package Plugins::SpotOn::Soloist;

# Structural twin of Helper.pm (D-02), but Soloist is auto-downloaded into the
# LMS cachedir (D-03/D-04) rather than shipped inside the plugin zip -- get()
# constructs the expected cachedir path directly and never uses
# Slim::Utils::Misc::findbin() for *binary discovery* (RESEARCH.md
# Anti-Patterns). Phase 73 (D-03 completion): findbin is AGAIN not used at
# all -- the Phase-72 per-track launcher wrapper (the one caller of
# addFindBinPaths()) is retired along with the `sol` convert-conf rule and
# content-type row; Soloist now runs exclusively as a persistent per-player
# daemon (Unified::SoloistDaemon), spawned directly, never via a generated
# shell wrapper.
#
# Per-player state lives under players/<mac>/{data,cache} (D-01/D-02,
# dataDirForClient/cacheDirForClient below) -- distinct from the Phase-72
# shared data/ dir this module used to manage via dataDir()/ensureLauncher().
# That shared dir (and any generated launcher script inside it) is left
# untouched on disk by this retirement: a session paired there under Phase 72
# is now orphaned but harmless (nothing references it anymore -- see
# TROUBLESHOOTING notes in 73-04-SUMMARY.md).
#
# %SOLOIST_VERSION_BY_ARCH is a record of "the version we downloaded and
# validated", per architecture -- NOT a URL parameter. Spotify's download
# endpoint is unversioned (RESEARCH.md Pitfall 1) and the three architectures
# carry permanently DIFFERENT build numbers (measured 2026-09-23: 68/69/69;
# measured 2026-08-25: 249/248 for arm64/arm32) -- a single, exactly-compared
# constant can never match all three. The pin is a LOWER bound (D-05,
# Phase 83.3): a binary reporting a version below its architecture's pin is
# never activated (fail-closed); a version above the pin activates and is
# recorded in the log -- never silently, never blocked.

use strict;
use warnings;
use Cwd qw(realpath);
use File::Spec::Functions qw(catdir catfile);
use File::Temp ();
use JSON::XS::VersionOneAndTwo;

use Slim::Utils::Log;
use Slim::Utils::OSDetect;
use Slim::Utils::Prefs;
use Slim::Networking::SimpleAsyncHTTP;

# D-05: validated 2026-09-23 against real downloads, per architecture --
# x86_64: `soloist --version` => "soloist 1.3.8.68 build 1790143294
# (20260923) (g5c3a2053ac) (linux/x86_64)"; aarch64 and armhf: 1.3.8.69
# (read from the binaries' own --version strings). One-way pin: a version
# change here requires revalidating all downstream patches (Lifetime,
# 24-bit -- Phase 74). Phase 83.3: the pin is enforced as a lower bound, not
# an equality -- a binary above the pin activates (D-05).
use constant VERSION_FLAG    => '--version';
use constant BINARY_NAME     => 'soloist';
use constant DOWNLOAD_HOST   => 'soloist-builds.spotifycdn.com';

my $prefs       = preferences('plugin.spoton');
my $serverPrefs = preferences('server');
my $log         = logger('plugin.spoton');

my ($binary, $version);

# WR-07: in-flight guard. ensureBinary() is now wired to every Settings save
# with backend=soloist (CR-01) -- without this flag, repeated saves during a
# slow async download would stack full parallel multi-MB downloads and tar
# extractions over the same destination. Cleared in both download callbacks
# (success and error) so a failed/retried download is never stuck blocked.
my $downloadInFlight;

# osArch (Spotify's vocabulary) -> { download (Spotify URL vocab),
# bindir (SpotOn's Bin/<arch>/ vocab) } -- RESEARCH.md Pitfall 4.
my @ARCH_MAP = (
    [ qr/^aarch64/i, { download => 'arm64',  bindir => 'aarch64-linux' } ],
    [ qr/^arm/i,     { download => 'arm32',  bindir => 'armhf-linux'  } ],
    [ qr/^x86_64/i,  { download => 'x86_64', bindir => 'x86_64-linux' } ],
);

# Keyed by bindir (SpotOn's Bin/<arch>/ vocabulary, i.e. @ARCH_MAP's
# {bindir} values -- deliberately NOT osArch, since bindir is what
# soloist-releases/<bindir>/ uses on disk). Validated 2026-09-23; change
# only together with a revalidation (see D-05 comment above).
my %SOLOIST_VERSION_BY_ARCH = (
    'x86_64-linux'  => '1.3.8.68',
    'aarch64-linux' => '1.3.8.69',
    'armhf-linux'   => '1.3.8.69',
);

sub init {
    $prefs->setChange( sub {
        $binary = $version = undef;
    }, 'backend') if !main::SCANNER;
}

# ---------------------------------------------------------------------------
# Arch detection + path construction
# ---------------------------------------------------------------------------

sub _arch {
    return undef if main::ISWINDOWS || main::ISMAC;

    my $osArch = Slim::Utils::OSDetect::details()->{osArch} || '';

    for my $entry (@ARCH_MAP) {
        my ($re, $map) = @$entry;
        return $map if $osArch =~ $re;
    }

    return undef;
}

# Public (no leading underscore): DaemonManager calls this too. Never dies --
# an architecture that isn't in @ARCH_MAP, or a bindir that (should never
# happen, but) isn't in %SOLOIST_VERSION_BY_ARCH, both resolve to undef.
sub expectedVersion {
    my $archInfo = _arch();
    return undef unless $archInfo;
    return $SOLOIST_VERSION_BY_ARCH{ $archInfo->{bindir} };
}

sub _downloadUrl {
    my ($archInfo) = @_;
    $archInfo ||= _arch();
    return undef unless $archInfo;

    return 'https://' . DOWNLOAD_HOST . '/soloist_release_' . $archInfo->{download} . '.tar.gz';
}

# Root dir for all Soloist state: cachedir/spoton/soloist -- spak.key lives
# directly here (NOT arch-specific, D-10); per-arch binaries live in
# subdirectories keyed by bindir.
sub _rootDir {
    return catdir($serverPrefs->get('cachedir'), 'spoton', 'soloist');
}

sub _cacheDir {
    my ($archInfo) = @_;
    $archInfo ||= _arch();
    return undef unless $archInfo;

    return catdir(_rootDir(), $archInfo->{bindir});
}

sub keyPath {
    return catfile(_rootDir(), 'spak.key');
}

sub libPath {
    my $archInfo = _arch();
    return undef unless $archInfo;

    # WR-05: runtime require (not a top-level `use`) to avoid a
    # Plugin.pm <-> Soloist.pm compile-time cycle -- load-cycle-safe
    # since libPath() is only ever called at runtime, well after both
    # modules have finished loading in the live LMS process.
    require Plugins::SpotOn::Plugin;

    my $basedir = Plugins::SpotOn::Plugin->_pluginDataFor('basedir');

    # D-17: the CI zip ships the per-arch shim as Bin/<bindir>/libpulse.so.0
    # (next to the soloist binary); the committed x86_64 build under
    # Bin/fake-libpulse/ would be the wrong architecture on aarch64/armhf.
    # Only the two fixed dirs below the plugin basedir are ever returned
    # (T-79-15), and the per-arch dir wins only when the .so file exists.
    my $perArch = catdir($basedir, 'Bin', $archInfo->{bindir});
    return $perArch if -f catfile($perArch, 'libpulse.so.0');

    return _fakeLibpulseDir($basedir);
}

sub _fakeLibpulseDir {
    my ($basedir) = @_;
    return catdir($basedir, 'Bin', 'fake-libpulse');
}

# libSearchPath() -- the LD_LIBRARY_PATH fragment for the daemon: libPath()
# first, then Bin/fake-libpulse when that is a different dir, because the
# decoy libpipewire-0.3.so.0 (invalid ELF, makes PipeWire's dlopen fail
# instantly) lives only there. undef when libPath() is undef.
sub libSearchPath {
    my $libPath = libPath();
    return undef unless defined $libPath;

    require Plugins::SpotOn::Plugin;
    my $fake = _fakeLibpulseDir(Plugins::SpotOn::Plugin->_pluginDataFor('basedir'));

    return $libPath eq $fake ? $libPath : "$libPath:$fake";
}

# ---------------------------------------------------------------------------
# Binary discovery + version check (Pattern 1)
# ---------------------------------------------------------------------------

# get() ACTIVATES: on a cold call ($binary unset) it probes the on-disk
# binary and, if acceptable, assigns the module-level $binary/$version and
# runs _versionCheck's park-flag side effect. 83.3 plan 08 (gap 2, WR-01):
# there are exactly two legitimate activation sites in this codebase --
# the Soloist role's prereqState (Backend/Soloist.pm, since 84-12 the prereq
# gate before a daemon may spawn) and SoloistDaemon's start (the spawn
# itself). Every OTHER reader --
# the settings page render, the 5s status poll, the hourly orphan sweep, the
# renewal pipeline's own same-version comparison, the exit-10 handler's
# version lookup -- is informational and MUST use activeVersion() /
# installedBinaryPath() instead, which never activate anything.
sub get {
    if (!$binary) {
        my $archInfo = _arch();
        return wantarray ? (undef, undef) : undef unless $archInfo;

        my $candidate = catfile(_cacheDir($archInfo), BINARY_NAME);

        if (-f $candidate && -x $candidate) {
            $binary = $candidate if _versionCheck($candidate);
        }
    }

    return wantarray ? ($binary, $version) : $binary;
}

# activeVersion() -- side-effect-free read: the version of the CURRENTLY
# ACTIVATED binary if one is already active ($binary set), otherwise the
# version the installed binary WOULD report if probed, without ever
# assigning $binary/$version or touching the cache. Returns undef when
# nothing acceptable is installed (same "activatable" semantics as get()).
# No memoization: the only state in which this spawns `soloist --version`
# repeatedly is a parked or below-pin binary, and by definition no daemon is
# running in that state, so the extra probe cost is bounded and rare.
sub activeVersion {
    return $version if $binary;

    my $path = installedBinaryPath();
    return undef unless defined $path;

    return _versionAcceptable($path, 1);
}

# Array-form open('-|', ...) -- never a shell string/backtick (RESEARCH.md
# Anti-Patterns; contrast with Helper.pm::helperCheck()'s pre-existing debt).
# Returns the parsed version string (e.g. "1.3.8.68") on success, or undef
# when the binary fails to run or its output doesn't parse. Pure probe --
# never touches the module-level $binary/$version or the cache, so plans 03
# (staged renewal candidates) and 05 (placed binaries) can call it directly
# without side-effecting activation state.
sub _versionProbe {
    my ($candidate) = @_;

    my $output = '';
    my $ok = eval {
        open(my $fh, '-|', $candidate, VERSION_FLAG) or die "open failed: $!\n";
        local $/;
        $output = <$fh> // '';
        close($fh);
        1;
    };

    unless ($ok) {
        $log->warn("Soloist: version check failed to run: $@");
        return undef;
    }

    # e.g. "soloist 1.3.8.68 build 1790143294 (20260923) (g5c3a2053ac) (linux/x86_64)"
    if ($output =~ /^soloist\s+([\d.]+)/i) {
        return $1;
    }

    $log->warn("Soloist: unexpected --version output (" . length($output) . " bytes)");
    return undef;
}

# _versionAcceptable($candidate, $quiet) -- pure: D-05 (Phase 83.3) pin
# check ONLY. The pin is a LOWER bound, not an equality. A binary below its
# architecture's pin is refused (fail-closed, unchanged); a binary above the
# pin is accepted and logged -- never silently, never blocked -- so a
# CDN-side renewal never requires a plugin update to keep working. Returns
# the parsed version string on acceptance, else undef. Touches nothing --
# no $binary/$version assignment, no cache read or write. Warns exactly as
# before unless $quiet is true (activeVersion() passes quiet=1 so an
# uninteresting informational probe of a parked/below-pin binary doesn't
# spam the log on every settings-page render).
sub _versionAcceptable {
    my ($candidate, $quiet) = @_;

    my $expected = expectedVersion();
    unless (defined $expected) {
        $log->warn("Soloist: no pinned version for this architecture -- not activating (D-05 fail-closed)")
            unless $quiet;
        return undef;
    }

    my $parsed = _versionProbe($candidate);
    return undef unless defined $parsed;

    if (_versionCompare($parsed, $expected) < 0) {
        $log->warn("Soloist: binary reports version $parsed, below the validated minimum "
            . $expected . " -- not activating (D-05 lower bound)") unless $quiet;
        return undef;
    }

    if (_versionCompare($parsed, $expected) > 0) {
        main::INFOLOG && $log->is_info && $log->info(
            "Soloist: binary version $parsed is newer than validated ($expected) -- activating (D-05)")
            unless $quiet;
    }

    return $parsed;
}

sub _versionCheck {
    my ($candidate) = @_;

    my $parsed = _versionAcceptable($candidate);
    return 0 unless defined $parsed;

    $version = $parsed;

    # 73-02 Pitfall 7 / 83.3 plan 08 (D-01/D-03 gap 2, WR-01): clearing the
    # park flag on EVERY successful probe (the original self-heal) meant the
    # very first read-only get() after an LMS restart -- from the settings
    # page render, the 5s status poll, or the renewal pipeline itself --
    # un-parked a daemon whose binary was still the expired one, letting the
    # watchdog start it (Connect-visible flash) only to exit 10 again. The
    # rule is now conditional: clear only when the probed binary actually
    # differs from the one recorded as expired -- by version, or by mtime
    # for a same-version replacement (a re-downloaded/placed copy of the
    # pinned version still un-parks; a re-probe of the SAME file must not).
    # A legacy flag record written before this plan (no mtime field) is
    # cleared once -- documented one-time self-heal; this makes no claim
    # about whether re-extracting the same archive preserves tar's stored
    # mtime, since that is asserted by no test here.
    eval {
        my $expired = _cache()->get('spoton_soloist_expired');
        my $mtime   = (stat($candidate))[9];
        $mtime = -2 unless defined $mtime;
        if (!$expired
            # 83.3-REVIEW round 2 (WR-01): an undef recorded version (unknown
            # at record time) can never PROVE a difference -- comparing it
            # against '' unconditionally cleared the flag on every probe of
            # the SAME expired file, defeating plan 08's conditional clear.
            # Only a DEFINED, genuinely differing version counts here; mtime
            # alone still tells a same-version replacement apart below.
            || (defined $expired->{version} && $expired->{version} ne $parsed)
            || (($expired->{mtime} // -1) != $mtime)) {
            _cache()->remove('spoton_soloist_expired');
        }
        1;
    };

    return 1;
}

# installedBinaryPath() -- pure: the canonical on-disk path for this
# architecture's Soloist binary IF it exists and is executable, else undef.
# No probe, no state -- informational read sites (Plugin.pm's orphan sweep,
# DaemonManager's exit-10 handler) use this instead of the activating get().
sub installedBinaryPath {
    my $archInfo = _arch();
    return undef unless $archInfo;

    my $path = catfile(_cacheDir($archInfo), BINARY_NAME);
    return (-f $path && -x $path) ? $path : undef;
}

sub _versionCompare {
    my ($v1, $v2) = @_;
    my @a = split /\./, $v1;
    my @b = split /\./, $v2;

    # WR-04: iterate over the max length of both lists, not just @b
    # (the expected version). Looping only over @b let a parsed version
    # that is a strict superset with an equal prefix (e.g. reported
    # "1.3.7.489.1" vs expected "1.3.7.489") compare equal -- weakening
    # the D-05 fail-closed pin, since trailing components on either side
    # must be significant.
    my $n = $#a > $#b ? $#a : $#b;
    for my $i (0 .. $n) {
        my $diff = ($a[$i] || 0) <=> ($b[$i] || 0);
        return $diff if $diff;
    }
    return 0;
}

# D-05: true iff the currently activated binary's version is strictly newer
# than this architecture's pin -- consumed by plan 03's Settings info line.
# undef/no activation or no pin both resolve to 0 (fail-closed default).
sub versionAheadOfPin {
    return 0 unless defined $version;
    my $expected = expectedVersion();
    return (defined $expected && _versionCompare($version, $expected) > 0) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# Download-and-cache (Pattern 2, D-03/D-04)
# ---------------------------------------------------------------------------

sub ensureBinary {
    return if main::ISWINDOWS || main::ISMAC;

    return if get();    # already have a working, version-matched binary
    return if $downloadInFlight;    # WR-07: a download is already running

    my $archInfo = _arch();
    return unless $archInfo;

    downloadBinary($archInfo);
}

sub downloadBinary {
    my ($archInfo) = @_;
    return if $downloadInFlight;    # WR-07: guard against concurrent downloads

    $archInfo ||= _arch();
    return unless $archInfo;

    my $destDir = _cacheDir($archInfo);

    # D-04 structural protection: never re-download/overwrite an already
    # cached binary except via an explicit cache-clear (which removes this
    # file out-of-band).
    my $existing = catfile($destDir, BINARY_NAME);
    if (-f $existing && -x $existing) {
        main::INFOLOG && $log->is_info && $log->info(
            "Soloist: binary already present at $existing -- skipping download (D-04)");
        return;
    }

    require File::Path;
    File::Path::make_path($destDir, { mode => 0700 }) unless -d $destDir;

    my (undef, $archivePath) = File::Temp::tempfile(
        'soloist-XXXX', DIR => $destDir, SUFFIX => '.tar.gz', UNLINK => 0, OPEN => 0,
    );

    my $url = _downloadUrl($archInfo);

    main::INFOLOG && $log->is_info && $log->info("Soloist: downloading $url");

    $downloadInFlight = 1;

    Slim::Networking::SimpleAsyncHTTP->new(
        sub { _onSoloistDownloadDone(shift, $archivePath, $destDir) },
        sub { my ($http, $error) = @_; _onSoloistDownloadError($http, $error, $archivePath) },
        { saveAs => $archivePath, timeout => 30 },
    )->get($url);
}

sub _onSoloistDownloadDone {
    my ($http, $archivePath, $destDir) = @_;

    $downloadInFlight = 0;    # WR-07: clear before any early return below

    unless (-f $archivePath && -s $archivePath) {
        $log->warn("Soloist: download completed but archive missing/empty");
        return;
    }

    my ($canonical, $reason) = _extractArchive($archivePath, $destDir);
    return unless $canonical;

    # Fail-closed: only activate on a matching post-download version check.
    if (_versionCheck($canonical)) {
        $binary = $canonical;
        main::INFOLOG && $log->is_info && $log->info(
            "Soloist: binary activated, version " . ($version || '?'));

        # Patching was dropped 2026-09-25 (Phase 83.3, lifetime and 24-bit
        # patches struck): the helper's `check` subcommand remains available
        # for diagnostics, but `patch` is never invoked in production.
    } else {
        $log->warn("Soloist: downloaded binary failed version check -- not activated (fail-closed)");
    }
}

# _extractArchive($archivePath, $destDir) -- Phase 83.3 plan 03: factored out
# of _onSoloistDownloadDone (WR-05 tar/containment discipline unchanged,
# byte-identical to the first-install path) so the renewal engine below can
# extract a staged candidate through the exact same code. Returns the
# canonical binary path on success, or (undef, $reason) with $reason one of
# tar_failed|no_binary|escapes_dir|move_failed.
sub _extractArchive {
    my ($archivePath, $destDir) = @_;

    # T-71-04: array-form system(), never an interpolated shell string.
    # WR-05: strip ownership/permission bits from archive members -- GNU
    # tar already refuses `..`-escaping/absolute members by default, but
    # the plugin cannot assume GNU tar (busybox/BSD tar on some LMS hosts
    # behave differently), so member-path containment is re-verified below
    # rather than trusted to tar alone.
    my $rc = system('tar', 'xzf', $archivePath, '-C', $destDir,
        '--no-same-owner', '--no-same-permissions');
    unlink $archivePath;

    if ($rc != 0) {
        $log->warn("Soloist: tar extraction failed (rc=$rc)");
        return (undef, 'tar_failed');
    }

    # A3: archive is flat (confirmed empirically), but search recursively as
    # a defensive fallback in case a future build nests the binary.
    my $extracted = _findExtractedBinary($destDir);
    unless ($extracted) {
        $log->warn("Soloist: no '" . BINARY_NAME . "' binary found after extraction");
        return (undef, 'no_binary');
    }

    # WR-05: reject a path-traversal/symlink escape -- resolve both the
    # extracted binary and the cache dir and require containment. A
    # malicious/compromised archive member (a symlink, or a `..`-relative
    # path a non-GNU tar didn't strip) could otherwise resolve outside the
    # trusted cache directory before it's chmod'd/activated.
    my $resolvedDest = realpath($destDir);
    my $resolvedExtracted = realpath($extracted);
    unless ($resolvedDest && $resolvedExtracted && _pathIsWithin($resolvedExtracted, $resolvedDest)) {
        $log->warn("Soloist: extracted binary path escapes cache dir -- refusing to activate");
        return (undef, 'escapes_dir');
    }

    chmod(0755, $extracted);

    my $canonical = catfile($destDir, BINARY_NAME);
    if ($extracted ne $canonical) {
        require File::Copy;
        unless (File::Copy::move($extracted, $canonical)) {
            $log->warn("Soloist: failed to move extracted binary into place: $!");
            return (undef, 'move_failed');
        }
        chmod(0755, $canonical);
    }

    return $canonical;
}

sub _onSoloistDownloadError {
    my ($http, $error, $archivePath) = @_;
    $downloadInFlight = 0;    # WR-07: clear on failure so a retry can proceed
    $log->warn("Soloist: download failed: " . ($error || 'unknown error'));
    unlink $archivePath if $archivePath && -f $archivePath;
}

sub _findExtractedBinary {
    my ($dir) = @_;

    my $direct = catfile($dir, BINARY_NAME);
    return $direct if -f $direct;

    require File::Find;
    my $found;
    File::Find::find(sub {
        return if $found;
        $found = $File::Find::name if $_ eq BINARY_NAME && -f $File::Find::name;
    }, $dir);

    return $found;
}

# _pathIsWithin($path, $root) -- WR-05: true iff resolved $path is $root
# itself or a descendant of it. Both arguments are expected to already be
# realpath()-resolved (symlinks followed, no trailing slash ambiguity);
# this is a pure string-containment check so it stays cheap and testable
# without touching the filesystem again.
sub _pathIsWithin {
    my ($path, $root) = @_;
    return 0 unless defined $path && defined $root && length $root;

    my $rootWithSep = $root =~ m{/\z} ? $root : "$root/";
    return $path eq $root || index($path, $rootWithSep) == 0;
}

# ---------------------------------------------------------------------------
# Renewal engine (D-01/D-03/D-04/D-06/D-07 storage half, Phase 83.3 plan 03)
#
# renewBinary() bypasses ensureBinary/downloadBinary's D-04 "never
# re-download" guard entirely (a renewal is exactly the case where a
# version-matched binary already exists and must be replaced) but reuses
# the same extraction/containment code (_extractArchive) and the same
# fail-closed activation gate (_versionCheck) as the first-install path.
# ---------------------------------------------------------------------------

use constant RENEWAL_TRIGGER_DAYS   => 14;
use constant RENEWAL_RETRY_S        => 86400;
use constant RENEWAL_HARD_TIMEOUT_S => 900;
use constant SOLOIST_DOWNLOAD_PAGE  =>
    'https://developer.spotify.com/documentation/soloist/reference/downloads-and-updates';

# undef | 'renewal' | 'placed' -- ONE guard shared with plan 05's
# placed-binary evaluation, so a renewal and a placed-binary check never
# overlap and two smoke tests never run at once.
my $lifecycleInFlight;

# State for the renewal currently in flight (undef when none) -- archInfo +
# the caller's %opts (incl. an optional 'cb' used by tests/checkRenewalDue
# callers to observe completion) + a one-shot 'done' flag so _finishRenewal
# is idempotent even if two code paths both try to finalize the same run.
my $_activeRenewal;

sub lifecycleInFlight { return $lifecycleInFlight; }

sub _setLifecycleInFlight {
    my ($owner) = @_;
    $lifecycleInFlight = $owner;
    return $lifecycleInFlight;
}

sub _cache {
    require Slim::Utils::Cache;
    require Plugins::SpotOn::Plugin;
    return Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION());
}

sub _stagingDir {
    my ($archInfo) = @_;
    $archInfo ||= _arch();
    return undef unless $archInfo;
    return catdir(_cacheDir($archInfo), 'staging');
}

sub _previousDir {
    my ($archInfo) = @_;
    $archInfo ||= _arch();
    return undef unless $archInfo;
    return catdir(_cacheDir($archInfo), 'previous');
}

# renewalState() -- always returns a hashref (default { phase => 'idle' }),
# a shallow copy so callers can't mutate the cached value in place.
sub renewalState {
    my $state = _cache()->get('spoton_soloist_renewal_state');
    return ($state && ref($state) eq 'HASH') ? { %$state } : { phase => 'idle' };
}

sub _setRenewalState {
    my (%fields) = @_;
    my $state = renewalState();
    @{$state}{ keys %fields } = values %fields;
    _cache()->set('spoton_soloist_renewal_state', $state, 'never');
    return $state;
}

# expiryDaysRemaining() -- the exact arithmetic Settings.pm used inline
# before this plan (WR-10: adjusted for wallclock elapsed since the reading
# was taken, floored at 0). undef when there is no cached expiry reading at
# all (daemon never started, or backend isn't soloist).
sub expiryDaysRemaining {
    my $expiryCache = _cache()->get('spoton_soloist_expiry_days');
    return undef unless $expiryCache && defined $expiryCache->{days};

    my $checkedAt   = $expiryCache->{checked_at} || time();
    my $elapsedDays = int((time() - $checkedAt) / 86400);
    my $adjusted    = $expiryCache->{days} - $elapsedDays;
    return $adjusted > 0 ? $adjusted : 0;
}

# hasPreviousGeneration() -- true iff a kept previous-generation binary
# exists on disk for this architecture (plan 04 uses this for rollback UI).
sub hasPreviousGeneration {
    my $archInfo = _arch();
    return 0 unless $archInfo;
    my $previous = catfile(_previousDir($archInfo), BINARY_NAME);
    return (-x $previous) ? 1 : 0;
}

# renewBinary(%opts) -- reason => 'expiry'|'exit10'|'manual' (required).
# Returns synchronously: 'unsupported' (Windows/macOS/no arch), 'busy' (a
# renewal or a plan-05 placed-binary check is already running, or a plain
# ensureBinary()-triggered download is in flight), or 'started'. The actual
# outcome is async -- poll renewalState() or pass opts{cb}.
sub renewBinary {
    my (%opts) = @_;

    my $archInfo = _arch();
    return 'unsupported' unless $archInfo;

    # D-09 (Phase 83.3 plan 05): while a valid placed binary is active,
    # automatic renewal rests -- ALL reasons, including a manual click
    # (objective). The way out is emptying the manual folder.
    if (_placedBinaryIsValid()) {
        _setRenewalState(phase => 'blocked', detail => 'placed_binary_active', reason => $opts{reason}, at => time());
        return 'blocked:placed_binary_active';
    }

    return 'busy' if $lifecycleInFlight || $downloadInFlight;

    $lifecycleInFlight = 'renewal';
    $_activeRenewal = { archInfo => $archInfo, opts => \%opts, done => 0 };

    require Slim::Utils::Timers;
    Slim::Utils::Timers::killTimers(__PACKAGE__, \&_renewalHardTimeout);
    Slim::Utils::Timers::setTimer(__PACKAGE__, time() + RENEWAL_HARD_TIMEOUT_S, \&_renewalHardTimeout);

    _setRenewalState(
        phase           => 'downloading',
        detail          => undef,    # G-83.3-6b: a new attempt starts without the previous attempt's detail.
        reason          => $opts{reason},
        at              => time(),
        last_attempt_at => time(),
    );

    my $stagingDir = _stagingDir($archInfo);
    require File::Path;
    File::Path::remove_tree($stagingDir) if -d $stagingDir;
    File::Path::make_path($stagingDir, { mode => 0700 });

    my (undef, $archivePath) = File::Temp::tempfile(
        'soloist-renew-XXXX', DIR => $stagingDir, SUFFIX => '.tar.gz', UNLINK => 0, OPEN => 0,
    );

    my $url = _downloadUrl($archInfo);
    main::INFOLOG && $log->is_info && $log->info(
        "Soloist: renewal download starting (reason=" . ($opts{reason} // '?') . "): $url");

    Slim::Networking::SimpleAsyncHTTP->new(
        sub { _onRenewalDownloadDone(shift, $archivePath, $archInfo, \%opts) },
        sub { my ($http, $error) = @_; _onRenewalDownloadError($http, $error, \%opts) },
        { saveAs => $archivePath, timeout => 30 },
    )->get($url);

    return 'started';
}

sub _renewalHardTimeout {
    $log->warn("Soloist: renewal hard-timeout (" . RENEWAL_HARD_TIMEOUT_S . "s) reached -- aborting");
    _finishRenewal('failed', 'stalled');
}

# _finishRenewal($phase, $detail) -- the SINGLE finalizer every renewal
# branch (success, every failure reason, an exception inside the smoke
# callback, and the hard-timeout) ends in. Idempotent: a second call after
# $_activeRenewal->{done} is already set is a no-op, so a stuck guard is
# structurally impossible.
sub _finishRenewal {
    my ($phase, $detail) = @_;

    return 0 unless $_activeRenewal && !$_activeRenewal->{done};
    $_activeRenewal->{done} = 1;

    require Slim::Utils::Timers;
    Slim::Utils::Timers::killTimers(__PACKAGE__, \&_renewalHardTimeout);

    if (my $archInfo = $_activeRenewal->{archInfo}) {
        my $stagingDir = _stagingDir($archInfo);
        if ($stagingDir && -d $stagingDir) {
            require File::Path;
            File::Path::remove_tree($stagingDir);
        }
    }

    $lifecycleInFlight = undef;

    # G-83.3-6b: detail is always named here, even when undef.
    # _setRenewalState() merges by key -- a key that is NOT passed survives
    # from the previous write, so a detail-less terminal phase (done,
    # same_version) must explicitly overwrite a stale detail rather than
    # omit the key.
    my %fields = (phase => $phase, detail => $detail, last_attempt_at => time());
    _setRenewalState(%fields);

    my $opts = $_activeRenewal->{opts} || {};
    my $cb   = $opts->{cb};
    $_activeRenewal = undef;
    $cb->($phase, $detail) if $cb;

    return 1;
}

sub _onRenewalDownloadDone {
    my ($http, $archivePath, $archInfo, $opts) = @_;

    unless (-f $archivePath && -s $archivePath) {
        return _finishRenewal('failed', 'download_empty');
    }

    my $stagingDir = _stagingDir($archInfo);
    my ($candidate, $extractReason) = _extractArchive($archivePath, $stagingDir);
    unless ($candidate) {
        return _finishRenewal('failed', $extractReason || 'extract_failed');
    }

    my $parsed = _versionProbe($candidate);
    unless (defined $parsed) {
        return _finishRenewal('failed', 'version_unparsable');
    }

    my $expected = expectedVersion();
    if (!defined $expected || _versionCompare($parsed, $expected) < 0) {
        return _finishRenewal('failed', 'below_minimum');
    }

    # Same-version rule (planner decision): a candidate matching the
    # currently-active version is discarded for the automatic reasons, but
    # is still smoke-tested and swapped for a manual renewal -- the button's
    # purpose is to exercise the whole path even when nothing changed.
    # 83.3 plan 08 (gap 2, WR-01): activeVersion() -- not the activating
    # get() -- the same-version comparison must not un-park a daemon
    # mid-renewal, before the candidate has even passed its smoke test.
    my $activeVersion = activeVersion();
    if (defined $activeVersion && _versionCompare($parsed, $activeVersion) == 0) {
        my $reason = $opts->{reason} || '';
        if ($reason eq 'exit10') {
            return _finishRenewal('failed', 'CDN still serves the expired build');
        }
        elsif ($reason ne 'manual') {
            return _finishRenewal('same_version', undef);
        }
        # reason eq 'manual' -- fall through to smoke test + swap.
    }

    _setRenewalState(phase => 'smoke', candidate_version => $parsed);

    my $ok = eval {
        _smokeTest($candidate, sub {
            my ($smokeOk, $info) = @_;
            if ($smokeOk) {
                _promoteCandidate($candidate, {
                    %{ $info || {} },
                    reason           => $opts->{reason},
                    previous_version => $activeVersion,
                });
            }
            else {
                _finishRenewal('failed', ($info && $info->{reason}) || 'smoke_failed');
            }
        });
        1;
    };
    unless ($ok) {
        $log->warn("Soloist: smoke test raised an exception: " . ($@ || 'unknown error'));
        _finishRenewal('failed', 'smoke_exception');
    }
}

sub _onRenewalDownloadError {
    my ($http, $error, $opts) = @_;
    _finishRenewal('failed', 'download_failed:' . ($error || 'unknown error'));
}

# _smokeTest($candidate, $cb) -- thin seam over SoloistDaemon->smokeTest so
# unit tests can stub this one call instead of the whole daemon-spawn chain.
# The version gate already ran (above); this call only proves the binary
# actually starts and reports its remaining lifetime in days. Freshness
# (> RENEWAL_TRIGGER_DAYS remaining) is enforced by the PLACED path's own
# caller, right below in checkPlacedBinary()'s smoke callback (D-10, WR-04).
# The RENEWAL path (_onRenewalDownloadDone) has NO freshness gate yet and
# promotes on $smokeOk alone -- WR-04's renewal-path half, out of this
# gap-closure plan's cut, tracked for Phase 84.
sub _smokeTest {
    my ($candidate, $cb) = @_;
    require Plugins::SpotOn::Unified::SoloistDaemon;
    Plugins::SpotOn::Unified::SoloistDaemon->smokeTest($candidate, $cb);
}

# _promoteCandidate($candidate, $info) -- swaps the smoke-tested candidate
# into place, keeping exactly ONE previous generation (D-07 storage half;
# rollback UI is plan 04). Activation is re-run explicitly via
# _versionCheck() -- backendPrereqState() short-circuits on
# spoton_soloist_expired BEFORE ever calling get(), so promotion must clear
# that flag itself rather than relying on some later get() call to do it.
sub _promoteCandidate {
    my ($candidate, $info) = @_;

    my $archInfo = _arch();
    my $oldDays  = expiryDaysRemaining();

    my $previousDir = _previousDir($archInfo);
    require File::Path;
    File::Path::remove_tree($previousDir) if -d $previousDir;
    File::Path::make_path($previousDir, { mode => 0700 });

    my $canonical        = catfile(_cacheDir($archInfo), BINARY_NAME);
    my $previousBinary   = catfile($previousDir, BINARY_NAME);

    if (-f $canonical) {
        require File::Copy;
        File::Copy::move($canonical, $previousBinary);
    }

    require File::Copy;
    unless (File::Copy::move($candidate, $canonical)) {
        $log->warn("Soloist: failed to move renewal candidate into place: $!");
        return _finishRenewal('failed', 'promote_move_failed');
    }
    chmod(0755, $canonical);

    $binary = undef;
    $version = undef;

    unless (_versionCheck($canonical)) {
        # Roll back: the smoke test already proved the OLD binary works, so
        # restore it rather than leaving the player with nothing at all.
        if (-f $previousBinary) {
            require File::Copy;
            File::Copy::move($previousBinary, $canonical);
            _versionCheck($canonical);
        }
        return _finishRenewal('failed', 'activation_failed');
    }

    $binary = $canonical;

    my $previousVersion = $info->{previous_version};
    $previousVersion = (-f $previousBinary ? _versionProbe($previousBinary) : undef)
        unless defined $previousVersion;

    _cache()->set('spoton_soloist_generation', {
        active_version       => $version,
        previous_version     => $previousVersion,
        previous_expiry_days => $oldDays,
        switched_at          => time(),
        reason               => $info->{reason},
    }, 'never');

    if (defined $info->{days}) {
        _cache()->set('spoton_soloist_expiry_days', {
            days       => $info->{days},
            checked_at => time(),
        }, 'never');
    }

    # D-10 second stage (Phase 83.3 plan 12, WR-04/gap-closure round 2): no
    # writer of the placed state previously existed for "a CDN renewal
    # replaced the placed binary" -- an active placed binary's status would
    # keep reading 'active' forever after a CDN promotion superseded it
    # (checkPlacedBinary's own signature short-circuit never re-evaluates
    # an unchanged file). Whenever this promotion's reason is NOT 'placed'
    # (i.e. this IS a CDN renewal, not the placed-binary path promoting
    # itself) and the placed state is currently 'active', flip it to
    # 'rejected'/'superseded:<new version>' -- Settings' existing 'rejected'
    # branch (MANUAL_REJECTED with %s => reason) already renders an
    # arbitrary reason token verbatim, and soloistExpiryHint goes false on
    # its own once status is no longer 'active'. The merge in
    # _setPlacedState keeps the signature, so the superseded (but still
    # unchanged) file in the manual folder short-circuits to 'rejected'
    # rather than being re-smoke-tested (same reasoning as
    # rollbackToPrevious()'s rolled_back flip). The user's ways out are
    # unchanged: place a fresher file (new signature -> re-evaluated), or
    # empty the folder.
    if ((($info->{reason} // '') ne 'placed') && ((placedState()->{status} // '') eq 'active')) {
        main::INFOLOG && $log->is_info && $log->info(
            "Soloist: CDN renewal promoted $version over an active placed binary -- placed state flips to rejected/superseded:$version");
        _setPlacedState(status => 'rejected', reason => 'superseded:' . $version);
    }

    _finishRenewal('done', undef);

    eval {
        require Plugins::SpotOn::Unified::DaemonManager;
        Plugins::SpotOn::Unified::DaemonManager->onSoloistBinaryReplaced({
            version => $version,
            reason  => $info->{reason},
        });
        1;
    } or $log->warn("Soloist: onSoloistBinaryReplaced failed: " . ($@ || 'unknown error'));

    return 1;
}

# rollbackToPrevious(%opts) -- Phase 83.3 plan 04 (D-07): swaps the kept
# previous generation back into place, while it is still unexpired.
# reason => a human string describing WHY (used only for the log line and
# the renewal-state 'detail' field, never for branching). Returns
# synchronously (unlike renewBinary/promoteCandidate -- there is no
# download/smoke test here, just a file swap and a re-activation):
#   (1, $version)              -- rolled back, $version is the restored build
#   (0, 'no_previous')         -- no kept previous generation, or it fails
#                                 its own version probe
#   (0, 'previous_expired')    -- a previous generation exists but its
#                                 wall-clock-adjusted remaining lifetime is
#                                 <= 0 (D-07: only the notice remains)
#   (0, 'rollback_move_failed') -- filesystem error moving the file back
# The binary path is shared per architecture (Soloist.pm _arch/_cacheDir,
# RESEARCH Q5) -- this swap covers every player on this machine at once;
# DaemonManager's _rollbackAfterSwitch is the caller that fans the restart
# out to each alive daemon.
sub rollbackToPrevious {
    my (%opts) = @_;

    my $archInfo = _arch();
    return (0, 'no_previous') unless $archInfo;

    my $canonical = catfile(_cacheDir($archInfo), BINARY_NAME);
    my $prev      = catfile(_previousDir($archInfo), BINARY_NAME);

    return (0, 'no_previous') unless -x $prev && _versionProbe($prev);

    my $gen = _cache()->get('spoton_soloist_generation') || {};
    my $prevDays = ($gen->{previous_expiry_days} // 0)
        - int((time() - ($gen->{switched_at} // time())) / 86400);

    if ($prevDays <= 0) {
        # D-07: only the notice remains -- checkRenewalDue's own daily
        # retry cadence is untouched and will still fetch a fresh build.
        _setRenewalState(phase => 'rollback_impossible', detail => 'previous_expired');
        return (0, 'previous_expired');
    }

    # The failed new build is discarded outright -- exactly one generation
    # is kept on disk, and after this swap it is the good one again.
    unlink $canonical if -f $canonical;

    require File::Copy;
    unless (File::Copy::move($prev, $canonical)) {
        $log->warn("Soloist: rollback move failed: $!");
        return (0, 'rollback_move_failed');
    }
    chmod(0755, $canonical);

    $binary  = undef;
    $version = undef;
    # Explicit activation, exactly like _promoteCandidate: backendPrereqState()
    # short-circuits on spoton_soloist_expired BEFORE ever calling get(), so
    # only an explicit _versionCheck call here clears that flag and un-parks
    # the daemon.
    _versionCheck($canonical);
    $binary = $canonical;

    # Phase 83.3 plan 05 (D-09/D-10): if the build just discarded was the
    # placed one, its placed state must flip to 'rejected' too -- otherwise
    # the settings page keeps claiming renewal is paused for a binary that
    # is no longer running, and _placedBinaryIsValid() would stay (wrongly)
    # true. Keeps the existing signature (merge, not reset) so the SAME
    # unchanged file in the manual folder is never re-evaluated: the
    # signature short-circuit in checkPlacedBinary() returns 'rejected'
    # straight away instead of re-running the smoke test on a build already
    # known to be bad.
    if (($gen->{reason} // '') eq 'placed') {
        _setPlacedState(status => 'rejected', reason => 'rolled_back');
    }

    _cache()->set('spoton_soloist_generation', {
        active_version    => $version,
        previous_version  => undef,
        rolled_back_from  => $gen->{active_version},
        switched_at       => time(),
        reason            => 'rollback',
    }, 'never');

    _cache()->set('spoton_soloist_expiry_days', {
        days       => $prevDays,
        checked_at => time(),
    }, 'never');

    # last_attempt_at = now (known limit, stated in the plan): the automatic
    # daily-retry path waits the full RENEWAL_RETRY_S cadence before fetching
    # again -- it may fetch the same bad build tomorrow.
    _setRenewalState(
        phase           => 'rolled_back',
        detail          => $opts{reason},
        from_version    => $gen->{active_version},
        to_version      => $version,
        last_attempt_at => time(),
        at              => time(),
    );

    return (1, $version);
}

# checkRenewalDue(%opts) -- called once per 60s watchdog tick (DaemonManager
# Task 2, no options) when backend=soloist. D-01: <= RENEWAL_TRIGGER_DAYS
# triggers a renewal, retried daily (RENEWAL_RETRY_S) until it succeeds;
# D-03: an exit-10 escalation (spoton_soloist_expired set) triggers
# immediately. 83.3 plan 11 (D-03, WR-01, gap-closure round 2): the daily
# RENEWAL_RETRY_S floor is skipped iff $opts{bypass_retry_floor} is true --
# DaemonManager's _handleSoloistBuildExpiry passes this exactly once per
# park-flag TRANSITION (the exit-10 that SETS spoton_soloist_expired), so
# the handler's "renew immediately" guarantee holds even when the preceding
# D-01 daily attempt stamped last_attempt_at within the last RENEWAL_RETRY_S
# (renewBinary/_finishRenewal stamp it on every terminal phase, including
# the routine same_version answer -- so on the day a build genuinely
# expires the floor is almost always closed without this bypass). A repeat
# exit-10 while the flag is already set, and every watchdog-tick call
# (which never passes the option), still obey the floor: a persistently
# failing CDN must not be hammered every 60s, and the bypass staying tied
# to the transition keeps plan 08's un-throttled-download-loop fix intact
# (the flag is cleared only by _versionCheck activating a binary differing
# in version or mtime from the one recorded, never by a read-only re-probe).
sub checkRenewalDue {
    my (%opts) = @_;

    return 'not_soloist' unless (($prefs->get('backend') // 'librespot') eq 'soloist') && _arch();
    return 'in_flight'   if $lifecycleInFlight;

    # D-10 (Phase 83.3 plan 05, extended plan 10, corrected plan 12
    # WR-04/gap-closure round 2): the two-stage rule. An active placed
    # binary keeps its status through its own last RENEWAL_TRIGGER_DAYS
    # days -- that is exactly the settings hint's window (Settings.pm
    # soloistExpiryHint = soloistExpiryWarn && placedStatus eq 'active'),
    # so the user sees "place a new one or empty the folder" for the WHOLE
    # 14 days D-10 promises, not for one 60s tick. Renewal is un-blocked in
    # that same window by _placedBinaryIsValid()'s own threshold below, NOT
    # by a status change here -- plan 10's tick-time flip to
    # 'rejected'/'expires_soon:<N>' collapsed the warning window to a
    # single tick and made the running, installed build read as "ignored"
    # (review WR-04); that flip is intentionally gone. Only a build that
    # actually ran out (<= 0 remaining days) is flipped here, keeping the
    # pre-existing 'expired'/'expired' wording (Case 9). A FRESH placed
    # candidate with <= RENEWAL_TRIGGER_DAYS days is still rejected at
    # evaluation time (checkPlacedBinary's smoke callback, D-01/plan 10,
    # Cases 13/14, unchanged) -- only the tick-time re-flip of an
    # already-active binary was the defect.
    if ((placedState()->{status} // '') eq 'active') {
        my $adjustedDays = expiryDaysRemaining() // 0;
        if ($adjustedDays <= 0) {
            _setPlacedState(status => 'expired', reason => 'expired');
        }
    }

    my $reason;
    if (_cache()->get('spoton_soloist_expired')) {
        $reason = 'exit10';
    }
    elsif (defined expiryDaysRemaining() && expiryDaysRemaining() <= RENEWAL_TRIGGER_DAYS) {
        $reason = 'expiry';
    }

    return 'not_due' unless $reason;

    my $lastAttempt = renewalState()->{last_attempt_at} // 0;
    return 'retry_wait' if !$opts{bypass_retry_floor} && (time() - $lastAttempt) < RENEWAL_RETRY_S;

    return renewBinary(reason => $reason);
}

# ---------------------------------------------------------------------------
# Placed-binary fallback (D-08/D-09/D-10/D-11, Phase 83.3 plan 05)
#
# A fixed folder under _rootDir() the 60s watchdog scans for a user-supplied
# Soloist archive or bare binary (named on the settings page next to
# Spotify's download link, D-08). Evaluated through EXACTLY the renewal
# pipeline's own gates (extract -> version >= pin -> smoke test -> promote),
# just without the download step -- a local file is treated as adversarial
# as a network download (RESEARCH.md Security Domain, T-83.3-21/22). While a
# placed binary is valid it takes priority over CDN renewal (D-09, enforced
# in renewBinary() above); once it is invalid/expired it counts as absent
# and CDN renewal resumes (D-10). Uses the SAME lifecycleInFlight guard as
# the renewal engine above -- a renewal and a placed-binary check can never
# run a smoke test concurrently (no second in-flight flag).
# ---------------------------------------------------------------------------

use constant MANUAL_DIR_NAME => 'manual';

sub manualDir {
    return catdir(_rootDir(), MANUAL_DIR_NAME);
}

# placedState() -- always a hashref (default { status => 'absent' }), a
# shallow copy so callers can't mutate the cached value in place. Mirrors
# renewalState()'s own idiom.
sub placedState {
    my $state = _cache()->get('spoton_soloist_placed_state');
    return ($state && ref($state) eq 'HASH') ? { %$state } : { status => 'absent' };
}

sub _setPlacedState {
    my (%fields) = @_;
    my $state = placedState();
    @{$state}{ keys %fields } = values %fields;
    _cache()->set('spoton_soloist_placed_state', $state, 'never');
    return $state;
}

# _scanManualDir() -- returns { path, kind => 'archive'|'binary', signature }
# for the single candidate the folder holds, or undef when the folder is
# empty/absent or holds nothing acceptable. Creates the folder (0700) when
# missing, so the settings page always names an existing folder. Ignores
# dotfiles and symlinks (T-83.3-21/T-83.3-22 -- a symlink member is never
# followed, matching _extractArchive's own containment discipline); a
# non-symlink candidate must additionally realpath-resolve inside the
# folder. `.tar.gz` files are preferred (sorted, first wins); a file named
# exactly `soloist` is the fallback when no archive is present.
sub _scanManualDir {
    my $dir = manualDir();

    unless (-d $dir) {
        require File::Path;
        File::Path::make_path($dir, { mode => 0700 });
        return undef;
    }

    opendir(my $dh, $dir) or return undef;
    my @entries = sort grep { $_ !~ /^\./ } readdir($dh);
    closedir($dh);

    my $resolvedDir = realpath($dir);
    return undef unless $resolvedDir;

    my ($archivePath, $archiveName, $binaryPath, $binaryName);
    for my $entry (@entries) {
        my $full = catfile($dir, $entry);
        next if -l $full;    # T-83.3-21/22: never follow a symlink member
        next unless -f $full;

        my $resolved = realpath($full);
        next unless $resolved && _pathIsWithin($resolved, $resolvedDir);

        if (!$archivePath && $entry =~ /\.tar\.gz\z/) {
            $archivePath = $full;
            $archiveName = $entry;
        }
        elsif (!$binaryPath && $entry eq BINARY_NAME) {
            $binaryPath = $full;
            $binaryName = $entry;
        }
    }

    my ($path, $kind, $name) = $archivePath ? ($archivePath, 'archive', $archiveName)
                              : $binaryPath  ? ($binaryPath, 'binary', $binaryName)
                              :                (undef, undef, undef);
    return undef unless $path;

    my @stat = stat($path);
    my $signature = "$name:" . ($stat[7] // 0) . ':' . ($stat[9] // 0);

    return { path => $path, kind => $kind, signature => $signature };
}

# checkPlacedBinary() -- called once per 60s watchdog tick, BEFORE
# checkRenewalDue (DaemonManager initHelpers), so a valid placed binary
# blocks a renewal decision made in the SAME tick (D-09). Returns
# synchronously: 'not_soloist' (backend isn't soloist or no arch),
# 'in_flight' (a renewal OR another placed-binary check already running --
# the SAME guard as the renewal engine), 'absent' (folder empty), the
# CURRENT status (active|rejected|expired) when the candidate's signature
# is unchanged since the last evaluation (D-10/T-83.3-23: re-evaluate only
# on a signature change, never every 60s), or 'started' (a fresh evaluation
# just ran -- synchronous end to end, no network step). Rejection reasons
# include below_minimum, version_unparsable, copy_failed, extract_failed,
# promote_failed, the smoke stub's own failure reason, and -- since 83.3
# plan 10 (D-10, WR-04) -- expires_soon:<N> when the candidate's own smoke
# test reports <= RENEWAL_TRIGGER_DAYS remaining days (an expiring placed
# binary counts as absent, same threshold the CDN path applies to itself).
sub checkPlacedBinary {
    return 'not_soloist' unless (($prefs->get('backend') // 'librespot') eq 'soloist') && _arch();
    return 'in_flight'   if $lifecycleInFlight;

    my $archInfo = _arch();
    my $cand     = _scanManualDir();

    unless ($cand) {
        my $wasActive = ((placedState()->{status} // '') eq 'active');
        if ($wasActive) {
            main::INFOLOG && $log->is_info && $log->info(
                "Soloist: placed binary removed -- CDN renewal resumes");
        }
        # D-10: "keep nothing else" -- a full reset, not a merge, so a
        # stale signature/version from a since-removed file never lingers.
        _cache()->set('spoton_soloist_placed_state', { status => 'absent', checked_at => time() }, 'never');
        return 'absent';
    }

    my $existing = placedState();
    if ((($existing->{signature} // '') eq $cand->{signature})
            && $existing->{status} && $existing->{status} =~ /^(?:active|rejected|expired)$/) {
        return $existing->{status};    # T-83.3-23: unchanged file, already evaluated
    }

    _setLifecycleInFlight('placed');
    _setPlacedState(status => 'checking', signature => $cand->{signature});

    my $stagingDir = catdir(_cacheDir($archInfo), 'staging-manual');
    require File::Path;
    File::Path::remove_tree($stagingDir) if -d $stagingDir;
    File::Path::make_path($stagingDir, { mode => 0700 });

    my $finish = sub {
        my (%fields) = @_;
        File::Path::remove_tree($stagingDir) if -d $stagingDir;
        _setLifecycleInFlight(undef);
        _setPlacedState(%fields, checked_at => time());
    };

    my $staged;
    require File::Copy;
    if ($cand->{kind} eq 'archive') {
        my $copyDest = catfile($stagingDir, 'soloist-manual.tar.gz');
        unless (File::Copy::copy($cand->{path}, $copyDest)) {
            $finish->(status => 'rejected', reason => 'copy_failed');
            return 'started';
        }
        my ($canonical, $reason) = _extractArchive($copyDest, $stagingDir);
        unless ($canonical) {
            $finish->(status => 'rejected', reason => 'extract_failed:' . ($reason || 'unknown'));
            return 'started';
        }
        $staged = $canonical;
    }
    else {
        $staged = catfile($stagingDir, BINARY_NAME);
        unless (File::Copy::copy($cand->{path}, $staged)) {
            $finish->(status => 'rejected', reason => 'copy_failed');
            return 'started';
        }
        chmod(0755, $staged);
    }

    my $parsed = _versionProbe($staged);
    unless (defined $parsed) {
        $finish->(status => 'rejected', reason => 'version_unparsable');
        return 'started';
    }

    my $expected = expectedVersion();
    if (!defined $expected || _versionCompare($parsed, $expected) < 0) {
        $finish->(status => 'rejected', reason => 'below_minimum');
        return 'started';
    }

    my $ok = eval {
        _smokeTest($staged, sub {
            my ($smokeOk, $info) = @_;
            unless ($smokeOk) {
                $finish->(status => 'rejected', reason => ($info && $info->{reason}) || 'smoke_failed');
                return;
            }

            # D-10/WR-04 (83.3 plan 10): a placed candidate whose own
            # remaining lifetime is already <= RENEWAL_TRIGGER_DAYS counts
            # as absent -- reject it here rather than promoting it, so it
            # never blocks CDN renewal (_placedBinaryIsValid()'s D-09
            # guard) in its own last days. The candidate keeps its
            # signature in the state via $finish's merge, so the unchanged
            # file short-circuits to 'rejected' on the next tick (a file
            # that is not fresh enough today will not be fresher tomorrow).
            if (($info->{days} // 0) <= RENEWAL_TRIGGER_DAYS) {
                $finish->(status => 'rejected', reason => 'expires_soon:' . ($info->{days} // '?'));
                return;
            }

            my $promoted = _promoteCandidate($staged, {
                %{ $info || {} },
                reason => 'placed',
            });

            if ($promoted) {
                $finish->(
                    status      => 'active',
                    reason      => undef,
                    version     => $info->{version},
                    days        => $info->{days},
                    signature   => $cand->{signature},
                    activated_at => time(),
                );
            }
            else {
                $finish->(status => 'rejected', reason => 'promote_failed');
            }
        });
        1;
    };
    unless ($ok) {
        $log->warn("Soloist: placed-binary smoke test raised an exception: " . ($@ || 'unknown error'));
        $finish->(status => 'rejected', reason => 'smoke_exception');
    }

    return 'started';
}

# _placedBinaryIsValid() -- true iff the placed binary is currently active
# AND is the binary actually installed (generation record reason 'placed')
# AND still has MORE than RENEWAL_TRIGGER_DAYS remaining lifetime -- the
# SAME freshness threshold (D-01) the CDN renewal path applies to itself,
# so a placed binary in its own last RENEWAL_TRIGGER_DAYS days never blocks
# renewal (D-09/D-10, WR-04, 83.3 plan 10, corrected plan 12). This
# threshold alone is what un-blocks renewal in that window -- unlike plan
# 10, checkRenewalDue() no longer flips the placed STATUS at this same
# threshold (WR-04/gap-closure round 2), so the status stays 'active' (and
# the settings hint keeps rendering) for the whole window while this check
# already lets renewal through underneath it. A placed binary rolled back
# by rollbackToPrevious() (D-07) no longer counts (status flips to
# 'rejected' there). Consumed by renewBinary()'s D-09 guard above.
sub _placedBinaryIsValid {
    my $state = placedState();
    return 0 unless (($state->{status} // '') eq 'active');

    my $gen = _cache()->get('spoton_soloist_generation') || {};
    return 0 unless (($gen->{reason} // '') eq 'placed');

    return ((expiryDaysRemaining() // 0) > RENEWAL_TRIGGER_DAYS) ? 1 : 0;
}

# noteActiveBinaryExpired() -- called by DaemonManager's
# _handleSoloistBuildExpiry BEFORE its checkRenewalDue() call (83.3 plan 08:
# no longer a direct renewBinary(reason=>'exit10')) (D-10): an exit-10
# placed binary must stop blocking renewal in the SAME handling pass that
# escalates the expiry, not on the next 60s tick.
sub noteActiveBinaryExpired {
    my $gen = _cache()->get('spoton_soloist_generation') || {};
    if (($gen->{reason} // '') eq 'placed') {
        _setPlacedState(status => 'expired', reason => 'exit_10');
    }
    _cache()->set('spoton_soloist_expiry_days', { days => 0, checked_at => time() }, 'never');
}

# ---------------------------------------------------------------------------
# Auto-patch (Phase 74, D-03) -- runs spoton-helper exactly once after a
# successful, version-matched download+activation. Idempotent (probes
# `check` first, mirroring Helper.pm's --check JSON-consumption pattern) and
# fail-open: any failure to complete the patch leaves Soloist running
# unpatched with a warning, never blocking core playback (T-74-10). The raw
# spak-key is never involved here and binary contents are never logged.
# ---------------------------------------------------------------------------

# _helperPath() -- basedir/Bin/<bindir>/spoton-helper, exactly the pattern
# libPath() uses for the fake-libpulse dir (same @ARCH_MAP bindir value,
# same runtime require to avoid the Plugin.pm <-> Soloist.pm compile-time
# cycle -- WR-05). Returns undef when the arch is unknown or the helper
# binary is absent/non-executable -- callers treat that as "nothing to do".
sub _helperPath {
    my $archInfo = _arch();
    return undef unless $archInfo;

    require Plugins::SpotOn::Plugin;
    my $candidate = catfile(
        Plugins::SpotOn::Plugin->_pluginDataFor('basedir'), 'Bin', $archInfo->{bindir}, 'spoton-helper'
    );

    return (-f $candidate && -x $candidate) ? $candidate : undef;
}

# _runHelperJson($helper, @args) -- array-form open('-|', ...), never an
# interpolated shell string (T-74-09 -- the project's raw spak-key
# discipline extends to any subprocess invocation, contrast
# Helper.pm::helperCheck()'s pre-existing backtick debt, which this module
# deliberately does not repeat). Returns the decoded JSON hashref on
# success, or undef on any failure (missing binary, unparsable/empty
# output, malformed JSON) -- never dies.
sub _runHelperJson {
    my ($helper, @args) = @_;

    my $output = '';
    my $ok = eval {
        open(my $fh, '-|', $helper, @args) or die "open failed: $!\n";
        local $/;
        $output = <$fh> // '';
        close($fh);
        1;
    };

    unless ($ok) {
        $log->warn("Soloist: spoton-helper invocation failed: $@");
        return undef;
    }

    return undef unless length $output;

    my $decoded = eval { from_json($output) };
    return ($decoded && ref($decoded) eq 'HASH') ? $decoded : undef;
}

# _autoPatch($soloistPath) -- D-03: patch a freshly activated, version-
# matched Soloist binary exactly once. Never dies; on any incomplete/failed
# patch, Soloist keeps running unpatched with a warning (fail-open, T-74-10).
# T-74-11: only ever called with an already version-matched, activated
# binary path (see _onSoloistDownloadDone) -- the helper re-gates on version
# internally as a second line of defense.
sub _autoPatch {
    my ($soloistPath) = @_;

    my $helper = _helperPath() or return;    # no helper shipped for this arch -- nothing to do

    my $expected = expectedVersion();
    return unless defined $expected;

    # 1. Idempotency probe (D-03): skip if already patched.
    my $status = _runHelperJson($helper, 'check', '--binary', $soloistPath);
    return if $status && $status->{patched};

    # 2. Patch (version-gated inside the helper too, T-74-11).
    my $result = _runHelperJson($helper, 'patch',
        '--version', $expected, '--binary', $soloistPath);

    unless ($result && $result->{patched}) {
        # Non-fatal: Soloist still runs unpatched (fail-open for core playback).
        $log->warn("Soloist: auto-patch did not complete -- running unpatched");
    }

    return;
}

# ---------------------------------------------------------------------------
# spak-key storage (Pattern 3, D-10/D-11) -- the raw key is NEVER logged.
# ---------------------------------------------------------------------------

sub storeKey {
    my ($class, $key) = @_;

    return (0, 'empty_key') unless defined $key && length $key;

    my $dir = _rootDir();
    unless (-d $dir) {
        require File::Path;
        File::Path::make_path($dir, { mode => 0700 });
    }

    my $target = keyPath();
    my ($fh, $staging) = File::Temp::tempfile('spak-XXXX', DIR => $dir, UNLINK => 0);
    unless ($fh) {
        $log->error('Soloist: failed to create staging file for spak-key');
        return (0, 'write_failed');
    }
    # WR-06: check both print and close -- on a full disk or I/O error
    # either can fail, and an unchecked failure previously let a
    # truncated/empty staging file get renamed over any existing valid
    # key while storeKey() still reported success (hasKey() then
    # returns true for a corrupt credential file with no breadcrumb).
    unless (print $fh $key) {
        my $err = $!;
        close $fh;
        unlink $staging;
        $log->error("Soloist: failed writing spak-key staging file: $err");
        return (0, 'write_failed');
    }
    unless (close $fh) {
        my $err = $!;
        unlink $staging;
        $log->error("Soloist: failed closing spak-key staging file: $err");
        return (0, 'write_failed');
    }

    unlink $target if -f $target;
    unless (rename($staging, $target)) {
        require File::Copy;
        unless (File::Copy::move($staging, $target)) {
            $log->error('Soloist: failed to install spak-key: ' . $!);
            return (0, 'write_failed');
        }
    }
    chmod(0600, $target) if -f $target;

    return 1;
}

sub hasKey {
    return -f keyPath() ? 1 : 0;
}

sub clearKey {
    my $path = keyPath();
    unlink $path if -f $path;
    return 1;
}

# ---------------------------------------------------------------------------
# Phase 73: per-player storage (D-01/D-02) + key access for SoloistDaemon.
# ---------------------------------------------------------------------------

# dataDirForClient($mac) / cacheDirForClient($mac) -- one data-dir and one
# cache-dir per player under players/<mac>/, distinct from the Phase-72
# shared dataDir()/launcher machinery (retired in 73-04, no lock interaction).
# Sharing or cloning a data-dir across players is the documented anti-pattern
# (lock collision / device_id collision, RESEARCH Anti-Patterns) -- each
# player pairs itself via app tap (D-07).
sub dataDirForClient {
    my ($mac) = @_;
    (my $clean = $mac || '') =~ s/://g;
    return catdir(_rootDir(), 'players', $clean, 'data');
}

sub cacheDirForClient {
    my ($mac) = @_;
    (my $clean = $mac || '') =~ s/://g;
    return catdir(_rootDir(), 'players', $clean, 'cache');
}

# isPairedForClient($mac) -- checks dataDirForClient($mac)/settings/Users/
# for at least one non-dot entry. Verified against a real paired daemon
# (§ S-10, 2026-09-04): a paired session writes settings/Users/<user>/{prefs,
# cached,offline_*,...} inside the per-player data dir. A never-paired
# daemon's own startup artefacts (.device_id, .lock, cache/, crashpad/,
# soloist.pid, ws.addr, ws.port) never include settings/ at all -- confirmed
# by a fresh handstart left running 60s with no pairing (§ S-10 Leer-Ordner-
# Probe). The prior heuristic ("any non-dot entry in the data dir") counted
# those startup artefacts as a paired session -- a false positive (§ S-10
# isPairedForClient-Ersatz table: 1/1/1 for [paired, paired, never-paired]
# vs. the correct 1/1/0 this replacement measures).
#
# Validity boundary (not measured by § S-10, carried forward rather than
# smoothed over): whether settings/Users/ persists once a paired session has
# expired server-side is unknown -- only three folder states were checked
# (never paired, paired via app tap x2), not "paired, then expired".
sub isPairedForClient {
    my ($mac) = @_;
    my $users = catdir(dataDirForClient($mac), 'settings', 'Users');
    return 0 unless -d $users;

    opendir(my $dh, $users) or return 0;
    my @entries = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir($dh);

    return scalar(@entries) ? 1 : 0;
}

# readKey() -- slurp keyPath(), chomp trailing whitespace, undef unless
# non-empty. The raw key is NEVER logged (T-71 discipline); callers pass it
# to SoloistDaemon's -k argv -- the /proc/cmdline exposure is the unchanged
# ACCEPTED RISK WR-01 (no env/stdin alternative exists in soloist 1.3.7.489).
sub readKey {
    my $path = keyPath();
    return undef unless -f $path;

    my $key = eval {
        open(my $fh, '<', $path) or die "open failed: $!";
        local $/;
        my $data = <$fh>;
        close($fh);
        $data;
    };
    return undef if $@ || !defined $key;

    $key =~ s/\s+\z//;
    return length($key) ? $key : undef;
}

# ensureWsLib() -- D-08 (user decision, replaces the RESEARCH Open Question 3
# runtime gate): prefer an LMS-bundled Protocol::WebSocket::Client (9.1+),
# fall back to the vendored copy under Plugins/SpotOn/Vendor/ (pure Perl,
# Perl >= 5.10-clean, no XS -- Artistic/GPL dual per RESEARCH Package
# Legitimacy Audit). Never dies. Soloist Connect thus works on any LMS 8.0+
# install -- there is no soloist_missing_wslib prereq state.
sub ensureWsLib {
    return 1 if eval { require Protocol::WebSocket::Client; 1 };

    require Plugins::SpotOn::Plugin;
    my $vendorDir = catdir(Plugins::SpotOn::Plugin->_pluginDataFor('basedir'), 'Vendor');

    # push, NOT unshift -- an LMS-bundled copy (if one appears later in this
    # process's lifetime) must always win over the vendored fallback.
    push @INC, $vendorDir unless grep { $_ eq $vendorDir } @INC;

    return eval { require Protocol::WebSocket::Client; 1 } ? 1 : 0;
}

1;

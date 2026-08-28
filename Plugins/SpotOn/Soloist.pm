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
# SOLOIST_VERSION is a record of "the version we downloaded and validated",
# NOT a URL parameter -- Spotify's download endpoint is unversioned
# (RESEARCH.md Pitfall 1). A binary that reports a different version after
# download is never activated (D-05, fail-closed).

use strict;
use warnings;
use File::Spec::Functions qw(catdir catfile);
use File::Temp ();
use JSON::XS::VersionOneAndTwo;

use Slim::Utils::Log;
use Slim::Utils::OSDetect;
use Slim::Utils::Prefs;
use Slim::Networking::SimpleAsyncHTTP;

# D-05: validated 2026-08-25 against a real download (x86_64) --
# `soloist --version` => "soloist 1.3.7.489 build 1787637711 (20260825)
# (gb24005ef46) (linux/x86_64)". One-way pin: a version change here requires
# revalidating all downstream patches (Lifetime, 24-bit -- Phase 74).
use constant SOLOIST_VERSION => '1.3.7.489';
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

    return catdir(Plugins::SpotOn::Plugin->_pluginDataFor('basedir'), 'Bin', 'fake-libpulse');
}

# ---------------------------------------------------------------------------
# Binary discovery + version check (Pattern 1)
# ---------------------------------------------------------------------------

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

# Array-form open('-|', ...) -- never a shell string/backtick (RESEARCH.md
# Anti-Patterns; contrast with Helper.pm::helperCheck()'s pre-existing debt).
sub _versionCheck {
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
        return 0;
    }

    # e.g. "soloist 1.3.7.489 build 1787637711 (20260825) (gb24005ef46) (linux/x86_64)"
    if ($output =~ /^soloist\s+([\d.]+)/i) {
        my $parsedVersion = $1;

        if (_versionCompare($parsedVersion, SOLOIST_VERSION) != 0) {
            $log->warn("Soloist: binary reports version $parsedVersion, expected "
                . SOLOIST_VERSION . " -- not activating (D-05/Pitfall 1)");
            return 0;
        }

        $version = $parsedVersion;

        # 73-02 Pitfall 7: self-heal DaemonManager's build-expiry escalation
        # -- a binary that just passed activation validation here is not
        # (yet) known to be an expired one; clearing on every successful
        # activation means a re-downloaded/replaced copy of the pinned
        # version un-parks the daemon without any manual cache-flush step.
        # One cache write, no daemon restart triggered from here --
        # DaemonManager's own initHelpers/60s watchdog picks it up next cycle.
        eval {
            require Slim::Utils::Cache;
            require Plugins::SpotOn::Plugin;
            Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION())
                ->remove('spoton_soloist_expired');
            1;
        };

        return 1;
    }

    $log->warn("Soloist: unexpected --version output (" . length($output) . " bytes)");
    return 0;
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

    # T-71-04: array-form system(), never an interpolated shell string.
    my $rc = system('tar', 'xzf', $archivePath, '-C', $destDir);
    unlink $archivePath;

    if ($rc != 0) {
        $log->warn("Soloist: tar extraction failed (rc=$rc)");
        return;
    }

    # A3: archive is flat (confirmed empirically), but search recursively as
    # a defensive fallback in case a future build nests the binary.
    my $extracted = _findExtractedBinary($destDir);
    unless ($extracted) {
        $log->warn("Soloist: no '" . BINARY_NAME . "' binary found after extraction");
        return;
    }

    chmod(0755, $extracted);

    my $canonical = catfile($destDir, BINARY_NAME);
    if ($extracted ne $canonical) {
        require File::Copy;
        unless (File::Copy::move($extracted, $canonical)) {
            $log->warn("Soloist: failed to move extracted binary into place: $!");
            return;
        }
        chmod(0755, $canonical);
    }

    # Fail-closed: only activate on a matching post-download version check.
    if (_versionCheck($canonical)) {
        $binary = $canonical;
        main::INFOLOG && $log->is_info && $log->info(
            "Soloist: binary activated, version " . ($version || '?'));

        # D-03: patch only an activated, version-matched binary.
        _autoPatch($canonical);
    } else {
        $log->warn("Soloist: downloaded binary failed version check -- not activated (fail-closed)");
    }
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

    # 1. Idempotency probe (D-03): skip if already patched.
    my $status = _runHelperJson($helper, 'check', '--binary', $soloistPath);
    return if $status && $status->{patched};

    # 2. Patch (version-gated inside the helper too, T-74-11).
    my $result = _runHelperJson($helper, 'patch',
        '--version', SOLOIST_VERSION, '--binary', $soloistPath);

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

# isPairedForClient($mac) -- heuristic: dataDirForClient($mac) exists and has
# at least one non-dot entry. Soloist stores its paired session under
# settings/Users/ inside that per-player data dir; the exact filename it
# writes on a successful app-tap pairing (D-07) is unverified (RESEARCH A3),
# so presence-of-any-file is the best available signal without
# over-specifying Soloist's internal storage format -- the same non-dot-entry
# heuristic the retired Phase-72 dataDir()/isPaired() pair used, now applied
# per player instead of to the single shared dir.
sub isPairedForClient {
    my ($mac) = @_;
    my $dir = dataDirForClient($mac);
    return 0 unless -d $dir;

    opendir(my $dh, $dir) or return 0;
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

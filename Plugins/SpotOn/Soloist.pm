package Plugins::SpotOn::Soloist;

# Structural twin of Helper.pm (D-02), but Soloist is auto-downloaded into the
# LMS cachedir (D-03/D-04) rather than shipped inside the plugin zip -- get()
# constructs the expected cachedir path directly and never uses
# Slim::Utils::Misc::findbin() for *binary discovery* (RESEARCH.md
# Anti-Patterns). Phase 72: addFindBinPaths() IS now called by
# ensureLauncher() -- purely so the static `[spoton-soloist]` token in
# custom-convert.conf can resolve the generated wrapper script; it plays no
# role in locating the soloist binary itself, which stays cachedir-path-based.
#
# SOLOIST_VERSION is a record of "the version we downloaded and validated",
# NOT a URL parameter -- Spotify's download endpoint is unversioned
# (RESEARCH.md Pitfall 1). A binary that reports a different version after
# download is never activated (D-05, fail-closed).

use strict;
use warnings;
use File::Spec::Functions qw(catdir catfile);
use File::Temp ();

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

# Phase 72 (D-01/D-02/D-03): the generated per-track launcher wrapper
# referenced by the `[spoton-soloist]` findbin token in custom-convert.conf.
use constant LAUNCHER_NAME   => 'spoton-soloist';

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

    return catdir(Plugins::SpotOn::Plugin->_pluginDataFor('basedir'), 'Bin', $archInfo->{bindir});
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
        return 1;
    }

    $log->warn("Soloist: unexpected --version output (" . length($output) . " bytes)");
    return 0;
}

sub _versionCompare {
    my ($v1, $v2) = @_;
    my @a = split /\./, $v1;
    my @b = split /\./, $v2;
    for my $i (0 .. $#b) {
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

    # Phase 72 Pitfall 5: the launcher lives in cachedir and dies with a
    # cache-clear -- regenerate unconditionally and cheaply on every call
    # (ensureBinary() is already invoked from the Settings save path
    # whenever backend=soloist, covering mid-run cache-clears).
    ensureLauncher();

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
# Phase 72: per-track launcher generator (RESEARCH Pattern 3, D-01..D-06)
# ---------------------------------------------------------------------------

# dataDir() -- the persistent --data-dir that holds paired credentials
# (RESEARCH A3). THE single canonical data-dir; any future `--pair`
# invocation (manual or Settings-driven, Phase 73) must target this path.
sub dataDir {
    return catdir(_rootDir(), 'data');
}

# isPaired() -- heuristic: dataDir() exists and has at least one non-dot
# entry. NOTE: the exact credential filename Soloist writes on `--pair` is
# unverified (RESEARCH A3), so presence-of-any-file is the best available
# signal without over-specifying Soloist's internal storage format.
sub isPaired {
    my $dir = dataDir();
    return 0 unless -d $dir;

    opendir(my $dh, $dir) or return 0;
    my @entries = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir($dh);

    return scalar(@entries) ? 1 : 0;
}

sub launcherPath {
    return catfile(_rootDir(), LAUNCHER_NAME);
}

# _launcherScript($lib, $key, $binary, $data)
# Builds the wrapper script body. Non-interpolating single-quoted heredoc --
# every shell variable ($KEY/$@/$rc/$n/$start/$now/${LD_LIBRARY_PATH}) stays
# completely literal; only these four Perl-computed paths are substituted
# via a plain placeholder replace (no sprintf %-escaping surprises against
# the shell's own `date +%s`).
sub _launcherScript {
    my ($lib, $key, $binary, $data) = @_;

    my $tmpl = <<'SCRIPT';
#!/bin/sh
# Generated by Plugins::SpotOn::Soloist::ensureLauncher() -- regenerated
# idempotently on every LMS start (Phase 72, RESEARCH Pitfall 5). Do not
# edit by hand; changes will be overwritten.
export LD_LIBRARY_PATH="__LIB__:${LD_LIBRARY_PATH}"
export SPOTON_SOLOIST_PCM_FD=1
KEY=$(cat "__KEY__") || exit 1

# D-06: up to 2 quick-failure retries before letting LMS advance/skip.
# PCM may already have started flowing on a slow failure (>=5s) -- retrying
# then would splice duplicated/misaligned audio, so a slow failure exits
# immediately with its own code instead of retrying.
n=0
while [ "$n" -lt 2 ]; do
    start=$(date +%s)
    "__BIN__" -n "SpotOn" -k "$KEY" -D "__DATA__" "$@"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        exit 0
    fi
    now=$(date +%s)
    elapsed=$((now - start))
    if [ "$elapsed" -ge 5 ]; then
        exit "$rc"
    fi
    n=$((n + 1))
    sleep 2
done

# Final attempt: exec so LMS's process management sees soloist directly.
exec "__BIN__" -n "SpotOn" -k "$KEY" -D "__DATA__" "$@"
SCRIPT

    $tmpl =~ s/__LIB__/$lib/g;
    $tmpl =~ s/__KEY__/$key/g;
    $tmpl =~ s/__BIN__/$binary/g;
    $tmpl =~ s/__DATA__/$data/g;

    return $tmpl;
}

# ensureLauncher() -- idempotent wrapper generator + findbin registration.
# Called on every LMS start (Plugin.pm initPlugin) and from ensureBinary()
# (mid-run cache-clears). Cheap and safe to call repeatedly.
sub ensureLauncher {
    # A5: POSIX sh is safe -- Soloist is Linux-only (_arch() returns undef
    # on Windows/macOS, which also covers the ISWINDOWS/ISMAC guard here).
    return if main::ISWINDOWS || main::ISMAC;

    my $archInfo = _arch();
    return unless $archInfo;

    require File::Path;
    File::Path::make_path(_rootDir(), { mode => 0700 }) unless -d _rootDir();
    File::Path::make_path(dataDir(),  { mode => 0700 }) unless -d dataDir();

    # Register the launcher dir for convert-rule token resolution: the
    # static `[spoton-soloist]` token in custom-convert.conf cannot resolve
    # without this. findbin is still never used for *binary discovery*
    # (Anti-Pattern, see module header) -- it IS now used so this one static
    # convert-rule token resolves (mirrors Helper.pm's init() pattern).
    require Slim::Utils::Misc;
    Slim::Utils::Misc::addFindBinPaths(_rootDir());

    # Computed deterministically (NOT via get()) so the wrapper can be
    # written before the first download completes -- paths are stable; a
    # missing binary just makes the wrapper exit non-zero, absorbed by the
    # D-06 retry/skip path.
    my $binaryPath = catfile(_cacheDir($archInfo), BINARY_NAME);
    my $lib        = libPath();
    my $key        = keyPath();
    my $data       = dataDir();

    return unless defined $lib;

    my $script = _launcherScript($lib, $key, $binaryPath, $data);
    my $target = launcherPath();

    # Atomic write (mirrors storeKey()): stage via File::Temp, then rename.
    my ($fh, $staging) = File::Temp::tempfile('spoton-soloist-XXXX', DIR => _rootDir(), UNLINK => 0);
    unless ($fh) {
        $log->error('Soloist: failed to create staging file for launcher');
        return;
    }
    unless (print $fh $script) {
        my $err = $!;
        close $fh;
        unlink $staging;
        $log->error("Soloist: failed writing launcher staging file: $err");
        return;
    }
    unless (close $fh) {
        my $err = $!;
        unlink $staging;
        $log->error("Soloist: failed closing launcher staging file: $err");
        return;
    }

    unlink $target if -f $target;
    unless (rename($staging, $target)) {
        require File::Copy;
        unless (File::Copy::move($staging, $target)) {
            $log->error('Soloist: failed to install launcher: ' . $!);
            return;
        }
    }
    chmod(0755, $target) if -f $target;

    return 1;
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

1;

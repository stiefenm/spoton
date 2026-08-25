package Plugins::SpotOn::Soloist;

# Structural twin of Helper.pm (D-02), but Soloist is auto-downloaded into the
# LMS cachedir (D-03/D-04) rather than shipped inside the plugin zip -- get()
# constructs the expected cachedir path directly and never uses
# Slim::Utils::Misc::findbin()/addFindBinPaths() (RESEARCH.md Anti-Patterns).
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

my $prefs       = preferences('plugin.spoton');
my $serverPrefs = preferences('server');
my $log         = logger('plugin.spoton');

my ($binary, $version);

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
    return if get();    # already have a working, version-matched binary

    my $archInfo = _arch();
    return unless $archInfo;

    downloadBinary($archInfo);
}

sub downloadBinary {
    my ($archInfo) = @_;
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

    Slim::Networking::SimpleAsyncHTTP->new(
        sub { _onSoloistDownloadDone(shift, $archivePath, $destDir) },
        sub { my ($http, $error) = @_; _onSoloistDownloadError($http, $error, $archivePath) },
        { saveAs => $archivePath, timeout => 30 },
    )->get($url);
}

sub _onSoloistDownloadDone {
    my ($http, $archivePath, $destDir) = @_;

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
    print $fh $key;
    close $fh;

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

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

use Slim::Utils::Log;
use Slim::Utils::Prefs;

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

1;

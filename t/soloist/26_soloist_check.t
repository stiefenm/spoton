#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use File::Spec::Functions qw(catdir catfile);

# Resolve project root (t/<group>/x.t sits two levels below it)
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

my $module = "$project_dir/Plugins/SpotOn/Soloist.pm";
unless (-f $module) {
    die "Plugins/SpotOn/Soloist.pm not yet present in this checkout -- wrong project root or broken checkout (84-09: die, never skip)\n";
}

# skip gracefully if system `tar` is not available -- mirrors t/06's
# skip-if-absent pattern (RESEARCH.md Validation Architecture); only the
# download-pipeline tests below need it.
unless (`tar --version 2>&1` && $? == 0) {
    die "system tar not available -- required for extraction tests (84-09: die, never skip)\n";
}

my $stub_dir  = tempdir(CLEANUP => 1);
my $cache_dir = tempdir(CLEANUP => 1);

sub write_stub {
    my ($dir, $pkg, $code) = @_;
    my @parts = split /::/, $pkg;
    my $file  = pop @parts;
    my $path  = $dir . '/' . join('/', @parts);
    make_path($path) unless -d $path;
    open(my $fh, '>', "$path/$file.pm") or die "Cannot write stub $pkg: $!";
    print $fh $code;
    close($fh);
}

# ============================================================
# LMS Module Stubs required by Soloist.pm
# ============================================================

write_stub($stub_dir, 'Log::Log4perl::Logger', <<'END');
package Log::Log4perl::Logger;
sub new { bless {}, shift }
sub AUTOLOAD { }
sub can { 1 }
1;
END

write_stub($stub_dir, 'Log::Log4perl', <<'END');
package Log::Log4perl;
sub get_logger { return bless {}, 'Log::Log4perl::Logger' }
sub init { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
use parent 'Exporter';
our @EXPORT_OK = qw(logger);
our @logged = ();
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub addLogCategory { return bless {}, 'Slim::Utils::Log' }
sub logger { return bless {}, 'Slim::Utils::Log' }
sub info  { push @logged, $_[1] if defined $_[1]; }
sub warn  { push @logged, $_[1] if defined $_[1]; }
sub error { push @logged, $_[1] if defined $_[1]; }
sub debug { push @logged, $_[1] if defined $_[1]; }
sub is_info  { 1 }
sub is_debug { 0 }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# preferences('server')->get('cachedir') returns a real tempdir so Soloist.pm
# actually writes/reads files under it (mirrors t/16_credentials.t).
my $prefs_cache_dir = $cache_dir;
write_stub($stub_dir, 'Slim::Utils::Prefs', <<"END");
package Slim::Utils::Prefs;
my \%_store;
my \%_ns_store = ( server => { cachedir => '$prefs_cache_dir' } );
my \%_change_cbs;   # { ns }{ key } => [ coderefs ] -- setChange() invalidation support

sub import {
    my \$class = shift;
    my \$caller = caller;
    no strict 'refs';
    *{"\${caller}::preferences"} = \\\&preferences;
}

sub preferences {
    my \$ns = \$_[0] eq 'Slim::Utils::Prefs' ? \$_[1] : \$_[0];
    return bless { _ns => \$ns }, 'Slim::Utils::Prefs';
}

sub get {
    my (\$self, \$key) = \@_;
    if (exists \$_ns_store{ \$self->{_ns} }) {
        return \$_ns_store{ \$self->{_ns} }{\$key};
    }
    return \$_store{ \$self->{_ns} }{\$key};
}

sub set {
    my (\$self, \$key, \$val) = \@_;
    \$_store{ \$self->{_ns} }{\$key} = \$val;
    if (\$_change_cbs{ \$self->{_ns} }{\$key}) {
        \$_->(\$self, \$val) for \@{ \$_change_cbs{ \$self->{_ns} }{\$key} };
    }
}

sub client { return bless { _ns => \$_[0]->{_ns} . '_client' }, 'Slim::Utils::Prefs' }

sub setChange {
    my (\$self, \$cb, \$key) = \@_;
    push \@{ \$_change_cbs{ \$self->{_ns} }{\$key} }, \$cb;
}

sub AUTOLOAD  { }
1;
END

# Configurable osArch (package-global, settable per-test) -- lets one test
# process exercise all three arch branches without reloading the module.
write_stub($stub_dir, 'Slim::Utils::OSDetect', <<'END');
package Slim::Utils::OSDetect;
our $osArch = 'x86_64';
sub details { return { osArch => $osArch } }
sub OS      { 'unix' }
sub getOS   { return bless {}, 'Slim::Utils::OSDetect' }
1;
END

# Controllable SimpleAsyncHTTP stub: records every ->new()/->get() call and
# supports synchronous cb/ecb invocation via $auto_mode, so download tests
# never touch the real network (RESEARCH.md "Don't Hand-Roll").
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
our @created   = ();
our $auto_mode  = 'none';   # none | success | error
our $auto_error = 'simulated network error';

sub new {
    my ($class, $cb, $ecb, $opts) = @_;
    my $self = bless { cb => $cb, ecb => $ecb, opts => $opts }, $class;
    push @created, $self;
    return $self;
}
sub get {
    my ($self, $url) = @_;
    $self->{url} = $url;
    if ($auto_mode eq 'success') {
        $self->{cb}->($self);
    } elsif ($auto_mode eq 'error') {
        $self->{ecb}->($self, $auto_error);
    }
    return;
}
sub content { '' }
sub reset_stub { @created = (); $auto_mode = 'none'; }
1;
END

# Phase 73 (D-03 completion): the Phase-72 per-track launcher (and its
# Slim::Utils::Misc::addFindBinPaths() registration) is retired -- ensureBinary()
# no longer calls ensureLauncher() at all, so no Slim::Utils::Misc stub is
# needed here anymore. Plugins::SpotOn::Plugin->_pluginDataFor('basedir') is
# still read by libPath(), so keep that stub.
write_stub($stub_dir, 'Plugins::SpotOn::Plugin', <<'END');
package Plugins::SpotOn::Plugin;
sub _pluginDataFor { return 'test-basedir' }
1;
END

# Phase 74: Soloist.pm now `use`s JSON::XS::VersionOneAndTwo (auto-patch
# JSON parsing) -- stub it so `require Plugins::SpotOn::Soloist` still
# loads in this sandbox (delegates to JSON::PP, mirrors t/07/t/09/etc.).
write_stub($stub_dir, 'JSON::XS::VersionOneAndTwo', <<'END');
package JSON::XS::VersionOneAndTwo;
use parent 'Exporter';
our @EXPORT = qw(from_json to_json);
use JSON::PP ();
sub from_json { JSON::PP::decode_json($_[0]) }
sub to_json   { JSON::PP::encode_json($_[0]) }
1;
END

# ============================================================
# main:: constants
# ============================================================
BEGIN {
    no warnings 'redefine';
    *main::TRANSCODING = sub () { 0 };
    *main::WEBUI       = sub () { 0 };
    *main::SCANNER     = sub () { 0 };
    *main::INFOLOG     = sub () { 0 };
    *main::ISWINDOWS   = sub () { 0 };
    *main::ISMAC       = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
}

unshift @INC, $stub_dir, $project_dir;

require Slim::Utils::Prefs;
Slim::Utils::Prefs->import();
require Slim::Utils::Log;
Slim::Utils::Log->import();
require Slim::Utils::OSDetect;
require Slim::Networking::SimpleAsyncHTTP;

require_ok('Plugins::SpotOn::Soloist')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Soloist");

# Register the 'backend' pref-change invalidation callback once (mirrors
# real LMS startup calling Soloist->init()).
Plugins::SpotOn::Soloist::init();

my $reset_counter = 0;

# Resets the mocked osArch AND Soloist.pm's module-level ($binary, $version)
# cache -- the latter via a real 'backend' pref-change, exactly the
# invalidation path Soloist->init() wires up.
sub reset_all {
    Slim::Networking::SimpleAsyncHTTP::reset_stub();
    $Slim::Utils::OSDetect::osArch = 'x86_64';
    preferences('plugin.spoton')->set('backend', 'reset-' . $reset_counter++);
}

# Writes an executable shell-script "soloist" binary at $path whose --version
# output matches the real binary's format, reporting $reportedVersion.
sub write_fake_binary {
    my ($path, $reportedVersion) = @_;
    open(my $fh, '>', $path) or die "write_fake_binary: $!";
    print $fh "#!/bin/sh\n";
    print $fh "if [ \"\$1\" = '--version' ]; then\n";
    print $fh "  echo 'soloist $reportedVersion build 1787637711 (20260825) (gb24005ef46) (linux/x86_64)'\n";
    print $fh "  exit 0\n";
    print $fh "fi\n";
    print $fh "exit 1\n";
    close($fh);
    chmod(0755, $path);
}

# ============================================================
# Test 1-3: Arch-map -- osArch -> {download, bindir}
# ============================================================
{
    reset_all();

    my %cases = (
        'aarch64'  => { download => 'arm64',  bindir => 'aarch64-linux' },
        'armv7l'   => { download => 'arm32',  bindir => 'armhf-linux'  },
        'arm'      => { download => 'arm32',  bindir => 'armhf-linux'  },
        'x86_64'   => { download => 'x86_64', bindir => 'x86_64-linux' },
    );

    for my $osArch (sort keys %cases) {
        $Slim::Utils::OSDetect::osArch = $osArch;
        my $archInfo = Plugins::SpotOn::Soloist::_arch();
        is($archInfo->{download}, $cases{$osArch}{download}, "osArch '$osArch' -> download '$cases{$osArch}{download}'");
        is($archInfo->{bindir},   $cases{$osArch}{bindir},   "osArch '$osArch' -> bindir '$cases{$osArch}{bindir}'");
    }
}

# ============================================================
# Test 4: Download URL construction
# ============================================================
{
    reset_all();
    $Slim::Utils::OSDetect::osArch = 'x86_64';

    my $url = Plugins::SpotOn::Soloist::_downloadUrl();
    is($url, 'https://soloist-builds.spotifycdn.com/soloist_release_x86_64.tar.gz',
        'x86_64 download URL matches Spotify CDN host + filename convention');
}

# ============================================================
# Test 5: findbin() is never used at all (D-03 completion) -- the Phase-72
# addFindBinPaths() registration (the one and only caller) is retired along
# with the per-track launcher wrapper it existed to resolve.
# ============================================================
{
    my $src = do {
        local $/;
        open(my $fh, '<', "$project_dir/Plugins/SpotOn/Soloist.pm") or die $!;
        <$fh>;
    };
    (my $codeOnly = $src) =~ s/^\s*#.*$//mg;
    my $findbinHits = () = $codeOnly =~ /(?<!add)findbin\s*\(/gi;
    is($findbinHits, 0, 'Soloist.pm never calls findbin() for binary discovery (Anti-Pattern, cachedir-based discovery)');

    my $addFindBinHits = () = $codeOnly =~ /addFindBinPaths\s*\(/gi;
    is($addFindBinHits, 0, 'Soloist.pm no longer calls addFindBinPaths() anywhere (D-03: findbin is again unused entirely)');
}

# ============================================================
# Test 6: Version-check uses array-form open, not backtick/shell-string
# ============================================================
{
    my $src = do {
        local $/;
        open(my $fh, '<', "$project_dir/Plugins/SpotOn/Soloist.pm") or die $!;
        <$fh>;
    };
    unlike($src, qr/`\$(?:checkCmd|candidate|binary)/, 'no backtick invocation of the Soloist binary');
    # 79-57 (GH #177): the probe forks with open('-|') and no command, and the
    # child execs the binary in list form (indirect object, never a shell),
    # so the loader's stderr can be merged into the read pipe.
    like($src, qr/open\(my \$fh, '-\|'\);/, "version check forks with open('-|') and no command (79-57)");
    like($src, qr/exec \{ \$candidate \} \$candidate, VERSION_FLAG;/, "version check execs the binary in list form, never a shell (79-57)");
}

# ============================================================
# Test 7: get() returns undef without crashing when no binary is cached
# ============================================================
{
    reset_all();
    $Slim::Utils::OSDetect::osArch = 'x86_64';

    my $got = eval { Plugins::SpotOn::Soloist::get() };
    ok(!$@, 'get() does not die when no binary is cached') or diag($@);
    ok(!defined($got), 'get() returns undef when no binary is present');
}

# ============================================================
# Test 8: get() picks up a valid, version-matched cached binary
# ============================================================
{
    reset_all();
    $Slim::Utils::OSDetect::osArch = 'x86_64';

    my $binDir = catdir($cache_dir, 'spoton', 'soloist', 'x86_64-linux');
    make_path($binDir);
    write_fake_binary(catfile($binDir, 'soloist'), '1.3.8.68');

    my $path = Plugins::SpotOn::Soloist::get();
    like($path, qr{x86_64-linux/soloist$}, 'get() resolves the cached, version-matched binary');
}

# ============================================================
# Test 9: a binary reporting a version NEWER than the pin activates (D-05
# lower bound, Phase 83.3 -- flipped from the pre-83.3 equality-pin refusal)
# ============================================================
{
    reset_all();
    $Slim::Utils::OSDetect::osArch = 'arm';

    my $binDir = catdir($cache_dir, 'spoton', 'soloist', 'armhf-linux');
    make_path($binDir);
    write_fake_binary(catfile($binDir, 'soloist'), '9.9.9.999');

    my ($path, $ver) = Plugins::SpotOn::Soloist::get();
    ok(defined($path), 'get() activates a binary reporting a version newer than the pin (D-05 lower bound)');
    is($ver, '9.9.9.999', 'get() records the newer, above-pin version');
}

# ============================================================
# Test 9b: a binary reporting a version BELOW the pin is still refused
# (D-05 lower bound still rejects on the low side)
# ============================================================
{
    reset_all();
    $Slim::Utils::OSDetect::osArch = 'arm';

    my $binDir = catdir($cache_dir, 'spoton', 'soloist', 'armhf-linux');
    make_path($binDir);
    write_fake_binary(catfile($binDir, 'soloist'), '1.3.8.1');

    my $path = Plugins::SpotOn::Soloist::get();
    ok(!defined($path), 'get() refuses to activate a binary reporting a version below the armhf pin (D-05 lower bound)');
}

# ============================================================
# Test 10: ensureBinary() does NOT re-download when a working binary exists
# ============================================================
{
    reset_all();
    $Slim::Utils::OSDetect::osArch = 'x86_64';

    my $binDir = catdir($cache_dir, 'spoton', 'soloist', 'x86_64-linux');
    make_path($binDir);
    write_fake_binary(catfile($binDir, 'soloist'), '1.3.8.68');

    Plugins::SpotOn::Soloist::ensureBinary();
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::created), 0,
        'ensureBinary() triggers no download when a working binary is already cached (D-04)');
}

# ============================================================
# Test 11: downloadBinary() refuses to overwrite an existing binary file
# even when it hasn't been version-validated by get() yet (D-04 structural)
# ============================================================
{
    reset_all();
    $Slim::Utils::OSDetect::osArch = 'aarch64';

    my $binDir = catdir($cache_dir, 'spoton', 'soloist', 'aarch64-linux');
    make_path($binDir);
    write_fake_binary(catfile($binDir, 'soloist'), '1.3.8.69');

    my $archInfo = { download => 'arm64', bindir => 'aarch64-linux' };
    Plugins::SpotOn::Soloist::downloadBinary($archInfo);
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::created), 0,
        'downloadBinary() skips download when a binary file already exists at the target path');
}

# ============================================================
# Test 12: full download pipeline -- saveAs -> tar extract -> version check
# -> activate, using a real tar.gz fixture (no network)
# ============================================================
{
    reset_all();
    $Slim::Utils::OSDetect::osArch = 'x86_64';

    my $destDir = catdir($cache_dir, 'download-pipeline', 'x86_64-linux');
    make_path($destDir);

    my $srcDir = tempdir(CLEANUP => 1);
    write_fake_binary(catfile($srcDir, 'soloist'), '1.3.8.68');

    my $archivePath = catfile($destDir, 'staged.tar.gz');
    my $rc = system('tar', 'czf', $archivePath, '-C', $srcDir, 'soloist');
    is($rc, 0, 'tar fixture created successfully') or diag("tar rc=$rc");

    my $fakeHttp = bless {}, 'Slim::Networking::SimpleAsyncHTTP';
    Plugins::SpotOn::Soloist::_onSoloistDownloadDone($fakeHttp, $archivePath, $destDir);

    ok(!-f $archivePath, 'archive is removed after extraction');
    my $canonical = catfile($destDir, 'soloist');
    ok(-f $canonical, 'extracted binary is placed at the canonical path');

    # _onSoloistDownloadDone() activates $binary in-process on a successful
    # version check -- get() must now return exactly that same path without
    # touching the filesystem again (proves activation flows into get()'s cache).
    my $path = Plugins::SpotOn::Soloist::get();
    is($path, $canonical, 'get() returns the just-activated, version-matched binary path');
}

# ============================================================
# Test 13: onError path leaves get() undef, without throwing
# ============================================================
{
    reset_all();
    $Slim::Utils::OSDetect::osArch = 'armv7l';

    my $archInfo = { download => 'arm32', bindir => 'armhf-linux' };
    no warnings 'once';
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error';

    my $ok = eval { Plugins::SpotOn::Soloist::downloadBinary($archInfo); 1 };
    ok($ok, 'downloadBinary() does not die when the download errors out') or diag($@);

    my $path = Plugins::SpotOn::Soloist::get();
    ok(!defined($path), 'get() remains undef after a failed download');
}

# ============================================================
# Test 14: activation is coupled to a successful version check (code
# assertion -- $binary is only assigned inside the version-ok branch)
# ============================================================
{
    my $src = do {
        local $/;
        open(my $fh, '<', "$project_dir/Plugins/SpotOn/Soloist.pm") or die $!;
        <$fh>;
    };
    like($src, qr/if \s* \( _versionCheck\(\$canonical\) \) \s* \{\s*\n\s*\$binary \s*=/x,
        'post-download activation ($binary = ...) is gated on a successful _versionCheck()');
}

# ============================================================
# Test 15: expectedVersion() resolves the pinned version per architecture
# (per-architecture pin table, keyed by @ARCH_MAP's bindir)
# ============================================================
{
    my %cases = (
        'x86_64'                        => '1.3.8.68',
        'x86_64-linux-gnu-thread-multi' => '1.3.8.68',
        'aarch64'                       => '1.3.8.69',
        'arm'                           => '1.3.8.69',
        'armv7l'                        => '1.3.8.69',
        'mips'                          => undef,
    );

    for my $osArch (sort keys %cases) {
        reset_all();
        $Slim::Utils::OSDetect::osArch = $osArch;
        is(Plugins::SpotOn::Soloist::expectedVersion(), $cases{$osArch},
            "expectedVersion() for osArch '$osArch'"
                . (defined($cases{$osArch}) ? " -> '$cases{$osArch}'" : ' -> undef (unknown architecture)'));
    }
}

# ============================================================
# Test 16: _versionCheck() stays fail-closed when there is no pin for the
# detected architecture, even when a binary is present and executable
# ============================================================
{
    reset_all();
    $Slim::Utils::OSDetect::osArch = 'mips';
    my $dir = tempdir(CLEANUP => 1);
    my $path = catfile($dir, 'soloist');
    write_fake_binary($path, '1.3.8.68');
    ok(!Plugins::SpotOn::Soloist::_versionCheck($path),
        '_versionCheck() refuses activation when the architecture has no pin at all');
}

{
    reset_all();
    $Slim::Utils::OSDetect::osArch = 'x86_64';
    my $dir = tempdir(CLEANUP => 1);
    my $path = catfile($dir, 'soloist');
    write_fake_binary($path, '1.3.7.489');
    ok(!Plugins::SpotOn::Soloist::_versionCheck($path),
        '_versionCheck() refuses the previously-live 1.3.7.489 binary under the new x86_64 pin');
}

{
    reset_all();
    $Slim::Utils::OSDetect::osArch = 'x86_64';
    my $dir = tempdir(CLEANUP => 1);
    my $path = catfile($dir, 'soloist');
    write_fake_binary($path, '1.3.8.68');
    ok(Plugins::SpotOn::Soloist::_versionCheck($path),
        '_versionCheck() activates the pinned 1.3.8.68 binary under the new x86_64 pin');
}

# ============================================================
# Test 17: _versionCheck() lower-bound cases on x86_64 -- newer activates,
# older is refused (D-05)
# ============================================================
{
    reset_all();
    $Slim::Utils::OSDetect::osArch = 'x86_64';
    my $dir = tempdir(CLEANUP => 1);
    my $path = catfile($dir, 'soloist');
    write_fake_binary($path, '1.3.8.69');
    ok(Plugins::SpotOn::Soloist::_versionCheck($path),
        '_versionCheck() activates a binary newer than the x86_64 pin (D-05 lower bound)');
}

{
    reset_all();
    $Slim::Utils::OSDetect::osArch = 'x86_64';
    my $dir = tempdir(CLEANUP => 1);
    my $path = catfile($dir, 'soloist');
    write_fake_binary($path, '1.3.8.67');
    ok(!Plugins::SpotOn::Soloist::_versionCheck($path),
        '_versionCheck() refuses a binary older than the x86_64 pin (D-05 lower bound)');
}

# ============================================================
# Test 18: _versionProbe() -- pure probe, returns the parsed version string
# or undef, without touching activation state
# ============================================================
{
    reset_all();
    my $dir = tempdir(CLEANUP => 1);
    my $path = catfile($dir, 'soloist');
    write_fake_binary($path, '1.3.8.68');
    is(Plugins::SpotOn::Soloist::_versionProbe($path), '1.3.8.68',
        '_versionProbe() returns the parsed version string from --version output');
}

{
    reset_all();
    my $dir = tempdir(CLEANUP => 1);
    my $path = catfile($dir, 'soloist');
    open(my $fh, '>', $path) or die "write failed: $!";
    print $fh "#!/bin/sh\nexit 1\n";
    close($fh);
    chmod(0755, $path);
    ok(!defined(Plugins::SpotOn::Soloist::_versionProbe($path)),
        '_versionProbe() returns undef when the binary exits without --version output');
}

# ============================================================
# Test 19 (79-57, GH #177): _versionProbeDetail() keeps the loader's stderr
# message. A binary the dynamic loader cannot start prints nothing on
# stdout; the reason names the missing library instead of
# version_unparsable. The fixture text is the real loader message of the
# unchanged soloist binary in debian:trixie-slim (79-57-DEVRUN.md).
# ============================================================
sub write_stderr_binary {
    my ($path, $stderrFile, $exit) = @_;
    open(my $fh, '>', $path) or die "write_stderr_binary: $!";
    print $fh "#!/bin/sh\n";
    print $fh "cat '$stderrFile' >&2\n";
    print $fh "exit $exit\n";
    close($fh);
    chmod(0755, $path);
}

my $loader_fixture = "$project_dir/t/fixtures/soloist-loader/libatomic-missing.stderr.txt";
my $glibc_fixture  = "$project_dir/t/fixtures/soloist-loader/glibc-too-old.stderr.txt";

{
    reset_all();
    my $dir = tempdir(CLEANUP => 1);
    my $path = catfile($dir, 'soloist');
    write_stderr_binary($path, $loader_fixture, 127);
    ok(Plugins::SpotOn::Soloist->can('_versionProbeDetail'),
        '79-57 #177: _versionProbeDetail() exists');
    my $d = Plugins::SpotOn::Soloist->can('_versionProbeDetail')
        ? Plugins::SpotOn::Soloist::_versionProbeDetail($path) : {};
    is($d->{reason}, 'missing_library:libatomic.so.1',
        '79-57 #177: the real loader message (exit 127) gives reason missing_library:libatomic.so.1');
    is($d->{soname}, 'libatomic.so.1', '79-57 #177: the detail names the soname');
    is($d->{exit}, 127, '79-57 #177: the detail keeps the exit status');
    ok(!defined $d->{version}, '79-57 #177: no version on a loader failure');
    ok(!defined(Plugins::SpotOn::Soloist::_versionProbe($path)),
        '79-57 #177: _versionProbe() keeps its contract (undef) on a loader failure');

    my $f = Plugins::SpotOn::Soloist->can('lastProbeFailure')
        ? Plugins::SpotOn::Soloist::lastProbeFailure() : undef;
    is(ref $f, 'HASH', '79-57 #177: lastProbeFailure() holds the failure');
    is($f && $f->{soname}, 'libatomic.so.1', '79-57 #177: lastProbeFailure() names the soname');
    is($f && $f->{package_hint}, 'libatomic1', '79-57 #177: lastProbeFailure() names the Debian package libatomic1');
    ok(scalar(grep { /libatomic\.so\.1/ && /libatomic1/ } @Slim::Utils::Log::logged),
        '79-57 #177: the warn line names the soname and the package');
    ok(!scalar(grep { /cannot open shared object file/ } @Slim::Utils::Log::logged),
        '79-57 T-79-240: the full loader stderr is never logged');

    # a successful probe clears the failure
    my $good = catfile($dir, 'soloist-good');
    write_fake_binary($good, '1.3.8.68');
    is(Plugins::SpotOn::Soloist::_versionProbe($good), '1.3.8.68', '79-57 #177: a good binary still parses');
    ok(!defined(Plugins::SpotOn::Soloist->can('lastProbeFailure')
        ? Plugins::SpotOn::Soloist::lastProbeFailure() : 'none'),
        '79-57 #177: a successful probe clears lastProbeFailure()');
}

{
    reset_all();
    my $dir = tempdir(CLEANUP => 1);
    my $path = catfile($dir, 'soloist');
    my $err = catfile($dir, 'gcc.err');
    open(my $eh, '>', $err) or die $!;
    print $eh "/s/soloist: error while loading shared libraries: libgcc_s.so.1: cannot open shared object file: No such file or directory\n";
    close $eh;
    write_stderr_binary($path, $err, 127);
    my $d = Plugins::SpotOn::Soloist->can('_versionProbeDetail')
        ? Plugins::SpotOn::Soloist::_versionProbeDetail($path) : {};
    is($d->{reason}, 'missing_library:libgcc_s.so.1', '79-57 #177: libgcc_s.so.1 is named as well');
    my $f = Plugins::SpotOn::Soloist->can('lastProbeFailure')
        ? Plugins::SpotOn::Soloist::lastProbeFailure() : undef;
    is($f && $f->{package_hint}, 'libgcc-s1', '79-57 #177: libgcc_s.so.1 maps to the Debian package libgcc-s1');
}

{
    reset_all();
    my $dir = tempdir(CLEANUP => 1);
    my $path = catfile($dir, 'soloist');
    open(my $fh, '>', $path) or die $!;
    print $fh "#!/bin/sh\necho 'this is not a version line'\nexit 0\n";
    close $fh;
    chmod 0755, $path;
    my $d = Plugins::SpotOn::Soloist->can('_versionProbeDetail')
        ? Plugins::SpotOn::Soloist::_versionProbeDetail($path) : {};
    is($d->{reason}, 'version_unparsable',
        '79-57 #177: garbage on stdout with exit 0 still reads version_unparsable');
    is($d->{exit}, 0, '79-57 #177: exit 0 is kept for the garbage case');
}

{
    reset_all();
    my $dir = tempdir(CLEANUP => 1);
    my $path = catfile($dir, 'soloist');
    write_fake_binary($path, '1.3.8.68');
    my $d = Plugins::SpotOn::Soloist->can('_versionProbeDetail')
        ? Plugins::SpotOn::Soloist::_versionProbeDetail($path) : {};
    is($d->{version}, '1.3.8.68', '79-57 #177: the success case gives the version in the detail');
    ok(!defined $d->{reason}, '79-57 #177: the success case has no reason');
}

# ============================================================
# Test 20 (79-57, GH #183): on a system whose glibc is below the floor the
# probe's warn line names the glibc reason, not only "unexpected --version
# output (0 bytes)". The fixture is the real stderr of the unchanged soloist
# in a Debian 12 image with libatomic1 (buildpack-deps:bookworm, exit 1).
# DaemonManager is not loaded in this harness; its soloistGlibcProblem() is
# stood in for by a test double (the real one is pinned in t/soloist/28).
# ============================================================
{
    no warnings 'once';
    our $GLIBC_PROBLEM;
    no strict 'refs';
    *{'Plugins::SpotOn::Unified::DaemonManager::soloistGlibcProblem'} = sub { $GLIBC_PROBLEM };
}
{
    reset_all();
    local $main::GLIBC_PROBLEM = 'Soloist cannot run on this system: glibc 2.36 found, Soloist needs glibc 2.38 or newer (Raspberry Pi OS Trixie / Debian 13 or newer). '
        . 'Update the system or select the librespot backend. This looks like a Docker container: the official Lyrion Docker image is based on Debian 12 (glibc 2.36). Use librespot, or an image based on Debian 13.';
    my $dir = tempdir(CLEANUP => 1);
    my $path = catfile($dir, 'soloist');
    write_stderr_binary($path, $glibc_fixture, 1);
    @Slim::Utils::Log::logged = ();
    my $d = Plugins::SpotOn::Soloist::_versionProbeDetail($path);
    is($d->{reason}, 'glibc_too_old:GLIBC_2.38', '79-57 #183: the real bookworm loader text gives glibc_too_old:GLIBC_2.38');
    is($d->{glibc_needed}, '2.38', '79-57 #183: the detail names the needed glibc version');
    my @glibc = grep { /glibc 2\.36 found/ && /2\.38/ } @Slim::Utils::Log::logged;
    is(scalar(@glibc), 1, '79-57 #183: exactly one warn line names the found and the needed glibc')
        or diag('LOGGED=' . join(' | ', @Slim::Utils::Log::logged));
    like($glibc[0] // '', qr/official Lyrion Docker image/, '79-57 #183: the warn line carries the container sentence when DaemonManager gives it');
    like($glibc[0] // '', qr/glibc_too_old:GLIBC_2\.38/, '79-57 #183: the warn line names the probe reason');
    is(scalar(@Slim::Utils::Log::logged), 1, '79-57 #183: one warn line per probe, not two');
}
{
    # "nothing at all": no output, exit 1, glibc below the floor
    reset_all();
    local $main::GLIBC_PROBLEM = 'Soloist cannot run on this system: glibc 2.36 found, Soloist needs glibc 2.38 or newer (Raspberry Pi OS Trixie / Debian 13 or newer). Update the system or select the librespot backend.';
    my $dir = tempdir(CLEANUP => 1);
    my $path = catfile($dir, 'soloist');
    open(my $fh, '>', $path) or die $!;
    print $fh "#!/bin/sh\nexit 1\n";
    close $fh;
    chmod 0755, $path;
    @Slim::Utils::Log::logged = ();
    my $d = Plugins::SpotOn::Soloist::_versionProbeDetail($path);
    is($d->{reason}, 'version_unparsable', '79-57 #183: an empty probe stays version_unparsable');
    is(scalar(grep { /glibc 2\.36 found/ && /version_unparsable/ } @Slim::Utils::Log::logged), 1,
        '79-57 #183: an empty probe on an old glibc logs the glibc reason, not only "0 bytes"')
        or diag('LOGGED=' . join(' | ', @Slim::Utils::Log::logged));
}
{
    # glibc not detectable (no DaemonManager message): the line still names GLIBC_2.38
    reset_all();
    local $main::GLIBC_PROBLEM = undef;
    my $dir = tempdir(CLEANUP => 1);
    my $path = catfile($dir, 'soloist');
    write_stderr_binary($path, $glibc_fixture, 1);
    @Slim::Utils::Log::logged = ();
    Plugins::SpotOn::Soloist::_versionProbeDetail($path);
    is(scalar(grep { /needs glibc 2\.38/ } @Slim::Utils::Log::logged), 1,
        '79-57 #183: without a detected glibc the warn line still names the needed glibc 2.38')
        or diag('LOGGED=' . join(' | ', @Slim::Utils::Log::logged));
}

# ============================================================
# Test 22 (79-57 fork chain): in LMS, STDERR is tied to
# Slim::Utils::Log::Trapper, which has no OPEN method (pitfall T-29-09). The
# version check's child must not die on its STDERR reopen and must never
# return into the caller: on the dev LMS (2026-10-31 11:32) the escaped child
# kept running as a second LMS and forked more of itself (10 LMS processes in
# 4 minutes, 79-57-DEVRUN.md "Task 3 step 7"). The double below has the same
# methods as Trapper (TIEHANDLE, PRINT, FILENO, UNTIE) and no OPEN. A child
# that returns into this file writes a marker file and leaves with _exit, so
# a defect shows as a marker, never as a forked test run.
# ============================================================
{
    package TrapperNoOpen;
    sub TIEHANDLE { my $class = shift; bless [], $class }
    sub PRINT     { 1 }
    sub FILENO    { 2 }
    sub UNTIE     {}
}

sub probe_with_tied_stderr {
    my ($path, $marker) = @_;
    require POSIX;
    my $parent = $$;
    my ($d, $tiedAfter, $err);
    {
        local $SIG{ALRM} = sub { die "probe timeout\n" };
        alarm 20;
        tie *STDERR, 'TrapperNoOpen';
        $d = eval { Plugins::SpotOn::Soloist::_versionProbeDetail($path) };
        $err = $@;
        if ($$ != $parent) {
            # an escaped child: mark it and leave without running anything else
            if (open(my $mh, '>>', $marker)) { print $mh "$$\n"; close $mh; }
            POSIX::_exit(0);
        }
        $tiedAfter = ref(tied(*STDERR)) // '';
        untie *STDERR;
        alarm 0;
    }
    return ($d, $tiedAfter, $err);
}

{
    reset_all();
    my $dir = tempdir(CLEANUP => 1);
    my $path = catfile($dir, 'soloist');
    write_fake_binary($path, '1.3.8.68');
    my $marker = catfile($dir, 'escaped-child');
    my ($d, $tiedAfter, $err) = probe_with_tied_stderr($path, $marker);
    is($err, '', '79-57 fork chain: the probe returns with STDERR tied (no die, no timeout)');
    ok(!-e $marker, '79-57 fork chain: with STDERR tied to a class without OPEN the probe child never returns into the caller')
        or diag('escaped child pids: ' . do { open(my $m, '<', $marker); local $/; <$m> // '' });
    is($d && $d->{version}, '1.3.8.68', '79-57 fork chain: with STDERR tied to a class without OPEN the probe still reads the version');
    is($tiedAfter, 'TrapperNoOpen', "79-57 fork chain: the parent's STDERR tie is untouched by the probe");
}

{
    # exec fails (not executable): the child must still end in _exit, never return
    reset_all();
    my $dir = tempdir(CLEANUP => 1);
    my $path = catfile($dir, 'soloist');
    open(my $fh, '>', $path) or die $!;
    print $fh "#!/bin/sh\necho 'soloist 1.3.8.68'\n";
    close $fh;
    chmod 0644, $path;
    my $marker = catfile($dir, 'escaped-child');
    @Slim::Utils::Log::logged = ();
    my ($d, $tiedAfter, $err) = probe_with_tied_stderr($path, $marker);
    ok(!-e $marker, '79-57 fork chain: when exec fails with STDERR tied the probe child ends in _exit, never returns into the caller')
        or diag('escaped child pids: ' . do { open(my $m, '<', $marker); local $/; <$m> // '' });
    ok(!defined($d && $d->{version}), '79-57 fork chain: a failed exec gives no version');
    is(scalar(grep { /version check failed to run \(exec failed\)/ } @Slim::Utils::Log::logged), 1,
        '79-57 fork chain: a failed exec with STDERR tied is reported as exec failed by the parent')
        or diag('LOGGED=' . join(' | ', @Slim::Utils::Log::logged));
}

# ============================================================
# Test 21 (79-57 IN-03): an existing Users dir that cannot be opened reads
# unknown (undef), not "never paired" (0); an empty one stays 0, a filled
# one 1.
# ============================================================
SKIP: {
    skip 'running as root: an unreadable dir is still readable', 3 if $> == 0;
    reset_all();
    my $mac = 'aa:bb:cc:dd:57:03';
    my $users = catdir(Plugins::SpotOn::Soloist::dataDirForClient($mac), 'settings', 'Users');
    make_path($users);
    is(Plugins::SpotOn::Soloist::isPairedForClient($mac), 0, '79-57 IN-03: an empty Users dir reads 0 (never paired)');
    open(my $fh, '>', catfile($users, 'someone')) or die $!;
    close $fh;
    is(Plugins::SpotOn::Soloist::isPairedForClient($mac), 1, '79-57 IN-03: a filled Users dir reads 1');
    chmod 0000, $users;
    my $r = Plugins::SpotOn::Soloist::isPairedForClient($mac);
    chmod 0700, $users;
    ok(!defined $r, '79-57 IN-03: an unreadable Users dir reads undef (unknown), never a defined "never paired"');
}

# ============================================================
# 79-63 R2 (79-REVIEW-BETA3-R1 WR-02): LMS ignores SIGPIPE (Slim/bootstrap.pm:243)
# and SIG_IGN survives exec. A candidate that ignores write errors -- a shell
# loop, or a wrapper that prints and then waits -- would then outlive the
# probe's close() and hold the single-threaded server. The probe child resets
# PIPE to DEFAULT before exec, so the child dies of SIGPIPE once the parent
# has read its 4 KB and closed. Each probe runs in its own process group
# under a hard deadline; on timeout the whole group is killed (no orphaned
# loop), and the cell fails instead of hanging the suite.
# ============================================================
sub probe_within {
    my ($path, $secs) = @_;
    require POSIX;
    require Time::HiRes;
    my $t0 = Time::HiRes::time();
    my $pid = fork;
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        setpgrp(0, 0);
        $SIG{PIPE} = 'IGNORE';    # as LMS
        my $d = eval { Plugins::SpotOn::Soloist::_versionProbeDetail($path) };
        POSIX::_exit($d ? 0 : 3);
    }
    my $done;
    while (Time::HiRes::time() - $t0 < $secs) {
        my $r = waitpid($pid, POSIX::WNOHANG());
        if ($r == $pid) { $done = ($? >> 8) == 0 ? 'returned' : 'died'; last; }
        Time::HiRes::sleep(0.05);
    }
    unless ($done) {
        kill 'KILL', -$pid;
        waitpid($pid, 0);
        $done = 'timeout';
    }
    return ($done, Time::HiRes::time() - $t0);
}
{
    reset_all();
    my $dir = tempdir(CLEANUP => 1);
    my %stub = (
        'shell loop'           => "#!/bin/sh\nwhile :; do echo 'soloist help text, ignoring write errors'; done\n",
        'print then sleep 30'  => "#!/bin/sh\nprintf '%0200000d' 0\nsleep 30\n",
    );
    for my $name (sort keys %stub) {
        (my $file = $name) =~ s/\W+/_/g;
        my $path = catfile($dir, $file);
        open(my $fh, '>', $path) or die $!;
        print $fh $stub{$name};
        close $fh;
        chmod 0755, $path;
        my ($how, $secs) = probe_within($path, 8);
        is($how, 'returned', "79-63 R2 WR-02: a candidate '$name' does not outlive the probe's close() under LMS's ignored SIGPIPE")
            or diag(sprintf 'probe %s after %.2f s', $how, $secs);
    }
}
{
    # the reset sits in the child branch before exec (source pin next to the behaviour)
    open(my $sfh, '<', "$project_dir/Plugins/SpotOn/Soloist.pm") or die $!;
    my $src = do { local $/; <$sfh> };
    my ($child) = $src =~ /(if \(!\$pid\) \{.*?POSIX::_exit\(127\);)/s;
    like($child // '', qr/\$SIG\{PIPE\}\s*=\s*'DEFAULT';.*exec \{ \$candidate \}/s,
        '79-63 R2 WR-02: the probe child resets SIGPIPE to DEFAULT before exec');
}

done_testing();

#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use File::Spec::Functions qw(catdir catfile);

# Resolve project root: t/ is directly under the project root
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname($test_dir);

my $module = "$project_dir/Plugins/SpotOn/Soloist.pm";
unless (-f $module) {
    plan skip_all => 'Plugins/SpotOn/Soloist.pm not yet present in this checkout';
}

# skip gracefully if system `tar` is not available -- mirrors t/06's
# skip-if-absent pattern (RESEARCH.md Validation Architecture); only the
# download-pipeline tests below need it.
unless (`tar --version 2>&1` && $? == 0) {
    plan skip_all => 'system tar not available -- required for extraction tests';
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

# Phase 72: ensureBinary() now calls ensureLauncher() as its first action
# (RESEARCH Pitfall 5), which requires Slim::Utils::Misc::addFindBinPaths()
# and Plugins::SpotOn::Plugin->_pluginDataFor('basedir') at runtime. Stub
# both so tests 10-13 (which call ensureBinary()/downloadBinary()) don't
# fall through to the real system Slim::Utils::Misc.
write_stub($stub_dir, 'Slim::Utils::Misc', <<'END');
package Slim::Utils::Misc;
our @findbin_calls = ();
sub addFindBinPaths { push @findbin_calls, $_[0]; }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Plugin', <<'END');
package Plugins::SpotOn::Plugin;
sub _pluginDataFor { return 'test-basedir' }
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
# Test 5: findbin() is never used for *binary discovery* (Anti-Pattern,
# cachedir-based discovery stays intact). Phase 72: addFindBinPaths() IS now
# called by ensureLauncher() -- purely so the static [spoton-soloist] token
# in custom-convert.conf can resolve the generated wrapper; it never
# participates in locating the soloist binary itself (still cachedir-based).
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

    like($codeOnly, qr/addFindBinPaths\(\s*_rootDir\(\)\s*\)/,
        'Soloist.pm calls addFindBinPaths(_rootDir()) so the [spoton-soloist] convert-rule token resolves (Phase 72)');
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
    like($src, qr/open\(my \$fh, '-\|', \$candidate, VERSION_FLAG\)/, "version check uses array-form open('-|', ...)");
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
    write_fake_binary(catfile($binDir, 'soloist'), '1.3.7.489');

    my $path = Plugins::SpotOn::Soloist::get();
    like($path, qr{x86_64-linux/soloist$}, 'get() resolves the cached, version-matched binary');
}

# ============================================================
# Test 9: version mismatch is NOT activated (D-05 fail-closed)
# ============================================================
{
    reset_all();
    $Slim::Utils::OSDetect::osArch = 'arm';

    my $binDir = catdir($cache_dir, 'spoton', 'soloist', 'armhf-linux');
    make_path($binDir);
    write_fake_binary(catfile($binDir, 'soloist'), '9.9.9.999');

    my $path = Plugins::SpotOn::Soloist::get();
    ok(!defined($path), 'get() refuses to activate a binary reporting an unexpected version (D-05)');
}

# ============================================================
# Test 10: ensureBinary() does NOT re-download when a working binary exists
# ============================================================
{
    reset_all();
    $Slim::Utils::OSDetect::osArch = 'x86_64';

    my $binDir = catdir($cache_dir, 'spoton', 'soloist', 'x86_64-linux');
    make_path($binDir);
    write_fake_binary(catfile($binDir, 'soloist'), '1.3.7.489');

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
    write_fake_binary(catfile($binDir, 'soloist'), '1.3.7.489');

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
    write_fake_binary(catfile($srcDir, 'soloist'), '1.3.7.489');

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

done_testing();

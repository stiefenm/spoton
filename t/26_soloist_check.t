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
# Test 5: No findbin/addFindBinPaths usage anywhere in the source
# ============================================================
{
    my $src = do {
        local $/;
        open(my $fh, '<', "$project_dir/Plugins/SpotOn/Soloist.pm") or die $!;
        <$fh>;
    };
    (my $codeOnly = $src) =~ s/^\s*#.*$//mg;
    my $hits = () = $codeOnly =~ /findbin|addFindBinPaths/gi;
    is($hits, 0, 'Soloist.pm never calls findbin()/addFindBinPaths() (Anti-Pattern, cachedir-based discovery)');
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

done_testing();

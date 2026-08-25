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
my $base_dir  = tempdir(CLEANUP => 1);

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
# LMS Module Stubs required by Soloist.pm (mirrors t/26/t/27's harness)
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

my $prefs_cache_dir = $cache_dir;
write_stub($stub_dir, 'Slim::Utils::Prefs', <<"END");
package Slim::Utils::Prefs;
my \%_store;
my \%_ns_store = ( server => { cachedir => '$prefs_cache_dir' } );
my \%_change_cbs;

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

write_stub($stub_dir, 'Slim::Utils::OSDetect', <<'END');
package Slim::Utils::OSDetect;
our $osArch = 'x86_64';
sub details { return { osArch => $osArch } }
sub OS      { 'unix' }
sub getOS   { return bless {}, 'Slim::Utils::OSDetect' }
1;
END

write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
sub new { bless {}, shift }
sub get { }
1;
END

# Records every addFindBinPaths() call so ensureLauncher()'s findbin
# registration (Phase 72) can be asserted without a real LMS.
write_stub($stub_dir, 'Slim::Utils::Misc', <<'END');
package Slim::Utils::Misc;
our @findbin_calls = ();
sub addFindBinPaths { push @findbin_calls, $_[0]; }
1;
END

my $stub_base_dir = $base_dir;
write_stub($stub_dir, 'Plugins::SpotOn::Plugin', <<"END");
package Plugins::SpotOn::Plugin;
sub _pluginDataFor { return '$stub_base_dir' }
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
require Slim::Utils::Misc;
require Plugins::SpotOn::Plugin;

require_ok('Plugins::SpotOn::Soloist')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Soloist");

Plugins::SpotOn::Soloist::init();

# Force the arch path deterministically for the whole file.
$Slim::Utils::OSDetect::osArch = 'x86_64';

# A dummy key file so we can assert its raw content never leaks into the
# generated script text (T-72-01).
my $DUMMY_KEY = 'spak_' . ('Z' x 40) . '_launcher_test_key';
Plugins::SpotOn::Soloist->storeKey($DUMMY_KEY);

# ============================================================
# Test: ensureLauncher() creates the launcher + dataDir, sets +x
# ============================================================
{
    @Slim::Utils::Misc::findbin_calls = ();

    my $ok = Plugins::SpotOn::Soloist::ensureLauncher();
    ok($ok, 'ensureLauncher() reports success');

    my $launcherPath = Plugins::SpotOn::Soloist::launcherPath();
    ok(-f $launcherPath, 'launcher file exists at launcherPath()');
    ok(-x $launcherPath, 'launcher file is executable');

    ok(-d Plugins::SpotOn::Soloist::dataDir(), 'dataDir() was created');

    ok(scalar(grep { $_ eq Plugins::SpotOn::Soloist::_rootDir() } @Slim::Utils::Misc::findbin_calls),
        'addFindBinPaths() was called with _rootDir() (Phase 72 convert-token resolution)');
}

# ============================================================
# Test: launcher script content -- structure, security contract, D-06 shape
# ============================================================
{
    my $launcherPath = Plugins::SpotOn::Soloist::launcherPath();
    open(my $fh, '<', $launcherPath) or die "cannot read $launcherPath: $!";
    local $/;
    my $content = <$fh>;
    close($fh);

    ok(index($content, "#!/bin/sh") == 0, 'launcher content starts with #!/bin/sh');

    like($content, qr/SPOTON_SOLOIST_PCM_FD=1/, 'launcher sets SPOTON_SOLOIST_PCM_FD=1');
    like($content, qr/export LD_LIBRARY_PATH=/, 'launcher exports LD_LIBRARY_PATH');

    my $keyPath = Plugins::SpotOn::Soloist::keyPath();
    like($content, qr/KEY=\$\(cat "\Q$keyPath\E"\)/,
        'launcher reads the spak-key via command substitution from keyPath()');

    like($content, qr/-k "\$KEY"/, 'launcher passes the key via a quoted shell variable, not a literal');

    my $dataDir = Plugins::SpotOn::Soloist::dataDir();
    like($content, qr/-D "\Q$dataDir\E"/, 'launcher passes -D followed by dataDir()');

    like($content, qr/"\$\@"/, 'launcher passes through "$@"');

    like($content, qr/sleep 2/, 'launcher contains the D-06 retry sleep');
    like($content, qr/^exec /m, 'launcher contains a final exec line (D-06)');

    # T-72-01: the raw key value never appears in the generated script text.
    unlike($content, qr/\Q$DUMMY_KEY\E/, 'the raw spak-key value never appears in the launcher script');
}

# ============================================================
# Test: idempotency -- a second ensureLauncher() call succeeds cleanly
# ============================================================
{
    my $ok = Plugins::SpotOn::Soloist::ensureLauncher();
    ok($ok, 'second ensureLauncher() call succeeds (idempotent)');

    my $launcherPath = Plugins::SpotOn::Soloist::launcherPath();
    ok(-f $launcherPath && -x $launcherPath, 'launcher still exists and is executable after re-run');
}

# ============================================================
# Test: isPaired() heuristic
# ============================================================
{
    my $freshDataDir = tempdir(CLEANUP => 1);
    no warnings 'redefine';
    local *Plugins::SpotOn::Soloist::dataDir = sub { $freshDataDir };

    is(Plugins::SpotOn::Soloist::isPaired(), 0, 'isPaired() is false on an empty dataDir');

    open(my $fh, '>', "$freshDataDir/credentials.bin") or die $!;
    print $fh 'fake-credentials';
    close($fh);

    is(Plugins::SpotOn::Soloist::isPaired(), 1, 'isPaired() is true after a file appears in dataDir');
}

done_testing();

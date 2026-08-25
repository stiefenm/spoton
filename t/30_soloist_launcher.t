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
    like($content, qr/WR-01/, 'launcher script text contains the WR-01 accepted-trade-off marker');

    my $dataDir = Plugins::SpotOn::Soloist::dataDir();
    like($content, qr/-D "\Q$dataDir\E"/, 'launcher passes -D followed by dataDir()');

    like($content, qr/"\$\@"/, 'launcher passes through "$@"');

    like($content, qr/sleep 2/, 'launcher contains the D-06 retry sleep');
    like($content, qr/^exec /m, 'launcher contains a final exec line (D-06)');

    # T-72-01: the raw key value never appears in the generated script text.
    unlike($content, qr/\Q$DUMMY_KEY\E/, 'the raw spak-key value never appears in the launcher script');
}

# ============================================================
# Test: CR-01 -- generated wrapper translates spoton:// to spotify: in the
# child argv, proven behaviorally against a stub "soloist" binary.
# ============================================================
SKIP: {
    skip 'behavioral launcher test requires /bin/sh (Linux-only launcher)', 10
        if $^O eq 'MSWin32' || !-x '/bin/sh';

    my $behav_dir = tempdir(CLEANUP => 1);
    my $argv_out  = "$behav_dir/argv.out";
    my $stub_bin  = "$behav_dir/soloist-stub";

    open(my $sfh, '>', $stub_bin) or die "cannot write stub binary: $!";
    print $sfh <<"STUB";
#!/bin/sh
printf '%s\\n' "\$\@" > "$argv_out"
exit 0
STUB
    close($sfh);
    chmod(0755, $stub_bin);

    my $behav_lib  = tempdir(CLEANUP => 1);
    my $behav_key  = Plugins::SpotOn::Soloist::keyPath();
    my $behav_data = Plugins::SpotOn::Soloist::dataDir();

    my $wrapper_text = Plugins::SpotOn::Soloist::_launcherScript(
        $behav_lib, $behav_key, $stub_bin, $behav_data,
    );

    my $wrapper_path = "$behav_dir/wrapper.sh";
    open(my $wfh, '>', $wrapper_path) or die "cannot write wrapper: $!";
    print $wfh $wrapper_text;
    close($wfh);
    chmod(0755, $wrapper_path);

    # --- Run 1: track URI translation ---
    unlink $argv_out if -f $argv_out;
    my $rc1 = system($wrapper_path, '--single-track', 'spoton://track:abc123DEF');
    is($rc1, 0, 'wrapper exits 0 against the stub binary (track run)');

    ok(-f $argv_out, 'stub binary captured argv to argv.out (track run)');
    open(my $afh1, '<', $argv_out) or die "cannot read $argv_out: $!";
    my @lines1 = <$afh1>;
    close($afh1);
    chomp @lines1;

    ok((grep { $_ eq 'spotify:track:abc123DEF' } @lines1),
        'captured argv contains the translated spotify:track: URI');
    ok((grep { $_ eq '--single-track' } @lines1),
        'captured argv contains --single-track');
    is((scalar grep { /^spoton:\/\// } @lines1), 0,
        'captured argv has zero occurrences of the internal spoton:// scheme (T-72-03)');

    is_deeply(
        \@lines1,
        [ '-n', 'SpotOn', '-k', $DUMMY_KEY, '-D', $behav_data, '-C', "$behav_data/cache", '--single-track', 'spotify:track:abc123DEF' ],
        'captured argv preserves order and non-URL args verbatim, -k immediately followed by the exact key content (WR-01 key-delivery contract)',
    );

    # --- Run 2: episode URI translation ---
    unlink $argv_out if -f $argv_out;
    my $rc2 = system($wrapper_path, '--single-track', 'spoton://episode:xyz789');
    is($rc2, 0, 'wrapper exits 0 against the stub binary (episode run)');

    open(my $afh2, '<', $argv_out) or die "cannot read $argv_out: $!";
    my @lines2 = <$afh2>;
    close($afh2);
    chomp @lines2;

    ok((grep { $_ eq 'spotify:episode:xyz789' } @lines2),
        'captured argv contains the translated spotify:episode: URI');
    is((scalar grep { /^spoton:\/\// } @lines2), 0,
        'episode run: captured argv has zero occurrences of the internal spoton:// scheme');

    # T-72-01 still holds against this behaviorally-generated wrapper too:
    # the raw key never appears in the SCRIPT TEXT (only in the runtime argv above).
    unlike($wrapper_text, qr/\Q$DUMMY_KEY\E/,
        'the raw spak-key value never appears in the generated script text');
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

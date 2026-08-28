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
# LMS Module Stubs required by Soloist.pm (mirrors t/26_soloist_check.t)
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

# Real from_json/to_json via JSON::PP -- _runHelperJson()'s JSON decoding is
# under test here, so (unlike a plain no-op stub) this must actually parse.
write_stub($stub_dir, 'JSON::XS::VersionOneAndTwo', <<'END');
package JSON::XS::VersionOneAndTwo;
use parent 'Exporter';
our @EXPORT = qw(from_json to_json);
use JSON::PP ();
sub from_json { JSON::PP::decode_json($_[0]) }
sub to_json   { JSON::PP::encode_json($_[0]) }
1;
END

# preferences('server')->get('cachedir') returns a real tempdir (unused by
# these tests directly, but Soloist.pm's module-load-time `my $prefs`/
# `my $serverPrefs` package globals need a working preferences() stub).
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
our @created   = ();
sub new {
    my ($class, $cb, $ecb, $opts) = @_;
    my $self = bless { cb => $cb, ecb => $ecb, opts => $opts }, $class;
    push @created, $self;
    return $self;
}
sub get { }
sub content { '' }
1;
END

# _pluginDataFor('basedir') returns a real tempdir -- _helperPath() joins it
# with Bin/<bindir>/spoton-helper, so tests write a fake helper executable
# under that same tree.
my $basedir = tempdir(CLEANUP => 1);
write_stub($stub_dir, 'Plugins::SpotOn::Plugin', <<"END");
package Plugins::SpotOn::Plugin;
sub _pluginDataFor { return '$basedir' }
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

Plugins::SpotOn::Soloist::init();

# ============================================================
# Test fixtures
# ============================================================

# Writes an executable "spoton-helper" fake at $path whose `check` and
# `patch` JSON outputs are driven by $behavior:
#   'already_patched' -> check reports {"patched":true}  (no patch call expected)
#   'needs_patch'      -> check reports {"patched":false}, patch reports {"patched":true}
#   'patch_fails'       -> check reports {"patched":false}, patch reports {"patched":false}
# Every invocation appends its argv (one line, space-joined) to $argv_log_path
# so tests can assert array-form invocation (no shell interpolation, T-74-09).
sub write_fake_helper {
    my ($path, $behavior, $argv_log_path) = @_;

    open(my $fh, '>', $path) or die "write_fake_helper: $!";
    print $fh "#!/bin/sh\n";
    print $fh "echo \"\$@\" >> '$argv_log_path'\n";
    print $fh "case \"\$1\" in\n";
    if ($behavior eq 'already_patched') {
        print $fh "  check) echo '{\"patched\":true}' ;;\n";
        print $fh "  patch) echo '{\"error\":\"should not be called\"}'; exit 1 ;;\n";
    } elsif ($behavior eq 'needs_patch') {
        print $fh "  check) echo '{\"patched\":false}' ;;\n";
        print $fh "  patch) echo '{\"status\":\"patched\",\"patched\":true}' ;;\n";
    } elsif ($behavior eq 'patch_fails') {
        print $fh "  check) echo '{\"patched\":false}' ;;\n";
        print $fh "  patch) echo '{\"status\":\"unsupported\"}' ;;\n";
    }
    print $fh "esac\n";
    close($fh);
    chmod(0755, $path);
}

sub reset_helper_dir {
    my $binDir = catdir($basedir, 'Bin', 'x86_64-linux');
    make_path($binDir);
    return $binDir;
}

# ============================================================
# Test 1-2: idempotent skip -- check reports patched:true, patch NOT invoked
# ============================================================
{
    $Slim::Utils::OSDetect::osArch = 'x86_64';
    my $binDir = reset_helper_dir();
    my $helperPath = catfile($binDir, 'spoton-helper');
    my $argvLog = catfile($binDir, 'argv.log');
    unlink $argvLog if -f $argvLog;
    write_fake_helper($helperPath, 'already_patched', $argvLog);

    my $ok = eval { Plugins::SpotOn::Soloist::_autoPatch('/fake/soloist/path'); 1 };
    ok($ok, '_autoPatch does not die when check reports patched:true') or diag($@);

    open(my $fh, '<', $argvLog) or die $!;
    my @lines = <$fh>;
    close($fh);
    is(scalar(@lines), 1, 'only one helper invocation happened (check only)');
    like($lines[0], qr/^check /, 'the single invocation was `check`, not `patch`');
}

# ============================================================
# Test 3-5: needs patch -- check reports patched:false, patch IS invoked and
# succeeds; assert array-form argv (no shell interpolation)
# ============================================================
{
    $Slim::Utils::OSDetect::osArch = 'x86_64';
    my $binDir = reset_helper_dir();
    my $helperPath = catfile($binDir, 'spoton-helper');
    my $argvLog = catfile($binDir, 'argv.log');
    unlink $argvLog if -f $argvLog;
    write_fake_helper($helperPath, 'needs_patch', $argvLog);

    my $ok = eval { Plugins::SpotOn::Soloist::_autoPatch('/fake/soloist/path'); 1 };
    ok($ok, '_autoPatch does not die on the patch-required path') or diag($@);

    open(my $fh, '<', $argvLog) or die $!;
    my @lines = <$fh>;
    close($fh);
    is(scalar(@lines), 2, 'two helper invocations happened (check, then patch)');
    like($lines[0], qr/^check\s+--binary\s+\/fake\/soloist\/path/, 'check invoked with --binary <path>');
    like($lines[1], qr/^patch\s+--version\s+1\.3\.7\.489\s+--binary\s+\/fake\/soloist\/path/,
        'patch invoked with --version SOLOIST_VERSION --binary <path> (array-form argv, no shell interpolation)');
}

# ============================================================
# Test 6: missing helper (_helperPath undef) -- _autoPatch returns without
# dying, fail-open
# ============================================================
{
    $Slim::Utils::OSDetect::osArch = 'x86_64';
    my $binDir = catdir($basedir, 'Bin', 'x86_64-linux');
    my $helperPath = catfile($binDir, 'spoton-helper');
    unlink $helperPath if -f $helperPath;    # ensure no helper binary present

    my $ok = eval { Plugins::SpotOn::Soloist::_autoPatch('/fake/soloist/path'); 1 };
    ok($ok, '_autoPatch does not die when _helperPath is undef (no helper shipped for this arch)') or diag($@);
}

# ============================================================
# Test 7: patch returns patched:false -- a warning is logged, no exception
# ============================================================
{
    $Slim::Utils::OSDetect::osArch = 'x86_64';
    my $binDir = reset_helper_dir();
    my $helperPath = catfile($binDir, 'spoton-helper');
    my $argvLog = catfile($binDir, 'argv.log');
    unlink $argvLog if -f $argvLog;
    write_fake_helper($helperPath, 'patch_fails', $argvLog);

    @Slim::Utils::Log::logged = ();
    my $ok = eval { Plugins::SpotOn::Soloist::_autoPatch('/fake/soloist/path'); 1 };
    ok($ok, '_autoPatch does not die when patch reports patched:false') or diag($@);

    my $warned = grep { /auto-patch did not complete/i } @Slim::Utils::Log::logged;
    ok($warned, 'a warning is logged when patch does not report patched:true');
}

# ============================================================
# Test 8: _autoPatch is called after the _versionCheck activation branch in
# _onSoloistDownloadDone (source assertion, mirrors t/26 Test 14 style)
# ============================================================
{
    my $src = do {
        local $/;
        open(my $fh, '<', "$project_dir/Plugins/SpotOn/Soloist.pm") or die $!;
        <$fh>;
    };
    like($src,
        qr/if \s* \( _versionCheck\(\$canonical\) \) \s* \{ .*? \$binary \s* = \s* \$canonical.*? _autoPatch\(\$canonical\)/sx,
        '_autoPatch($canonical) is called inside the successful _versionCheck activation branch');
}

# ============================================================
# Test 9: _runHelperJson uses array-form open, never a shell string
# ============================================================
{
    my $src = do {
        local $/;
        open(my $fh, '<', "$project_dir/Plugins/SpotOn/Soloist.pm") or die $!;
        <$fh>;
    };
    unlike($src, qr/`\$helper/, 'no backtick invocation of the helper binary');
    like($src, qr/open\(my \$fh, '-\|', \$helper, \@args\)/, "_runHelperJson uses array-form open('-|', ...)");
}

done_testing();

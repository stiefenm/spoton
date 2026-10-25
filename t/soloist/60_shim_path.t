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
# LMS Module Stubs required by Soloist.pm (mirrors t/33_soloist_patch.t)
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
sub new { bless {}, shift }
sub get { }
sub content { '' }
1;
END

# _pluginDataFor('basedir') reads a package variable so every case can point
# libPath() at its own tempdir tree.
write_stub($stub_dir, 'Plugins::SpotOn::Plugin', <<'END');
package Plugins::SpotOn::Plugin;
our $BASEDIR = 'unset';
sub _pluginDataFor { return $BASEDIR }
1;
END

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
require Plugins::SpotOn::Plugin;

require_ok('Plugins::SpotOn::Soloist')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Soloist");

Plugins::SpotOn::Soloist::init();

# One fresh tree per case: Bin/fake-libpulse always carries libpulse.so.0 and
# the decoy libpipewire (the dev tree); Bin/<bindir>/libpulse.so.0 only when
# $per_arch names that bindir (the CI zip layout).
sub tree {
    my ($osArch, $per_arch) = @_;
    my $base = tempdir(CLEANUP => 1);
    make_path(catdir($base, 'Bin', 'fake-libpulse'));
    for my $f (qw(libpulse.so.0 libpipewire-0.3.so.0)) {
        open(my $fh, '>', catfile($base, 'Bin', 'fake-libpulse', $f)) or die $!;
        print $fh "x"; close $fh;
    }
    if (defined $per_arch) {
        make_path(catdir($base, 'Bin', $per_arch));
        open(my $fh, '>', catfile($base, 'Bin', $per_arch, 'libpulse.so.0')) or die $!;
        print $fh "x"; close $fh;
    }
    no warnings "once";
    $Plugins::SpotOn::Plugin::BASEDIR = $base;
    $Slim::Utils::OSDetect::osArch    = $osArch;
    return $base;
}

sub lsp { my $r = eval { Plugins::SpotOn::Soloist::libSearchPath() }; diag("libSearchPath: $@") if $@; return $r }

my $base;

can_ok('Plugins::SpotOn::Soloist', 'libSearchPath');

# --- aarch64 with the per-arch member (CI zip layout) -------------------
$base = tree('aarch64', 'aarch64-linux');
is(Plugins::SpotOn::Soloist::libPath(), catdir($base, 'Bin', 'aarch64-linux'),
    'aarch64 + Bin/aarch64-linux/libpulse.so.0 -> libPath is the per-arch dir');
is(lsp(),
    catdir($base, 'Bin', 'aarch64-linux') . ':' . catdir($base, 'Bin', 'fake-libpulse'),
    'aarch64 per-arch -> libSearchPath keeps the decoy dir behind the per-arch dir');

# --- aarch64 without it (tree not yet populated) -> fallback -------------
$base = tree('aarch64', undef);
is(Plugins::SpotOn::Soloist::libPath(), catdir($base, 'Bin', 'fake-libpulse'),
    'aarch64 without the per-arch file -> fallback to Bin/fake-libpulse');
is(lsp(), catdir($base, 'Bin', 'fake-libpulse'),
    'fallback -> libSearchPath is the single fake-libpulse dir (no duplicate)');

# --- armhf ---------------------------------------------------------------
$base = tree('armv7l', 'armhf-linux');
is(Plugins::SpotOn::Soloist::libPath(), catdir($base, 'Bin', 'armhf-linux'),
    'armv7l + Bin/armhf-linux/libpulse.so.0 -> Bin/armhf-linux');

# --- x86_64 dev tree: only fake-libpulse -----------------------------------
$base = tree('x86_64', undef);
is(Plugins::SpotOn::Soloist::libPath(), catdir($base, 'Bin', 'fake-libpulse'),
    'x86_64 dev tree (only Bin/fake-libpulse) -> Bin/fake-libpulse');

# --- x86_64 with the per-arch member -----------------------------------------
$base = tree('x86_64', 'x86_64-linux');
is(Plugins::SpotOn::Soloist::libPath(), catdir($base, 'Bin', 'x86_64-linux'),
    'x86_64 + Bin/x86_64-linux/libpulse.so.0 -> per-arch dir');

# --- a per-arch DIR without the .so does not win (-f on the file) -----------
$base = tree('aarch64', undef);
make_path(catdir($base, 'Bin', 'aarch64-linux'));
is(Plugins::SpotOn::Soloist::libPath(), catdir($base, 'Bin', 'fake-libpulse'),
    'per-arch dir without libpulse.so.0 -> fallback (the -f check is on the file)');

# --- unknown arch -----------------------------------------------------------
$base = tree('riscv64', undef);
is(Plugins::SpotOn::Soloist::libPath(), undef, 'unknown arch -> libPath undef');
is(lsp(), undef, 'unknown arch -> libSearchPath undef');

# --- libPath keeps its runtime require (WR-05 load-cycle note) ---------------
{
    my $src = do { local (@ARGV, $/) = ($module); <> };
    my ($body) = $src =~ /\nsub libPath \{(.*?)\n\}\n/s;
    ok(defined $body && $body =~ /^\s*require Plugins::SpotOn::Plugin;/m,
        'libPath() still requires Plugins::SpotOn::Plugin at runtime');
}

# --- fence: SoloistDaemon builds the env from the two lookups ------------------
{
    my $dfile = "$project_dir/Plugins/SpotOn/Unified/SoloistDaemon.pm";
    open(my $fh, '<', $dfile) or die "$dfile: $!";
    my @code = grep { !/^\s*#/ } <$fh>;
    close $fh;
    my $code = join('', @code);
    like($code, qr/\$ENV\{LD_LIBRARY_PATH\}[^;]*libSearchPath|libSearchPath\(\)[^;]*;[\s\S]{0,400}\$ENV\{LD_LIBRARY_PATH\}/,
        'SoloistDaemon.pm sources LD_LIBRARY_PATH from libSearchPath()');
    like($code, qr/Soloist::libSearchPath\(\)/, 'SoloistDaemon.pm calls Soloist::libSearchPath()');
    like($code, qr/Soloist::libPath\(\)/, 'SoloistDaemon.pm still calls Soloist::libPath() for LD_PRELOAD');
    like($code, qr/catfile\(\$libPath, 'libpulse\.so\.0'\)/,
        'LD_PRELOAD stays <libPath>/libpulse.so.0');
}

done_testing();

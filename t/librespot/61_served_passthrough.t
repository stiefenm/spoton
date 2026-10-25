#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# 79-34 (D-29, P17-auto): under librespot the stream's content-type tag follows the
# daemon that is actually serving, not the pref. The REAL DaemonManager is loaded under
# the stub harness of t/soloist/28_soloist_dispatch_soloist.t (only the stubs this file
# needs); the helper is a fake with `alive` and `_passthrough`, installed through the
# glob override of helperForClient (t/soloist/28 :364-376 pattern).
#
# Every cell is prefixed "79-34 D-29:". Calls go through eval so a missing resolver is a
# `not ok` (RED), never a dying script.

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

my $module = "$project_dir/Plugins/SpotOn/Unified/DaemonManager.pm";
die "Plugins/SpotOn/Unified/DaemonManager.pm not present -- wrong project root or broken checkout (die, never skip)\n"
    unless -f $module;

my $stub_dir = tempdir(CLEANUP => 1);

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
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub logger { return bless {}, 'Slim::Utils::Log' }
sub info  { }
sub warn  { }
sub error { }
sub debug { }
sub is_info  { 1 }
sub is_debug { 0 }
sub is_warn  { 1 }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Global prefs from %FAKE_VALUES; per-client prefs from %CLIENT_VALUES (one hash, cells
# set the keys they need and restore them).
write_stub($stub_dir, 'Slim::Utils::Prefs', <<'END');
package Slim::Utils::Prefs;
our %FAKE_VALUES   = ( cachedir => '/tmp/spoton-test-cachedir', backend => 'librespot' );
our %CLIENT_VALUES = ();
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::preferences"} = \&preferences;
}
sub preferences { return bless { _ns => 'global' }, 'Slim::Utils::Prefs' }
sub get {
    my ($self, $key) = @_;
    return $self->{_ns} eq 'client' ? $CLIENT_VALUES{$key} : $FAKE_VALUES{$key};
}
sub set {
    my ($self, $key, $val) = @_;
    if ($self->{_ns} eq 'client') { $CLIENT_VALUES{$key} = $val } else { $FAKE_VALUES{$key} = $val }
}
sub client    { return bless { _ns => 'client' }, 'Slim::Utils::Prefs' }
sub setChange { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
sub new    { return bless {}, shift }
sub get    { return undef }
sub set    { }
sub remove { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Strings', <<'END');
package Slim::Utils::Strings;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::cstring"} = sub { '' };
    *{"${caller}::string"}  = sub { '' };
}
1;
END

write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
sub killTimers { }
sub setTimer   { }
1;
END

write_stub($stub_dir, 'Slim::Networking::Select', <<'END');
package Slim::Networking::Select;
sub addRead    { }
sub removeRead { }
1;
END

write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
sub new { return bless {}, shift }
sub get { }
sub post { }
1;
END

write_stub($stub_dir, 'JSON::XS::VersionOneAndTwo', <<'END');
package JSON::XS::VersionOneAndTwo;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::to_json"}   = sub { '{}' };
    *{"${caller}::from_json"} = sub { {} };
}
1;
END

write_stub($stub_dir, 'Slim::Utils::OSDetect', <<'END');
package Slim::Utils::OSDetect;
sub details { return { osArch => 'x86_64-linux-gnu-thread-multi' } }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Plugin', <<'END');
package Plugins::SpotOn::Plugin;
use constant SPOTON_CACHE_VERSION => 4;
our $FAKE_BASEDIR = 'test-basedir';
sub _pluginDataFor { return $FAKE_BASEDIR }
1;
END

# The passthrough capability of the installed binary (Backend::Librespot reads it
# from the Helper, lazy and eval-guarded). A package var so cells can set it.
write_stub($stub_dir, 'Plugins::SpotOn::Helper', <<'END');
package Plugins::SpotOn::Helper;
our $CAP_PASSTHROUGH = 1;
sub getCapability { my ($class, $name) = @_; return $name eq 'passthrough' ? $CAP_PASSTHROUGH : 0; }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Status', <<'END');
package Plugins::SpotOn::Status;
sub recordError { }
sub clearError  { }
sub hasError    { 0 }
1;
END

BEGIN {
    no warnings 'redefine';
    *main::TRANSCODING = sub () { 0 };
    *main::WEBUI       = sub () { 0 };
    *main::SCANNER     = sub () { 0 };
    *main::INFOLOG     = sub () { 0 };
    *main::DEBUGLOG    = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
    *main::ISWINDOWS   = sub () { 0 };
    *main::ISMAC       = sub () { 0 };
}

unshift @INC, $stub_dir, $project_dir;

require_ok('Plugins::SpotOn::Unified::DaemonManager')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Unified::DaemonManager");
require_ok('Plugins::SpotOn::Backend::Librespot')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Backend::Librespot");

my $DM = 'Plugins::SpotOn::Unified::DaemonManager';

# --- fakes -------------------------------------------------------------------
{
    package FakeHelper;
    sub new { my ($c, %a) = @_; return bless { alive => 1, %a }, $c }
    sub alive        { return $_[0]->{alive} }
    sub _passthrough { return $_[0]->{passthrough} }
}
{
    package FakeClient;
    sub new { my ($c, %a) = @_; return bless { id => 'aa:bb:cc:dd:ee:01', formats => [qw(ogg pcm flac mp3)], %a }, $c }
    sub id       { return $_[0]->{id} }
    sub formats  { return @{ $_[0]->{formats} } }
    sub isSynced { return 0 }
    sub master   { return undef }
}

our $HELPER;    # what helperForClient answers (undef = no alive daemon)
{
    no warnings 'redefine';
    *Plugins::SpotOn::Unified::DaemonManager::helperForClient = sub { return $main::HELPER };
}

sub with_pref {
    my ($fmt, $code) = @_;
    local %Slim::Utils::Prefs::CLIENT_VALUES = (streamFormat => $fmt);
    return $code->();
}

sub served {
    my ($client) = @_;
    my $r = eval { $DM->resolveServedPassthroughForClient($client) };
    return defined $r ? $r : "ERR($@)";
}

my $client = FakeClient->new;

# --- F1 shape: the old pcm (non-passthrough) daemon still serves after a switch to ogg/auto
{
    local $HELPER = FakeHelper->new(passthrough => 0);
    for my $pref (qw(ogg auto)) {
        my $got = with_pref($pref, sub { served($client) });
        is($got, 0, "79-34 D-29: alive helper _passthrough=0 while pref is $pref -> served resolver answers 0 (F1 shape: tag soc, not son)");
    }
}

# --- F4 shape: the old passthrough daemon still serves after a switch to pcm
{
    local $HELPER = FakeHelper->new(passthrough => 1);
    my $got = with_pref('pcm', sub { served($client) });
    is($got, 1, "79-34 D-29: alive helper _passthrough=1 while pref is pcm -> served resolver answers 1 (F4 shape: tag son, not soc)");
}

# --- the invariant: pref x flag matrix with an alive helper answers the flag
{
    my %got;
    for my $pref (qw(auto ogg pcm flac mp3)) {
        for my $flag (0, 1) {
            local $HELPER = FakeHelper->new(passthrough => $flag);
            $got{"$pref/$flag"} = with_pref($pref, sub { served($client) });
        }
    }
    my %want = map { my $p = $_; map { ("$p/$_" => $_) } (0, 1) } qw(auto ogg pcm flac mp3);
    is_deeply(\%got, \%want, "79-34 D-29: matrix pref (auto ogg pcm flac mp3) x daemon flag (0 1) with an alive helper -> the answer equals the flag in all ten cells");
}

# --- no alive helper: the pref resolver answers (spawn-time truth)
{
    local $HELPER = undef;
    local $Plugins::SpotOn::Helper::CAP_PASSTHROUGH = 1;
    my $auto = with_pref('auto', sub { served($client) });
    my $autoWant = with_pref('auto', sub { $DM->resolvePassthroughForClient($client) });
    is_deeply([$auto, $autoWant], [1, 1], "79-34 D-29: no alive helper, pref auto, ogg-capable player, passthrough capability -> 1 (same as resolvePassthroughForClient)");

    my $pcm = with_pref('pcm', sub { served($client) });
    my $pcmWant = with_pref('pcm', sub { $DM->resolvePassthroughForClient($client) });
    is_deeply([$pcm, $pcmWant], [0, 0], "79-34 D-29: no alive helper, pref pcm -> 0 (same as resolvePassthroughForClient)");
}

# --- a helper that exists but is not alive, or has no flag yet, is no daemon
{
    local $HELPER = FakeHelper->new(passthrough => 0, alive => 0);
    my $dead = with_pref('ogg', sub { served($client) });
    local $HELPER = FakeHelper->new(passthrough => undef);
    my $noflag = with_pref('ogg', sub { served($client) });
    is_deeply([$dead, $noflag], [1, 1], "79-34 D-29: a dead helper or one without a spawn flag falls back to the pref resolver (ogg -> 1)");
}

# --- soloist short-circuit kept
# 79-35: on a tree whose soloist side is amputated (CI job "Amputation soloist") backendName() cannot name
# soloist - the role module is gone and it falls back to librespot - so the cell has a second, explicit
# expectation there: the alive helper's flag (1) answers. The cell never vanishes.
{
    local $Slim::Utils::Prefs::FAKE_VALUES{backend} = 'soloist';
    local $HELPER = FakeHelper->new(passthrough => 1);
    my $got = with_pref('ogg', sub { served($client) });
    my $soloist_side = -f "$project_dir/Plugins/SpotOn/Backend/Soloist.pm" ? 1 : 0;
    is($got, $soloist_side ? 0 : 1, $soloist_side
        ? "79-34 D-29: backend soloist -> 0 even with an alive passthrough helper (soloist short-circuit kept)"
        : "79-34 D-29: soloist side amputated, backend soloist falls back to librespot -> the alive helper's flag (1) answers");
}

# --- no client -> 0
{
    local $HELPER = FakeHelper->new(passthrough => 1);
    my $r = eval { $DM->resolveServedPassthroughForClient(undef) };
    is(defined $r ? $r : "ERR($@)", 0, "79-34 D-29: no client -> 0");
}

# --- the capability table reaches the new resolver
{
    my $name = Plugins::SpotOn::Backend::Librespot->capabilitiesDefault->{formats};
    is($name, 'resolveServedPassthroughForClient', "79-34 D-29: Backend::Librespot capabilitiesDefault->{formats} names the served resolver");
    ok($DM->can($name // ''), "79-34 D-29: DaemonManager can() the resolver the capability table names");
}

# --- the spawn and the restart trigger keep the pref (source cells, comment lines excluded)
sub code_of {
    my ($file, $from, $to) = @_;
    open(my $fh, '<', $file) or die "$file: $!";
    local $/;
    my $src = <$fh>;
    close $fh;
    if (defined $from) {
        $src =~ /(^sub \Q$from\E\b.*?)(?=^sub |\z)/ms or return undef;
        $src = $1;
    }
    return join("\n", grep { !/^\s*#/ } split /\n/, $src);
}
{
    my $daemon = code_of("$project_dir/Plugins/SpotOn/Unified/Daemon.pm");
    my $start  = code_of($module, 'startHelper');
    ok(defined $start, "79-34 D-29: startHelper found in DaemonManager.pm");
    like($daemon, qr/->resolvePassthroughForClient\(\$client\)/, "79-34 D-29: Daemon.pm spawn still calls the pref resolver (--passthrough flag)");
    unlike($daemon, qr/resolveServedPassthroughForClient/, "79-34 D-29: Daemon.pm spawn does not call the served resolver");
    like($start // '', qr/->resolvePassthroughForClient\(\$client\)/, "79-34 D-29: startHelper passthrough restart branch still calls the pref resolver");
    unlike($start // '', qr/resolveServedPassthroughForClient/, "79-34 D-29: startHelper does not call the served resolver");
}

done_testing();

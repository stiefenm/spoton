#!/usr/bin/perl
# quick 261112-ca5, R4 (REVIEW-3 WR-01 c): the contract between the login guard
# Plugins::SpotOn::Soloist::Quality::_loggedInNow and the REAL classes it reads.
#
# t/soloist/50 drives the guard against stub classes, so a renamed accessor or a
# changed return format in the real DaemonManager / SoloistDaemon / SoloistWS
# would pass there and silently stop every quality write in the field (the guard
# fails closed). This file loads the REAL DaemonManager, SoloistDaemon, SoloistWS
# and Quality and drives the four accesses (helperForClient, mac, alive, _ws,
# authState) through the real objects, the login state itself through the real
# auth_state message handler of SoloistWS.
#
# Only the LMS framework and the process behind the daemon are doubles
# (Test::FakeProc stands for the child process, as in t/soloist/51).
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";
for my $m (qw(Soloist/Quality.pm Unified/DaemonManager.pm Unified/SoloistDaemon.pm Unified/SoloistWS.pm)) {
    -f "$project_dir/Plugins/SpotOn/$m"
        or die "Plugins/SpotOn/$m not present in this checkout -- wrong project root or broken checkout (84-09: die, never skip)\n";
}

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

# A logger that records what the guard says (the guard must not warn on a healthy chain).
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
sub debug { }
sub is_info  { 1 }
sub is_debug { 0 }
sub is_warn  { 1 }
sub AUTOLOAD { }
sub can { 1 }
1;
END

write_stub($stub_dir, 'Slim::Utils::Prefs', <<'END');
package Slim::Utils::Prefs;
our %FAKE_VALUES = ( cachedir => '/tmp/spoton-test-cachedir', backend => 'soloist' );
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::preferences"} = \&preferences;
}
sub preferences { return bless { _ns => $_[0] }, 'Slim::Utils::Prefs' }
sub get      { my ($self, $key) = @_; return $FAKE_VALUES{$key}; }
sub set      { my ($self, $key, $val) = @_; $FAKE_VALUES{$key} = $val; }
sub client   { return bless {}, 'Slim::Utils::Prefs' }
sub setChange { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
my %STORE;
sub new    { return bless {}, shift }
sub get    { my ($self, $k) = @_; return $STORE{$k}; }
sub set    { my ($self, $k, $v, $ttl) = @_; $STORE{$k} = $v; }
sub remove { my ($self, $k) = @_; delete $STORE{$k}; }
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

# The real auth_state handler of SoloistWS decodes JSON: a JSON::PP-backed double.
write_stub($stub_dir, 'JSON::XS::VersionOneAndTwo', <<'END');
package JSON::XS::VersionOneAndTwo;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::to_json"} = sub {
        require JSON::PP;
        return JSON::PP->new->canonical->encode($_[0]);
    };
    *{"${caller}::from_json"} = sub {
        require JSON::PP;
        return JSON::PP->new->utf8(1)->decode($_[0]);
    };
}
1;
END

write_stub($stub_dir, 'Slim::Utils::OSDetect', <<'END');
package Slim::Utils::OSDetect;
sub details { return { osArch => 'x86_64-linux-gnu-thread-multi' } }
1;
END

# Array-based like the real Slim::Utils::Accessor (blessed ARRAY refs).
write_stub($stub_dir, 'Slim::Utils::Accessor', <<'END');
package Slim::Utils::Accessor;
use Scalar::Util qw(weaken);
my %slot;
sub new { return bless [], shift }
sub mk_accessor {
    my ($class, $type, @names) = @_;
    no strict 'refs';
    for my $name (@names) {
        my $n = $slot{$class}{$name};
        if (!defined $n) {
            $n = keys %{ $slot{$class} };
            $slot{$class}{$name} = $n;
        }
        if ($type eq 'weak') {
            *{"${class}::${name}"} = sub {
                my $self = shift;
                if (@_) {
                    $self->[$n] = shift;
                    weaken($self->[$n]) if ref $self->[$n];
                }
                return $self->[$n];
            };
        }
        else {
            *{"${class}::${name}"} = sub {
                my $self = shift;
                $self->[$n] = shift if @_;
                return $self->[$n];
            };
        }
    }
}
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Plugin', <<'END');
package Plugins::SpotOn::Plugin;
use constant SPOTON_CACHE_VERSION => 4;
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Unified::Daemon', <<'END');
package Plugins::SpotOn::Unified::Daemon;
sub new   { my ($class, $mac) = @_; return bless { mac => $mac, alive => 1 }, $class }
sub backendName { return 'librespot' }
sub mac   { return $_[0]->{mac} }
sub alive { my $s = shift; $s->{alive} = shift if @_; return $s->{alive} }
sub AUTOLOAD { return undef }
sub DESTROY { }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::API::Credentials', <<'END');
package Plugins::SpotOn::API::Credentials;
sub isCredentialError     { return 0 }
sub needsPlaybackAuth     { return 0 }
sub markNeedsPlaybackAuth { return 1 }
sub accountMismatch       { return 0 }
1;
END

# LMS player registry: helperForClient reads isSynced / master of the client and
# Slim::Player::Sync::slaves of the master (the Sync fallback).
write_stub($stub_dir, 'Slim::Player::Client', <<'END');
package Slim::Player::Client;
our %clients;    # mac => Test::Client
sub getClient { my ($mac) = @_; return $clients{$mac || ''}; }
sub clients   { return values %clients; }
package Test::Client;
sub new      { my ($class, %a) = @_; return bless { %a }, $class; }
sub id       { $_[0]->{id} }
sub name     { $_[0]->{name} // 'Test Player' }
sub model    { 'squeezelite' }
sub isSynced { $_[0]->{master} ? 1 : 0 }
sub master   { $_[0]->{master} }
package Slim::Player::Sync;
sub slaves { return () }
1;
END

BEGIN {
    no warnings 'redefine';
    *main::TRANSCODING = sub () { 0 };
    *main::WEBUI       = sub () { 0 };
    *main::SCANNER     = sub () { 0 };
    *main::INFOLOG     = sub () { 0 };
    *main::DEBUGLOG    = sub () { 0 };
    *main::ISWINDOWS   = sub () { 0 };
    *main::ISMAC       = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
}

unshift @INC, $stub_dir, $project_dir;

require_ok('Plugins::SpotOn::Soloist')
    or BAIL_OUT("Failed to load the real Plugins::SpotOn::Soloist");

{
    no warnings 'redefine';
    *Plugins::SpotOn::Soloist::get    = sub { return '/fake/cachedir/spoton/soloist/x86_64-linux/soloist' };
    *Plugins::SpotOn::Soloist::hasKey = sub { return 1 };
    *Plugins::SpotOn::Soloist::isPairedForClient = sub { return 1 };
}

require_ok('Plugins::SpotOn::Unified::DaemonManager') or BAIL_OUT("Failed to load the real DaemonManager");
require_ok('Plugins::SpotOn::Unified::SoloistDaemon') or BAIL_OUT("Failed to load the real SoloistDaemon");
require_ok('Plugins::SpotOn::Unified::SoloistWS')     or BAIL_OUT("Failed to load the real SoloistWS");
require_ok('Plugins::SpotOn::Soloist::Quality')       or BAIL_OUT("Failed to load the real Quality");

my $DM = 'Plugins::SpotOn::Unified::DaemonManager';
my $SD = 'Plugins::SpotOn::Unified::SoloistDaemon';
my $WS = 'Plugins::SpotOn::Unified::SoloistWS';
my $Q  = 'Plugins::SpotOn::Soloist::Quality';

# The child process behind the daemon is the only double below the real classes.
{
    package Test::FakeProc;
    sub new   { my ($c, %a) = @_; return bless { %a }, $c; }
    sub alive { return $_[0]->{alive} // 0; }
    sub die   { $_[0]->{alive} = 0; }
    sub pid   { return 12345; }
}

# SoloistDaemon::new would spawn the real binary (start()); every accessor, alive()
# and the registry in DaemonManager stay real.
{
    no warnings 'redefine';
    *Plugins::SpotOn::Unified::SoloistDaemon::new = sub {
        my ($class, $id) = @_;
        my $self = bless [], $class;
        $self->mac($id);
        $self->name('Test Player');
        $self->_proc(Test::FakeProc->new(alive => 1));
        $self->_startTimes([ time() ]);
        return $self;
    };
}

# ------------------------------------------------------------------
# 1. The names _loggedInNow uses exist on the real classes.
# ------------------------------------------------------------------
subtest 'the accessors the login guard reads exist on the real classes' => sub {
    ok($DM->can('helperForClient'), 'DaemonManager->helperForClient');
    ok($SD->can($_), "SoloistDaemon->$_") for qw(mac alive _ws);
    ok($WS->can('authState'), 'SoloistWS->authState');
    ok($Q->can('_loggedInNow'), 'Quality->_loggedInNow (the reader of all of the above)');
};

# ------------------------------------------------------------------
# 2. The real chain: registry -> daemon -> ws -> authState -> guard.
# ------------------------------------------------------------------
my $MAC = 'aa:bb:cc:dd:ee:01';
$Slim::Player::Client::clients{$MAC} = Test::Client->new(id => $MAC, name => 'Test Player');

my $helper = $DM->startHelper($MAC);
my $ws;

subtest 'the real helperForClient hands out the real SoloistDaemon with its own mac' => sub {
    ok($helper, 'startHelper registers an alive Soloist helper');
    isa_ok($helper, $SD, 'the registered helper');
    my $found = $DM->helperForClient($MAC);
    ok($found && $found == $helper, 'helperForClient($mac) returns that helper (mac given as a string)');
    ok($found->alive, 'alive() is true while the process lives');
    is(lc($found->mac), lc($MAC), 'mac() is the player mac');
    ok($found->can('_ws'), 'the helper can _ws (the can() check inside the guard)');
};

subtest 'the guard reads the real SoloistWS authState, set by the real auth_state handler' => sub {
    @Slim::Utils::Log::logged = ();
    is($Q->_loggedInNow($MAC), 0, 'no ws yet: not logged in (fail closed)');

    $ws = $WS->new(daemon => $helper, mac => $MAC, port => 45678);
    $helper->_ws($ws);
    is($Q->_loggedInNow($MAC), 0, 'a ws that has seen no auth_state: not logged in');

    my @flanks;
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Soloist::Quality::onLoginFlank = sub { push @flanks, $_[1] };
        $ws->_onMessage('{"type":"auth_state","logged_in":0,"is_active":0}');
        is($Q->_loggedInNow($MAC), 0, 'auth_state logged_in 0: not logged in');
        is(scalar(@flanks), 0, 'and no flank');

        $ws->_onMessage('{"type":"auth_state","logged_in":1,"is_active":0}');
        is($Q->_loggedInNow($MAC), 1, 'auth_state logged_in 1: logged in (the key the guard reads is the key the handler writes)');
        is_deeply(\@flanks, [ $MAC ], 'and the 0 -> 1 flank is what calls Quality->onLoginFlank');

        $ws->_onMessage('{"type":"auth_state","logged_in":0,"is_active":0}');
        is($Q->_loggedInNow($MAC), 0, 'logged out again: 0');
    }
    is_deeply([ grep { /login state of/ } @Slim::Utils::Log::logged ], [],
        'the healthy chain never makes the guard log an error');
};

subtest 'a dead process is not logged in, even with a logged_in mirror' => sub {
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Soloist::Quality::onLoginFlank = sub { };
        $ws->_onMessage('{"type":"auth_state","logged_in":1,"is_active":0}');
    }
    is($Q->_loggedInNow($MAC), 1, 'precondition: logged in');
    $helper->_proc->die;
    ok(!$helper->alive, 'the process is gone');
    is($Q->_loggedInNow($MAC), 0, 'a dead process: 0 (helperForClient returns nothing for a dead daemon)');
    $helper->_proc->{alive} = 1;
};

subtest 'a Sync slave without its own daemon never counts as logged in (helperForClient falls back to the master)' => sub {
    my $SLAVE = 'aa:bb:cc:dd:ee:02';
    $Slim::Player::Client::clients{$SLAVE} = Test::Client->new(
        id => $SLAVE, name => 'Slave', master => $Slim::Player::Client::clients{$MAC},
    );
    my $found = $DM->helperForClient($SLAVE);
    ok($found && $found == $helper, 'the real helperForClient answers the MASTER daemon for the slave (the premise of the mac comparison)');
    isnt(lc($found->mac), lc($SLAVE), 'whose mac is not the slave mac');
    is($Q->_loggedInNow($MAC),   1, 'the master itself is logged in');
    is($Q->_loggedInNow($SLAVE), 0, 'the slave is not: that daemon is another player\'s');
};

subtest 'an unknown player has no daemon: 0, and that is no error line' => sub {
    @Slim::Utils::Log::logged = ();
    $Slim::Player::Client::clients{'aa:bb:cc:dd:ee:03'} = Test::Client->new(id => 'aa:bb:cc:dd:ee:03');
    is($Q->_loggedInNow('aa:bb:cc:dd:ee:03'), 0, 'no registered helper');
    is(scalar(grep { /login state of/ } @Slim::Utils::Log::logged), 0, 'no error line for a plain absence');
};

done_testing();

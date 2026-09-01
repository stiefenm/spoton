#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# ============================================================
# Phase 76-02 gap fill (Nyquist validation): GH-131 --buffer-latency-ms.
# Prior coverage was a build/syntax gate only (`perl -c`) -- this test
# actually calls Plugins::SpotOn::Unified::Daemon->start() (via new())
# with a fake synced/unsynced client and asserts the spawned argv,
# following the isolated-require stub harness established by
# t/30_soloist_daemon.t.
# ============================================================

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname($test_dir);

my $module = "$project_dir/Plugins/SpotOn/Unified/Daemon.pm";
unless (-f $module) {
    plan skip_all => 'Plugins/SpotOn/Unified/Daemon.pm not present in this checkout';
}

my $stub_dir  = tempdir(CLEANUP => 1);
my $cache_dir = tempdir(CLEANUP => 1);
make_path("$cache_dir/spoton");

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

write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
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
sub AUTOLOAD { }
sub can { 1 }
1;
END

my $prefs_cache_dir = $cache_dir;
write_stub($stub_dir, 'Slim::Utils::Prefs', <<"END");
package Slim::Utils::Prefs;
my \%_ns_store = ( server => { cachedir => '$prefs_cache_dir', httpport => 9000, authorize => 0 } );
sub import {
    my \$class = shift;
    my \$caller = caller;
    no strict 'refs';
    *{"\${caller}::preferences"} = \\\&preferences;
}
sub preferences { my \$ns = \$_[0] eq 'Slim::Utils::Prefs' ? \$_[1] : \$_[0]; return bless { _ns => \$ns }, 'Slim::Utils::Prefs'; }
sub get { my (\$self, \$key) = \@_; return \$_ns_store{ \$self->{_ns} }{\$key}; }
sub set { my (\$self, \$key, \$val) = \@_; \$_ns_store{ \$self->{_ns} }{\$key} = \$val; }
sub client {
    my (\$self, \$client) = \@_;
    my \$ns = \$self->{_ns} . '_client';
    \$_ns_store{\$ns} ||= { enableSpotifyConnect => 1, discoveryDisabledByCrashLoop => 0, disableDiscovery => 0, digitalVolumeControl => undef, enableAutoplay => undef };
    return bless { _ns => \$ns }, 'Slim::Utils::Prefs';
}
1;
END

write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
sub killTimers { }
sub setTimer   { }
1;
END

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
        *{"${class}::${name}"} = sub {
            my $self = shift;
            $self->[$n] = shift if @_;
            return $self->[$n];
        };
    }
}
1;
END

write_stub($stub_dir, 'Slim::Player::Client', <<'END');
package Slim::Player::Client;
our $FAKE_CLIENT;
sub getClient { return $FAKE_CLIENT; }
1;
END

write_stub($stub_dir, 'Slim::Utils::Network', <<'END');
package Slim::Utils::Network;
sub serverAddr { return '127.0.0.1'; }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Helper', <<'END');
package Plugins::SpotOn::Helper;
sub get { return '/fake/soloist-helper'; }
sub getCapability { return 0; }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Plugin', <<'END');
package Plugins::SpotOn::Plugin;
sub _bitrateConfigForClient { return 320; }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Unified::DaemonManager', <<'END');
package Plugins::SpotOn::Unified::DaemonManager;
sub deviceNameForClient { return 'Test Player'; }
sub resolvePassthroughForClient { return 0; }
1;
END

# Records the argv the daemon would spawn, without launching a real process.
write_stub($stub_dir, 'Proc::Background', <<'END');
package Proc::Background;
our @LAST_ARGS;
our $LAST_PATH;
sub new {
    my ($class, $opts, $path, @args) = @_;
    @LAST_ARGS = @args;
    $LAST_PATH = $path;
    return bless {}, $class;
}
sub alive { return 1; }
1;
END

BEGIN {
    no warnings 'redefine';
    *main::INFOLOG   = sub () { 0 };
    *main::ISWINDOWS  = sub () { 0 };
    *main::ISMAC      = sub () { 0 };
}

unshift @INC, $stub_dir, $project_dir;

require_ok('Slim::Player::Client')
    or BAIL_OUT("Failed to load the Slim::Player::Client stub");
require_ok('Proc::Background')
    or BAIL_OUT("Failed to load the Proc::Background stub");

require_ok('Slim::Utils::Network')
    or BAIL_OUT("Failed to load the Slim::Utils::Network stub");
require_ok('Plugins::SpotOn::Helper')
    or BAIL_OUT("Failed to load the Plugins::SpotOn::Helper stub");
require_ok('Plugins::SpotOn::Plugin')
    or BAIL_OUT("Failed to load the Plugins::SpotOn::Plugin stub");
require_ok('Plugins::SpotOn::Unified::DaemonManager')
    or BAIL_OUT("Failed to load the DaemonManager stub");

require_ok('Plugins::SpotOn::Unified::Daemon')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Unified::Daemon");

package Test::FakeClient;
sub new {
    my ($class, %args) = @_;
    return bless { volume => 50, %args }, $class;
}
sub isSynced { return $_[0]->{isSynced}; }
sub model    { return $_[0]->{model} // 'squeezelite'; }
sub volume   { return $_[0]->{volume}; }

package main;

# ==================================================================
# Scenario 1: a synced, non-group player must spawn with
# --buffer-latency-ms 5000 (GH-131).
# ==================================================================
{
    my $client = Test::FakeClient->new(isSynced => 1, model => 'squeezelite');
    $Slim::Player::Client::FAKE_CLIENT = $client;
    @Proc::Background::LAST_ARGS = ();

    Plugins::SpotOn::Unified::Daemon->new('aa:bb:cc:dd:ee:01');

    my @args = @Proc::Background::LAST_ARGS;
    my ($idx) = grep { $args[$_] eq '--buffer-latency-ms' } 0 .. $#args;
    ok(defined $idx, 'GH-131: synced non-group player spawns with --buffer-latency-ms');
    is($args[$idx + 1], 5000, 'GH-131: --buffer-latency-ms value is 5000') if defined $idx;
}

# ==================================================================
# Scenario 2: an UNSYNCED player must NOT carry --buffer-latency-ms
# (default daemon buffer latency applies).
# ==================================================================
{
    my $client = Test::FakeClient->new(isSynced => 0, model => 'squeezelite');
    $Slim::Player::Client::FAKE_CLIENT = $client;
    @Proc::Background::LAST_ARGS = ();

    Plugins::SpotOn::Unified::Daemon->new('aa:bb:cc:dd:ee:02');

    my @args = @Proc::Background::LAST_ARGS;
    ok(!(grep { $_ eq '--buffer-latency-ms' } @args),
        'GH-131: an unsynced player does not get --buffer-latency-ms');
}

# ==================================================================
# Scenario 3: a synced player whose model is 'group' (the sync-group
# virtual player) must NOT get --buffer-latency-ms either (per-member
# arg, not group-level).
# ==================================================================
{
    my $client = Test::FakeClient->new(isSynced => 1, model => 'group');
    $Slim::Player::Client::FAKE_CLIENT = $client;
    @Proc::Background::LAST_ARGS = ();

    Plugins::SpotOn::Unified::Daemon->new('aa:bb:cc:dd:ee:03');

    my @args = @Proc::Background::LAST_ARGS;
    ok(!(grep { $_ eq '--buffer-latency-ms' } @args),
        'GH-131: a synced group-model player does not get --buffer-latency-ms');
}

done_testing();

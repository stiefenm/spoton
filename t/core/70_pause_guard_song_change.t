#!/usr/bin/perl
# 79-32 (D-27): the SpotOn PauseGuard (Plugin.pm _onModeChange arms it on a `playlist pause` / `pause` notification,
# _pauseGuardCheck re-applies a pause that came back to play within 5 s) must never re-apply a pause once the playing
# song has changed after the pause request. Forensics 79-R3 Part A (a1): a skip while paused followed by Play was re-paused
# 0.4 s into the new title (`[DIAG] PauseGuard: re-applying pause (swallowed 2.5s ago)`, server.log:50759 of 2026-10-22).
# The guard records [playlist index, url] of $client->playingSong when it arms and compares at check time; a pause
# swallowed on the SAME song (459c1dfd) is still re-applied exactly once.
# Every Slim module is stubbed below, so the file passes with the LMS tree hidden. Time is a fake clock: the test sets
# $main::NOW and fires the recorded Timers by hand.
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

write_stub($stub_dir, 'Log::Log4perl::Logger', <<'END');
package Log::Log4perl::Logger;
sub new     { bless {}, shift }
sub AUTOLOAD { }
sub can     { 1 }
1;
END

write_stub($stub_dir, 'Log::Log4perl', <<'END');
package Log::Log4perl;
sub get_logger { return bless {}, 'Log::Log4perl::Logger' }
sub init { }
1;
END

# the log keeps every warn line so the cells can read the [DIAG] PauseGuard lines
write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
use parent 'Exporter';
our @EXPORT_OK = qw(logger);
our @WARNS = ();
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub addLogCategory { return bless {}, 'Slim::Utils::Log' }
sub logger { return bless {}, 'Slim::Utils::Log' }
sub info     { }
sub warn     { shift; push @WARNS, join('', @_) }
sub error    { }
sub debug    { }
sub is_info  { 0 }
sub is_debug { 0 }
sub AUTOLOAD { }
sub can      { 1 }
1;
END

my $prefs_cache_dir = $cache_dir;
write_stub($stub_dir, 'Slim::Utils::Prefs', <<"END");
package Slim::Utils::Prefs;
my %_store;
my %_ns_store = ( server => { cachedir => '$prefs_cache_dir' } );

sub import {
    my \$class = shift;
    my \$caller = caller;
    no strict 'refs';
    *{"\${caller}::preferences"} = \\&preferences;
}

sub preferences {
    my \$ns = \$_[0] eq 'Slim::Utils::Prefs' ? \$_[1] : \$_[0];
    return bless { _ns => \$ns }, 'Slim::Utils::Prefs';
}

sub init {
    my (\$self, \$defaults) = \@_;
    for my \$k (keys \%{\$defaults}) {
        \$_store{ \$self->{_ns} }{\$k} //= \$defaults->{\$k};
    }
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
}

sub client {
    my (\$self, \$client) = \@_;
    my \$client_id = ref \$client ? "\$client" : (\$client // 'default');
    return bless { _ns => \$self->{_ns} . '_client_' . \$client_id }, 'Slim::Utils::Prefs';
}

sub setChange { }
sub AUTOLOAD  { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
my %_store;
my %_ttl;
sub new    { bless {}, shift }
sub get    { $_store{$_[1]} }
sub set    { $_store{$_[1]} = $_[2]; $_ttl{$_[1]} = $_[3]; 1 }
sub remove { delete $_store{$_[1]}; delete $_ttl{$_[1]} }
sub ttl    { $_ttl{$_[1]} }
sub clear  { %_store = (); %_ttl = () }
1;
END

# timers: a pending list; killTimers removes by (client, coderef), fire_timer runs the oldest pending one by hand
write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
our @pending = ();    # { client, at, cb, args }
our @killed  = ();    # [ client id or string, coderef ] per killTimers call
sub setTimer   { my ($c, $at, $cb, @a) = @_; push @pending, { client => $c, at => $at, cb => $cb, args => [@a] } }
sub killTimers {
    my ($c, $cb) = @_;
    push @killed, [ (ref $c && eval { $c->can('id') } ? $c->id : "$c"), $cb ];
    @pending = grep { !(defined $_->{client} && defined $c && "$_->{client}" eq "$c" && $_->{cb} == $cb) } @pending;
}
1;
END

write_stub($stub_dir, 'Slim::Utils::Strings', <<'END');
package Slim::Utils::Strings;
use parent 'Exporter';
our @EXPORT_OK = qw(string cstring);
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    for my $fn (@_) {
        *{"${caller}::${fn}"} = \&{$fn};
    }
}
sub string  { $_[-1] }
sub cstring { $_[-1] }
1;
END

write_stub($stub_dir, 'Slim::Utils::Unicode', <<'END');
package Slim::Utils::Unicode;
sub utf8toLatin1Transliterate { $_[1] }
1;
END

write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
sub new  { bless {}, shift }
sub get  { }
sub post { }
1;
END

# executeRequest records [ client id, @args ] (the guard's re-apply is executeRequest($client, ['pause', '1']))
write_stub($stub_dir, 'Slim::Control::Request', <<'END');
package Slim::Control::Request;
our @subscribed   = ();   # [ handler, filter ]
our @unsubscribed = ();   # handler
our @executed     = ();   # [ client id, @args ]
sub subscribe       { push @subscribed, [@_] }
sub unsubscribe     { push @unsubscribed, $_[0] }
sub addDispatch     { }
sub executeRequest  { my ($c, $args) = @_; push @executed, [ $c->id, @{$args || []} ] }
sub notifyFromArray { }
1;
END

write_stub($stub_dir, 'Slim::Plugin::OPMLBased', <<'END');
package Slim::Plugin::OPMLBased;
sub new  { bless {}, shift }
sub initPlugin { }
sub can  { 1 }
sub AUTOLOAD { }
1;
END

write_stub($stub_dir, 'Slim::Utils::PluginManager', <<'END');
package Slim::Utils::PluginManager;
sub isEnabled { 1 }
1;
END

write_stub($stub_dir, 'JSON::XS', <<'END');
package JSON::XS;
use parent 'Exporter';
our @EXPORT_OK = qw(encode_json decode_json);
sub encode_json { '{}' }
sub decode_json { {} }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::API::SpClient', <<'END');
package Plugins::SpotOn::API::SpClient;
sub getTrack { }
sub trackBatchSize { 200 }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Connect', <<'END');
package Plugins::SpotOn::Connect;
our $is_connect = 0;   # what isSpotifyConnect answers
sub isSpotifyConnect { return $is_connect }
sub shutdown { }
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

require Plugins::SpotOn::Plugin;
require Slim::Control::Request;    # the guard calls executeRequest; the recording stub above
my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');
$prefs->init({ recentSearches => [] });
$prefs->set('diagnosticMode', 1);

# ------------------------------------------------------------
# Fake clock and fakes: playmode / song / client / request
# ------------------------------------------------------------
our ($NOW, $MODE) = (1000.0, 'pause');
{
    no warnings 'redefine';
    *Time::HiRes::time = sub () { return $main::NOW };
}
sub Slim::Player::Source::playmode { return $main::MODE }

my %CLIENTS;    # id -> FakeClient, what Slim::Player::Client::getClient answers
sub Slim::Player::Client::getClient { return $CLIENTS{ $_[0] } }

{
    package FakeTrack; sub new { bless { url => $_[1] }, $_[0] } sub url { $_[0]{url} }
    package FakeSong;  sub new { bless { index => $_[1], url => $_[2] }, $_[0] } sub index { $_[0]{index} } sub track { FakeTrack->new($_[0]{url}) }
    # a client reads its playing song from a controller; the members of a sync group share ONE controller
    # (Slim/Player/Client.pm:1349 playingSong -> controller()->playingSong())
    package FakeClient;
    sub new { bless { id => $_[1], ctrl => $_[2] }, $_[0] }
    sub id { $_[0]{id} }
    sub master { $_[0] }
    sub playingSong { $_[0]{ctrl}{song} }
    package FakeRequest;
    sub new { my ($c, $client, @args) = @_; bless { client => $client, args => [@args] }, $c }
    sub client { $_[0]{client} }
    sub getRequest { $_[0]{args}[ $_[1] ] }
}

my $MAC1 = '02:00:00:5a:11:01';
my $MAC2 = '02:00:00:5a:11:02';
sub b22 { sprintf('%022d', $_[0]) }
my $URL_A = 'spoton://track:' . b22(1);
my $URL_B = 'spoton://track:' . b22(2);

sub reset_t70 {
    @Slim::Utils::Timers::pending = ();
    @Slim::Utils::Timers::killed  = ();
    @Slim::Control::Request::executed = ();
    @Slim::Utils::Log::WARNS = ();
    $Plugins::SpotOn::Connect::is_connect = 0;
    $prefs->set('diagnosticMode', 1);
    %CLIENTS = ();
    ($NOW, $MODE) = (1000.0, 'pause');
}
sub mkclient {
    my ($id, $idx, $url, $ctrl) = @_;
    $ctrl ||= { song => FakeSong->new($idx, $url) };
    return $CLIENTS{$id} = FakeClient->new($id, $ctrl);
}
# a `playlist pause 1` / `pause 1` notification as _onModeChange sees it (mode pause)
sub press_pause { my ($c) = @_; $MODE = 'pause'; Plugins::SpotOn::Plugin::_onModeChange(FakeRequest->new($c, 'pause', 1)) }
# advance the fake clock to $t and run the oldest pending Timers entry (the 2.5 s check or a 1 s re-check)
sub fire_timer {
    my ($t) = @_;
    $NOW = $t;
    my $e = shift @Slim::Utils::Timers::pending or return 0;
    $e->{cb}->($e->{client}, @{ $e->{args} });
    return 1;
}
sub reapplied { scalar grep { $_->[1] eq 'pause' && ($_->[2] // '') eq '1' } @Slim::Control::Request::executed }
sub guard_lines { grep { /PauseGuard:/ } @Slim::Utils::Log::WARNS }

my $have = defined(&Plugins::SpotOn::Plugin::_pauseGuardCheck) ? 1 : 0;
ok($have, '79-32 D-27: Plugin.pm has _pauseGuardCheck');

# --- a skip while paused, then Play: the 2.5 s check finds another song and drops the guard (the 79-30 stutter case)
{
    reset_t70();
    my $c = mkclient($MAC1, 0, $URL_A);
    press_pause($c);
    is(scalar(@Slim::Utils::Timers::pending), 1, '79-32 D-27: a pause notification on a Browse song arms the guard (one 2.5 s timer)');
    $c->{ctrl}{song} = FakeSong->new(1, $URL_B);    # `playlist index +1`
    $MODE = 'play';                                 # `play`
    fire_timer(1002.5);
    is(reapplied(), 0, '79-32 D-27: after a skip (playlist index 0 -> 1) and play the pause is NOT re-applied');
    my ($d) = guard_lines();
    like($d // '', qr/^\[DIAG\] PauseGuard: dropped, song changed since the pause request \(0:\Q$URL_A\E -> 1:\Q$URL_B\E\) mac=\Q$MAC1\E$/,
        '79-32 D-27: the drop writes the [DIAG] PauseGuard: dropped line with both song identities and the MAC');
    is(scalar(@Slim::Utils::Timers::pending), 0, '79-32 D-27: the dropped guard leaves no re-check timer behind');
    Plugins::SpotOn::Plugin::_pauseGuardCheck($c);
    is(reapplied(), 0, '79-32 D-27: the guard is gone after the drop (a stray second check does nothing)');
}

# --- the song changes between two 1 s re-checks (still paused at 2.5 s, play and a new song at 3.5 s)
{
    reset_t70();
    my $c = mkclient($MAC1, 0, $URL_A);
    press_pause($c);
    fire_timer(1002.5);                             # same song, still paused -> re-check in 1 s
    is(scalar(@Slim::Utils::Timers::pending) . '/' . reapplied(), '1/0', '79-32 D-27: same song, still paused at 2.5 s -> a 1 s re-check, nothing applied');
    $c->{ctrl}{song} = FakeSong->new(1, $URL_B);
    $MODE = 'play';
    fire_timer(1003.5);
    is(reapplied(), 0, '79-32 D-27: song changed and mode play between two re-checks -> the pause is NOT re-applied');
    like((guard_lines())[0] // '', qr/PauseGuard: dropped, song changed since the pause request/, '79-32 D-27: the re-check drop is logged too');
}

# --- the same playlist position, another url (playlist replaced) counts as a change
{
    reset_t70();
    my $c = mkclient($MAC1, 0, $URL_A);
    press_pause($c);
    $c->{ctrl}{song} = FakeSong->new(0, $URL_B);
    $MODE = 'play';
    fire_timer(1002.5);
    is(reapplied(), 0, '79-32 D-27: the same index with another url is a song change -> NOT re-applied');
    like((guard_lines())[0] // '', qr/dropped, song changed since the pause request \(0:\Q$URL_A\E -> 0:\Q$URL_B\E\) mac=\Q$MAC1\E/, '79-32 D-27: the url-change drop names both identities');
}

# --- the 459c1dfd case: a pause swallowed on the SAME song (a rebuilt Song object included) is re-applied exactly once
{
    reset_t70();
    my $c = mkclient($MAC1, 3, $URL_A);
    press_pause($c);
    $c->{ctrl}{song} = FakeSong->new(3, $URL_A);    # a resume may rebuild the Song object for the same title
    $MODE = 'play';
    fire_timer(1002.5);
    is(reapplied(), 1, '79-32 D-27: same index and url, mode play at 2.5 s -> pause re-applied exactly once');
    is(join('|', @{ $Slim::Control::Request::executed[0] }), "$MAC1|pause|1", '79-32 D-27: the re-apply is executeRequest($client, [pause, 1]) on the right player');
    my @g = guard_lines();
    is(scalar(@g), 1, '79-32 D-27: one guard line for the re-apply');
    like($g[0] // '', qr/^\[DIAG\] PauseGuard: re-applying pause \(swallowed 2\.5s ago\) mac=\Q$MAC1\E$/, '79-32 D-27: the re-apply line carries the MAC (the 79-30 line had none)');
    Plugins::SpotOn::Plugin::_pauseGuardCheck($c);
    is(reapplied(), 1, '79-32 D-27: a second check does not re-apply again');
}

# --- a sync group: master and slave share ONE controller, so the shared playingSong decides for either member
{
    reset_t70();
    my $ctrl = { song => FakeSong->new(0, $URL_A) };
    my $master = mkclient($MAC1, 0, $URL_A, $ctrl);
    my $slave  = mkclient($MAC2, 0, $URL_A, $ctrl);
    press_pause($slave);
    $ctrl->{song} = FakeSong->new(1, $URL_B);       # the group's skip
    $MODE = 'play';
    fire_timer(1002.5);
    is(reapplied(), 0, '79-32 D-27: sync group, guard armed on the slave: the shared song changed -> NOT re-applied');
    like((guard_lines())[0] // '', qr/dropped, song changed since the pause request .* mac=\Q$MAC2\E$/, '79-32 D-27: the slave drop line carries the slave MAC');
    reset_t70();
    $ctrl = { song => FakeSong->new(0, $URL_A) };
    $master = mkclient($MAC1, 0, $URL_A, $ctrl);
    $slave  = mkclient($MAC2, 0, $URL_A, $ctrl);
    press_pause($master);
    $ctrl->{song} = FakeSong->new(1, $URL_B);
    $MODE = 'play';
    fire_timer(1002.5);
    is(reapplied(), 0, '79-32 D-27: sync group, guard armed on the master: the shared song changed -> NOT re-applied');
}

# --- the guard's other exits stay: `pause 0` and `playlist pause 0` clear it, a Connect session is never touched,
# --- shutdownPlugin empties it, an old guard on the same song ends without a re-apply
{
    reset_t70();
    my $c = mkclient($MAC1, 0, $URL_A);
    press_pause($c);
    $MODE = 'play';
    Plugins::SpotOn::Plugin::_onPauseCommand(FakeRequest->new($c, 'pause', 0));
    is(scalar(@Slim::Utils::Timers::pending), 0, '79-32 D-27: `pause 0` kills the guard timer');
    Plugins::SpotOn::Plugin::_pauseGuardCheck($c);
    is(reapplied(), 0, '79-32 D-27: after `pause 0` a stray check re-applies nothing (guard and stored song are cleared)');

    reset_t70();
    $c = mkclient($MAC1, 0, $URL_A);
    press_pause($c);
    $MODE = 'play';
    Plugins::SpotOn::Plugin::_onModeChange(FakeRequest->new($c, 'pause', 0));    # the `playlist pause 0` notification, mode play
    is(scalar(@Slim::Utils::Timers::pending), 0, '79-32 D-27: `playlist pause 0` (mode play) kills the guard timer');
    Plugins::SpotOn::Plugin::_pauseGuardCheck($c);
    is(reapplied(), 0, '79-32 D-27: after `playlist pause 0` a stray check re-applies nothing');

    reset_t70();
    $c = mkclient($MAC1, 0, $URL_A);
    press_pause($c);
    Plugins::SpotOn::Plugin::_onPauseCommand(FakeRequest->new($c, 'pause', 1));    # `pause 1` must not clear anything
    is(scalar(@Slim::Utils::Timers::pending), 1, '79-32 D-27: `pause 1` leaves the armed guard alone');
}
{
    reset_t70();
    $Plugins::SpotOn::Connect::is_connect = 1;
    my $c = mkclient($MAC1, 0, $URL_A);
    press_pause($c);
    is(scalar(@Slim::Utils::Timers::pending), 0, '79-32 D-27: a Connect session never arms the guard');
    # armed on a Browse song, then the session turns out to be Connect: the check ends with neither a re-apply nor a dropped line
    reset_t70();
    $c = mkclient($MAC1, 0, $URL_A);
    press_pause($c);
    $Plugins::SpotOn::Connect::is_connect = 1;
    $c->{ctrl}{song} = FakeSong->new(1, $URL_B);
    $MODE = 'play';
    fire_timer(1002.5);
    is(reapplied() . '/' . scalar(guard_lines()), '0/0', '79-32 D-27: a Connect session never re-applies and never logs the dropped line');
}
{
    reset_t70();
    my $c = mkclient($MAC1, 0, $URL_A);
    press_pause($c);
    Plugins::SpotOn::Plugin->shutdownPlugin();
    is(scalar(grep { $_->[0] eq $MAC1 && $_->[1] == \&Plugins::SpotOn::Plugin::_pauseGuardCheck } @Slim::Utils::Timers::killed) >= 2 ? 'killed' : 'not killed', 'killed',
        '79-32 D-27: shutdownPlugin kills the guard timer of every armed player');
    is(scalar(@Slim::Utils::Timers::pending), 0, '79-32 D-27: shutdownPlugin leaves no guard timer pending');
    $MODE = 'play';
    Plugins::SpotOn::Plugin::_pauseGuardCheck($c);
    is(reapplied(), 0, '79-32 D-27: after shutdownPlugin both guard hashes are empty (a stray check re-applies nothing)');
}
{
    reset_t70();
    my $c = mkclient($MAC1, 2, $URL_A);
    press_pause($c);                                 # armed at t=1000, the mode stays pause
    fire_timer(1002.5);
    fire_timer(1003.5);
    fire_timer(1004.5);
    is(scalar(@Slim::Utils::Timers::pending), 1, '79-32 D-27: at 4.5 s the guard on the same song still re-checks');
    fire_timer(1005.5);
    is(scalar(@Slim::Utils::Timers::pending) . '/' . reapplied() . '/' . scalar(guard_lines()), '0/0/0',
        '79-32 D-27: a guard older than 5 s on the same song in mode pause ends: no timer, no re-apply, no DIAG line');
    $MODE = 'play';
    Plugins::SpotOn::Plugin::_pauseGuardCheck($c);
    is(reapplied(), 0, '79-32 D-27: the ended guard stays ended');
}

done_testing();

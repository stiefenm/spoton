#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use Digest::MD5 qw(md5_hex);
use Time::HiRes ();

# ============================================================
# Phase 84 Plan 06 (D-08): librespot Connect characterization.
#
# t/37_connect_lifecycle.t pins Connect.pm with source-level regexes ("Connect.pm
# has no isolated unit harness", Phase 73-03 D4). This file is the first
# behavioural harness: the real Connect.pm is loaded against stubs and the
# librespot paths are DRIVEN -- the five /control/* endpoints reached
# through _sendControlCommand, the spoton://connect-<ts> URL choice on
# start / resume / ready, and the seven-verb spottyconnect dispatch.
# The current code is the oracle; the backend seam (84-07..84-09) must keep
# exactly this.
#
# Never skipped (characterization of existing code: a missing module
# dies). SPOTON_MODULE_ROOT points the test at a mutated copy of
# Plugins/SpotOn for the mutation proofs recorded in the 84-06 SUMMARY.
# Root resolution is two levels while flat under t/ (84-09 moves it).
# ============================================================

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";
my $module_root = $ENV{SPOTON_MODULE_ROOT} || $project_dir;

die "t/56: $module_root/Plugins/SpotOn/Connect.pm is missing -- "
  . "characterization tests of existing code must not skip\n"
    unless -f "$module_root/Plugins/SpotOn/Connect.pm";

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

# ------------------------------------------------------------
# LMS stubs
# ------------------------------------------------------------
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

write_stub($stub_dir, 'Slim::Utils::Prefs', <<'END');
package Slim::Utils::Prefs;
our %FAKE;
our %CLIENT;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::preferences"} = \&preferences;
}
sub preferences { return bless { _ns => $_[0] }, 'Slim::Utils::Prefs' }
sub get    { my ($self, $key) = @_; return $FAKE{$key}; }
sub set    { my ($self, $key, $val) = @_; $FAKE{$key} = $val; }
sub client { return bless {}, 'Slim::Utils::Prefs::Client' }
package Slim::Utils::Prefs::Client;
sub get { my ($self, $key) = @_; return $Slim::Utils::Prefs::CLIENT{$key}; }
1;
END

write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
our %STORE;
sub new    { return bless {}, shift }
sub get    { my ($self, $key) = @_; return $STORE{$key}; }
sub set    { my ($self, $key, $val) = @_; $STORE{$key} = $val; }
sub remove { my ($self, $key) = @_; delete $STORE{$key}; }
1;
END

# 79-28 D-23: _seekPositionFromRequest resolves a relative seek against
# Slim::Player::Source::songTime; the test sets $SONGTIME.
{
    package Slim::Player::Source;
    our $SONGTIME = 0;
    sub songTime { return $SONGTIME; }
}

# Call recorder: Connect.pm arms/kills timers for the volume debounce and
# the newTrack fallback.
write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
our (@SET, @KILL, @TIMERS);
# 79-69: @TIMERS is the live view (setTimer adds, killTimers removes) the
# power-off wait cells fire from; @SET / @KILL stay the call recorders.
sub killTimers { push @KILL, [@_]; my ($o, $cb) = @_; @TIMERS = grep { !($_->[0] == $o && $_->[2] == $cb) } @TIMERS; }
sub setTimer   { push @SET,  [@_]; push @TIMERS, [@_]; }
1;
END

# The control channel under test: records every instance with its two
# callbacks, its options, and the post() arguments.
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
our @POSTS;
sub new {
    my ($class, $ok, $err, $opts) = @_;
    return bless { ok => $ok, err => $err, opts => $opts }, $class;
}
sub post {
    my ($self, $url, @rest) = @_;
    $self->{url}  = $url;
    $self->{rest} = [@rest];
    push @POSTS, $self;
    return $self;
}
sub fire_ok    { my $s = shift; $s->{ok}->($s); }
sub fire_error { my ($s, $error, $response) = @_; $s->{err}->($s, $error, $response); }
1;
END

# JSON::XS is not installed in the sandbox (t/28 stubs it as '{}'); the
# body of /control/volume is part of what is characterized, so this stub
# encodes for real, canonically.
write_stub($stub_dir, 'JSON::XS::VersionOneAndTwo', <<'END');
package JSON::XS::VersionOneAndTwo;
use JSON::PP ();
sub import {
    my $caller = caller;
    no strict 'refs';
    my $j = JSON::PP->new->canonical;
    *{"${caller}::to_json"}   = sub { $j->encode($_[0]) };
    *{"${caller}::from_json"} = sub { $j->decode($_[0]) };
}
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Plugin', <<'END');
package Plugins::SpotOn::Plugin;
use constant SPOTON_CACHE_VERSION => 4;
sub _pluginDataFor { return 'test-basedir' }
sub _largestImage { return undef }
1;
END

# Outgoing requests (Connect.pm creates, source-marks and executes them)
# land in @SENT; subscribe/addDispatch registrations land in their lists.
write_stub($stub_dir, 'Slim::Control::Request', <<'END');
package Slim::Control::Request;
our (@SENT, @DISPATCH, @SUBSCRIBED, @UNSUBSCRIBED, @NOTIFIED);
sub new {
    my ($class, $id, $args) = @_;
    return bless { id => $id, args => [@{ $args || [] }], source => undef }, $class;
}
sub source  { my $s = shift; $s->{source} = shift if @_; return $s->{source}; }
sub execute { my $s = shift; push @SENT, { id => $s->{id}, args => [@{ $s->{args} }], source => $s->{source} }; }
sub addDispatch   { push @DISPATCH, [@_]; }
sub subscribe     { push @SUBSCRIBED, [@_]; }
sub unsubscribe   { push @UNSUBSCRIBED, [@_]; }
sub notifyFromArray { push @NOTIFIED, [@_]; }
1;
END

write_stub($stub_dir, 'Slim::Player::Client', <<'END');
package Slim::Player::Client;
sub getClient { return undef }
1;
END

# DaemonManager: only the calls Connect.pm's librespot paths make. 84-07:
# backendFor hands out the REAL Backend::Librespot role (the HTTP control
# sender moved there), so the POSTs below are now captured at the role --
# the assertions themselves are unchanged.
write_stub($stub_dir, 'Plugins::SpotOn::Unified::DaemonManager', <<'END');
package Plugins::SpotOn::Unified::DaemonManager;
our $HELPER;
our $PORT   = 4242;
our $UPTIME = 0;
our @STOPPED;
sub helperForClient     { return $HELPER; }
sub streamPortForClient { return $PORT; }
sub uptime              { return $UPTIME; }
sub stopHelper          { shift; push @STOPPED, [@_]; }
sub backendFor {
    my ($class, $c) = @_;
    require Plugins::SpotOn::Backend::Librespot;
    my $be = Plugins::SpotOn::Backend::Librespot->new(ref $c ? $c->id : $c);
    $be->client($c) if ref $c;
    return $be;
}
1;
END

# Control: a librespot player has NO Control instance -- for_client returns
# undef, which is what routes every handler into its librespot fallthrough.
write_stub($stub_dir, 'Plugins::SpotOn::Soloist::Control', <<'END');
package Plugins::SpotOn::Soloist::Control;
our $CALLS = 0;
sub for_client { $CALLS++; return undef; }
sub HOLD_CAP_S     { 30 }
sub HOLD_RECHECK_S { 1 }
sub HOLD_MAX_S     { 60 }
1;
END

# Web API fallback (D-15) recorder.
write_stub($stub_dir, 'Plugins::SpotOn::API::Client', <<'END');
package Plugins::SpotOn::API::Client;
our @CALLS;
sub playerPause  { my ($c, @a) = @_; push @CALLS, ['playerPause',  @a[0 .. $#a - 1]]; }
sub playerPlay   { my ($c, @a) = @_; push @CALLS, ['playerPlay',   @a[0 .. $#a - 1]]; }
sub playerVolume { my ($c, @a) = @_; push @CALLS, ['playerVolume', @a[0 .. $#a - 1]]; }
sub playerSeek   { my ($c, @a) = @_; push @CALLS, ['playerSeek',   @a[0 .. $#a - 1]]; }
1;
END

# 85-07 D-10 (T-85-26): the status page ring -- recorder for the "Daemon nicht erreichbar" entry.
write_stub($stub_dir, 'Plugins::SpotOn::Status', <<'END');
package Plugins::SpotOn::Status;
our (@RECORDED, @CLEARED, %HAS);
sub recordError {
    my ($class, $level, $module, $message, $key) = @_;
    push @RECORDED, [ $level, $module, $message, $key ];
    $HAS{ $module . '|' . ($key // '') } = 1;
}
sub clearError {
    my ($class, $module, $key) = @_;
    push @CLEARED, [ $module, $key ];
    delete $HAS{ $module . '|' . ($key // '') };
}
sub hasError {
    my ($class, $module, $key) = @_;
    return $HAS{ $module . '|' . ($key // '') } ? 1 : 0;
}
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

unshift @INC, $stub_dir, $module_root;

require_ok('Plugins::SpotOn::Plugin')
    or BAIL_OUT("Failed to load the Plugins::SpotOn::Plugin stub");
# Connect.pm calls these LMS packages without loading them itself (LMS has
# them resident); the stubs must be loaded before the first handler runs.
for my $stub (qw(Slim::Control::Request Slim::Player::Client Plugins::SpotOn::Unified::DaemonManager
                 Plugins::SpotOn::Soloist::Control Plugins::SpotOn::API::Client Plugins::SpotOn::Status)) {
    require_ok($stub) or BAIL_OUT("Failed to load the $stub stub");
}
require_ok('Plugins::SpotOn::Connect')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Connect");

my $CONNECT = 'Plugins::SpotOn::Connect';

# _fetchTrackMetadata talks to the Web API; its call (who asked for which
# track) is what the handlers' contract is, not its body.
my @FETCH;
{
    no warnings 'redefine';
    *Plugins::SpotOn::Connect::_fetchTrackMetadata = sub { push @FETCH, [ $_[1] ]; };
}

# ------------------------------------------------------------
# Test doubles
# ------------------------------------------------------------
{
    package MockSong;
    sub new {
        my ($class, %a) = @_;
        return bless { url => $a{url}, info => $a{info}, startOffset => undef, streamUrl => $a{streamUrl} }, $class;
    }
    sub track       { return $_[0]; }          # ->track->url
    sub url         { return $_[0]->{url}; }
    sub streamUrl   { return $_[0]->{streamUrl} // $_[0]->{url}; }
    sub pluginData  { my ($s, $k) = @_; return $k eq 'info' ? $s->{info} : undef; }
    sub startOffset { my $s = shift; $s->{startOffset} = shift if @_; return $s->{startOffset}; }

    package MockController;
    sub new { return bless {}, shift }
    sub isStreaming  { 1 }
    sub isStreamout  { 0 }
    sub streamingSong { undef }
    sub playingSong   { undef }
    sub jumpToTime    { }

    package MockClient;
    my $seq = 0;
    sub new {
        my ($class, %a) = @_;
        $seq++;
        return bless {
            id      => sprintf('aa:bb:cc:dd:ee:%02x', $seq),
            playing => ($a{playing} // 0),
            paused  => ($a{paused} // 0),
            power   => ($a{power} // 1),
            elapsed => ($a{elapsed} // 0),
            volume  => ($a{volume} // 55),
            song    => $a{song},
            data    => {},
            playPointCalls => [],
        }, $class;
    }
    sub id        { return $_[0]->{id}; }
    sub master    { return $_[0]; }
    sub isPlaying { return $_[0]->{playing}; }
    sub isPaused  { return $_[0]->{paused}; }
    sub power     { return $_[0]->{power}; }
    sub volume    { return $_[0]->{volume}; }
    sub songElapsedSeconds { return $_[0]->{elapsed}; }
    sub playingSong { return $_[0]->{song}; }
    sub controller  { return MockController->new; }
    sub playPoint   { my $s = shift; push @{ $s->{playPointCalls} }, [@_]; }
    sub pluginData {
        my $s = shift;
        return $s->{data}{ $_[0] } if @_ == 1;
        # 79-69 (GH #151): LMS's real rule, Slim/Player/Client.pm:1253 -
        # `if ( defined $value )`: an undef value does NOT write.
        while (@_) { my ($k, $v) = splice(@_, 0, 2); $s->{data}{$k} = $v if defined $v; }
        return;
    }

    package MockHelper;        # a librespot helper: not a SoloistDaemon
    sub new   { return bless {}, shift }
    sub alive { 1 }
    sub _streamPort { 4242 }

    package Test::Req;         # an incoming LMS request handed to a handler
    sub new {
        my ($class, %a) = @_;
        return bless { client => $a{client}, cmd => ($a{cmd} || []), params => ($a{params} || {}),
                       source => $a{source} }, $class;
    }
    sub client   { return $_[0]->{client}; }
    sub source   { my $s = shift; $s->{source} = shift if @_; return $s->{source}; }
    sub getParam { return $_[0]->{params}{ $_[1] }; }
    sub isCommand {
        my ($s, $spec) = @_;
        for my $i (0 .. $#$spec) {
            my $c = $s->{cmd}[$i];
            return 0 unless defined $c && grep { $_ eq $c } @{ $spec->[$i] };
        }
        return 1;
    }
}

my $C;                   # the client of the current scenario
my $DM = 'Plugins::SpotOn::Unified::DaemonManager';

sub fresh {
    my (%a) = @_;
    $CONNECT->releaseConnectClaim($C) if $C;      # no claim leaks across scenarios
    @Slim::Control::Request::SENT = ();
    @Slim::Control::Request::NOTIFIED = ();
    @Slim::Networking::SimpleAsyncHTTP::POSTS = ();
    @Plugins::SpotOn::API::Client::CALLS = ();
    @Plugins::SpotOn::Status::RECORDED = ();
    @Plugins::SpotOn::Status::CLEARED  = ();
    %Plugins::SpotOn::Status::HAS      = ();
    @Slim::Utils::Timers::SET = ();
    @Slim::Utils::Timers::KILL = ();
    @Slim::Utils::Timers::TIMERS = ();
    @FETCH = ();
    %Slim::Utils::Cache::STORE = ();
    %Slim::Utils::Prefs::CLIENT = ();
    $Slim::Utils::Prefs::FAKE{backend} = 'librespot';
    $Plugins::SpotOn::Unified::DaemonManager::HELPER = MockHelper->new;
    $Plugins::SpotOn::Unified::DaemonManager::PORT   = 4242;
    $Plugins::SpotOn::Unified::DaemonManager::UPTIME = 0;
    $C = MockClient->new(%a);
    return $C;
}

sub sent  { return @Slim::Control::Request::SENT; }
sub posts { return @Slim::Networking::SimpleAsyncHTTP::POSTS; }
sub cmds  { return map { join(' ', @{ $_->{args} }) } sent(); }

# 79-69: the saved pre-Connect power state through Connect.pm's reader (a
# cleared state is a sentinel); at RED the sub is absent and the raw value is read.
sub prev_power {
    my ($client) = @_;
    my $f = Plugins::SpotOn::Connect->can('_prevPowerGet');
    return $f ? $f->($client) : $client->pluginData('connectPrevPower');
}

# 79-69: fire the due _powerOffDue timers of the client at (now + $after_s)
sub fire_power_off {
    my ($client, $after_s) = @_;
    my $now = Time::HiRes::time() + $after_s;
    my $cb  = \&Plugins::SpotOn::Connect::_powerOffDue;
    my @due = grep { $_->[2] == $cb && $_->[0] == $client && $_->[1] <= $now } @Slim::Utils::Timers::TIMERS;
    my %gone = map { ("$_" => 1) } @due;
    @Slim::Utils::Timers::TIMERS = grep { !$gone{"$_"} } @Slim::Utils::Timers::TIMERS;
    for my $t (@due) { my ($obj, undef, $f, @extra) = @$t; $f->($obj, @extra); }
    return scalar(@due);
}

my $CONNECT_SRC = 'Plugins::SpotOn::Connect';

# ============================================================
# 0. Registration: the spottyconnect dispatch and the subscribers
# ============================================================
$CONNECT->initConnectHandlers();

my @dispatch = @Slim::Control::Request::DISPATCH;
is(scalar(@dispatch), 1, 'initConnectHandlers registers exactly one dispatch entry');
is_deeply($dispatch[0][0], ['spottyconnect', '_cmd'], "dispatch command is ['spottyconnect', '_cmd']");
is_deeply([ @{ $dispatch[0][1] }[0 .. 2] ], [1, 0, 1], 'dispatch flags are [1, 0, 1, ...]');
is($dispatch[0][1][3], \&Plugins::SpotOn::Connect::_connectEvent, 'dispatch handler is _connectEvent');
my $DISPATCH_CB = $dispatch[0][1][3];

# 84.2-02: the eighth subscriber is _onLmsPlaylistChanged (CAUSE-2 prefetch wish).
# 79-70 BR4-02: the ninth is _onPower (a manual power-on inside the power-off wait cancels it).
is(scalar(@Slim::Control::Request::SUBSCRIBED), 9, 'initConnectHandlers subscribes nine LMS-side handlers (incl. _onLmsPlaylistChanged, _onPower)');
is_deeply([ sort { $a cmp $b } map { $_->[0] } @Slim::Control::Request::SUBSCRIBED ],
          [ sort { $a cmp $b } (\&Plugins::SpotOn::Connect::_onNewSong, \&Plugins::SpotOn::Connect::_onPause,
                  \&Plugins::SpotOn::Connect::_onVolume,  \&Plugins::SpotOn::Connect::_onSeek,
                  \&Plugins::SpotOn::Connect::_onPlaylistJump, \&Plugins::SpotOn::Connect::_onLmsStop,
                  \&Plugins::SpotOn::Connect::_onLmsClear, \&Plugins::SpotOn::Connect::_onLmsPlaylistChanged,
                  \&Plugins::SpotOn::Connect::_onPower) ],
          'the nine subscribers are _onNewSong/_onPause/_onVolume/_onSeek/_onPlaylistJump/_onLmsStop/_onLmsClear/_onLmsPlaylistChanged/_onPower');

# Drive one spottyconnect verb through the registered dispatch coderef.
sub ev {
    my ($verb, $p2, $p3, $p4, %extra) = @_;
    my $req = Test::Req->new(
        client => $C,
        cmd    => ['spottyconnect', $verb],
        params => { _cmd => $verb, _p2 => $p2, _p3 => $p3, _p4 => $p4 },
        %extra,
    );
    $DISPATCH_CB->($req);
}

# ============================================================
# 1. Verb 'start' -- spoton://connect-<ts>
# ============================================================
{
    fresh(playing => 0, power => 0);
    my $t0 = Time::HiRes::time();
    ev('start', 'TRK111');
    my @s = sent();
    is(scalar(@s), 1, 'start: exactly one request is issued');
    is_deeply([ @{ $s[0]{args} }[0, 1] ], ['playlist', 'play'], 'start: the request is playlist play');
    like($s[0]{args}[2], qr/^spoton:\/\/connect-\d+$/, 'start: librespot play URL is spoton://connect-<ts>');
    my ($ms) = $s[0]{args}[2] =~ /connect-(\d+)$/;
    ok(defined $ms && $ms / 1000 >= $t0 - 1 && $ms / 1000 <= Time::HiRes::time() + 1,
        'start: <ts> is the current time in milliseconds');
    is($s[0]{source}, $CONNECT_SRC, 'start: the play request is source-marked (loop prevention T-05-13)');
    is($s[0]{id}, $C->id, 'start: the request targets the event player');
    ok($CONNECT->isSpotifyConnect($C), 'start: the Connect claim is bound to the player');
    is($C->pluginData('pendingConnect'), 0, 'start: pendingConnect is cleared after the play request');
    is($C->pluginData('eventTrackUri'), 'spotify:track:TRK111', 'start: eventTrackUri carries the announced track');
    is_deeply(\@FETCH, [['TRK111']], 'start: metadata is fetched for the announced track');
    is(prev_power($C), 0, 'start: the pre-Connect power state is saved (GH #151)');
    is($C->pluginData('newTrack'), 1, 'start: newTrack is set (suppresses the transitional stop)');
}

# start with an empty track id: URL choice is independent of the id
{
    fresh();
    ev('start', '');
    my @c = cmds();
    like($c[0], qr/^playlist play spoton:\/\/connect-\d+$/, 'start without a track id still plays spoton://connect-<ts>');
    is_deeply(\@FETCH, [], 'start without a track id fetches no metadata');
}

# start while a Browse song plays: D-08 mutual exclusion stops it first
{
    fresh(playing => 1, song => MockSong->new(url => 'spoton://track:BRW1'));
    ev('start', 'TRK112');
    my @c = cmds();
    is($c[0], 'stop', 'start over Browse playback: a source-marked stop comes first (D-08)');
    like($c[1], qr/^playlist play spoton:\/\/connect-\d+$/, 'start over Browse playback: then the connect-<ts> play');
}

# restart gate (Phase 76): a start right after the daemon's spawn with an idle player is suppressed
{
    fresh(playing => 0);
    $Plugins::SpotOn::Unified::DaemonManager::UPTIME = 4;
    ev('start', 'TRK113');
    is_deeply([ cmds() ], [], 'start 4s after daemon spawn with an idle player: no playlist play (restart gate)');
    is_deeply(\@FETCH, [['TRK113']], 'restart gate: metadata is still fetched');
    is($C->pluginData('pendingConnect'), 0, 'restart gate: pendingConnect is cleared');

    fresh(playing => 0);
    $Plugins::SpotOn::Unified::DaemonManager::UPTIME = 5;
    ev('start', 'TRK114');
    like(join('|', cmds()), qr/^playlist play spoton:\/\/connect-\d+$/, 'start at 5s after daemon spawn: the gate is open (RESTART_START_GRACE = 5)');

    fresh(playing => 1);
    $Plugins::SpotOn::Unified::DaemonManager::UPTIME = 1;
    ev('start', 'TRK115');
    like(join('|', cmds()), qr/^playlist play spoton:\/\/connect-\d+$/, 'start 1s after spawn with a PLAYING player: not suppressed (crash recovery)');
}

# ============================================================
# 2. Verb 'resume'
# ============================================================
{
    # not on a Connect stream -> re-entry via playlist play connect-<ts>
    fresh(playing => 0, power => 1, song => undef);
    ev('resume', 'TRK201', '12.5');
    my @s = sent();
    is(scalar(@s), 1, 'resume off-stream: one request (re-entry)');
    like(join(' ', @{ $s[0]{args} }), qr/^playlist play spoton:\/\/connect-\d+$/, 'resume off-stream: re-enters via playlist play spoton://connect-<ts>');
    is($s[0]{source}, $CONNECT_SRC, 'resume off-stream: the play request is source-marked');
    ok($CONNECT->isSpotifyConnect($C), 'resume off-stream: the Connect claim is re-established');
    is($C->pluginData('eventTrackUri'), 'spotify:track:TRK201', 'resume off-stream: eventTrackUri carries the track');
    is_deeply(\@FETCH, [['TRK201']], 'resume off-stream: metadata is fetched');
}

{
    # on a live Connect stream -> plain unpause + startOffset sync
    my $song = MockSong->new(url => 'spoton://connect-5', info => { live => 1 });
    fresh(playing => 1, elapsed => 2, song => $song);
    ev('resume', 'TRK202', '12.5');
    is_deeply([ cmds() ], ['pause 0'], 'resume on a live Connect stream: only a source-marked [pause, 0], never a play (Pitfall 1)');
    is((sent())[0]{source}, $CONNECT_SRC, 'resume on-stream: the pause request is source-marked');
    is($song->startOffset, 10.5, 'resume on-stream: startOffset = position - elapsed (CON-13)');
    is($C->pluginData('connectSessionPaused'), 0, 'resume on-stream: connectSessionPaused is cleared (GH #158)');
}

{
    # dead history URL -> dropped
    my $url = 'spoton://connect-77';
    my $song = MockSong->new(url => $url, info => undef);
    fresh(playing => 1, song => $song);
    $Slim::Utils::Cache::STORE{ 'spoton_meta_' . md5_hex($url) } = { spotifyUri => 'spotify:track:OLD' };
    ev('resume', 'TRK203', '3.0');
    is_deeply([ cmds() ], [], 'resume with a dead history URL on the player: dropped, nothing sent');
}

# ============================================================
# 3. Verb 'ready'
# ============================================================
{
    fresh(playing => 1);
    ev('start', 'TRK301');          # binds the claim, as in production
    @Slim::Control::Request::SENT = ();
    ev('ready');
    my @s = sent();
    is(scalar(@s), 1, 'ready (claim held, not paused): one request');
    like(join(' ', @{ $s[0]{args} }), qr/^playlist play spoton:\/\/connect-\d+$/, 'ready: re-issues playlist play spoton://connect-<ts>');
    is($s[0]{source}, $CONNECT_SRC, 'ready: the play request is source-marked');
}

{
    fresh(paused => 1);
    $CONNECT->bindConnectClaim($C, 'test');
    ev('ready');
    is_deeply([ cmds() ], [], 'ready with the player paused: playback is not forced (M11)');
}

{
    fresh();
    ev('ready');
    is_deeply([ cmds() ], [], 'ready without a Connect claim: ignored (T-05.3-06)');
}

# ============================================================
# 4. Verb 'change'
# ============================================================
{
    my $song = MockSong->new(url => 'spoton://connect-9', info => { live => 1 });
    fresh(playing => 1, elapsed => 12.5, song => $song);
    $CONNECT->bindConnectClaim($C, 'test');
    ev('change', 'NEWTRK', 'OLDTRK');
    is_deeply([ cmds() ], [], 'change (librespot): no playlist play -- the repeating stream continues');
    is($song->startOffset, -12.5, 'change: startOffset resets the progress bar (0 - elapsed)');
    is($C->pluginData('eventTrackUri'), 'spotify:track:NEWTRK', 'change: eventTrackUri carries the new track');
    is_deeply(\@FETCH, [['NEWTRK']], 'change: metadata is fetched for the new track');
    is_deeply($C->{playPointCalls}, [[undef]], 'change: playPoint is cleared');
}

{
    fresh(playing => 0, paused => 0, song => MockSong->new(url => 'spoton://connect-9', info => 1));
    $CONNECT->bindConnectClaim($C, 'test');
    ev('change', 'NEWTRK', 'OLDTRK');
    is_deeply([ cmds() ], ['pause 0'], 'change on a stopped-looking player: a source-marked [pause, 0] ensures playback');
}

{
    fresh(playing => 0, song => MockSong->new(url => 'spoton://connect-9', info => 1));
    $CONNECT->bindConnectClaim($C, 'test');
    $C->pluginData(connectSessionPaused => 1);
    ev('change', 'NEWTRK', 'OLDTRK');
    is_deeply([ cmds() ], [], 'change while the Spotify session is paused: no force-unpause (GH #158)');
}

{
    fresh(playing => 1, song => MockSong->new(url => 'spoton://track:BRW', info => undef));
    ev('change', 'NEWTRK', 'OLDTRK');
    is_deeply(\@FETCH, [], 'change for a non-Connect player: dropped (connect-guard)');
}

# ============================================================
# 5. Verb 'stop'
# ============================================================
{
    fresh(playing => 1, song => MockSong->new(url => 'spoton://connect-9', info => 1));
    $CONNECT->bindConnectClaim($C, 'test');
    ev('stop');
    is_deeply([ cmds() ], ['pause 1'], 'stop (post-grace, claim held, playing): source-marked [pause, 1]');
    is((sent())[0]{source}, $CONNECT_SRC, 'stop: the pause request is source-marked');
    is($C->pluginData('connectSessionPaused'), 1, 'stop: the Spotify-side pause is remembered (GH #158)');
}

{
    fresh(playing => 1);
    $CONNECT->bindConnectClaim($C, 'test');
    $C->pluginData(connectStartTime => Time::HiRes::time());
    ev('stop');
    is_deeply([ cmds() ], [], 'stop inside the 12s start grace: ignored');
}

{
    fresh(playing => 1);
    $CONNECT->bindConnectClaim($C, 'test');
    $C->pluginData(newTrack => 1);
    ev('stop');
    is_deeply([ cmds() ], [], 'stop while newTrack is set: ignored');
}

{
    fresh(playing => 1, song => MockSong->new(url => 'spoton://connect-9', info => 1));
    $CONNECT->bindConnectClaim($C, 'test');
    $C->pluginData(connectPrevPower => 0);
    $C->pluginData(connectSessionPaused => 1);
    ev('stop', 'inactive');
    # 79-69 (D-36): the power-off is an opt-in with a 30 s wait; the default sends only the pause
    is_deeply([ cmds() ], ['pause 1'], "stop 'inactive' (session end): the default (setting off) only pauses (GH #151, D-36)");
    is($C->pluginData('connectSessionPaused'), 0, "stop 'inactive': the remembered pause state is dropped");
    is(prev_power($C), undef, "stop 'inactive': the saved power state is consumed");
}

# 79-69 T1 i: the setting on - pause now, power 0 from the timer callback after the wait
{
    fresh(playing => 1, song => MockSong->new(url => 'spoton://connect-9', info => 1));
    $Slim::Utils::Prefs::CLIENT{connectPowerOff} = 1;
    $CONNECT->bindConnectClaim($C, 'test');
    $C->pluginData(connectPrevPower => 0);
    ev('stop', 'inactive');
    is_deeply([ cmds() ], ['pause 1'], "79-69 T1 i: stop 'inactive' with the setting on - pause 1 now, no power 0 yet");
    fire_power_off($C, 29);
    is_deeply([ cmds() ], ['pause 1'], '79-69 T1 i: no power 0 at +29 s');
    fire_power_off($C, 31);
    is_deeply([ cmds() ], ['pause 1', 'power 0'], '79-69 T1 i: power 0 from the timer callback after the wait');
    is(prev_power($C), undef, '79-69 T1 i: the saved power state is consumed after the wait');
}

# ============================================================
# 6. Verb 'volume'
# ============================================================
{
    fresh();
    $Plugins::SpotOn::Unified::DaemonManager::UPTIME = 10;
    ev('volume', '33');    # the volume value travels in _p2
    is_deeply([ cmds() ], ['mixer volume 33'], 'volume: a binary-reported change becomes [mixer, volume, N]');
    is((sent())[0]{source}, $CONNECT_SRC, 'volume: the mixer request is source-marked (no echo back, T-05-13)');

    fresh();
    $Plugins::SpotOn::Unified::DaemonManager::UPTIME = 1;
    ev('volume', '33');
    is_deeply([ cmds() ], [], 'volume within VOLUME_GRACE_PERIOD of the daemon start: ignored (CON-11)');

    fresh();
    $Plugins::SpotOn::Unified::DaemonManager::UPTIME = 10;
    ev('volume', '33', undef, undef, source => $CONNECT_SRC);
    is_deeply([ cmds() ], [], 'volume from a source-marked request: ignored');
}

# ============================================================
# 7. Verb 'seek'
# ============================================================
{
    my $song = MockSong->new(url => 'spoton://connect-9', info => 1);
    fresh(playing => 1, elapsed => 3, song => $song);
    $CONNECT->bindConnectClaim($C, 'test');
    ev('seek', '30.5');
    is($song->startOffset, 27.5, 'seek: startOffset = position - elapsed, never a [time, N] (CON-13)');
    is_deeply([ cmds() ], [], 'seek: no LMS request is issued');
    is_deeply($Slim::Control::Request::NOTIFIED[-1][1], ['newmetadata'], 'seek: clients are nudged with newmetadata');
}

{
    my $song = MockSong->new(url => 'spoton://connect-9', info => 1);
    fresh(playing => 1, elapsed => 3, song => $song);
    $C->pluginData(pendingConnect => 1);
    ev('seek', '30.5');
    is($C->pluginData('progress'), '30.5', 'seek before playlist play: stored as progress (CON-17)');
    is($C->pluginData('pendingConnect'), 0, 'seek before playlist play: pendingConnect is cleared');
    is($song->startOffset, undef, 'seek before playlist play: the song is untouched');
}

{
    my $song = MockSong->new(url => 'spoton://track:BRW', info => undef);
    fresh(playing => 1, elapsed => 3, song => $song);
    ev('seek', '30.5');
    is($song->startOffset, undef, 'seek for a non-Connect player: dropped (connect-guard)');
}

# ============================================================
# 8. Unknown verb: ignored, never dies
# ============================================================
{
    fresh(playing => 1);
    $CONNECT->bindConnectClaim($C, 'test');
    my $died = !eval { ev('frobnicate', 'x'); 1 };
    ok(!$died, 'an unknown verb does not die');
    is_deeply([ cmds() ], [], 'an unknown verb issues no LMS request');
    is(scalar(posts()), 0, 'an unknown verb posts no control command');
}

# ============================================================
# 9. The five /control/* endpoints (_sendControlCommand)
# ============================================================
sub connect_player {
    fresh(playing => 1, song => MockSong->new(url => 'spoton://connect-9', info => { live => 1 }));
    $CONNECT->bindConnectClaim($C, 'test');
    $Slim::Utils::Prefs::CLIENT{activeAccount} = 'acct1234';
}

sub pause_req {
    my ($cmd, $newvalue, %extra) = @_;
    return Test::Req->new(client => $C, cmd => ['playlist', $cmd],
                          params => { _newvalue => $newvalue }, %extra);
}

sub jump_req {
    my ($index, %extra) = @_;
    return Test::Req->new(client => $C, cmd => ['playlist', 'jump'], params => { _index => $index }, %extra);
}

sub one_post {
    my ($label, $endpoint, $body) = @_;
    my @p = posts();
    is(scalar(@p), 1, "$label: exactly one control POST");
    return unless @p;
    is($p[0]{url}, "http://127.0.0.1:4242$endpoint", "$label: POST goes to http://127.0.0.1:<port>$endpoint");
    is_deeply($p[0]{rest}, ['Content-Type', 'application/json', $body], "$label: JSON content type and body $body");
    is_deeply($p[0]{opts}, { timeout => 5 }, "$label: 5s timeout");
    return $p[0];
}

{
    connect_player();
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 1));
    my $p = one_post('pause', '/control/pause', '{}');
}

{
    connect_player();
    Plugins::SpotOn::Connect::_onPause(pause_req('stop', undef));
    one_post('stop', '/control/pause', '{}');
}

{
    connect_player();
    $C->pluginData(connectSessionPaused => 1);
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 0));
    one_post('unpause', '/control/play', '{}');
    is($C->pluginData('connectSessionPaused'), 0, 'unpause: connectSessionPaused is cleared before the POST (GH #158)');
}

{
    connect_player();
    Plugins::SpotOn::Connect::_bufferedSetVolume($C, 55.7);
    one_post('volume', '/control/volume', '{"volume":55}');
}

{
    connect_player();
    Plugins::SpotOn::Connect::_onPlaylistJump(jump_req('+1'));
    one_post('jump +1', '/control/next', '{}');
    ok(Time::HiRes::time() - $C->pluginData('connectPauseTs') < 2, 'jump +1: connectPauseTs is stamped (suppresses the echoed stop)');
}

{
    connect_player();
    Plugins::SpotOn::Connect::_onPlaylistJump(jump_req('-1'));
    one_post('jump -1', '/control/prev', '{}');
}

{
    connect_player();
    Plugins::SpotOn::Connect::_onPlaylistJump(jump_req('+0'));
    one_post('jump +0', '/control/prev', '{}');
}


# ------------------------------------------------------------
# GH #219: LMS Next (`playlist jump +1`) while a LIVE Connect session is
# paused. LMS' own Skip leaves PAUSED by itself (StreamingController
# _Skip/_StopGetNext: _Stop, clone of the repeating connect song, new
# stream -> BUFFERING, mode play) and LMS discards every pause while
# BUFFERING (state table row Pause = _NoOp). The Spotify session has to
# follow: after skip_next, resume it (mirror of the GH #158 unpause).
# LmsModel models only the LMS rows these cells need (Pause, Resume,
# Skip); Connect.pm and Backend::Librespot are the REAL modules.
# ------------------------------------------------------------
{
    package LmsModel;
    sub new {
        my ($c, %a) = @_;
        return bless { ps => 'PLAYING', ss => 'STREAMING', notif => [], song => $a{song} }, $c;
    }
    sub isStopped   { $_[0]{ps} eq 'STOPPED' && $_[0]{ss} eq 'IDLE' }
    sub isPaused    { $_[0]{ps} eq 'PAUSED' }
    sub isPlaying   { my ($s, $really) = @_; return $really ? ($s->{ps} eq 'PLAYING' ? 1 : 0) : ((!$s->isStopped && !$s->isPaused) ? 1 : 0); }
    sub buffering   { my $s = shift; return ($s->{ps} eq 'BUFFERING' || $s->{ps} eq 'WAITING_TO_SYNC') ? 1 : 0; }
    sub isStreaming { $_[0]{ss} eq 'STREAMING' }
    sub isStreamout { $_[0]{ss} eq 'STREAMOUT' }
    sub streamingSong { undef }
    sub playingSong   { $_[0]{song} }
    sub jumpToTime    { }
    sub playingSongDuration { undef }
    sub playingSongElapsed  { 0 }
    # row Pause: PLAYING -> _Pause (notifies `playlist pause 1`), BUFFERING -> _NoOp, PAUSED -> _Resume
    sub pause {
        my $s = shift;
        if    ($s->{ps} eq 'PLAYING') { $s->{ps} = 'PAUSED'; push @{ $s->{notif} }, ['playlist', 'pause', 1]; }
        elsif ($s->{ps} eq 'PAUSED')  { $s->{ps} = 'PLAYING'; push @{ $s->{notif} }, ['playlist', 'pause', 0]; }
    }
    sub resume {
        my $s = shift;
        if ($s->{ps} eq 'PAUSED') { $s->{ps} = 'PLAYING'; push @{ $s->{notif} }, ['playlist', 'pause', 0]; }
    }
    # row Skip -> _Skip/_StopGetNext: _Stop (`playlist stop` unless neither playing nor paused),
    # _getNextTrack -> _Stream: BUFFERING/STREAMING with the cloned song
    sub skip {
        my ($s, $newSong) = @_;
        push @{ $s->{notif} }, ['playlist', 'stop'] if $s->isPlaying || $s->isPaused;
        $s->{ps} = 'BUFFERING'; $s->{ss} = 'STREAMING'; $s->{song} = $newSong;
    }
    sub stop { my $s = shift; $s->{ps} = 'STOPPED'; $s->{ss} = 'IDLE'; }

    package ModelClient;
    our @ISA = ('MockClient');
    sub new {
        my ($class, %a) = @_;
        my $self = MockClient::new($class, %a);
        $self->{lms} = $a{lms};
        return $self;
    }
    sub isPlaying   { my $s = shift; return $s->{lms}->isPlaying(@_); }
    sub isPaused    { return $_[0]{lms}->isPaused ? 1 : 0; }
    sub isStopped   { return $_[0]{lms}->isStopped ? 1 : 0; }
    sub playingSong { return $_[0]{lms}{song}; }
    sub controller  { return $_[0]{lms}; }
}

my $LMS;
my $gh219_applied = 0;
sub gh219_setup {
    my $url  = 'spoton://connect-1794684238324';
    $LMS = LmsModel->new(song => MockSong->new(url => $url, info => { live => 1 }));
    fresh();
    $C = ModelClient->new(lms => $LMS);
    $C->{playing} = 1;
    $CONNECT->bindConnectClaim($C, 'test');
    $Slim::Utils::Prefs::CLIENT{activeAccount} = 'acct1234';
    # _fetchTrackMetadata caches spotifyUri for every live Connect track (reads as "dead history")
    $Slim::Utils::Cache::STORE{ 'spoton_meta_' . md5_hex($url) } = { spotifyUri => 'spotify:track:0tk8p69r1Ed2OuqiXxHdAQ', duration => 112 };
    $C->pluginData(connectStartTime => 1);     # session started long ago: grace expired
    $gh219_applied = 0;
    return;
}
# apply the source-marked requests Connect.pm sent to LMS, once each
sub gh219_apply_sent {
    my @s = sent();
    for my $i ($gh219_applied .. $#s) {
        my $line = join(' ', @{ $s[$i]{args} });
        if    ($line eq 'pause 1') { $LMS->pause; }
        elsif ($line eq 'pause 0') { $LMS->resume; }
        elsif ($line eq 'stop')    { $LMS->stop; }
    }
    $gh219_applied = scalar(@s);
}
# deliver the notifications LMS queued, in order
sub gh219_deliver {
    while (my $n = shift @{ $LMS->{notif} }) {
        my (undef, $what, $val) = @$n;
        if    ($what eq 'pause') { Plugins::SpotOn::Connect::_onPause(pause_req('pause', $val)); }
        elsif ($what eq 'stop')  { Plugins::SpotOn::Connect::_onPause(pause_req('stop', undef)); }
    }
}
sub gh219_material_pause { $LMS->pause; gh219_deliver(); }
sub gh219_material_next {
    # clonePlaylistSong shares _pluginData with the old song (Song.pm:50, 172-174)
    $LMS->skip(MockSong->new(url => 'spoton://connect-1794684238324', info => $LMS->{song}{info}));
    Plugins::SpotOn::Connect::_onPlaylistJump(jump_req('+1'));   # the jump notification is queued first
    gh219_deliver();                                              # then `playlist stop` from _Stop
}
sub gh219_reset_wire {
    @Slim::Networking::SimpleAsyncHTTP::POSTS = ();
    @Slim::Control::Request::SENT = ();
    $gh219_applied = 0;
}
sub gh219_post_urls { return map { $_->{url} =~ s{^http://127\.0\.0\.1:4242}{}r } posts(); }

# GH219-C1: LMS paused (daemon echo seen), then Next in LMS
gh219_setup();
gh219_material_pause();
ev('stop');
gh219_apply_sent();
gh219_reset_wire();
gh219_material_next();
gh219_apply_sent();
is_deeply([ gh219_post_urls() ], ['/control/next', '/control/play'],
    'GH219-C1: Next in LMS while the session is paused: /control/next then /control/play');
is($C->pluginData('connectSessionPaused'), 0, 'GH219-C1: the remembered pause state is cleared (GH #158 mirror)');
is($CONNECT->isSpotifyConnect($C), 1, 'GH219-C1: the claim is still held');

# GH219-C2: the daemon change that follows sends nothing
gh219_reset_wire();
ev('change', 'NEWTRK', 'OLDTRK');
gh219_apply_sent();
is_deeply([ cmds() ], [], 'GH219-C2: the change after the resumed skip issues no LMS request');
is(scalar(gh219_post_urls()), 0, 'GH219-C2: ... and no POST');

# GH219-C3: Next in the Spotify app while paused (GH #158/#201 B): unchanged
gh219_setup();
gh219_material_pause();
ev('stop');
gh219_apply_sent();
gh219_reset_wire();
ev('change', 'NEWTRK', 'OLDTRK');
gh219_apply_sent();
is_deeply([ cmds() ], [], 'GH219-C3: app Next while paused: no LMS request');
is(scalar(gh219_post_urls()), 0, 'GH219-C3: ... no POST');
is($LMS->{ps}, 'PAUSED', 'GH219-C3: LMS stays PAUSED with the new title');
is($C->pluginData('connectSessionPaused'), 1, 'GH219-C3: the pause state is kept');

# GH219-C4: Next while playing: /control/next only
gh219_setup();
gh219_reset_wire();
gh219_material_next();
gh219_apply_sent();
is_deeply([ gh219_post_urls() ], ['/control/next'], 'GH219-C4: Next while playing: /control/next only, no /control/play');

# GH219-C5: Previous while paused stays paused (decision for #219: no change). LMS `jump -1` / `jump +0`
# on the one-entry connect playlist is jumpToTime(0) -> _JumpPaused, and ProtocolHandler::canDoAction('rew')
# vetoes the restart while the claim is held, so LMS does not leave PAUSED and the session must not resume.
gh219_setup();
gh219_material_pause();
ev('stop');
gh219_apply_sent();
gh219_reset_wire();
Plugins::SpotOn::Connect::_onPlaylistJump(jump_req('-1'));
is_deeply([ gh219_post_urls() ], ['/control/prev'], 'GH219-C5: Previous (jump -1) while paused: /control/prev only, no /control/play');
is($C->pluginData('connectSessionPaused'), 1, 'GH219-C5: jump -1 keeps the pause state');
gh219_reset_wire();
Plugins::SpotOn::Connect::_onPlaylistJump(jump_req('+0'));
is_deeply([ gh219_post_urls() ], ['/control/prev'], 'GH219-C5: Previous (jump +0) while paused: /control/prev only, no /control/play');
is($C->pluginData('connectSessionPaused'), 1, 'GH219-C5: jump +0 keeps the pause state');

# GH219-C6: GH #159 pass-through (claim gone, live connect stream): Next never sends /control/play
gh219_setup();
gh219_material_pause();
ev('stop');
gh219_apply_sent();
$C->pluginData(connectSessionPaused => 1);
$CONNECT->releaseConnectClaim($C, 'inactive');
gh219_reset_wire();
Plugins::SpotOn::Connect::_onPlaylistJump(jump_req('+1'));
is_deeply([ gh219_post_urls() ], ['/control/next'], 'GH219-C6: GH #159 pass-through (no claim): /control/next only, no /control/play');

# GH219-C7: Next before the daemon's stop echo reached Perl
gh219_setup();
gh219_material_pause();
is($C->pluginData('connectSessionPaused'), 1, 'GH219-C7: an LMS pause marks the session paused at once');
gh219_apply_sent();
gh219_reset_wire();
gh219_material_next();
gh219_apply_sent();
is_deeply([ gh219_post_urls() ], ['/control/next', '/control/play'],
    'GH219-C7: Next inside the echo window (pause forwarded, daemon stop not yet seen) resumes too');

# GH219-C8: Play in LMS after Pause (GH #158): unchanged
gh219_setup();
gh219_material_pause();
ev('stop');
gh219_apply_sent();
gh219_reset_wire();
$LMS->resume;
gh219_deliver();
is_deeply([ gh219_post_urls() ], ['/control/play'], 'GH219-C8: Play in LMS after Pause: /control/play only');
is($C->pluginData('connectSessionPaused'), 0, 'GH219-C8: the pause state is cleared by the unpause');

# GH219-C9: an LMS `playlist stop` (not a pause) on a claim-held live session must NOT mark
# the session paused (pins the `!$isStop` guard of the early pause marking in _onPause)
gh219_setup();
gh219_reset_wire();
Plugins::SpotOn::Connect::_onPause(pause_req('stop', undef));
is_deeply([ gh219_post_urls() ], ['/control/pause'], 'GH219-C9: LMS stop on a live claim-held session is forwarded as /control/pause (the path under test was reached)');
ok(!$C->pluginData('connectSessionPaused'), 'GH219-C9: LMS stop does NOT mark the session paused (!$isStop guard)');

# 79-28 D-23: LMS seek -> debounced POST /control/seek (GH #129 behaviour behind the capability)
sub seek_req {
    my ($newvalue, %extra) = @_;
    return Test::Req->new(client => $C, cmd => ['time'], params => { _newvalue => $newvalue }, %extra);
}
{
    connect_player();
    my $t0 = Time::HiRes::time();
    Plugins::SpotOn::Connect::_onSeek(seek_req(42));
    is(scalar(@Slim::Utils::Timers::SET), 1, '79-28 D-23 seek: time 42 arms exactly one debounce timer');
    my $tm = $Slim::Utils::Timers::SET[0];
    is($tm && $tm->[2], \&Plugins::SpotOn::Connect::_forwardLibrespotSeek, '79-28 D-23 seek: the timer calls _forwardLibrespotSeek');
    is($tm && $tm->[3], 42000, '79-28 D-23 seek: the timer carries 42000 ms');
    ok($tm && $tm->[1] - $t0 > 0.2 && $tm->[1] - $t0 < 0.5, '79-28 D-23 seek: debounce is 0.3 s (SEEK_DEBOUNCE)');
    is(scalar(posts()), 0, '79-28 D-23 seek: nothing is posted before the timer fires');
    $tm->[2]->($tm->[0], $tm->[3]) if $tm;
    my @p = posts();
    is(scalar(@p), 1, '79-28 D-23 seek: firing the timer posts exactly one control command');
    is($p[0] && $p[0]{url}, 'http://127.0.0.1:4242/control/seek', '79-28 D-23 seek: POST goes to /control/seek');
    is_deeply($p[0] && $p[0]{rest}, ['Content-Type', 'application/json', '{"position_ms":42000}'], '79-28 D-23 seek: body {"position_ms":42000}');
}
{
    connect_player();
    local $Slim::Player::Source::SONGTIME = 30;
    Plugins::SpotOn::Connect::_onSeek(seek_req('+10'));
    my $tm = $Slim::Utils::Timers::SET[0];
    is($tm && $tm->[3], 40000, '79-28 D-23 seek: time +10 at songTime 30 resolves to 40000 ms (no LMS restart, songTime is the old position)');
}
{
    connect_player();
    Plugins::SpotOn::Connect::_onSeek(seek_req(10));
    Plugins::SpotOn::Connect::_onSeek(seek_req(20));
    is(scalar(@Slim::Utils::Timers::KILL), 2, '79-28 D-23 seek: every seek kills the pending debounce timer first');
    is($Slim::Utils::Timers::KILL[-1][1], \&Plugins::SpotOn::Connect::_forwardLibrespotSeek, '79-28 D-23 seek: the killed timer is _forwardLibrespotSeek');
    is($Slim::Utils::Timers::SET[-1][3], 20000, '79-28 D-23 seek: the surviving timer carries the last position');
    my $tm = $Slim::Utils::Timers::SET[-1];
    $tm->[2]->($tm->[0], $tm->[3]);
    is(scalar(posts()), 1, '79-28 D-23 seek: two seeks inside the window produce one POST');
}
{
    fresh(playing => 1, song => MockSong->new(url => 'spoton://connect-9', info => 1));
    Plugins::SpotOn::Connect::_onSeek(seek_req(42));
    is(scalar(@Slim::Utils::Timers::SET), 0, '79-28 D-23 seek: a player without the Connect claim arms no timer');
    connect_player();
    Plugins::SpotOn::Connect::_onSeek(seek_req(42, source => $CONNECT_SRC));
    is(scalar(@Slim::Utils::Timers::SET), 0, '79-28 D-23 seek: a source-marked request arms no timer (T-79-92)');
}

# _onVolume: debounced into _bufferedSetVolume with the player's current volume
{
    connect_player();
    my $t0 = Time::HiRes::time();
    Plugins::SpotOn::Connect::_onVolume(Test::Req->new(client => $C, cmd => ['mixer', 'volume']));
    is(scalar(@Slim::Utils::Timers::SET), 1, '_onVolume: one debounce timer is armed');
    my $tm = $Slim::Utils::Timers::SET[0];
    is($tm->[2], \&Plugins::SpotOn::Connect::_bufferedSetVolume, '_onVolume: the timer calls _bufferedSetVolume');
    is($tm->[3], 55, '_onVolume: the timer carries the player volume');
    ok($tm->[1] - $t0 > 0.4 && $tm->[1] - $t0 < 0.7, '_onVolume: debounce is 0.5s (VOLUME_DEBOUNCE)');
    is(scalar(posts()), 0, '_onVolume: nothing is posted before the timer fires');
}

# Gates in front of the POST
{
    fresh(playing => 1, song => MockSong->new(url => 'spoton://connect-9', info => 1));
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 1));
    is(scalar(posts()), 0, 'pause without a Connect claim: nothing is posted (isSpotifyConnect gate)');
}

{
    connect_player();
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 1, source => $CONNECT_SRC));
    Plugins::SpotOn::Connect::_onPlaylistJump(jump_req('+1', source => $CONNECT_SRC));
    is(scalar(posts()), 0, 'source-marked pause / jump requests are skipped (T-05-13)');
}

{
    connect_player();
    $Plugins::SpotOn::Unified::DaemonManager::PORT = undef;
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 1));
    is(scalar(posts()), 0, 'no stream port: no POST is sent');
    is(scalar(@Plugins::SpotOn::API::Client::CALLS), 0, 'no stream port: no Web API fallback either (the call is skipped)');
}

# Failure paths: 85-07 D-10 -- a dead control endpoint is reported on the
# status page ("Daemon nicht erreichbar"), never replayed against the Web API.
# The 409 rule (GH #159) is unchanged.
sub unreachable_entries { return grep { $_->[1] eq 'Connect' && ($_->[3] // '') =~ /^daemon_unreachable:/ } @Plugins::SpotOn::Status::RECORDED; }

{
    connect_player();
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 1));
    (posts())[0]->fire_ok;
    pass('control POST ok callback runs without dying');
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 0, 'pause POST ok: nothing is recorded');
    (posts())[0]->fire_error('500 Internal Server Error', undef);
    is(scalar(@Plugins::SpotOn::API::Client::CALLS), 0,
        'pause POST failed: no Web API call (D-10, the remote-control fallback is gone)');
    my @e = unreachable_entries();
    is(scalar(@e), 1, 'pause POST failed: exactly one "Daemon nicht erreichbar" status entry');
    is($e[0][0], 'warn', 'pause POST failed: the entry is a warn');
    is($e[0][2], $C->id . ': Daemon nicht erreichbar (/control/pause)', 'pause POST failed: message names the player and the endpoint');
    is($e[0][3], 'daemon_unreachable:' . $C->id, 'pause POST failed: dedupe key daemon_unreachable:<mac>');
}

{
    connect_player();
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 0));
    (posts())[0]->fire_error('503 Service Unavailable', undef);
    is(scalar(@Plugins::SpotOn::API::Client::CALLS), 0, 'play POST failed: no Web API call');
    my @e = unreachable_entries();
    is(scalar(@e), 1, 'play POST failed: one status entry');
    like($e[0][2], qr{Daemon nicht erreichbar \(/control/play\)}, 'play POST failed: message names /control/play');
}

{
    connect_player();
    Plugins::SpotOn::Connect::_bufferedSetVolume($C, 55);
    (posts())[0]->fire_error('500 Internal Server Error', undef);
    is(scalar(@Plugins::SpotOn::API::Client::CALLS), 0, 'volume POST failed: no Web API call');
    my @e = unreachable_entries();
    is(scalar(@e), 1, 'volume POST failed: one status entry');
    like($e[0][2], qr{Daemon nicht erreichbar \(/control/volume\)}, 'volume POST failed: message names /control/volume');
}

{
    # a transport error without a status code (connection refused) is the typical dead endpoint
    connect_player();
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 1));
    (posts())[0]->fire_error('Connection refused', undef);
    is(scalar(@Plugins::SpotOn::API::Client::CALLS), 0, 'connection refused: no Web API call');
    is(scalar(unreachable_entries()), 1, 'connection refused: one status entry');
}

{
    connect_player();
    Plugins::SpotOn::Connect::_onPlaylistJump(jump_req('+1'));
    (posts())[0]->fire_error('500 Internal Server Error', undef);
    is(scalar(@Plugins::SpotOn::API::Client::CALLS), 0, 'next POST failed: no Web API call');
    my @e = unreachable_entries();
    is(scalar(@e), 1, 'next POST failed: the dead endpoint is reported as well');
    like($e[0][2], qr{Daemon nicht erreichbar \(/control/next\)}, 'next POST failed: message names /control/next');
}

{
    # dedupe (T-85-26): repeated failures keep ONE entry; the next success clears it
    connect_player();
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 1));
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 0));
    my @p = posts();
    $p[0]->fire_error('500 Internal Server Error', undef);
    $p[1]->fire_error('500 Internal Server Error', undef);
    is(scalar(unreachable_entries()), 1, 'two failures in a row: still exactly one status entry (dedupe key)');
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 1));
    my @p2 = posts();
    $p2[-1]->fire_ok;
    is_deeply(\@Plugins::SpotOn::Status::CLEARED, [ [ 'Connect', 'daemon_unreachable:' . $C->id ] ],
        'a following successful control POST clears the entry (Status->clearError Connect daemon_unreachable:<mac>)');
}

{
    connect_player();
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 1));
    (posts())[0]->fire_error('409 Conflict', undef);
    is(scalar(@Plugins::SpotOn::API::Client::CALLS), 0, '409 Conflict: no Web API fallback (it would act on the wrong device, GH #159)');
    is(scalar(unreachable_entries()), 0, '409 Conflict: no status entry (the device was deselected, the daemon is fine)');
    is_deeply([ cmds() ], ['stop'], '409 Conflict: the stale stream is ejected with a source-marked [stop]');
    is((sent())[-1]{source}, $CONNECT_SRC, '409 Conflict: the stop request is source-marked');
}

{
    connect_player();
    $Plugins::SpotOn::Unified::DaemonManager::PORT = undef;
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 1));
    is(scalar(posts()), 0, 'no stream port: no POST');
    is(scalar(unreachable_entries()), 0, 'no stream port: no status entry either (unchanged)');
}

# ============================================================
# 261114-p4u (GH #216): the Connect claim ends with the session
# (this file runs with INFOLOG off: no log assertions here)
# ============================================================
{
    # P4U-4: the real Backend::Librespot role - stop 'inactive' releases the claim
    fresh(playing => 1, song => MockSong->new(url => 'spoton://connect-9', info => { live => 1 }));
    $CONNECT->bindConnectClaim($C, 'test');
    ev('stop', 'inactive');
    ok(!$CONNECT->isSpotifyConnect($C), "P4U-4: stop 'inactive' releases the claim (librespot role)");
    @Slim::Control::Request::SENT = ();
    $C->{playing} = 0;
    $C->{power}   = 0;
    ev('ready');
    # IN-07: this runs AFTER the release, so it reaches the "ignored, no claim" branch and not the
    # power-off guard (it would pass with power => 1 as well). The power guard is P4U-13 below.
    is_deeply([ cmds() ], [], 'P4U-4: ready after the session end (no claim): nothing sent');
}

{
    # P4U-5: GH #159 stays intact - an LMS unpause of the paused stale connect
    # stream after the session end still reaches the daemon, its 409 ejects it
    fresh(playing => 0, paused => 1, song => MockSong->new(url => 'spoton://connect-9', info => { live => 1 }));
    $CONNECT->bindConnectClaim($C, 'test');
    ev('stop', 'inactive');
    is_deeply([ cmds() ], [], 'P4U-5: deselect while paused sends nothing');
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 0));
    my @p = posts();
    is(scalar(@p), 1, 'P4U-5: LMS unpause after the session end: one control POST');
    ok(@p && $p[0]{url} eq 'http://127.0.0.1:4242/control/play', 'P4U-5: the POST is /control/play');
    $p[0]->fire_error('409 Conflict', undef) if @p;
    is_deeply([ cmds() ], ['stop'], 'P4U-5: the 409 ejects the stale stream with one stop');
    my @sent = sent();
    ok(@sent && $sent[-1]{source} eq $CONNECT_SRC, 'P4U-5: the stop is source-marked');
}

{
    # P4U-6: no claim, live connect stream, LMS pause: nothing goes to the daemon
    fresh(playing => 1, song => MockSong->new(url => 'spoton://connect-9', info => { live => 1 }));
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 1));
    is(scalar(posts()), 0, 'P4U-6: no claim, LMS pause on a connect stream: no control POST');
}

# ============================================================
# 261114-p4u-r2 (GH #216 review, WR-05 + IN-07): the ready power-off guard releases the claim
# ============================================================
{
    # P4U-13: the real power-off guard on the real librespot role. The claim outlived its session (the
    # session ended WITHOUT a `stop inactive`), the player is off: ready sends nothing and drops the
    # claim, so the next ready - player switched on again and idle - cannot replace its playlist either.
    fresh(playing => 0, power => 0, song => MockSong->new(url => 'spoton://connect-9', info => { live => 1 }));
    $CONNECT->bindConnectClaim($C, 'test');
    ok($CONNECT->isSpotifyConnect($C), 'P4U-13: precondition, the claim is bound');
    ev('ready');
    is_deeply([ cmds() ], [], 'P4U-13: claim bound, player off, ready without a preceding stop inactive: nothing sent');
    ok(!$CONNECT->isSpotifyConnect($C), 'P4U-13: the power-off guard released the claim');
    $C->{power}   = 1;
    $C->{playing} = 0;
    @Slim::Control::Request::SENT = ();
    ev('ready');
    is_deeply([ cmds() ], [], 'P4U-13: player switched on again and idle, second ready: still nothing sent');
}

{
    # P4U-14: positive control - same claim, player on: ready re-issues playlist play
    fresh(playing => 0, power => 1, song => MockSong->new(url => 'spoton://connect-9', info => { live => 1 }));
    $CONNECT->bindConnectClaim($C, 'test');
    ev('ready');
    my @c = cmds();
    is(scalar(@c), 1, 'P4U-14: claim bound, player on, ready: one request');
    like($c[0] // '', qr/^playlist play spoton:\/\/connect-\d+$/, 'P4U-14: ready re-issues playlist play spoton://connect-<ts>');
    ok($CONNECT->isSpotifyConnect($C), 'P4U-14: the claim stays bound');
}

# ============================================================
# 261114-p4u-r2 (GH #216 review, IN-06 (1)): Next/Previous on the stale connect stream eject like Play
# ============================================================
sub stale_connect_stream {
    fresh(playing => 0, paused => 1, song => MockSong->new(url => 'spoton://connect-9', info => { live => 1 }));
    $CONNECT->bindConnectClaim($C, 'test');
    ev('stop', 'inactive');                 # the session ends: the claim is released
    @Slim::Control::Request::SENT = ();
    @Slim::Networking::SimpleAsyncHTTP::POSTS = ();
}

for my $case ([ 'next', '+1', '/control/next' ], [ 'prev', '-1', '/control/prev' ], [ 'jump +0', '+0', '/control/prev' ]) {
    my ($label, $index, $endpoint) = @$case;
    stale_connect_stream();
    ok(!$CONNECT->isSpotifyConnect($C), "P4U-15 $label: precondition, no claim after the session end");
    Plugins::SpotOn::Connect::_onPlaylistJump(jump_req($index));
    my @p = posts();
    is(scalar(@p), 1, "P4U-15 $label: LMS jump on the stale stream: one control POST to the player's own daemon");
    is($p[0] && $p[0]{url}, "http://127.0.0.1:4242$endpoint", "P4U-15 $label: the POST is $endpoint");
    $p[0]->fire_error('409 Conflict', undef) if @p;
    is_deeply([ cmds() ], ['stop'], "P4U-15 $label: the daemon's 409 ejects the stale stream with one stop");
    my @sent = sent();
    ok(@sent && $sent[-1]{source} eq $CONNECT_SRC, "P4U-15 $label: the stop is source-marked");
}

{
    # P4U-16: negatives - the pass-through stays as narrow as the unpause one
    fresh(playing => 1, song => MockSong->new(url => 'spoton://track:BRW1', info => undef));
    Plugins::SpotOn::Connect::_onPlaylistJump(jump_req('+1'));
    is(scalar(posts()), 0, 'P4U-16: Browse stream, no claim, LMS next: nothing forwarded');

    fresh(playing => 0, paused => 1, song => MockSong->new(url => 'spoton://connect-9', info => undef));
    $Slim::Utils::Cache::STORE{ 'spoton_meta_' . md5_hex('spoton://connect-9') } = { spotifyUri => 'spotify:track:OLD' };
    Plugins::SpotOn::Connect::_onPlaylistJump(jump_req('+1'));
    is(scalar(posts()), 0, 'P4U-16: dead history URL, no claim, LMS next: nothing forwarded');

    # another player holds the claim: this player's jump is not forwarded either
    my $owner = MockClient->new(playing => 1);
    fresh(playing => 0, paused => 1, song => MockSong->new(url => 'spoton://connect-9', info => { live => 1 }));
    $CONNECT->bindConnectClaim($owner, 'test');
    Plugins::SpotOn::Connect::_onPlaylistJump(jump_req('+1'));
    is(scalar(posts()), 0, 'P4U-16: the claim sits on another player, LMS next: nothing forwarded');
    $CONNECT->releaseConnectClaim($owner, 'test');
}

done_testing();

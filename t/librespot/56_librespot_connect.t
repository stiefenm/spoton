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

# 88-10 (D-19, #219 residual IN-03): an app pause INSIDE the start grace is still a pause of the
# Spotify session. Only the echo forwarding to LMS stays suppressed (the daemon's Stopped between
# TrackChanged and Playing is spurious at that moment); the session is remembered as paused so that
# a later Next in LMS follows it (/control/next, then /control/play).
# GH219-C10: the app stop arrives 3 s after the start
gh219_setup();
$C->pluginData(connectStartTime => Time::HiRes::time() - 3);   # inside CONNECT_START_GRACE (12 s)
gh219_reset_wire();
ev('stop');
gh219_apply_sent();
is($C->pluginData('connectSessionPaused'), 1, 'GH219-C10: an app stop inside the start grace marks the session paused');
is_deeply([ cmds() ], [], 'GH219-C10: ... and forwards no pause to LMS (the echo suppression stays)');
is(scalar(gh219_post_urls()), 0, 'GH219-C10: ... and posts nothing to the daemon');

# GH219-C11: Next in LMS after that remembered pause
gh219_reset_wire();
gh219_material_next();
gh219_apply_sent();
is_deeply([ gh219_post_urls() ], ['/control/next', '/control/play'],
    'GH219-C11: Next in LMS after an app pause inside the start grace: /control/next then /control/play');

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
    is_deeply([ cmds() ], ['stop', 'play'], 'P4U-5: the 409 on play ejects and reopens the entry (stop, play; 88-06 D-03)');
    # 88-06: the 409 on /control/play also reopens the entry (GH223-C1); its source mark is checked below
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

# ============================================================
# 88-06 Task 1 (D-03, GH #223): every Play on a moved Connect session tries the
# pull-back first, else plays the last track through Browse. The open path
# (ProtocolHandler::getNextTrack) is the ONLY transfer site; the 409 on
# /control/play ejects the stale stream and reopens the entry (stop + play).
# ProtocolHandler and the REAL Connect.pm / Backend::Librespot run against the
# stubs above; the stubs below are the LMS classes ProtocolHandler loads.
# Every stub exists here (CI has no LMS tree).
# ============================================================
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
write_stub($stub_dir, 'Slim::Utils::Versions', <<'END');
package Slim::Utils::Versions;
sub compareVersions { return 1 }
1;
END
write_stub($stub_dir, 'Slim::Utils::Network', <<'END');
package Slim::Utils::Network;
sub serverAddr { return '192.0.2.7' }
1;
END
write_stub($stub_dir, 'Slim::Music::Info', <<'END');
package Slim::Music::Info;
sub setCurrentTitle { }
1;
END
write_stub($stub_dir, 'Slim::Formats::RemoteStream', <<'END');
package Slim::Formats::RemoteStream;
sub new      { return bless {}, shift }
sub AUTOLOAD { }
sub can      { 1 }
1;
END
write_stub($stub_dir, 'Slim::Player::Protocols::HTTP', <<'END');
package Slim::Player::Protocols::HTTP;
sub new { my ($class, $args) = @_; return bless { %$args }, $class; }
sub requestString { return ''; }
sub canEnhanceHTTP { return 1; }
1;
END
{
    # ProtocolHandler asks the DaemonManager for the role class (the stub above has no backendClass)
    no warnings 'once';
    *Plugins::SpotOn::Unified::DaemonManager::backendClass = sub {
        require Plugins::SpotOn::Backend::Librespot;
        return 'Plugins::SpotOn::Backend::Librespot';
    };
}
require_ok('Plugins::SpotOn::ProtocolHandler')
    or BAIL_OUT("Failed to load Plugins::SpotOn::ProtocolHandler");
# the stream class new() returns inherits from it (GH219-W1/W2 call new())
require_ok('Slim::Player::Protocols::HTTP')
    or BAIL_OUT("Failed to load the Slim::Player::Protocols::HTTP stub");

{
    # a song as LMS hands it to getNextTrack: master, track->url, a settable streamUrl, duration
    package GNSong;
    sub new {
        my ($class, %a) = @_;
        return bless { client => $a{client}, url => $a{url}, streamUrl => undef, duration => undef,
                       samplesize => undef, samplerate => undef, channels => undef }, $class;
    }
    sub master      { return $_[0]{client}; }
    sub track       { return $_[0]; }
    sub url         { return $_[0]{url}; }
    sub streamUrl   { my $s = shift; $s->{streamUrl} = shift if @_; return $s->{streamUrl} // $s->{url}; }
    sub rawStreamUrl { return $_[0]{streamUrl}; }
    sub duration    { my $s = shift; $s->{duration} = shift if @_; return $s->{duration}; }
    sub samplesize  { my $s = shift; $s->{samplesize} = shift if @_; return $s->{samplesize}; }
    sub samplerate  { my $s = shift; $s->{samplerate} = shift if @_; return $s->{samplerate}; }
    sub channels    { my $s = shift; $s->{channels} = shift if @_; return $s->{channels}; }
    sub pluginData  { return undef; }

    # a 503 response as LMS passes it to the error callback (SimpleAsyncHTTP.pm:96)
    package Resp503;
    sub new { my ($class, %h) = @_; return bless { h => { map { lc($_) => $h{$_} } keys %h } }, $class; }
    sub code   { return 503; }
    sub header { my ($s, $n) = @_; return $s->{h}{ lc $n }; }

    # a backend role without transferBack (Soloist)
    package NoTransferRole;
    sub new { return bless {}, shift; }
    sub capabilities { return { connectClaimGate => 0 }; }
    sub capabilitiesDefault { return { samplesize => 32 }; }
    sub state { return { mode => undef }; }
}

my $PH = 'Plugins::SpotOn::ProtocolHandler';
my $LB = 'Plugins::SpotOn::Backend::Librespot';

sub transfer_posts { return grep { $_->{url} =~ m{/control/transfer$} } posts(); }
sub meta_for {
    my ($url, $id) = @_;
    $Slim::Utils::Cache::STORE{ 'spoton_meta_' . md5_hex($url) } = { spotifyUri => "spotify:track:$id" };
    $Slim::Utils::Cache::STORE{ 'spoton_meta_' . md5_hex("spoton://track:$id") } = { duration => 120 };
}
# run (and remove) every pending timer that calls $cb
sub run_timers {
    my ($cb) = @_;
    my @due = grep { $_->[2] == $cb } @Slim::Utils::Timers::TIMERS;
    @Slim::Utils::Timers::TIMERS = grep { $_->[2] != $cb } @Slim::Utils::Timers::TIMERS;
    for my $t (@due) { my ($obj, undef, $f, @extra) = @$t; $f->($obj, @extra); }
    return scalar(@due);
}
sub tick    { return run_timers(\&Plugins::SpotOn::Backend::Librespot::_deliverConfirmed); }
sub timeout { return run_timers(\&Plugins::SpotOn::Backend::Librespot::_transferTimeout); }
sub wire_reset {
    @Slim::Control::Request::SENT = ();
    @Slim::Networking::SimpleAsyncHTTP::POSTS = ();
    @Slim::Utils::Timers::TIMERS = ();
}
# LMS opens a song: the result of one getNextTrack
sub gnt {
    my ($song) = @_;
    my $r = { ok => 0, err => 0, song => $song, eargs => undef };
    $PH->getNextTrack($song, sub { $r->{ok}++ }, sub { $r->{err}++; $r->{eargs} = [@_]; });
    return $r;
}
sub play_urls { return grep { /^playlist play / } cmds(); }

# P1 had a Connect session (its own `start` issued `playlist play connect-<ts>`), the session then moved away
sub moved_session {
    fresh(playing => 0, paused => 0);
    ev('start', 'TRK1');
    my ($url) = map { $_->{args}[2] } grep { ($_->{args}[0] // '') eq 'playlist' && ($_->{args}[1] // '') eq 'play' } sent();
    $CONNECT->releaseConnectClaim($C, 'inactive');
    $C->pluginData(connectStartTime => 1);
    wire_reset();
    return $url;
}
# ... and P1 sits PAUSED on the stale entry (Play there is an unpause)
sub stale_paused {
    my $url = moved_session();
    $C->{song}   = MockSong->new(url => $url, info => { live => 1 });
    $C->{paused} = 1;
    return $url;
}
sub paused_play_409 {
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 0));
    my @p = posts();
    $p[0]->fire_error('409 Conflict', undef) if @p;
    # whatever the 409 branch started would be answered by the helper before the reopen
    # (the helper refuses a second transfer inside 3 s: 503 + Retry-After); a transfer sent
    # here therefore cannot hide as "the same transfer" when the reopen asks again
    $_->fire_error('503 Service Unavailable', Resp503->new('Retry-After' => 2)) for transfer_posts();
    return @p;
}

# --- GH223-C1: the 409 on /control/play ejects and reopens; the control path never transfers
{
    my $url = stale_paused();
    my @p = paused_play_409();
    is(scalar(@p), 1, 'GH223-C1: the unpause reaches the daemon (one POST)');
    is_deeply([ cmds() ], ['stop', 'play'], 'GH223-C1: the 409 on /control/play ejects (stop) and reopens (play) the entry');
    ok((grep { ($_->{source} // '') eq $CONNECT_SRC } sent()) == scalar(sent()), 'GH223-C1: both requests are source-marked (no echo to the daemon)');
    is(scalar(transfer_posts()), 0, 'GH223-C1: the 409 branch itself sends no /control/transfer (single transfer site)');
}

# --- GH223-C2: the whole gesture through the reopen: exactly one transfer, then Browse
{
    my $url = stale_paused();
    paused_play_409();
    meta_for($url, 'DEADTRK');
    my $song = GNSong->new(client => $C, url => $url);
    $C->{song} = $song;                                  # the reopen is the explicit Play: playingSong
    my $r = gnt($song);
    my @t = transfer_posts();
    is(scalar(@t), 1, 'GH223-C2: the reopen of the entry sends the one transfer');
    $t[0]->fire_ok if @t;
    is("$r->{ok}/$r->{err}", '0/0', 'GH223-C2: the open waits for the outcome');
    timeout();
    is("$r->{ok}/$r->{err}", '1/0', 'GH223-C2: no start/change within TRANSFER_WAIT_S -> Browse result, successCb once');
    is($song->rawStreamUrl, 'spoton://track:DEADTRK', 'GH223-C2: the Browse URL is the translation of the cached spotifyUri');
    is(scalar(transfer_posts()), 1, 'GH223-C2: POST /control/transfer over the WHOLE gesture is exactly 1');
    is_deeply([ cmds() ], ['stop', 'play'], 'GH223-C2: no second stop, no second play');
}

# --- GH223-C3: the transfer is refused -> Browse at once, still exactly one transfer
for my $case (['404 old helper', '404 Not Found', undef],
              ['503 with Retry-After', '503 Service Unavailable', Resp503->new('Retry-After' => 2)],
              ['503 without a response object', '503 Service Unavailable', undef]) {
    my ($label, $err, $resp) = @$case;
    my $url = stale_paused();
    paused_play_409();
    meta_for($url, 'DEADTRK');
    my $song = GNSong->new(client => $C, url => $url);
    $C->{song} = $song;
    my $r = gnt($song);
    my @t = transfer_posts();
    $t[0]->fire_error($err, $resp) if @t;
    is("$r->{ok}/$r->{err}", '1/0', "GH223-C3 ($label): Browse result at once, successCb once");
    is($song->rawStreamUrl, 'spoton://track:DEADTRK', "GH223-C3 ($label): the Browse URL is set");
    is(scalar(transfer_posts()), 1, "GH223-C3 ($label): exactly one /control/transfer over the gesture");
    is_deeply([ cmds() ], ['stop', 'play'], "GH223-C3 ($label): no further stop/play");
    is(scalar(unreachable_entries()), 0, "GH223-C3 ($label): a refused transfer raises no daemon-unreachable entry");
}

# --- GH223-C4: a recovering helper (503 + Retry-After) neither ejects nor reports nor transfers
{
    connect_player();
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 0));
    my @p = posts();
    $p[0]->fire_error('503 Service Unavailable', Resp503->new('Retry-After' => 2)) if @p;
    is(scalar(@p), 1, 'GH223-C4: the unpause POST went out');
    is_deeply([ cmds() ], [], 'GH223-C4: 503 + Retry-After: no eject, no reopen');
    is(scalar(unreachable_entries()), 0, 'GH223-C4: no daemon-unreachable entry');
    is(scalar(transfer_posts()), 0, 'GH223-C4: no transfer');
    is(scalar(@Plugins::SpotOn::API::Client::CALLS), 0, 'GH223-C4: no Web API call');
}

# --- WR01 (88 review WR-01): LMS has already applied the user's Play / Pause when the recovering
# helper refuses the command (503 + Retry-After). Dropped, LMS and Spotify diverge (LMS paused while
# the recovery plays on, or LMS streaming a paused session). The transport pair play/pause is retried
# through an LMS timer after the Retry-After: bounded, the newest intent wins, never for a player
# that moved on to other content.
sub retry_cb     { return \&Plugins::SpotOn::Backend::Librespot::_controlRetryDue; }
sub retry_timers { my $cb = retry_cb(); return grep { $_->[2] == $cb } @Slim::Utils::Timers::TIMERS; }
sub retry_run    { return run_timers(retry_cb()); }
sub control_urls { return map { $_->{url} =~ s{^http://127\.0\.0\.1:4242}{}r } posts(); }
sub r503         { return ('503 Service Unavailable', Resp503->new('Retry-After' => $_[0])); }
# the wire (SENT, POSTS) is emptied, the timers stay: what the later timer does is the question
sub wire_reset_keep_retry {
    @Slim::Control::Request::SENT = ();
    @Slim::Networking::SimpleAsyncHTTP::POSTS = ();
    return;
}

{
    # WR01-1: a pause during the recovery reaches the daemon after the Retry-After
    connect_player();
    my $t0 = Time::HiRes::time();
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 1));
    (posts())[0]->fire_error(r503(2));
    my $t1 = Time::HiRes::time();
    my @t = retry_timers();
    is(scalar(@t), 1, 'WR01-1: 503 + Retry-After on /control/pause arms exactly one retry timer');
    ok(@t && $t[0][0] == $C, 'WR01-1: ... on the player (an LMS timer, nothing blocks)');
    ok(@t && $t[0][1] >= $t0 + 2 && $t[0][1] <= $t1 + 2, 'WR01-1: ... due after the Retry-After (2 s)');
    is(scalar(posts()), 1, 'WR01-1: nothing is resent before the timer');
    retry_run();
    is_deeply([ control_urls() ], ['/control/pause', '/control/pause'], 'WR01-1: the timer resends the pause');
    is_deeply((posts())[-1]{rest}, (posts())[0]{rest}, 'WR01-1: ... with the same content type and body');
    (posts())[-1]->fire_ok;
    is(scalar(retry_timers()), 0, 'WR01-1: delivered - no further retry');
    is_deeply([ cmds() ], [], 'WR01-1: no eject, no reopen');
    is(scalar(unreachable_entries()), 0, 'WR01-1: no daemon-unreachable entry');
}

{
    # WR01-2: the newest intent wins - pause (503), then play: only the play is retried
    connect_player();
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 1));
    (posts())[0]->fire_error(r503(2));
    is(scalar(retry_timers()), 1, 'WR01-2: precondition, the pause retry is armed');
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 0));
    is(scalar(retry_timers()), 0, 'WR01-2: a newer transport command voids the pending retry');
    (posts())[-1]->fire_error(r503(2));
    is(scalar(retry_timers()), 1, 'WR01-2: the play is retried in its place');
    retry_run();
    is_deeply([ control_urls() ], ['/control/pause', '/control/play', '/control/play'],
        'WR01-2: the pause is never resent, the play is (last intent wins)');
}

{
    # WR01-3: the 503 of an OLDER command that arrives after a newer one was accepted arms nothing
    connect_player();
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 1));
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 0));
    my @p = posts();
    $p[1]->fire_ok;
    $p[0]->fire_error(r503(2));
    is(scalar(retry_timers()), 0, 'WR01-3: a superseded pause is not retried over the accepted play');
    is(scalar(posts()), 2, 'WR01-3: no further POST');
}

{
    # WR01-4: bounded - a helper that keeps answering 503 is not asked forever
    connect_player();
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 1));
    my $max = $LB->can('CONTROL_RETRY_MAX') ? $LB->CONTROL_RETRY_MAX : -1;
    my $n = 0;
    while ($n < 100) {
        (posts())[-1]->fire_error(r503(2));
        last unless retry_run();
        $n++;
    }
    is($n, $max, 'WR01-4: exactly CONTROL_RETRY_MAX retries, then the command is given up');
    cmp_ok($max, '<=', 20, 'WR01-4: the bound is small');
    is(scalar(retry_timers()), 0, 'WR01-4: no timer left');
    is_deeply([ cmds() ], [], 'WR01-4: giving up ejects nothing');
    is(scalar(unreachable_entries()), 0, 'WR01-4: ... and raises no daemon-unreachable entry (the helper answers)');
}

{
    # WR01-5: the player moved on to other content - a late retry must not touch it
    connect_player();
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 0));
    (posts())[0]->fire_error(r503(2));
    is(scalar(retry_timers()), 1, 'WR01-5: precondition, the play retry is armed');
    $C->{song} = MockSong->new(url => 'spoton://track:OTHER');
    retry_run();
    is(scalar(posts()), 1, 'WR01-5: another song plays at retry time: nothing is resent');
    is(scalar(retry_timers()), 0, 'WR01-5: ... and nothing is re-armed');
}

{
    # WR01-6: only play/pause are retried; volume keeps today's drop (no timer, no status entry)
    connect_player();
    Plugins::SpotOn::Connect::_bufferedSetVolume($C, 55);
    (posts())[0]->fire_error(r503(2));
    is(scalar(retry_timers()), 0, 'WR01-6: a refused /control/volume arms no retry');
    is(scalar(unreachable_entries()), 0, 'WR01-6: ... and no daemon-unreachable entry');
}

for my $case ([4, 4], ['abc', 2], [0, 2], [600, 2]) {
    # WR01-7: the delay is the Retry-After when it is 1..5 s, else 2 s
    my ($ra, $want) = @$case;
    connect_player();
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 1));
    my $t0 = Time::HiRes::time();
    (posts())[0]->fire_error(r503($ra));
    my $t1 = Time::HiRes::time();
    my @t = retry_timers();
    ok(@t == 1 && $t[0][1] >= $t0 + $want && $t[0][1] <= $t1 + $want, "WR01-7: Retry-After '$ra' -> retry after $want s");
}

{
    # WR01-8: the retried play of a CLAIMED player that meets a 409 (the recovery failed, the device is
    # inactive, helper replaced) ejects and does NOT reopen. RE-PINNED on purpose in 88 review round 3
    # (R3-WR-01, user decision 2026-11-18 "Lueckenlos fixen"): it used to pin eject + reopen
    # (['stop', 'play']), which is the late pull-back the user decided against. The stale pass-through
    # (no claim) keeps eject + reopen: R3-D2.
    connect_player();
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 0));
    (posts())[0]->fire_error(r503(2));
    retry_run();
    is_deeply([ control_urls() ], ['/control/play', '/control/play'], 'WR01-8: precondition, the play was resent');
    (posts())[-1]->fire_error('409 Conflict', undef) if posts() == 2;
    is_deeply([ cmds() ], ['stop'], 'WR01-8: a 409 on the retried play (armed under a claim) ejects and does not reopen');
    is(scalar(retry_timers()), 0, 'WR01-8: no retry after a 409');
}

{
    # WR01-9 (88 review round 2 R2-WR-01, user decision 2026-11-18 option (a) "Verwerfen"): the retry
    # belongs to the Connect session it was issued in. The session ended meanwhile (`stop inactive`:
    # pause + claim release, the Song object stays) - the late retried Play must be dropped, never
    # reach the helper (a 409 there would reopen the entry = /control/transfer = pull the session back
    # from the device the user moved to). IN-02 (round 3): a real `start` session, and a `play` the
    # eject issued is honoured by LMS as a reopen, so the transfer cell can fail on the defective code
    my $url = r3_live_session();
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 0));
    (posts())[0]->fire_error(r503(2));
    is(scalar(retry_timers()), 1, 'WR01-9: precondition, the play retry is armed while the claim is held');
    ev('stop', 'inactive');
    ok(!$CONNECT->isSpotifyConnect($C), 'WR01-9: precondition, the session end released the claim');
    wire_reset_keep_retry();
    retry_run();
    # the recovery is over and the device deselected: whatever the helper is asked now answers 409
    (posts())[-1]->fire_error('409 Conflict', undef) if posts();
    is_deeply([ control_urls() ], [], 'WR01-9: the timer is due after the session end: nothing is resent');
    is_deeply([ cmds() ], [], 'WR01-9: ... and no eject, no reopen');
    is(r3_reopen_transfers($url), 0, 'WR01-9: ... and no /control/transfer (the session is not pulled back)');
    is(scalar(retry_timers()), 0, 'WR01-9: ... and nothing is re-armed');
}

{
    # WR01-10: the stale pass-through keeps its retry - no claim at either time (the unpause of a
    # stale stream while the helper recovers)
    my $url = stale_paused();
    ok(!$CONNECT->isSpotifyConnect($C), 'WR01-10: precondition, the player holds no claim');
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 0));
    (posts())[0]->fire_error(r503(2));
    is(scalar(retry_timers()), 1, 'WR01-10: the play retry is armed without a claim');
    retry_run();
    is_deeply([ control_urls() ], ['/control/play', '/control/play'], 'WR01-10: ... and resent (no claim at either time)');
}

# --- R3-WR-01 (88 review round 3, user decision 2026-11-18 "Lueckenlos fixen"): the retry must not
# cross the end of its Connect session through the 409 branch either. A 409 that answers a retried Play
# armed under a claim is the helper's own statement that the session ended meanwhile (recovery over,
# device deselected, helper replaced): eject and release, NEVER reopen (the reopen is the
# /control/transfer that pulls the session back from the device the user moved to). The claim state is
# taken when the command is ISSUED, not when its 503 arrives. Accepted cost: a player whose claim was
# already dormant before the press needs a second Play (the stale pass-through below keeps its reopen).
sub r3_live_session {
    fresh(playing => 0, paused => 0);
    ev('start', 'TRK1');
    my ($url) = map { $_->{args}[2] } grep { ($_->{args}[0] // '') eq 'playlist' && ($_->{args}[1] // '') eq 'play' } sent();
    $C->pluginData(connectStartTime => 1);
    $C->pluginData(newTrack => 0);
    $C->{song}    = MockSong->new(url => $url, info => { live => 1 });
    $C->{playing} = 1;
    wire_reset();
    return $url;
}
# LMS honours a `play` the 409 branch issued: it reopens the entry (the one place that transfers)
sub r3_reopen_transfers {
    my ($url) = @_;
    if (grep { $_ eq 'play' } cmds()) {
        meta_for($url, 'DEADTRK');
        my $song = GNSong->new(client => $C, url => $url);
        $C->{song} = $song;
        gnt($song);
    }
    return scalar(transfer_posts());
}
# a Play pressed while the helper recovers (503), the retry due and sent while LMS still holds the claim
sub r3_play_retried {
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 0));
    (posts())[0]->fire_error(r503(2));
    wire_reset_keep_retry();
    retry_run();
    return;
}

{
    # R3-A: the helper left `recovering` but LMS has not yet seen `stop inactive`: the retry is sent
    # while the claim is held; `stop inactive` is processed first, then the 409 answers the retry
    my $url = r3_live_session();
    r3_play_retried();
    is_deeply([ control_urls() ], ['/control/play'], 'R3-A: precondition, the retry is sent while the claim is held');
    ev('stop', 'inactive');
    ok(!$CONNECT->isSpotifyConnect($C), 'R3-A: precondition, the session end released the claim');
    (posts())[-1]->fire_error('409 Conflict', undef);
    is_deeply([ cmds() ], ['pause 1', 'stop'], 'R3-A: the 409 on the retried play ejects and does NOT reopen');
    is(r3_reopen_transfers($url), 0, 'R3-A: no /control/transfer (the session is not pulled back)');
    is(scalar(retry_timers()), 0, 'R3-A: no retry after the 409');
}

{
    # R3-A2: the 409 is processed BEFORE `stop inactive` reaches LMS
    my $url = r3_live_session();
    r3_play_retried();
    (posts())[-1]->fire_error('409 Conflict', undef);
    is_deeply([ cmds() ], ['stop'], 'R3-A2: the 409 on the retried play (claim still held) ejects and does NOT reopen');
    ok(!$CONNECT->isSpotifyConnect($C), 'R3-A2: ... and the stale claim is released (CR-01)');
    is(r3_reopen_transfers($url), 0, 'R3-A2: no /control/transfer');
    ev('stop', 'inactive');
    is(scalar(transfer_posts()), 0, 'R3-A2: the `stop inactive` afterwards causes none either');
}

{
    # R3-B: the helper process was replaced while the chain ran: nothing releases the claim, the new
    # helper answers 409 to the retried play
    my $url = r3_live_session();
    r3_play_retried();
    ok($CONNECT->isSpotifyConnect($C), 'R3-B: precondition, the claim is still held (no `stop inactive` came)');
    (posts())[-1]->fire_error('409 Conflict', undef);
    is_deeply([ cmds() ], ['stop'], 'R3-B: a 409 on the retried play ejects only');
    ok(!$CONNECT->isSpotifyConnect($C), 'R3-B: ... and releases the claim');
    is(r3_reopen_transfers($url), 0, 'R3-B: no /control/transfer');
}

{
    # R3-E: the session ended between the command and its 503 (the claim must be sampled when the
    # command is issued, not when the 503 arrives)
    my $url = r3_live_session();
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 0));
    ev('stop', 'inactive');
    ok(!$CONNECT->isSpotifyConnect($C), 'R3-E: precondition, the session ended after the command was issued');
    my ($first) = grep { $_->{url} =~ m{/control/play$} } posts();
    $first->fire_error(r503(2)) if $first;
    my $rec = $C->pluginData('connectControlRetry');
    is(ref $rec eq 'HASH' ? $rec->{claimed} : 'none', 1, 'R3-E: the record carries the claim state of the ISSUE time');
    wire_reset_keep_retry();
    retry_run();
    # answer a resent play with 409, so defective code (a resend) shows as an eject/reopen too
    $_->fire_error('409 Conflict') for grep { $_->{url} =~ m{/control/play$} } posts();
    is_deeply([ control_urls() ], [], 'R3-E: the timer is due: nothing is resent (the session ended)');
    is_deeply([ cmds() ], [], 'R3-E: ... no eject, no reopen');
    is(r3_reopen_transfers($url), 0, 'R3-E: ... no /control/transfer');
}

{
    # R3-G1 (IN-02): the claim state of the FIRST attempt travels through a chain: 503, retry, 503
    # again, `stop inactive`, the timer is due - nothing is resent and nothing is re-armed
    my $url = r3_live_session();
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 0));
    (posts())[0]->fire_error(r503(2));
    retry_run();
    (posts())[-1]->fire_error(r503(2));
    my $rec = $C->pluginData('connectControlRetry');
    is(ref $rec eq 'HASH' ? "$rec->{retries}/$rec->{claimed}" : 'none', '2/1', 'R3-G1: precondition, the second arm keeps the claim of the first attempt');
    ev('stop', 'inactive');
    wire_reset_keep_retry();
    retry_run();
    is_deeply([ control_urls() ], [], 'R3-G1: the chain\'s timer is due after the session end: nothing is resent');
    is(scalar(retry_timers()), 0, 'R3-G1: ... and nothing is re-armed');
}

{
    # R3-G2 (IN-02): the 409 on the SECOND retry of a chain armed under a claim is also eject-only
    my $url = r3_live_session();
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 0));
    (posts())[0]->fire_error(r503(2));
    retry_run();
    (posts())[-1]->fire_error(r503(2));
    wire_reset_keep_retry();
    retry_run();
    is_deeply([ control_urls() ], ['/control/play'], 'R3-G2: precondition, the second retry is sent');
    (posts())[-1]->fire_error('409 Conflict', undef);
    is_deeply([ cmds() ], ['stop'], 'R3-G2: the 409 on the second retry ejects only (the claim state travels the chain)');
    is(r3_reopen_transfers($url), 0, 'R3-G2: no /control/transfer');
}

{
    # R3-G3 (IN-02): the session ends between a retry being SENT and its own 503: the record keeps
    # the claim of the first attempt (it is neither re-sampled nor lost), the next due timer drops
    my $url = r3_live_session();
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 0));
    (posts())[0]->fire_error(r503(2));
    retry_run();
    ev('stop', 'inactive');
    (grep { $_->{url} =~ m{/control/play$} } posts())[-1]->fire_error(r503(2));
    my $rec = $C->pluginData('connectControlRetry');
    is(ref $rec eq 'HASH' ? $rec->{claimed} : 'none', 1, 'R3-G3: the re-armed record keeps the claim state of the first attempt');
    wire_reset_keep_retry();
    retry_run();
    is_deeply([ control_urls() ], [], 'R3-G3: the timer is due after the session end: nothing is resent');
}

{
    # R3-D2: the stale pass-through (no claim when the Play was pressed) keeps the designed GH #223
    # gesture, late by the recovery: its 409 ejects, reopens and transfers once
    my $url = stale_paused();
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 0));
    (posts())[0]->fire_error(r503(2));
    wire_reset_keep_retry();
    retry_run();
    (posts())[-1]->fire_error('409 Conflict', undef) if posts();
    is_deeply([ cmds() ], ['stop', 'play'], 'R3-D2: the 409 on a retried stale pass-through ejects and reopens');
    is(r3_reopen_transfers($url), 1, 'R3-D2: ... and the reopen sends the one /control/transfer');
}

# --- GH223-C5: the 409 on pause/next/prev stays eject-only
{
    connect_player();
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 1));
    (posts())[0]->fire_error('409 Conflict', undef);
    is_deeply([ cmds() ], ['stop'], 'GH223-C5 pause: the 409 ejects only (no reopen play)');
    is(scalar(transfer_posts()), 0, 'GH223-C5 pause: no transfer');
    for my $case (['next', '+1'], ['prev', '-1']) {
        connect_player();
        Plugins::SpotOn::Connect::_onPlaylistJump(jump_req($case->[1]));
        (posts())[0]->fire_error('409 Conflict', undef);
        is_deeply([ cmds() ], ['stop'], "GH223-C5 $case->[0]: the 409 ejects only (no reopen play)");
        is(scalar(transfer_posts()), 0, "GH223-C5 $case->[0]: no transfer");
    }
}

# --- GH223-C6: one transfer in flight per player; a second request shares the outcome
{
    my $url = moved_session();
    meta_for($url, 'DEADTRK');
    my $s1 = GNSong->new(client => $C, url => $url);
    $C->{song} = $s1;
    my $r1 = gnt($s1);
    my $s2 = GNSong->new(client => $C, url => $url);
    $C->{song} = $s2;
    my $r2 = gnt($s2);
    my @t = transfer_posts();
    is(scalar(@t), 1, 'GH223-C6: a second open while a transfer is pending sends no second POST');
    $t[0]->fire_ok if @t;
    timeout();
    is("$r1->{ok}/$r1->{err} $r2->{ok}/$r2->{err}", '1/0 1/0', 'GH223-C6: both waiters receive the one outcome');
}

# --- GH223-C7 (88 review CR-01): the claim is STILL HELD when the daemon answers 409 on /control/play
# (the helper process was replaced - health restart, crash backoff - and nothing released the claim).
# The 409 is the daemon's statement that the session is not on this device: the claim goes before the
# reopen, so the reopen takes the pull-back path and never the dead /stream relay of the claim holder.
{
    fresh(playing => 0, paused => 0);
    ev('start', 'TRK1');
    my ($url) = map { $_->{args}[2] } grep { ($_->{args}[0] // '') eq 'playlist' && ($_->{args}[1] // '') eq 'play' } sent();
    ok($CONNECT->isSpotifyConnect($C), 'GH223-C7: precondition, the start bound the claim and nothing released it');
    $C->pluginData(connectStartTime => 1);
    wire_reset();
    $C->{song}   = MockSong->new(url => $url, info => { live => 1 });
    $C->{paused} = 1;
    my @p = paused_play_409();
    is(scalar(@p), 1, 'GH223-C7: the unpause reaches the daemon (one POST)');
    is_deeply([ cmds() ], ['stop', 'play'], 'GH223-C7: the 409 on /control/play ejects and reopens the entry');
    ok(!$CONNECT->isSpotifyConnect($C), 'GH223-C7: the 409 releases the stale claim before the reopen');
    is(scalar(transfer_posts()), 0, 'GH223-C7: the 409 branch itself sends no /control/transfer');
    meta_for($url, 'DEADTRK');
    my $song = GNSong->new(client => $C, url => $url);
    $C->{song} = $song;                                  # the reopen is the explicit Play: playingSong
    my $r = gnt($song);
    my @t = transfer_posts();
    is(scalar(@t), 1, 'GH223-C7: the reopen sends exactly one /control/transfer (pull-back first)');
    is("$r->{ok}/$r->{err}", '0/0', 'GH223-C7: the open waits for the outcome, it does not answer on the dead /stream relay');
    $t[0]->fire_ok if @t;
    timeout();
    is("$r->{ok}/$r->{err}", '1/0', 'GH223-C7: no start/change -> Browse result, successCb once');
    is($song->rawStreamUrl, 'spoton://track:DEADTRK', 'GH223-C7: the Browse URL is the translation of the cached spotifyUri');
    my $stream = $PH->new({ url => $url, client => $C, song => $song });
    is($stream && $stream->{url}, 'http://127.0.0.1:4242/track/DEADTRK', 'GH223-C7: new() opens the Browse /track/<id>, never the dead /stream relay');
}

# --- GH223-C8 (88 review CR-01): the 409 on pause releases a held claim as well (eject only, no reopen).
# Another player's claim is never touched by this player's 409: GH159-C2.
{
    connect_player();
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 1));
    (posts())[0]->fire_error('409 Conflict', undef);
    is_deeply([ cmds() ], ['stop'], 'GH223-C8: the 409 on pause ejects only');
    ok(!$CONNECT->isSpotifyConnect($C), 'GH223-C8: ... and releases the stale claim');
}

# --- GH223-O1: the open of P1's own last Connect entry transfers first and waits
{
    my $url = moved_session();
    meta_for($url, 'DEADTRK');
    my $song = GNSong->new(client => $C, url => $url);
    $C->{song} = $song;
    my $r = gnt($song);
    my @t = transfer_posts();
    is(scalar(@t), 1, 'GH223-O1: exactly one POST /control/transfer');
    is($t[0] && $t[0]{url}, 'http://127.0.0.1:4242/control/transfer', 'GH223-O1: it goes to the player\'s own helper port');
    is("$r->{ok}/$r->{err}", '0/0', 'GH223-O1: neither callback has run before the outcome');
    is($song->rawStreamUrl, undef, 'GH223-O1: the song is not translated while waiting');
}

# --- GH223-O2: refused / unconfirmed -> today's dead-URL result
for my $case (['404', sub { $_[0]->fire_error('404 Not Found', undef) }],
              ['503', sub { $_[0]->fire_error('503 Service Unavailable', Resp503->new('Retry-After' => 2)) }],
              ['timeout', sub { $_[0]->fire_ok; timeout(); }]) {
    my ($label, $outcome) = @$case;
    my $url = moved_session();
    meta_for($url, 'DEADTRK');
    my $song = GNSong->new(client => $C, url => $url);
    $C->{song} = $song;
    my $r = gnt($song);
    my ($t) = transfer_posts();
    $outcome->($t) if $t;
    is("$r->{ok}/$r->{err}", '1/0', "GH223-O2 ($label): today's dead-URL result, successCb once");
    is($song->rawStreamUrl, 'spoton://track:DEADTRK', "GH223-O2 ($label): streamUrl is the Browse URL");
    is($song->duration, 120, "GH223-O2 ($label): the cached duration is set");
}
{
    my $url = moved_session();
    my $song = GNSong->new(client => $C, url => $url);      # no cached spotifyUri
    $C->{song} = $song;
    my $r = gnt($song);
    my ($t) = transfer_posts();
    $t->fire_error('404 Not Found', undef) if $t;
    is("$r->{ok}/$r->{err}", '0/1', 'GH223-O2 (no cached spotifyUri): errorCb once, as today');
    is($r->{eargs} && $r->{eargs}[0], 'PROBLEM_OPENING', 'GH223-O2 (no cached spotifyUri): PROBLEM_OPENING');
}

# --- GH223-O3: the session arrives with a start that issues its own playlist play -> the open is superseded
{
    my $url = moved_session();
    meta_for($url, 'DEADTRK');
    my $song = GNSong->new(client => $C, url => $url);
    $C->{song} = $song;
    my $r = gnt($song);
    my ($t) = transfer_posts();
    $t->fire_ok if $t;
    ev('start', 'TRK1');
    tick();
    is("$r->{ok}/$r->{err}", '0/0', 'GH223-O3: neither callback of the pending open runs (superseded)');
    my @pl = play_urls();
    is(scalar(@pl), 1, 'GH223-O3: exactly one playlist play (the start handler\'s)');
    like($pl[0] // '', qr{^playlist play spoton://connect-\d+$}, 'GH223-O3: ... and it is the live connect entry, no Browse play');
    is(scalar(transfer_posts()), 1, 'GH223-O3: still one transfer');
}

# --- GH223-O4: a change, or a start that issued no play -> the open continues on the live stream
{
    my $url = moved_session();
    meta_for($url, 'DEADTRK');
    my $song = GNSong->new(client => $C, url => $url);
    $C->{song} = $song;
    my $r = gnt($song);
    my ($t) = transfer_posts();
    $t->fire_ok if $t;
    ev('change', 'NEWTRK', 'OLDTRK');
    is("$r->{ok}/$r->{err}", '0/0', 'GH223-O4 (change): the confirmation is delivered on the next main-loop tick, not inside the handler');
    tick();
    is("$r->{ok}/$r->{err}", '1/0', 'GH223-O4 (change): successCb once');
    is($song->rawStreamUrl, undef, 'GH223-O4 (change): streamUrl NOT set, new() serves the live /stream');
    # 88 review WR-05: the player now plays the live session - it must hold the claim, or later
    # change events are dropped, an app pause is not applied and LMS pause/stop are not forwarded
    ok($CONNECT->isSpotifyConnect($C), 'GH223-O4 (change): the change that confirms the pull-back binds the Connect claim');
    is(scalar(play_urls()), 0, 'GH223-O4 (change): ... and still issues no playlist play (the pending open continues)');
    # LMS turns `pause 0` on a stopped player into a second `playlist jump` (Commands::playcontrolCommand)
    is_deeply([ cmds() ], [], 'GH223-O4 (change): ... and no forced unpause of the player that waits in TRACKWAIT');
    is($FETCH[-1] && $FETCH[-1][0], 'NEWTRK', 'GH223-O4 (change): the metadata of the new title is fetched (the handler goes on)');
    wire_reset();
    # the stream runs; the real _fetchTrackMetadata (stubbed here) tags the playing song as live ('info')
    $C->{playing} = 1;
    $C->{song}    = MockSong->new(url => $url, info => { live => 1 });
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 1));
    is_deeply([ map { $_->{url} =~ s{^http://127\.0\.0\.1:4242}{}r } posts() ], ['/control/pause'],
        'GH223-O4 (change): an LMS pause of the pulled-back session reaches the daemon');

    # ... and ONLY then: a change with no pull-back pending and no claim is still dropped (connect-guard)
    $url = moved_session();
    ev('change', 'NEWTRK', 'OLDTRK');
    ok(!$CONNECT->isSpotifyConnect($C), 'GH223-O4 (change, nothing pending): no claim is bound');
    is_deeply([ cmds() ], [], 'GH223-O4 (change, nothing pending): the event is dropped as before');

    $url = moved_session();
    meta_for($url, 'DEADTRK');
    $song = GNSong->new(client => $C, url => $url);
    $C->{song} = $song;
    $r = gnt($song);
    ($t) = transfer_posts();
    $t->fire_ok if $t;
    $Plugins::SpotOn::Unified::DaemonManager::UPTIME = 3;       # RESTART_START_GRACE: the start handler issues no play
    ev('start', 'TRK1');
    tick();
    is("$r->{ok}/$r->{err}", '1/0', 'GH223-O4 (start without play): successCb once');
    is($song->rawStreamUrl, undef, 'GH223-O4 (start without play): streamUrl NOT set');
    is(scalar(play_urls()), 0, 'GH223-O4 (start without play): the handler issued no playlist play');
}

# --- GH223-O4 (superseded): the pull-back's open was superseded by other content (88 review round 2 R2-WR-02)
# The connectTransferPending record outlives the open that asked for it (until the session arrives or
# TRANSFER_WAIT_S). A radio station started inside that window, then the session arrives as `change`:
# the claim must NOT be bound (the player does not play the session), and the Spotify title must not
# be fetched against the foreign song (connect-metadata-bleed)
{
    my $url = moved_session();
    meta_for($url, 'DEADTRK');
    my $song = GNSong->new(client => $C, url => $url);
    $C->{song} = $song;
    my $r = gnt($song);
    my ($t) = transfer_posts();
    $t->fire_ok if $t;
    # the user starts a radio station inside the wait window: the player plays something else now
    $C->{playing} = 1;
    $C->{song}    = MockSong->new(url => 'http://radio.example.test/stream.mp3');
    @FETCH = ();
    wire_reset();
    ev('change', 'NEWTRK', 'OLDTRK');
    tick();
    ok(!$CONNECT->isSpotifyConnect($C), 'GH223-O4 (superseded): no claim is bound for a player that plays other content');
    is(scalar(@FETCH), 0, 'GH223-O4 (superseded): no Spotify metadata fetch against the foreign song');
    is_deeply([ cmds() ], [], 'GH223-O4 (superseded): the change is dropped (connect-guard), nothing sent');
}

# --- GH223-O5: P1 IS the active Connect player -> no transfer, and its OWN live entry is not translated
# GH #219 WR-01 (88-08 rig, debug gh219-wr01-next-after-pause): this cell used to pin the translation of
# the claim holder's own last Connect entry as "today's order". That translation was only harmless while
# new() ignored it; with 88-06's streamUrl adoption it made an LMS jump (Next) on a live session open the
# helper's /track/<id> Browse endpoint, which shuts the player's own Spirc down (D-10), so the following
# /control/next + /control/play answered 409 (rig run 0031: V2 FAIL, 21 of 21 rows). A live title's record
# carries a spotifyUri too (Connect.pm _isDeadHistoryUrl note), so the cached record cannot tell live from history.
{
    my $url = moved_session();
    meta_for($url, 'LIVETRK');
    $CONNECT->bindConnectClaim($C, 'test');
    my $song = GNSong->new(client => $C, url => $url);
    $C->{song} = $song;
    my $r = gnt($song);
    is(scalar(posts()), 0, 'GH223-O5: the active Connect player sends no transfer');
    is("$r->{ok}/$r->{err}", '1/0', 'GH223-O5: the open of the live entry answers at once, successCb once');
    is($song->rawStreamUrl, undef, 'GH223-O5 / GH219-W1: the live entry is NOT translated to Browse');
    is($song->duration, undef, 'GH219-W1: no Browse duration is written onto the live entry');
    my $stream = $PH->new({ url => $url, client => $C, song => $song });
    is($stream && $stream->{url}, 'http://127.0.0.1:4242/stream',
        'GH219-W1: new() serves the live /stream relay, never a /track/<id> Browse URL that would preempt Spirc');
}

# --- GH219-W2: the claim holder opening a HISTORY entry (not its own last URL) still translates to Browse
{
    moved_session();
    $CONNECT->bindConnectClaim($C, 'test');
    my $hist = 'spoton://connect-777';
    meta_for($hist, 'HISTTRK');
    my $song = GNSong->new(client => $C, url => $hist);
    $C->{song} = $song;
    my $r = gnt($song);
    is(scalar(posts()), 0, 'GH219-W2: a history entry under a claim sends no POST');
    is("$r->{ok}/$r->{err}", '1/0', 'GH219-W2: the cached translation answers at once');
    is($song->rawStreamUrl, 'spoton://track:HISTTRK', 'GH219-W2: a history entry keeps the Browse translation (today\'s order)');
    my $stream = $PH->new({ url => $hist, client => $C, song => $song });
    is($stream && $stream->{url}, 'http://127.0.0.1:4242/track/HISTTRK', 'GH219-W2: new() builds the /track/<id> Browse URL for it (88-06 repair kept)');
}

# --- GH219-W3: a role without transferBack (Soloist) keeps today's translation under a claim (D-06)
{
    my $url = moved_session();
    meta_for($url, 'LIVETRK');
    $CONNECT->bindConnectClaim($C, 'test');
    my $song = GNSong->new(client => $C, url => $url);
    $C->{song} = $song;
    my $r;
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Unified::DaemonManager::backendFor = sub { NoTransferRole->new };
        local *Plugins::SpotOn::Unified::DaemonManager::backendClass = sub { 'NoTransferRole' };
        $r = gnt($song);
    }
    is("$r->{ok}/$r->{err}", '1/0', 'GH219-W3: a role without transferBack answers at once');
    is($song->rawStreamUrl, 'spoton://track:LIVETRK', 'GH219-W3: Soloist behaviour unchanged (D-06): translation as before');
}

# --- GH219-W4: the claim is gone (session moved away): the own last entry is still the dead-URL path (88-06 unchanged)
{
    my $url = moved_session();
    meta_for($url, 'DEADTRK');
    my $song = GNSong->new(client => $C, url => $url);
    $C->{song} = $song;
    my $r = gnt($song);
    is(scalar(transfer_posts()), 1, 'GH219-W4: without the claim the own last entry still pulls back first (one transfer)');
    is("$r->{ok}/$r->{err}", '0/0', 'GH219-W4: and waits for the outcome');
}

# --- GH223-O6: a role without transferBack (Soloist) keeps today's path
{
    my $url = moved_session();
    meta_for($url, 'DEADTRK');
    my $song = GNSong->new(client => $C, url => $url);
    $C->{song} = $song;
    my $r;
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Unified::DaemonManager::backendFor = sub { NoTransferRole->new };
        local *Plugins::SpotOn::Unified::DaemonManager::backendClass = sub { 'NoTransferRole' };
        $r = gnt($song);
    }
    is(scalar(posts()), 0, 'GH223-O6: a role without transferBack sends no transfer');
    is("$r->{ok}/$r->{err}", '1/0', 'GH223-O6: today\'s path answers at once');
}

# --- GH223-O7: another dead connect-* URL (a history entry) translates at once
{
    moved_session();
    my $hist = 'spoton://connect-777';
    meta_for($hist, 'HISTTRK');
    my $song = GNSong->new(client => $C, url => $hist);
    $C->{song} = $song;
    my $r = gnt($song);
    is(scalar(posts()), 0, 'GH223-O7: a history entry that is not the last Connect URL sends no POST');
    is("$r->{ok}/$r->{err}", '1/0', 'GH223-O7: the cached translation answers at once');
    is($song->rawStreamUrl, 'spoton://track:HISTTRK', 'GH223-O7: ... with the Browse translation');
}

# --- GH223-O8: a look-ahead open (another song is playing) translates at once
{
    my $url = moved_session();
    meta_for($url, 'DEADTRK');
    $C->{song} = MockSong->new(url => 'spoton://track:PLAYING');
    my $song = GNSong->new(client => $C, url => $url);
    my $r = gnt($song);
    is(scalar(posts()), 0, 'GH223-O8: a look-ahead open sends no POST');
    is("$r->{ok}/$r->{err}", '1/0', 'GH223-O8: today\'s immediate translation');
    is($song->rawStreamUrl, 'spoton://track:DEADTRK', 'GH223-O8: ... with the Browse translation');
}

# --- GH223-O9 (88 review WR-04): the Browse fallback is terminal for LMS's own failure retry.
# When the fallback stream fails to start (404 from /track/<id>, PROBLEM_OPENING), LMS retries by
# itself (StreamingController::_StopNextIfMore: _Stop, then _getNextTrack) with a FRESH Song for the
# same entry as the only queued song - the same shape as an explicit Play, with no user gesture.
# That retry must not send a second /control/transfer (T-88-12).
{
    my $url = moved_session();
    meta_for($url, 'DEADTRK');
    my $song = GNSong->new(client => $C, url => $url);
    $C->{song} = $song;
    my $r = gnt($song);
    my ($t) = transfer_posts();
    $t->fire_ok if $t;
    timeout();
    is("$r->{ok}/$r->{err}", '1/0', 'GH223-O9: precondition, the first open fell back to Browse');
    is(scalar(transfer_posts()), 1, 'GH223-O9: precondition, one transfer for the gesture');

    my $retry = GNSong->new(client => $C, url => $url);      # LMS's retry: a fresh Song, playingSong
    $C->{song} = $retry;
    my $r2 = gnt($retry);
    is(scalar(transfer_posts()), 1, 'GH223-O9: the retry open of the fallen-back entry sends NO second /control/transfer');
    is("$r2->{ok}/$r2->{err}", '1/0', 'GH223-O9: ... it answers at once');
    is($retry->rawStreamUrl, 'spoton://track:DEADTRK', 'GH223-O9: ... with the Browse translation');

    # the mark is bounded in time: a Play after the hold is a new gesture and pulls again (D-03)
    my $hold = $PH->can('PULLBACK_FALLBACK_HOLD_S') ? $PH->PULLBACK_FALLBACK_HOLD_S : undef;
    ok(defined $hold && $hold >= 10 && $hold <= 60, 'GH223-O9: PULLBACK_FALLBACK_HOLD_S exists and is short (10..60 s)');
    my $mark = $C->pluginData('connectPullbackFellBack');
    ok(ref $mark eq 'HASH' && ($mark->{url} // '') eq $url, 'GH223-O9: the fallback is recorded for the entry');
    $mark->{at} -= ($hold // 30) + 1 if ref $mark eq 'HASH';
    my $later = GNSong->new(client => $C, url => $url);
    $C->{song} = $later;
    my $r3 = gnt($later);
    is(scalar(transfer_posts()), 2, 'GH223-O9: a Play after the hold tries the pull-back again');
    is("$r3->{ok}/$r3->{err}", '0/0', 'GH223-O9: ... and waits for its outcome');
}
{
    # a refused transfer marks the entry as well; a new Connect entry clears the mark
    my $url = moved_session();
    meta_for($url, 'DEADTRK');
    my $song = GNSong->new(client => $C, url => $url);
    $C->{song} = $song;
    my $r = gnt($song);
    my ($t) = transfer_posts();
    $t->fire_error('503 Service Unavailable', Resp503->new('Retry-After' => 2)) if $t;
    my $retry = GNSong->new(client => $C, url => $url);
    $C->{song} = $retry;
    my $r2 = gnt($retry);
    is(scalar(transfer_posts()), 1, 'GH223-O9 (refused): the retry open sends no second transfer either');
    is("$r2->{ok}/$r2->{err}", '1/0', 'GH223-O9 (refused): ... and answers at once');
    ev('start', 'TRK2');
    ok(!ref $C->pluginData('connectPullbackFellBack'), 'GH223-O9: a new Connect entry (start -> playlist play) clears the mark');
}

# ============================================================
# 88-06 Task 2 (D-05, GH #159): the session moved from LMS player P1 to P2. Play on P1
# (paused: _onPause pass-through; stopped: the open path) pulls it back the same way, and
# P2 stops in BOTH arrival orders. The two players have their own helper ports.
# ============================================================
{
    package PortHelper;        # a helper with its own stream port
    sub new { my ($c, $port) = @_; return bless { port => $port }, $c; }
    sub alive { 1 }
    sub _streamPort { $_[0]{port} }
}
my ($P1, $P2);
my %PORT_OF;
{
    no warnings 'redefine';
    my $orig_helper = \&Plugins::SpotOn::Unified::DaemonManager::helperForClient;
    my $orig_port   = \&Plugins::SpotOn::Unified::DaemonManager::streamPortForClient;
    *Plugins::SpotOn::Unified::DaemonManager::helperForClient = sub {
        my ($class, $id) = @_;
        $id = $id->id if ref $id;
        return PortHelper->new($PORT_OF{$id}) if defined $id && exists $PORT_OF{$id};
        return $orig_helper->(@_);
    };
    *Plugins::SpotOn::Unified::DaemonManager::streamPortForClient = sub {
        my ($class, $id) = @_;
        $id = $id->id if ref $id;
        return $PORT_OF{$id} if defined $id && exists $PORT_OF{$id};
        return $orig_port->(@_);
    };
}

# P1 had the session (its own `start` issued playlist play connect-<ts>), P2 holds the claim now
sub two_players {
    $CONNECT->releaseConnectClaim($P2) if $P2;
    fresh(playing => 0);
    $P1 = $C;
    ev('start', 'TRK1');
    my ($url) = map { $_->{args}[2] } grep { ($_->{args}[0] // '') eq 'playlist' && ($_->{args}[1] // '') eq 'play' } sent();
    $P2 = MockClient->new(playing => 1, song => MockSong->new(url => 'spoton://connect-8', info => { live => 1 }));
    $CONNECT->bindConnectClaim($P2, 'test');
    %PORT_OF = ($P1->id => 4251, $P2->id => 4252);
    $P1->pluginData(connectStartTime => 1);
    wire_reset();
    return $url;
}
sub p1_posts { return map { $_->{url} =~ s{^http://127\.0\.0\.1:}{}r } posts(); }

# --- GH159-C1: P2 holds the claim; Play (unpause) on P1's stale live stream reaches P1's daemon
{
    my $url = two_players();
    $P1->{song}   = MockSong->new(url => $url, info => { live => 1 });
    $P1->{paused} = 1;
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 0));
    is_deeply([ p1_posts() ], ['4251/control/play'], "GH159-C1: unpause on P1's stale stream while P2 holds the claim: /control/play to P1's own daemon port");
    is($CONNECT->isSpotifyConnect($P2), 1, 'GH159-C1: P2 keeps the claim until the session really moves');
}

# --- GH159-C2: P1's daemon answers 409 -> eject + reopen on P1, and the reopen transfers to P1's port
{
    my $url = two_players();
    $P1->{song}   = MockSong->new(url => $url, info => { live => 1 });
    $P1->{paused} = 1;
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 0));
    my ($play) = posts();
    $play->fire_error('409 Conflict', undef) if $play;
    is_deeply([ cmds() ], ['stop', 'play'], 'GH159-C2: the 409 ejects and reopens (stop, play)');
    is_deeply([ map { $_->{id} } sent() ], [ $P1->id, $P1->id ], 'GH159-C2: both requests address P1, not the claim holder');
    is($CONNECT->isSpotifyConnect($P2), 1, "GH159-C2: P1's 409 does not touch P2's claim (88 review CR-01)");
    meta_for($url, 'DEADTRK');
    my $song = GNSong->new(client => $P1, url => $url);
    $P1->{song} = $song;                                   # the reopen: P1's playingSong
    my $r = gnt($song);
    my @t = grep { $_ =~ m{/control/transfer$} } p1_posts();
    is_deeply(\@t, ['4251/control/transfer'], 'GH159-C2: the reopen sends exactly one /control/transfer, to P1\'s port');
    is("$r->{ok}/$r->{err}", '0/0', 'GH159-C2: the open waits for the outcome');
}

# --- GH159-C3: P1's start arrives first (pull-back worked), then P2's stop inactive pauses P2
{
    two_players();
    ev('start', 'TRK1');                                   # P1 (= $C): the claim moves to P1
    ok($CONNECT->isSpotifyConnect($P1), 'GH159-C3: precondition, the claim moved to P1');
    wire_reset();
    $C = $P2;
    ev('stop', 'inactive');                                # P2's own session end, P2 plays its live connect stream
    $C = $P1;
    is_deeply([ cmds() ], ['pause 1'], "GH159-C3: P2's stop inactive pauses P2 although the claim sits on P1");
    my @c3 = sent();
    is($c3[0] && $c3[0]{id}, $P2->id, 'GH159-C3: the pause addresses P2');
    is($c3[0] && $c3[0]{source}, $CONNECT_SRC, 'GH159-C3: the pause is source-marked');
    ok($CONNECT->isSpotifyConnect($P1), 'GH159-C3: the claim stays with P1');
}

# --- GH159-C6: the other arrival order - P2's stop inactive first (P2 holds the claim), then P1's start
{
    two_players();
    wire_reset();
    $C = $P2;
    ev('stop', 'inactive');
    $C = $P1;
    is_deeply([ cmds() ], ['pause 1'], 'GH159-C6: P2 holding the claim: its stop inactive pauses it');
    ok(!$CONNECT->isSpotifyConnect($P2), 'GH159-C6: ... and the claim is released');
    wire_reset();
    ev('start', 'TRK1');
    ok($CONNECT->isSpotifyConnect($P1), 'GH159-C6: then P1\'s start takes the claim');
}

# --- GH159-C7: a translated Browse fallback is not the Connect session
{
    two_players();
    $P2->{song} = MockSong->new(url => 'spoton://connect-8', streamUrl => 'spoton://track:ID1', info => { live => 1 });
    $CONNECT->releaseConnectClaim($P2);                    # no claim anywhere
    wire_reset();
    $C = $P2;
    ev('stop', 'inactive');
    $C = $P1;
    is_deeply([ cmds() ], [], 'GH159-C7: stop inactive on a player playing a translated Browse entry does not pause it');
}

# --- GH159-C4: a plain pause/stop/unpause from P1 stays ignored while P2 holds the claim and P1 has no stale stream
{
    two_players();
    $P1->{song}   = MockSong->new(url => 'spoton://track:BRW1', info => undef);
    $P1->{playing} = 1;
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 1));
    Plugins::SpotOn::Connect::_onPause(pause_req('stop', undef));
    $P1->{paused} = 1; $P1->{playing} = 0;
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 0));
    is(scalar(posts()), 0, 'GH159-C4: pause / stop / unpause of a Browse stream on P1 while P2 holds the claim: nothing forwarded');

    two_players();
    $P1->{song}    = MockSong->new(url => 'spoton://connect-9', info => { live => 1 });
    $P1->{playing} = 1;
    Plugins::SpotOn::Connect::_onPause(pause_req('pause', 1));
    Plugins::SpotOn::Connect::_onPause(pause_req('stop', undef));
    is(scalar(posts()), 0, 'GH159-C4: a plain pause / stop of P1\'s live stream while P2 holds the claim: still ignored (only the unpause passes)');
}

# --- GH159-C5: P2 holds the claim, P1 is stopped and LMS opens P1's last Connect entry -> the transfer goes to P1's port
{
    my $url = two_players();
    $CONNECT->_rememberConnectPlayUrl($P2, 'spoton://connect-555') if $CONNECT->can('_rememberConnectPlayUrl');
    meta_for($url, 'DEADTRK');
    my $song = GNSong->new(client => $P1, url => $url);
    $P1->{song} = $song;
    my $r = gnt($song);
    is_deeply([ p1_posts() ], ['4251/control/transfer'], "GH159-C5: the open of P1's last Connect entry transfers via P1's port (P2's claim does not block it)");
    is("$r->{ok}/$r->{err}", '0/0', 'GH159-C5: the open waits for the outcome');
}
$CONNECT->releaseConnectClaim($P2) if $P2;

# ============================================================
# 88-10 (D-20, IN-05 of the #216 review): a stale `stop inactive` cannot end the current
# Connect session. The 88-05 helper numbers its sessions: `start <id> 0 <counter>` (_p4) and
# `stop inactive <counter>` (_p3). Perl stores the counter at `start` and compares it at the
# session end; an absent counter (Soloist, old helper) counts as a match (D-06).
# (This file runs with INFOLOG off, so the info line itself is not asserted: the observable
# contract is the behaviour - pause, power restore, claim and the stored counter.)
# ============================================================
sub in05_session {
    my ($counter) = @_;
    fresh(playing => 0, power => 1);
    ev('start', 'TRK111', 0, $counter);
    $C->{playing} = 1;
    $C->{song}    = MockSong->new(url => 'spoton://connect-9', info => { live => 1 });
    @Slim::Control::Request::SENT = ();
    return;
}

# IN05-C1: the counter of the session is 2, a late `stop inactive` of session 1 arrives
in05_session('2');
ok($CONNECT->isSpotifyConnect($C), 'IN05-C1: precondition, the start bound the claim');
is($C->pluginData('connectSessionCounter'), '2', 'IN05-C1: precondition, start _p4 "2" is stored as the session counter');
ev('stop', 'inactive', '1');
is_deeply([ cmds() ], [], 'IN05-C1: stale stop inactive (counter 1, current 2): no pause');
is(prev_power($C), 1, 'IN05-C1: ... no power restore (the saved pre-Connect state is untouched)');
ok($CONNECT->isSpotifyConnect($C), 'IN05-C1: ... the claim is kept');
is($C->pluginData('connectSessionCounter'), '2', 'IN05-C1: ... the stored counter is kept');

# IN05-C2: the matching counter ends the session as today
in05_session('2');
ev('stop', 'inactive', '2');
is_deeply([ cmds() ], ['pause 1'], 'IN05-C2: stop inactive with the matching counter: pause as today');
is(prev_power($C), undef, 'IN05-C2: ... the saved power state is consumed (restore ran)');
ok(!$CONNECT->isSpotifyConnect($C), 'IN05-C2: ... the claim is released');
is($C->pluginData('connectSessionCounter'), '', 'IN05-C2: ... the stored counter is cleared');

# IN05-C3: no counter on the stop (Soloist / old helper) = match (D-06)
in05_session('2');
ev('stop', 'inactive');
is_deeply([ cmds() ], ['pause 1'], 'IN05-C3: stop inactive without a counter: pause as today (absence = match)');
ok(!$CONNECT->isSpotifyConnect($C), 'IN05-C3: ... the claim is released');
# ... and a non-digit counter is no counter either (digits-only parse)
in05_session('2');
ev('stop', 'inactive', 'abc');
is_deeply([ cmds() ], ['pause 1'], 'IN05-C3: a non-digit counter on the stop counts as absent: pause as today');

# IN05-C4: Soloist's 'restored' marker in _p4 keeps its meaning and stores no counter
fresh(playing => 0, power => 1);
ev('start', 'TRK111', 0, 'restored');
is_deeply([ cmds() ], [], "IN05-C4: start with _p4 'restored' still suppresses the autoplay (no playlist play)");
ok(!defined $C->pluginData('connectSessionCounter'), "IN05-C4: ... and stores no counter");
# a start without any counter stores nothing and today's stop inactive still ends it
fresh(playing => 0, power => 1);
ev('start', 'TRK111');
ok(!defined $C->pluginData('connectSessionCounter'), 'IN05-C4: a start without _p4 stores no counter');

# IN05-C5: `start <id> 0 <n>` - the start position 0 is ignored (no progress), the counter is read from _p4, not _p3
fresh(playing => 0, power => 1);
ev('start', 'TRK111', 0, '7');
ok(!defined $C->pluginData('progress'), 'IN05-C5: start <id> 0 <n> sets no progress (start position 0 ignored)');
is($C->pluginData('connectSessionCounter'), '7', 'IN05-C5: the counter comes from _p4 (a 0 in _p3 is the position)');

# IN05-C6: a start suppressed by the restart gate still stores its counter, so the current
# session's own `stop inactive` is not ignored as stale (round-3 finding: the store sits ABOVE the suppression return)
fresh(playing => 0, power => 1);
$Plugins::SpotOn::Unified::DaemonManager::UPTIME = 1.5;       # daemon respawned 1.5 s ago, idle player
ev('start', 'TRK333', 0, '3');
is_deeply([ cmds() ], [], 'IN05-C6: precondition, the restart gate suppressed the start (no playlist play)');
is($C->pluginData('connectSessionCounter'), '3', 'IN05-C6: a suppressed start still stores its counter');
$C->{playing} = 1;
$C->{song}    = MockSong->new(url => 'spoton://connect-9', info => { live => 1 });
$CONNECT->bindConnectClaim($C, 'test');
@Slim::Control::Request::SENT = ();
ev('stop', 'inactive', '3');
is_deeply([ cmds() ], ['pause 1'], 'IN05-C6: the following stop inactive of the SAME counter is not stale: pause as today');
is($C->pluginData('connectSessionCounter'), '', 'IN05-C6: ... and clears the stored counter');
$Plugins::SpotOn::Unified::DaemonManager::UPTIME = 0;

done_testing();

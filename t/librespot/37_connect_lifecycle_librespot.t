#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# ============================================================
# Phase 76-05: Connect lifecycle source assertions (grep gates).
#
# Connect.pm has no isolated unit harness (Phase 73-03 D4), so these
# regression nets pin the three 76-05 fixes at the source level, following
# the established grep-gate idiom from t/10_stream_metadata.t:
#
#   1. Restart-autoplay provenance gate (ROADMAP: no self-starting audio
#      after an LMS restart re-announces a dormant Connect session)
#   2. GH #151 power-state save/restore across the Connect session
#   3. GH #158 pause-skip-play loop: change handler must not force-unpause
#      while the Spotify session itself is paused
# ============================================================

# 84-09: librespot half of t/37_connect_lifecycle.t -- the source nets over
# Backend/Librespot.pm _sendControlCommand (the rest: t/core/ and
# t/soloist/37_connect_lifecycle_*.t).
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

my $connect_file  = "$project_dir/Plugins/SpotOn/Connect.pm";
my $ws_file       = "$project_dir/Plugins/SpotOn/Unified/SoloistWS.pm";
my $handler_file  = "$project_dir/Plugins/SpotOn/ProtocolHandler.pm";

die "Connect.pm not present in this checkout -- wrong project root or broken checkout (84-09: die, never skip)\n" unless -f $connect_file;

sub slurp {
    my ($file) = @_;
    open(my $fh, '<', $file) or die "Cannot read $file: $!";
    local $/;
    my $src = <$fh>;
    close($fh);
    return $src;
}

my $connect = slurp($connect_file);
my $ws      = -f $ws_file ? slurp($ws_file) : '';
my $handler = -f $handler_file ? slurp($handler_file) : '';

# The suppress branch must NOT dispatch playlist play but must keep the
# metadata fetch (session stays visible / manually resumable).

# ------------------------------------------------------------
# Task 2: GH #151 power save/restore
# ------------------------------------------------------------




# ------------------------------------------------------------
# Phase 78-04: D-04 dual-backend dispatch (spoton://track: for
# Soloist, spoton://connect-%u for librespot)
# ------------------------------------------------------------

# Gate 1: 'start' block dispatches spoton://track: in a SoloistDaemon
# isa-branch AND still contains the literal spoton://connect-%u sprintf
# (librespot branch).
# 84-08 (SEAM-6.2): the URL choice moved into ONE helper keyed on the
# role's connectEntry -- the start block takes its URL from _playUrlFor and
# keys the per-track extras on the spoton://track: shape of that URL.

# Gate 2: 'change' block has dual-backend dispatch; the Soloist branch
# contains no skipInitiated reference (D-05 flush-disconnect delivers EOF).

# _onPause D-16 stale-claim guard: 83.1-07 inlines the librespot-only
# live-connect-stream check instead of calling the deleted helper. 84-07:
# the chain is gated by the role's connectClaimGate capability (librespot
# only) and the forwarding is the single role call after it.
my ($on_pause_block) = $connect =~ /(sub _onPause \{.*?\nsub )/s;

# ------------------------------------------------------------
# Phase 78-04: Watchdog Connect guards (Plugin.pm)
#
# Each of the five watchdog subs must contain at least one
# isSpotifyConnect reference; _onNewSongWatchdog must contain
# two (main body + deferred-timer closure).
# ------------------------------------------------------------



# ------------------------------------------------------------
# browse-stale-metadata-elapsed: _fetchTrackMetadata callback must not
# bleed a Connect track's title/duration onto a Browse song that took
# over playingSong() while the async getTrack() API call was in flight
# (e.g. a session-restore fetch racing a `playlist play spoton://track:`
# issued right after an LMS restart).
# ------------------------------------------------------------

my ($fetch_block) = $connect =~ /(sub _fetchTrackMetadata \{.*?\n1;)/s;

# The 'start' branch must contain no UNCONDITIONAL claim write -- the write
# `$_activeConnectPlayer = $client->id;` sits ONLY inside the non-Soloist
# (librespot) branch of the isa-check, never unguarded at the top level.




# ------------------------------------------------------------
# 83.1-03 Task 2 (D-08): requestPause/requestResume/requestVolume routed
# through Control for BOTH modes; Connect.pm's _onPause/_bufferedSetVolume
# no longer gate the Control call on mode ne 'connect' -- the
# _sendControlCommand fallthrough is reached only when no Control exists
# (librespot).
# ------------------------------------------------------------

my ($on_pause_block_03) = $connect =~ /(sub _onPause \{.*?\nsub )/s;


# ------------------------------------------------------------
# 83.1-04 Task 1 (D-B1): connect seek runs through the restart chain
# (getSeekData -> onStream -> Control::requestTrack -> the connect seek row
# in _reconcilePlan's Seek-Pfad); the LMS-side ['time'] WS bypass for N > 0
# is gone from _onSeek. canDoAction's connect 'rew' block is KEPT (plan-04
# decision: restart-at-0 now routes through requestSkip('prev'), not
# through an LMS-side stream restart).
# ------------------------------------------------------------




# ------------------------------------------------------------
# 83.1-04 Task 2 (D-B2/D-B4): _onPlaylistJump routes both directions
# through Control::requestSkip; the D-B4 available_actions precondition is
# implemented in Control.pm.
# ------------------------------------------------------------


# ------------------------------------------------------------
# Debug session connect-skip-prev-ton-bleibt (2026-09-24), user decision
# 1B -- DEVIATION from D-B2 for `jump +0`: LMS decides. `jump +0` (the LMS
# "previous" button more than 5 s into the title) restarts the title from
# 0 through the seek path (Control::requestRestart); only a real `jump -1`
# goes to Spotify as skip_prev. Where the restart route cannot run
# (requestRestart returns 0), `jump +0` keeps the old skip_prev route.
#
# Connect.pm has no unit harness (Phase 73-03 D4), so the REAL
# _onPlaylistJump source is extracted from the file and compiled into a
# scratch package against recording stubs -- the assertions run the
# routing code itself, not a regex over it.
# ------------------------------------------------------------
# 84-07 Task 2: the harness drives the REAL handlers against a mock
# backend role (DaemonManager->backendFor) instead of a Control stub --
# Connect.pm no longer asks Control directly for any transport command.
{
    package Test::RoleMock;
    sub new {
        my ($class, %args) = @_;
        return bless { mode => 'connect', gate => 0, outcome => {}, calls => [], notes => [], queries => [], %args }, $class;
    }
    sub state        { return { mode => $_[0]->{mode} }; }
    sub capabilities { return { connectClaimGate => $_[0]->{gate} }; }
    sub control {
        my ($self, $verb, %args) = @_;
        push @{ $self->{calls} }, [ $verb, {%args} ];
        return exists $self->{outcome}{$verb} ? $self->{outcome}{$verb} : 'ok';
    }
    sub notify {
        my ($self, $event, %args) = @_;
        push @{ $self->{notes} }, [ $event, {%args} ];
        return 'ok';
    }
    sub query {
        my ($self, $what, %args) = @_;
        push @{ $self->{queries} }, $what;
        return $self->{wanted};
    }

    package Test::JumpClient;
    sub new        { return bless { id => $_[1], pd => {} }, $_[0]; }
    sub master     { return $_[0]; }
    sub id         { return $_[0]->{id}; }
    sub pluginData { my ($s, $k, $v) = @_; $s->{pd}{$k} = $v if @_ > 2; return $s->{pd}{$k}; }
    sub playingSong { return undef; }

    package Test::JumpRequest;
    sub new      { my ($class, %args) = @_; return bless {%args}, $class; }
    sub source   { return $_[0]->{source}; }
    sub client   { return $_[0]->{client}; }
    sub getParam { return $_[0]->{params}{ $_[1] }; }
    sub isCommand {
        my ($self, $spec) = @_;
        my $cmd = $self->{cmd} || [];
        for my $i (0 .. $#$spec) {
            return 0 unless defined $cmd->[$i] && grep { $_ eq $cmd->[$i] } @{ $spec->[$i] };
        }
        return 1;
    }

    package Test::RoleLog;
    our @INFO;
    sub new      { return bless {}, shift; }
    sub info     { shift; push @INFO, join('', @_); }
    sub debug    { }
    sub warn     { }
    sub is_info  { 1 }
    sub is_debug { 0 }

    package Test::RolePrefs;
    sub new { return bless {}, shift; }
    sub get { return undef; }

    # Stand-ins (never the real modules in this file): the handlers'
    # `require`s must find them in %INC; the side-effect channels count.
    package Plugins::SpotOn::Unified::DaemonManager;
    our $ROLE;
    # 84-08 Task 3: per-client roles (bindConnectClaim asks the OLD player's
    # role) and the running-daemon probe _liveCaps reads.
    our %ROLES;
    our $HELPER = 1;
    sub backendFor {
        my ($class, $c) = @_;
        my $id = ref $c ? $c->id : $c;
        return (defined $id && exists $ROLES{$id}) ? $ROLES{$id} : $ROLE;
    }
    sub helperForClient { return $HELPER; }

    package Slim::Player::Source;
    our $PLAYMODE = 'stop';
    sub playmode { return $PLAYMODE; }

    package Slim::Control::Request;
    our $NEW = 0;
    sub new { $NEW++; return bless {}, shift; }
    sub source { }
    sub execute { }

    package Slim::Networking::SimpleAsyncHTTP;
    our $NEW = 0;
    sub new  { $NEW++; return bless {}, shift; }
    sub post { }

    package Plugins::SpotOn::API::Client;
    our $CALLS = 0;
    sub AUTOLOAD { $CALLS++; }

    # Control is never reached through these handlers any more; the
    # stand-in (no instance for any player) keeps a stray `require` from
    # dying and would make a direct Control route visible as "no call".
    package Plugins::SpotOn::Soloist::Control;
    sub for_client { return undef; }
}
$INC{'Plugins/SpotOn/Unified/DaemonManager.pm'} = __FILE__;
$INC{'Plugins/SpotOn/Soloist/Control.pm'}       = __FILE__;
{
    no strict 'refs';
    *{'main::INFOLOG'}  = sub () { 1 } unless defined &main::INFOLOG;
    *{'main::DEBUGLOG'} = sub () { 0 } unless defined &main::DEBUGLOG;
}

my %role_src;
for my $name (qw(_onPause _onLmsStop _bufferedSetVolume _onSeek _onPlaylistJump)) {
    ($role_src{$name}) = $connect =~ /(sub \Q$name\E \{.*?\n\})\n/s;
}
my $role_compiled = !grep { !defined } values %role_src;
$role_compiled &&= eval(
    "package Test::RoleHarness;\n"
    . "use strict; use warnings; use Time::HiRes;\n"
    . "use constant CONNECT_START_GRACE => 12;\n"
    . "use constant VOLUME_DEBOUNCE => 0.5;\n"
    . "our \$SPOTIFY_CONNECT = 0;\n"
    . "my \$log   = Test::RoleLog->new;\n"
    . "my \$prefs = Test::RolePrefs->new;\n"
    . "my \$_activeConnectPlayer;\n"
    . "sub isSpotifyConnect { return \$SPOTIFY_CONNECT; }\n"
    . "sub _holdCancel { return; }\n"
    . "sub _isDeadHistoryUrl { return 0; }\n"
    . "sub _seekPositionFromRequest { return \$_[1]->getParam('_newvalue'); }\n"
    # a leftover direct HTTP send (the pre-84-07 route) counts as a POST
    . "sub _sendControlCommand { \$Slim::Networking::SimpleAsyncHTTP::NEW++; return; }\n"
    . join("\n", map { $role_src{$_} } sort keys %role_src) . "\n1;"
);

my $MAC37 = '02:00:00:5a:11:01';
sub role_reset {
    @Test::RoleLog::INFO = ();
    $Slim::Control::Request::NEW = 0;
    $Slim::Networking::SimpleAsyncHTTP::NEW = 0;
    $Plugins::SpotOn::API::Client::CALLS = 0;
    $Test::RoleHarness::SPOTIFY_CONNECT = 0;
}
sub role_run {
    my ($role, $handler, %req) = @_;
    local $Plugins::SpotOn::Unified::DaemonManager::ROLE = $role;
    my $client = $req{client} || Test::JumpClient->new($MAC37);
    no strict 'refs';
    &{"Test::RoleHarness::$handler"}(Test::JumpRequest->new(client => $client, %req));
    return $role;
}
sub verbs { return [ map { $_->[0] } @{ $_[0]->{calls} } ]; }

my $jump_run = sub {
    my ($role, $index) = @_;
    role_run($role, '_onPlaylistJump', params => { _index => $index });
    return $role->{calls};
};


# ------------------------------------------------------------
# 83.1-07 Task 1 (ROADMAP Task 6): the Soloist WS branch of
# _sendControlCommand and _bufferedSeek are gone -- only the librespot HTTP
# path remains, reached only when no Control instance exists for the
# player.
# ------------------------------------------------------------
# 84-07 Task 2: the sender moved to Backend/Librespot.pm; Connect.pm has none left.
my $librespot_role = -f "$project_dir/Plugins/SpotOn/Backend/Librespot.pm"
    ? slurp("$project_dir/Plugins/SpotOn/Backend/Librespot.pm") : '';
my ($send_control_block) = $librespot_role =~ /(sub _sendControlCommand \{.*?\n\})/s;
ok($send_control_block, '83.1-07/84-07: Backend::Librespot _sendControlCommand block parseable');
if ($send_control_block) {
    my $send_control_code = join("\n", grep { !/^\s*#/ } split /\n/, $send_control_block);
    unlike($send_control_code, qr/isa\('Plugins::SpotOn::Unified::SoloistDaemon'\)/,
        "83.1-07: _sendControlCommand no longer checks isa('...SoloistDaemon')");
    unlike($send_control_code, qr/sendCommand\(/,
        "83.1-07: _sendControlCommand no longer calls \$ws->sendCommand(");
    unlike($send_control_code, qr/endpointToCommand/,
        "83.1-07: _sendControlCommand no longer maps endpointToCommand");
}


# ------------------------------------------------------------
# 84.1-07 (D-02): source gates for the leave path -- placement before
# CON-17, the exact guard text, the GH #151 discard, leaveConnect's own
# order and no-dispatch shape, the T-84.1-29 re-adoption guard on the
# reconnect `if`, and the marker's clear points (revision 2). These pin
# source shape; Task 2's mutation proofs (t/44/t/41 behaviour) are the
# can-fail evidence for what a source grep alone cannot catch.
# ------------------------------------------------------------




# G8 (revision 2, marker lifetime): the marker never outlives its
# post-leave episode -- same-line clears at requestTrack and the
# transfer-in, plus the explicit endForeignLeave clear point for an LMS
# stop / playlist clear.


# ------------------------------------------------------------
# 84.1-08 (CR-01): a distinct coderef for the playlist-clear subscription,
# so LMS's coderef-keyed %listeners (Request.pm:797) keeps both entries
# instead of the second silently replacing the first.
# ------------------------------------------------------------




# G10: WR-02's discriminator placement and its no-clock/weak-reference
# shape.



# G11: the IN-04 no-WS-connection notice sits before the deactivate probe,
# and the existing G6 forbidden-token assertion stays green.




# ------------------------------------------------------------
# 84-08 Task 3 (SEAM-6.2): the REAL Connect.pm/Plugin.pm handler sources
# that moved onto the role, compiled into a scratch package against
# recording mock roles (same discipline as the 84-07 harness above).
# ------------------------------------------------------------
{
    package Test::RoleMock3;
    sub new {
        my ($class, %a) = @_;
        return bless { st => {}, caps => {}, notes => [], outcome => {}, %a }, $class;
    }
    sub state        { return { %{ $_[0]->{st} } }; }
    sub capabilities { return { %{ $_[0]->{caps} } }; }
    sub notify {
        my ($self, $event, %args) = @_;
        push @{ $self->{notes} }, [ $event, {%args} ];
        return exists $self->{outcome}{$event} ? $self->{outcome}{$event} : 'ok';
    }
    sub control { return 'unsupported'; }

    package Test::RoleLog3;
    our (@INFO, @WARN);
    sub new      { return bless {}, shift; }
    sub info     { shift; push @INFO, join('', @_); }
    sub warn     { shift; push @WARN, join('', @_); }
    sub debug    { }
    sub is_info  { 1 }
    sub is_debug { 0 }

    package Test::Client3;
    sub new        { my ($c, $id, %a) = @_; return bless { id => $id, pd => {}, executed => [], %a }, $c; }
    sub id         { return $_[0]->{id}; }
    sub master     { return $_[0]; }
    sub pluginData { my ($s, $k, $v) = @_; $s->{pd}{$k} = $v if @_ > 2; return $s->{pd}{$k}; }
    sub playingSong { return $_[0]->{song}; }
    sub execute    { my ($s, $cmd) = @_; push @{ $s->{executed} }, [ @$cmd ]; }

    package Test::Song3;
    sub new   { return bless { url => $_[1] }, $_[0]; }
    sub track { return $_[0]; }
    sub url   { return $_[0]->{url}; }

    package Slim::Player::Client;
    our %BY_ID;
    sub getClient { return $BY_ID{ $_[0] }; }

    package Plugins::SpotOn::Connect;
    our $IS_CONNECT = 0;
    sub isSpotifyConnect { return $IS_CONNECT; }
}
$INC{'Plugins/SpotOn/Connect.pm'} = __FILE__;

my %src3;
for my $name (qw(_liveCaps _playUrlFor bindConnectClaim _onLmsPlaylistChanged _holdCaps _holdCap _holdRecheck _holdMax _holdClose)) {
    ($src3{$name}) = $connect =~ /(sub \Q$name\E \{.*?\n\})\n/s;
    ($src3{$name}) = $connect =~ /^(sub \Q$name\E .*?\})$/m unless $src3{$name};
}
my ($hang_src) = slurp("$project_dir/Plugins/SpotOn/Plugin.pm") =~ /(sub _prefetchHangCheck \{.*?\n\})\n/s;
$src3{_prefetchHangCheck} = $hang_src;
my @missing3 = grep { !defined $src3{$_} } sort keys %src3;
my $h3 = !@missing3 && eval(
    "package Test::RoleHarness3;\n"
    . "use strict; use warnings; use Time::HiRes; use Scalar::Util qw(weaken);\n"
    . "my \$log = Test::RoleLog3->new;\n"
    . "my (\$_activeConnectPlayer, \$_lastBindAt, %_connectEntrySong, %_hold, %_watchdogTriggerUrl);\n"
    . "sub setActive  { \$_activeConnectPlayer = \$_[0]; }\n"
    . "sub getActive  { return \$_activeConnectPlayer; }\n"
    . "sub setHold    { \$_hold{ \$_[0] } = \$_[1]; }\n"
    . "sub setTrigger { \$_watchdogTriggerUrl{ \$_[0] } = \$_[1]; }\n"
    . join("\n", map { $src3{$_} } sort keys %src3) . "\n1;"
);

done_testing();

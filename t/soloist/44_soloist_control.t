#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use Time::HiRes;

# Resolve project root (t/<group>/x.t sits two levels below it)
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

my $module = "$project_dir/Plugins/SpotOn/Soloist/Control.pm";
unless (-f $module) {
    die "Plugins/SpotOn/Soloist/Control.pm not yet present in this checkout -- wrong project root or broken checkout (84-09: die, never skip)\n";
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

# ============================================================
# LMS module stubs required to load Control.pm in isolation (t/31-style
# harness, copied per-file per project convention).
# ============================================================

write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
our @WARNINGS;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub logger { return bless {}, 'Slim::Utils::Log' }
sub info  { }
sub warn  { my $self = shift; push @WARNINGS, join('', @_); }
sub error { }
sub debug { }
sub is_info  { 1 }
sub is_debug { 1 }
sub AUTOLOAD { }
sub can { 1 }
1;
END

write_stub($stub_dir, 'Slim::Utils::Prefs', <<'END');
package Slim::Utils::Prefs;
our %FAKE_VALUES = ( enableSpotifyConnect => 1 );
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::preferences"} = \&preferences;
}
sub preferences { return bless {}, 'Slim::Utils::Prefs' }
sub get    { my ($self, $key) = @_; return $FAKE_VALUES{$key}; }
sub set    { my ($self, $key, $val) = @_; $FAKE_VALUES{$key} = $val; }
sub client { return bless {}, 'Slim::Utils::Prefs' }
1;
END

# Recorder -- our @TIMERS holds [$obj, $when, $cb, @extra_args]. fire_due($now)
# fires (and removes) every timer whose $when <= $now, in order.
write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
our @TIMERS;
sub setTimer {
    my ($obj, $when, $cb, @args) = @_;
    push @TIMERS, [$obj, $when, $cb, @args];
}
sub killTimers {
    my ($obj, $cb) = @_;
    @TIMERS = grep { !($_->[0] == $obj && $_->[2] == $cb) } @TIMERS;
}
sub fire_due {
    my ($now) = @_;
    my @due = grep { $_->[1] <= $now } @TIMERS;
    @TIMERS = grep { $_->[1] > $now } @TIMERS;
    for my $t (@due) {
        my ($obj, undef, $cb, @extra) = @$t;
        $cb->($obj, @extra);
    }
}
1;
END

# use base qw(Slim::Utils::Accessor) target. Array-based (blessed ARRAY refs,
# not hashes) to match the REAL Slim::Utils::Accessor contract -- CR-01.
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

# getClient() returns a recorder whose execute() pushes to a shared array --
# this is how tests would observe spottyconnect emissions, once wired.
# volume() (82-05, Task 6) is a plain get/set -- callers set it explicitly
# per test via Slim::Player::Client::getClient($mac)->volume($n) before
# exercising Control, since the client cache is shared file-wide (%clients).
write_stub($stub_dir, 'Slim::Player::Client', <<'END');
package Slim::Player::Client;
our @EXECUTED;
our @ORDER;
my %clients;
sub getClient {
    my ($mac) = @_;
    return undef unless defined $mac;
    unless (exists $clients{$mac}) {
        $clients{$mac} = bless { mac => $mac }, 'Slim::Player::Client::Recorder';
        # CR-04 (82-REVIEW.md, Task 1): _lmsSongIsOurs reads
        # streamingSong/playingSong off this client to decide whether LMS
        # is on OUR material. The large majority of this file's existing
        # requestPause/requestResume/requestVolume tests are about the
        # playmode/echo/grace logic those subs sit behind, not about
        # ownership itself -- defaulting every freshly-minted client to an
        # OWNED spoton:// track keeps that body of tests representative of
        # the common case without threading a song through every one of
        # them. Only the CR-04 test block explicitly overrides this to a
        # foreign or absent song to exercise the guard itself.
        $clients{$mac}->{streamingSong} =
            Slim::Player::Client::_StubSong->new('spoton://track:0000000000000default');
    }
    return $clients{$mac};
}
package Slim::Player::Client::Recorder;
# 79-53: one shared, ordered log of what the player was told (exec:<cmd> and
# hint:<text>); the never-paired refusal pins the ORDER stop, hint, errorCb.
# @EXECUTED stays as it was for every older block.
sub execute {
    my ($self, $req) = @_;
    push @Slim::Player::Client::EXECUTED, $req;
    push @Slim::Player::Client::ORDER, 'exec:' . join(' ', @$req);
}
sub showBriefly {
    my ($self, $h) = @_;
    my $t = $h && $h->{jive} ? $h->{jive}{text} : undef;
    push @Slim::Player::Client::ORDER, 'hint:' . ($t ? $t->[0] : '');
}
sub id     { return $_[0]->{mac}; }
sub volume {
    my $self = shift;
    $self->{volume} = shift if @_;
    return $self->{volume};
}
sub streamingSong {
    my $self = shift;
    $self->{streamingSong} = shift if @_;
    return $self->{streamingSong};
}
sub playingSong {
    my $self = shift;
    $self->{playingSong} = shift if @_;
    return $self->{playingSong};
}
# Debug session connect-skip-prev-ton-bleibt (1B): Control::requestRestart
# asks LMS' StreamingController for a restart from 0. The stub records
# every jumpToTime call and runs $ON_JUMP synchronously inside it -- the
# place where the real _JumpToTime consults canDoAction('rew').
sub controller {
    my $self = shift;
    return $self->{controller} //= Slim::Player::Client::_StubController->new;
}
package Slim::Player::Client::_StubController;
our @JUMPS;
our $ON_JUMP;
sub new       { return bless { paused => 0, stopped => 0 }, shift; }
sub isPaused  { return $_[0]->{paused}; }
sub isStopped { return $_[0]->{stopped}; }
sub jumpToTime {
    my ($self, @args) = @_;
    push @JUMPS, [ @args ];
    $ON_JUMP->(@args) if $ON_JUMP;
    return;
}
package Slim::Player::Client::_StubSong;
sub new   { my ($class, $url) = @_; return bless { url => $url }, $class; }
sub track { return bless { url => $_[0]->{url} }, 'Slim::Player::Client::_StubTrack'; }
package Slim::Player::Client::_StubTrack;
sub url { return $_[0]->{url}; }
1;
END

# playmode() (82-05, Task 4) -- classification source for
# Control::requestPause; $PLAYMODE is package-global and mutated per test
# via `local`. streamingSongIndex/playingSongIndex (82-06, Task 1) share
# one $INDEX knob -- Control::_prefetchNext's fallback from the first to
# the second only matters when streamingSongIndex is undef, which this
# harness never needs to exercise.
#
# 82-42 Task C (Bauform Fall (b), get-state-statt-play.md Frage 2): the
# retry hook now ALSO calls playmode($client,'play') -- a two-arg SET
# call, distinct from every pre-existing one-arg READ call in this file
# (`Slim::Player::Source::playmode($client)` in Control::requestPause).
# @PLAYMODE_CALLS records only the two-arg form so Fall-4 can assert this
# fresh LMS-side call happened without disturbing $PLAYMODE reads any
# existing test already depends on.
write_stub($stub_dir, 'Slim::Player::Source', <<'END');
package Slim::Player::Source;
our $PLAYMODE = 'play';
our $INDEX = 0;
our @PLAYMODE_CALLS;
sub playmode {
    my ($client, @rest) = @_;
    if (@rest) {
        push @PLAYMODE_CALLS, [ $client, @rest ];
        return;
    }
    return $PLAYMODE;
}
sub songTime { return 0; }
sub streamingSongIndex { return $INDEX; }
sub playingSongIndex   { return $INDEX; }
1;
END

# _prefetchNext's playlist lookahead (82-06, Task 1). @ENTRIES is a plain
# array of blessed Test::MockTrack-shaped objects (a `url` accessor is
# enough -- Control never reads anything else off a playlist entry).
write_stub($stub_dir, 'Slim::Player::Playlist', <<'END');
package Slim::Player::Playlist;
our @ENTRIES;
# 84.2-02: the repeat-aware lookahead reads track/repeat/shuffle (song is
# deprecated in LMS and kept here for older call sites only).
our $REPEAT = 0;
our $SHUFFLE = 0;
sub song    { my ($c, $i) = @_; return $ENTRIES[$i]; }
sub track   { $ENTRIES[$_[1]] }
sub count   { return scalar @ENTRIES; }
sub repeat  { $REPEAT }
sub shuffle { $SHUFFLE }
1;
END

# D-34 (79-48): the source-marked LMS requests Control forwards during Browse
# (pause 0|1, playlist index +1|-1). The stub keeps the request objects in
# @EXECUTED (cmd + source), the way t/core/41's own copy does; Control only
# `require`s it lazily, so every pre-existing test is untouched by it. A stub
# here (not the LMS tree under /usr/share/perl5) keeps the file hermetic.
write_stub($stub_dir, 'Slim::Control::Request', <<'END');
package Slim::Control::Request;
our @EXECUTED;
sub new {
    my ($class, $clientid, $cmdArray) = @_;
    return bless { clientid => $clientid, cmd => $cmdArray, source => undef }, $class;
}
sub source {
    my $self = shift;
    $self->{source} = shift if @_;
    return $self->{source};
}
sub execute {
    my $self = shift;
    push @EXECUTED, $self;
    return 1;
}
1;
END

# Records constructor callbacks + post($url) calls, and exposes a deferred-
# fire mode (t/29 convention) -- AUTO_FIRE 'ok' (default) fires the success
# callback synchronously inside post(), 'error' fires the error callback,
# 'defer' waits for the test to call fire_ok/fire_error manually.
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
our @CALLS;
our $AUTO_FIRE = 'ok';
sub new {
    my ($class, $ok_cb, $err_cb, $opts) = @_;
    return bless { ok_cb => $ok_cb, err_cb => $err_cb, opts => $opts }, $class;
}
sub post {
    my ($self, $url, @rest) = @_;
    $self->{url} = $url;
    push @CALLS, $self;
    if ($AUTO_FIRE eq 'ok') {
        $self->fire_ok;
    }
    elsif ($AUTO_FIRE eq 'error') {
        $self->fire_error;
    }
    return $self;
}
sub fire_ok    { my $self = shift; $self->{ok_cb}->($self); }
sub fire_error { my $self = shift; $self->{err_cb}->($self, '500 Internal Server Error', undef); }
1;
END

# errors[] recorder -- Control's _recordErrorOnce calls
# Plugins::SpotOn::Status->recordError($level, $module, $message, $key).
# clearError (82-11, WR-05 Raeumlogik) mirrors the real Status.pm: removes
# every entry whose module AND key (index 3) both match -- a no-op if
# nothing matches (e.g. a foreign MAC's key).
write_stub($stub_dir, 'Plugins::SpotOn::Status', <<'END');
package Plugins::SpotOn::Status;
our @RECORDED;
sub recordError {
    my $class = shift;
    push @RECORDED, [@_];
    # R3-WR02 Schritt 0: mirror the real Status.pm's MAX_ERROR_HISTORY=30
    # ring boundary -- without this, a stub-modeled eviction (Faelle A/B)
    # is not constructible at all.
    shift @RECORDED while scalar @RECORDED > 30;
}
sub clearError {
    my ($class, $module, $key) = @_;
    return unless defined $key;
    @RECORDED = grep {
        !(($_->[1] // '') eq $module && defined($_->[3]) && $_->[3] eq $key)
    } @RECORDED;
}
# hasError (R3-WR02 Schritt 0): same module+key comparison as clearError,
# but a pure query -- no state change. Lets _recordErrorOnce ask whether
# the ring still holds an entry before trusting its local dedupe lock.
sub hasError {
    my ($class, $module, $key) = @_;
    return 0 unless defined $key;
    return scalar grep {
        ($_->[1] // '') eq $module && defined($_->[3]) && $_->[3] eq $key
    } @RECORDED;
}
1;
END

# 83.1-02 Task 1/2: claim-bind recorder -- Control's _onFrameDeviceChanged
# lazily `require`s the REAL Plugins::SpotOn::Connect (D-D1); this stub
# shadows it (stub_dir precedes project_dir in @INC) with a controllable
# recorder so t/44 asserts Control's CALL, not Connect.pm's own state
# machine (which has no isolated unit harness, Phase 73-03 D4).
# @CLAIMS holds [ 'bind'|'release', $mac, $source ] tuples in call order.
#
# Task 2 (D-D2): $ACTIVE mirrors the real Connect.pm's package-scalar
# $_activeConnectPlayer -- bindConnectClaim below implements the SAME
# for_client-aware conflict check the real sub carries, against the REAL
# (non-stubbed) Plugins::SpotOn::Soloist::Control this file loads, so Fall-5
# exercises Control's OWN _recordErrorOnce/observed contract exactly as a
# live conflict would drive it.
write_stub($stub_dir, 'Plugins::SpotOn::Connect', <<'END');
package Plugins::SpotOn::Connect;
our @CLAIMS;
our $ACTIVE;
# 4th tuple element: a snapshot of how many spottyconnect executes had
# already fired at call time -- lets Fall-1 assert "bind BEFORE the
# _emitStart execute" structurally, not by inference from call order alone.
sub bindConnectClaim {
    my ($class, $client, $source) = @_;
    my $newId = $client ? $client->id : undef;

    if (defined $ACTIVE && defined $newId && $ACTIVE ne $newId) {
        my $oldId = $ACTIVE;
        require Plugins::SpotOn::Soloist::Control;
        my $oldClient = Slim::Player::Client::getClient($oldId);
        my $oldCtl    = $oldClient ? Plugins::SpotOn::Soloist::Control->for_client($oldClient) : undef;
        if ($oldCtl && $oldCtl->mode eq 'connect' && $oldCtl->observed->{is_active}) {
            $oldCtl->_recordErrorOnce('claim-conflict:' . $oldId, 'warn',
                $oldId . ": Connect claim: last message wins -- " . $newId
                . " replaces it while " . $oldId . " still reports an active session (D-D2)");
            $oldCtl->observed->{is_active} = 0;
        }
    }

    $ACTIVE = $newId;
    push @CLAIMS, [ 'bind', $newId, $source, scalar(@Slim::Player::Client::EXECUTED) ];
}
sub releaseConnectClaim {
    my ($class, $client, $source) = @_;
    push @CLAIMS, [ 'release', ($client ? $client->id : undef), $source, scalar(@Slim::Player::Client::EXECUTED) ];
}
sub isSpotifyConnect { return 0; }
1;
END

# Phase 82 Plan 01/04: counts /boundary and /seek-arm POSTs by PeerPort and
# hands back an in-memory filehandle (blessed glob) so `print $sock ...;
# close($sock);` in Control's boundary/sync-arm paths never touches a real
# socket. @REQUESTS (82-04, Wave-0 gap per 82-PATTERNS.md) additionally
# records the actual bytes printed -- each entry's bufref is captured at
# new() time and reflects the final content once the caller's print/close
# have run (the "scalar" PerlIO layer writes straight into the referenced
# scalar). $FAIL simulates a connect() failure (arm degrade-open tests).
#
# CR-05 (82-12, 82-REVIEW.md): @CALLS now records the FULL args hash (not
# just PeerPort) so tests can assert on the absence of `Timeout` and the
# presence of `Blocking => 0`. `syswrite` is a METHOD here (matching real
# IO::Socket::INET/IO::Handle, which provide `->syswrite` as a wrapper
# around the core builtin) -- Control's `_loopbackPost` calls it that way,
# which makes it directly stubbable without a CORE::GLOBAL override.
# @SYSWRITE_CALLS records each write's data; @SYSREAD_CALLS must stay
# empty (Fall B: _loopbackPost never reads a response -- narrowed by 84-17:
# true for every write-only caller; _postBoundaryRead reads by design, see
# the 84-17 block at the end of this file). $PARTIAL_WRITE, if
# set to a byte count, makes the next syswrite() return that count instead
# of the full length (Fall D: partial write).
write_stub($stub_dir, 'IO::Socket::INET', <<'END');
package IO::Socket::INET;
our @CALLS;
our @REQUESTS;
our @SYSWRITE_CALLS;
our @SYSREAD_CALLS;
our $FAIL = 0;
our $PARTIAL_WRITE;
sub new {
    my ($class, %args) = @_;
    push @CALLS, { %args };
    return undef if $FAIL;
    my $buf = '';
    open(my $fh, '>', \$buf) or return undef;
    push @REQUESTS, { PeerPort => $args{PeerPort}, bufref => \$buf };
    return bless $fh, $class;
}
# D-34 (79-48): POST /browse-keep?on=0|1 (the shim's browse flag) is its own
# channel. Every pre-existing assertion in this file counts /boundary and
# /seek-arm POSTs through @CALLS/@REQUESTS/@SYSWRITE_CALLS; the keep POST would
# shift all of those counts without being what they measure, so it is moved
# out of those lists into @KEEP_WRITES (data, in order) and $ON_KEEP_WRITE
# (a hook, run at the moment of the write, for ordering checks).
our @KEEP_WRITES;
our $ON_KEEP_WRITE;
# D-34 R2 (79-50): POST /seek-keep (the shim's decision-window keep for a
# daemon-originated reposition in Connect) is likewise its own channel: it is
# moved out of @CALLS/@REQUESTS/@SYSWRITE_CALLS into @SEEK_KEEP_WRITES so no
# pre-existing /boundary or /seek-arm count shifts.
our @SEEK_KEEP_WRITES;
sub syswrite {
    my $self = shift;
    my ($data) = @_;
    if ($data =~ m{^POST /seek-keep }) {
        pop @CALLS;
        pop @REQUESTS;
        push @SEEK_KEEP_WRITES, $data;
        print { $self } $data;
        return length($data);
    }
    if ($data =~ m{^POST /browse-keep\?}) {
        pop @CALLS;
        pop @REQUESTS;
        push @KEEP_WRITES, $data;
        $ON_KEEP_WRITE->($data) if $ON_KEEP_WRITE;
        print { $self } $data;
        return length($data);
    }
    push @SYSWRITE_CALLS, $data;
    # A real syswrite() bypasses PerlIO buffering and needs a genuine fd --
    # this stub's socket is scalar-backed (open($fh, '>', \$buf)) so a
    # literal CORE::syswrite() on it silently writes nothing. `print` uses
    # PerlIO and lands in the same @REQUESTS bufref the pre-existing
    # print-based tests already assert on -- this stub only needs to
    # capture what was "written" and how much, not exercise the real
    # syscall.
    if (defined $PARTIAL_WRITE) {
        my $n = $PARTIAL_WRITE;
        $PARTIAL_WRITE = undef;
        print { $self } substr($data, 0, $n);
        return $n;
    }
    print { $self } $data;
    return length($data);
}
# 84-17: `sysread` is a method too (matching IO::Handle). $READ_REPLY, if set,
# is what the NEXT sysread hands back (then EOF) -- how the 84-17 V-* cases
# script the audio shim's `POST /boundary` reply that _postBoundaryRead
# reads. @SYSREAD_CALLS still stays empty for every write-only caller
# (_loopbackPost, _armSync, the fire-and-forget _postBoundary callers; Fall B).
our $READ_REPLY;
sub sysread {
    my $self = shift;
    push @SYSREAD_CALLS, 1;
    if (defined $READ_REPLY) {
        my $r = $READ_REPLY;
        $READ_REPLY = undef;
        $_[0] = $r;
        return length($r);
    }
    $_[0] = '';
    return 0;
}
1;
END

# 79-53: the never-paired refusal asks Plugins::SpotOn::Soloist whether the
# player has a stored session. The real module does not load in this harness
# (the eval would return undef and the code would keep deferring, so gate B
# would be invisible), hence a stub. %FS maps mac => 0|1; a mac that is not
# in %FS answers undef (= unknown), so every older block keeps the old 20 s
# deferral. $BROKEN makes the call die (module unavailable).
write_stub($stub_dir, 'Plugins::SpotOn::Soloist', <<'END');
package Plugins::SpotOn::Soloist;
our %FS;
our $BROKEN = 0;
sub isPairedForClient {
    die "unavailable" if $BROKEN;
    return $FS{ $_[0] };
}
1;
END

# 79-53: the pairing hint is built with Slim::Utils::Strings::cstring. CI has
# no LMS tree (/usr/share/perl5/Slim), so without this stub the suite would
# pass here and die there.
write_stub($stub_dir, 'Slim::Utils::Strings', <<'END');
package Slim::Utils::Strings;
sub cstring { return "STR($_[1])"; }
1;
END

BEGIN {
    no warnings 'redefine';
    *main::INFOLOG  = sub () { 0 };
    *main::DEBUGLOG = sub () { 0 };
}

unshift @INC, $stub_dir, $project_dir;

require_ok('Slim::Player::Client')
    or BAIL_OUT("Failed to load the Slim::Player::Client stub");

require_ok('Slim::Player::Source')
    or BAIL_OUT("Failed to load the Slim::Player::Source stub");

require_ok('Slim::Player::Playlist')
    or BAIL_OUT("Failed to load the Slim::Player::Playlist stub");

# Force-load now (Control.pm only `require`s this lazily, inside
# _armAsync) so the module's own `our $AUTO_FIRE = 'ok';` default takes
# effect BEFORE any test does `local ... = 'ok'` -- localizing a package
# variable that has never been touched auto-vivifies it as undef and
# restores THAT (not the module's real default) once the local scope ends.
require_ok('Slim::Networking::SimpleAsyncHTTP')
    or BAIL_OUT("Failed to load the Slim::Networking::SimpleAsyncHTTP stub");

# 79-53: load the Soloist stub NOW, so its `our $BROKEN = 0` never runs after a
# test has set $BROKEN or %FS.
require_ok('Plugins::SpotOn::Soloist')
    or BAIL_OUT("Failed to load the Plugins::SpotOn::Soloist stub");

require_ok('Plugins::SpotOn::Soloist::Control')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Soloist::Control");

require JSON::PP;

# ------------------------------------------------------------------
# Test doubles
# ------------------------------------------------------------------

package Test::FakeDaemon;
sub new {
    my ($class, %args) = @_;
    return bless { %args }, $class;
}
sub mac         { return $_[0]->{mac}; }
sub _ws         { return $_[0]->{ws}; }
sub _streamPort { return $_[0]->{streamPort}; }
sub uptime      { return $_[0]->{uptime} // 100; }    # 82-05: CON-11 grace source

package Test::FakeWs;
sub new {
    my ($class, %args) = @_;
    return bless {
        connected    => ($args{connected} // 1),
        send_success => ($args{send_success} // 1),
        sent         => [],
        %args,
    }, $class;
}
sub sendCommand {
    my ($self, $cmd, %p) = @_;
    push @{ $self->{sent} }, [ $cmd, \%p ];
    return $self->{send_success};
}
sub sent { return $_[0]->{sent}; }

# Minimal Slim::Player::Playlist entry double (82-06, Task 1) -- Control's
# _prefetchNext only ever reads ->url off a playlist entry.
package Test::MockTrack;
sub new { my ($class, $url) = @_; return bless { url => $url }, $class; }
sub url { return $_[0]->{url}; }

# Minimal Slim::Player::Song double for CR-04 (82-10, Task 1) --
# _lmsSongIsOurs only ever reads ->track off the client's
# streamingSong/playingSong, then ->url off that track.
package Test::MockSong;
sub new   { my ($class, $track) = @_; return bless { track => $track }, $class; }
sub track { return $_[0]->{track}; }

package main;

# own_track($mac, $url) / foreign_track($mac, $url) -- CR-04 (82-10, Task
# 1) test helpers: set or clear the client's current-song ownership signal
# that _lmsSongIsOurs reads. no_track($mac) simulates neither
# streamingSong nor playingSong reporting a song at all (CR-04 Fall D).
sub own_track {
    my ($mac, $url) = @_;
    $url //= 'spoton://track:ownedTrack00000000000';
    Slim::Player::Client::getClient($mac)->streamingSong(Test::MockSong->new(Test::MockTrack->new($url)));
    Slim::Player::Client::getClient($mac)->playingSong(undef);
}

sub foreign_track {
    my ($mac, $url) = @_;
    $url //= 'file:///home/user/music/local-track.flac';
    Slim::Player::Client::getClient($mac)->streamingSong(Test::MockSong->new(Test::MockTrack->new($url)));
    Slim::Player::Client::getClient($mac)->playingSong(undef);
}

sub no_track {
    my ($mac) = @_;
    Slim::Player::Client::getClient($mac)->streamingSong(undef);
    Slim::Player::Client::getClient($mac)->playingSong(undef);
}

# fresh_control(%given) -- constructs a fresh Test::FakeDaemon + Test::FakeWs
# + Control instance. Returns ($ctl, $daemon, $ws): Control's `daemon`
# accessor is 'weak' (mirrors SoloistWS.pm CR-01) -- the CALLER must keep
# $daemon (and, transitively, $ws) alive in its own scope for the duration
# of the test, or Perl's refcounting collects it the instant this sub
# returns.
sub fresh_control {
    my (%given) = @_;

    my $ws = Test::FakeWs->new(
        connected    => ($given{ws_connected}  // 1),
        send_success => ($given{send_success}  // 1),
    );
    my $daemon = Test::FakeDaemon->new(
        mac        => ($given{mac} // 'aa:bb:cc:dd:ee:ff'),
        ws         => $ws,
        streamPort => ($given{streamPort} // 39755),
        uptime     => ($given{uptime} // 100),
    );

    my $ctl = Plugins::SpotOn::Soloist::Control->new(daemon => $daemon, mac => $daemon->mac);

    $ctl->mode($given{mode})         if defined $given{mode};
    $ctl->observed($given{observed}) if defined $given{observed};
    $ctl->pending($given{pending})   if defined $given{pending};
    $ctl->wanted($given{wanted})     if defined $given{wanted};

    return ($ctl, $daemon, $ws);
}

# load_fixture($name) -- t/32 convention: t/fixtures/soloist/$name. A
# ".json" file is a single raw wire frame (trimmed text). A ".jsonl" file
# is a time-ordered spike recording -- returns every non-"#"-comment line,
# in order.
sub load_fixture {
    my ($name) = @_;
    my $path = "$project_dir/t/fixtures/soloist/$name";
    open(my $fh, '<', $path) or die "fixture $name missing";
    binmode($fh);
    my @lines = <$fh>;
    close($fh);
    chomp @lines;
    # `.frames` = the same line-per-frame format, named so that t/47's *.jsonl
    # glob over "real archive material" does not pick it up (84-19 F-18-N4).
    if ($name =~ /\.(?:jsonl|frames)$/) {
        return grep { defined($_) && length($_) && $_ !~ /^#/ } @lines;
    }
    my $text = join('', @lines);
    $text =~ s/^\s+//;
    $text =~ s/\s+$//;
    return $text;
}

sub decode_frame {
    my ($text) = @_;
    return JSON::PP->new->utf8(1)->decode($text);
}

my $TID = 'spotify:track:11dFghVXANMlKmJXsNCbNl';    # track_changed.json's uri

# ============================================================
# tracer: getNextTrack(Y) with daemon on X playing -> arm + play Y;
# track_changed(Y) fixture -> successCb once, no boundary, no emission,
# observed.track=Y (the tracer assertion itself; the ProtocolHandler path
# through the same Control is exercised by t/29 in Task 2).
# ============================================================
{
    @IO::Socket::INET::CALLS                  = ();
    @IO::Socket::INET::REQUESTS               = ();
    @Slim::Networking::SimpleAsyncHTTP::CALLS = ();
    local $Slim::Networking::SimpleAsyncHTTP::AUTO_FIRE = 'ok';

    my ($ctl, $daemon, $ws) = fresh_control(
        observed => { wsConnected => 1, meta => { $TID => { duration => 200 } }, track => 'spotify:track:previousXYZ', status => 'playing' },
    );

    my ($success, $error_called);
    $ctl->requestTrack($TID, 0, { successCb => sub { $success++ }, errorCb => sub { $error_called = 1 } });

    # 82-19 F2: the async HTTP-client arm is gone -- every armed dispatch
    # now arms over the sync loopback socket, on BOTH call sites.
    is(scalar(@IO::Socket::INET::REQUESTS), 1, "tracer: one /seek-arm POST issued (daemon was playing a different track)");
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::CALLS), 0, "tracer: no async /seek-arm POST -- the async arm channel is gone (82-19 F2)");
    is_deeply($ws->sent, [ [ 'play', { uri => $TID } ] ], "tracer: exactly one play uri=Y sent");
    ok(!$success, "tracer: successCb not yet called before the echo arrives");

    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    is($success, 1, "tracer: successCb fires exactly once on the track_changed echo");
    ok(!$error_called, "tracer: errorCb not called");
    # 82-19 F2: a postSeek dispatch triggered by this same echo (RESEARCH
    # Kante 3, see onEvent) is now armed over the same IO::Socket::INET
    # channel as a genuine /boundary POST would be -- filter by the
    # recorded request body (bufref) rather than the raw connect count.
    is(scalar(grep { ${ $_->{bufref} } =~ m{^POST /boundary} } @IO::Socket::INET::REQUESTS), 0,
        "tracer: no /boundary POST on the echo of our own play");
    is_deeply(\@Slim::Player::Client::EXECUTED, [], "tracer: no spottyconnect emission in browse mode");
    is($ctl->observed->{track}, $TID, "tracer: observed.track updated to the echoed uri");
}

# ============================================================
# mismatch, daemon idle (observed.track undef) -> play Y without arm
# ============================================================
{
    @Slim::Networking::SimpleAsyncHTTP::CALLS = ();
    @IO::Socket::INET::REQUESTS               = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        observed => { wsConnected => 1, meta => {} },    # no track yet -- idle daemon
    );

    my $success;
    $ctl->requestTrack($TID, 0, { successCb => sub { $success++ } });

    is(scalar(@Slim::Networking::SimpleAsyncHTTP::CALLS), 0, "mismatch/idle: no /seek-arm POST -- nothing to flush yet");
    is(scalar(@IO::Socket::INET::REQUESTS), 0, "mismatch/idle: no sync /seek-arm POST either -- nothing to flush yet");
    is_deeply($ws->sent, [ [ 'play', { uri => $TID } ] ], "mismatch/idle: play uri=Y sent unarmed");
}

# ============================================================
# echo: track_changed(pending uri) -> successCb, boundary 0, emitted []
# ============================================================
{
    @IO::Socket::INET::CALLS    = ();
    @IO::Socket::INET::REQUESTS = ();

    my ($ctl, $daemon, $ws) = fresh_control(observed => { wsConnected => 1, meta => { $TID => { duration => 200 } } });

    my $success;
    $ctl->requestTrack($TID, 0, { successCb => sub { $success++ } });
    @Slim::Player::Client::EXECUTED = ();

    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    is($success, 1, "echo: successCb fires once");
    # 82-19 F2: the echo's own postSeek dispatch (position_ms 0, defined)
    # arms over the same socket a genuine /boundary POST would use --
    # filter by request body, not the raw connect count (see "tracer").
    is(scalar(grep { ${ $_->{bufref} } =~ m{^POST /boundary} } @IO::Socket::INET::REQUESTS), 0, "echo: boundary 0");
    is_deeply(\@Slim::Player::Client::EXECUTED, [], "echo: emitted []");
}

# ============================================================
# foreign track_changed in browse -> boundary 1, emitted [], observed.track
# updated
# ============================================================
{
    @IO::Socket::INET::CALLS = ();

    my ($ctl, $daemon, $ws) = fresh_control(mode => 'browse', observed => { wsConnected => 1, meta => {} });
    @Slim::Player::Client::EXECUTED = ();

    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    is(scalar(@IO::Socket::INET::CALLS), 1, "foreign track_changed: boundary 1 (not our own play)");
    is_deeply(\@Slim::Player::Client::EXECUTED, [], "foreign track_changed: emitted [] (Pitfall 8, browse mode)");
    is($ctl->observed->{track}, $TID, "foreign track_changed: observed.track updated");
}

# ============================================================
# idempotent: second requestTrack same uri while pending -> sent unchanged,
# both successCbs fire on echo
# ============================================================
{
    my ($ctl, $daemon, $ws) = fresh_control(observed => { wsConnected => 1, meta => { $TID => { duration => 200 } } });

    my ($success1, $success2) = (0, 0);
    $ctl->requestTrack($TID, 0, { successCb => sub { $success1++ } });
    is(scalar(@{ $ws->sent }), 1, "idempotent: first requestTrack sends exactly one play");

    $ctl->requestTrack($TID, 0, { successCb => sub { $success2++ } });
    is(scalar(@{ $ws->sent }), 1, "idempotent: second requestTrack for the SAME pending target sends nothing");

    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));
    is($success1, 1, "idempotent: first caller's successCb fires on the shared echo");
    is($success2, 1, "idempotent: second caller's successCb ALSO fires on the shared echo");
}

# ============================================================
# T1 timeout: no track_changed -> fire_timers(+0.6s) -> successCb once,
# warn logged
# ============================================================
{

    my ($ctl, $daemon, $ws) = fresh_control(observed => { wsConnected => 1, meta => {} });

    my $success;
    $ctl->requestTrack($TID, 0, { successCb => sub { $success++ } });
    ok(!$success, "T1 timeout: successCb not yet called before the timer fires");

    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 0.6);

    is($success, 1, "T1 timeout: successCb fires exactly once after 600ms with no echo");
    ok((grep { /no track_changed/ } @Slim::Utils::Log::WARNINGS), "T1 timeout: a warning was logged");
    is($ctl->pending, undef, "T1 timeout: pending cleared after release");
}

# ============================================================
# unpaired: error fixture after play -> errorCb PROBLEM_OPENING, recorded
# exactly one ('error','Soloist',qr/not paired/), second error -> still one
# ============================================================
{
    @Plugins::SpotOn::Status::RECORDED = ();

    my ($ctl, $daemon, $ws) = fresh_control(observed => { wsConnected => 1, meta => {} });

    my ($error_type, $error_msg);
    $ctl->requestTrack($TID, 0, { errorCb => sub { ($error_type, $error_msg) = @_; } });

    $ctl->onEvent(decode_frame(load_fixture('error.json')));

    is($error_type, 'PROBLEM_OPENING', "unpaired: errorCb fired with PROBLEM_OPENING");
    is($ctl->observed->{paired}, 0, "unpaired: observed.paired set to 0");
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 1, "unpaired: exactly one errors[] entry recorded");
    is($Plugins::SpotOn::Status::RECORDED[0][0], 'error', "unpaired: recorded level is 'error'");
    is($Plugins::SpotOn::Status::RECORDED[0][1], 'Soloist', "unpaired: recorded module is 'Soloist'");
    like($Plugins::SpotOn::Status::RECORDED[0][2], qr/not paired/, "unpaired: recorded message mentions 'not paired'");

    # A second, unsolicited error frame (no new pending) must NOT record a
    # second entry -- dedupe via errorsReported.
    $ctl->onEvent(decode_frame(load_fixture('error.json')));
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 1, "unpaired: a second error frame still records exactly one entry (dedupe)");
}

# ============================================================
# 82-11 Task 2, WR-05 Fall C: auth_state logged_in REMOVES the ring entry
# (not just the dedupe lock) -- a permanently-standing 'daemon not paired'
# is indistinguishable from a real (g)-finding (Todo
# errors-startup-falschmeldung-nicht-paired). This block used to assert
# the ring GREW to 2 entries after a fresh error following reset -- that
# was exactly the bug: the old entry never left. It must be gone before
# the fresh error adds its own, so the ring only ever holds 1.
# ============================================================
{
    @Plugins::SpotOn::Status::RECORDED = ();

    my ($ctl, $daemon, $ws) = fresh_control(observed => { wsConnected => 1, meta => {} });

    $ctl->requestTrack($TID, 0, { errorCb => sub { } });
    $ctl->onEvent(decode_frame(load_fixture('error.json')));
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 1, "WR-05: Fall C -- unpaired error recorded once before login");

    $ctl->onEvent(decode_frame(load_fixture('auth_state.json')));
    is($ctl->observed->{errorsReported}{unpaired}, 0, "WR-05: Fall C -- logged_in:true clears the unpaired dedupe bit");
    is($ctl->observed->{paired}, 1, "WR-05: Fall C -- logged_in:true sets observed.paired = 1");
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 0,
        "WR-05: Fall C -- logged_in:true removes the ring entry itself, not only the dedupe lock");

    # The clear takes effect: a fresh unpaired error can record again, and
    # the ring holds exactly that ONE entry -- the old one is gone.
    $ctl->requestTrack($TID, 0, { errorCb => sub { } });
    $ctl->onEvent(decode_frame(load_fixture('error.json')));
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 1,
        "WR-05: Fall C -- a later error records again, ring still holds exactly one entry");
}

# ============================================================
# 82-11 Task 2, CR-03 Fall A/B: UNPAIRED_GRACE_S suppresses the FIRST
# 'unpaired' ring entry while the daemon is still restoring its session
# after an LMS restart -- visibility only; observed.paired and the
# fail-fast path are unaffected either way.
# ============================================================

# --- CR-03: Fall A -- daemon younger than UNPAIRED_GRACE_S -- no ring entry ---
{
    @Plugins::SpotOn::Status::RECORDED = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:0d', uptime => 5, observed => { wsConnected => 1, meta => {} },
    );

    my $error_type;
    $ctl->requestTrack($TID, 0, { errorCb => sub { $error_type = $_[0]; } });
    $ctl->onEvent(decode_frame(load_fixture('error.json')));

    is($error_type, 'PROBLEM_OPENING', "CR-03: Fall A -- grace period -- errorCb still fires (fail-fast unaffected)");
    is($ctl->observed->{paired}, 0, "CR-03: Fall A -- grace period -- observed.paired still set to 0");
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 0, "CR-03: Fall A -- grace period suppresses the ring entry");
}

# --- CR-03: Fall B -- daemon past UNPAIRED_GRACE_S -- ring entry written ---
{
    @Plugins::SpotOn::Status::RECORDED = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:0e', uptime => 40, observed => { wsConnected => 1, meta => {} },
    );

    $ctl->requestTrack($TID, 0, { errorCb => sub { } });
    $ctl->onEvent(decode_frame(load_fixture('error.json')));

    is(scalar(@Plugins::SpotOn::Status::RECORDED), 1, "CR-03: Fall B -- past the grace period, exactly one ring entry");
}

# ============================================================
# 82-11 Task 2, WR-05 Fall D: clearing removes only the CALLING Control's
# own (mac-qualified) entry -- a foreign MAC's entry is untouched.
# ============================================================
{
    @Plugins::SpotOn::Status::RECORDED = ();
    Plugins::SpotOn::Status->recordError(
        'error', 'Soloist',
        'aa:bb:cc:dd:ee:ff: daemon not paired (command requires authentication)',
        'aa:bb:cc:dd:ee:ff:unpaired',
    );

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:10', uptime => 40, observed => { wsConnected => 1, meta => {} },
    );

    $ctl->requestTrack($TID, 0, { errorCb => sub { } });
    $ctl->onEvent(decode_frame(load_fixture('error.json')));
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 2, "WR-05: Fall D -- foreign entry plus own entry -- two total");

    $ctl->onEvent(decode_frame(load_fixture('auth_state.json')));
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 1, "WR-05: Fall D -- clearing removes only the own MAC's entry");
    is($Plugins::SpotOn::Status::RECORDED[0][3], 'aa:bb:cc:dd:ee:ff:unpaired',
        "WR-05: Fall D -- the foreign entry survives, still keyed to its own mac");
}

# ============================================================
# 82-11 Task 2, WR-05 Fall E: the drift ring entry clears through the same
# _clearErrorOnce path the echo already used to reset the dedupe bit --
# one clearing mechanism, not two.
# ============================================================
{
    @Plugins::SpotOn::Status::RECORDED = ();

    # Seed the exact post-drift-limit state directly (mac-qualified ring
    # entry + dedupe lock + a live pending 'play' for TID) rather than
    # re-deriving it through three requestTrack rounds: once
    # DRIFT_MAX_REDISPATCH is exceeded, Control never dispatches for this
    # uri again on its own (_driftCount only resets via the echo this test
    # exercises) -- so a genuine drift-limited state has no live pending to
    # echo against. This is the state the daemon's own eventual
    # track_changed for TID would meet in production.
    my ($ctl, $daemon, $ws) = fresh_control(
        observed => { wsConnected => 1, meta => {}, errorsReported => { 'drift:' . $TID => 1 } },
        pending  => { cmd => 'play', uri => $TID, cb => {} },
    );
    Plugins::SpotOn::Status->recordError('warn', 'Soloist', "does not follow $TID after 2 attempts",
        ($daemon->mac // '?') . ':drift:' . $TID);

    is(scalar(@Plugins::SpotOn::Status::RECORDED), 1, "WR-05: Fall E -- drift ring entry present before the echo");

    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));    # TID's own fixture -- echo
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 0,
        "WR-05: Fall E -- the echo clears the drift ring entry via the same _clearErrorOnce path");
}

# ============================================================
# position_sync fixture (nested) -> observed.anchor.position_ms == 31968,
# speed 1
# ============================================================
{
    my ($ctl, $daemon, $ws) = fresh_control(observed => { wsConnected => 1, meta => {} });

    $ctl->onEvent(decode_frame(load_fixture('position_sync.json')));

    is($ctl->observed->{anchor}{position_ms}, 31968, "position_sync fixture: observed.anchor.position_ms from the NESTED form");
    is($ctl->observed->{anchor}{speed}, 1, "position_sync fixture: observed.anchor.speed from the NESTED form");
}

# ============================================================
# transient paused during pending play -> no command, wanted.playing stays 1
# ============================================================
{
    my ($ctl, $daemon, $ws) = fresh_control(observed => { wsConnected => 1, meta => {} });

    $ctl->requestTrack($TID, 0, { successCb => sub { } });
    my $sentBefore = scalar(@{ $ws->sent });

    $ctl->onEvent(decode_frame(load_fixture('playback_changed.json')));    # {"status":"paused"}

    is(scalar(@{ $ws->sent }), $sentBefore, "transient paused: no new command sent while a play is pending");
    is($ctl->wanted->{playing}, 1, "transient paused: wanted.playing stays 1");
}

# ============================================================
# every fixture frame classified without die (all *.json + the five named
# jsonl spike recordings)
# ============================================================
{
    my ($ctl, $daemon, $ws) = fresh_control(observed => { wsConnected => 1, meta => {} });

    my @frames;
    for my $jsonFile (sort glob("$project_dir/t/fixtures/soloist/*.json")) {
        my ($name) = $jsonFile =~ m{([^/]+)$};
        push @frames, load_fixture($name);
    }
    for my $jsonl (qw(
        s01-pure-daemon-play.jsonl
        s01-lms-driven.jsonl
        s03-mismatch-play.jsonl
        s03-seek-order.jsonl
        s07-boundary.jsonl
    )) {
        push @frames, load_fixture($jsonl);
    }

    my $died = 0;
    for my $frameText (@frames) {
        my $decoded = eval { decode_frame($frameText) };
        next unless ref($decoded) eq 'HASH';
        eval { $ctl->onEvent($decoded); 1 } or do {
            $died++;
            diag("onEvent died on frame: $frameText -- $@");
        };
    }
    is($died, 0, "every fixture frame classified without die (" . scalar(@frames) . " frames)");
}

# ============================================================
# mode: requestTrack from idle -> browse; foreign track_changed in browse
# emits nothing
# ============================================================
{
    my ($ctl, $daemon, $ws) = fresh_control(observed => { wsConnected => 1, meta => { $TID => { duration => 200 } } });
    is($ctl->mode, 'idle', "mode: fresh Control starts idle");

    $ctl->requestTrack($TID, 0, { successCb => sub { } });
    is($ctl->mode, 'browse', "mode: requestTrack from idle transitions to browse");

    @Slim::Player::Client::EXECUTED = ();
    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));    # echo -- not "foreign" here
    is_deeply(\@Slim::Player::Client::EXECUTED, [], "mode: no emission at all while in browse");
}

# ============================================================
# Task 2 (82-01): drift, send-failure, arm-ordering and mode-policy
# edge cases.
# ============================================================

# --- drift limit: three requestTrack(Y) without echo -> third fires
# errorCb PROBLEM_OPENING and records exactly one ('warn','Soloist',
# qr/does not follow/) ---
{
    @Plugins::SpotOn::Status::RECORDED = ();
    # 82-23 WR-04 (direct consequence): _t1Fire now writes an errors[]
    # entry, which makes a long-dangling T1 timer left un-consumed by an
    # EARLIER, unrelated block in this shared-state file visible here for
    # the first time -- this fire_due() call sweeps ALL due timers
    # file-wide, not just this instance's own. $ctl is freshly minted
    # below and owns no timer yet, so clearing the whole queue here is
    # equivalent to filtering out only foreign entries and removes the
    # contamination without touching this test's own T1/T1-dedupe
    # behavior (same class of cross-contamination documented at the
    # R2-CR03 block near the end of this file).
    @Slim::Utils::Timers::TIMERS = ();

    my ($ctl, $daemon, $ws) = fresh_control(observed => { wsConnected => 1, meta => {} });

    my $error_type;
    for my $attempt (1 .. 3) {
        $error_type = undef;
        $ctl->requestTrack($TID, 0, { successCb => sub { }, errorCb => sub { $error_type = $_[0] } });
        Slim::Utils::Timers::fire_due(Time::HiRes::time() + 1) if $attempt < 3;
    }

    is($error_type, 'PROBLEM_OPENING', "drift limit: third attempt fires errorCb PROBLEM_OPENING");
    # 82-23 WR-04: attempt 1's T1 timeout (no echo ever arrives in this
    # test) now ALSO legitimately writes a t1:<uri> entry before the
    # drift:<uri> entry from attempt 3 -- two entries total, not one.
    # This is new, correct WR-04 behavior, not a regression: T1_TRACK_
    # CHANGED_MS (500ms) elapses before DRIFT_MAX_REDISPATCH is reached,
    # so the T1 entry is written first.
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 2,
        "drift limit: two errors[] entries recorded (t1 timeout, then drift limit)");
    is($Plugins::SpotOn::Status::RECORDED[0][0], 'warn', "drift limit: first entry level is 'warn'");
    is($Plugins::SpotOn::Status::RECORDED[0][1], 'Soloist', "drift limit: first entry module is 'Soloist'");
    like($Plugins::SpotOn::Status::RECORDED[0][2], qr/no track_changed within/,
        "drift limit: first entry is the T1 timeout (WR-04)");
    is($Plugins::SpotOn::Status::RECORDED[1][0], 'warn', "drift limit: second entry level is 'warn'");
    is($Plugins::SpotOn::Status::RECORDED[1][1], 'Soloist', "drift limit: second entry module is 'Soloist'");
    like($Plugins::SpotOn::Status::RECORDED[1][2], qr/does not follow/,
        "drift limit: second entry mentions 'does not follow' (the original drift-limit assertion)");
}

# --- drift reset: echo after two attempts clears counter -> next mismatch
# dispatches again ---
{
    my ($ctl, $daemon, $ws) = fresh_control(observed => { wsConnected => 1, meta => { $TID => { duration => 200 } } });

    $ctl->requestTrack($TID, 0, { successCb => sub { } });
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 1);
    $ctl->requestTrack($TID, 0, { successCb => sub { } });
    is($ctl->_driftCount->{$TID}, 2, "drift reset: two mismatch attempts recorded before the echo");

    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));    # TID's own fixture -- echo
    is($ctl->_driftCount->{$TID}, undef, "drift reset: echo clears the drift counter");

    # Simulate the daemon having wandered off again, then re-request the
    # SAME uri -- the counter must restart at 1 (dispatch, no error), not
    # resume from 2 (which would error immediately).
    $ctl->observed->{track} = 'spotify:track:somewhereElse0000';
    my $sentBefore = scalar(@{ $ws->sent });
    my $error_type;
    $ctl->requestTrack($TID, 0, { errorCb => sub { $error_type = $_[0] } });

    is($ctl->_driftCount->{$TID}, 1, "drift reset: counter restarts at 1 after the reset");
    is(scalar(@{ $ws->sent }), $sentBefore + 1, "drift reset: next mismatch dispatches again after the reset");
    ok(!$error_type, "drift reset: no error on the fresh single mismatch attempt");
}

# --- 84-21 D-24 F-20-LATCH: a NEW LMS play intent (requestTrack with
# source => 'getNextTrack') for a uri whose _driftCount is above
# DRIFT_MAX_REDISPATCH dispatches again (count restarts at 1, ws->sent +1,
# no PROBLEM_OPENING). Todo browse-drift-sperre-titel-bis-lms-neustart: the
# count was only cleared by a track_changed echo of that uri, so after one
# failed Browse start every later `playlist play` of the title failed within
# ~1 ms until LMS restarted. ---
{
    @Slim::Utils::Timers::TIMERS = ();
    @Plugins::SpotOn::Status::RECORDED = ();

    my ($ctl, $daemon, $ws) = fresh_control(observed => { wsConnected => 1, meta => {} });

    # intent 1: the getNextTrack half (count 1), T1 fires, then the onStream
    # half of the SAME intent (count 2) -- the limit is reached, not crossed
    $ctl->requestTrack($TID, 0, { source => 'getNextTrack', successCb => sub { } });
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 1);
    $ctl->observed->{expectEcho}{until} = Time::HiRes::time() - 1 if $ctl->observed->{expectEcho};    # 79-33 D-28 F2: close the late-echo window, the echo did not come
    $ctl->requestTrack($TID, 0, { source => 'onStream' });
    is($ctl->_driftCount->{$TID}, 2, "84-21 LATCH case 1: intent 1 leaves the drift count at the limit (2)");

    # intent 2: a NEW play intent for the same uri. In real life it arrives
    # long after intent 1's T1 window; without this fire_due the pending play
    # of the onStream half (< T1_TRACK_CHANGED_MS old) would swallow intent 2 in
    # _reconcile's idempotency join (Schritt 3) and the latch would never be
    # reached -- the case would read RED for the wrong reason.
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 3);
    my $sentBefore = scalar(@{ $ws->sent });
    my $err;
    $ctl->requestTrack($TID, 0, { source => 'getNextTrack', errorCb => sub { $err = $_[0] } });

    ok(!defined $err, "84-21 LATCH case 1: a new getNextTrack intent after the limit raises no PROBLEM_OPENING");
    is(scalar(@{ $ws->sent }), $sentBefore + 1, "84-21 LATCH case 1: the new intent dispatches again (ws->sent +1)");
    is($ctl->_driftCount->{$TID}, 1, "84-21 LATCH case 1: the drift count restarts at 1");
}

# --- 84-21 D-24 over-reset guard: a THIRD mismatch INSIDE one intent (the
# onStream half, source => 'onStream') still reaches PROBLEM_OPENING. A reset
# on every requestTrack -- the plausible wrong fix -- fails this case. ---
{
    @Slim::Utils::Timers::TIMERS = ();
    @Plugins::SpotOn::Status::RECORDED = ();

    my ($ctl, $daemon, $ws) = fresh_control(observed => { wsConnected => 1, meta => {} });

    $ctl->requestTrack($TID, 0, { source => 'getNextTrack', successCb => sub { } });
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 1);
    $ctl->observed->{expectEcho}{until} = Time::HiRes::time() - 1 if $ctl->observed->{expectEcho};    # 79-33 D-28 F2: close the late-echo window, the echo did not come
    $ctl->requestTrack($TID, 0, { source => 'onStream' });
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 2);
    my $err;
    $ctl->observed->{expectEcho}{until} = Time::HiRes::time() - 1 if $ctl->observed->{expectEcho};    # 79-33 D-28 F2: close the late-echo window, the echo did not come
    $ctl->requestTrack($TID, 0, { source => 'onStream', errorCb => sub { $err = $_[0] } });

    is($err, 'PROBLEM_OPENING', "84-21 LATCH case 2: a third mismatch inside one intent (onStream) still fires PROBLEM_OPENING");
    my @does = grep { ($_->[2] // '') =~ /does not follow/ } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@does), 1, "84-21 LATCH case 2: exactly one 'does not follow' errors[] entry");
}

# ============================================================
# 82-12 Task 2, WR-01 (82-REVIEW.md): a late track_changed echo -- arrived
# after T1 already released successCb and cleared `pending` -- is still
# recognized as OUR echo via `observed.expectEcho`, not run down the
# foreign-track path (which would plant a boundary on the freshly started
# own stream and leave the drift counter to accumulate toward
# DRIFT_MAX_REDISPATCH, making the title permanently unplayable after
# three such late-but-correct echoes).
# ============================================================

# --- WR-01: Fall A -- a late echo of the SAME uri is recognized: no
# boundary, drift counter cleared, observed.track set ---
{
    my ($ctl, $daemon, $ws) = fresh_control(observed => { wsConnected => 1, meta => {} });

    $ctl->requestTrack($TID, 0, { successCb => sub { } });
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 0.6);    # T1 fires -- pending released, expectEcho armed
    is($ctl->pending, undef, "WR-01: Fall A -- pending cleared by T1 before the late echo arrives");
    is($ctl->_driftCount->{$TID}, 1, "WR-01: Fall A -- drift counter at 1 from the original mismatch dispatch");

    @IO::Socket::INET::CALLS = ();
    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));    # late echo, same uri

    is(scalar(@IO::Socket::INET::CALLS), 0, "WR-01: Fall A -- late echo of the same uri plants no boundary");
    is($ctl->_driftCount->{$TID}, undef, "WR-01: Fall A -- late echo clears the drift counter for this uri");
    is($ctl->observed->{track}, $TID, "WR-01: Fall A -- observed.track is set from the late echo");
    is($ctl->observed->{expectEcho}, undef, "WR-01: Fall A -- the expectation is consumed, not left standing");
}

# --- WR-01: Fall B -- a genuine foreign track (different uri) after T1
# still takes the foreign-track path ---
{
    my ($ctl, $daemon, $ws) = fresh_control(observed => { wsConnected => 1, meta => {} });

    $ctl->requestTrack($TID, 0, { successCb => sub { } });
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 0.6);

    @IO::Socket::INET::CALLS = ();
    $ctl->onEvent({ type => 'track_changed', item => { uri => 'spotify:track:genuinelyForeign0000' } });

    is(scalar(@IO::Socket::INET::CALLS), 1, "WR-01: Fall B -- a genuinely different uri still plants a boundary");
    is($ctl->observed->{track}, 'spotify:track:genuinelyForeign0000',
        "WR-01: Fall B -- observed.track reflects the actual foreign uri, not the expected one");
}

# --- WR-01: Fall C -- the window expires: past LATE_ECHO_WINDOW_S, the
# same uri's echo is no longer treated as late-but-ours ---
{
    my ($ctl, $daemon, $ws) = fresh_control(observed => { wsConnected => 1, meta => {} });

    $ctl->requestTrack($TID, 0, { successCb => sub { } });
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 0.6);
    ok($ctl->observed->{expectEcho}, "WR-01: Fall C -- expectEcho is armed right after T1 fires");
    $ctl->observed->{expectEcho}{until} = Time::HiRes::time() - 1;    # simulate the window having elapsed

    @IO::Socket::INET::CALLS = ();
    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    is(scalar(@IO::Socket::INET::CALLS), 1,
        "WR-01: Fall C -- an expired window falls through to the foreign-track path (the window is bounded, not open-ended)");
}

# --- WR-01: Fall D -- three late-but-correct echoes in a row never
# escalate to errors[] or a permanent boundary; each fires successCb ---
{
    @Plugins::SpotOn::Status::RECORDED = ();
    @IO::Socket::INET::CALLS           = ();
    @IO::Socket::INET::REQUESTS        = ();

    my ($ctl, $daemon, $ws) = fresh_control(observed => { wsConnected => 1, meta => {} });

    for my $attempt (1 .. 3) {
        # Simulate the daemon having wandered off again before every
        # retry after the first (same technique as the pre-existing
        # "drift reset" test above) -- attempt 1 starts from a genuinely
        # idle daemon, 2/3 force the mismatch path again the way a real
        # late-but-correct daemon would look from Control's side.
        $ctl->observed->{track} = 'spotify:track:somewhereElse0000' if $attempt > 1;

        my $success;
        $ctl->requestTrack($TID, 0, { successCb => sub { $success++ } });
        Slim::Utils::Timers::fire_due(Time::HiRes::time() + 0.6);
        is($success, 1, "WR-01: Fall D -- attempt $attempt: successCb fires via T1's timeout");

        $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));    # the late echo for the same uri, right after
    }

    is(scalar(@Plugins::SpotOn::Status::RECORDED), 0,
        "WR-01: Fall D -- three late-but-correct echoes in a row record no errors[] entry (no permanent unplayability)");
    is($ctl->_driftCount->{$TID}, undef, "WR-01: Fall D -- drift counter stays clear after three late echoes");
    # 82-19 F2: attempts 2/3 re-dispatch on an already-defined observed.track
    # (mismatch path), so their own dispatch is armed over the same socket
    # a genuine /boundary POST would use -- filter by request body.
    is(scalar(grep { ${ $_->{bufref} } =~ m{^POST /boundary} } @IO::Socket::INET::REQUESTS), 0,
        "WR-01: Fall D -- no boundary planted across all three late echoes");
}

# --- WR-01: Fall E -- the Treffer-Zweig (a hit reached directly via
# _reconcile, not via the onEvent echo branch) also clears the drift
# counter -- WR-05 Fall E (82-11, above) already proved the echo path
# does; this is the SECOND path into "observed already matches wanted"
# (82-REVIEW.md WR-01, Schritt 5) ---
{
    @Plugins::SpotOn::Status::RECORDED = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'playing',
            errorsReported => { 'drift:' . $TID => 1 } },
    );
    $ctl->_driftCount->{$TID} = 2;
    Plugins::SpotOn::Status->recordError('warn', 'Soloist', "does not follow $TID after 2 attempts",
        ($daemon->mac // '?') . ':drift:' . $TID);

    is(scalar(@Plugins::SpotOn::Status::RECORDED), 1, "WR-01: Fall E -- drift ring entry present before the hit");

    my $success;
    $ctl->requestTrack($TID, 0, { successCb => sub { $success++ } });    # observed.track already == wanted uri -- Treffer-Zweig

    is($success, 1, "WR-01: Fall E -- Treffer-Zweig fires successCb");
    is($ctl->_driftCount->{$TID}, undef, "WR-01: Fall E -- Treffer-Zweig clears the drift counter");
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 0,
        "WR-01: Fall E -- Treffer-Zweig clears the drift ring entry too (_clearErrorOnce)");
}


# ============================================================
# 79-33 (D-28 F1/F2, LABELS-SKIP) -- RED cells, clock CONTROLLED
# (t/45 `local *Time::HiRes::time` convention, as R2-CR04 Fall H above):
# play sent at t0, T1 release and the synchronous onStream re-entry at
# t0+0.6 (past T1_TRACK_CHANGED_MS, so step 3's 0.5 s twin window is closed),
# the late echo at t0+0.711 (the 2026-10-22 incident, 79-R3-FORENSICS.md Part B).
# ============================================================
{
    my $t0 = Time::HiRes::time();
    my ($err, $succ, $pendingAtReentry) = (0, 0, 'unset');
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:79:33:00:00:01', observed => { wsConnected => 1, meta => {}, is_active => 1 });
    {
        no warnings 'redefine';
        local *Time::HiRes::time = sub { return $t0; };
        $ctl->requestTrack($TID, 0, {
            source    => 'getNextTrack',
            successCb => sub {
                $succ++;
                $pendingAtReentry = $ctl->pending;
                $ctl->requestTrack($TID, 0, { source => 'onStream', seek => 0 });
            },
            errorCb   => sub { $err++ },
        });
    }
    {
        no warnings 'redefine';
        local *Time::HiRes::time = sub { return $t0 + 0.6; };
        Slim::Utils::Timers::fire_due($t0 + 0.6);
    }
    my @plays = grep { $_->[0] eq 'play' } @{ $ws->sent };
    is($succ, 1, "79-33 D-28: the T1 release fires the successCb exactly once");
    is($err, 0, "79-33 D-28: a successCb that re-enters requestTrack(onStream) after T1 fires no errorCb (old code: superseded)");
    is(scalar(@plays), 1, "79-33 D-28: exactly one play on the wire for the released play and its onStream twin (old code: two)");
    ok(!defined $pendingAtReentry, "79-33 D-28: pending is already cleared when the successCb runs (F1: clear, then fire)");
}

# --- the same, late echo at t0+0.711; LMS's _NextIfMore is emulated in the
# errorCb (it requests the next title synchronously, as in the incident) ---
{
    my $t0 = Time::HiRes::time();
    my $TID2 = 'spotify:track:3wuCCNCnBhJlwkIJTBZFiv';
    my $err = 0;
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:79:33:00:00:02', observed => { wsConnected => 1, meta => {}, is_active => 1 });
    {
        no warnings 'redefine';
        local *Time::HiRes::time = sub { return $t0; };
        $ctl->requestTrack($TID, 0, {
            source    => 'getNextTrack',
            successCb => sub { $ctl->requestTrack($TID, 0, { source => 'onStream', seek => 0 }) },
            errorCb   => sub { $err++; $ctl->requestTrack($TID2, 0, { source => 'getNextTrack', successCb => sub { }, errorCb => sub { } }) },
        });
    }
    {
        no warnings 'redefine';
        local *Time::HiRes::time = sub { return $t0 + 0.6; };
        Slim::Utils::Timers::fire_due($t0 + 0.6);
    }
    @IO::Socket::INET::CALLS = ();
    my $before = scalar @{ $ws->sent };
    {
        no warnings 'redefine';
        local *Time::HiRes::time = sub { return $t0 + 0.711; };
        $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));
    }
    my @after = @{ $ws->sent }[$before .. $#{ $ws->sent }];
    is($err, 0, "79-33 D-28: late echo case -- no errorCb, so LMS never moves to the next title");
    is(scalar(grep { $_->[0] eq 'pause' } @after), 0, "79-33 D-28: the late echo at +0.711 s is own: no pause on the wire (old code: 'unrequested -- pausing')");
    is($ctl->observed->{track}, $TID, "79-33 D-28: observed.track is the released title after the late echo");
    is(scalar(@IO::Socket::INET::CALLS), 0, "79-33 D-28: the late echo plants no boundary");
}

# --- discriminator: the absorbing path is F2 (the late-echo window), not step 3.
# Same clock; the successCb removes observed.expectEcho before it re-enters, so
# only step 3 is left -- and step 3 cannot absorb (no pending after F1, window
# closed): the twin goes out as a second play on old and new code alike. ---
{
    my $t0 = Time::HiRes::time();
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:79:33:00:00:03', observed => { wsConnected => 1, meta => {}, is_active => 1 });
    {
        no warnings 'redefine';
        local *Time::HiRes::time = sub { return $t0; };
        $ctl->requestTrack($TID, 0, {
            source    => 'getNextTrack',
            successCb => sub { delete $ctl->observed->{expectEcho}; $ctl->requestTrack($TID, 0, { source => 'onStream', seek => 0 }) },
            errorCb   => sub { },
        });
    }
    {
        no warnings 'redefine';
        local *Time::HiRes::time = sub { return $t0 + 0.6; };
        Slim::Utils::Timers::fire_due($t0 + 0.6);
    }
    is(scalar(grep { $_->[0] eq 'play' } @{ $ws->sent }), 2,
        "79-33 D-28: control -- without the late-echo window the twin is NOT absorbed (two plays): F2, not step 3, decides the main cell");
}

# --- 79-33 D-28: seek re-entry and other-uri re-entry (clock controlled) ---
{
    my $t0 = Time::HiRes::time();
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:79:33:00:00:04', observed => { wsConnected => 1, meta => { $TID => { duration => 200 } }, is_active => 1 });
    { no warnings 'redefine'; local *Time::HiRes::time = sub { $t0 };
      $ctl->requestTrack($TID, 0, { source => 'getNextTrack', successCb => sub { $ctl->requestTrack($TID, 30000, { source => 'onStream', seek => 1 }) }, errorCb => sub { } }); }
    { no warnings 'redefine'; local *Time::HiRes::time = sub { $t0 + 0.6 }; Slim::Utils::Timers::fire_due($t0 + 0.6); }
    my @after = @{ $ws->sent }[1 .. $#{ $ws->sent }];
    ok(scalar(@after) >= 1, "79-33 D-28: a seek re-entry (seek => 1) after T1 is not absorbed: the seek path still sends");
}
{
    my $t0 = Time::HiRes::time();
    my $err = 0;
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:79:33:00:00:05', observed => { wsConnected => 1, meta => {}, is_active => 1 });
    { no warnings 'redefine'; local *Time::HiRes::time = sub { $t0 };
      $ctl->requestTrack($TID, 0, { source => 'getNextTrack', successCb => sub { $ctl->requestTrack('spotify:track:3wuCCNCnBhJlwkIJTBZFiv', 0, { source => 'onStream', seek => 0 }) }, errorCb => sub { $err++ } }); }
    { no warnings 'redefine'; local *Time::HiRes::time = sub { $t0 + 0.6 }; Slim::Utils::Timers::fire_due($t0 + 0.6); }
    is(scalar(grep { $_->[0] eq 'play' } @{ $ws->sent }), 2, "79-33 D-28: an onStream re-entry for a DIFFERENT uri is a genuine new play (not absorbed)");
    is($err, 0, "79-33 D-28: ... and the released play's errorCb never fires");
}

# --- send failure: FakeWs send_success=0 -> errorCb PROBLEM_OPENING
# 'Soloist daemon send failed', pending cleared, no T1 timer left ---
{
    my ($ctl, $daemon, $ws) = fresh_control(observed => { wsConnected => 1, meta => {} }, send_success => 0);

    my ($error_type, $error_msg);
    $ctl->requestTrack($TID, 0, { errorCb => sub { ($error_type, $error_msg) = @_; } });

    is($error_type, 'PROBLEM_OPENING', "send failure: errorCb fires PROBLEM_OPENING");
    is($error_msg, 'Soloist daemon send failed', "send failure: error message matches");
    is($ctl->pending, undef, "send failure: pending cleared");
    ok(!(grep { $_->[0] == $ctl } @Slim::Utils::Timers::TIMERS), "send failure: no T1 timer left running");
}

# --- arm ordering: daemon playing X, requestTrack(Y) -- 82-19 F2: the arm
# now runs over the sync loopback socket, so ordering is proven the same
# way "rewind" (below) proves it -- via the socket stub, not a deferred
# HTTP-client callback (that channel is gone) ---
{
    @IO::Socket::INET::REQUESTS = ();
    @IO::Socket::INET::CALLS    = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        observed => { wsConnected => 1, meta => {}, track => 'spotify:track:previousXYZ', status => 'playing' },
    );

    my $success;
    $ctl->requestTrack($TID, 0, { successCb => sub { $success++ } });

    is(scalar(@IO::Socket::INET::REQUESTS), 1, "arm ordering: exactly one sync seek-arm POST recorded");
    is_deeply($ws->sent, [ [ 'play', { uri => $TID } ] ],
        "arm ordering: play uri=Y sent (the sync arm above ran, synchronously, before this send)");
}

# --- arm degrade-open: socket connect fails -> warn, play still sent,
# successCb on echo (T-77-10) -- 82-19 F2: the failure mode moved from the
# HTTP-client stub's AUTO_FIRE=error to the socket stub's $FAIL ---
{
    @Slim::Utils::Log::WARNINGS = ();
    local $IO::Socket::INET::FAIL = 1;

    my ($ctl, $daemon, $ws) = fresh_control(
        observed => { wsConnected => 1, meta => { $TID => { duration => 200 } }, track => 'spotify:track:previousXYZ', status => 'playing' },
    );

    my $success;
    $ctl->requestTrack($TID, 0, { successCb => sub { $success++ } });

    ok((grep { /sync seek-arm failed/ } @Slim::Utils::Log::WARNINGS), "arm degrade-open: warning logged");
    is_deeply($ws->sent, [ [ 'play', { uri => $TID } ] ], "arm degrade-open: play still sent after the arm POST fails");

    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));
    is($success, 1, "arm degrade-open: successCb still fires on the echo (T-77-10)");
}

# --- no arm without observed.track (D-B / 77-REVIEWS HIGH) ---
{
    @Slim::Networking::SimpleAsyncHTTP::CALLS = ();
    @IO::Socket::INET::REQUESTS               = ();

    my ($ctl, $daemon, $ws) = fresh_control(observed => { wsConnected => 1, meta => {}, status => 'playing' });    # no track yet

    $ctl->requestTrack($TID, 0, { successCb => sub { } });

    is(scalar(@Slim::Networking::SimpleAsyncHTTP::CALLS), 0,
        "no arm without observed.track: no async /seek-arm POST even though status=playing");
    is(scalar(@IO::Socket::INET::REQUESTS), 0,
        "no arm without observed.track: no sync /seek-arm POST either even though status=playing");
}

# --- CR-01 Fall A: paused mit Abweichung -- observed.track eq uri, status
# paused, anchor 19431ms vs wanted 0 -> seek 0 BEFORE the bare-resume play
# (82-REVIEW.md CR-01: a bare `play` alone resumes at the stale anchor
# position -- live reproduced at 19431/81235/200708ms). Time::HiRes::time()
# as seen_at keeps the elapsed time in this test practically zero, so
# _observedPositionMs reports the anchor value itself. ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        observed => {
            wsConnected => 1, meta => {}, track => $TID, status => 'paused',
            anchor => { position_ms => 19431, seen_at => Time::HiRes::time() },
        },
    );

    my $success;
    $ctl->requestTrack($TID, 0, { successCb => sub { $success++ } });

    is_deeply($ws->sent, [ [ 'seek', { position_ms => 0 } ], [ 'play', {} ] ],
        "CR-01: paused with a stale anchor (19431ms) -- seek 0 sent before the bare-resume play");
    is($success, 1, "CR-01: paused with a stale anchor -- successCb fires once");
}

# --- CR-01 Fall B: playing mit Abweichung -- anchor 81235ms vs wanted 0 ->
# seek 0 ONLY, no play (the daemon already reports playing -- a bare play
# here would be a no-op resume that never touches position_ms). ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        observed => {
            wsConnected => 1, meta => {}, track => $TID, status => 'playing',
            anchor => { position_ms => 81235, seen_at => Time::HiRes::time() },
        },
    );

    my $success;
    $ctl->requestTrack($TID, 0, { successCb => sub { $success++ } });

    is_deeply($ws->sent, [ [ 'seek', { position_ms => 0 } ] ],
        "CR-01: playing with a stale anchor (81235ms) -- seek 0 only, no bare play (already playing)");
    is($success, 1, "CR-01: playing with a stale anchor -- successCb fires once");
}

# --- CR-01 Fall C: innerhalb der Toleranz -- anchor 200ms vs wanted 0 ->
# bare play only, no seek (200ms < HIT_POSITION_TOLERANCE_MS -- a seek here
# would cost more than the drift it corrects). ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        observed => {
            wsConnected => 1, meta => {}, track => $TID, status => 'paused',
            anchor => { position_ms => 200, seen_at => Time::HiRes::time() },
        },
    );

    my $success;
    $ctl->requestTrack($TID, 0, { successCb => sub { $success++ } });

    is_deeply($ws->sent, [ [ 'play', {} ] ],
        "CR-01: paused with anchor within tolerance (200ms) -- bare play only, no seek");
    is($success, 1, "CR-01: paused within tolerance -- successCb fires once");
}

# --- CR-01 Fall D: Mismatch mit Ziel 0 -- play uri sent immediately, then
# after the track_changed echo confirms the uri, exactly one seek 0 follows
# (82-REVIEW.md CR-01, Absatz Ergaenzend: postSeek is no longer suppressed
# for position_ms == 0 -- a `play uri` on the current session title behaves
# like a resume at the daemon, so 0 is the most important case, not a
# special-cased no-op). ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        observed => { wsConnected => 1, meta => { $TID => { duration => 200 } }, track => 'spotify:track:previousXYZ', status => 'playing' },
    );

    my $success;
    $ctl->requestTrack($TID, 0, { source => 'getNextTrack', successCb => sub { $success++ } });

    is_deeply($ws->sent, [ [ 'play', { uri => $TID } ] ],
        "CR-01: mismatch target 0 -- play uri sent (position_ms is never on the wire for play)");

    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    is_deeply($ws->sent, [ [ 'play', { uri => $TID } ], [ 'seek', { position_ms => 0 } ] ],
        "CR-01: mismatch target 0 -- postSeek fires seek 0 after the echo confirms the uri");
    is($success, 1, "CR-01: mismatch target 0 -- successCb still fires once");
}

# --- prefetch hit: observed.track eq uri, status playing -> nothing sent,
# successCb immediately. Carries an explicit anchor (WR-01, 82-31) so this
# stays the byte-identical genuine-prefetch-hit case on both codestates --
# the defined-arm decides it, unaffected by the removed !$playing exception. ---
{
    my ($ctl, $daemon, $ws) = fresh_control(observed => { wsConnected => 1, meta => {}, track => $TID, status => 'playing', anchor => { position_ms => 0, seen_at => Time::HiRes::time() } });

    my $success;
    $ctl->requestTrack($TID, 0, { successCb => sub { $success++ } });

    is_deeply($ws->sent, [], "prefetch hit: nothing sent");
    is($success, 1, "prefetch hit: successCb fires immediately");
}

# --- CR-01 Fall E (82-30, T-3): Treffer mit UNBEKANNTER Position (kein
# observed.anchor), status paused, mode browse -- needsSeek muss jetzt
# feuern: seek 0 VOR dem bare-resume play, genau wie beim bekannten Drift
# oben, weil eine unbekannte Position nicht als "bereits korrekt" behandelt
# werden darf (browse-play-startet-nicht-bei-position-0.md). Muss-Fehlschlag
# (RED) gegen den ungefixten Baum: $ws->sent enthielt nur [ [ 'play', {} ] ]
# -- woertlich im SUMMARY zitiert. Label "CR-01 Fall E" bewusst auf
# DERSELBEN Zeile wie die oeffnende Klammer (PLAN-CHECK-KORREKTUR Runde 1),
# nicht als Folgezeile wie beim Fall-A-D-Vorbild -- das zeilenbasierte
# Fall-Tor sieht sonst nur $success, nicht den eigentlichen Diskriminator. ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'paused' },    # bewusst KEIN anchor
    );

    my $success;
    $ctl->requestTrack($TID, 0, { successCb => sub { $success++ } });

    is_deeply($ws->sent, [ [ 'seek', { position_ms => 0 } ], [ 'play', {} ] ], "CR-01 Fall E: seek 0 before the bare-resume play when position is unknown");
    is($success, 1, "CR-01 Fall E: successCb fires once");
}

# --- CR-01 Fall F (82-30 -> 82-31, WR-01): dieser Kunstzustand
# (status=playing, KEIN observed.anchor) ist jetzt der Diskriminator fuer
# den playing-Zwilling (Nutzerentscheidung 2026-09-12, STATE.md :352:
# "Fall F wird dadurch vom Waechter zum Diskriminator des playing-
# Zwillings"). Die Fixture bleibt UNVERAENDERT -- track_changed schreibt
# observed.anchor nie, ein echter Prefetch-Hit traegt daher IMMER den
# Anchor des vorherigen Titels (siehe Fixture oben) und wird vom
# defined-Arm entschieden; dieser Kunstzustand war in Produktion nur ueber
# eine frische/neu verbundene Control ohne erstes Positionsframe fuer den
# aktuellen Titel erreichbar -- genau der playing-Zwilling des 82-30-Fixes,
# der bislang unkorrigiert blieb. Nur die ERWARTUNG aendert sich: seit
# 82-31 feuert hier ein erzwungener seek 0. Keine Redundanz mehr mit dem
# Block "prefetch hit" oben (t/44:1236-1245) -- der traegt jetzt einen
# Anchor und bleibt []; dieser bleibt ohne Anchor und wird [seek(0)]. ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'playing' },    # bewusst KEIN anchor -- der Diskriminator
    );

    my $success;
    $ctl->requestTrack($TID, 0, { successCb => sub { $success++ } });

    is_deeply($ws->sent, [ [ 'seek', { position_ms => 0 } ] ], "CR-01 Fall F: seek 0 fires for the playing-twin now that the position is genuinely unknown (WR-01, 82-31)");
    is($success, 1, "CR-01 Fall F: successCb fires once");
}

# --- CR-01 Fall G (82-30, Connect-Abgrenzung, 82-24): mode=connect bleibt
# von der neuen needsSeek-Korrektur vollstaendig ausgenommen -- das in 82-24
# CR-04 bewusst entfernte seek 0 im Connect-Transferfenster bleibt entfernt,
# obwohl observed.track eq wanted.uri UND kein anchor vorliegen -- exakt die
# Konstellation, die in browse/idle jetzt korrigiert wird (Fall E). Beleg
# der harten Abgrenzung: mode=connect bleibt unangetastet. Bestand bereits
# VOR der Aenderung und MUSS danach byte-identisch bestehen. ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mode => 'connect',
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'paused' },    # KEIN anchor
    );

    my $success;
    # 84.2-05: origin => 'connect' -- this case models Connect's OWN re-open in the
    # transfer window (producer P1) on a paused daemon; without the marker the
    # two-signal same-uri rule would classify the shape as an LMS user play (P12).
    $ctl->requestTrack($TID, 0, { source => 'getNextTrack', origin => 'connect', successCb => sub { $success++ } });

    is_deeply($ws->sent, [ [ 'play', {} ] ], "CR-01 Fall G: connect mode is exempt -- bare play only, no forced seek");
    is($success, 1, "CR-01 Fall G: successCb fires once");
}

# --- emission policy: mode browse + volume_changed (foreign, no pending,
# past grace) -> observed.volume set AND emitted (82-05, Task 6/D-06:
# volume is the one thing mode=browse DOES emit -- Mode-Policy from 82-01
# already allowed it, this plan wires the caller) ---
{
    my ($ctl, $daemon, $ws) = fresh_control(mode => 'browse', observed => { wsConnected => 1, meta => {} });
    @Slim::Player::Client::EXECUTED = ();

    $ctl->onEvent(decode_frame(load_fixture('volume_changed.json')));

    is($ctl->observed->{volume}, 100, "emission policy: observed.volume set from volume_changed");
    is_deeply(\@Slim::Player::Client::EXECUTED, [ [ 'spottyconnect', 'volume', 100, '' ] ],
        "emission policy: mode=browse DOES emit volume (82-05, D-06) -- the only cmd its Mode-Policy allows");
}

# --- for_client: registry by mac, master normalisation, undef for
# unknown mac ---
{
    package Test::FakeClientNoMaster;
    sub new { return bless { id => $_[1] }, $_[0]; }
    sub can { return 0; }
    sub id  { return $_[0]->{id}; }

    package Test::FakeClientWithMaster;
    sub new    { return bless { id => $_[1], master => $_[2] }, $_[0]; }
    sub can    { my ($self, $m) = @_; return $m eq 'master' ? 1 : 0; }
    sub master { return $_[0]->{master}; }

    package main;

    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:11:aa:11:aa:11', observed => { wsConnected => 1, meta => {} });

    is(Plugins::SpotOn::Soloist::Control->for_client('aa:11:aa:11:aa:11'), $ctl,
        "for_client: lookup by bare mac string");

    my $plainClient = Test::FakeClientNoMaster->new('aa:11:aa:11:aa:11');
    is(Plugins::SpotOn::Soloist::Control->for_client($plainClient), $ctl,
        "for_client: lookup by client object without master()");

    my $masterClient = Test::FakeClientNoMaster->new('aa:11:aa:11:aa:11');
    my $slaveClient  = Test::FakeClientWithMaster->new('bb:22:bb:22:bb:22', $masterClient);
    is(Plugins::SpotOn::Soloist::Control->for_client($slaveClient), $ctl,
        "for_client: normalizes to the sync master before lookup");

    is(Plugins::SpotOn::Soloist::Control->for_client('zz:99:zz:99:zz:99'), undef,
        "for_client: undef for an unregistered mac");
}

# --- shutdown: pending errorCb fired, registry entry gone, no timers left ---
{
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'cc:33:cc:33:cc:33', observed => { wsConnected => 1, meta => {} });

    my ($error_type, $error_msg);
    $ctl->requestTrack($TID, 0, { errorCb => sub { ($error_type, $error_msg) = @_; } });
    ok(defined $ctl->pending, "shutdown: pending exists before shutdown");

    $ctl->shutdown;

    is($error_type, 'PROBLEM_OPENING', "shutdown: pending errorCb fired with PROBLEM_OPENING");
    is($error_msg, 'Soloist control shut down', "shutdown: error message matches");
    is($ctl->pending, undef, "shutdown: pending cleared");
    is(Plugins::SpotOn::Soloist::Control->for_client('cc:33:cc:33:cc:33'), undef,
        "shutdown: registry entry removed");
    ok(!(grep { $_->[0] == $ctl } @Slim::Utils::Timers::TIMERS), "shutdown: no timers left for this instance");
}

# ============================================================
# Task 1 (82-04): seek/rewind marker, synchronous arm, T_meta-bounded
# successCb, stream generation. See 82-RESEARCH.md Befund 1-3.
# ============================================================

my $Y_URI = 'spotify:track:yyyyyyyyyyyyyyyyyyyy';
my $Z_URI = 'spotify:track:zzzzzzzzzzzzzzzzzzzz';

# --- marker: consumeSeekIntent within TTL returns target and clears ---
{
    my ($ctl, $daemon, $ws) = fresh_control(observed => { wsConnected => 1, meta => {} });

    $ctl->noteSeekIntent($TID, 5000);
    is($ctl->consumeSeekIntent($TID), 5000, "marker: consumeSeekIntent within TTL returns target and clears");
    is($ctl->wanted->{seekIntent}, undef, "marker: consumeSeekIntent within TTL clears the marker after reading it");
}

# --- marker: expired (ts - 3s) returns undef ---
{
    my ($ctl, $daemon, $ws) = fresh_control(observed => { wsConnected => 1, meta => {} });

    $ctl->noteSeekIntent($TID, 5000);
    $ctl->wanted->{seekIntent}{ts} -= 3;    # SEEK_INTENT_TTL is 2s

    is($ctl->consumeSeekIntent($TID), undef, "marker: expired (ts - 3s) returns undef");
    is($ctl->wanted->{seekIntent}, undef, "marker: expired marker is cleared too (delete-on-read is unconditional)");
}

# --- marker: uri mismatch returns undef and clears ---
{
    my ($ctl, $daemon, $ws) = fresh_control(observed => { wsConnected => 1, meta => {} });

    $ctl->noteSeekIntent($TID, 0);
    is($ctl->consumeSeekIntent($Y_URI), undef, "marker: uri mismatch returns undef and clears");
    is($ctl->wanted->{seekIntent}, undef, "marker: uri mismatch -- the (now irrelevant) marker was still consumed/cleared");
}

# --- marker: UPnP probe -- noteSeekIntent(X,0) then requestTrack(Y) from
# getNextTrack -> marker cleared, no seek sent ---
{
    my ($ctl, $daemon, $ws) = fresh_control(observed => { wsConnected => 1, meta => {} });

    $ctl->noteSeekIntent($TID, 0);    # UPnP MediaRenderer capability probe -- no restart follows
    $ctl->requestTrack($Y_URI, 0, { source => 'getNextTrack', successCb => sub { } });

    is_deeply($ws->sent, [ [ 'play', { uri => $Y_URI } ] ],
        "marker: UPnP probe -- noteSeekIntent(X,0) then requestTrack(Y) from getNextTrack -- Y plays from 0, no seek sent");
    is($ctl->wanted->{seekIntent}, undef, "marker: UPnP probe -- marker cleared on the foreign-uri requestTrack");
}

# --- marker: _JumpPaused -- noteSeekIntent(X,0), fire_timers(+3s),
# onStream-style requestTrack(X, undef) -> no seek, plain idempotent.
# Carries an explicit anchor (WR-01, 82-31) so removing the !$playing
# needsSeek exception does not turn this into an unrelated seek-0 case --
# this fixture's purpose is marker clearing, not the playing-twin. ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'playing', anchor => { position_ms => 0, seen_at => Time::HiRes::time() } },
    );

    $ctl->noteSeekIntent($TID, 0);
    $ctl->wanted->{seekIntent}{ts} -= 3;    # past TTL by the time unpause reaches onStream

    my $consumed = $ctl->consumeSeekIntent($TID);
    ok(!defined $consumed, "marker: _JumpPaused -- expired marker returns undef to the onStream-style consumer");

    $ctl->requestTrack($TID, 0, { source => 'onStream', seek => 0, successCb => sub { } });
    is_deeply($ws->sent, [], "marker: _JumpPaused -- plain idempotent requestTrack sends nothing (daemon already on X)");
}

# --- marker: open failure -- noteSeekIntent(X,0) then requestTrack(Y) ->
# Y plays from 0 ---
{
    my ($ctl, $daemon, $ws) = fresh_control(observed => { wsConnected => 1, meta => {} });

    $ctl->noteSeekIntent($TID, 0);    # canDoAction fired, but Song::open then failed -- no onStream ever ran
    $ctl->requestTrack($Z_URI, 0, { source => 'getNextTrack', successCb => sub { } });

    is_deeply($ws->sent, [ [ 'play', { uri => $Z_URI } ] ], "marker: open failure -- Y plays from 0, no leaked seek");
    is($ctl->wanted->{seekIntent}, undef, "marker: open failure -- the X marker is explicitly cleared on the foreign-uri requestTrack");
}

# --- marker: _Continue -- noteSeekIntent(X, 42000) then
# requestTrack(X, 42000, seek) -> seek 42000 + play ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'playing' },
    );

    $ctl->noteSeekIntent($TID, 42000);
    my $consumed = $ctl->consumeSeekIntent($TID);
    is($consumed, 42000, "marker: _Continue -- consumeSeekIntent returns the reconnect target");

    $ctl->requestTrack($TID, $consumed, { source => 'onStream', seek => 1 });
    is_deeply($ws->sent, [ [ 'seek', { position_ms => 42000 } ], [ 'play', {} ] ],
        "marker: _Continue -- noteSeekIntent(X, 42000) then requestTrack(X, 42000, seek) -- seek 42000 + play");
}

# --- rewind: daemon playing X, requestTrack(X, 0, seek, onStream) -> sync
# arm recorded, then ['seek',{position_ms=>0}], ['play',{}] ---
{
    @IO::Socket::INET::REQUESTS = ();
    @IO::Socket::INET::CALLS    = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'playing' },
    );

    $ctl->requestTrack($TID, 0, { source => 'onStream', seek => 1 });

    is(scalar(@IO::Socket::INET::REQUESTS), 1,
        "rewind: daemon playing X, requestTrack(X, 0, seek, onStream) -- exactly one sync seek-arm POST recorded");
    like(${ $IO::Socket::INET::REQUESTS[0]{bufref} }, qr{^POST /seek-arm},
        "rewind: daemon playing X -- the recorded request is POST /seek-arm");
    is_deeply($ws->sent, [ [ 'seek', { position_ms => 0 } ], [ 'play', {} ] ],
        "rewind: daemon playing X, requestTrack(X, 0, seek, onStream) -- seek 0 then play "
        . "(the sync arm above ran, synchronously, before this send)");
}

# --- seek N: requestTrack(X, 30000, seek, onStream) -> arm + seek 30000 +
# play, wanted.position_ms 30000 ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'playing' },
    );

    $ctl->requestTrack($TID, 30000, { source => 'onStream', seek => 1 });

    is_deeply($ws->sent, [ [ 'seek', { position_ms => 30000 } ], [ 'play', {} ] ],
        "seek N: requestTrack(X, 30000, seek, onStream) -- arm + seek 30000 + play");
    is($ctl->wanted->{position_ms}, 30000, "seek N: wanted.position_ms updated to 30000");
}

# --- G4-FIX: Fall A -- seek while paused (82-G4-MESSUNG.md H-S3
# bestaetigt, n=3, L1-L3: observed.status=paused, gemessen -- ein
# position_sync speed=0-Frame binnen 1 ms nach jedem playlist play schreibt
# 'paused', kein track_changed-Echo korrigiert es vor dem Seek). Seek-Pfad
# (2)'s Armierung folgt jetzt derselben H-vi-Regel wie Schritt 4/5 und der
# postSeek (defined observed.track, nicht der Status) -- VOR dem Fix war
# dies der Altstand ("seek while paused: observed.status paused -> no
# arm"), live reproduziert: kein Arm, der frisch angehaengte Stream-Client
# starb binnen 13-55 ms (flush-disconnect). ---
{
    @IO::Socket::INET::REQUESTS = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'paused' },
    );

    $ctl->requestTrack($TID, 90000, { source => 'onStream', seek => 1 });

    is(scalar(@IO::Socket::INET::REQUESTS), 1,
        "G4-FIX: Fall A -- seek while paused now arms (H-vi in Seek-Pfad (2), 82-G4-MESSUNG H-S3)");
    like(${ $IO::Socket::INET::REQUESTS[0]{bufref} }, qr{^POST /seek-arm},
        "G4-FIX: Fall A -- the recorded request is POST /seek-arm");
    is_deeply($ws->sent, [ [ 'seek', { position_ms => 90000 } ], [ 'play', {} ] ],
        "G4-FIX: Fall A -- seek + play still sent");
}

# --- G4-FIX: Fall B -- seek with observed.status undef -> also arms now
# (H-vi: armed follows defined(observed.track), independent of status;
# undef becomes '' at Seek-Pfad (2)'s status normalization, which is
# outside {playing,buffering} either way). ---
{
    @IO::Socket::INET::REQUESTS = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        observed => { wsConnected => 1, meta => {}, track => $TID, status => undef },
    );

    $ctl->requestTrack($TID, 90000, { source => 'onStream', seek => 1 });

    is(scalar(@IO::Socket::INET::REQUESTS), 1,
        "G4-FIX: Fall B -- seek with observed.status undef now arms (H-vi)");
    is_deeply($ws->sent, [ [ 'seek', { position_ms => 90000 } ], [ 'play', {} ] ],
        "G4-FIX: Fall B -- seek + play still sent");
}

# --- G4-FIX: Fall C -- seek with observed.status buffering -> still arms
# (regression guard: this case already armed before the fix and must keep
# arming after it -- unchanged behavior, not a new case). ---
{
    @IO::Socket::INET::REQUESTS = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'buffering' },
    );

    $ctl->requestTrack($TID, 90000, { source => 'onStream', seek => 1 });

    is(scalar(@IO::Socket::INET::REQUESTS), 1,
        "G4-FIX: Fall C -- seek with observed.status buffering still arms (regression guard, unchanged)");
    is_deeply($ws->sent, [ [ 'seek', { position_ms => 90000 } ], [ 'play', {} ] ],
        "G4-FIX: Fall C -- seek + play still sent");
}

# --- G4-FIX: Fall D -- observed.track undef (falls through Seek-Pfad (2)
# to Schritt 5's Mismatch-Pfad) -- no sync arm, play carries uri and
# postSeek instead (regression guard: this branch is untouched by the
# Seek-Pfad (2) fix, since observed.track eq uri is false either way). ---
{
    @IO::Socket::INET::REQUESTS = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        observed => { wsConnected => 1, meta => {}, track => undef, status => 'paused' },
    );

    $ctl->requestTrack($TID, 90000, { source => 'onStream', seek => 1 });

    is(scalar(@IO::Socket::INET::REQUESTS), 0,
        "G4-FIX: Fall D -- Mismatch-Pfad (observed.track undef) sends no sync arm, untouched by the fix");
    ok((scalar grep { $_->[0] eq 'play' && exists $_->[1]{uri} && $_->[1]{uri} eq $TID } @{ $ws->sent }),
        "G4-FIX: Fall D -- play carries uri (Mismatch-Pfad, unchanged)");
}

# --- seek during pending play same uri (getNextTrack+onStream with
# seekdata): requestTrack(X,30000,getNextTrack) then
# requestTrack(X,30000,onStream,seek) -> one play, no seek yet, postSeek
# 30000; echo track_changed(X) -> exactly one seek 30000, successCb once ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        observed => { wsConnected => 1, meta => { $TID => { duration => 200 } } },
    );

    my $success;
    $ctl->requestTrack($TID, 30000, { source => 'getNextTrack', successCb => sub { $success++ } });
    $ctl->requestTrack($TID, 30000, { source => 'onStream', seek => 1 });

    is(scalar(grep { $_->[0] eq 'play' } @{ $ws->sent }), 1,
        "seek during pending play same uri: exactly one play across the whole sent list");
    is(scalar(grep { $_->[0] eq 'seek' } @{ $ws->sent }), 0,
        "seek during pending play same uri: no seek yet -- the daemon is still on the old title");
    is($ctl->pending->{postSeek}, 30000, "seek during pending play same uri: postSeek recorded on the open pending play");

    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    is(scalar(grep { $_->[0] eq 'seek' } @{ $ws->sent }), 1,
        "seek during pending play same uri: echo track_changed(X) -> exactly one seek 30000 across the whole sent list");
    is($success, 1, "seek during pending play same uri: successCb fires once");
}

# --- rewind during pending play: requestTrack(X,0,onStream,seek) with
# pending play X -> no second play, no immediate seek, postSeek 0;
# echo -> seek 0 ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        observed => { wsConnected => 1, meta => { $TID => { duration => 200 } } },
    );

    $ctl->requestTrack($TID, 0, { source => 'getNextTrack', successCb => sub { } });
    $ctl->requestTrack($TID, 0, { source => 'onStream', seek => 1 });

    is(scalar(grep { $_->[0] eq 'play' } @{ $ws->sent }), 1, "rewind during pending play: exactly one play, no second play");
    is(scalar(grep { $_->[0] eq 'seek' } @{ $ws->sent }), 0, "rewind during pending play: no immediate seek");
    is($ctl->pending->{postSeek}, 0, "rewind during pending play: postSeek recorded as 0");

    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    is_deeply([ grep { $_->[0] eq 'seek' } @{ $ws->sent } ], [ [ 'seek', { position_ms => 0 } ] ],
        "rewind during pending play: echo -- exactly one seek 0");
}

# --- postSeek dropped on T1 timeout: pending play X with postSeek 30000,
# fire_timers(+0.6s) -> no seek sent, warn names 30000 ---
{
    @Slim::Utils::Log::WARNINGS = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        observed => { wsConnected => 1, meta => { $TID => { duration => 200 } } },
    );

    $ctl->requestTrack($TID, 30000, { source => 'getNextTrack', successCb => sub { } });
    is($ctl->pending->{postSeek}, 30000, "postSeek dropped on T1 timeout: postSeek recorded before the timeout");

    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 0.6);

    is(scalar(grep { $_->[0] eq 'seek' } @{ $ws->sent }), 0,
        "postSeek dropped on T1 timeout: no seek sent -- the title was never confirmed");
    ok((grep { /dropping postSeek 30000/ } @Slim::Utils::Log::WARNINGS),
        "postSeek dropped on T1 timeout: warn names 30000");
    is($ctl->pending, undef, "postSeek dropped on T1 timeout: pending cleared");
}

# --- mismatch with position: requestTrack(X,30000,getNextTrack) alone ->
# one play, postSeek 30000 (no onStream needed) ---
{
    my ($ctl, $daemon, $ws) = fresh_control(observed => { wsConnected => 1, meta => {} });

    $ctl->requestTrack($TID, 30000, { source => 'getNextTrack', successCb => sub { } });

    is_deeply($ws->sent, [ [ 'play', { uri => $TID } ] ], "mismatch with position: exactly one play, no onStream needed");
    is($ctl->pending->{postSeek}, 30000, "mismatch with position: postSeek 30000 recorded from the play dispatch alone");
}

# --- sync arm degrade-open: socket fails -> warn, seek still sent ---
{
    @Slim::Utils::Log::WARNINGS = ();
    local $IO::Socket::INET::FAIL = 1;

    my ($ctl, $daemon, $ws) = fresh_control(
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'playing' },
    );

    $ctl->requestTrack($TID, 5000, { source => 'onStream', seek => 1 });

    ok((grep { /sync seek-arm failed/ } @Slim::Utils::Log::WARNINGS), "sync arm degrade-open: warning logged");
    is_deeply($ws->sent, [ [ 'seek', { position_ms => 5000 } ], [ 'play', {} ] ],
        "sync arm degrade-open: seek still sent despite the failed arm");
}

# ============================================================
# CR-05 (82-REVIEW.md, 82-12): _armSync/_postBoundary go through the
# shared _loopbackPost -- a non-blocking socket (`Blocking => 0`, no
# `Timeout`) and exactly one syswrite, no response ever read. Fall C
# ("degrade-open bleibt") is the pre-existing "sync arm degrade-open" case
# directly above -- not repeated here, just named so the CR-05 grep gate
# covers it.
# ============================================================

# --- CR-05: Fall A -- no blocking socket setup: no Timeout argument, and
# Blocking is explicitly set to 0 ---
{
    @IO::Socket::INET::CALLS = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'playing' },
    );

    $ctl->requestTrack($TID, 5000, { source => 'onStream', seek => 1 });

    is(scalar(@IO::Socket::INET::CALLS), 1, "CR-05: Fall A -- exactly one IO::Socket::INET->new for the sync arm");
    ok(!exists $IO::Socket::INET::CALLS[0]{Timeout}, "CR-05: Fall A -- no Timeout argument on the socket constructor");
    is($IO::Socket::INET::CALLS[0]{Blocking}, 0, "CR-05: Fall A -- Blocking is explicitly set to 0");
}

# --- CR-05: Fall B -- exactly one write, no response read ---
{
    @IO::Socket::INET::SYSWRITE_CALLS = ();
    @IO::Socket::INET::SYSREAD_CALLS  = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'playing' },
    );

    $ctl->requestTrack($TID, 5000, { source => 'onStream', seek => 1 });

    is(scalar(@IO::Socket::INET::SYSWRITE_CALLS), 1, "CR-05: Fall B -- exactly one syswrite call");
    like($IO::Socket::INET::SYSWRITE_CALLS[0], qr{^POST /seek-arm HTTP/1\.0\r\nConnection: close\r\n\r\n$},
        "CR-05: Fall B -- the write carries the full POST request, nothing more");
    is(scalar(@IO::Socket::INET::SYSREAD_CALLS), 0, "CR-05: Fall B -- no read attempted after the write");
}

# --- CR-05: Fall D -- a partial write is detected, logged, and does not
# block the caller's own command ---
{
    @Slim::Utils::Log::WARNINGS = ();
    local $IO::Socket::INET::PARTIAL_WRITE = 5;

    my ($ctl, $daemon, $ws) = fresh_control(
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'playing' },
    );

    $ctl->requestTrack($TID, 5000, { source => 'onStream', seek => 1 });

    ok((grep { /partial write/ } @Slim::Utils::Log::WARNINGS), "CR-05: Fall D -- partial write is logged");
    is_deeply($ws->sent, [ [ 'seek', { position_ms => 5000 } ], [ 'play', {} ] ],
        "CR-05: Fall D -- caller's command still sent despite the partial write");
}

# --- CR-05: Fall E -- _postBoundary uses the same non-blocking loopback
# path and the same socket arguments as the arm ---
{
    @IO::Socket::INET::CALLS = ();

    my ($ctl, $daemon, $ws) = fresh_control(mode => 'browse', observed => { wsConnected => 1, meta => {} });

    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));    # no pending -> foreign path -> _postBoundary

    is(scalar(@IO::Socket::INET::CALLS), 1, "CR-05: Fall E -- _postBoundary issues one loopback POST");
    ok(!exists $IO::Socket::INET::CALLS[0]{Timeout}, "CR-05: Fall E -- boundary socket has no Timeout either");
    is($IO::Socket::INET::CALLS[0]{Blocking}, 0, "CR-05: Fall E -- boundary socket is Blocking => 0");
}

# --- getNextTrack path uses sync arm (no async arm) -- 82-19 F2: the
# getNextTrack call site arms over the same loopback socket as onStream
# now; the async HTTP-client channel (SimpleAsyncHTTP) is never touched ---
{
    @IO::Socket::INET::REQUESTS                = ();
    @Slim::Networking::SimpleAsyncHTTP::CALLS  = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        observed => { wsConnected => 1, meta => { $TID => { duration => 200 } }, track => 'spotify:track:previousXYZ', status => 'playing' },
    );

    $ctl->requestTrack($TID, 0, { source => 'getNextTrack', successCb => sub { } });

    is(scalar(@IO::Socket::INET::REQUESTS), 1,
        "getNextTrack path uses sync arm (no async arm) -- one sync seek-arm POST issued via the loopback socket");
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::CALLS), 0,
        "getNextTrack path uses sync arm (no async arm) -- no SimpleAsyncHTTP call, the async channel is gone");
}

# --- seekable: unknown meta -> 0; noteDuration -> 1; noteMetadataMissing ->
# 0 + exactly one ('warn','Soloist',qr/seek disabled/) ---
{
    @Plugins::SpotOn::Status::RECORDED = ();

    my ($ctl, $daemon, $ws) = fresh_control(observed => { wsConnected => 1, meta => {} });

    is($ctl->seekable($TID), 0, "seekable: unknown meta -> 0");

    $ctl->noteDuration($TID, 180);
    is($ctl->seekable($TID), 1, "seekable: noteDuration -> 1");

    $ctl->noteMetadataMissing($TID);
    is($ctl->seekable($TID), 0, "seekable: noteMetadataMissing -> 0");
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 1, "seekable: noteMetadataMissing records exactly one errors[] entry");
    is($Plugins::SpotOn::Status::RECORDED[0][0], 'warn', "seekable: recorded level is 'warn'");
    is($Plugins::SpotOn::Status::RECORDED[0][1], 'Soloist', "seekable: recorded module is 'Soloist'");
    like($Plugins::SpotOn::Status::RECORDED[0][2], qr/seek disabled/, "seekable: recorded message mentions 'seek disabled'");
}

# --- T_meta: play on cache miss -> play sent immediately; echo -> successCb
# held; noteDuration -> successCb ---
{
    my ($ctl, $daemon, $ws) = fresh_control(observed => { wsConnected => 1, meta => {} });

    my $success;
    $ctl->requestTrack($TID, 0, { source => 'getNextTrack', successCb => sub { $success++ } });

    is_deeply($ws->sent, [ [ 'play', { uri => $TID } ] ], "T_meta: play on cache miss -- play sent immediately");
    ok(!$success, "T_meta: successCb not yet fired before the echo");

    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));
    ok(!$success, "T_meta: echo alone does not release successCb -- duration unknown, held for T_meta");

    $ctl->noteDuration($TID, 180);
    is($success, 1, "T_meta: noteDuration releases the held successCb");
}

# --- T_meta timeout: echo, fire_timers(+1.6s) -> successCb once; 85-07 D-11:
# the timer cannot tell "slow" from "never", so it must NOT disable seek or
# write an errors[] entry -- seek stays off only because the duration is
# still unknown, and a later noteDuration turns it on. ---
{
    @Plugins::SpotOn::Status::RECORDED = ();
    # 82-23 WR-04 (direct consequence, same reasoning as the "drift
    # limit" block above): fire_due(+1.6) below sweeps every due timer
    # file-wide, not just this test's own -- clear foreign leftovers
    # before this fresh $ctl (which owns no timer yet) starts.
    @Slim::Utils::Timers::TIMERS = ();

    my ($ctl, $daemon, $ws) = fresh_control(observed => { wsConnected => 1, meta => {} });

    my $success;
    $ctl->requestTrack($TID, 0, { source => 'getNextTrack', successCb => sub { $success++ } });
    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));
    ok(!$success, "T_meta timeout: not yet fired right after the echo");

    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 1.6);

    is($success, 1, "T_meta timeout: successCb fires exactly once after T_META_MS with no duration");
    is($ctl->seekable($TID), 0, "85-07 D-11 T_meta timeout: seekable is 0 -- because the duration is unknown");
    ok(!defined($ctl->observed->{meta}{$TID}{seekable}),
        "85-07 D-11 T_meta timeout: NO explicit seekable=0 was written (the timer does not fail seek closed)");
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 0, "85-07 D-11 T_meta timeout: no errors[] entry (no 'seek disabled')");

    $ctl->noteDuration($TID, 180);
    is($ctl->seekable($TID), 1, "85-07 D-11 T_meta timeout: a later noteDuration makes the title seekable");
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 0, "85-07 D-11 T_meta timeout: still no errors[] entry after the late duration");
}

# --- generation: nextStreamGeneration increments 1,2,3 ---
{
    my ($ctl, $daemon, $ws) = fresh_control(observed => { wsConnected => 1, meta => {} });

    is($ctl->nextStreamGeneration, 1, "generation: nextStreamGeneration increments 1,2,3 -- first call returns 1");
    is($ctl->nextStreamGeneration, 2, "generation: nextStreamGeneration increments 1,2,3 -- second call returns 2");
    is($ctl->nextStreamGeneration, 3, "generation: nextStreamGeneration increments 1,2,3 -- third call returns 3");
    is($ctl->streamGeneration, 3, "generation: streamGeneration reads back the last value without incrementing");
}

# ============================================================
# Phase 82 Plan 05, Task 1: requestPause/requestResume (T-4, Befund 3) --
# classification against LMS' CURRENT playmode, never a time window.
# ============================================================

# --- requestPause: playmode play -> nothing sent, wanted.playing stays 1
# (historic notification, LMS already playing again) ---
{
    local $Slim::Player::Source::PLAYMODE = 'play';

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:01', mode => 'browse', observed => { wsConnected => 1, meta => {}, status => 'playing' },
    );
    $ctl->wanted->{playing} = 1;

    $ctl->requestPause(0);

    is_deeply($ws->sent, [], "requestPause: playmode play -- nothing sent");
    is($ctl->wanted->{playing}, 1, "requestPause: playmode play -- wanted.playing stays 1");
}

# --- requestPause: playmode pause, observed playing -> ['pause',{}] ---
{
    local $Slim::Player::Source::PLAYMODE = 'pause';

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:02', mode => 'browse', observed => { wsConnected => 1, meta => {}, status => 'playing' },
    );

    $ctl->requestPause(0);

    is_deeply($ws->sent, [ [ 'pause', {} ] ], "requestPause: playmode pause, observed playing -- ['pause',{}]");
    is($ctl->wanted->{playing}, 0, "requestPause: wanted.playing set to 0");
}

# --- requestPause(stop): playmode stop -> ['pause',{}] ---
{
    local $Slim::Player::Source::PLAYMODE = 'stop';

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:03', mode => 'browse', observed => { wsConnected => 1, meta => {}, status => 'playing' },
    );

    $ctl->requestPause(1);

    is_deeply($ws->sent, [ [ 'pause', {} ] ], "requestPause(stop): playmode stop -- ['pause',{}]");
}

# --- G3-FIX (82-20, H-F, 82-G3-MESSUNG.md Verdikt): requestPause(stop) with a
# STALE observed.status='paused' must still dispatch exactly one pause. Three
# live-measured runs (L1-L3, all Bruchstufe H-F) showed the daemon still
# actively streaming (fakepulse `playing`/`underflow` right up to the
# `client-close`) while Control's `observed.status` already read 'paused' --
# a stale value from an earlier poll/session. Before the fix, _reconcile's
# statusIsPlaying guard folded this real isStop transition silently into
# `return 1`, so `_dispatch('pause')` was never reached and the daemon kept
# ticking after LMS believed playback had stopped (Split-Brain, exactly what
# T-4 excludes). A Stop must force the pause dispatch regardless of
# observed.status (Fix-Zuordnung: "derselbe bestehende _dispatch('pause')
# -Aufruf, nur die Torbedingung um isStop erweitert; kein zweiter
# Kommandopfad", Prinzip 3.1(4)).
{
    local $Slim::Player::Source::PLAYMODE = 'stop';

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:21', mode => 'browse',
        observed => { wsConnected => 1, meta => {}, status => 'paused', paired => 1 },
    );

    $ctl->requestPause(1);

    is_deeply($ws->sent, [ [ 'pause', {} ] ],
        "G3-FIX: requestPause(stop) with stale observed.status=paused -- pause still dispatched (H-F)");
}

# --- requestPause: observed already paused -> nothing ---
{
    local $Slim::Player::Source::PLAYMODE = 'pause';

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:04', mode => 'browse', observed => { wsConnected => 1, meta => {}, status => 'paused' },
    );

    $ctl->requestPause(0);

    is_deeply($ws->sent, [], "requestPause: observed already paused -- nothing");
}

# --- requestPause: ws down -> nothing sent now; _transport open -> ['pause',{}]
# (never deadened, T-82-28) ---
{
    local $Slim::Player::Source::PLAYMODE = 'pause';

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:05', mode => 'browse', observed => { wsConnected => 0, meta => {} },
    );

    $ctl->requestPause(0);
    is_deeply($ws->sent, [], "CR-03: Fall B -- requestPause: ws down -- nothing sent now");
    is($ctl->wanted->{playing}, 0, "CR-03: Fall B -- requestPause: ws down -- wanted.playing still recorded as 0");

    $ctl->onEvent({ type => '_transport', state => 'open' });
    is_deeply($ws->sent, [ [ 'pause', {} ] ],
        "CR-03: Fall B -- requestPause: ws down -> _transport open dispatches the caught-up pause (never deadened)");
}

# ============================================================
# 82-11 Task 1, CR-03: no `pause` before authentication -- `defined`-Guard,
# Handshake-Reihenfolge, begrenzte Nachfrage.
# ============================================================

# --- CR-03: Fall A -- fresh Control, _transport open sends nothing (wanted
# is still {}, wanted.playing is undef -- "no wish", not "not playing") ---
{
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:ee:0a');

    $ctl->onEvent({ type => '_transport', state => 'open' });

    is_deeply($ws->sent, [], "CR-03: Fall A -- fresh Control, _transport open sends nothing");
}

# --- CR-03: Fall D -- paired:0 re-probes get_auth_state on a bounded timer
# (AUTH_REPROBE_S/AUTH_REPROBE_MAX), never past the limit ---
{
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:ee:0b');

    $ctl->onEvent({ type => 'error', message => 'requires authentication' });
    is($ctl->observed->{paired}, 0, "CR-03: Fall D -- paired set to 0 on auth error");
    is_deeply($ws->sent, [], "CR-03: Fall D -- no re-probe sent synchronously");

    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 5.1);
    is_deeply($ws->sent, [ [ 'get_auth_state', {} ] ],
        "CR-03: Fall D -- one re-probe get_auth_state after AUTH_REPROBE_S");

    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 10.2);
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 15.3);
    is(scalar(@{ $ws->sent }), 3, "CR-03: Fall D -- three re-probes total after two more rounds");

    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 20.4);
    is(scalar(@{ $ws->sent }), 3, "CR-03: Fall D -- no fourth re-probe after AUTH_REPROBE_MAX");
}

# --- CR-03: Fall E -- a successful auth_state ends the re-probe ---
{
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:ee:0c');

    $ctl->onEvent({ type => 'error', message => 'requires authentication' });
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 5.1);
    is(scalar(@{ $ws->sent }), 1, "CR-03: Fall E -- one re-probe get_auth_state sent before login");

    $ctl->onEvent({ type => 'auth_state', logged_in => 1 });
    is($ctl->observed->{paired}, 1, "CR-03: Fall E -- paired set to 1 after auth_state logged_in");
    my $sentAfterLogin = scalar(@{ $ws->sent });

    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 20);
    is(scalar(@{ $ws->sent }), $sentAfterLogin,
        "CR-03: Fall E -- no further re-probe after successful login");
}

# --- requestResume: observed paused -> ['play',{}], wanted.playing 1 ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:06', mode => 'browse', observed => { wsConnected => 1, meta => {}, status => 'paused' },
    );

    $ctl->requestResume;

    is_deeply($ws->sent, [ [ 'play', {} ] ], "requestResume: observed paused -- ['play',{}]");
    is($ctl->wanted->{playing}, 1, "requestResume: wanted.playing set to 1");
}

# --- requestResume: observed playing -> nothing ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:07', mode => 'browse', observed => { wsConnected => 1, meta => {}, status => 'playing' },
    );

    $ctl->requestResume;

    is_deeply($ws->sent, [], "requestResume: observed playing -- nothing");
}

# ============================================================
# 84-26 R1 (F-24-1, B7): the resume row of _reconcilePlan is uri-aware. A bare
# daemon `play` resumes WHATEVER the daemon sits on -- after the autoplay guard
# paused a foreign successor, an LMS-internal unpause (rebuffer at the A->L
# boundary, forwarded by Connect.pm _onPause) restarted that foreign title.
# requestResume now refuses (one INFO line, no errors[] entry, `wanted`
# untouched) while the daemon sits on a title other than wanted.uri or on the
# autoplay-paused title. R1_CONNECT_ROW=marker_only: wanted.uri does not follow
# observed.track in connect (Control.pm wanted({ ... }) only at requestTrack,
# the idle adoption and the transfer-in; Connect.pm:2153-2163 hold), so the
# resume row changes in browse only.
# ============================================================
{
    my $mac = 'aa:bb:cc:dd:ee:a1';
    @Plugins::SpotOn::Status::RECORDED = ();
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac, mode => 'browse',
        observed => { wsConnected => 1, meta => {}, track => 'spotify:track:ZZZZZZZZZZZZZZZZZZZZZZ', status => 'paused' },
        wanted   => { uri => 'spotify:track:AAAAAAAAAAAAAAAAAAAAAA', playing => 1 },
    );
    own_track($mac);

    $ctl->requestResume;

    is_deeply($ws->sent, [], "84-26 R1 Fall A: a resume while the daemon sits on another title sends nothing");
    is($ctl->wanted->{playing}, 1, "84-26 R1 Fall A: wanted.playing stays 1 (the refusal does not clear the wish)");
    is($ctl->wanted->{uri}, 'spotify:track:AAAAAAAAAAAAAAAAAAAAAA', "84-26 R1 Fall A: wanted.uri untouched");
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 0, "84-26 R1 Fall A: the refusal records no errors[] entry");
}

{
    my $mac = 'aa:bb:cc:dd:ee:a2';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac, mode => 'browse',
        observed => { wsConnected => 1, meta => {}, track => 'spotify:track:AAAAAAAAAAAAAAAAAAAAAA', status => 'paused' },
        wanted   => { uri => 'spotify:track:AAAAAAAAAAAAAAAAAAAAAA', playing => 1 },
    );
    own_track($mac);

    $ctl->requestResume;

    is_deeply($ws->sent, [ [ 'play', {} ] ], "84-26 R1 Fall B: the daemon sits on wanted.uri -- the bare play is sent (a genuine unpause)");
}

{
    my $mac = 'aa:bb:cc:dd:ee:a3';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac, mode => 'browse',
        observed => { wsConnected => 1, meta => {}, track => 'spotify:track:AAAAAAAAAAAAAAAAAAAAAA', status => 'paused',
                      autoplayPaused => 'spotify:track:AAAAAAAAAAAAAAAAAAAAAA' },
        wanted   => { uri => 'spotify:track:AAAAAAAAAAAAAAAAAAAAAA', playing => 1 },
    );
    own_track($mac);

    $ctl->requestResume;

    is_deeply($ws->sent, [], "84-26 R1 Fall C: a resume on the autoplay-paused title (the replay shape: same uri) sends nothing");
}

{
    my $mac = 'aa:bb:cc:dd:ee:a4';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac, mode => 'browse',
        observed => { wsConnected => 1, meta => {}, status => 'paused' },
        wanted   => { uri => 'spotify:track:AAAAAAAAAAAAAAAAAAAAAA', playing => 1 },
    );
    own_track($mac);

    $ctl->requestResume;

    is_deeply($ws->sent, [ [ 'play', {} ] ], "84-26 R1 Fall D: no title observed yet (undef observed.track) keeps the bare play (contract of the :2173 block)");
}

{
    my $mac = 'aa:bb:cc:dd:ee:a5';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac, mode => 'connect',
        observed => { wsConnected => 1, meta => {}, track => 'spotify:track:ZZZZZZZZZZZZZZZZZZZZZZ', status => 'paused' },
        wanted   => { uri => 'spotify:track:AAAAAAAAAAAAAAAAAAAAAA', playing => 1 },
    );
    own_track($mac);

    $ctl->requestResume;

    is_deeply($ws->sent, [ [ 'play', {} ] ],
        "84-26 R1 Fall E: connect mode keeps the bare play (R1_CONNECT_ROW=marker_only -- wanted.uri lags observed.track after a phone-side title change)");
}

{
    my $mac = 'aa:bb:cc:dd:ee:a6';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac, mode => 'connect',
        observed => { wsConnected => 1, meta => {}, track => 'spotify:track:ZZZZZZZZZZZZZZZZZZZZZZ', status => 'paused',
                      autoplayPaused => 'spotify:track:ZZZZZZZZZZZZZZZZZZZZZZ' },
        wanted   => { uri => 'spotify:track:ZZZZZZZZZZZZZZZZZZZZZZ', playing => 1 },
    );
    own_track($mac);

    $ctl->requestResume;

    is_deeply($ws->sent, [ [ 'play', {} ] ],
        "84-26 R1 Fall E2: a stale marker never refuses a resume in connect (the marker clause is browse-only)");
}

# Fall H (guard, the prefetch-hit shape): the daemon's own track_changed for the
# prefetched successor Y arrives while wanted.uri is still the previous title X.
# A refusal is harmless -- LMS's advance then calls requestTrack(Y), which takes
# the step-4 prefetch/resume row.
{
    my $mac = 'aa:bb:cc:dd:ee:a7';
    my $Y   = 'spotify:track:YYYYYYYYYYYYYYYYYYYYYY';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac, mode => 'browse',
        observed => { wsConnected => 1, meta => { $Y => { duration => 200 } }, track => $Y, status => 'paused' },
        wanted   => { uri => 'spotify:track:XXXXXXXXXXXXXXXXXXXXXX', playing => 1 },
    );
    own_track($mac);

    $ctl->requestResume;
    is_deeply($ws->sent, [], "84-26 R1 Fall H: the prefetch-hit shape -- requestResume while wanted.uri lags sends nothing");

    my $ok = 0;
    $ctl->requestTrack($Y, 0, { source => 'getNextTrack', successCb => sub { $ok++ }, errorCb => sub { } });
    my @plays = grep { ref($_) eq 'ARRAY' && $_->[0] eq 'play' } @{ $ws->sent };
    is(scalar(@plays), 1, "84-26 R1 Fall H: the ordinary advance requestTrack(Y) recovers with exactly one play (step-4 bare resume)");
    ok(!exists $plays[0]->[1]{uri}, "84-26 R1 Fall H: that play is the bare resume (no uri)");
}

# Fall H3 (guard, green before and after): the ordinary advance ALONE -- requestTrack(Y) on a paused daemon that
# already sits on Y takes the step-4 bare resume, with or without the R1 refusal in front of it.
{
    my $mac = 'aa:bb:cc:dd:ee:a9';
    my $Y   = 'spotify:track:YYYYYYYYYYYYYYYYYYYYYY';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac, mode => 'browse',
        observed => { wsConnected => 1, meta => { $Y => { duration => 200 } }, track => $Y, status => 'paused' },
        wanted   => { uri => 'spotify:track:XXXXXXXXXXXXXXXXXXXXXX', playing => 1 },
    );
    own_track($mac);

    $ctl->requestTrack($Y, 0, { source => 'getNextTrack', successCb => sub { }, errorCb => sub { } });
    my @plays = grep { ref($_) eq 'ARRAY' && $_->[0] eq 'play' } @{ $ws->sent };
    is(scalar(@plays), 1, "84-26 R1 Fall H3: requestTrack(Y) alone on a paused daemon sitting on Y sends exactly one play");
    ok(!exists $plays[0]->[1]{uri}, "84-26 R1 Fall H3: that play is the bare resume (no uri)");
}

{
    my $mac = 'aa:bb:cc:dd:ee:a8';
    my $Y   = 'spotify:track:YYYYYYYYYYYYYYYYYYYYYY';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac, mode => 'browse',
        observed => { wsConnected => 1, meta => { $Y => { duration => 200 } }, track => $Y, status => 'playing' },
        wanted   => { uri => 'spotify:track:XXXXXXXXXXXXXXXXXXXXXX', playing => 1 },
    );
    own_track($mac);

    my $ok = 0;
    $ctl->requestTrack($Y, 0, { source => 'getNextTrack', successCb => sub { $ok++ }, errorCb => sub { } });
    is($ok, 1, "84-26 R1 Fall H2: daemon already playing the prefetched successor -- the successCb fires");
    is(scalar(grep { ref($_) eq 'ARRAY' && $_->[0] eq 'play' } @{ $ws->sent }), 0, "84-26 R1 Fall H2: nothing sent");
}

# ============================================================
# Phase 82 Plan 05, Task 1: requestVolume + volume_changed echo/grace/
# foreign classification (T-6, D-06).
# ============================================================

# --- requestVolume(50): observed 40 -> ['set_volume',{volume=>50}], pending
# set_volume ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:08', mode => 'browse', observed => { wsConnected => 1, meta => {}, volume => 40 },
    );

    $ctl->requestVolume(50);

    is_deeply($ws->sent, [ [ 'set_volume', { volume => 50 } ] ],
        "requestVolume(50): observed 40 -- ['set_volume',{volume=>50}]");
    is($ctl->pending->{cmd}, 'set_volume', "requestVolume(50): pending.cmd is set_volume");
    is($ctl->pending->{volume}, 50, "requestVolume(50): pending.volume is 50");
}

# --- requestVolume(40): observed 40 -> nothing ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:09', mode => 'browse', observed => { wsConnected => 1, meta => {}, volume => 40 },
    );

    $ctl->requestVolume(40);

    is_deeply($ws->sent, [], "requestVolume(40): observed 40 -- nothing");
}

# --- volume_changed 50 with pending set_volume 50 -> echo: no emission,
# pending cleared, observed 50 ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:10', mode => 'browse', observed => { wsConnected => 1, meta => {}, volume => 40 },
    );
    @Slim::Player::Client::EXECUTED = ();

    $ctl->requestVolume(50);
    $ctl->onEvent({ type => 'volume_changed', volume => 50 });

    is_deeply(\@Slim::Player::Client::EXECUTED, [], "volume_changed 50 with pending set_volume 50 -- echo: no emission");
    is($ctl->pending, undef, "volume_changed 50 echo -- pending cleared");
    is($ctl->observed->{volume}, 50, "volume_changed 50 echo -- observed.volume updated to 50");
}

# --- volume_changed 30 foreign in browse -> emitted
# [['spottyconnect','volume',30,'']], wanted.volume 30 ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:11', mode => 'browse', observed => { wsConnected => 1, meta => {}, volume => 40 },
    );
    @Slim::Player::Client::EXECUTED = ();

    $ctl->onEvent({ type => 'volume_changed', volume => 30 });

    is_deeply(\@Slim::Player::Client::EXECUTED, [ [ 'spottyconnect', 'volume', 30, '' ] ],
        "volume_changed 30 foreign in browse -- emitted [['spottyconnect','volume',30,'']]");
    is($ctl->wanted->{volume}, 30, "volume_changed 30 foreign in browse -- wanted.volume 30");
}

# --- volume_changed 30 within grace (uptime 1) -> no emission, observed 30
# (CON-11, now applies in Browse too) ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:12', mode => 'browse', uptime => 1,
        observed => { wsConnected => 1, meta => {}, volume => 40 },
    );
    @Slim::Player::Client::EXECUTED = ();

    $ctl->onEvent({ type => 'volume_changed', volume => 30 });

    is_deeply(\@Slim::Player::Client::EXECUTED, [], "volume_changed 30 within grace -- no emission");
    is($ctl->observed->{volume}, 30, "volume_changed 30 within grace -- observed.volume updated to 30");
}

# --- volume_changed in idle -> no emission ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:13', mode => 'idle', observed => { wsConnected => 1, meta => {}, volume => 40 },
    );
    @Slim::Player::Client::EXECUTED = ();

    $ctl->onEvent({ type => 'volume_changed', volume => 30 });

    is_deeply(\@Slim::Player::Client::EXECUTED, [], "volume_changed in idle -- no emission");
}

# ============================================================
# Phase 82 Plan 05, Task 1: volume push on mode entry (H6-Ersatz, D-06) --
# a `play` dispatched by requestTrack is still pending its track_changed
# echo, so the push folds into pending.postVolume (mirrors postSeek,
# 82-04) and applies once the echo confirms the track.
# ============================================================

# --- mode entry idle->browse pushes client volume: requestTrack(Y) with
# client volume 55 -> sent ends with ['set_volume',{volume=>55}] ---
{
    my $mac = 'aa:bb:cc:dd:ee:14';
    Slim::Player::Client::getClient($mac)->volume(55);

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac, observed => { wsConnected => 1, meta => { $TID => { duration => 200 } } },
    );
    is($ctl->mode, 'idle', "mode entry idle: fresh control starts in idle");

    $ctl->requestTrack($TID, 0, {});

    is_deeply($ws->sent, [ [ 'play', { uri => $TID } ] ],
        "mode entry idle->browse pushes client volume: play sent, set_volume folded (not sent yet)");
    is($ctl->pending->{postVolume}, 55, "mode entry idle->browse pushes client volume: pending.postVolume is 55");

    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    is_deeply($ws->sent, [ [ 'play', { uri => $TID } ], [ 'seek', { position_ms => 0 } ], [ 'set_volume', { volume => 55 } ] ],
        "mode entry idle->browse pushes client volume: requestTrack(Y) with client volume 55 -- CR-01's postSeek 0 fires before "
        . "set_volume (82-08)");
}

# --- mode entry connect->browse pushes client volume (Seed mode connect,
# requestTrack aus getNextTrack mit fremder uri) ---
{
    my $mac = 'aa:bb:cc:dd:ee:15';
    Slim::Player::Client::getClient($mac)->volume(66);

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac, mode => 'connect',
        observed => { wsConnected => 1, meta => { $TID => { duration => 200 } }, track => 'spotify:track:previousXYZ', status => 'playing' },
    );

    $ctl->requestTrack($TID, 0, { source => 'getNextTrack' });

    is($ctl->mode, 'browse', "mode entry connect->browse pushes client volume: mode flipped to browse");
    is($ctl->pending->{postVolume}, 66, "mode entry connect->browse pushes client volume: pending.postVolume is 66");

    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    is_deeply($ws->sent->[-1], [ 'set_volume', { volume => 66 } ],
        "mode entry connect->browse pushes client volume: set_volume dispatched after the echo");
}

# ============================================================
# Phase 82 Plan 06, Task 1: Queue-Prefetch (D-C, eingefuehrt). _prefetchNext
# fires on the track_changed echo in browse mode and reads the NEXT LMS
# playlist entry (streamingSongIndex+1) -- track only, queue_changed
# confirms it back into observed.queuedNext.
# ============================================================

my $NEXT_TID = 'spotify:track:3n3Ppam7vgaVa1iaRUc9Lp';    # s01-pure-daemon-queue.jsonl's upcoming[0].item.uri

# --- track_changed echo in browse with next entry spoton://track:Y ->
# ['add_to_queue',{uri=>'spotify:track:Y'}] sent after play ---
{
    local @Slim::Player::Playlist::ENTRIES = ( undef, Test::MockTrack->new("spoton://track:3n3Ppam7vgaVa1iaRUc9Lp") );
    local $Slim::Player::Source::INDEX = 0;

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:20',
        observed => { wsConnected => 1, meta => { $TID => { duration => 200 } }, track => 'spotify:track:previousXYZ', status => 'playing' },
    );

    $ctl->requestTrack($TID, 0, {});
    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    is_deeply($ws->sent, [ [ 'play', { uri => $TID } ], [ 'seek', { position_ms => 0 } ], [ 'add_to_queue', { uri => $NEXT_TID } ] ],
        "prefetch: track_changed echo in browse with next entry spoton://track:Y -- CR-01's postSeek 0 fires before "
        . "add_to_queue (82-08)");
}

# --- next entry is an episode -> no add_to_queue ---
{
    local @Slim::Player::Playlist::ENTRIES = ( undef, Test::MockTrack->new('spoton://episode:someEpisodeId12345') );
    local $Slim::Player::Source::INDEX = 0;

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:21',
        observed => { wsConnected => 1, meta => { $TID => { duration => 200 } }, track => 'spotify:track:previousXYZ', status => 'playing' },
    );

    $ctl->requestTrack($TID, 0, {});
    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    is_deeply($ws->sent, [ [ 'play', { uri => $TID } ], [ 'seek', { position_ms => 0 } ] ],
        "prefetch: next entry is an episode -- no add_to_queue (CR-01's postSeek 0 still fires, 82-08)");
}

# --- no next entry -> nothing ---
{
    local @Slim::Player::Playlist::ENTRIES = ();
    local $Slim::Player::Source::INDEX = 0;

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:22',
        observed => { wsConnected => 1, meta => { $TID => { duration => 200 } }, track => 'spotify:track:previousXYZ', status => 'playing' },
    );

    $ctl->requestTrack($TID, 0, {});
    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    is_deeply($ws->sent, [ [ 'play', { uri => $TID } ], [ 'seek', { position_ms => 0 } ] ],
        "prefetch: no next entry -- nothing sent (CR-01's postSeek 0 still fires, 82-08)");
}

# --- queue_changed fixture line from s01-pure-daemon-queue.jsonl ->
# observed.queuedNext set ---
{
    my @lines = load_fixture('s01-pure-daemon-queue.jsonl');
    my ($qcLine) = grep { /"uid":"q0"/ } @lines;
    ok(defined $qcLine, "prefetch: queue_changed fixture line found in s01-pure-daemon-queue.jsonl");

    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:ee:23', observed => { wsConnected => 1, meta => {} });

    $ctl->onEvent(decode_frame($qcLine));

    is($ctl->observed->{queuedNext}, $NEXT_TID,
        "prefetch: queue_changed fixture line from s01-pure-daemon-queue.jsonl -- observed.queuedNext set");
}

# --- prefetch hit: foreign track_changed(Y) with queuedNext Y -> boundary
# 1; then requestTrack(Y) from getNextTrack -> nothing sent, successCb
# immediately. Anchor (WR-01, 82-31) set on the INITIAL observed (the
# previous track), not added afterwards -- track_changed never writes
# observed.anchor in production, so the previous track's anchor is what
# survives into the queued-next Treffer below. ---
{
    @IO::Socket::INET::CALLS = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mac  => 'aa:bb:cc:dd:ee:24',
        mode => 'browse',
        observed => { wsConnected => 1, meta => {}, track => 'spotify:track:previousXYZ', status => 'playing', queuedNext => $NEXT_TID, anchor => { position_ms => 0, seen_at => Time::HiRes::time() } },
    );

    $ctl->onEvent({ type => 'track_changed', item => { uri => $NEXT_TID } });

    is(scalar(@IO::Socket::INET::CALLS), 1, "prefetch hit: foreign track_changed(Y) with queuedNext Y -- boundary 1");
    is($ctl->observed->{track}, $NEXT_TID, "prefetch hit: observed.track updated to Y");

    my $success;
    $ctl->requestTrack($NEXT_TID, 0, { source => 'getNextTrack', successCb => sub { $success++ } });

    is_deeply($ws->sent, [], "prefetch hit: requestTrack(Y) from getNextTrack -- nothing sent");
    is($success, 1, "prefetch hit: requestTrack(Y) from getNextTrack -- successCb immediately");
}

# --- not in connect mode -- no add_to_queue sent on the echo ---
{
    local @Slim::Player::Playlist::ENTRIES = ( undef, Test::MockTrack->new("spoton://track:3n3Ppam7vgaVa1iaRUc9Lp") );
    local $Slim::Player::Source::INDEX = 0;

    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => 'aa:bb:cc:dd:ee:25',
        mode     => 'connect',
        observed => { wsConnected => 1, meta => { $TID => { duration => 200 } } },
        pending  => { cmd => 'play', uri => $TID, sentAt => Time::HiRes::time(), cb => {} },
    );

    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    is_deeply($ws->sent, [], "prefetch: not in connect mode -- no add_to_queue sent on the echo");
}

# ============================================================
# 84-19 F-18-N4 (stale daemon user queue): three changes in Control.pm,
# RED from the UAT recordings of 2026-10-04 (t/fixtures/soloist/
# f18n4-same1.frames = same-1.jsonl, f18n4-bound1.frames = bound-1.jsonl).
#   1. prefetch dedupe -- no second add_to_queue for a uri already queued
#   2. consume instead of play -- queue head == target -> skip_next
#   3. safety net -- the daemon consumed the head and restarted the title
#      that is playing (queue_changed without track_changed)
# ============================================================
my $N4_6D0C = 'spotify:track:6d0cIiukgZJ8fZBJFqDMBT';    # same-1: the title that is playing AND the stale queue head
my $N4_552L = 'spotify:track:552lBxKLGjerBDS8VYHOJn';    # bound-1: the stale DIFFERENT head the daemon advanced to

sub n4_queue_changed {
    my (@entries) = @_;    # [uid, source, uri]
    return {
        type     => 'queue_changed',
        previous => [],
        upcoming => [ map { { uid => $_->[0], source => $_->[1], item => { uri => $_->[2] } } } @entries ],
    };
}

# --- change 1: dedupe prefetch -- the next uri is already a queue entry
# (same-1 10:29:57.394: re-prefetching after a jump left [6d0c, 5EZh, 5EZh]).
{
    local @Slim::Player::Playlist::ENTRIES = ( undef, Test::MockTrack->new("spoton://track:3n3Ppam7vgaVa1iaRUc9Lp") );
    local $Slim::Player::Source::INDEX = 0;

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:30',
        observed => { wsConnected => 1, meta => { $TID => { duration => 200 } }, track => 'spotify:track:previousXYZ', status => 'playing' },
    );

    # the daemon already holds NEXT in its user queue (behind a stale entry, so queuedNext is another uri)
    $ctl->onEvent(n4_queue_changed([ 'q1', 'queue', 'spotify:track:staleOtherTitle1' ], [ 'q2', 'queue', $NEXT_TID ]));

    $ctl->requestTrack($TID, 0, {});
    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    is_deeply($ws->sent, [ [ 'play', { uri => $TID } ], [ 'seek', { position_ms => 0 } ] ],
        "F-18-N4 change 1: next uri already a source:queue entry -- no second add_to_queue");
    ok(exists $ctl->observed->{queuedByUs}{$NEXT_TID},
        "F-18-N4 change 1: the origin marker still names the next uri (the natural advance stays a recognised prefetch hit)");
}

# --- change 1, real frame order (UAT 2026-10-04 11:50:22.516, same-1 10:29:57.343): `play X` starts with a
# placeholder queue_changed (only node_rules_placeholder entries) BEFORE track_changed and the real queue_changed.
# The echo's prefetch must still see the queue as it was -- the placeholder is not a queue state.
{
    local @Slim::Player::Playlist::ENTRIES = ( undef, Test::MockTrack->new("spoton://track:3n3Ppam7vgaVa1iaRUc9Lp") );
    local $Slim::Player::Source::INDEX = 0;

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:37',
        observed => { wsConnected => 1, meta => { $TID => { duration => 200 } }, track => 'spotify:track:previousXYZ', status => 'playing', is_active => 1 },
    );
    $ctl->onEvent(n4_queue_changed([ 'q1', 'queue', $NEXT_TID ], [ 'q2', 'queue', $NEXT_TID ]));
    $ctl->requestTrack($TID, 0, {});
    $ctl->onEvent(decode_frame($_)) for load_fixture('f18n4-placeholder.frames');
    is_deeply($ctl->observed->{queueUris}, [ $NEXT_TID, $NEXT_TID ],
        "F-18-N4 change 1 (real order): the placeholder queue_changed does not replace the known queue list");
    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    is_deeply($ws->sent, [ [ 'play', { uri => $TID } ], [ 'seek', { position_ms => 0 } ] ],
        "F-18-N4 change 1 (real order): placeholder, then echo -- the queued next uri is still not queued again");
}

# --- change 1 control: a queue that does NOT hold the next uri -> add_to_queue still goes out
{
    local @Slim::Player::Playlist::ENTRIES = ( undef, Test::MockTrack->new("spoton://track:3n3Ppam7vgaVa1iaRUc9Lp") );
    local $Slim::Player::Source::INDEX = 0;

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:31',
        observed => { wsConnected => 1, meta => { $TID => { duration => 200 } }, track => 'spotify:track:previousXYZ', status => 'playing' },
    );
    $ctl->onEvent(n4_queue_changed([ 'q1', 'queue', 'spotify:track:staleOtherTitle1' ], [ 'q2', 'context', $NEXT_TID ]));

    $ctl->requestTrack($TID, 0, {});
    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    is_deeply($ws->sent, [ [ 'play', { uri => $TID } ], [ 'seek', { position_ms => 0 } ], [ 'add_to_queue', { uri => $NEXT_TID } ] ],
        "F-18-N4 change 1 control: the uri is only a source:context entry, not queued -- add_to_queue goes out");
}

# --- change 2: queue head == target -> skip_next consumes it (a `play X` never consumes a head equal to X,
# same-1 10:29:57.381); the slot stays {cmd:'play', uri} so the track_changed echo is classified as OWN.
{
    local @Slim::Player::Playlist::ENTRIES = ( undef, Test::MockTrack->new("spoton://track:3n3Ppam7vgaVa1iaRUc9Lp") );
    local $Slim::Player::Source::INDEX = 0;

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:32', mode => 'browse',
        observed => { wsConnected => 1, meta => { $TID => { duration => 200 } }, track => 'spotify:track:previousXYZ',
                      status => 'playing', is_active => 1 },
    );
    $ctl->onEvent(n4_queue_changed([ 'q1', 'queue', $TID ]));
    is($ctl->observed->{queuedNext}, $TID, "F-18-N4 change 2 setup: queue head is the target");

    my ($success, $error_called);
    $ctl->requestTrack($TID, 0, { successCb => sub { $success++ }, errorCb => sub { $error_called = 1 } });

    is_deeply($ws->sent, [ [ 'skip_next', {} ] ],
        "F-18-N4 change 2: requestTrack(head) sends skip_next, not play");
    is($ctl->pending && $ctl->pending->{cmd}, 'play', "F-18-N4 change 2: the pending slot keeps cmd=play");
    is($ctl->pending && $ctl->pending->{uri}, $TID,   "F-18-N4 change 2: the pending slot keeps the target uri");

    @IO::Socket::INET::CALLS = ();
    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    is($ctl->pending, undef, "F-18-N4 change 2: the track_changed echo settles the pending slot");
    is($success, 1, "F-18-N4 change 2: successCb fires once on the echo");
    ok(!$error_called, "F-18-N4 change 2: errorCb never fires");
    is(scalar(@IO::Socket::INET::CALLS), 0, "F-18-N4 change 2: the echo is OWN -- no boundary, no seek-arm after it");
    is($ctl->observed->{track}, $TID, "F-18-N4 change 2: observed.track = target");
    is_deeply($ws->sent, [ [ 'skip_next', {} ], [ 'add_to_queue', { uri => $NEXT_TID } ] ],
        "F-18-N4 change 2: only the prefetch follows the echo (the title starts at 0 by itself: no pause, no seek)");
}

# --- change 2 control: head is another title -> plain play as before
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:33', mode => 'browse',
        observed => { wsConnected => 1, meta => { $TID => { duration => 200 } }, track => 'spotify:track:previousXYZ',
                      status => 'playing', is_active => 1 },
    );
    $ctl->onEvent(n4_queue_changed([ 'q1', 'queue', 'spotify:track:staleOtherTitle1' ]));
    $ctl->requestTrack($TID, 0, {});
    is_deeply($ws->sent, [ [ 'play', { uri => $TID } ] ],
        "F-18-N4 change 2 control: a different head -- plain play");
}

# --- change 3: safety net. same-1 10:30:26.152: the daemon consumed head q17 (= the title that is playing) and
# restarted 6d0c -- queue_changed previous=[ctx 6d0c], NO track_changed.
{
    my @f = map { decode_frame($_) } load_fixture('f18n4-same1.frames');
    @IO::Socket::INET::CALLS = ();
    @IO::Socket::INET::SYSWRITE_CALLS = ();    # 79-38: boundary posts are counted from the wire, see below

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:34', mode => 'browse',
        wanted   => { uri => $N4_6D0C, playing => 1 },
        observed => { wsConnected => 1, meta => {}, track => $N4_6D0C, status => 'playing', is_active => 1 },
    );

    $ctl->onEvent($_) for @f[0 .. 2];    # track_changed 6d0c, queue_changed head q17 = 6d0c (twice)
    is_deeply($ws->sent, [], "F-18-N4 change 3 setup: nothing sent while the head sits unconsumed behind the playing title");
    is(scalar(@IO::Socket::INET::CALLS), 0, "F-18-N4 change 3 setup: no boundary");

    $ctl->onEvent($_) for @f[3 .. 13];   # end-of-write ... the consumed-head restart

    is_deeply($ws->sent, [ [ 'pause', {} ] ],
        "F-18-N4 change 3: the head consumed while it IS the playing title (no track_changed) -- pause, like the foreign branch");
    # 79-38 (79 D-31): the daemon's restart of the title (buffering -> playing on the same uri) also posts one
    # /hold-release, a second control connection; the boundary count therefore reads the wire, not every connection.
    is(scalar(grep { m{^POST /boundary} } @IO::Socket::INET::SYSWRITE_CALLS), 1, "F-18-N4 change 3: one boundary planted with the pause");
}

# --- change 3 control: bound-1 09:44:03.654 -- the natural advance to the stale DIFFERENT head 552l also carries
# previous=[ctx 6d0c]; track_changed arrives one frame earlier. The foreign branch pauses ONCE; the detector adds nothing.
{
    my @f = map { decode_frame($_) } load_fixture('f18n4-bound1.frames');
    @IO::Socket::INET::CALLS = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:35', mode => 'browse',
        wanted   => { uri => $N4_6D0C, playing => 1 },
        observed => { wsConnected => 1, meta => {}, track => $N4_6D0C, status => 'playing', is_active => 1 },
    );
    $ctl->onEvent(n4_queue_changed([ 'q10', 'queue', $N4_552L ], [ 'q11', 'queue', 'spotify:track:stale2' ]));

    $ctl->onEvent($_) for @f;

    is_deeply($ws->sent, [ [ 'pause', {} ] ],
        "F-18-N4 change 3 control: bound-1 advance -- the foreign guard pauses once, the detector sends nothing more");
    is(scalar(@IO::Socket::INET::CALLS), 1, "F-18-N4 change 3 control: exactly one boundary (the foreign branch's)");
}

# --- change 3 guards: an open own play defers the detector (LMS repeat-one re-requests via play); a seek intent
# is a seek to 0, not a replay; idle mode is not browse.
for my $case (
    [ 'own play pending',  { late_pending => { cmd => 'play', uri => $N4_6D0C, sentAt => Time::HiRes::time(), cb => {} } } ],
    [ 'seek intent',       { wanted  => { uri => $N4_6D0C, playing => 1, seekIntent => { uri => $N4_6D0C, target_ms => 0, ts => Time::HiRes::time() } } } ],
    [ 'mode idle',         { mode    => 'idle' } ],
) {
    my ($name, $over) = @$case;
    my $late_pending = delete $over->{late_pending};    # set AFTER the head is known: the replay lands before LMS's own play settles
    my @f = map { decode_frame($_) } load_fixture('f18n4-same1.frames');
    @IO::Socket::INET::CALLS = ();
    @IO::Socket::INET::SYSWRITE_CALLS = ();    # 79-38: boundary posts are counted from the wire, see below

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:36', mode => 'browse',
        wanted   => { uri => $N4_6D0C, playing => 1 },
        observed => { wsConnected => 1, meta => {}, track => $N4_6D0C, status => 'playing', is_active => 1 },
        %$over,
    );
    $ctl->onEvent($_) for @f[0 .. 2];
    $ctl->pending($late_pending) if $late_pending;
    $ctl->onEvent($_) for @f[3 .. 13];

    ok(!(grep { $_->[0] eq 'pause' } @{ $ws->sent }), "F-18-N4 change 3 guard ($name): the detector does not fire")
        or diag(explain($ws->sent));
    is(scalar(grep { m{^POST /boundary} } @IO::Socket::INET::SYSWRITE_CALLS), 0, "F-18-N4 change 3 guard ($name): no boundary planted either (a deferred own play folds a pause, the boundary is the tell)");
}

# ============================================================
# Phase 82 Plan 06, Task 2: X-1 -- the seven session flags
# (sessionActive/sessionStarted/sessionPaused/deactivating/skipInitiated/
# pendingPlayConfirm/soloistBrowseActive) have ZERO hits, code AND comment,
# in the three files must_haves.truths names as the phase-wide target
# (RESEARCH "Der Rueckbau der sieben Flags, belegt"; T-8 flagged assumption:
# "das Grep-Gate zaehlt Code UND Kommentare... ein 'nur noch im Kommentar'
# ist kein Nullstand" -- Gate ohne grep -v '^#'). Plugin.pm never carried
# any of the seven flags either, so it gets the same strict code+comment
# check for free. Plugins/SpotOn/Soloist/Control.pm is the DELIBERATE
# exception: its own header comment (this file's `require_ok` target,
# lines 3-13) and onEvent's docstring name the seven flags BY NAME as the
# history this module replaces -- a legitimate, permanent reference, not
# a rollback. Control.pm is therefore checked CODE-ONLY (comments
# stripped) -- the bar T-8 actually cares about (no LIVE usage), not the
# stricter code+comment bar that would break the module's own replacement
# narrative.
# ============================================================
{
    my $SEVEN_FLAGS = qr/\b(?:sessionActive|sessionStarted|sessionPaused|deactivating|skipInitiated|pendingPlayConfirm|soloistBrowseActive)\b/;

    sub slurp_project_file {
        my ($rel) = @_;
        open(my $fh, '<', "$project_dir/$rel") or die "cannot read $rel: $!";
        local $/;
        my $src = <$fh>;
        close($fh);
        return $src;
    }

    my $soloistWs      = slurp_project_file('Plugins/SpotOn/Unified/SoloistWS.pm');
    my $protocolHandler = slurp_project_file('Plugins/SpotOn/ProtocolHandler.pm');
    my $connect        = slurp_project_file('Plugins/SpotOn/Connect.pm');
    my $plugin         = slurp_project_file('Plugins/SpotOn/Plugin.pm');
    my $control        = slurp_project_file('Plugins/SpotOn/Soloist/Control.pm');

    unlike($soloistWs, $SEVEN_FLAGS, "Plugins/SpotOn/Unified/SoloistWS.pm: none of the seven session flags (X-1)");
    unlike($protocolHandler, $SEVEN_FLAGS, "Plugins/SpotOn/ProtocolHandler.pm: none of the seven session flags (X-1)");
    unlike($connect, $SEVEN_FLAGS, "Plugins/SpotOn/Connect.pm: none of the seven session flags (X-1)");
    unlike($plugin, $SEVEN_FLAGS, "Plugins/SpotOn/Plugin.pm: none of the seven session flags (X-1)");

    (my $controlCode = $control) =~ s/^\s*#.*$//mg;
    unlike($controlCode, $SEVEN_FLAGS, "Plugins/SpotOn/Soloist/Control.pm code (history lives only in its comments): none of the seven session flags (X-1)");

    # CR-01: accessor-only, never a direct hash-slot poke.
    unlike($control, qr/\$self->\{/, "Control.pm: no direct hash-slot access (CR-01)");
    like($control, qr/^use base qw\(Slim::Utils::Accessor\)/m,
        "Control.pm: use base Slim::Utils::Accessor (CR-01)");
}

# ============================================================
# Phase 82 Plan 09, Task 1 (82-REVIEW.md CR-02): `_dispatch` must not
# clobber an open `play`-pending with waiting callbacks. `set_volume` and
# `pause` fold into the existing slot (postVolume/postPause, consumed on
# the echo and on T1); everything else (get_state here) is passed through
# without touching `pending` or the T1 timer at all.
# ============================================================

# --- CR-02 Fall A: requestVolume(55) while a play is pending -- no
# set_volume on the wire yet, pending unchanged, postVolume recorded;
# after the echo, successCb fires once and set_volume(55) follows (after
# the echo's own postSeek 0, CR-01). ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:40', observed => { wsConnected => 1, meta => { $TID => { duration => 200 } } },
    );

    my $success;
    $ctl->requestTrack($TID, 0, { successCb => sub { $success++ } });
    $ctl->requestVolume(55);

    is_deeply($ws->sent, [ [ 'play', { uri => $TID } ] ],
        "CR-02: Fall A -- set_volume(55) not yet on the wire while a play is pending");
    is($ctl->pending->{cmd}, 'play', "CR-02: Fall A -- pending remains the play");
    is($ctl->pending->{uri}, $TID, "CR-02: Fall A -- pending.uri unchanged");
    is($ctl->pending->{postVolume}, 55, "CR-02: Fall A -- pending.postVolume is 55");

    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    is($success, 1, "CR-02: Fall A -- successCb fires exactly once on the echo");
    is_deeply($ws->sent,
        [ [ 'play', { uri => $TID } ], [ 'seek', { position_ms => 0 } ], [ 'set_volume', { volume => 55 } ] ],
        "CR-02: Fall A -- set_volume(55) follows the echo's own postSeek 0");
}

# --- CR-02 Fall B: a real pause (playmode=pause) while a play is pending
# -- no pause on the wire yet, pending unchanged, postPause recorded,
# wanted.playing 0; after the echo, successCb fires once and exactly one
# pause follows (observed.status is now 'playing', set by the echo). ---
{
    local $Slim::Player::Source::PLAYMODE = 'pause';

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:41', observed => { wsConnected => 1, meta => { $TID => { duration => 200 } } },
    );

    my $success;
    $ctl->requestTrack($TID, 0, { successCb => sub { $success++ } });
    $ctl->requestPause(0);

    is_deeply($ws->sent, [ [ 'play', { uri => $TID } ] ],
        "CR-02: Fall B -- no pause on the wire while a play is pending");
    is($ctl->pending->{cmd}, 'play', "CR-02: Fall B -- pending remains the play");
    is($ctl->pending->{postPause}, 1, "CR-02: Fall B -- pending.postPause is 1");
    is($ctl->wanted->{playing}, 0, "CR-02: Fall B -- wanted.playing is 0");

    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    is($success, 1, "CR-02: Fall B -- successCb fires exactly once on the echo");
    is_deeply($ws->sent,
        [ [ 'play', { uri => $TID } ], [ 'seek', { position_ms => 0 } ], [ 'pause', {} ] ],
        "CR-02: Fall B -- exactly one pause follows, observed.status is now playing (set by the echo)");
}

# --- CR-02 Fall C: a side command WITHOUT a fold path (get_state, via the
# real production trigger `_dispatch('get_state') if logged_in` in the
# auth_state handler) is sent through while a play is pending, and touches
# neither `pending` nor the T1 timer -- the timer is only ever cleared by
# the echo/T1 themselves. ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:42', observed => { wsConnected => 1, meta => { $TID => { duration => 200 } } },
    );

    my $success;
    $ctl->requestTrack($TID, 0, { successCb => sub { $success++ } });
    $ctl->onEvent(decode_frame(load_fixture('auth_state.json')));    # logged_in:true -> _dispatch('get_state')

    is_deeply($ws->sent, [ [ 'play', { uri => $TID } ], [ 'get_state', {} ] ],
        "CR-02: Fall C -- get_state passthrough sent while a play is pending, no clobber");
    is($ctl->pending->{cmd}, 'play', "CR-02: Fall C -- pending is still the play");
    is($ctl->pending->{lastSentCmd}, 'get_state', "CR-02: Fall C -- lastSentCmd updated for the passthrough command");
    ok(scalar(@{ $ctl->pending->{cb}{successCb} }), "CR-02: Fall C -- pending->{cb}{successCb} still populated");

    # inaktiver-player-steuert-fern: auth_state.json carries is_active:false,
    # and a track_changed on a daemon that says it is inactive is a MIRROR,
    # never the own echo (IA-6). Live, the own play's echo is always preceded
    # by the own-activation device_changed (82-17 Laeufe 1/3, fremd RED-2
    # setup) -- the realistic order is restored here; this block's subject
    # (the get_state passthrough leaves pending and T1 alone) is unchanged.
    $ctl->onEvent({ type => 'device_changed', is_active => 1, device_name => 'lavender-UAT' });
    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));
    is($success, 1, "CR-02: Fall C -- the echo still releases successCb after the passthrough command");

    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 0.6);
    is($success, 1, "CR-02: Fall C -- T1 has already been cleared by the echo -- a later fire_due is a no-op");
}

# --- CR-02 Fall D: T1 survives folding a side command -- requestVolume(55)
# folds (no echo arrives), then fire_due(+0.6) releases T1: successCb
# fires exactly once and set_volume(55) goes out afterwards. Without the
# `killTimers` move behind the fold decision, this pending would have
# neither a callback release nor a volume push. ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:43', observed => { wsConnected => 1, meta => { $TID => { duration => 200 } } },
    );

    my $success;
    $ctl->requestTrack($TID, 0, { successCb => sub { $success++ } });
    $ctl->requestVolume(55);

    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 0.6);

    is($success, 1, "CR-02: Fall D -- T1 survives the fold, successCb released exactly once");
    is_deeply($ws->sent,
        [ [ 'play', { uri => $TID } ], [ 'set_volume', { volume => 55 } ] ],
        "CR-02: Fall D -- set_volume(55) goes out after T1 releases the folded volume");
}

# --- CR-02 Fall E: a folded pause is not replayed verbatim -- it is
# re-decided via _reconcile('requestPause') against the FRESH observed
# state. 82-22 WR-07 (Review Runde 2): the echo now sets observed.status
# UNCONDITIONALLY ("playing" -- the daemon confirming it just started this
# title always outranks a stale prior notification), so the stray
# `playback_changed status=paused` delivered just before the echo no
# longer survives it. The replay therefore correctly sees the daemon
# genuinely playing and DOES send the pause the user actually asked for --
# this is the corrected behavior; the OLD assertion ("nothing sent")
# documented exactly the asymmetric-status class of bug WR-07 closes (a
# stale 'paused' silently swallowing a real pending pause is the T-4
# Split-Brain failure mode). ---
{
    local $Slim::Player::Source::PLAYMODE = 'pause';

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:44', observed => { wsConnected => 1, meta => { $TID => { duration => 200 } } },
    );

    my $success;
    $ctl->requestTrack($TID, 0, { successCb => sub { $success++ } });
    $ctl->requestPause(0);
    is($ctl->pending->{postPause}, 1, "CR-02: Fall E -- pending.postPause is 1 before the echo");

    $ctl->onEvent({ type => 'playback_changed', status => 'paused' });
    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    is($success, 1, "CR-02: Fall E -- successCb fires exactly once on the echo");
    is_deeply($ws->sent,
        [ [ 'play', { uri => $TID } ], [ 'seek', { position_ms => 0 } ], [ 'pause', {} ] ],
        "CR-02: Fall E -- WR-07: the echo's authoritative status means the folded pause DOES replay now (was silently swallowed before)");
}

# ============================================================
# Phase 82 Plan 09, Task 2 (82-REVIEW.md WR-04, WR-06)
# ============================================================

# --- WR-04 Fall A: correlated error (no side command dispatched since the
# play) -- errorCb fires with PROBLEM_OPENING, pending cleared. Baseline,
# unchanged by this plan. ---
{
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:ee:50', observed => { wsConnected => 1, meta => {} });

    my ($error_type, $error_msg);
    $ctl->requestTrack($TID, 0, { errorCb => sub { ($error_type, $error_msg) = @_; } });

    $ctl->onEvent({ type => 'error', message => 'daemon rejected play' });

    is($error_type, 'PROBLEM_OPENING', "WR-04: Fall A -- correlated error fires errorCb");
    is($ctl->pending, undef, "WR-04: Fall A -- pending cleared");
}

# --- WR-04 Fall B: uncorrelated error -- a passthrough get_state ran since
# the play (lastSentCmd is now 'get_state'), so an error WITHOUT a
# `command` field must not abort the still-open play. ---
{
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:ee:51', observed => { wsConnected => 1, meta => { $TID => { duration => 200 } } });

    my ($success, $error_type);
    $ctl->requestTrack($TID, 0, { successCb => sub { $success++ }, errorCb => sub { $error_type = $_[0] } });
    $ctl->onEvent(decode_frame(load_fixture('auth_state.json')));    # -> _dispatch('get_state'), lastSentCmd changes
    is($ctl->pending->{lastSentCmd}, 'get_state', "WR-04: Fall B -- lastSentCmd updated by the passthrough get_state");

    $ctl->onEvent({ type => 'error', message => 'get_state failed' });

    ok(!$error_type, "WR-04: Fall B -- uncorrelated error does not abort the open play");
    ok(defined $ctl->pending, "WR-04: Fall B -- pending survives the uncorrelated error");
    is($ctl->pending->{cmd}, 'play', "WR-04: Fall B -- pending is still the play");

    # inaktiver-player-steuert-fern: see CR-02 Fall C -- auth_state.json said
    # is_active:false, so the own echo needs the own-activation
    # device_changed before it (live order, 82-17); subject unchanged.
    $ctl->onEvent({ type => 'device_changed', is_active => 1, device_name => 'lavender-UAT' });
    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));
    is($success, 1, "WR-04: Fall B -- successCb still fires once on the later echo");
}

# --- WR-04 Fall C: error frame carries a `command` field -- it decides
# outright, in both directions, regardless of lastSentCmd. ---
{
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:ee:52', observed => { wsConnected => 1, meta => {} });

    my ($success, $error_type);
    $ctl->requestTrack($TID, 0, { successCb => sub { $success++ }, errorCb => sub { $error_type = $_[0] } });

    $ctl->onEvent({ type => 'error', command => 'add_to_queue', message => 'queue rejected' });
    ok(!$error_type, "WR-04: Fall C -- error with a mismatched command field is logged, not applied to pending");
    ok(defined $ctl->pending, "WR-04: Fall C -- pending survives a mismatched command field");

    $ctl->onEvent({ type => 'error', command => 'play', message => 'play failed' });
    is($error_type, 'PROBLEM_OPENING', "WR-04: Fall C -- error with a matching command field fires errorCb");
    is($ctl->pending, undef, "WR-04: Fall C -- pending cleared on the matching command field");
}

# --- WR-04 Fall D: the auth-error branch is a STATE finding, not a
# command finding -- it fires regardless of lastSentCmd. ---
{
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:ee:53', observed => { wsConnected => 1, meta => { $TID => { duration => 200 } } });

    my ($success, $error_type);
    $ctl->requestTrack($TID, 0, { successCb => sub { $success++ }, errorCb => sub { $error_type = $_[0] } });
    $ctl->onEvent(decode_frame(load_fixture('auth_state.json')));    # -> _dispatch('get_state'), lastSentCmd changes
    is($ctl->pending->{lastSentCmd}, 'get_state', "WR-04: Fall D -- lastSentCmd is a side command before the auth error");

    $ctl->onEvent(decode_frame(load_fixture('error.json')));    # "requires authentication"

    is($error_type, 'PROBLEM_OPENING', "WR-04: Fall D -- auth error still fires errorCb regardless of lastSentCmd");
    is($ctl->observed->{paired}, 0, "WR-04: Fall D -- observed.paired set to 0");
    is($ctl->pending, undef, "WR-04: Fall D -- pending cleared by the auth error");
}

# --- WR-06 Fall E: no transport at all -- _dispatch must fire the
# caller's errorCb instead of silently returning 0. ---
{
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:ee:54', observed => { wsConnected => 1, meta => {} });
    $daemon->{ws} = undef;    # simulates a gone/dead transport (WR-02 respawn path)

    my ($error_type, $error_msg);
    $ctl->requestTrack($TID, 0, { errorCb => sub { ($error_type, $error_msg) = @_; } });

    is($error_type, 'PROBLEM_OPENING', "WR-06: errorCb fires with PROBLEM_OPENING when the transport is gone");
    is($ctl->pending, undef, "WR-06: pending stays empty when the transport is gone");
}

# ============================================================
# Phase 82 Plan 09, Task 3 (82-REVIEW.md WR-03): `shutdown` and
# `_transportClosed` must also release `_awaitMeta` and kill its
# `_tMetaFire` timer -- otherwise a successCb waiting on noteDuration/
# T_meta fires as a SUCCESS after the daemon is already torn down.
# ============================================================

# --- WR-03 Fall A: shutdown with an open _awaitMeta wait. ---
{
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:ee:60', observed => { wsConnected => 1, meta => {} });

    my ($success, $error_type);
    $ctl->requestTrack($TID, 0, { successCb => sub { $success++ }, errorCb => sub { $error_type = $_[0] } });
    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));    # duration unknown -> awaitMeta armed

    ok(!$success, "WR-03: Fall A -- successCb still waiting on metadata after the echo (duration unknown)");
    ok(defined $ctl->_awaitMeta, "WR-03: Fall A -- _awaitMeta armed after the echo");

    $ctl->shutdown;

    is($error_type, 'PROBLEM_OPENING', "WR-03: Fall A -- shutdown releases the awaitMeta wait with errorCb");
    is($ctl->_awaitMeta, undef, "WR-03: Fall A -- _awaitMeta cleared by shutdown");

    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 2);
    ok(!$success, "WR-03: Fall A -- the late T_meta timer no longer fires successCb after shutdown");
}

# --- WR-03 Fall B: _transportClosed with an open _awaitMeta wait. ---
{
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:ee:61', observed => { wsConnected => 1, meta => {} });

    my ($success, $error_type);
    $ctl->requestTrack($TID, 0, { successCb => sub { $success++ }, errorCb => sub { $error_type = $_[0] } });
    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));    # duration unknown -> awaitMeta armed
    ok(defined $ctl->_awaitMeta, "WR-03: Fall B -- _awaitMeta armed after the echo");

    $ctl->onEvent({ type => '_transport', state => 'closed' });

    is($error_type, 'PROBLEM_OPENING', "WR-03: Fall B -- _transportClosed releases the awaitMeta wait with errorCb");
    is($ctl->_awaitMeta, undef, "WR-03: Fall B -- _awaitMeta cleared by _transportClosed");

    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 2);
    ok(!$success, "WR-03: Fall B -- the late T_meta timer no longer fires successCb after the transport closed");
}

# ============================================================
# Phase 82 Plan 10, Task 1 (82-REVIEW.md CR-04): requestPause/
# requestResume/requestVolume gain a song-criterion guard -- only forward
# to the daemon while LMS is actually on a spoton:// track/episode. `mode`
# also gains its missing browse -> idle path (`leaveBrowse`). The three
# INTERNAL requestVolume call sites (H6-Ersatz in requestTrack, the
# folded-volume replays in _t1Fire and the echo branch) pass
# `{ force => 1 }` and must keep working even while LMS is on a foreign
# title -- Fall F and G pin that down.
# ============================================================

# --- CR-04 Fall A: unpause on a foreign LMS title -- nothing sent,
# wanted.playing not forced to 1 ---
{
    my $mac = 'aa:bb:cc:dd:ee:70';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac, mode => 'browse', observed => { wsConnected => 1, meta => {}, status => 'paused' },
    );
    foreign_track($mac);

    $ctl->requestResume;

    is_deeply($ws->sent, [], "CR-04: Fall A -- unpause on a foreign LMS title -- nothing sent");
    is($ctl->wanted->{playing}, undef, "CR-04: Fall A -- wanted.playing not forced to 1");
}

# --- CR-04 Fall B: unpause on our own title -- ['play',{}] still goes out ---
{
    my $mac = 'aa:bb:cc:dd:ee:71';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac, mode => 'browse', observed => { wsConnected => 1, meta => {}, status => 'paused' },
    );
    own_track($mac);

    $ctl->requestResume;

    is_deeply($ws->sent, [ [ 'play', {} ] ], "CR-04: Fall B -- unpause on our own title -- ['play',{}]");
}

# --- CR-04 Fall C: volume push on a foreign LMS title -- nothing sent ---
{
    my $mac = 'aa:bb:cc:dd:ee:72';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac, mode => 'browse', observed => { wsConnected => 1, meta => {}, volume => 40 },
    );
    foreign_track($mac);

    $ctl->requestVolume(55);

    is_deeply($ws->sent, [], "CR-04: Fall C -- volume push on a foreign LMS title -- nothing sent");
}

# --- CR-04 Fall D: stop without an owned title -- exactly one pause still
# goes out (T-82-64, never deadened) and mode returns to idle ---
{
    my $mac = 'aa:bb:cc:dd:ee:73';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac, mode => 'browse', observed => { wsConnected => 1, meta => {}, status => 'playing' },
    );
    no_track($mac);

    $ctl->requestPause(1);

    is_deeply($ws->sent, [ [ 'pause', {} ] ],
        "CR-04: Fall D -- stop without an owned title -- exactly one pause (T-82-64)");
    is($ctl->mode, 'idle', "CR-04: Fall D -- mode returns to idle (leaveBrowse)");
}

# --- CR-04 Fall E: plain pause on a foreign LMS title -- nothing sent,
# mode still returns to idle ---
{
    my $mac = 'aa:bb:cc:dd:ee:74';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac, mode => 'browse', observed => { wsConnected => 1, meta => {}, status => 'playing' },
    );
    foreign_track($mac);

    $ctl->requestPause(0);

    is_deeply($ws->sent, [], "CR-04: Fall E -- plain pause on a foreign LMS title -- nothing sent");
    is($ctl->mode, 'idle', "CR-04: Fall E -- mode returns to idle (leaveBrowse) even without a stop");
}

# --- CR-04 Fall F: H6-Ersatz stays open -- a Treffer requestTrack (daemon
# already reports this uri, resolves synchronously, no pending play)
# still pushes the client's volume even though the LMS song does not yet
# point at the new title (force bypasses the guard). Carries an explicit
# anchor (WR-01, 82-31) so this stays about the volume push, not the
# playing-twin -- without it the removed !$playing needsSeek exception
# would add an unrelated leading seek to $ws->sent. ---
{
    my $mac = 'aa:bb:cc:dd:ee:75';
    Slim::Player::Client::getClient($mac)->volume(77);
    foreign_track($mac);

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac,
        observed => { wsConnected => 1, meta => { $TID => { duration => 200 } }, track => $TID, status => 'playing', anchor => { position_ms => 0, seen_at => Time::HiRes::time() } },
    );
    is($ctl->mode, 'idle', "CR-04: Fall F -- fresh control starts in idle");

    $ctl->requestTrack($TID, 0, {});

    is($ctl->mode, 'browse', "CR-04: Fall F -- requestTrack flips mode to browse");
    # The Treffer path never dispatches 'play' -- pending, if set at all,
    # is only the volume push's own D-06 echo-tracking slot below, never a
    # play awaiting track_changed.
    ok(!$ctl->pending || $ctl->pending->{cmd} ne 'play',
        "CR-04: Fall F -- Treffer resolves synchronously, no PLAY pending");
    is_deeply($ws->sent, [ [ 'set_volume', { volume => 77 } ] ],
        "CR-04: Fall F -- H6-Ersatz volume push still goes out despite the foreign LMS title (force)");
}

# --- CR-04 Fall G: folded volume push stays open -- a play-pending's
# postVolume still applies after the echo even though the LMS song is
# still foreign when the echo arrives (force bypasses the guard) ---
{
    my $mac = 'aa:bb:cc:dd:ee:76';
    Slim::Player::Client::getClient($mac)->volume(88);
    foreign_track($mac);

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac, observed => { wsConnected => 1, meta => { $TID => { duration => 200 } } },
    );

    $ctl->requestTrack($TID, 0, {});

    is_deeply($ws->sent, [ [ 'play', { uri => $TID } ] ],
        "CR-04: Fall G -- play sent, set_volume folded (not sent yet) while the LMS title is still foreign");
    is($ctl->pending->{postVolume}, 88, "CR-04: Fall G -- pending.postVolume recorded despite the foreign LMS title");

    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    is_deeply($ws->sent,
        [ [ 'play', { uri => $TID } ], [ 'seek', { position_ms => 0 } ], [ 'set_volume', { volume => 88 } ] ],
        "CR-04: Fall G -- set_volume(88) still goes out after the echo (force)");
}

# --- CR-04 Fall H: leaveBrowse only sets state -- mode idle, wanted.uri
# undefined, nothing sent ---
{
    my $mac = 'aa:bb:cc:dd:ee:77';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac, mode => 'browse', observed => { wsConnected => 1, meta => {} },
    );
    $ctl->wanted({ uri => $TID, position_ms => 0, playing => 1, volume => 50 });
    my $sentBefore = scalar @{ $ws->sent };

    $ctl->leaveBrowse;

    is($ctl->mode, 'idle', "CR-04: Fall H -- leaveBrowse sets mode to idle");
    is($ctl->wanted->{uri}, undef, "CR-04: Fall H -- leaveBrowse clears wanted.uri");
    is(scalar(@{ $ws->sent }), $sentBefore, "CR-04: Fall H -- leaveBrowse sends nothing, only a state change");
}

# ============================================================
# Phase 82 Plan 10, Task 3 (82-REVIEW.md IN-02): the reconnect-in-running-
# app-session branch (playback_state, is_active+playing, mode idle) used
# to copy the WHOLE observed hash into `wanted` (`{ %{ $self->observed } }`)
# -- sharing meta/errorsReported/anchor as the SAME hash references
# between `wanted` and `observed`. Explicit field assignment now, same
# pattern as the device_changed branch.
# ============================================================

# --- IN-02: wanted gets an explicit field copy, not a shared reference to
# observed's meta/errorsReported/anchor ---
{
    my $mac = 'aa:bb:cc:dd:ee:78';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => $mac,
        observed => {
            wsConnected    => 1,
            meta           => { $TID => { duration => 200 } },
            errorsReported => { 'drift:foo' => 1 },
            anchor         => { position_ms => 5000, timestamp_ms => 1000, speed => 1, seen_at => time() },
        },
    );
    is($ctl->mode, 'idle', "IN-02: fresh control starts in idle");

    $ctl->onEvent({
        type      => 'playback_state',
        item      => { uri => $TID },
        status    => 'playing',
        is_active => 1,
        volume    => 60,
        position  => { position_ms => 5000, timestamp_ms => 1000, speed => 1 },
    });

    is($ctl->mode, 'connect', "IN-02: reconnect-in-running-app-session transfers idle -> connect");
    is($ctl->wanted->{uri}, $TID, "IN-02: wanted.uri copied from observed.track (there is no observed.uri)");
    ok(!exists $ctl->wanted->{meta}, "IN-02: wanted does not contain meta (observation, not a wish)");
    ok(!exists $ctl->wanted->{errorsReported}, "IN-02: wanted does not contain errorsReported");
    ok(!exists $ctl->wanted->{anchor}, "IN-02: wanted does not contain anchor");

    # Beyond key-absence: prove the two hashes are genuinely independent
    # references, not merely differently-shaped by coincidence -- writing
    # through wanted must never leak into observed.
    $ctl->wanted->{volume} = 999;
    isnt($ctl->observed->{volume}, 999,
        "IN-02: writing through wanted.volume does not mutate observed.volume (no shared hash ref)");
}

# ============================================================
# G1-FIX (82-16 Task 1, F1/H-vi; 82-19 Task 2, F2 -- turns 82-15's G1-MESS
# Ist-Zustand characterization into Soll cases, per 82-G1-MESSUNG.md's
# Fix-Zuordnung as corrected by 82-19): H-v is bestaetigt (F1 applies,
# observed.seekIssued suppresses the duplicate correction). H-vi is
# bestaetigt -- the arm fires whenever a track is observed (armed =>
# defined observed.track), independent of status.
#
# 82-19 F2 (H-iii(async): berichtigt von "greift nicht" auf "greift" --
# 82-G1-MESSUNG.md ## Berichtigung 82-19 -- Fix-Zuordnung): the async arm
# (_armAsync/SimpleAsyncHTTP) and the `sync` channel marker are GONE.
# Every armed dispatch now arms over the sync loopback socket
# (_armSync -> _loopbackPost), on BOTH call sites (getNextTrack's Schritt 4
# AND onStream's Seek-Pfad (2)) -- so observed.seekIssued is written
# synchronously, before onStream's requestTrack (running in the SAME LMS
# command) can ask _seekAlreadyIssued anything. This closes the live gap
# 82-G1-MESSUNG.md ## Berichtigung 82-19 -- Zuschreibung des Doppel-Seeks
# documents: the getNextTrack dispatch used to complete its arm+send in an
# ASYNC callback that only fired after a real network round-trip, so
# onStream's synchronous dispatch could (and live, regularly did) run its
# own _seekAlreadyIssued check BEFORE that callback ever fired -- both
# sides sent. Falls A-C below are flipped from the pre-82-19 Bestandsfall
# (which asserted the OLD async-survives shape) to the F2 Soll shape (sync
# arm on whichever dispatch actually completes first -- always the FIRST
# call now, since both run synchronously to completion before the second
# call runs at all). Falls G and H (new) pin the exact live gap F2 closes,
# unit-level, with the HTTP-client stub in 'defer' mode so the callback
# genuinely never fires -- the closest unit-level model of the live
# network round-trip that never completed in time.
# ============================================================

# --- G1-FIX: Fall A -- Lauf-4-Replay (playing, stale anchor 213000ms):
# getNextTrack(X,0) then onStream(X,0,seek) -- exactly one seek 0
# (getNextTrack's Treffer-Zweig correction survives), one sync arm
# recorded (over the loopback socket, BEFORE the seek lands in $ws->sent
# -- same ordering idiom as "rewind"), zero async arm (the channel is
# gone, 82-19 F2), no play carries a uri, successCb fired once ---
{
    @IO::Socket::INET::REQUESTS               = ();
    @IO::Socket::INET::CALLS                  = ();
    @Slim::Networking::SimpleAsyncHTTP::CALLS = ();
    local $Slim::Networking::SimpleAsyncHTTP::AUTO_FIRE = 'ok';

    my ($ctl, $daemon, $ws) = fresh_control(
        observed => {
            wsConnected => 1, paired => 1, meta => {},
            track       => $TID, status => 'playing',
            anchor      => { position_ms => 213000, seen_at => Time::HiRes::time() },
        },
    );

    my $success;
    $ctl->requestTrack($TID, 0, { source => 'getNextTrack', successCb => sub { $success++ } });
    $ctl->requestTrack($TID, 0, { source => 'onStream', seek => 1 });

    is_deeply(
        [ grep { $_->[0] eq 'seek' } @{ $ws->sent } ],
        [ [ 'seek', { position_ms => 0 } ] ],
        "G1-FIX: Fall A -- exactly one seek 0 (H-v: the second requestTrack of the same LMS command is suppressed)"
    );
    is(scalar(grep { $_->[0] eq 'play' && exists $_->[1]{uri} } @{ $ws->sent }), 0,
        "G1-FIX: Fall A -- no play carries a uri (Treffer branch, the daemon already reports X)");
    # _armSync runs synchronously, before $send in the same _dispatch call
    # (82-19 F2) -- the arm is recorded before the seek lands in $ws->sent,
    # the same ordering guarantee the "rewind" Bestandsfall checks.
    is(scalar(@IO::Socket::INET::REQUESTS), 1,
        "G1-FIX: Fall A -- one sync arm (getNextTrack's dispatch, the one that survives -- arm recorded before the seek is sent)");
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::CALLS), 0,
        "G1-FIX: Fall A -- no async arm -- the async channel is gone (82-19 F2)");
    is($success, 1, "G1-FIX: Fall A -- successCb fired once on the getNextTrack Treffer");
}

# --- G1-FIX: Fall B -- Arm-Ausfall degrade-open: same fixture as A, but
# the sync arm's socket connect fails (82-19 F2: the failure mode moved
# from the HTTP-client stub's error callback to the socket stub's $FAIL)
# -- still exactly one seek (the failed arm does not block the send,
# T-77-10), plus the "sync seek-arm failed" warning; no second attempt ---
{
    @Slim::Networking::SimpleAsyncHTTP::CALLS = ();
    @Slim::Utils::Log::WARNINGS               = ();
    local $IO::Socket::INET::FAIL = 1;

    my ($ctl, $daemon, $ws) = fresh_control(
        observed => {
            wsConnected => 1, paired => 1, meta => {},
            track       => $TID, status => 'playing',
            anchor      => { position_ms => 213000, seen_at => Time::HiRes::time() },
        },
    );

    $ctl->requestTrack($TID, 0, { source => 'getNextTrack', successCb => sub { } });
    $ctl->requestTrack($TID, 0, { source => 'onStream', seek => 1 });

    is(scalar(grep { $_->[0] eq 'seek' } @{ $ws->sent }), 1,
        "G1-FIX: Fall B -- still exactly one seek despite the failed arm (degrade-open, kein zweiter Versuch)");
    ok((grep { /sync seek-arm failed/ } @Slim::Utils::Log::WARNINGS),
        "G1-FIX: Fall B -- 'sync seek-arm failed' warning logged");
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::CALLS), 0,
        "G1-FIX: Fall B -- no async arm attempted -- the async channel is gone (82-19 F2)");
}

# --- G1-FIX: Fall C -- Lauf-3-Replay (paused, frozen anchor 209000ms):
# exactly one seek 0 (H-v holds even while paused), two bare play
# (unchanged by F1/H-vi -- Schritt 4's own bare resume plus Seek-Pfad
# (2)'s unconditional resume play, neither carries a uri). H-vi bestaetigt
# (82-G1-MESSUNG.md Verdikt): the arm now fires even though the daemon is
# paused (armed => defined observed.track, not armed => $playing); the
# arm is the sync loopback arm (82-19 F2), not the removed async channel ---
{
    @IO::Socket::INET::REQUESTS               = ();
    @IO::Socket::INET::CALLS                  = ();
    @Slim::Networking::SimpleAsyncHTTP::CALLS = ();
    local $Slim::Networking::SimpleAsyncHTTP::AUTO_FIRE = 'ok';

    my ($ctl, $daemon, $ws) = fresh_control(
        observed => {
            wsConnected => 1, paired => 1, meta => {},
            track       => $TID, status => 'paused',
            anchor      => { position_ms => 209000, seen_at => Time::HiRes::time() },
        },
    );

    $ctl->requestTrack($TID, 0, { source => 'getNextTrack', successCb => sub { } });
    $ctl->requestTrack($TID, 0, { source => 'onStream', seek => 1 });

    is(scalar(grep { $_->[0] eq 'seek' } @{ $ws->sent }), 1,
        "G1-FIX: Fall C -- exactly one seek 0 (position drift is corrected even while paused, H-v holds)");
    is(scalar(grep { $_->[0] eq 'play' && !exists $_->[1]{uri} } @{ $ws->sent }), 2,
        "G1-FIX: Fall C -- two bare play (no uri, unchanged by F1/H-vi)");
    is(scalar(grep { $_->[0] eq 'play' && exists $_->[1]{uri} } @{ $ws->sent }), 0,
        "G1-FIX: Fall C -- no play carries a uri");
    is(scalar(@IO::Socket::INET::REQUESTS), 1,
        "G1-FIX: Fall C -- H-vi bestaetigt: the sync arm now fires even though the daemon is paused (armed => defined observed.track, not \$playing)");
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::CALLS), 0,
        "G1-FIX: Fall C -- no async arm -- the async channel is gone (82-19 F2)");
}

# --- G1-FIX: Fall D -- window expired: after Fall A's seek, the recorded
# seekIssued marker is aged past SEEK_ISSUED_WINDOW_S (anchor stays
# stale) -- a further requestTrack(X, 0, onStream, seek) sends its OWN
# seek 0; the suppression is time-bounded, not permanent ---
{
    @IO::Socket::INET::REQUESTS               = ();
    @Slim::Networking::SimpleAsyncHTTP::CALLS = ();
    local $Slim::Networking::SimpleAsyncHTTP::AUTO_FIRE = 'ok';

    my ($ctl, $daemon, $ws) = fresh_control(
        observed => {
            wsConnected => 1, paired => 1, meta => {},
            track       => $TID, status => 'playing',
            anchor      => { position_ms => 213000, seen_at => Time::HiRes::time() },
        },
    );

    $ctl->requestTrack($TID, 0, { source => 'getNextTrack', successCb => sub { } });
    is(scalar(grep { $_->[0] eq 'seek' } @{ $ws->sent }), 1,
        "G1-FIX: Fall D -- one seek after the first requestTrack");

    # SEEK_ISSUED_WINDOW_S is 1s -- age the recorded marker past it
    # without sleeping the test.
    $ctl->observed->{seekIssued}{at} -= 2;

    $ctl->requestTrack($TID, 0, { source => 'onStream', seek => 1 });
    is(scalar(grep { $_->[0] eq 'seek' } @{ $ws->sent }), 2,
        "G1-FIX: Fall D -- a second seek IS sent once the suppression window has expired");
}

# --- G1-FIX: Fall E -- anchor renewed: a position_sync frame matching the
# just-issued seek arrives between the two requestTrack calls -- the
# second requestTrack still does not send a further seek (seekIssued is
# still within its window; a fresh, matching anchor makes the field
# redundant, not wrong -- either one alone already prevents the extra
# seek) ---
{
    @IO::Socket::INET::REQUESTS               = ();
    @Slim::Networking::SimpleAsyncHTTP::CALLS = ();
    local $Slim::Networking::SimpleAsyncHTTP::AUTO_FIRE = 'ok';

    my ($ctl, $daemon, $ws) = fresh_control(
        observed => {
            wsConnected => 1, paired => 1, meta => {},
            track       => $TID, status => 'playing',
            anchor      => { position_ms => 213000, seen_at => Time::HiRes::time() },
        },
    );

    $ctl->requestTrack($TID, 0, { source => 'getNextTrack', successCb => sub { } });
    is(scalar(grep { $_->[0] eq 'seek' } @{ $ws->sent }), 1,
        "G1-FIX: Fall E -- one seek after the first requestTrack");

    $ctl->onEvent({
        type     => 'position_sync',
        position => { position_ms => 0, timestamp_ms => 0, speed => 1 },
    });

    $ctl->requestTrack($TID, 0, { source => 'onStream', seek => 1 });
    is(scalar(grep { $_->[0] eq 'seek' } @{ $ws->sent }), 1,
        "G1-FIX: Fall E -- still exactly one seek (fresh anchor already matches, seekIssued also still valid)");
}

# --- G1-FIX: Fall F -- transport loss clears seekIssued: a `_transport
# closed` pseudo-frame after a seek was recorded removes the marker, so a
# LATER reconnect on the same uri is free to correct again (same
# discipline as observed.expectEcho, WR-01) ---
{
    local $Slim::Networking::SimpleAsyncHTTP::AUTO_FIRE = 'ok';

    my ($ctl, $daemon, $ws) = fresh_control(
        observed => {
            wsConnected => 1, paired => 1, meta => {},
            track       => $TID, status => 'playing',
            anchor      => { position_ms => 213000, seen_at => Time::HiRes::time() },
        },
    );

    $ctl->requestTrack($TID, 0, { source => 'getNextTrack', successCb => sub { } });
    ok(defined $ctl->observed->{seekIssued}, "G1-FIX: Fall F -- seekIssued recorded after the seek");

    $ctl->onEvent({ type => '_transport', state => 'closed' });
    ok(!defined $ctl->observed->{seekIssued}, "G1-FIX: Fall F -- seekIssued cleared after transport loss");
}

# --- G1-FIX: Fall G -- the live G-1 Laeufe 2/3 finding, unit-pinned: same
# fixture as A, but the HTTP-client stub never fires (AUTO_FIRE=defer),
# and ONLY getNextTrack's requestTrack runs (no onStream call at all). On
# the pre-82-19 code, an armed&&!sync dispatch went through _armAsync,
# which handed $send to the HTTP-client stub's ok callback -- with
# AUTO_FIRE=defer that callback never fires, so $send (and the
# observed.seekIssued write inside it) never runs either: this is the
# unit-level model of the live gap 82-G1-MESSUNG.md ## Nachmessung 82-17
# ## G-1 measured (getNextTrack's async arm waiting on a real network
# round-trip that, live, sometimes did not complete before onStream's own
# synchronous dispatch ran its _seekAlreadyIssued check). AUTO_FIRE=defer,
# not 'ok', is deliberate: with 'ok' the stub's post() fires its success
# callback SYNCHRONOUSLY inside post() (t/44 stub, see 'post' above) --
# seekIssued would already be set on the OLD code and this case would
# never be RED, silently hiding exactly the live gap it exists to pin
# (82-G1-MESSUNG.md ## Nachmessung 82-17 -- "t/44s G1-FIX:-Testfaelle
# verifizieren dieses Timing nicht"). ---
{
    @IO::Socket::INET::REQUESTS               = ();
    @IO::Socket::INET::CALLS                  = ();
    @Slim::Networking::SimpleAsyncHTTP::CALLS = ();
    local $Slim::Networking::SimpleAsyncHTTP::AUTO_FIRE = 'defer';

    my ($ctl, $daemon, $ws) = fresh_control(
        observed => {
            wsConnected => 1, paired => 1, meta => {},
            track       => $TID, status => 'playing',
            anchor      => { position_ms => 213000, seen_at => Time::HiRes::time() },
        },
    );

    $ctl->requestTrack($TID, 0, { source => 'getNextTrack', successCb => sub { } });

    ok(defined $ctl->observed->{seekIssued},
        "G1-FIX: Fall G -- observed.seekIssued is defined immediately after the getNextTrack dispatch returns, "
        . "without firing any callback by hand (Laeufe 2/3, 82-G1-MESSUNG.md ## Nachmessung 82-17 ## G-1)");
    is($ctl->observed->{seekIssued}{position_ms}, 0,
        "G1-FIX: Fall G -- observed.seekIssued carries position_ms 0");
    is(scalar(@IO::Socket::INET::REQUESTS), 1,
        "G1-FIX: Fall G -- one sync seek-arm POST recorded via the loopback socket");
    like(${ $IO::Socket::INET::REQUESTS[0]{bufref} }, qr{^POST /seek-arm},
        "G1-FIX: Fall G -- the recorded request is POST /seek-arm");
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::CALLS), 0,
        "G1-FIX: Fall G -- no async /seek-arm POST -- the async channel is gone (82-19 F2)");
}

# --- G1-FIX: Fall H -- arm-vor-send on the getNextTrack path, recorded AT
# the moment of the first $ws->sent entry (not inferred from the final
# shape of $ws->sent, the way "rewind" does it -- that only works because
# rewind's send follows synchronously; this records the fact directly, so
# it exercises the exact call site "rewind" never touches). Same fixture
# and AUTO_FIRE=defer as Fall G, for the same reason (see above). The
# wrapper below saves the ORIGINAL Test::FakeWs::sendCommand as a coderef
# BEFORE localizing it (calling through the name here would recurse
# forever) and returns the original's return value (sendCommand's return
# is send_success, t/44:393-397 -- an unreturned falsy would route $send
# into the arm-leak branch on a mismatched premise, Control.pm's `unless
# ($ok)` path) ---
{
    @IO::Socket::INET::REQUESTS               = ();
    @Slim::Networking::SimpleAsyncHTTP::CALLS = ();
    local $Slim::Networking::SimpleAsyncHTTP::AUTO_FIRE = 'defer';

    my ($ctl, $daemon, $ws) = fresh_control(
        observed => {
            wsConnected => 1, paired => 1, meta => {},
            track       => $TID, status => 'playing',
            anchor      => { position_ms => 213000, seen_at => Time::HiRes::time() },
        },
    );

    my @requests_at_send;
    my $orig_send_command = \&Test::FakeWs::sendCommand;
    {
        no warnings 'redefine';
        local *Test::FakeWs::sendCommand = sub {
            push @requests_at_send, scalar(@IO::Socket::INET::REQUESTS);
            return $orig_send_command->(@_);
        };

        $ctl->requestTrack($TID, 0, { source => 'getNextTrack', successCb => sub { } });
    }

    is(scalar(@requests_at_send), 1,
        "G1-FIX: Fall H -- exactly one \$ws->sendCommand call recorded (the seek)");
    is($requests_at_send[0], 1,
        "G1-FIX: Fall H -- arm-vor-send: the sync arm was already recorded (REQUESTS==1) at the moment the first "
        . "\$ws->sent entry (seek) was sent, on the getNextTrack call site");
}

# ============================================================
# G2-G3 (82-17, Aktivierungs-Echo statt Transfer-in): a device_changed
# is_active:true frame that the daemon sends when OUR OWN just-issued play
# starts streaming ("became active device") must not be read as a transfer
# from the Spotify app -- that misclassification is the shared root cause
# of G-2 (LMS displays the previous session's title/length) and G-3 (LMS'
# stop stops reaching the daemon), see 82-17-PLAN.md <objective>. Fall
# names A-G (including D') per the plan's <behavior> section.
# ============================================================

my $TID_46EU = 'spotify:track:46eu3SBuFCXWsPT39Yg3tJ';    # Lauf 1: the restored previous session's title
my $TID_4PTG = 'spotify:track:4PTG3Z6ehGkBFwjybzWkR8';    # Lauf 1: the requested title

# --- G2-G3: Fall A -- own play still open (pending): mode stays browse, no
# start, wanted/pending untouched, observed.is_active set ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mode     => 'browse',
        observed => { wsConnected => 1, paired => 1, meta => {}, track => $TID_46EU, status => 'playing' },
    );

    $ctl->requestTrack($TID_4PTG, 0, { source => 'getNextTrack', successCb => sub { } });
    ok($ctl->pending && $ctl->pending->{cmd} eq 'play' && $ctl->pending->{uri} eq $TID_4PTG,
        "G2-G3: Fall A setup -- an own play is pending for the requested track");
    @Slim::Player::Client::EXECUTED = ();

    $ctl->onEvent({ type => 'device_changed', is_active => 1, device_name => 'lavender-pa' });

    is($ctl->mode, 'browse', "G2-G3: Fall A -- mode stays browse (own activation echo, not a transfer)");
    is_deeply(\@Slim::Player::Client::EXECUTED, [], "G2-G3: Fall A -- no spottyconnect start emitted");
    is($ctl->wanted->{uri}, $TID_4PTG, "G2-G3: Fall A -- wanted.uri unchanged (the requested track)");
    is($ctl->observed->{is_active}, 1, "G2-G3: Fall A -- observed.is_active set to 1");
    ok($ctl->pending && $ctl->pending->{cmd} eq 'play' && $ctl->pending->{uri} eq $TID_4PTG,
        "G2-G3: Fall A -- pending untouched (still the open play)");
}

# --- G2-G3: Fall B -- echo already settled via the track_changed echo
# branch (pending cleared, observed.track eq wanted.uri): criterion (3)
# fires the same as criterion (1) did in Fall A ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mode     => 'browse',
        observed => { wsConnected => 1, paired => 1, meta => {}, track => $TID_46EU, status => 'playing' },
    );

    $ctl->requestTrack($TID_4PTG, 0, { source => 'getNextTrack', successCb => sub { } });
    $ctl->onEvent({ type => 'track_changed', item => { uri => $TID_4PTG } });
    ok(!defined $ctl->pending, "G2-G3: Fall B setup -- pending cleared by the echo");
    is($ctl->observed->{track}, $TID_4PTG, "G2-G3: Fall B setup -- observed.track updated by the echo");
    @Slim::Player::Client::EXECUTED = ();

    $ctl->onEvent({ type => 'device_changed', is_active => 1, device_name => 'lavender-pa' });

    is($ctl->mode, 'browse', "G2-G3: Fall B -- mode stays browse (observed.track eq wanted.uri, criterion 3)");
    is_deeply(\@Slim::Player::Client::EXECUTED, [], "G2-G3: Fall B -- no spottyconnect start emitted");
    is($ctl->wanted->{uri}, $TID_4PTG, "G2-G3: Fall B -- wanted.uri unchanged");
    is($ctl->observed->{is_active}, 1, "G2-G3: Fall B -- observed.is_active set to 1");
}

# --- G2-G3: Fall C -- real transfer-in from idle, unchanged from 82-03:
# no pending play, no expectEcho, mode switches to connect, 'start' emitted
# with the daemon's OWN track (Y) ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mode     => 'idle',
        observed => { wsConnected => 1, meta => {}, track => $TID_46EU },
    );
    @Slim::Player::Client::EXECUTED = ();

    $ctl->onEvent({ type => 'device_changed', is_active => 1, device_name => 'lavender-pa' });

    is($ctl->mode, 'connect', "G2-G3: Fall C -- real transfer-in still switches idle -> connect (82-03 unchanged)");
    is_deeply(\@Slim::Player::Client::EXECUTED, [ [ 'spottyconnect', 'start', '46eu3SBuFCXWsPT39Yg3tJ', '' ] ],
        "G2-G3: Fall C -- start emitted with Y (unchanged from 82-03)");
    is($ctl->wanted->{uri}, $TID_46EU, "G2-G3: Fall C -- wanted.uri = Y");
}

# --- G2-G3: Fall D -- foreign title in browse (App has taken over): our
# own play already confirmed (pending cleared, observed.track = X), then a
# FOREIGN track_changed (Z) arrives before device_changed -- no target
# match, so this stays a real transfer, exactly the case the
# classification must NOT swallow ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mode     => 'browse',
        observed => { wsConnected => 1, paired => 1, meta => {}, track => $TID_46EU, status => 'playing' },
    );
    my $TID_Z = 'spotify:track:zzzzzzzzzzzzzzzzzzzzzz';

    $ctl->requestTrack($TID_4PTG, 0, { source => 'getNextTrack', successCb => sub { } });
    $ctl->onEvent({ type => 'track_changed', item => { uri => $TID_4PTG } });    # our own echo confirmed
    @IO::Socket::INET::CALLS = ();
    $ctl->onEvent({ type => 'track_changed', item => { uri => $TID_Z } });       # foreign (App skip)
    is($ctl->observed->{track}, $TID_Z, "G2-G3: Fall D setup -- foreign track_changed updates observed.track");
    @Slim::Player::Client::EXECUTED = ();

    $ctl->onEvent({ type => 'device_changed', is_active => 1, device_name => 'lavender-pa' });

    is($ctl->mode, 'connect', "G2-G3: Fall D -- foreign title: no target match, real transfer (not swallowed)");
    is_deeply(\@Slim::Player::Client::EXECUTED, [ [ 'spottyconnect', 'start', 'zzzzzzzzzzzzzzzzzzzzzz', '' ] ],
        "G2-G3: Fall D -- start emitted with Z (the App's title)");
    is($ctl->wanted->{uri}, $TID_Z, "G2-G3: Fall D -- wanted.uri = Z");
}

# --- G2-G3: Fall D' -- displacement after T1: our own play's echo has not
# arrived yet, T1 fires (pending -> expectEcho), then a FOREIGN
# track_changed (Z) arrives BEFORE our own echo -- expectEcho must be
# marked displacedBy, not deleted (WR-01 still needs it for a LATER echo of
# the ORIGINAL uri), and device_changed must still read as a real transfer
# despite a live (but displaced) expectEcho ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mode     => 'browse',
        observed => { wsConnected => 1, paired => 1, meta => {}, track => 'spotify:track:yyyyyyyyyyyyyyyyyyyyyy', status => 'playing' },
    );
    my $TID_Z = 'spotify:track:zzzzzzzzzzzzzzzzzzzzzz';

    $ctl->requestTrack($TID_4PTG, 0, { source => 'getNextTrack', successCb => sub { } });
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 0.6);    # T1 fires -- pending released, expectEcho armed
    ok(!defined $ctl->pending, "G2-G3: Fall D' setup -- T1 released pending");
    ok(defined $ctl->observed->{expectEcho} && $ctl->observed->{expectEcho}{uri} eq $TID_4PTG,
        "G2-G3: Fall D' setup -- expectEcho armed for our own uri");

    $ctl->onEvent({ type => 'track_changed', item => { uri => $TID_Z } });    # foreign, arrives before our echo
    is($ctl->observed->{expectEcho}{displacedBy}, $TID_Z,
        "G2-G3: Fall D' -- expectEcho.displacedBy set to Z, expectation NOT deleted");
    @Slim::Player::Client::EXECUTED = ();

    $ctl->onEvent({ type => 'device_changed', is_active => 1, device_name => 'lavender-pa' });

    is($ctl->mode, 'connect', "G2-G3: Fall D' -- displaced expectEcho does not block the real transfer");
    is_deeply(\@Slim::Player::Client::EXECUTED, [ [ 'spottyconnect', 'start', 'zzzzzzzzzzzzzzzzzzzzzz', '' ] ],
        "G2-G3: Fall D' -- start emitted with Z despite the live (displaced) expectEcho");
    is($ctl->wanted->{uri}, $TID_Z, "G2-G3: Fall D' -- wanted.uri = Z");
}

# --- G2-G3: Fall E -- G-3, a Stop after our own activation echo still
# reaches the daemon: after Fall B's setup (the echo already settled --
# pending clear, so 'pause' is not folded into a still-open 'play' per
# CR-02's fold-through discipline), requestPause(1) sends 'pause'
# regardless of the just-classified own-activation echo ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mode     => 'browse',
        observed => { wsConnected => 1, paired => 1, meta => {}, track => $TID_46EU, status => 'playing' },
    );

    $ctl->requestTrack($TID_4PTG, 0, { source => 'getNextTrack', successCb => sub { } });
    $ctl->onEvent({ type => 'track_changed', item => { uri => $TID_4PTG } });    # echo settles, pending clears
    $ctl->onEvent({ type => 'device_changed', is_active => 1, device_name => 'lavender-pa' });
    is($ctl->mode, 'browse', "G2-G3: Fall E setup -- mode still browse after own activation echo");

    local $Slim::Player::Source::PLAYMODE = 'stop';
    $ctl->requestPause(1);
    is_deeply($ws->sent->[-1], [ 'pause', {} ],
        "G2-G3: Fall E -- LMS stop reaches the daemon after an own-activation echo (G-3)");
}

# --- G2-G3: Fall F -- Replay Lauf 1 (2026-09-06 18:05, the actual live G-2
# trace): browse, requestTrack(4PTG..., getNextTrack) against a stale
# observed.track=46eu... (restored previous session), then replay every
# frame from g2-lauf1-own-activation.jsonl in order. Pre-fix this ends in
# mode=connect with a 'start' emission for 46eu... (the G-2 bug, visible as
# a RED failure here); post-fix mode stays browse throughout. ---
{
    @IO::Socket::INET::CALLS = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mode     => 'browse',
        observed => { wsConnected => 1, paired => 1, meta => {}, track => $TID_46EU, status => 'paused' },
    );

    $ctl->requestTrack($TID_4PTG, 0, { source => 'getNextTrack', successCb => sub { } });
    @Slim::Player::Client::EXECUTED = ();

    for my $line (load_fixture('g2-lauf1-own-activation.jsonl')) {
        $ctl->onEvent(decode_frame($line));
    }

    is($ctl->mode, 'browse',
        "G2-G3: Fall F -- Lauf-1 replay: mode stays browse (own activation echo, not the G-2 transfer bug)");
    is_deeply(\@Slim::Player::Client::EXECUTED, [], "G2-G3: Fall F -- Lauf-1 replay: no spottyconnect start emitted");
    is($ctl->wanted->{uri}, $TID_4PTG, "G2-G3: Fall F -- wanted.uri stays the requested track (4PTG...)");
    is($ctl->observed->{track}, $TID_4PTG,
        "G2-G3: Fall F -- observed.track converges on the requested track via the track_changed/playback_state frames");
    is($ctl->observed->{is_active}, 1, "G2-G3: Fall F -- observed.is_active set to 1 by the device_changed frame");
}

# --- G2-G3: Fall G -- late echo case, WR-01 stays intact: T1 fires
# (expectEcho armed, no displacement), device_changed is_active:true reads
# as our own activation (criterion 2), THEN the late track_changed for the
# original uri still lands via the existing late-echo branch (82-12) --
# no boundary, no start, either time ---
{
    @IO::Socket::INET::CALLS    = ();
    @IO::Socket::INET::REQUESTS = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mode     => 'browse',
        observed => { wsConnected => 1, paired => 1, meta => {}, track => $TID_46EU, status => 'playing' },
    );

    $ctl->requestTrack($TID_4PTG, 0, { source => 'getNextTrack', successCb => sub { } });
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 0.6);    # T1 fires -- pending released, expectEcho armed
    @Slim::Player::Client::EXECUTED = ();

    $ctl->onEvent({ type => 'device_changed', is_active => 1, device_name => 'lavender-pa' });

    is($ctl->mode, 'browse', "G2-G3: Fall G -- device_changed after T1 still reads as own activation (criterion 2)");
    is_deeply(\@Slim::Player::Client::EXECUTED, [], "G2-G3: Fall G -- no spottyconnect start emitted");
    is($ctl->observed->{is_active}, 1, "G2-G3: Fall G -- observed.is_active set to 1");

    $ctl->onEvent({ type => 'track_changed', item => { uri => $TID_4PTG } });    # the late echo, 82-12

    is($ctl->observed->{track}, $TID_4PTG, "G2-G3: Fall G -- late echo still updates observed.track (82-12 unchanged)");
    is_deeply(\@Slim::Player::Client::EXECUTED, [], "G2-G3: Fall G -- late echo emits no start either");
    # 82-19 F2: the initial requestTrack's own mismatch-path dispatch (X
    # differs from the daemon's reported track) arms over the same socket
    # a genuine /boundary POST would use -- filter by request body.
    is(scalar(grep { ${ $_->{bufref} } =~ m{^POST /boundary} } @IO::Socket::INET::REQUESTS), 0,
        "G2-G3: Fall G -- late echo plants no boundary (82-12 late-echo branch unchanged)");
}

# ============================================================
# 84-26 R3 (F-24-1, B7): the idle re-adoption in _onFramePlaybackState (a playing,
# is_active frame while mode idle -> Connect session) honours the autoplay marker through
# _holdAfterForeignLeave's predicate: while the daemon plays the title the guard paused AND
# LMS plays foreign content (a local file), the paused-then-resumed autoplay title is NOT
# adopted as a Connect session. Same clause shape as T-84.1-29 (url class + pending marker,
# never a time window). When LMS is not on foreign content the adoption is legitimate (D-02)
# and the marker is dropped.
# ============================================================
{
    my $R3_Z = 'spotify:track:r3AutoplayPausedZZZZZZ';
    my $R3_W = 'spotify:track:r3OtherTitleWWWWWWWWWW';
    my $r3_frame = sub {
        my ($uri) = @_;
        return { type => 'playback_state', item => { uri => $uri }, status => 'playing', is_active => 1, volume => 60,
                 position => { position_ms => 5000, timestamp_ms => 1000, speed => 1 } };
    };
    my $r3_ctl = sub {
        my ($macTail, %extra) = @_;
        @Plugins::SpotOn::Connect::CLAIMS = (); $Plugins::SpotOn::Connect::ACTIVE = undef;
        @Slim::Player::Client::EXECUTED   = ();
        my $mac = "aa:84:26:03:00:$macTail";
        my ($ctl, $daemon, $ws) = fresh_control(
            mac => $mac, mode => 'idle',
            observed => { wsConnected => 1, meta => {}, track => $R3_Z, autoplayPaused => $R3_Z, %extra },
        );
        return ($ctl, $daemon, $ws, $mac);
    };

    # Fall A: marker Z, the daemon plays Z, LMS plays a local file -> hold: mode stays idle, no bind, no start
    {
        my ($ctl, $daemon, $ws, $mac) = $r3_ctl->('01');
        foreign_track($mac);
        local $Slim::Player::Source::PLAYMODE = 'play';
        $ctl->onEvent($r3_frame->($R3_Z));
        is($ctl->mode, 'idle', "84-26 R3 Fall A: the paused-then-resumed autoplay title is not adopted while LMS plays a local file");
        is(scalar(grep { $_->[0] eq 'bind' } @Plugins::SpotOn::Connect::CLAIMS), 0, "84-26 R3 Fall A: no claim bind");
        is(scalar(@Slim::Player::Client::EXECUTED), 0, "84-26 R3 Fall A: no start emission (no LMS command)");
        is($ctl->observed->{autoplayPaused}, $R3_Z, "84-26 R3 Fall A: the marker stays while the hold applies");
    }

    # Fall B: same, LMS stopped -> the IN-02 adoption, marker gone (guard)
    {
        my ($ctl, $daemon, $ws, $mac) = $r3_ctl->('02');
        foreign_track($mac);
        local $Slim::Player::Source::PLAYMODE = 'stop';
        $ctl->onEvent($r3_frame->($R3_Z));
        is($ctl->mode, 'connect', "84-26 R3 Fall B: LMS stopped -- the daemon playing Z is adopted (IN-02 reconnect adoption, D-02)");
        ok(!exists $ctl->observed->{autoplayPaused}, "84-26 R3 Fall B: the marker is dropped when the predicate falls through");
        $Plugins::SpotOn::Connect::ACTIVE = undef; @Plugins::SpotOn::Connect::CLAIMS = ();
    }

    # Fall C: marker Z but the frame names W, LMS on foreign content -> today's behaviour (the hold only matches its own uri)
    {
        my ($ctl, $daemon, $ws, $mac) = $r3_ctl->('03');
        foreign_track($mac);
        local $Slim::Player::Source::PLAYMODE = 'play';
        $ctl->onEvent($r3_frame->($R3_W));
        is($ctl->mode, 'connect', "84-26 R3 Fall C: a frame naming another uri than the marker is adopted as today");
        $Plugins::SpotOn::Connect::ACTIVE = undef; @Plugins::SpotOn::Connect::CLAIMS = ();
    }

    # Fall D: marker Z, LMS on our own material and playing -> adopted (guard: our own session is legitimate)
    {
        my ($ctl, $daemon, $ws, $mac) = $r3_ctl->('04');
        own_track($mac);
        local $Slim::Player::Source::PLAYMODE = 'play';
        $ctl->onEvent($r3_frame->($R3_Z));
        is($ctl->mode, 'connect', "84-26 R3 Fall D: LMS plays our own material -- the adoption is legitimate (guard)");
        $Plugins::SpotOn::Connect::ACTIVE = undef; @Plugins::SpotOn::Connect::CLAIMS = ();
    }
}

# ============================================================
# 84-21 Task 1 (D-31 (1)): "Connect off = visible but refusing". With
# enableSpotifyConnect 0 a transfer-in must not bind the claim nor enter
# mode=connect -- at BOTH entries (device_changed, playback_state
# reconnect adoption). idle: probe `deactivate` + one errors[] entry;
# browse (foreign activation, the Fall D shape above -- the only shape that
# passes the _takeover and _ownActivation returns): NO deactivate (it would
# starve the Browse stream), the wanted title re-asserted. The pref is
# flipped through %Slim::Utils::Prefs::FAKE_VALUES with `local`, so it is
# back at 1 for the rest of the file.
# ============================================================

# --- connect-off A: device_changed entry from idle ---
{
    local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 0;
    @Plugins::SpotOn::Status::RECORDED = ();
    @Plugins::SpotOn::Connect::CLAIMS  = ();
    $Plugins::SpotOn::Connect::ACTIVE  = undef;    # the bind recorder's package scalar leaks across blocks
    @Slim::Player::Client::EXECUTED    = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => 'aa:84:21:00:00:a1',
        mode     => 'idle',
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'playing' },
    );

    $ctl->onEvent(decode_frame(load_fixture('device_changed.json')));

    is($ctl->mode, 'idle', "84-21 connect-off A: device_changed with the Connect pref at 0 leaves mode idle");
    is(scalar(grep { $_->[0] eq 'bind' } @Plugins::SpotOn::Connect::CLAIMS), 0,
        "84-21 connect-off A: no claim bind");
    is(scalar(grep { $_->[0] eq 'deactivate' } @{ $ws->sent }), 1,
        "84-21 connect-off A: exactly one deactivate sent");
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 1, "84-21 connect-off A: one errors[] entry");
    my $rec = $Plugins::SpotOn::Status::RECORDED[0] || [];
    is($rec->[0], 'warn',   "84-21 connect-off A: entry level warn");
    is($rec->[1], 'Soloist', "84-21 connect-off A: entry module Soloist");
    like($rec->[2] // '', qr/Spotify Connect is switched off/, "84-21 connect-off A: entry message");
    like($rec->[3] // '', qr/connect-off:/, "84-21 connect-off A: entry key");
    is_deeply(\@Slim::Player::Client::EXECUTED, [], "84-21 connect-off A: no LMS command");

    # --- connect-off D: re-enabling the pref clears the entry and lets the transfer in ---
    $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 1;
    $ctl->onEvent(decode_frame(load_fixture('device_changed.json')));
    is($ctl->mode, 'connect', "84-21 connect-off D: with the pref back at 1 the same frame enters connect");
    is(scalar(grep { ($_->[3] // '') =~ /connect-off:/ } @Plugins::SpotOn::Status::RECORDED), 0,
        "84-21 connect-off D: the connect-off entry is cleared (Status stub RECORDED, via _clearErrorOnce)");
    is(scalar(grep { $_->[0] eq 'bind' } @Plugins::SpotOn::Connect::CLAIMS), 1,
        "84-21 connect-off D: the allowed transfer binds the claim");
}

# --- connect-off B: playback_state reconnect adoption from idle ---
{
    local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 0;
    @Plugins::SpotOn::Status::RECORDED = ();
    @Plugins::SpotOn::Connect::CLAIMS  = ();
    $Plugins::SpotOn::Connect::ACTIVE  = undef;    # the bind recorder's package scalar leaks across blocks
    @Slim::Player::Client::EXECUTED    = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => 'aa:84:21:00:00:b1',
        mode     => 'idle',
        observed => { wsConnected => 1, meta => {} },
    );

    $ctl->onEvent(decode_frame(load_fixture('playback_state.json')));

    is($ctl->mode, 'idle', "84-21 connect-off B: reconnect adoption with the Connect pref at 0 leaves mode idle");
    is(scalar(grep { $_->[0] eq 'bind' } @Plugins::SpotOn::Connect::CLAIMS), 0,
        "84-21 connect-off B: no claim bind");
    is(scalar(grep { $_->[0] eq 'deactivate' } @{ $ws->sent }), 1,
        "84-21 connect-off B: exactly one deactivate sent");
    is(scalar(grep { ($_->[3] // '') =~ /connect-off:/ } @Plugins::SpotOn::Status::RECORDED), 1,
        "84-21 connect-off B: one connect-off errors[] entry");
    like(($Plugins::SpotOn::Status::RECORDED[0] || [])->[2] // '', qr/Spotify Connect is switched off/,
        "84-21 connect-off B: entry message");

    $ctl->onEvent(decode_frame(load_fixture('playback_state.json')));
    is(scalar(grep { ($_->[3] // '') =~ /connect-off:/ } @Plugins::SpotOn::Status::RECORDED), 1,
        "84-21 connect-off B: a second identical frame adds no second entry (dedupe)");
    is($ctl->mode, 'idle', "84-21 connect-off B: still idle after the second frame");
    is_deeply(\@Slim::Player::Client::EXECUTED, [], "84-21 connect-off B: no LMS command");
}

# --- connect-off C: browse mode, foreign activation (Fall D shape, NOT Fall G) ---
{
    local $Slim::Utils::Prefs::FAKE_VALUES{enableSpotifyConnect} = 0;
    @Plugins::SpotOn::Status::RECORDED = ();
    @Plugins::SpotOn::Connect::CLAIMS  = ();
    $Plugins::SpotOn::Connect::ACTIVE  = undef;    # the bind recorder's package scalar leaks across blocks
    @IO::Socket::INET::CALLS           = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => 'aa:84:21:00:00:c1',
        mode     => 'browse',
        observed => { wsConnected => 1, paired => 1, meta => {}, track => $TID_46EU, status => 'playing' },
    );
    my $TID_Z = 'spotify:track:zzzzzzzzzzzzzzzzzzzzzz';

    $ctl->requestTrack($TID_4PTG, 0, { source => 'getNextTrack', successCb => sub { } });
    $ctl->onEvent({ type => 'track_changed', item => { uri => $TID_4PTG } });    # our own echo settles
    $ctl->onEvent({ type => 'track_changed', item => { uri => $TID_Z } });       # foreign title: criterion 3 cannot fire
    # NO fire_due here: an armed late-echo expectation would read as our own activation (Fall G)
    @Slim::Player::Client::EXECUTED = ();
    my $sentBefore = scalar @{ $ws->sent };

    $ctl->onEvent({ type => 'device_changed', is_active => 1, device_name => 'lavender-pa' });

    is($ctl->mode, 'browse', "84-21 connect-off C: foreign activation with the Connect pref at 0 leaves mode browse");
    is_deeply(\@Slim::Player::Client::EXECUTED, [], "84-21 connect-off C: no LMS command");
    is($ctl->wanted->{uri}, $TID_4PTG, "84-21 connect-off C: wanted.uri stays the Browse title");
    my @after = @{ $ws->sent }[ $sentBefore .. $#{ $ws->sent } ];
    is(scalar(grep { $_->[0] eq 'deactivate' } @after), 0,
        "84-21 connect-off C: NO deactivate in browse (it would starve the stream)");
    ok(scalar(grep { $_->[0] eq 'play' } @after) >= 1,
        "84-21 connect-off C: the wanted title is re-asserted (play sent)");
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 1, "84-21 connect-off C: one errors[] entry");
    my $rec = $Plugins::SpotOn::Status::RECORDED[0] || [];
    like($rec->[2] // '', qr/Spotify Connect is switched off/, "84-21 connect-off C: entry message");
    like($rec->[3] // '', qr/connect-off:/, "84-21 connect-off C: entry key");
    is(scalar(grep { $_->[0] eq 'bind' } @Plugins::SpotOn::Connect::CLAIMS), 0,
        "84-21 connect-off C: no claim bind");
}

# --- connect-off control: pref 1 from idle still enters connect with a bind (CR-02 shape) ---
{
    @Plugins::SpotOn::Status::RECORDED = ();
    @Plugins::SpotOn::Connect::CLAIMS  = ();
    $Plugins::SpotOn::Connect::ACTIVE  = undef;    # the bind recorder's package scalar leaks across blocks
    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => 'aa:84:21:00:00:e1',
        mode     => 'idle',
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'playing' },
    );
    $ctl->onEvent(decode_frame(load_fixture('device_changed.json')));
    is($ctl->mode, 'connect', "84-21 connect-off control: pref 1, device_changed from idle enters connect");
    is(scalar(grep { $_->[0] eq 'bind' } @Plugins::SpotOn::Connect::CLAIMS), 1,
        "84-21 connect-off control: the claim is bound");
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 0, "84-21 connect-off control: no connect-off entry");
    $Plugins::SpotOn::Connect::ACTIVE = undef;
    @Plugins::SpotOn::Connect::CLAIMS = ();
    @Plugins::SpotOn::Status::RECORDED = ();
}

# ============================================================
# 82-22 Task 1, R2-CR01: the 82-09 guard (`$prev->{cmd} eq 'play' && $cmd
# ne 'play'`) still lets a BARE `play` (no uri) through to the slot-replace
# path -- requestResume/watchdogRing Fall (c)/Seek-Pfad (2) all send
# exactly that while a `play uri` pending is open (a getNextTrack in
# flight). Falls A-C prove the fold-through fix (B1); Fall D proves a
# GENUINE new `play uri` still replaces the slot AND releases the old
# pending's callbacks (B2); Falls E/F prove the `_reconcile` Schritt-4
# Treffer-Guard (W-NEU-1) on mismatched vs. matched pending uri.
# ============================================================

# --- R2-CR01: Fall A -- bare `play` from requestResume must FOLD into an
# open play-uri pending, not clobber it (Muss-Fehlschlag-Probe: this block
# asserts the FIXED/expected behavior and is run FIRST against the
# UNFIXED guard, where it fails -- see SUMMARY for the captured failure
# output, `pending` comes back `undef` instead of the expected HASH) ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:e1', mode => 'browse',
        observed => { wsConnected => 1, meta => { $TID => { duration => 200 } }, status => 'paused' },
    );

    my ($origOk, $origErr);
    $ctl->requestTrack($TID, 0, { successCb => sub { $origOk = 1; }, errorCb => sub { $origErr = [@_]; } });
    is_deeply($ws->sent, [ [ 'play', { uri => $TID } ] ],
        "R2-CR01: Fall A -- initial requestTrack opens a play-uri pending");

    $ctl->requestResume;

    is_deeply($ws->sent, [ [ 'play', { uri => $TID } ] ],
        "R2-CR01: Fall A -- bare play from requestResume sends NO second frame (fold-through, not clobber)");
    ok(defined($ctl->pending), "R2-CR01: Fall A -- pending is still a HASH structure, not undef");
    is($ctl->pending && $ctl->pending->{cmd}, 'play',
        "R2-CR01: Fall A -- pending->{cmd} is still 'play' -- the ORIGINAL slot, not a replacement");
    is($ctl->pending && $ctl->pending->{uri}, $TID,
        "R2-CR01: Fall A -- pending->{uri} is still the original target -- unchanged by the fold");
    ok((grep { $_->[0] == $ctl } @Slim::Utils::Timers::TIMERS),
        "R2-CR01: Fall A -- the T1 timer for the original play survives (getNextTrack does not wedge)");
    is($origOk, undef, "R2-CR01: Fall A -- the original successCb has not fired yet -- it still awaits the real echo");
    is($origErr, undef, "R2-CR01: Fall A -- the original errorCb has not fired either -- nothing was stranded");

    # --- R2-CR01: Fall B -- the round trip completes normally: the real
    # track_changed echo for the ORIGINAL uri still fires the ORIGINAL
    # successCb (GREEN, same setup continued) ---
    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    is($origOk, 1, "R2-CR01: Fall B -- the original successCb fires on the real echo -- never lost, just deferred");
    is($ctl->pending, undef, "R2-CR01: Fall B -- pending is released once the real echo settles it");
}

# --- R2-CR01: Fall C -- same fold-through, but via watchdogRing Fall (c)
# (paused/stopped/idle) instead of requestResume -- the same guard covers
# every bare-`play` call site, not just requestResume's ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:e2', mode => 'browse', observed => { wsConnected => 1, meta => {}, status => 'paused' },
    );

    $ctl->requestTrack($TID, 0, {});
    is_deeply($ws->sent, [ [ 'play', { uri => $TID } ] ], "R2-CR01: Fall C -- initial requestTrack opens a play-uri pending");

    $ctl->watchdogRing($TID);

    is_deeply($ws->sent, [ [ 'play', { uri => $TID } ] ],
        "R2-CR01: Fall C -- watchdogRing Fall (c)'s bare play sends NO second frame either");
    is($ctl->pending && $ctl->pending->{cmd}, 'play',
        "R2-CR01: Fall C -- pending stays the ORIGINAL play-uri slot, unchanged by watchdogRing's fold");
    is($ctl->pending && $ctl->pending->{uri}, $TID, "R2-CR01: Fall C -- pending->{uri} unchanged");
}

# --- R2-CR01: Fall D -- a GENUINE new `play uri` (different target) still
# replaces the pending slot as before (regular track change must not be
# blocked, B1 only excludes the BARE play), AND releases the OLD pending's
# callbacks with a `PROBLEM_OPENING`/`superseded` error instead of
# silently dropping them (B2) ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:e3', mode => 'browse', observed => { wsConnected => 1, meta => {}, status => 'paused' },
    );

    my ($oldOk, $oldErr, $newOk);
    $ctl->requestTrack($NEXT_TID, 0, { successCb => sub { $oldOk = 1; }, errorCb => sub { $oldErr = [@_]; } });
    is_deeply($ws->sent, [ [ 'play', { uri => $NEXT_TID } ] ], "R2-CR01: Fall D -- first requestTrack opens its own pending");

    $ctl->requestTrack($TID, 0, { successCb => sub { $newOk = 1; } });

    is_deeply($ws->sent, [ [ 'play', { uri => $NEXT_TID } ], [ 'play', { uri => $TID } ] ],
        "R2-CR01: Fall D -- a genuine new play-uri still replaces the slot (regular track change not broken)");
    is($ctl->pending && $ctl->pending->{uri}, $TID, "R2-CR01: Fall D -- pending is now the NEW target");
    is_deeply($oldErr, [ 'PROBLEM_OPENING', 'superseded' ],
        "R2-CR01: Fall D -- the OLD pending's errorCb fires with PROBLEM_OPENING/superseded (B2) instead of being dropped");
    is($oldOk, undef, "R2-CR01: Fall D -- the OLD pending's successCb never fires");
}

# --- R2-CR01: Fall E (W-NEU-1) -- `_reconcile` Schritt 4's Treffer
# condition must NOT resolve as "already there" when a `play`-pending is
# open for a DIFFERENT uri than wanted.uri, even though observed.track
# happens to equal wanted.uri (a stale intermediate value from BEFORE the
# in-flight switch to the pending's target). Fast Next->Prev out of pause:
# observed.track is still X (the title BEFORE the switch to Y), a play
# uri=Y pending is open, then a second requestTrack(X, ...) comes back in
# -- it must fall through to the Mismatch path (Schritt 5), which reaches
# the SAME Superseded mechanism Fall D already exercises, NOT resolve
# immediately via the Treffer branch. ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:e4', mode => 'browse',
        observed => { wsConnected => 1, meta => {}, status => 'paused', track => $TID },
    );

    my ($yOk, $yErr);
    $ctl->requestTrack($NEXT_TID, 0, { successCb => sub { $yOk = 1; }, errorCb => sub { $yErr = [@_]; } });
    is_deeply($ws->sent, [ [ 'play', { uri => $NEXT_TID } ] ],
        "R2-CR01: Fall E -- play uri=Y dispatched and pending, observed.track is still the stale X");

    my ($xOk, $xErr);
    $ctl->requestTrack($TID, 0, { successCb => sub { $xOk = 1; }, errorCb => sub { $xErr = [@_]; } });

    is_deeply($ws->sent, [ [ 'play', { uri => $NEXT_TID } ], [ 'play', { uri => $TID } ] ],
        "R2-CR01: Fall E -- W-NEU-1: falls through to Mismatch and dispatches play uri=X, NOT a premature Treffer resolve");
    is_deeply($yErr, [ 'PROBLEM_OPENING', 'superseded' ],
        "R2-CR01: Fall E -- Y's pending errorCb fires superseded via the SAME B2 mechanism as Fall D");
    is($xOk, undef,
        "R2-CR01: Fall E -- X's successCb does NOT fire immediately -- LMS must not be told X already played while the daemon is still mid-switch to Y");
    is($ctl->pending && $ctl->pending->{uri}, $TID, "R2-CR01: Fall E -- pending is now X, the new Mismatch-path target");
}

# Since 82-30 this test also guards $needsSeek's third exception (open play-Pending for the same uri) -- see Control::_reconcile Schritt 4.
# --- R2-CR01: Fall F (W-NEU-1, Disjunktheit) -- the new `_reconcile`
# clause must NOT fire when the open pending's uri EQUALS wanted.uri --
# the Treffer branch resolves exactly as before (B1 fold, immediate
# successCb, no second frame). `pending.sentAt` is backdated past
# T1_TRACK_CHANGED_MS (500ms) so Schritt 3 (Idempotenz) does NOT intercept
# first -- without that, the new Schritt-4 clause would never actually be
# evaluated and this fall would prove nothing about the guard. Built via
# requestTrack (not a direct _dispatch call) so the `_reconcile` clause
# under test is actually on the call path. ---
{
    my $preseededCb = { successCb => [], errorCb => undef };
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:e5', mode => 'browse',
        observed => { wsConnected => 1, meta => {}, status => 'paused', track => $TID },
        pending  => { cmd => 'play', uri => $TID, position_ms => 0,
            sentAt => Time::HiRes::time() - 1, cb => $preseededCb },
    );

    my ($xOk, $xErr);
    $ctl->requestTrack($TID, 0, { successCb => sub { $xOk = 1; }, errorCb => sub { $xErr = [@_]; } });

    is_deeply($ws->sent, [], "R2-CR01: Fall F -- same-uri Treffer folds through -- NO frame goes out at all");
    is($xOk, 1, "R2-CR01: Fall F -- successCb fires immediately (B1 fold), exactly as before the W-NEU-1 clause");
    is($ctl->pending && $ctl->pending->{uri}, $TID,
        "R2-CR01: Fall F -- pending is unchanged -- same-uri disjoint case is untouched by the new guard");
    is($ctl->pending && $ctl->pending->{cb}, $preseededCb,
        "R2-CR01: Fall F -- the pre-existing pending's own cb hash is the SAME reference -- no B2 supersede fired for it");
}

# ============================================================
# 82-22 Task 2, R2-CR02: a Stop (`isStop=1`) folded into an open
# `play`-pending must survive as `postPauseIsStop` and dispatch `pause` on
# replay REGARDLESS of the current (possibly stale) observed.status --
# the same Split-Brain discipline 82-20 already gave the DIRECT dispatch
# path (Control.pm:773-789), now extended to the FOLDED path.
# ============================================================

# --- R2-CR02: Fall A -- Echo replay dispatches the folded Stop's pause
# even though observed.status is still the stale 'paused' it started
# with (Muss-Fehlschlag-Probe: asserts the FIXED/expected behavior) ---
{
    local $Slim::Player::Source::PLAYMODE = 'stop';

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:f1', observed => { wsConnected => 1, meta => { $TID => { duration => 200 } }, status => 'paused' },
    );

    $ctl->requestTrack($TID, 0, {});
    $ctl->requestPause(1);    # isStop=1 -- folds into the open play pending

    is($ctl->pending && $ctl->pending->{postPauseIsStop}, 1,
        "R2-CR02: Fall A -- postPauseIsStop recorded on the fold, before the echo");

    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    is_deeply($ws->sent,
        [ [ 'play', { uri => $TID } ], [ 'seek', { position_ms => 0 } ], [ 'pause', {} ] ],
        "R2-CR02: Fall A -- the folded Stop's pause DOES dispatch on replay, isStop rides through unconditionally");
}

# --- R2-CR02: Fall B -- same replay, checked from the wanted/observed
# angle: wanted.playing stays 0 (the Stop's own wish) and the pause really
# went out as the LAST frame, not merged/lost. ---
{
    local $Slim::Player::Source::PLAYMODE = 'stop';

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:f2', observed => { wsConnected => 1, meta => { $TID => { duration => 200 } }, status => 'paused' },
    );

    $ctl->requestTrack($TID, 0, {});
    $ctl->requestPause(1);
    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    is($ctl->wanted->{playing}, 0, "R2-CR02: Fall B -- wanted.playing stays 0 (the Stop's own wish)");
    is_deeply($ws->sent->[-1], [ 'pause', {} ], "R2-CR02: Fall B -- pause is the LAST frame sent, not dropped after the echo");
}

# --- R2-CR02: Fall C -- same fold, but replay via T1's timeout instead of
# the echo (Slim::Utils::Timers::fire_due) -- T1 drops a folded postSeek
# but must still replay the folded Stop. ---
{
    local $Slim::Player::Source::PLAYMODE = 'stop';

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:f3', observed => { wsConnected => 1, meta => {}, status => 'paused' },
    );

    $ctl->requestTrack($TID, 0, {});
    $ctl->requestPause(1);

    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 0.6);    # T1 fires -- replay via _t1Fire, not the echo

    is_deeply($ws->sent, [ [ 'play', { uri => $TID } ], [ 'pause', {} ] ],
        "R2-CR02: Fall C -- T1's own replay also dispatches the folded Stop's pause (no seek -- T1 drops postSeek)");
}

# ============================================================
# 82-22 Task 2, R2-WR02: `_prefetchNext`'s `add_to_queue` must run BEFORE
# the folded volume replay -- running after (the old order) clobbered the
# freshly-opened `set_volume` pending before its `volume_changed` echo
# arrived, misclassifying that echo as a foreign value and mirroring the
# OLD volume back to LMS.
# ============================================================

# --- R2-WR02: Fall A -- prefetch's add_to_queue and the volume replay
# both go out on the SAME echo, in the new order, and the volume_changed
# echo that follows is still correctly classified as OUR echo (Muss-
# Fehlschlag-Probe: this is the FIXED/expected sequence and classification) ---
{
    local @Slim::Player::Playlist::ENTRIES = ( undef, Test::MockTrack->new("spoton://track:3n3Ppam7vgaVa1iaRUc9Lp") );
    local $Slim::Player::Source::INDEX = 0;

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:f4',
        observed => { wsConnected => 1, meta => { $TID => { duration => 200 } }, track => 'spotify:track:previousXYZ', status => 'playing' },
    );

    $ctl->requestTrack($TID, 0, {});
    $ctl->requestVolume(50, { force => 1 });    # folds postVolume=50 into the open play pending

    @Slim::Player::Client::EXECUTED = ();
    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    is_deeply($ws->sent,
        [ [ 'play', { uri => $TID } ], [ 'seek', { position_ms => 0 } ],
          [ 'add_to_queue', { uri => $NEXT_TID } ], [ 'set_volume', { volume => 50 } ] ],
        "R2-WR02: Fall A -- prefetch's add_to_queue now goes out BEFORE the volume replay opens its own pending");

    $ctl->onEvent({ type => 'volume_changed', volume => 50 });

    is($ctl->pending, undef, "R2-WR02: Fall A -- the volume_changed(50) echo correctly matches the set_volume pending and clears it");
    is_deeply(\@Slim::Player::Client::EXECUTED, [],
        "R2-WR02: Fall A -- no 'mixer volume' foreign-value mirror was emitted -- the echo was classified correctly, not as a foreign value");
}

# --- R2-WR02: Fall B -- same scenario, checked from the observed.volume
# angle: it ends up exactly at 50, not left stuck at the old value that a
# misclassified Fremdwert branch would have mirrored back. ---
{
    local @Slim::Player::Playlist::ENTRIES = ( undef, Test::MockTrack->new("spoton://track:3n3Ppam7vgaVa1iaRUc9Lp") );
    local $Slim::Player::Source::INDEX = 0;

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:f5',
        observed => { wsConnected => 1, meta => { $TID => { duration => 200 } }, track => 'spotify:track:previousXYZ', status => 'playing' },
    );

    $ctl->requestTrack($TID, 0, {});
    $ctl->requestVolume(50, { force => 1 });
    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));
    $ctl->onEvent({ type => 'volume_changed', volume => 50 });

    is($ctl->observed->{volume}, 50, "R2-WR02: Fall B -- observed.volume converges on the NEW value, 50");
    is($ctl->wanted->{volume}, 50, "R2-WR02: Fall B -- wanted.volume was never overwritten back to the old value");
}

# --- R2-WR02: Fall C (W1, documented residual RED case -- NOT fixed in
# this plan, see <objective>) -- postVolume AND postPause folded into the
# SAME pending: the volume replay (now first) opens a NEW set_volume
# pending, then _reconcile('requestPause')'s pause dispatch replaces THAT
# pending via the Slot-Replace path (prev.cmd is 'set_volume', not 'play'
# -- Task 1's fold guard does not apply here) before its own
# volume_changed echo arrives. This is the SAME WR-02 symptom class,
# reached through a different combination -- documented as RED, not
# fixed, per <objective>'s W1 residual-risk note. ---
{
    local @Slim::Player::Playlist::ENTRIES = ();
    local $Slim::Player::Source::PLAYMODE  = 'stop';

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:f6',
        observed => { wsConnected => 1, meta => { $TID => { duration => 200 } }, track => 'spotify:track:previousXYZ', status => 'playing' },
    );

    $ctl->requestTrack($TID, 0, {});
    $ctl->requestVolume(50, { force => 1 });
    $ctl->requestPause(1);

    @Slim::Player::Client::EXECUTED = ();
    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));
    $ctl->onEvent({ type => 'volume_changed', volume => 50 });

    is_deeply(\@Slim::Player::Client::EXECUTED, [ [ 'spottyconnect', 'volume', 50, '' ] ],
        "R2-WR02: Fall C -- W1 (documented, NOT fixed): the postVolume+postPause combination still misclassifies "
        . "the volume_changed(50) echo as a foreign value and mirrors it back to LMS");
}

# ============================================================
# 82-22 Task 2, R2-WR07 (teilweise): observed.status bookkeeping becomes
# symmetric for position_sync (speed>0 resets a stuck 'paused' back to
# 'playing'), and both echo branches set 'playing' unconditionally instead
# of `unless defined` -- the remaining freshness-gated forced-pause
# element from the review is explicitly NOT implemented (see <objective>).
# ============================================================

# --- R2-WR07: Fall A -- position_sync speed=0 still sets 'paused'
# (unchanged baseline behavior) ---
{
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:ee:f7', observed => { wsConnected => 1, meta => {}, status => 'playing' });

    $ctl->onEvent({ type => 'position_sync', position => { position_ms => 1000, timestamp_ms => 1000, speed => 0 } });

    is($ctl->observed->{status}, 'paused', "R2-WR07: Fall A -- position_sync speed=0 sets paused (unchanged)");
}

# --- R2-WR07: Fall B (NEW) -- a FOLLOWING position_sync with speed>0
# resets a 'paused' status back to 'playing' -- the missing symmetric
# case before this fix. ---
{
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:ee:f8', observed => { wsConnected => 1, meta => {}, status => 'playing' });

    $ctl->onEvent({ type => 'position_sync', position => { position_ms => 1000, timestamp_ms => 1000, speed => 0 } });
    is($ctl->observed->{status}, 'paused', "R2-WR07: Fall B -- speed=0 sets paused first");

    $ctl->onEvent({ type => 'position_sync', position => { position_ms => 1200, timestamp_ms => 1200, speed => 5000 } });
    is($ctl->observed->{status}, 'playing', "R2-WR07: Fall B -- a following speed>0 position_sync resets paused back to playing");
}

# --- R2-WR07: Fall C -- the pending-echo branch sets observed.status to
# 'playing' UNCONDITIONALLY, even when it was already 'paused' (not only
# `unless defined`). ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:f9', observed => { wsConnected => 1, meta => { $TID => { duration => 200 } }, status => 'paused' },
    );

    $ctl->requestTrack($TID, 0, {});
    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    is($ctl->observed->{status}, 'playing',
        "R2-WR07: Fall C -- pending-echo branch overwrites a pre-existing 'paused' with 'playing' unconditionally");
}

# --- R2-WR07: Fall D -- the late-echo branch does the same unconditional
# overwrite. ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:fa', observed => { wsConnected => 1, meta => { $TID => { duration => 200 } }, status => 'paused' },
    );

    $ctl->requestTrack($TID, 0, {});
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 0.6);    # T1 releases pending, arms expectEcho
    $ctl->observed->{status} = 'paused';                          # re-stale it after T1's release
    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));    # late echo (past pending, within the window)

    is($ctl->observed->{status}, 'playing',
        "R2-WR07: Fall D -- the late-echo branch also overwrites a stale 'paused' with 'playing' unconditionally");
}

# ============================================================
# R2-CR04 (82-24, Task 1): mode=connect must not overwrite a Connect
# transfer-in's position with 0 the next time requestTrack fires --
# neither at the getNextTrack call site nor at the onStream call site
# (the sibling the reviewer's narrower fix left open). The guard is
# additionally gated on uri-equality (Plan-Check B1, Fall G) and takes
# an int()'d value (Plan-Check B2, Fall H) -- both corrections are
# exercised below. Fall F (the IN-02 claim-release interaction, W3) is
# NOT bezeugbar at Control level (Control.pm never calls
# isSpotifyConnect) and is documented as a comment block only -- see
# 82-24-PLAN.md <objective>/Task 1 <behavior> "Plan-Check-Korrektur F".
# ============================================================

my $CR04_X = $TID;                                    # already-observed track
my $CR04_Y = 'spotify:track:otherTrackZZZZZZZZZZ';     # a DIFFERENT track (Fall G)

# --- R2-CR04 Fall A/B: getNextTrack call site -- the position is taken
# over from _observedPositionMs instead of being overwritten to 0.
# Before this fix: $ws->sent would contain ['seek',{position_ms=>0}]
# and wanted.position_ms would be 0 (dry-run confirmed against the
# unfixed code -- see 82-24-SUMMARY.md). ---
{
    @IO::Socket::INET::REQUESTS               = ();
    @Slim::Networking::SimpleAsyncHTTP::CALLS = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mode     => 'connect',
        observed => {
            wsConnected => 1, paired => 1, meta => {},
            track  => $CR04_X, status => 'playing',
            anchor => { position_ms => 45000, seen_at => Time::HiRes::time() },
        },
    );

    $ctl->requestTrack($CR04_X, 0, { source => 'getNextTrack', successCb => sub { } });

    ok(!(grep { $_->[0] eq 'seek' && ($_->[1]{position_ms} // -1) == 0 } @{ $ws->sent }), "R2-CR04 Fall A: getNextTrack in mode=connect on the already-observed track does not seek to 0");
    ok(abs(($ctl->wanted->{position_ms} // -1) - 45000) < 100, "R2-CR04 Fall B: getNextTrack in mode=connect takes over the observed position (~45000ms), not 0");
}

# --- R2-CR04 Fall C/D: onStream call site -- the sibling the reviewer's
# narrower ($opts->{source} eq 'getNextTrack') fix would have left open.
# Same assertions, same must-fail-without-the-fix property. ---
{
    @IO::Socket::INET::REQUESTS               = ();
    @Slim::Networking::SimpleAsyncHTTP::CALLS = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mode     => 'connect',
        observed => {
            wsConnected => 1, paired => 1, meta => {},
            track  => $CR04_X, status => 'playing',
            anchor => { position_ms => 45000, seen_at => Time::HiRes::time() },
        },
    );

    $ctl->requestTrack($CR04_X, 0, { source => 'onStream', seek => 0, successCb => sub { } });

    ok(!(grep { $_->[0] eq 'seek' && ($_->[1]{position_ms} // -1) == 0 } @{ $ws->sent }), "R2-CR04 Fall C: onStream in mode=connect on the already-observed track does not seek to 0 (the sibling call site)");
    ok(abs(($ctl->wanted->{position_ms} // -1) - 45000) < 100, "R2-CR04 Fall D: onStream in mode=connect takes over the observed position (~45000ms), not 0");
}

# --- R2-CR04 Fall E: mode=browse is unaffected -- the 82-08 CR-01
# position correction in the Treffer branch keeps owning this path, the
# new connect-only guard never touches wanted.position_ms here. ---
{
    @IO::Socket::INET::REQUESTS               = ();
    @Slim::Networking::SimpleAsyncHTTP::CALLS = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mode     => 'browse',
        observed => {
            wsConnected => 1, paired => 1, meta => {},
            track  => $CR04_X, status => 'playing',
            anchor => { position_ms => 45000, seen_at => Time::HiRes::time() },
        },
    );

    $ctl->requestTrack($CR04_X, 0, { source => 'getNextTrack', successCb => sub { } });

    is($ctl->wanted->{position_ms}, 0, "R2-CR04 Fall E: mode=browse is unaffected by the connect-only position takeover -- wanted.position_ms stays 0");
}

# --- R2-CR04 Fall G (Plan-Check B1, must-fail-without-the-uri-clause):
# mode=connect, but requestTrack asks for a DIFFERENT track (Y) than
# the one observed (X). Without the uri-equality clause, the guard
# would still fire (mode=connect && !seek is true regardless of WHICH
# uri is being requested) and hand Y the OLD track's ~45000ms position
# -- a brand new title would start mid-song. With the clause, the
# guard is skipped and the raw (0) position reaches the mismatch
# dispatch untouched. ---
{
    @IO::Socket::INET::REQUESTS               = ();
    @Slim::Networking::SimpleAsyncHTTP::CALLS = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mode     => 'connect',
        observed => {
            wsConnected => 1, paired => 1, meta => {},
            track  => $CR04_X, status => 'playing',
            anchor => { position_ms => 45000, seen_at => Time::HiRes::time() },
        },
    );

    $ctl->requestTrack($CR04_Y, 0, { source => 'onStream', seek => 0, successCb => sub { } });

    is($ctl->wanted->{position_ms}, 0, "R2-CR04 Fall G: a DIFFERENT uri does not inherit the old track's position -- without the uri clause this would be ~45000");
    is_deeply($ws->sent, [ [ 'play', { uri => $CR04_Y } ] ], "R2-CR04 Fall G: mismatch dispatch plays the NEW uri at position 0, not the old track's position");
}

# --- R2-CR04 Fall H (Plan-Check B2, TD-36): two requestTrack calls for the
# SAME already-dispatched target (getNextTrack, then onStream -- the same
# synchronous-LMS-command pattern CR-04 itself is about) must put exactly ONE
# command on the wire. int() at the takeover (Control.pm, CR-04) is a rounding
# decision: the wire carries an integer millisecond. _reconcile Schritt 3's `==`
# on position_ms absorbs the second call only while both calls fall inside ONE
# integer millisecond. Across a millisecond boundary (live: calls about 3 ms
# apart) the second call stays off the wire for a different reason: the daemon
# already plays the target and the observed position lies within
# HIT_POSITION_TOLERANCE_MS of the wanted one, so the hit path sends nothing.
# The block therefore asserts what production relies on -- one command on the
# wire, no seek on the wire, pending still on the target -- at three gaps on a
# STUBBED clock: 0.3 ms (inside one millisecond), 1.3 ms and 3.0 ms (across a
# boundary). The former cell "the second call's successCb is queued" is gone:
# its verdict was decided by the clock (public CI red once, Perl 5.36,
# 84-PUSH.md:338) and onStream passes no successCb in production, so the
# difference has no consumer.
#
# A prior pending 'play' for a DIFFERENT track (Z) is seeded so the FIRST call
# is forced through the Mismatch dispatch (Control.pm, W-NEU-1's exclusion
# clause) and actually opens the 'play'-pending that the second call meets --
# the Treffer branch itself never leaves one open (every Treffer-branch
# dispatch self-clears pending synchronously).
#
# The clock is CONTROLLED (t/45's `local *Time::HiRes::time` convention, 84-10):
# one real reading is the base, so any timer the block arms sits where it
# always did; only the two instants are fixed: getNextTrack at +0.1 ms, onStream
# one gap later. The anchor 45000.1 puts the first call at 45000.2 and the
# second at 45000.5 / 45001.5 / 45003.2 for the three gaps. ---
for my $gap (0.0003, 0.0013, 0.0030) {
    my $label = sprintf('%.1f', $gap * 1000);
    my $pfx   = "R2-CR04 Fall H gap $label ms:";

    @IO::Socket::INET::REQUESTS               = ();
    @Slim::Networking::SimpleAsyncHTTP::CALLS = ();

    my $t0       = Time::HiRes::time();
    my $tFirst   = $t0 + 0.0001;
    my $tSecond  = $tFirst + $gap;
    my ($ctl, $daemon, $ws) = fresh_control(
        mode     => 'connect',
        observed => {
            wsConnected => 1, paired => 1, meta => {},
            track  => $CR04_X, status => 'playing',
            anchor => { position_ms => 45000.1, seen_at => $t0 },
        },
        pending => {
            cmd => 'play', uri => 'spotify:track:priorZZZZZZZZZZZZZZ', position_ms => 999,
            sentAt => $t0, cb => { successCb => [], errorCb => undef },
        },
    );

    # Premise guard: the two rebased raw floats always differ; whether they
    # share one int()'d millisecond is what the gap chooses. If someone retunes
    # the numbers so a gap stops crossing (or stops staying inside) a
    # millisecond, this test would stop exercising what its name says -- fail
    # loudly instead.
    my ($rawFirst, $rawSecond) = map { $ctl->_observedPositionMs($_) } ($tFirst, $tSecond);
    if ($label eq '0.3') {
        ok($rawFirst != $rawSecond && int($rawFirst) == int($rawSecond),
            "$pfx premise -- this gap stays inside one int()'d millisecond (raw positions differ, int() equal)");
    }
    else {
        ok($rawFirst != $rawSecond && int($rawFirst) != int($rawSecond),
            "$pfx premise -- this gap crosses a millisecond boundary (int() of the two raw positions differs)");
    }

    {
        no warnings 'redefine';
        local *Time::HiRes::time = sub { return $tFirst; };
        $ctl->requestTrack($CR04_X, 0, { source => 'getNextTrack', successCb => sub { } });
    }

    ok(scalar(@{ $ws->sent }) == 1 && $ws->sent->[0][0] eq 'play',
        "$pfx first-call -- the first call (superseding the stale Z-pending) dispatches exactly one play");

    # onStream passes no successCb in production; neither does this call.
    {
        no warnings 'redefine';
        local *Time::HiRes::time = sub { return $tSecond; };
        $ctl->requestTrack($CR04_X, 0, { source => 'onStream', seek => 0 });
    }

    is(scalar(@{ $ws->sent }), 1,
        "$pfx wire-count -- still exactly ONE command on the wire for the getNextTrack+onStream pair");
    ok(!(grep { $_->[0] eq 'seek' } @{ $ws->sent }),
        "$pfx no-seek -- no seek reaches the wire for the second call");
    is($ctl->pending->{uri}, $CR04_X,
        "$pfx pending-on-X -- pending still targets X, open (awaiting the track_changed echo)");
}

# --- R2-CR04 Fall F (W3, IN-02 interaction) -- documented, NOT
# bezeugbar at Control level (Plan-Check-Korrektur F, 82-24-PLAN.md):
# after IN-02's claim-release, isSpotifyConnect($client) is false while
# Control.mode is still 'connect'. canDoAction('rew') then evaluates
# normally (no longer Connect-gated) and CAN return 1; a resulting
# getNextTrack(posMs=0, no seek flag) still hits this plan's
# position-takeover guard, because the guard checks Control.mode
# ('connect'), never Connect::isSpotifyConnect -- the rewind becomes a
# no-op (wanted.position_ms stays at the observed position instead of
# 0). Control.pm never calls isSpotifyConnect (all four call sites
# live in ProtocolHandler.pm:743/815/1205/1233) -- a test here would
# model the exact same state as Fall A/B and prove nothing beyond what
# they already do. Accepted, deferred to Phase 83 (Connect-Policy) per
# <objective>/T-82-9E-W3 in the threat model.
# ============================================================

# ============================================================
# R2-CR03 (82-23, Task 1): a truly unpaired daemon whose FIRST failure
# fell inside UNPAIRED_GRACE_S must still reach errors[] eventually --
# either at the next fail-fast request (_reconcile Schritt 2) or at probe
# exhaustion (_authProbe) -- not stay silent forever. 82-REVIEW.md CR-03
# (Runde 2), corrected: the original 82-11 CR-03 grace suppression is
# CORRECT (Fall A below is unchanged, pre-existing behavior); the bug is
# that NOTHING wrote a ring entry once the grace window passed.
#
# Fall A/D use Slim::Utils::Timers::fire_due with a real Time::HiRes
# offset -- @Slim::Utils::Timers::TIMERS is a FILE-WIDE package global
# that several earlier, unrelated test blocks leave dangling entries in
# (e.g. the "unpaired:" block ~line 645 arms one _authProbe timer and
# never drives or kills it). Because this whole file executes in well
# under a second of real wall-clock time, a fire_due(now+N) call late in
# the file can sweep up those long-dangling foreign timers too. The
# GLOBAL @Plugins::SpotOn::Status::RECORDED array is shared across every
# Control instance, so counting its raw length after a fire_due call is
# not safe here -- filter by THIS block's own mac-qualified key
# (':unpaired' suffix, matching the WR-05 Fall D foreign-entry pattern
# already established above) instead of a bare scalar() count.
# ============================================================

# --- R2-CR03 Fall A -- uptime already past grace when the error frame
# arrives: the ORIGINAL error-frame handler (Control.pm ~2116, unchanged
# by this task) already writes the ring entry immediately. Probe
# exhaustion afterwards is a dedup no-op -- this mac's entry stays at
# exactly one throughout. (Already covered structurally by the
# pre-existing "CR-03: Fall B" block above and Runde-1's "CR-03: Fall D"
# -- this case is not a must-fail proof by itself, per 82-23-PLAN.md
# Task 1 <behavior>: "Der eigentliche Muss-Fehlschlag-Fall ist Fall B.") ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:20', uptime => 100, observed => { wsConnected => 1, meta => {} },
    );
    my $myKey = sub { grep { ($_->[3] // '') eq $daemon->mac . ':unpaired' } @Plugins::SpotOn::Status::RECORDED };

    $ctl->onEvent({ type => 'error', message => 'requires authentication' });
    is(scalar($myKey->()), 1,
        "R2-CR03 Fall A: uptime already past grace -- the original error-frame handler writes immediately");

    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 5.1);
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 10.2);
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 15.3);
    is(scalar($myKey->()), 1,
        "R2-CR03 Fall A: probe exhaustion afterwards is a dedup no-op -- still exactly one entry for this mac");
}

# --- R2-CR03 Fall B/C (must-fail proof) -- the FIRST error falls INSIDE
# the grace window (suppressed, correctly). Time passes (simulated via
# bumping daemon.uptime past the grace threshold). A LATER requestTrack
# call still writes exactly one ring entry via the SAME unconditional
# _recordErrorOnce('unpaired', ...) call at the top of Schritt 2 (82-42A
# Defekt A fix: unchanged) -- but 82-42A changes what happens AFTER that:
# Schritt 2 no longer resolves synchronously for trigger=requestTrack, it
# defers (same _deferredTrackRequest/_wsRetryTimeout/WS_RETRY_TTL_S
# machinery as Schritt 1, see the 82-42A Fall-7/8/9 block near the end of
# this file). No fire_due used for the ring assertion (no cross-
# contamination risk from foreign timers); the deferral itself IS cleaned
# up explicitly below so it cannot leak a live _wsRetryTimeout timer into
# a LATER block's own fire_due() sweep -- the TIMERS queue is global,
# file-wide (see the drift-limit block's own comment earlier in this
# file). ---
{
    @Plugins::SpotOn::Status::RECORDED = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:21', uptime => 5, observed => { wsConnected => 1, meta => {} },
    );

    $ctl->onEvent({ type => 'error', message => 'requires authentication' });
    is($ctl->observed->{paired}, 0, "R2-CR03 Fall B: observed.paired set to 0 by the error frame");
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 0,
        "R2-CR03 Fall B: grace window (uptime=5 < 15) suppresses the ring entry, as designed");

    # Simulate time passing -- the daemon is now confirmed unpaired well
    # past UNPAIRED_GRACE_S, but no ring entry has EVER been written for
    # this state.
    $daemon->{uptime} = 40;

    my $err;
    $ctl->requestTrack($TID, 0, { errorCb => sub { $err = $_[0]; } });

    is($err, undef, "R2-CR03 Fall B/C (82-42A): a requestTrack past the grace window no longer fails synchronously -- it defers instead");
    ok($ctl->_deferredTrackRequest, "R2-CR03 Fall B/C (82-42A): the request is deferred, not dropped");
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 1,
        "R2-CR03 Fall C (GREEN): the fail-fast path in _reconcile Schritt 2 still writes exactly one ring entry before deferring");
    like($Plugins::SpotOn::Status::RECORDED[0][2], qr/not paired/,
        "R2-CR03 Fall C: recorded message mentions 'not paired'");
    like($Plugins::SpotOn::Status::RECORDED[0][3], qr/:unpaired$/,
        "R2-CR03 Fall C: recorded under the 'unpaired' key");

    # Cleanup (82-42A): see the file-wide TIMERS note above.
    Slim::Utils::Timers::killTimers($ctl, \&Plugins::SpotOn::Soloist::Control::_wsRetryTimeout);
    $ctl->_deferredTrackRequest(undef);
}

# --- R2-CR03 Fall D (GREEN, probe exhaustion) -- uptime past grace when
# the error frame arrives (same as Fall A): three exhausted
# get_auth_state probes, without any intervening requestTrack call,
# still leave errors[] holding exactly one 'unpaired' entry for this mac
# -- the literal acceptance criterion ("auch ohne zwischenzeitlichen
# requestTrack-Aufruf"). Structurally this entry originates from the
# unchanged initial error-frame write (uptime > grace makes that write
# succeed immediately); the new exhaustion-branch call in _authProbe is
# a dedup no-op on top of it -- see Fall A's comment for the same
# structural reasoning. Both call sites are exercised; dedup is what
# keeps the ring at exactly one entry either way. $ws->sent (per-instance,
# immune to cross-file timer contamination) confirms all three probes
# actually fired. ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:22', uptime => 100, observed => { wsConnected => 1, meta => {} },
    );
    my $myKey = sub { grep { ($_->[3] // '') eq $daemon->mac . ':unpaired' } @Plugins::SpotOn::Status::RECORDED };

    $ctl->onEvent({ type => 'error', message => 'requires authentication' });

    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 5.1);
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 10.2);
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 15.3);

    is(scalar(@{ $ws->sent }), 3, "R2-CR03 Fall D: three get_auth_state probes sent (AUTH_REPROBE_MAX reached)");
    is($ctl->_authProbeCount, undef, "R2-CR03 Fall D: probe cycle reset after exhaustion");
    is(scalar($myKey->()), 1,
        "R2-CR03 Fall D: exactly one 'unpaired' ring entry for this mac after exhaustion, without any requestTrack call");
}

# ============================================================
# R2-WR01 + R2-WR05 (82-23, Task 2): symmetric `paired` bookkeeping
# (auth_state logged_in:false clears a stale paired=1; _transportClosed
# deletes it entirely) and a rate-limited re-probe trigger so an
# exhausted probe cycle -- or a W2 restore-window paired=0 that never
# armed a probe cycle at all -- has a way out via a later user action.
#
# Fall A/B below use fire_due-driven probe exhaustion; per the same
# reasoning documented above the R2-CR03 block, assertions here read
# $ws->sent (per-instance) rather than any shared package global, so
# they are immune to the cross-contamination risk that affected an
# earlier draft of R2-CR03 Fall A/D.
# ============================================================

# --- R2-WR01 Fall A/B -- logged_in:false clears a stale paired=1 ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:23', observed => { wsConnected => 1, meta => {} },
    );

    $ctl->onEvent({ type => 'auth_state', logged_in => 1 });
    is($ctl->observed->{paired}, 1, "R2-WR01 Fall A/B setup: logged_in:true sets paired=1");

    $ctl->onEvent({ type => 'auth_state', logged_in => 0 });
    is($ctl->observed->{paired}, 0,
        "R2-WR01 Fall B (GREEN): logged_in:false clears a previously-true paired back to 0");
}

# --- R2-WR01 Fall C -- _transportClosed deletes paired entirely (no
# state survives a torn-down transport) ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:24', observed => { wsConnected => 1, meta => {} },
    );

    $ctl->onEvent({ type => 'auth_state', logged_in => 1 });
    is($ctl->observed->{paired}, 1, "R2-WR01 Fall C setup: paired=1 before transport loss");

    $ctl->onEvent({ type => '_transport', state => 'closed' });
    is(exists $ctl->observed->{paired} ? 1 : 0, 0,
        "R2-WR01 Fall C: _transportClosed deletes observed.paired entirely -- not defined, not 0");
}

# --- R2-WR05 Fall A/B -- an exhausted probe cycle gets exactly one
# re-probe from a later user action, rate-limited to AUTH_REPROBE_S.
# 82-42A: the request itself now defers instead of failing synchronously
# (Defekt A fix) -- this Fall's own point (the probe fires BEFORE any
# terminal/deferred decision) is exactly the ordering 82-42A's own read
# depends on and stays unchanged; see the Falle note at this plan's
# Fall-8 below for the dedicated proof. ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:25', uptime => 100, observed => { wsConnected => 1, meta => {} },
    );

    $ctl->onEvent({ type => 'error', message => 'requires authentication' });
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 5.1);
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 10.2);
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 15.3);
    is(scalar(@{ $ws->sent }), 3, "R2-WR05 Fall A/B setup: three probes sent, cycle exhausted");
    is($ctl->_authProbeCount, undef, "R2-WR05 Fall A/B setup: _authProbeCount reset to undef after exhaustion");

    # W5 (Plan-Check-Korrektur): no Time::HiRes stub exists in this
    # harness -- force eligibility directly via the new rw accessor
    # rather than sleeping or faking the clock.
    $ctl->_lastAuthProbeAt(Time::HiRes::time() - 10);

    my $err;
    $ctl->requestTrack($TID, 0, { errorCb => sub { $err = $_[0]; } });

    is($err, undef, "R2-WR05 Fall A/B (82-42A): fail-fast no longer refuses requestTrack synchronously -- it defers");
    ok($ctl->_deferredTrackRequest, "R2-WR05 Fall A/B (82-42A): the request is deferred after the probe fires");
    is(scalar(@{ $ws->sent }), 4,
        "R2-WR05 Fall B (GREEN): a later user action past AUTH_REPROBE_S triggers exactly one more get_auth_state");
    is($ws->sent->[3][0], 'get_auth_state', "R2-WR05 Fall B: the fourth wire command is get_auth_state");
    ok(($ctl->_lastAuthProbeAt // 0) > (Time::HiRes::time() - 1),
        "R2-WR05 Fall B: _lastAuthProbeAt stamped fresh by the reconcile-triggered probe");

    # Cleanup (82-42A): see the R2-CR03 Fall B/C comment above.
    Slim::Utils::Timers::killTimers($ctl, \&Plugins::SpotOn::Soloist::Control::_wsRetryTimeout);
    $ctl->_deferredTrackRequest(undef);
}

# --- R2-WR05 Fall C -- a second requestTrack within AUTH_REPROBE_S of
# the Fall B re-probe does NOT trigger a further get_auth_state
# (rate limiting). 82-42A: both requestTrack calls now defer (Schritt 2)
# instead of failing synchronously -- the second call supersedes the
# first's still-pending deferral (the same Fall-5 convention 82-42 Task C
# established for Schritt 1), which fires no wire traffic of its own, so
# the $ws->sent assertion below is unaffected. ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:26', uptime => 100, observed => { wsConnected => 1, meta => {} },
    );

    $ctl->onEvent({ type => 'error', message => 'requires authentication' });
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 5.1);
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 10.2);
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 15.3);
    $ctl->_lastAuthProbeAt(Time::HiRes::time() - 10);

    $ctl->requestTrack($TID, 0, { errorCb => sub { } });
    is(scalar(@{ $ws->sent }), 4, "R2-WR05 Fall C setup: first later request re-probes once (3 -> 4)");

    # Second request arrives immediately after -- well within
    # AUTH_REPROBE_S of the _lastAuthProbeAt this JUST stamped.
    $ctl->requestTrack($TID, 0, { errorCb => sub { } });
    is(scalar(@{ $ws->sent }), 4,
        "R2-WR05 Fall C: a second request inside AUTH_REPROBE_S does not trigger a fifth probe");
    ok($ctl->_deferredTrackRequest, "R2-WR05 Fall C (82-42A): the second (superseding) request now holds the deferral");

    # Cleanup (82-42A): see the R2-CR03 Fall B/C comment above.
    Slim::Utils::Timers::killTimers($ctl, \&Plugins::SpotOn::Soloist::Control::_wsRetryTimeout);
    $ctl->_deferredTrackRequest(undef);
}

# --- R2-WR05 Fall D (W2 -- Restore-Fall, combines WR-01 + WR-05) -- a
# logged_in:false that arrives WITHOUT a prior login (no error frame
# involved -- the normal session-restore window) sets paired=0 via
# WR-01. UPDATED for 82-26 CR-01: the push itself now ALSO arms the
# bounded re-probe cycle immediately (it no longer waits for a later
# user action to reach Schritt 2) -- so Schritt 2's OWN
# `unless (defined _authProbeCount)` trigger correctly declines to arm
# a second cycle (the same Fall C protection R3-CR01 below exercises
# directly). The eventual probe still fires -- from the 82-26-armed
# cycle itself, once its timer is due. A later logged_in:true resolves
# the state fully; a request after that succeeds. ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:27', observed => { wsConnected => 1, meta => {} },
    );

    is($ctl->_authProbeCount, undef, "R2-WR05 Fall D setup: _authProbeCount undef from the start (never armed)");

    $ctl->onEvent({ type => 'auth_state', logged_in => 0 });
    is($ctl->observed->{paired}, 0, "R2-WR05 Fall D: logged_in:false (no prior login) sets paired=0 via WR-01");
    is($ctl->_authProbeCount, 0, "R2-WR05 Fall D: 82-26 CR-01 arms the bounded re-probe cycle immediately on the push");
    is(scalar(@{ $ws->sent }), 0, "R2-WR05 Fall D: no probe sent yet -- the 82-26-armed cycle's timer has not fired");

    my $err;
    $ctl->requestTrack($TID, 0, { errorCb => sub { $err = $_[0]; } });

    is($err, undef, "R2-WR05 Fall D (82-42A): the request defers instead of failing fast");
    ok($ctl->_deferredTrackRequest, "R2-WR05 Fall D (82-42A): the request is deferred");
    is(scalar(@{ $ws->sent }), 0,
        "R2-WR05 Fall D: Schritt 2's own trigger declines -- the 82-26 cycle already owns this probe (Fall C protection)");

    # Cleanup (82-42A): the rest of this Fall exercises unrelated,
    # pre-existing behavior (the 82-26-armed probe cycle firing, then a
    # SEPARATE, later requestTrack succeeding after login) -- clear THIS
    # first call's deferral now so the login event below does not ALSO
    # replay it (that replay mechanics is this plan's own Fall-7/8/9, not
    # this cadence test).
    Slim::Utils::Timers::killTimers($ctl, \&Plugins::SpotOn::Soloist::Control::_wsRetryTimeout);
    $ctl->_deferredTrackRequest(undef);

    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 5.1);
    is($ws->sent->[0][0], 'get_auth_state', "R2-WR05 Fall D: the 82-26-armed cycle itself fires the probe");

    $ctl->onEvent({ type => 'auth_state', logged_in => 1 });
    is($ctl->observed->{paired}, 1, "R2-WR05 Fall D: a later logged_in:true resolves the state fully");

    my $success;
    $ctl->requestTrack($TID, 0, { successCb => sub { $success = 1; } });
    is($ctl->pending->{uri}, $TID, "R2-WR05 Fall D: the follow-up request now dispatches normally (not fail-fast)");
}


# ============================================================
# R2-WR03 + R2-WR04 (82-23, Task 3): a foreign, non-prefetch track_changed
# in mode=browse is paused and reported (WR-03, with the Plan-Check B1
# `queuedByUs` origin-proof correction); the five Control.pm-side
# errors[] keys added by WR-04 (t1, send, daemon-error, transport, arm).
#
# All new RECORDED assertions below filter by mac-qualified key rather
# than counting the raw array length -- the same reasoning documented at
# the top of the R2-CR03 block above applies file-wide, not just to
# fire_due-driven cases.
# ============================================================

my $WR03_X = 'spotify:track:wr03OwnTrackAAAAAAAAAA';    # the wanted/own track
my $WR03_Z = 'spotify:track:wr03ForeignTrkBBBBBBBBB';    # a foreign, unrequested track

# --- R2-WR03 Fall A/B -- a foreign, non-prefetch track_changed in
# mode=browse pauses and records exactly one autoplay:<uri> entry ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:28', mode => 'browse',
        wanted   => { uri => $WR03_X, playing => 1 },
        # is_active => 1 seeded explicitly (fremder-autoplay-waechter): the
        # guard only fires on the ACTIVE device; without the seed this
        # GREEN case would go silently RED under the is_active gate.
        observed => { wsConnected => 1, track => $WR03_X, status => 'playing', is_active => 1 },
    );

    $ctl->onEvent({ type => 'track_changed', item => { uri => $WR03_Z } });

    is_deeply($ws->sent, [ [ 'pause', {} ] ],
        "R2-WR03 Fall A/B (GREEN): a foreign, non-prefetch track_changed sends exactly one pause");
    my @mine = grep { ($_->[3] // '') eq $daemon->mac . ':autoplay:' . $WR03_Z } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@mine), 1, "R2-WR03 Fall B: exactly one autoplay:<uri> ring entry recorded");
    like($mine[0][2], qr/unrequested/, "R2-WR03 Fall B: recorded message mentions 'unrequested'");
}

# --- R2-WR03 Fall C -- abgrenzung: a confirmed queuedByUs match sends
# nothing and writes no ring entry (the guard's own excuse clause) ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:29', mode => 'browse',
        wanted   => { uri => $WR03_X, playing => 1 },
        observed => { wsConnected => 1, track => $WR03_X, status => 'playing', queuedByUs => { $WR03_Z => 1 } },
    );

    $ctl->onEvent({ type => 'track_changed', item => { uri => $WR03_Z } });

    is_deeply($ws->sent, [], "R2-WR03 Fall C: a queuedByUs match sends nothing");
    my @mine = grep { ($_->[3] // '') eq $daemon->mac . ':autoplay:' . $WR03_Z } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@mine), 0, "R2-WR03 Fall C: no autoplay ring entry when queuedByUs matches");
    is(exists $ctl->observed->{queuedByUs}{$WR03_Z} ? 1 : 0, 0,
        "R2-WR03 Fall C: queuedByUs consumed/cleared once matched, not left to excuse the NEXT foreign track");
}

# --- R2-WR03 Fall D -- abgrenzung: same-track re-announcement is
# unaffected (the pre-existing early-return, unchanged by this task) ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:2a', mode => 'browse',
        wanted   => { uri => $WR03_X, playing => 1 },
        observed => { wsConnected => 1, track => $WR03_Z, status => 'playing' },
    );

    $ctl->onEvent({ type => 'track_changed', item => { uri => $WR03_Z } });

    is_deeply($ws->sent, [], "R2-WR03 Fall D: a same-track re-announcement sends nothing");
    my @mine = grep { ($_->[3] // '') eq $daemon->mac . ':autoplay:' . $WR03_Z } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@mine), 0, "R2-WR03 Fall D: no autoplay ring entry for a same-track re-announcement");
}

# --- R2-WR03 Fall E (Plan-Check B1, must-fail proof against the
# `queuedNext` form -- empirically confirmed by reverting the guard to
# `queuedNext` in a scratch copy, see 82-23-SUMMARY.md) -- the daemon's
# OWN autoplay announcement (queue_changed -> queuedNext) must NOT excuse
# a foreign track_changed for that same uri; only `queuedByUs` (set by
# SpotOn's own _prefetchNext) may. No pending, isolating this from the
# guard's separate !pending clause. ---
{
    my $WR03_E_Z = 'spotify:track:wr03FallEAutoplayCCCC';

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:2b', mode => 'browse',
        wanted   => { uri => $WR03_X, playing => 1 },
        # is_active => 1 seeded explicitly (fremder-autoplay-waechter) --
        # same reason as Fall A/B: the guard is gated on the active device.
        observed => { wsConnected => 1, paired => 1, track => $WR03_X, status => 'playing', is_active => 1 },
    );

    # queue_changed sets queuedNext WITHOUT SpotOn ever having queued
    # anything itself (no _prefetchNext call, no add_to_queue dispatch,
    # no queuedByUs) -- exactly the daemon-side autoplay announcement
    # Plan-Check B1 identified as indistinguishable from a real prefetch
    # if the guard only checked queuedNext.
    $ctl->onEvent({ type => 'queue_changed', upcoming => [ { item => { uri => $WR03_E_Z } } ] });
    is($ctl->observed->{queuedNext}, $WR03_E_Z, "R2-WR03 Fall E setup: queue_changed sets queuedNext");
    is($ctl->pending, undef, "R2-WR03 Fall E setup: no pending open");

    $ctl->onEvent({ type => 'track_changed', item => { uri => $WR03_E_Z } });

    is_deeply($ws->sent, [ [ 'pause', {} ] ],
        "R2-WR03 Fall E (B1, GREEN -- confirmed to fail against the queuedNext form): a foreign autoplay "
        . "the daemon merely ANNOUNCED via queue_changed is still paused, not excused by queuedNext alone");
    my @mine = grep { ($_->[3] // '') eq $daemon->mac . ':autoplay:' . $WR03_E_Z } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@mine), 1, "R2-WR03 Fall E: exactly one autoplay:<uri> ring entry despite queuedNext matching");
}

# --- R2-WR03 Fall F (Gegenprobe) -- a track legitimately prefetched via
# _prefetchNext (queuedByUs set) is NOT paused when the daemon confirms
# it. `pending` is explicitly cleared after _prefetchNext (which itself
# opens a pending add_to_queue slot) so this case isolates queuedByUs
# specifically, the same way Fall E isolates it with no pending at all --
# without this, "no pause" could be explained by the guard's separate
# !pending clause instead of by queuedByUs, and Fall F would prove
# nothing about the B1 correction. ---
{
    my $WR03_F_Z = 'spotify:track:wr03FallFPrefetchDDDD';
    local @Slim::Player::Playlist::ENTRIES = ( undef, Test::MockTrack->new("spoton://track:wr03FallFPrefetchDDDD") );
    local $Slim::Player::Source::INDEX = 0;

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:2c', mode => 'browse',
        wanted   => { uri => $WR03_X, playing => 1 },
        observed => { wsConnected => 1, paired => 1, track => $WR03_X, status => 'playing' },
    );

    $ctl->_prefetchNext;
    ok(exists $ctl->observed->{queuedByUs}{$WR03_F_Z}, "R2-WR03 Fall F setup: _prefetchNext sets queuedByUs");
    @{ $ws->sent } = ();       # only the reaction to track_changed below matters
    $ctl->pending(undef);      # isolate queuedByUs from the guard's separate !pending clause

    $ctl->onEvent({ type => 'track_changed', item => { uri => $WR03_F_Z } });

    is_deeply($ws->sent, [], "R2-WR03 Fall F (Gegenprobe): a legitimately prefetched track is NOT paused");
    my @mine = grep { ($_->[3] // '') eq $daemon->mac . ':autoplay:' . $WR03_F_Z } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@mine), 0, "R2-WR03 Fall F: no autoplay ring entry for a legitimate prefetch confirmation");
    is(exists $ctl->observed->{queuedByUs}{$WR03_F_Z} ? 1 : 0, 0,
        "R2-WR03 Fall F: queuedByUs consumed/cleared on its own confirmed use");
}

# ============================================================
# 84-26 R2 (F-24-1, B7): the autoplay guard (and its replay sibling) leave a MARKER,
# `observed->{autoplayPaused} = <uri>`, when they pause. It survives leaveBrowse (which
# wipes `wanted` only -- the marker lives in `observed`), dies on the next own
# requestTrack, on any observed.track write naming ANOTHER uri, on leaveConnect and on
# the transfer-in clear point. R1 (resume row) and R3 (idle re-adoption hold) read it.
# ============================================================
{
    my $R2_X = 'spotify:track:r2OwnTrackAAAAAAAAAAAA';
    my $R2_Z = 'spotify:track:r2ForeignTrkBBBBBBBBBB';
    my $R2_W = 'spotify:track:r2OtherForeignCCCCCCCC';
    my $r2_guard = sub {
        my ($macTail) = @_;
        my $mac = "aa:84:26:02:00:$macTail";
        my ($ctl, $daemon, $ws) = fresh_control(
            mac => $mac, mode => 'browse',
            wanted   => { uri => $R2_X, playing => 1 },
            observed => { wsConnected => 1, meta => {}, track => $R2_X, status => 'playing', is_active => 1 },
        );
        $ctl->onEvent({ type => 'track_changed', item => { uri => $R2_Z } });
        return ($ctl, $daemon, $ws, $mac);
    };

    # Fall A: the guard's pause leaves the marker; still exactly one pause
    {
        my ($ctl, $daemon, $ws) = $r2_guard->('01');
        is_deeply($ws->sent, [ [ 'pause', {} ] ], "84-26 R2 Fall A setup: the guard sends exactly one pause");
        is($ctl->observed->{autoplayPaused}, $R2_Z, "84-26 R2 Fall A: the guard leaves observed.autoplayPaused = the paused foreign uri");
    }

    # Fall B: the marker survives leaveBrowse (mode idle, wanted wiped)
    {
        my ($ctl, $daemon, $ws) = $r2_guard->('02');
        $ctl->leaveBrowse;
        is($ctl->mode, 'idle', "84-26 R2 Fall B setup: leaveBrowse -> idle");
        is($ctl->observed->{autoplayPaused}, $R2_Z, "84-26 R2 Fall B: the marker survives leaveBrowse");
    }

    # Fall C: the next own requestTrack (any uri) clears it
    {
        my ($ctl, $daemon, $ws, $mac) = $r2_guard->('03');
        own_track($mac);
        $ctl->requestTrack($R2_X, 0, { source => 'getNextTrack', successCb => sub { }, errorCb => sub { } });
        ok(!exists $ctl->observed->{autoplayPaused}, "84-26 R2 Fall C: requestTrack clears the marker (a new own play intent re-targets the daemon)");
    }

    # Fall D: a later track_changed naming ANOTHER uri (foreign, guard excused by queuedByUs) clears it
    {
        my ($ctl, $daemon, $ws) = $r2_guard->('04');
        is($ctl->observed->{autoplayPaused}, $R2_Z, "84-26 R2 Fall D setup: the marker names Z");
        $ctl->observed->{queuedByUs} = { $R2_W => 1 };
        $ctl->onEvent({ type => 'track_changed', item => { uri => $R2_W } });
        is($ctl->observed->{track}, $R2_W, "84-26 R2 Fall D setup: observed.track moved to W");
        ok(!exists $ctl->observed->{autoplayPaused}, "84-26 R2 Fall D: an observed.track write naming another uri clears the marker");
    }

    # Fall E: the replay sibling (_onQueueHeadReplay) leaves the marker too (F-18-N4 change 3 shape)
    {
        my @f = map { decode_frame($_) } load_fixture('f18n4-same1.frames');
        @IO::Socket::INET::CALLS = ();
        my ($ctl, $daemon, $ws) = fresh_control(
            mac => 'aa:84:26:02:00:05', mode => 'browse',
            wanted   => { uri => $N4_6D0C, playing => 1 },
            observed => { wsConnected => 1, meta => {}, track => $N4_6D0C, status => 'playing', is_active => 1 },
        );
        $ctl->onEvent($_) for @f[0 .. 13];
        is_deeply($ws->sent, [ [ 'pause', {} ] ], "84-26 R2 Fall E setup: the replay detector paused (F-18-N4 change 3)");
        is($ctl->observed->{autoplayPaused}, $N4_6D0C, "84-26 R2 Fall E: the replay sibling leaves the marker = the replayed uri");
    }

    # Fall F: a transfer-in is a fresh session -- the marker is gone, mode connect, and a resume in the adopted
    # session still sends the bare play (a stale marker never refuses there)
    {
        @Plugins::SpotOn::Connect::CLAIMS = (); $Plugins::SpotOn::Connect::ACTIVE = undef;
        my ($ctl, $daemon, $ws, $mac) = $r2_guard->('06');
        is($ctl->observed->{autoplayPaused}, $R2_Z, "84-26 R2 Fall F setup: the guard's marker is set");
        $ctl->leaveBrowse;
        $ctl->onEvent(decode_frame(load_fixture('device_changed.json')));
        is($ctl->mode, 'connect', "84-26 R2 Fall F setup: the transfer-in enters connect");
        ok(!exists $ctl->observed->{autoplayPaused}, "84-26 R2 Fall F: the transfer-in clear point deletes the marker");
        own_track($mac);
        $ctl->observed->{status} = 'paused';
        my $n0 = scalar(grep { $_->[0] eq 'play' } @{ $ws->sent });
        $ctl->requestResume;
        my @plays = grep { $_->[0] eq 'play' } @{ $ws->sent };
        is(scalar(@plays) - $n0, 1, "84-26 R2 Fall F: a resume in the adopted connect session sends the bare play");
        $Plugins::SpotOn::Connect::ACTIVE = undef; @Plugins::SpotOn::Connect::CLAIMS = ();
    }

    # Fall G (per player): the marker lives in THIS Control's `observed` -- another player's Control on the same
    # account (the lavender-pa daemon mirrors the same foreign track_changed) keeps none
    {
        my ($ctlA, $daemonA, $wsA) = $r2_guard->('07');
        my ($ctlB, $daemonB, $wsB) = fresh_control(
            mac => 'aa:84:26:02:00:08', mode => 'idle',
            observed => { wsConnected => 1, meta => {}, is_active => 0 },
        );
        $ctlB->onEvent({ type => 'track_changed', item => { uri => $R2_Z } });
        is($ctlA->observed->{autoplayPaused}, $R2_Z, "84-26 R2 Fall G: player A's Control carries the marker");
        ok(!exists $ctlB->observed->{autoplayPaused}, "84-26 R2 Fall G: player B's Control (same foreign title mirrored, not our browse) carries none");
        is_deeply($wsB->sent, [], "84-26 R2 Fall G: and sends nothing");
    }
}

# ============================================================
# 83.1-07 Group D (wr03, .planning/todos/pending/wr03-autoplay-guard-
# pausiert-in-der-late-echo-rennbedingung.md): the Autoplay guard (WR-03
# above) must NOT pause a foreign track_changed that lands INSIDE the
# still-open late-echo window (82-12's expectEcho) -- that frame can be
# the OLD session's auto-advance racing our own just-dispatched `play`,
# whose own echo is about to arrive. Fall-1 proves the exclusion; Fall-2
# (Gegenprobe) proves the guard still fires once the window has expired.
# ============================================================

# --- wr03 Fall-1: foreign Z inside the late-echo window sends no pause;
# the own late echo X still resolves normally afterwards ---
{
    my $WR03B_X = 'spotify:track:wr03bOwnTrackGGGGGGGG';
    my $WR03B_Z = 'spotify:track:wr03bForeignZHHHHHHHH';

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:d1', observed => { wsConnected => 1, meta => {} },
    );

    $ctl->requestTrack($WR03B_X, 0, { successCb => sub { } });
    is($ctl->mode, 'browse', "83.1-07 wr03 Fall-1 setup: requestTrack transitions to mode=browse");
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 0.6);    # T1 fires -- pending released, expectEcho armed for X
    ok($ctl->observed->{expectEcho}, "83.1-07 wr03 Fall-1 setup: expectEcho armed for X after T1");
    is($ctl->pending, undef, "83.1-07 wr03 Fall-1 setup: pending cleared by T1 before the foreign frame arrives");

    @{ $ws->sent } = ();
    $ctl->onEvent({ type => 'track_changed', item => { uri => $WR03B_Z } });    # foreign, INSIDE the window

    is_deeply($ws->sent, [], "83.1-07 wr03 Fall-1: a foreign track_changed inside the late-echo window sends no pause");
    my @mine = grep { ($_->[3] // '') eq $daemon->mac . ':autoplay:' . $WR03B_Z } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@mine), 0, "83.1-07 wr03 Fall-1: no autoplay:<uri> ring entry for the excluded foreign frame");

    $ctl->onEvent({ type => 'track_changed', item => { uri => $WR03B_X } });    # our own late echo, right after

    is_deeply($ws->sent, [], "83.1-07 wr03 Fall-1: the own late echo still resolves without ever sending pause");
    is($ctl->observed->{track}, $WR03B_X, "83.1-07 wr03 Fall-1: observed.track reflects our own late echo (status playing)");
    is($ctl->observed->{expectEcho}, undef, "83.1-07 wr03 Fall-1: the expectation is consumed by the late echo, not left standing");
}

# --- wr03 Fall-2 (Gegenprobe): the same foreign frame, but AFTER the
# late-echo window has expired -- the guard still pauses and records
# autoplay:<uri> (the exclusion is bounded, not open-ended) ---
{
    my $WR03B2_X = 'spotify:track:wr03bOwnTrackIIIIIIII';
    my $WR03B2_Z = 'spotify:track:wr03bForeignZJJJJJJJJ';

    # is_active => 1 seeded explicitly (fremder-autoplay-waechter): stands
    # in for the own-activation device_changed a live browse play produces
    # (P1, live 2026-09-24 23:28:47) -- the guard only fires on the active
    # device; without the seed this Gegenprobe would go silently RED.
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:d2', observed => { wsConnected => 1, meta => {}, is_active => 1 },
    );

    $ctl->requestTrack($WR03B2_X, 0, { successCb => sub { } });
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 0.6);    # T1 fires -- expectEcho armed for X
    ok($ctl->observed->{expectEcho}, "83.1-07 wr03 Fall-2 setup: expectEcho armed for X after T1");
    $ctl->observed->{expectEcho}{until} = Time::HiRes::time() - 1;    # simulate the window having elapsed (WR-01 Fall C technique)

    @{ $ws->sent } = ();
    $ctl->onEvent({ type => 'track_changed', item => { uri => $WR03B2_Z } });    # foreign, AFTER the window

    is_deeply($ws->sent, [ [ 'pause', {} ] ],
        "83.1-07 wr03 Fall-2 (Gegenprobe): a foreign track_changed AFTER the window expired still sends exactly one pause");
    my @mine = grep { ($_->[3] // '') eq $daemon->mac . ':autoplay:' . $WR03B2_Z } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@mine), 1, "83.1-07 wr03 Fall-2: the autoplay:<uri> ring entry is still recorded once the window has expired");
}

# ============================================================
# fremder-autoplay-waechter (.planning/debug/fremder-autoplay-waechter.md,
# todo fremder-autoplay-waechter-pausiert-das-konto.md): EVERY daemon on the
# account mirrors the account-wide track_changed -- also a daemon that is
# NOT the active device (live 2026-09-24 23:28:48.72: idle lavender-pa
# mirrored lavender-UAT's own browse title). A Control left in mode=browse
# on such an uninvolved daemon read the mirrored frame as its OWN
# unrequested autoplay and paused THE ACCOUNT, i.e. another player's music
# (live 2026-09-24 11:32:29: lavender-UAT paused lavender-pa). Only the
# active device can have advanced on its own, so the guard is gated on
# observed.is_active. R2-WR03 Fall A/B, Fall E and wr03 Fall-2 above seed
# is_active => 1 for exactly this reason.
# ============================================================

# --- fremd RED-1: mode=browse, wanted.uri X, observed on X playing, but
# is_active 0 -> a mirrored foreign track_changed Z sends nothing and
# records no autoplay:Z ring entry ---
{
    my $F1_X = 'spotify:track:fremdOwnTrackKKKKKKKKK';
    my $F1_Z = 'spotify:track:fremdForeignZLLLLLLLLL';

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:d3', mode => 'browse',
        wanted   => { uri => $F1_X, playing => 1 },
        observed => { wsConnected => 1, track => $F1_X, status => 'playing', is_active => 0 },
    );

    $ctl->onEvent({ type => 'track_changed', item => { uri => $F1_Z } });

    is_deeply($ws->sent, [],
        "fremd RED-1: a mirrored foreign track_changed on an INACTIVE daemon (mode=browse) sends no pause");
    my @mine = grep { ($_->[3] // '') eq $daemon->mac . ':autoplay:' . $F1_Z } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@mine), 0, "fremd RED-1: no autoplay:<uri> ring entry on an inactive daemon");
    is($ctl->observed->{track}, $F1_Z, "fremd RED-1: observed.track still follows the mirrored frame");
}

# --- fremd RED-2: the live sequence -- own browse play X (device_changed
# true = own activation, own echo X), then the account moves to another
# player (device_changed false, mode stays browse), then that player's
# track change Z is mirrored here -> no pause, observed.track Z, mode still
# browse ---
{
    my $F2_X = 'spotify:track:fremdOwnTrackMMMMMMMMM';
    my $F2_Z = 'spotify:track:fremdForeignZNNNNNNNNN';

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:d4', observed => { wsConnected => 1, meta => {} },
    );

    $ctl->requestTrack($F2_X, 0, { successCb => sub { } });
    is($ctl->mode, 'browse', "fremd RED-2 setup: requestTrack transitions to mode=browse");
    $ctl->onEvent({ type => 'device_changed', is_active => 1, device_name => 'lavender-UAT' });
    is($ctl->observed->{is_active}, 1, "fremd RED-2 setup: own activation sets observed.is_active (P1)");
    is($ctl->mode, 'browse', "fremd RED-2 setup: own activation stays browse");
    $ctl->onEvent({ type => 'track_changed', item => { uri => $F2_X } });
    is($ctl->pending, undef, "fremd RED-2 setup: the own echo settles pending");
    is($ctl->observed->{track}, $F2_X, "fremd RED-2 setup: observed.track is the own title");

    $ctl->onEvent({ type => 'device_changed', is_active => 0, device_name => 'lavender-UAT' });
    is($ctl->observed->{is_active}, 0, "fremd RED-2 setup: device_changed false clears observed.is_active (P2)");
    # 84.1-02 (D-01(a), Task 2): the stale-mode root cause this comment
    # used to call "out of scope" is exactly what this plan fixes -- a
    # browse-side is_active:false now leaves browse (mode idle), the same
    # session-loss trigger IA-7/A8/A9 pin. Only this mode expectation
    # changes; the no-pause/no-ring-entry/track-follows-mirror properties
    # below are unchanged.
    is($ctl->mode, 'idle', "fremd RED-2 setup: a browse-side is_active:false now leaves browse (D-01(a))");

    @{ $ws->sent } = ();
    $ctl->onEvent({ type => 'track_changed', item => { uri => $F2_Z } });

    is_deeply($ws->sent, [],
        "fremd RED-2: after the account moved away, the mirrored foreign track_changed sends no pause");
    my @mine = grep { ($_->[3] // '') eq $daemon->mac . ':autoplay:' . $F2_Z } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@mine), 0, "fremd RED-2: no autoplay:<uri> ring entry after the account moved away");
    is($ctl->observed->{track}, $F2_Z, "fremd RED-2: observed.track follows the mirrored frame");
    is($ctl->mode, 'idle', "fremd RED-2: mode stays idle (D-01(a): the stale-mode root cause is fixed by this plan)");
}

# --- R2-WR04 Fall A/B (t1, with clear) -- T1 timeout writes t1:<uri>;
# a later late echo for the same uri clears it ---
{
    my $WR04_T1_X = 'spotify:track:wr04T1TimeoutEEEEEEE';

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:2d', mode => 'browse', observed => { wsConnected => 1, meta => {} },
    );

    $ctl->requestTrack($WR04_T1_X, 0, {});
    is($ctl->pending->{uri}, $WR04_T1_X, "R2-WR04 Fall A/B setup: play dispatched, pending open");

    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 1);

    my @mine = grep { ($_->[3] // '') eq $daemon->mac . ':t1:' . $WR04_T1_X } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@mine), 1, "R2-WR04 Fall B (GREEN): T1 timeout writes exactly one t1:<uri> entry");
    like($mine[0][2], qr/no track_changed within/, "R2-WR04 Fall B: recorded message matches the T1 warning");

    $ctl->onEvent({ type => 'track_changed', item => { uri => $WR04_T1_X } });    # late echo

    my @after = grep { ($_->[3] // '') eq $daemon->mac . ':t1:' . $WR04_T1_X } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@after), 0, "R2-WR04 Fall B: a late echo clears the t1:<uri> ring entry");
}

# --- R2-WR04 Fall C (send) -- a wire-level send failure writes
# send:<cmd> (A2: no clear path in this plan, documented in SUMMARY) ---
{
    my $WR04_SEND_X = 'spotify:track:wr04SendFailFFFFFFF';

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:2e', send_success => 0, observed => { wsConnected => 1, meta => {} },
    );

    my $err;
    $ctl->requestTrack($WR04_SEND_X, 0, { errorCb => sub { $err = $_[0] } });

    is($err, 'PROBLEM_OPENING', "R2-WR04 Fall C: send failure still fires errorCb");
    my @mine = grep { ($_->[3] // '') eq $daemon->mac . ':send:play' } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@mine), 1, "R2-WR04 Fall C: send failure writes exactly one send:play entry");
    like($mine[0][2], qr/send failed/, "R2-WR04 Fall C: recorded message mentions 'send failed'");
}

# --- R2-WR04 Fall D (daemon-error) -- a correlated daemon error frame
# (NOT "requires authentication") writes daemon-error (A2: no clear path
# in this plan, documented in SUMMARY) ---
{
    my $WR04_DAEMON_X = 'spotify:track:wr04DaemonErrGGGGGG';

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:2f', observed => { wsConnected => 1, meta => {} },
    );

    my $error_type;
    $ctl->requestTrack($WR04_DAEMON_X, 0, { errorCb => sub { $error_type = $_[0] } });
    $ctl->onEvent({ type => 'error', message => 'daemon rejected play' });

    is($error_type, 'PROBLEM_OPENING', "R2-WR04 Fall D setup: correlated error still fires errorCb (baseline, unchanged)");
    # 82-28 (WR-02): the key is now content-hashed (daemon-error:<md5>)
    # instead of the single fixed 'daemon-error' key -- match the prefix,
    # not the exact old key.
    my $wr04d_prefix = $daemon->mac . ':daemon-error:';
    my @mine = grep { ($_->[3] // '') =~ /^\Q$wr04d_prefix\E/ } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@mine), 1, "R2-WR04 Fall D: correlated daemon error writes exactly one daemon-error entry");
    like($mine[0][2], qr/daemon rejected play/, "R2-WR04 Fall D: recorded message includes the daemon's own message");
}

# --- R2-WR04 Fall E (transport, with clear) -- transport loss writes
# transport; a reopened transport clears it ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:30', observed => { wsConnected => 1, meta => {} },
    );

    $ctl->onEvent({ type => '_transport', state => 'closed' });

    my @mine = grep { ($_->[3] // '') eq $daemon->mac . ':transport' } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@mine), 1, "R2-WR04 Fall E: transport loss writes exactly one transport entry");
    like($mine[0][2], qr/WS transport lost/, "R2-WR04 Fall E: recorded message mentions transport loss");

    $ctl->onEvent({ type => '_transport', state => 'open' });

    my @after = grep { ($_->[3] // '') eq $daemon->mac . ':transport' } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@after), 0, "R2-WR04 Fall E: a reopened transport clears the transport ring entry");
}

# --- R2-WR04 Fall F (arm, with clear) -- a failed sync seek-arm writes
# arm; a later successful arm clears it ---
{
    my $WR04_ARM_X = 'spotify:track:wr04ArmFailHHHHHHHH';

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:31',
        observed => { wsConnected => 1, meta => {}, track => $WR04_ARM_X, status => 'playing' },
    );

    {
        local $IO::Socket::INET::FAIL = 1;
        $ctl->requestTrack($WR04_ARM_X, 5000, { source => 'onStream', seek => 1 });
    }

    my @mine = grep { ($_->[3] // '') eq $daemon->mac . ':arm' } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@mine), 1, "R2-WR04 Fall F: a failed sync seek-arm writes exactly one arm entry");
    like($mine[0][2], qr/sync seek-arm failed/, "R2-WR04 Fall F: recorded message mentions the arm failure");

    my $ok = $ctl->_armSync;

    is($ok, 1, "R2-WR04 Fall F: a subsequent arm succeeds (IO::Socket::INET::FAIL scoped to the block above)");
    my @after = grep { ($_->[3] // '') eq $daemon->mac . ':arm' } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@after), 0, "R2-WR04 Fall F: a subsequent successful arm clears the ring entry");
}

# ============================================================
# R3-CR01 (82-26, Review Runde 3 -- Critical): a `logged_in:false`
# arriving while the daemon's own session restore is still running (the
# unprompted handshake-time push, or the reply to a get_auth_state) now
# arms the SAME bounded re-probe cycle the `error` branch has used
# since 82-11, instead of latching paired=0 forever. `_authProbe`
# aborts the cycle by itself once `paired` turns true or the transport
# is gone -- the new code needs no bespoke abort logic of its own. The
# `_lastAuthProbeAt` guard (PLAN-CHECK-KORREKTUR B1) is the load-
# bearing half of the fix: without it, the reply to the daemon's OWN
# probe re-arms a fresh cycle every AUTH_REPROBE_S, forever (see
# 82-26-SUMMARY.md for the measured probe count of both variants).
#
# @Slim::Utils::Timers::TIMERS is a FILE-WIDE package global (see the
# R2-CR03 comment above) -- every timer-count assertion below filters
# by `$_->[0] == $ctl` (this block's own Control instance), never a
# bare scalar() over the whole array. $ws->sent is per-instance (a
# fresh Test::FakeWs per fresh_control call) and needs no such
# filtering. @Plugins::SpotOn::Status::RECORDED assertions filter by
# this block's own mac-qualified ':unpaired' key, same convention as
# every block above.
# ============================================================

my $authProbeTimers = sub {
    my $ctl = shift;
    return scalar grep { $_->[0] == $ctl && $_->[2] == \&Plugins::SpotOn::Soloist::Control::_authProbe }
        @Slim::Utils::Timers::TIMERS;
};

# --- R3-CR01 Fall A (82-42A closes the "documented gap" this Fall
# originally proved: a play attempted in the first AUTH_REPROBE_S after
# the push used to fail outright for trigger=requestTrack -- Schritt 2 now
# defers instead of firing errorCb terminally, Defekt A fix, same
# _deferredTrackRequest/_wsRetryTimeout/WS_RETRY_TTL_S machinery as
# Schritt 1). The push itself already armed the bounded probe cycle (its
# timer has not fired yet -- no fire_due runs between the push and the
# play), so Schritt 2's OWN `unless (defined _authProbeCount)` trigger
# still correctly declines to arm a second one (Fall C's protection,
# exercised here as a side effect) before deferring. The request now
# waits for that already-armed cycle's own resolution instead of failing
# -- Fall B below (unchanged) shows that resolution after one cycle. ---
{
    @Plugins::SpotOn::Status::RECORDED = ();
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:62', uptime => 3, observed => { wsConnected => 0, meta => {} },
    );

    $ctl->onEvent({ type => '_transport', state => 'open' });
    $ctl->onEvent({ type => 'auth_state', logged_in => 0 });

    is($ctl->observed->{paired}, 0, "R3-CR01 Fall A setup: the handshake-time push still sets paired=0");
    is($ctl->_authProbeCount, 0, "R3-CR01 Fall A: the push itself arms a bounded re-probe cycle (authProbeCount=0)");
    is($authProbeTimers->($ctl), 1, "R3-CR01 Fall A: exactly one _authProbe timer is armed for this instance");

    $daemon->{uptime} = 20;
    my ($ok, $err);
    $ctl->requestTrack($TID, 0, { successCb => sub { $ok = 1 }, errorCb => sub { $err = $_[0] } });

    is($ok, undef, "R3-CR01 Fall A: a play attempted before the armed cycle has fired still does not succeed yet");
    is($err, undef, "R3-CR01 Fall A (82-42A): the request defers instead of failing fast -- the gap this Fall proved is now closed for requestTrack");
    ok($ctl->_deferredTrackRequest, "R3-CR01 Fall A (82-42A): the request is deferred");
    my @ring = grep { ($_->[3] // '') eq $daemon->mac . ':unpaired' } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@ring), 1, "R3-CR01 Fall A: the deferred path still writes the unpaired ring entry");
    is($ctl->_authProbeCount, 0, "R3-CR01 Fall A: the deferred play does not disturb the already-armed cycle (Fall C protection)");

    # Cleanup (82-42A): see the R2-CR03 Fall B/C comment above.
    Slim::Utils::Timers::killTimers($ctl, \&Plugins::SpotOn::Soloist::Control::_wsRetryTimeout);
    $ctl->_deferredTrackRequest(undef);
}

# --- R3-CR01 Fall B (GREEN -- the actual fix assertion) -- after one
# AUTH_REPROBE_S cycle, the daemon's login reply resolves paired=1 and
# the follow-up play succeeds with NO ring entry. ---
{
    @Plugins::SpotOn::Status::RECORDED = ();
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:63', uptime => 3, observed => { wsConnected => 0, meta => {} },
    );

    $ctl->onEvent({ type => '_transport', state => 'open' });
    $ctl->onEvent({ type => 'auth_state', logged_in => 0 });
    is($ctl->_authProbeCount, 0, "R3-CR01 Fall B setup: the push arms the cycle (authProbeCount=0)");
    is($authProbeTimers->($ctl), 1, "R3-CR01 Fall B setup: exactly one _authProbe timer armed");

    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 5.1);
    is($ws->sent->[0][0], 'get_auth_state', "R3-CR01 Fall B: the armed cycle fires get_auth_state after AUTH_REPROBE_S");

    $ctl->onEvent({ type => 'auth_state', logged_in => 1 });
    is($ctl->observed->{paired}, 1, "R3-CR01 Fall B (GREEN): the daemon's login reply resolves paired=1");
    is($ctl->_authProbeCount, undef, "R3-CR01 Fall B: login clears the probe cycle (_authProbeCount undef)");
    is($authProbeTimers->($ctl), 0, "R3-CR01 Fall B: no _authProbe timer remains armed after login");

    $daemon->{uptime} = 20;
    my $err;
    $ctl->requestTrack($TID, 0, { errorCb => sub { $err = $_[0] } });
    is(scalar(grep { $_->[0] eq 'play' } @{ $ws->sent }), 1, "R3-CR01 Fall B (GREEN): the first play after login sends play");
    is($err, undef, "R3-CR01 Fall B: the play no longer fails");
    my @ring = grep { ($_->[3] // '') eq $daemon->mac . ':unpaired' } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@ring), 0, "R3-CR01 Fall B: no unpaired ring entry for this mac");
}

# --- R3-CR01 Fall C (no double-arming) -- two consecutive
# logged_in:false pushes arm exactly one cycle; a push while the
# `error` branch's own cycle is already running arms no second one
# either. ---
{
    @Plugins::SpotOn::Status::RECORDED = ();
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:64', uptime => 3, observed => { wsConnected => 1, meta => {} },
    );

    $ctl->onEvent({ type => 'auth_state', logged_in => 0 });
    is($authProbeTimers->($ctl), 1, "R3-CR01 Fall C setup: the first push arms exactly one timer");

    $ctl->onEvent({ type => 'auth_state', logged_in => 0 });
    is($authProbeTimers->($ctl), 1, "R3-CR01 Fall C: a second logged_in:false push does not arm a second timer");
    is($ctl->_authProbeCount, 0, "R3-CR01 Fall C: authProbeCount stays at 0, not re-armed");
}
{
    @Plugins::SpotOn::Status::RECORDED = ();
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:65', uptime => 100, observed => { wsConnected => 1, meta => {} },
    );

    $ctl->onEvent({ type => 'error', message => 'requires authentication' });
    is($authProbeTimers->($ctl), 1, "R3-CR01 Fall C setup: the error branch arms its own cycle first");

    $ctl->onEvent({ type => 'auth_state', logged_in => 0 });
    is($authProbeTimers->($ctl), 1, "R3-CR01 Fall C: a logged_in:false push while the error branch's cycle runs does not double-arm");
}

# --- R3-CR01 Fall D (True branch unchanged) -- logged_in:true sets
# paired=1, kills the probe timer, clears _authProbeCount and the
# unpaired ring entry -- byte-identical to the pre-plan True branch. ---
{
    @Plugins::SpotOn::Status::RECORDED = ();
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:66', uptime => 100, observed => { wsConnected => 1, meta => {} },
    );

    $ctl->onEvent({ type => 'error', message => 'requires authentication' });
    my @ring_before = grep { ($_->[3] // '') eq $daemon->mac . ':unpaired' } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@ring_before), 1, "R3-CR01 Fall D setup: the error branch wrote the unpaired ring entry");
    is($authProbeTimers->($ctl), 1, "R3-CR01 Fall D setup: the error branch armed a probe cycle");

    $ctl->onEvent({ type => 'auth_state', logged_in => 1 });

    is($ctl->observed->{paired}, 1, "R3-CR01 Fall D: logged_in:true sets paired=1 -- unchanged from the pre-plan True branch");
    is($ctl->_authProbeCount, undef, "R3-CR01 Fall D: logged_in:true clears _authProbeCount to undef");
    is($authProbeTimers->($ctl), 0, "R3-CR01 Fall D: logged_in:true kills the running probe timer");
    my @ring_after = grep { ($_->[3] // '') eq $daemon->mac . ':unpaired' } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@ring_after), 0, "R3-CR01 Fall D: logged_in:true clears the unpaired ring entry");
}

# --- R3-CR01 Fall E (Abgrenzung: echt ungepairter Daemon UND
# Begrenztheitsnachweis) -- a genuinely unpaired daemon that answers
# EVERY probe with logged_in:false (the real-world daemon behaviour)
# gets exactly AUTH_REPROBE_MAX probes and no more; a request after
# exhaustion still writes the unpaired ring entry -- the fix does not
# silence the real case (82-23 CR-03). 82-42A: point 4's request now
# defers (Schritt 2, Defekt A fix) instead of failing fast -- this daemon
# never resolves in this Fall's own scenario, so nothing in production
# ever clears that deferral either; it would sit until WS_RETRY_TTL_S
# (this plan's own Fall-8 covers that path directly). Points 1-3 are the
# actual content of this Fall (Plan-Check B1); point 4 alone would not
# distinguish the fix from the endless-cycle regression variant (see
# 82-26-SUMMARY.md for the counter-measurement). ---
{
    @Plugins::SpotOn::Status::RECORDED = ();
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:67', uptime => 100, observed => { wsConnected => 1, meta => {} },
    );

    $ctl->onEvent({ type => 'auth_state', logged_in => 0 });
    my $now = Time::HiRes::time();
    for my $i (1 .. 3) {
        Slim::Utils::Timers::fire_due($now + $i * 5 + 0.1);
        $ctl->onEvent({ type => 'auth_state', logged_in => 0 });
    }
    is(scalar(grep { $_->[0] eq 'get_auth_state' } @{ $ws->sent }), 3,
        "R3-CR01 Fall E point 1: exactly three get_auth_state probes sent after three answered rounds");

    is($authProbeTimers->($ctl), 0, "R3-CR01 Fall E point 2: no _authProbe timer remains after exhaustion");
    is($ctl->_authProbeCount, undef, "R3-CR01 Fall E point 2: _authProbeCount is undef after exhaustion");

    Slim::Utils::Timers::fire_due($now + 4 * 5 + 0.1);
    is(scalar(grep { $_->[0] eq 'get_auth_state' } @{ $ws->sent }), 3,
        "R3-CR01 Fall E point 3: a further fire_due does not produce a fourth probe");

    my $err;
    $ctl->requestTrack($TID, 0, { errorCb => sub { $err = $_[0] } });
    is($err, undef, "R3-CR01 Fall E point 4 (82-42A): a genuinely unpaired daemon no longer fails synchronously -- it defers, same as every other Schritt-2 requestTrack");
    ok($ctl->_deferredTrackRequest, "R3-CR01 Fall E point 4 (82-42A): the request is deferred, not dropped");
    my @ring = grep { ($_->[3] // '') eq $daemon->mac . ':unpaired' } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@ring), 1, "R3-CR01 Fall E point 4: the unpaired ring entry still stands (82-23 CR-03 not silenced)");

    # Cleanup (82-42A): see the R2-CR03 Fall B/C comment above.
    Slim::Utils::Timers::killTimers($ctl, \&Plugins::SpotOn::Soloist::Control::_wsRetryTimeout);
    $ctl->_deferredTrackRequest(undef);
}

# --- R3-CR01 Fall F (Gegenprobe zu Fall E: Handshake-Push armiert
# trotzdem) -- a fresh Control with NO prior probe history at all
# (_lastAuthProbeAt unset) still gets armed by the handshake-time push
# -- the _lastAuthProbeAt guard must not be strict enough to swallow
# the handshake push itself, or the plan would not close CR-01 at
# all. ---
{
    @Plugins::SpotOn::Status::RECORDED = ();
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:68', uptime => 3, observed => { wsConnected => 0, meta => {} },
    );

    $ctl->onEvent({ type => '_transport', state => 'open' });
    $ctl->onEvent({ type => 'auth_state', logged_in => 0 });

    is($ctl->_authProbeCount, 0, "R3-CR01 Fall F: the handshake push arms the cycle even with no prior probe history");
    is($authProbeTimers->($ctl), 1, "R3-CR01 Fall F: exactly one _authProbe timer is armed for a never-before-probed daemon");
}

# --- R3-CR01 Fall G (82-29, Review Runde 4 -- WR-02, Muss-Fehlschlag-
# Nachweis; committete Endform positiv): a reconnect whose new handshake
# push lands within AUTH_REPROBE_S of the PREVIOUS transport's last
# probe must still arm a fresh cycle on the new transport -- the R4-A
# reproduction. Vor der Aenderung armiert der Reconnect-Push nichts
# (Trockenlauf, gemessen: timers=0 nach dem Reconnect-Push -- siehe
# 82-29-SUMMARY.md fuer die woertliche Ausgabe). ---
{
    @Plugins::SpotOn::Status::RECORDED = ();
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:69', uptime => 3, observed => { wsConnected => 0, meta => {} },
    );

    $ctl->onEvent({ type => '_transport', state => 'open' });
    $ctl->onEvent({ type => 'auth_state', logged_in => 0 });
    is($authProbeTimers->($ctl), 1, "R3-CR01 Fall G setup: the handshake push arms the cycle");

    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 5.1);
    is(scalar(grep { $_->[0] eq 'get_auth_state' } @{ $ws->sent }), 1, "R3-CR01 Fall G setup: the first probe fires and stamps _lastAuthProbeAt");
    $ctl->onEvent({ type => 'auth_state', logged_in => 0 });    # reply to our own probe -- must not re-arm (Fall C protection)

    $ctl->onEvent({ type => '_transport', state => 'closed' });
    is($ctl->_authProbeCount, undef, "R3-CR01 Fall G setup: the closed transport clears authProbeCount");
    is($authProbeTimers->($ctl), 0, "R3-CR01 Fall G setup: the closed transport kills the pending probe timer");

    $ctl->onEvent({ type => '_transport', state => 'open' });
    $ctl->onEvent({ type => 'auth_state', logged_in => 0 });

    is($authProbeTimers->($ctl), 1, "R3-CR01 Fall G: the reconnect's new handshake push arms a fresh cycle on the new transport");
    is($ctl->_authProbeCount, 0, "R3-CR01 Fall G: the new transport gets its own full probe budget (authProbeCount=0)");
}

# --- R3-CR01 Fall H (82-29, Review Runde 4 -- WR-02, kein Sondierungssturm
# bei schnellen Reconnects): Teil 1 (Absicherung, PLAN-CHECK-KORREKTUR W1
# -- besteht identisch vor und nach der Aenderung, weil ohne fire_due nie
# eine Sondierung tatsaechlich feuert): dreimal in Folge open->push->close
# OHNE fire_due dazwischen sendet nie mehr als einen Timer gleichzeitig und
# keine einzige tatsaechliche get_auth_state-Sondierung. Teil 2 (der
# eigentliche Regressionswaechter, W1s Fortsetzung -- misst denselben
# Mechanismus wie Fall G, damit ueberhaupt ein gefeuerter Stempel
# existiert, den die Ruecksetzung betreffen kann): nach den drei schnellen
# Runden ein Zyklus MIT einer tatsaechlich feuernden Sondierung vor dem
# Reconnect, danach vier Antwortrunden. PLAN-CHECK-KORREKTUR (Ausfuehrung,
# 2026-09-11): der im Plan genannte Vorher-Wert 3 ist am echten Code NICHT
# reproduzierbar -- der Reconnect-Push armiert am ungefixten Code ueberhaupt
# nichts (Blindstelle wie in Fall G), daher bleibt es bei der EINEN
# Sondierung von vor dem Close; gemessen: 1 (ungefixt) vs. 4 (gefixt), nicht
# 3 vs. 4 wie im Plan geschaetzt. Siehe 82-29-SUMMARY.md fuer den woertlichen
# Trockenlauf beider Codestaende. ---
{
    @Plugins::SpotOn::Status::RECORDED = ();
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:6a', uptime => 3, observed => { wsConnected => 0, meta => {} },
    );

    for my $i (1 .. 3) {
        $ctl->onEvent({ type => '_transport', state => 'open' });
        $ctl->onEvent({ type => 'auth_state', logged_in => 0 });
        is($authProbeTimers->($ctl), 1, "R3-CR01 Fall H round $i: one timer armed after the push");
        $ctl->onEvent({ type => '_transport', state => 'closed' });
        is($authProbeTimers->($ctl), 0, "R3-CR01 Fall H round $i: zero timers after the close -- never more than one at once");
    }
    is(scalar(grep { $_->[0] eq 'get_auth_state' } @{ $ws->sent }), 0, "R3-CR01 Fall H: no probe reaches the wire without a timer ever firing -- three rapid reconnects send nothing (regression guard, holds before and after)");

    # Teil 2: a cycle that actually fires once before the reconnect, so the
    # stamp the fix resets has a value to carry.
    $ctl->onEvent({ type => '_transport', state => 'open' });
    $ctl->onEvent({ type => 'auth_state', logged_in => 0 });
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 5.1);
    $ctl->onEvent({ type => 'auth_state', logged_in => 0 });
    $ctl->onEvent({ type => '_transport', state => 'closed' });

    $ctl->onEvent({ type => '_transport', state => 'open' });
    $ctl->onEvent({ type => 'auth_state', logged_in => 0 });

    my $now = Time::HiRes::time();
    for my $i (1 .. 4) {
        $now += 5.1;
        Slim::Utils::Timers::fire_due($now);
        $ctl->onEvent({ type => 'auth_state', logged_in => 0 });
    }
    is(scalar(grep { $_->[0] eq 'get_auth_state' } @{ $ws->sent }), 4, "R3-CR01 Fall H: the reconnect after a fired probe gets its own bounded 3-probe cycle (1 before the close + 3 after) -- 1 without the fix (measured, corrects the plan's estimated 3)");
    is($authProbeTimers->($ctl), 0, "R3-CR01 Fall H: no probe timer remains armed once the new cycle exhausts");
}

# ============================================================
# R3-WR01 (82-27, Review Runde 3, WR-01): the 82-22 CR-02 fold mechanism
# (`postPauseIsStop`) reaches the SIBLING `_dispatch('pause')` call site
# too -- the not-ours branch of `requestPause` -- and a real Stop's replay
# survives `leaveBrowse` wiping `wanted` to `{}`. Both halves are needed:
# passing `isStop` alone still does nothing once `leaveBrowse` has cleared
# `wanted->{playing}` back to undef (82-REVIEW.md WR-01).
# ============================================================

# --- R3-WR01 Fall A (Muss-Fehlschlag-Nachweis, committete Endform traegt
# die UMGEDREHTE Zusicherung): browse, requestTrack(X) -> play X pending;
# LMS is on a FOREIGN song (foreign_track) when the Stop arrives --
# `_lmsSongIsOurs` is false, so requestPause(1) takes the not-ours branch.
# Before the fix: the echo's wire was [play][seek], no pause (quoted
# verbatim in 82-27-SUMMARY.md, captured by reverting this plan's fix).
# After the fix (this committed assertion): pause DOES reach the wire. ---
{
    local $Slim::Player::Source::PLAYMODE = 'stop';

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:71', observed => { wsConnected => 1, meta => { $TID => { duration => 200 } }, status => 'paused' },
    );
    foreign_track('aa:bb:cc:dd:ee:71');

    $ctl->requestTrack($TID, 0, {});
    $ctl->requestPause(1);    # not-ours branch: _lmsSongIsOurs is false

    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    # Single physical line -- the per-Fall gate in 82-27-PLAN.md is
    # line-based (`grep -cE`), so the call and its "R3-WR01 Fall A" label
    # must share a line, not just a statement.
    my $expectedWireA = [ [ 'play', { uri => $TID } ], [ 'seek', { position_ms => 0 } ], [ 'pause', {} ] ];
    is_deeply($ws->sent, $expectedWireA, "R3-WR01 Fall A -- not-ours branch: a folded Stop's pause DOES reach the wire on echo replay (fixed)");
}

# --- R3-WR01 Fall B (GREEN, both replay paths): postPauseIsStop is 1
# right after requestPause(1) on the not-ours branch, and BOTH replay
# callers (the echo AND T1's timeout) dispatch the pause -- not only one
# of the two, mirroring R2-CR02's already-fixed ours-branch coverage. ---
{
    local $Slim::Player::Source::PLAYMODE = 'stop';

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:72', observed => { wsConnected => 1, meta => { $TID => { duration => 200 } }, status => 'paused' },
    );
    foreign_track('aa:bb:cc:dd:ee:72');

    $ctl->requestTrack($TID, 0, {});
    $ctl->requestPause(1);

    is($ctl->pending && $ctl->pending->{postPauseIsStop}, 1, "R3-WR01 Fall B -- postPauseIsStop is recorded on the not-ours fold too, not only on the ours branch (R2-CR02)");

    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    is_deeply($ws->sent->[-1], [ 'pause', {} ], "R3-WR01 Fall B -- echo replay path: pause is the LAST frame on the wire");
}

# --- R3-WR01 Fall B, T1 variant: same not-ours fold, but replayed via
# T1's timeout instead of the echo -- T1 drops a folded postSeek but must
# still replay the folded Stop, exactly like R2-CR02 Fall C's ours-branch
# counterpart. ---
{
    local $Slim::Player::Source::PLAYMODE = 'stop';

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:73', observed => { wsConnected => 1, meta => {}, status => 'paused' },
    );
    foreign_track('aa:bb:cc:dd:ee:73');

    $ctl->requestTrack($TID, 0, {});
    $ctl->requestPause(1);

    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 0.6);    # T1 fires -- replay via _t1Fire, not the echo

    is_deeply($ws->sent, [ [ 'play', { uri => $TID } ], [ 'pause', {} ] ], "R3-WR01 Fall B -- T1's own replay also dispatches the not-ours branch's folded Stop (no seek -- T1 drops postSeek)");
}

# --- R3-WR01 Fall C (Regressionsschutz 82-11 CR-03 -- der wichtigste Fall
# dieses Plans): a fresh Control's `_transport open` must still send
# NOTHING -- the `defined $wanted->{playing}` guard stays in force for
# every trigger except a real requestPause Stop. Same assertion as
# "CR-03: Fall A -- fresh Control, _transport open sends nothing" above
# (not blindly duplicated -- referenced here so this plan's own
# per-Fall gate can see a `R3-WR01 Fall C`-named case); a fix that
# widened the guard to `$opts->{isStop}` alone, or dropped `defined`
# outright, would turn this RED. ---
{
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:ee:74');

    $ctl->onEvent({ type => '_transport', state => 'open' });

    is_deeply($ws->sent, [], "R3-WR01 Fall C -- fresh Control, _transport open sends nothing (82-11 CR-03 not reopened)");
}

# --- R3-WR01 Fall D (Abgrenzung: Pause ohne isStop) -- the same not-ours
# branch, but requestPause(0): the `if $isStop` guard at the call site is
# unchanged by this plan -- no fold, no dispatch, nothing beyond the
# original requestTrack's own `play`. ---
{
    local $Slim::Player::Source::PLAYMODE = 'stop';

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:75', observed => { wsConnected => 1, meta => { $TID => { duration => 200 } }, status => 'paused' },
    );
    foreign_track('aa:bb:cc:dd:ee:75');

    $ctl->requestTrack($TID, 0, {});
    $ctl->requestPause(0);

    is_deeply($ws->sent, [ [ 'play', { uri => $TID } ] ], "R3-WR01 Fall D -- requestPause(0) on the not-ours branch sends nothing beyond the original play (isStop-off unchanged)");
    is($ctl->pending && $ctl->pending->{postPause}, undef, "R3-WR01 Fall D -- no postPause fold happened -- the if \$isStop guard at the call site still gates this");
    is($ctl->mode, 'idle', "R3-WR01 Fall D -- leaveBrowse still runs regardless of isStop");
}

# --- R3-WR01 Fall E (Plan-Check W2 -- pins the `!$wanted->{playing}`
# clause for BOTH branches of the new condition): a real Stop folds
# through the not-ours branch (postPauseIsStop=1), then LMS re-requests
# the SAME title X within T1 -- Schritt 3's idempotency absorption hangs
# the new call onto the SAME pending (the fold's flags survive), and
# wanted.playing becomes 1 again. The echo of X must NOT carry a pause:
# the user just asked for this exact title. A fix that gated on
# `$opts->{isStop}` alone (dropping `!$wanted->{playing}` for the Stop
# arm) would pass Fall A-D and still turn this RED. ---
{
    local $Slim::Player::Source::PLAYMODE = 'stop';

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:76', observed => { wsConnected => 1, meta => { $TID => { duration => 200 } }, status => 'paused' },
    );
    foreign_track('aa:bb:cc:dd:ee:76');

    $ctl->requestTrack($TID, 0, {});
    $ctl->requestPause(1);    # not-ours branch folds postPauseIsStop=1, leaveBrowse wipes wanted

    is($ctl->wanted->{playing}, undef, "R3-WR01 Fall E setup -- leaveBrowse wiped wanted: playing is undef, not 0");

    $ctl->requestTrack($TID, 0, {});    # same title, within T1 -- Schritt 3 idempotency, same pending

    is($ctl->wanted->{playing}, 1, "R3-WR01 Fall E setup -- the re-request sets wanted.playing=1 again");
    is($ctl->pending && $ctl->pending->{postPauseIsStop}, 1, "R3-WR01 Fall E setup -- the fold's postPauseIsStop survives the same-pending re-request (Schritt 3 only appends a successCb)");

    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    ok(!(grep { $_->[0] eq 'pause' } @{ $ws->sent }), "R3-WR01 Fall E -- no pause on the wire: the user re-requested this exact title before the echo arrived");
}

# ============================================================
# R3-WR02 (82-28, Review Runde 3 -- WR-02): the dedupe lock in
# _recordErrorOnce (observed->{errorsReported}) must not outlive the ring
# entry it mirrors. Status.pm's ring (MAX_ERROR_HISTORY=30) evicts
# silently via shift; the lock knew nothing of that eviction before this
# fix. Faelle A/B cover the eviction re-arm and its Gegenprobe (the
# ring-internal dedupe must survive the fix unweakened); Fall C is the
# autoplay:<uri> clear in the NORMAL requestTrack path, not only the
# late-echo branch; Faelle D/E are daemon-error keyed by message content,
# not flooded by a repeat of the same message.
#
# @Plugins::SpotOn::Status::RECORDED is reset at the top of each block
# below (file-wide package global, same convention as every WR-04/CR01/
# WR01 block above) so counts are exact, not cumulative across blocks.
# ============================================================

# --- R3-WR02 Fall A (Muss-Fehlschlag-Nachweis; Plan-Check committete
# Endform traegt die umgedrehte, POSITIVE Zusicherung: nach dem Fix steht
# der durch Verdraengung verlorene Eintrag wieder da. Ohne den Fix haette
# die letzte Zusicherung unten mit 0 statt 1 fehlgeschlagen -- die lokale
# Sperre haette den zweiten Schreibversuch unterdrueckt, obwohl der Ring
# den ersten Eintrag laengst verdraengt hatte.) ---
{
    @Plugins::SpotOn::Status::RECORDED = ();
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:70', uptime => 100, observed => { wsConnected => 1, meta => {} },
    );

    my $unpairedKey = $daemon->mac . ':unpaired';

    $ctl->_recordErrorOnce('unpaired', 'error', 'daemon not paired (request refused)');
    my $countA1 = scalar(grep { ($_->[3] // '') eq $unpairedKey } @Plugins::SpotOn::Status::RECORDED);
    is($countA1, 1, "R3-WR02 Fall A setup: the original unpaired entry is written");

    # 35 foreign track boundaries under distinct keys, mirroring repro.t
    # Fall R-C's measured count -- MAX_ERROR_HISTORY=30 means the ring
    # evicts the unpaired entry above well before all 35 have landed.
    for my $i (1 .. 35) {
        $ctl->_recordErrorOnce("autoplay:filler$i", 'warn', "daemon advanced to filler$i unrequested -- pausing");
    }
    my $countA2 = scalar(grep { ($_->[3] // '') eq $unpairedKey } @Plugins::SpotOn::Status::RECORDED);
    is($countA2, 0, "R3-WR02 Fall A setup: 35 foreign boundaries evict the unpaired entry from the 30-entry ring");

    $ctl->_recordErrorOnce('unpaired', 'error', 'daemon not paired (request refused)');
    my $countA3 = scalar(grep { ($_->[3] // '') eq $unpairedKey } @Plugins::SpotOn::Status::RECORDED);
    is($countA3, 1, "R3-WR02 Fall A: after 35 foreign boundaries a later requires-authentication error still shows unpaired in errors[] -- the dedupe lock no longer outlives the evicted ring entry");
}

# --- R3-WR02 Fall B (GREEN + Gegenprobe: the fix must not defeat the
# ring-internal dedupe -- two _recordErrorOnce calls for the SAME key
# with NO intervening eviction still produce exactly one entry. Without
# this second assertion a fix could re-arm on every call and flood the
# ring with repeats, which would be worse than the original defect.) ---
{
    @Plugins::SpotOn::Status::RECORDED = ();
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:71', observed => { wsConnected => 1, meta => {} },
    );

    $ctl->_recordErrorOnce('transport', 'warn', 'WS transport lost');
    $ctl->_recordErrorOnce('transport', 'warn', 'WS transport lost');

    my $countB = scalar(grep { ($_->[3] // '') eq $daemon->mac . ':transport' } @Plugins::SpotOn::Status::RECORDED);
    is($countB, 1, "R3-WR02 Fall B: two _recordErrorOnce calls for the same key with no intervening eviction still produce exactly one ring entry -- the fix does not disable the ring-internal dedupe");
}

# --- R3-WR02 Fall C (autoplay:<uri> clear in the NORMAL requestTrack
# path -- not the late-echo branch, which is reachable only after a T1
# timeout for a `play <uri>` dispatch). An autoplay:X entry stands
# (written by the foreign-track-changed guard, as it would after Spotify
# autoplay advanced the daemon on its own); an ordinary requestTrack(X)
# -- the realistic resolution when LMS's own getNextTrack reaches the
# same uri -- must clear it. Today the only clear lives in the late-echo
# branch, which this path never reaches. ---
{
    @Plugins::SpotOn::Status::RECORDED = ();
    my $C_X = 'spotify:track:r3wr02AutoplayXXXXXXXX';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:72', observed => { wsConnected => 1, meta => {}, track => $C_X, status => 'playing' },
    );

    my $autoplayKeyC = $daemon->mac . ':autoplay:' . $C_X;

    $ctl->_recordErrorOnce('autoplay:' . $C_X, 'warn', "daemon advanced to $C_X unrequested -- pausing");
    my $countC1 = scalar(grep { ($_->[3] // '') eq $autoplayKeyC } @Plugins::SpotOn::Status::RECORDED);
    is($countC1, 1, "R3-WR02 Fall C setup: an autoplay:X entry stands");

    $ctl->requestTrack($C_X, 0);

    my $countC2 = scalar(grep { ($_->[3] // '') eq $autoplayKeyC } @Plugins::SpotOn::Status::RECORDED);
    is($countC2, 0, "R3-WR02 Fall C: an ordinary requestTrack(X) clears the autoplay:X entry via the normal-case clear path, not only the late-echo branch");
}

# --- R3-WR02 Fall D (daemon-error keyed by message content -- two
# DIFFERENT correlated daemon errors are two entries, not the second
# silently dropped after the first). Neither message matches "requires
# authentication" (that text routes to the separate 'unpaired' key, not
# 'daemon-error' -- same convention as the pre-existing R2-WR04 Fall D
# test above). ---
{
    @Plugins::SpotOn::Status::RECORDED = ();
    my $D_X = 'spotify:track:r3wr02DaemonErrDDDDDDDD';
    my $D_Y = 'spotify:track:r3wr02DaemonErrEEEEEEEE';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:73', observed => { wsConnected => 1, meta => {} },
    );

    $ctl->requestTrack($D_X, 0, { errorCb => sub {} });
    $ctl->onEvent({ type => 'error', message => 'daemon rejected play' });

    $ctl->requestTrack($D_Y, 0, { errorCb => sub {} });
    $ctl->onEvent({ type => 'error', message => 'disk full' });

    my $d_prefix = $daemon->mac . ':daemon-error:';
    my @mine = grep { ($_->[3] // '') =~ /^\Q$d_prefix\E/ } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@mine), 2, "R3-WR02 Fall D: two different daemon-error messages produce two entries -- the content-hashed key stops the first correlated error from silently blocking every later, different one");
}

# --- R3-WR02 Fall E (Abgrenzung: derselbe Fehler flutet nicht -- the
# message hash must refine the dedupe, not disable it). Same message
# text twice, via two independently pending commands, still yields
# exactly one entry. ---
{
    @Plugins::SpotOn::Status::RECORDED = ();
    my $E_X = 'spotify:track:r3wr02DaemonErrFFFFFFFF';
    my $E_Y = 'spotify:track:r3wr02DaemonErrGGGGGGGG';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:74', observed => { wsConnected => 1, meta => {} },
    );

    $ctl->requestTrack($E_X, 0, { errorCb => sub {} });
    $ctl->onEvent({ type => 'error', message => 'daemon rejected play' });

    $ctl->requestTrack($E_Y, 0, { errorCb => sub {} });
    $ctl->onEvent({ type => 'error', message => 'daemon rejected play' });

    my $e_prefix = $daemon->mac . ':daemon-error:';
    my @mine = grep { ($_->[3] // '') =~ /^\Q$e_prefix\E/ } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@mine), 1, "R3-WR02 Fall E: the same daemon-error message twice still produces exactly one entry -- the hash refines the dedupe key, it does not disable it");
}

# --- R3-WR02 Fall F (82-29, Review Runde 4 -- WR-01, Muss-Fehlschlag-
# Nachweis; committete Endform positiv): a correlated daemon error whose
# `message` carries a code point above U+00FF (curly quotes, the same
# reproduction the reviewer quoted as R4-B) must not kill onEvent --
# errorCb fires, pending is released, T1 is dead, and exactly one
# daemon-error: ring entry stands. Vor der Aenderung stirbt der direkte
# Aufruf mit "Wide character in subroutine entry" (siehe 82-29-SUMMARY.md
# fuer die woertliche Ausgabe, per Trockenlauf reproduziert). PLAN-CHECK-
# KORREKTUR I1: die t1Timers==0-Zusicherung unten besteht bereits am
# ungefixten Code (T1 wird VOR dem Hash gekillt) -- sie ist KEIN
# Muss-Fehlschlag-Beleg, nur errFired/pending/der Ring-Eintrag sind es. ---
{
    @Plugins::SpotOn::Status::RECORDED = ();
    my $F_X = 'spotify:track:r3wr02DaemonErrHHHHHHHH';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:75', observed => { wsConnected => 1, paired => 1, meta => {} },
    );

    my ($errFired, $okFired) = (0, 0);
    $ctl->requestTrack($F_X, 0, { errorCb => sub { $errFired++ }, successCb => sub { $okFired++ } });

    my $msg = "Track \x{2018}Foo\x{2019} unavailable";
    $ctl->onEvent({ type => 'error', message => $msg });

    is($errFired, 1, "R3-WR02 Fall F: errorCb fires for a non-ASCII correlated daemon error -- onEvent did not die");
    is($ctl->pending, undef, "R3-WR02 Fall F: pending is released after the non-ASCII error");
    my $f_t1Timers = scalar grep { $_->[0] == $ctl && $_->[2] == \&Plugins::SpotOn::Soloist::Control::_t1Fire } @Slim::Utils::Timers::TIMERS;
    is($f_t1Timers, 0, "R3-WR02 Fall F: T1 is dead after the error (also true pre-fix -- I1, not a must-fail proof by itself)");
    my $f_prefix = $daemon->mac . ':daemon-error:';
    my @f_mine = grep { ($_->[3] // '') =~ /^\Q$f_prefix\E/ } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@f_mine), 1, "R3-WR02 Fall F: exactly one daemon-error ring entry stands for the non-ASCII message");
}

# --- R3-WR02 Fall G (82-29, Review Runde 4 -- WR-01, ASCII-Hash-
# Invarianz -- Loesch-/Regressionssperre, KEINE Fortschrittszusicherung:
# besteht bereits am ungefixten Code, weil utf8::encode auf einer reinen
# ASCII-Zeichenkette ein No-op auf Byte-Ebene ist -- md5_hex($msgBytes)
# nach dem Fix produziert fuer 'daemon rejected play' denselben Hash wie
# md5_hex($message) davor). ---
{
    @Plugins::SpotOn::Status::RECORDED = ();
    my $G_X = 'spotify:track:r3wr02DaemonErrIIIIIIII';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ee:77', observed => { wsConnected => 1, meta => {} },
    );

    $ctl->requestTrack($G_X, 0, { errorCb => sub {} });
    $ctl->onEvent({ type => 'error', message => 'daemon rejected play' });

    my $expectedHash = Digest::MD5::md5_hex('daemon rejected play');
    my $expectedKey  = $daemon->mac . ':daemon-error:' . $expectedHash;
    my @g_mine = grep { ($_->[3] // '') eq $expectedKey } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@g_mine), 1, "R3-WR02 Fall G: an ASCII daemon-error message hashes to the identical key before and after the UTF-8-octet fix (regression guard)");
}

# ============================================================
# 82-42 Task C: _reconcile Schritt 1 nicht-terminal fuer trigger=
# 'requestTrack' (get-state-statt-play.md, T-3 AND-gate Richtung (i)).
# Bauform aus 82-42-PLAN.md Task B (checkpoint answers, verbatim):
#   Frage 1 = fall-b        -- Control retries AND forces a fresh
#                               LMS-side Slim::Player::Source::playmode
#                               ($client,'play') call (Task A: LMS
#                               discards the ORIGINAL successCb/errorCb
#                               by generation, a Control-only replay
#                               alone is silently dropped).
#   Frage 2 = ttl-visible   -- a TTL expiry writes one errors[] entry.
#   Frage 3 = clear-on-teardown -- _transportClosed clears the deferral
#                               and fires errorCb('...','transport closed').
#   Frage 4 = q4-trigger-paired:25 -- the retry hook lives in the
#                               auth_state branch (paired=1/logged_in:
#                               true), NOT on the bare wsConnected
#                               handshake; WS_RETRY_TTL_S=25 (a reasoned
#                               value, not measured -- see the constant's
#                               own comment in Control.pm).
# ============================================================

# --- 82-44 Task 1, Fall-0 (Wert-Tor fuer WS_RETRY_TTL_S, D-12):
# Superseded (82-44, Runde 44): WS_RETRY_TTL_S is no longer an independent
# 25s constant -- it now delegates to Plugins::SpotOn::Unified::
# DeferBudget::TOTAL_DEFER_BUDGET_S, ONE 20s budget shared across
# ProtocolHandler -> DaemonManager -> SoloistDaemon -> Control (D-12).
# Staggering independent per-level TTLs (this one plus SoloistDaemon's
# PENDING_TRACK_TTL_S) could add up to 50s/75s; D-12 replaces that with a
# single 20s ceiling from the original request. This gate now asserts the
# exact value, not a floor.
# Muss-Fehlschlag-Probe: a revert to `Time::HiRes::time() + 25` in
# Control.pm (bypassing DeferBudget entirely) makes this case red; leaving
# WS_RETRY_TTL_S delegated to DeferBudget stays green. ---
{
    my $ttl = Plugins::SpotOn::Soloist::Control::WS_RETRY_TTL_S();
    is($ttl, 20, 'Fall-0: WS_RETRY_TTL_S == 20 (82-44/D-12, EIN Gesamtbudget statt der bisherigen Einzel-TTL 25)');
}

# --- D-12 (82-46 Task 2, WR-04, Control Schritt 1): _reconcile Schritt 1
# liest eine vorgesetzte deferDeadline aus $opts, statt selbst
# Time::HiRes::time()+WS_RETRY_TTL_S zu rechnen. Muss-Fehlschlag (M-N,
# namentlich benannt, nicht in diesem Plans <verify> mechanisch
# vorgefuehrt -- s. SUMMARY): ein Rueckbau von Control.pm:836 auf eine
# unabhaengige Berechnung laesst die Assertion unten rot fallen. ---
{
    my $mac = 'aa:bb:cc:dd:82:49';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac,
        observed => { wsConnected => 0, paired => undef, meta => {}, track => $TID, status => 'paused' },
    );

    $ctl->requestTrack($TID, 0, {
        successCb => sub { }, errorCb => sub { }, deferDeadline => 1234567890.5,
    });

    my ($entry) = grep {
        $_->[0] == $ctl && $_->[2] == \&Plugins::SpotOn::Soloist::Control::_wsRetryTimeout
    } @Slim::Utils::Timers::TIMERS;
    is($entry->[1], 1234567890.5,
        "D-12: Control Schritt 1 liest die vorgesetzte Frist anstatt sie selbst zu berechnen (M-N)");
}

# --- D-12 (82-46 Task 2, WR-04, Control Schritt 2): dieselbe Eigenschaft
# am zweiten Zurueckstellungspunkt (wsConnected=1, paired=0). ---
{
    my $mac = 'aa:bb:cc:dd:82:50';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac,
        observed => { wsConnected => 1, paired => 0, meta => {}, track => $TID, status => 'paused' },
    );

    $ctl->requestTrack($TID, 0, {
        successCb => sub { }, errorCb => sub { }, deferDeadline => 1234567890.5,
    });

    my ($entry) = grep {
        $_->[0] == $ctl && $_->[2] == \&Plugins::SpotOn::Soloist::Control::_wsRetryTimeout
    } @Slim::Utils::Timers::TIMERS;
    is($entry->[1], 1234567890.5,
        "D-12: Control Schritt 2 liest die vorgesetzte Frist anstatt sie selbst zu berechnen (M-N)");
}

# --- 82-42 Task C, Fall-1 (Retry-Erfolg, Bauform "q4-trigger-paired"):
# _reconcile Schritt 1 no longer drops a requestTrack that arrives before
# wsConnected -- it defers, and the retry fires on the auth_state branch's
# paired=1/logged_in:true (NOT on the bare wsConnected handshake alone,
# Runde 2 Warning 1). The fixture drives the REAL sequence a restart
# produces (Runde-3-Korrektur W2, 82-42-PLAN.md Task C read_first): the
# `_transport open` pseudoframe first (handshake), an unprompted
# auth_state{logged_in:false} push (Control.pm ~2098-2106), the resulting
# _authProbe timer tick, and only THEN auth_state{logged_in:true} -- a test
# that starts directly at logged_in:true would skip exactly the
# Sondierungskadenz this bauform introduces (82-42-PLAN.md Task C
# <behavior> Fall-1). observed.track already equals the requested uri with
# no anchor (CR-01 Fall E fixture, t/44:1258-1268) -- the daemon already
# restored this session's track, position unknown -- so the retry's
# Treffer-Zweig fires seek 0 + a bare resume play, mirroring CR-01 Fall E's
# own assertion. ---
{
    my $mac = 'aa:bb:cc:dd:82:01';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac,
        observed => { wsConnected => 0, paired => undef, meta => {}, track => $TID, status => 'paused' },
    );

    my ($success, $errorFired) = (0, 0);
    $ctl->requestTrack($TID, 0, {
        successCb => sub { $success++ },
        errorCb   => sub { $errorFired++ },
    });

    is($errorFired, 0, "82-42 Fall-1: requestTrack against a not-yet-connected daemon does not fail immediately");
    is_deeply($ws->sent, [], "82-42 Fall-1: nothing sent yet -- no WS connection");
    ok($ctl->_deferredTrackRequest, "82-42 Fall-1: the request is deferred, not dropped");

    # Handshake -- wsConnected becomes true, but this alone must NOT
    # trigger the retry (q4-trigger-paired's whole point, Runde 2 Warning 1).
    $ctl->onEvent({ type => '_transport', state => 'open' });
    is($success, 0, "82-42 Fall-1: the bare handshake alone does not resolve the deferred request");
    is_deeply($ws->sent, [], "82-42 Fall-1: still nothing sent after the bare handshake");
    ok($ctl->_deferredTrackRequest, "82-42 Fall-1: still deferred after the handshake");

    # Daemon's own unprompted push right after the handshake: not logged in
    # yet (82-26 CR-01 comment, Control.pm ~2098-2106).
    $ctl->onEvent({ type => 'auth_state', logged_in => 0 });
    is($success, 0, "82-42 Fall-1: logged_in:false does not resolve the deferred request");

    # The bounded re-probe cadence (AUTH_REPROBE_S=5) ticks once -- this
    # itself sends 'get_auth_state' on the wire (unrelated, pre-existing
    # 82-11 CR-03 behavior); clear it so the assertion below isolates the
    # retry's OWN wire traffic.
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 5);
    is($success, 0, "82-42 Fall-1: an _authProbe tick alone does not resolve the deferred request");
    @{ $ws->sent } = ();

    # The daemon's real login confirmation -- THIS resolves the deferral.
    $ctl->onEvent({ type => 'auth_state', logged_in => 1 });

    is($ctl->_deferredTrackRequest, undef, "82-42 Fall-1: the deferral is cleared once paired=1/logged_in:true fires");
    is_deeply($ws->sent, [ [ 'seek', { position_ms => 0 } ], [ 'play', {} ], [ 'get_state', {} ] ],
        "82-42 Fall-1: auth_state{logged_in:true} replays the deferred requestTrack -- seek 0 + bare resume play, then the pre-existing 73-02 D-05 reconnect resync get_state (unconditional on logged_in:true, unrelated to this plan)");
    is($success, 1, "82-42 Fall-1: successCb fires exactly once, from the replay");
    is($errorFired, 0, "82-42 Fall-1: errorCb never fires");
}

# --- 82-42 Task C, Fall-2 (TTL-Fallback, IMMER zu implementieren): the
# daemon never signals readiness at all within WS_RETRY_TTL_S -- the
# deferred request must resolve with the SAME error shape _reconcile used
# to fire synchronously before this plan (T-77-10: getNextTrack/onStream
# never wedge indefinitely). Bauform Frage 2 = "ttl-visible"
# (82-42-PLAN.md Task B): the TTL expiry ALSO writes exactly one errors[]
# entry -- the silence on this exact path is what get-state-statt-play.md
# names as the root cause of nine failed measurement rounds (_reconcile
# Schritt 1 never called _recordErrorOnce). ---
{
    @Plugins::SpotOn::Status::RECORDED = ();
    my $mac = 'aa:bb:cc:dd:82:02';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac,
        observed => { wsConnected => 0, paired => undef, meta => {} },
    );

    my ($success, $errorArgs) = (0, undef);
    $ctl->requestTrack($TID, 0, {
        successCb => sub { $success++ },
        errorCb   => sub { $errorArgs = [@_]; },
    });

    ok($ctl->_deferredTrackRequest, "82-42 Fall-2: the request is deferred");
    is_deeply($ws->sent, [], "82-42 Fall-2: nothing sent yet");

    # Let the TTL fully expire -- no wsConnected/auth_state frame ever
    # arrives (the daemon stayed unreachable the whole time).
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + Plugins::SpotOn::Soloist::Control::WS_RETRY_TTL_S() + 1);

    is($ctl->_deferredTrackRequest, undef, "82-42 Fall-2: the deferral is cleared once the TTL fires");
    is_deeply($ws->sent, [], "82-42 Fall-2: TTL fallback sends nothing to the daemon");
    is($success, 0, "82-42 Fall-2: successCb never fires");
    is_deeply($errorArgs, [ 'PROBLEM_OPENING', 'Soloist daemon not ready' ],
        "82-42 Fall-2: errorCb fires with the SAME error shape _reconcile used to fire synchronously pre-this-plan");

    is(scalar(@Plugins::SpotOn::Status::RECORDED), 1, "82-42 Fall-2 (ttl-visible): exactly one errors[] entry for the TTL expiry");
    is($Plugins::SpotOn::Status::RECORDED[0][0], 'warn', "82-42 Fall-2: recorded level is 'warn'");
    is($Plugins::SpotOn::Status::RECORDED[0][1], 'Soloist', "82-42 Fall-2: recorded module is 'Soloist'");
    like($Plugins::SpotOn::Status::RECORDED[0][2], qr/timed out/, "82-42 Fall-2: recorded message names the timeout");
    like($Plugins::SpotOn::Status::RECORDED[0][3], qr/:ws-retry:\Q$TID\E$/, "82-42 Fall-2: ring key is mac-qualified ws-retry:<uri>");
}

# --- 82-42 Task C, Fall-4 (NUR Task B "fall-b", Task A Frage 2): Control
# must ALSO force a fresh, LMS-seitig wirksames Kommando when the retry
# fires -- Task A proved a Control-only replay of the ORIGINAL successCb/
# errorCb is worthless (LMS discards them by generation, nextTrackCallbackId,
# StreamingController.pm:640/2435-2445, the instant the earlier
# _NextIfMore attempt reached STOPPED-IDLE). The concrete command Task A
# named: Slim::Player::Source::playmode($client,'play') (Source.pm:66-96)
# -- the same LMS-core entry point the external playlist-play reannounce
# itself reaches via the "bug 14760" same-URL shortcut. ---
{
    @Slim::Player::Source::PLAYMODE_CALLS = ();
    my $mac = 'aa:bb:cc:dd:82:04';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac,
        observed => { wsConnected => 0, paired => undef, meta => {}, track => $TID, status => 'paused' },
    );

    $ctl->requestTrack($TID, 0, { successCb => sub {}, errorCb => sub {} });
    is(scalar(@Slim::Player::Source::PLAYMODE_CALLS), 0, "82-42 Fall-4: no LMS-side playmode('play') call while still deferred");

    $ctl->onEvent({ type => '_transport', state => 'open' });
    $ctl->onEvent({ type => 'auth_state', logged_in => 1 });

    is(scalar(@Slim::Player::Source::PLAYMODE_CALLS), 1,
        "82-42 Fall-4 (fall-b): the retry forces exactly one fresh Slim::Player::Source::playmode(\$client,'play') call");
    is($Slim::Player::Source::PLAYMODE_CALLS[0][1], 'play',
        "82-42 Fall-4: the forced LMS-side command is 'play' (Source.pm:66-96)");
    is_deeply($ws->sent, [ [ 'seek', { position_ms => 0 } ], [ 'play', {} ], [ 'get_state', {} ] ],
        "82-42 Fall-4: the WS replay still runs too -- both channels fire (Task A's Fall (b) finding: Control retries AND forces the LMS command); trailing get_state is the pre-existing 73-02 D-05 resync");
}

# --- 82-42 Task C, Fall-5 (Verdraengung/superseded, IMMER zu
# implementieren): a SECOND requestTrack that arrives while the FIRST is
# still deferred (daemon still not connected) must resolve the first with
# 'superseded' -- exact convention as the pre-existing play-pending
# supersession (Control.pm:1279, `_dispatch`) -- and let the deferred slot
# go to the NEWER request. Neither request may hang unresolved forever
# (T-77-10). ---
{
    my $mac   = 'aa:bb:cc:dd:82:05';
    my $URI_A = 'spotify:track:82ftFallA0000000000AA';
    my $URI_B = 'spotify:track:82ftFallB0000000000BB';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac,
        observed => { wsConnected => 0, paired => undef, meta => {}, track => $URI_B, status => 'paused' },
    );

    my ($successA, $successB) = (0, 0);
    my (@errorsA, @errorsB);
    $ctl->requestTrack($URI_A, 0, {
        successCb => sub { $successA++ },
        errorCb   => sub { push @errorsA, [@_]; },
    });
    ok($ctl->_deferredTrackRequest, "82-42 Fall-5: the first request is deferred");
    is($ctl->_deferredTrackRequest->{uri}, $URI_A, "82-42 Fall-5: the deferral holds request A first");

    $ctl->requestTrack($URI_B, 0, {
        successCb => sub { $successB++ },
        errorCb   => sub { push @errorsB, [@_]; },
    });

    is_deeply(\@errorsA, [ [ 'PROBLEM_OPENING', 'superseded' ] ],
        "82-42 Fall-5: the FIRST (superseded) request's errorCb fires exactly once, with 'superseded'");
    is($successA, 0, "82-42 Fall-5: the superseded request's successCb never fires");
    is(scalar(@errorsB), 0, "82-42 Fall-5: the second (still-deferred) request has not failed");
    is($ctl->_deferredTrackRequest->{uri}, $URI_B, "82-42 Fall-5: the deferral now holds request B");

    # Retry fires (q4-trigger-paired bauform): the SECOND (surviving)
    # request must be the one that resolves, not the superseded first one.
    $ctl->onEvent({ type => '_transport', state => 'open' });
    $ctl->onEvent({ type => 'auth_state', logged_in => 1 });

    is($ctl->_deferredTrackRequest, undef, "82-42 Fall-5: the deferral is cleared by the retry");
    is($successB, 1, "82-42 Fall-5: request B's successCb fires from the retry");
    is($successA, 0, "82-42 Fall-5: request A's successCb still never fires -- it was superseded, not replayed");
    is(scalar(@errorsA), 1, "82-42 Fall-5: request A resolved exactly once total (no double resolution)");
    is_deeply($ws->sent, [ [ 'seek', { position_ms => 0 } ], [ 'play', {} ], [ 'get_state', {} ] ],
        "82-42 Fall-5: request B's retry sends seek 0 + bare resume play (observed.track already equals URI_B), then the pre-existing 73-02 D-05 resync get_state");
}

# --- 82-42 Task C, Fall-6 (Transport-Abbau, Bauform "clear-on-teardown"):
# _transportClosed must not leave a deferred requestTrack hanging forever
# (T-82-42A) -- it clears the slot AND resolves errorCb with a distinct
# reason string ('transport closed', not the TTL's 'Soloist daemon not
# ready') so the two paths stay distinguishable in a log. A subsequent
# login must NOT resurrect the torn-down request (clear-on-teardown, as
# opposed to the rejected keep-across-teardown alternative). ---
{
    my $mac = 'aa:bb:cc:dd:82:06';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac,
        observed => { wsConnected => 0, paired => undef, meta => {}, track => $TID, status => 'paused' },
    );

    my ($success, $errorCount, $errorArgs) = (0, 0, undef);
    $ctl->requestTrack($TID, 0, {
        successCb => sub { $success++ },
        errorCb   => sub { $errorCount++; $errorArgs = [@_]; },
    });
    ok($ctl->_deferredTrackRequest, "82-42 Fall-6: the request is deferred before teardown");

    $ctl->_transportClosed;

    is($ctl->_deferredTrackRequest, undef, "82-42 Fall-6: the deferral is cleared by _transportClosed (clear-on-teardown)");
    is($errorCount, 1, "82-42 Fall-6: errorCb fires exactly once from the teardown");
    is_deeply($errorArgs, [ 'PROBLEM_OPENING', 'transport closed' ],
        "82-42 Fall-6: errorCb fires with a distinct 'transport closed' reason -- not the TTL's own text");
    is($success, 0, "82-42 Fall-6: successCb never fires");

    my $timersLeft = scalar grep {
        $_->[0] == $ctl && $_->[2] == \&Plugins::SpotOn::Soloist::Control::_wsRetryTimeout
    } @Slim::Utils::Timers::TIMERS;
    is($timersLeft, 0, "82-42 Fall-6: no leftover _wsRetryTimeout timer after teardown");

    # A subsequent respawn/reconnect (with the daemon logging in normally)
    # must NOT resurrect the torn-down request -- it is already resolved.
    $ctl->onEvent({ type => '_transport', state => 'open' });
    $ctl->onEvent({ type => 'auth_state', logged_in => 1 });

    is($success, 0, "82-42 Fall-6: a later login does not retroactively resolve the torn-down request");
    is($errorCount, 1, "82-42 Fall-6: errorCb still fired exactly once total -- no second resolution");
}

# --- 82-46 Task 1, WR-03 (82-REVIEW.md Zeile 179-192, Sonde S als
# permanenter Regressionswaechter): Control::shutdown must release a
# deferred requestTrack via the SAME _releaseDeferredTrackRequest path
# Fall-6 above already exercises on _transportClosed -- no timer/field may
# outlive a torn-down Control instance (the discipline shutdown's own
# comment at :254-256 already claims for _t1Fire/_watchdogRound2/
# _authProbe). Muss-Fehlschlag (Sonde S): on today's pre-fix shutdown, the
# field/timer survive and errorCb never fires from shutdown -- all four
# assertions below go red. ---
{
    my $mac = 'aa:bb:cc:dd:82:46';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac,
        observed => { wsConnected => 0, paired => undef, meta => {}, track => $TID, status => 'paused' },
    );

    my ($success, $errorCount, $errorArgs) = (0, 0, undef);
    $ctl->requestTrack($TID, 0, {
        successCb => sub { $success++ },
        errorCb   => sub { $errorCount++; $errorArgs = [@_]; },
    });
    ok($ctl->_deferredTrackRequest, "WR-03: the request is deferred before shutdown");

    $ctl->shutdown;

    is($ctl->_deferredTrackRequest, undef, "WR-03: the deferral is cleared by shutdown");

    my $timersLeft = scalar grep {
        $_->[0] == $ctl && $_->[2] == \&Plugins::SpotOn::Soloist::Control::_wsRetryTimeout
    } @Slim::Utils::Timers::TIMERS;
    is($timersLeft, 0, "WR-03: no leftover _wsRetryTimeout timer after shutdown");

    is($errorCount, 1, "WR-03: errorCb fires exactly once from shutdown");
    is_deeply($errorArgs, [ 'PROBLEM_OPENING', 'Soloist control shut down' ],
        "WR-03: errorCb fires with shutdown's own distinct reason text");
    is($success, 0, "WR-03: successCb never fires");

    # Gegenprobe: a subsequent _transportClosed call on the same
    # (already torn-down) instance must not double-fire errorCb -- the
    # field is already undef by the time _transportClosed runs.
    $ctl->_transportClosed;
    is($errorCount, 1, "WR-03: _transportClosed after shutdown does not double-fire errorCb (no double-firing)");
}

# --- 82-48 Task 1, CR-01 (82-REVIEW.md Zeile 50-88, Re-Verifikation
# Runde 7, 82-VERIFICATION.md gaps[0]): ein waehrend Control::shutdown
# feuernder errorCb kann synchron reentrant requestTrack aufrufen (LMS'
# eigener _nextTrackError-Callback ist genau dieser errorCb). Muss-
# Fehlschlag (heutiger Vorfix-Stand): der innere, reentrante Aufruf
# landet erneut in _reconcile Schritt 1 und defert auf der bereits
# abgemeldeten Instanz, statt sofort mit errorCb abgewiesen zu werden --
# alle vier CR-01-Behauptungen unten gehen rot. ---
{
    my $mac = 'aa:bb:cc:dd:82:48';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac,
        observed => { wsConnected => 0, paired => undef, meta => {}, track => $TID, status => 'paused' },
    );

    my ($innerErrorCount, $innerErrorArgs, $innerSuccess, $outerSuccess) = (0, undef, 0, 0);
    my $outerErrorCb = sub {
        # Phase 82 Plan 50 (WR-05, 82-REVIEW.md Zeile 93-106): the
        # committed block above reenters via the held $ctl reference, never
        # via Control->for_client($mac) -- so it never actually exercised
        # whether the registry deregistration (delete $_byMac{...}) runs
        # BEFORE the three releases, only that requestTrack's OWN _shutDown
        # guard rejects the reentrant call regardless of that ordering.
        # This assertion checks the ordering directly.
        is(Plugins::SpotOn::Soloist::Control->for_client($mac), undef,
            "CR-01: for_client liefert waehrend shutdown bereits undef (Abmeldung VOR der Freigabe)");

        $ctl->requestTrack($TID, 0, {
            successCb => sub { $innerSuccess++ },
            errorCb   => sub { $innerErrorCount++; $innerErrorArgs = [@_]; },
        });
    };

    $ctl->requestTrack($TID, 0, {
        successCb => sub { $outerSuccess++ },
        errorCb   => $outerErrorCb,
    });
    ok($ctl->_deferredTrackRequest, "CR-01: die aeussere Anforderung ist vor shutdown zurueckgestellt");

    $ctl->shutdown;

    is($ctl->_deferredTrackRequest, undef, "CR-01: kein Wiedereintritt hinterlaesst eine neue Zurueckstellung nach shutdown");

    my $timersLeft = scalar grep {
        $_->[0] == $ctl && $_->[2] == \&Plugins::SpotOn::Soloist::Control::_wsRetryTimeout
    } @Slim::Utils::Timers::TIMERS;
    is($timersLeft, 0, "CR-01: kein _wsRetryTimeout-Timer ueberlebt den Wiedereintritt");

    is($innerErrorCount, 1, "CR-01: der reentrante requestTrack-Aufruf wird sofort mit errorCb abgewiesen");
    is_deeply($innerErrorArgs, [ 'PROBLEM_OPENING', 'Soloist control shut down' ],
        "CR-01: mit derselben Grund-Zeichenkette wie shutdown selbst");

    is($innerSuccess, 0, "CR-01: der reentrante Aufruf feuert nie successCb");

    # Isolation: on today's pre-fix Control.pm this block's own RED
    # signature IS a leftover _wsRetryTimeout timer (asserted above) --
    # left armed, it would fire during a LATER block's fire_due() call
    # (global @Slim::Utils::Timers::TIMERS, not per-block) and contaminate
    # an unrelated assertion. Kill it explicitly regardless of RED/GREEN
    # outcome above so this block's own defect stays inside this block.
    Slim::Utils::Timers::killTimers($ctl, \&Plugins::SpotOn::Soloist::Control::_wsRetryTimeout);
}

# ============================================================
# 82-42A Task (Defekt A, get-state-statt-play.md Befund A, gemessen
# 2026-09-14): _reconcile Schritt 2 (der `paired`-Zweig) nicht-terminal
# fuer trigger='requestTrack' -- der T-3-Kernpfad-Abbruch bei Handschlag-
# vor-Login (wsConnected=1, paired=0, 4/6 gemessene Versuche: Schritt 1
# liess die Anfrage durch, Schritt 2 wies sie terminal ab). Bauform:
# dieselbe Zurueckstellung wie 82-42 Schritt 1 (_deferredTrackRequest,
# _wsRetryTimeout, WS_RETRY_TTL_S, Fall-5-Verdraengungskonvention) --
# keine zweite Maschinerie. Der Retry-Hook im auth_state/logged_in:true-
# Zweig (Control.pm ~2183) ist unveraendert der richtige Ausloeser auch
# hier -- er feuert bei paired=1, unabhaengig davon, welcher Schritt die
# Zurueckstellung gesetzt hat.
#
# Die Falle (siehe Auftrag): der WR-05-Sondierungsblock ist der EINZIGE
# Mechanismus, der `paired` in diesem Zustand ueberhaupt auf 1 bringen
# kann (der Daemon pusht einen spaeteren Login NICHT von selbst, 82-26
# CR-01) -- er MUSS laufen, BEVOR zurueckgestellt wird, sonst wartet die
# Zurueckstellung die volle TTL auf ein Ereignis, das niemand mehr
# anfragt. Fall-7 und Fall-9 belegen das je mit einem eigenen Testfall
# (nicht nur einer Zusicherung im Kommentar).
#
# _recordErrorOnce('unpaired', ...) und der terminale errorCb-Ausgang
# fuer requestPause/requestResume/requestVolume/transport bleiben
# UNVERAENDERT -- belegt durch die unveraenderte volle Suite (die
# R2-CR03/R2-WR05/R3-CR01-Faelle oben pruefen weiterhin denselben
# Ring-Eintrag, nur die requestTrack-Faelle wurden fuer das neue
# Zurueckstell-Verhalten aktualisiert).
# ============================================================

# --- 82-42A Fall-7 (Retry-Erfolg aus Schritt 2): a requestTrack against
# a wsConnected=1/paired=0 daemon -- the exact Handschlag-vor-Login state
# der_befund measured -- must (a) still trigger the WR-05 re-probe on
# THIS SAME call (the probe is the ONLY thing that can ever resolve this
# state, 82-26 CR-01: the daemon never pushes a later login unprompted)
# and (b) defer instead of firing errorCb terminally. The probe's own
# reply then resolves the deferral via the SAME auth_state/logged_in:true
# retry hook 82-42 Task C built for Schritt 1 (Control.pm ~2183) --
# unmodified for this Fall (verified: no change was needed there).
# Muss-Fehlschlag-Probe (Orchestrator, gegen eine git-archive-Kopie mit
# dem 82-42A-Fix zurueckgebaut): ohne den Fix feuert errorCb SOFORT mit
# ('PROBLEM_OPENING','Soloist daemon not paired'), _deferredTrackRequest
# bleibt undef, und der spaetere auth_state{logged_in:true} loest gar
# nichts mehr aus -- jede Assertion unten schlaegt fehl. ---
{
    @Plugins::SpotOn::Status::RECORDED = ();
    my $mac = 'aa:bb:cc:dd:82:07';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac, uptime => 100,
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'paused' },
    );

    # Handshake-vor-Login: the daemon's own unprompted push right after
    # the handshake says not-yet-logged-in (82-26 CR-01 comment,
    # Control.pm ~2098-2106) -- this is what sets paired=0 in the real
    # sequence (no test in this file sets observed.paired=0 directly via
    # the fixture; R2-WR05/R3-CR01 above drive it through the real event
    # too).
    $ctl->onEvent({ type => 'auth_state', logged_in => 0 });
    is($ctl->observed->{paired}, 0, "82-42A Fall-7 setup: the handshake-time push sets paired=0");

    # 82-26 CR-01 already arms its OWN bounded re-probe cycle on this
    # push -- kill it so THIS Fall isolates Schritt 2's OWN WR-05 trigger
    # (`unless (defined _authProbeCount)`) as the thing under test, not
    # the 82-26 cycle (R2-WR05 Fall D's "Fall C protection" note applies
    # here too: with a cycle already armed, Schritt 2 would correctly
    # decline to send a second probe of its own).
    Slim::Utils::Timers::killTimers($ctl, \&Plugins::SpotOn::Soloist::Control::_authProbe);
    $ctl->_authProbeCount(undef);

    my ($success, $errorFired) = (0, 0);
    $ctl->requestTrack($TID, 0, {
        successCb => sub { $success++ },
        errorCb   => sub { $errorFired++ },
    });

    # (a) the Falle: the probe MUST have fired on this same call.
    is(scalar(grep { $_->[0] eq 'get_auth_state' } @{ $ws->sent }), 1,
        "82-42A Fall-7: the WR-05 probe fires on the SAME requestTrack call that also defers");

    # (b) it defers instead of failing terminally.
    is($errorFired, 0, "82-42A Fall-7: errorCb does not fire synchronously");
    ok($ctl->_deferredTrackRequest, "82-42A Fall-7: the request is deferred, not dropped");
    @{ $ws->sent } = ();    # isolate the retry's OWN wire traffic below

    # The probe's own reply resolves the deferral -- same retry hook as
    # Schritt 1 (82-42 Task C, Control.pm ~2183), unmodified by this task.
    $ctl->onEvent({ type => 'auth_state', logged_in => 1 });

    is($ctl->_deferredTrackRequest, undef, "82-42A Fall-7: the deferral is cleared once the probe's own reply arrives");
    is_deeply($ws->sent, [ [ 'seek', { position_ms => 0 } ], [ 'play', {} ], [ 'get_state', {} ] ],
        "82-42A Fall-7: the retry replays the deferred requestTrack -- seek 0 + bare resume play (observed.track already equals the requested uri), then the pre-existing 73-02 D-05 reconnect resync get_state");
    is($success, 1, "82-42A Fall-7: successCb fires exactly once, from the retry");
    is($errorFired, 0, "82-42A Fall-7: errorCb still never fires");
}

# --- 82-42A Fall-8 (TTL-Fallback aus Schritt 2, IMMER zu implementieren),
# edited by 79-53: a daemon WITH a stored session (so the 82-42A deferral
# applies) that stays known-unpaired (paired=0) and never answers the
# WR-05 probe at all (the genuinely-unpaired real-world case R3-CR01
# Fall E already exercises for the probe cadence itself) must not wedge
# the deferred requestTrack forever (T-77-10) -- the SAME TTL fallback
# Schritt 1 uses (82-42 Task C Fall-2) resolves it here too, same
# ws-retry:<uri> ring entry -- plus Schritt 2's OWN 'unpaired' ring entry,
# written before the defer (unchanged, R2-CR03).
# The OUTCOME changed with 79-53: it used to end with errorCb 'Soloist
# daemon not ready', which made LMS advance to the next title (the
# unpaired-player playlist walk, 20 s per title, silent). Now the expiry on
# a daemon that is known-unpaired ends with stop FIRST (so LMS drops the
# errorCb as stale), then the pairing hint, then errorCb 'Soloist daemon
# not paired'. ---
{
    @Plugins::SpotOn::Status::RECORDED = ();
    @Slim::Player::Client::ORDER = ();
    my $mac = 'aa:bb:cc:dd:82:08';
    $Plugins::SpotOn::Soloist::FS{$mac} = 1;    # stored session: the deferral applies
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac, uptime => 100,
        observed => { wsConnected => 1, meta => {} },
    );

    $ctl->onEvent({ type => 'auth_state', logged_in => 0 });
    Slim::Utils::Timers::killTimers($ctl, \&Plugins::SpotOn::Soloist::Control::_authProbe);
    $ctl->_authProbeCount(undef);

    my ($success, $errorArgs) = (0, undef);
    $ctl->requestTrack($TID, 0, {
        successCb => sub { $success++ },
        errorCb   => sub { $errorArgs = [@_]; push @Slim::Player::Client::ORDER, 'errorCb'; },
    });

    is(scalar(grep { $_->[0] eq 'get_auth_state' } @{ $ws->sent }), 1,
        "82-42A Fall-8: the WR-05 probe fires before the defer, same ordering as Fall-7");
    ok($ctl->_deferredTrackRequest, "82-42A Fall-8: the request is deferred");

    # No reply ever arrives -- let the TTL fully expire.
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + Plugins::SpotOn::Soloist::Control::WS_RETRY_TTL_S() + 1);

    is($ctl->_deferredTrackRequest, undef, "82-42A Fall-8: the deferral is cleared once the TTL fires");
    is($success, 0, "82-42A Fall-8: successCb never fires");
    is_deeply($errorArgs, [ 'PROBLEM_OPENING', 'Soloist daemon not paired' ],
        "82-42A Fall-8 (79-53): the TTL expiry on a known-unpaired daemon ends with errorCb 'Soloist daemon not paired'");
    is_deeply([ @Slim::Player::Client::ORDER ],
        [ 'exec:stop', 'hint:STR(PLUGIN_SPOTON_SOLOIST_NOT_PAIRED)', 'errorCb' ],
        "82-42A Fall-8 (79-53): order is stop, hint, errorCb (the stop makes LMS drop the errorCb as stale)")
        or diag("ORDER=@Slim::Player::Client::ORDER");

    is(scalar(@Plugins::SpotOn::Status::RECORDED), 2,
        "82-42A Fall-8: exactly two ring entries total -- Schritt 2's own 'unpaired' write plus the TTL's 'ws-retry' write");
    my @unpaired = grep { ($_->[3] // '') eq $daemon->mac . ':unpaired' } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@unpaired), 1, "82-42A Fall-8: the 'unpaired' entry (unchanged, R2-CR03) still stands");
    my @wsretry = grep { ($_->[3] // '') =~ /:ws-retry:\Q$TID\E$/ } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@wsretry), 1, "82-42A Fall-8 (ttl-visible): exactly one ws-retry ring entry for the TTL expiry");
}

# --- 82-42A Fall-9 (Sondierung-laeuft-trotzdem-Probe, die Falle aus dem
# Auftrag): isolates ONE claim -- the WR-05 probe fires SYNCHRONOUSLY on
# the SAME requestTrack call that defers, before any timer/event resolves
# anything. A mutation that reordered the fix (deferring BEFORE the
# WR-05 probe block runs, instead of after) would turn THIS Fall red even
# if Fall-7's end-to-end retry-success narrative happened to still pass
# by coincidence -- this Fall exists so the ordering claim has its own,
# minimal, single-purpose proof ("Belege das mit einem eigenen Testfall,
# nicht mit einer Zusicherung im Kommentar", der Auftrag). ---
{
    my $mac = 'aa:bb:cc:dd:82:09';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => $mac, uptime => 100,
        observed => { wsConnected => 1, meta => {} },
    );

    $ctl->onEvent({ type => 'auth_state', logged_in => 0 });
    Slim::Utils::Timers::killTimers($ctl, \&Plugins::SpotOn::Soloist::Control::_authProbe);
    $ctl->_authProbeCount(undef);

    is_deeply($ws->sent, [], "82-42A Fall-9 setup: nothing sent yet");

    $ctl->requestTrack($TID, 0, { errorCb => sub { } });

    # Both facts must hold from THIS ONE call, with no fire_due/onEvent
    # in between -- the probe already went out on the wire AND the
    # request is deferred, in that order, synchronously.
    is_deeply($ws->sent, [ [ 'get_auth_state', {} ] ],
        "82-42A Fall-9: the WR-05 probe is on the wire immediately after the SAME call that defers -- proves the ordering, not just the eventual outcome");
    ok($ctl->_deferredTrackRequest, "82-42A Fall-9: the same call also deferred the request");

    # Cleanup (82-42A): see the R2-CR03 Fall B/C comment near the start
    # of this file's R2-CR03/R2-WR05/R3-CR01 block.
    Slim::Utils::Timers::killTimers($ctl, \&Plugins::SpotOn::Soloist::Control::_wsRetryTimeout);
    $ctl->_deferredTrackRequest(undef);
}

# ============================================================
# 79-53: a never-paired Soloist player must stop ONCE with the pairing hint
# instead of letting LMS walk the playlist (debug session
# unpaired-player-skips-playlist). LMS answers every getNextTrack error with
# "next title", so a refusal has to stop the player BEFORE the errorCb fires:
# StreamingController _Stop bumps nextTrackCallbackId and the later errorCb
# reaches _nextTrackError as a stale id. The gate that tells "never paired"
# from "restoring a stored session" is Plugins::SpotOn::Soloist::
# isPairedForClient (stubbed above, %FS). Synthetic MACs only.
# ============================================================
sub s53_state {    # wsConnected=1, paired=0: the Pi-walk daemon state
    my ($mac) = @_;
    return fresh_control(mac => $mac, uptime => 100,
        observed => { wsConnected => 1, paired => 0, meta => {} });
}
sub s53_reset {
    @Plugins::SpotOn::Status::RECORDED = ();
    @Slim::Player::Client::ORDER = ();
    @Slim::Player::Client::EXECUTED = ();
    @Slim::Utils::Log::WARNINGS = ();
}
sub s53_timer {
    my ($ctl) = @_;
    return scalar grep { $_->[0] == $ctl && $_->[2] == \&Plugins::SpotOn::Soloist::Control::_wsRetryTimeout } @Slim::Utils::Timers::TIMERS;
}
sub s53_cleanup {
    my ($ctl) = @_;
    Slim::Utils::Timers::killTimers($ctl, \&Plugins::SpotOn::Soloist::Control::_wsRetryTimeout);
    $ctl->_deferredTrackRequest(undef);
}

# --- 79-53 S1: never paired (FS=0, wsConnected=1, paired=0) -> refuse at once:
# stop, hint, errorCb in that order; no deferral, no timer, one warning.
{
    s53_reset();
    my $mac = 'aa:bb:cc:dd:53:01';
    $Plugins::SpotOn::Soloist::FS{$mac} = 0;
    my ($ctl, $daemon, $ws) = s53_state($mac);
    my @err;
    $ctl->requestTrack($TID, 0, { source => 'getNextTrack', errorCb => sub { push @Slim::Player::Client::ORDER, 'errorCb'; push @err, [@_] } });

    is_deeply([ @Slim::Player::Client::ORDER ],
        [ 'exec:stop', 'hint:STR(PLUGIN_SPOTON_SOLOIST_NOT_PAIRED)', 'errorCb' ],
        "79-53 S1: order is stop, hint, errorCb (errorCb last, so LMS drops it as stale)")
        or diag("ORDER=@Slim::Player::Client::ORDER");
    is_deeply($err[0], [ 'PROBLEM_OPENING', 'Soloist daemon not paired' ], "79-53 S1: errorCb args");
    ok(!$ctl->_deferredTrackRequest, "79-53 S1: no deferral for a never-paired daemon");
    is(s53_timer($ctl), 0, "79-53 S1: no _wsRetryTimeout timer armed");
    my @w = grep { /requestTrack refused \(daemon not paired, no stored session\)/ && /pairing hint shown/ } @Slim::Utils::Log::WARNINGS;
    is(scalar(@w), 1, "79-53 S1: exactly one refusal warning naming the reason and the hint")
        or diag("WARNINGS=" . join(' | ', @Slim::Utils::Log::WARNINGS));
    s53_cleanup($ctl);
}

# --- 79-53 S2: stored session (FS=1) -> still deferred, no stop, no hint; a
# login inside the window replays it, no errorCb (the 82-42A race survives).
{
    s53_reset();
    my $mac = 'aa:bb:cc:dd:53:02';
    $Plugins::SpotOn::Soloist::FS{$mac} = 1;
    my ($ctl, $daemon, $ws) = s53_state($mac);
    my @err;
    $ctl->requestTrack($TID, 0, { source => 'getNextTrack', errorCb => sub { push @err, [@_] } });
    ok($ctl->_deferredTrackRequest, "79-53 S2: deferred when a stored session exists");
    is(scalar(@Slim::Player::Client::ORDER), 0, "79-53 S2: no stop, no hint while the session is restoring");
    $ctl->onEvent({ type => 'auth_state', logged_in => 1 });
    ok(!$ctl->_deferredTrackRequest && !@err, "79-53 S2: a login inside the window replays the deferral, no errorCb");
    is(scalar(@Slim::Player::Client::ORDER), 0, "79-53 S2: still no stop and no hint after the replay");
    s53_cleanup($ctl);
}

# --- 79-53 S3: pairing state unknown (module dies) -> the old deferral, no stop.
{
    s53_reset();
    my $mac = 'aa:bb:cc:dd:53:03';
    my ($ctl, $daemon, $ws) = s53_state($mac);
    {
        local $Plugins::SpotOn::Soloist::BROKEN = 1;
        $ctl->requestTrack($TID, 0, { source => 'getNextTrack', errorCb => sub { } });
    }
    ok($ctl->_deferredTrackRequest, "79-53 S3: an unknown pairing state keeps the deferral");
    is(scalar(@Slim::Player::Client::ORDER), 0, "79-53 S3: no stop, no hint for an unknown state");
    s53_cleanup($ctl);
}

# --- 79-53 S4: wsConnected=0 with FS=0 -> step 1 deferral, untouched.
{
    s53_reset();
    my $mac = 'aa:bb:cc:dd:53:04';
    $Plugins::SpotOn::Soloist::FS{$mac} = 0;
    my ($ctl, $daemon, $ws) = fresh_control(mac => $mac, uptime => 1,
        observed => { wsConnected => 0, meta => {} });
    my @err;
    $ctl->requestTrack($TID, 0, { source => 'getNextTrack', errorCb => sub { push @err, [@_] } });
    ok($ctl->_deferredTrackRequest, "79-53 S4: wsConnected=0 still defers (step 1)");
    ok(!@err, "79-53 S4: no errorCb on the step 1 deferral");
    is(scalar(@Slim::Player::Client::ORDER), 0, "79-53 S4: no stop, no hint on step 1");
    s53_cleanup($ctl);
}

# --- 79-53 S5: stored session (FS=1) but the login never arrives -> deferred
# first; at TTL expiry: stop, hint, errorCb 'not paired' (not LMS moving on).
{
    s53_reset();
    my $mac = 'aa:bb:cc:dd:53:05';
    $Plugins::SpotOn::Soloist::FS{$mac} = 1;
    my ($ctl, $daemon, $ws) = s53_state($mac);
    my @err;
    $ctl->requestTrack($TID, 0, { source => 'getNextTrack', errorCb => sub { push @Slim::Player::Client::ORDER, 'errorCb'; push @err, [@_] } });
    ok($ctl->_deferredTrackRequest, "79-53 S5: deferred first");
    is(scalar(@Slim::Player::Client::ORDER), 0, "79-53 S5: nothing sent to the player while deferred");
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + Plugins::SpotOn::Soloist::Control::WS_RETRY_TTL_S() + 1);
    is_deeply([ @Slim::Player::Client::ORDER ],
        [ 'exec:stop', 'hint:STR(PLUGIN_SPOTON_SOLOIST_NOT_PAIRED)', 'errorCb' ],
        "79-53 S5: TTL expiry on a known-unpaired daemon: stop, hint, errorCb")
        or diag("ORDER=@Slim::Player::Client::ORDER");
    is_deeply($err[0], [ 'PROBLEM_OPENING', 'Soloist daemon not paired' ], "79-53 S5: errorCb args at the TTL");
    my @w = grep { /requestTrack refused \(daemon not paired, login did not arrive within \d+s\)/ } @Slim::Utils::Log::WARNINGS;
    is(scalar(@w), 1, "79-53 S5: the refusal warning names the TTL reason")
        or diag("WARNINGS=" . join(' | ', @Slim::Utils::Log::WARNINGS));
    s53_cleanup($ctl);
}

# --- 79-53 S6: requestResume on a never-paired daemon -> no stop (only a
# requestTrack, i.e. a getNextTrack caller, is refused with a stop).
{
    s53_reset();
    my $mac = 'aa:bb:cc:dd:53:06';
    $Plugins::SpotOn::Soloist::FS{$mac} = 0;
    my ($ctl, $daemon, $ws) = s53_state($mac);
    $ctl->wanted({ playing => 1, uri => $TID });
    $ctl->requestResume;
    is(scalar(grep { /^exec:stop/ } @Slim::Player::Client::ORDER), 0, "79-53 S6: requestResume on a never-paired daemon sends no stop");
    is(scalar(grep { /^hint:/ } @Slim::Player::Client::ORDER), 0, "79-53 S6: and shows no hint");
    s53_cleanup($ctl);
}

# --- 79-53 S7: a step 1 deferral is still pending, then a requestTrack
# arrives on the now never-paired daemon -> the old errorCb is superseded,
# exactly one stop, no timer left (no second refusal at the old TTL).
{
    s53_reset();
    my $mac = 'aa:bb:cc:dd:53:07';
    $Plugins::SpotOn::Soloist::FS{$mac} = 0;
    my ($ctl, $daemon, $ws) = fresh_control(mac => $mac, uptime => 1,
        observed => { wsConnected => 0, meta => {} });
    my (@old, @new);
    $ctl->requestTrack($TID, 0, { source => 'getNextTrack', errorCb => sub { push @old, [@_] } });
    ok($ctl->_deferredTrackRequest, "79-53 S7 setup: the step 1 deferral is pending");
    is(s53_timer($ctl), 1, "79-53 S7 setup: its TTL timer is armed");

    $ctl->observed->{wsConnected} = 1;
    $ctl->observed->{paired}      = 0;
    $ctl->requestTrack($TID, 0, { source => 'getNextTrack', errorCb => sub { push @Slim::Player::Client::ORDER, 'errorCb'; push @new, [@_] } });

    is_deeply(\@old, [ [ 'PROBLEM_OPENING', 'superseded' ] ], "79-53 S7: the old errorCb is superseded, once");
    is_deeply($new[0], [ 'PROBLEM_OPENING', 'Soloist daemon not paired' ], "79-53 S7: the new request is refused as not paired");
    is(scalar(grep { /^exec:stop/ } @Slim::Player::Client::ORDER), 1, "79-53 S7: exactly one stop");
    ok(!$ctl->_deferredTrackRequest, "79-53 S7: no deferral left");
    is(s53_timer($ctl), 0, "79-53 S7: no timer left");
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + Plugins::SpotOn::Soloist::Control::WS_RETRY_TTL_S() + 5);
    is(scalar(grep { /^exec:stop/ } @Slim::Player::Client::ORDER), 1, "79-53 S7: still exactly one stop after the old TTL would have fired");
    is(scalar(@old), 1, "79-53 S7: the old errorCb did not fire a second time");
    s53_cleanup($ctl);
}

# ============================================================
# 79-53 repair round 2 (79-REVIEW-53-FIX.md WR-01): the TTL refusal (branch
# D) fires up to 20 s after the request. By then the user may have moved on
# to a radio station or a local file while the deferral is still pending
# (only shutdown and a closed transport release it). The refusal must stop
# and show the hint ONLY while LMS is still on one of OUR spoton:// titles;
# the errorCb stays unconditional (T-77-10). Path A (synchronous, inside
# getNextTrack) keeps its unconditional stop: the TRACKWAIT song is ours by
# construction (S11 pins it).
# ============================================================
sub s53_ttl_fire {
    my ($ctl, $mac, $setSong) = @_;
    my @err;
    $ctl->requestTrack($TID, 0, { source => 'getNextTrack', errorCb => sub { push @Slim::Player::Client::ORDER, 'errorCb'; push @err, [@_] } });
    $setSong->() if $setSong;
    Slim::Utils::Timers::fire_due(Time::HiRes::time() + Plugins::SpotOn::Soloist::Control::WS_RETRY_TTL_S() + 1);
    return @err;
}

# --- 79-53 S8: stored session, the user switched to a radio station inside
# the window -> at the TTL no stop, no hint, errorCb still fires.
{
    s53_reset();
    my $mac = 'aa:bb:cc:dd:53:08';
    $Plugins::SpotOn::Soloist::FS{$mac} = 1;
    my ($ctl, $daemon, $ws) = s53_state($mac);
    my @err = s53_ttl_fire($ctl, $mac, sub { foreign_track($mac, 'http://radio.example.invalid/stream.mp3') });
    ok(!$ctl->_deferredTrackRequest, "79-53 S8: the deferral is resolved at the TTL");
    is_deeply([ @Slim::Player::Client::ORDER ], [ 'errorCb' ],
        "79-53 S8: a foreign song at the TTL -> no stop, no hint, errorCb still fires")
        or diag("ORDER=@Slim::Player::Client::ORDER");
    is_deeply($err[0], [ 'PROBLEM_OPENING', 'Soloist daemon not paired' ], "79-53 S8: errorCb args unchanged");
    my @w = grep { /requestTrack refused \(daemon not paired, login did not arrive within \d+s\)/ && /no stop/ && !/stop sent/ && !/pairing hint shown/ } @Slim::Utils::Log::WARNINGS;
    is(scalar(@w), 1, "79-53 S8: one warning that says no stop was sent")
        or diag("WARNINGS=" . join(' | ', @Slim::Utils::Log::WARNINGS));
    s53_cleanup($ctl);
}

# --- 79-53 S9: same, but LMS reports no song at all -> no stop, no hint.
{
    s53_reset();
    my $mac = 'aa:bb:cc:dd:53:09';
    $Plugins::SpotOn::Soloist::FS{$mac} = 1;
    my ($ctl, $daemon, $ws) = s53_state($mac);
    my @err = s53_ttl_fire($ctl, $mac, sub { no_track($mac) });
    is_deeply([ @Slim::Player::Client::ORDER ], [ 'errorCb' ],
        "79-53 S9: no song at the TTL -> no stop, no hint, errorCb still fires")
        or diag("ORDER=@Slim::Player::Client::ORDER");
    is_deeply($err[0], [ 'PROBLEM_OPENING', 'Soloist daemon not paired' ], "79-53 S9: errorCb args unchanged");
    s53_cleanup($ctl);
}

# --- 79-53 S10: twin of S5 with the ownership stated explicitly: LMS still on
# our spoton:// title at the TTL -> stop, hint, errorCb.
{
    s53_reset();
    my $mac = 'aa:bb:cc:dd:53:10';
    $Plugins::SpotOn::Soloist::FS{$mac} = 1;
    my ($ctl, $daemon, $ws) = s53_state($mac);
    my @err = s53_ttl_fire($ctl, $mac, sub { own_track($mac, 'spoton://track:' . $TID =~ s/^spotify:track://r) });
    is_deeply([ @Slim::Player::Client::ORDER ],
        [ 'exec:stop', 'hint:STR(PLUGIN_SPOTON_SOLOIST_NOT_PAIRED)', 'errorCb' ],
        "79-53 S10: LMS still on our title at the TTL -> stop, hint, errorCb")
        or diag("ORDER=@Slim::Player::Client::ORDER");
    is_deeply($err[0], [ 'PROBLEM_OPENING', 'Soloist daemon not paired' ], "79-53 S10: errorCb args");
    s53_cleanup($ctl);
}

# --- 79-53 S11: path A (never paired, synchronous inside getNextTrack) keeps
# its UNCONDITIONAL stop, even when the client's song reads foreign: the
# guard belongs to the delayed TTL path only.
{
    s53_reset();
    my $mac = 'aa:bb:cc:dd:53:11';
    $Plugins::SpotOn::Soloist::FS{$mac} = 0;
    foreign_track($mac, 'http://radio.example.invalid/stream.mp3');
    my ($ctl, $daemon, $ws) = s53_state($mac);
    $ctl->requestTrack($TID, 0, { source => 'getNextTrack', errorCb => sub { push @Slim::Player::Client::ORDER, 'errorCb' } });
    is_deeply([ @Slim::Player::Client::ORDER ],
        [ 'exec:stop', 'hint:STR(PLUGIN_SPOTON_SOLOIST_NOT_PAIRED)', 'errorCb' ],
        "79-53 S11: the synchronous refusal inside getNextTrack stops unconditionally")
        or diag("ORDER=@Slim::Player::Client::ORDER");
    s53_cleanup($ctl);
}

# ============================================================
# 82-42B (Defekt B, get-state-statt-play.md Signatur B, 2026-09-14
# investigation): a same-track re-announcement -- a second, foreign-path
# track_changed for the SAME uri Control already believes it is playing
# -- must plant NO boundary. Before this plan, `_postBoundary` fired
# UNCONDITIONALLY on the foreign path, ~15 lines before the same-track
# check that follows it recognized the re-announcement and returned; the
# boundary corked the daemon's just-opened stream (measured live:
# `client-close: bounded EOF`, `song pos: 0` or a truncated
# `total_pushed`, ~230-300ms after a `seek armed=1` dispatch, same uri).
# Fall-1 is the fix; Fall-2 is the Gegenprobe (a genuine foreign
# transition must still plant exactly one boundary, unaffected by the
# reorder).
# ============================================================

# --- 82-42B Fall-1: a same-track re-announcement plants no boundary ---
{
    @IO::Socket::INET::CALLS = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:82:0a', mode => 'browse',
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'playing' },
    );

    # fixture's uri equals observed.track -- same-track re-announcement,
    # not a real transition (e.g. device re-activation, or the second
    # late track_changed frame Signatur B measured racing a `seek`
    # dispatch).
    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    is(scalar(@IO::Socket::INET::CALLS), 0,
        "82-42B Fall-1: a same-track re-announcement plants NO boundary (Defekt B, Signatur B)");
    is_deeply($ws->sent, [], "82-42B Fall-1: nothing dispatched to LMS either");
    is($ctl->observed->{status}, 'playing',
        "82-42B Fall-1: status is still updated to playing despite no boundary being planted");
}

# --- 82-42B Fall-2 (Gegenprobe): a genuine foreign transition (different
# uri) still plants exactly one boundary -- the reorder must not disable
# the real-transition case ---
{
    @IO::Socket::INET::CALLS = ();

    my $PREV = 'spotify:track:82fortyTwoBPrevTrackXYZ1';

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:82:0b', mode => 'browse',
        observed => { wsConnected => 1, meta => {}, track => $PREV, status => 'playing' },
    );

    # fixture's uri differs from observed.track -- a genuine foreign
    # track_changed (auto-advance / App takeover), not a re-announcement.
    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));

    is(scalar(@IO::Socket::INET::CALLS), 1,
        "82-42B Fall-2 (Gegenprobe): a genuine foreign track_changed STILL plants exactly one boundary");
    is($ctl->observed->{track}, $TID, "82-42B Fall-2: observed.track updates to the new uri");
    is_deeply($ws->sent, [], "82-42B Fall-2: no WS commands sent (no wanted set, WR-03 pause guard inapplicable)");
}

# ============================================================
# 83.1-01 Vorab Fall-A/B/C -- characterization of the _ws-undef deferral
# path (Schritt 1 and Schritt 2 of _reconcile) and the get_auth_state
# probe+stamp unit, PINNED BEFORE the 83.1-01 null-measurement refactor
# touches Control.pm (checker round 2: fresh_control always carries a ws
# stub, so nothing in the suite pinned the daemon-gone path before this
# plan). These three cases must stay green across Task 1's AND Task 2's
# commits -- a regression here means a per-list ws gate crept into
# _execute (Fall-A/B), or the probe's stamp was split from its send
# (Fall-A's negative assertion / Fall-C's positive one).
# ============================================================

# --- 83.1-01 Vorab Fall-A (Schritt 2, ws undef): a requestTrack landing
# on an unpaired daemon with no transport defers -- no probe, no stamp,
# no errorCb (HEAD Control.pm:921-924: no ws -> no send AND no stamp) ---
{
    @Slim::Utils::Timers::TIMERS = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:83:01', mode => 'browse',
        observed => { wsConnected => 1, paired => 0 },
    );
    $daemon->{ws} = undef;    # Test::FakeDaemon stores the stub in {ws} (t/44:409) -- harness code, not Control.

    my $errorFired = 0;
    my $ret = $ctl->requestTrack($TID, 0, { errorCb => sub { $errorFired++ } });

    is($ret, 1, "83.1-01 Vorab Fall-A: requestTrack returns 1 (defers, does not fail)");
    is(scalar(@Slim::Utils::Timers::TIMERS), 1, "83.1-01 Vorab Fall-A: exactly one timer armed");
    is($Slim::Utils::Timers::TIMERS[0][2], \&Plugins::SpotOn::Soloist::Control::_wsRetryTimeout,
        "83.1-01 Vorab Fall-A: the armed timer is _wsRetryTimeout");
    ok($ctl->_deferredTrackRequest, "83.1-01 Vorab Fall-A: deferral is set");
    is(($ctl->_deferredTrackRequest || {})->{uri}, $TID, "83.1-01 Vorab Fall-A: deferral carries the requested uri");
    is($errorFired, 0, "83.1-01 Vorab Fall-A: no errorCb fired");
    is($ctl->_lastAuthProbeAt, undef,
        "83.1-01 Vorab Fall-A: _lastAuthProbeAt stays undef -- no ws means no probe AND no stamp (HEAD :921-924)");

    # Cleanup (82-42A idiom, t/44:4035-4036): a live _wsRetryTimeout timer
    # must not leak into a later block's fire_due() sweep.
    Slim::Utils::Timers::killTimers($ctl, \&Plugins::SpotOn::Soloist::Control::_wsRetryTimeout);
    $ctl->_deferredTrackRequest(undef);
}

# --- 83.1-01 Vorab Fall-B (Schritt 1, ws undef): a requestTrack landing
# before the daemon's first WS frame defers -- Schritt 1 does not consult
# ws at all, so this case shares Fall-A's ws=undef setup but takes the
# unconditional Schritt-1 deferral instead ---
{
    @Slim::Utils::Timers::TIMERS = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:83:02', mode => 'browse',
        observed => { wsConnected => 0 },
    );
    $daemon->{ws} = undef;

    my $errorFired = 0;
    my $ret = $ctl->requestTrack($TID, 0, { errorCb => sub { $errorFired++ } });

    is($ret, 1, "83.1-01 Vorab Fall-B: requestTrack returns 1 (defers, does not fail)");
    is(scalar(@Slim::Utils::Timers::TIMERS), 1, "83.1-01 Vorab Fall-B: exactly one timer armed");
    is($Slim::Utils::Timers::TIMERS[0][2], \&Plugins::SpotOn::Soloist::Control::_wsRetryTimeout,
        "83.1-01 Vorab Fall-B: the armed timer is _wsRetryTimeout");
    ok($ctl->_deferredTrackRequest, "83.1-01 Vorab Fall-B: deferral is set");
    is($errorFired, 0, "83.1-01 Vorab Fall-B: no errorCb fired");

    Slim::Utils::Timers::killTimers($ctl, \&Plugins::SpotOn::Soloist::Control::_wsRetryTimeout);
    $ctl->_deferredTrackRequest(undef);
}

# --- 83.1-01 Vorab Fall-C (Gegenprobe, ws present): same paired=0 setup
# as Fall-A but WITHOUT touching the ws -- the probe fires and stamps
# inside the same conditional unit (HEAD Control.pm:921-924) ---
{
    @Slim::Utils::Timers::TIMERS = ();

    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:83:03', mode => 'browse',
        observed => { wsConnected => 1, paired => 0 },
    );

    my $errorFired = 0;
    my $ret = $ctl->requestTrack($TID, 0, { errorCb => sub { $errorFired++ } });

    is($ret, 1, "83.1-01 Vorab Fall-C: requestTrack returns 1 (defers, does not fail)");
    is_deeply($ws->sent, [ ['get_auth_state', {}] ], "83.1-01 Vorab Fall-C: get_auth_state sent");
    ok(defined $ctl->_lastAuthProbeAt, "83.1-01 Vorab Fall-C: _lastAuthProbeAt stamped");
    ok(($ctl->_lastAuthProbeAt // 0) > (Time::HiRes::time() - 1),
        "83.1-01 Vorab Fall-C: stamp is fresh (within 1s of now -- stamp follows the send)");
    is(scalar(@Slim::Utils::Timers::TIMERS), 1, "83.1-01 Vorab Fall-C: exactly one timer armed");
    is($errorFired, 0, "83.1-01 Vorab Fall-C: no errorCb fired");

    Slim::Utils::Timers::killTimers($ctl, \&Plugins::SpotOn::Soloist::Control::_wsRetryTimeout);
    $ctl->_deferredTrackRequest(undef);
}

# ============================================================
# 83.1-01 Task 3 -- the classify table (Fall-1..10), the empty-list
# boundary, rollback, adjacency, require_ws and the probe unit
# (Fall-12..17). All calls exercise `_classify`/`_execute` directly
# (package-qualified) -- these are pure/executor-level contracts, not
# reached via `_reconcile`/`_dispatch` in every case here.
# ============================================================

# --- 83.1-01 Task 3 Fall-1 (track_changed, own play echo -> Echo) ---
{
    my $frame = decode_frame(load_fixture('track_changed.json'));
    my ($class, $detail) = Plugins::SpotOn::Soloist::Control::_classify(
        $frame, { uri => $TID }, { track => 'spotify:track:someOtherTrack000000' },
        { cmd => 'play', uri => $TID }, 'browse', 1000,
    );
    is($class, 'Echo', "83.1-01 Task 3 Fall-1: track_changed matching an open play-pending classifies Echo");
    is($detail, 'own-play', "83.1-01 Task 3 Fall-1: detail is 'own-play'");
}

# --- 83.1-01 Task 3 Fall-2 (track_changed, open late-echo expectation -> Echo/late) ---
{
    my $frame = decode_frame(load_fixture('track_changed.json'));
    my ($class, $detail) = Plugins::SpotOn::Soloist::Control::_classify(
        $frame, { uri => $TID }, { track => 'spotify:track:someOtherTrack000000',
            expectEcho => { uri => $TID, until => 1005 } },
        undef, 'browse', 1000,
    );
    is($class, 'Echo', "83.1-01 Task 3 Fall-2: track_changed matching an open late-echo expectation classifies Echo");
    is($detail, 'late', "83.1-01 Task 3 Fall-2: detail is 'late'");
}

# --- 83.1-01 Task 3 Fall-3 (track_changed, same as observed.track -> Drift/reannounce) ---
{
    my $frame = decode_frame(load_fixture('track_changed.json'));
    my ($class, $detail) = Plugins::SpotOn::Soloist::Control::_classify(
        $frame, { uri => $TID }, { track => $TID }, undef, 'browse', 1000,
    );
    is($class, 'Drift', "83.1-01 Task 3 Fall-3: a same-track re-announcement classifies Drift");
    is($detail, 'reannounce', "83.1-01 Task 3 Fall-3: detail is 'reannounce'");
}

# --- 83.1-01 Task 3 Fall-4 (track_changed, foreign uri -- browse=Fremdeingriff, connect=Transfer) ---
{
    my $frame = decode_frame(load_fixture('track_changed.json'));
    my $foreignObserved = { track => 'spotify:track:someOtherTrack000000' };
    my ($classBrowse) = Plugins::SpotOn::Soloist::Control::_classify(
        $frame, { uri => 'spotify:track:notThisOneEither0000' }, $foreignObserved, undef, 'browse', 1000,
    );
    is($classBrowse, 'Fremdeingriff', "83.1-01 Task 3 Fall-4: foreign track_changed in browse classifies Fremdeingriff");
    my ($classConnect) = Plugins::SpotOn::Soloist::Control::_classify(
        $frame, { uri => 'spotify:track:notThisOneEither0000' }, $foreignObserved, undef, 'connect', 1000,
    );
    is($classConnect, 'Transfer', "83.1-01 Task 3 Fall-4: the SAME foreign track_changed in connect classifies Transfer (mode is an input, D-03)");
}

# --- 83.1-01 Task 3 Fall-5 (device_changed is_active:true, own activation -- pending play open) ---
{
    my $frame = decode_frame(load_fixture('device_changed.json'));
    my ($class, $detail) = Plugins::SpotOn::Soloist::Control::_classify(
        $frame, { uri => $TID }, {}, { cmd => 'play', uri => $TID }, 'browse', 1000,
    );
    is($class, 'Echo', "83.1-01 Task 3 Fall-5: device_changed(is_active:true) during our own open play classifies Echo");
    is($detail, 'own activation', "83.1-01 Task 3 Fall-5: detail is 'own activation'");
}

# --- 83.1-01 Task 3 Fall-5b (own-activation, T1/precision clock input --
# NOT the machine clock: $now inside expectEcho.until -> Echo, $now past
# it -> Transfer, criterion (2) of _ownActivationAt) ---
{
    my $frame  = decode_frame(load_fixture('device_changed.json'));
    my $wanted = { uri => $TID };
    my $observed = { track => 'spotify:track:someOtherTrack000000',
        expectEcho => { uri => $TID, until => 1005 } };
    my ($classBefore) = Plugins::SpotOn::Soloist::Control::_classify(
        $frame, $wanted, $observed, undef, 'browse', 1000,
    );
    is($classBefore, 'Echo', "83.1-01 Task 3 Fall-5b: now=1000 < until=1005 -- own activation, Echo");
    my ($classAfter) = Plugins::SpotOn::Soloist::Control::_classify(
        $frame, $wanted, $observed, undef, 'browse', 2000,
    );
    is($classAfter, 'Transfer', "83.1-01 Task 3 Fall-5b: now=2000 past until=1005 -- no longer own activation, Transfer");
}

# --- 83.1-01 Task 3 Fall-6 (device_changed is_active:true, no own-activation match -> Transfer) ---
{
    my $frame = decode_frame(load_fixture('device_changed.json'));
    my ($class, $detail) = Plugins::SpotOn::Soloist::Control::_classify(
        $frame, { uri => $TID }, { track => 'spotify:track:someOtherTrack000000' }, undef, 'browse', 1000,
    );
    is($class, 'Transfer', "83.1-01 Task 3 Fall-6: device_changed(is_active:true) with no own-activation signal classifies Transfer");
    is($detail, 'activation', "83.1-01 Task 3 Fall-6: detail is 'activation'");
}

# --- 83.1-01 Task 3 Fall-7 (device_changed is_active:false -> Transfer/inactive) ---
{
    my $frame = decode_frame('{"type":"device_changed","is_active":false}');
    my ($class, $detail) = Plugins::SpotOn::Soloist::Control::_classify(
        $frame, {}, {}, undef, 'browse', 1000,
    );
    is($class, 'Transfer', "83.1-01 Task 3 Fall-7: device_changed(is_active:false) classifies Transfer");
    is($detail, 'inactive', "83.1-01 Task 3 Fall-7: detail is 'inactive'");
}

# --- 83.1-01 Task 3 Fall-8 (position_sync in connect, position deviates beyond SEEK_THRESHOLD -> Drift/seek) ---
{
    my $frame = decode_frame(load_fixture('position_sync.json'));    # position_ms=31968
    my $observed = { anchor => { position_ms => 0, seen_at => 1000, }, status => 'paused' };
    my ($class, $detail) = Plugins::SpotOn::Soloist::Control::_classify(
        $frame, {}, $observed, undef, 'connect', 1000,
    );
    is($class, 'Drift', "83.1-01 Task 3 Fall-8: a position_sync jump beyond SEEK_THRESHOLD in connect classifies Drift");
    is($detail, 'seek', "83.1-01 Task 3 Fall-8: detail is 'seek'");
}

# --- 83.1-01 Task 3 Fall-9 (state-report frames -- otherwise -> Drift/<type>, one per remaining type) ---
{
    for my $case (
        [ decode_frame(load_fixture('playback_changed.json')), 'playback_changed' ],
        [ decode_frame(load_fixture('volume_changed.json')),   'volume_changed' ],
        [ decode_frame(load_fixture('auth_state.json')),       'auth_state' ],
        [ decode_frame('{"type":"queue_changed"}'),            'queue_changed' ],
        [ decode_frame('{"type":"_transport","state":"open"}'),'_transport' ],
        [ decode_frame(load_fixture('error.json')),            'error' ],
    ) {
        my ($frame, $type) = @$case;
        my ($class, $detail) = Plugins::SpotOn::Soloist::Control::_classify(
            $frame, {}, {}, undef, 'browse', 1000,
        );
        is($class, 'Drift', "83.1-01 Task 3 Fall-9 ($type): state-report frame classifies Drift");
        is($detail, $type, "83.1-01 Task 3 Fall-9 ($type): detail equals the frame type");
    }
    # position_sync/playback_state in browse (mode != connect) never
    # consult the anchor at all -- always Drift/<type>, same as the other
    # state reports.
    my ($classPs) = Plugins::SpotOn::Soloist::Control::_classify(
        decode_frame(load_fixture('position_sync.json')), {}, {}, undef, 'browse', 1000,
    );
    is($classPs, 'Drift', "83.1-01 Task 3 Fall-9 (position_sync, browse): Drift regardless of position");
}

# --- 83.1-01 Task 3 Fall-10 (any type outside the ten -> unknown) ---
{
    my ($class, $detail) = Plugins::SpotOn::Soloist::Control::_classify(
        { type => 'command_result', command => 'seek' }, {}, {}, undef, 'browse', 1000,
    );
    is($class, 'unknown', "83.1-01 Task 3 Fall-10: an unlisted type classifies unknown");
    is($detail, 'command_result', "83.1-01 Task 3 Fall-10: detail carries the actual type");
}

# --- 83.1-01 Task 3 Fall-11 (onEvent, unlisted type -> unknown, ONE warn
# line, no other observed/wanted/pending mutation) ---
{
    @Slim::Utils::Log::WARNINGS = ();
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:83:11', mode => 'browse',
        wanted   => { uri => $TID },
        observed => { wsConnected => 1, track => $TID, status => 'playing' },
        pending  => { cmd => 'get_state' },
    );
    my $wantedBefore  = { %{ $ctl->wanted } };
    my $observedTrack = $ctl->observed->{track};
    my $observedStatus = $ctl->observed->{status};
    my $pendingBefore = { %{ $ctl->pending } };

    $ctl->onEvent({ type => 'not_a_frame' });

    is($ctl->observed->{lastClass}, 'unknown', "83.1-01 Task 3 Fall-11: lastClass recorded as unknown");
    is(scalar(grep { /Control: classify unknown/ } @Slim::Utils::Log::WARNINGS), 1,
        "83.1-01 Task 3 Fall-11: exactly one 'Control: classify unknown' warn line");
    is_deeply($ctl->wanted, $wantedBefore, "83.1-01 Task 3 Fall-11: wanted untouched");
    is_deeply($ctl->pending, $pendingBefore, "83.1-01 Task 3 Fall-11: pending untouched");
    is($ctl->observed->{track}, $observedTrack, "83.1-01 Task 3 Fall-11: observed.track untouched");
    is($ctl->observed->{status}, $observedStatus, "83.1-01 Task 3 Fall-11: observed.status untouched");
    is_deeply($ws->sent, [], "83.1-01 Task 3 Fall-11: nothing dispatched to LMS");
}

# --- 83.1-01 Task 3 Fall-12 (T1/boundary: _execute([]) is a pure no-op) ---
{
    @Slim::Utils::Timers::TIMERS = ();
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:83:12', observed => { wsConnected => 1 });
    my $ret = $ctl->_execute([]);
    is($ret, 1, "83.1-01 Task 3 Fall-12: _execute([]) returns 1");
    is_deeply($ws->sent, [], "83.1-01 Task 3 Fall-12: nothing sent");
    is(scalar(@Slim::Utils::Timers::TIMERS), 0, "83.1-01 Task 3 Fall-12: no timer armed");
}

# --- 83.1-01 Task 3 Fall-13 (D-02 rollback: a failed slot send restores
# pending/observed/timers to the pre-call snapshot and fires errorCb once) ---
{
    @Slim::Utils::Timers::TIMERS = ();
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:83:13', send_success => 0,
        observed => { wsConnected => 1, track => 'spotify:track:preExistingTrack0000' },
    );
    my $pendingBefore  = $ctl->pending;    # undef
    my $observedBefore = { %{ $ctl->observed } };

    my $err;
    my $intents = [ {
        op       => 'send', cmd => 'play',
        wireArgs => [ uri => $TID ],
        cb       => { errorCb => sub { $err = [@_] } },
        slot     => { uri => $TID, position_ms => 0, armed => 0, awaitMeta => 0, postSeek => undef },
    } ];
    my $ret = $ctl->_execute($intents);

    is($ret, 0, "83.1-01 Task 3 Fall-13: _execute returns 0 on a failed slot send");
    is_deeply($err, [ 'PROBLEM_OPENING', 'Soloist daemon send failed' ],
        "83.1-01 Task 3 Fall-13: the caller's errorCb fired once with PROBLEM_OPENING (D-02)");
    is($ctl->pending, $pendingBefore, "83.1-01 Task 3 Fall-13: pending restored to its pre-call value (D-02 rollback)");
    # WR-01 (83.1-REVIEW.md): observed is deep-equal to the pre-call
    # snapshot PLUS the errorsReported dedupe lock this failed send just
    # wrote -- rollback() restores everything else, but the lock is written
    # AFTER rollback() now specifically so it survives (see WR-01 test
    # below for the regression this closes).
    is_deeply($ctl->observed, { %$observedBefore, errorsReported => { 'send:play' => 1 } },
        "83.1-01 Task 3 Fall-13: observed deep-equal to the pre-call snapshot plus the send:play dedupe lock (WR-01)");
    is(scalar(@Slim::Utils::Timers::TIMERS), 0, "83.1-01 Task 3 Fall-13: no timer left armed (T1 kill was rolled back to its pre-call absence)");
}

# --- 83.1-REVIEW.md WR-01: the dedupe lock the rollback used to erase --
# TWO consecutive failed slot sends of the SAME cmd record exactly ONE
# @Plugins::SpotOn::Status::RECORDED ring entry, not one per attempt.
# Before the fix, _recordErrorOnce ran BEFORE rollback() replaced
# self->observed wholesale with the pre-call snapshot, erasing the
# observed->{errorsReported}{"send:$cmd"} lock it had just written -- a
# daemon whose WS accepts but fails writes (respawn window, half-open
# socket) therefore appended one ring entry per attempt. ---
{
    @Plugins::SpotOn::Status::RECORDED = ();
    @Slim::Utils::Timers::TIMERS       = ();
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:83:w1', send_success => 0,
        observed => { wsConnected => 1 },
    );
    my $mkIntents = sub {
        return [ {
            op       => 'send', cmd => 'play',
            wireArgs => [ uri => $TID ],
            cb       => { errorCb => sub {} },
            slot     => { uri => $TID, position_ms => 0, armed => 0, awaitMeta => 0, postSeek => undef },
        } ];
    };

    $ctl->_execute($mkIntents->());
    $ctl->_execute($mkIntents->());

    my $key = ($ctl->mac // '?') . ':send:play';
    my @sendEntries = grep { defined($_->[3]) && $_->[3] eq $key } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@sendEntries), 1,
        "WR-01: two consecutive failed sends of the same cmd record exactly one send:play ring entry");
}

# --- 83.1-01 Task 3 Fall-14 (T1/adjacency, T1/ordering: two send intents
# for pending-slot commands in one list -- both sent in order, the
# first's errorCb fires 'superseded' exactly once) ---
{
    @Slim::Utils::Timers::TIMERS = ();
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:83:14', observed => { wsConnected => 1 });
    my ($errA, $okA, $okB);
    my $TID_A = 'spotify:track:fall14TrackAAAAAAAAAA';
    my $TID_B = 'spotify:track:fall14TrackBBBBBBBBBB';
    my $intents = [
        { op => 'send', cmd => 'play', wireArgs => [ uri => $TID_A ],
          cb => { successCb => [ sub { $okA = 1 } ], errorCb => sub { $errA = [@_] } },
          slot => { uri => $TID_A, position_ms => 0, armed => 0, awaitMeta => 0, postSeek => undef }, armT1 => 1 },
        { op => 'send', cmd => 'play', wireArgs => [ uri => $TID_B ],
          cb => { successCb => [ sub { $okB = 1 } ] },
          slot => { uri => $TID_B, position_ms => 0, armed => 0, awaitMeta => 0, postSeek => undef }, armT1 => 1 },
    ];
    my $ret = $ctl->_execute($intents);

    is($ret, 1, "83.1-01 Task 3 Fall-14: _execute returns 1 -- both sends succeeded");
    is_deeply($ws->sent, [ [ 'play', { uri => $TID_A } ], [ 'play', { uri => $TID_B } ] ],
        "83.1-01 Task 3 Fall-14: both sends reach the wire, in list order");
    is_deeply($errA, [ 'PROBLEM_OPENING', 'superseded' ],
        "83.1-01 Task 3 Fall-14: the first send's errorCb fires 'superseded' exactly once");
    is($okA, undef, "83.1-01 Task 3 Fall-14: the first send's successCb never fires");
    is($ctl->pending->{uri}, $TID_B, "83.1-01 Task 3 Fall-14: pending is now the second (surviving) slot");
}

# --- 83.1-REVIEW.md WR-02: a FAILED slot send must not tell the
# predecessor it was superseded -- open play-pending A (successful send,
# T1 armed), then a failed slot send B for the SAME cmd (play). Before the
# fix, A's errorCb fired 'superseded' BEFORE the wire attempt for B; when
# B's send then failed and rollback put A right back as pending, a later
# T1 fire for A ALSO fired A's successCb -- both callbacks firing for the
# same predecessor, violating the single-fire contract. Now: B's failure
# means A is untouched (never told 'superseded'), and A's own T1 fires its
# successCb normally when it comes due. ---
{
    @Slim::Utils::Timers::TIMERS = ();
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:83:w2', observed => { wsConnected => 1 });
    my ($errA, $okA);
    my $TID_A = 'spotify:track:wr02TrackAAAAAAAAAAAA';
    my $TID_B = 'spotify:track:wr02TrackBBBBBBBBBBBB';

    my $retA = $ctl->_execute([ {
        op => 'send', cmd => 'play', wireArgs => [ uri => $TID_A ],
        cb => { successCb => [ sub { $okA = 1 } ], errorCb => sub { $errA = [@_] } },
        slot => { uri => $TID_A, position_ms => 0, armed => 0, awaitMeta => 0, postSeek => undef }, armT1 => 1,
    } ]);
    is($retA, 1, "WR-02 setup: A's send succeeds");
    is($ctl->pending->{uri}, $TID_A, "WR-02 setup: A is the live pending slot");

    $ws->{send_success} = 0;
    my $retB = $ctl->_execute([ {
        op => 'send', cmd => 'play', wireArgs => [ uri => $TID_B ],
        cb => { errorCb => sub {} },
        slot => { uri => $TID_B, position_ms => 0, armed => 0, awaitMeta => 0, postSeek => undef }, armT1 => 1,
    } ]);
    is($retB, 0, "WR-02: B's send fails");

    is($errA, undef, "WR-02: A's errorCb never fires -- B's failed send did not supersede it");
    is($ctl->pending->{uri}, $TID_A, "WR-02: A is still the live pending slot after B's rollback");

    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 0.6);    # A's own T1 fires

    is($okA, 1, "WR-02: A's successCb fires exactly once, via its own T1");
    is_deeply($errA, undef, "WR-02: A's errorCb still never fired -- no double-fire");
}

# --- 83.1-01 Task 3 Fall-15 (T1/probe: a probe intent followed by a timer
# intent, with a FAILING send -- the probe never rolls anything back and
# the list continues) ---
{
    @Slim::Utils::Timers::TIMERS = ();
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:83:15', send_success => 0, observed => { wsConnected => 1 });
    my $pendingBefore  = $ctl->pending;
    my $observedBefore = { %{ $ctl->observed } };
    my $marker = sub { };

    my $ret = $ctl->_execute([
        { op => 'probe', cmd => 'get_auth_state' },
        { op => 'timer', cb => $marker, at => Time::HiRes::time() + 10, args => [] },
    ]);

    is($ret, 1, "83.1-01 Task 3 Fall-15: _execute returns 1 -- a probe never fails the list, even with a failing send");
    is_deeply($ws->sent, [ [ 'get_auth_state', {} ] ], "83.1-01 Task 3 Fall-15: get_auth_state reached the wire");
    is(scalar(grep { $_->[0] == $ctl && $_->[2] == $marker } @Slim::Utils::Timers::TIMERS), 1,
        "83.1-01 Task 3 Fall-15: the timer after the probe is still armed -- the list continued");
    is($ctl->pending, $pendingBefore, "83.1-01 Task 3 Fall-15: pending untouched by the probe");
    is_deeply($ctl->observed, $observedBefore, "83.1-01 Task 3 Fall-15: observed untouched by the probe");

    Slim::Utils::Timers::killTimers($ctl, $marker);
}

# --- 83.1-01 Task 3 Fall-16 (T1/ws-undef, require_ws: the WR-06 shape of
# the old _dispatch ws-gone check -- and its Gegenprobe, a list WITHOUT
# require_ws on the same ws-less control) ---
{
    @Slim::Utils::Timers::TIMERS = ();
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:83:16', observed => { wsConnected => 1 });
    $daemon->{ws} = undef;

    my $pendingBefore  = $ctl->pending;
    my $observedBefore = { %{ $ctl->observed } };
    my @ERR;
    my $intents = $ctl->_planCommand('pause', cb => { errorCb => sub { push @ERR, [@_] } });
    my $ret = $ctl->_execute($intents);

    is($ret, 0, "83.1-01 Task 3 Fall-16: _execute returns 0 -- require_ws fails first, before fold-through/supersession");
    is_deeply(\@ERR, [ [ 'PROBLEM_OPENING', 'Soloist daemon gone' ] ],
        "83.1-01 Task 3 Fall-16: errorCb fires the WR-06 shape exactly once");
    is($ctl->pending, $pendingBefore, "83.1-01 Task 3 Fall-16: pending untouched");
    is_deeply($ctl->observed, $observedBefore, "83.1-01 Task 3 Fall-16: observed untouched");
    is(scalar(@Slim::Utils::Timers::TIMERS), 0, "83.1-01 Task 3 Fall-16: no timer armed");

    # Gegenprobe: a list WITHOUT require_ws runs to completion even with
    # `_ws` undef -- there is no per-list ws pre-check in `_execute` itself.
    my $marker = sub { };
    my $ret2 = $ctl->_execute([ { op => 'timer', cb => $marker, at => Time::HiRes::time() + 10, args => [] } ]);
    is($ret2, 1, "83.1-01 Task 3 Fall-16 (Gegenprobe): a list without require_ws succeeds with _ws undef");
    is(scalar(grep { $_->[0] == $ctl && $_->[2] == $marker } @Slim::Utils::Timers::TIMERS), 1,
        "83.1-01 Task 3 Fall-16 (Gegenprobe): the timer IS armed -- no per-list gate");
    Slim::Utils::Timers::killTimers($ctl, $marker);
}

# --- 83.1-01 Task 3 Fall-17 (the probe unit: send+stamp share ONE
# ws-conditional -- no ws means neither; ws present means both,
# REGARDLESS of send success) ---
{
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:83:17a', observed => { wsConnected => 1 });
    $daemon->{ws} = undef;
    my $ret = $ctl->_execute([ { op => 'probe', cmd => 'get_auth_state',
        stamp => { attr => '_lastAuthProbeAt', value => 12345 } } ]);
    is($ret, 1, "83.1-01 Task 3 Fall-17 (ws undef): _execute still returns 1");
    is($ctl->_lastAuthProbeAt, undef, "83.1-01 Task 3 Fall-17 (ws undef): no ws -- no send, no stamp");
}
{
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:83:17b', observed => { wsConnected => 1 });
    $ctl->_execute([ { op => 'probe', cmd => 'get_auth_state',
        stamp => { attr => '_lastAuthProbeAt', value => 12345 } } ]);
    is_deeply($ws->sent, [ [ 'get_auth_state', {} ] ], "83.1-01 Task 3 Fall-17 (ws present): get_auth_state sent");
    is($ctl->_lastAuthProbeAt, 12345, "83.1-01 Task 3 Fall-17 (ws present): stamp applied");
}
{
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:83:17c', send_success => 0, observed => { wsConnected => 1 });
    $ctl->_execute([ { op => 'probe', cmd => 'get_auth_state',
        stamp => { attr => '_lastAuthProbeAt', value => 12345 } } ]);
    is($ctl->_lastAuthProbeAt, 12345,
        "83.1-01 Task 3 Fall-17 (ws present, send fails): the stamp STILL follows the send -- the result is ignored");
}

# ============================================================
# 83.1-02 Task 1: D-D1 claim binding by the transfer class end-to-end
# (Control device_changed -> Connect.pm bind -> isSpotifyConnect true ->
# getNextTrack keeps it). Plugins::SpotOn::Connect is stubbed above with a
# recording bindConnectClaim/releaseConnectClaim (@Plugins::SpotOn::Connect::CLAIMS).
# ============================================================

# --- 83.1-02 Task 1 Fall-1 (bind before start): device_changed(is_active
# true) on a Control in mode browse with no own play pending -> a recorded
# bindConnectClaim(mac, 'transfer') BEFORE _emitStart's 'spottyconnect
# start' execute. ---
{
    @Plugins::SpotOn::Connect::CLAIMS = (); $Plugins::SpotOn::Connect::ACTIVE = undef;
    @Slim::Player::Client::EXECUTED   = ();
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:83:f1', mode => 'browse',
        observed => { wsConnected => 1, track => $TID });

    $ctl->onEvent(decode_frame(load_fixture('device_changed.json')));

    is(scalar(@Plugins::SpotOn::Connect::CLAIMS), 1,
        "83.1-02 Task 1 Fall-1: exactly one claim call recorded");
    is_deeply($Plugins::SpotOn::Connect::CLAIMS[0], [ 'bind', 'aa:bb:cc:dd:83:f1', 'transfer', 0 ],
        "83.1-02 Task 1 Fall-1: bindConnectClaim(mac, 'transfer') recorded BEFORE any spottyconnect execute (4th field = 0 executes so far)");
    is(scalar(@Slim::Player::Client::EXECUTED), 1,
        "83.1-02 Task 1 Fall-1: exactly one spottyconnect execute (the start)");
    is($Slim::Player::Client::EXECUTED[0][1], 'start', "83.1-02 Task 1 Fall-1: the one execute is 'start'");
    is($ctl->mode, 'connect', "83.1-02 Task 1 Fall-1: mode switched to connect");
}

# --- 83.1-02 Task 1 Fall-2: device_changed(is_active false) on a
# connect-mode Control -> releaseConnectClaim(mac, 'inactive') recorded
# AFTER the 'stop','inactive' execute (D-D1 ordering: Connect.pm's stop
# handler must still see isSpotifyConnect true while pausing), mode idle. ---
{
    @Plugins::SpotOn::Connect::CLAIMS = (); $Plugins::SpotOn::Connect::ACTIVE = undef;
    @Slim::Player::Client::EXECUTED   = ();
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:83:f2', mode => 'connect',
        observed => { wsConnected => 1, track => $TID, is_active => 1 });

    $ctl->onEvent({ type => 'device_changed', is_active => 0 });

    is(scalar(@Plugins::SpotOn::Connect::CLAIMS), 1,
        "83.1-02 Task 1 Fall-2: exactly one claim call recorded");
    is_deeply($Plugins::SpotOn::Connect::CLAIMS[0], [ 'release', 'aa:bb:cc:dd:83:f2', 'inactive', 1 ],
        "83.1-02 Task 1 Fall-2: releaseConnectClaim(mac, 'inactive') recorded AFTER the stop execute (4th field = 1 execute already happened)");
    is(scalar(@Slim::Player::Client::EXECUTED), 1,
        "83.1-02 Task 1 Fall-2: exactly one spottyconnect execute (the stop)");
    is($Slim::Player::Client::EXECUTED[0][1], 'stop', "83.1-02 Task 1 Fall-2: the one execute is 'stop'");
    is($Slim::Player::Client::EXECUTED[0][2], 'inactive', "83.1-02 Task 1 Fall-2: stop carries the 'inactive' marker");
    is($ctl->mode, 'idle', "83.1-02 Task 1 Fall-2: mode switched to idle");
    # 84.1-02 A10 (D-01(a), unconditional): the connect half already left
    # mode idle before this plan -- cited here instead of a new block, per
    # this plan's own instruction.
    is($ctl->mode, 'idle', "84.1-02 A10: connect half unchanged -- mode idle after is_active:0 (D-01(a) already held here)");
}

# --- 83.1-02 Task 1 Fall-3 (T4/empty): a device_changed frame WITHOUT
# is_active -> no bind, no release, no die. ---
{
    @Plugins::SpotOn::Connect::CLAIMS = (); $Plugins::SpotOn::Connect::ACTIVE = undef;
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:83:f3', mode => 'browse',
        observed => { wsConnected => 1 });

    my $died = 0;
    eval { $ctl->onEvent({ type => 'device_changed', device_name => 'lavender-UAT' }); 1 } or $died = 1;
    ok(!$died, "83.1-02 Task 1 Fall-3: onEvent does not die on a device_changed frame without is_active (T4/empty)");
    is(scalar(@Plugins::SpotOn::Connect::CLAIMS), 0,
        "83.1-02 Task 1 Fall-3: no bind, no release recorded");
}

# --- 83.1-REVIEW.md CR-02: the SECOND transfer-class entry point --
# playback_state (is_active+playing, mode idle: "Reconnect in laufende
# App-Session", LMS never saw a device_changed(is_active:true) for this
# session) -- must bind the Connect claim exactly like device_changed's
# transfer branch (Fall-1 above), BEFORE _emitStart's 'spottyconnect start'
# execute. Without this, the daemon's later track_changed 'change' is
# dropped by Connect.pm's `unless (isSpotifyConnect || pendingConnect)`
# guard (D-C2 regression on this path). ---
{
    @Plugins::SpotOn::Connect::CLAIMS = (); $Plugins::SpotOn::Connect::ACTIVE = undef;
    @Slim::Player::Client::EXECUTED   = ();
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:83:f4', mode => 'idle',
        observed => { wsConnected => 1 });

    $ctl->onEvent({
        type      => 'playback_state',
        item      => { uri => $TID },
        status    => 'playing',
        is_active => 1,
    });

    is(scalar(@Plugins::SpotOn::Connect::CLAIMS), 1,
        "CR-02: exactly one claim call recorded on the playback_state transfer-in");
    is_deeply($Plugins::SpotOn::Connect::CLAIMS[0], [ 'bind', 'aa:bb:cc:dd:83:f4', 'reconnect', 0 ],
        "CR-02: bindConnectClaim(mac, 'reconnect') recorded BEFORE any spottyconnect execute (4th field = 0 executes so far)");
    is(scalar(@Slim::Player::Client::EXECUTED), 1,
        "CR-02: exactly one spottyconnect execute (the start)");
    is($Slim::Player::Client::EXECUTED[0][1], 'start', "CR-02: the one execute is 'start'");
    is($ctl->mode, 'connect', "CR-02: mode switched to connect");
}

# ============================================================
# 83.1-02 Task 2: D-D2 conflict logging + D-D3/D-04/D-05 split-brain ladder
# ============================================================

# --- 83.1-02 Task 2 Fall-1 (detection needs two frames): mode connect,
# wanted.playing 1, observed.status playing, playmode stub 'stop'; first
# position_sync -> nothing emitted, sightings==1, attempts==0; second
# position_sync -> one 'change' execute, one errors[] entry
# split-brain:<uri>, attempts==1, sightings back to 0. ---
{
    local $Slim::Player::Source::PLAYMODE = 'stop';
    @Slim::Utils::Timers::TIMERS = ();
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:83:t2f1', mode => 'connect',
        wanted   => { playing => 1, uri => $TID },
        observed => { wsConnected => 1, track => $TID, status => 'playing', is_active => 1 });

    @Plugins::SpotOn::Status::RECORDED = ();
    @Slim::Player::Client::EXECUTED    = ();

    $ctl->onEvent({ type => 'position_sync', position => { position_ms => 1000, timestamp_ms => 0, speed => 1 } });
    is($ctl->observed->{splitBrain}{sightings}, 1, "83.1-02 Task 2 Fall-1: first sighting recorded");
    is($ctl->observed->{splitBrain}{attempts}, 0, "83.1-02 Task 2 Fall-1: attempts still 0 after one sighting");
    is(scalar(@Slim::Player::Client::EXECUTED), 0, "83.1-02 Task 2 Fall-1: nothing emitted after one sighting");
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 0, "83.1-02 Task 2 Fall-1: no errors[] entry after one sighting");

    $ctl->onEvent({ type => 'position_sync', position => { position_ms => 1000, timestamp_ms => 0, speed => 1 } });
    is(scalar(@Slim::Player::Client::EXECUTED), 1, "83.1-02 Task 2 Fall-1: one spottyconnect execute after the second sighting");
    is($Slim::Player::Client::EXECUTED[0][1], 'change', "83.1-02 Task 2 Fall-1: the execute is a 'change'");
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 1, "83.1-02 Task 2 Fall-1: exactly one errors[] entry");
    like($Plugins::SpotOn::Status::RECORDED[0][2], qr/LMS und Daemon uneinig/,
        "83.1-02 Task 2 Fall-1: message mentions LMS und Daemon uneinig");
    like($Plugins::SpotOn::Status::RECORDED[0][2], qr/LMS wird nachgezogen/,
        "83.1-02 Task 2 Fall-1: message mentions LMS wird nachgezogen");
    like($Plugins::SpotOn::Status::RECORDED[0][3], qr/split-brain:/,
        "83.1-02 Task 2 Fall-1: errors[] key is split-brain:<uri>");
    is($ctl->observed->{splitBrain}{attempts}, 1, "83.1-02 Task 2 Fall-1: attempts now 1");
    is($ctl->observed->{splitBrain}{sightings}, 0, "83.1-02 Task 2 Fall-1: sightings reset to 0 after nachziehen");

    # --- 83.1-02 Task 2 Fall-2 (D-05 after two failures): continue with
    # playmode still 'stop' through two more sighting-pairs -> the SHARED
    # attempts counter reaches 2 (second nachziehen), then a third pair
    # exceeds SPLIT_BRAIN_MAX_ATTEMPTS -> $ws->sent ends with ['pause',{}],
    # wanted.playing==0, Status::RECORDED has split-brain-halt:<uri>. ---
    $ctl->onEvent({ type => 'position_sync', position => { position_ms => 1000, timestamp_ms => 0, speed => 1 } });
    $ctl->onEvent({ type => 'position_sync', position => { position_ms => 1000, timestamp_ms => 0, speed => 1 } });
    is($ctl->observed->{splitBrain}{attempts}, 2, "83.1-02 Task 2 Fall-2: attempts now 2 (second nachziehen)");
    is(scalar(@Slim::Player::Client::EXECUTED), 2, "83.1-02 Task 2 Fall-2: two spottyconnect executes so far");

    $ctl->onEvent({ type => 'position_sync', position => { position_ms => 1000, timestamp_ms => 0, speed => 1 } });
    $ctl->onEvent({ type => 'position_sync', position => { position_ms => 1000, timestamp_ms => 0, speed => 1 } });
    is_deeply($ws->sent->[-1], [ 'pause', {} ], "83.1-02 Task 2 Fall-2: ws sent ends with pause (Notausgang)");
    is($ctl->wanted->{playing}, 0, "83.1-02 Task 2 Fall-2: wanted.playing cleared to 0");
    is($ctl->observed->{splitBrain}, undef, "83.1-02 Task 2 Fall-2: splitBrain record deleted after the halt");
    is(scalar(@Slim::Player::Client::EXECUTED), 2,
        "83.1-02 Task 2 Fall-2: still exactly two spottyconnect CHANGE executes -- the halt sends no third change");
    my ($haltEntry) = grep { $_->[3] =~ /split-brain-halt:/ } @Plugins::SpotOn::Status::RECORDED;
    ok($haltEntry, "83.1-02 Task 2 Fall-2: split-brain-halt errors[] entry recorded");
    like($haltEntry->[2], qr/Notausgang/, "83.1-02 Task 2 Fall-2: halt message mentions Notausgang") if $haltEntry;
}

# --- 83.1-02 Task 2 Fall-3 (never on LMS-side pause intent, D-08): same
# gate values as Fall-1 but wanted.playing already 0 (an LMS-side pause/
# stop intent, however it got set) -> no split-brain entry, nothing
# emitted, no pause. (requestPause itself is browse-only -- 'mode ne
# browse' returns 0 immediately -- so the intent is set directly here,
# exactly as D-08's guard reads it: the field, not its origin.) ---
{
    local $Slim::Player::Source::PLAYMODE = 'stop';
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:83:t2f3', mode => 'connect',
        wanted   => { playing => 0, uri => $TID },
        observed => { wsConnected => 1, track => $TID, status => 'playing', is_active => 1 });

    @Plugins::SpotOn::Status::RECORDED = ();
    @Slim::Player::Client::EXECUTED    = ();

    $ctl->onEvent({ type => 'position_sync', position => { position_ms => 1000, timestamp_ms => 0, speed => 1 } });
    $ctl->onEvent({ type => 'position_sync', position => { position_ms => 1000, timestamp_ms => 0, speed => 1 } });

    is($ctl->observed->{splitBrain}, undef, "83.1-02 Task 2 Fall-3: no splitBrain record (D-08 exclusion)");
    is(scalar(@Slim::Player::Client::EXECUTED), 0, "83.1-02 Task 2 Fall-3: nothing emitted");
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 0, "83.1-02 Task 2 Fall-3: no errors[] entry");
}

# --- 83.1-02 Task 2 Fall-4 (reset): after one attempt, playmode stub
# 'play' -> next frame clears observed->{splitBrain} and
# _clearErrorOnce('split-brain:<uri>') recorded (the ring entry is
# removed). ---
{
    local $Slim::Player::Source::PLAYMODE = 'stop';
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:83:t2f4', mode => 'connect',
        wanted   => { playing => 1, uri => $TID },
        observed => { wsConnected => 1, track => $TID, status => 'playing', is_active => 1 });

    @Plugins::SpotOn::Status::RECORDED = ();
    @Slim::Player::Client::EXECUTED    = ();

    $ctl->onEvent({ type => 'position_sync', position => { position_ms => 1000, timestamp_ms => 0, speed => 1 } });
    $ctl->onEvent({ type => 'position_sync', position => { position_ms => 1000, timestamp_ms => 0, speed => 1 } });
    is($ctl->observed->{splitBrain}{attempts}, 1, "83.1-02 Task 2 Fall-4: one attempt recorded before the reset");
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 1, "83.1-02 Task 2 Fall-4: one errors[] entry before the reset");

    $Slim::Player::Source::PLAYMODE = 'play';
    $ctl->onEvent({ type => 'position_sync', position => { position_ms => 1000, timestamp_ms => 0, speed => 1 } });

    is($ctl->observed->{splitBrain}, undef, "83.1-02 Task 2 Fall-4: splitBrain record cleared once playmode returns to 'play'");
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 0, "83.1-02 Task 2 Fall-4: the split-brain errors[] entry was cleared, not just superseded");
}

# --- 83.1-02 Task 2 Fall-5 (D-D2 conflict): two Controls (mac A in connect
# with is_active, mac B); B's device_changed(is_active:true) -> the loser
# (A) gets one claim-conflict:<A-mac> errors[] entry and A's
# observed->{is_active} becomes 0, WITHOUT an _emit('stop','inactive') for
# A (A merely lost the claim; its own daemon will report is_active:false
# itself). ---
{
    my ($ctlA, $daemonA, $wsA) = fresh_control(mac => 'aa:bb:cc:dd:83:t2f5a', mode => 'connect',
        observed => { wsConnected => 1, track => $TID, is_active => 1 });
    my ($ctlB, $daemonB, $wsB) = fresh_control(mac => 'aa:bb:cc:dd:83:t2f5b', mode => 'browse',
        observed => { wsConnected => 1, track => $TID });

    $Plugins::SpotOn::Connect::ACTIVE = $ctlA->mac;
    @Plugins::SpotOn::Connect::CLAIMS = ();
    @Plugins::SpotOn::Status::RECORDED = ();
    @Slim::Player::Client::EXECUTED    = ();

    $ctlB->onEvent(decode_frame(load_fixture('device_changed.json')));

    is($ctlA->observed->{is_active}, 0, "83.1-02 Task 2 Fall-5: the loser's (A) is_active flips to 0");
    my ($conflictEntry) = grep { $_->[3] =~ /claim-conflict:/ } @Plugins::SpotOn::Status::RECORDED;
    ok($conflictEntry, "83.1-02 Task 2 Fall-5: a claim-conflict errors[] entry was recorded");
    like($conflictEntry->[3], qr/claim-conflict:\Q@{[$ctlA->mac]}\E/,
        "83.1-02 Task 2 Fall-5: the conflict is keyed on A's mac (the loser)") if $conflictEntry;
    like($conflictEntry->[2], qr/last message wins/i,
        "83.1-02 Task 2 Fall-5: the conflict message mentions last message wins") if $conflictEntry;
    ok(!(grep { $_->[1] eq 'stop' } @Slim::Player::Client::EXECUTED),
        "83.1-02 Task 2 Fall-5: no spottyconnect stop was executed for A");
}

# --- 83.1-02 Task 2 Fall-6 (watchdog entry once, then the ticker ladder --
# the plan-03 contract, D-A3 Nachtrag P2-B2): _connectResync('watchdog')
# creates the record (attempts=1) with NO prior splitBrain state; two
# ticker sightings escalate to attempts=2 (SAME counter); two more ticker
# sightings exceed the cap -> D-05 Notausgang. ---
{
    local $Slim::Player::Source::PLAYMODE = 'stop';
    @Slim::Utils::Timers::TIMERS = ();
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:83:t2f6', mode => 'connect',
        wanted   => { playing => 1, uri => $TID },
        observed => { wsConnected => 1, track => $TID, status => 'playing', is_active => 1 });

    @Plugins::SpotOn::Status::RECORDED = ();
    @Slim::Player::Client::EXECUTED    = ();

    my @ORIGINS;
    my $orig_emit = \&Plugins::SpotOn::Soloist::Control::_emit;
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Soloist::Control::_emit = sub { push @ORIGINS, $_[4]; goto &$orig_emit };

        is($ctl->observed->{splitBrain}, undef, "83.1-02 Task 2 Fall-6: no prior splitBrain record");

        $ctl->_connectResync('watchdog');

        is($ctl->observed->{splitBrain}{attempts}, 1, "83.1-02 Task 2 Fall-6: watchdog creates the record, attempts=1");
        is($ctl->observed->{splitBrain}{reason}, 'watchdog', "83.1-02 Task 2 Fall-6: reason recorded as watchdog");
        is(scalar(@Slim::Player::Client::EXECUTED), 1, "83.1-02 Task 2 Fall-6: one execute after the watchdog attempt");
        is_deeply(\@ORIGINS, [ 'nachziehen' ], "83.1-02 Task 2 Fall-6: origin is 'nachziehen'");
        is(scalar(@Plugins::SpotOn::Status::RECORDED), 1, "83.1-02 Task 2 Fall-6: one errors[] entry (watchdog key)");
        like($Plugins::SpotOn::Status::RECORDED[0][3], qr/watchdog:/, "83.1-02 Task 2 Fall-6: errors[] key is watchdog:<uri>");
        like($Plugins::SpotOn::Status::RECORDED[0][2], qr/nicht.*wieder geoeffnet/,
            "83.1-02 Task 2 Fall-6: watchdog message mentions the re-open failure");
        like($Plugins::SpotOn::Status::RECORDED[0][2], qr/Versuch 1 von 2/,
            "83.1-02 Task 2 Fall-6: watchdog message names attempt 1 of 2");
        unlike($Plugins::SpotOn::Status::RECORDED[0][2], qr/LMS steht, Daemon spielt/,
            "83.1-02 Task 2 Fall-6: watchdog message does NOT claim LMS steht, Daemon spielt");

        $ctl->onEvent({ type => 'position_sync', position => { position_ms => 1000, timestamp_ms => 0, speed => 1 } });
        is(scalar(@Slim::Player::Client::EXECUTED), 1,
            "83.1-02 Task 2 Fall-6: no new execute after only ONE ticker sighting (needs two)");

        $ctl->onEvent({ type => 'position_sync', position => { position_ms => 1000, timestamp_ms => 0, speed => 1 } });
        is($ctl->observed->{splitBrain}{attempts}, 2, "83.1-02 Task 2 Fall-6: attempts now 2 (ONE shared counter)");
        is(scalar(@Slim::Player::Client::EXECUTED), 2, "83.1-02 Task 2 Fall-6: second execute (change) after the ticker escalation");
        is_deeply(\@ORIGINS, [ 'nachziehen', 'nachziehen' ], "83.1-02 Task 2 Fall-6: two nachziehen origins recorded");
        is(scalar(@Plugins::SpotOn::Status::RECORDED), 2, "83.1-02 Task 2 Fall-6: two errors[] entries total");
        like($Plugins::SpotOn::Status::RECORDED[1][3], qr/split-brain:/, "83.1-02 Task 2 Fall-6: second errors[] key is split-brain:<uri>");
        like($Plugins::SpotOn::Status::RECORDED[1][2], qr/Versuch 2 von 2/, "83.1-02 Task 2 Fall-6: second entry names attempt 2 of 2");

        $ctl->onEvent({ type => 'position_sync', position => { position_ms => 1000, timestamp_ms => 0, speed => 1 } });
        $ctl->onEvent({ type => 'position_sync', position => { position_ms => 1000, timestamp_ms => 0, speed => 1 } });

        is_deeply($ws->sent->[-1], [ 'pause', {} ], "83.1-02 Task 2 Fall-6: ws sent ends with pause");
        is($ctl->wanted->{playing}, 0, "83.1-02 Task 2 Fall-6: wanted.playing cleared to 0 (Notausgang)");
        is(scalar(@Slim::Player::Client::EXECUTED), 2,
            "83.1-02 Task 2 Fall-6: exactly two spottyconnect change executes in total (no third)");
        is($ctl->observed->{splitBrain}, undef, "83.1-02 Task 2 Fall-6: splitBrain record deleted after the halt");
        my ($haltEntry) = grep { $_->[3] =~ /split-brain-halt:/ } @Plugins::SpotOn::Status::RECORDED;
        ok($haltEntry, "83.1-02 Task 2 Fall-6: split-brain-halt errors[] entry recorded");
        if ($haltEntry) {
            like($haltEntry->[2], qr/Notausgang/, "83.1-02 Task 2 Fall-6: halt message mentions Notausgang");
            like($haltEntry->[2], qr/split-brain/, "83.1-02 Task 2 Fall-6: halt message names the reason of the last attempt");
        }
        is(scalar(@Slim::Utils::Timers::TIMERS), 0, "83.1-02 Task 2 Fall-6: no timer armed by the halt");
    }
}

# --- 83.1-02 Task 2 Fall-7 (one counter, no double count within a
# silence): after one attempt (attempts 1, sightings 0), a SINGLE further
# ticker sighting does not escalate (sightings 1, attempts STILL 1); a
# watchdog entry then shares the SAME counter (attempts 2); the reset
# (playmode 'play') clears BOTH split-brain:<uri> and watchdog:<uri>. ---
{
    local $Slim::Player::Source::PLAYMODE = 'stop';
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:83:t2f7', mode => 'connect',
        wanted   => { playing => 1, uri => $TID },
        observed => { wsConnected => 1, track => $TID, status => 'playing', is_active => 1 });

    @Plugins::SpotOn::Status::RECORDED = ();
    @Slim::Player::Client::EXECUTED    = ();

    $ctl->onEvent({ type => 'position_sync', position => { position_ms => 1000, timestamp_ms => 0, speed => 1 } });
    $ctl->onEvent({ type => 'position_sync', position => { position_ms => 1000, timestamp_ms => 0, speed => 1 } });
    is($ctl->observed->{splitBrain}{attempts}, 1, "83.1-02 Task 2 Fall-7: one attempt after the first escalation");

    $ctl->onEvent({ type => 'position_sync', position => { position_ms => 1000, timestamp_ms => 0, speed => 1 } });
    is($ctl->observed->{splitBrain}{sightings}, 1, "83.1-02 Task 2 Fall-7: a single further sighting does not escalate");
    is($ctl->observed->{splitBrain}{attempts}, 1, "83.1-02 Task 2 Fall-7: attempts STILL 1 after one lone sighting");

    $ctl->_connectResync('watchdog');
    is($ctl->observed->{splitBrain}{attempts}, 2,
        "83.1-02 Task 2 Fall-7: the watchdog and the ticker share ONE counter (now 2)");

    $Slim::Player::Source::PLAYMODE = 'play';
    $ctl->onEvent({ type => 'position_sync', position => { position_ms => 1000, timestamp_ms => 0, speed => 1 } });
    is($ctl->observed->{splitBrain}, undef, "83.1-02 Task 2 Fall-7: the reset clears the shared record");
    is(scalar(grep { $_->[3] =~ /split-brain:|watchdog:/ } @Plugins::SpotOn::Status::RECORDED), 0,
        "83.1-02 Task 2 Fall-7: the reset clears BOTH split-brain: and watchdog: errors[] keys");
}

# --- 83.1-02 Task 2 Browse gate (D-A2): all of the above in mode=browse ->
# nothing happens; the split-brain check never fires outside connect. ---
{
    local $Slim::Player::Source::PLAYMODE = 'stop';
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:83:t2bg', mode => 'browse',
        wanted   => { playing => 1, uri => $TID },
        observed => { wsConnected => 1, track => $TID, status => 'playing', is_active => 1 });

    @Plugins::SpotOn::Status::RECORDED = ();
    @Slim::Player::Client::EXECUTED    = ();

    $ctl->onEvent({ type => 'position_sync', position => { position_ms => 1000, timestamp_ms => 0, speed => 1 } });
    $ctl->onEvent({ type => 'position_sync', position => { position_ms => 1000, timestamp_ms => 0, speed => 1 } });

    is($ctl->observed->{splitBrain}, undef, "83.1-02 Task 2 Browse gate: no splitBrain record in mode=browse");
    is(scalar(@Slim::Player::Client::EXECUTED), 0, "83.1-02 Task 2 Browse gate: nothing emitted in mode=browse");
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 0, "83.1-02 Task 2 Browse gate: no errors[] entry in mode=browse");
}

# ============================================================
# 83.1-02 Task 3: wr04 (planned stop writes no transport-lost error) and
# wr05 (_awaitMeta supersession + nometa: clear)
# ============================================================

# --- 83.1-02 Task 3 wr04 Fall-1: shutdown then a '_transport closed'
# pseudo-frame -> no ':transport' errors[] entry, no 'WS transport lost'
# warn line (a planned teardown is not a transport LOSS). ---
{
    @Plugins::SpotOn::Status::RECORDED = ();
    @Slim::Utils::Log::WARNINGS        = ();
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:83:wr04a', observed => { wsConnected => 1 });

    $ctl->shutdown;
    $ctl->onEvent({ type => '_transport', state => 'closed' });

    ok(!(grep { defined($_->[3]) && $_->[3] =~ /:transport$/ } @Plugins::SpotOn::Status::RECORDED),
        "83.1-02 Task 3 wr04 Fall-1: no errors[] entry keyed :transport after a planned shutdown");
    ok(!(grep { /WS transport lost/ } @Slim::Utils::Log::WARNINGS),
        "83.1-02 Task 3 wr04 Fall-1: no 'WS transport lost' warn line after a planned shutdown");
}

# --- 83.1-02 Task 3 wr04 Fall-2 (Gegenprobe): '_transport closed' WITHOUT
# a prior shutdown still records exactly one :transport entry (existing
# behavior preserved -- this plan narrows the write, it does not remove
# it). ---
{
    @Plugins::SpotOn::Status::RECORDED = ();
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:83:wr04b', observed => { wsConnected => 1 });

    $ctl->onEvent({ type => '_transport', state => 'closed' });

    is(scalar(grep { defined($_->[3]) && $_->[3] =~ /:transport$/ } @Plugins::SpotOn::Status::RECORDED), 1,
        "83.1-02 Task 3 wr04 Fall-2 (Gegenprobe): exactly one :transport errors[] entry without a prior shutdown");
}

# --- 83.1-02 Task 3 wr05 Fall-1: echo X (no duration) arms _awaitMeta X; a
# second echo Y arms _awaitMeta Y -> exactly one _tMetaFire timer remains
# (the old one for X was killed, not left standing against the wrong
# uri), X's cb got errorCb 'superseded' exactly once, and the surviving
# timer resolves Y (not a phantom fire against X). ---
{
    @Slim::Utils::Timers::TIMERS = ();
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:83:wr05a', observed => { wsConnected => 1, meta => {} });
    my $Y = 'spotify:track:22eFghVXANMlKmJXsNCbNl';

    my ($successX, $errorTypeX, $errorTextX);
    $ctl->requestTrack($TID, 0, { successCb => sub { $successX++ }, errorCb => sub { ($errorTypeX, $errorTextX) = @_ } });
    $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));    # X's echo, no duration -> awaitMeta X

    ok(defined $ctl->_awaitMeta, "83.1-02 Task 3 wr05 Fall-1: awaitMeta armed for X");
    is($ctl->_awaitMeta->{uri}, $TID, "83.1-02 Task 3 wr05 Fall-1: awaitMeta holds X's uri");
    is(scalar(@Slim::Utils::Timers::TIMERS), 1, "83.1-02 Task 3 wr05 Fall-1: exactly one _tMetaFire timer after X's echo");

    my $successY;
    $ctl->requestTrack($Y, 0, { successCb => sub { $successY++ } });
    $ctl->onEvent({ type => 'track_changed', item => { uri => $Y } });    # Y's echo, no duration -> awaitMeta Y

    is($errorTypeX, 'PROBLEM_OPENING', "83.1-02 Task 3 wr05 Fall-1: X's cb got an errorCb");
    is($errorTextX, 'superseded', "83.1-02 Task 3 wr05 Fall-1: the errorCb reason is 'superseded'");
    ok(!$successX, "83.1-02 Task 3 wr05 Fall-1: X's successCb never fired");
    ok(defined $ctl->_awaitMeta, "83.1-02 Task 3 wr05 Fall-1: awaitMeta now armed for Y");
    is($ctl->_awaitMeta->{uri}, $Y, "83.1-02 Task 3 wr05 Fall-1: awaitMeta holds Y's uri");
    is(scalar(@Slim::Utils::Timers::TIMERS), 1,
        "83.1-02 Task 3 wr05 Fall-1: still exactly ONE _tMetaFire timer -- the old one was killed, not left standing (WR-06 timer-pairing class closed)");

    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 2);
    ok(!$successX, "83.1-02 Task 3 wr05 Fall-1: X never resolves, even after the sweep (its cb was already released)");
    is($successY, 1, "83.1-02 Task 3 wr05 Fall-1: the surviving timer resolves Y, not a phantom X");
}

# --- 83.1-02 Task 3 wr05 Fall-2: noteMetadataMissing(Y) then
# noteDuration(Y, 213) -> the nometa:Y errors[] entry is cleared (not just
# superseded) and seekable(Y) promotes to 1. ---
{
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:83:wr05b', observed => { wsConnected => 1, meta => {} });
    my $Y = 'spotify:track:22eFghVXANMlKmJXsNCbNl';

    @Plugins::SpotOn::Status::RECORDED = ();
    $ctl->noteMetadataMissing($Y);
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 1, "83.1-02 Task 3 wr05 Fall-2: nometa:Y recorded");
    is($ctl->seekable($Y), 0, "83.1-02 Task 3 wr05 Fall-2: seekable(Y) is 0 after noteMetadataMissing");

    $ctl->noteDuration($Y, 213);
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 0, "83.1-02 Task 3 wr05 Fall-2: noteDuration clears the nometa:Y entry");
    is($ctl->seekable($Y), 1, "83.1-02 Task 3 wr05 Fall-2: seekable(Y) promoted to 1");
}

# ============================================================
# 83.1-03 Task 2 (D-08): requestPause/requestResume/requestVolume mode-aware
# -- LMS pause/stop/unpause/volume in mode=connect go through Control's
# request primitives the same way browse always has, never deadened.
# ============================================================

# --- 83.1-03 Task 2 Fall-1 (D-08 pause in connect): _lmsSongIsOurs true,
# playmode stub 'pause', requestPause(0) -> wanted.playing==0, ws->sent
# ends with ['pause',{}], return value 1. ---
{
    local $Slim::Player::Source::PLAYMODE = 'pause';
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:83:t2f1', mode => 'connect',
        wanted   => { playing => 1, uri => $TID },
        observed => { wsConnected => 1, track => $TID, status => 'playing' });
    own_track($ctl->mac);

    my $rc = $ctl->requestPause(0);

    is($rc, 1, "83.1-03 Task 2 Fall-1: requestPause returns 1");
    is($ctl->wanted->{playing}, 0, "83.1-03 Task 2 Fall-1: wanted.playing cleared to 0");
    is_deeply($ws->sent->[-1], [ 'pause', {} ], "83.1-03 Task 2 Fall-1: ws sent ends with ['pause',{}]");
    is($ctl->mode, 'connect', "83.1-03 Task 2 Fall-1: mode stays connect");
}

# --- 83.1-03 Task 2 Fall-2 (stop in connect): requestPause(1) with a stale
# observed.status 'paused' -- pause is still sent (isStop forces it, the
# 82-20 rule holds in connect too). ---
{
    local $Slim::Player::Source::PLAYMODE = 'pause';
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:83:t2f2', mode => 'connect',
        wanted   => { playing => 1, uri => $TID },
        observed => { wsConnected => 1, track => $TID, status => 'paused' });
    own_track($ctl->mac);

    $ctl->requestPause(1);

    is_deeply($ws->sent->[-1], [ 'pause', {} ],
        "83.1-03 Task 2 Fall-2: ws sent ends with pause despite stale observed.status (isStop forces it)");
}

# --- 83.1-03 Task 2 Fall-3 (historic notification in connect): playmode
# stub 'play' -> nothing sent, wanted.playing stays 1 (the internal stop
# before 'playlist play' is recognized the same way as in browse). ---
{
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:83:t2f3', mode => 'connect',
        wanted   => { playing => 1, uri => $TID },
        observed => { wsConnected => 1, track => $TID, status => 'playing' });
    own_track($ctl->mac);

    my $rc = $ctl->requestPause(0);

    is($rc, 1, "83.1-03 Task 2 Fall-3: requestPause returns 1 (historic notification recognized)");
    is($ctl->wanted->{playing}, 1, "83.1-03 Task 2 Fall-3: wanted.playing stays 1 -- nothing dispatched");
    is_deeply($ws->sent, [], "83.1-03 Task 2 Fall-3: nothing sent to the daemon");
}

# --- 83.1-03 Task 2 Fall-4 (resume + volume in connect): requestResume
# with observed.status 'paused' -> ['play',{}]; requestVolume(37) with
# observed.volume 20 -> ['set_volume',{volume=>37}]; with observed.volume
# already 37 -> nothing (idempotent). ---
{
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:83:t2f4', mode => 'connect',
        wanted   => { playing => 0, uri => $TID },
        observed => { wsConnected => 1, track => $TID, status => 'paused', volume => 20 });
    own_track($ctl->mac);

    $ctl->requestResume;
    is_deeply($ws->sent->[-1], [ 'play', {} ], "83.1-03 Task 2 Fall-4: requestResume -- ['play',{}] sent");

    $ctl->requestVolume(37);
    is_deeply($ws->sent->[-1], [ 'set_volume', { volume => 37 } ],
        "83.1-03 Task 2 Fall-4: requestVolume(37) with observed.volume 20 -- set_volume sent");

    $ctl->observed->{volume} = 37;
    my $sentCountBefore = scalar(@{ $ws->sent });
    $ctl->requestVolume(37);
    is(scalar(@{ $ws->sent }), $sentCountBefore,
        "83.1-03 Task 2 Fall-4: requestVolume(37) is idempotent once observed.volume already 37");
}

# --- 83.1-03 Task 2 Fall-5 (foreign LMS title in connect, CR-04 discipline
# kept): _lmsSongIsOurs false -- requestPause(0) -> 0, nothing sent;
# requestPause(1) -> exactly one pause (a Stop always forces one, T-82-64);
# mode stays connect (leaveBrowse not called outside mode=browse). ---
{
    local $Slim::Player::Source::PLAYMODE = 'pause';
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:83:t2f5', mode => 'connect',
        wanted   => { playing => 1, uri => $TID },
        observed => { wsConnected => 1, track => $TID, status => 'playing' });
    foreign_track($ctl->mac);

    my $rc0 = $ctl->requestPause(0);
    is($rc0, 0, "83.1-03 Task 2 Fall-5: requestPause(0) on a foreign LMS title returns 0");
    is_deeply($ws->sent, [], "83.1-03 Task 2 Fall-5: nothing sent for a non-Stop pause on a foreign title");

    $ctl->requestPause(1);
    is(scalar(@{ $ws->sent }), 1,
        "83.1-03 Task 2 Fall-5: requestPause(1)/Stop forces exactly one pause even on a foreign title");
    is_deeply($ws->sent->[0], [ 'pause', {} ], "83.1-03 Task 2 Fall-5: the one send is 'pause'");
    is($ctl->mode, 'connect', "83.1-03 Task 2 Fall-5: mode stays connect -- leaveBrowse is not called outside mode=browse");
}

# ============================================================
# 83.1-03 Task 3 (EIGENTUMSFRAGE point 1): the connect ownership invariant
# guard -- a safety net for a defect, never a feature path. Proves the
# guard actually intercepts a play<uri> intent that reaches _reconcile in
# mode=connect WITHOUT LMS-request provenance ($opts->{source} neither
# 'getNextTrack' nor 'onStream') -- a synthetic scenario this plan's own
# real call sites never produce (both tag source correctly by contract).
# ============================================================

# --- 83.1-03 invariant: BEFORE the deliberate-trigger scenario below, the
# guard must never have fired across every REAL usage in this file so far
# (every connect requestTrack call above is properly source-tagged
# getNextTrack/onStream; every direct _dispatch caller -- watchdogRing,
# _connectResync, playback-state resume -- is out of this guard's reach by
# construction, see _enforceConnectOwnershipInvariant's own doc comment).
# Checked against whatever the LAST reset-then-populate block above left
# in Status::RECORDED (the file resets this array throughout; a stray
# invariant: key surviving to here would mean some earlier real call
# triggered the safety net -- exactly the false-positive the acceptance
# criteria warns against). ---
ok(!(grep { defined($_->[3]) && $_->[3] =~ /invariant:/ } @Plugins::SpotOn::Status::RECORDED),
    "83.1-03 invariant: no invariant: errors[] entry from any real call before the deliberate defect scenario below");

{
    my $OLD = 'spotify:track:oldUri00000000000000000';
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:83:t3inv', mode => 'connect',
        wanted   => { playing => 1, uri => $OLD },
        observed => { wsConnected => 1, track => $OLD, status => 'playing' });

    @Plugins::SpotOn::Status::RECORDED = ();
    @Slim::Utils::Log::WARNINGS        = ();

    # No `source` key -- NOT an LMS request (getNextTrack/onStream). A real
    # caller never does this (module contract); this is the synthetic
    # defect scenario the guard exists to catch.
    $ctl->requestTrack($TID, 0, {});

    ok(!(grep { $_->[0] eq 'play' } @{ $ws->sent }),
        "83.1-03 invariant: no 'play' reached ws->sent for a non-LMS-tagged trigger in connect");
    my ($invEntry) = grep { defined($_->[3]) && $_->[3] =~ /invariant:play/ } @Plugins::SpotOn::Status::RECORDED;
    ok($invEntry, "83.1-03 invariant: invariant:play errors[] entry recorded");
    like($invEntry->[2], qr/connect invariant -- suppressed play/, "83.1-03 invariant: message names the suppressed command")
        if $invEntry;
    like($invEntry->[2], qr/daemon owns the queue/, "83.1-03 invariant: message cites the ownership rationale")
        if $invEntry;
    ok((grep { /connect invariant -- suppressed/ } @Slim::Utils::Log::WARNINGS),
        "83.1-03 invariant: warn logged");
}

# ============================================================
# 83.1-04 Task 1 (D-B1): connect seek runs through the restart chain into
# Control (arm + seek, no play uri) -- the same _JumpToTime/onStream chain
# Browse uses. requestTrack(seek => 1, source => 'onStream') is the exact
# call onStream (ProtocolHandler.pm) makes; this file exercises Control
# directly, one layer below ProtocolHandler/Connect.pm's own grep gates
# (t/37).
# ============================================================

# --- 83.1-04 Task 1 Fall-1 (connect seek row): mode connect,
# observed.track eq $TID, status playing, anchor at 20000ms ->
# requestTrack($TID, 74000, {seek=>1, source=>'onStream'}) -- exactly one
# loopback POST to /seek-arm (the arm) and $ws->sent is EXACTLY
# [['seek',{position_ms=>74000}]], no play at all; wanted.position_ms ==
# 74000. ---
{
    @IO::Socket::INET::CALLS = ();

    my ($ctl, $daemon, $ws) = fresh_control(mode => 'connect',
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'playing',
                      anchor => { position_ms => 20000, seen_at => Time::HiRes::time() } });

    $ctl->requestTrack($TID, 74000, { seek => 1, source => 'onStream' });

    is(scalar(@IO::Socket::INET::CALLS), 1, "83.1-04 Task 1 Fall-1: one loopback POST to /seek-arm (the arm)");
    is_deeply($ws->sent, [ [ 'seek', { position_ms => 74000 } ] ],
        "83.1-04 Task 1 Fall-1: ws->sent is exactly [['seek',{position_ms=>74000}]] -- no play at all");
    is($ctl->wanted->{position_ms}, 74000, "83.1-04 Task 1 Fall-1: wanted.position_ms == 74000");
}

# --- 83.1-04 Task 1 Fall-2 (browse Gegenprobe, per plan text no new
# assertion): the existing browse seek cases in this file (e.g. the
# G1-FIX/CR-01 blocks above) already cover mode=browse's arm+seek+bare-play
# shape and are re-run unmodified by this same `prove` invocation -- their
# continued PASS is Fall-2's own proof that browse is unchanged. ---

# --- 83.1-04 Task 1 Fall-3 (duration capture): a Control with
# observed.meta empty receives the real playback_state.json frame ->
# seekable($TID) is 1 and observed.meta{$TID}{duration} equals
# item.playback.duration_ms/1000 (207959/1000). The same frame's
# available_actions is captured too (D-B4 infrastructure, consumed by
# Task 2's requestSkip). ---
{
    my ($ctl, $daemon, $ws) = fresh_control(mode => 'connect', observed => { wsConnected => 1, meta => {} });

    $ctl->onEvent(decode_frame(load_fixture('playback_state.json')));

    is($ctl->seekable($TID), 1, "83.1-04 Task 1 Fall-3: seekable becomes 1 from the real playback_state.json frame");
    is($ctl->observed->{meta}{$TID}{duration}, 207959 / 1000,
        "83.1-04 Task 1 Fall-3: observed.meta duration equals item.playback.duration_ms/1000");
    ok($ctl->observed->{availableActions}{skip_next},
        "83.1-04 Task 1 Fall-3: availableActions captured from the same frame (skip_next present)");
    ok(!$ctl->observed->{availableActions}{skip_prev},
        "83.1-04 Task 1 Fall-3: availableActions captured from the same frame (skip_prev absent, per the real fixture)");
}

# --- 83.1-04 Task 1 Fall-4 (idempotent arm): two requestTrack(seek=>1)
# calls for the same position within SEEK_ISSUED_WINDOW_S -> one seek on
# the wire (the existing _seekAlreadyIssued rule holds in connect too). ---
{
    my ($ctl, $daemon, $ws) = fresh_control(mode => 'connect',
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'playing',
                      anchor => { position_ms => 20000, seen_at => Time::HiRes::time() } });

    $ctl->requestTrack($TID, 74000, { seek => 1, source => 'onStream' });
    $ctl->requestTrack($TID, 74000, { seek => 1, source => 'onStream' });

    is(scalar(grep { $_->[0] eq 'seek' } @{ $ws->sent }), 1,
        "83.1-04 Task 1 Fall-4: idempotent arm -- exactly one seek on the wire for two identical requests");
}

# --- 84.1-06 C1/C2 (guarded by DECIDING_connect-weiter-nach-pause-haengt-im-puffern=confirmed,
# see 84.1-CLUSTER2-VERDICTS.md): a dropped-then-reopened connect stream
# whose daemon still reports 'paused' at the seek dispatch gets a
# follow-up bare `play` (Resume-Semantik) so it does not hang in
# BUFFERING forever (84.1-05 B4, both players CONFIRMED); a daemon that
# already reports 'playing' at the same seek dispatch gets NO such play
# (D-B1 unchanged for that case). ---

# --- 84.1-06 C1 (paused -> seek then play): mode connect, observed.track
# eq $TID, status paused, wanted.playing true -> requestTrack(seek=>1)
# sends seek(armed) FOLLOWED by a bare play. ---
{
    my ($ctl, $daemon, $ws) = fresh_control(mode => 'connect',
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'paused',
                      anchor => { position_ms => 69212, seen_at => Time::HiRes::time() } });

    $ctl->requestTrack($TID, 69212, { seek => 1, source => 'onStream' });

    is_deeply($ws->sent, [ [ 'seek', { position_ms => 69212 } ], [ 'play', {} ] ],
        "84.1-06 C1: paused daemon -- seek(armed) followed by a bare play");
}

# --- 84.1-06 C2 (Gegenprobe, playing -> seek only, no play): the D-B1 row
# for an already-playing daemon is unchanged by C1's fix. ---
{
    my ($ctl, $daemon, $ws) = fresh_control(mode => 'connect',
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'playing',
                      anchor => { position_ms => 20000, seen_at => Time::HiRes::time() } });

    $ctl->requestTrack($TID, 74000, { seek => 1, source => 'onStream' });

    is_deeply($ws->sent, [ [ 'seek', { position_ms => 74000 } ] ],
        "84.1-06 C2: playing daemon -- seek only, no play (D-B1 unchanged)");
}

# --- 84-08 IN-09 (D-22, Task 2b resolved 2026-10-11: KEEP, user "Behalten +
# Todo (Empfohlen)"). The `&& $wanted->{playing}` clause of the connect
# seek row (_reconcilePlan) is reached with wanted.playing = 0 ONLY through
# a replay of stored requestTrack opts -- never on the direct path, because
# requestTrack rewrites `wanted` with playing => 1 before _reconcile.
# R1 (replay, WS catch-up): an onStream seek re-open arrives before the
# daemon's first frame -> deferred; an LMS pause falls in between
# (requestPause -> wanted.playing 0); the login answer replays the stored
# opts (_reconcile('requestTrack', $deferred->{opts})) with observed status
# paused -> the plan holds the seek and NO play. Teeth: removing the clause
# makes R1 red (84-08 SUMMARY quotes the `not ok`). R2 (direct path,
# Gegenprobe): pause, then the seek-shaped requestTrack itself -> seek AND
# play (today's behaviour; the clause is inert there). ---
{
    local $Slim::Player::Source::PLAYMODE = 'pause';
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:ee:09', mode => 'connect',
        observed => { wsConnected => 0, meta => {}, track => $TID, status => 'paused',
                      anchor => { position_ms => 69212, seen_at => Time::HiRes::time() } });

    $ctl->requestTrack($TID, 69212, { seek => 1, source => 'onStream' });
    ok($ctl->_deferredTrackRequest, "IN-09 R1: the seek re-open is deferred (no daemon frame yet)");
    is($ctl->wanted->{playing}, 1, "IN-09 R1: requestTrack set wanted.playing 1 (the direct path never sees 0)");

    $ctl->requestPause(0);
    is($ctl->wanted->{playing}, 0, "IN-09 R1: the LMS pause between deferral and replay sets wanted.playing 0");

    $ctl->onEvent({ type => '_transport', state => 'open' });
    my $before = scalar(@{ $ws->sent });
    @Slim::Utils::Log::WARNINGS = ();
    # the login answer of the SAME live session (is_active true: the
    # session is still ours -- the recorded fixture's is_active:false would
    # end the connect session before the replay and test another row)
    $ctl->onEvent({ type => 'auth_state', logged_in => 1, is_active => 1, device_name => 'lavender-UAT' });
    my @replay = map { $_->[0] } @{ $ws->sent }[ $before .. $#{ $ws->sent } ];

    ok(!$ctl->_deferredTrackRequest, "IN-09 R1: the login answer consumed the deferral (WS catch-up replay ran)");
    is(scalar(grep { $_ eq 'seek' } @replay), 1, "IN-09 R1: the replayed seek row sends the seek");
    is(scalar(grep { $_ eq 'play' } @replay), 0,
        "IN-09 R1: replay with wanted.playing 0 and a paused daemon -- NO play (the clause keeps the LMS pause)");
    $ctl->shutdown;
}
{
    local $Slim::Player::Source::PLAYMODE = 'pause';
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:ee:0a', mode => 'connect',
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'paused',
                      anchor => { position_ms => 69212, seen_at => Time::HiRes::time() } });

    $ctl->requestPause(0);
    is($ctl->wanted->{playing}, 0, "IN-09 R2: LMS pause -> wanted.playing 0");
    my $before = scalar(@{ $ws->sent });
    $ctl->requestTrack($TID, 69212, { seek => 1, source => 'onStream' });
    my @direct = map { $_->[0] } @{ $ws->sent }[ $before .. $#{ $ws->sent } ];

    is_deeply(\@direct, [ 'seek', 'play' ],
        "IN-09 R2: direct pause -> seek-shaped requestTrack -- seek AND play (requestTrack re-sets wanted.playing 1; the clause is inert here)");
    $ctl->shutdown;
}

# ============================================================
# 83.1-04 Task 2 (D-B2/D-B4): requestSkip -- jump +1/-1/+0 as skip_next/
# skip_prev through the one Control entry point; D-B4 available_actions
# precondition refuses and logs instead of guessing; the LMS-side backward
# jump falls (no play with a uri, no seek, on a jump +1 sequence).
# ============================================================

# --- 83.1-04 Task 2 Fall-1: mode connect, observed.availableActions
# learned from the real playback_state.json frame (contains skip_next) --
# requestSkip('next') sends exactly [['skip_next',{}]] and returns 1. ---
{
    my ($ctl, $daemon, $ws) = fresh_control(mode => 'connect', observed => { wsConnected => 1, meta => {} });
    $ctl->onEvent(decode_frame(load_fixture('playback_state.json')));

    my $rc = $ctl->requestSkip('next');

    is_deeply($ws->sent, [ [ 'skip_next', {} ] ],
        "83.1-04 Task 2 Fall-1: requestSkip('next') sends exactly [['skip_next',{}]]");
    is($rc, 1, "83.1-04 Task 2 Fall-1: requestSkip('next') returns 1");
}

# --- 83.1-04 Task 2 Fall-2 (the resume rule): wanted.stopBy eq 'lms-stop'
# (set by a preceding requestPause(1) in connect with playmode 'stop') --
# requestSkip('next') sends [['pause',{}],['skip_next',{}],['play',{}]] in
# that order; wanted.playing==1, wanted.stopBy cleared (LMS's own one-entry
# playlist ran out; the session's actual intent was playing). ---
{
    local $Slim::Player::Source::PLAYMODE = 'stop';
    my ($ctl, $daemon, $ws) = fresh_control(mode => 'connect',
        wanted   => { playing => 1, uri => $TID },
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'playing',
                      availableActions => { skip_next => 1 } });
    own_track($ctl->mac);

    $ctl->requestPause(1);
    is($ctl->wanted->{stopBy}, 'lms-stop', "83.1-04 Task 2 Fall-2: requestPause(1) marks wanted.stopBy=lms-stop in connect");

    $ctl->requestSkip('next');

    is_deeply($ws->sent, [ [ 'pause', {} ], [ 'skip_next', {} ], [ 'play', {} ] ],
        "83.1-04 Task 2 Fall-2: pause, skip_next, then the resume play -- in that order");
    is($ctl->wanted->{playing}, 1, "83.1-04 Task 2 Fall-2: wanted.playing restored to 1");
    ok(!exists $ctl->wanted->{stopBy}, "83.1-04 Task 2 Fall-2: wanted.stopBy cleared");
}

# --- 83.1-04 Task 2 Fall-3 (D-B4 verb absent): observed.availableActions
# from the REAL 83.1-station-no-skip-prev.json fixture (available_actions
# lacks skip_prev) -- requestSkip('prev') sends nothing, warns once,
# records errors[] key refused-action:skip_prev, returns 0. ---
{
    @Plugins::SpotOn::Status::RECORDED = ();
    @Slim::Utils::Log::WARNINGS        = ();

    my ($ctl, $daemon, $ws) = fresh_control(mode => 'connect', observed => { wsConnected => 1, meta => {} });
    $ctl->onEvent(decode_frame(load_fixture('83.1-station-no-skip-prev.json')));

    my $rc = $ctl->requestSkip('prev');

    is($rc, 0, "83.1-04 Task 2 Fall-3: requestSkip('prev') refused -- returns 0");
    is_deeply($ws->sent, [], "83.1-04 Task 2 Fall-3: nothing sent");
    ok((grep { /skip_prev refused -- available_actions lacks it/ } @Slim::Utils::Log::WARNINGS),
        "83.1-04 Task 2 Fall-3: warn logged");
    my ($errEntry) = grep { defined($_->[3]) && $_->[3] =~ /refused-action:skip_prev$/ } @Plugins::SpotOn::Status::RECORDED;
    ok($errEntry, "83.1-04 Task 2 Fall-3: errors[] key refused-action:skip_prev recorded");
}

# --- 83.1-04 Task 2 Fall-4 (D-B4 field never seen): observed.availableActions
# undefined (no frame has ever carried it) -- requestSkip('next') sends
# nothing, warns with vorbedingung_actions_unbekannt, records errors[] key
# refused-action:skip_next, returns 0. A missing field is not permission. ---
{
    @Plugins::SpotOn::Status::RECORDED = ();
    @Slim::Utils::Log::WARNINGS        = ();

    my ($ctl, $daemon, $ws) = fresh_control(mode => 'connect', observed => { wsConnected => 1, meta => {} });

    my $rc = $ctl->requestSkip('next');

    is($rc, 0, "83.1-04 Task 2 Fall-4: requestSkip('next') refused (field never seen) -- returns 0");
    is_deeply($ws->sent, [], "83.1-04 Task 2 Fall-4: nothing sent");
    ok((grep { /vorbedingung_actions_unbekannt/ } @Slim::Utils::Log::WARNINGS),
        "83.1-04 Task 2 Fall-4: warn cites vorbedingung_actions_unbekannt");
    my ($errEntry) = grep { defined($_->[3]) && $_->[3] =~ /refused-action:skip_next$/ } @Plugins::SpotOn::Status::RECORDED;
    ok($errEntry, "83.1-04 Task 2 Fall-4: errors[] key refused-action:skip_next recorded");
}

# --- 83.1-04 Task 2 Fall-5 (clear on acceptance): after a Fall-3-style
# refusal, availableActions later learns skip_prev -- requestSkip('prev')
# is now accepted and the refused-action:skip_prev errors[] entry is
# cleared (_clearErrorOnce). ---
{
    @Plugins::SpotOn::Status::RECORDED = ();
    @Slim::Utils::Log::WARNINGS        = ();

    my ($ctl, $daemon, $ws) = fresh_control(mode => 'connect', observed => { wsConnected => 1, meta => {} });
    $ctl->onEvent(decode_frame(load_fixture('83.1-station-no-skip-prev.json')));
    $ctl->requestSkip('prev');    # refused -- records the ring entry

    ok((grep { defined($_->[3]) && $_->[3] =~ /refused-action:skip_prev$/ } @Plugins::SpotOn::Status::RECORDED),
        "83.1-04 Task 2 Fall-5 setup: the refusal ring entry exists before the daemon learns skip_prev");

    # A later frame's available_actions DOES carry skip_prev -- keep the
    # LAST known set (Task 1's own capture rule).
    $ctl->observed->{availableActions} = { skip_prev => 1, skip_next => 1, pause => 1 };

    my $rc = $ctl->requestSkip('prev');

    is($rc, 1, "83.1-04 Task 2 Fall-5: requestSkip('prev') now accepted");
    is_deeply($ws->sent, [ [ 'skip_prev', {} ] ], "83.1-04 Task 2 Fall-5: skip_prev sent");
    ok(!(grep { defined($_->[3]) && $_->[3] =~ /refused-action:skip_prev$/ } @Plugins::SpotOn::Status::RECORDED),
        "83.1-04 Task 2 Fall-5: refused-action:skip_prev errors[] entry cleared");
}

# --- 83.1-04 Task 2 Fall-6 (browse, D-A2): mode browse -- requestSkip
# ('next') returns 0, nothing sent, no errors[] entry. Browse moves its own
# playlist via getNextTrack, never a skip_* wire command. ---
{
    @Plugins::SpotOn::Status::RECORDED = ();

    my ($ctl, $daemon, $ws) = fresh_control(mode => 'browse',
        observed => { wsConnected => 1, meta => {}, availableActions => { skip_next => 1 } });

    my $rc = $ctl->requestSkip('next');

    is($rc, 0, "83.1-04 Task 2 Fall-6: requestSkip('next') in browse returns 0 (D-A2)");
    is_deeply($ws->sent, [], "83.1-04 Task 2 Fall-6: nothing sent in browse");
    is(scalar(@Plugins::SpotOn::Status::RECORDED), 0, "83.1-04 Task 2 Fall-6: no errors[] entry in browse");
}

# --- 83.1-04 Task 2 Fall-7 (the backward jump falls): connect,
# observed.track eq $TID; simulate the LMS sequence of a jump +1 on a
# one-entry playlist -- requestPause(1) (playmode 'stop', LMS's own
# internal stop, D-08) then requestSkip('next'); no play with a uri and no
# seek reach the wire -- the stale-replay path this plan removes. ---
{
    local $Slim::Player::Source::PLAYMODE = 'stop';
    my ($ctl, $daemon, $ws) = fresh_control(mode => 'connect',
        wanted   => { playing => 1, uri => $TID },
        observed => { wsConnected => 1, meta => {}, track => $TID, status => 'playing',
                      availableActions => { skip_next => 1 } });
    own_track($ctl->mac);

    $ctl->requestPause(1);
    $ctl->requestSkip('next');

    ok(!(grep { $_->[0] eq 'play' && exists $_->[1]{uri} } @{ $ws->sent }),
        "83.1-04 Task 2 Fall-7: no play with a uri reaches the wire on a jump +1 sequence");
    ok(!(grep { $_->[0] eq 'seek' } @{ $ws->sent }),
        "83.1-04 Task 2 Fall-7: no seek reaches the wire on a jump +1 sequence");
}

# --- 83.1-REVIEW.md CR-01: ownership guard -- connect mode but LMS is
# currently on a FOREIGN (non-spoton) song (e.g. a local file) --
# requestSkip('next') must not forward skip_next to the daemon; nothing
# sent, returns 0. Mirrors the _lmsSongIsOurs guard already used by
# requestPause/requestResume/requestVolume; without it LMS transport keys
# on a local playlist drove the Spotify account session via the daemon. ---
{
    my ($ctl, $daemon, $ws) = fresh_control(mode => 'connect',
        observed => { wsConnected => 1, meta => {}, availableActions => { skip_next => 1, skip_prev => 1 } });
    foreign_track($ctl->mac);

    my $rc = $ctl->requestSkip('next');

    is($rc, 0, "CR-01: requestSkip('next') on a foreign LMS song returns 0");
    is_deeply($ws->sent, [], "CR-01: requestSkip('next') on a foreign LMS song sends nothing");
}

# ============================================================
# Debug session connect-skip-prev-ton-bleibt (2026-09-24), user decision
# 1B -- DEVIATION from D-B2 for `jump +0`: "LMS decides". The LMS
# "previous" button more than 5 s into a title sends `jump +0`; in connect
# that is now a restart from 0 through the seek path, not a Spotify
# skip_prev. requestRestart grants a ONE-SHOT allowance for the current
# uri and asks LMS' StreamingController for jumpToTime(0, 1); inside that
# call LMS consults ProtocolHandler::canDoAction('rew'), which consumes the
# allowance (the stub's $ON_JUMP plays that part). The allowance never
# outlives the call. The daemon command (armed `seek 0`) then comes from
# the ordinary restart chain (onStream -> requestTrack seek=>1).
# ============================================================
my $RURL = 'spoton://track:11dFghVXANMlKmJXsNCbNl';    # LMS form of $TID

sub restart_rig {
    my (%given) = @_;
    my $mac = $given{mac};
    my ($ctl, $daemon, $ws) = fresh_control(
        mode     => ($given{mode} // 'connect'),
        mac      => $mac,
        observed => {
            wsConnected      => 1,
            meta             => (exists $given{meta} ? $given{meta} : { $TID => { duration => 200 } }),
            track            => (exists $given{track} ? $given{track} : $TID),
            status           => 'playing',
            availableActions => { skip_prev => 1, skip_next => 1, seek => 1 },
        },
    );
    my $client = Slim::Player::Client::getClient($mac);
    $client->playingSong(Test::MockSong->new(Test::MockTrack->new($given{lms_url} // $RURL)));
    my $controller = $client->controller;
    $controller->{paused}  = $given{paused}  // 0;
    $controller->{stopped} = $given{stopped} // 0;
    @Slim::Player::Client::_StubController::JUMPS = ();
    @IO::Socket::INET::REQUESTS = ();
    # Control holds its daemon WEAKLY -- the caller must keep $daemon alive
    # for the block, or every send finds no WS.
    return ($ctl, $ws, $daemon);
}

# --- 1B Fall-1 (the route): connect, LMS playing the daemon's title,
# seekable -> jumpToTime(0, 1) exactly once, canDoAction inside it sees
# the allowance, returns 1, nothing sent to the daemon by requestRestart
# itself (no skip_prev), allowance gone afterwards. ---
{
    my ($ctl, $ws, $daemon) = restart_rig(mac => 'aa:bb:cc:dd:1b:01');
    my @seen;
    local $Slim::Player::Client::_StubController::ON_JUMP = sub {
        push @seen, $ctl->consumeRestartAllowance($RURL);
    };

    my $rc = $ctl->requestRestart('jump+0');

    is($rc, 1, "1B Fall-1: requestRestart('jump+0') returns 1 when LMS took the restart");
    is_deeply(\@Slim::Player::Client::_StubController::JUMPS, [ [ 0, 1 ] ],
        "1B Fall-1: LMS asked for jumpToTime(0, 1) exactly once");
    is_deeply(\@seen, [ 1 ], "1B Fall-1: canDoAction inside the restart sees the allowance for this uri");
    is_deeply($ws->sent, [], "1B Fall-1: requestRestart itself sends nothing to the daemon -- no skip_prev");
    is($ctl->consumeRestartAllowance($RURL), 0, "1B Fall-1: the allowance does not outlive the call");
}

# --- 1B Fall-2 (chain end): the restart's onStream (rewind marker 0)
# reaches the connect seek row -> exactly one ARMED `seek 0`, no play, no
# skip_prev. ---
{
    my ($ctl, $ws, $daemon) = restart_rig(mac => 'aa:bb:cc:dd:1b:02');
    local $Slim::Player::Client::_StubController::ON_JUMP = sub {
        $ctl->noteSeekIntent($RURL, 0) if $ctl->consumeRestartAllowance($RURL);
    };
    $ctl->requestRestart('jump+0');
    my $marker = $ctl->consumeSeekIntent($RURL);
    is($marker, 0, "1B Fall-2: the restart left the rewind marker 0 for onStream");

    $ctl->requestTrack($RURL, $marker, { source => 'onStream', seek => 1 });

    is_deeply($ws->sent, [ [ 'seek', { position_ms => 0 } ] ],
        "1B Fall-2: onStream's restart -> exactly one `seek 0` on the wire, no play, no skip_prev");
    is(scalar(grep { ${ $_->{bufref} } =~ m{^POST /seek-arm} } @IO::Socket::INET::REQUESTS), 1,
        "1B Fall-2: the seek 0 is ARMED (one sync /seek-arm POST before it)");
}

# --- 1B Fall-3: LMS never consulted canDoAction (restart did not happen)
# -> returns 0 so the caller keeps the old skip_prev route; allowance
# cleared anyway. ---
{
    my ($ctl, $ws, $daemon) = restart_rig(mac => 'aa:bb:cc:dd:1b:03');
    local $Slim::Player::Client::_StubController::ON_JUMP;

    my $rc = $ctl->requestRestart('jump+0');

    is($rc, 0, "1B Fall-3: allowance never consumed -> requestRestart returns 0");
    is($ctl->consumeRestartAllowance($RURL), 0, "1B Fall-3: the unconsumed allowance is cleared, not left armed");
}

# --- 1B Fall-4..8: preconditions -- each returns 0 WITHOUT asking LMS. ---
my $precondition_no = 0;
for my $case (
    [ 'paused',            { paused => 1 } ],
    [ 'stopped',           { stopped => 1 } ],
    [ 'mode browse',       { mode => 'browse' } ],
    [ 'not seekable',      { meta => {} } ],
    [ 'daemon on another title', { track => 'spotify:track:otherTitle000000000000' } ],
) {
    my ($label, $given) = @$case;
    my $mac = sprintf('aa:bb:cc:dd:1c:%02x', ++$precondition_no);
    my ($ctl, $ws, $daemon) = restart_rig(mac => $mac, %$given);
    my $asked = 0;
    local $Slim::Player::Client::_StubController::ON_JUMP = sub { $asked++; $ctl->consumeRestartAllowance($RURL) };

    my $rc = $ctl->requestRestart('jump+0');

    is($rc, 0, "1B precondition ($label): requestRestart returns 0");
    is(scalar(@Slim::Player::Client::_StubController::JUMPS), 0, "1B precondition ($label): LMS is not asked to restart");
    is_deeply($ws->sent, [], "1B precondition ($label): nothing sent to the daemon");
    is($ctl->consumeRestartAllowance($RURL), 0, "1B precondition ($label): no allowance left behind");
}

# --- 1B Fall-9: consume for a DIFFERENT url during the restart -> denied,
# and the allowance is gone (read-and-clear, fail closed) -> 0. ---
{
    my ($ctl, $ws, $daemon) = restart_rig(mac => 'aa:bb:cc:dd:1b:09');
    my @seen;
    local $Slim::Player::Client::_StubController::ON_JUMP = sub {
        push @seen, $ctl->consumeRestartAllowance('spoton://track:otherTitle000000000000');
        push @seen, $ctl->consumeRestartAllowance($RURL);
    };

    my $rc = $ctl->requestRestart('jump+0');

    is_deeply(\@seen, [ 0, 0 ], "1B Fall-9: a mismatched consume denies AND clears the allowance");
    is($rc, 0, "1B Fall-9: requestRestart returns 0");
}

# --- 1B Fall-10: jumpToTime dies -> the error propagates, the allowance
# is still cleared (it can never leak into a later `time 0`). ---
{
    my ($ctl, $ws, $daemon) = restart_rig(mac => 'aa:bb:cc:dd:1b:0a');
    local $Slim::Player::Client::_StubController::ON_JUMP = sub { die "boom\n" };

    my $ok = eval { $ctl->requestRestart('jump+0'); 1 };

    ok(!$ok, "1B Fall-10: an exception inside LMS' restart propagates");
    is($ctl->consumeRestartAllowance($RURL), 0, "1B Fall-10: the allowance is cleared even on exception");
}

# ============================================================
# Debug session inaktiver-player-steuert-fern (2026-09-25), user decision A
# "Erst uebernehmen, dann spielen". Every daemon on the one Spotify account
# executes a state-changing command of a NON-active device as Connect
# REMOTE control against the active device (live 2026-09-24: 23:35:58
# seek 0 + resume, 23:37:09 play -> track change, 23:36:54 pause -- all on
# lavender-UAT2, sent by an inactive lavender-UAT). Fix: a KNOWN-inactive
# Control (observed.is_active defined and 0) takes the session over first
# (WS `activate`, measured 2026-09-25 M1/M5: confirmed by device_changed
# is_active:true, 0.6-0.9 s with another device active, ~1 ms with none;
# M6: an already-active daemon answers with command_result only), then
# plays; nothing else state-changing goes out while inactive; a mirrored
# track_changed is never an own echo; a browse player that loses the
# session stops in LMS (no ping-pong).
# ============================================================
my $IA_X = 'spotify:track:inaktivOwnXAAAAAAAAAAA';
my $IA_Z = 'spotify:track:inaktivOtherZBBBBBBBBB';

sub ia_cmds { return map { $_->[0] } @{ $_[0]->sent }; }

# --- IA-1 (symptom 23:37:09, mismatch): inactive, the account plays Z on
# another device -> requestTrack X sends `activate` and NO play; the
# transferred session's frame before the confirmation sends nothing; the
# confirmation is not a transfer-in; then exactly one `play X`; the own
# echo releases successCb ---
{
    local $Slim::Player::Source::PLAYMODE = 'play';
    local @Slim::Player::Playlist::ENTRIES = ();
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ef:01', mode => 'idle',
        observed => { wsConnected => 1, meta => { $IA_X => { duration => 200 } },
                      track => $IA_Z, status => 'playing', is_active => 0 },
    );
    my ($ok, $err) = (0, 0);
    $ctl->requestTrack($IA_X, 0, { successCb => sub { $ok++ }, errorCb => sub { $err++ }, source => 'getNextTrack' });

    my @cmds = ia_cmds($ws);
    is($cmds[0], 'activate', "IA-1: an INACTIVE Control's requestTrack first sends activate (take over)");
    ok(!grep({ /^(?:play|seek|pause|set_volume|add_to_queue)$/ } @cmds),
        "IA-1: nothing state-changing goes out before the take-over is confirmed (no remote play)");
    is($ok + $err, 0, "IA-1: getNextTrack's callback waits for the take-over");

    $ctl->onEvent({ type => 'track_changed', item => { uri => $IA_Z } });
    ok(!grep({ /^(?:play|seek|pause)$/ } ia_cmds($ws)),
        "IA-1: a frame of the transferred session before the confirmation sends nothing");

    $ctl->onEvent({ type => 'device_changed', is_active => 1, device_name => 'lavender-UAT' });
    is($ctl->mode, 'browse', "IA-1: the confirmation of our own take-over is not a transfer-in (mode stays browse)");
    is_deeply([ grep { $_->[0] eq 'play' } @{ $ws->sent } ], [ [ 'play', { uri => $IA_X } ] ],
        "IA-1: after the confirmation exactly one play uri=X goes out");

    $ctl->onEvent({ type => 'track_changed', item => { uri => $IA_X } });
    is($ok, 1, "IA-1: the own echo after the take-over releases successCb once");
    is($err, 0, "IA-1: no errorCb");
}

# --- IA-2 (symptom 23:35:58, Treffer): inactive, observed.track is the
# MIRRORED title X (paused at 48751 on the other device) -> requestTrack X
# sends no seek/play before the take-over; after the confirmation the stale
# transferred anchor is not trusted: seek 0 + bare play, successCb ---
{
    local $Slim::Player::Source::PLAYMODE = 'play';
    local @Slim::Player::Playlist::ENTRIES = ();
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ef:02', mode => 'idle',
        observed => { wsConnected => 1, meta => { $IA_X => { duration => 200 } },
                      track => $IA_X, status => 'paused', is_active => 0,
                      anchor => { position_ms => 48751, timestamp_ms => undef, speed => 0, seen_at => time() } },
    );
    my $ok = 0;
    $ctl->requestTrack($IA_X, 0, { successCb => sub { $ok++ }, source => 'getNextTrack' });

    ok(!grep({ /^(?:play|seek)$/ } ia_cmds($ws)),
        "IA-2: a mirrored hit on an INACTIVE daemon sends no seek/play (was: remote seek 0 + resume)");
    is($ok, 0, "IA-2: successCb waits for the take-over");

    # the transferred session reports position 0 although it starts at 48751 (M1)
    $ctl->onEvent({ type => 'playback_state', status => 'paused', is_active => JSON::PP::false(),
                    item => { uri => $IA_X }, position => { position_ms => 0, timestamp_ms => 0, speed => 0 } });
    $ctl->onEvent({ type => 'device_changed', is_active => 1, device_name => 'lavender-UAT' });

    my @after = grep { $_->[0] eq 'seek' || $_->[0] eq 'play' } @{ $ws->sent };
    is_deeply(\@after, [ [ 'seek', { position_ms => 0 } ], [ 'play', {} ] ],
        "IA-2: after the take-over: seek 0 (stale transferred anchor not trusted) + bare play, both local");
    is($ok, 1, "IA-2: successCb released after the local resume");
}

# --- IA-3: the take-over is never confirmed -> errorCb once, errors[]
# entry `takeover`, and still nothing state-changing on the wire ---
{
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ef:03', mode => 'idle',
        observed => { wsConnected => 1, meta => { $IA_X => { duration => 200 } }, track => $IA_Z, status => 'playing', is_active => 0 },
    );
    my ($ok, @err) = (0);
    $ctl->requestTrack($IA_X, 0, { successCb => sub { $ok++ }, errorCb => sub { push @err, [@_] }, source => 'getNextTrack' });

    Slim::Utils::Timers::fire_due(Time::HiRes::time() + 10);

    is(scalar(@err), 1, "IA-3: an unconfirmed take-over fails getNextTrack exactly once");
    is($err[0][0], 'PROBLEM_OPENING', "IA-3: ... with PROBLEM_OPENING");
    is($ok, 0, "IA-3: no successCb for a take-over that never happened");
    my @mine = grep { ($_->[3] // '') eq $daemon->mac . ':takeover' } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@mine), 1, "IA-3: the failed take-over is visible in errors[] (key <mac>:takeover)");
    ok(!grep({ /^(?:play|seek|pause)$/ } ia_cmds($ws)), "IA-3: nothing state-changing was sent at all");
}

# --- IA-4 (M6): Control's is_active is stale 0 but the daemon IS active --
# `activate` then brings no device_changed; the auth_state answer to the
# probe sent with it (is_active true) completes the take-over ---
{
    local $Slim::Player::Source::PLAYMODE = 'play';
    local @Slim::Player::Playlist::ENTRIES = ();
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ef:04', mode => 'idle',
        observed => { wsConnected => 1, paired => 1, meta => { $IA_X => { duration => 200 } }, track => $IA_Z, status => 'paused', is_active => 0 },
    );
    $ctl->requestTrack($IA_X, 0, { successCb => sub { }, source => 'getNextTrack' });
    my @cmds = ia_cmds($ws);
    is_deeply([ @cmds[0, 1] ], [ 'activate', 'get_auth_state' ],
        "IA-4: activate is followed by a read-only get_auth_state probe");

    $ctl->onEvent({ type => 'auth_state', logged_in => JSON::PP::true(), is_active => JSON::PP::true(), device_name => 'lavender-UAT' });
    is_deeply([ grep { $_->[0] eq 'play' } @{ $ws->sent } ], [ [ 'play', { uri => $IA_X } ] ],
        "IA-4: an auth_state reporting is_active completes the take-over -> play uri=X");
}

# --- IA-5: the send gate -- pause (LMS stop), resume and volume on an
# INACTIVE browse Control send nothing (were: remote pause/resume/volume
# on the active device); Gegenprobe: the same pause on an ACTIVE Control
# still goes out ---
{
    local $Slim::Player::Source::PLAYMODE = 'stop';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ef:05', mode => 'browse',
        wanted => { uri => $IA_X, playing => 1 },
        observed => { wsConnected => 1, meta => {}, track => $IA_Z, status => 'playing', is_active => 0 },
    );
    $ctl->requestPause(1);
    is_deeply($ws->sent, [], "IA-5: LMS stop on an INACTIVE player sends no pause (was: remote pause, 23:36:54)");
}
{
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ef:06', mode => 'browse',
        wanted => { uri => $IA_X, playing => 0 },
        observed => { wsConnected => 1, meta => {}, track => $IA_Z, status => 'paused', is_active => 0, volume => 50 },
    );
    $ctl->requestResume;
    is_deeply($ws->sent, [], "IA-5: LMS unpause on an INACTIVE player sends no play (was: remote resume)");
    $ctl->requestVolume(30);
    is_deeply($ws->sent, [], "IA-5: LMS volume on an INACTIVE player sends no set_volume (was: remote volume)");
}
{
    local $Slim::Player::Source::PLAYMODE = 'stop';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ef:07', mode => 'browse',
        wanted => { uri => $IA_X, playing => 1 },
        observed => { wsConnected => 1, meta => {}, track => $IA_X, status => 'playing', is_active => 1 },
    );
    $ctl->requestPause(1);
    is_deeply($ws->sent, [ [ 'pause', {} ] ], "IA-5 Gegenprobe: LMS stop on the ACTIVE player still pauses its daemon");
}

# --- IA-6: a MIRRORED track_changed is never the echo of our own play --
# own play X pending, the account moves to another device, that device's
# track_changed X arrives here: no successCb from it, no echo follow-ups
# (postSeek/prefetch/volume) on the wire ---
{
    local $Slim::Player::Source::PLAYMODE = 'play';
    local @Slim::Player::Playlist::ENTRIES = ();
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ef:08', mode => 'browse',
        observed => { wsConnected => 1, meta => { $IA_X => { duration => 200 } }, track => $IA_Z, status => 'playing', is_active => 1 },
    );
    my $ok = 0;
    $ctl->requestTrack($IA_X, 0, { successCb => sub { $ok++ }, source => 'getNextTrack' });
    is($ctl->pending && $ctl->pending->{uri}, $IA_X, "IA-6 setup: own play X pending on the ACTIVE daemon");

    $ctl->onEvent({ type => 'device_changed', is_active => 0, device_name => 'lavender-UAT' });
    @{ $ws->sent } = ();
    $ctl->onEvent({ type => 'track_changed', item => { uri => $IA_X } });

    is($ok, 0, "IA-6: a mirrored track_changed on an INACTIVE daemon is not taken as the own echo");
    is_deeply($ws->sent, [], "IA-6: ... and triggers no echo follow-up command");
}

# --- IA-7: a browse player that LOSES the session to another device stops
# in LMS (no ping-pong: a still-playing LMS would re-request and take the
# session back); Gegenproben: LMS already paused, or LMS on a foreign title
# -> no stop ---
{
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ef:09', mode => 'browse',
        wanted => { uri => $IA_X, playing => 1 },
        observed => { wsConnected => 1, meta => {}, track => $IA_X, status => 'playing', is_active => 1 },
    );
    own_track('aa:bb:cc:dd:ef:09', 'spoton://track:inaktivOwnXAAAAAAAAAAA');
    @Slim::Player::Client::EXECUTED = ();
    $ctl->onEvent({ type => 'device_changed', is_active => 0, device_name => 'lavender-UAT' });
    is_deeply(\@Slim::Player::Client::EXECUTED, [ [ 'stop' ] ],
        "IA-7: losing the session in browse while LMS plays our title stops LMS");
    is_deeply($ws->sent, [], "IA-7: ... and sends nothing to the daemon");
    is($ctl->observed->{is_active}, 0, "IA-7: observed.is_active is 0");
}
{
    local $Slim::Player::Source::PLAYMODE = 'pause';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ef:0a', mode => 'browse',
        wanted => { uri => $IA_X, playing => 0 },
        observed => { wsConnected => 1, meta => {}, track => $IA_X, status => 'paused', is_active => 1 },
    );
    own_track('aa:bb:cc:dd:ef:0a', 'spoton://track:inaktivOwnXAAAAAAAAAAA');
    @Slim::Player::Client::EXECUTED = ();
    $ctl->onEvent({ type => 'device_changed', is_active => 0, device_name => 'lavender-UAT' });
    is_deeply(\@Slim::Player::Client::EXECUTED, [], "IA-7 Gegenprobe: LMS already paused -> no stop");
}
{
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ef:0b', mode => 'browse',
        wanted => { uri => $IA_X, playing => 1 },
        observed => { wsConnected => 1, meta => {}, track => $IA_X, status => 'playing', is_active => 1 },
    );
    foreign_track('aa:bb:cc:dd:ef:0b');
    @Slim::Player::Client::EXECUTED = ();
    $ctl->onEvent({ type => 'device_changed', is_active => 0, device_name => 'lavender-UAT' });
    is_deeply(\@Slim::Player::Client::EXECUTED, [], "IA-7 Gegenprobe: LMS on a foreign title -> no stop");
}

# --- IA-7r/IA-7c (ordering guards): the LMS stop/pause a lost session
# causes can re-enter requestPause synchronously (LMS notification). That
# pause must meet the send gate -- is_active is cleared BEFORE the LMS
# command, in browse (the new stop) and in connect (the GH #151 stop
# 'inactive' emission) -- or it would pause the device that just took the
# session. The client stub's execute re-enters here the way LMS would. ---
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ef:10', mode => 'browse',
        wanted => { uri => $IA_X, playing => 1 },
        observed => { wsConnected => 1, meta => {}, track => $IA_X, status => 'playing', is_active => 1 },
    );
    own_track('aa:bb:cc:dd:ef:10', 'spoton://track:inaktivOwnXAAAAAAAAAAA');
    local $Slim::Player::Source::PLAYMODE = 'play';
    no warnings 'redefine';
    local *Slim::Player::Client::Recorder::execute = sub {
        my ($client, $req) = @_;
        push @Slim::Player::Client::EXECUTED, $req;
        if (($req->[0] // '') eq 'stop') {
            $Slim::Player::Source::PLAYMODE = 'stop';
            $ctl->requestPause(1);
        }
    };
    $ctl->onEvent({ type => 'device_changed', is_active => 0, device_name => 'lavender-UAT' });
    is_deeply($ws->sent, [], "IA-7r: the re-entrant stop after a browse loss sends no pause to the daemon");
}
{
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ef:11', mode => 'connect',
        wanted => { uri => $IA_X, playing => 1 },
        observed => { wsConnected => 1, meta => {}, track => $IA_X, status => 'playing', is_active => 1, startEmittedFor => $IA_X },
    );
    own_track('aa:bb:cc:dd:ef:11', 'spoton://track:inaktivOwnXAAAAAAAAAAA');
    local $Slim::Player::Source::PLAYMODE = 'play';
    no warnings 'redefine';
    local *Slim::Player::Client::Recorder::execute = sub {
        my ($client, $req) = @_;
        push @Slim::Player::Client::EXECUTED, $req;
        if (($req->[0] // '') eq 'spottyconnect' && ($req->[1] // '') eq 'stop') {
            $Slim::Player::Source::PLAYMODE = 'pause';
            $ctl->requestPause(0);
        }
    };
    $ctl->onEvent({ type => 'device_changed', is_active => 0, device_name => 'lavender-UAT' });
    is_deeply($ws->sent, [], "IA-7c: the re-entrant pause after a connect loss (stop 'inactive') sends no pause to the daemon");
}

# --- IA-8: LMS stop DURING the take-over -- nothing on the wire while
# inactive; once the take-over is confirmed the stop is honoured locally
# (the transferred session must not keep playing unattended) ---
{
    local @Slim::Player::Playlist::ENTRIES = ();
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ef:0c', mode => 'idle',
        observed => { wsConnected => 1, meta => { $IA_X => { duration => 200 } }, track => $IA_Z, status => 'playing', is_active => 0 },
    );
    {
        local $Slim::Player::Source::PLAYMODE = 'play';
        $ctl->requestTrack($IA_X, 0, { successCb => sub { }, source => 'getNextTrack' });
    }
    {
        local $Slim::Player::Source::PLAYMODE = 'stop';
        $ctl->requestPause(1);
    }
    ok(!grep({ /^(?:play|seek|pause)$/ } ia_cmds($ws)),
        "IA-8: a stop during the take-over sends nothing while still inactive");

    $ctl->onEvent({ type => 'device_changed', is_active => 1, device_name => 'lavender-UAT' });
    $ctl->onEvent({ type => 'track_changed', item => { uri => $IA_X } });
    my @cmds = ia_cmds($ws);
    is($cmds[-1], 'pause', "IA-8: after the confirmation the stop is honoured locally (last command pause)");
}

# --- IA-9 Gegenproben: is_active UNKNOWN (fresh Control, no frame yet) or
# ACTIVE -> requestTrack plays directly, no activate (the own-activation
# cold start of 82-17 stays untouched) ---
{
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ef:0d', observed => { wsConnected => 1, meta => { $IA_X => { duration => 200 } } },
    );
    $ctl->requestTrack($IA_X, 0, { successCb => sub { } });
    is_deeply([ ia_cmds($ws) ], [ 'play' ], "IA-9 Gegenprobe: is_active unknown -> play directly, no activate");
}
{
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ef:0e', mode => 'browse',
        observed => { wsConnected => 1, meta => { $IA_X => { duration => 200 } }, track => $IA_Z, status => 'playing', is_active => 1 },
    );
    $ctl->requestTrack($IA_X, 0, { successCb => sub { } });
    is_deeply([ ia_cmds($ws) ], [ 'play' ], "IA-9 Gegenprobe: ACTIVE -> play directly, no activate");
}

# --- IA-10: a daemon error during the take-over releases it: errorCb once,
# and a later confirmation plays nothing ---
{
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ef:0f', mode => 'idle',
        observed => { wsConnected => 1, meta => { $IA_X => { duration => 200 } }, track => $IA_Z, status => 'playing', is_active => 0 },
    );
    my $err = 0;
    $ctl->requestTrack($IA_X, 0, { successCb => sub { }, errorCb => sub { $err++ }, source => 'getNextTrack' });
    $ctl->onEvent({ type => 'error', message => 'activate failed' });
    is($err, 1, "IA-10: a daemon error during the take-over fails the request once");
    $ctl->onEvent({ type => 'device_changed', is_active => 1, device_name => 'lavender-UAT' });
    ok(!grep({ $_ eq 'play' } ia_cmds($ws)), "IA-10: no play was sent, not even after a late confirmation");
    is($err, 1, "IA-10: errorCb still fired exactly once");
}

# --- IA-11: the H6-Ersatz volume push (idle -> browse) is not lost to the
# send gate -- held while the take-over is in flight, applied after it ---
{
    local $Slim::Player::Source::PLAYMODE = 'play';
    local @Slim::Player::Playlist::ENTRIES = ();
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ef:12', mode => 'idle',
        observed => { wsConnected => 1, meta => { $IA_X => { duration => 200 } }, track => $IA_Z, status => 'playing', is_active => 0, volume => 80 },
    );
    Slim::Player::Client::getClient('aa:bb:cc:dd:ef:12')->volume(40);
    $ctl->requestTrack($IA_X, 0, { successCb => sub { }, source => 'getNextTrack' });
    ok(!grep({ $_ eq 'set_volume' } ia_cmds($ws)), "IA-11: no set_volume while still inactive");

    $ctl->onEvent({ type => 'device_changed', is_active => 1, device_name => 'lavender-UAT' });
    $ctl->onEvent({ type => 'track_changed', item => { uri => $IA_X } });
    is_deeply([ grep { $_->[0] eq 'set_volume' } @{ $ws->sent } ], [ [ 'set_volume', { volume => 40 } ] ],
        "IA-11: LMS' volume is pushed once the take-over is confirmed");
}

# --- IA-12: LMS left the title while the take-over was in flight
# (leaveBrowse, e.g. a stop on a foreign title) -> the confirmation plays
# nothing, the caller is released, and the transferred session is paused
# locally (it would otherwise play here unattended, M1) ---
{
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ef:13', mode => 'idle',
        observed => { wsConnected => 1, meta => { $IA_X => { duration => 200 } }, track => $IA_Z, status => 'playing', is_active => 0 },
    );
    my @err;
    $ctl->requestTrack($IA_X, 0, { successCb => sub { }, errorCb => sub { push @err, [@_] }, source => 'getNextTrack' });
    $ctl->leaveBrowse;
    $ctl->onEvent({ type => 'device_changed', is_active => 1, device_name => 'lavender-UAT' });

    ok(!grep({ $_ eq 'play' } ia_cmds($ws)), "IA-12: nothing is played for a title LMS no longer wants");
    is(scalar(@err), 1, "IA-12: the waiting caller is released once");
    is((ia_cmds($ws))[-1], 'pause', "IA-12: the transferred session is paused locally");
}

# --- IA-13: a second requestTrack during the take-over sends no second
# activate; a DIFFERENT title supersedes the first caller, and the
# confirmation plays the newest title ---
{
    local $Slim::Player::Source::PLAYMODE = 'play';
    local @Slim::Player::Playlist::ENTRIES = ();
    my $IA_Y = 'spotify:track:inaktivNewerYCCCCCCCCC';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac => 'aa:bb:cc:dd:ef:14', mode => 'idle',
        observed => { wsConnected => 1, meta => { $IA_X => { duration => 200 }, $IA_Y => { duration => 200 } },
                      track => $IA_Z, status => 'playing', is_active => 0 },
    );
    my (@err1, $ok2);
    $ctl->requestTrack($IA_X, 0, { successCb => sub { }, errorCb => sub { push @err1, [@_] }, source => 'getNextTrack' });
    $ctl->requestTrack($IA_Y, 0, { successCb => sub { $ok2++ }, source => 'getNextTrack' });

    is(scalar(grep { $_ eq 'activate' } ia_cmds($ws)), 1, "IA-13: one take-over, one activate");
    is_deeply(\@err1, [ [ 'PROBLEM_OPENING', 'superseded' ] ], "IA-13: the earlier title's caller is superseded");

    $ctl->onEvent({ type => 'device_changed', is_active => 1, device_name => 'lavender-UAT' });
    is_deeply([ grep { $_->[0] eq 'play' } @{ $ws->sent } ], [ [ 'play', { uri => $IA_Y } ] ],
        "IA-13: the confirmation plays the newest title only");
    $ctl->onEvent({ type => 'track_changed', item => { uri => $IA_Y } });
    is($ok2, 1, "IA-13: the newest caller's successCb fires on its echo");
}

# --- 84.1 plan 03 (D-04): _onFrameAuthState stamps observed->{authStateAt}
# so DaemonManager's health tick can tell "the daemon answered our
# get_auth_state probe" apart from onEvent's own lastEventAt (refreshed by
# every frame, ticker frames included). ---
{
    my ($ctl, $daemon, $ws) = fresh_control();
    $ctl->onEvent(decode_frame(load_fixture('auth_state.json')));
    ok(defined $ctl->observed->{authStateAt}, "84.1-03: authStateAt is stamped by auth_state");
    ok(Time::HiRes::time() - $ctl->observed->{authStateAt} < 2,
        "84.1-03: authStateAt is a fresh Time::HiRes timestamp");
}

# ============================================================
# 84.1-02 Task 1 (D-01(b)/D-03): stop-triggered leaveBrowse -- an LMS stop
# of our own browse title ends SpotOn's browse mode (re-entry is
# requestTrack, Prinzip 3.1(4); leaveBrowse itself sends no command) -- and
# the criterion-3 guard on _ownActivationAt, extended with $lmsPlaysOurs
# (84.1 D-03): observed.track == wanted.uri is only an echo of our OWN
# activation while LMS is actually playing our material; after a stop the
# daemon is still parked on the title, and a device_changed(is_active:1)
# then is the app's transfer, not an echo. Cases A1-A5 below; A2 exercises
# _ownActivationAt directly (pure function, no clock, D-03). Branch R
# (scenario (a) reproduced pre-fix, per 84.1-CLUSTER1-VERDICTS.md Summary).
# ============================================================

# _84102_a1_state($mac) -- shared setup for A1/A3/A4/A4b: browse, own
# track X, LMS stops (playmode 'stop'), requestPause(1) -- the exact
# sequence A1 itself pins. Returns the post-stop state every other case
# continues from.
sub _84102_a1_state {
    my ($mac) = @_;
    my $X = 'spotify:track:84102A1ownBrowseXXXXXX';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => $mac,
        mode     => 'browse',
        observed => { wsConnected => 1, paired => 1, meta => {}, track => $X, status => 'playing',
                      anchor => { position_ms => 45000 } },
        wanted   => { uri => $X, playing => 1 },
    );
    own_track($mac, 'spoton://track:84102a1ownedXXXXXXX');
    {
        local $Slim::Player::Source::PLAYMODE = 'stop';
        $ctl->requestPause(1);
    }
    return ($ctl, $daemon, $ws, $X);
}

# --- 84.1-02 A1: LMS stop of our own browse title -- pause dispatched,
# then D-01(b) leaves browse (leftBrowseUri keeps the autoplay guard
# armed for this title) ---
{
    my ($ctl, $daemon, $ws, $X) = _84102_a1_state('aa:84:01:02:00:01');

    is_deeply($ws->sent->[-1], [ 'pause', {} ], "84.1-02 A1: pause reaches the daemon");
    is($ctl->mode, 'idle', "84.1-02 A1: LMS stop of our browse title leaves browse -- mode idle");
    is_deeply($ctl->wanted, {}, "84.1-02 A1: wanted cleared by leaveBrowse");
    is($ctl->observed->{leftBrowseUri}, $X, "84.1-02 A1: leftBrowseUri records the title we left");
}

# --- 84.1-02 A2: _ownActivationAt criterion (3) direct -- pure function,
# no clock (D-03): fires only while LMS is actually playing our material
# (lmsPlaysOurs) ---
{
    my $trackUri = 'spotify:track:84102A2critThreeXXXXXX';
    my $wanted   = { uri => $trackUri };
    my $observed = { track => $trackUri };
    is(Plugins::SpotOn::Soloist::Control::_ownActivationAt(
            $wanted, $observed, undef, 'browse', Time::HiRes::time(), 0),
        0, "84.1-02 A2: criterion 3 does not fire when LMS is not playing our material (lmsPlaysOurs=0)");
    is(Plugins::SpotOn::Soloist::Control::_ownActivationAt(
            $wanted, $observed, undef, 'browse', Time::HiRes::time(), 1),
        1, "84.1-02 A2: criterion 3 fires when LMS is actually playing our material (lmsPlaysOurs=1)");
}

# --- 84.1-02 A3: after A1's stop-leave, a same-title app transfer starts
# a real Connect session at the app's position (D-03) -- the daemon is
# still parked on X, but LMS is stopped, so criterion 3 no longer reads
# this as our own echo ---
{
    my ($ctl, $daemon, $ws, $X) = _84102_a1_state('aa:84:01:02:00:03');
    @Slim::Player::Client::EXECUTED = ();

    $ctl->onEvent({ type => 'device_changed', is_active => 1, device_name => 'lavender-UAT' });

    is($ctl->mode, 'connect', "84.1-02 A3: the same-title transfer is recognized (mode=connect)");
    is($ctl->wanted->{uri}, $X, "84.1-02 A3: wanted.uri is the transferred title");
    is($ctl->wanted->{position_ms}, 45000, "84.1-02 A3: wanted.position_ms comes from the anchor (app's position)");
    ok((grep { $_->[0] eq 'bind' && $_->[1] eq $daemon->mac && $_->[2] eq 'transfer' } @Plugins::SpotOn::Connect::CLAIMS),
        "84.1-02 A3: the Connect claim is bound with source=transfer");
    ok((grep { $_->[0] eq 'spottyconnect' && $_->[1] eq 'start' } @Slim::Player::Client::EXECUTED),
        "84.1-02 A3: a spottyconnect start is emitted");
    is($ctl->observed->{leftBrowseUri}, undef, "84.1-02 A3: leftBrowseUri is cleared on the transfer-in");
}

# --- 84.1-02 A4: after A1's stop-leave, the autoplay guard stays armed in
# idle (keyed on leftBrowseUri) -- an unrequested foreign track_changed is
# still paused and recorded ---
{
    my ($ctl, $daemon, $ws, $X) = _84102_a1_state('aa:84:01:02:00:04');
    $ctl->observed->{is_active} = 1;
    @{ $ws->sent } = ();

    my $Z = 'spotify:track:84102A4foreignZXXXXXX';
    $ctl->onEvent({ type => 'track_changed', item => { uri => $Z } });

    is_deeply($ws->sent, [ [ 'pause', {} ] ],
        "84.1-02 A4: the autoplay guard fires in idle after a stop-triggered leaveBrowse (leftBrowseUri armed)");
    my @mine = grep { ($_->[3] // '') eq $daemon->mac . ':autoplay:' . $Z } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@mine), 1, "84.1-02 A4: exactly one autoplay:<uri> ring entry recorded");
}

# --- 84.1-02 A4b: after a transfer-in (A3), the SAME foreign frame
# produces no pause -- the marker is cleared, and mode=connect is outside
# the guard's scope anyway ---
{
    my ($ctl, $daemon, $ws, $X) = _84102_a1_state('aa:84:01:02:00:4b');
    $ctl->onEvent({ type => 'device_changed', is_active => 1, device_name => 'lavender-UAT' });
    is($ctl->mode, 'connect', "84.1-02 A4b setup: transfer-in landed");
    @{ $ws->sent } = ();

    my $Z = 'spotify:track:84102A4bforeignZXXXXX';
    $ctl->onEvent({ type => 'track_changed', item => { uri => $Z } });

    is_deeply($ws->sent, [], "84.1-02 A4b: no pause after a transfer-in -- the guard no longer applies");
}

# --- 84.1-02 A5: an LMS stop in connect mode stays a session pause -- the
# D-01 clarification (browse-only stop trigger, locked 2026-09-27, user) ---
{
    my $mac = 'aa:84:01:02:00:05';
    my $Y   = 'spotify:track:84102A5connectYXXXXXX';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => $mac,
        mode     => 'connect',
        wanted   => { uri => $Y, playing => 1 },
        observed => { wsConnected => 1, track => $Y, status => 'playing', is_active => 1 },
    );
    own_track($mac, 'spoton://track:84102a5ownedXXXXXXX');

    local $Slim::Player::Source::PLAYMODE = 'stop';
    $ctl->requestPause(1);

    is($ctl->mode, 'connect', "84.1-02 A5: LMS stop in connect stays a session pause -- mode unchanged");
}

# ============================================================
# 84.1-02 Task 2 (D-01(a), unconditional -- NOT gated by plan 01's
# verdict, CONTEXT states the gap as a code fact): losing the Spotify
# session in browse (device_changed is_active:0) leaves browse mode in
# BOTH LMS states -- playing (LMS is stopped as before, then leaveBrowse)
# and paused (no stop, as before, but leaveBrowse still fires). The
# connect half is untouched (83.1-02 Task 1 Fall-2 already pins mode idle
# there -- A10 adds one line next to it instead of a new block).
# ============================================================

# --- 84.1-02 A8: session loss in browse while LMS plays our title -- LMS
# is still stopped (unchanged, playmode-gated) AND browse mode is left ---
{
    local $Slim::Player::Source::PLAYMODE = 'play';
    my $mac = 'aa:84:01:02:00:08';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => $mac,
        mode     => 'browse',
        wanted   => { uri => $IA_X, playing => 1 },
        observed => { wsConnected => 1, meta => {}, track => $IA_X, status => 'playing', is_active => 1 },
    );
    own_track($mac, 'spoton://track:84102a8ownedXXXXXXXX');
    @Slim::Player::Client::EXECUTED = ();

    $ctl->onEvent({ type => 'device_changed', is_active => 0, device_name => 'lavender-UAT' });

    is_deeply(\@Slim::Player::Client::EXECUTED, [ [ 'stop' ] ],
        "84.1-02 A8: LMS is still stopped when it plays our title (unchanged)");
    is($ctl->mode, 'idle', "84.1-02 A8: session loss leaves browse -- mode idle");
    is_deeply($ctl->wanted, {}, "84.1-02 A8: wanted cleared by leaveBrowse");
    is_deeply($ws->sent, [], "84.1-02 A8: nothing sent to the daemon");
}

# --- 84.1-02 A9: session loss in browse while LMS is only paused -- no
# stop (decision A of inaktiver-player-steuert-fern unchanged), but
# browse mode is STILL left (D-01(a) applies to both LMS states) ---
{
    local $Slim::Player::Source::PLAYMODE = 'pause';
    my $mac = 'aa:84:01:02:00:09';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => $mac,
        mode     => 'browse',
        wanted   => { uri => $IA_X, playing => 0 },
        observed => { wsConnected => 1, meta => {}, track => $IA_X, status => 'paused', is_active => 1 },
    );
    own_track($mac, 'spoton://track:84102a9ownedXXXXXXXX');
    @Slim::Player::Client::EXECUTED = ();

    $ctl->onEvent({ type => 'device_changed', is_active => 0, device_name => 'lavender-UAT' });

    is_deeply(\@Slim::Player::Client::EXECUTED, [], "84.1-02 A9: LMS paused -- no stop (decision A unchanged)");
    is($ctl->mode, 'idle', "84.1-02 A9: session loss leaves browse even though LMS was only paused");
    is_deeply($ctl->wanted, {}, "84.1-02 A9: wanted cleared by leaveBrowse");
    is_deeply($ws->sent, [], "84.1-02 A9: nothing sent to the daemon");
}

# ============================================================
# 84.1-07 (D-02): foreign LMS content arriving while Control is in a
# Connect session ends the session cleanly. leaveConnect (Control.pm)
# releases the claim, cancels the watchdog, resets state to idle/{},
# then sends exactly one self-scoped `deactivate` probe -- the ONLY
# wire effect (84.1-02-PLAN.md:30/:70). Triggered by Connect.pm
# _onNewSong's url-class guard (Task 1 Step 3; t/41/t/37 in Task 2 pin
# the trigger and its edges against the real code).
# ============================================================

# _d02_setup($mac) -- a Control mid Connect session, watchdog armed,
# ready for leaveConnect. Shared by every 84.1-07 case below so each
# case can build its OWN fresh state (never chained off another case's
# Control -- Task 1 Step 1's independence requirement for A6c/A6d).
sub _d02_setup {
    my ($mac) = @_;
    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => $mac,
        mode     => 'connect',
        wanted   => { uri => $TID, playing => 1 },
        observed => {
            wsConnected => 1, meta => {}, track => $TID, status => 'playing',
            is_active   => 1, startEmittedFor => $TID,
        },
    );
    $ctl->_armConnectWatchdog($TID);
    return ($ctl, $daemon, $ws);
}

# --- 84.1-07 A6: order (claim release before any send), the wire
# (ws->sent holds exactly one entry: deactivate, sent only once mode is
# already idle and startEmittedFor already cleared), and the echo
# (foreign content untouched) ---
{
    @Plugins::SpotOn::Connect::CLAIMS = (); $Plugins::SpotOn::Connect::ACTIVE = undef;
    @Slim::Player::Client::EXECUTED   = ();
    my $mac = 'aa:84:07:00:00:06';
    my ($ctl, $daemon, $ws) = _d02_setup($mac);
    ok((grep { $_->[0] == $ctl && $_->[2] == \&Plugins::SpotOn::Soloist::Control::_watchdogRound2 }
        @Slim::Utils::Timers::TIMERS),
        "84.1-07 A6 setup: connect watchdog armed");

    local $Slim::Player::Source::PLAYMODE = 'play';
    foreign_track($mac, 'http://radio.example/1live.mp3');

    my $sentAtRelease;
    my @sendOrder;
    my $orig_release = \&Plugins::SpotOn::Connect::releaseConnectClaim;
    my $orig_send    = \&Test::FakeWs::sendCommand;
    my $ok;
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Connect::releaseConnectClaim = sub {
            $sentAtRelease = scalar(@{ $ws->sent });
            goto &$orig_release;
        };
        local *Test::FakeWs::sendCommand = sub {
            my ($self, $cmd, %p) = @_;
            push @sendOrder, [ $cmd, $ctl->mode, defined($ctl->observed->{startEmittedFor}) ? 1 : 0 ];
            goto &$orig_send;
        };
        $ok = eval { $ctl->leaveConnect('foreign-lms-content'); 1 };
    }
    ok($ok, "84.1-07 A6: leaveConnect callable");

    is($ctl->mode, 'idle', "84.1-07 A6: mode idle after leaveConnect");
    is_deeply($ctl->wanted, {}, "84.1-07 A6: wanted cleared");
    ok(!defined($ctl->observed->{startEmittedFor}), "84.1-07 A6: startEmittedFor cleared");
    ok(!exists($ctl->observed->{connectWatchdog}), "84.1-07 A6: connectWatchdog record gone");
    ok(!(grep { $_->[0] == $ctl && $_->[2] == \&Plugins::SpotOn::Soloist::Control::_watchdogRound2 }
        @Slim::Utils::Timers::TIMERS),
        "84.1-07 A6: no _watchdogRound2 timer left for this Control");

    is(scalar(@Plugins::SpotOn::Connect::CLAIMS), 1, "84.1-07 A6: exactly one claim call recorded");
    is_deeply($Plugins::SpotOn::Connect::CLAIMS[0], [ 'release', $mac, 'foreign-lms-content', 0 ],
        "84.1-07 A6: [ 'release', mac, 'foreign-lms-content', 0 ]");
    is($sentAtRelease, 0, "84.1-07 A6: at release time the FakeWs had sent nothing");

    is(scalar(@{ $ws->sent }), 1, "84.1-07 A6: ws->sent holds exactly one entry");
    is($ws->sent->[0][0], 'deactivate', "84.1-07 A6: the one entry is deactivate");
    is(scalar(@sendOrder), 1, "84.1-07 A6: exactly one sendCommand call recorded");
    is($sendOrder[0][0], 'deactivate', "84.1-07 A6: the recorded send is deactivate");
    is($sendOrder[0][1], 'idle', "84.1-07 A6: mode was already idle when deactivate was sent");
    is($sendOrder[0][2], 0, "84.1-07 A6: startEmittedFor was already undef when deactivate was sent");

    is_deeply(\@Slim::Player::Client::EXECUTED, [], "84.1-07 A6: no LMS execute -- foreign content untouched");

    # --- 84.1-07 A6b (tap-back, per D-02): from A6's end state, with
    # CLAIMS and EXECUTED reset and LMS STILL playing the foreign
    # stream (the tap is a deliberate user action and must win over the
    # guard) ---
    $ctl->onEvent({ type => 'device_changed', is_active => 0, device_name => 'lavender-UAT' });
    is_deeply(\@Slim::Player::Client::EXECUTED, [], "84.1-07 A6: echo -- EXECUTED still empty (no LMS pause/stop)");
    is($ctl->mode, 'idle', "84.1-07 A6: echo -- mode stays idle");
    is($ctl->observed->{is_active}, 0, "84.1-07 A6: echo -- observed.is_active is 0");

    @Plugins::SpotOn::Connect::CLAIMS = ();
    @Slim::Player::Client::EXECUTED   = ();

    $ctl->onEvent(decode_frame(load_fixture('device_changed.json')));

    is($ctl->mode, 'connect', "84.1-07 A6b: tap-back -- mode connect");
    is(scalar(@Plugins::SpotOn::Connect::CLAIMS), 1, "84.1-07 A6b: exactly one claim call");
    is_deeply($Plugins::SpotOn::Connect::CLAIMS[0], [ 'bind', $mac, 'transfer', 0 ],
        "84.1-07 A6b: [ 'bind', mac, 'transfer', 0 ]");
    is(scalar(@Slim::Player::Client::EXECUTED), 1, "84.1-07 A6b: exactly one spottyconnect execute");
    is($Slim::Player::Client::EXECUTED[0][1], 'start',
        "84.1-07 A6b: the one execute is 'start', not 'resume' -- startEmittedFor was cleared");
    ok(!exists($ctl->observed->{leftConnectForeign}),
        "84.1-07 A6b: leftConnectForeign does not exist -- the transfer-in ended the post-leave episode");
}

# ============================================================
# 84-01 L2 (D-18, release blocker) -- a surviving startEmittedFor is only a
# reactivation while LMS still holds THAT session's track.
#
# Mechanism (frozen window 2026-09-29 10:55:04.32, 02:00:00:5a:11:03;
# server-260929.log via extract-run.pl): Control was in mode=idle (the G4
# lines read `mode=idle`), yet `observed->{startEmittedFor}` still held a
# previous session's marker (only leaveConnect and a fresh Control clear it --
# the is_active:false session end and the requestTrack connect->browse flip
# leave it), and LMS's current playlist item was a STALE title. The
# transfer-in took the reactivation branch and dispatched `seek` + `resume`
# instead of `start`; Connect.pm's resume handler then unpaused the stale
# item (pause 0) -- LMS asked getNextTrack for the stale url 38 ms later.
#
# The existing t/32 cases pin the intended reactivation (transfer-away and
# back: mode idle + marker -> seek + resume); there LMS still holds the
# session's own track, or nothing is known. The discriminator is therefore
# LMS's current url, not Control's mode.
# L2-a  (RED pre-fix): idle + marker + LMS holds a stale spoton track -> `start`.
# L2-a2 (RED pre-fix): idle + marker + LMS holds foreign content (radio) -> `start`.
# L2-g  (guard only, passes pre- and post-fix): idle + marker + LMS holds the
#   session's own track (transfer-away and back) -> seek + resume, never start.
# ============================================================
{
    my $L2_OLD   = 'spotify:track:7j74lucZ59vqN67Ipe2ZcY';
    my $L2_STALE = 'spoton://track:1JSTJqkT5qHq8MDJnJbRE1';
    my $L2_OWN   = 'spoton://track:11dFghVXANMlKmJXsNCbNl';   # $TID as an LMS url

    my $l2_run = sub {
        my ($name, $macTail, $lmsUrl) = @_;
        @Plugins::SpotOn::Connect::CLAIMS = (); $Plugins::SpotOn::Connect::ACTIVE = undef;
        @Slim::Player::Client::EXECUTED   = ();
        my $mac = "aa:84:01:00:00:$macTail";
        my $client = Slim::Player::Client::getClient($mac);
        $client->streamingSong(undef);
        $client->playingSong(Slim::Player::Client::_StubSong->new($lmsUrl));
        my ($ctl) = fresh_control(
            mac      => $mac,
            mode     => 'idle',
            observed => {
                wsConnected => 1, meta => {}, track => $TID, status => 'paused',
                is_active   => 0, startEmittedFor => $L2_OLD, anchor => { position_ms => 46000 },
            },
        );
        $ctl->onEvent(decode_frame(load_fixture('device_changed.json')));
        return $ctl;
    };

    for my $case (
        [ 'L2-a',  '01', $L2_STALE ],
        [ 'L2-a2', '02', 'http://radio.example/1live.mp3' ],
    ) {
        my ($name, $tail, $url) = @$case;
        my $ctl = $l2_run->($name, $tail, $url);
        is($ctl->mode, 'connect', "84-01 $name: transfer-in switches idle -> connect");
        is(scalar(@Slim::Player::Client::EXECUTED), 1,
            "84-01 $name: exactly one spottyconnect execute on the transfer-in (not seek + resume)");
        is($Slim::Player::Client::EXECUTED[0][1], 'start',
            "84-01 $name: the one execute is 'start' -- LMS holds '$url', there is no session to reactivate");
        is($ctl->observed->{startEmittedFor}, $TID,
            "84-01 $name: startEmittedFor now names the new session's track");
    }

    # L2-g: transfer-away and back -- LMS still holds the session's own track
    my $gctl = $l2_run->('L2-g', '03', $L2_OWN);
    my @gverbs = map { $_->[1] } @Slim::Player::Client::EXECUTED;
    is_deeply(\@gverbs, [ 'seek', 'resume' ],
        "84-01 L2-g (guard only): LMS still holds the session's own track -> reactivation (seek + resume)");
    is($gctl->observed->{startEmittedFor}, $L2_OLD,
        "84-01 L2-g (guard only): the marker of a reactivated session is kept");
}

# ============================================================
# 84-02 C4-c (Control half, D-21): a transfer-in `start` carries the app
# position, so Connect.pm can set LMS' clock at the start instead of waiting
# for a `seek` echo that never comes (live 2026-09-30 11:03:46, l2-proof run:
# POS_LMS_FIRST_S=0 while the daemon entered at 44 s -- LMS' bar ran from 0).
# `start`'s third parameter (`_p3`) was always ''; it now holds the anchor
# position in seconds ('%.3f', same format as the reactivation branch's seek),
# or stays '' when no position is known.
#   C4-c-ctl-a (RED pre-fix): anchor 46000 ms -> start p3 == '46.000'
#   C4-c-ctl-b (guard only):  no anchor       -> start p3 == ''
# ============================================================
{
    my $c4_run = sub {
        my ($macTail, $anchor) = @_;
        @Plugins::SpotOn::Connect::CLAIMS = (); $Plugins::SpotOn::Connect::ACTIVE = undef;
        @Slim::Player::Client::EXECUTED   = ();
        my $mac = "aa:84:02:00:00:$macTail";
        my $client = Slim::Player::Client::getClient($mac);
        $client->streamingSong(undef);
        $client->playingSong(undef);
        my ($ctl) = fresh_control(
            mac      => $mac,
            mode     => 'idle',
            observed => {
                wsConnected => 1, meta => {}, track => $TID, status => 'paused',
                is_active   => 0,
                (defined $anchor ? (anchor => { position_ms => $anchor }) : ()),
            },
        );
        $ctl->onEvent(decode_frame(load_fixture('device_changed.json')));
        return $ctl;
    };

    $c4_run->('01', 46000);
    is(scalar(@Slim::Player::Client::EXECUTED), 1, "84-02 C4-c-ctl-a: exactly one spottyconnect execute");
    is($Slim::Player::Client::EXECUTED[0][1], 'start', "84-02 C4-c-ctl-a: the execute is 'start'");
    is($Slim::Player::Client::EXECUTED[0][3], '46.000',
        "84-02 C4-c-ctl-a: start carries the app position (anchor 46000 ms) in its third parameter");

    $c4_run->('02', undef);
    is($Slim::Player::Client::EXECUTED[0][1], 'start', "84-02 C4-c-ctl-b (guard only): the execute is 'start'");
    is($Slim::Player::Client::EXECUTED[0][3], '',
        "84-02 C4-c-ctl-b (guard only): no anchor -> start's third parameter stays empty");
}

# ============================================================
# 84-02 C4-c-ctl-c (RED pre-fix): the zero reset frame. Live 2026-09-30
# 12:10:03.699-04.605 (l2-proof stale run, recorder ws.jsonl): position_sync
# 44499 speed 1 -> track_changed -> position_sync 0 speed 0 -> device_changed.
# The zero frame (the daemon's new-item reset) overwrote the anchor, so the
# transfer-in `start` carried no position (POS_LMS_FIRST_S=0, app at 45 s).
# The last real position before a zero reset is remembered (entryAnchor) and
# used when the anchor itself reads 0.
#   C4-c-ctl-c: 44499 -> 0 -> device_changed           -> start p3 '44.499'
#   C4-c-ctl-d (guard only): the real entry frame follows the zero (15530, the
#     12:04:12.919 case) -> that frame wins -> '15.530'
#   C4-c-ctl-e (guard only): a stale entryAnchor (older than the limit) is not used
# ============================================================
{
    my $c4_frames = sub {
        my ($macTail, @frames) = @_;
        @Plugins::SpotOn::Connect::CLAIMS = (); $Plugins::SpotOn::Connect::ACTIVE = undef;
        @Slim::Player::Client::EXECUTED   = ();
        my $mac = "aa:84:02:00:01:$macTail";
        my $client = Slim::Player::Client::getClient($mac);
        $client->streamingSong(undef);
        $client->playingSong(undef);
        my ($ctl) = fresh_control(
            mac      => $mac,
            mode     => 'idle',
            observed => { wsConnected => 1, meta => {}, track => $TID, status => 'paused', is_active => 0 },
        );
        for my $f (@frames) { $ctl->onEvent($f); }
        $ctl->onEvent(decode_frame(load_fixture('device_changed.json')));
        return $ctl;
    };
    my $ps = sub { my ($ms, $speed) = @_; return { type => 'position_sync', position => { position_ms => $ms, timestamp_ms => 0, speed => $speed } }; };

    $c4_frames->('01', $ps->(44499, 1), $ps->(0, 0));
    is($Slim::Player::Client::EXECUTED[0][1], 'start', "84-02 C4-c-ctl-c: the execute is 'start'");
    is($Slim::Player::Client::EXECUTED[0][3], '44.499',
        "84-02 C4-c-ctl-c: a zero reset frame does not lose the last real position -> start carries 44.499");

    # 84-14 (D-06 workaround) SUPERSEDES the 84-02 expectation here: the daemon's
    # entry frame after the zero (15530) is 31 s off the app position (46710) --
    # the 12:04:12.919 failure itself -- so `start` now carries the app position
    # and one corrective seek goes out (see the 84-14 E-* cases below). The
    # 15.530 this case used to pin was the wrong figure. An entry within the
    # 2 s tolerance still wins as before (E-b).
    $c4_frames->('02', $ps->(46710, 1), $ps->(0, 0), $ps->(15530, 0));
    ok(abs(($Slim::Player::Client::EXECUTED[0][3] // 0) - 46.710) < 0.005,
        "84-02 C4-c-ctl-d (84-14 superseded): an entry frame 31 s off the app position no longer wins -> start carries ~46.710, got "
        . ($Slim::Player::Client::EXECUTED[0][3] // 'none'));

    {
        # an entryAnchor older than the limit, anchor itself 0
        @Plugins::SpotOn::Connect::CLAIMS = (); $Plugins::SpotOn::Connect::ACTIVE = undef;
        @Slim::Player::Client::EXECUTED   = ();
        my $mac = "aa:84:02:00:01:04";
        my $client = Slim::Player::Client::getClient($mac);
        $client->streamingSong(undef); $client->playingSong(undef);
        my ($ctl) = fresh_control(mac => $mac, mode => 'idle',
            observed => { wsConnected => 1, meta => {}, track => $TID, status => 'paused', is_active => 0,
                          anchor => { position_ms => 0, seen_at => time() },
                          entryAnchor => { position_ms => 44499, seen_at => time() - 120 } });
        $ctl->onEvent(decode_frame(load_fixture('device_changed.json')));
        is($Slim::Player::Client::EXECUTED[0][3], '',
            "84-02 C4-c-ctl-e (guard only): an entryAnchor older than the limit is not used -> start carries no position");
    }
}

# ============================================================
# 84-14 (D-06 workaround for a daemon-side entry figure): a transfer-in whose
# daemon entry position is off the app position by more than
# ENTRY_TOLERANCE_MS (2000) gets exactly ONE corrective seek to the app
# position, through the armed seek path; never to 0, never without a known
# position, one-shot per transfer-in.
#
# Evidence (84-ENTRY-ATTRIBUTION.md, recorder ws.jsonl): M1 position_sync
# 47174 (speed 1) -> track_changed -> 0 (speed 0) -> 3620 (speed 0) ->
# device_changed 0.8 s later; M3 45869 -> 0 -> 6966 -> device_changed. The wrong
# figure is the daemon's own and precedes device_changed and any SpotOn command.
#   E-a  (RED pre-fix) live order: 47174/1 -> playback_state 0 -> 0 -> 3620/0 ->
#        device_changed: ONE seek ~47174 sent; start carries ~47.174
#   E-a2 (RED pre-fix) plan order (entry frames AFTER device_changed):
#        44499/1 -> device_changed -> 0 -> 15530/1: ONE seek ~44499; start 44.499
#   E-b  (guard only) entry within 2 s (44700 vs 44499; live order 44681 vs 44682) -> no seek
#   E-c  (guard only) no position known -> no seek, before or after device_changed
#   E-d  (guard only) a later divergent frame (20000) after the seek -> no second seek
#   E-e  the daemon's echo of our seek (position_sync ~47174) is carried to LMS as
#        exactly one `seek` event and dispatches nothing more
#   E-f  (guard only) target under 1 s (500 ms) is unknown -> never a seek
#   E-h  (RED pre-fix) the pa failure: the daemon entered at 0:00 and reported only the
#        reset frames after the app position -> ONE seek to the app position
#   E-g  (RED pre-fix) the new-item reset as playback_state(0) BEFORE position_sync(0)
#        (the live order) does not lose the last real position (entryAnchor)
# ============================================================
{
    my $e_run = sub {
        my ($macTail, $before, $after) = @_;
        @Plugins::SpotOn::Connect::CLAIMS = (); $Plugins::SpotOn::Connect::ACTIVE = undef;
        @Slim::Player::Client::EXECUTED   = ();
        my $mac = "aa:84:14:00:00:$macTail";
        my $client = Slim::Player::Client::getClient($mac);
        $client->streamingSong(undef);
        $client->playingSong(undef);
        my ($ctl, $daemon, $ws) = fresh_control(
            mac      => $mac,
            mode     => 'idle',
            observed => { wsConnected => 1, meta => {}, track => $TID, status => 'paused', is_active => 0 },
        );
        $ctl->onEvent($_) for @{ $before || [] };
        $ctl->onEvent(decode_frame(load_fixture('device_changed.json')));
        $ctl->onEvent($_) for @{ $after || [] };
        return ($ctl, $ws);
    };
    my $ps = sub { my ($ms, $speed) = @_; return { type => 'position_sync', position => { position_ms => $ms, timestamp_ms => 0, speed => $speed } }; };
    my $pbs = sub { my ($ms, $speed, $status) = @_; return { type => 'playback_state', status => $status // 'playing', is_active => 0,
        item => { uri => "spotify:track:$TID" }, position => { position_ms => $ms, timestamp_ms => 0, speed => $speed } }; };
    my $seeks = sub { my ($ws) = @_; return [ grep { $_->[0] eq 'seek' } @{ $ws->sent } ]; };
    my $near  = sub { my ($got, $want, $tol) = @_; return (defined $got && abs($got - $want) <= ($tol // 50)) ? 1 : 0; };

    # E-a: live order -- the wrong entry frame precedes device_changed
    {
        my ($ctl, $ws) = $e_run->('01', [ $ps->(47174, 1), $pbs->(0, 0, 'buffering'), $ps->(0, 0), $ps->(3620, 0) ], []);
        my $sk = $seeks->($ws);
        is(scalar(@$sk), 1, "84-14 E-a: exactly ONE seek sent to the daemon (entry 3620 ms, app 47174 ms)");
        ok($near->($sk->[0][1]{position_ms}, 47174), "84-14 E-a: the seek targets the app position (~47174 ms), got " . ($sk->[0][1]{position_ms} // 'none'));
        ok($sk->[0][1]{position_ms} >= 1000, "84-14 E-a: never a seek to 0");
        my @starts = grep { $_->[1] eq 'start' } @Slim::Player::Client::EXECUTED;
        is(scalar(@starts), 1, "84-14 E-a: one start");
        ok($near->($starts[0][3] * 1000, 47174, 5), "84-14 E-a: start carries the app position (~47.174), got " . ($starts[0][3] // 'none'));
        is($ctl->observed->{entryCheck}, undef, "84-14 E-a: nothing left armed after a decided transfer-in");
    }

    # E-a2: the plan's order -- entry frames after device_changed
    {
        my ($ctl, $ws) = $e_run->('02', [ $ps->(44499, 1) ], [ $ps->(0, 0), $ps->(15530, 1) ]);
        my $sk = $seeks->($ws);
        is(scalar(@$sk), 1, "84-14 E-a2: exactly ONE seek after device_changed (entry 15530 ms, app 44499 ms)");
        ok($near->($sk->[0][1]{position_ms}, 44499), "84-14 E-a2: the seek targets ~44499 ms, got " . ($sk->[0][1]{position_ms} // 'none'));
        my @starts = grep { $_->[1] eq 'start' } @Slim::Player::Client::EXECUTED;
        is($starts[0][3], '44.499', "84-14 E-a2: start carries 44.499 (guard: C4-c-ctl)");
    }

    # E-b: within tolerance -> no seek (both orders)
    {
        my ($ctl, $ws) = $e_run->('03', [ $ps->(44499, 1) ], [ $ps->(0, 0), $ps->(44700, 1) ]);
        is(scalar(@{ $seeks->($ws) }), 0, "84-14 E-b (guard only): entry 44700 vs app 44499 -> no seek");
        my ($ctl2, $ws2) = $e_run->('04', [ $ps->(44682, 1), $ps->(0, 0), $ps->(44681, 0) ], []);
        is(scalar(@{ $seeks->($ws2) }), 0, "84-14 E-b (guard only): live order, entry 44681 vs app 44682 -> no seek");
    }

    # E-c: no position known
    {
        my ($ctl, $ws) = $e_run->('05', [], [ $ps->(0, 0), $ps->(15530, 1) ]);
        is(scalar(@{ $seeks->($ws) }), 0, "84-14 E-c (guard only): no position known at the transfer -> no seek");
        my ($ctl2, $ws2) = $e_run->('06', [ $ps->(0, 0) ], []);
        is(scalar(@{ $seeks->($ws2) }), 0, "84-14 E-c (guard only): only a zero frame -> no seek");
    }

    # E-d: one-shot
    {
        my ($ctl, $ws) = $e_run->('07', [ $ps->(44499, 1) ], [ $ps->(0, 0), $ps->(15530, 1), $ps->(20000, 1), $ps->(0, 0), $ps->(9000, 1) ]);
        is(scalar(@{ $seeks->($ws) }), 1, "84-14 E-d (guard only): later divergent frames after the seek -> still exactly one seek");
        my ($ctl2, $ws2) = $e_run->('08', [ $ps->(47174, 1), $ps->(0, 0), $ps->(3620, 0) ], [ $ps->(20000, 1), $ps->(0, 0), $ps->(9000, 1) ]);
        is(scalar(@{ $seeks->($ws2) }), 1, "84-14 E-d (guard only): live order, later divergent frames -> still exactly one seek");
    }

    # E-e: the echo of our seek is carried to LMS, dispatches nothing more
    {
        my ($ctl, $ws) = $e_run->('09', [ $ps->(47174, 1), $ps->(0, 0), $ps->(3620, 0) ], []);
        my $execBefore = scalar(@Slim::Player::Client::EXECUTED);
        $ctl->observed->{anchor}{seen_at} -= 10;   # the time between the seek and its echo (rebased expectation moves on)
        $ctl->onEvent($ps->(47300, 1));
        my @new = @Slim::Player::Client::EXECUTED[$execBefore .. $#Slim::Player::Client::EXECUTED];
        is(scalar(grep { $_->[1] eq 'seek' } @new), 1, "84-14 E-e: the daemon's echo of our seek reaches LMS as exactly one seek event");
        is(scalar(@{ $seeks->($ws) }), 1, "84-14 E-e: the echo dispatches no further seek to the daemon");
    }

    # E-f: a target under 1 s is unknown
    {
        my ($ctl, $ws) = $e_run->('0a', [ $ps->(500, 1) ], [ $ps->(0, 0), $ps->(15530, 1) ]);
        is(scalar(@{ $seeks->($ws) }), 0, "84-14 E-f (guard only): app position 500 ms is under the 1 s floor -> never a seek");
    }

    # E-h (RED pre-fix): the pa failure -- the daemon entered at 0:00 and reported only the
    # reset frames (84-14 proof run 14:25, start_position 0 ms, no frame after the zero)
    {
        my ($ctl, $ws) = $e_run->('0c', [ $ps->(45430, 1), $pbs->(0, 0, 'buffering'), $ps->(0, 0) ], []);
        my $sk = $seeks->($ws);
        is(scalar(@$sk), 1, "84-14 E-h: daemon entry at 0 (only the reset frames after app position 45430) -> exactly ONE seek");
        ok($near->($sk->[0][1]{position_ms}, 45430), "84-14 E-h: the seek targets the app position (~45430 ms), got " . ($sk->[0][1]{position_ms} // 'none'));
        my @starts = grep { $_->[1] eq 'start' } @Slim::Player::Client::EXECUTED;
        ok($near->($starts[0][3] * 1000, 45430, 5), "84-14 E-h: start carries the app position (~45.430), got " . ($starts[0][3] // 'none'));
    }

    # E-g: the live reset order (playback_state 0 first) keeps the last real position
    {
        my ($ctl, $ws) = $e_run->('0b', [ $ps->(47174, 1), $pbs->(0, 0, 'buffering'), $ps->(0, 0) ], []);
        my @starts = grep { $_->[1] eq 'start' } @Slim::Player::Client::EXECUTED;
        ok($near->($starts[0][3] * 1000, 47174, 5),
            "84-14 E-g: playback_state(0) before position_sync(0) does not lose the last real position -> start carries ~47.174, got " . ($starts[0][3] // 'none'));
    }
}

# ============================================================
# 84-14 (round 3): the workaround on the REACTIVATION branch of
# _onFrameDeviceChanged. Live 2026-09-30 14:25 and 14:36 (`empty --prior same`,
# runs 142401 / 143448): the prior session's startEmittedFor marker survives, the
# playlist is empty (LMS url undef -> the 84-01 marker-drop cannot fire), so the
# transfer-in took the reactivation branch, which sent `seek <anchor>` with the
# anchor being the daemon's reset (0.000) and then `resume` -- SpotOn itself sent
# 0:00 (recorder: position_sync 45926/1 -> track_changed -> 0/0 -> device_changed;
# server log verbs `seek, resume`, no `start`).
#   R-a  (RED pre-fix) that live shape: ONE daemon seek ~45926, LMS `seek`/`resume`
#        carry ~45.926, never `seek 0.000`
#   R-a2 (RED pre-fix) the reset is followed by a divergent non-zero entry frame (3620)
#   R-b  (guard only) genuine transfer-away-and-back, real non-zero anchor (46000):
#        seek 46.000 + resume 46.000, NO daemon seek (current behaviour kept)
#   R-c  (RED pre-fix: counts the first seek) one-shot: later divergent frames -> no second
#   R-d  (RED pre-fix on the 0.000 seek) position unknown (only the zero frame): no daemon
#        seek and no LMS `seek 0.000`; `resume` still goes out
# ============================================================
{
    my $OLD = 'spotify:track:7j74lucZ59vqN67Ipe2ZcY';
    my $r_run = sub {
        my ($macTail, $lmsUrl, $obs, $before, $after) = @_;
        @Plugins::SpotOn::Connect::CLAIMS = (); $Plugins::SpotOn::Connect::ACTIVE = undef;
        @Slim::Player::Client::EXECUTED   = ();
        my $mac = "aa:84:14:01:00:$macTail";
        my $client = Slim::Player::Client::getClient($mac);
        $client->streamingSong(undef);
        $client->playingSong(defined $lmsUrl ? Slim::Player::Client::_StubSong->new($lmsUrl) : undef);
        my ($ctl, $daemon, $ws) = fresh_control(
            mac      => $mac,
            mode     => 'idle',
            observed => { wsConnected => 1, meta => {}, track => $TID, status => 'paused', is_active => 0,
                          startEmittedFor => $OLD, %{ $obs || {} } },
        );
        $ctl->onEvent($_) for @{ $before || [] };
        $ctl->onEvent(decode_frame(load_fixture('device_changed.json')));
        $ctl->onEvent($_) for @{ $after || [] };
        return ($ctl, $ws);
    };
    my $ps = sub { my ($ms, $speed) = @_; return { type => 'position_sync', position => { position_ms => $ms, timestamp_ms => 0, speed => $speed } }; };
    my $pbs = sub { my ($ms, $speed, $status) = @_; return { type => 'playback_state', status => $status // 'playing', is_active => 0,
        item => { uri => "spotify:track:$TID" }, position => { position_ms => $ms, timestamp_ms => 0, speed => $speed } }; };
    my $seeks = sub { my ($ws) = @_; return [ grep { $_->[0] eq 'seek' } @{ $ws->sent } ]; };
    my $near  = sub { my ($got, $want, $tol) = @_; return (defined $got && abs($got - $want) <= ($tol // 50)) ? 1 : 0; };
    my $lms   = sub { my ($verb) = @_; return [ grep { $_->[1] eq $verb } @Slim::Player::Client::EXECUTED ]; };

    # R-a: the live shape
    {
        my ($ctl, $ws) = $r_run->('01', undef, {}, [ $ps->(45926, 1), $pbs->(0, 0, 'buffering'), $ps->(0, 0) ], []);
        my @verbs = map { $_->[1] } @Slim::Player::Client::EXECUTED;
        is_deeply(\@verbs, [ 'seek', 'resume' ], "84-14 R-a: marker survives, empty playlist -> still the reactivation path (seek + resume, no start)");
        my $sk = $seeks->($ws);
        is(scalar(@$sk), 1, "84-14 R-a: exactly ONE seek sent to the daemon");
        ok($near->($sk->[0][1]{position_ms}, 45926), "84-14 R-a: the daemon seek targets the last real position (~45926 ms), got " . ($sk->[0][1]{position_ms} // 'none'));
        my $ls = $lms->('seek')->[0];
        ok($near->(($ls->[2] // -1) * 1000, 45926, 5), "84-14 R-a: the LMS seek event carries ~45.926, got " . ($ls->[2] // 'none'));
        is(scalar(grep { ($_->[2] // '') eq '0.000' } @{ $lms->('seek') }), 0, "84-14 R-a: never an LMS `seek 0.000`");
        my $lr = $lms->('resume')->[0];
        ok($near->(($lr->[3] // -1) * 1000, 45926, 5), "84-14 R-a: resume carries ~45.926, got " . ($lr->[3] // 'none'));
        is($ctl->observed->{startEmittedFor}, $OLD, "84-14 R-a: the marker is kept (still a reactivation)");
    }

    # R-a2: reset followed by a divergent non-zero entry frame
    {
        my ($ctl, $ws) = $r_run->('02', undef, {}, [ $ps->(45926, 1), $pbs->(0, 0, 'buffering'), $ps->(0, 0), $ps->(3620, 0) ], []);
        my $sk = $seeks->($ws);
        is(scalar(@$sk), 1, "84-14 R-a2: entry 3620 ms vs app 45926 ms -> exactly ONE daemon seek");
        ok($near->($sk->[0][1]{position_ms}, 45926), "84-14 R-a2: the daemon seek targets ~45926 ms, got " . ($sk->[0][1]{position_ms} // 'none'));
        my $ls = $lms->('seek')->[0];
        ok($near->(($ls->[2] // -1) * 1000, 45926, 5), "84-14 R-a2: the LMS seek event carries ~45.926, got " . ($ls->[2] // 'none'));
    }

    # R-b: genuine transfer-away-and-back (guard only)
    {
        my ($ctl, $ws) = $r_run->('03', 'spoton://track:11dFghVXANMlKmJXsNCbNl', { anchor => { position_ms => 46000 } }, [], []);
        my @verbs = map { $_->[1] } @Slim::Player::Client::EXECUTED;
        is_deeply(\@verbs, [ 'seek', 'resume' ], "84-14 R-b (guard only): away and back, LMS holds the session's own track -> seek + resume");
        is($lms->('seek')->[0][2], '46.000', "84-14 R-b (guard only): the LMS seek carries the real anchor 46.000");
        is($lms->('resume')->[0][3], '46.000', "84-14 R-b (guard only): resume carries 46.000");
        is(scalar(@{ $seeks->($ws) }), 0, "84-14 R-b (guard only): no daemon seek for a genuine reactivation");
        my ($ctl2, $ws2) = $r_run->('04', 'spoton://track:11dFghVXANMlKmJXsNCbNl', {}, [ $ps->(46000, 1) ], [ $ps->(46100, 1) ]);
        is(scalar(@{ $seeks->($ws2) }), 0, "84-14 R-b (guard only): real frames around a reactivation -> no daemon seek");
        is($lms->('seek')->[0][2], '46.000', "84-14 R-b (guard only): frame-fed anchor -> LMS seek 46.000");
    }

    # R-c: one-shot
    {
        my ($ctl, $ws) = $r_run->('05', undef, {}, [ $ps->(45926, 1), $pbs->(0, 0, 'buffering'), $ps->(0, 0) ],
            [ $ps->(20000, 1), $ps->(0, 0), $ps->(9000, 1) ]);
        is(scalar(@{ $seeks->($ws) }), 1, "84-14 R-c: later divergent frames after the corrective seek -> still exactly one daemon seek");
    }

    # R-d: position unknown
    {
        my ($ctl, $ws) = $r_run->('06', undef, {}, [ $ps->(0, 0) ], []);
        is(scalar(@{ $seeks->($ws) }), 0, "84-14 R-d: only the zero frame -> no daemon seek");
        is(scalar(grep { ($_->[2] // '') eq '0.000' } @{ $lms->('seek') }), 0, "84-14 R-d: only the zero frame -> no LMS `seek 0.000`");
        is(scalar(@{ $lms->('resume') }), 1, "84-14 R-d: resume still goes out");
    }
}

# ============================================================
# 84-26 F-24-2 Control (defensive; the primary repair is Connect.pm's jumpToTime): the
# reactivation transfer-in writes a one-shot `observed->{entryResume}` marker carrying the
# position Control ITSELF emitted in that resume (the 84-14 entry fix included -- never the raw
# `observed->{anchor}`, which _entryFixOnTransferIn does not rewrite). An LMS re-open
# (requestTrack seek=1, same uri, within ENTRY_RESUME_WINDOW_S = 2 s) whose target is off that
# figure by more than HIT_POSITION_TOLERANCE_MS gets the emitted position as the seek target; the
# marker is consumed on first read, expires, matches only its own uri, and is never written for a
# sub-ENTRY_MIN_TARGET_MS figure.
# ============================================================
{
    my $FR_URI = 'spotify:track:11dFghVXANMlKmJXsNCbNl';
    my $OLD    = 'spotify:track:7j74lucZ59vqN67Ipe2ZcY';
    my $fr_run = sub {
        my ($macTail, $lmsUrl, $obs, $before) = @_;
        @Plugins::SpotOn::Connect::CLAIMS = (); $Plugins::SpotOn::Connect::ACTIVE = undef;
        @Slim::Player::Client::EXECUTED   = ();
        my $mac = "aa:84:26:04:00:$macTail";
        my $client = Slim::Player::Client::getClient($mac);
        $client->streamingSong(undef);
        $client->playingSong(defined $lmsUrl ? Slim::Player::Client::_StubSong->new($lmsUrl) : undef);
        my ($ctl, $daemon, $ws) = fresh_control(
            mac      => $mac,
            mode     => 'idle',
            observed => { wsConnected => 1, paired => 1, meta => {}, track => $FR_URI, status => 'paused', is_active => 0,
                          startEmittedFor => $OLD, %{ $obs || {} } },
        );
        $ctl->onEvent($_) for @{ $before || [] };
        $ctl->onEvent(decode_frame(load_fixture('device_changed.json')));
        return ($ctl, $ws, $daemon);
    };
    my $ps  = sub { my ($ms, $speed) = @_; return { type => 'position_sync', position => { position_ms => $ms, timestamp_ms => 0, speed => $speed } }; };
    my $pbs = sub { my ($ms, $speed, $status) = @_; return { type => 'playback_state', status => $status // 'playing', is_active => 0,
        item => { uri => $FR_URI }, position => { position_ms => $ms, timestamp_ms => 0, speed => $speed } }; };
    my $sent_since = sub { my ($ws, $n0, $cmd) = @_; my @all = @{ $ws->sent }; return [ grep { $_->[0] eq $cmd } @all[ $n0 .. $#all ] ]; };
    my $near = sub { my ($got, $want, $tol) = @_; return (defined $got && abs($got - $want) <= ($tol // 50)) ? 1 : 0; };
    my $GENUINE = 'spoton://track:11dFghVXANMlKmJXsNCbNl';    # LMS holds the session's own track: the genuine away-and-back

    # Fall A: the reactivation resume writes the marker with the emitted position
    {
        my ($ctl, $ws, $daemon) = $fr_run->('01', $GENUINE, { anchor => { position_ms => 53386 } }, []);
        my @verbs = map { $_->[1] } @Slim::Player::Client::EXECUTED;
        is_deeply(\@verbs, [ 'seek', 'resume' ], "84-26 F-24-2 Control Fall A setup: the reactivation path (seek + resume)");
        my $er = $ctl->observed->{entryResume};
        is($er && $er->{uri}, $FR_URI, "84-26 F-24-2 Control Fall A: observed.entryResume.uri = the resumed track");
        is($er && $er->{position_ms}, 53386, "84-26 F-24-2 Control Fall A: entryResume.position_ms = the position the resume emitted");
    }

    # Fall B: an LMS re-open at the stale 31205 within the window follows the EMITTED 53386 (raw anchor seeded 0 on purpose)
    {
        my ($ctl, $ws, $daemon) = $fr_run->('02', $GENUINE, { anchor => { position_ms => 53386 } }, []);
        $ctl->observed->{anchor} = { position_ms => 0 };
        my $n0 = scalar @{ $ws->sent };
        $ctl->requestTrack($FR_URI, 31205, { seek => 1, source => 'onStream', successCb => sub { }, errorCb => sub { } });
        is($ctl->wanted->{position_ms}, 53386, "84-26 F-24-2 Control Fall B: wanted.position_ms = the emitted figure, never the LMS stale 31205 nor the raw anchor");
        my $seeks = $sent_since->($ws, $n0, 'seek');
        ok(scalar(@$seeks) >= 1, "84-26 F-24-2 Control Fall B setup: a seek was dispatched");
        is(scalar(grep { $_->[1]{position_ms} != 53386 } @$seeks), 0, "84-26 F-24-2 Control Fall B: every seek sent carries 53386 (never 31205)");
        is(scalar(grep { exists $_->[1]{uri} } @{ $sent_since->($ws, $n0, 'play') }), 0, "84-26 F-24-2 Control Fall B: no play with a uri (no restart of the title)");
    }

    # Fall C: the same call 3 s after the marker -> honoured as today, marker consumed
    {
        my ($ctl, $ws, $daemon) = $fr_run->('03', $GENUINE, { anchor => { position_ms => 53386 } }, []);
        $ctl->observed->{entryResume}{hr} -= 3 if $ctl->observed->{entryResume};
        my $n0 = scalar @{ $ws->sent };
        $ctl->requestTrack($FR_URI, 31205, { seek => 1, source => 'onStream', successCb => sub { }, errorCb => sub { } });
        is($ctl->wanted->{position_ms}, 31205, "84-26 F-24-2 Control Fall C: an expired marker leaves the LMS seek target alone");
        ok(!exists $ctl->observed->{entryResume}, "84-26 F-24-2 Control Fall C: the marker is consumed on first read");
        is(scalar(grep { $_->[1]{position_ms} != 31205 } @{ $sent_since->($ws, $n0, 'seek') }), 0, "84-26 F-24-2 Control Fall C: every seek sent carries 31205 as today");
    }

    # Fall D: an LMS target within HIT_POSITION_TOLERANCE_MS of the emitted figure -> honoured, marker consumed
    {
        my ($ctl, $ws, $daemon) = $fr_run->('04', $GENUINE, { anchor => { position_ms => 53386 } }, []);
        $ctl->requestTrack($FR_URI, 53300, { seek => 1, source => 'onStream', successCb => sub { }, errorCb => sub { } });
        is($ctl->wanted->{position_ms}, 53300, "84-26 F-24-2 Control Fall D: a target within tolerance is honoured as today");
        ok(!exists $ctl->observed->{entryResume}, "84-26 F-24-2 Control Fall D: the marker is consumed");
    }

    # Fall E: a different uri -> honoured
    {
        my ($ctl, $ws, $daemon) = $fr_run->('05', $GENUINE, { anchor => { position_ms => 53386 } }, []);
        $ctl->requestTrack('spotify:track:otherTitleOtherTitleOT', 31205, { seek => 1, source => 'onStream', successCb => sub { }, errorCb => sub { } });
        is($ctl->wanted->{position_ms}, 31205, "84-26 F-24-2 Control Fall E: a re-open of another uri keeps its own target");
    }

    # Fall F (the 84-14 entry-fix shape): the anchor reads the reset, _entryFixOnTransferIn supplies the app position;
    # the marker holds what the resume EMITTED, and a following requestTrack(uri, 112, seek) substitutes it -- never 0
    {
        my ($ctl, $ws, $daemon) = $fr_run->('06', undef, {}, [ $ps->(45926, 1), $pbs->(0, 0, 'buffering'), $ps->(0, 0) ]);
        my $lr = (grep { $_->[1] eq 'resume' } @Slim::Player::Client::EXECUTED)[0];
        ok($near->(($lr->[3] // -1) * 1000, 45926, 5), "84-26 F-24-2 Control Fall F setup: the resume carries the entry-fix figure ~45.926, got " . ($lr->[3] // 'none'));
        my $er = $ctl->observed->{entryResume};
        ok($er && $near->($er->{position_ms}, 45926, 5), "84-26 F-24-2 Control Fall F: the marker holds the emitted ~45926 (never the raw anchor), got " . ($er ? $er->{position_ms} : 'none'));
        $ctl->requestTrack($FR_URI, 112, { seek => 1, source => 'onStream', successCb => sub { }, errorCb => sub { } });
        ok($near->($ctl->wanted->{position_ms}, 45926, 5), "84-26 F-24-2 Control Fall F: requestTrack(112) substitutes ~45926, never 0/112, got " . ($ctl->wanted->{position_ms} // 'none'));
    }

    # Fall G (the floor): the resume's emitted position is 0.000 (only the zero frame) -> NO marker, a following
    # requestTrack(uri, 31205, seek) is honoured
    {
        my ($ctl, $ws, $daemon) = $fr_run->('07', undef, {}, [ $ps->(0, 0) ]);
        ok(scalar(grep { $_->[1] eq 'resume' } @Slim::Player::Client::EXECUTED), "84-26 F-24-2 Control Fall G setup: the resume still goes out");
        ok(!exists $ctl->observed->{entryResume}, "84-26 F-24-2 Control Fall G: a sub-1000 ms emitted figure writes NO marker");
        $ctl->requestTrack($FR_URI, 31205, { seek => 1, source => 'onStream', successCb => sub { }, errorCb => sub { } });
        is($ctl->wanted->{position_ms}, 31205, "84-26 F-24-2 Control Fall G: the LMS seek target is honoured");
    }
}

# --- 84.1-07 A6c (T-84.1-29 guard holds): from A6's state right after
# leaveConnect, BEFORE any echo -- while LMS keeps playing foreign
# content, a delayed playback_state(is_active,playing) frame must NOT
# re-adopt: the radio is not replaced. The echo is deliberately not a
# clear point, so the guard still holds afterwards ---
{
    my $mac = 'aa:84:07:00:00:c3';
    my ($ctl, $daemon, $ws) = _d02_setup($mac);
    local $Slim::Player::Source::PLAYMODE = 'play';
    foreign_track($mac, 'http://radio.example/1live-c3.mp3');
    eval { $ctl->leaveConnect('foreign-lms-content'); 1 };
    ok($ctl->observed->{leftConnectForeign}, "84.1-07 A6c setup: leftConnectForeign marker set");

    @Plugins::SpotOn::Connect::CLAIMS = ();
    @Slim::Player::Client::EXECUTED   = ();

    $ctl->onEvent({ type => 'playback_state', item => { uri => $TID }, status => 'playing', is_active => 1 });

    is($ctl->mode, 'idle', "84.1-07 A6c: mode stays idle -- guard held right after the leave");
    is(scalar(@Plugins::SpotOn::Connect::CLAIMS), 0, "84.1-07 A6c: no claim call recorded");
    is_deeply(\@Slim::Player::Client::EXECUTED, [], "84.1-07 A6c: no execute -- the radio is not replaced");

    $ctl->onEvent({ type => 'device_changed', is_active => 0, device_name => 'lavender-UAT' });
    $ctl->onEvent({ type => 'playback_state', item => { uri => $TID }, status => 'playing', is_active => 1 });

    is($ctl->mode, 'idle', "84.1-07 A6c: still idle after the deactivate echo and a second frame");
    is(scalar(@Plugins::SpotOn::Connect::CLAIMS), 0, "84.1-07 A6c: still no claim call after the echo");
    is_deeply(\@Slim::Player::Client::EXECUTED, [], "84.1-07 A6c: still no execute -- the echo is not a clear point");
    ok($ctl->observed->{leftConnectForeign}, "84.1-07 A6c: marker is still set");
}

# --- 84.1-07 A6d: the guard releases once LMS no longer plays foreign
# content -- the reconnect adoption then runs exactly as CR-02 ---
{
    my $mac = 'aa:84:07:00:00:d4';
    my ($ctl, $daemon, $ws) = _d02_setup($mac);
    {
        local $Slim::Player::Source::PLAYMODE = 'play';
        foreign_track($mac, 'http://radio.example/1live-d4.mp3');
        eval { $ctl->leaveConnect('foreign-lms-content'); 1 };
    }
    ok($ctl->observed->{leftConnectForeign}, "84.1-07 A6d setup: leftConnectForeign marker set");

    @Plugins::SpotOn::Connect::CLAIMS = ();
    @Slim::Player::Client::EXECUTED   = ();

    local $Slim::Player::Source::PLAYMODE = 'stop';
    $ctl->onEvent({ type => 'playback_state', item => { uri => $TID }, status => 'playing', is_active => 1 });

    is($ctl->mode, 'connect', "84.1-07 A6d: mode connect -- the guard released");
    is(scalar(@Plugins::SpotOn::Connect::CLAIMS), 1, "84.1-07 A6d: exactly one claim call");
    is_deeply($Plugins::SpotOn::Connect::CLAIMS[0], [ 'bind', $mac, 'reconnect', 0 ],
        "84.1-07 A6d: [ 'bind', mac, 'reconnect', 0 ]");
    is(scalar(@Slim::Player::Client::EXECUTED), 1, "84.1-07 A6d: exactly one execute");
    is($Slim::Player::Client::EXECUTED[0][1], 'start', "84.1-07 A6d: the execute is 'start'");
    ok(!exists($ctl->observed->{leftConnectForeign}), "84.1-07 A6d: leftConnectForeign gone");
}

# --- 84.1-07 A6e (revision 2, marker does not leak across sessions):
# leave -> tap-back -> the new session ends -> a LATER foreign track ->
# a LATER reconnect frame must adopt exactly as a leave-free TWIN would
# (a differential: _emitStart's own startEmittedFor-defined guard means
# neither the pre-fix code nor this one emits a second 'start' here) ---
{
    my $mac = 'aa:84:07:00:00:e6';
    my ($ctl, $daemon, $ws) = _d02_setup($mac);

    # 1. leave (as A6)
    {
        local $Slim::Player::Source::PLAYMODE = 'play';
        foreign_track($mac, 'http://radio.example/1live-e1.mp3');
        eval { $ctl->leaveConnect('foreign-lms-content'); 1 };
    }

    # 2. tap-back (the A6b frame)
    @Plugins::SpotOn::Connect::CLAIMS = ();
    @Slim::Player::Client::EXECUTED   = ();
    $ctl->onEvent(decode_frame(load_fixture('device_changed.json')));
    is($ctl->mode, 'connect', "84.1-07 A6e: tap-back restores connect");

    # 3. the new session ends by device_changed is_active:0 in connect
    $ctl->onEvent({ type => 'device_changed', is_active => 0, device_name => 'lavender-UAT' });
    is($ctl->mode, 'idle', "84.1-07 A6e: session end leaves connect (connect half unchanged)");

    # 4. reset CLAIMS and EXECUTED
    @Plugins::SpotOn::Connect::CLAIMS = ();
    @Slim::Player::Client::EXECUTED   = ();

    # 5. a foreign track plays in LMS
    local $Slim::Player::Source::PLAYMODE = 'play';
    foreign_track($mac, 'http://radio.example/1live-e2.mp3');

    # 6. the marker must already be gone (cleared by the tap-back, step 2)
    ok(!exists($ctl->observed->{leftConnectForeign}),
        "84.1-07 A6e: leftConnectForeign does not exist before the later reconnect frame");

    # 7. feed the CR-02 frame
    $ctl->onEvent({ type => 'playback_state', item => { uri => $TID }, status => 'playing', is_active => 1 });

    is($ctl->mode, 'connect', "84.1-07 A6e: mode connect after the later reconnect frame");
    is(scalar(@Plugins::SpotOn::Connect::CLAIMS), 1, "84.1-07 A6e: exactly one claim call");
    is_deeply($Plugins::SpotOn::Connect::CLAIMS[0], [ 'bind', $mac, 'reconnect', 0 ],
        "84.1-07 A6e: [ 'bind', mac, 'reconnect', 0 ]");

    my @executedAfter = @Slim::Player::Client::EXECUTED;

    # -- the leave-free twin: same starting shape, steps 3-7 only --
    my $twinMac = 'aa:84:07:00:00:e7';
    my ($twin, $twinDaemon, $twinWs) = fresh_control(
        mac      => $twinMac,
        mode     => 'connect',
        wanted   => { uri => $TID, playing => 1 },
        observed => {
            wsConnected => 1, meta => {}, track => $TID, status => 'playing',
            is_active   => 1, startEmittedFor => $TID,
        },
    );
    $twin->onEvent({ type => 'device_changed', is_active => 0, device_name => 'lavender-UAT' });
    @Plugins::SpotOn::Connect::CLAIMS = ();
    @Slim::Player::Client::EXECUTED   = ();
    foreign_track($twinMac, 'http://radio.example/1live-e2.mp3');
    $twin->onEvent({ type => 'playback_state', item => { uri => $TID }, status => 'playing', is_active => 1 });
    my @executedTwin = @Slim::Player::Client::EXECUTED;

    is_deeply(\@executedAfter, \@executedTwin,
        "84.1-07 A6e: EXECUTED after the later reconnect is identical to the leave-free twin (differential)");
}

# --- 84.1-07 A6f: an LMS stop ends the episode -- endForeignLeave
# clears the marker, so a later reconnect adoption runs exactly as
# CR-02 (startEmittedFor was already cleared by the leave) ---
{
    my $mac = 'aa:84:07:00:00:f6';
    my ($ctl, $daemon, $ws) = _d02_setup($mac);
    {
        local $Slim::Player::Source::PLAYMODE = 'play';
        foreign_track($mac, 'http://radio.example/1live-f6a.mp3');
        eval { $ctl->leaveConnect('foreign-lms-content'); 1 };
    }
    my $endOk = eval { $ctl->endForeignLeave('lms-stop'); 1 };
    ok($endOk, "84.1-07 A6f: endForeignLeave callable");
    ok(!exists($ctl->observed->{leftConnectForeign}), "84.1-07 A6f setup: endForeignLeave cleared the marker");

    @Plugins::SpotOn::Connect::CLAIMS = ();
    @Slim::Player::Client::EXECUTED   = ();

    local $Slim::Player::Source::PLAYMODE = 'play';
    foreign_track($mac, 'http://radio.example/1live-f6b.mp3');
    $ctl->onEvent({ type => 'playback_state', item => { uri => $TID }, status => 'playing', is_active => 1 });

    is($ctl->mode, 'connect', "84.1-07 A6f: mode connect -- adoption not held (marker was cleared)");
    is(scalar(@Plugins::SpotOn::Connect::CLAIMS), 1, "84.1-07 A6f: exactly one claim call");
    is_deeply($Plugins::SpotOn::Connect::CLAIMS[0], [ 'bind', $mac, 'reconnect', 0 ],
        "84.1-07 A6f: [ 'bind', mac, 'reconnect', 0 ]");
    is(scalar(@Slim::Player::Client::EXECUTED), 1, "84.1-07 A6f: exactly one execute");
    is($Slim::Player::Client::EXECUTED[0][1], 'start', "84.1-07 A6f: the execute is 'start'");
}

# --- 84.1-07 A6g: requestTrack (LMS asks for our material) ends the
# episode ---
{
    my $mac = 'aa:84:07:00:00:67';
    my ($ctl, $daemon, $ws) = _d02_setup($mac);
    local $Slim::Player::Source::PLAYMODE = 'play';
    foreign_track($mac, 'http://radio.example/1live-g6.mp3');
    eval { $ctl->leaveConnect('foreign-lms-content'); 1 };
    ok($ctl->observed->{leftConnectForeign}, "84.1-07 A6g setup: leftConnectForeign marker set");

    $ctl->requestTrack('spoton://track:84107a6gTestTrack00001', 0,
        { successCb => sub { }, errorCb => sub { } });

    ok(!exists($ctl->observed->{leftConnectForeign}),
        "84.1-07 A6g: requestTrack (LMS asks for our material) ends the episode -- marker gone");
}

# --- 84.1-07 A7: leaveConnect outside connect is a no-op ---
{
    my @A7_CASES = ( browse => 'aa:84:07:00:00:71', idle => 'aa:84:07:00:00:72' );
    while (my ($mode, $mac) = splice(@A7_CASES, 0, 2)) {
        @Plugins::SpotOn::Connect::CLAIMS = ();
        @Slim::Player::Client::EXECUTED   = ();
        my ($ctl, $daemon, $ws) = fresh_control(
            mac      => $mac,
            mode     => $mode,
            wanted   => { uri => $TID, playing => 1 },
            observed => { wsConnected => 1, meta => {}, track => $TID },
        );

        my $ok = eval { $ctl->leaveConnect('foreign-lms-content'); 1 };
        ok($ok, "84.1-07 A7 ($mode): leaveConnect callable outside connect");

        is($ctl->mode, $mode, "84.1-07 A7 ($mode): mode unchanged");
        is_deeply($ctl->wanted, { uri => $TID, playing => 1 }, "84.1-07 A7 ($mode): wanted unchanged");
        is_deeply($ws->sent, [], "84.1-07 A7 ($mode): nothing sent");
        is(scalar(@Plugins::SpotOn::Connect::CLAIMS), 0, "84.1-07 A7 ($mode): no claim call");
        ok(!exists($ctl->observed->{leftConnectForeign}), "84.1-07 A7 ($mode): no leftConnectForeign marker set");
    }
}

# ==================================================================
# 84.1-08 (WR-01, WR-04, IN-04)
# ==================================================================

# --- 84.1-08 W1a (WR-01, D-01): from the stop-leave state (mode idle,
# leftBrowseUri set), an is_active:0 device_changed clears the marker in
# ANY mode -- pre-fix it stays ---
{
    my ($ctl, $daemon, $ws, $X) = _84102_a1_state('aa:84:08:00:01:a1');
    ok(defined($ctl->observed->{leftBrowseUri}), "84.1-08 W1a setup: leftBrowseUri set by the stop-leave");
    is($ctl->mode, 'idle', "84.1-08 W1a setup: mode idle");

    $ctl->onEvent({ type => 'device_changed', is_active => 0 });

    ok(!exists($ctl->observed->{leftBrowseUri}), "84.1-08 W1a: leftBrowseUri cleared by an any-mode is_active:0");
}

# --- 84.1-08 W1b (WR-01): a reconnect adoption (CR-02 frame) also clears
# leftBrowseUri, same line as the mode('connect') write -- pre-fix it
# stays ---
{
    my ($ctl, $daemon, $ws, $X) = _84102_a1_state('aa:84:08:00:01:b1');
    ok(defined($ctl->observed->{leftBrowseUri}), "84.1-08 W1b setup: leftBrowseUri set by the stop-leave");

    {
        local $Slim::Player::Source::PLAYMODE = 'stop';
        $ctl->onEvent({ type => 'playback_state', item => { uri => $TID }, status => 'playing', is_active => 1 });
    }

    is($ctl->mode, 'connect', "84.1-08 W1b: the reconnect adoption lands (mode connect)");
    ok(!exists($ctl->observed->{leftBrowseUri}), "84.1-08 W1b: leftBrowseUri cleared by the reconnect adoption");
}

# --- 84.1-08 W1c (WR-01, the consequence): continue W1b -- after
# leaveConnect, a foreign track_changed produces no pause and no autoplay
# ring entry, because the stale marker no longer re-arms the idle guard
# (pre-fix: a pause is sent) ---
{
    my ($ctl, $daemon, $ws, $X) = _84102_a1_state('aa:84:08:00:01:c1');
    {
        local $Slim::Player::Source::PLAYMODE = 'stop';
        $ctl->onEvent({ type => 'playback_state', item => { uri => $TID }, status => 'playing', is_active => 1 });
    }
    is($ctl->mode, 'connect', "84.1-08 W1c setup: reconnect adoption landed");

    eval { $ctl->leaveConnect('foreign-lms-content'); 1 };
    is($ctl->mode, 'idle', "84.1-08 W1c setup: leaveConnect landed (mode idle)");
    @{ $ws->sent } = ();

    my $Z = 'spotify:track:84108W1cforeignZXXXXX';
    $ctl->onEvent({ type => 'track_changed', item => { uri => $Z } });

    is_deeply($ws->sent, [],
        "84.1-08 W1c: no pause sent -- the stale leftBrowseUri marker no longer re-arms the idle guard");
    my @mine = grep { ($_->[3] // '') eq $daemon->mac . ':autoplay:' . $Z } @Plugins::SpotOn::Status::RECORDED;
    is(scalar(@mine), 0, "84.1-08 W1c: no autoplay:<uri> ring entry recorded");
}

# --- 84.1-08 L1 (WR-04, D-04): loggedOutAt stamps only on a genuine
# logged_in 1->0 transition ---
{
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:84:08:00:01:l1');

    $ctl->onEvent({ type => 'auth_state', logged_in => 1 });
    ok(!exists($ctl->observed->{loggedOutAt}), "84.1-08 L1a: no loggedOutAt after a logged_in true frame");

    my $before = Time::HiRes::time();
    $ctl->onEvent({ type => 'auth_state', logged_in => 0 });
    my $after = Time::HiRes::time();

    ok(defined($ctl->observed->{loggedOutAt}), "84.1-08 L1b: loggedOutAt set by the 1->0 transition");
    ok(($ctl->observed->{loggedOutAt} >= $before - 0.01 && $ctl->observed->{loggedOutAt} <= $after + 2),
        "84.1-08 L1b: loggedOutAt is a number within 2s of now");

    $ctl->observed->{loggedOutAt} = 12345;
    $ctl->onEvent({ type => 'auth_state', logged_in => 0 });
    is($ctl->observed->{loggedOutAt}, 12345, "84.1-08 L1c: a second logged_in false (0->0) does not restamp");
}

# --- 84.1-08 L1d: a fresh Control that never saw logged_in gets no
# loggedOutAt on its first logged_in false (undef->0 never stamps) ---
{
    my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:84:08:00:01:l1d');
    $ctl->onEvent({ type => 'auth_state', logged_in => 0 });
    ok(!exists($ctl->observed->{loggedOutAt}), "84.1-08 L1d: undef->0 does not stamp loggedOutAt");
}

# --- 84.1-08 A6h (IN-04, D-02): leaveConnect with no WS connection still
# ends the episode cleanly and does not die; the INFO line itself is
# pinned by t/37 G11 (INFOLOG is a constant 0 in this file) ---
{
    @Plugins::SpotOn::Connect::CLAIMS = (); $Plugins::SpotOn::Connect::ACTIVE = undef;
    @Slim::Player::Client::EXECUTED   = ();
    my $mac = 'aa:84:08:00:01:a6h';
    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => $mac,
        mode     => 'connect',
        wanted   => { uri => $TID, playing => 1 },
        observed => {
            wsConnected => 0, meta => {}, track => $TID, status => 'playing',
            is_active   => 1, startEmittedFor => $TID,
        },
    );

    my $ok = eval { $ctl->leaveConnect('foreign-lms-content'); 1 };
    ok($ok, "84.1-08 A6h: leaveConnect callable with no WS connection (does not die)");

    is($ctl->mode, 'idle', "84.1-08 A6h: mode idle after leaveConnect");
    is_deeply($ctl->wanted, {}, "84.1-08 A6h: wanted cleared");
    ok($ctl->observed->{leftConnectForeign}, "84.1-08 A6h: leftConnectForeign marker set");
    is(scalar(@Plugins::SpotOn::Connect::CLAIMS), 1, "84.1-08 A6h: exactly one claim call recorded");
    is_deeply($Plugins::SpotOn::Connect::CLAIMS[0], [ 'release', $mac, 'foreign-lms-content', 0 ],
        "84.1-08 A6h: [ 'release', mac, 'foreign-lms-content', 0 ]");
}

# ============================================================
# 84-17 Task 1 -- the shim's `via` reaches Connect (tracer). V-a .. V-i.
#
# The audio shim (fake-libpulse) answers `POST /boundary` with its own
# classification of a title change (`via=live` = the old title was still
# being streamed = a natural end; `departed` = the old client was already
# closed by a skip's flush; `none`). In mode=connect Control now READS that
# reply -- through Slim::Networking::Select, never blocking -- before it
# emits `change`, which carries the via as the wire's 4th positional; every
# verb that arrives while the reply is pending is queued behind the
# `change` (wire order `change ... <via>` first).
#
# Narrowing of the CR-05 Fall B contract (@SYSREAD_CALLS "must stay empty",
# :389-390 / :1835-1844) -- stated here because it is deliberate:
# `_loopbackPost`, `_armSync` and the fire-and-forget `_postBoundary`
# callers still never read a response. `_postBoundaryRead` reads BY DESIGN
# (one non-blocking sysread per Select callback); the reply is delivered by
# the test through the recorded callback.
#
# `Slim::Networking::Select` is stubbed from a SEPARATE directory that is
# put on @INC only here, at the end of the file: Control `require`s it
# lazily, so every case above this block ran against the
# 'unavailable' (fire-and-forget) path exactly as before this plan.
# ============================================================
{
    my $sel_dir = tempdir(CLEANUP => 1);
    write_stub($sel_dir, 'Slim::Networking::Select', <<'END');
package Slim::Networking::Select;
our @READS;      # [ $sock, $cb ] per addRead, in call order
our @REMOVED;    # every socket removeRead() was called with
sub addRead    { my ($sock, $cb) = @_; push @READS, [ $sock, $cb ]; return; }
sub removeRead {
    my ($sock) = @_;
    push @REMOVED, $sock;
    @READS = grep { $_->[0] != $sock } @READS;
    return;
}
# Deliver the scripted reply to the OLDEST registered read callback.
sub deliver { my ($r) = @READS; $r->[1]->($r->[0]) if $r; return $r ? 1 : 0; }
1;
END
    unshift @INC, $sel_dir;
    # Control's earlier lazy `require` failed (no such module on @INC then);
    # Perl caches a failed require as `Attempt to reload ... aborted`.
    delete $INC{'Slim/Networking/Select.pm'};
    require Slim::Networking::Select;

    my $PREV = 'spotify:track:prevTrackId0000000001';
    my $NEXT = 'spotify:track:nextTrackId0000000002';
    my $NEX2 = 'spotify:track:thirdTrackId000000003';
    my ($PREVID, $NEXTID, $NEX2ID) = ('prevTrackId0000000001', 'nextTrackId0000000002', 'thirdTrackId000000003');

    my $reply = sub {
        my ($via, %o) = @_;
        my $body = "via=$via boundary=" . ($o{boundary} // 75169288) . " anchor=" . ($o{anchor} // 'drain')
            . " ring_fill=487696 total_pushed=75706136 total_popped=75169288 drops=0 gen=1\n";
        return "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: " . length($body)
            . "\r\nConnection: close\r\n\r\n$body";
    };
    my $reset = sub {
        @Slim::Player::Client::EXECUTED   = ();
        @IO::Socket::INET::CALLS          = ();
        @IO::Socket::INET::REQUESTS       = ();
        @IO::Socket::INET::SYSWRITE_CALLS = ();
        @IO::Socket::INET::SYSREAD_CALLS  = ();
        $IO::Socket::INET::FAIL           = 0;
        $IO::Socket::INET::READ_REPLY     = undef;
        @Slim::Networking::Select::READS   = ();
        @Slim::Networking::Select::REMOVED = ();
        @Slim::Utils::Timers::TIMERS      = ();
        @Slim::Utils::Log::WARNINGS       = ();
    };
    my $connect_ctl = sub {
        my (%o) = @_;
        my ($ctl, $daemon, $ws) = fresh_control(
            mac  => ($o{mac} // 'aa:84:17:00:00:01'),
            mode => ($o{mode} // 'connect'),
            observed => {
                wsConnected => 1, meta => {}, track => $PREV, status => 'playing',
                is_active => 1, startEmittedFor => $PREV,
                anchor => { position_ms => 100000, timestamp_ms => 1, speed => 1,
                            seen_at => time(), seen_hr => Time::HiRes::time() },
            },
        );
        return ($ctl, $daemon, $ws);
    };
    my $tc = sub { return { type => 'track_changed', item => { uri => $_[0] } }; };

    # The harness' Slim::Utils::Prefs stub answers enableSpotifyConnect=1.

    # -- V-a: reply via=live -> `change <id> <prev> live`, NOTHING before the reply ---
    {
        $reset->();
        my ($ctl, $daemon, $ws) = $connect_ctl->();
        $ctl->onEvent($tc->($NEXT));
        is(scalar(@Slim::Player::Client::EXECUTED), 0,
            "84-17 V-a: nothing is emitted before the shim's reply arrives (the change is pending)");
        is(scalar(@Slim::Networking::Select::READS), 1, "84-17 V-a: exactly one Select read registered");
        ok($ctl->observed->{pendingChange}, "84-17 V-a: the change is held as the pending change");
        $IO::Socket::INET::READ_REPLY = $reply->('live');
        Slim::Networking::Select::deliver();
        is_deeply([ @Slim::Player::Client::EXECUTED ],
            [ [ 'spottyconnect', 'change', $NEXTID, $PREVID, 'live' ] ],
            "84-17 V-a: reply via=live -> `spottyconnect change <id> <prev> live`");
        ok(!$ctl->observed->{pendingChange}, "84-17 V-a: no pending change left after the reply");
        is(scalar(@Slim::Networking::Select::READS), 0, "84-17 V-a: the read watcher was removed");
        is(scalar(grep { $_->[1] < Time::HiRes::time() + 5 } @Slim::Utils::Timers::TIMERS), 0,
            "84-17 V-a: the cap timer was killed (only the 10 s connect watchdog of the emitted change remains)");
        is(scalar(grep { m{^POST /boundary\?anchor=drain HTTP/1.0} } @IO::Socket::INET::SYSWRITE_CALLS), 1,
            "84-17 V-a: the connect-mode post asks for the drain anchor");
    }

    # -- V-b: reply via=departed -> `... departed` ---
    {
        $reset->();
        my ($ctl, $daemon, $ws) = $connect_ctl->();
        $ctl->onEvent($tc->($NEXT));
        $IO::Socket::INET::READ_REPLY = $reply->('departed', anchor => 'pushed');
        Slim::Networking::Select::deliver();
        is_deeply([ @Slim::Player::Client::EXECUTED ],
            [ [ 'spottyconnect', 'change', $NEXTID, $PREVID, 'departed' ] ],
            "84-17 V-b: reply via=departed -> `spottyconnect change <id> <prev> departed`");
    }

    # -- V-c: no reply -> after the cap timer: `... timeout` ---
    {
        $reset->();
        my ($ctl, $daemon, $ws) = $connect_ctl->();
        $ctl->onEvent($tc->($NEXT));
        is(scalar(@Slim::Utils::Timers::TIMERS), 1, "84-17 V-c: the cap timer is armed");
        my $CAP = Plugins::SpotOn::Soloist::Control->can('BOUNDARY_REPLY_CAP_S')
            ? Plugins::SpotOn::Soloist::Control->BOUNDARY_REPLY_CAP_S : -1;
        ok(@Slim::Utils::Timers::TIMERS && abs($Slim::Utils::Timers::TIMERS[0][1] - (Time::HiRes::time() + $CAP)) < 0.5,
            "84-17 V-c: the cap is BOUNDARY_REPLY_CAP_S (0.3 s) away");
        is($CAP, 0.3, "84-17 V-c: BOUNDARY_REPLY_CAP_S is 0.3");
        is(scalar(@Slim::Player::Client::EXECUTED), 0, "84-17 V-c: still nothing emitted before the cap");
        Slim::Utils::Timers::fire_due(Time::HiRes::time() + 1);
        is_deeply([ @Slim::Player::Client::EXECUTED ],
            [ [ 'spottyconnect', 'change', $NEXTID, $PREVID, 'timeout' ] ],
            "84-17 V-c: no reply within the cap -> `spottyconnect change <id> <prev> timeout`");
        is(scalar(@Slim::Networking::Select::READS), 0, "84-17 V-c: the read watcher was removed by the cap");
        ok(scalar(grep { /Control: boundary reply via=timeout/ } @Slim::Utils::Log::WARNINGS),
            "84-17 V-c: the timeout is logged (warn, `Control: boundary reply via=timeout`)");
    }

    # -- V-d: a second foreign track_changed for a DIFFERENT uri during the wait ---
    {
        $reset->();
        my ($ctl, $daemon, $ws) = $connect_ctl->();
        $ctl->onEvent($tc->($NEXT));
        is(scalar(@Slim::Player::Client::EXECUTED), 0, "84-17 V-d: the first change is pending");
        $ctl->onEvent($tc->($NEX2));
        is_deeply([ @Slim::Player::Client::EXECUTED ],
            [ [ 'spottyconnect', 'change', $NEXTID, $PREVID, 'unknown' ] ],
            "84-17 V-d: the first change resolves `unknown` IMMEDIATELY when a different uri arrives");
        ok($ctl->observed->{pendingChange} && $ctl->observed->{pendingChange}{id} eq $NEX2ID,
            "84-17 V-d: the second change is now THE pending one (exactly one per Control)");
        is(scalar(@Slim::Networking::Select::READS), 1, "84-17 V-d: the first wait was aborted, only the second read is registered");
        $IO::Socket::INET::READ_REPLY = $reply->('live');
        Slim::Networking::Select::deliver();
        is_deeply([ @Slim::Player::Client::EXECUTED ],
            [ [ 'spottyconnect', 'change', $NEXTID, $PREVID, 'unknown' ],
              [ 'spottyconnect', 'change', $NEX2ID, $NEXTID, 'live' ] ],
            "84-17 V-d: the second change waits for its OWN reply and carries it; no duplicate");
    }

    # -- V-e: send order unchanged: the /boundary write happens inside the frame handler,
    #         before a later /seek-arm write ---
    {
        $reset->();
        my ($ctl, $daemon, $ws) = $connect_ctl->();
        $ctl->onEvent($tc->($NEXT));
        is(scalar(@IO::Socket::INET::SYSWRITE_CALLS), 1, "84-17 V-e: the boundary write happened inside the frame handler call");
        like($IO::Socket::INET::SYSWRITE_CALLS[0], qr{^POST /boundary\?anchor=drain HTTP/1\.0\r\nConnection: close\r\n\r\n\z},
            "84-17 V-e: the send is the unchanged single `POST /boundary` request (plus the query)");
        # a later arm in the same tick (the daemon is on NEXT, request a different uri)
        $ctl->_armSync;    # a later sync arm in the same tick (write-only, byte-identical send)
        my @idx = grep { $IO::Socket::INET::SYSWRITE_CALLS[$_] =~ m{^POST /seek-arm} } 0 .. $#IO::Socket::INET::SYSWRITE_CALLS;
        ok(@idx && $idx[0] > 0, "84-17 V-e: a later /seek-arm write comes AFTER the /boundary write");
    }

    # -- V-f: the connect fails -> `unknown` synchronously, logged once ---
    {
        $reset->();
        my ($ctl, $daemon, $ws) = $connect_ctl->();
        $IO::Socket::INET::FAIL = 1;
        $ctl->onEvent($tc->($NEXT));
        $IO::Socket::INET::FAIL = 0;
        is_deeply([ @Slim::Player::Client::EXECUTED ],
            [ [ 'spottyconnect', 'change', $NEXTID, $PREVID, 'unknown' ] ],
            "84-17 V-f: a failed connect emits `unknown` synchronously (degrade open, T-77-10 lineage)");
        is(scalar(grep { /Control: boundary reply via=unknown reason=send_failed/ } @Slim::Utils::Log::WARNINGS), 1,
            "84-17 V-f: and logs it exactly once");
        is(scalar(@Slim::Networking::Select::READS), 0, "84-17 V-f: nothing was registered for reading");
    }

    # -- V-g: track_changed + position_sync(0, speed 0) within the cap: wire order
    #         `change ... live` THEN `seek ... deferred` ---
    {
        $reset->();
        my ($ctl, $daemon, $ws) = $connect_ctl->();
        $ctl->onEvent($tc->($NEXT));
        $ctl->onEvent({ type => 'position_sync', position => { position_ms => 500, timestamp_ms => 2, speed => 0 } });
        is(scalar(@Slim::Player::Client::EXECUTED), 0, "84-17 V-g: the echo seek does not overtake the pending change");
        is(scalar(@{ $ctl->observed->{pendingChange}{queued} }), 1, "84-17 V-g: the seek is queued behind it");
        $IO::Socket::INET::READ_REPLY = $reply->('live');
        Slim::Networking::Select::deliver();
        is_deeply([ @Slim::Player::Client::EXECUTED ],
            [ [ 'spottyconnect', 'change', $NEXTID, $PREVID, 'live' ],
              [ 'spottyconnect', 'seek', '0.500', '', 'deferred' ] ],
            "84-17 V-g: wire order `change ... live` THEN `seek ... deferred`, never the seek first, never `unknown`");
    }

    # -- V-h: playback_changed paused within the cap -> queued, never `unknown` ---
    {
        $reset->();
        my ($ctl, $daemon, $ws) = $connect_ctl->();
        $ctl->onEvent($tc->($NEXT));
        $ctl->onEvent({ type => 'playback_changed', status => 'paused' });
        is(scalar(@Slim::Player::Client::EXECUTED), 0, "84-17 V-h: the pause does not overtake the pending change");
        $IO::Socket::INET::READ_REPLY = $reply->('live');
        Slim::Networking::Select::deliver();
        is_deeply([ @Slim::Player::Client::EXECUTED ],
            [ [ 'spottyconnect', 'change', $NEXTID, $PREVID, 'live' ],
              [ 'spottyconnect', 'stop', '', '' ] ],
            "84-17 V-h: `playback_changed paused` is queued: wire order `change ... live` then `stop`, never `unknown`");
    }

    # -- V-i: mode=browse: the reply is read and logged only; nothing waits, nothing is emitted ---
    {
        $reset->();
        my ($ctl, $daemon, $ws) = $connect_ctl->(mode => 'browse', mac => 'aa:84:17:00:00:09');
        $ctl->onEvent($tc->($NEXT));
        is(scalar(grep { m{^POST /boundary\?anchor=drain HTTP/1.0} } @IO::Socket::INET::SYSWRITE_CALLS), 1,
            "84-17 V-i (79-31 D-26): browse posts /boundary?anchor=drain (the drained end of the old title)");
        is(scalar(grep { m{^POST /boundary HTTP/1.0} } @IO::Socket::INET::SYSWRITE_CALLS), 0, "84-17 V-i (79-31 D-26): browse no longer posts the plain /boundary");
        ok(!$ctl->observed->{pendingChange}, "84-17 V-i: browse holds no pending change");
        is(scalar(@Slim::Player::Client::EXECUTED), 0, "84-17 V-i: browse emits nothing");
        is(scalar(@Slim::Networking::Select::READS), 1, "84-17 V-i: the reply is still read");
        $IO::Socket::INET::READ_REPLY = $reply->('live');
        Slim::Networking::Select::deliver();
        is(scalar(@Slim::Networking::Select::READS), 0, "84-17 V-i: the reply was consumed (watcher removed)");
        is(scalar(@Slim::Player::Client::EXECUTED), 0, "84-17 V-i: still nothing emitted after the reply");
        is(scalar(@{ $ctl->observed->{pendingChange}{queued} // [] }), 0, "84-17 V-i: no queue in browse");
    }

    # -- 79-31 D-26 (STUTTER-SOLO): a browse natural title end asks for the drain anchor ---
    # 79-30 control run: `boundary_planted ... via=live anchor=pushed` planted the boundary
    # 1.75 s inside the next title, so the old stream carried the first 1.75 s of it.
    {
        $reset->();
        my ($ctl, $daemon, $ws) = $connect_ctl->(mode => 'browse', mac => 'aa:79:31:00:00:01');
        $ctl->onEvent($tc->($NEXT));
        is(scalar(grep { m{^POST /boundary\?anchor=drain HTTP/1\.0} } @IO::Socket::INET::SYSWRITE_CALLS), 1,
            "79-31 D-26: browse natural title end writes exactly one POST /boundary?anchor=drain");
        is(scalar(grep { m{^POST /boundary HTTP/1\.0} } @IO::Socket::INET::SYSWRITE_CALLS), 0,
            "79-31 D-26: browse natural title end writes no plain POST /boundary");
    }
    {
        $reset->();
        my ($ctl, $daemon, $ws) = $connect_ctl->(mode => 'idle', mac => 'aa:79:31:00:00:02');
        $ctl->onEvent($tc->($NEXT));
        is(scalar(grep { m{^POST /boundary\?anchor=drain HTTP/1\.0} } @IO::Socket::INET::SYSWRITE_CALLS), 1,
            "79-31 D-26: idle frame writes exactly one POST /boundary?anchor=drain");
        is(scalar(grep { m{^POST /boundary HTTP/1\.0} } @IO::Socket::INET::SYSWRITE_CALLS), 0,
            "79-31 D-26: idle frame writes no plain POST /boundary");
    }
    {
        $reset->();
        my ($ctl, $daemon, $ws) = $connect_ctl->(mode => 'browse', mac => 'aa:79:31:00:00:03');
        $ctl->onEvent($tc->($NEXT));
        $IO::Socket::INET::READ_REPLY = $reply->('live');
        Slim::Networking::Select::deliver();
        ok(!$ctl->observed->{pendingChange}, "79-31 D-26: browse with the drain path still holds no pending change");
        is(scalar(@Slim::Player::Client::EXECUTED), 0, "79-31 D-26: browse with the drain path still emits nothing");
        is(scalar(@Slim::Networking::Select::READS), 0,
            "79-31 D-26: browse with the drain path - the reply was read once and the watcher removed");
    }
    {
        # the skip/stop path (_postBoundary) is not a natural end: it keeps the plain /boundary
        $reset->();
        my ($ctl, $daemon, $ws) = fresh_control(
            mac => 'aa:79:31:00:00:04', mode => 'idle',
            observed => { wsConnected => 1, meta => {}, is_active => 0 },
        );
        $ctl->onEvent({ type => 'playback_changed', status => 'stopped' });
        is(scalar(grep { m{^POST /boundary HTTP/1\.0} } @IO::Socket::INET::SYSWRITE_CALLS), 1,
            "79-31 D-26: the skip/stop path stays plain (one POST /boundary, no anchor)");
        is(scalar(grep { m{anchor=} } @IO::Socket::INET::SYSWRITE_CALLS), 0,
            "79-31 D-26: the skip/stop path asks for no anchor");
    }

    # -- 79-31 D-26 (done in 79-38 Task 2): the two other browse callers post the drain path too ---
    {
        # _maybeContextEnd: paused at 0 on the same uri, near the title end, no queue, no seek intent
        $reset->();
        my $CE = 'spotify:track:2374M0fQpWi3dLnB54qaLX';
        my ($ctl, $daemon, $ws) = fresh_control(
            mac => 'aa:79:31:00:00:05', mode => 'browse',
            wanted   => { uri => $CE, playing => 1 },
            observed => { wsConnected => 1, meta => { $CE => { duration => 295.282 } }, track => $CE, status => 'paused',
                          is_active => 1, paired => 1,
                          anchor => { position_ms => 0, timestamp_ms => 1, speed => 0, seen_at => time(), seen_hr => Time::HiRes::time() },
                          preResetAnchor => { uri => $CE, position_ms => 294000, speed => 0 } },
        );
        $ctl->_maybeContextEnd;
        is(scalar(grep { m{^POST /boundary\?anchor=drain HTTP/1\.0} } @IO::Socket::INET::SYSWRITE_CALLS), 1,
            "79-31 D-26: browse context end (_maybeContextEnd) writes exactly one POST /boundary?anchor=drain");
        is(scalar(grep { m{^POST /boundary HTTP/1\.0} } @IO::Socket::INET::SYSWRITE_CALLS), 0,
            "79-31 D-26: browse context end writes no plain POST /boundary");
        is($ctl->observed->{contextEndPlanted}, $CE, "79-31 D-26: browse context end still marks contextEndPlanted");
    }
    {
        # _onQueueHeadReplay: the daemon consumed its queue head and restarted the playing title
        $reset->();
        my $QR = 'spotify:track:6d0cIiukgZJ8fZBJFqDMBT';
        my ($ctl, $daemon, $ws) = fresh_control(
            mac => 'aa:79:31:00:00:06', mode => 'browse',
            wanted   => { uri => $QR, playing => 1 },
            observed => { wsConnected => 1, meta => {}, track => $QR, status => 'playing', is_active => 1 },
        );
        $ctl->_onQueueHeadReplay({ uri => $QR });
        is(scalar(grep { m{^POST /boundary\?anchor=drain HTTP/1\.0} } @IO::Socket::INET::SYSWRITE_CALLS), 1,
            "79-31 D-26: browse queue-head replay writes exactly one POST /boundary?anchor=drain");
        is(scalar(grep { m{^POST /boundary HTTP/1\.0} } @IO::Socket::INET::SYSWRITE_CALLS), 0,
            "79-31 D-26: browse queue-head replay writes no plain POST /boundary");
        is_deeply([ grep { $_->[0] eq 'pause' } @{ $ws->sent } ], [ [ 'pause', {} ] ],
            "79-31 D-26: browse queue-head replay still pauses the daemon once");
    }

    # -- 79 D-31 (79-38): a transition into `playing` from paused or buffering on the SAME title posts one
    # POST /hold-release; a title change, stopped, idle without a session and a missing daemon never do. ---
    {
        my $hr_wire = qr{^POST /hold-release HTTP/1\.0\r\nConnection: close\r\n\r\n\z};
        my $hrs = sub { return scalar(grep { $_ =~ $hr_wire } @IO::Socket::INET::SYSWRITE_CALLS); };
        my $pc  = sub { return { type => 'playback_changed', status => $_[0] }; };
        my $ps  = sub {
            my ($st, $uri, $pos) = @_;
            return { type => 'playback_state', status => $st,
                     (defined $uri ? (item => { uri => $uri }) : ()),
                     position => { position_ms => ($pos // 1000), timestamp_ms => 1791000000000, speed => ($st eq 'playing' ? 1 : 0) } };
        };
        my $hold_ctl = sub {
            my (%o) = @_;
            return fresh_control(
                mac => $o{mac}, mode => ($o{mode} // 'browse'),
                (exists $o{streamPort} ? (streamPort => $o{streamPort}) : ()),
                observed => { wsConnected => 1, meta => {}, track => $PREV, status => ($o{status} // 'playing'),
                              is_active => ($o{is_active} // 1), %{ $o{observed} || {} } },
            );
        };

        # D-31 resume after a pause, playback_changed reports it
        $reset->();
        my ($c1, $d1, $w1) = $hold_ctl->(mac => 'aa:79:38:00:00:01');
        $c1->onEvent($pc->('paused'));
        is($hrs->(), 0, "79-38 D-31: the pause itself posts no release");
        $c1->onEvent($pc->('playing'));
        is($hrs->(), 1, "79-38 D-31: browse, paused on X, playback_changed playing -> exactly one POST /hold-release");

        # resume reported by playback_state first
        $reset->();
        my ($c2, $d2, $w2) = $hold_ctl->(mac => 'aa:79:38:00:00:02');
        $c2->onEvent($ps->('paused', $PREV, 5000));
        $c2->onEvent($ps->('playing', $PREV, 5000));
        is($hrs->(), 1, "79-38 D-31: browse, paused on X, playback_state playing on X -> exactly one post");

        # one resume reported by both frames
        $reset->();
        my ($c3, $d3, $w3) = $hold_ctl->(mac => 'aa:79:38:00:00:03');
        $c3->onEvent($pc->('paused'));
        $c3->onEvent($pc->('playing'));
        $c3->onEvent($ps->('playing', $PREV, 5100));
        is($hrs->(), 1, "79-38 D-31: one resume reported by both frames (playback_changed, then playback_state) -> exactly one post");

        # connect: the release is sent and the Connect resume emit is unchanged
        $reset->();
        my ($c4, $d4, $w4) = $connect_ctl->(mode => 'connect', mac => 'aa:79:38:00:00:04');
        $c4->onEvent($pc->('paused'));
        $c4->onEvent($pc->('playing'));
        # 79-51 runaway D1: the resume is released by the frame that decides it (the same-title playback_state of the
        # same millisecond, E3); the playing frame alone only holds it. Contract unchanged: one post, one resume.
        $c4->onEvent($ps->('playing', $PREV, 5000));
        is($hrs->(), 1, "79-38 D-31: connect, paused on X, playback_changed playing -> exactly one post");
        is(scalar(grep { $_->[1] eq 'resume' } @Slim::Player::Client::EXECUTED), 1,
            "79-38 D-31: connect: the Connect `resume` emit is unchanged");

        # a title change is not a resume
        $reset->();
        my ($c5, $d5, $w5) = $hold_ctl->(mac => 'aa:79:38:00:00:05');
        $c5->onEvent($pc->('paused'));
        $c5->onEvent($ps->('playing', $NEXT, 0));
        is($hrs->(), 0, "79-38 D-31: paused on X, playback_state playing with item.uri Y (a title change) -> no release");

        # stopped -> playing, playing -> playing
        $reset->();
        my ($c6, $d6, $w6) = $hold_ctl->(mac => 'aa:79:38:00:00:06');
        $c6->onEvent($pc->('stopped'));
        $c6->onEvent($pc->('playing'));
        is($hrs->(), 0, "79-38 D-31: stopped -> playing posts no release");
        $reset->();
        my ($c7, $d7, $w7) = $hold_ctl->(mac => 'aa:79:38:00:00:07');
        $c7->onEvent($pc->('playing'));
        $c7->onEvent($ps->('playing', $PREV, 9000));
        is($hrs->(), 0, "79-38 D-31: playing -> playing posts no release");

        # idle without an active session
        $reset->();
        my ($c8, $d8, $w8) = $hold_ctl->(mac => 'aa:79:38:00:00:08', mode => 'idle', is_active => 0, status => 'idle');
        $c8->onEvent($pc->('paused'));
        $c8->onEvent($pc->('playing'));
        $c8->onEvent($ps->('paused', $PREV, 5000));
        $c8->onEvent($ps->('playing', $PREV, 5000));
        is($hrs->(), 0, "79-38 D-31: idle without an active session posts no release (both frame types)");

        # no daemon, no stream port: no post and no die
        $reset->();
        my ($c9, $d9, $w9) = $hold_ctl->(mac => 'aa:79:38:00:00:09', streamPort => 0);
        $c9->onEvent($pc->('paused'));
        ok(eval { $c9->onEvent($pc->('playing')); 1 }, "79-38 D-31: no stream port: the frame handler does not die") or diag($@);
        is(scalar(@IO::Socket::INET::SYSWRITE_CALLS), 0, "79-38 D-31: no stream port -> nothing is written");
        my ($c10, $d10, $w10) = $hold_ctl->(mac => 'aa:79:38:00:00:0a');
        undef $d10; undef $w10;
        $reset->();
        ok(eval { $c10->_postHoldRelease; 1 }, "79-38 D-31: no daemon -> _postHoldRelease does not die") or diag($@);
        is(scalar(@IO::Socket::INET::SYSWRITE_CALLS), 0, "79-38 D-31: no daemon -> nothing is written");

        # a mid-track stall the daemon reports as buffering (no uri)
        $reset->();
        my ($c11, $d11, $w11) = $hold_ctl->(mac => 'aa:79:38:00:00:0b');
        $c11->onEvent($pc->('buffering'));
        $c11->onEvent($ps->('playing', $PREV, 7000));
        is($hrs->(), 1, "79-38 D-31: browse, playback_changed buffering (no uri) on X, then playback_state playing on X -> exactly one post");

        # connect: buffering -> playing
        $reset->();
        my ($c12, $d12, $w12) = $connect_ctl->(mode => 'connect', mac => 'aa:79:38:00:00:0c');
        $c12->onEvent($pc->('buffering'));
        $c12->onEvent($pc->('playing'));
        is($hrs->(), 1, "79-38 D-31: connect, buffering -> playing on X -> exactly one post");

        # a buffering frame that announces another title
        $reset->();
        my ($c13, $d13, $w13) = $hold_ctl->(mac => 'aa:79:38:00:00:0d');
        $c13->onEvent($ps->('buffering', $NEXT, 0));
        $c13->onEvent($ps->('playing', $NEXT, 0));
        is($hrs->(), 0, "79-38 D-31: playback_state buffering naming Y while on X, then playing on Y -> no post");

        # the real natural-end frame order: the drain POST is on the wire before the one release
        my $order = sub {
            my ($name, $ctl, @frames) = @_;
            my @w = @IO::Socket::INET::SYSWRITE_CALLS;
            my ($di) = grep { $w[$_] =~ m{^POST /boundary\?anchor=drain HTTP/1\.0} } 0 .. $#w;
            my ($hi) = grep { $w[$_] =~ $hr_wire } 0 .. $#w;
            return (defined $di && defined $hi && $di < $hi) ? 1 : 0;
        };
        {
            # REAL: t/fixtures/soloist/f18n4-bound1.frames (track_changed Y, playback_changed buffering,
            # queue_changed, playback_state buffering Y). APPENDED by this cell: the final playback_state playing Y.
            $reset->();
            my @f = map { decode_frame($_) } load_fixture('f18n4-bound1.frames');
            my $Y = $f[0]{item}{uri};
            my ($cn, $dn, $wn) = $hold_ctl->(mac => 'aa:79:38:00:00:0e', observed => { track => 'spotify:track:6d0cIiukgZJ8fZBJFqDMBT' });
            $cn->onEvent($_) for @f;
            is($hrs->(), 0, "79-38 D-31: bound1 natural end: no release before playing");
            $cn->onEvent($ps->('playing', $Y, 0));
            is($hrs->(), 1, "79-38 D-31: bound1 natural end (real frames, playing appended): exactly one POST /hold-release");
            ok($order->(), "79-38 D-31: bound1 natural end: POST /boundary?anchor=drain is on the wire before the release");
        }
        {
            # REAL: t/fixtures/soloist/s01-hearing-lavender-pa.jsonl from its first track_changed up to the first
            # playback_state buffering naming that title (a TITLE START from idle, not a natural end). The frames
            # before it (auth_state, idle, context_changed, device_changed is_active) put the control into connect
            # mode (the first boundary post of the full recording was the plain connect-start path), so they are left out to
            # keep this a browse cell. APPENDED by this cell: playback_state playing.
            $reset->();
            my @f;
            for my $t (load_fixture('s01-hearing-lavender-pa.jsonl')) {
                my $fr = decode_frame($t);
                next if !@f && $fr->{type} ne 'track_changed';
                push @f, $fr;
                last if $fr->{type} eq 'playback_state' && ($fr->{status} // '') eq 'buffering'
                    && ref($fr->{item}) eq 'HASH' && ($fr->{item}{uri} // '') eq $TID;
            }
            my ($cs, $ds, $wsx) = $hold_ctl->(mac => 'aa:79:38:00:00:0f', status => 'idle', observed => { track => undef });
            $cs->onEvent($_) for @f;
            is($hrs->(), 0, "79-38 D-31: s01 title start: no release before playing");
            $cs->onEvent($ps->('playing', $TID, 0));
            is($hrs->(), 1, "79-38 D-31: s01 title start (real frames, playing appended): exactly one POST /hold-release");
            ok($order->(), "79-38 D-31: s01 title start: POST /boundary?anchor=drain is on the wire before the release")
                or diag(explain([ map { (split /\r\n/, $_)[0] } @IO::Socket::INET::SYSWRITE_CALLS ]));
        }
    }

    # -- V-j (extra): the first track of a session (`start`) never waits ---
    {
        $reset->();
        my ($ctl, $daemon, $ws) = fresh_control(
            mac => 'aa:84:17:00:00:0a', mode => 'connect',
            observed => { wsConnected => 1, meta => {}, is_active => 1 },
        );
        $ctl->onEvent($tc->($NEXT));
        ok(!$ctl->observed->{pendingChange}, "84-17 V-j: a `start` (no change) holds no pending change");
        is(scalar(grep { $_->[1] eq 'start' } @Slim::Player::Client::EXECUTED), 1, "84-17 V-j: the start is emitted immediately");
        is(scalar(grep { m{^POST /boundary HTTP/1.0} } @IO::Socket::INET::SYSWRITE_CALLS), 1, "84-17 V-j: the plain path is used for a start");
    }

    # -- V-k (extra): shutdown during the wait drops the change (nothing emitted) and frees the watcher ---
    {
        $reset->();
        my ($ctl, $daemon, $ws) = $connect_ctl->(mac => 'aa:84:17:00:00:0b');
        $ctl->onEvent($tc->($NEXT));
        $ctl->shutdown;
        is(scalar(@Slim::Player::Client::EXECUTED), 0, "84-17 V-k: shutdown emits nothing for the dropped pending change");
        is(scalar(@Slim::Networking::Select::READS), 0, "84-17 V-k: shutdown removed the read watcher");
        is(scalar(@Slim::Utils::Timers::TIMERS), 0, "84-17 V-k: shutdown killed the cap timer");
    }

    # ==========================================================
    # 84-17 Task 2 -- Control's side of the hold (H-f, H-g, H-h).
    # A `live` change opens observed->{hold} (uri, since, max_at = since +
    # HOLD_MAX_S) at the moment _emit puts it on the wire; while it is open
    # every seek/resume carries `deferred` as the 4th positional; the
    # connect watchdog gets the EXTENDED deadline for it; _checkSplitBrain
    # stands down; the record dies with clearHold, a cancelling frame, or
    # expiry at max_at (NOT with LMS's requestTrack re-open, which cancels
    # the watchdog only).
    # ==========================================================
    my $now_hold = sub { return Time::HiRes::time(); };
    # (the `can` guards keep the pre-fix run reporting `not ok` lines instead of dying on the missing constant/method)
    my $HOLD_MAX = Plugins::SpotOn::Soloist::Control->can('HOLD_MAX_S') ? Plugins::SpotOn::Soloist::Control->HOLD_MAX_S : 180;
    my $open_hold = sub {
        # a pending change resolved with a live reply -> the hold is open
        my ($ctl) = @_;
        $ctl->onEvent($tc->($NEXT));
        $IO::Socket::INET::READ_REPLY = $reply->('live');
        Slim::Networking::Select::deliver();
    };

    # -- H-f: the queue/cancellation of Task 1, re-asserted together with the hold ---
    {
        $reset->();
        @Plugins::SpotOn::Status::RECORDED = ();
        my ($ctl, $daemon, $ws) = $connect_ctl->(mac => 'aa:84:17:00:00:f1');
        $ctl->onEvent($tc->($NEXT));
        $ctl->onEvent({ type => 'playback_changed', status => 'paused' });
        is(scalar(@Slim::Player::Client::EXECUTED), 0, "84-17 H-f: a pause during the pending reply is queued behind the change (never `unknown`)");
        $IO::Socket::INET::READ_REPLY = $reply->('live');
        Slim::Networking::Select::deliver();
        is_deeply([ @Slim::Player::Client::EXECUTED ],
            [ [ 'spottyconnect', 'change', $NEXTID, $PREVID, 'live' ], [ 'spottyconnect', 'stop', '', '' ] ],
            "84-17 H-f: wire order `change ... live` then `stop`");
        ok($ctl->observed->{hold} && $ctl->observed->{hold}{uri} eq $NEXT,
            "84-17 H-f: the `live` change opened the hold record for the changed title");
        ok($ctl->observed->{hold} && abs($ctl->observed->{hold}{max_at} - ($now_hold->() + $HOLD_MAX)) < 1.5,
            "84-17 H-f: max_at = since + HOLD_MAX_S");

        # a second track_changed for a DIFFERENT uri resolves the pending one `unknown` -- and `unknown` opens no hold
        $reset->();
        my ($c2, $d_c2, $w_c2) = $connect_ctl->(mac => 'aa:84:17:00:00:f2');
        $c2->onEvent($tc->($NEXT));
        $c2->onEvent($tc->($NEX2));
        is_deeply([ @Slim::Player::Client::EXECUTED ], [ [ 'spottyconnect', 'change', $NEXTID, $PREVID, 'unknown' ] ],
            "84-17 H-f: a different-uri track_changed resolves the pending change `unknown` immediately");
        ok(!$c2->observed->{hold}, "84-17 H-f: an `unknown` change opens NO hold");
        $IO::Socket::INET::READ_REPLY = $reply->('live');
        Slim::Networking::Select::deliver();
        ok($c2->observed->{hold} && $c2->observed->{hold}{uri} eq $NEX2, "84-17 H-f: the second change (live) opens the hold for ITS title");
    }

    # -- H-g: neither rung re-emits inside a hold ---
    {
        # g1: the connect watchdog of a `live` change carries the EXTENDED deadline; firing timers 11 s .. 185 s
        #     after the change must NOT call _connectResync('watchdog') (no nachziehen change, no errors[] entry).
        #     Pre-fix (Task 1 state): the 10 s watchdog fires and emits `change` WITHOUT via.
        local $Slim::Player::Source::PLAYMODE = 'stop';
        $reset->();
        @Plugins::SpotOn::Status::RECORDED = ();
        my ($ctl, $daemon, $ws) = $connect_ctl->(mac => 'aa:84:17:00:00:91');
        $ctl->wanted({ uri => $PREV, playing => 1 });
        $open_hold->($ctl);
        my ($wd) = grep { $_->[2] == \&Plugins::SpotOn::Soloist::Control::_watchdogRound2 } @Slim::Utils::Timers::TIMERS;
        ok($wd, "84-17 H-g g1: the live change armed the connect watchdog");
        my $window = $HOLD_MAX + Plugins::SpotOn::Soloist::Control->CONNECT_WATCHDOG_S;
        ok($wd && abs($wd->[1] - ($now_hold->() + $window)) < 1.5,
            "84-17 H-g g1: ... with the EXTENDED deadline HOLD_MAX_S + CONNECT_WATCHDOG_S (190 s), not 10 s");
        my $before = scalar(@Slim::Player::Client::EXECUTED);
        Slim::Utils::Timers::fire_due($now_hold->() + 11);
        Slim::Utils::Timers::fire_due($now_hold->() + 100);
        Slim::Utils::Timers::fire_due($now_hold->() + 185);
        is(scalar(@Slim::Player::Client::EXECUTED), $before,
            "84-17 H-g g1: nothing is emitted 11/100/185 s into the hold (no `change ... nachziehen` re-emit without via)");
        is(scalar(@Plugins::SpotOn::Status::RECORDED), 0, "84-17 H-g g3: and no errors[] entry (no watchdog:/split-brain: record)");

        # LMS's re-open (requestTrack for the deferred uri = the daemon's own track) cancels the WATCHDOG only; the hold stays
        $ctl->_cancelConnectWatchdog;
        ok(!$ctl->observed->{connectWatchdog}, "84-17 H-g: LMS's re-open cancels the watchdog");
        ok($ctl->observed->{hold}, "84-17 H-g (W3): ... but the hold record stays");

        # g2: _checkSplitBrain stands down while the hold is open, even with LMS reading `stop` for several ticks
        $ctl->observed->{status}    = 'playing';
        $ctl->observed->{is_active} = 1;
        $before = scalar(@Slim::Player::Client::EXECUTED);
        $ctl->_checkSplitBrain for 1 .. 4;
        is(scalar(@Slim::Player::Client::EXECUTED), $before, "84-17 H-g g2: _checkSplitBrain does not escalate inside a hold (4 `stop` sightings)");
        is(scalar(@Plugins::SpotOn::Status::RECORDED), 0, "84-17 H-g g2/g3: no errors[] entry");

        # expired at max_at: two `stop` sightings DO escalate again (both halves asserted)
        $ctl->observed->{hold}{max_at} = $now_hold->() - 1;
        $ctl->_checkSplitBrain for 1 .. 2;
        ok(scalar(grep { $_->[1] eq 'change' } @Slim::Player::Client::EXECUTED) >= 1,
            "84-17 H-g g2: with the hold expired, two `stop` sightings escalate again (a nachziehen `change`)");
        ok(scalar(@Plugins::SpotOn::Status::RECORDED) >= 1, "84-17 H-g g2: ... and write the split-brain errors[] entry as before");
        ok(!$ctl->observed->{hold}, "84-17 H-g: the expired record is gone (deleted on read)");
    }

    # -- H-h: the deferred marker on EVERY seek/resume while the hold is open ---
    {
        $reset->();
        my ($ctl, $daemon, $ws) = $connect_ctl->(mac => 'aa:84:17:00:00:a1');
        $open_hold->($ctl);
        @Slim::Player::Client::EXECUTED = ();
        # run 3's end-of-write pair (ws.jsonl:28-31): position_sync 242603 speed 0, playback_changed playing, position_sync 242605 speed 1
        $ctl->onEvent({ type => 'position_sync', position => { position_ms => 242603, timestamp_ms => 3, speed => 0 } });
        $ctl->onEvent({ type => 'playback_changed', status => 'playing' });
        $ctl->onEvent({ type => 'position_sync', position => { position_ms => 242605, timestamp_ms => 4, speed => 1 } });
        my @seek   = grep { $_->[1] eq 'seek' } @Slim::Player::Client::EXECUTED;
        my @resume = grep { $_->[1] eq 'resume' } @Slim::Player::Client::EXECUTED;
        is_deeply($seek[0], [ 'spottyconnect', 'seek', '242.603', '', 'deferred' ],
            "84-17 H-h: the end-of-write seek 242.603 carries `deferred` (pre-fix: no marker)");
        is($resume[0] ? $resume[0][4] : undef, 'deferred', "84-17 H-h: the resume carries `deferred` too");
        is($resume[0] ? $resume[0][2] : undef, $NEXTID, "84-17 H-h: ... with the deferred track id as today");
        ok(!(grep { $_->[1] eq 'change' } @Slim::Player::Client::EXECUTED), "84-17 H-h: and NO cancellation (no change re-emit)");
        ok($ctl->observed->{hold}, "84-17 H-h: the hold is still open after the daemon's own verbs");

        # LMS's requestTrack for the deferred uri (STMd, ~10 s before the switch) cancels the watchdog only
        $ctl->_cancelConnectWatchdog;
        @Slim::Player::Client::EXECUTED = ();
        $ctl->_emit('seek', '241.000');
        is_deeply($Slim::Player::Client::EXECUTED[0], [ 'spottyconnect', 'seek', '241.000', '', 'deferred' ],
            "84-17 H-h (W3): a seek in the ~10 s after LMS's re-open STILL carries the marker");

        # after clearHold the marker stops
        $ctl->clearHold($NEXTID) if $ctl->can('clearHold');
        @Slim::Player::Client::EXECUTED = ();
        $ctl->_emit('seek', '3.000');
        is_deeply($Slim::Player::Client::EXECUTED[0], [ 'spottyconnect', 'seek', '3.000', '' ],
            "84-17 H-h: after clearHold the seek goes out unmarked (the 4-element wire)");

        # ... and at expiry (max_at) as well
        $reset->();
        my ($c2, $d_c2, $w_c2) = $connect_ctl->(mac => 'aa:84:17:00:00:a2');
        $open_hold->($c2);
        $c2->observed->{hold}{max_at} = $now_hold->() - 1;
        @Slim::Player::Client::EXECUTED = ();
        $c2->_emit('resume', $NEXTID, '10.000');
        is_deeply($Slim::Player::Client::EXECUTED[0], [ 'spottyconnect', 'resume', $NEXTID, '10.000' ],
            "84-17 H-h: after the record expired (max_at) the resume goes out unmarked");

        # a skip while a hold is open: a non-live change clears the record
        $reset->();
        my ($c3, $d_c3, $w_c3) = $connect_ctl->(mac => 'aa:84:17:00:00:a3');
        $open_hold->($c3);
        $c3->onEvent($tc->($NEX2));
        $IO::Socket::INET::READ_REPLY = $reply->('departed', anchor => 'pushed');
        Slim::Networking::Select::deliver();
        ok(!$c3->observed->{hold}, "84-17 H-h: a `departed` change (a skip) clears the hold record");
    }

    # -- 84.2-05 D: the hold's natural advance through requestTrack (producer P6) ---
    # LMS's own advance to the item `_holdOpen` inserted reaches requestTrack as a
    # getNextTrack for the deferred uri -- the uri the daemon already reports. The
    # 84.2-05 two-signal same-uri rule must keep connect here: the marker `_holdOpen`
    # stamps before its insert (t/41 H-a pins the stamp on the real Connect.pm; here the
    # opts carry it as ProtocolHandler derives it) is the ONLY stay signal on a paused
    # daemon (D1); on a playing daemon the status alone keeps it (D2, unmarked). Neither
    # case reads the 84-17 hold record (it is not a stay signal: written on every live
    # change, it could outlive the LMS-side hold). D2 is the requestTrack-DRIVEN
    # counterpart of H-g's direct `_cancelConnectWatchdog` call. Its two watchdog
    # assertions are NON-DISCRIMINATING (both branches of the rule cancel the watchdog);
    # its discriminating assertions are `mode` connect and the kept hold record.
    {
        $reset->();
        my ($ctl, $daemon, $ws) = $connect_ctl->(mac => 'aa:84:25:00:00:d1');
        $open_hold->($ctl);
        is($ctl->observed->{hold} ? $ctl->observed->{hold}{uri} : undef, $NEXT,
            "84.2-05 D1 setup: the live change opened the hold record for the deferred uri");
        $ctl->onEvent({ type => 'playback_changed', status => 'paused' });    # the app paused during the hold
        @Slim::Player::Client::EXECUTED = ();
        $ctl->requestTrack($NEXT, 0, { source => 'getNextTrack', origin => 'connect', successCb => sub {} });
        is($ctl->mode, 'connect', "84.2-05 D1: the hold's advance on a PAUSED daemon carries the _holdOpen marker -- mode stays connect");
        is($ctl->observed->{hold} ? $ctl->observed->{hold}{uri} : undef, $NEXT,
            "84.2-05 D1: the stay path leaves the hold record alone");
        is($ctl->observed->{connectWatchdog}, undef, "84.2-05 D1: no connect watchdog record afterwards");
    }
    {
        $reset->();
        my ($ctl, $daemon, $ws) = $connect_ctl->(mac => 'aa:84:25:00:00:d2');
        $open_hold->($ctl);
        my $wd = sub { scalar(grep { $_->[2] == \&Plugins::SpotOn::Soloist::Control::_watchdogRound2 } @Slim::Utils::Timers::TIMERS) };
        is($wd->(), 1, "84.2-05 D2 setup: the live change armed exactly one connect watchdog timer");
        $ctl->requestTrack($NEXT, 0, { source => 'getNextTrack', successCb => sub {} });    # unmarked, daemon playing
        is($wd->(), 0, "84.2-05 D2: the hold advance through requestTrack kills the watchdog timer (non-discriminating)");
        is($ctl->observed->{connectWatchdog}, undef, "84.2-05 D2: connectWatchdog record deleted (non-discriminating)");
        is($ctl->mode, 'connect', "84.2-05 D2: an unmarked re-open of the title the daemon PLAYS stays connect (signal d)");
        is($ctl->observed->{hold} ? $ctl->observed->{hold}{uri} : undef, $NEXT,
            "84.2-05 D2: the hold record is kept");
        ok(!(grep { $_->[0] eq 'seek' && ($_->[1]{position_ms} // -1) == 0 } @{ $ws->sent }),
            "84.2-05 D2: no seek to 0 (R2-CR04 Fall A shape)");
    }
}

# ===== 84.2-01: own-queue set (CAUSE-3 D-04/D-06/D-07, IN-04) =====
# `observed.queuedByUs` -- SpotOn's proof that IT queued a title (the
# autoplay guard in _onFrameTrackChanged stands aside on a match). Before
# 84.2-01 it was ONE scalar, written before the add_to_queue send and
# never cleared on a loss of control: a leftover prefetch from an earlier
# Browse run (B7 07:48: 6d0c, cut from the real recording into
# t/fixtures/soloist/84-2-b7-0748-leftover.frames) was waved through as
# "own". The two helpers below read either shape (scalar on the old code,
# HASH set after the fix), so the SAME assertions are RED before and GREEN
# after.
sub own_queue_has {
    my ($ctl, $uri) = @_;
    my $q = $ctl->observed->{queuedByUs};
    return 0 unless defined $q;
    return (exists $q->{$uri} ? 1 : 0) if ref($q) eq 'HASH';
    return ($q eq $uri) ? 1 : 0;
}

sub own_queue_empty {
    my ($ctl) = @_;
    my $q = $ctl->observed->{queuedByUs};
    return 1 unless defined $q;
    return (%$q ? 0 : 1) if ref($q) eq 'HASH';
    return 0;
}

{
    my $Q_X  = $TID;                                         # track_changed.json's uri (our own play X)
    my $Q_Y  = 'spotify:track:842o1OwnNextYYYYYYYYYYY';      # X's LMS successor (prefetched)
    my $Q_W  = 'spotify:track:842o1JumpTargetWWWWWWWW';      # LMS jumps here (D-07)
    my $Q_V  = 'spotify:track:842o1JumpNextVVVVVVVVVV';      # W's LMS successor (prefetched)
    my $Q_Q  = 'spotify:track:842o1PhoneQueuedQQQQQQQ';      # queued on the phone, never by SpotOn (D-06)
    my $Q_Z  = 'spotify:track:842o1AppTitleZZZZZZZZZZ';      # the app's title on a transfer-in
    my $Q_6D0C   = 'spotify:track:6d0cIiukgZJ8fZBJFqDMBT';   # B7 07:48 leftover (B6 07:35's last prefetch)
    my $Q_AFRICA = 'spotify:track:2374M0fQpWi3dLnB54qaLX';   # B7's own title A
    my $mt = sub { Test::MockTrack->new($_[0]) };
    my $sp = sub { my ($u) = @_; $u =~ s/^spotify:track:/spoton:\/\/track:/; return $u };

    # browse session: play X, its echo prefetches X's LMS successor. The
    # caller sets @ENTRIES / $INDEX with `local` before calling.
    my $q_browse = sub {
        my ($mac) = @_;
        @Plugins::SpotOn::Status::RECORDED = ();
        my ($ctl, $daemon, $ws) = fresh_control(
            mac      => $mac,
            mode     => 'browse',
            observed => { wsConnected => 1, paired => 1, is_active => 1, meta => { $Q_X => { duration => 200 } },
                          track => 'spotify:track:previousXYZ', status => 'playing' },
        );
        $ctl->requestTrack($Q_X, 0, {});
        $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));
        return ($ctl, $daemon, $ws);
    };

    # --- Case A (D-04): LMS stop of our browse title (stop-leave :871-876)
    # forgets the own queue ---
    {
        local @Slim::Player::Playlist::ENTRIES = ( $mt->($sp->($Q_X)), $mt->($sp->($Q_Y)) );
        local $Slim::Player::Source::INDEX = 0;
        my ($ctl, $daemon, $ws) = $q_browse->('aa:84:2a:01:00:0a');
        ok(own_queue_has($ctl, $Q_Y), "84.2-01 A setup: the echo of X prefetched Y (own)");
        $ctl->pending(undef);
        {
            local $Slim::Player::Source::PLAYMODE = 'stop';
            $ctl->requestPause(1);
        }
        is($ctl->mode, 'idle', "84.2-01 A setup: LMS stop left browse (stop-leave ran)");
        ok(own_queue_empty($ctl), "84.2-01 A (D-04 stop-leave): the own queue is forgotten on an LMS stop");
    }

    # --- Case B1 (D-04): source switch / non-spoton pause -- the direct
    # leaveBrowse callers (Connect.pm CR-04, Control :788) ---
    {
        local @Slim::Player::Playlist::ENTRIES = ( $mt->($sp->($Q_X)), $mt->($sp->($Q_Y)) );
        local $Slim::Player::Source::INDEX = 0;
        my ($ctl, $daemon, $ws) = $q_browse->('aa:84:2a:01:00:b1');
        ok(own_queue_has($ctl, $Q_Y), "84.2-01 B1 setup: Y prefetched");
        $ctl->leaveBrowse;
        is($ctl->mode, 'idle', "84.2-01 B1 setup: leaveBrowse -> idle");
        ok(own_queue_empty($ctl), "84.2-01 B1 (D-04 source switch): leaveBrowse forgets the own queue");
    }

    # --- Case B2 (D-04): another device takes the session in browse --
    # device_changed(is_active:false) while mode is browse reaches the
    # session-loss leave (`lost the Spotify session in browse --
    # leaveBrowse`; no earlier t/44 test feeds that shape) ---
    {
        local @Slim::Player::Playlist::ENTRIES = ( $mt->($sp->($Q_X)), $mt->($sp->($Q_Y)) );
        local $Slim::Player::Source::INDEX = 0;
        my ($ctl, $daemon, $ws) = $q_browse->('aa:84:2a:01:00:b2');
        ok(own_queue_has($ctl, $Q_Y), "84.2-01 B2 setup: Y prefetched");
        $ctl->pending(undef);
        my $f = decode_frame(load_fixture('device_changed.json'));
        $f->{is_active} = JSON::PP::false();
        $ctl->onEvent($f);
        is($ctl->mode, 'idle', "84.2-01 B2 setup: session loss in browse left browse");
        ok(own_queue_empty($ctl), "84.2-01 B2 (D-04 session loss): the own queue is forgotten when another device takes the session");
    }

    # --- Case C1 (D-04): browse -> connect transfer-in (_onFrameDeviceChanged
    # :4312) -- the app's title Z, no open play, so not our own activation ---
    {
        local @Slim::Player::Playlist::ENTRIES = ( $mt->($sp->($Q_X)), $mt->($sp->($Q_Y)) );
        local $Slim::Player::Source::INDEX = 0;
        @Plugins::SpotOn::Connect::CLAIMS = (); $Plugins::SpotOn::Connect::ACTIVE = undef;
        @Plugins::SpotOn::Status::RECORDED = ();
        my ($ctl, $daemon, $ws) = fresh_control(
            mac      => 'aa:84:2a:01:00:c1',
            mode     => 'browse',
            wanted   => { uri => $Q_X, playing => 1 },
            observed => { wsConnected => 1, paired => 1, is_active => 1, meta => {}, track => $Q_Z, status => 'playing' },
        );
        $ctl->_prefetchNext;
        ok(own_queue_has($ctl, $Q_Y), "84.2-01 C1 setup: _prefetchNext in browse queued Y");
        $ctl->pending(undef);
        $ctl->onEvent(decode_frame(load_fixture('device_changed.json')));
        is($ctl->mode, 'connect', "84.2-01 C1 setup: the transfer-in flipped browse -> connect");
        ok(own_queue_empty($ctl), "84.2-01 C1 (D-04 transfer-in): no own-queue memory survives into connect");
    }

    # --- Case C2 (D-04, defensive): the idle -> connect reconnect flip
    # (_onFramePlaybackState :3978, only from idle) -- a stale set that
    # survived into idle by whatever path is cleared there too ---
    {
        @Plugins::SpotOn::Connect::CLAIMS = (); $Plugins::SpotOn::Connect::ACTIVE = undef;
        @Plugins::SpotOn::Status::RECORDED = ();
        my ($ctl, $daemon, $ws) = fresh_control(
            mac      => 'aa:84:2a:01:00:c2',
            mode     => 'idle',
            observed => { wsConnected => 1, paired => 1, meta => {} },
        );
        $ctl->observed->{queuedByUs} = { $Q_Y => 1 };
        $ctl->onEvent(decode_frame(load_fixture('playback_state.json')));
        is($ctl->mode, 'connect', "84.2-01 C2 setup: the reconnect flip idle -> connect ran");
        ok(own_queue_empty($ctl), "84.2-01 C2 (D-04 reconnect-to-connect): the stale own queue is cleared at the idle -> connect entry");
    }

    # --- Case D (tracer, CAUSE-3): the real B7 07:48 frames. Session 1 =
    # the B6 07:35 run whose last echo prefetched 6d0c, ended by an LMS
    # stop. Session 2 = B7: A (Africa) -> L (local file) -> B. The daemon
    # starts the leftover 6d0c from the account queue; SpotOn never asked
    # for it in THIS session -> paused + autoplay:<6d0c> entry ---
    {
        my @f = map { decode_frame($_) } load_fixture('84-2-b7-0748-leftover.frames');
        is(scalar(@f), 5, "84.2-01 D setup: five real frames from the B7 07:48 recording");
        my ($ctl, $daemon, $ws);
        {
            local @Slim::Player::Playlist::ENTRIES = ( $mt->($sp->($Q_X)), $mt->($sp->($Q_6D0C)) );
            local $Slim::Player::Source::INDEX = 0;
            ($ctl, $daemon, $ws) = $q_browse->('aa:84:2a:01:00:0d');
            ok(own_queue_has($ctl, $Q_6D0C), "84.2-01 D setup: session 1 prefetched 6d0c");
            $ctl->pending(undef);
            local $Slim::Player::Source::PLAYMODE = 'stop';
            $ctl->requestPause(1);
            is($ctl->mode, 'idle', "84.2-01 D setup: session 1 ended by an LMS stop");
        }
        {
            local @Slim::Player::Playlist::ENTRIES = (
                $mt->($sp->($Q_AFRICA)),
                $mt->('file:///var/tmp/spoton-b7/local-30s.wav'),
                $mt->('spoton://track:552lBxKLGjerBDS8VYHOJn'),
            );
            local $Slim::Player::Source::INDEX = 0;
            @Plugins::SpotOn::Status::RECORDED = ();
            $ctl->observed->{meta}{$Q_AFRICA} = { duration => 295 };
            $ctl->requestTrack($Q_AFRICA, 0, {});
            $ctl->onEvent($f[0]);    # ws.jsonl:9  track_changed Africa = our echo (successor local -> no new prefetch)
            $ctl->onEvent($f[1]);    # ws.jsonl:11 queue_changed upcoming[0] = q1 6d0c
            @{ $ws->sent } = ();
            $ctl->pending(undef);
            $ctl->onEvent($f[2]);    # ws.jsonl:26 track_changed 6d0c (the leftover)
            $ctl->onEvent($f[3]);    # ws.jsonl:28 playback_state buffering 6d0c
            $ctl->onEvent($f[4]);    # ws.jsonl:31 playback_state playing 6d0c
            ok((grep { $_->[0] eq 'pause' } @{ $ws->sent }),
                "84.2-01 D (CAUSE-3 real B7 07:48 replay): the leftover 6d0c is paused, not waved through as own");
            my @mine = grep { ($_->[3] // '') eq $daemon->mac . ':autoplay:' . $Q_6D0C } @Plugins::SpotOn::Status::RECORDED;
            is(scalar(@mine), 1, "84.2-01 D (CAUSE-3 real B7 07:48 replay): exactly one autoplay:6d0c errors[] entry");
        }
    }

    # --- Case E (D-07 / IN-04): two own entries at once -- LMS jumped past
    # the prefetched Y to W (W's echo prefetched V); the daemon then reaches
    # Y from the account queue: still own, consumed individually ---
    {
        local @Slim::Player::Playlist::ENTRIES = ( $mt->($sp->($Q_X)), $mt->($sp->($Q_Y)), $mt->($sp->($Q_W)), $mt->($sp->($Q_V)) );
        local $Slim::Player::Source::INDEX = 0;
        my ($ctl, $daemon, $ws) = $q_browse->('aa:84:2a:01:00:0e');
        ok(own_queue_has($ctl, $Q_Y), "84.2-01 E setup: the echo of X prefetched Y");
        $ctl->pending(undef);
        $Slim::Player::Source::INDEX = 2;
        $ctl->observed->{meta}{$Q_W} = { duration => 200 };
        $ctl->requestTrack($Q_W, 0, {});
        $ctl->onEvent({ type => 'track_changed', item => { uri => $Q_W } });
        ok(own_queue_has($ctl, $Q_V), "84.2-01 E setup: the echo of W prefetched V");
        @{ $ws->sent } = ();
        $ctl->pending(undef);
        $ctl->onEvent({ type => 'track_changed', item => { uri => $Q_Y } });
        ok(!(grep { $_->[0] eq 'pause' } @{ $ws->sent }),
            "84.2-01 E (D-07 multi-slot): the skipped prefetched Y is still own -- no pause");
        my @mine = grep { ($_->[3] // '') eq $daemon->mac . ':autoplay:' . $Q_Y } @Plugins::SpotOn::Status::RECORDED;
        is(scalar(@mine), 0, "84.2-01 E (D-07 multi-slot): no autoplay:Y entry");
        ok(own_queue_has($ctl, $Q_V), "84.2-01 E (D-07 multi-slot): V is still own after Y was consumed");
        ok(!own_queue_has($ctl, $Q_Y), "84.2-01 E (D-07 multi-slot): Y is consumed individually");
    }

    # --- Case F (IN-04): a failed add_to_queue send leaves no own marker ---
    {
        local @Slim::Player::Playlist::ENTRIES = ( $mt->($sp->($Q_X)), $mt->($sp->($Q_Y)) );
        local $Slim::Player::Source::INDEX = 0;
        @Plugins::SpotOn::Status::RECORDED = ();
        my ($ctl, $daemon, $ws) = fresh_control(
            mac          => 'aa:84:2a:01:00:0f',
            mode         => 'browse',
            send_success => 0,
            wanted       => { uri => $Q_X, playing => 1 },
            observed     => { wsConnected => 1, paired => 1, is_active => 1, meta => {}, track => $Q_X, status => 'playing' },
        );
        $ctl->_prefetchNext;
        ok((grep { $_->[0] eq 'add_to_queue' && ($_->[1]{uri} // '') eq $Q_Y } @{ $ws->sent }),
            "84.2-01 F setup: the add_to_queue send for Y was attempted");
        ok(!own_queue_has($ctl, $Q_Y), "84.2-01 F (IN-04 set-after-send): a failed send leaves Y unmarked");
    }

    # --- Case G (D-06 pin, GREEN before and after): a title queued on the
    # phone before LMS started, never by SpotOn, is paused as foreign. (G2,
    # the 84-19 edge case "LMS successor == pre-existing entry counts as
    # own", stays pinned by the F-18-N4 change-1 test above.) ---
    {
        local @Slim::Player::Playlist::ENTRIES = ( $mt->($sp->($Q_X)) );
        local $Slim::Player::Source::INDEX = 0;
        my ($ctl, $daemon, $ws) = $q_browse->('aa:84:2a:01:00:09');
        ok(own_queue_empty($ctl), "84.2-01 G setup: no successor, nothing prefetched");
        $ctl->onEvent(n4_queue_changed([ 'q9', 'queue', $Q_Q ]));
        @{ $ws->sent } = ();
        $ctl->pending(undef);
        $ctl->onEvent({ type => 'track_changed', item => { uri => $Q_Q } });
        ok((grep { $_->[0] eq 'pause' } @{ $ws->sent }),
            "84.2-01 G (D-06 pin): a pre-existing foreign queue entry is paused");
        my @mine = grep { ($_->[3] // '') eq $daemon->mac . ':autoplay:' . $Q_Q } @Plugins::SpotOn::Status::RECORDED;
        is(scalar(@mine), 1, "84.2-01 G (D-06 pin): exactly one autoplay:Q entry");
    }
}

# ===== 84.2-02: prefetch wish + repeat-aware next + context-end carrier (CAUSE-2, D-15) =====
# CAUSE-2: the only prefetch trigger used to be the echo of SpotOn's own
# play -- it fires before the B6 runner adds the successor, never after a
# prefetch hit (LMS adopts the queued title through getNextTrack: Treffer,
# no play, no echo) and never at a repeat-all wrap. D-15: at a context end
# without a Spotify successor (Autoplay OFF) the watchdog's round 1 (c)
# resumed the wrapped title from 0:00 for ~10 s. Cases A-E pin the prefetch
# wish, F-G6 pin the context-end carrier on real frames (off-1, run7, B7
# 07:48). Assertions tagged `T3-owned` stay RED until the carrier lands
# (Task 3 of 84.2-02); every other assertion of this section is green once
# the prefetch wish lands.
{
    my $W_T1 = 'spotify:track:842o2WishTitleOneAAAAAA';
    my $W_T2 = 'spotify:track:842o2WishTitleTwoBBBBBB';
    my $W_T3 = 'spotify:track:842o2WishTitleThreeCCCC';
    my $W_7GVU   = 'spotify:track:7GVUmCP00eSsqc4tzj1sDD';    # off-1 context end (duration 205933)
    my $W_552L   = 'spotify:track:552lBxKLGjerBDS8VYHOJn';    # run7 context end / B7 mid-title pause (317278)
    my $W_AFRICA = 'spotify:track:2374M0fQpWi3dLnB54qaLX';    # B7 seek / late pick (295282)
    my $W_6D0C   = 'spotify:track:6d0cIiukgZJ8fZBJFqDMBT';    # B7 late pick (207682)
    my $mt = sub { Test::MockTrack->new($_[0]) };
    my $sp = sub { my ($u) = @_; $u =~ s/^spotify:track:/spoton:\/\/track:/; return $u };
    my $adds = sub {
        my ($ws, $uri) = @_;
        return scalar(grep { $_->[0] eq 'add_to_queue' && (!defined $uri || ($_->[1]{uri} // '') eq $uri) } @{ $ws->sent });
    };
    my $cmds = sub { my ($ws, $cmd) = @_; return scalar(grep { $_->[0] eq $cmd } @{ $ws->sent }); };
    my $boundaries = sub { return scalar(grep { ${ $_->{bufref} } =~ m{^POST /boundary} } @IO::Socket::INET::REQUESTS); };

    # A settled browse control: LMS plays $uri, the daemon reports it.
    my $settled = sub {
        my ($mac, $uri, %more) = @_;
        @Plugins::SpotOn::Status::RECORDED = ();
        return fresh_control(
            mac      => $mac,
            mode     => ($more{mode} // 'browse'),
            wanted   => { uri => $uri, playing => 1 },
            observed => { wsConnected => 1, paired => 1, is_active => 1, meta => {}, track => $uri,
                          status => 'playing', %{ $more{observed} || {} } },
        );
    };

    # --- Case A (tracer, D-08 late successor): the B6 runner's
    # play-then-add shape -- the echo of T1 finds no successor; the add of
    # T2 arrives as an LMS playlist change and queues T2 exactly once ---
    {
        local @Slim::Player::Playlist::ENTRIES = ( $mt->($sp->($W_T1)) );
        local $Slim::Player::Source::INDEX = 0;
        @Plugins::SpotOn::Status::RECORDED = ();
        my ($ctl, $daemon, $ws) = fresh_control(
            mac      => 'aa:84:2b:02:00:0a',
            mode     => 'browse',
            observed => { wsConnected => 1, paired => 1, is_active => 1, meta => { $W_T1 => { duration => 200 } },
                          track => 'spotify:track:previousXYZ', status => 'playing' },
        );
        $ctl->requestTrack($W_T1, 0, {});
        $ctl->onEvent({ type => 'track_changed', item => { uri => $W_T1 } });
        is($adds->($ws), 0, "84.2-02 A setup: the echo of T1 queues nothing (LMS holds one entry)");
        push @Slim::Player::Playlist::ENTRIES, $mt->($sp->($W_T2));
        eval { $ctl->notePlaylistChanged };
        ok(!$@, "84.2-02 A: notePlaylistChanged exists and runs");
        is($adds->($ws, $W_T2), 1, "84.2-02 A: the late successor T2 is queued exactly once after the LMS playlist change");
        eval { $ctl->notePlaylistChanged };
        is($adds->($ws), 1, "84.2-02 A: a second playlist change queues nothing new (idempotent through the own-queue set)");
    }

    # --- Case B (after-hit): LMS adopts the prefetched T2 through
    # getNextTrack (Treffer, no play, no echo) -- T3 is still queued once ---
    {
        local @Slim::Player::Playlist::ENTRIES = ( $mt->($sp->($W_T1)), $mt->($sp->($W_T2)), $mt->($sp->($W_T3)) );
        local $Slim::Player::Source::INDEX = 0;
        @Plugins::SpotOn::Status::RECORDED = ();
        my ($ctl, $daemon, $ws) = fresh_control(
            mac      => 'aa:84:2b:02:00:0b',
            mode     => 'browse',
            observed => { wsConnected => 1, paired => 1, is_active => 1,
                          meta => { $W_T1 => { duration => 200 }, $W_T2 => { duration => 200 }, $W_T3 => { duration => 200 } },
                          track => 'spotify:track:previousXYZ', status => 'playing' },
        );
        $ctl->requestTrack($W_T1, 0, {});
        $ctl->onEvent({ type => 'track_changed', item => { uri => $W_T1 } });
        is($adds->($ws, $W_T2), 1, "84.2-02 B setup: the echo of T1 queued T2");
        $ctl->pending(undef);
        $ctl->onEvent({ type => 'track_changed', item => { uri => $W_T2 } });
        is($cmds->($ws, 'pause'), 0, "84.2-02 B setup: the daemon's advance to T2 is own (no pause)");
        $Slim::Player::Source::INDEX = 1;
        my $mark = scalar @{ $ws->sent };
        $ctl->requestTrack($W_T2, 0, { source => 'getNextTrack' });
        $ctl->onEvent({ type => 'position_sync', position => { position_ms => 3, timestamp_ms => 1791000000000, speed => 1 } });
        my @after = @{ $ws->sent }[ $mark .. $#{ $ws->sent } ];
        is($adds->($ws, $W_T3), 1, "84.2-02 B: after the prefetch hit the next successor T3 is queued exactly once");
        is(scalar(grep { $_->[0] eq 'play' } @after), 0, "84.2-02 B: the Treffer sent no play");
    }

    # --- Case C (repeat-aware next index): six sub-cases, each on its own
    # control (a shared control would keep T1 in the own-queue set and the
    # idempotence test would silence C-5) ---
    {
        my @three = ( $mt->($sp->($W_T1)), $mt->($sp->($W_T2)), $mt->($sp->($W_T3)) );
        # C-1
        {
            local @Slim::Player::Playlist::ENTRIES = @three;
            local $Slim::Player::Source::INDEX = 2;
            local $Slim::Player::Playlist::REPEAT  = 2;
            local $Slim::Player::Playlist::SHUFFLE = 0;
            local $Slim::Utils::Prefs::FAKE_VALUES{reshuffleOnRepeat} = 0;
            my ($ctl, $daemon, $ws) = fresh_control(
                mac      => 'aa:84:2b:02:0c:01',
                mode     => 'browse',
                wanted   => { uri => $W_T3, playing => 1 },
                observed => { wsConnected => 1, paired => 1, is_active => 1, meta => {}, track => $W_T3, status => 'playing' },
            );
            $ctl->_prefetchNext;
            is_deeply($ws->sent, [ [ 'add_to_queue', { uri => $W_T1 } ] ], "84.2-02 C-1: repeat-all wraps to index 0: exactly one add T1");
        }
        # C-2
        {
            local @Slim::Player::Playlist::ENTRIES = @three;
            local $Slim::Player::Source::INDEX = 2;
            local $Slim::Player::Playlist::REPEAT  = 1;
            local $Slim::Player::Playlist::SHUFFLE = 0;
            local $Slim::Utils::Prefs::FAKE_VALUES{reshuffleOnRepeat} = 0;
            my ($ctl, $daemon, $ws) = fresh_control(
                mac      => 'aa:84:2b:02:0c:02',
                mode     => 'browse',
                wanted   => { uri => $W_T3, playing => 1 },
                observed => { wsConnected => 1, paired => 1, is_active => 1, meta => {}, track => $W_T3, status => 'playing' },
            );
            $ctl->_prefetchNext;
            is_deeply($ws->sent, [], "84.2-02 C-2: repeat-one queues nothing (a same-uri advance would be a replay)");
        }
        # C-3
        {
            local @Slim::Player::Playlist::ENTRIES = @three;
            local $Slim::Player::Source::INDEX = 2;
            local $Slim::Player::Playlist::REPEAT  = 0;
            local $Slim::Player::Playlist::SHUFFLE = 0;
            local $Slim::Utils::Prefs::FAKE_VALUES{reshuffleOnRepeat} = 0;
            my ($ctl, $daemon, $ws) = fresh_control(
                mac      => 'aa:84:2b:02:0c:03',
                mode     => 'browse',
                wanted   => { uri => $W_T3, playing => 1 },
                observed => { wsConnected => 1, paired => 1, is_active => 1, meta => {}, track => $W_T3, status => 'playing' },
            );
            $ctl->_prefetchNext;
            is_deeply($ws->sent, [], "84.2-02 C-3: no repeat at the last title queues nothing");
        }
        # C-4
        {
            local @Slim::Player::Playlist::ENTRIES = @three;
            local $Slim::Player::Source::INDEX = 2;
            local $Slim::Player::Playlist::REPEAT  = 2;
            local $Slim::Player::Playlist::SHUFFLE = 1;
            local $Slim::Utils::Prefs::FAKE_VALUES{reshuffleOnRepeat} = 1;
            my ($ctl, $daemon, $ws) = fresh_control(
                mac      => 'aa:84:2b:02:0c:04',
                mode     => 'browse',
                wanted   => { uri => $W_T3, playing => 1 },
                observed => { wsConnected => 1, paired => 1, is_active => 1, meta => {}, track => $W_T3, status => 'playing' },
            );
            $ctl->_prefetchNext;
            is_deeply($ws->sent, [], "84.2-02 C-4: repeat-all + shuffle + reshuffleOnRepeat queues nothing (next unknown until LMS reshuffles)");
        }
        # C-5
        {
            local @Slim::Player::Playlist::ENTRIES = @three;
            local $Slim::Player::Source::INDEX = 2;
            local $Slim::Player::Playlist::REPEAT  = 2;
            local $Slim::Player::Playlist::SHUFFLE = 1;
            local $Slim::Utils::Prefs::FAKE_VALUES{reshuffleOnRepeat} = 0;
            my ($ctl, $daemon, $ws) = fresh_control(
                mac      => 'aa:84:2b:02:0c:05',
                mode     => 'browse',
                wanted   => { uri => $W_T3, playing => 1 },
                observed => { wsConnected => 1, paired => 1, is_active => 1, meta => {}, track => $W_T3, status => 'playing' },
            );
            $ctl->_prefetchNext;
            is_deeply($ws->sent, [ [ 'add_to_queue', { uri => $W_T1 } ] ], "84.2-02 C-5: repeat-all + shuffle without reshuffleOnRepeat: exactly one add T1");
        }
        # C-6
        {
            local @Slim::Player::Playlist::ENTRIES = ( $mt->($sp->($W_T1)) );
            local $Slim::Player::Source::INDEX = 0;
            local $Slim::Player::Playlist::REPEAT  = 2;
            local $Slim::Player::Playlist::SHUFFLE = 0;
            local $Slim::Utils::Prefs::FAKE_VALUES{reshuffleOnRepeat} = 0;
            my ($ctl, $daemon, $ws) = fresh_control(
                mac      => 'aa:84:2b:02:0c:06',
                mode     => 'browse',
                wanted   => { uri => $W_T1, playing => 1 },
                observed => { wsConnected => 1, paired => 1, is_active => 1, meta => {}, track => $W_T1, status => 'playing' },
            );
            $ctl->_prefetchNext;
            is_deeply($ws->sent, [], "84.2-02 C-6: a repeat-all wrap on a one-entry playlist queues nothing (index 0 is the playing uri)");
        }
        delete $Slim::Utils::Prefs::FAKE_VALUES{reshuffleOnRepeat};
    }

    # --- Case D (open slot never superseded, Pitfall 2 / WR-02): an open
    # set_volume slot defers the wish to the settle point ---
    {
        local @Slim::Player::Playlist::ENTRIES = ( $mt->($sp->($W_T1)) );
        local $Slim::Player::Source::INDEX = 0;
        my ($ctl, $daemon, $ws) = $settled->('aa:84:2b:02:00:0d', $W_T1, observed => { volume => 40 });
        @Slim::Player::Client::EXECUTED = ();
        $ctl->requestVolume(50);
        is($ctl->pending && $ctl->pending->{cmd}, 'set_volume', "84.2-02 D setup: a set_volume slot is open");
        push @Slim::Player::Playlist::ENTRIES, $mt->($sp->($W_T2));
        eval { $ctl->notePlaylistChanged };
        ok(!$@, "84.2-02 D: notePlaylistChanged exists and runs");
        is($adds->($ws), 0, "84.2-02 D: no add_to_queue while the set_volume slot is open");
        my $f = decode_frame(load_fixture('volume_changed.json'));
        $f->{volume} = 50;
        $ctl->onEvent($f);
        is_deeply([ map { $_->[0] } @{ $ws->sent } ], [ 'set_volume', 'add_to_queue' ],
            "84.2-02 D: the wish is consumed at the settle point -- set_volume, then add_to_queue");
        is($adds->($ws, $W_T2), 1, "84.2-02 D: the add carries T2");
        is($cmds->($ws, 'set_volume'), 1, "84.2-02 D: the volume echo was own (no second set_volume)");
        is_deeply(\@Slim::Player::Client::EXECUTED, [], "84.2-02 D: no volume mirrored back to LMS");
    }

    # --- Case E (connect invariant, Pitfall 4 / D-16): nothing is queued
    # and nothing planted in connect ---
    {
        local @Slim::Player::Playlist::ENTRIES = ( $mt->($sp->($W_T1)), $mt->($sp->($W_T2)) );
        local $Slim::Player::Source::INDEX = 0;
        my ($ctl, $daemon, $ws) = $settled->('aa:84:2b:02:00:0e', $W_T1, mode => 'connect');
        eval { $ctl->notePlaylistChanged };
        ok(!$@, "84.2-02 E: notePlaylistChanged exists and runs in connect");
        is($adds->($ws), 0, "84.2-02 E: no add_to_queue in connect");

        local @Slim::Player::Playlist::ENTRIES = ( $mt->($sp->($W_7GVU)) );
        my ($c2, $d2, $w2) = $settled->('aa:84:2b:02:00:e2', $W_7GVU, mode => 'connect');
        my $before = $boundaries->();
        $c2->onEvent(decode_frame($_)) for load_fixture('84-2-off1-context-end.frames');
        is($boundaries->(), $before, "84.2-02 E: the off-1 context-end frames plant no boundary in connect");
        is($adds->($w2), 0, "84.2-02 E: and queue nothing in connect");
    }

    # --- Case F (D-15, real off-1 frames, MUST fire) ---
    my ($fCtl, $fDaemon, $fWs);
    {
        my @f = map { decode_frame($_) } load_fixture('84-2-off1-context-end.frames');
        is(scalar(@f), 7, "84.2-02 F setup: seven real off-1 frames");
        @Slim::Player::Playlist::ENTRIES = ( $mt->($sp->($W_7GVU)) );
        $Slim::Player::Source::INDEX = 0;
        ($fCtl, $fDaemon, $fWs) = $settled->('aa:84:2b:02:00:0f', $W_7GVU);
        my $before = $boundaries->();
        $fCtl->onEvent($_) for @f[0 .. 2];
        is($boundaries->(), $before, "84.2-02 F: no boundary while 7GVU plays at 194143 ms");
        is($fCtl->observed->{meta}{$W_7GVU}{duration}, 205.933, "84.2-02 F: duration 205.933 s learned from the playing frame");
        $fCtl->onEvent($_) for @f[3 .. 6];
        is($boundaries->(), $before + 1, "84.2-02 F: T3-owned POST /boundary count +1 exactly at the context end");
        is($cmds->($fWs, 'play'), 0, "84.2-02 F: no play at the context end");
        is($cmds->($fWs, 'pause'), 0, "84.2-02 F: no pause at the context end (the daemon is already paused)");
        is(scalar(@Plugins::SpotOn::Status::RECORDED), 0, "84.2-02 F: no errors[] entry (correct Spotify behaviour under Autoplay OFF)");
        is($fCtl->observed->{contextEndPlanted}, $W_7GVU, "84.2-02 F: T3-owned contextEndPlanted marks 7GVU");
        my $pre = $fCtl->observed->{preResetAnchor} || {};
        is_deeply({ map { $_ => $pre->{$_} } qw(position_ms speed timestamp_ms uri reset_ts) },
            { position_ms => 194143, speed => 1, timestamp_ms => 1791098280338, uri => $W_7GVU, reset_ts => 1791098291942 },
            "84.2-02 F: T3-owned preResetAnchor is the 194143 ms playing anchor, reset at 1791098291942");
        my $near = eval { $fCtl->_nearTitleEnd($W_7GVU) };
        ok($near, "84.2-02 F: T3-owned _nearTitleEnd(7GVU) is true (194143 + 11604 = 205747 >= 195933)");
        @Slim::Utils::Timers::TIMERS = ();
        my $mark = scalar @{ $fWs->sent };
        $fCtl->watchdogRing($W_7GVU);
        my @after = @{ $fWs->sent }[ $mark .. $#{ $fWs->sent } ];
        is(scalar(grep { $_->[0] eq 'play' } @after), 0, "84.2-02 F: T3-owned watchdog round 1 sends no play at a planted context end");
        is($fCtl->observed->{watchdogReason}, 'context end (no successor)', "84.2-02 F: T3-owned watchdogReason is 'context end (no successor)'");
        is(scalar(grep { $_->[0] == $fCtl && $_->[2] == \&Plugins::SpotOn::Soloist::Control::_watchdogRound2 } @Slim::Utils::Timers::TIMERS), 1,
            "84.2-02 F: the round-2 timer is still armed");
        @Slim::Utils::Timers::TIMERS = ();
    }

    # --- Case F4 (the plant marker does not survive a same-uri requestTrack:
    # LMS repeat-one's second loop plants again) -- continues on F's control ---
    {
        my @f = map { decode_frame($_) } load_fixture('84-2-off1-context-end.frames');
        $fCtl->requestTrack('spoton://track:7GVUmCP00eSsqc4tzj1sDD', 0, {});
        ok(!defined $fCtl->observed->{contextEndPlanted}, "84.2-02 F4: a same-uri requestTrack clears contextEndPlanted");
        ok(!defined $fCtl->observed->{preResetAnchor}, "84.2-02 F4: a same-uri requestTrack clears preResetAnchor");
        $fCtl->pending(undef);
        my $before = $boundaries->();
        $fCtl->onEvent($_) for @f;
        is($boundaries->(), $before + 1, "84.2-02 F4: T3-owned the second loop's context end plants again (+1)");
        @Slim::Player::Playlist::ENTRIES = ();
    }

    # --- Case F2 (D-15, real run7 frames fed in BROWSE, MUST fire) ---
    {
        my @f = map { decode_frame($_) } load_fixture('84-2-run7-context-end.frames');
        is(scalar(@f), 8, "84.2-02 F2 setup: eight real run7 frames");
        local @Slim::Player::Playlist::ENTRIES = ( $mt->($sp->($W_552L)) );
        local $Slim::Player::Source::INDEX = 0;
        my ($ctl, $daemon, $ws) = $settled->('aa:84:2b:02:00:f2', $W_552L);
        my $before = $boundaries->();
        $ctl->onEvent($_) for @f[0 .. 3];
        is($boundaries->(), $before, "84.2-02 F2: no boundary while 552l plays/buffers at 314298 ms");
        $ctl->onEvent($_) for @f[4 .. 7];
        is($boundaries->(), $before + 1, "84.2-02 F2: T3-owned POST /boundary count +1 exactly at the context end");
        is($cmds->($ws, 'play') + $cmds->($ws, 'pause'), 0, "84.2-02 F2: no play and no pause at the context end");
        is($ctl->observed->{contextEndPlanted}, $W_552L, "84.2-02 F2: T3-owned contextEndPlanted marks 552l");
        my $near = eval { $ctl->_nearTitleEnd($W_552L) };
        ok($near, "84.2-02 F2: T3-owned _nearTitleEnd(552l) is true (314298 speed 0 >= 307278)");
    }

    # --- Case F3 (D-16 pin): the same run7 frames in CONNECT plant nothing,
    # while the arithmetic still reads the title as ended ---
    {
        my @f = map { decode_frame($_) } load_fixture('84-2-run7-context-end.frames');
        local @Slim::Player::Playlist::ENTRIES = ( $mt->($sp->($W_552L)) );
        local $Slim::Player::Source::INDEX = 0;
        my ($ctl, $daemon, $ws) = $settled->('aa:84:2b:02:00:f3', $W_552L, mode => 'connect');
        my $before = $boundaries->();
        $ctl->onEvent($_) for @f;
        is($boundaries->(), $before, "84.2-02 F3: no boundary planted in connect (D-16)");
        is($cmds->($ws, 'play'), 0, "84.2-02 F3: no play in connect");
        ok(!defined $ctl->observed->{contextEndPlanted}, "84.2-02 F3: contextEndPlanted absent in connect");
        my $near = eval { $ctl->_nearTitleEnd($W_552L) };
        ok($near, "84.2-02 F3: T3-owned _nearTitleEnd(552l) is true on the Connect sequence too");
    }

    # --- Case G (D-15 negative, doctored off-1): a pause 5 s into the title
    # that happens to carry the reset signature plants nothing ---
    {
        my @raw = load_fixture('84-2-off1-context-end.frames');
        $raw[$_] =~ s/"position_ms":194143/"position_ms":5000/g for (1, 2);
        my @f = map { decode_frame($_) } @raw;
        is($f[1]{position}{position_ms}, 5000, "84.2-02 G setup: frames 2 and 3 doctored to 5000 ms");
        local @Slim::Player::Playlist::ENTRIES = ( $mt->($sp->($W_7GVU)) );
        local $Slim::Player::Source::INDEX = 0;
        my ($ctl, $daemon, $ws) = $settled->('aa:84:2b:02:00:09', $W_7GVU);
        my $before = $boundaries->();
        $ctl->onEvent($_) for @f;
        is($boundaries->(), $before, "84.2-02 G: an early pause with the reset signature plants no boundary (5000 + 11604 = 16604 < 195933)");
        ok(!defined $ctl->observed->{contextEndPlanted}, "84.2-02 G: contextEndPlanted absent");
    }

    # --- Case G2: the off-1 context-end frames while an own play is pending ---
    {
        my @f = map { decode_frame($_) } load_fixture('84-2-off1-context-end.frames');
        local @Slim::Player::Playlist::ENTRIES = ( $mt->($sp->($W_7GVU)) );
        local $Slim::Player::Source::INDEX = 0;
        my ($ctl, $daemon, $ws) = $settled->('aa:84:2b:02:00:92', $W_7GVU);
        $ctl->onEvent($_) for @f[0 .. 2];
        $ctl->pending({ cmd => 'play', uri => $W_7GVU, sentAt => Time::HiRes::time() });
        my $before = $boundaries->();
        $ctl->onEvent($_) for @f[3 .. 6];
        is($boundaries->(), $before, "84.2-02 G2: no boundary while an own play is pending");
        ok(!defined $ctl->observed->{contextEndPlanted}, "84.2-02 G2: contextEndPlanted absent");
    }

    # --- Case G3 (real mid-title pause, B7 074810 lines 42-46, MUST NOT fire) ---
    {
        my @f = map { decode_frame($_) } load_fixture('84-2-b7-0748-midtitle-pause.frames');
        is(scalar(@f), 5, "84.2-02 G3 setup: five real B7 frames");
        local @Slim::Player::Playlist::ENTRIES = ( $mt->($sp->($W_552L)) );
        local $Slim::Player::Source::INDEX = 0;
        my ($ctl, $daemon, $ws) = $settled->('aa:84:2b:02:00:93', $W_552L);
        my $before = $boundaries->();
        $ctl->onEvent($_) for @f;
        is($boundaries->(), $before, "84.2-02 G3: the real mid-title pause plants no boundary");
        is($cmds->($ws, 'play'), 0, "84.2-02 G3: no play");
        ok(!defined $ctl->observed->{contextEndPlanted}, "84.2-02 G3: contextEndPlanted absent");
        is($ctl->observed->{anchor}{position_ms}, 24738, "84.2-02 G3: the anchor stays at 24738 (a pause, not a reset)");
    }

    # --- Case G4 (real seek, B7 074810 lines 18-22, MUST NOT fire) ---
    {
        my @f = map { decode_frame($_) } load_fixture('84-2-b7-0748-seek.frames');
        is(scalar(@f), 5, "84.2-02 G4 setup: five real B7 frames");
        local @Slim::Player::Playlist::ENTRIES = ( $mt->($sp->($W_AFRICA)) );
        local $Slim::Player::Source::INDEX = 0;
        my ($ctl, $daemon, $ws) = $settled->('aa:84:2b:02:00:94', $W_AFRICA);
        my $before = $boundaries->();
        $ctl->onEvent($_) for @f;
        is($boundaries->(), $before, "84.2-02 G4: the real seek plants no boundary");
        is($cmds->($ws, 'play'), 0, "84.2-02 G4: no play");
        ok(!defined $ctl->observed->{contextEndPlanted}, "84.2-02 G4: contextEndPlanted absent");
        is($ctl->observed->{status}, 'playing', "84.2-02 G4: status playing after the seek");
    }

    # --- Case G5 (the B7 leftover reset, plan 01's fixture replayed as in
    # 84.2-01 case D): the 6d0c reset belongs to plan 01's guard ---
    {
        my $Q_X = $TID;
        my @f = map { decode_frame($_) } load_fixture('84-2-b7-0748-leftover.frames');
        my ($ctl, $daemon, $ws);
        {
            local @Slim::Player::Playlist::ENTRIES = ( $mt->($sp->($Q_X)), $mt->($sp->($W_6D0C)) );
            local $Slim::Player::Source::INDEX = 0;
            @Plugins::SpotOn::Status::RECORDED = ();
            ($ctl, $daemon, $ws) = fresh_control(
                mac      => 'aa:84:2b:02:00:95',
                mode     => 'browse',
                observed => { wsConnected => 1, paired => 1, is_active => 1, meta => { $Q_X => { duration => 200 } },
                              track => 'spotify:track:previousXYZ', status => 'playing' },
            );
            $ctl->requestTrack($Q_X, 0, {});
            $ctl->onEvent(decode_frame(load_fixture('track_changed.json')));
            $ctl->pending(undef);
            local $Slim::Player::Source::PLAYMODE = 'stop';
            $ctl->requestPause(1);
        }
        {
            local @Slim::Player::Playlist::ENTRIES = (
                $mt->($sp->($W_AFRICA)),
                $mt->('file:///var/tmp/spoton-b7/local-30s.wav'),
                $mt->('spoton://track:552lBxKLGjerBDS8VYHOJn'),
            );
            local $Slim::Player::Source::INDEX = 0;
            $ctl->observed->{meta}{$W_AFRICA} = { duration => 295 };
            $ctl->requestTrack($W_AFRICA, 0, {});
            $ctl->onEvent($f[0]);
            $ctl->onEvent($f[1]);
            $ctl->pending(undef);
            # the foreign 6d0c track_changed plants its own boundary (plan 01's
            # guard path); count from after it, so only the detector is measured
            $ctl->onEvent($f[2]);
            my $before = $boundaries->();
            $ctl->onEvent($f[3]);
            $ctl->onEvent($f[4]);
            is($boundaries->(), $before, "84.2-02 G5: the leftover 6d0c reset plants nothing through the detector");
            ok(!defined $ctl->observed->{contextEndPlanted}, "84.2-02 G5: contextEndPlanted absent");
        }
    }

    # --- Case G6 (the uri tag, real B7 074810 lines 23-29, MUST NOT fire):
    # a new title picked in LMS during the last 10 s of the previous one ---
    {
        my @f = map { decode_frame($_) } load_fixture('84-2-b7-0748-late-pick.frames');
        is(scalar(@f), 7, "84.2-02 G6 setup: seven real B7 frames");
        local @Slim::Player::Playlist::ENTRIES = ( $mt->($sp->($W_AFRICA)), $mt->($sp->($W_6D0C)) );
        local $Slim::Player::Source::INDEX = 0;
        my ($ctl, $daemon, $ws) = $settled->('aa:84:2b:02:00:96', $W_AFRICA, observed => { meta => { $W_AFRICA => { duration => 295.282 } } });
        $ctl->onEvent($_) for @f[0 .. 2];
        is($ctl->observed->{anchor}{position_ms}, 292333, "84.2-02 G6 setup: Africa's anchor is 292333 (speed 0)");
        $Slim::Player::Source::INDEX = 1;
        $ctl->requestTrack('spoton://track:6d0cIiukgZJ8fZBJFqDMBT', 0, {});
        my $mark   = scalar @{ $ws->sent };
        my $before = $boundaries->();
        $ctl->onEvent($_) for @f[3 .. 6];
        my $pre = $ctl->observed->{preResetAnchor} || {};
        is_deeply({ map { $_ => $pre->{$_} } qw(position_ms speed uri reset_ts) },
            { position_ms => 292333, speed => 0, uri => $W_AFRICA, reset_ts => 1791524925317 },
            "84.2-02 G6: T3-owned preResetAnchor is Africa's 292333 anchor, tagged with Africa's uri");
        is($ctl->observed->{meta}{$W_6D0C}{duration}, 207.682, "84.2-02 G6: 6d0c's duration 207.682 s is known (the tag, not a missing duration, decides)");
        my $near = eval { $ctl->_nearTitleEnd($W_6D0C) };
        ok(!$@ && defined $near && !$near, "84.2-02 G6: T3-owned _nearTitleEnd(6d0c) is false (the pre-reset anchor belongs to Africa)");
        my @after = @{ $ws->sent }[ $mark .. $#{ $ws->sent } ];
        is($boundaries->(), $before, "84.2-02 G6: no boundary planted for 6d0c");
        is(scalar(grep { $_->[0] eq 'play' || $_->[0] eq 'pause' } @after), 0, "84.2-02 G6: no play and no pause");
        ok(!defined $ctl->observed->{contextEndPlanted}, "84.2-02 G6: contextEndPlanted absent");
    }
}

# ===== 84.2-05: B6 dormant-session handoff, B7 resume refusal + adoption hold (gap closure) =====
# Debug session b6-prefetch-b7-africa-replay (recurrence_guard). B6: Control
# stayed in a DORMANT connect session inherited from H3 (claim bound, daemon
# paused on its title at 0:00, LMS stopped) and requestTrack's same-uri branch
# kept connect for a user's Browse play of exactly that title, so every 84.2-02
# mechanism (all gated on browse) stayed off. The repaired rule decides from two
# positive signals: (a) Connect's one-shot dispatch marker (`origin => 'connect'`,
# derived by ProtocolHandler::getNextTrack) or (d) the daemon actively playing
# the title -- either keeps the D-A1/D-A3 re-open; neither (paused/stopped/idle,
# unmarked = producer P12) hands over to browse. B7: LMS's StreamingController
# _Rebuffer/_Resume unpause at the planted boundary reached requestResume as a
# user unpause and resumed the wrapped title; the next get_state reply adopted
# the still-playing daemon as a Connect session under a local file.
{
    my $W_7GVU = 'spotify:track:7GVUmCP00eSsqc4tzj1sDD';    # off-1 context end (duration 205933)
    my $mt  = sub { Test::MockTrack->new($_[0]) };
    my $sp  = sub { my ($u) = @_; $u =~ s/^spotify:track:/spoton:\/\/track:/; return $u };
    my $adds = sub {
        my ($ws, $uri) = @_;
        return scalar(grep { $_->[0] eq 'add_to_queue' && (!defined $uri || ($_->[1]{uri} // '') eq $uri) } @{ $ws->sent });
    };
    my $cmds = sub { my ($ws, $cmd) = @_; return scalar(grep { $_->[0] eq $cmd } @{ $ws->sent }); };
    my $settled = sub {
        my ($mac, $uri, %more) = @_;
        @Plugins::SpotOn::Status::RECORDED = ();
        return fresh_control(
            mac      => $mac,
            mode     => ($more{mode} // 'browse'),
            wanted   => { uri => $uri, playing => 1 },
            observed => { wsConnected => 1, paired => 1, is_active => 1, meta => {}, track => $uri,
                          status => 'playing', %{ $more{observed} || {} } },
        );
    };
    # A browse control on 7GVU after the seven real off-1 context-end frames
    # (84.2-02 case F's shape): the daemon sits paused at ~0 on 7GVU, the
    # boundary is planted, contextEndPlanted reads 7GVU.
    my $planted = sub {
        my ($mac) = @_;
        my @f = map { decode_frame($_) } load_fixture('84-2-off1-context-end.frames');
        @Slim::Player::Playlist::ENTRIES = ( $mt->($sp->($W_7GVU)) );
        $Slim::Player::Source::INDEX = 0;
        my ($ctl, $daemon, $ws) = $settled->($mac, $W_7GVU);
        $ctl->onEvent($_) for @f;
        return ($ctl, $daemon, $ws);
    };

    # --- Case A (B7 resume refusal, real off-1 frames). The real sender is LMS's
    # StreamingController _Resume -> ['playlist','pause',0] -> Connect.pm _onPause
    # (isUnpause) -> requestResume: a one-line forward with no condition of its own
    # and no Control state, unchanged by 84.2-05 and outside t/44 (Connect.pm is a
    # stub here; t/37 pins its subscriber set). The refusal is the Control-side
    # guard; 84.2-04 R7 reads the live INFO line through extract-run.pl. ---
    {
        my $mac = 'aa:84:2b:05:00:0a';
        my ($ctl, $daemon, $ws) = $planted->($mac);
        is($ctl->observed->{contextEndPlanted}, $W_7GVU, "84.2-05 A setup: the real off-1 frames planted 7GVU's context end");
        own_track($mac);
        @Plugins::SpotOn::Status::RECORDED = ();
        my $mark = scalar @{ $ws->sent };
        $ctl->requestResume;
        my @after = @{ $ws->sent }[ $mark .. $#{ $ws->sent } ];
        is(scalar(grep { $_->[0] eq 'play' } @after), 0,
            "84.2-05 A: LMS's rebuffer unpause on the planted title is refused -- no play (the wrapped title is not resumed)");
        is($ctl->wanted->{playing}, 1, "84.2-05 A: wanted.playing stays 1 (the refusal does not clear the wish)");
        is($ctl->wanted->{uri}, $W_7GVU, "84.2-05 A: wanted.uri untouched");
        is(scalar(@Plugins::SpotOn::Status::RECORDED), 0, "84.2-05 A: the refusal records no errors[] entry");
        is($ctl->observed->{contextEndPlanted}, $W_7GVU, "84.2-05 A: a refusal does not consume the plant marker");
        @Slim::Player::Playlist::ENTRIES = ();
    }

    # --- Case A2 (MUST-PASS twin): no plant marker, the daemon paused on the
    # wanted title -> a genuine unpause sends exactly one bare play (84-26 R1 Fall B) ---
    {
        my $mac = 'aa:84:2b:05:00:a2';
        my ($ctl, $daemon, $ws) = $settled->($mac, $W_7GVU, observed => { status => 'paused' });
        own_track($mac);
        $ctl->requestResume;
        is_deeply($ws->sent, [ [ 'play', {} ] ], "84.2-05 A2: without a plant marker the genuine unpause sends exactly one bare play");
    }

    # --- Cases B-B4: the same-uri getNextTrack in connect, classified by the
    # producer table of 84.2-05-PLAN.md (P1-P14) ---
    my $X = 'spotify:track:8405DormantTitleXXXXXX';
    my $Y = 'spotify:track:8405SuccessorYYYYYYYYY';
    my $dormant = sub {
        my ($mac, $status) = @_;
        return fresh_control(
            mac => $mac, mode => 'connect',
            observed => { wsConnected => 1, paired => 1, is_active => 1, meta => {}, track => $X, status => $status },
        );
    };

    # Case B (producer P12, the measured B6 21:50 state): an UNMARKED LMS play of
    # the daemon's paused title into a dormant connect session -> browse; the
    # 84.2-02 prefetch wish engages for the successor.
    {
        my $mac = 'aa:84:2b:05:00:0b';
        my ($ctl, $daemon, $ws) = $dormant->($mac, 'paused');
        own_track($mac, $sp->($X));
        local @Slim::Player::Playlist::ENTRIES = ( $mt->($sp->($X)), $mt->($sp->($Y)) );
        local $Slim::Player::Source::INDEX = 0;
        $ctl->requestTrack($sp->($X), 0, { source => 'getNextTrack', successCb => sub {}, errorCb => sub {} });
        is($ctl->mode, 'browse', "84.2-05 B: an unmarked LMS play of the daemon's paused title in a dormant connect session hands over to browse");
        $ctl->pending(undef);
        $ctl->notePlaylistChanged;
        is($adds->($ws, $Y), 1, "84.2-05 B: in browse the 84.2-02 wish queues the successor exactly once");
    }

    # Case B2 (MUST-PASS, producers P1-P5): the same shape carrying Connect's own
    # dispatch marker stays connect (D-A1/D-A3); nothing queued (Pitfall 4).
    {
        my $mac = 'aa:84:2b:05:00:b2';
        my ($ctl, $daemon, $ws) = $dormant->($mac, 'paused');
        own_track($mac, $sp->($X));
        local @Slim::Player::Playlist::ENTRIES = ( $mt->($sp->($X)), $mt->($sp->($Y)) );
        local $Slim::Player::Source::INDEX = 0;
        $ctl->requestTrack($sp->($X), 0, { source => 'getNextTrack', origin => 'connect', successCb => sub {}, errorCb => sub {} });
        is($ctl->mode, 'connect', "84.2-05 B2: Connect's own marked re-open of the paused title stays connect");
        $ctl->pending(undef);
        $ctl->notePlaylistChanged;
        is($adds->($ws), 0, "84.2-05 B2: nothing is queued in connect");
    }

    # Case B3 (the different-uri handoff is untouched): marker or not, a
    # DIFFERENT uri means LMS took over.
    {
        my $mac = 'aa:84:2b:05:00:b3';
        my ($ctl, $daemon, $ws) = $dormant->($mac, 'paused');
        own_track($mac, $sp->($Y));
        local @Slim::Player::Playlist::ENTRIES = ( $mt->($sp->($X)), $mt->($sp->($Y)) );
        local $Slim::Player::Source::INDEX = 1;
        $ctl->requestTrack($sp->($Y), 0, { source => 'getNextTrack', origin => 'connect', successCb => sub {}, errorCb => sub {} });
        is($ctl->mode, 'browse', "84.2-05 B3: a different uri hands over to browse even with the marker");
    }

    # Case B4 (producers P8/P13, the safe default): an UNMARKED re-open of the
    # title the daemon is actively PLAYING stays connect; nothing queued.
    {
        my $mac = 'aa:84:2b:05:00:b4';
        my ($ctl, $daemon, $ws) = $dormant->($mac, 'playing');
        own_track($mac, $sp->($X));
        local @Slim::Player::Playlist::ENTRIES = ( $mt->($sp->($X)), $mt->($sp->($Y)) );
        local $Slim::Player::Source::INDEX = 0;
        $ctl->requestTrack($sp->($X), 0, { source => 'getNextTrack', successCb => sub {}, errorCb => sub {} });
        is($ctl->mode, 'connect', "84.2-05 B4: an unmarked re-open of the title the daemon PLAYS stays connect (safe default)");
        $ctl->pending(undef);
        $ctl->notePlaylistChanged;
        is($adds->($ws), 0, "84.2-05 B4: nothing is queued in connect");
    }

    # --- Cases C-C3 (B7 adoption hold): after leaveBrowse of a planted title, a
    # playback_state(is_active, playing) frame naming that title is NOT adopted
    # while LMS plays foreign content (84-26 R3's clause shape; url class +
    # marker, never a time window). ---
    my $r3_frame = sub {
        my ($uri) = @_;
        return { type => 'playback_state', item => { uri => $uri }, status => 'playing', is_active => 1, volume => 60,
                 position => { position_ms => 5000, timestamp_ms => 1000, speed => 1 } };
    };
    my $left = sub {
        my ($mac) = @_;
        my ($ctl, $daemon, $ws) = $planted->($mac);
        $ctl->leaveBrowse;
        @Plugins::SpotOn::Connect::CLAIMS = (); $Plugins::SpotOn::Connect::ACTIVE = undef;
        @Slim::Player::Client::EXECUTED   = ();
        return ($ctl, $daemon, $ws);
    };

    # Case C: LMS plays a local file -> hold (the 22:05:45 chain)
    {
        my $mac = 'aa:84:2b:05:00:0c';
        my ($ctl, $daemon, $ws) = $left->($mac);
        is($ctl->mode, 'idle', "84.2-05 C setup: leaveBrowse left mode idle");
        ok(!exists $ctl->observed->{contextEndPlanted}, "84.2-05 C setup: contextEndPlanted is cleared by leaveBrowse");
        is($ctl->observed->{leftBrowsePlanted}, $W_7GVU, "84.2-05 C setup: leaveBrowse records the planted title as leftBrowsePlanted");
        foreign_track($mac);
        local $Slim::Player::Source::PLAYMODE = 'play';
        $ctl->onEvent($r3_frame->($W_7GVU));
        is($ctl->mode, 'idle', "84.2-05 C: the context-end title the daemon plays is not adopted while LMS plays a local file");
        is(scalar(grep { $_->[0] eq 'bind' } @Plugins::SpotOn::Connect::CLAIMS), 0, "84.2-05 C: no claim bind");
        is(scalar(@Slim::Player::Client::EXECUTED), 0, "84.2-05 C: no start emission (no LMS command)");
        is($ctl->observed->{leftBrowsePlanted}, $W_7GVU, "84.2-05 C: the marker stays while the hold applies");
        @Slim::Player::Playlist::ENTRIES = ();
    }

    # Case C2 (MUST-PASS): LMS stopped -> the IN-02 reconnect adoption (D-02), marker dropped
    {
        my $mac = 'aa:84:2b:05:00:c2';
        my ($ctl, $daemon, $ws) = $left->($mac);
        foreign_track($mac);
        local $Slim::Player::Source::PLAYMODE = 'stop';
        $ctl->onEvent($r3_frame->($W_7GVU));
        is($ctl->mode, 'connect', "84.2-05 C2: LMS stopped -- the daemon playing the planted title is adopted (IN-02, D-02)");
        ok(!exists $ctl->observed->{leftBrowsePlanted}, "84.2-05 C2: the marker is dropped when the predicate falls through");
        $Plugins::SpotOn::Connect::ACTIVE = undef; @Plugins::SpotOn::Connect::CLAIMS = ();
        @Slim::Player::Playlist::ENTRIES = ();
    }

    # Case C3 (MUST-PASS): LMS plays our own material -> adopted (legitimate)
    {
        my $mac = 'aa:84:2b:05:00:c3';
        my ($ctl, $daemon, $ws) = $left->($mac);
        own_track($mac);
        local $Slim::Player::Source::PLAYMODE = 'play';
        $ctl->onEvent($r3_frame->($W_7GVU));
        is($ctl->mode, 'connect', "84.2-05 C3: LMS plays our own material -- the adoption is legitimate");
        $Plugins::SpotOn::Connect::ACTIVE = undef; @Plugins::SpotOn::Connect::CLAIMS = ();
        @Slim::Player::Playlist::ENTRIES = ();
    }
}

# ============================================================
# 85-07 Task 1 (D-09): Up Next comes from the playback helper. A
# queue_changed frame (unsolicited AND the reply to get_queue -- 85-03
# D09-QUEUE: reply type queue_changed, no new frame type) fills a bounded
# observed.upNext cache; requestQueue asks at most once per 5 s; the
# queueUris/queueHead/queuedNext bookkeeping is untouched.
# ============================================================
{
    my $q_item = sub {
        my (%a) = @_;
        return {
            uid    => ($a{uid} // 'u0'),
            source => ($a{source} // 'autoplay'),
            item   => {
                uri         => $a{uri},
                entity_type => ($a{entity_type} // 'track'),
                decorations => {
                    identity        => { name => $a{name} },
                    visual_identity => { cover => [ { url => 'https://i.scdn.co/image/ab67616d0000b273aaaa', size => 'large' } ] },
                    creators        => [ { entity => { uri => 'spotify:artist:ART1', entity_type => 'artist', decorations => { identity => { name => 'Artist One' } } } } ],
                    playback        => { duration_ms => 111000 },
                },
            },
        };
    };

    # --- s01 line 20 (the queue_changed fixture) -> one normalized entry ---
    {
        my @lines = load_fixture('s01-pure-daemon-queue.jsonl');
        my ($qcLine) = grep { /"uid":"q0"/ } @lines;
        my ($ctl) = fresh_control(mac => 'aa:bb:cc:dd:85:01', observed => { wsConnected => 1, meta => {} });
        $ctl->onEvent(decode_frame($qcLine));
        my $up = $ctl->observed->{upNext};
        is(ref($up), 'ARRAY', "85-07 D-09: queue_changed fixture fills observed.upNext");
        is(scalar(@{ $up || [] }), 1, "85-07 D-09: the fixture's one upcoming entry is cached");
        my $e = ($up || [])->[0] || {};
        is($e->{uri}, 'spotify:track:3n3Ppam7vgaVa1iaRUc9Lp', "85-07 D-09: cached entry uri");
        is($e->{name}, 'Mr. Brightside', "85-07 D-09: cached entry name");
        is_deeply($e->{artists}, [ { name => 'The Killers', id => '0C0XlULifJtAgn6ZNCW2eu' } ], "85-07 D-09: cached entry artists from creators[]");
        is($e->{album}{name}, 'Hot Fuss', "85-07 D-09: cached entry album name from parent");
        is($e->{album}{id}, '4OHNH3sDzIxnmUADXzv2kT', "85-07 D-09: cached entry album id from parent uri");
        is($e->{duration_ms}, 222000, "85-07 D-09: cached entry duration_ms");
        is($e->{album}{images}[-1]{url}, 'https://i.scdn.co/image/ab67616d0000b2739c284a6855f4945dc5a3cd73',
            "85-07 D-09: cover list kept (largest last-by-width ordering is _largestImage's job)");
        ok((grep { ($_->{width} // 0) >= 640 } @{ $e->{album}{images} }), "85-07 D-09: cover entries carry a width so _largestImage picks the large one");
        is($ctl->observed->{queuedNext}, 'spotify:track:3n3Ppam7vgaVa1iaRUc9Lp', "85-07 D-09: queuedNext bookkeeping unchanged");
    }

    # --- the get_queue reply (s85 fixture, same frame type) fills the same cache ---
    {
        # each fixture line is {"frame": "<json text>", "dir": ...}; the inner
        # text is already character data after the outer decode
        my @recorded = load_fixture('s85-get-queue-reply.jsonl');
        my @rx = grep { ref($_) eq 'HASH' && ($_->{dir} // '') eq 'rx' } map { decode_frame($_) } @recorded;
        my ($qc) = grep { ref($_) eq 'HASH' && ($_->{type} // '') eq 'queue_changed' } map { eval { JSON::PP->new->decode($_->{frame}) } } @rx;
        ok($qc, "85-07 D-09: s85 get_queue reply fixture carries a queue_changed frame");
        my ($ctl) = fresh_control(mac => 'aa:bb:cc:dd:85:02', observed => { wsConnected => 1, meta => {} });
        $ctl->onEvent($qc);
        my $up = $ctl->observed->{upNext} || [];
        is(scalar(@$up), scalar(@{ $qc->{upcoming} }), "85-07 D-09: every upcoming entry of the reply is cached (10)");
        is($up->[0]{name}, 'Vandalist', "85-07 D-09: reply entry 0 name");
        is_deeply([ map { $_->{name} } @{ $up->[1]{artists} } ], [ 'Tokischa', 'Austin Millz', 'Haraca Kiko', 'Leo RD', 'El Cherry Scom' ],
            "85-07 D-09: reply entry 1 keeps all five creators in order");
        ok((grep { $_->{name} eq 'where' . "\x{2019}" . 's my lighter' } @$up), "85-07 D-09: non-ASCII names survive unchanged");
    }

    # --- bounded at 20; non-track/episode uris and malformed entries skipped ---
    {
        my ($ctl) = fresh_control(mac => 'aa:bb:cc:dd:85:03', observed => { wsConnected => 1, meta => {} });
        my @many = map { $q_item->(uid => "m$_", uri => sprintf('spotify:track:T%03d', $_), name => "Title $_") } 1 .. 25;
        $ctl->onEvent({ type => 'queue_changed', previous => [], upcoming => \@many });
        is(scalar(@{ $ctl->observed->{upNext} }), 20, "85-07 T-85-24: the cache is bounded at 20 entries");
        is($ctl->observed->{upNext}[19]{uri}, 'spotify:track:T020', "85-07 T-85-24: the FIRST 20 entries are kept, in order");

        my @mixed = (
            $q_item->(uid => 'x1', uri => 'spotify:ad:AAA111',          name => 'An ad', entity_type => 'ad'),
            $q_item->(uid => 'x2', uri => 'spotify:local:a:b:c:1',      name => 'Local file'),
            $q_item->(uid => 'x3', uri => 'spotify:track:GOOD1',        name => 'Good one'),
            'not-a-hash',
            { uid => 'x4', source => 'queue', item => 'not-a-hash' },
            { uid => 'x5', source => 'queue', item => { uri => 'spotify:track:NONAME1' } },
            { uid => 'x6', source => 'queue', item => { uri => 'spotify:track:BADDEC1', decorations => 'oops' } },
            $q_item->(uid => 'x7', uri => 'spotify:episode:EPI1',       name => 'An episode', entity_type => 'episode'),
        );
        $ctl->onEvent({ type => 'queue_changed', previous => [], upcoming => \@mixed });
        is_deeply([ map { $_->{uri} } @{ $ctl->observed->{upNext} } ], [ 'spotify:track:GOOD1', 'spotify:episode:EPI1' ],
            "85-07 T-85-24: ads, local files and malformed entries are skipped, tracks and episodes kept");

        my $ok = eval { $ctl->onEvent({ type => 'queue_changed', previous => [], upcoming => 'garbage' }); 1 };
        ok($ok, "85-07 T-85-24: a non-array upcoming does not die");
        is_deeply([ map { $_->{uri} } @{ $ctl->observed->{upNext} } ], [ 'spotify:track:GOOD1', 'spotify:episode:EPI1' ],
            "85-07 T-85-24: a non-array upcoming leaves the cache as it was");
    }

    # --- a placeholder frame (every uid node_rules_placeholder) is not a queue state ---
    {
        my ($ctl) = fresh_control(mac => 'aa:bb:cc:dd:85:04', observed => { wsConnected => 1, meta => {} });
        $ctl->onEvent({ type => 'queue_changed', previous => [], upcoming => [ $q_item->(uid => 'real1', uri => 'spotify:track:REAL1', name => 'Real') ] });
        $ctl->onEvent({ type => 'queue_changed', previous => [], upcoming => [ $q_item->(uid => 'node_rules_placeholder', uri => 'spotify:track:PLACE1', name => 'Placeholder') ] });
        is_deeply([ map { $_->{uri} } @{ $ctl->observed->{upNext} } ], [ 'spotify:track:REAL1' ],
            "85-07 D-09: a placeholder queue_changed does not replace the cache");
    }

    # --- queueUris / queueHead untouched by the cache ---
    {
        my ($ctl) = fresh_control(mac => 'aa:bb:cc:dd:85:05', observed => { wsConnected => 1, meta => {} });
        $ctl->onEvent(n4_queue_changed([ 'q1', 'queue', 'spotify:track:HEAD1' ], [ 'q2', 'context', 'spotify:track:CTX1' ]));
        is_deeply($ctl->observed->{queueUris}, [ 'spotify:track:HEAD1' ], "85-07 D-09: queueUris bookkeeping unchanged");
        is($ctl->observed->{queueHead}{uri}, 'spotify:track:HEAD1', "85-07 D-09: queueHead bookkeeping unchanged");
        is(scalar(@{ $ctl->observed->{upNext} || [] }), 0, "85-07 D-09: entries without decorations (bare uri) are not renderable and are skipped");
    }

    # --- requestQueue: one get_queue (limit 20) per QUEUE_REQUEST_MIN_INTERVAL_S ---
    {
        is(Plugins::SpotOn::Soloist::Control::QUEUE_REQUEST_MIN_INTERVAL_S(), 5, "85-07 T-85-23: QUEUE_REQUEST_MIN_INTERVAL_S is 5");
        my ($ctl, $daemon, $ws) = fresh_control(mac => 'aa:bb:cc:dd:85:06', observed => { wsConnected => 1, meta => {} });
        $ctl->requestQueue;
        is_deeply($ws->sent, [ [ 'get_queue', { limit => 20 } ] ], "85-07 D-09: requestQueue sends get_queue with limit 20");
        $ctl->requestQueue;
        is(scalar(@{ $ws->sent }), 1, "85-07 T-85-23: a second requestQueue inside 5 s sends nothing");
        $ctl->_lastQueueRequestAt(Time::HiRes::time() - 6);
        $ctl->requestQueue;
        is(scalar(@{ $ws->sent }), 2, "85-07 T-85-23: after 5 s the next requestQueue asks again");

        my ($ctl2, $daemon2, $ws2) = fresh_control(mac => 'aa:bb:cc:dd:85:07', observed => { wsConnected => 1, meta => {} });
        $ctl2->observed->{is_active} = 0;
        my $ok = eval { $ctl2->requestQueue; 1 };
        ok($ok, "85-07 D-09: requestQueue never dies");
        is($ws2->sent->[0][0], 'get_queue', "85-07 D-09: get_queue is a read-only query, allowed while inactive");
    }

    # --- queueSnapshot: copy, current from observed.track + cached item ---
    {
        my ($ctl) = fresh_control(mac => 'aa:bb:cc:dd:85:08', observed => { wsConnected => 1, meta => {} });
        my $snap0 = $ctl->queueSnapshot;
        is_deeply($snap0, { current => undef, upcoming => [] }, "85-07 D-09: queueSnapshot of an unknown queue is empty");

        $ctl->onEvent({ type => 'playback_state', status => 'playing', item => $q_item->(uri => 'spotify:track:CUR1', name => 'Current')->{item} });
        $ctl->onEvent({ type => 'queue_changed', previous => [], upcoming => [ $q_item->(uid => 'n1', uri => 'spotify:track:NXT1', name => 'Next 1') ] });
        my $snap = $ctl->queueSnapshot;
        is($snap->{current}{uri}, 'spotify:track:CUR1', "85-07 D-09: current is the playing item's entry");
        is($snap->{current}{name}, 'Current', "85-07 D-09: current carries the name from the frame");
        is_deeply([ map { $_->{uri} } @{ $snap->{upcoming} } ], [ 'spotify:track:NXT1' ], "85-07 D-09: upcoming from the cache");

        $snap->{upcoming}[0]{name} = 'MUTATED';
        push @{ $snap->{upcoming} }, { uri => 'spotify:track:X' };
        is($ctl->observed->{upNext}[0]{name}, 'Next 1', "85-07 D-09: queueSnapshot is a deep copy (entry)");
        is(scalar(@{ $ctl->observed->{upNext} }), 1, "85-07 D-09: queueSnapshot is a deep copy (list)");

        $ctl->onEvent({ type => 'track_changed', item => $q_item->(uri => 'spotify:track:CUR2', name => 'Second')->{item} });
        is($ctl->queueSnapshot->{current}{uri}, 'spotify:track:CUR2', "85-07 D-09: current follows track_changed");
    }
}

# ============================================================
# D-34 (79-48): during LMS-started Browse on Soloist, LMS stays the owner of
# everything that moves within its list; Control forwards only a daemon
# transport change it did not request itself. Frames are the real recorder
# frames of 79-46 (t/fixtures/uat/d34-*.log, the cases named in 79-D34-RULE.md).
# ============================================================
my $D34_SRC = Plugins::SpotOn::Soloist::Control::BROWSE_FORWARD_SOURCE();    # Control's source marker
my $D34_T1 = 'spotify:track:7GVUmCP00eSsqc4tzj1sDD';
my $D34_T2 = 'spotify:track:2374M0fQpWi3dLnB54qaLX';

# d34_case($file, $case) -- the rx frames of one case of a fixture, in order:
# [ { ts => 'HH:MM:SS.mmm', epoch => <float>, msg => <decoded frame> }, ... ].
sub d34_case {
    my ($file, $want) = @_;
    open(my $fh, '<', "$project_dir/t/fixtures/uat/$file") or die "fixture $file missing";
    my ($cur, @out);
    my $json = JSON::PP->new->utf8(1);
    while (my $line = <$fh>) {
        chomp $line;
        next unless length $line;
        my $o = $json->decode($line);
        if ($o->{dir} eq 'meta') { ($cur) = $o->{frame} =~ /CASE (\w+)/; next; }
        next unless defined $cur && $cur eq $want && $o->{dir} eq 'rx';
        push @out, { ts => $o->{ts}, epoch => $o->{epoch}, msg => $json->decode($o->{frame}) };
    }
    close($fh);
    die "fixture $file has no case $want" unless @out;
    return \@out;
}

# d34_age($ctl, $gap) -- the fixture's own clock between two frames: every
# wall-clock stamp Control keeps is moved $gap seconds into the past, so the
# anchor arithmetic and the echo/takeover windows see the recorded spacing.
sub d34_age {
    my ($ctl, $gap) = @_;
    return unless $gap > 0;
    my $o = $ctl->observed;
    for my $k (qw(anchor preResetAnchor entryAnchor)) {
        my $a = $o->{$k} or next;
        for my $f (qw(seen_at seen_hr reset_hr)) { $a->{$f} -= $gap if defined $a->{$f}; }
    }
    if (ref($o->{ownSend}) eq 'HASH') { $o->{ownSend}{$_} -= $gap for keys %{ $o->{ownSend} }; }
    $o->{expectEcho}{until} -= $gap if ref($o->{expectEcho}) eq 'HASH' && defined $o->{expectEcho}{until};
    $o->{seekIssued}{at}    -= $gap if ref($o->{seekIssued}) eq 'HASH' && defined $o->{seekIssued}{at};
    $o->{ctxForeign}{hr}    -= $gap if ref($o->{ctxForeign}) eq 'HASH' && defined $o->{ctxForeign}{hr};
}

my %D34_LAST;
# d34_feed($ctl, $frames, %o) -- hands the frames to onEvent in order, aging
# Control's stamps by the recorded gap before each one. o{from}/o{to} bound
# the slice by fixture ts (inclusive, string compare on HH:MM:SS.mmm); o{at}
# is a list of [ts, coderef]: an own command Control itself issued in the
# recorded run (an LMS command), run before the first frame at or after ts.
sub d34_feed {
    my ($ctl, $frames, %o) = @_;
    my @at = sort { $a->[0] cmp $b->[0] } @{ $o{at} || [] };
    my $key = Scalar::Util::refaddr($ctl);
    for my $f (@$frames) {
        next if defined $o{from} && $f->{ts} lt $o{from};
        last if defined $o{to}   && $f->{ts} gt $o{to};
        d34_age($ctl, $f->{epoch} - $D34_LAST{$key}) if defined $D34_LAST{$key};
        $D34_LAST{$key} = $f->{epoch};
        while (@at && $at[0][0] le $f->{ts}) { (shift @at)->[1]->(); }
        $ctl->onEvent($f->{msg});
    }
}

# d34_session($mac, %o) -- a Browse session LMS started: requestTrack(T1)
# from idle, so the own `play` is pending and its echo is the first
# track_changed of the recorded case. The title length is known (the
# context-end test needs it). o{mode} 'connect' builds the connect row
# instead; o{started} 0 skips requestTrack.
sub d34_session {
    my ($mac, %o) = @_;
    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => $mac,
        observed => { wsConnected => 1, is_active => 1, meta => { $D34_T1 => { duration => 203 }, $D34_T2 => { duration => 180 } } },
    );
    delete $D34_LAST{ Scalar::Util::refaddr($ctl) };
    if (($o{mode} // '') eq 'connect') {
        $ctl->mode('connect');
        $ctl->wanted({ uri => $D34_T1, position_ms => 0, playing => 1 });
        $ctl->observed->{track}  = $D34_T1;
        $ctl->observed->{status} = 'playing';
    }
    elsif (($o{started} // 1)) {
        $ctl->requestTrack($D34_T1, 0, { successCb => sub { } });
    }
    return ($ctl, $daemon, $ws);
}

sub d34_forwarded { return map { [ @{ $_->{cmd} } ] } @Slim::Control::Request::EXECUTED; }
sub d34_reset { @Slim::Control::Request::EXECUTED = (); @Slim::Player::Client::EXECUTED = (); @IO::Socket::INET::KEEP_WRITES = (); }

# --- P1/P2: app pause and app play on the own title (Case E) -> LMS pause 1 / pause 0 ---
{
    d34_reset();
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = d34_session('02:d3:40:00:00:01');
    my $E = d34_case('d34-pause-seek.log', 'E');

    d34_feed($ctl, $E, to => '15:15:20.716');
    is(scalar(d34_forwarded()), 0, "D-34 P1: before the app pause nothing is forwarded to LMS");
    my $sent = scalar @{ $ws->sent };

    d34_feed($ctl, $E, from => '15:15:20.717', to => '15:15:20.717');
    is_deeply([ d34_forwarded() ], [ ['pause', 1] ], "D-34 P1: the app pause on the own title reaches LMS as exactly one pause 1");
    is($Slim::Control::Request::EXECUTED[0]{source}, $D34_SRC,
        "D-34 P1: the forwarded request carries Control's source marker");
    is(scalar @{ $ws->sent }, $sent, "D-34 P1: nothing is sent to the daemon for the app's own pause");
    is($ctl->wanted->{playing}, 0, "D-34 P1: wanted.playing follows the app's pause (no resume nachziehen)");

    @Slim::Control::Request::EXECUTED = ();
    local $Slim::Player::Source::PLAYMODE = 'pause';
    d34_feed($ctl, $E, from => '15:15:20.718', to => '15:15:27.017');
    is_deeply([ d34_forwarded() ], [ ['pause', 0] ], "D-34 P2: the app play after that pause reaches LMS as exactly one pause 0");
    is($Slim::Control::Request::EXECUTED[0]{source}, $D34_SRC,
        "D-34 P2: the forwarded unpause carries the source marker");
    is($ctl->wanted->{playing}, 1, "D-34 P2: wanted.playing follows the app's play");
    is(scalar @{ $ws->sent }, $sent, "D-34 P2: nothing is sent to the daemon for the app's own play");
}

# --- P4: connect mode keeps today's stop emit; nothing is forwarded to LMS ---
{
    d34_reset();
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = d34_session('02:d3:40:00:00:04', mode => 'connect');
    my $E = d34_case('d34-pause-seek.log', 'E');
    d34_feed($ctl, $E, from => '15:15:20.717', to => '15:15:20.717');
    is(scalar(d34_forwarded()), 0, "D-34 P4: mode connect forwards no LMS request for the app pause");
    ok((grep { ref($_) eq 'ARRAY' && $_->[0] eq 'spottyconnect' && $_->[1] eq 'stop' } @Slim::Player::Client::EXECUTED),
        "D-34 P4: mode connect keeps today's spottyconnect stop emit");
}

# --- P5: the context end under Autoplay OFF (Case A_off) is never read as an app pause ---
{
    d34_reset();
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = d34_session('02:d3:40:00:00:05');
    my $A = d34_case('d34-end-off.log', 'A_off');
    d34_feed($ctl, $A, at => [ [ '15:11:37.100', sub { $ctl->_dispatch('seek', position_ms => 175000, armed => 0) } ] ]);
    is(scalar(d34_forwarded()), 0, "D-34 P5: the context-end pause under Autoplay OFF reaches LMS as no request");
    is($ctl->observed->{contextEndPlanted}, $D34_T1,
        "D-34 P5: the context-end path itself is unchanged (the boundary is planted on the own title)");
    is($ctl->wanted->{playing}, 1, "D-34 P5: wanted.playing stays 1 (LMS moves on by itself)");
}

# --- P5b (79-44 Fable review, D-33 WR-01): the same context end with the title's duration UNKNOWN is never an app pause ---
# _nearTitleEnd answers 0 without a known duration, so the P5 shape (anchor reset to <= 1 s, not moving) carried no evidence
# at all and was forwarded as LMS pause 1 on a title that is over (wanted.playing 0: the list wedges).
{
    d34_reset();
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = d34_session('02:d3:40:00:00:51');
    delete $ctl->observed->{meta}{$D34_T1}{duration};
    my $A = d34_case('d34-end-off.log', 'A_off');
    d34_feed($ctl, $A, at => [ [ '15:11:37.100', sub { $ctl->_dispatch('seek', position_ms => 175000, armed => 0) } ] ]);
    is(scalar(d34_forwarded()), 0, "79-44 WR-01: the context end with an unknown duration reaches LMS as no request");
    is($ctl->wanted->{playing}, 1, "79-44 WR-01: wanted.playing stays 1 (LMS moves on by itself)");
}

# --- P5c (79-44 Fable review, D-33 WR-01): an app pause well into the title still forwards when the duration is unknown ---
# (the guard only reads the reset shape; a real pause is not the reset shape)
{
    d34_reset();
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = d34_session('02:d3:40:00:00:52');
    delete $ctl->observed->{meta}{$D34_T1}{duration};
    my $E = d34_case('d34-pause-seek.log', 'E');
    d34_feed($ctl, $E, to => '15:15:20.717');
    is_deeply([ d34_forwarded() ], [ ['pause', 1] ], "79-44 WR-01: an app pause mid-title forwards as pause 1 although the duration is unknown");
}

# --- P5d (79-44 Fable review, D-33 WR-01): a boundary the carrier already planted is never read as an app pause either ---
# After the A_off context end (boundary planted) the pre-reset evidence is gone; a pause candidate in the reset shape on the
# same title, duration known but _nearTitleEnd now 0, must not turn into an LMS pause just because the carrier's evidence aged out.
{
    d34_reset();
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = d34_session('02:d3:40:00:00:53');
    my $A = d34_case('d34-end-off.log', 'A_off');
    d34_feed($ctl, $A, at => [ [ '15:11:37.100', sub { $ctl->_dispatch('seek', position_ms => 175000, armed => 0) } ] ]);
    is($ctl->observed->{contextEndPlanted}, $D34_T1, "79-44 WR-01 (precondition): the carrier planted the boundary on the own title");
    d34_reset();
    delete $ctl->observed->{preResetAnchor};
    $ctl->observed->{pauseCandidate} = { uri => $D34_T1, hr => Time::HiRes::time() };
    $ctl->observed->{anchor} = { position_ms => 0, timestamp_ms => 1, speed => 0, seen_at => time(), seen_hr => Time::HiRes::time(), uri => $D34_T1 };
    is($ctl->_nearTitleEnd($D34_T1), 0, "79-44 WR-01 (precondition): the near-end evidence is gone, the duration is still known");
    $ctl->_settleBrowsePause({ type => 'position_sync', position => { position_ms => 0 } });
    is(scalar(d34_forwarded()), 0, "79-44 WR-01: a planted boundary keeps the reset shape from being forwarded as an app pause");
}

# --- P6: the echo of an LMS pause (Case H) is never forwarded back ---
{
    d34_reset();
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = d34_session('02:d3:40:00:00:06');
    my $H = d34_case('d34-lms-pause-echo.log', 'H');
    d34_feed($ctl, $H, at => [
        [ '15:23:43.700', sub { $Slim::Player::Source::PLAYMODE = 'pause'; $ctl->requestPause(0); } ],
        [ '15:23:49.900', sub { $Slim::Player::Source::PLAYMODE = 'play';  $ctl->requestResume; } ],
    ]);
    is(scalar(d34_forwarded()), 0, "D-34 P6: the echoes of an LMS pause and an LMS unpause (wanted.playing already moved) forward nothing");
    is($ctl->wanted->{playing}, 1, "D-34 P6: wanted.playing is 1 again after the LMS unpause");

    # An own pause that does NOT move wanted.playing (the autoplay guard's and
    # the split-brain exit's `_dispatch('pause')` shape): only the own-command
    # exclusion keeps its echo from coming back as an "app pause".
    d34_reset();
    $Slim::Player::Source::PLAYMODE = 'play';
    my ($c2, $d2, $w2) = d34_session('02:d3:40:00:00:07');
    d34_feed($c2, $H, to => '15:23:43.746', at => [ [ '15:23:43.700', sub { $c2->_dispatch('pause') } ] ]);
    is($c2->wanted->{playing}, 1, "D-34 P6: (precondition) an own _dispatch('pause') leaves wanted.playing at 1");
    is(scalar(d34_forwarded()), 0, "D-34 P6: the echo of Control's own daemon pause is never forwarded to LMS");
}

# --- P6b: the internal stop LMS issues during `playlist index +1` (Case J) ---
{
    d34_reset();
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = d34_session('02:d3:40:00:00:08');
    my $J = d34_case('d34-lms-skip-echo.log', 'J');
    # LMS: playlist index +1 -> its internal stop (historic: LMS already plays again) -> getNextTrack(T2)
    d34_feed($ctl, $J, at => [ [ '15:34:34.820', sub {
        $ctl->requestPause(1);
        $ctl->requestTrack($D34_T2, 0, { successCb => sub { } });
    } ] ]);
    is(scalar(d34_forwarded()), 0, "D-34 P6b: LMS's own jump (internal stop, getNextTrack, echo) forwards no request back");
    is($ctl->wanted->{playing}, 1, "D-34 P6b: wanted.playing stays 1 through LMS's own jump");
}


# ============================================================
# D-34 (79-48) Task 2: app seek and next/previous during Browse, the shim's
# browse flag (/browse-keep), and the exits that clear it.
# ============================================================

# d34_settled($mac, %o) -- a Browse session already running when the recorded
# window opens: mode browse on T1, the daemon on T1 and playing, Control's own
# `play` sent just now (so the opening frames of the window are its echo and
# the fixture's own clock ages that stamp out before the app acts).
sub d34_settled {
    my ($mac, %o) = @_;
    my ($ctl, $daemon, $ws) = fresh_control(
        mac      => $mac,
        mode     => 'browse',
        wanted   => { uri => $D34_T1, position_ms => 0, playing => 1 },
        observed => {
            wsConnected => 1, is_active => 1, track => $D34_T1, status => 'playing',
            meta        => { $D34_T1 => { duration => 203 }, $D34_T2 => { duration => 180 } },
            ownSend     => { play => Time::HiRes::time() },
            %{ $o{observed} || {} },
        },
    );
    delete $D34_LAST{ Scalar::Util::refaddr($ctl) };
    return ($ctl, $daemon, $ws);
}

sub d34_keep_lines { return map { (split /\r\n/, $_)[0] } @IO::Socket::INET::KEEP_WRITES; }
sub d34_seeks { return grep { ref($_) eq 'ARRAY' && $_->[0] eq 'spottyconnect' && $_->[1] eq 'seek' } @Slim::Player::Client::EXECUTED; }

# --- K1: entering browse posts the shim's keep once; Control's own title changes post nothing ---
{
    d34_reset();
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = d34_session('02:d3:40:00:01:01', started => 0);
    is(scalar(d34_keep_lines()), 0, "D-34 K1: (precondition) no keep post before browse starts");
    $ctl->requestTrack($D34_T1, 0, { successCb => sub { } });
    is_deeply([ d34_keep_lines() ], [ 'POST /browse-keep?on=1 HTTP/1.0' ],
        "D-34 K1: entering browse posts /browse-keep?on=1 exactly once");
    my $E = d34_case('d34-pause-seek.log', 'E');
    d34_feed($ctl, $E, to => '15:15:03.300');
    $ctl->requestTrack($D34_T2, 0, { successCb => sub { } });
    $ctl->onEvent({ type => 'track_changed', item => { uri => $D34_T2 } });
    is(scalar(d34_keep_lines()), 1, "D-34 K1: Control's own title changes (requestTrack T2, its echo) post nothing more");
    ok(!grep({ $_ =~ /on=0/ } @IO::Socket::INET::KEEP_WRITES), "D-34 K1: no clear while browse runs");
}

# --- K1b: every exit from browse posts on=0 exactly once (the flag is never reset by the shim itself) ---
my $k1b_n = 0;
for my $exit (
    [ 'stop/clear (leaveBrowse)',          sub { $_[0]->leaveBrowse; $_[0]->leaveBrowse; } ],
    [ 'stop of a foreign title (requestPause)', sub { foreign_track($_[0]->mac); $_[0]->requestPause(1); } ],
    [ 'player leaves Soloist (shutdown)',  sub { $_[0]->shutdown; } ],
    [ 'daemon session end (device_changed is_active false)', sub { $_[0]->onEvent({ type => 'device_changed', is_active => JSON::PP::false() }); } ],
) {
    d34_reset();
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = d34_session(sprintf('02:d3:40:00:01:%02x', 16 + $k1b_n++));
    own_track($ctl->mac);
    is(scalar(d34_keep_lines()), 1, "D-34 K1b: ($exit->[0]) browse is on");
    $exit->[1]->($ctl);
    is_deeply([ d34_keep_lines() ], [ 'POST /browse-keep?on=1 HTTP/1.0', 'POST /browse-keep?on=0 HTTP/1.0' ],
        "D-34 K1b: $exit->[0] posts on=0 exactly once");
}

# --- K2: an app seek (Case F) reaches LMS's clock as a marked startOffset seek, no stream re-open ---
{
    d34_reset();
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = d34_settled('02:d3:40:00:02:01');
    my $F = d34_case('d34-pause-seek.log', 'F');
    my $sent = scalar @{ $ws->sent };
    # the frames of the app seek itself; the title change at 15:23:07.510 is today's
    # flush-disconnect consequence, which the shim's keep (79-47) removes
    d34_feed($ctl, $F, to => '15:23:07.200');
    is_deeply([ d34_seeks() ], [ [ 'spottyconnect', 'seek', '102.463', '', 'browse' ] ],
        "D-34 K2: the app seek on the own title is emitted once, marked 'browse', at the app's target");
    is(scalar(d34_forwarded()), 0, "D-34 K2: no time command and no playlist command reaches LMS (the stream is not re-opened)");
    is(scalar @{ $ws->sent }, $sent, "D-34 K2: nothing is sent to the daemon");
}

# --- K3: app next / previous (Cases C and D, Autoplay ON and OFF) become LMS playlist index +1 / -1 ---
for my $case (
    [ 'next',     'd34-next-prev-on.log',  'C_on',  'ON',  '15:09:53.300', 1, [ [ 'playlist', 'index', '+1' ] ] ],
    [ 'next',     'd34-next-prev-off.log', 'C_off', 'OFF', '15:12:53.200', 0, [ [ 'playlist', 'index', '+1' ] ] ],
    [ 'previous', 'd34-next-prev-on.log',  'D_on',  'ON',  '15:10:40.300', 1, [ [ 'playlist', 'index', '-1' ] ] ],
    [ 'previous', 'd34-next-prev-off.log', 'D_off', 'OFF', '15:13:40.200', 1, [ [ 'playlist', 'index', '-1' ] ] ],
) {
    my ($what, $file, $c, $state, $to, $withEcho, $want) = @$case;
    d34_reset();
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = $withEcho ? d34_session("02:d3:40:00:03:$c") : d34_settled("02:d3:40:00:03:$c");
    $ctl->observed->{queuedByUs} = { $D34_T2 => 1 };
    my $frames = d34_case($file, $c);
    my $sent = scalar @{ $ws->sent };
    d34_feed($ctl, $frames, to => $to);
    is_deeply([ d34_forwarded() ], $want, "D-34 K3: app $what with Autoplay $state ($c) becomes LMS $want->[0][1] $want->[0][2]");
    is($Slim::Control::Request::EXECUTED[0]{source}, $D34_SRC, "D-34 K3: ($c) the request carries the source marker");
    is($ctl->mode, 'browse', "D-34 K3: ($c) no takeover, the session stays Browse");
    is(scalar(grep { ref($_) eq 'ARRAY' && $_->[0] eq 'spottyconnect' && $_->[1] ne 'volume' } @Slim::Player::Client::EXECUTED), 0, "D-34 K3: ($c) nothing emitted to Connect (the browse volume echo aside)");
}

# --- K3b: a natural advance onto the prefetched title (the daemon at its end) is LMS's own and is not forwarded ---
{
    d34_reset();
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = d34_settled('02:d3:40:00:03:b1');
    $ctl->observed->{queuedByUs} = { $D34_T2 => 1 };
    my $C = d34_case('d34-next-prev-off.log', 'C_off');
    d34_feed($ctl, $C, to => '15:12:53.200', at => [ [ '15:12:52.600', sub { d34_age($ctl, 180) } ] ]);
    is(scalar(d34_forwarded()), 0, "D-34 K3b: a prefetched title reached at the end of the title is no app next (LMS advances by itself)");
}

# --- K4: a frozen-position repeat still emits nothing in browse; the connect seek is unchanged ---
{
    d34_reset();
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = d34_settled('02:d3:40:00:04:01');
    my $F = d34_case('d34-pause-seek.log', 'F');
    d34_feed($ctl, $F, to => '15:22:46.200');
    # the daemon reports 41 s mid-title, then goes quiet; 30 s later a buffering
    # frame repeats exactly that report while the clock moved on (the 84-02 shape)
    $ctl->onEvent({ type => 'position_sync', position => { position_ms => 41000, timestamp_ms => 1, speed => 1 } });
    my $anchorPos = $ctl->observed->{anchor}{position_ms};
    is($anchorPos, 41000, "D-34 K4: (precondition) the anchor holds the 41 s report");
    d34_age($ctl, 30);
    $ctl->observed->{status} = 'buffering';
    $ctl->onEvent({ type => 'playback_state', status => 'buffering', item => { uri => $D34_T1 },
        position => { position_ms => $anchorPos, speed => 0, timestamp_ms => 2 } });
    is(scalar(d34_seeks()), 0, "D-34 K4: a position report equal to the prior anchor while time passed (frozen daemon position) emits no seek in browse");
    is(scalar(d34_forwarded()), 0, "D-34 K4: and forwards nothing to LMS");

    d34_reset();
    my ($c2, $d2, $w2) = d34_session('02:d3:40:00:04:02', mode => 'connect');
    $c2->onEvent({ type => 'position_sync', position => { position_ms => 1000, timestamp_ms => 1, speed => 1 } });
    d34_age($c2, 1);
    $c2->onEvent({ type => 'position_sync', position => { position_ms => 102463, timestamp_ms => 2, speed => 1 } });
    is_deeply([ d34_seeks() ], [ [ 'spottyconnect', 'seek', '102.463', '' ] ],
        "D-34 K4: a connect seek is emitted as before (no browse marker)");
}

# --- K5: the echo frames of an LMS-side seek (Case I) trigger nothing ---
{
    d34_reset();
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = d34_settled('02:d3:40:00:05:01');
    my $I = d34_case('d34-lms-seek-echo.log', 'I');
    d34_feed($ctl, $I, at => [ [ '15:24:57.250', sub { $ctl->_dispatch('seek', position_ms => 102000, armed => 0); } ] ]);
    is(scalar(d34_seeks()), 0, "D-34 K5: the echo of an LMS seek (Control's own seek, 137 ms before the frames) emits no seek");
    is(scalar(d34_forwarded()), 0, "D-34 K5: and forwards no LMS request");
}


# ============================================================
# D-34 (79-48) Task 3: takeover into Connect only when the app replaces the
# queue (79-D34-RULE.md: a context_changed to a foreign context, then a foreign
# track within the window, with no own command pending; an app-queued track when
# it STARTS). An autoplay continuation and a natural end are not takeovers.
# ============================================================
# P3 pin: Connect.pm cannot load Control or spell a Soloist package (the amputation leg's
# refcheck), so it holds its own copy of the source marker; the two literals must stay equal.
{
    open(my $cfh, '<', "$project_dir/Plugins/SpotOn/Connect.pm") or die "Connect.pm unreadable";
    my $src = do { local $/; <$cfh> };
    close($cfh);
    my ($onPause) = $src =~ /(sub _onPause \{.*?\nsub )/s;
    my ($lit) = ($onPause // '') =~ /\$request->source eq '([^']+)'/;
    is($lit, $D34_SRC, "D-34 P3: Connect.pm's copy of the source marker equals Control's BROWSE_FORWARD_SOURCE");
    unlike($D34_SRC, qr/Soloist/, "D-34 P3: the marker spells no Soloist package (core code may carry it)");
}

# d34_wrap_enter(\@calls) -- records every call of the shared transfer-in sub
# ([ why, %opts ]) and runs the real one. Returns a guard object; scope = test.
sub d34_wrap_enter {
    my ($calls) = @_;
    no warnings 'redefine';
    my $orig = \&Plugins::SpotOn::Soloist::Control::_enterConnectSession;
    *Plugins::SpotOn::Soloist::Control::_enterConnectSession = sub {
        my ($self, $why, %o) = @_;
        push @$calls, [ $why, %o ];
        return $self->$orig($why, %o);
    };
    return bless { orig => $orig }, 'D34::Unwrap';
}
sub D34::Unwrap::DESTROY {
    no warnings 'redefine';
    *Plugins::SpotOn::Soloist::Control::_enterConnectSession = $_[0]{orig};
}
sub d34_starts { return grep { ref($_) eq 'ARRAY' && $_->[0] eq 'spottyconnect' && $_->[1] eq 'start' } @Slim::Player::Client::EXECUTED; }
sub d34_daemon_pauses { my $ws = shift; return grep { $_->[0] eq 'pause' } @{ $ws->sent }; }

# --- T1 / T2 / T6: the app starts another track (Case B) or playlist (Case G) ---
for my $t (
    [ q(D-34 T1:), q(T1), q(d34-takeover-track.log),    q(B), q(15:14:32.240), q(0ymW7RlpQ12wFvr3tP8Fqb), q(track) ],
    [ q(D-34 T2:), q(T2), q(d34-takeover-playlist.log), q(G), q(15:30:10.348), q(6nFsSjK6HtenFUCnDi9rRb), q(playlist) ],
) {
    my ($label, $id, $file, $case, $to, $newId, $kind) = @$t;
    d34_reset();
    @Plugins::SpotOn::Connect::CLAIMS = ();
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = d34_session("02:d3:40:00:06:$id");
    $ctl->observed->{queuedByUs} = { $D34_T2 => 1 };
    my @enter;
    my $guard = d34_wrap_enter(\@enter);
    my $modeAtClear;
    local $IO::Socket::INET::ON_KEEP_WRITE = sub { $modeAtClear = $ctl->mode if $_[0] =~ /on=0/; };

    d34_feed($ctl, d34_case($file, $case), to => $to);

    is($ctl->mode, 'connect', "$label the app started a $kind -> Control leaves Browse for connect");
    is(scalar(@enter), 1, "$label exactly one takeover went through the shared transfer-in sub");
    is($enter[0][0], 'takeover', "$label ... as its third caller (why 'takeover')");
    is_deeply([ d34_starts() ], [ [ 'spottyconnect', 'start', $newId, '' ] ],
        "$label exactly one connect start for the app's track (Connect replaces the LMS playlist with it)");
    is(scalar(grep { $_->[0] eq 'bind' && ($_->[2] // '') eq 'takeover' } @Plugins::SpotOn::Connect::CLAIMS), 1,
        "$label the Connect claim is bound from the takeover");
    is(scalar(d34_daemon_pauses($ws)), 0, "$label the autoplay guard does not pause the app's track");
    ok(!defined $ctl->observed->{autoplayPaused}, "$label no autoplay marker on the app's track");
    is($ctl->wanted->{uri}, "spotify:track:$newId", "$label wanted follows the app's track");
    is(scalar(d34_forwarded()), 0, "$label nothing is forwarded to LMS (the list is replaced by Connect's start)");

    if ($id eq 'T1') {
        is_deeply([ d34_keep_lines() ], [ 'POST /browse-keep?on=1 HTTP/1.0', 'POST /browse-keep?on=0 HTTP/1.0' ],
            "D-34 T6: the takeover posts /browse-keep?on=0 (once)");
        is($modeAtClear, 'browse', "D-34 T6: ... while Control is still in browse, before mode connect");
    }
}

# --- T3: an autoplay continuation (Case A_on) is paused by the guard as today, not taken over ---
{
    d34_reset();
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = d34_session('02:d3:40:00:06:a1');
    my @enter;
    my $guard = d34_wrap_enter(\@enter);
    d34_feed($ctl, d34_case('d34-end-on.log', 'A_on'),
        at => [ [ '15:08:24.100', sub { $ctl->_dispatch('seek', position_ms => 175000, armed => 0) } ] ]);
    is($ctl->mode, 'browse', "D-34 T3: the autoplay continuation at a title end does not leave Browse");
    is(scalar(@enter), 0, "D-34 T3: no takeover");
    is($ctl->observed->{autoplayPaused}, 'spotify:track:0yNttAVwMr39qyODHNIkrY', "D-34 T3: the guard pauses the foreign title as today");
    is(scalar(d34_daemon_pauses($ws)), 1, "D-34 T3: exactly one daemon pause (the guard's)");
    is(scalar(d34_starts()), 0, "D-34 T3: no connect start");
}

# --- T3b: the natural end under Autoplay OFF (Case A_off) stays the context-end path ---
{
    d34_reset();
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = d34_session('02:d3:40:00:06:a2');
    my @enter;
    my $guard = d34_wrap_enter(\@enter);
    d34_feed($ctl, d34_case('d34-end-off.log', 'A_off'),
        at => [ [ '15:11:37.100', sub { $ctl->_dispatch('seek', position_ms => 175000, armed => 0) } ] ]);
    is($ctl->mode, 'browse', "D-34 T3b: the natural end under Autoplay OFF does not leave Browse");
    is(scalar(@enter), 0, "D-34 T3b: no takeover");
    is($ctl->observed->{contextEndPlanted}, $D34_T1, "D-34 T3b: the context-end path plants its boundary as today");
    is(scalar(d34_starts()), 0, "D-34 T3b: no connect start");
}

# --- T4: an app-queued track takes over when it STARTS, not when it is queued ---
{
    d34_reset();
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = d34_session('02:d3:40:00:06:b1');
    $ctl->observed->{queuedByUs} = { $D34_T2 => 1 };
    my $Q = 'spotify:track:4cOdK2wGLETKBW3PvgPWqT';
    my @enter;
    my $guard = d34_wrap_enter(\@enter);
    d34_feed($ctl, d34_case('d34-pause-seek.log', 'E'), to => '15:15:03.300');
    # the app's "add to queue": a queue_changed frame (shape of the real ones, a source 'queue' entry)
    $ctl->onEvent({ type => 'queue_changed', previous => [],
        upcoming => [ { uid => 'app-q-1', source => 'queue', item => { uri => $Q, entity_type => 'track' } } ] });
    is($ctl->mode, 'browse', "D-34 T4: queueing a track in the app does not take over");
    is(scalar(@enter), 0, "D-34 T4: no transfer-in at queue time");
    d34_age($ctl, 200);
    $ctl->onEvent({ type => 'track_changed', item => { uri => $Q, entity_type => 'track' } });
    is($ctl->mode, 'connect', "D-34 T4: the queued track taking over when it starts");
    is_deeply([ d34_starts() ], [ [ 'spottyconnect', 'start', '4cOdK2wGLETKBW3PvgPWqT', '' ] ], "D-34 T4: one connect start for it");
    is(scalar(@enter), 1, "D-34 T4: one takeover through the shared sub");
    is(scalar(d34_daemon_pauses($ws)), 0, "D-34 T4: and the guard does not pause it");

    # the autoplay shape: the same foreign track, queued from the baseline (stale own entries) or by the context
    d34_reset();
    my ($c2, $d2, $w2) = d34_session('02:d3:40:00:06:b2');
    $c2->observed->{queuedByUs} = { $D34_T2 => 1 };
    d34_feed($c2, d34_case('d34-pause-seek.log', 'E'), to => '15:15:03.300');
    $c2->onEvent({ type => 'queue_changed', previous => [],
        upcoming => [ { uid => 'ctx-1', source => 'context', item => { uri => $Q, entity_type => 'track' } } ] });
    d34_age($c2, 200);
    $c2->onEvent({ type => 'track_changed', item => { uri => $Q, entity_type => 'track' } });
    is($c2->mode, 'browse', "D-34 T4: a context entry (autoplay shape) is no app queue and is not taken over");
    is(scalar(d34_daemon_pauses($w2)), 1, "D-34 T4: the guard pauses it as today");
}

# --- T5: the two existing transfer-in callers behave as before (through the shared sub) ---
{
    d34_reset();
    @Plugins::SpotOn::Connect::CLAIMS = ();
    my @enter;
    my $guard = d34_wrap_enter(\@enter);

    my ($c1, $d1, $w1) = fresh_control(mac => '02:d3:40:00:07:01', observed => { wsConnected => 1, track => $D34_T1, status => 'playing', volume => 40,
        anchor => { position_ms => 47000, timestamp_ms => 1, speed => 1, seen_at => time(), seen_hr => Time::HiRes::time(), uri => $D34_T1 } });
    $c1->observed->{leftBrowseUri} = 'x';
    $c1->observed->{leftConnectForeign} = 1;
    $c1->observed->{autoplayPaused} = 'y';
    $c1->onEvent({ type => 'device_changed', is_active => JSON::PP::true() });
    is($c1->mode, 'connect', "D-34 T5: device_changed(is_active) transfer-in still enters connect");
    is_deeply([ @{ $enter[0] || [] }[0, 1, 2] ], [ 'transfer-in', 'fresh', 1 ], "D-34 T5: ... through the shared sub (why transfer-in, fresh)");
    is_deeply({ map { $_ => $c1->wanted->{$_} } qw(uri position_ms playing volume) },
        { uri => $D34_T1, position_ms => 47000, playing => 1, volume => 40 }, "D-34 T5: transfer-in wanted as before");
    ok(!defined $c1->observed->{leftBrowseUri} && !defined $c1->observed->{leftConnectForeign} && !defined $c1->observed->{autoplayPaused},
        "D-34 T5: transfer-in clears the stop-leave and autoplay markers as before");
    is(scalar(d34_starts()), 1, "D-34 T5: transfer-in emits its one start");

    d34_reset();
    @enter = ();
    my ($c2, $d2, $w2) = fresh_control(mac => '02:d3:40:00:07:02', observed => { wsConnected => 1, volume => 55 });
    $c2->observed->{leftBrowseUri} = 'x';
    $c2->onEvent({ type => 'playback_state', status => 'playing', is_active => JSON::PP::true(), item => { uri => $D34_T1 },
        position => { position_ms => 12000, timestamp_ms => 1, speed => 1 } });
    is($c2->mode, 'connect', "D-34 T5: playback_state reconnect adoption still enters connect");
    is($enter[0][0], 'reconnect-to-connect', "D-34 T5: ... through the shared sub (why reconnect-to-connect)");
    is($c2->wanted->{uri}, $D34_T1, "D-34 T5: reconnect wanted as before");
    ok(!defined $c2->observed->{leftBrowseUri}, "D-34 T5: reconnect clears the stop-leave marker as before");
}


# ============================================================
# D-34 R2 (79-50): the Connect app seek keeps LMS's stream. In Connect the app
# is the controller; an app seek makes the daemon flush on its own, the shim's
# unarmed flush would close LMS's stream 9 ms later (79-47 R2). The shim now
# holds that decision open for a bounded window (POST /seek-keep keeps the
# client, POST /boundary closes it) and Control sends the keep when the daemon's
# first frame after the flush is a `buffering` playback_state for the title it
# already observed, with no change pending and no command of its own in flight.
# Frames: the recorded R2_3 (t/fixtures/uat/r2-connect-seek.log, 79-47 Task 4)
# and the 79-46 cases C_off / C_on / D_off / E / F / I (the d34 fixtures).
# ============================================================
my $R2_T = $D34_T2;    # the title of R2_3 (the title that was already playing)

# r2_connect($mac, $uri) -- a Connect session already running on $uri: the
# `start` is behind us (startEmittedFor), so a title change takes the 84-17
# change path, and the observed track is the one the recorded window opens on.
sub r2_connect {
    my ($mac, $uri) = @_;
    my ($ctl, $daemon, $ws) = d34_session($mac, mode => 'connect');
    $ctl->wanted({ uri => $uri, position_ms => 0, playing => 1 });
    $ctl->observed->{track}           = $uri;
    $ctl->observed->{startEmittedFor} = $uri;
    return ($ctl, $daemon, $ws);
}
sub r2_reset {
    d34_reset();
    @IO::Socket::INET::SEEK_KEEP_WRITES = ();
    @IO::Socket::INET::SYSWRITE_CALLS   = ();
    @IO::Socket::INET::REQUESTS         = ();
    @IO::Socket::INET::CALLS            = ();
}
sub r2_keeps  { return scalar(@IO::Socket::INET::SEEK_KEEP_WRITES); }
sub r2_drains { return scalar(grep { m{^POST /boundary\?anchor=drain HTTP/1\.0} } @IO::Socket::INET::SYSWRITE_CALLS); }

# --- S1: the recorded connect seek (R2_3): one keep, at the buffering frame of the title already playing ---
{
    r2_reset();
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = r2_connect('02:d3:50:00:00:01', $R2_T);
    my $R = d34_case('r2-connect-seek.log', 'R2_3');
    d34_feed($ctl, $R, from => '18:00:36.453', to => '18:01:11.515');
    is(r2_keeps(), 0, "D-34 R2-S1: (precondition) no keep before the app seek's first frame (fixture lines 3-6)");
    d34_feed($ctl, $R, from => '18:01:11.516', to => '18:01:11.516');
    is(r2_keeps(), 1, "D-34 R2-S1: exactly one POST /seek-keep at the buffering frame of the unchanged title (R2_3 line 8)");
    like($IO::Socket::INET::SEEK_KEEP_WRITES[0] // '', qr{^POST /seek-keep HTTP/1\.0\r\n}, "D-34 R2-S1: the keep is the bare loopback POST");
    d34_feed($ctl, $R, from => '18:01:11.517', to => '18:01:11.617');
    is(r2_keeps(), 1, "D-34 R2-S1: the playing frames after it (lines 10-12) post no second keep");
    is(r2_drains(), 0, "D-34 R2-S1: a reposition plants no boundary");
}

# --- S2: an app skip (C_off, C_on) is a title change: no keep, the 84-17 drain boundary and a pending change as today ---
# C_off lines 2-17 in full. C_on from its playing frame (line 11, 15:09:33.463): lines 2-10 are the recorded run's own
# session START (the app's play, track_changed of T1, buffering at position 0 -- no skip), which a seed that already sits on
# T1 (observed.track and startEmittedFor, as the plan has it) reads as a restart on the unchanged title and keeps, correctly.
for my $c ([ 'C_off', 'd34-next-prev-off.log', 'D-34 R2-S2: C_off', undef ], [ 'C_on', 'd34-next-prev-on.log', 'D-34 R2-S2: C_on', '15:09:33.463' ]) {
    my ($case, $file, $label, $from) = @$c;
    r2_reset();
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = r2_connect('02:d3:50:00:00:02', $D34_T1);
    my $C = d34_case($file, $case);
    d34_feed($ctl, $C, (defined $from ? (from => $from) : ()));
    is(r2_keeps(), 0, "$label: no POST /seek-keep for the skip (track_changed first, then the new title's buffering frame)");
    is(r2_drains(), 1, "$label: exactly one POST /boundary?anchor=drain at the track_changed (84-17, as today)");
    is($ctl->observed->{track}, $D34_T2, "$label: the observed title moved on to the new uri");
}

# --- S3: an app restart on the unchanged title (D_off line 34): a keep, the title continues from 0 on the kept stream ---
{
    r2_reset();
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = r2_connect('02:d3:50:00:00:03', $D34_T1);
    my $D = d34_case('d34-next-prev-off.log', 'D_off');
    d34_feed($ctl, $D, from => '15:13:21.393', to => '15:13:39.870');
    is(r2_keeps(), 0, "D-34 R2-S3: (precondition) no keep before the restart (fixture lines 28-32)");
    d34_feed($ctl, $D, from => '15:13:39.871', to => '15:13:40.116');
    is(r2_keeps(), 1, "D-34 R2-S3: exactly one POST /seek-keep at the restart's buffering frame (line 34, same title, position 0)");
}

# --- S4: pause and play bring no buffering frame: no keep ---
{
    r2_reset();
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = r2_connect('02:d3:50:00:00:04', $D34_T1);
    d34_feed($ctl, d34_case('d34-pause-seek.log', 'E'), from => '15:15:02.426', to => '15:15:27.017');
    is(r2_keeps(), 0, "D-34 R2-S4: an app pause and play on the unchanged title post no keep (lines 12-22)");
}

# --- S5: Browse (79-48 form): the app seek of case F posts no keep, the browse keep is untouched ---
{
    r2_reset();
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws) = d34_session('02:d3:50:00:00:05');
    my $F = d34_case('d34-pause-seek.log', 'F');
    d34_feed($ctl, $F, to => '15:23:07.119');
    is(r2_keeps(), 0, "D-34 R2-S5: the browse app seek (case F lines 24-38) posts no POST /seek-keep");
    is_deeply([ d34_keep_lines() ], [ 'POST /browse-keep?on=1 HTTP/1.0' ],
        "D-34 R2-S5: the browse keep (/browse-keep?on=1) is posted once, as in 79-48");
}

# --- S6 (B1): the echo of Control's OWN LMS-side seek posts no keep; the arm still precedes the wire seek ---
my $R2_I_OWN_SEEK_AT = '15:24:57.241';
sub r2_own_seek_session {
    my ($mac, $seek_cb) = @_;
    my ($ctl, $daemon, $ws) = r2_connect($mac, $D34_T1);
    my $I = d34_case('d34-lms-seek-echo.log', 'I');
    d34_feed($ctl, $I, from => '15:24:53.084', to => '15:24:53.693');
    return ($ctl, $daemon, $ws, $I);
}
{
    r2_reset();
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws, $I) = r2_own_seek_session('02:d3:50:00:00:06');
    # LMS's seek at 15:24:57.241 of the recorded run: Control's own connect seek row, run at its recorded place
    d34_feed($ctl, $I, from => '15:24:57.378', to => '15:24:57.476',
        at => [ [ $R2_I_OWN_SEEK_AT, sub { $ctl->requestTrack($D34_T1, 102000, { source => 'onStream', seek => 1 }); } ] ]);
    my @sent = map { $_->[0] } @{ $ws->sent };
    ok(scalar(grep { $_ eq 'seek' } @sent) >= 1, "D-34 R2-S6: (precondition) Control sent its own seek through the connect seek row");
    is(scalar(grep { m{^POST /seek-arm} } @IO::Socket::INET::SYSWRITE_CALLS), 1, "D-34 R2-S6: the /seek-arm is posted (before the wire seek, as today)");
    is(r2_keeps(), 0, "D-34 R2-S6: the echo of Control's own seek (buffering at 102000) posts no keep");
}

# --- S6b (B1, keying): the exclusion is keyed on the own seek's TARGET: an app seek elsewhere right after still gets its keep ---
{
    r2_reset();
    local $Slim::Player::Source::PLAYMODE = 'play';
    my ($ctl, $daemon, $ws, $I) = r2_own_seek_session('02:d3:50:00:00:07');
    d34_feed($ctl, $I, from => '15:24:57.378', to => '15:24:57.476',
        at => [ [ $R2_I_OWN_SEEK_AT, sub { $ctl->requestTrack($D34_T1, 102000, { source => 'onStream', seek => 1 }); } ] ]);
    is(r2_keeps(), 0, "D-34 R2-S6b: (precondition) the own seek's echo posts no keep");
    my ($buf) = grep { $_->{msg}{type} eq 'playback_state' && $_->{msg}{status} eq 'buffering' && $_->{ts} eq '15:24:57.378' } @$I;
    my $copy = JSON::PP->new->utf8(1)->decode(JSON::PP->new->utf8(1)->canonical(1)->encode($buf->{msg}));
    $copy->{position}{position_ms} = 30000;
    d34_age($ctl, 0.2);
    $ctl->onEvent({ %$copy });
    is(r2_keeps(), 1, "D-34 R2-S6b: a buffering frame at 30000 ms within 1 s after the own seek (an app seek elsewhere) posts exactly one keep");
}


# ============================================================
# 79-51 D1 (runaway, .planning/debug/album-start-connect-runaway.md): the Connect
# `resume` waits for the frame that decides it. The `playback_changed playing`
# frame of an album start arrives BEFORE the context_changed and the item-less
# playback_state (same millisecond, E1/E2), so at that frame nothing tells a
# resume of the paused title from a new context. R1..R9 replay the REAL frames of
# t/fixtures/uat/runaway-album-start.log (cases RUNAWAY, PASS1, RESUME, TRANSFER,
# TRACKFIRST) through Control; where several frames share a millisecond the slice
# is cut by array index, never by ts. The shim's /boundary reply is delivered
# through IO::Socket::INET::READ_REPLY + Slim::Networking::Select::deliver, as in
# 84-17 (the stub is on @INC from the 84-17 block above).
# ============================================================
{
    my $F51 = 'runaway-album-start.log';
    my $R51_T1 = 'spotify:track:7GVUmCP00eSsqc4tzj1sDD';
    my $R51_A1 = 'spotify:track:37BTh5g05cxBIRYMbw8g2T';
    my $R51_Q1 = 'spotify:track:15taea6JZLAfG5OX0pzfG6';
    my $R51_T2 = 'spotify:track:2374M0fQpWi3dLnB54qaLX';
    my $R51_TF_OLD = 'spotify:track:1qRA5BS78u3gME0loMl9AA';
    my $R51_TF_NEW = 'spotify:track:6lx1n63qJmhzPpirxxksbI';
    my ($T1ID, $A1ID, $Q1ID, $T2ID, $TFNEWID) = map { (my $x = $_) =~ s/^spotify:track://; $x }
        ($R51_T1, $R51_A1, $R51_Q1, $R51_T2, $R51_TF_NEW);

    my $reply = sub {
        my ($via) = @_;
        my $body = "via=$via boundary=130643728 anchor=drain ring_fill=0 total_pushed=130643728 total_popped=130643728 drops=0 gen=-1\n";
        return "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: " . length($body)
            . "\r\nConnection: close\r\n\r\n$body";
    };
    my $deliver = sub {
        my ($via) = @_;
        $IO::Socket::INET::READ_REPLY = $reply->($via);
        return Slim::Networking::Select::deliver();
    };
    my $reset = sub {
        r2_reset();
        $IO::Socket::INET::READ_REPLY = undef;
        @Slim::Networking::Select::READS   = ();
        @Slim::Networking::Select::REMOVED = ();
        @Slim::Utils::Timers::TIMERS       = ();
        @Slim::Utils::Log::WARNINGS        = ();
    };
    # the wire as 'cmd|p2|p3[|p4]' strings
    my $wire = sub { return map { join('|', @{$_}[ 1 .. $#$_ ]) } @Slim::Player::Client::EXECUTED; };
    my $resumes = sub { return grep { $_->[1] eq 'resume' } @Slim::Player::Client::EXECUTED; };
    my $gstates = sub { my ($ws) = @_; return scalar(grep { $_->[0] eq 'get_state' } @{ $ws->sent }); };
    my $resume_timers = sub {
        my $cb = \&Plugins::SpotOn::Soloist::Control::_resumeDueFire;
        return scalar(grep { $_->[2] == $cb } @Slim::Utils::Timers::TIMERS);
    };
    my $idx = sub { my ($C, @i) = @_; return [ map { $C->[$_] } @i ]; };
    # the title uris of the frames given: a deep copy for a doctored frame
    my $clone = sub { return JSON::PP->new->utf8(1)->decode(JSON::PP->new->utf8(1)->canonical(1)->encode($_[0])); };

    # --- R1 (RUNAWAY): the failing run 094204 end to end, without its four SpotOn-caused pause triplets ---
    # Fixture lines 3-44 = indices 0..41. The triplets (E1: paused, playback_state paused, position_sync at 25.428,
    # 25.727, 25.928, 26.130 = lines 18-20, 26-28, 34-36, 42-44) are chain link d of the recording: SpotOn's stop forwarded as
    # a pause after each 0-byte stream; in the repaired world they do not occur. The replay keeps the app's own skips.
    my @r1_wire;
    {
        $reset->();
        local $Slim::Player::Source::PLAYMODE = 'play';
        my ($ctl, $daemon, $ws) = r2_connect('02:51:00:00:00:01', $R51_T1);
        $ctl->observed->{startEmittedFor} = $R51_T1;
        my $C = d34_case($F51, 'RUNAWAY');
        is(scalar(@$C), 42, "79-51 D1-R1: (precondition) the RUNAWAY case holds source lines 3-44");
        my %skip = map { $_ => 1 } (15 .. 17, 23 .. 25, 31 .. 33, 39 .. 41);
        my @frames = map { $C->[$_] } grep { !$skip{$_} } 0 .. $#$C;
        # frame 0 = the paused playback_state of T1 at 95802; indices 1..5 = the five frames of 09:42:24.913
        d34_feed($ctl, [ $frames[0] ]);
        my $before = scalar(@Slim::Player::Client::EXECUTED);
        d34_feed($ctl, $idx->(\@frames, 1 .. 5));
        my @delta = @Slim::Player::Client::EXECUTED[ $before .. $#Slim::Player::Client::EXECUTED ];
        is(scalar(@delta), 0, "79-51 D1-R1 (b): nothing is emitted for the five frames at 09:42:24.913 (the resume of T1 at the playing frame is gone)");
        is($gstates->($ws), 0, "79-51 D1-R1 (b): ... and no get_state is sent either");
        # the rest: the reply of the first change (A1) is delivered at 09:42:25.117 as via=none (no LMS client at the plant),
        # the other four 10 ms after their track_changed as via=departed
        my @at = (
            [ '09:42:25.117', sub { $deliver->('none') } ],
            [ '09:42:25.337', sub { $deliver->('departed') } ],
            [ '09:42:25.684', sub { $deliver->('departed') } ],
            [ '09:42:25.875', sub { $deliver->('departed') } ],
        );
        d34_feed($ctl, $idx->(\@frames, 6 .. $#frames), at => \@at);
        $deliver->('departed');    # the reply of the last title change (09:42:26.083), no frame follows it
        my @rs = $resumes->();
        ok(!(grep { $_->[2] eq $T1ID } @rs), "79-51 D1-R1 (a): no resume carries T1 (the paused old title)");
        is_deeply([ map { [ @$_[1 .. 3] ] } @rs ], [ [ 'resume', $A1ID, '' ] ],
            "79-51 D1-R1 (c): exactly one resume, A1 with an empty position");
        my @w = $wire->();
        my ($ci) = grep { $w[$_] eq "change|$A1ID|$T1ID|none" } 0 .. $#w;
        ok(defined $ci && ($w[ $ci + 1 ] // '') eq "resume|$A1ID|", "79-51 D1-R1 (c): ... directly after `change A1 T1 none`");
        is_deeply([ map { $_->[2] } grep { $_->[1] eq 'change' } @Slim::Player::Client::EXECUTED ],
            [ $A1ID, $Q1ID, '7D4EtbE7LfQiH8CWj7fQoz', '2MuwL6v9qAOUag4fM4m1PA', '2mLgGFWNJQAYHRgNLg7C23' ],
            "79-51 D1-R1 (d): the change ids in order: the album's first title, then the app's four skips");
        # (e) a snapshot taken AFTER GREEN (D1_REPLAY_WIRE), a regression pin and not a specification: (a)-(d) are the specification
        is_deeply(\@w, [
            'volume|60|',
            "change|$A1ID|$T1ID|none",
            "resume|$A1ID|",
            'seek|0.000||deferred',
            "change|$Q1ID|$A1ID|departed",
            "change|7D4EtbE7LfQiH8CWj7fQoz|$Q1ID|departed",
            "change|2MuwL6v9qAOUag4fM4m1PA|7D4EtbE7LfQiH8CWj7fQoz|departed",
            "change|2mLgGFWNJQAYHRgNLg7C23|2MuwL6v9qAOUag4fM4m1PA|departed",
        ], "79-51 D1-R1 (e): the whole wire equals the post-GREEN snapshot (D1_REPLAY_WIRE)");
        @r1_wire = @w;
        diag("79-51 R1 wire: " . join(';', @w)) if $ENV{R51_DIAG};
    }

    # --- R2 (PASS1): pass 1 092233, the same frame form at position 0, then its second plain resume (E10) ---
    {
        $reset->();
        local $Slim::Player::Source::PLAYMODE = 'play';
        my ($ctl, $daemon, $ws) = r2_connect('02:51:00:00:00:02', $R51_T1);
        $ctl->observed->{startEmittedFor} = $R51_T1;
        my $C = d34_case($F51, 'PASS1');
        is(scalar(@$C), 14, "79-51 D1-R2: (precondition) the PASS1 case holds source lines 3-16");
        # the reply (via=none) comes after the 09:22:54.418 frames and before the 09:22:54.788 frame
        d34_feed($ctl, $C, at => [ [ '09:22:54.500', sub { $deliver->('none') } ] ]);
        my @rs = $resumes->();
        ok(!(grep { $_->[2] eq $T1ID } @rs), "79-51 D1-R2: no resume carries T1");
        is_deeply([ map { [ @$_[1 .. 3] ] } @rs ], [ [ 'resume', $A1ID, '' ], [ 'resume', $A1ID, '0.000' ] ],
            "79-51 D1-R2: exactly two resumes, the new-context one (A1, empty position) and pass 1's plain resume (A1, 0.000)");
        my @w = $wire->();
        my ($ci) = grep { $w[$_] eq "change|$A1ID|$T1ID|none" } 0 .. $#w;
        ok(defined $ci && ($w[ $ci + 1 ] // '') eq "resume|$A1ID|", "79-51 D1-R2: the first resume follows `change A1 T1 none` directly");
    }

    # --- R3 (RESUME): a plain Connect resume keeps today's arguments, one frame later ---
    {
        $reset->();
        local $Slim::Player::Source::PLAYMODE = 'play';
        my ($ctl, $daemon, $ws) = r2_connect('02:51:00:00:00:03', $R51_Q1);
        my $C = d34_case($F51, 'RESUME');
        is(scalar(@$C), 4, "79-51 D1-R3: (precondition) the RESUME case holds source lines 3-6");
        d34_feed($ctl, $idx->($C, 0));    # paused at 11981 (its volume frame is the only thing it emits)
        my $before = scalar(@Slim::Player::Client::EXECUTED);
        d34_feed($ctl, $idx->($C, 1));    # playback_changed playing alone
        is(scalar(@Slim::Player::Client::EXECUTED), $before, "79-51 D1-R3: the playing frame alone emits nothing");
        is($gstates->($ws), 0, "79-51 D1-R3: ... and sends no get_state");
        d34_feed($ctl, $idx->($C, 2));    # the playback_state of the same millisecond decides it
        is_deeply([ @Slim::Player::Client::EXECUTED[ $before .. $#Slim::Player::Client::EXECUTED ] ], [ [ 'spottyconnect', 'resume', $Q1ID, '11.981' ] ],
            "79-51 D1-R3: the deciding playback_state releases exactly today's resume (Q1, 11.981)");
        is($gstates->($ws), 1, "79-51 D1-R3: ... with one get_state on the daemon socket");
    }

    # --- R4 (lone playing frame): the decide timer releases today's resume ---
    {
        $reset->();
        my ($ctl, $daemon, $ws) = fresh_control(mac => '02:51:00:00:00:04', mode => 'connect',
            observed => { is_active => 1, wsConnected => 1, track => 'spotify:track:tid1', status => 'paused', anchor => { position_ms => 42500 } });
        $ctl->onEvent({ type => 'playback_changed', status => 'playing' });
        is(scalar(@Slim::Player::Client::EXECUTED), 0, "79-51 D1-R4: a lone playing frame emits nothing at once");
        is($resume_timers->(), 1, "79-51 D1-R4: exactly one decide timer is armed");
        Slim::Utils::Timers::fire_due(Time::HiRes::time() + 0.25);
        is_deeply([ @Slim::Player::Client::EXECUTED ], [ [ 'spottyconnect', 'resume', 'tid1', '42.500' ] ],
            "79-51 D1-R4: the timer (200 ms) releases exactly one resume tid1 42.500");
        is($gstates->($ws), 1, "79-51 D1-R4: ... and one get_state");
        is($resume_timers->(), 0, "79-51 D1-R4: no decide timer is left");
    }

    # --- R4b (79-44 Fable review, D-33 WR-02): playing, an item-less playback_state, then only position frames ---
    # No context_changed and no title frame ever follows. HEAD: noItem blocks the timer AND the position release, the record
    # lives until a frame arrives more than 10 s later and dies as INFO 'stale': the app's resume is lost without a trace while
    # the daemon plays. The timer decides this shape like a lone playing frame (the item-less snapshot without a
    # context_changed is the same title in every recorded case), counted from the item-less frame so a title frame that
    # follows it by 40-76 ms (R8, E10) still gets its full window.
    {
        $reset->();
        my ($ctl, $daemon, $ws) = fresh_control(mac => '02:51:00:00:00:44', mode => 'connect',
            observed => { is_active => 1, wsConnected => 1, track => 'spotify:track:tid1', status => 'paused', anchor => { position_ms => 42500 } });
        $ctl->onEvent({ type => 'playback_changed', status => 'playing' });
        my ($t0) = map { $_->[1] } grep { $_->[2] == \&Plugins::SpotOn::Soloist::Control::_resumeDueFire } @Slim::Utils::Timers::TIMERS;
        Time::HiRes::sleep(0.06);
        $ctl->onEvent({ type => 'playback_state', status => 'playing', position => { position_ms => 42500, timestamp_ms => 2, speed => 1 } });
        $ctl->onEvent({ type => 'position_sync', position => { position_ms => 42600, timestamp_ms => 3, speed => 1 } });
        $ctl->onEvent({ type => 'position_sync', position => { position_ms => 42700, timestamp_ms => 4, speed => 1 } });
        is(scalar($resumes->()), 0, "79-44 WR-02: (precondition) the item-less state and the position frames release nothing by themselves");
        my ($t1) = map { $_->[1] } grep { $_->[2] == \&Plugins::SpotOn::Soloist::Control::_resumeDueFire } @Slim::Utils::Timers::TIMERS;
        ok(defined $t1 && defined $t0 && $t1 - $t0 >= 0.05,
            "79-44 WR-02: the item-less frame re-arms the decide timer (it counts from that frame, not from the playing frame)");
        Slim::Utils::Timers::fire_due(Time::HiRes::time() + 0.25);
        is_deeply([ map { [ @$_[1 .. 3] ] } $resumes->() ], [ [ 'resume', 'tid1', '42.500' ] ],
            "79-44 WR-02: the decide timer releases the held resume of the item-less-only shape, today's arguments, exactly once");
        is($gstates->($ws), 1, "79-44 WR-02: ... with one get_state");
        ok(!defined $ctl->observed->{resumeDue}, "79-44 WR-02: no held record is left");
    }

    # --- R4c (79-44 Fable review, D-33 WR-02): a held resume that nothing released is dropped LOUDLY, not at INFO ---
    {
        $reset->();
        my ($ctl, $daemon, $ws) = fresh_control(mac => '02:51:00:00:00:45', mode => 'connect',
            observed => { is_active => 1, wsConnected => 1, track => 'spotify:track:tid1', status => 'paused', anchor => { position_ms => 42500 } });
        $ctl->onEvent({ type => 'playback_changed', status => 'playing' });
        Slim::Utils::Timers::killTimers($ctl, \&Plugins::SpotOn::Soloist::Control::_resumeDueFire);
        $ctl->observed->{resumeDue}{at} -= 11;
        @Slim::Utils::Log::WARNINGS = ();
        $ctl->onEvent({ type => 'position_sync', position => { position_ms => 53000, timestamp_ms => 9, speed => 1 } });
        is(scalar($resumes->()), 0, "79-44 WR-02: a record older than RESUME_DUE_MAX_S emits no resume");
        ok((grep { /held resume dropped \(stale\)/ } @Slim::Utils::Log::WARNINGS),
            "79-44 WR-02: ... and the drop is logged as a warning that names the cause (stale)");
    }

    # --- R5 (position frame): the 84-17 run-3 pair, today's arguments, released before anything the position frame emits ---
    {
        $reset->();
        my ($ctl, $daemon, $ws) = fresh_control(mac => '02:51:00:00:00:05', mode => 'connect',
            observed => { is_active => 1, wsConnected => 1, meta => {}, track => 'spotify:track:tid5', status => 'playing',
                          startEmittedFor => 'spotify:track:tid5',
                          anchor => { position_ms => 100000, timestamp_ms => 1, speed => 1, seen_at => time(), seen_hr => Time::HiRes::time() } });
        $ctl->onEvent({ type => 'position_sync', position => { position_ms => 242603, timestamp_ms => 3, speed => 0 } });
        $ctl->onEvent({ type => 'playback_changed', status => 'playing' });
        $ctl->onEvent({ type => 'position_sync', position => { position_ms => 242605, timestamp_ms => 4, speed => 1 } });
        my @rs = $resumes->();
        is_deeply([ map { [ @$_[1 .. 3] ] } @rs ], [ [ 'resume', 'tid5', '242.603' ] ],
            "79-51 D1-R5: the resume carries the arguments the playing frame computed (tid5, 242.603), exactly once");
        my @w = $wire->();
        my ($ri) = grep { $w[$_] =~ /^resume\|/ } 0 .. $#w;
        my ($si) = grep { $w[$_] =~ /^seek\|/ && $_ != 0 } 0 .. $#w;
        ok(defined $ri && (!defined $si || $ri < $si || $si == 0), "79-51 D1-R5: the resume is not preceded by anything the second position_sync emits");
    }

    # --- R6 (paused again): a pause before the deciding frame drops the held resume ---
    {
        $reset->();
        local $Slim::Player::Source::PLAYMODE = 'play';
        my ($ctl, $daemon, $ws) = r2_connect('02:51:00:00:00:06', $R51_Q1);
        my $C = d34_case($F51, 'RESUME');
        d34_feed($ctl, $idx->($C, 0, 1));
        $ctl->onEvent({ type => 'playback_changed', status => 'paused' });
        is(scalar($resumes->()), 0, "79-51 D1-R6: playing then paused again emits no resume");
        is(scalar(grep { $_->[1] eq 'stop' } @Slim::Player::Client::EXECUTED), 1, "79-51 D1-R6: ... exactly one stop (the pause itself, as today)");
        is($resume_timers->(), 0, "79-51 D1-R6: no decide timer is left");
        is($gstates->($ws), 0, "79-51 D1-R6: no get_state either");
    }

    # --- R7 (the title arrives in a playback_state): the mirror's change first, then the resume for THAT title ---
    {
        $reset->();
        local $Slim::Player::Source::PLAYMODE = 'play';
        my ($ctl, $daemon, $ws) = r2_connect('02:51:00:00:00:07', $R51_T1);
        $ctl->observed->{startEmittedFor} = $R51_T1;
        my $C = d34_case($F51, 'RUNAWAY');
        d34_feed($ctl, $idx->($C, 0));
        # the item-less playback_state (line 7 = index 4) is doctored INSIDE this test, on its own copy, to name A1
        my $doctored = $clone->($C->[4]);
        $doctored->{msg}{item} = { uri => $R51_A1, entity_type => 'track' };
        d34_feed($ctl, [ $C->[1], $C->[2], $C->[3], $doctored, $C->[5] ]);
        my @w = grep { /^(?:change|resume)\|/ } $wire->();
        is_deeply(\@w, [ "change|$A1ID|$T1ID", "resume|$A1ID|" ],
            "79-51 D1-R7: the playback_state mirror's `change A1 T1` first, then `resume A1` with an empty position");
    }

    # --- R8 (TRANSFER): the transfer-in without a context_changed keeps today's wire; the resume goes out at the same-uri track_changed ---
    {
        $reset->();
        local $Slim::Player::Source::PLAYMODE = 'play';
        my ($ctl, $daemon, $ws) = r2_connect('02:51:00:00:00:08', $R51_T2);
        $ctl->observed->{status} = 'paused';
        my $C = d34_case($F51, 'TRANSFER');
        is(scalar(@$C), 12, "79-51 D1-R8: (precondition) the TRANSFER case holds source lines 3-14");
        d34_feed($ctl, $C);
        $deliver->('none');
        my @w = $wire->();
        diag("79-51 R8 wire: " . join(';', @w)) if $ENV{R51_DIAG};
        # recorded at HEAD (plan 79-51 Task 1 RED step), before the Control change:
        my @D1_TRANSFER_WIRE_HEAD = ('volume|60|', "start|$T2ID|100.094", "resume|$T2ID|100.094", 'seek|0.000|');
        is_deeply(\@w, \@D1_TRANSFER_WIRE_HEAD, "79-51 D1-R8: the wire equals the one this test produced at HEAD (D1_TRANSFER_WIRE_HEAD)");
        my @rs = $resumes->();
        is_deeply([ map { [ @$_[1 .. 3] ] } @rs ], [ [ 'resume', $T2ID, '100.094' ] ],
            "79-51 D1-R8: the playing frame's resume keeps today's arguments (T2, 100.094)");
    }

    # --- R9 (TRACKFIRST): the recorded track-first start (E9) ---
    # Corrected at GREEN (deviation, recorded in the SUMMARY): the plan expected HEAD to emit `resume 6lx1 0.104` here. It emits
    # NO resume: track_changed (line 4) writes observed.status = playing (Control.pm _debugStatusTransition), so the playing
    # frame (line 5) is not a Paused->Playing transition and opens no resume. The recorded frames therefore pin "no resume at all"
    # (green at HEAD, a guard); the anchor-title check at the playing frame is pinned by R9b on a doctored status.
    {
        $reset->();
        local $Slim::Player::Source::PLAYMODE = 'play';
        my ($ctl, $daemon, $ws) = r2_connect('02:51:00:00:00:09', $R51_TF_OLD);
        $ctl->observed->{status} = 'paused';
        $ctl->observed->{anchor} = { position_ms => 104, timestamp_ms => 1, speed => 0, seen_at => time(), seen_hr => Time::HiRes::time(), uri => $R51_TF_OLD };
        my $C = d34_case($F51, 'TRACKFIRST');
        is(scalar(@$C), 7, "79-51 D1-R9: (precondition) the TRACKFIRST case holds source lines 3-9");
        d34_feed($ctl, $C);
        $deliver->('none');
        diag("79-51 R9 wire: " . join(';', $wire->())) if $ENV{R51_DIAG};
        is(scalar($resumes->()), 0, "79-51 D1-R9: the recorded track-first start emits no resume at all (track_changed already wrote status playing)");
        ok(scalar(grep { $_ eq "change|$TFNEWID|" . ($R51_TF_OLD =~ s/^spotify:track://r) . "|none" } $wire->()), "79-51 D1-R9: ... only the change to the new title");
    }

    # --- R9b (TRACKFIRST, doctored status): the anchor belongs to the OLD title, so the resume carries no position ---
    # The recorded frames never reach the resume branch (see R9), so the status is doctored in this test's own session: after
    # line 4 (track_changed of the new title) the status is set back to paused, the state a `playback_changed paused` of the
    # daemon between track_changed and playing would leave (the anchor still holds the old title's 0.104 s). HEAD then emits
    # `resume <new> 0.104`: the old title's position for the new title (T-79-190, Connect.pm sets LMS's clock to it).
    {
        $reset->();
        local $Slim::Player::Source::PLAYMODE = 'play';
        my ($ctl, $daemon, $ws) = r2_connect('02:51:00:00:00:0a', $R51_TF_OLD);
        $ctl->observed->{status} = 'paused';
        $ctl->observed->{anchor} = { position_ms => 104, timestamp_ms => 1, speed => 0, seen_at => time(), seen_hr => Time::HiRes::time(), uri => $R51_TF_OLD };
        my $C = d34_case($F51, 'TRACKFIRST');
        d34_feed($ctl, $idx->($C, 0, 1));    # paused at 104, track_changed of the new title
        $ctl->observed->{status} = 'paused'; # doctored: see above
        d34_feed($ctl, $idx->($C, 2 .. 6));
        $deliver->('none');
        my @rs = $resumes->();
        is_deeply([ map { [ @$_[1 .. 3] ] } @rs ], [ [ 'resume', $TFNEWID, '' ] ],
            "79-51 D1-R9b: the resume names the new title with an empty position (HEAD sends the old title's 0.104)");
    }
}

# ============================================================
# 79-52 G1 (album-start deadline stop, .planning/debug/album-start-deadline-stop.md):
# the keep for a re-loaded title. For a bare-track OpenUri the Spotify app sends two
# `prepare play` commands; when the second lands while the first load is still corked
# the daemon flushes again and then sends only `context_changed` (album) and a
# `playback_state playing` of the SAME title (variant V3, 7 of 20 real runs). The shim's
# decision window (2000 ms) then gets neither keep nor boundary and closes LMS's fresh
# stream at its deadline. The REAL frames of two V3 runs (V3_SAME: the title already
# paused on the session; V3_CHANGE: another title paused, so the first frame is a title
# change with its pending 84-17 change) and of six negatives (V1, V1B, V2, V0: the
# other album-start variants; SKIP: an app skip; CSEEK: an app seek) come from
# t/fixtures/uat/album-start-deadline.log. The negatives post exactly the keeps and
# drains the code posted before 79-52. Replies of the shim's /boundary are delivered as
# in the 79-51 block.
# ============================================================
{
    my $F52 = 'album-start-deadline.log';
    my $reply = sub {
        my ($via) = @_;
        my $body = "via=$via boundary=130643728 anchor=drain ring_fill=0 total_pushed=130643728 total_popped=130643728 drops=0 gen=-1\n";
        return "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: " . length($body)
            . "\r\nConnection: close\r\n\r\n$body";
    };
    my $deliver = sub {
        my ($via) = @_;
        $IO::Socket::INET::READ_REPLY = $reply->($via);
        return Slim::Networking::Select::deliver();
    };
    my $reset = sub {
        r2_reset();
        $IO::Socket::INET::READ_REPLY = undef;
        @Slim::Networking::Select::READS   = ();
        @Slim::Networking::Select::REMOVED = ();
        @Slim::Utils::Timers::TIMERS       = ();
        @Slim::Utils::Log::WARNINGS        = ();
    };
    # the title the session sits on before the case: the item uri of its first track playback_state
    my $seed = sub {
        my ($F) = @_;
        my ($first) = grep { $_->{msg}{type} eq 'playback_state' && ref($_->{msg}{item}) eq 'HASH'
            && ($_->{msg}{item}{uri} // '') =~ /^spotify:track:/ } @$F;
        return $first->{msg}{item}{uri};
    };

    # --- V3_SAME (run 123930): paused 7GVU; the keep at the buffering frame, the second at the playing frame after the album context ---
    {
        $reset->();
        local $Slim::Player::Source::PLAYMODE = 'play';
        my $F = d34_case($F52, 'V3_SAME');
        is(scalar(@$F), 16, "79-52 G1-V3_SAME: (precondition) the case holds source lines 3-18");
        my ($ctl, $daemon, $ws) = r2_connect('02:52:00:00:00:01', $seed->($F));
        d34_feed($ctl, $F, to => '12:39:52.723');
        is(r2_keeps(), 1, "79-52 G1-V3_SAME: (precondition) up to the album context_changed (12:39:52.723) exactly one keep, the one at the buffering frame");
        d34_feed($ctl, $F, from => '12:39:53.030', to => '12:39:53.030');
        is(r2_keeps(), 2, "79-52 G1-V3_SAME: the playing frame of the re-loaded title (12:39:53.030) posts the second keep");
        is(r2_drains(), 0, "79-52 G1-V3_SAME: a same-title re-load plants no boundary");
        diag("79-52 G1_COUNTS V3_SAME keeps=" . r2_keeps() . " drains=" . r2_drains()) if $ENV{R52_DIAG};
    }

    # --- V3_CHANGE (run 130219): paused Rosanna, the app's track is a title change; the pending change blocks the buffering keep, the reply clears it ---
    {
        $reset->();
        local $Slim::Player::Source::PLAYMODE = 'play';
        my $F = d34_case($F52, 'V3_CHANGE');
        is(scalar(@$F), 16, "79-52 G1-V3_CHANGE: (precondition) the case holds source lines 3-18");
        my ($ctl, $daemon, $ws) = r2_connect('02:52:00:00:00:02', $seed->($F));
        d34_feed($ctl, $F, to => '13:02:41.223', at => [ [ '13:02:40.956', sub { $deliver->('departed') } ] ]);
        is(r2_keeps(), 0, "79-52 G1-V3_CHANGE: (precondition) up to the album context_changed (13:02:41.223) no keep: the pending change blocked the buffering frame");
        ok(!$ctl->observed->{pendingChange}, "79-52 G1-V3_CHANGE: (precondition) the shim's reply (departed, 13:02:40.956) cleared the pending change");
        d34_feed($ctl, $F, from => '13:02:41.514', to => '13:02:41.515');
        is(r2_keeps(), 1, "79-52 G1-V3_CHANGE: the playing frame of the re-loaded title (13:02:41.515) posts the keep");
        is(r2_drains(), 1, "79-52 G1-V3_CHANGE: exactly the one boundary of the title change");
        diag("79-52 G1_COUNTS V3_CHANGE keeps=" . r2_keeps() . " drains=" . r2_drains()) if $ENV{R52_DIAG};
    }

    # --- the six negatives: the keeps and drains of the code before 79-52, on the real frames of the other variants, a skip and a seek ---
    my $mac = 0;
    for my $n ([ 'V1', 2, 2 ], [ 'V1B', 2, 2 ], [ 'V2', 2, 2 ], [ 'V0', 3, 1 ], [ 'SKIP', 0, 2 ], [ 'CSEEK', 1, 0 ]) {
        my ($case, $wantKeeps, $wantDrains) = @$n;
        $reset->();
        local $Slim::Player::Source::PLAYMODE = 'play';
        my $F = d34_case($F52, $case);
        my ($ctl, $daemon, $ws) = r2_connect(sprintf('02:52:00:00:01:%02x', ++$mac), $seed->($F));
        for my $f (@$F) {
            d34_feed($ctl, [ $f ]);
            $deliver->('live') if $ctl->observed->{pendingChange};
        }
        is(r2_keeps(), $wantKeeps, "79-52 G1-NEG $case: exactly $wantKeeps keep(s), as before 79-52");
        is(r2_drains(), $wantDrains, "79-52 G1-NEG $case: exactly $wantDrains boundary drain(s), as before 79-52");
        diag("79-52 G1_COUNTS $case keeps=" . r2_keeps() . " drains=" . r2_drains()) if $ENV{R52_DIAG};
    }
}

done_testing();

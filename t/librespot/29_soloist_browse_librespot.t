#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use Digest::MD5 qw(md5_hex);

# Resolve project root (84-09: librespot half of t/29_soloist_browse.t -- the
# backend=librespot / unset cells, which resolve the REAL Backend::Librespot
# through the factory stub's classFor; the rest is t/soloist/29_soloist_browse_soloist.t)
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

my $module = "$project_dir/Plugins/SpotOn/ProtocolHandler.pm";
unless (-f $module) {
    die "Plugins/SpotOn/ProtocolHandler.pm not yet present in this checkout -- wrong project root or broken checkout (84-09: die, never skip)\n";
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
# LMS module stubs required to load ProtocolHandler.pm in isolation
# (Phase 72 Wave-0 gap -- ProtocolHandler.pm has never had dedicated test
# coverage before that plan; t/28's write_stub pattern is copied verbatim).
#
# Phase 73-03 Task 3 (D-03, Modell B): rewritten for the persistent-daemon
# dispatch matrix -- soloist Browse now shares the SAME 'soc'/HTTP-/stream
# path as Connect (canDirectStream/new() resolve the daemon's HTTP /stream
# URL) instead of the retired per-track 'sol' transcoder profile.
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

# Controllable Prefs stub -- get() reads from a controllable %FAKE hash so
# individual test cases can flip 'backend' without touching the real
# Slim::Utils::Prefs machinery.
write_stub($stub_dir, 'Slim::Utils::Prefs', <<'END');
package Slim::Utils::Prefs;
our %FAKE;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::preferences"} = \&preferences;
}
sub preferences { return bless { _ns => $_[0] }, 'Slim::Utils::Prefs' }
sub get    { my ($self, $key) = @_; return $FAKE{$key}; }
sub set    { my ($self, $key, $val) = @_; $FAKE{$key} = $val; }
sub client { return bless {}, 'Slim::Utils::Prefs' }
sub setChange { }
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

write_stub($stub_dir, 'Slim::Utils::Versions', <<'END');
package Slim::Utils::Versions;
sub compareVersions { return 1 }
1;
END

# Phase 82 Plan 04: a real (TTL-ignoring) in-memory cache -- the negative-
# cache short-circuit test (_asyncRefetch) needs get() to see what set()
# stored. A single %STORE, shared for the whole file (ProtocolHandler.pm's
# $cache is one instance for the process), like production.
write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
our %STORE;
# Fable-5 review of quick-260910-upw (CR-01/WR-01): %STORE_TTL records the
# ttl argument passed to set() -- the stub used to ignore it entirely, which
# is why a bounded-but-different-TTL fix could not be expressed in a test.
our %STORE_TTL;
sub new    { return bless {}, shift }
sub get    { my ($self, $key) = @_; return $STORE{$key}; }
sub set    { my ($self, $key, $val, $ttl) = @_; $STORE{$key} = $val; $STORE_TTL{$key} = $ttl; }
sub remove { my ($self, $key) = @_; delete $STORE{$key}; delete $STORE_TTL{$key}; }
1;
END

write_stub($stub_dir, 'Slim::Utils::Network', <<'END');
package Slim::Utils::Network;
sub serverAddr { return '127.0.0.1' }
1;
END

write_stub($stub_dir, 'Slim::Utils::Misc', <<'END');
package Slim::Utils::Misc;
sub crackURL         { return ('127.0.0.1', 80, '/') }
sub findbin           { }
sub addFindBinPaths   { }
1;
END

write_stub($stub_dir, 'Slim::Music::Info', <<'END');
package Slim::Music::Info;
sub setCurrentTitle { }
1;
END

write_stub($stub_dir, 'Slim::Schema::RemoteTrack', <<'END');
package Slim::Schema::RemoteTrack;
sub fetch { return undef }
1;
END

write_stub($stub_dir, 'Slim::Formats::RemoteStream', <<'END');
package Slim::Formats::RemoteStream;
sub new      { return bless {}, shift }
sub AUTOLOAD { }
sub can      { 1 }
1;
END

# Records constructor args (as a copied hash on the returned blessed object)
# so tests can inspect whether new() substituted the daemon /stream URL.
write_stub($stub_dir, 'Slim::Player::Protocols::HTTP', <<'END');
package Slim::Player::Protocols::HTTP;
our @NEW_ARGS;
sub new {
    my ($class, $args) = @_;
    push @NEW_ARGS, $args;
    return bless { %$args }, $class;
}
1;
END

# Minimal stand-in -- ProtocolHandler.pm only needs the CACHE_VERSION
# constant at load time (Cache->new('spoton', SPOTON_CACHE_VERSION())).
write_stub($stub_dir, 'Plugins::SpotOn::Plugin', <<'END');
package Plugins::SpotOn::Plugin;
use constant SPOTON_CACHE_VERSION => 4;
sub _pluginDataFor { return 'test-basedir' }
1;
END

# 73-03 Task 3: controllable DaemonManager stub. $HELPER is undef (no
# daemon) by default; test cases assign a Test::FakeSoloistDaemon instance
# to simulate an alive daemon with a known stream port.
# 76-04 Task 2: $RESOLVED stubs resolveSoloistFormat (default 'pcm' so the
# pre-76-04 direct-stream assertions keep passing unchanged); $PASSTHROUGH
# stubs the librespot boolean for formatOverride coverage.
write_stub($stub_dir, 'Plugins::SpotOn::Unified::DaemonManager', <<'END');
package Plugins::SpotOn::Unified::DaemonManager;
our $HELPER;
our $RESOLVED       = 'pcm';
our $PASSTHROUGH    = 0;
# Phase 82 Plan 44 (D-10, Runde 44): $PREREQ_STATE controls the new
# spawn-capability gate's answer -- default 'soloist_ready' so the
# pre-existing Fall a-integration/Fall c-2 assertions (which never touch
# this gate) keep passing unchanged.
our $PREREQ_STATE   = 'soloist_ready';
our @PENDING_QUEUE_CALLS;
sub helperForClient             { return $HELPER; }
sub resolveSoloistFormat        { return $RESOLVED; }
sub resolvePassthroughForClient { return $PASSTHROUGH; }
sub resolveServedPassthroughForClient { return $PASSTHROUGH; }   # 79-34 D-29: Backend::Librespot formats names it
sub backendPrereqState          { return $PREREQ_STATE; }
# 84-08: Case 2's package-level anchor is entered through the Soloist role
# (Backend::Soloist::deferTrackRequestForClient); DaemonManager keeps only
# the store. Same recorded shape as before: [clientId, uri, posMs, opts].
sub queuePendingTrackRequest    { shift; my @a = @_; push @PENDING_QUEUE_CALLS, [@a[0 .. 3]]; return; }
# 84-08 (SEAM-6.2): the backend factory, mirroring the production rule
# (backendName = validated `backend` pref, default librespot). It hands out
# the REAL role classes -- Backend::Soloist with Test::FakeControl behind
# it, Backend::Librespot over $HELPER -- never a role mock, so the moved
# URL/defer/origin logic is what these cells exercise (revision 8).
sub backendName {
    my $name = $Slim::Utils::Prefs::FAKE{backend} // 'librespot';
    return $name eq 'soloist' ? 'soloist' : 'librespot';
}
sub backendClass {
    require Plugins::SpotOn::Backend;
    return Plugins::SpotOn::Backend::classFor(backendName());
}
our @BACKENDFOR_CALLS;
sub backendFor {
    my ($class, $c) = @_;
    return undef unless defined $c;
    push @BACKENDFOR_CALLS, $c;
    my $be = backendClass()->new(ref $c ? $c->id : $c);
    $be->client($c) if ref $c;
    return $be;
}
1;
END

# Phase 82 Plan 04: _asyncRefetch's negative-cache test needs
# require Plugins::SpotOn::API::SpClient to resolve WITHOUT compiling the
# real module (which pulls in JSON::XS::VersionOneAndTwo, not guaranteed
# present outside a full LMS install). $FETCH_RESULT controls getTrack's
# callback payload -- undef simulates the 404-from-both-sources case.
# Quick 260910-upw: $FETCH_ERROR controls the second callback argument --
# the error hash SpClient::_doRequest already produces ({error, code}) but
# which ProtocolHandler.pm's $fetchCb dropped before this fix.
write_stub($stub_dir, 'Plugins::SpotOn::API::SpClient', <<'END');
package Plugins::SpotOn::API::SpClient;
our $FETCH_RESULT = undef;
our $FETCH_ERROR  = undef;
our $FETCH_CALLS  = 0;
sub getTrack   { my ($class, $accountId, $trackId, $cb)   = @_; $FETCH_CALLS++; $cb->($FETCH_RESULT, $FETCH_ERROR); }
sub getEpisode { my ($class, $accountId, $episodeId, $cb) = @_; $FETCH_CALLS++; $cb->($FETCH_RESULT, $FETCH_ERROR); }
1;
END

# Plan 77-04: records constructor callbacks + post($url) calls, and exposes
# a deferred-fire mode so tests can assert no WS command was recorded before
# the arm POST's callback fires (ordering, not timing -- RESEARCH Pitfall 1).
# Mirrors t/30_soloist_daemon.t's stub shape, extended with a call recorder
# and manual fire_ok/fire_error control.
# 84-08 Task 3: Backend::Soloist::state() falls back to the filesystem
# pairing read when Control has made no observation (the Status page's
# truth) -- a recorder instead of the real module (no cachedir here).
write_stub($stub_dir, 'Plugins::SpotOn::Soloist', <<'END');
package Plugins::SpotOn::Soloist;
our $PAIRED = 0;
sub isPairedForClient { return $PAIRED; }
1;
END

# 84-08: Backend::Librespot (loaded by the factory stub above for
# backend=librespot) imports to_json/from_json at compile time.
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

write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
our @CALLS;             # every instance that called ->post(), in order
our $AUTO_FIRE = 'ok';  # 'ok' | 'error' | 'defer'
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
    # 'defer' -- caller fires manually via fire_ok/fire_error below.
    return $self;
}
sub fire_ok    { my $self = shift; $self->{ok_cb}->($self); }
sub fire_error { my $self = shift; $self->{err_cb}->($self, '500 Internal Server Error', undef); }
1;
END

# Phase 82 Plan 01 Task 2: Control-vertrag stub. getNextTrack now delegates
# entirely to Plugins::SpotOn::Soloist::Control->for_client($client)
# ->requestTrack(...) -- this stub shadows the REAL Control.pm (stub_dir
# precedes project_dir in @INC below) with a controllable recorder so these
# tests exercise ProtocolHandler's delegation, not Control's own internal
# state machine (that is t/44_soloist_control.t's job).
write_stub($stub_dir, 'Plugins::SpotOn::Soloist::Control', <<'END');
package Plugins::SpotOn::Soloist::Control;
our $CTL;
sub for_client { return $CTL; }
# 84-08: Backend::Soloist::capabilities reads the 84-17 hold constants.
sub HOLD_CAP_S     { 60 }
sub HOLD_RECHECK_S { 5 }
sub HOLD_MAX_S     { 180 }

package Test::FakeControl;
sub new {
    my ($class, %args) = @_;
    return bless {
        auto       => ($args{auto} // 'ok'),
        seekable   => ($args{seekable} // 1),
        generation => 0,
        marker     => undef,
        recorded   => [],    # [ [method, @args], ... ] -- noteSeekIntent/noteDuration/noteMetadataMissing
        mode       => ($args{mode} // 'browse'),    # 83.1-02 Task 1: ProtocolHandler's post-requestTrack release reads this
    }, $class;
}
# mode($val) -- 83.1-02 Task 1: ProtocolHandler::getNextTrack now reads
# $ctl->mode after requestTrack (D-D1 Browse-entry release, guarded by
# `mode ne 'connect'`). Defaults to 'browse' -- requestTrack's own
# connect->browse handoff is Control's own internal state machine (t/44's
# job), not re-modeled here.
sub mode { my $self = shift; $self->{mode} = shift if @_; return $self->{mode}; }
# 84-08: Backend::Soloist::state reads observed (status/paired/is_active).
sub observed { return $_[0]->{observed} //= {}; }
sub requestTrack {
    my ($self, $url, $pos, $opts) = @_;
    push @Test::FakeControl::CALLS, [ $url, $pos, $opts ];
    if ($self->{auto} eq 'ok') {
        $opts->{successCb}->() if $opts->{successCb};
    }
    elsif ($self->{auto} eq 'error') {
        $opts->{errorCb}->('PROBLEM_OPENING', 'x') if $opts->{errorCb};
    }
}
# Phase 82 Plan 04: seek/rewind marker + metadata contract, extended on the
# SAME recorder so t/29 asserts ProtocolHandler's DELEGATION to these
# methods (their own state-machine correctness is t/44's job).
sub seekable { my $self = shift; return $self->{seekable}; }
# Debug session connect-skip-prev-ton-bleibt (1B): Control's one-shot
# restart allowance, read-and-clear like consumeSeekIntent. Consume calls
# are tracked in their own list (not `recorded`, which stays the
# marker/metadata ledger the existing assertions compare exactly).
sub consumeRestartAllowance {
    my ($self, $url) = @_;
    push @{ $self->{consumed} }, $url;
    my $allowed = delete $self->{restart_allowance};
    return (defined $allowed && $allowed eq $url) ? 1 : 0;
}
sub noteSeekIntent {
    my ($self, $url, $target_ms) = @_;
    push @{ $self->{recorded} }, [ 'noteSeekIntent', $url, $target_ms ];
    $self->{marker} = { url => $url, target_ms => $target_ms };
}
sub consumeSeekIntent {
    my ($self, $url) = @_;
    my $m = delete $self->{marker};
    return undef unless $m && $m->{url} eq $url;
    return $m->{target_ms};
}
sub nextStreamGeneration { my $self = shift; return ++$self->{generation}; }
sub streamGeneration     { my $self = shift; return $self->{generation}; }
sub noteDuration {
    my ($self, $url, $secs) = @_;
    push @{ $self->{recorded} }, [ 'noteDuration', $url, $secs ];
}
sub noteMetadataMissing {
    my ($self, $url) = @_;
    push @{ $self->{recorded} }, [ 'noteMetadataMissing', $url ];
}
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
    *main::DEBUGLOG    = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
    *main::ISWINDOWS   = sub () { 0 };
    *main::ISMAC       = sub () { 0 };
}

# canSeek()'s LMS-version check compares $::VERSION -- fix it to a value the
# real Slim::Utils::Versions stub is happy with regardless (stub always
# returns 1), but set a plausible LMS version string for realism.
our $VERSION;
$::VERSION = '9.0.0';

unshift @INC, $stub_dir, $project_dir;

# ProtocolHandler.pm calls Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION()
# as a fully-qualified sub at load time -- pre-load the stub so Perl doesn't
# need an implicit require for it.
require_ok('Plugins::SpotOn::Plugin')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Plugin stub");

require_ok('Plugins::SpotOn::ProtocolHandler')
    or BAIL_OUT("Failed to load Plugins::SpotOn::ProtocolHandler");

# new()'s fallthrough calls Slim::Player::Protocols::HTTP->new($args) as a
# fully-qualified call, never require'd by ProtocolHandler.pm itself --
# pre-load the stub so that call resolves.
require_ok('Slim::Player::Protocols::HTTP')
    or BAIL_OUT("Failed to load Slim::Player::Protocols::HTTP stub");

require_ok('Plugins::SpotOn::Unified::DaemonManager')
    or BAIL_OUT("Failed to load the Plugins::SpotOn::Unified::DaemonManager stub");

require_ok('Slim::Networking::SimpleAsyncHTTP')
    or BAIL_OUT("Failed to load the Slim::Networking::SimpleAsyncHTTP stub");

# Force-load now (ProtocolHandler.pm only `require`s this lazily, inside
# getNextTrack) so Test::FakeControl (defined in the same stub file) exists
# before any test constructs one.
require_ok('Plugins::SpotOn::Soloist::Control')
    or BAIL_OUT("Failed to load the Plugins::SpotOn::Soloist::Control stub");

# Force-load now (ProtocolHandler.pm only `require`s this lazily, inside
# _asyncRefetch) -- otherwise the first require() there would re-run this
# stub's `our` initializers and silently clobber whatever the negative-
# cache test just set.
require_ok('Plugins::SpotOn::API::SpClient')
    or BAIL_OUT("Failed to load the Plugins::SpotOn::API::SpClient stub");

sub reset_backend {
    my ($value) = @_;
    if (defined $value) {
        $Slim::Utils::Prefs::FAKE{backend} = $value;
    } else {
        delete $Slim::Utils::Prefs::FAKE{backend};
    }
}

my $pkg = 'Plugins::SpotOn::ProtocolHandler';

# 84-08: ProtocolHandler.pm source for the seam's regex-over-source pins.
our $protocol_src_84_08 = do {
    open(my $fh, '<', "$project_dir/Plugins/SpotOn/ProtocolHandler.pm") or die "ProtocolHandler.pm: $!";
    local $/; <$fh>;
};

# ============================================================
# Mock client -- can('master') always false (single-player scenario: the
# ternary `$client->can('master') ? $client->master : $client` in
# ProtocolHandler.pm then just uses $client itself), isSynced()
# per-instance controllable.
# ============================================================
{
    package MockClient;
    sub new {
        my ($class, %args) = @_;
        return bless { id => ($args{id} // 'player1'), synced => ($args{synced} // 0) }, $class;
    }
    # 84.2-05: `can` answers true for 'pluginData' only (every other name
    # keeps 0 -- other pins rely on it); the accessor stores per instance.
    sub can      { return (($_[1] // '') eq 'pluginData') ? 1 : 0; }
    sub isSynced { return $_[0]->{synced}; }
    sub id       { return $_[0]->{id}; }
    sub pluginData { my ($s, $k, @v) = @_; $s->{pd}{$k} = $v[0] if @v; return $s->{pd}{$k} }
}

# 73-03 Task 3: test double for the persistent SoloistDaemon helper.
# Blessed into the REAL class name (Scalar::Util::blessed trickery, per the
# plan) so any future isa() check against it behaves like production code
# would; ProtocolHandler.pm itself only calls alive()/_streamPort()/_ws().
{
    package Plugins::SpotOn::Unified::SoloistDaemon;
    sub new {
        my ($class, %args) = @_;
        return bless { %args }, $class;
    }
    sub alive       { return $_[0]->{alive} // 1; }
    sub _streamPort { return $_[0]->{port}; }
    sub _ws         { return $_[0]->{ws}; }

    # 260914-qn1 (Signature C): call recorder for the daemon-level
    # deferral gate in ProtocolHandler::getNextTrack.
    our @DEFER_CALLS;
    sub deferTrackRequest { my $self = shift; push @DEFER_CALLS, [@_]; return 1; }
}
# 84-08: the librespot-class double (Fall c-2) answers alive like every
# production daemon (Backend::Soloist::state reads it after the defer path).
{
    package Plugins::SpotOn::Unified::Daemon;
    sub alive { return 1; }
}

# D-07 (Phase 78): FakeSoloistWs for the bounded model -- lastTrackId
# accessor and sendCommand recorder for ProtocolHandler's gate-free
# getNextTrack.
{
    package Test::FakeSoloistWs;
    sub new {
        my ($class, %args) = @_;
        return bless {
            connected     => 1,
            lastTrackId   => undef,
            sent          => [],
            send_success  => 1,
            sessionPaused => 0,
            %args,
        }, $class;
    }
    sub connected   { return $_[0]->{connected}; }
    sub lastTrackId { my $self = shift; $self->{lastTrackId} = shift if @_; return $self->{lastTrackId}; }
    # KE: browse-connect-gating -- ProtocolHandler::getNextTrack sets this
    # right before dispatching the WS 'play' command.
    sub soloistBrowseActive { my $self = shift; $self->{soloistBrowseActive} = shift if @_; return $self->{soloistBrowseActive}; }
    # Plan 77-04 (D-05): a missing accessor counts as paused in production
    # (degrade-open), but this stub always answers `can()` truthy -- tests
    # control the value directly via the constructor/setter instead.
    sub sessionPaused { my $self = shift; $self->{sessionPaused} = shift if @_; return $self->{sessionPaused}; }
    sub sendCommand {
        my ($self, $cmd, %p) = @_;
        push @{ $self->{sent} }, [$cmd, \%p];
        return $self->{send_success};
    }
    sub can { return 1; }
}
{
    # librespot backend with a (stale) Control registered: the seek/rewind
    # marker sites ask the ROLE, which has no opinion -- Control is never
    # touched (before 84-08 they read Control->for_client whatever the backend).
    reset_backend('librespot');
    my $ctl = Test::FakeControl->new(seekable => 0);
    local $Plugins::SpotOn::Soloist::Control::CTL = $ctl;
    local $Plugins::SpotOn::Connect::_IS_CONNECT = 0;
    my $client = MockClient->new(synced => 0);
    my $song   = MockSong->new(master => $client, track => MockTrack->new('spoton://track:abc123'));
    is_deeply($pkg->getSeekData($client, $song, 30), { timeOffset => 30 },
        '84-08: librespot getSeekData -> {timeOffset} (role query(seekable) undef = no opinion)');
    is($pkg->canDoAction($client, 'spoton://track:abc123', 'rew'), 1,
        "84-08: librespot canDoAction('rew') outside connect -> 1 (no seekable veto from a foreign Control)");
    is_deeply($ctl->{recorded}, [], '84-08: librespot -- no noteSeekIntent reaches a registered Control');
}
{
    # 79-28 D-23: a librespot connect seek goes to /control/seek (Connect.pm
    # _forwardLibrespotSeek); LMS must not restart /stream, so getSeekData
    # answers undef and records no seek intent.
    reset_backend('librespot');
    my $ctl = Test::FakeControl->new(seekable => 1);
    local $Plugins::SpotOn::Soloist::Control::CTL = $ctl;
    local $Plugins::SpotOn::Connect::_IS_CONNECT = 1;
    my $client = MockClient->new(synced => 0);
    my $song   = MockSong->new(master => $client, track => MockTrack->new('spoton://connect-9'));
    is($pkg->getSeekData($client, $song, 30), undef,
        '79-28 D-23 seek: librespot connect getSeekData -> undef (no LMS /stream restart, connectSeekViaControl)');
    is_deeply($ctl->{recorded}, [], '79-28 D-23 seek: librespot connect getSeekData records no noteSeekIntent');
    local $Plugins::SpotOn::Connect::_IS_CONNECT = 0;
    is_deeply($pkg->getSeekData($client, $song, 30), { timeOffset => 30 },
        '79-28 D-23 seek: librespot outside connect keeps {timeOffset => 30}');
}

# ============================================================
# backend = 'librespot' (pre-phase behavior unchanged) -- regression net
# for BOTH backends per Task 3 acceptance criteria.
# ============================================================
{
    reset_backend('librespot');
    $Plugins::SpotOn::Unified::DaemonManager::HELPER =
        Plugins::SpotOn::Unified::SoloistDaemon->new(alive => 1, port => 39755);

    is($pkg->contentType(), 'son', "contentType() eq 'son' when backend=librespot");

    is($pkg->getFormatForURL('spoton://track:abc123'), 'soc',
        "getFormatForURL(track) eq 'soc' when backend=librespot (pre-phase behavior)");

    my $client = MockClient->new(synced => 0);
    my $result = $pkg->canDirectStream($client, 'spoton://track:abc123');
    like($result, qr{^http://127\.0\.0\.1:39755/track/abc123$},
        "canDirectStream() returns the daemon /track/{id} URL for an unsynced librespot browse client (unchanged)");

    my $syncedClient = MockClient->new(synced => 1);
    is($pkg->canDirectStream($syncedClient, 'spoton://track:abc123'), 0,
        "canDirectStream() == 0 for a synced librespot browse client (unchanged -- new() proxy handles it)");

    ok($pkg->canSeek($client), "canSeek() truthy when backend=librespot");
}

# ============================================================
# backend unset (default -> librespot behavior)
# ============================================================
{
    reset_backend(undef);

    is($pkg->contentType(), 'son', "contentType() eq 'son' when backend is unset (default librespot)");

    is($pkg->getFormatForURL('spoton://track:abc123'), 'soc',
        "getFormatForURL(track) eq 'soc' when backend is unset (default librespot)");

    ok($pkg->canSeek(MockClient->new), "canSeek() truthy when backend is unset (default librespot)");
}

# ============================================================
# 76-04 Task 2 (D-06/D-07): resolver-gated canDirectStream + formatOverride
# smp routing. The DaemonManager stub's $RESOLVED controls the resolver.
# ============================================================
{
    package MockTrack;
    sub new        { return bless { url => $_[1], _ss => undef, _sr => undef, _ch => undef }, $_[0]; }
    sub url        { return $_[0]->{url}; }
    sub can        { return 1; }
    sub samplesize { my $self = shift; $self->{_ss} = shift if @_; return $self->{_ss}; }
    sub samplerate { my $self = shift; $self->{_sr} = shift if @_; return $self->{_sr}; }
    sub channels   { my $self = shift; $self->{_ch} = shift if @_; return $self->{_ch}; }
}
{
    package MockSong;
    sub new      { my ($class, %args) = @_; return bless { %args, _duration => undef, _startOffset => undef, _seekdata => undef, _streamUrl => undef }, $class; }
    sub master   { return $_[0]->{master}; }
    sub track    { return $_[0]->{track}; }
    sub duration { my $self = shift; $self->{_duration} = shift if @_; return $self->{_duration}; }
    sub startOffset { my $self = shift; $self->{_startOffset} = shift if @_; return $self->{_startOffset}; }
    sub seekdata { my $self = shift; $self->{_seekdata} = shift if @_; return $self->{_seekdata}; }
    sub streamUrl { my $self = shift; $self->{_streamUrl} = shift if @_; return $self->{_streamUrl}; }
    sub currentTrack { return $_[0]->{track}; }
}

# Controllable Connect stub -- default isSpotifyConnect returns false.
{
    package Plugins::SpotOn::Connect;
    our $_IS_CONNECT = 0;
    our @RELEASE_CALLS;    # 83.1-02 Task 1: [ [client, source], ... ]
    sub isSpotifyConnect { return $_IS_CONNECT; }
    sub releaseConnectClaim {
        my ($class, $client, $source) = @_;
        push @RELEASE_CALLS, [ $client, $source ];
        return;
    }
}

# --- librespot connect: explicit pref check unchanged (D-14 regression pin) ---
{
    reset_backend('librespot');
    $Plugins::SpotOn::Unified::DaemonManager::HELPER =
        Plugins::SpotOn::Unified::SoloistDaemon->new(alive => 1, port => 39755);
    my $client = MockClient->new(synced => 0);

    local $Slim::Utils::Prefs::FAKE{streamFormat} = 'mp3';
    is($pkg->canDirectStream($client, 'spoton://connect-1234567890'), 0,
        "librespot connect: explicit streamFormat=mp3 still forces transcoding (unchanged, D-14)");

    $Slim::Utils::Prefs::FAKE{streamFormat} = 'auto';
    like($pkg->canDirectStream($client, 'spoton://connect-1234567890'),
        qr{^http://127\.0\.0\.1:39755/stream$},
        "librespot connect: streamFormat=auto keeps the direct /stream URL (unchanged, D-14)");
}
# --- formatOverride: smp routing (D-07), librespot cells (84-09: split out of
# the soloist block in t/soloist/29_soloist_browse_soloist.t) ---
{
    my $client = MockClient->new(synced => 0);

    # librespot: explicit mp3 pref routes to 'smp' too; auto stays 'soc';
    # passthrough stays 'son' (untouched by the smp branch).
    reset_backend('librespot');
    my $connectSong = MockSong->new(
        master => $client,
        track  => MockTrack->new('spoton://connect-1234567890'),
    );
    local $Slim::Utils::Prefs::FAKE{streamFormat} = 'mp3';
    local $Plugins::SpotOn::Unified::DaemonManager::PASSTHROUGH = 0;
    is($pkg->formatOverride($connectSong), 'smp',
        "formatOverride: librespot explicit streamFormat=mp3 -> 'smp' (D-07)");

    $Slim::Utils::Prefs::FAKE{streamFormat} = 'auto';
    is($pkg->formatOverride($connectSong), 'soc',
        "formatOverride: librespot streamFormat=auto without passthrough -> 'soc' (unchanged)");

    $Plugins::SpotOn::Unified::DaemonManager::PASSTHROUGH = 1;
    is($pkg->formatOverride($connectSong), 'son',
        "formatOverride: librespot passthrough -> 'son' (unchanged, D-14)");
}

# ============================================================
# Debug session connect-seek-zeit-ab-null (2026-09-24, fix option A):
# onStream's seekdata branch sets LMS' clock itself --
# song->startOffset = seekdata.timeOffset, the pattern of LMS' own handlers
# (HTTP.pm requestString "Fix progress bar", File.pm). Song::open resets
# startOffset to 0 on every (re)open ("handlers will set this if
# necessary") and LMS' clock is startOffset + the player's elapsed time
# (StreamingController::playingSongElapsed). Before the fix the Soloist
# restart chain never set it (the false premise of Note §3.3 "LMS-Byte-Uhr
# startet bei N"), so the clock ran from 0:00 after every browse seek and
# after every connect seek whose daemon echo was suppressed (target within
# 3 s of the daemon's frozen position; live Step 2 runs B/D/E).
#
# MockSongW logs every startOffset WRITE so the non-seek paths can assert
# "not written" directly. Every song starts at 0, as Song::open leaves it.
# ============================================================
{
    package MockSongW;
    our @ISA = ('MockSong');
    sub startOffset {
        my $self = shift;
        push @{ $self->{_soWrites} }, $_[0] if @_;
        return $self->SUPER::startOffset(@_);
    }
    sub writes { return $_[0]->{_soWrites} || []; }
}

sub new_song_w {
    my ($client, $url) = @_;
    my $song = MockSongW->new(master => $client, track => MockTrack->new($url));
    $song->{_startOffset} = 0;    # Song::open's reset, not a logged write
    return $song;
}

# --- Fall 2 -- (b2) unified-browse-sync-proxy (W6-Korrektur: NEUE
# Testaufrufstelle -- kein bestehender $pkg->new()-Aufruf in dieser Datei
# durchlaeuft diesen Block, da sein Guard `!_useSoloist()` verlangt und
# beide bestehenden new()-Aufrufe oben unter backend=soloist laufen).
# backend=librespot (=> !_useSoloist()) with a synced client so the guard
# `!_useSoloist() && $url =~ .../track|episode/` is satisfied. ---
{
    reset_backend('librespot');
    $Plugins::SpotOn::Unified::DaemonManager::HELPER =
        Plugins::SpotOn::Unified::SoloistDaemon->new(alive => 1, port => 39755);
    my $client = MockClient->new(synced => 1);

    local *Slim::Utils::Network::serverAddr = sub { '10.0.0.1' };
    my $streamObj = $pkg->new({ url => 'spoton://track:abc123', client => $client });
    ok(defined $streamObj, "CR-05 (b2): new() is defined even with serverAddr() stubbed to a different address");
    like($streamObj->{url}, qr{^http://127\.0\.0\.1:39755/track/abc123$},
        "CR-05 (b2): unified browse sync-group proxy URL is hardcoded to 127.0.0.1, ignoring serverAddr()=10.0.0.1");
    unlike($streamObj->{url}, qr{10\.0\.0\.1},
        "CR-05 (b2): stubbed 10.0.0.1 does not leak into the unified browse sync-group proxy URL");
}

done_testing();

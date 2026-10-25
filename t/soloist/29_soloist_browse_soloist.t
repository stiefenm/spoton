#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use Digest::MD5 qw(md5_hex);

# Resolve project root (84-09: soloist half of t/29_soloist_browse.t -- every cell
# that passes without librespot; the cells that resolve classFor('librespot')
# are t/librespot/29_soloist_browse_librespot.t. No core half: the subject is
# Soloist browse over the ProtocolHandler role seam.)
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
# 74b D-22: the staging seam contentTypeFor asks (never the shipped constant);
# default 0 = Auto keeps today's PCM delivery, cells override it with a local
# glob assignment.
sub autoFlacEnabled             { return 0 }
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
    # 79-33 (D-28 F3): a Control-internal double fire, in the four orders LMS must survive.
    elsif ($self->{auto} eq 'both') {
        $opts->{successCb}->() if $opts->{successCb};
        $opts->{errorCb}->('PROBLEM_OPENING', 'x') if $opts->{errorCb};
    }
    elsif ($self->{auto} eq 'both_rev') {
        $opts->{errorCb}->('PROBLEM_OPENING', 'x') if $opts->{errorCb};
        $opts->{successCb}->() if $opts->{successCb};
    }
    elsif ($self->{auto} eq 'twice_ok') {
        $opts->{successCb}->() for 1 .. 2;
    }
    elsif ($self->{auto} eq 'twice_err') {
        $opts->{errorCb}->('PROBLEM_OPENING', 'x') for 1 .. 2;
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

# ============================================================
# backend = 'soloist' (D-03, Phase 78): daemon alive, unsynced player --
# canDirectStream returns the bounded per-track URL.
# ============================================================
{
    reset_backend('soloist');
    $Plugins::SpotOn::Unified::DaemonManager::HELPER =
        Plugins::SpotOn::Unified::SoloistDaemon->new(alive => 1, port => 39755);

    is($pkg->contentType(), 'soc', "contentType() eq 'soc' when backend=soloist (D-03)");

    is($pkg->getFormatForURL('spoton://track:abc123'), 'soc',
        "getFormatForURL(track) eq 'soc' when backend=soloist (D-03)");
    is($pkg->getFormatForURL('spoton://episode:abc123'), 'soc',
        "getFormatForURL(episode) eq 'soc' when backend=soloist (D-03)");

    my $client = MockClient->new(synced => 0);
    my $result = $pkg->canDirectStream($client, 'spoton://track:abc123');
    is($result, 'http://127.0.0.1:39755/stream?uri=spotify:track:abc123&g=0',
        "canDirectStream() returns the bounded per-track URL for an unsynced soloist browse client (D-03, Phase 78; g=0 -- no Control registered)");

    ok($pkg->canSeek($client), "canSeek() truthy when backend=soloist");

    my $streamObj = $pkg->new({ url => 'spoton://track:abc123', client => $client });
    ok(defined $streamObj, "new({url => spoton://track:..., unsynced}) is defined when backend=soloist");
    # new() is only called when canDirectStream() returned 0, so the
    # spoton:// URL ALWAYS needs substitution to the bounded endpoint.
    like($streamObj->{url}, qr{^http://127\.0\.0\.1:39755/stream\?uri=spotify:track:abc123&g=0$},
        "new() substitutes the bounded URL for an unsynced soloist browse client too (D-03 proxy)");
}

# ============================================================
# backend = 'soloist', synced player -- canDirectStream returns 0 (proxy
# handles it); new() substitutes the daemon /stream URL.
# ============================================================
{
    reset_backend('soloist');
    $Plugins::SpotOn::Unified::DaemonManager::HELPER =
        Plugins::SpotOn::Unified::SoloistDaemon->new(alive => 1, port => 39755);

    my $client = MockClient->new(synced => 1);

    is($pkg->canDirectStream($client, 'spoton://track:abc123'), 0,
        "canDirectStream() == 0 for a synced soloist browse client (D-03 -- new() proxy handles it)");

    my $streamObj = $pkg->new({ url => 'spoton://track:abc123', client => $client });
    ok(defined $streamObj, "new({url => spoton://track:..., synced}) is defined when backend=soloist");
    like($streamObj->{url}, qr{^http://127\.0\.0\.1:39755/stream\?uri=spotify:track:abc123&g=0$},
        "new() substitutes the bounded URL for a synced soloist browse client (D-03 sync-group proxy)");
}

# ============================================================
# 84-08 Task 1 (SEAM-6.2): new()'s Browse substitution goes through the
# backend role -- ONE streamUrl(..., 'browse_proxy') call in the core,
# the bounded /stream?uri=...&g=<gen> URL built by Backend::Soloist.
# Mutation evidence (84-08 SUMMARY): `uri=` -> `url=` in a scratch copy of
# Backend/Soloist.pm turns the role cells and the new() cells red.
# ============================================================
{
    reset_backend('soloist');
    $Plugins::SpotOn::Unified::DaemonManager::HELPER =
        Plugins::SpotOn::Unified::SoloistDaemon->new(alive => 1, port => 39755);
    @Plugins::SpotOn::Unified::DaemonManager::BACKENDFOR_CALLS = ();
    local $Plugins::SpotOn::Soloist::Control::CTL = Test::FakeControl->new;

    my $client = MockClient->new(synced => 1, id => 'p84');
    my $streamObj = $pkg->new({ url => 'spoton://episode:ep84', client => $client });
    is(scalar(@Plugins::SpotOn::Unified::DaemonManager::BACKENDFOR_CALLS), 1,
        "84-08: new() asks DaemonManager->backendFor exactly once for a Browse URL");
    is($streamObj->{url}, 'http://127.0.0.1:39755/stream?uri=spotify:episode:ep84&g=1',
        "84-08: new() takes the role's browse_proxy URL (episode, g from Control's generation counter)");

    my $be = Plugins::SpotOn::Unified::DaemonManager->backendFor($client);
    isa_ok($be, 'Plugins::SpotOn::Backend::Soloist', '84-08: backend=soloist -> the REAL Backend::Soloist');
    is($be->streamUrl($client, undef, 'browse_proxy', url => 'spoton://track:abc123'),
        'http://127.0.0.1:39755/stream?uri=spotify:track:abc123&g=2',
        "84-08: Backend::Soloist streamUrl(browse_proxy) builds /stream?uri=spotify:<type>:<id>&g=<gen>");
    is($be->streamUrl($client, 'spoton://connect-123', 'browse_proxy'), undef,
        "84-08: Backend::Soloist streamUrl(browse_proxy) -> undef for a non-Browse URL");

    $Plugins::SpotOn::Unified::DaemonManager::HELPER = undef;
    is($be->streamUrl($client, 'spoton://track:abc123', 'browse_proxy'), undef,
        "84-08: Backend::Soloist streamUrl(browse_proxy) -> undef without a daemon");
    is($pkg->new({ url => 'spoton://track:abc123', client => $client }), undef,
        "84-08: new() -> undef when the role has no URL (no daemon)");

    my ($newBody) = $protocol_src_84_08 =~ /(^sub new \{.*?^\})/ms;
    ok($newBody, '84-08: new() body parseable');
    is(scalar(() = ($newBody // '') =~ /->streamUrl\(\$client, \$args->\{song\}, 'browse_proxy'/g), 1,
        "84-08: new() has exactly one streamUrl(\$client, \$args->{song}, 'browse_proxy', ...) call");
    unlike($newBody // '', qr{/stream\?uri}, '84-08: new() builds no backend-specific /stream?uri URL itself');
}

# ============================================================
# 84-08 Task 2 (SEAM-6.2): ProtocolHandler knows the backends only through
# the role -- regex-over-source pins (each mutation-shown red in the 84-08
# SUMMARY) plus behaviour pins that only the role routing satisfies.
# ============================================================
{
    my $src  = $protocol_src_84_08;
    my $code = join "\n", grep { !/^\s*#/ } split /\n/, $src;
    unlike($src, qr/_useSoloist|SoloistDaemon|can\(.?_ws/, '84-08: ProtocolHandler.pm matches no criterion-1 token (comments included)');
    unlike($code, qr/Plugins::SpotOn::Soloist(?:[^A-Za-z0-9_]|$)/m, '84-08: ProtocolHandler.pm names no Soloist package outside comments');
    unlike($code, qr/for_client/, '84-08: ProtocolHandler.pm has no for_client call');
    my ($ct) = $src =~ /^(sub contentType .*)$/m;
    like($ct // '', qr/capabilitiesDefault->\{contentType\}/, '84-08: contentType reads the role class default');
    my ($os) = $src =~ /(^sub onStream \{.*?^\})/ms;
    my $osCode = join "\n", grep { !/^\s*#/ } split /\n/, ($os // '');
    is(scalar(() = $osCode =~ /->control\('track'/g), 1, "84-08: onStream routes through exactly one control('track') call");
    my ($gnt) = $src =~ /(^sub getNextTrack \{.*?^\})/ms;
    like($gnt // '', qr/->control\('track', source => 'getNextTrack'/, "84-08: getNextTrack calls control('track', source => 'getNextTrack')");
    unlike($src, qr/PREREQ_FAILURE_MESSAGES/, '84-08: the prereq message table moved out of ProtocolHandler.pm');
}

# ============================================================
# backend = 'soloist', no daemon alive -- canDirectStream falls back to 0.
# ============================================================
{
    reset_backend('soloist');
    $Plugins::SpotOn::Unified::DaemonManager::HELPER = undef;

    my $client = MockClient->new(synced => 0);
    is($pkg->canDirectStream($client, 'spoton://track:abc123'), 0,
        "canDirectStream() == 0 when no soloist daemon is alive (daemon backoff owns recovery)");
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

# --- soloist browse: resolved pcm -> direct URL, resolved flac/mp3 -> 0 ---
{
    reset_backend('soloist');
    $Plugins::SpotOn::Unified::DaemonManager::HELPER =
        Plugins::SpotOn::Unified::SoloistDaemon->new(alive => 1, port => 39755);
    my $client = MockClient->new(synced => 0);

    local $Plugins::SpotOn::Unified::DaemonManager::RESOLVED = 'pcm';
    like($pkg->canDirectStream($client, 'spoton://track:abc123'),
        qr{^http://127\.0\.0\.1:39755/stream\?uri=spotify:track:abc123&g=\d+$},
        "soloist browse: resolved 'pcm' keeps the bounded URL (D-06, Phase 78)");

    $Plugins::SpotOn::Unified::DaemonManager::RESOLVED = 'flac';
    is($pkg->canDirectStream($client, 'spoton://track:abc123'), 0,
        "soloist browse: resolved 'flac' returns 0 (LMS opens the stream and runs the soc transcode rule)");

    $Plugins::SpotOn::Unified::DaemonManager::RESOLVED = 'mp3';
    is($pkg->canDirectStream($client, 'spoton://track:abc123'), 0,
        "soloist browse: resolved 'mp3' returns 0 (forces the smp transcode pipeline)");
}

# --- soloist connect: same gating on the unified connect block ---
{
    reset_backend('soloist');
    $Plugins::SpotOn::Unified::DaemonManager::HELPER =
        Plugins::SpotOn::Unified::SoloistDaemon->new(alive => 1, port => 39755);
    my $client = MockClient->new(synced => 0);

    local $Plugins::SpotOn::Unified::DaemonManager::RESOLVED = 'pcm';
    like($pkg->canDirectStream($client, 'spoton://connect-1234567890'),
        qr{^http://127\.0\.0\.1:39755/stream$},
        "soloist connect: resolved 'pcm' keeps the direct /stream URL (D-06)");

    $Plugins::SpotOn::Unified::DaemonManager::RESOLVED = 'flac';
    is($pkg->canDirectStream($client, 'spoton://connect-1234567890'), 0,
        "soloist connect: resolved 'flac' returns 0 (forces the LMS-side transcode pipeline)");
}

# --- formatOverride: smp routing (D-07) ---
{
    my $client = MockClient->new(synced => 0);
    my $song = MockSong->new(
        master => $client,
        track  => MockTrack->new('spoton://track:abc123'),
    );

    reset_backend('soloist');
    local $Plugins::SpotOn::Unified::DaemonManager::RESOLVED = 'mp3';
    is($pkg->formatOverride($song), 'smp',
        "formatOverride: soloist resolved 'mp3' -> 'smp' (single-rule forcing type, D-07)");

    # 74b D-14: explicit FLAC (resolver answers 'flac', stored pref 'flac')
    # lands on the single-rule FLAC type 'sof'.
    $Plugins::SpotOn::Unified::DaemonManager::RESOLVED = 'flac';
    {
        local $Slim::Utils::Prefs::FAKE{streamFormat} = 'flac';
        is($pkg->formatOverride($song), 'sof',
            "formatOverride: soloist resolved 'flac' + stored streamFormat=flac -> 'sof' (explicit FLAC, D-14)");
    }

    # 74b D-22: Auto keeps today's PCM delivery through the soc pcm rule
    # (the resolver's 'flac' only decides the PATH, the type decides the
    # delivered format; Task 2 adds the AUTO_FLAC branch on top of this).
    {
        local $Slim::Utils::Prefs::FAKE{streamFormat} = 'auto';
        is($pkg->formatOverride($song), 'soc',
            "formatOverride: soloist resolved 'flac' + stored streamFormat=auto -> 'soc' (D-22: Auto delivers PCM while staged)");
    }
    {
        delete local $Slim::Utils::Prefs::FAKE{streamFormat};
        is($pkg->formatOverride($song), 'soc',
            "formatOverride: soloist resolved 'flac' + no stored streamFormat -> 'soc' (D-22)");
    }
    {
        local $Slim::Utils::Prefs::FAKE{streamFormat} = 'ogg';
        is($pkg->formatOverride($song), 'soc',
            "formatOverride: soloist resolved 'flac' + stored streamFormat=ogg -> 'soc' (ogg behaves as auto under Soloist, D-22)");
    }

    # 74b D-16/D-22: the staging answer only changes the type of Auto's
    # already-proxied stream. AUTO_FLAC 1 (after the 74b-06 flip) -> 'sof'.
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Unified::DaemonManager::autoFlacEnabled = sub { 1 };
        local $Slim::Utils::Prefs::FAKE{streamFormat} = 'auto';
        is($pkg->formatOverride($song), 'sof',
            "formatOverride: soloist resolved 'flac' + stored auto + AUTO_FLAC 1 -> 'sof' (D-16 after the flip)");
        delete local $Slim::Utils::Prefs::FAKE{streamFormat};
        is($pkg->formatOverride($song), 'sof',
            "formatOverride: soloist resolved 'flac' + no stored streamFormat + AUTO_FLAC 1 -> 'sof'");
    }
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Unified::DaemonManager::autoFlacEnabled = sub { 0 };
        local $Slim::Utils::Prefs::FAKE{streamFormat} = 'flac';
        is($pkg->formatOverride($song), 'sof',
            "formatOverride: soloist resolved 'flac' + stored flac + AUTO_FLAC 0 -> 'sof' (explicit FLAC before the flip)");
    }

    $Plugins::SpotOn::Unified::DaemonManager::RESOLVED = 'pcm';
    is($pkg->formatOverride($song), 'soc',
        "formatOverride: soloist resolved 'pcm' -> 'soc'");
    {
        no warnings 'redefine';
        local *Plugins::SpotOn::Unified::DaemonManager::autoFlacEnabled = sub { 1 };
        is($pkg->formatOverride($song), 'soc',
            "formatOverride: soloist resolved 'pcm' + AUTO_FLAC 1 -> 'soc' (a PCM answer is never promoted)");
    }

    # A resolver downgrade is never overridden by a pref re-read: the
    # resolver answered 'pcm' (e.g. D-15 degrade), the stored pref still
    # says flac, the type stays 'soc'.
    {
        local $Slim::Utils::Prefs::FAKE{streamFormat} = 'flac';
        is($pkg->formatOverride($song), 'soc',
            "formatOverride: soloist resolved 'pcm' + stored streamFormat=flac -> 'soc' (a downgrade is never undone by the pref, RESEARCH Pitfall 3)");
    }

    # (84-09: the librespot formatOverride cells of this block live in
    # t/librespot/29_soloist_browse_librespot.t)
}

# ============================================================
# D-07 (Phase 78) / Phase 82 (D-01 Folge D): getFormatForURL for the
# bounded /stream?uri=...&g=<gen> URL form (name is contract, task 2
# acceptance criteria).
# ============================================================
{
    is($pkg->getFormatForURL('http://127.0.0.1:39755/stream?uri=spotify:track:abc123&g=3'), 'pcm',
        "getFormatForURL: /stream?uri=...&g=<gen> URL still maps to pcm");
}

# ============================================================
# Phase 82 (D-04, Befund 1): canDirectStreamSong no longer rewrites the
# URL for a seekdata offset -- the &start= mechanism never reached the
# daemon (Befund 1: LMS's seek-restart bypasses getNextTrack entirely).
# Seek/rewind now reach Control via onStream's marker consumption
# (t/44_soloist_control.t), not via the URL. g=<gen> still counts up on
# every canDirectStream call -- that is the ONLY thing that changes
# between two builds of the same URL.
# ============================================================
{
    reset_backend('soloist');
    $Plugins::SpotOn::Unified::DaemonManager::HELPER =
        Plugins::SpotOn::Unified::SoloistDaemon->new(alive => 1, port => 39755);
    local $Plugins::SpotOn::Soloist::Control::CTL = Test::FakeControl->new;

    my $client = MockClient->new(synced => 0);
    my $track  = MockTrack->new('spoton://track:abc123');
    my $song   = MockSong->new(master => $client, track => $track);
    $song->seekdata({ timeOffset => 42 });

    my $directUrl = $pkg->canDirectStream($client, 'spoton://track:abc123');
    like($directUrl, qr{^http://127\.0\.0\.1:39755/stream\?uri=spotify:track:abc123&g=\d+$},
        "canDirectStream: bounded URL, no start= regardless of seekdata");

    # canDirectStreamSong no longer touches the URL for the bounded form
    # (no /(?:track|episode)/ path segment to match, and the &start=
    # rewrite is gone) -- it re-derives the SAME shape from canDirectStream
    # (which itself counts up g= on every call, so the value differs from
    # $directUrl above -- that is expected, not a rewrite).
    my $seekUrl = $pkg->canDirectStreamSong($client, $song);
    like($seekUrl, qr{^http://127\.0\.0\.1:39755/stream\?uri=spotify:track:abc123&g=\d+$},
        "canDirectStreamSong: no rewrite for the bounded form -- still the plain &g=<gen> shape, no &start=");
    ok(!defined $song->startOffset,
        "canDirectStreamSong: song->startOffset NOT set for the bounded form (no URL-carried offset any more)");

    # Two consecutive canDirectStream calls for the same track produce
    # DIFFERENT g= values (nextStreamGeneration counts up every dispatch,
    # D-01 Folge D) -- the only source of per-call URL uniqueness now.
    my $secondUrl = $pkg->canDirectStream($client, 'spoton://track:abc123');
    isnt($directUrl, $secondUrl,
        "canDirectStream: two consecutive calls produce different g= (stream generation counts up)");
}

# ============================================================
# Phase 82 Plan 01 Task 2: getNextTrack now delegates entirely to
# Plugins::SpotOn::Soloist::Control->for_client($client)->requestTrack(...)
# -- ProtocolHandler.pm sends no WS command itself and reads no SoloistWS
# state any more (T-1, T-3). The Test::FakeControl recorder above stands
# in for Control's own state machine (pinned separately in
# t/44_soloist_control.t); the arm-ordering/degrade-open/send-failure
# tests that used to live here moved to t/44 with Control (they test
# Control's internals now, not ProtocolHandler's delegation).
# ============================================================

# (1) getNextTrack(spoton://track:abc123) calls requestTrack exactly once
# with the raw spoton:// url, position_ms 0 (no seekdata), and
# source => 'getNextTrack'; successCb runs through.
{
    reset_backend('soloist');
    @Test::FakeControl::CALLS = ();
    $Plugins::SpotOn::Soloist::Control::CTL = Test::FakeControl->new(auto => 'ok');
    local $Plugins::SpotOn::Connect::_IS_CONNECT = 0;

    my $client = MockClient->new(synced => 0);
    my $track  = MockTrack->new('spoton://track:abc123');
    my $song   = MockSong->new(master => $client, track => $track);

    my ($success_called, $error_called);
    $pkg->getNextTrack($song, sub { $success_called = 1 }, sub { $error_called = 1 });

    is(scalar(@Test::FakeControl::CALLS), 1,
        "getNextTrack: requestTrack called exactly once");
    is($Test::FakeControl::CALLS[0][0], 'spoton://track:abc123',
        "getNextTrack: requestTrack called with the raw spoton:// url");
    is($Test::FakeControl::CALLS[0][1], 0,
        "getNextTrack: requestTrack position_ms defaults to 0 (no seekdata)");
    is($Test::FakeControl::CALLS[0][2]{source}, 'getNextTrack',
        "getNextTrack: requestTrack opts carry source => 'getNextTrack'");
    ok($success_called, "getNextTrack: successCb runs through Control's requestTrack");
    ok(!$error_called, "getNextTrack: errorCb not called");
}

# --- 79-33 D-28 F3: LMS gets a once-only callback pair for every getNextTrack,
# whatever order or number of fires Control produces (79-R3-FORENSICS.md Part B:
# a double fire reaches LMS's _nextTrackError and skips the title) ---
for my $case (
    [ both      => 1, 0, 'success then error: the success callback runs once, the error callback never' ],
    [ both_rev  => 0, 1, 'error then success: the error callback runs once, the success callback never' ],
    [ twice_ok  => 1, 0, 'success twice: the success callback runs once' ],
    [ twice_err => 0, 1, 'error twice: the error callback runs once' ],
) {
    my ($mode, $wantOk, $wantErr, $name) = @$case;
    reset_backend('soloist');
    @Test::FakeControl::CALLS = ();
    $Plugins::SpotOn::Soloist::Control::CTL = Test::FakeControl->new(auto => $mode);
    local $Plugins::SpotOn::Connect::_IS_CONNECT = 0;

    my $client = MockClient->new(synced => 0);
    my $track  = MockTrack->new('spoton://track:abc123');
    my $song   = MockSong->new(master => $client, track => $track);

    my ($ok, $err) = (0, 0);
    $pkg->getNextTrack($song, sub { $ok++ }, sub { $err++ });

    is_deeply([ $ok, $err ], [ $wantOk, $wantErr ], "79-33 D-28: getNextTrack callbacks: $name");
}

# (2) seekdata {timeOffset => 5} -> position_ms 5000 in the call.
{
    reset_backend('soloist');
    @Test::FakeControl::CALLS = ();
    $Plugins::SpotOn::Soloist::Control::CTL = Test::FakeControl->new(auto => 'ok');
    local $Plugins::SpotOn::Connect::_IS_CONNECT = 0;

    my $client = MockClient->new(synced => 0);
    my $track  = MockTrack->new('spoton://track:abc123');
    my $song   = MockSong->new(master => $client, track => $track);
    $song->seekdata({ timeOffset => 5 });

    my $success_called;
    $pkg->getNextTrack($song, sub { $success_called = 1 }, sub { });

    is($Test::FakeControl::CALLS[0][1], 5000,
        "getNextTrack: seekdata timeOffset => 5 becomes position_ms 5000");
    ok($success_called, "getNextTrack: successCb runs through Control's requestTrack (with seekdata)");
}

# 84.2-05 P1..P4: getNextTrack derives `origin` from Connect.pm's one-shot
# dispatch marker (client pluginData connectOwnPlayUri): 'connect' only when
# the marker names the requested url, 'lms' otherwise; the marker is consumed
# by every getNextTrack whatever its url. Seekdata is no signal (plan-check
# round 3: an LMS-UI seek re-streams through onStream) -- no seekReopen key.
{
    my $run = sub {
        my (%o) = @_;
        reset_backend('soloist');
        @Test::FakeControl::CALLS = ();
        $Plugins::SpotOn::Soloist::Control::CTL = Test::FakeControl->new(auto => 'ok');
        local $Plugins::SpotOn::Connect::_IS_CONNECT = 0;
        my $client = MockClient->new(synced => 0);
        $client->pluginData(connectOwnPlayUri => $o{marker}) if defined $o{marker};
        my $song = MockSong->new(master => $client, track => MockTrack->new('spoton://track:abc123'));
        $song->seekdata($o{seekdata}) if $o{seekdata};
        $pkg->getNextTrack($song, sub { }, sub { });
        return $client;
    };

    # P1: no marker, no seekdata -> lms
    $run->();
    is($Test::FakeControl::CALLS[0][2]{origin}, 'lms', "84.2-05 P1: no dispatch marker -> origin 'lms'");

    # P2: marker for the requested url -> connect, consumed
    my $c2 = $run->(marker => 'spoton://track:abc123');
    is($Test::FakeControl::CALLS[0][2]{origin}, 'connect', "84.2-05 P2: the marker names the requested url -> origin 'connect'");
    is($c2->pluginData('connectOwnPlayUri'), '', "84.2-05 P2: the marker is consumed (one-shot)");

    # P3: marker for another url -> lms, consumed too
    my $c3 = $run->(marker => 'spoton://track:otherXYZ');
    is($Test::FakeControl::CALLS[0][2]{origin}, 'lms', "84.2-05 P3: a marker for another url -> origin 'lms'");
    is($c3->pluginData('connectOwnPlayUri'), '', "84.2-05 P3: a stale marker for another title is consumed too");

    # P4: seekdata and no marker -> lms, no seekReopen key
    $run->(seekdata => { timeOffset => 5 });
    is($Test::FakeControl::CALLS[0][2]{origin}, 'lms', "84.2-05 P4: seekdata without a marker -> origin 'lms'");
    ok(!exists $Test::FakeControl::CALLS[0][2]{seekReopen}, "84.2-05 P4: no seekReopen key (seekdata is no signal)");
    is($Test::FakeControl::CALLS[0][1], 5000, "84.2-05 P4: position_ms 5000 as pin (2)");
}

# (3) Control->for_client returns undef -- three explicit Faelle (260914-qn1
# Signature C split): no daemon at all (Fall c, unchanged terminal reject),
# helper exists but is the librespot daemon not SoloistDaemon (Fall c-2,
# NEW -- exercises the isa() branch), and a SoloistDaemon exists but Control
# does not yet (Fall a-integration, NEW -- the deferral gate itself). Each
# sets $HELPER on purpose instead of relying on whatever an earlier block
# left behind (an earlier block leaves $HELPER pointing at an alive
# SoloistDaemon -- verified, reset_backend() never touches it).

# Fall c (no daemon at all, prereqs NOT ready -- D-09/D-10/D-11, Runde 44):
# precise now, not just "unchanged terminal reject" -- $PREREQ_STATE is set
# to a concrete non-ready state BEFORE the call, and D-11 requires the
# error text to name it. Must-fail proof: a revert to the generic message
# makes ONLY the NEW $error_text assertion red -- the pre-existing
# $error_type assertion stays green on EITHER message text and therefore
# does NOT prove D-11 (exactly this file's established "Fall c beweist
# nicht Task X" pattern).
{
    reset_backend('soloist');
    @Test::FakeControl::CALLS = ();
    $Plugins::SpotOn::Soloist::Control::CTL = undef;
    $Plugins::SpotOn::Unified::DaemonManager::HELPER = undef;
    $Plugins::SpotOn::Unified::DaemonManager::PREREQ_STATE = 'soloist_missing_key';
    @Plugins::SpotOn::Unified::SoloistDaemon::DEFER_CALLS = ();
    @Plugins::SpotOn::Unified::DaemonManager::PENDING_QUEUE_CALLS = ();
    local $Plugins::SpotOn::Connect::_IS_CONNECT = 0;

    my $client = MockClient->new(synced => 0);
    my $track  = MockTrack->new('spoton://track:abc123');
    my $song   = MockSong->new(master => $client, track => $track);

    my ($success_called, $error_called, $error_type, $error_text);
    $pkg->getNextTrack($song, sub { $success_called = 1 }, sub { $error_called = 1; $error_type = $_[0]; $error_text = $_[1]; });

    is(scalar(@Test::FakeControl::CALLS), 0, "Fall c: no requestTrack call when Control->for_client returns undef");
    ok(!$success_called, "Fall c: successCb not called without a Control instance");
    ok($error_called, "Fall c: errorCb called without a Control instance");
    is($error_type, 'PROBLEM_OPENING', "Fall c: error type is PROBLEM_OPENING when Soloist daemon not ready");
    is($error_text, 'Soloist not authorized (missing key)', "Fall c: D-11 names the known reason");
    is(scalar(@Plugins::SpotOn::Unified::SoloistDaemon::DEFER_CALLS), 0, "Fall c: no deferTrackRequest call -- no daemon to defer on");
    is(scalar(@Plugins::SpotOn::Unified::DaemonManager::PENDING_QUEUE_CALLS), 0, "Fall c: no deferTrackRequestForClient call -- prereqs not ready");

    $Plugins::SpotOn::Unified::DaemonManager::PREREQ_STATE = 'soloist_ready';    # restore default for later Faelle
}

# Fall e (NEW, D-09/D-10, Runde 44): no daemon at all, but prereqs ARE
# ready ($PREREQ_STATE = 'soloist_ready' default) -- this is the actual
# Signatur-C-Runde-44 fix: defer on the new DaemonManager package-level
# anchor instead of failing fast, exactly the (a)/(b) gap Messrunde 5
# identified. Must-fail proof: reverting to the old unconditional
# errorCb-on-no-helper path leaves @PENDING_QUEUE_CALLS empty and
# $error_called true.
{
    reset_backend('soloist');
    @Test::FakeControl::CALLS = ();
    $Plugins::SpotOn::Soloist::Control::CTL = undef;
    $Plugins::SpotOn::Unified::DaemonManager::HELPER = undef;
    @Plugins::SpotOn::Unified::SoloistDaemon::DEFER_CALLS = ();
    @Plugins::SpotOn::Unified::DaemonManager::PENDING_QUEUE_CALLS = ();
    local $Plugins::SpotOn::Connect::_IS_CONNECT = 0;

    my $client = MockClient->new(synced => 0);
    my $track  = MockTrack->new('spoton://track:abc123');
    my $song   = MockSong->new(master => $client, track => $track);

    my ($success_called, $error_called, $error_type);
    $pkg->getNextTrack($song, sub { $success_called = 1 }, sub { $error_called = 1; $error_type = $_[0]; });

    is(scalar(@Test::FakeControl::CALLS), 0, "Fall e: no requestTrack call -- deferred on DaemonManager instead");
    ok(!$error_called, "Fall e: errorCb NOT called -- deferred, not resolved");
    ok(!$success_called, "Fall e: successCb NOT called -- deferred, not resolved");
    is(scalar(@Plugins::SpotOn::Unified::SoloistDaemon::DEFER_CALLS), 0, "Fall e: no instance-level deferTrackRequest call -- no daemon object exists");
    is(scalar(@Plugins::SpotOn::Unified::DaemonManager::PENDING_QUEUE_CALLS), 1, "Fall e: exactly one deferTrackRequestForClient call on the new package-level anchor");
    is($Plugins::SpotOn::Unified::DaemonManager::PENDING_QUEUE_CALLS[0][1], 'spoton://track:abc123', "Fall e: deferred call carries the original uri");
}

# Fall c-2 (NEW: helper exists but is the librespot Unified::Daemon, not
# SoloistDaemon -- covers the isa() branch, which Fall c's $HELPER=undef
# never exercises). Must-fail proof: dropping the isa('...SoloistDaemon')
# check (testing only if($helper)) makes this Fall incorrectly call
# deferTrackRequest on the librespot helper instead of falling through to
# the terminal reject -- @DEFER_CALLS gains an entry and errorCb stops
# firing, both assertions below go red.
{
    reset_backend('soloist');
    @Test::FakeControl::CALLS = ();
    $Plugins::SpotOn::Soloist::Control::CTL = undef;
    $Plugins::SpotOn::Unified::DaemonManager::HELPER = bless {}, 'Plugins::SpotOn::Unified::Daemon';
    # Phase 82 Plan 44: this Fall's whole point is the isa() type check
    # (wrong-type helper -> Case 1 does not match), independent of prereq
    # readiness -- pin a non-ready state explicitly so it reaches the
    # fail-fast path regardless of what an earlier/later Fall left
    # $PREREQ_STATE at (Fall e above deliberately leaves it 'soloist_ready').
    $Plugins::SpotOn::Unified::DaemonManager::PREREQ_STATE = 'soloist_missing_binary';
    @Plugins::SpotOn::Unified::SoloistDaemon::DEFER_CALLS = ();
    @Plugins::SpotOn::Unified::DaemonManager::PENDING_QUEUE_CALLS = ();
    local $Plugins::SpotOn::Connect::_IS_CONNECT = 0;

    my $client = MockClient->new(synced => 0);
    my $track  = MockTrack->new('spoton://track:abc123');
    my $song   = MockSong->new(master => $client, track => $track);

    my ($success_called, $error_called, $error_type);
    $pkg->getNextTrack($song, sub { $success_called = 1 }, sub { $error_called = 1; $error_type = $_[0]; });

    is(scalar(@Test::FakeControl::CALLS), 0, "Fall c-2: no requestTrack call when helper is the librespot daemon");
    ok(!$success_called, "Fall c-2: successCb not called (librespot helper, not SoloistDaemon)");
    ok($error_called, "Fall c-2: errorCb called (librespot helper, not SoloistDaemon)");
    is($error_type, 'PROBLEM_OPENING', "Fall c-2: error type is PROBLEM_OPENING (librespot helper, not SoloistDaemon)");
    is(scalar(@Plugins::SpotOn::Unified::SoloistDaemon::DEFER_CALLS), 0, "Fall c-2: no deferTrackRequest call -- helper isn't a SoloistDaemon");
    is(scalar(@Plugins::SpotOn::Unified::DaemonManager::PENDING_QUEUE_CALLS), 0, "Fall c-2: no deferTrackRequestForClient call -- prereqs pinned not-ready");

    $Plugins::SpotOn::Unified::DaemonManager::PREREQ_STATE = 'soloist_ready';    # restore default for later Faelle
}

# Fall a-integration (NEW: daemon exists, Control does not yet -- the
# Signature-C deferral gate itself). Must-fail proof: reverting Task 1's
# ProtocolHandler.pm change makes errorCb fire immediately instead (this
# Fall goes red on the "errorCb NOT called" assertion).
{
    reset_backend('soloist');
    @Test::FakeControl::CALLS = ();
    $Plugins::SpotOn::Soloist::Control::CTL = undef;
    $Plugins::SpotOn::Unified::DaemonManager::HELPER =
        Plugins::SpotOn::Unified::SoloistDaemon->new(alive => 1, port => 22222);
    @Plugins::SpotOn::Unified::SoloistDaemon::DEFER_CALLS = ();
    local $Plugins::SpotOn::Connect::_IS_CONNECT = 0;

    my $client = MockClient->new(synced => 0);
    my $track  = MockTrack->new('spoton://track:abc123');
    my $song   = MockSong->new(master => $client, track => $track);

    my ($success_called, $error_called, $error_type);
    $pkg->getNextTrack($song, sub { $success_called = 1 }, sub { $error_called = 1; $error_type = $_[0]; });

    is(scalar(@Test::FakeControl::CALLS), 0, "Fall a-integration: no requestTrack call -- deferred on the daemon instead");
    ok(!$error_called, "Fall a-integration: errorCb NOT called -- deferred, not resolved");
    ok(!$success_called, "Fall a-integration: successCb NOT called -- deferred, not resolved");
    is(scalar(@Plugins::SpotOn::Unified::SoloistDaemon::DEFER_CALLS), 1, "Fall a-integration: exactly one deferTrackRequest call");
    is($Plugins::SpotOn::Unified::SoloistDaemon::DEFER_CALLS[0][0], 'spoton://track:abc123', "Fall a-integration: deferred call carries the original uri");
    is($Plugins::SpotOn::Unified::SoloistDaemon::DEFER_CALLS[0][1], 0, "Fall a-integration: deferred call carries position_ms 0 (no seekdata)");
    is(ref($Plugins::SpotOn::Unified::SoloistDaemon::DEFER_CALLS[0][2]{errorCb}), 'CODE', "Fall a-integration: deferred opts carries a CODE errorCb");
}

# (4) Control's requestTrack reports an error -> error_called, success_called false.
{
    reset_backend('soloist');
    @Test::FakeControl::CALLS = ();
    $Plugins::SpotOn::Soloist::Control::CTL = Test::FakeControl->new(auto => 'error');
    local $Plugins::SpotOn::Connect::_IS_CONNECT = 0;

    my $client = MockClient->new(synced => 0);
    my $track  = MockTrack->new('spoton://track:abc123');
    my $song   = MockSong->new(master => $client, track => $track);

    my ($success_called, $error_called, $error_type);
    $pkg->getNextTrack($song, sub { $success_called = 1 }, sub { $error_called = 1; $error_type = $_[0]; });

    ok(!$success_called, "getNextTrack: successCb not called when Control's requestTrack reports an error");
    ok($error_called, "getNextTrack: errorCb called when Control's requestTrack reports an error");
    is($error_type, 'PROBLEM_OPENING',
        "getNextTrack: error type propagated from Control's errorCb");
}

# ============================================================
# Phase 82 Plan 04 (D-04, Befund 1/3): canDoAction/getSeekData are marker
# carriers ONLY -- they never send, onStream is the only consumer. The
# 82-01 t/29 tests 1/2 (seek via getNextTrack) had no real LMS input
# (Befund 1 -- getNextTrack is never on the seek/rewind path) and are
# replaced below with tests against the actual LMS entry points.
# ============================================================

# --- canDoAction('rew'): seekable -> noteSeekIntent(url,0) recorded,
# returns 1 ---
{
    reset_backend('soloist');
    local $Plugins::SpotOn::Connect::_IS_CONNECT = 0;
    $Plugins::SpotOn::Soloist::Control::CTL = Test::FakeControl->new(seekable => 1);

    my $client = MockClient->new(synced => 0);
    my $result = $pkg->canDoAction($client, 'spoton://track:abc123', 'rew');

    is($result, 1, "canDoAction('rew'): seekable -> returns 1");
    is_deeply($Plugins::SpotOn::Soloist::Control::CTL->{recorded},
        [ [ 'noteSeekIntent', 'spoton://track:abc123', 0 ] ],
        "canDoAction('rew'): seekable -> noteSeekIntent(url,0) recorded");
}

# --- canDoAction('rew'): not seekable -> returns 0, no marker ---
{
    reset_backend('soloist');
    local $Plugins::SpotOn::Connect::_IS_CONNECT = 0;
    $Plugins::SpotOn::Soloist::Control::CTL = Test::FakeControl->new(seekable => 0);

    my $client = MockClient->new(synced => 0);
    my $result = $pkg->canDoAction($client, 'spoton://track:abc123', 'rew');

    is($result, 0, "canDoAction('rew'): not seekable -> returns 0");
    is_deeply($Plugins::SpotOn::Soloist::Control::CTL->{recorded}, [],
        "canDoAction('rew'): not seekable -> no marker recorded");
}

# --- canDoAction('rew'): Connect -> 0 unchanged ---
{
    reset_backend('soloist');
    local $Plugins::SpotOn::Connect::_IS_CONNECT = 1;
    $Plugins::SpotOn::Soloist::Control::CTL = Test::FakeControl->new(seekable => 1);

    my $client = MockClient->new(synced => 0);
    my $result = $pkg->canDoAction($client, 'spoton://connect-1234567890', 'rew');

    is($result, 0, "canDoAction('rew'): Connect -> 0 unchanged (GH #129, unaffected by 82-04)");
    is_deeply($Plugins::SpotOn::Soloist::Control::CTL->{recorded}, [],
        "canDoAction('rew'): Connect -> no marker recorded (short-circuits before the Soloist branch)");
}

# --- Debug session connect-skip-prev-ton-bleibt (2026-09-24), decision 1B
# (DEVIATION from D-B2 for `jump +0`): in connect, canDoAction('rew') still
# blocks every LMS-side restart-at-0 (`time 0`, `jump -1`, LMS' own first
# `jump +0` call) -- EXCEPT the one restart Control::requestRestart asked
# for itself: its one-shot allowance for exactly this url lets the restart
# through and notes the rewind marker 0 (onStream -> armed `seek 0`). ---
{
    reset_backend('soloist');
    local $Plugins::SpotOn::Connect::_IS_CONNECT = 1;
    my $ctl = Test::FakeControl->new(seekable => 1);
    $ctl->{restart_allowance} = 'spoton://track:abc123';
    $Plugins::SpotOn::Soloist::Control::CTL = $ctl;

    my $client = MockClient->new(synced => 0);
    my $result = $pkg->canDoAction($client, 'spoton://track:abc123', 'rew');

    is($result, 1, "1B: canDoAction('rew') in connect WITH Control's restart allowance -> 1 (LMS restarts the stream)");
    is_deeply($ctl->{recorded}, [ [ 'noteSeekIntent', 'spoton://track:abc123', 0 ] ],
        "1B: canDoAction('rew') in connect with allowance -> rewind marker 0 noted (onStream arms seek 0)");
    ok(!exists $ctl->{restart_allowance}, "1B: the allowance is consumed (one-shot)");

    my $again = $pkg->canDoAction($client, 'spoton://track:abc123', 'rew');
    is($again, 0, "1B: a second canDoAction('rew') right after -> 0 again (allowance was one-shot)");
}

# --- 1B: an allowance for a DIFFERENT url does not open this restart. ---
{
    reset_backend('soloist');
    local $Plugins::SpotOn::Connect::_IS_CONNECT = 1;
    my $ctl = Test::FakeControl->new(seekable => 1);
    $ctl->{restart_allowance} = 'spoton://track:otherTrack1';
    $Plugins::SpotOn::Soloist::Control::CTL = $ctl;

    my $result = $pkg->canDoAction(MockClient->new(synced => 0), 'spoton://track:abc123', 'rew');

    is($result, 0, "1B: canDoAction('rew') in connect with an allowance for another url -> 0");
    is_deeply($ctl->{recorded}, [], "1B: allowance for another url -> no marker");
}

# --- 1B: allowance matches but the title is not seekable -> fail closed. ---
{
    reset_backend('soloist');
    local $Plugins::SpotOn::Connect::_IS_CONNECT = 1;
    my $ctl = Test::FakeControl->new(seekable => 0);
    $ctl->{restart_allowance} = 'spoton://track:abc123';
    $Plugins::SpotOn::Soloist::Control::CTL = $ctl;

    my $result = $pkg->canDoAction(MockClient->new(synced => 0), 'spoton://track:abc123', 'rew');

    is($result, 0, "1B: canDoAction('rew') in connect with allowance but not seekable -> 0");
    is_deeply($ctl->{recorded}, [], "1B: not seekable -> no marker");
}

# --- 1B: other actions in connect stay allowed and never touch the
# allowance. ---
{
    reset_backend('soloist');
    local $Plugins::SpotOn::Connect::_IS_CONNECT = 1;
    my $ctl = Test::FakeControl->new(seekable => 1);
    $Plugins::SpotOn::Soloist::Control::CTL = $ctl;

    is($pkg->canDoAction(MockClient->new(synced => 0), 'spoton://track:abc123', 'pause'), 1,
        "1B: canDoAction('pause') in connect -> 1 (unchanged)");
    ok(!$ctl->{consumed}, "1B: canDoAction('pause') never consults the restart allowance");
}

# --- getSeekData(30): noteSeekIntent(url,30000) + {timeOffset=>30} ---
{
    reset_backend('soloist');
    local $Plugins::SpotOn::Connect::_IS_CONNECT = 0;
    $Plugins::SpotOn::Soloist::Control::CTL = Test::FakeControl->new(seekable => 1);

    my $client = MockClient->new(synced => 0);
    my $track  = MockTrack->new('spoton://track:abc123');
    my $song   = MockSong->new(master => $client, track => $track);

    my $result = $pkg->getSeekData($client, $song, 30);

    is_deeply($result, { timeOffset => 30 }, "getSeekData(30): returns {timeOffset=>30}");
    is_deeply($Plugins::SpotOn::Soloist::Control::CTL->{recorded},
        [ [ 'noteSeekIntent', 'spoton://track:abc123', 30000 ] ],
        "getSeekData(30): noteSeekIntent(url,30000) recorded");
}

# --- 79-28 D-23: Soloist connect keeps the restart chain (connectSeekViaControl 0) ---
{
    reset_backend('soloist');
    local $Plugins::SpotOn::Connect::_IS_CONNECT = 1;
    $Plugins::SpotOn::Soloist::Control::CTL = Test::FakeControl->new(seekable => 1);

    my $client = MockClient->new(synced => 0);
    my $song   = MockSong->new(master => $client, track => MockTrack->new('spoton://track:abc123'));
    is_deeply($pkg->getSeekData($client, $song, 30), { timeOffset => 30 },
        '79-28 D-23 seek: Soloist connect getSeekData -> {timeOffset => 30} (restart chain, D-B1)');
}

# --- getSeekData: not seekable -> undef ---
{
    reset_backend('soloist');
    local $Plugins::SpotOn::Connect::_IS_CONNECT = 0;
    $Plugins::SpotOn::Soloist::Control::CTL = Test::FakeControl->new(seekable => 0);

    my $client = MockClient->new(synced => 0);
    my $track  = MockTrack->new('spoton://track:abc123');
    my $song   = MockSong->new(master => $client, track => $track);

    is($pkg->getSeekData($client, $song, 30), undef, "getSeekData: not seekable -> undef");
}

# ============================================================
# onStream (Phase 82 Plan 04, D-04/D-05): the only consumer of both
# markers. LMS calls it once per player, per stream start, right before
# $player->play (StreamingController.pm:1311).
# ============================================================

# --- onStream: seekdata 5 -> requestTrack(url, 5000, {source=>'onStream', seek=>1}) ---
{
    reset_backend('soloist');
    @Test::FakeControl::CALLS = ();
    $Plugins::SpotOn::Soloist::Control::CTL = Test::FakeControl->new;

    my $client = MockClient->new(id => 'aa:bb:cc:dd:ee:ff', synced => 0);
    my $track  = MockTrack->new('spoton://track:abc123');
    my $song   = MockSong->new(master => $client, track => $track);
    $song->seekdata({ timeOffset => 5 });

    $pkg->onStream($client, $song);

    is(scalar(@Test::FakeControl::CALLS), 1, "onStream: seekdata 5 -- requestTrack called exactly once");
    is($Test::FakeControl::CALLS[0][0], 'spoton://track:abc123', "onStream: seekdata 5 -- called with the raw url");
    is($Test::FakeControl::CALLS[0][1], 5000, "onStream: seekdata 5 -- position_ms 5000");
    is($Test::FakeControl::CALLS[0][2]{source}, 'onStream', "onStream: seekdata 5 -- source => 'onStream'");
    is($Test::FakeControl::CALLS[0][2]{seek}, 1, "onStream: seekdata 5 -- seek => 1");
}

# --- onStream: marker 0 -> requestTrack(url, 0, seek=>1) ---
{
    reset_backend('soloist');
    @Test::FakeControl::CALLS = ();
    $Plugins::SpotOn::Soloist::Control::CTL = Test::FakeControl->new;
    $Plugins::SpotOn::Soloist::Control::CTL->noteSeekIntent('spoton://track:abc123', 0);

    my $client = MockClient->new(id => 'aa:bb:cc:dd:ee:ff', synced => 0);
    my $track  = MockTrack->new('spoton://track:abc123');
    my $song   = MockSong->new(master => $client, track => $track);

    $pkg->onStream($client, $song);

    is($Test::FakeControl::CALLS[0][1], 0, "onStream: marker 0 -- position_ms 0");
    is($Test::FakeControl::CALLS[0][2]{seek}, 1, "onStream: marker 0 -- seek => 1 (consumed marker, not the idempotent default)");
}

# --- onStream: no marker -> requestTrack(url, 0, seek=>0) (idempotent twin) ---
{
    reset_backend('soloist');
    @Test::FakeControl::CALLS = ();
    $Plugins::SpotOn::Soloist::Control::CTL = Test::FakeControl->new;

    my $client = MockClient->new(id => 'aa:bb:cc:dd:ee:ff', synced => 0);
    my $track  = MockTrack->new('spoton://track:abc123');
    my $song   = MockSong->new(master => $client, track => $track);

    $pkg->onStream($client, $song);

    is($Test::FakeControl::CALLS[0][1], 0, "onStream: no marker -- position_ms 0");
    is($Test::FakeControl::CALLS[0][2]{seek}, 0, "onStream: no marker -- seek => 0 (idempotent twin of getNextTrack)");
}

# ============================================================
# 82-REVIEW.md IN-01 (82-10, Task 2): a seek-intent marker must never
# survive an onStream call, on EITHER branch -- the seekdata branch has
# precedence and used to leave a same-uri marker armed for up to
# SEEK_INTENT_TTL (2s), so a second onStream for the same uri within that
# window (a _Continue reconnect) would seek again. Same target either way
# -- harmless, but a rule violation (a marker that survives its ONE
# consumer).
# ============================================================

# --- IN-01 Fall A: the seekdata branch (which never itself reads the
# marker) still clears a marker left over for the SAME uri ---
{
    reset_backend('soloist');
    @Test::FakeControl::CALLS = ();
    my $ctl = Test::FakeControl->new;
    $Plugins::SpotOn::Soloist::Control::CTL = $ctl;
    $ctl->noteSeekIntent('spoton://track:abc123', 0);

    my $client = MockClient->new(id => 'aa:bb:cc:dd:ee:ff', synced => 0);
    my $track  = MockTrack->new('spoton://track:abc123');
    my $song   = MockSong->new(master => $client, track => $track);
    $song->seekdata({ timeOffset => 5 });

    $pkg->onStream($client, $song);

    is($ctl->consumeSeekIntent('spoton://track:abc123'), undef,
        "IN-01: Fall A -- seekdata branch still clears a same-uri marker left over from noteSeekIntent");
}

# --- IN-01 Fall B: the marker branch already consumes the marker itself
# (Befund 1/3) -- the unconditional call at the end of onStream is then a
# no-op, and requestTrack still saw the marker's own position/seek=>1 ---
{
    reset_backend('soloist');
    @Test::FakeControl::CALLS = ();
    my $ctl = Test::FakeControl->new;
    $Plugins::SpotOn::Soloist::Control::CTL = $ctl;
    $ctl->noteSeekIntent('spoton://track:abc123', 3000);

    my $client = MockClient->new(id => 'aa:bb:cc:dd:ee:ff', synced => 0);
    my $track  = MockTrack->new('spoton://track:abc123');
    my $song   = MockSong->new(master => $client, track => $track);

    $pkg->onStream($client, $song);

    is($Test::FakeControl::CALLS[0][1], 3000, "IN-01: Fall B -- marker branch unaffected, position_ms 3000");
    is($Test::FakeControl::CALLS[0][2]{seek}, 1, "IN-01: Fall B -- marker branch unaffected, seek => 1");
    is($ctl->consumeSeekIntent('spoton://track:abc123'), undef,
        "IN-01: Fall B -- consumeSeekIntent after onStream is undef (already consumed; the unconditional call is a no-op)");
}

# --- IN-01 Fall C: no marker, no seekdata -- the unconditional call is a
# no-op that must not throw ---
{
    reset_backend('soloist');
    @Test::FakeControl::CALLS = ();
    my $ctl = Test::FakeControl->new;
    $Plugins::SpotOn::Soloist::Control::CTL = $ctl;

    my $client = MockClient->new(id => 'aa:bb:cc:dd:ee:ff', synced => 0);
    my $track  = MockTrack->new('spoton://track:abc123');
    my $song   = MockSong->new(master => $client, track => $track);

    eval { $pkg->onStream($client, $song); };
    is($@, '', "IN-01: Fall C -- no marker, no seekdata -- unconditional consumeSeekIntent call does not throw");
    is($Test::FakeControl::CALLS[0][1], 0, "IN-01: Fall C -- position_ms still 0 (idempotent twin of getNextTrack)");
}

# --- onStream: sync member (player id ne master id) -> no call ---
{
    reset_backend('soloist');
    @Test::FakeControl::CALLS = ();
    $Plugins::SpotOn::Soloist::Control::CTL = Test::FakeControl->new;

    my $master = MockClient->new(id => 'aa:bb:cc:dd:ee:ff', synced => 0);
    my $member = MockClient->new(id => 'bb:cc:dd:ee:ff:aa', synced => 0);
    my $track  = MockTrack->new('spoton://track:abc123');
    my $song   = MockSong->new(master => $master, track => $track);

    $pkg->onStream($member, $song);

    is(scalar(@Test::FakeControl::CALLS), 0, "onStream: sync member (player id ne master id) -> no call");
}

# --- onStream: non-spoton url -> no call ---
{
    reset_backend('soloist');
    @Test::FakeControl::CALLS = ();
    $Plugins::SpotOn::Soloist::Control::CTL = Test::FakeControl->new;

    my $client = MockClient->new(id => 'aa:bb:cc:dd:ee:ff', synced => 0);
    my $track  = MockTrack->new('http://example.com/some-other-stream');
    my $song   = MockSong->new(master => $client, track => $track);

    $pkg->onStream($client, $song);

    is(scalar(@Test::FakeControl::CALLS), 0, "onStream: non-spoton url -> no call");
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

# --- connect: seek 150 -> startOffset 150 ---
{
    reset_backend('soloist');
    local $Plugins::SpotOn::Connect::_IS_CONNECT = 1;
    @Test::FakeControl::CALLS = ();
    $Plugins::SpotOn::Soloist::Control::CTL = Test::FakeControl->new(mode => 'connect');

    my $client = MockClient->new(id => '02:00:00:5a:11:01', synced => 0);
    my $song   = new_song_w($client, 'spoton://track:abc123');
    $song->seekdata({ timeOffset => 150 });

    $pkg->onStream($client, $song);

    is($song->startOffset, 150,
        "zeit-ab-null: connect seek 150 -- onStream sets startOffset 150 (LMS clock starts at the target)");
    is_deeply($song->writes, [ 150 ],
        "zeit-ab-null: connect seek 150 -- exactly one startOffset write, value 150");
    is($Test::FakeControl::CALLS[0][1], 150000, "zeit-ab-null: connect seek 150 -- requestTrack still gets 150000 ms");
    is($Test::FakeControl::CALLS[0][2]{seek}, 1, "zeit-ab-null: connect seek 150 -- requestTrack still seek => 1");
}

# --- connect: seek 120.5 (Step 2 run E, 500 ms off the frozen position) ->
# startOffset 120.5, fractional target kept ---
{
    reset_backend('soloist');
    local $Plugins::SpotOn::Connect::_IS_CONNECT = 1;
    @Test::FakeControl::CALLS = ();
    $Plugins::SpotOn::Soloist::Control::CTL = Test::FakeControl->new(mode => 'connect');

    my $client = MockClient->new(id => '02:00:00:5a:11:01', synced => 0);
    my $song   = new_song_w($client, 'spoton://track:abc123');
    $song->seekdata({ timeOffset => 120.5 });

    $pkg->onStream($client, $song);

    is($song->startOffset, 120.5, "zeit-ab-null: connect seek 120.5 -- startOffset 120.5 (fraction kept)");
    is($Test::FakeControl::CALLS[0][1], 120500, "zeit-ab-null: connect seek 120.5 -- requestTrack 120500 ms");
}

# --- browse: seek 100 (live-fix run11, SF-5) -> startOffset 100 ---
{
    reset_backend('soloist');
    local $Plugins::SpotOn::Connect::_IS_CONNECT = 0;
    @Test::FakeControl::CALLS = ();
    $Plugins::SpotOn::Soloist::Control::CTL = Test::FakeControl->new(mode => 'browse');

    my $client = MockClient->new(id => '02:00:00:5a:11:01', synced => 0);
    my $song   = new_song_w($client, 'spoton://track:abc123');
    $song->seekdata({ timeOffset => 100 });

    $pkg->onStream($client, $song);

    is($song->startOffset, 100,
        "zeit-ab-null: browse seek 100 -- onStream sets startOffset 100 (LMS clock starts at the target)");
    is_deeply($song->writes, [ 100 ], "zeit-ab-null: browse seek 100 -- exactly one startOffset write, value 100");
}

# --- browse: episode url, seek 42 -> startOffset 42 (same regex branch) ---
{
    reset_backend('soloist');
    local $Plugins::SpotOn::Connect::_IS_CONNECT = 0;
    @Test::FakeControl::CALLS = ();
    $Plugins::SpotOn::Soloist::Control::CTL = Test::FakeControl->new(mode => 'browse');

    my $client = MockClient->new(id => '02:00:00:5a:11:01', synced => 0);
    my $song   = new_song_w($client, 'spoton://episode:ep42');
    $song->seekdata({ timeOffset => 42 });

    $pkg->onStream($client, $song);

    is($song->startOffset, 42, "zeit-ab-null: browse episode seek 42 -- startOffset 42");
}

# --- no seek (normal title start, transfer-in's `playlist play`, the
# getNextTrack per-title cycle): no seekdata, no marker -> startOffset NOT
# written, in both modes (the transfer-in position is Connect.pm's
# mid-song-connect startOffset on newsong, which runs AFTER onStream) ---
for my $mode (qw(connect browse)) {
    reset_backend('soloist');
    local $Plugins::SpotOn::Connect::_IS_CONNECT = ($mode eq 'connect') ? 1 : 0;
    @Test::FakeControl::CALLS = ();
    $Plugins::SpotOn::Soloist::Control::CTL = Test::FakeControl->new(mode => $mode);

    my $client = MockClient->new(id => '02:00:00:5a:11:01', synced => 0);
    my $song   = new_song_w($client, 'spoton://track:abc123');

    $pkg->onStream($client, $song);

    is_deeply($song->writes, [], "zeit-ab-null: $mode, no seek -- onStream does not write startOffset");
    is($song->startOffset, 0, "zeit-ab-null: $mode, no seek -- startOffset stays at Song::open's 0");
    is($Test::FakeControl::CALLS[0][2]{seek}, 0, "zeit-ab-null: $mode, no seek -- requestTrack seek => 0 (unchanged)");
}

# --- rewind (canDoAction('rew') marker 0, no seekdata): not written --
# Song::open's 0 already is the rewind target ---
{
    reset_backend('soloist');
    local $Plugins::SpotOn::Connect::_IS_CONNECT = 0;
    @Test::FakeControl::CALLS = ();
    my $ctl = Test::FakeControl->new(mode => 'browse');
    $Plugins::SpotOn::Soloist::Control::CTL = $ctl;
    $ctl->noteSeekIntent('spoton://track:abc123', 0);

    my $client = MockClient->new(id => '02:00:00:5a:11:01', synced => 0);
    my $song   = new_song_w($client, 'spoton://track:abc123');

    $pkg->onStream($client, $song);

    is_deeply($song->writes, [], "zeit-ab-null: rewind marker 0 -- onStream does not write startOffset");
    is($song->startOffset, 0, "zeit-ab-null: rewind marker 0 -- startOffset stays 0");
}

# --- sync member: onStream returns before anything -- no write from the
# member's call (the master's own call sets the shared song's clock) ---
{
    reset_backend('soloist');
    @Test::FakeControl::CALLS = ();
    $Plugins::SpotOn::Soloist::Control::CTL = Test::FakeControl->new(mode => 'browse');

    my $master = MockClient->new(id => 'aa:bb:cc:dd:ee:ff', synced => 0);
    my $member = MockClient->new(id => 'bb:cc:dd:ee:ff:aa', synced => 0);
    my $song   = new_song_w($master, 'spoton://track:abc123');
    $song->seekdata({ timeOffset => 100 });

    $pkg->onStream($member, $song);
    is_deeply($song->writes, [], "zeit-ab-null: sync member call -- no startOffset write");

    $pkg->onStream($master, $song);
    is_deeply($song->writes, [ 100 ], "zeit-ab-null: then the master's call -- one write, value 100");
}

# --- no Control for the player: no seek is dispatched to a daemon, so the
# clock is not moved either (clock set iff the seek goes out) ---
{
    reset_backend('soloist');
    @Test::FakeControl::CALLS = ();
    $Plugins::SpotOn::Soloist::Control::CTL = undef;

    my $client = MockClient->new(id => '02:00:00:5a:11:01', synced => 0);
    my $song   = new_song_w($client, 'spoton://track:abc123');
    $song->seekdata({ timeOffset => 100 });

    $pkg->onStream($client, $song);
    is_deeply($song->writes, [], "zeit-ab-null: no Control -- no requestTrack, no startOffset write");
}

# --- getNextTrack passes duration ---
{
    reset_backend('soloist');
    @Test::FakeControl::CALLS = ();
    $Plugins::SpotOn::Soloist::Control::CTL = Test::FakeControl->new(auto => 'ok');
    local $Plugins::SpotOn::Connect::_IS_CONNECT = 0;

    my $client = MockClient->new(synced => 0);
    my $track  = MockTrack->new('spoton://track:abc123');
    my $song   = MockSong->new(master => $client, track => $track);
    $song->duration(217);

    $pkg->getNextTrack($song, sub { }, sub { });

    is($Test::FakeControl::CALLS[0][2]{duration}, 217, "getNextTrack passes duration -- opts carry the song's known duration");
}

# --- _asyncRefetch: negative cache set on 404 and short-circuits the next call ---
{
    reset_backend('soloist');
    $Plugins::SpotOn::Soloist::Control::CTL = Test::FakeControl->new;
    $Plugins::SpotOn::API::SpClient::FETCH_CALLS  = 0;
    $Plugins::SpotOn::API::SpClient::FETCH_RESULT = undef;    # definitive-404 fixture -- both metadata sources exhausted
    $Plugins::SpotOn::API::SpClient::FETCH_ERROR  = { error => 'not_found', code => 404 };

    my $client = MockClient->new(synced => 0);
    my $negKey = 'spoton_meta_neg_' . md5_hex('spoton://track:notfound000');
    $pkg->_asyncRefetch($client, 'spoton://track:notfound000', 'spoton://track:notfound000');

    is($Plugins::SpotOn::API::SpClient::FETCH_CALLS, 1, "_asyncRefetch: first call fetches");
    ok($Slim::Utils::Cache::STORE{$negKey},
        "_asyncRefetch: negative cache set on 404");
    is($Slim::Utils::Cache::STORE_TTL{$negKey}, 60,
        "_asyncRefetch: definitive negative-cache TTL is 60s (Fable-5 CR-01/WR-01)");
    is_deeply($Plugins::SpotOn::Soloist::Control::CTL->{recorded},
        [ [ 'noteMetadataMissing', 'spoton://track:notfound000' ] ],
        "_asyncRefetch: negative cache path -- noteMetadataMissing recorded");

    $pkg->_asyncRefetch($client, 'spoton://track:notfound000', 'spoton://track:notfound000');
    is($Plugins::SpotOn::API::SpClient::FETCH_CALLS, 1,
        "_asyncRefetch: second call short-circuits on the negative cache -- no second fetch");
}

# --- _asyncRefetch: transient connect-timeout must not permanently disable seek
# (upw-260910), but Fable-5 CR-01 requires EVERY failure -- including this
# transient one -- to still keep a per-url bound on the refetch cadence via a
# SHORT-TTL negative cache entry, not the unbounded-until-TTL-expiry gap the
# original quick-260910-upw fix left open. ---
{
    reset_backend('soloist');
    $Plugins::SpotOn::Soloist::Control::CTL = Test::FakeControl->new;
    $Plugins::SpotOn::API::SpClient::FETCH_CALLS  = 0;
    $Plugins::SpotOn::API::SpClient::FETCH_RESULT = undef;
    $Plugins::SpotOn::API::SpClient::FETCH_ERROR  = { error => 'Connect timed out', code => 0 };

    my $client = MockClient->new(synced => 0);
    my $negKey = 'spoton_meta_neg_' . md5_hex('spoton://track:transient000');
    $pkg->_asyncRefetch($client, 'spoton://track:transient000', 'spoton://track:transient000');

    is($Plugins::SpotOn::API::SpClient::FETCH_CALLS, 1, "connect-timeout: first call fetches");
    ok($Slim::Utils::Cache::STORE{$negKey}, "connect-timeout: transient failure STILL sets a bounded negative cache (CR-01)");
    ok(defined($Slim::Utils::Cache::STORE_TTL{$negKey}) && $Slim::Utils::Cache::STORE_TTL{$negKey} < 60,
        "connect-timeout: transient negative-cache TTL is the SHORT bound, not the 60s definitive bound");
    is_deeply($Plugins::SpotOn::Soloist::Control::CTL->{recorded}, [], "connect-timeout: transient failure must NOT call noteMetadataMissing");

    # The stub has no real time-based expiry -- simulate TTL expiry by
    # deleting the key directly, then confirm the next call actually
    # refetches instead of being short-circuited forever.
    delete $Slim::Utils::Cache::STORE{$negKey};
    delete $Slim::Utils::Cache::STORE_TTL{$negKey};

    $pkg->_asyncRefetch($client, 'spoton://track:transient000', 'spoton://track:transient000');
    is($Plugins::SpotOn::API::SpClient::FETCH_CALLS, 2,
        "connect-timeout: after TTL expiry, second call retries -- no permanent block from a transient error");
}

# --- _asyncRefetch: Fable-5 WR-01 -- {error=>'invalid_id'} with NO code key is
# structurally permanent (idToHex's local base62 check fails before any HTTP
# call), so it must classify DEFINITIVE, not transient (old classifier read
# the missing code as 0, indistinguishable from a connect timeout). ---
{
    reset_backend('soloist');
    $Plugins::SpotOn::Soloist::Control::CTL = Test::FakeControl->new;
    $Plugins::SpotOn::API::SpClient::FETCH_CALLS  = 0;
    $Plugins::SpotOn::API::SpClient::FETCH_RESULT = undef;
    $Plugins::SpotOn::API::SpClient::FETCH_ERROR  = { error => 'invalid_id' };    # no code key at all

    my $client = MockClient->new(synced => 0);
    my $negKey = 'spoton_meta_neg_' . md5_hex('spoton://track:invalidid000');
    $pkg->_asyncRefetch($client, 'spoton://track:invalidid000', 'spoton://track:invalidid000');

    is($Plugins::SpotOn::API::SpClient::FETCH_CALLS, 1, "invalid_id: first call fetches");
    ok($Slim::Utils::Cache::STORE{$negKey}, "invalid_id: negative cache set (definitive, WR-01)");
    is($Slim::Utils::Cache::STORE_TTL{$negKey}, 60, "invalid_id: definitive negative-cache TTL is 60s");
    is_deeply($Plugins::SpotOn::Soloist::Control::CTL->{recorded}, [],
        "85-07 D-11 invalid_id: NO noteMetadataMissing -- only a real HTTP 404 fails seek closed (60s bound kept)");
}

# --- _asyncRefetch: Fable-5 WR-01 -- code => 400 (Web API's "invalid id"
# answer) is also structurally permanent and must classify DEFINITIVE. ---
{
    reset_backend('soloist');
    $Plugins::SpotOn::Soloist::Control::CTL = Test::FakeControl->new;
    $Plugins::SpotOn::API::SpClient::FETCH_CALLS  = 0;
    $Plugins::SpotOn::API::SpClient::FETCH_RESULT = undef;
    $Plugins::SpotOn::API::SpClient::FETCH_ERROR  = { error => 'invalid id', code => 400 };

    my $client = MockClient->new(synced => 0);
    my $negKey = 'spoton_meta_neg_' . md5_hex('spoton://track:invalidcode400000');
    $pkg->_asyncRefetch($client, 'spoton://track:invalidcode400000', 'spoton://track:invalidcode400000');

    is($Plugins::SpotOn::API::SpClient::FETCH_CALLS, 1, "code400: first call fetches");
    ok($Slim::Utils::Cache::STORE{$negKey}, "code400: negative cache set (definitive, WR-01)");
    is($Slim::Utils::Cache::STORE_TTL{$negKey}, 60, "code400: definitive negative-cache TTL is 60s");
    is_deeply($Plugins::SpotOn::Soloist::Control::CTL->{recorded}, [],
        "85-07 D-11 code400: NO noteMetadataMissing -- only a real HTTP 404 fails seek closed (60s bound kept)");
}

# --- _asyncRefetch: Fable-5 CR-01 -- code => 503 is transient (real 5xx, not
# a permanent id-shape problem): bounded short-TTL negative cache, but NO
# noteMetadataMissing -- seek must not be fail-closed for a server hiccup. ---
{
    reset_backend('soloist');
    $Plugins::SpotOn::Soloist::Control::CTL = Test::FakeControl->new;
    $Plugins::SpotOn::API::SpClient::FETCH_CALLS  = 0;
    $Plugins::SpotOn::API::SpClient::FETCH_RESULT = undef;
    $Plugins::SpotOn::API::SpClient::FETCH_ERROR  = { error => 'Service Unavailable', code => 503 };

    my $client = MockClient->new(synced => 0);
    my $negKey = 'spoton_meta_neg_' . md5_hex('spoton://track:serviceunavail000');
    $pkg->_asyncRefetch($client, 'spoton://track:serviceunavail000', 'spoton://track:serviceunavail000');

    is($Plugins::SpotOn::API::SpClient::FETCH_CALLS, 1, "503: first call fetches");
    ok($Slim::Utils::Cache::STORE{$negKey}, "503: transient failure still sets a bounded negative cache (CR-01)");
    ok(defined($Slim::Utils::Cache::STORE_TTL{$negKey}) && $Slim::Utils::Cache::STORE_TTL{$negKey} < 60,
        "503: transient negative-cache TTL is the SHORT bound, not 60s");
    is_deeply($Plugins::SpotOn::Soloist::Control::CTL->{recorded}, [], "503: transient failure must NOT call noteMetadataMissing");
}

# ============================================================
# CR-05 regression (82-25, 82-REVIEW.md): the browse-proxy stream URL must
# NOT depend on Slim::Utils::Network::serverAddr() -- LMS itself is the
# HTTP client on all three proxy paths ((b2)/(b3)/(b) in ProtocolHandler.pm
# new()), and the soloist daemon always runs locally, binding INADDR_ANY
# (fake-libpulse.c:1298). serverAddr() caches a host IP ONCE per LMS
# process (Slim::Utils::IPDetect.pm) and never re-detects it after a
# network change -- a stale IP made every browse-play hang for the full
# 15s RemoteStream timeout (82-13 live incident, todo
# browse-proxy-url-hostip-nicht-neu-ermittelt-nach-netzwechsel.md).
#
# Every case below stubs serverAddr() to a DIFFERENT address (10.0.0.1)
# and asserts the resulting proxy URL still uses 127.0.0.1 regardless.
# RED (pre-fix, quoted verbatim in 82-25-SUMMARY.md): the URL contained
# 10.0.0.1. GREEN (post-fix): 127.0.0.1, unconditionally.
# ============================================================

# --- Fall 1 -- (b3) soloist-browse-proxy: reuses the already-established
# backend=soloist / unsynced-client setup pattern (same shape as the
# existing D-03 test above); only the serverAddr stub and the URL-source
# assertion are new. ---
{
    reset_backend('soloist');
    $Plugins::SpotOn::Unified::DaemonManager::HELPER =
        Plugins::SpotOn::Unified::SoloistDaemon->new(alive => 1, port => 39755);
    my $client = MockClient->new(synced => 0);

    local *Slim::Utils::Network::serverAddr = sub { '10.0.0.1' };
    my $streamObj = $pkg->new({ url => 'spoton://track:abc123', client => $client });
    ok(defined $streamObj, "CR-05 (b3): new() is defined even with serverAddr() stubbed to a different address");
    like($streamObj->{url}, qr{^http://127\.0\.0\.1:39755/stream\?uri=spotify:track:abc123&g=\d+$},
        "CR-05 (b3): soloist-browse proxy URL is hardcoded to 127.0.0.1, ignoring serverAddr()=10.0.0.1");
    unlike($streamObj->{url}, qr{10\.0\.0\.1},
        "CR-05 (b3): stubbed 10.0.0.1 does not leak into the soloist-browse proxy URL");
}

# --- Fall 3 -- (b) connect-sync-proxy (W6-Korrektur: ebenfalls NEUE
# Testaufrufstelle -- no existing $pkg->new() call in this file uses a
# spoton://connect-* URL). Guard is only `$url =~ m{spoton://connect-}`,
# independent of backend/_useSoloist -- reachable via any backend value,
# as long as canDirectStream would have returned 0 for it (e.g. a synced
# client). Positioned at the already-established $_IS_CONNECT stub
# (t/29:584 area). ---
{
    reset_backend('soloist');
    $Plugins::SpotOn::Unified::DaemonManager::HELPER =
        Plugins::SpotOn::Unified::SoloistDaemon->new(alive => 1, port => 39755);
    local $Plugins::SpotOn::Connect::_IS_CONNECT = 1;
    my $client = MockClient->new(synced => 1);

    local *Slim::Utils::Network::serverAddr = sub { '10.0.0.1' };
    my $streamObj = $pkg->new({ url => 'spoton://connect-1234567890', client => $client });
    ok(defined $streamObj, "CR-05 (b): new() is defined even with serverAddr() stubbed to a different address");
    like($streamObj->{url}, qr{^http://127\.0\.0\.1:39755/stream$},
        "CR-05 (b): connect sync-group proxy URL is hardcoded to 127.0.0.1, ignoring serverAddr()=10.0.0.1");
    unlike($streamObj->{url}, qr{10\.0\.0\.1},
        "CR-05 (b): stubbed 10.0.0.1 does not leak into the connect sync-group proxy URL");
}

done_testing();

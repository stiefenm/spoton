package Plugins::SpotOn::Soloist::Quality;

# Phase 83.3 Plan 02 (D-12/D-13/D-14/D-15): Spotify streaming-quality setting
# for the Soloist backend. Reads/writes the per-device server-side quality
# via spclient's undocumented playback-settings service, authenticated with
# SpotOn's own login5 bearer token (same idiom as SpClient.pm) -- NOT the
# server-to-client push (that direction is never sent from here, see the
# module header note below).
#
# D-12: the app can change this server-side value at any time. SpotOn only
# writes (a) when the LMS setting is actually changed and (b) once, on a
# player's very first Soloist daemon start (the onDaemonReady hook) -- never
# on any later start, so this module never fights the app. D-13: the
# first-start default is Automatic (level 0). D-14: a write is verified with
# a one-second read-back; a "rejected" answer (grpc-status != 0, an HTTP
# error code, or a read-back that differs from what was written) resets the
# supplying pref to the effective value and shows a notice; an "unreachable"
# answer (no HTTP status at all, or a login5 mint failure) keeps the pref
# and retries on the next occasion. D-15: the settings page states a change
# takes effect from the next track (not applied by this module -- Perl
# module logic only).
#
# Deliberately self-contained: no coupling to any other SpotOn playback
# control module -- Phase 84 relocates this file behind a backend
# abstraction by a plain move, no rewiring. Two-callback async only, same
# discipline as SpClient.pm's _doRequest.

use strict;
use warnings;

use File::Spec::Functions qw(catfile);
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Player::Client;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Time::HiRes;

# ------------------------------------------------------------
# Constants
# ------------------------------------------------------------
use constant PLAYBACK_SETTINGS_URL =>
    'https://spclient.wg.spotify.com/playback-settings/spotify.playbacksettings.PlaybackSettingsService/';
use constant REQUEST_TIMEOUT      => 15;
use constant READBACK_DELAY_S     => 1;
use constant EFFECTIVE_TTL        => 300;
use constant FIELD_AUDIO_QUALITY  => 1;    # the settings-message field id identifying the AUDIO_QUALITY setting
use constant LEVEL_LOSSLESS       => 5;    # write 5 for Lossless -- never 6 (binary clamps 6->5 anyway)
use constant SUPPORTED_LEVELS     => (0, 2, 3, 4, 5);    # offered in Settings: Low(1) is never surfaced

# D-14 classification (review CR-01): a status carried in these sets is a
# TRANSIENT transport/auth condition -- "unreachable" (keep the pref, retry
# on the next occasion), never "rejected" (which resets the pref). Everything
# else in the semantic-refusal range (4xx HTTP not listed here; any grpc
# status not listed here) is a genuine "the server does not hold this value"
# answer.
my %TRANSIENT_HTTP = map { $_ => 1 } (401, 408, 429);
my %TRANSIENT_GRPC = map { $_ => 1 } (1, 4, 8, 13, 14, 16);    # CANCELLED, DEADLINE_EXCEEDED, RESOURCE_EXHAUSTED, INTERNAL, UNAVAILABLE, UNAUTHENTICATED

# Level -> i18n key (0..6; 1 and 6 are storable via a D-14 reset/app choice
# but never offered as a select option -- see SUPPORTED_LEVELS above).
my %LEVEL_STRING = (
    0 => 'PLUGIN_SPOTON_SOLOIST_QUALITY_AUTOMATIC',
    1 => 'PLUGIN_SPOTON_SOLOIST_QUALITY_LOW',
    2 => 'PLUGIN_SPOTON_SOLOIST_QUALITY_NORMAL',
    3 => 'PLUGIN_SPOTON_SOLOIST_QUALITY_HIGH',
    4 => 'PLUGIN_SPOTON_SOLOIST_QUALITY_VERY_HIGH',
    5 => 'PLUGIN_SPOTON_SOLOIST_QUALITY_LOSSLESS',
    6 => 'PLUGIN_SPOTON_SOLOIST_QUALITY_LOSSLESS_24',
);

my $log   = logger('plugin.spoton');
my $prefs = preferences('plugin.spoton');
# M5: cache version lives in Plugin.pm (single source of truth). Plugin.pm is
# always compiled first in production (this module is runtime-require'd).
my $cache = Slim::Utils::Cache->new('spoton', Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION());

# ============================================================
# Pure helpers
# ============================================================

# levels($class) -> arrayref of { value => N, string => 'PLUGIN_SPOTON_...' }
# for the levels this setting offers in the UI (SUPPORTED_LEVELS).
sub levels {
    my ($class) = @_;
    return [ map { { value => $_, string => $LEVEL_STRING{$_} } } (SUPPORTED_LEVELS) ];
}

# isValidLevel($class, $v) -> true only for a level this setting may WRITE.
sub isValidLevel {
    my ($class, $v) = @_;
    return 0 unless defined $v;
    return $v =~ /^(?:0|2|3|4|5)$/ ? 1 : 0;
}

# isStorableLevel($class, $v) -> true for anything a D-14 reset (or an
# app-side choice observed via read-back) may legitimately leave in a pref
# -- includes 1 (Low) and 6 (Lossless 24-bit) even though this module never
# WRITES either.
sub isStorableLevel {
    my ($class, $v) = @_;
    return 0 unless defined $v;
    return $v =~ /^[0-6]$/ ? 1 : 0;
}

# labelFor($class, $level) -> the i18n KEY for a level (never the rendered
# text -- this module has no Slim::Utils::Strings dependency by design;
# callers render via string($key)).
sub labelFor {
    my ($class, $level) = @_;
    return '' unless defined $level && exists $LEVEL_STRING{$level};
    return $LEVEL_STRING{$level};
}

# effectiveLevelForClient($class, $client) -> the level this module would
# currently write for $client: the client's own storable override first,
# else the storable global default, else 0 (Automatic, D-13).
sub effectiveLevelForClient {
    my ($class, $client) = @_;
    return 0 unless $client;

    my $clientStored = $prefs->client($client)->get('soloistQuality');
    if (defined $clientStored && $clientStored ne 'global' && $class->isStorableLevel($clientStored)) {
        return $clientStored;
    }

    my $globalStored = $prefs->get('soloistQuality');
    if (defined $globalStored && $class->isStorableLevel($globalStored)) {
        return $globalStored;
    }

    return 0;
}

# deviceIdForMac($class, $mac) -> the 36-char UUID this player's Soloist
# daemon wrote to its data dir (byte-identical to the app's own dealer id),
# or undef when the daemon has never started (no request is possible yet).
sub deviceIdForMac {
    my ($class, $mac) = @_;
    return undef unless $mac;

    require Plugins::SpotOn::Soloist;
    my $path = catfile(Plugins::SpotOn::Soloist::dataDirForClient($mac), '.device_id');
    return undef unless -f $path;

    open(my $fh, '<', $path) or return undef;
    my $id = <$fh>;
    close($fh);
    return undef unless defined $id;
    chomp $id;
    return undef unless $id =~ /^[0-9a-f]{8}-[0-9a-f-]{27}$/i;
    return $id;
}

# deviceNameForMac($class, $mac) -> the same display name DaemonManager
# gives this player's daemon (undef when the player is not currently known).
sub deviceNameForMac {
    my ($class, $mac) = @_;
    my $client = Slim::Player::Client::getClient($mac) or return undef;
    require Plugins::SpotOn::Unified::DaemonManager;
    return Plugins::SpotOn::Unified::DaemonManager->deviceNameForClient($client);
}

# ------------------------------------------------------------
# Wire encoders/decoder (live-verified 2026-09-25, spike 012a probe.pl) --
# pure, no network/side effects.
# ------------------------------------------------------------

sub _encodeRead {
    my ($class, $id, $name) = @_;
    require Plugins::SpotOn::API::ProtobufLite;
    my $descriptor = Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $id)
                    . Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, $name);
    return Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2,
        Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $descriptor));
}

sub _encodeWrite {
    my ($class, $id, $name, $level) = @_;
    require Plugins::SpotOn::API::ProtobufLite;
    my $descriptor = Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $id)
                    . Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, $name);
    my $valueMsg   = Plugins::SpotOn::API::ProtobufLite::encode_field(1, 0, FIELD_AUDIO_QUALITY)
                    . Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2,
                        Plugins::SpotOn::API::ProtobufLite::encode_field(3, 0, $level));
    return Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $descriptor)
         . Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, $valueMsg);
}

sub _decodeLevel {
    my ($class, $content) = @_;
    require Plugins::SpotOn::API::ProtobufLite;

    my $top = Plugins::SpotOn::API::ProtobufLite::parse_fields($content);
    return undef unless $top;

    my $settingsMsg = Plugins::SpotOn::API::ProtobufLite::field_first($top, 2);
    return undef unless defined $settingsMsg;

    my $inner = Plugins::SpotOn::API::ProtobufLite::parse_fields($settingsMsg);
    return undef unless $inner;

    # WINDOWS #30 (W30): proto3 omits a scalar field on the wire when it
    # equals its type's default (here 0, Automatic) -- a settings message
    # that IS present but carries no field 1 is level 0, not a parse error.
    # The three undef guards above stay: no top-level parse, no settings
    # message at all (field 2 absent), and an unparseable settings message
    # remain parse errors -- only "settings message present, field 1 absent"
    # becomes 0.
    my $level = Plugins::SpotOn::API::ProtobufLite::field_first($inner, 1);
    return defined $level ? $level : 0;
}

# _classifyHttpError($class, $code) -- pure, no I/O. D-14 split (review
# CR-01): a defined HTTP status in the semantic 4xx range (400 <= code < 500)
# that is NOT one of %TRANSIENT_HTTP is a genuine refusal ('rejected'); a 5xx,
# a transient 4xx (401/408/429), or the absence of any status code at all is
# a transport/auth condition ('unreachable').
sub _classifyHttpError {
    my ($class, $code) = @_;
    if (defined $code && $code >= 400 && $code < 500 && !$TRANSIENT_HTTP{$code}) {
        return 'rejected';
    }
    return 'unreachable';
}

# _classifyGrpcStatus($class, $status) -- pure, no I/O. A grpc status in
# %TRANSIENT_GRPC (CANCELLED/DEADLINE_EXCEEDED/RESOURCE_EXHAUSTED/INTERNAL/
# UNAVAILABLE/UNAUTHENTICATED) is a transport/auth condition ('unreachable');
# every other non-zero status (e.g. INVALID_ARGUMENT/PERMISSION_DENIED/
# FAILED_PRECONDITION) is a genuine refusal ('rejected').
sub _classifyGrpcStatus {
    my ($class, $status) = @_;
    return $TRANSIENT_GRPC{$status} ? 'unreachable' : 'rejected';
}

# ============================================================
# Network primitive
# ============================================================

# _request($class, $method, $body, $cb) -- mints a login5 token for the
# active account, POSTs $body to spclient's PlaybackSettingsService/$method,
# and normalizes the outcome to exactly one of: $cb->($content) on a clean
# HTTP 200/grpc-status 0 answer, or $cb->(undef, { class => ... }) with class
# one of no_token | rejected | unreachable. 'rejected' means the server
# answered with a semantic refusal (D-14: reset the pref to the read-back
# value); 'unreachable' means a transient transport/auth condition -- no HTTP
# status, a 5xx/401/408/429, or a transient grpc status (D-14: keep the pref,
# retry). A login5 throttle (getToken detail throttled => 1 or code 429: the
# HTTP 429 and the protobuf TIMEOUT/TOO_MANY_ATTEMPTS/TRY_AGAIN_LATER answers,
# live or damped replay) is 'unreachable' too, because a throttle is transient
# and the user's authorization is fine (quick-261018-ife, WR-18); every other
# token failure stays 'no_token'. Never logs the token, headers, or body -- method name + outcome
# class only (T-02-10 idiom).
sub _request {
    my ($class, $method, $body, $cb) = @_;

    require Plugins::SpotOn::API::Login5;
    my $accountId = $prefs->get('activeAccount') || '';
    my $called    = 0;

    Plugins::SpotOn::API::Login5->getToken($accountId, sub {
        my ($token, $reason, $detail) = @_;

        unless ($token) {
            return if $called++;
            if ($detail && ref $detail eq 'HASH' && ($detail->{throttled} || ($detail->{code} // 0) == 429)) {
                main::INFOLOG && $log->info("Soloist::Quality: $method class=unreachable (login5 throttle)");
                $cb->(undef, { class => 'unreachable', http => ($detail->{code} // undef), source => 'login5', reason => $reason });
                return;
            }
            main::INFOLOG && $log->info("Soloist::Quality: $method class=no_token");
            $cb->(undef, { class => 'no_token', reason => $reason });
            return;
        }

        my $url = PLAYBACK_SETTINGS_URL . $method;

        my $http = Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $httpResp = shift;
                return if $called++;

                # G-83.3-1b: $httpResp IS the SimpleAsyncHTTP instance itself
                # (onBody:134 `$self->cb->( $self )`), not a wrapper carrying
                # a ->response accessor -- the gRPC trailers live on its own
                # ->headers (an HTTP::Headers, filled at onBody:113-115).
                my $headers     = $httpResp->headers;
                my $grpcStatus  = $headers ? $headers->header('grpc-status') : undef;
                my $grpcMessage = $headers ? $headers->header('grpc-message') : undef;
                my $grpcValid   = defined($grpcStatus) && $grpcStatus =~ /^\d+$/;

                if ($grpcValid && $grpcStatus != 0) {
                    my $grpcClass = $class->_classifyGrpcStatus($grpcStatus);
                    main::INFOLOG && $log->info("Soloist::Quality: $method class=$grpcClass (grpc $grpcStatus)");
                    $cb->(undef, {
                        class => $grpcClass,
                        grpc => $grpcStatus,
                        message => $grpcMessage,
                    });
                    return;
                }

                $cb->($httpResp->content // '');
            },
            sub {
                my ($httpResp, $error, $response) = @_;
                return if $called++;

                my $code = ($response && ref $response && $response->can('code'))
                    ? ($response->code || 0) : 0;
                if (!$code && $error && $error =~ /^(\d{3})\b/) {
                    $code = $1;
                }

                my $httpClass = $class->_classifyHttpError($code || undef);
                main::INFOLOG && $log->info("Soloist::Quality: $method class=$httpClass (http " . ($code || 'none') . ")");
                $cb->(undef, { class => $httpClass, http => ($code || undef), error => $error });
            },
            { timeout => REQUEST_TIMEOUT },
        );

        $http->post(
            $url,
            'Authorization'   => "Bearer $token",
            'Content-Type'    => 'application/x-protobuf',
            'Accept'          => 'application/x-protobuf',
            'Accept-Encoding' => 'identity',
            $body,
        );
    });
}

# ============================================================
# Read / write
# ============================================================

# read($class, $mac, $cb) -> $cb->($level, undef) or $cb->(undef, $err)
sub read {
    my ($class, $mac, $cb) = @_;

    my $id = $class->deviceIdForMac($mac);
    unless ($id) {
        $cb->(undef, { class => 'no_device_id' });
        return;
    }
    my $name = $class->deviceNameForMac($mac) || $mac;

    $class->_request('GetDeviceSettings', $class->_encodeRead($id, $name), sub {
        my ($content, $err) = @_;
        if ($err) {
            $cb->(undef, $err);
            return;
        }
        my $level = $class->_decodeLevel($content);
        unless (defined $level) {
            $cb->(undef, { class => 'parse_error' });
            return;
        }
        $cb->($level, undef);
    });
}

# write($class, $mac, $level, $cb) -> $cb->(1) or $cb->(undef, $err)
sub write {
    my ($class, $mac, $level, $cb) = @_;

    my $id = $class->deviceIdForMac($mac);
    unless ($id) {
        $cb->(undef, { class => 'no_device_id' });
        return;
    }
    my $name = $class->deviceNameForMac($mac) || $mac;

    $class->_request('WriteDeviceValue', $class->_encodeWrite($id, $name, $level), sub {
        my (undef, $err) = @_;
        if ($err) {
            $cb->(undef, $err);
            return;
        }
        $cb->(1);
    });
}

# ============================================================
# D-14 outcome handling (private)
# ============================================================

sub _storeEffectiveCache {
    my ($class, $mac, $level) = @_;
    (my $macClean = $mac || '') =~ s/://g;
    $cache->set("spoton_soloist_quality_effective_$macClean", { level => $level, checked_at => time() }, EFFECTIVE_TTL);
}

sub _setNotice {
    my ($class, $mac, $notice) = @_;
    (my $macClean = $mac || '') =~ s/://g;
    $cache->set("spoton_soloist_quality_notice_$macClean", $notice, 'never');
}

# clearNotice($class, $mac) -- cleared by the next successful verified write.
sub clearNotice {
    my ($class, $mac) = @_;
    (my $macClean = $mac || '') =~ s/://g;
    $cache->remove("spoton_soloist_quality_notice_$macClean");
}

sub noticeFor {
    my ($class, $mac) = @_;
    (my $macClean = $mac || '') =~ s/://g;
    return $cache->get("spoton_soloist_quality_notice_$macClean");
}

sub effectiveCached {
    my ($class, $mac) = @_;
    (my $macClean = $mac || '') =~ s/://g;
    return $cache->get("spoton_soloist_quality_effective_$macClean");
}

# refreshEffective($class, $mac) -- fire-and-forget async read into the
# effective cache (Settings.pm's first async-populated-param pattern).
sub refreshEffective {
    my ($class, $mac) = @_;
    $class->read($mac, sub {
        my ($level) = @_;
        $class->_storeEffectiveCache($mac, $level) if defined $level;
    });
}

sub _setScopePref {
    my ($class, $scope, $level) = @_;
    return unless $scope && ref $scope eq 'HASH';

    if (($scope->{kind} || '') eq 'client' && $scope->{client}) {
        $prefs->client($scope->{client})->set('soloistQuality', $level);
    }
    else {
        $prefs->set('soloistQuality', $level);
    }
}

# _markInitialised($class, $mac) -- the server has answered AND an effective
# value is known: the first-start condition (D-12b/D-13) is satisfied and
# must never write again on a later daemon start.
sub _markInitialised {
    my ($class, $mac) = @_;
    my $client = Slim::Player::Client::getClient($mac) or return;
    $prefs->client($client)->set('soloistQualityInitialised', 1);
    $prefs->client($client)->set('soloistQualityPending', 0);
}

sub _markVerified {
    my ($class, $mac, $level) = @_;
    $class->_storeEffectiveCache($mac, $level);
    $class->clearNotice($mac);
    $class->_markInitialised($mac);
}

# _handleRejected($class, $mac, $wanted, $scope, $effective, $err) -- D-14
# "rejected": the server refused $wanted SEMANTICALLY AND a known effective
# level exists (a read-back, or a fresh read after a semantic HTTP/grpc
# refusal). $effective undefined means the refusal could not be corrected --
# there is nothing to reset to -- so this delegates to _handleUnreachable:
# keep the pref, mark pending, and NEVER mark this player initialised
# without an effective value (T-83.3-31).
sub _handleRejected {
    my ($class, $mac, $wanted, $scope, $effective, $err) = @_;

    unless (defined $effective) {
        $class->_handleUnreachable($mac, $err // { class => 'unreachable' });
        return;
    }

    $class->_setScopePref($scope, $effective);
    $class->_storeEffectiveCache($mac, $effective);
    $class->_setNotice($mac, { kind => 'rejected', wanted => $wanted, effective => $effective, at => time() });
    $class->_markInitialised($mac);
}

# _handleUnreachable($class, $mac, $err) -- D-14 "unreachable"/no_token: no
# server answer at all. Keep the pref, mark pending so the next occasion
# (next change, or next daemon start) retries.
sub _handleUnreachable {
    my ($class, $mac, $err) = @_;

    my $kind = ($err && $err->{class}) || 'unreachable';
    if (my $client = Slim::Player::Client::getClient($mac)) {
        $prefs->client($client)->set('soloistQualityPending', 1);
    }
    $class->_setNotice($mac, { kind => $kind, at => time() });
}

# _writeAndVerify($class, $mac, $level, $scope, $cb) -- write, then a
# READBACK_DELAY_S read-back to classify the D-14 outcome. $scope names the
# pref this $level came from ({ kind => 'global' } or { kind => 'client',
# client => $c }), so a rejection can be corrected at the source.
sub _writeAndVerify {
    my ($class, $mac, $level, $scope, $cb) = @_;

    $class->write($mac, $level, sub {
        my ($ok, $err) = @_;

        unless ($ok) {
            if ($err && ($err->{class} || '') eq 'rejected') {
                # The write was refused semantically (transient codes never
                # reach this branch -- Task 1's classifier already routes
                # them to 'unreachable'). Only a successful read-back can
                # supply the value to reset to; a fresh read discovers the
                # effective level the server actually holds.
                $class->read($mac, sub {
                    my ($readLevel, $readErr) = @_;
                    $class->_handleRejected($mac, $level, $scope, $readLevel, $readErr);
                    if (defined $readLevel) {
                        $cb->(1) if $cb;
                    }
                    else {
                        $cb->(0, $readErr) if $cb;
                    }
                });
                return;
            }
            $class->_handleUnreachable($mac, $err);
            $cb->(0, $err) if $cb;
            return;
        }

        Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + READBACK_DELAY_S, sub {
            $class->read($mac, sub {
                my ($readLevel, $readErr) = @_;

                if (defined $readLevel && $readLevel == $level) {
                    $class->_markVerified($mac, $readLevel);
                    $cb->(1) if $cb;
                    return;
                }

                if (defined $readLevel) {
                    # The write succeeded but the read-back differs -- a
                    # known effective value, so this is a genuine D-14
                    # rejection (symmetric with the rejected-write branch
                    # above: only a defined effective level reaches
                    # _handleRejected).
                    $class->_handleRejected($mac, $level, $scope, $readLevel);
                    $cb->(1) if $cb;
                    return;
                }

                # No effective value could be read at all -- unreachable,
                # same as an undefined read-back in the rejected-write
                # branch above.
                $class->_handleUnreachable($mac, $readErr);
                $cb->(0, $readErr) if $cb;
            });
        });
    });
}

# ============================================================
# Entry points
# ============================================================

# applyChange($class, scope => 'global'|'client', client => $c, level => N)
# -- called only from a change-detect guard in a save handler (Settings.pm /
# Settings/Player.pm), never blocking the handler (async only).
sub applyChange {
    my ($class, %o) = @_;

    my $scopeKind = $o{scope} || 'global';
    my $level     = $o{level};
    return unless $class->isValidLevel($level) || $class->isStorableLevel($level);

    if ($scopeKind eq 'client' && $o{client}) {
        my $client = $o{client};
        my $mac    = $client->id;
        return unless $class->deviceIdForMac($mac);    # first-start hook will write once it exists
        $class->_writeAndVerify($mac, $level, { kind => 'client', client => $client });
        return;
    }

    for my $c (Slim::Player::Client::clients()) {
        my $stored = $prefs->client($c)->get('soloistQuality');
        next if defined $stored && $stored ne 'global';    # this player has its own override

        my $mac = $c->id;
        next unless $class->deviceIdForMac($mac);          # first-start hook will write once it exists

        $class->_writeAndVerify($mac, $level, { kind => 'global' });
    }
}

# onDaemonReady($class, $mac) -- D-12(b)/D-13: the ONLY other write
# occasion, called once per daemon start from SoloistDaemon's on_found. Never
# writes on a start where the server has already answered once for this
# player (soloistQualityInitialised) UNLESS a prior attempt never reached
# the server at all (soloistQualityPending) -- D-12: no fighting the app.
sub onDaemonReady {
    my ($class, $mac) = @_;

    return unless (($prefs->get('backend') || 'librespot') eq 'soloist');

    my $client = Slim::Player::Client::getClient($mac) or return;

    my $initialised = $prefs->client($client)->get('soloistQualityInitialised') ? 1 : 0;
    my $pending      = $prefs->client($client)->get('soloistQualityPending') ? 1 : 0;
    return if $initialised && !$pending;

    my $clientStored = $prefs->client($client)->get('soloistQuality');
    my $scope = (defined $clientStored && $clientStored ne 'global' && $class->isStorableLevel($clientStored))
        ? { kind => 'client', client => $client }
        : { kind => 'global' };

    $class->_writeAndVerify($mac, $class->effectiveLevelForClient($client), $scope);
}

1;

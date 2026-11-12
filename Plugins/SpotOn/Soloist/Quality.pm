package Plugins::SpotOn::Soloist::Quality;

# Phase 83.3 Plan 02 (D-12/D-13/D-14/D-15): Spotify streaming-quality setting
# for the Soloist backend. Reads/writes the per-device server-side quality
# via spclient's undocumented playback-settings service, authenticated with
# SpotOn's own login5 bearer token (same idiom as SpClient.pm) -- NOT the
# server-to-client push (that direction is never sent from here, see the
# module header note below).
#
# D-12: the app can change this server-side value at any time. SpotOn only
# writes (a) when the LMS setting is actually changed and (b) once after the
# first CONFIRMED pairing AND login of a device (quick 261112-ca5, reworked by
# R1): the logged_in 0 -> 1 flank writes the wished level once and
# UNCONDITIONALLY -- also when the server already reads it, because the daemon
# takes the level only from the server push such a write triggers -- and
# soloistQualityVerifiedPaired (carrying the device id) closes it. Never
# again, so this module never fights the app. D-13: the default is Automatic
# (level 0). D-14: a write is verified with a one-second read-back; a
# "rejected" answer (grpc-status != 0, an HTTP error code, or a read-back that
# differs from what was written) shows a notice and, ONLY on a settings change
# (not on the reconcile) and ONLY for a confirmed pairing, resets the supplying
# pref to the effective value (the reconcile counts the rejection instead and
# stops after RECONCILE_REJECT_CAP); an "unreachable" answer (no HTTP status at
# all, or a login5 mint failure) keeps the pref and retries on the next
# occasion; after the logged_in flank an "unreachable" write is also retried
# (WR-01), bounded: UNREACHABLE_RETRY_S waits, three attempts, one-shot timers,
# every request through SpClient->gate. D-15: the settings page states a change takes effect from the next
# track (not applied by this module -- Perl module logic only).
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
# ca5 reconcile: cap of rejected reconcile writes per device, settle and retry
# timing of the logged_in flank, stale limit of the serial queue.
use constant RECONCILE_REJECT_CAP => 3;
use constant LOGIN_SETTLE_S       => 3;
use constant LOGIN_RETRY_MAX      => 3;
use constant LOGIN_RETRY_S        => 5;
use constant RECONCILE_STALE_S    => 120;
# WR-01: bounded retry of a reconcile write that ended "unreachable" (429, login5
# throttle, 5xx, network) -- three one-shot attempts, no permanent timer. A
# 429-class failure (gate lock, login5 throttle) waits at least
# UNREACHABLE_RATE_MIN_S: the retry must not land inside the lock.
use constant UNREACHABLE_RETRY_S    => (60, 300, 900);
use constant UNREACHABLE_RATE_MIN_S => 300;
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

# ca5: serial reconcile queue (one player at a time against the shared rate
# limit), per-mac flank retry budget, busy marker with a stale limit.
my @RECONCILE_QUEUE;
my %RECONCILE_QUEUED;
my %FLANK_RETRIES;
my %UNREACH_TRIES;    # mac -> retries of the unreachable write used so far (WR-01)
my %UNREACH_TIMER;    # mac -> the pending retry timer's callback (killable)
my $RECONCILE_BUSY_SINCE = 0;
my $RECONCILE_BUSY_MAC;
my $RECONCILE_GEN = 0;

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
    # 79-43 (D-33 FULL-3 WR-02): the device name is a character string from LMS; its Latin-1 representation
    # ("K\x{fc}che" unflagged) is upgraded on a copy so encode_field sends it as UTF-8 like the flagged one.
    if (defined $name) { $name = "$name"; utf8::upgrade($name); }
    my $descriptor = Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $id)
                    . Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, $name);
    return Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2,
        Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $descriptor));
}

sub _encodeWrite {
    my ($class, $id, $name, $level) = @_;
    require Plugins::SpotOn::API::ProtobufLite;
    if (defined $name) { $name = "$name"; utf8::upgrade($name); }   # 79-43: see _encodeRead
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
# and the user's authorization is fine (quick-261018-ife, WR-18), and so is a
# minting failure login5 marks transient (network, 5xx; R4 WR-02); every other
# token failure stays 'no_token'. Never logs the token, headers, or body -- method name + outcome
# class only (T-02-10 idiom).
#
# 79-61 (FULL-3 WR-03): every request passes SpClient's central gate (the
# shared concurrency cap and 429 key); a cached rate limit answers
# 'unreachable' without any HTTP, and a 429 from playback-settings is recorded
# in the shared key (SpClient->noteRateLimit).
sub _request {
    my ($class, $method, $body, $cb) = @_;

    require Plugins::SpotOn::API::SpClient;
    Plugins::SpotOn::API::SpClient->gate("playback-settings $method", sub {
        my ($release) = @_;
        $class->_requestUngated($method, $body, sub { $release->(); $cb->(@_); });
    }, sub {
        my ($why) = @_;
        main::INFOLOG && $log->info("Soloist::Quality: $method class=unreachable (spclient gate: $why)");
        $cb->(undef, { class => 'unreachable', http => 429, source => 'spclient_gate', reason => $why });
    });
}

sub _requestUngated {
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
            # R4 WR-02: login5 itself marks a minting failure that is the network or a 5xx
            # (Login5.pm:343-348, detail->{transient}) as transient: nothing is wrong with
            # the user's authorization, so it is 'unreachable' like the throttle -- but with
            # its own source, so the 300 s minimum of a throttle does not apply (login5
            # damps an ordinary failed attempt for 15 s only). Directly after an LMS start
            # the token has to be minted first, i.e. exactly at the login flank.
            if ($detail && ref $detail eq 'HASH' && $detail->{transient}) {
                main::INFOLOG && $log->info("Soloist::Quality: $method class=unreachable (login5 transient)");
                $cb->(undef, { class => 'unreachable', source => 'login5_transient', reason => $reason });
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

                if (($code || 0) == 429) {
                    my $retryAfter = ($response && ref $response && $response->can('header'))
                        ? $response->header('Retry-After') : undef;
                    Plugins::SpotOn::API::SpClient->noteRateLimit($retryAfter);
                }

                my $httpClass = $class->_classifyHttpError($code || undef);
                main::INFOLOG && $log->info("Soloist::Quality: $method class=$httpClass (http " . ($code || 'none') . ")");
                $cb->(undef, { class => $httpClass, http => ($code || undef), error => $error });
            },
            { timeout => REQUEST_TIMEOUT },
        );

        # 79-43 (D-33 FULL-3 WR-02): a transport-layer die (HTTP::Message "content must be bytes", a socket
        # error raised synchronously) is classified as unreachable through the same once-only guard instead of
        # escaping into the daemon poll or the settings handler.
        eval {
            $http->post(
                $url,
                'Authorization'   => "Bearer $token",
                'Content-Type'    => 'application/x-protobuf',
                'Accept'          => 'application/x-protobuf',
                'Accept-Encoding' => 'identity',
                $body,
            );
            1;
        } or do {
            my $error = "$@";
            return if $called++;
            main::INFOLOG && $log->info("Soloist::Quality: $method class=unreachable (post died)");
            $cb->(undef, { class => 'unreachable', error => $error });
        };
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

# _pairedNow($class, $mac) -> 1 only when the pairing folder confirms a paired
# device at THIS moment, 0 when it is confirmed unpaired, undef when unknown.
# Only 1 counts as paired (CTX-3): an unregistered device must never write or
# tip a pref.
sub _pairedNow {
    my ($class, $mac) = @_;
    my $paired = eval {
        require Plugins::SpotOn::Soloist;
        Plugins::SpotOn::Soloist::isPairedForClient($mac);
    };
    return undef unless defined $paired;
    return $paired == 1 ? 1 : 0;
}

# _markInitialised($class, $mac) -- the server has answered AND an effective
# value is known. It is only a marker, WRITE-ONLY since ca5: no production code
# reads soloistQualityInitialised any more -- closing the reconcile is
# soloistQualityVerifiedPaired's job (_markVerified). It is still written so a
# downgrade to beta.9 (which reads it) keeps seeing an initialised player.
sub _markInitialised {
    my ($class, $mac) = @_;
    my $client = Slim::Player::Client::getClient($mac) or return;
    $prefs->client($client)->set('soloistQualityInitialised', 1);
}

# _loggedInNow($class, $mac) -> 1 only when this player's OWN Soloist daemon is
# alive and logged in at this moment, else 0 (fail closed). The daemon takes the
# quality only from the server push a write on a paired AND logged-in device
# triggers (spike, Rig 2026-11-12), so a write without that daemon reaches
# nobody. helperForClient falls back to the Sync master for a slave
# (DaemonManager.pm:3542-3549); that daemon is another player's, hence the MAC
# comparison.
# A failure INSIDE the lookup (a renamed accessor, another return format, a
# failing require) also answers 0, but is logged (R4 WR-01): the guard stops every
# write, so it must not do that in silence. A plain absence (no daemon) is a
# state, not a failure, and is not logged here. The names it reads are bound to
# the real classes by t/soloist/53.
sub _loggedInNow {
    my ($class, $mac) = @_;
    my $ok = eval {
        require Plugins::SpotOn::Unified::DaemonManager;
        my $h = Plugins::SpotOn::Unified::DaemonManager->helperForClient($mac);
        ($h && $h->alive && lc($h->mac // '') eq lc($mac // '') && $h->can('_ws') && $h->_ws
            && (($h->_ws->authState || {})->{logged_in})) ? 1 : 0;
    };
    if (my $err = $@) {
        $err =~ s/\s+\z//;
        $log->warn("Soloist::Quality: login state of " . ($mac // '?') . " unknown: $err");
    }
    return $ok ? 1 : 0;
}

# _markVerified($class, $mac, $level) -- the server holds the wanted level.
# Only when the device is confirmed paired at this moment AND its own daemon is
# logged in (the push reached it) the reconcile is closed (VerifiedPaired);
# otherwise it is just noted (Pending) and the next logged_in flank writes
# again (BL-01: the read-back says nothing about the daemon).
sub _markVerified {
    my ($class, $mac, $level) = @_;
    $class->_storeEffectiveCache($mac, $level);
    $class->clearNotice($mac);
    $class->_markInitialised($mac);

    my $client = Slim::Player::Client::getClient($mac) or return;
    if (($class->_pairedNow($mac) // 0) == 1 && $class->_loggedInNow($mac)) {
        # WR-07: the server value lives per DEVICE ID, so the flag carries it --
        # a new .device_id is a new device and is reconciled again.
        $prefs->client($client)->set('soloistQualityVerifiedPaired', $class->deviceIdForMac($mac) || 1);
        $prefs->client($client)->set('soloistQualityPending', 0);
        $prefs->client($client)->set('soloistQualityRejectCount', 0);
        $class->_cancelUnreachableRetry($mac);
    }
    else {
        $prefs->client($client)->set('soloistQualityPending', 1);
    }
}

# _handleRejected($class, $mac, $wanted, $scope, $effective, $err, $opts) --
# D-14 "rejected": the server refused $wanted SEMANTICALLY AND a known
# effective level exists (a read-back, or a fresh read after a semantic
# HTTP/grpc refusal). $effective undefined means the refusal could not be
# corrected -- there is nothing to reset to -- so this delegates to
# _handleUnreachable: keep the pref, mark pending (T-83.3-31); on the reconcile
# path the refusal is still counted against the cap (WR-04).
# ca5 (CTX-4/W3): the pref is reset to $effective ONLY on a non-reconcile path
# AND when the device is confirmed paired; an unconfirmed device must never tip
# the global wish. Every other case keeps the pref and marks pending. The
# reconcile path additionally counts the rejection (cap per device). A
# rejection never closes the reconcile.
sub _handleRejected {
    my ($class, $mac, $wanted, $scope, $effective, $err, $opts) = @_;

    unless (defined $effective) {
        # WR-04: a refused write whose read-back failed too is still a refusal --
        # on the reconcile path it counts against the cap (else every flank writes
        # again without limit). Without an effective value there is nothing to
        # say "rejected" about, so the notice is the plain unreachable one.
        if ($opts && $opts->{reconcile} && (my $client = Slim::Player::Client::getClient($mac))) {
            my $count = $prefs->client($client)->get('soloistQualityRejectCount') || 0;
            $prefs->client($client)->set('soloistQualityRejectCount', $count + 1);
        }
        my %e = %{ $err || {} };
        $e{class} = 'unreachable' if !$e{class} || $e{class} eq 'rejected';
        $class->_handleUnreachable($mac, \%e);
        return;
    }

    my $reconcile = ($opts && $opts->{reconcile}) ? 1 : 0;
    my $client    = Slim::Player::Client::getClient($mac);
    my $didReset  = (!$reconcile && ($class->_pairedNow($mac) // 0) == 1) ? 1 : 0;

    if ($didReset) {
        $class->_setScopePref($scope, $effective);
    }
    elsif ($client) {
        $prefs->client($client)->set('soloistQualityPending', 1);
    }
    if ($reconcile && $client) {
        my $count = $prefs->client($client)->get('soloistQualityRejectCount') || 0;
        $prefs->client($client)->set('soloistQualityRejectCount', $count + 1);
    }

    $class->_storeEffectiveCache($mac, $effective);
    # WR-03: the notice says whether the pref really was reset, so the text
    # never claims a reset that did not happen.
    $class->_setNotice($mac, { kind => 'rejected', wanted => $wanted, effective => $effective,
                               reset => $didReset, at => time() });
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

# _writeAndVerify($class, $mac, $level, $scope, $cb, $opts) -- write, then a
# READBACK_DELAY_S read-back to classify the D-14 outcome. $scope names the
# pref this $level came from ({ kind => 'global' } or { kind => 'client',
# client => $c }), so a rejection can be corrected at the source. $opts is
# forwarded to _handleRejected ({ reconcile => 1 }: reset no pref, count it).
sub _writeAndVerify {
    my ($class, $mac, $level, $scope, $cb, $opts) = @_;

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
                    $class->_handleRejected($mac, $level, $scope, $readLevel, $readErr, $opts);
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
                    $class->_handleRejected($mac, $level, $scope, $readLevel, undef, $opts);
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
        $prefs->client($client)->set('soloistQualityRejectCount', 0);
        $class->_writeAndVerify($mac, $level, { kind => 'client', client => $client });
        return;
    }

    my @macs;
    my %online;
    for my $c (Slim::Player::Client::clients()) {
        $online{ $c->id } = 1;
        my $stored = $prefs->client($c)->get('soloistQuality');
        next if defined $stored && $stored ne 'global';    # this player has its own override

        my $mac = $c->id;
        next unless $class->deviceIdForMac($mac);          # first-start hook will write once it exists

        $prefs->client($c)->set('soloistQualityRejectCount', 0);
        push @macs, $mac;
    }

    # ca5 (CTX-5): a player that is not connected cannot be written now. Mark
    # every stored player without an own level pending, so its next start or
    # login flank reconciles it. An own level (0 = Automatic included) stays.
    eval {
        for my $cp ($prefs->allClients) {
            my $id = $cp && $cp->{clientid};
            next if !defined $id || $online{$id};
            my $own = $cp->get('soloistQuality');
            next if defined $own && $own ne 'global';
            $cp->set('soloistQualityPending', 1);
            $cp->set('soloistQualityRejectCount', 0);
        }
        1;
    } or do {
        $log->warn("Soloist::Quality: offline pending marking failed: $@");
    };
    # 79-61 (FULL-3 WR-03): one player at a time -- the next write starts
    # when the previous write-and-verify has finished, instead of a burst of
    # one write (plus read-backs) per player against the shared rate limit.
    $class->_applyGlobalSerial($level, @macs);
}

sub _applyGlobalSerial {
    my ($class, $level, @macs) = @_;
    my $mac = shift @macs;
    return unless defined $mac;
    $class->_writeAndVerify($mac, $level, { kind => 'global' }, sub {
        $class->_applyGlobalSerial($level, @macs);
    });
}

# _needsReconcile($class, $client) -- does this player still need the
# reconcile write? Not once it is verified paired FOR ITS CURRENT DEVICE ID and
# nothing is pending (D-12: never fight the app; a flag without the current id,
# e.g. the 1 an interim build stored, counts as open); not once the rejection
# cap is reached.
sub _needsReconcile {
    my ($class, $client) = @_;

    my $verified = $prefs->client($client)->get('soloistQualityVerifiedPaired');
    my $deviceId = $class->deviceIdForMac($client->id);
    my $sameDevice = (defined $verified && length $verified && defined $deviceId && $verified eq $deviceId) ? 1 : 0;
    my $pending    = $prefs->client($client)->get('soloistQualityPending') ? 1 : 0;
    return 0 if $sameDevice && !$pending;    # ca5 gate: verified_paired

    my $rejects = $prefs->client($client)->get('soloistQualityRejectCount') || 0;
    if ($rejects >= RECONCILE_REJECT_CAP) {
        main::INFOLOG && $log->is_info && $log->info(
            "SpotOn quality reconcile (mac=" . ($client->id // '?') . "): cap reached ($rejects), no request"
        );
        return 0;
    }
    return 1;
}

# onDaemonReady($class, $mac) -- called once per daemon start from
# SoloistDaemon's on_found. R1 (quick 261112-ca5 rework): the daemon is not
# logged in at this point, so this occasion posts NOTHING -- a write before the
# login never reaches the daemon (it takes the level only from the server push
# a write on a paired, logged-in device triggers). It only notes an open player
# as Pending; the logged_in flank (onLoginFlank) does the work.
sub onDaemonReady {
    my ($class, $mac) = @_;

    return unless (($prefs->get('backend') || 'librespot') eq 'soloist');

    my $client = Slim::Player::Client::getClient($mac) or return;
    return unless $class->_needsReconcile($client);

    $prefs->client($client)->set('soloistQualityPending', 1);
}

# onLoginFlank($class, $mac) -- the one occasion that writes: the daemon's
# logged_in went 0 -> 1 (SoloistWS), right after a pairing or on a start of an
# already paired daemon. The pairing folder may lag behind the flank, so wait
# LOGIN_SETTLE_S, and a result "still unpaired" is retried up to LOGIN_RETRY_MAX
# times, LOGIN_RETRY_S apart (no permanent timer).
sub onLoginFlank {
    my ($class, $mac) = @_;

    return unless (($prefs->get('backend') || 'librespot') eq 'soloist');

    my $client = Slim::Player::Client::getClient($mac) or return;
    return unless $class->_needsReconcile($client);

    $FLANK_RETRIES{$mac} = LOGIN_RETRY_MAX;
    $class->_cancelUnreachableRetry($mac);    # a new flank is a new occasion with a fresh budget
    Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + LOGIN_SETTLE_S, sub {
        $class->_attemptReconcile($mac);
    });
}

# _attemptReconcile($class, $mac) -- queue one reconcile attempt, unless the
# player is gone, the backend changed, the reconcile closed meanwhile, or the
# player has no logged-in daemon of its own any more (a write would reach
# nobody; the next flank writes -- BL-01); then the flank's retry budgets are
# dropped as well (they must not be inherited by a later run of the same player).
sub _attemptReconcile {
    my ($class, $mac) = @_;

    my $client = Slim::Player::Client::getClient($mac);
    my $applies = $client
        && (($prefs->get('backend') || 'librespot') eq 'soloist')
        && $class->_needsReconcile($client);
    my $loggedIn = $applies ? $class->_loggedInNow($mac) : 0;
    if (!$applies || !$loggedIn) {
        # R4 WR-01: an attempt that is dropped ONLY for want of a login is the one
        # that would otherwise leave no trace at all (0 requests, 0 lines).
        $class->_logReconcile($mac, undef, undef, 'skipped_no_login') if $applies;
        delete $FLANK_RETRIES{$mac};
        $class->_cancelUnreachableRetry($mac);
        return;
    }
    $class->_enqueueReconcile($mac);
}

# _scheduleUnreachableRetry($class, $mac, $err) -- WR-01: a reconcile write that
# ended "unreachable" (and only that: a rejection is the cap's business, a missing
# token or device id is not transient) gets at most UNREACHABLE_RETRY_S attempts,
# one one-shot timer at a time. _attemptReconcile re-checks player, backend, need
# and login, so a retry that no longer applies simply ends.
sub _scheduleUnreachableRetry {
    my ($class, $mac, $err) = @_;

    return unless $err && ($err->{class} || '') eq 'unreachable';

    my @wait = (UNREACHABLE_RETRY_S);
    my $n    = $UNREACH_TRIES{$mac} // 0;
    return if $n >= @wait;
    $UNREACH_TRIES{$mac} = $n + 1;

    my $delay = $wait[$n];
    if ((($err->{http} // 0) == 429 || ($err->{source} // '') eq 'login5') && $delay < UNREACHABLE_RATE_MIN_S) {
        $delay = UNREACHABLE_RATE_MIN_S;
    }

    $class->_killUnreachableTimer($mac);
    my $cb = sub {
        delete $UNREACH_TIMER{$mac};
        $class->_attemptReconcile($mac);
    };
    $UNREACH_TIMER{$mac} = $cb;
    Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + $delay, $cb);
}

sub _killUnreachableTimer {
    my ($class, $mac) = @_;
    if (my $t = delete $UNREACH_TIMER{$mac}) {
        Slim::Utils::Timers::killTimers($class, $t);
    }
}

sub _cancelUnreachableRetry {
    my ($class, $mac) = @_;
    delete $UNREACH_TRIES{$mac};
    $class->_killUnreachableTimer($mac);
}

# _expireStaleReconcile($class) -- a run that never reported back (a lost
# answer, a swallowed die) must not block the queue for good (WR-01): after
# RECONCILE_STALE_S the busy marker is dropped, the player's dedupe mark with
# it, and the abandoned run's generation is void, so its late answer cannot
# touch the queue any more. Called BEFORE the dedupe mark is consulted -- the
# mark of the stuck player itself would otherwise hide the stale run for good.
sub _expireStaleReconcile {
    my ($class) = @_;

    return unless $RECONCILE_BUSY_SINCE;
    return if (Time::HiRes::time() - $RECONCILE_BUSY_SINCE) < RECONCILE_STALE_S;

    $log->warn("Soloist::Quality: reconcile of " . ($RECONCILE_BUSY_MAC // '?') . " did not finish in "
        . RECONCILE_STALE_S . "s, moving on");
    delete $RECONCILE_QUEUED{$RECONCILE_BUSY_MAC} if defined $RECONCILE_BUSY_MAC;
    $RECONCILE_BUSY_SINCE = 0;
    $RECONCILE_BUSY_MAC   = undef;
    $RECONCILE_GEN++;    # the late callback of the abandoned run is void from now on
}

sub _enqueueReconcile {
    my ($class, $mac) = @_;

    $class->_expireStaleReconcile;
    unless ($RECONCILE_QUEUED{$mac}) {
        push @RECONCILE_QUEUE, $mac;
        $RECONCILE_QUEUED{$mac} = 1;
    }
    $class->_drainReconcile;
}

sub _drainReconcile {
    my ($class) = @_;

    $class->_expireStaleReconcile;
    return if $RECONCILE_BUSY_SINCE;

    my $mac = shift @RECONCILE_QUEUE;
    return unless defined $mac;

    $RECONCILE_BUSY_SINCE = Time::HiRes::time();
    $RECONCILE_BUSY_MAC   = $mac;
    my $gen      = ++$RECONCILE_GEN;
    my $finished = 0;

    my $finish = sub {
        return if $finished++;
        return if $gen != $RECONCILE_GEN;    # a stale run finishing late must not touch the queue
        delete $RECONCILE_QUEUED{$mac};
        $RECONCILE_BUSY_SINCE = 0;
        $RECONCILE_BUSY_MAC   = undef;
        $class->_drainReconcile;
    };

    # A synchronous die inside the run (a name lookup, a stub) must free the
    # queue at once instead of after RECONCILE_STALE_S.
    eval { $class->_reconcileOne($mac, $finish); 1 } or do {
        $log->warn("Soloist::Quality: reconcile of $mac died: $@");
        $finish->();
    };
}

# Test hook: the flank retry budget left for a player (undef = none).
sub _flankRetriesFor { return $FLANK_RETRIES{ $_[1] } }

# Test hook: the unreachable retries a player has used so far (undef = none).
sub _unreachableTriesFor { return $UNREACH_TRIES{ $_[1] } }

# Test hook: forget queue, busy marker, flank retries and unreachable retries.
sub _resetReconcileQueue {
    @RECONCILE_QUEUE      = ();
    %RECONCILE_QUEUED     = ();
    %FLANK_RETRIES        = ();
    %UNREACH_TRIES        = ();
    %UNREACH_TIMER        = ();
    $RECONCILE_BUSY_SINCE = 0;
    $RECONCILE_BUSY_MAC   = undef;
    $RECONCILE_GEN++;    # a callback of the forgotten run is stale from now on
}

sub _logReconcile {
    my ($class, $mac, $wanted, $paired, $action) = @_;
    main::INFOLOG && $log->is_info && $log->info(sprintf(
        'SpotOn quality reconcile (mac=%s): wanted=%s paired=%s -> %s',
        $mac, defined $wanted ? $wanted : '?',
        defined $paired ? $paired : 'unknown', $action
    ));
}

# _reconcileOne($class, $mac, $done) -- R1: no read first. Only a device that
# is confirmed paired (called from the logged_in flank, so the login is given)
# gets the wished level written ONCE UNCONDITIONALLY, also when the server
# already reads it (the daemon takes the level only from the push such a write
# triggers), read-back verified by _writeAndVerify. An unconfirmed pairing
# posts nothing, only Pending. A write that ends "unreachable" is retried, bounded
# (_scheduleUnreachableRetry). $done runs exactly once per branch.
sub _reconcileOne {
    my ($class, $mac, $done) = @_;

    my $client = Slim::Player::Client::getClient($mac);
    unless ($client) {
        delete $FLANK_RETRIES{$mac};
        $done->();
        return;
    }
    # Re-check at dequeue time: an earlier run may have closed it meanwhile.
    unless ($class->_needsReconcile($client)) {
        delete $FLANK_RETRIES{$mac};
        $done->();
        return;
    }

    my $paired = $class->_pairedNow($mac);
    unless (defined $paired && $paired == 1) {
        $prefs->client($client)->set('soloistQualityPending', 1);
        $class->_logReconcile($mac, undef, $paired, 'deferred_unpaired');

        # A flank that found the device unpaired tries again a few times (the
        # pairing folder may lag the login).
        if (($FLANK_RETRIES{$mac} // 0) > 0) {
            $FLANK_RETRIES{$mac}--;
            $done->();    # first: the queue dedupe would swallow the retry otherwise
            Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + LOGIN_RETRY_S, sub {
                $class->_attemptReconcile($mac);
            });
            return;
        }
        delete $FLANK_RETRIES{$mac};
        $done->();
        return;
    }

    # The wish is formed here, immediately before the write (WR-02): nothing
    # asynchronous sits between this line and the write call.
    my $wanted       = $class->effectiveLevelForClient($client);
    my $clientStored = $prefs->client($client)->get('soloistQuality');
    my $scope = (defined $clientStored && $clientStored ne 'global' && $class->isStorableLevel($clientStored))
        ? { kind => 'client', client => $client }
        : { kind => 'global' };

    $class->_logReconcile($mac, $wanted, $paired, 'write');
    delete $FLANK_RETRIES{$mac};
    $class->_writeAndVerify($mac, $wanted, $scope, sub {
        my ($ok, $err) = @_;
        $done->();    # first: the queue dedupe would swallow the retry otherwise
        $class->_scheduleUnreachableRetry($mac, $err) unless $ok;
    }, { reconcile => 1 });
}

1;

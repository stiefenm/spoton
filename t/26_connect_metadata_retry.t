#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use JSON::PP ();
use Test::More;
use FindBin;
use lib "$FindBin::Bin/..";

# LMS logging switches are constants in production.
sub DEBUGLOG () { 0 }
sub INFOLOG () { 0 }

BEGIN {
    # Load the actual Connect module with only its external LMS/API services stubbed.
    $INC{"$_.pm"} = 1 for qw(
        JSON/XS/VersionOneAndTwo Slim/Utils/Log Slim/Utils/Cache
        Slim/Utils/Prefs Slim/Utils/Strings Slim/Utils/Timers Slim/Networking/SimpleAsyncHTTP
        Plugins/SpotOn/Plugin Plugins/SpotOn/API/Client
    );
}
{
    package JSON::XS::VersionOneAndTwo;
    # Decode the daemon wire format using Perl's core JSON implementation.
    sub import { no strict 'refs'; *{caller() . '::from_json'} = sub { JSON::PP->new->decode($_[0]) }; }
}
{
    package Slim::Utils::Strings;
    # A non-English sentinel proves the display uses the localized token.
    sub import {
        no strict 'refs';
        *{caller() . '::cstring'} = sub {
            die "Unexpected string token" unless $_[1] eq 'PLUGIN_SPOTON_LOADING_TRACK_INFORMATION';
            return 'Localized loading title';
        };
    }
}
{
    package Slim::Utils::Log;
    # Export the logger expected by Connect at module load time.
    sub import { no strict 'refs'; *{caller() . '::logger'} = sub { bless {}, 'Fixture' }; }
}
{
    package Slim::Utils::Prefs;
    # All preferences default to unset, disabling optional diagnostic logging.
    sub import { no strict 'refs'; *{caller() . '::preferences'} = sub { bless {}, 'Fixture' }; }
}
{
    package Slim::Utils::Cache;
    # Shared state represents the cache also used by API::Client for rate limits.
    our %data;
    # The namespace is irrelevant because this fixture has only the SpotOn cache.
    sub new { bless {}, shift }
    # Missing keys model cache misses.
    sub get { $data{$_[1]} }
    # Store metadata without wall-clock expiry so tests control time explicitly.
    sub set { $data{$_[1]} = $_[2] }
    # Removing old metadata prevents fallback to the preceding track.
    sub remove { delete $data{$_[1]} }
}
{
    package Slim::Utils::Timers;
    # Pending callbacks are executed manually without sleeping.
    our @pending;
    # Keep callback arguments intact as LMS does.
    sub setTimer { push @pending, [@_] }
    # Only remove timers belonging to the requested owner and callback.
    sub killTimers { my ($owner, $cb) = @_; @pending = grep { $_->[0] != $owner || $_->[2] != $cb } @pending; }
}
{
    package Slim::Control::Request;
    # Commands executed by playlist play are recorded separately from incoming events.
    our @executed;
    # The fixture's active client is the target of simulated playlist execution.
    our $player;
    # Extra arguments follow LMS 9.1's tag:value parsing rule.
    sub new {
        my ($class, $id, $args) = @_;
        my %params = (_cmd => $args->[1]);
        for my $i (2 .. $#$args) {
            if ($args->[$i] && $args->[$i] =~ /([^:]+):(.*)/s) {
                $params{$1} = $2;
            } else {
                $params{"_p$i"} = $args->[$i];
            }
        }
        bless { args => $args, params => \%params }, $class;
    }
    # Incoming events are routed to the one player in this test.
    sub client { $player }
    # Missing optional metadata emulates an older daemon.
    sub getParam { $_[0]{params}{$_[1]} }
    # Record source marks used to suppress command echoes.
    sub source { $_[0]{source} = $_[1] if @_ > 1; $_[0]{source} }
    # Playlist play makes the requested URL visible immediately in this fixture.
    sub execute {
        my ($self) = @_;
        push @executed, $self->{args};
        $player->{url} = $self->{args}[2] if $self->{args}[0] eq 'playlist' && $self->{args}[1] eq 'play';
    }
    # Count refreshes to check stale callbacks have no display side effects.
    our $notifications = 0;
    # No player notifications leave this isolated test.
    sub notifyFromArray { $notifications++ }
}
{
    package Slim::Music::Info;
    # Record titles for both logical and direct stream URLs.
    our %titles;
    # This mimics the display-title store used by renderers.
    sub setCurrentTitle { $titles{$_[0]} = $_[1] }
}
{
    package Plugins::SpotOn::Plugin;
    # Cache version only needs to match within the fixture.
    sub SPOTON_CACHE_VERSION () { 1 }
    # These presentation helpers avoid loading unrelated plugin dependencies.
    sub _releaseYear { defined($_[0]) && $_[0] =~ /^(\d{4})/ ? $1 : '' }
    # No artwork in fixture responses exercises the fallback cover.
    sub _largestImage { $_[0] && @{$_[0]} ? $_[0][0]{url} : undef }
    # Connect display type is independent of retry behavior.
    sub _typeString { 'Connect' }
    # Match the bitrate in the reported failure.
    sub _bitrateForClient { 320 }
    # External identifiers are not used by these track fixtures.
    sub _extractTrackIds { () }
}
{
    package Plugins::SpotOn::API::Client;
    # Capture asynchronous callbacks so failures and late replies can be injected.
    our @requests;
    # Each entry preserves the requested track ID and completion callback.
    sub getTrack { push @requests, [$_[2], $_[3]] }
}
{
    package Fixture;
    # Client, song and track share one object unless a test replaces the playing song.
    sub new { bless { eventTrackUri => 'spotify:track:B', info => { title => 'Track A' } }, shift }
    # Group playback is represented by its master in Connect event handlers.
    sub master { $_[0] }
    # A stable player identifier lets the start handler establish session ownership.
    sub id { 'test-player' }
    # Track changes must not restart an already playing stream.
    sub isPlaying { 1 }
    # Elapsed time is independent of metadata availability.
    sub songElapsedSeconds { 100 }
    # Capture timeline resets performed by the change event.
    sub startOffset { $_[0]{offset} = $_[1] }
    # LMS play-point invalidation needs no implementation in the fixture.
    sub playPoint { }
    # Return client preferences without a separate preference store.
    sub client { $_[0] }
    # Unset preferences use production defaults.
    sub get { undef }
    # Model LMS pluginData getters and setters.
    sub pluginData { my ($self, $key, @value) = @_; $self->{$key} = $value[0] if @value; $self->{$key} }
    # A replacement song simulates leaving the original stream.
    sub playingSong { $_[0]{replacement} || $_[0] }
    # The fixture itself exposes the logical track URL.
    sub track { $_[0] }
    # A source switch changes this URL to a non-Connect URL.
    sub url { $_[0]{url} || 'spoton://connect-session' }
    # The stream URL remains constant through Connect track transitions.
    sub streamUrl { 'http://localhost/stream' }
    # Duration writes allow stale-duration clearing to be asserted.
    sub duration { $_[0]{duration} = $_[1] if @_ > 1; $_[0]{duration} }
    # No actual player progress bar exists in the fixture.
    sub streamingProgressBar { }
    # Record polling-client invalidation without requiring LMS.
    sub currentPlaylistUpdateTime { $_[0]{updateTime} = $_[1] }
}
require Plugins::SpotOn::Connect;
{
    no warnings qw(redefine once);
    # Bypass session setup; tests separately exercise URL and song ownership guards.
    *Plugins::SpotOn::Connect::isSpotifyConnect = sub { !$_[1]{inactive} };
}

# Begin a new transition using the same entry point as the production change handler.
sub begin_track {
    my ($client, $id) = @_;
    $client->pluginData(eventTrackUri => "spotify:track:$id");
    Plugins::SpotOn::Connect::_fetchTrackMetadata($client, $id);
}

# Complete an API call with the final 429 seen after API::Client exhausts its retry.
sub rate_limit {
    my ($request, $seconds) = @_;
    $Slim::Utils::Cache::data{spoton_rate_limit} = Time::HiRes::time() + $seconds;
    $request->[1]->(undef, { code => 429, error => 'rate_limited' });
}

# Fire one recovery timer after simulating expiry of the API backoff window.
sub retry_now {
    my $timer = shift @Slim::Utils::Timers::pending;
    delete $Slim::Utils::Cache::data{spoton_rate_limit};
    $timer->[2]->($timer->[0], @{$timer}[3 .. $#$timer]);
}

# A successful response must match the requested Spotify ID.
sub succeed {
    my ($request) = @_;
    $request->[1]->({ uri => "spotify:track:$request->[0]", name => "Track $request->[0]", duration_ms => 237360 });
}

my $client = Fixture->new;
begin_track($client, 'B');
is($client->pluginData('info')->{title}, 'Localized loading title', 'Old title replaced while lookup is pending');
is($client->duration, 0, 'Old duration cleared');
my $request = shift @Plugins::SpotOn::API::Client::requests;
rate_limit($request, 29);
is(scalar @Slim::Utils::Timers::pending, 1, 'Second API 429 schedules Connect recovery');
cmp_ok($Slim::Utils::Timers::pending[0][1], '>=', $Slim::Utils::Cache::data{spoton_rate_limit} + 1, 'Recovery respects Retry-After expiry');
retry_now();
succeed(shift @Plugins::SpotOn::API::Client::requests);
is($client->pluginData('info')->{title}, 'Track B', 'Recovery publishes current metadata');
is($client->duration, 237.36, 'Recovery restores current duration');
is(scalar @Slim::Utils::Timers::pending, 0, 'Success leaves no retry');

begin_track($client, 'C');
$request = shift @Plugins::SpotOn::API::Client::requests;
rate_limit($request, 120);
my $stale_timer = $Slim::Utils::Timers::pending[0];
begin_track($client, 'D');
is(scalar @Slim::Utils::Timers::pending, 0, 'Track change cancels pending recovery');
my $current = shift @Plugins::SpotOn::API::Client::requests;
$stale_timer->[2]->($stale_timer->[0], @{$stale_timer}[3 .. $#$stale_timer]);
is(scalar @Plugins::SpotOn::API::Client::requests, 0, 'Late timer cannot request an old track');
succeed($current);
my $notifications = $Slim::Control::Request::notifications;
succeed($request);
is($client->pluginData('info')->{title}, 'Track D', 'Late response cannot overwrite newer track');
is($Slim::Control::Request::notifications, $notifications, 'Late response does not notify clients');

begin_track($client, 'E');
$request = shift @Plugins::SpotOn::API::Client::requests;
$client->{url} = 'spoton://track:Browse';
rate_limit($request, 29);
is(scalar @Slim::Utils::Timers::pending, 0, 'Source switch prevents retry');
delete $client->{url};

begin_track($client, 'F');
$request = shift @Plugins::SpotOn::API::Client::requests;
$request->[1]->(undef, { code => 404 });
is(scalar @Slim::Utils::Timers::pending, 0, 'Permanent errors are not retried');

begin_track($client, 'G');
for (1 .. 3) {
    rate_limit(shift @Plugins::SpotOn::API::Client::requests, 29);
    is(scalar @Slim::Utils::Timers::pending, 1, "Recovery attempt $_ scheduled");
    retry_now();
}
rate_limit(shift @Plugins::SpotOn::API::Client::requests, 29);
is(scalar @Slim::Utils::Timers::pending, 0, 'Persistent failures stop after three recovery attempts');

begin_track($client, 'H');
my $old_h = shift @Plugins::SpotOn::API::Client::requests;
begin_track($client, 'I');
shift @Plugins::SpotOn::API::Client::requests;
begin_track($client, 'H');
my $new_h = shift @Plugins::SpotOn::API::Client::requests;
succeed($old_h);
is($client->pluginData('info')->{title}, 'Localized loading title', 'A -> B -> A rejects the original A response');
succeed($new_h);
is($client->pluginData('info')->{title}, 'Track H', 'Latest A response is accepted');

begin_track($client, 'J');
$request = shift @Plugins::SpotOn::API::Client::requests;
$client->{replacement} = Fixture->new;
succeed($request);
is($client->pluginData('info')->{title}, 'Localized loading title', 'Replaced song rejects a late response');
delete $client->{replacement};

begin_track($client, 'K');
$request = shift @Plugins::SpotOn::API::Client::requests;
$request->[1]->(undef, { code => 503 });
is(scalar @Slim::Utils::Timers::pending, 1, 'Temporary server errors also recover');
$client->{inactive} = 1;
retry_now();
is(scalar @Plugins::SpotOn::API::Client::requests, 0, 'Ended Connect session does not retry');

# Valid daemon payloads exercise the shared display writer without any API call.
delete $client->{inactive};
@Slim::Utils::Timers::pending = ();
$client->pluginData(eventTrackUri => 'spotify:track:L');
my $payload = {
    uri => 'spotify:track:L', name => 'Björk: "Live" — 東京',
    artists => [{ name => 'Artist & guest' }], duration_ms => 237360,
    album => { name => 'Album: one', images => [{url => 'https://i.scdn.co/image/example', width => 640}] },
};
$Slim::Utils::Cache::data{'spoton_meta_' . Digest::MD5::md5_hex('spoton://track:L')} = {
    year => '2005', albumId => 'album-L', artistId => 'artist-L',
};
Plugins::SpotOn::Connect::_connectTrackMetadata($client, 'L', JSON::PP->new->encode($payload));
is(scalar @Plugins::SpotOn::API::Client::requests, 0, 'Daemon metadata bypasses Web API');
is($client->pluginData('info')->{title}, $payload->{name}, 'Unicode title displayed immediately');
is($client->pluginData('info')->{artist}, 'Artist & guest', 'Artist applied');
is($client->pluginData('info')->{album}, 'Album: one', 'Album applied');
is($client->pluginData('info')->{cover}, 'https://i.scdn.co/image/example', 'Artwork applied');
is($client->duration, 237.36, 'Daemon duration used');
is($client->pluginData('info')->{year}, '2005', 'Connect retains same-track cached year');
my $saved = $Slim::Utils::Cache::data{'spoton_meta_' . Digest::MD5::md5_hex($client->url)};
is($saved->{albumId}, 'album-L', 'Connect retains album navigation');
# Advancing a shared stream must not inherit the preceding track's optional details.
$payload->{uri} = 'spotify:track:L2';
$client->pluginData(eventTrackUri => $payload->{uri});
Plugins::SpotOn::Connect::_connectTrackMetadata($client, 'L2', JSON::PP->new->encode($payload));
$saved = $Slim::Utils::Cache::data{'spoton_meta_' . Digest::MD5::md5_hex($client->url)};
ok(!$saved->{albumId}, 'Next track does not inherit previous album ID');
$payload->{uri} = 'spotify:track:L';
$client->pluginData(eventTrackUri => $payload->{uri});
Plugins::SpotOn::Connect::_connectTrackMetadata($client, 'L', JSON::PP->new->encode($payload));
Plugins::SpotOn::Connect::_connectTrackMetadata($client, 'L', undef);
is(scalar @Plugins::SpotOn::API::Client::requests, 0, 'Same-track re-entry uses daemon metadata cache');

# A stream may not be ready when playlist play returns; defer local application only.
$client->pluginData(eventTrackUri => 'spotify:track:M');
$payload->{uri} = 'spotify:track:M';
$payload->{name} = 'New stream';
Plugins::SpotOn::Connect::_connectTrackMetadata($client, 'M', JSON::PP->new->encode($payload), 'spoton://connect-new');
is($client->pluginData('info')->{title}, 'Björk: "Live" — 東京', 'Pending start does not overwrite old song');
is(scalar @Plugins::SpotOn::API::Client::requests, 0, 'Waiting for stream does not request Web API');
is(scalar @Slim::Utils::Timers::pending, 1, 'Start waits for exact Connect URL');
Plugins::SpotOn::Connect::_connectTrackMetadata($client, 'M', JSON::PP->new->encode($payload));
is($client->pluginData('info')->{title}, 'Björk: "Live" — 東京', 'Metadata-only event preserves pending start URL');
is(scalar @Slim::Utils::Timers::pending, 1, 'Later metadata replaces rather than duplicates the pending timer');
$client->{url} = 'spoton://connect-new';
retry_now();
is($client->pluginData('info')->{title}, 'New stream', 'Metadata applied when stream becomes ready');

# Invalid daemon payloads fall back safely, including mismatched track identities.
for my $invalid ('broken JSON', '[]', '{"uri":"spotify:track:N","name":"bad","artists":{}}', JSON::PP->new->encode($payload)) {
    $client->pluginData(eventTrackUri => 'spotify:track:N');
    Plugins::SpotOn::Connect::_connectTrackMetadata($client, 'N', $invalid);
    is(scalar @Plugins::SpotOn::API::Client::requests, 1, 'Invalid or mismatched daemon payload uses fallback');
    shift @Plugins::SpotOn::API::Client::requests;
}

# Direct metadata supersedes an API request that was already in flight.
begin_track($client, 'O');
my $old_api = shift @Plugins::SpotOn::API::Client::requests;
$payload->{uri} = 'spotify:track:O';
$payload->{name} = 'Immediate metadata';
Plugins::SpotOn::Connect::_connectTrackMetadata($client, 'O', JSON::PP->new->encode($payload));
succeed($old_api);
is($client->pluginData('info')->{title}, 'Immediate metadata', 'Late Web API response cannot overwrite daemon metadata');
is(scalar @Slim::Utils::Timers::pending, 0, 'Direct metadata cancels recovery timers');

# Exercise the real Perl event entry point with LMS-compatible tagged arguments.
$Slim::Control::Request::player = $client;
@Slim::Utils::Timers::pending = ();
@Plugins::SpotOn::API::Client::requests = ();
$Slim::Utils::Cache::data{spoton_rate_limit} = Time::HiRes::time() + 300;
$client->{url} = 'http://radio.example/stream';
for my $transition (['start', 'P', ''], ['change', 'Q', 'P'], ['metadata', 'Q', '']) {
    my ($command, $id, $previous) = @$transition;
    $payload->{uri} = "spotify:track:$id";
    $payload->{name} = "Immediate $id: title";
    my $event = Slim::Control::Request->new($client->id,
        ['spottyconnect', $command, $id, $previous, 'metadata:' . JSON::PP->new->encode($payload)]);
    Plugins::SpotOn::Connect::_connectEvent($event);
    is($client->pluginData('info')->{title}, $payload->{name}, "$command dispatch applies tagged metadata during API backoff");
    is(scalar @Plugins::SpotOn::API::Client::requests, 0, "$command dispatch makes no Web API requests");
}
is(scalar @Slim::Control::Request::executed, 1, 'Only initial start opens a stream; metadata changes never restart playback');
my $event = Slim::Control::Request->new($client->id,
    ['spottyconnect', 'metadata', 'P', '', 'metadata:' . JSON::PP->new->encode($payload)]);
Plugins::SpotOn::Connect::_connectEvent($event);
is($client->pluginData('info')->{title}, 'Immediate Q: title', 'Metadata-only event for an old track is ignored');

done_testing;

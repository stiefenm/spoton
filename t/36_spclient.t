#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';   # cross-package stub var/sub access below (mirrors t/08 pattern)
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# Resolve project root
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname($test_dir);

# Create a temporary directory for LMS stubs
my $stub_dir = tempdir(CLEANUP => 1);

# ============================================================
# Helper: write a stub Perl module
# ============================================================
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
# LMS Module Stubs (t/08_api_client.t pattern)
# ============================================================

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
sub addLogCategory { return bless {}, 'Slim::Utils::Log' }
sub logger { return bless { _calls => [] }, 'Slim::Utils::Log' }
sub info     { push @{$_[0]->{_calls}}, ['info',  $_[1]] }
sub warn     { push @{$_[0]->{_calls}}, ['warn',  $_[1]] }
sub error    { push @{$_[0]->{_calls}}, ['error', $_[1]] }
sub debug    { push @{$_[0]->{_calls}}, ['debug', $_[1]] }
sub is_info  { 0 }
sub is_debug { 0 }
sub AUTOLOAD { }
sub can { 1 }
1;
END

write_stub($stub_dir, 'Slim::Utils::Prefs', <<'END');
package Slim::Utils::Prefs;
my %_store;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::preferences"} = \&preferences;
}
sub preferences {
    my $ns = ($_[0] eq 'Slim::Utils::Prefs') ? $_[1] : $_[0];
    return bless { _ns => $ns }, 'Slim::Utils::Prefs';
}
sub init { }
sub get  { $_store{$_[0]->{_ns}}{$_[1]} }
sub set  { $_store{$_[0]->{_ns}}{$_[1]} = $_[2] }
sub client { return bless { _ns => $_[0]->{_ns} . '_client' }, 'Slim::Utils::Prefs' }
sub setChange { }
sub AUTOLOAD { }
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

write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
our @set_calls = ();
sub setTimer   { push @set_calls, [@_] }
sub killTimers { }
1;
END

write_stub($stub_dir, 'JSON::XS::VersionOneAndTwo', <<'END');
package JSON::XS::VersionOneAndTwo;
use parent 'Exporter';
our @EXPORT = qw(from_json to_json);
use JSON::PP ();
sub from_json { JSON::PP::decode_json($_[0]) }
sub to_json   { JSON::PP::encode_json($_[0]) }
1;
END

write_stub($stub_dir, 'Time::HiRes', <<'END');
package Time::HiRes;
use POSIX qw();
sub time  { POSIX::floor(CORE::time()) + 0 }
sub sleep { CORE::sleep($_[1]) }
1;
END

# ============================================================
# Stub: Slim::Networking::SimpleAsyncHTTP
# apresolve.spotify.com always auto-succeeds with a fixed host (host
# resolution is not under test here); every other URL follows $auto_mode.
# ============================================================
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;

our @requests = ();
our $auto_mode = 'success';   # success | error_429 | error_401 | error_404 | error_500
our $auto_response_content = '{}';
our $last_response_headers = {};
our @response_rules = ();     # [ qr/.../, $content ] -- first match wins, most-recently-pushed first
our @error_rules    = ();     # [ qr/.../, $code ]    -- per-URL error injection regardless of $auto_mode

sub set_response_for {
    my ($pattern, $content) = @_;
    unshift @response_rules, [ $pattern, $content ];
}

# set_error_for($pattern, $code)
# Forces the error callback for any URL matching $pattern, regardless of
# $auto_mode -- lets a test make ONE endpoint fail (e.g. metadata/4/show)
# while collection/v2 (a different URL) keeps succeeding via
# set_response_for, needed for the getSavedShows single-item-probe test
# (Plan 04 Task 2).
sub set_error_for {
    my ($pattern, $code) = @_;
    unshift @error_rules, [ $pattern, $code ];
}

sub new {
    my ($class, $success_cb, $error_cb, $opts) = @_;
    return bless { success_cb => $success_cb, error_cb => $error_cb, opts => $opts || {} }, $class;
}

sub get  { _dispatch(shift, 'GET',  @_) }
sub post { _dispatch(shift, 'POST', @_) }

sub _dispatch {
    my ($self, $method, $url, @rest) = @_;

    my $body;
    if (@rest % 2 == 1) {
        $body = pop @rest;
    }
    my %headers = @rest;

    my $entry = {
        method => $method, url => $url, headers => \%headers, body => $body,
        success_cb => $self->{success_cb}, error_cb => $self->{error_cb},
    };
    push @requests, $entry;

    if ($url =~ /apresolve\.spotify\.com/) {
        my $resp = bless { _content => '{"spclient":["test-spclient.example.com:443"]}', _code => 200 },
            'Slim::Networking::SimpleAsyncHTTP::Response';
        $self->{success_cb}->($resp);
        return;
    }

    for my $rule (@error_rules) {
        if ($url =~ $rule->[0]) {
            my $resp = bless { _code => $rule->[1], _headers => {} },
                'Slim::Networking::SimpleAsyncHTTP::MockResponse';
            $self->{error_cb}->($self, "$rule->[1] forced error", $resp);
            return;
        }
    }

    if ($auto_mode eq 'success') {
        my $content = $auto_response_content;
        for my $rule (@response_rules) {
            if ($url =~ $rule->[0]) {
                my $c = $rule->[1];
                if (ref($c) eq 'ARRAY') {
                    # Sequential responses per matching URL (e.g. collection/v2
                    # pagination: page 1 then page 2) -- shift each call,
                    # sticking on the last entry once exhausted.
                    $content = (@$c > 1) ? shift(@$c) : $c->[0];
                }
                elsif (ref($c) eq 'CODE') {
                    # Inspect the request body to decide the response (e.g.
                    # branch on the collection/v2 PageRequest's pagination_token).
                    $content = $c->($body);
                }
                else {
                    $content = $c;
                }
                last;
            }
        }
        my $resp = bless { _content => $content, _code => 200 },
            'Slim::Networking::SimpleAsyncHTTP::Response';
        $self->{success_cb}->($resp);
    }
    elsif ($auto_mode eq 'error_429') {
        my $resp = bless { _code => 429, _headers => $last_response_headers },
            'Slim::Networking::SimpleAsyncHTTP::MockResponse';
        $self->{error_cb}->($self, '429 rate limited', $resp);
    }
    elsif ($auto_mode eq 'error_401') {
        my $resp = bless { _code => 401, _headers => {} },
            'Slim::Networking::SimpleAsyncHTTP::MockResponse';
        $self->{error_cb}->($self, '401 unauthorized', $resp);
    }
    elsif ($auto_mode eq 'error_404') {
        my $resp = bless { _code => 404, _headers => {} },
            'Slim::Networking::SimpleAsyncHTTP::MockResponse';
        $self->{error_cb}->($self, '404 not found', $resp);
    }
    elsif ($auto_mode eq 'error_500') {
        my $resp = bless { _code => 500, _headers => {} },
            'Slim::Networking::SimpleAsyncHTTP::MockResponse';
        $self->{error_cb}->($self, '500 internal error', $resp);
    }
}

sub reset_requests {
    @requests = ();
    $auto_mode = 'success';
    $auto_response_content = '{}';
    $last_response_headers = {};
    @response_rules = ();
    @error_rules = ();
}

sub non_apresolve_requests {
    return grep { $_->{url} !~ /apresolve/ } @requests;
}

package Slim::Networking::SimpleAsyncHTTP::Response;
sub content { $_[0]->{_content} }
sub code    { $_[0]->{_code} }

package Slim::Networking::SimpleAsyncHTTP::MockResponse;
sub code   { $_[0]->{_code} }
sub header { $_[0]->{_headers}{$_[1]} }
sub can    { 1 }
1;
END

# ============================================================
# Stub: Plugins::SpotOn::API::Login5 -- controllable getToken
# ============================================================
write_stub($stub_dir, 'Plugins::SpotOn::API::Login5', <<'END');
package Plugins::SpotOn::API::Login5;
our $mock_token = 'mock_login5_bearer_token';
our $mock_fail_reason = undef;
our @getToken_calls = ();
sub getToken {
    my ($class, $accountId, $cb) = @_;
    push @getToken_calls, $accountId;
    if ($mock_fail_reason) {
        $cb->(undef, $mock_fail_reason);
        return;
    }
    $cb->($mock_token, undef);
}
sub reset_calls { @getToken_calls = () }
1;
END

# ============================================================
# Stub: Plugins::SpotOn::API::Client -- records delegated calls
# ============================================================
write_stub($stub_dir, 'Plugins::SpotOn::API::Client', <<'END');
package Plugins::SpotOn::API::Client;
our @getTrack_calls        = ();
our @getAlbum_calls        = ();
our @getAlbumTracks_calls  = ();
our @getArtist_calls       = ();
our @getArtistAlbums_calls = ();
our @getShow_calls         = ();
our @getShowEpisodes_calls = ();
our @getEpisode_calls      = ();
our @search_calls          = ();
our @getSavedAlbums_calls     = ();
our @getFollowedArtists_calls = ();
our @getSavedShows_calls      = ();
our @getSavedTracks_calls     = ();
our @getRecentlyPlayed_calls  = ();
our @getUserPlaylists_calls   = ();
our @getPlaylistItems_calls   = ();
our $mock_result = { id => 'mockclienttrackid0000' };

sub getTrack {
    my ($class, $accountId, $trackId, $cb) = @_;
    push @getTrack_calls, { accountId => $accountId, trackId => $trackId };
    $cb->($mock_result, undef);
}
sub getAlbum {
    my ($class, $accountId, $albumId, $cb) = @_;
    push @getAlbum_calls, { accountId => $accountId, albumId => $albumId };
    $cb->($mock_result, undef);
}
sub getAlbumTracks {
    my ($class, $accountId, $albumId, $params, $cb) = @_;
    push @getAlbumTracks_calls, { accountId => $accountId, albumId => $albumId, params => $params };
    $cb->($mock_result, undef);
}
sub getArtist {
    my ($class, $accountId, $artistId, $cb) = @_;
    push @getArtist_calls, { accountId => $accountId, artistId => $artistId };
    $cb->($mock_result, undef);
}
sub getArtistAlbums {
    my ($class, $accountId, $artistId, $params, $cb) = @_;
    push @getArtistAlbums_calls, { accountId => $accountId, artistId => $artistId, params => $params };
    $cb->($mock_result, undef);
}
sub getShow {
    my ($class, $accountId, $showId, $cb) = @_;
    push @getShow_calls, { accountId => $accountId, showId => $showId };
    $cb->($mock_result, undef);
}
sub getShowEpisodes {
    my ($class, $accountId, $showId, $params, $cb) = @_;
    push @getShowEpisodes_calls, { accountId => $accountId, showId => $showId, params => $params };
    $cb->($mock_result, undef);
}
sub getEpisode {
    my ($class, $accountId, $episodeId, $cb) = @_;
    push @getEpisode_calls, { accountId => $accountId, episodeId => $episodeId };
    $cb->($mock_result, undef);
}
sub search {
    my ($class, $accountId, $params, $cb) = @_;
    push @search_calls, { accountId => $accountId, params => $params };
    $cb->($mock_result, undef);
}
sub getSavedAlbums {
    my ($class, $accountId, $params, $cb) = @_;
    push @getSavedAlbums_calls, { accountId => $accountId, params => $params };
    $cb->($mock_result, undef);
}
sub getFollowedArtists {
    my ($class, $accountId, $params, $cb) = @_;
    push @getFollowedArtists_calls, { accountId => $accountId, params => $params };
    $cb->($mock_result, undef);
}
sub getSavedShows {
    my ($class, $accountId, $params, $cb) = @_;
    push @getSavedShows_calls, { accountId => $accountId, params => $params };
    $cb->($mock_result, undef);
}
sub getSavedTracks {
    my ($class, $accountId, $params, $cb) = @_;
    push @getSavedTracks_calls, { accountId => $accountId, params => $params };
    $cb->($mock_result, undef);
}
sub getRecentlyPlayed {
    my ($class, $accountId, $params, $cb) = @_;
    push @getRecentlyPlayed_calls, { accountId => $accountId, params => $params };
    $cb->($mock_result, undef);
}
sub getUserPlaylists {
    my ($class, $accountId, $params, $cb) = @_;
    push @getUserPlaylists_calls, { accountId => $accountId, params => $params };
    $cb->($mock_result, undef);
}
sub getPlaylistItems {
    my ($class, $accountId, $playlistId, $params, $cb) = @_;
    push @getPlaylistItems_calls, { accountId => $accountId, playlistId => $playlistId, params => $params };
    $cb->($mock_result, undef);
}
sub reset_calls {
    @getTrack_calls        = ();
    @getAlbum_calls        = ();
    @getAlbumTracks_calls  = ();
    @getArtist_calls       = ();
    @getArtistAlbums_calls = ();
    @getShow_calls         = ();
    @getShowEpisodes_calls = ();
    @getEpisode_calls      = ();
    @search_calls          = ();
    @getSavedAlbums_calls     = ();
    @getFollowedArtists_calls = ();
    @getSavedShows_calls      = ();
    @getSavedTracks_calls     = ();
    @getRecentlyPlayed_calls  = ();
    @getUserPlaylists_calls   = ();
    @getPlaylistItems_calls   = ();
}
1;
END

# ============================================================
# Stub: Plugins::SpotOn::API::Credentials -- controllable verifyCredentials
# ============================================================
write_stub($stub_dir, 'Plugins::SpotOn::API::Credentials', <<'END');
package Plugins::SpotOn::API::Credentials;
our $mock_creds = { username => 'testuser', auth_data => 'ZGF0YQ==' };
sub verifyCredentials {
    my ($class, $accountId) = @_;
    return $mock_creds;
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
    *main::ISWINDOWS   = sub () { 0 };
    *main::ISMAC       = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
}

# M5: SPOTON_CACHE_VERSION is defined in Plugin.pm (single source of truth).
BEGIN {
    package Plugins::SpotOn::Plugin;
    use constant SPOTON_CACHE_VERSION => 4;
}

unshift @INC, $stub_dir, $project_dir;

# SpClient.pm runtime-require's Login5/Client/Credentials only when the code
# path is actually hit (D-03: no compile-time dependency on Client.pm).
# Force-load the stubs up front so reset_all()/test setup can reference their
# package variables/subs before the first getTrack() call.
require_ok('Plugins::SpotOn::API::Login5')      or BAIL_OUT('Failed to load Login5 stub');
require_ok('Plugins::SpotOn::API::Client')      or BAIL_OUT('Failed to load Client stub');
require_ok('Plugins::SpotOn::API::Credentials') or BAIL_OUT('Failed to load Credentials stub');

require_ok('Plugins::SpotOn::API::SpClient')
    or BAIL_OUT('Failed to load SpClient.pm');

my $SP = 'Plugins::SpotOn::API::SpClient';

sub reset_all {
    Slim::Networking::SimpleAsyncHTTP::reset_requests();
    Slim::Utils::Cache->new()->clear();
    $SP->reset();
    Plugins::SpotOn::API::Login5::reset_calls();
    Plugins::SpotOn::API::Client::reset_calls();
    $Plugins::SpotOn::API::Login5::mock_fail_reason = undef;
    $Plugins::SpotOn::API::Credentials::mock_creds  = { username => 'testuser', auth_data => 'ZGF0YQ==' };
}

# ============================================================
# (a) idToHex / hexToId roundtrip + validation
# ============================================================
{
    my @validIds = (
        '4iV5W9uYEdYUVa79Axb7Rh',
        '6y0igZArWVi6Iz0rj35c1Y',
        '3n3Ppam7vgaVa1iaRUc9Lp',
        '7ouMYWpwJ422jRcDASZB7P',
        '1301WleyT98MSxVHPZCA6M',
    );
    for my $id (@validIds) {
        my $hex = $SP->idToHex($id);
        ok(defined $hex, "idToHex succeeds for $id");
        is(length($hex // ''), 32, "idToHex($id) produces 32 hex chars");
        like($hex, qr/^[0-9a-f]{32}$/, "idToHex($id) is lowercase hex");
        is($SP->hexToId($hex), $id, "hexToId(idToHex($id)) round-trips to the original id");
    }

    # All-zeros roundtrip
    my $allZeroB62 = '0' x 22;
    my $allZeroHex = $SP->idToHex($allZeroB62);
    is($allZeroHex, '0' x 32, 'idToHex maps 22 zero-chars to 32 hex zeros');
    is($SP->hexToId($allZeroHex), $allZeroB62, 'hexToId maps 32 hex zeros back to 22 zero-chars');

    # Rejections
    is($SP->idToHex('4iV5W9uYEdYUVa79Axb7R'), undef, 'idToHex rejects a 21-char id (too short)');
    is($SP->idToHex('4iV5W9uYEdYUVa79Axb7R!'), undef, 'idToHex rejects an invalid-charset id');
}

# ============================================================
# (b) creds present -> HTTP request to metadata/4/track/, no Client delegation
# ============================================================
{
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = to_json_fixture();

    my ($result, $err);
    $SP->getTrack('acct1', '4iV5W9uYEdYUVa79Axb7Rh', sub { ($result, $err) = @_ });

    my @nonApresolve = Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@nonApresolve), 1, 'creds-present: exactly one spclient HTTP request made');
    like($nonApresolve[0]->{url}, qr{/metadata/4/track/}, 'creds-present: request URL targets metadata/4/track/');
    is(scalar(@Plugins::SpotOn::API::Client::getTrack_calls), 0, 'creds-present: Client.pm NOT delegated to');
    ok(!$err, 'creds-present: no error');
}

sub to_json_fixture {
    require JSON::XS::VersionOneAndTwo;
    return JSON::XS::VersionOneAndTwo::to_json({
        gid      => 'aa000000000000000000000000000001',
        name     => 'Test Track',
        duration => 210000,
        explicit => 0,
        popularity => 42,
        artist   => [ { gid => 'bb000000000000000000000000000002', name => 'Test Artist' } ],
        album    => {
            gid  => 'cc000000000000000000000000000003',
            name => 'Test Album',
            cover_group => {
                image => [ { file_id => 'deadbeefcafefeed00000000000000000000000', width => 640, height => 640 } ],
            },
        },
    });
}

# ============================================================
# (c) creds absent -> Client.pm delegated exactly once, no HTTP
# ============================================================
{
    reset_all();
    $Plugins::SpotOn::API::Credentials::mock_creds = undef;

    my ($result, $err);
    $SP->getTrack('acct2', '4iV5W9uYEdYUVa79Axb7Rh', sub { ($result, $err) = @_ });

    my @nonApresolve = Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@nonApresolve), 0, 'creds-absent: zero spclient HTTP requests');
    is(scalar(@Plugins::SpotOn::API::Client::getTrack_calls), 1, 'creds-absent (D-06): Client.pm delegated to exactly once');
    is($Plugins::SpotOn::API::Client::getTrack_calls[0]->{accountId}, 'acct2', 'delegated call carries the account id');
}

# ============================================================
# (d) spclient 500 -> Client.pm delegated once, exactly one spclient attempt (D-07, no retry)
# ============================================================
{
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_500';

    my ($result, $err);
    $SP->getTrack('acct3', '4iV5W9uYEdYUVa79Axb7Rh', sub { ($result, $err) = @_ });

    my @nonApresolve = Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@nonApresolve), 1, 'D-07: exactly one spclient HTTP attempt before delegation (no spclient retry)');
    is(scalar(@Plugins::SpotOn::API::Client::getTrack_calls), 1, 'D-07: Client.pm delegated to exactly once on 500');

    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
}

# ============================================================
# (e) 429 -> own rate key set, Client.pm rate key untouched (D-03 isolation)
# ============================================================
{
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_429';
    $Slim::Networking::SimpleAsyncHTTP::last_response_headers = { 'Retry-After' => 30 };

    my ($result, $err);
    $SP->getTrack('acct4', '4iV5W9uYEdYUVa79Axb7Rh', sub { ($result, $err) = @_ });

    my $cache = Slim::Utils::Cache->new();
    ok($cache->get('spoton_spclient_rate_limit'), 'D-03: spoton_spclient_rate_limit set after a spclient 429');
    ok(!$cache->get('spoton_rate_limit'), 'D-03: spoton_rate_limit (Client.pm key) is NOT touched by a spclient 429');

    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
}

# ============================================================
# (f) normalization -> Web-API shape incl. i.scdn.co image URL
# ============================================================
{
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = to_json_fixture();

    my ($result, $err);
    $SP->getTrack('acct5', '4iV5W9uYEdYUVa79Axb7Rh', sub { ($result, $err) = @_ });

    ok($result, 'normalization: result returned');
    is($result->{name}, 'Test Track', 'normalization: name mapped');
    is($result->{duration_ms}, 210000, 'normalization: duration -> duration_ms');
    is($result->{popularity}, 42, 'normalization: popularity passed through (Dev Mode field, additive)');
    is($result->{uri}, 'spotify:track:' . $SP->hexToId('aa000000000000000000000000000001'), 'normalization: track uri derived from gid');
    is($result->{artists}[0]{name}, 'Test Artist', 'normalization: artist name mapped');
    is($result->{album}{name}, 'Test Album', 'normalization: album name mapped');
    like($result->{album}{images}[0]{url}, qr{^https://i\.scdn\.co/image/deadbeefcafefeed}, 'normalization: cover_group image maps to i.scdn.co URL');
    is($result->{album}{images}[0]{width}, 640, 'normalization: image width carried through');
}

# ============================================================
# (g) 401 -> login5 token cache removed, exactly one remint retry
# ============================================================
{
    reset_all();

    # Seed a cached login5 token so we can observe its removal.
    my $cache = Slim::Utils::Cache->new();
    $cache->set('spoton_login5_token_acct6', 'stale_token', 3600);

    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_401';

    my ($result, $err);
    $SP->getTrack('acct6', '4iV5W9uYEdYUVa79Axb7Rh', sub { ($result, $err) = @_ });

    ok(!$cache->get('spoton_login5_token_acct6'), '401: stale login5 token cache key removed');

    my @nonApresolve = Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@nonApresolve), 2, '401: exactly one remint retry (2 spclient HTTP attempts total, D-07a)');
    is(scalar(@Plugins::SpotOn::API::Login5::getToken_calls), 2, '401: login5 getToken called twice (initial + remint)');
    is(scalar(@Plugins::SpotOn::API::Client::getTrack_calls), 1, '401: falls back to Client.pm after the second 401');

    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
}

# ============================================================
# Phase 75 Plan 02 fixtures -- album/artist/show/episode/context-resolve
# ============================================================
sub hexid { sprintf('%032d', $_[0]) }   # 32 decimal-digit chars == valid hex
sub b62id { sprintf('%022d', $_[0]) }   # 22 decimal-digit chars == valid base62

sub album_fixture {
    return JSON::XS::VersionOneAndTwo::to_json({
        gid        => hexid(100),
        name       => 'Test Album',
        artist     => [ { gid => hexid(101), name => 'Test Artist' } ],
        label      => 'Test Label',
        popularity => 55,
        date       => { year => 2020, month => 5, day => 15 },
        cover_group => {
            image => [ { file_id => 'albumcoverfileidxxxxxxxxxxxxxxxxxxxxxx', width => 300, height => 300 } ],
        },
        disc => [
            { number => 1, track => [ { gid => hexid(1) }, { gid => hexid(2) } ] },
            { number => 2, track => [ { gid => hexid(3) } ] },
        ],
    });
}

sub artist_fixture {
    return JSON::XS::VersionOneAndTwo::to_json({
        gid        => hexid(200),
        name       => 'Test Artist Name',
        popularity => 77,
        portrait_group => {
            image => [ { file_id => 'artistportraitfileidxxxxxxxxxxxxxxxxxx', width => 640, height => 640 } ],
        },
        album_group       => [ { album => [ { gid => hexid(10), name => 'Album One' } ] } ],
        single_group      => [ { album => [ { gid => hexid(11), name => 'Single One' } ] } ],
        compilation_group => [],
    });
}

sub show_fixture {
    return JSON::XS::VersionOneAndTwo::to_json({
        gid         => hexid(300),
        name        => 'Test Show',
        description => 'A test show',
        publisher   => 'Test Publisher',
        cover_image => {
            image => [ { file_id => 'showcoverfileidxxxxxxxxxxxxxxxxxxxxxxx', width => 300, height => 300 } ],
        },
        episode => [ { gid => hexid(20) }, { gid => hexid(21) } ],
    });
}

sub episode_fixture {
    return JSON::XS::VersionOneAndTwo::to_json({
        gid      => hexid(20),
        name     => 'Test Episode',
        duration => 1800000,
        explicit => 0,
        date     => { year => 2021, month => 3, day => 10 },
        cover_group => {
            image => [ { file_id => 'episodecoverfileidxxxxxxxxxxxxxxxxxxxx', width => 300, height => 300 } ],
        },
    });
}

sub context_resolve_fixture {
    my @tracks = map { { uri => 'spotify:track:' . b62id($_) } } (1 .. 20);
    return JSON::XS::VersionOneAndTwo::to_json({
        pages => [ { tracks => \@tracks } ],
        uri   => 'spotify:search:radiohead',
        url   => 'context://spotify:search:radiohead',
    });
}

# ============================================================
# Task 1: Album + artist endpoints with track-name enrichment (S-04)
# ============================================================

# getAlbum: normalized shape incl. label/popularity (Dev-Mode value-add) and
# empty tracks.items (S-04 -- names live in getAlbumTracks, not here).
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/album/}, album_fixture());

    my ($result, $err);
    $SP->getAlbum('acct10', '4iV5W9uYEdYUVa79Axb7Rh', sub { ($result, $err) = @_ });

    ok($result, 'getAlbum: result returned');
    is($result->{name}, 'Test Album', 'getAlbum: name mapped');
    is($result->{label}, 'Test Label', 'getAlbum: label present (Dev-Mode value-add)');
    is($result->{popularity}, 55, 'getAlbum: popularity present (Dev-Mode value-add)');
    is($result->{release_date}, '2020-05-15', 'getAlbum: release_date formatted YYYY-MM-DD');
    is($result->{artists}[0]{name}, 'Test Artist', 'getAlbum: artist name mapped');
    is($result->{total_tracks}, 3, 'getAlbum: total_tracks flattened from disc/track counts');
    is(scalar(@{ $result->{tracks}{items} }), 0, 'getAlbum: tracks.items intentionally empty (S-04)');
    like($result->{images}[0]{url}, qr{^https://i\.scdn\.co/image/albumcoverfileid}, 'getAlbum: cover_group image mapped');
    is(scalar(@Plugins::SpotOn::API::Client::getAlbum_calls), 0, 'getAlbum: Client.pm NOT delegated to on success');
}

# getAlbum D-07 fallback (proves _spFacade's shared error path -- other new
# methods below reuse this exact helper without a duplicate 500 test each).
{
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_500';

    my ($result, $err);
    $SP->getAlbum('acct15', '4iV5W9uYEdYUVa79Axb7Rh', sub { ($result, $err) = @_ });

    is(scalar(@Plugins::SpotOn::API::Client::getAlbum_calls), 1,
        'getAlbum D-07: falls back to Client.pm on a spclient 500 (shared _spFacade helper)');

    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
}

# getAlbumTracks: lazy slice -- exactly limit-many (2 of 3) enrichment calls.
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/album/}, album_fixture());
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/track/}, to_json_fixture());

    my ($result, $err);
    $SP->getAlbumTracks('acct11', '4iV5W9uYEdYUVa79Axb7Rh', { offset => 0, limit => 2 }, sub { ($result, $err) = @_ });

    ok($result, 'getAlbumTracks: result returned');
    is($result->{total}, 3, 'getAlbumTracks: total reflects the full flattened disc/track count (3), not the slice');
    is(scalar(@{ $result->{items} }), 2, 'getAlbumTracks: only the requested slice (2) is returned');

    my @trackReqs = grep { $_->{url} =~ m{/metadata/4/track/} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@trackReqs), 2, 'getAlbumTracks: exactly limit-many (2) metadata/4/track enrichment requests -- lazy slice, not all 3');
    is($result->{items}[0]{name}, 'Test Track', 'getAlbumTracks: enriched item carries the Web-API track shape');
}

# getAlbumTracks: D-09 cache reuse -- a second identical call issues zero
# additional HTTP requests (album metadata + per-track enrichment all cache hits).
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/album/}, album_fixture());
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/track/}, to_json_fixture());

    my $noop = sub { };
    $SP->getAlbumTracks('acct12', '4iV5W9uYEdYUVa79Axb7Rh', { offset => 0, limit => 2 }, $noop);
    my $firstCount = scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests());

    $SP->getAlbumTracks('acct12', '4iV5W9uYEdYUVa79Axb7Rh', { offset => 0, limit => 2 }, $noop);
    my $secondCount = scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests());

    is($secondCount, $firstCount,
        'D-09: repeated getAlbumTracks for the same album+slice issues zero additional HTTP requests (response cache hits)');
}

# getArtist: normalized shape incl. portrait_group images, empty genres.
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/artist/}, artist_fixture());

    my ($result, $err);
    $SP->getArtist('acct13', '4iV5W9uYEdYUVa79Axb7Rh', sub { ($result, $err) = @_ });

    ok($result, 'getArtist: result returned');
    is($result->{name}, 'Test Artist Name', 'getArtist: name mapped');
    is($result->{popularity}, 77, 'getArtist: popularity mapped');
    like($result->{images}[0]{url}, qr{^https://i\.scdn\.co/image/artistportraitfileid}, 'getArtist: portrait_group image mapped');
    is_deeply($result->{genres}, [], 'getArtist: genres always empty array');
}

# getArtist D-06: no login5-capable creds -> immediate Client.pm delegation, zero HTTP.
{
    reset_all();
    $Plugins::SpotOn::API::Credentials::mock_creds = undef;

    my ($result, $err);
    $SP->getArtist('acct16', '4iV5W9uYEdYUVa79Axb7Rh', sub { ($result, $err) = @_ });

    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 0, 'getArtist D-06: zero spclient HTTP when creds absent');
    is(scalar(@Plugins::SpotOn::API::Client::getArtist_calls), 1, 'getArtist D-06: delegates to Client.pm exactly once when creds absent');

    $Plugins::SpotOn::API::Credentials::mock_creds = { username => 'testuser', auth_data => 'ZGF0YQ==' };
}

# getArtistAlbums: album_group + single_group flattening, no per-album metadata calls.
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/artist/}, artist_fixture());

    my ($result, $err);
    $SP->getArtistAlbums('acct14', '4iV5W9uYEdYUVa79Axb7Rh', {}, sub { ($result, $err) = @_ });

    ok($result, 'getArtistAlbums: result returned');
    is($result->{total}, 2, 'getArtistAlbums: album_group + single_group flattened to 2 total');
    is($result->{items}[0]{name}, 'Album One', 'getArtistAlbums: album_group entry name preserved');
    is($result->{items}[1]{name}, 'Single One', 'getArtistAlbums: single_group entry name preserved');

    my @metaReqs = grep { $_->{url} =~ m{/metadata/4/} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@metaReqs), 1, 'getArtistAlbums: exactly one metadata call total -- no per-album enrichment calls');
}

# ============================================================
# Task 2: Show + episode endpoints with D-07 safety net
# ============================================================

# getShow: normalized shape.
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/show/}, show_fixture());

    my ($result, $err);
    $SP->getShow('acct20', '4iV5W9uYEdYUVa79Axb7Rh', sub { ($result, $err) = @_ });

    ok($result, 'getShow: result returned');
    is($result->{name}, 'Test Show', 'getShow: name mapped');
    is($result->{publisher}, 'Test Publisher', 'getShow: publisher mapped');
    is($result->{total_episodes}, 2, 'getShow: total_episodes counted from embedded episode gid list');
    like($result->{images}[0]{url}, qr{^https://i\.scdn\.co/image/showcoverfileid}, 'getShow: cover_image mapped');
}

# getShow: forced 404 (spike-unverified endpoint) -> exactly one spclient
# attempt then Client.pm delegation (explicit D-07 safety-net test).
{
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_404';

    my ($result, $err);
    $SP->getShow('acct21', '4iV5W9uYEdYUVa79Axb7Rh', sub { ($result, $err) = @_ });

    my @nonApresolve = Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@nonApresolve), 1, 'getShow 404: exactly one spclient attempt (spike-unverified endpoint, D-07 safety net)');
    is(scalar(@Plugins::SpotOn::API::Client::getShow_calls), 1, 'getShow 404: falls back to Client.pm exactly once');

    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
}

# getShowEpisodes: slice + per-episode enrichment.
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/show/}, show_fixture());
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/episode/}, episode_fixture());

    my ($result, $err);
    $SP->getShowEpisodes('acct22', '4iV5W9uYEdYUVa79Axb7Rh', { offset => 0, limit => 50 }, sub { ($result, $err) = @_ });

    ok($result, 'getShowEpisodes: result returned');
    is($result->{total}, 2, 'getShowEpisodes: total reflects embedded episode gid count');
    is(scalar(@{ $result->{items} }), 2, 'getShowEpisodes: both episodes enriched (within limit)');
    is($result->{items}[0]{name}, 'Test Episode', 'getShowEpisodes: enriched episode carries name');
    is($result->{items}[0]{duration_ms}, 1800000, 'getShowEpisodes: normalized episode contains duration_ms');
    is($result->{items}[0]{release_date}, '2021-03-10', 'getShowEpisodes: normalized episode contains release_date');
}

# getEpisode: single-object fetch.
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/episode/}, episode_fixture());

    my ($result, $err);
    $SP->getEpisode('acct23', '4iV5W9uYEdYUVa79Axb7Rh', sub { ($result, $err) = @_ });

    ok($result, 'getEpisode: result returned');
    is($result->{name}, 'Test Episode', 'getEpisode: name mapped');
    is($result->{duration_ms}, 1800000, 'getEpisode: duration_ms mapped');
    is($result->{release_date}, '2021-03-10', 'getEpisode: release_date mapped');
}

# ============================================================
# Task 3: Search router -- context-resolve for track search, Client.pm for
# multi-type / deep-offset (S-05)
# ============================================================

# (a) type=track, offset=0 -> context-resolve, lazy enrichment, Web-API tracks.items shape.
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/context-resolve/}, context_resolve_fixture());
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/track/}, to_json_fixture());

    my ($result, $err);
    $SP->search('acct30', { q => 'radiohead', type => 'track', offset => 0, limit => 5 }, sub { ($result, $err) = @_ });

    my @ctxReqs = grep { $_->{url} =~ m{/context-resolve/} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@ctxReqs), 1, 'search track offset0: exactly one context-resolve request issued');
    unlike($ctxReqs[0]->{url}, qr/offset=/, 'search track offset0: context-resolve request never sends an offset query param');

    my @trackReqs = grep { $_->{url} =~ m{/metadata/4/track/} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@trackReqs), 5, 'search track offset0: enrichment for min(limit,20)=5 ids');

    ok($result, 'search track offset0: result returned');
    is($result->{tracks}{total}, 20, 'search track offset0: total reflects the full 20-uri context-resolve window');
    is(scalar(@{ $result->{tracks}{items} }), 5, 'search track offset0: tracks.items sliced to limit');
    is(scalar(@Plugins::SpotOn::API::Client::search_calls), 0, 'search track offset0: Client.pm NOT delegated to');
}

# (b) type=album -> Client.pm delegation, zero spclient HTTP (S-05: no multi-type search).
{
    reset_all();

    my ($result, $err);
    $SP->search('acct31', { q => 'radiohead', type => 'album' }, sub { ($result, $err) = @_ });

    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 0, 'search type=album: zero spclient HTTP calls');
    is(scalar(@Plugins::SpotOn::API::Client::search_calls), 1, 'search type=album: delegates to Client.pm exactly once (S-05)');
}

# (c) type=track, offset=20 -> Client.pm delegation, zero spclient HTTP (offset at the ceiling).
{
    reset_all();

    my ($result, $err);
    $SP->search('acct32', { q => 'radiohead', type => 'track', offset => 20, limit => 10 }, sub { ($result, $err) = @_ });

    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 0,
        'search track offset20: zero spclient HTTP -- offset at the context-resolve ceiling short-circuits before any request');
    is(scalar(@Plugins::SpotOn::API::Client::search_calls), 1,
        'search track offset20: delegates to Client.pm exactly once (S-05 deep-offset paging)');
}

# (d) context-resolve 500 -> Client.pm delegation (D-07).
{
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_500';

    my ($result, $err);
    $SP->search('acct33', { q => 'radiohead', type => 'track', offset => 0, limit => 10 }, sub { ($result, $err) = @_ });

    my @nonApresolve = Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@nonApresolve), 1, 'search context-resolve 500: exactly one spclient attempt');
    is(scalar(@Plugins::SpotOn::API::Client::search_calls), 1, 'search context-resolve 500: falls back to Client.pm exactly once (D-07)');

    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
}

# ============================================================
# Phase 75 Plan 04 fixtures -- collection/v2 (Task 1)
# ============================================================

sub encode_collection_item {
    my (%args) = @_;
    my $bytes = '';
    $bytes .= Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $args{uri})
        if defined $args{uri};
    $bytes .= Plugins::SpotOn::API::ProtobufLite::encode_field(2, 0, $args{added_at})
        if defined $args{added_at};
    $bytes .= Plugins::SpotOn::API::ProtobufLite::encode_field(3, 0, 1)
        if $args{is_removed};
    return $bytes;
}

sub encode_page_response {
    my (%args) = @_;
    my $bytes = '';
    for my $item (@{ $args{items} || [] }) {
        $bytes .= Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, encode_collection_item(%$item));
    }
    $bytes .= Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, $args{next_page_token})
        if defined $args{next_page_token} && length $args{next_page_token};
    return $bytes;
}

# ============================================================
# Task 1: collection/v2 plumbing + getSavedAlbums (S-06/S-07, A1)
# ============================================================

# (a) wire-level: Content-Type + Accept exact CT string, body decodes to
# username/set/limit via ProtobufLite (S-06).
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/collection/v2/paging}, encode_page_response(
        items => [ { uri => 'spotify:album:' . b62id(1), added_at => 10 } ],
    ));
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/album/}, album_fixture());

    my ($result, $err);
    $SP->getSavedAlbums('acct60', {}, sub { ($result, $err) = @_ });

    my @collReqs = grep { $_->{url} =~ m{/collection/v2/paging} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@collReqs), 1, 'getSavedAlbums: exactly one collection/v2/paging POST');
    is($collReqs[0]->{headers}{'Content-Type'}, 'application/vnd.collection-v2.spotify.proto',
        'collection/v2: Content-Type is the exact vendor string (S-06)');
    is($collReqs[0]->{headers}{'Accept'}, 'application/vnd.collection-v2.spotify.proto',
        'collection/v2: Accept is the exact vendor string (S-06)');

    my $reqFields = Plugins::SpotOn::API::ProtobufLite::parse_fields($collReqs[0]->{body});
    is(Plugins::SpotOn::API::ProtobufLite::field_first($reqFields, 1), 'testuser',
        'collection/v2 body: field 1 (username) decodes from credentials.json username');
    is(Plugins::SpotOn::API::ProtobufLite::field_first($reqFields, 2), 'collection',
        'collection/v2 body: field 2 (set) is "collection" for Saved Albums (S-07)');
    is($SP->SET_MAP->{albums}, 'collection', 'SET_MAP: albums maps to the verified "collection" set name (S-07)');
    is(Plugins::SpotOn::API::ProtobufLite::field_first($reqFields, 4), 200,
        'collection/v2 body: field 4 (limit) is 200');
    ok(!defined(Plugins::SpotOn::API::ProtobufLite::field_first($reqFields, 3)),
        'collection/v2 body: field 3 (pagination_token) omitted entirely on the first page');
}

# (b) pagination: 2 pages, >=4 items total, all present in order (A1 --
# repeated-field decode across multiple pages).
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/collection/v2/paging}, sub {
        my ($body) = @_;
        my $fields = Plugins::SpotOn::API::ProtobufLite::parse_fields($body);
        my $token  = Plugins::SpotOn::API::ProtobufLite::field_first($fields, 3);
        if (!defined $token || $token eq '') {
            return encode_page_response(
                items => [
                    { uri => 'spotify:album:' . b62id(1), added_at => 10 },
                    { uri => 'spotify:album:' . b62id(2), added_at => 11 },
                ],
                next_page_token => 'page2token',
            );
        }
        return encode_page_response(
            items => [
                { uri => 'spotify:album:' . b62id(3), added_at => 12 },
                { uri => 'spotify:album:' . b62id(4), added_at => 13 },
            ],
        );
    });
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/album/}, album_fixture());

    my ($result, $err);
    $SP->getSavedAlbums('acct61', { offset => 0, limit => 10 }, sub { ($result, $err) = @_ });

    my @collReqs = grep { $_->{url} =~ m{/collection/v2/paging} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@collReqs), 2, 'pagination: exactly 2 collection/v2 POSTs (page 1 + page 2)');

    ok($result, 'pagination: result returned');
    is($result->{total}, 4, 'pagination: total reflects all 4 items across both pages');
    is(scalar(@{ $result->{items} }), 4, 'pagination: all 4 items surfaced in the enriched slice');
}

# (c) is_removed tombstones are filtered out at the wire-decode level.
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/collection/v2/paging}, encode_page_response(
        items => [
            { uri => 'spotify:album:' . b62id(1), added_at => 10 },
            { uri => 'spotify:album:' . b62id(2), added_at => 11, is_removed => 1 },
        ],
    ));
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/album/}, album_fixture());

    my ($result, $err);
    $SP->getSavedAlbums('acct62', {}, sub { ($result, $err) = @_ });

    ok($result, 'is_removed: result returned');
    is($result->{total}, 1, 'is_removed: tombstoned item excluded from the total (1 of 2 survives)');
}

# (d) D-09: second getSavedAlbums call within TTL issues zero additional
# collection/v2 POSTs (list-level cache).
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/collection/v2/paging}, encode_page_response(
        items => [ { uri => 'spotify:album:' . b62id(1), added_at => 10 } ],
    ));
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/album/}, album_fixture());

    my $noop = sub { };
    $SP->getSavedAlbums('acct63', {}, $noop);
    my $firstCollCount = scalar(grep { $_->{url} =~ m{/collection/v2/paging} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests());

    $SP->getSavedAlbums('acct63', {}, $noop);
    my $secondCollCount = scalar(grep { $_->{url} =~ m{/collection/v2/paging} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests());

    is($firstCollCount, 1, 'D-09: first getSavedAlbums call issues one collection/v2 POST');
    is($secondCollCount, $firstCollCount, 'D-09: second getSavedAlbums call within TTL issues zero additional collection/v2 POSTs');
}

# getSavedAlbums D-06/D-07 router regressions (shared _collectionAll/_isFallbackError path).
{
    reset_all();
    $Plugins::SpotOn::API::Credentials::mock_creds = undef;

    my ($result, $err);
    $SP->getSavedAlbums('acct64', {}, sub { ($result, $err) = @_ });

    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 0, 'getSavedAlbums D-06: zero spclient HTTP when creds absent');
    is(scalar(@Plugins::SpotOn::API::Client::getSavedAlbums_calls), 1, 'getSavedAlbums D-06: delegates to Client.pm exactly once');

    $Plugins::SpotOn::API::Credentials::mock_creds = { username => 'testuser', auth_data => 'ZGF0YQ==' };
}
{
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_500';

    my ($result, $err);
    $SP->getSavedAlbums('acct65', {}, sub { ($result, $err) = @_ });

    is(scalar(@Plugins::SpotOn::API::Client::getSavedAlbums_calls), 1, 'getSavedAlbums D-07: falls back to Client.pm on a spclient 500');

    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
}

# ============================================================
# Task 2: getFollowedArtists + getSavedShows on collection sets
# ============================================================

# Cursor-emulation walk over a 3-artist fixture across 2 sequential calls.
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/collection/v2/paging}, encode_page_response(
        items => [
            { uri => 'spotify:artist:' . b62id(1), added_at => 1 },
            { uri => 'spotify:artist:' . b62id(2), added_at => 2 },
            { uri => 'spotify:artist:' . b62id(3), added_at => 3 },
        ],
    ));
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/artist/}, artist_fixture());

    my ($result1, $err1);
    $SP->getFollowedArtists('acct70', { limit => 2 }, sub { ($result1, $err1) = @_ });

    ok($result1, 'cursor walk (1): result returned');
    is(scalar(@{ $result1->{artists}{items} }), 2, 'cursor walk (1): first call returns 2 of 3 artists');
    is($result1->{artists}{total}, 3, 'cursor walk (1): total reflects the full 3-artist list');
    ok(defined($result1->{artists}{cursors}{after}), 'cursor walk (1): cursors.after is set (more remain)');
    is($result1->{artists}{cursors}{after}, b62id(2), 'cursor walk (1): cursors.after is the id of the last returned artist');

    my ($result2, $err2);
    $SP->getFollowedArtists('acct70', { after => $result1->{artists}{cursors}{after}, limit => 2 }, sub { ($result2, $err2) = @_ });

    ok($result2, 'cursor walk (2): result returned');
    is(scalar(@{ $result2->{artists}{items} }), 1, 'cursor walk (2): second call returns the remaining 1 artist');
    ok(!defined($result2->{artists}{cursors}{after}), 'cursor walk (2): cursors.after is undef -- terminating cursor (exhausted)');

    my @collReqs = grep { $_->{url} =~ m{/collection/v2/paging} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@collReqs), 1, 'cursor walk: both calls share the same cached collection/v2 list (one POST total)');
}

# getFollowedArtists D-06 router regression: PKCE-only account -> Client stub
# records the call, zero spclient HTTP.
{
    reset_all();
    $Plugins::SpotOn::API::Credentials::mock_creds = undef;

    my ($result, $err);
    $SP->getFollowedArtists('acct71', {}, sub { ($result, $err) = @_ });

    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 0, 'getFollowedArtists D-06: zero spclient HTTP when creds absent');
    is(scalar(@Plugins::SpotOn::API::Client::getFollowedArtists_calls), 1, 'getFollowedArtists D-06: delegates to Client.pm exactly once');

    $Plugins::SpotOn::API::Credentials::mock_creds = { username => 'testuser', auth_data => 'ZGF0YQ==' };
}

# getSavedShows: items nest under a show key (Web-API shape).
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/collection/v2/paging}, encode_page_response(
        items => [
            { uri => 'spotify:show:' . b62id(1), added_at => 5 },
            { uri => 'spotify:show:' . b62id(2), added_at => 6 },
        ],
    ));
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/show/}, show_fixture());

    my ($result, $err);
    $SP->getSavedShows('acct72', { offset => 0, limit => 50 }, sub { ($result, $err) = @_ });

    ok($result, 'getSavedShows: result returned');
    is($result->{total}, 2, 'getSavedShows: total reflects both collection items');
    is(scalar(@{ $result->{items} }), 2, 'getSavedShows: both items enriched');
    is($result->{items}[0]{show}{name}, 'Test Show', 'getSavedShows: item nests the normalized show under a "show" key (Web-API shape)');
    ok(exists $result->{items}[0]{added_at}, 'getSavedShows: item carries added_at from the collection entry');
}

# getSavedShows: probe-detected degenerate metadata/4/show -> the WHOLE call
# delegates to Client.pm in one shot (not N per-item fallbacks).
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/collection/v2/paging}, encode_page_response(
        items => [
            { uri => 'spotify:show:' . b62id(1), added_at => 5 },
            { uri => 'spotify:show:' . b62id(2), added_at => 6 },
        ],
    ));
    Slim::Networking::SimpleAsyncHTTP::set_error_for(qr{/metadata/4/show/}, 404);

    my ($result, $err);
    $SP->getSavedShows('acct73', { offset => 0, limit => 50 }, sub { ($result, $err) = @_ });

    my @showMetaReqs = grep { $_->{url} =~ m{/metadata/4/show/} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@showMetaReqs), 1, 'getSavedShows probe: exactly one metadata/4/show attempt (the probe), not N per-item fallbacks');
    is(scalar(@Plugins::SpotOn::API::Client::getSavedShows_calls), 1, 'getSavedShows probe: delegates the WHOLE call to Client.pm exactly once');
}

# getSavedShows D-06 router regression: PKCE-only account -> Client stub
# records the call, zero spclient HTTP.
{
    reset_all();
    $Plugins::SpotOn::API::Credentials::mock_creds = undef;

    my ($result, $err);
    $SP->getSavedShows('acct74', {}, sub { ($result, $err) = @_ });

    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 0, 'getSavedShows D-06: zero spclient HTTP when creds absent');
    is(scalar(@Plugins::SpotOn::API::Client::getSavedShows_calls), 1, 'getSavedShows D-06: delegates to Client.pm exactly once');

    $Plugins::SpotOn::API::Credentials::mock_creds = { username => 'testuser', auth_data => 'ZGF0YQ==' };
}

# ============================================================
# Phase 75 Plan 04 fixtures -- context-resolve (liked songs), recently-played
# (protobuf), Task 3
# ============================================================

sub encode_context {
    my (%args) = @_;
    my $bytes = '';
    $bytes .= Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $args{uri})
        if defined $args{uri};
    $bytes .= Plugins::SpotOn::API::ProtobufLite::encode_field(2, 0, $args{lastPlayedTime})
        if defined $args{lastPlayedTime};
    return $bytes;
}

sub encode_recently_played {
    my (@contexts) = @_;
    my $bytes = '';
    for my $c (@contexts) {
        $bytes .= Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, encode_context(%$c));
    }
    return $bytes;
}

sub liked_songs_fixture {
    my ($n) = @_;
    my @tracks = map { { uri => 'spotify:track:' . b62id($_) } } (1 .. $n);
    return JSON::XS::VersionOneAndTwo::to_json({
        pages => [ { tracks => \@tracks } ],
        uri   => 'spotify:user:testuser:collection',
        url   => 'context://spotify:user:testuser:collection',
    });
}

# ============================================================
# Task 3: getSavedTracks (Liked Songs, no paging) + getRecentlyPlayed (S-09)
# ============================================================

# Liked-songs fixture (25 URIs), offset=10/limit=10 -> exactly 10 enrichment
# calls, total=25 (the full list, not the slice -- S-04 no-paging win).
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/context-resolve/v1/spotify:user:}, liked_songs_fixture(25));
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/track/}, to_json_fixture());

    my ($result, $err);
    $SP->getSavedTracks('acct80', { offset => 10, limit => 10 }, sub { ($result, $err) = @_ });

    ok($result, 'getSavedTracks: result returned');
    is($result->{total}, 25, 'getSavedTracks: total reflects the FULL liked-songs list (25), not the slice');
    is(scalar(@{ $result->{items} }), 10, 'getSavedTracks: items sliced to the requested limit (10)');

    my @trackReqs = grep { $_->{url} =~ m{/metadata/4/track/} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@trackReqs), 10, 'getSavedTracks: exactly limit-many (10) enrichment calls -- sliced, not all 25');
    is($result->{items}[0]{track}{name}, 'Test Track', 'getSavedTracks: item wraps the enriched track under a "track" key (Web-API shape)');
}

# getSavedTracks D-06/D-07 router regressions.
{
    reset_all();
    $Plugins::SpotOn::API::Credentials::mock_creds = undef;

    my ($result, $err);
    $SP->getSavedTracks('acct81', {}, sub { ($result, $err) = @_ });

    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 0, 'getSavedTracks D-06: zero spclient HTTP when creds absent');
    is(scalar(@Plugins::SpotOn::API::Client::getSavedTracks_calls), 1, 'getSavedTracks D-06: delegates to Client.pm exactly once');

    $Plugins::SpotOn::API::Credentials::mock_creds = { username => 'testuser', auth_data => 'ZGF0YQ==' };
}
{
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_500';

    my ($result, $err);
    $SP->getSavedTracks('acct82', {}, sub { ($result, $err) = @_ });

    is(scalar(@Plugins::SpotOn::API::Client::getSavedTracks_calls), 1, 'getSavedTracks D-07: falls back to Client.pm on a context-resolve 500');

    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
}

# Username-source test (A5): prefs spotifyUserId differs from the
# credentials.json username -- the request URL must use the CREDENTIALS
# username, never the prefs value.
{
    reset_all();
    $Plugins::SpotOn::API::Credentials::mock_creds = { username => 'crealuser123', auth_data => 'ZGF0YQ==' };
    Slim::Utils::Prefs::preferences('plugin.spoton')->set('spotifyUserId', 'wrongprefsid999');
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/context-resolve/v1/spotify:user:}, liked_songs_fixture(1));

    my ($result, $err);
    $SP->getSavedTracks('acct83', {}, sub { ($result, $err) = @_ });

    my @ctxReqs = grep { $_->{url} =~ m{/context-resolve/v1/spotify:user:} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@ctxReqs), 1, 'username-source: exactly one context-resolve request');
    like($ctxReqs[0]->{url}, qr{spotify:user:crealuser123:collection}, 'username-source (A5): URL uses the credentials.json username');
    unlike($ctxReqs[0]->{url}, qr{wrongprefsid999}, 'username-source (A5): URL never contains the prefs spotifyUserId value');

    $Plugins::SpotOn::API::Credentials::mock_creds = { username => 'testuser', auth_data => 'ZGF0YQ==' };
}

# getRecentlyPlayed: protobuf fixture with 2 track contexts + 1 playlist
# context -> exactly 2 track items out, non-track context filtered,
# lastPlayedTime decoded via multi-byte varint (epoch-ms values need >5 bytes).
{
    reset_all();
    my $rpFixture = encode_recently_played(
        { uri => 'spotify:track:' . b62id(1),    lastPlayedTime => 1_700_000_000_123 },
        { uri => 'spotify:playlist:' . b62id(2), lastPlayedTime => 1_700_000_000_456 },
        { uri => 'spotify:track:' . b62id(3),    lastPlayedTime => 1_700_000_000_789 },
    );
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/recently-played/v3/}, $rpFixture);
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/track/}, to_json_fixture());

    my ($result, $err);
    $SP->getRecentlyPlayed('acct84', {}, sub { ($result, $err) = @_ });

    ok($result, 'getRecentlyPlayed: result returned');
    is(scalar(@{ $result->{items} }), 2, 'getRecentlyPlayed: filters out the non-track (playlist) context -- 2 of 3 contexts survive');
    is($result->{items}[0]{played_at}, 1_700_000_000_123, 'getRecentlyPlayed: lastPlayedTime decoded correctly via multi-byte varint');
    is($result->{items}[1]{played_at}, 1_700_000_000_789, 'getRecentlyPlayed: second track context lastPlayedTime decoded correctly');

    my @recentReqs = grep { $_->{url} =~ m{/recently-played/v3/} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    like($recentReqs[0]->{url}, qr{/user/testuser/}, 'getRecentlyPlayed: URL uses the credentials.json username');
}

# getRecentlyPlayed D-06/D-07 router regressions.
{
    reset_all();
    $Plugins::SpotOn::API::Credentials::mock_creds = undef;

    my ($result, $err);
    $SP->getRecentlyPlayed('acct85', {}, sub { ($result, $err) = @_ });

    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 0, 'getRecentlyPlayed D-06: zero spclient HTTP when creds absent');
    is(scalar(@Plugins::SpotOn::API::Client::getRecentlyPlayed_calls), 1, 'getRecentlyPlayed D-06: delegates to Client.pm exactly once');

    $Plugins::SpotOn::API::Credentials::mock_creds = { username => 'testuser', auth_data => 'ZGF0YQ==' };
}
{
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_500';

    my ($result, $err);
    $SP->getRecentlyPlayed('acct86', {}, sub { ($result, $err) = @_ });

    is(scalar(@Plugins::SpotOn::API::Client::getRecentlyPlayed_calls), 1, 'getRecentlyPlayed D-07: falls back to Client.pm on a spclient 500');

    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
}

# ============================================================
# Phase 75 Plan 05 fixtures -- rootlist (protobuf, nested
# Folder/Item/Playlist tree), Task 1
# ============================================================

# encode_user(%args): User submessage (username=2, display_name=3)
sub encode_user {
    my (%args) = @_;
    my $bytes = '';
    $bytes .= Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, $args{username})
        if defined $args{username};
    $bytes .= Plugins::SpotOn::API::ProtobufLite::encode_field(3, 2, $args{display_name})
        if defined $args{display_name};
    return $bytes;
}

# encode_playlist_metadata(%args): link=1, name=2, owner=3 (User submessage)
sub encode_playlist_metadata {
    my (%args) = @_;
    my $bytes = '';
    $bytes .= Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $args{link})
        if defined $args{link};
    $bytes .= Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, $args{name})
        if defined $args{name};
    if ($args{owner}) {
        $bytes .= Plugins::SpotOn::API::ProtobufLite::encode_field(3, 2, encode_user(%{ $args{owner} }));
    }
    return $bytes;
}

# encode_rootlist_playlist(%args): row_id=1, playlist_metadata=2
sub encode_rootlist_playlist {
    my (%args) = @_;
    my $bytes = '';
    $bytes .= Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $args{row_id})
        if defined $args{row_id};
    if ($args{metadata}) {
        $bytes .= Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, encode_playlist_metadata(%{ $args{metadata} }));
    }
    return $bytes;
}

# encode_rootlist_item(%args): folder=2 OR playlist=3
sub encode_rootlist_item {
    my (%args) = @_;
    my $bytes = '';
    $bytes .= Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, $args{folder})
        if defined $args{folder};
    $bytes .= Plugins::SpotOn::API::ProtobufLite::encode_field(3, 2, $args{playlist})
        if defined $args{playlist};
    return $bytes;
}

# encode_rootlist_folder(@itemBytesList): item=1 (repeated)
sub encode_rootlist_folder {
    my (@itemBytesList) = @_;
    my $bytes = '';
    $bytes .= Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $_) for @itemBytesList;
    return $bytes;
}

# encode_rootlist_response($rootFolderBytes): root=1
sub encode_rootlist_response {
    my ($rootFolderBytes) = @_;
    return Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $rootFolderBytes);
}

# ============================================================
# Task 1: getUserPlaylists via rootlist (protobuf-only, S-10)
# ============================================================

# Nested-folder fixture: 2 top-level playlists + 1 folder containing 1
# playlist -> all 3 surface flattened, in tree order, with the folder's
# playlist last.
{
    reset_all();

    my $pl1 = encode_rootlist_playlist(
        row_id   => 'spotify:playlist:' . b62id(1),
        metadata => { name => 'Top Playlist One', owner => { username => 'testuser', display_name => 'Test User' } },
    );
    my $pl2 = encode_rootlist_playlist(
        row_id   => 'spotify:playlist:' . b62id(2),
        metadata => { name => 'Top Playlist Two', owner => { username => 'testuser', display_name => 'Test User' } },
    );
    my $pl3 = encode_rootlist_playlist(
        row_id   => 'spotify:playlist:' . b62id(3),
        metadata => { name => 'Nested Playlist Three', owner => { username => 'testuser', display_name => 'Test User' } },
    );

    my $subFolder  = encode_rootlist_folder(encode_rootlist_item(playlist => $pl3));
    my $rootFolder = encode_rootlist_folder(
        encode_rootlist_item(playlist => $pl1),
        encode_rootlist_item(playlist => $pl2),
        encode_rootlist_item(folder   => $subFolder),
    );
    my $rootlistBytes = encode_rootlist_response($rootFolder);

    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/playlist/v2/user/.+/rootlist}, $rootlistBytes);

    my ($result, $err);
    $SP->getUserPlaylists('acct90', {}, sub { ($result, $err) = @_ });

    ok($result, 'getUserPlaylists: result returned');
    is($result->{total}, 3, 'getUserPlaylists: nested-folder fixture flattens to 3 playlists');
    is(scalar(@{ $result->{items} }), 3, 'getUserPlaylists: all 3 items present in the sliced page');
    is($result->{items}[0]{uri}, 'spotify:playlist:' . b62id(1), 'getUserPlaylists: playlist 1 uri preserved (tree order)');
    is($result->{items}[1]{uri}, 'spotify:playlist:' . b62id(2), 'getUserPlaylists: playlist 2 uri preserved (tree order)');
    is($result->{items}[2]{uri}, 'spotify:playlist:' . b62id(3), 'getUserPlaylists: nested playlist surfaces flattened, after the top-level items');
    is($result->{items}[2]{name}, 'Nested Playlist Three', 'getUserPlaylists: nested playlist name decoded from playlist_metadata');
    is($result->{items}[0]{owner}{display_name}, 'Test User', 'getUserPlaylists: owner display_name decoded from the User submessage');

    my @rootlistReqs = grep { $_->{url} =~ m{/rootlist} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@rootlistReqs), 1, 'getUserPlaylists: exactly one rootlist request');
    like($rootlistReqs[0]->{url}, qr{/user/testuser/rootlist}, 'getUserPlaylists: URL uses the credentials.json username');
}

# Malformed rootlist bytes -> D-07 delegation to Client.pm, no die
# (T-75-12).
{
    reset_all();
    my $malformed = pack('C*', 0xFF, 0x00, 0xAB, 0xCD, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF);
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/playlist/v2/user/.+/rootlist}, $malformed);

    my ($result, $err);
    $SP->getUserPlaylists('acct91', {}, sub { ($result, $err) = @_ });

    is(scalar(@Plugins::SpotOn::API::Client::getUserPlaylists_calls), 1,
        'getUserPlaylists: malformed rootlist bytes delegate to Client.pm exactly once (D-07/T-75-12), no die');
}

# Recursion depth guard (T-75-16/V5): folder nesting well beyond
# ROOTLIST_MAX_DEPTH never crashes/hangs -- each level wraps the previous
# folder's bytes, simulating a pathological/adversarial rootlist payload.
# The playlist buried past the cap is silently dropped, not returned.
{
    reset_all();

    my $deepPlaylist = encode_rootlist_playlist(
        row_id   => 'spotify:playlist:' . b62id(99),
        metadata => { name => 'Buried Playlist' },
    );
    my $innerFolder = encode_rootlist_folder(encode_rootlist_item(playlist => $deepPlaylist));
    for (1 .. 20) {   # 20 levels, well beyond ROOTLIST_MAX_DEPTH (10)
        $innerFolder = encode_rootlist_folder(encode_rootlist_item(folder => $innerFolder));
    }
    my $deepRootlistBytes = encode_rootlist_response($innerFolder);

    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/playlist/v2/user/.+/rootlist}, $deepRootlistBytes);

    my ($result, $err);
    $SP->getUserPlaylists('acct94', {}, sub { ($result, $err) = @_ });

    ok($result, 'getUserPlaylists: 20-level-deep folder nesting does not crash/hang (T-75-16 depth guard)');
    is(scalar(@{ $result->{items} }), 0, 'getUserPlaylists: playlist buried beyond ROOTLIST_MAX_DEPTH is dropped, not returned (bounded recursion)');
}

# Source-level assertion: the depth-guard constant and its bail-out check
# exist in SpClient.pm (acceptance criterion: "Recursion depth guard exists
# (source assertion)").
{
    my $srcPath = "$project_dir/Plugins/SpotOn/API/SpClient.pm";
    open(my $fh, '<', $srcPath) or die "Cannot read $srcPath: $!";
    local $/;
    my $src = <$fh>;
    close($fh);
    like($src, qr/ROOTLIST_MAX_DEPTH/, 'source: ROOTLIST_MAX_DEPTH depth-guard constant present in SpClient.pm');
    like($src, qr/return if \$depth > ROOTLIST_MAX_DEPTH/, 'source: _flattenRootlistFolder bails out once the depth cap is exceeded');
}

# _normalizePlaylistMeta: URI derivation branches (link precedence over a
# non-URI row_id; bare row_id fallback when no link is present; malformed
# bytes return undef, not a die).
{
    my $withLink = encode_rootlist_playlist(
        row_id   => 'raw_row_id_value',
        metadata => { link => 'spotify:playlist:' . b62id(50), name => 'Linked Playlist' },
    );
    my $norm1 = $SP->_normalizePlaylistMeta($withLink);
    is($norm1->{uri}, 'spotify:playlist:' . b62id(50), '_normalizePlaylistMeta: prefers PlaylistMetadata.link over a non-URI row_id');
    is($norm1->{id}, b62id(50), '_normalizePlaylistMeta: id derived from the link-based uri');

    my $rawIdOnly = encode_rootlist_playlist(
        row_id   => b62id(51),
        metadata => { name => 'Raw Id Playlist' },
    );
    my $norm2 = $SP->_normalizePlaylistMeta($rawIdOnly);
    is($norm2->{uri}, 'spotify:playlist:' . b62id(51), '_normalizePlaylistMeta: derives spotify:playlist:{id} from a bare row_id when no link is present');

    my $malformedPlaylist = pack('C*', 0xFF, 0xFF, 0xFF);
    is($SP->_normalizePlaylistMeta($malformedPlaylist), undef, '_normalizePlaylistMeta: malformed playlist bytes return undef, not a die');
}

# getUserPlaylists D-06/D-07 router regressions.
{
    reset_all();
    $Plugins::SpotOn::API::Credentials::mock_creds = undef;

    my ($result, $err);
    $SP->getUserPlaylists('acct92', {}, sub { ($result, $err) = @_ });

    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 0, 'getUserPlaylists D-06: zero spclient HTTP when creds absent');
    is(scalar(@Plugins::SpotOn::API::Client::getUserPlaylists_calls), 1, 'getUserPlaylists D-06: delegates to Client.pm exactly once');

    $Plugins::SpotOn::API::Credentials::mock_creds = { username => 'testuser', auth_data => 'ZGF0YQ==' };
}
{
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_500';

    my ($result, $err);
    $SP->getUserPlaylists('acct93', {}, sub { ($result, $err) = @_ });

    is(scalar(@Plugins::SpotOn::API::Client::getUserPlaylists_calls), 1, 'getUserPlaylists D-07: falls back to Client.pm on a rootlist 500');

    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
}

done_testing();

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
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

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
our @SET_LOG = ();   # 79-27: every set(), [ key, expiry ], oldest first
sub new    { bless {}, shift }
sub get    { $_store{$_[1]} }
sub set    { push @SET_LOG, [ $_[1], $_[3] ]; $_store{$_[1]} = $_[2]; $_ttl{$_[1]} = $_[3]; 1 }
sub remove { delete $_store{$_[1]}; delete $_ttl{$_[1]} }
sub ttl    { $_ttl{$_[1]} }
sub clear  { %_store = (); %_ttl = (); @SET_LOG = () }
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
    elsif ($auto_mode eq 'error_timeout') {
        # a transport failure: no HTTP response at all (code 0, 85-07 D-11)
        $self->{error_cb}->($self, 'Connect timed out', undef);
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
our $mock_fail_detail = undef;
our @getToken_calls = ();
our %mock_login_state = ();
sub loginState { my ($class, $accountId) = @_; return $mock_login_state{$accountId // ''} }
sub getToken {
    my ($class, $accountId, $cb) = @_;
    push @getToken_calls, $accountId;
    if ($mock_fail_reason) {
        $cb->(undef, $mock_fail_reason, $mock_fail_detail);
        return;
    }
    $cb->($mock_token, undef);
}
sub reset_calls { @getToken_calls = () }
1;
END

# ============================================================
# Stub: Plugins::SpotOn::API::TokenManager -- account list for statusSnapshot
# (85-09 D-13)
# ============================================================
write_stub($stub_dir, 'Plugins::SpotOn::API::TokenManager', <<'END');
package Plugins::SpotOn::API::TokenManager;
our @mock_account_ids = ();
sub getAccountIds { return @mock_account_ids }
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
our @getLimit_calls                  = ();
our @getMe_calls                     = ();
our @getTopTracks_calls               = ();
our @getPersonalMixes_calls           = ();
our @saveTracks_calls                 = ();
our @removeTracks_calls               = ();
our @checkTracks_calls                 = ();
our @saveShows_calls                   = ();
our @removeShows_calls                 = ();
our @checkShows_calls                  = ();
our @addToPlaylist_calls               = ();
our $mock_result = { id => 'mockclienttrackid0000' };
our $mock_limit  = 42;

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
sub getLimit {
    my ($class, $endpointClass) = @_;
    push @getLimit_calls, { endpointClass => $endpointClass };
    return $mock_limit;
}
sub getMe {
    my ($class, $accountId, $cb) = @_;
    push @getMe_calls, { accountId => $accountId };
    $cb->($mock_result, undef);
}
sub getTopTracks {
    my ($class, $accountId, $params, $cb) = @_;
    push @getTopTracks_calls, { accountId => $accountId, params => $params };
    $cb->($mock_result, undef);
}
sub getPersonalMixes {
    my ($class, $accountId, $params, $cb) = @_;
    push @getPersonalMixes_calls, { accountId => $accountId, params => $params };
    $cb->($mock_result, undef);
}
sub saveTracks {
    my ($class, $accountId, $uris, $cb) = @_;
    push @saveTracks_calls, { accountId => $accountId, uris => $uris };
    $cb->($mock_result, undef);
}
sub removeTracks {
    my ($class, $accountId, $uris, $cb) = @_;
    push @removeTracks_calls, { accountId => $accountId, uris => $uris };
    $cb->($mock_result, undef);
}
sub checkTracks {
    my ($class, $accountId, $uris, $cb) = @_;
    push @checkTracks_calls, { accountId => $accountId, uris => $uris };
    $cb->($mock_result, undef);
}
sub saveShows {
    my ($class, $accountId, $uris, $cb) = @_;
    push @saveShows_calls, { accountId => $accountId, uris => $uris };
    $cb->($mock_result, undef);
}
sub removeShows {
    my ($class, $accountId, $uris, $cb) = @_;
    push @removeShows_calls, { accountId => $accountId, uris => $uris };
    $cb->($mock_result, undef);
}
sub checkShows {
    my ($class, $accountId, $uris, $cb) = @_;
    push @checkShows_calls, { accountId => $accountId, uris => $uris };
    $cb->($mock_result, undef);
}
sub addToPlaylist {
    my ($class, $accountId, $playlistId, $uris, $cb) = @_;
    push @addToPlaylist_calls, { accountId => $accountId, playlistId => $playlistId, uris => $uris };
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
    @getLimit_calls                = ();
    @getMe_calls                   = ();
    @getTopTracks_calls            = ();
    @getPersonalMixes_calls        = ();
    @saveTracks_calls              = ();
    @removeTracks_calls            = ();
    @checkTracks_calls             = ();
    @saveShows_calls               = ();
    @removeShows_calls             = ();
    @checkShows_calls              = ();
    @addToPlaylist_calls           = ();
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
    Plugins::SpotOn::API::Pathfinder->reset() if $INC{'Plugins/SpotOn/API/Pathfinder.pm'};
    Plugins::SpotOn::API::Login5::reset_calls();
    Plugins::SpotOn::API::Client::reset_calls();
    $Plugins::SpotOn::API::Login5::mock_fail_reason = undef;
    $Plugins::SpotOn::API::Login5::mock_fail_detail = undef;
    $Plugins::SpotOn::API::Credentials::mock_creds  = { username => 'testuser', auth_data => 'ZGF0YQ==' };
}

# 79-71: the trimmed real spike-013/014 replies (episode, chapter, NotFound, shows, lists) and the ids they carry
my $F71 = do {
    require JSON::PP;
    my $f = "$project_dir/t/fixtures/pathfinder/79-71-podcasts.json";
    open(my $fh, '<:raw', $f) or BAIL_OUT("cannot read fixture $f: $!");
    local $/; JSON::PP->new->utf8->decode(<$fh>);
};
my $EP71 = '6hDIr2Ngy8ijkGk3o77Li2';
my $CH71 = '73E4okoX6R2PAagxONnSWI';
my $SHOW71_POD  = '1SzqOFS7bQ61WHixnftnYH';
my $SHOW71_BOOK = '01DbzJA9caChG3VDgVmnFc';
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
                image => [ { file_id => 'deadbeefcafefeed000000000000000000000000', width => 640, height => 640 } ],
            },
        },
    });
}

# ============================================================
# 79-27 (D-18/D-21): extended-metadata batch helpers. The batch endpoint answers a protobuf
# BatchedExtensionResponse; these helpers build it for the requested entity_uris from the same track
# data the JSON fixtures carry (BatchedEntityRequest: entity_request=2 { entity_uri=1, query=2 };
# BatchedExtensionResponse: extended_metadata=2 { extension_kind=2, extension_data=3 {
# header=1 { status_code=1 }, entity_uri=2, extension_data=3 Any { type_url=1, value=2 = Track } } }).
# ============================================================
my $PBL = 'Plugins::SpotOn::API::ProtobufLite';
our @BATCH_LOG;   # one arrayref of entity_uris per POST the responder answered
sub pb_enc { return $PBL->can('encode_field')->(@_) }
sub pb_pf  { return $PBL->can('parse_fields')->(@_) }
sub pb_ff  { return $PBL->can('field_first')->(@_) }
sub zz     { my $v = shift; return $v < 0 ? (-$v * 2 - 1) : ($v * 2) }

# pb_track_msg(\%json_shaped_track) -> metadata.proto Track bytes
sub pb_track_msg {
    my ($h) = @_;
    my $out = '';
    $out .= pb_enc(1, 2, pack('H*', $h->{gid})) if defined $h->{gid};
    $out .= pb_enc(2, 2, $h->{name})             if defined $h->{name};
    if (my $al = $h->{album}) {
        my $a = '';
        $a .= pb_enc(1, 2, pack('H*', $al->{gid})) if defined $al->{gid};
        $a .= pb_enc(2, 2, $al->{name})            if defined $al->{name};
        my $imgs = join '', map {
            pb_enc(1, 2, pb_enc(1, 2, pack('H*', $_->{file_id})) . pb_enc(3, 0, zz($_->{width})) . pb_enc(4, 0, zz($_->{height})))
        } @{ ($al->{cover_group} || {})->{image} || [] };
        $a .= pb_enc(17, 2, $imgs) if length $imgs;
        $out .= pb_enc(3, 2, $a);
    }
    $out .= pb_enc(4, 2, pb_enc(1, 2, pack('H*', $_->{gid})) . pb_enc(2, 2, $_->{name})) for @{ $h->{artist} || [] };
    $out .= pb_enc(7, 0, zz($h->{duration}))   if defined $h->{duration};
    $out .= pb_enc(8, 0, zz($h->{popularity})) if defined $h->{popularity};
    $out .= pb_enc(9, 0, $h->{explicit} ? 1 : 0);
    return $out;
}

# track_hash_for_id($id) -> the JSON-shaped metadata/4/track hash of a distinguishable test track
sub track_hash_for_id {
    my ($id) = @_;
    return {
        gid        => $SP->idToHex($id),
        name       => "Track $id",
        duration   => 215000,
        explicit   => 1,
        popularity => 42,
        artist     => [ { gid => 'bb000000000000000000000000000002', name => "Artist of $id" } ],
        album      => {
            gid => 'cc000000000000000000000000000003', name => 'Test Album',
            cover_group => { image => [ { file_id => 'deadbeefcafefeed000000000000000000000000', width => 640, height => 640 } ] },
        },
    };
}
sub fixture_track_hash { require JSON::PP; return JSON::PP::decode_json(to_json_fixture()); }

# batch_responder(%o): CODE response rule for the extended-metadata POST.
#   data      => sub ($id) -> JSON-shaped hash   (default track_hash_for_id)
#   shuffle   => 1                               (entities answered in reverse request order)
#   status404 => { $uri => 1 }                   (that entity answers status_code 404)
#   nameless  => { $uri => 1 }                   (that entity carries a Track without a name)
#   drop      => { $uri => 1 }                   (no entity at all for that uri)
sub batch_responder {
    my (%o) = @_;
    return sub {
        my ($body) = @_;
        my $req  = pb_pf($body) || {};
        my @uris = map { pb_ff(pb_pf($_) || {}, 1) } @{ $req->{2} || [] };
        push @BATCH_LOG, \@uris;
        my @ents;
        for my $uri (@uris) {
            next if $o{drop} && $o{drop}{$uri};
            my ($id) = $uri =~ /^spotify:track:(.+)$/;
            my $h = $o{data} ? $o{data}->($id) : track_hash_for_id($id);
            $h = { %$h, name => undef } if $o{nameless} && $o{nameless}{$uri};
            my $status = ($o{status404} && $o{status404}{$uri}) ? 404 : 200;
            push @ents, pb_enc(3, 2, pb_enc(1, 2, pb_enc(1, 0, $status)) . pb_enc(2, 2, $uri)
                . pb_enc(3, 2, pb_enc(1, 2, 'type.googleapis.com/spotify.metadata.Track') . pb_enc(2, 2, pb_track_msg($h))));
        }
        @ents = reverse @ents if $o{shuffle};
        return pb_enc(2, 2, pb_enc(2, 0, 10) . join('', @ents));
    };
}
sub set_batch { Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/extended-metadata/v0/extended-metadata}, batch_responder(@_)); }
sub batch_posts { return grep { $_->{method} eq 'POST' && $_->{url} =~ m{/extended-metadata/v0/extended-metadata$} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests(); }
sub track_gets  { return grep { $_->{url} =~ m{/metadata/4/track/} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests(); }
sub post_uris   { my ($r) = @_; return map { pb_ff(pb_pf($_) || {}, 1) } @{ (pb_pf($r->{body}) || {})->{2} || [] }; }

# ============================================================
# (c) creds absent -> 85-07 D-11: no Client.pm delegation, an immediate
# no_credentials error to the callback, no HTTP
# ============================================================
{
    reset_all();
    $Plugins::SpotOn::API::Credentials::mock_creds = undef;

    my ($result, $err, $called);
    $SP->getTrack('acct2', '4iV5W9uYEdYUVa79Axb7Rh', sub { ($result, $err) = @_; $called++ });

    my @nonApresolve = Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@nonApresolve), 0, 'creds-absent: zero spclient HTTP requests');
    is(scalar(@Plugins::SpotOn::API::Client::getTrack_calls), 0, 'creds-absent (85-07 D-11): Client.pm is NOT delegated to');
    is($called, 1, 'creds-absent: the callback fires exactly once');
    ok(!defined $result, 'creds-absent: no result');
    is($err->{error}, 'no_credentials', 'creds-absent: error no_credentials');
}

# ============================================================
# (d) spclient 5xx / transport error -> 85-07 D-11: retried after 1 s and 3 s
# (TRACK_META_RETRY_DELAYS) through the same pipeline, then the last error
# goes to the callback; never Client.pm
# ============================================================
sub retry_timers { return grep { ref($_->[2]) eq 'CODE' } @Slim::Utils::Timers::set_calls }
{
    reset_all();
    @Slim::Utils::Timers::set_calls = ();
    is_deeply(Plugins::SpotOn::API::SpClient::TRACK_META_RETRY_DELAYS(), [1, 3], 'D-11: TRACK_META_RETRY_DELAYS is [1, 3]');
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_500';

    my ($result, $err, $called);
    $SP->getTrack('acct3', '4iV5W9uYEdYUVa79Axb7Rh', sub { ($result, $err) = @_; $called++ });

    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 1, 'D-11: 500 -> one attempt so far');
    ok(!$called, 'D-11: 500 -> the callback has not fired, a retry is pending');
    my @t = retry_timers();
    is(scalar(@t), 1, 'D-11: 500 -> exactly one retry timer armed');
    my $d1 = $t[0][1] - Time::HiRes::time();
    ok($d1 >= 0 && $d1 <= 2, "D-11: the first retry is due in about 1 s (got $d1)");

    @Slim::Utils::Timers::set_calls = ();
    $t[0][2]->($t[0][0]);
    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 2, 'D-11: first retry -> second attempt');
    ok(!$called, 'D-11: still no callback after the second 500');
    @t = retry_timers();
    is(scalar(@t), 1, 'D-11: a second retry timer is armed');
    my $d2 = $t[0][1] - Time::HiRes::time();
    ok($d2 >= 2 && $d2 <= 4, "D-11: the second retry is due in about 3 s (got $d2)");

    @Slim::Utils::Timers::set_calls = ();
    $t[0][2]->($t[0][0]);
    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 3, 'D-11: second retry -> third and last attempt');
    is($called, 1, 'D-11: after the retries the callback fires exactly once');
    is($err->{code}, 500, 'D-11: with the last error');
    is(scalar(retry_timers()), 0, 'D-11: no further retry after two');
    is(scalar(@Plugins::SpotOn::API::Client::getTrack_calls), 0, 'D-11: Client.pm is never reached on 5xx');

    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
}

# a transport error (code 0, "Connect timed out") is retried too, and a
# retry that succeeds delivers the track
{
    reset_all();
    @Slim::Utils::Timers::set_calls = ();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_timeout';

    my ($result, $err, $called);
    $SP->getTrack('acct3b', '4iV5W9uYEdYUVa79Axb7Rh', sub { ($result, $err) = @_; $called++ });
    ok(!$called, 'D-11: Connect timed out -> retried, not reported');
    my @t = retry_timers();
    is(scalar(@t), 1, 'D-11: Connect timed out -> one retry timer armed');

    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = to_json_fixture();
    @Slim::Utils::Timers::set_calls = ();
    $t[0][2]->($t[0][0]);
    is($called, 1, 'D-11: the retry that succeeds fires the callback once');
    ok(!$err, 'D-11: no error after a successful retry');
    is($result->{name}, 'Test Track', 'D-11: the retried result is the normalized track');
}

# 404 is definitive: no retry, the error goes straight to the callback
{
    reset_all();
    @Slim::Utils::Timers::set_calls = ();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_404';

    my ($result, $err, $called);
    $SP->getTrack('acct3c', '4iV5W9uYEdYUVa79Axb7Rh', sub { ($result, $err) = @_; $called++ });
    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 1, 'D-11: 404 -> exactly one attempt');
    is(scalar(retry_timers()), 0, 'D-11: 404 -> no retry timer');
    is($called, 1, 'D-11: 404 -> the callback fires');
    is($err->{code}, 404, 'D-11: 404 -> the 404 error is passed on unchanged');
    is(scalar(@Plugins::SpotOn::API::Client::getTrack_calls), 0, 'D-11: 404 -> Client.pm is not asked for a second opinion');

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

    @Slim::Utils::Timers::set_calls = ();
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
    is(scalar(@Plugins::SpotOn::API::Client::getTrack_calls), 0, '401: no Client.pm fallback after the second 401 (85-07 D-11)');
    is(ref($err) eq 'HASH' ? $err->{code} : undef, 401, '401: the second 401 is passed on to the callback');
    is(scalar(grep { ref($_->[2]) eq 'CODE' } @Slim::Utils::Timers::set_calls), 0, '401: no retry timer (not a network error)');

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
        album_group       => [ { album => [ { gid => hexid(10) } ] } ],
        single_group      => [ { album => [ { gid => hexid(11) } ] } ],
        compilation_group => [],
    });
}

# 87.1-03 (GH #211): one distinct album gid per release group. The four *_group keys and the shape
# { album => [ { gid } ] } follow the real metadata/4/artist reply (rig probe, 87.1-03-PROBE.txt: all four
# keys present for Daft Punk and Queen). The CONTENT of appears_on_group is synthetic: the probe counted
# no entries, so no real appears_on entry shape is claimed here beyond the shared group wrapper.
sub artist_fixture_groups {
    return JSON::XS::VersionOneAndTwo::to_json({
        gid               => hexid(200),
        name              => 'Test Artist Name',
        album_group       => [ { album => [ { gid => hexid(10) } ] } ],
        single_group      => [ { album => [ { gid => hexid(11) } ] } ],
        compilation_group => [ { album => [ { gid => hexid(12) } ] } ],
        appears_on_group  => [ { album => [ { gid => hexid(13) } ] } ],
    });
}

# 261114-kus: an artist with $nAlbum album_group albums (gid hexid(2000+i)) and $nAppears appears_on_group
# albums (gid hexid(1000+i)), the latter in wrappers of THREE albums each (the last one may be shorter; a cut at
# 100 falls inside wrapper 34, so the cut is per album, not per wrapper). Synthetic content, wrapper shape as in
# artist_fixture_groups.
sub artist_fixture_cap {
    my ($nAlbum, $nAppears) = @_;
    my @ap = map { { gid => hexid(1000 + $_) } } 1 .. $nAppears;
    my @apGroups;
    push @apGroups, { album => [ splice(@ap, 0, 3) ] } while @ap;
    return JSON::XS::VersionOneAndTwo::to_json({
        gid               => hexid(200),
        name              => 'Test Artist Name',
        album_group       => ($nAlbum ? [ { album => [ map { { gid => hexid(2000 + $_) } } 1 .. $nAlbum ] } ] : []),
        single_group      => [],
        compilation_group => [],
        appears_on_group  => \@apGroups,
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

# context_resolve_mixed_fixture: 5 URIs of which only 3 are spotify:track:
# (episode + local interleaved) -- Window 6 regression fixture. The offset
# guard in search() must compare against the track-FILTERED count (3), not
# the raw URI count (5).
sub context_resolve_mixed_fixture {
    my @entries = (
        { uri => 'spotify:track:'   . b62id(1) },
        { uri => 'spotify:episode:' . b62id(90) },
        { uri => 'spotify:track:'   . b62id(2) },
        { uri => 'spotify:local:not-a-track' },
        { uri => 'spotify:track:'   . b62id(3) },
    );
    return JSON::XS::VersionOneAndTwo::to_json({
        pages => [ { tracks => \@entries } ],
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

# getAlbum error path (85-15, D-01: the D-07 fallback is gone). Proves
# _spFacade's shared error path -- other new methods below reuse this exact
# helper without a duplicate 500 test each.
{
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_500';

    my ($result, $err);
    $SP->getAlbum('acct15', '4iV5W9uYEdYUVa79Axb7Rh', sub { ($result, $err) = @_ });

    is(scalar(@Plugins::SpotOn::API::Client::getAlbum_calls), 0,
        'getAlbum 85-15: a spclient 500 never reaches Client.pm (no fallback layer, shared _spFacade helper)');
    ok(!$result && ref($err) eq 'HASH' && $err->{code} == 500,
        'getAlbum 85-15: the spclient 500 reaches the caller unchanged as (undef, {code=>500})');

    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
}

# getAlbumTracks: lazy slice -- exactly limit-many (2 of 3) enrichment calls.
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/album/}, album_fixture());
    set_batch(data => sub { fixture_track_hash() });

    my ($result, $err);
    $SP->getAlbumTracks('acct11', '4iV5W9uYEdYUVa79Axb7Rh', { offset => 0, limit => 2 }, sub { ($result, $err) = @_ });

    ok($result, 'getAlbumTracks: result returned');
    is($result->{total}, 3, 'getAlbumTracks: total reflects the full flattened disc/track count (3), not the slice');
    is(scalar(@{ $result->{items} }), 2, 'getAlbumTracks: only the requested slice (2) is returned');

    # 79-27 (was: exactly limit-many (2) metadata/4/track GETs): the 2 sliced ids travel in ONE extended-metadata POST
    my @posts = batch_posts();
    is(scalar(@posts) . '/' . scalar(track_gets()) . '/' . join(',', map { scalar(post_uris($_)) } @posts), '1/0/2',
        'getAlbumTracks: exactly limit-many (2) ids in ONE extended-metadata POST and no metadata/4/track GET -- lazy slice, not all 3');
    is($result->{items}[0]{name}, 'Test Track', 'getAlbumTracks: enriched item carries the Web-API track shape');
}

# getAlbumTracks: D-09 cache reuse -- a second identical call issues zero
# additional HTTP requests (album metadata + per-track enrichment all cache hits).
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/album/}, album_fixture());
    set_batch(data => sub { fixture_track_hash() });

    my $noop = sub { };
    $SP->getAlbumTracks('acct12', '4iV5W9uYEdYUVa79Axb7Rh', { offset => 0, limit => 2 }, $noop);
    my $firstCount = scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests());

    $SP->getAlbumTracks('acct12', '4iV5W9uYEdYUVa79Axb7Rh', { offset => 0, limit => 2 }, $noop);
    my $secondCount = scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests());

    is($secondCount, $firstCount,
        'D-09: repeated getAlbumTracks for the same album+slice issues zero additional HTTP requests (response cache hits)');
}

# WR-01 (gap closure 75-07 Task 2): an empty-body 200 response leaves $meta
# undef -- the normalize closure must answer parse_error exactly once
# instead of dying inside the async HTTP success callback (no die, no hang,
# no double-callback; 85-15: no Client.pm delegation any more).
{
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = '';

    my $cbCalls = 0;
    my ($result, $err);
    $SP->getAlbumTracks('acct17', '4iV5W9uYEdYUVa79Axb7Rh', {}, sub { $cbCalls++; ($result, $err) = @_ });

    is($cbCalls, 1, 'WR-01 getAlbumTracks: cb fires exactly once on an empty-body 200 (no double-callback)');
    is(scalar(@Plugins::SpotOn::API::Client::getAlbumTracks_calls), 0,
        'WR-01 getAlbumTracks: empty-body $meta never reaches Client.pm (85-15), no die');
    is(ref($err) eq 'HASH' ? $err->{error} : undef, 'parse_error',
        'WR-01 getAlbumTracks: empty-body $meta answers (undef, {error=>parse_error})');

    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = '{}';
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

# getArtist D-06: no login5-capable creds -> immediate no_credentials, zero HTTP, no Client.pm (85-15).
{
    reset_all();
    $Plugins::SpotOn::API::Credentials::mock_creds = undef;

    my ($result, $err);
    $SP->getArtist('acct16', '4iV5W9uYEdYUVa79Axb7Rh', sub { ($result, $err) = @_ });

    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 0, 'getArtist D-06: zero spclient HTTP when creds absent');
    is(scalar(@Plugins::SpotOn::API::Client::getArtist_calls), 0, 'getArtist D-06: never reaches Client.pm when creds absent (85-15)');
    is(ref($err) eq 'HASH' ? $err->{error} : undef, 'no_credentials', 'getArtist D-06: answers (undef, {error=>no_credentials}) when creds absent');

    $Plugins::SpotOn::API::Credentials::mock_creds = { username => 'testuser', auth_data => 'ZGF0YQ==' };
}

# getArtistAlbums per release group (87.1-03, GH #211). One cached metadata/4/artist read; the include_groups
# value picks the *_group key(s), and only the selected group's albums are counted and enriched (total and the
# metadata/4/album requests are per tab).
#   AG-1 album: total 1 'Album One', 2 metadata requests (artist + its album); a comma list adds the second group
#   AG-2 single  AG-3 compilation  AG-4 appears_on (synthetic content)
#   AG-5 include_groups absent: album + single + compilation (total 3), appears_on not included
#   AG-6 unknown value: total 0, only the artist request (no enrichment)
{
    my %group_name = (10 => 'Album One', 11 => 'Single One', 12 => 'Compilation One', 13 => 'Appears On One');
    my $run = sub {
        my ($params) = @_;
        reset_all();
        Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/artist/}, artist_fixture_groups());
        for my $n (sort keys %group_name) {
            my $hex = hexid($n);
            Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/album/$hex}, JSON::XS::VersionOneAndTwo::to_json({
                gid  => $hex, name => $group_name{$n},
                artist => [ { gid => hexid(201), name => 'Artist' } ],
                cover_group => { image => [ { file_id => "coverid$n", width => 300, height => 300 } ] },
            }));
        }
        my ($result, $err);
        $SP->getArtistAlbums('acct14', '4iV5W9uYEdYUVa79Axb7Rh', $params, sub { ($result, $err) = @_ });
        my @metaReqs = grep { $_->{url} =~ m{/metadata/4/} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
        return ($result, $err, scalar @metaReqs);
    };
    my $names = sub { join(',', map { $_->{name} } @{ $_[0]->{items} || [] }) };

    my ($r, $e, $reqs) = $run->({ include_groups => 'album' });
    ok($r, 'AG-1: result returned');
    is($r && $r->{total}, 1, 'AG-1: include_groups album -> total 1');
    is($r && $names->($r), 'Album One', 'AG-1: include_groups album -> only Album One');
    is($reqs, 2, 'AG-1: 2 metadata requests (artist + its own album), not 3 for the union');
    ($r) = $run->({ include_groups => 'album,single' });
    is($r && $names->($r), 'Album One,Single One', 'AG-1: a comma list takes both groups, album first');

    ($r) = $run->({ include_groups => 'single' });
    is($r && $r->{total}, 1, 'AG-2: include_groups single -> total 1');
    is($r && $names->($r), 'Single One', 'AG-2: include_groups single -> only Single One');

    ($r) = $run->({ include_groups => 'compilation' });
    is($r && $r->{total}, 1, 'AG-3: include_groups compilation -> total 1');
    is($r && $names->($r), 'Compilation One', 'AG-3: include_groups compilation -> only Compilation One');

    ($r) = $run->({ include_groups => 'appears_on' });
    is($r && $r->{total}, 1, 'AG-4: include_groups appears_on -> total 1 (synthetic appears_on_group)');
    is($r && $names->($r), 'Appears On One', 'AG-4: include_groups appears_on -> only the appears_on_group album');

    ($r, $e, $reqs) = $run->({});
    is($r && $r->{total}, 3, 'AG-5: include_groups absent -> album + single + compilation, total 3');
    is($r && $names->($r), 'Album One,Single One,Compilation One', 'AG-5: appears_on is not part of the default');
    ($r) = $run->({ include_groups => '' });
    is($r && $r->{total}, 3, 'AG-5: an empty include_groups behaves like an absent one');

    ($r, $e, $reqs) = $run->({ include_groups => 'bogus' });
    ok($r && !$e, 'AG-6: unknown include_groups value still answers a page');
    is($r && $r->{total}, 0, 'AG-6: unknown include_groups value -> total 0');
    is($r && scalar @{ $r->{items} }, 0, 'AG-6: unknown include_groups value -> no items');
    is($reqs, 1, 'AG-6: only the artist request, no enrichment');
}

# 261114-kus: Appears On cap (user decision 2026-11-14, cap 100). One artist had 514 appears_on entries and Play All
# enriched every one through metadata/4/album. getArtistAlbums keeps the first 100 appears_on album ids (reply order)
# BEFORE total, slice and enrichment; `available` carries the uncapped count and exists only when the cap cut something.
#   AOC-1 515 ids, page 0: total 100, available 515, 50 album requests for 1001..1050
#   AOC-2 page at offset 100 is empty and sends no album request; offset 90 holds the last ten (91..100)
#   AOC-3 a full page walk sends album requests for exactly 1001..1100 and ONE artist request
#   AOC-4 combined list album,appears_on: only the appears_on part is cut (total 102, available 517)
#   AOC-5 control: album stays unlimited (150), no available key; exactly 100 appears_on ids are not cut
{
    my $run = sub {
        my ($nAlbum, $nAppears, $params) = @_;
        reset_all();
        Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/artist/}, artist_fixture_cap($nAlbum, $nAppears));
        for my $spec ([ 1000, $nAppears, 'AO' ], [ 2000, $nAlbum, 'AL' ]) {
            my ($base, $n, $pfx) = @$spec;
            for my $i (1 .. $n) {
                my $hex = hexid($base + $i);
                Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/album/$hex}, JSON::XS::VersionOneAndTwo::to_json({
                    gid  => $hex, name => "$pfx $i",
                    artist => [ { gid => hexid(201), name => 'Artist' } ],
                    cover_group => { image => [ { file_id => "coverid$base$i", width => 300, height => 300 } ] },
                }));
            }
        }
        my ($result, $err);
        $SP->getArtistAlbums('acct14', '4iV5W9uYEdYUVa79Axb7Rh', $params, sub { ($result, $err) = @_ });
        return ($result, $err);
    };
    my $albumNums = sub {
        my @n = map { $_->{url} =~ m{/metadata/4/album/([0-9a-f]{32})} ? 0 + $1 : () }
                Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
        return @n;
    };
    my $names = sub { join(',', map { $_->{name} } @{ $_[0]->{items} || [] }) };

    my ($r) = $run->(0, 515, { include_groups => 'appears_on', offset => 0, limit => 50 });
    my @nums = $albumNums->();
    is($r && $r->{total}, 100, 'AOC-1: 515 appears_on ids -> total 100');
    is($r && $r->{available}, 515, 'AOC-1: available carries the uncapped count 515');
    is($r && scalar @{ $r->{items} }, 50, 'AOC-1: page of 50 items');
    is($r && $r->{items}[0]{name}, 'AO 1', 'AOC-1: first item is the first listed album');
    is($r && $r->{items}[-1]{name}, 'AO 50', 'AOC-1: last item of the page is AO 50');
    is(scalar @nums, 50, 'AOC-1: exactly 50 metadata/4/album requests');
    is(join(',', sort { $a <=> $b } @nums), join(',', 1001 .. 1050), 'AOC-1: the requests are for albums 1001..1050');

    ($r) = $run->(0, 515, { include_groups => 'appears_on', offset => 100, limit => 50 });
    @nums = $albumNums->();
    is($r && scalar @{ $r->{items} }, 0, 'AOC-2: the page at offset 100 is empty');
    is($r && $r->{total}, 100, 'AOC-2: total stays 100 at offset 100');
    is($r && $r->{available}, 515, 'AOC-2: available stays 515 at offset 100');
    is(scalar @nums, 0, 'AOC-2: zero metadata/4/album requests at offset 100');

    ($r) = $run->(0, 515, { include_groups => 'appears_on', offset => 90, limit => 50 });
    @nums = $albumNums->();
    is($r && scalar @{ $r->{items} }, 10, 'AOC-2: offset 90 holds the last ten items');
    is($r && $names->($r), join(',', map { "AO $_" } 91 .. 100), 'AOC-2: offset 90 holds AO 91..AO 100');
    is(scalar @nums, 10, 'AOC-2: offset 90 sends 10 album requests');
    is((sort { $b <=> $a } @nums)[0], 1100, 'AOC-2: the highest requested album is 1100');

    # AOC-3: walk the pages like Plugin.pm _fetchPages (one reset, no reset between pages).
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/artist/}, artist_fixture_cap(0, 515));
    for my $i (1 .. 515) {
        my $hex = hexid(1000 + $i);
        Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/album/$hex}, JSON::XS::VersionOneAndTwo::to_json({
            gid => $hex, name => "AO $i", artist => [ { gid => hexid(201), name => 'Artist' } ],
            cover_group => { image => [ { file_id => "coverid$i", width => 300, height => 300 } ] },
        }));
    }
    my @collected;
    my $offset = 0;
    my $guard  = 0;
    while ($guard++ < 40) {
        my ($pg, $pe);
        $SP->getArtistAlbums('acct14', '4iV5W9uYEdYUVa79Axb7Rh', { include_groups => 'appears_on', offset => $offset, limit => 50 }, sub { ($pg, $pe) = @_ });
        last unless $pg && @{ $pg->{items} || [] };
        push @collected, map { $_->{name} } @{ $pg->{items} };
        $offset += scalar @{ $pg->{items} };
        last unless $offset < $pg->{total};
    }
    @nums = $albumNums->();
    my %seen = map { $_ => 1 } @nums;
    my @artistReqs = grep { $_->{url} =~ m{/metadata/4/artist/} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(join(',', @collected), join(',', map { "AO $_" } 1 .. 100), 'AOC-3: the walk collects AO 1..AO 100 in order');
    is(join(',', sort { $a <=> $b } keys %seen), join(',', 1001 .. 1100), 'AOC-3: the requested albums are exactly 1001..1100');
    is(scalar(keys %seen), 100, 'AOC-3: 100 distinct album ids requested, none above 1100');
    is(scalar @artistReqs, 1, 'AOC-3: ONE metadata/4/artist request for the whole walk');

    ($r) = $run->(2, 515, { include_groups => 'album,appears_on', offset => 0, limit => 50 });
    is($r && $r->{total}, 102, 'AOC-4: album 2 + appears_on 515 -> total 102 (only appears_on is cut)');
    is($r && $r->{available}, 517, 'AOC-4: available 517 (uncapped count of the whole selection)');
    is($r && join(',', map { $_->{name} } @{ $r->{items} }[0 .. 2]), 'AL 1,AL 2,AO 1', 'AOC-4: albums first, then the appears_on albums');
    ($r) = $run->(2, 515, { include_groups => 'album,appears_on', offset => 102, limit => 50 });
    is($r && scalar @{ $r->{items} }, 0, 'AOC-4: offset 102 gives no items');

    ($r) = $run->(150, 0, { include_groups => 'album', offset => 0, limit => 50 });
    is($r && $r->{total}, 150, 'AOC-5: include_groups album with 150 ids -> total 150 (no cap)');
    ok($r && !exists $r->{available}, 'AOC-5: album carries no available key');
    ($r) = $run->(150, 0, { include_groups => 'album', offset => 100, limit => 50 });
    is($r && $names->($r), join(',', map { "AL $_" } 101 .. 150), 'AOC-5: offset 100 limit 50 gives AL 101..AL 150');
    ($r) = $run->(0, 100, { include_groups => 'appears_on', offset => 0, limit => 50 });
    is($r && $r->{total}, 100, 'AOC-5: exactly 100 appears_on ids -> total 100');
    ok($r && !exists $r->{available}, 'AOC-5: exactly 100 ids are not cut, no available key');
}

# WR-01 (gap closure 75-07 Task 2): an empty-body 200 response leaves $meta
# undef -- the normalize closure must answer parse_error exactly once
# instead of dying inside the async HTTP success callback (no die, no hang,
# no double-callback; 85-15: no Client.pm delegation any more).
{
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = '';

    my $cbCalls = 0;
    my ($result, $err);
    $SP->getAlbumTracks('acct17', '4iV5W9uYEdYUVa79Axb7Rh', {}, sub { $cbCalls++; ($result, $err) = @_ });

    is($cbCalls, 1, 'WR-01 getAlbumTracks: cb fires exactly once on an empty-body 200 (no double-callback)');
    is(scalar(@Plugins::SpotOn::API::Client::getAlbumTracks_calls), 0,
        'WR-01 getAlbumTracks: empty-body $meta never reaches Client.pm (85-15), no die');
    is(ref($err) eq 'HASH' ? $err->{error} : undef, 'parse_error',
        'WR-01 getAlbumTracks: empty-body $meta answers (undef, {error=>parse_error})');

    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = '{}';
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

# getArtist D-06: no login5-capable creds -> immediate no_credentials, zero HTTP, no Client.pm (85-15).
{
    reset_all();
    $Plugins::SpotOn::API::Credentials::mock_creds = undef;

    my ($result, $err);
    $SP->getArtist('acct16', '4iV5W9uYEdYUVa79Axb7Rh', sub { ($result, $err) = @_ });

    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 0, 'getArtist D-06: zero spclient HTTP when creds absent');
    is(scalar(@Plugins::SpotOn::API::Client::getArtist_calls), 0, 'getArtist D-06: never reaches Client.pm when creds absent (85-15)');
    is(ref($err) eq 'HASH' ? $err->{error} : undef, 'no_credentials', 'getArtist D-06: answers (undef, {error=>no_credentials}) when creds absent');

    $Plugins::SpotOn::API::Credentials::mock_creds = { username => 'testuser', auth_data => 'ZGF0YQ==' };
}

# getArtistAlbums: album_group + single_group flattening, per-album enrichment.
# spclient artist metadata only embeds gid per album (no name/cover), so each
# album in the page is enriched via metadata/4/album.
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/artist/}, artist_fixture());
    my $albumHex10 = hexid(10);
    my $albumHex11 = hexid(11);
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/album/$albumHex11}, JSON::XS::VersionOneAndTwo::to_json({
        gid  => $albumHex11, name => 'Single One',
        artist => [ { gid => hexid(201), name => 'Artist' } ],
        cover_group => { image => [ { file_id => 'coverid11', width => 300, height => 300 } ] },
    }));
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/album/$albumHex10}, JSON::XS::VersionOneAndTwo::to_json({
        gid  => $albumHex10, name => 'Album One',
        artist => [ { gid => hexid(201), name => 'Artist' } ],
        cover_group => { image => [ { file_id => 'coverid10', width => 300, height => 300 } ] },
    }));

    my ($result, $err);
    $SP->getArtistAlbums('acct14', '4iV5W9uYEdYUVa79Axb7Rh', {}, sub { ($result, $err) = @_ });

    ok($result, 'getArtistAlbums: result returned');
    is($result->{total}, 2, 'getArtistAlbums: album_group + single_group flattened to 2 total');
    is($result->{items}[0]{name}, 'Album One', 'getArtistAlbums: album enrichment delivers name');
    is($result->{items}[1]{name}, 'Single One', 'getArtistAlbums: single enrichment delivers name');

    my @metaReqs = grep { $_->{url} =~ m{/metadata/4/} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@metaReqs), 3, 'getArtistAlbums: 1 artist + 2 album enrichment calls');
}

# WR-01 (gap closure 75-07 Task 2): empty-body 200 -> parse_error (85-15: no
# Client.pm delegation), no die, no hang, cb fires exactly once. 79-71: the body is Pathfinder's.
{
    reset_all();
    Slim::Utils::Cache->new()->set("spoton_pf_hash_$_", 'a' x 64) for qw(queryShowMetadataV2 queryPodcastEpisodes);
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{pathfinder/v2/query}, '');

    my $cbCalls = 0;
    my ($result, $err);
    $SP->getShowEpisodes('acct24', '4iV5W9uYEdYUVa79Axb7Rh', {}, sub { $cbCalls++; ($result, $err) = @_ });

    is($cbCalls, 1, 'WR-01 getShowEpisodes: cb fires exactly once on an empty-body 200 (no double-callback)');
    is(scalar(@Plugins::SpotOn::API::Client::getShowEpisodes_calls), 0,
        'WR-01 getShowEpisodes: an empty body never reaches Client.pm (85-15), no die');
    ok(ref($err) eq 'HASH' && $err->{error} eq 'pathfinder_unavailable' && ($err->{pf_error} // '') eq 'parse_error' && !exists $err->{code},
        'WR-01 getShowEpisodes: an empty body answers (undef, {error=>pathfinder_unavailable, pf_error=>parse_error})');

    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = '{}';
}

# getEpisode: single-object fetch. 79-71 (GH #167, D-38): the facade runs on Pathfinder (getEpisodeOrChapter), no
# spclient metadata/4/episode request; the cells on the real spike-013 replies are in the 79-71 section at the end of
# this file (one-request, notfound, transport) and in t/core/20 (the mappers).

# ============================================================
# 85-08 Task 3 -- search on Pathfinder (decision-SEARCH pathfinder-search):
# per-type ops for one type, ONE searchDesktop request for several types,
# login5, cookie-free; the context-resolve path is only the degraded mode.
# Replaces the Phase 75 router assertions (context-resolve / Client.pm
# delegation), one-for-one or more.
# ============================================================
my $PFX = do {
    require JSON::PP;
    my $f = "$project_dir/t/fixtures/pathfinder/85-04-trimmed.json";
    open(my $fh, '<:raw', $f) or BAIL_OUT("cannot read fixture $f: $!");
    local $/; JSON::PP->new->utf8->decode(<$fh>);
};
sub pf_seed {
    Slim::Utils::Cache->new()->set("spoton_pf_hash_$_", 'a' x 64)
        for qw(homeSection userTopContent searchDesktop searchTracks searchAlbums searchArtists searchPlaylists searchPodcasts);
}
sub pf_reqs {
    return grep { $_->{url} =~ m{api-partner\.spotify\.com/pathfinder/v2/query} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
}
sub pf_vars { return JSON::PP::decode_json($_[0]{body}); }
# answers from the fixture: userTopContent / searchDesktop whole, a per-type op as the one section of searchDesktop
sub pf_ops_rule {
    my %sect = (searchTracks => 'tracksV2', searchAlbums => 'albumsV2', searchArtists => 'artists',
                searchPlaylists => 'playlists', searchPodcasts => 'podcasts');
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{pathfinder/v2/query}, sub {
        my $op = JSON::PP::decode_json($_[0])->{operationName};
        my $enc = JSON::PP->new->utf8;
        return $enc->encode($PFX->{userTopContent}) if $op eq 'userTopContent';
        return $enc->encode($PFX->{searchTracks})   if $op eq 'searchTracks';
        return $enc->encode($PFX->{searchDesktop})  if $op eq 'searchDesktop';
        if (my $k = $sect{$op}) { return $enc->encode({ data => { searchV2 => { $k => $PFX->{searchDesktop}{data}{searchV2}{$k} } } }) }
        return '{"data":{}}';
    });
}

# (a) type=track, offset=0 -> searchTracks, Web-API tracks.items shape.
{
    reset_all(); pf_seed(); pf_ops_rule();

    my ($result, $err);
    $SP->search('acct30', { q => 'radiohead', type => 'track', offset => 0, limit => 5 }, sub { ($result, $err) = @_ });

    my @q = pf_reqs();
    is(scalar(@q), 1, 'search track offset0: exactly one Pathfinder request');
    is(pf_vars($q[0])->{operationName}, 'searchTracks', 'search track offset0: the per-type op searchTracks');
    my $v = pf_vars($q[0])->{variables};
    ok($v->{searchTerm} eq 'radiohead' && $v->{offset} == 0 && $v->{limit} == 5, 'search track offset0: searchTerm, offset and limit travel in the variables');
    is(scalar(grep { $_->{url} =~ m{/context-resolve/|/metadata/4/} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 0, 'search track offset0: no context-resolve and no metadata/4 request');
    ok($result && !$err, 'search track offset0: result returned');
    is($result->{tracks}{total}, $PFX->{searchTracks}{data}{searchV2}{tracksV2}{totalCount}, 'search track offset0: total follows Pathfinder totalCount');
    is(scalar(@{ $result->{tracks}{items} }), 3, 'search track offset0: tracks.items mapped');
    my $t = $result->{tracks}{items}[0];
    ok($t->{id} && $t->{uri} =~ /^spotify:track:/ && $t->{name} && $t->{duration_ms} > 0 && $t->{artists}[0]{name} && $t->{album}{name} && $t->{album}{images}[0]{url},
        'search track offset0: items carry id, uri, name, duration_ms, artists, album and album images (Web-API shape)');
    is(scalar(@Plugins::SpotOn::API::Client::search_calls), 0, 'search track offset0: Client.pm NOT delegated to');
    ok(!$result->{limited}, 'search track offset0: not flagged limited');
}

# (b) one type of album / artist / playlist / show -> its per-type op
for my $c (['album', 'searchAlbums', 'albums'], ['artist', 'searchArtists', 'artists'],
           ['playlist', 'searchPlaylists', 'playlists'], ['show', 'searchPodcasts', 'shows']) {
    my ($type, $op, $key) = @$c;
    reset_all(); pf_seed(); pf_ops_rule();
    my ($result, $err);
    $SP->search('acct31', { q => 'radiohead', type => $type }, sub { ($result, $err) = @_ });
    my @q = pf_reqs();
    ok(scalar(@q) == 1 && pf_vars($q[0])->{operationName} eq $op && scalar(@Plugins::SpotOn::API::Client::search_calls) == 0,
        "search type=$type: one $op request via Pathfinder, no Client.pm call (S-05 delegation gone)");
    ok($result && @{ $result->{$key}{items} } >= 2, "search type=$type: $key.items mapped");
}

# GenericError items (podcasts) keep their slot as a nameless {} (79-58, GH #168: list positions stay
# equal to Spotify's offsets; the menus turn the slot into an ignore row)
{
    reset_all(); pf_seed(); pf_ops_rule();
    my ($result);
    $SP->search('acct31b', { q => 'jazz', type => 'show' }, sub { ($result) = @_ });
    my @named = grep { defined $_->{name} } @{ $result->{shows}{items} };
    is(scalar(@named), 2, 'search type=show: two mapped podcast items');
    is(scalar(@{ $result->{shows}{items} }), scalar(@{ $PFX->{searchDesktop}{data}{searchV2}{podcasts}{items} }),
        'search type=show: the GenericError podcast item keeps its slot (one entry per raw item)');
    is($result->{shows}{total}, $PFX->{searchDesktop}{data}{searchV2}{podcasts}{totalCount}, 'search type=show: total is the totalCount');
}

# (c) type=track, offset=20 -> searchTracks at offset 20 (no 20-result context-resolve ceiling any more)
{
    reset_all(); pf_seed(); pf_ops_rule();

    my ($result, $err);
    $SP->search('acct32', { q => 'radiohead', type => 'track', offset => 20, limit => 10 }, sub { ($result, $err) = @_ });

    my @q = pf_reqs();
    is(scalar(@q), 1, 'search track offset20: exactly one Pathfinder request at offset 20');
    ok(scalar(@q) == 1 && pf_vars($q[0])->{operationName} eq 'searchTracks' && pf_vars($q[0])->{variables}{offset} == 20
        && scalar(@Plugins::SpotOn::API::Client::search_calls) == 0,
        'search track offset20: searchTracks via Pathfinder, no Client.pm call');
}

# multi-type -> ONE searchDesktop request
{
    reset_all(); pf_seed(); pf_ops_rule();

    my ($result, $err);
    $SP->search('acct33', { q => 'radiohead', type => 'track,album,artist,playlist', limit => 10, offset => 0 }, sub { ($result, $err) = @_ });
    my @q = pf_reqs();
    ok(scalar(@q) == 1 && pf_vars($q[0])->{operationName} eq 'searchDesktop', 'search track,album,artist,playlist: exactly one searchDesktop request');
    is_deeply([ sort keys %{ $result || {} } ], [ qw(albums artists playlists tracks) ], 'search track,album,artist,playlist: one section per requested type');
    is(scalar(@{ $result->{playlists}{items} }), 3, 'search multi-type: playlists mapped (ownerV2 name, images)');
    is($result->{playlists}{items}[0]{owner}{display_name}, 'Spotify', 'search multi-type: playlist owner display_name from ownerV2.data.name');
    is(scalar(@Plugins::SpotOn::API::Client::search_calls), 0, 'search multi-type: Client.pm NOT delegated to');
}

# episode -> the episodes section of searchDesktop
{
    reset_all(); pf_seed(); pf_ops_rule();
    my ($result);
    $SP->search('acct33b', { q => 'jazz', type => 'episode', limit => 10, offset => 0 }, sub { ($result) = @_ });
    my @q = pf_reqs();
    ok(scalar(@q) == 1 && pf_vars($q[0])->{operationName} eq 'searchDesktop', 'search type=episode: one searchDesktop request');
    ok($result && @{ $result->{episodes}{items} } == 3 && $result->{episodes}{items}[0]{show}{name} && $result->{episodes}{items}[0]{release_date} =~ /^\d{4}-\d\d-\d\d$/,
        'search type=episode: episodes mapped with show and release_date');
}

# DSTM: q = artist:"<name>"
{
    reset_all(); pf_seed(); pf_ops_rule();
    my ($result);
    $SP->search('acct34', { q => 'artist:"artist 2"', type => 'track', limit => 10, offset => 0 }, sub { ($result) = @_ });
    my @q = pf_reqs();
    my @kept = grep { defined $_->{name} } @{ $result->{tracks}{items} };
    ok(scalar(@q) == 1 && pf_vars($q[0])->{variables}{searchTerm} eq 'artist 2'
        && scalar(@kept) == 1 && $kept[0]{artists}[0]{name} eq 'Artist 2',
        'search artist:"<name>": searchTerm is the bare name, track items kept only for that artist (case-insensitive)');
    ok(!grep({ !defined $_->{name} && keys %$_ } @{ $result->{tracks}{items} }),
        'search artist:"<name>": every other track is an empty slot {} (79-58), not a row of another artist');
}

# Pathfinder failing -> track results from the existing context-resolve path, flagged limited
{
    reset_all(); pf_seed();
    Slim::Networking::SimpleAsyncHTTP::set_error_for(qr{pathfinder/v2/query}, 500);
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/context-resolve/}, context_resolve_fixture());
    set_batch(data => sub { fixture_track_hash() });

    my ($result, $err);
    $SP->search('acct35', { q => 'radiohead', type => 'track', offset => 0, limit => 5 }, sub { ($result, $err) = @_ });
    ok($result && $result->{limited}, 'search degraded: Pathfinder failing flags the result limited');
    is(scalar(@{ $result->{tracks}{items} || [] }), 5, 'search degraded: track results come from context-resolve (limit 5)');
    is($result->{tracks}{total}, 20, 'search degraded: total is the 20-uri context-resolve window');
    is(scalar(@Plugins::SpotOn::API::Client::search_calls), 0, 'search degraded: Client.pm NOT delegated to');

    # deeper offset: empty page, limited
    my $r2;
    $SP->search('acct35', { q => 'radiohead', type => 'track', offset => 20, limit => 5 }, sub { ($r2) = @_ });
    ok($r2 && $r2->{limited} && !@{ $r2->{tracks}{items} }, 'search degraded: a track offset >= 20 answers an empty limited page');

    # another type: empty page, limited
    my $r3;
    $SP->search('acct35', { q => 'radiohead', type => 'album', offset => 0, limit => 5 }, sub { ($r3) = @_ });
    ok($r3 && $r3->{limited} && !@{ $r3->{albums}{items} }, 'search degraded: another type answers an empty limited page');
}

# no login5 credentials -> no_credentials, no request
{
    reset_all();
    $Plugins::SpotOn::API::Credentials::mock_creds = undef;
    my ($result, $err);
    $SP->search('acct36', { q => 'radiohead', type => 'track' }, sub { ($result, $err) = @_ });
    ok(!$result && ($err->{error} // '') eq 'no_credentials' && scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()) == 0,
        'search: without login5 credentials answers no_credentials and sends nothing');
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

# getSavedAlbums error paths (85-15: no Client.pm fallback; shared _collectionAll path).
{
    reset_all();
    $Plugins::SpotOn::API::Credentials::mock_creds = undef;

    my ($result, $err);
    $SP->getSavedAlbums('acct64', {}, sub { ($result, $err) = @_ });

    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 0, 'getSavedAlbums D-06: zero spclient HTTP when creds absent');
    is(scalar(@Plugins::SpotOn::API::Client::getSavedAlbums_calls), 0, 'getSavedAlbums D-06: never reaches Client.pm (85-15)');
    is(ref($err) eq 'HASH' ? $err->{error} : undef, 'no_credentials', 'getSavedAlbums D-06: answers (undef, {error=>no_credentials}) when creds absent');

    $Plugins::SpotOn::API::Credentials::mock_creds = { username => 'testuser', auth_data => 'ZGF0YQ==' };
}
{
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_500';

    my ($result, $err);
    $SP->getSavedAlbums('acct65', {}, sub { ($result, $err) = @_ });

    is(scalar(@Plugins::SpotOn::API::Client::getSavedAlbums_calls), 0, 'getSavedAlbums D-07: a spclient 500 never reaches Client.pm (85-15)');
    ok(!$result && ref($err) eq 'HASH' && $err->{code} == 500, 'getSavedAlbums D-07: the 500 reaches the caller unchanged');

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

# getFollowedArtists D-06: an account without credentials -> no_credentials,
# zero spclient HTTP, the Client stub is never called (85-15).
{
    reset_all();
    $Plugins::SpotOn::API::Credentials::mock_creds = undef;

    my ($result, $err);
    $SP->getFollowedArtists('acct71', {}, sub { ($result, $err) = @_ });

    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 0, 'getFollowedArtists D-06: zero spclient HTTP when creds absent');
    is(scalar(@Plugins::SpotOn::API::Client::getFollowedArtists_calls), 0, 'getFollowedArtists D-06: never reaches Client.pm (85-15)');
    is(ref($err) eq 'HASH' ? $err->{error} : undef, 'no_credentials', 'getFollowedArtists D-06: answers (undef, {error=>no_credentials})');

    $Plugins::SpotOn::API::Credentials::mock_creds = { username => 'testuser', auth_data => 'ZGF0YQ==' };
}

# getSavedShows: items nest under a show key (Web-API shape). 79-71: the names come from Pathfinder (getShow).
{
    reset_all();
    Slim::Utils::Cache->new()->set("spoton_pf_hash_$_", 'a' x 64) for qw(queryShowMetadataV2);
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/collection/v2/paging}, encode_page_response(
        items => [
            { uri => 'spotify:show:' . b62id(1), added_at => 5 },
            { uri => 'spotify:show:' . b62id(2), added_at => 6 },
        ],
    ));
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{pathfinder/v2/query},
        JSON::PP->new->utf8->encode($F71->{show_podcast}));

    my ($result, $err);
    $SP->getSavedShows('acct72', { offset => 0, limit => 50 }, sub { ($result, $err) = @_ });

    ok($result, 'getSavedShows: result returned');
    is($result->{total}, 2, 'getSavedShows: total reflects both collection items');
    is(scalar(@{ $result->{items} }), 2, 'getSavedShows: both items enriched');
    is($result->{items}[0]{show}{name}, "Der B\x{e4}tchcast", 'getSavedShows: item nests the show under a "show" key (Web-API shape)');
    ok(exists $result->{items}[0]{added_at}, 'getSavedShows: item carries added_at from the collection entry');
}

# getSavedShows: a failing show request (85-15: no probe, no Client.pm hand-over)
# keeps every slot as a minimal id/uri stub -- one request per show, one result.
{
    reset_all();
    Slim::Utils::Cache->new()->set("spoton_pf_hash_$_", 'a' x 64) for qw(queryShowMetadataV2);
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/collection/v2/paging}, encode_page_response(
        items => [
            { uri => 'spotify:show:' . b62id(1), added_at => 5 },
            { uri => 'spotify:show:' . b62id(2), added_at => 6 },
        ],
    ));
    Slim::Networking::SimpleAsyncHTTP::set_error_for(qr{pathfinder/v2/query}, 404);

    my ($result, $err);
    $SP->getSavedShows('acct73', { offset => 0, limit => 50 }, sub { ($result, $err) = @_ });

    my @showReqs = grep { $_->{url} =~ m{pathfinder/v2/query} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@showReqs), 2, 'getSavedShows 404: one show request per slice item (no probe, no whole-call hand-over)');
    is(scalar(@Plugins::SpotOn::API::Client::getSavedShows_calls), 0, 'getSavedShows 404: never reaches Client.pm (85-15)');
    is(ref($result) eq 'HASH' ? scalar(@{ $result->{items} || [] }) : -1, 2, 'getSavedShows 404: both slots survive as id/uri stubs (CR-01), no error');
}

# getSavedShows D-06: an account without credentials -> no_credentials, zero
# spclient HTTP, the Client stub is never called (85-15).
{
    reset_all();
    $Plugins::SpotOn::API::Credentials::mock_creds = undef;

    my ($result, $err);
    $SP->getSavedShows('acct74', {}, sub { ($result, $err) = @_ });

    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 0, 'getSavedShows D-06: zero spclient HTTP when creds absent');
    is(scalar(@Plugins::SpotOn::API::Client::getSavedShows_calls), 0, 'getSavedShows D-06: never reaches Client.pm (85-15)');
    is(ref($err) eq 'HASH' ? $err->{error} : undef, 'no_credentials', 'getSavedShows D-06: answers (undef, {error=>no_credentials})');

    $Plugins::SpotOn::API::Credentials::mock_creds = { username => 'testuser', auth_data => 'ZGF0YQ==' };
}

# ============================================================
# WR-02/WR-03 gap closure (Phase 75 Plan 07, Task 3)
# ============================================================

# WR-03: a next_page_token that always echoes the SAME non-empty value
# regardless of the request's own token -> the fetch loop terminates at or
# before COLLECTION_MAX_PAGES (100) page requests (completes without
# hanging) and still delivers the accumulated items via the normal success
# path, not an error.
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/collection/v2/paging}, sub {
        my ($body) = @_;
        my $fields = Plugins::SpotOn::API::ProtobufLite::parse_fields($body);
        my $token  = Plugins::SpotOn::API::ProtobufLite::field_first($fields, 3);
        if (!defined $token || $token eq '') {
            return encode_page_response(
                items           => [ { uri => 'spotify:album:' . b62id(1), added_at => 10 } ],
                next_page_token => 'sametoken',
            );
        }
        # Every subsequent request, regardless of the token it just sent,
        # gets the SAME 'sametoken' echoed back -- a malformed/adversarial
        # server response WR-03 must guard against.
        return encode_page_response(
            items           => [ { uri => 'spotify:album:' . b62id(2), added_at => 11 } ],
            next_page_token => 'sametoken',
        );
    });
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/album/}, album_fixture());

    my ($result, $err);
    $SP->getSavedAlbums('acct103', {}, sub { ($result, $err) = @_ });

    my @collReqs = grep { $_->{url} =~ m{/collection/v2/paging} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    ok(scalar(@collReqs) <= 100, 'WR-03: repeated-token loop terminates at or before COLLECTION_MAX_PAGES (100) page requests');
    ok(!$err, 'WR-03: repeated-token loop delivers via the normal success path, not an error');
    ok($result, 'WR-03: repeated-token loop still returns accumulated data');
}

# WR-02: getSavedShows honors _noCache -- two sequential calls with
# _noCache=>1 issue TWO separate collection/v2 POSTs (cache bypassed on
# demand, matching Plugin.pm:2088's call shape); a THIRD call immediately
# after WITHOUT _noCache issues zero additional POSTs (the bypass didn't
# disable the cache).
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/collection/v2/paging}, encode_page_response(
        items => [ { uri => 'spotify:show:' . b62id(1), added_at => 5 } ],
    ));
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/show/}, show_fixture());

    my $noop = sub { };
    $SP->getSavedShows('acct104', { _noCache => 1 }, $noop);
    my $count1 = scalar(grep { $_->{url} =~ m{/collection/v2/paging} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests());

    $SP->getSavedShows('acct104', { _noCache => 1 }, $noop);
    my $count2 = scalar(grep { $_->{url} =~ m{/collection/v2/paging} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests());

    $SP->getSavedShows('acct104', {}, $noop);
    my $count3 = scalar(grep { $_->{url} =~ m{/collection/v2/paging} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests());

    is($count1, 1, 'WR-02 _noCache: first _noCache=>1 call issues one collection/v2 POST');
    is($count2, 2, 'WR-02 _noCache: second _noCache=>1 call issues a SECOND collection/v2 POST (cache bypassed on demand)');
    is($count3, 2, 'WR-02 _noCache: third call WITHOUT _noCache issues zero additional POSTs (the bypass did not disable the cache)');
}

# WR-02: getSavedShows (cache populated) -> saveShows(...) -> getSavedShows
# again (no _noCache) -> issues a FRESH collection/v2 POST (write
# invalidated the cache), not a cache hit.
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/collection/v2/paging}, encode_page_response(
        items => [ { uri => 'spotify:show:' . b62id(1), added_at => 5 } ],
    ));
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/show/}, show_fixture());

    my $noop = sub { };
    $SP->getSavedShows('acct105', {}, $noop);
    my $countBefore = scalar(grep { $_->{url} =~ m{/collection/v2/paging} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests());

    $SP->saveShows('acct105', [ 'spotify:show:' . b62id(2) ], $noop);

    $SP->getSavedShows('acct105', {}, $noop);
    my $countAfter = scalar(grep { $_->{url} =~ m{/collection/v2/paging} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests());

    is($countBefore, 1, 'WR-02 write-invalidation: first getSavedShows call issues one collection/v2 POST');
    is($countAfter, 2, 'WR-02 write-invalidation: getSavedShows after saveShows issues a FRESH collection/v2 POST (cache invalidated by the write)');
}

# WR-02: saveTracks/removeTracks invalidate the Liked Songs cache key
# directly (raw cache check, not a fetch round-trip).
{
    reset_all();
    my $rawCache = Slim::Utils::Cache->new();
    $rawCache->set('spoton_spclient_liked_acct106', [ 'spotify:track:' . b62id(1) ], 60);
    ok($rawCache->get('spoton_spclient_liked_acct106'), 'WR-02 saveTracks: Liked Songs cache populated before the write');

    my $noop = sub { };
    $SP->saveTracks('acct106', [ 'spotify:track:' . b62id(2) ], $noop);
    ok(!$rawCache->get('spoton_spclient_liked_acct106'), 'WR-02 saveTracks: Liked Songs cache key removed after saveTracks');

    $rawCache->set('spoton_spclient_liked_acct106', [ 'spotify:track:' . b62id(1) ], 60);
    ok($rawCache->get('spoton_spclient_liked_acct106'), 'WR-02 removeTracks: Liked Songs cache re-populated before the write');

    $SP->removeTracks('acct106', [ 'spotify:track:' . b62id(2) ], $noop);
    ok(!$rawCache->get('spoton_spclient_liked_acct106'), 'WR-02 removeTracks: Liked Songs cache key removed after removeTracks');
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
    $bytes .= Plugins::SpotOn::API::ProtobufLite::encode_field(3, 2, $args{trackUri})
        if defined $args{trackUri};
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
    set_batch(data => sub { fixture_track_hash() });

    my ($result, $err);
    $SP->getSavedTracks('acct80', { offset => 10, limit => 10 }, sub { ($result, $err) = @_ });

    ok($result, 'getSavedTracks: result returned');
    is($result->{total}, 25, 'getSavedTracks: total reflects the FULL liked-songs list (25), not the slice');
    is(scalar(@{ $result->{items} }), 10, 'getSavedTracks: items sliced to the requested limit (10)');

    # 79-27 (was: exactly limit-many (10) metadata/4/track GETs): the 10 sliced ids, not all 25, travel in ONE POST
    my @posts = batch_posts();
    is(scalar(@posts) . '/' . scalar(track_gets()) . '/' . join(',', map { scalar(post_uris($_)) } @posts), '1/0/10',
        'getSavedTracks: exactly limit-many (10) ids in ONE extended-metadata POST, no track GET -- sliced, not all 25');
    is(join(',', post_uris($posts[0])), join(',', map { 'spotify:track:' . b62id($_) } 11 .. 20),
        'getSavedTracks: the POST carries the sliced ids 11..20 (offset 10), in order');
    is($result->{items}[0]{track}{name}, 'Test Track', 'getSavedTracks: item wraps the enriched track under a "track" key (Web-API shape)');
}

# getSavedTracks error paths (85-15: no Client.pm fallback).
{
    reset_all();
    $Plugins::SpotOn::API::Credentials::mock_creds = undef;

    my ($result, $err);
    $SP->getSavedTracks('acct81', {}, sub { ($result, $err) = @_ });

    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 0, 'getSavedTracks D-06: zero spclient HTTP when creds absent');
    is(scalar(@Plugins::SpotOn::API::Client::getSavedTracks_calls), 0, 'getSavedTracks D-06: never reaches Client.pm (85-15)');
    is(ref($err) eq 'HASH' ? $err->{error} : undef, 'no_credentials', 'getSavedTracks D-06: answers (undef, {error=>no_credentials})');

    $Plugins::SpotOn::API::Credentials::mock_creds = { username => 'testuser', auth_data => 'ZGF0YQ==' };
}
{
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_500';

    my ($result, $err);
    $SP->getSavedTracks('acct82', {}, sub { ($result, $err) = @_ });

    is(scalar(@Plugins::SpotOn::API::Client::getSavedTracks_calls), 0, 'getSavedTracks D-07: a context-resolve 500 never reaches Client.pm (85-15)');
    ok(!$result && ref($err) eq 'HASH' && $err->{code} == 500, 'getSavedTracks D-07: the 500 reaches the caller unchanged');

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

# 85-16 (live finding): the REAL layout -- field 1 is the context (playlist/album), field 2 the played-at ms,
# field 3 the track. Three entries (two contexts with a track, one context without any track field) -> two track items.
{
    reset_all();
    my $rpReal = encode_recently_played(
        { uri => q(spotify:playlist:) . b62id(2), lastPlayedTime => 1_792_155_241_398, trackUri => q(spotify:track:) . b62id(5) },
        { uri => q(spotify:album:)    . b62id(3), lastPlayedTime => 1_792_094_575_077 },
        { uri => q(spotify:album:)    . b62id(4), lastPlayedTime => 1_792_084_847_574, trackUri => q(spotify:track:) . b62id(6) },
    );
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/recently-played/v3/}, $rpReal);
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/track/}, to_json_fixture());
    my ($result, $err);
    $SP->getRecentlyPlayed(q(acct93), {}, sub { ($result, $err) = @_ });
    ok($result, q(getRecentlyPlayed: real-layout fixture returned));
    is(scalar(@{ $result->{items} }), 2, q(getRecentlyPlayed: real layout -- the track comes from field 3 (85-16), the entry without a track is skipped));
    is($result->{items}[0]{played_at}, 1_792_155_241_398, q(getRecentlyPlayed: real layout -- played_at is field 2 of the entry));
    is($result->{items}[1]{played_at}, 1_792_084_847_574, q(getRecentlyPlayed: real layout -- second entry played_at));
}

# getRecentlyPlayed error paths (85-15: no Client.pm fallback).
{
    reset_all();
    $Plugins::SpotOn::API::Credentials::mock_creds = undef;

    my ($result, $err);
    $SP->getRecentlyPlayed('acct85', {}, sub { ($result, $err) = @_ });

    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 0, 'getRecentlyPlayed D-06: zero spclient HTTP when creds absent');
    is(scalar(@Plugins::SpotOn::API::Client::getRecentlyPlayed_calls), 0, 'getRecentlyPlayed D-06: never reaches Client.pm (85-15)');
    is(ref($err) eq 'HASH' ? $err->{error} : undef, 'no_credentials', 'getRecentlyPlayed D-06: answers (undef, {error=>no_credentials})');

    $Plugins::SpotOn::API::Credentials::mock_creds = { username => 'testuser', auth_data => 'ZGF0YQ==' };
}
{
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_500';

    my ($result, $err);
    $SP->getRecentlyPlayed('acct86', {}, sub { ($result, $err) = @_ });

    is(scalar(@Plugins::SpotOn::API::Client::getRecentlyPlayed_calls), 0, 'getRecentlyPlayed D-07: a spclient 500 never reaches Client.pm (85-15)');
    ok(!$result && ref($err) eq 'HASH' && $err->{code} == 500, 'getRecentlyPlayed D-07: the 500 reaches the caller unchanged');

    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
}

# ============================================================
# Phase 75 Plan 05 fixtures -- rootlist (ListContent in field 5), Task 1
# The live server wraps items in Response.field_5 (ListContent), with
# item URIs in field 5.3[].1 and decorations in field 5.4[].
# ============================================================

# encode_rootlist_item($uri): Item { field 1 = URI }
sub encode_rootlist_item {
    my ($uri) = @_;
    return Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $uri);
}

# encode_rootlist_decoration(%args): { field 1 = revision, field 2 = attributes{name=1, picture=3, picture_size=13*},
# field 3 = track_count, field 5 = owner }. picture is raw bytes (20 for a cover); picture_size is [[target, url], ...].
# The attributes submessage is written when name, picture or picture_size is given; name stays its first field.
sub encode_rootlist_decoration {
    my (%args) = @_;
    my $bytes = '';
    $bytes .= Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $args{revision})
        if defined $args{revision};
    if (defined $args{name} || defined $args{picture} || $args{picture_size}) {
        my $attrs = '';
        $attrs .= Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $args{name}) if defined $args{name};
        $attrs .= Plugins::SpotOn::API::ProtobufLite::encode_field(3, 2, $args{picture}) if defined $args{picture};
        for my $ps (@{ $args{picture_size} || [] }) {
            my $one = Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $ps->[0])
                    . Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, $ps->[1]);
            $attrs .= Plugins::SpotOn::API::ProtobufLite::encode_field(13, 2, $one);
        }
        $bytes .= Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, $attrs);
    }
    $bytes .= Plugins::SpotOn::API::ProtobufLite::encode_field(3, 0, $args{track_count} // 0);
    $bytes .= Plugins::SpotOn::API::ProtobufLite::encode_field(5, 2, $args{owner})
        if defined $args{owner};
    return $bytes;
}

# encode_rootlist_response(@items, @decorations): Response { field 5 = ListContent { field 3 = items, field 4 = decorations } }
sub encode_rootlist_response {
    my ($items_ref, $decorations_ref) = @_;
    my $listContent = '';
    $listContent .= Plugins::SpotOn::API::ProtobufLite::encode_field(3, 2, $_) for @$items_ref;
    $listContent .= Plugins::SpotOn::API::ProtobufLite::encode_field(4, 2, $_) for @$decorations_ref;
    return Plugins::SpotOn::API::ProtobufLite::encode_field(5, 2, $listContent);
}

# ============================================================
# Task 1: getUserPlaylists via rootlist (protobuf-only, S-10)
# ============================================================

# Flat ListContent fixture: 3 playlists with decorations (live server
# wraps items in Response.field_5, not a nested Folder tree).
{
    reset_all();

    my @items = (
        encode_rootlist_item('spotify:playlist:' . b62id(1)),
        encode_rootlist_item('spotify:playlist:' . b62id(2)),
        encode_rootlist_item('spotify:playlist:' . b62id(3)),
    );
    my @decos = (
        encode_rootlist_decoration(name => 'Top Playlist One',   owner => 'testuser', track_count => 42),
        encode_rootlist_decoration(name => 'Top Playlist Two',   owner => 'testuser', track_count => 10),
        encode_rootlist_decoration(name => 'Nested Playlist Three', owner => 'testuser', track_count => 5),
    );
    my $rootlistBytes = encode_rootlist_response(\@items, \@decos);

    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/playlist/v2/user/.+/rootlist}, $rootlistBytes);

    my ($result, $err);
    $SP->getUserPlaylists('acct90', {}, sub { ($result, $err) = @_ });

    ok($result, 'getUserPlaylists: result returned');
    is($result->{total}, 3, 'getUserPlaylists: ListContent fixture yields 3 playlists');
    is(scalar(@{ $result->{items} }), 3, 'getUserPlaylists: all 3 items present in the sliced page');
    is($result->{items}[0]{uri}, 'spotify:playlist:' . b62id(1), 'getUserPlaylists: playlist 1 uri preserved');
    is($result->{items}[1]{uri}, 'spotify:playlist:' . b62id(2), 'getUserPlaylists: playlist 2 uri preserved');
    is($result->{items}[2]{uri}, 'spotify:playlist:' . b62id(3), 'getUserPlaylists: playlist 3 uri preserved');
    is($result->{items}[2]{name}, 'Nested Playlist Three', 'getUserPlaylists: playlist name decoded from decoration attributes');
    # 261110-k1b (#200, deliberate change of the old expectation 'testuser'): the account's own playlists
    # leave the owner line empty, the owner id keeps the raw user name.
    is($result->{items}[0]{owner}{display_name}, '', 'k1b T1 owner: own playlist has an empty owner line');
    is($result->{items}[0]{owner}{id}, 'testuser', 'k1b T1 owner: owner id keeps the raw user name');

    my @rootlistReqs = grep { $_->{url} =~ m{/rootlist} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@rootlistReqs), 1, 'getUserPlaylists: exactly one rootlist request');
    like($rootlistReqs[0]->{url}, qr{/user/testuser/rootlist}, 'getUserPlaylists: URL uses the credentials.json username');
    # 85-16 (live finding): spclient answers the rootlist as JSON (gzip, 53 KB) when the request says
    # Accept: application/json, and the protobuf parser then reports parse_error -- Library -> Playlists
    # rendered "Keine Ergebnisse" for an account with 96 playlists. The request must ask for protobuf.
    is($rootlistReqs[0]->{headers}{Accept}, q(application/x-protobuf),
        q(getUserPlaylists: the rootlist request asks for protobuf, not JSON (85-16 live finding)));
}

# 85-16 (live finding): the names inside the protobuf rootlist are UTF-8 BYTES; without a decode the menu
# (JSON-encoded by LMS) showed "T\xc3\x83\xc2\xbcrk..." mojibake for a playlist named with umlauts. Names and owners
# must reach the caller as characters.
{
    reset_all();
    require Encode;
    my $umlaut = "T\x{fc}rk\x{fc}lerimiz";
    my $bytes  = Encode::encode(q(UTF-8), $umlaut);
    my @items  = (encode_rootlist_item(q(spotify:playlist:) . b62id(1)));
    my @decos  = (encode_rootlist_decoration(name => $bytes, owner => Encode::encode(q(UTF-8), "J\x{fc}rgen"), track_count => 3));
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/playlist/v2/user/.+/rootlist}, encode_rootlist_response(\@items, \@decos));
    my ($result, $err);
    $SP->getUserPlaylists(q(acct92), {}, sub { ($result, $err) = @_ });
    ok($result, q(getUserPlaylists: umlaut fixture returned));
    is($result->{items}[0]{name}, $umlaut, q(getUserPlaylists: the playlist name is decoded from UTF-8 bytes into characters (85-16)));
    ok(utf8::is_utf8($result->{items}[0]{name}), q(getUserPlaylists: the decoded name carries the utf8 flag));
    is($result->{items}[0]{owner}{display_name}, "J\x{fc}rgen", q(getUserPlaylists: the owner name is decoded as well));
}

# Malformed rootlist bytes -> parse_error to the caller (85-15: no Client.pm
# delegation), no die (T-75-12).
{
    reset_all();
    my $malformed = pack('C*', 0xFF, 0x00, 0xAB, 0xCD, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF);
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/playlist/v2/user/.+/rootlist}, $malformed);

    my ($result, $err);
    $SP->getUserPlaylists('acct91', {}, sub { ($result, $err) = @_ });

    is(scalar(@Plugins::SpotOn::API::Client::getUserPlaylists_calls), 0,
        'getUserPlaylists: malformed rootlist bytes never reach Client.pm (85-15/T-75-12), no die');
    is(ref($err) eq 'HASH' ? $err->{error} : undef, 'parse_error',
        'getUserPlaylists: malformed rootlist bytes answer (undef, {error=>parse_error})');
}

# 261110-k1b Task 1 (#200): covers from the rootlist reply (picture, picture_size) and the owner line rule
# (own -> empty, 'spotify' -> OWNER_FIXED_NAMES, other -> the user name), no new request.
{
    reset_all();
    # inert in Task 1 (the rootlist-only path); keeps this block rootlist-only once libraryV3 exists
    Slim::Utils::Cache->new()->set('spoton_pf_hash_libraryV3', 'a' x 64);
    Slim::Networking::SimpleAsyncHTTP::set_error_for(qr{pathfinder/v2/query}, 400);

    my $pic1 = 'ab67706c0000da84' . ('aa' x 12);
    my @defs = (
        [ b62id(1), name => 'Own With Picture', owner => 'testuser',   picture => pack('H*', $pic1) ],
        [ b62id(2), name => 'Spotify Made',     owner => 'spotify',
            picture_size => [ [ 'default', 'https://i.scdn.co/image/ab67616d0000b273' . ('bb' x 12) ],
                              [ 'small',   'https://pickasso.spotifycdn.com/image/ab67c0de0000deef/dt/v1/img/x' ] ] ],
        [ b62id(3), name => 'Foreign Plain',    owner => 'someoneelse' ],
        [ b62id(4), name => 'Own Bad Urls',     owner => 'testuser',   picture => 'short',
            picture_size => [ [ 'a', 'http://i.scdn.co/image/plain' ],
                              [ 'b', 'https://evil.example/x.jpg' ],
                              [ 'c', 'https://i.scdn.co.evil.example/x.jpg' ] ] ],
        [ b62id(5), name => 'Prefix Owner',     owner => 'spotifyfan' ],
    );
    my (@items, @decos);
    for my $d (@defs) {
        my ($id, %a) = @$d;
        push @items, encode_rootlist_item('spotify:playlist:' . $id);
        push @decos, encode_rootlist_decoration(%a, track_count => 3);
    }
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/playlist/v2/user/.+/rootlist}, encode_rootlist_response(\@items, \@decos));

    my ($result, $err);
    eval { $SP->getUserPlaylists('acct95', {}, sub { ($result, $err) = @_ }); 1 } or diag "k1b T1: getUserPlaylists died: $@";
    my @it = @{ ($result && $result->{items}) || [] };
    my ($p1, $p2, $p3, $p4, $p5) = map { $it[$_] || {} } 0 .. 4;
    my @urls2 = map { $_->{url} } @{ $p2->{images} || [] };

    is($p1->{images} && $p1->{images}[0] ? $p1->{images}[0]{url} : undef, 'https://i.scdn.co/image/' . $pic1,
        'k1b T1 cover: a 20 byte picture becomes the i.scdn.co image url');
    is(scalar(@{ $p1->{images} || [] }), 1, 'k1b T1 cover: a picture alone gives exactly one image');
    is_deeply(\@urls2, [ 'https://i.scdn.co/image/ab67616d0000b273' . ('bb' x 12),
                         'https://pickasso.spotifycdn.com/image/ab67c0de0000deef/dt/v1/img/x' ],
        'k1b T1 cover: picture_size urls are kept in received order');
    is_deeply($p3->{images}, [], 'k1b T1 cover: no picture gives no image');
    is_deeply($p4->{images}, [], 'k1b T1 cover: a short picture, http, a foreign host and a suffix trick give no image');

    is($p1->{owner}{display_name}, '', 'k1b T1 owner: own playlist has an empty owner line');
    is($p1->{owner}{id}, 'testuser', 'k1b T1 owner: owner id keeps the raw user name');
    is($p2->{owner}{display_name}, 'Spotify', 'k1b T1 owner: owner spotify shows Spotify');
    is($p2->{owner}{id}, 'spotify', 'k1b T1 owner: the spotify owner id keeps the raw user name');
    is($p3->{owner}{display_name}, 'someoneelse', 'k1b T1 owner: a foreign owner shows the user name until a name is known');
    is($p5->{owner}{display_name}, 'spotifyfan', 'k1b T1 owner: a user name that starts with spotify is not the fixed name');

    my $fixed = $SP->can('OWNER_FIXED_NAMES') ? $SP->OWNER_FIXED_NAMES : undef;
    is_deeply([ sort keys %{ ref($fixed) eq 'HASH' ? $fixed : {} } ], [ 'spotify' ], 'k1b T1 const: OWNER_FIXED_NAMES has exactly the key spotify');
    is(ref($fixed) eq 'HASH' ? $fixed->{spotify} : undef, 'Spotify', 'k1b T1 const: the fixed name of spotify is Spotify');
}

# Non-playlist URIs in items are skipped (e.g. start-group/end-group markers).
{
    reset_all();

    my @items = (
        encode_rootlist_item('spotify:playlist:' . b62id(1)),
        encode_rootlist_item('spotify:start-group:v2:folder-name'),
        encode_rootlist_item('spotify:playlist:' . b62id(2)),
    );
    my @decos = (
        encode_rootlist_decoration(name => 'Real Playlist', owner => 'user1', track_count => 5),
        encode_rootlist_decoration(),
        encode_rootlist_decoration(name => 'Another Playlist', owner => 'user1', track_count => 3),
    );
    my $bytes = encode_rootlist_response(\@items, \@decos);
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/playlist/v2/user/.+/rootlist}, $bytes);

    my ($result, $err);
    $SP->getUserPlaylists('acct94', {}, sub { ($result, $err) = @_ });

    ok($result, 'getUserPlaylists: non-playlist URIs skipped without crash');
    is($result->{total}, 2, 'getUserPlaylists: start-group URI filtered out, only 2 playlists');
}

# getUserPlaylists error paths (85-15: no Client.pm fallback).
{
    reset_all();
    $Plugins::SpotOn::API::Credentials::mock_creds = undef;

    my ($result, $err);
    $SP->getUserPlaylists('acct92', {}, sub { ($result, $err) = @_ });

    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 0, 'getUserPlaylists D-06: zero spclient HTTP when creds absent');
    is(scalar(@Plugins::SpotOn::API::Client::getUserPlaylists_calls), 0, 'getUserPlaylists D-06: never reaches Client.pm (85-15)');
    is(ref($err) eq 'HASH' ? $err->{error} : undef, 'no_credentials', 'getUserPlaylists D-06: answers (undef, {error=>no_credentials})');

    $Plugins::SpotOn::API::Credentials::mock_creds = { username => 'testuser', auth_data => 'ZGF0YQ==' };
}
{
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_500';

    my ($result, $err);
    $SP->getUserPlaylists('acct93', {}, sub { ($result, $err) = @_ });

    is(scalar(@Plugins::SpotOn::API::Client::getUserPlaylists_calls), 0, 'getUserPlaylists D-07: a rootlist 500 never reaches Client.pm (85-15)');
    ok(!$result && ref($err) eq 'HASH' && $err->{code} == 500, 'getUserPlaylists D-07: the 500 reaches the caller unchanged');

    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
}

# ============================================================
# Phase 75 Plan 05 fixtures -- playlist/v2 (JSON contents envelope), Task 2
# ============================================================

sub playlist_envelope_fixture {
    my ($n) = @_;
    my @items = map { { uri => 'spotify:track:' . b62id($_) } } (1 .. $n);
    return JSON::XS::VersionOneAndTwo::to_json({
        revision   => 'abc123',
        length     => $n,
        attributes => { name => 'Test Playlist' },
        contents   => { items => \@items, pos => 0, truncated => 0 },
    });
}

# track_fixture_for_id($id): a metadata/4/track fixture whose gid is derived
# from $id (unlike to_json_fixture()'s always-fixed gid) -- needed whenever a
# test must distinguish enriched tracks by which id was actually requested
# (e.g. a duplicate-tracks regression check across chained pages).
sub track_fixture_for_id {
    my ($id) = @_;
    require JSON::XS::VersionOneAndTwo;
    return JSON::XS::VersionOneAndTwo::to_json({
        gid      => $SP->idToHex($id),
        name     => "Track $id",
        duration => 200000,
        explicit => 0,
        artist   => [],
        album    => {},
    });
}

# playlist_mixed_envelope_fixture: 3 spotify:track: URIs interleaved with 2
# non-track URIs (episode + local file) -- CR-01 regression fixture. Envelope
# length (5) intentionally differs from the track-only count (3).
sub playlist_mixed_envelope_fixture {
    my @items = (
        { uri => 'spotify:track:'   . b62id(1) },
        { uri => 'spotify:episode:' . b62id(2) },
        { uri => 'spotify:track:'   . b62id(3) },
        { uri => 'spotify:local:'   . b62id(4) },
        { uri => 'spotify:track:'   . b62id(5) },
    );
    return JSON::XS::VersionOneAndTwo::to_json({
        revision   => 'abc123',
        length     => scalar(@items),
        attributes => { name => 'Mixed Content Playlist' },
        contents   => { items => \@items, pos => 0, truncated => 0 },
    });
}

# ============================================================
# Task 2: getPlaylistItems via playlist/v2 (JSON) with sliced enrichment
# ============================================================

# Slice test: 5-track envelope, offset=0/limit=3 -> exactly 3 enrichment
# calls, total reported 5 (the full envelope length, not the slice).
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/playlist/v2/playlist/}, playlist_envelope_fixture(5));
    set_batch(data => sub { fixture_track_hash() });

    my ($result, $err);
    $SP->getPlaylistItems('acct95', 'testplaylist0000000001', { offset => 0, limit => 3 }, sub { ($result, $err) = @_ });

    ok($result, 'getPlaylistItems: result returned');
    is($result->{total}, 5, 'getPlaylistItems: total reflects the FULL envelope length (5), not the slice');
    is(scalar(@{ $result->{items} }), 3, 'getPlaylistItems: items sliced to the requested limit (3)');

    # 79-27 (was: exactly limit-many (3) metadata/4/track GETs): the 3 sliced ids, not all 5, travel in ONE POST
    my @posts = batch_posts();
    is(scalar(@posts) . '/' . scalar(track_gets()) . '/' . join(',', map { scalar(post_uris($_)) } @posts), '1/0/3',
        'getPlaylistItems: exactly limit-many (3) ids in ONE extended-metadata POST, no track GET -- sliced, not all 5');
    is($result->{items}[0]{track}{name}, 'Test Track', 'getPlaylistItems: item wraps the enriched track under a "track" key (Web-API shape)');
}

# Envelope cache test: two sequential getPlaylistItems calls (different
# offsets) within TTL share ONE playlist/v2 GET (300s envelope cache).
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/playlist/v2/playlist/}, playlist_envelope_fixture(5));
    set_batch(data => sub { fixture_track_hash() });

    my ($r1, $e1);
    $SP->getPlaylistItems('acct96', 'testplaylist0000000002', { offset => 0, limit => 2 }, sub { ($r1, $e1) = @_ });
    my $firstEnvCount = scalar(grep { $_->{url} =~ m{/playlist/v2/playlist/} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests());

    my ($r2, $e2);
    $SP->getPlaylistItems('acct96', 'testplaylist0000000002', { offset => 2, limit => 2 }, sub { ($r2, $e2) = @_ });
    my $secondEnvCount = scalar(grep { $_->{url} =~ m{/playlist/v2/playlist/} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests());

    is($firstEnvCount, 1, 'getPlaylistItems: first call issues one playlist/v2 GET');
    is($secondEnvCount, $firstEnvCount, 'getPlaylistItems: second call within TTL issues zero additional playlist/v2 GETs (300s envelope cache)');
    is($r2->{total}, 5, 'getPlaylistItems: cached-envelope second call still reports the full total (5)');
}

# An account without credentials -> no_credentials (D-06), zero spclient HTTP, no Client.pm (85-15).
{
    reset_all();
    $Plugins::SpotOn::API::Credentials::mock_creds = undef;

    my ($result, $err);
    $SP->getPlaylistItems('acct97', 'testplaylist0000000003', {}, sub { ($result, $err) = @_ });

    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 0, 'getPlaylistItems D-06: zero spclient HTTP when creds absent');
    is(scalar(@Plugins::SpotOn::API::Client::getPlaylistItems_calls), 0, 'getPlaylistItems D-06: never reaches Client.pm (85-15)');
    is(ref($err) eq 'HASH' ? $err->{error} : undef, 'no_credentials', 'getPlaylistItems D-06: answers (undef, {error=>no_credentials})');

    $Plugins::SpotOn::API::Credentials::mock_creds = { username => 'testuser', auth_data => 'ZGF0YQ==' };
}

# D-07: playlist/v2 500 -> passed to the caller, Client.pm never reached (85-15).
{
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_500';

    my ($result, $err);
    $SP->getPlaylistItems('acct98', 'testplaylist0000000004', {}, sub { ($result, $err) = @_ });

    is(scalar(@Plugins::SpotOn::API::Client::getPlaylistItems_calls), 0, 'getPlaylistItems D-07: a playlist/v2 500 never reaches Client.pm (85-15)');
    ok(!$result && ref($err) eq 'HASH' && $err->{code} == 500, 'getPlaylistItems D-07: the 500 reaches the caller unchanged');

    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
}

# WR-04 (gap closure 75-07 Task 2): a malformed playlistId (containing '/')
# is rejected with { error => 'invalid_id' } BEFORE any spclient HTTP request
# or Client.pm call -- distinct from the no_credentials / error paths above
# (tested with valid 22-char fixture ids).
{
    reset_all();

    my ($result, $err);
    $SP->getPlaylistItems('acct99a', 'not/a/valid/playlist/id', {}, sub { ($result, $err) = @_ });

    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 0,
        'WR-04: malformed playlistId (contains /) -- zero spclient HTTP requests');
    is(scalar(@Plugins::SpotOn::API::Client::getPlaylistItems_calls), 0,
        'WR-04: malformed playlistId (contains /) -- zero Client.pm delegations (hard validation error, not D-06/D-07)');
    is($err->{error}, 'invalid_id', 'WR-04: malformed playlistId (contains /) returns { error => invalid_id }');
}

# WR-04: a too-short playlistId (10 chars, valid charset) is also rejected
# the same way.
{
    reset_all();

    my ($result, $err);
    $SP->getPlaylistItems('acct99b', 'shortid123', {}, sub { ($result, $err) = @_ });

    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 0,
        'WR-04: too-short playlistId -- zero spclient HTTP requests');
    is(scalar(@Plugins::SpotOn::API::Client::getPlaylistItems_calls), 0,
        'WR-04: too-short playlistId -- zero Client.pm delegations');
    is($err->{error}, 'invalid_id', 'WR-04: too-short playlistId returns { error => invalid_id }');
}

# ============================================================
# CR-01 gap closure (Phase 75 Plan 07, Task 1) -- mixed-content windows,
# offset-advance-by-returned-count chaining, and partial-enrichment-failure
# windows must never desync total/items or drop items below the requested
# window size.
# ============================================================

# Mixed-content window: 5-item envelope (3 track + 2 non-track), offset=0/
# limit=3 -> total reflects the 3 FILTERED track URIs (not the raw envelope
# length of 5), and items is exactly the track-filtered slice.
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/playlist/v2/playlist/}, playlist_mixed_envelope_fixture());
    set_batch(data => sub { fixture_track_hash() });

    my ($result, $err);
    $SP->getPlaylistItems('acct99', 'testplaylist0000000005', { offset => 0, limit => 3 }, sub { ($result, $err) = @_ });

    ok($result, 'CR-01 mixed-content: result returned');
    is($result->{total}, 3, 'CR-01 mixed-content: total reflects the 3 filtered track URIs, NOT the raw envelope length (5)');
    is(scalar(@{ $result->{items} }), 3, 'CR-01 mixed-content: items count is exactly the track-filtered slice');
}

# Sequential-call chaining: simulates how explodePlaylist/_fetchPages
# actually chain pages (second call's offset = first call's returned item
# count) against the SAME mixed-content envelope -> the full track set is
# collected with zero duplicates and zero premature termination.
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/playlist/v2/playlist/}, playlist_mixed_envelope_fixture());
    # Per-id distinguishable track fixtures -- to_json_fixture() always
    # returns the SAME fixed gid regardless of which hex was requested,
    # which would make every enriched track look identical and hide a real
    # duplicate-tracks regression. Registered per-hex so each of the 3
    # track ids in the mixed envelope normalizes to a distinct uri.
    # 79-27: one batch responder answers per entity_uri, each id with its own gid (track_hash_for_id)
    set_batch();

    my ($r1, $e1);
    $SP->getPlaylistItems('acct100', 'testplaylist0000000006', { offset => 0, limit => 2 }, sub { ($r1, $e1) = @_ });
    my $nextOffset = 0 + scalar(@{ $r1->{items} || [] });   # Plugin.pm _fetchPages contract

    my ($r2, $e2);
    $SP->getPlaylistItems('acct100', 'testplaylist0000000006', { offset => $nextOffset, limit => 2 }, sub { ($r2, $e2) = @_ });

    my @allUris = (
        (map { $_->{track}{uri} } @{ $r1->{items} || [] }),
        (map { $_->{track}{uri} } @{ $r2->{items} || [] }),
    );
    my %seen;
    my @dupes = grep { $seen{$_}++ } @allUris;

    is(scalar(@allUris), 3, 'CR-01 chaining: exactly 3 track uris collected across both chained calls (no premature termination)');
    is(scalar(@dupes), 0, 'CR-01 chaining: zero duplicate tracks across the chained windows');
}

# Partial-enrichment-failure window: one of three metadata/4/track requests
# forced to error -> items array length stays 3 (stub substituted, not
# dropped); stub's track.name is undef, track.uri matches the source uri.
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/playlist/v2/playlist/}, playlist_envelope_fixture(3));
    # 79-27 (was: one metadata/4/track GET forced to 429): one entity of the batch answers status_code 404
    set_batch(data => sub { fixture_track_hash() }, status404 => { 'spotify:track:' . b62id(2) => 1 });

    my ($result, $err);
    $SP->getPlaylistItems('acct101', 'testplaylist0000000007', { offset => 0, limit => 3 }, sub { ($result, $err) = @_ });

    ok($result, 'CR-01 partial-enrichment-failure: result returned');
    is(scalar(@{ $result->{items} }), 3, 'CR-01 partial-enrichment-failure: items length stays 3 (stub substituted, not dropped)');
    is($result->{items}[1]{track}{name}, undef, 'CR-01 partial-enrichment-failure: failed slot\'s stub has undef name');
    is($result->{items}[1]{track}{uri}, 'spotify:track:' . b62id(2), 'CR-01 partial-enrichment-failure: failed slot\'s stub uri matches the source uri');
}

# Same partial-enrichment-failure pattern against getSavedAlbums (collection/
# v2 + _enrichCollectionSlice path) -- one metadata/4/album fetch forced to
# fail -> the full requested count is still returned with a stub in the
# failed slot.
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/collection/v2/paging}, encode_page_response(
        items => [
            { uri => 'spotify:album:' . b62id(1), added_at => 10 },
            { uri => 'spotify:album:' . b62id(2), added_at => 11 },
        ],
    ));
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/album/}, album_fixture());
    Slim::Networking::SimpleAsyncHTTP::set_error_for(qr{/metadata/4/album/} . quotemeta($SP->idToHex(b62id(2))), 429);

    my ($result, $err);
    $SP->getSavedAlbums('acct102', { offset => 0, limit => 50 }, sub { ($result, $err) = @_ });

    ok($result, 'CR-01 getSavedAlbums partial-enrichment-failure: result returned');
    is($result->{total}, 2, 'CR-01 getSavedAlbums partial-enrichment-failure: total unaffected (2 collection items)');
    is(scalar(@{ $result->{items} }), 2, 'CR-01 getSavedAlbums partial-enrichment-failure: full requested count returned (stub in failed slot, not dropped)');
    is($result->{items}[1]{album}{name}, undef, 'CR-01 getSavedAlbums partial-enrichment-failure: failed slot\'s stub has undef name');
}

sub to_json_fixture_mfy {
    my $item = sub { my ($uri, $name) = @_; return { uri => $uri, content => { data => { __typename => 'Playlist', uri => $uri, name => $name } } } };
    return JSON::XS::VersionOneAndTwo::to_json({ data => { homeSections => { sections => [ {
        sectionItems => { totalCount => 1, items => [ $item->('spotify:playlist:37i9dQZF1E3a6pKpVe40mF', 'Daily Mix 1') ] },
    } ] } } });
}

# ============================================================
# 85-08 Task 3 -- getTopTracks on Pathfinder userTopContent (decision-D07)
# ============================================================
{
    reset_all(); pf_seed(); pf_ops_rule();
    my ($r, $e);
    $SP->getTopTracks('acctTT1', { time_range => 'medium_term', limit => 50, offset => 0 }, sub { ($r, $e) = @_ });
    my @q = pf_reqs();
    my $v = @q ? pf_vars($q[0])->{variables} : {};
    ok(scalar(@q) == 1 && scalar(@Plugins::SpotOn::API::Client::getTopTracks_calls) == 0, 'getTopTracks: one userTopContent query, no Client.pm call');
    is_deeply($v->{topTracksInput}, { offset => 0, limit => 50, sortBy => 'AFFINITY', timeRange => 'MID_TERM' }, 'getTopTracks: medium_term sends topTracksInput {offset 0, limit 50, sortBy AFFINITY, timeRange MID_TERM}');
    ok($v->{includeTopTracks} && !$v->{includeTopArtists} && $v->{topArtistsInput}{limit} == 1, 'getTopTracks: includeTopTracks true, includeTopArtists false with a topArtistsInput of limit 1');
    is($r->{total}, $PFX->{userTopContent}{data}{me}{profile}{topTracks}{totalCount}, 'getTopTracks: total is the totalCount');
    is(scalar(@{ $r->{items} }), 3, 'getTopTracks: items mapped');
    my $t = $r->{items}[0];
    ok($t->{id} && $t->{uri} =~ /^spotify:track:/ && $t->{name} && $t->{duration_ms} > 0 && $t->{artists}[0]{uri} =~ /^spotify:artist:/
        && $t->{album}{uri} =~ /^spotify:album:/ && $t->{album}{images}[0]{url}, 'getTopTracks: items in the Web-API track shape');

    my %seen;
    for my $c (['short_term', 'SHORT_TERM'], ['medium_term', 'MID_TERM'], ['long_term', 'LONG_TERM'], [undef, 'MID_TERM']) {
        reset_all(); pf_seed(); pf_ops_rule();
        $SP->getTopTracks('acctTT2', { (defined $c->[0] ? (time_range => $c->[0]) : ()), limit => 10 }, sub { });
        my ($q) = pf_reqs();
        $seen{ $c->[1] }++ if $q && pf_vars($q)->{variables}{topTracksInput}{timeRange} eq $c->[1];
    }
    ok($seen{SHORT_TERM} == 1 && $seen{MID_TERM} == 2 && $seen{LONG_TERM} == 1, 'getTopTracks: time range mapping SHORT_TERM / MID_TERM / LONG_TERM');

    reset_all(); pf_seed(); pf_ops_rule();
    $SP->getTopTracks('acctTT3', { time_range => 'medium_term', limit => 100, offset => 50 }, sub { });
    my ($q3) = pf_reqs();
    ok($q3 && pf_vars($q3)->{variables}{topTracksInput}{limit} == 50 && pf_vars($q3)->{variables}{topTracksInput}{offset} == 50, 'getTopTracks: limit capped at 50 (D07-page-cap), offset passed');

    reset_all(); pf_seed();
    Slim::Networking::SimpleAsyncHTTP::set_error_for(qr{pathfinder/v2/query}, 500);
    my ($r4, $e4);
    $SP->getTopTracks('acctTT4', { time_range => 'medium_term', limit => 50 }, sub { ($r4, $e4) = @_ });
    ok(!$r4 && $e4 && scalar(@Plugins::SpotOn::API::Client::getTopTracks_calls) == 0, 'getTopTracks: a Pathfinder failure is reported as (undef, err), not delegated');

    reset_all();
    $Plugins::SpotOn::API::Credentials::mock_creds = undef;
    my ($r5, $e5);
    $SP->getTopTracks('acctTT5', { time_range => 'medium_term' }, sub { ($r5, $e5) = @_ });
    ok(!$r5 && ($e5->{error} // '') eq 'no_credentials' && scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()) == 0, 'getTopTracks: without login5 credentials answers no_credentials and sends nothing');
}

# ============================================================
# Former passthrough delegation matrix (Phase 75 Plan 06, Task 1)
# ============================================================
# 85-15 (D-01, D-08): the Web-API-only passthroughs are deleted; the matrix
# now pins their absence and that no method reaches the Client stub.
# reset_all() clears the Client stub's call-recording arrays.
{
    reset_all();

    my $cb = sub { };

    # 85-09 D-12: getLimit/probe are gone; fixed constants replace them (one-for-one
    # for the three delegation assertions that stood here).
    ok(!$SP->can('getLimit'), 'D-12: SpClient has no getLimit any more (the delegation to the Web-API probe is gone)');
    is(eval { $SP->pageLimit('search') }, 50, 'D-12: pageLimit(search) == 50 (decision-SEARCH keeps 50)');
    is(scalar(@Plugins::SpotOn::API::Client::getLimit_calls), 0, 'D-12: pageLimit never asks Client.pm');

    ok(!$SP->can('getMe'), 'getMe: SpClient has no getMe any more (85-15, the /me passthrough is deleted)');
    ok(!$SP->can('_delegateToClient') && !$SP->can('_isFallbackError'),
        'fallback layer: SpClient has neither _delegateToClient nor _isFallbackError (85-15)');

    # 85-08 (decision-D07 pathfinder): getTopTracks is native Pathfinder userTopContent
    pf_seed(); pf_ops_rule();
    $SP->getTopTracks('acctPT2', { time_range => 'short_term', limit => 5 }, $cb);
    is(scalar(@Plugins::SpotOn::API::Client::getTopTracks_calls), 0, 'getTopTracks: never calls Client.pm');
    is(scalar(grep { pf_vars($_)->{operationName} eq 'userTopContent' } pf_reqs()), 1, 'getTopTracks: sends one userTopContent Pathfinder request');

    ok(!$SP->can('getPersonalMixes'), 'getPersonalMixes: SpClient has no getPersonalMixes any more (85-15, D-08)');
    is(scalar(@Plugins::SpotOn::API::Client::getPersonalMixes_calls), 0, 'getPersonalMixes: the Client stub is never asked (85-15, D-08)');

    # D-14 (85-05): track writes are native collection/v2 -- they must send the
    # request and never reach Client.pm.
    my $trackUris = ['spotify:track:AAAAAAAAAAAAAAAAAAAAAA'];
    my @w;
    $SP->saveTracks('acctPT4', $trackUris, $cb);
    @w = grep { $_->{url} =~ m{/collection/v2/write} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@w), 1, 'saveTracks: sends collection/v2/write exactly once');
    is(scalar(@Plugins::SpotOn::API::Client::saveTracks_calls), 0, 'saveTracks: never calls Client.pm');

    $SP->removeTracks('acctPT5', $trackUris, $cb);
    @w = grep { $_->{url} =~ m{/collection/v2/write} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@w), 2, 'removeTracks: sends a second collection/v2/write');
    is(scalar(@Plugins::SpotOn::API::Client::removeTracks_calls), 0, 'removeTracks: never calls Client.pm');

    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/collection/v2/contains}, "\x0a\x01\x01");
    $SP->checkTracks('acctPT6', $trackUris, $cb);
    my @c = grep { $_->{url} =~ m{/collection/v2/contains} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@c), 1, 'checkTracks: sends collection/v2/contains exactly once');
    is(scalar(@Plugins::SpotOn::API::Client::checkTracks_calls), 0, 'checkTracks: never calls Client.pm');
    # D-14 (85-05): shows and add-to-playlist are native spclient requests --
    # they must send them and never reach Client.pm.
    my $showUris = ['spotify:show:BBBBBBBBBBBBBBBBBBBBBB'];
    $SP->saveShows('acctPT7', $showUris, $cb);
    my @sw = grep { $_->{url} =~ m{/collection/v2/write} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@sw), 3, 'saveShows: sends collection/v2/write exactly once');
    is(scalar(@Plugins::SpotOn::API::Client::saveShows_calls), 0, 'saveShows: never calls Client.pm');

    $SP->removeShows('acctPT8', $showUris, $cb);
    @sw = grep { $_->{url} =~ m{/collection/v2/write} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@sw), 4, 'removeShows: sends a further collection/v2/write');
    is(scalar(@Plugins::SpotOn::API::Client::removeShows_calls), 0, 'removeShows: never calls Client.pm');

    $SP->checkShows('acctPT9', $showUris, $cb);
    my @sc = grep { $_->{url} =~ m{/collection/v2/contains} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@sc), 2, 'checkShows: sends a further collection/v2/contains');
    is(scalar(@Plugins::SpotOn::API::Client::checkShows_calls), 0, 'checkShows: never calls Client.pm');

    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/playlist/v2/playlist/testplaylistidPT10000\?}, "\x0a\x03rev");
    $SP->addToPlaylist('acctPT10', 'testplaylistidPT10000', $trackUris, $cb);
    my @pc = grep { $_->{url} =~ m{/playlist/v2/playlist/testplaylistidPT10000/changes$} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@pc), 1, 'addToPlaylist: sends playlist/v2 changes exactly once');
    is(scalar(@Plugins::SpotOn::API::Client::addToPlaylist_calls), 0, 'addToPlaylist: never calls Client.pm');
    is(scalar(grep { $_->{url} =~ m{/playlist/v2/playlist/testplaylistidPT10000\?decorate=revision} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 1, 'addToPlaylist: reads the revision exactly once first');

    # 85-08 (decision-D17 pathfinder-login5-plus-rootlist): getWebPlayerPlaylistItems and
    # pathfinderHome are gone; Made for You is native Pathfinder, never Client.pm.
    $Plugins::SpotOn::API::Credentials::mock_creds = undef;
    my ($mfyNoCreds, $mfyNoCredsErr);
    $SP->getMadeForYou('acctPT11', sub { ($mfyNoCreds, $mfyNoCredsErr) = @_ });
    is($mfyNoCredsErr->{error}, 'no_credentials', 'getMadeForYou: without login5 credentials answers no_credentials');
    $Plugins::SpotOn::API::Credentials::mock_creds = { username => 'testuser', auth_data => 'ZGF0YQ==' };

    Slim::Utils::Cache->new()->set('spoton_pf_hash_homeSection', 'a' x 64);
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{pathfinder/v2/query}, to_json_fixture_mfy());
    my ($mfy, $mfyErr);
    $SP->getMadeForYou('acctPT12', sub { ($mfy, $mfyErr) = @_ });
    my @pfReqs = grep { JSON::PP::decode_json($_->{body})->{operationName} eq 'homeSection' } pf_reqs();
    is(scalar(@pfReqs), 2, 'getMadeForYou: sends exactly two Pathfinder homeSection requests');
    is_deeply([ map { JSON::PP::decode_json($_->{body})->{variables}{uri} } @pfReqs ],
        [ 'spotify:section:0JQ5DAUnp4wcj0bCb3wh3S', 'spotify:section:0JQ5DAnM3wGh0gz1MXnu89' ],
        'getMadeForYou: SECTION_MFY first, then SECTION_TOPMIX');
    ok(!Plugins::SpotOn::API::Client->can('pathfinderHome') && !Plugins::SpotOn::API::Client->can('getWebPlayerPlaylistItems'),
        'getMadeForYou: the Client stub has no pathfinderHome / getWebPlayerPlaylistItems to delegate to');
    is($mfy->{source}, 'pathfinder', 'getMadeForYou: source is pathfinder');
}

# ============================================================
# 85-08 Task 2 -- the status contract for 85-09: madeForYouStatus
# ============================================================
{
    reset_all();
    require JSON::PP;
    my $keys = [ sort qw(source hashState fallbackActive fallbackReason lastError mixCount last412At last401At last403At lastScrapeAt opsMissing) ];

    my $st = $SP->madeForYouStatus();
    is_deeply([ sort keys %$st ], $keys, 'madeForYouStatus: exactly the eleven contract keys');
    is($st->{source}, 'pathfinder-login5-plus-rootlist', 'madeForYouStatus: source names decision-D17 pathfinder-login5-plus-rootlist');
    ok($st->{hashState} eq 'unknown' && $st->{fallbackActive} == 0 && $st->{mixCount} == 0 && ref($st->{opsMissing}) eq 'ARRAY',
        'madeForYouStatus: before any call hashState unknown, no fallback, no mixes');

    Slim::Utils::Cache->new()->set('spoton_pf_hash_homeSection', 'a' x 64);
    Slim::Utils::Cache->new()->set('spoton_pf_hash_home', 'a' x 64);    # 79-59: op home is asked too
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{pathfinder/v2/query}, to_json_fixture_mfy());
    $SP->getMadeForYou('acctST1', sub { });
    $st = $SP->madeForYouStatus();
    ok($st->{mixCount} == 1 && $st->{fallbackActive} == 0 && $st->{hashState} eq 'ok',
        'madeForYouStatus: after a Pathfinder answer mixCount 1, fallbackActive 0, hashState ok');

    reset_all();
    Slim::Utils::Cache->new()->set('spoton_pf_hash_homeSection', 'a' x 64);
    Slim::Networking::SimpleAsyncHTTP::set_error_for(qr{pathfinder/v2/query}, 500);
    my $items = [ encode_rootlist_item('spotify:playlist:37i9dQZF1E3a6pKpVe40mF'), encode_rootlist_item('spotify:playlist:37i9dQZEVXcLuBdTdkGtju') ];
    my $decos = [ encode_rootlist_decoration(name => 'Daily Mix 1', owner => 'spotify', track_count => 5),
                  encode_rootlist_decoration(name => 'Discover Weekly', owner => 'spotify', track_count => 5) ];
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/playlist/v2/user/.+/rootlist}, encode_rootlist_response($items, $decos));
    my ($fb, $fbErr);
    $SP->getMadeForYou('acctST2', sub { ($fb, $fbErr) = @_ });
    $st = $SP->madeForYouStatus();
    ok($fb && $fb->{source} eq 'rootlist-fallback' && $st->{fallbackActive} == 1 && $st->{mixCount} == 2,
        'madeForYouStatus: after the rootlist fallback fallbackActive 1 and mixCount 2');

    my $json = JSON::PP->new->encode($st);
    unlike($json, qr/mock_login5_bearer_token|testuser|Bearer/, 'madeForYouStatus: carries no token and no username');
}

# Dynamic method-name dispatch (mirrors Plugin.pm's _doLibraryAction pattern,
# which calls Plugins::SpotOn::API::SpClient->$apiMethod(...) with a method
# name resolved at runtime from %_LIBRARY_API_METHODS).
{
    reset_all();
    my $cb = sub { };
    my $m = 'saveTracks';
    my $uris = ['spotify:track:CCCCCCCCCCCCCCCCCCCCCC'];
    $SP->$m('acctPTdyn', $uris, $cb);
    my @w = grep { $_->{url} =~ m{/collection/v2/write} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@w), 1, 'Dynamic dispatch: $SP->$m(...) with $m="saveTracks" sends collection/v2/write');
    is(scalar(@Plugins::SpotOn::API::Client::saveTracks_calls), 0, 'Dynamic dispatch: the dynamic call path never reaches Client.pm');
}

# ============================================================
# (85-06, D-05) getDisplayName -- user-profile-view/v3/profile/{username},
# `name` only; GET /me (Client.pm::getMe) is never used for it.
# ============================================================
sub dn_call {
    my $ok = eval { $SP->getDisplayName(@_); 1 };
    fail("getDisplayName callable: " . ($@ =~ s/\s+\z//r)) unless $ok;
}
can_ok($SP, 'getDisplayName');
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(
        qr{/user-profile-view/v3/profile/}, '{"uri":"spotify:user:testuser","name":"Test Person"}');

    my @got; my $called = 0;
    dn_call('acctDN1', sub { @got = @_; $called++ });
    my @r = Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@r), 1, 'getDisplayName: exactly one spclient request');
    like($r[0]->{url}, qr{/user-profile-view/v3/profile/testuser$}, 'getDisplayName: GET user-profile-view/v3/profile/<username>');
    is($r[0]->{method}, 'GET', 'getDisplayName: uses GET');
    is($r[0]->{headers}{Accept}, 'application/json', 'getDisplayName: Accept application/json');
    is($got[0], 'Test Person', 'getDisplayName: passes the profile name to the callback');
    is($called, 1, 'getDisplayName: callback fires exactly once');
    is(scalar(@Plugins::SpotOn::API::Client::getMe_calls), 0, 'getDisplayName: GET /me (Client::getMe) is not used');

    # username is URI-escaped into the path
    reset_all();
    $Plugins::SpotOn::API::Credentials::mock_creds = { username => 'a b/c', auth_data => 'ZGF0YQ==' };
    dn_call('acctDN2', sub { });
    @r = Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    like($r[0]->{url}, qr{/user-profile-view/v3/profile/a%20b%2Fc$}, 'getDisplayName: username is URI-escaped in the path');

    # empty / missing / non-string name -> undef
    for my $case ([ '{"name":""}', 'empty name' ], [ '{"uri":"x"}', 'missing name' ],
                  [ '{"name":{"a":1}}', 'non-string name' ], [ '{"name":"   "}', 'blank name' ]) {
        reset_all();
        Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/user-profile-view/}, $case->[0]);
        my @g = ('unset');
        dn_call('acctDN3', sub { @g = @_ });
        is($g[0], undef, "getDisplayName: $case->[1] -> undef");
    }

    # HTTP error -> undef, no fallback to Client.pm
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_404';
    my @e = ('unset');
    dn_call('acctDN4', sub { @e = @_ });
    is($e[0], undef, 'getDisplayName: HTTP error -> undef');
    is(scalar(@Plugins::SpotOn::API::Client::getMe_calls), 0, 'getDisplayName: an error never falls back to GET /me');

    # no credentials -> undef without any request
    reset_all();
    $Plugins::SpotOn::API::Credentials::mock_creds = undef;
    my @n = ('unset');
    dn_call('acctDN5', sub { @n = @_ });
    is($n[0], undef, 'getDisplayName: no credentials -> undef');
    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 0, 'getDisplayName: no credentials -> no request');
}

# ============================================================
# 85-09 Task 1 (D-13): SpClient->statusSnapshot -- counters fed by _request /
# _doRequest, exact key set, no secret in the payload.
# ============================================================
{
    # eval-guarded: a missing sub is a `not ok`, not a die that hides the rest
    sub snap_of { return eval { $SP->statusSnapshot() } || {} }
    reset_all();
    %Plugins::SpotOn::API::Login5::mock_login_state = ();
    @Plugins::SpotOn::API::TokenManager::mock_account_ids = ();

    my $snap = snap_of();
    is_deeply([ sort keys %$snap ],
        [ sort qw(apiRequestCount inflightCount api429Count rateLimited spclientHost lastErrorClass lastErrorAt login5) ],
        'D-13: statusSnapshot has exactly the 8 spclient keys');
    is($snap->{apiRequestCount}, 0, 'D-13: apiRequestCount starts at 0');
    is($snap->{api429Count},     0, 'D-13: api429Count starts at 0');
    is($snap->{rateLimited},     0, 'D-13: rateLimited 0 without the rate key');
    is($snap->{lastErrorClass}, undef, 'D-13: lastErrorClass undef before any error');
    is_deeply($snap->{login5}, {}, 'D-13: login5 is an empty hash without accounts');

    # a successful request counts once and records the resolved host
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = to_json_fixture();
    $SP->getTrack('acctSS1', '4iV5W9uYEdYUVa79Axb7Rh', sub { });
    $snap = snap_of();
    is($snap->{apiRequestCount}, 1, 'D-13: one dispatched request -> apiRequestCount 1');
    is($snap->{spclientHost}, 'test-spclient.example.com:443', 'D-13: spclientHost is the resolved host');
    is($snap->{lastErrorClass}, undef, 'D-13: a success sets no error class');
    is($snap->{inflightCount}, 0, 'D-13: inflightCount back to 0 after the callback');

    # a 404 sets the http_<code> class and the time
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_404';
    $SP->getTrack('acctSS2', '4iV5W9uYEdYUVa79Axb7Rh', sub { });
    $snap = snap_of();
    is($snap->{lastErrorClass}, 'http_404', 'D-13: a 404 -> lastErrorClass http_404');
    ok(defined $snap->{lastErrorAt} && $snap->{lastErrorAt} > 0, 'D-13: a 404 sets lastErrorAt');
    is($snap->{api429Count}, 0, 'D-13: a 404 is no 429');

    # a 429 counts, sets the rate key, and shows as rateLimited
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_429';
    $Slim::Networking::SimpleAsyncHTTP::last_response_headers = { 'Retry-After' => 30 };
    $SP->getTrack('acctSS3', '4iV5W9uYEdYUVa79Axb7Rh', sub { });
    $snap = snap_of();
    is($snap->{api429Count}, 1, 'D-13: one 429 -> api429Count 1');
    is($snap->{rateLimited}, 1, 'D-13: rate key set -> rateLimited 1');
    is($snap->{lastErrorClass}, 'http_429', 'D-13: a 429 -> lastErrorClass http_429');

    # no login5 token: the failure reason is the class, still one dispatch
    reset_all();
    $Plugins::SpotOn::API::Login5::mock_fail_reason = 'invalid_credentials';
    $SP->getTrack('acctSS4', '4iV5W9uYEdYUVa79Axb7Rh', sub { });
    $snap = snap_of();
    is($snap->{lastErrorClass}, 'invalid_credentials', 'D-13: no token -> the login5 reason is the error class');
    $Plugins::SpotOn::API::Login5::mock_fail_reason = undef;

    # per-account login5 state, and nothing secret in the whole payload
    reset_all();
    @Plugins::SpotOn::API::TokenManager::mock_account_ids = ('acctSS5', 'acctSS6');
    %Plugins::SpotOn::API::Login5::mock_login_state = (acctSS5 => 'ok', acctSS6 => 'invalid_credentials');
    $snap = snap_of();
    is_deeply($snap->{login5}, { acctSS5 => 'ok', acctSS6 => 'invalid_credentials' },
        'D-13: login5 maps each account id to Login5->loginState');
    my $flat = join '|', map { defined $_ ? (ref $_ ? join(',', %$_) : $_) : '' } values %$snap;
    unlike($flat, qr/mock_login5_bearer_token|testuser|ZGF0YQ/, 'T-85-29: the snapshot carries no token, username or auth_data');

    # reset zeroes the counters
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_429';
    $SP->getTrack('acctSS7', '4iV5W9uYEdYUVa79Axb7Rh', sub { });
    $SP->reset();
    $snap = snap_of();
    is($snap->{apiRequestCount}, 0, 'D-13: reset zeroes apiRequestCount');
    is($snap->{api429Count},     0, 'D-13: reset zeroes api429Count');
    is($snap->{lastErrorClass}, undef, 'D-13: reset clears lastErrorClass');
    is($snap->{lastErrorAt},    undef, 'D-13: reset clears lastErrorAt');

    %Plugins::SpotOn::API::Login5::mock_login_state = ();
    @Plugins::SpotOn::API::TokenManager::mock_account_ids = ();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
}

# ============================================================
# 85-09 Task 3 (D-12): fixed page limits -- the values of today's default
# (bundled-ID) install after its skipped probe (Client.pm:149-150), and
# search paging over them.
# ============================================================
{
    my %want = (search => 50, library => 50, artist_albums => 50, album_tracks => 50, playlist_items => 100);
    for my $kind (sort keys %want) {
        is(eval { $SP->pageLimit($kind) }, $want{$kind}, "D-12: pageLimit($kind) == $want{$kind}");
    }
    is(eval { $SP->pageLimit('no_such_kind') }, 50, 'D-12: an unknown kind pages with 50');
    is(eval { $SP->pageLimit(undef) },           50, 'D-12: an undefined kind pages with 50');
}

# the pager contract of Plugin.pm::_fetchPages over SpClient->search: offset = items so far,
# stop on an empty page or when the total is reached; hard cap so a bug cannot loop unbounded.
sub page_search {
    my ($acct, $q, $limit) = @_;
    my (@acc, @calls, $total);
    while (@calls < 10) {
        my $off = scalar @acc;
        my $res;
        $SP->search($acct, { q => $q, type => 'track', offset => $off, limit => $limit }, sub { ($res) = @_ });
        push @calls, [ $off, $limit ];
        my $items = ($res && $res->{tracks} && $res->{tracks}{items}) || [];
        push @acc, @$items;
        $total = ($res && $res->{tracks}{total}) // 0;
        last unless @$items && scalar(@acc) < $total;
    }
    return (\@acc, \@calls, $total);
}

# Pathfinder searchTracks: pages offset 0 / limit 50, then offset 50 while totalCount says more
{
    reset_all(); pf_seed();
    my $tpl = $PFX->{searchTracks}{data}{searchV2}{tracksV2}{items}[0];
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{pathfinder/v2/query}, sub {
        my $v = JSON::PP::decode_json($_[0])->{variables};
        my $total = 120;
        my $n = $total - $v->{offset}; $n = $v->{limit} if $n > $v->{limit}; $n = 0 if $n < 0;
        my $enc = JSON::PP->new->utf8;
        return $enc->encode({ data => { searchV2 => { tracksV2 => { totalCount => $total, items => [ map { $tpl } 1 .. $n ] } } } });
    });

    my $limit = eval { $SP->pageLimit('search') };
    my ($acc, $calls, $total) = page_search('acct90', 'radiohead', $limit);
    is_deeply($calls, [ [0, 50], [50, 50], [100, 50] ], 'D-12: search pages are offset 0 / 50 / 100 at limit 50 while totalCount says more');
    is(scalar(@$acc), 120, 'D-12: all 120 results arrive over the three pages');
    my @vars = map { pf_vars($_)->{variables} } pf_reqs();
    is_deeply([ map { [ $_->{offset}, $_->{limit} ] } @vars ], [ [0, 50], [50, 50], [100, 50] ], 'D-12: the Pathfinder variables carry offset and limit 50');
}

# degraded mode over context-resolve (<= 20 results): everything on the first page, the second page is empty
{
    reset_all(); pf_seed();
    Slim::Networking::SimpleAsyncHTTP::set_error_for(qr{pathfinder/v2/query}, 500);
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/context-resolve/}, context_resolve_fixture());
    set_batch(data => sub { fixture_track_hash() });

    my $limit = eval { $SP->pageLimit('search') };
    my ($acc, $calls, $total) = page_search('acct91', 'radiohead', $limit);
    is(scalar(@$acc), 20, 'D-12: degraded search at limit 50 delivers all 20 results on the first page');
    is(scalar(@$calls), 1, 'D-12: degraded search needs no second page');
    my $r2;
    $SP->search('acct91', { q => 'radiohead', type => 'track', offset => 20, limit => $limit }, sub { ($r2) = @_ });
    ok($r2 && $r2->{limited} && !@{ $r2->{tracks}{items} }, 'D-12: degraded search second page (offset 20) is empty and limited');
}

# WR-16: a login5 HTTP 429 (Login5 hands over { code => 429 } as the third
# argument) surfaces as rate_limited, not as the plain mint_failed that the menu
# renders as "No results". SpClient and Pathfinder both read it.
{
    reset_all();
    $Plugins::SpotOn::API::Login5::mock_fail_reason = 'mint_failed';
    $Plugins::SpotOn::API::Login5::mock_fail_detail = { code => 429, retryAfter => 120 };
    my ($r, $e);
    $SP->getTrack('acctWR16', '4iV5W9uYEdYUVa79Axb7Rh', sub { ($r, $e) = @_ });
    ok(!$r && $e, 'WR-16 SpClient: a login5 429 fails the request');
    is($e && $e->{error}, 'rate_limited', 'WR-16 SpClient: the error is rate_limited (not mint_failed)');
    is($e && $e->{code}, 429, 'WR-16 SpClient: the error carries code 429');
    is($e && $e->{source}, 'login5', 'WR-16 SpClient: the error names login5 as the source');
    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 0, 'WR-16 SpClient: nothing was sent to Spotify');

    reset_all();
    $Plugins::SpotOn::API::Login5::mock_fail_reason = 'mint_failed';
    $Plugins::SpotOn::API::Login5::mock_fail_detail = { transient => 1 };
    my ($r2, $e2);
    $SP->getTrack('acctWR16', '4iV5W9uYEdYUVa79Axb7Rh', sub { ($r2, $e2) = @_ });
    is($e2 && $e2->{error}, 'mint_failed', 'WR-16 SpClient: a transient mint failure stays mint_failed');

    reset_all();
    $Plugins::SpotOn::API::Login5::mock_fail_reason = 'mint_failed';
    my ($r3, $e3);
    $SP->getTrack('acctWR16', '4iV5W9uYEdYUVa79Axb7Rh', sub { ($r3, $e3) = @_ });
    is($e3 && $e3->{error}, 'mint_failed', 'WR-16 SpClient: without a detail the reason is unchanged');

    reset_all(); pf_seed();
    $Plugins::SpotOn::API::Login5::mock_fail_reason = 'mint_failed';
    $Plugins::SpotOn::API::Login5::mock_fail_detail = { code => 429, retryAfter => 120 };
    my ($r4, $e4);
    $SP->getTopTracks('acctWR16', { time_range => 'medium_term', limit => 50 }, sub { ($r4, $e4) = @_ });
    ok(!$r4 && $e4, 'WR-16 Pathfinder: a login5 429 fails the Pathfinder call');
    is($e4 && $e4->{error}, 'rate_limited', 'WR-16 Pathfinder: the error is rate_limited (not mint_failed)');
    is($e4 && $e4->{code}, 429, 'WR-16 Pathfinder: the error carries code 429');
    is($e4 && $e4->{source}, 'login5', 'WR-16 Pathfinder: the error names login5 as the source');
    is(scalar(grep { $_->{url} =~ m{pathfinder/v2/query} } @Slim::Networking::SimpleAsyncHTTP::requests), 0, 'WR-16 Pathfinder: no Pathfinder request was sent');
}

# WR-18: the protobuf throttle answers of login5 (LoginError 4/6/8) arrive as
# { throttled => 1, loginError => N } and surface exactly like the HTTP 429.
for my $le (4, 6, 8) {
    reset_all();
    $Plugins::SpotOn::API::Login5::mock_fail_reason = 'mint_failed';
    $Plugins::SpotOn::API::Login5::mock_fail_detail = { throttled => 1, loginError => $le, retryAfter => 60 };
    my ($r, $e);
    $SP->getTrack('acctWR18', '4iV5W9uYEdYUVa79Axb7Rh', sub { ($r, $e) = @_ });
    ok(!$r && $e, "WR-18 SpClient: LoginError $le fails the request");
    is($e && $e->{error}, 'rate_limited', "WR-18 SpClient: LoginError $le is rate_limited (not mint_failed)");
    is($e && $e->{source}, 'login5', "WR-18 SpClient: LoginError $le names login5 as the source");
    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 0, "WR-18 SpClient: LoginError $le sends nothing to Spotify");

    reset_all(); pf_seed();
    $Plugins::SpotOn::API::Login5::mock_fail_reason = 'mint_failed';
    $Plugins::SpotOn::API::Login5::mock_fail_detail = { throttled => 1, loginError => $le, retryAfter => 60 };
    my ($r2, $e2);
    $SP->getTopTracks('acctWR18', { time_range => 'medium_term', limit => 50 }, sub { ($r2, $e2) = @_ });
    ok(!$r2 && $e2, "WR-18 Pathfinder: LoginError $le fails the Pathfinder call");
    is($e2 && $e2->{error}, 'rate_limited', "WR-18 Pathfinder: LoginError $le is rate_limited (not mint_failed)");
    is($e2 && $e2->{source}, 'login5', "WR-18 Pathfinder: LoginError $le names login5 as the source");
    is(scalar(grep { $_->{url} =~ m{pathfinder/v2/query} } @Slim::Networking::SimpleAsyncHTTP::requests), 0, "WR-18 Pathfinder: LoginError $le sends no Pathfinder request");
}
{
    # a falsy flag is no throttle
    reset_all();
    $Plugins::SpotOn::API::Login5::mock_fail_reason = 'mint_failed';
    $Plugins::SpotOn::API::Login5::mock_fail_detail = { throttled => 0 };
    my ($r, $e);
    $SP->getTrack('acctWR18', '4iV5W9uYEdYUVa79Axb7Rh', sub { ($r, $e) = @_ });
    is($e && $e->{error}, 'mint_failed', 'WR-18 SpClient: throttled => 0 stays mint_failed');
}

# ============================================================
# 79-27 (D-18, D-21, D-22): batched track hydration through the shared path (_enrichTracks)
# BATCH_DECISION=extended-metadata size=200 (79-27-PROBE.md): ceil(misses/200) POSTs instead of one GET per track.
# ============================================================
my $B = eval { $SP->trackBatchSize } // -1;
is($B, 200, '79-27 D-18: SpClient->trackBatchSize is the probed batch size (200)');

# 100 uncached liked URIs -> exactly ceil(100/B) POSTs, no metadata/4/track GET, 100 items in input order
{
    reset_all(); @BATCH_LOG = ();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/context-resolve/v1/spotify:user:}, liked_songs_fixture(100));
    set_batch();
    my ($result, $err);
    $SP->getSavedTracks('acct7901', { offset => 0, limit => 100 }, sub { ($result, $err) = @_ });
    my @posts = batch_posts();
    my $want  = $B > 0 ? int((100 + $B - 1) / $B) : -1;
    is(scalar(@posts) . '/' . scalar(track_gets()), "$want/0",
        '79-27 D-18: getSavedTracks over 100 uncached liked URIs issues exactly ceil(100/B) POSTs and 0 GETs of metadata/4/track');
    is(join(',', map { $_->{track}{name} // '?' } @{ $result->{items} || [] }), join(',', map { 'Track ' . b62id($_) } 1 .. 100),
        '79-27 D-18: the 100 items come back in input order, each with its own track');
    is(join(',', map { $_->{method} . ':' . (hdr_ci($_->{headers}, 'Content-Type') // '?') . ':' . (hdr_ci($_->{headers}, 'Accept') // '?') } @posts),
        join(',', ('POST:application/x-protobuf:application/x-protobuf') x scalar(@posts)),
        '79-27 D-18: the batch is a protobuf POST (Content-Type and Accept application/x-protobuf)');
}
sub hdr_ci { my ($h, $n) = @_; for my $k (keys %$h) { return $h->{$k} if lc $k eq lc $n } return undef }

# 450 ids -> three chunks of at most B, the union is every id in order
{
    reset_all(); @BATCH_LOG = (); set_batch();
    my @ids = map { b62id($_) } 1 .. 450;
    my $res;
    $SP->_enrichTracks('acct7902', \@ids, sub { ($res) = @_ });
    my @posts = batch_posts();
    my @sizes = map { scalar(post_uris($_)) } @posts;
    is(join(',', @sizes), join(',', (200, 200, 50)), '79-27 D-18: 450 uncached ids travel as chunks of 200, 200 and 50');
    is(join(',', map { post_uris($_) } @posts), join(',', map { 'spotify:track:' . $_ } @ids), '79-27 D-18: the chunks together carry every id once, in order');
    is(scalar(@{ $res || [] }), 450, '79-27 D-18: 450 results for 450 ids');
}

# entities answered in shuffled order are paired by entity_uri; a 404 entity and a nameless entity become their own stub
{
    reset_all(); @BATCH_LOG = ();
    my @ids = map { b62id($_) } 1 .. 6;
    set_batch(shuffle => 1,
        status404 => { 'spotify:track:' . b62id(2) => 1 },
        nameless  => { 'spotify:track:' . b62id(4) => 1 });
    my $res;
    $SP->_enrichTracks('acct7903', \@ids, sub { ($res) = @_ });
    is(scalar(@{ $res || [] }), 6, '79-27 D-18: scalar(results) == scalar(ids) (CR-01) with a 404 and a nameless entity in the batch');
    is(join(',', map { $_->{name} // 'STUB' } @{ $res || [] }),
        join(',', map { ($_ == 2 || $_ == 4) ? 'STUB' : 'Track ' . b62id($_) } 1 .. 6),
        '79-27 D-18: shuffled answers are paired by entity_uri; the 404 and the nameless entity are stubs in their OWN slots');
    is(join(',', map { $_->{uri} // '?' } @{ $res || [] }), join(',', map { 'spotify:track:' . b62id($_) } 1 .. 6),
        '79-27 D-18: every slot keeps its uri (stubs carry id/uri)');
}

# a batch result equals the JSON path's normalized track, field for field
{
    reset_all(); @BATCH_LOG = ();
    my $id = b62id(77);
    my $json = JSON::PP->new->canonical->encode(track_hash_for_id($id));
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/track/}, $json);
    my ($viaJson);
    $SP->getTrack('acct7904', $id, sub { ($viaJson) = @_ });
    reset_all(); @BATCH_LOG = (); set_batch();
    my $res;
    $SP->_enrichTracks('acct7904', [$id], sub { ($res) = @_ });
    is_deeply($res && $res->[0], $viaJson, '79-27 D-18: the normalized track of the batch path is_deeply equals the JSON path (duration, gid, cover, artist)');
    is($res && $res->[0] && $res->[0]{duration_ms}, 215000, '79-27 D-18: duration from sint32 field 7 (wire value 430000) is 215000 ms, not doubled');
    like($res && $res->[0] && $res->[0]{album}{images}[0]{url} // '', qr{^https://i\.scdn\.co/image/deadbeefcafefeed0{24}$}, '79-27 D-18: the cover file_id bytes become the hex the JSON path carries');
}

# each batch result lands under the per-track key; the same call again is free; 10 of 30 cached -> the POST carries the 20 misses
{
    reset_all(); @BATCH_LOG = ();
    set_batch();
    my @ids = map { b62id($_) } 1 .. 30;
    my $res;
    $SP->_enrichTracks('acct7905', [ @ids[0 .. 9] ], sub { ($res) = @_ });
    my $c = Slim::Utils::Cache->new();
    my $key = 'spoton_spclient_resp_acct7905_metadata/4/track/' . $SP->idToHex($ids[0]);
    my $stored = $c->get($key);
    ok(ref($stored) eq 'HASH' && $stored->{name} eq 'Track ' . $ids[0] && $stored->{gid} eq $SP->idToHex($ids[0]),
        '79-27 D-18: a batch result is written under spoton_spclient_resp_<acct>_metadata/4/track/<hex> in the JSON shape');
    my $n1 = scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests());
    $SP->_enrichTracks('acct7905', [ @ids[0 .. 9] ], sub { ($res) = @_ });
    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), $n1, '79-27 D-18: the same call again issues 0 HTTP requests');
    @BATCH_LOG = ();
    $SP->_enrichTracks('acct7905', \@ids, sub { ($res) = @_ });
    is(scalar(@BATCH_LOG) . '/' . scalar(@{ $BATCH_LOG[0] || [] }), '1/20', '79-27 D-18: with 10 of 30 ids cached the one POST carries exactly the 20 misses');
    is(join(',', @{ $BATCH_LOG[0] || [] }), join(',', map { 'spotify:track:' . $_ } @ids[10 .. 29]), '79-27 D-18: ... namely ids 11..30 in order');
    is(scalar(@{ $res || [] }), 30, '79-27 D-18: all 30 results (10 cached + 20 fetched)');
}

# transient batch error: retried after 1 s and 3 s, then stubbed; 404/429 stub at once; a malformed body stubs the chunk
{
    reset_all(); @Slim::Utils::Timers::set_calls = ();
    Slim::Networking::SimpleAsyncHTTP::set_error_for(qr{/extended-metadata/v0/extended-metadata}, 500);
    my ($res, $called);
    $SP->_enrichTracks('acct7906', [ b62id(1), b62id(2) ], sub { ($res) = @_; $called++ });
    is(scalar(batch_posts()) . '/' . ($called // 0), '1/0', '79-27 D-18: a 500 batch error -> one attempt, callback not yet fired, retry pending');
    my @t = retry_timers();
    my $d1 = @t ? $t[0][1] - Time::HiRes::time() : -1;
    ok(@t == 1 && $d1 >= 0 && $d1 <= 2, "79-27 D-18: the first batch retry is due in about 1 s (got $d1)");
    @Slim::Utils::Timers::set_calls = ();
    $t[0][2]->($t[0][0]) if @t;
    @t = retry_timers();
    my $d2 = @t ? $t[0][1] - Time::HiRes::time() : -1;
    ok(@t == 1 && $d2 >= 2 && $d2 <= 4, "79-27 D-18: the second batch retry is due in about 3 s (got $d2)");
    @Slim::Utils::Timers::set_calls = ();
    $t[0][2]->($t[0][0]) if @t;
    is(scalar(batch_posts()) . '/' . ($called // 0) . '/' . scalar(retry_timers()), '3/1/0', '79-27 D-18: three attempts, then the callback fires once and no further retry');
    is(join(',', map { $_->{name} // 'STUB' } @{ $res || [] }), 'STUB,STUB', '79-27 D-18: after the retries both slots are stubs');
}
for my $case ([404, 'a 404'], [429, 'a 429']) {
    reset_all(); @Slim::Utils::Timers::set_calls = ();
    Slim::Networking::SimpleAsyncHTTP::set_error_for(qr{/extended-metadata/v0/extended-metadata}, $case->[0]);
    my ($res, $called);
    $SP->_enrichTracks('acct7907', [ b62id(1), b62id(2) ], sub { ($res) = @_; $called++ });
    is(($called // 0) . '/' . scalar(retry_timers()) . '/' . join(',', map { $_->{uri} // '?' } @{ $res || [] }),
        '1/0/spotify:track:' . b62id(1) . ',spotify:track:' . b62id(2), "79-27 D-18: $case->[1] batch error stubs at once (no retry timer)");
}
{
    reset_all(); @Slim::Utils::Timers::set_calls = ();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/extended-metadata/v0/extended-metadata}, pack('C*', 0xFF, 0x00, 0xAB, 0xCD, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF));
    my ($res, $called, $died);
    eval { $SP->_enrichTracks('acct7908', [ b62id(1), b62id(2), b62id(3) ], sub { ($res) = @_; $called++ }); 1 } or $died = $@;
    is(($died ? 'DIED' : 'ok') . '/' . ($called // 0) . '/' . join(',', map { $_->{name} // 'STUB' } @{ $res || [] }), 'ok/1/STUB,STUB,STUB',
        '79-27 D-18: a malformed response body stubs the whole chunk, never dies');
}

# D-21: the other track lists ride the same path
{
    reset_all(); @BATCH_LOG = ();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/playlist/v2/playlist/}, playlist_envelope_fixture(30));
    set_batch();
    my ($result, $err);
    $SP->getPlaylistItems('acct7909', 'testplaylist0000000030', { offset => 0, limit => 30 }, sub { ($result, $err) = @_ });
    is(scalar(batch_posts()) . '/' . scalar(track_gets()) . '/' . scalar(@{ $result->{items} || [] }), '1/0/30',
        '79-27 D-21: getPlaylistItems over 30 uncached ids issues one extended-metadata POST and no metadata/4/track GET');
}
{
    reset_all(); @BATCH_LOG = ();
    my $album = JSON::PP->new->encode({
        gid => hexid(100), name => 'Twelve', artist => [ { gid => hexid(101), name => 'Test Artist' } ],
        disc => [ { number => 1, track => [ map { { gid => hexid($_) } } 1 .. 12 ] } ],
    });
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/album/}, $album);
    set_batch();
    my ($result, $err);
    $SP->getAlbumTracks('acct7910', '4iV5W9uYEdYUVa79Axb7Rh', { offset => 0, limit => 12 }, sub { ($result, $err) = @_ });
    is(scalar(batch_posts()) . '/' . scalar(track_gets()) . '/' . scalar(@{ $result->{items} || [] }), '1/0/12',
        '79-27 D-21: getAlbumTracks over a 12-track album issues one extended-metadata POST and no metadata/4/track GET');
}

# D-18: the single-track path stays a GET
{
    reset_all();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/track/}, to_json_fixture());
    my $res;
    $SP->getTrack('acct7911', '4iV5W9uYEdYUVa79Axb7Rh', sub { ($res) = @_ });
    my @g = track_gets();
    is(scalar(@g) . '/' . scalar(batch_posts()) . '/' . ($g[0] && $g[0]{url} =~ m{/metadata/4/track/[0-9a-f]{32}$} ? 'hex' : 'nohex'), '1/0/hex',
        '79-27 D-18: getTrack (single) still issues one GET metadata/4/track/<hex>');
}

# ============================================================
# 79-27 (D-19): track metadata lives 90 days (ABSOLUTE expiry - DbCache reads a number above 2592000 as a unix
# time, DbCache.pm:214), carries its own _spoton_cached_at stamp and is renewed by a timer-driven drain (50 per
# tick), never by a synchronous write inside the hit path.
# ============================================================
sub drain_timers { return grep { ref($_->[2]) eq 'CODE' && $_->[2] == \&Plugins::SpotOn::API::SpClient::_flushTrackRenewals } @Slim::Utils::Timers::set_calls }
sub set_log_for { my ($pat) = @_; return grep { $_->[0] =~ $pat } @Slim::Utils::Cache::SET_LOG }
sub seed_track { my ($acct, $id, $ageDays, %o) = @_;
    my $h = track_hash_for_id($id);
    $h->{name} = $o{name} if defined $o{name};
    $h->{_spoton_cached_at} = time() - int($ageDays * 86400) if defined $ageDays;
    # 79-43 (D-33 FULL-3 CR-01): a seeded entry is written in the current format unless the case asks for the old one
    $h->{_spoton_fmt} = (eval { Plugins::SpotOn::API::SpClient::TRACK_META_FORMAT() } // 2) unless $o{unmarked};
    Slim::Utils::Cache->new()->set('spoton_spclient_resp_' . $acct . '_metadata/4/track/' . $SP->idToHex($id), $h, time() + 90 * 86400);
    return $h;
}
my $DAY = 86400;
{
    my $hex = $SP->idToHex(b62id(1));
    my $now = time();
    my $ttl = eval { $SP->_cacheTTL("metadata/4/track/$hex") } // 0;
    ok($ttl >= $now + 89 * $DAY && $ttl <= $now + 91 * $DAY, "79-27 D-19: _cacheTTL('metadata/4/track/<hex>') is an absolute epoch 89..91 days ahead (got $ttl)");
    is($SP->_cacheTTL("metadata/4/album/$hex") . '/' . $SP->_cacheTTL('context-resolve/x') . '/' . $SP->_cacheTTL("metadata/4/artist/$hex"), '3600/300/3600',
        '79-27 D-19: album/artist keep 3600 s, context-resolve 300 s');
}
{
    reset_all(); set_batch();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/track/}, JSON::PP->new->encode(track_hash_for_id(b62id(5))));
    my $c = Slim::Utils::Cache->new();
    my $now = time();
    $SP->getTrack('acct7920', b62id(5), sub { });
    my $k1 = 'spoton_spclient_resp_acct7920_metadata/4/track/' . $SP->idToHex(b62id(5));
    my $e1 = $c->get($k1);
    my ($set1) = set_log_for(qr/^\Q$k1\E$/);
    $SP->_enrichTracks('acct7920', [ b62id(6) ], sub { });
    my $k2 = 'spoton_spclient_resp_acct7920_metadata/4/track/' . $SP->idToHex(b62id(6));
    my $e2 = $c->get($k2);
    my ($set2) = set_log_for(qr/^\Q$k2\E$/);
    ok($set1 && $set1->[1] > 2592000 && ref($e1) eq 'HASH' && abs(($e1->{_spoton_cached_at} // 0) - $now) <= 2,
        '79-27 D-19: a getTrack fetch stores the entry with an expiry above 2592000 and a _spoton_cached_at stamp within 2 s of now');
    ok($set2 && $set2->[1] > 2592000 && ref($e2) eq 'HASH' && abs(($e2->{_spoton_cached_at} // 0) - $now) <= 2,
        '79-27 D-19: a batch fetch stores the entry with an expiry above 2592000 and a stamp within 2 s of now');
    my $plain = $SP->_normalizeTrack(track_hash_for_id(b62id(5)));
    is_deeply($SP->_normalizeTrack({ %{ track_hash_for_id(b62id(5)) }, _spoton_cached_at => 12345 }), $plain,
        '79-27 D-19: _normalizeTrack output is unchanged by the stamp key');
}
{
    # a 31-day-old hit: zero sets in the hit path, one drain timer; the drain writes it once with a fresh stamp
    reset_all(); @Slim::Utils::Timers::set_calls = ();
    seed_track('acct7921', b62id(7), 31, name => 'Old Name');
    my $k = 'spoton_spclient_resp_acct7921_metadata/4/track/' . $SP->idToHex(b62id(7));
    @Slim::Utils::Cache::SET_LOG = ();
    my ($res, $setsInHit);
    $SP->getTrack('acct7921', b62id(7), sub { ($res) = @_; $setsInHit = scalar(@Slim::Utils::Cache::SET_LOG); });
    is(($res && $res->{name} // '?') . '/' . scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 'Old Name/0',
        '79-27 D-19: a 31-day-old entry is still served from the cache (0 requests)');
    is(($setsInHit // -1) . '/' . scalar(drain_timers()), '0/1',
        '79-27 D-19: a hit older than 30 days performs zero $cache->set while the hit callback runs and arms exactly one drain timer');
    my @t = drain_timers();
    @Slim::Utils::Timers::set_calls = ();
    $t[0][2]->($t[0][0], @{$t[0]}[3 .. $#{$t[0]}]) if @t;
    my @sets = set_log_for(qr/^\Q$k\E$/);
    my $e = Slim::Utils::Cache->new()->get($k);
    ok(@sets == 1 && $sets[0][1] > 2592000 && $sets[0][1] >= time() + 89 * $DAY && abs(($e->{_spoton_cached_at} // 0) - time()) <= 2,
        '79-27 D-19: firing the drain writes that entry once with a fresh stamp and a 90-day absolute expiry');
    is(scalar(drain_timers()), 0, '79-27 D-19: nothing left to drain, no further timer');
    # a hit 1 day old arms nothing and writes nothing
    reset_all(); @Slim::Utils::Timers::set_calls = ();
    seed_track('acct7922', b62id(8), 1);
    @Slim::Utils::Cache::SET_LOG = ();
    $SP->getTrack('acct7922', b62id(8), sub { });
    is(scalar(drain_timers()) . '/' . scalar(@Slim::Utils::Cache::SET_LOG), '0/0', '79-27 D-19: a hit 1 day old arms nothing and writes nothing');
    # an entry without a stamp (written before this change) counts as due
    reset_all(); @Slim::Utils::Timers::set_calls = ();
    seed_track('acct7923', b62id(9), undef);
    $SP->getTrack('acct7923', b62id(9), sub { });
    is(scalar(drain_timers()), 1, '79-27 D-19: an entry without a stamp counts as due (one drain timer)');
}
{
    # 120 due hits drain as 50, 50, 20 over three ticks; a key due twice before the drain is written once
    reset_all(); @Slim::Utils::Timers::set_calls = ();
    my @ids = map { b62id(1000 + $_) } 1 .. 120;
    seed_track('acct7924', $_, 45) for @ids;
    $SP->_enrichTracks('acct7924', \@ids, sub { });
    $SP->getTrack('acct7924', $ids[0], sub { });   # due twice
    is(scalar(drain_timers()), 1, '79-27 D-19: 120 due hits (and a repeat) arm exactly ONE drain timer');
    @Slim::Utils::Cache::SET_LOG = ();
    my @per;
    for my $tick (1 .. 4) {
        my @t = drain_timers();
        last unless @t;
        @Slim::Utils::Timers::set_calls = ();
        $t[0][2]->($t[0][0], @{$t[0]}[3 .. $#{$t[0]}]);
        push @per, scalar(@Slim::Utils::Cache::SET_LOG);
        @Slim::Utils::Cache::SET_LOG = ();
    }
    is(join(',', @per), '50,50,20', '79-27 D-19: 120 due hits drain as 50, 50, 20 over three timer ticks');
    my %seen; $seen{$_->[0]}++ for @Slim::Utils::Cache::SET_LOG;
}

# ============================================================
# 79-27 (D-20): getTrack(..., { refresh => 1 }) skips the cache READ and keeps the WRITE
# ============================================================
{
    reset_all(); @Slim::Utils::Timers::set_calls = ();
    seed_track('acct7930', b62id(11), 2, name => 'Stale Name');
    my $fresh = track_hash_for_id(b62id(11)); $fresh->{name} = 'Fresh Name';
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/track/}, JSON::PP->new->encode($fresh));
    my ($plain, $refreshed, $after);
    $SP->getTrack('acct7930', b62id(11), sub { ($plain) = @_ });
    my $n0 = scalar(track_gets());
    $SP->getTrack('acct7930', b62id(11), sub { ($refreshed) = @_ }, { refresh => 1 });
    my $n1 = scalar(track_gets());
    $SP->getTrack('acct7930', b62id(11), sub { ($after) = @_ });
    my $n2 = scalar(track_gets());
    is($n0 . '/' . ($plain && $plain->{name} // '?'), '0/Stale Name', '79-27 D-20: a plain getTrack on a warm entry issues 0 requests');
    is(($n1 - $n0) . '/' . ($refreshed && $refreshed->{name} // '?'), '1/Fresh Name', '79-27 D-20: getTrack with refresh on a warm entry issues exactly one GET metadata/4/track/<hex>');
    is(($n2 - $n1) . '/' . ($after && $after->{name} // '?'), '0/Fresh Name', '79-27 D-20: ... and overwrote the entry (a following plain getTrack returns the new name with 0 requests)');
}

# ============================================================
# 79-43 (D-33 FULL-3 CR-01): names from the extended-metadata batch decoder are Perl character strings, and a
# track cache entry without the current format marker (the byte form beta.1 wrote, up to 90 days to live) is a
# miss at both readers: refetched, overwritten, never queued for renewal.
# ============================================================
my $FMT43 = eval { Plugins::SpotOn::API::SpClient::TRACK_META_FORMAT() } // 2;
# umlaut_track_bytes($id): the JSON-shaped hash with UTF-8 BYTE names, as protobuf delivers them and beta.1 stored them
sub umlaut_track_bytes {
    my ($id) = @_;
    my $h = track_hash_for_id($id);
    $h->{name}   = "F\xc3\xbcr Elise";
    $h->{artist} = [ { gid => 'bb000000000000000000000000000002', name => "Bj\xc3\xb6rk" } ];
    $h->{album}  = { %{ $h->{album} }, name => "Caf\xc3\xa9 \xe2\x98\x95" };
    return $h;
}
# umlaut_track_chars($id): the same names as character strings (what GET metadata/4/track JSON decodes to)
sub umlaut_track_chars {
    my ($id) = @_;
    my $h = track_hash_for_id($id);
    $h->{name}   = "F\x{fc}r Elise";
    $h->{artist} = [ { gid => 'bb000000000000000000000000000002', name => "Bj\x{f6}rk" } ];
    $h->{album}  = { %{ $h->{album} }, name => "Caf\x{e9} \x{2615}" };
    return $h;
}
sub flag_len { return join '/', map { defined $_ ? (utf8::is_utf8($_) ? 1 : 0) . ':' . length($_) : 'undef' } @_ }
sub names3   { my ($t) = @_; $t ||= {}; return ($t->{name}, ((($t->{artists} || [])->[0]) || {})->{name}, ($t->{album} || {})->{name}) }
sub seed_bytes43 {   # an UNMARKED byte-form entry, as beta.1 and C5 wrote it
    my ($acct, $id, $ageDays) = @_;
    my $key = $SP->_trackCacheKey($acct, $SP->idToHex($id));
    Slim::Utils::Cache->new()->set($key, { %{ umlaut_track_bytes($id) }, _spoton_cached_at => time() - int($ageDays * 86400) }, time() + 60 * 86400);
    return $key;
}
my $UMLAUT_JSON = sub { JSON::PP->new->utf8->canonical->encode(umlaut_track_chars($_[0])) };

# D1: the batch decoder returns character strings for the track, artist and album name
{
    reset_all(); @BATCH_LOG = ();
    set_batch(data => \&umlaut_track_bytes);
    my $res;
    $SP->_enrichTracks('acct4301', [ b62id(4301) ], sub { ($res) = @_ });
    my $t = $res && $res->[0];
    is(flag_len(names3($t)), '1:9/1:5/1:6',
        '79-43 D1 (D-33 FULL-3 CR-01): batch-decoded name, artist and album are character strings of length 9, 5 and 6');
    is(join('|', map { $_ // 'undef' } names3($t)), join('|', "F\x{fc}r Elise", "Bj\x{f6}rk", "Caf\x{e9} \x{2615}"),
        '79-43 D1: ... and equal the decoded characters');
}

# D2: the JSON path keeps its characters (no double decode) and the stored entry carries the marker
{
    reset_all();
    my $id = b62id(4302);
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/track/}, $UMLAUT_JSON->($id));
    my $res;
    $SP->getTrack('acct4302', $id, sub { ($res) = @_ });
    is(join('|', map { $_ // 'undef' } names3($res)), join('|', "F\x{fc}r Elise", "Bj\x{f6}rk", "Caf\x{e9} \x{2615}"),
        '79-43 D2: a metadata/4/track JSON result keeps its characters (no double decode)');
    my $stored = Slim::Utils::Cache->new()->get($SP->_trackCacheKey('acct4302', $SP->idToHex($id)));
    is(ref($stored) eq 'HASH' ? ($stored->{_spoton_fmt} // 'none') : 'nostore', $FMT43,
        '79-43 D2: the stored metadata/4/track entry carries _spoton_fmt = TRACK_META_FORMAT');
}

# H1: an unmarked byte-form entry is a miss for _enrichTracks: one POST for X, decoded name, the entry is marked
{
    reset_all(); @BATCH_LOG = (); @Slim::Utils::Timers::set_calls = ();
    my $id  = b62id(4303);
    my $key = seed_bytes43('acct4303', $id, 1);
    set_batch(data => \&umlaut_track_bytes);
    my $res;
    $SP->_enrichTracks('acct4303', [$id], sub { ($res) = @_ });
    is(scalar(@BATCH_LOG) . '/' . join(',', @{ $BATCH_LOG[0] || [] }), "1/spotify:track:$id",
        '79-43 H1: an unmarked byte-form entry is a miss for _enrichTracks (one extended-metadata POST for X)');
    is($res && $res->[0] && $res->[0]{name} // 'undef', "F\x{fc}r Elise", '79-43 H1: ... it returns the decoded name');
    my $st = Slim::Utils::Cache->new()->get($key) || {};
    is(($st->{_spoton_fmt} // 'none') . '|' . ($st->{name} // 'undef'), "$FMT43|F\x{fc}r Elise",
        '79-43 H1: ... and the overwritten entry is marked and holds the decoded name');
}

# H2: the same unmarked entry is a miss for getTrack: one GET, the entry is overwritten
{
    reset_all(); @Slim::Utils::Timers::set_calls = ();
    my $id  = b62id(4304);
    my $key = seed_bytes43('acct4304', $id, 1);
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/track/}, $UMLAUT_JSON->($id));
    my $res;
    $SP->getTrack('acct4304', $id, sub { ($res) = @_ });
    is(scalar(track_gets()) . '|' . ($res && $res->{name} // 'undef'), "1|F\x{fc}r Elise",
        '79-43 H2: an unmarked byte-form entry is a miss for getTrack (one GET metadata/4/track/<hex>, decoded name)');
    my $st = Slim::Utils::Cache->new()->get($key) || {};
    is(($st->{_spoton_fmt} // 'none') . '|' . ($st->{name} // 'undef'), "$FMT43|F\x{fc}r Elise",
        '79-43 H2: ... and the entry is overwritten with the marked character form');
}

# H3: a marked entry is a hit with no request; a marked entry older than TRACK_META_RENEW_AFTER is queued as today
{
    reset_all(); @Slim::Utils::Timers::set_calls = (); @BATCH_LOG = ();
    seed_track('acct4305', b62id(4305), 1, name => 'Marked Name');
    my $res;
    $SP->getTrack('acct4305', b62id(4305), sub { ($res) = @_ });
    $SP->_enrichTracks('acct4305', [ b62id(4305) ], sub { });
    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()) . '|' . ($res && $res->{name} // 'undef') . '|' . scalar(drain_timers()),
        '0|Marked Name|0', '79-43 H3: a marked entry is a hit at both readers with no request and no renewal');
    reset_all(); @Slim::Utils::Timers::set_calls = ();
    seed_track('acct4306', b62id(4306), 31);
    $SP->getTrack('acct4306', b62id(4306), sub { });
    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()) . '|' . scalar(drain_timers()), '0|1',
        '79-43 H3: a marked entry older than 30 days is still a hit and is queued for renewal (one drain timer)');
}

# H4 (no laundering): an unmarked 31-day-old byte-form entry is refetched, never queued; the drain skips an unmarked value
{
    reset_all(); @Slim::Utils::Timers::set_calls = ();
    my $id = b62id(4307);
    seed_bytes43('acct4307', $id, 31);
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/metadata/4/track/}, $UMLAUT_JSON->($id));
    $SP->getTrack('acct4307', $id, sub { });
    is(scalar(track_gets()) . '|' . scalar(drain_timers()), '1|0',
        '79-43 H4: getTrack on an unmarked 31-day-old entry refetches (one GET) and queues nothing for renewal');

    reset_all(); @Slim::Utils::Timers::set_calls = (); @BATCH_LOG = ();
    seed_bytes43('acct4308', b62id(4308), 31);
    set_batch(data => \&umlaut_track_bytes);
    $SP->_enrichTracks('acct4308', [ b62id(4308) ], sub { });
    is(scalar(@BATCH_LOG) . '|' . scalar(drain_timers()), '1|0',
        '79-43 H4: _enrichTracks on an unmarked 31-day-old entry refetches (one POST) and queues nothing for renewal');

    reset_all(); @Slim::Utils::Timers::set_calls = ();
    my $k = $SP->_trackCacheKey('acct4309', $SP->idToHex(b62id(4309)));
    $SP->_noteTrackHit($k, { %{ umlaut_track_bytes(b62id(4309)) }, _spoton_cached_at => time() - 31 * 86400 });
    my @t = drain_timers();
    @Slim::Utils::Cache::SET_LOG = ();
    $t[0][2]->($t[0][0], @{$t[0]}[3 .. $#{$t[0]}]) if @t;
    is(scalar(@t) . '|' . scalar(set_log_for(qr/^\Q$k\E$/)), '1|0',
        '79-43 H4: a queued value without the current marker is skipped by _flushTrackRenewals (nothing stored)');
}


# ============================================================
# 79-43 (D-33 FULL-3 WR-01): no Spotify username and no search term in a SpClient log line. Paths are masked at
# the one logging point (_logPath); request paths, cache keys and the request itself stay unchanged.
# ============================================================
{
    my $lp = Plugins::SpotOn::API::SpClient->can('_logPath') || sub { $_[0] };
    is(join(' | ', map { $lp->($_) } (
            'user-profile-view/v3/profile/max.mustermann%40example.com',
            'context-resolve/v1/spotify:user:j%C3%BCrgen.m:collection',
            'recently-played/v3/user/j%C3%BCrgen.m/recently-played',
            'playlist/v2/user/max/rootlist',
            'context-resolve/v1/spotify:search:F%C3%BCr%20Elise',
            'metadata/4/track/0123456789abcdef0123456789abcdef')),
        join(' | ',
            'user-profile-view/v3/profile/****',
            'context-resolve/v1/spotify:user:****:collection',
            'recently-played/v3/user/****/recently-played',
            'playlist/v2/user/****/rootlist',
            'context-resolve/v1/spotify:search:****',
            'metadata/4/track/0123456789abcdef0123456789abcdef'),
        '79-43 M1 (D-33 FULL-3 WR-01): _logPath masks profile/<u>, spotify:user:<u>, /user/<u> and the search term; a metadata path is unchanged');
}

our @LOGCAP43;
sub capture43 {
    my ($code) = @_;
    @LOGCAP43 = ();
    no warnings 'redefine';
    local *Slim::Utils::Log::warn  = sub { push @LOGCAP43, $_[1] };
    local *Slim::Utils::Log::error = sub { push @LOGCAP43, $_[1] };
    local *Slim::Utils::Log::info  = sub { push @LOGCAP43, $_[1] };
    $code->();
    return @LOGCAP43;
}

# M2: a 503 on the profile lookup of an e-mail-shaped username
{
    reset_all();
    $Plugins::SpotOn::API::Credentials::mock_creds = { username => 'max.mustermann@example.com', auth_data => 'ZGF0YQ==' };
    Slim::Networking::SimpleAsyncHTTP::set_error_for(qr{/user-profile-view/v3/profile/}, 503);
    my @lines = capture43(sub { $SP->getDisplayName('acct4310', sub { }) });
    my $all = join("\n", @lines);
    ok(scalar(grep { m{profile/\*\*\*\*} } @lines) >= 1, '79-43 M2 (D-33 FULL-3 WR-01): the 503 log line carries profile/****');
    unlike($all, qr/max\.mustermann|%40example/, '79-43 M2: no logged line carries max.mustermann or %40example');
    ok(scalar(grep { m{/user-profile-view/v3/profile/max\.mustermann%40example\.com$} } map { $_->{url} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()) >= 1,
        '79-43 M2: the request itself still goes to the real profile path');
}

# M3: the 429 line and both 401 lines mask the same way (non-ASCII username)
{
    reset_all();
    $Plugins::SpotOn::API::Credentials::mock_creds = { username => "j\x{fc}rgen.m", auth_data => 'ZGF0YQ==' };
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_429';
    my @l429 = capture43(sub { $SP->getDisplayName('acct4311', sub { }) });
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
    ok(scalar(grep { /429/ && m{profile/\*\*\*\*} } @l429) == 1 && !grep({ /j%C3%BCrgen|j\x{fc}rgen|j\xc3\xbcrgen/ } @l429),
        '79-43 M3: the 429 line names profile/**** and not the username (raw or escaped)');

    reset_all();
    $Plugins::SpotOn::API::Credentials::mock_creds = { username => "j\x{fc}rgen.m", auth_data => 'ZGF0YQ==' };
    Slim::Networking::SimpleAsyncHTTP::set_error_for(qr{/user-profile-view/v3/profile/}, 401);
    my @l401 = capture43(sub { $SP->getDisplayName('acct4312', sub { }) });
    ok(scalar(grep { /401/ && m{profile/\*\*\*\*} } @l401) == 2 && !grep({ /j%C3%BCrgen|j\x{fc}rgen|j\xc3\xbcrgen/ } @l401),
        '79-43 M3: both 401 lines (remint, then unauthorized) name profile/**** and not the username');

    # every log statement in SpClient that prints the request path does so through _logPath (the INFO lines are
    # compiled away here by main::INFOLOG = 0, so their source is the oracle)
    open(my $fh, '<', "$project_dir/Plugins/SpotOn/API/SpClient.pm") or die $!;
    my $src = do { local $/; <$fh> };
    close $fh;
    my @raw = grep { /\$log->(?:info|warn|error|debug)\(/ && /\$cleanPath\b/ && !/_logPath\(\$cleanPath\)/ } split /\n/, $src;
    my @masked = grep { /\$log->(?:info|warn|error|debug)\(/ && /_logPath\(\$cleanPath\)/ } split /\n/, $src;
    is(scalar(@raw) . '/' . (scalar(@masked) >= 11 ? 'ok' : scalar(@masked)), '0/ok',
        '79-43 M3: no SpClient log line prints $cleanPath unmasked (the cache-hit INFO line included); 11 lines go through _logPath');
}

# ============================================================
# 261110-nu9 (I1): a failed playlist/v2 lookup of a Made for You list logs a shortened id, not the full account
# bound id (37i9dQZF1E... mixes and 37i9dQZEVX... Discover Weekly / Release Radar are generated per account);
# the request itself keeps the full id.
# ============================================================
{
    my $lp = Plugins::SpotOn::API::SpClient->can('_logPath') || sub { $_[0] };
    my $full = '37i9dQZF1EQjzt0uNuyJFR';
    my $masked = $lp->("playlist/v2/playlist/$full");
    ok(index($masked, '37i9dQZF1E') >= 0 && index($masked, '****') >= 0 && index($masked, $full) < 0 && index($masked, '0uNuyJFR') < 0,
        'nu9 I1: _logPath shortens an account bound playlist id under playlist/v2/playlist/ (id family kept, rest ****)');
    is($lp->("playlist/v2/playlist/$full"), 'playlist/v2/playlist/37i9dQZF1E****', 'nu9 I1: the shortened form is exactly the id family plus ****');
    is($lp->('playlist/v2/playlist/0123456789abcdefABCDEF'), 'playlist/v2/playlist/0123456789abcdefABCDEF', 'nu9 I1: a playlist id of another family is unchanged');
    is($lp->("metadata/4/track/$full"), "metadata/4/track/$full", 'nu9 I1: a path without playlist/v2/playlist/ is unchanged');
    is($lp->("playlist/v2/user/max/rootlist"), 'playlist/v2/user/****/rootlist', 'nu9 I1: the existing user masking still holds');
    # 261111-i1i (UR8-2): Discover Weekly / Release Radar (37i9dQZEVX...) are generated per account too
    is($lp->('playlist/v2/playlist/37i9dQZEVXcLuBdTdkGtju'), 'playlist/v2/playlist/37i9dQZEVX****',
        'i1i mask: a Discover Weekly or Release Radar id (37i9dQZEVX) is shortened the same way');
    is($lp->('500 error for https://x/playlist/v2/playlist/37i9dQZEVXbkoDWHZvXaFe?y=1'), '500 error for https://x/playlist/v2/playlist/37i9dQZEVX****?y=1',
        'i1i mask: inside an error text the EVX id is shortened too');
    is($lp->('playlist/v2/playlist/37i9dQZF1DXcBWIGoYBM5M'), 'playlist/v2/playlist/37i9dQZF1DXcBWIGoYBM5M',
        'i1i mask: an editorial playlist id (37i9dQZF1D) is unchanged');

    # the request itself is not changed, only the logged text
    reset_all();
    $Plugins::SpotOn::API::Credentials::mock_creds = { username => 'testuser', auth_data => 'ZGF0YQ==' };
    Slim::Networking::SimpleAsyncHTTP::set_error_for(qr{/playlist/v2/playlist/}, 500);
    my @lines = capture43(sub { $SP->_playlistEnvelope('acct4390', $full, sub { }) });
    my $all = join("\n", @lines);
    ok(scalar(grep { m{playlist/v2/playlist/37i9dQZF1E\*\*\*\*} } @lines) >= 1, 'nu9 I1: the error log line names playlist/v2/playlist/37i9dQZF1E****');
    unlike($all, qr/\Q$full\E|0uNuyJFR/, 'nu9 I1: no logged line carries the full playlist id');
    ok(scalar(grep { m{/playlist/v2/playlist/\Q$full\E} } map { $_->{url} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()) >= 1,
        'nu9 I1: the request itself still goes to the full playlist id');
}

# ============================================================
# 79-61 (79-REVIEW-FULL-3 WR-05): a persistent spclient 401 turned every
# request into a login5 mint. D-07a allows one remint per request; across
# requests the pattern was 401 -> remove token -> mint -> 401 -> unauthorized,
# and the NEXT request repeated it. After a confirmed unauthorized the
# account is remembered for 60 s: its next 401 is reported at once, the
# cached token is kept (so no mint), and a 2xx answer for the account lifts
# the memory again so a real token expiry later still gets its one remint.
# ============================================================
{
    reset_all();
    my $cache = Slim::Utils::Cache->new();
    $cache->set('spoton_login5_token_acct7961', 'tok', 3600);
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_401';

    my @ids = ('7961aaaaaaaaaaaaaaaaaa', '7961bbbbbbbbbbbbbbbbbb', '7961cccccccccccccccccc');
    my @errs;
    for my $id (@ids) {
        $SP->getTrack('acct7961', $id, sub { push @errs, $_[1] });
    }
    my @http = Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@errs), 3, '79-61 WR-05: harness -- all three requests answered');
    is(scalar(grep { ref $_ eq 'HASH' && ($_->{code} // 0) == 401 } @errs), 3, '79-61 WR-05: all three are reported unauthorized (401)');
    is(scalar(@http), 4, '79-61 WR-05: the first request takes its D-07a remint (2 attempts), the next two one attempt each (4, not 6)');
    is(scalar(@Plugins::SpotOn::API::Login5::getToken_calls), 4, '79-61 WR-05: no remint for the second and third request (4 token reads, not 6)');
    ok(Plugins::SpotOn::API::SpClient::_unauthMemory('acct7961'), '79-61 WR-05: the confirmed unauthorized account is remembered');
    $cache->set('spoton_login5_token_acct7961', 'tok2', 3600);

    # a 2xx for the account lifts the memory
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
    my $ok;
    $SP->getTrack('acct7961', '7961dddddddddddddddddd', sub { $ok = $_[0] });
    ok(!Plugins::SpotOn::API::SpClient::_unauthMemory('acct7961'), '79-61 WR-05: a successful answer clears the unauthorized memory');

    Slim::Networking::SimpleAsyncHTTP::reset_requests();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_401';
    Plugins::SpotOn::API::Login5::reset_calls();
    $SP->getTrack('acct7961', '7961eeeeeeeeeeeeeeeeee', sub { });
    my @http2 = Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests();
    is(scalar(@http2), 2, '79-61 WR-05: after the memory is lifted, a 401 gets its one D-07a remint again');

    # another account is not affected by acct7961's memory
    Slim::Networking::SimpleAsyncHTTP::reset_requests();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_401';
    $SP->getTrack('acct7962', '7962aaaaaaaaaaaaaaaaaa', sub { });
    is(scalar(Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 2, '79-61 WR-05: the memory is per account (another account still gets its remint)');

    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
}

# ============================================================
# 79-61 (79-REVIEW-FULL-3 WR-03): SpClient->gate is the central gate for
# spclient requests outside _request (Soloist's playback-settings). It shares
# _request's concurrency slots and 429 key, frees a slot whose request never
# answers, and noteRateLimit records a gated caller's 429 in the shared key.
# ============================================================
{
    reset_all();
    my $cache = Slim::Utils::Cache->new();
    $cache->remove(Plugins::SpotOn::API::SpClient::SPCLIENT_RATE_LIMIT_KEY());
    @Slim::Utils::Timers::set_calls = ();

    my @releases;
    my $ran = 0;
    for (1 .. 2) {
        $SP->gate("t$_", sub { $ran++; push @releases, $_[0] }, sub { });
    }
    is($ran, 2, '79-61 WR-03 gate: two gated requests run while slots are free');
    is($SP->statusSnapshot->{api}{inflightCount} // $SP->statusSnapshot->{inflightCount}, 2,
        '79-61 WR-03 gate: they occupy the same in-flight count _request uses');

    my $thirdRan = 0;
    @Slim::Utils::Timers::set_calls = ();
    $SP->gate('t3', sub { $thirdRan++; $_[0]->() }, sub { });
    is($thirdRan, 0, '79-61 WR-03 gate: a third request waits while both slots are taken (cap shared with _request)');
    ok(scalar(grep { ref($_->[2]) eq 'CODE' } @Slim::Utils::Timers::set_calls) >= 1, '79-61 WR-03 gate: the waiting request is re-tried by a timer');

    $_->() for @releases;
    $_->() for @releases;    # a second release is a no-op
    is($SP->statusSnapshot->{api}{inflightCount} // $SP->statusSnapshot->{inflightCount}, 0,
        '79-61 WR-03 gate: released slots return to zero, a double release does not go negative');

    # a request that never answers is freed by the watchdog timer
    @Slim::Utils::Timers::set_calls = ();
    $SP->gate('lost', sub { }, sub { });
    my ($watch) = grep { ref($_->[2]) eq 'CODE' } @Slim::Utils::Timers::set_calls;
    is($SP->statusSnapshot->{api}{inflightCount} // $SP->statusSnapshot->{inflightCount}, 1, '79-61 WR-03 gate: a lost request holds its slot');
    $watch->[2]->() if $watch;
    is($SP->statusSnapshot->{api}{inflightCount} // $SP->statusSnapshot->{inflightCount}, 0, '79-61 WR-03 gate: the watchdog frees the slot of a request that never answered');

    # a die inside $run releases and reports blocked
    my $why;
    $SP->gate('dies', sub { die "boom\n" }, sub { $why = $_[0] });
    is($why, 'internal_error', '79-61 WR-03 gate: a die in the dispatch is reported to the caller');
    is($SP->statusSnapshot->{api}{inflightCount} // $SP->statusSnapshot->{inflightCount}, 0, '79-61 WR-03 gate: ... and its slot is released');

    # the shared 429 key: noteRateLimit sets it, gate and _request both honour it
    $SP->noteRateLimit(7);
    ok($cache->get(Plugins::SpotOn::API::SpClient::SPCLIENT_RATE_LIMIT_KEY()), '79-61 WR-03 gate: noteRateLimit sets the shared spclient rate key');
    my ($gRan, $gWhy) = (0, undef);
    $SP->gate('limited', sub { $gRan++ }, sub { $gWhy = $_[0] });
    is($gRan . '|' . ($gWhy // ''), '0|rate_limited_local', '79-61 WR-03 gate: a gated request is short-circuited by the shared key');
    my $err;
    $SP->getTrack('acct1', '7961ffffffffffffffffff', sub { $err = $_[1] });
    is(($err && $err->{error}) // '', 'rate_limited_local', '79-61 WR-03 gate: _request is short-circuited by a 429 a gated caller recorded');
    $cache->remove(Plugins::SpotOn::API::SpClient::SPCLIENT_RATE_LIMIT_KEY());
}

# ============================================================
# 79-71 (GH #167, D-38): getEpisode / getShow / getShowEpisodes / getSavedShows names on Pathfinder
# (getEpisodeOrChapter, queryShowMetadataV2, queryPodcastEpisodes, queryBookChapters), on the trimmed real
# spike-013/014 replies. No spclient metadata/4/show or /episode request.
# ============================================================
sub pf71_seed {
    Slim::Utils::Cache->new()->set("spoton_pf_hash_$_", 'a' x 64)
        for qw(getEpisodeOrChapter queryShowMetadataV2 queryPodcastEpisodes queryBookChapters);
}
# answers by operationName: a fixture key (encoded), a raw string, or a code ref ($vars, $opName) returning either
sub pf71_serve {
    my (%by_op) = @_;
    my $enc = JSON::PP->new->utf8;
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{pathfinder/v2/query}, sub {
        my $req = JSON::PP::decode_json($_[0]);
        my $r = $by_op{ $req->{operationName} };
        $r = $r->($req->{variables}, $req->{operationName}) if ref($r) eq 'CODE';
        return '{"data":{}}' unless defined $r;
        return ref($r) ? $enc->encode($r) : $r;
    });
}
sub pf71_nonpf { return grep { $_->{url} !~ m{api-partner\.spotify\.com/pathfinder} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests() }

# 79-71 T1: one request, the facade shape, no spclient request
{
    reset_all(); pf71_seed(); pf71_serve(getEpisodeOrChapter => $F71->{episode});
    my ($result, $err);
    $SP->getEpisode('acct71a', $EP71, sub { ($result, $err) = @_ });
    my @q = pf_reqs();
    is(scalar(@q), 1, '79-71 T1 one-request: getEpisode sends exactly one Pathfinder request');
    my $b = @q ? pf_vars($q[0]) : {};
    is(join('|', ($b->{operationName} // '?'), ($b->{variables}{uri} // '?')), "getEpisodeOrChapter|spotify:episode:$EP71",
        '79-71 T1 one-request: operationName getEpisodeOrChapter, variable uri spotify:episode:<id>');
    is(scalar(pf71_nonpf()), 0, '79-71 T1 one-request: no spclient (non-Pathfinder) request');
    ok($result && !$err && $result->{name} eq "Vier Engel f\x{fc}r Cartier (SLOMW S05E04)" && $result->{show}{name} eq "Der B\x{e4}tchcast",
        '79-71 T1 one-request: the facade answers the mapped episode with its show');
    is(join('|', map { $result->{$_} // '?' } qw(id duration_ms release_date)), "$EP71|5173551|2026-10-27",
        '79-71 T1 one-request: id, duration_ms and release_date mapped (the shape the callers read)');
}

# 79-71 T1: NotFound is the item's own not-found
{
    reset_all(); pf71_seed(); pf71_serve(getEpisodeOrChapter => $F71->{notfound});
    my ($result, $err, $n) = (undef, undef, 0);
    $SP->getEpisode('acct71b', $EP71, sub { $n++; ($result, $err) = @_ });
    ok($n == 1 && !$result && ref($err) eq 'HASH' && ($err->{error} // '') eq 'not_found' && ($err->{code} // 0) == 404,
        '79-71 T1 notfound: __typename NotFound calls back (undef, { error => not_found, code => 404 }) once');
}

# 79-71 T1: a transport, hash or GraphQL failure is transient - never a code
{
    reset_all(); pf71_seed(); pf71_serve(getEpisodeOrChapter => '{"errors":[{"message":"boom"}],"data":null}');
    my ($result, $err);
    $SP->getEpisode('acct71c', $EP71, sub { ($result, $err) = @_ });
    ok(!$result && ref($err) eq 'HASH' && ($err->{error} // '') eq 'pathfinder_unavailable' && ($err->{pf_error} // '') eq 'graphql_error' && !exists $err->{code},
        '79-71 T1 transport: a Pathfinder graphql_error calls back pathfinder_unavailable (pf_error graphql_error), no code');

    reset_all(); pf71_seed();
    Slim::Networking::SimpleAsyncHTTP::set_error_for(qr{pathfinder/v2/query}, 404);
    ($result, $err) = ();
    $SP->getEpisode('acct71d', $EP71, sub { ($result, $err) = @_ });
    ok(!$result && ref($err) eq 'HASH' && ($err->{error} // '') eq 'pathfinder_unavailable' && length($err->{pf_error} // '') && !exists $err->{code},
        '79-71 T1 transport: an HTTP 404 of the Pathfinder endpoint is pathfinder_unavailable, no code (never the item\'s not-found)');
}

# ------------------------------------------------------------
# 79-71 Task 2: shows, episode and chapter lists, "Meine Podcasts" names
# ------------------------------------------------------------
# queryShowMetadataV2 answers the podcast or the audiobook show by the requested uri, the lists by operation and offset
sub pf71_serve_shows {
    pf71_serve(
        queryShowMetadataV2  => sub { my ($v) = @_; return $v->{uri} =~ /\Q$SHOW71_BOOK\E/ ? $F71->{show_audiobook} : $F71->{show_podcast} },
        queryPodcastEpisodes => sub { my ($v) = @_; return ($v->{offset} // 0) >= 50 ? $F71->{episodes_p2} : $F71->{episodes_p1} },
        queryBookChapters    => $F71->{chapters},
    );
}
sub pf71_ops { return map { pf_vars($_)->{operationName} } pf_reqs() }

# show-podcast / show-audiobook: the show shape and the kind
{
    reset_all(); pf71_seed(); pf71_serve_shows();
    my ($r, $e);
    $SP->getShow('acct71e', $SHOW71_POD, sub { ($r, $e) = @_ });
    ok($r && !$e, '79-71 T2 show-podcast: getShow answers a show');
    is(join('|', map { $r->{$_} // '?' } qw(id uri name publisher)),
        "$SHOW71_POD|spotify:show:$SHOW71_POD|Der B\x{e4}tchcast|Annika Brockschmidt und Anja R\x{fc}tzel", '79-71 T2 show-podcast: id, uri, name, publisher');
    is(scalar(@{ $r->{images} || [] }), 3, '79-71 T2 show-podcast: three cover sizes');
    is(Slim::Utils::Cache->new()->get("spoton_pf_showkind_$SHOW71_POD") // '?', 'podcast', '79-71 T2 show-podcast: the kind (podcast) is recorded');
    is(join(',', pf71_ops()), 'queryShowMetadataV2', '79-71 T2 show-podcast: one queryShowMetadataV2 request');
    is(scalar(pf71_nonpf()), 0, '79-71 T2 show-podcast: no spclient metadata/4/show request');

    reset_all(); pf71_seed(); pf71_serve_shows();
    ($r, $e) = ();
    $SP->getShow('acct71e', $SHOW71_BOOK, sub { ($r, $e) = @_ });
    ok($r && ($r->{name} // '') =~ /\AWahre Verbrechen Extrem 1: /, '79-71 T2 show-audiobook: getShow answers the book with its name');
    is(Slim::Utils::Cache->new()->get("spoton_pf_showkind_$SHOW71_BOOK") // '?', 'audiobook', '79-71 T2 show-audiobook: the kind (audiobook) is recorded');
}

# episodes-p1 / episodes-p2: paging reaches the end by the returned count
{
    reset_all(); pf71_seed(); pf71_serve_shows();
    my ($r, $e);
    $SP->getShowEpisodes('acct71f', $SHOW71_POD, { offset => 0, limit => 50 }, sub { ($r, $e) = @_ });
    my @ops = pf71_ops();
    is(scalar(grep { $_ eq 'queryPodcastEpisodes' } @ops), 1, '79-71 T2 episodes-p1: exactly one queryPodcastEpisodes request');
    my ($lq) = grep { pf_vars($_)->{operationName} eq 'queryPodcastEpisodes' } pf_reqs();
    my $v = $lq ? pf_vars($lq)->{variables} : {};
    is(join('|', ($v->{uri} // '?'), ($v->{offset} // '?'), ($v->{limit} // '?')), "spotify:show:$SHOW71_POD|0|50", '79-71 T2 episodes-p1: uri, offset and limit travel in the variables');
    ok($r && !$e && $r->{total} == 56 && $r->{offset} == 0 && $r->{limit} == 50, '79-71 T2 episodes-p1: { total 56, offset 0, limit 50 }');
    is(scalar(@{ $r->{items} || [] }), 3, '79-71 T2 episodes-p1: the three episodes of the trimmed fixture');
    is(scalar(grep { defined $_->{name} && length $_->{name} && ($_->{uri} // '') =~ /\Aspotify:episode:/ } @{ $r->{items} || [] }), 3, '79-71 T2 episodes-p1: every item named, with an episode uri');
    is(scalar(pf71_nonpf()), 0, '79-71 T2 episodes-p1: no spclient request');

    reset_all(); pf71_seed(); pf71_serve_shows();
    ($r, $e) = ();
    $SP->getShowEpisodes('acct71f', $SHOW71_POD, { offset => 50, limit => 50 }, sub { ($r, $e) = @_ });
    ($lq) = grep { pf_vars($_)->{operationName} eq 'queryPodcastEpisodes' } pf_reqs();
    is($lq ? pf_vars($lq)->{variables}{offset} : '?', 50, '79-71 T2 episodes-p2: offset 50 travels in the variables');
    is(scalar(@{ $r->{items} || [] }), 6, '79-71 T2 episodes-p2: the six page-2 items');
    is($r->{total}, 56, '79-71 T2 episodes-p2: total 56');
    is(50 + scalar(@{ $r->{items} || [] }), $r->{total}, '79-71 T2 episodes-p2: offset + returned count == total, so a caller that advances by the count stops');
    is(scalar(grep { defined $_->{name} && length $_->{name} } @{ $r->{items} || [] }), 6, '79-71 T2 episodes-p2: all six named');
}

# chapters: an audiobook lists its chapters (never queryPodcastEpisodes)
{
    reset_all(); pf71_seed(); pf71_serve_shows();
    my ($r, $e);
    $SP->getShowEpisodes('acct71g', $SHOW71_BOOK, { offset => 0, limit => 50 }, sub { ($r, $e) = @_ });
    my @ops = pf71_ops();
    is(scalar(grep { $_ eq 'queryBookChapters' } @ops) . '/' . scalar(grep { $_ eq 'queryPodcastEpisodes' } @ops), '1/0', '79-71 T2 chapters: queryBookChapters once, queryPodcastEpisodes never');
    ok($r && !$e && $r->{total} == 16, '79-71 T2 chapters: total 16');
    is(scalar(grep { defined $_->{name} && length $_->{name} && ($_->{uri} // '') =~ /\Aspotify:episode:/ } @{ $r->{items} || [] }), scalar(@{ $r->{items} || [] }) || -1,
        '79-71 T2 chapters: every chapter named, with a spotify:episode: uri');
    is($r->{items}[0]{uri} // '?', "spotify:episode:$CH71", '79-71 T2 chapters: the first chapter is 73E4okoX6R2PAagxONnSWI');
}

# kind-cache: a second page of the same show costs only the list request
{
    reset_all(); pf71_seed(); pf71_serve_shows();
    my ($r1, $r2, $e);
    $SP->getShowEpisodes('acct71h', $SHOW71_POD, { offset => 0, limit => 50 }, sub { $r1 = $_[0] });
    $SP->getShowEpisodes('acct71h', $SHOW71_POD, { offset => 50, limit => 50 }, sub { $r2 = $_[0] });
    my @ops = pf71_ops();
    is(join(',', @ops), 'queryShowMetadataV2,queryPodcastEpisodes,queryPodcastEpisodes', '79-71 T2 kind-cache: the kind is read once, the second page sends only the list request');
    ok($r1 && $r2, '79-71 T2 kind-cache: both pages answered');
}

# notfound-show: only NotFound is not_found; a transport error is transient
{
    my $nf = { data => { podcastUnionV2 => { __typename => 'NotFound' } } };
    reset_all(); pf71_seed(); pf71_serve(queryShowMetadataV2 => $nf);
    my ($r, $e, $n) = (undef, undef, 0);
    $SP->getShow('acct71i', $SHOW71_POD, sub { $n++; ($r, $e) = @_ });
    ok($n == 1 && !$r && ($e->{error} // '') eq 'not_found' && ($e->{code} // 0) == 404, '79-71 T2 notfound-show: getShow on NotFound calls back (undef, { not_found, code 404 }) once');
    ($r, $e) = ();
    $SP->getShowEpisodes('acct71i', $SHOW71_POD, { offset => 0, limit => 50 }, sub { ($r, $e) = @_ });
    ok(!$r && ($e->{error} // '') eq 'not_found' && ($e->{code} // 0) == 404, '79-71 T2 notfound-show: getShowEpisodes on NotFound likewise');

    reset_all(); pf71_seed();
    Slim::Networking::SimpleAsyncHTTP::set_error_for(qr{pathfinder/v2/query}, 500);
    ($r, $e) = ();
    $SP->getShow('acct71j', $SHOW71_POD, sub { ($r, $e) = @_ });
    ok(!$r && ($e->{error} // '') eq 'pathfinder_unavailable' && !exists $e->{code}, '79-71 T2 notfound-show: a transport error is pathfinder_unavailable without a code (getShow)');
    ($r, $e) = ();
    $SP->getShowEpisodes('acct71j', $SHOW71_POD, { offset => 0, limit => 50 }, sub { ($r, $e) = @_ });
    ok(!$r && ($e->{error} // '') eq 'pathfinder_unavailable' && !exists $e->{code}, '79-71 T2 notfound-show: ... and for getShowEpisodes');
}

# saved-names: "Meine Podcasts" - every saved show carries its name, from getShow (Pathfinder)
{
    reset_all(); pf71_seed(); pf71_serve_shows();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/collection/v2/paging}, encode_page_response(
        items => [
            { uri => "spotify:show:$SHOW71_POD",  added_at => 5 },
            { uri => "spotify:show:$SHOW71_BOOK", added_at => 6 },
        ],
    ));
    my ($r, $e);
    $SP->getSavedShows('acct71k', { offset => 0, limit => 50 }, sub { ($r, $e) = @_ });
    ok($r && !$e && $r->{total} == 2 && scalar(@{ $r->{items} }) == 2, '79-71 T2 saved-names: both saved shows returned');
    is(scalar(grep { !defined $_->{show}{name} || !length $_->{show}{name} } @{ $r->{items} || [] }), 0, '79-71 T2 saved-names: 0 nameless entries');
    is(join('|', map { $_->{show}{name} =~ /\A(\S+)/ ? $1 : '?' } @{ $r->{items} || [] }), 'Der|Wahre', '79-71 T2 saved-names: each name is its own show\'s');
    ok(exists $r->{items}[0]{added_at}, '79-71 T2 saved-names: added_at of the collection entry kept');
    is(scalar(grep { $_->{url} =~ m{/metadata/4/show/} } Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests()), 0, '79-71 T2 saved-names: no spclient metadata/4/show request');
    is(scalar(grep { $_ eq 'queryShowMetadataV2' } pf71_ops()), 2, '79-71 T2 saved-names: one show request per show');

    # a failing show keeps its slot as an id/uri stub (the CR-01 slot discipline)
    reset_all(); pf71_seed();
    Slim::Networking::SimpleAsyncHTTP::set_response_for(qr{/collection/v2/paging}, encode_page_response(
        items => [ { uri => "spotify:show:$SHOW71_POD", added_at => 5 }, { uri => "spotify:show:$SHOW71_BOOK", added_at => 6 } ],
    ));
    Slim::Networking::SimpleAsyncHTTP::set_error_for(qr{pathfinder/v2/query}, 500);
    ($r, $e) = ();
    $SP->getSavedShows('acct71l', { offset => 0, limit => 50 }, sub { ($r, $e) = @_ });
    is(ref($r) eq 'HASH' ? scalar(@{ $r->{items} || [] }) : -1, 2, '79-71 T2 saved-names: when every show request fails both slots survive as stubs, no error');
}

done_testing();

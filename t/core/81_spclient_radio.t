#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# GH #82: the SpClient radio facades (radioSeedType, getRadio,
# getRadioStationTracks) against recorded response shapes (2026-11-09 probe:
# inspiredby-mix seed_to_playlist, radio-apollo stations). Stub layout:
# t/core/59 (LMS stubs, a rule-based SimpleAsyncHTTP, Login5/Credentials stubs).

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

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
sub import {
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub logger   { return bless {}, 'Slim::Utils::Log' }
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
sub new    { bless {}, shift }
sub get    { $_store{$_[1]} }
sub set    { $_store{$_[1]} = $_[2]; 1 }
sub remove { delete $_store{$_[1]} }
sub clear  { %_store = () }
1;
END

write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
sub setTimer   { }
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

# Rule-based HTTP stub (t/core/59 pattern): add_rule($method|undef, qr/url/, $responder);
# $responder is a body, an ARRAY (sequence, sticks on the last), CODE ($body) -> body, or
# { code => N } (N >= 400: HTTP error, 0: transport failure).
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
our @requests = ();
our @rules    = ();
sub add_rule { unshift @rules, [ @_ ] }
sub new {
    my ($class, $success_cb, $error_cb, $opts) = @_;
    return bless { success_cb => $success_cb, error_cb => $error_cb }, $class;
}
sub get  { _dispatch(shift, 'GET',  @_) }
sub post { _dispatch(shift, 'POST', @_) }
sub _dispatch {
    my ($self, $method, $url, @rest) = @_;
    my $body;
    $body = pop @rest if @rest % 2 == 1;
    push @requests, { method => $method, url => $url, body => $body };
    if ($url =~ /apresolve\.spotify\.com/) {
        $self->{success_cb}->(bless { _content => '{"spclient":["test-spclient.example.com:443"]}' }, 'Slim::Networking::SimpleAsyncHTTP::Response');
        return;
    }
    my $answer = '';
    for my $rule (@rules) {
        next if defined $rule->[0] && $rule->[0] ne $method;
        next unless $url =~ $rule->[1];
        my $r = $rule->[2];
        if    (ref($r) eq 'ARRAY') { $answer = (@$r > 1) ? shift(@$r) : $r->[0] }
        elsif (ref($r) eq 'CODE')  { $answer = $r->($body) }
        else                       { $answer = $r }
        last;
    }
    if (ref($answer) eq 'HASH') {
        my $resp = bless { _code => $answer->{code}, _headers => $answer->{headers} || {} }, 'Slim::Networking::SimpleAsyncHTTP::MockResponse';
        $self->{error_cb}->($self, $answer->{code} ? "$answer->{code} forced error" : 'transport failure', $resp);
        return;
    }
    $self->{success_cb}->(bless { _content => $answer }, 'Slim::Networking::SimpleAsyncHTTP::Response');
}
sub reset_requests { @requests = (); @rules = () }
sub non_apresolve_requests { grep { $_->{url} !~ /apresolve/ } @requests }
package Slim::Networking::SimpleAsyncHTTP::Response;
sub content { $_[0]->{_content} }
package Slim::Networking::SimpleAsyncHTTP::MockResponse;
sub code   { $_[0]->{_code} }
sub header { $_[0]->{_headers}{$_[1]} }
sub can    { 1 }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::API::Login5', <<'END');
package Plugins::SpotOn::API::Login5;
sub getToken { my ($class, $accountId, $cb) = @_; $cb->('mock_login5_bearer_token', undef); }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::API::Credentials', <<'END');
package Plugins::SpotOn::API::Credentials;
our $mock_creds = { username => 'testuser', auth_data => 'ZGF0YQ==' };
sub verifyCredentials { return $mock_creds; }
1;
END

BEGIN {
    no warnings 'redefine';
    *main::TRANSCODING = sub () { 0 };
    *main::WEBUI       = sub () { 0 };
    *main::SCANNER     = sub () { 0 };
    *main::INFOLOG     = sub () { 0 };
    *main::DEBUGLOG    = sub () { 0 };
    *main::ISWINDOWS   = sub () { 0 };
    *main::ISMAC       = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
}

BEGIN {
    package Plugins::SpotOn::Plugin;
    use constant SPOTON_CACHE_VERSION => 4;
}

unshift @INC, $stub_dir, $project_dir;

require_ok('Plugins::SpotOn::API::SpClient') or BAIL_OUT('Failed to load SpClient.pm');

my $SP = 'Plugins::SpotOn::API::SpClient';

sub enc  { Plugins::SpotOn::API::ProtobufLite::encode_field(@_) }
sub rule { Slim::Networking::SimpleAsyncHTTP::add_rule(@_) }
sub reqs { Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests() }

sub reset_all {
    Slim::Networking::SimpleAsyncHTTP::reset_requests();
    Slim::Utils::Cache->new()->clear();
    $SP->reset();
    $Plugins::SpotOn::API::Credentials::mock_creds = { username => 'testuser', auth_data => 'ZGF0YQ==' };
}

my %HEX = map { $_ => sprintf('%032x', 0x2000 + $_) } 1 .. 4;
my %ID  = map { $_ => $SP->hexToId($HEX{$_}) } keys %HEX;
my ($T, $PL) = ($ID{1}, 'P' x 22);
my $RADIO = 'R' x 22;

# Track message (extended-metadata): gid=1 name=2 album=3 { gid=1 name=2 } artist=4 { gid=1 name=2 } duration=7 (zigzag)
sub track_msg {
    my ($n, $name) = @_;
    return enc(1, 2, pack('H*', $HEX{$n})) . enc(2, 2, $name)
         . enc(3, 2, enc(1, 2, pack('H*', $HEX{4})) . enc(2, 2, 'An Album'))
         . enc(4, 2, enc(1, 2, pack('H*', $HEX{4})) . enc(2, 2, 'An Artist'))
         . enc(7, 0, 2000);
}
sub extmeta_response {
    return enc(2, 2, join '', map {
        enc(3, 2, enc(1, 2, enc(1, 0, 200)) . enc(2, 2, "spotify:track:$ID{$_->[0]}") . enc(3, 2, enc(2, 2, track_msg(@$_))))
    } @_);
}

# ============================================================
# radioSeedType
# ============================================================
is($SP->radioSeedType("spotify:track:$T"), 'track', 'radioSeedType: track');
is($SP->radioSeedType("spotify:artist:$T"), 'artist', 'radioSeedType: artist');
is($SP->radioSeedType("spotify:album:$T"), 'album', 'radioSeedType: album');
is($SP->radioSeedType("spotify:playlist:$PL"), 'playlist', 'radioSeedType: playlist');
ok(!defined $SP->radioSeedType("spotify:episode:$T"), 'radioSeedType: episodes have no radio');
ok(!defined $SP->radioSeedType('spotify:track:../x'), 'radioSeedType: malformed id rejected');
ok(!defined $SP->radioSeedType("spotify:track:$T?x=1"), 'radioSeedType: no trailing text');

# ============================================================
# getRadio: radio playlist, cache, station, no radio, errors
# ============================================================
{
    reset_all();
    rule('GET', qr{/inspiredby-mix/v2/seed_to_playlist/spotify:track:$T\?response-format=json$},
        JSON::PP::encode_json({ mediaItems => [ { uri => "spotify:playlist:$RADIO" } ], total => 1 }));

    my ($radio, $err);
    $SP->getRadio('acct1', "spotify:track:$T", sub { ($radio, $err) = @_ });
    is_deeply($radio, { playlistId => $RADIO, uri => "spotify:playlist:$RADIO" }, 'getRadio: track seed -> radio playlist');
    is(scalar(reqs()), 1, 'getRadio: one request');

    Slim::Networking::SimpleAsyncHTTP::reset_requests();
    $SP->getRadio('acct1', "spotify:track:$T", sub { ($radio, $err) = @_ });
    is($radio->{playlistId}, $RADIO, 'getRadio: answered again');
    is(scalar(reqs()), 0, 'getRadio: the second open of the same seed is a cache hit');

    reset_all();
    rule('GET', qr{/seed_to_playlist/spotify:playlist:$PL\?}, JSON::PP::encode_json({ mediaItems => [ { uri => "spotify:station:playlist:$PL" } ], total => 1 }));
    $SP->getRadio('acct1', "spotify:playlist:$PL", sub { ($radio, $err) = @_ });
    is_deeply($radio, { station => "spotify:playlist:$PL" }, 'getRadio: a station answer (playlist seed) -> station with the seed');

    reset_all();
    rule('GET', qr{/seed_to_playlist/spotify:album:$T\?}, JSON::PP::encode_json({ mediaItems => [ { uri => "spotify:playlist:$RADIO" } ], total => 1 }));
    $SP->getRadio('acct1', "spotify:album:$T", sub { ($radio, $err) = @_ });
    is($radio && $radio->{playlistId}, $RADIO, 'getRadio: an album seed -> the radio playlist Spotify names (its artist radio)');

    reset_all();
    rule('GET', qr{/seed_to_playlist/}, JSON::PP::encode_json({ mediaItems => [], total => 0 }));
    ($radio, $err) = ();
    $SP->getRadio('acct1', "spotify:artist:$T", sub { ($radio, $err) = @_ });
    is($err && $err->{error}, 'no_radio', 'getRadio: an empty answer -> no_radio');
    Slim::Networking::SimpleAsyncHTTP::reset_requests();
    rule('GET', qr{/seed_to_playlist/}, JSON::PP::encode_json({ mediaItems => [], total => 0 }));
    $SP->getRadio('acct1', "spotify:artist:$T", sub { ($radio, $err) = @_ });
    is(scalar(reqs()), 1, 'getRadio: no_radio is not cached');

    reset_all();
    rule('GET', qr{/seed_to_playlist/}, { code => 429, headers => { 'Retry-After' => 20 } });
    ($radio, $err) = ();
    $SP->getRadio('acct1', "spotify:track:$T", sub { ($radio, $err) = @_ });
    is($err && $err->{error}, 'rate_limited', 'getRadio: 429 -> rate_limited');
    Slim::Networking::SimpleAsyncHTTP::reset_requests();
    $SP->getRadio('acct1', "spotify:artist:$T", sub { ($radio, $err) = @_ });
    is(scalar(reqs()), 0, 'getRadio: during the backoff no request is sent');

    reset_all();
    ($radio, $err) = ();
    $SP->getRadio('acct1', 'spotify:track:nope', sub { ($radio, $err) = @_ });
    is($err && $err->{error}, 'invalid_id', 'getRadio: invalid seed -> invalid_id');
    is(scalar(reqs()), 0, 'getRadio: invalid seed sends nothing');

    $Plugins::SpotOn::API::Credentials::mock_creds = undef;
    $SP->getRadio('acct1', "spotify:track:$T", sub { ($radio, $err) = @_ });
    is($err && $err->{error}, 'no_credentials', 'getRadio: no stored credentials -> no_credentials');
}

# ============================================================
# getRadioStationTracks: radio-apollo list, named, sliced, cached
# ============================================================
{
    reset_all();
    my $apollo = JSON::PP::encode_json({
        title  => 'Radio for a playlist',
        tracks => [ { uri => "spotify:track:$ID{1}" }, { uri => 'spotify:episode:' . ('E' x 22) }, { uri => "spotify:track:$ID{2}" }, { uri => "spotify:track:$ID{3}" } ],
        next_page_url => '/radio-apollo/v3/stations/x?offset=50',
    });
    rule('GET',  qr{/radio-apollo/v3/stations/spotify:playlist:$PL\?autoplay=false&count=50$}, $apollo);
    rule('POST', qr{/extended-metadata/v0/extended-metadata$}, extmeta_response([1, 'One'], [2, 'Two'], [3, 'Three']));

    my ($page, $err);
    $SP->getRadioStationTracks('acct1', "spotify:playlist:$PL", { offset => 0, limit => 2 }, sub { ($page, $err) = @_ });
    ok(!$err, 'getRadioStationTracks: no error');
    is_deeply([ map { $_->{track}{name} } @{ $page->{items} } ], [ 'One', 'Two' ], 'getRadioStationTracks: first slice, named, episodes left out');
    is($page->{total}, 3, 'getRadioStationTracks: total counts the tracks of the station');
    ok($page->{next}, 'getRadioStationTracks: next set while tracks remain');
    is(scalar(grep { $_->{url} =~ /radio-apollo/ } reqs()), 1, 'getRadioStationTracks: one radio-apollo request');

    Slim::Networking::SimpleAsyncHTTP::reset_requests();
    rule('POST', qr{/extended-metadata/v0/extended-metadata$}, extmeta_response([3, 'Three']));
    $SP->getRadioStationTracks('acct1', "spotify:playlist:$PL", { offset => 2, limit => 2 }, sub { ($page, $err) = @_ });
    is_deeply([ map { $_->{track}{name} } @{ $page->{items} } ], [ 'Three' ], 'getRadioStationTracks: next page from the same list');
    ok(!$page->{next}, 'getRadioStationTracks: no next on the last page');
    is(scalar(grep { $_->{url} =~ /radio-apollo/ } reqs()), 0, 'getRadioStationTracks: the next page reuses the cached station list');

    reset_all();
    rule('GET', qr{/radio-apollo/}, { code => 500 });
    ($page, $err) = ();
    $SP->getRadioStationTracks('acct1', "spotify:playlist:$PL", {}, sub { ($page, $err) = @_ });
    ok(!$page && $err, 'getRadioStationTracks: HTTP error is passed on');

    reset_all();
    rule('GET', qr{/radio-apollo/}, JSON::PP::encode_json({ tracks => [] }));
    ($page, $err) = ();
    $SP->getRadioStationTracks('acct1', "spotify:playlist:$PL", {}, sub { ($page, $err) = @_ });
    is($page && $page->{total}, 0, 'getRadioStationTracks: an empty station -> an empty page');
    Slim::Networking::SimpleAsyncHTTP::reset_requests();
    rule('GET', qr{/radio-apollo/}, JSON::PP::encode_json({ tracks => [] }));
    $SP->getRadioStationTracks('acct1', "spotify:playlist:$PL", {}, sub { ($page, $err) = @_ });
    is(scalar(grep { $_->{url} =~ /radio-apollo/ } reqs()), 1, 'getRadioStationTracks: an empty station is not cached');

    reset_all();
    $SP->getRadioStationTracks('acct1', 'spotify:playlist:bad', {}, sub { ($page, $err) = @_ });
    is($err && $err->{error}, 'invalid_id', 'getRadioStationTracks: invalid seed -> invalid_id, no request');
    is(scalar(reqs()), 0, 'getRadioStationTracks: invalid seed sends nothing');
}

done_testing();

#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# GH #32: the SpClient facades the LMS library importer reads through
# (getSavedAlbumUris, getAlbumWithTracks, getPlaylistTrackUris,
# prefetchTracks, rateLimitedFor, requestCount) and the playlist revision the
# rootlist parser now hands out. Stub layout: t/core/59 (LMS stubs, a rule-
# based SimpleAsyncHTTP, Login5/Credentials stubs).

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

# ids: 32-hex gids and their base62 ids
my %HEX = map { $_ => sprintf('%032x', 0x1000 + $_) } 1 .. 9;
my %ID  = map { $_ => $SP->hexToId($HEX{$_}) } keys %HEX;
my $ALBUM_HEX = $HEX{9};
is(length $ID{1}, 22, 'fixture ids are 22-character base62 ids');

# collection/v2 PageResponse: items=1 { uri=1, added_at=2, is_removed=3 }, next_page_token=2
sub collection_page {
    my ($items, $next) = @_;
    my $out = join '', map {
        enc(1, 2, enc(1, 2, $_->[0]) . enc(2, 0, $_->[1]) . ($_->[2] ? enc(3, 0, 1) : ''))
    } @$items;
    $out .= enc(2, 2, $next) if defined $next;
    return $out;
}

# Track message: gid=1 (raw bytes) name=2 album=3 { gid=1 name=2 } artist=4 { gid=1 name=2 } duration=7 (zigzag)
sub track_msg {
    my ($n, $name, $ms) = @_;
    return enc(1, 2, pack('H*', $HEX{$n}))
         . enc(2, 2, $name)
         . enc(3, 2, enc(1, 2, pack('H*', $HEX{9})) . enc(2, 2, 'The Album'))
         . enc(4, 2, enc(1, 2, pack('H*', $HEX{8})) . enc(2, 2, 'Track Artist'))
         . enc(7, 0, $ms * 2);
}

# BatchedExtensionResponse: extended_metadata=2 { extension_data=3 { header=1 { status=1 }, entity_uri=2, Any=3 { value=2 } } }
sub extmeta_response {
    my (@entities) = @_;   # [n, name, ms]
    return enc(2, 2, join '', map {
        enc(3, 2, enc(1, 2, enc(1, 0, 200))
                . enc(2, 2, "spotify:track:$ID{$_->[0]}")
                . enc(3, 2, enc(2, 2, track_msg(@$_))))
    } @entities);
}

# ============================================================
# getSavedAlbumUris: the full list, albums only, removed items left out, paged
# ============================================================
{
    reset_all();
    rule('POST', qr{/collection/v2/paging}, [
        collection_page([ ["spotify:album:$ID{1}", 1700000000], ["spotify:track:$ID{2}", 1700000001] ], 'page2'),
        collection_page([ ["spotify:album:$ID{3}", 1700000002], ["spotify:album:$ID{4}", 1700000003, 1] ]),
    ]);

    my ($list, $err);
    $SP->getSavedAlbumUris('acct1', sub { ($list, $err) = @_ });

    ok(!$err, 'getSavedAlbumUris: no error');
    is_deeply([ map { $_->{uri} } @{ $list || [] } ], [ "spotify:album:$ID{1}", "spotify:album:$ID{3}" ],
        'getSavedAlbumUris: albums only, in collection order, removed entries left out, both pages read');
    is($list->[0]{added_at}, 1700000000, 'getSavedAlbumUris: added_at is kept');
    is(scalar(reqs()), 2, 'getSavedAlbumUris: one request per collection page, no enrichment');

    Slim::Networking::SimpleAsyncHTTP::reset_requests();
    rule('POST', qr{/collection/v2/paging}, collection_page([]));
    $SP->getSavedAlbumUris('acct1', sub { ($list, $err) = @_ });
    is(scalar(reqs()), 1, 'getSavedAlbumUris: the 60 s list cache is not read (a scan wants the current list)');

    $Plugins::SpotOn::API::Credentials::mock_creds = undef;
    Slim::Networking::SimpleAsyncHTTP::reset_requests();
    $SP->getSavedAlbumUris('acct1', sub { ($list, $err) = @_ });
    is($err && $err->{error}, 'no_credentials', 'getSavedAlbumUris: no stored credentials -> no_credentials');
    is(scalar(reqs()), 0, 'getSavedAlbumUris: no request without credentials');
}

# ============================================================
# getAlbumWithTracks: disc layout -> disc/track numbers, batch naming, stubs left out
# ============================================================
my $albumJson = JSON::PP::encode_json({
    gid    => $HEX{9},
    name   => 'The Album',
    type   => 'COMPILATION',
    artist => [ { gid => $HEX{7}, name => 'Album Artist' } ],
    date   => { year => 1999, month => 5 },
    cover_group => { image => [ { file_id => 'ab12', width => 300 }, { file_id => 'cd34', width => 640 } ] },
    disc   => [
        { number => 1, track => [ { gid => $HEX{1} }, { gid => $HEX{2} } ] },
        { number => 2, track => [ { gid => $HEX{3} } ] },
    ],
});

{
    reset_all();
    rule('GET',  qr{/metadata/4/album/$ALBUM_HEX$}, $albumJson);
    rule('POST', qr{/extended-metadata/v0/extended-metadata$}, extmeta_response([1, 'One', 61000], [2, 'Two', 62000], [3, 'Three', 63000]));

    my ($album, $err);
    $SP->getAlbumWithTracks('acct1', $ID{9}, sub { ($album, $err) = @_ });

    ok(!$err, 'getAlbumWithTracks: no error');
    is($album->{name}, 'The Album', 'getAlbumWithTracks: album name');
    is($album->{album_type}, 'compilation', 'getAlbumWithTracks: album_type is Album.type in lower case');
    is($album->{release_date}, '1999-05-01', 'getAlbumWithTracks: release_date from the date struct');
    is_deeply([ map { [ $_->{name}, $_->{disc_number}, $_->{track_number}, $_->{duration_ms} ] } @{ $album->{tracks}{items} } ],
        [ ['One', 1, 1, 61000], ['Two', 1, 2, 62000], ['Three', 2, 1, 63000] ],
        'getAlbumWithTracks: tracks in disc order with disc/track numbers from the disc layout');
    is($album->{tracks}{total}, 3, 'getAlbumWithTracks: total = tracks of the album');
    is($album->{tracks}{items}[0]{artists}[0]{name}, 'Track Artist', 'getAlbumWithTracks: track artists from the track entity');

    my @r = reqs();
    is(scalar(@r), 2, 'getAlbumWithTracks: one album request + one batch for three tracks');

    # second read: album response (3600 s) and the tracks (90 days) come from the caches
    Slim::Networking::SimpleAsyncHTTP::reset_requests();
    $SP->getAlbumWithTracks('acct1', $ID{9}, sub { ($album, $err) = @_ });
    is(scalar(reqs()), 0, 'getAlbumWithTracks: a second read is answered from the caches');
}

{
    reset_all();
    rule('GET',  qr{/metadata/4/album/$ALBUM_HEX$}, $albumJson);
    rule('POST', qr{/extended-metadata/v0/extended-metadata$}, extmeta_response([1, 'One', 61000], [3, 'Three', 63000]));

    my ($album, $err);
    $SP->getAlbumWithTracks('acct1', $ID{9}, sub { ($album, $err) = @_ });
    is_deeply([ map { $_->{name} } @{ $album->{tracks}{items} } ], ['One', 'Three'], 'getAlbumWithTracks: an unnamed track (stub) is left out');
    is($album->{tracks}{total}, 3, 'getAlbumWithTracks: total still counts it, so the caller sees an incomplete album');
    is($album->{tracks}{items}[1]{track_number}, 1, 'getAlbumWithTracks: positions stay those of the disc layout');
}

{
    reset_all();
    rule('GET', qr{/metadata/4/album/}, { code => 429, headers => { 'Retry-After' => 30 } });
    my ($album, $err);
    $SP->getAlbumWithTracks('acct1', $ID{9}, sub { ($album, $err) = @_ });
    ok(!$album, 'getAlbumWithTracks: 429 -> no album');
    is($err && $err->{error}, 'rate_limited', 'getAlbumWithTracks: 429 -> rate_limited');
    cmp_ok($SP->rateLimitedFor, '>', 0, 'rateLimitedFor: the backoff of the 429 is visible');
    cmp_ok($SP->rateLimitedFor, '<=', 30, 'rateLimitedFor: bounded by Retry-After');

    reset_all();
    is($SP->rateLimitedFor, 0, 'rateLimitedFor: 0 without a backoff');

    my $err2;
    $SP->getAlbumWithTracks('acct1', 'not-an-id', sub { $err2 = $_[1] });
    is($err2 && $err2->{error}, 'invalid_id', 'getAlbumWithTracks: invalid id -> invalid_id, no request');
    is(scalar(reqs()), 0, 'getAlbumWithTracks: invalid id sends nothing');
}

# ============================================================
# getAlbumTrackIds: the layout alone; getAlbumWithTracks after it reuses the album response
# ============================================================
{
    reset_all();
    rule('GET',  qr{/metadata/4/album/$ALBUM_HEX$}, $albumJson);
    rule('POST', qr{/extended-metadata/v0/extended-metadata$}, extmeta_response([1, 'One', 61000], [2, 'Two', 62000], [3, 'Three', 63000]));

    my ($ids, $err);
    $SP->getAlbumTrackIds('acct1', $ID{9}, sub { ($ids, $err) = @_ });
    is_deeply($ids, [ $ID{1}, $ID{2}, $ID{3} ], 'getAlbumTrackIds: track ids in disc order');
    is_deeply([ map { $_->{method} } reqs() ], ['GET'], 'getAlbumTrackIds: only the album request, no track naming');

    my $named;
    $SP->prefetchTracks('acct1', $ids, sub { $named = shift });
    Slim::Networking::SimpleAsyncHTTP::reset_requests();
    my $album;
    $SP->getAlbumWithTracks('acct1', $ID{9}, sub { $album = shift });
    is(scalar(@{ $album->{tracks}{items} }), 3, 'getAlbumWithTracks after layout + prefetch: complete album');
    is(scalar(reqs()), 0, 'getAlbumWithTracks after layout + prefetch: no request at all');

    my (undef, $pos) = $SP->_albumTrackLayout({ disc => [ { track => [ {}, { gid => $HEX{1} } ] }, { number => 'x', track => [ { gid => $HEX{2} } ] } ] });
    is_deeply($pos, [ [1, 2], [2, 1] ], '_albumTrackLayout: a gid-less entry keeps its position, an unusable disc number counts on');
}

# ============================================================
# getPlaylistTrackUris + prefetchTracks + requestCount
# ============================================================
{
    reset_all();
    my $plId = 'P' x 22;
    rule('GET', qr{/playlist/v2/playlist/$plId$}, JSON::PP::encode_json({
        contents => { items => [
            { uri => "spotify:track:$ID{1}" }, { uri => 'spotify:episode:' . ('E' x 22) },
            { uri => 'spotify:local:a:b:c:1' }, { uri => "spotify:track:$ID{2}" },
        ] },
    }));

    my ($uris, $err);
    $SP->getPlaylistTrackUris('acct1', $plId, sub { ($uris, $err) = @_ });
    is_deeply($uris, [ "spotify:track:$ID{1}", "spotify:track:$ID{2}" ], 'getPlaylistTrackUris: track uris in order, episodes/local files left out');
    is(scalar(grep { $_->{url} =~ /extended-metadata/ } reqs()), 0, 'getPlaylistTrackUris: no enrichment');

    my $err2;
    $SP->getPlaylistTrackUris('acct1', '../x', sub { $err2 = $_[1] });
    is($err2 && $err2->{error}, 'invalid_id', 'getPlaylistTrackUris: malformed id -> invalid_id');

    rule('POST', qr{/extended-metadata/v0/extended-metadata$}, extmeta_response([1, 'One', 61000], [2, 'Two', 62000]));
    my $before = $SP->requestCount;
    my $named;
    $SP->prefetchTracks('acct1', [ $ID{1}, $ID{2} ], sub { $named = shift });
    is($named, 2, 'prefetchTracks: both tracks named');
    is($SP->requestCount, $before + 1, 'prefetchTracks: one batch request; requestCount counts it');

    $before = $SP->requestCount;
    $SP->prefetchTracks('acct1', [ $ID{1}, $ID{2} ], sub { $named = shift });
    is($named, 2, 'prefetchTracks: cached tracks count as named');
    is($SP->requestCount, $before, 'prefetchTracks: cached tracks cost no request');
}

# ============================================================
# rootlist: the playlist revision (MetaItem.revision, hex)
# ============================================================
{
    my $plA = 'A' x 22;
    my $plB = 'B' x 22;
    my $items = enc(3, 2, enc(1, 2, "spotify:playlist:$plA")) . enc(3, 2, enc(1, 2, "spotify:playlist:$plB"));
    my $metas = enc(4, 2, enc(1, 2, "\x01\x02\xff") . enc(2, 2, enc(1, 2, 'First')) . enc(3, 0, 12))
              . enc(4, 2, enc(2, 2, enc(1, 2, 'Second')));
    my $parsed = $SP->_parseRootlist(enc(5, 2, $items . $metas));

    is($parsed->[0]{revision}, '0102ff', 'rootlist: revision is MetaItem.revision as hex');
    is($parsed->[0]{name}, 'First', 'rootlist: name still parsed');
    is($parsed->[0]{tracks}{total}, 12, 'rootlist: length still parsed');
    ok(!defined $parsed->[1]{revision}, 'rootlist: no revision -> undef');
}

done_testing();

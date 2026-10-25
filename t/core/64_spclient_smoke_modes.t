#!/usr/bin/perl
# Phase 85 plan 85-02: offline test of the tools/spclient-smoke.pl probe modes
# against a FAKE curl placed first on PATH. No network, no real account.
#
# The fake curl answers canned responses keyed on the URL, keeps a little state
# on disk (collection/v2 contains), and appends one JSON line per request to
# $FAKE_LOG so the test can assert on method, URL, headers, body and on the fact
# that no secret ever reaches argv. Every secret in this file is a recognisable
# fake; no output line of any mode may contain one (T-85-01).
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Path qw(remove_tree make_path);
use File::Temp qw(tempdir);
use Cwd qw(abs_path);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use JSON::PP qw(decode_json encode_json);
use MIME::Base64 qw(encode_base64);
use Digest::SHA qw(sha1 sha256_hex);

# Resolve the project root (t/<group>/x.t sits two levels below it)
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

use lib do { my $d = dirname(dirname(dirname(abs_path($0)))); $d };
use Plugins::SpotOn::API::ProtobufLite;
my $PB = 'Plugins::SpotOn::API::ProtobufLite';

# SPOTON_SMOKE_TOOL points the test at a mutated copy for the MUST-FAIL dry runs (the copy needs a
# sibling Plugins/ symlink because the tool resolves its libs through $RealBin/..).
my $TOOL = $ENV{SPOTON_SMOKE_TOOL} || "$project_dir/tools/spclient-smoke.pl";
ok(-f $TOOL, 'tool exists');

# ------------------------------------------------------------
# Fake secrets. NONE of these may appear in any output line.
# ------------------------------------------------------------
my $AUTH_RAW = 'FAKE_AUTH_DATA_BYTES_zzzz9999';
my %S = (
    LOGIN5       => 'FAKE_LOGIN5_TOKEN_aaaa1111',
    CLIENT_TOKEN => 'FAKE_CLIENT_TOKEN_dddd4444',
    WP_LOGIN5    => 'FAKE_WP_LOGIN5_TOKEN_ffff6666',
);
my $WP_CID = 'd8a5ed958d274c2e8ee717e6a4b0971d';   # shape of the Web-Player client id (not a secret)
my @SECRETS = ($AUTH_RAW, encode_base64($AUTH_RAW, ''), values %S);
chomp(@SECRETS);

# ------------------------------------------------------------
# Scratch area
# ------------------------------------------------------------
my $tmp   = tempdir(CLEANUP => 1);
my $bin   = "$tmp/bin";
my $state = "$tmp/state";
my $log   = "$tmp/curl.log";
make_path($bin, $state);

my $creds = "$tmp/credentials.json";
open(my $cfh, '>', $creds) or die $!;
print $cfh encode_json({ username => 'fakeuser123', auth_data => encode_base64($AUTH_RAW, '') });
close $cfh;
chmod 0600, $creds;

# ------------------------------------------------------------
# The fake curl
# ------------------------------------------------------------
my $FAKE = <<'FAKE_CURL';
#!PERL
use strict;
use warnings;
use lib $ENV{FAKE_ROOT};
use File::Basename qw(dirname);
use JSON::PP qw(decode_json encode_json);
use Plugins::SpotOn::API::ProtobufLite;
use Digest::SHA qw(sha1 sha256_hex);
use MIME::Base64 qw(encode_base64);
my $PB = 'Plugins::SpotOn::API::ProtobufLite';

my @argv = @ARGV;
my (%flag, $cfg, $wfmt, $data, $method, $url);
while (@argv) {
    my $a = shift @argv;
    if    ($a eq '-K')            { $cfg    = shift @argv }
    elsif ($a eq '-w')            { $wfmt   = shift @argv }
    elsif ($a eq '--data-binary') { $data   = shift @argv }
    elsif ($a eq '-X')            { $method = shift @argv }
    elsif ($a eq '--max-time')    { shift @argv }
    elsif ($a =~ /^-/)            { $flag{$a} = 1 }
    else                          { $url = $a }
}
$method ||= $flag{'-I'} ? 'HEAD' : (defined $data ? 'POST' : 'GET');

my (@hdrs, %H);
my ($cfgMode, $dirMode) = ('-', '-');
if (defined $cfg && open(my $c, '<', $cfg)) {
    $cfgMode = sprintf('%04o', (stat $cfg)[2] & 07777);
    $dirMode = sprintf('%04o', (stat dirname($cfg))[2] & 07777);
    while (my $l = <$c>) {
        next unless $l =~ /^header = "(.*)"\s*$/;
        (my $h = $1) =~ s/\\(["\\])/$1/g;
        push @hdrs, $h;
        my ($k, $v) = split /:\s*/, $h, 2;
        $H{lc $k} = $v;
    }
    close $c;
}
my $body = '';
if (defined $data && $data eq '@-') { local $/; binmode STDIN; $body = <STDIN> // ''; }

open(my $lf, '>>', $ENV{FAKE_LOG}) or die $!;
print $lf encode_json({
    method => $method, url => $url, argv => [@ARGV], headers => \@hdrs,
    body_hex => unpack('H*', $body), cfg_mode => $cfgMode, dir_mode => $dirMode,
}), "\n";
close $lf;

sub enc { $PB->can('encode_field')->(@_) }
sub pf  { $PB->can('parse_fields')->(@_) }
sub ff  { $PB->can('field_first')->(@_) }

my $HOST = 'https://fake-spclient.test:443';
my ($code, $payload) = (404, '{"error":"fake_not_found"}');

# ---- state helpers (collection/v2 contains) ----
sub st_file { my ($set, $uri) = @_; (my $k = "$set|$uri") =~ s/[^A-Za-z0-9]/_/g; return "$ENV{FAKE_STATE}/coll_$k"; }
sub st_get  {
    my ($set, $uri) = @_;
    my $f = st_file($set, $uri);
    return -f $f ? 1 : 0 if -f $f || -f "$f.off";
    return $ENV{FAKE_CONTAINS_INITIAL} ? 1 : 0;
}
sub st_set  { my ($set, $uri, $on) = @_; my $f = st_file($set, $uri); unlink $f, "$f.off"; open(my $o, '>', $on ? $f : "$f.off") or die; close $o; }
sub next_code {   # consume a comma separated list of codes from env $_[0], counter in state dir
    my ($var, $default) = @_;
    my @codes = split /,/, ($ENV{$var} // '');
    return $default unless @codes;
    my $cf = "$ENV{FAKE_STATE}/n_$var";
    my $n = 0;
    if (open(my $i, '<', $cf)) { $n = <$i> + 0; close $i; }
    open(my $o, '>', $cf) or die; print $o $n + 1; close $o;
    return $codes[ $n < @codes ? $n : $#codes ];
}

if ($url eq 'https://login5.spotify.com/v3/login') {
    my $req = pf($body) || {};
    my $ci  = pf(ff($req, 1)) || {};
    my $cid = ff($ci, 1) // '';
    my $ok  = sub { enc(1, 2, enc(1, 2, 'fakeuser123') . enc(2, 2, $_[0]) . enc(4, 0, 3600)) };
    if ($cid eq '65b708073fc0480ea92a077233ca87bd') {
        if (defined $ENV{FAKE_LOGIN5_ERROR}) {
            ($code, $payload) = (200, enc(2, 0, $ENV{FAKE_LOGIN5_ERROR}));   # LoginResponse.error (field 2)
        }
        elsif ($ENV{FAKE_LOGIN5_CHALLENGE}) {
            my $chal = enc(1, 2, enc(1, 2, enc(1, 2, pack('H*', '0a0b0c0d0e0f1011')) . enc(2, 0, 12)));
            ($code, $payload) = (200, enc(3, 2, $chal) . enc(5, 2, 'CTX-FOR-HASHCASH'));   # challenges=3, login_context=5
        }
        else {
            ($code, $payload) = (200, $ok->($ENV{FAKE_S_LOGIN5}));
        }
    }
    elsif ($cid ne $ENV{FAKE_WP_CID} || ($H{'client-token'} // '') ne $ENV{FAKE_S_CLIENT_TOKEN}) {
        ($code, $payload) = (200, enc(2, 0, 2));   # LoginError BAD_REQUEST (response field 2)
    }
    else {
        my $sol = ff($req, 3);
        my ($CTX, $PREFIX, $LEN) = ('CTX-FOR-HASHCASH', pack('H*', '0a0b0c0d0e0f1011'), 12);
        if ($ENV{FAKE_LOGIN5_HASHCASH} && !defined $sol) {
            my $chal = enc(1, 2, enc(1, 2, enc(1, 2, $PREFIX) . enc(2, 0, $LEN)));   # Challenges{Challenge{hashcash{prefix,length}}}
            ($code, $payload) = (200, enc(3, 2, $chal) . enc(5, 2, $CTX));          # challenges=3, login_context=5
        }
        else {
            my $good = 1;
            if ($ENV{FAKE_LOGIN5_HASHCASH}) {
                $good = 0;
                my $suffix;
                my $cs = pf($sol);
                if ($cs && $cs->{1}) {
                    my $one = pf($cs->{1}[0]);
                    my $hs  = $one ? pf(ff($one, 1)) : undef;
                    $suffix = $hs ? ff($hs, 1) : undef;
                }
                if ((ff($req, 2) // '') eq $CTX && defined $suffix && length($suffix) == 16) {
                    my $target = unpack('Q>', substr(sha1($CTX), 12, 8));
                    my ($x, $y) = unpack('Q>Q>', $suffix);
                    my $diff = do { use integer; $x - $y };
                    my $v = unpack('Q>', substr(sha1($PREFIX . $suffix), 12, 8));
                    my $tz = 0;
                    if ($v) { until ($v & 1) { $v >>= 1; $tz++ } } else { $tz = 64 }
                    $good = (unpack('Q>', pack('q>', $diff)) == $target && $tz >= $LEN) ? 1 : 0;
                }
            }
            ($code, $payload) = (200, $good ? $ok->($ENV{FAKE_S_WP_LOGIN5}) : enc(2, 0, 2));
        }
    }
}
elsif ($url eq 'https://open.spotify.com/') {
    if ($method eq 'HEAD') {
        ($code, $payload) = (200, "HTTP/1.1 200 OK\r\nDate: Fri, 16 Oct 2026 12:00:00 GMT\r\n\r\n");
    }
    else {
        my $cfgJson = encode_base64(encode_json({ clientId => $ENV{FAKE_WP_CID}, other => 1 }), '');
        my $cfgTag  = $ENV{FAKE_NO_APPCONFIG} ? '' : qq{<script id="appServerConfig" type="text/plain">$cfgJson</script>};
        ($code, $payload) = (200, qq{<html><head>$cfgTag}
            . qq{<script src="https://open.spotifycdn.com/cdn/build/web-player/web-player.abc123.js"></script>}
            . qq{<script src="https://open.spotifycdn.com/cdn/build/web-player/vendor.def456.js" defer></script>}
            . qq{<script src="https://evil.example.test/never-fetched.js"></script></head></html>});
    }
}
elsif ($url =~ m{^https://open\.spotifycdn\.com/cdn/build/web-player/(web-player\.abc123|vendor\.def456)\.js$}) {
    my $which = $1;
    my $h = sub { sha256_hex("fake-op-$_[0]") };
    if ($which eq 'web-player.abc123') {
        my @ops = qw(home fetchPlaylistContents userTopContent);
        push @ops, 'searchDesktop' unless $ENV{FAKE_BUNDLE_NO_SEARCH};
        # decoy first (85-03 live finding: a bundle carries other services' clientId literals before the Web-Player one)
        $payload = 'var a=1;' . ($ENV{FAKE_NO_APPCONFIG} ? qq{x({clientId:"0123456789abcdef0123456789abcdef",deviceId:e}),} : '') . join('', map { qq{new l.l("$_","query","} . $h->($_) . qq{",null),} } @ops)
            . qq{new l.l("addToPlaylist","mutation","} . $h->('addToPlaylist') . qq{",null),}
            . qq{new l.l("brokenOp","query","zzzz-not-hex",null),};
    }
    else {
        $payload = 'var b=2;' . qq{new l.l("libraryV3","query","} . $h->('libraryV3') . qq{",null),}
            . ($ENV{FAKE_NO_APPCONFIG} ? qq{,clientID:"$ENV{FAKE_WP_CID}",clientId:"$ENV{FAKE_WP_CID}",} : '');
    }
    $code = 200;
}
elsif ($url eq 'https://clienttoken.spotify.com/v1/clienttoken') {
    my $req = eval { decode_json($body) } || {};
    if (($req->{client_data}{client_id} // '') eq $ENV{FAKE_WP_CID}) {
        ($code, $payload) = (200, encode_json({ response_type => 'RESPONSE_GRANTED_TOKEN_RESPONSE',
            granted_token => { token => $ENV{FAKE_S_CLIENT_TOKEN} } }));
    }
    else { ($code, $payload) = (400, '{"error":"bad client id"}'); }
}
elsif ($url eq 'https://api-partner.spotify.com/pathfinder/v2/query') {
    my $auth = $H{authorization} // '';
    my $authOk = $auth eq "Bearer $ENV{FAKE_S_WP_LOGIN5}"
        && ($H{'client-token'} // '') eq $ENV{FAKE_S_CLIENT_TOKEN};
    if (!$authOk) { ($code, $payload) = (401, '{"errors":[{"message":"unauthorized"}]}'); }
    else {
        my $req  = eval { decode_json($body) } || {};
        my $op   = $req->{operationName} // '';
        my $hash = $req->{extensions}{persistedQuery}{sha256Hash} // '';
        $code = 200;
        if ($ENV{FAKE_PQ_NOT_FOUND} || $hash ne sha256_hex("fake-op-$op")) {
            $payload = '{"errors":[{"message":"PersistedQueryNotFound"}]}';
        }
        elsif ($op eq 'searchDesktop') {
            $payload = encode_json({ data => { searchV2 => {
                tracksV2 => { items => [ map { { item => { data => { name => "Song $_" } } } } qw(A B C D E F G) ] },
                albumsV2 => { items => [ { data => { name => 'Album X' } } ] } } } });
        }
        elsif ($op eq 'home') {
            $payload = encode_json({ data => { home => { sectionContainer => { sections => { items => [ { name => 'S1' }, { name => 'S2' } ] } } } } });
        }
        else {
            $payload = encode_json({ data => { $op => { items => [ { name => 'Generic' } ] } } });
        }
    }
}
elsif ($url =~ m{^https://apresolve\.spotify\.com/}) {
    ($code, $payload) = (200, '{"spclient":["fake-spclient.test:443"]}');
}
elsif ($url =~ m{^\Q$HOST\E/metadata/4/track/[0-9a-f]{32}$}) {
    ($code, $payload) = (200, '{"name":"Fake Track","artist":[{"name":"Fake Artist"}]}');
}
elsif ($url =~ m{^\Q$HOST\E/context-resolve/v1/spotify:user:[^/]+:collection$}) {
    # 79-27: the liked-songs URI list (JSON pages[].tracks[].uri), as SpClient::_likedSongsUris reads it
    my @liked = map { { uri => sprintf('spotify:track:%02dLIKEDxxxxxxxxxxxxxxx', $_) } } 1 .. 5;
    push @liked, { uri => 'spotify:episode:99LIKEDxxxxxxxxxxxxxxx' };   # not a track: the probe must skip it
    ($code, $payload) = (200, encode_json({ pages => [ { tracks => \@liked } ] }));
}
elsif ($url =~ m{^\Q$HOST\E/extended-metadata/v0/extended-metadata(?:\?(.*))?$}) {
    # 79-27: canned BatchedExtensionResponse. One EntityExtensionData per requested entity
    # (FAKE_EXTMETA_SHORT=k answers only the first k); entity 2 -> status 404 with FAKE_EXTMETA_404,
    # entity 1 -> no Track name with FAKE_EXTMETA_NONAME, entity 3 -> no header with FAKE_EXTMETA_NOHEADER;
    # FAKE_EXTMETA_CODE answers a plain HTTP error instead.
    if (($ENV{FAKE_EXTMETA_CODE} // 200) != 200) {
        ($code, $payload) = ($ENV{FAKE_EXTMETA_CODE}, '');
    }
    elsif (($H{'content-type'} // '') ne 'application/x-protobuf') {
        ($code, $payload) = (415, '');
    }
    else {
        my $req   = pf($body) || {};
        my @ents  = @{ $req->{2} || [] };
        @ents = @ents[0 .. $ENV{FAKE_EXTMETA_SHORT} - 1] if defined $ENV{FAKE_EXTMETA_SHORT} && $ENV{FAKE_EXTMETA_SHORT} < @ents;
        my $i = 0;
        my @data;
        for my $e (@ents) {
            $i++;
            my $uri = ff(pf($e) || {}, 1) // '';
            my $status = ($ENV{FAKE_EXTMETA_404} && $i == 2) ? 404 : 200;
            my $track  = '';
            $track .= enc(2, 2, "Fake Entity Name $i") unless $ENV{FAKE_EXTMETA_NONAME} && $i == 1;
            $track .= enc(7, 0, 2 * 215000);   # sint32 duration 215000 (zigzag)
            my $hdr = ($ENV{FAKE_EXTMETA_NOHEADER} && $i == 3) ? '' : enc(1, 2, enc(1, 0, $status));
            push @data, enc(3, 2, $hdr . enc(2, 2, $uri)
                . enc(3, 2, enc(1, 2, 'type.googleapis.com/spotify.metadata.Track') . enc(2, 2, $track)));
        }
        ($code, $payload) = (200, enc(2, 2, enc(2, 0, 10) . join('', @data)));
    }
}
elsif ($url =~ m{^\Q$HOST\E/playlist/v2/user/[^/]+/rootlist\?}) {
    my @pl = (
        ['spotify:playlist:37i9dQZF1E39AAAAAAAAAA', 'Daily Mix 1',      'spotify', 50],
        ['spotify:playlist:37i9dQZEVXcBBBBBBBBBBB', 'Discover Weekly',  'spotify', 30],
        ['spotify:playlist:1234567890abcdefghijkl', 'My Own List',      'fakeuser123', 7],
        ['spotify:start-group:abcdef:Folder',       'Folder',           'fakeuser123', 0],
    );
    my $items = join '', map { enc(3, 2, enc(1, 2, $_->[0])) } @pl;
    my $deco  = join '', map { enc(4, 2, enc(2, 2, enc(1, 2, $_->[1])) . enc(3, 0, $_->[3]) . enc(5, 2, $_->[2])) } @pl;
    ($code, $payload) = (200, enc(1, 2, 'rev24bytesrev24bytesrev2') . enc(5, 2, $items . $deco));
}
elsif ($url =~ m{^\Q$HOST\E/user-profile-view/v3/profile/}) {
    ($code, $payload) = (200, encode_json({
        uri => 'spotify:user:fakeuser123', name => 'Fake Display Name', image_url => 'x',
        followers_count => 3, following_count => 4,
        public_playlists => [{}, {}], recently_played_artists => [{}, {}, {}],
    }));
}
elsif ($url =~ m{^\Q$HOST\E/playlist/v2/playlist/([0-9A-Za-z]{22})/changes$}) {
    my $c = next_code('FAKE_CHANGES_CODES', 200);
    ($code, $payload) = ($c, '');
}
elsif ($url =~ m{^\Q$HOST\E/playlist/v2/playlist/([0-9A-Za-z]{22})\?decorate=revision}) {
    my $n = 1;   # the revision "number" grows with each read (counter lives in the state dir)
    if (open(my $i, '<', "$ENV{FAKE_STATE}/rev_n")) { $n = (<$i> // 0) + 1; close $i; }
    open(my $o, '>', "$ENV{FAKE_STATE}/rev_n") or die; print $o $n; close $o;
    ($code, $payload) = (200, enc(1, 2, "REVISION-BYTES-$n"));
}
elsif ($url =~ m{^\Q$HOST\E/playlist/v2/playlist/([0-9A-Za-z]{22})$}) {
    my $accept = $H{accept} // '';
    my @uris = ('spotify:track:11dFghVXANMlKmJXsNCbNl', 'spotify:track:22dFghVXANMlKmJXsNCbNl');
    if ($ENV{FAKE_PLAYLIST_READ_CODE} && $accept =~ m{json}) {
        ($code, $payload) = ($ENV{FAKE_PLAYLIST_READ_CODE}, '{"error":"nope"}');
    }
    elsif ($accept =~ m{json}) {
        ($code, $payload) = (200, encode_json({ revision => 'abc', length => 2,
            contents => { items => [ map { { uri => $_ } } @uris ] } }));
    }
    else {
        ($code, $payload) = (200, enc(1, 2, 'REVBYTES') . enc(5, 2, join '', map { enc(3, 2, enc(1, 2, $_)) } @uris));
    }
}
elsif ($url =~ m{^\Q$HOST\E/collection/v2/(contains|write)$}) {
    my $which = $1;
    my $ct = 'application/vnd.collection-v2.spotify.proto';
    if (($H{'content-type'} // '') ne $ct || ($H{accept} // '') ne $ct) {
        ($code, $payload) = (415, '');
    }
    else {
        my $req  = pf($body) || {};
        my $set  = ff($req, 2);
        my @items = map { pf($_) || {} } @{ $req->{3} || [] };
        if ($which eq 'contains') {
            my $n = $ENV{FAKE_CONTAINS_COUNT} // scalar @items;
            my @found = map { st_get($set, ff($items[0], 1)) } 1 .. $n;
            if (($ENV{FAKE_CONTAINS_WIRE} // 'packed') eq 'packed') {
                ($code, $payload) = (200, enc(1, 2, join '', map { chr($_) } @found));
            }
            else {
                ($code, $payload) = (200, join '', map { enc(1, 0, $_) } @found);
            }
        }
        else {
            for my $it (@items) {
                my $removed = ff($it, 3) ? 1 : 0;
                st_set($set, ff($it, 1), $removed ? 0 : 1);
            }
            ($code, $payload) = ($ENV{FAKE_WRITE_CODE} || 200, '');
        }
    }
}
elsif ($url =~ m{^\Q$HOST\E/searchview/km/v4/search/}) {
    if ($url =~ /platform=zelda/) {
        ($code, $payload) = (200, encode_json({ requestId => 'x', results => {
            tracks => { hits => [{}, {}, {}] }, albums => { hits => [{}] }, artists => { hits => [] } } }));
    }
    else {
        ($code, $payload) = (400, '{"error":"Query-Parameter unbekannt"}');
    }
}
elsif ($url =~ m{^\Q$HOST\E/(some/probe/path)$}) {
    if ($method eq 'POST') {
        ($code, $payload) = (200, encode_json({ posted => 1, bytes => length($body), ct => ($H{'content-type'} // '') }));
    }
    else {
        ($code, $payload) = (200, '{"alpha":1,"beta":[1,2],"gamma":{}}');
    }
}

if ($flag{'--fail'} && $code >= 400) {
    print STDERR "curl: (22) The requested URL returned error: $code\n";
    exit 22;
}
binmode STDOUT;
print $payload;
if (defined $wfmt) {
    (my $w = $wfmt) =~ s/%\{http_code\}/$code/g;
    print $w;
}
exit 0;
FAKE_CURL

$FAKE =~ s/^#!PERL/#!$^X/;
open(my $ffh, '>', "$bin/curl") or die $!;
print $ffh $FAKE;
close $ffh;
chmod 0755, "$bin/curl";

# ------------------------------------------------------------
# Harness
# ------------------------------------------------------------
sub run_tool {
    my ($env, @args) = @_;
    unlink $log;
    remove_tree($state);
    make_path($state);
    local %ENV = (
        %ENV,
        PATH       => "$bin:$ENV{PATH}",
        FAKE_ROOT  => $project_dir,
        FAKE_LOG   => $log,
        FAKE_STATE => $state,
        FAKE_WP_CID => $WP_CID,
        (map { ("FAKE_S_$_" => $S{$_}) } keys %S),
        %{ $env || {} },
    );
    my ($w, $r) = (gensym(), gensym());
    my $pid = open3($w, $r, undef, $^X, $TOOL, $creds, @args);
    close $w;
    my $out = do { local $/; <$r> };
    close $r;
    waitpid($pid, 0);
    my $exit = $? >> 8;
    my @req;
    if (open(my $lf, '<', $log)) {
        while (my $l = <$lf>) { push @req, decode_json($l); }
        close $lf;
    }
    push @main::ALL_OUTPUT, $out;
    push @main::ALL_REQ,    @req;
    return ($exit, $out // '', \@req);
}

sub with_url   { my ($req, $re) = @_; return grep { $_->{url} =~ $re } @$req; }
sub body_json { my ($r) = @_; return $r ? (eval { decode_json(pack('H*', $r->{body_hex})) } || {}) : {}; }
sub hdr_of     { my ($r, $name) = @_; for my $h (@{ $r->{headers} }) { my ($k, $v) = split /:\s*/, $h, 2; return $v if lc $k eq lc $name; } return undef; }

our (@ALL_OUTPUT, @ALL_REQ);

# ------------------------------------------------------------
# 1. existing behaviour: default mode and `profile` stay unchanged
# ------------------------------------------------------------
{
    my ($exit, $out, $req) = run_tool({});
    is($exit, 0, 'default mode: exit 0');
    like($out, qr/^creds: loaded \(username=fak\*\*\*\*\)$/m, 'default mode: creds line unchanged');
    like($out, qr/^mint: OK \(token length=\d+, expires_in=3600s\)$/m, 'default mode: mint line unchanged');
    like($out, qr/^apresolve: using host fake-spclient\.test:443$/m, 'default mode: apresolve line unchanged');
    like($out, qr/^metadata: track="Fake Track" artists="Fake Artist"$/m, 'default mode: metadata line unchanged');
    like($out, qr/^rootlist: playlist count=3$/m, 'default mode: rootlist line unchanged');
    like($out, qr/^OK: login5 \+ spclient round-trip succeeded end to end\.$/m, 'default mode: closing OK line unchanged');
    is(scalar(grep { $_->{url} =~ /collection|changes|searchview/ } @$req), 0, 'default mode: sends no probe request');
}
{
    my ($exit, $out) = run_tool({}, '-', 'profile');
    like($out, qr/^profile: name=Fake Display Name uri=spotify:user:fakeuser123$/m, 'profile mode: line unchanged and "-" accepted as track id');
}
{
    my ($exit, $out, $req) = run_tool({}, '-', 'no-such-mode');
    isnt($exit, 0, 'unknown mode: non-zero exit');
    is(scalar(@$req), 0, 'unknown mode: refused before any request is sent');
}

# ------------------------------------------------------------
# 2. collection-roundtrip (D-14)
# ------------------------------------------------------------
my $TRACK_URI = 'spotify:track:11dFghVXANMlKmJXsNCbNl';
{
    my ($exit, $out, $req) = run_tool({}, '-', 'collection-roundtrip', 'collection', $TRACK_URI);
    my @coll = with_url($req, qr{/collection/v2/});
    is(join(' ', map { ($_->{url} =~ m{/v2/(\w+)$})[0] } @coll),
       'contains write contains write contains', 'roundtrip: request order contains/write/contains/write/contains');
    like($out, qr/^contains_before=0$/m,         'roundtrip: contains_before=0');
    like($out, qr/^write_add=200$/m,             'roundtrip: write_add=200');
    like($out, qr/^contains_after_add=1$/m,      'roundtrip: contains_after_add=1');
    like($out, qr/^write_remove=200$/m,          'roundtrip: write_remove=200');
    like($out, qr/^contains_after_remove=0$/m,   'roundtrip: contains_after_remove=0');
    my $add = pf_item($coll[1]);
    my $rem = pf_item($coll[3]);
    ok($add->{uri} eq $TRACK_URI && $add->{added_at} && !$add->{removed},
       'roundtrip: add item carries uri and added_at, no tombstone');
    ok($rem->{uri} eq $TRACK_URI && $rem->{removed} == 1 && !defined $rem->{added_at},
       'roundtrip: remove item carries is_removed=1 and no added_at');
    ok(!grep({ hdr_of($_, 'Content-Type') ne 'application/vnd.collection-v2.spotify.proto'
            || hdr_of($_, 'Accept') ne 'application/vnd.collection-v2.spotify.proto' } @coll),
       'roundtrip: content type and accept are the collection-v2 proto type on every request');
}
{
    my ($exit, $out, $req) = run_tool({ FAKE_CONTAINS_WIRE => 'varint' }, '-', 'collection-roundtrip', 'collection', $TRACK_URI);
    like($out, qr/^contains_before=0$/m, 'roundtrip: unpacked (repeated varint) contains answers decode');
    like($out, qr/^contains_after_add=1$/m, 'roundtrip: unpacked answer after add decodes as 1');
}
{
    my ($exit, $out, $req) = run_tool({ FAKE_CONTAINS_INITIAL => 1 }, '-', 'collection-roundtrip', 'collection', $TRACK_URI);
    like($out, qr/^ABORT already_present \(no write, no residue\)$/m, 'roundtrip: already present aborts with the exact message');
    is(scalar(with_url($req, qr{/collection/v2/write})), 0, 'roundtrip: already present sends no write request');
}
{
    my ($exit, $out, $req) = run_tool({ FAKE_CONTAINS_COUNT => 2 }, '-', 'collection-roundtrip', 'collection', $TRACK_URI);
    like($out, qr/^ABORT contains_answer_count got=2 want=1$/m, 'roundtrip: a wrong answer count aborts');
    is(scalar(with_url($req, qr{/collection/v2/write})), 0, 'roundtrip: a wrong answer count sends no write request');
}

sub pf_item {   # first CollectionItem of a WriteRequest/ContainsRequest logged request
    my ($r) = @_;
    my $body = pack('H*', $r->{body_hex});
    my $f = $PB->can('parse_fields')->($body);
    my $it = $PB->can('parse_fields')->($PB->can('field_first')->($f, 3));
    return { uri => $PB->can('field_first')->($it, 1), added_at => $PB->can('field_first')->($it, 2),
             removed => $PB->can('field_first')->($it, 3) };
}

# ------------------------------------------------------------
# 3. profile-keys (D-05)
# ------------------------------------------------------------
{
    my ($exit, $out) = run_tool({}, '-', 'profile-keys');
    like($out, qr/^keys: followers_count,following_count,image_url,name,public_playlists,recently_played_artists,uri$/m,
         'profile-keys: sorted top-level keys');
    like($out, qr/^array public_playlists len=2$/m, 'profile-keys: array length printed');
    like($out, qr/^name_present=1 name_len=17$/m, 'profile-keys: name_present and name_len');
    unlike($out, qr/Fake Display Name/, 'profile-keys: never prints the value of name');
}

# ------------------------------------------------------------
# 4. rootlist-list / playlist-find (D-16a)
# ------------------------------------------------------------
{
    my ($exit, $out) = run_tool({}, '-', 'rootlist-list');
    like($out, qr/^rootlist_total=3 mix_37i9=2$/m, 'rootlist-list: totals');
    like($out, qr/^mix: Daily Mix 1$/m, 'rootlist-list: names the first 37i9 mix');
    like($out, qr/^mix: Discover Weekly$/m, 'rootlist-list: names the second 37i9 mix');
    unlike($out, qr/^mix: My Own List$/m, 'rootlist-list: does not list a user playlist as a mix');
}
{
    my ($exit, $out) = run_tool({}, '-', 'playlist-find', 'Discover Weekly');
    like($out, qr/^found spotify:playlist:37i9dQZEVXcBBBBBBBBBBB$/m, 'playlist-find: exact name found');
    my ($e2, $o2) = run_tool({}, '-', 'playlist-find', 'Discover');
    like($o2, qr/^not_found$/m, 'playlist-find: a partial name is not_found');
}

# ------------------------------------------------------------
# 5. playlist-read (D-16a readability)
# ------------------------------------------------------------
{
    my ($exit, $out, $req) = run_tool({}, '-', 'playlist-read', '37i9dQZF1E39AAAAAAAAAA');
    like($out, qr/^playlist-read json HTTP 200 items=2$/m, 'playlist-read: JSON variant status and item count');
    like($out, qr/^playlist-read protobuf HTTP 200 items=2$/m, 'playlist-read: protobuf variant status and item count');
    my @pr = with_url($req, qr{/playlist/v2/playlist/37i9dQZF1E39AAAAAAAAAA$});
    is(join(',', map { hdr_of($_, 'Accept') } @pr), 'application/json,application/x-protobuf', 'playlist-read: Accept json first, then protobuf');
    my ($e2, $o2) = run_tool({ FAKE_PLAYLIST_READ_CODE => 404 }, '-', 'playlist-read', '37i9dQZF1E39AAAAAAAAAA');
    like($o2, qr/^playlist-read json HTTP 404 items=-$/m, 'playlist-read: a refused variant prints the status and items=-');
}

# ------------------------------------------------------------
# 6. playlist-append (D-14)
# ------------------------------------------------------------
my $PLID = '1234567890abcdefghijkl';
{
    my ($exit, $out, $req) = run_tool({}, '-', 'playlist-append', $PLID, $TRACK_URI);
    my ($rev) = with_url($req, qr{/playlist/v2/playlist/$PLID\?decorate=revision&from=0&length=1$});
    my ($chg) = with_url($req, qr{/playlist/v2/playlist/$PLID/changes$});
    ok($rev && !defined hdr_of($rev, 'Accept'), 'append: revision GET carries no Accept header (protobuf, not JSON)');
    ok($chg && $chg->{method} eq 'POST' && hdr_of($chg, 'Content-Type') eq 'application/x-protobuf', 'append: changes is a POST with Content-Type application/x-protobuf');
    like($out, qr/^revision_len=16 changes=200$/m, 'append: prints revision_len and the changes status');
    my $f = $PB->can('parse_fields')->(pack('H*', $chg->{body_hex}));
    my $delta = $PB->can('parse_fields')->($PB->can('field_first')->($f, 2));
    my $op    = $PB->can('parse_fields')->($PB->can('field_first')->($delta, 2));
    my $add   = $PB->can('parse_fields')->($PB->can('field_first')->($op, 2));
    my $item  = $PB->can('parse_fields')->($PB->can('field_first')->($add, 2));
    my $info  = $PB->can('parse_fields')->($PB->can('field_first')->($delta, 4));
    ok($PB->can('field_first')->($f, 1) eq 'REVISION-BYTES-1'
        && $PB->can('field_first')->($op, 1) == 2
        && $PB->can('field_first')->($item, 1) eq $TRACK_URI
        && $PB->can('field_first')->($add, 4) == 1
        && $PB->can('field_first')->($info, 1) eq 'fakeuser123'
        && $PB->can('field_first')->($info, 2) > 1_000_000_000_000,
       'append: ListChanges carries base_revision, ADD op, uri, add_last and ChangeInfo');
}
{
    my ($exit, $out, $req) = run_tool({ FAKE_CHANGES_CODES => '409,200' }, '-', 'playlist-append', $PLID, $TRACK_URI);
    my @chg = with_url($req, qr{/changes$});
    my @rev = with_url($req, qr{decorate=revision&from=0&length=1});
    is(scalar(@chg) . '/' . scalar(@rev), '2/2', 'append 409: exactly one re-read and one retry');
    like($out, qr/^revision_len=16 changes_retry=200$/m, 'append 409: the retry status is printed');
    my $f2 = $PB->can('parse_fields')->(pack('H*', $chg[1]{body_hex}));
    is($PB->can('field_first')->($f2, 1), 'REVISION-BYTES-2', 'append 409: the retry carries the re-read revision');
}
{
    my ($exit, $out, $req) = run_tool({ FAKE_CHANGES_CODES => '503,200' }, '-', 'playlist-append', $PLID, $TRACK_URI);
    is(scalar(with_url($req, qr{/changes$})), 1, 'append 5xx: never retried (non-idempotent)');
    like($out, qr/^revision_len=16 changes=503$/m, 'append 5xx: the failing status is printed');
}

# ------------------------------------------------------------
# 7. probe (GET and POST) and search-probe
# ------------------------------------------------------------
{
    my ($exit, $out, $req) = run_tool({}, '-', 'probe', 'some/probe/path', 'json');
    like($out, qr{^probe some/probe/path HTTP 200 bytes=\d+ keys=alpha,beta,gamma$}m, 'probe GET: status, bytes and top-level keys');
    my ($pr) = with_url($req, qr{/some/probe/path$});
    is(hdr_of($pr, 'Accept'), 'application/json', 'probe GET json: Accept application/json');
}
{
    my $bodyfile = "$tmp/post.body";
    open(my $bf, '>', $bodyfile) or die; binmode $bf; print $bf "\x01\x02POSTBODY\x00\xff"; close $bf;
    my ($exit, $out, $req) = run_tool({}, '-', 'probe', 'some/probe/path', 'protobuf', 'post', $bodyfile, 'application/x-protobuf');
    like($out, qr{^probe some/probe/path HTTP 200 bytes=\d+ keys=bytes,ct,posted$}m, 'probe POST: status, bytes and keys of the answer');
    my ($pr) = with_url($req, qr{/some/probe/path$});
    ok($pr->{method} eq 'POST' && $pr->{body_hex} eq unpack('H*', "\x01\x02POSTBODY\x00\xff")
        && hdr_of($pr, 'Content-Type') eq 'application/x-protobuf' && hdr_of($pr, 'Accept') eq 'application/x-protobuf',
       'probe POST: sends the body file bytes with the given content type');
}
{
    my ($exit, $out, $req) = run_tool({}, '-', 'search-probe', 'daft punk');
    like($out, qr/^search-probe with_platform HTTP 200 bytes=\d+ keys=requestId,results$/m, 'search-probe: variant with platform');
    like($out, qr/^search-probe without_platform HTTP 400 bytes=\d+ keys=error$/m, 'search-probe: variant without platform');
    like($out, qr/^count results\.tracks\.hits 3$/m, 'search-probe: per-entity-type count for tracks');
    like($out, qr/^count results\.albums\.hits 1$/m, 'search-probe: per-entity-type count for albums');
    my @s = with_url($req, qr{/searchview/km/v4/search/});
    ok(@s == 2 && $s[0]{url} =~ m{/search/daft%20punk\?entityVersion=2&limit=10&offset=0&catalogue=&country=\w*&locale=\w*&platform=zelda&username=fakeuser123$}
        && $s[1]{url} !~ /platform=/, 'search-probe: both candidate URLs are built as RESEARCH 2.1 describes');
}

# ------------------------------------------------------------
# 9. pathfinder-ops (cookie-free scrape, D-19 and the Pathfinder-backed options)
# ------------------------------------------------------------
sub fakehash { return sha256_hex("fake-op-$_[0]"); }
sub hdr_names { my ($r) = @_; return map { (split /:/, $_, 2)[0] } @{ $r->{headers} }; }
{
    my ($exit, $out, $req) = run_tool({}, '-', 'pathfinder-ops');
    is($exit, 0, 'pathfinder-ops: exit 0');
    for my $op (qw(home fetchPlaylistContents searchDesktop userTopContent)) {
        like($out, qr/^op \Q$op\E ${\ fakehash($op)}$/m, "pathfinder-ops: op line for $op with its 64-hex hash");
    }
    like($out, qr/^op addToPlaylist ${\ fakehash('addToPlaylist')}$/m, 'pathfinder-ops: mutation operations are listed too');
    like($out, qr/^op libraryV3 ${\ fakehash('libraryV3')}$/m, 'pathfinder-ops: operations of the second bundle are listed');
    unlike($out, qr/brokenOp/, 'pathfinder-ops: an entry whose hash is not 64-hex is never printed');
    like($out, qr/^ops_total=6$/m, 'pathfinder-ops: ops_total counts the printed pairs');
    unlike($out, qr/^op_missing /m, 'pathfinder-ops: nothing reported missing when the bundle carries all three');
    my @scrape = grep { $_->{url} =~ m{^https://open\.spotify(?:cdn)?\.com/} } @$req;
    ok(@scrape == 3 && !grep({ grep { /^cookie$/i } hdr_names($_) } @scrape),
       'pathfinder-ops: the scrape (page + 2 bundles) sends no Cookie header');
    ok(!(grep { $_->{url} =~ m{evil\.example\.test} } @$req), 'pathfinder-ops: only open.spotifycdn.com scripts are fetched');
    ok(!(grep { $_->{url} =~ m{clienttoken|api-partner|api/token} } @$req), 'pathfinder-ops: no token or query request is made');
}
{
    my ($exit, $out) = run_tool({ FAKE_BUNDLE_NO_SEARCH => 1 }, '-', 'pathfinder-ops');
    like($out, qr/^op_missing searchDesktop$/m, 'pathfinder-ops: an absent searchDesktop is reported, not skipped silently');
}

# ------------------------------------------------------------
# 10. wpcid-probe (D-16b) and pathfinder-query with the WP-CID bearer
# ------------------------------------------------------------
{
    my ($exit, $out, $req) = run_tool({ FAKE_LOGIN5_HASHCASH => 1 }, '-', 'wpcid-probe');
    my $home = fakehash('home');
    like($out, qr/^step1 client_id_len=32 home_hash=$home$/m, 'wpcid-probe: step1 client id length and the home hash');
    like($out, qr/^step2 client_token HTTP 200 len=\d+$/m, 'wpcid-probe: step2 anonymous client-token');
    like($out, qr/^step3 login5 ok hashcash=1 token_len=\d+$/m, 'wpcid-probe: step3 login5 answered the HashCash challenge');
    like($out, qr/^step4 home HTTP 200 errors=0$/m, 'wpcid-probe: step4 home query accepted with the login5 bearer');
    my @l5 = grep { $_->{url} =~ m{login5} && hdr_of($_, 'client-token') } @$req;
    is(scalar(@l5), 2, 'wpcid-probe: the WP-CID login5 is sent twice (challenge, then solution)');
    my ($pf) = with_url($req, qr{pathfinder/v2/query$});
    my $pb = body_json($pf);
    ok($pb->{operationName} eq 'home' && $pb->{extensions}{persistedQuery}{sha256Hash} eq $home
        && $pb->{extensions}{persistedQuery}{version} == 1, 'wpcid-probe: the home body carries operationName and the scraped persisted-query hash');
}
{
    my ($exit, $out) = run_tool({}, '-', 'wpcid-probe');
    like($out, qr/^step3 login5 ok hashcash=0 token_len=\d+$/m, 'wpcid-probe: no challenge reports hashcash=0');
}
{
    my ($exit, $out, $req) = run_tool({ FAKE_NO_APPCONFIG => 1 }, '-', 'wpcid-probe');
    like($out, qr/^step1 client_id_len=32 /m, 'wpcid-probe: client id falls back to the bundle when the page config is absent');
    like($out, qr/^step2 client_token HTTP 200 /m, 'wpcid-probe: the bundle fallback picks the id that occurs most often, not the first literal (decoy ignored)');
}
{
    my $vars = "$tmp/vars.json";
    open(my $vf, '>', $vars) or die; print $vf '{"searchTerm":"daft punk","limit":10,"offset":0}'; close $vf;
    my ($exit, $out, $req) = run_tool({ FAKE_LOGIN5_HASHCASH => 1 }, '-', 'pathfinder-query', 'searchDesktop', $vars, 'wpcid');
    like($out, qr/^step3 login5 ok hashcash=1 token_len=\d+$/m, 'pathfinder-query wpcid: the chain logs in');
    like($out, qr/^query HTTP 200 errors=0 data_keys=searchV2$/m, 'pathfinder-query wpcid: status, errors flag and data keys');
    like($out, qr/^items data\.searchV2\.tracksV2\.items 7$/m, 'pathfinder-query wpcid: item count of the tracks array');
    like($out, qr/^items data\.searchV2\.albumsV2\.items 1$/m, 'pathfinder-query wpcid: item count of the albums array');
    is(scalar(() = $out =~ /^name: /mg), 5, 'pathfinder-query wpcid: at most five item names are printed');
    like($out, qr/^name: Song A$/m, 'pathfinder-query wpcid: names come from the response');
    my ($pf) = with_url($req, qr{pathfinder/v2/query$});
    my $pb = body_json($pf);
    ok($pb->{operationName} eq 'searchDesktop' && $pb->{extensions}{persistedQuery}{sha256Hash} eq fakehash('searchDesktop')
        && $pb->{variables}{searchTerm} eq 'daft punk' && $pb->{variables}{limit} == 10,
       'pathfinder-query: the request carries the scraped hash and the variables file content');
    is(hdr_of($pf, 'Authorization'), "Bearer $S{WP_LOGIN5}", 'pathfinder-query wpcid: the Pathfinder bearer is the WP-CID login5 token');
}
{
    my $vars = "$tmp/vars.json";
    my ($exit, $out) = run_tool({ FAKE_PQ_NOT_FOUND => 1 }, '-', 'pathfinder-query', 'home', $vars, 'wpcid');
    like($out, qr/^query errors=1 persisted_query_not_found=1$/m, 'pathfinder-query: PersistedQueryNotFound gets its own line');
    my ($e2, $o2, $r2) = run_tool({}, '-', 'pathfinder-query', 'noSuchOperation', $vars, 'wpcid');
    like($o2, qr/^ABORT op_not_in_bundle$/m, 'pathfinder-query: an operation the bundle does not carry aborts');
    ok(!(grep { $_->{url} =~ m{pathfinder|clienttoken} } @$r2), 'pathfinder-query: op_not_in_bundle aborts before any token request');
}

# ------------------------------------------------------------
# 11. (85-15, D-01/D-17) the pathfinder-query mode with the cookie bearer is removed together with the
#     cookie flow; the mode takes only the stored-credentials login5 bearer (wpcid).
# ------------------------------------------------------------
{
    my $vars = "$tmp/vars.json";
    # the cookie variable IS set, so only the removed mode itself can account for a refusal
    my ($exit, $out, $req) = run_tool({ SPOTON_85_SPDC => 'fake-cookie-value-not-a-secret' }, '-', 'pathfinder-query', 'home', $vars, 'spdc');
    isnt($exit, 0, 'pathfinder-query: the removed cookie bearer argument is refused (non-zero exit)');
    is(scalar(@$req), 0, 'pathfinder-query: the removed cookie bearer argument is refused before any request');
}
# ------------------------------------------------------------
# 12. HashCash solver: the real code, lifted from the tool source between its markers
# ------------------------------------------------------------
my $src = do { open(my $sf, '<', $TOOL) or die $!; local $/; <$sf> };
for my $blk (qw(hashcash)) {
    my ($code) = $src =~ /^# BEGIN \Q$blk\E\n(.*?)^# END \Q$blk\E\n/ms;
    ok(defined $code && length $code, "$blk: block is delimited in the tool source");
    next unless $code;
    package HC;
    use Digest::SHA qw(sha1);
    use JSON::PP qw(decode_json);
    eval "use strict; use warnings; $code; 1" or die "block $blk does not compile: $@";
    package main;
}
{
    my $ctx    = 'login-context-test-vector';
    my $prefix = pack('H*', '0102030405060708090a0b0c0d0e0f10');
    my ($suffix, $counter) = HC->can('solve_hashcash') ? HC::solve_hashcash($ctx, $prefix, 12, 5) : ();
    is(defined $suffix ? unpack('H*', $suffix) : 'undef', '36135707094133fb0000000000000233',
       'hashcash: fixed test vector (length 12) matches the independent python reference suffix');
    my ($s14) = HC->can('solve_hashcash') ? HC::solve_hashcash($ctx, $prefix, 14, 5) : ();
    is(defined $s14 ? unpack('H*', $s14) : 'undef', '361357070941388800000000000006c0',
       'hashcash: fixed test vector (length 14) matches the independent python reference suffix');
    my $tz = -1;
    if (defined $suffix) {
        my $v = unpack('Q>', substr(sha1($prefix . $suffix), 12, 8));
        $tz = 0; until ($v & 1) { $v >>= 1; $tz++ };
    }
    cmp_ok($tz, '>=', 12, 'hashcash: SHA-1 trailing zeros over bytes 12..19 of (prefix || suffix) reach the requested length');
    my $t0 = time();
    my ($never) = HC->can('solve_hashcash') ? HC::solve_hashcash($ctx, $prefix, 60, 1) : ('x');
    ok(!defined $never && time() - $t0 <= 5, 'hashcash: an unreachable length gives up at the deadline instead of looping');
}
# ------------------------------------------------------------
# 13. (85-18, CR-01) the main mint stage reads LoginResponse{ok=1, error=2, challenges=3,
#     login_context=5} (librespot login5.proto, commit 19959512) and SPOTON_SMOKE_LOGIN5_DUMP
# ------------------------------------------------------------
my $DUMPDIR = "$tmp/dump";
make_path($DUMPDIR);
chmod 0700, $DUMPDIR;
{
    my ($exit, $out, $req) = run_tool({ FAKE_LOGIN5_ERROR => 1 });
    isnt($exit, 0, 'CR-01 smoke: LoginError INVALID_CREDENTIALS (field 2 = 1): non-zero exit');
    like($out, qr/^FAIL \[mint\]: login5 returned error code 1 \(INVALID_CREDENTIALS\)$/m,
        'CR-01 smoke: the failure line names error code 1 (INVALID_CREDENTIALS)');
    unlike($out, qr/HashCash challenge/, 'CR-01 smoke: an error reply is not reported as a HashCash challenge');
    is(scalar(@$req), 1, 'CR-01 smoke: nothing is sent after the login5 error reply');
}
{
    my ($exit, $out) = run_tool({ FAKE_LOGIN5_ERROR => 2 });
    isnt($exit, 0, 'CR-01 smoke: LoginError BAD_REQUEST (field 2 = 2): non-zero exit');
    like($out, qr/^FAIL \[mint\]: login5 returned error code 2 \(BAD_REQUEST\)$/m,
        'CR-01 smoke: the failure line names error code 2 (BAD_REQUEST)');
}
{
    my ($exit, $out, $req) = run_tool({ FAKE_LOGIN5_CHALLENGE => 1 });
    isnt($exit, 0, 'CR-01 smoke: a field-3 Challenges reply on the librespot client id: non-zero exit');
    like($out, qr/^FAIL \[mint\]: login5 returned a HashCash challenge/m,
        'CR-01 smoke: a field-3 Challenges reply gives the existing challenge failure line');
    unlike($out, qr/error code/, 'CR-01 smoke: a Challenges reply is not read as an error code');
}
{
    my $dump = "$DUMPDIR/err.bin";
    unlink $dump;
    my ($exit, $out) = run_tool({ FAKE_LOGIN5_ERROR => 1, SPOTON_SMOKE_LOGIN5_DUMP => $dump });
    my $bytes = '';
    if (open(my $dfh, '<:raw', $dump)) { local $/; $bytes = <$dfh>; close $dfh; }
    is(unpack('H*', $bytes), unpack('H*', enc_pb(2, 0, 1)), 'CR-01 dump: the file holds exactly the reply bytes');
    is(-f $dump ? (stat $dump)[2] & 07777 : -1, 0600, 'CR-01 dump: the file has mode 0600');
    like($out, qr/^login5-dump: wrote 2 bytes$/m, 'CR-01 dump: the output says how many bytes were written');
}
{
    my $dump = "$DUMPDIR/ok.bin";
    unlink $dump;
    my ($exit, $out) = run_tool({ SPOTON_SMOKE_LOGIN5_DUMP => $dump });
    ok(!-e $dump, 'CR-01 dump: a LoginOk reply is never written (it carries the bearer)');
    like($out, qr/^login5-dump: refused \(reply carries LoginOk\)$/m, 'CR-01 dump: the LoginOk refusal is reported');
    is($exit, 0, 'CR-01 dump: the run with a refused dump still succeeds');
}
{
    my $dump = "$DUMPDIR/exists.bin";
    open(my $efh, '>', $dump) or die $!; print $efh 'keep-me'; close $efh;
    my ($exit, $out) = run_tool({ FAKE_LOGIN5_ERROR => 1, SPOTON_SMOKE_LOGIN5_DUMP => $dump });
    my $left = do { open(my $rfh, '<', $dump) or die $!; local $/; <$rfh> };
    is($left, 'keep-me', 'CR-01 dump: an existing target is never overwritten');
    like($out, qr/^login5-dump: refused \(target exists\)$/m, 'CR-01 dump: the existing-target refusal is reported');
}
sub enc_pb { $PB->can('encode_field')->(@_) }

# ------------------------------------------------------------
# 79-27 (D-18): extmeta-probe - the batch ceiling of spclient's extended-metadata endpoint, counts only
# ------------------------------------------------------------
{
    my ($exit, $out, $req) = run_tool({}, '-', 'extmeta-probe', '3');
    my @pl = $out =~ /^(EXTMETA_PROBE .*)$/mg;
    is(scalar(@pl), 1, '79-27 PROBE: extmeta-probe 3 prints exactly one EXTMETA_PROBE line');
    like($pl[0] // '', qr/^EXTMETA_PROBE n=3 http=200 bytes=\d+ entities=3 status_ok=3 status_other=0 status_absent=0 named=3 ms=\d+ query=none$/,
        '79-27 PROBE: the line carries n, http, bytes, entities, status counters, named, ms and query=none');
    my ($pr) = with_url($req, qr{/extended-metadata/v0/extended-metadata$});
    my $f   = $pr ? ($PB->can('parse_fields')->(pack('H*', $pr->{body_hex})) || {}) : {};
    my @ent = map { $PB->can('parse_fields')->($_) || {} } @{ $f->{2} || [] };
    my @uri = map { $PB->can('field_first')->($_, 1) // '' } @ent;
    my @kind = map { my $q = $PB->can('parse_fields')->($PB->can('field_first')->($_, 2) // '') || {}; $PB->can('field_first')->($q, 1) // -1 } @ent;
    is(join(',', @uri), join(',', map { sprintf('spotify:track:%02dLIKEDxxxxxxxxxxxxxxx', $_) } 1 .. 3),
        '79-27 PROBE: the POST body holds the first 3 liked track URIs in order (the episode URI is skipped)');
    is(join(',', @kind), '10,10,10', '79-27 PROBE: every ExtensionQuery asks extension_kind 10 (TRACK_V4)');
    ok($pr && $pr->{method} eq 'POST' && hdr_of($pr, 'Content-Type') eq 'application/x-protobuf' && hdr_of($pr, 'Accept') eq 'application/x-protobuf',
        '79-27 PROBE: POST with Content-Type and Accept application/x-protobuf');
    ok(!(grep { /Fake Entity Name|fakeuser123|FAKE_LOGIN5_TOKEN|LIKEDxxxx/ } @pl),
        '79-27 PROBE: the EXTMETA_PROBE line holds no track name, username, URI or token');
}
{
    my ($exit, $out) = run_tool({ FAKE_EXTMETA_404 => 1 }, '-', 'extmeta-probe', '3,5');
    my @pl = $out =~ /^(EXTMETA_PROBE .*)$/mg;
    is(scalar(@pl), 2, '79-27 PROBE: extmeta-probe 3,5 prints two lines');
    like($pl[0] // '', qr/^EXTMETA_PROBE n=3 http=200 .*entities=3 status_ok=2 status_other=1 status_absent=0 named=3 /,
        '79-27 PROBE: an entity with status_code 404 counts in status_other');
    like($pl[1] // '', qr/^EXTMETA_PROBE n=5 http=200 .*entities=5 /, '79-27 PROBE: the second size follows in order');
}
{
    my ($exit, $out) = run_tool({ FAKE_EXTMETA_NONAME => 1, FAKE_EXTMETA_NOHEADER => 1 }, '-', 'extmeta-probe', '4');
    like($out, qr/^EXTMETA_PROBE n=4 http=200 .*entities=4 status_ok=3 status_other=0 status_absent=1 named=3 /m,
        '79-27 PROBE: a nameless entity lowers named, a header-less entity counts in status_absent');
}
{
    my ($exit, $out, $req) = run_tool({ FAKE_EXTMETA_CODE => 400 }, '-', 'extmeta-probe', '3,5', 'product=0&country=DE');
    my @pl = $out =~ /^(EXTMETA_PROBE .*)$/mg;
    is(scalar(@pl), 1, '79-27 PROBE: the probe stops after the first size whose HTTP code is not 200');
    like($pl[0] // '', qr/^EXTMETA_PROBE n=3 http=400 bytes=0 entities=0 status_ok=0 status_other=0 status_absent=0 named=0 ms=\d+ query=product=0&country=DE$/,
        '79-27 PROBE: a refused size reports its code and the query form used');
    my ($pr) = with_url($req, qr{/extended-metadata/v0/extended-metadata\?product=0&country=DE$});
    ok($pr, '79-27 PROBE: the optional query string is appended to the path');
}
{
    for my $bad ('0', 'abc', '1001', '3,,5', '') {
        my ($exit, $out, $req) = run_tool({}, '-', 'extmeta-probe', $bad);
        ok($exit != 0 && $out =~ /usage/ && @$req == 0, "79-27 PROBE: bad size list '$bad' is a usage error before any network stage");
    }
    my ($exit, $out, $req) = run_tool({}, '-', 'extmeta-probe');
    ok($exit != 0 && $out =~ /usage/ && @$req == 0, '79-27 PROBE: a missing size list is a usage error before any network stage');
}

# ------------------------------------------------------------
# 8. T-85-01: no secret in any output line, none in argv, config files 0600 in a 0700 dir
# ------------------------------------------------------------
{
    my $all = join "\n", @ALL_OUTPUT;
    my @leaks = grep { index($all, $_) >= 0 } @SECRETS;
    is(scalar(@leaks), 0, 'no output line of any mode contains a fake secret');
    my @argvleaks = grep { my $r = $_; grep { index(join(' ', @{ $r->{argv} }), $_) >= 0 } @SECRETS } @ALL_REQ;
    is(scalar(@argvleaks), 0, 'no fake secret ever reaches a curl argv');
    my @badmode = grep { $_->{cfg_mode} ne '0600' || $_->{dir_mode} ne '0700' } @ALL_REQ;
    is(scalar(@badmode), 0, 'every curl config file is 0600 inside a 0700 directory');
}

done_testing();

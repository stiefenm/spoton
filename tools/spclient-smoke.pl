#!/usr/bin/perl

# tools/spclient-smoke.pl
#
# Standalone, LMS-free UAT vehicle for Phase 75 (D-08 spclient unification).
# Mints a login5 Bearer token from a librespot-format credentials.json (the
# same file ZeroConf/Keymaster/Soloist pairing produces) using ONLY
# Plugins::SpotOn::API::ProtobufLite and system curl -- no Slim::* modules,
# no running LMS process required. It then fetches one track's metadata via
# spclient's metadata/4 endpoint and the account's playlist rootlist via
# playlist/v2, proving the whole login5 + spclient chain end to end. This is
# the mandatory live-UAT vehicle referenced by 75-01..75-05's SUMMARY.md
# "Next Phase Readiness" sections (no paired Spotify account is reachable in
# the agent execution environment).
#
# Usage:
#   perl tools/spclient-smoke.pl /path/to/credentials.json [trackId]
#   perl tools/spclient-smoke.pl /path/to/credentials.json [trackId] profile
#
# Phase 85 (plan 85-02) adds probe modes for the 85-03 spike. Argument form:
# <credentials.json> <trackId|-> <mode> [mode args...]   ("-" = the default track).
# Every mode runs AFTER the existing login5 + metadata + rootlist stages and
# prints status codes, lengths, key names, counts and item names only:
#   perl tools/spclient-smoke.pl <credentials.json> <trackId|-> probe <path> [json|protobuf] [post <body-file> <content-type>]
#   perl tools/spclient-smoke.pl <credentials.json> <trackId|-> profile-keys
#   perl tools/spclient-smoke.pl <credentials.json> <trackId|-> rootlist-list
#   perl tools/spclient-smoke.pl <credentials.json> <trackId|-> playlist-find <exact name>
#   perl tools/spclient-smoke.pl <credentials.json> <trackId|-> playlist-read <playlistId>
#   perl tools/spclient-smoke.pl <credentials.json> <trackId|-> collection-roundtrip <set> <uri>
#   perl tools/spclient-smoke.pl <credentials.json> <trackId|-> playlist-append <playlistId> <uri>
#   perl tools/spclient-smoke.pl <credentials.json> <trackId|-> search-probe <query> [country] [locale]
#   perl tools/spclient-smoke.pl <credentials.json> <trackId|-> wpcid-probe
#   perl tools/spclient-smoke.pl <credentials.json> <trackId|-> pathfinder-ops
#   perl tools/spclient-smoke.pl <credentials.json> <trackId|-> pathfinder-query <operation> <variables-json-file> <wpcid>
#   perl tools/spclient-smoke.pl <credentials.json> <trackId|-> extmeta-probe <sizes> [query]
#
# extmeta-probe (79-27, D-18): the batch ceiling of spclient's extended-metadata endpoint. <sizes> is a comma list
# of integers 1..1000 (e.g. 50,100,200,500); [query] is an optional raw query string appended to the path (e.g.
# 'product=0&country=DE', the form the bundled daemon used). It resolves the account's liked-songs URI list
# (context-resolve/v1/spotify:user:<u>:collection), POSTs the first n track URIs of each size as one
# BatchedEntityRequest and prints ONE counts-only line per size:
#   EXTMETA_PROBE n=<n> http=<code> bytes=<b> entities=<e> status_ok=<k> status_other=<o> status_absent=<a> named=<m> ms=<t> query=<none|raw>
# It stops after the first size whose HTTP code is not 200. Never printed: names, URIs, the username, the bearer.
#
# The Pathfinder modes (wpcid-probe, pathfinder-ops, pathfinder-query) exist for the 85-03 spike only. Every
# secret they touch (the bearer, the client-token) stays in curl config files under a 0700 tempdir that is
# removed on exit. 85-15 (D-01, D-17): the cookie-based bearer variant of pathfinder-query was removed together
# with the cookie flow it mirrored; the only bearer left is the stored-credentials login5 one (wpcid).
#
# SPOTON_SMOKE_LOGIN5_DUMP=<path> (85-18, CR-01): writes the raw login5 reply of the main mint stage to
# <path> (mode 0600, never overwritten) so a real reply can be pinned as a test fixture. A reply that
# carries LoginOk (field 1, the bearer) is NEVER written: the tool prints "login5-dump: refused (reply
# carries LoginOk)" instead (T-85-56). Unset, the output is unchanged.
#
# trackId is an optional 22-char base62 Spotify track id (default: a
# well-known public track, "Cut To The Feeling" -- used throughout Spotify's
# own API documentation examples, so any account can resolve it).
#
# The optional third argument "profile" is additive (Phase 81, S-08): after
# the existing metadata+rootlist round-trip, it also fetches
# GET user-profile-view/v3/profile/{username} and prints only "name"/"uri"
# (values are not secrets) -- or "profile: HTTP <code>" on any non-2xx
# response. All other modes/behavior are unchanged.
#
# Security (T-75-19, Information Disclosure): the minted Bearer token and the
# decoded auth_data bytes are NEVER printed -- only token length and expiry
# are shown. Both the login5 request body and every curl invocation pass
# secrets via stdin/argv-free exec (IPC::Open3, list-form, no shell
# interpolation) so nothing sensitive ever appears in a process list or a
# shell history. credentials.json itself is expected to be a normal 0600
# local file (the same permissions librespot/SpotOn already write it with).

use strict;
use warnings;

use FindBin qw($RealBin);
use lib "$RealBin/..";

use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use MIME::Base64 qw(decode_base64);
use JSON::PP qw(decode_json);
use Digest::MD5 qw(md5_hex);
use Digest::SHA qw(sha1);              # Phase 85: HashCash for the Web-Player probes (core module)
use Time::HiRes ();                    # Phase 85: HashCash duration
use Math::BigInt;
use File::Temp qw(tempfile tempdir);
use Fcntl qw(O_WRONLY O_CREAT O_EXCL);

use Plugins::SpotOn::API::ProtobufLite;

# ------------------------------------------------------------
# Constants (mirrors Plugins::SpotOn::API::Login5 / SpClient field layout)
# ------------------------------------------------------------
use constant LIBRESPOT_CLIENT_ID     => '65b708073fc0480ea92a077233ca87bd';
use constant LOGIN5_URL              => 'https://login5.spotify.com/v3/login';
use constant APRESOLVE_URL           => 'https://apresolve.spotify.com/?type=spclient';
use constant SPCLIENT_FALLBACK_HOST  => 'gew4-spclient.spotify.com:443';
use constant ROOTLIST_DECORATE       => 'revision,attributes,length,owner,timestamp';
use constant ROOTLIST_MAX_DEPTH      => 10;
use constant BASE62_CHARSET          => '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
use constant DEFAULT_TRACK_ID        => '11dFghVXANMlKmJXsNCbNl';   # "Cut To The Feeling" -- Spotify's own docs example

# ------------------------------------------------------------
# fail($stage, $message) -- stage-labelled non-zero exit
# ------------------------------------------------------------
sub fail {
    my ($stage, $msg) = @_;
    print STDERR "FAIL [$stage]: $msg\n";
    exit 1;
}

# ------------------------------------------------------------
# _uriEscape($s) -- minimal percent-encoder (avoids a URI::Escape dependency
# for this standalone, LMS-free script)
# ------------------------------------------------------------
sub _uriEscape {
    my ($s) = @_;
    $s =~ s/([^A-Za-z0-9\-._~])/sprintf("%%%02X", ord($1))/ge;
    return $s;
}

# ------------------------------------------------------------
# idToHex($b62) -- base62 -> 32-hex-char gid (S-02, duplicated standalone
# from SpClient.pm::idToHex since that module has compile-time Slim::*
# dependencies this script must not load)
# ------------------------------------------------------------
sub idToHex {
    my ($b62) = @_;
    return undef unless defined $b62 && length($b62) == 22;
    return undef unless $b62 =~ /^[0-9A-Za-z]{22}$/;

    my $charset = BASE62_CHARSET;
    my $n = Math::BigInt->new(0);
    for my $c (split //, $b62) {
        my $idx = index($charset, $c);
        return undef if $idx < 0;
        $n = $n * 62 + $idx;
    }

    my $hex = $n->as_hex;
    $hex =~ s/^0x//;
    $hex = ('0' x (32 - length($hex))) . $hex if length($hex) < 32;
    return lc($hex);
}

# ------------------------------------------------------------
# curl helpers -- list-form exec via IPC::Open3 (never shell-interpolated).
# Headers (which carry the Bearer token) go through a 0600 temp curl -K
# config file rather than -H argv flags, so the token never appears in a
# `ps`/`/proc/<pid>/cmdline` snapshot either -- request bodies (auth_data)
# go via stdin (--data-binary @-) for the same reason (T-75-19).
# ------------------------------------------------------------
my $CFG_DIR;   # lazily created 0700 directory that holds every curl config file; removed on exit (T-85-01)

sub _writeCurlConfig {
    my (@headers) = @_;
    $CFG_DIR //= tempdir('spclient-smoke-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    chmod 0700, $CFG_DIR;
    my ($fh, $filename) = tempfile(DIR => $CFG_DIR, SUFFIX => '.curlcfg', UNLINK => 1);
    chmod 0600, $filename;
    for my $h (@headers) {
        (my $escaped = $h) =~ s/(["\\])/\\$1/g;
        print $fh qq{header = "$escaped"\n};
    }
    close $fh;
    return $filename;
}

sub _runCurl {
    my ($body, @cmd) = @_;
    my ($writeFh, $readFh, $errFh) = (gensym(), gensym(), gensym());
    my $pid = eval { open3($writeFh, $readFh, $errFh, @cmd) };
    return (-1, '', "open3 failed: $@") unless $pid;

    if (defined $body) {
        binmode $writeFh;
        print $writeFh $body;
    }
    close $writeFh;

    local $/;
    my $stdout = <$readFh> // '';
    my $stderr = <$errFh>  // '';
    close $readFh;
    close $errFh;
    waitpid($pid, 0);
    my $exit = $? >> 8;
    return ($exit, $stdout, $stderr);
}

sub curlPost {
    my ($url, $body, @headers) = @_;
    my $cfgFile = _writeCurlConfig(@headers);
    my @cmd = ('curl', '--silent', '--fail', '--show-error', '-K', $cfgFile, '--data-binary', '@-', $url);
    my @result = _runCurl($body, @cmd);
    unlink $cfgFile;
    return @result;
}

sub curlGet {
    my ($url, @headers) = @_;
    my $cfgFile = _writeCurlConfig(@headers);
    my @cmd = ('curl', '--silent', '--fail', '--show-error', '-K', $cfgFile, $url);
    my @result = _runCurl(undef, @cmd);
    unlink $cfgFile;
    return @result;
}

# ------------------------------------------------------------
# count_rootlist_playlists($responseBytes) -- counts playlist URIs in the
# rootlist response. The live server wraps items in field 5 (ListContent),
# with playlist URIs in field 5.3[].1.
# ------------------------------------------------------------
sub count_rootlist_playlists {
    my ($responseBytes) = @_;

    my $fields = Plugins::SpotOn::API::ProtobufLite::parse_fields($responseBytes);
    return 0 unless $fields;

    my $listBytes = Plugins::SpotOn::API::ProtobufLite::field_first($fields, 5);
    return 0 unless defined $listBytes;

    my $listFields = Plugins::SpotOn::API::ProtobufLite::parse_fields($listBytes);
    return 0 unless $listFields;

    my $count = 0;
    for my $itemBytes (@{ $listFields->{3} || [] }) {
        my $itemFields = Plugins::SpotOn::API::ProtobufLite::parse_fields($itemBytes);
        next unless $itemFields;
        my $uri = Plugins::SpotOn::API::ProtobufLite::field_first($itemFields, 1);
        $count++ if defined $uri && $uri =~ /^spotify:playlist:/;
    }
    return $count;
}

# ------------------------------------------------------------
# fetch_profile($host, $username, $accessToken) -- additive (Phase 81, S-08):
# GET user-profile-view/v3/profile/{username}, prints only name+uri (not
# secrets) or the HTTP status on any non-2xx response. Same list-form
# curl-via-temp-config pattern as the rest of the script (T-75-19): the
# Bearer header never touches argv, and this sub never prints the token.
# ------------------------------------------------------------
sub fetch_profile {
    my ($host, $username, $bearerToken) = @_;
    my $url = "https://$host/user-profile-view/v3/profile/" . _uriEscape($username);
    my $cfgFile = _writeCurlConfig("Authorization: Bearer $bearerToken");
    my @cmd = ('curl', '--silent', '--show-error', '-w', "\n%{http_code}", '-K', $cfgFile, $url);
    my ($exit, $stdout, $stderr) = _runCurl(undef, @cmd);
    unlink $cfgFile;
    if ($exit != 0) {
        print "profile: HTTP error ($stderr)\n";
        return;
    }
    my ($body, $httpCode) = $stdout =~ /^(.*)\n(\d+)\s*\z/s;
    if (!defined $httpCode || $httpCode !~ /^2/) {
        print "profile: HTTP " . ($httpCode // '?') . "\n";
        return;
    }
    my $parsed = eval { decode_json($body) };
    if ($@ || !$parsed) {
        print "profile: HTTP $httpCode (unparsable body)\n";
        return;
    }
    my $name = $parsed->{name} // '(unknown)';
    my $uri  = $parsed->{uri}  // '(unknown)';
    print "profile: name=$name uri=$uri\n";
}

# ============================================================
# Phase 85 plan 85-02: probe helpers for the 85-03 spike
# ============================================================
# Every helper below prints status codes, lengths, key names, counts and item
# names -- never a token, auth_data, client-token or cookie value (T-85-01).
# All HTTP goes through curlReq -> _runCurl with the headers (bearer, cookie,
# client-token) inside a curl -K config file, never argv.
use constant COLLECTION_V2_CONTENT_TYPE => 'application/vnd.collection-v2.spotify.proto';
use constant PROTOBUF_CONTENT_TYPE      => 'application/x-protobuf';
use constant ID22_RE                    => qr/\A[0-9A-Za-z]{22}\z/;
use constant URI_ITEM_RE                => qr/\Aspotify:(?:track|album|artist|show|episode):[0-9A-Za-z]{22}\z/;

sub _enc { return Plugins::SpotOn::API::ProtobufLite::encode_field(@_); }
sub _pf  { return Plugins::SpotOn::API::ProtobufLite::parse_fields(@_); }
sub _ff  { return Plugins::SpotOn::API::ProtobufLite::field_first(@_); }

# curlReq(%o) -- one HTTP exchange WITHOUT --fail, so the status code is always visible.
#   method (GET|POST|HEAD), url, headers => [...], body => bytes (POST)
# Returns ($httpCode, $responseBody, $curlExit, $curlStderr); httpCode is 0 when curl failed.
sub curlReq {
    my (%o) = @_;
    my $method  = $o{method} || 'GET';
    my $cfgFile = _writeCurlConfig(@{ $o{headers} || [] });
    my @cmd = ('curl', '--silent', '--show-error', '--max-time', '30', '-w', "\n%{http_code}", '-K', $cfgFile);
    push @cmd, '-I' if $method eq 'HEAD';
    push @cmd, '--data-binary', '@-' if defined $o{body};
    push @cmd, $o{url};
    my ($exit, $stdout, $stderr) = _runCurl($o{body}, @cmd);
    unlink $cfgFile;
    my ($body, $code) = ('', 0);
    ($body, $code) = ($1, $2 + 0) if $exit == 0 && $stdout =~ /\A(.*)\n(\d+)\s*\z/s;
    return ($code, $body, $exit, $stderr);
}

# spReq($ctx, %o) -- an authenticated spclient request. path has no leading slash.
sub spReq {
    my ($ctx, %o) = @_;
    my @h = ("Authorization: Bearer $ctx->{token}");
    push @h, "Accept: $o{accept}"             if $o{accept};
    push @h, "Content-Type: $o{content_type}" if $o{content_type};
    return curlReq(method => $o{method}, url => "https://$ctx->{host}/$o{path}", headers => \@h, body => $o{body});
}

# json_top_keys($body) -- sorted top-level keys of a JSON object, array[<n>] for an array, '-' otherwise
sub json_top_keys {
    my ($body) = @_;
    my $d = eval { decode_json($body) };
    return '-' if $@ || !defined $d;
    return (join(',', sort keys %$d) || '-') if ref $d eq 'HASH';
    return 'array[' . scalar(@$d) . ']'      if ref $d eq 'ARRAY';
    return '-';
}

# json_array_counts($data, $prefix, $out) -- [path, count] for every array reachable through hashes
# (at most 6 path segments deep); arrays are counted, not descended into.
sub json_array_counts {
    my ($data, $prefix, $out, $depth) = @_;
    $depth ||= 1;
    return unless ref $data eq 'HASH' && $depth <= 6;
    for my $k (sort keys %$data) {
        my $v = $data->{$k};
        my $p = defined $prefix && length $prefix ? "$prefix.$k" : $k;
        if    (ref $v eq 'ARRAY') { push @$out, [$p, scalar @$v]; }
        elsif (ref $v eq 'HASH')  { json_array_counts($v, $p, $out, $depth + 1); }
    }
}

# rootlist_entries($bytes) -- the playlists of a rootlist response (same layout as
# SpClient::_parseRootlist: items in 5.3, decorations in 5.4 paired by index). Folders are skipped.
sub rootlist_entries {
    my ($bytes) = @_;
    my $fields = _pf($bytes) or return ();
    my $listBytes = _ff($fields, 5);
    return () unless defined $listBytes;
    my $listFields = _pf($listBytes) or return ();
    my @items = @{ $listFields->{3} || [] };
    my @deco  = @{ $listFields->{4} || [] };
    my @out;
    for my $i (0 .. $#items) {
        my $it  = _pf($items[$i]) or next;
        my $uri = _ff($it, 1);
        next unless defined $uri && $uri =~ /^spotify:playlist:/;
        my $name = '';
        if ($i <= $#deco) {
            my $df = _pf($deco[$i]);
            if ($df && defined(my $attr = _ff($df, 2))) {
                my $af = _pf($attr);
                $name = _ff($af, 1) // '' if $af;
            }
        }
        push @out, { uri => $uri, name => $name };
    }
    return @out;
}

# probe($ctx, $path, [json|protobuf], [post, $bodyFile, $contentType])
sub probe {
    my ($ctx, @a) = @_;
    my $path = shift @a;
    $path =~ s{^/+}{};
    my $kind = (@a && $a[0] =~ /\A(?:json|protobuf)\z/) ? shift @a : 'json';
    my ($body, $ct);
    if (@a) {
        my (undef, $file, $type) = @a;
        open(my $bf, '<', $file) or fail('probe', "cannot open body file $file: $!");
        binmode $bf;
        $body = do { local $/; <$bf> };
        close $bf;
        $ct = $type;
    }
    my ($code, $resp) = spReq($ctx,
        method       => defined $body ? 'POST' : 'GET',
        path         => $path,
        accept       => $kind eq 'json' ? 'application/json' : PROTOBUF_CONTENT_TYPE,
        content_type => $ct,
        body         => $body,
    );
    print "probe $path HTTP $code bytes=" . length($resp) . ' keys=' . json_top_keys($resp) . "\n";
}

# profile_keys($ctx) -- D-05: which keys does the profile view carry, and is `name` the display name?
# Prints keys and array lengths only; the value of `name` is never printed.
sub profile_keys {
    my ($ctx) = @_;
    my ($code, $body) = spReq($ctx,
        path   => 'user-profile-view/v3/profile/' . _uriEscape($ctx->{username}) . '?playlist_limit=10&artist_limit=10',
        accept => 'application/json',
    );
    print "profile-keys HTTP $code bytes=" . length($body) . "\n";
    my $d = eval { decode_json($body) };
    unless (ref $d eq 'HASH') {
        print "keys: -\n";
        print "name_present=0 name_len=0\n";
        return;
    }
    print 'keys: ' . join(',', sort keys %$d) . "\n";
    for my $k (sort keys %$d) {
        print "array $k len=" . scalar(@{ $d->{$k} }) . "\n" if ref $d->{$k} eq 'ARRAY';
    }
    my $name = $d->{name};
    my $present = (defined $name && !ref $name && length $name) ? 1 : 0;
    print "name_present=$present name_len=" . ($present ? length($name) : 0) . "\n";
}

# rootlist_list($rootlistBytes) -- D-16a: how many playlists, how many are 37i9dQZ mixes, and their names
sub rootlist_list {
    my ($bytes) = @_;
    my @pl  = rootlist_entries($bytes);
    my @mix = grep { $_->{uri} =~ /^spotify:playlist:37i9dQZ/ } @pl;
    print 'rootlist_total=' . scalar(@pl) . ' mix_37i9=' . scalar(@mix) . "\n";
    print "mix: $_->{name}\n" for @mix;
}

# playlist_find($rootlistBytes, $exactName)
sub playlist_find {
    my ($bytes, $name) = @_;
    for my $p (rootlist_entries($bytes)) {
        if ($p->{name} eq $name) {
            print "found $p->{uri}\n";
            return;
        }
    }
    print "not_found\n";
}

# playlist_read($ctx, $id) -- D-16a: is the playlist readable via playlist/v2, as JSON and as protobuf?
sub playlist_read {
    my ($ctx, $id) = @_;
    for my $v (['json', 'application/json'], ['protobuf', PROTOBUF_CONTENT_TYPE]) {
        my ($code, $body) = spReq($ctx, path => "playlist/v2/playlist/$id", accept => $v->[1]);
        my $items = '-';
        if ($code =~ /^2/) {
            if ($v->[0] eq 'json') {
                my $d = eval { decode_json($body) };
                $items = scalar @{ $d->{contents}{items} }
                    if ref $d eq 'HASH' && ref $d->{contents} eq 'HASH' && ref $d->{contents}{items} eq 'ARRAY';
            }
            else {
                my $f  = _pf($body);
                my $lc = $f ? _pf(_ff($f, 5)) : undef;
                $items = scalar @{ $lc->{3} || [] } if $lc;
            }
        }
        print "playlist-read $v->[0] HTTP $code items=$items\n";
    }
}

# decode_contains($bytes) -- ContainsResponse{found=1 repeated bool}: packed (one length-delimited
# field of varint bytes) AND unpacked (repeated varints) are both accepted. undef = unparsable.
sub decode_contains {
    my ($bytes) = @_;
    return undef unless defined $bytes;
    my ($pos, $len, @found) = (0, length $bytes);
    my $varint = sub {
        my ($v, $shift) = (0, 0);
        while ($pos < $len) {
            my $b = ord(substr($bytes, $pos++, 1));
            $v |= ($b & 0x7f) << $shift;
            return $v unless $b & 0x80;
            $shift += 7;
            return undef if $shift > 63;
        }
        return undef;
    };
    while ($pos < $len) {
        my $tag = $varint->();
        return undef unless defined $tag;
        my ($field, $wire) = ($tag >> 3, $tag & 7);
        if ($wire == 0) {
            my $v = $varint->();
            return undef unless defined $v;
            push @found, ($v ? 1 : 0) if $field == 1;
        }
        elsif ($wire == 2) {
            my $l = $varint->();
            return undef unless defined $l && $pos + $l <= $len;
            if ($field == 1) {
                my $end = $pos + $l;
                while ($pos < $end) {
                    my $v = $varint->();
                    return undef unless defined $v;
                    push @found, ($v ? 1 : 0);
                }
            }
            else { $pos += $l; }
        }
        else { return undef; }
    }
    return \@found;
}

sub _collectionCall {
    my ($ctx, $which, $set, $item) = @_;
    my $body = _enc(1, 2, $ctx->{username}) . _enc(2, 2, $set) . _enc(3, 2, $item);
    return spReq($ctx,
        method       => 'POST',
        path         => "collection/v2/$which",
        accept       => COLLECTION_V2_CONTENT_TYPE,
        content_type => COLLECTION_V2_CONTENT_TYPE,
        body         => $body,
    );
}

# collection_contains($ctx, $set, $uri) -> ($httpCode, \@answers|undef)
sub collection_contains {
    my ($ctx, $set, $uri) = @_;
    my ($code, $resp) = _collectionCall($ctx, 'contains', $set, _enc(1, 2, $uri));
    return ($code, $code =~ /^2/ ? decode_contains($resp) : undef);
}

# collection_roundtrip($ctx, $set, $uri) -- D-14: contains -> add -> contains -> remove -> contains.
# Aborts BEFORE any write when the item is already present or the answer count is wrong, so the
# measurement account never carries residue. After a write was attempted the removal is always tried.
sub collection_roundtrip {
    my ($ctx, $set, $uri) = @_;

    my ($c0, $f0) = collection_contains($ctx, $set, $uri);
    if ($c0 !~ /^2/) {
        print "ABORT contains_http_$c0 (no write)\n";
        exit 4;
    }
    if (!$f0 || @$f0 != 1) {
        print 'ABORT contains_answer_count got=' . ($f0 ? scalar(@$f0) : 'unparsable') . " want=1\n";
        exit 4;
    }
    print "contains_before=$f0->[0]\n";
    if ($f0->[0]) {
        print "ABORT already_present (no write, no residue)\n";
        exit 3;
    }

    my $answer = sub {
        my ($code, $f) = collection_contains($ctx, $set, $uri);
        return ($f && @$f == 1) ? $f->[0] : '?';
    };

    my ($wa) = _collectionCall($ctx, 'write', $set, _enc(1, 2, $uri) . _enc(2, 0, time()));
    print "write_add=$wa\n";
    my $afterAdd = $answer->();
    print "contains_after_add=$afterAdd\n";

    if ($wa =~ /^2/ || $afterAdd eq '1' || $afterAdd eq '?') {
        my ($wr) = _collectionCall($ctx, 'write', $set, _enc(1, 2, $uri) . _enc(3, 0, 1));
        print "write_remove=$wr\n";
    }
    else {
        print "write_remove=skipped\n";
    }
    my $afterRemove = $answer->();
    print "contains_after_remove=$afterRemove\n";
    print 'roundtrip_residue=' . ($afterRemove eq '0' ? 0 : 1) . "\n";
}

# playlist_revision($ctx, $id) -> ($httpCode, $revisionBytes|undef) -- protobuf, no JSON Accept
sub playlist_revision {
    my ($ctx, $id) = @_;
    my ($code, $body) = spReq($ctx, path => "playlist/v2/playlist/$id?decorate=revision&from=0&length=1");
    return ($code, undef) unless $code =~ /^2/;
    my $f = _pf($body) or return ($code, undef);
    return ($code, _ff($f, 1));
}

# playlist_append($ctx, $id, $uri) -- D-14: revision GET, then ListChanges POST. 409 = revision moved:
# one re-read and one retry. 5xx / transport errors are NOT retried (non-idempotent).
sub playlist_append {
    my ($ctx, $id, $uri) = @_;

    my $post = sub {
        my ($revision) = @_;
        my $add   = _enc(2, 2, _enc(1, 2, $uri)) . _enc(4, 0, 1);              # Add{items=2{uri=1}, add_last=4}
        my $op    = _enc(1, 0, 2) . _enc(2, 2, $add);                          # Op{kind=1 ADD=2, add=2}
        my $info  = _enc(1, 2, $ctx->{username}) . _enc(2, 0, time() * 1000); # ChangeInfo{user=1, timestamp=2 ms}
        my $delta = _enc(2, 2, $op) . _enc(4, 2, $info);                       # Delta{ops=2, info=4}
        my $body  = _enc(1, 2, $revision) . _enc(2, 2, $delta);                # ListChanges{base_revision=1, deltas=2}
        my ($code) = spReq($ctx, method => 'POST', path => "playlist/v2/playlist/$id/changes",
            content_type => PROTOBUF_CONTENT_TYPE, body => $body);
        return $code;
    };

    my ($rc, $rev) = playlist_revision($ctx, $id);
    unless (defined $rev) {
        print "revision HTTP $rc revision_len=0\n";
        print "ABORT no_revision\n";
        exit 5;
    }
    my $code = $post->($rev);
    print 'revision_len=' . length($rev) . " changes=$code\n";

    if ($code == 409) {
        my ($rc2, $rev2) = playlist_revision($ctx, $id);
        unless (defined $rev2) {
            print "ABORT no_revision_on_retry\n";
            exit 5;
        }
        my $code2 = $post->($rev2);
        print 'revision_len=' . length($rev2) . " changes_retry=$code2\n";
    }
    elsif ($code == 0 || $code >= 500) {
        print "changes_not_retried (5xx and transport errors are non-idempotent)\n";
    }
}

# search_probe($ctx, $query, $country, $locale) -- RESEARCH 2.1 candidate (i), with and without platform=zelda
sub search_probe {
    my ($ctx, $query, $country, $locale) = @_;
    my $base = 'searchview/km/v4/search/' . _uriEscape($query)
        . '?entityVersion=2&limit=10&offset=0&catalogue=&country=' . _uriEscape($country)
        . '&locale=' . _uriEscape($locale);
    my $user = '&username=' . _uriEscape($ctx->{username});
    for my $v (['with_platform', "$base&platform=zelda$user"], ['without_platform', "$base$user"]) {
        my ($code, $body) = spReq($ctx, path => $v->[1], accept => 'application/json');
        print "search-probe $v->[0] HTTP $code bytes=" . length($body) . ' keys=' . json_top_keys($body) . "\n";
        my $d = eval { decode_json($body) };
        my @counts;
        json_array_counts($d, '', \@counts) if ref $d eq 'HASH';
        print "count $_->[0] $_->[1]\n" for @counts;
    }
}

# extmeta_probe($ctx, $sizes, [$query]) -- 79-27 D-18: how many entities does one extended-metadata call carry?
# The liked-songs URI list comes from context-resolve (the same path SpClient::_likedSongsUris reads); the request
# is the minimal BatchedEntityRequest of the research (no header): per entity
#   EntityRequest { entity_uri = 1; query = 2 { extension_kind = 1: TRACK_V4 (10) } }.
# The answer is decoded for COUNTS only: BatchedExtensionResponse.extended_metadata (2) -> EntityExtensionDataArray
# .extension_data (3) -> EntityExtensionData { header (1) { status_code (1) }, entity_uri (2), extension_data (3) Any
# { value (2) = Track { name (2) } } }.
sub extmeta_probe {
    my ($ctx, $sizes, $query) = @_;
    my @sizes = split /,/, $sizes;

    my ($ccode, $cbody) = spReq($ctx,
        path   => 'context-resolve/v1/spotify:user:' . _uriEscape($ctx->{username}) . ':collection',
        accept => 'application/json');
    fail('extmeta-probe', "liked-songs list HTTP $ccode") unless $ccode == 200;
    my $cd = eval { decode_json($cbody) };
    my @uris;
    if (ref $cd eq 'HASH' && ref $cd->{pages} eq 'ARRAY') {
        for my $page (@{ $cd->{pages} }) {
            next unless ref $page eq 'HASH' && ref $page->{tracks} eq 'ARRAY';
            push @uris, grep { defined $_ && !ref $_ && /\Aspotify:track:[0-9A-Za-z]{22}\z/ }
                        map  { ref $_ eq 'HASH' ? $_->{uri} : undef } @{ $page->{tracks} };
        }
    }
    my $qtext = defined $query && length $query ? $query : 'none';

    for my $n (@sizes) {
        if (@uris < $n) {
            print "EXTMETA_PROBE n=$n skipped=not_enough_liked_tracks have=" . scalar(@uris) . " query=$qtext\n";
            last;
        }
        my $body = join '', map {
            Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2,
                Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $_)
              . Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2,
                    Plugins::SpotOn::API::ProtobufLite::encode_field(1, 0, 10)))
        } @uris[0 .. $n - 1];

        my $t0 = Time::HiRes::time();
        my ($code, $resp) = spReq($ctx,
            method       => 'POST',
            path         => 'extended-metadata/v0/extended-metadata' . ($qtext eq 'none' ? '' : "?$query"),
            accept       => PROTOBUF_CONTENT_TYPE,
            content_type => PROTOBUF_CONTENT_TYPE,
            body         => $body,
        );
        my $ms = int((Time::HiRes::time() - $t0) * 1000);

        my ($entities, $ok, $other, $absent, $named) = (0, 0, 0, 0, 0);
        if ($code == 200) {
            my $top = _pf($resp);
            for my $arrBytes (@{ ($top && $top->{2}) || [] }) {
                my $arr = _pf($arrBytes) or next;
                for my $dataBytes (@{ $arr->{3} || [] }) {
                    my $e = _pf($dataBytes) or next;
                    $entities++;
                    my $hdr    = _pf(_ff($e, 1) // '');
                    my $status = $hdr ? _ff($hdr, 1) : undef;
                    if    (!defined $status)                  { $absent++ }
                    elsif ($status >= 200 && $status < 300)   { $ok++ }
                    else                                      { $other++ }
                    my $any   = _pf(_ff($e, 3) // '');
                    my $track = $any ? _pf(_ff($any, 2) // '') : undef;
                    my $name  = $track ? _ff($track, 2) : undef;
                    $named++ if defined $name && length $name;
                }
            }
        }
        print "EXTMETA_PROBE n=$n http=$code bytes=" . length($resp) . " entities=$entities status_ok=$ok"
            . " status_other=$other status_absent=$absent named=$named ms=$ms query=$qtext\n";
        last unless $code == 200;
    }
}

# check_mode_args($mode, @args) -- argument validation BEFORE any request is sent; returns an error text or undef
sub check_mode_args {
    my ($mode, @a) = @_;
    my %usage = (
        'probe'               => '<path> [json|protobuf] [post <body-file> <content-type>]',
        'profile-keys'        => '',
        'rootlist-list'       => '',
        'playlist-find'       => '<exact name>',
        'playlist-read'       => '<playlistId>',
        'collection-roundtrip'=> '<set> <uri>',
        'playlist-append'     => '<playlistId> <uri>',
        'search-probe'        => '<query> [country] [locale]',
        'wpcid-probe'         => '',
        'pathfinder-ops'      => '',
        'pathfinder-query'    => '<operation> <variables-json-file> <wpcid>',
        'extmeta-probe'       => '<sizes: comma list of 1..1000> [query]',
    );
    return undef if $mode eq '' || $mode eq 'profile';
    return "unknown mode '$mode'" unless exists $usage{$mode};
    my $u = "usage: <credentials.json> <trackId|-> $mode $usage{$mode}";
    if ($mode eq 'probe') {
        return $u unless @a;
        my @r = @a[1 .. $#a];
        shift @r if @r && $r[0] =~ /\A(?:json|protobuf)\z/;
        return $u if @r && !(@r == 3 && $r[0] eq 'post');
        return "probe: body file not readable: $r[1]" if @r && !-r $r[1];
    }
    elsif ($mode eq 'profile-keys' || $mode eq 'rootlist-list' || $mode eq 'wpcid-probe' || $mode eq 'pathfinder-ops') { return $u if @a; }
    elsif ($mode eq 'pathfinder-query') {
        return $u unless @a == 3 && $a[0] =~ /\A[A-Za-z][A-Za-z0-9_]*\z/ && $a[2] eq 'wpcid';
        return "pathfinder-query: variables file not readable: $a[1]" unless -r $a[1];
    }
    elsif ($mode eq 'playlist-find')    { return $u unless @a == 1 && length $a[0]; }
    elsif ($mode eq 'playlist-read')    { return $u unless @a == 1 && $a[0] =~ ID22_RE; }
    elsif ($mode eq 'collection-roundtrip') {
        return $u unless @a == 2 && $a[0] =~ /\A[A-Za-z0-9_-]+\z/ && $a[1] =~ URI_ITEM_RE;
    }
    elsif ($mode eq 'playlist-append') {
        return $u unless @a == 2 && $a[0] =~ ID22_RE && $a[1] =~ /\Aspotify:(?:track|episode):[0-9A-Za-z]{22}\z/;
    }
    elsif ($mode eq 'search-probe') { return $u unless @a >= 1 && @a <= 3 && length $a[0]; }
    elsif ($mode eq 'extmeta-probe') {
        return $u unless @a >= 1 && @a <= 2 && length $a[0];
        return "extmeta-probe: sizes must be a comma list of integers 1..1000: $a[0]\n$u"
            unless !grep { !/\A[1-9][0-9]{0,3}\z/ || $_ > 1000 } split(/,/, $a[0], -1);
        return "extmeta-probe: query must not be empty\n$u" if @a == 2 && !length $a[1];
    }
    return undef;
}

# ============================================================
# Phase 85 plan 85-02, task 2: Web-Player / Pathfinder probe helpers
# ============================================================
# These exist for the 85-03 spike only. Secrets (the
# login5/Web-Player bearer, the client-token) travel inside curl -K config
# files under a 0700 tempdir that is removed on exit -- never argv, never
# printed, never left in the environment curl inherits (T-85-01, T-85-41).
use constant WP_USER_AGENT => 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36';
use constant WP_OPEN_URL         => 'https://open.spotify.com/';
use constant WP_CLIENT_TOKEN_URL => 'https://clienttoken.spotify.com/v1/clienttoken';
use constant WP_CLIENT_VERSION   => '1.2.94.583.g60394bd5';   # as WebPlayer.pm CLIENT_VERSION
use constant PATHFINDER_URL      => 'https://api-partner.spotify.com/pathfinder/v2/query';
use constant MAX_BUNDLES         => 8;

# --- HashCash (login5 challenge) -------------------------------------------
# Field numbers and the algorithm come from librespot at the pinned commit
#   19959512c212cbc48a3ff64382fe204f52c659a7   (github.com/librespot-org/librespot)
#   core/src/login5.rs         handle_challenges(): the solution is a ChallengeSolution{hashcash=1}
#   core/src/util.rs           solve_hash_cash()
#   protocol/proto/spotify/login5/v3/login5.proto
#       LoginRequest{client_info=1, login_context=2, challenge_solutions=3, stored_credential=100}
#       LoginResponse{ok=1, error=2, challenges=3, login_context=5}
#       Challenges{challenges=1}, Challenge{hashcash=1, code=2}
#       ChallengeSolutions{solutions=1}, ChallengeSolution{hashcash=1, code=2}
#   protocol/proto/spotify/login5/v3/challenges/hashcash.proto
#       HashcashChallenge{prefix=1, length=2}, HashcashSolution{suffix=1, duration=2 (google.protobuf.Duration)}
# Algorithm: target = big-endian int64 of SHA1(login_context)[12..19]; for counter = 0, 1, ...:
#   suffix = be64(target + counter) || be64(counter)   (16 bytes, wrapping int64 addition)
#   accept when the trailing zero bits of the big-endian int64 SHA1(prefix || suffix)[12..19] >= length.
# BEGIN hashcash
# solve_hashcash($loginContext, $prefix, $length, $timeoutSeconds) -> ($suffix16, $counter) or undef at the deadline
sub solve_hashcash {
    my ($ctx, $prefix, $length, $timeout) = @_;
    $timeout = 5 unless defined $timeout;
    my $deadline = time() + $timeout;
    my $target   = unpack('q>', substr(sha1($ctx), 12, 8));
    my $counter  = 0;
    while (1) {
        return undef if $counter > 0 && ($counter & 0xFFFF) == 0 && time() >= $deadline;
        my $suffix = do { use integer; pack('q>', $target + $counter) } . pack('q>', $counter);
        my $v  = unpack('Q>', substr(sha1($prefix . $suffix), 12, 8));
        my $tz = 0;
        if ($v) { until ($v & 1) { $v >>= 1; $tz++; } }
        else    { $tz = 64; }
        return ($suffix, $counter) if $tz >= $length;
        $counter++;
    }
}
# END hashcash

sub _wpHeaders { return ('User-Agent: ' . WP_USER_AGENT); }

# scrape_web_player() -- cookie-free (RESEARCH 3.3c): GET open.spotify.com, then the web-player bundles it
# lists on open.spotifycdn.com. Returns { client_id, ops => {name => hash}, pairs => [[name,hash]..] }.
# Only (name, "query"|"mutation", 64-hex) triples count; only open.spotifycdn.com scripts are fetched.
# Known limit: bundles the page does not list (lazily loaded chunks) are not visited.
sub scrape_web_player {
    my ($code, $html) = curlReq(url => WP_OPEN_URL, headers => [_wpHeaders(), 'Accept: text/html']);
    my (@urls, %seen);
    while ($html =~ m{<script[^>]+src="(https://open\.spotifycdn\.com/[^"]+\.js)"}g) {
        push @urls, $1 unless $seen{$1}++;
        last if @urls >= MAX_BUNDLES;
    }
    print "scrape html HTTP $code bytes=" . length($html) . ' bundles=' . scalar(@urls) . "\n";
    my %r = (client_id => undef, ops => {}, pairs => []);
    if ($html =~ m{<script[^>]*id="appServerConfig"[^>]*>\s*([A-Za-z0-9+/=_-]+)\s*</script>}) {
        my $cfg = eval { decode_json(decode_base64($1)) };
        $r{client_id} = $cfg->{clientId}
            if ref $cfg eq 'HASH' && defined $cfg->{clientId} && $cfg->{clientId} =~ /\A[0-9a-f]{32}\z/;
    }
    my (%pairSeen, $i, %cidCount, @cidOrder);
    for my $u (@urls) {
        $i++;
        my ($bc, $js) = curlReq(url => $u, headers => [_wpHeaders()]);
        print "scrape bundle $i HTTP $bc bytes=" . length($js) . "\n";
        next unless $bc == 200;
        while ($js =~ /\("([A-Za-z][A-Za-z0-9_]*)","(?:query|mutation)","([0-9a-f]{64})"/g) {
            my ($name, $hash) = ($1, $2);
            next if $pairSeen{"$name|$hash"}++;
            push @{ $r{pairs} }, [$name, $hash];
            $r{ops}{$name} //= $hash;
        }
        # 85-03 live finding: the bundle carries more than one clientId literal (a different service's id came
        # first; the Web-Player id is the one that occurs most often) -- count, do not take the first.
        while ($js =~ /client[Ii][Dd]:"([0-9a-f]{32})"/g) {
            push @cidOrder, $1 unless $cidCount{$1};
            $cidCount{$1}++;
        }
    }
    unless (defined $r{client_id}) {
        my $best;
        for my $c (@cidOrder) { $best = $c if !defined $best || $cidCount{$c} > $cidCount{$best}; }   # ties: first seen
        $r{client_id} = $best if defined $best;
    }
    return \%r;
}

# wp_client_token($clientId) -- anonymous client-token, request body as WebPlayer.pm::_clientToken -> ($code, $token|undef)
sub wp_client_token {
    my ($clientId) = @_;
    my $body = JSON::PP->new->canonical->encode({ client_data => {
        client_version => WP_CLIENT_VERSION,
        client_id      => $clientId,
        js_sdk_data    => { device_brand => '', device_id => '', device_model => '', device_type => '', os => '', os_version => '' },
    } });
    my ($code, $resp) = curlReq(method => 'POST', url => WP_CLIENT_TOKEN_URL, body => $body,
        headers => ['Content-Type: application/json', 'Accept: application/json']);
    my $d = eval { decode_json($resp) };
    my $tok = (ref $d eq 'HASH' && ref $d->{granted_token} eq 'HASH') ? $d->{granted_token}{token} : undef;
    return ($code, (defined $tok && length $tok) ? $tok : undef);
}

# wp_login5($ctx, $clientId, $clientToken) -- login5 with the Web-Player client id and the stored credentials.
# A HashCash challenge is solved and the request resent (at most 3 rounds, as librespot).
# -> { token | error, hashcash => 0|1 }
sub wp_login5 {
    my ($ctx, $clientId, $clientToken) = @_;
    my $clientInfo = _enc(1, 2, $clientId) . _enc(2, 2, $ctx->{device_id});
    my $stored     = _enc(1, 2, $ctx->{username}) . _enc(2, 2, $ctx->{auth_data});
    my ($loginContext, $solutions);
    my $hashcash = 0;
    for my $round (1 .. 3) {
        my $body = _enc(1, 2, $clientInfo);
        $body .= _enc(2, 2, $loginContext) if defined $loginContext;
        $body .= _enc(3, 2, $solutions)    if defined $solutions;
        $body .= _enc(100, 2, $stored);
        my ($code, $resp) = curlReq(method => 'POST', url => LOGIN5_URL, body => $body, headers => [
            'Content-Type: application/x-protobuf', 'Accept: application/x-protobuf', "client-token: $clientToken",
        ]);
        return { error => "http_$code", hashcash => $hashcash } unless $code == 200;
        my $f = _pf($resp) or return { error => 'unparsable', hashcash => $hashcash };
        if (defined(my $okBytes = _ff($f, 1))) {
            my $ok  = _pf($okBytes);
            my $tok = $ok ? _ff($ok, 2) : undef;
            return (defined $tok && length $tok)
                ? { token => $tok, hashcash => $hashcash }
                : { error => 'no_access_token', hashcash => $hashcash };
        }
        if (defined(my $err = _ff($f, 2))) { return { error => $err, hashcash => $hashcash }; }
        my $chBytes = _ff($f, 3);
        return { error => 'no_response', hashcash => $hashcash } unless defined $chBytes;

        $loginContext = _ff($f, 5);
        $loginContext = '' unless defined $loginContext;
        my $chs = _pf($chBytes) or return { error => 'unparsable_challenge', hashcash => $hashcash };
        my @solutions;
        for my $cb (@{ $chs->{1} || [] }) {
            my $c = _pf($cb) or next;
            return { error => 'code_challenge', hashcash => $hashcash } if defined _ff($c, 2);
            my $hb = _ff($c, 1);
            my $h  = defined $hb ? _pf($hb) : undef;
            next unless $h;
            $hashcash = 1;
            my $t0 = Time::HiRes::time();
            my ($suffix) = solve_hashcash($loginContext, _ff($h, 1) // '', _ff($h, 2) // 0, 5);
            return { error => 'hashcash_timeout', hashcash => 1 } unless defined $suffix;
            my $took  = Time::HiRes::time() - $t0;
            my ($sec, $nanos) = (int($took), int(($took - int($took)) * 1e9));
            my $duration = ($sec ? _enc(1, 0, $sec) : '') . ($nanos ? _enc(2, 0, $nanos) : '');
            push @solutions, _enc(1, 2, _enc(1, 2, _enc(1, 2, $suffix) . _enc(2, 2, $duration)));
        }
        return { error => 'empty_challenge', hashcash => $hashcash } unless @solutions;
        $solutions = join '', @solutions;
    }
    return { error => 'retries_failed', hashcash => $hashcash };
}

# wp_bearer_wpcid($ctx, $scrape) -- steps 2-3 of the WP-CID chain (step 1 is the scrape the caller printed)
sub wp_bearer_wpcid {
    my ($ctx, $scrape) = @_;
    my $cid = $scrape->{client_id};
    unless (defined $cid) {
        print "step2 client_token skipped no_client_id\n";
        return;
    }
    my ($cc, $ct) = wp_client_token($cid);
    print "step2 client_token HTTP $cc len=" . length($ct // '') . "\n";
    return unless defined $ct;
    my $r = wp_login5($ctx, $cid, $ct);
    print 'step3 login5 ' . (defined $r->{token} ? 'ok' : "error=$r->{error}")
        . " hashcash=$r->{hashcash} token_len=" . length($r->{token} // '') . "\n";
    return unless defined $r->{token};
    return ($r->{token}, $ct);
}

# pathfinder_post($operation, $hash, \%variables, $bearer, $clientToken) -> ($code, $body)
sub pathfinder_post {
    my ($op, $hash, $vars, $bearer, $clientToken) = @_;
    my $body = JSON::PP->new->canonical->encode({
        operationName => $op,
        variables     => $vars,
        extensions    => { persistedQuery => { version => 1, sha256Hash => $hash } },
    });
    return curlReq(method => 'POST', url => PATHFINDER_URL, body => $body, headers => [
        "Authorization: Bearer $bearer", "client-token: $clientToken",
        'Content-Type: application/json;charset=UTF-8', 'Accept: application/json', 'App-Platform: WebPlayer', _wpHeaders(),
    ]);
}

# collect_names($data, \@out, $max) -- up to $max values of keys called `name`, depth first in sorted key order
sub collect_names {
    my ($d, $out, $max) = @_;
    return if @$out >= $max;
    if (ref $d eq 'HASH') {
        for my $k (sort keys %$d) {
            if ($k eq 'name' && defined $d->{$k} && !ref $d->{$k} && length $d->{$k}) {
                (my $n = $d->{$k}) =~ s/[\r\n]+/ /g;
                push @$out, substr($n, 0, 80);
                return if @$out >= $max;
            }
            collect_names($d->{$k}, $out, $max);
        }
    }
    elsif (ref $d eq 'ARRAY') { collect_names($_, $out, $max) for @$d; }
}

# print_query_result($code, $body) -- status, errors flag, data keys, array sizes, a few names. No values beyond item names.
sub print_query_result {
    my ($code, $body) = @_;
    my $d = eval { decode_json($body) };
    my $hasErrors = (ref $d eq 'HASH' && ref $d->{errors} eq 'ARRAY' && @{ $d->{errors} }) ? 1 : 0;
    my $errors    = ($hasErrors || $code !~ /^2/) ? 1 : 0;
    my $data      = (ref $d eq 'HASH' && ref $d->{data} eq 'HASH') ? $d->{data} : undef;
    print "query HTTP $code errors=$errors data_keys=" . ($data ? (join(',', sort keys %$data) || '-') : '-') . "\n";
    print "query errors=1 persisted_query_not_found=1\n" if $body =~ /PersistedQueryNotFound/;
    return unless $data;
    my @counts;
    json_array_counts($data, 'data', \@counts);
    print "items $_->[0] $_->[1]\n" for @counts;
    my @names;
    collect_names($data, \@names, 5);
    print "name: $_\n" for @names;
}

# pathfinder_ops() -- every (operation, hash) pair the page's bundles carry, cookie-free
sub pathfinder_ops {
    my $sc = scrape_web_player();
    my @pairs = sort { $a->[0] cmp $b->[0] || $a->[1] cmp $b->[1] } @{ $sc->{pairs} };
    print "op $_->[0] $_->[1]\n" for @pairs;
    for my $must (qw(home fetchPlaylistContents searchDesktop)) {
        print "op_missing $must\n" unless $sc->{ops}{$must};
    }
    print 'ops_total=' . scalar(@pairs) . "\n";
}

# wpcid_probe($ctx) -- D-16b: does the Web-Player client id log in with the stored credentials and reach Pathfinder?
sub wpcid_probe {
    my ($ctx) = @_;
    my $sc = scrape_web_player();
    print 'step1 client_id_len=' . length($sc->{client_id} // '') . ' home_hash=' . ($sc->{ops}{home} // 'none') . "\n";
    my ($bearer, $ct) = wp_bearer_wpcid($ctx, $sc);
    return unless defined $bearer;
    unless ($sc->{ops}{home}) {
        print "step4 home skipped no_home_hash\n";
        return;
    }
    my ($code, $body) = pathfinder_post('home', $sc->{ops}{home}, {
        homeEndUserIntegration => 'INTEGRATION_WEB_PLAYER', timeZone => 'Europe/Berlin', sp_t => '', facet => '',
        sectionItemsLimit => 10, includeEpisodeContentRatingsV2 => JSON::PP::true,
    }, $bearer, $ct);
    my $d = eval { decode_json($body) };
    my $errors = ((ref $d eq 'HASH' && ref $d->{errors} eq 'ARRAY' && @{ $d->{errors} }) || $code !~ /^2/) ? 1 : 0;
    print "step4 home HTTP $code errors=$errors\n";
}

# pathfinder_query($ctx, $operation, $variablesFile, 'wpcid') -- one Pathfinder operation with the login5 bearer
sub pathfinder_query {
    my ($ctx, $op, $varsFile, $kind) = @_;
    open(my $vf, '<', $varsFile) or fail('pathfinder-query', "cannot open $varsFile: $!");
    my $vraw = do { local $/; <$vf> };
    close $vf;
    my $vars = eval { decode_json($vraw) };
    fail('pathfinder-query', "variables file is not a JSON object: $@") unless ref $vars eq 'HASH';

    my $sc = scrape_web_player();
    my $hash = $sc->{ops}{$op};
    unless ($hash) {
        print "ABORT op_not_in_bundle\n";
        exit 7;
    }
    my ($bearer, $ct) = wp_bearer_wpcid($ctx, $sc);
    unless (defined $bearer) {
        print "ABORT no_bearer\n";
        exit 8;
    }
    my ($code, $body) = pathfinder_post($op, $hash, $vars, $bearer, $ct);
    print_query_result($code, $body);
}

# LoginError names, duplicated from Plugins::SpotOn::API::Login5 (this tool stays LMS-free):
# librespot login5.proto at 19959512.
my %LOGIN_ERROR_NAME = (
    0 => 'UNKNOWN_ERROR',
    1 => 'INVALID_CREDENTIALS',
    2 => 'BAD_REQUEST',
    3 => 'UNSUPPORTED_LOGIN_PROTOCOL',
    4 => 'TIMEOUT',
    5 => 'UNKNOWN_IDENTIFIER',
    6 => 'TOO_MANY_ATTEMPTS',
    7 => 'INVALID_PHONENUMBER',
    8 => 'TRY_AGAIN_LATER',
);

# ============================================================
# main
# ============================================================

my $credsPath = shift @ARGV
    or fail('args', 'usage: perl tools/spclient-smoke.pl /path/to/credentials.json [trackId]');
my $trackId = shift @ARGV || DEFAULT_TRACK_ID;
$trackId = DEFAULT_TRACK_ID if $trackId eq '-';   # Phase 85: "-" keeps the default track when a mode follows
my $mode = shift @ARGV || '';   # additive (S-08): 'profile' fetches user-profile-view/v3/profile/{username}
my @modeArgs = @ARGV;
if (defined(my $argErr = check_mode_args($mode, @modeArgs))) {
    fail('args', $argErr);   # before any request: a mistyped mode must not cost a login5 mint
}

# ---- Stage: creds ----
open(my $credsFh, '<', $credsPath) or fail('creds', "cannot open $credsPath: $!");
my $credsRaw = do { local $/; <$credsFh> };
close($credsFh);

my $creds = eval { decode_json($credsRaw) };
fail('creds', "cannot parse $credsPath as JSON: $@") if $@;
fail('creds', 'missing "username" field in credentials.json') unless $creds->{username};
fail('creds', 'missing "auth_data" field in credentials.json') unless $creds->{auth_data};

my $username      = $creds->{username};
my $authDataBytes = eval { decode_base64($creds->{auth_data}) };
fail('creds', 'failed to base64-decode auth_data') unless defined $authDataBytes && length $authDataBytes;

print "creds: loaded (username=" . substr($username, 0, 3) . "****)\n";

# ---- Stage: mint (login5 LoginRequest, mirrors Login5.pm's field layout) ----
my $deviceId = md5_hex("spoton-smoke-$username");

my $clientInfo = Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, LIBRESPOT_CLIENT_ID)
    . Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, $deviceId);
my $storedCred = Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $username)
    . Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, $authDataBytes);
my $loginBody = Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2, $clientInfo)
    . Plugins::SpotOn::API::ProtobufLite::encode_field(100, 2, $storedCred);

my ($mintExit, $loginResp, $mintErr) = curlPost(LOGIN5_URL, $loginBody,
    'Content-Type: application/x-protobuf',
    'Accept: application/x-protobuf',
);
fail('mint', "curl exited $mintExit: $mintErr") if $mintExit != 0;

my $loginFields = Plugins::SpotOn::API::ProtobufLite::parse_fields($loginResp);
fail('mint', 'failed to parse login5 response as protobuf') unless $loginFields;

# SPOTON_SMOKE_LOGIN5_DUMP (85-18): keep the raw login5 reply bytes for a test fixture. Runs
# before the error/challenge checks, so an error reply is captured.
if (defined $ENV{SPOTON_SMOKE_LOGIN5_DUMP} && length $ENV{SPOTON_SMOKE_LOGIN5_DUMP}) {
    my $dumpPath = $ENV{SPOTON_SMOKE_LOGIN5_DUMP};
    if (exists $loginFields->{1}) {
        print "login5-dump: refused (reply carries LoginOk)\n";
    }
    elsif (-e $dumpPath || -l $dumpPath) {
        print "login5-dump: refused (target exists)\n";
    }
    elsif (sysopen(my $dumpFh, $dumpPath, O_WRONLY | O_CREAT | O_EXCL, 0600)) {
        binmode($dumpFh);
        print {$dumpFh} $loginResp;
        close($dumpFh);
        chmod 0600, $dumpPath;
        print 'login5-dump: wrote ' . length($loginResp) . " bytes\n";
    }
    else {
        print "login5-dump: refused (cannot create target)\n";
    }
}

# LoginResponse{ ok=1, error=2, challenges=3, login_context=5 } -- librespot login5.proto at
# 19959512 (see the layout comment above the HashCash helpers). The same layout as Login5.pm.
my $errorCode = Plugins::SpotOn::API::ProtobufLite::field_first($loginFields, 2);
if (defined $errorCode) {
    fail('mint', 'login5 returned a malformed error field') unless $errorCode =~ /\A[0-9]{1,10}\z/;
    fail('mint', "login5 returned error code $errorCode (" . ($LOGIN_ERROR_NAME{$errorCode + 0} // 'UNRECOGNIZED') . ')')
        if $errorCode != 0;
}

fail('mint', 'login5 returned a HashCash challenge -- the librespot Client ID is expected to be challenge-free')
    if defined Plugins::SpotOn::API::ProtobufLite::field_first($loginFields, 3);

my $loginOkBytes = Plugins::SpotOn::API::ProtobufLite::field_first($loginFields, 1);
fail('mint', 'no LoginOk payload in login5 response') unless defined $loginOkBytes;

my $loginOk = Plugins::SpotOn::API::ProtobufLite::parse_fields($loginOkBytes);
fail('mint', 'failed to parse LoginOk payload') unless $loginOk;

my $accessToken = Plugins::SpotOn::API::ProtobufLite::field_first($loginOk, 2);
my $expiresIn   = Plugins::SpotOn::API::ProtobufLite::field_first($loginOk, 4);
fail('mint', 'no access_token in LoginOk payload') unless defined $accessToken && length $accessToken;

# T-75-19: token value is NEVER printed -- length and expiry only.
print "mint: OK (token length=" . length($accessToken) . ", expires_in=" . ($expiresIn // '?') . "s)\n";

# ---- Stage: apresolve (nearest spclient host) ----
my ($apExit, $apResp, $apErr) = curlGet(APRESOLVE_URL);
my $host = SPCLIENT_FALLBACK_HOST;
if ($apExit == 0 && $apResp) {
    my $parsed = eval { decode_json($apResp) };
    if (!$@ && $parsed && ref($parsed) eq 'HASH'
        && ref($parsed->{spclient}) eq 'ARRAY' && @{ $parsed->{spclient} })
    {
        $host = $parsed->{spclient}[0];
    }
}
print "apresolve: using host $host\n";

# ---- Stage: metadata (GET metadata/4/track/{hex}) ----
my $hexId = idToHex($trackId);
fail('metadata', "invalid track id (not 22-char base62): $trackId") unless $hexId;

my ($metaExit, $metaResp, $metaErr) = curlGet(
    "https://$host/metadata/4/track/$hexId",
    "Authorization: Bearer $accessToken",
    'Accept: application/json',
);
fail('metadata', "curl exited $metaExit: $metaErr") if $metaExit != 0;

my $track = eval { decode_json($metaResp) };
fail('metadata', "failed to parse track JSON: $@") if $@;

my $trackName    = $track->{name} // '(unknown)';
my @artistNames  = map { $_->{name} // '(unknown)' } @{ $track->{artist} || [] };
print "metadata: track=\"$trackName\" artists=\"" . join(', ', @artistNames) . "\"\n";

# ---- Stage: rootlist (GET playlist/v2/user/{username}/rootlist) ----
my $rootlistUrl = "https://$host/playlist/v2/user/" . _uriEscape($username)
    . '/rootlist?decorate=' . ROOTLIST_DECORATE;

my ($rootExit, $rootResp, $rootErr) = curlGet($rootlistUrl,
    "Authorization: Bearer $accessToken",
);
fail('rootlist', "curl exited $rootExit: $rootErr") if $rootExit != 0;

my $playlistCount = count_rootlist_playlists($rootResp);
fail('rootlist', 'failed to parse rootlist protobuf response (no items in field 5)') if $playlistCount == 0 && length($rootResp) > 100;

print "rootlist: playlist count=$playlistCount\n";

# ---- Stage: profile (additive, S-08) ----
if ($mode eq 'profile') {
    fetch_profile($host, $username, $accessToken);
}

# ---- Stages: Phase 85 probe modes (85-03 spike) ----
my $ctx = { host => $host, token => $accessToken, username => $username, auth_data => $authDataBytes, device_id => $deviceId };

if ($mode eq 'probe')                { probe($ctx, @modeArgs); }
if ($mode eq 'profile-keys')         { profile_keys($ctx); }
if ($mode eq 'rootlist-list')        { rootlist_list($rootResp); }
if ($mode eq 'playlist-find')        { playlist_find($rootResp, $modeArgs[0]); }
if ($mode eq 'playlist-read')        { playlist_read($ctx, $modeArgs[0]); }
if ($mode eq 'collection-roundtrip') { collection_roundtrip($ctx, @modeArgs); }
if ($mode eq 'playlist-append')      { playlist_append($ctx, @modeArgs); }
if ($mode eq 'search-probe')         { search_probe($ctx, $modeArgs[0], $modeArgs[1] // 'US', $modeArgs[2] // 'en'); }
if ($mode eq 'wpcid-probe')          { wpcid_probe($ctx); }
if ($mode eq 'pathfinder-ops')       { pathfinder_ops(); }
if ($mode eq 'pathfinder-query')     { pathfinder_query($ctx, @modeArgs); }
if ($mode eq 'extmeta-probe')         { extmeta_probe($ctx, @modeArgs); }

print "OK: login5 + spclient round-trip succeeded end to end.\n";
exit 0;

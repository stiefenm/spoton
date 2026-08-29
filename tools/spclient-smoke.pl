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
#
# trackId is an optional 22-char base62 Spotify track id (default: a
# well-known public track, "Cut To The Feeling" -- used throughout Spotify's
# own API documentation examples, so any account can resolve it).
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
use Math::BigInt;
use File::Temp qw(tempfile);

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
sub _writeCurlConfig {
    my (@headers) = @_;
    my ($fh, $filename) = tempfile(SUFFIX => '.curlcfg', UNLINK => 1);
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

# ============================================================
# main
# ============================================================

my $credsPath = shift @ARGV
    or fail('args', 'usage: perl tools/spclient-smoke.pl /path/to/credentials.json [trackId]');
my $trackId = shift @ARGV || DEFAULT_TRACK_ID;

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

my $errorCode = Plugins::SpotOn::API::ProtobufLite::field_first($loginFields, 3);
fail('mint', "login5 returned error code $errorCode") if defined $errorCode && $errorCode != 0;

fail('mint', 'login5 returned a HashCash challenge -- the librespot Client ID is expected to be challenge-free')
    if defined Plugins::SpotOn::API::ProtobufLite::field_first($loginFields, 2);

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

print "OK: login5 + spclient round-trip succeeded end to end.\n";
exit 0;

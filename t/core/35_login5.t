#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use MIME::Base64 qw(encode_base64);

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
our @errors = ();   # every error line of every logger (WR-02 masking check)
sub logger { return bless { _calls => [] }, 'Slim::Utils::Log' }
sub info     { push @{$_[0]->{_calls}}, ['info',  $_[1]] }
sub warn     { push @{$_[0]->{_calls}}, ['warn',  $_[1]] }
sub error    { push @{$_[0]->{_calls}}, ['error', $_[1]]; push @errors, $_[1] if defined $_[1] }
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

# 85-06: Login5.pm arms the health tick through Slim::Utils::Timers.
write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
sub setTimer   { }
sub killTimers { }
1;
END

# ============================================================
# Stub: Slim::Networking::SimpleAsyncHTTP -- captures POST args, response
# content controlled via $auto_response_content, dispatch mode controllable
# per-test via $auto_mode ('success' | 'none').
# ============================================================
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;

our @requests = ();
our $auto_mode = 'success';   # 'success' | 'none'
our $auto_response_content = '';

sub new {
    my ($class, $success_cb, $error_cb, $opts) = @_;
    return bless { success_cb => $success_cb, error_cb => $error_cb, opts => $opts || {} }, $class;
}

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

    if ($auto_mode eq 'success') {
        my $resp = bless { _content => $auto_response_content, _code => 200 },
            'Slim::Networking::SimpleAsyncHTTP::Response';
        $self->{success_cb}->($resp);
    }
    # 'none': no callback fired -- test drives it manually via @requests
}

sub reset_requests { @requests = (); $auto_mode = 'success'; $auto_response_content = '' }

package Slim::Networking::SimpleAsyncHTTP::Response;
sub content { $_[0]->{_content} }
sub code    { $_[0]->{_code} }
1;
END

# ============================================================
# Stub: Plugins::SpotOn::API::Credentials -- controllable verifyCredentials
# ============================================================
write_stub($stub_dir, 'Plugins::SpotOn::API::Credentials', <<'END');
package Plugins::SpotOn::API::Credentials;
our $mock_creds = { username => 'testuser', auth_data => 'dGVzdGRhdGE=' };
our $die_on_verify = 0;   # WR-02: makes the credential check die (message carries the account id and a file path)
sub verifyCredentials {
    my ($class, $accountId) = @_;
    die "credential check blew up for $accountId at /cache/spoton/$accountId/credentials.json\n" if $die_on_verify;
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

# ProtobufLite is the real (non-stubbed) module -- pure Perl, zero LMS deps.
require_ok('Plugins::SpotOn::API::ProtobufLite')
    or BAIL_OUT('Failed to load ProtobufLite.pm');
*encode_field = \&Plugins::SpotOn::API::ProtobufLite::encode_field;

require_ok('Plugins::SpotOn::API::Login5')
    or BAIL_OUT('Failed to load Login5.pm');

my $L5 = 'Plugins::SpotOn::API::Login5';

sub reset_all {
    Slim::Networking::SimpleAsyncHTTP::reset_requests();
    Slim::Utils::Cache->new()->clear();
    $L5->reset();
    $Plugins::SpotOn::API::Credentials::mock_creds = { username => 'testuser', auth_data => 'dGVzdGRhdGE=' };
    $Plugins::SpotOn::API::Credentials::die_on_verify = 0;
    @Slim::Utils::Log::errors = ();
}

# ------------------------------------------------------------
# Helper: build a synthetic login5 LoginOk response.
# ------------------------------------------------------------
sub build_login_ok_response {
    my (%args) = @_;
    my $username    = $args{username}    // 'testuser';
    my $accessToken = $args{accessToken} // ('a' x 438);
    my $expiresIn   = $args{expiresIn}   // 3600;
    my $padding     = $args{padding}     // ('p' x 300);

    # LoginOk: username=1, access_token=2, expires_in=4(varint); plus an
    # unrelated large field (99) purely to push total response size past
    # ~700 bytes, matching the spike's real-world observation and forcing
    # the OUTER field-1 length to require a multi-byte varint (S-01).
    my $loginOk = encode_field(1, 2, $username)
        . encode_field(2, 2, $accessToken)
        . encode_field(4, 0, $expiresIn)
        . encode_field(99, 2, $padding);

    return encode_field(1, 2, $loginOk);
}

# ============================================================
# Test 1: S-01 regression -- multi-byte varint length, 438-char token
# ============================================================
{
    reset_all();

    my $response = build_login_ok_response(accessToken => ('a' x 438), expiresIn => 3600);
    ok(length($response) > 700, 'S-01 fixture: synthetic response exceeds 700 bytes (realistic size)');

    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = $response;

    my ($token, $err);
    $L5->getToken('acct-s01', sub { ($token, $err) = @_ });

    is($err, undef, 'S-01: no error on a well-formed multi-byte-varint response');
    is(length($token // ''), 438, 'S-01: full 438-char token delivered, not truncated to 31 chars');
}

# ============================================================
# Test 2: LoginError INVALID_CREDENTIALS (response field 2 = 1) -> invalid_credentials
# ============================================================
{
    reset_all();

    # LoginResponse{ ok=1, error=2, challenges=3, login_context=5 } (librespot
    # login5.proto, commit 19959512): INVALID_CREDENTIALS = error (field 2) = 1.
    my $errorResponse = encode_field(2, 0, 1);
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = $errorResponse;

    my ($token, $err);
    $L5->getToken('acct-err', sub { ($token, $err) = @_ });

    is($token, undef, 'error-field test: no token on error response');
    is($err, 'invalid_credentials', 'LoginError INVALID_CREDENTIALS (response field 2 = 1) maps to invalid_credentials reason');
}

# ============================================================
# Test 3: no stored credentials -> no_credentials, no HTTP call
# ============================================================
{
    reset_all();
    $Plugins::SpotOn::API::Credentials::mock_creds = undef;

    my ($token, $err);
    $L5->getToken('acct-nocreds', sub { ($token, $err) = @_ });

    is($token, undef, 'no-credentials test: no token');
    is($err, 'no_credentials', 'missing stored credentials maps to no_credentials reason');
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, 'no-credentials test: zero HTTP calls made');
}

# ============================================================
# Test 4: coalescing -- two concurrent getToken calls, one HTTP POST
# ============================================================
{
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'none';   # don't auto-fire; drive manually

    my (@results);
    $L5->getToken('acct-coalesce', sub { push @results, [@_] });
    $L5->getToken('acct-coalesce', sub { push @results, [@_] });

    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 1,
        'coalescing: two concurrent getToken calls trigger exactly one HTTP POST');

    # Manually fire the single in-flight request's success callback.
    my $response = build_login_ok_response(accessToken => ('b' x 50), expiresIn => 1800);
    my $entry = $Slim::Networking::SimpleAsyncHTTP::requests[0];
    my $resp = bless { _content => $response, _code => 200 }, 'Slim::Networking::SimpleAsyncHTTP::Response';
    $entry->{success_cb}->($resp);

    is(scalar(@results), 2, 'coalescing: both queued callbacks were resolved');
    is($results[0][0], 'b' x 50, 'coalescing: first callback received the minted token');
    is($results[1][0], 'b' x 50, 'coalescing: second callback received the same minted token');

    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
}

# ============================================================
# Test 5: request-body assertion -- field-1 tag + field-100 tag bytes
# ============================================================
{
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content =
        build_login_ok_response(accessToken => 'z' x 40, expiresIn => 3600);

    $L5->getToken('acct-body', sub { });

    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 1, 'body test: one HTTP POST made');
    my $body = $Slim::Networking::SimpleAsyncHTTP::requests[0]->{body};

    is(substr($body, 0, 1), "\x0A", 'request body starts with field-1 (ClientInfo) tag byte 0x0A');
    ok(index($body, "\xA2\x06") >= 0,
        'request body contains field-100 (StoredCredential) tag bytes 0xA2 0x06 (100<<3|2)');

    my $req = $Slim::Networking::SimpleAsyncHTTP::requests[0];
    is($req->{headers}{'Content-Type'}, 'application/x-protobuf', 'Content-Type header is application/x-protobuf');
    is($req->{url}, 'https://login5.spotify.com/v3/login', 'POST goes to login5.spotify.com/v3/login');
}

# ============================================================
# CR-01 (85-18): full LoginError classification, robust parsing
# ============================================================
# LoginResponse{ ok=1, error=2, challenges=3, login_context=5 }, LoginError
# UNKNOWN_ERROR=0 INVALID_CREDENTIALS=1 BAD_REQUEST=2 UNSUPPORTED_LOGIN_PROTOCOL=3
# TIMEOUT=4 UNKNOWN_IDENTIFIER=5 TOO_MANY_ATTEMPTS=6 INVALID_PHONENUMBER=7
# TRY_AGAIN_LATER=8 (librespot login5.proto, commit 19959512).
sub login5_answer {
    my ($bytes) = @_;
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = $bytes;
    my (@warns, @res);
    {
        local $SIG{__WARN__} = sub { push @warns, @_ };
        $L5->getToken('acct-cr01', sub { @res = @_ });
    }
    return { token => $res[0], reason => $res[1], detail => $res[2], warns => \@warns };
}

for my $row (
    [ 0, 'UNKNOWN_ERROR',              'mint_failed' ],
    [ 1, 'INVALID_CREDENTIALS',        'invalid_credentials' ],
    [ 2, 'BAD_REQUEST',                'mint_failed' ],
    [ 3, 'UNSUPPORTED_LOGIN_PROTOCOL', 'mint_failed' ],
    [ 4, 'TIMEOUT',                    'mint_failed' ],
    [ 5, 'UNKNOWN_IDENTIFIER',         'invalid_credentials' ],
    [ 6, 'TOO_MANY_ATTEMPTS',          'mint_failed' ],
    [ 7, 'INVALID_PHONENUMBER',        'mint_failed' ],
    [ 8, 'TRY_AGAIN_LATER',            'mint_failed' ],
    [ 9, 'unknown code 9',             'mint_failed' ],
) {
    my ($code, $name, $want) = @$row;
    my $r = login5_answer(encode_field(2, 0, $code));
    # WR-18: the throttle answers (4, 6, 8) carry { throttled => 1 } (never
    # transient); every other LoginError resolves without a detail.
    my $throttle = ($code == 4 || $code == 6 || $code == 8);
    my $detail_ok = $throttle
        ? (ref($r->{detail}) eq 'HASH' && $r->{detail}{throttled} && !$r->{detail}{transient})
        : !defined $r->{detail};
    ok(!defined $r->{token} && ($r->{reason} // '') eq $want && $detail_ok,
        "CR-01: LoginError $code ($name) resolves $want with no transient detail");
}

{
    my $r = login5_answer(encode_field(2, 0, 2));
    isnt($r->{reason}, 'invalid_credentials', 'CR-01: BAD_REQUEST (field 2 = 2) is NOT invalid_credentials');
    is($r->{reason}, 'mint_failed', 'CR-01: BAD_REQUEST (field 2 = 2) is plain mint_failed');
}

{
    # The pre-fix invented shape: error as top-level field 3 varint 2.
    my $r = login5_answer(encode_field(3, 0, 2));
    isnt($r->{reason}, 'invalid_credentials', 'CR-01: the invented shape (field 3 as varint 2) is NOT invalid_credentials');
}

{
    # Challenges{Challenge{hashcash{prefix,length}}} (field 3) + login_context (field 5),
    # the shape t/core/64 builds for the HashCash fake.
    my $chal = encode_field(1, 2, encode_field(1, 2, encode_field(1, 2, pack('H*', '0a0b0c0d0e0f1011')) . encode_field(2, 0, 12)));
    my $r = login5_answer(encode_field(3, 2, $chal) . encode_field(5, 2, 'CTX-FOR-HASHCASH'));
    ok(!defined $r->{token} && ($r->{reason} // '') eq 'mint_failed' && !defined $r->{detail},
        'CR-01: a Challenges reply (field 3 + login_context 5) is mint_failed');
    is(scalar(@{ $r->{warns} }), 0, 'CR-01: a Challenges reply emits no Perl warning');
}

{
    # A length-delimited field 2 where a varint belongs: malformed, no numeric compare.
    my $r = login5_answer(encode_field(2, 2, "\xffbad"));
    ok(!defined $r->{token} && ($r->{reason} // '') eq 'mint_failed' && !defined $r->{detail},
        'CR-01: a length-delimited (non-varint) field 2 is mint_failed');
    is(scalar(@{ $r->{warns} }), 0, 'CR-01: a length-delimited (non-varint) field 2 emits no Perl warning');
}

{
    # A reply login5.spotify.com actually sent (85-18, Task 3): the smoke tool (SPOTON_SMOKE_LOGIN5_DUMP)
    # posted ONE login request with the librespot client id, the account's username and RANDOM auth_data
    # (the real credential was never sent). Capture directory:
    # spoton-messdaten/85-18-capture-261017-215357/out/ (outcome.txt, login5-reply.bin).
    my $L5_CAPTURED_REPLY = pack('H*', '1001');
    my $r = login5_answer($L5_CAPTURED_REPLY);
    ok(!defined $r->{token} && ($r->{reason} // '') eq 'invalid_credentials' && !defined $r->{detail},
        'CR-01 captured: the genuine login5 reply (LoginResponse.error = INVALID_CREDENTIALS) resolves invalid_credentials');
    is(unpack('H*', $L5_CAPTURED_REPLY), unpack('H*', encode_field(2, 0, 1)),
        'CR-01 captured: the genuine reply equals the constructed INVALID_CREDENTIALS fixture byte for byte');
    is(scalar(@{ $r->{warns} }), 0, 'CR-01 captured: the genuine reply emits no Perl warning');
}

# ============================================================
# WR-02: a die inside the credential check must not leak the in-flight slot
# ============================================================
{
    reset_all();
    my $acct = 'wr02acctid1234567890';
    $Plugins::SpotOn::API::Credentials::die_on_verify = 1;

    my @cb;
    my $ok = eval { $L5->getToken($acct, sub { push @cb, [@_] }); 1 };
    ok($ok, 'WR-02: getToken does not die when the credential check dies')
        or diag("died: $@");
    is(scalar(@cb), 1, 'WR-02: the callback runs exactly once after a dying credential check');
    ok(@cb && !defined $cb[0][0] && ($cb[0][1] // '') eq 'mint_failed',
        'WR-02: a dying credential check resolves (undef, mint_failed)');
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0,
        'WR-02: a dying credential check sends no login5 POST');
    my @die_lines = grep { /credential check died/ } @Slim::Utils::Log::errors;
    ok(scalar(@die_lines) == 1 && $die_lines[0] !~ /\Q$acct\E/ && $die_lines[0] =~ /wr02\*\*\*\*/,
        'WR-02: the die is logged once, with only the masked account id (T-75-01)')
        or diag("error lines: " . join(' | ', @Slim::Utils::Log::errors));

    # The slot must be free: with the check healthy again, the next mint sends a POST.
    $Plugins::SpotOn::API::Credentials::die_on_verify = 0;
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content =
        build_login_ok_response(accessToken => 'w' x 40, expiresIn => 3600);
    my @cb2;
    eval { $L5->getToken($acct, sub { push @cb2, [@_] }); 1 };
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 1,
        'WR-02: the mint after a dying credential check sends exactly one POST (slot released)');
    ok(@cb2 == 1 && ($cb2[0][0] // '') eq 'w' x 40,
        'WR-02: the mint after a dying credential check delivers the token');
}

# ============================================================
# CID constant + no-hardcoded-TTL source assertions
# ============================================================
{
    my $module_src = do {
        local $/;
        open(my $fh, '<', "$project_dir/Plugins/SpotOn/API/Login5.pm") or die $!;
        <$fh>;
    };
    like($module_src, qr/65b708073fc0480ea92a077233ca87bd/, 'librespot CID constant present in source');
    like($module_src, qr/\$expiresIn\s*-\s*TOKEN_TTL_BUFFER/, 'cache TTL is computed from the parsed expires_in field');
    unlike($module_src, qr/3600\s*\)\s*;\s*#?\s*$/m, 'no bare literal-3600 TTL expression');
}


# ============================================================
# 79-43 (D-33 FULL-3 WR-02): the username is sent as UTF-8 bytes, the authData byte-exact
# ============================================================
{
    reset_all();
    require MIME::Base64;
    my $user = "j\x{fc}rgen";
    utf8::upgrade($user);   # JSON-decoded credentials are character strings
    my $auth = "\x80\xff\x00\xc3\x10\xfe";
    $Plugins::SpotOn::API::Credentials::mock_creds = { username => $user, auth_data => MIME::Base64::encode_base64($auth, '') };
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content =
        build_login_ok_response(accessToken => 'z' x 40, expiresIn => 3600);
    $L5->getToken('acct-l1', sub { });
    my $body = ($Slim::Networking::SimpleAsyncHTTP::requests[0] || {})->{body};
    ok(defined $body && !utf8::is_utf8($body), '79-43 L1 (D-33 FULL-3 WR-02): the login5 body is a byte string');
    my $top = defined $body ? Plugins::SpotOn::API::ProtobufLite::parse_fields($body) : undef;
    my $sc  = $top ? Plugins::SpotOn::API::ProtobufLite::parse_fields(Plugins::SpotOn::API::ProtobufLite::field_first($top, 100) // '') : undef;
    is(unpack('H*', ($sc ? Plugins::SpotOn::API::ProtobufLite::field_first($sc, 1) : '') // ''), unpack('H*', "j\xc3\xbcrgen"),
        '79-43 L1: StoredCredential.username is "j\x{fc}rgen" as UTF-8 bytes');
    is(unpack('H*', ($sc ? Plugins::SpotOn::API::ProtobufLite::field_first($sc, 2) : '') // ''), unpack('H*', $auth),
        '79-43 L1: StoredCredential.data is the authData byte-exact (0x80..0xFF untouched)');
}

done_testing();

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
# Test 2: error field 3 = 2 -> invalid_credentials
# ============================================================
{
    reset_all();

    my $errorResponse = encode_field(3, 0, 2);   # top-level error code 2 = INVALID_CREDENTIALS
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = $errorResponse;

    my ($token, $err);
    $L5->getToken('acct-err', sub { ($token, $err) = @_ });

    is($token, undef, 'error-field test: no token on error response');
    is($err, 'invalid_credentials', 'error field 3=2 maps to invalid_credentials reason');
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

done_testing();

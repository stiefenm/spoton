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
# Unlike t/core/36, responders may branch on method + body and may answer
# with a status code (409, 500) or a transport failure, because the library
# writes need: revision GET, then POST /changes, then a 409 retry.
#   add_rule($method|undef, qr/url/, $responder)
#   $responder: scalar (200 body) | ARRAY (sequence, sticks on the last) |
#               CODE ($body, $method, $url) -> scalar | { code => N, content => '..' }
#   code 0 = transport failure
# ============================================================
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;

our @requests = ();
our @rules    = ();

sub add_rule {
    my ($method, $pattern, $responder) = @_;
    unshift @rules, [ $method, $pattern, $responder ];
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
    $body = pop @rest if @rest % 2 == 1;
    my %headers = @rest;

    push @requests, { method => $method, url => $url, headers => \%headers, body => $body };

    if ($url =~ /apresolve\.spotify\.com/) {
        my $resp = bless { _content => '{"spclient":["test-spclient.example.com:443"]}', _code => 200 },
            'Slim::Networking::SimpleAsyncHTTP::Response';
        $self->{success_cb}->($resp);
        return;
    }

    my $answer = '';
    for my $rule (@rules) {
        next if defined $rule->[0] && $rule->[0] ne $method;
        next unless $url =~ $rule->[1];
        my $r = $rule->[2];
        if    (ref($r) eq 'ARRAY') { $answer = (@$r > 1) ? shift(@$r) : $r->[0]; }
        elsif (ref($r) eq 'CODE')  { $answer = $r->($body, $method, $url); }
        else                       { $answer = $r; }
        last;
    }

    my ($code, $content) = (200, $answer);
    if (ref($answer) eq 'HASH') {
        $code    = $answer->{code};
        $content = $answer->{content} // '';
    }

    if ($code == 0) {
        my $resp = bless { _code => 0, _headers => {} }, 'Slim::Networking::SimpleAsyncHTTP::MockResponse';
        $self->{error_cb}->($self, 'transport failure', $resp);
    }
    elsif ($code >= 400) {
        my $resp = bless { _code => $code, _headers => {} }, 'Slim::Networking::SimpleAsyncHTTP::MockResponse';
        $self->{error_cb}->($self, "$code forced error", $resp);
    }
    else {
        my $resp = bless { _content => $content, _code => $code }, 'Slim::Networking::SimpleAsyncHTTP::Response';
        $self->{success_cb}->($resp);
    }
}

sub reset_requests {
    @requests = ();
    @rules    = ();
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

write_stub($stub_dir, 'Plugins::SpotOn::API::Login5', <<'END');
package Plugins::SpotOn::API::Login5;
sub getToken { my ($class, $accountId, $cb) = @_; $cb->('mock_login5_bearer_token', undef); }
1;
END

# Client.pm must NEVER be reached by a library write (D-14): every method call
# is recorded; a call answers with an error so a delegating implementation
# fails visibly instead of passing silently.
write_stub($stub_dir, 'Plugins::SpotOn::API::Client', <<'END');
package Plugins::SpotOn::API::Client;
our @calls = ();
our $AUTOLOAD;
sub AUTOLOAD {
    my $class = shift;
    my $name = $AUTOLOAD; $name =~ s/.*:://;
    return if $name eq 'DESTROY';
    push @calls, $name;
    my $cb = (ref($_[-1]) eq 'CODE') ? $_[-1] : undef;
    $cb->(undef, { error => 'client_stub_reached' }) if $cb;
    return;
}
sub reset_calls { @calls = () }
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
    *main::ISWINDOWS   = sub () { 0 };
    *main::ISMAC       = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
}

BEGIN {
    package Plugins::SpotOn::Plugin;
    use constant SPOTON_CACHE_VERSION => 4;
}

unshift @INC, $stub_dir, $project_dir;

require_ok('Plugins::SpotOn::API::Client')      or BAIL_OUT('Failed to load Client stub');
require_ok('Plugins::SpotOn::API::Credentials') or BAIL_OUT('Failed to load Credentials stub');
require_ok('Plugins::SpotOn::API::SpClient')    or BAIL_OUT('Failed to load SpClient.pm');

my $SP = 'Plugins::SpotOn::API::SpClient';
my $PB = 'Plugins::SpotOn::API::ProtobufLite';
my $VENDOR = 'application/vnd.collection-v2.spotify.proto';

sub reset_all {
    Slim::Networking::SimpleAsyncHTTP::reset_requests();
    Slim::Utils::Cache->new()->clear();
    $SP->reset();
    Plugins::SpotOn::API::Client::reset_calls();
    $Plugins::SpotOn::API::Credentials::mock_creds = { username => 'testuser', auth_data => 'ZGF0YQ==' };
}

sub reqs   { Slim::Networking::SimpleAsyncHTTP::non_apresolve_requests() }
sub pf     { Plugins::SpotOn::API::ProtobufLite::parse_fields($_[0]) }
sub ff     { Plugins::SpotOn::API::ProtobufLite::field_first($_[0], $_[1]) }
sub enc    { Plugins::SpotOn::API::ProtobufLite::encode_field(@_) }
sub rule   { Slim::Networking::SimpleAsyncHTTP::add_rule(@_) }

# ContainsResponse fixtures: packed (normal proto3 wire form, measured in the
# 85-03 D14 spike: "0a 01 00") and unpacked repeated varints.
sub contains_packed   { enc(1, 2, join('', map { chr($_ ? 1 : 0) } @_)) }
sub contains_unpacked { join('', map { enc(1, 0, $_ ? 1 : 0) } @_) }

# ============================================================
# Task 1: tracks over collection/v2 -- write (add)
# ============================================================
{
    reset_all();
    rule('POST', qr{/collection/v2/write}, '');

    my ($res, $err, $called) = ('unset', 'unset', 0);
    $SP->saveTracks('acct1', ['spotify:track:AAAAAAAAAAAAAAAAAAAAAA'], sub { ($res, $err) = @_; $called++ });

    my @r = reqs();
    is(scalar(@r), 1, 'saveTracks: exactly one HTTP request');
    like($r[0]{url} // '', qr{/collection/v2/write$}, 'saveTracks: POST goes to collection/v2/write');
    is($r[0]{method}, 'POST', 'saveTracks: method is POST');
    is($r[0]{headers}{'Content-Type'}, $VENDOR, 'saveTracks: Content-Type is the collection-v2 vendor string');
    is($r[0]{headers}{'Accept'},       $VENDOR, 'saveTracks: Accept is the collection-v2 vendor string');

    my $f = pf($r[0]{body});
    ok($f, 'saveTracks: request body parses as protobuf');
    is(ff($f, 1), 'testuser', 'saveTracks: field 1 is the credentials username');
    is(ff($f, 2), 'collection', 'saveTracks: field 2 is the set "collection"');
    my $item = pf(ff($f, 3));
    is(ff($item, 1), 'spotify:track:AAAAAAAAAAAAAAAAAAAAAA', 'saveTracks: item field 1 is the track uri');
    ok(ff($item, 2) && ff($item, 2) > 1_000_000_000, 'saveTracks: item field 2 (added_at) is a unix-second varint');
    ok(!defined ff($item, 3), 'saveTracks: item carries no is_removed flag');

    is($called, 1, 'saveTracks: callback invoked exactly once');
    ok(!defined $res && !defined $err, 'saveTracks: empty 200 body is success -> cb(undef, undef)');
    is(scalar(@Plugins::SpotOn::API::Client::calls), 0, 'saveTracks: Client.pm never called');
}

# ============================================================
# Task 1: removeTracks
# ============================================================
{
    reset_all();
    rule('POST', qr{/collection/v2/write}, '');

    my ($res, $err) = ('unset', 'unset');
    $SP->removeTracks('acct2', ['spotify:track:BBBBBBBBBBBBBBBBBBBBBB'], sub { ($res, $err) = @_ });

    my @r = reqs();
    is(scalar(@r), 1, 'removeTracks: exactly one HTTP request');
    my $f = pf($r[0]{body});
    my $item = pf(ff($f, 3));
    is(ff($f, 2), 'collection', 'removeTracks: set is "collection"');
    is(ff($item, 1), 'spotify:track:BBBBBBBBBBBBBBBBBBBBBB', 'removeTracks: item field 1 is the track uri');
    is(ff($item, 3), 1, 'removeTracks: item field 3 (is_removed) is varint 1');
    ok(!defined ff($item, 2), 'removeTracks: item carries no added_at');
    ok(!defined $res && !defined $err, 'removeTracks: empty 200 body is success -> cb(undef, undef)');
    is(scalar(@Plugins::SpotOn::API::Client::calls), 0, 'removeTracks: Client.pm never called');
}

# ============================================================
# Task 1: HTTP 500 -> error to cb, no Client.pm fallback
# ============================================================
{
    reset_all();
    rule('POST', qr{/collection/v2/write}, { code => 500 });

    my ($res, $err, $called) = ('unset', 'unset', 0);
    $SP->saveTracks('acct3', ['spotify:track:AAAAAAAAAAAAAAAAAAAAAA'], sub { ($res, $err) = @_; $called++ });

    is(scalar(reqs()), 1, 'write 500: exactly one request (no retry)');
    ok(!defined $res, 'write 500: result undef');
    is(ref($err) eq 'HASH' ? $err->{code} : undef, 500, 'write 500: error carries code 500');
    is($called, 1, 'write 500: callback invoked exactly once');
    is(scalar(@Plugins::SpotOn::API::Client::calls), 0, 'write 500: Client.pm never called');
}

# ============================================================
# Task 1: no credentials -> no_credentials, no HTTP
# ============================================================
{
    reset_all();
    $Plugins::SpotOn::API::Credentials::mock_creds = undef;

    my ($res, $err) = ('unset', 'unset');
    $SP->saveTracks('acct4', ['spotify:track:AAAAAAAAAAAAAAAAAAAAAA'], sub { ($res, $err) = @_ });
    is(ref($err) eq 'HASH' ? $err->{error} : undef, 'no_credentials', 'saveTracks without credentials: error no_credentials');
    is(scalar(reqs()), 0, 'saveTracks without credentials: no HTTP request');

    ($res, $err) = ('unset', 'unset');
    $SP->checkTracks('acct4', ['spotify:track:AAAAAAAAAAAAAAAAAAAAAA'], sub { ($res, $err) = @_ });
    is(ref($err) eq 'HASH' ? $err->{error} : undef, 'no_credentials', 'checkTracks without credentials: error no_credentials');
    is(scalar(@Plugins::SpotOn::API::Client::calls), 0, 'no credentials: Client.pm never called');
}

# ============================================================
# Task 1: checkTracks over collection/v2/contains
# ============================================================
{
    reset_all();
    rule('POST', qr{/collection/v2/contains}, contains_packed(1, 0));

    my ($res, $err);
    $SP->checkTracks('acct5', ['spotify:track:AAAAAAAAAAAAAAAAAAAAAA', 'spotify:track:BBBBBBBBBBBBBBBBBBBBBB'],
        sub { ($res, $err) = @_ });

    my @r = reqs();
    is(scalar(@r), 1, 'checkTracks: exactly one HTTP request');
    like($r[0]{url} // '', qr{/collection/v2/contains$}, 'checkTracks: POST goes to collection/v2/contains');
    is($r[0]{headers}{'Content-Type'}, $VENDOR, 'checkTracks: Content-Type is the vendor string');
    my $f = pf($r[0]{body});
    is(ff($f, 1), 'testuser', 'checkTracks: field 1 is the credentials username');
    is(ff($f, 2), 'collection', 'checkTracks: field 2 is the set "collection"');
    is_deeply([ map { ff(pf($_), 1) } @{ $f->{3} || [] } ],
        ['spotify:track:AAAAAAAAAAAAAAAAAAAAAA', 'spotify:track:BBBBBBBBBBBBBBBBBBBBBB'],
        'checkTracks: field 3 repeats one item per uri, in order');
    is_deeply($res, [1, 0], 'checkTracks: packed found bytes decode to [1,0]');
    ok(!$err, 'checkTracks: no error');
    is(scalar(@Plugins::SpotOn::API::Client::calls), 0, 'checkTracks: Client.pm never called');
}

# unpacked repeated varints decode the same
{
    reset_all();
    rule('POST', qr{/collection/v2/contains}, contains_unpacked(0, 1));
    my ($res, $err);
    $SP->checkTracks('acct6', ['spotify:track:AAAAAAAAAAAAAAAAAAAAAA', 'spotify:track:BBBBBBBBBBBBBBBBBBBBBB'],
        sub { ($res, $err) = @_ });
    is_deeply($res, [0, 1], 'checkTracks: unpacked repeated varints decode to [0,1]');
}

# answer count != request count -> parse_error; garbage never dies
{
    reset_all();
    rule('POST', qr{/collection/v2/contains}, contains_packed(1));
    my ($res, $err) = ('unset', 'unset');
    $SP->checkTracks('acct7', ['spotify:track:AAAAAAAAAAAAAAAAAAAAAA', 'spotify:track:BBBBBBBBBBBBBBBBBBBBBB'],
        sub { ($res, $err) = @_ });
    ok(!defined $res, 'checkTracks count mismatch: result undef');
    is(ref($err) eq 'HASH' ? $err->{error} : undef, 'parse_error', 'checkTracks count mismatch: error parse_error');

    reset_all();
    rule('POST', qr{/collection/v2/contains}, "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01");
    ($res, $err) = ('unset', 'unset');
    my $lived = eval {
        $SP->checkTracks('acct7', ['spotify:track:AAAAAAAAAAAAAAAAAAAAAA'], sub { ($res, $err) = @_ });
        1;
    };
    ok($lived, 'checkTracks malformed bytes: does not die');
    is(ref($err) eq 'HASH' ? $err->{error} : undef, 'parse_error', 'checkTracks malformed bytes: error parse_error');
}

# direct decoder contract
{
    is_deeply(Plugins::SpotOn::API::SpClient::_decodeContains(contains_packed(1, 0), 2), [1, 0], '_decodeContains: packed [1,0]');
    is(Plugins::SpotOn::API::SpClient::_decodeContains(contains_packed(1, 0), 3), undef, '_decodeContains: wrong expected count -> undef');
    is(Plugins::SpotOn::API::SpClient::_decodeContains(undef, 1), undef, '_decodeContains: undef input -> undef');
}

# ============================================================
# Task 1: write invalidates the Liked Songs list cache
# ============================================================
{
    reset_all();
    rule('POST', qr{/collection/v2/write}, '');
    my $rawCache = Slim::Utils::Cache->new();

    $rawCache->set('spoton_spclient_liked_acct8', ['x'], 60);
    $SP->saveTracks('acct8', ['spotify:track:AAAAAAAAAAAAAAAAAAAAAA'], sub { });
    ok(!$rawCache->get('spoton_spclient_liked_acct8'), 'saveTracks: removes spoton_spclient_liked_<acct>');

    $rawCache->set('spoton_spclient_liked_acct8', ['x'], 60);
    $SP->removeTracks('acct8', ['spotify:track:AAAAAAAAAAAAAAAAAAAAAA'], sub { });
    ok(!$rawCache->get('spoton_spclient_liked_acct8'), 'removeTracks: removes spoton_spclient_liked_<acct>');
}

# ============================================================
# Task 2: shows over collection/v2 (set "show")
# ============================================================
{
    reset_all();
    rule('POST', qr{/collection/v2/write}, '');
    my $rawCache = Slim::Utils::Cache->new();
    $rawCache->set('spoton_spclient_coll_acct10_show', ['x'], 60);

    my ($res, $err) = ('unset', 'unset');
    $SP->saveShows('acct10', ['spotify:show:4rOoJ6Egrf8K2IrywzwOMk'], sub { ($res, $err) = @_ });

    my @r = reqs();
    is(scalar(@r), 1, 'saveShows: exactly one HTTP request');
    like($r[0]{url} // '', qr{/collection/v2/write$}, 'saveShows: POST goes to collection/v2/write');
    my $f = pf($r[0]{body});
    is(ff($f, 2), 'show', 'saveShows: set is "show"');
    my $item = pf(ff($f, 3));
    is(ff($item, 1), 'spotify:show:4rOoJ6Egrf8K2IrywzwOMk', 'saveShows: item uri is the show uri');
    ok(ff($item, 2), 'saveShows: item carries added_at');
    ok(!defined $res && !defined $err, 'saveShows: empty 200 body is success');
    ok(!$rawCache->get('spoton_spclient_coll_acct10_show'), 'saveShows: removes spoton_spclient_coll_<acct>_show');

    reset_all();
    rule('POST', qr{/collection/v2/write}, '');
    $rawCache->set('spoton_spclient_coll_acct10_show', ['x'], 60);
    $SP->removeShows('acct10', ['spotify:show:4rOoJ6Egrf8K2IrywzwOMk'], sub { ($res, $err) = @_ });
    @r = reqs();
    $f = pf($r[0]{body});
    $item = pf(ff($f, 3));
    is(ff($f, 2), 'show', 'removeShows: set is "show"');
    is(ff($item, 3), 1, 'removeShows: item is_removed is varint 1');
    ok(!defined ff($item, 2), 'removeShows: item carries no added_at');
    ok(!$rawCache->get('spoton_spclient_coll_acct10_show'), 'removeShows: removes spoton_spclient_coll_<acct>_show');

    reset_all();
    rule('POST', qr{/collection/v2/contains}, contains_packed(1));
    $SP->checkShows('acct10', ['spotify:show:4rOoJ6Egrf8K2IrywzwOMk'], sub { ($res, $err) = @_ });
    @r = reqs();
    like($r[0]{url} // '', qr{/collection/v2/contains$}, 'checkShows: POST goes to collection/v2/contains');
    is(ff(pf($r[0]{body}), 2), 'show', 'checkShows: set is "show"');
    is_deeply($res, [1], 'checkShows: packed found decodes to [1]');
    is(scalar(@Plugins::SpotOn::API::Client::calls), 0, 'shows: Client.pm never called');
}

# ============================================================
# Task 2: addToPlaylist -- revision read, then ListChanges ADD
# ============================================================
my $REV1 = "REVISION-ONE-0123456789";   # opaque bytes; the real ones are 24 long
my $REV2 = "REVISION-TWO-0123456789";
sub revision_resp { enc(1, 2, $_[0]) . enc(18, 0, 1) }   # SelectedListContent{revision=1, capabilities=18}

sub playlist_rules {
    my (%o) = @_;
    rule('GET',  qr{/playlist/v2/playlist/PL1\?decorate=revision}, $o{revision} // revision_resp($REV1));
    rule('POST', qr{/playlist/v2/playlist/PL1/changes$},           $o{changes}  // '');
}
sub gets  { grep { $_->{method} eq 'GET'  } reqs() }
sub posts { grep { $_->{method} eq 'POST' } reqs() }

{
    reset_all();
    playlist_rules();

    my ($res, $err, $called) = ('unset', 'unset', 0);
    $SP->addToPlaylist('acct20', 'PL1', ['spotify:track:AAAAAAAAAAAAAAAAAAAAAA'], sub { ($res, $err) = @_; $called++ });

    my @g = gets();
    my @p = posts();
    is(scalar(@g), 1, 'addToPlaylist: exactly one revision GET');
    like($g[0]{url} // '', qr{/playlist/v2/playlist/PL1\?decorate=revision&from=0&length=1$}, 'addToPlaylist: GET url asks for decorate=revision&from=0&length=1');
    isnt($g[0]{headers}{'Accept'}, 'application/json', 'addToPlaylist: revision GET does not ask for JSON (protobuf)');
    is(scalar(@p), 1, 'addToPlaylist: exactly one changes POST');
    like($p[0]{url} // '', qr{/playlist/v2/playlist/PL1/changes$}, 'addToPlaylist: POST goes to playlist/v2/playlist/<id>/changes');
    is($p[0]{headers}{'Content-Type'}, 'application/x-protobuf', 'addToPlaylist: Content-Type is application/x-protobuf');

    my $lc = pf($p[0]{body});
    ok($lc, 'addToPlaylist: ListChanges body parses');
    is(ff($lc, 1), $REV1, 'addToPlaylist: base_revision is the revision bytes just read');
    my $delta = pf(ff($lc, 2));
    my $op    = pf(ff($delta, 2));
    is(ff($op, 1), 2, 'addToPlaylist: op kind is ADD (2)');
    my $add = pf(ff($op, 2));
    is(ff(pf(ff($add, 2)), 1), 'spotify:track:AAAAAAAAAAAAAAAAAAAAAA', 'addToPlaylist: add item uri');
    is(ff($add, 4), 1, 'addToPlaylist: add_last is 1');
    my $info = pf(ff($delta, 4));
    is(ff($info, 1), 'testuser', 'addToPlaylist: change info user is the credentials username');
    ok(ff($info, 2) && ff($info, 2) > 1_000_000_000_000, 'addToPlaylist: change info timestamp is unix milliseconds');
    is($called, 1, 'addToPlaylist: callback invoked exactly once');
    ok(!defined $res && !defined $err, 'addToPlaylist: success -> cb(undef, undef)');
    is(scalar(@Plugins::SpotOn::API::Client::calls), 0, 'addToPlaylist: Client.pm never called');
}

# 409: revision moved -> exactly one re-read and one retry, with the NEW revision
{
    reset_all();
    playlist_rules(revision => [ revision_resp($REV1), revision_resp($REV2) ],
                   changes  => [ { code => 409 }, '' ]);

    my ($res, $err, $called) = ('unset', 'unset', 0);
    $SP->addToPlaylist('acct21', 'PL1', ['spotify:track:AAAAAAAAAAAAAAAAAAAAAA'], sub { ($res, $err) = @_; $called++ });

    my @p = posts();
    is(scalar(gets()), 2, '409 then ok: revision read twice');
    is(scalar(@p), 2, '409 then ok: changes POSTed twice');
    is(ff(pf($p[0]{body}), 1), $REV1, '409 then ok: first POST carries the first revision');
    is(ff(pf($p[1]{body}), 1), $REV2, '409 then ok: retry carries the re-read revision');
    ok(!defined $res && !defined $err, '409 then ok: retry success -> cb(undef, undef)');
    is($called, 1, '409 then ok: callback invoked exactly once');
}

# 409 twice -> error, no third attempt
{
    reset_all();
    playlist_rules(revision => [ revision_resp($REV1), revision_resp($REV2) ],
                   changes  => { code => 409 });

    my ($res, $err, $called) = ('unset', 'unset', 0);
    $SP->addToPlaylist('acct22', 'PL1', ['spotify:track:AAAAAAAAAAAAAAAAAAAAAA'], sub { ($res, $err) = @_; $called++ });

    is(scalar(posts()), 2, 'second 409: exactly two POSTs (one retry only)');
    is(scalar(gets()), 2, 'second 409: exactly two revision reads');
    is(ref($err) eq 'HASH' ? $err->{code} : undef, 409, 'second 409: error with code 409 to cb');
    is($called, 1, 'second 409: callback invoked exactly once');
}

# 500 / transport failure on the change: never replayed (non-idempotent)
{
    reset_all();
    playlist_rules(changes => { code => 500 });
    my ($res, $err, $called) = ('unset', 'unset', 0);
    $SP->addToPlaylist('acct23', 'PL1', ['spotify:track:AAAAAAAAAAAAAAAAAAAAAA'], sub { ($res, $err) = @_; $called++ });
    is(scalar(posts()), 1, '500 on changes: exactly one POST (no retry)');
    is(scalar(gets()), 1, '500 on changes: exactly one revision read');
    is(ref($err) eq 'HASH' ? $err->{code} : undef, 500, '500 on changes: error code 500 to cb');
    is($called, 1, '500 on changes: callback invoked exactly once');

    reset_all();
    playlist_rules(changes => { code => 0 });
    ($res, $err, $called) = ('unset', 'unset', 0);
    $SP->addToPlaylist('acct23', 'PL1', ['spotify:track:AAAAAAAAAAAAAAAAAAAAAA'], sub { ($res, $err) = @_; $called++ });
    is(scalar(posts()), 1, 'transport error on changes: exactly one POST (no retry)');
    ok(ref($err) eq 'HASH' && $err->{error}, 'transport error on changes: error to cb');
    is($called, 1, 'transport error on changes: callback invoked exactly once');
}

# revision unavailable -> no change is sent
{
    reset_all();
    rule('GET', qr{/playlist/v2/playlist/PL1\?}, { code => 500 });
    rule('POST', qr{/changes$}, '');
    my ($res, $err) = ('unset', 'unset');
    $SP->addToPlaylist('acct24', 'PL1', ['spotify:track:AAAAAAAAAAAAAAAAAAAAAA'], sub { ($res, $err) = @_ });
    is(scalar(posts()), 0, 'revision read fails: no POST sent');
    is(ref($err) eq 'HASH' ? $err->{code} : undef, 500, 'revision read fails: error to cb');

    reset_all();
    rule('GET', qr{/playlist/v2/playlist/PL1\?}, enc(18, 0, 1));   # no field 1
    rule('POST', qr{/changes$}, '');
    ($res, $err) = ('unset', 'unset');
    $SP->addToPlaylist('acct24', 'PL1', ['spotify:track:AAAAAAAAAAAAAAAAAAAAAA'], sub { ($res, $err) = @_ });
    is(scalar(posts()), 0, 'revision without field 1: no POST sent');
    is(ref($err) eq 'HASH' ? $err->{error} : undef, 'parse_error', 'revision without field 1: parse_error');
}

# invalid ids / uris -> no request at all
{
    reset_all();
    my ($res, $err);
    for my $bad ('PL/../x', 'PL 1', '', 'a' x 41) {
        ($res, $err) = ('unset', 'unset');
        $SP->addToPlaylist('acct25', $bad, ['spotify:track:AAAAAAAAAAAAAAAAAAAAAA'], sub { ($res, $err) = @_ });
        is(ref($err) eq 'HASH' ? $err->{error} : undef, 'invalid_id', 'addToPlaylist invalid playlist id "' . substr($bad, 0, 8) . '": invalid_id');
    }
    ($res, $err) = ('unset', 'unset');
    $SP->addToPlaylist('acct25', 'PL1', ['not-a-uri'], sub { ($res, $err) = @_ });
    is(ref($err) eq 'HASH' ? $err->{error} : undef, 'invalid_id', 'addToPlaylist invalid uri: invalid_id');
    is(scalar(reqs()), 0, 'invalid ids: no HTTP request');
}

done_testing();

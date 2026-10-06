#!/usr/bin/perl
use strict;
use warnings;
use Test::More;

# Inline stubs for the LMS modules Net.pm depends on
BEGIN {
    package Slim::Utils::Prefs;
    my %store;
    sub preferences { return bless {}, 'Slim::Utils::Prefs' }
    sub get { return $store{$_[1]} }
    sub set { $store{$_[1]} = $_[2] }
    $INC{'Slim/Utils/Prefs.pm'} = 1;

    package Slim::Utils::Log;
    sub logger { return bless {}, 'Slim::Utils::Log' }
    sub AUTOLOAD { }
    sub DESTROY { }
    $INC{'Slim/Utils/Log.pm'} = 1;

    # LMS logs via `main::INFOLOG && $log->info(...)`; keep the info branch on
    # so the "via proxy" message can be checked (captured below).
    *main::INFOLOG  = sub () { 1 };
    *main::DEBUGLOG = sub () { 0 };
    @main::log_info = ();
    *Slim::Utils::Log::info = sub { push @main::log_info, $_[1] };

    # Minimal URI / HTTP::Request stand-ins (libwww is not core).
    # Capability lookup used by Net::proxyBlockedReason.
    package Plugins::SpotOn::Helper;
    our %caps;
    sub getCapability { $caps{$_[1]} }
    $INC{'Plugins/SpotOn/Helper.pm'} = 1;

    package FakeURI;
    use overload '""' => sub { $_[0]{str} }, fallback => 1;
    sub new {
        my ($class, $str) = @_;
        my ($scheme, $host, $port) = $str =~ m{^([a-z]+)://(\[[^\]]+\]|[^:/]+)(?::(\d+))?}i;
        $host =~ s/^\[|\]$//g;
        return bless { str => $str, scheme => lc $scheme, host => $host,
            port => $port || (lc $scheme eq 'https' ? 443 : 80) }, $class;
    }
    sub scheme { $_[0]{scheme} }
    sub host   { $_[0]{host} }
    sub port   { $_[0]{port} }
    sub as_string { $_[0]{str} }

    package FakeRequest;
    sub new { my ($class, $method, $url) = @_; return bless { method => $method, uri => FakeURI->new($url) }, $class }
    sub uri { my $self = shift; $self->{uri} = shift if @_; $self->{uri} }

    # Stub of Slim::Networking::SimpleHTTP::Base (parts used).
    package Slim::Networking::SimpleHTTP::Base;
    sub new { my ($class, @args) = @_; return bless { args => \@args }, $class }
    sub cb      { $_[0]{args}[0] }
    sub ecb     { $_[0]{args}[1] }
    sub _params { $_[0]{args}[2] }
    sub get { shift->_createHTTPRequest(GET => @_) }
    # Base::_createHTTPRequest: builds the request, returns ($request, $timeout)
    sub _createHTTPRequest {
        my ($self, $type, $url) = @_;
        my $params = $self->_params || {};
        return (FakeRequest->new($type => $url), $params->{Timeout} || $params->{timeout} || 30);
    }
    $INC{'Slim/Networking/SimpleHTTP/Base.pm'} = 1;

    # Stub of Slim::Networking::SimpleAsyncHTTP: like LMS 9.1, its own
    # _createHTTPRequest calls SUPER (Base) and then sends the request with a
    # stock Slim::Networking::Async::HTTP (recorded in @stock_sent).
    package Slim::Networking::SimpleAsyncHTTP;
    our @ISA = ('Slim::Networking::SimpleHTTP::Base');
    our @stock_sent;
    sub _createHTTPRequest {
        my $self = shift;
        my ($request, $timeout) = $self->SUPER::_createHTTPRequest(@_);
        return unless $request && $timeout;
        push @stock_sent, $request->uri->as_string;
        my $http = Slim::Networking::Async::HTTP->new($self->_params);
        $http->send_request({ request => $request, Timeout => $timeout,
            onError => \&onError, onBody => \&onBody, passthrough => [ $self ] });
    }
    sub onError { my ($http, $error, $self) = @_; $self->ecb->($self, $error, $http->response) }
    sub onBody  { my ($http, $self) = @_; $self->cb->($self) }
    $INC{'Slim/Networking/SimpleAsyncHTTP.pm'} = 1;

    package StubPlainSocket;
    package StubHTTPSSocket;

    package Slim::Networking::Async::Socket::HTTP;
    sub new { my ($class, %args) = @_; return bless { args => \%args }, 'StubPlainSocket' }
    $INC{'Slim/Networking/Async/Socket/HTTP.pm'} = 1;

    # Stub of Slim::Networking::Async::HTTP, including the parts of its base
    # Slim::Networking::Async (write_async/open/connect) that decide on DNS
    # and call new_socket. Mirrors LMS 9.1 control flow and method names.
    package Slim::Networking::Async::HTTP;
    our (@dns_lookups, @socket_args);
    sub mk_accessor {
        my ($class, $type, @names) = @_;
        no strict 'refs';
        for my $n (@names) {
            *{"${class}::$n"} = sub { my $s = shift; $s->{$n} = shift if @_; $s->{$n} };
        }
    }
    __PACKAGE__->mk_accessor(rw => qw(socket request response timeout options insecureHTTPS));
    sub new {
        my ($class, $args) = @_;
        my $self = bless {}, $class;
        $self->options($args->{options});
        $self->insecureHTTPS(Slim::Utils::Prefs->get('insecureHTTPS') || $args->{insecureHTTPS});
        return $self;
    }
    sub new_socket {
        my $self = shift;
        push @_, %{$self->options} if $self->options;
        if (my $proxy = $self->use_proxy) {
            my ($pserver, $pport) = split /:/, $proxy;
            return Slim::Networking::Async::Socket::HTTP->new(@_, PeerAddr => $pserver, PeerPort => $pport || 80);
        }
        if ($self->request->uri->scheme eq 'https') {
            my %args = @_;
            $args{SSL_hostname} //= $args{Host};
            return bless { args => \%args }, 'StubHTTPSSocket';
        }
        return Slim::Networking::Async::Socket::HTTP->new(@_);
    }
    sub use_proxy {
        my $self = shift;
        if (my $proxy = Slim::Utils::Prefs->get('webproxy')) {
            my $uri = $self->request->uri;
            return $proxy if $uri->scheme ne 'https' && $uri->host !~ /(?:localhost|127.0.0.1)/;
        }
        return;
    }
    sub send_request {
        my ($self, $args, $redirect) = @_;
        $self->timeout($args->{Timeout}) if $args->{Timeout};
        $self->request($args->{request});
        $self->write_async({
            host        => $self->request->uri->host,
            port        => $self->request->uri->port,
            Timeout     => $self->timeout,
            skipDNS     => ($self->use_proxy) ? 1 : 0,
            onError     => \&_http_error,
            passthrough => [ $args ],
        });
    }
    sub _http_error {
        my ($self, $error, $args) = @_;
        $self->disconnect;
        $args->{onError}->($self, $error, @{ $args->{passthrough} || [] }) if $args->{onError};
    }
    # --- Slim::Networking::Async ---
    sub write_async {
        my ($self, $args) = @_;
        if (!$self->socket) {
            return $self->open({
                Host => $args->{host}, PeerPort => $args->{port}, skipDNS => $args->{skipDNS},
                Timeout => $args->{Timeout}, onError => \&_async_error, passthrough => [ $self, $args ],
            });
        }
    }
    sub open {
        my ($self, $args) = @_;
        $args->{PeerAddr} = '127.0.0.1' if $args->{Host} =~ /^localhost$/i;
        if (!($args->{skipDNS} || $args->{PeerAddr} || $args->{Host} =~ /^\d+\.\d+\.\d+\.\d+$/)) {
            push @dns_lookups, $args->{Host};      # Async::DNS->resolve
            $args->{PeerAddr} = '192.0.2.53';      # _dns_ok
        }
        return $self->connect($args);
    }
    sub connect {
        my ($self, $args) = @_;
        my $socket = $self->new_socket(%{$args});
        push @socket_args, { %{$args} };
        if (!defined $socket) {    # _connect_error
            my $ecb = $args->{onError};
            $ecb->($self, "Connect timed out: $!", @{ $args->{passthrough} || [] }) if $ecb;
            return;
        }
        $self->socket($socket);    # _async_connect
    }
    sub disconnect { $_[0]->socket(undef) }
    sub _async_error {
        my ($socket, $error, $self, $args) = @_;
        $self->disconnect;
        $args->{onError}->($self, $error, @{ $args->{passthrough} || [] }) if $args->{onError};
    }
    $INC{'Slim/Networking/Async/HTTP.pm'} = 1;

    # Stand-in for LMS's HTTPS socket class (real one: Net::HTTPS::NB, which
    # isa Net::HTTPS isa IO::Socket::SSL). Only the IO::Socket::SSL part is
    # needed for HTTPSConnect->new; it is optional (skip if not installed).
    package Slim::Networking::Async::Socket::HTTPS;
    our @ISA;
    @ISA = ('IO::Socket::SSL') if eval { require IO::Socket::SSL; 1 };
    $INC{'Slim/Networking/Async/Socket/HTTPS.pm'} = 1;

    package main;
    no warnings 'redefine';
    *Slim::Utils::Prefs::import = sub {
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::preferences"} = \&Slim::Utils::Prefs::preferences;
    };
    *Slim::Utils::Log::import = sub {
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::logger"} = \&Slim::Utils::Log::logger;
    };
}

use FindBin qw($Bin);
use lib "$Bin/..";
use Plugins::SpotOn::Net qw(parseProxyUrl currentProxy proxyFor binaryProxyArgs proxyBlockedReason);

sub set_pref { Slim::Utils::Prefs->set(@_) }

# parseProxyUrl - valid
is_deeply((parseProxyUrl('http://proxy.lan:3128'))[0], {host=>'proxy.lan', port=>3128, url=>'http://proxy.lan:3128'}, 'plain host');
is((parseProxyUrl('  http://10.0.0.1:8080  '))[0]{url}, 'http://10.0.0.1:8080', 'whitespace trimmed');
is((parseProxyUrl('http://127.0.0.1:8888'))[0]{host}, '127.0.0.1', 'local proxy allowed');
is_deeply((parseProxyUrl('http://[::1]:8080'))[0], {host=>'::1', port=>8080, url=>'http://[::1]:8080'}, 'IPv6');
is((parseProxyUrl('http://host:3128/'))[0]{url}, 'http://host:3128', 'trailing slash dropped');
is((parseProxyUrl('HTTP://Host:3128'))[0]{url}, 'http://host:3128', 'case normalised');
is((parseProxyUrl('http://host:65535'))[0]{port}, 65535, 'max port');

# parseProxyUrl - errors
is((parseProxyUrl('http://h:80'))[1], 'port80', 'port 80 rejected (librespot cannot connect)');
is((parseProxyUrl('http://[::1]:80'))[1], 'port80', 'IPv6 port 80 rejected');
is((parseProxyUrl('http://h:8080'))[0]{port}, 8080, 'port 8080 still valid');
is((parseProxyUrl('http://h:0'))[1], 'port', 'port 0 stays a generic port error');
is((parseProxyUrl(''))[1], 'empty', 'empty');
is((parseProxyUrl(undef))[1], 'empty', 'undef');
is((parseProxyUrl('   '))[1], 'empty', 'blank');
is((parseProxyUrl('http://host'))[1], 'port', 'no port');
is((parseProxyUrl('http://host:0'))[1], 'port', 'port 0');
is((parseProxyUrl('http://host:70000'))[1], 'port', 'port too big');
is((parseProxyUrl('http://host:abc'))[1], 'port', 'port not numeric');
{
    my @warn; local $SIG{__WARN__} = sub { push @warn, @_ };
    is((parseProxyUrl("http://host:\x{0663}\x{0662}"))[1], 'port', 'Unicode digits are not a port');
    is_deeply(\@warn, [], 'Unicode digits: no warnings');
}
is((parseProxyUrl('http://u:p@host:3128'))[1], 'userinfo', 'userinfo');
is((parseProxyUrl('http://host:3128/x'))[1], 'path', 'path');
is((parseProxyUrl('http://host:3128/?a=1'))[1], 'path', 'query');
is((parseProxyUrl('https://host:3128'))[1], 'scheme', 'https');
is((parseProxyUrl('socks5://host:1080'))[1], 'socks_unsupported', 'socks5');
is((parseProxyUrl('socks://host:1080'))[1], 'socks_unsupported', 'socks');
is((parseProxyUrl('garbage'))[1], 'scheme', 'garbage');
is((parseProxyUrl('http://:3128'))[1], 'host', 'empty host');
# host syntax as strict as the binary's Url::parse (saved but rejected by the
# binary = daemon crash loop)
is((parseProxyUrl("http://$_:3128"))[1], 'host', "invalid host '$_'")
    for 'a<b', 'a b', 'a>b', 'a|b', 'a^b', 'a\\b', 'a%41', 'a"b', "a'b", 'a{b}', '.a', 'a..b',
        'host.123', '999.1.1.1', '1.2.3.256', '1.2.3', 'a.0x1f';
is((parseProxyUrl("http://pr\x{f6}xy:3128"))[1], 'host', 'non-ASCII host rejected');
is((parseProxyUrl('http://[::g]:3128'))[1], 'host', 'invalid IPv6 literal');
is((parseProxyUrl('http://[1:2]:3128'))[1], 'host', 'too short IPv6 literal');
is((parseProxyUrl('http://[:::]:3128'))[1], 'host', 'IPv6 literal with ":::"');
is((parseProxyUrl("http://$_->[0]:3128"))[0]{host}, $_->[1], "valid host '$_->[0]'")
    for ['exa_mple.com', 'exa_mple.com'], ['my-proxy', 'my-proxy'], ['Proxy.LAN', 'proxy.lan'],
        ['10.0.0.254', '10.0.0.254'], ['a1.b2', 'a1.b2'], ['proxy.lan.', 'proxy.lan.'], ['1host', '1host'];
is((parseProxyUrl('http://[2001:db8::1]:3128'))[0]{url}, 'http://[2001:db8::1]:3128', 'IPv6 literal');
is((parseProxyUrl('http://[::ffff:192.0.2.1]:3128'))[0]{host}, '::ffff:192.0.2.1', 'IPv6 with embedded IPv4');
ok(!defined((parseProxyUrl('garbage'))[0]), 'no hashref on error');

# currentProxy
set_pref(networkProxy => '');
ok(!defined currentProxy(), 'currentProxy empty');
set_pref(networkProxy => 'http://p:3128');
is(currentProxy()->{port}, 3128, 'currentProxy valid');

# proxyFor
set_pref(networkProxy => '');
is_deeply([proxyFor('https://api.spotify.com/v1/me')], [], 'no proxy configured');
set_pref(networkProxy => 'http://p:3128');
is_deeply([proxyFor('https://api.spotify.com/v1/me')], ['p', 3128], 'api via proxy');
is_deeply([proxyFor('https://accounts.spotify.com/api/token')], ['p', 3128], 'accounts via proxy');
is_deeply([proxyFor('http://127.0.0.1:9000/x')], [], 'loopback bypass');
is_deeply([proxyFor('http://127.4.5.6:1/x')], [], '127/8 bypass');
is_deeply([proxyFor('http://localhost:9000/x')], [], 'localhost bypass');
is_deeply([proxyFor('http://[::1]:9000/x')], [], '::1 bypass');
is_deeply([proxyFor('http://192.168.1.5:9000/x')], ['p', 3128], 'private LAN is not bypassed');
is_deeply([proxyFor('https://127.example.com/')], ['p', 3128], 'hostname starting with 127. is not bypassed');
is_deeply([proxyFor('http://127.0.0.1.nip.io/')], ['p', 3128], '127.0.0.1.<domain> is not bypassed');
is_deeply([proxyFor('http://127.255.255.254:80/')], [], '127/8 dotted quad bypass');
set_pref(networkProxy => 'http://127.0.0.1:8888');
is_deeply([proxyFor('https://api.spotify.com/')], ['127.0.0.1', 8888], 'proxy on localhost works');
is_deeply([proxyFor('https://api.spotify.com/', {host=>'o', port=>1})], ['o', 1], 'explicit override');
is_deeply([proxyFor('https://api.spotify.com/', undef)], [], 'explicit direct');
is_deeply([proxyFor('http://localhost/', {host=>'o', port=>1})], [], 'override still bypasses localhost');

# binaryProxyArgs
set_pref(networkProxy => '');
is_deeply([binaryProxyArgs()], [], 'args empty');
set_pref(networkProxy => 'http://p:3128');
is_deeply([binaryProxyArgs()], ['--proxy', 'http://p:3128'], 'args proxy');
set_pref(networkProxy => 'socks5://p:1');
is_deeply([binaryProxyArgs()], [], 'invalid = empty');

# http() without proxy
set_pref(networkProxy => '');
my $cb = sub {};
my $o = Plugins::SpotOn::Net->http($cb, $cb, {timeout=>5});
isa_ok($o, 'Slim::Networking::SimpleAsyncHTTP');
is(ref $o, 'Slim::Networking::SimpleAsyncHTTP', 'exact class');
is_deeply($o->{args}, [$cb, $cb, {timeout=>5}], 'args passed through');

# ---------------------------------------------------------------------------
# tunnel: Plugins::SpotOn::Net::Socket::HTTPSConnect
# ---------------------------------------------------------------------------
use IO::Socket::IP;
use IO::Select;
use File::Temp qw(tempfile tempdir);
use POSIX ();
use Time::HiRes qw(time sleep);

alarm 90;    # safety net: the whole file must never hang

require_ok('Plugins::SpotOn::Net::Socket::HTTPSConnect');
*_tunnel = \&Plugins::SpotOn::Net::Socket::HTTPSConnect::_tunnel;

my @children;
# local $?: waitpid on a SIGKILLed child sets $? = 9, which would otherwise
# become the test's exit status after all tests passed.
END { local $?; kill 'KILL', @children if @children; waitpid($_, 0) for @children }

# Fake proxy: listens on $addr, forks a child that accepts one connection,
# reads the request up to \r\n\r\n, stores it in a file and then plays the
# scenario: $response is written as-is, then $after runs ('echo', 'close',
# 'silent', 'trickle' or a coderef receiving the client socket).
# Returns (client socket connected to it, request file, listen port).
sub fake_proxy {
    my ($response, $after, $addr) = @_;
    $addr //= '127.0.0.1';
    my $l = IO::Socket::IP->new(Listen => 5, LocalHost => $addr, LocalPort => 0, ReuseAddr => 1)
        or die "listen on $addr: $@";
    my (undef, $reqfile) = tempfile(UNLINK => 1);
    my $pid = fork // die "fork: $!";
    if (!$pid) {
        alarm 15;
        my $c = $l->accept or POSIX::_exit(1);
        my $req = q();
        while ($req !~ /\r\n\r\n/) {
            sysread($c, $req, 1, length $req) or last;
        }
        open my $fh, q(>), $reqfile; print $fh $req; close $fh;
        syswrite($c, $response) if length $response;
        $after //= 'close';
        if (ref $after eq 'CODE') { $after->($c) }
        elsif ($after eq 'echo')   { while (sysread($c, my $buf, 4096)) { syswrite($c, $buf) } }
        elsif ($after eq 'silent') { 1 while sysread($c, my $buf, 4096) }
        elsif ($after eq 'trickle') { for (1 .. 20) { syswrite($c, 'H') or last; sleep 0.25 } }
        POSIX::_exit(0);
    }
    push @children, $pid;
    my $port = $l->sockport;
    my $s = IO::Socket::IP->new(PeerHost => $addr, PeerPort => $port, Timeout => 5)
        or die "connect to fake proxy: $@";
    close $l;
    return ($s, $reqfile, $port);
}
sub fake        { (fake_proxy($_[0], 'silent'))[0] }
sub fake_close  { (fake_proxy('', 'close'))[0] }
sub fake_silent { (fake_proxy('', 'silent'))[0] }
sub slurp { open my $fh, '<', $_[0] or return ''; local $/; my $d = <$fh>; $d // '' }
sub read_echo {
    my ($s, $want) = @_;
    $want //= 4;
    my $buf = '';
    my $sel = IO::Select->new($s);
    while (length $buf < $want && $sel->can_read(5)) {
        sysread($s, $buf, $want - length $buf, length $buf) or last;
    }
    return $buf;
}

{
    my ($s, $reqfile) = fake_proxy("HTTP/1.1 200 Connection established\r\n\r\n", 'echo');
    my ($ok, $err) = _tunnel($s, 'api.spotify.com', 443, 5);
    ok($ok, 'HTTP/1.1 200 opens the tunnel');
    is($err, undef, 'no error on success');
    like(slurp($reqfile), qr/^CONNECT api\.spotify\.com:443 HTTP\/1\.1\r\nHost: api\.spotify\.com:443\r\n\r\n\z/,
        'CONNECT request line and Host header');
    print $s "ping"; $s->flush;
    is(read_echo($s), 'ping', 'data flows through the tunnel');
}

# Review Focus 1: HTTP/1.0 200 (tinyproxy, old squid)
ok((_tunnel(fake("HTTP/1.0 200 Connection established\r\n\r\n"), 'h', 443, 5))[0], 'HTTP/1.0 200 accepted');
ok((_tunnel(fake("HTTP/1.1 200 OK\r\nProxy-Agent: x\r\n\r\n"), 'h', 443, 5))[0], '200 with headers accepted');

{
    my ($s) = fake_proxy("HTTP/1.1 200 OK\r\n\r\nEXTRA", 'silent');
    ok((_tunnel($s, 'h', 443, 5))[0], '200 followed by tunnel bytes');
    is(read_echo($s, 5), 'EXTRA', 'bytes after the header block stay in the socket');
}

# Rejections
is((_tunnel(fake("HTTP/1.1 403 Forbidden\r\n\r\n"), 'h', 443, 5))[1], 'proxy: CONNECT rejected: 403 Forbidden', 'rejected: 403');
like((_tunnel(fake("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic\r\n\r\n"), 'h', 443, 5))[1],
    qr/^proxy: CONNECT rejected: 407/, 'rejected: 407');
like((_tunnel(fake("HTTP/1.1 502 Bad Gateway\r\n\r\n"), 'h', 443, 5))[1], qr/^proxy: CONNECT rejected: 502/, 'rejected: 502');
is((_tunnel(fake("HTTP/1.1 201 Created\r\n\r\n"), 'h', 443, 5))[1], 'proxy: CONNECT rejected: 201 Created', 'only 200 opens');
is((_tunnel(fake("HTTP/1.1 503\r\n\r\n"), 'h', 443, 5))[1], 'proxy: CONNECT rejected: 503', 'no reason phrase');
is((_tunnel(fake("garbage\r\n\r\n"), 'h', 443, 5))[1], 'proxy: malformed response', 'garbage');
is((_tunnel(fake("HTTP/2 200\r\n\r\n"), 'h', 443, 5))[1], 'proxy: malformed response', 'HTTP/2 status line');
is((_tunnel(fake('X' x 9000), 'h', 443, 5))[1], 'proxy: malformed response', 'header block over 8 KB');
is((_tunnel(fake_close(), 'h', 443, 5))[1], 'proxy: connection closed', 'closed before reply');
is((_tunnel((fake_proxy("HTTP/1.1 200 OK\r\n", 'close'))[0], 'h', 443, 5))[1], 'proxy: connection closed',
    'closed mid-headers');

# Review Focus 2: silent / trickling proxy must time out within the limit
{
    my $t0 = time; my @r = _tunnel(fake_silent(), 'h', 443, 1);
    is($r[1], 'proxy: timeout', 'silent proxy times out');
    cmp_ok(time - $t0, '<', 3, 'silent proxy: bounded by timeout');
    $t0 = time; @r = _tunnel((fake_proxy('', 'trickle'))[0], 'h', 443, 1);
    is($r[1], 'proxy: timeout', 'trickling proxy times out');
    cmp_ok(time - $t0, '<', 3, 'trickling proxy: deadline is total, not per read');
}

# Review Focus 4: IPv6 proxy on ::1
SKIP: {
    my $probe = IO::Socket::IP->new(Listen => 1, LocalHost => '::1', LocalPort => 0);
    skip 'IPv6 loopback not available', 2 unless $probe;
    close $probe;
    my ($s, $reqfile) = fake_proxy("HTTP/1.1 200 OK\r\n\r\n", 'silent', '::1');
    ok((_tunnel($s, 'api.spotify.com', 443, 5))[0], 'tunnel through IPv6 proxy');
    like(slurp($reqfile), qr/^CONNECT api\.spotify\.com:443 /, 'IPv6 proxy got the CONNECT');
}

# ---------------------------------------------------------------------------
# HTTPSConnect->new: TCP to proxy + CONNECT + TLS to the target (real TLS,
# self-signed cert). Needs Net::HTTP, IO::Socket::SSL and openssl (not core):
# skipped when unavailable. Net::HTTPS::NB is replaced by the stub above.
# ---------------------------------------------------------------------------
SKIP: {
    skip 'Net::HTTP / IO::Socket::SSL not installed', 32
        unless eval { require Net::HTTP; require IO::Socket::SSL; 1 };
    my $class = 'Plugins::SpotOn::Net::Socket::HTTPSConnect';
    my $dir = tempdir(CLEANUP => 1);
    my ($crt, $key) = ("$dir/c.pem", "$dir/k.pem");
    system("openssl req -x509 -newkey rsa:2048 -nodes -keyout $key -out $crt -days 2"
        . " -subj /CN=api.test -addext subjectAltName=DNS:api.test >/dev/null 2>&1");
    skip 'openssl cannot create a test certificate', 32 unless -s $crt && -s $key;

    # Child side after CONNECT: TLS server presenting the api.test cert, echo.
    my $tls_echo = sub {
        my ($c) = @_;
        my $ssl = IO::Socket::SSL->start_SSL($c, SSL_server => 1, SSL_cert_file => $crt,
            SSL_key_file => $key, Timeout => 5) or return;
        while (defined(my $line = <$ssl>)) { print $ssl $line }
    };
    # fake_proxy() also connects a client; new() makes its own connection,
    # so this variant only listens and hands back the port.
    my $proxy_for_new = sub {
        my ($response, $after) = @_;
        my $l = IO::Socket::IP->new(Listen => 5, LocalHost => '127.0.0.1', LocalPort => 0, ReuseAddr => 1)
            or die "listen: $@";
        my (undef, $reqfile) = tempfile(UNLINK => 1);
        my $pid = fork // die "fork: $!";
        if (!$pid) {
            alarm 15;
            my $c = $l->accept or POSIX::_exit(1);
            my $req = '';
            while ($req !~ /\r\n\r\n/) { sysread($c, $req, 1, length $req) or last }
            open my $fh, '>', $reqfile; print $fh $req; close $fh;
            syswrite($c, $response) if length $response;
            if (ref $after eq 'CODE') { $after->($c) }
            elsif (($after // '') eq 'silent') { 1 while sysread($c, my $buf, 4096) }
            POSIX::_exit(0);
        }
        push @children, $pid;
        my $port = $l->sockport;
        close $l;
        return ($port, $reqfile);
    };

    my %base = (Host => 'api.test', PeerAddr => '192.0.2.1', PeerPort => 443, Timeout => 30);
    no warnings 'once';
    my $NC = \%Plugins::SpotOn::Net::Socket::HTTPSConnect::unreachable;
    use warnings 'once';

    {
        my ($port, $reqfile) = $proxy_for_new->("HTTP/1.1 200 OK\r\n\r\n", $tls_echo);
        my $sock = $class->new(%base, SSL_ca_file => $crt, ProxyAddr => '127.0.0.1', ProxyPort => $port);
        ok($sock, 'new: tunnel + verified TLS established') or diag("error: $@");
        isa_ok($sock, 'Slim::Networking::Async::Socket::HTTPS');
        like(slurp($reqfile), qr/^CONNECT api\.test:443 HTTP\/1\.1\r\n/, 'new: CONNECT to the target, not PeerAddr');
        SKIP: {
            skip 'no socket', 5 unless $sock;
            ok(!$sock->blocking, 'new: socket is non-blocking once established');
            # LMS Async::write_async arms its "Timed out waiting for data"
            # timer from io_socket_timeout: must be the caller's Timeout,
            # not the 5 s handshake budget.
            is(${*$sock}{io_socket_timeout}, 30, 'new: io_socket_timeout is the caller Timeout after the handshake');
            is($sock->timeout, 30, 'new: ->timeout is the caller Timeout');
            is($sock->peerport, $port, 'new: TCP peer is the proxy');
            syswrite($sock, "hello\n");
            my $buf = '';
            my $sel = IO::Select->new($sock);
            for (1 .. 50) {
                my $n = sysread($sock, $buf, 100, length $buf);
                last if $buf =~ /\n/;
                $sel->can_read(0.1) unless defined $n && $n;
            }
            is($buf, "hello\n", 'new: application data flows over TLS through the tunnel');
            $sock->close;
        }
    }

    {
        my ($port) = $proxy_for_new->("HTTP/1.1 403 Forbidden\r\n\r\n", 'silent');
        $@ = '';
        my $sock = $class->new(%base, ProxyAddr => '127.0.0.1', ProxyPort => $port);
        ok(!defined $sock, 'new: rejected CONNECT gives undef');
        is($@, 'proxy: CONNECT rejected: 403 Forbidden', 'new: rejection reason in $@');
        ok(!exists $NC->{"127.0.0.1:$port"}, 'negative cache: CONNECT rejection (proxy reachable) is not cached');
    }

    {
        my ($port) = $proxy_for_new->('', 'silent');
        my $t0 = time;
        my $sock = $class->new(%base, ProxyAddr => '127.0.0.1', ProxyPort => $port);
        is($@, 'proxy: timeout', 'new: silent proxy times out');
        cmp_ok(time - $t0, '<', 7, 'new: handshake bounded by 5 s even with Timeout => 30');

        # negative cache: the next attempt to the same proxy fails at once
        $t0 = time;
        $sock = $class->new(%base, ProxyAddr => '127.0.0.1', ProxyPort => $port);
        ok(!defined $sock, 'negative cache: timeout -> next attempt refused');
        like($@, qr/^proxy: unreachable \(recent failure, retry in (?:29|30)s\)\z/, 'negative cache: error message');
        cmp_ok(time - $t0, '<', 0.5, 'negative cache: no blocking handshake');
        %$NC = ();
    }

    {
        # bind+close to get a port nobody listens on
        my $l = IO::Socket::IP->new(Listen => 1, LocalHost => '127.0.0.1', LocalPort => 0);
        my $port = $l->sockport; close $l;
        my $sock = $class->new(%base, ProxyAddr => '127.0.0.1', ProxyPort => $port);
        like($@, qr/^proxy: cannot connect to 127\.0\.0\.1:\d+: /, 'new: proxy down');

        $class->new(%base, ProxyAddr => '127.0.0.1', ProxyPort => $port);
        like($@, qr/^proxy: unreachable \(recent failure, retry in \d+s\)\z/, 'negative cache: connect failure is cached');
        my $l2 = IO::Socket::IP->new(Listen => 1, LocalHost => '127.0.0.1', LocalPort => 0);
        my $port2 = $l2->sockport; close $l2;
        $class->new(%base, ProxyAddr => '127.0.0.1', ProxyPort => $port2);
        like($@, qr/^proxy: cannot connect/, 'negative cache: keyed by proxy host:port');
        {
            my $base_t = time;
            $NC->{"127.0.0.1:$port"} = $base_t + 30;
            no warnings 'once';
            local $Plugins::SpotOn::Net::Socket::HTTPSConnect::clock = sub { $base_t + 20 };
            $class->new(%base, ProxyAddr => '127.0.0.1', ProxyPort => $port);
            like($@, qr/retry in (?:9|10)s\)\z/, 'negative cache: retry countdown');
            local $Plugins::SpotOn::Net::Socket::HTTPSConnect::clock = sub { $base_t + 31 };
            $class->new(%base, ProxyAddr => '127.0.0.1', ProxyPort => $port);
            like($@, qr/^proxy: cannot connect/, 'negative cache: entry expires after 30 s');
        }
        %$NC = ();
    }

    {
        # a successful handshake clears the entry; NoNegativeCache (settings
        # Test button) ignores the cache
        my ($port) = $proxy_for_new->("HTTP/1.1 200 OK\r\n\r\n", $tls_echo);
        $NC->{"127.0.0.1:$port"} = time + 30;
        $class->new(%base, SSL_ca_file => $crt, ProxyAddr => '127.0.0.1', ProxyPort => $port);
        like($@, qr/^proxy: unreachable/, 'negative cache: cached proxy refused without the bypass flag');
        my $sock = $class->new(%base, SSL_ca_file => $crt, ProxyAddr => '127.0.0.1', ProxyPort => $port,
            NoNegativeCache => 1);
        ok($sock, 'negative cache: NoNegativeCache bypasses the cache') or diag("error: $@");
        ok(!exists $NC->{"127.0.0.1:$port"}, 'negative cache: success clears the entry');
        $sock->close if $sock;
    }

    {
        # untrusted cert (no CA given): verification must fail ...
        my ($port) = $proxy_for_new->("HTTP/1.1 200 OK\r\n\r\n", $tls_echo);
        my $sock = $class->new(%base, ProxyAddr => '127.0.0.1', ProxyPort => $port);
        like($@, qr/^proxy: TLS handshake failed/, 'new: certificate is verified by default');
        # ... unless the LMS server pref insecureHTTPS is set
        set_pref(insecureHTTPS => 1);
        ($port) = $proxy_for_new->("HTTP/1.1 200 OK\r\n\r\n", $tls_echo);
        $sock = $class->new(%base, ProxyAddr => '127.0.0.1', ProxyPort => $port);
        ok($sock, 'new: insecureHTTPS disables verification') or diag("error: $@");
        is($sock && $sock->timeout, 30, 'new: insecure path also keeps the caller Timeout');
        $sock->close if $sock;
        set_pref(insecureHTTPS => 0);
    }

    {
        # no Timeout from the caller: 30 s fallback, not the 5 s handshake budget
        set_pref(insecureHTTPS => 1);
        my ($port) = $proxy_for_new->("HTTP/1.1 200 OK\r\n\r\n", $tls_echo);
        my %noTimeout = %base; delete $noTimeout{Timeout};
        my $sock = $class->new(%noTimeout, ProxyAddr => '127.0.0.1', ProxyPort => $port);
        is($sock && $sock->timeout, 30, 'new: io_socket_timeout falls back to 30 s');
        $sock->close if $sock;
        set_pref(insecureHTTPS => 0);
    }

    {
        # the certificate is checked against the target Host, not the proxy
        my ($port) = $proxy_for_new->("HTTP/1.1 200 OK\r\n\r\n", $tls_echo);
        my $sock = $class->new(%base, Host => 'other.test', SSL_ca_file => $crt,
            ProxyAddr => '127.0.0.1', ProxyPort => $port);
        like($@, qr/^proxy: TLS handshake failed/, 'new: certificate name must match the target host');
    }

    {
        # slow CONNECT reply, then silence during TLS: 5 s is the total budget
        my ($port) = $proxy_for_new->('', sub {
            sleep 3; syswrite($_[0], "HTTP/1.1 200 OK\r\n\r\n"); 1 while sysread($_[0], my $b, 4096);
        });
        my $t0 = time;
        my $sock = $class->new(%base, ProxyAddr => '127.0.0.1', ProxyPort => $port);
        like($@, qr/^proxy: TLS handshake failed/, 'new: TLS stalls after CONNECT');
        cmp_ok(time - $t0, '<', 6.5, 'new: TCP + CONNECT + TLS share one 5 s deadline');
    }

    SKIP: {
        my $probe = IO::Socket::IP->new(Listen => 1, LocalHost => '::1', LocalPort => 0);
        skip 'IPv6 loopback not available', 1 unless $probe;
        my $port = $probe->sockport;
        my $pid = fork // die;
        if (!$pid) {
            alarm 15;
            my $c = $probe->accept or POSIX::_exit(1);
            my $req = '';
            while ($req !~ /\r\n\r\n/) { sysread($c, $req, 1, length $req) or last }
            syswrite($c, "HTTP/1.1 403 Forbidden\r\n\r\n");
            POSIX::_exit(0);
        }
        push @children, $pid;
        close $probe;
        $class->new(%base, ProxyAddr => '::1', ProxyPort => $port);
        is($@, 'proxy: CONNECT rejected: 403 Forbidden', 'new: IPv6 proxy address (no brackets) reaches the proxy');
    }
}

# ---------------------------------------------------------------------------
# async: Net->http proxy branch, Net::SimpleAsyncHTTP, Net::AsyncHTTP
# ---------------------------------------------------------------------------
{
    require_ok('Plugins::SpotOn::Net::AsyncHTTP');
    require_ok('Plugins::SpotOn::Net::SimpleAsyncHTTP');

    # HTTPSConnect stand-in: records its arguments, can be told to fail.
    my (%fake_connect_args, $fake_connect_error);
    no warnings qw(redefine once);
    local *Plugins::SpotOn::Net::Socket::HTTPSConnect::new = sub {
        my ($class, %args) = @_;
        %fake_connect_args = %args;
        if (defined $fake_connect_error) { $@ = $fake_connect_error; return undef }
        return bless { args => \%args }, 'FakeHTTPSConnect';
    };
    use warnings 'redefine';

    my $AH = 'Plugins::SpotOn::Net::AsyncHTTP';
    sub new_async {
        my ($url, $args) = @_;
        my $a = Plugins::SpotOn::Net::AsyncHTTP->new($args || {});
        $a->request(FakeRequest->new(GET => $url));
        return $a;
    }
    my $reset = sub {
        @Slim::Networking::Async::HTTP::dns_lookups = ();
        @Slim::Networking::Async::HTTP::socket_args = ();
        @main::log_info = ();
        %fake_connect_args = ();
    };

    # Net->http picks the subclass when a proxy is set
    set_pref(networkProxy => 'http://p:3128');
    my $h = Plugins::SpotOn::Net->http(sub {}, sub {}, {});
    isa_ok($h, 'Plugins::SpotOn::Net::SimpleAsyncHTTP');
    isa_ok($h, 'Slim::Networking::SimpleAsyncHTTP');

    # https via proxy: tunnel, not absolute-URI proxying
    my $a = new_async('https://api.spotify.com/v1/me');
    isa_ok($a, 'Slim::Networking::Async::HTTP');
    is($a->use_proxy, undef, 'https: use_proxy is off (no absolute-URI request)');
    $reset->();
    is(ref $a->new_socket(Host => 'api.spotify.com', PeerPort => 443), 'FakeHTTPSConnect', 'https: CONNECT tunnel socket');
    is($fake_connect_args{ProxyAddr}, 'p', 'tunnel: ProxyAddr');
    is($fake_connect_args{ProxyPort}, 3128, 'tunnel: ProxyPort');
    is($fake_connect_args{Host}, 'api.spotify.com', 'tunnel: target host passed through');
    is($fake_connect_args{PeerPort}, 443, 'tunnel: target port passed through');
    is($fake_connect_args{SSL_hostname}, 'api.spotify.com', 'tunnel: SNI set to the target');
    ok(!$fake_connect_args{NoNegativeCache}, 'tunnel: normal requests use the negative cache');
    is_deeply(\@main::log_info, ['via proxy p:3128'], 'tunnel choice is logged');
    my %w = (host => 'api.spotify.com', port => 443);
    $a->write_async(\%w);
    is($w{skipDNS}, 1, 'https via proxy: write_async forces skipDNS');

    # full request path: no local DNS lookup, hostname reaches new_socket
    $reset->();
    $a = new_async('https://api.spotify.com/');
    $a->send_request({ request => FakeRequest->new(GET => 'https://accounts.spotify.com/api/token') });
    is_deeply(\@Slim::Networking::Async::HTTP::dns_lookups, [], 'https via proxy: target is not resolved locally');
    is($Slim::Networking::Async::HTTP::socket_args[0]{Host}, 'accounts.spotify.com', 'new_socket gets the hostname');
    ok(!defined $Slim::Networking::Async::HTTP::socket_args[0]{PeerAddr}, 'no resolved PeerAddr');
    is(ref $a->socket, 'FakeHTTPSConnect', 'send_request ends up in the tunnel');
    is($fake_connect_args{Host}, 'accounts.spotify.com', 'CONNECT target = request host');

    # Review Focus 3: redirect to another https host is tunneled again
    # (LMS _http_read: disconnect, rewrite request->uri, send_request(..., 1))
    $reset->();
    $a->disconnect;
    $a->request->uri(FakeURI->new('https://other.example/'));
    $a->send_request({ request => $a->request }, 1);
    is(ref $a->socket, 'FakeHTTPSConnect', 'redirect: other host goes through the tunnel');
    is($fake_connect_args{Host}, 'other.example', 'redirect: CONNECT to the new host');
    is_deeply(\@Slim::Networking::Async::HTTP::dns_lookups, [], 'redirect: no local DNS');
    $a->request(FakeRequest->new(GET => 'https://other2.example/'));
    is(ref $a->new_socket(Host => 'other2.example', PeerPort => 443), 'FakeHTTPSConnect', 'new request on same object: tunnel');
    # redirect https -> http: absolute-URI request via the proxy
    $reset->();
    $a->disconnect;
    $a->request->uri(FakeURI->new('http://plain.example/x'));
    $a->send_request({ request => $a->request }, 1);
    is(ref $a->socket, 'StubPlainSocket', 'redirect to http: plain socket');
    is($a->socket->{args}{PeerAddr}, 'p', 'redirect to http: connects to the proxy');
    is_deeply(\@Slim::Networking::Async::HTTP::dns_lookups, [], 'redirect to http: no local DNS');

    # http via proxy: absolute-URI request to the proxy
    is(new_async('http://example.com/x')->use_proxy, 'p:3128', 'http: use_proxy');
    {
        my $s = new_async('http://example.com/x', { options => { Foo => 1 } })->new_socket(Host => 'example.com', PeerPort => 80);
        is(ref $s, 'StubPlainSocket', 'http via proxy: plain socket');
        is_deeply([@{ $s->{args} }{qw(Host PeerAddr PeerPort Foo)}], ['example.com', 'p', 3128, 1],
            'http via proxy: connects to the proxy, options merged');
    }
    is(new_async('http://127.0.0.1:9000/x')->use_proxy, undef, 'loopback: no proxy');
    is(ref new_async('http://127.0.0.1:9000/x')->new_socket(Host => '127.0.0.1', PeerPort => 9000), 'StubPlainSocket',
        'loopback: direct socket');
    {
        my $s = new_async('http://127.0.0.1:9000/x')->new_socket(Host => '127.0.0.1', PeerPort => 9000);
        ok(!defined $s->{args}{PeerAddr}, 'loopback: not sent to the proxy');
    }
    {
        my %w2 = (host => '127.0.0.1', port => 9000);
        new_async('http://127.0.0.1:9000/x')->write_async(\%w2);
        ok(!exists $w2{skipDNS}, 'loopback: write_async leaves skipDNS alone');
    }

    # IPv6 proxy address
    set_pref(networkProxy => 'http://[::1]:8080');
    is(new_async('http://example.com/')->use_proxy, '[::1]:8080', 'IPv6 proxy: use_proxy keeps brackets');
    is(new_async('http://example.com/')->new_socket(Host => 'example.com', PeerPort => 80)->{args}{PeerAddr}, '[::1]',
        'IPv6 proxy: http socket gets a bracketed PeerAddr');
    new_async('https://example.com/')->new_socket(Host => 'example.com', PeerPort => 443);
    is($fake_connect_args{ProxyAddr}, '::1', 'IPv6 proxy: tunnel gets the bare address');

    # insecureHTTPS request param
    set_pref(networkProxy => 'http://p:3128');
    new_async('https://example.com/', { insecureHTTPS => 1 })->new_socket(Host => 'example.com', PeerPort => 443);
    is($fake_connect_args{SSL_verify_mode}, 0, 'insecureHTTPS param disables verification in the tunnel');
    {
        # LMS 8.x's Async::HTTP may lack the insecureHTTPS accessor
        my $old = new_async('https://example.com/');
        no warnings 'redefine';
        local *Slim::Networking::Async::HTTP::insecureHTTPS;
        %fake_connect_args = ();
        my $s = eval { $old->new_socket(Host => 'example.com', PeerPort => 443) };
        is(ref $s, 'FakeHTTPSConnect', 'no insecureHTTPS method: tunnel still built') or diag($@);
        ok(!exists $fake_connect_args{SSL_verify_mode}, 'no insecureHTTPS method: verification left on');
    }

    # tunnel failure: the "proxy: ..." error reaches the caller's ecb as is
    {
        $fake_connect_error = 'proxy: CONNECT rejected: 403 Forbidden';
        my @err;
        my $http = Plugins::SpotOn::Net->http(sub { push @err, 'ok' }, sub { push @err, $_[1] }, { timeout => 5 });
        $http->get('https://api.spotify.com/v1/me');
        is_deeply(\@err, ['proxy: CONNECT rejected: 403 Forbidden'], 'ecb receives the proxy error');
        undef $fake_connect_error;
    }
    {
        # ... and a plain connect failure without proxy keeps the LMS message
        set_pref(networkProxy => '');
        my @err;
        no warnings 'redefine';
        local *Slim::Networking::Async::HTTP::new_socket = sub { $@ = 'boom'; undef };
        my $http = Plugins::SpotOn::Net->http(sub {}, sub { push @err, $_[1] }, { proxyOverride => undef });
        $http->get('https://api.spotify.com/');
        like($err[0] // '', qr/^Connect timed out/, 'direct connect failure: LMS error unchanged');
        set_pref(networkProxy => 'http://p:3128');
    }

    # SimpleAsyncHTTP: _params go to AsyncHTTP->new; request settings passed on
    {
        my @seen;
        no warnings 'redefine';
        no warnings 'once';
        local *Plugins::SpotOn::Net::AsyncHTTP::send_request = sub { push @seen, [$_[0], $_[1]] };
        use warnings 'redefine';
        my $params = { timeout => 7, maxRedirect => 3, saveAs => '/tmp/x', options => { A => 1 } };
        my $http = Plugins::SpotOn::Net->http(sub {}, sub {}, $params);
        @Slim::Networking::SimpleAsyncHTTP::stock_sent = ();
        $http->get('https://api.spotify.com/v1/me');
        is(scalar @seen, 1, 'exactly one request sent');
        is_deeply(\@Slim::Networking::SimpleAsyncHTTP::stock_sent, [],
            'stock SimpleAsyncHTTP::_createHTTPRequest is bypassed (no second, direct request)');
        is(ref $seen[0][0], 'Plugins::SpotOn::Net::AsyncHTTP', 'SimpleAsyncHTTP uses Net::AsyncHTTP');
        is_deeply($seen[0][0]->options, { A => 1 }, '_params passed to AsyncHTTP->new');
        my $r = $seen[0][1];
        is($r->{request}->uri->as_string, 'https://api.spotify.com/v1/me', 'request passed');
        is_deeply([@{$r}{qw(maxRedirect saveAs Timeout)}], [3, '/tmp/x', 7], 'maxRedirect/saveAs/Timeout passed');
        is_deeply($r->{passthrough}, [$http], 'passthrough is the SimpleAsyncHTTP object');
        is($r->{onBody}, \&Slim::Networking::SimpleAsyncHTTP::onBody, 'onBody is the LMS handler');
        ok(ref $r->{onError} eq 'CODE', 'onError set');
    }

    # proxyOverride: hashref routes through it even with an empty pref ...
    set_pref(networkProxy => '');
    my $ov = { host => 'o', port => 9 };
    $h = Plugins::SpotOn::Net->http(sub {}, sub {}, { proxyOverride => $ov });
    is(ref $h, 'Plugins::SpotOn::Net::SimpleAsyncHTTP', 'override hashref: subclass even with empty pref');
    $reset->();
    $h->get('https://apresolve.spotify.com/?type=accesspoint');
    is($fake_connect_args{ProxyAddr}, 'o', 'override hashref: tunnel to the override proxy');
    is($fake_connect_args{ProxyPort}, 9, 'override hashref: override port');
    is($fake_connect_args{NoNegativeCache}, 1, 'override hashref (Test button): negative cache bypassed');
    is(new_async('http://example.com/', { proxyOverride => $ov })->use_proxy, 'o:9', 'override hashref: use_proxy');
    # ... undef means direct even with a pref set
    set_pref(networkProxy => 'http://p:3128');
    $h = Plugins::SpotOn::Net->http(sub {}, sub {}, { proxyOverride => undef });
    is(ref $h, 'Plugins::SpotOn::Net::SimpleAsyncHTTP', 'override undef: subclass');
    $reset->();
    $h->get('https://apresolve.spotify.com/?type=accesspoint');
    is_deeply(\%fake_connect_args, {}, 'override undef: no tunnel');
    is(ref $Slim::Networking::Async::HTTP::socket_args[0] ? 1 : 0, 1, 'override undef: a socket was opened');
    is_deeply(\@Slim::Networking::Async::HTTP::dns_lookups, ['apresolve.spotify.com'], 'override undef: normal LMS DNS');
    my $d = new_async('https://api.spotify.com/', { proxyOverride => undef });
    is(ref $d->new_socket(Host => 'api.spotify.com', PeerPort => 443), 'StubHTTPSSocket', 'override undef: direct https socket');
    is($d->use_proxy, undef, 'override undef: no use_proxy');

    # no proxy at all: stock class, stock sockets
    set_pref(networkProxy => '');
    is(ref Plugins::SpotOn::Net->http(sub {}, sub {}, {}), 'Slim::Networking::SimpleAsyncHTTP', 'no proxy: stock class');
    is(ref Plugins::SpotOn::Net->http(sub {}, sub {}), 'Slim::Networking::SimpleAsyncHTTP', 'no proxy, no params: stock class');
    is(ref new_async('https://api.spotify.com/')->new_socket(Host => 'api.spotify.com', PeerPort => 443), 'StubHTTPSSocket',
        'no proxy: stock HTTPS socket');
    {
        my %w3 = (host => 'api.spotify.com', port => 443);
        new_async('https://api.spotify.com/')->write_async(\%w3);
        ok(!exists $w3{skipDNS}, 'no proxy: skipDNS untouched');
    }
    set_pref(webproxy => 'wp:8080');
    is(new_async('http://example.com/')->use_proxy, 'wp:8080', 'no proxy: LMS webproxy still honoured');
    set_pref(networkProxy => 'http://p:3128');
    is(new_async('http://example.com/')->use_proxy, 'p:3128', 'networkProxy overrides webproxy for http');
    set_pref(webproxy => '');
    set_pref(networkProxy => '');
}

# ---------------------------------------------------------------------------
# spawn: fail closed when the binary cannot take --proxy
# ---------------------------------------------------------------------------
{
    set_pref(networkProxy => 'http://p:3128');
    $Plugins::SpotOn::Helper::caps{proxy} = 1;
    is(proxyBlockedReason(), undef, 'proxy + capability: not blocked');
    $Plugins::SpotOn::Helper::caps{proxy} = undef;
    is(proxyBlockedReason(), 'binary_no_proxy', 'proxy without capability: blocked');
    set_pref(networkProxy => '');
    is(proxyBlockedReason(), undef, 'no proxy: never blocked');
    set_pref(networkProxy => 'http://h:80');
    $Plugins::SpotOn::Helper::caps{proxy} = undef;
    is(proxyBlockedReason(), undef, 'invalid proxy (not in effect) is not blocked');
    set_pref(networkProxy => '');
}

# ---------------------------------------------------------------------------
# guard: no plugin code may construct Slim::Networking::SimpleAsyncHTTP directly
# ---------------------------------------------------------------------------
{
    require File::Find;
    my @offenders;
    File::Find::find(sub {
        return unless /\.pm$/ && $File::Find::name !~ m{/Plugins/SpotOn/Net(?:/|\.pm$)};
        open my $fh, '<', $_ or die "$File::Find::name: $!";
        local $/; my $src = <$fh>;
        push @offenders, $File::Find::name if $src =~ /Slim::Networking::SimpleAsyncHTTP\s*->\s*new/;
    }, "$Bin/../Plugins/SpotOn");
    is_deeply([sort @offenders], [], 'all HTTP goes through Plugins::SpotOn::Net');
}

done_testing;

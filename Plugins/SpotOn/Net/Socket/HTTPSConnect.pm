package Plugins::SpotOn::Net::Socket::HTTPSConnect;

# https socket through an HTTP proxy (CONNECT tunnel), usable by LMS's async
# HTTP machinery exactly like Slim::Networking::Async::Socket::HTTPS.
# The proxy handshake (TCP + CONNECT + TLS) is done blocking, bounded by
# HANDSHAKE_TIMEOUT in total; the socket is non-blocking once returned.
# Negative cache: the blocking handshake stalls the LMS main loop, so after a
# timeout or a failed TCP connect to the proxy, further tunnels to that proxy
# fail at once for NEGATIVE_CACHE_SECONDS (unless NoNegativeCache is passed,
# as for the settings page's Test button). CONNECT rejections and TLS errors
# are not cached: the proxy is reachable.

use strict;
use warnings;

use base qw(Slim::Networking::Async::Socket::HTTPS);

use IO::Select;
use POSIX ();
use Time::HiRes ();
use Slim::Utils::Prefs;

use constant HANDSHAKE_TIMEOUT => 5;
use constant MAX_RESPONSE      => 8192;
use constant NEGATIVE_CACHE_SECONDS => 30;

# "proxyhost:port" => time until which tunnels to that proxy are refused
our %unreachable;
# clock for the negative cache (tests override it)
our $clock = \&Time::HiRes::time;

# Returns the socket, or undef with $@ = 'proxy: ...'.
# %args are those of Slim::Networking::Async::Socket::HTTPS->new (Host and
# PeerPort are the target; PeerAddr, the target's resolved address, is
# replaced by the proxy) plus ProxyAddr / ProxyPort and, optionally,
# NoNegativeCache => 1 (ignore the negative cache for this attempt).
#
# Why not $class->SUPER::new(..., Blocking => 1): Slim's HTTPS::new forces
# Blocking => 0, and Net::HTTPS::NB::new starts TLS right after the TCP
# connect, i.e. with the proxy. So we perform the same steps as
# Net::HTTPS::NB::new -- Net::HTTP->new, then $class->start_SSL with
# SSL_startHandshake => 0 -- with the CONNECT exchange in between, blocking.
# The finished TLS socket makes NB's connected() true (connect_SSL returns
# early on an opened SSL socket), so LMS sees an already connected socket.
sub new {
    my ($class, %args) = @_;

    my $proxyAddr = delete $args{ProxyAddr};
    my $proxyPort = delete $args{ProxyPort};
    my $noCache   = delete $args{NoNegativeCache};
    my $cacheKey  = "$proxyAddr:$proxyPort";
    my $host      = $args{Host};
    my $port      = $args{PeerPort} || 443;
    # The caller's Timeout (LMS: request Timeout, Async::open default
    # remotestreamtimeout) becomes the socket's io_socket_timeout again once
    # the handshake is done -- LMS Async::write_async arms its "Timed out
    # waiting for data" timer from it, as with Net::HTTPS::NB::new.
    my $ioTimeout = $args{Timeout} || 30;

    if (!$noCache && defined(my $until = $unreachable{$cacheKey})) {
        my $left = $until - $clock->();
        if ($left > 0) {
            $@ = sprintf('proxy: unreachable (recent failure, retry in %ds)', POSIX::ceil($left));
            return undef;
        }
        delete $unreachable{$cacheKey};
    }

    my $deadline  = Time::HiRes::time() + HANDSHAKE_TIMEOUT;

    my %ssl = map { $_ => delete $args{$_} } grep { /^SSL_/ } keys %args;
    $ssl{SSL_hostname}      //= $host;
    $ssl{SSL_verifycn_name} //= $host;
    $ssl{SSL_verify_mode}   //= IO::Socket::SSL::SSL_VERIFY_NONE()
        if preferences('server')->get('insecureHTTPS');

    require Net::HTTP;    # loaded by Net::HTTPS::NB in LMS anyway

    # Net::HTTP parses PeerAddr as a URI authority: IPv6 needs brackets.
    my $sock = Net::HTTP->new(
        %args,
        PeerAddr => ($proxyAddr =~ /:/ ? "[$proxyAddr]" : $proxyAddr),
        PeerPort => $proxyPort,
        Blocking => 1,
        Timeout  => HANDSHAKE_TIMEOUT,
    ) or do {
        _markUnreachable($cacheKey);
        return _fail(undef, "proxy: cannot connect to $proxyAddr:$proxyPort: " . ($@ || $!));
    };

    my ($ok, $err) = _tunnel($sock, $host, $port, $deadline - Time::HiRes::time());
    unless ($ok) {
        _markUnreachable($cacheKey) if $err eq 'proxy: timeout';
        return _fail($sock, $err);
    }

    $class->start_SSL($sock, %ssl, SSL_startHandshake => 0, PeerHost => $host)
        or return _fail($sock, 'proxy: TLS setup failed: ' . IO::Socket::SSL::errstr());

    my $left = $deadline - Time::HiRes::time();
    if ($left <= 0) {
        _markUnreachable($cacheKey);
        return _fail($sock, 'proxy: timeout');
    }
    $sock->connect_SSL(Timeout => $left)
        or return _fail($sock, 'proxy: TLS handshake failed: ' . IO::Socket::SSL::errstr());

    delete $unreachable{$cacheKey};
    $sock->timeout($ioTimeout);
    $sock->blocking(0);
    return $sock;
}

# close() is inherited from Slim::Networking::Async::Socket::HTTPS, which
# removes the socket from Slim::Networking::Select (as LMS's HTTPSSocks does).

sub _markUnreachable {
    my ($key) = @_;
    $unreachable{$key} = $clock->() + NEGATIVE_CACHE_SECONDS;
}

sub _fail {
    my ($sock, $err) = @_;
    $sock->close if $sock;
    $@ = $err;
    return undef;
}

# Sends CONNECT on a connected blocking socket and reads the proxy's reply
# header block byte by byte, so no tunnel data is consumed.
# Returns (1, undef) on HTTP/1.x 200, else (0, 'proxy: ...').
sub _tunnel {
    my ($sock, $host, $port, $timeout) = @_;

    my $deadline  = Time::HiRes::time() + $timeout;
    my $authority = ($host =~ /:/ ? "[$host]" : $host) . ":$port";
    my $request   = "CONNECT $authority HTTP/1.1\r\nHost: $authority\r\n\r\n";
    my $sel       = IO::Select->new($sock);

    local $SIG{PIPE} = 'IGNORE';

    while (length $request) {
        my $left = $deadline - Time::HiRes::time();
        return (0, 'proxy: timeout') if $left <= 0 || !$sel->can_write($left);
        my $n = syswrite($sock, $request);
        return (0, 'proxy: connection closed') unless $n;
        substr($request, 0, $n, '');
    }

    my $response = '';
    while ($response !~ /\r\n\r\n\z/) {
        return (0, 'proxy: malformed response') if length $response >= MAX_RESPONSE;
        my $left = $deadline - Time::HiRes::time();
        return (0, 'proxy: timeout') if $left <= 0 || !$sel->can_read($left);
        my $n = sysread($sock, $response, 1, length $response);
        return (0, 'proxy: connection closed') unless $n;
    }

    my ($code, $reason) = $response =~ m{\AHTTP/1\.[01] (\d{3})(?: ([^\r\n]*))?\r\n}
        or return (0, 'proxy: malformed response');
    return (1, undef) if $code eq '200';

    $reason = defined $reason && length $reason ? " $reason" : '';
    return (0, "proxy: CONNECT rejected: $code$reason");
}

1;

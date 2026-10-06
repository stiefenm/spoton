package Plugins::SpotOn::Net::AsyncHTTP;

# Slim::Networking::Async::HTTP routed through the SpotOn network proxy:
# - https: the socket is a CONNECT tunnel (Net::Socket::HTTPSConnect); the
#   target hostname is not resolved by LMS's async DNS (skipDNS), the proxy
#   resolves it. Caveat: LMS Async::open still does a blocking local
#   gethostbyname for dotless names even with skipDNS -- all Spotify hosts
#   are dotted, so they are never resolved locally;
# - http:  classic absolute-URI request to the proxy (use_proxy).
# Every decision is taken from the *current* request URI, so redirects (LMS
# rewrites $self->request->uri and calls send_request again on this object)
# go through the proxy as well. Destinations bypassed by Net::proxyFor
# (localhost, 127.0.0.0/8, ::1) and "direct" overrides use the stock code.

use strict;
use warnings;

use base qw(Slim::Networking::Async::HTTP);

use Slim::Networking::Async::Socket::HTTP;
use Slim::Utils::Log;

use Plugins::SpotOn::Net qw(proxyFor);

my $log = logger('plugin.spoton');

# _spotonOverride: [ $proxy ] when the request params carried a proxyOverride
#                  key ($proxy: parseProxyUrl hashref, or undef = direct)
# _spotonProxyError: $@ of the last failed tunnel, reported instead of LMS's
#                  generic "Connect timed out"
__PACKAGE__->mk_accessor(rw => qw(_spotonOverride _spotonProxyError));

sub new {
    my ($class, $args) = @_;

    my $self = $class->SUPER::new($args);

    if (ref $args eq 'HASH' && exists $args->{proxyOverride}) {
        $self->_spotonOverride([ $args->{proxyOverride} ]);
    }

    return $self;
}

# ($host, $port) of the proxy for the current request, or ()
sub _proxy {
    my $self = shift;

    my $request = $self->request or return ();
    my $uri     = $request->uri  or return ();

    my $override = $self->_spotonOverride;
    return $override ? proxyFor($uri, $override->[0]) : proxyFor($uri);
}

sub _scheme {
    my $self = shift;
    my $request = $self->request or return '';
    return lc($request->uri->scheme || '');
}

sub _isTunnel {
    my $self = shift;
    my ($host) = $self->_proxy;
    return defined $host && $self->_scheme eq 'https';
}

# "host:port" for http through the proxy (absolute-URI request), else undef.
# https never uses this path: it is tunneled (see new_socket).
sub use_proxy {
    my $self = shift;

    my ($host, $port) = $self->_proxy;

    # bypassed destination or explicit "direct": unchanged LMS logic (webproxy)
    return $self->SUPER::use_proxy(@_) unless defined $host;

    return undef unless $self->_scheme eq 'http';
    return ($host =~ /:/ ? "[$host]" : $host) . ":$port";
}

sub new_socket {
    my $self = shift;

    my ($host, $port) = $self->_proxy;
    return $self->SUPER::new_socket(@_) unless defined $host;

    my $scheme = $self->_scheme;
    return $self->SUPER::new_socket(@_) unless $scheme eq 'https' || $scheme eq 'http';

    # merge with user-defined socket parameters (as LMS does)
    my %args = (@_, ($self->options ? %{ $self->options } : ()));

    main::INFOLOG && $log->info("via proxy $host:$port");

    if ($scheme eq 'http') {
        # Same as LMS's webproxy branch, without its "split /:/" (IPv6).
        return Slim::Networking::Async::Socket::HTTP->new(
            %args,
            PeerAddr => ($host =~ /:/ ? "[$host]" : $host),
            PeerPort => $port,
        );
    }

    $self->_spotonProxyError(undef);

    $args{SSL_hostname} //= $args{Host};
    # insecureHTTPS accessor: LMS 9.x (may be missing on older servers)
    $args{SSL_verify_mode} //= 0 if $self->can('insecureHTTPS') && $self->insecureHTTPS;    # SSL_VERIFY_NONE

    my $sock = eval { require Plugins::SpotOn::Net::Socket::HTTPSConnect; 1 }
        ? Plugins::SpotOn::Net::Socket::HTTPSConnect->new(%args, ProxyAddr => $host, ProxyPort => $port,
            # proxyOverride requests (settings Test button) always try for real
            ($self->_spotonOverride ? (NoNegativeCache => 1) : ()))
        : do { $@ = "proxy: TLS support unavailable: $@"; undef };

    $self->_spotonProxyError($@ || 'proxy: tunnel failed') unless $sock;

    return $sock;
}

# The target name must reach new_socket unresolved: the proxy resolves it
# (local DNS may be poisoned on the networks this feature is for). skipDNS
# skips LMS's async lookup; Async::open still resolves dotless names locally
# (not the case for any Spotify host).
sub write_async {
    my ($self, $args) = @_;

    $args->{skipDNS} = 1 if !$self->socket && $self->_isTunnel;

    return $self->SUPER::write_async($args);
}

# Slim::Networking::Async::connect reports a failed new_socket to onError as
# "Connect timed out: $!"; hand the tunnel's own "proxy: ..." error on instead.
sub connect {
    my ($self, $args) = @_;

    my $ecb = $args->{onError};
    return $self->SUPER::connect($args) unless $ecb;

    $self->_spotonProxyError(undef);

    local $args->{onError} = sub {
        my ($obj, $error, @pt) = @_;
        my $proxyError = $self->_spotonProxyError;
        $error = $proxyError if defined $proxyError;
        return $ecb->($obj, $error, @pt);
    };

    return $self->SUPER::connect($args);
}

1;

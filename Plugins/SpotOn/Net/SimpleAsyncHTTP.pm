package Plugins::SpotOn::Net::SimpleAsyncHTTP;

# Slim::Networking::SimpleAsyncHTTP whose transport is
# Plugins::SpotOn::Net::AsyncHTTP (network proxy). Only _createHTTPRequest
# is overridden: a copy of LMS 9.1's, with the Async::HTTP class swapped.
# (Slim::Networking::SimpleHTTP::Base is loaded by Slim::Networking::SimpleAsyncHTTP.)

use strict;
use warnings;

use base qw(Slim::Networking::SimpleAsyncHTTP);

use Plugins::SpotOn::Net::AsyncHTTP;

sub _createHTTPRequest {
    my $self = shift;

    # Not SUPER: Slim::Networking::SimpleAsyncHTTP::_createHTTPRequest would
    # itself send the request with a stock (direct) Async::HTTP. Skip a level,
    # exactly like LMS's own SUPER call from that class does.
    my ($request, $timeout) = $self->Slim::Networking::SimpleHTTP::Base::_createHTTPRequest(@_);

    # in case of a cached response we'd return without any response data
    return unless $request && $timeout;

    my $params = $self->_params || {};

    my $http = Plugins::SpotOn::Net::AsyncHTTP->new( $self->_params );
    $http->send_request( {
        request     => $request,
        maxRedirect => $params->{maxRedirect},
        saveAs      => $params->{saveAs},
        Timeout     => $timeout,
        onError     => \&Slim::Networking::SimpleAsyncHTTP::onError,
        onBody      => \&Slim::Networking::SimpleAsyncHTTP::onBody,
        passthrough => [ $self ],
    } );
}

1;

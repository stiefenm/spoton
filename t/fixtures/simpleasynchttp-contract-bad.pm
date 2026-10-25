package Fixtures::SimpleAsyncHTTPContractBad;
use strict;
use warnings;

# t/fixtures/simpleasynchttp-contract-bad.pm -- MUST-FAIL fixture for
# t/53_simpleasynchttp_contract.t's dry run (83.3-14 Task 2). Lives OUTSIDE
# Plugins/SpotOn so the real sweep never sees it; the dry run points
# SPOTON_CONTRACT_SWEEP_DIR at a temp copy of this file (plus the pre-fix
# Quality.pm) to prove the gate actually fails on real defective material
# before it is trusted on the fixed tree.
#
# One inline site and one named hand-off site, both calling an invented
# accessor (`statusLine`) that does not exist on the real SimpleAsyncHTTP
# class. Neither shape's minimum-count assertion is exercised here --
# override mode relaxes the assertion to "each shape matched >= 1" -- only
# the accessor-whitelist check is meant to fail against this file.

sub inlineSite {
    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $s = $http->statusLine;
        },
        sub {},
    )->get('x');
}

sub namedSite {
    Slim::Networking::SimpleAsyncHTTP->new(
        sub { _onDone(shift, 1) },
        sub {},
    )->get('y');
}

sub _onDone {
    my ($http, $flag) = @_;
    return $http->statusLine;
}

1;

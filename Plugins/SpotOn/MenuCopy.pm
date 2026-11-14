package Plugins::SpotOn::MenuCopy;

# 87.1-02 (GH #210, WR-02): copy of an OPML menu tree for the places where one
# is cached and handed out.
#
# XMLBrowser writes into the tree it is given (items, fetched, fetchSize, total
# and offset into intermediate levels, offset into every level it descends
# through). A cache that hands out the tree it stores therefore carries those
# writes into the next request, which then reads an empty slice. Copy at both
# boundaries: when a tree enters a cache and when it leaves one.
#
# Unblessed HASH and ARRAY containers are copied at every depth. Everything else
# is returned as it is: scalars, CODE refs (items carry url => \&_albumFeed, and
# Storable::dclone cannot copy those) and blessed refs, which are objects and not
# menu data. No Slim dependency, so the module loads in the unit tests without an
# LMS tree.

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(copyMenu);

sub copyMenu {
    my ($node) = @_;

    my $type = ref $node;
    return [ map { copyMenu($_) } @$node ]                           if $type eq 'ARRAY';
    return +{ map { $_ => copyMenu($node->{$_}) } keys %$node }      if $type eq 'HASH';

    return $node;
}

1;

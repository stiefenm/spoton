#!/usr/bin/perl
#
# tools/uat/menu-walk.pl -- walk the SpotOn OPML menus over LMS JSON-RPC (85 D-25 runtime layer).
#
# USAGE  menu-walk.pl --player <mac> [options]
#   --player <mac>        required; the LMS player the menu is asked for
#   --lms-url <url>       JSON-RPC endpoint (default http://127.0.0.1:9000/jsonrpc.js)
#   --cmd <name>          menu command (default spoton; spotoninfo reaches the TrackInfo menu
#                         that holds Add to Playlist)
#   --param <key:value>   repeatable; appended to every request (e.g. url:<spoton url> with
#                         --cmd spotoninfo)
#   --depth <n>           levels below the top level to walk (default 2)
#   --max-items <n>       items requested per node (default 100)
#   --search <term>       sent as search:<term> to every node of type search, and on every
#                         request in --path mode
#   --path <item_id|top>  repeatable; query only these nodes (top = the level without item_id),
#                         then list their children -- used to locate and fire one action node
#   --arm-webapi-log      before walking: debug network.asynchttp DEBUG, read it back, print ARMED
#   --timeout <s>         HTTP timeout per request in seconds, 1..900 (default 30); a cold open of a long
#                         list can take minutes (79-30), the default would read it as UNANSWERED
# Every node is one request [<mac>,[<cmd>,items,0,<max>,item_id:<id>,<params>,want_url:1]].
#
# OUTPUT (one line per fact, nothing else)
#   MENU <id> | <name> | type=<type> | count=<n> | hint=<text of a single textarea item, or ->
#         count is LMS's total for the level, not the number of items returned within --max-items
#   CHILD <child id> | <name> | type=<type> | url=<url or ->      (--path mode only)
#   UNANSWERED <id> | <name>          the reply had no result key (HTTP 200 is no execution receipt)
#   SKIPPED <id> | <name> | search node without --search
#   ARMED network.asynchttp=DEBUG at <HH:MM:SS.mmm>   read-back proved the switch (local time)
#   ARM_FAILED network.asynchttp=<value>
#   WALK_DONE menus=<n> unanswered=<k>
#
# EXIT  0 every node answered | 1 at least one UNANSWERED | 2 usage error / LMS unreachable
#       3 arm failed
#
# network.asynchttp is a RUNTIME switch: every LMS restart clears it, so the ARMED line is only
# the proof for the window that starts after its time. webapi-gate.pl reads that line.
# Core modules only. Prints menu names and counts, never an account identity or a credential.

use strict;
use warnings;
use JSON::PP;
use HTTP::Tiny;
use Getopt::Long qw(GetOptions);
use Time::HiRes qw(gettimeofday);
use POSIX qw(strftime);

# Names arrive as decoded characters (decode_json); without an encoding layer a name with an umlaut
# is written as a Latin-1 byte and every UTF-8 pattern in the plan verify commands misses it (85-16).
binmode(STDOUT, q(:encoding(UTF-8)));

my %o = (lms_url => 'http://127.0.0.1:9000/jsonrpc.js', cmd => 'spoton', depth => 2, max_items => 100, timeout => 30);
my (@params, @paths);
GetOptions(
    'player=s'        => \$o{player},
    'lms-url=s'       => \$o{lms_url},
    'cmd=s'           => \$o{cmd},
    'param=s'         => \@params,
    'depth=i'         => \$o{depth},
    'max-items=i'     => \$o{max_items},
    'search=s'        => \$o{search},
    'path=s'          => \@paths,
    'arm-webapi-log'  => \$o{arm},
    'timeout=i'       => \$o{timeout},
) or usage_exit();
usage_exit() unless defined $o{player} && length $o{player};
usage_exit() if $o{max_items} < 1 || $o{depth} < 0;
usage_exit() if $o{timeout} < 1 || $o{timeout} > 900;

my $http = HTTP::Tiny->new(timeout => $o{timeout});
my $first_request = 1;

sub usage_exit {
    print STDERR "usage: menu-walk.pl --player <mac> [--lms-url U] [--cmd C] [--param k:v]... [--depth N] "
        . "[--max-items N] [--search T] [--path ID|top]... [--arm-webapi-log] [--timeout S]  (see header)\n";
    exit 2;
}

sub clean { my ($s) = @_; return '-' unless defined $s && length $s; $s =~ s/[\r\n\t]+/ /g; $s =~ s/\|/\//g; return $s; }

# One JSON-RPC call. Returns the decoded reply hash, or undef when the reply carried no usable JSON.
# A refused connection on the very first request is "LMS unreachable" (exit 2); afterwards a failed
# request is simply an unanswered node.
sub rpc {
    my ($player, $cmd) = @_;
    my $body = encode_json({ id => 1, method => 'slim.request', params => [$player, $cmd] });
    my $res = $http->post($o{lms_url}, { headers => { 'Content-Type' => 'application/json' }, content => $body });
    if ($first_request) {
        $first_request = 0;
        if (!$res->{success} && ($res->{content} // '') =~ /Could not connect|Connection refused/i) {
            print STDERR "LMS unreachable at $o{lms_url}\n";
            exit 2;
        }
    }
    return undef unless $res->{success};
    my $d = eval { decode_json($res->{content} // '') };
    return ref $d eq 'HASH' ? $d : undef;
}

sub stamp {
    my ($s, $us) = gettimeofday();
    return sprintf('%s.%03d', strftime('%H:%M:%S', localtime $s), int($us / 1000));
}

if ($o{arm}) {
    rpc('', ['debug', 'network.asynchttp', 'DEBUG']);
    my $r = rpc('', ['debug', 'network.asynchttp', '?']);
    my $v = (ref $r eq 'HASH' && ref $r->{result} eq 'HASH' && defined $r->{result}{_value}) ? $r->{result}{_value} : '<empty>';
    if ($v ne 'DEBUG') {
        print "ARM_FAILED network.asynchttp=$v\n";
        exit 3;
    }
    print 'ARMED network.asynchttp=DEBUG at ' . stamp() . "\n";
}

my ($menus, $unanswered) = (0, 0);

# Query one node; prints MENU (or UNANSWERED) and returns the reply's items (arrayref) or undef.
sub query_node {
    my ($id, $name, $type, $path_mode) = @_;
    $menus++;
    my @cmd = ($o{cmd}, 'items', '0', "$o{max_items}");
    push @cmd, "item_id:$id" unless $id eq 'top';
    push @cmd, @params;
    push @cmd, "search:$o{search}" if defined $o{search} && ($path_mode || (defined $type && $type eq 'search'));
    push @cmd, 'want_url:1';
    my $r = rpc($o{player}, \@cmd);
    if (!(ref $r eq 'HASH' && ref $r->{result} eq 'HASH')) {
        $unanswered++;
        print 'UNANSWERED ' . clean($id) . ' | ' . clean($name) . "\n";
        return undef;
    }
    my $res = $r->{result};
    my $items = ref $res->{loop_loop} eq 'ARRAY' ? $res->{loop_loop}
              : ref $res->{item_loop} eq 'ARRAY' ? $res->{item_loop} : [];
    my $count = defined $res->{count} ? $res->{count} : scalar @$items;
    my $hint = '-';
    if (@$items == 1 && defined $items->[0]{type} && $items->[0]{type} eq 'textarea') {
        $hint = clean($items->[0]{name});
    }
    $name = $res->{title} if $path_mode;
    printf "MENU %s | %s | type=%s | count=%s | hint=%s\n", clean($id), clean($name), clean($type), clean($count), $hint;
    return $items;
}

sub walk {
    my ($id, $name, $type, $level) = @_;
    my $items = query_node($id, $name, $type, 0);
    return unless $items && $level < $o{depth};
    for my $it (@$items) {
        next unless ref $it eq 'HASH' && defined $it->{id};
        next if $it->{isaudio} || !$it->{hasitems};
        my $t = $it->{type} // '-';
        if ($t eq 'search' && !defined $o{search}) {
            print 'SKIPPED ' . clean($it->{id}) . ' | ' . clean($it->{name}) . " | search node without --search\n";
            next;
        }
        walk($it->{id}, $it->{name}, $t, $level + 1);
    }
}

if (@paths) {
    for my $p (@paths) {
        my $items = query_node($p, '-', '-', 1);
        next unless $items;
        for my $it (@$items) {
            next unless ref $it eq 'HASH';
            printf "CHILD %s | %s | type=%s | url=%s\n", clean($it->{id}), clean($it->{name}), clean($it->{type}), clean($it->{url});
        }
    }
}
else {
    walk('top', 'top', '-', 0);
}

print "WALK_DONE menus=$menus unanswered=$unanswered\n";
exit($unanswered ? 1 : 0);

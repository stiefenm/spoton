#!/usr/bin/env bash
# tools/ci/d15-port-gate.sh -- Phase 85 D-15 order gate: every Web-API data method is ported
# BEFORE the auth switch (85-10) and before anything is deleted. Run green by 85-09.
#
# USAGE  d15-port-gate.sh [root]     root = checkout (or archive copy) holding Plugins/SpotOn;
#                                    default .
# OUTPUT (one line per fact)
#   PURE_DELEGATION <name>          a SpClient.pm sub (name not starting with _) that only hands the
#                                   call to API::Client: its body mentions API::Client or
#                                   _delegateToClient and calls no other $class->method( (a native
#                                   spclient path with a fallback closure is NOT a delegation)
#   WEBAPI_CALLER <file>:<line>     a product caller of a Web-API data method (API::Client->getQueue,
#                                   getTopTracks, search, saveTracks ..., player*, statusSnapshot,
#                                   getLimit, limitsProbed, probeEndpointLimits) outside
#                                   API/Client.pm and API/SpClient.pm
#   EXEMPT_CALLED <file>:<line>     a call of SpClient->getMe or _fetchAllPersonalMixes( -- the two
#                                   delegations getMe/getPersonalMixes are exempt from PURE_DELEGATION
#                                   only while no such call exists
#   PATHFINDER_HOST_OUTSIDE <file>:<line>
#                                   a non-comment line naming api-partner.spotify.com in a .pm other
#                                   than Plugins/SpotOn/API/Pathfinder.pm (check 4, decision-D17:
#                                   the Pathfinder host lives in its own module only)
# LAST LINE  D15_GATE=PASS                                           (exit 0)
#            D15_GATE=FAIL pure=<n> callers=<m> exempt=<k> pf=<j>    (exit 1)
# EXIT  0 PASS | 1 FAIL | 2 root has no Plugins/SpotOn/API/SpClient.pm
# Core tools only (bash + one perl -0777 pass); comment lines never count.
set -u
export LC_ALL=C

ROOT=${1:-.}
SP="$ROOT/Plugins/SpotOn/API/SpClient.pm"
[ -f "$SP" ] || { echo "no Plugins/SpotOn/API/SpClient.pm under $ROOT" >&2; exit 2; }

OUT=$(perl -0777 -e '
    use strict; use warnings;
    my ($root) = @ARGV;
    my $app = "$root/Plugins/SpotOn";

    sub slurp { my ($f) = @_; open(my $fh, "<", $f) or die "cannot read $f: $!"; local $/; my $t = <$fh>; close $fh; return $t; }
    sub noncomment { my ($f) = @_; open(my $fh, "<", $f) or die "cannot read $f: $!";
        local $/ = "\n";   # -0777 slurps; line numbers need real lines
        my @l; while (my $x = <$fh>) { chomp $x; push @l, [$., $x] unless $x =~ /^\s*#/; } close $fh; return @l; }

    my @pm;
    sub walk { my ($d) = @_; opendir(my $dh, $d) or die "cannot opendir $d: $!";
        for my $e (sort grep { !/^\./ } readdir $dh) { my $p = "$d/$e";
            if (-d $p) { walk($p) } elsif ($e =~ /\.pm\z/) { push @pm, $p } } closedir $dh; }
    walk($app);

    # check 3 first: the exemptions of check 1 hold only while it is clean
    my @exempt;
    for my $f (@pm) {
        (my $rel = $f) =~ s{^\Q$root\E/}{};
        for my $l (noncomment($f)) {
            my ($n, $t) = @$l;
            push @exempt, "EXEMPT_CALLED $rel:$n" if $t =~ /SpClient->getMe\b/;
            push @exempt, "EXEMPT_CALLED $rel:$n" if $t =~ /_fetchAllPersonalMixes\b/ && $t !~ /^\s*sub\s+_fetchAllPersonalMixes\b/;
        }
    }

    # check 1: pure delegations in SpClient.pm
    my @pure;
    my $src = slurp("$app/API/SpClient.pm");
    while ($src =~ /^sub (\w+) \{\n(.*?)^\}\n/msg) {
        my ($name, $body) = ($1, $2);
        next if $name =~ /^_/;
        next if !@exempt && ($name eq "getMe" || $name eq "getPersonalMixes");
        $body = join "", grep { !/^\s*#/ } split /^/, $body;
        next unless $body =~ /API::Client|_delegateToClient/;
        my @native = grep { $_ ne "_delegateToClient" && $_ ne "_hasLogin5Creds" } $body =~ /\$class->(\w+)\(/g;
        push @pure, "PURE_DELEGATION $name" unless @native;
    }

    # check 2: product callers of Web-API data methods
    my $re = qr/API::Client->(?:getQueue|getTopTracks|search|saveTracks|removeTracks|checkTracks|saveShows|removeShows|checkShows|addToPlaylist|pathfinderHome|getWebPlayerPlaylistItems|getTrack|player[A-Z]\w*|statusSnapshot|getLimit|limitsProbed|probeEndpointLimits)\b/;
    my @callers;
    for my $f (@pm) {
        next if $f =~ m{/API/(?:Client|SpClient)\.pm\z};
        (my $rel = $f) =~ s{^\Q$root\E/}{};
        for my $l (noncomment($f)) { push @callers, "WEBAPI_CALLER $rel:$l->[0]" if $l->[1] =~ $re; }
    }

    # check 4: the Pathfinder host only in API/Pathfinder.pm (same @pm list, same comment rule)
    my @pf;
    for my $f (@pm) {
        next if $f =~ m{/API/Pathfinder\.pm\z};
        (my $rel = $f) =~ s{^\Q$root\E/}{};
        for my $l (noncomment($f)) { push @pf, "PATHFINDER_HOST_OUTSIDE $rel:$l->[0]" if $l->[1] =~ /api-partner\.spotify\.com/; }
    }

    print "$_\n" for @pure, @callers, @exempt, @pf;
    print "D15_COUNTS pure=" . scalar(@pure) . " callers=" . scalar(@callers) . " exempt=" . scalar(@exempt) . " pf=" . scalar(@pf) . "\n";
' "$ROOT") || { echo "d15-port-gate: scan failed" >&2; exit 2; }

printf '%s\n' "$OUT" | command grep -v '^D15_COUNTS '
COUNTS=$(printf '%s\n' "$OUT" | command grep '^D15_COUNTS ' | sed 's/^D15_COUNTS //')
P=${COUNTS#pure=}; P=${P%% *}
C=${COUNTS#*callers=}; C=${C%% *}
E=${COUNTS#*exempt=}; E=${E%% *}
F=${COUNTS#*pf=}; F=${F%% *}
if [ "$P" = 0 ] && [ "$C" = 0 ] && [ "$E" = 0 ] && [ "$F" = 0 ]; then
    echo "D15_GATE=PASS"
    exit 0
fi
echo "D15_GATE=FAIL pure=$P callers=$C exempt=$E pf=$F"
exit 1

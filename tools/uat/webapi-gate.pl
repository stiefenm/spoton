#!/usr/bin/perl
#
# tools/uat/webapi-gate.pl -- 85 D-25 runtime verdict: did any request reach api.spotify.com?
#
# USAGE  webapi-gate.pl --extract <extract-run output file> --walk <menu-walk output file> --from <HH:MM:SS>
#   --extract <file>   saved stdout of tools/uat/extract-run.pl for the window under test
#   --walk <file>      saved stdout of tools/uat/menu-walk.pl --arm-webapi-log (holds the ARMED line)
#   --from <HH:MM:SS>  start of the window under test (local time, same clock as the ARMED line)
#
# The verdict is recomputed from those two files, never from prose an executor wrote. Absence of a
# line proves nothing on its own (extract-run rule 4), so a PASS needs all of: the ARMED line at or
# before --from, the extract category section, a covered server.log window, and zero request lines.
#
# OUTPUT  webapi_lines=<n>   then the LAST line:
#   WEBAPI_GATE=PASS webapi_lines=0                              (exit 0)
#   WEBAPI_GATE=FAIL webapi_lines=<n> reason=<word>              (exit 1)
# REASON WORDS (checked in this order)
#   not_armed_before_window  no ARMED network.asynchttp=DEBUG line, an ARM_FAILED line, or the latest
#                            ARMED time lies after --from
#   category_missing         the extract output has no `server.log: Web API request` section
#   window_not_covered       the server.log coverage line is a `!!` not-checked form, or absent
#   webapi_requests          the section prints at least one line naming api.spotify.com
# EXIT  0 PASS | 1 FAIL | 2 usage error / unreadable file
#
# Core modules only.

use strict;
use warnings;
use Getopt::Long qw(GetOptions);

my %o;
GetOptions('extract=s' => \$o{extract}, 'walk=s' => \$o{walk}, 'from=s' => \$o{from}) or usage_exit();
usage_exit() unless defined $o{extract} && defined $o{walk} && defined $o{from};
usage_exit() unless $o{from} =~ /^(\d{1,2}):(\d{2}):(\d{2})(?:\.(\d+))?$/;
my $from = hms($1, $2, $3, $4);

sub usage_exit {
    print STDERR "usage: webapi-gate.pl --extract <file> --walk <file> --from <HH:MM:SS>  (see header)\n";
    exit 2;
}

sub hms {
    my ($h, $m, $s, $frac) = @_;
    return $h * 3600 + $m * 60 + $s + (defined $frac && length $frac ? "0.$frac" : 0);
}

sub slurp_lines {
    my ($f) = @_;
    open(my $fh, '<', $f) or do { print STDERR "cannot read $f: $!\n"; exit 2; };
    my @l = <$fh>;
    close $fh;
    chomp @l;
    return @l;
}

sub verdict {
    my ($n, $reason) = @_;
    print "webapi_lines=$n\n";
    if ($reason) { print "WEBAPI_GATE=FAIL webapi_lines=$n reason=$reason\n"; exit 1; }
    print "WEBAPI_GATE=PASS webapi_lines=$n\n";
    exit 0;
}

my @walk = slurp_lines($o{walk});
my @ext  = slurp_lines($o{extract});

# 1. armed before the window -- the LATEST ARMED line decides, an ARM_FAILED line voids the proof
my ($armed, $armed_ok) = (undef, 1);
for my $l (@walk) {
    $armed_ok = 0 if $l =~ /^ARM_FAILED\b/;
    if ($l =~ /^ARMED network\.asynchttp=DEBUG at (\d{1,2}):(\d{2}):(\d{2})(?:\.(\d+))?\s*$/) {
        $armed = hms($1, $2, $3, $4);
    }
}
verdict(0, 'not_armed_before_window') if !$armed_ok || !defined $armed || $armed > $from;

# 2. the category section (heading as emit_categories prints it: `--- <name>[ (Anzahl: ...)] ---`)
my $head = qr/^--- server\.log: Web API request \(api\.spotify\.com;/;
my ($start) = grep { $ext[$_] =~ $head } 0 .. $#ext;
verdict(0, 'category_missing') unless defined $start;

# 3. the server.log window is covered (extract-run rule 4: absence is not refutation)
my $covered = grep { /^Abdeckung server\.log: erste Zeile/ } @ext;
my $not_covered = grep { /^!! (?:Abdeckung server\.log:|server\.log deckt das Fenster NICHT ab|server\.log hat 0 Bytes)/ } @ext;
verdict(0, 'window_not_covered') if !$covered || $not_covered;

# 4. count the request lines of the section (the heading and the not-found marker carry the category
#    name, which itself names api.spotify.com -- neither is a request line)
my $n = 0;
for my $i ($start + 1 .. $#ext) {
    last if $ext[$i] eq '' || $ext[$i] =~ /^--- /;
    next if $ext[$i] =~ /^\[MUSTER NICHT GEFUNDEN IM FENSTER\]/;
    $n++ if $ext[$i] =~ /api\.spotify\.com/;
}
verdict($n, $n ? 'webapi_requests' : undef);

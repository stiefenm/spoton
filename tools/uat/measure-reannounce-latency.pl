#!/usr/bin/perl

# tools/uat/measure-reannounce-latency.pl
#
# 82-38 Task 2: N-Wiederholungs-Messtreiber fuer die neue Opt-in-LMS-
# Reanforderung aus tools/soloist-ws-record.pl (T-3 Option a,
# .planning/notes/soloist-neuausrichtung-plan.md §3). Treibt run_recorder()
# mindestens 20-mal gegen einen ECHTEN vendorierten Protocol::WebSocket::
# Client (kein Test::More-Mock -- t/43_soloist_ws_record.t installiert
# einen %INC-Stub, dieser Treiber tut das bewusst NICHT: das wuerde genau
# den echten Handshake unterlaufen, den dieser Treiber messen soll) und
# gegen den ECHTEN lokalen LMS-Prozess (seiteneffektfreier serverstatus-
# Aufruf, kein Playback-Eingriff -- derselbe Aufruf wie
# tools/uat/pre-scenario-gate.sh Tor 1).
#
# Der Daemon-seitige WS-Handshake wird je Wiederholung von einem geforkten
# Kind bedient, das eine ECHTE HTTP/1.1 101-Antwort mit korrekt berechnetem
# Sec-WebSocket-Accept zurueckschreibt -- Plugins/SpotOn/Vendor/Protocol/
# WebSocket/Response.pm::_parse_first_line verlangt exakt diese Statuszeile;
# ein reines Bytespiegeln der Client-Anfrage wuerde den connect-Callback nie
# feuern lassen und dieser Treiber liefert dann durchgehend n=0/20 gueltige
# Wiederholungen.
#
# Prozessmodell: run_recorder() kehrt erst nach `seconds` zurueck und liest
# die 101-Antwort in seinem EIGENEN select-Loop -- im selben Prozess kann
# daher NIE parallel ein Responder auf der anderen Haelfte bedient werden.
# Deshalb ein fork() je Wiederholung; das Kind haelt seine Haelfte offen,
# bis der Elternprozess (run_recorder) sein Ende schliesst (sysread liefert
# dann 0), und beendet sich dann selbst -- der Elternprozess sammelt es per
# waitpid ein.
#
# Ausgabe: eine LATENZ-ERGEBNIS-Zeile mit vollstaendiger Verteilung
# (mean/median/min/max/stdev) ueber die dispatch_ms-Werte der gueltigen
# (REANFORDERUNG OK) Wiederholungen. REANFORDERUNG-UNGUELTIG-Wiederholungen
# werden separat gezaehlt, fliessen NICHT in die Statistik ein.

use strict;
use warnings;

use FindBin qw($RealBin);

# 82-38 Code-Review Runde 3, Warnung 1: soloist-ws-record.pl:60-62 setzt
# seinen eigenen use-lib-Pfad relativ zu FindBin::RealBin des LAUFENDEN
# Skripts (also DIESES Skripts, nicht der gleich geforderten Datei) --
# FindBin bindet $RealBin einmalig an $0 fuer den gesamten Prozess. Aus
# tools/uat/ heraus zeigt soloist-ws-record.pls eigener
# "$RealBin/../Plugins/SpotOn/Vendor" deshalb auf das NICHT existierende
# tools/Plugins/SpotOn/Vendor, und das require unten wuerde mit
# "Can't locate Protocol/WebSocket/Client.pm in @INC" abbrechen (das Modul
# ist systemweit nicht installiert). Der korrekte Pfad MUSS deshalb VOR dem
# require selbst vorangestellt werden -- require durchsucht @INC vollstaendig,
# also reicht es, dass unser Eintrag IRGENDWO in @INC steht.
use lib "$RealBin/../../Plugins/SpotOn/Vendor";

require "$RealBin/../soloist-ws-record.pl";

use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use Digest::SHA qw(sha1);
use MIME::Base64 qw(encode_base64);
use File::Temp qw(tempdir);
use List::Util qw(sum min max);

my $LMS_URL      = 'http://127.0.0.1:9000/jsonrpc.js';
my $REANNOUNCE   = '["","serverstatus","0","1"]';
my $MIN_VALID    = 20;   # must_haves: mindestens 20 GUELTIGE Wiederholungen
my $MAX_ATTEMPTS = 40;   # Sicherheitsdeckel gegen eine dauerhaft kaputte LMS-Verbindung
my $RUN_SECONDS  = 3;    # run_recorder()s Gesamtlaufzeit je Wiederholung

# 82-41 Task 3 (R9-WR-03): $tmp zieht in main() um -- ein require dieses
# Skripts fuer Tests (compute_latency_stats isoliert nutzbar machen) soll
# keinen Tempdir anlegen, den niemand ausser dem echten Messlauf braucht.

# ------------------------------------------------------------
# serve_ws_handshake($sock) -- laeuft im geforkten Kind: liest die
# Client-Handshake-Anfrage, berechnet den echten Sec-WebSocket-Accept-Wert
# (RFC 6455), schreibt die 101-Antwort zurueck, und haelt die Verbindung
# offen, bis der Elternprozess sie schliesst.
# ------------------------------------------------------------
sub serve_ws_handshake {
    my ($sock) = @_;

    my $buf = '';
    while ($buf !~ /\r\n\r\n/) {
        my $n = sysread($sock, my $chunk, 65536);
        last unless defined $n && $n > 0;
        $buf .= $chunk;
    }

    my ($key) = $buf =~ /Sec-WebSocket-Key:\s*(\S+)/i;
    if (defined $key) {
        my $accept = encode_base64(sha1($key . '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'), '');
        my $resp = "HTTP/1.1 101 Switching Protocols\r\n"
                 . "Upgrade: websocket\r\n"
                 . "Connection: Upgrade\r\n"
                 . "Sec-WebSocket-Accept: $accept\r\n\r\n";
        syswrite($sock, $resp);
    }

    # Haelfte offenhalten, bis der Elternprozess (run_recorder) sein Ende
    # schliesst -- genau dann liefert sysread 0 und dieses Kind beendet sich.
    while (1) {
        my $n = sysread($sock, my $discard, 65536);
        last if !defined $n || $n == 0;
    }
}

# ------------------------------------------------------------
# run_one_measurement($out_file) -- eine Wiederholung: forkt den
# WS-Handshake-Responder, ruft run_recorder() im Elternprozess auf, sammelt
# das Kind per waitpid ein. Rueckgabe: die REANFORDERUNG-Meta-Zeile (als
# dekodierter Hash) oder undef, wenn keine gefunden wurde.
# ------------------------------------------------------------
sub run_one_measurement {
    my ($out_file) = @_;

    socketpair(my $daemon_a, my $daemon_b, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die "socketpair: $!";

    my $pid = fork();
    die "fork failed: $!" unless defined $pid;

    if ($pid == 0) {
        close($daemon_a);
        serve_ws_handshake($daemon_b);
        exit(0);
    }

    close($daemon_b);

    run_recorder({
        host           => '127.0.0.1',
        sock           => $daemon_a,
        client_factory => sub { Protocol::WebSocket::Client->new(@_) },
        reannounce_lms => $REANNOUNCE,
        lms_url        => $LMS_URL,
        out            => $out_file,
        seconds        => $RUN_SECONDS,
    });
    waitpid($pid, 0);

    open(my $fh, '<', $out_file) or die "cannot read $out_file: $!";
    local $/;
    my $content = <$fh>;
    close($fh);

    for my $line (split /\n/, ($content // '')) {
        next unless length $line;
        my $rec = eval { decode_json($line) };
        next if $@ || ref($rec) ne 'HASH';
        my $frame = $rec->{frame} // '';
        if ($frame =~ /^REANFORDERUNG (OK|UNGUELTIG)/) {
            return $frame;
        }
    }
    return undef;
}

# ------------------------------------------------------------
# _stats_for(@vals) -- mean/median/min/max/stdev fuer eine flache Liste von
# Zahlen. Reine Hilfsfunktion, kein Seiteneffekt, von compute_latency_stats
# fuer dispatch_ms UND roundtrip_ms gleichermassen benutzt.
# ------------------------------------------------------------
sub _stats_for {
    my (@vals) = @_;
    my $n = scalar @vals;
    return (0, 0, 0, 0, 0) unless $n > 0;
    my $mean = sum(@vals) / $n;
    my @sorted = sort { $a <=> $b } @vals;
    my $median = ($n % 2 == 1)
        ? $sorted[($n - 1) / 2]
        : ($sorted[$n / 2 - 1] + $sorted[$n / 2]) / 2;
    my $mn = min(@vals);
    my $mx = max(@vals);
    my $variance = sum(map { ($_ - $mean) ** 2 } @vals) / $n;
    my $stdev = sqrt($variance);
    return ($mean, $median, $mn, $mx, $stdev);
}

# ------------------------------------------------------------
# compute_latency_stats(\@dispatch_ms, \@roundtrip_ms, $min_valid) -- R9-WR-03:
# extracted so the status decision (faellt sie tatsaechlich auf
# GRENZWERT_VERFEHLT?) is reachable with SYNTHETIC values in a test -- real
# live runs report dispatch_ms in the microsecond range, never near the 9.0ms
# threshold, so the "faellt"-branch was practically unreachable before this
# extraction. roundtrip_ms is now reported (mean/median/min/max/stdev)
# instead of being silently discarded (the previous code captured $2 from
# the REANFORDERUNG-OK match but never stored it).
# ------------------------------------------------------------
sub compute_latency_stats {
    my ($dispatch_ms_ref, $roundtrip_ms_ref, $min_valid) = @_;
    my @dispatch_ms  = @{ $dispatch_ms_ref  || [] };
    my @roundtrip_ms = @{ $roundtrip_ms_ref || [] };
    my $n_valid = scalar @dispatch_ms;

    my %stats = (n_valid => $n_valid);
    @stats{qw(dispatch_mean dispatch_median dispatch_min dispatch_max dispatch_stdev)}
        = _stats_for(@dispatch_ms);
    @stats{qw(roundtrip_mean roundtrip_median roundtrip_min roundtrip_max roundtrip_stdev)}
        = _stats_for(@roundtrip_ms);

    # status=OK nur, wenn dispatch_ms-Mittelwert UND -Median unter 9.0 liegen
    # UND genug gueltige Wiederholungen vorliegen -- das Maximum wird IMMER
    # mitberichtet, auch wenn es ueber 9,0 ms liegt (kein Verschweigen eines
    # Ausreissers). WICHTIG (R9-WR-03): dieser Vergleich bewertet
    # AUSSCHLIESSLICH den clientseitigen dispatch_ms (syswrite-Dauer) -- er
    # ist KEIN Vergleich gegen die LMS-seitig aus server.log gemessene
    # 9,0-ms-Grenze aus 82-36 (strukturell andere Groessen: clientseitiger
    # Dispatch vs. LMS-server.log-Zeitstempel). roundtrip_ms wird oben
    # separat berichtet, fliesst aber NICHT in diese Statusentscheidung ein.
    $stats{status} = ($n_valid >= $min_valid
                       && $stats{dispatch_mean} < 9.0
                       && $stats{dispatch_median} < 9.0)
        ? 'OK' : 'GRENZWERT_VERFEHLT';

    return \%stats;
}

# ------------------------------------------------------------
# run_measurement_loop() -- der echte Messlauf: mindestens $MIN_VALID
# gueltige Wiederholungen, gedeckelt bei $MAX_ATTEMPTS Gesamtversuchen.
# Hinter `unless caller` (Vorbild tools/soloist-ws-record.pl:731), damit
# ein `require` dieses Skripts fuer Tests compute_latency_stats isoliert
# nutzbar macht, OHNE den echten Messlauf (Fork, echter lokaler
# LMS-Aufruf) auszuloesen. NICHT `main` genannt: dieses Skript require't
# tools/soloist-ws-record.pl (Zeile 55) in dasselbe main::-Package --
# jenes Skript definiert SELBST ein main::main, das eine gleichnamige Sub
# hier stillschweigend ueberschreiben wuerde (Compile-Reihenfolge: das
# require laeuft NACH der Kompilierung dieser Datei, aber die kompilierte
# main::main dieser Datei stuende dann trotzdem am Ende auf die
# CLI-Optionsverarbeitung von soloist-ws-record.pl, nicht auf diesen
# Messlauf).
# ------------------------------------------------------------
sub run_measurement_loop {
    my $tmp = tempdir(CLEANUP => 1);

    my @dispatch_ms;
    my @roundtrip_ms;
    my $invalid_count = 0;
    my $attempts = 0;

    while (@dispatch_ms < $MIN_VALID && $attempts < $MAX_ATTEMPTS) {
        $attempts++;
        my $out_file = "$tmp/rep-$attempts.jsonl";
        my $frame = run_one_measurement($out_file);

        if (!defined $frame) {
            warn "WARNUNG: Wiederholung $attempts lieferte keine REANFORDERUNG-Zeile ($out_file)\n";
            next;
        }

        if ($frame =~ /^REANFORDERUNG OK dispatch_ms=([0-9.]+)\s+roundtrip_ms=([0-9.]+)/) {
            push @dispatch_ms, $1 + 0;
            push @roundtrip_ms, $2 + 0;
        } elsif ($frame =~ /^REANFORDERUNG UNGUELTIG:\s*(.*)$/) {
            $invalid_count++;
            warn "UNGUELTIG (Wiederholung $attempts): $1\n";
        }
    }

    my $n_total = $attempts;
    my $stats = compute_latency_stats(\@dispatch_ms, \@roundtrip_ms, $MIN_VALID);

    printf "LATENZ-ERGEBNIS: n=%d/%d mean=%.3fms median=%.3fms min=%.3fms max=%.3fms stdev=%.3fms roundtrip_mean_ms=%.3f roundtrip_median_ms=%.3f status=%s\n",
        $stats->{n_valid}, $n_total,
        $stats->{dispatch_mean}, $stats->{dispatch_median}, $stats->{dispatch_min}, $stats->{dispatch_max}, $stats->{dispatch_stdev},
        $stats->{roundtrip_mean}, $stats->{roundtrip_median},
        $stats->{status};

    return 0;
}

run_measurement_loop() unless caller;

1;

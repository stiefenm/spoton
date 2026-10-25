#!/usr/bin/perl
#
# tools/uat/instrument-probe.pl
#
# Sonde ueber Archivmaterial fuer Phase 83-05 ("Instrumente vermessen, bevor
# gemessen wird"). Beantwortet die fuenf Instrumentenfragen I-1..I-5 aus
# vorhandenem Mitschnitt- und Daemon-Log-Material -- kein Geraet, kein
# LMS-Eingriff, kein Hoerbefund.
#
# Zwei Regeln bestimmen die Bauform, fuer alle Unterbefehle gleich (Auftrag
# 83-05-PLAN.md Task 1):
#   1. Jede Datensatzzeile beginnt mit <pfad>:<zeile>, 1-basiert, die Zeile
#      des Frames selbst.
#   2. Nichts wird still verworfen -- jede nicht erkennbare Zeile geht in
#      einen Restzaehler, der immer ausgegeben wird, auch bei null.
#
# Unterbefehle: ws-cadence, ws-handshake, ticker, blocks, transitions,
# stillstand.
#
# Reines Perl mit Kernmodulen (strict, warnings, JSON::PP), Modulino-
# Konvention wie tools/uat/extract-run.pl: main(@ARGV) laeuft nur beim
# Direktaufruf, nicht per require.

use strict;
use warnings;
use JSON::PP ();
use Time::Local ();

my $JSON = JSON::PP->new->utf8(0)->canonical(0);

# ---------------------------------------------------------------------------
# Hilfe

sub usage {
    return <<'USAGE';
tools/uat/instrument-probe.pl -- Sonde ueber Archivmaterial (Phase 83-05)

Usage:
  tools/uat/instrument-probe.pl ws-cadence <fixture.jsonl...>
  tools/uat/instrument-probe.pl ws-handshake <fixture.jsonl...>
  tools/uat/instrument-probe.pl ticker <daemon.log>
  tools/uat/instrument-probe.pl blocks <daemon.log>
  tools/uat/instrument-probe.pl transitions <daemon.log>
  tools/uat/instrument-probe.pl stillstand <daemon.log>
  tools/uat/instrument-probe.pl --help | -h

Jede Datensatzzeile beginnt mit <pfad>:<zeile>. Restzaehler werden immer
ausgegeben, auch bei null. Reines Perl mit Kernmodulen.
USAGE
}

# ---------------------------------------------------------------------------
# Gemeinsames Frame-Parsing ueber WS-Mitschnitte (flaches Recorder-Schema
# ODER Alt-Schema mit #ts=-Kommentarzeile). Schema-Erkennung je Zeile.
#
# Liefert eine Liste von Records:
#   { line => <1-basiert>, dir => 'rx'|'tx'|'meta'|undef,
#     type => <string|undef>, epoch => <num|undef>, raw => <decoded hashref|undef>,
#     residual => 0|1, meta_marker => <string|undef> }
#
# $residual_ref wird als Skalarreferenz mitgegeben und mitgezaehlt (fuer
# Aufrufer, die nur die Gesamtzahl brauchen); die volle Liste traegt residual
# je Zeile ohnehin mit.

sub parse_ws_fixture {
    my ($path) = @_;
    open my $fh, '<', $path or die "FATAL: kann $path nicht lesen: $!\n";
    my @records;
    my $pending_epoch;
    my $pending_ts;
    my $lineno = 0;
    while (my $line = <$fh>) {
        $lineno++;
        chomp $line;
        next if $line eq '';

        if ($line =~ /^#ts=(\S+)\s+epoch=(\S+)/) {
            $pending_ts    = $1;
            $pending_epoch = $2;
            next;
        }

        my $decoded = eval { $JSON->decode($line) };
        if (!defined $decoded || ref($decoded) ne 'HASH') {
            push @records, { line => $lineno, residual => 1 };
            next;
        }

        if (exists $decoded->{dir} && exists $decoded->{frame}) {
            # Flaches Recorder-Schema: frame ist ein JSON-String (JSON-in-JSON).
            my $dir   = $decoded->{dir};
            my $frame = $decoded->{frame};
            my $inner = eval { $JSON->decode($frame) };
            if (!defined $inner || ref($inner) ne 'HASH' || !exists $inner->{type}) {
                if ($dir eq 'meta') {
                    # Bekannter Meta-Marker (z.B. HANDSHAKE-OK) -- kein Frame
                    # mit Typ, kein Residuum.
                    push @records, {
                        line        => $lineno,
                        dir         => $dir,
                        type        => undef,
                        epoch       => $decoded->{epoch},
                        raw         => undef,
                        residual    => 0,
                        meta_marker => $frame,
                    };
                    next;
                }
                push @records, { line => $lineno, residual => 1 };
                next;
            }
            push @records, {
                line     => $lineno,
                dir      => $dir,
                type     => $inner->{type},
                epoch    => $decoded->{epoch},
                raw      => $inner,
                residual => 0,
            };
            next;
        }

        if (exists $decoded->{type}) {
            # Nackter Frame -- im Archiv ausschliesslich die Alt-Schema-
            # Frame-Zeile nach einer #ts=-Kommentarzeile. Alt-Schema traegt
            # kein eigenes dir-Feld; Inhalt kommt vom Daemon, gilt als
            # empfangen (rx).
            push @records, {
                line     => $lineno,
                dir      => 'rx',
                type     => $decoded->{type},
                epoch    => defined $pending_epoch ? $pending_epoch : undef,
                raw      => $decoded,
                residual => 0,
            };
            $pending_epoch = undef;
            $pending_ts    = undef;
            next;
        }

        push @records, { line => $lineno, residual => 1 };
    }
    close $fh;
    return \@records;
}

# ---------------------------------------------------------------------------
# ws-cadence <fixture...>

sub cmd_ws_cadence {
    my (@files) = @_;
    die "FATAL: ws-cadence braucht mindestens eine Fixture-Datei\n" unless @files;

    my $residuum_gesamt = 0;

    # Frames, deren position-Feld zwar da ist, aber kein Objekt (z.B. ein
    # nackter Skalar). Sie werden auf NA normalisiert -- ohne eigenen Zaehler
    # waere die Normalisierung selbst ein stilles Verwerfen und von einem
    # schlicht fehlenden Feld nicht mehr zu unterscheiden (Regel 2).
    my $residuum_positionsform = 0;

    for my $path (@files) {
        my $records = parse_ws_fixture($path);
        my $prev_rx_type   = 'NONE';
        my $prev_ps_epoch;
        my @deltas;
        my $n            = 0;
        my $n_ueber_20000 = 0;
        my $residuum_file = 0;

        for my $rec (@$records) {
            if ($rec->{residual}) {
                $residuum_file++;
                next;
            }
            next unless defined $rec->{dir};

            if ($rec->{dir} eq 'rx' && defined $rec->{type} && $rec->{type} eq 'position_sync') {
                my $epoch = $rec->{epoch};
                my $delta_str = 'NA';
                if (defined $prev_ps_epoch && defined $epoch) {
                    my $delta_ms = int(($epoch - $prev_ps_epoch) * 1000 + 0.5);
                    $delta_str = $delta_ms;
                    push @deltas, $delta_ms;
                    $n_ueber_20000++ if $delta_ms > 20000;
                }
                # HASH-Wache wie beim Geschwister in cmd_ws_handshake: ohne
                # sie reisst EIN Frame mit skalarem position den gesamten
                # Lauf mit exit 255 ab -- vor jeder SUMMARY- und
                # RESIDUUM-Zeile, also verliert ein schlechter Frame jeden
                # Zaehler jeder Datei.
                my $pos_raw = $rec->{raw}{position};
                my $pos     = (ref($pos_raw) eq 'HASH') ? $pos_raw : {};
                $residuum_positionsform++ if defined($pos_raw) && ref($pos_raw) ne 'HASH';
                my $pos_ms = $pos->{position_ms};
                my $speed  = $pos->{speed};
                $pos_ms = 'NA' unless defined $pos_ms;
                $speed  = 'NA' unless defined $speed;

                printf "%s:%d type=position_sync epoch=%s delta_prev_ms=%s prev_frame_type=%s pos_ms=%s speed=%s\n",
                    $path, $rec->{line}, (defined $epoch ? $epoch : 'NA'), $delta_str, $prev_rx_type, $pos_ms, $speed;

                $n++;
                $prev_ps_epoch = $epoch if defined $epoch;
            }

            # Vorgaenger-Tracker: jeder empfangene (rx) Frame aktualisiert ihn,
            # nicht nur position_sync.
            if ($rec->{dir} eq 'rx' && defined $rec->{type}) {
                $prev_rx_type = $rec->{type};
            }
        }

        my ($min_ms, $median_ms, $max_ms) = ('NA', 'NA', 'NA');
        if (@deltas) {
            my @sorted = sort { $a <=> $b } @deltas;
            $min_ms = $sorted[0];
            $max_ms = $sorted[-1];
            my $mid = int(@sorted / 2);
            $median_ms = (@sorted % 2)
                ? $sorted[$mid]
                : int(($sorted[$mid - 1] + $sorted[$mid]) / 2);
        }

        printf "SUMMARY %s n=%d min_ms=%s median_ms=%s max_ms=%s n_ueber_20000=%d residuum=%d\n",
            $path, $n, $min_ms, $median_ms, $max_ms, $n_ueber_20000, $residuum_file;

        $residuum_gesamt += $residuum_file;
    }

    printf "RESIDUUM_POSITIONSFORM=%d\n", $residuum_positionsform;
    print "RESIDUUM_GESAMT=$residuum_gesamt\n";
    return 0;
}

# ---------------------------------------------------------------------------
# ws-handshake <fixture...>
#
# Prueft die Reparatur-Hypothese des Checkers fuer Blocker 1: traegt das
# erste playback_state nach dem Verbindungsaufbau ein position-Objekt?
# "Frische Verbindung" = das erste playback_state nach HANDSHAKE-OK (oder,
# ohne HANDSHAKE-OK-Metaframe im Alt-Schema, nach Dateianfang -- als
# Annahme benannt), unabhaengig von status/is_active.

# Schwelle fuer I2_VERDIKT=UNENTSCHEIDBAR: ein "erheblicher Teil" der
# Dateien ohne echtes HANDSHAKE-OK. Als mehr als ein Drittel gefasst --
# ausgeschrieben, nicht stillschweigend gewaehlt.
use constant I2_KEIN_HANDSHAKE_ANTEIL => 1 / 3;

sub cmd_ws_handshake {
    my (@files) = @_;
    die "FATAL: ws-handshake braucht mindestens eine Fixture-Datei\n" unless @files;

    my ($n_mit, $n_ohne, $n_ohne_handshake) = (0, 0, 0);

    # Dateien, in denen nach dem Handshake ueberhaupt kein playback_state
    # steht. Sie erhoehen WEDER $n_mit NOCH $n_ohne -- ohne eigenen Zaehler
    # waeren sie aus dem Urteil nicht mehr herauszulesen (Regel 2).
    my $n_kein_ps = 0;

    for my $path (@files) {
        my $records = parse_ws_fixture($path);

        my $handshake_idx;
        for my $i (0 .. $#$records) {
            my $r = $records->[$i];
            next if $r->{residual};
            if (defined $r->{meta_marker} && $r->{meta_marker} eq 'HANDSHAKE-OK') {
                $handshake_idx = $i;
                last;
            }
        }

        my $handshake_ok_found = defined($handshake_idx) ? 'ja' : 'nein';
        $n_ohne_handshake++ if $handshake_ok_found eq 'nein';

        my $conn_start_epoch;
        my $search_from = 0;
        if (defined $handshake_idx) {
            $conn_start_epoch = $records->[$handshake_idx]{epoch};
            $search_from = $handshake_idx + 1;
        } else {
            for my $r (@$records) {
                next if $r->{residual};
                if (defined $r->{epoch}) { $conn_start_epoch = $r->{epoch}; last; }
            }
        }

        my $ps_rec;
        for my $i ($search_from .. $#$records) {
            my $r = $records->[$i];
            next if $r->{residual};
            next unless defined $r->{dir} && $r->{dir} eq 'rx';
            next unless defined $r->{type} && $r->{type} eq 'playback_state';
            $ps_rec = $r;
            last;
        }

        if ($ps_rec) {
            my $has_pos = (ref($ps_rec->{raw}{position}) eq 'HASH') ? 1 : 0;
            my $position_ms  = $has_pos ? $ps_rec->{raw}{position}{position_ms}  : undef;
            my $timestamp_ms = $has_pos ? $ps_rec->{raw}{position}{timestamp_ms} : undef;
            my $speed        = $has_pos ? $ps_rec->{raw}{position}{speed}        : undef;

            my $delay_ms = 'NA';
            if (defined $conn_start_epoch && defined $ps_rec->{epoch}) {
                $delay_ms = int(($ps_rec->{epoch} - $conn_start_epoch) * 1000 + 0.5);
                $delay_ms = 0 if $delay_ms < 0;
            }

            printf "%s:%d handshake_playback_state=ja position=%s position_ms=%s timestamp_ms=%s speed=%s delay_ms=%s\n",
                $path, $ps_rec->{line}, ($has_pos ? 'ja' : 'nein'),
                (defined $position_ms ? $position_ms : 'NA'),
                (defined $timestamp_ms ? $timestamp_ms : 'NA'),
                (defined $speed ? $speed : 'NA'),
                $delay_ms;

            $has_pos ? $n_mit++ : $n_ohne++;
        } else {
            $n_kein_ps++;
            printf "%s:0 handshake_playback_state=nein position=nein position_ms=NA timestamp_ms=NA speed=NA delay_ms=NA\n",
                $path;
        }
    }

    my $fix = scalar @files;
    my $verdikt;
    if ($n_ohne > 0) {
        $verdikt = 'NICHT_IMMER';
    } elsif ($n_mit == 0) {
        # Null Beobachtungen koennen niemals IMMER sagen. Ohne diesen Zweig
        # faellt jede Dateimenge ohne ein einziges playback_state nach dem
        # Handshake auf IMMER_IM_ARCHIV durch -- ein Urteil aus dem Vakuum
        # (falscher Glob, abgeschnittene Dateien, Schema-Drift).
        $verdikt = 'UNENTSCHEIDBAR';
    } elsif ($fix > 0 && $n_ohne_handshake > $fix * I2_KEIN_HANDSHAKE_ANTEIL) {
        $verdikt = 'UNENTSCHEIDBAR';
    } else {
        $verdikt = 'IMMER_IM_ARCHIV';
    }

    printf "I2_VERDIKT=%s n_mit=%d n_ohne=%d n_ohne_handshake=%d\n", $verdikt, $n_mit, $n_ohne, $n_ohne_handshake;
    printf "RESIDUUM_OHNE_PLAYBACK_STATE=%d\n", $n_kein_ps;

    my $handshake_ok_vorhanden = $fix - $n_ohne_handshake;
    printf "I2_GUELTIGKEIT n=%d recorder=tools/soloist-ws-record.pl daemon_zeitraum=2026-09-03-2026-09-07 handshake_ok_vorhanden=%d/%d\n",
        $fix, $handshake_ok_vorhanden, $fix;

    return 0;
}

# ---------------------------------------------------------------------------
# Gemeinsames Parsing der Daemon-Log-Ticker-Zeile (Uhr B).
#
# Zeilenform: YYYY-MM-DD HH:MM:SS.mmm: <playing|paused|stopped> <uri> "<titel>"
# by "<kuenstler>" [m:ss / m:ss]. NICHT zeilenanfangsverankert -- zwei
# Zeilen im lavender-pa-Log sind ohne Zeilenumbruch an das Ende einer
# [fakepulse] TIMING-Zeile geklebt.

use constant TICKER_PAT => qr/(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}\.\d+): (playing|paused|stopped) (\S+) "([^"]*)" by "([^"]*)" \[(\d+):(\d{2}) \/ (\d+):(\d{2})\]/;
use constant TICKER_TAIL_LOOSE => qr/\[\d+:\d{2} \/ \d+:\d{2}\]/;

sub ticker_epoch {
    my ($date, $time) = @_;
    my ($y, $mo, $d) = split /-/, $date;
    my ($h, $mi, $s) = split /:/, $time;
    my $frac = 0;
    if ($s =~ /^(\d+)\.(\d+)$/) {
        $s    = $1;
        $frac = "0.$2" + 0;
    }
    my $epoch = Time::Local::timegm($s, $mi, $h, $d, $mo - 1, $y);
    return $epoch + $frac;
}

# parse_ticker_log($path) -- gibt (\@records, $residuum_verklebt, $residuum_ungeparst).
sub parse_ticker_log {
    my ($path) = @_;
    open my $fh, '<', $path or die "FATAL: kann $path nicht lesen: $!\n";
    my @records;
    my ($residuum_verklebt, $residuum_ungeparst) = (0, 0);
    my $lineno = 0;
    while (my $line = <$fh>) {
        $lineno++;
        chomp $line;
        my $found_any = 0;
        while ($line =~ /${\TICKER_PAT()}/g) {
            my $matchpos = $-[0];
            my ($date, $time, $state, $uri, $title, $artist, $pm, $ps, $dm, $ds) =
                ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10);
            $found_any = 1;
            my $glued = ($matchpos == 0) ? 0 : 1;
            $residuum_verklebt++ if $glued;
            my $pos_ms = ($pm * 60 + $ps) * 1000;
            my $dur_ms = ($dm * 60 + $ds) * 1000;
            my $norm_uri = ($uri =~ /^spotify:track:[A-Za-z0-9]+$/) ? $uri : 'NA';
            push @records, {
                line     => $lineno,
                ts_iso   => "${date}T${time}",
                ts_epoch => ticker_epoch($date, $time),
                state    => $state,
                uri      => $norm_uri,
                pos_ms   => $pos_ms,
                dur_ms   => $dur_ms,
                glued    => $glued,
            };
        }
        if (!$found_any && $line =~ TICKER_TAIL_LOOSE()) {
            $residuum_ungeparst++;
        }
    }
    close $fh;
    return (\@records, $residuum_verklebt, $residuum_ungeparst);
}

# ---------------------------------------------------------------------------
# ticker <log>

use constant STALE_TOLERANZ_MS  => 2000;
use constant RASTER_INTERVAL_MS => 10000;
use constant RASTER_TOLERANZ_MS => 500;

sub cmd_ticker {
    my (@args) = @_;
    # Argumentzahl pruefen, nicht nur auf undef: `my ($path) = @_` liess
    # jedes weitere Argument wortlos fallen. Ein Shell-Glob ueber zwei
    # Daemon-Logs lieferte so ein Urteil ueber die erste Datei, waehrend die
    # zweite nie gelesen wurde -- ein stilles Unter-Berichten mit exit 0.
    die "FATAL: ticker braucht genau eine Log-Datei (bekommen: " . scalar(@args) . ")\n"
        unless @args == 1;
    my ($path) = @args;

    my ($records, $residuum_verklebt, $residuum_ungeparst) = parse_ticker_log($path);

    my $prev_any;       # letzte Ticker-Zeile, egal welche URI (fuer raster_delta_ms / Bedingung a)
    my %prev_by_uri;    # letzte Ticker-Zeile je URI (fuer Bedingung b und Staleness)

    my %cond = (
        a => { treffer => 0, davon_stale => 0 },
        b => { treffer => 0, davon_stale => 0 },
        c => { treffer => 0, davon_stale => 0 },
    );

    for my $rec (@$records) {
        my $raster_delta_ms = defined($prev_any) ? int(($rec->{ts_epoch} - $prev_any->{ts_epoch}) * 1000 + 0.5) : undef;

        printf "%s:%d ts=%s state=%s uri=%s pos_ms=%d dur_ms=%d raster_delta_ms=%s\n",
            $path, $rec->{line}, $rec->{ts_iso}, $rec->{state}, $rec->{uri}, $rec->{pos_ms}, $rec->{dur_ms},
            (defined $raster_delta_ms ? $raster_delta_ms : 'NA');

        # Staleness gegen die Vorzeile DERSELBEN URI (STALE_DEFINITION).
        my $is_stale = 0;
        my $prev_same = $prev_by_uri{ $rec->{uri} };
        if ($prev_same && $rec->{uri} ne 'NA') {
            my $wall_delta_ms = int(($rec->{ts_epoch} - $prev_same->{ts_epoch}) * 1000 + 0.5);
            my $pos_delta_ms  = $rec->{pos_ms} - $prev_same->{pos_ms};
            my $not_endstellung = ($rec->{pos_ms} != $rec->{dur_ms});
            if ($wall_delta_ms >= STALE_TOLERANZ_MS
                && ($wall_delta_ms - $pos_delta_ms) >= STALE_TOLERANZ_MS
                && $not_endstellung) {
                $is_stale = 1;
            }
        }

        # Bedingung (a): Zeile liegt ausserhalb des 10-s-Rasters.
        if (defined $raster_delta_ms) {
            my $off_raster = (abs($raster_delta_ms - RASTER_INTERVAL_MS) > RASTER_TOLERANZ_MS) ? 1 : 0;
            if ($off_raster) {
                $cond{a}{treffer}++;
                $cond{a}{davon_stale}++ if $is_stale;
            }
        }

        # Bedingung (b): Position gegenueber der Vorzeile derselben URI um
        # etwa ein Rasterintervall gestiegen.
        if ($prev_same) {
            my $pos_delta_ms = $rec->{pos_ms} - $prev_same->{pos_ms};
            if (abs($pos_delta_ms - RASTER_INTERVAL_MS) <= RASTER_TOLERANZ_MS) {
                $cond{b}{treffer}++;
                $cond{b}{davon_stale}++ if $is_stale;
            }
        }

        # Bedingung (c): pos_ms entspricht der Titeldauer (Endstellung).
        if ($rec->{pos_ms} == $rec->{dur_ms}) {
            $cond{c}{treffer}++;
            $cond{c}{davon_stale}++ if $is_stale;
        }

        $prev_any = $rec;
        $prev_by_uri{ $rec->{uri} } = $rec if $rec->{uri} ne 'NA';
    }

    printf "RESIDUUM_VERKLEBT=%d\n", $residuum_verklebt;
    printf "RESIDUUM_UNGEPARST=%d\n", $residuum_ungeparst;

    print "STALE_DEFINITION=Eine Position gilt als stale, wenn seit der Vorzeile derselben URI mindestens STALE_TOLERANZ_MS Wanduhrzeit vergangen sind (wall_delta_ms >= STALE_TOLERANZ_MS), das Positions-Delta gegenueber dieser Vorzeile aber um mindestens STALE_TOLERANZ_MS hinter dem Wanduhr-Delta zurueckbleibt (wall_delta_ms - pos_delta_ms >= STALE_TOLERANZ_MS), und die Position nicht auf der Titeldauer steht (Endstellung ist ein eigener Fall, kein Stillstand der Uhr).\n";
    printf "STALE_TOLERANZ_MS=%d\n", STALE_TOLERANZ_MS;

    for my $letter (qw(a b c)) {
        printf "bedingung=%s treffer=%d davon_stale=%d\n", $letter, $cond{$letter}{treffer}, $cond{$letter}{davon_stale};
    }

    return 0;
}

# ---------------------------------------------------------------------------
# blocks <log>
#
# Maximale Folgen aufeinanderfolgender playing-Ticker-Zeilen (im
# Ticker-Datenstrom, nicht in der rohen Logzeile) mit identischer URI UND
# identischer Position. Ein paused/stopped dazwischen bricht den Block.
# Mindestlaenge 2 -- eine einzelne Zeile ist kein Befund fuer eingefrorene
# Uhr, erst eine Wiederholung. Ein Block, der bis zum Dateiende offen
# bleibt, zaehlt, wenn er die Mindestlaenge erreicht hat.

use constant BLOCK_MIN_LEN => 2;
use constant BLOCKDEFINITION_TEXT =>
    'Maximale Folge aufeinanderfolgender playing-Ticker-Zeilen (im geparsten Ticker-Datenstrom, ein paused/stopped dazwischen bricht) mit identischer URI und identischer Position (pos_ms); Mindestlaenge ' . BLOCK_MIN_LEN . ' Zeilen; ein bis Dateiende offener Block zaehlt, wenn er die Mindestlaenge erreicht';

# compute_blocks($records) -- liefert \@blocks (start_idx,end_idx als Index
# in $records, first,last,n,endstellung). Gemeinsam fuer cmd_blocks und
# cmd_stillstand (Task 5 setzt auf denselben Bloecken auf wie Task 3).
sub compute_blocks {
    my ($records) = @_;
    my @blocks;
    my @run_idx;

    my $flush = sub {
        return unless @run_idx >= BLOCK_MIN_LEN;
        my $first = $records->[$run_idx[0]];
        my $last  = $records->[$run_idx[-1]];
        push @blocks, {
            start_idx   => $run_idx[0],
            end_idx     => $run_idx[-1],
            first       => $first,
            last        => $last,
            n           => scalar(@run_idx),
            endstellung => ($first->{pos_ms} == $first->{dur_ms}) ? 'ja' : 'nein',
        };
    };

    for my $i (0 .. $#$records) {
        my $rec = $records->[$i];
        if ($rec->{state} eq 'playing'
            && @run_idx
            && $records->[$run_idx[-1]]{state} eq 'playing'
            && $records->[$run_idx[-1]]{uri} eq $rec->{uri}
            && $records->[$run_idx[-1]]{pos_ms} == $rec->{pos_ms}) {
            push @run_idx, $i;
            next;
        }
        $flush->();
        @run_idx = ($rec->{state} eq 'playing') ? ($i) : ();
    }
    $flush->();

    return \@blocks;
}

sub cmd_blocks {
    my (@args) = @_;
    # Argumentzahl pruefen, nicht nur auf undef: `my ($path) = @_` liess
    # jedes weitere Argument wortlos fallen. Ein Shell-Glob ueber zwei
    # Daemon-Logs lieferte so ein Urteil ueber die erste Datei, waehrend die
    # zweite nie gelesen wurde -- ein stilles Unter-Berichten mit exit 0.
    die "FATAL: blocks braucht genau eine Log-Datei (bekommen: " . scalar(@args) . ")\n"
        unless @args == 1;
    my ($path) = @args;

    my ($records, undef, undef) = parse_ticker_log($path);
    my $blocks = compute_blocks($records);

    printf "BLOCKDEFINITION=%s\n", BLOCKDEFINITION_TEXT();

    for my $blk (@$blocks) {
        my $dauer_s = int(($blk->{last}{ts_epoch} - $blk->{first}{ts_epoch}) + 0.5);
        printf "%s:%d-%d n=%d uri=%s pos_ms=%d dauer_s=%d endstellung=%s\n",
            $path, $blk->{first}{line}, $blk->{last}{line}, $blk->{n}, $blk->{first}{uri}, $blk->{first}{pos_ms}, $dauer_s, $blk->{endstellung};
    }

    printf "BLOECKE_GESAMT=%d\n", scalar(@$blocks);
    return 0;
}

# ---------------------------------------------------------------------------
# transitions <log>
#
# Bewertet Titelgrenzen-Anker gegen eine anker-unabhaengige Referenz aus der
# Stromschicht des Daemons (boundary_planted:/pa_stream_flush(stream=,
# tools/uat/extract-run.pl:180/:176) statt gegen sich selbst.

use constant REFERENZ_FENSTER_MS  => 5000;
use constant LUECKENSCHWELLE_MS   => 120000;
use constant REF_DATE_PAT         => qr/(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}\.\d+): (?:playing|paused|stopped) /;
use constant REF_TIME_PAT         => qr/(\d{2}:\d{2}:\d{2}\.\d+)/;

# Rueckwaertssprung, ab dem ein geerbtes Datum als tagversetzt gilt. Nur
# Erkennungsschwelle fuer den Restzaehler -- es wird NICHTS umdatiert.
use constant REF_TAGWECHSEL_SCHWELLE_S => 12 * 3600;

# parse_reference_events($path) -- Stromschicht-Ereignisse mit von der
# vorangehenden datierten Ticker-Zeile geerbtem Datum (beide Referenzformen
# tragen nur HH:MM:SS.mmm ohne Datum).
#
# Liefert (\@events, $n_undatiert, $n_tagwechsel). Zwei Faelle sind mit dem
# geerbten Datum nicht verwertbar, und beide gingen bisher spurlos verloren
# (Regel 2 des Dateikopfes):
#   - undatiert: die Referenzzeile steht VOR der ersten datierten
#     Ticker-Zeile. Es gibt kein Datum zu erben, das Ereignis entfaellt.
#   - tagwechsel: die Zeit springt gegenueber der zuletzt gesehenen Zeit um
#     mehr als REF_TAGWECHSEL_SCHWELLE_S zurueck -- die Signatur eines
#     Mitternachtswechsels. Das Ereignis erbt dann den Vortag und liegt 24 h
#     daneben, bestaetigt also nie den Anker, zu dem es gehoert.
#
# NUR ZAEHLEN, NICHT REPARIEREN (Nutzerentscheidung 2026-09-23): die im
# Review vorgeschlagene +24-h-Heuristik wird bewusst NICHT eingebaut. Die
# Sonde meldet den Fall sichtbar, statt eine ungepruefte Annahme ueber das
# Material zu treffen und plausibel-falsche Anker zu liefern. Die Epoche der
# betroffenen Ereignisse bleibt daher unveraendert.
sub parse_reference_events {
    my ($path) = @_;
    open my $fh, '<', $path or die "FATAL: kann $path nicht lesen: $!\n";
    my @events;
    my $last_date;
    my $last_epoch;
    my ($n_undatiert, $n_tagwechsel) = (0, 0);
    while (my $line = <$fh>) {
        chomp $line;
        if ($line =~ REF_DATE_PAT()) {
            $last_date  = $1;
            $last_epoch = ticker_epoch($1, $2);
        }
        for my $kind (['boundary_planted:', 'boundary_planted'],
                      ['pa_stream_flush(stream=', 'pa_stream_flush']) {
            next unless index($line, $kind->[0]) >= 0;
            next unless $line =~ REF_TIME_PAT();
            my $time = $1;
            if (!defined $last_date) {
                $n_undatiert++;
                next;
            }
            my $epoch = ticker_epoch($last_date, $time);
            $n_tagwechsel++
                if defined($last_epoch) && ($last_epoch - $epoch) > REF_TAGWECHSEL_SCHWELLE_S;
            push @events, { epoch => $epoch, kind => $kind->[1] };
            $last_epoch = $epoch;
        }
    }
    close $fh;
    return (\@events, $n_undatiert, $n_tagwechsel);
}

our %ANCHOR = (
    uri_wechsel     => sub { my ($a, $b) = @_; return $a->{uri} ne $b->{uri}; },
    pos_rueckwaerts => sub { my ($a, $b) = @_; return $a->{uri} eq $b->{uri} && $b->{pos_ms} < $a->{pos_ms}; },
);
our @ANCHOR_ORDER = qw(uri_wechsel pos_rueckwaerts);

# analyze_pairs($ticker_records, $path) -- gemeinsame Paar-Analyse fuer
# transitions UND stillstand: liefert \@pairs (a_idx,b_idx,gap_ms,is_luecke,
# ref_confirmed,triggers=>{anchor=>klasse}), die Referenzereignisse und deren
# zwei Restzaehler (undatiert / tagversetzt).
sub analyze_pairs {
    my ($ticker_records, $path) = @_;

    my ($ref_events, $ref_undatiert, $ref_tagwechsel) = parse_reference_events($path);
    my @ref_epochs = sort { $a <=> $b } map { $_->{epoch} } @$ref_events;
    my $ref_confirmed = sub {
        my ($epoch) = @_;
        for my $re (@ref_epochs) {
            return 1 if abs($re - $epoch) * 1000 <= REFERENZ_FENSTER_MS;
        }
        return 0;
    };

    my @pairs;
    for my $i (0 .. $#$ticker_records - 1) {
        my $a = $ticker_records->[$i];
        my $b = $ticker_records->[$i + 1];
        my $gap_ms = int(($b->{ts_epoch} - $a->{ts_epoch}) * 1000 + 0.5);
        my $is_luecke = ($gap_ms > LUECKENSCHWELLE_MS) ? 1 : 0;
        my $confirmed = $ref_confirmed->($b->{ts_epoch});

        my %triggers;
        for my $name (@ANCHOR_ORDER) {
            next unless $ANCHOR{$name}->($a, $b);
            $triggers{$name} = $is_luecke ? 'sitzungsluecke' : ($confirmed ? 'grenze_ref_bestaetigt' : 'grenze_unbestaetigt');
        }

        push @pairs, {
            a_idx => $i, b_idx => $i + 1, a => $a, b => $b,
            gap_ms => $gap_ms, is_luecke => $is_luecke, ref_confirmed => $confirmed,
            triggers => \%triggers,
        };
    }

    return (\@pairs, $ref_events, $ref_undatiert, $ref_tagwechsel);
}

sub cmd_transitions {
    my (@args) = @_;
    # Argumentzahl pruefen, nicht nur auf undef: `my ($path) = @_` liess
    # jedes weitere Argument wortlos fallen. Ein Shell-Glob ueber zwei
    # Daemon-Logs lieferte so ein Urteil ueber die erste Datei, waehrend die
    # zweite nie gelesen wurde -- ein stilles Unter-Berichten mit exit 0.
    die "FATAL: transitions braucht genau eine Log-Datei (bekommen: " . scalar(@args) . ")\n"
        unless @args == 1;
    my ($path) = @args;

    my ($ticker_records, undef, undef) = parse_ticker_log($path);
    my ($pairs, $ref_events, $ref_undatiert, $ref_tagwechsel) = analyze_pairs($ticker_records, $path);

    print "REFERENZ_QUELLE=Stromschicht des Daemons: boundary_planted: (tools/uat/extract-run.pl:180) und pa_stream_flush(stream= (tools/uat/extract-run.pl:176), lavender-pa-Schnappschuss\n";
    print "REFERENZ_MUSTER=boundary_planted:\n";
    printf "REFERENZ_FENSTER_MS=%d\n", REFERENZ_FENSTER_MS;
    printf "REFERENZ_EREIGNISSE=%d\n", scalar(@$ref_events);
    # Die Herkunftszeile nennt nur noch das VERFAHREN. Die frueher hier fest
    # verdrahtete Behauptung ("im Schnappschuss liegt keine Referenzzeile vor
    # der ersten datierten Zeile") galt fuer genau einen Schnappschuss und
    # wurde fuer JEDE Datei gedruckt. Was fuer die vorliegende Datei gilt,
    # steht jetzt gemessen in den beiden Restzaehlern darunter.
    print "REFERENZ_DATUMSHERKUNFT=Datum von der naechsten vorangehenden datierten Ticker-Zeile uebernommen; fuer diese Datei gemessen in RESIDUUM_REFERENZ_UNDATIERT und RESIDUUM_REFERENZ_TAGWECHSEL\n";
    printf "RESIDUUM_REFERENZ_UNDATIERT=%d\n", $ref_undatiert;
    printf "RESIDUUM_REFERENZ_TAGWECHSEL=%d\n", $ref_tagwechsel;
    printf "LUECKENSCHWELLE_MS=%d\n", LUECKENSCHWELLE_MS;

    my %stats = map { $_ => { treffer => 0, kandidaten => 0, ref_bestaetigt => 0, ref_unbestaetigt => 0, fehl_null_auf_null => 0, falschtreffer => 0 } } @ANCHOR_ORDER;

    my $null_roh  = 0;
    my $null_best = 0;
    my @null_pairs;

    for my $p (@$pairs) {
        my ($a, $b) = ($p->{a}, $p->{b});

        if (!$p->{is_luecke} && $a->{pos_ms} == 0 && $b->{pos_ms} == 0) {
            $null_roh++;
            if ($p->{ref_confirmed}) {
                $null_best++;
                push @null_pairs, [$a, $b];
            }
        }

        for my $name (@ANCHOR_ORDER) {
            my $klasse = $p->{triggers}{$name};
            next unless $klasse;
            $stats{$name}{treffer}++;
            if ($klasse eq 'sitzungsluecke') {
                $stats{$name}{falschtreffer}++;
            } elsif ($klasse eq 'grenze_ref_bestaetigt') {
                $stats{$name}{kandidaten}++;
                $stats{$name}{ref_bestaetigt}++;
            } else {
                $stats{$name}{kandidaten}++;
                $stats{$name}{ref_unbestaetigt}++;
            }
            printf "%s:%d anker=%s klasse=%s ts=%s von_uri=%s nach_uri=%s von_pos_ms=%d nach_pos_ms=%d luecke_ms=%d\n",
                $path, $b->{line}, $name, $klasse, $b->{ts_iso}, $a->{uri}, $b->{uri}, $a->{pos_ms}, $b->{pos_ms}, $p->{gap_ms};
        }
    }

    for my $name (@ANCHOR_ORDER) {
        for my $pair (@null_pairs) {
            my ($a, $b) = @$pair;
            $stats{$name}{fehl_null_auf_null}++ unless $ANCHOR{$name}->($a, $b);
        }
    }

    printf "NULL_AUF_NULL_ROH=%d\n", $null_roh;
    printf "NULL_AUF_NULL=%d\n", $null_best;

    for my $name (@ANCHOR_ORDER) {
        printf "ANKER %s treffer=%d kandidaten=%d ref_bestaetigt=%d ref_unbestaetigt=%d fehl_null_auf_null=%d falschtreffer=%d\n",
            $name, $stats{$name}{treffer}, $stats{$name}{kandidaten}, $stats{$name}{ref_bestaetigt},
            $stats{$name}{ref_unbestaetigt}, $stats{$name}{fehl_null_auf_null}, $stats{$name}{falschtreffer};
    }

    printf "REFERENZ_UNABHAENGIG=%s\n", referenz_unabhaengig($pairs, $ref_events, \%stats);

    return 0;
}

# referenz_unabhaengig($pairs, $ref_events, $stats) -- gemeinsame Regel fuer
# REFERENZ_UNABHAENGIG (Task 4) und I5_REFERENZ_UEBERNOMMEN (Task 5): JA nur,
# wenn die Referenzmenge nicht leer ist UND die Anker unter ihr
# unterschiedlich abschneiden.
sub referenz_unabhaengig {
    my ($pairs, $ref_events, $stats) = @_;
    my %distinct_unbest = map { $stats->{$_}{ref_unbestaetigt} => 1 } @ANCHOR_ORDER;
    return (@$ref_events && keys(%distinct_unbest) >= 2) ? 'JA' : 'NEIN';
}

# grenze_index_set($pairs) -- Menge der Ticker-Record-Indizes (b_idx), die
# fuer MINDESTENS einen Anker als grenze_ref_bestaetigt klassifiziert sind.
sub grenze_index_set {
    my ($pairs) = @_;
    my %set;
    for my $p (@$pairs) {
        for my $name (@ANCHOR_ORDER) {
            my $k = $p->{triggers}{$name};
            $set{ $p->{b_idx} } = 1 if defined($k) && $k eq 'grenze_ref_bestaetigt';
        }
    }
    return \%set;
}

# luecke_after_set($pairs) -- Menge der a_idx, nach denen eine Sitzungsluecke
# folgt (Paar a_idx->b_idx mit is_luecke).
sub luecke_after_set {
    my ($pairs) = @_;
    my %set;
    for my $p (@$pairs) {
        $set{ $p->{a_idx} } = 1 if $p->{is_luecke};
    }
    return \%set;
}

# ---------------------------------------------------------------------------
# stillstand <log>
#
# Setzt auf den Bloecken aus Task 3 (compute_blocks) und der Grenzliste aus
# Task 4 (analyze_pairs, referenzbestaetigter Teil) auf. Klassifiziert je
# Kandidat: folgt eine referenzbestaetigte Grenze, bevor eine Sitzungsluecke
# dazwischenkommt -> normaler_durchlauf; folgt bis Sitzungsende keine mehr
# -> echter_stillstand; eine Sitzungsluecke kommt zuerst -> unentscheidbar.

use constant STILLSTAND_N_RASTER => 3;

sub classify_forward {
    my ($start_idx, $last_idx, $grenze_idx, $luecke_after) = @_;
    for my $j ($start_idx + 1 .. $last_idx) {
        return 'unentscheidbar' if $luecke_after->{ $j - 1 };
        return 'normaler_durchlauf' if $grenze_idx->{$j};
    }
    return 'echter_stillstand';
}

sub cmd_stillstand {
    my (@args) = @_;
    # Argumentzahl pruefen, nicht nur auf undef: `my ($path) = @_` liess
    # jedes weitere Argument wortlos fallen. Ein Shell-Glob ueber zwei
    # Daemon-Logs lieferte so ein Urteil ueber die erste Datei, waehrend die
    # zweite nie gelesen wurde -- ein stilles Unter-Berichten mit exit 0.
    die "FATAL: stillstand braucht genau eine Log-Datei (bekommen: " . scalar(@args) . ")\n"
        unless @args == 1;
    my ($path) = @args;

    my ($records, undef, undef) = parse_ticker_log($path);
    my $blocks = compute_blocks($records);
    my ($pairs, $ref_events, $ref_undatiert, $ref_tagwechsel) = analyze_pairs($records, $path);

    my $last_idx      = $#$records;
    my $grenze_idx     = grenze_index_set($pairs);
    my $luecke_after   = luecke_after_set($pairs);

    my %stats = map { $_ => { treffer => 0, normaler_durchlauf => 0, echter_stillstand => 0, unentscheidbar => 0 } }
        qw(paused kein_playing_n_raster endstellung);

    my @triggers;    # [ idx, kriterium ]

    for my $i (0 .. $last_idx) {
        push @triggers, [$i, 'paused'] if $records->[$i]{state} eq 'paused';
        push @triggers, [$i, 'endstellung'] if $records->[$i]{pos_ms} == $records->[$i]{dur_ms};
        if ($i >= STILLSTAND_N_RASTER - 1) {
            my $all_non_playing = 1;
            for my $k (($i - STILLSTAND_N_RASTER + 1) .. $i) {
                if ($records->[$k]{state} eq 'playing') { $all_non_playing = 0; last; }
            }
            push @triggers, [$i, 'kein_playing_n_raster'] if $all_non_playing;
        }
    }

    # SW-01 (Geschwisterbefund zu CR-01, Debug-Sitzung
    # instrument-probe-vakuumverdikt, 2026-09-23): die Schleife in
    # classify_forward laeuft NULLMAL, wenn der Ausloeser die letzte
    # Ticker-Zeile der Datei ist. `echter_stillstand` -- die staerkste der drei
    # Klassen -- faellt dann aus null Vorwaertsbeobachtungen durch.
    # Nutzerentscheidung: ADDITIV ZAEHLEN, nicht umklassifizieren. Die
    # Klassifikation bleibt unveraendert, damit kein protokollierter Wert sich
    # verschiebt; der Zaehler macht sichtbar, worauf ein Urteil ruht.
    my $leeres_fenster = 0;

    for my $t (@triggers) {
        my ($idx, $krit) = @$t;
        my $klasse = classify_forward($idx, $last_idx, $grenze_idx, $luecke_after);
        # Genau die Bedingung, unter der die Schleife in classify_forward
        # nullmal laeuft ($start_idx + 1 .. $last_idx ist leer).
        $leeres_fenster++ if $idx + 1 > $last_idx;
        $stats{$krit}{treffer}++;
        $stats{$krit}{$klasse}++;
        printf "%s:%d kriterium=%s klasse=%s ts=%s\n", $path, $records->[$idx]{line}, $krit, $klasse, $records->[$idx]{ts_iso};
    }

    for my $krit (qw(paused kein_playing_n_raster endstellung)) {
        printf "KRITERIUM=%s treffer=%d normaler_durchlauf=%d echter_stillstand=%d unentscheidbar=%d\n",
            $krit, $stats{$krit}{treffer}, $stats{$krit}{normaler_durchlauf}, $stats{$krit}{echter_stillstand}, $stats{$krit}{unentscheidbar};
    }

    # HEUTIGES_KRITERIUM: Gegenrechnung ueber ALLE Bloecke aus Task 3 (nicht
    # nur eine Teilmenge) -- wie viele erweisen sich, vom Blockende aus
    # vorwaerts geprueft, als normaler Durchlauf (Falschtreffer)?
    my $heutiges_falschtreffer = 0;
    for my $blk (@$blocks) {
        my $klasse = classify_forward($blk->{end_idx}, $last_idx, $grenze_idx, $luecke_after);
        $heutiges_falschtreffer++ if $klasse eq 'normaler_durchlauf';
    }
    printf "HEUTIGES_KRITERIUM falschtreffer=%d blocks_geprueft=%d grundlage=Bloecke aus Task 3 (compute_blocks, %s)\n",
        $heutiges_falschtreffer, scalar(@$blocks), BLOCKDEFINITION_TEXT();

    my %anchor_stats = map { $_ => { ref_unbestaetigt => 0 } } @ANCHOR_ORDER;
    for my $p (@$pairs) {
        for my $name (@ANCHOR_ORDER) {
            my $k = $p->{triggers}{$name};
            $anchor_stats{$name}{ref_unbestaetigt}++ if defined($k) && $k eq 'grenze_unbestaetigt';
        }
    }
    my $referenz_uebernommen = referenz_unabhaengig($pairs, $ref_events, \%anchor_stats);
    printf "I5_REFERENZ_UEBERNOMMEN=%s\n", $referenz_uebernommen;

    # Dieselbe Referenzmenge traegt hier die Grenzliste (grenze_index_set).
    # Was dort unbrauchbar war, muss auch hier sichtbar sein -- sonst
    # ueberlebt derselbe Befund die Korrektur eine Dateigrenze weiter.
    printf "RESIDUUM_REFERENZ_UNDATIERT=%d\n", $ref_undatiert;
    printf "RESIDUUM_REFERENZ_TAGWECHSEL=%d\n", $ref_tagwechsel;
    # Regel 2: immer ausgeben, auch bei null. Zaehlt die Kandidaten, deren
    # Vorwaertsfenster leer war (Ausloeser = letzte Ticker-Zeile) und deren
    # `echter_stillstand` damit auf null Beobachtungen steht. Die Klasse selbst
    # bleibt unveraendert -- wer diese Zahl > 0 sieht, weiss, dass die
    # Bilanzzeile darueber und EMPFOHLENES_KRITERIUM darunter in diesem Umfang
    # auf einem leeren Fenster ruhen.
    printf "RESIDUUM_STILLSTAND_LEERES_FENSTER=%d\n", $leeres_fenster;

    # Empfehlung: das Kriterium mit dem geringsten Anteil normaler_durchlauf
    # an seinen Treffern (wenigste Falschalarme), sofern es ueberhaupt
    # echten Stillstand findet. KEINES, wenn kein Kandidat trennt.
    my $empfohlen = 'KEINES';
    my $best_ratio;
    for my $krit (qw(paused kein_playing_n_raster endstellung)) {
        my $s = $stats{$krit};
        next unless $s->{treffer} > 0 && $s->{echter_stillstand} > 0;
        my $ratio = $s->{normaler_durchlauf} / $s->{treffer};
        if (!defined($best_ratio) || $ratio < $best_ratio) {
            $best_ratio = $ratio;
            $empfohlen  = $krit;
        }
    }
    printf "EMPFOHLENES_KRITERIUM=%s\n", $empfohlen;

    return 0;
}

# ---------------------------------------------------------------------------
# main

sub main {
    my (@argv) = @_;

    if (!@argv || $argv[0] eq '--help' || $argv[0] eq '-h') {
        print usage();
        return 0;
    }

    my $cmd = shift @argv;

    if ($cmd eq 'ws-cadence') {
        return cmd_ws_cadence(@argv);
    }
    if ($cmd eq 'ws-handshake') {
        return cmd_ws_handshake(@argv);
    }
    if ($cmd eq 'ticker') {
        return cmd_ticker(@argv);
    }
    if ($cmd eq 'blocks') {
        return cmd_blocks(@argv);
    }
    if ($cmd eq 'transitions') {
        return cmd_transitions(@argv);
    }
    if ($cmd eq 'stillstand') {
        return cmd_stillstand(@argv);
    }

    print STDERR "FATAL: unbekannter Unterbefehl '$cmd'\n";
    print STDERR usage();
    return 1;
}

exit(main(@ARGV)) unless caller;

1;

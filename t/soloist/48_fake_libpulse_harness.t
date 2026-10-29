#!/usr/bin/perl

# t/48_fake_libpulse_harness.t
#
# Debug-Sitzung `connect-seek-stoppt-wiedergabe` (2026-09-24). Bindet den
# C-Harness von fake-libpulse (`make test`, FAKE_LIBPULSE_TEST) in
# `prove -r t/` ein -- bisher lief er nur im x86_64-Zweig von
# `.github/workflows/build-fake-libpulse.yml`, also nie bei einer
# Perl-Aenderung und nie lokal im normalen Testlauf.
#
# Anlass: fake-libpulse fuehrte einen `g_flush_disconnect` aus, BEVOR es
# einen schon eingereihten `POST /seek-arm` gelesen hatte. Auf dem
# Proxy-Pfad schloss das den FRISCHEN Seek-Strom von LMS; LMS las EOF,
# spielte aus, stoppte die Ein-Titel-Playlist und reichte den Stopp als
# Pause an die Connect-Sitzung weiter. Live gemessen auf lavender-UAT
# (2026-09-24 07:04:57, 08:04:14, 08:07:22). Der Harness enthaelt dafuer
# sechs Tests (Arm eingereiht bei Flush-Zeitpunkt, Gegenprobe ohne Arm,
# erzwungene Varianten Warteschlange/Pending-Slot, Arm vor rennendem GET,
# /boundary ueberlebt den Durchgang) -- alle wurden vor dem Fix rot
# gezeigt bzw. toeten je eine Mutante an der Fix-Stelle.
#
# 84-17 (2026-10-01): acht weitere Regressionsnamen (Antwortkoerper von
# POST /boundary mit via=/boundary=/anchor=/drops=, Drain-Anker, Drop-Zaehler,
# Pop nur bis zur Marke); die Gesamtzahl der `ok:`-Zeilen steigt von 26 auf 34.
#
# 84-17 (Nachtrag, Nutzerentscheidung "Nie verwerfen, Daemon warten lassen"):
# ein volles Ring verwirft nie mehr Audio. Vier weitere Namen: der Schreiber
# wartet und nichts geht verloren (Form der Langschwanz-Messung: 80240 B frei,
# ein 81920-B-Schreibvorgang, vorher 1680 B verworfen), ein Flush gibt den
# wartenden Schreiber frei und verwirft den veralteten Rest, die Obergrenze
# (SPOTON_FAKEPULSE_WRITE_WAIT_MS) zaehlt die Verweigerung in drops=, und
# writable_size meldet genau den freien Platz. Die ok:-Zeilen steigen auf 40 (Nachtrag: writable_size meldet den freien Platz MINUS eine Reserve von 128 KiB, weil der Daemon bei writable_size > 0 immer einen ganzen Chunk schreibt).
#
# 84-20 (Q2, virtuelle Senke, Nutzerentscheidung "Ja, so uebernehmen" mit den Aenderungen des
# Zweitgutachtens): dreizehn weitere Namen `vsink: ...`. Mit SPOTON_FAKEPULSE_VSINK_MS=<T> verhaelt sich
# der Shim wie eine PulseAudio-Senke der Tiefe T: writable_size schrumpft beim Schreiben, waechst bei
# laufender (unkorkter) Uhr mit Wanduhrrate nach, ein Cork-Wechsel startet die Abflussuhr neu, ein Flush
# leert die Senke, underflow_cb und read_index/sink_usec folgen ihr (S16 zaehlt in Ausgabebytes). Die
# Harness-Uhr ist ein _Atomic-Override, die Fuelle bleibt eingefroren, solange ein Fall nichts vorstellt.
# Die ok:-Zeilen steigen auf mindestens 54.
#
# 84-22 (F-20-WRITER, Todo fake-libpulse-writer-bricht-nach-langer-pause-ab): fuenf weitere Namen `writer: ...`
# (vier vom Plan, einer aus dem Review der eigenen Aenderung). Der HTTP-Schreiber gab einen Client nach 2 s
# ohne Fortschritt als gegangen auf (`client-close: write error/disconnect`); ein Player, der ~15 s nicht liest
# (SIGSTOP, Netzaussetzer, Sync-Gruppe), verlor so seinen Strom. Jetzt: 4 s Lesepause bleibt angehaengt und
# bekommt die Zaehlerrampe lueckenlos, Flush und Takeover beenden den haengenden Schreibvorgang innerhalb eines
# Ticks ueber ihre eigenen Pfade, die Waisengrenze zaehlt Nichtfortschritt, ein nie fertig werdender Anfragekopf
# im Pending-Slot laeuft ab. Die ok:-Zeilen steigen um 5.
#
# 84-22 (Nachtrag, Nutzerentscheidung 180 s am Entscheidungs-Checkpoint 2a): ein sechster Name `writer: the orphan bound
# defaults to 180000 ms when the env is unset` pinnt die ausgelieferte Waisengrenze (define + Env-Ueberschreibung).
# Die ok:-Zeilen steigen damit um 6.
#
# 79-07 (84 WR-01): zwei weitere Namen (Teardown wartet auf einen blockierten Schreiber, Unref eines nicht aktiven
# Streams laesst flush_epoch unveraendert); die Untergrenze der ok:-Zeilen steigt um 2 auf 56.
#
# quick-261022-ca3: Ursache des CI-Flakes `reconnected client received no audio within 500ms` war die Harness-Arithmetik,
# nicht die Shim: die Lese-Helfer und sechs Warteschleifen massen die Zeit als Differenz ganzer Sekunden, die Frist eines
# Budgets unter 1000 ms feuerte also am ersten Sekundenwechsel. Jetzt zaehlen verstrichene Millisekunden; der Reconnect-Fall
# misst die Latenz vom Schreiben bis zum ersten Byte gegen 500 ms. Zwei Namen kommen hinzu (der Reconnect-Fall steht erstmals
# in der Liste, dazu die Sekundenwechsel-Probe der Helfer); die Untergrenze der ok:-Zeilen bleibt 56.
#
# 79-37 (79 D-31, Nutzerentscheidung "Ja, reparieren", 2026-10-23): die Luecken-Haltung des Shims. Nach einem
# Schreibstopp von mindestens HOLD_GAP_MS (Standard 500 ms) mit demselben Live-Client haelt der Shim die Bytes
# hinter dem Ende des alten Titels zurueck (Pop-Kappe in _ring_pop_timed), bis Controls Drain-POST die Grenze dort
# setzt oder die Haltung ausgelaufen ist. Der Namenspunkt `hold: archive natural end ...` faehrt die Archivform
# (8192-B-Schreibvorgaenge, 536848-B-Burst nach einer echten Pause von 3 s) und verlangt null Byte des naechsten
# Titels im alten Strom. Damit der Fall scheitern KANN, baut dieser Test hier die Mutante ohne die Kappe (der
# markierte Block D-31 HOLD_CAP_BEGIN/END wird aus dem Quelltext geschnitten) und laesst sie im Nur-Hold-Modus
# (FAKE_LIBPULSE_TEST_HOLD_ONLY=1) laufen: die Mutante MUSS den Fall verfehlen, der unveraenderte Harness MUSS ihn
# bestehen. Die Untergrenze der ok:-Zeilen steigt von 56 auf 64.
#
# 79-37 (Nachtrag, Task 2): zehn weitere Namen `hold: ...` fuer jeden Ausgang der Haltung (Ablauf ohne POST, Flush mit und
# ohne Arm, frischer Client, gleichmaessige Wiedergabe, POST /hold-release bei stehender Haltung und vor dem Refill,
# plain POST /boundary, HOLD_GAP_MS 0, negative 64-Bit-Uhr). Der Off-Loopback-Fall (403) steht NICHT in der Liste: ohne
# nicht-lokale IPv4-Adresse druckt er `skip:` statt `ok:`. Die Untergrenze der ok:-Zeilen steigt von 64 auf 74
# (63 + 1 + 10; der Harness druckt mit dem Off-Loopback-Fall 75).
#
# 79-47 (D-34, Nutzerentscheidung "beta.2: auch App-Uebernahme"): ein App-Spulen im Browse-Betrieb laesst den Daemon
# selbst flushen; der unarmierte Flush schloss bisher LMS' Strom, LMS las EOF und spielte den naechsten Titel. Mit
# POST /browse-keep?on=1 (Control setzt es ab 79-48) haelt ein unarmierter Flush den Client. Sechs Namen `browse: ...`:
# Flush mit Keep haelt den Client (S1), ohne Keep bzw. nach on=0 schliesst er wie bisher (S2), Drain-POST und neuer
# GET /stream beenden den alten Titel weiterhin (S3), ein armierter Flush verbraucht den Arm (S4), ein POST ohne on=
# wird mit 400 abgewiesen (S5). Die Mutante schneidet den markierten Block D-34 BROWSE_KEEP_BEGIN/END aus dem
# Quelltext (der alte unarmierte Flush-Disconnect) und laeuft im Nur-Browse-Modus (FAKE_LIBPULSE_TEST_BROWSE_ONLY=1):
# sie MUSS S1 verfehlen, der unveraenderte Harness MUSS ihn bestehen. Die Untergrenze der ok:-Zeilen steigt von 74
# auf 80.
#
# 79-50 (D-34 R2, Nutzerentscheidung "beta.2: das App-Spulen im Connect darf die Wiedergabe nicht beenden"): im Connect-Betrieb
# laesst ein App-Spulen den Daemon selbst flushen; der unarmierte Flush schloss LMS' Strom 9 ms spaeter, LMS las EOF und stoppte
# etwa 6,5 s danach (79-47 R2, R2_3). Perl erfaehrt erst 6-8 ms nach dem Flush, dass es ein Spulen war (der erste Daemon-Frame).
# Darum haelt der Shim einen unarmierten Flush-Disconnect jetzt FLUSH_DECIDE_MS lang offen (SPOTON_FAKEPULSE_FLUSH_DECIDE_MS,
# Standard 2000, 0 = kein Fenster) und haelt das Audio nach dem Flush zurueck; POST /seek-keep haelt den Client, POST /boundary
# (der Skip) oder die Frist schliesst ihn. Zwoelf Namen `connect: R2-C...` (elf Pflicht, der Off-Loopback-Fall druckt ohne
# nicht-lokale IPv4 `skip:` und steht nicht in der Liste): Keep haelt den Client (C1), Boundary schliesst sofort (C2), ohne Signal
# schliesst die Frist (C3), ein Keep nach dem Boundary wird abgewiesen (C4), ein Keep ohne Anstehendes aendert nichts (C5), Fenster 0
# ist der alte Vertrag (C6), ein stehender Schreibvorgang wird nie mittendrin abgeschnitten (C7), der Browse-Keep von 79-47 oeffnet
# kein Fenster (C8), ein wartender GET /stream ueberlebt einen Steuer-Neuankoemmling (C9, B1), ein verspaeteter /seek-arm beendet das
# Fenster (C10, W4), ein Takeover beendet es (C11, M1). Drei Mutanten laufen im Nur-Connect-Modus (FAKE_LIBPULSE_TEST_CONNECT_ONLY=1):
# der geschnittene Block D-34 R2_DEFER_BEGIN/END (sofortiger Disconnect) MUSS C1 verfehlen, der geschnittene Block R2_PROMOTE_BEGIN/END
# (das Boundary beendet das Fenster nicht) C2, und der durch die alte Zeile ersetzte Block R2_TAKEOVER_BEGIN/END C11. Die Untergrenze
# der ok:-Zeilen steigt von 80 auf 91.
#
# 79-51 (Runaway D2, .planning/debug/album-start-connect-runaway.md, E4/E5): ein Album-Start im pausierten Connect-Betrieb
# endete in "LMS ended in stop", weil ein Plant mit niemandem angeschlossen von LMS' frischem Strom geerbt wurde und diesen nach
# 0 Bytes schloss (094204 :25.328/.338 und 094408 :20.536/.550, jeweils `gen=-1 via=none ring_fill=0`). Der Shim vermerkt jetzt
# auch den Client eines begrenzten EOF als gegangen (g_departed_client_generation, beide Schliessstellen; Bloecke
# `79-51 D2_DEPART_BEGIN/END`, genau zwei) und verwirft beim Anschluss eines neuen Clients einen Waisen-Marker, der auf oder
# unter total_popped steht (Block `79-51 D2_ORPHAN_BEGIN/END`, genau einer; Log `boundary_discarded: orphan at attach`). Sieben
# Namen `runaway: D2-C...`: ein begrenztes EOF vermerkt seinen Client, der naechste Plant liest via=departed und der frische Client
# wird bedient (C1), ein Waisen-Marker auf dem Lesezeiger wird beim Anschluss verworfen (C2), D-04 bleibt (Marker ueber total_popped
# ohne Vermerk wird geerbt, C3), der Vermerk ist einmalig (C4), ein Anschluss loescht ihn (C5), nach begrenztem EOF plus Skip-Flush
# wird der Marker beim Anschluss verworfen und der naechste Titel nicht bei 8192 Bytes abgeschnitten (C6), und die Kosten ohne
# Flush sind festgeschrieben (C7: der Zwischeneintrag wird nicht mehr begrenzt). Zwei Mutanten laufen im Nur-Runaway-Modus
# (FAKE_LIBPULSE_TEST_RUNAWAY_ONLY=1): beide geschnittenen D2_DEPART-Bloecke MUESSEN C1 (die Plant-Antwort) UND C6 (der Vermerk
# selbst) verfehlen, der geschnittene D2_ORPHAN-Block C2. Die Untergrenze der ok:-Zeilen steigt von 91 auf 98.
#
# Der Test uebersetzt fake-libpulse.c mit -DFAKE_LIBPULSE_TEST in ein
# Temp-Verzeichnis (kein Build-Artefakt im Quellbaum), fuehrt den Harness
# aus und macht aus jeder `ok:`-/`FAIL:`-Zeile einen TAP-Punkt. Ohne
# C-Compiler oder ausserhalb von Linux: skip_all.

use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use Cwd qw(abs_path);

my $project_dir = dirname(dirname(dirname(abs_path($0))));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";
my $src         = "$project_dir/Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c";

plan skip_all => 'fake-libpulse harness is Linux-only' unless $^O eq 'linux';
die "missing $src (84-09: die, never skip)\n" unless -f $src;

my $cc;
for my $cand (grep { defined && length } ($ENV{CC}, 'gcc', 'cc')) {
    my $found = `command -v $cand 2>/dev/null`;
    chomp $found;
    if (length $found) { $cc = $found; last; }
}
plan skip_all => 'no C compiler (gcc/cc) available' unless $cc;

my $tmp = tempdir('fake-libpulse-harness-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $bin = "$tmp/fake-libpulse-test";

# Same flags as the Makefile's `fake-libpulse-test` target.
my $build = `"$cc" -O2 -Wall -Wextra -DFAKE_LIBPULSE_TEST -o "$bin" "$src" -lpthread -lm 2>&1`;
my $build_rc = $? >> 8;
is($build_rc, 0, 'harness compiles (-DFAKE_LIBPULSE_TEST)') or diag($build);
unlike($build, qr/warning:/, 'harness compiles without warnings') or diag($build);
if ($build_rc != 0) {
    done_testing();
    exit;
}

my $timeout = -x '/usr/bin/timeout' ? '/usr/bin/timeout 180 ' : '';
my $out = `$timeout"$bin" 2>&1`;
my $run_rc = $? >> 8;

my @ok   = ($out =~ /^ok: (.*)$/mg);
my @fail = ($out =~ /^FAIL: (.*)$/mg);

pass("harness: $_") for @ok;
fail("harness: $_") for @fail;

is($run_rc, 0, 'harness exits 0') or diag($out);
like($out, qr/^All fake-libpulse HTTP mode tests passed$/m, 'harness reports all tests passed');
cmp_ok(scalar(@ok), '>=', 98, 'harness ran at least the 98 known checks') or diag($out);

# The regression tests of this session must stay in the harness -- a
# silently deleted test would otherwise still leave "All ... passed".
for my $want (
    qr/^ok: queued seek-arm at flush time cancels the flush-disconnect/m,
    qr/^ok: unarmed flush without a queued arm still disconnects \(negative control\)/m,
    qr/^ok: seek-arm in the backlog at flush-disconnect time cancels it/m,
    qr/^ok: seek-arm in the pending at flush-disconnect time cancels it/m,
    qr/^ok: pending seek-arm survives a racing GET/m,
    qr/^ok: queued boundary at flush time survives the backlog pass/m,
    qr/^ok: seek-armed flush keeps client attached and serves only post-flush bytes/m,
    # debug connect-skip-prev-ton-bleibt (2026-09-24, decision 2A)
    qr/^ok: a boundary planted after an unarmed flush-disconnect belongs to the departed client/m,
    # 84-17 (L1 repair): POST /boundary answers with the shim's own skip/natural-end fact,
    # the drained-end placement, the drop counter and pops only up to the marker
    qr/^ok: boundary reply body carries via=live/m,
    qr/^ok: boundary reply body carries via=departed/m,
    qr/^ok: boundary reply body carries via=none/m,
    qr/^ok: live boundary anchored at the drain point/m,
    qr/^ok: live boundary without the anchor query is planted at total_pushed/m,
    qr/^ok: ring drop counter counts dropped bytes/m,
    qr/^ok: bounded EOF pops nothing past the marker/m,
    qr/^ok: bounded EOF exactly at the marker closes without a pop/m,
    # 84-17 (found live in the long-tail proof): the control endpoints are served while a client write is stalled
    qr/^ok: control POST is answered while the client write is stalled/m,
    # 84-17 (user decision: never discard, the daemon waits)
    qr/^ok: full ring: the writer waits and nothing is discarded/m,
    qr/^ok: flush releases a waiting writer and abandons the stale chunk/m,
    qr/^ok: write ceiling releases a stuck writer and counts the refusal/m,
    qr/^ok: a skip's pending flush-disconnect is answered via=departed at once/m,
    qr/^ok: writable_size reports the free space minus the reserve/m,
    qr/^ok: a daemon that stops at writable_size 0 never waits in the shim and loses nothing/m,
    # 84-20 (Q2): the virtual sink
    qr/^ok: vsink: writable_size reaches 0 after T ms written while corked/m,
    qr/^ok: vsink: a corked stream keeps writable_size at 0 while the clock runs/m,
    qr/^ok: vsink: an uncorked stream regains writable_size at the wall-clock rate/m,
    qr/^ok: vsink: uncork restarts the drain clock so a corked interval never drains/m,
    qr/^ok: vsink: flush empties the virtual sink/m,
    qr/^ok: vsink: no underflow_cb while the virtual sink holds data/m,
    qr/^ok: vsink: underflow_cb fires once when the virtual sink and the ring are empty/m,
    qr/^ok: vsink: read_index and sink_usec include the virtual sink/m,
    qr/^ok: vsink: S16 input fills the virtual sink in output bytes/m,
    qr/^ok: vsink: writable_size never exceeds the real free space minus the reserve/m,
    qr/^ok: vsink: default T applies when the env is unset/m,
    qr/^ok: vsink: T 0 keeps the 84-17 writable contract/m,
    qr/^ok: vsink: underrun edge survives push\/flush hammering with the virtual sink on/m,
    # 84-22 (F-20-WRITER): the writer no longer departs on a slow reader
    qr/^ok: writer: a client that stops reading for 4 s stays attached and gets contiguous bytes/m,
    qr/^ok: writer: a flush during a stalled write returns within one tick and closes via the flush path/m,
    qr/^ok: writer: a takeover during a stalled write is served/m,
    qr/^ok: writer: the orphan bound closes a never-reading client after the configured time/m,
    qr/^ok: writer: the orphan bound defaults to 180000 ms when the env is unset/m,
    qr/^ok: writer: a pending connection that never completes its request head is expired while a write is stalled/m,
    # 79-07 (84 WR-01): teardown waits for a blocked writer; unref of a stale stream leaves the epoch alone
    qr/^ok: pa_stream_unref returns only after a blocked writer left pa_stream_write/m,
    qr/^ok: unref of a non-active stream leaves flush_epoch unchanged/m,
    # quick-261022-ca3: the reconnect latency check and the second-boundary self-test of the read helpers
    qr/^ok: reconnect after flush-disconnect attaches and drains immediately/m,
    qr/^ok: test helpers: a sub-second read budget is measured in elapsed milliseconds across a wall-clock second boundary/m,
    # 79-37 D-31: the gap hold
    qr/^ok: hold: archive natural end leaves zero bytes of the next title in the old stream/m,
    qr/^ok: hold: without a POST the hold times out and the held bytes are served, none lost/m,
    qr/^ok: hold: an armed flush clears the hold and the kept client gets only post-flush bytes/m,
    qr/^ok: hold: an unarmed flush clears the hold and the departing client gets no byte of the next title/m,
    qr/^ok: hold: a fresh client is never held/m,
    qr/^ok: hold: steady playback never arms a hold/m,
    qr/^ok: hold: POST \/hold-release releases an active hold at once/m,
    qr/^ok: hold: POST \/hold-release before the refill suppresses the next arming/m,
    qr/^ok: hold: a plain POST \/boundary releases the hold and plants at total_pushed/m,
    qr/^ok: hold: HOLD_GAP_MS 0 turns the hold off/m,
    qr/^ok: hold: the hold arms when the monotonic clock reads negative \(32-bit wrap\)/m,
    # 79-47 D-34: browse keep
    qr/^ok: browse: with browse keep set an unarmed flush keeps the client and it gets only post-flush bytes/m,
    qr/^ok: browse: without browse keep an unarmed flush still closes the client \(never set, and after on=0\)/m,
    qr/^ok: browse: with browse keep set the drain POST \/boundary still ends the title and the gap hold applies/m,
    qr/^ok: browse: with browse keep set a new GET \/stream still supersedes the old client/m,
    qr/^ok: browse: with browse keep set an armed flush consumes the arm and keeps the client/m,
    qr/^ok: browse: a POST \/browse-keep without on=0 or on=1 is refused and changes nothing/m,
    # 79-50 D-34 R2: the connect decision window
    qr/^ok: connect: R2-C1 a keep inside the decision window keeps the client and it gets the post-flush bytes/m,
    qr/^ok: connect: R2-C2 a boundary inside the decision window closes the old client at once with no byte of the next title/m,
    qr/^ok: connect: R2-C3 with no signal the window closes the client at its deadline and withholds the next title/m,
    qr/^ok: connect: R2-C4 a keep after a boundary is refused and the client still ends/m,
    qr/^ok: connect: R2-C5 a keep with nothing pending is a no-op \(no arm, audio flows\) and a later unarmed flush still opens a window/m,
    qr/^ok: connect: R2-C6 with window 0 an unarmed flush closes at the next tick as before 79-50/m,
    qr/^ok: connect: R2-C7 a keep while a write is stalled completes the chunk in flight and then delivers the post-flush bytes/m,
    qr/^ok: connect: R2-C8 with browse keep set an unarmed flush keeps the client and opens no decision window/m,
    qr/^ok: connect: R2-C9 a \/seek-keep arriving while a GET \/stream waits in the pending slot is served in place and the GET survives/m,
    qr/^ok: connect: R2-C10 a late seek-arm consumed by the pending disconnect ends the window and the audio flows/m,
    qr/^ok: connect: R2-C11 a takeover inside the decision window ends the window: the new client gets audio and is not closed at the deadline/m,
    # 79-51 runaway D2: the departed record at a bounded close, the orphan discard at promotion
    qr/^ok: runaway: D2-C1 a bounded EOF records its client: the next plant \(nobody attached, ring empty\) reads via=departed and the fresh client is not closed at 0 bytes/m,
    qr/^ok: runaway: D2-C2 an orphan plant at or below total_popped is discarded when the next client attaches \(the fresh client is served\)/m,
    qr/^ok: runaway: D2-C3 a plant above total_popped with no departed record is still inherited/m,
    qr/^ok: runaway: D2-C4 the departed record is one-shot: a second plant with nobody attached reads via=none/m,
    qr/^ok: runaway: D2-C5 a live attach clears the departed record: a plant while the new client is attached reads via=live with its generation/m,
    qr/^ok: runaway: D2-C6 after a bounded EOF and a skip flush the next plant reads via=departed and its marker is discarded at the attach/m,
    qr/^ok: runaway: D2-C7 after a bounded EOF without a flush the next plant is discarded at the attach/m,
) {
    like($out, $want, "regression check present: $want");
}

# 79-37 D-31: the hold-cap mutant. The archive cell must be able to FAIL: cut the marked cap block out of the
# source, build that, and run it in hold-only mode -- it MUST fail the cell; the real binary MUST pass it.
{
    open(my $sfh, '<', $src) or die "cannot read $src: $!";
    my $code = do { local $/; <$sfh> };
    close $sfh;
    my $begins = () = $code =~ /D-31 HOLD_CAP_BEGIN/g;
    my $ends   = () = $code =~ /D-31 HOLD_CAP_END/g;
    my $cut    = $code;
    my $nrep   = ($cut =~ s{/\* D-31 HOLD_CAP_BEGIN \*/.*?/\* D-31 HOLD_CAP_END \*/}{}s) || 0;
    my $one    = ($begins == 1 && $ends == 1 && $nrep == 1 && $cut ne $code) ? 1 : 0;
    ok($one, '79-37 D-31: the hold-cap mutant source differs from the real source at exactly one marked block')
        or diag("begin markers=$begins end markers=$ends replaced=$nrep");

    my ($mcompiled, $mout, $mrc) = (0, '', 0);
    if ($one) {
        my $msrc = "$tmp/fake-libpulse-mutant.c";
        my $mbin = "$tmp/fake-libpulse-mutant";
        open(my $mfh, '>', $msrc) or die "cannot write $msrc: $!";
        print $mfh $cut;
        close $mfh;
        my $mbuild = `"$cc" -O2 -Wall -Wextra -DFAKE_LIBPULSE_TEST -o "$mbin" "$msrc" -lpthread -lm 2>&1`;
        $mcompiled = (($? >> 8) == 0 && -x $mbin) ? 1 : 0;
        diag($mbuild) unless $mcompiled;
        if ($mcompiled) {
            $mout = `FAKE_LIBPULSE_TEST_HOLD_ONLY=1 $timeout"$mbin" 2>&1`;
            $mrc  = $? >> 8;
        }
    }
    ok($mcompiled, '79-37 D-31: the hold-cap mutant compiles');
    ok(($mcompiled && $mrc != 0 && $mout =~ /^FAIL: hold: archive natural end/m) ? 1 : 0,
       '79-37 D-31: the hold-cap mutant fails the zero-residual cell')
        or diag("mutant exit=$mrc output:\n$mout");

    my $hout = `FAKE_LIBPULSE_TEST_HOLD_ONLY=1 $timeout"$bin" 2>&1`;
    my $hrc  = $? >> 8;
    ok(($hrc == 0 && $hout =~ /^ok: hold: archive natural end/m && $hout !~ /^FAIL: /m) ? 1 : 0,
       '79-37 D-31: the unmutated harness passes the zero-residual cell in hold-only mode')
        or diag("hold-only exit=$hrc output:\n$hout");
}

# 79-47 D-34: the browse-keep mutant. The S1 cell must be able to FAIL: cut the marked keep block out of the source
# (what is left is the old unarmed flush-disconnect), build that, and run it in browse-only mode -- it MUST fail S1;
# the real binary MUST pass every browse cell in that mode.
{
    open(my $sfh, '<', $src) or die "cannot read $src: $!";
    my $code = do { local $/; <$sfh> };
    close $sfh;
    my $begins = () = $code =~ /D-34 BROWSE_KEEP_BEGIN/g;
    my $ends   = () = $code =~ /D-34 BROWSE_KEEP_END/g;
    my $cut    = $code;
    my $nrep   = ($cut =~ s{/\* D-34 BROWSE_KEEP_BEGIN \*/.*?/\* D-34 BROWSE_KEEP_END \*/}{}s) || 0;
    my $one    = ($begins == 1 && $ends == 1 && $nrep == 1 && $cut ne $code) ? 1 : 0;
    ok($one, '79-47 D-34: the browse-keep mutant source differs from the real source at exactly one marked block')
        or diag("begin markers=$begins end markers=$ends replaced=$nrep");

    my ($mcompiled, $mout, $mrc) = (0, '', 0);
    if ($one) {
        my $msrc = "$tmp/fake-libpulse-browse-mutant.c";
        my $mbin = "$tmp/fake-libpulse-browse-mutant";
        open(my $mfh, '>', $msrc) or die "cannot write $msrc: $!";
        print $mfh $cut;
        close $mfh;
        my $mbuild = `"$cc" -O2 -Wall -Wextra -DFAKE_LIBPULSE_TEST -o "$mbin" "$msrc" -lpthread -lm 2>&1`;
        $mcompiled = (($? >> 8) == 0 && -x $mbin) ? 1 : 0;
        diag($mbuild) unless $mcompiled;
        if ($mcompiled) {
            $mout = `FAKE_LIBPULSE_TEST_BROWSE_ONLY=1 $timeout"$mbin" 2>&1`;
            $mrc  = $? >> 8;
        }
    }
    ok($mcompiled, '79-47 D-34: the browse-keep mutant compiles');
    ok(($mcompiled && $mrc != 0 && $mout =~ /^FAIL: browse: with browse keep set an unarmed flush keeps the client/m) ? 1 : 0,
       '79-47 D-34: the browse-keep mutant fails the keep cell (old unarmed flush-disconnect)')
        or diag("mutant exit=$mrc output:\n$mout");

    my $bout = `FAKE_LIBPULSE_TEST_BROWSE_ONLY=1 $timeout"$bin" 2>&1`;
    my $brc  = $? >> 8;
    my $bok  = () = $bout =~ /^ok: browse: /mg;
    ok(($brc == 0 && $bok == 6 && $bout !~ /^FAIL: /m) ? 1 : 0,
       '79-47 D-34: the unmutated harness passes all six browse cells in browse-only mode')
        or diag("browse-only exit=$brc ok=$bok output:\n$bout");
}

# 79-50 D-34 R2: the three decision-window mutants. Each cell must be able to FAIL: the marked block is cut (or, for the
# takeover, replaced by the line that was there before 79-50), the result built and run in connect-only mode -- it MUST fail
# its cell; the real binary MUST pass every connect cell in that mode. Each check also proves that the source differs from the
# real one at exactly one marked block.
{
    open(my $sfh, '<', $src) or die "cannot read $src: $!";
    my $code = do { local $/; <$sfh> };
    close $sfh;
    my $r2n = 0;
    for my $m (
        [ 'MUT_DEFER',    'R2_DEFER',    '',
          qr/^FAIL: connect: R2-C1 /m,  'the decision hold-back (an unarmed flush closes at once again)' ],
        [ 'MUT_PROMOTE',  'R2_PROMOTE',  '',
          qr/^FAIL: connect: R2-C2 /m,  'the boundary promotion (a boundary no longer ends the window)' ],
        [ 'MUT_TAKEOVER', 'R2_TAKEOVER', "if (!was_supersede && g_flush_disconnect) g_flush_disconnect = 0;\n",
          qr/^FAIL: connect: R2-C11 /m, 'the takeover clear (the window outlives a takeover and closes the new client)' ],
    ) {
        my ($label, $tag, $repl, $want, $what) = @$m;
        my $begins = () = $code =~ /D-34 ${tag}_BEGIN/g;
        my $ends   = () = $code =~ /D-34 ${tag}_END/g;
        my $cut    = $code;
        my $nrep   = ($cut =~ s{/\* D-34 ${tag}_BEGIN \*/.*?/\* D-34 ${tag}_END \*/}{$repl}s) || 0;
        my $one    = ($begins == 1 && $ends == 1 && $nrep == 1 && $cut ne $code) ? 1 : 0;
        ok($one, "79-50 D-34 R2: the $label mutant source differs from the real source at exactly one marked block")
            or diag("begin markers=$begins end markers=$ends replaced=$nrep");

        my ($mcompiled, $mout, $mrc) = (0, '', 0);
        if ($one) {
            $r2n++;
            my $msrc = "$tmp/fake-libpulse-r2-mutant-$r2n.c";
            my $mbin = "$tmp/fake-libpulse-r2-mutant-$r2n";
            open(my $mfh, '>', $msrc) or die "cannot write $msrc: $!";
            print $mfh $cut;
            close $mfh;
            my $mbuild = `"$cc" -O2 -Wall -Wextra -DFAKE_LIBPULSE_TEST -o "$mbin" "$msrc" -lpthread -lm 2>&1`;
            $mcompiled = (($? >> 8) == 0 && -x $mbin) ? 1 : 0;
            diag($mbuild) unless $mcompiled;
            if ($mcompiled) {
                $mout = `FAKE_LIBPULSE_TEST_CONNECT_ONLY=1 $timeout"$mbin" 2>&1`;
                $mrc  = $? >> 8;
            }
        }
        ok($mcompiled, "79-50 D-34 R2: the $label mutant compiles");
        ok(($mcompiled && $mrc != 0 && $mout =~ $want) ? 1 : 0,
           "79-50 D-34 R2: the $label mutant fails its cell: $what")
            or diag("mutant exit=$mrc output:\n$mout");
    }

    my $cout = `FAKE_LIBPULSE_TEST_CONNECT_ONLY=1 $timeout"$bin" 2>&1`;
    my $crc  = $? >> 8;
    my $cok  = () = $cout =~ /^ok: connect: R2-C\d+ /mg;
    ok(($crc == 0 && $cok == 11 && $cout !~ /^FAIL: /m) ? 1 : 0,
       '79-50 D-34 R2: the unmutated harness passes all eleven connect cells in connect-only mode')
        or diag("connect-only exit=$crc ok=$cok output:\n$cout");
}

# 79-51 runaway D2: the two shim mutants. MUT_D2_DEPART cuts BOTH `79-51 D2_DEPART` blocks (a bounded EOF no longer records its
# client): in runaway-only mode it MUST fail C1 (the plant reads via=none) AND C6 (the record's own effect: the next title is bounded at
# the marker again). MUT_D2_ORPHAN cuts the one `79-51 D2_ORPHAN` block (the orphan marker is inherited again): it MUST fail C2. The
# unmutated binary MUST pass all seven runaway cells in that mode. Each check also proves the source differs from the real one at
# exactly the expected number of marked blocks.
{
    open(my $sfh, '<', $src) or die "cannot read $src: $!";
    my $code = do { local $/; <$sfh> };
    close $sfh;
    my $r51n = 0;
    for my $m (
        [ 'MUT_D2_DEPART', 'D2_DEPART', 2, [ qr/^FAIL: runaway: D2-C1 /m, qr/^FAIL: runaway: D2-C6 /m ],
          'the departed record at both bounded-EOF closes (the next plant reads via=none and is inherited again)' ],
        [ 'MUT_D2_ORPHAN', 'D2_ORPHAN', 1, [ qr/^FAIL: runaway: D2-C2 /m ],
          'the orphan discard at the attach (the fresh client is closed at 0 bytes again)' ],
    ) {
        my ($label, $tag, $want_n, $wants, $what) = @$m;
        my $begins = () = $code =~ /79-51 ${tag}_BEGIN/g;
        my $ends   = () = $code =~ /79-51 ${tag}_END/g;
        my $cut    = $code;
        my $nrep   = ($cut =~ s{/\* 79-51 ${tag}_BEGIN \*/.*?/\* 79-51 ${tag}_END \*/}{}sg) || 0;
        my $one    = ($begins == $want_n && $ends == $want_n && $nrep == $want_n && $cut ne $code) ? 1 : 0;
        ok($one, "79-51 runaway D2: the $label mutant source differs from the real source at exactly $want_n marked block(s)")
            or diag("begin markers=$begins end markers=$ends replaced=$nrep (want $want_n)");

        my ($mcompiled, $mout, $mrc) = (0, '', 0);
        if ($one) {
            $r51n++;
            my $msrc = "$tmp/fake-libpulse-r51-mutant-$r51n.c";
            my $mbin = "$tmp/fake-libpulse-r51-mutant-$r51n";
            open(my $mfh, '>', $msrc) or die "cannot write $msrc: $!";
            print $mfh $cut;
            close $mfh;
            my $mbuild = `"$cc" -O2 -Wall -Wextra -DFAKE_LIBPULSE_TEST -o "$mbin" "$msrc" -lpthread -lm 2>&1`;
            $mcompiled = (($? >> 8) == 0 && -x $mbin) ? 1 : 0;
            diag($mbuild) unless $mcompiled;
            if ($mcompiled) {
                $mout = `FAKE_LIBPULSE_TEST_RUNAWAY_ONLY=1 $timeout"$mbin" 2>&1`;
                $mrc  = $? >> 8;
            }
        }
        ok($mcompiled, "79-51 runaway D2: the $label mutant compiles");
        my $all = ($mcompiled && $mrc != 0 && !grep { $mout !~ $_ } @$wants) ? 1 : 0;
        ok($all, "79-51 runaway D2: the $label mutant fails its cell(s): $what")
            or diag("mutant exit=$mrc output:\n$mout");
    }

    my $rout = `FAKE_LIBPULSE_TEST_RUNAWAY_ONLY=1 $timeout"$bin" 2>&1`;
    my $rrc  = $? >> 8;
    my $rok  = () = $rout =~ /^ok: runaway: D2-C\d+ /mg;
    ok(($rrc == 0 && $rok == 7 && $rout !~ /^FAIL: /m) ? 1 : 0,
       '79-51 runaway D2: the unmutated harness passes all seven runaway cells in runaway-only mode')
        or diag("runaway-only exit=$rrc ok=$rok output:\n$rout");
}

done_testing();

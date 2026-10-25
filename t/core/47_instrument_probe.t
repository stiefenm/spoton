#!/usr/bin/perl

# t/47_instrument_probe.t
#
# Debug-Sitzung `instrument-probe-vakuumverdikt` (2026-09-23) -- vier Befunde
# aus dem Phasen-Review 83 (`83-REVIEW.md` CR-01, WR-04, WR-05, WR-06) gegen
# `tools/uat/instrument-probe.pl`. Alle vier haben dieselbe Wurzel: ein
# Messinstrument berichtet, was es nicht gemessen hat.
#
#   - CR-01: `ws-handshake` faellt auf `I2_VERDIKT=IMMER_IM_ARCHIV` durch,
#     sobald `n_ohne == 0` -- auch bei `n_mit == 0`. Dateien ohne
#     `playback_state` nach dem Handshake erhoehen KEINEN der beiden Zaehler.
#     Ein Urteil "Position immer vorhanden" aus null Beobachtungen.
#   - WR-04: `ws-cadence` dereferenziert `position` ohne HASH-Wache. Ein
#     einziger Frame mit skalarem `position` reisst den GESAMTEN Lauf mit
#     exit 255 ab -- vor jeder SUMMARY- und RESIDUUM-Zeile, also verliert ein
#     schlechter Frame jeden Zaehler jeder Datei.
#   - WR-05: `ticker`/`blocks`/`transitions`/`stillstand` nehmen `my ($path)
#     = @_` und sterben nur bei undefiniertem `$path`. Ein Shell-Glob ueber
#     zwei Daemon-Logs liefert ein Urteil ueber die erste Datei, ohne dass
#     die zweite je gelesen wurde -- wortlos.
#   - WR-06: Referenzereignisse (`boundary_planted:` /
#     `pa_stream_flush(stream=`) ohne geerbtes Datum verschwinden ohne
#     Restzaehler; nach einem Mitternachtswechsel erben sie den Vortag und
#     liegen 24 h daneben. `REFERENZ_DATUMSHERKUNFT` behauptete fuer JEDE
#     Datei fest verdrahtet, was nur fuer einen Schnappschuss gemessen war.
#   - SW-01 (Geschwisterbefund aus der Pflicht-Geschwistersuche zu CR-01):
#     `classify_forward` hat dieselbe Bauform. Ist der Ausloeser die letzte
#     Ticker-Zeile der Datei, laeuft die Vorwaertsschleife nullmal und der
#     Durchfall liefert `echter_stillstand` -- die staerkste der drei Klassen
#     aus null Beobachtungen. Nutzerentscheidung: ADDITIV ZAEHLEN, nicht
#     umklassifizieren (siehe Kopf des fuenften Subtests).
#
# Nutzerentscheidung zu WR-06 (Debug-File "Entscheidungen des Nutzers"):
# NUR ZAEHLEN, NICHT REPARIEREN. Die im Review vorgeschlagene +24-h-Heuristik
# wird ausdruecklich NICHT eingebaut -- die Sonde meldet den Fall sichtbar,
# statt eine ungepruefte Annahme ueber das Material zu treffen und
# plausibel-falsche Anker zu liefern. Dieser Test haelt beide Richtungen
# fest: die Zaehler MUESSEN erscheinen, und die Klassifikation der falsch
# datierten Grenze MUSS unveraendert bleiben.
#
# Jeder Fall wurde vor dem Patch gegen den ungepatchten Stand gefahren und
# war dort ROT (fuenf von fuenf Subtests; beim fuenften genau die drei
# Zaehler-Behauptungen, waehrend die zwoelf Behauptungen der Gegenrichtung
# schon vorher bestanden -- das Tor unterscheidet, statt pauschal rot zu
# sein). Zusaetzlich laufen die Unterbefehle
# ueber ECHTES Archivmaterial -- `t/fixtures/soloist/*.jsonl` (zwoelf
# Mitschnitte) und, wenn vorhanden, den Daemon-Log-Schnappschuss der Phase 83
# ausserhalb des Repos. Ein rein synthetischer Trockenlauf belegt nur die
# Formel, nicht das Verhalten am Material.
#
# Blackbox-only, wie t/46_uat_tools.t: jede Behauptung ruft das echte Skript
# ueber exec() in LIST-Form und prueft Exitcode plus stdout/stderr.
# Vollstaendig offline -- kein LMS, kein Daemon, kein Geraet, kein Hoerbefund.

use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use Cwd qw(abs_path);

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";
my $probe       = "$project_dir/tools/uat/instrument-probe.pl";

unless (-f $probe) {
    die "tools/uat/instrument-probe.pl not present in this checkout -- wrong project root or broken checkout (84-09: die, never skip)\n";
}

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined($c) ? $c : '';
}

# ============================================================
# Helper: run_probe(@args) -- fuehrt die Sonde aus und liefert
# ($exit, $stdout, $stderr). exec() in LIST-Form, keine Shell.
#
# Trockenlauf und Live-Lauf teilen NIE eine Ausgabeadresse: jeder Aufruf
# bekommt ein eigenes frisches Verzeichnis und prueft vor dem Start, dass die
# Adresse leer ist. Eine stehengebliebene Vorausgabe liesse eine Behauptung
# sonst vakuos mit exit=0 bestehen.
# ============================================================
sub run_probe {
    my (@args) = @_;
    my $dir = tempdir(CLEANUP => 1);
    my $out = "$dir/stdout";
    my $err = "$dir/stderr";
    die "run_probe: Ausgabeadresse $out war nicht frisch" if -e $out || -e $err;

    my $pid = fork();
    die "run_probe: fork fehlgeschlagen: $!" unless defined $pid;
    if ($pid == 0) {
        open STDOUT, '>', $out or exit 127;
        open STDERR, '>', $err or exit 127;
        exec($^X, $probe, @args);
        exit 127;
    }
    waitpid($pid, 0);
    my $exit = $? >> 8;
    return ($exit, slurp($out), slurp($err));
}

# ============================================================
# Helper: grab_line($text, $regex) -- liefert die ERSTE passende Ausgabezeile.
#
# Haelt die Diagnostik klein und die Behauptung scharf: ein like() gegen die
# Volltextausgabe des echten Schnappschusses (ueber 180 Ankerzeilen) waere im
# Fehlerfall unlesbar, und is() auf der herausgeschnittenen Zeile prueft die
# GANZE Zeile statt nur eines Teilstuecks.
# ============================================================
sub grab_line {
    my ($text, $re) = @_;
    for my $l (split /\n/, $text) {
        return $l if $l =~ $re;
    }
    return '(keine passende Zeile)';
}

# write_fixture($dir, $name, @lines) -- legt eine Fixture an, nie zweimal
# dieselbe Adresse.
sub write_fixture {
    my ($dir, $name, @lines) = @_;
    my $path = "$dir/$name";
    die "write_fixture: $path existiert bereits" if -e $path;
    open my $fh, '>', $path or die "write_fixture: $path: $!";
    print {$fh} "$_\n" for @lines;
    close $fh;
    return $path;
}

# Die zwoelf Mitschnitte der Phasen 81-84 sind das protokollierte Archiv, auf dem die festen Zahlen unten
# beruhen. Phase-85-Mitschnitte (s85-*) kommen als weitere Fixtures hinzu, gehoeren aber nicht zu dieser
# Messung und verschieben sie nicht (85-03: s85-get-queue-reply.jsonl hat n_mit 12 -> 13 gemacht).
my @real_fixtures = grep { $_ !~ m{/s85-[^/]*\.jsonl\z} } sort glob("$project_dir/t/fixtures/soloist/*.jsonl");

# Echter Daemon-Log-Schnappschuss der Phase 83 (liegt ausserhalb des Repos,
# weil 24 MB / 351660 Zeilen). Vorhanden -> die WR-06-Zaehler werden
# zusaetzlich gegen echtes Material geprueft; fehlt er -> sauber uebersprungen.
my $real_daemon_log = ($ENV{HOME} // '') . '/SynologyDrive/dev/spoton-messdaten/83-instrumente/pa-soloist.log';

# ============================================================
# CR-01 -- ws-handshake darf kein IMMER_IM_ARCHIV aus null Beobachtungen
# ============================================================
subtest 'CR-01: ws-handshake urteilt nicht aus null Beobachtungen' => sub {
    my $dir = tempdir(CLEANUP => 1);

    # (1) MUSS-GREIFEN: nur der HANDSHAKE-OK-Metaframe, kein playback_state.
    # Ungepatcht: I2_VERDIKT=IMMER_IM_ARCHIV n_mit=0 n_ohne=0 -- "Position
    # immer vorhanden" aus null Beobachtungen.
    my $leer = write_fixture($dir, 'nur-handshake.jsonl',
        '{"dir":"meta","epoch":1.0,"frame":"HANDSHAKE-OK"}');
    my ($exit, $out) = run_probe('ws-handshake', $leer);
    is($exit, 0, 'ws-handshake laeuft durch');
    is(grab_line($out, qr/^I2_VERDIKT=/),
        'I2_VERDIKT=UNENTSCHEIDBAR n_mit=0 n_ohne=0 n_ohne_handshake=0',
        'null Beobachtungen -> UNENTSCHEIDBAR, nicht IMMER_IM_ARCHIV');
    is(grab_line($out, qr/^RESIDUUM_OHNE_PLAYBACK_STATE=/),
        'RESIDUUM_OHNE_PLAYBACK_STATE=1',
        'die uebersprungene Datei steht in einem sichtbaren Restzaehler');

    # (2) GEGENRICHTUNG: mit echter Beobachtung MUSS IMMER_IM_ARCHIV weiter
    # erreichbar bleiben -- sonst waere die Korrektur ein Tor, das nicht
    # bestehen kann, statt eines, das nicht luegen kann.
    my $mit = write_fixture($dir, 'mit-position.jsonl',
        '{"dir":"meta","epoch":1.0,"frame":"HANDSHAKE-OK"}',
        '{"dir":"rx","epoch":1.5,"frame":"{\"type\":\"playback_state\",\"position\":{\"position_ms\":1000,\"timestamp_ms\":2,\"speed\":1}}"}');
    my ($exit2, $out2) = run_probe('ws-handshake', $mit);
    is($exit2, 0, 'ws-handshake laeuft ueber die Gegenrichtung durch');
    is(grab_line($out2, qr/^I2_VERDIKT=/),
        'I2_VERDIKT=IMMER_IM_ARCHIV n_mit=1 n_ohne=0 n_ohne_handshake=0',
        'eine echte Beobachtung -> IMMER_IM_ARCHIV bleibt erreichbar');
    is(grab_line($out2, qr/^RESIDUUM_OHNE_PLAYBACK_STATE=/),
        'RESIDUUM_OHNE_PLAYBACK_STATE=0',
        'der Restzaehler wird auch bei null ausgegeben (Regel 2)');

    # (3) GEGENRICHTUNG: ein Gegenbeispiel schlaegt weiter auf NICHT_IMMER
    # durch -- die Rangfolge der Zweige bleibt unveraendert.
    my $ohne = write_fixture($dir, 'ohne-position.jsonl',
        '{"dir":"meta","epoch":1.0,"frame":"HANDSHAKE-OK"}',
        '{"dir":"rx","epoch":1.5,"frame":"{\"type\":\"playback_state\",\"status\":\"playing\"}"}');
    my ($exit3, $out3) = run_probe('ws-handshake', $ohne);
    is($exit3, 0, 'ws-handshake laeuft ueber das Gegenbeispiel durch');
    is(grab_line($out3, qr/^I2_VERDIKT=/),
        'I2_VERDIKT=NICHT_IMMER n_mit=0 n_ohne=1 n_ohne_handshake=0',
        'ein Gegenbeispiel schlaegt weiter auf NICHT_IMMER durch');

    # (4) ECHTES ARCHIVMATERIAL: die zwoelf Mitschnitte muessen exakt das in
    # 83-INSTRUMENTE.md protokollierte Ergebnis behalten. Der CR-01-Fix darf
    # den Wertebereich des bestehenden <automated>-Tors aus
    # 83-05-PLAN.md:199 (IMMER_IM_ARCHIV|NICHT_IMMER|UNENTSCHEIDBAR) nicht
    # verlassen und das protokollierte Verdikt nicht verschieben.
    SKIP: {
        skip 'keine echten Mitschnitt-Fixtures im Checkout', 3 unless @real_fixtures >= 12;
        my ($rexit, $rout) = run_probe('ws-handshake', @real_fixtures);
        is($rexit, 0, 'ws-handshake laeuft ueber echtes Archivmaterial durch');
        is(grab_line($rout, qr/^I2_VERDIKT=/),
            'I2_VERDIKT=UNENTSCHEIDBAR n_mit=12 n_ohne=0 n_ohne_handshake=7',
            'echtes Archiv: protokolliertes Verdikt unveraendert');
        is(grab_line($rout, qr/^RESIDUUM_OHNE_PLAYBACK_STATE=/),
            'RESIDUUM_OHNE_PLAYBACK_STATE=0',
            'echtes Archiv: keine Datei ohne playback_state');
    }
};

# ============================================================
# WR-04 -- ein schlechter Frame darf nicht jeden Zaehler jeder Datei verlieren
# ============================================================
subtest 'WR-04: ws-cadence ueberlebt ein skalares position-Feld' => sub {
    my $dir = tempdir(CLEANUP => 1);

    # Ungepatcht: Can't use string ("12345") as a HASH ref, exit 255, keine
    # einzige SUMMARY- oder RESIDUUM-Zeile.
    my $bad  = write_fixture($dir, 'skalares-position.jsonl',
        '{"type":"position_sync","position":12345}');
    my $good = write_fixture($dir, 'gutes-position.jsonl',
        '{"type":"position_sync","position":{"position_ms":1000,"speed":1}}');

    my ($exit, $out, $err) = run_probe('ws-cadence', $bad);
    is($exit, 0, 'ein skalares position-Feld reisst den Lauf nicht ab');
    unlike($err, qr/as a HASH ref/, 'kein Dereferenzierungs-Abbruch mehr');
    is(grab_line($out, qr/^\Q$bad\E:1 /),
        "$bad:1 type=position_sync epoch=NA delta_prev_ms=NA prev_frame_type=NONE pos_ms=NA speed=NA",
        'das unbrauchbare Feld wird als NA ausgewiesen, nicht erfunden');
    is(grab_line($out, qr/^SUMMARY \Q$bad\E /),
        "SUMMARY $bad n=1 min_ms=NA median_ms=NA max_ms=NA n_ueber_20000=0 residuum=0",
        'die Datei bekommt ihre SUMMARY-Zeile');
    is(grab_line($out, qr/^RESIDUUM_POSITIONSFORM=/), 'RESIDUUM_POSITIONSFORM=1',
        'die unbrauchbare position-Form steht in einem Restzaehler (Regel 2)');
    is(grab_line($out, qr/^RESIDUUM_GESAMT=/), 'RESIDUUM_GESAMT=0',
        'RESIDUUM_GESAMT wird ueberhaupt erreicht');

    # Der Kern des Befundes: ein schlechter Frame in der ERSTEN Datei darf
    # die ZWEITE nicht mitreissen.
    my ($exit2, $out2) = run_probe('ws-cadence', $bad, $good);
    is($exit2, 0, 'zwei Dateien, erste mit schlechtem Frame -- der Lauf haelt');
    is(grab_line($out2, qr/^SUMMARY \Q$good\E /),
        "SUMMARY $good n=1 min_ms=NA median_ms=NA max_ms=NA n_ueber_20000=0 residuum=0",
        'die zweite Datei wurde gelesen und bilanziert');
    is(grab_line($out2, qr/^RESIDUUM_POSITIONSFORM=/), 'RESIDUUM_POSITIONSFORM=1',
        'genau ein unbrauchbares Feld ueber beide Dateien gezaehlt');

    # ECHTES ARCHIVMATERIAL: die zwoelf Mitschnitte behalten ihr
    # protokolliertes Ergebnis (175 Datensaetze, 12 SUMMARY-Zeilen,
    # RESIDUUM_GESAMT=0) und melden keine unbrauchbare position-Form.
    SKIP: {
        skip 'keine echten Mitschnitt-Fixtures im Checkout', 5 unless @real_fixtures >= 12;
        my ($rexit, $rout) = run_probe('ws-cadence', @real_fixtures);
        is($rexit, 0, 'ws-cadence laeuft ueber echtes Archivmaterial durch');
        my $n_rec = () = $rout =~ /^[^: ]+:\d+ type=position_sync /mg;
        is($n_rec, 175, 'echtes Archiv: 175 Datensaetze wie protokolliert');
        my $n_sum = () = $rout =~ /^SUMMARY /mg;
        is($n_sum, 12, 'echtes Archiv: zwoelf SUMMARY-Zeilen');
        is(grab_line($rout, qr/^RESIDUUM_GESAMT=/), 'RESIDUUM_GESAMT=0',
            'echtes Archiv: protokolliertes RESIDUUM_GESAMT unveraendert');
        is(grab_line($rout, qr/^RESIDUUM_POSITIONSFORM=/), 'RESIDUUM_POSITIONSFORM=0',
            'echtes Archiv: keine unbrauchbare position-Form');
    }
};

# ============================================================
# WR-05 -- Zusatzargumente duerfen nicht wortlos wegfallen
# ============================================================
subtest 'WR-05: Ein-Datei-Unterbefehle verschlucken kein zweites Argument' => sub {
    my $dir = tempdir(CLEANUP => 1);

    # one.log traegt keinen Block, two.log genau einen. Ungepatcht meldet
    # `blocks one.log two.log` BLOECKE_GESAMT=0 -- ein Urteil ueber die erste
    # Datei, waehrend die zweite nie gelesen wurde.
    my $one = write_fixture($dir, 'one.log',
        '2026-09-06 18:00:00.000: playing spotify:track:AAAAAAAAAAAAAAAAAAAAAA "T" by "A" [0:05 / 3:00]');
    my $two = write_fixture($dir, 'two.log',
        '2026-09-06 18:10:00.000: playing spotify:track:BBBBBBBBBBBBBBBBBBBBBB "T" by "A" [1:00 / 3:00]',
        '2026-09-06 18:10:10.000: playing spotify:track:BBBBBBBBBBBBBBBBBBBBBB "T" by "A" [1:00 / 3:00]',
        '2026-09-06 18:10:20.000: playing spotify:track:BBBBBBBBBBBBBBBBBBBBBB "T" by "A" [1:00 / 3:00]');

    for my $cmd (qw(ticker blocks transitions stillstand)) {
        # MUSS-GREIFEN: zwei Argumente -> harter, sichtbarer Abbruch.
        my ($exit, undef, $err) = run_probe($cmd, $one, $two);
        isnt($exit, 0, "$cmd: zwei Dateien brechen sichtbar ab");
        is(grab_line($err, qr/^FATAL: /),
            "FATAL: $cmd braucht genau eine Log-Datei (bekommen: 2)",
            "$cmd: die Meldung nennt die tatsaechliche Argumentzahl");

        # MUSS-BESTEHEN (Gegenrichtung): ein Argument laeuft unveraendert.
        my ($exit1) = run_probe($cmd, $two);
        is($exit1, 0, "$cmd: ein Argument laeuft unveraendert durch");

        # MUSS-GREIFEN: null Argumente brechen weiter ab, jetzt beziffert.
        my ($exit0, undef, $err0) = run_probe($cmd);
        isnt($exit0, 0, "$cmd: null Argumente brechen weiter ab");
        is(grab_line($err0, qr/^FATAL: /),
            "FATAL: $cmd braucht genau eine Log-Datei (bekommen: 0)",
            "$cmd: null Argumente werden ebenso beziffert");
    }

    # Der konkrete Fehlbefund aus dem Review: die zweite Datei traegt einen
    # Block, der im Zwei-Argument-Aufruf heute stumm verlorenging.
    my (undef, $solo) = run_probe('blocks', $two);
    is(grab_line($solo, qr/^BLOECKE_GESAMT=/), 'BLOECKE_GESAMT=1',
        'die allein gefahrene zweite Datei traegt tatsaechlich einen Block');
};

# ============================================================
# WR-06 -- undatierte und tagversetzte Referenzereignisse werden GEZAEHLT
# (Nutzerentscheidung: zaehlen, nicht reparieren)
# ============================================================
subtest 'WR-06: Referenzereignisse ohne brauchbares Datum werden gezaehlt' => sub {
    my $dir = tempdir(CLEANUP => 1);

    # (1) Zwei Referenzzeilen VOR der ersten datierten Ticker-Zeile. Heute
    # verschwinden sie spurlos: die Datei traegt drei Referenzzeilen,
    # REFERENZ_EREIGNISSE meldet 1, kein Zaehler nennt die anderen zwei.
    my $undatiert = write_fixture($dir, 'undatiert.log',
        '[fakepulse] 17:59:50.100 pa_stream_flush(stream=0x1) called',
        '[fakepulse] 17:59:55.200 boundary_planted: at frame 4410',
        '2026-09-06 18:00:00.000: playing spotify:track:AAAAAAAAAAAAAAAAAAAAAA "T" by "A" [0:00 / 3:00]',
        '[fakepulse] 18:00:02.000 boundary_planted: at frame 8820',
        '2026-09-06 18:00:10.000: playing spotify:track:BBBBBBBBBBBBBBBBBBBBBB "T2" by "A" [0:00 / 3:00]');
    my ($exit, $out) = run_probe('transitions', $undatiert);
    is($exit, 0, 'transitions laeuft ueber undatierte Referenzzeilen durch');
    is(grab_line($out, qr/^RESIDUUM_REFERENZ_UNDATIERT=/),
        'RESIDUUM_REFERENZ_UNDATIERT=2',
        'die zwei undatierten Referenzzeilen stehen in einem Restzaehler');
    is(grab_line($out, qr/^RESIDUUM_REFERENZ_TAGWECHSEL=/),
        'RESIDUUM_REFERENZ_TAGWECHSEL=0',
        'kein Tagwechsel in dieser Datei -- Zaehler trotzdem ausgegeben');
    is(grab_line($out, qr/^REFERENZ_EREIGNISSE=/), 'REFERENZ_EREIGNISSE=1',
        'die verwertbaren Ereignisse bleiben unveraendert gezaehlt');

    # (2) Mitternachtswechsel: die Referenzzeile um 00:00:05 erbt den Vortag
    # und liegt damit 24 h daneben. NUTZERENTSCHEIDUNG: nur zaehlen. Die
    # Epoche wird NICHT weitergedreht -- die Grenze bleibt folglich
    # `grenze_unbestaetigt`, und genau das macht der Zaehler sichtbar,
    # statt einen plausibel-falschen Anker zu liefern.
    my $mitternacht = write_fixture($dir, 'mitternacht.log',
        '2026-09-06 23:59:50.000: playing spotify:track:AAAAAAAAAAAAAAAAAAAAAA "T" by "A" [2:50 / 3:00]',
        '[fakepulse] 00:00:05.000 boundary_planted: at frame 4410',
        '2026-09-07 00:00:10.000: playing spotify:track:BBBBBBBBBBBBBBBBBBBBBB "T2" by "A" [0:00 / 3:00]');
    my ($exit2, $out2) = run_probe('transitions', $mitternacht);
    is($exit2, 0, 'transitions laeuft ueber den Tagwechsel durch');
    is(grab_line($out2, qr/^RESIDUUM_REFERENZ_TAGWECHSEL=/),
        'RESIDUUM_REFERENZ_TAGWECHSEL=1',
        'das tagversetzte Referenzereignis steht in einem Restzaehler');
    is(grab_line($out2, qr/^RESIDUUM_REFERENZ_UNDATIERT=/),
        'RESIDUUM_REFERENZ_UNDATIERT=0',
        'keine undatierte Zeile in dieser Datei -- Zaehler trotzdem ausgegeben');
    like(grab_line($out2, qr/ anker=uri_wechsel /),
        qr/ klasse=grenze_unbestaetigt /,
        'die +24-h-Heuristik wurde NICHT eingebaut: die Klasse bleibt unveraendert');

    # (2b) GESCHWISTER UEBER DIE DATEIGRENZE: `stillstand` zieht seine
    # Grenzliste aus DERSELBEN Referenzmenge. Waeren die Zaehler nur in
    # `transitions` ausgegeben, ueberlebte derselbe Befund die Korrektur
    # eine Dateigrenze weiter.
    my ($exit3, $out3) = run_probe('stillstand', $mitternacht);
    is($exit3, 0, 'stillstand laeuft ueber den Tagwechsel durch');
    is(grab_line($out3, qr/^RESIDUUM_REFERENZ_TAGWECHSEL=/),
        'RESIDUUM_REFERENZ_TAGWECHSEL=1',
        'stillstand meldet denselben Restzaehler wie transitions');

    # (3) REFERENZ_DATUMSHERKUNFT darf nichts behaupten, was fuer die
    # vorliegende Datei nicht gemessen wurde.
    my $herkunft = grab_line($out, qr/^REFERENZ_DATUMSHERKUNFT=/);
    like($herkunft, qr/^REFERENZ_DATUMSHERKUNFT=.+$/,
        'REFERENZ_DATUMSHERKUNFT bleibt vorhanden (bestehendes Tor)');
    unlike($herkunft, qr/im Schnappschuss liegt keine Referenzzeile/,
        'keine fest verdrahtete Behauptung ueber einen fremden Schnappschuss');

    # (4) ECHTES ARCHIVMATERIAL: der Daemon-Log-Schnappschuss der Phase 83
    # spannt 2026-09-06..2026-09-20 und traegt vier tagversetzte
    # Referenzereignisse -- der Fall ist im Archiv belegt, nicht nur gebaut.
    # Die protokollierte Ereigniszahl bleibt unveraendert, weil nur gezaehlt
    # und nichts umdatiert wird.
    SKIP: {
        skip 'echter Daemon-Log-Schnappschuss nicht vorhanden', 4 unless -f $real_daemon_log;
        my ($rexit, $rout) = run_probe('transitions', $real_daemon_log);
        is($rexit, 0, 'transitions laeuft ueber den echten Schnappschuss durch');
        is(grab_line($rout, qr/^RESIDUUM_REFERENZ_TAGWECHSEL=/),
            'RESIDUUM_REFERENZ_TAGWECHSEL=4',
            'echtes Archiv: vier tagversetzte Referenzereignisse');
        is(grab_line($rout, qr/^RESIDUUM_REFERENZ_UNDATIERT=/),
            'RESIDUUM_REFERENZ_UNDATIERT=0',
            'echtes Archiv: keine Referenzzeile vor der ersten datierten Zeile');
        is(grab_line($rout, qr/^REFERENZ_EREIGNISSE=/), 'REFERENZ_EREIGNISSE=423',
            'echtes Archiv: die protokollierte Ereigniszahl bleibt unveraendert');
    }
};


# ============================================================
# SW-01 -- 'echter_stillstand' aus einem LEEREN Vorwaertsfenster wird GEZAEHLT
# (Nutzerentscheidung: additiver Zaehler, Klassifikation unveraendert)
#
# Geschwisterbefund aus der Pflicht-Geschwistersuche zu CR-01: `classify_forward`
# hat dieselbe Bauform. Die Schleife `for my $j ($start_idx + 1 .. $last_idx)`
# laeuft NULLMAL, wenn der Ausloeser die letzte Ticker-Zeile der Datei ist. Der
# Durchfall liefert dann `echter_stillstand` -- die STAERKSTE Behauptung aus
# null Vorwaertsbeobachtungen.
#
# Nutzerentscheidung: ADDITIVER ZAEHLER. Die Klassifikation bleibt Byte fuer
# Byte, wie sie ist; `EMPFOHLENES_KRITERIUM=paused` bleibt stehen; kein
# protokollierter Wert verschiebt sich und kein Dokument muss korrigiert
# werden. Die naechste Messreihe sieht im Lauf, worauf die Empfehlung ruht.
# NICHT gewaehlt wurde die Korrektur (leeres Fenster -> `unentscheidbar`); sie
# haette `EMPFOHLENES_KRITERIUM` auf `KEINES` gekippt.
#
# Dieser Test haelt beide Richtungen fest: der Zaehler MUSS erscheinen und
# unterscheiden, und die Klassifikation MUSS unveraendert bleiben.
# ============================================================
subtest 'SW-01: stillstand zaehlt Urteile aus leerem Vorwaertsfenster' => sub {
    my $dir = tempdir(CLEANUP => 1);

    # (1) MUSS-GREIFEN: die LETZTE Ticker-Zeile ist `paused`. Der einzige
    # Kandidat steht damit am Dateiende, das Vorwaertsfenster ist leer, und
    # `echter_stillstand` faellt aus null Beobachtungen durch.
    my $leer = write_fixture($dir, 'leeres-fenster.log',
        '2026-09-06 18:00:00.000: playing spotify:track:AAAAAAAAAAAAAAAAAAAAAA "T" by "A" [0:05 / 3:00]',
        '2026-09-06 18:00:10.000: playing spotify:track:AAAAAAAAAAAAAAAAAAAAAA "T" by "A" [0:15 / 3:00]',
        '2026-09-06 18:00:20.000: paused spotify:track:AAAAAAAAAAAAAAAAAAAAAA "T" by "A" [0:25 / 3:00]');
    my ($exit, $out) = run_probe('stillstand', $leer);
    is($exit, 0, 'stillstand laeuft ueber das leere Vorwaertsfenster durch');
    is(grab_line($out, qr/^RESIDUUM_STILLSTAND_LEERES_FENSTER=/),
        'RESIDUUM_STILLSTAND_LEERES_FENSTER=1',
        'das Urteil aus null Vorwaertsbeobachtungen steht in einem Restzaehler');

    # UNVERAENDERT: Klassifikation und Empfehlung bleiben, wie sie waren.
    is(grab_line($out, qr/^\Q$leer\E:3 /),
        "$leer:3 kriterium=paused klasse=echter_stillstand ts=2026-09-06T18:00:20.000",
        'die Klasse bleibt echter_stillstand -- der Zaehler ist additiv');
    is(grab_line($out, qr/^KRITERIUM=paused /),
        'KRITERIUM=paused treffer=1 normaler_durchlauf=0 echter_stillstand=1 unentscheidbar=0',
        'die Bilanzzeile verschiebt sich nicht');
    is(grab_line($out, qr/^EMPFOHLENES_KRITERIUM=/), 'EMPFOHLENES_KRITERIUM=paused',
        'die Empfehlung bleibt stehen (nicht gewaehlt: Kippen auf KEINES)');

    # (2) GEGENRICHTUNG: derselbe Befund `echter_stillstand`, aber aus einer
    # ECHTEN Vorwaertsbeobachtung -- der Kandidat steht nicht am Dateiende.
    # Der Zaehler MUSS hier 0 melden und MUSS trotzdem erscheinen (Regel 2).
    # Waere er eine blosse Kopie von echter_stillstand, stuende hier 1.
    my $voll = write_fixture($dir, 'volles-fenster.log',
        '2026-09-06 18:00:00.000: playing spotify:track:AAAAAAAAAAAAAAAAAAAAAA "T" by "A" [0:05 / 3:00]',
        '2026-09-06 18:00:10.000: paused spotify:track:AAAAAAAAAAAAAAAAAAAAAA "T" by "A" [0:15 / 3:00]',
        '2026-09-06 18:00:20.000: playing spotify:track:AAAAAAAAAAAAAAAAAAAAAA "T" by "A" [0:25 / 3:00]');
    my ($exit2, $out2) = run_probe('stillstand', $voll);
    is($exit2, 0, 'stillstand laeuft ueber das volle Vorwaertsfenster durch');
    is(grab_line($out2, qr/^RESIDUUM_STILLSTAND_LEERES_FENSTER=/),
        'RESIDUUM_STILLSTAND_LEERES_FENSTER=0',
        'echte Vorwaertsbeobachtung -> 0, und der Zaehler erscheint auch bei null');

    # Der Kern der Unterscheidung: BEIDE Dateien liefern dieselbe Bilanzzeile
    # (treffer=1 echter_stillstand=1). Vor dem Zaehler war das Urteil aus null
    # Beobachtungen von dem aus einer echten Beobachtung in der Ausgabe nicht
    # zu unterscheiden -- genau diese Ununterscheidbarkeit war der Befund.
    is(grab_line($out2, qr/^KRITERIUM=paused /),
        grab_line($out, qr/^KRITERIUM=paused /),
        'beide Faelle tragen dieselbe Bilanzzeile -- nur der Zaehler trennt sie');

    # (3) ECHTES ARCHIVMATERIAL: der Daemon-Log-Schnappschuss der Phase 83.
    # Dort steht GENAU EIN echter_stillstand (Zeile 351594), und das ist
    # zugleich die letzte Ticker-Zeile der Datei -- die protokollierte
    # I-5-Empfehlung ruht auf diesem einen Urteil aus null Beobachtungen.
    # Der Zaehler muss dort 1 melden: nicht 0 (dann traefe er den Fall nicht)
    # und nicht 77 (dann zaehlte er alle paused-Kandidaten).
    SKIP: {
        skip 'echter Daemon-Log-Schnappschuss nicht vorhanden', 7 unless -f $real_daemon_log;
        my ($rexit, $rout) = run_probe('stillstand', $real_daemon_log);
        is($rexit, 0, 'stillstand laeuft ueber den echten Schnappschuss durch');
        is(grab_line($rout, qr/^RESIDUUM_STILLSTAND_LEERES_FENSTER=/),
            'RESIDUUM_STILLSTAND_LEERES_FENSTER=1',
            'echtes Archiv: genau ein Urteil aus leerem Fenster');
        is(grab_line($rout, qr/ klasse=echter_stillstand /),
            "$real_daemon_log:351594 kriterium=paused klasse=echter_stillstand ts=2026-09-17T09:01:25.719",
            'echtes Archiv: es ist die letzte Ticker-Zeile, die das Urteil traegt');

        # Kein protokollierter Wert verschiebt sich -- das war die Bedingung
        # der Nutzerentscheidung. Alle vier kategorischen Zeilen bytegleich
        # zum Lauf vor der Aenderung.
        is(grab_line($rout, qr/^KRITERIUM=paused /),
            'KRITERIUM=paused treffer=77 normaler_durchlauf=26 echter_stillstand=1 unentscheidbar=50',
            'echtes Archiv: die protokollierte paused-Bilanz bleibt unveraendert');
        is(grab_line($rout, qr/^KRITERIUM=endstellung /),
            'KRITERIUM=endstellung treffer=4954 normaler_durchlauf=230 echter_stillstand=0 unentscheidbar=4724',
            'echtes Archiv: die protokollierte endstellung-Bilanz bleibt unveraendert');
        like(grab_line($rout, qr/^HEUTIGES_KRITERIUM /),
            qr/^HEUTIGES_KRITERIUM falschtreffer=101 blocks_geprueft=167 /,
            'echtes Archiv: die Gegenrechnung ueber alle Bloecke bleibt unveraendert');
        is(grab_line($rout, qr/^EMPFOHLENES_KRITERIUM=/), 'EMPFOHLENES_KRITERIUM=paused',
            'echtes Archiv: die protokollierte I-5-Empfehlung bleibt stehen');
    }
};

done_testing();

#!/usr/bin/perl
#
# tools/uat/extract-run.pl
#
# Log-Forensik fuer Messlaeufe: sammelt die drei Belegquellen eines Laufs
# (server.log, <mac>-soloist.log, Recorder-Mitschnitt) fuer ein Zeitfenster
# und gibt einen fertigen Belegblock aus -- in der Form, die
# 82-G3-MESSUNG.md/82-G4-MESSUNG.md unter "## Laeufe" bisher von Hand
# zusammentragen mussten (.planning/todos/pending/log-forensik-skript-fuer-messlaeufe.md).
#
# WICHTIG -- Laufnamen wie "L1" sind zwischen Messreihen mehrdeutig
# (z.B. G3-L1 und G4-L1 sind VERSCHIEDENE Laeufe an verschiedenen Tagen).
# Immer MAC+T0+T1 exakt aus der jeweiligen Quelltabelle uebernehmen, nie
# nur den Kurznamen.
#
# ---------------------------------------------------------------------------
# DIE VIER REGELN (Nutzervorgabe, nicht verhandelbar)
#   1. Kein Verdikt. Nur Rohzeilen und ausdruecklich als "[ABGELEITET ...]"
#      markierte Zeitstempel-Differenzen. Keine wertende Sprache.
#   2. Kein Schweigen bei fehlender Quelle. Alles Fehlende, Verworfene,
#      Unerkannte erzeugt eine LAUTE Zeile bzw. einen Restzaehler.
#   3. Keine Mehrdeutigkeit. Jede Zeile traegt Quelle und Zeitbasis;
#      Mehrtages-, Fremd-MAC- und MAC-lose Kategorien sind markiert. Wo eine
#      Aussage nicht entscheidbar ist, wird sie NICHT getroffen.
#   4. Abwesenheit ist nicht Widerlegung. "nicht gefunden im Fenster",
#      niemals "nicht vorhanden".
#
# ---------------------------------------------------------------------------
# ARCHITEKTUR -- der Grund fuer die Perl-Neufassung (REVIEW-02, Teil C).
# Die Bash-Fassung (1480 Zeilen, geloescht mit dieser Neufassung) hatte sieben
# Zeitstempel-Parser und drei Kopien der Anker/Partner-Auswahl mit einem von
# Hand gelesenen Fuenf-Feld-Positionsprotokoll. Beide Kritischen und die
# Regression des zweiten Reviews waren direkte Folgen davon.
#
#   1. GENAU EIN Zeitstempel-Parser. parse_hms() ist die einzige Stelle, die
#      eine Zeitzeichenkette in Sekunden umrechnet; parse_line() ist die
#      einzige Stelle, die einen Zeitstempel AUS einer Logzeile liest. Beide
#      erzeugen je Zeile genau einen Datensatz:
#        { source, raw, ts, epoch, day, day_derived, stamp,
#          mac_class, macs, cats, category }
#   2. PARSEN, DANN RENDERN -- niemals rendern und erneut parsen. Die
#      Annotationen [TAG ...], [ANDERE MAC: ...] und [ZUSAMMENGEFASST]
#      entstehen ausschliesslich beim Ausgeben (render_record / die
#      Ausgabeschleifen), aus Feldern des Datensatzes. Kein Code liest je
#      eine gerenderte Zeile zurueck. Das beseitigt N-CR-01 als Klasse.
#   3. GENAU EINE Auswahl-/Paarungsroutine. select_record() arbeitet ueber
#      Datensaetze und liefert BENANNTE Felder (kein Positionsprotokoll) --
#      das beseitigt N-WR-01 als Klasse und macht die Rand-Behandlung des
#      eingerahmten Ankers (N-CR-02, Status "bracketed") an EINER Stelle
#      loesbar.
#   4. RESTZAEHLER. Jede verworfene, unerkannte oder nicht kategorisierte
#      Zeile wird gezaehlt und im Abschnitt "Restzaehler" gemeldet -- ein
#      Zaehler, der nie Null sein darf, ohne dass es dasteht (Regel 2).
#
# N-CR-02 im Klartext: liegt je ein Partner VOR und NACH dem Anker innerhalb
# der Paarungsspanne, ist die Reihenfolge NICHT entscheidbar. Dann werden
# BEIDE Kandidaten mit Zeitstempel genannt und KEIN Delta und KEINE
# VOR/NACH-Aussage ausgegeben. Lieber kein Delta als eines, dessen Vorzeichen
# an 2 ms eines unbeteiligten Ereignisses haengt. Die Zwei-Modi-Einsicht
# bleibt erhalten: fuer die Arm/Flush-Frage wird der Partner in BEIDE
# Richtungen gesucht (Modus "near"), sonst waere "Arm liegt NACH dem Flush"
# strukturell unauffindbar.
#
# ---------------------------------------------------------------------------
# Usage:
#   tools/uat/extract-run.pl <mac> <T0> <T1> [--out FILE] [--recorder FILE]
#     [--recorder-seconds N] [--server-log FILE] [--daemon-log FILE]
#     [--full] [--date YYYY-MM-DD] [--daemon-end-epoch E]
#
#   <mac>   Spieler-MAC, z.B. 02:00:00:5a:11:03
#   <T0>    Fensteranfang-Anker, HH:MM:SS[.mmm] (lokale Zeit)
#   <T1>    Fensterende-Anker, HH:MM:SS[.mmm] (lokale Zeit)
#
# Flags (Reihenfolge relativ zu den drei Positionalargumenten beliebig):
#   --out FILE             Ausgabe zusaetzlich in FILE schreiben (redigiert)
#   --recorder FILE        Recorder-JSONL-Mitschnitt (roh dir/frame- ODER
#                           flaches type-Schema, wird pro Zeile erkannt)
#   --recorder-seconds N   erwartete Recorder-Laufzeit ab T0
#   --server-log FILE      Default: /var/log/squeezeboxserver/server.log
#   --daemon-log FILE      Default: aus <mac> abgeleitet
#   --full                 keine Rauschunterdrueckung
#   --date YYYY-MM-DD      schraenkt bei Mehrtages-Mehrdeutigkeit ein; fuer
#                          das Daemon-Log aktueller Soloist-Builds (datumslose
#                          UTC-Tickerzeilen) ERFORDERLICH -- ohne --date bleibt
#                          der Daemon-Kanal dunkel (WR-10, round 3)
#   --daemon-end-epoch E   Ende-Anker der Tagesrekonstruktion des Daemon-Logs
#                          (84-22 splice fix, siehe daemon_day_plan): Epoche,
#                          zu der die letzte Zeile der Datei geschrieben war.
#                          Default: mtime der Datei (Kopien OHNE erhaltene
#                          mtime brauchen diese Option)
#   --help / -h            diese Hilfe, Exit 0
#
# Env-Var-Override (Testhaken):
#   SUDO_BIN   Default "sudo" -- Binary fuer den Daemon-Log-Zugriff
#   STAT_BIN   Default "stat" -- nur fuer die mtime-Zeile des Recorders
#
# Voraussetzung: sudo -n true muss ohne Passwortabfrage funktionieren
# (Daemon-Log ist ohne sudo nicht lesbar). server.log ist ohne sudo lesbar.
#
# Reines Perl mit Kernmodulen (strict, warnings, JSON::PP). Externe
# Kommandos: nur `sudo -n cat` fuer das Daemon-Log und `stat -c %y` fuer die
# mtime-Zeile (Nanosekunden sind aus einem Perl-Double nicht rekonstruierbar).
#
# Modulino-Konvention (wie tools/soloist-ws-record.pl): main(@ARGV) laeuft
# nur beim direkten Aufruf, nicht per require.

use strict;
use warnings;

use JSON::PP ();
use POSIX ();
use Time::Local qw(timegm);

our $VERSION = '2.1';

# ---------------------------------------------------------------------------
# Konstanten
# ---------------------------------------------------------------------------
my $SERVER_LOG_DEFAULT = '/var/log/squeezeboxserver/server.log';
my $PAIR_SPAN    = 3;      # s -- "gehoert zum selben Vorgang"
my $TB_TOL       = 2;      # s -- Zeitbasis-Selbsttest: Paar gilt als nah
my $TB_STEP      = 1800;   # s -- kleinster echter Zeitzonenversatz (30 min)
my $EPS          = 1e-9;
# 84-22 splice fix: Tagesrekonstruktion des datumslosen Daemon-Logs (siehe daemon_day_plan)
my $DAY_TOL      = 1.0;    # s -- groesster tolerierter Rueckschritt der UTC-Tickeruhr (gemessen < 0.01 s); mehr = naechster Tag
my $END_SLACK    = 120;    # s -- die letzte Tickerzeile liegt hoechstens so weit NACH dem Ende-Anker (mtime / --daemon-end-epoch)

my $MAC_RE = qr/[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5}/;

my $REDACT_RE = qr/spak_[A-Za-z0-9_-]*|auth_data[^ ]*|Bearer [A-Za-z0-9._-]+/;

# Kategorien. count=1 bedeutet: Kopfzeile traegt die Anzahl im Fenster und
# die engere Zaehlung T1 +/- PAIR_SPAN (Handtabellen zaehlen auf dieser
# engeren Basis).
my @SRV_CATS = (
    { name => 'server.log: jumpToTime',
      pat  => qr/jumpToTime/,                                                        count => 0 },
    { name => 'server.log: noteSeekIntent',
      pat  => qr/noteSeekIntent\(/,                                                  count => 1 },
    { name => 'server.log: Song::open (seek=/time=/canSeek=)',
      pat  => qr/Song::open.*seek=(?:true|false) time=[0-9]+ canSeek=[0-9]/,         count => 0 },
    { name => 'server.log: formatOverride (result=)',
      pat  => qr/formatOverride:.*result=/,                                          count => 0 },
    { name => 'server.log: canDirectStream (result=/reason=)',
      pat  => qr/canDirectStream:.*result=.*reason=/,                                count => 0 },
    { name => 'server.log: Request: GET /stream',
      pat  => qr/Request: GET \/stream/,                                             count => 0 },
    { name => 'server.log: onStream (pos=/seek=)',
      pat  => qr/onStream:.*pos=[0-9]+ seek=[0-9]/,                                  count => 0 },
    { name => 'server.log: Control: dispatch (armed=)',
      pat  => qr/Control: dispatch [a-z_]+ armed=[0-9]/,                             count => 1 },
    # 84.1 plan 05 (D-12 seek-to-restricted): SoloistWS's own daemon-error
    # relay (SoloistWS.pm _onMessage, "daemon reported error (<mac>, last
    # command '<cmd>'): <text>") was previously uncategorized -- the
    # seek_to_restricted todo's own evidence (two verbatim lines,
    # 2026-09-06 18:05:26) had no category and would have needed hand-grep
    # for the live series' restricted_verdict formula (forbidden).
    { name => 'server.log: SoloistWS daemon-reported error (seek_to_restricted etc.)',
      pat  => qr/SoloistWS: daemon reported error/,                                   count => 1 },
    # 84.1 plan 01 (D-07/D-08): cluster-1 live proof needs the three mode-
    # transition decision points named in Control.pm's _onFrameDeviceChanged
    # (own activation echo / transfer-in / own take-over / no longer active
    # device in browse / lost the Spotify session) plus leaveBrowse/
    # leaveConnect's own DEBUG lines (e.g. Connect.pm CR-04 "new LMS song is
    # not ours -- leaveBrowse") in one category -- without it, scenario (a)'s
    # dry-run gate would have to hand-grep server.log directly (forbidden).
    # 84.1-08 (WR-07, D-02): the leaveConnect alternative is anchored on the
    # real transition text (Control.pm:4833, "in connect -- leaveConnect (")
    # instead of the bare word -- a bare `leaveConnect` also matched the
    # D-02 stay lines, the re-adoption hold line and the IN-04 no-WS-
    # connection notice, none of which is an actual transition; gate b and
    # gate_a_formula read this exact category for B_LEAVECONNECT_SEEN.
    { name => 'server.log: Control mode transitions (own activation echo / transfer-in / take-over / no longer active / leaveBrowse / leaveConnect)',
      pat  => qr/own activation echo -- staying browse|transfer-in -> mode=connect|own take-over confirmed|no longer active device in browse|lost the Spotify session to another device|leaveBrowse|in connect -- leaveConnect \(/, count => 1 },
    # 84.1-08 (WR-07): the D-02 lines that stay IN connect (no leaveConnect)
    # get their own category, so they remain visible without being counted
    # as a transition by the category above.
    { name => 'server.log: D-02 stays in connect (no url / connect-entry song re-announced)',
      pat  => qr/D-02: newsong .* -- staying, no leaveConnect/,                       count => 1 },
    # 84.1-08 (WR-07): the re-adoption hold (T-84.1-29) and the IN-04 no-WS-
    # connection notice both mention "leaveConnect" in their own text
    # without being a transition -- their own category, same reason.
    { name => 'server.log: after leaveConnect (re-adoption hold / deactivate not sent)',
      pat  => qr/after leaveConnect while LMS plays foreign content -- not re-adopting|leaveConnect without a WS connection -- deactivate not sent/, count => 1 },
    # Connect claim bind/release (Connect.pm bindConnectClaim/releaseConnectClaim)
    # -- scenario (b)'s discriminator: a released claim during foreign LMS
    # playback would mean the connect-session's claim did NOT stay bound.
    { name => 'server.log: Connect claim (bound / released)',
      pat  => qr/Connect claim: (?:bound|released)/,                                 count => 1 },
    # StreamingController's own no-op stop path (Stop in <STATE> -> _NoOp,
    # e.g. "Stop in STOPPED-IDLE -> ..._NoOp") -- distinct from the existing
    # "Stop in <STATE> -> ::_Stop" category above, which does NOT match
    # _NoOp. Scenario (a)'s discriminator for the todo's premise fact (2):
    # a bare `stop` on an already-stopped player never reaches leaveBrowse.
    { name => 'server.log: StreamingController no-op stop (Stop in <STATE> -> _NoOp)',
      pat  => qr/Stop in [A-Z-]+ -> .*::_NoOp/,                                       count => 1 },
    # 84.1-08 (CR-01, D-01(b)): _onLmsStop's own INFO line -- live proof
    # that a bare `stop` / `playlist clear` notification reaches SpotOn's
    # handler in the running LMS (Connect.pm _onLmsStop/_onLmsClear).
    { name => 'server.log: D-01(b) LMS stop / playlist clear notification (_onLmsStop)',
      pat  => qr/D-01\(b\): LMS (?:stop|playlist clear) notification -- mode=/, count => 1 },
    { name => 'server.log: Control: loopback POST /seek-arm sent',
      pat  => qr/Control: loopback POST \/seek-arm sent/,                            count => 0 },
    { name => 'server.log: SpotOn G3/G4-INSTR',
      pat  => qr/SpotOn G[34]-INSTR:/,                                               count => 0 },
    { name => 'server.log: Stop in <STATE> -> ::_Stop',
      pat  => qr/Stop in [A-Z-]+ -> .*::_Stop/,                                      count => 0 },
    { name => 'server.log: playerTrackStarted / playerStopped / new state',
      pat  => qr/playerTrackStarted|playerStopped| - new state /,                    count => 0 },
    # Debug-Report .planning/debug/get-state-statt-play.md Zeilen 205-304:
    # der bislang unsichtbare LMS-eigene StreamingController-Fehlschlagkanal.
    # Beide Eintraege additiv zur obigen Kategorie -- sie bleibt unveraendert
    # (Baseline-Erhalt). Eintrag 1 ist die Ausloeserzeile (vorher komplett
    # unkategorisiert, nur im Sammelzaehler); Eintrag 2 hebt die bereits
    # ausgebbare Terminalzeile aus dem Sammeltopf, ohne ihn zu veraendern.
    { name => 'server.log: NextTrackError -> _NextIfMore (LMS interner Neustart-Vorlauf, T-3-Ausloeser)',
      pat  => qr/NextTrackError in [A-Z-]+ -> .*::_NextIfMore/,                       count => 1 },
    { name => 'server.log: NextTrackError - new state (LMS-Kern-Fehlschlagverdikt desselben Zyklus)',
      pat  => qr/NextTrackError - new state /,                                       count => 1 },
    # 84-04 (B3 instrument): LMS' OWN drop line when the player buffer is full while paused,
    # Slim::Player::StreamingController::_CheckPaused (437 `(resume time: ...)` / 445 `(no resume)`),
    # logger player.source at INFO -- emitted only while player.source is at DEBUG/INFO, i.e. after
    # cluster2 set_loglevels. Without a category the line fell into the uncategorised counter, so
    # cluster2-series.sh A4_STREAM_DROPPED (:1770/:1787) could never read yes (3 of 3 archived
    # readings `no`). Real lines: t/fixtures/uat/84-04-server-remote-stream-stopped.log.
    { name => 'server.log: remote stream stopped upon full buffer when paused (StreamingController:437/445)',
      pat  => qr/Stopping remote stream upon full buffer when paused/,                count => 1 },
    { name => 'server.log: end of file or error on socket',
      pat  => qr/end of file or error on socket/,                                    count => 0 },
    { name => 'server.log: notifyFromArray / Notifying',
      pat  => qr/notifyFromArray|Notifying/,                                         count => 0 },
    # W5 (82-25, CR-05): dedicated category for the three browse-proxy
    # [DIAG] markers (unified_browse_sync_proxy, soloist_browse_proxy,
    # unified_connect_sync_proxy) -- without it, the belegweg for the
    # fixed 127.0.0.1 proxy URL required hand-grepping server.log
    # (forbidden, Nutzeranweisung 10.09.). Matches nothing else: other
    # [DIAG] lines (e.g. formatOverride, canDirectStream) carry neither
    # "_proxy:" nor "http_url=".
    { name => 'server.log: [DIAG] *_proxy (http_url=)',
      pat  => qr/\[DIAG\] \w+_proxy: .*http_url=/,                                   count => 0 },
    # quick-260923-hgj: the watchdog rescue channel fell into the
    # collective "in keiner Kategorie" bucket -- neither rung had a
    # dedicated pattern, so the watchdog diagnosis (verified 2026-09-23
    # over six server.log generations: 11 Runde-1 rings, 0 Runde-2 forced
    # skips) could only be evidenced via hand-grep. Two additive
    # categories close this gap.
    # Sources: Plugin.pm:4136 (_prefetchHangCheck, Runde 1, handoff to
    # Soloist::Control) and Control.pm:687 (_watchdogRound2, Runde 2,
    # forced skip). The em dash between "past end" and "handing"/"forcing"
    # is stored DOUBLE-ENCODED in server.log (bytes c3 a2 c2 80 c2 94, not
    # a plain e2 80 94) -- the tool reads bytes with no encoding layer, so
    # the pattern bridges the dash with `.*` and stays pure ASCII; a
    # pattern containing the literal em-dash character would silently
    # match nothing.
    # _recordErrorOnce (Control.pm:3086) is a SECOND sender of the Runde-2
    # wording ("<mac>: watchdog forced skip (round 2: ...)"); the Runde-2
    # pattern is anchored on "Control: watchdog forced skip on " so it
    # catches only the :687 line -- one hit per event, not two.
    # Plugin.pm:4140 ("... forcing skip", player without a Control
    # instance) is the sibling of the Runde-1 line and is deliberately NOT
    # covered here -- it stays visible in the collective bucket.
    { name => 'server.log: Prefetch watchdog -> Soloist::Control (Wachhund Runde 1, Uebergabe; Plugin.pm _prefetchHangCheck)',
      pat  => qr/Prefetch watchdog: still on same track after 10s past end .*handing to Soloist::Control/, count => 1 },
    # 84.1 plan 03 (D-04/D-05/D-06): the health tick's own stop line
    # (DaemonManager.pm _soloistHealthTick, "unhealthy for <mac> (<reason>)")
    # plus the crash-poll's own restart line for the SAME event (the
    # existing "Unified daemon crashed for ... - restarting via startHelper"
    # INFO line, shared with every other crash-restart cause) -- without a
    # dedicated category both fell into the collective "in keiner Kategorie"
    # bucket, forcing hand-grep for plan 84.1-04's live gate.
    { name => 'server.log: Soloist health (unhealthy -> stop / crash restart)',
      pat  => qr/Soloist daemon unhealthy for |Unified daemon crashed for .* - restarting via startHelper/, count => 1 },
    { name => 'server.log: Control: watchdog forced skip (Wachhund Runde 2, erzwungener Sprung; Control.pm _watchdogRound2)',
      pat  => qr/Control: watchdog forced skip on \S+ \(round 2: /,                   count => 1 },
    # 83.2-03 orchestrator finding: e-verbose-boundary.sh:436-441 derives
    # hang=nein by grepping THIS TOOL's own output for "getNextTrack" -- but
    # no @SRV_CATS pattern ever existed for it, so the event fell into the
    # collective "in keiner Kategorie" bucket and hang=nein was unreachable
    # (every healthy boundary read hang=unbestimmt instead, poisoning H1 via
    # the plan's N_UNBESTIMMT>=1 rule). Source: the [DIAG] line SpotOn emits
    # when LMS asks it for the next track, Plugins::SpotOn::ProtocolHandler::
    # getNextTrack -- at source line 718 pre-seam (83.2-03, where this
    # category was born), at line 535 since the 84-07/08/12/13 seam.
    #
    # 84-11 pre-3b (2026-10-13): the pattern originally pinned the literal
    # "(718)"; after the seam it read 0 on every post-seam log and the D-08
    # compare reported `count[...getNextTrack (718...)] before=1 after=0`
    # (84-D08-BASELINE.md "## D-08 deviations" item 1) -- tool-caused, not a
    # seam effect. The match is now line-number-agnostic (\(\d+\)); the
    # `[DIAG] getNextTrack: mac=... url=` tail alone disambiguates from both
    # siblings that also contain the substring "getNextTrack":
    # Slim::Player::StreamingController::_getNextTrack (698, LMS-internal
    # "Loading metadata" line, different class+method) and the
    # ProtocolHandler::getNextTrack (896) dispatch-echo "soloist browse ->
    # Control->requestTrack(...)" line (never carries the [DIAG] tail) --
    # neither is covered here, both stay in the collective bucket.
    # The header text keeps "718" as the HISTORICAL pre-seam line number on
    # purpose: it is a compare key referenced verbatim by
    # librespot-baseline.sh / e-advance-mechanism.sh, t/soloist/46_uat_tools.t,
    # the t/fixtures/uat/ extracts and field 5 of every D-08 scenarios.tsv.
    # A cosmetic relabel is a separate todo, not part of pre-3b.
    { name => 'server.log: ProtocolHandler::getNextTrack (718, LMS fragt SpotOn nach dem naechsten Titel)',
      pat  => qr/ProtocolHandler::getNextTrack \(\d+\) \[DIAG\] getNextTrack: mac=\S+ url=/, count => 1 },
    # 83.1-06 (D-C2): der Mechanismusnachweis fuer den Weiterschaltpfad an der
    # Connect-Titelgrenze. Vor Plan 02/83.1-06 wurde das `change`-Ereignis vom
    # connect-guard verworfen und der Wechsel geschah nur als Nebenwirkung des
    # `resume`-Wiedereinstiegs (83-MESSUNG-C.md:753-790, 18 verworfene `change`
    # gegen 18 `resume`-Wiedereinstiege, 1:1). Drei additive Kategorien machen
    # diesen Unterschied direkt aus extract-run.pl lesbar, statt ihn per
    # Hand-Grep zu belegen (RESEARCH.md:598-616).
    #
    # Quellen: Connect.pm:1574-1578 (Drop, `_connectEvent` change-Zweig),
    # Connect.pm:1586-1588 (`Track change:` Dispatch-Zeile, nach dem Guard),
    # Connect.pm:1268-1271 (Resume-Wiedereinstieg, `_connectEvent` resume-Zweig).
    #
    # Der em dash in der Resume-Zeile ("Resume while not on Connect stream —
    # re-entering ...") ist in server.log DOPPELT-kodiert gespeichert (Bytes
    # c3 a2 c2 80 c2 94, nicht ein einfaches e2 80 94) -- das Muster ueberbrueckt
    # die Stelle mit `.*` und bleibt reines ASCII (gleiche Regel wie beim
    # Wachhund-Kanal oben).
    #
    # Bewusste Negative: der Drop der Track-change-Kategorie ist auf "change"
    # verankert, NICHT auf den textgleichen seek-Drop bei Connect.pm:1177
    # ("Dropping Connect seek event for non-Connect player") -- dieser bleibt
    # absichtlich unkategorisiert (Restzaehler).
    { name => 'server.log: Connect change verworfen (connect-guard, Connect.pm _connectEvent change-Zweig)',
      pat  => qr/Dropping Connect change event for non-Connect player/,                count => 1 },
    { name => 'server.log: Track change (Connect change-Dispatch -> playlist play; Connect.pm _connectEvent)',
      pat  => qr/Track change: \S+ -> \S+/,                                           count => 1 },
    # 84-17 (L1 repair; plan-checker B1): four evidence categories the hold
    # gates read. They had NO category -- extract-run.pl prints categorised
    # lines only (classify_records/emit_categories), so a perfect live hold
    # would have read empty and every "no nachziehen/watchdog line" check
    # would have been vacuous. Formats are the live strings of the 84-17
    # code (Connect.pm change handler/hold; Control.pm _postBoundaryRead
    # callback) and of the two pre-existing escalation rungs
    # (Control.pm _connectResync `Control: nachziehen -- reason=`, :4537;
    # _watchdogRound2 `Control: connect watchdog -- LMS did not re-open`,
    # :1059). The `Track change` pattern above keeps matching the line with
    # ` via=<v>` appended (the suffix stays inside the line).
    { name => 'server.log: Connect: hold (opened / closed by / skipped; 84-17 Connect.pm change handler)',
      pat  => qr/Connect: hold (?:opened|closed by|skipped)/,                          count => 1 },
    { name => 'server.log: Control: boundary reply (via=/anchor=; 84-17 Control.pm _postBoundaryRead)',
      pat  => qr/Control: boundary reply via=/,                                        count => 1 },
    { name => 'server.log: Control: nachziehen (split-brain / watchdog re-emit; Control.pm _connectResync)',
      pat  => qr/Control: nachziehen -- reason=/,                                      count => 1 },
    { name => 'server.log: Control: connect watchdog (Control.pm _watchdogRound2)',
      pat  => qr/Control: connect watchdog -- LMS did not re-open/,                    count => 1 },
    { name => 'server.log: Resume-Wiedereinstieg (Resume while not on Connect stream; Connect.pm _connectEvent resume-Zweig)',
      pat  => qr/Resume while not on Connect stream.*re-entering Connect via playlist play/, count => 1 },
    # 84-01 (D-18, L1/L2 attribution): two Connect.pm INFO lines that the
    # L1 discriminator (H-L1a: negative startOffset precedes the early
    # boundary) and the L2 discriminator (H-L2a/b: which spottyconnect verb
    # was dispatched right before the stale getNextTrack) need, and that
    # fell into the collective bucket (uncategorised lines are only counted,
    # never printed -- architecture rule 4). Sources: Connect.pm:1126
    # (_connectEvent entry, "Got spottyconnect event for <mac>: <verb>") and
    # Connect.pm:1268 / :1454 ("Stream mode seek: adjusted startOffset to N" /
    # "Resume: adjusted startOffset to N").
    { name => 'server.log: Connect verb event (Got spottyconnect event; Connect.pm _connectEvent entry)',
      pat  => qr/Got spottyconnect event for \S+: \S+/,                               count => 1 },
    { name => 'server.log: Connect startOffset adjust (Stream mode seek / Resume: adjusted startOffset)',
      pat  => qr/(?:Stream mode seek|Resume): adjusted startOffset to /,              count => 1 },
    # 84-01 (L2 repair proof): the INFO line Control.pm's transfer-in writes when
    # it drops the startEmittedFor marker of an ended session (LMS holds another
    # track than the session's) -- without a category the live proof could not
    # show that the repaired branch was EXERCISED (a transfer-in on a fresh
    # Control reads `start` with or without the repair).
    { name => 'server.log: Control transfer-in drops the marker of an ended session (84-01 L2 repair)',
      pat  => qr/Control: transfer-in -- LMS holds '[^']*', not the session track \S+ -- dropping the marker of an ended session/, count => 1 },
    # 84-21 (D-31 (1)): the per-player Connect switch is enforced in Control; the
    # refusal INFO line (Control.pm _refuseTransferConnectOff) is the only
    # server.log channel of the refusal and of its `deactivate` (the probe op logs
    # no dispatch line). Without a category every "refusal_lines=0" reading of the
    # live A/B/C would be vacuous (uncategorised lines are only counted, never
    # printed -- architecture rule 4).
    { name => 'server.log: Control connect-off refusal (D-31; Control.pm _refuseTransferConnectOff)',
      pat  => qr/Control: transfer-in refused -- Spotify Connect is off/,           count => 1 },
    # 84-21 (D-26 instrument gap): Connect.pm writes $song->startOffset in two
    # places that were silent or sat in no category: the mid-song connect
    # (Connect.pm:685, INFO) and the change reset (Connect.pm:2106, new INFO).
    # The seek/resume writers keep their own, unchanged adjust category above.
    { name => 'server.log: Connect startOffset write (mid-song connect / change reset; Connect.pm:685, :2106)',
      pat  => qr/(?:Stream mode mid-song connect|Stream mode change reset): startOffset=/, count => 1 },
    # 84-21 (F-20-LATCH live gate): the drift limit line (Control.pm _reconcile
    # Schritt 5) and the T1 line (Control.pm _t1Fire) had no category; a live
    # "drift_lines_in_window=0" would have read an uncategorised string (only
    # counted, never printed -- architecture rule 4) and been vacuous.
    { name => 'server.log: Control drift (daemon does not follow play; Control.pm _reconcile Schritt 5, :1865)',
      pat  => qr/daemon does not follow play \S+ after \d+ attempts/,                count => 1 },
    { name => 'server.log: Control T1 (no track_changed within; Control.pm :2726)',
      pat  => qr/Control: no track_changed within \d+ ?ms/,                          count => 1 },
    # 84-22 (W2, F-20-WRITER live gate): LMS drops a player that sends no STAT
    # for 3 x 5 s (Slim::Networking::Slimproto::check_all_clients,
    # Slimproto.pm:219-228) and logs it only at INFO, logger
    # network.protocol.slimproto (Slimproto.pm:31, :224). A SIGSTOPped player
    # answers no poll, so a 15 s stall run can lose the control connection on
    # LMS's side; without a category every "no heartbeat close" reading would
    # be an uncategorised string (only counted, never printed -- rule 4) and
    # a heartbeat drop would read as the writer's doing.
    { name => "server.log: Slimproto heartbeat close (Haven't heard from; Slimproto.pm:224, INFO network.protocol.slimproto)",
      pat  => qr/Haven't heard from \S+ in \d+ seconds, closing connection/,        count => 1 },
    # 84-23 (D-26 attribution input): Slim::Networking::Slimproto::_stat_handler
    # logs, at INFO on network.protocol.slimproto, ONE PER-MAC line per STAT
    # frame (Slimproto.pm:809-814): `<mac>: STAT-<code>: fullness=N,
    # output_fullness=N, elapsed=S`. It carries the MAC and the player's own
    # elapsed value; the DEBUG `elapsed milliseconds` block (:852-861) has no
    # MAC and pa's STATs interleave, so it is never the attribution input.
    # Without a category the line is only counted, never printed (rule 4).
    { name => 'server.log: slimproto STAT (per-MAC INFO: fullness / output_fullness / elapsed; Slimproto.pm:810)',
      pat  => qr/: STAT-\w+: fullness=\d+, output_fullness=-?\d+, elapsed=-?[\d.]+/, count => 1 },
    # 85 D-25 runtime gate: Slim::Networking::SimpleHTTP::Base::_createHTTPRequest logs `<TYPE>ing <url>`
    # (GETing / POSTing / PUTing / DELETEing) at DEBUG on network.asynchttp (SimpleHTTP/Base.pm:97). The
    # lines only exist while that category is at DEBUG -- a RUNTIME switch that every LMS restart clears.
    # Absence in a window therefore reads "nicht gefunden im Fenster" (rule 4), never "no Web-API request":
    # a verdict needs the armed-state proof (menu-walk.pl --arm-webapi-log, ARMED line) and the server.log
    # coverage line -- that is tools/uat/webapi-gate.pl's job, never a hand reading. Sits BEFORE the 84.3 entries and
    # the 84-26 entry (which stays last: the remainder line follows the last section, and t/46's
    # 84.3-settle subtest pins that the buffering section is followed directly by the 84-26 header).
    { name => 'server.log: Web API request (api.spotify.com; LMS network.asynchttp DEBUG "<TYPE>ing <url>", 85 D-25)',
      pat  => qr/api\.spotify\.com/,                                                 count => 1 },
    # 85-16 (D-25 live acceptance, D-02/D-03/D-21/D-23): the auth-chain lines. Without a category they
    # were only counted (rule 4) and "kept (same id)" / "re-keyed" / "paired credentials installed" could be
    # proven only by hand-grep. The names are read by 85-16/85-17's verify commands -- keep them exactly.
    # Sit BEFORE the 84.3 entries and the 84-26 entry (t/46 84.3-settle pins that the buffering section is followed directly by the 84-26 header).
    # (1) AccountMigration.pm: per-account summary at WARN (kept (same id) / re-keyed to / needs pairing),
    #     the journal lines and the failure lines, plus Plugin.pm's "Auth chain migration failed:".
    { name => 'server.log: 85 auth-chain migration (D-02/D-03)',
      pat  => qr/Auth chain migration/,                                              count => 1 },
    # (2) Credentials.pm installAccountCredentials: `Pairing: paired credentials installed for account <mask>
    #     (source <src>)` at WARN (pairing and discover both pass through it) and the discover-folder import
    #     line at INFO.
    { name => 'server.log: 85 credentials installed (D-21/D-23)',
      pat  => qr/Pairing: paired credentials installed for account|Credentials: account \S+ imported from the discover folder/, count => 1 },
    # (3) Plugin.pm _removePkceOnce: `PKCE cleanup: removed N stored token file(s), ...` -- logged at INFO,
    #     so it reaches server.log only when plugin.spoton is at INFO or lower during the start window.
    { name => 'server.log: 85 PKCE artifact cleanup (D-01)',
      pat  => qr/PKCE cleanup: removed/,                                             count => 1 },
    # (4) Credentials.pm discover intake refusals (symlink / not a regular file / not imported / identity mismatch).
    { name => 'server.log: 85 discover intake refused (D-23)',
      pat  => qr/Credentials: (?:the discover folder is a symlink|credentials\.json in the discover folder is (?:a symlink|not a regular file)|the file in the discover folder was not imported|installed credentials belong to account)/, count => 1 },
    # 79-13 (D-03, 76 point 19): librespot eject on deselect. Backend/Librespot.pm _sendControlCommand answers a
    # 409 (the device is not the active Connect target, GH #159) with a WARN line (:360-363, written at every level
    # from WARN up, diagnosticMode or not) and, only while diagnosticMode=1, its twin `[DIAG] control_cmd_rejected:`
    # (:364). Without a category both were only counted (rule 4). Absence reads "nicht gefunden im Fenster", no verdict.
    # Sits BEFORE the 84.3 entries and the 84-26 entry (t/46 extract-run-79-eject, 84.3-settle pin the order).
    { name => 'server.log: librespot eject on deselect (GH #159: control command rejected 409; Backend/Librespot.pm _sendControlCommand)',
      pat  => qr/rejected for \S+ - device is not the active Connect target|\[DIAG\] control_cmd_rejected: /, count => 1 },
    # 79-27 (D-18, LIKED repair): spclient track-metadata requests. SpClient hydrates a track list with one
    # `GET metadata/4/track/<32 hex>` per track or, after 79-27, one `POST extended-metadata/v0/extended-metadata`
    # per batch; network.asynchttp logs `<TYPE>ing <url>` at DEBUG (SimpleHTTP/Base.pm:97) -- a RUNTIME switch
    # (menu-walk.pl --arm-webapi-log) that every LMS restart clears. The Web API category above matches only
    # api.spotify.com, so these lines were only counted (rule 4). Absence reads "nicht gefunden im Fenster",
    # never "no request". Sits BEFORE the 84.3 entries and the 84-26 entry (t/46 extract-run-79-eject, 84.3-settle).
    { name => 'server.log: spclient track metadata request (network.asynchttp DEBUG "<TYPE>ing <url>": metadata/4/track or extended-metadata, 79-27 D-18)',
      pat  => qr/(?:GET|POST)ing https:\/\/\S+\/(?:metadata\/4\/track\/[0-9a-f]{32}|extended-metadata\/v0\/extended-metadata)/, count => 1 },
    # 79-28 (D-23): the LMS side of every librespot control direction. Backend/Librespot.pm _sendControlCommand writes
    # `[DIAG] control_cmd_sent: mac=<mac> endpoint=<path> body=<json>` (only while diagnosticMode=1) for every POST to the
    # daemon (/control/play|pause|volume|next|prev|seek). Without a category they were only counted (rule 4). Absence reads
    # "nicht gefunden im Fenster" (diagnosticMode off is also absence). Sits BEFORE the 84.3 entries and the 84-26 entry
    # (t/46 extract-run-79-eject, 84.3-settle pin the order).
    { name => 'server.log: librespot control command sent ([DIAG] control_cmd_sent; Backend/Librespot.pm _sendControlCommand, 79-28 D-23)',
      pat  => qr/\[DIAG\] control_cmd_sent: /,                                        count => 1 },
    # 79-28 (D-23): the other direction (app -> LMS): Connect.pm writes `[DIAG] seek_from_binary:` and
    # `[DIAG] volume_from_binary:` (diagnosticMode=1) for the daemon's Seeked / VolumeChanged events. Own category, not the
    # control one: a control line is something LMS SENT, these are something LMS RECEIVED. The real run8 cut
    # (t/fixtures/uat/84.3-c5-run8-server-pause-won.log:31) already holds one real seek_from_binary line.
    { name => 'server.log: librespot daemon event received ([DIAG] seek_from_binary / volume_from_binary; Connect.pm _connectEvent, 79-28 D-23)',
      pat  => qr/\[DIAG\] (?:seek_from_binary|volume_from_binary): /,                  count => 1 },
    # 79-32 (D-27): the SpotOn PauseGuard (Plugin.pm _pauseGuardCheck) writes `[DIAG] PauseGuard: re-applying pause (swallowed
    # <age>s ago) mac=<id>` when it re-pauses a pause that came back to play on the SAME song, and `[DIAG] PauseGuard: dropped,
    # song changed since the pause request (<idx>:<url> -> <idx>:<url>) mac=<id>` when it drops the guard instead. Both only
    # while diagnosticMode=1; the 79-30 line (server.log:50759, 2026-10-22) carries no MAC. Without a category they were only
    # counted (rule 4). Absence reads "nicht gefunden im Fenster", never "no re-apply" (diagnosticMode off is also absence).
    # runners/pauseguard-gate.sh reads this section. Sits BEFORE the 84.3 entries and the 84-26 entry (t/46 extract-run-79-eject,
    # 84.3-settle pin the order).
    { name => 'server.log: PauseGuard ([DIAG] PauseGuard: re-applying pause / dropped after a song change; Plugin.pm _pauseGuardCheck, 79-32 D-27)',
      pat  => qr/\[DIAG\] PauseGuard: (?:re-applying pause|dropped)/,                     count => 1 },
    # 79-32 (D-27, mechanism a2): LMS' own sync controller (Slim::Player::StreamingController::_CheckSync, :566 / :576) logs its
    # corrections of a sync slave as `<mac> resync: skipAhead <n>ms` or `<mac> resync: pauseFor <n>ms` at player.sync INFO. player.sync
    # is at ERROR by default, so the lines exist only after `debug player.sync INFO` (a RUNTIME switch that every LMS restart clears);
    # absence is no verdict. The master's slave corrections show here (the repeat of the sync scenario, 79-36). Sits BEFORE the 84.3
    # entries and the 84-26 entry (t/46 extract-run-79-eject, 84.3-settle pin the order).
    { name => 'server.log: LMS sync resync (player.sync INFO "<mac> resync: skipAhead|pauseFor <n>ms"; StreamingController.pm:566/576, 79-32 D-27 a2)',
      pat  => qr/resync: (?:skipAhead|pauseFor) -?\d+ms/,                                   count => 1 },
    # 84.3-03 (D-09): the context-end settle (Connect.pm _settleNow, 84.3-01) leaves FOUR kinds of
    # server.log line that no category printed -- they were only counted (rule 4), so a guarded hit
    # (or its absence) could be proven only by hand-grepping. The four entries below sit BEFORE the
    # 84-26 entry on purpose: the section of the LAST @SRV_CATS entry is followed by the remainder
    # line `[N von M server.log-Fensterzeilen ...]`, which a body capture up to the next `--- `
    # header would read as part of that section. The 84-26 entry stays last. The name prefixes are
    # read by the advance derive (84.3-04) and the digest (84.3-05) -- keep them exactly.
    # (1) the settle itself, a WARN line (Connect.pm _settleNow).
    { name => 'server.log: Connect: context-end settle (Pause discarded while rebuffering -> own stop; Connect.pm _settleNow, 84.3)',
      pat  => qr/Connect: context-end settle -- /,                                   count => 1 },
    # (2) the settle evaluation, INFO lines: outcome (_settleCheck), grace skipped / re-armed (_settleFire),
    # grace cancelled (_settleCancel). One prefix covers every variant incl. `grace re-armed (data_arriving)`.
    { name => 'server.log: Connect: context-end check (settle evaluation / grace armed / skipped / cancelled; Connect.pm _settleCheck/_settleFire/_settleCancel, 84.3)',
      pat  => qr/Connect: context-end check -- /,                                    count => 1 },
    # (3) LMS' own StreamingController DEBUG rows: the underrun/NoOp pair of a discarded pause
    # (`OutputUnderrun in PLAYING-STREAMING -> ::_Rebuffer`, `Pause in BUFFERING-STREAMING -> ::_NoOp`)
    # and the honoured one (`Pause in PLAYING-STREAMING -> ::_Pause`).
    { name => 'server.log: LMS pause/underrun state rows (Pause in <STATE> -> / OutputUnderrun in <STATE> -> ; StreamingController DEBUG, 84.3 D-09)',
      pat  => qr/(?:Pause|OutputUnderrun) in [A-Z-]+ -> \S+/,                        count => 1 },
    # (4) D-09's tail: Slim::Player::Player::_buffering logs `Buffering... <fullness> / <threshold>` at
    # DEBUG without a MAC (the header notes the KEINE-MAC share). Both thresholds print; the digest
    # counts only the `/ 81920` lines after its reference row.
    { name => 'server.log: LMS buffering progress (Buffering... <fullness> / <threshold>; Slim::Player::Player::_buffering, carries no MAC, 84.3 D-09 tail)',
      pat  => qr/Buffering\.\.\. \d+ \/ \d+/,                                        count => 1 },
    # 84-26 (F-24-1 / F-24-2 live gates): the five INFO lines the repairs write are the only server.log
    # channel of their effect -- the R1 refusal (Control.pm _reconcilePlan, logged through _execute), the R3
    # hold (_holdAfterForeignLeave), the F-24-2 Control follow-the-daemon (requestTrack) and the two F-24-2
    # Connect lines (_connectEvent: the resume jump, the change-handler unpause skip). Without a category a
    # live "refusal_lines=0" / "jump_line=0" would read an uncategorised string (only counted, never printed
    # -- rule 4) and be vacuous.
    # 84.2-05: the same category also prints the dormant-session handoff (requestTrack) and the
    # context-end re-adoption hold (_holdAfterForeignLeave); the context-end resume refusal is the R1
    # line with an extra ` planted=` token and is matched by its unchanged prefix. Without a category
    # the three 84.2-05 lines would be counted, never printed (rule 4), and 84.2-04 R7's live reading
    # would be vacuous. The name keeps its `server.log: 84-26 repairs` prefix (t/46 matches by prefix).
    { name => 'server.log: 84-26 repairs (resume refusal / autoplay re-adoption hold / transfer-in re-open follows the daemon / resume position set / change unpause skipped) / 84.2-05 (dormant-session handoff / context-end re-adoption hold)',
      pat  => qr/requestResume refused -- daemon on|plays the autoplay-paused title .* -- not re-adopting|LMS re-open after transfer-in at|resume while LMS paused with the stream gone|change while LMS paused with the stream gone|-- handing over to browse|plays the context-end title .* -- not re-adopting/, count => 1 },
);

my @DMN_CATS = (
    { name => 'Daemon-Log: client-attach / client-close / flush-disconnect',
      pat  => qr/client-attach: new \/stream client fd=|client-close:|flush-disconnect:/, count => 0 },
    { name => 'Daemon-Log: pa_stream_flush',
      pat  => qr/pa_stream_flush\(stream=/,                                          count => 1 },
    { name => 'Daemon-Log: flush: (BOUNDARY-Detailzeile zum pa_stream_flush -- bytes_written/ring_fill/corked)',
      pat  => qr/BOUNDARY ts=[0-9:.]+\] flush:/,                                     count => 1 },
    { name => 'Daemon-Log: seek_arm / seek_arm_expired / boundary_planted',
      pat  => qr/seek_arm: armed=|seek_arm_expired:|boundary_planted:/,              count => 0 },
    { name => 'Daemon-Log: cork',
      pat  => qr/cork:/,                                                             count => 0 },
    # 84.1 plan 05: der aktuelle Build schreibt den Ticker im neuen,
    # datumslosen Format ("HH:MM:SS.mmm I [f:N ...] playing ...", ANSI schon
    # in scan_log() entfernt) -- das alte, datierte Format ("YYYY-MM-DD
    # HH:MM:SS.mmm: playing ...") bleibt als zweite Alternative unveraendert,
    # aeltere Logdateien tragen beide Formen gemischt.
    { name => 'Daemon-Log: Ticker (playing/paused/stopped)',
      pat  => qr/(?:[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+: |[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+\s+[A-Za-z]\s+\[f:[0-9]+\s*\]\s+)(?:playing|paused|stopped) /, count => 0 },
    { name => 'Daemon-Log: Sitzungszustand (became active device / no longer active / shutting down / restoring session / ready / login failed)',
      pat  => qr/became active device|no longer active|shutting down|restoring session|login failed|: ready/, count => 0 },
    # 84.2 plan 03 (CAUSE-1, D-11): one line per context end names the account's
    # Autoplay setting -- "from no request" = OFF, "from hm://context-resolve/v1/
    # autoplay" = ON (real: 84-19-spike-autoplay-261004/off-1/daemon-window.txt
    # :101/:4697). The siblings "routing for ..." and "request successful with N
    # tracks" stay out. The acceptance runner's per-row classifier
    # (_autoplay_gates.py setting) reads this body; without the category the
    # line is only counted, never printed (rule 4).
    { name => 'Daemon-Log: autoplay request (requesting autoplay context from ... -- "no request" = Autoplay AUS, hm://context-resolve = AN)',
      pat  => qr/autoplay: requesting autoplay context from /,                       count => 1 },
    # 79-28 D-23: the librespot daemon's unified log (<mac>-unified.log, parsed since 79-28) names every Connect
    # command it received from Spotify as `handling: 'endpoint: <verb>' from <device id>` at DEBUG
    # (librespot_connect::spirc) -- pause, resume, skip_prev, transfer, seek ... : the daemon side of every l16
    # direction. Without a category the lines were only counted (rule 4). Absence reads "nicht gefunden im Fenster".
    { name => "Daemon-Log: librespot Connect endpoint (handling: 'endpoint: <verb>'; unified log)",
      pat  => qr/handling: 'endpoint: \w+'/,                                          count => 1 },
    # 79-38 (79 D-31): the 79-37 shim's gap hold writes hold_armed / hold_consumed / hold_released reason=<...> /
    # hold_suppressed / hold_skipped as `[fakepulse BOUNDARY ts=...] <line>` (fake-libpulse.c), and the close of a
    # held boundary as `boundary_reached: closing client ... wrote= total_popped= boundary= trimmed=`. runners/
    # boundary-gate.sh (a held boundary_planted line needs its boundary_reached) and runners/resume-gate.sh (release /
    # suppressed vs timeout) read them from here. Before this entry they were only counted, never printed (rule 4).
    # The boundary_planted line (with its hold= / hold_at= fields) stays in its own category above. Absence reads
    # "nicht gefunden im Fenster" (no hold armed in that window), never "no hold".
    { name => 'Daemon-Log: gap hold (hold_armed / hold_consumed / hold_released / hold_suppressed / hold_skipped; 79 D-31 fake-libpulse) / boundary_reached',
      pat  => qr/\] hold_(?:armed|consumed|released|suppressed|skipped): |\] boundary_reached: /, count => 1 },
);

# Rauschkategorien des Daemon-Logs: eigene Behandlung, aber sie zaehlen als
# kategorisiert (und als "Signal war da" fuer den Banner-Test, N-WR-02).
my $UNDERFLOW_PAT  = qr/underflow/;
my $WRITE_SUM_PAT  = qr/write_summary:/;

# Recorder-Frametypen, die einzeln ausgegeben werden. playback_state traegt
# status/uri -- dieselben Felder, die WR-01 fuer playback_changed sichtbar
# gemacht hat (N-WR-05).
#
# 83.2-02: queue_changed fiel bisher in den else-Zweig ("anderer Typen"),
# weil rec_field() (unten, NICHT angefasst) nur Skalare an einem
# Punkt-Pfad liest -- previous/upcoming sind jedoch Arrays (uid/source/item
# je Eintrag). Quelle: soloist-developer-docs.md:334-336 (previous/
# upcoming-Arrays mit uid/source/item); 83.2-RESEARCH §3/§4; D-03 ("ob
# `upcoming` in diesem Moment leer ist"). rec_queue_summary() (unten, neben
# rec_field, nicht darin) liefert drei unterscheidbare Zustaende statt
# eines stummen undef: 0 = leeres Array (Schluessel vorhanden, Laenge 0),
# FEHLT = Schluessel nicht vorhanden, KEIN_ARRAY = Schluessel vorhanden,
# aber kein Array -- genau diese Unterscheidung ist der Messzweck dieser
# Erweiterung (Regel 2: nie stillschweigend verwerfen).
my %REC_LISTED = map { $_ => 1 }
    qw(position_sync playback_changed track_changed device_changed playback_state queue_changed);

# ---------------------------------------------------------------------------
# Kleine Helfer
# ---------------------------------------------------------------------------
sub err_line { my ($m) = @_; print STDERR "$m\n"; return; }

sub abort { my ($m) = @_; err_line($m); exit 1; }

sub usage {
    return <<'USAGE';
tools/uat/extract-run.pl <mac> <T0> <T1> [--out FILE] [--recorder FILE]
  [--recorder-seconds N] [--server-log FILE] [--daemon-log FILE]
  [--date YYYY-MM-DD] [--daemon-end-epoch E]

  <mac>   Spieler-MAC, z.B. 02:00:00:5a:11:03
  <T0>    Fensteranfang-Anker, HH:MM:SS[.mmm] (lokale Zeit)
  <T1>    Fensterende-Anker, HH:MM:SS[.mmm] (lokale Zeit)

Flags:
  --out FILE             Ausgabe zusaetzlich in FILE schreiben
  --recorder FILE         Recorder-JSONL-Mitschnitt
  --recorder-seconds N    erwartete Recorder-Laufzeit ab T0
  --server-log FILE       Default: /var/log/squeezeboxserver/server.log
  --daemon-log FILE       Default: aus <mac> abgeleitet
  --full                  write_summary/underflow vollstaendig statt zusammengefasst
  --date YYYY-MM-DD       schraenkt bei Mehrtages-Mehrdeutigkeit ein; fuer das
                          Daemon-Log aktueller Soloist-Builds (datumslose
                          UTC-Tickerzeilen) ERFORDERLICH -- ohne --date bleibt
                          der Daemon-Kanal dunkel (WR-10, round 3)
  --daemon-end-epoch E    Ende-Anker der Tagesrekonstruktion des Daemon-Logs
                          (Epoche der letzten Zeile; Default: mtime der Datei;
                          fuer Kopien ohne erhaltene mtime)
  --help / -h             diese Hilfe

WICHTIG: Laufnamen wie "L1" sind zwischen Messreihen mehrdeutig (z.B. G3-L1
und G4-L1 sind VERSCHIEDENE Laeufe). Immer MAC+T0+T1 exakt aus der
jeweiligen Quelltabelle uebernehmen, nie nur den Kurznamen.

Env-Var-Override: SUDO_BIN (Default "sudo"), STAT_BIN (Default "stat")
USAGE
}

# ---------------------------------------------------------------------------
# parse_hms($string) -- DIE EINZIGE Stelle, die eine Zeitzeichenkette in
# Sekunden seit Tagesbeginn umrechnet (Architekturvorgabe 1).
#
# Rueckgabe im Listenkontext: ($sekunden, $streng) -- $streng ist 0, wenn die
# Zeichenkette nur ueber einen numerischen Praefix gelesen werden konnte
# (dann wird die Zeile im Restzaehler gemeldet, Regel 2). Ohne lesbare
# dritte Komponente: undef.
# ---------------------------------------------------------------------------
sub parse_hms {
    my ($str) = @_;
    return (undef, 0) unless defined $str;
    my @p = split /:/, $str, -1;
    return (undef, 0) unless @p >= 3 && defined $p[2] && $p[2] ne '';
    my $strict = ($str =~ /^[0-9]{1,2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?$/) ? 1 : 0;
    my @n;
    for my $i (0 .. 2) {
        my $v = $p[$i];
        $v = ($v =~ /^\s*([0-9]+(?:\.[0-9]+)?)/) ? $1 : 0;
        push @n, $v + 0;
    }
    return ($n[0] * 3600 + $n[1] * 60 + $n[2], $strict);
}

# fmt_hms($sec) -- HH:MM:SS.mmm; negative Werte werden auf 00:00:00 geklemmt
# (der Aufrufer meldet das Klemmen laut, siehe Mitternachtshinweis).
sub fmt_hms {
    my ($s) = @_;
    $s = 0 if !defined $s || $s < 0;
    my $h = int($s / 3600); $s -= $h * 3600;
    my $m = int($s / 60);   $s -= $m * 60;
    return sprintf('%02d:%02d:%06.3f', $h, $m, $s);
}

# ---------------------------------------------------------------------------
# classify_mac($raw, $mac_lower) -- drei Zustaende, nicht zwei: eine Zeile
# traegt entweder die gesuchte MAC ("own"), oder ausschliesslich fremde MACs
# ("foreign"), oder ueberhaupt keine MAC ("none"). Der dritte Fall ist NICHT
# "eigene MAC" -- er ist "nicht zuordenbar".
# ---------------------------------------------------------------------------
sub classify_mac {
    my ($raw, $mac_lower) = @_;
    my %seen;
    while ($raw =~ /($MAC_RE)/g) { $seen{ lc $1 } = 1; }
    my @all = sort keys %seen;
    return ('none', []) unless @all;
    return ('own', [$mac_lower]) if $seen{$mac_lower};
    return ('foreign', \@all);
}

# ---------------------------------------------------------------------------
# resolve_dateless_utc($h, $m, $s, $frac_ms, $state) -- 84.1 plan 05.
#
# GEMESSEN, nicht angenommen: der aktuelle Soloist-Build schreibt seine neuen
# Ticker-Zeilen ohne Datum, nur "HH:MM:SS.mmm", und diese Uhrzeit ist UTC
# (nicht lokal). Beleg (260928-Lauf, A2-Szenario "mid-track seek to 90s"):
# meta.txt A2_FIRST_RISE=90.0, LMS-Statuszeile bei lokaler Epoche 1790622094
# (Mo 2026-09-28 21:01:34 CEST) -- exakt zeitgleich steht im Daemon-Log
# "19:01:34.482 I [f:77 ...] playing ... [1:30 / 4:55]": 1:30 = 90s, und
# 19:01:34 UTC + 2h CEST-Offset = 21:01:34 lokal. Zweite, unabhaengige Zeile
# derselben Sekunde: A1s Rewind-Ziel 0:10 erscheint als "19:08:50.969 ...
# paused ... [0:10 / 4:55]" im selben UTC-lokal-Versatz.
#
# Der Kalendertag der datumslosen Zeile wird NICHT aus der letzten datierten
# Zeile uebernommen (Regel 3 unten bleibt fuer [fakepulse ...] unveraendert)
# -- im aktuellen Log ist das neue Format die weit ueberwiegende Mehrheit
# (482882 von 489719 Zeilen im 260928-Lauf), eine datierte Ankerzeile liegt
# oft ausserhalb des Fensters oder fehlt ganz. Stattdessen wird er aus --date
# abgeleitet: fuer die drei Kandidatentage {Fenstertag-1, Fenstertag,
# Fenstertag+1} (timegm-Mitternacht des Fenstertags +/- 86400s -- DST-frei,
# also ohne die Ungenauigkeit einer lokalen Mitternachtsverschiebung) wird
# die UTC-Uhrzeit der Zeile zu einer Kandidaten-Epoche addiert und per
# localtime() (nutzt die Systemzeitzone INKLUSIVE Sommerzeit fuer genau
# dieses historische Datum) auf einen lokalen Kalendertag zurueckgerechnet.
# Der Kandidat, dessen lokaler Kalendertag GLEICH --date ist, gewinnt --
# NICHT (WR-09, 84.1-REVIEW.md round 3 -- vorherige Fassung) der erste
# Kandidat, dessen lokale Uhrzeit ins Fenster faellt: die Uhrzeit ist auf
# allen drei Kandidatentagen identisch, ausser genau ueber eine Sommer-/
# Winterzeitumstellung hinweg, kann also die drei Kandidaten nicht
# unterscheiden und haette immer den ERSTEN (Fenstertag+0) genommen. Die
# Fensterpruefung selbst bleibt ausschliesslich bei scan_log (:655-662,
# bereits lokal). Das deckt sowohl "Fenster nahe lokaler Mitternacht" als
# auch "UTC-Tag != lokaler Tag" ab (z.B. 00:30 CET lokal = 23:30 UTC am
# Vortag: der Kandidat Fenstertag-1 trifft dann). NICHT geloest (benannt,
# nicht versteckt): ein Fenster, das exakt auf den Umschaltmoment Sommer-/
# Winterzeit faellt -- dort kann Fenstertag+/-1 * 86400s um die
# Umstellstunde daneben liegen; das betrifft zwei Momente im Jahr und
# keinen der 84.1-05-Laeufe.
#
# Ohne --date (state->{local_date} leer) ist der Fenstertag nicht bekannt --
# die Zeile bleibt dann unaufgeloest (Rueckgabe (undef,undef); WR-10
# (round 3) gibt dem Aufrufer dafuer einen eigenen, lauten Verwurfsgrund
# statt des stillen 'unrecognized').
# ---------------------------------------------------------------------------
sub resolve_dateless_utc {
    my ($h, $m, $s, $frac_ms, $state) = @_;
    my $local_date = $state->{local_date};
    return (undef, undef)
        unless defined $local_date && $local_date =~ /^([0-9]{4})-([0-9]{2})-([0-9]{2})$/;
    my ($Y, $Mo, $D) = ($1, $2, $3);

    my $utc_midnight = eval { timegm(0, 0, 0, $D + 0, $Mo - 1, $Y - 1900) };
    return (undef, undef) unless defined $utc_midnight;

    # WR-09 (84.1-REVIEW.md round 3): select the candidate whose LOCAL
    # calendar day equals --date -- NOT whether its time-of-day happens to
    # fall inside the window. Time-of-day is identical on every candidate
    # day (delta=0/-1/+1 only differ by a whole day), so testing against the
    # window cannot discriminate between them and always accepted delta=0
    # first, silently returning the day AFTER --date whenever a UTC clock
    # >=22:00 CEST/23:00 CET happened to also land inside the window. The
    # window itself is (correctly) re-applied afterwards by scan_log's own
    # outside/day_filtered bookkeeping (:655-662) -- this function's only
    # job is the day.
    for my $delta (0, -1, 1) {
        my $cand_epoch = $utc_midnight + $delta * 86400 + $h * 3600 + $m * 60 + $s;
        my @lt = localtime($cand_epoch);
        my $local_day_full = sprintf('%04d-%02d-%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3]);
        next unless $local_day_full eq $local_date;          # the day is the discriminator
        my $local_ts = sprintf('%02d:%02d:%02d.%03d', $lt[2], $lt[1], $lt[0], $frac_ms + 0);
        return ($local_ts, $local_day_full);
    }
    return (undef, undef);
}

# ---------------------------------------------------------------------------
# 84-22 splice fix (Debug-Sitzung shim-final-browse-reconnect, Nutzer-
# entscheidung 2026-10-06 Option 3): Tagesrekonstruktion des Daemon-Logs.
#
# Das Daemon-Log traegt seit 2026-09-23 KEINE datierte Zeile mehr; es umfasst
# viele Tage (2.28 GB, ~30 Tage). Vorher bekam jede datumslose UTC-Tickerzeile
# den --date-Tag (die Ticker ALLER Tage zur selben Uhrzeit landeten im
# Fenster -- die "vier Titel" von 84-22) und jede [fakepulse ...]-Zeile den
# Tag der letzten datierten Zeile (2026-09-23 -- die eigenen [fakepulse]-
# Zeilen des Laufs fielen heraus, "MUSTER NICHT GEFUNDEN").
#
# Das Log wird nur angehaengt, also ist seine Zeilenfolge chronologisch:
#  (1) daemon_day_plan() (erster Durchlauf): eine UTC-Tickerzeile, deren Uhr
#      mehr als $DAY_TOL hinter der vorigen UTC-Tickerzeile liegt, beginnt
#      den naechsten Tagesabschnitt (Mitternacht, Luecke ueber Mitternacht,
#      oder ein zusammengeschnittenes Fenster wie das archivierte 103109).
#  (2) Ende-Anker: der LETZTE Abschnitt liegt auf dem spaetesten UTC-Tag, auf
#      dem die letzte Tickeruhrzeit hoechstens $END_SLACK nach der mtime der
#      Datei liegt (--daemon-end-epoch ersetzt die mtime, fuer Kopien ohne
#      erhaltene mtime); fruehere Abschnitte zaehlen je einen Tag zurueck.
#      Gemessen 2026-10-06: vom Ende zurueckgezaehlt treffen die 12 Grenzen
#      die Archivdaten (84-20 10-04, 84-20 10-05, 84-22 10-06), vorwaerts
#      von der letzten datierten Zeile gezaehlt endet man einen Tag zu frueh
#      (eine >24 h-Pause nach 09-23 ist unsichtbar) -- deshalb das Ende.
#  (3) [fakepulse ...]-Zeilen (lokale Uhr, DST-korrekt per mktime) liegen auf
#      dem ersten lokalen Zeitpunkt ihrer Uhrzeit, der nicht mehr als
#      $DAY_TOL vor der vorigen aufgeloesten Zeile liegt; vor der ersten
#      Tickerzeile auf dem letzten Zeitpunkt nicht nach ihr.
# Ohne Tagesgrenze und ohne --daemon-end-epoch bleibt alles wie bisher
# (Regel 3 / WR-09..11: Ticker aus --date, [fakepulse] aus der letzten
# datierten Zeile) -- ein Abschnitt enthaelt jede Uhrzeit hoechstens einmal.
# Mit Grenzen, aber ohne lesbare mtime: ebenfalls wie bisher, LAUT gemeldet.
# Restgrenzen (benannt): eine Pause von >= 24 h ohne Rueckschritt der Uhr ist
# unsichtbar (Abschnitte davor sind dann einen Tag zu spaet datiert); eine
# Fuge, die nur im [fakepulse]-Kanal sichtbar ist (keine Tickerzeile auf
# einer Seite), trennt die Ticker nicht; die DST-Rueckstellungsstunde
# (einmal im Jahr, 02-03 Uhr lokal) kann eine [fakepulse]-Zeile um einen Tag
# verschieben.
# ---------------------------------------------------------------------------
sub daemon_day_plan {
    my ($fh) = @_;
    my ($n, $prev, $first_line, $first_sod) = (0, undef, undef, undef);
    my @bounds;
    while (defined(my $l = <$fh>)) {
        $n++;
        my $c = ord($l);
        next unless ($c >= 48 && $c <= 57) || $c == 27;
        $l =~ s/\x1b\[[0-9;]*m//g;
        next unless $l =~ /^([0-9]{2}):([0-9]{2}):([0-9]{2}\.[0-9]{3})\s+[A-Za-z]\s+\[f:[0-9]+\s*\]/;
        my $sod = $1 * 3600 + $2 * 60 + $3;
        push @bounds, $n if defined $prev && $sod < $prev - $DAY_TOL;
        $prev = $sod;
        ($first_line, $first_sod) = ($n, $sod) unless defined $first_line;
    }
    return { lines => $n, bounds => \@bounds, groups => (defined $prev ? @bounds + 1 : 0),
             last_sod => $prev, first_line => $first_line, first_sod => $first_sod };
}

# daemon_end_epoch($path, $sudo_bin) -- mtime des Daemon-Logs: direkt (Archiv,
# Testdatei) oder ueber `sudo -n stat -c %Y` (Cache-Verzeichnis 0700).
sub daemon_end_epoch {
    my ($path, $sudo_bin) = @_;
    my @st = stat($path);
    return $st[9] if @st;
    my ($out, $rc) = capture_quiet($sudo_bin, '-n', 'stat', '-c', '%Y', $path);
    return ($rc == 0 && defined $out && $out =~ /^\s*([0-9]+)\s*$/) ? $1 + 0 : undef;
}

# finish_day_plan($scan, $end) -- Basis-Epoche (00:00 UTC) je Abschnitt aus dem
# Ende-Anker; undef ohne Ticker oder ohne Anker.
sub finish_day_plan {
    my ($scan, $end) = @_;
    return undef unless $scan->{groups} && defined $end;
    my $last_base = POSIX::floor(($end + $END_SLACK - $scan->{last_sod}) / 86400) * 86400;
    my $g = $scan->{groups};
    my @base = map { $last_base - ($g - 1 - $_) * 86400 } 0 .. $g - 1;
    my %p = (%$scan, base => \@base, end => $end);
    $p{first_tick_abs} = $base[0] + $scan->{first_sod};
    return \%p;
}

sub _local_day_ts {
    my ($ep) = @_;
    my $i = POSIX::floor($ep);
    my $ms = int(($ep - $i) * 1000 + 0.5);
    if ($ms >= 1000) { $i++; $ms -= 1000; }
    my @lt = localtime($i);
    return (sprintf('%04d-%02d-%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3]),
            sprintf('%02d:%02d:%02d.%03d', $lt[2], $lt[1], $lt[0], $ms));
}

# day_plan_note($scan, $plan, $src) -- die Berichtszeile der Tagesrekonstruktion
sub day_plan_note {
    my ($scan, $plan, $src) = @_;
    return '!! Tagesrekonstruktion: Daemon-Log im ersten Durchlauf nicht gelesen -- Tage wie bisher aus --date / der letzten datierten Zeile.'
        unless $scan;
    my @bl = @{ $scan->{bounds} };
    my $nb = scalar @bl;
    my $gw = $nb == 1 ? 'Tagesgrenze' : 'Tagesgrenzen';
    my $at = $nb ? ' bei Zeile ' . join(',', @bl[0 .. ($nb > 5 ? 4 : $nb - 1)]) . ($nb > 5 ? ',...' : '') : '';
    if ($plan) {
        my @b = @{ $plan->{base} };
        my $ymd = sub { my @t = gmtime($_[0]); return sprintf('%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3]); };
        return sprintf('Tagesrekonstruktion: %d %s (die UTC-Tickeruhr springt um mehr als %.1f s zurueck%s) -> %d Abschnitt(e), UTC-Tage %s .. %s; Ende-Anker %s=%s (letzte Tickerzeile %s UTC). [fakepulse]-Zeilen liegen auf dem ersten lokalen Zeitpunkt ihrer Uhrzeit nach der vorigen Zeile (84-22 splice fix).',
                       $nb, $gw, $DAY_TOL, $at, scalar @b, $ymd->($b[0]), $ymd->($b[-1]), $src, $plan->{end}, fmt_hms($scan->{last_sod}));
    }
    return sprintf('!! Tagesrekonstruktion: %d %s erkannt%s, aber KEIN Ende-Anker (mtime nicht lesbar, kein --daemon-end-epoch) -- Tage wie bisher aus --date / der letzten datierten Zeile; Zeilen anderer Tage zur selben Uhrzeit koennen im Fenster stehen.',
                   $nb, $gw, $at) if $nb;
    return 'Tagesrekonstruktion: 0 Tagesgrenzen -- ein Abschnitt, Tag wie bisher aus --date (Ticker) / der letzten datierten Zeile ([fakepulse]).';
}

# plan_place_local($ts, $state) -- [fakepulse]-Uhrzeit (lokal) -> (Tag, Epoche)
sub plan_place_local {
    my ($ts, $state) = @_;
    return () unless $ts =~ /^([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?$/;
    my ($h, $m, $s, $frac) = ($1 + 0, $2 + 0, $3 + 0, defined $4 ? $4 + 0 : 0);
    my $ref = $state->{prev_abs};
    my $after = 1;
    if (!defined $ref) { $ref = $state->{plan}{first_tick_abs}; $after = 0; }
    return () unless defined $ref;
    my @r = localtime(POSIX::floor($ref));
    my $best;
    for my $d (-1, 0, 1) {
        my $e = POSIX::mktime($s, $m, $h, $r[3] + $d, $r[4], $r[5], 0, 0, -1);
        next unless defined $e;
        $e += $frac;
        if ($after) { $best = $e if $e >= $ref - $DAY_TOL && (!defined $best || $e < $best); }
        else        { $best = $e if $e <= $ref + $DAY_TOL && (!defined $best || $e > $best); }
    }
    return () unless defined $best;
    my ($day) = _local_day_ts($best);
    return ($day, $best);
}

# ---------------------------------------------------------------------------
# parse_line($source, $raw, $state) -- DIE EINZIGE Stelle, die einen
# Zeitstempel AUS einer Logzeile liest (Architekturvorgabe 1).
#
# $state traegt zwischen den Zeilen: curdate (fuer [fakepulse ...]-Zeilen,
# unveraendert), plus (84.1 plan 05) local_date/win_start/win_end -- feste
# Werte des ganzen Laufs, fuer resolve_dateless_utc() oben. [fakepulse ...]-
# Zeilen des Daemon-Logs tragen selbst KEIN Datum; ihr Kalendertag wird aus
# der letzten datierten Zeile davor MITGEFUEHRT und im Datensatz als
# day_derived=1 ausgewiesen (Regel 3). Die neuen datumslosen Ticker-Zeilen
# (HH:MM:SS.mmm L [f:N ...] ...) nutzen stattdessen resolve_dateless_utc()
# und sind ebenfalls day_derived=1.
#
# Rueckgabe: entweder { discard => <grund> } -- der Grund landet im
# Restzaehler, nie im Schweigen (Regel 2, Architekturvorgabe 4) -- oder ein
# vollstaendiger Datensatz.
# ---------------------------------------------------------------------------
sub parse_line {
    my ($source, $raw, $state) = @_;
    my ($ts, $day, $day_full, $derived);
    my $ts_src = 'local';   # WR-11 (84.1-REVIEW.md round 3): overridden 'utc' below

    if ($source eq 'server') {
        return { discard => 'no_ts' } if substr($raw, 0, 1) ne '[';
        my $cb = index($raw, ']');
        return { discard => 'unparsable_ts' } if $cb < 1;
        my @parts = split ' ', substr($raw, 1, $cb - 1);
        return { discard => 'unparsable_ts' } if @parts < 2;
        ($day, $ts)  = @parts[0, 1];
        $day_full    = $day;
        $derived     = 0;
    }
    elsif ($source eq 'daemon') {
        # 84-22 splice fix: Tagesabschnitt dieser Zeile (Zeilennummer gegen die Grenzen aus daemon_day_plan)
        my $plan = $state->{plan};
        if ($plan) {
            my $b = $plan->{bounds};
            $state->{gidx}++ while $state->{gidx} < @$b && $state->{lineno} >= $b->[ $state->{gidx} ];
        }
        if ($raw =~ /^[0-9]{4}-/) {
            $state->{curdate} = substr($raw, 0, 10);
            $day_full = $state->{curdate};
            $ts       = substr($raw, 11, 12);
            $derived  = 0;
            if ($plan) {   # a dated line is an absolute anchor for the [fakepulse] lines after it
                my ($Y, $Mo, $D) = ($day_full =~ /^([0-9]{4})-([0-9]{2})-([0-9]{2})$/);
                my ($h, $mi, $s, $fr) = ($ts =~ /^([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?/);
                if (defined $Y && defined $h) {
                    my $e = POSIX::mktime($s + 0, $mi + 0, $h + 0, $D + 0, $Mo - 1, $Y - 1900, 0, 0, -1);
                    $state->{prev_abs} = $e + (defined $fr ? $fr + 0 : 0) if defined $e;
                }
            }
        }
        elsif (substr($raw, 0, 11) eq '[fakepulse ') {
            if (substr($raw, 11, 9) eq 'BOUNDARY ') {
                my $p = index($raw, 'ts=');
                return { discard => 'unparsable_ts' } if $p < 0;
                $ts = substr($raw, $p + 3, 12);
            }
            else {
                $ts = substr($raw, 11, 12);
            }
            $day_full = $state->{curdate};
            $derived  = 1;
            if ($plan) {   # 84-22 splice fix: Tag aus der Chronologie statt aus der letzten datierten Zeile
                my ($d, $e) = plan_place_local($ts, $state);
                if (defined $d) { $day_full = $d; $state->{prev_abs} = $e; }
            }
        }
        elsif ($raw =~ /^\[([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?Z\s+[A-Z]+\s+[^\]]*\]/) {
            # 79-28 D-23: das librespot-Daemon-Log (<mac>-unified.log) -- "[YYYY-MM-DDTHH:MM:SS(.fff)Z LEVEL target]
            # text". Ein ABSOLUTER UTC-Anker MIT Datum: der Kalendertag ist der eigene der Zeile (day_derived=0),
            # die Umrechnung auf lokal laeuft ueber denselben einen Weg wie die datumslosen Soloist-Tickerzeilen
            # (_local_day_ts, Systemzeitzone inkl. Sommerzeit fuer genau dieses Datum); die Zeile wird beim Rendern
            # als [UTC->lokal ...] markiert (ts_src 'utc', Regel 3). Vorher: "andere Form", die ganze Quelle uebersprungen.
            my ($uY, $uMo, $uD, $uh, $umi, $us) = ($1, $2, $3, $4, $5, $6);
            my $ufr = defined $7 ? $7 + 0 : 0;
            my $uep = eval { timegm($us + 0, $umi + 0, $uh + 0, $uD + 0, $uMo - 1, $uY - 1900) };
            return { discard => 'unparsable_ts' } unless defined $uep;
            ($day_full, $ts) = _local_day_ts($uep + $ufr);
            $derived  = 0;
            $ts_src   = 'utc';
        }
        elsif ($raw =~ /^([0-9]{2}):([0-9]{2}):([0-9]{2})\.([0-9]{3})\s+[A-Za-z]\s+\[f:[0-9]+\s*\]/) {
            # 84.1 plan 05: neues, datumsloses Format des aktuellen Soloist-
            # Builds -- "HH:MM:SS.mmm <Level> [f:<N> ...] <message>" in UTC
            # (gemessen, siehe resolve_dateless_utc() oben). ANSI-Codes sind
            # bereits in scan_log() entfernt, bevor diese Zeile hier ankommt.
            my ($local_ts, $local_day_full);
            if ($plan) {   # 84-22 splice fix: UTC-Tag aus dem Tagesabschnitt (Ende-Anker), nicht aus --date
                my $ep = $plan->{base}[ $state->{gidx} ] + $1 * 3600 + $2 * 60 + $3 + $4 / 1000;
                ($local_day_full, $local_ts) = _local_day_ts($ep);
                $state->{prev_abs} = $ep;
            }
            else {
                ($local_ts, $local_day_full) = resolve_dateless_utc($1 + 0, $2 + 0, $3 + 0, $4, $state);
            }
            # WR-10 (84.1-REVIEW.md round 3): a distinct, loud discard
            # reason -- NOT 'unrecognized'. This branch already fully
            # recognised the line's format; it only failed to resolve a
            # calendar day, either because --date is absent (the common
            # case for current Soloist builds, whose ticker is entirely
            # dateless) or the rare DST-switch-moment edge case named in
            # resolve_dateless_utc()'s header comment. Lumping it into
            # 'unrecognized' buried real unrecognised lines under a
            # six-digit counter and broke the "andere Form" hint's own
            # claim that those lines carry no timestamp.
            return { discard => 'dateless_no_date' } unless defined $local_ts;
            $ts       = $local_ts;
            $day_full = $local_day_full;
            $derived  = 1;
            $ts_src   = 'utc';
        }
        else {
            # [fakepulse] ohne Zeitstempel (pa_stream_cork, TIMING, ...) und
            # alles andere: nicht fensterbar, aber existent -- gezaehlt,
            # nicht verschwiegen (N-WR-04).
            return { discard => (substr($raw, 0, 11) eq '[fakepulse]'
                                 ? 'no_ts_fakepulse' : 'unrecognized') };
        }
        $day = defined $day_full ? substr($day_full, 2, 8) : '?';
    }
    else {
        return { discard => 'unrecognized' };
    }

    my ($epoch, $strict) = parse_hms($ts);
    return { discard => 'unparsable_ts' } unless defined $epoch;

    my $stamp = ($source eq 'server')
              ? "$day $ts"
              : (defined $day_full ? "$day_full $ts" : "(Tag unbekannt) $ts");

    return {
        source      => $source,
        raw         => $raw,
        ts          => $ts,
        epoch       => $epoch,
        day         => $day,
        day_derived => $derived,
        ts_src      => $ts_src,
        stamp       => $stamp,
        ts_lenient  => ($strict ? 0 : 1),
        mac_class   => 'none',
        macs        => [],
        cats        => [],
        category    => undef,
    };
}

# ---------------------------------------------------------------------------
# scan_log -- EIN Durchlauf je Quelle. Erzeugt die Fensterdatensaetze, die
# Datei-Abdeckung und ALLE Restzaehler in einem Rutsch.
# ---------------------------------------------------------------------------
sub scan_log {
    my (%a) = @_;
    # 84.1 plan 05: das --date der lokale Fenstertag muss bis in parse_line()
    # durchgereicht werden -- resolve_dateless_utc() (unten) braucht ihn, um
    # den Kalendertag der neuen, datumslosen Daemon-Ticker-Zeilen zu
    # bestimmen (die im aktuellen Log fast nie eine eigene datierte Zeile
    # haben: 482882 von 489719 Daemon-Zeilen im 260928-Lauf sind das neue
    # Format). WR-09 (round 3): win_start/win_end werden hier NICHT mehr
    # gebraucht -- die Fensterpruefung bleibt allein bei scan_log selbst
    # (:655-662), resolve_dateless_utc() waehlt nur noch den Tag.
    my $state = { curdate => undef, local_date => $a{date},
                  plan => $a{day_plan}, lineno => 0, gidx => 0, prev_abs => undef };   # 84-22 splice fix
    my %agg = (
        lines => 0, bytes => 0,
        no_ts => 0, no_ts_fakepulse => 0, unrecognized => 0, unparsable_ts => 0,
        dateless_no_date => 0,
        lenient_ts => 0, timestamped => 0, outside => 0, day_filtered => 0,
        first => undef, last => undef, dmin => undef, dmax => undef, seen => 0,
    );
    my @win;
    my @attach;
    my $fh = $a{fh};

    while (defined(my $line = <$fh>)) {
        $agg{bytes} += length $line;
        $line =~ s/\n\z//;   # NUR der Zeilenumbruch -- ein \r im Log ist Teil der Rohzeile
        # 84.1 plan 05: der aktuelle Soloist-Build faerbt seine Ticker-/
        # Log-Ausgabe mit ANSI-Codes (fuehrend bei Fehlerzeilen, stets ein
        # abschliessendes ESC[0m) -- vor JEDEM Parsen/Kategorisieren
        # entfernen, sonst reisst das \e[...m die Zeitstempel- und
        # Kategorie-Muster auseinander. Nur fuer den Daemon-Kanal; server.log
        # traegt keine ANSI-Codes.
        $line =~ s/\x1b\[[0-9;]*m//g if $a{source} eq 'daemon';
        $agg{lines}++;
        $state->{lineno} = $agg{lines};   # 84-22 splice fix: same numbering as daemon_day_plan()

        my $r = parse_line($a{source}, $line, $state);
        if ($r->{discard}) { $agg{ $r->{discard} }++; next; }

        $agg{timestamped}++;
        $agg{lenient_ts}++ if $r->{ts_lenient};
        $agg{first} = $r->{stamp} unless defined $agg{first};
        $agg{last}  = $r->{stamp};

        # Tagesbezug: ein unbekannter Tag ("?") wird NICHT stumm weggefiltert
        # -- er wird unten laut benannt (Regel 2).
        my $day_ok = (!$a{date_short} || $r->{day} eq $a{date_short} || $r->{day} eq '?');
        if ($day_ok) {
            $agg{seen}++;
            $agg{dmin} = $r->{epoch} if !defined $agg{dmin} || $r->{epoch} < $agg{dmin};
            $agg{dmax} = $r->{epoch} if !defined $agg{dmax} || $r->{epoch} > $agg{dmax};
            # Zeitbasis-Selbsttest: ALLE client-attach der Quelle, bewusst
            # OHNE Fensterfilter -- sonst kann ein Stundenversatz gar nicht
            # sichtbar werden.
            if ($a{source} eq 'daemon'
                && index($r->{raw}, 'client-attach: new /stream client fd=') >= 0) {
                # WR-06: der Kalendertag MUSS mitreisen -- ohne --date stehen
                # hier Zeilen mehrerer Tage, und emit_timebase darf ein GET
                # von heute nicht mit einem attach von gestern paaren.
                push @attach, { epoch => $r->{epoch}, ts => $r->{ts}, day => $r->{day} };
            }
        }

        if ($r->{epoch} < $a{win_start} || $r->{epoch} > $a{win_end}) {
            $agg{outside}++;
            next;
        }
        if ($a{date_short} && $r->{day} ne '?' && $r->{day} ne $a{date_short}) {
            $agg{day_filtered}++;
            next;
        }

        # MAC-Klasse nur fuer Fensterzeilen (die anderen werden nie gerendert).
        ($r->{mac_class}, $r->{macs}) = classify_mac($line, $a{mac_lower});
        $r->{idx} = scalar @win;   # Datei-Reihenfolge, fuer die stabile Sortierung
        push @win, $r;
    }

    return (\@win, \%agg, \@attach);
}

# ---------------------------------------------------------------------------
# classify_records -- Kategoriezuordnung EINMAL je Datensatz. Mehrfach-
# mitgliedschaft ist zugelassen (eine Zeile kann in zwei Kategorien stehen);
# "nicht kategorisiert" heisst: in keiner.
# ---------------------------------------------------------------------------
sub classify_records {
    my ($recs, $cats, $extra) = @_;
    for my $r (@$recs) {
        my (@hit, @noise);
        for my $c (@$cats) { push @hit, $c->{name} if $r->{raw} =~ $c->{pat}; }
        if ($extra) {
            for my $e (@$extra) { push @noise, $e->{name} if $r->{raw} =~ $e->{pat}; }
        }
        # cats = Signalkategorien (sie entscheiden den "keine Signalzeile"-Banner),
        # noise = Rauschkategorien (underflow/write_summary). "Nicht
        # kategorisiert" heisst: in keiner von beiden.
        $r->{cats}     = \@hit;
        $r->{noise}    = \@noise;
        $r->{category} = @hit ? $hit[0] : $noise[0];
    }
    return;
}

sub in_cat {
    my ($r, $name) = @_;
    for my $c (@{ $r->{cats} }) { return 1 if $c eq $name; }
    return 0;
}

# ---------------------------------------------------------------------------
# render_record -- die EINZIGE Stelle, an der ein Datensatz zu einer
# menschenlesbaren Zeile wird (Architekturvorgabe 2). Alle Annotationen
# entstehen hier, aus Feldern -- kein Code liest je eine gerenderte Zeile
# zurueck.
# ---------------------------------------------------------------------------
sub render_record {
    my ($r, $mark_day) = @_;
    my $out = $r->{raw};
    # WR-11 (84.1-REVIEW.md round 3): a converted line carries a UTC clock
    # inside a block whose header/window/every other line are local time
    # (Regel 3, "jede Zeile traegt Quelle und Zeitbasis") -- mark it, with
    # the ALREADY-converted local ts, so a reader never has to do the +2h/+1h
    # arithmetic by eye next to unconverted [fakepulse ...] lines.
    if ($r->{source} eq 'daemon' && ($r->{ts_src} // 'local') eq 'utc') {
        $out = '[UTC->lokal ' . $r->{ts} . '] ' . $out;
    }
    if ($mark_day && $r->{source} eq 'daemon') {
        $out = '[TAG ' . $r->{day} . ($r->{day_derived} ? ' abgeleitet' : '') . '] ' . $out;
    }
    if ($r->{mac_class} eq 'foreign') {
        $out = '[ANDERE MAC: ' . join(',', @{ $r->{macs} }) . '] ' . $out;
    }
    return $out;
}

# ---------------------------------------------------------------------------
# Unterprozesse: kein Shell-Aufruf, nur exec-Listenform.
# ---------------------------------------------------------------------------
sub run_quiet {
    my (@cmd) = @_;
    my $pid = fork();
    return 0 unless defined $pid;
    if ($pid == 0) {
        open(STDOUT, '>', '/dev/null');
        open(STDERR, '>', '/dev/null');
        exec(@cmd) or exit 127;
    }
    waitpid($pid, 0);
    return ($? == 0) ? 1 : 0;
}

sub capture_quiet {
    my (@cmd) = @_;
    my $pid = open(my $fh, '-|');
    return (undef, -1) unless defined $pid;
    if ($pid == 0) {
        open(STDERR, '>', '/dev/null');
        exec(@cmd) or exit 127;
    }
    local $/ = undef;
    my $out = <$fh>;
    close $fh;
    return ($out, $?);
}

sub open_pipe_quiet {
    my (@cmd) = @_;
    my $pid = open(my $fh, '-|');
    return (undef, undef) unless defined $pid;
    if ($pid == 0) {
        open(STDERR, '>', '/dev/null');
        exec(@cmd) or exit 127;
    }
    return ($fh, $pid);
}

# ---------------------------------------------------------------------------
# records_with($recs, $needle) -- alle Datensaetze, deren ROHTEXT das
# Teilstueck enthaelt. Bewusst ueber $r->{raw}, nie ueber eine gerenderte
# Zeile: genau dieser Rueckgriff auf gerenderten Text war N-CR-01.
# ---------------------------------------------------------------------------
sub records_with {
    my ($recs, $needle) = @_;
    return [ grep { index($_->{raw}, $needle) >= 0 } @$recs ];
}

# ---------------------------------------------------------------------------
# select_record -- DIE EINZIGE Auswahl-/Paarungsroutine (Architekturvorgabe 3).
#
# Argumente: records, center, span, mode ('nearest'|'after'), bracket (0|1)
# Rueckgabe: Hashref mit BENANNTEN Feldern -- kein Positionsprotokoll, damit
# ein verschobener Feldindex (N-WR-01) strukturell unmoeglich wird.
#
#   status      ok | ambig | bracketed | outside | noafter | foreign | none
#   ts, epoch   der gewaehlte Datensatz
#   in_span     Anzahl Kandidaten in der Spanne (Modus 'after': ab dem Anker)
#   before_n / after_n / before_ts / after_ts / before_d / after_d
#   before_list Liste der Vorkommen DAVOR (Modus 'after', "nicht gepaart")
#   nearest_ts / nearest_d   naechstes Vorkommen ueberhaupt (ohne Spanne)
#   tie_ts      zweiter, gleich weit entfernter Kandidat (Status ambig)
#   foreign_n   Vorkommen, die NUR eine andere MAC tragen
#   total_ok    Vorkommen mit eigener oder ohne MAC
#
# 'bracketed' (N-CR-02): liegt je ein Kandidat VOR und NACH dem Anker
# innerhalb der Spanne, ist die Reihenfolge nicht entscheidbar. Dann wird
# KEIN Delta gebildet und beide Kandidaten werden genannt.
# ---------------------------------------------------------------------------
sub select_record {
    my (%a) = @_;
    my $span = $a{span};
    my $c    = $a{center};

    my @ok;
    my $foreign = 0;
    my $otherday = 0;
    my %otherdays;
    for my $r (@{ $a{records} }) {
        if ($r->{mac_class} eq 'foreign') { $foreign++; next; }
        # Tageswaechter: ein Partner darf nur aus DEMSELBEN Kalendertag wie
        # der Anker stammen. Die Epoche ist eine Tageszeit -- ohne diesen
        # Filter wuerde ein Vorgang des Vortages mit einem des heutigen Tages
        # zu einem Paar verrechnet, das es nie gab (Regel 3).
        if (defined $a{day} && $r->{day} ne $a{day}) {
            $otherday++;
            $otherdays{ $r->{day} } = 1;
            next;
        }
        push @ok, $r;
    }

    my %res = (
        status      => 'none',
        foreign_n   => $foreign,
        otherday_n  => $otherday,
        otherdays   => [ sort keys %otherdays ],
        total_ok    => scalar @ok,
        in_span     => 0,
        before_n    => 0,
        after_n     => 0,
        before_list => [],
    );
    if (!@ok) {
        $res{status} = $foreign > 0 ? 'foreign' : 'none';
        return \%res;
    }

    my ($nearest, $neard);
    my ($bef, $befd, $aft, $aftd);
    my ($best, $bestd, $tie_ts);
    my @before_list;
    my %spanday;

    for my $r (@ok) {
        my $d  = $r->{epoch} - $c;
        my $ad = $d < 0 ? -$d : $d;

        if (!defined $neard || $ad < $neard) { $neard = $ad; $nearest = $r; }

        # Seitenzuordnung: "auf dem Anker" (bis 0.5 ms) zaehlt als DANACH,
        # damit ein zeitgleiches Paar nicht als eingerahmt gilt.
        if ($d >= -0.0005 && $ad <= $span) {
            $res{after_n}++;
            if (!defined $aftd || $d < $aftd) { $aftd = $d; $aft = $r; }
        }
        elsif ($d < 0 && $ad <= $span) {
            $res{before_n}++;
            push @before_list, '@' . $r->{ts};
            if (!defined $befd || $ad < $befd) { $befd = $ad; $bef = $r; }
        }

        next if $ad > $span;
        $spanday{ $r->{day} } = $r->{ts} unless exists $spanday{ $r->{day} };
        if ($a{mode} eq 'nearest') {
            $res{in_span}++;
            if (!defined $bestd || $ad < $bestd - $EPS) {
                $bestd = $ad; $best = $r; $tie_ts = undef;
            }
            elsif ($ad < $bestd + $EPS && $r->{ts} ne $best->{ts}) {
                $tie_ts = $r->{ts};
            }
        }
    }

    $res{nearest_ts} = $nearest->{ts};
    $res{nearest_d}  = $neard;
    $res{before_list} = \@before_list;
    if (defined $bef) { $res{before_ts} = $bef->{ts}; $res{before_d} = $befd; }
    if (defined $aft) { $res{after_ts}  = $aft->{ts};  $res{after_d}  = $aftd; }

    if ($a{mode} eq 'after') {
        $res{in_span} = $res{after_n};
        if ($res{after_n} == 0) {
            $res{status} = 'noafter';
            return \%res;
        }
        $res{status} = 'ok';
        $res{ts}     = $aft->{ts};
        $res{epoch}  = $aft->{epoch};
        $res{day}    = $aft->{day};
        return \%res;
    }

    # Modus 'nearest'
    if ($res{in_span} == 0) {
        $res{status} = 'outside';
        return \%res;
    }
    if (!defined $a{day} && keys(%spanday) > 1) {
        # Mehrere Kalendertage in der Spanne: welcher Vorgang gemeint ist,
        # ist ohne --date nicht entscheidbar (Regel 3).
        $res{status} = 'multiday';
        $res{days}   = join(', ', map { "$_ @" . $spanday{$_} } sort keys %spanday);
        return \%res;
    }
    if ($a{bracket} && $res{before_n} > 0 && $res{after_n} > 0) {
        $res{status} = 'bracketed';
        return \%res;
    }
    if (defined $tie_ts) {
        $res{status} = 'ambig';
        $res{ts}     = $best->{ts};
        $res{epoch}  = $best->{epoch};
        $res{day}    = $best->{day};
        $res{tie_ts} = $tie_ts;
        return \%res;
    }
    $res{status} = 'ok';
    $res{ts}     = $best->{ts};
    $res{epoch}  = $best->{epoch};
    $res{day}    = $best->{day};
    return \%res;
}

# ---------------------------------------------------------------------------
# side_status -- Kurzform des Zustands EINER Seite. Damit bei einem
# ausgefallenen Delta nie nur eine Seite genannt wird (WR-07).
# ---------------------------------------------------------------------------
sub side_status {
    my ($label, $recs, $t1) = @_;
    my $s = select_record(records => $recs, center => $t1, span => $PAIR_SPAN,
                          mode => 'nearest', bracket => 0);
    return sprintf('%s: %s Vorkommen im Fenster T1+/-%ss (naechstes @%s)',
                   $label, $s->{in_span}, $PAIR_SPAN, $s->{ts})
        if $s->{status} eq 'ok';
    return sprintf('%s: zwei gleich weit von T1 entfernte Vorkommen (@%s, @%s)',
                   $label, $s->{ts}, $s->{tie_ts})
        if $s->{status} eq 'ambig';
    return sprintf('%s: %s Vorkommen im Fenster T1+/-%ss, davon %s DAVOR (naechstes @%s) und %s DANACH (naechstes @%s) -- Reihenfolge nicht entscheidbar',
                   $label, $s->{in_span}, $PAIR_SPAN, $s->{before_n}, $s->{before_ts},
                   $s->{after_n}, $s->{after_ts})
        if $s->{status} eq 'bracketed';
    return sprintf('%s: Vorkommen aus mehreren Kalendertagen im Fenster T1+/-%ss (%s) -- ohne --date nicht zuordenbar',
                   $label, $PAIR_SPAN, $s->{days})
        if $s->{status} eq 'multiday';
    return sprintf('%s: kein Vorkommen im Fenster T1+/-%ss; naechstes @%s, %.3fs ausserhalb',
                   $label, $PAIR_SPAN, $s->{nearest_ts}, $s->{nearest_d})
        if $s->{status} eq 'outside';
    return sprintf('%s: nur %s Vorkommen mit ANDERER MAC -- fuer diese MAC nicht gefunden (NICHT "nicht vorhanden")',
                   $label, $s->{foreign_n})
        if $s->{status} eq 'foreign';
    return sprintf('%s: im Fenster T0-2s..T1+5s nicht gefunden', $label);
}

# ---------------------------------------------------------------------------
# emit_delta -- ein abgeleitetes Feld ausgeben. Kein Verdikt (Regel 1): nur
# eine Zeitstempel-Differenz, als [ABGELEITET, NICHT GEMESSEN] markiert.
# ---------------------------------------------------------------------------
sub emit_delta {
    my (%a) = @_;
    my $out    = $a{out};
    my $t1     = $a{t1};
    my $alabel = $a{alabel};
    my $plabel = $a{plabel};

    my $anchor = select_record(records => $a{arecs}, center => $t1,
                               span => $PAIR_SPAN, mode => 'nearest', bracket => 0);

    if ($anchor->{status} ne 'ok') {
        my $reason;
        if ($anchor->{status} eq 'ambig') {
            $reason = sprintf('Anker mehrdeutig: zwei gleich weit von T1 entfernte %s (@%s, @%s) -- Zuordnung nicht entscheidbar, deshalb KEIN Delta',
                              $alabel, $anchor->{ts}, $anchor->{tie_ts});
        }
        elsif ($anchor->{status} eq 'multiday') {
            $reason = sprintf('Anker aus mehreren Kalendertagen: %s im Fenster T1+/-%ss stammen aus verschiedenen Tagen (%s). Welcher Vorgang gemeint ist, ist ohne --date NICHT entscheidbar, deshalb KEIN Delta',
                              $alabel, $PAIR_SPAN, $anchor->{days});
        }
        elsif ($anchor->{status} eq 'outside') {
            $reason = sprintf('kein %s im Fenster T1+/-%ss (naechstes Vorkommen @%s, %.3fs ausserhalb -- gehoert zu einem anderen Vorgang)',
                              $alabel, $PAIR_SPAN, $anchor->{nearest_ts}, $anchor->{nearest_d});
        }
        elsif ($anchor->{status} eq 'foreign') {
            $reason = sprintf("%s: nur %s Vorkommen mit ANDERER MAC gefunden -- fuer diese MAC nicht gefunden, NICHT als 'nicht vorhanden' lesen",
                              $alabel, $anchor->{foreign_n});
        }
        else {
            $reason = sprintf('%s im Fenster T0-2s..T1+5s nicht gefunden', $alabel);
        }
        push @$out, sprintf('[ABGELEITET] Delta(%s -> %s): kein Wert -- %s. %s',
                            $alabel, $plabel, $reason,
                            side_status($plabel, $a{precs}, $t1));
        return;
    }

    my $partner = select_record(
        records => $a{precs}, center => $anchor->{epoch}, span => $PAIR_SPAN,
        mode    => ($a{mode} eq 'after' ? 'after' : 'nearest'),
        bracket => ($a{mode} eq 'after' ? 0 : 1),
        day     => $anchor->{day},
    );

    if ($partner->{status} ne 'ok') {
        my $reason;
        if ($partner->{status} eq 'bracketed') {
            # N-CR-02: lieber kein Delta als eines, dessen Vorzeichen an
            # wenigen Millisekunden eines unbeteiligten Ereignisses haengt.
            $reason = sprintf('Anker ist EINGERAHMT -- je ein %s DAVOR (@%s, %.4fs davor) und DANACH (@%s, %.4fs danach) innerhalb %ss. Welcher zum selben Vorgang gehoert, ist aus den Zeitstempeln allein NICHT entscheidbar; deshalb kein Delta und keine Reihenfolgeaussage (%s %s innerhalb %ss um den Anker)',
                              $plabel, $partner->{before_ts}, $partner->{before_d},
                              $partner->{after_ts}, $partner->{after_d}, $PAIR_SPAN,
                              $partner->{in_span}, $plabel, $PAIR_SPAN);
        }
        elsif ($partner->{status} eq 'ambig') {
            $reason = sprintf('Partner mehrdeutig: zwei gleich weit vom Anker entfernte %s (@%s, @%s) -- Zuordnung nicht entscheidbar, deshalb KEIN Delta',
                              $plabel, $partner->{ts}, $partner->{tie_ts});
        }
        elsif ($partner->{status} eq 'outside') {
            $reason = sprintf('kein %s innerhalb %ss um %s @%s (naechstes @%s, %.3fs entfernt)',
                              $plabel, $PAIR_SPAN, $alabel, $anchor->{ts},
                              $partner->{nearest_ts}, $partner->{nearest_d});
        }
        elsif ($partner->{status} eq 'noafter') {
            my $bef = @{ $partner->{before_list} }
                    ? sprintf(' (im selben Abstand DAVOR: %s)', join(', ', @{ $partner->{before_list} }))
                    : '';
            $reason = sprintf('kein %s innerhalb %ss NACH %s @%s gefunden%s',
                              $plabel, $PAIR_SPAN, $alabel, $anchor->{ts}, $bef);
        }
        elsif ($partner->{status} eq 'foreign') {
            $reason = sprintf('%s: nur %s Vorkommen mit ANDERER MAC gefunden',
                              $plabel, $partner->{foreign_n});
        }
        else {
            $reason = sprintf('%s im Fenster T0-2s..T1+5s nicht gefunden', $plabel);
        }
        $reason .= sprintf('; %d %s aus anderen Kalendertagen (%s) waren als Partner nicht zugelassen',
                           $partner->{otherday_n}, $plabel, join(', ', @{ $partner->{otherdays} }))
            if $partner->{otherday_n} > 0;
        push @$out, sprintf('[ABGELEITET] Delta(%s @%s -> %s): kein Wert -- %s',
                            $alabel, $anchor->{ts}, $plabel, $reason);
        return;
    }

    my $extras = '';
    $extras .= sprintf(' (%s %s im Fenster T1+/-%ss, das zu T1 naechste als Anker gewaehlt)',
                       $anchor->{in_span}, $alabel, $PAIR_SPAN) if $anchor->{in_span} > 1;
    if ($a{mode} eq 'after') {
        $extras .= sprintf(' (zusaetzlich %s DAVOR innerhalb %ss: %s -- nicht gepaart)',
                           $plabel, $PAIR_SPAN, join(', ', @{ $partner->{before_list} }))
            if @{ $partner->{before_list} };
        $extras .= sprintf(' (%s %s nach dem Anker, das erste gepaart)',
                           $partner->{in_span}, $plabel) if $partner->{in_span} > 1;
    }
    else {
        $extras .= sprintf(' (%s %s innerhalb %ss um den Anker, das naechste gepaart)',
                           $partner->{in_span}, $plabel, $PAIR_SPAN) if $partner->{in_span} > 1;
    }

    $extras .= sprintf(' (%d %s aus anderen Kalendertagen (%s) nicht als Partner zugelassen)',
                       $partner->{otherday_n}, $plabel, join(', ', @{ $partner->{otherdays} }))
        if $partner->{otherday_n} > 0;

    my $d = $partner->{epoch} - $anchor->{epoch};
    my $ordertext = '';
    if ($a{mode} ne 'after') {
        if ($anchor->{epoch} > $partner->{epoch}) {
            $ordertext = sprintf(' -- %s liegt NACH dem gepaarten %s', $alabel, $plabel);
        }
        elsif ($anchor->{epoch} < $partner->{epoch}) {
            $ordertext = sprintf(' -- %s liegt VOR dem gepaarten %s', $alabel, $plabel);
        }
        else {
            $ordertext = sprintf(' -- %s und %s tragen denselben Zeitstempel', $alabel, $plabel);
        }
    }
    push @$out, sprintf('[ABGELEITET, NICHT GEMESSEN] Delta(%s @%s -> %s @%s) = %.4fs%s%s%s',
                        $alabel, $anchor->{ts}, $plabel, $partner->{ts},
                        $d, $ordertext, $a{note}, $extras);
    return;
}

# ---------------------------------------------------------------------------
# report_coverage -- Abdeckung je Quelle. Eine 0-Byte-Datei und eine Datei,
# deren Zeilen alle nach dem Fensterende liegen, duerfen nicht aussehen wie
# "Quelle vollstaendig, aber im Fenster nichts gefunden" (Regel 4).
# ---------------------------------------------------------------------------
sub report_coverage {
    my ($out, $label, $agg, $c) = @_;

    if ($label eq 'server.log' && $agg->{no_ts} > 0) {
        push @$out, sprintf('Hinweis %s: %d Fortsetzungszeile(n) ohne eigenen Zeitstempel (HTTP-Header, Backtraces) uebersprungen -- sie sind keinem Zeitfenster zuzuordnen.',
                            $label, $agg->{no_ts});
    }
    # N-WR-04: das Daemon-Gegenstueck. [fakepulse] ohne Zeitstempel
    # (pa_stream_cork, TIMING, constructor, ...) ist nicht fensterbar, aber
    # existent -- und teils inhaltlich einschlaegig.
    if ($label eq 'Daemon-Log') {
        my $n = $agg->{no_ts_fakepulse} + $agg->{unrecognized};
        if ($n > 0) {
            push @$out, sprintf('Hinweis %s: %d Zeile(n) ohne eigenen Zeitstempel ([fakepulse] ohne ts: %d, andere Form: %d) uebersprungen -- sie sind keinem Zeitfenster zuzuordnen und in der Fensterzahl unten NICHT enthalten.',
                                $label, $n, $agg->{no_ts_fakepulse}, $agg->{unrecognized});
        }
        # WR-10 (84.1-REVIEW.md round 3): these lines carry their OWN
        # timestamp (UTC) and ARE fully recognised -- they are missing from
        # the window purely because --date was not given, so this gets its
        # own loud line rather than hiding inside the "andere Form" count
        # above (which is now for genuinely unrecognised lines only).
        if ($agg->{dateless_no_date} > 0) {
            push @$out, sprintf('!! %s: %d datumslose UTC-Tickerzeile(n) des aktuellen Soloist-Builds konnten OHNE --date keinem Kalendertag zugeordnet werden und fehlen im Fenster -- mit --date YYYY-MM-DD wiederholen.',
                                $label, $agg->{dateless_no_date});
        }
    }

    if (($agg->{seen} || 0) == 0) {
        if ($c->{date_short}) {
            push @$out, sprintf("!! Abdeckung %s: KEINE Zeile vom %s in dieser Quelle (Datei-Abdeckung: %s .. %s). Das Fenster ist damit fuer diese Quelle NICHT GEPRUEFT -- 'nichts gefunden' heisst hier 'nicht protokolliert', nicht 'nicht passiert'.",
                                $label, $c->{date},
                                defined $agg->{first} ? $agg->{first} : 'keine Zeitstempelzeile',
                                defined $agg->{last}  ? $agg->{last}  : 'keine Zeitstempelzeile');
        }
        else {
            push @$out, sprintf('!! Abdeckung %s: keine auswertbare Zeitstempelzeile gefunden (Datei-Abdeckung: %s .. %s).',
                                $label,
                                defined $agg->{first} ? $agg->{first} : 'keine',
                                defined $agg->{last}  ? $agg->{last}  : 'keine');
        }
        return;
    }

    my $daynote = $c->{date_short}
        ? sprintf('; am %s von %s bis %s', $c->{date}, fmt_hms($agg->{dmin}), fmt_hms($agg->{dmax}))
        : '';
    push @$out, sprintf('Abdeckung %s: erste Zeile @%s .. letzte Zeile @%s%s',
                        $label, $agg->{first}, $agg->{last}, $daynote);

    if ($agg->{dmax} < $c->{win_start}) {
        push @$out, sprintf("!! %s deckt das Fenster NICHT ab: die Quelle endet bei %s und damit VOR dem Fensteranfang %s. Ein leerer Abschnitt bedeutet hier 'nicht protokolliert', NICHT 'nicht passiert'.",
                            $label, fmt_hms($agg->{dmax}), fmt_hms($c->{win_start}));
    }
    elsif ($agg->{dmin} > $c->{win_end}) {
        push @$out, sprintf("!! %s deckt das Fenster NICHT ab: die Quelle beginnt erst bei %s und damit NACH dem Fensterende %s. Ein leerer Abschnitt bedeutet hier 'nicht protokolliert', NICHT 'nicht passiert'.",
                            $label, fmt_hms($agg->{dmin}), fmt_hms($c->{win_end}));
    }
    return;
}

# ---------------------------------------------------------------------------
# mac_mix_note -- WR-05: die Zahl "davon N in T1+/-3s" wandert von Hand in
# eine Handtabellenspalte EINES Spielers (G4: "noteSeekIntent (Anzahl)").
# server.log ist aber die gemeinsame Quelle BEIDER Spieler dieses Rigs: ein
# Seek des anderen Spielers innerhalb T1+/-3s ergibt dieselbe "2" wie ein
# echter Doppel-Seek. Darum traegt die Kopfzeile die Aufschluesselung nach
# mac_class -- aber NUR, wenn sie etwas unterscheidet (Regel 3 schuetzt vor
# Mehrdeutigkeit, nicht vor Kuerze; vier Zahlen an jeder Kategorie waeren
# selbst Rauschen und wuerden das Signal begraben):
#
#   * alle nahen Zeilen 'own'  -> die Zahl IST die Zahl dieses Spielers,
#                                 kein Zusatz.
#   * alle nahen Zeilen 'none' UND die Kategorie traegt NIE eine MAC
#                              -> der bestehende Hinweis "%d von %d Zeilen
#                                 tragen KEINE MAC ... sie zaehlen ueber alle
#                                 Spieler" gilt dann fuer jede Teilzaehlung,
#                                 also auch fuer diese; kein Zusatz.
#   * sonst (fremde MAC dabei, oder gemischte Klassen, bei denen der
#     Kategoriehinweis die nahe Teilmenge NICHT festlegt)
#                              -> lauter Zusatz mit der Aufschluesselung.
#
# Es wird KEINE Zahl als "die des Spielers" behauptet, die das nicht ist:
# ohne-MAC-Zeilen sind nicht zuordenbar, deshalb wird in diesem Fall eine
# Spanne genannt (own .. own+none) statt eines Wertes (Regel 1/3).
#
# Nur fuer Quellen mit MAC-Klassifikation (mac_note, d.h. server.log). Das
# Daemon-Log ist ueber den Dateipfad <mac>-soloist.log je Spieler getrennt --
# dort ist "ohne MAC" kein Zuordnungsproblem.
# ---------------------------------------------------------------------------
sub mac_mix_note {
    my ($near, $nomac_cat, $cnt) = @_;
    my $tot = scalar @$near;
    return '' if $tot == 0;
    my %n = (own => 0, foreign => 0, none => 0);
    $n{ $_->{mac_class} }++ for @$near;
    return '' if $n{own}  == $tot;                          # reine eigene MAC
    return '' if $n{none} == $tot && $nomac_cat == $cnt;     # Kategorie traegt nie eine MAC
    my %fm;
    for my $r (@$near) {
        next unless $r->{mac_class} eq 'foreign';
        $fm{$_} = 1 for @{ $r->{macs} || [] };
    }
    my $fl = %fm ? sprintf(' (%s)', join(',', sort keys %fm)) : '';
    return sprintf(' -- GEMISCHTE ZAEHLUNG, diese %d ist NICHT die Zahl dieses Spielers: eigene MAC %d, ANDERE MAC %d%s, ohne MAC %d; die Zahl dieses Spielers liegt zwischen %d und %d -- ohne-MAC-Zeilen sind nicht zuordenbar',
                   $tot, $n{own}, $n{foreign}, $fl, $n{none},
                   $n{own}, $n{own} + $n{none})
        if $n{none} > 0;
    return sprintf(' -- GEMISCHTE ZAEHLUNG, diese %d ist NICHT die Zahl dieses Spielers: eigene MAC %d, ANDERE MAC %d%s; fuer eine Handtabellenspalte dieses Spielers zaehlt %d',
                   $tot, $n{own}, $n{foreign}, $fl, $n{own});
}

# ---------------------------------------------------------------------------
# emit_categories -- Kategorieblöcke einer Quelle. Alle Annotationen
# entstehen hier beim Rendern, aus Datensatzfeldern.
# ---------------------------------------------------------------------------
sub emit_categories {
    my (%a) = @_;
    my $out = $a{out};
    for my $cat (@{ $a{cats} }) {
        my @m = grep { in_cat($_, $cat->{name}) } @{ $a{recs} };
        if (!@m) {
            push @$out, "--- $cat->{name} ---";
            push @$out, "[MUSTER NICHT GEFUNDEN IM FENSTER] $cat->{name}";
            push @$out, '';
            next;
        }
        my $cnt = scalar @m;
        my $nomac = grep { $_->{mac_class} eq 'none' } @m;
        my $hdr = "--- $cat->{name}";
        if ($cat->{count}) {
            my @near = grep { abs($_->{epoch} - $a{t1}) <= $PAIR_SPAN } @m;
            $hdr .= sprintf(' (Anzahl: %d im Fenster %s..%s; davon %d in T1+/-%ss%s)',
                            $cnt, fmt_hms($a{win_start}), fmt_hms($a{win_end}),
                            scalar @near, $PAIR_SPAN,
                            $a{mac_note} ? mac_mix_note(\@near, $nomac, $cnt) : '');
        }
        if ($a{mac_note}) {
            $hdr .= sprintf(' [%d von %d Zeilen tragen KEINE MAC -- fuer sie ist die [ANDERE MAC]-Markierung strukturell unmoeglich, sie zaehlen ueber alle Spieler]',
                            $nomac, $cnt) if $nomac > 0;
        }
        push @$out, "$hdr ---";
        push @$out, render_record($_, $a{mark_day}) for @m;
        push @$out, '';
    }
    return;
}

# ---------------------------------------------------------------------------
# emit_window_gate -- Fenster-Tor: liegt im Fenster ein _Stop aus
# PLAYING-STREAMING? Beschreibend, ohne Verdikt (WR-04).
# ---------------------------------------------------------------------------
sub emit_window_gate {
    my ($out, $recs, $mac_lower) = @_;
    my @lines;
    for my $r (@$recs) {
        next unless $r->{raw} =~ /Stop in ([A-Z-]+) -> .*::_Stop/;
        my $state = $1;
        my $macnote = $r->{mac_class} eq 'own'
            ? "MAC $mac_lower"
            : ($r->{mac_class} eq 'foreign'
               ? sprintf('MAC %s -- ANDERE MAC, nicht %s', join(',', @{ $r->{macs} }), $mac_lower)
               : 'Zeile ohne MAC -- nicht zuordenbar');
        if ($state eq 'PLAYING-STREAMING') {
            push @lines, sprintf('[Fenster-Tor] _Stop aus PLAYING-STREAMING gefunden @%s (%s)',
                                 $r->{ts}, $macnote);
        }
        else {
            push @lines, sprintf('[Fenster-Tor] _Stop aus %s gefunden @%s (%s) -- nicht PLAYING-STREAMING',
                                 $state, $r->{ts}, $macnote);
        }
    }
    push @lines, '[Fenster-Tor] KEIN _Stop-UEBERGANG IM FENSTER GEFUNDEN' unless @lines;
    push @$out, '--- Fenster-Tor-Klassifikation (abgeleitet, kein Verdikt) ---', @lines, '';
    return;
}

# ---------------------------------------------------------------------------
# emit_underflow -- Rauschunterdrueckung: nie einzeln, es sei denn --full.
# ---------------------------------------------------------------------------
sub emit_underflow {
    my ($out, $recs, $full, $mark_day) = @_;
    my @m = grep { $_->{raw} =~ $UNDERFLOW_PAT } @$recs;
    push @$out, '--- Daemon-Log: underflow ---';
    if (!@m) {
        push @$out, '[MUSTER NICHT GEFUNDEN IM FENSTER] underflow';
    }
    elsif ($full) {
        push @$out, render_record($_, $mark_day) for @m;
    }
    else {
        push @$out, sprintf('[underflow] %dx zusammengefasst, erste @%s, letzte @%s',
                            scalar @m, $m[0]{ts}, $m[-1]{ts});
    }
    push @$out, '';
    return scalar @m;
}

# ---------------------------------------------------------------------------
# emit_write_summary -- innerhalb +/-PAIR_SPAN um T0 UND um T1 vollstaendig,
# dazwischen zusammengefasst MIT den Extremwertzeilen wortwoertlich (WR-09):
# ring_fill/bytes_written werden in Handtabellen zitiert, eine reine Zaehlung
# wuerde zitierte Zahlen vernichten. Mit --full gar nichts gekuerzt.
# ---------------------------------------------------------------------------
sub emit_write_summary {
    my (%a) = @_;
    my $out = $a{out};
    push @$out, '--- Daemon-Log: write_summary (letzte Kategorie -- Rauschunterdrueckung, s.u.) ---';
    my @ws = grep { $_->{raw} =~ $WRITE_SUM_PAT } @{ $a{recs} };
    if (!@ws) {
        push @$out, '[MUSTER NICHT GEFUNDEN IM FENSTER] write_summary';
        push @$out, '';
        return 0;
    }

    my %m;
    my $flush_mid = sub {
        return unless $m{n};
        my $inc = ($m{blast} || 0) - ($m{bfirst} || 0);
        push @$out, sprintf('[ZUSAMMENGEFASST -- %d write_summary-Zeile(n) zwischen @%s und @%s nicht einzeln aufgefuehrt; mit --full vollstaendig]',
                            $m{n}, $m{tsfirst}, $m{tslast});
        push @$out, sprintf('   bytes_written: %s -> %s (monoton steigend: %s, Zuwachs %s)',
                            $m{bfirst}, $m{blast}, ($m{mono} ? 'ja' : 'NEIN'), $inc);
        push @$out, sprintf('   ring_fill: min=%s @%s, max=%s @%s',
                            $m{rmin}, $m{rmints}, $m{rmax}, $m{rmaxts});
        push @$out, '   Extremwertzeilen wortwoertlich (damit keine zitierte Zahl verlorengeht):';
        push @$out, '   ' . $m{rminline};
        push @$out, '   ' . $m{rmaxline};
        %m = ();
        return;
    };

    for my $r (@ws) {
        my $d0 = abs($r->{epoch} - $a{t0});
        my $d1 = abs($r->{epoch} - $a{t1});
        my $line = render_record($r, $a{mark_day});
        if ($a{full} || $d0 <= $PAIR_SPAN || $d1 <= $PAIR_SPAN) {
            $flush_mid->();
            push @$out, $line;
            next;
        }
        my $b = ($r->{raw} =~ /bytes_written=([0-9]+)/) ? $1 : '';
        my $rf = ($r->{raw} =~ /ring_fill=([0-9]+)/)    ? $1 : '';
        if (!$m{n}) {
            %m = (n => 0, tsfirst => $r->{ts}, bfirst => $b, mono => 1, bprev => $b,
                  rmin => $rf, rmax => $rf, rmints => $r->{ts}, rmaxts => $r->{ts},
                  rminline => $line, rmaxline => $line);
        }
        else {
            $m{mono} = 0 if $b ne '' && $m{bprev} ne '' && $b + 0 < $m{bprev} + 0;
            $m{bprev} = $b if $b ne '';
            if ($rf ne '' && $rf + 0 < $m{rmin} + 0) { $m{rmin} = $rf; $m{rmints} = $r->{ts}; $m{rminline} = $line; }
            if ($rf ne '' && $rf + 0 > $m{rmax} + 0) { $m{rmax} = $rf; $m{rmaxts} = $r->{ts}; $m{rmaxline} = $line; }
        }
        $m{tslast} = $r->{ts};
        $m{blast}  = $b;
        $m{n}++;
    }
    $flush_mid->();
    push @$out, '';
    return scalar @ws;
}

# ---------------------------------------------------------------------------
# day_crosscheck -- WR-06: Tagesabgleich ZWISCHEN den Quellen.
#
# Der Tageswaechter von select_record schuetzt nur Paarungen INNERHALB einer
# Quelle, und die MEHRDEUTIG-Zeilen melden nur mehrere Tage INNERHALB eines
# Fensters. Enthaelt das server-Fenster nur Zeilen vom 09. und das
# Daemon-Fenster nur Zeilen vom 08. (weil der Daemon am 09. zu dieser Uhrzeit
# nichts protokolliert hat), war bisher KEINE Zeile laut: kein [TAG]-Praefix,
# keine !!-Zeile -- der einzige Hinweis war die unauffaellige Zeile "Im
# Fenster vertretene Tage: 26-09-08". Zwei Belegbloecke verschiedener Tage
# standen untereinander wie einer (Regel 3).
#
# Entwurfsentscheidung: LAUT melden, nicht --date verpflichtend machen.
# Regel 2 heisst "laut melden", nicht "verbieten"; ein Werkzeug, das einen
# Aufruf ablehnt, den es beantworten koennte, verliert Brauchbarkeit (und
# alle bestehenden Aufrufe ohne --date wuerden brechen, ohne dass dadurch
# ein einziger Fehlbefund mehr erkannt wird).
#
# "?" ist kein Tag und wird vor dem Vergleich entfernt -- dafuer steht die
# eigene "?"-Zeile des Daemon-Tagesbezugs. Die Tagesmengen sind nicht nur
# gleich oder disjunkt, sie koennen sich schneiden; dann wird die Schnittmenge
# benannt, weil nur fuer sie quellenuebergreifende Aussagen belegt sind.
# ---------------------------------------------------------------------------
sub day_crosscheck {
    my ($sdays, $ddays, $date_short, $date) = @_;
    my @s = grep { $_ ne '?' } @$sdays;
    my @d = grep { $_ ne '?' } @$ddays;
    return () unless @s && @d;
    my %s = map { $_ => 1 } @s;
    my @common = grep { $s{$_} } @d;
    return () if @common == @s && @common == @d;   # identische Tagesmengen
    my $hint = $date_short
        ? sprintf('--date %s ist gesetzt und hat das NICHT aufgeloest -- die Tagesableitung einer der beiden Quellen ist fraglich.', $date)
        : 'T0/T1 sind reine Uhrzeiten ohne Datum -- mit --date YYYY-MM-DD auf einen Tag einschraenken.';
    return (sprintf('!! TAGESABGLEICH DER QUELLEN: die server.log-Fensterzeilen stammen vom %s, die Daemon-Fensterzeilen vom %s -- die beiden Quellen zeigen KEINEN gemeinsamen Kalendertag. Die Abschnitte oben und unten beschreiben verschiedene Tage; quellenuebergreifende Aussagen (Zeitbasis-Selbsttest) sind damit nicht belegt. %s',
                    join(',', @s), join(',', @d), $hint))
        unless @common;
    return (sprintf('!! TAGESABGLEICH DER QUELLEN: die Tagesmengen der beiden Quellen sind NICHT gleich: server.log %s, Daemon-Log %s, gemeinsam %s. Fuer die nicht gemeinsamen Tage gibt es in der anderen Quelle keinen Beleg; quellenuebergreifende Aussagen (Zeitbasis-Selbsttest) gelten nur fuer %s. %s',
                    join(',', @s), join(',', @d), join(',', @common), join(',', @common), $hint));
}

# ---------------------------------------------------------------------------
# emit_timebase -- Zeitbasis-Selbsttest (WR-02). Die Zeitbasis-Zeile der
# Kopfzeile ist eine ANNAHME; hier wird sie geprueft, indem jedes
# "Request: GET /stream" im Fenster mit dem zeitnaechsten "client-attach"
# des Daemon-Logs gepaart wird.
#
# N-WR-03: der Versatz-Kandidat wird je GET neu bestimmt (vorher blieb er
# ueber alle GETs stehen) und gegen Vielfache von 30 Minuten geprueft --
# CEST gegen TZ=UTC sind ZWEI Stunden, die alte 1-Stunden-Probe hat genau
# den Fall nicht erkannt, fuer den der Test gebaut wurde.
# ---------------------------------------------------------------------------
sub emit_timebase {
    my (%a) = @_;
    my $out = $a{out};
    push @$out, '--- Zeitbasis-Selbsttest (server.log vs. Daemon-Log) ---';
    if (!$a{daemon_ok}) {
        push @$out, 'NICHT DURCHFUEHRBAR: Daemon-Log nicht lesbar.';
        push @$out, '';
        return;
    }
    my @get = grep { $_->{raw} =~ /Request: GET \/stream/ } @{ $a{srv_recs} };
    my $attach = $a{attach};
    if (!@get || !@$attach) {
        push @$out, sprintf("NICHT DURCHFUEHRBAR: %d 'Request: GET /stream' im Fenster, %d 'client-attach' im Daemon-Log -- ohne Paar ist die Zeitbasis nicht pruefbar. Die Annahme in der Kopfzeile bleibt UNGEPRUEFT.",
                            scalar @get, scalar @$attach);
        push @$out, '';
        return;
    }

    # WR-06: @attach traegt bewusst ALLE Zeilen der Datei ohne Fensterfilter
    # (sonst kann ein Stundenversatz gar nicht sichtbar werden) -- ohne --date
    # also auch die anderer Kalendertage. Ein attach von gestern zur selben
    # Uhrzeit wie das GET von heute ergab dann "Innerhalb +/-2s: 1" und
    # bestaetigte eine Zeitbasis, die nie geprueft wurde: genau der Versatz,
    # fuer den dieser Test gebaut ist, blieb unsichtbar (Regel 3). Gepaart
    # wird deshalb nur innerhalb eines Kalendertags. Ein nicht ableitbarer Tag
    # ("?") schliesst einen Partner NICHT aus -- "unbekannt" ist kein anderer
    # Tag --, und beide Ausschlussgruende werden laut gezaehlt (Regel 2).
    my @gdays = day_list(map { $_->{day} } @get);
    my @adays = day_list(map { $_->{day} } @$attach);
    my $usable = grep { my $at = $_; grep { day_compatible($at->{day}, $_->{day}) } @get } @$attach;
    if (!$usable) {
        push @$out, sprintf("NICHT DURCHFUEHRBAR: Tag nicht eindeutig -- die %d 'Request: GET /stream' im Fenster tragen den Kalendertag %s, die %d 'client-attach' des Daemon-Logs den Kalendertag %s. Kein Paar desselben Kalendertags; ein Abstand ueber die Tagesgrenze hinweg waere kein Zeitbasis-Versatz, sondern die Tagesdifferenz. Die Annahme in der Kopfzeile bleibt UNGEPRUEFT%s.",
                            scalar @get, join(',', @gdays), scalar @$attach, join(',', @adays),
                            $a{date_short} ? '' : ' -- mit --date YYYY-MM-DD auf einen Tag einschraenken');
        push @$out, '';
        return;
    }
    my $excluded = scalar(@$attach) - $usable;

    my ($near, $far, $shifted, $unpaired) = (0, 0, 0, 0);
    my $min_shift_ad;
    for my $g (@get) {
        my ($bd, $bh, $bh_ad);
        for my $at (@$attach) {
            next unless day_compatible($at->{day}, $g->{day});
            my $ad = abs($at->{epoch} - $g->{epoch});
            $bd = $ad if !defined $bd || $ad < $bd;
            next if $ad < $TB_STEP / 2;   # zu nah an 0: kein Zeitzonenversatz
            my $k = int($ad / $TB_STEP + 0.5);
            my $r = abs($ad - $k * $TB_STEP);
            if (!defined $bh || $r < $bh) { $bh = $r; $bh_ad = $ad; }
        }
        if (!defined $bd) { $unpaired++; next; }   # kein attach desselben Tages
        if ($bd <= $TB_TOL) { $near++; next; }
        $far++;
        if (defined $bh && $bh <= $TB_TOL) {
            $shifted++;
            $min_shift_ad = $bh_ad if !defined $min_shift_ad || $bh_ad < $min_shift_ad;
        }
    }
    push @$out, sprintf("Gepruefte Paare: %d 'Request: GET /stream' gegen %d 'client-attach'%s. Innerhalb +/-%ss: %d. Weiter entfernt: %d, davon %d mit einem Abstand nahe einem Vielfachen von 30 Minuten (Zeitzonen-Signatur).%s",
                        scalar @get, scalar @$attach,
                        $excluded ? sprintf(' (davon %d mit abweichendem Kalendertag NICHT als Partner zugelassen: Daemon-Log %s gegen server.log %s)',
                                            $excluded, join(',', @adays), join(',', @gdays))
                                  : '',
                        $TB_TOL, $near, $far, $shifted,
                        $unpaired ? sprintf(" !! %d 'Request: GET /stream' haben im Daemon-Log keinen 'client-attach' desselben Kalendertags und sind in diesen Zahlen NICHT enthalten -- fuer sie ist die Zeitbasis NICHT geprueft.",
                                            $unpaired)
                                  : '');
    if ($near == 0 && $shifted > 0) {
        push @$out, sprintf('!! ZEITBASIS-ABWEICHUNG VERMUTET: kein einziges GET/attach-Paar liegt innerhalb +/-%ss, aber %d Paar(e) liegen nahe einem Vielfachen von 30 Minuten auseinander (kleinster solcher Abstand: rund %.1f Stunden). Das ist die Signatur eines Zeitzonenversatzes zwischen server.log und Daemon-Log (z.B. LMS unter TZ=UTC). Alle Zeitfenster dieses Belegblocks sind dann NICHT vergleichbar.',
                            $TB_TOL, $shifted, $min_shift_ad / 3600);
    }
    elsif ($near == 0) {
        push @$out, sprintf('!! Kein GET/attach-Paar innerhalb +/-%ss gefunden. Ein Zeitbasis-Versatz ist damit NICHT ausgeschlossen; die Annahme in der Kopfzeile bleibt fuer diesen Lauf unbestaetigt.',
                            $TB_TOL);
    }
    push @$out, '';
    return;
}

# ---------------------------------------------------------------------------
# rec_field -- jq-Semantik ohne jq: "//" verwirft nur null/false, eine 0 oder
# ein "" bleiben erhalten. Ausgegeben wird ein Feld nur, wenn es definiert und
# nicht leer ist (so verhielt sich die Bash-Fassung ueber [ -n "$x" ]).
# ---------------------------------------------------------------------------
sub rec_field {
    my ($h, @keys) = @_;
    for my $k (@keys) {
        if ($k =~ /^(\w+)\.(\w+)$/) {
            my ($a, $b) = ($1, $2);
            next unless ref $h->{$a} eq 'HASH';
            return $h->{$a}{$b} if defined $h->{$a}{$b};
            next;
        }
        return $h->{$k} if defined $h->{$k};
    }
    return undef;
}

sub rec_bool {
    my ($h, $k) = @_;
    return undef unless exists $h->{$k};
    return $h->{$k} ? 'true' : 'false';
}

# ---------------------------------------------------------------------------
# rec_queue_summary -- eigener Helfer NEBEN rec_field (nicht darin), weil
# previous/upcoming Arrays sind (je Eintrag uid/source/item.uri), die
# rec_field()s Punkt-Pfad-Skalar-Logik nicht abdeckt. Liefert previous_n/
# upcoming_n als Zahl (Array vorhanden), 'FEHLT' (Schluessel fehlt) oder
# 'KEIN_ARRAY' (Schluessel vorhanden, aber kein Array) -- drei
# unterscheidbare Zustaende statt eines stummen undef (Regel 2, 83.2-02
# D-03). upcoming_first/previous_last (item.uri, ersatzweise uid) werden
# nur gesetzt, wenn definiert.
# ---------------------------------------------------------------------------
sub rec_queue_summary {
    my ($h) = @_;
    my %s;
    for my $pair ([qw(previous_n previous)], [qw(upcoming_n upcoming)]) {
        my ($key, $field) = @$pair;
        if (!exists $h->{$field}) {
            $s{$key} = 'FEHLT';
        }
        elsif (ref $h->{$field} eq 'ARRAY') {
            $s{$key} = scalar @{ $h->{$field} };
        }
        else {
            $s{$key} = 'KEIN_ARRAY';
        }
    }
    if (ref $h->{upcoming} eq 'ARRAY' && @{ $h->{upcoming} }) {
        my $first = $h->{upcoming}[0];
        if (ref $first eq 'HASH') {
            my $uri = (ref $first->{item} eq 'HASH') ? $first->{item}{uri} : undef;
            $uri = $first->{uid} unless defined $uri;
            $s{upcoming_first} = $uri if defined $uri;
        }
    }
    if (ref $h->{previous} eq 'ARRAY' && @{ $h->{previous} }) {
        my $last = $h->{previous}[-1];
        if (ref $last eq 'HASH') {
            my $uri = (ref $last->{item} eq 'HASH') ? $last->{item}{uri} : undef;
            $uri = $last->{uid} unless defined $uri;
            $s{previous_last} = $uri if defined $uri;
        }
    }
    return \%s;
}

# ---------------------------------------------------------------------------
# section_recorder -- Recorder-Mitschnitt (JSONL, rohes dir/frame- ODER
# flaches type-Schema, pro Zeile erkannt). meta-Zeilen (darunter
# "device mismatch", die EINZIGE Zeile, die einen fremden Mitschnitt
# verraet), tx-Frames und nicht parsbare Frames werden nie stumm verworfen.
# ---------------------------------------------------------------------------
sub section_recorder {
    my (%a) = @_;
    my $out  = $a{out};
    my $file = $a{recorder};
    my $bar  = '=' x 72;
    push @$out, $bar, 'Recorder', $bar;

    if ($file eq '') {
        push @$out, '-- kein Recorder-Mitschnitt uebergeben (--recorder fehlt); Abschnitt Recorder: NICHT GEPRUEFT --';
        return { state => 'none' };
    }
    if (!-e $file) {
        push @$out, "!! Recorder-Datei $file nicht gefunden";
        return { state => 'missing' };
    }
    if (!-s $file) {
        push @$out, "!! Recorder-Datei $file hat 0 Bytes -- KEIN Recorder-Beleg vorhanden (moegliche Ursache: fehlendes PERLIO=unix, s. 2026-09-07-Ausfall, sechs entwertete Laeufe)";
        return { state => 'empty' };
    }

    my ($mtime) = capture_quiet($a{stat_bin}, '-c', '%y', $file);
    $mtime = 'unbekannt' if !defined $mtime || $mtime !~ /\S/;
    $mtime =~ s/\s+\z//;

    my $json = JSON::PP->new->allow_nonref;
    my %st = (total => 0, raw => 0, flat => 0, unknown_schema => 0, not_json => 0,
              frame_unparsed => 0, typeless => 0, meta => 0, tx => 0,
              listed_in => 0, listed_out => 0, other_n => 0, other_win => 0);
    my (%other, %other_w);
    my (@meta, @tx, @events);
    my ($first_ts, $first_sec, $last_ts, $last_sec, $meta_eof_ts);
    my ($saw_raw, $saw_flat) = (0, 0);
    # 260914-qn1: REANFORDERUNG-Namensgebung (Signatur C, zweite Luecke).
    # $saw_handshake_ok ist der Entscheidbarkeits-Anker: nur wenn der
    # WS-Handshake nachweislich abgeschlossen wurde UND keine
    # REANFORDERUNG-Zeile existiert, ist "der Recorder lief ohne
    # --reannounce-lms" eine ABLEITUNG, keine Vermutung.
    my $saw_handshake_ok = 0;
    my @reannounce;

    open my $fh, '<', $file or do {
        push @$out, "!! Recorder-Datei $file nicht lesbar: $!";
        return { state => 'unreadable' };
    };
    while (defined(my $line = <$fh>)) {
        $line =~ s/\n\z//;   # NUR der Zeilenumbruch -- ein \r im Log ist Teil der Rohzeile
        next unless length $line;
        $st{total}++;
        my $d = eval { $json->decode($line) };
        if ($@) { $st{not_json}++; next; }
        if (ref $d ne 'HASH' || !(exists $d->{frame} || exists $d->{type})) {
            $st{unknown_schema}++;
            next;
        }

        my ($ts, $type, $pos, $speed, $status, $uri, $active, $device,
            $qprev_n, $qup_n, $qup_first, $qprev_last);
        if (exists $d->{frame}) {
            $st{raw}++;
            $saw_raw = 1;
            $ts = $d->{ts};
            my $ftext = defined $d->{frame} ? $d->{frame} : '';
            my $dir   = defined $d->{dir} ? $d->{dir} : '';
            if ($dir eq 'meta') {
                $st{meta}++;
                push @meta, sprintf('[META @%s] %s', defined $ts ? $ts : '', $ftext);
                $meta_eof_ts = $ts if $ftext =~ /EOF|ERROR|HANDSHAKE-TIMEOUT/;
                push @meta, sprintf('!! Recorder-meta-Zeile @%s: %s -- dieser Mitschnitt gehoert zu einem ANDEREN Geraet als dem erwarteten. Der Recorder-Abschnitt ist damit KEIN Beleg fuer den hier gemessenen Spieler.',
                                    defined $ts ? $ts : '', $ftext)
                    if index($ftext, 'device mismatch') >= 0;
                # 260914-qn1: Entscheidbarkeits-Anker -- tools/soloist-ws-record.pl's
                # connect-Callback schreibt HANDSHAKE-OK und (bei gesetztem
                # $lms_sock) unbedingt eine REANFORDERUNG-Zeile, bevor der
                # Callback zurueckkehrt; ohne HANDSHAKE-OK ist "keine
                # REANFORDERUNG-Zeile" nicht von einem vor dem Handshake
                # abgebrochenen Mitschnitt unterscheidbar.
                $saw_handshake_ok = 1 if index($ftext, 'HANDSHAKE-OK') >= 0;
                # 260914-qn1: die REANFORDERUNG-Quittung additiv als eigene,
                # benannte Unterrubrik erfassen -- die Zeile bleibt auch im
                # generischen @meta-Block oben, wird hier nicht abgezogen.
                if (index($ftext, 'REANFORDERUNG') >= 0) {
                    if ($ftext =~ /REANFORDERUNG OK dispatch_ms=([\d.]+) roundtrip_ms=([\d.]+)/) {
                        push @reannounce, sprintf('[REANFORDERUNG @%s] OK dispatch_ms=%s roundtrip_ms=%s -- Rohzeile: %s',
                                                  defined $ts ? $ts : '', $1, $2, $ftext);
                    }
                    elsif ($ftext =~ /REANFORDERUNG UNGUELTIG: (.*)/) {
                        push @reannounce, sprintf('[REANFORDERUNG @%s] UNGUELTIG, Grund: %s -- Rohzeile: %s',
                                                  defined $ts ? $ts : '', $1, $ftext);
                    }
                    else {
                        push @reannounce, sprintf('[REANFORDERUNG @%s] unrecognized REANFORDERUNG format (Regel 2 -- nicht stillschweigend verworfen) -- Rohzeile: %s',
                                                  defined $ts ? $ts : '', $ftext);
                    }
                }
                next;
            }
            if ($dir eq 'tx') {
                $st{tx}++;
                push @tx, sprintf('[TX @%s] %s', defined $ts ? $ts : '', $ftext);
            }
            my $f = eval { $json->decode($ftext) };
            if ($@ || ref $f ne 'HASH') {
                $st{frame_unparsed}++;
                push @tx, sprintf('[FRAME NICHT PARSBAR @%s] %s', defined $ts ? $ts : '', $ftext);
            }
            else {
                $type   = rec_field($f, 'type');
                $pos    = rec_field($f, 'position.position_ms', 'position_ms');
                $speed  = rec_field($f, 'position.speed', 'speed');
                $status = rec_field($f, 'status');
                $uri    = rec_field($f, 'uri', 'item.uri');
                $active = rec_bool($f, 'is_active');
                $device = rec_field($f, 'device_name');
                # 83.2-02: roher Zweig -- previous/upcoming sind Arrays,
                # rec_field() liest sie nicht (s. Kommentar bei %REC_LISTED).
                if (defined $type && $type eq 'queue_changed') {
                    my $qs = rec_queue_summary($f);
                    ($qprev_n, $qup_n, $qup_first, $qprev_last) =
                        @{$qs}{qw(previous_n upcoming_n upcoming_first previous_last)};
                }
            }
        }
        else {
            $st{flat}++;
            $saw_flat = 1;
            $ts     = $d->{ts};
            $type   = rec_field($d, 'type');
            $pos    = rec_field($d, 'position_ms');
            $speed  = rec_field($d, 'speed');
            $status = rec_field($d, 'status');
            $uri    = rec_field($d, 'uri', 'item.uri');
            $active = rec_bool($d, 'is_active');
            $device = rec_field($d, 'device_name');
            # 83.2-02: flacher Zweig, dieselbe Erweiterung wie oben.
            if (defined $type && $type eq 'queue_changed') {
                my $qs = rec_queue_summary($d);
                ($qprev_n, $qup_n, $qup_first, $qprev_last) =
                    @{$qs}{qw(previous_n upcoming_n upcoming_first previous_last)};
            }
        }

        next unless defined $ts && length $ts;
        my ($sec) = parse_hms($ts);
        next unless defined $sec;

        if (!defined $last_sec || $sec > $last_sec)  { $last_sec  = $sec; $last_ts  = $ts; }
        if (!defined $first_sec || $sec < $first_sec) { $first_sec = $sec; $first_ts = $ts; }

        $type = '' unless defined $type;
        if ($REC_LISTED{$type}) {
            if ($sec >= $a{win_start} && $sec <= $a{win_end}) {
                $st{listed_in}++;
                my $extra = '';
                for my $p (['status', $status], ['uri', $uri], ['position_ms', $pos],
                           ['speed', $speed], ['is_active', $active], ['device_name', $device],
                           # 83.2-02: queue_changed-Arraykennzahlen, gleiche
                           # Zeile, gleiches key=value-Format, keine neue Rubrik.
                           ['previous_n', $qprev_n], ['upcoming_n', $qup_n],
                           ['upcoming_first', $qup_first], ['previous_last', $qprev_last]) {
                    next unless defined $p->[1] && length "$p->[1]";
                    $extra .= " $p->[0]=$p->[1]";
                }
                push @events, "\@$ts type=$type$extra";
            }
            else {
                # Regel 2: auch bekannte Typen ausserhalb des Fensters werden
                # gezaehlt, nicht stumm verworfen (Restzaehler).
                $st{listed_out}++;
            }
        }
        elsif ($type eq '') {
            $st{typeless}++;
        }
        else {
            $st{other_n}++;
            $other{$type}++;
            if ($sec >= $a{win_start} && $sec <= $a{win_end}) {
                $st{other_win}++;
                $other_w{$type}++;
            }
        }
    }
    close $fh;

    my $schema = ($saw_raw && $saw_flat) ? 'gemischt'
               : $saw_raw ? 'roh'
               : $saw_flat ? 'flach' : 'nicht erkannt';
    push @$out, "--- Recorder: $file (Schema erkannt: $schema) ---";
    push @$out, "Datei-mtime: $mtime (kann bei archivierten/kopierten Belegen die Checkout-/Kopierzeit widerspiegeln, nicht die Aufnahmezeit -- das letzte Ereignis-ts bleibt das aussagekraeftige Signal)";

    if (defined $first_ts) {
        push @$out, sprintf('Abdeckung Recorder: erstes Ereignis @%s .. letztes Ereignis @%s (Fenster: %s .. %s)',
                            $first_ts, $last_ts, fmt_hms($a{win_start}), fmt_hms($a{win_end}));
        if ($last_sec < $a{win_start}) {
            push @$out, sprintf("!! Recorder deckt das Fenster NICHT ab: das letzte Ereignis (@%s) liegt VOR dem Fensteranfang. 'Kein Ereignis im Fenster' heisst hier 'nicht aufgezeichnet', NICHT 'nicht passiert'.", $last_ts);
        }
        elsif ($first_sec > $a{win_end}) {
            push @$out, sprintf("!! Recorder deckt das Fenster NICHT ab: das erste Ereignis (@%s) liegt NACH dem Fensterende. 'Kein Ereignis im Fenster' heisst hier 'nicht aufgezeichnet', NICHT 'nicht passiert'.", $first_ts);
        }
    }
    else {
        push @$out, '!! Abdeckung Recorder: keine einzige Zeile mit lesbarem Zeitstempel -- die Abdeckung ist damit UNBEKANNT.';
    }

    if (@meta) {
        push @$out, '[meta-Zeilen des Recorders, vollstaendig -- auch ausserhalb des Fensters]', @meta;
    }
    else {
        push @$out, '[keine meta-Zeile im Mitschnitt]';
    }

    # 260914-qn1: REANFORDERUNG-Namensgebung -- DREIWEGE-Entscheidung, nie
    # zweiwege (die blosse Abwesenheit einer REANFORDERUNG-Zeile ist ohne
    # $saw_handshake_ok nicht entscheidbar; Regel 4 "Abwesenheit ist nicht
    # Widerlegung"). Keiner der beiden neuen Zweige darf eine Reanforderung
    # als fehlgeschlagen charakterisieren -- das einzige erlaubte Urteil
    # ueber ihren Ausgang ist der bereits woertlich mitgefuehrte
    # UNGUELTIG-Fall in @reannounce.
    if (@reannounce) {
        push @$out, '[REANFORDERUNG-Zeilen des Recorders, vollstaendig -- auch ausserhalb des Fensters]', @reannounce;
    }
    elsif ($saw_handshake_ok) {
        push @$out, "[keine REANFORDERUNG-Zeile im Mitschnitt -- der WS-Handshake ist bestaetigt (HANDSHAKE-OK), [ABGELEITET aus HANDSHAKE-OK ohne REANFORDERUNG:] der Recorder lief ohne --reannounce-lms, es wurde keine Reanforderung abgesetzt]";
    }
    else {
        push @$out, "[keine REANFORDERUNG-Zeile im Mitschnitt UND kein HANDSHAKE-OK -- nicht entscheidbar, ob --reannounce-lms gesetzt war (moegliche Ursachen: HANDSHAKE-TIMEOUT, EOF/ERROR vor dem Handshake, oder tatsaechlich ohne die Flagge gestartet) -- dieses Werkzeug faellt darueber kein Urteil]";
    }

    push @$out, '[gesendete Kommandos (tx) und nicht parsbare Frames, vollstaendig]', @tx if @tx;

    if (@events) { push @$out, @events; }
    else         { push @$out, '[KEIN RECORDER-EREIGNIS IM FENSTER GEFUNDEN]'; }

    # N-WR-05: die Zaehlung "anderer Typen" nennt jetzt ihren Bezug (Fenster
    # vs. ganze Datei) -- vorher war sie dateiweit und las sich fensterbezogen.
    if ($st{other_n} > 0) {
        my $all = join(', ', map { "$_=$other{$_}" } sort keys %other);
        my $win = $st{other_win}
                ? join(', ', map { "$_=$other_w{$_}" } sort keys %other_w)
                : 'keiner';
        push @$out, sprintf('[%d Frame(s) anderer Typen in der ganzen Datei nicht einzeln aufgefuehrt: %s; davon im Fenster %d: %s]',
                            $st{other_n}, $all, $st{other_win}, $win);
    }
    push @$out, sprintf('[%d Frame(s) ohne erkennbares Typfeld nicht einzeln aufgefuehrt]', $st{typeless})
        if $st{typeless} > 0;
    push @$out, sprintf('!! %d Frame(s) im rohen Schema tragen einen Frametext, der kein JSON ist -- oben als [FRAME NICHT PARSBAR] wortwoertlich ausgegeben.', $st{frame_unparsed})
        if $st{frame_unparsed} > 0;
    push @$out, sprintf("!! Recorder-Datei %s: %d von %d Zeilen in keinem bekannten Schema (weder rohes 'frame'-Format noch flaches 'type'-Format)", $file, $st{unknown_schema}, $st{total})
        if $st{unknown_schema} > 0;
    push @$out, sprintf('%d von %d Zeile(n) nicht als JSON parsbar (Parse-Fehler; die letzte Zeile kann durch einen Prozessabbruch abgeschnitten sein)', $st{not_json}, $st{total})
        if $st{not_json} > 0;

    # Deckungslueckenpruefung (WR-03): der Ersatzwert "Fensterende" ist eine
    # SKRIPTKONSTANTE, keine Erwartung an den Recorder -- ohne
    # --recorder-seconds ist "vollstaendig" nicht definiert und wird als
    # NICHT PRUEFBAR gesagt, nicht als Warnung. T1 dagegen ist ein vom
    # Aufrufer GEMESSENER Ankerpunkt: endet der Mitschnitt davor, ist das laut.
    if (!defined $last_sec) {
        push @$out, 'Deckung: NICHT PRUEFBAR -- kein Ereignis mit lesbarem Zeitstempel im Mitschnitt.';
    }
    elsif ($a{recorder_seconds} ne '') {
        my $soll = $a{t0} + $a{recorder_seconds};
        my $lbl  = sprintf('%s (T0 + --recorder-seconds %s)', fmt_hms($soll), $a{recorder_seconds});
        if ($last_sec < $soll) {
            push @$out, sprintf('!! Recorder-Datei %s: letztes Ereignis @%s, Sollende=%s, Delta=%.1fs ohne weiteres Ereignis -- NICHT als vollstaendige Deckung werten (Ursache -- Prozesstod vs. sparsame WS-Verbindung -- ist aus der Datei allein nicht bestimmbar, dieses Skript faellt darueber kein Urteil).',
                                $file, $last_ts, $lbl, $soll - $last_sec);
            push @$out, sprintf('   Zusaetzliches Signal (nicht alleinig beweiskraeftig): meta-Zeile EOF/ERROR/HANDSHAKE-TIMEOUT @%s', $meta_eof_ts)
                if defined $meta_eof_ts;
        }
        else {
            push @$out, sprintf('Deckung: letztes Ereignis @%s liegt auf oder nach dem Sollende %s -- keine Luecke bis zum Sollende.', $last_ts, $lbl);
        }
    }
    else {
        push @$out, sprintf("Deckung: NICHT PRUEFBAR (--recorder-seconds fehlt -- ohne die erwartete Recorder-Laufzeit ist 'vollstaendig' nicht definiert). Erstes Ereignis @%s, letztes Ereignis @%s, T1=%s.",
                            $first_ts, $last_ts, $a{t1_label});
        if ($last_sec < $a{t1}) {
            push @$out, sprintf('!! Recorder-Datei %s: das letzte Ereignis @%s liegt %.1fs VOR T1 (%s) -- der Mitschnitt endet vor dem Fensterende-Anker dieses Laufs und deckt ihn damit NICHT ab (Ursache -- Prozesstod vs. sparsame WS-Verbindung -- ist aus der Datei allein nicht bestimmbar, dieses Skript faellt darueber kein Urteil).',
                                $file, $last_ts, $a{t1} - $last_sec, $a{t1_label});
            push @$out, sprintf('   Zusaetzliches Signal (nicht alleinig beweiskraeftig): meta-Zeile EOF/ERROR/HANDSHAKE-TIMEOUT @%s', $meta_eof_ts)
                if defined $meta_eof_ts;
        }
        else {
            push @$out, sprintf('   Der Mitschnitt reicht bis T1 (%s) und darueber hinaus; ob er die volle vorgesehene Laufzeit abdeckt, ist ohne --recorder-seconds nicht entscheidbar.', $a{t1_label});
        }
    }
    push @$out, '';
    return { state => 'read', %st };
}

# ---------------------------------------------------------------------------
# emit_leftovers -- RESTZAEHLER (Architekturvorgabe 4, Regel 2).
#
# Jede gelesene Zeile landet in genau einem Topf; die Summe wird gegen die
# Gesamtzahl geprueft. Ein Zaehler, der nie Null sein darf, ohne dass es
# dasteht -- und eine Zeile, die unerwaehnt wegfaellt, faellt hier auf.
# ---------------------------------------------------------------------------
sub emit_leftovers {
    my (%a) = @_;
    my $out = $a{out};
    push @$out, '--- Restzaehler: verworfene, unerkannte und nicht kategorisierte Zeilen (Regel 2) ---';

    for my $s (@{ $a{sources} }) {
        my ($label, $agg, $win, $accessible) = @{$s}{qw(label agg win accessible)};
        if (!$accessible) {
            push @$out, sprintf('%s: Quelle nicht lesbar -- keine Zeile gelesen, kein Restzaehler moeglich (Abschnitt oben als NICHT GEPRUEFT benannt).', $label);
            next;
        }
        my $uncat = grep { !@{ $_->{cats} } && !@{ $_->{noise} || [] } } @$win;
        push @$out, sprintf('%s: %d Zeile(n) gelesen = %d ohne eigenen Zeitstempel + %d mit unlesbarem Zeitstempel + %d datumslos ohne aufloesbaren Kalendertag + %d mit Zeitstempel; von diesen %d ausserhalb des Fensters + %d vom Tagesfilter verworfen + %d im Fenster; von den Fensterzeilen %d in keiner Kategorie (oben nur als Zahl genannt).',
                            $label, $agg->{lines},
                            $agg->{no_ts} + $agg->{no_ts_fakepulse} + $agg->{unrecognized},
                            $agg->{unparsable_ts}, $agg->{dateless_no_date}, $agg->{timestamped},
                            $agg->{outside}, $agg->{day_filtered}, scalar @$win, $uncat);
        push @$out, sprintf('!! %s: %d Zeile(n) mit nur ueber einen Zahlenpraefix lesbarem Zeitstempel -- deren Einordnung ins Fenster ist unsicher.',
                            $label, $agg->{lenient_ts}) if $agg->{lenient_ts} > 0;
        my $sum_a = $agg->{no_ts} + $agg->{no_ts_fakepulse} + $agg->{unrecognized}
                  + $agg->{unparsable_ts} + $agg->{dateless_no_date} + $agg->{timestamped};
        my $sum_b = $agg->{outside} + $agg->{day_filtered} + scalar @$win;
        push @$out, sprintf('!! Restzaehler-Selbsttest %s FEHLGESCHLAGEN: %d gelesene Zeilen, Summe der Toepfe %d bzw. %d gegen %d mit Zeitstempel -- eine Zeile faellt unerwaehnt weg, das ist ein Fehler dieses Werkzeugs.',
                            $label, $agg->{lines}, $sum_a, $sum_b, $agg->{timestamped})
            if $sum_a != $agg->{lines} || $sum_b != $agg->{timestamped};
    }

    my $r = $a{recorder_stats};
    if (!defined $r || $r->{state} ne 'read') {
        my %txt = (none => 'kein Mitschnitt uebergeben (--recorder fehlt)',
                   missing => 'Datei nicht gefunden', empty => 'Datei hat 0 Bytes',
                   unreadable => 'Datei nicht lesbar');
        push @$out, sprintf('Recorder: %s -- keine Zeile gelesen, kein Restzaehler moeglich.',
                            $txt{ $r ? $r->{state} : 'none' } || 'nicht ausgewertet');
    }
    else {
        push @$out, sprintf('Recorder: %d Zeile(n) gelesen = %d nicht als JSON parsbar + %d in keinem bekannten Schema + %d auswertbar (%d rohes, %d flaches Schema); davon %d meta, %d tx, %d Frametext nicht parsbar, %d ohne Typfeld, %d bekannter Typ im Fenster (oben aufgefuehrt), %d bekannter Typ ausserhalb des Fensters, %d anderer Typ (%d davon im Fenster).',
                            $r->{total}, $r->{not_json}, $r->{unknown_schema},
                            $r->{raw} + $r->{flat}, $r->{raw}, $r->{flat},
                            $r->{meta}, $r->{tx}, $r->{frame_unparsed}, $r->{typeless},
                            $r->{listed_in}, $r->{listed_out}, $r->{other_n}, $r->{other_win});
    }
    push @$out, '';
    return;
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
sub main {
    my @argv = @_;
    my %o = (out => '', recorder => '', recorder_seconds => '', full => 0,
             server_log => $SERVER_LOG_DEFAULT, daemon_log => '', date => '', daemon_end_epoch => '');
    my @pos;
    while (@argv) {
        my $x = shift @argv;
        if    ($x eq '--help' || $x eq '-h')  { print usage(); return 0; }
        elsif ($x eq '--out')                 { $o{out}     = @argv ? shift @argv : ''; }
        elsif ($x eq '--recorder')            { $o{recorder} = @argv ? shift @argv : ''; }
        elsif ($x eq '--recorder-seconds')    { $o{recorder_seconds} = @argv ? shift @argv : ''; }
        elsif ($x eq '--server-log')          { $o{server_log} = @argv ? shift @argv : ''; }
        elsif ($x eq '--daemon-log')          { $o{daemon_log} = @argv ? shift @argv : ''; }
        elsif ($x eq '--date')                { $o{date}    = @argv ? shift @argv : ''; }
        elsif ($x eq '--daemon-end-epoch')    { $o{daemon_end_epoch} = @argv ? shift @argv : ''; }
        elsif ($x eq '--full')                { $o{full}    = 1; }
        elsif ($x =~ /^--/)                   { abort("ABBRUCH: unbekannte Option '$x'"); }
        else                                  { push @pos, $x; }
    }
    if (!@pos) { print usage(); return 0; }
    abort('ABBRUCH: <mac> <T0> <T1> erforderlich (siehe --help)') if @pos < 3;

    my ($mac, $T0, $T1) = @pos[0, 1, 2];
    my $tre = qr/^[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?$/;
    abort("ABBRUCH: ungueltiges Zeitformat fuer T0='$T0', erwartet HH:MM:SS[.mmm]") if $T0 !~ $tre;
    abort("ABBRUCH: ungueltiges Zeitformat fuer T1='$T1', erwartet HH:MM:SS[.mmm]") if $T1 !~ $tre;
    abort("ABBRUCH: --recorder-seconds muss numerisch sein (erhalten: '$o{recorder_seconds}')")
        if $o{recorder_seconds} ne '' && $o{recorder_seconds} !~ /^[0-9]+(?:\.[0-9]+)?$/;
    abort("ABBRUCH: --daemon-end-epoch muss eine Epoche in Sekunden sein (erhalten: '$o{daemon_end_epoch}')")
        if $o{daemon_end_epoch} ne '' && $o{daemon_end_epoch} !~ /^[0-9]+(?:\.[0-9]+)?$/;

    my $mac_lower = lc $mac;
    my $daemon_log = $o{daemon_log};
    if ($daemon_log eq '') {
        my $flat = $mac_lower;
        $flat =~ s/://g;
        $daemon_log = "/var/lib/squeezeboxserver/cache/spoton/$flat-soloist.log";
    }

    my $date_short = '';
    if ($o{date} ne '') {
        abort("ABBRUCH: ungueltiges --date Format '$o{date}', erwartet YYYY-MM-DD")
            if $o{date} !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/;
        $date_short = substr($o{date}, 2);
    }

    my $sudo_bin = (defined $ENV{SUDO_BIN} && length $ENV{SUDO_BIN}) ? $ENV{SUDO_BIN} : 'sudo';
    my $stat_bin = (defined $ENV{STAT_BIN} && length $ENV{STAT_BIN}) ? $ENV{STAT_BIN} : 'stat';

    # sudo-Gate VOR jedem Daemon-Log-Zugriff und vor jeder Teilausgabe.
    abort('ABBRUCH: sudo -n schlaegt fehl fuer Daemon-Log-Zugriff -- keine halben Belege')
        unless run_quiet($sudo_bin, '-n', 'true');

    my ($t0s) = parse_hms($T0);
    my ($t1s) = parse_hms($T1);
    abort("ABBRUCH: T1 ($T1) liegt rechnerisch vor T0 ($T0) -- negatives Fenster") if $t1s < $t0s;

    my $win_start = $t0s - 2;
    my $win_end   = $t1s + 5;
    my %ctx = (win_start => $win_start, win_end => $win_end,
               date_short => $date_short, date => $o{date}, mac_lower => $mac_lower);

    my @mid;
    push @mid, '!! Der Fensteranfang liegt rechnerisch VOR 00:00:00 (T0-2s) und wurde auf 00:00:00 geklemmt -- Zeilen des Vortags werden NICHT erfasst.'
        if $win_start < 0;
    push @mid, '!! Das Fensterende liegt rechnerisch NACH 24:00:00 (T1+5s) -- Zeilen des Folgetags werden NICHT erfasst.'
        if $win_end > 86400;

    my @out;
    push @out, '=== extract-run.pl Belegblock ===';
    push @out, "MAC: $mac", "T0: $T0", "T1: $T1";
    push @out, sprintf('Fenster (lokale Zeit): %s .. %s  (T0-2s .. T1+5s)',
                       fmt_hms($win_start), fmt_hms($win_end));
    push @out, join(' ', @mid) if @mid;
    push @out, "Zeitbasis: ANNAHME (vom Skript NICHT vorausgesetzt, sondern unten geprueft): server.log, Daemon-Log und Recorder-ts tragen dieselbe LOKALE Zeit -- AUSSER den datumslosen UTC-Tickerzeilen des aktuellen Soloist-Builds (\"HH:MM:SS.mmm [f:N ...] ...\"), die per Systemzeitzone auf lokal umgerechnet und je Zeile als [UTC->lokal ...] markiert werden (WR-11, round 3). Laeuft LMS unter TZ=UTC (Container-Standard), waere die Annahme fuer die UEBRIGEN Quellen falsch -- siehe Abschnitt 'Zeitbasis-Selbsttest'.";
    push @out, "Quelle server.log: $o{server_log}";
    push @out, "Quelle Daemon-Log: $daemon_log";
    push @out, $o{recorder} ne '' ? "Quelle Recorder: $o{recorder}" : 'Quelle Recorder: NICHT ANGEGEBEN';
    push @out, '';

    # ---------------- server.log ----------------
    abort("ABBRUCH: server.log nicht lesbar: $o{server_log}") unless -r $o{server_log};
    open my $sfh, '<', $o{server_log}
        or abort("ABBRUCH: server.log nicht lesbar: $o{server_log} ($!)");
    my ($srv_win, $srv_agg) = scan_log(source => 'server', fh => $sfh, %ctx);
    close $sfh;

    if (!-s $o{server_log}) {
        push @out, "!! server.log hat 0 Bytes: $o{server_log} -- KEIN server.log-Beleg vorhanden (das Fenster ist nicht geprueft, nicht leer).";
    }
    else {
        report_coverage(\@out, 'server.log', $srv_agg, \%ctx);
    }
    push @out, '';

    my %sdays;
    $sdays{ $_->{day} } = 1 for @$srv_win;
    my @sdays = sort keys %sdays;
    if (!$date_short && @sdays > 1) {
        push @out, sprintf('!! MEHRDEUTIG: Treffer aus mehreren Kalendertagen im selben HH:MM:SS-Fenster gefunden: %s. T0/T1 sind reine Uhrzeiten ohne Datum -- mit --date YYYY-MM-DD auf einen Tag einschraenken.',
                           join(',', @sdays));
        push @out, '';
    }

    classify_records($srv_win, \@SRV_CATS);
    emit_categories(out => \@out, recs => $srv_win, cats => \@SRV_CATS,
                    t1 => $t1s, win_start => $win_start, win_end => $win_end,
                    mac_note => 1, mark_day => 0);

    my @suncat = grep { !@{ $_->{cats} } } @$srv_win;
    my $smine  = grep { $_->{raw} =~ /\Q$mac_lower\E/i } @suncat;
    push @out, sprintf('[%d von %d server.log-Fensterzeilen fallen in keine der Kategorien und sind oben NICHT aufgefuehrt; davon %d mit der MAC %s]',
                       scalar @suncat, scalar @$srv_win, $smine, $mac_lower);
    push @out, '';

    emit_window_gate(\@out, $srv_win, $mac_lower);

    # ---------------- Daemon-Log ----------------
    # 84-22 splice fix: erster Durchlauf = Tagesrekonstruktion (daemon_day_plan), zweiter = die Fensterzeilen
    my ($day_scan, $day_plan, $day_end, $day_end_src) = (undef, undef, undef, '-');
    {
        my ($pfh) = open_pipe_quiet($sudo_bin, '-n', 'cat', $daemon_log);
        if (defined $pfh) { $day_scan = daemon_day_plan($pfh); close($pfh); }
    }
    if ($o{daemon_end_epoch} ne '') { ($day_end, $day_end_src) = ($o{daemon_end_epoch} + 0, '--daemon-end-epoch'); }
    elsif ($day_scan && $day_scan->{groups} >= 2) {
        $day_end = daemon_end_epoch($daemon_log, $sudo_bin);
        $day_end_src = defined $day_end ? 'mtime' : 'keiner';
    }
    $day_plan = finish_day_plan($day_scan, $day_end)
        if $day_scan && $day_scan->{groups} && ($day_scan->{groups} >= 2 || $o{daemon_end_epoch} ne '');
    my ($dfh, $dpid) = open_pipe_quiet($sudo_bin, '-n', 'cat', $daemon_log);
    my ($dmn_win, $dmn_agg, $attach_all) = ([], {}, []);
    my $daemon_ok = 0;
    if (defined $dfh) {
        ($dmn_win, $dmn_agg, $attach_all) = scan_log(source => 'daemon', fh => $dfh, %ctx, day_plan => $day_plan);
        $daemon_ok = close($dfh) ? 1 : 0;
    }
    if (!$daemon_ok) { $dmn_win = []; $attach_all = []; }

    if ($daemon_ok) {
        if (($dmn_agg->{bytes} || 0) == 0) {
            push @out, "!! Daemon-Log hat 0 Bytes: $daemon_log -- KEIN Daemon-Beleg vorhanden. Der Daemon-Abschnitt unten ist NICHT GEPRUEFT, nicht 'still'.";
        }
        else {
            report_coverage(\@out, 'Daemon-Log', $dmn_agg, \%ctx);
            push @out, day_plan_note($day_scan, $day_plan, $day_end_src);
        }
        push @out, '';
    }
    else {
        push @out, "!! Daemon-Log nicht lesbar/nicht vorhanden: $daemon_log -- Daemon-Log-Abschnitt NICHT GEPRUEFT";
        push @out, '';
    }

    my $mark_day = 0;
    if ($daemon_ok && @$dmn_win) {
        my %dd;
        $dd{ $_->{day} } = 1 for @$dmn_win;
        my @days = sort { ($a eq q{?}) <=> ($b eq q{?}) || $a cmp $b } keys %dd;
        my $unknown = grep { $_->{day} eq '?' } @$dmn_win;
        push @out, $day_plan
            ? sprintf('Daemon-Log Tagesbezug: [fakepulse ...]-Zeilen und die datumslosen UTC-Tickerzeilen tragen selbst KEIN Datum; ihr Tag ist aus der Chronologie der Datei rekonstruiert (Tagesrekonstruktion oben, 84-22 splice fix), nicht aus --date und nicht aus der letzten datierten Zeile. Im Fenster vertretene Tage: %s.',
                      @days ? join(',', @days) : 'keine')
            : sprintf('Daemon-Log Tagesbezug: [fakepulse ...]-Zeilen tragen selbst KEIN Datum; ihr Tag ist ABGELEITET aus der letzten datierten Zeile davor (Regel 3, unveraendert). Die datumslosen UTC-Tickerzeilen des aktuellen Builds ("HH:MM:SS.mmm [f:N ...] ...") tragen ebenfalls kein Datum, ihr Tag ist stattdessen aus --date abgeleitet (WR-11, round 3). Im Fenster vertretene Tage: %s.',
                           @days ? join(',', @days) : 'keine');
        if (@days > 1) {
            $mark_day = 1;
            if (!$date_short) {
                push @out, sprintf('!! MEHRDEUTIG (Daemon-Log): Treffer aus mehreren Kalendertagen im selben HH:MM:SS-Fenster: %s. Das Daemon-Log ist nicht rotiert -- mit --date YYYY-MM-DD auf einen Tag einschraenken. Jede Zeile unten traegt deshalb ihren Tag als [TAG ...]-Praefix.',
                                   join(',', @days));
            }
            else {
                # N-CR-01 (Teilbefund): "mit --date einschraenken" darf nicht
                # geraten werden, wenn --date gesetzt IST.
                push @out, sprintf('!! MEHRDEUTIG (Daemon-Log): trotz --date %s sind mehrere Tageszuordnungen im Fenster vertreten: %s. Zeilen, deren Tag nicht ableitbar ist ("?"), werden NICHT weggefiltert -- eine weitere --date-Einschraenkung ist dafuer kein Mittel. Jede Zeile unten traegt ihren Tag als [TAG ...]-Praefix.',
                                   $o{date}, join(',', @days));
            }
        }
        if ($unknown > 0) {
            $mark_day = 1;
            push @out, sprintf('!! %d Daemon-Zeile(n) im Fenster stehen VOR der ersten datierten Zeile der Datei -- ihr Kalendertag ist nicht ableitbar und wurde NICHT gefiltert. Sie sind unten mit [TAG ?] markiert.',
                               $unknown);
        }
        # WR-06: Tagesabgleich ZWISCHEN den Quellen -- die MEHRDEUTIG-Zeilen
        # oben pruefen nur INNERHALB eines Fensters.
        push @out, day_crosscheck(\@sdays, \@days, $date_short, $o{date});
        # Die Datei-Reihenfolge muss nicht chronologisch sein (Daemon-Neustarts
        # haengen an dieselbe Datei an).
        my $chrono = 1;
        for my $i (1 .. $#$dmn_win) {
            my ($p, $c) = ($dmn_win->[$i - 1], $dmn_win->[$i]);
            my $cmp = daykey($p->{day}) cmp daykey($c->{day});
            $cmp = $p->{epoch} <=> $c->{epoch} if $cmp == 0;
            if ($cmp > 0) { $chrono = 0; last; }
        }
        push @out, '!! Die Daemon-Fensterzeilen stehen in der Datei NICHT chronologisch (Daemon-Neustart o.ae.). Die Ausgabe unten ist nach Tag und Zeit sortiert; die Datei-Reihenfolge weicht davon ab.'
            unless $chrono;
        push @out, '';
        my @sorted = sort {
            daykey($a->{day}) cmp daykey($b->{day})
            || $a->{epoch} <=> $b->{epoch}
            || $a->{idx} <=> $b->{idx}
        } @$dmn_win;
        $dmn_win = \@sorted;
    }

    my ($uf_count, $ws_count) = (0, 0);
    if ($daemon_ok) {
        classify_records($dmn_win, \@DMN_CATS,
                         [ { name => 'underflow', pat => $UNDERFLOW_PAT },
                           { name => 'write_summary', pat => $WRITE_SUM_PAT } ]);
        emit_categories(out => \@out, recs => $dmn_win, cats => \@DMN_CATS,
                        t1 => $t1s, win_start => $win_start, win_end => $win_end,
                        mac_note => 0, mark_day => $mark_day);
        $uf_count = emit_underflow(\@out, $dmn_win, $o{full}, $mark_day);
        $ws_count = emit_write_summary(out => \@out, recs => $dmn_win, t0 => $t0s,
                                      t1 => $t1s, full => $o{full}, mark_day => $mark_day);
        my @duncat = grep { !@{ $_->{cats} } && !@{ $_->{noise} } } @$dmn_win;
        push @out, sprintf('[%d von %d Daemon-Fensterzeilen fallen in keine der Kategorien und sind oben NICHT aufgefuehrt]',
                           scalar @duncat, scalar @$dmn_win);
        push @out, '';
    }

    # Fenster ohne jede Signalzeile (N-WR-02: Rauschkategorien zaehlen mit,
    # sonst behauptet der Banner "nichts gefunden, Parameter pruefen", waehrend
    # der Daemon im Fenster nachweislich protokolliert hat).
    my $srv_sig = grep { @{ $_->{cats} } } @$srv_win;
    my $dmn_sig = grep { @{ $_->{cats} } } @$dmn_win;
    if ($srv_sig == 0 && $dmn_sig == 0) {
        if ($uf_count + $ws_count == 0) {
            unshift @out, '!!! WARNUNG: In diesem Fenster wurde KEIN einziges bekanntes Ereignis in server.log oder Daemon-Log gefunden -- MAC/T0/T1 pruefen.', '';
        }
        else {
            unshift @out, sprintf('!!! WARNUNG: In diesem Fenster wurde KEINE Signalzeile (Attach/Flush/Arm/Fenster-Tor/INSTR/Ticker/...) gefunden, wohl aber Rauschzeilen des Daemons (underflow=%d, write_summary=%d) -- der Daemon hat im Fenster protokolliert, die gesuchten Ereignisse fehlen darin. MAC/T0/T1 pruefen, bevor daraus eine Abwesenheit gelesen wird.',
                                  $uf_count, $ws_count), '';
        }
    }

    emit_timebase(out => \@out, daemon_ok => $daemon_ok, srv_recs => $srv_win,
                  attach => $attach_all, date_short => $date_short);

    my $rec_stats = section_recorder(
        out => \@out, recorder => $o{recorder}, stat_bin => $stat_bin,
        win_start => $win_start, win_end => $win_end, t0 => $t0s, t1 => $t1s,
        t1_label => $T1, recorder_seconds => $o{recorder_seconds},
    );

    # ---------------- Abgeleitete Felder ----------------
    push @out, '--- Abgeleitete Felder (Zeitstempel-Differenzen, kein Verdikt) ---';
    push @out, sprintf('Paarungsregel: ANKER = Vorkommen innerhalb T1 +/- %ss; PARTNER = Vorkommen innerhalb %ss um den ANKER.', $PAIR_SPAN, $PAIR_SPAN);
    push @out, 'Liegt kein Anker in T1 +/- ' . $PAIR_SPAN . 's, ist die Zuordnung mehrdeutig oder ist der Anker von Partnern auf BEIDEN Seiten eingerahmt, wird KEIN Delta ausgegeben, sondern der Grund genannt.';

    my $attach_recs = records_with($dmn_win, 'client-attach: new /stream client fd=');
    my $flush_recs  = records_with($dmn_win, 'pa_stream_flush(stream=');
    my $arm_recs    = records_with($dmn_win, 'seek_arm: armed=');
    my $post_recs   = records_with($srv_win, 'Control: loopback POST /seek-arm sent');
    my $get_recs    = records_with($srv_win, 'Request: GET /stream');

    emit_delta(out => \@out, t1 => $t1s, mode => 'after', note => '',
               alabel => 'client-attach',      arecs => $attach_recs,
               plabel => 'pa_stream_flush',    precs => $flush_recs);
    emit_delta(out => \@out, t1 => $t1s, mode => 'near',
               note => ' (t(Partner)-t(Anker), Vorzeichen zeigt Reihenfolge, keine Wertung; Request: GET-Zeilen tragen keine MAC)',
               alabel => 'loopback POST sent', arecs => $post_recs,
               plabel => 'Request: GET',       precs => $get_recs);
    emit_delta(out => \@out, t1 => $t1s, mode => 'near', note => '',
               alabel => 'seek_arm: armed=',   arecs => $arm_recs,
               plabel => 'pa_stream_flush',    precs => $flush_recs);
    push @out, '';

    emit_leftovers(
        out => \@out,
        sources => [
            { label => 'server.log', agg => $srv_agg, win => $srv_win, accessible => 1 },
            { label => 'Daemon-Log', agg => $dmn_agg, win => $dmn_win, accessible => $daemon_ok },
        ],
        recorder_stats => $rec_stats,
    );

    # ---------------- Redaktion (ueber den fertigen Puffer) ----------------
    my $redacted = grep { $_ =~ $REDACT_RE } @out;
    for my $l (@out) {
        $l =~ s/spak_[A-Za-z0-9_-]*/[REDACTED: spak_...]/g;
        $l =~ s/auth_data[^ ]*/[REDACTED: auth_data...]/g;
        $l =~ s/Bearer [A-Za-z0-9._-]+/[REDACTED: Bearer ...]/g;
    }
    push @out, $redacted == 0
        ? '=== Redaktion: 0 Zeilen redigiert ==='
        : "=== Redaktion: $redacted Zeile(n) redigiert ===";

    my $text = join("\n", @out) . "\n";
    if ($o{out} ne '') {
        open my $ofh, '>', $o{out} or abort("ABBRUCH: --out $o{out} nicht schreibbar: $!");
        print $ofh $text;
        close $ofh;
    }
    print $text;
    return 0;
}

sub daykey { my ($d) = @_; return $d eq '?' ? "\x7f" : $d; }

# day_list(@days) -- eindeutige Tagesliste, "?" zuletzt (WR-06/Anzeige).
sub day_list {
    my %d;
    $d{$_} = 1 for grep { defined } @_;
    return sort { ($a eq q{?}) <=> ($b eq q{?}) || $a cmp $b } keys %d;
}

# day_compatible($a, $b) -- duerfen zwei Datensaetze ueber die Quellengrenze
# gepaart werden? "?" heisst "Tag nicht ableitbar", NICHT "anderer Tag" --
# ein unbekannter Tag schliesst deshalb nicht aus (WR-06).
sub day_compatible {
    my ($x, $y) = @_;
    return 1 if !defined $x || !defined $y;
    return 1 if $x eq '?' || $y eq '?';
    return $x eq $y ? 1 : 0;
}

exit(main(@ARGV)) unless caller;

1;

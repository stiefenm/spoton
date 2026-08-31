# Phase 78: Browse + Connect Reintegration (Perl) - Pattern Map

**Mapped:** 2026-08-31
**Files analyzed:** 9 (alle Modifikationen — Refactor-Phase, keine neuen Dateien)
**Analogs found:** 9 / 9 (Analoga sind überwiegend In-Repo-Muster in denselben oder Schwester-Dateien)

**Zeilenreferenzen:** Working-Tree-Stand dieser Session (uncommitteter Spike-2-Stand,
identisch mit RESEARCH.md). Alle zitierten Pfade sind git-tracked (per `git ls-files`
verifiziert). Nach dem Wave-0-Commit bleiben die Zeilen gültig, bis die Removal-Waves
selbst sie verschieben.

## File Classification

| Modifizierte Datei | Role | Data Flow | Closest Analog (Muster-Quelle) | Match Quality |
|--------------------|------|-----------|-------------------------------|---------------|
| `Plugins/SpotOn/ProtocolHandler.pm` | protocol-handler (LMS) | streaming / request-response | eigener librespot-Connect-Branch + `canDirectStreamSong` seek-append | exact (in-file) |
| `Plugins/SpotOn/Connect.pm` | event-subscriber/controller | event-driven | eigene source-marked `playlist play`-Sites + `_sendControlCommand`-Dispatch | exact (in-file) |
| `Plugins/SpotOn/Unified/SoloistWS.pm` | WS-client/service | event-driven (WS→Dispatch) | eigenes `_signalBoundary` + `_onPlaybackChanged`-Status-Dispatch | exact (in-file) |
| `Plugins/SpotOn/Plugin.pm` | watchdog/utility | event-driven (Timer) | eigene Watchdog-Gates (Phase 27) + `isSpotifyConnect`-Guard aus Connect.pm | exact |
| `t/29_soloist_browse.t` | test (Rewrite) | stub-harness dispatch | eigener `write_stub`-Harness + `Test::FakeSoloistWs` | exact (in-file) |
| `t/31_soloist_ws.t` | test (Modify) | stub-harness event | eigener Timer-Recording-Stub + `%FAKE_VALUES`-Prefs | exact (in-file) |
| `t/37_connect_lifecycle.t` | test (Modify) | source-analysis (grep-gate) | eigenes Grep-Gate-Idiom (aus t/10 etabliert) | exact (in-file) |
| `t/32_soloist_events.t` | test (Minor) | stub-harness event | t/31-Harness-Stil | exact |
| `Plugins/SpotOn/custom-convert.conf` | config | transform | voraussichtlich No-op (`soc pcm * *` deckt bounded URL, s. RESEARCH) | exact |

## Pattern Assignments

### `Plugins/SpotOn/ProtocolHandler.pm` (protocol-handler, streaming)

#### A) Bounded-URL-Bau in `canDirectStream` — Analog: eigener librespot-Browse-Branch

Die neue URL-Form `http://$host:$port/stream/track?uri=spotify:$type:$id&start=$offset`
ersetzt den nackten `/stream`-Bau. Muster-Quelle ist die Kombination aus dem
bestehenden Soloist-Branch (Gates BEHALTEN) und dem librespot-Branch (URL mit
Track-Bestandteilen):

**Soloist-Branch, bleibt strukturell erhalten — nur URL-Zeile ändert sich**
(`ProtocolHandler.pm:225-275`, URL-Bau 265-268):
```perl
if (_useSoloist() && $url && $url =~ m{^spoton://(?:track|episode):}) {
    my $browseClient = $client->can('master') ? $client->master : $client;
    # WR-05 Proxy-Gate (232-235), D-06 resolveSoloistFormat-Gate (251-257),
    # synced-Gate (261-264) BLEIBEN unverändert.
    ...
    my $host   = Slim::Utils::Network::serverAddr();
    my $ds_url = "http://$host:" . $helper->_streamPort . "/stream";   # ← ÄNDERN
    $log->warn("[DIAG] canDirectStream: soloist browse url=$ds_url") if $prefs->get('diagnosticMode');
    return $ds_url;
}
```

**URL-mit-Track-Bestandteilen-Muster** (librespot-Browse-Branch, `ProtocolHandler.pm:296-311`):
```perl
if ($url && $url =~ m{^spoton://(track|episode):([A-Za-z0-9]+)$}) {
    my $contentType = $1;
    my $trackId = $2;
    ...
    my $ds_url = "http://$host:" . $helper->_streamPort . "/$contentType/$trackId";
```
→ Für die bounded URL Capture-Groups genauso extrahieren und als Query-Params
anhängen: `"/stream/track?uri=spotify:$1:$2&start=0"`. **Achtung Regex-Falle**
(RESEARCH): `canDirectStreamSong` (Z. 199) hängt `?start_position=` nur bei
`m{/(?:track|episode)/}` an — `/stream/track?` matcht das NICHT. Seek-Offset
daher direkt im Soloist-Branch als `&start=$offset` + `$song->startOffset($offset)`.

**Seek-Offset-Append-Muster** — Analog `canDirectStreamSong` (`ProtocolHandler.pm:192-206`):
```perl
if ($directUrl =~ m{/(?:track|episode)/} && $song->seekdata && $song->seekdata->{'timeOffset'}) {
    my $offset = $song->seekdata->{'timeOffset'};
    $directUrl .= '?start_position=' . $offset;
    $song->startOffset($offset);
}
```
→ Gleiches Idiom (seekdata lesen, Query anhängen, startOffset setzen) für den
Soloist-Zweig kopieren; nur Query-Name `start=` und die Match-Bedingung anpassen.

#### B) getNextTrack-Ersatz (D-17-Gate weg) — Analog: WS-Check + Fehlerpfad des heutigen Blocks

Der zu ersetzende Block ist `ProtocolHandler.pm:729-844`. Aus ihm BEHALTEN
(Muster kopieren): Samplesize-Hints, WS-Verfügbarkeits-Check, errorCb-Idiom:

**Samplesize-Hint-Muster** (`ProtocolHandler.pm:729-736`, identisch im Connect-Zweig 686-693):
```perl
if (_useSoloist() && $url =~ m{^spoton://(track|episode):([A-Za-z0-9]+)$}) {
    my ($type, $id) = ($1, $2);
    my $track = $song->track;
    if ($track) {
        $track->samplesize(32)    if $track->can('samplesize');
        $track->samplerate(44100) if $track->can('samplerate');
        $track->channels(2)       if $track->can('channels');
    }
```

**WS-Check + errorCb-Muster** (`ProtocolHandler.pm:745-756`):
```perl
my $client = $song->master;
require Plugins::SpotOn::Unified::DaemonManager;
my $helper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($client);
my $ws = ($helper && $helper->can('_ws')) ? $helper->_ws : undef;

unless ($ws && $ws->connected) {
    $errorCb->('PROBLEM_OPENING', 'Soloist daemon not ready');
    return;
}
```

**Neu statt Gate** (RESEARCH Pattern 1): Connect-Ownership-/lastTrackId-Vergleich,
dann `$ws->sendCommand('play', uri => "spotify:$type:$id") or do { $errorCb->(...); return; }`,
danach sofort `$successCb->()`. Das `sendCommand`-Rückgabewert-Check-Idiom stammt
aus dem heutigen WR-03-Block (`ProtocolHandler.pm:778-785`).

**Duration-aus-Cache-Muster** (bleibt, `ProtocolHandler.pm:711-716`):
```perl
my $browseMeta = $cache->get('spoton_meta_' . md5_hex($url));
if ($browseMeta && $browseMeta->{duration} && $browseMeta->{duration} > 0) {
    $song->duration($browseMeta->{duration});
}
```

#### C) `new()` b3-Proxy-Block — gleiche URL-Umstellung

Analog ist der Block selbst (`ProtocolHandler.pm:592-610`): nur Z. 600
(`.../stream"`) auf die bounded Form ändern; Args-Substitutions-Idiom
`$args = { %$args, url => $httpUrl };` unverändert kopieren.

#### D) getSeekData / canDoAction — Analog: eigener Connect-Zweig

Bei Discretion-Empfehlung „LMS-nativer Seek-Restart" (RESEARCH Pitfall 5):
Soloist-Browse-`undef`-Branch (`ProtocolHandler.pm:1141-1144`) entfernen →
Fall-through auf das bestehende `return { timeOffset => $newtime };` (Z. 1146).
`_hasActiveSoloistBrowseSession` (Z. 1178-1188) und seine Verwendung in
`canDoAction('rew')` (Z. 1162) entfernen; der Connect-Teil des `canDoAction`-Guards
(`isSpotifyConnect($client)`) bleibt als Muster stehen.

---

### `Plugins/SpotOn/Connect.pm` (event-subscriber, event-driven)

#### A) D-04 Backend-Dispatch der Playlist-Einträge — Analog: die vier bestehenden Dispatch-Sites

Das zu kopierende source-marked-Play-Idiom (`Connect.pm:1274-1280`, identisch
1097-1103, 1374-1389, 1516-1523):
```perl
my $ts      = int(Time::HiRes::time() * 1000);
my $playReq = Slim::Control::Request->new($client->id, [
    'playlist', 'play',
    sprintf("spoton://connect-%u", $ts)
]);
$playReq->source(__PACKAGE__);
$playReq->execute();
```
→ Für Soloist wird nur das URL-Argument ersetzt: `"spoton://track:$trackId"`
(trackId liegt an allen vier Sites bereits vor — `eventTrackUri`-Zeilen davor).
librespot-Pfad bleibt byte-identisch. **Backend-Weiche** nach dem etablierten
isa-Dispatch-Muster (s. Shared Patterns).

#### B) Unified Pause/Seek-Forwarding — Analog: `_sendControlCommand`-Endpoint-Map

Das Removal-Target `_onPause`-Browse-Block (Z. 575-632) braucht einen unified
Ersatz (Pitfall 4). Muster-Quelle ist der bestehende Soloist-Zweig von
`_sendControlCommand` (`Connect.pm:296-348`):
```perl
my $helper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($client->id);
if ($helper && $helper->isa('Plugins::SpotOn::Unified::SoloistDaemon')) {
    my %endpointToCommand = (
        '/control/pause'  => 'pause',
        '/control/play'   => 'play',      # no uri: resume semantics
        ...
    );
    my $ws   = $helper->_ws;
    my $sent = ($ws && $ws->connected) ? $ws->sendCommand($command, %params) : 0;
    ...
    _sendControlFallback($client, $endpoint, $body);   # D-15 Web-API-Fallback
```
→ Pause-Forwarding NICHT neu bauen: `_sendControlCommand($client, '/control/pause')`
bzw. `'/control/play'` aufrufen, sobald das neue Ownership-Kriterium auch
Soloist-Browse-Songs erfasst. `play` ohne uri = resume (Pitfall 9).

#### C) Seek-Forwarding-Debounce — Analog: `_onSeek`-Connect-Zweig

(`Connect.pm:791-801` + `_seekPositionFromRequest` 234-248):
```perl
my $position   = _seekPositionFromRequest($client, $request);
my $positionMs = int($position * 1000);
Slim::Utils::Timers::killTimers($client, \&_bufferedSeek);
Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + SEEK_DEBOUNCE, \&_bufferedSeek, $positionMs);
```
→ Bei Vereinheitlichung ersetzt dieser Zweig den `_bufferedBrowseSeek`-Zwilling
(Z. 780-789, 804-820), der gelöscht wird.

#### D) Neues Soloist-Ownership-Kriterium — Analoga für Umbau statt Löschung

- **D-16-Release-Idiom** (`Connect.pm:537-558`) — Struktur behalten (Claim-Release
  + `pendingConnect => 0` + GH-#151-Power-Discard), nur das Kriterium
  `unless ($url =~ m{spoton://connect-})` durch das neue ersetzen
  (RESEARCH OQ 1: un-marked newsong mit URI ≠ `ws->lastTrackId`).
- **Session-End-Release** (`Connect.pm:1423-1445`, `stop 'inactive'`) — bleibt der
  autoritative Release-Pfad, Muster unverändert:
```perl
if (($request->getParam('_p2') || '') eq 'inactive') {
    ...
    my $pauseReq = Slim::Control::Request->new($client->id, ['pause', 1]);
    $pauseReq->source(__PACKAGE__);
    $pauseReq->execute();
    ...
    _restorePowerAfterConnect($client);
```
- **`_isLiveConnectStream`** (`Connect.pm:126-139`) — track->url-first-Extraktion
  (Phase-44-Pattern) als Vorlage für das Soloist-Äquivalent
  („aktueller Song == zuletzt announced Daemon-Track"):
```perl
my $song = $client->playingSong();
return 0 unless $song;
my $url = $song->track->url || $song->streamUrl || '';
```

#### E) Echo-Check (Pitfall 1) — Analog: Source-Marking + Grace-Idiome

Vorbilder im selben File: Top-of-Function-Source-Guard (`Connect.pm:567`):
```perl
return if $request->source && $request->source eq __PACKAGE__;
```
und das Grace-Window-Idiom (`Connect.pm:1450`,
`Time::HiRes::time() - ($client->pluginData('connectStartTime') || 0) < CONNECT_START_GRACE`).
Der neue Bestätigungs-Check im 'start'/'change'-Handler vergleicht die announced
URI gegen den aktuellen LMS-Song (streamingSong UND playingSong prüfen, A3) —
das URL-Extraktions-Idiom dafür ist `_isLiveConnectStream` oben.

#### F) Restart Gate — behalten, Muster unverändert

(`Connect.pm:1201-1225`) — nur die playReq-URL im nicht-unterdrückten Pfad wird
per D-04 umgestellt (Pattern A). Der Uptime-Check bleibt:
```perl
my $daemonUptime = Plugins::SpotOn::Unified::DaemonManager->uptime($client->id) || 0;
if (!$client->isPlaying && $daemonUptime > 0 && $daemonUptime < RESTART_START_GRACE) {
```

---

### `Plugins/SpotOn/Unified/SoloistWS.pm` (WS-client, event-driven)

#### A) D-02: Boundary auf 'stopped' — Analog: `_signalBoundary`-Aufruf in `_onTrackChanged`

Bestehender Trigger (`SoloistWS.pm:671-679`, Aufruf VOR aller Klassifikation):
```perl
# track_changed is the ONLY track-boundary signal available ...
$self->_signalBoundary;
```
Implementierung (bleibt, `SoloistWS.pm:735-758`) — eval-guarded Fire-and-Forget:
```perl
my $daemon = $self->daemon or return;
my $httpPort = $daemon->_streamPort or return;
eval {
    my $sock = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1', PeerPort => $httpPort,
        Proto => 'tcp', Timeout => 1,
    );
    if ($sock) {
        print $sock "POST /boundary HTTP/1.0\r\nConnection: close\r\n\r\n";
        close($sock);
    }
};
```
→ Neuer zweiter Aufrufort in `_onPlaybackChanged`, am ROHEN `$msg->{status}`
(`my $status = $msg->{status} // '';`, Z. 874) — NACH dem deactivating-Guard
(Z. 884-889), VOR der Paused+Stopped-Kollaps-Übersetzung (Z. 984-988):
```perl
$self->_signalBoundary if $status eq 'stopped';   # NUR 'stopped', nie 'paused'
```

#### B) Removal-Muster: `_onTrackChanged` nach Browse-Route-Entfernung

Nach Löschen von Z. 688-690 (`return $self->_onBrowseTrackChanged(...)`) läuft
jedes Event durch den bestehenden Connect-Pfad — der pflegt `lastTrackId`
(Z. 692-697), was Pattern 1 in ProtocolHandler braucht:
```perl
my $prevId = $self->lastTrackId;
return if defined $prevId && $newId eq $prevId;   # Re-Announcement-Dedup
$self->lastTrackId($newId);
```

#### C) `_emitAllowed` nach Gate-Entfernung — Pref-Check bleibt

(`SoloistWS.pm:1432-1448`): Zeile `return 0 if $self->browseSession;` löschen,
der `enableSpotifyConnect`-Pref-Check (Z. 1445-1447) bleibt unverändert.

#### D) Accessor-Removal — Analog: mk_accessor-Liste

(`SoloistWS.pm:84-110`): die sieben browse*-Accessors aus der `mk_accessor(rw => ...)`-
Liste streichen; Init-Zeilen 222-223 mit. Kein Ersatz nötig.

---

### `Plugins/SpotOn/Plugin.pm` (watchdog guards)

**Keine Löschung — Guard-Ergänzung** (Pitfall 3). Analog: das bestehende
Gate-Idiom an allen fünf Stellen (Z. 3942, 3952, 3973, 4011, 4038):
```perl
return unless $url =~ m{^spoton://(?!connect-)};
```
→ Unter D-04 matcht das Soloist-Connect-Songs. Ergänzendes Guard-Muster aus
Connect.pm/ProtocolHandler kopieren (z. B. `ProtocolHandler.pm:676`):
```perl
require Plugins::SpotOn::Connect;
return if Plugins::SpotOn::Connect->isSpotifyConnect($client);
```
direkt nach dem URL-Gate an jeder der fünf Stellen (bzw. am neuen
Ownership-Kriterium, wenn der Planner es anders benennt). `_pauseGuardCheck`
(Z. 4011) nutzt `unless (...) { delete ...; return; }` — dort den Connect-Check
in dieselbe Bedingung integrieren.

---

### `t/29_soloist_browse.t` (test, Rewrite auf bounded Modell)

Harness-Analoga (alle in-file, wiederverwenden):

**write_stub-Harness** (`t/29:19-30`) + kontrollierbarer Prefs-Stub (`t/29:84-99`,
`%FAKE`-Hash mit `reset_backend()`).

**Helper-Double, blessed in echten Klassennamen** (`t/29:274-283`):
```perl
package Plugins::SpotOn::Unified::SoloistDaemon;
sub new { my ($class, %args) = @_; return bless { %args }, $class; }
sub alive       { return $_[0]->{alive} // 1; }
sub _streamPort { return $_[0]->{port}; }
sub _ws         { return $_[0]->{ws}; }
```

**FakeSoloistWs-Recorder** (`t/29:288-298`) — umbauen: browse*-Felder raus,
`lastTrackId` + `sendCommand`-Recorder rein (Wave-0-Gap aus RESEARCH):
```perl
package Test::FakeSoloistWs;
sub new { ... bless { connected => 1, lastTrackId => undef, sent => [], %args } ... }
sub connected   { return $_[0]->{connected}; }
sub lastTrackId { my $self = shift; $self->{lastTrackId} = shift if @_; return $self->{lastTrackId}; }
sub sendCommand { my ($self, $cmd, %p) = @_; push @{ $self->{sent} }, [$cmd, \%p]; return 1; }
```

**Assertion-Stil für die neue URL-Form** — Analog `t/29:317-319`:
```perl
my $result = $pkg->canDirectStream($client, 'spoton://track:abc123');
like($result, qr{^http://127\.0\.0\.1:39755/stream$}, "...");
```
→ neue Erwartung: `qr{^http://127\.0\.0\.1:39755/stream/track\?uri=spotify:track:abc123&start=0$}`.
Neue Fälle: getNextTrack-Dispatch ohne Gate (successCb synchron), Connect-Ownership-
No-Play-Fall (sent-Recorder leer), sendCommand-Fail → errorCb.

---

### `t/31_soloist_ws.t` (test, Modify)

Harness-Analoga in-file: `%FAKE_VALUES`-Prefs-Stub (`t/31:62-76`),
Timer-Recording-Stub (`t/31:84-96`, `@TIMERS` + manuelles `fire_timer`).

Neuer Boundary-Test (D-02): `_signalBoundary` per Method-Override zählen
(Muster: Recorder-Stub-Idiom des Files) und asserten —
feuert bei `_onTrackChanged` (immer) und bei `_onPlaybackChanged` mit rohem
`status => 'stopped'`, NICHT bei `'paused'`, NICHT während `deactivating`.
Browse-SM-Testblöcke (Emit-Gate 421-434, D-17-Recorder, 800ff) löschen.

---

### `t/37_connect_lifecycle.t` (test, Modify)

Analog: das etablierte Grep-Gate-Idiom des Files selbst (`t/37:30-40` slurp +
Block-Extraktion per Regex):
```perl
my ($suppress_block) = $connect =~ /(\$daemonUptime < RESTART_START_GRACE\).*?return;)/s;
ok($suppress_block, '...');
unlike($suppress_block, qr/'playlist',\s*'play'/, '...');
```
→ Neue D-04-Gates im selben Stil: 'start'/'change'-Blöcke extrahieren und
asserten, dass der Soloist-Zweig `spoton://track:` dispatcht und der
librespot-Zweig weiterhin `spoton://connect-%u` enthält; D-16-Blöcke (123-161)
durch Ownership-Kriterium-Gates ersetzen. Metadata-Bleed-Block (165-199,
uncommitted) BLEIBT.

---

### `t/32_soloist_events.t` + `custom-convert.conf`

- t/32: keine browseSession-Referenzen (RESEARCH-Grep) — höchstens neuer Fall
  „Emission ohne ehemaliges browseSession-Gate", im t/31-Harness-Stil.
- custom-convert.conf: voraussichtlich No-op (`soc pcm * *` + `getFormatForURL`
  Z. 134 `m{:\d+/stream\b}` deckt `/stream/track?...` bereits — `\b` matcht nach
  `stream`). Nur ggf. DEFERRED-Kommentar (Z. 21-22) aktualisieren.

## Shared Patterns

### Source-Marking (Loop-Prevention)
**Source:** `Connect.pm:1279` (Setzen), `Connect.pm:567` (Prüfen)
**Apply to:** alle neuen playlist-/stop-/pause-Dispatches in Connect.pm und
alle Subscriber-Eintrittspunkte
```perl
$playReq->source(__PACKAGE__);            # beim Dispatch
return if $request->source && $request->source eq __PACKAGE__;   # im Subscriber
```
Der Marker `PLUGIN_SPOTON_SOLOIST_BROWSE` (`Connect.pm:583`, `SoloistWS.pm:946`)
verschwindet mit der Browse-SM — Grep nach Restverwendungen vor Wave-2-Abschluss.

### Backend-Dispatch (Soloist vs. librespot)
**Source:** `Connect.pm:302-303`
**Apply to:** alle vier D-04-Sites, unified Pause/Seek-Forwarding
```perl
my $helper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($client->id);
if ($helper && $helper->isa('Plugins::SpotOn::Unified::SoloistDaemon')) { ... }
```
(ProtocolHandler nutzt stattdessen `_useSoloist()` — dort das bestehende Idiom
beibehalten; Windows-Constraint: librespot-Pfad nie verhaltensändern.)

### Master-Client-Normalisierung
**Source:** `Connect.pm:103`, `ProtocolHandler.pm:226`
**Apply to:** jeder neue Codepfad, der `$client` von außen bekommt
```perl
$client = $client->master if $client->can('master');
```

### DIAG-Logging
**Source:** `ProtocolHandler.pm:267`, `Connect.pm:329`
**Apply to:** neue Dispatch-/URL-Bau-Stellen (UAT-Korrelierbarkeit)
```perl
$log->warn("[DIAG] ...: mac=" . $client->id . " ...") if $prefs->get('diagnosticMode');
```

### sendCommand-Disziplin
**Source:** `SoloistWS.pm:394-414`
**Apply to:** getNextTrack-play, Pause/Seek-Forwarding
- `uri`-Params werden gegen `^spotify:(?:track|episode):[A-Za-z0-9]+$` validiert
  (Z. 397) — nur diese Form senden.
- `play` MIT uri = Track-Start, `play` OHNE uri = Resume (Pitfall 9).
- Rückgabewert prüfen (`or do { $errorCb->(...); return; }` bzw. D-15-Fallback).

### Eval-guarded Fire-and-Forget-I/O
**Source:** `SoloistWS.pm:741-757` (`_signalBoundary`)
**Apply to:** jeden weiteren Boundary-Trigger — exakt denselben Helper aufrufen,
keine Kopie anlegen.

## No Analog Found

Keine Datei ohne Analog — die Phase ist Umverdrahtung + Löschung in bestehenden
Dateien; jedes benötigte Muster existiert im Repo (RESEARCH „Don't Hand-Roll":
das größte Risiko sind übersehene Konsumenten der alten `connect-`-URL-Semantik,
nicht fehlende Vorbilder).

Einziges Muster OHNE direktes Repo-Vorbild: der **Echo-/Bestätigungs-Check**
(Pitfall 1, Volumio-`play_origin`-Analogon). Bausteine dafür sind vorhanden
(Source-Marking, `_isLiveConnectStream`-URL-Extraktion, `ws->lastTrackId`),
die Komposition ist neu — Planner muss sie aus den Shared Patterns oben
zusammensetzen und per t/37-Grep-Gate pinnen.

## Metadata

**Analog search scope:** `Plugins/SpotOn/` (ProtocolHandler.pm, Connect.pm,
Unified/SoloistWS.pm, Plugin.pm, custom-convert.conf), `t/` (29, 31, 32, 37, 03)
**Files scanned:** 10 (alle git-tracked, per `git ls-files` verifiziert;
keine gitignorierten Mirror-Pfade zitiert)
**Pattern extraction date:** 2026-08-31
**Grundlage:** 78-CONTEXT.md, 78-RESEARCH.md (zeilengenaues Removal-Inventar),
gezielte Reads der oben zitierten Zeilenbereiche in dieser Session

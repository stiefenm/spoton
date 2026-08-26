# Phase 73: Soloist Connect Mode - Research

**Researched:** 2026-08-26
**Domain:** Persistenter Soloist-Daemon (WebSocket-API, Connect-Registrierung, Audio-Transport) + LMS-Perl-Integration
**Confidence:** HIGH (WS-API und Perl-Stack empirisch verifiziert; Audio-Transport-Design MEDIUM — C-Implementierung folgt bewährtem Muster, aber Track-End-Semantik hat offene Punkte)

## Summary

Phase 73 ersetzt das Phase-72-Per-Track-Spawning durch einen persistenten Soloist-Daemon pro Player. Die Forschung hat alle vier RESEARCH-Aufträge (D-04 bis D-07) beantwortet — großteils mit **empirischer Verifikation gegen das echte Soloist-Binary in dieser Session**: Das WebSocket-API wurde live angesprochen (Handshake, `auth_state`-Event, Command-Format, Fehlerantworten mit dem LMS-gebündelten `Protocol::WebSocket` 0.26 — exakt der Stack, den das Plugin nutzen wird). Soloist registriert sich **nativ** als Spotify-Connect-Gerät (Dealer-WebSocket `connect-state`-Protokoll + lokales mDNS); Transfer-Playback braucht keinerlei LMS-seitige Web-API-Calls. Das Pairing pro Player reduziert sich auf "Gerät in der Spotify-App auswählen" — der SSH-Umweg aus Phase 72 entfällt architektonisch.

Für den Audio-Transport (D-04) ist die Empfehlung ein **HTTP-Streaming-Server innerhalb von fake-libpulse.so** — der einzige Code, den SpotOn im Soloist-Prozess kontrolliert (Soloist ist closed-source; ein Server "im Rust-Code wie bei librespot" ist bei Soloist nicht möglich, das funktionale Äquivalent im C-Stub aber schon). fake-libpulse empfängt bereits jedes PCM-Sample über `pa_stream_write()`; ein kleiner pthread-basierter HTTP/1.0-Server mit Ringpuffer liefert dieselbe `/stream`-Semantik wie der librespot-Fork (dessen `unified.rs` als validierte Blaupause dient). Nebeneffekte: die sox-Systemabhängigkeit entfällt (float32→S16LE-Konvertierung in C ist trivial), und die Ringpuffer-Bounded-Semantik löst das Realtime-Pacing sauber. Das data-dir-Lock-Problem verschwindet strukturell: der persistente Daemon hält den `.lock` (verifiziert im echten data-dir) dauerhaft — es gibt keine konkurrierenden Spawns mehr; Voraussetzung ist ein **eigenes data-dir pro Player**.

Für den Perl-WS-Client (D-05) ist die Empfehlung ein **eigener schlanker Client** auf Basis von `Protocol::WebSocket::Client` + `Slim::Networking::Select::addRead` (event-getrieben, non-blocking) — NICHT `Slim::Networking::SimpleWS`, dessen Error-Handler `exit` aufruft (würde den gesamten LMS-Prozess töten) und dessen Polling bis zu 1 s Latenz hat. `Protocol::WebSocket` ist erst ab **LMS 9.1.0** (2026-02-19) gebündelt; für LMS 8.x/9.0 muss das Plugin die reinen Perl-Module vendoren oder Soloist-Connect auf LMS ≥ 9.1 gaten (Entscheidung für Discuss/Planner, siehe Assumptions A1).

**Primary recommendation:** HTTP-Server in fake-libpulse.so (Audio) + eigener Protocol::WebSocket-Client an LMS' Select-Loop (Control/Events), Events auf das bestehende `spottyconnect`-Vokabular übersetzt — Connect.pm bleibt unangetastet die State-Maschine.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

#### Daemon-Modell
- **D-01:** Ein Soloist-Daemon pro Player (wie librespot). Jeder LMS-Player bekommt seinen eigenen Soloist-Prozess. Isoliert, stabiler bei Crash, passt zum bestehenden DaemonManager-Pattern. Vorbereitung für Per-Player-Backend in Phase 74. — **Reversibility:** costly — Umstellung auf Singleton erfordert Multiplexing-Logik und DaemonManager-Refactoring
- **D-02:** Daemon startet bei Player-Connect (wie librespot). Identisches Lifecycle-Pattern wie DaemonManager für librespot. Phase 71's D-09 Gate prüft Voraussetzungen (Binary, Key, Linux). — **Reversibility:** reversible
- **D-03:** Daemon handhabt Browse UND Connect. Browse-Wiedergabe wechselt von custom-convert.conf (Per-Track `--single-track`) zu WS-API-Befehlen an den persistenten Daemon. Löst das data-dir Lock-Problem für Gapless komplett. canDirectStream wechselt bei Soloist von 0 auf HTTP-URL (wenn HTTP-Server verfügbar). — **Reversibility:** costly — Rückbau auf Per-Track-Spawning erfordert Phase-72-Pfad wiederherstellen

#### Audio-Transport
- **D-04:** RESEARCH-AUFTRAG — Audio-Transport-Mechanismus für den persistenten Daemon. Status quo: Fake-libpulse greift PCM direkt per FD/Pipe ab. OOB Soloist: nur FIFO und Pipe. Ideal: HTTP-Server im Rust-Code bauen (wie bei librespot schon getan). Researcher soll Machbarkeit und Vor-/Nachteile evaluieren. Referenz: bestehende librespot HTTP-Streaming-Implementierung im SpotOn Rust-Code.

#### WebSocket Event-Mapping
- **D-05:** RESEARCH-AUFTRAG — WebSocket-Client-Implementierung. Researcher analysiert: (1) verfügbare Perl WebSocket-Bibliotheken im LMS-Kontext (IO::Socket, AnyEvent, gebundelte Module), (2) Soloist `--ws` API-Format (Endpoint, Event-Typen, Command-Format), (3) Architektur-Empfehlung (nativer Perl WS-Client in DaemonManager vs stdout-Proxy).
- **D-06:** RESEARCH-AUFTRAG — Event-Set abhängig von der WS-API-Analyse. Researcher dokumentiert verfügbare Events, Planner mappt auf LMS Player State. Ziel: volles Connect-Set (Play/Pause/Stop/Track-Change/Volume/Seek/Queue) soweit die API es hergibt.

#### Connect Transfer-Playback
- **D-07:** RESEARCH-AUFTRAG — Connect-Registrierung und Transfer-Mechanismus. Researcher analysiert wie Soloist sich als Spotify Connect Device anmeldet (nativ über eigene Registrierung vs LMS-gesteuert über Web API PUT /me/player).

### Claude's Discretion
- Sync Groups: wenn das DaemonManager-Pattern 1:1 auf Soloist übertragbar ist, direkt einbauen. Wenn spezielle Anpassungen nötig, nach Phase 74 verschieben.
- DaemonManager-Erweiterung vs SoloistDaemon-Klasse — Architektur-Entscheidung basierend auf Research
- Error-Handling / Crash-Backoff für Soloist-Daemon — bestehende Patterns aus DaemonManager übernehmen

### Deferred Ideas (OUT OF SCOPE)
- Per-Player Backend-Auswahl (librespot für Player A, Soloist für Player B) → Phase 74
- Pairing-Flow in Settings (kein SSH nötig) → Phase 74
- 24-Bit FLAC / Quality-Dropdown → Phase 74
- Lifetime-Patcher → Phase 74
</user_constraints>

## Project Constraints (from CLAUDE.md)

- **Perl ≥ 5.10, keine externen CPAN-Deps** — alles nur mit LMS-gebündelten Modulen (Vendoring innerhalb des Plugin-Zips ist davon unberührt und etablierte LMS-Plugin-Praxis)
- **LMS ist single-threaded (Event-Loop)** — keine blockierenden Operationen im Plugin-Code
- **LMS 8.0+ Minimum**, volle Features ab 8.5.1
- **Soloist ist Linux-only** (x86_64, arm64, arm32); macOS/Windows bleiben bei librespot — alle Perl-Änderungen müssen trotzdem Windows-lauffähig bleiben (`main::ISWINDOWS`-Guards, `File::Spec`-Pfade, `Proc::Background` statt fork)
- **Playback-Engine:** librespot bleibt Default-Backend; Soloist ist Opt-in-Alternative
- **Alternatives-Tabelle CLAUDE.md:** "Connect audio: HTTP-Streaming statt FIFO — FIFO hat architektonische Seek-Latenz (P-19) und White-Noise-Probleme (P-20)" — bindet die D-04-Bewertung
- **GSD-Workflow:** Implementierung nur über `/gsd-execute-phase` etc.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Connect-Registrierung (Gerät sichtbar in Spotify-App) | Soloist-Binary (Dealer-WS + mDNS) | — | Nativ im closed-source Binary; LMS ist nicht beteiligt (D-07) |
| Transfer-Playback (App → Soloist, Soloist → App) | Soloist-Binary (connect-state Cluster) | LMS Perl (reagiert auf `device_changed`) | Cloud-Transfer läuft komplett in Soloist; LMS startet/stoppt nur den Audio-Konsum |
| Playback-Events → LMS Player State | LMS Perl (WS-Client in Unified/) | Connect.pm (`spottyconnect`-Dispatch) | WS-Client übersetzt Soloist-Events in das existierende Event-Vokabular |
| Playback-Steuerung (LMS → Soloist) | LMS Perl (WS-Commands) | — | `play`/`pause`/`seek`/`set_volume` als JSON-Text-Frames |
| Audio-Dekodierung | Soloist-Binary | — | Closed-source; dekodiert zu float32 PCM |
| Audio-Transport zu LMS | fake-libpulse.so (C, im Soloist-Prozess) | LMS StreamingController (HTTP-Client) | Einziger von SpotOn kontrollierter Code im Soloist-Prozess; serviert `/stream` |
| Format-Konvertierung float32→S16LE | fake-libpulse.so (C) | — | Ersetzt sox; 10 Zeilen C statt externe Pipeline |
| Daemon-Lifecycle (Start/Stop/Crash-Backoff) | LMS Perl (DaemonManager + neue SoloistDaemon-Klasse) | — | Bestehendes Pattern (D-02, Claude's Discretion) |
| Sync-Groups | LMS Perl (DaemonManager Master-Logik + new()-Proxy) | — | 1:1 vom librespot-Pattern übertragbar |
| Pairing / Session-Storage | Soloist-Binary (data-dir) | LMS Perl (data-dir-Verwaltung pro Player) | Soloist verwaltet Sessions selbst; LMS stellt nur getrennte data-dirs |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Soloist-Binary | 1.3.7.489 (Pin, Phase 71 D-05) | Spotify-Streaming + native Connect-Registrierung | Einzige BYOK-Alternative zu librespot; Pin validiert `[VERIFIED: Plugins/SpotOn/Soloist.pm:31]` — verbatim: `use constant SOLOIST_VERSION => '1.3.7.489';` |
| `Protocol::WebSocket` | 0.26 (LMS-Bundle ab 9.1.0) | WS-Handshake + Frame-Framing (transport-agnostisch) | LMS-gebündelt, pure Perl, in dieser Session live gegen Soloists WS-Server verifiziert `[VERIFIED: WS-Probe this session — Handshake + JSON-Text-Frames funktionieren mit dem LMS-9.2-Bundle]` |
| `Slim::Networking::Select` (`addRead`/`removeRead`) | LMS-Core (seit 7.x) | Event-getriebene Socket-Reads im LMS-Select-Loop | Von Slimproto, Async.pm, UDP.pm genutzt — der kanonische non-blocking-Pfad `[VERIFIED: /usr/share/perl5/Slim/Networking/IO/Select.pm:51-73 — `sub addRead`, `sub removeRead`, `sub addWrite`; Aufrufer: Slim/Networking/Async.pm]` |
| `JSON::XS` | LMS-Bundle | WS-Message-Parsing | Bereits Plugin-weit im Einsatz (`JSON::XS::VersionOneAndTwo`) |
| `Proc::Background` | LMS-Bundle | Daemon-Spawn | Identisch zum librespot-Daemon `[VERIFIED: Plugins/SpotOn/Unified/Daemon.pm:83,301]` |
| fake-libpulse.so | Repo `Bin/fake-libpulse/` + CI (3 Arches) | PCM-Abgriff → neu: HTTP-Server | Phase-71-Asset, wird um HTTP-Serving erweitert `[VERIFIED: Plugins/SpotOn/Bin/fake-libpulse/fake-libpulse.c:675-711 — `pa_stream_write` ist die Load-Bearing-Funktion]` |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `Slim::Utils::Timers` | LMS-Core | ws.port-Polling, Reconnect-Backoff | Wie `_pollPortFile` in Daemon.pm `[VERIFIED: Plugins/SpotOn/Unified/Daemon.pm:359-422]` |
| `Slim::Control::Request` | LMS-Core | Event-Dispatch an Connect.pm | `executeRequest`/`addDispatch(['spottyconnect', '_cmd'])` `[VERIFIED: Plugins/SpotOn/Connect.pm:66]` |
| pthread (C) | libc | HTTP-Server-Thread in fake-libpulse | Bereits genutzt (threaded mainloop) `[VERIFIED: fake-libpulse.c:48,197-203]` |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Eigener WS-Client (Protocol::WebSocket + Select) | `Slim::Networking::SimpleWS` | SimpleWS-Error-Handler ruft `exit` auf → tötet den GANZEN LMS-Prozess bei WS-Protokollfehler `[VERIFIED: /usr/share/perl5/Slim/Networking/SimpleWS.pm:133-142 — verbatim: `$self->{tcp_socket}->close; exit;`]`; blockierender Handshake-Loop (L166-183); Timer-Polling mit bis zu 1 s Event-Latenz (L303: `_continueListen(1)`) |
| Eigener WS-Client | `AnyEvent::WebSocket::Client` | AnyEvent ist zwar im LMS-CPAN-Baum, aber AnyEvent-Event-Loop kollidiert mit LMS' eigenem Select-Loop; AnyEvent::WebSocket::Client ist NICHT gebündelt |
| HTTP-Server in fake-libpulse | stdout-Pipe + externer Bridge-Prozess | Zweiter Prozess pro Player (Lifecycle, Crash-Handling, CI ×3 Arches); keine Vorteile gegenüber in-process Server |
| HTTP-Server in fake-libpulse | FIFO (SPOTON_SOLOIST_PCM_PATH auf FIFO) | CLAUDE.md-Alternatives: FIFO wegen Seek-Latenz (P-19) und White-Noise (P-20) bereits projektweit verworfen; kein Sync-Group-Fanout |
| Events → `spottyconnect`-Vokabular | Neues Soloist-eigenes Event-Vokabular | Würde Connect.pm-State-Maschine (Grace-Timer, Volume-Suppression, Track-Translation) duplizieren statt wiederverwenden |

**Installation:** Keine neuen externen Pakete. Optional (Assumptions A1): Vendoring von `Protocol::WebSocket` 0.26 (pure Perl, Artistic/GPL dual-license `[VERIFIED: /usr/share/squeezeboxserver/CPAN/Protocol/WebSocket.pm — "This program is free software, you can redistribute it and/or modify it"]`) ins Plugin-Zip für LMS < 9.1.0.

## Package Legitimacy Audit

Diese Phase installiert **keine Pakete aus Registries** (kein npm/PyPI/crates/CPAN-Install — CLAUDE.md verbietet externe CPAN-Deps ohnehin). Der einzige Fremdcode-Kandidat:

| Package | Registry | Age | Downloads | Source Repo | Verdict | Disposition |
|---------|----------|-----|-----------|-------------|---------|-------------|
| Protocol::WebSocket 0.26 | (kein Install — Vendoring aus LMS-Quelle) | 2010-2018 (Autor V. Tykhanovskyi) | LMS-Core-Dependency | github.com/vti/protocol-websocket; im LMS-Baum seit slimserver-Commit 53146447 (2024-12-12) | OK | Approved — Quelle für Vendoring ist der LMS-Community/slimserver-Baum selbst (identische Version wie das Bundle), nicht CPAN-Download zur Laufzeit |

**Packages removed due to [SLOP] verdict:** none
**Packages flagged as suspicious [SUS]:** none

## Architecture Patterns

### System Architecture Diagram

```
                       Spotify Cloud
        ┌────────────────────┴─────────────────────┐
        │  dealer.g2.spotify.com (connect-state)   │
        │  clienttoken / spclient / Audio-CDN      │
        └────────────────────┬─────────────────────┘
                             │ (nativ, closed-source)
   Spotify App ──mDNS/Cloud──┤
   (Device-Picker)           ▼
                  ┌─────────────────────────┐   dlopen("libpulse.so.0")
                  │  soloist (1 pro Player) │──────────────┐
                  │  -n <PlayerName>        │              ▼
                  │  -D <per-player-data>   │   ┌──────────────────────────┐
                  │  --ws 127.0.0.1:0       │   │ fake-libpulse.so (C)     │
                  └──────────┬──────────────┘   │  pa_stream_write(PCM f32)│
                             │                  │  → f32→S16LE-Konvertierung│
              ws.port-File   │ WS (JSON-Frames) │  → Ringpuffer (bounded)  │
              im data-dir    │                  │  → HTTP GET /stream      │
                             ▼                  │  → Port-File-Announce    │
       ┌───────────────────────────────┐        └───────────┬──────────────┘
       │ LMS-Plugin (Perl, ein Prozess)│                    │ HTTP (S16LE PCM)
       │ ┌───────────────────────────┐ │                    │
       │ │ Unified::SoloistDaemon    │ │                    │
       │ │  - spawn/stop/alive       │ │                    ▼
       │ │  - ws.port + http-port    │ │    ┌────────────────────────────────┐
       │ │    Polling                │ │    │ LMS StreamingController        │
       │ │  - WS-Client (Protocol::  │ │    │  canDirectStream → http://…/   │
       │ │    WebSocket + addRead)   │ │    │  stream  (Sync: new()-Proxy)   │
       │ └──────────┬────────────────┘ │    └────────────────┬───────────────┘
       │            │ Event-Übersetzung │                    ▼
       │            ▼                   │              Squeezebox-Player
       │  spottyconnect start/change/   │              (Audio-Ausgabe)
       │  stop/volume/seek/resume       │
       │            ▼                   │
       │  Connect.pm (_connectEvent)    │
       │  → LMS Player State            │
       └────────────────────────────────┘
```

Datenfluss Haupt-Use-Case (Transfer von der Spotify-App): User wählt Player-Gerät in der App → Soloist-Cloud-Registrierung macht Gerät aktiv → WS-Events `device_changed{is_active:true}` + `track_changed` treffen im Perl-WS-Client ein → Übersetzung in `spottyconnect start` → Connect.pm startet `spoton://connect-…`-Wiedergabe → canDirectStream liefert `http://<host>:<port>/stream` → LMS-Player konsumiert PCM aus fake-libpulse.

### Recommended Project Structure

```
Plugins/SpotOn/
├── Unified/
│   ├── DaemonManager.pm     # startHelper() Soloist-Branch füllen (bisher Platzhalter L664-674)
│   ├── Daemon.pm            # unverändert (librespot)
│   ├── SoloistDaemon.pm     # NEU: Lifecycle-Klasse analog Daemon.pm (spawn, ws.port-Poll, stop)
│   └── SoloistWS.pm         # NEU: schlanker WS-Client (Handshake, Frames, Event-Dispatch, Reconnect)
├── Soloist.pm               # erweitert: dataDirForClient($client), WS-Hilfen
├── ProtocolHandler.pm       # canDirectStream/new()/canSeek Soloist-Pfade auf HTTP-URL umstellen
├── Connect.pm               # unverändert — empfängt spottyconnect wie bisher
└── Bin/fake-libpulse/
    └── fake-libpulse.c      # erweitert: HTTP-Server-Thread + Ringpuffer + f32→S16-Konvertierung
```

### Pattern 1 (D-04): HTTP-Streaming-Server in fake-libpulse.so — EMPFOHLEN

**What:** Ein pthread-basierter HTTP/1.0-Server im fake-libpulse-Stub (dem einzigen SpotOn-Code im Soloist-Prozess). `pa_stream_write()` schreibt in einen bounded Ringpuffer statt auf einen FD; der Server-Thread akzeptiert eine `/stream`-Verbindung, konvertiert float32→S16LE und liefert Endless-PCM — semantisch identisch zum librespot-`/stream`-Relay.

**Bewertung der drei Optionen aus D-04:**

| Kriterium | A: HTTP in fake-libpulse (empfohlen) | B: Pipe/FD-Fortführung | C: FIFO |
|-----------|--------------------------------------|------------------------|---------|
| Machbarkeit | HOCH — pa_stream_write hat schon alle Bytes; pthread schon im Stub `[VERIFIED: fake-libpulse.c:48]` | Persistenter Daemon + LMS-Transcoder-Framework passen nicht: LMS erwartet Prozess-pro-Track am Pipe-Ende | Möglich (SPOTON_SOLOIST_PCM_PATH auf FIFO), aber projektweit verworfen |
| LMS-Anbindung | canDirectStream → URL; `getFormatForURL` liefert für `:port/stream`-URLs bereits `'pcm'` `[VERIFIED: Plugins/SpotOn/ProtocolHandler.pm:107 — verbatim: `return 'pcm' if $url && $url =~ m{:\d+/stream\b};`]` | custom-convert.conf-Regel müsste an persistenten Prozess koppeln — kein LMS-Mechanismus dafür | FIFO-Reader-Lifecycle in LMS fragil (P-19/P-20, CLAUDE.md) |
| Sync-Groups | new()-Proxy-Pattern 1:1 wie librespot `[VERIFIED: ProtocolHandler.pm:477-495]` | nicht abbildbar (ein FD, ein Konsument) | ein FIFO, ein Konsument |
| Reconnect/Attach-Detach | Client-Takeover-Semantik wie unified.rs M15 (Relay-Generation) | Pipe bricht bei Konsumenten-Wechsel | FIFO-EOF-Probleme |
| sox-Abhängigkeit | ENTFÄLLT — f32→S16 in C (Clamp+Scale) | bleibt (sox extern nötig) `[VERIFIED: Plugins/SpotOn/custom-convert.conf — verbatim: `[spoton-soloist] --single-track $URL$ 2>/dev/null | [sox] -t raw -r 44100 -c 2 -e floating-point -b 32 -L - -t raw -r 44100 -c 2 -e signed -b 16 -L -`]` | bleibt |
| Risiko | Bug im .so crasht Soloist (Blast-Radius = 1 Daemon; Crash-Backoff existiert) | — | — |

**Design-Vorgaben für die C-Implementierung (aus librespot unified.rs abgeleitet):**
- Bind `127.0.0.1:0`, Port-Announce über Datei via Env-Var (neues `SPOTON_SOLOIST_HTTP_PORT_FILE`, analog zu `SPOTON_PORT_FILE` `[VERIFIED: Plugins/SpotOn/Unified/Daemon.pm:290 — verbatim: `$ENV{SPOTON_PORT_FILE} = $port_tmpfile;`]`). Perl pollt mit dem bestehenden `_pollPortFile`-Timer-Pattern.
- **Bounded Ringpuffer (~1-2 s Audio) mit blockierendem Write bei vollem Puffer.** Das ist nicht nur Speicherhygiene, sondern das Realtime-Pacing: Soloist schreibt so schnell, wie `pa_stream_write` annimmt; ein voller Puffer + LMS-Lesetempo (Realtime) taktet Soloist auf ≈ Echtzeit — exakt wie eine reale PulseAudio-`tlength`-Buffer-Attr. `pa_stream_writable_size()` sollte den freien Pufferplatz melden statt konstant 65536 `[VERIFIED: fake-libpulse.c:664-670 — aktuell konstant]`.
- Kein Client verbunden → älteste Bytes im Ring verwerfen (Soloist darf nie dauerhaft blockieren, wenn LMS nicht liest — z. B. Connect aktiv, aber LMS-Player pausiert).
- Neuer `/stream`-Client übernimmt (Takeover), alter Socket wird geschlossen — Muster aus `librespot-spoton/src/unified.rs` (Relay-Generation M15, dort verifiziert `[VERIFIED: librespot-spoton/src/unified.rs:535,680-684]`).
- Response-Header wie librespot: `Content-Type: audio/L16;rate=44100;channels=2` `[VERIFIED: librespot-spoton/src/unified.rs:879 — verbatim: `"audio/L16;rate=44100;channels=2"`]`; keine Content-Length (Endless-Stream). ProtocolHandler unterdrückt Range/Enhanced-HTTP für `/stream`-URLs bereits `[VERIFIED: ProtocolHandler.pm:277-298,398-411]`.
- Audio-Format-Fakt: Soloist liefert **float32 PCM 44,1 kHz stereo** an pa_stream_write (Phase-72-UAT-Korrektur; die sox-Regel oben konvertiert von `floating-point -b 32`). Konvertierung in C: `s16 = (int16_t)lrintf(clamp(f, -1.0f, 1.0f) * 32767.0f)`. 24-Bit-Pfad ist Phase 74.

**When to use:** Immer für Phase 73 (Connect UND Browse-Audio).

### Pattern 2 (D-05): Schlanker Perl-WS-Client an LMS' Select-Loop

**What:** Neues Modul `Unified::SoloistWS`: `IO::Socket::INET`-Connect auf `127.0.0.1:<ws.port>`, `Protocol::WebSocket::Client` für Handshake/Framing, `Slim::Networking::Select::addRead($sock, \&onReadable)` für event-getriebene Reads (0 Latenz statt 1 s SimpleWS-Polling), `JSON::XS` fürs Message-Parsing.

**Verifiziert in dieser Session** (Live-Probe gegen laufenden Soloist mit `--ws 127.0.0.1:0`, LMS-gebündeltes Protocol::WebSocket):

```perl
# Source: live verified this session against soloist --ws (Handshake + Frames OK)
use Protocol::WebSocket::Client;
my $sock = IO::Socket::INET->new(
    PeerAddr => '127.0.0.1', PeerPort => $wsPort, Proto => 'tcp',
) or return $errorCb->("connect failed: $!");
my $client = Protocol::WebSocket::Client->new(url => "ws://127.0.0.1:$wsPort");
$client->on(write => sub { syswrite $sock, $_[1] });       # frames out
$client->on(read  => sub { $self->_dispatchEvent($_[1]) }); # JSON text in
$client->on(error => sub { $self->_onWsError($_[1]) });     # NIE exit!
$client->on(ping  => sub { $_[0]->pong($_[1]) });           # RFC 6455 keepalive
$client->connect;
# Handshake-Bytes + laufende Frames event-getrieben:
Slim::Networking::Select::addRead($sock, sub {
    my $n = sysread $sock, my $buf, 16384;
    return $self->_onWsClosed() unless $n;   # 0/undef = Verbindung weg
    $client->read($buf);                      # feeds handshake AND frames
});
# Senden: $client->write('{"type":"command","command":"pause"}');
```

- **Handshake:** Der localhost-Connect + Handshake sind in <5 ms erledigt; auch der `connect`-Aufruf schreibt nur den HTTP-Upgrade-Request. Die Antwort kommt über denselben addRead-Callback (`$client->read` verarbeitet Handshake-Bytes bis `is_done`, danach Frames — kein blockierender Loop nötig, im Gegensatz zu SimpleWS).
- **Endpoint-Discovery:** `--ws 127.0.0.1:0` → Soloist schreibt `<data-dir>/ws.addr` und `<data-dir>/ws.port` `[VERIFIED: live probe this session — ws.port enthielt `43789`, stdout-Log: `api: websocket server listening on 127.0.0.1:43789`]`. Polling mit `PORT_POLL_INTERVAL`-Pattern.
- **Message-Format (live verifiziert):** Verbindungsaufbau → Server sendet sofort `{"type":"auth_state","logged_in":false,"is_active":false,"device_name":"…"}`. Commands: `{"type":"command","command":"get_auth_state"}` → `auth_state`-Antwort. Nicht eingeloggt + authentifizierter Command → `{"type":"error","message":"command requires authentication"}`. Ungültige Message → `{"type":"error","message":"invalid JSON or missing required fields"}` `[VERIFIED: live WS probe this session, alle vier Antworten wörtlich beobachtet]`.
- **stdout-Proxy-Alternative (verworfen):** `soloist ctl trace` streamt alle WS-Events auf stdout (`<unix_epoch_ms> <json_event>`) `[CITED: developer.spotify.com/documentation/soloist/reference/soloist-ctl]` — wäre ein zweiter Kindprozess pro Player, dessen stdout-Parsing dieselbe JSON-Arbeit erfordert, plus eigener Lifecycle. Der native Client ist strikt einfacher; `soloist ctl trace` bleibt als **Debug-Werkzeug** wertvoll (Wave-0-Validierung, TROUBLESHOOTING).
- **Reconnect:** WS-Verbindungsverlust ≠ Daemon-Tod. Bei `_onWsClosed`: `removeRead`, Timer-Retry mit Backoff; wenn Prozess tot → bestehende `_streamAlivePoll`-Crash-Behandlung greift `[VERIFIED: Plugins/SpotOn/Unified/DaemonManager.pm:379-437]`.

### Pattern 3 (D-06): Event-Mapping auf das `spottyconnect`-Vokabular

Connect.pm konsumiert heute genau 6 Kommandos vom librespot-Daemon: `start`, `change`, `stop`, `volume`, `seek`, `resume` `[VERIFIED: librespot-spoton/src/connect.rs:83-84 — verbatim: `/// Wire vocabulary (6 commands): start, change, stop, volume, seek, resume.` und Plugins/SpotOn/Connect.pm:537-912 — Handler-Branches `if ($cmd eq 'start')`, `'volume'`, `'seek'`, `'resume'`, `'change'`, `'stop'`]`. Der Soloist-WS-Client übersetzt in dieses Vokabular und dispatcht intern (`Slim::Control::Request::executeRequest`) — Connect.pm bleibt unverändert.

**Vollständiges Soloist-Event-Set** `[CITED: developer.spotify.com/documentation/soloist/reference/websocket-api]`; `auth_state` + Fehlerpfade zusätzlich `[VERIFIED: live probe]`:

| Soloist-WS-Event | Payload | → LMS-Aktion (spottyconnect bzw. direkt) |
|------------------|---------|------------------------------------------|
| `auth_state` | `logged_in`, `is_active`, `device_name` | Kein Player-Event. `logged_in:false` → Settings-Status "nicht gepairt"; gated authentifizierte Commands |
| `playback_state` (Snapshot bei Connect + auf `get_state`) | status, item, context, position, volume, options, actions | Initialer Zustandsabgleich nach WS-(Re)Connect — Position/Track/Volume synchronisieren |
| `track_changed` | Item-Entity (uri, decorations…) | `start` (None→Track) bzw. `change` (Track→Track); Track-ID aus `uri` (`spotify:track:<id>`); Metadata aus `decorations` (identity/visual_identity/creators/playback → Titel/Cover/Artist/Duration) |
| `playback_changed` | `status` | playing → `resume` (nach Pause) / Teil des Start-Flows; paused/stopped → `stop` (librespot kollabiert Paused+Stopped ebenfalls zu `stop` `[VERIFIED: connect.rs:85 — verbatim: `"pause" is intentionally not emitted — Paused and Stopped collapse to "stop".`]`) |
| `volume_changed` | 0-100 | `volume` (librespot-Analogon inkl. CON-11-Suppression nach Transfer beachten) |
| `position_sync` | `position_ms`, `timestamp_ms`, `speed` | `seek` (nur bei Sprung > Toleranz; `speed` 0.0 = pausiert) |
| `device_changed` | `is_active`, `device_name` | `is_active:true` → Connect-Session-Start (Transfer ZU Soloist): `start`; `is_active:false` → Transfer WEG: `stop` |
| `context_changed` | Context-Entity | Metadata/Kontextanzeige (optional; kein Player-State-Event) |
| `options_changed` | PlaybackOptions (shuffle/repeat) | LMS-Shuffle/Repeat-Anzeige synchronisieren (optional, Parität mit librespot-Verhalten prüfen) |
| `queue_changed` | `previous`/`upcoming` Arrays (uid, source, item) | Queue-Metadaten (bis 80 Tracks); für Browse-Modell B: Bestätigung der `add_to_queue`-Seeds |

**Command-Set LMS → Soloist** (für Connect.pm's bestehende `_onPause`/`_onVolume`/`_onSeek`/`_onPlaylistJump`-Forwarder `[VERIFIED: Plugins/SpotOn/Connect.pm:319,396,428,474]`, die heute an librespot `/control/*` POSTen — Soloist-Äquivalent als WS-Command):

| LMS-Aktion | librespot heute | Soloist-WS-Command |
|------------|-----------------|--------------------|
| Pause/Play | POST /control/pause,play | `{"type":"command","command":"pause"}` / `"play"` (play optional mit `uri`) |
| Next/Prev | /control/next,prev | `skip_next` / `skip_prev` |
| Seek | /control/seek | `seek` + `position_ms` |
| Volume | /control/volume | `set_volume` + `volume` (0-100) |
| Shuffle/Repeat | — | `set_shuffle` + `enabled`; Repeat braucht ZWEI Commands: `set_repeat_context` + `set_repeat_track` (Pitfall 7) |
| Queue | — | `add_to_queue` + `uri` (**nur Track-URIs**) |
| Transfer erzwingen | — | `activate` / `deactivate` |
| Zustandsabfrage | /health | `get_auth_state` (ohne Login), `get_state`, `get_queue` (mit Login) |

Antworten: Erfolg `{"type":"command_result","command":"pause"}`, Fehler `{"type":"error","message":"…"}` `[VERIFIED: Fehlerform live beobachtet; command_result-Form CITED: websocket-api]`.

### Pattern 4 (D-07): Native Connect-Registrierung + Transfer

**Registrierung ist vollständig nativ** — LMS macht NICHTS über die Spotify Web API:
- Soloist verbindet sich mit `wss://dealer.g2.spotify.com:443` und registriert sich über das connect-state-Protokoll (`PutStateRequest` mit `PutStateReason=NEW_CONNECTION` + dealer-vergebener `connection_id`) `[VERIFIED: strings/symbol analysis of the soloist binary — u. a. `wss://dealer.g2.spotify.com:443`, `ConnectConnectivityListener: received new_connection_id %s - starting`, `spotify.connectstate.PutStateRequestWrapper…device_id…connection_id`]`.
- Zusätzlich lokales mDNS für den Device-Picker im LAN `[VERIFIED: binary strings `connect_mdns`; CITED: soloist/concepts/overview — "advertises itself on your local network"]`.
- Identität: `.device_id` (UUID) im data-dir; Session unter `settings/Users/<canonical-username>-user/` `[VERIFIED: Inspektion des realen Phase-72-data-dir dieser Session — Dateien `.device_id` (36 Bytes UUID), `.lock`, `settings/Users/<user>-user/`]`.

**Transfer-Playback (App → Soloist):** User wählt das Gerät im Spotify-App-Device-Picker → Cloud-Transfer via connect-state-Cluster → Soloist wird aktiv → WS-Events `device_changed{is_active:true}` + `track_changed` + `playback_state`. LMS reagiert rein auf Events (startet `/stream`-Konsum). **Rückrichtung:** anderes Gerät gewählt → `device_changed{is_active:false}` → LMS stoppt. **LMS-initiiert:** `activate`/`deactivate`-Commands `[CITED: websocket-api + soloist ctl reference; ctl-Kommandos gegen Binary verifiziert: `soloist ctl --help` listet `activate  Become the active Spotify Connect device`]`.

**Pairing-Implikation (wichtig!):** Der "Login" IST der erste Transfer: Daemon läuft mit frischem data-dir → Gerät erscheint in der App → User wählt es → Session wird gespeichert ("Authentication occurs and the session stores automatically", "Sessions persist across restarts when the data directory remains unchanged" `[CITED: soloist/concepts/authentication]`, empirisch von Phase 72 bestätigt: das UAT-data-dir enthält die persistierte Session). Der Phase-72-SSH-`--pair`-Umweg wird für den persistenten Daemon **obsolet** — pro Player einmal das Gerät in der App antippen. Das ist zugleich die Antwort auf die Per-Player-data-dir-Frage: **kein data-dir-Cloning nötig** (das UUID-/Session-Cloning wäre riskant, Device-ID-Kollision im Cluster); jeder Player paart sich selbst per App-Tap.

### Pattern 5: Daemon-Lifecycle (SoloistDaemon-Klasse)

Empfehlung (Claude's Discretion): **eigene Klasse `Unified::SoloistDaemon`** parallel zu Daemon.pm statt Daemon.pm-Erweiterung — die Unterschiede sind strukturell (kein credentials.json-Gate, ws.port-File statt stdout-`stream_port=N`, zwei Ports [WS + HTTP], LD_LIBRARY_PATH-Env, per-player data-dir, spak-key via argv). Wiederverwendet werden die DaemonManager-Mechanismen unverändert: `%helperInstances`-Registry, `CRASH_BACKOFF_*` `[VERIFIED: DaemonManager.pm:46-48]`, Stagger-Start `[VERIFIED: DaemonManager.pm:34-36,350-373]`, `deviceNameForClient` (60-Zeichen-Cap, Sync-Suffix) `[VERIFIED: DaemonManager.pm:156-166]`, `_streamAlivePoll`.

**Spawn-Parameter** (alle Flags gegen `soloist --help` des echten Binaries verifiziert `[VERIFIED: soloist --help this session]`):

```sh
# Env vor Proc::Background->new (Muster: Daemon.pm start(), Env nach Spawn löschen):
#   LD_LIBRARY_PATH=<plugin>/Bin/fake-libpulse           (Soloist.pm libPath(), Phase 71)
#   SPOTON_SOLOIST_HTTP_PORT_FILE=<tmpfile>              (neu, fake-libpulse announce)
#   PIPEWIRE_RUNTIME_DIR=/nonexistent                    (Pitfall 3 — PipeWire-Fallback erzwingen)
soloist \
  -n "<deviceNameForClient>" \
  -k "<spak-key>" \
  -D <cachedir>/spoton/soloist/players/<mac>/data \
  -C <cachedir>/spoton/soloist/players/<mac>/cache \
  -w 127.0.0.1:0
```

- **Start-Trigger:** Player-Connect via bestehendem `initHelpers`-Flow; der Soloist-Branch in `startHelper()` ersetzt den Phase-72-Platzhalter `[VERIFIED: DaemonManager.pm:664-674 — verbatim: "The persistent WebSocket daemon (--ws) arrives with Phase 73 Connect."]`. Prereq-Gate `_backendPrereqState` bleibt `[VERIFIED: DaemonManager.pm:615-629]`.
- **Ready-Detection:** ws.port-File-Poll (data-dir) + HTTP-Port-File-Poll (fake-libpulse); danach WS-Connect + `get_auth_state`.
- **Stop:** Player-Disconnect → `shutdown('inactive-only')`-Pfad (bestehend); `Proc::Background` mit `die_upon_destroy`.
- **spak-key auf argv:** `/proc/<pid>/cmdline`-Sichtbarkeit ist der in Phase 72 dokumentierte ACCEPTED RISK (WR-01) `[VERIFIED: Plugins/SpotOn/Soloist.pm:388-396]` — gilt unverändert; ein Env/stdin-Pfad existiert im Binary nicht.
- **Session-Lock-Auflösung:** `.lock` im data-dir `[VERIFIED: reales data-dir — Datei `.lock` vorhanden]`; Exit-Code 1 bei "another process using data directory" `[CITED: soloist/reference/command-line]`. Persistenter Daemon = genau ein Lock-Halter pro data-dir für die gesamte Laufzeit; Prefetch/Gapless erzeugt keine zweiten Prozesse mehr → Problem strukturell weg. Restrisiko: Zombie-Daemon hält Lock → Startup-Kill-Pattern (`_killOrphanedProcesses`-Analogie, `helperPids`-Ausschluss `[VERIFIED: DaemonManager.pm:1043-1046]`).

### Pattern 6: Browse-Wiedergabe über den persistenten Daemon (D-03)

Zwei Modelle wurden analysiert; **Empfehlung: Modell B ("Browse als lokal gesteuerte Connect-Session")**, weil nur B das Phasen-Ziel Gapless/Crossfade erreicht:

- **Modell A — Per-Track-WS-Play mit LMS-Track-Grenzen:** Pro LMS-Track `play {uri}` + `/stream`-Reconnect. Problem: `/stream` ist endlos — LMS bekommt kein EOF am Track-Ende und würde nie von selbst weiterschalten; ein Perl-seitiger Advance-Timer wäre fragil. Kein Gapless (Reconnect-Lücke).
- **Modell B — Soloist-Queue geseedet aus der LMS-Playlist:** Track-Start: `play {uri}`; rechtzeitig vor Track-Ende `add_to_queue {uri des nächsten LMS-Spotify-Tracks}`; Soloist blendet gapless/crossfade über; `track_changed`-Event → `spottyconnect change` → LMS-Playlist-Index rückt nach, OHNE Stream-Neustart — exakt die Mechanik, mit der Connect.pm heute librespot-Connect-Trackwechsel abbildet (`isRepeatingStream` für die Stream-Kontinuität `[VERIFIED: ProtocolHandler.pm:806-811]`). Misch-Playlists (Spotify-Track → Radio/Lokal): am Grenzübergang `pause` senden und LMS normal weiterschalten lassen.
- ProtocolHandler-Änderungen: Soloist-Branch in `canDirectStream` von `return 0` `[VERIFIED: ProtocolHandler.pm:174-178]` auf HTTP-URL; `new()`-Soloist-Guard `[VERIFIED: ProtocolHandler.pm:448 — `!_useSoloist()`-Bedingung]` für Sync-Proxy öffnen; `canSeek` von 0 auf 1 (Seek jetzt via WS `seek` möglich — hebt die Phase-72-Einschränkung `[VERIFIED: ProtocolHandler.pm:813-820]` auf); `getNextTrack`-Samplesize-Hints von Transcoder- auf HTTP-Pfad anpassen (S16LE aus fake-libpulse → 16/44100/2, konsistent mit `[VERIFIED: ProtocolHandler.pm:566-573]`).
- Die `sol pcm`-Convert-Regel + Launcher bleiben zunächst als Fallback für `streamingMode=proxy`… **nein** — einfacher: Proxy-Modus nutzt den `new()`-HTTP-Proxy-Pfad (wie librespot). Die `sol`-Regeln und der `--single-track`-Launcher können nach Modell-B-Umstellung entfernt werden (CONTEXT §specifics bestätigt das explizit).

### Pattern 7: Sync-Groups

DaemonManager-Pattern überträgt sich 1:1 (Claude's Discretion → **direkt einbauen**): Daemon läuft auf dem Sync-Master (`initHelpers`-Slave-Delegation `[VERIFIED: DaemonManager.pm:319-339]`), `deviceNameForClient` liefert den Gruppen-Suffix, `canDirectStream` gibt bei synced Playern 0 zurück und `new()` proxied die HTTP-URL an alle Member `[VERIFIED: ProtocolHandler.pm:213-215,477-495]`. Einzige Soloist-Besonderheit: der fake-libpulse-Server hat (wie librespot `/stream`) EINEN Konsumenten — der LMS-interne Proxy fächert auf. Keine Verschiebung nach Phase 74 nötig.

### Anti-Patterns to Avoid
- **`Slim::Networking::SimpleWS` direkt verwenden:** `on(error => …{ exit })` tötet LMS `[VERIFIED: SimpleWS.pm:133-142]`. Auch nicht "SimpleWS + Error-Handler überschreiben" — der blockierende Handshake und das 1s-Polling bleiben.
- **data-dir zwischen Playern teilen oder clonen:** Teilen → `.lock`-Kollision (das Phase-72-Problem in neuer Form); Clonen → `device_id`-Kollision im Connect-Cluster. Ein data-dir pro Player, Pairing per App-Tap.
- **WS-API auf 0.0.0.0 binden:** Die API hat "no built-in client authentication, authorization, TLS, Origin validation, CSRF protection" `[CITED: soloist/reference/websocket-api]` — strikt `127.0.0.1`.
- **Blocking-Reads/-Writes im Perl-WS-Client:** LMS-Event-Loop; alles über `Select::addRead` + `syswrite` kleiner Frames (localhost-Kernel-Puffer reicht; bei EAGAIN-Paranoia `writeNoBlock`-Queue aus Select.pm nutzen).
- **stdout des Soloist-Daemons ignorieren:** Soloist loggt auf stdout (u. a. `client expires in 80 days` `[VERIFIED: live probe stdout]`) — nach Datei umleiten (stderr-Capture-Pattern aus Daemon.pm), sonst gehen Expiry-Warnungen verloren.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| WS-Handshake + RFC-6455-Framing (Masking, Fragmente, Ping/Pong, Close) | Eigener Frame-Parser | `Protocol::WebSocket::Client` (0.26) | Fragmentierte Frames, Maskierungspflicht Client→Server, Control-Frames — alles fehleranfällig; Modul live gegen Soloist verifiziert |
| Event-State-Maschine (Grace-Timer, Volume-Suppression nach Transfer, Track-Translation, History) | Neue Soloist-Event-Verarbeitung | Bestehendes `spottyconnect`-Dispatch + Connect.pm | Jahre an Edge-Case-Fixes (CON-11, GH #129, M8/M9) stecken in Connect.pm |
| Daemon-Crash-Handling | Neues Backoff-System | `CRASH_BACKOFF_*` + `%crashRestarts` in DaemonManager | Explizit als Reusable Asset markiert (CONTEXT code_context) |
| Port-Discovery | Socket-Scanning/Retry-Connect | ws.port/HTTP-Port-File-Polling (`_pollPortFile`-Pattern) | Soloist schreibt ws.port selbst; fake-libpulse schreibt Port-File analog SPOTON_PORT_FILE |
| Realtime-Pacing des PCM | Timer-basierte Drossel in C | Bounded Ringpuffer + blockierender Producer | Emergentes Pacing wie bei realem PulseAudio-Sink; selbstkorrigierend |
| HTTP-Streaming-Semantik (Takeover, Drain, Header) | Neues Protokoll LMS↔fake-libpulse | librespot `unified.rs` `/stream`-Relay als Blaupause | In Produktion bewährt (Phasen 28-72), LMS-Seite existiert bereits komplett |

## Common Pitfalls

### Pitfall 1: SimpleWS `exit` im Error-Handler
**What goes wrong:** Ein einziger WS-Protokollfehler beendet den gesamten LMS-Server.
**Why it happens:** `Slim::Networking::SimpleWS` (LMS 9.1/9.2) registriert `on(error => sub { … exit; })` `[VERIFIED: SimpleWS.pm:133-142]`.
**How to avoid:** Eigener Client (Pattern 2); Error-Callback loggt + Reconnect.
**Warning signs:** LMS-Neustarts korreliert mit Soloist-Daemon-Restarts.

### Pitfall 2: Stale ws.port/ws.addr nach unsauberem Daemon-Ende
**What goes wrong:** Perl verbindet sich mit einem Port eines toten (oder fremden neuen) Prozesses.
**Why it happens:** Docs sagen "On shutdown, runtime files removed" — bei SIGKILL/Crash bleiben die Dateien aber liegen `[VERIFIED: live probe this session — nach `kill` existierten ws.addr/ws.port weiter]`.
**How to avoid:** Vor jedem Daemon-Start ws.port/ws.addr/soloist.pid im data-dir löschen; ws.port-Wert nur akzeptieren, wenn die Datei NACH dem Spawn-Zeitpunkt geschrieben wurde (mtime-Check) oder nach Löschung neu erschien.
**Warning signs:** WS-Connect-Refused-Loops direkt nach Daemon-Restart.

### Pitfall 3: Soloist bevorzugt PipeWire — fake-libpulse wird umgangen
**What goes wrong:** Auf Systemen mit laufender PipeWire-Session (Desktop-LMS!) spielt Soloist über echtes PipeWire auf die lokale Soundkarte statt in fake-libpulse.
**Why it happens:** Das Binary dlopen't `libpipewire-0.3.so.0` bevorzugt, `libpulse.so.0` ist Fallback `[VERIFIED: strings im Binary — beide Bibliotheksnamen vorhanden; CITED: soloist/concepts/overview — "PipeWire is prioritized when available; PulseAudio serves as fallback"]`. Auf dem Headless-Dev-System funktionierte Phase 72 nur, weil der `squeezeboxserver`-User keinen PipeWire-Socket hat.
**How to avoid:** Daemon-Env härten: `PIPEWIRE_RUNTIME_DIR=/nonexistent` (und defensiv `XDG_RUNTIME_DIR` unsetzen) vor dem Spawn — PipeWire-Discovery schlägt fehl, Pulse-Fallback lädt fake-libpulse via LD_LIBRARY_PATH. Alternativ (robuster, mehr Aufwand): Stub-`libpipewire-0.3.so.0`, die Connect-Fehler liefert.
**Warning signs:** Audio auf dem LMS-Host hörbar; `/stream` liefert keine Bytes obwohl Soloist "spielt".

### Pitfall 4: Track-Ende-/Autoplay-Verhalten bei WS-`play {uri}` ist undokumentiert
**What goes wrong:** Nach Ende eines per WS gestarteten Einzeltracks könnte Soloist stoppen, pausieren ODER per Autoplay (Feature laut Blog-Announcement) selbständig weiterspielen — im schlimmsten Fall spielt der Player Tracks, die nicht in der LMS-Playlist stehen.
**Why it happens:** Die WS-Doku spezifiziert das Ende-Verhalten nicht; Autoplay/Smart-Shuffle sind Soloist-Features ohne dokumentierten CLI/WS-Toggle.
**How to avoid:** Wave-0-Validierung mit `soloist ctl trace` (welche Events feuern am Track-Ende? spielt Autoplay weiter?). Defensiv: Modell B hält die Soloist-Queue immer mit dem nächsten LMS-Track geseedet; bei `track_changed` mit unerwarteter URI korrigieren (`play {expected}` oder `pause` am LMS-Queue-Ende).
**Warning signs:** `track_changed`-Events mit URIs, die nie von LMS angefordert wurden.

### Pitfall 5: Position-Drift durch Decode-Ahead
**What goes wrong:** Soloists gemeldete Position (`position_sync`) läuft der hörbaren Audioposition um die Pufferungstiefe voraus.
**Why it happens:** fake-libpulse meldet aktuell `writable_size` konstant und `read_index == write_index` `[VERIFIED: fake-libpulse.c:310-316,664-670]` — Soloist kann schneller als Echtzeit dekodieren; LMS puffert zusätzlich.
**How to avoid:** Bounded Ringpuffer (Pattern 1) begrenzt den Vorlauf auf ~1-2 s; `position_sync`-Übernahme in LMS mit Toleranzfenster (nur bei Sprüngen > z. B. 3 s als `seek` weiterreichen — librespot-Pfad hat dieselbe Toleranz-Philosophie).
**Warning signs:** Fortschrittsbalken in Spotify-App und LMS laufen sichtbar auseinander.

### Pitfall 6: Repeat-Modus braucht ZWEI Commands — und die Doku-Tabelle widerspricht sich selbst
**What goes wrong:** Falscher Repeat-State (z. B. Track-Repeat obwohl Context-Repeat gewünscht).
**Why it happens:** `set_repeat_context` und `set_repeat_track` sind getrennte Toggles; die offizielle Tabelle listet für "track"-Mode fälschlich `set_repeat_track: false` und korrigiert sich in der Fußnote `[CITED: websocket-api — "Note: for track mode, set set_repeat_track to enabled: true and set_repeat_context to enabled: false."]`.
**How to avoid:** Der Fußnote folgen: off=(false,false), context=(true,false), track=(false,true) — und empirisch mit `soloist ctl repeat` gegenprüfen (Wave 0).
**Warning signs:** `options_changed`-Events mit unerwartetem Repeat-State.

### Pitfall 7: Build-Expiry (90 Tage, Exit-Code 10) trifft den persistenten Daemon härter
**What goes wrong:** Ein abgelaufenes Binary beendet sich mit Code 10; der Crash-Backoff restartet vergeblich alle 5 s → 300 s — Log-Spam, kein Playback, unklare UX.
**Why it happens:** "Builds expire after 90 days from creation … terminates with exit code 10" `[CITED: soloist/reference/downloads-and-updates]`; live: `client expires in 80 days` im stdout-Log `[VERIFIED: probe]`. Der Phase-71-Versions-Pin verhindert Auto-Updates bewusst (D-05, one-way).
**How to avoid:** stdout-Log auf `client expires in \d+ days` parsen → Settings-Status + Warnschwelle; Exit-Code-10-Erkennung im Crash-Handler → Daemon dauerhaft stoppen (analog `_handleCredentialCrash`-Eskalation `[VERIFIED: DaemonManager.pm:522-574]`) statt Endlos-Backoff, mit klarer Settings-Meldung ("Soloist-Build abgelaufen — Update erforderlich"). Lifetime-Patcher ist Phase 74.
**Warning signs:** Wiederholte sofortige Exits mit rc=10.

### Pitfall 8: Protocol::WebSocket erst ab LMS 9.1.0 — und auf Debian in ZWEI Verzeichnissen
**What goes wrong:** `require Protocol::WebSocket::Client` schlägt auf LMS 8.x/9.0 fehl; selbst auf 9.1+ liegt `Frame.pm` u. U. woanders als `Client.pm`.
**Why it happens:** Gebündelt seit slimserver-Commit vom 2024-12-12, released mit LMS 9.1.0 (2026-02-19, "Added a Simple WebSocket client capability for 3rd Party Plugins", PR #1245) `[CITED: lyrion.org/getting-started/changelog-lms9/; Commit-Daten VERIFIED: gh api LMS-Community/slimserver]`. Auf dem Debian-9.2-Install liegt `Frame.pm` unter `lib/Protocol/WebSocket/`, der Rest unter `CPAN/Protocol/WebSocket/` `[VERIFIED: Datei-Inspektion + Probe-Fehlschlag mit nur CPAN/ in @INC this session]` — im LMS-Prozess sind beide in @INC, standalone-Tests brauchen beide Pfade.
**How to avoid:** Laufzeit-Gate: `eval { require Protocol::WebSocket::Client }`; bei Fehlschlag Vendoring-Fallback aus dem Plugin-Zip laden (Entscheidung A1) oder Soloist-Backend mit Settings-Warnung "benötigt LMS 9.1+" gaten. Tests: beide LMS-Pfade in @INC.
**Warning signs:** "Can't locate Protocol/WebSocket/Frame.pm in @INC".

### Pitfall 9: mDNS-Port-Contention bei mehreren Soloist-Instanzen
**What goes wrong:** Mehrere gleichzeitig startende Daemons konkurrieren um mDNS-Ressourcen (bei librespot als GH #113 real).
**Why it happens:** Jeder per-Player-Daemon announced sich selbst; Soloists Multi-Instanz-mDNS-Verhalten ist unerprobt.
**How to avoid:** Bestehenden `STAGGER_DELAY`-Mechanismus unverändert nutzen `[VERIFIED: DaemonManager.pm:34-36]`; Wave-0-Test mit 2+ Daemons auf einem Host.
**Warning signs:** Nur ein Soloist-Gerät im Device-Picker sichtbar, obwohl mehrere laufen.

## Code Examples

### Soloist-Daemon-Invocation (persistent, verifizierte Flags)
```sh
# Source: soloist --help (binary probe this session) + Pattern 5
soloist -n "Wohnzimmer" -k "$SPAK_KEY" \
  -D /path/cachedir/spoton/soloist/players/aabbccddeeff/data \
  -C /path/cachedir/spoton/soloist/players/aabbccddeeff/cache \
  -w 127.0.0.1:0
# → schreibt <data>/ws.addr, <data>/ws.port, <data>/soloist.pid, <data>/.lock
```

### WS-Session-Ablauf (live verifiziert)
```
connect ws://127.0.0.1:<ws.port>
<- {"type":"auth_state","logged_in":false,"is_active":false,"device_name":"…"}
-> {"type":"command","command":"get_auth_state"}
<- {"type":"auth_state","logged_in":false,…}
-> {"type":"command","command":"pause"}          # vor Login:
<- {"type":"error","message":"command requires authentication"}
-> {"type":"bogus"}
<- {"type":"error","message":"invalid JSON or missing required fields"}
```

### Perl-WS-Client-Kern
Siehe Pattern 2 — der Skeleton wurde in dieser Session 1:1 gegen den echten Daemon ausgeführt (Handshake, Events, Commands, Fehlerpfade).

### Event-Übersetzung (Konzept für SoloistWS::_dispatchEvent)
```perl
# Source: Mapping-Tabelle Pattern 3; spottyconnect-Vokabular VERIFIED Connect.pm:520-912
my %dispatch = (
    track_changed    => sub { … executeRequest($client, ['spottyconnect', $isNew ? 'start' : 'change', $newId, $prevId]) },
    playback_changed => sub { $_[0]->{status} =~ /^(paused|stopped)$/ ? _emit('stop') : _emit('resume') },
    volume_changed   => sub { _emit('volume', $_[0]->{volume}) },
    position_sync    => sub { _emit('seek', $_[0]->{position}{position_ms} / 1000) if $jumpExceedsTolerance },
    device_changed   => sub { $_[0]->{is_active} ? _sessionStart() : _emit('stop') },
);
```

### fake-libpulse HTTP-Server (C-Konzeptskizze)
```c
/* Source: Design nach librespot-spoton/src/unified.rs /stream-Relay (VERIFIED),
   Einbettungspunkt pa_stream_write VERIFIED fake-libpulse.c:675-711 */
static ring_buffer_t ring;              /* bounded, ~1-2 s S16LE */
int pa_stream_write(...) {
    /* f32 -> s16 konvertieren, in Ring schreiben;
       Ring voll + Client verbunden -> pthread_cond_wait (Pacing);
       Ring voll + kein Client      -> älteste Bytes verwerfen */
}
static void *http_thread(void *arg) {
    /* bind 127.0.0.1:0 -> Port in getenv("SPOTON_SOLOIST_HTTP_PORT_FILE") schreiben
       accept-Loop: GET /stream -> Header:
         "HTTP/1.0 200 OK\r\nContent-Type: audio/L16;rate=44100;channels=2\r\n\r\n"
       dann Ring -> Socket; neuer Client -> Takeover (alten Socket schließen) */
}
```

## State of the Art

| Old Approach (Phase 72) | Current Approach (Phase 73) | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Per-Track `--single-track`-Spawn via custom-convert.conf | Persistenter Daemon, WS-`play`-Commands | Phase 73 | data-dir-Lock weg → Gapless/Crossfade möglich; Session-Restore-Latenz pro Track entfällt |
| sox-Pipeline float32→S16LE (`sol pcm`-Regel) | Konvertierung in fake-libpulse (C) | Phase 73 | sox-Systemabhängigkeit entfällt komplett |
| Pairing via SSH (`--pair` manuell) | Pairing = Gerät in Spotify-App wählen (Daemon läuft ja) | Phase 73 | Kein SSH mehr nötig; Phase-74-"Pairing-Flow in Settings" schrumpft auf Status-Anzeige |
| `canSeek` = 0 für Soloist | Seek via WS `seek {position_ms}` | Phase 73 | Seek-Bar funktioniert für Soloist-Browse |
| `contentType 'sol'` + Transcoder-Profil | HTTP-Direct-Stream (`getFormatForURL` → 'pcm' für `/stream`-URLs, bestehende Logik) | Phase 73 | `sol`-Convert-Regeln + Launcher entfernbar |

**Deprecated/outdated nach dieser Phase:** `spoton-soloist`-Launcher-Wrapper, `sol pcm`-Regel, `SPOTON_SOLOIST_PCM_FD`-Pfad in fake-libpulse (bleibt als Fallback-Env erhalten oder wird entfernt — Planner-Entscheidung).

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Vendoring von Protocol::WebSocket 0.26 im Plugin-Zip funktioniert auf LMS 8.x (Perl ≥ 5.10-kompatibel, keine XS-Teile) `[ASSUMED — pure-Perl-Charakter verifiziert am 9.2-Bundle, aber nie auf einem echten LMS-8.x-System getestet]` | Standard Stack, Pitfall 8 | Soloist-Connect müsste auf LMS ≥ 9.1 gegatet werden (akzeptabler Fallback; braucht User-Entscheid) |
| A2 | Soloist stoppt/pausiert nach Ende eines per WS-`play` gestarteten Einzeltracks statt unkontrolliert weiterzuspielen, bzw. Autoplay ist über die geseedete Queue beherrschbar `[ASSUMED]` | Pattern 6, Pitfall 4 | Modell B braucht zusätzliche Korrektur-Logik; schlimmstenfalls Modell-Wechsel — Wave-0-Test PFLICHT |
| A3 | Soloist attenuiert PCM NICHT selbst, sondern setzt Lautstärke via `pa_context_set_sink_input_volume` (fake-libpulse-No-Op) → bit-perfektes PCM + `volume_changed`-Events für LMS `[ASSUMED — Stub implementiert die Funktion (VERIFIED fake-libpulse.c:512-519), aber ob Soloist NUR diesen Pfad nutzt, ist unbewiesen]` | Pattern 3 (volume) | Doppelte Attenuation (Soloist + LMS) → leises Audio; Wave-0-Hörtest bei 50 % App-Volume |
| A4 | `track_changed`/`playback_changed`/`position_sync`/`device_changed`-Payloads entsprechen exakt der Doku (nur `auth_state` + Fehlerpfade wurden live verifiziert, die Playback-Events erfordern eine eingeloggte Session) `[ASSUMED auf Payload-Detail-Ebene, CITED auf Event-Ebene]` | Pattern 3 | Feldnamen-Abweichungen → Parser-Anpassung in Wave 0 (trivial, `soloist ctl trace` liefert Ground Truth in Minuten) |
| A5 | Ein blockierender Producer in `pa_stream_write` (volle Ringpuffer) destabilisiert Soloists interne Watchdogs nicht `[ASSUMED — reale PA-Clients blockieren ebenso, aber Soloists Timeout-Verhalten ist unbekannt]` | Pattern 1 | Fallback: Drop-Oldest statt Blockieren (Pacing dann über writable_size-Drosselung) |
| A6 | Mehrere Soloist-Instanzen auf einem Host koexistieren (mDNS, Cast-Discovery) `[ASSUMED]` | Pitfall 9 | Multi-Player-Systeme zeigen nur ein Gerät; Stagger mildert, löst aber nicht jede Kollision |
| A7 | `-i/--initial-volume` und Default 40 gelten auch im Daemon-Betrieb; Volume-Seeding analog librespot nötig `[VERIFIED Flag-Existenz via --help; ASSUMED Verhalten]` | Pattern 5 | Falsches Start-Volume nach Transfer — kosmetisch |

## Open Questions (RESOLVED)

1. **Was passiert am Ende eines WS-`play {uri}`-Einzeltracks (A2)?** — **RESOLVED-BY-SPIKE (73-03 Task 1):** Wave-0-Spike (`soloist ctl trace`) ist als verpflichtender erster Task in Plan 73-03 eingeplant; Protokoll landet in 73-SPIKE-NOTES.md.
   - What we know: `play` akzeptiert optional eine URI; Soloist hat Autoplay/Smart-Shuffle als Produktfeatures; `--single-track` (anderer Modus) beendet den Prozess nach dem Track.
   - What's unclear: stoppt/pausiert der Daemon, feuert `playback_changed{status:stopped}`, oder greift Autoplay?
   - Recommendation: Wave-0-Task: paired Daemon + `soloist ctl trace` + einen Track spielen; Events am Track-Ende protokollieren. Erst danach die Modell-B-Advance-Logik festschreiben.
2. **Verhält sich `play {uri}` mit Album-/Playlist-URIs kontextbildend?** (Für Repeat-Context/Autoplay-Beherrschung relevant.) — **RESOLVED-BY-SPIKE (73-03 Task 1):** im selben Wave-0-Spike abgedeckt.
3. **LMS-Versions-Gate vs. Vendoring (A1)** — **RESOLVED (User-Entscheidung, 2026-08-26): Vendoring.** Protocol::WebSocket 0.26 (pure Perl) wird ins Plugin-Zip vendored (`Plugins/SpotOn/Vendor/Protocol/WebSocket/`); kein LMS-Versions-Gate, Soloist Connect läuft auf LMS 8.0+. Die LMS-gebündelte Kopie (ab 9.1) hat Vorrang, der Vendor-Fallback greift nur bei fehlendem Bundle. → D-08 in 73-CONTEXT.md, umgesetzt in 73-01 Task 2.
4. **Werden `queue_changed`-Events auch bei `add_to_queue` durch den WS-Client selbst gefeuert (Echo)?** Wichtig für Modell-B-Bestätigungslogik. — **RESOLVED-BY-SPIKE (73-03 Task 1):** Wave-0-Trace im Spike-Protokoll.
5. **Bleibt die Session gültig, wenn der User Free-Account nutzt und Premium-Features (Gapless/Crossfade "Premium only") wegfallen?** Erwartung: ja, ohne Crossfade — kein Blocker, aber UX-Doku. (Kein Planungs-Blocker — als TROUBLESHOOTING/Doku-Punkt getragen, keine offene Entscheidung.)

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Soloist-Binary (Pin 1.3.7.489) | Daemon | ✓ (Dev: cachedir, Phase 72 validiert) | 1.3.7.489 | Auto-Download (Soloist.pm, Phase 71) |
| fake-libpulse.so.0 (3 Arches) | Audio-Abgriff | ✓ Repo + CI `build-fake-libpulse.yml` | — | — |
| Protocol::WebSocket | WS-Client | ✓ auf Dev (LMS 9.2.0); ✗ auf LMS < 9.1.0 | 0.26 | Vendoring im Plugin-Zip (A1) |
| gcc/cross-gcc CI | fake-libpulse-Erweiterung | ✓ (bestehender Workflow, gcc/aarch64/armhf) | — | — |
| sox | Phase-72-`sol pcm`-Regel | ✓ Dev (`/usr/bin/sox`), systemabhängig | — | **Entfällt mit Pattern 1** — Abhängigkeit wird eliminiert |
| LMS-Testinstanz | UAT | ✓ Dev-Maschine (lyrionmusicserver 9.2.0, systemd) | 9.2.0 | — |
| PipeWire-freie Daemon-Env | fake-libpulse-Ladepfad | ✓ headless (squeezeboxserver-User); ⚠ Desktop-Installs | — | Env-Härtung (Pitfall 3) |

**Missing dependencies with no fallback:** keine.
**Missing dependencies with fallback:** Protocol::WebSocket auf LMS < 9.1 (→ Vendoring/Gate, A1).

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Perl Test::More via `prove` (CI: Perl 5.36/5.38 Matrix) `[VERIFIED: .github/workflows/perl-tests.yml — verbatim: `run: prove t/`]` |
| Config file | keine (Konvention: `t/NN_name.t`) |
| Quick run command | `prove t/31_soloist_ws.t` (neu) |
| Full suite command | `prove t/` |

### Phase Requirements → Test Map
(Phase 73 hat keine formalen REQ-IDs in REQUIREMENTS.md — Mapping auf die D-Entscheidungen:)

| Req | Behavior | Test Type | Automated Command | File Exists? |
|-----|----------|-----------|-------------------|-------------|
| D-05 | WS-Message-Parsing (auth_state, error, command_result, alle Event-Typen) + Command-Serialisierung | unit | `prove t/31_soloist_ws.t` | ❌ Wave 0 |
| D-06 | Event→spottyconnect-Übersetzungstabelle (inkl. Paused/Stopped→stop-Kollaps, Repeat-Zwei-Command-Matrix) | unit | `prove t/32_soloist_events.t` | ❌ Wave 0 |
| D-01/D-02 | SoloistDaemon-Spawn-Args, data-dir-pro-Player-Pfade, Prereq-Gate-Erweiterung | unit | `prove t/28_soloist_dispatch.t` (erweitern) | ✅ vorhanden `[VERIFIED: t/28_soloist_dispatch.t existiert]` |
| D-03 | ProtocolHandler: canDirectStream→URL, canSeek=1, new()-Proxy für sol | unit | `prove t/29_soloist_browse.t` (anpassen) | ✅ vorhanden |
| D-04 | fake-libpulse f32→s16-Konvertierung + Ringpuffer (C-Unit-Test oder Host-Build-Smoke) | unit/smoke | `make -C Plugins/SpotOn/Bin/fake-libpulse test` (neu) | ❌ Wave 0 |
| D-07 | Transfer-Playback E2E (App→Soloist→LMS-Audio) | manual-only | UAT (`spoton-uat`-Skill) — Begründung: braucht echte Spotify-App + Netzwerk | — |

### Sampling Rate
- **Per task commit:** betroffene `t/2x`/`t/3x`-Dateien einzeln (`prove t/31_soloist_ws.t`)
- **Per wave merge:** `prove t/`
- **Phase gate:** `prove t/` grün + Wave-0-Empirie-Protokoll (Open Questions 1/2/4) vor `/gsd-verify-work`

### Wave 0 Gaps
- [ ] `t/31_soloist_ws.t` — WS-Frame/JSON-Parsing, Reconnect-State (deckt D-05); @INC muss `CPAN/` UND `lib/`-Pfad des LMS-Baums aufnehmen bzw. Fixture-Kopie nutzen (Pitfall 8)
- [ ] `t/32_soloist_events.t` — Event-Mapping-Tabelle (deckt D-06)
- [ ] fake-libpulse Host-Build-Test (Konvertierung/Ringpuffer)
- [ ] **Empirischer Spike (kein .t):** `soloist ctl trace`-Protokoll für Track-Ende/Autoplay/Queue-Echo (Open Questions 1, 2, 4) — MUSS vor der Modell-B-Implementierung laufen

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes | spak-Key: 0600-Datei, nie loggen (`_maskAccountId`-Disziplin); argv-Exposure = dokumentierter Accepted Risk WR-01 (unverändert aus Phase 72) |
| V3 Session Management | yes | Soloist-Session im data-dir 0700 (`make_path mode => 0700`-Pattern aus Soloist.pm beibehalten) |
| V4 Access Control | yes | WS-API + fake-libpulse-HTTP **ausschließlich 127.0.0.1** binden — die WS-API hat per Design null Auth/TLS/Origin-Checks `[CITED: websocket-api]`; der fake-libpulse-`/stream` muss allerdings wie librespot LAN-erreichbar sein (LMS-Player streamen direkt) → gleiche Exposure wie der bestehende librespot-`/stream` (unauthentifiziertes PCM, akzeptierter Status quo). Planner: bewusst dokumentieren |
| V5 Input Validation | yes | Alle WS-Payloads durch `eval { from_json }` mit Fehlerpfad; URIs vor `play`/`add_to_queue` gegen `^spotify:(track|episode):[A-Za-z0-9]+$` validieren (T-22-01-Disziplin) |
| V6 Cryptography | no (delegiert) | TLS zur Spotify-Cloud macht das Soloist-Binary selbst |

### Known Threat Patterns for this stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Lokaler Prozess sendet WS-Commands an Soloist (keine Auth) | Elevation/Tampering | 127.0.0.1-Bind; Bedrohungsmodell = lokale User auf dem LMS-Host (identisch zu librespot /control) |
| spak-Key in /proc/cmdline | Information Disclosure | Accepted Risk WR-01 (dokumentiert); hidepid=2-Hinweis in TROUBLESHOOTING |
| JSON-Parser-Crash durch malformed Event | DoS | eval-Wrap + Fehler-Log statt die (LMS-Single-Process!) |
| Stale ws.port zeigt auf fremden Prozess nach Port-Reuse | Spoofing | Pitfall-2-Mitigation (Dateien vor Start löschen, mtime-Check); zusätzlich `auth_state`-Ersthandshake als Plausibilitätscheck (`device_name` muss stimmen) |

## Sources

### Primary (HIGH confidence — tool-verifiziert diese Session)
- Soloist-Binary 1.3.7.x: `--help`, `--version`, `ctl --help`, Live-`--ws`-Probe (Handshake, auth_state, Command-/Fehlerformate, ws.addr/ws.port-Dateien, stdout-Log inkl. Expiry-Zeile), `strings`-Evidenz (dealer.g2.spotify.com, connect_mdns, libpipewire-0.3.so.0/libpulse.so.0)
- Reales Phase-72-data-dir (LMS-cachedir): `.lock`, `.device_id`, `settings/Users/<user>-user/` — Session-Persistenz empirisch belegt
- SpotOn-Codebase: `Plugins/SpotOn/Unified/DaemonManager.pm`, `Unified/Daemon.pm`, `ProtocolHandler.pm`, `Soloist.pm`, `Connect.pm`, `Bin/fake-libpulse/fake-libpulse.c`, `custom-convert.conf` (alle mit Zeilenangaben zitiert)
- librespot-Fork: `librespot-spoton/src/unified.rs` (Endpoints, Content-Type, Relay-Takeover), `src/connect.rs` (6-Command-Vokabular)
- LMS 9.2.0-Install (Dev): `Slim/Networking/SimpleWS.pm`, `Slim/Networking/IO/Select.pm`, `CPAN/Protocol/WebSocket*` + `lib/Protocol/WebSocket*` (Split-Layout)
- slimserver-Git via gh api: Protocol::WebSocket-Bundle-Commit 53146447 (2024-12-12), SimpleWS-Commits a0bfbfa9/6307ab50 (2024-12-12/13)

### Secondary (MEDIUM confidence)
- Spotify Soloist Docs (offiziell, Struktur gegen Binary quer-verifiziert): developer.spotify.com/documentation/soloist — concepts/overview, concepts/authentication, reference/command-line, reference/websocket-api, reference/soloist-ctl, reference/downloads-and-updates; Blog: developer.spotify.com/blog/2026-08-13-introducing-spotify-soloist
- lyrion.org/getting-started/changelog-lms9/ — LMS 9.1.0 (2026-02-19) "Simple WebSocket client capability for 3rd Party Plugins" (PR #1245); 9.1.1 (2026-06-17). Korrigiert CLAUDE.mds "9.1.1"-Angabe auf 9.1.0.

### Tertiary (LOW confidence)
- WebSearch zu Protocol::WebSocket-Pitfalls (metacpan.org/pod/Protocol::WebSocket u. a.) — Ping/Pong-Pflicht, Transport-Agnostik; deckungsgleich mit eigener Code-Lektüre des Bundles

## Metadata

**Confidence breakdown:**
- Standard Stack: HIGH — jede Komponente lokal vorhanden und diese Session ausgeführt/gelesen
- Architecture (D-05/D-06/D-07): HIGH — WS-API live verifiziert, Event-Doku vollständig, Registrierung binary-evident; Payload-Details der Playback-Events MEDIUM (A4)
- Architecture (D-04): MEDIUM-HIGH — Design folgt produktionsbewährter librespot-Blaupause, aber die C-Erweiterung selbst ist Neubau; Pacing-Annahme A5
- Browse-Modell B: MEDIUM — hängt an Open Question 1 (Track-Ende-Verhalten); Wave-0-Spike verpflichtend
- Pitfalls: HIGH — 7 von 9 direkt beobachtet/belegt

**Research date:** 2026-08-26
**Valid until:** 2026-09-25 (Soloist-Builds/Docs beweglich — 90-Tage-Expiry-Ökosystem; LMS-Seite stabil)

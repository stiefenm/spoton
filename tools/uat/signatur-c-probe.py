#!/usr/bin/env python3
"""signatur-c-probe.py -- Trockenlauf fuer das Signatur-C-Fenster.

Bereitschaftstor mit DREI einzeln belegten Bedingungen. Grund: ein Tor, das
nur "irgendwer antwortet auf Port 9000" prueft, kann von der STERBENDEN alten
Instanz beantwortet werden -- oder von einer neuen, die den Spieler noch nicht
kennt. Beides laesst ein playlist-play spurlos verfallen und sieht hinterher
aus wie "LMS hat es absorbiert". Genau das ist am 2026-09-14 passiert.

  Tor A: LMS-PID != PID vor dem Neustart      (neue Instanz, nicht die alte)
  Tor B: JSON-RPC liefert ein result          (Instanz dispatcht)
  Tor C: players enthaelt die MAC, connected=1 (Spieler registriert)

Jeder Zeitpunkt wird zusaetzlich gegen ws.port gestempelt -- ws.port neu
bedeutet, der Daemon hat seinen Port angekuendigt, LMS baut Control, und das
Signatur-C-Fenster ist zu.

Beleg (Messrunde 5, 2026-09-14/15): ohne die drei Bedingungen blieb die
REANFORDERUNG unquittiert; mit ihnen wurde sie in 3/3 Laeufen quittiert und
ausgefuehrt.
"""
import os, subprocess, time, json, sys

# Umgebung: SPOTON_MAC, sonst PA_MAC = MAC von lavender-pa (Pflicht, kein Default; sonst Exit 2).

MAC = os.environ.get('SPOTON_MAC') or os.environ.get('PA_MAC')
if not MAC:
    sys.stderr.write('signatur-c-probe: weder SPOTON_MAC noch PA_MAC gesetzt (MAC von lavender-pa, D-10)\n')
    sys.exit(2)
URI = os.environ.get('SPOTON_TRACK_URI', 'spoton://track:4uLU6hMCjMI75M1A2tKUQC')
# Testhaken (Quick 260915-bpd): LMS_URL macht den JSON-RPC-Zielport ohne echten LMS pruefbar,
# gleiche Form wie tools/uat/lms-cmd.sh (Quick 260910-w9q).
URL = os.environ.get('LMS_URL', 'http://127.0.0.1:9000/jsonrpc.js')
WS = os.environ.get('WS_PATH', '/var/lib/squeezeboxserver/cache/spoton/soloist/players/%s/data/ws.port' % MAC.replace(':', ''))
CATS = ["plugin.spoton","player.source","player.streaming",
        "player.streaming.direct","player.streaming.remote","control.command"]
# Testhaken (Quick 260915-bpd): SUDO_BIN macht jeden `sudo -n`-Aufruf test-passierbar,
# gleiche Konvention wie tools/uat/extract-run.pl.
SUDO_BIN = os.environ.get('SUDO_BIN', 'sudo')
# Testhaken (Quick 260915-bpd): PGREP_BIN macht Tor As Prozesspruefung ohne echten
# squeezeboxserver-Prozess deterministisch pruefbar.
PGREP_BIN = os.environ.get('PGREP_BIN', 'pgrep')
# Testhaken (Quick 260915-bpd): PROBE_TIMEOUT_S macht Tor A/B/Cs Poll-Frist in Tests klein.
PROBE_TIMEOUT_S = float(os.environ.get('PROBE_TIMEOUT_S', '90'))

def ws_mtime():
    r = subprocess.run([SUDO_BIN,'-n','stat','-c','%Y',WS], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None

def el(): return time.time() - t0
def fenster():
    """Drei Zustaende, nicht zwei. Ein fehlgeschlagenes stat (Datei waehrend des
    Neustarts geloescht) ist NICHT 'neu geschrieben' -- es heisst 'Daemon noch
    nicht da', und das Fenster ist dann OFFEN. Die Zwei-Wege-Fassung hat am
    2026-09-14 pauschal 'ZU' gemeldet, schon 0,17 s nach dem Neustart."""
    m = ws_mtime()
    if m is None:      return "offen (ws.port fehlt -- Daemon nicht da)"
    if m == BEFORE_WS: return "offen (ws.port unveraendert)"
    return "ZU (ws.port neu -- Control gebaut)"

def lms_pid():
    r = subprocess.run([PGREP_BIN,'-f','sbin/squeezeboxserver '], capture_output=True, text=True)
    return r.stdout.split()[0] if r.stdout.strip() else None

def rpc(player, cmd, timeout='3'):
    body = json.dumps({"id":1,"method":"slim.request","params":[player,cmd]})
    r = subprocess.run(['curl','-s','-m',timeout,'-X','POST',
                        '-H','Content-Type: application/json','-d',body,URL],
                       capture_output=True, text=True)
    try:
        return json.loads(r.stdout)
    except Exception:
        return None

# Testhaken (Quick 260915-bpd): --check-fenster <before> ist ein isolierter Selbsttest der
# Drei-Wege-Fensteranzeige -- kein Restart, kein Tor A/B/C, keine echte Anlage beruehrt.
if len(sys.argv) >= 3 and sys.argv[1] == '--check-fenster':
    BEFORE_WS = sys.argv[2]
    print(fenster())
    sys.exit(0)

BEFORE_WS  = ws_mtime()
BEFORE_PID = lms_pid()
print(f"vor dem Neustart: LMS-PID={BEFORE_PID}  ws.port-mtime={BEFORE_WS}")

t0 = time.time()
subprocess.run([SUDO_BIN,'-n','systemctl','restart',os.environ.get('LMS_SERVICE', 'lyrionmusicserver')], check=True)

def stamp(label, extra=""):
    print(f"  {label:<34} +{el():5.2f}s   Fenster: {fenster():<42} {extra}")

# --- Tor A ---
pid = None
while el() < PROBE_TIMEOUT_S:
    p = lms_pid()
    if p and p != BEFORE_PID:
        pid = p; break
    time.sleep(0.05)
if not pid:
    print("TOR A ROT: keine neue LMS-PID binnen 90 s -- Lauf ungueltig"); sys.exit(1)
stamp("Tor A: neue LMS-PID", f"pid={pid}")

# --- Tor B ---
ok_b = False
while el() < PROBE_TIMEOUT_S:
    d = rpc("", ["serverstatus","0","1"])
    if d and "result" in d:
        ok_b = True; break
    time.sleep(0.05)
if not ok_b:
    print("TOR B ROT: JSON-RPC liefert kein result -- Lauf ungueltig"); sys.exit(1)
stamp("Tor B: JSON-RPC dispatcht")

# --- Kategorien scharfstellen (vor Tor C, damit nichts verloren geht) ---
for c in CATS:
    rpc("", ["debug", c, "DEBUG"])
rpc("", ["pref","plugin.spoton:diagnosticMode","1"])
bad = [c for c in CATS
       if (rpc("", ["debug", c, "?"]) or {}).get("result",{}).get("_value") != "DEBUG"]
if bad:
    print(f"SCHALTER ROT: {bad} nicht bestaetigt -- Lauf ungueltig"); sys.exit(1)
stamp("Kategorien scharf (6/6 bestaetigt)")

# --- Tor C ---
ok_c = False
while el() < PROBE_TIMEOUT_S:
    d = rpc("", ["players","0","20"])
    if d and "result" in d:
        for p in d["result"].get("players_loop", []):
            if p.get("playerid") == MAC and p.get("connected") == 1:
                ok_c = True; break
    if ok_c: break
    time.sleep(0.05)
if not ok_c:
    print("TOR C ROT: Spieler nicht registriert -- NICHT feuern, Lauf ungueltig"); sys.exit(1)
stamp("Tor C: Spieler registriert")

# --- feuern ---
d = rpc(MAC, ["playlist","play",URI], timeout='8')
quittiert = bool(d and "result" in d)
stamp("REANFORDERUNG abgesetzt", f"quittiert={quittiert}")
if not quittiert:
    print("  !! NICHT QUITTIERT -- nichts wurde ausgefuehrt. Messung UNGUELTIG,")
    print("     nicht 'LMS hat absorbiert'.")
    sys.exit(3)

# --- Fensterschluss abwarten ---
while el() < 60:
    m = ws_mtime()
    if m is not None and m != BEFORE_WS: break
    time.sleep(0.1)
print(f"  {'ws.port neu (Fenster zu)':<34} +{el():5.2f}s")

#!/usr/bin/perl

# tools/soloist-ws-record.pl
#
# Standalone, LMS-free WS mitschnittwerkzeug fuer den Soloist-Daemon (D-15,
# Phase 81). Verbindet direkt auf den Daemon-eigenen WS-Control-Port
# (players/<mac>/data/ws.port) ueber das vendorierte
# Protocol::WebSocket::Client -- kein websocat, kein CPAN, kein laufendes
# LMS noetig. Standardmodus ist PASSIV: es wird nichts gesendet, solange
# --send nicht explizit gesetzt ist (das Instrument darf sich nicht selbst
# messen, D-15). Jeder empfangene/gesendete Frame wird als eine Zeile JSONL
# geschrieben (Rohtext im "frame"-Feld, Sidecar-Zeitstempel ts/epoch).
#
# Usage:
#   perl tools/soloist-ws-record.pl --mac 02:00:00:5a:11:01 --seconds 30 \
#     --out /tmp/rec.jsonl
#   perl tools/soloist-ws-record.pl --mac 02:00:00:5a:11:01 \
#     --send get_auth_state --send get_state --send 'play:spotify:track:XXXX'
#   perl tools/soloist-ws-record.pl --preflight --mac 02:00:00:5a:11:01 \
#     --expect-device lavender-UAT
#   perl tools/soloist-ws-record.pl --help
#
# Flags:
#   --mac <aa:bb:cc:dd:ee:ff>   Player-MAC; Port wird aus ws.port aufgeloest
#   --port <n>                 Expliziter Port (schlaegt --mac)
#   --host <addr>               Default 127.0.0.1 (muss Loopback sein)
#   --cache-dir <dir>          Default /var/lib/squeezeboxserver/cache
#   --min-mtime <epoch>        Referenzzeit fuer die ws.port-Staleness-Regel
#   --seconds <n>               Laufzeit; ohne Angabe bis EOF/SIGINT
#   --out <datei>               Default stdout
#   --send <spec>                wiederholbar; roh-JSON oder Kurzform (siehe unten)
#   --expect-device <name>      erwarteter device_name im ersten auth_state
#   --preflight                  einmaliger get_auth_state-Check, dann Exit
#   --lms-url <url>              Default http://127.0.0.1:9000/jsonrpc.js (LMS JSON-RPC)
#   --reannounce-lms <json>     Opt-in (Default: nicht gesetzt): LMS-Reanforderung im
#                                HANDSHAKE-OK-Callback, JSON-Array ["<playerid>","<cmd>",...]
#   --help                       Bedienhilfe, Exit 0
#
# --send-Kurzformen: get_auth_state, get_state, get_queue, play[:<uri>],
#   pause, skip_next, skip_prev, seek:<ms>, set_volume:<0-100>,
#   add_to_queue:<uri>. Roh-JSON (beginnt mit "{") wird unveraendert gesendet.
#
# Exit-Codes: 0 = OK (bzw. preflight logged_in), 1 = Fehler/Ablehnung
#   (ungueltiges Kommando, RMS-aehnliche Validierungsfehler), 2 = Verbindung/
#   Port/Loopback-Verweigerung, 3 = device mismatch (--expect-device).
#
# Security (T-73-01/T-81-02, Tampering): der WS-Socket des Daemons hat KEINE
# Auth-, TLS- oder Origin-Pruefung (RESEARCH Security Domain V3) -- deshalb
# erzwingt is_loopback() Verbindungen ausschliesslich auf 127.0.0.0/8, ::1
# oder localhost, VOR jedem Verbindungsversuch (Exit 2, keine Ausnahme).
# T-74-09 (Information Disclosure): der spak-Key und auth_data-Bytes werden
# von diesem Werkzeug nie angefasst, nie geloggt -- es sieht nur WS-Frames.
# Passivmodus ist Default (T-81-03): write() wird nie aufgerufen, solange
# --send nicht gesetzt ist -- sonst misst das Instrument sich selbst.
#
# Modulino-Konvention (neu fuer tools/, siehe t/43_soloist_ws_record.t):
# main(@ARGV) laeuft nur, wenn dieses Skript direkt aufgerufen wird (nicht
# per require), damit Tests die Subs isoliert laden koennen.

use strict;
use warnings;

use FindBin qw($RealBin);
use lib "$RealBin/..";
use lib "$RealBin/../Plugins/SpotOn/Vendor";   # push-Fallback, wie Soloist::ensureWsLib

use IO::Socket::INET;
use IO::Handle;
use IO::Select;
use Time::HiRes qw(time);
use POSIX qw(strftime);
use Getopt::Long qw(GetOptionsFromArray);
use JSON::PP qw(encode_json decode_json);
use File::Spec;
use Encode qw(decode);

require Protocol::WebSocket::Client;

# ------------------------------------------------------------
# fail($stage, $message) -- stage-labelled non-zero exit (spclient-smoke.pl:62-66)
# ------------------------------------------------------------
sub fail {
    my ($stage, $msg, $code) = @_;
    $code = defined($code) ? $code : 1;
    print STDERR "FAIL [$stage]: $msg\n";
    exit $code;
}

# ------------------------------------------------------------
# usage() -- prints the bedienhilfe to stdout, exit 0 caller-controlled
# ------------------------------------------------------------
sub usage {
    return <<'USAGE';
tools/soloist-ws-record.pl -- Pure-Perl WS-Mitschnitt fuer den Soloist-Daemon (D-15)

Usage:
  perl tools/soloist-ws-record.pl --mac <mac> [--seconds N] [--out FILE] [--send SPEC ...]
  perl tools/soloist-ws-record.pl --preflight --mac <mac> [--expect-device NAME]
  perl tools/soloist-ws-record.pl --help

Flags:
  --mac <aa:bb:cc:dd:ee:ff>   Player-MAC, Port aus ws.port aufgeloest
  --port <n>                  Expliziter Port (schlaegt --mac)
  --host <addr>                Default 127.0.0.1 (nur Loopback erlaubt)
  --cache-dir <dir>            Default /var/lib/squeezeboxserver/cache
  --min-mtime <epoch>          Referenzzeit fuer ws.port-Staleness
  --seconds <n>                 Laufzeit in Sekunden (Default: bis EOF/SIGINT)
  --out <datei>                 Default stdout
  --send <spec>                 wiederholbar, Reihenfolge erhalten
  --expect-device <name>        erwarteter device_name
  --preflight                    einmaliger get_auth_state-Check
  --lms-url <url>                Default http://127.0.0.1:9000/jsonrpc.js
  --reannounce-lms <json>       Opt-in: ["<playerid>","<cmd>",...], Default: nicht gesetzt
  --help                         diese Hilfe, Exit 0

--send-Kurzformen:
  get_auth_state, get_state, get_queue, play, play:<uri>, pause,
  skip_next, skip_prev, seek:<ms>, set_volume:<0-100>, add_to_queue:<uri>
  Roh-JSON (beginnt mit "{") wird unveraendert gesendet.

Exit: 0 OK, 1 Fehler/Ablehnung, 2 Verbindung/Port/Loopback, 3 device mismatch.
USAGE
}

# ------------------------------------------------------------
# is_loopback($host) -- wahr nur fuer 127.0.0.0/8, ::1, localhost (T-81-02)
# ------------------------------------------------------------
sub is_loopback {
    my ($host) = @_;
    return 0 unless defined $host;
    return 1 if $host eq 'localhost';
    return 1 if $host eq '::1';
    return 1 if $host =~ /\A127\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\z/
        && $1 <= 255 && $2 <= 255 && $3 <= 255;
    return 0;
}

# ------------------------------------------------------------
# validate_uri($uri) -- SoloistWS.pm:333, gehaertet um \z statt $ (81-02,
# t/43 Gruppe 'uri'/T-81-04): Perl's $ matches BEFORE a trailing "\n", so
# the literal SoloistWS.pm:333 regex accepts "spotify:track:abc\n" -- a
# newline-smuggling gap in the tool's own --send URI gate. SoloistWS.pm
# itself carries the identical regex at :333/:635/:859 but is out of scope
# for this plan (files_modified, "! git status --porcelain -- Plugins/SpotOn"
# verify gate) -- logged to WINDOWS.md as a deferred finding for the plugin.
# ------------------------------------------------------------
sub validate_uri {
    my ($uri) = @_;
    return 0 unless defined $uri;
    return $uri =~ /\A spotify:(?:track|episode):[A-Za-z0-9]+ \z/x ? 1 : 0;
}

# ------------------------------------------------------------
# resolve_port(\%opt) -- baut den ws.port-Pfad, liest bei JEDEM Aufruf frisch
# (D-15, kein Caching), verwirft mtime < Referenzzeit (SoloistDaemon.pm:303-313)
# Returns: ($port, $reason) -- $port undef bei Fehler, $reason erklaert warum
# ------------------------------------------------------------
sub resolve_port {
    my ($opt) = @_;

    return ($opt->{port}, 'explicit --port') if defined $opt->{port};

    my $mac = $opt->{mac};
    return (undef, 'no --mac or --port given') unless defined $mac;

    (my $clean = $mac) =~ s/://g;
    my $cache_dir = $opt->{cache_dir} || '/var/lib/squeezeboxserver/cache';
    my $data_dir = File::Spec->catdir($cache_dir, 'spoton', 'soloist', 'players', $clean, 'data');

    my $pid_file = File::Spec->catfile($data_dir, 'soloist.pid');
    my $ref_mtime = $opt->{min_mtime};
    if (!defined $ref_mtime) {
        # Fail-closed (81-REVIEW.md WR-02): a missing or unparseable
        # soloist.pid must not silently disable the staleness check below --
        # that is exactly the scenario (dead/foreign process, no pid file)
        # where a stale ws.port is most likely and most dangerous to trust.
        # Mirrors the explicit-error style already used for the sibling
        # ws.port-unparseable case a few lines down.
        open(my $pfh, '<', $pid_file)
            or return (undef, "cannot open $pid_file: $!");
        my $pid_line = readline($pfh);
        close($pfh);
        return (undef, 'soloist.pid content unparseable')
            unless defined $pid_line && $pid_line =~ /^(\d+)\s*$/;
        my $pid = $1;
        my @pstat = stat("/proc/$pid");
        return (undef, "daemon pid $pid not running") unless @pstat;
        $ref_mtime = $pstat[10];   # ctime of /proc/<pid> == process start reference
    }

    my $port_file = File::Spec->catfile($data_dir, 'ws.port');
    my @stat = stat($port_file);
    return (undef, "cannot stat $port_file: $!") unless @stat;

    my $mtime = $stat[9] || 0;
    return (undef, "ws.port stale (mtime=$mtime < ref=$ref_mtime)") if $mtime < $ref_mtime;

    open(my $fh, '<', $port_file) or return (undef, "cannot open $port_file: $!");
    my $line = readline($fh);
    close($fh);
    return (undef, 'ws.port content unparseable') unless defined $line && $line =~ /^(\d+)\s*$/;

    return ($1 + 0, 'fresh read');
}

# ------------------------------------------------------------
# build_command($spec) -- rohes JSON oder Kurzform verb[:arg]; undef bei
# unbekanntem Verb. uri-Argumente laufen durch validate_uri.
# ------------------------------------------------------------
sub build_command {
    my ($spec) = @_;
    return undef unless defined $spec && length $spec;

    if ($spec =~ /^\{/) {
        my $decoded = eval { decode_json($spec) };
        return undef if $@;
        return $spec;
    }

    my ($verb, $arg) = split(/:/, $spec, 2);

    if ($verb eq 'get_auth_state' || $verb eq 'get_state') {
        return encode_json({ type => 'command', command => $verb });
    }
    if ($verb eq 'get_queue') {
        return encode_json({ type => 'command', command => 'get_queue', limit => 10 });
    }
    if ($verb eq 'pause' || $verb eq 'skip_next' || $verb eq 'skip_prev') {
        return encode_json({ type => 'command', command => $verb });
    }
    if ($verb eq 'play') {
        my %msg = (type => 'command', command => 'play');
        if (defined $arg && length $arg) {
            return undef unless validate_uri($arg);
            $msg{uri} = $arg;
        }
        return encode_json(\%msg);
    }
    if ($verb eq 'add_to_queue') {
        return undef unless defined $arg && validate_uri($arg);
        return encode_json({ type => 'command', command => 'add_to_queue', uri => $arg });
    }
    if ($verb eq 'seek') {
        return undef unless defined $arg && $arg =~ /^\d+$/;
        return encode_json({ type => 'command', command => 'seek', position_ms => $arg + 0 });
    }
    if ($verb eq 'set_volume') {
        return undef unless defined $arg && $arg =~ /^\d+$/ && $arg >= 0 && $arg <= 100;
        return encode_json({ type => 'command', command => 'set_volume', volume => $arg + 0 });
    }

    return undef;
}

# ------------------------------------------------------------
# ts_now() -- Wanduhr HH:MM:SS.mmm, Spiegel von fake-libpulse::_trace_ts (Uhr C)
# ------------------------------------------------------------
sub ts_now {
    my $t = time();
    return strftime("%H:%M:%S", localtime($t)) . sprintf(".%03d", (($t - int($t)) * 1000));
}

# ------------------------------------------------------------
# jsonl_line($dir, $text) -- baut EINE JSONL-Zeile (UTF-8-Oktette, endet mit
# "\n") und gibt sie als String zurueck (reine Funktion, t/43 D-15-Vertrag).
# Aufrufer schreiben selbst: print {$fh} jsonl_line($dir, $text);
#
# $text kommt aus dem vendorierten Protocol::WebSocket::Frame.pm:98 bereits
# per Encode::decode('UTF-8', ...) dekodiert an (also ein Unicode-Zeichen-
# string, UTF8-Flag gesetzt) fuer jeden echten Frame. encode_json() laeuft
# hier im modul-globalen utf8(1)-Modus und kodiert jeden ihm uebergebenen
# Perl-String selbst nach UTF-8 -- ein zusaetzliches utf8::encode() VOR
# diesem Aufruf fuehrt zu Doppelkodierung (jedes Nicht-ASCII-Zeichen wird
# zweimal nach UTF-8 kodiert, siehe 81-REVIEW.md CR-01). Normalisieren wir
# stattdessen IMMER auf eine dekodierte Zeichenkette (nur falls das
# UTF8-Flag noch nicht gesetzt ist -- z.B. reine ASCII-Bytes aus Tests),
# bevor wir sie encode_json uebergeben.
# ------------------------------------------------------------
sub jsonl_line {
    my ($dir, $text) = @_;
    $text = decode('UTF-8', $text) unless utf8::is_utf8($text);
    my $t = time();
    my $line = encode_json({
        ts    => ts_now(),
        epoch => $t + 0,
        dir   => $dir,
        frame => $text,
    });
    return $line . "\n";
}

# ------------------------------------------------------------
# check_device($frame_hash, $expected) -- fail-closed Geraetevergleich
# (T-73-04/T-81-01): ohne $expected oder ohne device_name im Frame ist das
# Ergebnis immer 0. Gemeinsamer Einhaengepunkt fuer preflight() und
# run_recorder().
# ------------------------------------------------------------
sub check_device {
    my ($frame, $expected) = @_;
    return 0 unless defined $expected;
    my $device = $frame->{device_name};
    return 0 unless defined $device;
    return ($device eq $expected) ? 1 : 0;
}

# ------------------------------------------------------------
# build_lms_request($url, $playerid, \@cmd) -- baut vollstaendige HTTP/1.1
# POST-Bytes fuer LMS' JSON-RPC-Endpunkt (slim.request). LMS verlangt die
# VERSCHACHTELTE params-Form [$playerid, \@cmd] -- Slim::Web::JSONRPC.pm:219
# prueft ref($params->[1]) als Array; ein flaches params-Array fuehrt STILL
# KEINEN Request aus. Reine Funktion, kein Socket (t/43).
# ------------------------------------------------------------
sub build_lms_request {
    my ($url, $playerid, $cmd) = @_;

    my ($host, $port, $path) = $url =~ m{\A https?://([^:/]+)(?::(\d+))?(/.*)?\z}x;
    $port = defined($port) ? $port : 80;
    $path = (defined($path) && length($path)) ? $path : '/';

    my $body = encode_json({
        id     => 1,
        method => 'slim.request',
        params => [ $playerid, $cmd ],
    });
    utf8::encode($body) if utf8::is_utf8($body);
    my $len = length($body);

    return "POST $path HTTP/1.1\r\n"
         . "Host: $host\r\n"
         . "Content-Type: application/json\r\n"
         . "Content-Length: $len\r\n"
         . "Connection: close\r\n"
         . "\r\n"
         . $body;
}

# ------------------------------------------------------------
# parse_lms_response($bytes) -- Quittungspruefung wie tools/uat/lms-cmd.sh:
# leerer Rumpf, Verbindungsabbruch ohne Bytes, oder eine Antwort ohne
# result-Feld sind je fuer sich UNGUELTIG. Stirbt niemals bei kaputten/
# unvollstaendigen Bytes (t/43).
# ------------------------------------------------------------
sub parse_lms_response {
    my ($bytes) = @_;

    return { ok => 0, reason => 'empty response (connection closed without bytes)' }
        unless defined $bytes && length $bytes;

    my ($header, $body) = split(/\r\n\r\n/, $bytes, 2);
    return { ok => 0, reason => 'no header/body separator found in response' }
        unless defined $body && length $body;

    my $decoded = eval { decode_json($body) };
    return { ok => 0, reason => "response body is not valid JSON: $@" } if $@;
    return { ok => 0, reason => 'response missing result field' }
        unless ref($decoded) eq 'HASH' && exists $decoded->{result};

    return { ok => 1, result => $decoded->{result} };
}

# ------------------------------------------------------------
# preflight(\%opt) -- verbindet, sendet genau get_auth_state, wartet <=5s
# ------------------------------------------------------------
sub preflight {
    my ($opt) = @_;

    my $host = $opt->{host} || '127.0.0.1';
    fail('loopback', "refusing non-loopback address: $host", 2) unless is_loopback($host);

    my ($port, $reason) = resolve_port($opt);
    fail('port', $reason, 2) unless defined $port;

    my $sock = IO::Socket::INET->new(
        PeerAddr => $host, PeerPort => $port, Proto => 'tcp', Timeout => 2,
    );
    fail('connect', "connect failed to $host:$port: $!", 2) unless $sock;
    $sock->blocking(0);

    my $client = Protocol::WebSocket::Client->new(url => "ws://$host:$port");

    my %result;
    my $handshake_done = 0;

    $client->on(
        write   => sub { syswrite($sock, $_[1]) },
        read    => sub {
            my $text = $_[1];
            utf8::encode($text) if utf8::is_utf8($text);
            my $msg = eval { decode_json($text) };
            return if $@ || ref($msg) ne 'HASH';
            if (($msg->{type} || '') eq 'auth_state') {
                %result = %$msg;
            }
        },
        error   => sub { },
        eof     => sub { },
        connect => sub {
            $handshake_done = 1;
            $client->write(build_command('get_auth_state'));
        },
    );
    $client->connect;

    my $end = time() + 5;
    while (time() < $end && !%result) {
        my $rin = '';
        vec($rin, fileno($sock), 1) = 1;
        if (select(my $r = $rin, undef, undef, 0.2)) {
            my $n = sysread($sock, my $buf, 65536);
            last if !defined $n || $n == 0;
            $client->read($buf);
        }
    }

    close($sock);

    unless (%result) {
        fail('preflight', 'no auth_state received within 5s', 2);
    }

    my $logged_in = $result{logged_in} ? 1 : 0;
    my $is_active = $result{is_active} ? 1 : 0;
    my $device = $result{device_name} // '';

    my $pid_file_dir;
    {
        (my $clean = ($opt->{mac} // '')) =~ s/://g;
        my $cache_dir = $opt->{cache_dir} || '/var/lib/squeezeboxserver/cache';
        $pid_file_dir = File::Spec->catdir($cache_dir, 'spoton', 'soloist', 'players', $clean, 'data');
    }
    my $pid = '?';
    if (open(my $pfh, '<', File::Spec->catfile($pid_file_dir, 'soloist.pid'))) {
        my $line = readline($pfh);
        close($pfh);
        ($pid = $line) =~ s/\s+$// if defined $line;
    }

    print "PREFLIGHT mac=" . ($opt->{mac} // '?') . " port=$port pid=$pid logged_in=$logged_in is_active=$is_active device=$device\n";

    if (defined $opt->{expect_device} && !check_device(\%result, $opt->{expect_device})) {
        exit 3;
    }

    exit($logged_in ? 0 : 1);
}

# ------------------------------------------------------------
# run_recorder(\%opt) -- der eigentliche Mitschnitt; passiv, ausser --send
# gesetzt. Gibt den Exit-Code zurueck (0 OK, 2 Handshake-Timeout nach 5s
# ohne WS-Connect, 3 device mismatch) -- main() ist die einzige Stelle,
# die tatsaechlich exit() aufruft (t/43 D-15: testbar per direktem
# Sub-Aufruf, ohne den Testprozess zu beenden).
#
# Testhaken (81-02, additiv): client_factory (Default: echtes
# Protocol::WebSocket::Client->new) und sock (Default: echtes
# IO::Socket::INET, per resolve_port aufgeloest) -- damit kann t/43 die
# Sendelogik gegen einen Mock/ein socketpair pruefen, ohne einen Daemon zu
# brauchen.
# ------------------------------------------------------------
sub run_recorder {
    my ($opt) = @_;

    my $host = $opt->{host} || '127.0.0.1';
    fail('loopback', "refusing non-loopback address: $host", 2) unless is_loopback($host);

    my $sock = $opt->{sock};
    my $port = $opt->{port};

    unless (defined $sock) {
        my $reason;
        ($port, $reason) = resolve_port($opt);
        fail('port', $reason, 2) unless defined $port;

        $sock = IO::Socket::INET->new(
            PeerAddr => $host, PeerPort => $port, Proto => 'tcp', Timeout => 2,
        );
        fail('connect', "connect failed to $host:$port: $!", 2) unless $sock;
        $sock->blocking(0);
    }

    my $out_fh;
    if (defined $opt->{out}) {
        open($out_fh, '>', $opt->{out}) or fail('out', "cannot open $opt->{out}: $!", 1);
    } else {
        $out_fh = \*STDOUT;
    }
    binmode($out_fh);
    # PLAN-CHECK-KORREKTUR Runde 2 (82-32, BLOCKER 2ii): ohne Autoflush
    # puffert Perl blockweise -- ein live pollender Leser (tail -F, oder
    # ein --check-trigger-Aufruf waehrend der Recorder noch laeuft) sieht
    # bis zum Prozessende nichts. Gilt fuer BEIDE Zweige oben (--out-Datei
    # UND \*STDOUT), da $out_fh hier dieselbe lexikalische Variable ist.
    $out_fh->autoflush(1);

    my @send_queue = @{ $opt->{send} || [] };
    my @built_commands;
    for my $spec (@send_queue) {
        my $cmd = build_command($spec);
        fail('send', "unknown/invalid --send spec: $spec", 1) unless defined $cmd;
        push @built_commands, $cmd;
    }

    my $client_factory = $opt->{client_factory} || sub { Protocol::WebSocket::Client->new(@_) };
    my $port_display = defined $port ? $port : 0;
    my $client = $client_factory->(url => "ws://$host:$port_display");

    my $first_auth_state_checked = 0;
    my $mismatch = 0;
    my $eof = 0;
    my $handshake_done = 0;

    # ------------------------------------------------------------
    # Opt-in LMS-Reanforderung (82-38, T-3 Option a): strikt Opt-in ueber
    # --reannounce-lms -- ohne diese Flagge bleibt run_recorder byte-
    # identisch zum Zustand vor diesem Plan (D-15/T-81-03). Der zweite
    # Socket wird JETZT, vor $client->connect, geoeffnet und die Bytes
    # werden JETZT vorgebaut, damit der HANDSHAKE-OK-Callback unten nur
    # noch syswrite() aufrufen muss -- keine Socket-Aufbauzeit in der
    # gemessenen Latenz.
    # ------------------------------------------------------------
    my ($lms_sock, $lms_request_bytes);
    if ($opt->{reannounce_lms}) {
        my $arr = eval { decode_json($opt->{reannounce_lms}) };
        fail('reannounce', "invalid --reannounce-lms JSON: $@", 1)
            if $@ || ref($arr) ne 'ARRAY' || !@$arr;

        my $reannounce_playerid = $arr->[0];
        my @reannounce_cmd = @{$arr}[1 .. $#$arr];
        my $lms_url = $opt->{lms_url} || 'http://127.0.0.1:9000/jsonrpc.js';

        $lms_request_bytes = build_lms_request($lms_url, $reannounce_playerid, \@reannounce_cmd);

        if (defined $opt->{lms_sock}) {
            $lms_sock = $opt->{lms_sock};
        } else {
            my ($lms_host, $lms_port) = $lms_url =~ m{\A https?://([^:/]+)(?::(\d+))?}x;
            $lms_port = defined($lms_port) ? $lms_port : 80;
            $lms_sock = IO::Socket::INET->new(
                PeerAddr => $lms_host, PeerPort => $lms_port, Proto => 'tcp', Timeout => 2,
            );
            unless ($lms_sock) {
                print {$out_fh} jsonl_line('meta', "REANFORDERUNG UNGUELTIG: LMS-Socket nicht verbindbar: $!");
                close($out_fh) if defined $opt->{out};
                fail('connect', "LMS pre-connect failed: $!", 2);
            }
        }
    }

    $client->on(
        write   => sub { syswrite($sock, $_[1]) },
        read    => sub {
            my $text = $_[1];
            print {$out_fh} jsonl_line('rx', $text);

            unless ($first_auth_state_checked) {
                my $copy = $text;
                utf8::encode($copy) if utf8::is_utf8($copy);
                my $msg = eval { decode_json($copy) };
                if (!$@ && ref($msg) eq 'HASH' && ($msg->{type} || '') eq 'auth_state') {
                    $first_auth_state_checked = 1;
                    if (defined $opt->{expect_device} && !check_device($msg, $opt->{expect_device})) {
                        print {$out_fh} jsonl_line('meta', "device mismatch: got " . ($msg->{device_name} // '?') . " expected $opt->{expect_device}");
                        $mismatch = 1;
                    }
                }
            }
        },
        error   => sub {
            print {$out_fh} jsonl_line('meta', "ERROR: $_[1]");
        },
        eof     => sub {
            print {$out_fh} jsonl_line('meta', 'EOF');
            $eof = 1;
        },
        connect => sub {
            $handshake_done = 1;
            print {$out_fh} jsonl_line('meta', 'HANDSHAKE-OK');

            if (defined $lms_sock) {
                my $t0 = Time::HiRes::time();

                my $to_write = $lms_request_bytes;
                my $written = 0;
                while ($written < length($to_write)) {
                    my $n = syswrite($lms_sock, $to_write, length($to_write) - $written, $written);
                    last unless defined $n && $n > 0;
                    $written += $n;
                }
                my $t_dispatch = Time::HiRes::time();

                # IO::Select statt IO::Socket::INET's Timeout-Option (die nur
                # beim Verbindungsaufbau wirkt, nicht beim Lesen) -- 2s
                # Gesamtbudget fuer die vollstaendige Antwort (T-82-38D).
                #
                # R9-WR-02 (Code-Review Runde 9): diese synchrone Wartezeit verschiebt den rx-Zeitstempel
                # nachfolgender Daemon-Frames -- sie schiebt den Rueckkehrzeitpunkt dieses Callbacks um bis
                # zu 2s nach hinten; jeder Daemon-Frame, der danach eintrifft, traegt in der
                # JSONL-Sekundaerquelle einen entsprechend spaeteren rx-Zeitstempel als ohne diese Wartezeit
                # (dispatch_ms selbst, oben berechnet, ist NICHT betroffen -- es misst nur die
                # syswrite-Dauer VOR dieser Wartezeit). Mechanisch belegt durch den Subtest
                # 'reannounce-lms-active' (Test E, t/43_soloist_ws_record.t, 82-41 Task 2).
                my $resp_bytes = '';
                my $content_length;
                my $sel = IO::Select->new($lms_sock);
                my $read_deadline = Time::HiRes::time() + 2;
                while (Time::HiRes::time() < $read_deadline) {
                    my $remaining = $read_deadline - Time::HiRes::time();
                    $remaining = 0 if $remaining < 0;
                    last unless $sel->can_read($remaining);
                    my $n = sysread($lms_sock, my $buf, 65536);
                    last if !defined $n || $n == 0;
                    $resp_bytes .= $buf;
                    if (!defined $content_length && $resp_bytes =~ /\r\n\r\n/) {
                        $content_length = ($resp_bytes =~ /Content-Length:\s*(\d+)/i) ? $1 : 0;
                    }
                    if (defined $content_length) {
                        my ($hdr, $body) = split(/\r\n\r\n/, $resp_bytes, 2);
                        last if defined $body && length($body) >= $content_length;
                    }
                }
                my $t_roundtrip = Time::HiRes::time();
                close($lms_sock) unless defined $opt->{lms_sock};

                my $parsed = parse_lms_response($resp_bytes);
                if ($parsed->{ok}) {
                    my $dispatch_ms  = ($t_dispatch  - $t0) * 1000;
                    my $roundtrip_ms = ($t_roundtrip - $t0) * 1000;
                    print {$out_fh} jsonl_line('meta', sprintf(
                        'REANFORDERUNG OK dispatch_ms=%.3f roundtrip_ms=%.3f',
                        $dispatch_ms, $roundtrip_ms));
                } else {
                    print {$out_fh} jsonl_line('meta', "REANFORDERUNG UNGUELTIG: $parsed->{reason}");
                }
            }

            if (@built_commands) {
                for my $cmd (@built_commands) {
                    print {$out_fh} jsonl_line('tx', $cmd);
                    $client->write($cmd);
                }
            }
        },
    );

    # Handshake budget (81-REVIEW.md WR-03): mirrors preflight()'s
    # `my $end = time() + 5; while (time() < $end && !%result) {...}` --
    # enforced below in the select loop, not just computed, so a daemon
    # that never completes the WS handshake cannot hang run_recorder()
    # forever when --seconds is not given. handshake_timeout_s is an
    # additive test hook (81-02-style client_factory/sock convention) --
    # no CLI flag, defaults to the same 5s preflight() uses.
    my $handshake_budget_s = $opt->{handshake_timeout_s} // 5;
    my $handshake_deadline = time() + $handshake_budget_s;
    $client->connect;

    my $run_until = defined $opt->{seconds} ? (time() + $opt->{seconds}) : undef;
    my $sigint = 0;
    local $SIG{INT} = sub { $sigint = 1 };

    my $handshake_timeout = 0;
    while (1) {
        last if $eof;
        last if $mismatch;
        last if defined $run_until && time() >= $run_until;
        last if $sigint;
        if (!$handshake_done && time() >= $handshake_deadline) {
            $handshake_timeout = 1;
            last;
        }

        my $rin = '';
        vec($rin, fileno($sock), 1) = 1;
        if (select(my $r = $rin, undef, undef, 0.2)) {
            my $n = sysread($sock, my $buf, 65536);
            if (!defined $n || $n == 0) {
                print {$out_fh} jsonl_line('meta', 'EOF');
                last;
            }
            $client->read($buf);
        }
    }

    # Exit through the same flush-on-close path as SIGINT (81-REVIEW.md
    # CR-02/WR-03: an enforced timeout must not reintroduce the buffered-
    # JSONL-loss bug by short-circuiting past close($out_fh)).
    print {$out_fh} jsonl_line('meta', 'HANDSHAKE-TIMEOUT') if $handshake_timeout;

    close($sock);
    close($out_fh) if defined $opt->{out};

    return 2 if $handshake_timeout;
    return $mismatch ? 3 : 0;
}

# ------------------------------------------------------------
# main(@argv)
# ------------------------------------------------------------
sub main {
    my (@argv) = @_;

    my %opt = (
        host => '127.0.0.1',
        cache_dir => '/var/lib/squeezeboxserver/cache',
        send => [],
    );
    my $help = 0;
    my $preflight_mode = 0;

    GetOptionsFromArray(
        \@argv,
        'mac=s'            => \$opt{mac},
        'port=i'           => \$opt{port},
        'host=s'           => \$opt{host},
        'cache-dir=s'      => \$opt{cache_dir},
        'min-mtime=i'      => \$opt{min_mtime},
        'seconds=i'        => \$opt{seconds},
        'out=s'            => \$opt{out},
        'send=s'           => $opt{send},
        'expect-device=s'  => \$opt{expect_device},
        'preflight'        => \$preflight_mode,
        'lms-url=s'        => \$opt{lms_url},
        'reannounce-lms=s' => \$opt{reannounce_lms},
        'help'             => \$help,
    ) or fail('args', 'invalid arguments, see --help', 1);

    if ($help) {
        print usage();
        exit 0;
    }

    if ($preflight_mode) {
        preflight(\%opt);
        return;
    }

    exit(run_recorder(\%opt));
}

main(@ARGV) unless caller;

1;

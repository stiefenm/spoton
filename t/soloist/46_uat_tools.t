#!/usr/bin/perl

# t/46_uat_tools.t
#
# Quick 260910-w9q -- adopts three session-scratchpad measurement-rig tools
# into tools/uat/ as permanent, tested project tools (see
# .planning/quick/260910-w9q-mess-werkzeuge-aus-dem-scratchpad-nach-t/260910-w9q-PLAN.md).
# Each script closes exactly one real measurement-run failure from
# 2026-09-10, and each guard is proven here in both directions (must-fail
# AND must-pass), not just the happy path:
#
#   - tools/uat/lms-cmd.sh: a curl 200 does not prove LMS executed a
#     command -- LMS silently drops an unknown command with a closed
#     connection and no response. Tonight, ["playlist","stop"] does not
#     exist (the real command is ["stop"]), and the resulting silent
#     no-op looked like a product defect ("Stop greift nicht durch"),
#     burning two measurement runs.
#   - tools/uat/pre-scenario-gate.sh: the rig looked fine but wasn't --
#     three independent gates each catch one setup mistake: a frozen
#     serverAddr() left pointing at a dead IP after a network change; a
#     spclient reachability check; and SpClient connect-timeouts counted
#     by DISTINCT target, because more than one target means the network
#     is down while exactly one target means a single stuck track that
#     must simply be avoided, not a reason to block all measurement.
#   - tools/uat/checkpoint-beep.sh: the acoustic checkpoint signal must
#     never contaminate a listening scenario -- it must stay silent
#     whenever lavender-pa reports mode=play, and it must NOT default to
#     silence just because LMS could not be reached (fail-open, not
#     fail-silent).
#
# Blackbox-only for all three tools (plain .sh files -- no modulino
# `require` is possible or attempted), same convention as
# t/43_soloist_ws_record.t's CLI-contract note: every assertion runs the
# real executable via system()/exec() in LIST form and inspects exit code
# plus stdout/stderr.
#
# Entirely offline: no live LMS, no soloist daemon, no real audio output,
# no internet reachability requirement. LMS is stood in for by a small
# forked fake HTTP server bound to 127.0.0.1 (start_fake_http); real audio
# output is stood in for by a PATH-prepended stub `play` binary
# (make_stub_bindir) that only ever appends its own arguments to a file.

use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname basename);
use File::Temp qw(tempdir tempfile);
use Cwd qw(abs_path);
use IO::Socket::INET;
use POSIX ':sys_wait_h';
use Time::HiRes qw(time);
# Quick 260915-bpd: JSON::PP deodiert JSON-RPC-Request-Body fuer
# make_routing_responder() (arm-after-restart / signatur-c-probe Subtests).
use JSON::PP;

# Resolve project root (t/<group>/x.t sits two levels below it)
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

my $lms_cmd_script    = "$project_dir/tools/uat/lms-cmd.sh";
my $beep_script       = "$project_dir/tools/uat/checkpoint-beep.sh";
my $gate_script       = "$project_dir/tools/uat/pre-scenario-gate.sh";
my $window_gate_script = "$project_dir/tools/uat/soloist-window-gate.sh";
my $extract_run_script = "$project_dir/tools/uat/extract-run.pl";
my $measure_reannounce_script = "$project_dir/tools/uat/measure-reannounce-latency.pl";
my $arm_after_restart_script  = "$project_dir/tools/uat/arm-after-restart.sh";
my $signatur_c_probe_script   = "$project_dir/tools/uat/signatur-c-probe.py";
my $repeat_probe_script       = "$project_dir/tools/uat/repeat-probe.sh";
my $rig_prefs_check_script    = "$project_dir/tools/uat/rig-prefs-check.sh";
my $player_settings_post_script = "$project_dir/tools/uat/player-settings-post.sh";
my $cluster2_series_script = "$project_dir/.planning/phases/84.1-soloist-reparaturen-vor-der-abnahme/runners/cluster2-series.sh";

# Quick 260915-bpd: gemeinsame Test-MAC fuer alle drei neuen Subtests --
# jeder players_loop-Fixture-Eintrag UND jeder run_*_tool-Aufruf, der eine MAC
# braucht, verwendet DIESEN Wert, damit kein Fall versehentlich ueber den
# Playerid-Mismatch-Pfad statt des beabsichtigten connected==1-Pfads laeuft.
my $probe_mac = '02:00:00:5a:11:03';
# 79-04 (D-10): a developer's real PA_MAC must never leak into a child tool; every tool call below
# also passes PA_MAC explicitly.
$ENV{PA_MAC} = $probe_mac;

unless (-f $lms_cmd_script) {
    die "tools/uat/lms-cmd.sh not yet present in this checkout -- wrong project root or broken checkout (84-09: die, never skip)\n";
}

# ============================================================
# Shared helper 1/3: start_fake_http(\@responders) -- forks a one-shot fake
# LMS HTTP server bound to 127.0.0.1:0 (OS-assigned free port). One
# responder coderef per expected request, called in order as
# $responder->($body, $header_text); the second arg is the raw request header
# block, whose first line is `METHOD TARGET HTTP/1.x`. A responder returning ($status_line, $resp_body)
# gets a full HTTP response written back; a responder returning an empty
# list makes the server close the connection without writing any bytes --
# this reproduces curl exit 52 (verified empirically during planning),
# exactly LMS's real behavior for an unknown command. Returns ($pid,
# $port); the caller is responsible for waitpid($pid, 0) once done.
# ============================================================
sub start_fake_http {
    my ($responders) = @_;
    my $listener = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => 5,
        ReuseAddr => 1,
    ) or die "start_fake_http: cannot bind listener: $!";
    my $port = $listener->sockport;
    my $pid = fork();
    die "start_fake_http: fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        for my $responder (@$responders) {
            my $conn = $listener->accept or next;
            my $header_text = '';
            my $line;
            while (defined($line = <$conn>)) {
                $header_text .= $line;
                last if $line eq "\r\n" || $line eq "\n";
            }
            my $body = '';
            if ($header_text =~ /Content-Length:\s*(\d+)/i) {
                my $len = $1;
                if ($len > 0) {
                    read($conn, $body, $len);
                }
            }
            my @result = $responder->($body, $header_text);
            if (@result) {
                my ($status_line, $resp_body) = @result;
                $resp_body = '' unless defined $resp_body;
                my $len = length($resp_body);
                print $conn "$status_line\r\n";
                print $conn "Content-Type: application/json\r\n";
                print $conn "Content-Length: $len\r\n";
                print $conn "Connection: close\r\n";
                print $conn "\r\n";
                print $conn $resp_body;
            }
            close($conn);
        }
        close($listener);
        exit(0);
    }
    close($listener);
    return ($pid, $port);
}

# ============================================================
# Shared helper 2/3: run_tool($script_path, \@args, %env_overrides) --
# forks, in the child overlays %ENV with %env_overrides (this is also how
# PATH gets overridden for the checkpoint-beep.sh audio stub), redirects
# STDOUT/STDERR to their own File::Temp files, then exec('bash',
# $script_path, @args). In the parent, waitpid and return ($exit_code,
# $stdout_text, $stderr_text).
# ============================================================
sub _slurp {
    my ($file) = @_;
    open(my $fh, '<', $file) or return '';
    local $/;
    my $content = <$fh>;
    close($fh);
    return defined($content) ? $content : '';
}

sub run_tool {
    my ($script_path, $args, %env_overrides) = @_;
    my ($out_fh, $out_file) = tempfile();
    my ($err_fh, $err_file) = tempfile();
    my $pid = fork();
    die "run_tool: fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        local %ENV = (%ENV, %env_overrides);
        open(STDOUT, '>&', $out_fh) or exit(126);
        open(STDERR, '>&', $err_fh) or exit(126);
        exec('bash', $script_path, @$args) or exit(127);
    }
    waitpid($pid, 0);
    my $exit_code = $? >> 8;
    close($out_fh);
    close($err_fh);
    my $stdout_text = _slurp($out_file);
    my $stderr_text = _slurp($err_file);
    unlink($out_file, $err_file);
    return ($exit_code, $stdout_text, $stderr_text);
}

# ============================================================
# Shared helper (Perl variant of run_tool, added 82-41 Task 1): run_perl_tool
# ($script_path, \@args, %env_overrides) -- identical to run_tool() above,
# except the child execs `perl $script_path @args` instead of
# `bash $script_path @args`. Needed for tools/uat/extract-run.pl, which is a
# Perl script, not a shell script (run_tool()'s hardcoded `exec('bash', ...)`
# would fail with a Perl syntax error read as a shell script).
# ============================================================
sub run_perl_tool {
    my ($script_path, $args, %env_overrides) = @_;
    my ($out_fh, $out_file) = tempfile();
    my ($err_fh, $err_file) = tempfile();
    my $pid = fork();
    die "run_perl_tool: fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        local %ENV = (%ENV, %env_overrides);
        open(STDOUT, '>&', $out_fh) or exit(126);
        open(STDERR, '>&', $err_fh) or exit(126);
        exec($^X, $script_path, @$args) or exit(127);
    }
    waitpid($pid, 0);
    my $exit_code = $? >> 8;
    close($out_fh);
    close($err_fh);
    my $stdout_text = _slurp($out_file);
    my $stderr_text = _slurp($err_file);
    unlink($out_file, $err_file);
    return ($exit_code, $stdout_text, $stderr_text);
}

# ============================================================
# Shared helper (stdin variant of run_tool, added 82-35): run_tool_stdin
# ($script_path, \@args, $stdin_text, %env_overrides) -- identical to
# run_tool() above, except the child's STDIN is reopened from a temp file
# holding $stdin_text before exec. Needed for --check-trigger, which reads
# exactly one JSONL line from stdin (soloist-window-gate.sh Kopfkommentar
# Abschnitt B) -- run_tool() alone inherits the test process's own STDIN,
# which is wrong here (prove's own stdin, not a JSONL line).
# ============================================================
sub run_tool_stdin {
    my ($script_path, $args, $stdin_text, %env_overrides) = @_;
    my ($in_fh, $in_file) = tempfile();
    print {$in_fh} $stdin_text;
    close($in_fh);
    my ($out_fh, $out_file) = tempfile();
    my ($err_fh, $err_file) = tempfile();
    my $pid = fork();
    die "run_tool_stdin: fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        local %ENV = (%ENV, %env_overrides);
        open(STDIN, '<', $in_file) or exit(126);
        open(STDOUT, '>&', $out_fh) or exit(126);
        open(STDERR, '>&', $err_fh) or exit(126);
        exec('bash', $script_path, @$args) or exit(127);
    }
    waitpid($pid, 0);
    my $exit_code = $? >> 8;
    close($out_fh);
    close($err_fh);
    my $stdout_text = _slurp($out_file);
    my $stderr_text = _slurp($err_file);
    unlink($in_file, $out_file, $err_file);
    return ($exit_code, $stdout_text, $stderr_text);
}

# ============================================================
# Shared helper (Quick 260915-bpd): run_python_tool($script_path, \@args,
# %env_overrides) -- identical to run_perl_tool() above, except the child
# execs `python3 $script_path @args` instead of `$^X $script_path @args`.
# Needed for tools/uat/signatur-c-probe.py, which is Python, not Perl.
# ============================================================
sub run_python_tool {
    my ($script_path, $args, %env_overrides) = @_;
    my ($out_fh, $out_file) = tempfile();
    my ($err_fh, $err_file) = tempfile();
    my $pid = fork();
    die "run_python_tool: fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        local %ENV = (%ENV, %env_overrides);
        open(STDOUT, '>&', $out_fh) or exit(126);
        open(STDERR, '>&', $err_fh) or exit(126);
        exec('python3', $script_path, @$args) or exit(127);
    }
    waitpid($pid, 0);
    my $exit_code = $? >> 8;
    close($out_fh);
    close($err_fh);
    my $stdout_text = _slurp($out_file);
    my $stderr_text = _slurp($err_file);
    unlink($out_file, $err_file);
    return ($exit_code, $stdout_text, $stderr_text);
}

# ============================================================
# Shared helper 3/3: free_closed_port() -- binds a throwaway listener on
# 127.0.0.1:0 to obtain a guaranteed-free ephemeral port, then immediately
# closes it so nothing listens there afterward (reproduces "LMS process
# not running" without racing a real port number).
# ============================================================
sub free_closed_port {
    my $l = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => 5,
        ReuseAddr => 1,
    ) or die "free_closed_port: cannot bind: $!";
    my $port = $l->sockport;
    close($l);
    return $port;
}

# ============================================================
# subtest 'lms-cmd' -- Task 1. All 9 cases from the plan, including both
# must-fail and must-pass paths and the ACHTUNG/no-ACHTUNG control pair.
# ============================================================
subtest 'lms-cmd' => sub {
    # Case 1 (frozen probe: `stop` -> 0)
    {
        my ($pid, $port) = start_fake_http([ sub { return ('HTTP/1.1 200 OK', '{"result":{}}'); } ]);
        my ($exit, $stdout, $stderr) = run_tool($lms_cmd_script, [ '-', 'stop' ],
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js");
        waitpid($pid, 0);
        is($exit, 0, 'lms-cmd: stop -> exit 0 (frozen probe)');
        like($stdout, qr/quittiert: \[stop\]/, 'lms-cmd: stop -> quittiert');
    }

    # Case 2 (frozen probe: `playlist stop` -> 1, connection closed w/o response)
    {
        my ($pid, $port) = start_fake_http([ sub { return (); } ]);
        my ($exit, $stdout, $stderr) = run_tool($lms_cmd_script, [ '-', 'playlist', 'stop' ],
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js");
        waitpid($pid, 0);
        is($exit, 1, 'lms-cmd: playlist stop -> exit 1 (frozen probe)');
        like($stderr, qr/Verbindung ohne Antwort geschlossen/,
            'lms-cmd: playlist stop -> connection-closed message');
    }

    # Case 3 (frozen probe: `voellig quatsch hier` -> 1)
    {
        my ($pid, $port) = start_fake_http([ sub { return (); } ]);
        my ($exit, $stdout, $stderr) = run_tool($lms_cmd_script, [ '-', 'voellig', 'quatsch', 'hier' ],
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js");
        waitpid($pid, 0);
        is($exit, 1, 'lms-cmd: voellig quatsch hier -> exit 1 (frozen probe)');
        like($stderr, qr/NICHT QUITTIERT/, 'lms-cmd: voellig quatsch hier -> NICHT QUITTIERT');
    }

    # Case 4 (frozen probe: `playlist clear` -> 0). Note: "playlist" contains
    # the substring "play", so the original script's own case-pattern match
    # fires the side-effect status re-check here even though the command's
    # actual intent is unrelated to playback -- a pre-existing quirk in the
    # adopted script, not something this plan changes.
    {
        my ($pid, $port) = start_fake_http([
            sub { return ('HTTP/1.1 200 OK', '{"result":{}}'); },
            sub { return ('HTTP/1.1 200 OK', '{"result":{"mode":"stop"}}'); },
        ]);
        my ($exit, $stdout, $stderr) = run_tool($lms_cmd_script, [ '-', 'playlist', 'clear' ],
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js");
        waitpid($pid, 0);
        is($exit, 0, 'lms-cmd: playlist clear -> exit 0 (frozen probe)');
        like($stdout, qr/quittiert: \[playlist clear\]/, 'lms-cmd: playlist clear -> quittiert');
        unlike($stderr, qr/ACHTUNG/, 'lms-cmd: playlist clear -> no ACHTUNG (mode=stop)');
    }

    # Case 5 (frozen probe: closed port -> 2)
    {
        my $port = free_closed_port();
        my ($exit, $stdout, $stderr) = run_tool($lms_cmd_script, [ '-', 'stop' ],
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js");
        is($exit, 2, 'lms-cmd: closed port -> exit 2 (frozen probe)');
        like($stderr, qr/LMS UNERREICHBAR/, 'lms-cmd: closed port -> LMS UNERREICHBAR');
    }

    # Case 6: empty body. Real LMS is documented to always close via the
    # curl-52 path instead (case 2/3 above); this exercises a branch the
    # script defends defensively even though it is not the observed real
    # behavior.
    {
        my ($pid, $port) = start_fake_http([ sub { return ('HTTP/1.1 200 OK', ''); } ]);
        my ($exit, $stdout, $stderr) = run_tool($lms_cmd_script, [ '-', 'xyzzy-empty-body-check' ],
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js");
        waitpid($pid, 0);
        is($exit, 1, 'lms-cmd: empty body -> exit 1 (defensive branch)');
        like($stderr, qr/LEEREN Rumpf/, 'lms-cmd: empty body -> LEEREN Rumpf');
    }

    # Case 7: valid JSON but no result field
    {
        my ($pid, $port) = start_fake_http([ sub { return ('HTTP/1.1 200 OK', '{"error":"nope"}'); } ]);
        my ($exit, $stdout, $stderr) = run_tool($lms_cmd_script, [ '-', 'xyzzy-no-result-field' ],
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js");
        waitpid($pid, 0);
        is($exit, 1, 'lms-cmd: no result field -> exit 1');
        like($stderr, qr/ohne result-Feld/, 'lms-cmd: no result field -> ohne result-Feld');
    }

    # Case 8: `play` with a genuine mode=play follow-up -- side-effect
    # warning fires.
    {
        my ($pid, $port) = start_fake_http([
            sub { return ('HTTP/1.1 200 OK', '{"result":{}}'); },
            sub { return ('HTTP/1.1 200 OK', '{"result":{"mode":"play"}}'); },
        ]);
        my ($exit, $stdout, $stderr) = run_tool($lms_cmd_script, [ '-', 'play' ],
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js");
        waitpid($pid, 0);
        is($exit, 0, 'lms-cmd: play (mode=play follow-up) -> exit 0');
        like($stderr, qr/ACHTUNG/, 'lms-cmd: play (mode=play follow-up) -> ACHTUNG present');
        like($stderr, qr/GESTARTET/, 'lms-cmd: play (mode=play follow-up) -> GESTARTET present');
    }

    # Case 9: control case pairing with case 8 -- same command, but the
    # follow-up status re-check reports mode=stop -- proves the warning is
    # conditional, not unconditional noise.
    {
        my ($pid, $port) = start_fake_http([
            sub { return ('HTTP/1.1 200 OK', '{"result":{}}'); },
            sub { return ('HTTP/1.1 200 OK', '{"result":{"mode":"stop"}}'); },
        ]);
        my ($exit, $stdout, $stderr) = run_tool($lms_cmd_script, [ '-', 'play' ],
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js");
        waitpid($pid, 0);
        is($exit, 0, 'lms-cmd: play (mode=stop follow-up) -> exit 0');
        unlike($stderr, qr/ACHTUNG/, 'lms-cmd: play (mode=stop follow-up) -> no ACHTUNG (control case)');
    }
};

# ============================================================
# Shared helper 4/4: make_stub_bindir(@names) -- creates a tempdir, and for
# each name writes an executable shell script whose entire body appends
# one line (its own "$*") to a fixed recorder file at $dir/CALLS and exits
# 0 -- no real audio, no real subprocess side effect of any kind. Callers
# pass PATH => "$dir:$ENV{PATH}" as part of run_tool's %env_overrides
# (keeping the real curl/python3/id on PATH) and read back $dir/CALLS
# afterward (a missing file means zero recorded calls).
# ============================================================
sub make_stub_bindir {
    my (@names) = @_;
    my $dir = tempdir(CLEANUP => 1);
    for my $name (@names) {
        my $path = "$dir/$name";
        open(my $fh, '>', $path) or die "make_stub_bindir: cannot write $path: $!";
        print $fh "#!/bin/bash\necho \"\$*\" >> \"$dir/CALLS\"\nexit 0\n";
        close($fh);
        chmod 0755, $path;
    }
    return $dir;
}

sub _read_calls {
    my ($dir) = @_;
    my $file = "$dir/CALLS";
    return () unless -f $file;
    open(my $fh, '<', $file) or return ();
    my @lines = <$fh>;
    close($fh);
    chomp @lines;
    return @lines;
}

# ============================================================
# Helper 5/5: write_custom_stub($dir, $name, $body) -- like make_stub_bindir,
# but writes the CALLER-SUPPLIED script body verbatim instead of the fixed
# "exit 0" template (WR-04, 82-33: Test 4/4b need a `sudo` stub that exits 1
# WITH or WITHOUT stderr output -- two distinct, individually controlled
# behaviors the fixed template cannot express).
# ============================================================
sub write_custom_stub {
    my ($dir, $name, $body) = @_;
    my $path = "$dir/$name";
    open(my $fh, '>', $path) or die "write_custom_stub: cannot write $path: $!";
    print $fh $body;
    close($fh);
    chmod 0755, $path;
    return $path;
}

# ============================================================
# Three stub-generator helpers (Quick 260915-bpd), shared by the
# 'arm-after-restart'/'signatur-c-probe'/'repeat-probe' subtests below --
# same tempdir(CLEANUP => 1)/write_custom_stub convention as above.
#
# 1. SUDO_BIN passthrough stub: drops a leading -n, no-ops any `systemctl`
#    invocation (never a real restart), execs everything else for real
#    (stat/wc/tail/cat against a test's own tempfiles). Reused by ALL THREE
#    subtests -- harmless for repeat-probe, which never calls systemctl.
# 2. PGREP_BIN counter stub: a colocated counter file increments on every
#    call, echoing an always-DIFFERENT fake PID (10000+N). Used only where
#    Tor A must pass on its very first check (signatur-c-probe Tor-C-red).
# 3. PGREP_BIN constant stub: always echoes the SAME fake PID (88888).
#    Used only where BEFORE_PID and every later poll must be provably,
#    deterministically equal (signatur-c-probe Tor-A-rot).
# ============================================================
sub write_sudo_passthrough_stub {
    my ($dir) = @_;
    return write_custom_stub($dir, 'sudo', "#!/bin/bash
if [ \"\$1\" = \"-n\" ]; then shift; fi
if [ \"\$1\" = \"systemctl\" ]; then exit 0; fi
exec \"\$\@\"
");
}

sub write_pgrep_counter_stub {
    my ($dir) = @_;
    return write_custom_stub($dir, 'pgrep', "#!/bin/bash
DIR=\$(dirname \"\$0\")
CTR=\"\$DIR/PGREP_COUNTER\"
N=0
[ -f \"\$CTR\" ] && N=\$(cat \"\$CTR\")
N=\$((N+1))
echo \"\$N\" > \"\$CTR\"
echo \$((10000 + N))
exit 0
");
}

sub write_pgrep_constant_stub {
    my ($dir) = @_;
    return write_custom_stub($dir, 'pgrep', "#!/bin/bash
echo 88888
exit 0
");
}

# ============================================================
# Helper (Quick 260915-bpd): make_routing_responder(%opts) -- returns ONE
# coderef for start_fake_http() that decodes each JSON-RPC request body via
# JSON::PP and routes a canned reply based on the decoded command, so the
# SAME fake-LMS logic serves both arm-after-restart's
# category-scharfstellen sequence AND signatur-c-probe's players/Tor-C
# sequence without baking in a fixed failure. %opts:
#   bad_category => undef (default: every category confirms DEBUG) or a
#                   category name (that ONE gets _value=>"OFF" instead).
#   players_ok   => 1 (default: players_loop entry for $probe_mac,
#                   connected=>1) or 0 (SAME $probe_mac, connected=>0 --
#                   deliberately the same MAC, so the fixture exercises the
#                   connected==1 half of Tor C's check, never a separate
#                   playerid-mismatch path).
#   ack_playlist_play => 1 (default: "playlist play" falls into the
#                   generic catch-all, which returns a "result" key, so
#                   signatur-c-probe.py's `quittiert` check sees True) or 0
#                   (WR-07: reply to "playlist" with a bare '{}', no
#                   "result" key at all, so `quittiert` becomes False --
#                   reproduces an un-acknowledged reannouncement).
# ============================================================
sub make_routing_responder {
    my (%opts) = @_;
    my $bad_category = $opts{bad_category};
    my $players_ok    = exists $opts{players_ok} ? $opts{players_ok} : 1;
    my $ack_playlist_play = exists $opts{ack_playlist_play} ? $opts{ack_playlist_play} : 1;
    return sub {
        my ($body) = @_;
        my $req = eval { JSON::PP::decode_json($body) };
        return ('HTTP/1.1 200 OK', '{"result":{}}') unless $req && ref($req->{params}) eq 'ARRAY';
        my ($player, $cmd) = @{ $req->{params} };
        $cmd = [] unless ref($cmd) eq 'ARRAY';
        my $verb = defined($cmd->[0]) ? $cmd->[0] : '';
        if ($verb eq 'debug') {
            my $cat   = $cmd->[1];
            my $third = $cmd->[2];
            if (defined($third) && $third eq '?') {
                my $value = (defined($bad_category) && defined($cat) && $cat eq $bad_category) ? 'OFF' : 'DEBUG';
                return ('HTTP/1.1 200 OK', qq({"result":{"_value":"$value"}}));
            }
            return ('HTTP/1.1 200 OK', '{"result":{}}');
        }
        if ($verb eq 'pref') {
            return ('HTTP/1.1 200 OK', '{"result":{"_p2":"1"}}');
        }
        if ($verb eq 'players') {
            my $connected = $players_ok ? 1 : 0;
            return ('HTTP/1.1 200 OK',
                qq({"result":{"players_loop":[{"playerid":"$probe_mac","connected":$connected}]}}));
        }
        if ($verb eq 'playlist' && !$ack_playlist_play) {
            return ('HTTP/1.1 200 OK', '{}');
        }
        # serverstatus, playlist play, and anything else -> generic result
        # (Tor B / the "quittiert" check only look for the "result" key).
        return ('HTTP/1.1 200 OK', '{"result":{}}');
    };
}

# ============================================================
# Helper (Quick 260928-fv0): make_prefs_responder(\%before, %opts) -- shared
# fake-LMS responder for rig-prefs-check.sh (Task 1) and player-settings-post.sh
# (Task 2). Decodes each request body; a NON-JSON body is a settings-page
# form POST (Task 2), everything else is JSON-RPC playerpref traffic.
#   before        => hashref key => value (Perl undef -> JSON null, i.e.
#                    "_p2":null)
#   close_on      => arrayref of keys whose query gets an empty reply
#                    (reproduces curl exit 52, the start_fake_http
#                    empty-list contract).
#   bad_reply     => hashref key => 'notjson' | 'no_p2' -- GAP-260928-07: a
#                    malformed (non-JSON) or valid-but-fieldless JSON-RPC
#                    reply for that key's query.
#   capture_file  => path to a plain file. start_fake_http forks, so a
#                    plain arrayref pushed to inside the closure would
#                    mutate only the CHILD's copy and never become visible
#                    to the parent test process; every capture line is
#                    therefore appended to this file instead ("Q <key>" per
#                    query, "SET <key> <value>" per playerpref set, "FORM
#                    <body>" per form POST). Read it back with
#                    read_capture_file() AFTER waitpid.
#   after         => hashref, replaces %before for all queries AFTER the
#                    first form POST (Task 2's before/after snapshot
#                    compare).
# Quick 261019-m6b options (all off by default; every existing caller keeps
# its behavior except one extra capture line, "TARGET <request-target>", per
# form POST):
#   default_mac   => <mac>. Switches on form-field storage that emulates LMS
#                    routing. Target player = force_target if given, else the
#                    body's `playerid` (HTTP.pm:1164-1166), else default_mac
#                    (HTTP.pm:562 never parses the URL query on a POST and
#                    HTTP.pm:901 falls back to the first client). Every
#                    pref_<name> body pair except the three checkbox fields is
#                    stored per target ("STORE <target> <name> <value>") and
#                    answered by later playerpref `?` queries for that target.
#   force_target  => <mac>. Misroute emulation, overrides the target.
#   stored_as     => hashref name => value. Emulates the handler's sanitizer
#                    (Player.pm:111): store this value instead of the posted one.
#   skip_store    => arrayref of names. Emulates the echo-skip (Player.pm:71):
#                    store nothing for these names.
#   server_prefs  => hashref name => value. Answers a JSON-RPC `pref` `?`
#                    query for plugin.spoton:<name> ("QS <name>" capture line).
# ============================================================
sub make_prefs_responder {
    my ($before, %opts) = @_;
    my $capture_file = $opts{capture_file};
    my $close_on      = $opts{close_on}  || [];
    my $bad_reply     = $opts{bad_reply} || {};
    my $current       = $before;
    my $default_mac   = $opts{default_mac};
    my $force_target  = $opts{force_target};
    my $stored_as     = $opts{stored_as}    || {};
    my $skip_store    = $opts{skip_store}   || [];
    my $server_prefs  = $opts{server_prefs};
    my %store;    # target mac => { name => stored value }
    my $append = sub {
        return unless $capture_file;
        open(my $fh, '>>', $capture_file) or return;
        print $fh "$_[0]\n";
        close($fh);
    };
    return sub {
        my ($body, $header_text) = @_;
        my $req = eval { JSON::PP::decode_json($body) };
        if (!$req) {
            # Non-JSON body: a settings-page form POST (Task 2).
            $append->("FORM $body");
            my ($request_target) = (defined($header_text) ? $header_text : '') =~ /^\S+\s+(\S+)/;
            $append->('TARGET ' . (defined($request_target) ? $request_target : ''));
            if (defined $default_mac) {
                my $unesc = sub {
                    my ($x) = @_;
                    $x =~ tr/+/ /;
                    $x =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
                    return $x;
                };
                my (%fields, @pairs);
                for my $pair (split /&/, $body) {
                    my ($n, $v) = split /=/, $pair, 2;
                    next unless defined $n && length $n;
                    $n = $unesc->($n);
                    $v = $unesc->(defined $v ? $v : '');
                    $fields{$n} = $v;
                    push @pairs, [ $n, $v ];
                }
                my $target = defined($force_target) ? $force_target
                           : (defined($fields{playerid}) ? $fields{playerid} : $default_mac);
                for my $p (@pairs) {
                    my ($n, $v) = @$p;
                    next unless $n =~ /^pref_([A-Za-z]+)$/;
                    my $bare = $1;
                    next if $bare =~ /^(?:enableSpotifyConnect|enableDiscovery|enableAutoplay)$/;
                    next if grep { $_ eq $bare } @$skip_store;
                    my $stored = exists $stored_as->{$bare} ? $stored_as->{$bare} : $v;
                    $store{$target}{$bare} = $stored;
                    $append->("STORE $target $bare $stored");
                }
            }
            $current = $opts{after} if $opts{after};
            return ('HTTP/1.1 200 OK', '<html>ok</html>');
        }
        return ('HTTP/1.1 200 OK', '{"result":{}}') unless ref($req->{params}) eq 'ARRAY';
        my ($player, $cmd) = @{ $req->{params} };
        $cmd = [] unless ref($cmd) eq 'ARRAY';
        my $verb = defined($cmd->[0]) ? $cmd->[0] : '';
        if ($verb eq 'playerpref') {
            my $prefkey = defined($cmd->[1]) ? $cmd->[1] : '';
            my ($key) = $prefkey =~ /^plugin\.spoton:(.+)$/;
            $key = $prefkey unless defined $key;
            my $third = $cmd->[2];
            if (defined($third) && $third eq '?') {
                $append->("Q $key");
                return () if grep { $_ eq $key } @$close_on;
                if (my $mode = $bad_reply->{$key}) {
                    return ('HTTP/1.1 200 OK', 'not json at all') if $mode eq 'notjson';
                    return ('HTTP/1.1 200 OK', '{"result":{}}')   if $mode eq 'no_p2';
                }
                my $val = (defined($player) && ref($store{$player}) eq 'HASH' && exists $store{$player}{$key})
                    ? $store{$player}{$key}
                    : $current->{$key};
                my $json_val = defined($val) ? qq("$val") : 'null';
                return ('HTTP/1.1 200 OK', qq({"result":{"_p2":$json_val}}));
            } else {
                my $value = defined($third) ? $third : '';
                $append->("SET $key $value");
                return ('HTTP/1.1 200 OK', '{"result":{}}');
            }
        }
        if ($verb eq 'pref' && $server_prefs) {
            my $prefkey = defined($cmd->[1]) ? $cmd->[1] : '';
            my ($key) = $prefkey =~ /^plugin\.spoton:(.+)$/;
            my $third = $cmd->[2];
            if (defined($key) && defined($third) && $third eq '?') {
                $append->("QS $key");
                my $val = $server_prefs->{$key};
                my $json_val = defined($val) ? qq("$val") : 'null';
                return ('HTTP/1.1 200 OK', qq({"result":{"_p2":$json_val}}));
            }
        }
        return ('HTTP/1.1 200 OK', '{"result":{}}');
    };
}

# read_capture_file($path) -- slurp a capture_file into a list of lines
# (chomped), AFTER waitpid on the fake-HTTP child that wrote it. Missing/
# never-written file (e.g. no request reached the fake) -> empty list.
sub read_capture_file {
    my ($path) = @_;
    return () unless defined($path) && -f $path;
    open(my $fh, '<', $path) or return ();
    my @lines = <$fh>;
    close($fh);
    chomp @lines;
    return @lines;
}

# ============================================================
# subtest 'checkpoint-beep' -- Task 2. The four cases from the plan's
# <behavior> block, proving the STUMM safety gate fires on a confirmed
# mode=play (0 stub invocations), does NOT fire by default when LMS is
# unreachable (4 stub invocations, fail-open -- silence is opt-in on a
# POSITIVELY confirmed mode=play, never the default), and honors
# BEEP_VOL -- all without emitting a single real sound.
# ============================================================
subtest 'checkpoint-beep' => sub {
    # Test 1 (STUMM): fake LMS reports mode=play -> exit 0, STUMM, 0 stub
    # invocations.
    {
        my $bindir = make_stub_bindir('play');
        my ($pid, $port) = start_fake_http([ sub { return ('HTTP/1.1 200 OK', '{"result":{"mode":"play"}}'); } ]);
        my ($exit, $stdout, $stderr) = run_tool($beep_script, [], PA_MAC => $probe_mac,
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js",
            PATH    => "$bindir:$ENV{PATH}");
        waitpid($pid, 0);
        is($exit, 0, 'checkpoint-beep: mode=play -> exit 0');
        like($stdout, qr/STUMM/, 'checkpoint-beep: mode=play -> STUMM printed');
        my @calls = _read_calls($bindir);
        is(scalar(@calls), 0, 'checkpoint-beep: mode=play -> zero stub play invocations');
    }

    # Test 2 (beep): fake LMS reports mode=stop -> exit 0, "Signal
    # ausgegeben", exactly 4 stub invocations, tones alternating 784/1047.
    {
        my $bindir = make_stub_bindir('play');
        my ($pid, $port) = start_fake_http([ sub { return ('HTTP/1.1 200 OK', '{"result":{"mode":"stop"}}'); } ]);
        my ($exit, $stdout, $stderr) = run_tool($beep_script, [], PA_MAC => $probe_mac,
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js",
            PATH    => "$bindir:$ENV{PATH}");
        waitpid($pid, 0);
        is($exit, 0, 'checkpoint-beep: mode=stop -> exit 0');
        like($stdout, qr/Signal ausgegeben/, 'checkpoint-beep: mode=stop -> Signal ausgegeben printed');
        my @calls = _read_calls($bindir);
        is(scalar(@calls), 4, 'checkpoint-beep: mode=stop -> exactly 4 stub play invocations');
        like($calls[0], qr/sine 784/,  'checkpoint-beep: call 1 is sine 784');
        like($calls[1], qr/sine 1047/, 'checkpoint-beep: call 2 is sine 1047');
        like($calls[2], qr/sine 784/,  'checkpoint-beep: call 3 is sine 784');
        like($calls[3], qr/sine 1047/, 'checkpoint-beep: call 4 is sine 1047');
    }

    # Test 3 (fail-open default): no fake LMS reachable (closed port) ->
    # mode resolves to the empty string -> still exits 0, prints "Signal
    # ausgegeben (mode=unbekannt...", still exactly 4 stub invocations --
    # proves silence is opt-in on a POSITIVELY confirmed mode=play, never
    # the default when LMS can't be reached.
    {
        my $bindir = make_stub_bindir('play');
        my $port = free_closed_port();
        my ($exit, $stdout, $stderr) = run_tool($beep_script, [], PA_MAC => $probe_mac,
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js",
            PATH    => "$bindir:$ENV{PATH}");
        is($exit, 0, 'checkpoint-beep: LMS unreachable -> exit 0 (fail-open)');
        like($stdout, qr/Signal ausgegeben \(mode=unbekannt/,
            'checkpoint-beep: LMS unreachable -> mode=unbekannt, still beeps');
        my @calls = _read_calls($bindir);
        is(scalar(@calls), 4, 'checkpoint-beep: LMS unreachable -> exactly 4 stub play invocations');
    }

    # Test 4 (BEEP_VOL regression pin): same as Test 2 but with
    # BEEP_VOL=0.1 -> recorded stub invocations carry "vol 0.1" instead of
    # the default "vol 0.5".
    {
        my $bindir = make_stub_bindir('play');
        my ($pid, $port) = start_fake_http([ sub { return ('HTTP/1.1 200 OK', '{"result":{"mode":"stop"}}'); } ]);
        my ($exit, $stdout, $stderr) = run_tool($beep_script, [], PA_MAC => $probe_mac,
            LMS_URL  => "http://127.0.0.1:$port/jsonrpc.js",
            PATH     => "$bindir:$ENV{PATH}",
            BEEP_VOL => '0.1');
        waitpid($pid, 0);
        is($exit, 0, 'checkpoint-beep: BEEP_VOL=0.1 -> exit 0');
        my @calls = _read_calls($bindir);
        is(scalar(@calls), 4, 'checkpoint-beep: BEEP_VOL=0.1 -> exactly 4 stub play invocations');
        ok((grep { /vol 0\.1/ } @calls) == 4, 'checkpoint-beep: BEEP_VOL=0.1 -> all 4 calls carry vol 0.1');
    }
};

# ============================================================
# subtest 'pre-scenario-gate' -- Task 3. The 5 frozen-probe rows from
# tonight (2026-09-10), adapted for offline determinism with
# GATE_FAKE_ADDR=127.0.0.1 (unconditionally accepted by the script's own
# Gate-1 logic) and GATE_FAKE_NET=up (new value, this plan's addition)
# used wherever the probe's intent is Gate 3, not Gate 2 -- neither
# addition changes the exit code or gate verdict versus tonight's
# live-rig result, they only remove the live-LMS/live-internet
# dependency. diag() the full captured stdout so every future `prove -v`
# run re-quotes the raw output as a durable record.
# ============================================================
subtest 'pre-scenario-gate' => sub {
    # Row 1: stale IP -> Gate 1 fails
    {
        my ($exit, $stdout, $stderr) = run_tool($gate_script, [],
            GATE_FAKE_ADDR => '192.168.1.200', GATE_FAKE_NET => 'up', GATE_FAKE_TARGETS => '0');
        is($exit, 1, 'pre-scenario-gate: stale IP -> exit 1 (frozen probe)');
        like($stdout, qr/NICHT gebunden/, 'pre-scenario-gate: stale IP -> NICHT gebunden');
        like($stdout, qr/TOR ROT/, 'pre-scenario-gate: stale IP -> TOR ROT');
        diag("Row 1 (stale IP) raw stdout:\n$stdout");
    }

    # Row 2: network down -> Gate 2 fails
    {
        my ($exit, $stdout, $stderr) = run_tool($gate_script, [],
            GATE_FAKE_ADDR => '127.0.0.1', GATE_FAKE_NET => 'down', GATE_FAKE_TARGETS => '0');
        is($exit, 1, 'pre-scenario-gate: network down -> exit 1 (frozen probe)');
        like($stdout, qr/spclient nicht erreichbar/, 'pre-scenario-gate: network down -> spclient nicht erreichbar');
        like($stdout, qr/TOR ROT/, 'pre-scenario-gate: network down -> TOR ROT');
        diag("Row 2 (network down) raw stdout:\n$stdout");
    }

    # Row 3: several targets = outage -> Gate 3 fails
    {
        my ($exit, $stdout, $stderr) = run_tool($gate_script, [],
            GATE_FAKE_ADDR => '127.0.0.1', GATE_FAKE_NET => 'up', GATE_FAKE_TARGETS => '3');
        is($exit, 1, 'pre-scenario-gate: several targets -> exit 1 (frozen probe)');
        like($stdout, qr/VERSCHIEDENE Ziele/, 'pre-scenario-gate: several targets -> VERSCHIEDENE Ziele');
        like($stdout, qr/TOR ROT/, 'pre-scenario-gate: several targets -> TOR ROT');
        diag("Row 3 (several targets) raw stdout:\n$stdout");
    }

    # Row 4: one stuck track -> warn but allow
    {
        my ($exit, $stdout, $stderr) = run_tool($gate_script, [],
            GATE_FAKE_ADDR => '127.0.0.1', GATE_FAKE_NET => 'up', GATE_FAKE_TARGETS => '1');
        is($exit, 0, 'pre-scenario-gate: one stuck track -> exit 0 (frozen probe)');
        like($stdout, qr/steckengebliebener Track/, 'pre-scenario-gate: one stuck track -> steckengebliebener Track');
        like($stdout, qr/TOR GRUEN/, 'pre-scenario-gate: one stuck track -> TOR GRUEN');
        diag("Row 4 (one stuck track) raw stdout:\n$stdout");
    }

    # Row 5: all clear
    {
        my ($exit, $stdout, $stderr) = run_tool($gate_script, [],
            GATE_FAKE_ADDR => '127.0.0.1', GATE_FAKE_NET => 'up', GATE_FAKE_TARGETS => '0');
        is($exit, 0, 'pre-scenario-gate: all clear -> exit 0 (frozen probe)');
        like($stdout, qr/keine Timeouts im Fenster/, 'pre-scenario-gate: all clear -> keine Timeouts im Fenster');
        like($stdout, qr/TOR GRUEN/, 'pre-scenario-gate: all clear -> TOR GRUEN');
        diag("Row 5 (all clear) raw stdout:\n$stdout");
    }
};

# ============================================================
# subtest 'soloist-window-gate' -- WR-04 (82-33). Regressionswaechter fuer
# alle vier Code-Review-Runde-7-Befunde (82-REVIEW.md): CR-01
# (Cross-Player), WR-01 (Slim::Control::Commands-Ausschluss), WR-02
# (Optionsparser-Endlosschleife), WR-03 (stummer Instrumentenfehler bei
# server.log-Lesefehler). Jeder Fall traegt sowohl den Muss-Fehlschlag
# (Verhalten VOR der jeweiligen Korrektur, siehe 82-33-PLAN.md Task 1/2)
# als auch die Korrektur selbst -- eine Mutationsprobe (jede Korrektur
# einzeln in einer Wegwerfkopie zurueckgenommen) bricht dann genau den
# zugehoerigen Fall, alle anderen bleiben gruen (siehe 82-33-SUMMARY.md).
#
# Test 3 verwendet ABSICHTLICH NICHT den gemeinsamen run_tool-Helfer:
# run_tool wartet blockierend per waitpid und gibt die Kind-PID nie an den
# Aufrufer zurueck -- ein Regressions-Haenger in need() wuerde diesen Test
# selbst auf unbestimmte Zeit blockieren. Der eigene Fork-Block execut
# stattdessen `timeout 8 bash ...` (ein externes Programm, NICHT Perls
# alarm), das den Kindprozess von AUSSEN beendet, unabhaengig davon, ob
# der Perl-Elternprozess je aus waitpid zurueckkehrt -- kein Orphan
# moeglich.
# ============================================================
subtest 'soloist-window-gate' => sub {
    # Test 1 (CR-01, Cross-Player): eine Treffer-Zeile fuer MAC A --
    # Aufruf mit einer FREMDEN MAC darf NICHT treffen, Aufruf mit der
    # EIGENEN MAC muss weiterhin treffen.
    {
        my ($fh, $file) = tempfile();
        print $fh "Control: Treffer seek wantMs=0 haveMs=undef armed=1 source=- (aa:bb:cc:dd:ee:01)\n";
        close($fh);

        my ($exit, $stdout, $stderr) = run_tool($window_gate_script,
            [ '--from-file', $file, '--mac', '99:99:99:99:99:99' ]);
        isnt($exit, 0, 'soloist-window-gate: CR-01 fremde MAC -> Exit ungleich 0');
        like($stdout, qr/VERDIKT: INSTRUMENT_NICHT_SCHARF/,
            'soloist-window-gate: CR-01 fremde MAC -> INSTRUMENT_NICHT_SCHARF (nicht GETROFFEN)');

        ($exit, $stdout, $stderr) = run_tool($window_gate_script,
            [ '--from-file', $file, '--mac', 'aa:bb:cc:dd:ee:01' ]);
        is($exit, 0, 'soloist-window-gate: CR-01 eigene MAC -> Exit 0');
        like($stdout, qr/VERDIKT: GETROFFEN_PLAYING/,
            'soloist-window-gate: CR-01 eigene MAC -> GETROFFEN_PLAYING');
        unlink($file);
    }

    # Test 2 (WR-01, Geschwisterpaket): ausschliesslich eine
    # Slim::Control::Commands-Zeile (Paketname enthaelt "Control:" als
    # Substring, ist aber NICHT Plugins::SpotOn::Soloist::Control::) --
    # muss INSTRUMENT_NICHT_SCHARF liefern, nicht VERFEHLT_ANDERER_GRUND.
    {
        my ($fh, $file) = tempfile();
        print $fh "[26-09-12 12:00:00.0000] Slim::Control::Commands::playlistJumpCommand (512) Jumping to index 1\n";
        close($fh);

        my ($exit, $stdout, $stderr) = run_tool($window_gate_script, [ '--from-file', $file ]);
        isnt($exit, 0, 'soloist-window-gate: WR-01 Geschwisterpaket -> Exit ungleich 0');
        like($stdout, qr/VERDIKT: INSTRUMENT_NICHT_SCHARF/,
            'soloist-window-gate: WR-01 Geschwisterpaket -> INSTRUMENT_NICHT_SCHARF (nicht VERFEHLT_ANDERER_GRUND)');
        unlike($stdout, qr/VERFEHLT_ANDERER_GRUND/,
            'soloist-window-gate: WR-01 Geschwisterpaket -> kein VERFEHLT_ANDERER_GRUND');
        unlink($file);
    }

    # Test 3 (WR-02, Optionsparser): --from-file ohne Wert (letztes
    # Argument) muss innerhalb von 3 Sekunden mit Exit 2 abbrechen --
    # Laufzeit gemessen, nicht nur Exit-Code (ein Regressions-Merge, der
    # need() versehentlich entfernt, wuerde sonst nur am Exit-Code
    # vorbeischluepfen, wenn zufaellig ein Folgeargument existiert).
    {
        my ($out_fh, $out_file) = tempfile();
        my ($err_fh, $err_file) = tempfile();
        my $start = Time::HiRes::time();
        my $pid = fork();
        die "soloist-window-gate Test 3: fork failed: $!" unless defined $pid;
        if ($pid == 0) {
            open(STDOUT, '>&', $out_fh) or exit(126);
            open(STDERR, '>&', $err_fh) or exit(126);
            exec('timeout', '8', 'bash', $window_gate_script, '--from-file') or exit(127);
        }
        waitpid($pid, 0);
        my $exit_code = $? >> 8;
        my $duration  = Time::HiRes::time() - $start;
        close($out_fh);
        close($err_fh);
        my $stderr_text = _slurp($err_file);
        unlink($out_file, $err_file);

        cmp_ok($duration, '<', 3, 'soloist-window-gate: WR-02 faellt schnell, keine Endlosschleife');
        is($exit_code, 2, 'soloist-window-gate: WR-02 --from-file ohne Wert -> Exit 2 (nicht 124/timeout)');
        like($stderr_text, qr/benoetigt einen Wert/,
            'soloist-window-gate: WR-02 Fehlermeldung vorhanden');
    }

    # Test 4 (WR-03, PIPESTATUS, Credential-Verweigerung): PATH-gestubbtes
    # `sudo`, das Exit 1 MIT einer stderr-Zeile liefert (eine echte
    # `sudo -n`-Verweigerung schreibt ebenfalls immer auf stderr) -- muss
    # Exit 2 mit FEHLER-Meldung liefern, NICHT INSTRUMENT_NICHT_SCHARF.
    {
        my $stubdir = tempdir(CLEANUP => 1);
        write_custom_stub($stubdir, 'sudo',
            "#!/bin/bash
echo 'sudo: a password is required' >&2
exit 1
");

        my ($exit, $stdout, $stderr) = run_tool($window_gate_script,
            [ '--mac', 'aa:bb:cc:dd:ee:01', '--t0', '00:00:00', '--t1', '23:59:59',
              '--date', '26-01-01', '--server-log', '/nonexistent/spoton33/server.log' ],
            PATH => "$stubdir:$ENV{PATH}");
        is($exit, 2, 'soloist-window-gate: WR-03 Credential-Verweigerung -> Exit 2');
        like($stderr, qr/FEHLER: server\.log nicht lesbar/,
            'soloist-window-gate: WR-03 Credential-Verweigerung -> FEHLER-Meldung');
        unlike($stdout, qr/INSTRUMENT_NICHT_SCHARF/,
            'soloist-window-gate: WR-03 Credential-Verweigerung -> nicht stumm INSTRUMENT_NICHT_SCHARF');
    }

    # Test 4b (WR-03, echter Leerfund, Diskriminator-Gegenprobe): derselbe
    # Aufbau, aber der sudo-Stub liefert Exit 1 OHNE jede Ausgabe (die
    # echte "grep fand nichts"-Situation) -- muss weiterhin
    # INSTRUMENT_NICHT_SCHARF liefern, Exit ungleich 2. Ohne diesen Fall
    # bliebe eine Mutationsprobe, die den `[ -s "$WINDOW_ERR" ]`-Diskriminator
    # entfernt (rc=1 wird dann IMMER als Fehler gewertet), unentdeckt --
    # Test 4 allein bleibt dabei gruen, da er sudo mit stderr stubt.
    {
        my $stubdir = tempdir(CLEANUP => 1);
        write_custom_stub($stubdir, 'sudo', "#!/bin/bash
exit 1
");

        my ($exit, $stdout, $stderr) = run_tool($window_gate_script,
            [ '--mac', 'aa:bb:cc:dd:ee:01', '--t0', '00:00:00', '--t1', '23:59:59',
              '--date', '26-01-01', '--server-log', '/nonexistent/spoton33/server.log' ],
            PATH => "$stubdir:$ENV{PATH}");
        isnt($exit, 2, 'soloist-window-gate: WR-03 echter Leerfund -> Exit ungleich 2');
        like($stdout, qr/VERDIKT: INSTRUMENT_NICHT_SCHARF/,
            'soloist-window-gate: WR-03 echter Leerfund -> weiterhin INSTRUMENT_NICHT_SCHARF');
    }

    # Test 5 (Baseline-Erhalt): die woertlich aus 82-32-PLAN.md/-SUMMARY.md
    # uebernommenen Muss-Fehlschlag- und Positive-Probe-Fixtures liefern
    # weiterhin dieselben Verdikte wie vor diesem Plan -- Nachweis, dass
    # keine der vier Korrekturen ein bestehendes Verdikt veraendert hat.
    {
        my ($fh, $file) = tempfile();
        print $fh "Control: dispatch play armed=0 uri=spotify:track:4PTG3Z6ehGkBFwjybzWkR8\n";
        close($fh);
        my ($exit, $stdout, $stderr) = run_tool($window_gate_script, [ '--from-file', $file ]);
        isnt($exit, 0, 'soloist-window-gate: Baseline VERFEHLT_MISMATCH -> Exit ungleich 0');
        like($stdout, qr/VERDIKT: VERFEHLT_MISMATCH/,
            'soloist-window-gate: Baseline VERFEHLT_MISMATCH unveraendert');
        unlink($file);
    }
    {
        my ($fh, $file) = tempfile();
        print $fh "Control: Treffer seek wantMs=0 haveMs=undef armed=1 source=getNextTrack (aa:bb:cc:dd:ee:ff)\n";
        close($fh);
        my ($exit, $stdout, $stderr) = run_tool($window_gate_script, [ '--from-file', $file ]);
        is($exit, 0, 'soloist-window-gate: Baseline GETROFFEN_PLAYING -> Exit 0');
        like($stdout, qr/VERDIKT: GETROFFEN_PLAYING/,
            'soloist-window-gate: Baseline GETROFFEN_PLAYING unveraendert');
        unlink($file);
    }

    # Test 9 (WR-01, echte Fundstelle 1 -- Control.pm:794 _recordErrorOnce,
    # 82-37): der Fallback any_control_line verankerte die MAC bislang als
    # letztes Klammer-Token -- diese reale Nachricht bettet die MAC an
    # ANDERER Stelle ein ("<mac>: daemon not paired (request refused)",
    # kein Klammer-Suffix). Eigene MAC muss VERFEHLT_ANDERER_GRUND liefern
    # (nicht stumm INSTRUMENT_NICHT_SCHARF), eine fremde MAC muss weiterhin
    # INSTRUMENT_NICHT_SCHARF liefern (CR-01-Cross-Player-Filter bleibt
    # erhalten -- das Paketpraefix ist der Filter, nicht die MAC-Position).
    {
        my ($fh, $file) = tempfile();
        print $fh "[26-09-12 12:00:00.0000] Plugins::SpotOn::Soloist::Control::_recordErrorOnce (794) aa:bb:cc:dd:ee:01: daemon not paired (request refused)\n";
        close($fh);

        my ($exit, $stdout, $stderr) = run_tool($window_gate_script,
            [ '--from-file', $file, '--mac', 'aa:bb:cc:dd:ee:01' ]);
        isnt($exit, 0, 'soloist-window-gate: WR-01 verlorene Logstelle _recordErrorOnce eigene MAC -> Exit ungleich 0');
        like($stdout, qr/VERDIKT: VERFEHLT_ANDERER_GRUND/,
            'soloist-window-gate: WR-01 verlorene Logstelle _recordErrorOnce eigene MAC -> VERFEHLT_ANDERER_GRUND');

        ($exit, $stdout, $stderr) = run_tool($window_gate_script,
            [ '--from-file', $file, '--mac', '99:99:99:99:99:99' ]);
        like($stdout, qr/VERDIKT: INSTRUMENT_NICHT_SCHARF/,
            'soloist-window-gate: WR-01 verlorene Logstelle _recordErrorOnce fremde MAC -> weiterhin INSTRUMENT_NICHT_SCHARF');
        unlink($file);
    }

    # Test 10 (WR-01, echte Fundstelle 2 -- Control.pm:1764 onEvent
    # prefetch hit, 82-37): zweite reale Nachrichtenform ohne
    # MAC-am-Zeilenende ("Control: prefetch hit on <mac> (<uri>)").
    {
        my ($fh, $file) = tempfile();
        print $fh "[26-09-12 12:00:05.0000] Plugins::SpotOn::Soloist::Control::onEvent (1764) Control: prefetch hit on aa:bb:cc:dd:ee:01 (spotify:track:4PTG3Z6ehGkBFwjybzWkR8)\n";
        close($fh);

        my ($exit, $stdout, $stderr) = run_tool($window_gate_script,
            [ '--from-file', $file, '--mac', 'aa:bb:cc:dd:ee:01' ]);
        isnt($exit, 0, 'soloist-window-gate: WR-01 verlorene Logstelle onEvent eigene MAC -> Exit ungleich 0');
        like($stdout, qr/VERDIKT: VERFEHLT_ANDERER_GRUND/,
            'soloist-window-gate: WR-01 verlorene Logstelle onEvent eigene MAC -> VERFEHLT_ANDERER_GRUND');

        ($exit, $stdout, $stderr) = run_tool($window_gate_script,
            [ '--from-file', $file, '--mac', '99:99:99:99:99:99' ]);
        like($stdout, qr/VERDIKT: INSTRUMENT_NICHT_SCHARF/,
            'soloist-window-gate: WR-01 verlorene Logstelle onEvent fremde MAC -> weiterhin INSTRUMENT_NICHT_SCHARF');
        unlink($file);
    }

    # Test 11 (WR-02, Positivprobe Ausgang 5, 82-37): das Verdikt zitiert
    # die gefundene Zeile woertlich im Verdikt-Text -- ein Mensch (oder ein
    # Folgeplan) kann daraus den realen Fund nachvollziehen, statt nur
    # einer nackten VERFEHLT_ANDERER_GRUND-Konstante.
    {
        my ($fh, $file) = tempfile();
        print $fh "[26-09-12 12:00:00.0000] Plugins::SpotOn::Soloist::Control::_recordErrorOnce (794) aa:bb:cc:dd:ee:01: daemon not paired (request refused)\n";
        close($fh);
        my ($exit, $stdout, $stderr) = run_tool($window_gate_script,
            [ '--from-file', $file, '--mac', 'aa:bb:cc:dd:ee:01' ]);
        like($stdout, qr/VERDIKT: VERFEHLT_ANDERER_GRUND \(.*_recordErrorOnce.*daemon not paired.*\)/,
            'soloist-window-gate: WR-02 Positivprobe Ausgang 5 zitiert die Fundzeile woertlich');
        unlink($file);
    }

    # Test 6 (82-35, Fall i): --trigger-mode connect qualifiziert sofort auf
    # eine synthetische dir=meta/frame=HANDSHAKE-OK-Zeile, ohne --target-uri.
    {
        my ($exit, $stdout, $stderr) = run_tool_stdin($window_gate_script,
            [ '--check-trigger', '--trigger-mode', 'connect' ],
            qq({"ts":"t","epoch":1,"dir":"meta","frame":"HANDSHAKE-OK"}\n));
        is($exit, 0, 'soloist-window-gate: 82-35 Fall i HANDSHAKE-OK -> Exit 0');
        like($stdout, qr/QUALIFIES/,
            'soloist-window-gate: 82-35 Fall i HANDSHAKE-OK -> QUALIFIES');
    }

    # Test 7 (82-35, Fall ii): derselbe connect-Modus DARF NICHT auf eine
    # echte rx/track_changed-Zeile qualifizieren, selbst wenn deren URI zur
    # (hier ignorierten) --target-uri passen wuerde -- der entscheidende
    # Diskriminator gegenueber dem alten track-match-Modus.
    {
        my $rx_line = `command grep -m1 'track_changed' $project_dir/t/fixtures/soloist/g1-lauf-a1.jsonl`;
        my ($exit, $stdout, $stderr) = run_tool_stdin($window_gate_script,
            [ '--check-trigger', '--trigger-mode', 'connect', '--target-uri', 'spotify:track:4PTG3Z6ehGkBFwjybzWkR8' ],
            $rx_line);
        is($exit, 1, 'soloist-window-gate: 82-35 Fall ii rx/track_changed im connect-Modus -> Exit 1');
        like($stdout, qr/NEUTRAL/,
            'soloist-window-gate: 82-35 Fall ii rx/track_changed im connect-Modus -> NEUTRAL (nicht QUALIFIES)');
    }

    # Test 8 (82-35, Fall iii): ein unbekannter --trigger-mode-Wert bricht
    # mit Exit 2 und einer Fehlermeldung ab, statt stillschweigend auf
    # track-match oder connect zurueckzufallen.
    {
        my ($exit, $stdout, $stderr) = run_tool_stdin($window_gate_script,
            [ '--check-trigger', '--trigger-mode', 'gibtsnicht' ],
            qq({}\n));
        is($exit, 2, 'soloist-window-gate: 82-35 Fall iii unbekannter --trigger-mode -> Exit 2');
        like($stderr, qr/unbekannter --trigger-mode/,
            'soloist-window-gate: 82-35 Fall iii unbekannter --trigger-mode -> Fehlermeldung');
    }

    # Test 9 (WR-03 NUL-Byte, 82-37, echter Bugbeleg): Zeile 1 der
    # server.log-Fixture ist ein alleinstehendes NUL-Byte (eigene Zeile,
    # VOR der Fixture -- nicht auf derselben Zeile vorangestellt, sonst
    # verschiebt sich das awk-Zeitfeld um ein Zeichen und die Zeile faellt
    # aus dem Fenster). Zeile 2 ist die exakte _recordErrorOnce-Fixture aus
    # Test A/9 oben. Ein PATH-injizierter sudo-Stub kuerzt sein eigenes -n
    # und reicht den Rest per exec an das ECHTE System-grep weiter, damit
    # der Unterschied wirklich am -a-Flag des Gate-Skripts haengt, nicht an
    # einem Test-Stub-Verhalten. Manuell gegenprobt (siehe SUMMARY): eine
    # Wegwerfkopie OHNE -a liefert fuer dieselbe Fixture
    # INSTRUMENT_NICHT_SCHARF statt VERFEHLT_ANDERER_GRUND.
    {
        my $stubdir = tempdir(CLEANUP => 1);
        write_custom_stub($stubdir, 'sudo', "#!/bin/bash
shift
exec \"\$\@\"
");
        my ($fh, $file) = tempfile();
        binmode($fh);
        print $fh "\x00\n";
        print $fh "[26-09-12 12:00:00.0000] Plugins::SpotOn::Soloist::Control::_recordErrorOnce (794) aa:bb:cc:dd:ee:01: daemon not paired (request refused)\n";
        close($fh);

        my ($exit, $stdout, $stderr) = run_tool($window_gate_script,
            [ '--mac', 'aa:bb:cc:dd:ee:01', '--t0', '11:59:00', '--t1', '12:01:00',
              '--date', '26-09-12', '--server-log', $file ],
            PATH => "$stubdir:$ENV{PATH}");
        like($stdout, qr/VERDIKT: VERFEHLT_ANDERER_GRUND/,
            'soloist-window-gate: WR-03 NUL-Byte maskiert echten Treffer im Fenster nicht (mit -a)');
        unlink($file);
    }

    # Test 10 (WR-04 Normalisierung, 82-37): Grossschreibung im --mac-Wert
    # wird klaglos zu Kleinschreibung normalisiert -- eine kleingeschriebene
    # Fixture-MAC liefert weiterhin dasselbe Verdikt.
    {
        my ($fh, $file) = tempfile();
        print $fh "Control: Treffer seek wantMs=0 haveMs=undef armed=1 source=- (aa:bb:cc:dd:ee:01)\n";
        close($fh);
        my ($exit, $stdout, $stderr) = run_tool($window_gate_script,
            [ '--from-file', $file, '--mac', 'AA:BB:CC:DD:EE:01' ]);
        is($exit, 0, 'soloist-window-gate: WR-04 Normalisierung Grossschreibung -> Exit 0');
        like($stdout, qr/VERDIKT: GETROFFEN_PLAYING/,
            'soloist-window-gate: WR-04 Normalisierung Grossschreibung -> GETROFFEN_PLAYING');
        unlink($file);
    }

    # Test 11 (WR-04 Ablehnung, 82-37): ein Nicht-MAC-String (z. B. ein
    # Spielername) bricht mit Exit 2 und der benannten Fehlermeldung ab,
    # BEVOR classify_window je aufgerufen wird -- kein stilles
    # INSTRUMENT_NICHT_SCHARF.
    {
        my ($fh, $file) = tempfile();
        print $fh "Control: Treffer seek wantMs=0 haveMs=undef armed=1 source=- (aa:bb:cc:dd:ee:01)\n";
        close($fh);
        my ($exit, $stdout, $stderr) = run_tool($window_gate_script,
            [ '--from-file', $file, '--mac', 'lavender-pa' ]);
        is($exit, 2, 'soloist-window-gate: WR-04 Ablehnung Nicht-MAC -> Exit 2');
        like($stderr, qr/FEHLER: --mac ist ungueltig/,
            'soloist-window-gate: WR-04 Ablehnung Nicht-MAC -> Fehlermeldung');
        unlike($stdout, qr/VERDIKT:/,
            'soloist-window-gate: WR-04 Ablehnung Nicht-MAC -> keine Verdikt-Klassifikation versucht');
        unlink($file);
    }

    # Test G (82-41 Task 3, R9-WR-04 G3-INSTR MAC-los dokumentiert): eine
    # synthetische, MAC-lose G3-INSTR-Zeile (reales Nachrichtenformat aus
    # Control.pm:1231, SpotOn::Soloist::Control::_dispatch). MIT --mac
    # gesetzt bleibt sie weiterhin unsichtbar fuer den any_control_line-
    # Fallback (INSTRUMENT_NICHT_SCHARF, dokumentiertes, akzeptiertes
    # Restrisiko -- dieser Task AENDERT das Verhalten NICHT, er sperrt es
    # fest und macht den Kommentar wahrheitsgemaess). OHNE --mac bleibt
    # dieselbe Zeile weiterhin auffindbar (Beleg, dass der bestehende
    # Teil-Fix aus 82-37 unveraendert funktioniert).
    {
        my ($fh, $file) = tempfile();
        print $fh "[26-09-12 12:00:00.0000] Plugins::SpotOn::Soloist::Control::_dispatch (1230) SpotOn G3-INSTR: dispatch pause folded into pending play uri=- age=0.010\n";
        close($fh);

        my ($exit, $stdout, $stderr) = run_tool($window_gate_script,
            [ '--from-file', $file, '--mac', 'aa:bb:cc:dd:ee:01' ]);
        isnt($exit, 0, 'soloist-window-gate: WR-04 G3-INSTR MAC-los dokumentiert mit --mac -> Exit ungleich 0');
        like($stdout, qr/VERDIKT: INSTRUMENT_NICHT_SCHARF/,
            'soloist-window-gate: WR-04 G3-INSTR MAC-los dokumentiert mit --mac -> weiterhin INSTRUMENT_NICHT_SCHARF (dokumentiertes Restrisiko)');

        ($exit, $stdout, $stderr) = run_tool($window_gate_script,
            [ '--from-file', $file ]);
        isnt($exit, 0, 'soloist-window-gate: WR-04 G3-INSTR MAC-los dokumentiert ohne --mac -> Exit ungleich 0');
        like($stdout, qr/VERDIKT: VERFEHLT_ANDERER_GRUND/,
            'soloist-window-gate: WR-04 G3-INSTR MAC-los dokumentiert ohne --mac -> weiterhin gefunden (bestehender Teil-Fix 82-37 unveraendert)');
        unlink($file);
    }
};

# ============================================================
# subtest 'extract-run-nextifmore' -- 82-41 Task 1. Closes the visibility gap
# named in .planning/debug/get-state-statt-play.md Zeilen 205-304: the
# LMS-owned Slim::Player::StreamingController failure channel had no
# @SRV_CATS category for its trigger line (_NextIfMore), and its already-
# categorized terminal line (" - new state ", caught by the pre-existing
# 'playerTrackStarted / playerStopped / new state' pattern) was invisible in
# that collective bucket to nine prior planning rounds. Two new categories
# are added AFTER that pre-existing category (additive, Baseline-Erhalt) --
# Test A proves the trigger line is now its own category, Test B proves the
# terminal line appears in BOTH the unchanged old category AND the new
# precise one, Test C proves the new patterns are not overbroad (a plain
# playerTrackStarted line, carrying neither "_NextIfMore" nor
# "NextTrackError - new state ", stays out of both new categories).
#
# All three lines share one synthetic server.log fixture and one
# extract-run.pl invocation (SUDO_BIN=/bin/true is REQUIRED -- without the
# stub, extract-run.pl's unconditional sudo -n gate at main() aborts before
# reading --server-log at all, per read_first Runde-3-Korrektur W4).
#
# Mutation probe M-1 (run manually during development, documented in
# 82-41-SUMMARY.md, throwaway copy discarded afterward): removing both new
# @SRV_CATS entries from a throwaway copy turns Test A fully red (the
# trigger line falls back into the unbucketed tail counter) and Test B
# partially red (the new precise category assertion fails while the
# unchanged old-category assertion stays green) -- proving additivity, not
# just presence.
# ============================================================
subtest 'extract-run-nextifmore' => sub {
    my ($fh, $file) = tempfile();
    print $fh "[26-09-12 12:00:05.0000] Slim::Player::StreamingController::_eventAction (271) aa:bb:cc:dd:ee:01: NextTrackError in STOPPED-TRACKWAIT -> Slim::Player::StreamingController::_NextIfMore\n";
    print $fh "[26-09-12 12:00:05.5000] Slim::Player::StreamingController::_eventAction (301) aa:bb:cc:dd:ee:01: NextTrackError - new state STOPPED-IDLE\n";
    print $fh "[26-09-12 12:00:06.0000] Slim::Player::StreamingController::_eventAction (321) aa:bb:cc:dd:ee:01: playerTrackStarted\n";
    close($fh);

    my ($exit, $stdout, $stderr) = run_perl_tool($extract_run_script,
        [ 'aa:bb:cc:dd:ee:01', '12:00:00', '12:00:10',
          '--server-log', $file, '--date', '2026-09-12' ],
        SUDO_BIN => '/bin/true');
    is($exit, 0, 'extract-run-nextifmore: SUDO_BIN-Stub laesst das Werkzeug normal durchlaufen (Exit 0)')
        or diag("stderr: $stderr");

    # Section-scoped extraction: capture the body of each "--- <header> ---"
    # block up to the NEXT header, so a raw line's presence is checked
    # WITHIN its category's own section, not just anywhere in the full
    # multi-section stdout blob.
    my $section_body = sub {
        my ($hdr_re) = @_;
        return ($stdout =~ /---\s*\Q$hdr_re\E.*?---\n(.*?)(?=\n---|\z)/s) ? $1 : '';
    };

    my $trigger_body  = $section_body->('server.log: NextTrackError -> _NextIfMore');
    my $terminal_body = $section_body->('server.log: NextTrackError - new state');
    my $baseline_body = $section_body->('server.log: playerTrackStarted / playerStopped / new state');

    # Test A: the trigger line (previously wholly uncategorized) is now its
    # own, named category.
    like($trigger_body, qr/_NextIfMore/,
        'extract-run-nextifmore: Test A Ausloeserzeile erscheint in der neuen _NextIfMore-Kategorie');
    unlike($trigger_body, qr/ - new state /,
        'extract-run-nextifmore: Test A Kategorie enthaelt NICHT die Terminalzeile');
    unlike($trigger_body, qr/playerTrackStarted\n/,
        'extract-run-nextifmore: Test A Kategorie enthaelt NICHT die Test-C-Zeile');

    # Test B: the terminal line appears in BOTH the unchanged old collective
    # category AND the new, precise one -- additive, no baseline break.
    like($terminal_body, qr/NextTrackError - new state STOPPED-IDLE/,
        'extract-run-nextifmore: Test B Terminalzeile erscheint in der neuen praeziseren Kategorie');
    like($baseline_body, qr/NextTrackError - new state STOPPED-IDLE/,
        'extract-run-nextifmore: Test B Terminalzeile bleibt zusaetzlich in der unveraenderten Altkategorie (Baseline-Erhalt)');

    # Test C: a third, independent line carrying neither "_NextIfMore" nor
    # "NextTrackError - new state " must NOT fall into either new category
    # -- it stays visible only in the old collective category. Proves the
    # new patterns are not overbroad.
    like($baseline_body, qr/playerTrackStarted\n/,
        'extract-run-nextifmore: Test C Negativzeile bleibt in der Altkategorie sichtbar');
    unlike($trigger_body, qr/playerTrackStarted/,
        'extract-run-nextifmore: Test C Negativzeile faellt NICHT in die neue Ausloeser-Kategorie');
    unlike($terminal_body, qr/playerTrackStarted/,
        'extract-run-nextifmore: Test C Negativzeile faellt NICHT in die neue Terminal-Kategorie');

    unlink($file);
};

# ============================================================
# subtest 'extract-run-connect-off' -- 84-21 Task 1 (D-31). The refusal line
# Control.pm's _refuseTransferConnectOff writes ("Control: transfer-in
# refused -- Spotify Connect is off for this player (entry=..., mode=...,
# deactivate=<sent|no_ws|not_sent>, <mac>)") is the ONLY server.log channel
# of the refusal and of its deactivate (the probe op logs no dispatch line).
# Uncategorised lines are only counted, never printed (extract-run.pl
# architecture rule 4), so without a category every live "refusal_lines=0"
# reading would be vacuous. Must-match: the refusal line lands in its own
# section. Must-NOT-match: the neighbouring `transfer-in -> mode=connect`
# line stays in the mode-transition category only.
# ============================================================
subtest 'extract-run-connect-off' => sub {
    my ($fh, $file) = tempfile();
    print $fh "[26-10-06 12:00:05.0000] Plugins::SpotOn::Soloist::Control::_refuseTransferConnectOff (4170) Control: transfer-in refused -- Spotify Connect is off for this player (entry=device_changed, mode=idle, deactivate=sent, aa:bb:cc:dd:ee:01)\n";
    print $fh "[26-10-06 12:00:06.0000] Plugins::SpotOn::Soloist::Control::_onFrameDeviceChanged (4174) Control: transfer-in -> mode=connect (aa:bb:cc:dd:ee:01)\n";
    close($fh);

    my ($exit, $stdout, $stderr) = run_perl_tool($extract_run_script,
        [ 'aa:bb:cc:dd:ee:01', '12:00:00', '12:00:10',
          '--server-log', $file, '--date', '2026-10-06' ],
        SUDO_BIN => '/bin/true');
    is($exit, 0, 'extract-run-connect-off: SUDO_BIN-Stub laesst das Werkzeug durchlaufen (Exit 0)')
        or diag("stderr: $stderr");

    my $section_body = sub {
        my ($hdr_re) = @_;
        return ($stdout =~ /---\s*\Q$hdr_re\E.*?---\n(.*?)(?=\n---|\z)/s) ? $1 : '';
    };
    my $refusal_body = $section_body->('server.log: Control connect-off refusal');
    my $mode_body    = $section_body->('server.log: Control mode transitions');

    like($refusal_body, qr/transfer-in refused -- Spotify Connect is off for this player \(entry=device_changed, mode=idle, deactivate=sent,/,
        'extract-run-connect-off: Must-Match die Ablehnungszeile steht in ihrer eigenen Kategorie');
    unlike($refusal_body, qr/transfer-in -> mode=connect/,
        'extract-run-connect-off: Must-Not-Match die mode=connect-Zeile steht NICHT in der Ablehnungskategorie');
    like($mode_body, qr/transfer-in -> mode=connect \(aa:bb:cc:dd:ee:01\)/,
        'extract-run-connect-off: die mode=connect-Zeile bleibt in der Modus-Kategorie (additiv)');
    unlike($mode_body, qr/transfer-in refused/,
        'extract-run-connect-off: die Ablehnungszeile faellt NICHT in die Modus-Kategorie');

    unlink($file);
};

# ============================================================
# subtest 'extract-run-84-26-repairs' -- 84-26 Task 2. The five INFO lines the
# 84-26 repairs write are the ONLY server.log channel of their effect (R1 refusal
# in Control.pm _reconcilePlan, R3 hold in _holdAfterForeignLeave, F-24-2 Control
# follow-the-daemon in requestTrack, F-24-2 Connect resume jump and change-handler
# unpause skip in Connect.pm _connectEvent). Uncategorised lines are only counted,
# never printed (extract-run.pl architecture rule 4), so without a category every
# live "refusal_lines=0" / "jump_line=0" reading would be vacuous. Must-match: each
# of the five lands in the new section. Must-NOT-match: the neighbouring
# `transfer-in -> mode=connect` line stays in the mode category only. Drift guard:
# the static part of every fabricated line is asserted to exist in the committed
# Perl (the literals are copied, the guard proves the copy).
# ============================================================
subtest 'extract-run-84-26-repairs' => sub {
    my $control_src = _slurp("$project_dir/Plugins/SpotOn/Soloist/Control.pm");
    my $connect_src = _slurp("$project_dir/Plugins/SpotOn/Connect.pm");
    for my $lit ('Control: requestResume refused -- daemon on',
                 'Control: daemon plays the autoplay-paused title',
                 '-- not re-adopting',
                 'Control: LMS re-open after transfer-in at',
                 '-- following the emitted position') {
        ok(index($control_src, $lit) >= 0, "extract-run-84-26-repairs: Control.pm still carries the literal `$lit`");
    }
    # 84.2-05: the dormant-session handoff and the context-end re-adoption hold
    # print into the same category (the refusal line is matched by its unchanged
    # prefix above, the INFO line only gains a ` planted=` token).
    for my $lit ('-- handing over to browse',
                 'Control: daemon plays the context-end title') {
        ok(index($control_src, $lit) >= 0, "extract-run-84.2-05: Control.pm carries the literal `$lit`");
    }
    for my $lit ('Connect: resume while LMS paused with the stream gone -- resume position set to the daemon',
                 'Connect: change while LMS paused with the stream gone -- unpause skipped') {
        ok(index($connect_src, $lit) >= 0, "extract-run-84-26-repairs: Connect.pm still carries the literal `$lit`");
    }

    my ($fh, $file) = tempfile();
    print $fh "[26-10-07 12:00:01.0000] Plugins::SpotOn::Soloist::Control::_execute (2790) Control: requestResume refused -- daemon on spotify:track:5fdNHVZHbWB1AaXk4RBGVD not on spotify:track:2374M0fQpWi3dLnB54qaLX (marker=none) (aa:bb:cc:dd:ee:01)\n";
    print $fh "[26-10-07 12:00:02.0000] Plugins::SpotOn::Soloist::Control::_holdAfterForeignLeave (5990) Control: daemon plays the autoplay-paused title spotify:track:5fdNHVZHbWB1AaXk4RBGVD while LMS plays foreign content -- not re-adopting (aa:bb:cc:dd:ee:01)\n";
    print $fh "[26-10-07 12:00:03.0000] Plugins::SpotOn::Soloist::Control::requestTrack (601) Control: LMS re-open after transfer-in at 31205 ms differs from the position Control emitted 53386 ms -- following the emitted position (aa:bb:cc:dd:ee:01)\n";
    print $fh "[26-10-07 12:00:04.0000] Plugins::SpotOn::Connect::_connectEvent (1850) Connect: resume while LMS paused with the stream gone -- resume position set to the daemon's 53.386 s, startOffset adjust skipped (aa:bb:cc:dd:ee:01)\n";
    print $fh "[26-10-07 12:00:05.0000] Plugins::SpotOn::Connect::_connectEvent (2200) Connect: change while LMS paused with the stream gone -- unpause skipped, the playlist play re-opens the new title (aa:bb:cc:dd:ee:01)\n";
    print $fh "[26-10-07 12:00:06.0000] Plugins::SpotOn::Soloist::Control::_onFrameDeviceChanged (4174) Control: transfer-in -> mode=connect (aa:bb:cc:dd:ee:01)\n";
    print $fh "[26-10-07 12:00:07.0000] Plugins::SpotOn::Soloist::Control::requestTrack (660) Control: LMS opened the daemon's current title spotify:track:5oiTnaEHK3OFDZIL8AIYwu in a dormant Connect session (status=paused, no Connect dispatch marker) -- handing over to browse (aa:bb:cc:dd:ee:01)\n";
    print $fh "[26-10-07 12:00:08.0000] Plugins::SpotOn::Soloist::Control::_holdAfterForeignLeave (6330) Control: daemon plays the context-end title spotify:track:7GVUxxxxxxxxxxxxxxxxxx LMS left while LMS plays foreign content -- not re-adopting (aa:bb:cc:dd:ee:01)\n";
    close($fh);

    my ($exit, $stdout, $stderr) = run_perl_tool($extract_run_script,
        [ 'aa:bb:cc:dd:ee:01', '12:00:00', '12:00:10',
          '--server-log', $file, '--date', '2026-10-07' ],
        SUDO_BIN => '/bin/true');
    is($exit, 0, 'extract-run-84-26-repairs: SUDO_BIN-Stub laesst das Werkzeug durchlaufen (Exit 0)')
        or diag("stderr: $stderr");

    my $section_body = sub {
        my ($hdr_re) = @_;
        return ($stdout =~ /---\s*\Q$hdr_re\E.*?---\n(.*?)(?=\n---|\z)/s) ? $1 : '';
    };
    my $rep_body  = $section_body->('server.log: 84-26 repairs');
    my $mode_body = $section_body->('server.log: Control mode transitions');

    like($rep_body, qr/requestResume refused -- daemon on spotify:track:5fdNHVZHbWB1AaXk4RBGVD not on /,
        'extract-run-84-26-repairs: Must-Match R1 refusal');
    like($rep_body, qr/plays the autoplay-paused title spotify:track:5fdNHVZHbWB1AaXk4RBGVD while LMS plays foreign content -- not re-adopting/,
        'extract-run-84-26-repairs: Must-Match R3 hold');
    like($rep_body, qr/LMS re-open after transfer-in at 31205 ms differs from the position Control emitted 53386 ms/,
        'extract-run-84-26-repairs: Must-Match F-24-2 Control follow-the-daemon');
    like($rep_body, qr/resume while LMS paused with the stream gone -- resume position set to the daemon's 53\.386 s/,
        'extract-run-84-26-repairs: Must-Match F-24-2 Connect resume jump');
    like($rep_body, qr/change while LMS paused with the stream gone -- unpause skipped/,
        'extract-run-84-26-repairs: Must-Match F-24-2 Connect change-handler skip');
    like($rep_body, qr/handing over to browse \(aa:bb:cc:dd:ee:01\)/,
        'extract-run-84.2-05: Must-Match dormant-session handoff');
    like($rep_body, qr/plays the context-end title spotify:track:7GVU\w+ LMS left while LMS plays foreign content -- not re-adopting/,
        'extract-run-84.2-05: Must-Match context-end re-adoption hold');
    unlike($rep_body, qr/transfer-in -> mode=connect/,
        'extract-run-84-26-repairs: Must-Not-Match die mode=connect-Zeile steht NICHT in der 84-26-Kategorie');
    like($mode_body, qr/transfer-in -> mode=connect \(aa:bb:cc:dd:ee:01\)/,
        'extract-run-84-26-repairs: die mode=connect-Zeile bleibt in der Modus-Kategorie (additiv)');

    unlink($file);
};

# ============================================================
# subtest 'extract-run-84.3-settle' -- 84.3-03 Task 2 (D-09). The settle line, the
# settle-check line, the LMS pause/underrun state rows and the LMS `Buffering...`
# progress lines are what a guarded context-end hit leaves in server.log. All four
# are uncategorised without an @SRV_CATS entry, i.e. only COUNTED, never printed
# (extract-run.pl architecture rule 4) -- a live "settle_lines=0" / "buffering tail
# empty" reading would be vacuous.
# Inputs, named by origin in the assertion names:
#   A "doctored run13 cut": the REAL run13 race window (t/fixtures/uat/
#     84.3-c5-run13-server-race.log, byte-exact from the archived server.log) with
#     exactly TWO FABRICATED lines inserted after its `Pause in BUFFERING-STREAMING`
#     row -- one settle warn line and one check info line, built from the Connect.pm
#     format strings with the run13 values. Everything else is real, including the
#     three `Buffering... 3896 / 81920` lines.
#   B "real run8 cut": t/fixtures/uat/84.3-c5-run8-server-pause-won.log, unchanged.
# The four sections sit BEFORE the 84-26 entry, so the remainder line
# (`[N von M server.log-Fensterzeilen ...]`) never lands in a section body: the
# buffering body of input A ends at the `--- server.log: 84-26 repairs` header.
# The throwaway copy of extract-run.pl without the four entries must turn the
# must-match assertions false (the :1174 pattern).
# ============================================================
subtest 'extract-run-84.3-settle' => sub {
    my $connect_src = _slurp("$project_dir/Plugins/SpotOn/Connect.pm");
    my $settle_lit  = 'Connect: context-end settle -- LMS discarded the pause while rebuffering, stopping ';
    my $check_lit   = 'Connect: context-end check -- ';
    ok(index($connect_src, $settle_lit) >= 0,
        "extract-run-84.3-settle: Connect.pm still carries the literal `$settle_lit`");
    ok(index($connect_src, $check_lit) >= 0,
        "extract-run-84.3-settle: Connect.pm still carries the literal `$check_lit`");

    my $fx_dir   = "$project_dir/t/fixtures/uat";
    my $race_fx  = "$fx_dir/84.3-c5-run13-server-race.log";
    my $won_fx   = "$fx_dir/84.3-c5-run8-server-pause-won.log";
    ok(-s $race_fx && -s $won_fx, 'extract-run-84.3-settle: both real fixtures present');

    # Input A: the real run13 cut + TWO FABRICATED lines (settle warn, check info).
    my $race = _slurp($race_fx);
    my $fab_settle = "[26-10-13 01:14:41.0458] Plugins::SpotOn::Connect::_settleNow (531) "
        . "Connect: context-end settle -- LMS discarded the pause while rebuffering, stopping 02:00:00:5a:11:01 "
        . "via=immediate songTime=201.115 duration=201.142 fullness=3896\n";
    my $fab_check  = "[26-10-13 01:14:41.0459] Plugins::SpotOn::Connect::_settleCheck (444) "
        . "Connect: context-end check -- settling 02:00:00:5a:11:01 songTime=201.115 duration=201.142 state=rebuffering stuck=1\n";
    my $doctored = $race;
    my $n_ins = ($doctored =~ s/(^[^\n]*Pause in BUFFERING-STREAMING -> [^\n]*\n)/$1$fab_settle$fab_check/m) ? 1 : 0;
    is($n_ins, 1, 'extract-run-84.3-settle: doctored run13 cut -- the two fabricated lines were inserted after the real Pause row');
    my ($fhA, $fileA) = tempfile();
    binmode($fhA);
    print $fhA $doctored;
    close($fhA);

    my @argsA = ('02:00:00:5a:11:01', '01:14:40', '01:14:43', '--server-log', $fileA, '--date', '2026-10-13');
    my @argsB = ('02:00:00:5a:11:01', '21:09:27', '21:09:29', '--server-log', $won_fx,  '--date', '2026-10-09');

    my $body_of = sub {
        my ($stdout, $hdr_re) = @_;
        return ($stdout =~ /---\s*\Q$hdr_re\E.*?---\n(.*?)(?=\n---|\z)/s) ? $1 : '';
    };
    my $c_settle = 'server.log: Connect: context-end settle';
    my $c_check  = 'server.log: Connect: context-end check';
    my $c_state  = 'server.log: LMS pause/underrun state rows';
    my $c_buf    = 'server.log: LMS buffering progress';

    # ---- input A ----
    my ($exitA, $outA, $errA) = run_perl_tool($extract_run_script, \@argsA, SUDO_BIN => '/bin/true');
    is($exitA, 0, 'extract-run-84.3-settle: doctored run13 cut -- SUDO_BIN stub lets the tool run (exit 0)')
        or diag("stderr: $errA");
    my ($settleA, $checkA, $stateA, $bufA) = map { $body_of->($outA, $_) } ($c_settle, $c_check, $c_state, $c_buf);

    like($outA, qr/---\s*\Q$c_settle\E[^\n]*\(Anzahl: 1 im Fenster/,
        'extract-run-84.3-settle: doctored run13 cut -- settle section header carries (Anzahl: 1 im Fenster');
    like($settleA, qr/context-end settle -- LMS discarded the pause while rebuffering, stopping 02:00:00:5a:11:01 via=immediate songTime=201\.115 duration=201\.142 fullness=3896/,
        'extract-run-84.3-settle: doctored run13 cut -- settle line printed in its section');
    unlike($settleA, qr/context-end check/,
        'extract-run-84.3-settle: doctored run13 cut -- the check line is NOT in the settle section (prefix separation)');
    like($outA, qr/---\s*\Q$c_check\E[^\n]*\(Anzahl: 1 im Fenster/,
        'extract-run-84.3-settle: doctored run13 cut -- check section header carries (Anzahl: 1 im Fenster');
    like($checkA, qr/context-end check -- settling 02:00:00:5a:11:01 songTime=201\.115 /,
        'extract-run-84.3-settle: doctored run13 cut -- check line printed in its section');
    unlike($checkA, qr/context-end settle/,
        'extract-run-84.3-settle: doctored run13 cut -- the settle line is NOT in the check section (prefix separation)');
    like($stateA, qr/OutputUnderrun in PLAYING-STREAMING -> Slim::Player::StreamingController::_Rebuffer/,
        'extract-run-84.3-settle: doctored run13 cut -- state rows carry the OutputUnderrun -> _Rebuffer row');
    like($stateA, qr/Pause in BUFFERING-STREAMING -> Slim::Player::StreamingController::_NoOp/,
        'extract-run-84.3-settle: doctored run13 cut -- state rows carry the Pause in BUFFERING-STREAMING -> _NoOp row');
    for my $pair ([settle => $settleA], [check => $checkA], ['state rows' => $stateA]) {
        unlike($pair->[1], qr/Spotify told us to pause|D-01\(b\): LMS stop/,
            "extract-run-84.3-settle: doctored run13 cut -- neither `Spotify told us to pause` nor the D-01(b) LMS stop line is in the $pair->[0] section");
    }
    like($outA, qr/---\s*\Q$c_buf\E[^\n]*\(Anzahl: 3 im Fenster[^\n]*KEINE MAC/,
        'extract-run-84.3-settle: doctored run13 cut -- buffering header carries (Anzahl: 3 im Fenster plus the KEINE MAC note');
    my @buf_nonblank = grep { /\S/ } split /\n/, $bufA;
    is(scalar(@buf_nonblank), 3,
        'extract-run-84.3-settle: doctored run13 cut -- the buffering body holds exactly 3 lines (no remainder line, no neighbour)');
    is(scalar(grep { /Buffering\.\.\. 3896 \/ 81920/ } @buf_nonblank), 3,
        'extract-run-84.3-settle: doctored run13 cut -- all three are the real `Buffering... 3896 / 81920` lines');
    like($outA, qr/\Q$c_buf\E[^\n]* ---\n(?:[^\n]*Buffering[^\n]*\n)+\n--- server\.log: 84-26 repairs/,
        'extract-run-84.3-settle: doctored run13 cut -- the buffering body ends at the `--- server.log: 84-26 repairs` header, not at the remainder line');

    # ---- input B ----
    my ($exitB, $outB, $errB) = run_perl_tool($extract_run_script, \@argsB, SUDO_BIN => '/bin/true');
    is($exitB, 0, 'extract-run-84.3-settle: real run8 cut -- SUDO_BIN stub lets the tool run (exit 0)')
        or diag("stderr: $errB");
    my $stateB = $body_of->($outB, $c_state);
    like($stateB, qr/Pause in PLAYING-STREAMING -> Slim::Player::StreamingController::_Pause/,
        'extract-run-84.3-settle: real run8 cut -- state rows carry Pause in PLAYING-STREAMING -> _Pause');
    like($stateB, qr/OutputUnderrun in PAUSED-STREAMING -> Slim::Player::StreamingController::_NoOp/,
        'extract-run-84.3-settle: real run8 cut -- state rows carry OutputUnderrun in PAUSED-STREAMING -> _NoOp');
    unlike($stateB, qr/Spotify told us to pause|D-01\(b\): LMS stop/,
        'extract-run-84.3-settle: real run8 cut -- `Spotify told us to pause` is not in the state-row section');
    like($outB, qr/\[MUSTER NICHT GEFUNDEN IM FENSTER\] \Q$c_buf\E/,
        'extract-run-84.3-settle: real run8 cut -- no buffering lines in the cut reads [MUSTER NICHT GEFUNDEN IM FENSTER]');
    like($outB, qr/\[MUSTER NICHT GEFUNDEN IM FENSTER\] \Q$c_settle\E/,
        'extract-run-84.3-settle: real run8 cut -- pause won, no settle line: [MUSTER NICHT GEFUNDEN IM FENSTER]');

    # ---- throwaway copy WITHOUT the four entries (MUST-FAIL half) ----
    my $dir  = tempdir(CLEANUP => 1);
    my $copy = "$dir/extract-run-without-84.3.pl";
    my $src  = _slurp($extract_run_script);
    my $stripped = $src;
    my $n_strip = ($stripped =~ s/\n[ \t]*\{ name => 'server\.log: (?:Connect: context-end settle|Connect: context-end check|LMS pause\/underrun state rows|LMS buffering progress)[^\n]*\n[ \t]*pat[ \t]*=>[^\n]*\},//g) || 0;
    is($n_strip, 4, 'extract-run-84.3-settle: MUST-FAIL half: the throwaway copy lost exactly the four 84.3 entries')
        or diag('RED: the four entries are not in extract-run.pl (tool unmodified)');
    open(my $ofh, '>', $copy) or die "cannot write $copy: $!";
    print $ofh $stripped;
    close($ofh);
    my ($exitC, $outC) = run_perl_tool($copy, \@argsA, SUDO_BIN => '/bin/true');
    is($exitC, 0, 'extract-run-84.3-settle: MUST-FAIL half: the copy still runs');
    unlike($outC, qr/context-end settle -- LMS discarded|context-end check -- settling|Pause in BUFFERING-STREAMING|Buffering\.\.\. 3896/,
        'extract-run-84.3-settle: MUST-FAIL half: without the entries none of the four line kinds is printed (they fall into the uncategorised counter)');

    unlink($fileA);
};

# ============================================================
# subtest 'extract-run-startoffset-writers' -- 84-21 Task 2 (D-26 instrument
# gap). Connect.pm writes $song->startOffset in places that log nothing
# extract-run.pl could print: the mid-song connect writer (INFO "Stream mode
# mid-song connect: startOffset=") and the change reset (new INFO "Stream mode
# change reset: startOffset="). The seek writer's "adjusted startOffset to"
# line has its own, older category that must NOT be widened (Baseline-Erhalt).
# Test A: both new lines land in the new category. Test B: the seek line stays
# in the old adjust category only. Test C: the old category holds neither new
# line.
# ============================================================
subtest 'extract-run-startoffset-writers' => sub {
    my ($fh, $file) = tempfile();
    print $fh "[26-10-06 12:00:01.0000] Plugins::SpotOn::Connect::_connectEvent (685) Stream mode mid-song connect: startOffset=33\n";
    print $fh "[26-10-06 12:00:02.0000] Plugins::SpotOn::Connect::_connectEvent (2106) Stream mode change reset: startOffset=-12 elapsed=12.340 (aa:bb:cc:dd:ee:01)\n";
    print $fh "[26-10-06 12:00:03.0000] Plugins::SpotOn::Connect::_connectEvent (1268) aa:bb:cc:dd:ee:01: Stream mode seek: adjusted startOffset to 5\n";
    close($fh);

    my ($exit, $stdout, $stderr) = run_perl_tool($extract_run_script,
        [ 'aa:bb:cc:dd:ee:01', '12:00:00', '12:00:10',
          '--server-log', $file, '--date', '2026-10-06' ],
        SUDO_BIN => '/bin/true');
    is($exit, 0, 'extract-run-startoffset-writers: SUDO_BIN-Stub laesst das Werkzeug durchlaufen (Exit 0)')
        or diag("stderr: $stderr");

    my $section_body = sub {
        my ($hdr_re) = @_;
        return ($stdout =~ /---\s*\Q$hdr_re\E.*?---\n(.*?)(?=\n---|\z)/s) ? $1 : '';
    };
    my $writer_body = $section_body->('server.log: Connect startOffset write');
    my $adjust_body = $section_body->('server.log: Connect startOffset adjust');

    like($writer_body, qr/Stream mode mid-song connect: startOffset=33/,
        'extract-run-startoffset-writers: Test A die mid-song-connect-Zeile steht in der Schreiber-Kategorie');
    like($writer_body, qr/Stream mode change reset: startOffset=-12 elapsed=12\.340/,
        'extract-run-startoffset-writers: Test A die change-reset-Zeile steht in der Schreiber-Kategorie');
    unlike($writer_body, qr/adjusted startOffset to/,
        'extract-run-startoffset-writers: Test B die Seek-Zeile steht NICHT in der Schreiber-Kategorie');
    like($adjust_body, qr/Stream mode seek: adjusted startOffset to 5/,
        'extract-run-startoffset-writers: Test B die Seek-Zeile bleibt in der Altkategorie');
    unlike($adjust_body, qr/mid-song connect|change reset/,
        'extract-run-startoffset-writers: Test C die Altkategorie enthaelt keine der beiden neuen Zeilen');

    unlink($file);
};

# ============================================================
# subtest 'extract-run-control-drift-t1' -- 84-21 Task 2 (F-20-LATCH live
# gate). The drift line (Control.pm _reconcile Schritt 5, "daemon does not
# follow play <uri> after N attempts") and the T1 line ("Control: no
# track_changed within N ms") had no category -- a live "drift_lines_in_window=0"
# reading would have read an uncategorised string (only counted, never
# printed; rule 4) and been vacuous. Must-match: each lands in its own section;
# must-NOT-match: not in the other's section, not in the mode-transition one.
# ============================================================
subtest 'extract-run-control-drift-t1' => sub {
    my ($fh, $file) = tempfile();
    print $fh "[26-10-06 12:00:01.0000] Plugins::SpotOn::Soloist::Control::_execute (2625) aa:bb:cc:dd:ee:01: daemon does not follow play spotify:track:1rcIb8sfuxcOsCoLqVaQhw after 2 attempts\n";
    print $fh "[26-10-06 12:00:02.0000] Plugins::SpotOn::Soloist::Control::_t1TrackChanged (2726) Control: no track_changed within 500ms for spotify:track:1rcIb8sfuxcOsCoLqVaQhw (aa:bb:cc:dd:ee:01)\n";
    close($fh);

    my ($exit, $stdout, $stderr) = run_perl_tool($extract_run_script,
        [ 'aa:bb:cc:dd:ee:01', '12:00:00', '12:00:10',
          '--server-log', $file, '--date', '2026-10-06' ],
        SUDO_BIN => '/bin/true');
    is($exit, 0, 'extract-run-control-drift-t1: SUDO_BIN-Stub laesst das Werkzeug durchlaufen (Exit 0)')
        or diag("stderr: $stderr");

    my $section_body = sub {
        my ($hdr_re) = @_;
        return ($stdout =~ /---\s*\Q$hdr_re\E.*?---\n(.*?)(?=\n---|\z)/s) ? $1 : '';
    };
    my $drift_body = $section_body->('server.log: Control drift');
    my $t1_body    = $section_body->('server.log: Control T1');
    my $mode_body  = $section_body->('server.log: Control mode transitions');

    like($drift_body, qr/daemon does not follow play spotify:track:1rcIb8sfuxcOsCoLqVaQhw after 2 attempts/,
        'extract-run-control-drift-t1: Must-Match die Drift-Zeile steht in der Drift-Kategorie');
    like($t1_body, qr/Control: no track_changed within 500ms for spotify:track:1rcIb8sfuxcOsCoLqVaQhw/,
        'extract-run-control-drift-t1: Must-Match die T1-Zeile steht in der T1-Kategorie');
    unlike($drift_body, qr/no track_changed within/,
        'extract-run-control-drift-t1: die T1-Zeile steht NICHT in der Drift-Kategorie');
    unlike($t1_body, qr/does not follow/,
        'extract-run-control-drift-t1: die Drift-Zeile steht NICHT in der T1-Kategorie');
    unlike($mode_body, qr/does not follow|no track_changed within/,
        'extract-run-control-drift-t1: keine der beiden Zeilen faellt in die Modus-Kategorie');

    unlink($file);
};

# ============================================================
# subtest 'extract-run-slimproto-stat' -- 84-23 Task 1 (D-26 attribution
# input). Slim::Networking::Slimproto::_stat_handler logs, at INFO on the
# logger network.protocol.slimproto, one PER-MAC line per STAT frame
# (Slimproto.pm:809-814): `<mac>: STAT-<code>: fullness=N, output_fullness=N,
# elapsed=S`. Without a category the line is only counted, never printed
# (architecture rule 4), so the attribution of LMS_TIME_TRANSIENT / F-18-03
# could not read `elapsed=`. Must-match: the real-form line lands in its own
# section. Must-NOT-match: a plain playerTrackStarted line stays out of it,
# and the heartbeat-close category (84-22) does not take the STAT line.
# ============================================================
subtest 'extract-run-slimproto-stat' => sub {
    my ($fh, $file) = tempfile();
    print $fh "[26-10-06 12:00:05.0000] Slim::Networking::Slimproto::_stat_handler (810) 02:00:00:5a:11:01: STAT-STMt: fullness=123456, output_fullness=78910, elapsed=12.345\n";
    print $fh "[26-10-06 12:00:06.0000] Slim::Player::StreamingController::playerTrackStarted (1234) 02:00:00:5a:11:01: playerTrackStarted\n";
    close($fh);

    my ($exit, $stdout, $stderr) = run_perl_tool($extract_run_script,
        [ '02:00:00:5a:11:01', '12:00:00', '12:00:10',
          '--server-log', $file, '--date', '2026-10-06' ],
        SUDO_BIN => '/bin/true');
    is($exit, 0, 'extract-run-slimproto-stat: SUDO_BIN-Stub laesst das Werkzeug durchlaufen (Exit 0)')
        or diag("stderr: $stderr");

    my $section_body = sub {
        my ($hdr_re) = @_;
        return ($stdout =~ /---\s*\Q$hdr_re\E.*?---\n(.*?)(?=\n---|\z)/s) ? $1 : '';
    };
    my $stat_body = $section_body->('server.log: slimproto STAT');
    my $hb_body   = $section_body->('server.log: Slimproto heartbeat close');

    like($stat_body, qr/02:00:00:5a:11:01: STAT-STMt: fullness=123456, output_fullness=78910, elapsed=12\.345/,
        'extract-run-slimproto-stat: Must-Match die per-MAC-STAT-Zeile steht in der STAT-Kategorie');
    unlike($stat_body, qr/playerTrackStarted/,
        'extract-run-slimproto-stat: Must-NOT-Match die playerTrackStarted-Zeile steht NICHT in der STAT-Kategorie');
    unlike($hb_body, qr/STAT-/,
        'extract-run-slimproto-stat: die STAT-Zeile faellt nicht in die Heartbeat-Close-Kategorie');

    unlink($file);
};

# ============================================================
# subtest 'extract-run-slimproto-heartbeat' -- 84-22 Task 1 (W2, round 2).
# LMS disconnects a player that sends no STAT for 3 x 5 s
# (Slim::Networking::Slimproto::check_all_clients, Slimproto.pm:219-228) and
# logs it only at INFO under network.protocol.slimproto: "Haven't heard from
# <mac> in <n> seconds, closing connection" (Slimproto.pm:224). extract-run.pl
# had no category for it, so every "no heartbeat close" reading of a stall run
# would have read an uncategorised string (only counted, never printed --
# architecture rule 4) and been vacuous. The must-match line is fabricated in
# the sprintf form of Slimproto.pm:224 (no real line exists in any rotated
# server.log: the level was never raised before this plan); must-NOT-match:
# an unrelated playerTrackStarted line and the 84-23 STAT INFO form.
# ============================================================
subtest 'extract-run-slimproto-heartbeat' => sub {
    my ($fh, $file) = tempfile();
    print $fh "[26-10-06 12:00:05.0000] Slim::Networking::Slimproto::check_all_clients (224) Haven't heard from 02:00:00:5a:11:01 in 15 seconds, closing connection\n";
    print $fh "[26-10-06 12:00:06.0000] Slim::Player::StreamingController::playerTrackStarted (2161) 02:00:00:5a:11:01: playerTrackStarted\n";
    print $fh "[26-10-06 12:00:07.0000] Slim::Networking::Slimproto::_stat_handler (1008) 02:00:00:5a:11:01: STAT-STMt: fullness=1, output_fullness=2, elapsed=3.4\n";
    close($fh);

    my ($exit, $stdout, $stderr) = run_perl_tool($extract_run_script,
        [ '02:00:00:5a:11:01', '12:00:00', '12:00:10',
          '--server-log', $file, '--date', '2026-10-06' ],
        SUDO_BIN => '/bin/true');
    is($exit, 0, 'extract-run-slimproto-heartbeat: SUDO_BIN-Stub laesst das Werkzeug durchlaufen (Exit 0)')
        or diag("stderr: $stderr");

    my $hb_body = ($stdout =~ /---\s*\Qserver.log: Slimproto heartbeat close\E.*?---\n(.*?)(?=\n---|\z)/s) ? $1 : '';

    like($hb_body, qr/Haven't heard from 02:00:00:5a:11:01 in 15 seconds, closing connection/,
        'extract-run-slimproto-heartbeat: Must-Match die Heartbeat-Zeile steht in ihrer eigenen Kategorie');
    unlike($hb_body, qr/playerTrackStarted/,
        'extract-run-slimproto-heartbeat: Must-Not-Match die playerTrackStarted-Zeile steht NICHT in der Heartbeat-Kategorie');
    unlike($hb_body, qr/STAT-STMt/,
        'extract-run-slimproto-heartbeat: Must-Not-Match die STAT-INFO-Zeile steht NICHT in der Heartbeat-Kategorie');

    unlink($file);
};

# ============================================================
# subtest 'extract-run-remote-stream-stopped' -- 84-04 Task 2 (B3 instrument).
# cluster2-series.sh browse A4 (the B3 pause -> LMS drops the stream -> resume
# row) reads `A4_STREAM_DROPPED` from the extract (:1770/:1787), but extract-run.pl
# had NO category for LMS' own drop line
#   Slim::Player::StreamingController::_CheckPaused (437/445)
#   "Stopping remote stream upon full buffer when paused (resume time: ...)"
# (logger player.source, INFO: emitted only while player.source is at DEBUG/INFO),
# so the gate could never read `yes` -- 3 of 3 archived readings were `no`.
# The fixture is REAL: the three archived lines 8911 / 105966 / 108837 of
# 84-04-archive/server-261001-full-1601.log (sha256 prefix 47ba8af92c672ea2) with
# their two preceding context lines, MACs kept, nothing synthetic. RED first
# against the unmodified tool; the MUST-FAIL half runs the SAME fixture through a
# throwaway copy of extract-run.pl without the entry (the :1174 pattern).
# ============================================================
subtest 'extract-run-remote-stream-stopped' => sub {
    my $fixture = "$project_dir/t/fixtures/uat/84-04-server-remote-stream-stopped.log";
    ok(-s $fixture, 'extract-run-remote-stream-stopped: real fixture present');
    my $cat = 'server.log: remote stream stopped upon full buffer when paused (StreamingController:437/445)';
    my @args = ('02:00:00:5a:11:01', '08:00:00', '15:00:00', '--server-log', $fixture, '--date', '2026-10-01');

    my ($exit, $stdout, $stderr) = run_perl_tool($extract_run_script, \@args, SUDO_BIN => '/bin/true');
    is($exit, 0, 'extract-run-remote-stream-stopped: SUDO_BIN-Stub laesst das Werkzeug durchlaufen (Exit 0)')
        or diag("stderr: $stderr");
    like($stdout, qr/---\s*\Q$cat\E[^\n]*\(Anzahl: 3 im Fenster/,
        'extract-run-remote-stream-stopped: neue Kategorie traegt (Anzahl: 3 im Fenster');
    my $body = ($stdout =~ /---\s*\Q$cat\E.*?---\n(.*?)(?=\n---|\z)/s) ? $1 : '';
    my $n = () = $body =~ /Stopping remote stream upon full buffer when paused/g;
    is($n, 3, 'extract-run-remote-stream-stopped: alle drei echten Zeilen stehen im Abschnitt der Kategorie');
    like($body, qr/resume time: 121\.802388004303/, 'extract-run-remote-stream-stopped: Zeile 8911 (08:19:08.0156)');
    like($body, qr/resume time: 39\.765515165329/, 'extract-run-remote-stream-stopped: Zeile 105966 (14:26:19.4123)');
    like($body, qr/resume time: 43\.5638671894073/, 'extract-run-remote-stream-stopped: Zeile 108837 (14:45:54.1126)');
    unlike($body, qr/StatusHeartbeat|G4-INSTR|G3-INSTR/,
        'extract-run-remote-stream-stopped: die Kontextzeilen fallen NICHT in die neue Kategorie (Muster nicht zu breit)');

    # MUST-FAIL half: a throwaway copy WITHOUT the entry reads the category absent.
    my $dir = tempdir(CLEANUP => 1);
    my $copy = "$dir/extract-run-without-entry.pl";
    my $src = _slurp($extract_run_script);
    my $stripped = $src;
    $stripped =~ s/\n\s*\{ name => '\Q$cat\E',\s*\n?\s*pat\s*=>\s*qr\/Stopping remote stream upon full buffer when paused\/,\s*count => 1 \},//;
    isnt($stripped, $src, 'extract-run-remote-stream-stopped: MUST-FAIL half: the throwaway copy really lost the entry')
        or diag('the category entry was not found in extract-run.pl (RED: tool unmodified)');
    open(my $ofh, '>', $copy) or die "cannot write $copy: $!";
    print $ofh $stripped;
    close($ofh);
    my ($exit2, $stdout2) = run_perl_tool($copy, \@args, SUDO_BIN => '/bin/true');
    is($exit2, 0, 'extract-run-remote-stream-stopped: MUST-FAIL half: the copy still runs');
    unlike($stdout2, qr/\Q$cat\E/,
        'extract-run-remote-stream-stopped: MUST-FAIL half: without the entry the category is absent (the drop lines fall into the uncategorised counter)');
};

# ============================================================
# subtest 'extract-run-hold' -- 84-17 Task 1 (plan-checker B1/N1/I-c).
# extract-run.pl prints CATEGORISED server.log lines only (uncategorised
# ones are merely counted, architecture rule 4). The 84-17 hold gates read
# lines that had no category: Connect's `Connect: hold opened|closed by|
# skipped`, Control's `Control: boundary reply via=`, and the two escalation
# rungs of a hold, `Control: nachziehen -- reason=` (_connectResync, split-
# brain AND watchdog re-emit) and `Control: connect watchdog -- LMS did not
# re-open` (_watchdogRound2). Without categories a perfect live hold would
# read EMPTY and every "no nachziehen/watchdog line" check would be vacuous.
# Four additive @SRV_CATS entries next to `Track change`.
#
# The fixture lines are in the EXACT format the 84-17 code logs (Control.pm
# _postBoundaryRead callback, Connect.pm change handler / hold) and the two
# pre-existing Control.pm formats. Test A: each section carries its own
# line. Test B: the `Track change: A -> B via=live` line keeps matching the
# unchanged `Track change` category (the appended ` via=<v>` stays inside
# the line). Test C (breadth, plan-checker I-c): the `Track change ... via=`
# line and a `playerTrackStarted` baseline line fall into NONE of the four
# new sections, and the baseline line stays visible in its old category.
# Test D (negative): a second run over a fixture WITHOUT the four lines
# reads `[MUSTER NICHT GEFUNDEN IM FENSTER]` for each of the four sections
# -- the proof that the categories exist (a missing category prints no
# section at all).
#
# SUDO_BIN=/bin/true is REQUIRED (same precedent as extract-run-nextifmore).
# ============================================================
subtest 'extract-run-hold' => sub {
    my $mac = 'aa:bb:cc:dd:ee:01';
    my ($fh, $file) = tempfile();
    print $fh "[26-10-01 09:00:00.1000] Plugins::SpotOn::Soloist::Control::_boundaryReply (3420) Control: boundary reply via=live anchor=drain boundary=75169288 ring_fill=487696 drops=0 ($mac)\n";
    print $fh "[26-10-01 09:00:00.1100] Plugins::SpotOn::Connect::_connectEvent (1730) Track change: 456WNXWhDwYOSf5SpTuqxd -> 6HSXNV0b4M4cLJ7ljgVVeh via=live\n";
    print $fh "[26-10-01 09:00:00.1200] Plugins::SpotOn::Connect::_connectEvent (1800) Connect: hold opened uri=spoton://track:6HSXNV0b4M4cLJ7ljgVVeh cap_at=1790845260 max_at=1790845380 ($mac)\n";
    print $fh "[26-10-01 09:00:05.0000] Plugins::SpotOn::Soloist::Control::_connectResync (4537) Control: nachziehen -- reason=watchdog attempt=1/2 playmode=play observed.status=playing uri=spotify:track:6HSXNV0b4M4cLJ7ljgVVeh ($mac)\n";
    print $fh "[26-10-01 09:00:05.1000] Plugins::SpotOn::Soloist::Control::_watchdogRound2 (1059) Control: connect watchdog -- LMS did not re-open spotify:track:6HSXNV0b4M4cLJ7ljgVVeh within 10s ($mac)\n";
    print $fh "[26-10-01 09:00:06.0000] Plugins::SpotOn::Connect::_onNewSong (870) Connect: hold closed by newsong ($mac)\n";
    print $fh "[26-10-01 09:00:07.0000] Plugins::SpotOn::Connect::_connectEvent (1750) Connect: hold skipped reason=repeat_one ($mac)\n";
    print $fh "[26-10-01 09:00:08.0000] Slim::Player::StreamingController::_eventAction (321) $mac: playerTrackStarted\n";
    close($fh);

    my ($exit, $stdout, $stderr) = run_perl_tool($extract_run_script,
        [ $mac, '08:59:55', '09:00:15', '--server-log', $file, '--date', '2026-10-01' ],
        SUDO_BIN => '/bin/true');
    is($exit, 0, 'extract-run-hold: SUDO-Stub, Exit 0') or diag("stderr: $stderr");

    my $section_body = sub {
        my ($out, $hdr_re) = @_;
        return ($out =~ /---\s*\Q$hdr_re\E.*?---\n(.*?)(?=\n---|\z)/s) ? $1 : '';
    };
    my @new = (
        'server.log: Connect: hold',
        'server.log: Control: boundary reply',
        'server.log: Control: nachziehen',
        'server.log: Control: connect watchdog',
    );
    my ($hold, $reply, $nach, $wd) = map { $section_body->($stdout, $_) } @new;
    my $track  = $section_body->($stdout, 'server.log: Track change');
    my $base   = $section_body->($stdout, 'server.log: playerTrackStarted / playerStopped / new state');

    # Test A
    like($hold,  qr/Connect: hold opened uri=spoton:\/\/track:6HSXNV0b4M4cLJ7ljgVVeh cap_at=\d+ max_at=\d+/,
        'extract-run-hold: Test A `Connect: hold opened` in der Hold-Kategorie');
    like($hold,  qr/Connect: hold closed by newsong/,
        'extract-run-hold: Test A `Connect: hold closed by` in der Hold-Kategorie');
    like($hold,  qr/Connect: hold skipped reason=repeat_one/,
        'extract-run-hold: Test A `Connect: hold skipped` in der Hold-Kategorie');
    like($reply, qr/Control: boundary reply via=live anchor=drain boundary=75169288 ring_fill=487696 drops=0/,
        'extract-run-hold: Test A `Control: boundary reply` in seiner Kategorie');
    like($nach,  qr/Control: nachziehen -- reason=watchdog attempt=1\/2/,
        'extract-run-hold: Test A `Control: nachziehen --` in seiner Kategorie');
    like($wd,    qr/Control: connect watchdog -- LMS did not re-open spotify:track:6HSXNV0b4M4cLJ7ljgVVeh within 10s/,
        'extract-run-hold: Test A `Control: connect watchdog --` in seiner Kategorie');

    # Test B: the via suffix stays inside the unchanged Track change category
    like($track, qr/Track change: 456WNXWhDwYOSf5SpTuqxd -> 6HSXNV0b4M4cLJ7ljgVVeh via=live/,
        'extract-run-hold: Test B die `Track change ... via=live`-Zeile bleibt in der unveraenderten Kategorie');

    # Test C: breadth -- the via line and the baseline line fall into NONE of the four new sections
    for my $i (0 .. 3) {
        my $b = ($hold, $reply, $nach, $wd)[$i];
        unlike($b, qr/Track change: /,
            "extract-run-hold: Test C Track-change-Zeile nicht in Kategorie $new[$i]");
        unlike($b, qr/playerTrackStarted/,
            "extract-run-hold: Test C Baseline-Zeile nicht in Kategorie $new[$i]");
    }
    like($base, qr/playerTrackStarted/,
        'extract-run-hold: Test C Baseline-Zeile bleibt in ihrer Altkategorie sichtbar');
    # and the four kinds stay apart from each other
    unlike($hold,  qr/Control: /, 'extract-run-hold: Test C Hold-Kategorie traegt keine Control-Zeile');
    unlike($reply, qr/Connect: hold|nachziehen|connect watchdog/, 'extract-run-hold: Test C Boundary-reply-Kategorie ist rein');
    unlike($nach,  qr/connect watchdog|boundary reply/, 'extract-run-hold: Test C Nachziehen-Kategorie ist rein');
    unlike($wd,    qr/nachziehen|boundary reply/, 'extract-run-hold: Test C Watchdog-Kategorie ist rein');

    # Test D: a window WITHOUT the four kinds -- the categories exist and read "not found"
    my ($fh2, $file2) = tempfile();
    print $fh2 "[26-10-01 09:00:00.1100] Plugins::SpotOn::Connect::_connectEvent (1730) Track change: 456WNXWhDwYOSf5SpTuqxd -> 6HSXNV0b4M4cLJ7ljgVVeh via=departed\n";
    print $fh2 "[26-10-01 09:00:08.0000] Slim::Player::StreamingController::_eventAction (321) $mac: playerTrackStarted\n";
    close($fh2);
    my ($exit2, $stdout2, $stderr2) = run_perl_tool($extract_run_script,
        [ $mac, '08:59:55', '09:00:15', '--server-log', $file2, '--date', '2026-10-01' ],
        SUDO_BIN => '/bin/true');
    is($exit2, 0, 'extract-run-hold: Negativfixture, Exit 0') or diag("stderr: $stderr2");
    for my $hdr (@new) {
        like($stdout2, qr/\[MUSTER NICHT GEFUNDEN IM FENSTER\] \Q$hdr\E/,
            "extract-run-hold: Test D Kategorie '$hdr' existiert und meldet MUSTER NICHT GEFUNDEN");
    }
    like($stdout2, qr/Track change: 456WNXWhDwYOSf5SpTuqxd -> 6HSXNV0b4M4cLJ7ljgVVeh via=departed/,
        'extract-run-hold: Test D die via=departed-Zeile bleibt in der Track-change-Kategorie');

    unlink($file, $file2);
};

# ============================================================
# subtest 'extract-run-watchdog' -- quick-260923-hgj.
# The watchdog rescue channel (Prefetch-Timer Runde 1, Soloist::Control
# Runde 2) fell into the collective "in keiner Kategorie" bucket -- neither
# rung had a dedicated @SRV_CATS pattern, so the watchdog diagnosis (11
# rings across six server.log generations, 0 forced skips, verified
# 2026-09-23) could only be evidenced via hand-grep, forbidden since
# 10.09. Two additive categories close this gap.
#
# Sources: Plugin.pm:4136 (_prefetchHangCheck, Runde 1, handoff to
# Soloist::Control) and Control.pm:687 (_watchdogRound2, Runde 2, forced
# skip). L1/L3 carry the six-byte sequence \xc3\xa2\xc2\x80\xc2\x94 for the
# em dash -- server.log stores it double-encoded (the tool reads bytes with
# no encoding layer, so a pure-ASCII pattern with a literal dash character
# would silently match nothing).
#
# L4 is a deliberate negative: _recordErrorOnce (Control.pm:3086) is a
# SECOND sender of the round-2 wording ("<mac>: watchdog forced skip
# (round 2: ...)"); the Runde-2 pattern is anchored on "Control: watchdog
# forced skip on " so only the :687 line is caught (one hit per event, Z05
# / Z09). L3 is the sibling negative: Plugin.pm:4140 ("... forcing skip",
# player without a Control instance) stays out of the Runde-1 category
# (Z06) and remains in the collective bucket -- it is deliberately not
# covered here.
#
# SUDO_BIN=/bin/true is REQUIRED -- without the stub, extract-run.pl's
# unconditional sudo -n gate at main() aborts before reading --server-log
# at all (same precedent as 'extract-run-nextifmore' above).
# ============================================================
subtest 'extract-run-watchdog' => sub {
    my ($fh, $file) = tempfile();
    print $fh "[26-09-12 12:00:01.0000] Plugins::SpotOn::Plugin::_prefetchHangCheck (4136) Prefetch watchdog: still on same track after 10s past end \xc3\xa2\xc2\x80\xc2\x94 handing to Soloist::Control (D-02)\n";
    print $fh "[26-09-12 12:00:02.0000] Plugins::SpotOn::Soloist::Control::_watchdogRound2 (687) Control: watchdog forced skip on aa:bb:cc:dd:ee:01 (round 2: unknown)\n";
    print $fh "[26-09-12 12:00:03.0000] Plugins::SpotOn::Plugin::_prefetchHangCheck (4140) Prefetch watchdog: still on same track after 10s past end \xc3\xa2\xc2\x80\xc2\x94 forcing skip\n";
    print $fh "[26-09-12 12:00:04.0000] Plugins::SpotOn::Soloist::Control::_recordErrorOnce (3086) aa:bb:cc:dd:ee:01: watchdog forced skip (round 2: unknown)\n";
    print $fh "[26-09-12 12:00:05.0000] Slim::Player::StreamingController::_eventAction (321) aa:bb:cc:dd:ee:01: playerTrackStarted\n";
    close($fh);

    my ($exit, $stdout, $stderr) = run_perl_tool($extract_run_script,
        [ 'aa:bb:cc:dd:ee:01', '12:00:00', '12:00:10',
          '--server-log', $file, '--date', '2026-09-12' ],
        SUDO_BIN => '/bin/true');

    my $section_body = sub {
        my ($hdr_re) = @_;
        return ($stdout =~ /---\s*\Q$hdr_re\E.*?---\n(.*?)(?=\n---|\z)/s) ? $1 : '';
    };

    my $round1_body   = $section_body->('server.log: Prefetch watchdog -> Soloist::Control');
    my $round2_body   = $section_body->('server.log: Control: watchdog forced skip');
    my $baseline_body = $section_body->('server.log: playerTrackStarted / playerStopped / new state');

    is($exit, 0, 'extract-run-watchdog: Z01 SUDO_BIN-Stub laesst das Werkzeug normal durchlaufen (Exit 0)')
        or diag("stderr: $stderr");

    like($round1_body, qr/handing to Soloist::Control \(D-02\)/,
        'extract-run-watchdog: Z02 Test A Runde-1-Zeile erscheint in der neuen Uebergabe-Kategorie');
    like($stdout, qr/^--- server\.log: Prefetch watchdog -> Soloist::Control[^\n]*\(Anzahl: 1 im Fenster/m,
        'extract-run-watchdog: Z03 Runde-1-Kopfzeile traegt Anzahl 1 (count => 1)');

    like($round2_body, qr/Control: watchdog forced skip on aa:bb:cc:dd:ee:01 \(round 2: unknown\)/,
        'extract-run-watchdog: Z04 Test B Runde-2-Zeile erscheint in der neuen Kategorie');
    like($stdout, qr/^--- server\.log: Control: watchdog forced skip[^\n]*\(Anzahl: 1 im Fenster/m,
        'extract-run-watchdog: Z05 Runde-2-Kopfzeile traegt Anzahl 1 -- genau EIN Treffer trotz Echozeile L4');

    unlike($round1_body, qr/forcing skip/,
        'extract-run-watchdog: Z06 Test C Geschwisterzeile Plugin.pm:4140 bleibt draussen');
    unlike($round1_body, qr/forced skip/,
        'extract-run-watchdog: Z07 Runde-2-Wortlaut nicht in der Runde-1-Kategorie');
    unlike($round2_body, qr/Prefetch watchdog/,
        'extract-run-watchdog: Z08 Runde-1-Wortlaut nicht in der Runde-2-Kategorie');
    unlike($round2_body, qr/ee:01: watchdog forced skip \(round 2/,
        'extract-run-watchdog: Z09 Test C Echozeile L4 (_recordErrorOnce) bleibt draussen');

    like($baseline_body, qr/playerTrackStarted\n/,
        'extract-run-watchdog: Z10 Altkategorie unveraendert (Baseline-Erhalt)');
    unlike($round1_body, qr/playerTrackStarted/,
        'extract-run-watchdog: Z11 Altkategorie-Zeile faellt nicht in die Runde-1-Kategorie');
    unlike($round2_body, qr/playerTrackStarted/,
        'extract-run-watchdog: Z12 Altkategorie-Zeile faellt nicht in die Runde-2-Kategorie');

    like($stdout, qr/von den Fensterzeilen 2 in keiner Kategorie/,
        'extract-run-watchdog: Z13 Restzaehler-Arithmetik -- 5 Zeilen, 3 kategorisiert, 2 im Topf');
    unlike($stdout, qr/Restzaehler-Selbsttest[^\n]*FEHLGESCHLAGEN/,
        'extract-run-watchdog: Z14 Restzaehler-Selbsttest bleibt stumm');

    unlink($file);
};

# ============================================================
# subtest 'extract-run-daemon-ticker-format' -- 84.1 plan 05, Task 3
# deviation (user-authorised: "Erst Werkzeug reparieren"). The current
# Soloist daemon build writes its ticker lines WITHOUT a date and with a
# level/[f:N] infix ("HH:MM:SS.mmm I [f:N ...] playing ..." plus a trailing
# ANSI reset "\e[0m") -- parse_line()'s daemon branch discarded this form as
# 'unrecognized', so 'Daemon-Log: Ticker (playing/paused/stopped)' (and every
# other daemon category) silently stopped matching for 482882 of 489719
# lines of /var/lib/squeezeboxserver/cache/spoton/0200005a1101-soloist.log
# in the 84.1-05 260928-2100 run (counted via `command grep -c`, recorded in
# the plan-05 continuation dispatch). All three raw lines below are copied
# VERBATIM from that file, not synthesized.
#
# Test A (new format, IN the window): the target line's dateless clock
# reading 19:35:19.482 is UTC, not local -- measured by correlating the
# 260928 run's A2 scenario (meta.txt A2_FIRST_RISE=90.0 at local epoch
# 1790622094 = Mo 2026-09-28 21:01:34 CEST) against the daemon line
# "19:01:34.482 ... [1:30 / 4:55]" (1:30 = 90s, and 19:01:34 UTC + 2h CEST
# offset = 21:01:34 local) -- see resolve_dateless_utc()'s header comment in
# extract-run.pl for the full evidence and the second, independent line
# pair. Local equivalent of THIS test's target (Europe/Berlin, CEST that
# day, +2h): 21:35:19.482. The window below (--date 2026-09-28, local
# 21:35:15..21:35:25) must resolve the dateless UTC line onto that local
# day/time and categorise it as Ticker.
#
# Test B (new format, OUTSIDE the window): a second real line from the SAME
# daemon log, 40s earlier UTC (19:34:39.482 -> local 21:34:39, well before
# the window's padded start 21:35:13) -- must NOT appear anywhere in stdout.
# A window that leaked a line from outside its own bounds would be the more
# dangerous failure than missing one inside it.
#
# Test C (old format, regression / Baseline-Erhalt): a real line in the
# daemon log's older, dated format ("YYYY-MM-DD HH:MM:SS.mmm: playing ...",
# no ANSI, no [f:N] infix) must still be categorised exactly as before --
# this plan's fix is additive (a new elsif branch plus an alternation in the
# Ticker pattern), it must never touch the dated-line path.
# ============================================================
subtest 'extract-run-daemon-ticker-format' => sub {
    my $stubdir   = tempdir(CLEANUP => 1);
    my $sudo_stub = write_sudo_passthrough_stub($stubdir);

    my ($sfh, $server_log) = tempfile();
    close($sfh);   # leer -- dieser Subtest gilt ausschliesslich dem Daemon-Log

    my $section_body = sub {
        my ($out, $hdr_re) = @_;
        return ($out =~ /---\s*\Q$hdr_re\E.*?---\n(.*?)(?=\n---|\z)/s) ? $1 : '';
    };

    # -- Test A + B: neues, datumsloses Format ---------------------------
    my ($dfh1, $daemon_log_new) = tempfile();
    print $dfh1 "19:34:39.482 I [f:77                            ] playing spotify:track:6md4w95cnKaW64JyEQ3A0L \"Somebody That I Used To Know\" by \"Gotye\" [1:54 / 4:04]\e[0m\n";
    print $dfh1 "19:35:19.482 I [f:77                            ] playing spotify:track:6md4w95cnKaW64JyEQ3A0L \"Somebody That I Used To Know\" by \"Gotye\" [2:40 / 4:04]\e[0m\n";
    close($dfh1);

    # WR-12 (84.1-REVIEW.md round 3): resolve_dateless_utc() converts with
    # localtime(), i.e. the CHILD PROCESS's timezone -- the expected local
    # clock below (21:35) is CEST (+2h), so it must be pinned explicitly
    # rather than inherited from whatever TZ the test host/CI runner has.
    # GitHub-hosted runners default to UTC (.github/workflows/perl-tests.yml),
    # which turned this subtest red on the first push that carried it.
    my ($exit1, $stdout1, $stderr1) = run_perl_tool($extract_run_script,
        [ 'aa:bb:cc:dd:ee:01', '21:35:15', '21:35:25',
          '--server-log', $server_log, '--daemon-log', $daemon_log_new,
          '--date', '2026-09-28' ],
        SUDO_BIN => $sudo_stub, TZ => 'Europe/Berlin');
    is($exit1, 0, 'extract-run-daemon-ticker-format: neues Format, Exit 0')
        or diag("stderr: $stderr1");

    my $ticker_body1 = $section_body->($stdout1, 'Daemon-Log: Ticker');
    like($ticker_body1, qr/\[2:40 \/ 4:04\]/,
        'extract-run-daemon-ticker-format: Test A neues Format (datumslos, UTC, ANSI) wird als Ticker kategorisiert');
    unlike($stdout1, qr/\[1:54 \/ 4:04\]/,
        'extract-run-daemon-ticker-format: Test B die 40s vor dem Fenster liegende Zeile erscheint NIRGENDS');

    # WR-11 (84.1-REVIEW.md round 3): the rendered line must carry its
    # already-converted local clock, visibly marked as converted -- not the
    # raw UTC clock silently sitting inside an otherwise-local block.
    like($ticker_body1, qr/^\[UTC->lokal 21:35:19\.482\] 19:35:19\.482 /m,
        'extract-run-daemon-ticker-format: Test A wird mit [UTC->lokal ...]-Markierung gerendert (WR-11)');

    # -- Test C: altes, datiertes Format (Baseline-Erhalt) ---------------
    my ($dfh2, $daemon_log_old) = tempfile();
    print $dfh2 "2026-09-07 07:58:08.892: playing spotify:track:4PTG3Z6ehGkBFwjybzWkR8 \"Never Gonna Give You Up\" by \"Rick Astley\" [3:34 / 3:34]\n";
    close($dfh2);

    # Test C's format is dated (no dateless-UTC path involved), so TZ does
    # not change its outcome -- pinned anyway for symmetry with Test A/B.
    my ($exit2, $stdout2, $stderr2) = run_perl_tool($extract_run_script,
        [ 'aa:bb:cc:dd:ee:01', '07:58:06', '07:58:11',
          '--server-log', $server_log, '--daemon-log', $daemon_log_old,
          '--date', '2026-09-07' ],
        SUDO_BIN => $sudo_stub, TZ => 'Europe/Berlin');
    is($exit2, 0, 'extract-run-daemon-ticker-format: altes Format, Exit 0')
        or diag("stderr: $stderr2");

    my $ticker_body2 = $section_body->($stdout2, 'Daemon-Log: Ticker');
    like($ticker_body2, qr/\[3:34 \/ 3:34\]/,
        'extract-run-daemon-ticker-format: Test C altes, datiertes Format bleibt unveraendert kategorisiert (Baseline-Erhalt)');
    unlike($ticker_body2, qr/\[UTC->lokal/,
        'extract-run-daemon-ticker-format: Test C altes, datiertes Format bekommt KEINE [UTC->lokal ...]-Markierung (WR-11 betrifft nur das neue Format)');

    unlink($server_log, $daemon_log_new, $daemon_log_old);
};

# ============================================================
# subtest 'extract-run-autoplay-request' -- 84.2 plan 03, Task 1 (CAUSE-1,
# D-11). The daemon writes ONE line per context end that names the account's
# Autoplay setting: "autoplay: requesting autoplay context from no request"
# (Autoplay OFF) or "... from hm://context-resolve/v1/autoplay" (ON). The
# runner's per-row classifier (_autoplay_gates.py setting) reads that line
# from the extract -- without a category it is only counted, never printed
# (rule 4), and the classifier would read every row as `unreadable`.
# Line forms copied from the real archive (84-19-spike-autoplay-261004/
# off-1/daemon-window.txt :100/:101/:4697, 84-26-b7-run-261007-164216/
# daemon-window.txt :337): the dateless UTC form with the [f:N] infix and the
# trailing ANSI reset. The two siblings (`routing for ...` and `request
# successful with 50 tracks`) carry "autoplay:" too and must stay OUT of the
# category -- they appear in both settings and would void the classifier.
# Window: 06:37:4x UTC = 08:37:4x local (CEST, +2h) on 2026-10-09.
# ============================================================
subtest 'extract-run-autoplay-request' => sub {
    my $stubdir   = tempdir(CLEANUP => 1);
    my $sudo_stub = write_sudo_passthrough_stub($stubdir);

    my ($sfh, $server_log) = tempfile();
    close($sfh);

    my ($dfh, $daemon_log) = tempfile();
    print $dfh "06:37:41.100 I [f:193                           ] autoplay: requesting autoplay context from no request\e[0m\n";
    print $dfh "06:37:42.200 I [f:193                           ] autoplay: requesting autoplay context from hm://context-resolve/v1/autoplay\e[0m\n";
    print $dfh "06:37:42.200 I [f:172                           ] autoplay: routing for spotify:track:2374M0fQpWi3dLnB54qaLX - endpoint=music is_video=false\e[0m\n";
    print $dfh "06:37:42.450 I [f:239                           ] autoplay: request successful with 50 tracks\e[0m\n";
    close($dfh);

    my ($exit, $stdout, $stderr) = run_perl_tool($extract_run_script,
        [ 'aa:bb:cc:dd:ee:01', '08:37:40', '08:37:46',
          '--server-log', $server_log, '--daemon-log', $daemon_log,
          '--date', '2026-10-09' ],
        SUDO_BIN => $sudo_stub, TZ => 'Europe/Berlin');
    is($exit, 0, 'extract-run-autoplay-request: Exit 0') or diag("stderr: $stderr");

    my $body = ($stdout =~ /---\s*\QDaemon-Log: autoplay request\E.*?---\n(.*?)(?=\n---|\z)/s) ? $1 : '';
    like($stdout, qr/^--- Daemon-Log: autoplay request[^\n]*\(Anzahl: 2 im Fenster/m,
        'extract-run-autoplay-request: category header carries Anzahl 2 (count => 1)');
    like($body, qr/requesting autoplay context from no request/,
        'extract-run-autoplay-request: the OFF line ("from no request") is in the category body');
    like($body, qr/requesting autoplay context from hm:\/\/context-resolve\/v1\/autoplay/,
        'extract-run-autoplay-request: the ON line (hm://context-resolve) is in the category body');
    unlike($body, qr/routing for spotify:track/,
        'extract-run-autoplay-request: the sibling `routing for` line stays out');
    unlike($body, qr/request successful with 50 tracks/,
        'extract-run-autoplay-request: the sibling `request successful` line stays out');
    unlike($stdout, qr/Restzaehler-Selbsttest[^\n]*FEHLGESCHLAGEN/,
        'extract-run-autoplay-request: Restzaehler self-test stays silent');

    unlink($server_log, $daemon_log);
};

# ============================================================
# subtest 'extract-run-79-38-hold' -- 79-38 Task 1 (79 D-31). The 79-37 shim
# writes its gap-hold lines as `[fakepulse BOUNDARY ts=HH:MM:SS.mmm] <line>`:
# hold_armed, hold_consumed, hold_released reason=<...>, hold_suppressed,
# hold_skipped, and the close of a held boundary as boundary_reached.
# Without a category they are only counted, never printed (rule 4), so the
# gate runners/boundary-gate.sh (held line needs its boundary_reached) and
# runners/resume-gate.sh could not read them from the extract.
# REAL in this fixture: the boundary_planted line (79-31 live run, UAT daemon
# log 2026-10-23 12:03:32.864) and the boundary_reached line (same run,
# 0200005a1101-soloist.log:66146). SYNTHETIC: hold_armed, hold_consumed,
# hold_released reason=timeout, hold_suppressed, hold_skipped (79-37 shim
# format, fake-libpulse.c:1210/1664/1042/1903/1214) and the write_summary
# line, which must stay OUT of the new category. The file carries its data
# inline and never reads spoton-messdaten or /var/log.
# ============================================================
subtest 'extract-run-79-38-hold' => sub {
    my $stubdir   = tempdir(CLEANUP => 1);
    my $sudo_stub = write_sudo_passthrough_stub($stubdir);

    my ($sfh, $server_log) = tempfile();
    close($sfh);

    my ($dfh, $daemon_log) = tempfile();
    print $dfh "[fakepulse BOUNDARY ts=12:03:29.800] hold_armed: at=18070168 gap_ms=3012 gen=2\n";
    print $dfh "[fakepulse BOUNDARY ts=12:03:32.864] hold_consumed: at=18070168 held_ms=3 withheld=57344\n";
    print $dfh "[fakepulse BOUNDARY ts=12:03:32.864] boundary_planted: total_pushed=18127512 ring_fill=561424 gen=2 via=live anchor=popped seek_arm_reset\n";
    print $dfh "[fakepulse BOUNDARY ts=12:03:32.864] boundary_reached: closing client fd=45 wrote=0 total_popped=18127512 boundary=18127512 trimmed=0\n";
    print $dfh "[fakepulse BOUNDARY ts=12:03:34.100] hold_released: reason=timeout at=18127512 held_ms=450 withheld=8192\n";
    print $dfh "[fakepulse BOUNDARY ts=12:03:35.200] hold_suppressed: window_ms=450\n";
    print $dfh "[fakepulse BOUNDARY ts=12:03:36.300] hold_skipped: reason=suppressed gap_ms=3001\n";
    print $dfh "[fakepulse BOUNDARY ts=12:03:37.000] write_summary: bytes_written=1 ring_fill=0 calls=1 bytes_since=1 corked=0\n";
    close($dfh);

    my ($exit, $stdout, $stderr) = run_perl_tool($extract_run_script,
        [ 'aa:bb:cc:dd:ee:01', '12:03:00', '12:04:00',
          '--server-log', $server_log, '--daemon-log', $daemon_log,
          '--date', '2026-10-23' ],
        SUDO_BIN => $sudo_stub, TZ => 'Europe/Berlin');
    is($exit, 0, 'extract-run-79-38-hold: Exit 0') or diag("stderr: $stderr");

    my $body = ($stdout =~ /^--- Daemon-Log: gap hold[^\n]*---\n(.*?)(?=\n---|\z)/ms) ? $1 : '';
    like($stdout, qr/^--- Daemon-Log: gap hold[^\n]*\(Anzahl: 6 im Fenster/m,
        'extract-run-79-38-hold: category header carries Anzahl 6 (count => 1)');
    for my $kw (qw(hold_armed hold_consumed boundary_reached hold_suppressed hold_skipped)) {
        like($body, qr/\] \Q$kw\E: /,
            "extract-run-79-38-hold: the $kw line is in the gap-hold body");
    }
    like($body, qr/hold_released: reason=timeout at=18127512 held_ms=450/,
        'extract-run-79-38-hold: the hold_released reason=timeout line is in the gap-hold body');
    like($body, qr/boundary_reached: closing client fd=45 wrote=0 total_popped=18127512 boundary=18127512 trimmed=0/,
        'extract-run-79-38-hold: the real boundary_reached line is verbatim');
    unlike($body, qr/boundary_planted:/,
        'extract-run-79-38-hold: the boundary_planted line stays out of the gap-hold category');
    unlike($body, qr/write_summary:/,
        'extract-run-79-38-hold: a write_summary line stays out of the gap-hold category');
    my $planted = ($stdout =~ /^--- Daemon-Log: seek_arm \/ seek_arm_expired \/ boundary_planted[^\n]*---\n(.*?)(?=\n---|\z)/ms) ? $1 : '';
    like($planted, qr/boundary_planted: total_pushed=18127512 ring_fill=561424 gen=2 via=live anchor=popped/,
        'extract-run-79-38-hold: the boundary_planted line is in its own category');
    unlike($stdout, qr/Restzaehler-Selbsttest[^\n]*FEHLGESCHLAGEN/,
        'extract-run-79-38-hold: Restzaehler self-test stays silent');

    unlink($server_log, $daemon_log);
};

# ============================================================
# subtest 'extract-run-79-50-decide' -- 79-50 Task 2 (D-34 R2). The 79-47 shim
# writes `flush-keep:` / `browse-keep:` (and their BOUNDARY twins `flush_keep:` /
# `browse_keep:`), and since 79-50 the decision window writes `flush-decide:
# open|closed reason=<boundary|deadline>` and `seek-keep: kept|nothing pending`
# (BOUNDARY twins `flush_decide:` / `seek_keep:`). Under architecture rule 4 a
# line without a category is only counted, never printed, so the live checks of
# 79-50 Task 4 (d50-check.py, `seek-keep: kept` / `flush-decide: closed reason=`)
# could not quote them. One category prints all of them.
# REAL in this fixture: the four 79-47 lines, copied from the UAT daemon log of
# the 79-47 R1 window (/var/lib/squeezeboxserver/cache/spoton/0200005a1101-soloist.log
# lines 11035/11036 (browse-keep 0 -> 1) and 11078/11079 (flush-keep, 2026-10-26
# 17:51:48 / 17:52:05; the one bootstrap raw read of 79-50 Task 2, recorded as
# BOOTSTRAP_RAW_READ in 79-50-DEVRUN.md). SYNTHETIC: the 79-50 lines, in the
# format of fake-libpulse.c's flush-decide / seek-keep writers, and a write_summary
# line, which must stay OUT. The file carries its data inline.
# ============================================================
subtest 'extract-run-79-50-decide' => sub {
    my $stubdir   = tempdir(CLEANUP => 1);
    my $sudo_stub = write_sudo_passthrough_stub($stubdir);

    my ($sfh, $server_log) = tempfile();
    close($sfh);

    my ($dfh, $daemon_log) = tempfile();
    print $dfh "[fakepulse 17:51:48.702] browse-keep: 0 -> 1\n";
    print $dfh "[fakepulse BOUNDARY ts=17:51:48.702] browse_keep: 0 -> 1\n";
    print $dfh "[fakepulse 17:52:05.610] flush-keep: browse keep set, active HTTP client stays\n";
    print $dfh "[fakepulse BOUNDARY ts=17:52:05.610] flush_keep: browse keep set, no flush-disconnect\n";
    print $dfh "[fakepulse 17:52:06.000] flush-decide: open window_ms=2000\n";
    print $dfh "[fakepulse BOUNDARY ts=17:52:06.000] flush_decide: open window_ms=2000\n";
    print $dfh "[fakepulse 17:52:06.020] seek-keep: kept active HTTP client after_ms=20\n";
    print $dfh "[fakepulse BOUNDARY ts=17:52:06.020] seek_keep: kept after_ms=20\n";
    print $dfh "[fakepulse 17:52:09.000] flush-decide: closed reason=boundary after_ms=6\n";
    print $dfh "[fakepulse BOUNDARY ts=17:52:09.000] flush_decide: closed reason=boundary after_ms=6\n";
    print $dfh "[fakepulse 17:52:10.000] seek-keep: nothing pending\n";
    print $dfh "[fakepulse BOUNDARY ts=17:52:10.000] seek_keep: noop reason=none\n";
    print $dfh "[fakepulse BOUNDARY ts=17:52:11.000] write_summary: bytes_written=1 ring_fill=0 calls=1 bytes_since=1 corked=0\n";
    close($dfh);

    my ($exit, $stdout, $stderr) = run_perl_tool($extract_run_script,
        [ 'aa:bb:cc:dd:ee:01', '17:51:00', '17:53:00',
          '--server-log', $server_log, '--daemon-log', $daemon_log,
          '--date', '2026-10-26' ],
        SUDO_BIN => $sudo_stub, TZ => 'Europe/Berlin');
    is($exit, 0, 'extract-run-79-50-decide: Exit 0') or diag("stderr: $stderr");

    my $body = ($stdout =~ /^--- Daemon-Log: connect decision and keeps[^\n]*---\n(.*?)(?=\n---|\z)/ms) ? $1 : '';
    like($stdout, qr/^--- Daemon-Log: connect decision and keeps[^\n]*\(Anzahl: 12 im Fenster/m,
        'extract-run-79-50-decide: category header carries Anzahl 12 (count => 1)');
    like($body, qr/\] flush-decide: open window_ms=2000/,        'extract-run-79-50-decide: the flush-decide open line is in the body');
    like($body, qr/\] flush-decide: closed reason=boundary after_ms=6/, 'extract-run-79-50-decide: the flush-decide closed line (reason=boundary) is in the body');
    like($body, qr/\] seek-keep: kept active HTTP client after_ms=20/,  'extract-run-79-50-decide: the seek-keep kept line is in the body');
    like($body, qr/\] seek-keep: nothing pending/,                'extract-run-79-50-decide: the seek-keep nothing-pending line is in the body');
    like($body, qr/\] seek_keep: kept after_ms=20/,               'extract-run-79-50-decide: the BOUNDARY twin seek_keep line is in the body');
    like($body, qr/\] flush_decide: closed reason=boundary after_ms=6/, 'extract-run-79-50-decide: the BOUNDARY twin flush_decide line is in the body');
    like($body, qr/\] flush-keep: browse keep set, active HTTP client stays/, 'extract-run-79-50-decide: the real 79-47 flush-keep line is verbatim');
    like($body, qr/\] flush_keep: browse keep set, no flush-disconnect/,      'extract-run-79-50-decide: the real 79-47 flush_keep twin is verbatim');
    like($body, qr/\] browse-keep: 0 -> 1/,                       'extract-run-79-50-decide: the real 79-47 browse-keep line is verbatim');
    like($body, qr/\] browse_keep: 0 -> 1/,                       'extract-run-79-50-decide: the real 79-47 browse_keep twin is verbatim');
    unlike($body, qr/write_summary:/,                             'extract-run-79-50-decide: a write_summary line stays out of the category');
    unlike($stdout, qr/Restzaehler-Selbsttest[^\n]*FEHLGESCHLAGEN/,
        'extract-run-79-50-decide: Restzaehler self-test stays silent');

    unlink($server_log, $daemon_log);
};

# ============================================================
# subtest 'extract-run-79-51-discard' -- 79-51 Task 2 (runaway D2). The shim's drain loop writes
# `boundary_discarded: stale generation (planted_gen=.. current_gen=..) total_popped=.. boundary=..` when a
# marker planted for a departed client meets the next client, and since 79-51 the promotion block writes
# `boundary_discarded: orphan at attach (planted_gen=-1 current_gen=..) total_popped=.. boundary=..` (an orphan
# marker at or below total_popped, E4/E5). Under architecture rule 4 a line without a category is only counted,
# never printed, so the live checks of 79-51 Task 4 could not quote them. One category prints both.
# REAL in this fixture: the two stale-generation lines, copied from the UAT daemon log
# (/var/lib/squeezeboxserver/cache/spoton/0200005a1101-soloist.log lines 16841 (09:13:43.057) and 22251
# (09:36:17.617); the one bootstrap raw read of 79-51 Task 2, recorded as BOOTSTRAP_RAW_READ in 79-51-DEVRUN.md).
# SYNTHETIC: the orphan-at-attach line, in the format of fake-libpulse.c's writer, and a write_summary line,
# which must stay OUT. The file carries its data inline.
# ============================================================
subtest 'extract-run-79-51-discard' => sub {
    my $stubdir   = tempdir(CLEANUP => 1);
    my $sudo_stub = write_sudo_passthrough_stub($stubdir);

    my ($sfh, $server_log) = tempfile();
    close($sfh);

    my ($dfh, $daemon_log) = tempfile();
    print $dfh "[fakepulse BOUNDARY ts=09:13:43.057] boundary_discarded: stale generation (planted_gen=12 current_gen=13) total_popped=118898688 boundary=118890496\n";
    print $dfh "[fakepulse BOUNDARY ts=09:36:17.617] boundary_discarded: stale generation (planted_gen=5 current_gen=6) total_popped=45268992 boundary=45260800\n";
    print $dfh "[fakepulse BOUNDARY ts=09:42:25.338] boundary_discarded: orphan at attach (planted_gen=-1 current_gen=16) total_popped=130643728 boundary=130643728\n";
    print $dfh "[fakepulse BOUNDARY ts=09:42:26.000] write_summary: bytes_written=1 ring_fill=0 calls=1 bytes_since=1 corked=0\n";
    close($dfh);

    my ($exit, $stdout, $stderr) = run_perl_tool($extract_run_script,
        [ 'aa:bb:cc:dd:ee:01', '09:00:00', '09:50:00',
          '--server-log', $server_log, '--daemon-log', $daemon_log,
          '--date', '2026-10-27' ],
        SUDO_BIN => $sudo_stub, TZ => 'Europe/Berlin');
    is($exit, 0, 'extract-run-79-51-discard: Exit 0') or diag("stderr: $stderr");

    my $body = ($stdout =~ /^--- Daemon-Log: boundary discarded[^\n]*---\n(.*?)(?=\n---|\z)/ms) ? $1 : '';
    like($stdout, qr/^--- Daemon-Log: boundary discarded[^\n]*\(Anzahl: 3 im Fenster/m,
        'extract-run-79-51-discard: category header carries Anzahl 3 (count => 1)');
    like($body, qr/\] boundary_discarded: stale generation \(planted_gen=12 current_gen=13\) total_popped=118898688 boundary=118890496/,
        'extract-run-79-51-discard: the real 09:13:43.057 stale-generation line is verbatim');
    like($body, qr/\] boundary_discarded: stale generation \(planted_gen=5 current_gen=6\) total_popped=45268992 boundary=45260800/,
        'extract-run-79-51-discard: the real 09:36:17.617 stale-generation line is verbatim');
    like($body, qr/\] boundary_discarded: orphan at attach \(planted_gen=-1 current_gen=16\) total_popped=130643728 boundary=130643728/,
        'extract-run-79-51-discard: the orphan-at-attach line is in the body');
    unlike($body, qr/write_summary:/, 'extract-run-79-51-discard: a write_summary line stays out of the category');
    unlike($stdout, qr/Restzaehler-Selbsttest[^\n]*FEHLGESCHLAGEN/,
        'extract-run-79-51-discard: Restzaehler self-test stays silent');

    unlink($server_log, $daemon_log);
};

# ============================================================
# subtest 'extract-run-dateless-utc-day-boundary' -- 84.1-REVIEW.md round 3,
# WR-09. resolve_dateless_utc() picked its candidate day by asking "does the
# time-of-day fall inside the (local) window?" -- but time-of-day is
# identical on every candidate day, so the FIRST candidate tried (delta=0,
# i.e. the UTC day matching --date) always wins whenever the clock fits the
# window at all. For a UTC clock >= 22:00 CEST-local-midnight, delta=0's
# local day is the day AFTER --date, so the line was returned with the
# WRONG day and scan_log's day filter (extract-run.pl:659) then drops it
# into day_filtered -- silently missing from every category.
#
# Test A (RED before the fix, GREEN after): a real-shaped fixture line
# stamped "22:30:00.000" UTC (2026-09-27 22:30 UTC = 2026-09-28 00:30 CEST)
# with --date 2026-09-28 and a window 00:29:00..00:31:00 local (padded to
# 00:28:58..00:31:05) -- exactly the near-midnight case the function's own
# header comment claims to cover. Must be categorised as Ticker, and the
# Restzaehler line for Daemon-Log must show "0 vom Tagesfilter verworfen".
#
# Test B (regression guard, green both before and after): the existing
# same-day case (no day-boundary crossing) must keep resolving correctly --
# reuses the Test-A fixture shape from 'extract-run-daemon-ticker-format'
# above (19:35:19.482 UTC -> 21:35:19.482 CEST, same calendar day).
#
# Both pin TZ => 'Europe/Berlin' (WR-12): resolve_dateless_utc() converts
# with localtime(), i.e. the child process's timezone.
# ============================================================
subtest 'extract-run-dateless-utc-day-boundary' => sub {
    my $stubdir   = tempdir(CLEANUP => 1);
    my $sudo_stub = write_sudo_passthrough_stub($stubdir);

    my $section_body = sub {
        my ($out, $hdr_re) = @_;
        return ($out =~ /---\s*\Q$hdr_re\E.*?---\n(.*?)(?=\n---|\z)/s) ? $1 : '';
    };

    # -- Test A: near-midnight day-boundary case (the WR-09 repro) -------
    my ($sfh, $server_log) = tempfile();
    close($sfh);

    my ($dfh, $daemon_log) = tempfile();
    print $dfh "22:30:00.000 I [f:77                            ] playing spotify:track:6md4w95cnKaW64JyEQ3A0L \"Somebody That I Used To Know\" by \"Gotye\" [0:05 / 4:04]\e[0m\n";
    close($dfh);

    my ($exit, $stdout, $stderr) = run_perl_tool($extract_run_script,
        [ 'aa:bb:cc:dd:ee:01', '00:29:00', '00:31:00',
          '--server-log', $server_log, '--daemon-log', $daemon_log,
          '--date', '2026-09-28' ],
        SUDO_BIN => $sudo_stub, TZ => 'Europe/Berlin');
    is($exit, 0, 'extract-run-dateless-utc-day-boundary: Test A Exit 0')
        or diag("stderr: $stderr");

    my $ticker_body = $section_body->($stdout, 'Daemon-Log: Ticker');
    like($ticker_body, qr/\[0:05 \/ 4:04\]/,
        'extract-run-dateless-utc-day-boundary: Test A near-midnight UTC line (22:30 UTC = 00:30 CEST next calendar day) resolves to --date\'s day and is categorised as Ticker');

    like($stdout, qr/Daemon-Log: \d+ Zeile\(n\) gelesen.*?0 vom Tagesfilter verworfen/s,
        'extract-run-dateless-utc-day-boundary: Test A Restzaehler shows day_filtered=0 for Daemon-Log -- the line was not silently dropped by the day filter');

    unlink($server_log, $daemon_log);

    # -- Test B: same-day case (regression guard) -------------------------
    my ($sfh2, $server_log2) = tempfile();
    close($sfh2);

    my ($dfh2, $daemon_log2) = tempfile();
    print $dfh2 "19:35:19.482 I [f:77                            ] playing spotify:track:6md4w95cnKaW64JyEQ3A0L \"Somebody That I Used To Know\" by \"Gotye\" [2:40 / 4:04]\e[0m\n";
    close($dfh2);

    my ($exit2, $stdout2, $stderr2) = run_perl_tool($extract_run_script,
        [ 'aa:bb:cc:dd:ee:01', '21:35:15', '21:35:25',
          '--server-log', $server_log2, '--daemon-log', $daemon_log2,
          '--date', '2026-09-28' ],
        SUDO_BIN => $sudo_stub, TZ => 'Europe/Berlin');
    is($exit2, 0, 'extract-run-dateless-utc-day-boundary: Test B Exit 0')
        or diag("stderr: $stderr2");

    my $ticker_body2 = $section_body->($stdout2, 'Daemon-Log: Ticker');
    like($ticker_body2, qr/\[2:40 \/ 4:04\]/,
        'extract-run-dateless-utc-day-boundary: Test B same-day case still resolves correctly (no day-boundary crossing)');

    unlink($server_log2, $daemon_log2);
};

# ============================================================
# subtest 'extract-run-dateless-no-date-hint' -- 84.1-REVIEW.md round 3,
# WR-10. Three consequences of the previous 'unrecognized' catch-all for
# every new-format line that didn't resolve, now fixed as a side effect of
# WR-09's change plus this commit's own additions:
#
# Test A: without --date, resolve_dateless_utc() can never resolve a day,
# so every new-format line now gets the distinct 'dateless_no_date' discard
# reason instead of 'unrecognized' -- and report_coverage prints a loud
# "!!" hint naming it (rather than silently folding it into the "andere
# Form" count, which is now reserved for genuinely unrecognised lines).
#
# Test B: WITH --date, a new-format line outside the window (reusing Test
# B's fixture shape from 'extract-run-daemon-ticker-format') is now a fully
# resolved, timestamped record that scan_log counts as 'outside' -- it must
# NOT appear in the "andere Form" hint text at all.
# ============================================================
subtest 'extract-run-dateless-no-date-hint' => sub {
    my $stubdir   = tempdir(CLEANUP => 1);
    my $sudo_stub = write_sudo_passthrough_stub($stubdir);

    # -- Test A: no --date at all ----------------------------------------
    my ($sfh, $server_log) = tempfile();
    close($sfh);
    my ($dfh, $daemon_log) = tempfile();
    print $dfh "19:35:19.482 I [f:77                            ] playing spotify:track:6md4w95cnKaW64JyEQ3A0L \"Somebody That I Used To Know\" by \"Gotye\" [2:40 / 4:04]\e[0m\n";
    close($dfh);

    my ($exit1, $stdout1, $stderr1) = run_perl_tool($extract_run_script,
        [ 'aa:bb:cc:dd:ee:01', '21:35:15', '21:35:25',
          '--server-log', $server_log, '--daemon-log', $daemon_log ],
        SUDO_BIN => $sudo_stub, TZ => 'Europe/Berlin');
    is($exit1, 0, 'extract-run-dateless-no-date-hint: Test A Exit 0')
        or diag("stderr: $stderr1");

    like($stdout1, qr/!! Daemon-Log: 1 datumslose UTC-Tickerzeile\(n\).*OHNE --date/,
        'extract-run-dateless-no-date-hint: Test A prints the loud dateless_no_date hint when --date is absent');
    unlike($stdout1, qr/andere Form: 1/,
        'extract-run-dateless-no-date-hint: Test A does NOT fold the dateless line into the "andere Form" (genuinely unrecognised) count');

    unlink($server_log, $daemon_log);

    # -- Test B: WITH --date, line outside the window --------------------
    my ($sfh2, $server_log2) = tempfile();
    close($sfh2);
    my ($dfh2, $daemon_log2) = tempfile();
    print $dfh2 "19:34:39.482 I [f:77                            ] playing spotify:track:6md4w95cnKaW64JyEQ3A0L \"Somebody That I Used To Know\" by \"Gotye\" [1:54 / 4:04]\e[0m\n";
    close($dfh2);

    my ($exit2, $stdout2, $stderr2) = run_perl_tool($extract_run_script,
        [ 'aa:bb:cc:dd:ee:01', '21:35:15', '21:35:25',
          '--server-log', $server_log2, '--daemon-log', $daemon_log2,
          '--date', '2026-09-28' ],
        SUDO_BIN => $sudo_stub, TZ => 'Europe/Berlin');
    is($exit2, 0, 'extract-run-dateless-no-date-hint: Test B Exit 0')
        or diag("stderr: $stderr2");

    unlike($stdout2, qr/andere Form: 1/,
        'extract-run-dateless-no-date-hint: Test B a line outside the window (but WITH --date) is not counted as "andere Form" (unrecognised)');
    like($stdout2, qr/Daemon-Log: 1 Zeile\(n\) gelesen[^\n]*1 ausserhalb des Fensters/,
        'extract-run-dateless-no-date-hint: Test B the Restzaehler counts the line as ausserhalb des Fensters (outside), not unrecognized');

    unlink($server_log2, $daemon_log2);
};

# ============================================================
# subtest 'extract-run-daemon-day-chronology' -- 84-22 splice fix (debug
# session shim-final-browse-reconnect, user decision 2026-10-06 option 3).
# The daemon log carries NO date (the newest dated line is 2026-09-23); the
# tool gave every date-less UTC ticker line the --date day (so the tickers
# of EVERY day at the same clock time landed in the window -- the "four
# titles") and dated [fakepulse] lines from the last dated line before them
# (2026-09-23 -> the run's own fakepulse lines fell out, "MUSTER NICHT
# GEFUNDEN"). Fix: the log is append-only, so a UTC ticker clock that steps
# back by more than 1.0 s starts the next day; the LAST day group is dated
# from the log's mtime (or --daemon-end-epoch), earlier groups count back;
# [fakepulse] lines take the first local-clock instant at/after the line
# before them.
#
# REAL material, read in place (mtime preserved, 2026-10-06 10:34:01): the
# archived daemon window of 84-22-final-browse-play-261006-103109 -- lines
# 2-430 are 2026-10-05 (the C3/B2 Connect mid-seek: "Play" by "Alewya"
# tickers, a write-error close at 10:32:38.095), lines 431-794 the run
# (its own client-attach fd=40 at 10:31:14.651). RED before the fix:
# --date 2026-10-06 shows the Alewya tickers as 26-10-06 and the fd=40
# attach as [TAG ?]; --date 2026-10-05 shows the run's own tickers and its
# fd=40 attach as if they were 2026-10-05 lines.
# Boundary neighbours (synthetic, pinned by --daemon-end-epoch): a ticker
# 0.9 s behind its predecessor stays on the same day, 1.1 s starts the
# next day.
# ============================================================
subtest 'extract-run-daemon-day-chronology' => sub {
    my $stubdir   = tempdir(CLEANUP => 1);
    my $sudo_stub = write_sudo_passthrough_stub($stubdir);
    my ($sfh, $server_log) = tempfile();
    close($sfh);   # leer -- dieser Subtest gilt dem Daemon-Log

    my $section_body = sub {
        my ($out, $hdr) = @_;
        return ($out =~ /---\s*\Q$hdr\E.*?---\n(.*?)(?=\n---|\z)/s) ? $1 : '';
    };
    my $win = "$ENV{HOME}/SynologyDrive/dev/spoton-messdaten/84-22-final-browse-play-261006-103109/daemon-window.txt";
  SKIP: {
        skip 'archived 84-22 run 103109 window not on this host (measurement data, not in git)', 12
            unless -f $win;
        my @st = stat($win);
        my @lt = localtime($st[9]);
        skip 'archived window mtime is not 2026-10-06 (copied without -p?) -- the end anchor of this case', 12
            unless sprintf('%04d-%02d-%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3]) eq '2026-10-06';

        my ($e6, $o6, $x6) = run_perl_tool($extract_run_script,
            [ '02:00:00:5a:11:01', '10:30:44', '10:34:00',
              '--server-log', $server_log, '--daemon-log', $win, '--date', '2026-10-06' ],
            SUDO_BIN => $sudo_stub, TZ => 'Europe/Berlin');
        is($e6, 0, 'extract-run-daemon-day-chronology: --date 2026-10-06 exit 0') or diag("stderr: $x6");
        my $tick6 = $section_body->($o6, 'Daemon-Log: Ticker');
        my $att6  = $section_body->($o6, 'Daemon-Log: client-attach / client-close / flush-disconnect');
        unlike($tick6, qr/"Play" by "Alewya"/,
            'extract-run-daemon-day-chronology: --date 2026-10-06 -- the 2026-10-05 Alewya tickers (archived lines 2-430) are NOT in the window');
        like($tick6, qr/1rcIb8sfuxcOsCoLqVaQhw/,
            'extract-run-daemon-day-chronology: --date 2026-10-06 -- the run\'s own ticker (track 1rcIb8sfuxcOsCoLqVaQhw) is in the window');
        like($att6, qr/^\[fakepulse 10:31:14\.651\] client-attach: new \/stream client fd=40$/m,
            'extract-run-daemon-day-chronology: --date 2026-10-06 -- the run\'s own client-attach fd=40 is dated (no [TAG ?] prefix)');
        unlike($att6, qr/client-close: write error\/disconnect/,
            'extract-run-daemon-day-chronology: --date 2026-10-06 -- the 2026-10-05 write-error close (10:32:38.095) is NOT in the window');
        unlike($o6, qr/MEHRDEUTIG \(Daemon-Log\)/,
            'extract-run-daemon-day-chronology: --date 2026-10-06 -- no multi-day ambiguity left in the daemon window');

        my ($e5, $o5, $x5) = run_perl_tool($extract_run_script,
            [ '02:00:00:5a:11:01', '10:30:44', '10:34:00',
              '--server-log', $server_log, '--daemon-log', $win, '--date', '2026-10-05' ],
            SUDO_BIN => $sudo_stub, TZ => 'Europe/Berlin');
        is($e5, 0, 'extract-run-daemon-day-chronology: --date 2026-10-05 exit 0') or diag("stderr: $x5");
        my $tick5 = $section_body->($o5, 'Daemon-Log: Ticker');
        my $att5  = $section_body->($o5, 'Daemon-Log: client-attach / client-close / flush-disconnect');
        like($tick5, qr/"Play" by "Alewya" \[2:44 \/ 3:21\]/,
            'extract-run-daemon-day-chronology: --date 2026-10-05 -- the Alewya tickers belong to 2026-10-05');
        unlike($tick5, qr/1rcIb8sfuxcOsCoLqVaQhw/,
            'extract-run-daemon-day-chronology: --date 2026-10-05 -- the run\'s own ticker (2026-10-06) is NOT in the 2026-10-05 window');
        like($att5, qr/^\[fakepulse 10:32:38\.095\] client-close: write error\/disconnect$/m,
            'extract-run-daemon-day-chronology: --date 2026-10-05 -- the write-error close is a 2026-10-05 line');
        unlike($att5, qr/fd=40/,
            'extract-run-daemon-day-chronology: --date 2026-10-05 -- the run\'s own fd=40 attach (2026-10-06) is NOT in the 2026-10-05 window');
        like($o6, qr/Tagesrekonstruktion: 1 Tagesgrenze/,
            'extract-run-daemon-day-chronology: the report names the reconstructed day boundary');
    }

    # boundary neighbours: 0.9 s back = jitter (one day), 1.1 s back = next day; end anchor pinned
    my $end = 1791223230;   # 2026-10-05T08:00:30Z
    for my $c ([0.9, 3], [1.1, 1]) {
        my ($back, $want) = @$c;
        my ($dfh, $dlog) = tempfile();
        my $s2 = sprintf('%06.3f', 60 - $back);
        print $dfh "07:59:00.000 I [f:77                            ] playing spotify:track:6md4w95cnKaW64JyEQ3A0L \"Somebody That I Used To Know\" by \"Gotye\" [0:10 / 4:04]\e[0m\n";
        print $dfh "08:00:00.000 I [f:77                            ] playing spotify:track:6md4w95cnKaW64JyEQ3A0L \"Somebody That I Used To Know\" by \"Gotye\" [1:10 / 4:04]\e[0m\n";
        print $dfh "07:59:$s2 I [f:77                            ] playing spotify:track:6md4w95cnKaW64JyEQ3A0L \"Somebody That I Used To Know\" by \"Gotye\" [1:11 / 4:04]\e[0m\n";
        close($dfh);
        my ($e, $o, $x) = run_perl_tool($extract_run_script,
            [ 'aa:bb:cc:dd:ee:01', '09:58:50', '10:00:30',
              '--server-log', $server_log, '--daemon-log', $dlog, '--date', '2026-10-05', '--daemon-end-epoch', $end ],
            SUDO_BIN => $sudo_stub, TZ => 'Europe/Berlin');
        is($e, 0, "extract-run-daemon-day-chronology: neighbour ${back} s exit 0") or diag("stderr: $x");
        my $tick = $section_body->($o, 'Daemon-Log: Ticker');
        my $n = () = $tick =~ /Gotye/g;
        is($n, $want, "extract-run-daemon-day-chronology: a ticker ${back} s behind its predecessor leaves $want of 3 lines on 2026-10-05 (end anchor 2026-10-05T08:00:30Z)")
            or diag($tick);
        unlink($dlog);
    }
    unlink($server_log);
};

# ============================================================
# subtest 'cluster2-series-nearend-verdict-late-stop' -- 84.1-05
# continuation, Task 4. `nearend_verdict()` (cluster2-series.sh) set
# `stop_ts` from the FIRST StreamingFailed/STOPPED-IDLE line AT OR AFTER
# the seek dispatch, with NO upper time bound -- so a scenario's own
# cleanup stop or the natural end-of-track transition, tens of seconds
# later, silently blocked the REFUTED branch's `stop_ts is None`
# requirement even when the seek itself completed normally. Documented as
# a deferred finding in 84.1-CLUSTER2-VERDICTS.md ("New finding (deferred,
# Rule 4...)") against the real archived A3/B3 postfix extracts (A3: a
# Stop -> STOPPED-IDLE 46.7s after dispatch; B3: 13.68s after) BEFORE this
# fix -- both read `nicht_geprueft`; a human reading the raw evidence
# would call both REFUTED (JumpToTime/dispatch seek -> PLAYING-STREAMING
# within ~0.2s, no StreamingFailed anywhere near the dispatch).
#
# Test A (RED before the fix, GREEN after): the REAL archived A3 extract
# -- no synthetic fixture, per the operating rule "at least one real
# (archived) input" -- must now read `refuted`.
# Test B (regression guard, green both before and after): a fixture with
# the confirmed shape (stop 2s after dispatch, ticker paused) must keep
# reading `confirmed` -- the fix must only narrow the LATE-stop case, not
# touch the near-dispatch confirmed path.
# ============================================================
# 84-09: environment skip (CI has no .planning / measurement archive) as a
# SKIP around the subtest -- same TAP as the former in-subtest skip-all
# (one `ok N # skip` in the parent), no plan-level skip in a soloist file.
SKIP: {
    skip 'cluster2-series.sh not present in this checkout (.planning absent: CI)', 1 unless -f $cluster2_series_script;
subtest 'cluster2-series-nearend-verdict-late-stop' => sub {

    my $archived_a3 = "$ENV{HOME}/SynologyDrive/dev/spoton-messdaten/84.1-05-series-260928-2100/lavender-UAT/extract-A3-postfix-260929.txt";
    SKIP: {
        skip 'archived A3 postfix extract not present on this host (measurement data, not checked into git)', 1
            unless -f $archived_a3;

        my ($exit, $stdout, $stderr) = run_tool($cluster2_series_script,
            [ '__nearend_verdict', $archived_a3 ]);
        is($exit, 0, 'cluster2-series-nearend-verdict-late-stop: __nearend_verdict hook exits 0')
            or diag("stderr: $stderr");
        my ($verdict) = $stdout =~ /(\S+)/;
        is($verdict, 'refuted',
            'cluster2-series-nearend-verdict-late-stop: Test A real archived A3 (Stop 46.7s after dispatch, no StreamingFailed near it) now reads refuted, not nicht_geprueft')
            or diag("stdout: $stdout");
    }

    my ($cfh, $confirmed_fixture) = tempfile();
    print {$cfh} <<'FIXEOF';
[26-09-10 10:57:36.4152] Plugins::SpotOn::Soloist::Control::_execute (2194) Control: dispatch seek armed=1 uri=- (02:00:00:5a:11:03)
[26-09-10 10:57:36.4152] Slim::Player::StreamingController::_eventAction (301) 02:00:00:5a:11:03: JumpToTime - new state BUFFERING-STREAMING
[26-09-10 10:57:38.4152] Slim::Player::StreamingController::_eventAction (301) 02:00:00:5a:11:03: StreamingFailed - new state STOPPED-IDLE
19:57:38.500 I [f:77                            ] paused spotify:track:2374M0fQpWi3dLnB54qaLX "Africa" by "TOTO" [4:30 / 4:55]
FIXEOF
    close($cfh);
    my ($exit_c, $stdout_c, $stderr_c) = run_tool($cluster2_series_script,
        [ '__nearend_verdict', $confirmed_fixture ]);
    is($exit_c, 0, 'cluster2-series-nearend-verdict-late-stop: Test B hook exits 0')
        or diag("stderr: $stderr_c");
    my ($verdict_c) = $stdout_c =~ /(\S+)/;
    is($verdict_c, 'confirmed',
        'cluster2-series-nearend-verdict-late-stop: Test B stop 2s after dispatch + ticker paused still reads confirmed (regression guard)');
    unlink($confirmed_fixture);
};
}

# ============================================================
# subtest 'cluster2-series-daemon-ticker-tail-depth' -- 84.1-05
# continuation, Task 2 investigation. listen_l1's post-seek gate and
# listen_l2's post-transfer gate both read `daemon_ticker_latest "$mac" 60`
# -- a hardcoded 60-RAW-line lookback. Real evidence from this dispatch's
# run (02:00:00:5a:11:03-soloist.log, L2 transfer-in window): between the
# real Ticker line "08:55:04.388 ... playing spotify:track:1JSTJ... [0:00
# / 4:13]" (the exact line quoted in this continuation's dispatch) and the
# NEXT Ticker heartbeat 10.094s later, there are 437 RAW lines of
# fakepulse cork/underflow/mixer noise -- 7x the 60-line lookback. NOT a
# UTC/local mismatch (both L1_A4 and L2's real failures read
# ticker_status=/ticker_track=/ticker_pos= EMPTY, meaning zero Ticker
# lines were found in the tail window at all, not a wrong-window match)
# and NOT a regex miss (extract-run-daemon-ticker-format above already
# covers the dateless/ANSI line shape; Test B below proves the SAME regex
# finds the line once the lookback is deep enough). The fixture below is
# 200 REAL, verbatim lines copied from that exact window (trailing
# "\e[0m" ANSI reset stripped only -- irrelevant to this bug, and already
# covered by extract-run-daemon-ticker-format above); line 1 is the Ticker
# line, lines 2-200 are the real noise that buried it under a 60-line tail.
#
# Test A (RED before the fix, GREEN after): __daemon_ticker_latest_gate
# against this real fixture, using the runner's own TICKER_GATE_TAIL_N
# (no override) -- must return the Ticker line with the correct track id
# and position. Before the fix (TICKER_GATE_TAIL_N=60) this fails: the
# last 60 raw lines of the 200-line fixture are all noise (line 1 is 140
# lines further back than the 60-line window reaches). After the fix
# (TICKER_GATE_TAIL_N=3000, deep enough for the whole 200-line fixture),
# it passes.
# Test B (regression guard, must stay green both before and after): a
# genuinely ticker-less fixture (lines 2-200 of the same real material,
# Ticker line 1 dropped) must still read empty -- the fix widens the
# lookback, it must not make the gate hallucinate a Ticker line that
# truly is not there.
# ============================================================
# 84-09: environment skip (CI has no .planning / measurement archive) as a
# SKIP around the subtest -- same TAP as the former in-subtest skip-all
# (one `ok N # skip` in the parent), no plan-level skip in a soloist file.
SKIP: {
    skip 'cluster2-series.sh not present in this checkout (.planning absent: CI)', 1 unless -f $cluster2_series_script;
subtest 'cluster2-series-daemon-ticker-tail-depth' => sub {

    my ($ffh, $ticker_fixture) = tempfile();
    print {$ffh} <<'TICKERFIXEOF';
08:55:04.388 I [f:77                            ] playing spotify:track:1JSTJqkT5qHq8MDJnJbRE1 "Every Breath You Take" by "The Police" [0:00 / 4:13]
08:55:04.388 I [f:294                           ] Prefetch: looks like a skip or partial context change - halving window size to 1
08:55:04.388 I [f:165                           ] Emitting signal.
08:55:04.388 I [f:168                           ] Device coordinator was set online
08:55:04.388 I [f:601                           ] Updated connection type from 6 to 6
08:55:04.388 I [f:567                           ] Timeline attacher (0x7fcfdc0243f0) adding audio to MediaPlayer
08:55:04.388 I [f:568                           ]     stream type: default
08:55:04.388 I [f:569                           ]     prev transition_out: 
08:55:04.388 I [f:570                           ]     curr transition_in: none
08:55:04.388 I [f:571                           ]     fade in start: -1 ms
08:55:04.388 I [f:572                           ]     fade in entry delay: 0 ms
08:55:04.388 I [f:573                           ]     fade in duration: -1 ms
08:55:04.388 I [f:574                           ]     fade out start: -1 ms
08:55:04.388 I [f:575                           ]     fade out duration: -1 ms
08:55:04.388 I [f:576                           ]     fade overlap duration: -1 ms
08:55:04.388 I [f:581                           ]     fade in curves: volume -1, filter -1
08:55:04.388 I [f:586                           ]     fade out curves: volume -1, filter -1
08:55:04.388 I [f:587                           ]     initial seek: 
08:55:04.388 I [f:588                           ]     pre-audio seek: 
08:55:04.388 I [f:589                           ]     audio_start (stretched/rendered time): 0ms
08:55:04.388 I [f:590                           ]     start_pos: 0ms
08:55:04.388 I [f:591                           ]     stop_pos: 
08:55:04.388 I [f:593                           ]     fade in end (stretched time (in audio)): 0ms
08:55:04.388 I [f:595                           ]     fade out duration (stretched time): 0ms
08:55:04.388 I [f:596                           ]     audio duration: 253920ms
08:55:04.388 I [f:143                           ] Timeline attacher(0x7fcfdc0243f0) speed automation:
08:55:04.388 I [f:146                           ]     speed change at 0ms value 1.000000
08:55:04.388 I [f:599                           ]     automation_start_position: 0ms
08:55:04.388 I [f:112                           ] Timeline attacher(0x7fcfdc0243f0) pushing new gain automation points to mixer:
08:55:04.388 I [f:120                           ]     point offset=0ms, alignment=begin, value=1
08:55:04.389 I [f:1315                          ] Audio@0x7fcfdc1d65c0 is buffering
08:55:04.389 I [f:119                           ] AudioRendererImpl 0x7fcfdc5ea7d0 format [32-bit-float-pcm, 44100 Hz] driver [stream type default content type music]
08:55:04.389 I [f:1254                          ] Audio@0x7fcfdc1d65c0 start_frame now 0 (was -1), last mixed frame 0 (read 0)
08:55:04.389 I [f:119                           ] AudioRendererImpl 0x7fcfdc5ea7d0 format [32-bit-float-pcm, 44100 Hz] driver [stream type default content type music]
08:55:04.389 I [f:478                           ] AudioRendererImpl 0x7fcfdc5ea7d0 cannot start driver: flushing 0 hasSuff 0 canStart 0 1 numAud 1
08:55:04.389 I [f:517                           ] Audio@0x7fcfdc1d65c0 started at 0 (0ms)
[fakepulse 10:55:04.392] client-attach: new /stream client fd=33
[fakepulse 10:55:04.392] first-drain: 16384 bytes to fd=33 after flush-disconnect
08:55:04.392 I [f:41                            ] onAudioStarted: stp 0x7fcfdc864a50, active audio count 1
08:55:04.392 I [f:51                            ] onAudioProgress: stp 0x7fcfdc864a50, timepoint 1/1
[fakepulse BOUNDARY ts=10:55:04.396] seek_arm: armed=1
[fakepulse BOUNDARY ts=10:55:04.398] seek_arm: armed=2
08:55:04.398 I [f:1565                          ] Seeking to position: 0 ms - creator position: 0 ms
08:55:04.398 I [f:310                           ] ContextPlayer RoutingTrackPlayer: Seeking to 0 ms creator_timestamp_position -1
08:55:04.398 I [f:1269                          ] Seeking track to 0 ms (playback_id 4a7f21d47ff7d6d3da082c112973530c)
08:55:04.398 I [f:61                            ] onAudioEnded: stp 0x7fcfdc864a50, active audio count 0
08:55:04.398 I [f:791                           ] Mixer@0x7fcfdc721510 flush
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
[fakepulse 10:55:04.398] pa_stream_flush(stream=0x7fcfc47e78c0)
[fakepulse BOUNDARY ts=10:55:04.398] flush: stream=0x7fcfc47e78c0 bytes_written=4136960 ring_fill=581632 corked=1
08:55:04.398 I [f:166                           ] AudioRendererImpl 0x7fcfdc5ea7d0 flush, driver hasSuff: 0
08:55:04.398 I [f:670                           ] Mixer@0x7fcfdc721510 destructed without flushing
08:55:04.398 I [f:531                           ] Restarting decompressor.
08:55:04.398 I [f:532                           ]     pos: 0 frames
08:55:04.398 I [f:533                           ]     offset: 4511 bytes
08:55:04.398 I [f:292                           ] Timeline attacher (0x7fcfdc0243f0) flush
08:55:04.398 I [f:293                           ]     position: 0 ms
08:55:04.400 I [f:724                           ] Starting playback.
08:55:04.400 I [f:726                           ]     min limit 4000 ms.
08:55:04.400 I [f:727                           ]     compressed buffer: 74680 bytes
08:55:04.400 I [f:729                           ]     decompressed buffer: 0 ms
08:55:04.400 I [f:731                           ]     sink buffer: 1021 ms
08:55:04.400 I [f:732                           ]     final source buffer: false
08:55:04.400 I [f:733                           ]     trystartplayback count: 6
08:55:04.400 I [f:888                           ] AudioBufferedSinkImpl::markStartPlayback(0x7fcfdc797c00): want now 2
08:55:04.400 I [f:192                           ] restoreMedia: adding audio 0x7fcfdc1d65c0
08:55:04.400 I [f:1315                          ] Audio@0x7fcfdc1d65c0 is buffering
08:55:04.400 I [f:119                           ] AudioRendererImpl 0x7fcfdc5ea7d0 format [32-bit-float-pcm, 44100 Hz] driver [stream type default content type music]
08:55:04.400 I [f:1254                          ] Audio@0x7fcfdc1d65c0 start_frame now 0 (was -1), last mixed frame 0 (read 0)
08:55:04.401 I [f:478                           ] AudioRendererImpl 0x7fcfdc5ea7d0 cannot start driver: flushing 0 hasSuff 0 canStart 0 1 numAud 1
08:55:04.401 I [f:517                           ] Audio@0x7fcfdc1d65c0 started at 0 (0ms)
08:55:04.405 I [f:41                            ] onAudioStarted: stp 0x7fcfdc864a50, active audio count 1
08:55:04.405 I [f:51                            ] onAudioProgress: stp 0x7fcfdc864a50, timepoint 1/1
08:55:04.406 I [f:1565                          ] Seeking to position: 0 ms - creator position: 0 ms
08:55:04.406 I [f:310                           ] ContextPlayer RoutingTrackPlayer: Seeking to 0 ms creator_timestamp_position -1
08:55:04.406 I [f:1269                          ] Seeking track to 0 ms (playback_id 4a7f21d47ff7d6d3da082c112973530c)
08:55:04.406 I [f:61                            ] onAudioEnded: stp 0x7fcfdc864a50, active audio count 0
08:55:04.406 I [f:791                           ] Mixer@0x7fcfdc721510 flush
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
[fakepulse 10:55:04.407] pa_stream_flush(stream=0x7fcfc47e78c0)
[fakepulse BOUNDARY ts=10:55:04.407] flush: stream=0x7fcfc47e78c0 bytes_written=4685824 ring_fill=548864 corked=1
08:55:04.407 I [f:166                           ] AudioRendererImpl 0x7fcfdc5ea7d0 flush, driver hasSuff: 0
08:55:04.407 I [f:670                           ] Mixer@0x7fcfdc721510 destructed without flushing
08:55:04.407 I [f:531                           ] Restarting decompressor.
08:55:04.407 I [f:532                           ]     pos: 0 frames
08:55:04.407 I [f:533                           ]     offset: 4511 bytes
08:55:04.407 I [f:292                           ] Timeline attacher (0x7fcfdc0243f0) flush
08:55:04.407 I [f:293                           ]     position: 0 ms
08:55:04.409 I [f:724                           ] Starting playback.
08:55:04.409 I [f:726                           ]     min limit 4000 ms.
08:55:04.409 I [f:727                           ]     compressed buffer: 74680 bytes
08:55:04.409 I [f:729                           ]     decompressed buffer: 0 ms
08:55:04.409 I [f:731                           ]     sink buffer: 1021 ms
08:55:04.409 I [f:732                           ]     final source buffer: false
08:55:04.409 I [f:733                           ]     trystartplayback count: 6
08:55:04.409 I [f:888                           ] AudioBufferedSinkImpl::markStartPlayback(0x7fcfdc797c00): want now 3
08:55:04.409 I [f:192                           ] restoreMedia: adding audio 0x7fcfdc1d65c0
08:55:04.409 I [f:1315                          ] Audio@0x7fcfdc1d65c0 is buffering
08:55:04.409 I [f:119                           ] AudioRendererImpl 0x7fcfdc5ea7d0 format [32-bit-float-pcm, 44100 Hz] driver [stream type default content type music]
08:55:04.409 I [f:1254                          ] Audio@0x7fcfdc1d65c0 start_frame now 0 (was -1), last mixed frame 0 (read 0)
08:55:04.409 I [f:478                           ] AudioRendererImpl 0x7fcfdc5ea7d0 cannot start driver: flushing 0 hasSuff 0 canStart 0 1 numAud 1
08:55:04.409 I [f:517                           ] Audio@0x7fcfdc1d65c0 started at 0 (0ms)
08:55:04.413 I [f:41                            ] onAudioStarted: stp 0x7fcfdc864a50, active audio count 1
08:55:04.413 I [f:51                            ] onAudioProgress: stp 0x7fcfdc864a50, timepoint 1/1
[fakepulse BOUNDARY ts=10:55:05.016] write_summary: bytes_written=6586368 ring_fill=1310720 calls=489 bytes_since=4005888 corked=1
08:55:05.417 I [f:478                           ] AudioRendererImpl 0x7fcfdc5ea7d0 cannot start driver: flushing 0 hasSuff 0 canStart 0 1 numAud 1
[fakepulse BOUNDARY ts=10:55:06.018] write_summary: bytes_written=8798208 ring_fill=2539520 calls=270 bytes_since=2211840 corked=1
[fakepulse] TIMING caller=update_timing_info stream=0x7fcfc47e78c0 corked=1 playing=0 bytes_written=8996736 fill=2443136 fill_input=2443136 write_index=8996736 read_index=6553600 since_underrun=3317601 sink_usec=6924988
08:55:06.418 I [f:478                           ] AudioRendererImpl 0x7fcfdc5ea7d0 cannot start driver: flushing 0 hasSuff 0 canStart 0 1 numAud 1
[fakepulse BOUNDARY ts=10:55:07.019] write_summary: bytes_written=9256960 ring_fill=2015232 calls=74 bytes_since=458752 corked=1
08:55:07.419 I [f:478                           ] AudioRendererImpl 0x7fcfdc5ea7d0 cannot start driver: flushing 0 hasSuff 0 canStart 0 1 numAud 1
[fakepulse BOUNDARY ts=10:55:08.020] write_summary: bytes_written=9666560 ring_fill=1441792 calls=70 bytes_since=409600 corked=1
[fakepulse] TIMING caller=update_timing_info stream=0x7fcfc47e78c0 corked=1 playing=0 bytes_written=9820000 fill=1300320 fill_input=1300320 write_index=9820000 read_index=8519680 since_underrun=5337671 sink_usec=3685714
08:55:08.421 I [f:478                           ] AudioRendererImpl 0x7fcfdc5ea7d0 cannot start driver: flushing 0 hasSuff 0 canStart 0 1 numAud 1
[fakepulse BOUNDARY ts=10:55:09.021] write_summary: bytes_written=10084352 ring_fill=876544 calls=71 bytes_since=417792 corked=1
08:55:09.422 I [f:478                           ] AudioRendererImpl 0x7fcfdc5ea7d0 cannot start driver: flushing 0 hasSuff 0 canStart 0 1 numAud 1
08:55:09.490 I [f:46                            ] Prefetch: key prefetched for track: spotify:track:1JSTJqkT5qHq8MDJnJbRE1 (file: 9e9d5dc5588e969a900085b1176cdfba0b47c05b)
[fakepulse BOUNDARY ts=10:55:10.023] write_summary: bytes_written=10502144 ring_fill=311296 calls=71 bytes_since=417792 corked=1
[fakepulse] TIMING caller=update_timing_info stream=0x7fcfc47e78c0 corked=1 playing=0 bytes_written=10642848 fill=157088 fill_input=157088 write_index=10642848 read_index=10485760 since_underrun=7358785 sink_usec=445260
08:55:10.423 I [f:478                           ] AudioRendererImpl 0x7fcfdc5ea7d0 cannot start driver: flushing 0 hasSuff 0 canStart 0 1 numAud 1
08:55:10.490 I [f:2769                          ] Update! reason: cached-key-provided, flags: 0x00
[fakepulse 10:55:10.573] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
[fakepulse 10:55:10.623] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
08:55:10.683 I [f:724                           ] Starting playback.
08:55:10.683 I [f:726                           ]     min limit 4000 ms.
08:55:10.683 I [f:727                           ]     compressed buffer: 1003172 bytes
08:55:10.683 I [f:729                           ]     decompressed buffer: 0 ms
08:55:10.683 I [f:731                           ]     sink buffer: 1022 ms
08:55:10.683 I [f:732                           ]     final source buffer: false
08:55:10.683 I [f:733                           ]     trystartplayback count: 0
08:55:10.683 I [f:888                           ] AudioBufferedSinkImpl::markStartPlayback(0x7fcfdc797c00): want now 4
[fakepulse 10:55:10.699] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
[fakepulse 10:55:10.749] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
[fakepulse 10:55:10.799] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
[fakepulse 10:55:10.850] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
08:55:10.882 I [f:724                           ] Starting playback.
08:55:10.882 I [f:726                           ]     min limit 4000 ms.
08:55:10.882 I [f:727                           ]     compressed buffer: 998762 bytes
08:55:10.882 I [f:729                           ]     decompressed buffer: 0 ms
08:55:10.882 I [f:731                           ]     sink buffer: 1012 ms
08:55:10.882 I [f:732                           ]     final source buffer: false
08:55:10.882 I [f:733                           ]     trystartplayback count: 0
08:55:10.882 I [f:888                           ] AudioBufferedSinkImpl::markStartPlayback(0x7fcfdc797c00): want now 5
[fakepulse 10:55:10.913] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
[fakepulse 10:55:10.963] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
[fakepulse 10:55:11.014] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
[fakepulse BOUNDARY ts=10:55:11.024] write_summary: bytes_written=10928128 ring_fill=6144 calls=75 bytes_since=425984 corked=1
[fakepulse 10:55:11.064] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
08:55:11.083 I [f:724                           ] Starting playback.
08:55:11.083 I [f:726                           ]     min limit 4000 ms.
08:55:11.083 I [f:727                           ]     compressed buffer: 994645 bytes
08:55:11.083 I [f:729                           ]     decompressed buffer: 0 ms
08:55:11.083 I [f:731                           ]     sink buffer: 1043 ms
08:55:11.083 I [f:732                           ]     final source buffer: false
08:55:11.083 I [f:733                           ]     trystartplayback count: 0
08:55:11.083 I [f:888                           ] AudioBufferedSinkImpl::markStartPlayback(0x7fcfdc797c00): want now 6
[fakepulse 10:55:11.114] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
[fakepulse 10:55:11.165] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
[fakepulse 10:55:11.215] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
[fakepulse 10:55:11.265] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
08:55:11.283 I [f:724                           ] Starting playback.
08:55:11.283 I [f:726                           ]     min limit 4000 ms.
08:55:11.283 I [f:727                           ]     compressed buffer: 990358 bytes
08:55:11.283 I [f:729                           ]     decompressed buffer: 0 ms
08:55:11.283 I [f:731                           ]     sink buffer: 1051 ms
08:55:11.283 I [f:732                           ]     final source buffer: false
08:55:11.283 I [f:733                           ]     trystartplayback count: 0
08:55:11.283 I [f:888                           ] AudioBufferedSinkImpl::markStartPlayback(0x7fcfdc797c00): want now 7
[fakepulse 10:55:11.315] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
[fakepulse 10:55:11.366] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
[fakepulse 10:55:11.416] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
08:55:11.424 I [f:478                           ] AudioRendererImpl 0x7fcfdc5ea7d0 cannot start driver: flushing 0 hasSuff 0 canStart 0 1 numAud 1
[fakepulse 10:55:11.466] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
08:55:11.482 I [f:724                           ] Starting playback.
08:55:11.482 I [f:726                           ]     min limit 4000 ms.
08:55:11.483 I [f:727                           ]     compressed buffer: 986258 bytes
08:55:11.483 I [f:729                           ]     decompressed buffer: 0 ms
08:55:11.483 I [f:731                           ]     sink buffer: 1015 ms
08:55:11.483 I [f:732                           ]     final source buffer: false
08:55:11.483 I [f:733                           ]     trystartplayback count: 0
08:55:11.483 I [f:888                           ] AudioBufferedSinkImpl::markStartPlayback(0x7fcfdc797c00): want now 8
[fakepulse 10:55:11.524] underflow: ring empty, invoking underflow_cb
TICKERFIXEOF
    close($ffh);

    my ($exit_a, $stdout_a, $stderr_a) = run_tool($cluster2_series_script,
        [ '__daemon_ticker_latest_gate', $ticker_fixture ]);
    is($exit_a, 0, 'cluster2-series-daemon-ticker-tail-depth: Test A hook exits 0')
        or diag("stderr: $stderr_a");
    like($stdout_a, qr/spotify:track:1JSTJqkT5qHq8MDJnJbRE1/,
        'cluster2-series-daemon-ticker-tail-depth: Test A the real Ticker line (140 lines back from the noisy tail) is found once TICKER_GATE_TAIL_N is deep enough')
        or diag("stdout: $stdout_a");
    like($stdout_a, qr/\[0:00 \/ 4:13\]/,
        'cluster2-series-daemon-ticker-tail-depth: Test A position/duration parse from the same real line');

    my ($nfh, $noiseonly_fixture) = tempfile();
    print {$nfh} <<'NOISEONLYEOF';
08:55:04.388 I [f:294                           ] Prefetch: looks like a skip or partial context change - halving window size to 1
08:55:04.388 I [f:165                           ] Emitting signal.
08:55:04.388 I [f:168                           ] Device coordinator was set online
08:55:04.388 I [f:601                           ] Updated connection type from 6 to 6
08:55:04.388 I [f:567                           ] Timeline attacher (0x7fcfdc0243f0) adding audio to MediaPlayer
08:55:04.388 I [f:568                           ]     stream type: default
08:55:04.388 I [f:569                           ]     prev transition_out: 
08:55:04.388 I [f:570                           ]     curr transition_in: none
08:55:04.388 I [f:571                           ]     fade in start: -1 ms
08:55:04.388 I [f:572                           ]     fade in entry delay: 0 ms
08:55:04.388 I [f:573                           ]     fade in duration: -1 ms
08:55:04.388 I [f:574                           ]     fade out start: -1 ms
08:55:04.388 I [f:575                           ]     fade out duration: -1 ms
08:55:04.388 I [f:576                           ]     fade overlap duration: -1 ms
08:55:04.388 I [f:581                           ]     fade in curves: volume -1, filter -1
08:55:04.388 I [f:586                           ]     fade out curves: volume -1, filter -1
08:55:04.388 I [f:587                           ]     initial seek: 
08:55:04.388 I [f:588                           ]     pre-audio seek: 
08:55:04.388 I [f:589                           ]     audio_start (stretched/rendered time): 0ms
08:55:04.388 I [f:590                           ]     start_pos: 0ms
08:55:04.388 I [f:591                           ]     stop_pos: 
08:55:04.388 I [f:593                           ]     fade in end (stretched time (in audio)): 0ms
08:55:04.388 I [f:595                           ]     fade out duration (stretched time): 0ms
08:55:04.388 I [f:596                           ]     audio duration: 253920ms
08:55:04.388 I [f:143                           ] Timeline attacher(0x7fcfdc0243f0) speed automation:
08:55:04.388 I [f:146                           ]     speed change at 0ms value 1.000000
08:55:04.388 I [f:599                           ]     automation_start_position: 0ms
08:55:04.388 I [f:112                           ] Timeline attacher(0x7fcfdc0243f0) pushing new gain automation points to mixer:
08:55:04.388 I [f:120                           ]     point offset=0ms, alignment=begin, value=1
08:55:04.389 I [f:1315                          ] Audio@0x7fcfdc1d65c0 is buffering
08:55:04.389 I [f:119                           ] AudioRendererImpl 0x7fcfdc5ea7d0 format [32-bit-float-pcm, 44100 Hz] driver [stream type default content type music]
08:55:04.389 I [f:1254                          ] Audio@0x7fcfdc1d65c0 start_frame now 0 (was -1), last mixed frame 0 (read 0)
08:55:04.389 I [f:119                           ] AudioRendererImpl 0x7fcfdc5ea7d0 format [32-bit-float-pcm, 44100 Hz] driver [stream type default content type music]
08:55:04.389 I [f:478                           ] AudioRendererImpl 0x7fcfdc5ea7d0 cannot start driver: flushing 0 hasSuff 0 canStart 0 1 numAud 1
08:55:04.389 I [f:517                           ] Audio@0x7fcfdc1d65c0 started at 0 (0ms)
[fakepulse 10:55:04.392] client-attach: new /stream client fd=33
[fakepulse 10:55:04.392] first-drain: 16384 bytes to fd=33 after flush-disconnect
08:55:04.392 I [f:41                            ] onAudioStarted: stp 0x7fcfdc864a50, active audio count 1
08:55:04.392 I [f:51                            ] onAudioProgress: stp 0x7fcfdc864a50, timepoint 1/1
[fakepulse BOUNDARY ts=10:55:04.396] seek_arm: armed=1
[fakepulse BOUNDARY ts=10:55:04.398] seek_arm: armed=2
08:55:04.398 I [f:1565                          ] Seeking to position: 0 ms - creator position: 0 ms
08:55:04.398 I [f:310                           ] ContextPlayer RoutingTrackPlayer: Seeking to 0 ms creator_timestamp_position -1
08:55:04.398 I [f:1269                          ] Seeking track to 0 ms (playback_id 4a7f21d47ff7d6d3da082c112973530c)
08:55:04.398 I [f:61                            ] onAudioEnded: stp 0x7fcfdc864a50, active audio count 0
08:55:04.398 I [f:791                           ] Mixer@0x7fcfdc721510 flush
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
[fakepulse 10:55:04.398] pa_stream_flush(stream=0x7fcfc47e78c0)
[fakepulse BOUNDARY ts=10:55:04.398] flush: stream=0x7fcfc47e78c0 bytes_written=4136960 ring_fill=581632 corked=1
08:55:04.398 I [f:166                           ] AudioRendererImpl 0x7fcfdc5ea7d0 flush, driver hasSuff: 0
08:55:04.398 I [f:670                           ] Mixer@0x7fcfdc721510 destructed without flushing
08:55:04.398 I [f:531                           ] Restarting decompressor.
08:55:04.398 I [f:532                           ]     pos: 0 frames
08:55:04.398 I [f:533                           ]     offset: 4511 bytes
08:55:04.398 I [f:292                           ] Timeline attacher (0x7fcfdc0243f0) flush
08:55:04.398 I [f:293                           ]     position: 0 ms
08:55:04.400 I [f:724                           ] Starting playback.
08:55:04.400 I [f:726                           ]     min limit 4000 ms.
08:55:04.400 I [f:727                           ]     compressed buffer: 74680 bytes
08:55:04.400 I [f:729                           ]     decompressed buffer: 0 ms
08:55:04.400 I [f:731                           ]     sink buffer: 1021 ms
08:55:04.400 I [f:732                           ]     final source buffer: false
08:55:04.400 I [f:733                           ]     trystartplayback count: 6
08:55:04.400 I [f:888                           ] AudioBufferedSinkImpl::markStartPlayback(0x7fcfdc797c00): want now 2
08:55:04.400 I [f:192                           ] restoreMedia: adding audio 0x7fcfdc1d65c0
08:55:04.400 I [f:1315                          ] Audio@0x7fcfdc1d65c0 is buffering
08:55:04.400 I [f:119                           ] AudioRendererImpl 0x7fcfdc5ea7d0 format [32-bit-float-pcm, 44100 Hz] driver [stream type default content type music]
08:55:04.400 I [f:1254                          ] Audio@0x7fcfdc1d65c0 start_frame now 0 (was -1), last mixed frame 0 (read 0)
08:55:04.401 I [f:478                           ] AudioRendererImpl 0x7fcfdc5ea7d0 cannot start driver: flushing 0 hasSuff 0 canStart 0 1 numAud 1
08:55:04.401 I [f:517                           ] Audio@0x7fcfdc1d65c0 started at 0 (0ms)
08:55:04.405 I [f:41                            ] onAudioStarted: stp 0x7fcfdc864a50, active audio count 1
08:55:04.405 I [f:51                            ] onAudioProgress: stp 0x7fcfdc864a50, timepoint 1/1
08:55:04.406 I [f:1565                          ] Seeking to position: 0 ms - creator position: 0 ms
08:55:04.406 I [f:310                           ] ContextPlayer RoutingTrackPlayer: Seeking to 0 ms creator_timestamp_position -1
08:55:04.406 I [f:1269                          ] Seeking track to 0 ms (playback_id 4a7f21d47ff7d6d3da082c112973530c)
08:55:04.406 I [f:61                            ] onAudioEnded: stp 0x7fcfdc864a50, active audio count 0
08:55:04.406 I [f:791                           ] Mixer@0x7fcfdc721510 flush
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
[fakepulse 10:55:04.407] pa_stream_flush(stream=0x7fcfc47e78c0)
[fakepulse BOUNDARY ts=10:55:04.407] flush: stream=0x7fcfc47e78c0 bytes_written=4685824 ring_fill=548864 corked=1
08:55:04.407 I [f:166                           ] AudioRendererImpl 0x7fcfdc5ea7d0 flush, driver hasSuff: 0
08:55:04.407 I [f:670                           ] Mixer@0x7fcfdc721510 destructed without flushing
08:55:04.407 I [f:531                           ] Restarting decompressor.
08:55:04.407 I [f:532                           ]     pos: 0 frames
08:55:04.407 I [f:533                           ]     offset: 4511 bytes
08:55:04.407 I [f:292                           ] Timeline attacher (0x7fcfdc0243f0) flush
08:55:04.407 I [f:293                           ]     position: 0 ms
08:55:04.409 I [f:724                           ] Starting playback.
08:55:04.409 I [f:726                           ]     min limit 4000 ms.
08:55:04.409 I [f:727                           ]     compressed buffer: 74680 bytes
08:55:04.409 I [f:729                           ]     decompressed buffer: 0 ms
08:55:04.409 I [f:731                           ]     sink buffer: 1021 ms
08:55:04.409 I [f:732                           ]     final source buffer: false
08:55:04.409 I [f:733                           ]     trystartplayback count: 6
08:55:04.409 I [f:888                           ] AudioBufferedSinkImpl::markStartPlayback(0x7fcfdc797c00): want now 3
08:55:04.409 I [f:192                           ] restoreMedia: adding audio 0x7fcfdc1d65c0
08:55:04.409 I [f:1315                          ] Audio@0x7fcfdc1d65c0 is buffering
08:55:04.409 I [f:119                           ] AudioRendererImpl 0x7fcfdc5ea7d0 format [32-bit-float-pcm, 44100 Hz] driver [stream type default content type music]
08:55:04.409 I [f:1254                          ] Audio@0x7fcfdc1d65c0 start_frame now 0 (was -1), last mixed frame 0 (read 0)
08:55:04.409 I [f:478                           ] AudioRendererImpl 0x7fcfdc5ea7d0 cannot start driver: flushing 0 hasSuff 0 canStart 0 1 numAud 1
08:55:04.409 I [f:517                           ] Audio@0x7fcfdc1d65c0 started at 0 (0ms)
08:55:04.413 I [f:41                            ] onAudioStarted: stp 0x7fcfdc864a50, active audio count 1
08:55:04.413 I [f:51                            ] onAudioProgress: stp 0x7fcfdc864a50, timepoint 1/1
[fakepulse BOUNDARY ts=10:55:05.016] write_summary: bytes_written=6586368 ring_fill=1310720 calls=489 bytes_since=4005888 corked=1
08:55:05.417 I [f:478                           ] AudioRendererImpl 0x7fcfdc5ea7d0 cannot start driver: flushing 0 hasSuff 0 canStart 0 1 numAud 1
[fakepulse BOUNDARY ts=10:55:06.018] write_summary: bytes_written=8798208 ring_fill=2539520 calls=270 bytes_since=2211840 corked=1
[fakepulse] TIMING caller=update_timing_info stream=0x7fcfc47e78c0 corked=1 playing=0 bytes_written=8996736 fill=2443136 fill_input=2443136 write_index=8996736 read_index=6553600 since_underrun=3317601 sink_usec=6924988
08:55:06.418 I [f:478                           ] AudioRendererImpl 0x7fcfdc5ea7d0 cannot start driver: flushing 0 hasSuff 0 canStart 0 1 numAud 1
[fakepulse BOUNDARY ts=10:55:07.019] write_summary: bytes_written=9256960 ring_fill=2015232 calls=74 bytes_since=458752 corked=1
08:55:07.419 I [f:478                           ] AudioRendererImpl 0x7fcfdc5ea7d0 cannot start driver: flushing 0 hasSuff 0 canStart 0 1 numAud 1
[fakepulse BOUNDARY ts=10:55:08.020] write_summary: bytes_written=9666560 ring_fill=1441792 calls=70 bytes_since=409600 corked=1
[fakepulse] TIMING caller=update_timing_info stream=0x7fcfc47e78c0 corked=1 playing=0 bytes_written=9820000 fill=1300320 fill_input=1300320 write_index=9820000 read_index=8519680 since_underrun=5337671 sink_usec=3685714
08:55:08.421 I [f:478                           ] AudioRendererImpl 0x7fcfdc5ea7d0 cannot start driver: flushing 0 hasSuff 0 canStart 0 1 numAud 1
[fakepulse BOUNDARY ts=10:55:09.021] write_summary: bytes_written=10084352 ring_fill=876544 calls=71 bytes_since=417792 corked=1
08:55:09.422 I [f:478                           ] AudioRendererImpl 0x7fcfdc5ea7d0 cannot start driver: flushing 0 hasSuff 0 canStart 0 1 numAud 1
08:55:09.490 I [f:46                            ] Prefetch: key prefetched for track: spotify:track:1JSTJqkT5qHq8MDJnJbRE1 (file: 9e9d5dc5588e969a900085b1176cdfba0b47c05b)
[fakepulse BOUNDARY ts=10:55:10.023] write_summary: bytes_written=10502144 ring_fill=311296 calls=71 bytes_since=417792 corked=1
[fakepulse] TIMING caller=update_timing_info stream=0x7fcfc47e78c0 corked=1 playing=0 bytes_written=10642848 fill=157088 fill_input=157088 write_index=10642848 read_index=10485760 since_underrun=7358785 sink_usec=445260
08:55:10.423 I [f:478                           ] AudioRendererImpl 0x7fcfdc5ea7d0 cannot start driver: flushing 0 hasSuff 0 canStart 0 1 numAud 1
08:55:10.490 I [f:2769                          ] Update! reason: cached-key-provided, flags: 0x00
[fakepulse 10:55:10.573] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
[fakepulse 10:55:10.623] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
08:55:10.683 I [f:724                           ] Starting playback.
08:55:10.683 I [f:726                           ]     min limit 4000 ms.
08:55:10.683 I [f:727                           ]     compressed buffer: 1003172 bytes
08:55:10.683 I [f:729                           ]     decompressed buffer: 0 ms
08:55:10.683 I [f:731                           ]     sink buffer: 1022 ms
08:55:10.683 I [f:732                           ]     final source buffer: false
08:55:10.683 I [f:733                           ]     trystartplayback count: 0
08:55:10.683 I [f:888                           ] AudioBufferedSinkImpl::markStartPlayback(0x7fcfdc797c00): want now 4
[fakepulse 10:55:10.699] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
[fakepulse 10:55:10.749] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
[fakepulse 10:55:10.799] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
[fakepulse 10:55:10.850] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
08:55:10.882 I [f:724                           ] Starting playback.
08:55:10.882 I [f:726                           ]     min limit 4000 ms.
08:55:10.882 I [f:727                           ]     compressed buffer: 998762 bytes
08:55:10.882 I [f:729                           ]     decompressed buffer: 0 ms
08:55:10.882 I [f:731                           ]     sink buffer: 1012 ms
08:55:10.882 I [f:732                           ]     final source buffer: false
08:55:10.882 I [f:733                           ]     trystartplayback count: 0
08:55:10.882 I [f:888                           ] AudioBufferedSinkImpl::markStartPlayback(0x7fcfdc797c00): want now 5
[fakepulse 10:55:10.913] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
[fakepulse 10:55:10.963] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
[fakepulse 10:55:11.014] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
[fakepulse BOUNDARY ts=10:55:11.024] write_summary: bytes_written=10928128 ring_fill=6144 calls=75 bytes_since=425984 corked=1
[fakepulse 10:55:11.064] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
08:55:11.083 I [f:724                           ] Starting playback.
08:55:11.083 I [f:726                           ]     min limit 4000 ms.
08:55:11.083 I [f:727                           ]     compressed buffer: 994645 bytes
08:55:11.083 I [f:729                           ]     decompressed buffer: 0 ms
08:55:11.083 I [f:731                           ]     sink buffer: 1043 ms
08:55:11.083 I [f:732                           ]     final source buffer: false
08:55:11.083 I [f:733                           ]     trystartplayback count: 0
08:55:11.083 I [f:888                           ] AudioBufferedSinkImpl::markStartPlayback(0x7fcfdc797c00): want now 6
[fakepulse 10:55:11.114] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
[fakepulse 10:55:11.165] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
[fakepulse 10:55:11.215] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
[fakepulse 10:55:11.265] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
08:55:11.283 I [f:724                           ] Starting playback.
08:55:11.283 I [f:726                           ]     min limit 4000 ms.
08:55:11.283 I [f:727                           ]     compressed buffer: 990358 bytes
08:55:11.283 I [f:729                           ]     decompressed buffer: 0 ms
08:55:11.283 I [f:731                           ]     sink buffer: 1051 ms
08:55:11.283 I [f:732                           ]     final source buffer: false
08:55:11.283 I [f:733                           ]     trystartplayback count: 0
08:55:11.283 I [f:888                           ] AudioBufferedSinkImpl::markStartPlayback(0x7fcfdc797c00): want now 7
[fakepulse 10:55:11.315] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
[fakepulse 10:55:11.366] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
[fakepulse 10:55:11.416] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
08:55:11.424 I [f:478                           ] AudioRendererImpl 0x7fcfdc5ea7d0 cannot start driver: flushing 0 hasSuff 0 canStart 0 1 numAud 1
[fakepulse 10:55:11.466] underflow: ring empty, invoking underflow_cb
[fakepulse] pa_stream_cork(stream=0x7fcfc47e78c0, b=1)
08:55:11.482 I [f:724                           ] Starting playback.
08:55:11.482 I [f:726                           ]     min limit 4000 ms.
08:55:11.483 I [f:727                           ]     compressed buffer: 986258 bytes
08:55:11.483 I [f:729                           ]     decompressed buffer: 0 ms
08:55:11.483 I [f:731                           ]     sink buffer: 1015 ms
08:55:11.483 I [f:732                           ]     final source buffer: false
08:55:11.483 I [f:733                           ]     trystartplayback count: 0
08:55:11.483 I [f:888                           ] AudioBufferedSinkImpl::markStartPlayback(0x7fcfdc797c00): want now 8
[fakepulse 10:55:11.524] underflow: ring empty, invoking underflow_cb
NOISEONLYEOF
    close($nfh);

    my ($exit_b, $stdout_b, $stderr_b) = run_tool($cluster2_series_script,
        [ '__daemon_ticker_latest_gate', $noiseonly_fixture ]);
    is($exit_b, 0, 'cluster2-series-daemon-ticker-tail-depth: Test B hook exits 0')
        or diag("stderr: $stderr_b");
    is($stdout_b, '',
        'cluster2-series-daemon-ticker-tail-depth: Test B a genuinely ticker-less window (same real noise, Ticker line dropped) still reads empty -- the fix widens the lookback, it does not fabricate a match (regression guard)');

    unlink($ticker_fixture, $noiseonly_fixture);
};
}

# ============================================================
# subtest 'extract-run-queue-changed' -- 83.2-02 Task 1 (D-03).
# `queue_changed` fiel bisher in den else-Zweig ("anderer Typen"), weil
# rec_field() nur Skalare an einem Punkt-Pfad liest -- previous/upcoming
# sind jedoch Arrays (uid/source/item je Eintrag, 83.2-RESEARCH Abschnitt
# 4, verifiziert an extract-run.pl:1417-1419/1257-1269). D-03 fragt, ob
# `upcoming` am Titelende leer ist; das Werkzeug muss drei Zustaende
# unterscheiden koennen: 0 (leeres Array), FEHLT (Schluessel fehlt),
# KEIN_ARRAY (Schluessel vorhanden, aber kein Array) -- ein stummer undef
# wuerde genau diese Unterscheidung vernichten (Regel 2).
#
# Test A/B/F/G laufen gegen ECHTES Archivmaterial
# (t/fixtures/soloist/s04-connect-skip.jsonl, 64 Zeilen rohes dir/frame-
# Schema, 10 queue_changed-Frames, davon 3 mit leerem upcoming und 7
# gefuellt -- Werte hier aus der Datei selbst gezaehlt, nicht hart
# verdrahtet). Das Fenster wird aus der ersten/letzten ts der Datei
# abgeleitet (floor/ceil auf ganze Sekunden), ebenfalls nicht hart
# verdrahtet.
#
# Test C/D sind SYNTHETISCH (tempfile), weil kein Archivframe den
# upcoming-Schluessel weglaesst oder ihn als Nicht-Array traegt -- C nutzt
# die rohe dir/frame-Form (deckt den rohen Zweig der Action), D die flache
# type-Form (deckt den flachen Zweig).
#
# Test E ist die Geschwister-Gegenprobe: ein playback_changed-Frame,
# dessen `reason`-Feld den Text "queue_changed" traegt, und ein
# track_changed-Frame, dessen `item.name` ihn traegt, duerfen weder als
# queue_changed gezaehlt werden noch ein upcoming_n= tragen -- die
# Unterscheidung laeuft ueber das echte `type`-Feld, nicht ueber
# Substring-Suche im Frametext.
#
# SUDO_BIN=/bin/true wie bei extract-run-watchdog oben (unconditional sudo
# -n gate in main()).
# ============================================================
subtest 'extract-run-queue-changed' => sub {
    # -- Fenster aus s04-connect-skip.jsonl ableiten (erste/letzte ts) --
    my $s04_fixture = "$project_dir/t/fixtures/soloist/s04-connect-skip.jsonl";
    my @s04_ts;
    {
        open my $sfh, '<', $s04_fixture
            or die "extract-run-queue-changed: cannot read $s04_fixture: $!";
        while (my $line = <$sfh>) {
            push @s04_ts, $1 while $line =~ /"ts":"([0-9:.]+)"/g;
        }
        close $sfh;
    }
    my $min_ts = (sort @s04_ts)[0];
    my $max_ts = (sort @s04_ts)[-1];
    my $to_sec = sub {
        my ($ts) = @_;
        my ($h, $m, $s) = split /:/, $ts;
        return $h * 3600 + $m * 60 + $s;
    };
    my $to_hms = sub {
        my ($sec) = @_;
        my $h = int($sec / 3600); $sec -= $h * 3600;
        my $m = int($sec / 60);   $sec -= $m * 60;
        return sprintf('%02d:%02d:%02d', $h, $m, $sec);
    };
    my $win_t0 = $to_hms->(int($to_sec->($min_ts)));
    my $win_t1 = $to_hms->(int($to_sec->($max_ts)) + 1);

    # -- erwartete Zahlen aus der Fixture-Datei gezaehlt (Test F) --
    my $s04_text = do { local $/; open my $tfh, '<', $s04_fixture or die $!; <$tfh> };
    my $expected_qc_total  = () = $s04_text =~ /queue_changed/g;
    my $expected_qc_empty  = () = $s04_text =~ /\\"upcoming\\":\[\]/g;
    my $expected_qc_filled = $expected_qc_total - $expected_qc_empty;

    my (undef, $empty_server_log) = tempfile();

    # ---- Test A/B/F/G: echtes Archivmaterial ----
    my ($exit, $stdout, $stderr) = run_perl_tool($extract_run_script,
        [ 'aa:bb:cc:dd:ee:01', $win_t0, $win_t1,
          '--server-log', $empty_server_log, '--recorder', $s04_fixture ],
        SUDO_BIN => '/bin/true');
    is($exit, 0, 'extract-run-queue-changed: Z01 SUDO_BIN-Stub + leerer server-log laesst das Werkzeug normal durchlaufen (Exit 0)')
        or diag("stderr: $stderr");

    my @qc_lines = ($stdout =~ /^\@\S+ type=queue_changed[^\n]*/mg);
    is(scalar(@qc_lines), $expected_qc_total,
        "extract-run-queue-changed: Z02 Test F Anzahl der type=queue_changed-Zeilen = Anzahl im Fixture-Fenster ($expected_qc_total, aus der Datei gezaehlt)");

    my @filled_lines = grep { /upcoming_n=[1-9][0-9]*/ } @qc_lines;
    is(scalar(@filled_lines), $expected_qc_filled,
        "extract-run-queue-changed: Z03 Test A gefuellte upcoming_n-Zeilen = $expected_qc_filled (aus der Datei gezaehlt)");
    ok((grep { /upcoming_first=spotify:/ } @filled_lines),
        'extract-run-queue-changed: Z04 Test A mindestens eine gefuellte Zeile traegt upcoming_first=spotify:...');

    my @empty_lines = grep { /upcoming_n=0(?:\s|$)/ } @qc_lines;
    is(scalar(@empty_lines), $expected_qc_empty,
        "extract-run-queue-changed: Z05 Test B genau $expected_qc_empty Zeile(n) mit upcoming_n=0 (aus der Datei gezaehlt)");

    my @previous_n_lines = grep { /previous_n=[0-9]+/ } @qc_lines;
    is(scalar(@previous_n_lines), $expected_qc_total,
        'extract-run-queue-changed: Z06 previous_n ist auf JEDER queue_changed-Zeile zahlig vorhanden');

    unlike($stdout, qr/anderer Typen.*queue_changed=/,
        'extract-run-queue-changed: Z07 Test G Sammelzeile "anderer Typen" nennt queue_changed nicht mehr');

    # ---- Test C: synthetisch, roher Zweig, upcoming-Schluessel FEHLT ----
    {
        my ($fh, $recorder_file) = tempfile();
        print $fh '{"ts":"12:00:05.000","epoch":1,"dir":"rx","frame":"{\"type\":\"queue_changed\",\"previous\":[{\"uid\":\"x1\",\"source\":\"context\",\"item\":{\"uri\":\"spotify:track:AAA\"}}]}"}' . "\n";
        close $fh;

        my ($exit_c, $stdout_c, $stderr_c) = run_perl_tool($extract_run_script,
            [ 'aa:bb:cc:dd:ee:01', '12:00:00', '12:00:10',
              '--server-log', $empty_server_log, '--recorder', $recorder_file ],
            SUDO_BIN => '/bin/true');
        is($exit_c, 0, 'extract-run-queue-changed: Z08 Test C (FEHLT, roher Zweig) Exit 0')
            or diag("stderr: $stderr_c");
        like($stdout_c, qr/type=queue_changed.*upcoming_n=FEHLT/,
            'extract-run-queue-changed: Z09 Test C fehlender upcoming-Schluessel -> upcoming_n=FEHLT');
        like($stdout_c, qr/type=queue_changed.*previous_n=1/,
            'extract-run-queue-changed: Z10 Test C previous_n bleibt trotzdem zahlig (1)');
        unlink($recorder_file);
    }

    # ---- Test D: synthetisch, flacher Zweig, upcoming ist kein Array ----
    {
        my ($fh, $recorder_file) = tempfile();
        print $fh '{"ts":"12:00:06.000","type":"queue_changed","previous":[],"upcoming":"not-an-array"}' . "\n";
        close $fh;

        my ($exit_d, $stdout_d, $stderr_d) = run_perl_tool($extract_run_script,
            [ 'aa:bb:cc:dd:ee:01', '12:00:00', '12:00:10',
              '--server-log', $empty_server_log, '--recorder', $recorder_file ],
            SUDO_BIN => '/bin/true');
        is($exit_d, 0, 'extract-run-queue-changed: Z11 Test D (KEIN_ARRAY, flacher Zweig) Exit 0')
            or diag("stderr: $stderr_d");
        like($stdout_d, qr/type=queue_changed.*upcoming_n=KEIN_ARRAY/,
            'extract-run-queue-changed: Z12 Test D upcoming ist String statt Array -> upcoming_n=KEIN_ARRAY (Regel 2: nie stillschweigend verwerfen)');
        like($stdout_d, qr/type=queue_changed.*previous_n=0/,
            'extract-run-queue-changed: Z13 Test D previous_n=0 fuer leeres Array (unterscheidbar von FEHLT)');
        unlink($recorder_file);
    }

    # ---- Test E: Geschwister-Gegenprobe ----
    {
        my ($fh, $recorder_file) = tempfile();
        print $fh '{"ts":"12:00:05.000","type":"queue_changed","previous":[],"upcoming":[{"uid":"u1","source":"context","item":{"uri":"spotify:track:CCC"}}]}' . "\n";
        print $fh '{"ts":"12:00:06.000","type":"playback_changed","status":"playing","reason":"queue_changed"}' . "\n";
        print $fh '{"ts":"12:00:07.000","type":"track_changed","item":{"name":"queue_changed","uri":"spotify:track:DDD"}}' . "\n";
        close $fh;

        my ($exit_e, $stdout_e, $stderr_e) = run_perl_tool($extract_run_script,
            [ 'aa:bb:cc:dd:ee:01', '12:00:00', '12:00:10',
              '--server-log', $empty_server_log, '--recorder', $recorder_file ],
            SUDO_BIN => '/bin/true');
        is($exit_e, 0, 'extract-run-queue-changed: Z14 Test E (Geschwister-Gegenprobe) Exit 0')
            or diag("stderr: $stderr_e");

        my @qc_lines_e = ($stdout_e =~ /^\@\S+ type=queue_changed[^\n]*/mg);
        is(scalar(@qc_lines_e), 1,
            'extract-run-queue-changed: Z15 Test E genau EINE queue_changed-Zeile trotz zweier Geschwisterzeilen mit dem Wortlaut im Feldwert');

        my ($pc_line) = ($stdout_e =~ /^\@\S+ type=playback_changed[^\n]*/m);
        ok(defined $pc_line,
            'extract-run-queue-changed: Z16 Test E playback_changed-Zeile erscheint als eigener Typ');
        unlike($pc_line // '', qr/upcoming_n=/,
            'extract-run-queue-changed: Z17 Test E playback_changed-Zeile traegt kein upcoming_n=');

        my ($tc_line) = ($stdout_e =~ /^\@\S+ type=track_changed[^\n]*/m);
        ok(defined $tc_line,
            'extract-run-queue-changed: Z18 Test E track_changed-Zeile erscheint als eigener Typ');
        unlike($tc_line // '', qr/upcoming_n=/,
            'extract-run-queue-changed: Z19 Test E track_changed-Zeile traegt kein upcoming_n=');

        unlink($recorder_file);
    }

    unlink($empty_server_log);
};

# ============================================================
# subtest 'extract-run-getnexttrack' -- 83.2-03 orchestrator finding
# (Live-Klassifikation hang=nein ist unerreichbar).
#
# e-verbose-boundary.sh:436-441 classifies hang=nein by grepping
# extract-run.pl's OWN output for "getNextTrack" -- but @SRV_CATS never
# had a getNextTrack category, so the event fell into the collective "in
# keiner Kategorie" bucket and every healthy boundary read hang=unbestimmt
# (never hang=nein). Confirmed against RUN 4's own g=1/g=2 windows: the
# raw server-window has 1 getNextTrack hit each, extract-g1.txt/
# extract-g2.txt have 0. H1's judgment rule in 83.2-03-PLAN.md forces
# UNENTSCHEIDBAR whenever N_UNBESTIMMT >= 1 -- with hang=nein unreachable,
# every healthy boundary poisons H1, and the gate passes anyway (same
# "formal gruen, sachlich leer" failure class as Blocker 1, different
# door).
#
# Source: Plugins::SpotOn::ProtocolHandler::getNextTrack (718) -- LMS
# asking SpotOn for the next track's metadata, the [DIAG] line SpotOn
# itself emits. Deliberately NOT covered: Slim::Player::StreamingController
# ::_getNextTrack (698, LMS-internal "Loading metadata" line, different
# class+method) and ProtocolHandler::getNextTrack (896, the sibling
# "soloist browse -> Control->requestTrack(...)" dispatch-echo line,
# different line number). The (718) literal in the pattern already
# disambiguates all three -- no line number collision is possible.
#
# Fixture: a verbatim excerpt of six consecutive lines from
# ~/SynologyDrive/dev/spoton-messdaten/83.2-00-messung-d-archiv-260923/messung-d-server-1320-1346.log
# (lines 1136-1141, Messung D grenze 1, "Same Old" -> "Glorious") --
# real archive material, not synthesized (orchestrator instruction:
# "Kein selbstgebautes Log"). Carries all three getNextTrack forms plus
# one Control:dispatch baseline line already covered by an existing
# category, so the negative checks (Z03/Z04) and the baseline-untouched
# check (Z06) are against real neighbours, not invented ones.
#
# SUDO_BIN=/bin/true as in extract-run-watchdog/extract-run-queue-changed
# above (unconditional sudo -n gate in main()).
# ============================================================
subtest 'extract-run-getnexttrack' => sub {
    my ($fh, $file) = tempfile();
    print $fh "[26-09-23 13:21:43.2833] Slim::Player::StreamingController::_getNextTrack (698) Loading metadata for spoton://track:0aPRKH8FlhwyTw6z0TFCqx\n";
    print $fh "[26-09-23 13:21:43.2838] Slim::Player::StreamingController::_playersMessage (802) Streaminfos werden geladen...: spoton://track:0aPRKH8FlhwyTw6z0TFCqx\n";
    print $fh "[26-09-23 13:21:43.2839] Slim::Player::Song::getNextSong (224) spoton://track:0aPRKH8FlhwyTw6z0TFCqx\n";
    print $fh "[26-09-23 13:21:43.2840] Plugins::SpotOn::ProtocolHandler::getNextTrack (718) [DIAG] getNextTrack: mac=02:00:00:5a:11:01 url=spoton://track:0aPRKH8FlhwyTw6z0TFCqx\n";
    print $fh "[26-09-23 13:21:43.2841] Plugins::SpotOn::ProtocolHandler::getNextTrack (896) getNextTrack: soloist browse -> Control->requestTrack(spoton://track:0aPRKH8FlhwyTw6z0TFCqx, 0) (mac=02:00:00:5a:11:01)\n";
    print $fh "[26-09-23 13:21:43.2842] Plugins::SpotOn::Soloist::Control::_dispatch (1496) Control: dispatch play armed=1 uri=spotify:track:0aPRKH8FlhwyTw6z0TFCqx (02:00:00:5a:11:01)\n";
    close($fh);

    my ($exit, $stdout, $stderr) = run_perl_tool($extract_run_script,
        [ '02:00:00:5a:11:01', '13:21:40', '13:21:50',
          '--server-log', $file, '--date', '2026-09-23' ],
        SUDO_BIN => '/bin/true');

    is($exit, 0, 'extract-run-getnexttrack: Z01 SUDO_BIN-Stub laesst das Werkzeug normal durchlaufen (Exit 0)')
        or diag("stderr: $stderr");

    my $section_body = sub {
        my ($hdr_re) = @_;
        return ($stdout =~ /---\s*\Q$hdr_re\E.*?---\n(.*?)(?=\n---|\z)/s) ? $1 : '';
    };

    my $gnt_body      = $section_body->('server.log: ProtocolHandler::getNextTrack (718');
    my $dispatch_body = $section_body->('server.log: Control: dispatch');

    like($gnt_body, qr/ProtocolHandler::getNextTrack \(718\) \[DIAG\] getNextTrack: mac=02:00:00:5a:11:01 url=spoton:\/\/track:0aPRKH8FlhwyTw6z0TFCqx/,
        'extract-run-getnexttrack: Z02 die (718)-Zeile erscheint in der neuen Kategorie');
    like($stdout, qr/^--- server\.log: ProtocolHandler::getNextTrack \(718[^\n]*\(Anzahl: 1 im Fenster/m,
        'extract-run-getnexttrack: Z03 Kopfzeile traegt Anzahl 1 (count => 1)');

    unlike($gnt_body, qr/_getNextTrack \(698\)/,
        'extract-run-getnexttrack: Z04 Geschwisterzeile StreamingController::_getNextTrack (698) bleibt draussen (andere Klasse+Methode)');
    unlike($gnt_body, qr/\(896\)/,
        'extract-run-getnexttrack: Z05 Geschwisterzeile ProtocolHandler::getNextTrack (896, Dispatch-Echo) bleibt draussen (andere Zeilennummer)');

    like($dispatch_body, qr/Control: dispatch play armed=1/,
        'extract-run-getnexttrack: Z06 Altkategorie (Control: dispatch) unveraendert -- Baseline-Erhalt');
    unlike($dispatch_body, qr/getNextTrack/,
        'extract-run-getnexttrack: Z07 Altkategorie-Zeile faellt nicht in die neue getNextTrack-Kategorie');

    # 6 Zeilen im Fenster: 4 bereits vorher kategorisiert (698-Zeile faellt
    # in keine bestehende Kategorie -> Restzaehler VOR dem Fix waere 3: die
    # (718)-, (896)- und (698)-Zeile; NACH dem Fix nur noch 2: (896) und
    # (698) bleiben unkategorisiert, die drei uebrigen (_playersMessage,
    # getNextSong, Control:dispatch) sind durch KEINE bestehende Kategorie
    # gedeckt -- exakte Arithmetik gegen die neue Kategorie allein zu
    # pruefen waere fragil, deshalb Z08 nur als Selbsttest-Stummheit statt
    # als exakter Zaehler.
    unlike($stdout, qr/Restzaehler-Selbsttest[^\n]*FEHLGESCHLAGEN/,
        'extract-run-getnexttrack: Z08 Restzaehler-Selbsttest bleibt stumm');

    unlink($file);
};

# ============================================================
# 84-11 pre-3b (2026-10-13): the (718) literal above was the PRE-seam source
# line. The seam (84-07/08/12/13) moved the same [DIAG] emit to
# ProtocolHandler.pm:535; with the literal pinned, the category read 0 on
# every post-seam log and the D-08 compare reported
# `count[...getNextTrack (718...)] before=1 after=0` in browse_play and
# connect_transfer (84-D08-BASELINE.md "## D-08 deviations" item 1) --
# tool-caused, not a seam effect. The match must be line-number-agnostic;
# the `[DIAG] getNextTrack: mac=` tail alone disambiguates from the (896)
# dispatch-echo sibling (which never carries that tail).
#
# Fixture: (a) the (535) line in the form the live post-seam server.log
# emits (/var/log/squeezeboxserver/server.log, 2026-10-13, 35/35 DIAG
# lines carry (535), 0 carry any other number); (b) the (896) sibling
# verbatim from the Messung-D archive (messung-d-server-1320-1346.log:1140)
# -- the post-seam tree no longer emits that line, so no live/rotated log
# of 2026-10-07..13 carries it; the archive line is the only real source.
#
# RED proof: with the (718) literal still in place this subtest fails on
# P02/P03 (category empty, Anzahl 0) -- see 84-11 pre-3b scratch
# prove-red.log.
# ============================================================
subtest 'extract-run-getnexttrack-postseam-linenum' => sub {
    my ($fh, $file) = tempfile();
    print $fh "[26-10-13 11:31:37.6882] Plugins::SpotOn::ProtocolHandler::getNextTrack (535) [DIAG] getNextTrack: mac=02:00:00:5a:11:01 url=spoton://track:AAAA\n";
    print $fh "[26-10-13 11:31:37.6890] Plugins::SpotOn::ProtocolHandler::getNextTrack (896) getNextTrack: soloist browse -> Control->requestTrack(spoton://track:AAAA, 0) (mac=02:00:00:5a:11:01)\n";
    close($fh);

    my ($exit, $stdout, $stderr) = run_perl_tool($extract_run_script,
        [ '02:00:00:5a:11:01', '11:31:35', '11:31:45',
          '--server-log', $file, '--date', '2026-10-13' ],
        SUDO_BIN => '/bin/true');

    is($exit, 0, 'extract-run-getnexttrack-postseam: P01 SUDO_BIN-Stub laesst das Werkzeug normal durchlaufen (Exit 0)')
        or diag("stderr: $stderr");

    my $section_body = sub {
        my ($hdr_re) = @_;
        return ($stdout =~ /---\s*\Q$hdr_re\E.*?---\n(.*?)(?=\n---|\z)/s) ? $1 : '';
    };
    my $gnt_body = $section_body->('server.log: ProtocolHandler::getNextTrack (718');

    like($gnt_body, qr/ProtocolHandler::getNextTrack \(535\) \[DIAG\] getNextTrack: mac=02:00:00:5a:11:01 url=spoton:\/\/track:AAAA/,
        'extract-run-getnexttrack-postseam: P02 die post-seam (535)-Zeile erscheint in der Kategorie (Kopfzeile behaelt das historische "718")');
    like($stdout, qr/^--- server\.log: ProtocolHandler::getNextTrack \(718[^\n]*\(Anzahl: 1 im Fenster/m,
        'extract-run-getnexttrack-postseam: P03 Kopfzeile traegt Anzahl 1 -- genau die (535)-Zeile, nicht die (896)-Zeile');
    unlike($gnt_body, qr/\(896\)/,
        'extract-run-getnexttrack-postseam: P04 Geschwisterzeile (896, Dispatch-Echo ohne "[DIAG] getNextTrack: mac=") bleibt draussen');
    unlike($gnt_body, qr/requestTrack/,
        'extract-run-getnexttrack-postseam: P05 Dispatch-Echo-Text taucht im Kategorierumpf nicht auf');
    unlike($stdout, qr/Restzaehler-Selbsttest[^\n]*FEHLGESCHLAGEN/,
        'extract-run-getnexttrack-postseam: P06 Restzaehler-Selbsttest bleibt stumm');

    unlink($file);
};

# ============================================================
# subtest 'extract-run-connect-advance' -- 83.1-06 Task 1 (D-C2).
# Three additive categories distinguish "change dropped by the connect-guard,
# rescued a moment later by resume" (BEFORE the D-C1 dispatch fix -- the
# mechanism 83-MESSUNG-C.md documents, 18 dropped `change` vs 18 `resume`
# re-entries, 1:1) from "change itself dispatches the switch" (AFTER).
#
# Sources: Connect.pm:1574-1578 (drop, change branch), Connect.pm:1586-1588
# (`Track change:` dispatch line, past the guard), Connect.pm:1268-1271
# (resume re-entry). L3 carries the SAME double-encoded em-dash byte
# sequence \xc3\xa2\xc2\x80\xc2\x94 server.log actually stores (precedent:
# extract-run-watchdog above) -- a pattern with a literal dash character
# would silently match nothing.
#
# L4 is a deliberate negative: the seek-drop line at Connect.pm:1177
# ("Dropping Connect seek event ...") must NOT fall into the change-drop
# category -- the pattern is anchored on "change", not just "Dropping
# Connect ... event".
#
# SUDO_BIN=/bin/true as in the other extract-run-* subtests above
# (unconditional sudo -n gate in main()).
# ============================================================
subtest 'extract-run-connect-advance' => sub {
    my ($fh, $file) = tempfile();
    print $fh "[26-09-24 10:00:01.0000] Plugins::SpotOn::Connect::_connectEvent (1576) Dropping Connect change event for non-Connect player aa:bb:cc:dd:ee:01 (connect-guard)\n";
    print $fh "[26-09-24 10:00:02.0000] Plugins::SpotOn::Connect::_connectEvent (1587) Track change: A -> B\n";
    print $fh "[26-09-24 10:00:03.0000] Plugins::SpotOn::Connect::_connectEvent (1270) Resume while not on Connect stream \xc3\xa2\xc2\x80\xc2\x94 re-entering Connect via playlist play\n";
    print $fh "[26-09-24 10:00:04.0000] Plugins::SpotOn::Connect::_connectEvent (1177) Dropping Connect seek event for non-Connect player aa:bb:cc:dd:ee:01 (connect-guard)\n";
    print $fh "[26-09-24 10:00:05.0000] Slim::Player::StreamingController::playerTrackStarted (2253) aa:bb:cc:dd:ee:01\n";
    print $fh "[26-09-24 10:00:06.0000] Plugins::SpotOn::Soloist::Control::_recordErrorOnce (3086) aa:bb:cc:dd:ee:01: watchdog forced skip (round 2: unknown)\n";
    close($fh);

    my ($exit, $stdout, $stderr) = run_perl_tool($extract_run_script,
        [ 'aa:bb:cc:dd:ee:01', '10:00:00', '10:00:10',
          '--server-log', $file, '--date', '2026-09-24' ],
        SUDO_BIN => '/bin/true');

    my $section_body = sub {
        my ($hdr_re) = @_;
        return ($stdout =~ /---\s*\Q$hdr_re\E.*?---\n(.*?)(?=\n---|\z)/s) ? $1 : '';
    };

    my $drop_body     = $section_body->('server.log: Connect change verworfen');
    my $dispatch_body = $section_body->('server.log: Track change (Connect');
    my $resume_body   = $section_body->('server.log: Resume-Wiedereinstieg');
    my $baseline_body = $section_body->('server.log: playerTrackStarted / playerStopped / new state');

    is($exit, 0, 'extract-run-connect-advance: Z01 SUDO_BIN-Stub laesst das Werkzeug normal durchlaufen (Exit 0)')
        or diag("stderr: $stderr");

    like($drop_body, qr/Dropping Connect change event for non-Connect player aa:bb:cc:dd:ee:01/,
        'extract-run-connect-advance: Z02 die change-Drop-Zeile erscheint in der neuen Kategorie');
    like($stdout, qr/^--- server\.log: Connect change verworfen[^\n]*\(Anzahl: 1 im Fenster/m,
        'extract-run-connect-advance: Z03 Drop-Kopfzeile traegt Anzahl 1 (count => 1)');

    like($dispatch_body, qr/Track change: A -> B/,
        'extract-run-connect-advance: Z04 die Track-change-Dispatch-Zeile erscheint in der neuen Kategorie');
    like($stdout, qr/^--- server\.log: Track change \(Connect[^\n]*\(Anzahl: 1 im Fenster/m,
        'extract-run-connect-advance: Z05 Dispatch-Kopfzeile traegt Anzahl 1 (count => 1)');

    like($resume_body, qr/Resume while not on Connect stream.*re-entering Connect via playlist play/,
        'extract-run-connect-advance: Z06 die Resume-Wiedereinstiegszeile (doppelt-kodierter em dash) erscheint in der neuen Kategorie');
    like($stdout, qr/^--- server\.log: Resume-Wiedereinstieg[^\n]*\(Anzahl: 1 im Fenster/m,
        'extract-run-connect-advance: Z07 Resume-Kopfzeile traegt Anzahl 1 (count => 1)');

    unlike($drop_body, qr/Dropping Connect seek event/,
        'extract-run-connect-advance: Z08 Negativ -- der seek-Drop (L4) faellt NICHT in die change-Drop-Kategorie');
    unlike($dispatch_body, qr/Dropping Connect/,
        'extract-run-connect-advance: Z09 Drop-Wortlaut nicht in der Dispatch-Kategorie');
    unlike($resume_body, qr/Track change:/,
        'extract-run-connect-advance: Z10 Dispatch-Wortlaut nicht in der Resume-Kategorie');

    like($baseline_body, qr/playerTrackStarted/,
        'extract-run-connect-advance: Z11 Altkategorie unveraendert (Baseline-Erhalt)');
    unlike($drop_body, qr/playerTrackStarted/,
        'extract-run-connect-advance: Z12 Altkategorie-Zeile faellt nicht in die neuen Kategorien');

    like($stdout, qr/von den Fensterzeilen 2 in keiner Kategorie/,
        'extract-run-connect-advance: Z13 Restzaehler-Arithmetik -- 6 Zeilen, 4 kategorisiert (Drop/Dispatch/Resume/Baseline), 2 im Topf (seek-Drop L4, _recordErrorOnce-Echo L6)');
    unlike($stdout, qr/Restzaehler-Selbsttest[^\n]*FEHLGESCHLAGEN/,
        'extract-run-connect-advance: Z14 Restzaehler-Selbsttest bleibt stumm');

    unlink($file);
};

# ============================================================
# subtest 'extract-run-plain-hyphen' -- quick 261018-cp5.
# Quick 261018-cp5 replaced the long dash in SpotOn's log strings with a
# plain hyphen. The two category patterns extract-run.pl:263 (watchdog
# handoff) and :350 (Resume re-entry) bridge the dash with `.*`, so they
# accept both forms. This subtest pins that the NEW form (plain hyphen,
# ASCII only) is categorised, while 'extract-run-watchdog' and
# 'extract-run-connect-advance' keep the OLD double-encoded recordings.
#
# SUDO_BIN=/bin/true as in the sibling subtests (unconditional sudo -n
# gate in main()).
# ============================================================
subtest 'extract-run-plain-hyphen' => sub {
    my ($fh, $file) = tempfile();
    print $fh "[26-10-18 10:00:01.0000] Plugins::SpotOn::Plugin::_prefetchHangCheck (4185) Prefetch watchdog: still on same track after 10s past end - handing to Soloist::Control (D-02)\n";
    print $fh "[26-10-18 10:00:02.0000] Plugins::SpotOn::Connect::_connectEvent (1919) Resume while not on Connect stream - re-entering Connect via playlist play\n";
    close($fh);

    my ($exit, $stdout, $stderr) = run_perl_tool($extract_run_script,
        [ 'aa:bb:cc:dd:ee:01', '10:00:00', '10:00:10',
          '--server-log', $file, '--date', '2026-10-18' ],
        SUDO_BIN => '/bin/true');

    is($exit, 0, 'extract-run-plain-hyphen: Z01 SUDO_BIN-Stub laesst das Werkzeug normal durchlaufen (Exit 0)')
        or diag("stderr: $stderr");

    like($stdout, qr/^--- server\.log: Prefetch watchdog -> Soloist::Control[^\n]*\(Anzahl: 1 im Fenster/m,
        'extract-run-plain-hyphen: Z02 Watchdog-Zeile mit einfachem Bindestrich wird kategorisiert (Anzahl 1)');
    like($stdout, qr/^--- server\.log: Resume-Wiedereinstieg[^\n]*\(Anzahl: 1 im Fenster/m,
        'extract-run-plain-hyphen: Z03 Resume-Zeile mit einfachem Bindestrich wird kategorisiert (Anzahl 1)');

    unlink($file);
};

# ============================================================
# subtest 'extract-run-connect-advance-archive' -- 83.1-06 Task 1 (D-C2),
# real-archive companion to 'extract-run-connect-advance' above (memory
# `trockenlauf-synthetisch-belegt-nur-die-formel`: a synthetic-only test
# proves the tool's own regex, never that the regex matches real log
# material). Fixture: t/fixtures/uat/83.1-messung-c-connect-guard.log,
# an excerpt of a real 2026-09-22 server.log (see t/fixtures/uat/README.md
# for provenance/sha256). It carries the BEFORE-code signature: change
# dropped and rescued by resume, never dispatched directly (0 `Track
# change:` lines) -- the exact pattern 83-MESSUNG-C.md:753-790 documents.
# ============================================================
subtest 'extract-run-connect-advance-archive' => sub {
    my $fixture = "$project_dir/t/fixtures/uat/83.1-messung-c-connect-guard.log";

    my ($exit, $stdout, $stderr) = run_perl_tool($extract_run_script,
        [ '02:00:00:5a:11:01', '12:25:19', '12:52:27',
          '--server-log', $fixture, '--date', '2026-09-22' ],
        SUDO_BIN => '/bin/true');

    is($exit, 0, 'extract-run-connect-advance-archive: Z01 SUDO_BIN-Stub laesst das Werkzeug normal durchlaufen (Exit 0)')
        or diag("stderr: $stderr");

    like($stdout, qr/^--- server\.log: Connect change verworfen[^\n]*\(Anzahl: 2 im Fenster/m,
        'extract-run-connect-advance-archive: Z02 change-Drop-Kopfzeile Anzahl >= 2 (BEFORE-Signatur, 83-MESSUNG-C.md:768-769)');
    like($stdout, qr/\[MUSTER NICHT GEFUNDEN IM FENSTER\] server\.log: Track change \(Connect/,
        'extract-run-connect-advance-archive: Z03 Track-change-Dispatch-Kategorie Anzahl 0 -- vor dem D-C1-Fix dispatchte `change` nie direkt');
    like($stdout, qr/^--- server\.log: Resume-Wiedereinstieg[^\n]*\(Anzahl: 1 im Fenster/m,
        'extract-run-connect-advance-archive: Z04 Resume-Wiedereinstiegs-Kopfzeile Anzahl >= 1 -- der Umweg, der den Wechsel tatsaechlich ausloeste');

    unlike($stdout, qr/Restzaehler-Selbsttest[^\n]*FEHLGESCHLAGEN/,
        'extract-run-connect-advance-archive: Z05 Restzaehler-Selbsttest bleibt stumm');
};

# ============================================================
# subtest 'measure-reannounce-latency-wr03' -- 82-41 Task 3 (R9-WR-03).
# compute_latency_stats is `require`-isolated from
# tools/uat/measure-reannounce-latency.pl's real measurement loop
# (run_measurement_loop, guarded by `unless caller`) -- this test calls it
# directly with SYNTHETIC arrays, reaching the status=GRENZWERT_VERFEHLT
# branch that real live runs practically never hit (dispatch_ms is always
# microseconds in practice, never near the 9.0ms threshold).
#
# FindBin note: measure-reannounce-latency.pl (and the
# tools/soloist-ws-record.pl it in turn `require`s) resolves its own
# relative `use lib`/`require` paths off $RealBin, which FindBin computes
# from $0 the FIRST time FindBin loads in a process. t/46_uat_tools.t never
# loads FindBin before this point, so $0 MUST be set to the script's own
# path before this require -- otherwise $RealBin resolves against t/'s
# location and the nested require/use lib silently point at the wrong
# directories.
#
# Package-isolation note: the require runs inside a dedicated package
# (MeasureReannounceLatencyWR03), NOT main::. Both required scripts define
# their own `sub fail` (an abort-and-exit helper, unrelated to
# Test::More's exported `fail($name)` test assertion) -- requiring them
# into main:: would silently clobber Test::More's fail() for the REST of
# this test file's process lifetime (a later `fail(...)` call meant as a
# test assertion would instead call soloist-ws-record.pl's `exit()`-based
# helper). Isolating into its own package keeps every symbol the two
# scripts define out of main::'s namespace.
# ============================================================
subtest 'measure-reannounce-latency-wr03' => sub {
    {
        package MeasureReannounceLatencyWR03;
        local $0 = $measure_reannounce_script;
        require $measure_reannounce_script;
    }

    # Positive probe: a synthetic, realistic-fast dispatch_ms array (mean
    # AND median both well under 9.0) must report status=OK.
    my $fast = MeasureReannounceLatencyWR03::compute_latency_stats(
        [0.02, 0.03, 0.04, 0.05, 0.06],
        [10.0, 12.0, 11.0, 9.5, 10.5],
        3,
    );
    is($fast->{status}, 'OK',
        'measure-reannounce-latency-wr03: schnelles synthetisches dispatch_ms-Array -> status=OK');

    # Negative probe (the branch that was practically unreachable before
    # this extraction): a synthetic, slow dispatch_ms array (mean AND
    # median both >= 9.0) must report status=GRENZWERT_VERFEHLT.
    my $slow = MeasureReannounceLatencyWR03::compute_latency_stats(
        [9.1, 9.2, 9.3, 9.4, 9.5],
        [10.0, 12.0, 11.0, 9.5, 10.5],
        3,
    );
    is($slow->{status}, 'GRENZWERT_VERFEHLT',
        'measure-reannounce-latency-wr03: langsames synthetisches dispatch_ms-Array -> status=GRENZWERT_VERFEHLT (vorher praktisch unerreichbar)');

    # roundtrip_ms is now reported, not silently discarded (the previous
    # code captured $2 from the REANFORDERUNG-OK match but never stored it).
    ok(defined $fast->{roundtrip_mean} && $fast->{roundtrip_mean} > 0,
        'measure-reannounce-latency-wr03: roundtrip_mean wird berichtet, nicht mehr stillschweigend verworfen');
    is(sprintf('%.1f', $fast->{roundtrip_mean}), '10.6',
        'measure-reannounce-latency-wr03: roundtrip_mean ist korrekt aus roundtrip_ms berechnet (Mittelwert von 10.0,12.0,11.0,9.5,10.5)');

    # Too few valid repetitions must still fail even with fast dispatch_ms
    # -- status is not ONLY a dispatch_ms threshold check.
    my $too_few = MeasureReannounceLatencyWR03::compute_latency_stats([0.02, 0.03], [10.0, 11.0], 3);
    is($too_few->{status}, 'GRENZWERT_VERFEHLT',
        'measure-reannounce-latency-wr03: zu wenige gueltige Wiederholungen -> status=GRENZWERT_VERFEHLT trotz schnellem dispatch_ms');
};

# ============================================================
# subtest 'extract-run-reannounce' -- 260914-qn1 Task 3. Names the
# REANFORDERUNG acknowledgement value as its own subsection of
# section_recorder's Recorder report, additive to the existing generic
# meta-line block. Four cases: OK-with-values, UNGUELTIG-with-reason,
# absent-but-decidable (HANDSHAKE-OK seen, no flag given -- a DERIVATION,
# not a guess), and absent-and-undecidable (no HANDSHAKE-OK at all -- the
# tool must never claim a reannouncement failed when it cannot tell
# whether one was ever attempted).
#
# Each case gets its own synthetic recorder JSONL fixture (one JSON object
# per line, {ts, epoch, dir, frame} shape matching
# tools/soloist-ws-record.pl's real jsonl_line output) plus an EMPTY
# --server-log temp file (0 bytes is a legitimate, non-aborting input --
# confirmed by section_recorder's own "0 Bytes" branch).
# ============================================================
subtest 'extract-run-reannounce' => sub {
    my $write_fixture = sub {
        my (@lines) = @_;
        my ($fh, $file) = tempfile();
        print $fh "$_\n" for @lines;
        close($fh);
        return $file;
    };

    # Case 1: REANFORDERUNG OK -- dispatch_ms/roundtrip_ms surfaced by name.
    {
        my $recorder_file = $write_fixture->(
            '{"ts":"12:00:05.000","epoch":1,"dir":"meta","frame":"REANFORDERUNG OK dispatch_ms=1.234 roundtrip_ms=5.678"}'
        );
        my $empty_server_log = $write_fixture->();

        my ($exit, $stdout, $stderr) = run_perl_tool($extract_run_script,
            [ 'aa:bb:cc:dd:ee:01', '12:00:00', '12:00:10',
              '--server-log', $empty_server_log, '--recorder', $recorder_file ],
            SUDO_BIN => '/bin/true');
        is($exit, 0, 'extract-run-reannounce: Case 1 (OK) laesst das Werkzeug normal durchlaufen (Exit 0)')
            or diag("stderr: $stderr");
        like($stdout, qr/\[REANFORDERUNG-Zeilen des Recorders/,
            'extract-run-reannounce: Case 1 (OK) hat die neue benannte Unterrubrik');
        like($stdout, qr/dispatch_ms=1\.234/,
            'extract-run-reannounce: Case 1 (OK) nennt dispatch_ms explizit');
        like($stdout, qr/roundtrip_ms=5\.678/,
            'extract-run-reannounce: Case 1 (OK) nennt roundtrip_ms explizit');

        unlink($recorder_file, $empty_server_log);
    }

    # Case 2: REANFORDERUNG UNGUELTIG -- the reason (<grund>) surfaced by name.
    {
        my $recorder_file = $write_fixture->(
            '{"ts":"12:00:05.000","epoch":1,"dir":"meta","frame":"REANFORDERUNG UNGUELTIG: LMS-Socket nicht verbindbar: Connection refused"}'
        );
        my $empty_server_log = $write_fixture->();

        my ($exit, $stdout, $stderr) = run_perl_tool($extract_run_script,
            [ 'aa:bb:cc:dd:ee:01', '12:00:00', '12:00:10',
              '--server-log', $empty_server_log, '--recorder', $recorder_file ],
            SUDO_BIN => '/bin/true');
        is($exit, 0, 'extract-run-reannounce: Case 2 (UNGUELTIG) laesst das Werkzeug normal durchlaufen (Exit 0)')
            or diag("stderr: $stderr");
        like($stdout, qr/\[REANFORDERUNG-Zeilen des Recorders/,
            'extract-run-reannounce: Case 2 (UNGUELTIG) hat die neue benannte Unterrubrik');
        like($stdout, qr/LMS-Socket nicht verbindbar/,
            'extract-run-reannounce: Case 2 (UNGUELTIG) nennt den Grund');

        unlink($recorder_file, $empty_server_log);
    }

    # Case 3a: HANDSHAKE-OK seen, zero REANFORDERUNG lines -- the DECIDABLE
    # "recorder ran without --reannounce-lms" reading. Must NOT land in the
    # undecidable branch.
    {
        my $recorder_file = $write_fixture->(
            '{"ts":"12:00:05.000","epoch":1,"dir":"meta","frame":"HANDSHAKE-OK"}'
        );
        my $empty_server_log = $write_fixture->();

        my ($exit, $stdout, $stderr) = run_perl_tool($extract_run_script,
            [ 'aa:bb:cc:dd:ee:01', '12:00:00', '12:00:10',
              '--server-log', $empty_server_log, '--recorder', $recorder_file ],
            SUDO_BIN => '/bin/true');
        is($exit, 0, 'extract-run-reannounce: Case 3a (decidable) laesst das Werkzeug normal durchlaufen (Exit 0)')
            or diag("stderr: $stderr");
        like($stdout, qr/keine REANFORDERUNG-Zeile im Mitschnitt/,
            'extract-run-reannounce: Case 3a meldet die fehlende REANFORDERUNG-Zeile');
        like($stdout, qr/HANDSHAKE-OK.*ohne --reannounce-lms/,
            'extract-run-reannounce: Case 3a leitet "ohne --reannounce-lms" aus HANDSHAKE-OK ab');
        unlike($stdout, qr/nicht entscheidbar/,
            'extract-run-reannounce: Case 3a landet NICHT im undecidable-Zweig');

        unlink($recorder_file, $empty_server_log);
    }

    # Case 3b: zero meta lines at all (mirrors a real mitschnitt that hit
    # HANDSHAKE-TIMEOUT/EOF/ERROR before the handshake) -- the UNDECIDABLE
    # case. Must NOT land in the decidable "never sent" branch.
    {
        my $recorder_file = $write_fixture->(
            '{"ts":"12:00:05.000","epoch":1,"dir":"tx","frame":"{\"type\":\"unrelated\"}"}'
        );
        my $empty_server_log = $write_fixture->();

        my ($exit, $stdout, $stderr) = run_perl_tool($extract_run_script,
            [ 'aa:bb:cc:dd:ee:01', '12:00:00', '12:00:10',
              '--server-log', $empty_server_log, '--recorder', $recorder_file ],
            SUDO_BIN => '/bin/true');
        is($exit, 0, 'extract-run-reannounce: Case 3b (undecidable) laesst das Werkzeug normal durchlaufen (Exit 0)')
            or diag("stderr: $stderr");
        like($stdout, qr/keine REANFORDERUNG-Zeile im Mitschnitt UND kein HANDSHAKE-OK/,
            'extract-run-reannounce: Case 3b meldet fehlende REANFORDERUNG-Zeile UND fehlendes HANDSHAKE-OK');
        like($stdout, qr/nicht entscheidbar/,
            'extract-run-reannounce: Case 3b landet im undecidable-Zweig');
        unlike($stdout, qr/ohne --reannounce-lms/,
            'extract-run-reannounce: Case 3b landet NICHT im decidable "nie gesendet"-Zweig');

        unlink($recorder_file, $empty_server_log);
    }
};

# ============================================================
# arm-after-restart.sh subtest -- Quick 260915-bpd Task 3. Both cases route
# WS_PATH at a nonexistent sibling of the SUDO_BIN passthrough stub (neither
# cares about the window value itself, both must still route ws_mtime()'s
# stat call away from the real live rig).
# ============================================================
subtest 'arm-after-restart' => sub {
    my $stubdir = tempdir(CLEANUP => 1);
    my $sudo_stub = write_sudo_passthrough_stub($stubdir);
    my $unused_ws_path = "$stubdir/unused-ws.port";

    # Case 1 (NICHT ANWENDBAR): --no-restart, alle sechs Kategorien
    # bestaetigen. Rueckbau: der --no-restart-Fruehausstieg (Quellzeilen
    # 61-65) entfernt oder in den AFTER-vs-BEFORE-Vergleich verschmolzen ->
    # wuerde stattdessen "Fenster offen"/"BEREIT" drucken statt NICHT
    # ANWENDBAR.
    {
        my $responder = make_routing_responder();
        my ($pid, $port) = start_fake_http([ ($responder) x 100 ]);
        my ($exit, $stdout, $stderr) = run_tool($arm_after_restart_script, ['--no-restart'], PA_MAC => $probe_mac,
            SUDO_BIN => $sudo_stub, WS_PATH => $unused_ws_path,
            LMS_URL  => "http://127.0.0.1:$port/jsonrpc.js");
        kill('TERM', $pid); waitpid($pid, 0);
        is($exit, 0, 'arm-after-restart: Case 1 (NICHT ANWENDBAR) -> exit 0');
        like($stdout, qr/NICHT ANWENDBAR/, 'arm-after-restart: Case 1 -> NICHT ANWENDBAR gedruckt');
        unlike($stdout, qr/Fenster offen/, 'arm-after-restart: Case 1 -> kein "Fenster offen"');
    }

    # Case 2 (ein Schalter bestaetigt sich nicht): player.streaming.direct
    # meldet OFF, die anderen fuenf bestaetigen. Zusaetzlich zur
    # NICHT-ALLE-SCHALTER-Meldung wird die Zeilenform gezaehlt: ein totaler
    # Blackout (kaputte Fixture/Env-Verdrahtung, keine Anfrage kommt an)
    # wuerde dieselbe Endmeldung drucken, aber sechs FEHLER-Zeilen und null
    # DEBUG-Zeilen statt einer FEHLER- und fuenf DEBUG-Zeilen. Rueckbau: die
    # `[ $FAIL -ne 0 ] &&`-Wache (Quellzeile 62) entfernt -> wuerde trotzdem
    # SCHALTER GESETZT/exit 0 drucken.
    {
        my $responder = make_routing_responder(bad_category => 'player.streaming.direct');
        my ($pid, $port) = start_fake_http([ ($responder) x 100 ]);
        my ($exit, $stdout, $stderr) = run_tool($arm_after_restart_script, ['--no-restart'], PA_MAC => $probe_mac,
            SUDO_BIN => $sudo_stub, WS_PATH => $unused_ws_path,
            LMS_URL  => "http://127.0.0.1:$port/jsonrpc.js");
        kill('TERM', $pid); waitpid($pid, 0);
        is($exit, 1, 'arm-after-restart: Case 2 (ein Schalter rot) -> exit 1');
        like($stdout, qr/NICHT ALLE SCHALTER BESTAETIGT/,
            'arm-after-restart: Case 2 -> NICHT ALLE SCHALTER BESTAETIGT');
        my $fehler_count = () = $stdout =~ /player\.streaming\.direct\s+FEHLER:/g;
        is($fehler_count, 1, 'arm-after-restart: Case 2 -> genau EINE FEHLER-Zeile fuer player.streaming.direct');
        my $debug_count = () = $stdout =~ /^\s+\S+\s+DEBUG$/mg;
        is($debug_count, 5, 'arm-after-restart: Case 2 -> genau FUENF DEBUG-Zeilen (kein Blackout)');
    }
};

# ============================================================
# signatur-c-probe.py subtest -- Quick 260915-bpd Task 3.
# ============================================================
subtest 'signatur-c-probe' => sub {
    # Case 1 (Tor A rot): PGREP_BIN liefert IMMER dieselbe fingierte PID,
    # damit BEFORE_PID und jede Poll-Pruefung beweisbar gleich sind --
    # unabhaengig davon, was der echte, scharfgestellte Messaufbau
    # waehrenddessen tut. LMS_URL zeigt zusaetzlich auf einen geschlossenen
    # Port (defense in depth: selbst wenn Tor A doch gruen wuerde, schlaegt
    # jeder curl-Aufruf deterministisch fehl). Rueckbau: der
    # `p != BEFORE_PID`-Vergleich in der Tor-A-Schleife entfernt (jedes
    # pgrep-Ergebnis, auch die Vor-Neustart-PID, gilt als "neu") -> wuerde
    # diesen Fall an Tor A vorbeischleusen statt mit TOR A ROT abzubrechen.
    {
        my $stubdir = tempdir(CLEANUP => 1);
        my $sudo_stub  = write_sudo_passthrough_stub($stubdir);
        my $pgrep_stub = write_pgrep_constant_stub($stubdir);
        my $unused_ws_path = "$stubdir/unused-ws.port";
        my $closed_port = free_closed_port();

        my ($exit, $stdout, $stderr) = run_python_tool($signatur_c_probe_script, [], PA_MAC => $probe_mac,
            SUDO_BIN        => $sudo_stub,
            WS_PATH         => $unused_ws_path,
            PROBE_TIMEOUT_S => '1',
            PGREP_BIN       => $pgrep_stub,
            LMS_URL         => "http://127.0.0.1:$closed_port/jsonrpc.js");
        is($exit, 1, 'signatur-c-probe: Case 1 (Tor A rot) -> exit 1');
        like($stdout, qr/TOR A ROT/, 'signatur-c-probe: Case 1 -> TOR A ROT');
        unlike($stdout, qr/REANFORDERUNG/, 'signatur-c-probe: Case 1 -> nie REANFORDERUNG erreicht');
    }

    # Case 2 (Tor C rot): PGREP_BIN liefert bei JEDEM Aufruf eine neue,
    # unterschiedliche fingierte PID, damit Tor A gleich beim ersten Check
    # gruen wird und der Lauf tatsaechlich bis Tor C kommt. Der Fake-Server
    # bestaetigt alle sechs Kategorien und antwortet auf players mit
    # DERSELBEN $probe_mac bei connected=0 -- absichtlich dieselbe MAC,
    # damit der Fixture den connected==1-Zweig prueft, nicht den getrennten
    # Playerid-Mismatch-Zweig. Rueckbau: Tor Cs Pruefung auf playerid==MAC
    # allein abgeschwaecht (das connected==1-Kriterium entfernt) -> wuerde
    # diesen Fixture-Eintrag als bestaetigt werten und Richtung
    # REANFORDERUNG weiterlaufen statt mit TOR C ROT abzubrechen.
    {
        my $stubdir = tempdir(CLEANUP => 1);
        my $sudo_stub  = write_sudo_passthrough_stub($stubdir);
        my $pgrep_stub = write_pgrep_counter_stub($stubdir);
        my $unused_ws_path = "$stubdir/unused-ws.port";
        my $responder = make_routing_responder(players_ok => 0);
        my ($pid, $port) = start_fake_http([ ($responder) x 100 ]);

        my ($exit, $stdout, $stderr) = run_python_tool($signatur_c_probe_script, [], PA_MAC => $probe_mac,
            SUDO_BIN        => $sudo_stub,
            WS_PATH         => $unused_ws_path,
            PGREP_BIN       => $pgrep_stub,
            PROBE_TIMEOUT_S => '1',
            SPOTON_MAC      => $probe_mac,
            LMS_URL         => "http://127.0.0.1:$port/jsonrpc.js");
        kill('TERM', $pid); waitpid($pid, 0);
        is($exit, 1, 'signatur-c-probe: Case 2 (Tor C rot) -> exit 1');
        like($stdout, qr/TOR C ROT/, 'signatur-c-probe: Case 2 -> TOR C ROT');
        unlike($stdout, qr/REANFORDERUNG abgesetzt/, 'signatur-c-probe: Case 2 -> nie REANFORDERUNG abgesetzt');
    }

    # Case 3 (Fensteranzeige, drei Zustaende): --check-fenster isoliert die
    # Drei-Wege-Fensteranzeige direkt, ohne Neustart/Tor A/B/C -- Nachweis
    # gegen die Regressionsnotiz zum falschen "ZU"-Befund der
    # Zwei-Wege-Fassung vom 2026-09-14. Alle drei zurueckgegebenen Strings
    # muessen paarweise verschieden sein, nicht nur je einzeln passend.
    {
        my $stubdir = tempdir(CLEANUP => 1);
        my $sudo_stub = write_sudo_passthrough_stub($stubdir);

        # 1. ws.port fehlt (beliebiger $before-Wert)
        my $missing_path = "$stubdir/missing-ws.port";
        my ($exit1, $stdout1, $stderr1) = run_python_tool($signatur_c_probe_script,
            [ '--check-fenster', '12345' ],
            SUDO_BIN => $sudo_stub, PA_MAC => $probe_mac, WS_PATH => $missing_path);
        like($stdout1, qr/ws\.port fehlt/, 'signatur-c-probe: --check-fenster fehlend -> ws.port fehlt');

        # 2. ws.port unveraendert (before == echte mtime der Datei)
        my ($fh, $real_file) = tempfile();
        print $fh "x";
        close($fh);
        my $real_mtime = (stat($real_file))[9];
        my ($exit2, $stdout2, $stderr2) = run_python_tool($signatur_c_probe_script,
            [ '--check-fenster', "$real_mtime" ],
            SUDO_BIN => $sudo_stub, PA_MAC => $probe_mac, WS_PATH => $real_file);
        like($stdout2, qr/ws\.port unveraendert/,
            'signatur-c-probe: --check-fenster gleich -> ws.port unveraendert');

        # 3. ws.port neu (ZU) -- before absichtlich verschieden
        my $different = $real_mtime - 999999;
        my ($exit3, $stdout3, $stderr3) = run_python_tool($signatur_c_probe_script,
            [ '--check-fenster', "$different" ],
            SUDO_BIN => $sudo_stub, PA_MAC => $probe_mac, WS_PATH => $real_file);
        like($stdout3, qr/ZU \(ws\.port neu/,
            'signatur-c-probe: --check-fenster verschieden -> ZU (ws.port neu');

        unlink($real_file);

        isnt($stdout1, $stdout2, 'signatur-c-probe: Fensteranzeige Zustand 1 != Zustand 2');
        isnt($stdout2, $stdout3, 'signatur-c-probe: Fensteranzeige Zustand 2 != Zustand 3');
        isnt($stdout1, $stdout3, 'signatur-c-probe: Fensteranzeige Zustand 1 != Zustand 3');
    }

    # Case 4 (nicht quittiert, WR-07): Tor A/B/C alle gruen (gleicher Aufbau
    # wie Case 2's Counter-PID-Stub + players_ok=>1), aber "playlist play"
    # bekommt keinen "result"-Schluessel -- quittiert wird False. Muss-
    # Fehlschlag: ohne Task 1s `sys.exit(3)` im `if not quittiert:`-Block
    # liefert die Sonde heute Exit 0 -- die `is($exit, 3, ...)`-Assertion
    # faellt (siehe SUMMARY.md fuer die RED/GREEN-Gegenprobe gegen den
    # Pre-Fix-Stand).
    {
        my $stubdir = tempdir(CLEANUP => 1);
        my $sudo_stub  = write_sudo_passthrough_stub($stubdir);
        my $pgrep_stub = write_pgrep_counter_stub($stubdir);
        my $unused_ws_path = "$stubdir/unused-ws.port";
        my $responder = make_routing_responder(players_ok => 1, ack_playlist_play => 0);
        my ($pid, $port) = start_fake_http([ ($responder) x 100 ]);

        my ($exit, $stdout, $stderr) = run_python_tool($signatur_c_probe_script, [], PA_MAC => $probe_mac,
            SUDO_BIN        => $sudo_stub,
            WS_PATH         => $unused_ws_path,
            PGREP_BIN       => $pgrep_stub,
            PROBE_TIMEOUT_S => '1',
            SPOTON_MAC      => $probe_mac,
            LMS_URL         => "http://127.0.0.1:$port/jsonrpc.js");
        kill('TERM', $pid); waitpid($pid, 0);
        is($exit, 3, 'signatur-c-probe: Case 4 (nicht quittiert) -> exit 3');
        like($stdout, qr/NICHT QUITTIERT/, 'signatur-c-probe: Case 4 -> NICHT QUITTIERT');
    }
};

# ============================================================
# repeat-probe.sh subtest -- Quick 260915-bpd Task 3. A synthetic
# PROBE_SCRIPT stub (Bash, direct invocation -- matching the
# no-`python3`-prefix call form Task 2 wired into repeat-probe.sh) drives
# three invocations: run 1 and run 3 append DISTINCT explodePlaylist counts
# to a synthetic SERVER_LOG, run 2 appends nothing and exits 1 (mirroring a
# red Tor).
# ============================================================
subtest 'repeat-probe' => sub {
    my $stubdir = tempdir(CLEANUP => 1);
    my $sudo_stub = write_sudo_passthrough_stub($stubdir);
    my $probe_stub = write_custom_stub($stubdir, 'probe-stub.sh', "#!/bin/bash
DIR=\$(dirname \"\$0\")
CTR=\"\$DIR/PROBE_COUNTER\"
N=0
[ -f \"\$CTR\" ] && N=\$(cat \"\$CTR\")
N=\$((N+1))
echo \"\$N\" > \"\$CTR\"
if [ \"\$N\" = \"1\" ]; then
  {
    echo \"[26-09-15 00:00:01.000000] Song::getNextSong bla\"
    echo \"[26-09-15 00:00:01.100000] Need to create Soloist daemon fuer aa:bb:cc:dd:ee:01\"
    echo \"[26-09-15 00:00:01.200000] explodePlaylist: 1 tracks\"
  } >> \"\$SERVER_LOG\"
  exit 0
elif [ \"\$N\" = \"2\" ]; then
  exit 1
elif [ \"\$N\" = \"3\" ]; then
  {
    echo \"[26-09-15 00:00:02.000000] Song::getNextSong bla\"
    echo \"[26-09-15 00:00:02.100000] Need to create Soloist daemon fuer aa:bb:cc:dd:ee:01\"
    echo \"[26-09-15 00:00:02.200000] explodePlaylist: 1 tracks\"
    echo \"[26-09-15 00:00:02.300000] explodePlaylist: 2 tracks\"
  } >> \"\$SERVER_LOG\"
  exit 0
fi
exit 0
");

    my ($log_fh, $server_log) = tempfile();
    print $log_fh "startup line 1\n";
    print $log_fh "startup line 2\n";
    close($log_fh);

    my ($exit, $stdout, $stderr) = run_tool($repeat_probe_script, ['3'], PA_MAC => $probe_mac,
        PROBE_SCRIPT => $probe_stub, SERVER_LOG => $server_log, SUDO_BIN => $sudo_stub);

    my $lauf_count = () = $stdout =~ /LAUF \d+\/3/g;
    is($lauf_count, 3, 'repeat-probe: genau 3 LAUF-r/3-Kopfzeilen (nicht die LAUF-UNGUELTIG-Zeile)');
    my $invalid_count = () = $stdout =~ /LAUF UNGUELTIG/g;
    is($invalid_count, 1, 'repeat-probe: genau 1 LAUF UNGUELTIG');
    my @exp_matches = ($stdout =~ /explodePlaylist=(\d+)/g);
    is_deeply(\@exp_matches, [ 1, 2 ],
        'repeat-probe: Lauf 1 explodePlaylist=1, Lauf 3 explodePlaylist=2 (je Lauf, nicht kumulativ)');
    my $deferring_count = () = $stdout =~ /deferring=/g;
    is($deferring_count, 2,
        'repeat-probe: nur 2 deferring=-Zeilen (Lauf 2 wurde uebersprungen, nicht leer ausgewertet)');

    unlink($server_log);

    # WR-07, isolierter Fall: ein einlaeufiger (N=1) Stub, der SOFORT exit 3
    # liefert (keine Logzeilen) -- muss von der spezifischen "nicht
    # quittiert"-Meldung erkannt werden, nicht von der allgemeinen "(Tor
    # rot)"-Meldung. Eigener PROBE_COUNTER-Zaehler in einem eigenen
    # $stubdir2, damit dieser Fall vom Drei-Lauf-Block oben komplett
    # isoliert bleibt. Muss-Fehlschlag: ohne Task 1s `RC -eq 3`-Zweig faellt
    # der Lauf durch die allgemeine `RC -ne 0`-Pruefung -- stdout traegt
    # dann "(Tor rot)" statt "(nicht quittiert)", die `like`-Assertion auf
    # den spezifischen Text schlaegt fehl (siehe SUMMARY.md fuer die
    # RED/GREEN-Gegenprobe gegen den Pre-Fix-Stand).
    {
        my $stubdir2 = tempdir(CLEANUP => 1);
        my $sudo_stub2 = write_sudo_passthrough_stub($stubdir2);
        my $probe_stub2 = write_custom_stub($stubdir2, 'probe-stub-exit3.sh', "#!/bin/bash
exit 3
");
        my ($log_fh2, $server_log2) = tempfile();
        print $log_fh2 "startup line 1\n";
        close($log_fh2);

        my ($exit2, $stdout2, $stderr2) = run_tool($repeat_probe_script, ['1'], PA_MAC => $probe_mac,
            PROBE_SCRIPT => $probe_stub2, SERVER_LOG => $server_log2, SUDO_BIN => $sudo_stub2);

        like($stdout2, qr/LAUF UNGUELTIG \(nicht quittiert\)/,
            'repeat-probe: isolierter Exit-3-Lauf -> LAUF UNGUELTIG (nicht quittiert)');
        unlike($stdout2, qr/deferring=/,
            'repeat-probe: isolierter Exit-3-Lauf -> keine deferring=-Zeile');

        unlink($server_log2);
    }
};

# ============================================================
# subtest 'rig-prefs-check' -- Quick 260928-fv0 Task 1. Read-only preflight
# gate against the partial-settings-form trap (connect-transfer-split-brain,
# 2026-09-26 03:29:52). Every behavior bullet from the plan, including two
# must-fail paths (the real muted tuple as a fixture; a --expect override on
# an otherwise-good fixture) alongside the must-pass fixture.
# ============================================================
subtest 'rig-prefs-check' => sub {
    my $mac = '02:00:00:5a:11:01';

    # Case 1: good fixture -> PASS, one line, read-only (Q only, no SET).
    {
        my (undef, $capture_file) = tempfile();
        my $responder = make_prefs_responder(
            { enableSpotifyConnect => 1, disableDiscovery => 0, enableAutoplay => 1,
              discoveryDisabledByCrashLoop => undef },
            capture_file => $capture_file,
        );
        my ($pid, $port) = start_fake_http([ ($responder) x 12 ]);
        my ($exit, $stdout, $stderr) = run_tool($rig_prefs_check_script, [ $mac ],
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js");
        kill('TERM', $pid);
        waitpid($pid, 0);
        my @capture = read_capture_file($capture_file);
        unlink($capture_file);
        is($exit, 0, 'rig-prefs-check: good fixture -> exit 0');
        like($stdout, qr/^RIG_PREFS=PASS mac=\Q$mac\E[^\n]*\n\z/, 'rig-prefs-check: PASS one line');
        ok(!(grep { /^SET / } @capture), 'rig-prefs-check: read-only, no SET in capture');
        is(scalar(grep { /^Q / } @capture), 4, 'rig-prefs-check: exactly four Q queries');
    }

    # Case 2: real 2026-09-26 03:29:52 muted tuple -> FAIL naming all three.
    {
        my $responder = make_prefs_responder(
            { enableSpotifyConnect => 0, disableDiscovery => 1, enableAutoplay => 0,
              discoveryDisabledByCrashLoop => undef },
        );
        my ($pid, $port) = start_fake_http([ ($responder) x 12 ]);
        my ($exit, $stdout, $stderr) = run_tool($rig_prefs_check_script, [ $mac ],
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js");
        kill('TERM', $pid);
        waitpid($pid, 0);
        is($exit, 1, 'rig-prefs-check: 2026-09-26 tuple -> exit 1');
        like($stdout, qr/^RIG_PREFS=FAIL[^\n]*\n\z/, 'rig-prefs-check: FAIL one line');
        like($stdout, qr/enableSpotifyConnect/, 'rig-prefs-check: names enableSpotifyConnect');
        like($stdout, qr/disableDiscovery/, 'rig-prefs-check: names disableDiscovery');
        like($stdout, qr/enableAutoplay/, 'rig-prefs-check: names enableAutoplay');
    }

    # Case 3: enableSpotifyConnect null (others good) -> FAIL, undef literal.
    {
        my $responder = make_prefs_responder(
            { enableSpotifyConnect => undef, disableDiscovery => 0, enableAutoplay => 1,
              discoveryDisabledByCrashLoop => undef },
        );
        my ($pid, $port) = start_fake_http([ ($responder) x 12 ]);
        my ($exit, $stdout, $stderr) = run_tool($rig_prefs_check_script, [ $mac ],
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js");
        kill('TERM', $pid);
        waitpid($pid, 0);
        is($exit, 1, 'rig-prefs-check: enableSpotifyConnect null -> exit 1');
        like($stdout, qr/enableSpotifyConnect=undef/, 'rig-prefs-check: null prints as undef');
    }

    # Case 4: discoveryDisabledByCrashLoop "1" (others good) -> FAIL.
    {
        my $responder = make_prefs_responder(
            { enableSpotifyConnect => 1, disableDiscovery => 0, enableAutoplay => 1,
              discoveryDisabledByCrashLoop => 1 },
        );
        my ($pid, $port) = start_fake_http([ ($responder) x 12 ]);
        my ($exit, $stdout, $stderr) = run_tool($rig_prefs_check_script, [ $mac ],
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js");
        kill('TERM', $pid);
        waitpid($pid, 0);
        is($exit, 1, 'rig-prefs-check: crash-loop flag set -> exit 1');
        like($stdout, qr/discoveryDisabledByCrashLoop=1/, 'rig-prefs-check: names crash-loop flag');
    }

    # Case 5: good fixture + --expect enableSpotifyConnect=0 -> FAIL, expect_override=.
    {
        my $responder = make_prefs_responder(
            { enableSpotifyConnect => 1, disableDiscovery => 0, enableAutoplay => 1,
              discoveryDisabledByCrashLoop => undef },
        );
        my ($pid, $port) = start_fake_http([ ($responder) x 12 ]);
        my ($exit, $stdout, $stderr) = run_tool($rig_prefs_check_script,
            [ $mac, '--expect', 'enableSpotifyConnect=0' ],
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js");
        kill('TERM', $pid);
        waitpid($pid, 0);
        is($exit, 1, 'rig-prefs-check: --expect override on good fixture -> exit 1');
        like($stdout, qr/expect_override=enableSpotifyConnect=0/, 'rig-prefs-check: expect_override= visible');
    }

    # Case 6: first query gets no reply (curl exit 52) -> ERROR.
    {
        my $responder = make_prefs_responder(
            { enableSpotifyConnect => 1, disableDiscovery => 0, enableAutoplay => 1,
              discoveryDisabledByCrashLoop => undef },
            close_on => [ 'enableSpotifyConnect' ],
        );
        my ($pid, $port) = start_fake_http([ ($responder) x 12 ]);
        my ($exit, $stdout, $stderr) = run_tool($rig_prefs_check_script, [ $mac ],
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js");
        kill('TERM', $pid);
        waitpid($pid, 0);
        is($exit, 2, 'rig-prefs-check: no reply on first query -> exit 2');
        like($stdout, qr/^RIG_PREFS=ERROR[^\n]*\n\z/, 'rig-prefs-check: ERROR one line');
    }

    # Case 7: LMS_URL points at a refused port -> ERROR.
    {
        my $port = free_closed_port();
        my ($exit, $stdout, $stderr) = run_tool($rig_prefs_check_script, [ $mac ],
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js");
        is($exit, 2, 'rig-prefs-check: refused port -> exit 2');
        like($stdout, qr/^RIG_PREFS=ERROR[^\n]*\n\z/, 'rig-prefs-check: ERROR one line (refused port)');
    }

    # Case 8: --snapshot on good fixture -> exactly four key=value lines, fixed order.
    {
        my $responder = make_prefs_responder(
            { enableSpotifyConnect => 1, disableDiscovery => 0, enableAutoplay => 1,
              discoveryDisabledByCrashLoop => undef },
        );
        my ($pid, $port) = start_fake_http([ ($responder) x 12 ]);
        my ($exit, $stdout, $stderr) = run_tool($rig_prefs_check_script, [ $mac, '--snapshot' ],
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js");
        kill('TERM', $pid);
        waitpid($pid, 0);
        is($exit, 0, 'rig-prefs-check: --snapshot good fixture -> exit 0');
        is($stdout,
            "enableSpotifyConnect=1\ndisableDiscovery=0\nenableAutoplay=1\ndiscoveryDisabledByCrashLoop=undef\n",
            'rig-prefs-check: --snapshot exact four lines, fixed order');
    }

    # Case 9: invalid MAC -> ERROR before any request; capture stays empty.
    {
        my (undef, $capture_file) = tempfile();
        my $responder = make_prefs_responder(
            { enableSpotifyConnect => 1, disableDiscovery => 0, enableAutoplay => 1,
              discoveryDisabledByCrashLoop => undef },
            capture_file => $capture_file,
        );
        my ($pid, $port) = start_fake_http([ ($responder) x 12 ]);
        my ($exit, $stdout, $stderr) = run_tool($rig_prefs_check_script, [ 'not-a-mac' ],
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js");
        kill('TERM', $pid);
        waitpid($pid, 0);
        my @capture = read_capture_file($capture_file);
        unlink($capture_file);
        is($exit, 2, 'rig-prefs-check: invalid MAC -> exit 2');
        like($stdout, qr/^RIG_PREFS=ERROR reason=usage/, 'rig-prefs-check: usage ERROR line');
        is(scalar(@capture), 0, 'rig-prefs-check: invalid MAC -> no request reached the fake');
    }

    # Case 10: unknown --expect key -> ERROR before any request; capture stays empty.
    {
        my (undef, $capture_file) = tempfile();
        my $responder = make_prefs_responder(
            { enableSpotifyConnect => 1, disableDiscovery => 0, enableAutoplay => 1,
              discoveryDisabledByCrashLoop => undef },
            capture_file => $capture_file,
        );
        my ($pid, $port) = start_fake_http([ ($responder) x 12 ]);
        my ($exit, $stdout, $stderr) = run_tool($rig_prefs_check_script,
            [ $mac, '--expect', 'noSuchKey=1' ],
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js");
        kill('TERM', $pid);
        waitpid($pid, 0);
        my @capture = read_capture_file($capture_file);
        unlink($capture_file);
        is($exit, 2, 'rig-prefs-check: unknown --expect key -> exit 2');
        like($stdout, qr/^RIG_PREFS=ERROR reason=usage/, 'rig-prefs-check: usage ERROR line (--expect)');
        is(scalar(@capture), 0, 'rig-prefs-check: unknown --expect key -> no request reached the fake');
    }
};

# ============================================================
# subtest 'player-settings-post' -- Quick 260928-fv0 Task 2. The full-form
# settings-page POST tool (never partial), with a before/after guard that
# restores via playerpref and fails loudly if anything flips anyway. Every
# behavior bullet from the plan, plus the GAP-260928-07 peer-review addition
# (malformed/fieldless JSON-RPC reply during the pre-POST snapshot).
# ============================================================
subtest 'player-settings-post' => sub {
    my $mac = '02:00:00:5a:11:01';

    # Case A: before/after 1/0/1, pref_soloistQuality=3 -> PASS, one FORM
    # line carrying the full checkbox state + the caller's field.
    {
        my (undef, $capture_file) = tempfile();
        my %fixture = ( enableSpotifyConnect => 1, disableDiscovery => 0, enableAutoplay => 1,
                         discoveryDisabledByCrashLoop => undef );
        my $responder = make_prefs_responder(\%fixture,
            capture_file => $capture_file, after => \%fixture, default_mac => $probe_mac);
        my ($pid, $port) = start_fake_http([ ($responder) x 24 ]);
        my ($exit, $stdout, $stderr) = run_tool($player_settings_post_script,
            [ $mac, 'pref_soloistQuality=3' ],
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js");
        kill('TERM', $pid);
        waitpid($pid, 0);
        my @capture = read_capture_file($capture_file);
        unlink($capture_file);
        is($exit, 0, 'player-settings-post: unchanged fixture -> exit 0');
        like($stdout, qr/^SETTINGS_POST=PASS[^\n]*\n\z/, 'player-settings-post: PASS one line');
        my @form_lines = grep { /^FORM / } @capture;
        is(scalar(@form_lines), 1, 'player-settings-post: exactly one FORM POST');
        like($form_lines[0], qr/saveSettings=1/, 'player-settings-post: FORM carries saveSettings=1');
        like($form_lines[0], qr/pref_enableSpotifyConnect=1/, 'player-settings-post: FORM carries connect=1');
        like($form_lines[0], qr/pref_enableDiscovery=1/, 'player-settings-post: FORM carries discovery checked');
        like($form_lines[0], qr/pref_enableAutoplay=1/, 'player-settings-post: FORM carries autoplay=1');
        like($form_lines[0], qr/pref_soloistQuality=3/, 'player-settings-post: FORM carries caller field');
    }

    # Case B: before/after 1/0/0 (autoplay OFF) -> PASS, FORM line has NO
    # pref_enableAutoplay -- an unchecked box stays unchecked.
    {
        my (undef, $capture_file) = tempfile();
        my %fixture = ( enableSpotifyConnect => 1, disableDiscovery => 0, enableAutoplay => 0,
                         discoveryDisabledByCrashLoop => undef );
        my $responder = make_prefs_responder(\%fixture,
            capture_file => $capture_file, after => \%fixture, default_mac => $probe_mac);
        my ($pid, $port) = start_fake_http([ ($responder) x 24 ]);
        my ($exit, $stdout, $stderr) = run_tool($player_settings_post_script,
            [ $mac, 'pref_soloistQuality=3' ],
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js");
        kill('TERM', $pid);
        waitpid($pid, 0);
        my @capture = read_capture_file($capture_file);
        unlink($capture_file);
        is($exit, 0, 'player-settings-post: autoplay-off fixture -> exit 0');
        my @form_lines = grep { /^FORM / } @capture;
        is(scalar(@form_lines), 1, 'player-settings-post: exactly one FORM POST (autoplay off)');
        unlike($form_lines[0], qr/pref_enableAutoplay/, 'player-settings-post: unchecked autoplay never forced on');
    }

    # Case C: before 1/0/1, after 0/1/0 (the exact effect of the 2026-09-26
    # partial POST) -> FAIL naming all three, restored via SET.
    {
        my (undef, $capture_file) = tempfile();
        my %before = ( enableSpotifyConnect => 1, disableDiscovery => 0, enableAutoplay => 1,
                        discoveryDisabledByCrashLoop => undef );
        my %after  = ( enableSpotifyConnect => 0, disableDiscovery => 1, enableAutoplay => 0,
                        discoveryDisabledByCrashLoop => undef );
        my $responder = make_prefs_responder(\%before,
            capture_file => $capture_file, after => \%after);
        my ($pid, $port) = start_fake_http([ ($responder) x 24 ]);
        my ($exit, $stdout, $stderr) = run_tool($player_settings_post_script,
            [ $mac, 'pref_soloistQuality=3' ],
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js");
        kill('TERM', $pid);
        waitpid($pid, 0);
        my @capture = read_capture_file($capture_file);
        unlink($capture_file);
        is($exit, 1, 'player-settings-post: guard trips on flip -> exit 1');
        like($stdout, qr/^SETTINGS_POST=FAIL[^\n]*\n\z/, 'player-settings-post: FAIL one line');
        like($stdout, qr/enableSpotifyConnect/, 'player-settings-post: names enableSpotifyConnect');
        like($stdout, qr/disableDiscovery/, 'player-settings-post: names disableDiscovery');
        like($stdout, qr/enableAutoplay/, 'player-settings-post: names enableAutoplay');
        ok((grep { /^SET enableSpotifyConnect 1$/ } @capture), 'player-settings-post: restores enableSpotifyConnect to 1');
        ok((grep { /^SET disableDiscovery 0$/ } @capture), 'player-settings-post: restores disableDiscovery to 0');
        ok((grep { /^SET enableAutoplay 1$/ } @capture), 'player-settings-post: restores enableAutoplay to 1');
    }

    # Case D: before enableSpotifyConnect null -> FAIL, no POST at all.
    {
        my (undef, $capture_file) = tempfile();
        my %fixture = ( enableSpotifyConnect => undef, disableDiscovery => 0, enableAutoplay => 1,
                         discoveryDisabledByCrashLoop => undef );
        my $responder = make_prefs_responder(\%fixture,
            capture_file => $capture_file, after => \%fixture);
        my ($pid, $port) = start_fake_http([ ($responder) x 24 ]);
        my ($exit, $stdout, $stderr) = run_tool($player_settings_post_script,
            [ $mac, 'pref_soloistQuality=3' ],
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js");
        kill('TERM', $pid);
        waitpid($pid, 0);
        my @capture = read_capture_file($capture_file);
        unlink($capture_file);
        is($exit, 1, 'player-settings-post: undef checkbox before -> exit 1');
        is(scalar(grep { /^FORM / } @capture), 0, 'player-settings-post: undef checkbox -> no FORM POST');
    }

    # Case E: refused checkbox field argument -> ERROR, empty capture.
    {
        my (undef, $capture_file) = tempfile();
        my %fixture = ( enableSpotifyConnect => 1, disableDiscovery => 0, enableAutoplay => 1,
                         discoveryDisabledByCrashLoop => undef );
        my $responder = make_prefs_responder(\%fixture, capture_file => $capture_file);
        my ($pid, $port) = start_fake_http([ ($responder) x 24 ]);
        my ($exit, $stdout, $stderr) = run_tool($player_settings_post_script,
            [ $mac, 'pref_enableSpotifyConnect=0' ],
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js");
        kill('TERM', $pid);
        waitpid($pid, 0);
        my @capture = read_capture_file($capture_file);
        unlink($capture_file);
        is($exit, 2, 'player-settings-post: refused checkbox field -> exit 2');
        like($stdout, qr/^SETTINGS_POST=ERROR[^\n]*\n\z/, 'player-settings-post: ERROR one line');
        is(scalar(@capture), 0, 'player-settings-post: refused checkbox field -> empty capture');
    }

    # Case F: value containing '&' -> ERROR, empty capture.
    {
        my (undef, $capture_file) = tempfile();
        my %fixture = ( enableSpotifyConnect => 1, disableDiscovery => 0, enableAutoplay => 1,
                         discoveryDisabledByCrashLoop => undef );
        my $responder = make_prefs_responder(\%fixture, capture_file => $capture_file);
        my ($pid, $port) = start_fake_http([ ($responder) x 24 ]);
        my ($exit, $stdout, $stderr) = run_tool($player_settings_post_script,
            [ $mac, 'pref_soloistQuality=3&pref_enableSpotifyConnect=0' ],
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js");
        kill('TERM', $pid);
        waitpid($pid, 0);
        my @capture = read_capture_file($capture_file);
        unlink($capture_file);
        is($exit, 2, 'player-settings-post: & in value -> exit 2');
        like($stdout, qr/^SETTINGS_POST=ERROR[^\n]*\n\z/, 'player-settings-post: ERROR one line (& in value)');
        is(scalar(@capture), 0, 'player-settings-post: & in value -> empty capture');
    }

    # Case G: no reply to the first snapshot query -> ERROR, no FORM line.
    {
        my (undef, $capture_file) = tempfile();
        my %fixture = ( enableSpotifyConnect => 1, disableDiscovery => 0, enableAutoplay => 1,
                         discoveryDisabledByCrashLoop => undef );
        my $responder = make_prefs_responder(\%fixture,
            capture_file => $capture_file, close_on => [ 'enableSpotifyConnect' ]);
        my ($pid, $port) = start_fake_http([ ($responder) x 24 ]);
        my ($exit, $stdout, $stderr) = run_tool($player_settings_post_script,
            [ $mac, 'pref_soloistQuality=3' ],
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js");
        kill('TERM', $pid);
        waitpid($pid, 0);
        my @capture = read_capture_file($capture_file);
        unlink($capture_file);
        is($exit, 2, 'player-settings-post: no reply to snapshot query -> exit 2');
        is(scalar(grep { /^FORM / } @capture), 0, 'player-settings-post: no reply -> no FORM POST');
    }

    # GAP-260928-07 (i): non-JSON reply during the pre-POST snapshot.
    {
        my (undef, $capture_file) = tempfile();
        my %fixture = ( enableSpotifyConnect => 1, disableDiscovery => 0, enableAutoplay => 1,
                         discoveryDisabledByCrashLoop => undef );
        my $responder = make_prefs_responder(\%fixture,
            capture_file => $capture_file, bad_reply => { enableSpotifyConnect => 'notjson' });
        my ($pid, $port) = start_fake_http([ ($responder) x 24 ]);
        my ($exit, $stdout, $stderr) = run_tool($player_settings_post_script,
            [ $mac, 'pref_soloistQuality=3' ],
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js");
        kill('TERM', $pid);
        waitpid($pid, 0);
        my @capture = read_capture_file($capture_file);
        unlink($capture_file);
        isnt($exit, 0, 'player-settings-post: non-JSON snapshot reply -> non-zero exit');
        my @lines = grep { length } split /\n/, $stdout;
        is(scalar(@lines), 1, 'player-settings-post: non-JSON snapshot reply -> one stdout line');
        is(scalar(grep { /^FORM / } @capture), 0, 'player-settings-post: non-JSON snapshot reply -> no POST sent');
    }

    # GAP-260928-07 (ii): valid JSON without _p2 during the pre-POST snapshot.
    {
        my (undef, $capture_file) = tempfile();
        my %fixture = ( enableSpotifyConnect => 1, disableDiscovery => 0, enableAutoplay => 1,
                         discoveryDisabledByCrashLoop => undef );
        my $responder = make_prefs_responder(\%fixture,
            capture_file => $capture_file, bad_reply => { enableSpotifyConnect => 'no_p2' });
        my ($pid, $port) = start_fake_http([ ($responder) x 24 ]);
        my ($exit, $stdout, $stderr) = run_tool($player_settings_post_script,
            [ $mac, 'pref_soloistQuality=3' ],
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js");
        kill('TERM', $pid);
        waitpid($pid, 0);
        my @capture = read_capture_file($capture_file);
        unlink($capture_file);
        isnt($exit, 0, 'player-settings-post: fieldless JSON snapshot reply -> non-zero exit');
        my @lines = grep { length } split /\n/, $stdout;
        is(scalar(@lines), 1, 'player-settings-post: fieldless JSON snapshot reply -> one stdout line');
        is(scalar(grep { /^FORM / } @capture), 0, 'player-settings-post: fieldless JSON snapshot reply -> no POST sent');
    }

    # ------------------------------------------------------------------
    # Quick 261019-m6b. Live incident 2026-10-19: `player-settings-post.sh
    # 02:00:00:5a:11:03 pref_streamFormat=flac` printed SETTINGS_POST=PASS, but
    # LMS stored the value on 02:00:00:5a:11:01 (lavender-UAT) and left the
    # named player untouched; the checkbox snapshot only reads the NAMED mac,
    # which the POST never reached. LMS routing rule the fake emulates:
    # HTTP.pm:562 (a POST parses the BODY only, never the URL query), HTTP.pm:901
    # (no client -> clientRandom(), the first client) and HTTP.pm:1164-1166
    # (a body `playerid` resolves the settings handler's client). Named player
    # N = $probe_mac, other (default) player O = $mac.
    # ------------------------------------------------------------------
    my %m6b_boxes = ( enableSpotifyConnect => 1, disableDiscovery => 0, enableAutoplay => 1,
                      discoveryDisabledByCrashLoop => undef );

    # run_m6b(\%fixture, \%responder_opts, $field) -> ($exit, $stdout, @capture)
    my $run_m6b = sub {
        my ($fixture, $opts, $field) = @_;
        my (undef, $capture_file) = tempfile();
        my $responder = make_prefs_responder($fixture,
            capture_file => $capture_file, default_mac => $mac, %$opts);
        my ($pid, $port) = start_fake_http([ ($responder) x 24 ]);
        my ($exit, $stdout, $stderr) = run_tool($player_settings_post_script,
            [ $probe_mac, $field ],
            LMS_URL => "http://127.0.0.1:$port/jsonrpc.js");
        kill('TERM', $pid);
        waitpid($pid, 0);
        my @capture = read_capture_file($capture_file);
        unlink($capture_file);
        return ($exit, $stdout, @capture);
    };

    # queried_after_post($name, @capture): a `Q <name>` line AFTER the FORM line
    # (the before-read legitimately queries it too, so "after" means any later one).
    my $queried_after_post = sub {
        my ($name, @capture) = @_;
        my $seen_form;
        for my $line (@capture) {
            if (!$seen_form) { $seen_form = 1 if $line =~ /^FORM /; next; }
            return 1 if $line eq "Q $name";
        }
        return 0;
    };

    # Cell routing: default player is O; the tool must name N in the body.
    {
        my %fixture = %m6b_boxes;
        my ($exit, $stdout, @capture) = $run_m6b->(\%fixture, {}, 'pref_soloistQuality=3');
        is($exit, 0, 'player-settings-post: m6b routing: exit 0');
        like($stdout, qr/^SETTINGS_POST=PASS[^\n]* readback=ok[^\n]*\n\z/,
            'player-settings-post: m6b routing: PASS one line with readback=ok');
        my @form = grep { /^FORM / } @capture;
        my @tgt  = grep { /^TARGET / } @capture;
        ok((@form == 1 && $form[0] =~ /(?:^FORM |&)playerid=\Q$probe_mac\E(?:&|$)/),
            'player-settings-post: m6b routing: FORM body carries playerid');
        ok((@tgt == 1 && $tgt[0] =~ /^TARGET \S*[?&]playerid=\Q$probe_mac\E(?:&|$)/),
            'player-settings-post: m6b routing: POST target carries playerid');
        ok((grep { /^STORE \Q$probe_mac\E soloistQuality 3$/ } @capture),
            'player-settings-post: m6b routing: field stored on the named player');
        ok(!(grep { /^STORE \Q$mac\E / } @capture),
            'player-settings-post: m6b routing: nothing stored on the default player');
        ok($queried_after_post->('soloistQuality', @capture),
            'player-settings-post: m6b routing: read-back queried soloistQuality after the POST');
    }

    # Cell misroute: LMS delivers the write to O although N was named.
    {
        my %fixture = %m6b_boxes;
        my ($exit, $stdout, @capture) = $run_m6b->(\%fixture,
            { force_target => $mac }, 'pref_soloistQuality=3');
        is($exit, 3, 'player-settings-post: m6b misroute: exit 3');
        like($stdout, qr/^SETTINGS_POST=FAIL[^\n]*\n\z/, 'player-settings-post: m6b misroute: FAIL one line');
        like($stdout, qr/^[^\n]*\Qreason=readback: soloistQuality posted=3 expected=3 stored=null\E[^\n]*\n\z/,
            'player-settings-post: m6b misroute: reason names the unstored field');
        ok((grep { /^STORE \Q$mac\E soloistQuality 3$/ } @capture),
            'player-settings-post: m6b misroute: fake stored the field on the other player');
    }

    # Cell bitrate-sanitized: the handler stores '' for 128 (Player.pm:111); not a FAIL.
    {
        my %fixture = %m6b_boxes;
        my ($exit, $stdout, @capture) = $run_m6b->(\%fixture,
            { stored_as => { bitrateOverride => '' } }, 'pref_bitrateOverride=128');
        is($exit, 0, 'player-settings-post: m6b bitrate-sanitized: exit 0');
        like($stdout, qr/^SETTINGS_POST=PASS[^\n]* readback=ok[^\n]*\n\z/,
            'player-settings-post: m6b bitrate-sanitized: PASS one line with readback=ok');
        ok($queried_after_post->('bitrateOverride', @capture),
            'player-settings-post: m6b bitrate-sanitized: read-back queried bitrateOverride after the POST');
        ok((grep { /^STORE \Q$probe_mac\E bitrateOverride $/ } @capture),
            'player-settings-post: m6b bitrate-sanitized: sanitized value stored on the named player');
    }

    # Cell bitrate-mismatch: 320 is valid, so a stored '' is a real mismatch.
    {
        my %fixture = %m6b_boxes;
        my ($exit, $stdout, @capture) = $run_m6b->(\%fixture,
            { stored_as => { bitrateOverride => '' } }, 'pref_bitrateOverride=320');
        is($exit, 3, 'player-settings-post: m6b bitrate-mismatch: exit 3');
        like($stdout, qr/^[^\n]*\QbitrateOverride posted=320 expected=320 stored=empty\E[^\n]*\n\z/,
            'player-settings-post: m6b bitrate-mismatch: FAIL line names posted 320 and stored empty');
    }

    # Cell echo-skip: backend soloist + effective stored ogg -> the handler skips
    # the write for streamFormat=auto (Player.pm:67-73); not a FAIL.
    {
        my %fixture = ( %m6b_boxes, streamFormat => 'ogg', connectOggOverride => undef );
        my ($exit, $stdout, @capture) = $run_m6b->(\%fixture,
            { server_prefs => { backend => 'soloist' }, skip_store => [ 'streamFormat' ] },
            'pref_streamFormat=auto');
        is($exit, 0, 'player-settings-post: m6b echo-skip: exit 0');
        like($stdout, qr/^SETTINGS_POST=PASS[^\n]* readback=ok[^\n]* echo_skip=streamFormat[^\n]*\n\z/,
            'player-settings-post: m6b echo-skip: PASS one line with readback=ok and echo_skip=streamFormat');
        ok((grep { /^QS backend$/ } @capture), 'player-settings-post: m6b echo-skip: backend pref queried');
        ok($queried_after_post->('streamFormat', @capture),
            'player-settings-post: m6b echo-skip: read-back queried streamFormat after the POST');
        ok(!(grep { /^STORE \S+ streamFormat / } @capture),
            'player-settings-post: m6b echo-skip: nothing stored for streamFormat');
    }

    # Cell echo-noskip: same, but backend librespot -> the write is NOT skipped,
    # so a stored ogg against an expected auto is a real mismatch.
    {
        my %fixture = ( %m6b_boxes, streamFormat => 'ogg', connectOggOverride => undef );
        my ($exit, $stdout, @capture) = $run_m6b->(\%fixture,
            { server_prefs => { backend => 'librespot' }, skip_store => [ 'streamFormat' ] },
            'pref_streamFormat=auto');
        is($exit, 3, 'player-settings-post: m6b echo-noskip: exit 3');
        like($stdout, qr/^[^\n]*\QstreamFormat posted=auto expected=auto stored=ogg\E[^\n]*\n\z/,
            'player-settings-post: m6b echo-noskip: FAIL line names posted auto and stored ogg');
    }
};

# ============================================================
# subtest '84.1-08 extract-run-leaveconnect-anchor' -- WR-07 (84.1-REVIEW.md
# :162-166, D-02). Pre-fix, the mode-transition category's final alternative
# is the bare word `leaveConnect`, which also matches the D-02 stay lines
# (L2, L4), the re-adoption hold line (L3) and the IN-04 no-WS-connection
# line (L5) -- every one of them contains the substring "leaveConnect"
# somewhere in its text, even though none of them is an actual mode
# transition. gate_a_formula/gate b read B_LEAVECONNECT_SEEN off this exact
# category, so an over-broad match here would report a leave that never
# happened. Anchored on the real transition text (Control.pm:4833) instead;
# the D-02 stay and after-leaveConnect lines get their OWN categories so
# they stay visible, just not miscounted as a leave.
# ============================================================
subtest '84.1-08 extract-run-leaveconnect-anchor' => sub {
    my $mac = 'aa:bb:cc:dd:ee:01';
    my ($fh, $file) = tempfile();
    print $fh "[26-09-28 12:00:01.0000] Plugins::SpotOn::Soloist::Control::leaveConnect (4833) Control: LMS plays foreign content in connect -- leaveConnect ($mac)\n";
    print $fh "[26-09-28 12:00:02.0000] Plugins::SpotOn::Connect::_onNewSong (592) D-02: newsong without a url in connect -- staying, no leaveConnect ($mac)\n";
    print $fh "[26-09-28 12:00:03.0000] Plugins::SpotOn::Soloist::Control::_holdAfterForeignLeave (4879) Control: daemon reports playing after leaveConnect while LMS plays foreign content -- not re-adopting ($mac)\n";
    print $fh "[26-09-28 12:00:04.0000] Plugins::SpotOn::Connect::_onNewSong (570) D-02: newsong re-announces the song playing at connect entry -- staying, no leaveConnect ($mac)\n";
    print $fh "[26-09-28 12:00:05.0000] Plugins::SpotOn::Soloist::Control::leaveConnect (4848) Control: leaveConnect without a WS connection -- deactivate not sent, the daemon may stay the active device ($mac)\n";
    print $fh "[26-09-28 12:00:06.0000] Plugins::SpotOn::Connect::_onLmsStop (642) D-01(b): LMS stop notification -- mode=idle ($mac)\n";
    close($fh);

    my ($exit, $stdout, $stderr) = run_perl_tool($extract_run_script,
        [ $mac, '12:00:00', '12:00:10',
          '--server-log', $file, '--date', '2026-09-28' ],
        SUDO_BIN => '/bin/true');
    is($exit, 0, '84.1-08 extract-run-leaveconnect-anchor: SUDO_BIN stub lets the tool run through (exit 0)')
        or diag("stderr: $stderr");

    my $section_body = sub {
        my ($hdr_re) = @_;
        return ($stdout =~ /---\s*\Q$hdr_re\E.*?---\n(.*?)(?=\n---|\z)/s) ? $1 : '';
    };

    my $transition_body = $section_body->('server.log: Control mode transitions');
    my $stay_body       = $section_body->('server.log: D-02 stays in connect');
    my $after_body      = $section_body->('server.log: after leaveConnect');
    my $d01b_body       = $section_body->('server.log: D-01(b) LMS stop / playlist clear notification');

    # The transition category holds L1 and NONE of L2-L6.
    like($transition_body, qr/LMS plays foreign content in connect -- leaveConnect/,
        '84.1-08 extract-run-leaveconnect-anchor: L1 (the real transition) is in the transition category');
    unlike($transition_body, qr/newsong without a url in connect/,
        '84.1-08 extract-run-leaveconnect-anchor: L2 (D-02 no-url stay) is NOT in the transition category');
    unlike($transition_body, qr/not re-adopting/,
        '84.1-08 extract-run-leaveconnect-anchor: L3 (re-adoption hold) is NOT in the transition category');
    unlike($transition_body, qr/newsong re-announces the song playing at connect entry/,
        '84.1-08 extract-run-leaveconnect-anchor: L4 (D-02 re-announce stay) is NOT in the transition category');
    unlike($transition_body, qr/deactivate not sent/,
        '84.1-08 extract-run-leaveconnect-anchor: L5 (IN-04 no-WS notice) is NOT in the transition category');
    unlike($transition_body, qr/D-01\(b\)/,
        '84.1-08 extract-run-leaveconnect-anchor: L6 (D-01(b) stop notification) is NOT in the transition category');

    # The D-02-stay category holds L2 and L4.
    like($stay_body, qr/newsong without a url in connect/,
        '84.1-08 extract-run-leaveconnect-anchor: L2 is in the D-02-stays-in-connect category');
    like($stay_body, qr/newsong re-announces the song playing at connect entry/,
        '84.1-08 extract-run-leaveconnect-anchor: L4 is in the D-02-stays-in-connect category');

    # The after-leaveConnect category holds L3 and L5.
    like($after_body, qr/not re-adopting/,
        '84.1-08 extract-run-leaveconnect-anchor: L3 is in the after-leaveConnect category');
    like($after_body, qr/deactivate not sent/,
        '84.1-08 extract-run-leaveconnect-anchor: L5 is in the after-leaveConnect category');

    # The D-01(b) category holds L6 only.
    like($d01b_body, qr/D-01\(b\): LMS stop notification/,
        '84.1-08 extract-run-leaveconnect-anchor: L6 is in the D-01(b) category');
    unlike($d01b_body, qr/leaveConnect/,
        '84.1-08 extract-run-leaveconnect-anchor: the D-01(b) category holds L6 only');

    unlink($file);
};

# ============================================================
# subtest 'extract-run-84-01-startoffset-verb' -- 84-01 (D-18, L1/L2
# attribution). Two Connect.pm INFO lines the attribution needs had no
# @SRV_CATS pattern and fell into the collective bucket (uncategorised lines
# are only counted): "Got spottyconnect event for <mac>: <verb>"
# (Connect.pm:1126) and "...: adjusted startOffset to N" (Connect.pm:1268
# seek branch, :1454 resume branch). L1/L2 are the verbatim shapes from the
# live server.log; L3 is the deliberate negative (LMS-internal line that
# mentions startOffset without the adjust wording); L4 is a neighbouring
# Connect line that must stay in the bucket.
# SUDO_BIN=/bin/true is REQUIRED (same precedent as 'extract-run-watchdog').
# ============================================================
subtest 'extract-run-84-01-startoffset-verb' => sub {
    my ($fh, $file) = tempfile();
    print $fh "[26-09-29 10:55:04.3190] Plugins::SpotOn::Connect::_connectEvent (1126) Got spottyconnect event for 02:00:00:5a:11:03: resume\n";
    print $fh "[26-09-29 10:55:04.3300] Plugins::SpotOn::Connect::_connectEvent (1268) Stream mode seek: adjusted startOffset to -87.498\n";
    print $fh "[26-09-29 10:55:04.3400] Plugins::SpotOn::Connect::_connectEvent (1454) Resume: adjusted startOffset to -3.25\n";
    print $fh "[26-09-29 10:55:04.3500] Slim::Player::Song::startOffset (77) startOffset read without adjust wording\n";
    print $fh "[26-09-29 10:55:04.3600] Plugins::SpotOn::Connect::_connectEvent (1260) Stream mode seek deferred: progress=12 (pending connect)\n";
    print $fh "[26-09-29 10:55:04.3700] Plugins::SpotOn::Soloist::Control::onEvent (3820) Control: transfer-in -- LMS holds 'spoton://track:1JSTJqkT5qHq8MDJnJbRE1', not the session track spotify:track:2M9ro2krNb7nr7HSprkEgo -- dropping the marker of an ended session, fresh start (02:00:00:5a:11:03)\n";
    print $fh "[26-09-29 10:55:04.3800] Plugins::SpotOn::Soloist::Control::onEvent (3790) Control: transfer-in -> mode=connect (02:00:00:5a:11:03)\n";
    close($fh);

    my ($exit, $stdout, $stderr) = run_perl_tool($extract_run_script,
        [ '02:00:00:5a:11:03', '10:55:00', '10:55:10',
          '--server-log', $file, '--date', '2026-09-29' ],
        SUDO_BIN => '/bin/true');

    my $section_body = sub {
        my ($hdr_re) = @_;
        return ($stdout =~ /---\s*\Q$hdr_re\E.*?---\n(.*?)(?=\n---|\z)/s) ? $1 : '';
    };
    my $verb_body = $section_body->('server.log: Connect verb event');
    my $off_body  = $section_body->('server.log: Connect startOffset adjust');

    is($exit, 0, 'extract-run-84-01: S01 tool runs with the SUDO_BIN stub (exit 0)')
        or diag("stderr: $stderr");
    like($verb_body, qr/Got spottyconnect event for 02:00:00:5a:11:03: resume/,
        'extract-run-84-01: S02 L1 (verb event) is in the new verb category');
    like($stdout, qr/^--- server\.log: Connect verb event[^\n]*\(Anzahl: 1 im Fenster/m,
        'extract-run-84-01: S03 verb header carries count 1');
    like($off_body, qr/Stream mode seek: adjusted startOffset to -87\.498/,
        'extract-run-84-01: S04 L2 (seek branch) is in the new startOffset category');
    like($off_body, qr/Resume: adjusted startOffset to -3\.25/,
        'extract-run-84-01: S05 L3 (resume branch) is in the new startOffset category');
    like($stdout, qr/^--- server\.log: Connect startOffset adjust[^\n]*\(Anzahl: 2 im Fenster/m,
        'extract-run-84-01: S06 startOffset header carries count 2 (seek + resume)');
    unlike($off_body, qr/without adjust wording/,
        'extract-run-84-01: S07 negative (startOffset without the adjust wording) stays out');
    unlike($verb_body, qr/deferred/,
        'extract-run-84-01: S08 neighbouring Connect line stays out of the verb category');
    my $drop_body = $section_body->('server.log: Control transfer-in drops the marker');
    like($drop_body, qr/LMS holds 'spoton:\/\/track:1JSTJqkT5qHq8MDJnJbRE1'.*dropping the marker/,
        'extract-run-84-01: S11 the marker-drop line is in its own category');
    unlike($drop_body, qr/transfer-in -> mode=connect/,
        'extract-run-84-01: S12 the plain transfer-in line stays out of the marker-drop category');
    like($stdout, qr/von den Fensterzeilen 2 in keiner Kategorie/,
        'extract-run-84-01: S09 remainder arithmetic -- 7 lines, 5 categorised, 2 in the bucket');
    unlike($stdout, qr/Restzaehler-Selbsttest[^\n]*FEHLGESCHLAGEN/,
        'extract-run-84-01: S10 remainder self-test stays silent');

    unlink($file);
};

# ============================================================
# 84-19 (Task 3, step 1): the acceptance runners' offline selftests as TAP.
# A runner's `selftest` prints `CASE=<name> EXPECTED=<E> GOT=<G> VERDICT=<OK|MISMATCH>`
# per case and exits 0 only when all are OK; this helper runs it once and gives
# every named case its own ok/not ok line, so a RED reads `not ok N - <runner>
# <case>` under `prove -v` (the tdd-red-evidence tool parses Node, not prove; the
# `not ok` line is the evidence). Cases whose archive input is absent on a host
# (measurement data is not in git) are skipped by the caller, not by this helper.
# ============================================================
my $runners_84 = "$project_dir/.planning/phases/84-soloist-uat-und-backend-trennnaht/runners";

sub runner_selftest_cases {
    my ($script, $args, @cases) = @_;
    my ($exit, $stdout, $stderr) = run_tool($script, $args);
    my $name = basename($script);
    for my $case (@cases) {
        my ($line) = $stdout =~ /^(CASE=\Q$case\E\s[^\n]*)$/m;
        ok(defined $line && $line =~ /VERDICT=OK$/, "84-19 $name selftest: $case")
            or diag(defined $line ? $line : "case '$case' not printed by the selftest");
    }
    is($exit, 0, "84-19 $name selftest: exits 0 (SELFTEST=PASS)")
        or diag("stdout: $stdout\nstderr: $stderr");
    like($stdout, qr/^SELFTEST=PASS$/m, "84-19 $name selftest: prints SELFTEST=PASS");
    return $stdout;
}

# 84-09: environment skip (CI has no .planning / measurement archive) as a
# SKIP around the subtest -- same TAP as the former in-subtest skip-all
# (one `ok N # skip` in the parent), no plan-level skip in a soloist file.
SKIP: {
    skip 'rapid-skip.sh not present in this checkout (.planning absent: CI)', 1 unless -f "$runners_84/rapid-skip.sh";
subtest '84-19 runner selftests' => sub {
    my $rapid = "$runners_84/rapid-skip.sh";
    # F-04-02 (B8): errors[] counted from the storm start, real archive errors[].
    runner_selftest_cases($rapid, ['selftest'],
        qw(errors_entry_before_storm_ignored errors_pa_entry_before_storm_ignored
           errors_entry_inside_run_window_counted errors_entry_at_run_start_counted
           errors_entry_one_second_before_run_ignored errors_entry_other_mac_not_counted
           errors_unreadable_stays_unreadable));

    # F-04-06 (R4): gate_core over real archived runs; both-daemons-quiet arm gate.
    my $gap15 = "$runners_84/gap-15-exit10-live.sh";
    my $mdir  = "$ENV{HOME}/SynologyDrive/dev/spoton-messdaten";
  SKIP: {
        skip 'gap-15 archive runs (83.3-15-live-260927-1549/-1203, 84-03-gap15-261001-2025) not on this host (measurement data, not in git)', 12
            unless -f "$mdir/83.3-15-live-260927-1549/server-log-snapshot.txt"
                && -f "$mdir/83.3-15-live-260927-1203/server-log-snapshot.txt"
                && -f "$mdir/84-03-gap15-261001-2025/server-log-snapshot.txt";
        runner_selftest_cases($gap15, ['selftest'],
            qw(real_pass_run_promoted_reads_pass real_pass_run_cdn_expired_reads_pass
               real_r4_run_exit10_on_other_mac_reads_pass
               doctored_no_exit10_line_reads_fail doctored_r4_no_exit10_line_reads_fail
               doctored_two_exit10_lines_reads_fail doctored_no_renewal_attempt_reads_fail
               quiet_real_uat_only_status_not_quiet quiet_both_listed_stable_30s
               quiet_window_too_short quiet_pa_pid_changed_mid_window quiet_pa_dies_at_end
               arm_recheck_same_pids_unchanged arm_recheck_pa_pid_differs
               arm_recheck_pa_missing_real_r4_status));
    }

    # F-04-01 (B5): a run against an idle player is UNBESTIMMT, never FAIL; with the precondition met the gate still fails.
    runner_selftest_cases("$runners_84/volume.sh", ['selftest'],
        qw(real_recorder_frames_carry_77 real_recorder_never_shows_30
           doctored_real_recorder_without_volume
           synthetic_both_values_echoed synthetic_60_never_echoed synthetic_60_echo_2_5s_late
           idle_run_real_recorder_precondition_met_still_fails
           idle_run_real_recorder_precondition_missing_unbestimmt
           idle_run_precondition_unknown_unbestimmt
           echoed_frames_without_precondition_still_pass));

    # F-04-05 (R2): the stops-answering stand-in answers by TIME (every sender inside the window), then goes silent.
    # standin-ws.py is Python: run it with python3 directly (run_tool execs bash).
    my $standin = "$runners_84/standin-ws.py";
    my $st_out = `python3 $standin selftest 2>&1`;
    my $st_exit = $? >> 8;
    for my $case (qw(first_probe_answered_logged_in
                     second_probe_same_connection_within_window_answered
                     initial_probe_of_new_connection_within_window_answered
                     probe_after_window_unanswered_new_connection
                     probe_after_window_unanswered_old_connection
                     never_login_answers_not_logged_in_after_window never_login_never_goes_silent)) {
        my ($line) = $st_out =~ /^(CASE=\Q$case\E\s[^\n]*)$/m;
        ok(defined $line && $line =~ /VERDICT=OK$/, "84-19 standin-ws.py selftest: $case")
            or diag(defined $line ? $line : "case '$case' not printed by the selftest");
    }
    is($st_exit, 0, '84-19 standin-ws.py selftest: exits 0 (SELFTEST=PASS)') or diag($st_out);
};
}

# ---------------------------------------------------------------------------
# subtest 'd15-frames-literal-subset' -- 84.2 Nyquist (VALIDATION row 7, D-15).
# t/44 cases F/F2 claim their fixtures are the inner `frame` text of real
# recordings at fixed line numbers (header comments of the .frames files).
# Each fixture line must equal, byte for byte, the decoded `frame` field of the
# named ws.jsonl line. MUST-FAIL: a copy with one byte changed is rejected.
# Skips when the spoton-messdaten archive is absent (CI).
# ---------------------------------------------------------------------------
sub _frames_vs_archive {
    my ($fixture, $ws, $first) = @_;
    open(my $fh, '<', $fixture) or return ("cannot open $fixture");
    my @fx = grep { length && !/^#/ } map { chomp; $_ } <$fh>;
    close $fh;
    open(my $wh, '<', $ws) or return ("cannot open $ws");
    my @wl = <$wh>;
    close $wh;
    my @bad;
    for my $i (0 .. $#fx) {
        my $n = $first + $i;
        my $rec = eval { JSON::PP->new->decode($wl[$n - 1]) };
        my $fr = ref $rec ? $rec->{frame} : undef;
        push @bad, "line $n: fixture[$i] differs" unless defined $fr && $fr eq $fx[$i];
    }
    return @bad;
}

# 84-09: environment skip (CI has no .planning / measurement archive) as a
# SKIP around the subtest -- same TAP as the former in-subtest skip-all
# (one `ok N # skip` in the parent), no plan-level skip in a soloist file.
SKIP: {
    skip 'spoton-messdaten archive absent (CI)', 1 unless -d "$ENV{HOME}/SynologyDrive/dev/spoton-messdaten";
subtest 'd15-frames-literal-subset' => sub {
    my $M = "$ENV{HOME}/SynologyDrive/dev/spoton-messdaten";
    my $fxd = "$project_dir/t/fixtures/soloist";
    for my $c (['84-2-off1-context-end.frames', "$M/84-19-spike-autoplay-261004/off-1/ws.jsonl", 15, 7],
               ['84-2-run7-context-end.frames', "$M/84-04-c5/run7/ws-all.jsonl",            20, 8]) {
        my ($fx, $ws, $first, $n) = @$c;
        ok(-s $ws, "$fx: archive $ws present") or next;
        my @bad = _frames_vs_archive("$fxd/$fx", $ws, $first);
        is(scalar(@bad), 0, "$fx: all $n frames are literal ws lines $first..".($first+$n-1)) or diag(join "\n", @bad);
        # MUST-FAIL: one byte inserted into the last frame
        my ($th, $tmp) = tempfile(UNLINK => 1);
        open(my $in, '<', "$fxd/$fx") or die;
        my @l = <$in>; close $in;
        $l[-1] =~ s/\}(\s*)$/ }$1/;  # one inserted byte
        print $th @l; close $th;
        my @bad2 = _frames_vs_archive($tmp, $ws, $first);
        is(scalar(@bad2), 1, "$fx: doctored copy is rejected (exactly the changed frame)");
    }
};
}

# ---------------------------------------------------------------------------
# subtest 'remeasure-doc-gate' -- 84.2 Nyquist (VALIDATION row 12). Makes the
# one-off 84.2-04 Task-4 gate permanent: the real 84-ACCEPTANCE.md MUST PASS,
# a copy cut before `## Pre-seam reference (84.2)` MUST FAIL; same pair for
# the 84-11 reader (ACCEPTANCE_RUN_DIR_84_2 -> results.tsv). Skips without
# .planning (CI) or the measurement archive.
# ---------------------------------------------------------------------------
# 84-09: environment skip (CI has no .planning / measurement archive) as a
# SKIP around the subtest -- same TAP as the former in-subtest skip-all
# (one `ok N # skip` in the parent), no plan-level skip in a soloist file.
SKIP: {
    skip '.planning absent (CI)', 1 unless -f "$project_dir/.planning/phases/84-soloist-uat-und-backend-trennnaht/84-ACCEPTANCE.md" && -f "$project_dir/.planning/phases/84.2-titelfortsetzung-und-autoplay-neutralitaet/84.2-04-offround/t4-gate.sh";
    skip 'spoton-messdaten archive absent', 1 unless -d "$ENV{HOME}/SynologyDrive/dev/spoton-messdaten";
subtest 'remeasure-doc-gate' => sub {
    my $acc  = "$project_dir/.planning/phases/84-soloist-uat-und-backend-trennnaht/84-ACCEPTANCE.md";
    my $gate = "$project_dir/.planning/phases/84.2-titelfortsetzung-und-autoplay-neutralitaet/84.2-04-offround/t4-gate.sh";
    my $dir = tempdir(CLEANUP => 1);
    my $cut = "$dir/84-ACCEPTANCE-cut.md";
    system('sh', '-c', q{awk '/^## Pre-seam reference \(84.2\)/{exit} {print}' "$1" > "$2"}, 'x', $acc, $cut);
    ok(-s $cut && -s $cut < -s $acc, 'cut copy is non-empty and shorter');
    my $reader = q{R=$(command grep -oE '^ACCEPTANCE_RUN_DIR_84_2=.*' "$1" | tail -1 | cut -d= -f2-) && test -s "$R/results.tsv"};
    is(system('bash', $gate, $acc) >> 8, 0, 'T4 block gate: real 84-ACCEPTANCE.md PASSES');
    isnt(system('bash', $gate, $cut) >> 8, 0, 'T4 block gate: copy without the 84.2 block FAILS');
    is(system('bash', '-c', $reader, 'x', $acc) >> 8, 0, '84-11 reader: real file resolves a results.tsv');
    isnt(system('bash', '-c', $reader, 'x', $cut) >> 8, 0, '84-11 reader: cut copy resolves nothing');
};
}

# ---------------------------------------------------------------------------
# 85-01 (D-25 runtime gate chain): extract-run category + webapi-gate.pl verdict + menu-walk.pl.
# Real input: the run8 server.log cut (t/fixtures/uat/84.3-c5-run8-server-pause-won.log, byte-exact
# from the archived server.log). The MUST-FAIL input is that cut plus ONE fabricated Web-API line
# (doctored real input); the MUST-PASS input is the unmodified cut.
# ---------------------------------------------------------------------------
my $webapi_gate_script = "$project_dir/tools/uat/webapi-gate.pl";
my $menu_walk_script   = "$project_dir/tools/uat/menu-walk.pl";
my $webapi_fx          = "$project_dir/t/fixtures/uat/84.3-c5-run8-server-pause-won.log";
my $webapi_cat         = 'server.log: Web API request (api.spotify.com;';
my $webapi_fab_line    = "[26-10-09 21:09:28.0001] Slim::Networking::SimpleHTTP::Base::_createHTTPRequest (97) GETing https://api.spotify.com/v1/me/top/tracks?limit=50";

# Writes the real cut (optionally doctored with the fabricated line after its first line) to a
# temp file and returns its path.
sub _webapi_server_log {
    my ($doctor) = @_;
    my $text = _slurp($webapi_fx);
    if ($doctor) {
        $text =~ s/\A([^\n]*\n)/$1$webapi_fab_line\n/ or die "webapi fixture has no first line";
    }
    my ($fh, $file) = tempfile();
    binmode($fh);
    print $fh $text;
    close($fh);
    return $file;
}

# Runs extract-run over the 21:09:27..21:09:29 window of $server_log; returns ($exit, $stdout, $out_file).
sub _webapi_extract {
    my ($server_log, $date) = @_;
    my @args = ('02:00:00:5a:11:01', '21:09:27', '21:09:29', '--server-log', $server_log, '--date', $date);
    my ($exit, $out, $err) = run_perl_tool($extract_run_script, \@args, SUDO_BIN => '/bin/true');
    my ($fh, $file) = tempfile();
    print $fh $out;
    close($fh);
    return ($exit, $out, $file, $err);
}

sub _webapi_section {
    my ($stdout) = @_;
    return ($stdout =~ /---\s*\Q$webapi_cat\E.*?---\n(.*?)(?=\n---|\z)/s) ? $1 : '';
}

subtest 'extract-run-85-webapi' => sub {
    ok(-s $webapi_fx, 'extract-run-85-webapi: real run8 cut present');
    my $doctored = _webapi_server_log(1);
    my $real     = _webapi_server_log(0);

    my ($exitD, $outD, undef, $errD) = _webapi_extract($doctored, '2026-10-09');
    is($exitD, 0, 'extract-run-85-webapi: doctored real cut -- extract-run runs (exit 0)') or diag("stderr: $errD");
    like($outD, qr/---\s*\Q$webapi_cat\E[^\n]*\(Anzahl: 1 im Fenster/,
        'extract-run-85-webapi: doctored real cut -- Web-API section header carries (Anzahl: 1 im Fenster');
    my @linesD = grep { /\S/ } split /\n/, _webapi_section($outD);
    is(scalar(@linesD), 1, 'extract-run-85-webapi: doctored real cut -- the section holds exactly one line');
    is($linesD[0], $webapi_fab_line, 'extract-run-85-webapi: doctored real cut -- that line is the fabricated GETing line, verbatim');
    like($outD, qr/\Q$webapi_cat\E[^\n]* ---\n[^\n]*GETing[^\n]*\n\n--- server\.log: /,
        'extract-run-85-webapi: the section ends at the next category header (it is not the last section, so no remainder line lands in its body)');
    unlike(_webapi_section($outD), qr/server\.log-Fensterzeilen/, 'extract-run-85-webapi: the remainder line is not part of the section body');

    my ($exitR, $outR, undef, $errR) = _webapi_extract($real, '2026-10-09');
    is($exitR, 0, 'extract-run-85-webapi: unmodified real cut -- extract-run runs (exit 0)') or diag("stderr: $errR");
    my $secR = _webapi_section($outR);
    is(scalar(grep { /GETing|POSTing|PUTing|DELETEing/ } split /\n/, $secR), 0,
        'extract-run-85-webapi: unmodified real cut -- zero GETing/POSTing lines in the section');
    like($outR, qr/\[MUSTER NICHT GEFUNDEN IM FENSTER\] \Q$webapi_cat\E/,
        'extract-run-85-webapi: unmodified real cut -- the section reads "nicht gefunden im Fenster" (rule 4), not a verdict');
    unlink($doctored, $real);
};

subtest 'webapi-gate' => sub {
    my $doctored = _webapi_server_log(1);
    my $real     = _webapi_server_log(0);
    my (undef, undef, $extD)   = _webapi_extract($doctored, '2026-10-09');
    my (undef, undef, $extR)   = _webapi_extract($real, '2026-10-09');
    my (undef, undef, $ext_nc) = _webapi_extract($real, '2026-10-10');   # no line of that day

    my $walk_file = sub {
        my ($text) = @_;
        my ($fh, $f) = tempfile();
        print $fh $text;
        close($fh);
        return $f;
    };
    my $walk_ok   = $walk_file->("ARMED network.asynchttp=DEBUG at 21:09:20.000\nWALK_DONE menus=1 unanswered=0\n");
    my $walk_none = $walk_file->("WALK_DONE menus=1 unanswered=0\n");
    my $walk_late = $walk_file->("ARMED network.asynchttp=DEBUG at 21:09:28.000\nWALK_DONE menus=1 unanswered=0\n");
    my $walk_fail = $walk_file->("ARM_FAILED network.asynchttp=ERROR\n");

    my $gate = sub {
        my ($ext, $walk) = @_;
        my ($exit, $out, $err) = run_perl_tool($webapi_gate_script, ['--extract', $ext, '--walk', $walk, '--from', '21:09:27']);
        my @l = split /\n/, $out;
        return ($exit, $l[-1] // '', $out, $err);
    };

    my ($e1, $last1) = $gate->($extD, $walk_ok);
    is($e1, 1, 'webapi-gate: MUST-FAIL doctored real cut -- exit 1');
    is($last1, 'WEBAPI_GATE=FAIL webapi_lines=1 reason=webapi_requests', 'webapi-gate: MUST-FAIL doctored real cut -- verdict line');

    my ($e2, $last2) = $gate->($extR, $walk_ok);
    is($e2, 0, 'webapi-gate: MUST-PASS unmodified real cut -- exit 0');
    is($last2, 'WEBAPI_GATE=PASS webapi_lines=0', 'webapi-gate: MUST-PASS unmodified real cut -- verdict line');

    my ($e3, $last3) = $gate->($extR, $walk_none);
    is($e3, 1, 'webapi-gate: walk without ARMED line -- exit 1');
    is($last3, 'WEBAPI_GATE=FAIL webapi_lines=0 reason=not_armed_before_window', 'webapi-gate: walk without ARMED line -- reason');

    my ($e4, $last4) = $gate->($extR, $walk_late);
    is($e4, 1, 'webapi-gate: ARMED at 21:09:28 (after --from 21:09:27) -- exit 1');
    is($last4, 'WEBAPI_GATE=FAIL webapi_lines=0 reason=not_armed_before_window', 'webapi-gate: late-armed walk -- reason');

    my ($e5, $last5) = $gate->($extR, $walk_fail);
    is($e5, 1, 'webapi-gate: ARM_FAILED walk -- exit 1');
    is($last5, 'WEBAPI_GATE=FAIL webapi_lines=0 reason=not_armed_before_window', 'webapi-gate: ARM_FAILED walk -- reason');

    my ($e6, $last6) = $gate->($ext_nc, $walk_ok);
    is($e6, 1, 'webapi-gate: extract run over a day with no server.log line (--date 2026-10-10) -- exit 1');
    is($last6, 'WEBAPI_GATE=FAIL webapi_lines=0 reason=window_not_covered', 'webapi-gate: uncovered window -- reason (absence is not refutation)');

    # category_missing: the real output with the Web-API section cut out
    my $text = _slurp($extR);
    (my $cut = $text) =~ s/^--- \Q$webapi_cat\E[^\n]*\n.*?\n\n//ms;
    isnt($cut, $text, 'webapi-gate: category_missing input -- the section was cut out of the real output');
    my $ext_cut = $walk_file->($cut);
    my ($e7, $last7) = $gate->($ext_cut, $walk_ok);
    is($e7, 1, 'webapi-gate: extract output without the category section -- exit 1');
    is($last7, 'WEBAPI_GATE=FAIL webapi_lines=0 reason=category_missing', 'webapi-gate: missing section -- reason');

    my ($e8) = run_perl_tool($webapi_gate_script, ['--extract', $extR, '--walk', $walk_ok]);
    is($e8, 2, 'webapi-gate: missing --from is a usage error (exit 2)');
    unlink($doctored, $real, $extD, $extR, $ext_nc, $walk_ok, $walk_none, $walk_late, $walk_fail, $ext_cut);
};

# 85-03: the D-25 runtime gate on REAL pre-phase material (t/fixtures/uat/85-03-server-webapi-prephase.log,
# server.log of the 2026-10-16 19:10:23..19:11:35 menu walk on the pre-phase tree, Bearer headers and the
# username masked). MUST-FAIL: the old Web-API code is live there, so the verdict tool has to answer FAIL.
subtest 'webapi-gate-85-03-real' => sub {
    my $fx = "$project_dir/t/fixtures/uat/85-03-server-webapi-prephase.log";
    ok(-s $fx, 'webapi-gate-85-03-real: real pre-phase cut present');
    my ($exit, $out, $err) = run_perl_tool($extract_run_script,
        ['02:00:00:5a:11:01', '19:10:23', '19:11:35', '--server-log', $fx, '--date', '2026-10-16'], SUDO_BIN => '/bin/true');
    is($exit, 0, 'webapi-gate-85-03-real: extract-run over the real cut runs (exit 0)') or diag("stderr: $err");
    my ($efh, $ext) = tempfile();
    print $efh $out;
    close($efh);
    my ($wfh, $walk) = tempfile();
    print $wfh "ARMED network.asynchttp=DEBUG at 19:10:22.779\nWALK_DONE menus=1 unanswered=0\n";
    close($wfh);
    my ($gexit, $gout, $gerr) = run_perl_tool($webapi_gate_script, ['--extract', $ext, '--walk', $walk, '--from', '19:10:23']);
    my @l = split /\n/, $gout;
    is($gexit, 1, 'webapi-gate-85-03-real: real pre-phase cut -- exit 1 (MUST-FAIL)') or diag("stderr: $gerr");
    like($l[-1] // '', qr/^WEBAPI_GATE=FAIL webapi_lines=[1-9][0-9]* reason=webapi_requests$/,
        'webapi-gate-85-03-real: last line is the FAIL verdict with reason=webapi_requests');
    my @cat = grep { /(?:GETing|POSTing|PUTing|DELETEing)/ } split /\n/, _webapi_section($out);
    cmp_ok(scalar(@cat), '>=', 1, 'webapi-gate-85-03-real: the category section holds >= 1 request line');
    is(scalar(grep { index($_, 'api.spotify.com') < 0 } @cat), 0,
        'webapi-gate-85-03-real: every request line of the section names api.spotify.com');
    ok((grep { m{api\.spotify\.com/v1/me/player/queue} } @cat) ? 1 : 0,
        'webapi-gate-85-03-real: the Up Next node request (me/player/queue) is among them');
    unlike(_slurp($fx), qr/Bearer\s+[A-Za-z0-9_-]{8,}/, 'webapi-gate-85-03-real: the fixture carries no Bearer token');
    unlink($ext, $walk);
};

# 85-16: the four auth-chain extract-run categories, each on a doctored REAL input -- the byte-exact run8
# server.log cut plus ONE injected line in the real server.log line layout
# (`[YY-MM-DD HH:MM:SS.mmmm] <Package::sub> (<line>) <message>`) with the message text the code logs
# (AccountMigration.pm:116/:175, Credentials.pm:528/:567/:578, Plugin.pm:473). MUST-PASS side: the
# unmodified cut prints none of them (rule 4: "nicht gefunden im Fenster", never a verdict).
my %authchain_cat = (
    migration   => 'server.log: 85 auth-chain migration (D-02/D-03)',
    credentials => 'server.log: 85 credentials installed (D-21/D-23)',
    pkce        => 'server.log: 85 PKCE artifact cleanup (D-01)',
    discover    => 'server.log: 85 discover intake refused (D-23)',
);
my @authchain_cases = (
    [ migration   => 'Plugins::SpotOn::API::AccountMigration::run (116) Auth chain migration: account 7716**** kept (same id)' ],
    [ migration   => 'Plugins::SpotOn::API::AccountMigration::run (175) Auth chain migration: account 0bad**** re-keyed to 7716****' ],
    [ credentials => 'Plugins::SpotOn::API::Credentials::installAccountCredentials (528) Pairing: paired credentials installed for account 7716**** (source pairing)' ],
    [ pkce        => 'Plugins::SpotOn::Plugin::_removePkceOnce (473) PKCE cleanup: removed 2 stored token file(s), the Client-ID pref and the token cache keys' ],
    [ discover    => 'Plugins::SpotOn::API::Credentials::importFromDiscover (567) Credentials: the discover folder is a symlink -- refused' ],
);

subtest 'extract-run-85-authchain' => sub {
    ok(-s $webapi_fx, 'extract-run-85-authchain: real run8 cut present');
    for my $case (@authchain_cases) {
        my ($key, $msg) = @$case;
        my $cat  = $authchain_cat{$key};
        my $line = "[26-10-09 21:09:28.0001] $msg";
        my $text = _slurp($webapi_fx);
        $text =~ s/\A([^\n]*\n)/$1$line\n/ or die "fixture has no first line";
        my ($fh, $file) = tempfile();
        binmode($fh);
        print $fh $text;
        close($fh);
        my ($exit, $out, undef, $err) = _webapi_extract($file, '2026-10-09');
        is($exit, 0, "extract-run-85-authchain[$key]: extract-run runs (exit 0)") or diag("stderr: $err");
        like($out, qr/---\s*\Q$cat\E \(Anzahl: 1 im Fenster/,
            "extract-run-85-authchain[$key]: header '$cat' carries (Anzahl: 1 im Fenster");
        ok($out =~ /---\s*\Q$cat\E[^\n]*---\n([^\n]*)\n/ && $1 eq $line,
            "extract-run-85-authchain[$key]: the injected line is printed under its category, verbatim");
        unlike($out, qr/---\s*\Q$webapi_cat\E[^\n]*\(Anzahl: [1-9]/,
            "extract-run-85-authchain[$key]: the line is not mistaken for a Web-API request");
        unlink($file);
    }
    my $real = _webapi_server_log(0);
    my ($exitR, $outR, undef, $errR) = _webapi_extract($real, '2026-10-09');
    is($exitR, 0, 'extract-run-85-authchain: unmodified real cut -- extract-run runs (exit 0)') or diag("stderr: $errR");
    for my $key (sort keys %authchain_cat) {
        like($outR, qr/\[MUSTER NICHT GEFUNDEN IM FENSTER\] \Q$authchain_cat{$key}\E/,
            "extract-run-85-authchain[$key]: unmodified real cut -- reads 'nicht gefunden im Fenster', no verdict");
    }
    unlink($real);
};

# 79-13 (D-03, point 19): the librespot eject category. Backend/Librespot.pm _sendControlCommand writes, on a
# 409, a WARN line at every level from WARN up (:360-363) and its [DIAG] twin only while diagnosticMode=1 (:364).
# Without a category both were only counted (rule 4), so "eject on deselect" could not be proven from a log.
# NO real archive line exists for either text (searched 2026-10-19: /var/log/squeezeboxserver/server.log and
# server.log.1-5.gz, spoton-messdaten, t/: 0 hits), so the injected text is the code's own format string in the
# real server.log layout, put into the real run8 cut; the first live l19 extract is the first real instance.
my $eject_cat = 'server.log: librespot eject on deselect (GH #159: control command rejected 409; Backend/Librespot.pm _sendControlCommand)';
my @eject_cases = (
    [ warn => '[26-10-09 21:09:28.0001] Plugins::SpotOn::Backend::Librespot::_sendControlCommand (360) '
            . '_sendControlCommand: pause rejected for 02:00:00:5a:11:01 - device is not the active Connect target (GH #159); ejecting stale stream' ],
    [ diag => '[26-10-09 21:09:28.0002] Plugins::SpotOn::Backend::Librespot::_sendControlCommand (364) '
            . '[DIAG] control_cmd_rejected: mac=02:00:00:5a:11:01 endpoint=pause code=409' ],
);

subtest 'extract-run-79-eject' => sub {
    ok(-s $webapi_fx, 'extract-run-79-eject: real run8 cut present');
    for my $case (@eject_cases) {
        my ($key, $line) = @$case;
        my $text = _slurp($webapi_fx);
        $text =~ s/\A([^\n]*\n)/$1$line\n/ or die "fixture has no first line";
        my ($fh, $file) = tempfile();
        binmode($fh);
        print $fh $text;
        close($fh);
        my ($exit, $out, undef, $err) = _webapi_extract($file, '2026-10-09');
        is($exit, 0, "extract-run-79-eject[$key]: extract-run runs (exit 0)") or diag("stderr: $err");
        like($out, qr/---\s*\Q$eject_cat\E \(Anzahl: 1 im Fenster/,
            "extract-run-79-eject[$key]: header carries (Anzahl: 1 im Fenster");
        ok($out =~ /---\s*\Q$eject_cat\E[^\n]*---\n([^\n]*)\n/ && $1 eq $line,
            "extract-run-79-eject[$key]: the injected line is printed under the eject category, verbatim");
        unlike($out, qr/---\s*\Q$webapi_cat\E[^\n]*\(Anzahl: [1-9]/,
            "extract-run-79-eject[$key]: the line is not mistaken for a Web-API request");
        unlink($file);
    }
    my $real = _webapi_server_log(0);
    my ($exitR, $outR, undef, $errR) = _webapi_extract($real, '2026-10-09');
    is($exitR, 0, 'extract-run-79-eject: unmodified real cut -- extract-run runs (exit 0)') or diag("stderr: $errR");
    like($outR, qr/\[MUSTER NICHT GEFUNDEN IM FENSTER\] \Q$eject_cat\E/,
        'extract-run-79-eject: unmodified real cut -- reads "nicht gefunden im Fenster", no verdict (absence is no verdict)');
    unlink($real);
};

# 79-42 (D-33 FULL-2 CR-01): the `[DIAG] [<ts>] stop: player=<mac> ...` lines Connect.pm writes in diagnostic mode
# (stop branch: sessionEnd=1, or isPlaying=<0|1> gracePeriod=<0|1>) had no category, so a stop swallowed by the
# CONNECT_START_GRACE was only counted (rule 4). Real input: the run8 cut carries a real `stop: ... gracePeriod=0` line
# (:27) and a real `[DIAG] seek_from_binary:` line (:31). The `gracePeriod=1` form is a real archive line
# (spoton-messdaten/79-29-forensics/logs/server.log, 2026-10-22 10:07:47) re-stamped into the run8 window.
my $stopdiag_cat = 'server.log: Connect stop decision ([DIAG] stop: sessionEnd / gracePeriod; Connect.pm _connectEvent stop branch, 79-42 D-33)';
my $stopdiag_grace_line = '[26-10-09 21:09:28.0005] Plugins::SpotOn::Connect::_connectEvent (2558) '
    . '[DIAG] [1792656467.729] stop: player=02:00:00:5a:11:01 isPlaying=1 gracePeriod=1 elapsed=0.000';

subtest 'extract-run-79-42-stopdiag' => sub {
    ok(-s $webapi_fx, 'extract-run-79-42-stopdiag: real run8 cut present');
    my $section = sub {
        my ($out) = @_;
        return ($out =~ /---\s*\Q$stopdiag_cat\E[^\n]*---\n(.*?)(?=\n---|\z)/s) ? $1 : '';
    };

    # A: the unmodified real cut -- its real gracePeriod=0 stop line lands in the new category.
    my $real = _webapi_server_log(0);
    my ($exitR, $outR, undef, $errR) = _webapi_extract($real, '2026-10-09');
    is($exitR, 0, 'extract-run-79-42-stopdiag: real cut -- extract-run runs (exit 0)') or diag("stderr: $errR");
    like($outR, qr/---\s*\Q$stopdiag_cat\E \(Anzahl: 1 im Fenster/,
        'extract-run-79-42-stopdiag: real cut -- the category header counts the one real stop line');
    like($section->($outR), qr/stop: player=02:00:00:5a:11:01 isPlaying=0 gracePeriod=0/,
        'extract-run-79-42-stopdiag: real cut -- the real gracePeriod=0 line is printed under the category');
    unlike($section->($outR), qr/seek_from_binary/,
        'extract-run-79-42-stopdiag: real cut -- a [DIAG] line without stop: stays out of the category');
    unlink($real);

    # B: the real gracePeriod=1 form injected into the cut -- both stop lines print, the grace one verbatim.
    my $text = _slurp($webapi_fx);
    $text =~ s/\A([^\n]*\n)/$1$stopdiag_grace_line\n/ or die "fixture has no first line";
    my ($fh, $file) = tempfile();
    binmode($fh);
    print $fh $text;
    close($fh);
    my ($exit, $out, undef, $err) = _webapi_extract($file, '2026-10-09');
    is($exit, 0, 'extract-run-79-42-stopdiag: injected cut -- extract-run runs (exit 0)') or diag("stderr: $err");
    like($out, qr/---\s*\Q$stopdiag_cat\E \(Anzahl: 2 im Fenster/,
        'extract-run-79-42-stopdiag: injected cut -- header counts both stop lines');
    like($section->($out), qr/\Q$stopdiag_grace_line\E/,
        'extract-run-79-42-stopdiag: injected cut -- the gracePeriod=1 line is printed under the category, verbatim');
    unlink($file);
};

# 79-27 (D-18): the spclient track-metadata request category. SpClient hydrates a track list with one
# `GET metadata/4/track/<hex>` per track (cap 2) or, after 79-27, one `POST extended-metadata/v0/extended-metadata`
# per batch; both are logged by network.asynchttp at DEBUG (`<TYPE>ing <url>`, SimpleHTTP/Base.pm:97) only while the
# runtime switch is armed. Real input: the 85-03 menu-walk server.log (t/fixtures/uat/85-03-server-webapi-prephase.log)
# carries real `GETing https://gew4-spclient.spotify.com:443/metadata/4/track/<32 hex>` lines. NO real archive line exists
# for the POST extended-metadata form (searched 2026-10-21: spoton-messdaten and t/fixtures, asynchttp lines only), so
# that one is injected in the core layout into the real run8 cut, together with a second GET line: both must print.
my $spc_cat = 'server.log: spclient track metadata request (network.asynchttp DEBUG "<TYPE>ing <url>": metadata/4/track or extended-metadata, 79-27 D-18)';
my @spc_lines = (
    '[26-10-09 21:09:28.0003] Slim::Networking::SimpleHTTP::Base::_createHTTPRequest (97) POSTing https://gew4-spclient.spotify.com:443/extended-metadata/v0/extended-metadata',
    '[26-10-09 21:09:28.0004] Slim::Networking::SimpleHTTP::Base::_createHTTPRequest (97) GETing https://gew4-spclient.spotify.com:443/metadata/4/track/e402db50b5214cac86d9d2e79d12a759',
);

subtest 'extract-run-79-27-spclient' => sub {
    ok(-s $webapi_fx, 'extract-run-79-27-spclient: real run8 cut present');
    my $text = _slurp($webapi_fx);
    $text =~ s/\A([^\n]*\n)/$1 . join("\n", @spc_lines) . "\n"/e or die "fixture has no first line";
    my ($fh, $file) = tempfile();
    binmode($fh);
    print $fh $text;
    close($fh);
    my ($exit, $out, undef, $err) = _webapi_extract($file, '2026-10-09');
    is($exit, 0, 'extract-run-79-27-spclient: extract-run over the doctored real cut runs (exit 0)') or diag("stderr: $err");
    like($out, qr/---\s*\Q$spc_cat\E \(Anzahl: 2 im Fenster/,
        'extract-run-79-27-spclient: header carries (Anzahl: 2 im Fenster');
    my ($sec) = $out =~ /---\s*\Q$spc_cat\E[^\n]*---\n(.*?)(?=\n---|\z)/s;
    $sec //= '';
    my @got = grep { length } split /\n/, $sec;
    is(join("\n", @got[0 .. 1]), join("\n", @spc_lines),
        'extract-run-79-27-spclient: both injected lines are printed under the new category, verbatim');
    unlike($out, qr/---\s*\Q$webapi_cat\E[^\n]*\(Anzahl: [1-9]/,
        'extract-run-79-27-spclient: neither line counts under the Web API category');
    unlink($file);

    my $real = _webapi_server_log(0);
    my ($exitR, $outR, undef, $errR) = _webapi_extract($real, '2026-10-09');
    is($exitR, 0, 'extract-run-79-27-spclient: unmodified real cut -- extract-run runs (exit 0)') or diag("stderr: $errR");
    like($outR, qr/\[MUSTER NICHT GEFUNDEN IM FENSTER\] \Q$spc_cat\E/,
        'extract-run-79-27-spclient: unmodified real cut -- reads "nicht gefunden im Fenster", no verdict (absence is no verdict)');
    unlink($real);

    # MUST-PASS on real material: the 85-03 cut, window 19:10:25..19:10:26 (the first Liked/search hydration burst).
    my $fx = "$project_dir/t/fixtures/uat/85-03-server-webapi-prephase.log";
    # extract-run pads the window by 3 s per side (header: "19:10:23.000..19:10:31.000"), so the expected count is taken over that span
    my @want = grep { /^\[26-10-16 (19:10:\d\d)\.\d+\] .*\b(?:GET|POST)ing https:\/\/\S+\/(?:metadata\/4\/track\/[0-9a-f]{32}|extended-metadata\/v0\/extended-metadata)/
                      && $1 ge '19:10:23' && $1 lt '19:10:31' } split /\n/, _slurp($fx);
    cmp_ok(scalar(@want), '>=', 2, 'extract-run-79-27-spclient: the real 85-03 cut holds >= 2 metadata/4/track request lines in the window');
    my ($xe, $xo, $xerr) = run_perl_tool($extract_run_script,
        ['02:00:00:5a:11:01', '19:10:25', '19:10:26', '--server-log', $fx, '--date', '2026-10-16'], SUDO_BIN => '/bin/true');
    is($xe, 0, 'extract-run-79-27-spclient: real 85-03 cut -- extract-run runs (exit 0)') or diag("stderr: $xerr");
    my $n = scalar(@want);
    like($xo, qr/---\s*\Q$spc_cat\E \(Anzahl: \Q$n\E im Fenster/,
        "extract-run-79-27-spclient: real 85-03 cut -- the header counts the $n real request lines");
    my ($rsec) = $xo =~ /---\s*\Q$spc_cat\E[^\n]*---\n(.*?)(?=\n---|\z)/s;
    ok(defined $rsec && index($rsec, $want[0]) >= 0, 'extract-run-79-27-spclient: real 85-03 cut -- the first real request line is printed verbatim');
};

# 79-28 (D-23): the librespot daemon's own log is the "unified" log (<mac>-unified.log): `[YYYY-MM-DDTHH:MM:SSZ LEVEL target] text`,
# an absolute UTC stamp WITH date. extract-run.pl read it as "andere Form" (all 700 lines of the 79-13 window skipped, "KEINE Zeile
# vom 2026-10-21 in dieser Quelle"), so the daemon side of every l16 direction could not be cited. Real input: a cut of the real
# 79-13 daemon log (window 09:28:55..09:30:20 UTC = 11:28:55..11:30:20 local, CEST), device ids replaced by the neutral zero id.
my $uni_fx       = "$project_dir/t/fixtures/uat/79-28-unified-l16-cut.log";
my $endpoint_cat = q{Daemon-Log: librespot Connect endpoint (handling: 'endpoint: <verb>'; unified log)};

subtest 'extract-run-79-28-unified' => sub {
    ok(-s $uni_fx, 'extract-run-79-28-unified: real unified-log cut present');
    my $stubdir   = tempdir(CLEANUP => 1);
    my $sudo_stub = write_sudo_passthrough_stub($stubdir);
    my ($sfh, $server_log) = tempfile();
    close($sfh);   # empty: this subtest is about the daemon log only
    my ($exit, $out, $err) = run_perl_tool($extract_run_script,
        ['02:00:00:5a:11:01', '11:28:55', '11:30:20', '--server-log', $server_log, '--daemon-log', $uni_fx, '--date', '2026-10-21'],
        SUDO_BIN => $sudo_stub, TZ => 'Europe/Berlin');
    is($exit, 0, 'extract-run-79-28-unified: extract-run runs (exit 0)') or diag("stderr: $err");
    unlike($out, qr/Abdeckung Daemon-Log: KEINE Zeile vom 2026-10-21/,
        'extract-run-79-28-unified: the coverage line no longer reads KEINE Zeile vom 2026-10-21 for the daemon log');
    unlike($out, qr/Hinweis Daemon-Log: \d+ Zeile\(n\) ohne eigenen Zeitstempel[^\n]*andere Form/,
        'extract-run-79-28-unified: no daemon line is skipped as "andere Form" (the unified stamp is parsed)');
    like($out, qr/---\s*\Q$endpoint_cat\E \(Anzahl: [1-9]/,
        'extract-run-79-28-unified: the endpoint category prints with a count in the window');
    my ($sec) = $out =~ /---\s*\Q$endpoint_cat\E[^\n]*---\n(.*?)(?=\n---|\z)/s;
    $sec //= '';
    # UTC + 2 h on 2026-10-21: 09:29:00Z pause -> 11:29:00, 09:29:51Z skip_prev -> 11:29:51, 09:29:57Z / 09:30:14Z resume
    like($sec, qr/^\[UTC->lokal 11:29:00\.000\] \[2026-10-21T09:29:00Z DEBUG librespot_connect::spirc\] handling: 'endpoint: pause' from 0{40}$/m,
        'extract-run-79-28-unified: the pause line is printed with its converted local time (UTC + 2 h)');
    like($sec, qr/^\[UTC->lokal 11:29:51\.000\] \[2026-10-21T09:29:51Z [^\n]*handling: 'endpoint: skip_prev'/m,
        'extract-run-79-28-unified: the skip_prev line is printed');
    like($sec, qr/^\[UTC->lokal 11:29:57\.000\] \[2026-10-21T09:29:57Z [^\n]*handling: 'endpoint: resume'/m,
        'extract-run-79-28-unified: the first resume line is printed');
    like($sec, qr/^\[UTC->lokal 11:30:14\.000\] \[2026-10-21T09:30:14Z [^\n]*handling: 'endpoint: resume'/m,
        'extract-run-79-28-unified: the second resume line is printed');
    unlike($sec, qr/endpoint: transfer/, 'extract-run-79-28-unified: lines outside the window (transfer 11:28:46) are not printed');
    # MUST-FAIL leg: the same window one day later finds none of them (the date is part of the stamp)
    my ($exit2, $out2) = run_perl_tool($extract_run_script,
        ['02:00:00:5a:11:01', '11:28:55', '11:30:20', '--server-log', $server_log, '--daemon-log', $uni_fx, '--date', '2026-10-22'],
        SUDO_BIN => $sudo_stub, TZ => 'Europe/Berlin');
    unlike($out2, qr/handling: 'endpoint: pause'/, 'extract-run-79-28-unified: --date 2026-10-22 prints none of the 2026-10-21 lines');
};

my $ctl_cat  = 'server.log: librespot control command sent ([DIAG] control_cmd_sent; Backend/Librespot.pm _sendControlCommand, 79-28 D-23)';
my $ctl_line = '[26-10-09 21:09:28.0005] Plugins::SpotOn::Backend::Librespot::_sendControlCommand (337) '
             . '[DIAG] control_cmd_sent: mac=02:00:00:5a:11:01 endpoint=/control/seek body={"position_ms":42000}';
my $evt_cat  = 'server.log: librespot daemon event received ([DIAG] seek_from_binary / volume_from_binary; Connect.pm _connectEvent, 79-28 D-23)';
my @from_binary_lines = (
    '[26-10-09 21:09:28.0006] Plugins::SpotOn::Connect::_connectEvent (1854) [DIAG] seek_from_binary: mac=02:00:00:5a:11:01 position=42.000',
    '[26-10-09 21:09:28.0007] Plugins::SpotOn::Connect::_connectEvent (1795) [DIAG] volume_from_binary: mac=02:00:00:5a:11:01 volume=33 uptime=61.2s',
);

subtest 'extract-run-79-28-control' => sub {
    ok(-s $webapi_fx, 'extract-run-79-28-control: real run8 cut present');
    my $text = _slurp($webapi_fx);
    $text =~ s/\A([^\n]*\n)/$1$ctl_line\n/ or die "fixture has no first line";
    my ($fh, $file) = tempfile();
    binmode($fh);
    print $fh $text;
    close($fh);
    my ($exit, $out, undef, $err) = _webapi_extract($file, '2026-10-09');
    is($exit, 0, 'extract-run-79-28-control: extract-run runs (exit 0)') or diag("stderr: $err");
    like($out, qr/---\s*\Q$ctl_cat\E \(Anzahl: 1 im Fenster/, 'extract-run-79-28-control: header carries (Anzahl: 1 im Fenster');
    ok($out =~ /---\s*\Q$ctl_cat\E[^\n]*---\n([^\n]*)\n/ && $1 eq $ctl_line,
        'extract-run-79-28-control: the injected control_cmd_sent line is printed under the new category, verbatim');
    unlike($out, qr/---\s*\Q$webapi_cat\E[^\n]*\(Anzahl: [1-9]/, 'extract-run-79-28-control: the line is not mistaken for a Web-API request');
    unlike($out, qr/---\s*\Q$eject_cat\E[^\n]*\(Anzahl: [1-9]/, 'extract-run-79-28-control: the line is not mistaken for an eject line');
    unlink($file);

    my $real = _webapi_server_log(0);
    my ($exitR, $outR, undef, $errR) = _webapi_extract($real, '2026-10-09');
    is($exitR, 0, 'extract-run-79-28-control: unmodified real cut -- extract-run runs (exit 0)') or diag("stderr: $errR");
    like($outR, qr/\[MUSTER NICHT GEFUNDEN IM FENSTER\] \Q$ctl_cat\E/,
        'extract-run-79-28-control: unmodified real cut -- control_cmd_sent reads "nicht gefunden im Fenster", no verdict');
    # MUST-PASS on real material: the real run8 cut holds ONE real `[DIAG] seek_from_binary:` line (fixture line 31), now printed
    my ($real_evt) = grep { /\[DIAG\] seek_from_binary: / } split /\n/, _slurp($webapi_fx);
    ok(defined $real_evt, 'extract-run-79-28-control: the real run8 cut holds a seek_from_binary line');
    like($outR, qr/---\s*\Q$evt_cat\E \(Anzahl: 1 im Fenster/, 'extract-run-79-28-control: unmodified real cut -- the real seek_from_binary line is counted');
    ok($outR =~ /---\s*\Q$evt_cat\E[^\n]*---\n([^\n]*)\n/ && defined $real_evt && $1 eq $real_evt,
        'extract-run-79-28-control: unmodified real cut -- the real seek_from_binary line is printed verbatim');
    unlink($real);

    # the two from-binary DIAG lines (app -> LMS seek / volume): injected next to the real one
    my $text2 = _slurp($webapi_fx);
    $text2 =~ s/\A([^\n]*\n)/$1 . join("\n", @from_binary_lines) . "\n"/e or die "fixture has no first line";
    my ($fh2, $file2) = tempfile();
    binmode($fh2);
    print $fh2 $text2;
    close($fh2);
    my ($exit2, $out2, undef, $err2) = _webapi_extract($file2, '2026-10-09');
    is($exit2, 0, 'extract-run-79-28-control: from-binary injection -- extract-run runs (exit 0)') or diag("stderr: $err2");
    like($out2, qr/---\s*\Q$evt_cat\E \(Anzahl: 3 im Fenster/, 'extract-run-79-28-control: seek_from_binary x2 and volume_from_binary count under the event category');
    my ($sec2) = $out2 =~ /---\s*\Q$evt_cat\E[^\n]*---\n(.*?)(?=\n---|\z)/s;
    $sec2 //= '';
    is(join("\n", sort grep { length } split /\n/, $sec2), join("\n", sort @from_binary_lines, $real_evt),
        'extract-run-79-28-control: all three lines are printed verbatim under the event category');
    unlike($out2, qr/---\s*\Q$ctl_cat\E[^\n]*\(Anzahl: [1-9]/, 'extract-run-79-28-control: from-binary lines do not count as control commands');
    unlink($file2);
};

# 79-32 (D-27): the SpotOn PauseGuard category. Plugin.pm _pauseGuardCheck writes `[DIAG] PauseGuard: re-applying pause (swallowed <age>s ago)`
# (the 79-30 form carries NO mac; 79-32 appends ` mac=<id>`) and `[DIAG] PauseGuard: dropped, song changed since the pause request (...) mac=<id>`.
# The first literal below is the REAL line of the 2026-10-22 stutter run (archived server.log:50759), copied verbatim; the test never reads
# spoton-messdaten or /var/log (the private CI cannot see them). The dropped line is the new form in the core layout.
my $pg_cat = 'server.log: PauseGuard ([DIAG] PauseGuard: re-applying pause / dropped after a song change; Plugin.pm _pauseGuardCheck, 79-32 D-27)';
my $pg_real_line = '[26-10-22 17:34:16.0041] Plugins::SpotOn::Plugin::_pauseGuardCheck (4122) [DIAG] PauseGuard: re-applying pause (swallowed 2.5003809928894s ago)';
my $pg_drop_line = '[26-10-22 17:34:16.5000] Plugins::SpotOn::Plugin::_pauseGuardCheck (4135) [DIAG] PauseGuard: dropped, song changed since the pause request '
                 . '(0:spoton://track:2374M0fQpWi3dLnB54qaLX -> 1:spoton://track:5oiTnaEHK3OFDZIL8AIYwu) mac=02:00:00:5a:11:01';

subtest 'extract-run-79-32-pauseguard' => sub {
    ok(-s $webapi_fx, 'extract-run-79-32-pauseguard: real run8 cut present');
    # both lines injected into the real run8 cut; their own window (17:34:13..17:34:20 on 2026-10-22) is the one of the stutter run
    my $text = _slurp($webapi_fx);
    $text =~ s/\A([^\n]*\n)/$1$pg_real_line\n$pg_drop_line\n/ or die "fixture has no first line";
    my ($fh, $file) = tempfile();
    binmode($fh);
    print $fh $text;
    close($fh);
    my ($exit, $out, $err) = run_perl_tool($extract_run_script,
        ['02:00:00:5a:11:01', '17:34:13', '17:34:20', '--server-log', $file, '--date', '2026-10-22'], SUDO_BIN => '/bin/true');
    is($exit, 0, 'extract-run-79-32-pauseguard: extract-run over the doctored real cut runs (exit 0)') or diag("stderr: $err");
    like($out, qr/---\s*\Q$pg_cat\E \(Anzahl: 2 im Fenster/, 'extract-run-79-32-pauseguard: header carries (Anzahl: 2 im Fenster');
    my ($sec) = $out =~ /---\s*\Q$pg_cat\E[^\n]*---\n(.*?)(?=\n---|\z)/s;
    $sec //= '';
    is(join("\n", grep { length } split /\n/, $sec), "$pg_real_line\n$pg_drop_line",
        'extract-run-79-32-pauseguard: the real re-apply line and the dropped line are printed under the category, verbatim');
    unlike($out, qr/---\s*\Q$webapi_cat\E[^\n]*\(Anzahl: [1-9]/, 'extract-run-79-32-pauseguard: neither line counts under the Web API category');
    unlike($out, qr/---\s*\Q$ctl_cat\E[^\n]*\(Anzahl: [1-9]/, 'extract-run-79-32-pauseguard: neither line counts under the control-command category');
    unlink($file);

    my $real = _webapi_server_log(0);
    my ($exitR, $outR, undef, $errR) = _webapi_extract($real, '2026-10-09');
    is($exitR, 0, 'extract-run-79-32-pauseguard: unmodified real cut -- extract-run runs (exit 0)') or diag("stderr: $errR");
    like($outR, qr/\[MUSTER NICHT GEFUNDEN IM FENSTER\] \Q$pg_cat\E/,
        'extract-run-79-32-pauseguard: unmodified real cut -- reads "nicht gefunden im Fenster", no verdict (absence is no verdict)');
    unlink($real);
};

# 79-32 (D-27, mechanism a2): LMS' sync controller logs its own corrections as `<mac> resync: skipAhead <n>ms` or `<mac> resync: pauseFor <n>ms`
# at player.sync INFO (Slim/Player/StreamingController.pm:566 / :576, sub _CheckSync). player.sync is at ERROR by default, so the lines exist only
# after `debug player.sync INFO`. A search of /var/log/squeezeboxserver/server.log* and the archived lms-logs for a REAL line on 2026-10-23 found
# none (649087 lines scanned), so the two lines below are written in the core server.log layout, not copied from a log.
my $rs_cat = 'server.log: LMS sync resync (player.sync INFO "<mac> resync: skipAhead|pauseFor <n>ms"; StreamingController.pm:566/576, 79-32 D-27 a2)';
my @rs_lines = (
    '[26-10-09 21:09:28.0008] Slim::Player::StreamingController::_CheckSync (566) 02:00:00:5a:11:01 resync: skipAhead 1990ms',
    '[26-10-09 21:09:28.0009] Slim::Player::StreamingController::_CheckSync (576) 02:00:00:5a:11:01 resync: pauseFor 31ms',
);

subtest 'extract-run-79-32-resync' => sub {
    ok(-s $webapi_fx, 'extract-run-79-32-resync: real run8 cut present');
    my $text = _slurp($webapi_fx);
    $text =~ s/\A([^\n]*\n)/$1 . join("\n", @rs_lines) . "\n"/e or die "fixture has no first line";
    my ($fh, $file) = tempfile();
    binmode($fh);
    print $fh $text;
    close($fh);
    my ($exit, $out, undef, $err) = _webapi_extract($file, '2026-10-09');
    is($exit, 0, 'extract-run-79-32-resync: extract-run over the doctored real cut runs (exit 0)') or diag("stderr: $err");
    like($out, qr/---\s*\Q$rs_cat\E \(Anzahl: 2 im Fenster/, 'extract-run-79-32-resync: header carries (Anzahl: 2 im Fenster');
    my ($sec) = $out =~ /---\s*\Q$rs_cat\E[^\n]*---\n(.*?)(?=\n---|\z)/s;
    $sec //= '';
    is(join("\n", grep { length } split /\n/, $sec), join("\n", @rs_lines),
        'extract-run-79-32-resync: both resync lines (skipAhead and pauseFor) are printed under the category, verbatim');
    unlike($out, qr/---\s*\Q$webapi_cat\E[^\n]*\(Anzahl: [1-9]/, 'extract-run-79-32-resync: neither line counts under the Web API category');
    unlike($out, qr/---\s*\Q$pg_cat\E[^\n]*\(Anzahl: [1-9]/, 'extract-run-79-32-resync: neither line counts under the PauseGuard category');
    unlink($file);

    my $real = _webapi_server_log(0);
    my ($exitR, $outR, undef, $errR) = _webapi_extract($real, '2026-10-09');
    is($exitR, 0, 'extract-run-79-32-resync: unmodified real cut -- extract-run runs (exit 0)') or diag("stderr: $errR");
    like($outR, qr/\[MUSTER NICHT GEFUNDEN IM FENSTER\] \Q$rs_cat\E/,
        'extract-run-79-32-resync: unmodified real cut -- reads "nicht gefunden im Fenster", no verdict (absence is no verdict)');
    unlink($real);
};

# Starts a fake LMS answering the given replies in order; every request body is appended to a
# capture file (the server is a forked child, so a plain array would never reach the parent).
# Runs menu-walk.pl against it. Returns ($exit, $stdout, $stderr, \@decoded_request_bodies).
sub _menu_walk_run {
    my ($replies, $args, $delay) = @_;     # $delay (79-30): seconds the fake LMS waits before it answers
    my ($cfh, $capture) = tempfile();
    close($cfh);
    my @responders = map {
        my $reply = $_;
        sub {
            my ($body) = @_;
            if (open(my $c, '>>', $capture)) { print $c "$body\n"; close($c); }
            select(undef, undef, undef, $delay) if $delay;
            return @$reply;
        };
    } @$replies;
    my ($pid, $port) = start_fake_http(\@responders);
    my ($exit, $out, $err) = run_perl_tool($menu_walk_script,
        ['--player', $probe_mac, '--lms-url', "http://127.0.0.1:$port/jsonrpc.js", @$args]);
    kill('TERM', $pid) if $delay;    # 79-30: a tool that never connected (usage error) must not leave the fake waiting in accept
    waitpid($pid, 0);
    my @reqs = map { JSON::PP::decode_json($_) } grep { /\S/ } split /\n/, _slurp($capture);
    unlink($capture);
    return ($exit, $out, $err, \@reqs);
}

subtest 'menu-walk' => sub {
    my $OK = 'HTTP/1.1 200 OK';
    my $top = qq({"result":{"count":2,"loop_loop":[)
        . qq({"id":"1","name":"Home","type":"link","hasitems":1,"isaudio":0},)
        . qq({"id":"2","name":"Library","type":"link","hasitems":1,"isaudio":0}]}});

    # (1) top level of two items whose children answer
    my ($e1, $o1, $r1, $q1) = _menu_walk_run(
        [[$OK, $top], [$OK, '{"result":{"count":7,"loop_loop":[{"id":"1.0","name":"t","type":"audio","isaudio":1}]}}'],
                      [$OK, '{"result":{"count":3,"loop_loop":[]}}']],
        ['--depth', '1']);
    is($e1, 0, 'menu-walk: (1) all nodes answered -- exit 0') or diag($r1);
    like($o1, qr/^MENU top \| top \| type=- \| count=2 \| hint=-$/m, 'menu-walk: (1) top MENU line with its count');
    like($o1, qr/^MENU 1 \| Home \| type=link \| count=7 \| hint=-$/m, 'menu-walk: (1) first child MENU line with its count');
    like($o1, qr/^MENU 2 \| Library \| type=link \| count=3 \| hint=-$/m, 'menu-walk: (1) second child MENU line with its count');
    like($o1, qr/^WALK_DONE menus=3 unanswered=0$/m, 'menu-walk: (1) WALK_DONE menus=3 unanswered=0');
    is(scalar(@$q1), 3, 'menu-walk: (1) exactly three requests were sent');
    is_deeply($q1->[1]{params}[1], ['spoton', 'items', '0', '100', 'item_id:1', 'want_url:1'],
        'menu-walk: (1) a child request carries item_id and want_url:1');

    # (2) one child answered with an empty body (no result key)
    my ($e2, $o2) = _menu_walk_run(
        [[$OK, $top], [$OK, '{"result":{"count":7,"loop_loop":[]}}'], [$OK, '']],
        ['--depth', '1']);
    is($e2, 1, 'menu-walk: (2) a child without result key -- exit 1');
    like($o2, qr/^UNANSWERED 2 \| Library$/m, 'menu-walk: (2) UNANSWERED line for the empty-body child');
    like($o2, qr/^WALK_DONE menus=3 unanswered=1$/m, 'menu-walk: (2) WALK_DONE counts the unanswered node');

    # (3) --arm-webapi-log: read-back DEBUG -> ARMED, read-back ERROR -> ARM_FAILED + exit 3
    my ($e3, $o3, undef, $q3) = _menu_walk_run(
        [[$OK, '{"result":{}}'], [$OK, '{"result":{"_value":"DEBUG"}}'], [$OK, '{"result":{"count":0,"loop_loop":[]}}']],
        ['--arm-webapi-log', '--depth', '0']);
    is($e3, 0, 'menu-walk: (3) armed and walked -- exit 0');
    like($o3, qr/^ARMED network\.asynchttp=DEBUG at \d\d:\d\d:\d\d\.\d{3}$/m, 'menu-walk: (3) ARMED line with a time');
    is_deeply($q3->[0]{params}[1], ['debug', 'network.asynchttp', 'DEBUG'], 'menu-walk: (3) first request sets network.asynchttp DEBUG');
    is_deeply($q3->[1]{params}[1], ['debug', 'network.asynchttp', '?'], 'menu-walk: (3) second request reads it back');
    my ($e3b, $o3b) = _menu_walk_run(
        [[$OK, '{"result":{}}'], [$OK, '{"result":{"_value":"ERROR"}}']],
        ['--arm-webapi-log']);
    is($e3b, 3, 'menu-walk: (3) read-back ERROR -- exit 3');
    like($o3b, qr/^ARM_FAILED network\.asynchttp=ERROR$/m, 'menu-walk: (3) ARM_FAILED line names the read-back value');
    unlike($o3b, qr/^(?:ARMED|MENU) /m, 'menu-walk: (3) nothing is walked after a failed arm');

    # (4) --path against a reply with the total count, a title and two children
    my ($e4, $o4, undef, $q4) = _menu_walk_run(
        [[$OK, '{"result":{"count":250,"title":"Liked","loop_loop":['
            . '{"id":"7.2.0","name":"Track A","type":"audio","url":"spoton://track:X"},'
            . '{"id":"7.2.1","name":"Track B","type":"audio"}]}}']],
        ['--path', '7.2']);
    is($e4, 0, 'menu-walk: (4) --path -- exit 0');
    is(scalar(grep { /^MENU / } split /\n/, $o4), 1, 'menu-walk: (4) exactly one MENU line');
    like($o4, qr/^MENU 7\.2 \| Liked \| type=- \| count=250 \| hint=-$/m, 'menu-walk: (4) count is the LMS total (250), not the two returned items');
    like($o4, qr/^CHILD 7\.2\.0 \| Track A \| type=audio \| url=spoton:\/\/track:X$/m, 'menu-walk: (4) first CHILD line carries its url');
    like($o4, qr/^CHILD 7\.2\.1 \| Track B \| type=audio \| url=-$/m, 'menu-walk: (4) second CHILD line has url=-');
    my @c4 = @{ $q4->[0]{params}[1] };
    ok((grep { $_ eq 'item_id:7.2' } @c4) && (grep { $_ eq 'want_url:1' } @c4), 'menu-walk: (4) the recorded request carries item_id:7.2 and want_url:1');

    # (5) --cmd spotoninfo --param url:... --path top
    my ($e5, undef, undef, $q5) = _menu_walk_run(
        [[$OK, '{"result":{"count":0,"loop_loop":[]}}']],
        ['--cmd', 'spotoninfo', '--param', 'url:spoton://track:X', '--path', 'top']);
    is($e5, 0, 'menu-walk: (5) spotoninfo top -- exit 0');
    my @c5 = @{ $q5->[0]{params}[1] };
    is_deeply([@c5[0, 1]], ['spotoninfo', 'items'], 'menu-walk: (5) the command array starts with spotoninfo, items');
    ok((grep { $_ eq 'url:spoton://track:X' } @c5), 'menu-walk: (5) the url param is carried');
    is(scalar(grep { /^item_id:/ } @c5), 0, 'menu-walk: (5) top has no item_id parameter');

    # (6) --search reaches the request in --path mode
    my ($e6, undef, undef, $q6) = _menu_walk_run(
        [[$OK, '{"result":{"count":0,"loop_loop":[]}}']],
        ['--search', 'Miles Davis', '--path', '3.1']);
    is($e6, 0, 'menu-walk: (6) --search with --path -- exit 0');
    ok((grep { $_ eq 'search:Miles Davis' } @{ $q6->[0]{params}[1] }), 'menu-walk: (6) the request carries search:Miles Davis');

    # (7) zero items: one MENU line with count=0 and no CHILD line
    my ($e7, $o7) = _menu_walk_run(
        [[$OK, '{"result":{"count":0,"title":"Empty","loop_loop":[]}}']],
        ['--path', '9']);
    is($e7, 0, 'menu-walk: (7) empty node -- exit 0');
    like($o7, qr/^MENU 9 \| Empty \| type=- \| count=0 \| hint=-$/m, 'menu-walk: (7) MENU line with count=0');
    unlike($o7, qr/^CHILD /m, 'menu-walk: (7) no CHILD line');

    # (8) a single textarea item becomes the hint
    my ($e8, $o8) = _menu_walk_run(
        [[$OK, '{"result":{"count":1,"title":"Hint","loop_loop":[{"id":"4.0","name":"Nothing here","type":"textarea"}]}}']],
        ['--path', '4']);
    like($o8, qr/^MENU 4 \| Hint \| type=- \| count=1 \| hint=Nothing here$/m, 'menu-walk: (8) the textarea text is the hint');

    # (9) LMS not running -> exit 2 (never a silent empty walk)
    my $dead = free_closed_port();
    my ($e9) = run_perl_tool($menu_walk_script, ['--player', $probe_mac, '--lms-url', "http://127.0.0.1:$dead/jsonrpc.js"]);
    is($e9, 2, 'menu-walk: (9) LMS unreachable -- exit 2');
    my ($e10) = run_perl_tool($menu_walk_script, []);
    is($e10, 2, 'menu-walk: (10) missing --player is a usage error (exit 2)');
};

# 79-30 (D-18, D-21): the cold open of Liked Songs took about 182 s, so the fixed 30 s HTTP::Tiny timeout of menu-walk
# would read UNANSWERED on a slow cold open. `--timeout <s>` (1..900, default 30) is passed to HTTP::Tiny.
subtest 'menu-walk-79-30-timeout' => sub {
    my $OK = 'HTTP/1.1 200 OK';
    my $ans = '{"result":{"count":3,"title":"Liked","loop_loop":[]}}';
    my ($e1, $o1) = _menu_walk_run([[$OK, $ans]], ['--path', '2.0', '--timeout', '1'], 2.5);
    is($e1, 1, 'menu-walk-79-30-timeout: --timeout 1 against a fake answering after 2.5 s -- exit 1');
    like($o1, qr/^UNANSWERED 2\.0 \| -$/m, 'menu-walk-79-30-timeout: --timeout 1 -- the node reads UNANSWERED');
    unlike($o1, qr/^MENU /m, 'menu-walk-79-30-timeout: --timeout 1 -- no MENU line for the cut node');
    my ($e2, $o2) = _menu_walk_run([[$OK, $ans]], ['--path', '2.0', '--timeout', '8'], 2.5);
    is($e2, 0, 'menu-walk-79-30-timeout: --timeout 8 against the same fake -- exit 0');
    like($o2, qr/^MENU 2\.0 \| Liked \| type=- \| count=3 \| hint=-$/m, 'menu-walk-79-30-timeout: --timeout 8 -- the MENU line is printed');
    my ($e3, $o3) = _menu_walk_run([[$OK, $ans]], ['--path', '2.0']);
    is($e3, 0, 'menu-walk-79-30-timeout: no --timeout keeps working against a fast fake -- exit 0');
    for my $bad (0, 901, -3) {
        my ($eb, undef, $rb) = run_perl_tool($menu_walk_script, ['--player', $probe_mac, '--timeout', $bad]);
        is($eb, 2, "menu-walk-79-30-timeout: --timeout $bad is a usage error (exit 2)");
    }
};

# 85-16: a name with an umlaut must leave menu-walk as valid UTF-8 (the live walk printed a Latin-1 byte,
# so the plan verify patterns for the German Made-for-You label could not match).
subtest q(menu-walk-utf8) => sub {
    my $OK = q(HTTP/1.1 200 OK);
    my ($e, $o) = _menu_walk_run(
        [[$OK, q({"result":{"count":1,"loop_loop":[{"id":"0.2","name":"F\u00fcr dich gemacht","type":"link","hasitems":1}]}})],
         [$OK, q({"result":{"count":21,"loop_loop":[]}})]],
        [q(--depth), q(1)]);
    is($e, 0, q(menu-walk-utf8: walk answered -- exit 0));
    like($o, qr/^MENU 0\.2 \| F\xc3\xbcr dich gemacht \| type=link \| count=21 \| hint=-$/m,
        q(menu-walk-utf8: the umlaut leaves as UTF-8 bytes C3 BC, not as Latin-1 FC));
    unlike($o, qr/F\xfcr/, q(menu-walk-utf8: no Latin-1 byte FC in the output));
};

# 79-04 (D-10): pa-idle-gate.sh no longer carries the headphone-player MAC. It reads PA_MAC and
# stops with exit 2 when it is unset; PA_IDLE_FAKE_MODE keeps the subtest offline.
subtest q(pa-idle-gate-pa-mac) => sub {
    my $pa_idle_script = "$project_dir/tools/uat/pa-idle-gate.sh";
    my ($e1, $o1, $r1) = run_tool($pa_idle_script, [], PA_MAC => '', PA_IDLE_FAKE_MODE => 'stop');
    is($e1, 2, 'pa-idle-gate: PA_MAC unset -> exit 2');
    like($o1, qr/^PA_IDLE=ERROR PA_MAC not set$/m, 'pa-idle-gate: PA_MAC unset -> output names PA_MAC');
    my ($e2, $o2) = run_tool($pa_idle_script, [], PA_MAC => $probe_mac, PA_IDLE_FAKE_MODE => 'stop');
    is($e2, 0, 'pa-idle-gate: PA_MAC set, mode stop -> exit 0');
    like($o2, qr/^PA_IDLE=PASS mode=stop$/m, 'pa-idle-gate: PASS line');
    my ($e3, $o3) = run_tool($pa_idle_script, [], PA_MAC => $probe_mac, PA_IDLE_FAKE_MODE => 'play');
    is($e3, 1, 'pa-idle-gate: PA_MAC set, mode play -> exit 1');
    like($o3, qr/^PA_IDLE=FAIL mode=play time=0$/m, 'pa-idle-gate: FAIL line');
};

# 79-04 (D-10): the four tools that used a built-in headphone-player MAC now fail closed without
# PA_MAC (arm-after-restart, repeat-probe and signatur-c-probe also accept SPOTON_MAC first).
subtest q(pa-mac-fail-closed) => sub {
    my $stubdir = tempdir(CLEANUP => 1);
    my $sudo_stub = write_sudo_passthrough_stub($stubdir);
    my $closed = free_closed_port();
    my $lms = "http://127.0.0.1:$closed/jsonrpc.js";

    # checkpoint-beep: never reaches curl or the sound command
    {
        my $bindir = make_stub_bindir('play');
        my ($e, $o, $r) = run_tool($beep_script, [], PA_MAC => '', LMS_URL => $lms, PATH => "$bindir:$ENV{PATH}");
        is($e, 2, 'pa-mac-fail-closed: checkpoint-beep without PA_MAC -> exit 2');
        like($o . $r, qr/PA_MAC/, 'pa-mac-fail-closed: checkpoint-beep output names PA_MAC');
        is(scalar(my @calls = _read_calls($bindir)), 0, 'pa-mac-fail-closed: checkpoint-beep made no sound call');
    }

    # arm-after-restart
    {
        my ($e, $o, $r) = run_tool($arm_after_restart_script, ['--no-restart'], PA_MAC => $probe_mac,
            PA_MAC => '', SPOTON_MAC => '', SUDO_BIN => $sudo_stub, LMS_URL => $lms,
            WS_PATH => "$stubdir/unused-ws.port");
        is($e, 2, 'pa-mac-fail-closed: arm-after-restart without PA_MAC and SPOTON_MAC -> exit 2');
        like($o . $r, qr/PA_MAC/, 'pa-mac-fail-closed: arm-after-restart output names PA_MAC');
        like($o . $r, qr/SPOTON_MAC/, 'pa-mac-fail-closed: arm-after-restart output names SPOTON_MAC');
    }

    # repeat-probe
    {
        my $probe_stub = write_custom_stub($stubdir, 'probe-stub-failclosed.sh', "#!/bin/bash\nexit 0\n");
        my ($e, $o, $r) = run_tool($repeat_probe_script, ['1'], PA_MAC => $probe_mac,
            PA_MAC => '', SPOTON_MAC => '', PROBE_SCRIPT => $probe_stub, SUDO_BIN => $sudo_stub,
            SERVER_LOG => "$stubdir/none.log");
        is($e, 2, 'pa-mac-fail-closed: repeat-probe without PA_MAC and SPOTON_MAC -> exit 2');
        like($o . $r, qr/PA_MAC/, 'pa-mac-fail-closed: repeat-probe output names PA_MAC');
        unlike($o, qr/LAUF 1\/1/, 'pa-mac-fail-closed: repeat-probe started no run');
    }

    # signatur-c-probe
    {
        my ($e, $o, $r) = run_python_tool($signatur_c_probe_script, [], PA_MAC => $probe_mac,
            PA_MAC => '', SPOTON_MAC => '', SUDO_BIN => $sudo_stub, LMS_URL => $lms,
            WS_PATH => "$stubdir/unused-ws.port");
        is($e, 2, 'pa-mac-fail-closed: signatur-c-probe without PA_MAC and SPOTON_MAC -> exit 2');
        like($o . $r, qr/PA_MAC/, 'pa-mac-fail-closed: signatur-c-probe output names PA_MAC');
    }
};

# ============================================================
# 79-46 (D-34): the autoplay-vs-takeover measurement reads the frames Control
# receives. E1: a recorder `context_changed` frame is rendered with its
# context.uri and context.entity_type (before 79-46 it fell into the "other
# types" counter, so no window could show which context the daemon moved to).
# E2-E4: three Control server.log lines that were only counted (rule 4) get
# their own category: the autoplay guard's pause (Control.pm:3979-3986), the
# classify-unknown catch-all (Control.pm:3584-3589) and the context end
# without successor (Control.pm _maybeContextEnd). Each subtest also proves
# an unrelated line stays out of the new section.
# ============================================================
my $d34_write = sub {
    my (@lines) = @_;
    my ($fh, $file) = tempfile();
    print $fh "$_\n" for @lines;
    close($fh);
    return $file;
};
my $d34_section = sub {
    my ($stdout, $hdr) = @_;
    return ($stdout =~ /---\s*\Q$hdr\E.*?---\n(.*?)(?=\n---|\z)/s) ? $1 : '';
};
my $d34_unrelated = '[26-10-26 12:00:04.0000] Plugins::SpotOn::Soloist::Control::_dispatch (100) Control: dispatch play armed=0 (02:00:00:5a:11:01)';
my $d34_run_srv = sub {
    my ($line) = @_;
    my $srv = $d34_write->($d34_unrelated, $line);
    my $dmn = $d34_write->();
    my ($exit, $stdout, $stderr) = run_perl_tool($extract_run_script,
        [ '02:00:00:5a:11:01', '12:00:00', '12:00:10', '--server-log', $srv,
          '--daemon-log', $dmn, '--date', '2026-10-26' ],
        SUDO_BIN => '/bin/true');
    unlink($srv, $dmn);
    return ($exit, $stdout, $stderr);
};

subtest 'd34-E1-context-changed-rendered' => sub {
    my $rec = $d34_write->(
        '{"frame":"{\"type\":\"context_changed\",\"context\":{\"uri\":\"spotify:playlist:37i9dQZF1DXcBWIGoYBM5M\",\"entity_type\":\"playlist\",\"decorations\":{}}}","ts":"12:00:05.500","dir":"rx","epoch":1}',
        '{"frame":"{\"type\":\"context_changed\",\"context\":{\"uri\":\"\",\"entity_type\":\"\",\"decorations\":{}}}","ts":"12:00:05.550","dir":"rx","epoch":2}',
        '{"frame":"{\"type\":\"track_changed\",\"item\":{\"uri\":\"spotify:track:0ymW7RlpQ12wFvr3tP8Fqb\",\"entity_type\":\"track\"}}","ts":"12:00:05.600","dir":"rx","epoch":3}',
    );
    my $srv = $d34_write->();
    my $dmn = $d34_write->();
    my ($exit, $stdout, $stderr) = run_perl_tool($extract_run_script,
        [ '02:00:00:5a:11:01', '12:00:00', '12:00:10', '--server-log', $srv,
          '--daemon-log', $dmn, '--recorder', $rec, '--date', '2026-10-26' ],
        SUDO_BIN => '/bin/true');
    unlink($rec, $srv, $dmn);
    is($exit, 0, 'd34-E1: extract-run.pl exits 0') or diag("stderr: $stderr");
    like($stdout, qr/^\@12:00:05\.500 type=context_changed uri=spotify:playlist:37i9dQZF1DXcBWIGoYBM5M entity_type=playlist$/m,
        'd34-E1: context_changed is listed with context.uri and context.entity_type');
    like($stdout, qr/^\@12:00:05\.550 type=context_changed uri="" entity_type=""$/m,
        'd34-E1: an empty context is listed with explicit empty values, not silently dropped');
    like($stdout, qr/^\@12:00:05\.600 type=track_changed uri=spotify:track:0ymW7RlpQ12wFvr3tP8Fqb$/m,
        'd34-E1: the track_changed line keeps its existing form');
    unlike($stdout, qr/anderer Typen[^\n]*context_changed/,
        'd34-E1: context_changed no longer falls into the other-types counter');
};

subtest 'd34-E2-autoplay-guard-category' => sub {
    my $hdr = 'server.log: D-34 autoplay guard (daemon advanced to <uri> unrequested -- pausing; Control.pm)';
    my ($exit, $stdout, $stderr) = $d34_run_srv->(
        '[26-10-26 12:00:06.0000] Plugins::SpotOn::Soloist::Control::_recordErrorOnce (6386) 02:00:00:5a:11:01: daemon advanced to spotify:track:0ymW7RlpQ12wFvr3tP8Fqb unrequested -- pausing');
    is($exit, 0, 'd34-E2: extract-run.pl exits 0') or diag("stderr: $stderr");
    my $body = $d34_section->($stdout, $hdr);
    like($body, qr/daemon advanced to spotify:track:0ymW7RlpQ12wFvr3tP8Fqb unrequested -- pausing/,
        'd34-E2: the guard line lands in its own category');
    unlike($body, qr/Control: dispatch play/, 'd34-E2: an unrelated line stays out of the category');
};

subtest 'd34-E3-classify-unknown-category' => sub {
    my $hdr = 'server.log: D-34 Control classify unknown (type=; Control.pm onEvent catch-all)';
    my ($exit, $stdout, $stderr) = $d34_run_srv->(
        '[26-10-26 12:00:06.0000] Plugins::SpotOn::Soloist::Control::_classify (3584) Control: classify unknown -- type=context_changed mode=browse wanted.uri=spotify:track:0ymW7RlpQ12wFvr3tP8Fqb observed.track=spotify:track:0ymW7RlpQ12wFvr3tP8Fqb pending.cmd=- (02:00:00:5a:11:01)');
    is($exit, 0, 'd34-E3: extract-run.pl exits 0') or diag("stderr: $stderr");
    my $body = $d34_section->($stdout, $hdr);
    like($body, qr/Control: classify unknown -- type=context_changed mode=browse/,
        'd34-E3: the classify-unknown line lands in its own category');
    unlike($body, qr/Control: dispatch play/, 'd34-E3: an unrelated line stays out of the category');
};

subtest 'd34-E4-context-end-category' => sub {
    my $hdr = 'server.log: D-34 context end without successor (Control.pm _maybeContextEnd)';
    my ($exit, $stdout, $stderr) = $d34_run_srv->(
        '[26-10-26 12:00:06.0000] Plugins::SpotOn::Soloist::Control::_maybeContextEnd (3420) Control: context end without successor on spotify:track:0ymW7RlpQ12wFvr3tP8Fqb -- planting boundary, no resume (02:00:00:5a:11:01)');
    is($exit, 0, 'd34-E4: extract-run.pl exits 0') or diag("stderr: $stderr");
    my $body = $d34_section->($stdout, $hdr);
    like($body, qr/Control: context end without successor on spotify:track:0ymW7RlpQ12wFvr3tP8Fqb/,
        'd34-E4: the context-end line lands in its own category');
    unlike($body, qr/Control: dispatch play/, 'd34-E4: an unrelated line stays out of the category');
};

done_testing();

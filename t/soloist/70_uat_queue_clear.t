#!/usr/bin/perl

# t/soloist/70_uat_queue_clear.t
#
# Quick 261022-iwm -- tools/uat/queue-clear.sh, the read-refresh-reread tool
# for the RIG=QUEUE_NOT_EMPTY / ROW_ABORT=user_queue_not_empty stops on
# lavender-UAT. Soloist has NO command that deletes a queue entry; an
# inactive daemon answers get_queue from a frozen copy of its last session.
# The tool refreshes that copy through the desktop app's own device handover
# (DECISION.md: CHOICE=app_transfer) and reports real account entries instead
# of hiding them.
#
# Entirely offline: no LMS, no sudo, no Slim tree, no real daemon, no real
# app. Three fakes share one JSON state file:
#   (a) a fake ws-record (QC_WS_RECORD), same JSONL shape as
#       tools/soloist-ws-record.pl writes (meta HANDSHAKE-OK, rx auth_state /
#       playback_state, tx + rx per --send),
#   (b) a fake app driver (QC_CDP): start, status, connect, disconnect, pause,
#       stop,
#   (c) a fake app-process probe (QC_APP_PIDS_CMD).
# Every case is flat (no BAIL_OUT): a missing tool fails each case on its own.
#
# QC_TOOL overrides the tool under test (plant runs use scratch copies).

use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use Cwd qw(abs_path);
use JSON::PP;

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/soloist/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

my $tool = $ENV{QC_TOOL} // "$project_dir/tools/uat/queue-clear.sh";
my $UAT_MAC = '02:00:00:5a:11:01';
# synthetic stand-in for lavender-pa (D-10: the shipped tool holds no real MAC; it reads PA_MAC)
my $FAKE_PA = '02:00:00:5a:22:02';

my $X = 'spotify:track:XXXXXXXXXXXXXXXXXXXXXX';
my $Y = 'spotify:track:YYYYYYYYYYYYYYYYYYYYYY';
my $Z = 'spotify:track:ZZZZZZZZZZZZZZZZZZZZZZ';

# ------------------------------------------------------------
# the three fakes (written once into a shared tempdir)
# ------------------------------------------------------------
my $fakes = tempdir(CLEANUP => 1);

my $fake_ws = <<'FAKE_WS';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP; use Time::HiRes qw(time);
my (%o, @send);
while (@ARGV) {
    my $a = shift @ARGV;
    if ($a eq '--send') { push @send, shift @ARGV }
    elsif ($a =~ /\A--(mac|expect-device|seconds|out)\z/) { $o{$1} = shift @ARGV }
    else { print STDERR "fake ws-record: unknown arg $a\n"; exit 1 }
}
sub logline { my ($f, $l) = @_; open(my $fh, '>>', $f) or die "log $f: $!"; print $fh "$l\n"; close $fh }
sub cmdname {
    my ($s) = @_;
    if ($s =~ /\A\{/) { my $d = eval { decode_json($s) }; return $d ? ($d->{command} // '?') : '?' }
    return (split /:/, $s, 2)[0];
}
logline($ENV{QC_FAKE_INVLOG}, "ws mac=" . ($o{mac} // ''));
my $st = do { open(my $fh, '<', $ENV{QC_FAKE_STATE}) or die; local $/; decode_json(<$fh>) };
open(my $out, '>', $o{out}) or die "out: $!";
sub jl { my ($dir, $frame) = @_; print $out encode_json({ dir => $dir, frame => $frame, ts => '00:00:00.000', epoch => time() + 0 }) . "\n" }
sub save { open(my $fh, '>', $ENV{QC_FAKE_STATE}) or die; print $fh encode_json($st); close $fh }
# 79-46: the real recorder writes the frame as a CHARACTER string (soloist-ws-record.pl), so a
# non-ASCII title arrives as a wide character after the outer decode. `nonascii` reproduces that:
# rx frames are encoded at character level and carry a title with an accent.
if ($st->{nonascii}) {
    my $chars = JSON::PP->new->canonical;
    no warnings 'redefine';
    *encode_json = sub {
        my ($h) = @_;
        if (ref $h eq 'HASH' && ref $h->{item} eq 'HASH') { $h->{item}{decorations} = { identity => { name => "Thierry \x{e9}t\x{e9}" } } }
        if (ref $h eq 'HASH' && ref $h->{upcoming} eq 'ARRAY') { $_->{item}{decorations} = { identity => { name => "Caf\x{e9}" } } for @{ $h->{upcoming} } }
        return $chars->encode($h);
    };
    *jl = sub { my ($dir, $frame) = @_; print $out JSON::PP->new->utf8->encode({ dir => $dir, frame => $frame, ts => '00:00:00.000', epoch => time() + 0 }) . "\n" };
}
jl('meta', 'HANDSHAKE-OK');
if ($st->{unreadable}) {
    for my $s (@send) { logline($ENV{QC_FAKE_TXLOG}, cmdname($s)); jl('tx', encode_json({ type => 'command', command => cmdname($s) })) }
    close $out; exit 0;
}
my $active = $st->{is_active} ? 1 : 0;
my $item = $active ? $st->{live_item} : $st->{copy_item};
my $q    = $active ? $st->{live} : $st->{copy};
jl('rx', encode_json({ type => 'auth_state', logged_in => JSON::PP::true, is_active => ($active ? JSON::PP::true : JSON::PP::false), device_name => $st->{device_name} }));
jl('rx', encode_json({ type => 'playback_state', status => $st->{status}, item => { uri => $item, entity_type => 'track' } }));
for my $s (@send) {
    my $c = cmdname($s);
    logline($ENV{QC_FAKE_TXLOG}, $c);
    jl('tx', encode_json({ type => 'command', command => $c }));
    if ($c eq 'get_queue') {
        my @up = ((map { { uid => "q$_", source => 'queue', item => { uri => $q->[$_] } } } 0 .. $#$q),
                  (map { { uid => "c$_", source => 'context', item => { uri => $st->{context}[$_] } } } 0 .. $#{ $st->{context} }));
        jl('rx', encode_json({ type => 'queue_changed', previous => [], upcoming => \@up }));
    }
    elsif ($c eq 'pause') {
        $st->{status} = 'paused';
        jl('rx', encode_json({ type => 'command_result', ok => JSON::PP::true }));
        jl('rx', encode_json({ type => 'playback_state', status => 'paused', item => { uri => $item, entity_type => 'track' } }));
    }
    elsif ($c eq 'deactivate') {
        unless ($st->{deactivate_noop}) {
            $st->{is_active} = 0; $st->{copy} = [ @{ $st->{live} } ]; $st->{copy_item} = $st->{live_item};
        }
        jl('rx', encode_json({ type => 'device_changed', is_active => JSON::PP::false, device_name => $st->{device_name} }));
        jl('rx', encode_json({ type => 'command_result', command => 'deactivate' }));
    }
    else { jl('rx', encode_json({ type => 'command_result', ok => JSON::PP::true })) }
}
save();
close $out;
if (defined $o{'expect-device'} && $o{'expect-device'} ne $st->{device_name}) { exit 3 }
exit 0;
FAKE_WS

my $fake_cdp = <<'FAKE_CDP';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP;
my ($cmd, @rest) = @ARGV;
$cmd //= '';
sub logline { my ($f, $l) = @_; open(my $fh, '>>', $f) or die "log $f: $!"; print $fh "$l\n"; close $fh }
logline($ENV{QC_FAKE_INVLOG}, "cdp $cmd");
logline($ENV{QC_FAKE_CDPLOG}, join(' ', $cmd, @rest));
my $st = do { open(my $fh, '<', $ENV{QC_FAKE_STATE}) or die; local $/; decode_json(<$fh>) };
sub save { open(my $fh, '>', $ENV{QC_FAKE_STATE}) or die; print $fh encode_json($st); close $fh }
if ($cmd eq 'start') { $st->{app_running} = 1; save(); print "Spotify started (PID 4242), CDP on port 9222\n" }
elsif ($cmd eq 'stop') {
    $st->{app_running} = 0 unless $st->{stop_noop};
    save(); print "Spotify stopped\n";
}
elsif ($cmd eq 'status') {
    if ($st->{app_running}) { print "app log noise\n" . encode_json({ ok => JSON::PP::true, playing => JSON::PP::false }) . "\n" }
    else { print "connect ECONNREFUSED\n"; exit 1 }
}
elsif ($cmd eq 'connect') {
    if ($st->{app_running} && ($st->{on_activate} // 'pull') ne 'noop') {
        $st->{is_active} = 1;
        if ($st->{on_activate} eq 'keep') { $st->{live} = [ @{ $st->{copy} } ]; $st->{live_item} = $st->{copy_item} }
        $st->{status} = 'playing' if $st->{play_on_activate};
        save();
    }
    print encode_json({ ok => JSON::PP::true, action => 'connect', device => $rest[0] }) . "\n";   # exit 0 even on failure
}
elsif ($cmd eq 'disconnect') {
    if ($st->{app_running} && ($st->{on_deactivate} // 'ok') ne 'noop' && $st->{is_active}) {
        $st->{is_active} = 0; $st->{copy} = [ @{ $st->{live} } ]; $st->{copy_item} = $st->{live_item};
        save();
    }
    print encode_json({ ok => JSON::PP::true, action => 'disconnect' }) . "\n";
}
elsif ($cmd eq 'pause') { $st->{status} = 'paused'; save(); print encode_json({ ok => JSON::PP::true }) . "\n" }
else { print STDERR "fake cdp: unknown command $cmd\n"; exit 1 }
exit 0;
FAKE_CDP

my $fake_pids = <<'FAKE_PIDS';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP;
open(my $lf, '>>', $ENV{QC_FAKE_INVLOG}) or die; print $lf "probe\n"; close $lf;
my $st = do { open(my $fh, '<', $ENV{QC_FAKE_STATE}) or die; local $/; decode_json(<$fh>) };
print "4242\n" if $st->{app_running};
exit 0;
FAKE_PIDS

my $fake_gaps = <<'FAKE_GAPS';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP;
my ($cmd, $dir) = @ARGV;
$cmd //= '';
sub logline { my ($f, $l) = @_; open(my $fh, '>>', $f) or die "log $f: $!"; print $fh "$l\n"; close $fh }
logline($ENV{QC_FAKE_INVLOG}, "gaps $cmd");
logline($ENV{QC_FAKE_GAPSLOG}, $cmd);
my $st = do { open(my $fh, '<', $ENV{QC_FAKE_STATE}) or die; local $/; decode_json(<$fh>) };
if ($cmd eq 'record-state') {
    if (($st->{gaps_record} // '') eq 'fail') { print "RIG=LMS_NO_RESULT\n"; exit 2 }
    open(my $fh, '>', "$dir/state-before.txt") or die; print $fh "provider=x\npower=1\n"; close $fh;
    print "STATE_RECORDED $dir/state-before.txt\n"; exit 0;
}
if ($cmd eq 'restore-state') {
    if (($st->{gaps_restore} // '') eq 'fail') { print "NOW volume=40\nSTATE_RESTORED=FAIL diff= volume\n"; exit 1 }
    print "NOW provider=x\nSTATE_RESTORED=PASS\n"; exit 0;
}
print STDERR "fake gaps: unknown $cmd\n"; exit 1;
FAKE_GAPS

my $fake_lms = <<'FAKE_LMS';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP;
my $st = do { open(my $fh, '<', $ENV{QC_FAKE_STATE}) or die; local $/; decode_json(<$fh>) };
my $cnt = "$ENV{QC_FAKE_STATE}.lmscnt";
my $n = 0;
if (open(my $fh, '<', $cnt)) { $n = <$fh>; close $fh; $n //= 0 }
open(my $o, '>', $cnt) or die; print $o $n + 1; close $o;
my $mode = ($n == 0) ? ($st->{lms_mode_first} // 'stop') : ($st->{lms_mode_last} // 'stop');
print "mode=$mode playlist_tracks=1 remote=1\n";
FAKE_LMS

for my $pair (['fake-ws.pl', $fake_ws], ['fake-cdp.pl', $fake_cdp], ['fake-pids.pl', $fake_pids], ['fake-gaps.pl', $fake_gaps], ['fake-lms.pl', $fake_lms]) {
    open(my $fh, '>', "$fakes/$pair->[0]") or die "write $pair->[0]: $!";
    print $fh $pair->[1];
    close $fh;
}

# ------------------------------------------------------------
# harness
# ------------------------------------------------------------
sub slurp { my ($f) = @_; open(my $fh, '<', $f) or return ''; local $/; my $c = <$fh>; return defined $c ? $c : '' }
sub lines_of { my ($f) = @_; return grep { length } split /\n/, slurp($f) }

my %SENT;          # command -> count, across every case (C17)

# run_case(state => {...}, mac => ..., extra => [...], pa => 'stop', dirty => 0, no_out_dir => 0)
sub run_case {
    my (%c) = @_;
    my $d = tempdir(CLEANUP => 1);
    my %st = (
        is_active => 0, device_name => 'lavender-UAT', status => 'paused',
        copy => [], live => [], context => [],
        copy_item => 'spotify:track:COPYITEMCOPYITEMCOPY', live_item => 'spotify:track:LIVEITEMLIVEITEMLIVEI',
        on_activate => 'pull', on_deactivate => 'ok', play_on_activate => 0,
        unreadable => 0, app_running => 0, stop_noop => 0,
        %{ $c{state} || {} },
    );
    open(my $sfh, '>', "$d/state.json") or die; print $sfh encode_json(\%st); close $sfh;
    my $out_dir = "$d/out";
    if ($c{dirty}) { mkdir $out_dir; open(my $fh, '>', "$out_dir/old.txt") or die; print $fh "old\n"; close $fh }

    my @args = ('--mac', ($c{mac} // $UAT_MAC));
    push @args, ('--out-dir', $out_dir) unless $c{no_out_dir};
    push @args, @{ $c{extra} || [] };

    local $ENV{QC_REPO}          = $project_dir;
    local $ENV{QC_WS_RECORD}     = "perl $fakes/fake-ws.pl";
    local $ENV{QC_CDP}           = "perl $fakes/fake-cdp.pl";
    local $ENV{QC_APP_PIDS_CMD}  = "perl $fakes/fake-pids.pl";
    local $ENV{QC_FAKE_STATE}    = "$d/state.json";
    local $ENV{QC_FAKE_TXLOG}    = "$d/tx.log";
    local $ENV{QC_FAKE_CDPLOG}   = "$d/cdp.log";
    local $ENV{QC_FAKE_INVLOG}   = "$d/inv.log";
    local $ENV{QC_FAKE_GAPSLOG}  = "$d/gaps.log";
    local $ENV{QC_GAPS}          = "perl $fakes/fake-gaps.pl";
    local $ENV{QC_LMS_STATUS_CMD} = "perl $fakes/fake-lms.pl";
    local $ENV{PA_MAC}          = $FAKE_PA;
    delete $ENV{PA_MAC} if $c{no_pa_mac};
    local $ENV{PA_IDLE_FAKE_MODE} = $c{pa} // 'stop';
    local $ENV{LMS_URL}          = 'http://127.0.0.1:9/jsonrpc.js';
    local $ENV{QC_POLL_SLEEP}    = '0';

    my $cmd = join(' ', 'bash', "'$tool'", map { "'$_'" } @args) . " > '$d/stdout' 2>&1 < /dev/null";
    system($cmd);
    my $rc = $? == -1 ? -1 : ($? >> 8);

    my $stdout = slurp("$d/stdout");
    my @qc = grep { /\AQUEUE_CLEARED=/ } split /\n/, $stdout;
    my @tx  = lines_of("$d/tx.log");
    my @cdp = map { (split / /, $_)[0] } lines_of("$d/cdp.log");
    my @gaps = lines_of("$d/gaps.log");
    $SENT{$_}++ for @tx;
    my $after = eval { decode_json(slurp("$d/state.json")) } || {};
    return {
        rc => $rc, out => $stdout, qc => ($qc[-1] // ''), nqc => scalar(@qc),
        tx => \@tx, cdp => \@cdp, gaps => \@gaps, inv => [ lines_of("$d/inv.log") ],
        state => $after, out_dir => $out_dir,
        last_line => (split /\n/, $stdout)[-1] // '',
    };
}

sub only_reads { my ($r) = @_; return (@{ $r->{tx} } > 0 && !grep { $_ ne 'get_queue' } @{ $r->{tx} }) ? 1 : 0 }
sub in_order {
    my ($have, @want) = @_;
    my $i = 0;
    for my $h (@$have) { $i++ if $i < @want && $h eq $want[$i] }
    return $i == @want ? 1 : 0;
}
sub nothing_invoked { my ($r) = @_; return (@{ $r->{inv} } == 0) ? 1 : 0 }

# ------------------------------------------------------------
# C01 empty live
# ------------------------------------------------------------
{
    my $r = run_case(state => { is_active => 1, live => [] });
    like($r->{qc}, qr/\AQUEUE_CLEARED=PASS before=0 after=0 action=none\b/, 'iwm C01 empty live: PASS before=0 after=0 action=none');
    like($r->{qc}, qr/view_before=live restored=active\z/, 'iwm C01 view_before=live restored=active');
    is($r->{rc}, 0, 'iwm C01 exit 0');
    ok(only_reads($r) && !@{ $r->{cdp} }, 'iwm C01 txlog only get_queue, app driver untouched');
    is($r->{nqc}, 1, 'iwm C01 exactly one QUEUE_CLEARED line');
    is($r->{last_line}, $r->{qc}, 'iwm C01 the QUEUE_CLEARED line is the last output line');
}

# ------------------------------------------------------------
# C01u (79-46): the same empty live session, but the frames carry a non-ASCII title the way the real
# recorder writes them (live 2026-10-26: "malformed UTF-8 character in JSON string" on an accented
# title made every read `read_before_unreadable`).
# ------------------------------------------------------------
{
    my $r = run_case(state => { is_active => 1, live => [], nonascii => 1 });
    like($r->{qc}, qr/\AQUEUE_CLEARED=PASS before=0 after=0 action=none\b/, 'iwm C01u non-ASCII title: PASS before=0 after=0 action=none (not read_before_unreadable)');
    is($r->{rc}, 0, 'iwm C01u exit 0');
}
{
    my $r = run_case(state => { is_active => 1, live => ['spotify:track:QQQQQQQQQQQQQQQQQQQQQQ'], nonascii => 1 });
    unlike($r->{qc}, qr/read_before_unreadable/, 'iwm C01u2 non-ASCII queue entry: the read is not unreadable');
}

# ------------------------------------------------------------
# C02 empty copy
# ------------------------------------------------------------
{
    my $r = run_case(state => { is_active => 0, copy => [] });
    like($r->{qc}, qr/\AQUEUE_CLEARED=PASS before=0 after=0 action=none\b.*view_before=snapshot/, 'iwm C02 empty copy: PASS before=0 after=0 action=none view_before=snapshot');
    is($r->{rc}, 0, 'iwm C02 exit 0');
    ok(only_reads($r) && !@{ $r->{cdp} }, 'iwm C02 reads only');
}

# ------------------------------------------------------------
# C03 stale copy (and C18 app closed afterwards)
# ------------------------------------------------------------
{
    my $r = run_case(state => { is_active => 0, copy => [$X], live => [] });
    like($r->{qc}, qr/\AQUEUE_CLEARED=PASS before=1 after=0 action=app_transfer\b.*restored=inactive\z/, 'iwm C03 stale copy: PASS before=1 after=0 action=app_transfer restored=inactive');
    is($r->{rc}, 0, 'iwm C03 exit 0');
    ok(in_order($r->{cdp}, qw(start status connect disconnect pause stop)), 'iwm C03 app driver order start,status,connect,disconnect,pause,stop');
    is($r->{state}{is_active}, 0, 'iwm C03 daemon released (is_active=0) afterwards');
    ok(!grep({ $_ ne 'get_queue' } @{ $r->{tx} }), 'iwm C03 only get_queue went over the WS (no pause needed)');
    unlike($r->{out}, qr/QC_PAUSED_DURING_REFRESH=1/, 'iwm C03 not playing: no pause during refresh');

    # C18 (app_transfer): the app is closed afterwards
    ok($r->{cdp} && grep({ $_ eq 'stop' } @{ $r->{cdp} }), 'iwm C18 stop was called');
    is($r->{state}{app_running}, 0, 'iwm C18 app closed afterwards (probe empty)');
    like($r->{out}, qr/^QC_CDP_CALLS /m, 'iwm C18 QC_CDP_CALLS recorded');

    # release fallback is NOT used when disconnect released the daemon
    unlike($r->{out}, qr/QC_RELEASE_FALLBACK/, 'iwm C12 no release fallback when disconnect released');
    # LMS state recorded before the handover, restored after it (gaps-76.sh record-state / restore-state)
    is_deeply($r->{gaps}, [qw(record-state restore-state)], 'iwm C20 LMS state recorded once before and restored once after');
    like($r->{out}, qr/^STATE_RESTORED=PASS$/m, 'iwm C20 STATE_RESTORED=PASS printed');
}

# ------------------------------------------------------------
# C04 real entries on the active daemon
# ------------------------------------------------------------
{
    my $r = run_case(state => { is_active => 1, live => [$X] });
    like($r->{qc}, qr/\AQUEUE_CLEARED=UNBESTIMMT before=1 after=1 action=none reason=account_queue_holds_entries\b/, 'iwm C04 real entries (active): UNBESTIMMT account_queue_holds_entries action=none');
    is($r->{rc}, 3, 'iwm C04 exit 3');
    ok(only_reads($r) && !@{ $r->{cdp} }, 'iwm C04 reads only');
}

# ------------------------------------------------------------
# C05 real entries after handover
# ------------------------------------------------------------
{
    my $r = run_case(state => { is_active => 0, copy => [$X], live => [$X] });
    like($r->{qc}, qr/\AQUEUE_CLEARED=UNBESTIMMT before=1 after=1 action=app_transfer reason=account_queue_holds_entries\b.*restored=inactive\z/, 'iwm C05 real entries after handover: UNBESTIMMT account_queue_holds_entries, restored inactive');
    is($r->{rc}, 3, 'iwm C05 exit 3');
    is($r->{state}{is_active}, 0, 'iwm C05 daemon released again');
    is($r->{state}{app_running}, 0, 'iwm C05 app closed again');
}

# ------------------------------------------------------------
# C06 lavender-pa playing
# ------------------------------------------------------------
{
    my $r = run_case(state => { is_active => 0, copy => [$X] }, pa => 'play');
    like($r->{qc}, qr/\AQUEUE_CLEARED=UNBESTIMMT before=1 after=1 action=none reason=rig_not_idle:pa\b/, 'iwm C06 pa playing: UNBESTIMMT rig_not_idle:pa');
    is($r->{rc}, 3, 'iwm C06 exit 3');
    ok(only_reads($r), 'iwm C06 no write over the WS');
    ok(!@{ $r->{cdp} }, 'iwm C06 no connect / no app start in any log');
}

# ------------------------------------------------------------
# C07 app already open
# ------------------------------------------------------------
{
    my $r = run_case(state => { is_active => 0, copy => [$X], app_running => 1 });
    like($r->{qc}, qr/\AQUEUE_CLEARED=UNBESTIMMT before=1 after=1 action=none reason=rig_not_idle:app\b/, 'iwm C07 app open: UNBESTIMMT rig_not_idle:app');
    is($r->{rc}, 3, 'iwm C07 exit 3');
    ok(only_reads($r) && !@{ $r->{cdp} }, 'iwm C07 no write, the user\'s app is not touched');
    is($r->{state}{app_running}, 1, 'iwm C07 the app is still running');
}

# ------------------------------------------------------------
# C08 lavender-pa as target (any case) and malformed input
# ------------------------------------------------------------
{
    my $r = run_case(mac => uc($FAKE_PA), state => { copy => [$X] });
    like($r->{qc}, qr/\AQUEUE_CLEARED=UNBESTIMMT before=- after=- action=none reason=refused_target_lavender-pa\b/, 'iwm C08 lavender-pa MAC refused');
    is($r->{rc}, 2, 'iwm C08 exit 2');
    ok(nothing_invoked($r) && $r->{rc} == 2, 'iwm C08 fakes never invoked');

    my $r2 = run_case(mac => lc($FAKE_PA), state => { copy => [$X] });
    like($r2->{qc}, qr/reason=refused_target_lavender-pa\b/, 'iwm C08 lower-case lavender-pa MAC refused too');

    my $r5 = run_case(no_pa_mac => 1, state => { copy => [$X] });
    is($r5->{rc}, 2, 'iwm C08 PA_MAC not set: exit 2 (no default, D-10)');
    like($r5->{qc}, qr/\AQUEUE_CLEARED=UNBESTIMMT before=- after=- action=none reason=pa_mac_not_set\b/, 'iwm C08 PA_MAC not set: reason=pa_mac_not_set');
    ok(nothing_invoked($r5), 'iwm C08 PA_MAC not set: fakes never invoked');

    my $r3 = run_case(mac => 'not-a-mac');
    is($r3->{rc}, 2, 'iwm C08 malformed MAC: exit 2');
    like($r3->{qc}, qr/\AQUEUE_CLEARED=UNBESTIMMT .*reason=usage\b/, 'iwm C08 malformed MAC: reason=usage');
    ok(nothing_invoked($r3), 'iwm C08 malformed MAC: fakes never invoked');

    my $r4 = run_case(no_out_dir => 1);
    is($r4->{rc}, 2, 'iwm C08 missing --out-dir: exit 2');
    ok(nothing_invoked($r4) && $r4->{qc} =~ /reason=usage/, 'iwm C08 missing --out-dir: usage, fakes never invoked');
}

# ------------------------------------------------------------
# C09 the daemon reports another device name
# ------------------------------------------------------------
{
    my $r = run_case(state => { device_name => 'lavender-pa', copy => [$X] });
    like($r->{qc}, qr/\AQUEUE_CLEARED=UNBESTIMMT .*reason=device_name_mismatch\b/, 'iwm C09 device_name lavender-pa: refused (device_name_mismatch)');
    is($r->{rc}, 2, 'iwm C09 exit 2');
    ok(only_reads($r) && !@{ $r->{cdp} }, 'iwm C09 no write');
}

# ------------------------------------------------------------
# C10 non-empty out dir
# ------------------------------------------------------------
{
    my $r = run_case(dirty => 1, state => { copy => [$X] });
    like($r->{qc}, qr/\AQUEUE_CLEARED=UNBESTIMMT .*reason=out_dir_not_empty\b/, 'iwm C10 non-empty --out-dir refused');
    is($r->{rc}, 2, 'iwm C10 exit 2');
    ok(nothing_invoked($r), 'iwm C10 fakes never invoked');
    is(slurp("$r->{out_dir}/old.txt"), "old\n", 'iwm C10 existing evidence left intact');
}

# ------------------------------------------------------------
# C11 handover without effect
# ------------------------------------------------------------
{
    my $r = run_case(state => { is_active => 0, copy => [$X], on_activate => 'noop' });
    like($r->{qc}, qr/\AQUEUE_CLEARED=UNBESTIMMT before=1 .*action=app_transfer reason=transfer_no_effect\b/, 'iwm C11 handover without effect: UNBESTIMMT transfer_no_effect');
    is($r->{rc}, 3, 'iwm C11 exit 3');
    is($r->{state}{app_running}, 0, 'iwm C11 app closed again');
    ok(!grep({ $_ eq 'pause' || $_ eq 'disconnect' } @{ $r->{cdp} }), 'iwm C11 no desktop pause / disconnect when nothing was handed over');
}

# ------------------------------------------------------------
# C12 release does not take effect: the WS deactivate fallback (live finding 2026-10-22)
# ------------------------------------------------------------
{
    my $r = run_case(state => { is_active => 0, copy => [$X], live => [], on_deactivate => 'noop' });
    like($r->{out}, qr/^QC_RELEASE_FALLBACK=deactivate$/m, 'iwm C12 disconnect does not release: QC_RELEASE_FALLBACK=deactivate printed');
    is(scalar(grep { $_ eq 'deactivate' } @{ $r->{tx} }), 1, 'iwm C12 exactly one deactivate sent over the WS');
    like($r->{qc}, qr/\AQUEUE_CLEARED=PASS before=1 after=0 action=app_transfer\b.*restored=inactive\z/, 'iwm C12 fallback released the daemon: PASS');
    is($r->{rc}, 0, 'iwm C12 exit 0');
    is($r->{state}{is_active}, 0, 'iwm C12 daemon inactive afterwards');

    my $r2 = run_case(state => { is_active => 0, copy => [$X], live => [], on_deactivate => 'noop', deactivate_noop => 1 });
    like($r2->{out}, qr/^QC_RELEASE_FALLBACK=deactivate$/m, 'iwm C12 fallback tried when nothing else releases');
    like($r2->{qc}, qr/\AQUEUE_CLEARED=FAIL .*reason=not_restored\b/, 'iwm C12 fallback without effect: FAIL not_restored');
    is($r2->{rc}, 1, 'iwm C12 exit 1 when even the fallback does not release');
}

# ------------------------------------------------------------
# ------------------------------------------------------------
# C13 daemon playing after the handover
# ------------------------------------------------------------
{
    my $r = run_case(state => { is_active => 0, copy => [$X], live => [], play_on_activate => 1 });
    is(scalar(grep { $_ eq 'pause' } @{ $r->{tx} }), 1, 'iwm C13 one pause sent over the WS');
    like($r->{out}, qr/^QC_PAUSED_DURING_REFRESH=1$/m, 'iwm C13 QC_PAUSED_DURING_REFRESH=1');
    like($r->{qc}, qr/\AQUEUE_CLEARED=PASS before=1 after=0 action=app_transfer\b/, 'iwm C13 final PASS');
    is($r->{state}{status}, 'paused', 'iwm C13 daemon left paused');
}

# ------------------------------------------------------------
# C14 context-only copy
# ------------------------------------------------------------
{
    my $r = run_case(state => { is_active => 0, copy => [], context => [$Y, $Z] });
    like($r->{qc}, qr/\AQUEUE_CLEARED=PASS before=0 after=0 action=none\b/, 'iwm C14 context entries are never counted: before=0');
    ok(only_reads($r) && !@{ $r->{cdp} }, 'iwm C14 reads only');
}

# ------------------------------------------------------------
# C15 unreadable first read
# ------------------------------------------------------------
{
    my $r = run_case(state => { unreadable => 1, copy => [$X] });
    like($r->{qc}, qr/\AQUEUE_CLEARED=UNBESTIMMT before=- after=- action=none reason=read_before_unreadable\b/, 'iwm C15 no queue_changed: UNBESTIMMT read_before_unreadable');
    is($r->{rc}, 3, 'iwm C15 exit 3');
    ok(!@{ $r->{cdp} }, 'iwm C15 no write');
}

# ------------------------------------------------------------
# C16 --refresh on an empty inactive copy
# ------------------------------------------------------------
{
    my $r = run_case(state => { is_active => 0, copy => [], live => [] }, extra => ['--refresh']);
    like($r->{qc}, qr/\AQUEUE_CLEARED=PASS before=0 after=0 action=app_transfer\b.*restored=inactive\z/, 'iwm C16 --refresh: full cycle, PASS before=0 after=0 action=app_transfer restored=inactive');
    ok(in_order($r->{cdp}, qw(start connect disconnect stop)), 'iwm C16 the app driver ran the whole cycle');
    my $r2 = run_case(state => { is_active => 1, live => [] }, extra => ['--refresh']);
    like($r2->{qc}, qr/\AQUEUE_CLEARED=PASS before=0 after=0 action=none\b/, 'iwm C16 --refresh on an active daemon: no write');
}

# ------------------------------------------------------------
# C19 app still running after stop
# ------------------------------------------------------------
{
    my $r = run_case(state => { is_active => 0, copy => [$X], live => [], stop_noop => 1 });
    like($r->{qc}, qr/\AQUEUE_CLEARED=FAIL .*reason=app_not_closed\b/, 'iwm C19 app still running after stop: FAIL app_not_closed');
    is($r->{rc}, 1, 'iwm C19 exit 1');
}

# ------------------------------------------------------------
# C21 LMS state not restored
# ------------------------------------------------------------
{
    my $r = run_case(state => { is_active => 0, copy => [$X], live => [], gaps_restore => 'fail' });
    like($r->{qc}, qr/\AQUEUE_CLEARED=FAIL .*reason=lms_state_not_restored\b/, 'iwm C21 restore-state without STATE_RESTORED=PASS: FAIL lms_state_not_restored');
    is($r->{rc}, 1, 'iwm C21 exit 1');
    is($r->{state}{is_active}, 0, 'iwm C21 the daemon itself was still released');
}

# ------------------------------------------------------------
# C22 LMS state not recorded: nothing is touched
# ------------------------------------------------------------
{
    my $r = run_case(state => { is_active => 0, copy => [$X], live => [], gaps_record => 'fail' });
    like($r->{qc}, qr/\AQUEUE_CLEARED=UNBESTIMMT before=1 after=1 action=none reason=lms_state_not_recorded\b/, 'iwm C22 record-state fails: UNBESTIMMT lms_state_not_recorded');
    is($r->{rc}, 3, 'iwm C22 exit 3');
    ok(only_reads($r) && !@{ $r->{cdp} }, 'iwm C22 no handover without a recorded LMS state');
    my $r2 = run_case(state => { is_active => 0, copy => [$X] }, pa => 'play');
    is_deeply($r2->{gaps}, [], 'iwm C22 record-state is not run when a rig gate stops the write path first');
}

# ------------------------------------------------------------
# C23 an LMS mode change is printed, never hidden
# ------------------------------------------------------------
{
    my $r = run_case(state => { is_active => 0, copy => [$X], live => [], lms_mode_first => 'stop', lms_mode_last => 'play' });
    like($r->{out}, qr/^QC_LMS_MODE_CHANGED before=stop after=play$/m, 'iwm C23 LMS mode stop -> play is printed');
    like($r->{qc}, qr/\AQUEUE_CLEARED=PASS /, 'iwm C23 the printed change does not turn the daemon result into something else');
    my $r2 = run_case(state => { is_active => 0, copy => [$X], live => [] });
    unlike($r2->{out}, qr/QC_LMS_MODE_CHANGED/, 'iwm C23 no change line when the mode is unchanged');
}

# ------------------------------------------------------------
# C17 across every case: no consuming or steering verb, ever
# ------------------------------------------------------------
{
    my @forbidden = qw(skip_next skip_prev add_to_queue play seek set_volume set_shuffle set_repeat_context set_repeat_track);
    my @hit = grep { $SENT{$_} } @forbidden;
    ok($SENT{get_queue} && $SENT{get_queue} > 10, 'iwm C17 the sweep is not vacuous (get_queue was sent by the cases)');
    is_deeply(\@hit, [], 'iwm C17 none of the consuming / steering verbs was ever sent');
    my @other = grep { $_ ne 'get_queue' && $_ ne 'pause' && $_ ne 'deactivate' } keys %SENT;
    is_deeply([ sort @other ], [], 'iwm C17 only get_queue, pause and (fallback) deactivate ever crossed the WS');
}

done_testing();

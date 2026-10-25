#!/usr/bin/perl

# t/43_soloist_ws_record.t
#
# D-15 (81-02): Unit + Blackbox acceptance of tools/soloist-ws-record.pl --
# the D-15 tool built in 81-01 gets its test coverage here so no later spike
# rides an uninstrumented instrument (Nyquist-Grundsatz, 81-VALIDATION.md).
#
# Modulino + Blackbox split (new convention -- 81-PATTERNS.md "Luecke, die
# der Plan fuellen muss": no existing t/ file loads a tools/*.pl script).
# The pure logic (port resolution, staleness, loopback, URI validation,
# JSONL framing, device check) is loaded via `require` as a modulino -- the
# script's own `main(@ARGV) unless caller;` guard means requiring it from a
# test never executes main(). This is the only way to unit-test these subs
# without a live daemon. The CLI contract (--help, non-loopback refusal) is
# checked as a blackbox via system()/open('-|', ...) in LIST form -- t/05
# runs `perl -c` through a shell-string backtick, but that is test-harness
# code for a different check, not a pattern to copy here (81-PATTERNS.md
# Hinweis 2 also flags that CI runs `prove t/`, not `prove -l t/`).
#
# Flagged assumption (unresolved, see 81-02-PLAN.md flagged_assumptions):
# this test exercises only the VENDORED Protocol::WebSocket::Client (via a
# mock substituted for it below). Whether an LMS-bundled 9.1+ copy -- which
# Soloist::ensureWsLib's fallback convention would prefer if the tool wired
# it the same way -- has identical callback semantics is untested here.

use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use JSON::PP qw(decode_json);

# Resolve project root (t/<group>/x.t sits two levels below it)
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

my $script = "$project_dir/tools/soloist-ws-record.pl";
unless (-f $script) {
    die "tools/soloist-ws-record.pl not yet present in this checkout -- wrong project root or broken checkout (84-09: die, never skip)\n";
}

sub write_stub {
    my ($dir, $pkg, $code) = @_;
    my @parts = split /::/, $pkg;
    my $file  = pop @parts;
    my $path  = $dir . '/' . join('/', @parts);
    make_path($path) unless -d $path;
    open(my $fh, '>', "$path/$file.pm") or die "Cannot write stub $pkg: $!";
    print $fh $code;
    close($fh);
}

my $stub_dir = tempdir(CLEANUP => 1);

# ============================================================
# Mock Protocol::WebSocket::Client -- new (mac, on, connect, read, write,
# is_ready, disconnect, pong), tracks writes in package globals so the
# 'passive' group below can assert on them without a real socket peer.
# ============================================================
my $mock_client_code = <<'END';
package Protocol::WebSocket::Client;

our $WRITES = 0;
our @SENT;

sub new {
    my ($class, %args) = @_;
    return bless { url => $args{url}, cb => {} }, $class;
}

sub on {
    my ($self, %cb) = @_;
    $self->{cb}{$_} = $cb{$_} for keys %cb;
    return $self;
}

sub connect {
    my ($self) = @_;
    $self->{cb}{connect}->($self) if $self->{cb}{connect};
    return $self;
}

sub read {
    my ($self, $bytes) = @_;
    $self->{cb}{read}->($self, $bytes) if $self->{cb}{read};
    return $self;
}

sub write {
    my ($self, $text) = @_;
    $WRITES++;
    push @SENT, $text;
    return $self;
}

sub is_ready   { return 1; }
sub disconnect { my $self = shift; return $self; }
sub pong       { my $self = shift; return $self; }

1;
END

write_stub($stub_dir, 'Protocol::WebSocket::Client', $mock_client_code);

unshift @INC, $stub_dir, $project_dir;

# The unshift above matches the stated convention, but does NOT reliably
# win: the required script's OWN `use lib "$RealBin/../Plugins/SpotOn/Vendor"`
# runs at compile time of the required file, AFTER this unshift, and
# re-unshifts the real Vendor path ahead of $stub_dir every single time
# (verified empirically -- @INC ends up [VendorDir, ProjectDir, stub_dir,
# ...] regardless of call-site order). Pre-registering %INC is the
# standard, robust Perl mocking idiom for this exact situation and
# sidesteps the ordering problem entirely, without touching the script
# under test.
eval $mock_client_code;
die "failed to eval mock Protocol::WebSocket::Client: $@" if $@;
$INC{'Protocol/WebSocket/Client.pm'} = "mock ($test_dir/43_soloist_ws_record.t)";

require_ok($script)
    or BAIL_OUT("Failed to load $script as a modulino");

# ============================================================
# help -- CLI blackbox: --help exits 0 and documents the flags a spike
# runner needs (81-VALIDATION.md D-15 Wave-0 line).
# ============================================================
subtest 'help' => sub {
    my $out;
    {
        open(my $fh, '-|', $^X, $script, '--help') or die "cannot run --help: $!";
        local $/;
        $out = <$fh>;
        close($fh);
    }
    my $exit = $? >> 8;
    is($exit, 0, '--help exits 0');
    like($out, qr/--mac/,            '--help output documents --mac');
    like($out, qr/--send/,           '--help output documents --send');
    like($out, qr/--preflight/,      '--help output documents --preflight');
    like($out, qr/--expect-device/,  '--help output documents --expect-device');
};

# ============================================================
# port -- resolve_port(\%opt): fresh read every call (D-15, no caching),
# unparseable content -> undef.
# ============================================================
subtest 'port' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $data_dir = "$tmp/spoton/soloist/players/0200005a1101/data";
    make_path($data_dir);

    open(my $fh, '>', "$data_dir/ws.port") or die "cannot write ws.port: $!";
    print $fh "45467\n";
    close($fh);
    open(my $pfh, '>', "$data_dir/soloist.pid") or die "cannot write soloist.pid: $!";
    print $pfh "$$\n";
    close($pfh);

    my ($port1, $reason1) = resolve_port({ mac => '02:00:00:5a:11:01', cache_dir => $tmp });
    is($port1, 45467, 'resolve_port: reads the current ws.port content')
        or diag("reason: " . ($reason1 // 'undef'));

    open(my $fh2, '>', "$data_dir/ws.port") or die "cannot rewrite ws.port: $!";
    print $fh2 "38105\n";
    close($fh2);
    my ($port2, $reason2) = resolve_port({ mac => '02:00:00:5a:11:01', cache_dir => $tmp });
    is($port2, 38105, 'resolve_port: re-reads ws.port fresh on every call (no caching, D-15)')
        or diag("reason: " . ($reason2 // 'undef'));

    open(my $fh3, '>', "$data_dir/ws.port") or die "cannot rewrite ws.port: $!";
    print $fh3 "abc\n";
    close($fh3);
    my ($port3, $reason3) = resolve_port({ mac => '02:00:00:5a:11:01', cache_dir => $tmp });
    is($port3, undef, 'resolve_port: unparseable ws.port content returns undef');
    like($reason3, qr/unparseable/, 'resolve_port: reason names the unparseable content');
};

# ============================================================
# stale -- SoloistDaemon.pm:303-313 staleness rule mirrored: mtime < ref is
# rejected, min_mtime=>0 accepts anything, a dead soloist.pid is rejected
# even with a fresh-looking mtime.
# ============================================================
subtest 'stale' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $data_dir = "$tmp/spoton/soloist/players/0200005a1101/data";
    make_path($data_dir);

    open(my $fh, '>', "$data_dir/ws.port") or die "cannot write ws.port: $!";
    print $fh "45467\n";
    close($fh);
    open(my $pfh, '>', "$data_dir/soloist.pid") or die "cannot write soloist.pid: $!";
    print $pfh "$$\n";
    close($pfh);
    utime(time - 3600, time - 3600, "$data_dir/ws.port")
        or die "utime failed: $!";

    my ($port_stale, $reason_stale) = resolve_port({
        mac => '02:00:00:5a:11:01', cache_dir => $tmp, min_mtime => time - 60,
    });
    is($port_stale, undef, 'resolve_port: mtime older than --min-mtime is rejected');
    like($reason_stale, qr/stale/, 'resolve_port: reason mentions "stale"');

    my ($port_fresh, $reason_fresh) = resolve_port({
        mac => '02:00:00:5a:11:01', cache_dir => $tmp, min_mtime => 0,
    });
    is($port_fresh, 45467, 'resolve_port: min_mtime=>0 accepts the same old file')
        or diag("reason: " . ($reason_fresh // 'undef'));

    open(my $pfh2, '>', "$data_dir/soloist.pid") or die "cannot rewrite soloist.pid: $!";
    print $pfh2 "999999\n";
    close($pfh2);
    my ($port_dead, $reason_dead) = resolve_port({
        mac => '02:00:00:5a:11:01', cache_dir => $tmp,
    });
    is($port_dead, undef, 'resolve_port: a dead pid in soloist.pid is rejected');
    like($reason_dead, qr/not running/, 'resolve_port: reason names the dead daemon pid');
};

# ============================================================
# pid-file-fail-closed -- 81-REVIEW.md WR-02: a missing or unparseable
# soloist.pid (no --min-mtime given) must be a hard failure, not a silent
# ref_mtime=0 that disables the staleness check entirely -- exactly the
# scenario (dead/foreign process, no pid file) where a stale ws.port is
# most likely and most dangerous to trust.
# ============================================================
subtest 'pid-file-fail-closed' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $data_dir = "$tmp/spoton/soloist/players/0200005a1101/data";
    make_path($data_dir);

    open(my $fh, '>', "$data_dir/ws.port") or die "cannot write ws.port: $!";
    print $fh "45467\n";
    close($fh);

    # No soloist.pid file at all, no --min-mtime given.
    my ($port_missing, $reason_missing) = resolve_port({
        mac => '02:00:00:5a:11:01', cache_dir => $tmp,
    });
    is($port_missing, undef,
        'resolve_port: a missing soloist.pid (no --min-mtime) is rejected, not silently ref_mtime=>0');
    like($reason_missing, qr/cannot open/,
        'resolve_port: reason names the missing soloist.pid');

    # soloist.pid present but unparseable.
    open(my $pfh, '>', "$data_dir/soloist.pid") or die "cannot write soloist.pid: $!";
    print $pfh "not-a-pid\n";
    close($pfh);
    my ($port_garbled, $reason_garbled) = resolve_port({
        mac => '02:00:00:5a:11:01', cache_dir => $tmp,
    });
    is($port_garbled, undef, 'resolve_port: an unparseable soloist.pid is rejected');
    like($reason_garbled, qr/unparseable/, 'resolve_port: reason names the unparseable soloist.pid');

    # --min-mtime explicitly given still bypasses the pid-file read entirely,
    # even with soloist.pid missing/garbled.
    unlink("$data_dir/soloist.pid");
    my ($port_bypass, $reason_bypass) = resolve_port({
        mac => '02:00:00:5a:11:01', cache_dir => $tmp, min_mtime => 0,
    });
    is($port_bypass, 45467,
        'resolve_port: explicit --min-mtime bypasses the pid-file read even with soloist.pid missing')
        or diag("reason: " . ($reason_bypass // 'undef'));
};

# ============================================================
# loopback -- is_loopback($host) pure-function coverage plus one blackbox
# refusal (T-81-02: the WS socket has no auth/TLS/origin check).
# ============================================================
subtest 'loopback' => sub {
    ok(is_loopback('127.0.0.1'),  'is_loopback: 127.0.0.1 is loopback');
    ok(is_loopback('127.9.9.9'),  'is_loopback: any 127.0.0.0/8 address is loopback');
    ok(is_loopback('::1'),        'is_loopback: ::1 is loopback');
    ok(is_loopback('localhost'),  'is_loopback: localhost is loopback');
    ok(!is_loopback('192.168.0.1'),  'is_loopback: 192.168.0.1 is not loopback');
    ok(!is_loopback('0.0.0.0'),      'is_loopback: 0.0.0.0 is not loopback');
    ok(!is_loopback('lavender.local'), 'is_loopback: an mDNS hostname is not loopback');
    ok(!is_loopback(''),             'is_loopback: empty string is not loopback');
    ok(!is_loopback("127.0.0.1\n"),
        'is_loopback: a trailing newline is rejected (mirrors validate_uri $ -> \A...\z hardening)');

    system($^X, $script, '--port', '1', '--host', '192.168.0.1');
    my $exit = $? >> 8;
    is($exit, 2, 'blackbox: a non-loopback --host is refused with exit 2');
};

# ============================================================
# jsonl -- jsonl_line($dir, $text): one UTF-8-octet line, ts/epoch/dir
# fields, and a lossless round-trip for non-ASCII frame text (81-02
# fixed jsonl_line to a pure ($dir, $text) -> $line function -- the 81-01
# implementation took a filehandle and printed as a side effect, which
# does not match the 81-01-PLAN.md/interfaces contract this group tests).
# ============================================================
subtest 'jsonl' => sub {
    # Frame.pm:98 (vendored Protocol::WebSocket::Frame) decodes every real
    # WS text frame with Encode::decode('UTF-8', $bytes), so $text always
    # arrives at jsonl_line() as a UTF8-flagged Perl character string for
    # non-ASCII content. A bare literal with \x{fc}/\x{e4} escapes (all
    # codepoints < 256) does NOT reliably get that flag set, so without the
    # explicit utf8::upgrade below this fixture never actually exercised
    # jsonl_line's utf8::is_utf8() branch -- masking the double-UTF-8-encode
    # regression this subtest guards against (81-REVIEW.md CR-01).
    my $frame = "{\"type\":\"track_changed\",\"item\":{\"name\":\"Fr\x{fc}hling \x{e4}\"}}";
    utf8::upgrade($frame);
    ok(utf8::is_utf8($frame),
        'jsonl: fixture carries the UTF8 flag the way Frame.pm:98 leaves it on real frames');
    my $line = jsonl_line('rx', $frame);

    is(($line =~ tr/\n//), 1, 'jsonl_line: exactly one newline in the returned line');
    ok($line =~ /\n\z/, 'jsonl_line: the line ends with a newline');
    ok(!utf8::is_utf8($line), 'jsonl_line: return value is UTF-8 octets, not a character string');

    my $decoded = eval { decode_json($line) };
    ok(!$@, 'jsonl_line: decode_json succeeds on the returned line') or diag($@);
    like($decoded->{ts}, qr/^\d\d:\d\d:\d\d\.\d{3}$/, 'jsonl_line: ts matches HH:MM:SS.mmm');
    ok($decoded->{epoch} > 1.7e9, 'jsonl_line: epoch is a plausible Unix timestamp');
    is($decoded->{dir}, 'rx', 'jsonl_line: dir is preserved verbatim');

    # 73-05-style UTF-8 bridge: decode_json already returned a decoded
    # character string for 'frame' -- re-encode before decoding it AGAIN,
    # exactly the pitfall SoloistWS.pm:418-427 documents.
    my $frame_text = $decoded->{frame};
    utf8::encode($frame_text) if utf8::is_utf8($frame_text);
    my $inner = eval { decode_json($frame_text) };
    ok(!$@, 'jsonl_line: the frame field itself round-trips through decode_json') or diag($@);
    is($inner->{item}{name}, "Fr\x{fc}hling \x{e4}",
        'jsonl_line: round-trip preserves non-ASCII text exactly (Frame::next UTF-8 bridge)');

    my $ascii_frame = '{"type":"command","command":"get_state"}';
    my $ascii_decoded = decode_json(jsonl_line('tx', $ascii_frame));
    is($ascii_decoded->{frame}, $ascii_frame,
        'jsonl_line: a pure-ASCII frame is preserved byte-for-byte');
};

# ============================================================
# passive -- run_recorder(\%opt) with the 81-02 client_factory/sock test
# hooks: without --send, zero writes (T-81-03, the instrument never
# measures itself); with --send, exactly the built commands, in order.
# A forked helper closes its end of a socketpair after 0.3s so
# run_recorder's own select loop sees EOF well before the 0.5s safety
# bound -- run_recorder no longer calls exit() itself (81-02 refactor: it
# now returns an exit code and main() is the sole exit() call site), so
# calling it in-process here does not kill the test process.
# ============================================================
subtest 'passive' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $n = 0;

    my $run_case = sub {
        my (@sends) = @_;
        $n++;
        socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
            or die "socketpair: $!";
        my $pid = fork();
        die "fork failed: $!" unless defined $pid;
        if ($pid == 0) {
            close($a);
            select(undef, undef, undef, 0.3);
            close($b);
            exit(0);
        }
        close($b);
        $Protocol::WebSocket::Client::WRITES = 0;
        @Protocol::WebSocket::Client::SENT = ();
        my $rc = run_recorder({
            host           => '127.0.0.1',
            sock           => $a,
            client_factory => sub { Protocol::WebSocket::Client->new(@_) },
            seconds        => 0.5,
            send           => [ @sends ],
            out            => "$tmp/passive-$n.jsonl",
        });
        waitpid($pid, 0);
        return $rc;
    };

    $run_case->();
    is($Protocol::WebSocket::Client::WRITES, 0,
        'run_recorder: no --send means zero writes (passive is the default)');

    $run_case->('get_state');
    is($Protocol::WebSocket::Client::WRITES, 1, 'run_recorder: one --send spec means one write');
    is_deeply(
        decode_json($Protocol::WebSocket::Client::SENT[0]),
        { type => 'command', command => 'get_state' },
        'run_recorder: the single write is the built get_state command'
    );

    $run_case->('get_auth_state', 'get_queue');
    is($Protocol::WebSocket::Client::WRITES, 2, 'run_recorder: two --send specs mean two writes');
    my @commands = map { decode_json($_)->{command} } @Protocol::WebSocket::Client::SENT;
    is_deeply(\@commands, ['get_auth_state', 'get_queue'],
        'run_recorder: writes preserve --send order');
};

# ============================================================
# Mock Protocol::WebSocket::Client stand-in that never fires the 'connect'
# callback -- simulates a WS handshake that never completes, for the
# handshake-timeout subtest below. Not registered in %INC (only used via
# an explicit client_factory closure, never looked up by module name).
# ============================================================
package Test::StuckWSClient;

sub new         { my ($class, %args) = @_; return bless { cb => {} }, $class; }
sub on          { my ($self, %cb) = @_; $self->{cb}{$_} = $cb{$_} for keys %cb; return $self; }
sub connect     { return $_[0]; }   # deliberately never invokes the 'connect' callback
sub read        { return $_[0]; }
sub write       { return $_[0]; }
sub is_ready    { return 0; }
sub disconnect  { return $_[0]; }
sub pong        { return $_[0]; }

package main;

# ============================================================
# handshake-timeout -- 81-REVIEW.md WR-03: run_recorder()'s handshake
# deadline was computed but never enforced, so a daemon that never
# completes the WS handshake (and no --seconds given) would hang
# run_recorder() forever. handshake_timeout_s is an additive test hook
# (same convention as client_factory/sock) letting this subtest exercise
# the real 5s default's enforcement logic without waiting 5 real seconds.
# ============================================================
subtest 'handshake-timeout' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die "socketpair: $!";
    # Deliberately never close or write to $b -- the socket stays open and
    # silent, so run_recorder's select loop never sees EOF or data; only
    # the handshake-timeout branch can end the run.
    my $out_file = "$tmp/handshake-timeout.jsonl";

    my $rc = run_recorder({
        host               => '127.0.0.1',
        sock               => $a,
        client_factory     => sub { Test::StuckWSClient->new(@_) },
        handshake_timeout_s => 0.2,
        out                => $out_file,
    });
    close($b);

    is($rc, 2, 'run_recorder: returns exit code 2 when the handshake never completes');

    open(my $fh, '<', $out_file) or die "cannot read $out_file: $!";
    local $/;
    my @lines = grep { length } split /\n/, <$fh>;
    close($fh);

    ok((grep { decode_json($_)->{frame} eq 'HANDSHAKE-TIMEOUT' } @lines),
        'run_recorder: writes a HANDSHAKE-TIMEOUT meta line before closing');
    ok(-s $out_file,
        'run_recorder: the timeout exits through close($out_fh) (CR-02: flush-on-close, not a bare exit)');
};

# ============================================================
# uri -- validate_uri($uri) + build_command($spec) (SoloistWS.pm:333
# validation, T-81-04 URI-Schmuggel mitigation).
# ============================================================
subtest 'uri' => sub {
    ok(validate_uri('spotify:track:4uLU6hMCjMI75M1A2tKUQC'), 'validate_uri: a track uri is accepted');
    ok(validate_uri('spotify:episode:abc123'),                'validate_uri: an episode uri is accepted');

    ok(!validate_uri('spotify:playlist:37i9dQZF1DX'), 'validate_uri: a playlist uri is rejected');
    ok(!validate_uri('spotify:album:x'),               'validate_uri: an album uri is rejected');
    ok(!validate_uri('spotify:track:'),                'validate_uri: an empty id is rejected');
    ok(!validate_uri('spotify:track:abc def'),         'validate_uri: an embedded space is rejected');
    ok(!validate_uri("spotify:track:abc\n"),
        'validate_uri: a trailing newline is rejected (81-02 hardening: $ matches before \\n in Perl)');

    is(build_command('play:spotify:album:x'), undef,
        'build_command: play with a non-track/episode uri is refused');

    my $play = decode_json(build_command('play:spotify:track:abc'));
    is($play->{command}, 'play',                  'build_command: play command name');
    is($play->{uri}, 'spotify:track:abc',          'build_command: play uri is preserved');

    like(build_command('seek:12345'), qr/"position_ms":12345[,}]/,
        'build_command: seek position_ms is a bare JSON number, not a string');
    like(build_command('set_volume:50'), qr/"volume":50[,}]/,
        'build_command: set_volume volume is a bare JSON number');

    my $raw = '{"type":"command","command":"get_state"}';
    is(build_command($raw), $raw, 'build_command: raw JSON passes through unchanged');

    is(build_command('explode'), undef, 'build_command: an unknown verb is rejected');
};

# ============================================================
# device -- check_device($frame_hash, $expected): fail-closed comparison
# (T-81-01: a stale ws.port can point at a foreign process).
# ============================================================
subtest 'device' => sub {
    is(check_device({ type => 'auth_state', device_name => 'lavender-UAT' }, 'lavender-UAT'), 1,
        'check_device: a matching device_name is accepted');
    is(check_device({ type => 'auth_state', device_name => 'lavender-UAT' }, 'lavender-pa'), 0,
        'check_device: a mismatched device_name is rejected');
    is(check_device({ type => 'auth_state', device_name => 'lavender-UAT' }), 0,
        'check_device: no expected device given is fail-closed');
};

# ============================================================
# build_lms_request -- 82-38 Task 1, Test 1: pure function, no socket.
# LMS requires the NESTED params form [$playerid, \@cmd]
# (Slim::Web::JSONRPC.pm:219 checks ref($params->[1])) -- a flat params
# array silently executes nothing.
# ============================================================
subtest 'build_lms_request' => sub {
    my $bytes = build_lms_request('http://127.0.0.1:9000/jsonrpc.js', '02:00:00:5a:11:01', ['play']);

    like($bytes, qr{\APOST /jsonrpc\.js HTTP/1\.1\r\n}, 'build_lms_request: POST line with path parsed from the URL');
    like($bytes, qr{Host: 127\.0\.0\.1\r\n}, 'build_lms_request: Host header parsed from the URL');
    like($bytes, qr{Content-Type: application/json\r\n}, 'build_lms_request: Content-Type header present');

    my ($header, $body) = split(/\r\n\r\n/, $bytes, 2);
    my ($cl) = $header =~ /Content-Length:\s*(\d+)/i;
    ok(defined $cl, 'build_lms_request: Content-Length header present');
    is(length($body), $cl, 'build_lms_request: Content-Length matches the actual body length');

    my $decoded = decode_json($body);
    is($decoded->{id}, 1, 'build_lms_request: id field is 1');
    is($decoded->{method}, 'slim.request', 'build_lms_request: method field is slim.request');
    is_deeply($decoded->{params}, ['02:00:00:5a:11:01', ['play']],
        'build_lms_request: params is the NESTED [playerid, cmd-array] form LMS requires');

    my $bytes_no_path = build_lms_request('http://127.0.0.1:9000', '', ['serverstatus', '0', '1']);
    like($bytes_no_path, qr{\APOST / HTTP/1\.1\r\n}, 'build_lms_request: a URL with no path defaults to /');
};

# ============================================================
# parse_lms_response -- 82-38 Task 1, Test 2: never dies on broken/
# incomplete bytes; the three-way distinction lms-cmd.sh already makes
# (empty body, connection closed without bytes, response without a
# result field) are all reported as invalid, never a crash.
# ============================================================
subtest 'parse_lms_response' => sub {
    my $good = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"
             . encode_json({ id => 1, result => { mode => 'play' } });
    my $parsed = parse_lms_response($good);
    is($parsed->{ok}, 1, 'parse_lms_response: a full response with a result field is valid');
    is_deeply($parsed->{result}, { mode => 'play' }, 'parse_lms_response: the result payload is preserved');

    my $empty = parse_lms_response('');
    is($empty->{ok}, 0, 'parse_lms_response: empty bytes are invalid');
    like($empty->{reason}, qr/empty/i, 'parse_lms_response: reason names the empty response');

    is(parse_lms_response(undef)->{ok}, 0, 'parse_lms_response: undef bytes are invalid, not a crash');

    my $no_result = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n" . encode_json({ id => 1 });
    my $nr = parse_lms_response($no_result);
    is($nr->{ok}, 0, 'parse_lms_response: a response without a result field is invalid');
    like($nr->{reason}, qr/result/i, 'parse_lms_response: reason names the missing result field');

    my $broken = parse_lms_response("garbage bytes with no header/body separator at all");
    is($broken->{ok}, 0, 'parse_lms_response: broken/incomplete bytes never die, just report invalid');

    my $bad_json = parse_lms_response("HTTP/1.1 200 OK\r\n\r\nnot json at all");
    is($bad_json->{ok}, 0, 'parse_lms_response: a non-JSON body is invalid, not a crash');
};

# ============================================================
# reannounce-lms-passive -- 82-38 Task 1, Test 3 (integration level): the
# new lms_sock test hook (additive to sock/client_factory, 81-02
# convention) is injected, but --reannounce-lms is deliberately left
# UNSET. Passive-mode preservation (D-15/T-81-03, T-82-38A) is checked
# mechanically: no bytes ever arrive on the OTHER half of the lms_sock
# socketpair for the entire test run -- run_recorder must never call
# syswrite() on lms_sock unless reannounce_lms is explicitly set.
# ============================================================
subtest 'reannounce-lms-passive' => sub {
    my $tmp = tempdir(CLEANUP => 1);

    socketpair(my $daemon_a, my $daemon_b, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die "socketpair (daemon): $!";
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        close($daemon_a);
        select(undef, undef, undef, 0.3);
        close($daemon_b);
        exit(0);
    }
    close($daemon_b);

    socketpair(my $lms_a, my $lms_b, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die "socketpair (lms): $!";

    my $rc = run_recorder({
        host           => '127.0.0.1',
        sock           => $daemon_a,
        client_factory => sub { Protocol::WebSocket::Client->new(@_) },
        lms_sock       => $lms_a,
        seconds        => 0.5,
        out            => "$tmp/reannounce-lms-passive.jsonl",
    });
    waitpid($pid, 0);

    is($rc, 0, 'run_recorder: exits 0 with lms_sock injected but --reannounce-lms unset');

    $lms_b->blocking(0);
    my $peer_bytes = '';
    while (1) {
        my $n = sysread($lms_b, my $buf, 65536);
        last unless defined $n && $n > 0;
        $peer_bytes .= $buf;
    }
    is($peer_bytes, '',
        'run_recorder: without --reannounce-lms, zero bytes are ever written to lms_sock (T-82-38A opt-in preserved)');
};

# ============================================================
# reannounce-lms-active -- 82-41 Task 2 (Code-Review Runde 9 WR-01/WR-02).
# Mirrors reannounce-lms-passive's socketpair/fork setup, but WITH
# reannounce_lms actually SET, closing two gaps:
#
#   Test D (R9-WR-01): the 48-line send branch
#   (tools/soloist-ws-record.pl:579-626) had NO positive test -- a
#   reviewer could delete the whole block and t/43 stayed green. This
#   proves bytes actually land on the LMS peer socket.
#
#   Test E (R9-WR-02): the connect-callback's synchronous up-to-2s LMS
#   response read shifts the callback's own return time by at least the
#   LMS response latency -- mechanically proven via a wall-clock delta
#   between an immediate-response run (E1) and a 0.3s-delayed-response run
#   (E2), each with its own, non-reused socketpair/process instances.
#   Single-threaded Perl: no subsequent daemon frame can be read/rx-
#   stamped before this callback returns, so this delta IS the mechanism
#   R9-WR-02 names as the JSONL rx-timestamp shift's cause.
# ============================================================
subtest 'reannounce-lms-active' => sub {
    my $tmp = tempdir(CLEANUP => 1);

    # ---- Test D: positive proof the send branch actually sends ----
    socketpair(my $daemon_a, my $daemon_b, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die "socketpair (daemon, Test D): $!";
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        close($daemon_a);
        select(undef, undef, undef, 0.3);
        close($daemon_b);
        exit(0);
    }
    close($daemon_b);

    socketpair(my $lms_a, my $lms_b, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die "socketpair (lms, Test D): $!";

    my $rc = run_recorder({
        host           => '127.0.0.1',
        sock           => $daemon_a,
        client_factory => sub { Protocol::WebSocket::Client->new(@_) },
        lms_sock       => $lms_a,
        reannounce_lms => encode_json(['02:00:00:5a:11:01', 'play']),
        seconds        => 0.5,
        out            => "$tmp/reannounce-lms-active-D.jsonl",
    });
    waitpid($pid, 0);

    is($rc, 0, 'reannounce-lms-active: Test D run_recorder exits 0 with reannounce_lms set');

    $lms_b->blocking(0);
    my $peer_bytes = '';
    while (1) {
        my $n = sysread($lms_b, my $buf, 65536);
        last unless defined $n && $n > 0;
        $peer_bytes .= $buf;
    }
    ok(length($peer_bytes) > 0,
        'reannounce-lms-active: Test D bytes actually arrive on the LMS peer socket when reannounce_lms is set (R9-WR-01 positive proof)');
    like($peer_bytes, qr/POST/i,
        'reannounce-lms-active: Test D bytes look like an HTTP POST request');
    like($peer_bytes, qr/jsonrpc/i,
        'reannounce-lms-active: Test D bytes reference the jsonrpc endpoint');

    # ---- Test E: mechanical proof of the rx-timestamp shift ----
    # E1 (comparison value, immediate response): the minimal valid HTTP
    # response is written to lms_b1 BEFORE run_recorder is even called --
    # the socketpair kernel buffer holds the bytes, no timing race needed.
    # daemon_b1 is ALSO closed synchronously before the call (no fork, no
    # delay), so the main loop's first sysread on daemon_a1 sees EOF
    # essentially immediately once the connect callback returns. Only the
    # run_recorder() call itself is timed.
    socketpair(my $daemon_a1, my $daemon_b1, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die "socketpair (daemon, Test E1): $!";
    close($daemon_b1);

    # lms_b1 MUST stay open through the run_recorder() call below: the
    # connect callback first WRITES the outgoing reannounce request to
    # lms_sock (lms_a1) BEFORE it reads the response -- closing the peer
    # (lms_b1) beforehand would make that write hit a closed peer and
    # raise SIGPIPE in THIS process (run_recorder runs in-process, not
    # forked). The response bytes are still pre-buffered in the kernel
    # before the call, so the read half of the race is still eliminated.
    socketpair(my $lms_a1, my $lms_b1, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die "socketpair (lms, Test E1): $!";
    my $http_response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}";
    syswrite($lms_b1, $http_response, length($http_response));

    my $t_e1_start = Time::HiRes::time();
    my $rc_e1 = run_recorder({
        host           => '127.0.0.1',
        sock           => $daemon_a1,
        client_factory => sub { Protocol::WebSocket::Client->new(@_) },
        lms_sock       => $lms_a1,
        reannounce_lms => encode_json(['02:00:00:5a:11:01', 'play']),
        seconds        => 0.5,
        out            => "$tmp/reannounce-lms-active-E1.jsonl",
    });
    my $duration_e1 = Time::HiRes::time() - $t_e1_start;
    close($lms_b1);
    is($rc_e1, 0, 'reannounce-lms-active: Test E1 (sofortige Antwort) run_recorder exits 0');

    # E2 (positive probe, 0.3s-delayed response): a SEPARATE fork holds
    # lms_b2 (mirrors the existing daemon_a/daemon_b fork pattern above,
    # applied here to lms_a/lms_b and to WRITING instead of closing) --
    # the parent process cannot both call run_recorder (which blocks
    # synchronously inside the connect callback) AND write the delayed
    # response itself, so a child process must hold the write side.
    # daemon_b2 is closed synchronously immediately, same as E1,
    # independent of the lms fork's timing.
    socketpair(my $daemon_a2, my $daemon_b2, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die "socketpair (daemon, Test E2): $!";
    close($daemon_b2);

    socketpair(my $lms_a2, my $lms_b2, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die "socketpair (lms, Test E2): $!";
    my $lms_pid = fork();
    die "fork failed (lms writer, Test E2): $!" unless defined $lms_pid;
    if ($lms_pid == 0) {
        close($lms_a2);
        select(undef, undef, undef, 0.3);
        syswrite($lms_b2, $http_response, length($http_response));
        close($lms_b2);
        exit(0);
    }
    close($lms_b2);

    my $t_e2_start = Time::HiRes::time();
    my $rc_e2 = run_recorder({
        host           => '127.0.0.1',
        sock           => $daemon_a2,
        client_factory => sub { Protocol::WebSocket::Client->new(@_) },
        lms_sock       => $lms_a2,
        reannounce_lms => encode_json(['02:00:00:5a:11:01', 'play']),
        seconds        => 0.5,
        out            => "$tmp/reannounce-lms-active-E2.jsonl",
    });
    my $duration_e2 = Time::HiRes::time() - $t_e2_start;
    waitpid($lms_pid, 0);
    is($rc_e2, 0, 'reannounce-lms-active: Test E2 (verzoegerte Antwort) run_recorder exits 0');

    diag(sprintf('reannounce-lms-active: rx-Verschiebung E1=%.3fs E2=%.3fs delta=%.3fs',
        $duration_e1, $duration_e2, $duration_e2 - $duration_e1));

    cmp_ok($duration_e1, '<', 0.25,
        'reannounce-lms-active: Test E1 ohne injizierte Verzoegerung bleibt schnell (Negativprobe)');
    cmp_ok($duration_e2 - $duration_e1, '>=', 0.25,
        'reannounce-lms-active: Test E rx-Verschiebung -- die 0.3s-LMS-Antwortverzoegerung schiebt die Rueckkehr des connect-Callbacks um mindestens ~250ms nach hinten (R9-WR-02, mechanischer Beleg)');
};

done_testing();

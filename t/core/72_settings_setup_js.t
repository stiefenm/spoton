#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempfile);
use Cwd qw(abs_path);
use JSON::PP;

# ============================================================
# 79-39 (D-32): the settings-page setup JS and its template structure.
#
# F3 (slim scope, user: "Schlank: nur 'bereit' (Empfohlen)"): while the red
# "Soloist binary not found" line shows under a saved soloist backend, the
# block `soloist-binary-js` polls the existing GET route
# plugins/SpotOn/settings/soloistRenewStatus and reads its existing
# `active_version` field. A version turns the line to the non-red ready text
# (or the orange key-missing text) and stops the poll. No downloading state,
# no error state, no progress bar.
#
# The JS block between the BEGIN and END markers is extracted from
# basic.html and executed under Node with a fake XMLHttpRequest and fake
# timers, so the changed template is what gets tested, not a copy.
# ============================================================

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";
my $html_file   = "$project_dir/Plugins/SpotOn/HTML/EN/plugins/SpotOn/settings/basic.html";
die "basic.html not found (never skip)\n" unless -f $html_file;

# 79-43 (D-33 79-REVIEW WR-02): without Node the whole file is a skip, as in t/core/42 and t/core/65, so the
# expected-skip lists of perl-tests.yml and amp-leg.sh see it. Before, the Node cases skipped inside SKIP
# blocks and the file reported ok while none of its behaviour checks ran.
my $node = `which node 2>/dev/null`;
chomp $node;
plan skip_all => 'node not available in this environment' unless $node;

open(my $fh, '<:encoding(UTF-8)', $html_file) or die "Cannot open basic.html: $!";
my $html = do { local $/; <$fh> };
close($fh);

# ------------------------------------------------------------
# Static: the F3 status line
# ------------------------------------------------------------
{
    my ($line) = $html =~ m{(<div id="soloist-binary-line".*?</div>)}s;
    ok(defined $line, 'F3 static: the status line is wrapped in div#soloist-binary-line');
    $line //= '';

    my ($open) = $line =~ m{^(<div id="soloist-binary-line"[^>]*>)}s;
    $open //= '';
    like($open,
        qr{data-poll="\[%\s*IF\s+backend\s*==\s*'soloist'\s*&&\s*soloistMissing\s*&&\s*!soloistUnsupportedOS\s*%\]1\[%\s*ELSE\s*%\]0\[%\s*END\s*%\]"},
        'F3 static: data-poll is 1 only under backend soloist && soloistMissing && !soloistUnsupportedOS');
    like($open, qr{data-ready-text="\[%\s*'PLUGIN_SPOTON_SOLOIST_STATUS'\s*\|\s*string\s*\|\s*html\s*%\]"},
        'F3 static: data-ready-text reuses PLUGIN_SPOTON_SOLOIST_STATUS with | string | html');
    like($open, qr{data-key-missing-text="\[%\s*'PLUGIN_SPOTON_SOLOIST_KEY_MISSING'\s*\|\s*string\s*\|\s*html\s*%\]"},
        'F3 static: data-key-missing-text reuses PLUGIN_SPOTON_SOLOIST_KEY_MISSING with | string | html');
    like($open, qr{data-key-missing="\[%\s*IF\s+soloistKeyMissing\s*%\]1\[%\s*ELSE\s*%\]0\[%\s*END\s*%\]"},
        'F3 static: data-key-missing carries soloistKeyMissing as 1/0');

    my @spans = $line =~ m{(<span\b[^>]*>)}g;
    is(scalar @spans, 4, 'F3 static: the four status branches are kept');
    my @ids    = grep { m{id="soloist-binary-status"} } @spans;
    is(scalar @ids, 4, 'F3 static: every branch span carries id="soloist-binary-status"');
    my @states = map { m{data-state="([^"]*)"} ? $1 : '' } @spans;
    is_deeply(\@states, [qw(unsupported missing ready ready)],
        'F3 static: data-state per branch is unsupported, missing, ready (key missing), ready');
    my @colors = map { m{color:\s*(\w+)} ? $1 : '' } @spans;
    is_deeply(\@colors, [qw(red red orange green)], 'F3 static: the four branch colors are unchanged');
    like($line, qr{'PLUGIN_SPOTON_SOLOIST_BINARY_MISSING'\s*\|\s*string}, 'F3 static: the missing text is unchanged');
}

# ------------------------------------------------------------
# Node: block soloist-binary-js
# ------------------------------------------------------------
my ($js) = $html =~ m{// BEGIN soloist-binary-js\n(.*?)// END soloist-binary-js}s;
ok(defined $js && length $js, 'F3 node: extracted the soloist-binary-js block from basic.html');
if (defined $js) {
    unlike($js, qr{spotonSoloistPollTimer}, 'F3 node: the block keeps its own timer, separate from spotonSoloistPollTimer');
    unlike($js, qr{innerHTML}, 'F3 node: the block never touches innerHTML');
}

SKIP: {
    skip 'soloist-binary-js block missing, Node cases cannot run', 1 unless defined $js;

    my $harness = <<'NODE_HARNESS';
var timers = [];            // {id, fn, ms, live}
var nextTimer = 1;
function fakeSetTimeout(fn, ms) { var t = {id: nextTimer++, fn: fn, ms: ms, live: true}; timers.push(t); return t.id; }
function fakeClearTimeout(id) { timers.forEach(function(t) { if (t.id === id) { t.live = false; } }); }
function liveTimers() { return timers.filter(function(t) { return t.live; }); }
function fire() { var l = liveTimers(); if (!l.length) { return null; } var t = l[0]; t.live = false; t.fn(); return t.ms; }

var requests = [];
function FakeXHR() {
    var self = this;
    self.headers = {};
    self.open = function(m, u) { self.method = m; self.url = u; };
    self.setRequestHeader = function(k, v) { self.headers[k] = v; };
    self.send = function(body) { self.body = body; requests.push(self); };
    self.reply = function(status, bodyObj) {
        self.status = status;
        self.responseText = (typeof bodyObj === 'string') ? bodyObj : JSON.stringify(bodyObj);
        if (self.onload) { self.onload(); }
    };
    self.fail = function() { if (self.onerror) { self.onerror(); } };
    self.timeoutFire = function() { if (self.ontimeout) { self.ontimeout(); } };   // 79-43 R4
}
function last() { return requests[requests.length - 1]; }

var els = {}, innerHtmlWrites = 0;
function mkEl(id, extra) {
    var e = { id: id, style: {}, textContent: '', dataset: {} };
    Object.defineProperty(e, 'innerHTML', { get: function() { return ''; }, set: function() { innerHtmlWrites++; } });
    for (var k in (extra || {})) { e[k] = extra[k]; }
    els[id] = e;
    return e;
}
var doc = { getElementById: function(id) { return els[id] || null; } };

function load(opts) {
    timers = []; requests = []; els = {};
    if (!opts.noLine) {
        mkEl('soloist-binary-line', { dataset: { poll: opts.poll, readyText: 'READY',
            keyMissingText: 'KEYMISSING', keyMissing: opts.keyMissing || '0' } });
        mkEl('soloist-binary-status', { textContent: '\u25CF MISSING', style: { color: 'red' },
            dataset: { state: 'missing' } });
    }
    var threw = null;
    try {
        (new Function('window', 'document', 'XMLHttpRequest', 'setTimeout', 'clearTimeout', CODE))
            ({}, doc, FakeXHR, fakeSetTimeout, fakeClearTimeout);
    } catch (e) { threw = String(e); }
    return threw;
}
function st() {
    var s = els['soloist-binary-status'];
    return s ? { text: s.textContent, color: s.style.color, state: s.dataset.state } : null;
}
var CODE = EXTRACTED_JS_LITERAL;
var R = {};

// 1. null, null, then a version -> ready text in green, poll stops
R.a_threw = load({ poll: '1' });
R.a_first = { n: requests.length, method: last() && last().method, url: last() && last().url,
              xrw: last() && last().headers['X-Requested-With'] };
last().reply(200, { active_version: null, renewal: null });
R.a_afterNull1 = st(); R.a_timerMs = liveTimers().length ? liveTimers()[0].ms : null;
fire();
last().reply(200, { active_version: null });
R.a_afterNull2 = st();
fire();
R.a_n3 = requests.length;
last().reply(200, { active_version: '1.3.8.105' });
R.a_afterVersion = st(); R.a_liveAfter = liveTimers().length; R.a_nAfter = requests.length;

// 2. a version with data-key-missing=1 -> orange key-missing text, stops
load({ poll: '1', keyMissing: '1' });
last().reply(200, { active_version: '1.3.8.105' });
R.b = st(); R.b_live = liveTimers().length;

// 3. 79-43 (D-33 79-REVIEW WR-01): non-200, unparsable, network error and timeout keep the red text AND
//    schedule exactly one next poll in 5000 ms (the chain survives a transport hiccup inside its cap)
function liveMs() { return liveTimers().map(function(t) { return t.ms; }).join(','); }
load({ poll: '1' });
last().reply(500, 'oops');
R.c500 = st(); R.c500_live = liveTimers().length; R.c500_ms = liveMs();
load({ poll: '1' });
last().reply(200, 'not json {');
R.cBad = st(); R.cBad_live = liveTimers().length; R.cBad_ms = liveMs();
load({ poll: '1' });
last().fail();
R.cErr = st(); R.cErr_live = liveTimers().length; R.cErr_ms = liveMs();
load({ poll: '1' });
R.cTo_timeout = last().timeout;
last().timeoutFire();
R.cTo = st(); R.cTo_live = liveTimers().length; R.cTo_ms = liveMs();

// 3b. 79-43 R5: a failed poll at elapsedMs 595000 schedules one more; the poll at 600000 sends nothing
timers = []; requests = []; els = {};
mkEl('soloist-binary-line', { dataset: { poll: '0', readyText: 'READY', keyMissingText: 'KEYMISSING', keyMissing: '0' } });
mkEl('soloist-binary-status', { textContent: '\u25CF MISSING', style: { color: 'red' }, dataset: { state: 'missing' } });
var pollFn = (new Function('window', 'document', 'XMLHttpRequest', 'setTimeout', 'clearTimeout',
    CODE + '\n return spotonSoloistBinaryPoll;'))({}, doc, FakeXHR, fakeSetTimeout, fakeClearTimeout);
pollFn(595000);
R.g_n1 = requests.length;
last().reply(500, 'oops');
R.g_live1 = liveTimers().length; R.g_ms1 = liveMs();
fire();
R.g_n2 = requests.length; R.g_live2 = liveTimers().length;

// 4. data-poll=0 sends nothing
load({ poll: '0' });
R.d = { n: requests.length, live: liveTimers().length, st: st() };

// 5. the 600000 ms cap with only null answers
load({ poll: '1' });
var simMs = 0, guard = 0;
while (guard++ < 1000) {
    var r = last();
    if (r && r.status === undefined) { r.reply(200, { active_version: null }); }
    var ms = fire();
    if (ms === null) { break; }
    simMs += ms;
}
R.e = { n: requests.length, simMs: simMs, live: liveTimers().length, st: st(), guard: guard };

// 6. no line element -> nothing thrown, nothing sent
R.f_threw = load({ noLine: true });
R.f_n = requests.length;

R.innerHtmlWrites = innerHtmlWrites;
console.log(JSON.stringify(R));
NODE_HARNESS

    my $js_lit = JSON::PP->new->allow_nonref->ascii->encode($js);
    $harness =~ s/EXTRACTED_JS_LITERAL/$js_lit/;

    my ($tmp_fh, $script_path) = tempfile('setup_js_XXXXXX', SUFFIX => '.js', TMPDIR => 1, UNLINK => 1);
    print $tmp_fh $harness;
    close($tmp_fh);

    my $out = `node "$script_path" 2>&1`;
    my $node_exit = $? >> 8;
    is($node_exit, 0, 'F3 node: soloist-binary-js executed under Node without error') or diag("Node output: $out");
    my $r = $node_exit == 0 ? eval { JSON::PP::decode_json($out) } : undef;
    ok($r, 'F3 node: result is JSON') or diag($out);
    $r ||= {};

    my $dot = "\x{25CF} ";
    is($r->{a_threw}, undef, 'F3 node: loading the block with data-poll=1 throws nothing');
    is($r->{a_first}{n}, 1, 'F3 node: data-poll=1 sends the first request at load');
    is($r->{a_first}{method}, 'GET', 'F3 node: the poll is a GET');
    is($r->{a_first}{url}, '/plugins/SpotOn/settings/soloistRenewStatus', 'F3 node: the poll reads the existing soloistRenewStatus route');
    is($r->{a_first}{xrw}, 'XMLHttpRequest', 'F3 node: the poll sends X-Requested-With');
    is($r->{a_timerMs}, 5000, 'F3 node: a null active_version schedules the next poll in 5000 ms');
    is($r->{a_afterNull1}{text}, "${dot}MISSING", 'F3 node: the first null answer keeps the red missing text');
    is($r->{a_afterNull2}{color}, 'red', 'F3 node: the second null answer keeps the line red');
    is($r->{a_n3}, 3, 'F3 node: the third poll was sent after two null answers');
    is($r->{a_afterVersion}{text}, "${dot}READY 1.3.8.105", 'F3 node: a version turns the line to "<ready text> <version>"');
    is($r->{a_afterVersion}{color}, 'green', 'F3 node: the ready line is green');
    is($r->{a_afterVersion}{state}, 'ready', 'F3 node: the ready line carries data-state ready');
    is($r->{a_liveAfter}, 0, 'F3 node: no further poll is scheduled after a version');

    is($r->{b}{text}, "${dot}KEYMISSING", 'F3 node: a version with data-key-missing=1 shows the key-missing text');
    is($r->{b}{color}, 'orange', 'F3 node: the key-missing line is orange');
    is($r->{b_live}, 0, 'F3 node: the key-missing case stops the poll');

    # 79-43 (D-33 79-REVIEW WR-01): the three stop assertions flipped - a failed status request keeps polling
    is($r->{c500}{text}, "${dot}MISSING", 'F3 node: a non-200 answer leaves the red text');
    is(($r->{c500_live} // 'undef') . '@' . ($r->{c500_ms} // ''), '1@5000', '79-43 R1: a non-200 answer schedules exactly one next poll in 5000 ms');
    is($r->{cBad}{text}, "${dot}MISSING", 'F3 node: an unparsable answer leaves the red text');
    is(($r->{cBad_live} // 'undef') . '@' . ($r->{cBad_ms} // ''), '1@5000', '79-43 R2: an unparsable answer schedules exactly one next poll in 5000 ms');
    is($r->{cErr}{text}, "${dot}MISSING", '79-43 R3: a network error leaves the red text');
    is(($r->{cErr_live} // 'undef') . '@' . ($r->{cErr_ms} // ''), '1@5000', '79-43 R3: a network error schedules exactly one next poll in 5000 ms');
    is($r->{cTo_timeout}, 4000, '79-43 R4: the status request carries xhr.timeout 4000');
    is($r->{cTo}{text}, "${dot}MISSING", '79-43 R4: a timeout leaves the red text');
    is(($r->{cTo_live} // 'undef') . '@' . ($r->{cTo_ms} // ''), '1@5000', '79-43 R4: a timeout schedules exactly one next poll in 5000 ms');
    is(join('/', map { $_ // 'undef' } @{$r}{qw(g_n1 g_live1 g_ms1)}), '1/1/5000', '79-43 R5: a failed poll at elapsedMs 595000 schedules one more');
    is(join('/', map { $_ // 'undef' } @{$r}{qw(g_n2 g_live2)}), '1/0', '79-43 R5: the poll at 600000 sends nothing and schedules nothing');

    is($r->{d}{n}, 0, 'F3 node: data-poll=0 sends nothing');
    is($r->{d}{live}, 0, 'F3 node: data-poll=0 schedules nothing');

    is($r->{e}{live}, 0, 'F3 node: after the cap no further poll is scheduled');
    cmp_ok($r->{e}{simMs} // 0, '>=', 595000, 'F3 node: the poll ran for the whole 600000 ms window');
    cmp_ok($r->{e}{simMs} // 1e9, '<=', 600000, 'F3 node: the poll never runs past 600000 ms');
    cmp_ok($r->{e}{n} // 0, '<=', 121, 'F3 node: the capped poll sent at most 121 requests');
    is($r->{e}{st}{text}, "${dot}MISSING", 'F3 node: after the cap the red text stays');

    is($r->{f_threw}, undef, 'F3 node: a page without the line throws nothing');
    is($r->{f_n}, 0, 'F3 node: a page without the line sends nothing');
    is($r->{innerHtmlWrites}, 0, 'F3 node: text is written through textContent only');
}

# ============================================================
# 79-39 Task 3 (D-32 F2): once an account is paired, step 1 shows
# "Gekoppelt: <names>" and keeps "Weiteres Konto koppeln" as a small link
# that opens the unchanged pairing flow; under Soloist with every player
# paired, step 2 keeps the table and hides the how-to behind
# "Weiteren Player koppeln".
# ============================================================
{
    my $a0 = index($html, '<h3 id="spoton-step-account"');
    my $p0 = index($html, '<h3 id="spoton-step-player"');
    my $step1 = ($a0 >= 0 && $p0 > $a0) ? substr($html, $a0, $p0 - $a0) : '';
    ok(length $step1, 'F2 static: found the step-1 region');

    my $ifRe = qr{\[%\s*IF\s+accountStepOk\s*&&\s*!needsPairingAccounts\.size\s*%\]};
    my $i0 = $step1 =~ $ifRe ? $-[0] : -1;
    ok($i0 >= 0, 'F2 static: step 1 has [% IF accountStepOk && !needsPairingAccounts.size %]');
    my $hidden = index($step1, '<div id="account-pair-flow" style="display:none">');
    ok($i0 >= 0 && $hidden > $i0, 'F2 static: the paired branch opens div#account-pair-flow with display:none');
    my $paired = ($i0 >= 0 && $hidden > $i0) ? substr($step1, $i0, $hidden - $i0) : '';
    like($paired, qr{id="account-paired"}, 'F2 static: the paired branch has id="account-paired"');
    like($paired, qr{'PLUGIN_SPOTON_ACCOUNT_PAIRED'\s*\|\s*string}, 'F2 static: the paired line shows PLUGIN_SPOTON_ACCOUNT_PAIRED');
    like($paired, qr{&#9679;}, 'F2 static: the paired line carries the &#9679; dot');
    like($paired, qr{\[%\s*FOREACH\s+(\w+)\s+IN\s+pairedAccounts\s*%\].*?accounts\.\$\1\.displayName\s*\|\s*html}s,
        'F2 static: the paired line loops over pairedAccounts with displayName | html');
    like($paired, qr{<a\b[^>]*id="accountPairAnotherLink"[^>]*onclick="spotonAccountPairShow\(\); return false;"}s,
        'F2 static: the small link accountPairAnotherLink calls spotonAccountPairShow()');
    like($paired, qr{font-size:\s*0\.85em[^>]*>\s*<a\b[^>]*id="accountPairAnotherLink"}s,
        'F2 static: the link sits in a 0.85em line (small secondary action)');
    like($paired, qr{'PLUGIN_SPOTON_ACCOUNT_PAIR_ANOTHER'\s*\|\s*string}, 'F2 static: the link text is PLUGIN_SPOTON_ACCOUNT_PAIR_ANOTHER');
    like($step1,
        qr{<div id="account-pair-flow" style="display:none">\s*\[%\s*ELSE\s*%\]\s*<div id="account-pair-flow" style="display:block">\s*\[%\s*END\s*%\]},
        'F2 static: the ELSE branch opens the same flow id with display:block');

    my $disc = index($step1, 'discover-invalid');
    ok($disc >= 0 && $i0 > $disc, 'F2 static: the paired branch sits below the discover lines');

    my $blk = index($step1, '<div id="account-pair-flow" style="display:block">');
    my $np  = index($step1, '[% FOREACH id IN needsPairingAccounts');
    ok($blk >= 0 && $np > $blk, 'F2 static: the needs-pairing lines stay below the flow');
    my $flow = ($blk >= 0 && $np > $blk) ? substr($step1, $blk, $np - $blk) : '';
    for my $need ("'PLUGIN_SPOTON_PLAYER_AUTH_INSTRUCTIONS'", 'pairingDeviceName | html', 'id="accountPairStartBtn"',
                  'id="playerAuthCancelBtn"', 'id="account-pair-countdown"', 'id="player-auth-status"') {
        ok(index($flow, $need) >= 0, "F2 static: the flow holds $need");
    }
    like($flow, qr{</div>\s*$}s, 'F2 static: the flow div is closed before the needs-pairing lines');

    my $h0 = index($html, '<hr', $p0);
    my $step2 = ($p0 >= 0 && $h0 > $p0) ? substr($html, $p0, $h0 - $p0) : '';
    my ($pairedBr, $elseBr) = $step2 =~
        m{\[%\s*IF\s+playerStepOk\s*&&\s*soloistPlayers\.size\s*%\](.*?)\[%\s*ELSE\s*%\](.*?)\[%\s*END\s*%\]}s;
    ok(defined $pairedBr, 'F2 static: step 2 has [% IF playerStepOk && soloistPlayers.size %] ... [% ELSE %]');
    $pairedBr //= '';
    $elseBr   //= '';
    like($pairedBr, qr{<a\b[^>]*id="soloistPairHowtoLink"[^>]*onclick="spotonSoloistPairHowtoShow\(\); return false;"}s,
        'F2 static: the paired branch has the link soloistPairHowtoLink calling spotonSoloistPairHowtoShow()');
    like($pairedBr, qr{'PLUGIN_SPOTON_SOLOIST_PAIR_ANOTHER'\s*\|\s*string}, 'F2 static: the link text is PLUGIN_SPOTON_SOLOIST_PAIR_ANOTHER');
    like($pairedBr, qr{<p id="soloist-pair-howto" style="display:none;[^"]*">\s*\[%\s*'PLUGIN_SPOTON_SOLOIST_PAIR_HOWTO'},
        'F2 static: the paired branch hides the how-to (display:none)');
    like($elseBr, qr{<p id="soloist-pair-howto" style="display:block;[^"]*">\s*\[%\s*'PLUGIN_SPOTON_SOLOIST_PAIR_HOWTO'},
        'F2 static: the else branch shows the how-to (display:block)');
    my $sol = index($step2, "[% IF backend == 'soloist' %]");
    my $tbl = index($step2, '<table');
    my $ifp = $step2 =~ m{\[%\s*IF\s+playerStepOk\s*&&\s*soloistPlayers\.size} ? $-[0] : -1;
    ok($sol >= 0 && $tbl > $sol && $ifp > $tbl, 'F2 static: the player table stays, above the how-to rule, in the soloist branch');
    like($step2, qr{\[%\s*ELSE\s*%\]\s*<p[^>]*>\s*\[%\s*'PLUGIN_SPOTON_STEP_PLAYER_NOT_NEEDED'}s,
        'F2 static: the librespot branch is unchanged');
}

# ---- Node: block setup-collapse-js ----
my ($cjs) = $html =~ m{// BEGIN setup-collapse-js\n(.*?)// END setup-collapse-js}s;
ok(defined $cjs && length $cjs, 'F2 node: extracted the setup-collapse-js block from basic.html');

SKIP: {
    skip 'setup-collapse-js block missing, Node cases cannot run', 1 unless defined $cjs;

    my $harness = <<'NODE_HARNESS';
var els = {};
function mkEl(id, display) { els[id] = { id: id, style: { display: display } }; return els[id]; }
var doc = { getElementById: function(id) { return els[id] || null; } };
var api = (new Function('document', CODE + '\n return { acc: spotonAccountPairShow, howto: spotonSoloistPairHowtoShow };'))(doc);
var R = {};
mkEl('account-pair-flow', 'none'); mkEl('accountPairAnotherLink', '');
mkEl('soloist-pair-howto', 'none'); mkEl('soloistPairHowtoLink', '');
api.acc();
R.acc = { flow: els['account-pair-flow'].style.display, link: els['accountPairAnotherLink'].style.display,
          howtoUntouched: els['soloist-pair-howto'].style.display };
api.howto();
R.howto = { howto: els['soloist-pair-howto'].style.display, link: els['soloistPairHowtoLink'].style.display };
els = {};
R.absent = null;
try { api.acc(); api.howto(); R.absent = 'ok'; } catch (e) { R.absent = String(e); }
console.log(JSON.stringify(R));
NODE_HARNESS
    my $lit = JSON::PP->new->allow_nonref->ascii->encode($cjs);
    $harness =~ s/\bCODE\b/$lit/;

    my ($tmp_fh, $script_path) = tempfile('collapse_js_XXXXXX', SUFFIX => '.js', TMPDIR => 1, UNLINK => 1);
    print $tmp_fh $harness;
    close($tmp_fh);
    my $out = `node "$script_path" 2>&1`;
    my $node_exit = $? >> 8;
    is($node_exit, 0, 'F2 node: setup-collapse-js executed under Node without error') or diag("Node output: $out");
    my $r = $node_exit == 0 ? eval { JSON::PP::decode_json($out) } : undef;
    $r ||= {};
    is($r->{acc}{flow}, 'block', 'F2 node: spotonAccountPairShow() opens the pairing flow');
    is($r->{acc}{link}, 'none', 'F2 node: spotonAccountPairShow() hides its link');
    is($r->{acc}{howtoUntouched}, 'none', 'F2 node: spotonAccountPairShow() leaves the step-2 how-to alone');
    is($r->{howto}{howto}, 'block', 'F2 node: spotonSoloistPairHowtoShow() opens the how-to');
    is($r->{howto}{link}, 'none', 'F2 node: spotonSoloistPairHowtoShow() hides its link');
    is($r->{absent}, 'ok', 'F2 node: both functions throw nothing when their elements are absent');
}

done_testing();

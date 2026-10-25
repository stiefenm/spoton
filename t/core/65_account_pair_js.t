#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempfile);
use Cwd qw(abs_path);
use JSON::PP;

# ============================================================
# 85-11 Task 1 (D-21, D-22, D-24, T-85-21): the account-pairing JS of the
# settings page, executed under Node with a fake XMLHttpRequest, a fake
# window.location and controllable timers. The block between the BEGIN and END
# markers is extracted from basic.html, so a changed template is what gets
# tested, not a copy.
#
# What must hold:
#   - a success state returns by GET navigation (location.href = pathname) and
#     never calls reload() -- a reload re-POSTs the browser's last submit
#     (3fd1632 layer 1)
#   - a just_paired start reply shows the justPaired text and starts no poll
#   - the countdown element shows the window and decrements
#   - leaving the page cancels a running pairing, an idle page sends nothing
# ============================================================

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";
my $html_file   = "$project_dir/Plugins/SpotOn/HTML/EN/plugins/SpotOn/settings/basic.html";
die "basic.html not found (never skip)\n" unless -f $html_file;

my $node = `which node 2>/dev/null`;
chomp $node;
plan skip_all => "node not available in this environment" unless $node;

open(my $fh, '<:encoding(UTF-8)', $html_file) or die "Cannot open basic.html: $!";
my $html = do { local $/; <$fh> };
close($fh);

my ($js) = $html =~ m{// BEGIN account-pair-js\n(.*?)// END account-pair-js}s;
ok(defined $js && length $js, 'extracted the account-pair-js block from basic.html')
    or BAIL_OUT("account-pair-js markers missing in basic.html");

my $harness = <<'NODE_HARNESS';
// ---- fake browser ----------------------------------------------------
var timers = [];            // {id, fn, ms, live}
var nextTimer = 1;
global.setInterval = function(fn, ms) { var t = {id: nextTimer++, fn: fn, ms: ms, live: true}; timers.push(t); return t.id; };
global.clearInterval = function(id) { timers.forEach(function(t) { if (t.id === id) { t.live = false; } }); };
function liveTimers(ms) { return timers.filter(function(t) { return t.live && (ms === undefined || t.ms === ms); }); }

var requests = [];
global.XMLHttpRequest = function() {
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
};
function lastRequest(urlPart) {
    for (var i = requests.length - 1; i >= 0; i--) { if (requests[i].url.indexOf(urlPart) >= 0) { return requests[i]; } }
    return null;
}

var els = {};
function mkEl(id, extra) {
    var e = { id: id, style: {}, textContent: '', disabled: false, dataset: {} };
    for (var k in (extra || {})) { e[k] = extra[k]; }
    els[id] = e;
    return e;
}
function resetDom() {
    timers = []; requests = []; reloads = 0; fetches = [];
    mkEl('accountPairStartBtn', { dataset: {
        waitingText: 'WAITING', successText: 'SUCCESS', failedText: 'FAILED',
        timeoutText: 'TIMEOUT', justPairedText: 'JUSTPAIRED', windowSeconds: '300' } });
    mkEl('playerAuthCancelBtn', { style: { display: 'none' } });
    mkEl('player-auth-status', { style: { display: 'none' } });
    mkEl('account-pair-countdown', { style: { display: 'none' } });
    win.location.href = '/settings/plugins/SpotOn/settings/basic.html?playerid=x';
}
var reloads = 0, fetches = [], pagehide = null;
var win = {
    location: { href: '', pathname: '/settings/plugins/SpotOn/settings/basic.html', reload: function() { reloads++; } },
    addEventListener: function(evt, fn) { if (evt === 'pagehide') { pagehide = fn; } },
    open: function() {}
};
global.window = win;
global.document = { getElementById: function(id) { return els[id] || null; } };
global.fetch = function(url, opts) { fetches.push({ url: url, opts: opts }); };

// ---- the template block under test ----------------------------------
resetDom();
var CODE = EXTRACTED_JS_LITERAL + `
     return { start: spotonPlayerAuthStart, check: spotonPlayerAuthCheck, cancel: spotonPlayerAuthCancel,
              poll: function() { return spotonPlayerAuthPoll; } };`;
var api = (new Function('window', 'document', 'XMLHttpRequest', 'setInterval', 'clearInterval', 'fetch', CODE))
    (win, global.document, global.XMLHttpRequest, global.setInterval, global.clearInterval, global.fetch);

var R = {};
function snap(tag) {
    R[tag] = {
        status: els['player-auth-status'].textContent,
        statusShown: els['player-auth-status'].style.display,
        startDisabled: els['accountPairStartBtn'].disabled,
        cancelShown: els['playerAuthCancelBtn'].style.display,
        countdown: els['account-pair-countdown'].textContent,
        countdownShown: els['account-pair-countdown'].style.display,
        href: win.location.href,
        reloads: reloads,
        livePoll: liveTimers(2000).length,
        liveCountdown: liveTimers(1000).length
    };
}

// 1. start: POST, CSRF header, ok reply -> waiting UI + countdown + poll
api.start();
var s1 = lastRequest('/playerauth/start');
R.start = { method: s1.method, xrw: s1.headers['X-Requested-With'] };
s1.reply(200, { status: 'ok', deviceName: 'SpotOn Authorization (T)', windowSeconds: 300 });
snap('afterStart');

// 2. countdown decrements per second tick
var cd = liveTimers(1000)[0];
cd.fn(); cd.fn();
snap('afterTwoTicks');

// 3. poll while waiting: nothing changes
api.check();
lastRequest('/playerauth/status').reply(200, { state: 'waiting' });
snap('afterWaiting');
R.checkIsGet = lastRequest('/playerauth/status').method;

// 4. success: GET navigation, no reload, success text, timers stopped
api.check();
lastRequest('/playerauth/status').reply(200, { state: 'success', accountId: 'abcd1234' });
snap('afterSuccess');

// 5. just_paired start reply: text shown, no poll, button usable
resetDom();
api.start();
lastRequest('/playerauth/start').reply(200, { status: 'error', reason: 'just_paired' });
snap('afterJustPaired');

// 6. start error -> failed text
resetDom();
api.start();
lastRequest('/playerauth/start').reply(200, { status: 'error', reason: 'no_binary' });
snap('afterStartError');

// 7. timeout and failed states reset the UI and show their text
resetDom();
api.start();
lastRequest('/playerauth/start').reply(200, { status: 'ok', windowSeconds: 300 });
api.check();
lastRequest('/playerauth/status').reply(200, { state: 'timeout' });
snap('afterTimeout');
resetDom();
api.start();
lastRequest('/playerauth/start').reply(200, { status: 'ok', windowSeconds: 300 });
api.check();
lastRequest('/playerauth/status').reply(200, { state: 'failed' });
snap('afterFailed');

// 8. already_running attaches to the running pairing (double click)
resetDom();
api.start();
lastRequest('/playerauth/start').reply(200, { status: 'error', reason: 'already_running' });
snap('afterAlreadyRunning');

// 9. cancel POSTs and resets
resetDom();
api.start();
lastRequest('/playerauth/start').reply(200, { status: 'ok', windowSeconds: 300 });
api.cancel();
var c = lastRequest('/playerauth/cancel');
R.cancelMethod = c.method;
c.reply(200, { status: 'ok' });
snap('afterCancel');

// 10. pagehide: cancels a running pairing, sends nothing when idle
resetDom();
fetches = [];
pagehide();
R.pagehideIdle = fetches.length;
api.start();
lastRequest('/playerauth/start').reply(200, { status: 'ok', windowSeconds: 300 });
pagehide();
R.pagehideRunning = { n: fetches.length, url: fetches[0] && fetches[0].url,
    xrw: fetches[0] && fetches[0].opts && fetches[0].opts.headers && fetches[0].opts.headers['X-Requested-With'] };

console.log(JSON.stringify(R));
NODE_HARNESS

my $js_lit = JSON::PP->new->allow_nonref->ascii->encode($js);
$harness =~ s/EXTRACTED_JS_LITERAL/$js_lit/;

my ($tmp_fh, $script_path) = tempfile('pair_js_XXXXXX', SUFFIX => '.js', TMPDIR => 1, UNLINK => 1);
print $tmp_fh $harness;
close($tmp_fh);

my $out = `node "$script_path" 2>&1`;
my $node_exit = $? >> 8;

is($node_exit, 0, 'account-pair JS executed under Node without error')
    or diag("Node output: $out");

SKIP: {
    skip "Node execution failed, cannot parse result", 35 if $node_exit != 0;

    my $r = eval { JSON::PP::decode_json($out) };
    ok($r, 'Node result is JSON') or diag($out);
    skip "no result", 34 unless $r;

    my $path = '/settings/plugins/SpotOn/settings/basic.html';

    is($r->{start}{method}, 'POST', 'start POSTs to playerauth/start');
    is($r->{start}{xrw}, 'XMLHttpRequest', 'start sends X-Requested-With (CSRF guard, T-85-20)');

    # --- waiting UI ---
    is($r->{afterStart}{status}, 'WAITING', 'ok start reply shows the waiting text');
    ok($r->{afterStart}{startDisabled}, 'the pair button is disabled while waiting');
    is($r->{afterStart}{cancelShown}, 'inline-block', 'the cancel button is shown while waiting');
    is($r->{afterStart}{countdown}, '5:00', 'the countdown starts at the window (300 s = 5:00)');
    is($r->{afterStart}{countdownShown}, 'inline', 'the countdown element is visible while waiting');
    is($r->{afterStart}{livePoll}, 1, 'exactly one 2 s status poll is armed');

    # --- countdown ---
    is($r->{afterTwoTicks}{countdown}, '4:58', 'the countdown decrements once per second tick');

    # --- waiting poll ---
    is($r->{afterWaiting}{status}, 'WAITING', 'a waiting status poll leaves the page untouched');
    is($r->{checkIsGet}, 'GET', 'the status poll is a GET');

    # --- success: GET navigation, never reload ---
    is($r->{afterSuccess}{href}, $path, 'success sets location.href to the pathname (GET navigation, query dropped)');
    is($r->{afterSuccess}{reloads}, 0, 'success never calls location.reload()');
    is($r->{afterSuccess}{status}, 'SUCCESS', 'success shows the success text');
    is($r->{afterSuccess}{livePoll} + $r->{afterSuccess}{liveCountdown}, 0, 'success stops the poll and the countdown');
    is($r->{afterSuccess}{startDisabled}, JSON::PP::false, 'success re-enables the pair button');

    # --- just_paired ---
    is($r->{afterJustPaired}{status}, 'JUSTPAIRED', 'a just_paired start reply shows the justPaired text');
    is($r->{afterJustPaired}{livePoll}, 0, 'a just_paired start reply arms no poll');
    is($r->{afterJustPaired}{startDisabled}, JSON::PP::false, 'a just_paired start reply leaves the button usable');
    is($r->{afterJustPaired}{reloads}, 0, 'a just_paired start reply does not reload');

    # --- other start / end states ---
    is($r->{afterStartError}{status}, 'FAILED', 'a start error shows the failed text');
    is($r->{afterTimeout}{status}, 'TIMEOUT', 'the timeout state shows the timeout text');
    is($r->{afterTimeout}{livePoll} + $r->{afterTimeout}{liveCountdown}, 0, 'timeout stops the poll and the countdown');
    is($r->{afterFailed}{status}, 'FAILED', 'the failed state shows the failed text');
    is($r->{afterTimeout}{reloads} + $r->{afterFailed}{reloads}, 0, 'timeout/failed never reload');
    is($r->{afterAlreadyRunning}{status}, 'WAITING', 'already_running attaches to the running pairing (waiting text)');
    is($r->{afterAlreadyRunning}{livePoll}, 1, 'already_running arms the status poll');

    # --- cancel / pagehide ---
    is($r->{cancelMethod}, 'POST', 'cancel POSTs to playerauth/cancel');
    is($r->{afterCancel}{cancelShown}, 'none', 'cancel hides the cancel button');
    is($r->{afterCancel}{statusShown}, 'none', 'cancel hides the status element');
    is($r->{pagehideIdle}, 0, 'leaving an idle page sends no cancel request');
    is($r->{pagehideRunning}{n}, 1, 'leaving a page with a running pairing sends one cancel request');
    like($r->{pagehideRunning}{url} // '', qr{/playerauth/cancel$}, 'the pagehide request goes to playerauth/cancel');
    is($r->{pagehideRunning}{xrw}, 'XMLHttpRequest', 'the pagehide request carries X-Requested-With (CSRF guard)');
}

done_testing();

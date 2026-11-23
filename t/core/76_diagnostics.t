#!/usr/bin/perl
# 79-72 (D-44, D-45): Plugins::SpotOn::Diagnostics -- the ordered section and redaction lists and the
# per-report placeholders. Fixture lines are synthetic and carry the SAME shapes the archived logs carry
# (79-BETA5-RESEARCH 2.4): the archive lives outside git, CI must pass without it. The archive proof is
# runners/diag-redact-gate.sh (79-72-DEVRUN.md DIAG72_*).
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use Encode qw(encode);

my $project_dir = dirname(dirname(dirname(abs_path($0))));   # t/core/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";
BEGIN { my $d = dirname(dirname(dirname(Cwd::abs_path($0)))); unshift @INC, $d; }

# No Slim module is stubbed here on purpose: the list module must load without LMS.
use_ok('Plugins::SpotOn::Diagnostics');
my $R = \&Plugins::SpotOn::Diagnostics::redact;

# --- Test 1: display name, token-wise ----------------------------------------------------------------
{
    my $ctx = { accounts => { a => { spotifyUserId => 'fixtureuser77', displayName => 'Max' } } };
    is($R->("Display name: Max / HOLD_MAX_S=3 / Maxwell", $ctx),
       "Display name: [REDACTED] / HOLD_MAX_S=3 / Maxwell",
       '79-72 T2 display name: only the standalone name is replaced; HOLD_MAX_S and Maxwell stay');
    is($R->("who: Max, then Max.", { accounts => { a => { displayName => 'Max' } } }),
       "who: [REDACTED], then [REDACTED].",
       '79-72 T2 display name: punctuation around the token is fine');
    is($R->("short: A end", { accounts => { a => { displayName => 'A' } } }),
       "short: A end",
       '79-72 T2 display name: a one-character name is not redacted (length >= 2)');
}

# --- Test 2: user id, three forms --------------------------------------------------------------------
{
    my $uid2 = "j\x{fc}rgen.m";
    my $ctx = { accounts => {
        a => { spotifyUserId => 'fixtureuser77' },
        b => { spotifyUserId => $uid2 },
    } };
    is($R->("u fixtureuser77 end", $ctx), "u [REDACTED] end", '79-72 T2 user id: the stored value');
    my $bytes = encode('UTF-8', $uid2);
    is($R->("log $bytes end", $ctx), "log [REDACTED] end", '79-72 T2 user id: its UTF-8 bytes (as a log file holds them)');
    is($R->("path/profile/j%C3%BCrgen.m: 503", $ctx), "path/profile/[REDACTED]: 503", '79-72 T2 user id: its URI escape');
    is($R->("path/profile/j%c3%bcrgen.m: 503", $ctx), "path/profile/[REDACTED]: 503", '79-72 T2 user id: ... in either hex case');
}

# --- Test 3: LAN IPv4 ----------------------------------------------------------------------------------
{
    is($R->("192.168.4.7 then 10.0.0.2 then 192.168.4.7 then 8.8.8.8", {}),
       "LAN-1 then LAN-2 then LAN-1 then 8.8.8.8",
       '79-72 T2 LAN IPv4: same address same N, public addresses stay');
    is($R->("172.20.1.1 169.254.9.9 172.32.0.1 172.15.0.1", {}),
       "LAN-1 LAN-2 172.32.0.1 172.15.0.1",
       '79-72 T2 LAN IPv4: 172.16/12 and 169.254/16 count as LAN, the neighbours do not');
    is($R->("POSTing http://192.168.4.7:9000/jsonrpc.js and (IP [10.0.0.2, 192.168.4.7])", {}),
       "POSTing http://LAN-1:9000/jsonrpc.js and (IP [LAN-2, LAN-1])",
       '79-72 T2 LAN IPv4: URL and list shapes');
    is($R->("version 1.10.0.2.3 and 9.10.0.0.2", {}), "version 1.10.0.2.3 and 9.10.0.0.2",
       '79-72 T2 LAN IPv4: dotted version strings are not addresses');
}

# --- Test 4: LAN IPv6 ----------------------------------------------------------------------------------
{
    is($R->("fe80::1a2b:3c4d:5e6f:7a8b%eth0 and fd12:3456::1 and 2001:db8::1", {}),
       "LAN6-1%eth0 and LAN6-2 and IP6-1",
       '79-72 T2 LAN IPv6: zone suffix kept; a GLOBAL address becomes IP6-N too (owner decision 2026-11-04, was: stays)');
    is($R->("IP [192.168.1.5, fe80::1a2b:3c4d:5e6f:7a8b, fe80::1a2b:3c4d:5e6f:7a8b%wlan0]", {}),
       "IP [LAN-1, LAN6-1, LAN6-1%wlan0]",
       '79-72 T2 LAN IPv6: the same address with and without a zone is one N');
}

# --- Test 4b: GLOBAL IPv6 (owner decision 2026-11-04): the Soloist Reachability lines carry the host's global
# addresses. Synthetic addresses from the documentation prefix 2001:db8::/32 in the SAME line shape as the archive.
{
    my $line = "09:28:58.572 I [f:288                           ] Reachability changed from unknown (IP [], roaming false) to ethernet (IP "
        . "[192.168.4.7, 10.0.0.2, 172.20.1.1, 2001:db8:1801:3941:f49:3d4e:8881:1, 2001:db8:1801:bc5d:7ad2:c1cb:b2e6:2, "
        . "fe80::1a2b:3c4d:5e6f:7a8b, fd12:3456::1, fe80::aaaa:bbbb%wlp0s1], roaming false)\e[0m";
    is($R->($line, {}),
       "09:28:58.572 I [f:288                           ] Reachability changed from unknown (IP [], roaming false) to ethernet (IP "
        . "[LAN-1, LAN-2, LAN-3, IP6-1, IP6-2, LAN6-1, LAN6-2, LAN6-3%wlp0s1], roaming false)\e[0m",
       '79-72 T2 global IPv6: the Soloist Reachability line shape - global addresses IP6-N, local LAN6-N, IPv4 LAN-N, numbered per kind');
    is($R->("2001:db8::7 a 2001:DB8::7 b 2001:db8:0:0:0:0:0:8 c [2001:db8::9]:9000 d", {}),
       "IP6-1 a IP6-1 b IP6-2 c [IP6-3]:9000 d",
       '79-72 T2 global IPv6: compressed, upper-case and bracketed forms; the same address is one N');
    my $keep = "Plugins::SpotOn::API::Client Slim::Player::Client Dead::Beef std::cout at 10:11:12 and [26-10-22 10:03:21.2587] "
        . "ratio 3:2:1 key a:b: and ::ffff:1.2.3.4 and 1.2.3.4.5";
    is($R->($keep, {}), $keep,
       '79-72 T2 global IPv6: module names, times, ratios and version strings are no addresses (no digit or no valid shape)');
}

# Against a REAL archived Soloist line (the archive lives outside git: skipped in CI and on machines without it).
SKIP: {
    my $f = "$ENV{HOME}/SynologyDrive/dev/spoton-messdaten/79-29-forensics/logs/0200005a1101-soloist.log";
    skip 'archived Soloist log not present', 6 unless -f $f;
    my $v6 = qr/(?<![\w:])(?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}(?![\w:])/i;
    my $line;
    open(my $fh, '<:raw', $f) or die "$f: $!";
    while (my $l = <$fh>) { if ($l =~ /Reachability changed/ && $l =~ $v6) { $line = $l; last } }
    close $fh;
    ok(defined $line, '79-72 T2 global IPv6 (archive): the archived log has a Reachability line with a global address');
    skip 'no such line', 5 unless defined $line;
    my @orig = $line =~ /($v6)/g;
    my $out = $R->($line, {});
    my $left = grep { $out =~ /\Q$_\E/i } @orig;
    is($left, 0, '79-72 T2 global IPv6 (archive): none of the ' . scalar(@orig) . ' archived global addresses of the line is left');
    my $nglobal = grep { !/^(?:fe[89ab][0-9a-f]|f[cd][0-9a-f]{2}):/i } @orig;
    ok($nglobal >= 1, '79-72 T2 global IPv6 (archive): the line carries at least one GLOBAL address (' . $nglobal . ' of ' . scalar(@orig) . ' full-length ones; the rest are unique-local)');
    is(scalar(() = $out =~ /IP6-\d+/g), $nglobal, '79-72 T2 global IPv6 (archive): each global address became an IP6-N placeholder, the unique-local ones LAN6-N');
    unlike($out, $v6, '79-72 T2 global IPv6 (archive): no full-length IPv6 address is left in the line');
    like($out, qr/Reachability changed from unknown \(IP \[\], roaming false\) to ethernet \(IP \[LAN-1/, '79-72 T2 global IPv6 (archive): the rest of the line is intact');
}

# --- Test 4c: 79-75 WR-01 -- an IPv6 address whose groups are all two hex digits is no MAC -----------------
{
    is($R->("v6 fd00:11:22:33:44:55:66:77 and 2001:db8:11:22:33:44:55:66 end", {}),
       "v6 LAN6-1 and IP6-1 end",
       '79-75 WR-01 IPv6: eight two-hex groups are an address (LAN6-N / IP6-N), not a MAC plus a readable prefix');
    is($R->("addr 2001:db8:10:20:30:40:50:60 end", {}), "addr IP6-1 end",
       '79-75 WR-01 IPv6: a hand-assigned global address with two-hex groups becomes IP6-1, no Player-N phantom');
    unlike($R->("addr 2001:db8:10:20:30:40:50:60", {}), qr/Player-|2001:db8/,
       '79-75 WR-01 IPv6: no prefix of the address and no phantom player is left');
    is($R->("id:02:00:00:5a:11:01 [02:00:00:5a:11:02] Player_02:00:00:5a:11:03", {}),
       "id:02:00:00:Player-1 [02:00:00:Player-2] Player_02:00:00:Player-3",
       '79-75 WR-01 IPv6: a MAC behind a key that ends in a hex letter and a colon is still a MAC');
}

# --- Test 4c2: 79-75 IN-R1-04 -- a key ending in two hex letters glued to a MAC -----------------------------
{
    is($R->("mac:02:00:00:5a:11:01 face:02:00:00:5a:11:02", {}),
       "mac:02:00:00:Player-1 face:02:00:00:Player-2",
       '79-75 IN-R1-04 macs: a key that ends in two hex letters (mac, face) does not start the MAC rule inside the key');
    is($R->("mac:02:00:00:5a:11:01 and 02:00:00:5a:11:01", {}),
       "mac:02:00:00:Player-1 and 02:00:00:Player-1",
       '79-75 IN-R1-04 macs: the glued and the bare form of one MAC share one Player number');
    is($R->("_client:02:00:00:5a:11:01 [02:00:00:5a:11:02]:9000 (2205) 02:00:00:5a:11:03fadein=undef id:02:00:00:5a:11:04", {}),
       "_client:02:00:00:Player-1 [02:00:00:Player-2]:9000 (2205) 02:00:00:Player-3fadein=undef id:02:00:00:Player-4",
       '79-75 IN-R1-04 macs (controls): _client:, [mac]:port, a glued trailing word and id: still redact');
}

# --- Test 4d: 79-75 IN-02 -- the e-mail rule runs before the id rules ------------------------------------
{
    my $ctx = { accounts => { a => { spotifyUserId => 'max', displayName => 'Mx' } } };
    is($R->("mail max\@example.com and Mx\@example.org", $ctx), "mail [REDACTED] and [REDACTED]",
       '79-75 IN-02 emails: an id that is the local part of an address does not leave the domain readable');
}

# --- Test 5: device ids -------------------------------------------------------------------------------
{
    my $uuid = '0a1b2c3d-1111-2222-3333-444455556666';
    my $own  = '0123456789abcdef';
    my $far  = 'a1a1a1a1a1a1a1a1';
    my $app  = 'b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2';
    my $in = join("\n",
        "ready, device_name=x device_id=$uuid\e[0m",
        "[spoton/unified] Device ID: $own",
        "[2026-01-01T00:00:00Z DEBUG librespot_connect::spirc] cluster update: Ok(NEW_DEVICE_APPEARED) from $far, active device: ",
        "[2026-01-01T00:00:01Z DEBUG librespot_connect::spirc] cluster update: Ok(DEVICE_STATE_CHANGED) from $app, active device: $own",
        "[2026-01-01T00:00:02Z DEBUG librespot_connect::spirc] handling: 'endpoint: resume' from $app",
        "Requesting https://h/connect-state/v1/devices/" . uc($own) . "?product=0",
        "device_id=$uuid",
        "hash fedcba9876543210,",
        "uuid 11111111-2222-3333-4444-555555555555 never behind a prefix",
        "separator-less device id 9f9f9f9f00 stays",
        "");
    my $want = join("\n",
        "ready, device_name=x device_id=DEVICE-1\e[0m",
        "[spoton/unified] Device ID: DEVICE-2",
        "[2026-01-01T00:00:00Z DEBUG librespot_connect::spirc] cluster update: Ok(NEW_DEVICE_APPEARED) from DEVICE-3, active device: ",
        "[2026-01-01T00:00:01Z DEBUG librespot_connect::spirc] cluster update: Ok(DEVICE_STATE_CHANGED) from DEVICE-4, active device: DEVICE-2",
        "[2026-01-01T00:00:02Z DEBUG librespot_connect::spirc] handling: 'endpoint: resume' from DEVICE-4",
        "Requesting https://h/connect-state/v1/devices/DEVICE-2?product=0",
        "device_id=DEVICE-1",
        "hash fedcba9876543210,",
        "uuid 11111111-2222-3333-4444-555555555555 never behind a prefix",
        "separator-less device id 9f9f9f9f00 stays",
        "");
    my $got = $R->($in, {});
    is($got, $want, '79-72 T2 device ids: learn shapes (device_id=, Device ID:, spirc from, active device:) and every recurrence');
    unlike($got, qr/\Q$own\E/i, '79-72 T2 device ids: the learned 16-hex id is gone in both cases');
    unlike($got, qr/\Q$far\E|\Q$app\E|\Q$uuid\E/, '79-72 T2 device ids: the foreign ids and the uuid are gone');
    like($got, qr/fedcba9876543210/, '79-72 T2 device ids: a hex token never behind a learn shape stays');
    like($got, qr/device_id=DEVICE-1\e\[0m/, '79-72 T2 device ids: the ANSI reset after a value is not part of it');
    like($got, qr/separator-less device id 9f9f9f9f00/, '79-72 T2 device ids: a separator-less "device id <hex>" is not a learn shape');
}

# --- Test 6: home paths --------------------------------------------------------------------------------
{
    is($R->("/home/alice/x", {}), "~/x", '79-72 T2 home paths: /home/<u>');
    is($R->("/Users/bob/y", {}), "~/y", '79-72 T2 home paths: /Users/<u>');
    is($R->('C:\\Users\\carol\\z', {}), '~\\z', '79-72 T2 home paths: C:\\Users\\<u>');
    is($R->("(could not collect: open /home/alice/.cache/x failed)", {}), "(could not collect: open ~/.cache/x failed)",
       '79-72 T2 home paths: inside an error text');
    is($R->("see /usr/share/home/x and /var/home", {}), "see /usr/share/home/x and /var/home", '79-72 T2 home paths: other paths stay');
}

# --- Test 7: e-mail addresses -------------------------------------------------------------------------
is($R->("mail alice\@example.org", {}), "mail [REDACTED]", '79-72 T2 emails: an address becomes [REDACTED]');

# --- Test 8: librespot Authenticated as -------------------------------------------------------------
is($R->("Authenticated as 'someone' !", {}), "Authenticated as '[REDACTED]' !", "79-72 T2 secrets: the librespot Authenticated as shape");

# --- Test 9: token key-values -------------------------------------------------------------------------
{
    is($R->("access_token=abc.def refresh_token: xyz sp_dc=qq", {}),
       "access_token=[REDACTED] refresh_token: [REDACTED] sp_dc=[REDACTED]",
       '79-72 T2 secrets: token key-values keep the key, replace the value');
    is($R->('{"client_token":"ct.1","password": "pw"}', {}),
       '{"client_token":"[REDACTED]","password": "[REDACTED]"}',
       '79-72 T2 secrets: the JSON form too');
    is($R->("the secret garden", {}), "the secret garden", '79-72 T2 secrets: the word alone is not a key-value');
    # 79-75 BR5 WR-02: a key that is the suffix of a longer key is still a key (the key stays, the value goes)
    is($R->("client_secret=abc app_secret: def user_password=jkl secret=mno", {}),
       "client_secret=[REDACTED] app_secret: [REDACTED] user_password=[REDACTED] secret=[REDACTED]",
       '79-75 WR-02 secrets: suffixed key names (client_secret, app_secret, user_password) are redacted');
    is($R->("apiSecret=ghi X-Api-Password: pw https://h/p?client_secret=zz&a=1", {}),
       "apiSecret=[REDACTED] X-Api-Password: [REDACTED] https://h/p?client_secret=[REDACTED]&a=1",
       '79-75 WR-02 secrets: camel-case, header and URL-query forms');
}

# --- Test 10: order and overlap ---------------------------------------------------------------------
{
    my $ctx = { accounts => { a => { displayName => 'ED' } } };
    is($R->("mac 02:00:00:ED:11:22 name ED aa:ED:bb:cc:dd:ee", $ctx),
       "mac 02:00:00:Player-1 name [REDACTED] aa:ed:bb:Player-2",
       '79-72 T2 order: a display name that equals a MAC octet does not break the MAC rule');
    is($R->("key spak_ED ED", { accounts => { a => { displayName => 'ED' } } }),
       "key [REDACTED] [REDACTED]", '79-72 T2 order: secrets run first');
}

# --- Test 11: counter stability -----------------------------------------------------------------------
{
    my $text = "02:00:00:5a:11:01 bare 0200005a1101-soloist.log 192.168.4.7 fe80::1 device_id=0a1b2c3d-1111-2222-3333-444455556666";
    my $one = $R->($text, {});
    my $two = $R->($text, {});
    is($one, $two, '79-72 T2 counters: two consecutive reports with fresh ctx hashes are identical');
    is($one, "02:00:00:Player-1 bare 020000-Player-1-soloist.log LAN-1 LAN6-1 device_id=DEVICE-1",
       '79-72 T2 counters: every counter starts at 1; the colon and the bare form of one MAC share one N');
    my $ctx = {};
    $R->("02:00:00:5a:11:09", $ctx);
    is($R->("02:00:00:5a:11:09 02:00:00:5a:11:0a", $ctx), "02:00:00:Player-1 02:00:00:Player-2",
       '79-72 T2 counters: within one report (same ctx) the map is shared');
    my $clients = { macs => ['02:00:00:5a:11:0a', '02:00:00:5a:11:09'] };
    is($R->("02:00:00:5a:11:09 02:00:00:5a:11:0a 0200005a110a-unified.log", $clients),
       "02:00:00:Player-2 02:00:00:Player-1 020000-Player-1-unified.log",
       '79-72 T2 counters: the ordered client list numbers first, appearance order only for the rest');
    is($R->("resume (2205) 02:00:00:5a:11:01fadein=undef", {}), "resume (2205) 02:00:00:Player-1fadein=undef",
       '79-72 T2 counters: a MAC with the next word glued to it (LMS StreamingController::resume line, found by the archive gate) is redacted');
    is($R->("hash abcdef012345 and 02:00:00:5a:11:01", {}), "hash abcdef012345 and 02:00:00:Player-1",
       '79-72 T2 counters: a bare 12-hex string that is no MAC stays (it may be a hash)');
}

# --- Test 12: list integrity --------------------------------------------------------------------------
{
    my @red = Plugins::SpotOn::Diagnostics::redactions();
    my @sec = Plugins::SpotOn::Diagnostics::sections();
    is(scalar(@red), 9, '79-72 T2 lists: nine redactions (90.1-04: guestids joined)');
    is(scalar(@sec), 8, '79-72 T2 lists: eight sections');
    is(join(',', map { $_->{id} } @red), 'secrets,emails,userids,guestids,displayname,lanips,macs,deviceids,homepaths',
       '79-72 T2 lists: redaction order (90.1-04 R3: guestids right after userids, nothing reordered)');
    ok((!grep { ref($_->{apply}) ne 'CODE' || $_->{key} !~ /^PLUGIN_SPOTON_DIAG_RED_/ } @red),
       '79-72 T2 lists: every redaction has an apply coderef and a PLUGIN_SPOTON_DIAG_RED_ key');
    ok((!grep { $_->{collector} !~ /^_collect/ || $_->{title} !~ /^PLUGIN_SPOTON_DIAG_SEC_/ || $_->{desc} !~ /^PLUGIN_SPOTON_DIAG_SEC_\w+_DESC$/ } @sec),
       '79-72 T2 lists: every section has a _collect* collector name and SEC title/desc keys');
    my @fixed = Plugins::SpotOn::Diagnostics::fixedKeys();
    is(scalar(@fixed), 8, '79-82 D-56: eight fixed keys (the six of 79-72 plus the page link text and the page title)');
    ok((grep { $_ eq 'PLUGIN_SPOTON_DIAG_PAGE_LINK' } @fixed) && (grep { $_ eq 'PLUGIN_SPOTON_DIAG_PAGE_TITLE' } @fixed),
       '79-82 D-56: the fixed keys contain PLUGIN_SPOTON_DIAG_PAGE_LINK and PLUGIN_SPOTON_DIAG_PAGE_TITLE');
    is(Plugins::SpotOn::Diagnostics::notRedactedKey(), 'PLUGIN_SPOTON_DIAG_NOT_REDACTED', '79-72 T2 lists: the not-redacted key');
}

# --- 79-82 D57 (D-57): stripAnsi ------------------------------------------------------------------------
# The user's Pi report (spoton-diag-20261105-111320.txt) held 4661 terminal color sequences on 4616 lines of the
# daemonlogs section: ESC[0m at every line end, ESC[1;31m before the text of an E line, ESC[1;33m before a W line.
# The three fixture lines are lines 104, 281 and 419 of it. The function is called through can() so that a missing
# function gives `not ok` lines, not a die.
{
    my $strip = Plugins::SpotOn::Diagnostics->can('stripAnsi') || sub { $_[0] };
    my $fixturePath = "$project_dir/t/fixtures/soloist/d57-ansi-soloist.log";
    open(my $fh, '<:raw', $fixturePath) or die "$fixturePath: $!";
    my @fx = <$fh>;
    close $fh;
    is(scalar(@fx), 3, 'D57 fixture: three real report lines (an I line, an E line, a W line)');
    my @out = map { $strip->($_) } @fx;

    ok(Plugins::SpotOn::Diagnostics->can('stripAnsi') ? 1 : 0, 'D57-1 (D-57): Diagnostics::stripAnsi exists');
    is(scalar(grep { /\x1b/ } @out), 0, 'D57-1 (D-57): none of the three real lines keeps an ESC byte');
    like($out[0], qr/^18:56:11\.090 I \[f:219 +\] soloist 1\.3\.10\.13 build 1792778483 \(20261023\) \(g19412df6ea\) \(linux\/aarch64\)\n\z/,
         'D57-1: the I line ends in (linux/aarch64), letter and column intact');
    like($out[1], qr/^07:09:16\.755 E \[f:430 +\] mDNS: unable to parse question 0 string, aborting\n\z/,
         'D57-1: the E line reads "] mDNS: ... aborting" (the ESC[1;31m before the text is gone)');
    like($out[2], qr/^20:45:29\.110 W \[f:1200 +\] Session Track Player closed without close source\n\z/,
         'D57-1: the W line reads "] Session Track Player ..." (the ESC[1;33m before the text is gone)');

    my @plain = ("[fakepulse] vsink: T_ms=3000 source=default\n", "12:00:00.001 I [f:47                            ] plain text [x] (y)\n", "no newline at all");
    is_deeply([ map { $strip->($_) } @plain ], \@plain,
              'D57-2: a line without ESC comes back byte-identical, bracket forms included');

    is($strip->("a\e[1;31mb\e[0mc"), 'abc', 'D57-3: ESC[1;31m and ESC[0m go');
    is($strip->("x\e[38;5;196my"), 'xy', 'D57-3: a 256-colour form goes');
    is($strip->("a\e[2Kb\e[?25lc"), 'abc', 'D57-3: other CSI forms go (erase line, private mode)');
    my $multi = "one\e[0m\ntwo \e[1;33mwarn\e[0m\nthree\n";
    my $res = $strip->($multi);
    is($res, "one\ntwo warn\nthree\n", 'D57-3: a multi-line text keeps its newlines and its line count');
    is($strip->("a\eb"), "a\eb", 'D57-3: a lone ESC that is no CSI start stays (the gate would count it)');
}

# --- 90.1-04 (D-06): a guest account id in the copied daemon log leaves the report as ...<last4> --------------
# Made-up 28-character id (never a real one). The Soloist daemon log prints it in `logged in as <id>` and in the
# `[session:<id>]` tag; the guest is NOT a stored account, so only the guestids rule can shorten it.
{
    my $FAKE28 = 'fakeguestid012345678abcdwxyz';   # 28 chars
    my $last4  = substr($FAKE28, -4);
    my $log = "2026-11-20 12:07:18.718: logged in as $FAKE28\n"
            . "2026-11-20 12:07:19.001: Session restored from store, session: [session:$FAKE28]\n";
    my $out = $R->($log, {});
    like($out, qr/logged in as \.\.\.\Q$last4\E\n/, '90.1-04 R1: `logged in as <id>` comes out as `logged in as ...<last4>`');
    like($out, qr/\[session:\.\.\.\Q$last4\E\]/, '90.1-04 R1: `[session:<id>]` comes out as `[session:...<last4>]`');
    unlike($out, qr/\Q$FAKE28\E/, '90.1-04 R1: the guest id appears nowhere in the whole report output');
    unlike($out, qr/fakeguestid/, '90.1-04 R1: not even its first part appears in the report output');

    # R2: a STORED id stays [REDACTED] as before; the guest rule leaves that marker alone
    my $ctx = { accounts => { a => { spotifyUserId => 'fixtureuser77' } } };
    my $o2 = $R->("logged in as fixtureuser77\n[session:fixtureuser77]\n", $ctx);
    is($o2, "logged in as [REDACTED]\n[session:[REDACTED]]\n", '90.1-04 R2: a stored id still becomes [REDACTED]; the guest rule adds no ...TED] fragment');
    unlike($o2, qr/\.\.\./, '90.1-04 R2: no ellipsis shortening on an already redacted marker');
}

# --- 90.1 review CR-01: the guest rule fails CLOSED, with AccountLog's length rule ---------------------------------
# An id of 8 characters or fewer shows nothing (`...`), a longer one only its last 4 characters. Whatever follows the
# anchor is the id, whatever characters it holds (legacy Spotify user names are user-chosen and can be short). Every
# id below is made up.
{
    require Encode;
    my $cases = [
        # [ label, id (characters), expected shown form ]
        [ '6-character id',                 'qz7k2m',                 '...' ],
        [ '7-character legacy-style id',    'qzfixtr',                '...' ],
        [ '8-character id (all digits)',    '12345678',               '...' ],
        [ '9-character id',                 'q1w2e3r4t',              '...3r4t' ],
        [ 'id with a +',                    'zz9fixture+guest77',     '...st77' ],
        [ 'id with a non-ASCII letter',     "andr\x{e9}.fixture99",   '...re99' ],
        [ '8 characters, one non-ASCII',    "j\x{f6}rgen77",          '...' ],
        [ '6 characters, one non-ASCII',    "j\x{f6}rg77",            '...' ],
    ];
    for my $c (@$cases) {
        my ($label, $id, $want) = @$c;
        for my $form ([ 'bytes', Encode::encode('UTF-8', $id) ], [ 'characters', $id ]) {
            my ($fname, $fid) = @$form;
            my $wantF = $fname eq 'bytes' ? Encode::encode('UTF-8', $want) : $want;
            my $log = "2026-11-20 12:07:18.718: logged in as $fid\n"
                    . "2026-11-20 12:07:19.001: Session restored from store, session: [session:$fid]\n"
                    . "11:08:38.854 I [f:415 ] logged in as $fid\e[0m\n";
            my $out = $R->($log, {});
            my $q = quotemeta $wantF;
            like($out, qr/: logged in as $q\n/, "90.1 CR-01: $label ($fname) - `logged in as` shows $want");
            like($out, qr/\[session:$q\]/,     "90.1 CR-01: $label ($fname) - `[session:]` shows $want");
            like($out, qr/logged in as $q\e\[0m/, "90.1 CR-01: $label ($fname) - the older build's coloured line shows $want");
            unlike($out, qr/\Q$fid\E/,          "90.1 CR-01: $label ($fname) - the id appears nowhere in the output");
            my $head = substr($fid, 0, 3);
            unlike($out, qr/(?:as |session:)\Q$head\E/, "90.1 CR-01: $label ($fname) - not even its first characters follow an anchor");
        }
    }

    # an already shortened id and the stored-id marker are left as they are (the rule runs once per report, but it must
    # not turn `...wxyz` into `...` or `[REDACTED]` into `...TED]`)
    my $done = "logged in as ...wxyz\n[session:...wxyz]\nlogged in as ...\n[session:...]\nlogged in as [REDACTED]\n[session:[REDACTED]]\n";
    is($R->($done, {}), $done, '90.1 CR-01: an already shortened id and the [REDACTED] marker stay untouched');

    # the guest id elsewhere in the text (a context uri at INFO): every token occurrence of an id seen at an anchor goes
    my $ID7 = 'qzfixtr';
    my $ctxLog = "2026-11-20 12:07:18.718: logged in as $ID7\n"
               . "[26-11-20 12:07:20.0000] Control: the app replaced the queue (context spotify:user:$ID7:collection) -- takeover\n";
    my $o3 = $R->($ctxLog, {});
    unlike($o3, qr/\Q$ID7\E/, '90.1 CR-01: a guest id seen in `logged in as` is also gone from a context uri elsewhere in the text');
    like($o3, qr/spotify:user:\.\.\.:collection/, '90.1 CR-01: the context uri keeps its shape (spotify:user:...:collection)');
    my $ID12 = 'fixtureguest12';
    my $o4 = $R->("[session:$ID12]\nplaying spotify:user:$ID12:collection\n", {});
    unlike($o4, qr/\Q$ID12\E/, '90.1 CR-01: an id seen only in `[session:]` is gone from the rest of the text as well');
    like($o4, qr/spotify:user:\.\.\.st12:collection/, '90.1 CR-01: a long id elsewhere keeps its last 4 characters, like at the anchor');
}

# --- 90.1 review R2 WR-01: the user uri is its own anchor, cut in place, never a sweep source ---------------------------
# The login line can lie outside the report's daemon-log tail while the server.log extract still carries the context uri
# `spotify:user:<id>:collection` at INFO (Control.pm takeover line). The uri cuts its id in place with the same length rule,
# in the plain and in the URI-escaped form (`spotify%3Auser%3A<id>%3A...`, an escaped id counted after unescaping). A stored
# (paired) id stays [REDACTED] in both forms, as the userids rule does for its plain form. Every id below is made up.
{
    require Encode;
    my $take = "[26-11-20 12:07:20.0000] Plugins::SpotOn::Soloist::Control::_onFrameContextChanged (4462) Control: the app replaced the queue (context spotify:user:%s:collection) -- takeover (02:00:00:86:00:02)\n";
    my $o1 = $R->(sprintf($take, 'smedjanfixture'), {});
    unlike($o1, qr/smedjanfix/, '90.1 R2 WR-01: a user uri with no anchor line in the text loses its id');
    like($o1, qr/\(context spotify:user:\.\.\.ture:collection\) -- takeover/, '90.1 R2 WR-01: a long id in a user uri shows its last 4 characters, the uri keeps its shape');
    my $o2 = $R->(sprintf($take, 'qzfixtr'), {});
    like($o2, qr/\(context spotify:user:\.\.\.:collection\)/, '90.1 R2 WR-01: a short id (8 characters or fewer) in a user uri shows nothing');
    unlike($o2, qr/qzfixtr/, '90.1 R2 WR-01: the short id appears nowhere');
    my $o2b = $R->(sprintf($take, Encode::encode('UTF-8', "j\x{f6}rgen77")), {});
    like($o2b, qr/spotify:user:\.\.\.:collection/, '90.1 R2 WR-01: 8 characters with one non-ASCII letter (9 bytes) in a user uri show nothing');

    # the URI-escaped forms: the escaped uri anchor, and an escaped id inside a plain uri
    my $o3 = $R->("GET https://spclient.wg.spotify.com/context-resolve/v1/spotify%3Auser%3Azz9fixture%2Bguest77%3Acollection\n", {});
    unlike($o3, qr/fixture/, '90.1 R2 WR-01: an id in the escaped uri form loses all but its last 4 characters');
    like($o3, qr{/v1/spotify%3Auser%3A\.\.\.st77%3Acollection\n}, '90.1 R2 WR-01: the escaped uri keeps its shape (`%3A` ends the id)');
    my $o4 = $R->("x spotify%3auser%3aab%2Bcdefg%3acollection\nlogged in as abc+def1234\ny spotify:user:abc%2Bdef1234:collection\n", {});
    like($o4, qr/x spotify%3auser%3a\.\.\.%3acollection/, '90.1 R2 WR-01: an escaped 8-character id (ab+cdefg) counts unescaped and shows nothing');
    like($o4, qr/y spotify:user:\.\.\.1234:collection/, '90.1 R2 WR-01: an escaped id in a plain uri (review probe abc%2Bdef1234) is cut, not left in full');
    unlike($o4, qr/abc%2Bdef|cdefg/, '90.1 R2 WR-01: no escaped id is left in full');

    # an id seen at an anchor is also swept in its URI-escaped form (as _redactUserIds does for a stored id)
    my $o5 = $R->("2026-11-20 12:07:18.718: logged in as zz9fixture+guest77\nGET /v1/users/zz9fixture%2bguest77/items\n", {});
    unlike($o5, qr/zz9fixture/i, '90.1 R2 WR-01: the escaped form of an anchored id is swept too (hex digits in either case)');
    like($o5, qr{GET /v1/users/\.\.\.st77/items}, '90.1 R2 WR-01: the swept escaped form keeps only the last 4 characters');

    # the legacy playlist uri: the owner is cut in place, the word `spotify` is NOT swept from the rest of the text
    my $o6 = $R->("2026-11-20 12:07:18.718: logged in as fixtureguest12\nplay spotify:user:spotify:playlist:37i9dQZF1DXcBWIGoYBM5M\nnext spotify:track:4JOyMhad5dD81uGYLGgKrS on the spotify device\n", {});
    like($o6, qr/play spotify:user:\.\.\.:playlist:37i9dQZF1DXcBWIGoYBM5M\n/, '90.1 R2 WR-01: spotify:user:spotify:playlist: keeps its shape, the owner word cut in place');
    like($o6, qr/next spotify:track:4JOyMhad5dD81uGYLGgKrS on the spotify device\n/, '90.1 R2 WR-01: the user-uri anchor feeds no sweep (the word spotify stays everywhere else)');

    # the stored (paired) id keeps round 1's behaviour, [REDACTED], also in the escaped uri form the userids rule cannot see
    my $ctx = { accounts => { a => { spotifyUserId => 'fixtureuser77' } } };
    my $o7 = $R->("A spotify:user:fixtureuser77:collection\nB spotify%3Auser%3Afixtureuser77%3Acollection\n", $ctx);
    is($o7, "A spotify:user:[REDACTED]:collection\nB spotify%3Auser%3A[REDACTED]%3Acollection\n", '90.1 R2 WR-01: a stored id in a user uri stays [REDACTED], plain and escaped');

    # idempotent: a cut or redacted uri stays as it is
    my $done = "spotify:user:...:collection\nspotify:user:...ture:collection\nspotify:user:[REDACTED]:collection\nspotify%3Auser%3A...st77%3Acollection\n";
    is($R->($done, {}), $done, '90.1 R2 WR-01: an already cut or redacted user uri stays untouched');
}

# --- 90.1 review R2 WR-02: only a daemon-shaped anchor feeds the token sweep ---------------------------------------------
# The server.log section carries Error and Warning lines of every module, whose wording SpotOn does not control. A foreign
# `logged in as <word>` is still cut in place (fail closed), but only the daemon's own login line (a daemon timestamp right
# before it, the id ends the line: AccountLog's shape) and the bracketed `[session:<id>]` tag teach the sweep an id.
{
    my $o1 = $R->("[26-11-20 12:00:01.0000] Plugins::X::y (1) WARN not logged in as premium user\n"
                . "[26-11-20 12:00:02.0000] Plugins::X::z (2) premium tier active, max-age=3\n", {});
    like($o1, qr/WARN not logged in as \.\.\. user\n/, '90.1 R2 WR-02: a foreign `logged in as <word>` is still cut in place');
    like($o1, qr/\(2\) premium tier active, max-age=3\n/, '90.1 R2 WR-02: the false anchor `not logged in as premium user` sweeps no word from other lines');
    my $o2 = $R->("[26-11-20 12:00:01.0000] Plugins::X::y (1) user not logged in as premium\n"
                . "[26-11-20 12:00:02.0000] Plugins::X::z (2) premium tier active\n", {});
    like($o2, qr/\(2\) premium tier active\n/, '90.1 R2 WR-02: a foreign line ending in `logged in as <word>` (no daemon timestamp) sweeps nothing either');
    my $o3 = $R->("x session:connect y\nControl: transfer-in -> mode=connect\nreconnect-to-connect, controlMode connect\n", {});
    is($o3, "x session:connect y\nControl: transfer-in -> mode=connect\nreconnect-to-connect, controlMode connect\n",
       '90.1 R2 WR-02: a bracket-less `session:connect` is no anchor (mode=connect and controlMode connect stay)');

    # the daemon's own shapes still teach the sweep: current build, older build (coloured and after stripAnsi), the session tag
    for my $c ([ 'current build', "2026-11-20 12:07:18.718: logged in as fixtureguest12\n" ],
               [ 'older build, coloured', "11:08:38.854 I [f:415 ] logged in as fixtureguest12\e[0m\n" ],
               [ 'older build, stripped', "11:08:38.854 I [f:415 ] logged in as fixtureguest12\n" ],
               [ 'session tag', "restoring session [session:fixtureguest12]\n" ]) {
        my $o = $R->($c->[1] . "[26-11-20 12:07:20.0000] Plugins::SpotOn::Foo::bar (9) playing for fixtureguest12 now\n", {});
        like($o, qr/playing for \.\.\.st12 now\n/, "90.1 R2 WR-02: the daemon's $c->[0] form still sweeps its id from other lines");
    }
}

# --- the module needs no Slim module --------------------------------------------------------------------
{
    my @slim = grep { m{^Slim/} } keys %INC;
    is(scalar(@slim), 0, '79-72 T1 module / D57-4 (D-57): loading Diagnostics.pm (stripAnsi included) pulled in no Slim module');
}

done_testing();

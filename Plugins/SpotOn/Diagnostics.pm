package Plugins::SpotOn::Diagnostics;

# 79-72 (D-44, D-45): the ONE list module behind the diagnostic report.
#
# sections()   -- the ordered report sections (id, title/desc string keys, collector name in Settings.pm)
# redactions() -- the ordered redaction rules (id, string key, applier)
# redact($text, \%ctx) -- applies every rule in list order over the whole report text
#
# The bundle handler (Settings.pm), the settings page template and t/core/02_strings.t all read these two
# lists, so the page and the report cannot drift apart. This module requires NO Slim module (at file scope or
# inside the list subs): `perl -I. -MPlugins::SpotOn::Diagnostics` runs over archived log files, and
# 02_strings.t loads it without LMS stubs.
#
# Placeholders are numbered PER REPORT: the maps and counters live in the %ctx hash the caller passes in
# (a fresh hash per report), never in package variables. Two consecutive reports both start at 1.

use strict;
use warnings;

use Encode qw(encode);

# The repo's secret pattern, verbatim from tools/uat/extract-run.pl ($REDACT_RE): Soloist keys, auth_data
# values and Bearer tokens. t/core/09_settings_core.t pins that this stays equal.
our $SECRET_RE = qr/spak_[A-Za-z0-9_-]*|auth_data[^ ]*|Bearer [A-Za-z0-9._-]+/;

sub sections {
    return (
        { id => 'system',      title => 'PLUGIN_SPOTON_DIAG_SEC_SYSTEM',      desc => 'PLUGIN_SPOTON_DIAG_SEC_SYSTEM_DESC',      collector => '_collectSystem' },
        { id => 'backend',     title => 'PLUGIN_SPOTON_DIAG_SEC_BACKEND',     desc => 'PLUGIN_SPOTON_DIAG_SEC_BACKEND_DESC',     collector => '_collectBackend' },
        { id => 'players',     title => 'PLUGIN_SPOTON_DIAG_SEC_PLAYERS',     desc => 'PLUGIN_SPOTON_DIAG_SEC_PLAYERS_DESC',     collector => '_collectPlayers' },
        { id => 'environment', title => 'PLUGIN_SPOTON_DIAG_SEC_ENV',         desc => 'PLUGIN_SPOTON_DIAG_SEC_ENV_DESC',         collector => '_collectEnvironment' },
        { id => 'transcoding', title => 'PLUGIN_SPOTON_DIAG_SEC_TRANSCODING', desc => 'PLUGIN_SPOTON_DIAG_SEC_TRANSCODING_DESC', collector => '_collectTranscoding' },
        { id => 'status',      title => 'PLUGIN_SPOTON_DIAG_SEC_STATUS',      desc => 'PLUGIN_SPOTON_DIAG_SEC_STATUS_DESC',      collector => '_collectStatus' },
        { id => 'daemonlogs',  title => 'PLUGIN_SPOTON_DIAG_SEC_DAEMONLOGS',  desc => 'PLUGIN_SPOTON_DIAG_SEC_DAEMONLOGS_DESC',  collector => '_collectDaemonLogs' },
        { id => 'serverlog',   title => 'PLUGIN_SPOTON_DIAG_SEC_SERVERLOG',   desc => 'PLUGIN_SPOTON_DIAG_SEC_SERVERLOG_DESC',   collector => '_collectServerLog' },
    );
}

# Order matters (research 2.4 rule 3): secrets first, then e-mail addresses (an id or display name that is the
# local part of an address would otherwise break the address apart; 79-75 IN-02), then the stored identities,
# then IP, MAC, device ids, paths. IP runs before MAC (79-75 WR-01): an IPv6 address whose groups are all two hex
# digits ("2001:db8:10:20:30:40:50:60") would otherwise be eaten as six-group MAC runs; a MAC is a six-group run
# and no valid IPv6 shape ("::" once and at most 7 groups, or exactly 8), so it survives the IP rule untouched.
sub redactions {
    return (
        { id => 'secrets',     key => 'PLUGIN_SPOTON_DIAG_RED_SECRETS',     apply => \&_redactSecrets },
        { id => 'emails',      key => 'PLUGIN_SPOTON_DIAG_RED_EMAILS',      apply => \&_redactEmails },
        { id => 'userids',     key => 'PLUGIN_SPOTON_DIAG_RED_USERIDS',     apply => \&_redactUserIds },
        { id => 'displayname', key => 'PLUGIN_SPOTON_DIAG_RED_DISPLAYNAME', apply => \&_redactDisplayNames },
        { id => 'lanips',      key => 'PLUGIN_SPOTON_DIAG_RED_LANIPS',      apply => \&_redactLanIps },
        { id => 'macs',        key => 'PLUGIN_SPOTON_DIAG_RED_MACS',        apply => \&_redactMacs },
        { id => 'deviceids',   key => 'PLUGIN_SPOTON_DIAG_RED_DEVICEIDS',   apply => \&_redactDeviceIds },
        { id => 'homepaths',   key => 'PLUGIN_SPOTON_DIAG_RED_HOMEPATHS',   apply => \&_redactHomePaths },
    );
}

# The six fixed keys of the transparency block on the settings page.
sub fixedKeys {
    return qw(
        PLUGIN_SPOTON_DIAG_SWITCH_TEXT
        PLUGIN_SPOTON_DIAG_SECTIONS_HEAD
        PLUGIN_SPOTON_DIAG_REDACTIONS_HEAD
        PLUGIN_SPOTON_DIAG_NOT_REDACTED
        PLUGIN_SPOTON_DIAG_LOCAL_ONLY
        PLUGIN_SPOTON_DIAG_OPEN_FIRST
    );
}

# What the report does NOT redact (shown on the page; player names and models, Spotify item ids and titles,
# versions and error texts stay readable).
sub notRedactedKey { 'PLUGIN_SPOTON_DIAG_NOT_REDACTED' }

sub redact {
    my ($text, $ctx) = @_;
    return $text unless defined $text && length $text;
    $ctx = {} unless ref $ctx eq 'HASH';
    $text = $_->{apply}->($text, $ctx) for redactions();
    return $text;
}

# ------------------------------------------------------------------
# secrets
# ------------------------------------------------------------------
sub _redactSecrets {
    my ($text, $ctx) = @_;
    return $text unless defined $text;
    $text =~ s/$SECRET_RE/[REDACTED]/g;
    # T-79-309: token key-values of the widened server.log extract (other modules' lines). The key and the
    # separator stay, the value goes. The value stops at whitespace, a comma, a semicolon, an ampersand, a
    # quote or a closing brace, so the JSON form keeps its structure.
    # No \b before the key (79-75 WR-02): a key that is the suffix of a longer key (client_secret, app_secret,
    # user_password, apiSecret) is still a key; the key stays, only the value goes.
    $text =~ s/((?:access_token|refresh_token|client_token|password|secret|sp_dc)["']?[ \t]*[=:][ \t]*["']?)[^\s,;&"'}]+/$1\[REDACTED]/gi;
    # librespot's own login line: Authenticated as '<user id>'
    $text =~ s/(Authenticated as ')[^']*(')/$1\[REDACTED]$2/g;
    return $text;
}

# ------------------------------------------------------------------
# stored Spotify user ids (79-43 D-33 FULL-3 WR-01, 79-44 WR-04)
#
# Replaces every stored spotifyUserId with [REDACTED] in each form it can take in the report: the stored value,
# its UTF-8 bytes (as a log file holds it) and its URI escape (as a spclient path holds it, matched
# case-insensitively). quotemeta, longest first. An id is replaced as a TOKEN, not as a substring: no word
# character (or % escape byte) directly before or after it, and case-sensitive (ids are). Only the URI-escape
# form, whose hex digits a log may print in either case, stays case-insensitive. A short id ("max") therefore
# does not eat HOLD_MAX_S or Maxwell.
# ------------------------------------------------------------------
sub _redactUserIds {
    my ($text, $ctx) = @_;
    return $text unless defined $text && length $text;
    my $accounts = $ctx->{accounts};
    return $text unless ref($accounts) eq 'HASH';
    my (%forms, %escForms);
    for my $acct (values %$accounts) {
        next unless ref($acct) eq 'HASH';
        my $uid = $acct->{spotifyUserId};
        next unless defined $uid && !ref($uid) && length($uid) >= 3;
        require URI::Escape;
        $forms{$uid} = 1;
        $forms{ encode('UTF-8', $uid) } = 1;
        my $esc = URI::Escape::uri_escape(encode('UTF-8', $uid));   # = uri_escape_utf8, for either representation
        if (exists $forms{$esc} || $esc eq $uid) { $forms{$esc} = 1; }    # nothing escaped: stays case-sensitive
        else                                      { $escForms{$esc} = 1; }
    }
    return $text unless %forms || %escForms;
    my $by  = sub { length($b) <=> length($a) || $a cmp $b };
    my @alt = ((map { quotemeta } sort $by keys %forms), (map { '(?i:' . quotemeta($_) . ')' } sort $by keys %escForms));
    my $alt = join '|', @alt;
    $text =~ s/(?<![A-Za-z0-9_%])(?:$alt)(?![A-Za-z0-9_])/[REDACTED]/g;
    return $text;
}

# ------------------------------------------------------------------
# Spotify display name (D-44)
#
# Every stored displayName (length >= 2) becomes [REDACTED], as a TOKEN like the user id: no word character or
# % escape byte directly before or after it, case-sensitive, quotemeta, longest first. A name that is also a
# hex octet ("Ed") must not eat a MAC: a match directly after `<hex>:` or directly before `:<hex>` is skipped.
# ------------------------------------------------------------------
sub _redactDisplayNames {
    my ($text, $ctx) = @_;
    return $text unless defined $text && length $text;
    my $accounts = $ctx->{accounts};
    return $text unless ref($accounts) eq 'HASH';
    my %names;
    for my $acct (values %$accounts) {
        next unless ref($acct) eq 'HASH';
        my $n = $acct->{displayName};
        next unless defined $n && !ref($n) && length($n) >= 2;
        $names{$n} = 1;
        $names{ encode('UTF-8', $n) } = 1;
    }
    return $text unless %names;
    my $by  = sub { length($b) <=> length($a) || $a cmp $b };
    my $alt = join '|', map { quotemeta } sort $by keys %names;
    $text =~ s/(?<![A-Za-z0-9_%])(?<![0-9A-Fa-f]:)(?:$alt)(?![A-Za-z0-9_])(?!:[0-9A-Fa-f]{2})/[REDACTED]/g;
    return $text;
}

# ------------------------------------------------------------------
# player MACs (D-44)
#
# Colon form  xx:xx:xx:xx:xx:xx  ->  <first three octets>:Player-N
# Bare form   12 hex digits      ->  <first six hex>-Player-N
# Both forms of the same MAC get the same N. N comes from the ordered client list ($ctx->{macs}, lower-case
# colon MACs) first, then from first appearance in the text. A bare 12-hex string is only treated as a MAC when
# it is in the map, matches a colon MAC seen in the same text, or directly precedes -soloist.log, -unified.log
# or -connect.log (the daemon log file names); any other 12-hex string stays, it may be a hash.
# The map and the counter live in %$ctx only.
# ------------------------------------------------------------------
sub _redactMacs {
    my ($text, $ctx) = @_;
    return $text unless defined $text && length $text;
    my $map = $ctx->{macmap} ||= {};
    $ctx->{macn} //= 0;
    unless ($ctx->{macseeded}) {
        for my $m (@{ $ctx->{macs} || [] }) {
            (my $k = lc $m) =~ s/://g;
            next unless $k =~ /^[0-9a-f]{12}$/;
            $map->{$k} //= ++$ctx->{macn};
        }
        $ctx->{macseeded} = 1;
    }
    my %known;
    while ($text =~ /(?<![0-9A-Za-z])((?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2})/g) {
        (my $k = lc $1) =~ s/://g;
        $known{$k} = 1;
    }
    my $repl = sub {
        my ($colon, $bare, $suffix) = @_;
        if (defined $colon) {
            (my $k = lc $colon) =~ s/://g;
            my $n = ($map->{$k} //= ++$ctx->{macn});
            return lc(substr($colon, 0, 8)) . ":Player-$n";
        }
        my $k = lc $bare;
        return $bare unless exists $map->{$k} || $known{$k} || defined $suffix;
        my $n = ($map->{$k} //= ++$ctx->{macn});
        return lc(substr($bare, 0, 6)) . "-Player-$n";
    };
    # The colon form carries NO hex lookarounds: LMS prints `...resume (2205) <mac>fadein=undef` with the next
    # word glued to the MAC (79-29 server.log, 5 lines). The bare form keeps them (any 12-hex run may be a hash).
    # 79-75 IN-R1-04: the colon form does not start right behind a letter or digit (a key such as `mac:` or `face:`
    # ends in two hex letters and would otherwise start the match inside the key). The archive (1.69 M MAC
    # occurrences) shows no alphanumeric directly before a MAC; `_client:<mac>`, `id:<mac>`, `[<mac>]` pass.
    $text =~ s{(?:(?<![0-9A-Za-z])((?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2})|(?<![0-9A-Fa-f])([0-9A-Fa-f]{12})(?![0-9A-Fa-f])(?=(-(?:soloist|unified|connect)\.log)?))}
              {$repl->($1, $2, $3)}ge;
    return $text;
}

# ------------------------------------------------------------------
# IP addresses (D-44, owner decision 2026-11-04 for IPv6)
#
# Private IPv4 (10/8, 172.16/12, 192.168/16, 169.254/16) -> LAN-N. IPv6: link-local and unique-local
# (fe80::/10, fc00::/7) -> LAN6-N, every other (GLOBAL) address -> IP6-N; a %<zone> suffix stays. Public IPv4
# addresses stay. The same address gets the same N within one report (maps in %$ctx, one per kind).
# A dotted version string ("1.10.0.2.3") is no IPv4 address: no digit or dot directly before, no digit or
# ".digit" directly after. An IPv6 CANDIDATE is a run of hex groups joined by colons with no word character or
# colon directly before and no word character, colon or ".digit" after; it counts as an address only when it is a
# valid shape ("::" once and at most 7 groups, or exactly 8 groups) and, for a global one, holds a digit - so the
# Perl module names `Dead::Beef` and `Plugins::SpotOn::API::Client`, times, ratios and "::" alone stay.
# ------------------------------------------------------------------
my $OCT = qr/(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])/;
my $LAN4_RE = qr/(?<![0-9.])(?:10\.$OCT\.$OCT\.$OCT|172\.(?:1[6-9]|2[0-9]|3[01])\.$OCT\.$OCT|192\.168\.$OCT\.$OCT|169\.254\.$OCT\.$OCT)(?![0-9]|\.[0-9])/;
my $IP6_RE  = qr/(?<![\w:.])((?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4})(%[A-Za-z0-9_.-]+)?(?![\w:])(?!\.\w)/;

sub _redactLanIps {
    my ($text, $ctx) = @_;
    return $text unless defined $text && length $text;
    my $m4 = $ctx->{ip4map} ||= {};
    $ctx->{ip4n} //= 0;
    $text =~ s{($LAN4_RE)}{ 'LAN-' . ($m4->{$1} //= ++$ctx->{ip4n}) }ge;
    $text =~ s{$IP6_RE}{ _ip6($1, $2, $ctx) }ge;
    return $text;
}

# Validates an IPv6 candidate and returns LAN6-N / IP6-N (+ zone), or the candidate unchanged when it is no address.
sub _ip6 {
    my ($addr, $zone, $ctx) = @_;
    $zone = '' unless defined $zone;
    my $keep = $addr . $zone;
    return $keep if $addr =~ /:::/;
    my $dbl = () = $addr =~ /::/g;
    return $keep if $dbl > 1;
    my @groups;
    if ($dbl) {
        my ($l, $r) = split /::/, $addr, 2;
        $r = '' unless defined $r;
        my @l = length $l ? split(/:/, $l, -1) : ();
        my @r = length $r ? split(/:/, $r, -1) : ();
        @groups = (@l, @r);
        return $keep if @groups > 7 || !@groups;
    }
    else {
        @groups = split /:/, $addr, -1;
        return $keep unless @groups == 8;
    }
    return $keep if grep { !/^[0-9A-Fa-f]{1,4}$/ } @groups;

    my $first = lc($dbl && $addr =~ /^::/ ? '' : $groups[0]);
    my $local = $first =~ /^fe[89ab][0-9a-f]$/ || $first =~ /^f[cd][0-9a-f]{2}$/;
    if ($local) {
        my $n = ($ctx->{ip6map}{lc $addr} //= ++$ctx->{ip6n});
        return "LAN6-$n$zone";
    }
    return $keep unless $addr =~ /[0-9]/;
    my $n = ($ctx->{gip6map}{lc $addr} //= ++$ctx->{gip6n});
    return "IP6-$n$zone";
}

# ------------------------------------------------------------------
# device ids (D-44)
#
# Two passes. LEARN the values from the shapes that name one -- `device_id=<uuid>` (Soloist) and
# `Device ID: <16 hex>` (librespot) with the separator `=` or `:` REQUIRED (a separator-less "device id <hex>"
# is not a shape), `from <id>` on a librespot_connect::spirc line (the sender of a cluster update or an
# endpoint call: the Soloist id, the librespot id and the ids of other Connect devices, 16 or 40 hex) and
# `active device: <id>`. The value stops at the first byte that is neither hex nor `-` (an ANSI reset after a
# Soloist uuid is not part of it), and the trailing lookahead rejects a longer alphanumeric token. N by first
# appearance in $ctx->{devmap}. Then REPLACE every learned value wherever it occurs (URL path segments and
# `from <id>` lines included), longest first, case-insensitive, with alnum lookarounds. A hex token that never
# appears behind a learn shape stays (it may be a hash).
# ------------------------------------------------------------------
my $DEVICE_LEARN_RE = qr/(?:device[ _-]?id[ \t]*[=:][ \t]*|librespot_connect::spirc\].*?\bfrom |active device: )([0-9a-f]{8,}(?:-[0-9a-f]{4,}){0,4})(?![0-9A-Za-z])/i;

sub _redactDeviceIds {
    my ($text, $ctx) = @_;
    return $text unless defined $text && length $text;
    my $map = $ctx->{devmap} ||= {};
    $ctx->{devn} //= 0;
    while ($text =~ /$DEVICE_LEARN_RE/g) {
        $map->{lc $1} //= ++$ctx->{devn};
    }
    return $text unless %$map;
    my $by  = sub { length($b) <=> length($a) || $a cmp $b };
    my $alt = join '|', map { quotemeta } sort $by keys %$map;
    $text =~ s{(?<![0-9A-Za-z])($alt)(?![0-9A-Za-z])}{ 'DEVICE-' . $map->{lc $1} }gie;
    return $text;
}

# ------------------------------------------------------------------
# home paths, e-mail addresses
# ------------------------------------------------------------------
sub _redactHomePaths {
    my ($text, $ctx) = @_;
    return $text unless defined $text && length $text;
    $text =~ s{(?<![A-Za-z0-9_.-])/(?:home|Users)/[^/\s"'\\:]+}{~}g;
    $text =~ s{(?<![A-Za-z0-9_])[A-Za-z]:\\Users\\[^\\\s"'/:]+}{~}g;
    return $text;
}

sub _redactEmails {
    my ($text, $ctx) = @_;
    return $text unless defined $text && length $text;
    $text =~ s/[A-Za-z0-9._%+-]+\@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+/[REDACTED]/g;
    return $text;
}

1;

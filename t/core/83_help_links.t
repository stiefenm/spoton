#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use Test::More;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# quick 261115-k6r: help and feedback links on the settings page, homepage metadata.
#
# Every gate is a pure function returning a list of problems. Each one is asserted
# twice: on the real file (empty list) and on a named in-memory mutant of the real
# text (non-empty list). isnt($mutant, $real) comes first so a mutation that did not
# apply fails instead of passing silently. Mutations never touch the checkout.
#
# Core modules only in the always-on legs: the local suite sees the LMS tree under
# /usr/share/perl5, CI does not. LMS-CPAN legs (Template::Parser, XML::Simple) SKIP
# with a reason when the module cannot be loaded.

binmode(Test::More->builder->output,         ':encoding(UTF-8)');
binmode(Test::More->builder->failure_output, ':encoding(UTF-8)');
binmode(Test::More->builder->todo_output,    ':encoding(UTF-8)');

# Resolve the project root: t/<group>/x.t sits two levels below it.
# Wrong depth must die, never skip (84-09: a silent skip-all reads as green).
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

my $INSTALL_XML = "$project_dir/Plugins/SpotOn/install.xml";
my $BASIC_HTML  = "$project_dir/Plugins/SpotOn/HTML/EN/plugins/SpotOn/settings/basic.html";
my $STRINGS     = "$project_dir/Plugins/SpotOn/strings.txt";

sub slurp {
    my ($file, $enc) = @_;
    open(my $fh, $enc ? '<:encoding(UTF-8)' : '<:raw', $file) or die "cannot read $file: $!";
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t;
}

my $install = slurp($INSTALL_XML);
my $html    = slurp($BASIC_HTML);
my $strings = slurp($STRINGS, 1);

my $PROJECT_URL = 'https://github.com/stiefenm/spoton';
my @LANGS       = qw(CS DA DE EN ES FR IT NL NO PL SV);
my $LANG_JOIN   = join(',', @LANGS);

my $HR = q{<hr style="margin:16px 0; border:0; border-top:1px solid rgba(128,128,128,0.25)"/>};
my $REL         = 'rel="noopener noreferrer"';
my $HELP_H2_KEY = q{'PLUGIN_SPOTON_SETTINGS_HELP_SECTION'};
my $DIAG_H2_KEY = q{'PLUGIN_SPOTON_SETTINGS_DIAG_SECTION'};

# --- helpers -----------------------------------------------------------------

# key => { LANG => value }; same regexes as t/core/02_strings.t
sub langs_of {
    my ($text) = @_;
    my (%langs_of, $cur);
    for my $line (split /\n/, $text) {
        if ($line =~ /^(PLUGIN_SPOTON\w*)\s*$/) { $cur = $1; next; }
        $langs_of{$cur}{$1} = $2 if defined $cur && $line =~ /^\t([A-Z]{2})\t(.+)$/;
    }
    return \%langs_of;
}

# Substring from the first $from to the first $to after it; undef when either is missing.
sub region {
    my ($text, $from, $to) = @_;
    my $s = index($text, $from);
    return undef if $s < 0;
    my $e = index($text, $to, $s + length $from);
    return undef if $e < 0;
    return substr($text, $s, $e - $s);
}

sub help_region {
    my ($text) = @_;
    return region($text, $HELP_H2_KEY, $DIAG_H2_KEY);
}

# Apply $code (gets a writable copy of the help region in $_[0]) and splice it back.
sub mutate_help {
    my ($text, $code) = @_;
    my $reg = help_region($text);
    return $text unless defined $reg;
    my $new = $reg;
    $code->($new);
    my $out = $text;
    substr($out, index($text, $HELP_H2_KEY), length $reg, $new);
    return $out;
}

sub np { my $n = () = @_; return $n; }

sub count_of {
    my ($text, $needle) = @_;
    my $n = 0;
    my $pos = 0;
    while (($pos = index($text, $needle, $pos)) >= 0) { $n++; $pos += length $needle; }
    return $n;
}

# --- gate: install.xml homepageURL --------------------------------------------

sub check_homepage {
    my ($text) = @_;
    my $want = "<homepageURL>$PROJECT_URL</homepageURL>";
    my $n = count_of($text, $want);
    return $n == 1 ? () : ("install.xml has $n homepageURL lines for $PROJECT_URL, want 1");
}

# --- gate: section placement ---------------------------------------------------

sub check_section {
    my ($text) = @_;
    my @p;
    my $help_h2 = "<h2>[% $HELP_H2_KEY | string %]</h2>";

    my $hr_re = qr/\Q$HR\E\s*\n\s*\Q$help_h2\E/;
    my $hr_n = () = $text =~ /$hr_re/g;
    push @p, "hr plus HELP h2 occurs $hr_n times, want 1" unless $hr_n == 1;

    my $g = index($text, q{'PLUGIN_SPOTON_SETTINGS_GLOBAL_SECTION'});
    my $h = index($text, $HELP_H2_KEY);
    my $d = index($text, $DIAG_H2_KEY);
    if ($g < 0 || $h < 0 || $d < 0) {
        push @p, "GLOBAL/HELP/DIAG h2 missing (global=$g help=$h diag=$d)";
        return @p;
    }
    push @p, "order is not GLOBAL < HELP < DIAG" unless $g < $h && $h < $d;

    my $between = region($text, $help_h2, "<h2>[% $DIAG_H2_KEY");
    $between = substr($between, length $help_h2) if defined $between;
    if (!defined $between) {
        push @p, "region HELP h2 .. DIAG h2 not found";
    } else {
        my $h2n = () = $between =~ /<h2\b/g;
        push @p, "$h2n h2 between HELP and DIAG, want 0" unless $h2n == 0;
    }

    my $outer = region($text, q{'PLUGIN_SPOTON_SETTINGS_GLOBAL_SECTION'}, $HELP_H2_KEY);
    if (defined $outer) {
        my $open  = () = $outer =~ /<div\b/g;
        my $close = () = $outer =~ m{</div>}g;
        push @p, "GLOBAL..HELP has $open div openers vs $close closers (section inside #librespot-fields?)"
            unless $open == $close;
    }
    return @p;
}

# --- gate: links carry target and rel ------------------------------------------

sub check_links {
    my ($text, @urls) = @_;
    my @p;
    my $reg = help_region($text);
    return ('help region not found') unless defined $reg;
    for my $url (@urls) {
        my $re = qr/<a href="\Q$url\E" target="_blank" \Q$REL\E(?=[ >])/;
        my $n  = () = $reg =~ /$re/g;
        push @p, "$url occurs $n times with target+rel in the help region, want 1" unless $n == 1;
    }
    my $all  = () = $reg =~ /<a /g;
    my $good = () = $reg =~ /<a href="[^"]*" target="_blank" \Q$REL\E/g;
    push @p, "$all anchors in the help region but $good carry target+rel" unless $all == $good;
    return @p;
}

# --- gate: help section is not inside any conditional or loop block -------------
# WR-03: placement was checked through <div> counts only, so wrapping the section
# (or one row) in [% IF backend == 'soloist' %] stayed green.
sub check_unconditional {
    my ($text) = @_;
    my $reg = help_region($text);
    return ('help region not found') unless defined $reg;
    my @p;
    my %n;
    $n{$1}++ while $reg =~ /\[%-?\s*(\w+)/g;
    for my $w (qw(IF UNLESS ELSIF ELSE FOREACH FOR WHILE SWITCH)) {
        push @p, "help region holds a $w directive" if $n{$w};
    }
    my ($ro, $re) = (0, 0);
    for my $w (keys %n) {
        $ro += $n{$w} if $w =~ /^(?:WRAPPER|BLOCK|FILTER)$/;
    }
    $re = $n{END} || 0;
    push @p, "help region has $ro block openers vs $re END" unless $ro == $re;
    my $pre = substr($text, 0, index($text, $HELP_H2_KEY));
    my ($o, $e) = (0, 0);
    while ($pre =~ /\[%-?\s*(\w+)/g) {
        my $w = $1;
        $o++ if $w =~ /^(?:IF|UNLESS|FOREACH|FOR|WHILE|WRAPPER|BLOCK|SWITCH|FILTER)$/;
        $e++ if $w eq 'END';
    }
    push @p, "HELP h2 sits inside an open block ($o openers, $e END before it)" unless $o == $e;
    return @p;
}

# --- gate: every key named in the template exists in all eleven languages ------

sub missing_keys {
    my ($h, $s) = @_;
    my $langs = langs_of($s);
    my %seen;
    $seen{$_} = 1 for $h =~ /(PLUGIN_SPOTON_[A-Z0-9_]+)/g;
    my @p;
    for my $k (sort keys %seen) {
        my $got = join(',', sort keys %{ $langs->{$k} || {} });
        push @p, "$k has [$got]" unless $got eq $LANG_JOIN;
    }
    return @p;
}

# --- gate: template directives balance -----------------------------------------

sub tt_balance {
    my ($h) = @_;
    my @p;
    my $open  = () = $h =~ /\[%/g;
    my $close = () = $h =~ /%\]/g;
    push @p, "[% count $open vs %] count $close" unless $open == $close;
    my ($blocks, $ends) = (0, 0);
    while ($h =~ /\[%-?\s*(.*?)\s*-?%\]/gs) {
        my $body = $1;
        next unless $body =~ /^(\w+)/;
        my $w = $1;
        $blocks++ if $w =~ /^(?:IF|UNLESS|FOREACH|FOR|WHILE|WRAPPER|BLOCK|SWITCH|FILTER)$/;
        $ends++   if $w eq 'END';
    }
    push @p, "block openers $blocks vs END $ends" unless $blocks == $ends;
    return @p;
}

# --- gate: strings in eleven languages, no en/em dash --------------------------

sub check_strings {
    my ($s, @keys) = @_;
    my $langs = langs_of($s);
    my @p;
    for my $k (@keys) {
        my $got = join(',', sort keys %{ $langs->{$k} || {} });
        push @p, "$k has [$got], want [$LANG_JOIN]" unless $got eq $LANG_JOIN;
        for my $l (sort keys %{ $langs->{$k} || {} }) {
            push @p, "$k $l holds an en or em dash"
                if $langs->{$k}{$l} =~ /[\x{2013}\x{2014}]/;
        }
    }
    return @p;
}

# strings.txt mutators (text in, text out)
sub strip_lang {
    my ($s, $key, $lang) = @_;
    $s =~ s/(^\Q$key\E\n(?:\t[A-Z]{2}\t[^\n]*\n)*?)\t\Q$lang\E\t[^\n]*\n/$1/m;
    return $s;
}

sub append_to_lang {
    my ($s, $key, $lang, $extra) = @_;
    $s =~ s/(^\Q$key\E\n(?:\t[A-Z]{2}\t[^\n]*\n)*?\t\Q$lang\E\t[^\n]*)/$1$extra/m;
    return $s;
}

# =============================================================================
# Task 1 cells
# =============================================================================

# --- homepageURL ---
{
    my @p = check_homepage($install);
    is(scalar(@p), 0, 'install.xml carries exactly one homepageURL') or diag(join("\n", @p));

    (my $mut = $install) =~ s{^[ \t]*<homepageURL>[^\n]*\n}{}m;
    ok($mut ne $install, 'mutant applied: homepageURL line removed');
    ok(np(check_homepage($mut)) > 0, 'mutant without homepageURL is reported');
}

# --- section placement ---
{
    my @p = check_section($html);
    is(scalar(@p), 0, 'Help & feedback section sits between #librespot-fields and Diagnostics')
        or diag(join("\n", @p));

    (my $m1 = $html) =~ s{^[ \t]*<h2>\[% \Q$HELP_H2_KEY\E \| string %\]</h2>\n}{}m;
    ok($m1 ne $html, 'mutant applied: HELP h2 line removed');
    ok(np(check_section($m1)) > 0, 'mutant without the HELP h2 is reported');

    (my $m2 = $html) =~ s{(\Q$HR\E\s*\n\s*<h2>\[% \Q$HELP_H2_KEY\E)}{<div>\n\t$1};
    ok($m2 ne $html, 'mutant applied: bare div inserted before the HELP hr');
    ok(np(check_section($m2)) > 0, 'mutant with a div opened before HELP is reported');
}

# --- links: project URL with target and rel ---
{
    my @p = check_links($html, $PROJECT_URL);
    is(scalar(@p), 0, 'project link carries target=_blank rel="noopener noreferrer"') or diag(join("\n", @p));

    my $mut = mutate_help($html, sub { $_[0] =~ s/ \Q$REL\E// });
    ok($mut ne $html, 'mutant applied: first rel removed from the help region');
    ok(np(check_links($mut, $PROJECT_URL)) > 0, 'mutant without rel is reported');

    # IN-01: noreferrer dropped from one anchor must be reported
    my $nr = mutate_help($html, sub { $_[0] =~ s/rel="noopener noreferrer"/rel="noopener"/ });
    ok($nr ne $html, 'mutant applied: noreferrer dropped from the first help anchor');
    ok(np(check_links($nr, $PROJECT_URL)) > 0, 'mutant with the first anchor lacking noreferrer is reported');

    my $nr_all = mutate_help($html, sub { $_[0] =~ s/rel="noopener noreferrer"/rel="noopener"/g });
    ok($nr_all ne $html, 'mutant applied: noreferrer dropped from every help anchor');
    ok(np(check_all_links($nr_all)) > 0, 'mutant with no anchor carrying noreferrer is reported');
}

# --- strings: every key named in the template exists in eleven languages ---
{
    my @p = missing_keys($html, $strings);
    is(scalar(@p), 0, 'every PLUGIN_SPOTON_* key in basic.html has all eleven languages')
        or diag(join("\n", @p));

    my $mut = $html . "\n[% 'PLUGIN_SPOTON_HELP_NOPE' | string %]\n";
    my @q = missing_keys($mut, $strings);
    is(scalar(@q), 1, 'mutant naming an unknown key yields exactly one problem');
    like($q[0] // '', qr/PLUGIN_SPOTON_HELP_NOPE/, 'the problem names the unknown key');
}

# --- template directives balance ---
{
    my @p = tt_balance($html);
    is(scalar(@p), 0, 'basic.html directives balance') or diag(join("\n", @p));

    (my $mut = $html) =~ s/\[% END %\]//;
    ok($mut ne $html, 'mutant applied: first [% END %] removed');
    ok(np(tt_balance($mut)) > 0, 'mutant with a missing END is reported');

    push @INC, '/usr/share/squeezeboxserver/CPAN' if -d '/usr/share/squeezeboxserver/CPAN';
    SKIP: {
        skip 'Template::Parser not loadable (CI has no LMS CPAN tree); the directive count still runs', 2
            unless eval { require Template::Parser; 1 };
        ok(Template::Parser->new({})->parse($html), 'Template::Parser parses the real template');
        ok(!Template::Parser->new({})->parse($mut), 'Template::Parser rejects the mutant without END');
    }
}

# --- strings of the Task 1 keys ---
{
    my @t1 = qw(PLUGIN_SPOTON_SETTINGS_HELP_SECTION PLUGIN_SPOTON_HELP_PROJECT);
    my @p = check_strings($strings, @t1);
    is(scalar(@p), 0, 'Task 1 keys exist in eleven languages without en or em dash') or diag(join("\n", @p));

    my $l = langs_of($strings);
    is($l->{PLUGIN_SPOTON_SETTINGS_HELP_SECTION}{EN}, 'Help & feedback', 'HELP_SECTION EN');
    is($l->{PLUGIN_SPOTON_SETTINGS_HELP_SECTION}{DE}, 'Hilfe & Feedback', 'HELP_SECTION DE');
    is($l->{PLUGIN_SPOTON_HELP_PROJECT}{EN}, 'Project page and documentation', 'HELP_PROJECT EN');
    is($l->{PLUGIN_SPOTON_HELP_PROJECT}{DE}, 'Projektseite und Dokumentation', 'HELP_PROJECT DE');

    my $m1 = strip_lang($strings, 'PLUGIN_SPOTON_HELP_PROJECT', 'SV');
    ok($m1 ne $strings, 'mutant applied: SV line of HELP_PROJECT removed');
    ok(np(check_strings($m1, @t1)) > 0, 'mutant with a missing language is reported');

    my $m2 = append_to_lang($strings, 'PLUGIN_SPOTON_HELP_PROJECT', 'EN', " \x{2014} x");
    ok($m2 ne $strings, 'mutant applied: em dash appended to HELP_PROJECT EN');
    ok(np(check_strings($m2, @t1)) > 0, 'mutant with an em dash is reported');
}

# =============================================================================
# Task 2 cells
# =============================================================================

my @ALL_URLS = (
    $PROJECT_URL,
    "$PROJECT_URL/blob/main/TROUBLESHOOTING.md",
    "$PROJECT_URL/issues/new/choose",
    "$PROJECT_URL/issues?q=is%3Aissue+is%3Aopen+label%3Arelease-status",
    'https://forums.lyrion.org/forum/user-forums/3rd-party-software/1826188-announce-spoton-%E2%80%94-spotify-plugin-for-lms-alternative-to-spotty',
    'https://github.com/sponsors/stiefenm',
    'https://ko-fi.com/stiefenm',
);
my $FORUM_URL = $ALL_URLS[4];

my @ROW_KEYS = qw(
    PLUGIN_SPOTON_HELP_PROJECT PLUGIN_SPOTON_HELP_UPGRADE PLUGIN_SPOTON_HELP_TROUBLESHOOT PLUGIN_SPOTON_HELP_REPORT
    PLUGIN_SPOTON_HELP_RELEASE_STATUS PLUGIN_SPOTON_HELP_FORUM PLUGIN_SPOTON_HELP_SUPPORT
);

my @T2_KEYS = qw(
    PLUGIN_SPOTON_HELP_TROUBLESHOOT PLUGIN_SPOTON_HELP_REPORT PLUGIN_SPOTON_HELP_REPORT_DESC
    PLUGIN_SPOTON_HELP_RELEASE_STATUS PLUGIN_SPOTON_HELP_RELEASE_STATUS_DESC
    PLUGIN_SPOTON_HELP_FORUM PLUGIN_SPOTON_HELP_SUPPORT PLUGIN_SPOTON_HELP_SUPPORT_DESC
);

# all seven URLs: target+rel in the help region, and exactly once in the whole template
sub check_all_links {
    my ($text) = @_;
    my @p = check_links($text, @ALL_URLS);
    for my $u (@ALL_URLS) {
        my $n = count_of($text, qq{href="$u"});
        push @p, "$u is linked $n times in the template, want 1" unless $n == 1;
    }
    return @p;
}

sub check_setup_box {
    my ($text) = @_;
    my $box = region($text, 'id="spoton-setup"', 'title="PLUGIN_SPOTON_ACCOUNT_SETTINGS"');
    return ('setup box region not found') unless defined $box;
    my @p;
    push @p, 'setup box still names TROUBLESHOOTING.md' if index($box, 'TROUBLESHOOTING.md') >= 0;
    push @p, 'setup box still uses PLUGIN_SPOTON_SETUP_TROUBLESHOOT' if index($box, 'PLUGIN_SPOTON_SETUP_TROUBLESHOOT') >= 0;
    return @p;
}

sub check_rows {
    my ($text) = @_;
    my $reg = help_region($text);
    return ('help region not found') unless defined $reg;
    my @got;
    while ($reg =~ /WRAPPER setting title="([^"]*)" desc="([^"]*)"/g) { push @got, $2 eq '' ? $1 : "$1(desc=$2)"; }
    return join(',', @got) eq join(',', @ROW_KEYS) ? () : ('help rows are [' . join(',', @got) . '], want [' . join(',', @ROW_KEYS) . ']');
}

sub check_visible {
    my ($text) = @_;
    my @p;
    push @p, 'a help key sits in a hidden desc=' if $text =~ /desc="PLUGIN_SPOTON_HELP_/;
    push @p, 'the troubleshooting hint sits in a hidden desc=' if $text =~ /desc="PLUGIN_SPOTON_SETUP_TROUBLESHOOT/;
    my $reg = help_region($text);
    return (@p, 'help region not found') unless defined $reg;
    for my $k (qw(PLUGIN_SPOTON_SETUP_TROUBLESHOOT_HINT PLUGIN_SPOTON_SETUP_TROUBLESHOOT_LINK
                  PLUGIN_SPOTON_HELP_REPORT_DESC PLUGIN_SPOTON_HELP_RELEASE_STATUS_DESC PLUGIN_SPOTON_HELP_SUPPORT_DESC)) {
        my $n = count_of($reg, "'$k' | string");
        push @p, "$k is shown $n times in the help region, want 1" unless $n == 1;
    }
    return @p;
}

sub check_discreet {
    my ($text) = @_;
    my $row = region($text, 'title="PLUGIN_SPOTON_HELP_SUPPORT"', $DIAG_H2_KEY);
    return ('support row not found') unless defined $row;
    my @p;
    push @p, 'an anchor in the support row has a style attribute' if $row =~ /<a [^>]*\bstyle=/;
    push @p, 'support row uses font-weight' if $row =~ /font-weight/;
    push @p, 'support row uses <strong' if $row =~ /<strong/;
    push @p, 'support row uses <b>' if $row =~ /<b>/;
    push @p, 'support row uses <img' if $row =~ /<img/;
    push @p, 'support row names Spotify' if $row =~ /spotify/i;
    return @p;
}

sub check_register {
    my ($s) = @_;
    my $l = langs_of($s);
    my @p;
    for my $k (qw(PLUGIN_SPOTON_HELP_REPORT_DESC PLUGIN_SPOTON_HELP_SUPPORT_DESC)) {
        my $de = $l->{$k}{DE};
        push @p, "$k DE does not address the reader with Sie" unless defined $de && $de =~ /\bSie\b/;
    }
    for my $k (@T2_KEYS, qw(PLUGIN_SPOTON_SETTINGS_HELP_SECTION PLUGIN_SPOTON_HELP_PROJECT
                  PLUGIN_SPOTON_HELP_UPGRADE PLUGIN_SPOTON_UPGRADE_GUIDE_LINK)) {
        my $de = $l->{$k}{DE};
        push @p, "$k DE uses du-form" if defined $de && $de =~ /\b(?:du|dich|dir|dein\w*)\b/i;
    }
    for my $k (qw(PLUGIN_SPOTON_HELP_SUPPORT PLUGIN_SPOTON_HELP_SUPPORT_DESC)) {
        for my $lang (sort keys %{ $l->{$k} || {} }) {
            push @p, "$k $lang names Spotify" if $l->{$k}{$lang} =~ /spotify/i;
        }
    }
    return @p;
}

# --- all seven links ---
{
    my @p = check_all_links($html);
    is(np(@p), 0, 'all seven links sit in the help region with target+rel, once each') or diag(join("\n", @p));

    my $mut = mutate_help($html, sub {
        my $u = quotemeta($FORUM_URL);
        $_[0] =~ s/(<a href="$u" target="_blank") \Q$REL\E/$1/;
    });
    ok($mut ne $html, 'mutant applied: rel removed from the forum anchor');
    ok(np(check_all_links($mut)) > 0, 'mutant forum anchor without rel is reported');
}

# --- setup box no longer carries the troubleshooting paragraph ---
{
    my @p = check_setup_box($html);
    is(np(@p), 0, 'setup box holds no troubleshooting link or hint') or diag(join("\n", @p));

    (my $mut = $html) =~ s{(\[% WRAPPER setting title="PLUGIN_SPOTON_ACCOUNT_SETTINGS")}{<a href="$PROJECT_URL/blob/main/TROUBLESHOOTING.md">x</a>\n\t$1};
    ok($mut ne $html, 'mutant applied: troubleshooting anchor put back before the account wrapper');
    ok(np(check_setup_box($mut)) > 0, 'mutant with the anchor back in the setup box is reported');
}

# --- seven rows in order (quick 261115-lcq added the upgrade row as second) ---
{
    my @p = check_rows($html);
    is(np(@p), 0, 'help section holds the seven rows in order, desc empty') or diag(join("\n", @p));

    (my $mut = $html) =~ s{(\Q$HR\E\s*\n\s*<h2>\[% \Q$DIAG_H2_KEY\E)}{[% WRAPPER setting title="PLUGIN_SPOTON_HELP_FORUM" desc="" %][% END %]\n\t$1};
    ok($mut ne $html, 'mutant applied: second FORUM row before the Diagnostics hr');
    ok(np(check_rows($mut)) > 0, 'mutant with a duplicated row is reported');
}

# --- sentences are visible, not in the hidden desc ---
{
    my @p = check_visible($html);
    is(np(@p), 0, 'explanatory sentences sit in the row content') or diag(join("\n", @p));

    (my $mut = $html) =~ s{title="PLUGIN_SPOTON_HELP_SUPPORT" desc=""}{title="PLUGIN_SPOTON_HELP_SUPPORT" desc="PLUGIN_SPOTON_HELP_SUPPORT_DESC"};
    ok($mut ne $html, 'mutant applied: support sentence moved into desc=');
    ok(np(check_visible($mut)) > 0, 'mutant with a hidden desc is reported');
}

# --- the donation row is plain ---
{
    my @p = check_discreet($html);
    is(np(@p), 0, 'support row is plain: no emphasis, no icon, no Spotify wording') or diag(join("\n", @p));

    (my $mut = $html) =~ s{(href="https://ko-fi\.com/stiefenm" target="_blank" \Q$REL\E)}{$1 style="font-weight:bold"};
    ok($mut ne $html, 'mutant applied: bold style on the Ko-fi anchor');
    ok(np(check_discreet($mut)) > 0, 'mutant with emphasis is reported');
}

# --- WR-03: the section is unconditional ---
{
    my @p = check_unconditional($html);
    is(np(@p), 0, 'help section is not inside any IF/UNLESS/loop block') or diag(join("\n", @p));

    # the review's mutant: all rows wrapped in a backend conditional
    my $m1 = mutate_help($html, sub {
        $_[0] =~ s{(</h2>\s*\n)}{$1\t[% IF backend == 'soloist' %]\n};
        $_[0] =~ s{(\s*)\z}{\n\t[% END %]$1};
    });
    ok($m1 ne $html, "mutant applied: all rows wrapped in IF backend == 'soloist'");
    ok(np(check_unconditional($m1)) > 0, 'mutant with the rows inside an IF is reported');

    # the whole section (hr and h2 included) wrapped: the IF opens before the HELP h2
    (my $m2 = $html) =~ s{(\Q$HR\E\s*\n\s*<h2>\[% \Q$HELP_H2_KEY\E)}{[% IF backend == 'soloist' %]\n\t$1};
    $m2 =~ s{(\Q$HR\E\s*\n\s*<h2>\[% \Q$DIAG_H2_KEY\E)}{[% END %]\n\t$1};
    ok($m2 ne $html, 'mutant applied: IF opened before the HELP hr, END before the Diagnostics hr');
    ok(np(check_unconditional($m2)) > 0, 'mutant with the IF opened before the HELP h2 is reported');

    # one row only
    my $m3 = mutate_help($html, sub {
        $_[0] =~ s{(\[% WRAPPER setting title="PLUGIN_SPOTON_HELP_FORUM" desc="" %\])}{[% UNLESS prefs.x %]$1};
        $_[0] =~ s{(title="PLUGIN_SPOTON_HELP_FORUM".*?\[% END %\])}{$1\[% END %]}s;
    });
    ok($m3 ne $html, 'mutant applied: the forum row wrapped in UNLESS');
    ok(np(check_unconditional($m3)) > 0, 'mutant with one row inside an UNLESS is reported');
}

# --- strings of the Task 2 keys, plus the two reused ones ---
{
    my @keys = (@T2_KEYS, qw(PLUGIN_SPOTON_SETUP_TROUBLESHOOT_HINT PLUGIN_SPOTON_SETUP_TROUBLESHOOT_LINK));
    my @p = check_strings($strings, @keys);
    is(np(@p), 0, 'Task 2 and reused keys exist in eleven languages without en or em dash') or diag(join("\n", @p));

    my $l = langs_of($strings);
    my %pin = (
        PLUGIN_SPOTON_HELP_TROUBLESHOOT => ['Troubleshooting', 'Fehlerbehebung'],
        PLUGIN_SPOTON_HELP_REPORT => ['Report a problem', 'Problem melden'],
        PLUGIN_SPOTON_HELP_REPORT_DESC => [
            'Please attach the diagnostic report from the Diagnostics section below.',
            'Bitte hängen Sie den Diagnosebericht aus dem Abschnitt Diagnose unten an.'],
        PLUGIN_SPOTON_HELP_RELEASE_STATUS => ['Release status', 'Release-Status'],
        PLUGIN_SPOTON_HELP_RELEASE_STATUS_DESC => [
            'Known issues and the state of the current release.',
            'Bekannte Probleme und der Stand des aktuellen Release.'],
        PLUGIN_SPOTON_HELP_FORUM => ['Forum thread', 'Forum-Thread'],
        PLUGIN_SPOTON_HELP_SUPPORT => ['Support SpotOn', 'SpotOn unterstützen'],
        PLUGIN_SPOTON_HELP_SUPPORT_DESC => [
            'SpotOn is free. If you want to support its development, you can donate here. A donation is voluntary and unlocks nothing.',
            'SpotOn ist kostenlos. Wenn Sie die Entwicklung unterstützen möchten, können Sie hier spenden. Eine Spende ist freiwillig und schaltet nichts frei.'],
    );
    for my $k (sort keys %pin) {
        is($l->{$k}{EN}, $pin{$k}[0], "$k EN");
        is($l->{$k}{DE}, $pin{$k}[1], "$k DE");
    }

    my $m1 = strip_lang($strings, 'PLUGIN_SPOTON_HELP_FORUM', 'SV');
    ok($m1 ne $strings, 'mutant applied: SV line of HELP_FORUM removed');
    ok(np(check_strings($m1, @keys)) > 0, 'mutant with a missing HELP_FORUM language is reported');
}

# --- register: Sie, no Spotify wording ---
{
    my @p = check_register($strings);
    is(np(@p), 0, 'DE uses Sie, support strings name no Spotify') or diag(join("\n", @p));

    (my $m1 = $strings) =~ s/(^PLUGIN_SPOTON_HELP_SUPPORT_DESC\n(?:\t[A-Z]{2}\t[^\n]*\n)*?\tDE\t[^\n]*?)Wenn Sie/$1Wenn du/m;
    ok($m1 ne $strings, 'mutant applied: DE support sentence switched to du');
    ok(np(check_register($m1)) > 0, 'mutant with du-form is reported');

    my $m2 = append_to_lang($strings, 'PLUGIN_SPOTON_HELP_SUPPORT_DESC', 'EN', ' for Spotify');
    ok($m2 ne $strings, 'mutant applied: EN support sentence names Spotify');
    ok(np(check_register($m2)) > 0, 'mutant naming Spotify is reported');
}

# =============================================================================
# Task 3 cells
# =============================================================================

my $LINK_LINE_RE = qr{^\s*<link>https://github\.com/stiefenm/spoton</link>\s*$}m;

sub check_descriptor {
    my ($text) = @_;
    my @p;
    my @plugins = $text =~ m{<plugin\b([^>]*)>(.*?)</plugin>}sg;
    if (@plugins != 2) {
        return ('want exactly one <plugin> element, found ' . (@plugins / 2));
    }
    my ($attrs, $body) = @plugins;
    push @p, '<plugin> carries a link= attribute' if $attrs =~ /\blink=/;
    my $n = () = $body =~ /$LINK_LINE_RE/g;
    push @p, "<plugin> body has $n project link lines, want 1" unless $n == 1;
    my $all = () = $text =~ m{<link>}g;
    push @p, "file has $all <link> elements, want 1" unless $all == 1;
    return @p;
}

sub check_funding {
    my ($text) = @_;
    my @p;
    my $g = () = $text =~ /^github:\s*\[\s*stiefenm\s*\]\s*$/mg;
    my $k = () = $text =~ /^ko_fi:\s*stiefenm\s*$/mg;
    push @p, "FUNDING.yml has $g github lines, want 1" unless $g == 1;
    push @p, "FUNDING.yml has $k ko_fi lines, want 1" unless $k == 1;
    return @p;
}

push @INC, '/usr/share/squeezeboxserver/CPAN' if -d '/usr/share/squeezeboxserver/CPAN';

for my $rel ('repo.xml', 'docs/beta/repo.xml') {
    my $text = slurp("$project_dir/$rel");
    my @p = check_descriptor($text);
    is(np(@p), 0, "$rel has exactly one project <link> child in <plugin>") or diag(join("\n", @p));

    (my $mut = $text) =~ s/$LINK_LINE_RE\n?//;
    ok($mut ne $text, "mutant applied: link line removed from $rel");
    ok(np(check_descriptor($mut)) > 0, "mutant of $rel without the link is reported");

    SKIP: {
        skip 'XML::Simple not loadable (CI has no LMS CPAN tree); the regex leg still runs', 2
            unless eval { require XML::Simple; 1 };
        my $xml = eval {
            XML::Simple::XMLin($text,
                SuppressEmpty => undef,
                KeyAttr       => { title => 'lang', desc => 'lang', changes => 'lang' },
                ContentKey    => '-content',
                GroupTags     => {
                    applets => 'applet', sounds => 'sound', wallpapers => 'wallpaper',
                    plugins => 'plugin', patches => 'patch',
                },
                ForceArray    => [qw(applet wallpaper sound plugin patch title desc changes)],
            );
        };
        ok(defined $xml, "XMLin parses $rel with the LMS options") or diag($@);
        my $link = ref($xml) eq 'HASH' ? $xml->{plugins}[0]{link} : undef;
        ok(defined $link && !ref($link) && $link eq $PROJECT_URL,
            "LMS reads $rel link as the plain project URL string");
    }
}

{
    my $file = "$project_dir/.github/FUNDING.yml";
    ok(-f $file, '.github/FUNDING.yml exists');
    my $text = -f $file ? slurp($file) : '';
    my @p = check_funding($text);
    is(np(@p), 0, 'FUNDING.yml holds github: [stiefenm] and ko_fi: stiefenm') or diag(join("\n", @p));

    (my $mut = $text) =~ s/^ko_fi:[^\n]*\n?//m;
    ok($mut ne $text, 'mutant applied: ko_fi line removed');
    ok(np(check_funding($mut)) > 0, 'mutant without ko_fi is reported');
}

# =============================================================================
# quick 261115-lcq: upgrade guide (UPGRADING.md) and its links on the settings page
# =============================================================================
#
# Same rule as above: pure gates, the real file first, then named in-memory mutants,
# each mutant leg opening with 'mutant applied'. Core Perl only.

my $UPGRADING   = "$project_dir/UPGRADING.md";
my $TROUBLE     = "$project_dir/TROUBLESHOOTING.md";
my $UPGRADE_URL = "$PROJECT_URL/blob/main/UPGRADING.md";
my $NP_OPEN     = '[% FOREACH id IN needsPairingAccounts %]';

my @UPGRADE_SECTIONS = (
    'What changes in 4.0',
    'Right after the update',
    'If the pairing device does not appear',
    'Getting help',
    'Going back to 3.5.8',
);
my @UPGRADE_LITERALS = ('SpotOn Authorization', '__DISCOVER__', 'Local Network', 'Please pair this account once');

# A missing guide reads as empty text: the gate must report it, the test must not die.
my $upgrading = -f $UPGRADING ? slurp($UPGRADING, 1) : '';
my $trouble   = slurp($TROUBLE, 1);

# GitHub's heading anchor: lower case, drop everything that is neither a word
# character nor a space nor a hyphen, then each space becomes a hyphen.
sub slug_of {
    my ($heading) = @_;
    my $s = lc $heading;
    $s =~ s/[^\w \-]//g;
    $s =~ s/ /-/g;
    return $s;
}

# --- gate: the guide itself ----------------------------------------------------
# $exists is a code ref that gets a repo-relative path and says whether it is a file.
sub check_upgrade_doc {
    my ($text, $ts_text, $exists) = @_;
    return ('UPGRADING.md is missing or empty') unless defined $text && $text =~ /\S/;
    my @p;

    push @p, 'UPGRADING.md holds an en or em dash' if $text =~ /[\x{2013}\x{2014}]/;

    my @h2 = $text =~ /^## +(.*?)[ \t]*$/mg;
    push @p, 'sections are [' . join(' / ', @h2) . '], want [' . join(' / ', @UPGRADE_SECTIONS) . ']'
        unless join("\n", @h2) eq join("\n", @UPGRADE_SECTIONS);

    my %slug = map { slug_of($_) => 1 } $ts_text =~ /^#{1,6} +(.*?)[ \t]*$/mg;
    my $anchored = 0;
    while ($text =~ /\]\(([^)\s]+)\)/g) {
        my $target = $1;
        next if $target =~ m{^(?:https?://|#)};
        my ($path, $frag) = split /#/, $target, 2;
        push @p, "link target '$path' is not a file in the repo" unless length $path && $exists->($path);
        next unless $path eq 'TROUBLESHOOTING.md' && defined $frag;
        $anchored++;
        push @p, "TROUBLESHOOTING.md has no heading for #$frag" unless $slug{$frag};
    }
    push @p, 'UPGRADING.md links no TROUBLESHOOTING.md section' unless $anchored;

    for my $lit (@UPGRADE_LITERALS) {
        push @p, "UPGRADING.md does not name '$lit'" if index($text, $lit) < 0;
    }

    push @p, "UPGRADING.md holds the private address $1"
        if $text =~ /(?<![\d.])((?:10\.\d{1,3}|192\.168|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3})(?![\d.])/;
    push @p, "UPGRADING.md holds the e-mail address $1"
        if $text =~ /([\w.+\-]+\@[\w\-]+(?:\.[\w\-]+)+)/;
    return @p;
}

# --- gate: the link on the needs-pairing line ----------------------------------
sub check_pairing_link {
    my ($text) = @_;
    my $reg = region($text, $NP_OPEN, '[% END %]');
    return ('needs-pairing block not found') unless defined $reg;
    my $body = substr($reg, length $NP_OPEN);
    return ("needs-pairing block opens a nested $1, so its end cannot be located")
        if $body =~ /\[%-?\s*(IF|UNLESS|FOREACH|FOR|WHILE|WRAPPER|BLOCK|SWITCH|FILTER)\b/;

    my @p;
    my $text_n = count_of($body, q{'PLUGIN_SPOTON_ACCOUNT_NEEDS_PAIRING' | string});
    push @p, "the needs-pairing text occurs $text_n times in the block, want 1" unless $text_n == 1;

    my $all = () = $body =~ /<a /g;
    push @p, "$all anchors in the needs-pairing block, want 1" unless $all == 1;
    my $good = () = $body =~ /<a href="\Q$UPGRADE_URL\E" target="_blank" \Q$REL\E(?=[ >])/g;
    push @p, "$good anchors to $UPGRADE_URL with target+rel in the needs-pairing block, want 1" unless $good == 1;

    push @p, 'the upgrade anchor does not sit inside the needs-pairing paragraph'
        unless $body =~ m{<p class="needs-pairing"(?:(?!</p>).)*<a href="\Q$UPGRADE_URL\E"(?:(?!</p>).)*</p>}s;

    my $key_n = count_of($body, q{'PLUGIN_SPOTON_UPGRADE_GUIDE_LINK' | string});
    push @p, "the link text key occurs $key_n times in the block, want 1" unless $key_n == 1;
    return @p;
}

# Apply $code (gets a writable copy of the needs-pairing block in $_[0]) and splice it back.
sub mutate_np {
    my ($text, $code) = @_;
    my $reg = region($text, $NP_OPEN, '[% END %]');
    return $text unless defined $reg;
    my $new = $reg;
    $code->($new);
    my $out = $text;
    substr($out, index($text, $NP_OPEN), length $reg, $new);
    return $out;
}

# --- gate: the help row "Upgrading from 3.x" ------------------------------------
# The UPGRADING URL is linked twice by design (needs-pairing line, help row), so it
# is not part of @ALL_URLS with its once-only rule; the count is pinned here.
sub check_upgrade_row {
    my ($text) = @_;
    my @p = check_links($text, $UPGRADE_URL);

    my $reg = help_region($text);
    my $row = defined $reg ? region($reg, 'title="PLUGIN_SPOTON_HELP_UPGRADE"', '[% END %]') : undef;
    if (!defined $row) {
        push @p, 'help row PLUGIN_SPOTON_HELP_UPGRADE not found';
    } else {
        push @p, "the upgrade row holds no anchor to $UPGRADE_URL"
            unless index($row, qq{<a href="$UPGRADE_URL"}) >= 0;
        push @p, 'the upgrade row does not show PLUGIN_SPOTON_UPGRADE_GUIDE_LINK'
            unless index($row, q{'PLUGIN_SPOTON_UPGRADE_GUIDE_LINK' | string}) >= 0;
    }

    my $n = count_of($text, qq{href="$UPGRADE_URL"});
    push @p, "$UPGRADE_URL is linked $n times in the template, want 2" unless $n == 2;
    return @p;
}

# --- UPGRADING.md ---
{
    my $exists = sub { -f "$project_dir/$_[0]" };

    ok(-f $UPGRADING, 'UPGRADING.md exists');
    my @p = check_upgrade_doc($upgrading, $trouble, $exists);
    is(np(@p), 0, 'UPGRADING.md: five sections, hyphen only, links and anchors resolve, no private data')
        or diag(join("\n", @p));

    # D1: a missing file reads as empty text
    my $d1 = '';
    ok($d1 ne $upgrading, 'mutant applied: D1 empty guide');
    ok(np(check_upgrade_doc($d1, $trouble, $exists)) > 0, 'D1 empty guide is reported');

    (my $d2 = $upgrading) =~ s/^(# [^\n]*\n)/$1\x{2014}\n/m;
    ok($d2 ne $upgrading, 'mutant applied: D2 em dash after the first heading');
    ok(np(check_upgrade_doc($d2, $trouble, $exists)) > 0, 'D2 em dash is reported');

    (my $d3 = $upgrading) =~ s/\]\(TROUBLESHOOTING\.md/](TROUBLESHOOTING-NOPE.md/;
    ok($d3 ne $upgrading, 'mutant applied: D3 first TROUBLESHOOTING.md link points to a file that does not exist');
    ok(np(check_upgrade_doc($d3, $trouble, $exists)) > 0, 'D3 link to a missing file is reported');

    (my $d4 = $upgrading) =~ s/\]\(TROUBLESHOOTING\.md#[^)]*\)/](TROUBLESHOOTING.md#no-such-section)/;
    ok($d4 ne $upgrading, 'mutant applied: D4 first TROUBLESHOOTING.md anchor renamed');
    ok(np(check_upgrade_doc($d4, $trouble, $exists)) > 0, 'D4 anchor without a heading is reported');

    (my $d5 = $upgrading) =~ s/^## Going back to 3\.5\.8[ \t]*\n//m;
    ok($d5 ne $upgrading, 'mutant applied: D5 section Going back to 3.5.8 removed');
    ok(np(check_upgrade_doc($d5, $trouble, $exists)) > 0, 'D5 missing section is reported');

    (my $d6 = $upgrading) =~ s/Local Network/Network/g;
    ok($d6 ne $upgrading, 'mutant applied: D6 Local Network turned into Network');
    ok(np(check_upgrade_doc($d6, $trouble, $exists)) > 0, 'D6 missing iOS permission name is reported');

    my $d7 = length $upgrading ? $upgrading . "\nLMS runs at 192.168.1.20 here.\n" : $upgrading;
    ok($d7 ne $upgrading, 'mutant applied: D7 line with a private address appended');
    ok(np(check_upgrade_doc($d7, $trouble, $exists)) > 0, 'D7 private address is reported');
}

# --- the needs-pairing line links the guide ---
{
    my @p = check_pairing_link($html);
    is(np(@p), 0, 'every account that needs pairing links UPGRADING.md inside the FOREACH block')
        or diag(join("\n", @p));

    # P1: the anchor leaves the paragraph and lands behind the END of the block
    (my $p1 = $html) =~ s{(\Q$NP_OPEN\E(?:(?!\[% END %\]).)*?) &middot; (<a href="\Q$UPGRADE_URL\E"[^\n]*?</a>)((?:(?!\[% END %\]).)*\[% END %\])}{$1$3$2}s;
    ok($p1 ne $html, 'mutant applied: P1 anchor moved behind the END of the needs-pairing block');
    ok(np(check_pairing_link($p1)) > 0, 'P1 anchor outside the block is reported');

    my $p2 = mutate_np($html, sub { $_[0] =~ s/rel="noopener noreferrer"/rel="noopener"/ });
    ok($p2 ne $html, 'mutant applied: P2 noreferrer dropped inside the needs-pairing block');
    ok(np(check_pairing_link($p2)) > 0, 'P2 anchor lacking noreferrer is reported');

    my $p3 = mutate_np($html, sub { $_[0] =~ s{href="\Q$UPGRADE_URL\E"}{href="$PROJECT_URL/blob/main/TROUBLESHOOTING.md"} });
    ok($p3 ne $html, 'mutant applied: P3 href switched to TROUBLESHOOTING.md inside the needs-pairing block');
    ok(np(check_pairing_link($p3)) > 0, 'P3 wrong link target is reported');
}

# --- link text in eleven languages ---
{
    my $k = 'PLUGIN_SPOTON_UPGRADE_GUIDE_LINK';
    my @p = check_strings($strings, $k);
    is(np(@p), 0, "$k exists in eleven languages without en or em dash") or diag(join("\n", @p));

    my $l = langs_of($strings);
    is($l->{$k}{EN}, 'What changed in 4.0', "$k EN");
    is($l->{$k}{DE}, 'Was sich in 4.0 geändert hat', "$k DE");

    my $s1 = strip_lang($strings, $k, 'PL');
    ok($s1 ne $strings, "mutant applied: S1 PL line of $k removed");
    ok(np(check_strings($s1, $k)) > 0, 'S1 missing language is reported');

    my $s2 = append_to_lang($strings, $k, 'FR', " \x{2014} x");
    ok($s2 ne $strings, "mutant applied: S2 em dash appended to $k FR");
    ok(np(check_strings($s2, $k)) > 0, 'S2 em dash is reported');
}

# --- help row "Upgrading from 3.x": second row, same link, two links in total ---
{
    my @p = check_upgrade_row($html);
    is(np(@p), 0, 'help row Upgrading from 3.x links UPGRADING.md; the template links it exactly twice')
        or diag(join("\n", @p));

    my $r1 = mutate_help($html, sub { $_[0] =~ s{href="\Q$UPGRADE_URL\E"}{href="$PROJECT_URL/blob/main/README.md"} });
    ok($r1 ne $html, 'mutant applied: R1 href of the help-row anchor switched to README.md');
    ok(np(check_upgrade_row($r1)) > 0, 'R1 wrong target in the help row is reported');

    my $r2 = $html . qq{\n<a href="$UPGRADE_URL" target="_blank" $REL>x</a>\n};
    ok($r2 ne $html, 'mutant applied: R2 one more copy of the anchor appended to the template');
    ok(np(check_upgrade_row($r2)) > 0, 'R2 one link too many is reported');

    my $r3 = mutate_help($html, sub {
        if ($_[0] =~ s{([ \t]*\[% WRAPPER setting title="PLUGIN_SPOTON_HELP_UPGRADE" desc="" %\].*?\[% END %\]\n)\n?}{}s) {
            my $row = $1;
            $_[0] =~ s{(title="PLUGIN_SPOTON_HELP_FORUM".*?\[% END %\]\n)}{$1\n$row}s;
        }
    });
    ok($r3 ne $html, 'mutant applied: R3 upgrade row moved behind the forum row');
    ok(np(check_rows($r3)) > 0, 'R3 upgrade row out of place is reported');
}

# --- row title in eleven languages, register ---
{
    my $k = 'PLUGIN_SPOTON_HELP_UPGRADE';
    my @p = check_strings($strings, $k);
    is(np(@p), 0, "$k exists in eleven languages without en or em dash") or diag(join("\n", @p));

    my $l = langs_of($strings);
    is($l->{$k}{EN}, 'Upgrading from 3.x', "$k EN");
    is($l->{$k}{DE}, 'Umstieg von 3.x', "$k DE");

    my $s3 = strip_lang($strings, $k, 'NO');
    ok($s3 ne $strings, "mutant applied: S3 NO line of $k removed");
    ok(np(check_strings($s3, $k)) > 0, 'S3 missing language is reported');

    my $g1 = append_to_lang($strings, $k, 'DE', ' für dich');
    ok($g1 ne $strings, "mutant applied: G1 du-form appended to $k DE");
    ok(np(check_register($g1)) > 0, 'G1 du-form in the row title is reported');
}

done_testing;

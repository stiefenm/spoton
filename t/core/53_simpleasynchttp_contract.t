#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use File::Find;

# t/53_simpleasynchttp_contract.t -- G-83.3-1b contract gate (83.3-14 Task 2)
#
# Pins the SimpleAsyncHTTP callback-object contract from the OUTSIDE: the
# allowed accessor set comes from parsing the INSTALLED LMS class files
# (mk_accessor rw list + every `sub NAME` in Base.pm/SimpleAsyncHTTP.pm/
# Accessor.pm, plus UNIVERSAL's can/isa/DOES/VERSION) -- never from a mock
# written to satisfy the plugin code. That is exactly how the G-83.3-1b
# defect went undetected: t/50's old stub DEFINED a `response` accessor the
# real class does not have, so Quality.pm's `->response` call verified
# clean against a contract the mock invented. When the installed files are
# absent, an embedded LMS 9.1.1 fallback list is used instead, with a drift
# alarm asserting the installed list -- when present -- still contains the
# 14 accessor names this test hardcodes as a known-good baseline.
#
# Two sweeps over the sweep root (Plugins/SpotOn by default,
# $SPOTON_CONTRACT_SWEEP_DIR to override for the MUST-FAIL dry run):
#   (1) no `->response` method call anywhere (full-line comments excluded --
#       a comment documenting the ecb signature is not a defect).
#   (2) every accessor called on a SimpleAsyncHTTP success-callback object --
#       found in the tree's two real shapes, INLINE multi-line callbacks and
#       NAMED hand-offs -- must be in the allowed set. Minimum match-count
#       assertions exist so a sweep that matches nothing can never pass
#       vacuously: on the real tree a PER-FILE floor table (84-09, W8:
#       %SITE_FLOOR below, measured on the full tree, summing to inline 6 /
#       named 3 / skipped 1); under an override root >= 1 each.
#
# 84-09 (amputation-safe core sweep, WARNING 2): every path listed in
# tools/ci/amputation/librespot.files or soloist.files is OPTIONAL -- when it
# is absent (an amputated tree) its row prints one
# `# optional (amputation): <path>` diagnostic and only its own floor is
# skipped; the totals are the sums over the PRESENT rows (full tree
# 6 / 3 / 1, without Soloist 5 / 1 / 1, without librespot 6 / 3 / 0). A
# core (non-manifest) row whose file is absent is a failure, and a site in a
# file the table does not list is a failure too (it must add a row) -- a
# floor is never lowered.
#
# 85-13 (2026-10-17): Settings.pm /me site deleted with PKCE (D-01); sums were inline 10 / named 3 / skipped 1.
# 85-14 (2026-10-17): PKCE.pm deleted (its 2 inline sites) and the TokenManager /me site deleted (1), D-01;
# sums now inline 7 / named 3 / skipped 1 (without Soloist 6 / 1 / 1, without librespot 7 / 3 / 0).
# 85-15 (2026-10-17): API/Client.pm deleted (D-01, D-25) with its 1 inline site; sums now inline 6 / named 3 / skipped 1
# (without Soloist 5 / 1 / 1, without librespot 6 / 3 / 0).
#
# This test never loads any Slim:: class and never writes a stub dir --
# pure static file parsing, no class load required.

use constant BASE_PM     => '/usr/share/perl5/Slim/Networking/SimpleHTTP/Base.pm';
use constant ASYNC_PM    => '/usr/share/perl5/Slim/Networking/SimpleAsyncHTTP.pm';
use constant ACCESSOR_PM => '/usr/share/perl5/Slim/Utils/Accessor.pm';

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

# ------------------------------------------------------------------
# Embedded LMS 9.1.1 fallback (planner-supplied, 83.3-14-PLAN.md interfaces
# block). @MK_ACCESSOR_EMBEDDED is also the 13-name mk_accessor rw list this
# test expects to find verbatim in the installed Base.pm; together with
# `content` (Base.pm:401, a hand-written accessor outside the mk_accessor
# block) that is the 14-name drift-alarm baseline.
# ------------------------------------------------------------------
my @MK_ACCESSOR_EMBEDDED = qw(
    cb ecb _params _log type url error code mess headers contentRef
    cacheTime cachedResponse
);
my @EMBEDDED_CORE_14 = (@MK_ACCESSOR_EMBEDDED, 'content');
my @EMBEDDED_FALLBACK_EXTRA = qw(
    content params get post put delete head new init hasSSL onError onBody
    sendCachedResponse close shouldNotRevalidate isNotModifiedResponse
    processResponse cacheResponse prepareCachedResponse unzip mk_accessor
    init_accessor can isa DOES VERSION
);
my @UNIVERSAL_NAMES = qw(can isa DOES VERSION);

# ------------------------------------------------------------------
# IN-03: the inline-shape regex, hoisted to a package variable so it can be
# exercised directly against fixture strings (below) as well as used inside
# sweep_accessor_shapes(). Widened (GREEN) with an optional `\)?` before the
# `=` so it recognises BOTH `my $http = shift;` (scalar shift) AND
# `my ($http) = @_;` (list assignment) -- the RED commit for this plan
# carried the old pattern without `\)?`, which matched only the scalar-shift
# shape and silently miscounted every list-assignment site as
# skipped_no_var, hiding IN-03 behind this file's own aggregate minimum
# count instead of a per-shape assertion.
# ------------------------------------------------------------------
our $INLINE_SHAPE_RE = qr/\A\s*(?:\#[^\n]*\n\s*)*my\s+(?:\(\s*)?\$(\w+)\s*\)?\s*=\s*(?:shift|\@_)/;

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------

sub read_file {
    my ($path) = @_;
    open(my $fh, '<', $path) or return '';
    local $/;
    my $content = <$fh>;
    close($fh);
    return $content // '';
}

sub find_pm_files {
    my ($root) = @_;
    my @files;
    return @files unless -d $root;
    find(sub {
        push @files, $File::Find::name if -f $_ && /\.pm\z/;
    }, $root);
    return sort @files;
}

sub line_of {
    my ($text, $pos) = @_;
    return 1 + (substr($text, 0, $pos) =~ tr/\n//);
}

# amputation_optional($root) -- 84-09: a predicate over repo-relative paths,
# true for every path listed (or under a directory listed, trailing /) in
# tools/ci/amputation/librespot.files or soloist.files. A missing manifest
# is a die: without it an absent file cannot be told from a broken tree.
sub amputation_optional {
    my ($root) = @_;
    my (@exact, @dirs);
    for my $side (qw(librespot soloist)) {
        my $m = "$root/tools/ci/amputation/$side.files";
        open(my $fh, '<', $m) or die "amputation manifest missing: $m";
        while (my $l = <$fh>) {
            chomp $l;
            next if $l =~ /^\s*(?:#|\z)/;
            if ($l =~ m{/\z}) { push @dirs, $l } else { push @exact, $l }
        }
        close($fh);
    }
    my %exact = map { $_ => 1 } @exact;
    return sub {
        my ($path) = @_;
        return 1 if $exact{$path};
        return scalar grep { index($path, $_) == 0 } @dirs;
    };
}

# extract_brace_body($text, $open_pos) -- $open_pos points at the '{'
# character. Naive brace-depth counting (strings/comments not parsed --
# accepted approximation, the tree has no unbalanced braces inside these
# callbacks). Returns (body_text_excluding_braces, pos_right_after_close)
# or (undef, undef) if unbalanced.
sub extract_brace_body {
    my ($text, $open_pos) = @_;
    my $len = length($text);
    my $depth = 0;
    for (my $i = $open_pos; $i < $len; $i++) {
        my $ch = substr($text, $i, 1);
        if ($ch eq '{') {
            $depth++;
        }
        elsif ($ch eq '}') {
            $depth--;
            if ($depth == 0) {
                return (substr($text, $open_pos + 1, $i - $open_pos - 1), $i + 1);
            }
        }
    }
    return (undef, undef);
}

# resolve_named_sub_var($text, $name) -- finds `sub NAME { ... }` in $text
# (brace-counted, works for both one-line and multi-line subs -- #1 note
# from the plan-check advisory), extracts its `my (...) = @_` variable list.
# Returns { vars => \@vars, body => $body } or undef.
sub resolve_named_sub_var {
    my ($text, $name) = @_;
    return undef unless $text =~ /^sub\s+\Q$name\E\b/m;
    my $subStart = $-[0];
    my $bracePos = index($text, '{', $subStart);
    return undef if $bracePos < 0;
    my ($body, undef) = extract_brace_body($text, $bracePos);
    return undef unless defined $body;
    return undef unless $body =~ /my\s*\(([^)]*)\)\s*=\s*\@_/;
    my @vars = map { /\$(\w+)/ ? $1 : undef } split /,/, $1;
    return { vars => \@vars, body => $body };
}

# sweep_response_ban(\@files) -- sweep (1): zero non-comment lines calling
# ->response anywhere under the sweep root.
sub sweep_response_ban {
    my ($files) = @_;
    my @offenders;
    for my $file (@$files) {
        open(my $fh, '<', $file) or next;
        my $lineno = 0;
        while (my $line = <$fh>) {
            $lineno++;
            next if $line =~ /^\s*#/;    # full-line comment -- excluded
            if ($line =~ /->\s*response\b/) {
                push @offenders, "$file:$lineno";
            }
        }
        close($fh);
    }
    return @offenders;
}

# sweep_accessor_shapes(\@files, \%allowed) -- sweep (2): every accessor
# called on a SimpleAsyncHTTP success-callback object must be in %allowed.
# Finds callback sites via `Slim::Networking::SimpleAsyncHTTP->new( sub {`,
# extracts the callback body by brace-depth counting, and classifies it as
# INLINE (`my $VAR = shift|@_` near the start) or NAMED hand-off (the whole
# body is exactly one call expression, optionally through an invocant --
# resolved through the argument position of shift/@_ onto the named sub's
# own `my (...) = @_` list). Anything else is counted as skipped_no_var
# (e.g. Connect.pm:361, which never binds the object to a variable).
sub sweep_accessor_shapes {
    my ($files, $allowed, $root) = @_;
    my (@site_diag, @offenders);
    my ($inline_matched, $named_matched, $skipped_no_var) = (0, 0, 0);
    my %per;    # 84-09: per-file site counts {inline|named|skipped}{<path under the sweep root>}

    for my $file (@$files) {
        my $text = read_file($file);
        next unless length $text;
        (my $rel = $file) =~ s{\A\Q$root\E/}{};

        while ($text =~ /Slim::Networking::SimpleAsyncHTTP->new\(\s*sub\s*\{/g) {
            my $open_pos   = pos($text) - 1;    # position of the matched '{'
            my $site_line  = line_of($text, $open_pos);
            my ($body, $end_pos) = extract_brace_body($text, $open_pos);

            unless (defined $body) {
                $skipped_no_var++;
                $per{skipped}{$rel}++;
                push @site_diag, "$file:$site_line shape=skipped_no_var";
                next;
            }

            if ($body =~ $INLINE_SHAPE_RE) {
                my $var = $1;
                $inline_matched++;
                $per{inline}{$rel}++;
                push @site_diag, "$file:$site_line shape=inline var=\$$var";
                while ($body =~ /\$\Q$var\E->(\w+)/g) {
                    my $accessor = $1;
                    push @offenders, "$file:$site_line:$accessor (inline)"
                        unless $allowed->{$accessor};
                }
            }
            elsif ($body =~ /\A\s*(?:(\$\w+)->)?(\w+)\((.*?)\)\s*;?\s*\z/s) {
                my ($invocant, $name, $args) = ($1, $2, $3);
                my @argList = map { s/^\s+|\s+\z//gr } split /,/, $args;
                my $posInArgs;
                for my $i (0 .. $#argList) {
                    if ($argList[$i] eq 'shift' || $argList[$i] eq '@_') {
                        $posInArgs = $i;
                        last;
                    }
                }
                if (defined $posInArgs) {
                    my $P = $posInArgs + ($invocant ? 1 : 0);
                    my $resolved = resolve_named_sub_var($text, $name);
                    my $var = $resolved ? $resolved->{vars}[$P] : undef;
                    if (defined $var) {
                        $named_matched++;
                        $per{named}{$rel}++;
                        push @site_diag, "$file:$site_line shape=named var=\$$var";
                        while ($resolved->{body} =~ /\$\Q$var\E->(\w+)/g) {
                            my $accessor = $1;
                            push @offenders, "$file:$site_line:$accessor (named)"
                                unless $allowed->{$accessor};
                        }
                    }
                    else {
                        $skipped_no_var++;
                        $per{skipped}{$rel}++;
                        push @site_diag, "$file:$site_line shape=skipped_no_var";
                    }
                }
                else {
                    $skipped_no_var++;
                    $per{skipped}{$rel}++;
                    push @site_diag, "$file:$site_line shape=skipped_no_var";
                }
            }
            else {
                $skipped_no_var++;
                $per{skipped}{$rel}++;
                push @site_diag, "$file:$site_line shape=skipped_no_var";
            }

            pos($text) = $end_pos if defined $end_pos;
        }
    }

    return {
        inline_matched => $inline_matched,
        named_matched  => $named_matched,
        skipped_no_var => $skipped_no_var,
        site_diag      => \@site_diag,
        offenders      => \@offenders,
        per            => \%per,
    };
}

# ------------------------------------------------------------------
# Build the allowed accessor set
# ------------------------------------------------------------------

my $haveInstalled = (-f BASE_PM && -f ASYNC_PM && -f ACCESSOR_PM) ? 1 : 0;
my (%allowed, $source);

if ($haveInstalled) {
    $source = 'installed';

    my $baseText     = read_file(BASE_PM);
    my $asyncText    = read_file(ASYNC_PM);
    my $accessorText = read_file(ACCESSOR_PM);

    my @mkNames;
    if ($baseText =~ /mk_accessor\s*\(\s*rw\s*=>\s*qw\(([^)]*)\)/s) {
        @mkNames = split ' ', $1;
    }

    my @subNames;
    for my $text ($baseText, $asyncText, $accessorText) {
        while ($text =~ /^sub\s+(\w+)/mg) {
            push @subNames, $1;
        }
    }

    $allowed{$_} = 1 for (@mkNames, @subNames, @UNIVERSAL_NAMES);

    my @missing = grep { !$allowed{$_} } @EMBEDDED_CORE_14;
    diag("drift alarm: missing from installed set: @missing") if @missing;
    is(scalar(@missing), 0,
        'installed accessor list contains all 14 embedded accessor names (drift alarm)');
}
else {
    $source = 'embedded fallback';
    $allowed{$_} = 1 for (@MK_ACCESSOR_EMBEDDED, @EMBEDDED_FALLBACK_EXTRA, @UNIVERSAL_NAMES);
}

diag("contract source: $source");

# ------------------------------------------------------------------
# Sweep
# ------------------------------------------------------------------

my $overrideRoot = $ENV{SPOTON_CONTRACT_SWEEP_DIR};
my $overrideMode = defined($overrideRoot) && length($overrideRoot);
my $sweepRoot    = $overrideMode ? $overrideRoot : "$project_dir/Plugins/SpotOn";

# IN-03: fixture checks on $INLINE_SHAPE_RE itself, run BEFORE the sweep --
# pin all three inline-callback shapes the sweep must tell apart. RED on the
# unfixed (old) pattern: the list-assignment shape does not match.
like('my $http = shift;', $INLINE_SHAPE_RE,
    'IN-03: scalar-shift inline shape is recognised');
like('my ($http) = @_;', $INLINE_SHAPE_RE,
    'IN-03: list-assignment inline shape is recognised');
unlike('$http->post($url);', $INLINE_SHAPE_RE,
    'IN-03: a non-declaration line is not an inline shape');

my @files = find_pm_files($sweepRoot);
diag("sweep root: $sweepRoot (" . scalar(@files) . " .pm files)");

my @offenders1 = sweep_response_ban(\@files);
diag("sweep(1) offender: $_") for @offenders1;
is(scalar(@offenders1), 0,
    "sweep(1): zero '->response' calls (excluding full-line comments) under $sweepRoot");

my $result = sweep_accessor_shapes(\@files, \%allowed, $sweepRoot);
diag("site: $_") for @{ $result->{site_diag} };
diag("sweep(2) offender: $_") for @{ $result->{offenders} };
diag("skipped_no_var: $result->{skipped_no_var}") if $result->{skipped_no_var};

if ($overrideMode) {
    ok($result->{inline_matched} >= 1,
        "override mode: inline callbacks matched >= 1 (got $result->{inline_matched})");
    ok($result->{named_matched} >= 1,
        "override mode: named hand-offs matched >= 1 (got $result->{named_matched})");
}
else {
    # 84-09 (W8): the per-file table, measured on the full tree 2026-10-12
    # (site diag above); paths are relative to Plugins/SpotOn. inline/named
    # rows are floors (>=), the skipped row is exact (==).
    my %SITE_FLOOR = (
        inline => {
            # 85-15: Client.pm deleted (D-01, D-25) -- its row and its 1 inline site go, inline 7 -> 6
            # 85-14: PKCE.pm deleted, TokenManager /me site deleted (D-01) -- inline 10 -> 7
            # 85-13: Settings.pm /me site deleted with PKCE (D-01) -- inline 11 -> 10
            # 85-12 (2026-10-17): WebPlayer.pm deleted (its 4 inline sites go with it; inline 15 -> 11), D-17=pathfinder-login5-plus-rootlist
            # 85-08: Pathfinder sites moved (1: the query callback; getWebPlayerPlaylistItems'
            # site is deleted with the function) and scrape sites added (1), D-17
            'API/Login5.pm'       => 1,
            'API/Pathfinder.pm'   => 2,
            'API/SpClient.pm'     => 2,
            'Soloist/Quality.pm'  => 1,
        },
        named => {
            'Soloist.pm'               => 2,
            'Unified/DaemonManager.pm' => 1,
        },
        skipped => {
            'Backend/Librespot.pm' => 1,    # the _sendControlCommand ok-callback (moved from Connect.pm in 84-07)
        },
    );
    my $optional = amputation_optional($project_dir);
    my %sum = (inline => 0, named => 0, skipped => 0);
    my $present_rows = 0;
    for my $shape (qw(inline named skipped)) {
        for my $rel (sort keys %{ $SITE_FLOOR{$shape} }) {
            my $floor = $SITE_FLOOR{$shape}{$rel};
            my $got   = $result->{per}{$shape}{$rel} // 0;
            if (!-f "$sweepRoot/$rel") {
                if ($optional->("Plugins/SpotOn/$rel")) {
                    diag("optional (amputation): Plugins/SpotOn/$rel");
                    next;
                }
                ok(0, "core sweep file present: Plugins/SpotOn/$rel (not in an amputation manifest)");
                next;
            }
            $present_rows++;
            $sum{$shape} += $floor;
            if ($shape eq 'skipped') {
                is($got, $floor, "$shape sites in $rel == $floor (got $got)");
            } else {
                cmp_ok($got, '>=', $floor, "$shape sites in $rel >= $floor (got $got)");
            }
        }
    }
    ok($present_rows >= 1, "at least one row of the site table is present (got $present_rows)");
    # 85-13 (D-01): the row for Settings.pm is replaced by this absence check --
    # its only SimpleAsyncHTTP site was the /me call in the deleted PKCE finish handler.
    is($result->{per}{inline}{'Settings.pm'} // 0, 0,
        'no inline SimpleAsyncHTTP site remains in Settings.pm (85-13, D-01)');
    my @unlisted = sort map { my $s = $_; map { "$s:$_" } grep { !exists $SITE_FLOOR{$s}{$_} } keys %{ $result->{per}{$s} || {} } } qw(inline named skipped);
    is_deeply(\@unlisted, [], 'every callback site sits in a file the floor table lists (a new file adds a row)')
        or diag("unlisted: @unlisted");
    ok($result->{inline_matched} >= $sum{inline},
        "inline callbacks matched >= $sum{inline} (got $result->{inline_matched})");
    ok($result->{named_matched} >= $sum{named},
        "named hand-offs matched >= $sum{named} (got $result->{named_matched})");
    is($result->{skipped_no_var}, $sum{skipped},
        "IN-03: exactly the documented no-var site(s) of the present files are skipped ($sum{skipped}: Backend/Librespot.pm _sendControlCommand ok-callback, moved from Connect.pm in 84-07)");
}

is(scalar(@{ $result->{offenders} }), 0,
    'sweep(2): every accessor called on a SimpleAsyncHTTP callback object is in the allowed set');

done_testing();

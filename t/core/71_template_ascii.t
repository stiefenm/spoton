#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Find qw(find);
use Cwd qw(abs_path);

# ============================================================
# 79-39 (D-32 F1): no text file under Plugins/SpotOn/HTML/ carries a byte
# above 0x7F. On the user's LMS (DiskStation) the raw UTF-8 check mark of
# the setup step headings rendered as "a-circumflex" plus two invisible C1
# characters (served as C3 A2 C2 9C C2 93). Markup uses character
# references (&#10003;), JS strings set through textContent use \uXXXX
# escapes (a reference would print literally there).
#
# The check is byte-level on purpose: it needs no comment or string parser.
# Files holding a NUL byte are binary and skipped.
#
# Optional argument (prove ... :: <root>): a directory holding
# Plugins/SpotOn/HTML, e.g. a `git archive` of an older revision, so the
# same test can be run against the published beta.1 templates. Without it
# the repo root is scanned.
# ============================================================

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";
my $root     = @ARGV ? abs_path($ARGV[0]) : $project_dir;
my $html_dir = "$root/Plugins/SpotOn/HTML";
die "template dir not found: $html_dir (never skip)\n" unless -d $html_dir;

# findings($bytes) -> list of 1-based line numbers holding a byte above 0x7F
sub findings {
    my ($bytes) = @_;
    my @lines = split /\n/, $bytes, -1;
    my @hits;
    for my $i (0 .. $#lines) {
        push @hits, $i + 1 if $lines[$i] =~ /[\x80-\xFF]/;
    }
    return @hits;
}

# ---- formula leg: the beta.1 line yields exactly one finding ----
{
    my $beta1 = "\t\t\t<span style=\"color:green\">\xE2\x9C\x93</span>\n";
    my @f = findings("<h3>\n$beta1</h3>\n");
    is_deeply(\@f, [2], 'formula: the beta.1 mark line (E2 9C 93) is exactly one finding, on its line');
    my @clean = findings("<span style=\"color:green\">&#10003;</span>\n");
    is(scalar @clean, 0, 'formula: the character reference form is no finding');
}

# ---- scan ----
my @files;
find({ no_chdir => 1, wanted => sub {
    return unless -f $_;
    push @files, $_ if /\.(?:html?|js|css|svg|xml|txt)\z/i;
} }, $html_dir);
@files = sort @files;
cmp_ok(scalar @files, '>=', 3, 'found the SpotOn template text files (' . scalar(@files) . ')');

my $total = 0;
for my $file (@files) {
    open(my $fh, '<:raw', $file) or die "Cannot open $file: $!";
    my $bytes = do { local $/; <$fh> };
    close($fh);
    (my $rel = $file) =~ s{^\Q$root\E/}{};
    if (index($bytes, "\0") >= 0) {
        note("binary (NUL byte), skipped: $rel");
        next;
    }
    my @hits = findings($bytes);
    $total += @hits;
    ok(!@hits, "$rel: no byte above 0x7F") or diag(join("\n", map { "FINDING $rel:$_" } @hits));
}
is($total, 0, "no byte above 0x7F in any SpotOn template text file (findings=$total)");

# ---- the fix forms ----
{
    my $basic = "$html_dir/EN/plugins/SpotOn/settings/basic.html";
    open(my $fh, '<:raw', $basic) or die "Cannot open basic.html: $!";
    my $b = do { local $/; <$fh> };
    close($fh);
    for my $step (qw(account player)) {
        my ($h3) = $b =~ m{(<h3 id="spoton-step-\Q$step\E".*?</h3>)}s;
        ok(defined $h3 && $h3 =~ /&#10003;/ && $h3 =~ /&#10007;/,
            "basic.html step heading '$step' uses &#10003; / &#10007;");
    }

    my $status = "$html_dir/EN/plugins/SpotOn/status.html";
    open($fh, '<:raw', $status) or die "Cannot open status.html: $!";
    my $s = do { local $/; <$fh> };
    close($fh);
    for my $esc (qw(u25CF u25B6 u2026)) {
        ok(index($s, "\\$esc") >= 0, "status.html carries the JS escape \\$esc");
    }
}

done_testing();

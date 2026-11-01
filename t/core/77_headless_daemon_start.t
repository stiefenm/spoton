#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# ============================================================
# 79-61 (79-REVIEW-FULL-1 WR-02): daemons and Connect never started on an
# LMS without web UI. The timer that runs _startUnifiedDaemons (Connect
# handlers, migrations, DaemonManager->init) and the diagnosticMode pref
# watcher sat inside `if (main::WEBUI) { ... }` together with the Settings
# and Status page registration, so `--noweb` left every play attempt with
# "no active unified daemon".
#
# Structural test on initPlugin's body, in the form t/core/62 uses for the
# Login5 health timer: the WEBUI block may only register the web pages; the
# daemon start timer and the diagnosticMode watcher must sit outside it.
# Brace matching skips comments and quoted strings.
# ============================================================

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));
my $file = "$project_dir/Plugins/SpotOn/Plugin.pm";
die "Plugin.pm not found at $file (die, never skip)\n" unless -f $file;

open(my $fh, '<', $file) or die "cannot read $file: $!";
my $src = do { local $/; <$fh> };
close($fh);

# initPlugin body: from `sub initPlugin` to the next top-level `sub `.
my ($init) = $src =~ /(^sub initPlugin\b.*?)(?=^sub \w)/ms;
ok(defined $init, 'initPlugin body found in Plugin.pm');
$init //= '';

# Return the text of the block that starts at the `{` at $open (inclusive).
sub balanced_block {
    my ($text, $open) = @_;
    my $depth = 0;
    my $i = $open;
    my $n = length $text;
    while ($i < $n) {
        my $c = substr($text, $i, 1);
        if ($c eq '#') {                       # comment to end of line
            my $nl = index($text, "\n", $i);
            $i = $nl < 0 ? $n : $nl;
            next;
        }
        if ($c eq "'" || $c eq '"') {          # quoted string
            my $j = $i + 1;
            while ($j < $n) {
                my $d = substr($text, $j, 1);
                if ($d eq '\\') { $j += 2; next; }
                last if $d eq $c;
                $j++;
            }
            $i = $j + 1;
            next;
        }
        if ($c eq '{') { $depth++; }
        elsif ($c eq '}') {
            $depth--;
            return substr($text, $open, $i - $open + 1) if $depth == 0;
        }
        $i++;
    }
    return undef;
}

my @webuiBlocks;
while ($init =~ /if \(main::WEBUI\)\s*\{/g) {
    my $open = pos($init) - 1;
    my $block = balanced_block($init, $open);
    push @webuiBlocks, $block if defined $block;
}
ok(scalar(@webuiBlocks) >= 1, 'initPlugin still has a main::WEBUI block (the web pages need it)');

my $webui = join("\n", @webuiBlocks);
my $outside = $init;
for my $b (@webuiBlocks) { my $pos = index($outside, $b); substr($outside, $pos, length $b, '') if $pos >= 0; }

like($webui, qr/Plugins::SpotOn::Settings->new\(\)/, 'the WEBUI block registers the Settings page');
like($webui, qr/Plugins::SpotOn::Status->new\(\)/, 'the WEBUI block registers the Status page');

unlike($webui, qr/_startUnifiedDaemons/,
    '79-61 WR-02: the daemon start timer (_startUnifiedDaemons) is not inside the main::WEBUI block');
like($outside, qr/setTimer\(\s*\$class\s*,\s*Time::HiRes::time\(\)\s*\+\s*4\s*,\s*\\&_startUnifiedDaemons\s*\)/,
    '79-61 WR-02: initPlugin arms _startUnifiedDaemons at +4 s outside the WEBUI block (headless LMS starts daemons)');
unlike($webui, qr/'diagnosticMode'/,
    '79-61 WR-02: the diagnosticMode pref watcher is not inside the main::WEBUI block');
like($outside, qr/\}\s*,\s*'diagnosticMode'\s*\)/,
    '79-61 WR-02: the diagnosticMode pref watcher is registered outside the WEBUI block');

like($outside, qr/if \( !main::SCANNER \) \{\s*(?:#[^\n]*\n\s*)*Slim::Utils::Timers::killTimers\(\$class, \\&_startUnifiedDaemons\)/,
    '79-61 WR-02: the moved daemon start stays out of the scanner process (guarded by !main::SCANNER)');

done_testing();

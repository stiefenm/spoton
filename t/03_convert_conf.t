#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# Resolve the project root: t/ is directly under the project root
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname($test_dir);
my $conf_file   = "$project_dir/Plugins/SpotOn/custom-convert.conf";

ok(-f $conf_file, "custom-convert.conf exists at $conf_file");

SKIP: {
    skip "custom-convert.conf not found", 10 unless -f $conf_file;

    open(my $fh, '<', $conf_file) or die "Cannot open $conf_file: $!";
    my $content = do { local $/; <$fh> };
    close($fh);

    # soc = SpotOn Coded (PCM), son = SpotOn Native (OGG passthrough)
    ok($content =~ m{^soc pcm}m,  "soc pcm pipeline header exists");
    ok($content =~ m{^son ogg}m,  "son ogg pipeline header exists (OGG passthrough)");

    # No [spotty] references
    ok($content !~ m{\[spotty\]}, "No [spotty] references in convert.conf");

    # Command line is '-' (direct streaming, no transcoder)
    ok($content =~ m{^\t-$}m, "Pipeline command is '-' (direct streaming)");

    # Phase 73 (D-03 completion): the Phase-72 per-track `sol` transcoder
    # rule is retired -- the persistent Soloist daemon (73-01/73-03) replaced
    # per-track --single-track spawning entirely. The sol-family retirement
    # STANDS. Phase 76 (D-05) deliberately reintroduces sox -- but ONLY as
    # the LMS-bundled [sox] tool token in the soc-flc rule (LMS resolves
    # [sox] to its own bundled binary under Bin/<arch>/; this is NOT an
    # external dependency, unlike the Phase-72 sol-era converter). The old
    # blanket "no sox anywhere" assertion is therefore rescoped below: the
    # soc-flc command must START with the [sox] token, and sox must never
    # appear as a raw path or bare shell word outside that token.
    # <!-- planner-discipline-allow: sox -->
    ok($content !~ m{^sol pcm \* \*}m, "sol pcm pipeline header is gone (D-03 retirement)");
    ok($content !~ m{^sol flc \* \*}m, "sol flc rule absent (retired with the rest of the sol family)");
    ok($content !~ m{spoton-soloist}, "no [spoton-soloist] launcher token anywhere in convert.conf");

    # Phase 76 D-05 (i): positive pin -- the soc flc rule exists and its
    # command line starts with the bundled [sox] tool token (capability
    # comment lines beginning with "\t#" may sit between header and command).
    ok($content =~ m{^soc flc \* \*\n(?:\t#[^\n]*\n)*\t\[sox\] }m,
       "soc flc rule present and its command starts with the [sox] tool token (D-05)");

    # Phase 76 D-05 (ii): after stripping all literal [sox] tool tokens,
    # no bare `sox` word remains -- pins that sox appears ONLY as the
    # bracketed tool token, never as a raw path or shell word.
    my $stripped = $content;
    $stripped =~ s{\[sox\]}{}g;
    ok($stripped !~ m{\bsox\b}i,
       "sox appears only as the [sox] tool token, never as a raw path or bare word");

    # Phase 76 D-05: seek templating DID return with the soc-flc
    # T-capability line -- but in the sanctioned capability-flag form
    # ({START=--skip=%t} with %t substitution), NOT the legacy $START$
    # command placeholder. This assertion now pins that the legacy
    # $START$ style is not used anywhere.
    ok($content !~ m{\$START\$}, "no legacy \$START\$ command placeholder anywhere in convert.conf (capability-line {START=...} + %t is the sanctioned form)");
}

done_testing();

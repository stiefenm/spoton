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
    skip "custom-convert.conf not found", 11 unless -f $conf_file;

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

    # Phase 72 (D-02/D-04): sol pcm per-track transcoder rule
    ok($content =~ m{^sol pcm \* \*}m, "sol pcm pipeline header exists");

    # CR-02 (72-REVIEW.md, re-review): a `sol flc` rule piping Soloist's raw
    # S32LE PCM into [flac] --bps=32 was removed. The LMS-bundled flac
    # (1.3.x on stock installs) rejects --bps=32 outright ("must be
    # 8/16/24"; only flac >=1.4.0 supports 32-bit raw). Declaring --bps=24
    # while still feeding unmodified 4-byte/sample frames would mis-frame
    # every sample instead (72-RESEARCH.md Pitfall 2/A2/A4 already flagged
    # this exact trade-off and named PCM-only as the documented fallback).
    # True 24-bit FLAC is deferred to Phase 74 (HiFi enum patch). This
    # assertion guards against a regression back to the broken rule.
    ok($content !~ m{^sol flc \* \*}m, "sol flc rule absent (CR-02: bundled flac rejects --bps=32)");
    ok($content !~ m{--bps=32}, "no --bps=32 anywhere in convert.conf (CR-02)");

    my $solPcmCmd = ($content =~ m{^sol pcm \* \*\n\t[^\n]*\n\t([^\n]*)}m) ? $1 : '';

    like($solPcmCmd, qr{\[spoton-soloist\]}, "sol pcm command references [spoton-soloist]");
    like($solPcmCmd, qr{--single-track \$URL\$}, "sol pcm command uses --single-track \$URL\$");

    # Seek templating must never return for sol (Soloist has no
    # --start-position flag -- RESEARCH Anti-Pattern / Pitfall 3)
    ok($content !~ m{\$START\$}, "no \$START\$ substitution variable anywhere in convert.conf");

    # 3-line format guard (Pitfall 6): each sol header is immediately
    # followed by a TAB-indented capabilities/comment line.
    ok($content =~ m{^sol pcm \* \*\n\t\S}m, "sol pcm header followed by a TAB-indented line (3-line format)");
}

done_testing();

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

    # Phase 72 (D-02/D-04): sol pcm per-track transcoder rule
    ok($content =~ m{^sol pcm \* \*}m, "sol pcm pipeline header exists");

    # Phase 72: sol-flc removed — S32LE frames mis-frame at any bps<32, and
    # flac 1.3.x rejects bps=32. PCM-only until Phase 74 adds proper downsampling.
    ok($content !~ m{^sol flc \* \*}m, "sol flc rule absent (S32LE/flac bps mismatch)");

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

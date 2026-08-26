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
    skip "custom-convert.conf not found", 9 unless -f $conf_file;

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
    # per-track --single-track spawning entirely, and with it went the only
    # external audio-converter dependency this plugin ever had.
    # <!-- planner-discipline-allow: sox -->
    ok($content !~ m{^sol pcm \* \*}m, "sol pcm pipeline header is gone (D-03 retirement)");
    ok($content !~ m{^sol flc \* \*}m, "sol flc rule absent (retired with the rest of the sol family)");
    ok($content !~ m{spoton-soloist}, "no [spoton-soloist] launcher token anywhere in convert.conf");
    ok($content !~ m{\bsox\b}i, "no sox reference anywhere in convert.conf (external converter dependency gone)");

    # Seek templating must never return here (unrelated to sol -- soc/son
    # never used $START$ either).
    ok($content !~ m{\$START\$}, "no \$START\$ substitution variable anywhere in convert.conf");
}

done_testing();

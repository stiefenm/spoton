#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# Resolve the project root (t/<group>/x.t sits two levels below it)
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";
my $conf_file   = "$project_dir/Plugins/SpotOn/custom-types.conf";

ok(-f $conf_file, "custom-types.conf exists at $conf_file");

SKIP: {
    skip "custom-types.conf not found", 10 unless -f $conf_file;

    open(my $fh, '<', $conf_file) or die "Cannot open $conf_file: $!";
    my $content = do { local $/; <$fh> };
    close($fh);

    # Find the son format line (non-comment)
    my ($son_line) = grep { /^son\s+/ } split(/\n/, $content);

    ok(defined $son_line, "son format line exists in custom-types.conf");

    SKIP: {
        skip "son format line not found", 2 unless defined $son_line;

        # Parse: ID  Suffix  MIME-Type  Server-File-Type
        my @fields = split(/\s+/, $son_line);

        # MIME-Type is 3rd field (index 2). Must be SpotOn-specific, not the
        # standard audio/ogg, so LMS's own Ogg internet radio resolution
        # (Slim::Music::Info last-writer-wins) is never hijacked.
        is($fields[2], 'audio/x-sb-spoton-ogg', "MIME-Type is audio/x-sb-spoton-ogg (SpotOn Native OGG passthrough, namespaced)");

        # Server-File-Type is 4th field (index 3)
        is($fields[3], 'audio', "Server-File-Type is audio");
    }

    # Phase 73 (D-03 completion): the Phase-72 `sol` content-type row is
    # retired along with the per-track transcoder path it fed.
    my ($sol_line) = grep { /^sol\s+/ } split(/\n/, $content);

    ok(!defined $sol_line, "sol format line is gone from custom-types.conf (D-03 retirement)");

    # Phase 76 D-07 (76-04): dedicated MP3 forcing type -- registered so
    # formatOverride's 'smp' result maps to a real content type whose only
    # convert rule is the [lame] MP3 transcode.
    my ($smp_line) = grep { /^smp\s+/ } split(/\n/, $content);

    ok(defined $smp_line, "smp format line exists in custom-types.conf (D-07 MP3 forcing type)");

    SKIP: {
        skip "smp format line not found", 2 unless defined $smp_line;

        my @fields = split(/\s+/, $smp_line);

        # Must be SpotOn-specific, not the standard audio/mpeg, so LMS's own
        # MP3 internet radio resolution is never hijacked (T-wh5-01).
        is($fields[2], 'audio/x-sb-spoton-mp3', "smp MIME-Type is audio/x-sb-spoton-mp3 (MP3 target semantics, namespaced)");
        is($fields[3], 'audio', "smp Server-File-Type is audio");
    }

    # Phase 74b D-01/D-14: the dedicated FLAC forcing type -- registered so
    # formatOverride's 'sof' result maps to a real content type whose only
    # convert rule is the bundled-sox FLAC transcode. MIME stays
    # SpotOn-specific (t/core/54 enforces it for the whole file).
    my ($sof_line) = grep { /^sof\s+/ } split(/\n/, $content);

    ok(defined $sof_line, "sof format line exists in custom-types.conf (74b D-14 FLAC forcing type)");

    SKIP: {
        skip "sof format line not found", 2 unless defined $sof_line;

        my @fields = split(/\s+/, $sof_line);

        is($fields[2], 'audio/x-sb-spoton-flac', "sof MIME-Type is audio/x-sb-spoton-flac (FLAC target semantics, namespaced)");
        is($fields[3], 'audio', "sof Server-File-Type is audio");
    }
}

done_testing();

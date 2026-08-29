#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# Resolve the project root: t/ is directly under the project root
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname($test_dir);
my $conf_file   = "$project_dir/Plugins/SpotOn/custom-types.conf";

ok(-f $conf_file, "custom-types.conf exists at $conf_file");

SKIP: {
    skip "custom-types.conf not found", 7 unless -f $conf_file;

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

        # MIME-Type is 3rd field (index 2)
        is($fields[2], 'audio/ogg', "MIME-Type is audio/ogg (SpotOn Native OGG passthrough)");

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

        is($fields[2], 'audio/mpeg', "smp MIME-Type is audio/mpeg (MP3 target semantics)");
        is($fields[3], 'audio', "smp Server-File-Type is audio");
    }
}

done_testing();

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
    skip "custom-types.conf not found", 6 unless -f $conf_file;

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

    # Phase 72 (D-02): sol content-type row
    my ($sol_line) = grep { /^sol\s+/ } split(/\n/, $content);

    ok(defined $sol_line, "sol format line exists in custom-types.conf");

    SKIP: {
        skip "sol format line not found", 2 unless defined $sol_line;

        my @fields = split(/\s+/, $sol_line);

        is($fields[2], 'audio/x-sb-spoton-soloist', "sol MIME-Type is audio/x-sb-spoton-soloist");
        is($fields[3], 'audio', "sol Server-File-Type is audio");
    }
}

done_testing();

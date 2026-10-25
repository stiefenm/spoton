#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use JSON::PP qw(decode_json);

# Resolve the project root (t/<group>/x.t sits two levels below it)
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";
my $bin_dir     = "$project_dir/Plugins/SpotOn/Bin/x86_64-linux";

# Binaries are built by CI and not tracked in git.
# Skip gracefully if the binary is not present locally.
my $binary = "$bin_dir/spoton";

unless (-d $bin_dir && -f $binary && -x $binary) {
    plan skip_all => 'Binary not present (built by CI, not tracked in git)';
}

# Binary found — validate the --check contract
my $output = `"$binary" --check 2>&1`;
my @lines  = split /\n/, $output;

# First line must match: ok spoton v<version>
like($lines[0], qr/^ok spoton v[\d\.]+/i,
    "Binary --check first line matches 'ok spoton v<version>'");

# Second line must be parseable JSON
SKIP: {
    my $json_line = $lines[1];
    skip "--check did not produce a second line", 2 unless defined $json_line && length($json_line);

    my $data = eval { decode_json($json_line) };
    ok(!$@, "Second line of --check output is parseable JSON")
        or diag("JSON parse error: $@\nLine was: $json_line");

    SKIP: {
        skip "JSON parse failed", 1 if $@;
        ok(exists $data->{version}, "JSON capability manifest contains 'version' key");
    }
}

done_testing();

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

# Helper: read a file and return list of non-comment lines
sub _noncomment_lines {
    my ($file) = @_;
    open(my $fh, '<', $file) or die "Cannot open $file: $!";
    my @lines;
    while (my $line = <$fh>) {
        chomp $line;
        # Skip lines that start with optional whitespace then #
        next if $line =~ /^\s*#/;
        push @lines, $line;
    }
    close($fh);
    return @lines;
}

# Helper: grep non-comment lines of a file for a pattern, return matching lines
sub _grep_file {
    my ($file, $pattern) = @_;
    my @matches = grep { $_ =~ $pattern } _noncomment_lines($file);
    return @matches;
}

# Helper: find all .pm files recursively under a directory
sub _find_pm_files {
    my ($dir) = @_;
    my @files;
    opendir(my $dh, $dir) or die "Cannot opendir $dir: $!";
    for my $entry (sort readdir($dh)) {
        next if $entry =~ /^\./;
        my $path = "$dir/$entry";
        if (-d $path) {
            push @files, _find_pm_files($path);
        } elsif ($entry =~ /\.pm$/) {
            push @files, $path;
        }
    }
    closedir($dh);
    return @files;
}

# amputation_optional($root) -- 84-09: true for a repo-relative path listed
# (or under a directory listed, trailing /) in tools/ci/amputation/
# librespot.files or soloist.files. A missing manifest dies.
sub amputation_optional {
    my ($root) = @_;
    my (%exact, @dirs);
    for my $side (qw(librespot soloist)) {
        my $m = "$root/tools/ci/amputation/$side.files";
        open(my $fh, '<', $m) or die "amputation manifest missing: $m";
        while (my $l = <$fh>) {
            chomp $l;
            next if $l =~ /^\s*(?:#|\z)/;
            if ($l =~ m{/\z}) { push @dirs, $l } else { $exact{$l} = 1 }
        }
        close($fh);
    }
    return sub { my ($p) = @_; return 1 if $exact{$p}; return scalar grep { index($p, $_) == 0 } @dirs; };
}

# ============================================================
# PROTO-01: No spotify:// in routing-URL contexts across Perl source files
# Scan Plugin.pm, ProtocolHandler.pm, Connect.pm, DontStopTheMusic.pm
# non-comment lines for spotify:// (double-slash). Assert zero matches.
# ============================================================
{
    my @files = (
        "$project_dir/Plugins/SpotOn/Plugin.pm",
        "$project_dir/Plugins/SpotOn/ProtocolHandler.pm",
        "$project_dir/Plugins/SpotOn/Connect.pm",
        "$project_dir/Plugins/SpotOn/DontStopTheMusic.pm",
    );

    my @matches;
    for my $file (@files) {
        ok(-f $file, "PROTO-01: source file exists: " . (File::Basename::basename($file)));
        for my $line (_noncomment_lines($file)) {
            if ($line =~ m{spotify://}) {
                push @matches, "$file: $line";
            }
        }
    }

    is(scalar @matches, 0,
        "PROTO-01: zero spotify:// occurrences in non-comment Perl source lines (found: "
        . scalar(@matches)
        . (scalar(@matches) ? ": " . join("; ", @matches[0..($#matches > 2 ? 2 : $#matches)]) : "")
        . ")");
}

# ============================================================
# PROTO-02: ProtocolHandler registered as 'spoton' not 'spotify' in Plugin.pm
# Multi-line match: registerHandler( may be on a different line than the scheme string.
# Read whole file content and remove comment lines, then do multi-line pattern match.
# ============================================================
{
    my $plugin_file = "$project_dir/Plugins/SpotOn/Plugin.pm";

    open(my $fh, '<', $plugin_file) or BAIL_OUT("Cannot read Plugin.pm: $!");
    my $content = do { local $/; <$fh> };
    close($fh);

    # Remove comment lines for analysis
    $content =~ s/^\s*#[^\n]*\n//gm;

    my $spoton_count  = () = ($content =~ m{registerHandler\s*\(\s*\n?\s*['"]spoton['"]}g);
    my $spotify_count = () = ($content =~ m{registerHandler\s*\(\s*\n?\s*['"]spotify['"]}g);

    is($spoton_count, 1,
        "PROTO-02: Plugin.pm registers handler as 'spoton' exactly once (found: "
        . $spoton_count . ")");

    is($spotify_count, 0,
        "PROTO-02: Plugin.pm does NOT register handler as 'spotify' (found: "
        . $spotify_count . ")");
}

# ============================================================
# PROTO-04: Connect URLs use spoton://connect- prefix. 84-08 (SEAM-6.2): the
# former three construction sites (start, resume, ready) are two now -- the
# start and resume entries take their URL from ONE helper, _playUrlFor
# (capabilities->{connectEntry}), the ready re-entry keeps its own fallback.
# Pinned: both constructions carry the prefix, and the two dispatch sites
# use the helper (each mutation-shown red in the 84-08 SUMMARY).
# ============================================================
{
    my $connect_file = "$project_dir/Plugins/SpotOn/Connect.pm";

    my @matches = _grep_file($connect_file, qr{sprintf.*spoton://connect-});

    cmp_ok(scalar @matches, '>=', 2,
        "PROTO-04: Connect.pm has >= 2 sprintf.*spoton://connect- constructions (found: "
        . scalar(@matches) . ")");

    my @helper = _grep_file($connect_file, qr{^\s*return sprintf\("spoton://connect-%u"});
    is(scalar @helper, 1, 'PROTO-04 (84-08): _playUrlFor builds the repeating URL with the spoton://connect- prefix');
    my @calls = _grep_file($connect_file, qr{= _playUrlFor\(\$client, \$trackId\);});
    is(scalar @calls, 2, 'PROTO-04 (84-08): the start and resume entries take their URL from _playUrlFor');
}

# ============================================================
# PROTO-05: No registerHandler('spotify') anywhere under Plugins/SpotOn/
# ============================================================
{
    my $plugins_dir = "$project_dir/Plugins/SpotOn";
    my @pm_files    = _find_pm_files($plugins_dir);

    ok(scalar @pm_files > 0, "PROTO-05: found .pm files under Plugins/SpotOn/");

    my $bad_count = 0;
    my @bad_files;
    for my $file (@pm_files) {
        open(my $fh, '<', $file) or die "Cannot open $file: $!";
        my $content = do { local $/; <$fh> };
        close($fh);
        # Remove comment lines
        $content =~ s/^\s*#[^\n]*\n//gm;
        my $matches = () = ($content =~ m{registerHandler\s*\(\s*\n?\s*['"]spotify['"]}g);
        if ($matches) {
            $bad_count += $matches;
            push @bad_files, "$file ($matches)";
        }
    }

    is($bad_count, 0,
        "PROTO-05: zero registerHandler('spotify') across all SpotOn .pm files (found: "
        . $bad_count . (scalar(@bad_files) ? ": " . join(", ", @bad_files) : "") . ")");
}

# ============================================================
# PROTO-06: cacheSchemaVersion pref and SPOTON_CACHE_VERSION constant in Plugin.pm
# ============================================================
{
    my $plugin_file = "$project_dir/Plugins/SpotOn/Plugin.pm";

    my @cache_ver_matches = _grep_file($plugin_file, qr{cacheSchemaVersion});
    my @const_matches     = _grep_file($plugin_file, qr{SPOTON_CACHE_VERSION});

    cmp_ok(scalar @cache_ver_matches, '>=', 2,
        "PROTO-06: Plugin.pm has >= 2 cacheSchemaVersion references (found: "
        . scalar(@cache_ver_matches) . ")");

    cmp_ok(scalar @const_matches, '>=', 1,
        "PROTO-06: Plugin.pm has >= 1 SPOTON_CACHE_VERSION reference (found: "
        . scalar(@const_matches) . ")");
}

# ============================================================
# Rust binary normalization check:
# v2.0: --single-track mode removed, no spoton:// URL rewrite in Rust anymore.
# Verify no spotify:// references leaked into the Rust source.
# ============================================================
# 84-09 (amputation-safe core sweep): librespot-spoton/ is a line of
# tools/ci/amputation/librespot.files -- absent on a librespot-amputated tree,
# where this one assertion is left out with a `# optional (amputation)`
# diagnostic (no SKIP: a core test carries no backend-conditional skip). An
# absent main.rs that no manifest lists is a broken tree and dies.
{
    my $rust_rel  = 'librespot-spoton/src/main.rs';
    my $rust_file = "$project_dir/$rust_rel";

    if (!-f $rust_file) {
        die "$rust_rel missing and not listed in an amputation manifest -- broken tree\n"
            unless amputation_optional($project_dir)->($rust_rel);
        diag("optional (amputation): $rust_rel");
    }
    else {
        open(my $fh, '<', $rust_file) or die "Cannot open $rust_file: $!";
        my @lines = <$fh>;
        close($fh);
        chomp @_ for @lines;

        my @spotify_replace = grep { /replace\("spotify:\/\/"/ } @lines;

        is(scalar @spotify_replace, 0,
            "Rust binary: zero replace(\"spotify://\") calls in main.rs (found: "
            . scalar(@spotify_replace) . ")");
    }
}

# ============================================================
# Cache namespace check:
# All 5 Perl modules use Cache->new('spoton', ...) — assert 5 total
# and zero Cache->new() no-args calls in those files
# ============================================================
{
    # 85-15: API/Client.pm deleted (D-01) — five modules remain
    my @cache_files = (
        "$project_dir/Plugins/SpotOn/Plugin.pm",
        "$project_dir/Plugins/SpotOn/ProtocolHandler.pm",
        "$project_dir/Plugins/SpotOn/Connect.pm",
        "$project_dir/Plugins/SpotOn/DontStopTheMusic.pm",
        "$project_dir/Plugins/SpotOn/API/TokenManager.pm",
    );

    my $named_ns_count = 0;
    my $noargs_count   = 0;

    for my $file (@cache_files) {
        for my $line (_noncomment_lines($file)) {
            $named_ns_count++ if $line =~ qr{Cache->new\s*\(\s*['"]spoton['"]};
            # Match Cache->new() with no arguments (empty parens, possible whitespace)
            $noargs_count++   if $line =~ qr{Cache->new\s*\(\s*\)};
        }
    }

    is($named_ns_count, 5,
        "Cache namespace: exactly 5 Cache->new('spoton', ...) calls across all 5 modules (found: "
        . $named_ns_count . ")");

    is($noargs_count, 0,
        "Cache namespace: zero Cache->new() no-args calls across all 5 modules (found: "
        . $noargs_count . ")");
}

done_testing();

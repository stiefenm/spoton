#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Find;
use Cwd qw(abs_path);

# t/core/63_no_webapi_sweep.t -- 85 D-25 static layer.
#
# Phase 85 removes the Spotify Web API from the product. This sweep proves the SOURCE side: no
# non-comment line under Plugins/SpotOn names the API host, the Web-API client modules or the
# symbols that only existed for them. (The RUNTIME side -- no request leaves the box -- is
# tools/uat/webapi-gate.pl.)
#
# Sweep root: Plugins/SpotOn of the repo by default; $SPOTON_WEBAPI_SWEEP_DIR points the sweep at
# another directory that CONTAINS Plugins/SpotOn (a git archive of the pre-phase commit for the
# MUST-FAIL dry run, a doctored copy for the MUST-PASS one).
#
# Mode rule (85-15): every test is strict, on the real tree and under an override alike. The
# TODO wrapper 85-01 put around the forbidden-pattern tests while the Web API was still in the
# tree is gone; the minimum-match tests stay as they were: a sweep over nothing must fail, not pass.
#
# Scoped rule (85-15, decision-D17 pathfinder-login5-plus-rootlist): the Pathfinder host
# api-partner.spotify.com is NOT forbidden everywhere -- Made for You, top tracks and search
# keep one Pathfinder path -- but it may be named in exactly ONE module, Plugins/SpotOn/API/
# Pathfinder.pm (one exact relative path, not a pattern family). Any other non-comment line
# naming it is an offender. The @FORBIDDEN list below is unchanged; its api\.spotify\.com
# pattern does not match api-partner.spotify.com.
#
# Files: every *.pm, *.html, *.txt, *.conf and install.xml under the root. For *.pm only
# non-comment lines count (full-line comments, POD blocks and everything after __END__/__DATA__
# are excluded); the other file types are scanned line by line.

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

# 79-25 (D-08, NA-x): which backend-side leg is this tree? The committed manifests
# tools/ci/amputation/<side>.files (entries under Plugins/SpotOn/) are the single source:
# all paths present = normal tree ('present'), none present = that side was removed on purpose
# ('amputated', the CI amputation leg), some present = broken checkout (die, never skip).
sub amputation_state {
    my ($root, $side) = @_;
    my $manifest = "$project_dir/tools/ci/amputation/$side.files";
    open(my $mfh, '<', $manifest)
        or die "$manifest: $! -- wrong project root or broken checkout (die, never skip)\n";
    my @paths;
    while (my $line = <$mfh>) {
        chomp $line;
        next if $line =~ /^\s*(?:#|$)/;
        next unless $line =~ m{^Plugins/SpotOn/};
        $line =~ s{/+\z}{};
        push @paths, $line;
    }
    close($mfh);
    die "$manifest holds no Plugins/SpotOn entries -- wrong project root or broken checkout (die, never skip)\n"
        unless @paths;
    my $here = grep { -e "$root/$_" } @paths;
    return 'present'   if $here == @paths;
    return 'amputated' if $here == 0;
    die "partial $side side ($here of " . scalar(@paths) . " paths present) -- broken checkout (die, never skip)\n";
}

my $override      = $ENV{SPOTON_WEBAPI_SWEEP_DIR};
my $override_mode = defined($override) && length($override);
my $base          = $override_mode ? $override : $project_dir;
my $sweep_root    = "$base/Plugins/SpotOn";
die "sweep root has no Plugins/SpotOn: $base" unless -d $sweep_root;

# name => regex. Each pattern is its own named test with `file:line` offender diagnostics.
my @FORBIDDEN = (
    ['api.spotify.com'              => qr/api\.spotify\.com/],
    ['API::Client'                  => qr/API::Client\b/],
    ['API::PKCE'                    => qr/API::PKCE\b/],
    ['getLimit'                     => qr/\bgetLimit\b/],
    ['limitsProbed'                 => qr/\blimitsProbed\b/],
    ['probeEndpointLimits'          => qr/\bprobeEndpointLimits\b/],
    ['SPOTON_DEFAULT_CLIENT_ID'     => qr/SPOTON_DEFAULT_CLIENT_ID/],
    ['PATHFINDER_HOME_HASH_DEFAULT' => qr/PATHFINDER_HOME_HASH_DEFAULT/],
    ['settings/pkce/'               => qr{settings/pkce/}],
    ['browse/categories'            => qr{browse/categories}],
);

sub scan_files {
    my ($root) = @_;
    my @files;
    find({
        no_chdir => 1,
        wanted   => sub {
            return unless -f $File::Find::name;
            push @files, $File::Find::name if $File::Find::name =~ /(?:\.pm|\.html|\.txt|\.conf|\/install\.xml)\z/;
        },
    }, $root);
    return sort @files;
}

# Returns [[lineno, text], ...] -- the lines that count for $file.
sub counted_lines {
    my ($file) = @_;
    open(my $fh, '<', $file) or die "Cannot open $file: $!";
    my $is_pm = $file =~ /\.pm\z/;
    my ($in_pod, @out) = (0);
    while (my $line = <$fh>) {
        chomp $line;
        if ($is_pm) {
            last if $line =~ /^__(?:END|DATA)__\b/;
            if ($line =~ /^=cut\b/) { $in_pod = 0; next; }
            if ($line =~ /^=[a-zA-Z]/) { $in_pod = 1; next; }
            next if $in_pod;
            next if $line =~ /^\s*#/;
        }
        push @out, [$., $line];
    }
    close($fh);
    return \@out;
}

my @files = scan_files($sweep_root);
my @pm    = grep { /\.pm\z/ } @files;
diag("sweep root: $sweep_root (" . scalar(@files) . " files, " . scalar(@pm) . " .pm)");

# ---- 79-25 (NA-4): which backend sides does the sweep root hold? ----
# The two CI amputation legs remove one side on purpose (tools/ci/amputation/<side>.files). A
# partial side dies inside amputation_state(); BOTH sides gone is not a leg, it is a sweep over
# nothing, and fails below. The state is read at the sweep base so SPOTON_WEBAPI_SWEEP_DIR still
# steers it.
my %side_state = map { $_ => amputation_state($base, $_) } qw(librespot soloist);

# The floor: 25 modules on a full tree. With the soloist side removed (21 modules gone) fewer than
# 25 remain by construction, so the floor is the committed core list (core.files = every module
# under neither manifest), which the sweep must still reach in full.
my @core_pm;
{
    my $core_list = "$project_dir/tools/ci/amputation/core.files";
    open(my $cfh, '<', $core_list) or die "$core_list: $! -- broken checkout (die, never skip)\n";
    while (my $line = <$cfh>) {
        chomp $line;
        next if $line =~ /^\s*(?:#|$)/;
        push @core_pm, $line;
    }
    close($cfh);
    die "$core_list holds no modules -- broken checkout (die, never skip)\n" unless @core_pm;
}
my $floor = $side_state{soloist} eq 'amputated' ? scalar(@core_pm) : 25;

# ---- minimum-match assertions: never TODO ----
ok($side_state{librespot} ne 'amputated' || $side_state{soloist} ne 'amputated',
    'NA-4: at least one backend side is present in the sweep root (neither side = a sweep over nothing)');
cmp_ok(scalar(@pm), '>=', $floor, "minimum match: at least $floor .pm files scanned (a sweep over nothing must fail)");
ok((grep { $_ eq "$sweep_root/Plugin.pm" } @pm), 'minimum match: Plugins/SpotOn/Plugin.pm is among the scanned files');
{
    my %scanned = map { $_ => 1 } @pm;
    my @missing = grep { !$scanned{"$base/$_"} } @core_pm;
    ok(!@missing, 'NA-4: every core.files module is among the scanned files')
        or diag("core.files modules not scanned: " . join(', ', @missing));
}

# ---- forbidden patterns ----
my %lines = map { $_ => counted_lines($_) } @files;
for my $f (@FORBIDDEN) {
    my ($name, $re) = @$f;
    my @offenders;
    for my $file (@files) {
        for my $l (@{ $lines{$file} }) {
            next unless $l->[1] =~ $re;
            (my $rel = $file) =~ s{^\Q$base\E/}{};
            push @offenders, "$rel:$l->[0]";
        }
    }
    # the diagnostics are capped so a TODO run on the real tree stays readable; the count is exact
    diag("offender [$name]: $_") for @offenders[0 .. ($#offenders > 24 ? 24 : $#offenders)];
    diag("offender [$name]: ... " . (@offenders - 25) . " more (" . scalar(@offenders) . " total)") if @offenders > 25;
    is(scalar(@offenders), 0, "no-webapi: no non-comment line matches `$name`");
}

# ---- scoped rule: a host that is allowed in exactly one module ----
# [name, pattern, allowed path (relative to the sweep base, anchored)]
my @SCOPED = (
    ['Pathfinder host only in API/Pathfinder.pm' => qr/api-partner\.spotify\.com/ => qr{\APlugins/SpotOn/API/Pathfinder\.pm\z}],
);
for my $sc (@SCOPED) {
    my ($name, $re, $allowed) = @$sc;
    my @offenders;
    for my $file (@files) {
        (my $rel = $file) =~ s{^\Q$base\E/}{};
        next if $rel =~ $allowed;
        for my $l (@{ $lines{$file} }) {
            next unless $l->[1] =~ $re;
            push @offenders, "$rel:$l->[0]";
        }
    }
    diag("offender [$name]: $_") for @offenders[0 .. ($#offenders > 24 ? 24 : $#offenders)];
    diag("offender [$name]: ... " . (@offenders - 25) . " more (" . scalar(@offenders) . " total)") if @offenders > 25;
    is(scalar(@offenders), 0, "no-webapi: $name");
}

done_testing();

#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use File::Temp;

# 79-06: the release workflow text is asserted in public CI (no LMS modules,
# no rig). Pure Perl plus system awk.
#
#   - the release step derives its prerelease flag from the tag name (D-13)
#   - the workflow's OWN changelog awk, extracted from the workflow file and
#     run on a fixture CHANGELOG, finds exactly the section of the tag

# Resolve project root (t/<group>/x.t sits two levels below it).
# Wrong depth must die, never skip (84-09: a silent skip-all reads as green).
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

# RELEASE_WORKFLOW_FILE lets a dry run point the test at an archived workflow
# text (MUST-FAIL check against the cbcee5fb text).
my $workflow_file = $ENV{RELEASE_WORKFLOW_FILE} || "$project_dir/.github/workflows/build-librespot.yml";
die "workflow file missing: $workflow_file" unless -f $workflow_file;

sub slurp {
    my ($file) = @_;
    open(my $fh, '<', $file) or die "Cannot open $file: $!";
    local $/;
    my $c = <$fh>;
    close($fh);
    return $c;
}

my $workflow = slurp($workflow_file);
my @wf_lines = split /\n/, $workflow;

# ---------------------------------------------------------------------------
# Task 1: prerelease flag
# ---------------------------------------------------------------------------

# The step "Create GitHub Release": from its name line to the next step or job.
my @release_step;
{
    my $in = 0;
    for my $l (@wf_lines) {
        if ($l =~ /^\s*- name: Create GitHub Release\s*$/) { $in = 1; next; }
        if ($in && $l =~ /^\s*- name:/) { last; }
        if ($in && $l =~ /^  \S/)       { last; }
        push @release_step, $l if $in;
    }
}
ok(scalar(@release_step) > 0, 'release step "Create GitHub Release" found');

my ($prerelease_line) = grep { /^\s*prerelease:/ } @release_step;
ok(defined $prerelease_line, 'release step has a prerelease: line');
$prerelease_line //= '';

like($prerelease_line, qr/\$\{\{.*github\.ref_name.*\}\}/,
    'prerelease: is an expression on github.ref_name (not a hard-coded value)');
for my $marker ('-', 'beta', 'rc') {
    like($prerelease_line, qr/contains\(github\.ref_name,\s*'\Q$marker\E'\)/,
        "prerelease expression covers the marker '$marker'");
}
unlike($prerelease_line, qr/prerelease:\s*(true|false)\s*$/,
    'prerelease: is not a literal true/false');

# ---------------------------------------------------------------------------
# Task 1: the workflow's own changelog awk
# ---------------------------------------------------------------------------

my @awk_prog;
{
    my $in = 0;
    for my $l (@wf_lines) {
        if (!$in && $l =~ /NOTES=\$\(awk\b/) { $in = 1; next; }
        if ($in && $l =~ /^\s*'\s+CHANGELOG\.md\)/) { last; }
        push @awk_prog, $l if $in;
    }
}
ok(scalar(@awk_prog) > 0, 'changelog awk program extracted from the workflow');
my $awk_program = join("\n", @awk_prog) . "\n";

my $tmp = File::Temp->newdir();
my $changelog = "$tmp/CHANGELOG.md";
{
    open(my $fh, '>', $changelog) or die "Cannot write $changelog: $!";
    print $fh <<'EOF';
# Changelog

## [Unreleased]

Unreleased text.

## [4.0.0] - 2026-11-01

Final text.
More final text.

## [4.0.0-beta.1] - 2026-10-25

Beta one text.

## [3.5.8] - 2026-09-01

Old text.
EOF
    close($fh);
}

sub run_awk {
    my ($ver) = @_;
    open(my $p, '-|', 'awk', '-v', "ver=$ver", $awk_program, $changelog)
        or die "Cannot run awk: $!";
    local $/;
    my $out = <$p>;
    close($p);
    return $out // '';
}

my $beta  = run_awk('4.0.0-beta.1');
my $final = run_awk('4.0.0');
like($beta,   qr/Beta one text\./, 'awk 4.0.0-beta.1: yields the beta section');
unlike($beta, qr/Final text|Old text|Unreleased text/, 'awk 4.0.0-beta.1: only the beta section');
like($final,   qr/Final text\./, 'awk 4.0.0: yields the final section');
unlike($final, qr/Beta one text|Old text|Unreleased text/,
    'awk 4.0.0: a later beta heading does not leak in, the final does not swallow the beta');
is(run_awk('9.9.9'), '', 'awk of an unknown version yields nothing (workflow then falls back to a link)');

# ---------------------------------------------------------------------------
# Task 2: public .gitignore overlay and CI trigger list
# ---------------------------------------------------------------------------

my $overlay_file = "$project_dir/tools/ci/release-overlay/gitignore.public";
ok(-f $overlay_file, 'overlay tools/ci/release-overlay/gitignore.public exists');
SKIP: {
    skip 'overlay missing', 5 unless -f $overlay_file;
    my $overlay = slurp($overlay_file);
    my @ol = split /\n/, $overlay;
    ok((grep { $_ eq '.planning/' } @ol),       'overlay has a line exactly ".planning/"');
    ok((grep { $_ eq 'soloist-releases/' } @ol), 'overlay has a line exactly "soloist-releases/"');
    ok(!(grep { /gsd-pr-branch/ } @ol),          'overlay carries no gsd-pr-branch comment block');
    ok(!(grep { m{^\.planning/.+} } @ol),        'overlay has no .planning/ sub-lines (the directory is ignored as a whole)');
    ok($overlay !~ /[^\x00-\x7F]/,               'overlay is ASCII only');
}

{
    my $pt = slurp("$project_dir/.github/workflows/perl-tests.yml");
    my ($push_branches) = $pt =~ /^on:\s*\n\s+push:\s*\n\s+branches:\s*\[([^\]]*)\]/m;
    $push_branches //= '';
    my %b = map { s/^\s+|\s+$//gr => 1 } split /,/, $push_branches;
    ok($b{main} && $b{develop}, "perl-tests.yml push trigger lists main and develop (got: [$push_branches])");
}

# ---------------------------------------------------------------------------
# Task 2: detect-changes step, emulated chronologically in a scratch repo
# ---------------------------------------------------------------------------
#
# The step with `id: check` is cut out of the workflow text, de-indented, and run
# with bash in a scratch repo. Tags are created in the order a maintainer would
# create them and the block runs right after each tag exists, so it sees exactly
# the tags that existed when GitHub started the run.

my @check_block;
{
    my $state = 0;
    my $indent;
    for my $l (@wf_lines) {
        if ($state == 0) { $state = 1 if $l =~ /^\s*id:\s*check\s*$/; next; }
        if ($state == 1) { $state = 2 if $l =~ /^\s*run:\s*\|\s*$/; next; }
        if ($state == 2) {
            if ($l =~ /^\s*$/) { push @check_block, ''; next; }
            my ($ws) = $l =~ /^(\s*)/;
            $indent //= length($ws);
            last if length($ws) < $indent;
            push @check_block, substr($l, $indent);
        }
    }
}
ok(scalar(@check_block) > 0, 'detect-changes run block (step id: check) extracted');
my $check_script = join("\n", @check_block) . "\n";
$check_script =~ s/\$\{\{\s*github\.event_name\s*\}\}/push/g;
unlike($check_script, qr/\$\{\{/, 'detect-changes block has no unresolved ${{ }} expression after the event_name substitution');

my %git_env = (
    GIT_CONFIG_GLOBAL   => '/dev/null',
    GIT_CONFIG_NOSYSTEM => '1',
    GIT_AUTHOR_NAME     => 'test',  GIT_AUTHOR_EMAIL    => 'test@example.invalid',
    GIT_COMMITTER_NAME  => 'test',  GIT_COMMITTER_EMAIL => 'test@example.invalid',
);

sub sh_in {
    my ($dir, @cmd) = @_;
    local %ENV = (%ENV, %git_env);
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) { chdir $dir or die "chdir $dir: $!"; open(STDOUT, '>', '/dev/null'); open(STDERR, '>&', \*STDOUT); exec(@cmd) or die "exec: $!"; }
    waitpid($pid, 0);
    return $? >> 8;
}

# Run the extracted block as GitHub would, return (prev, rust_changed).
sub run_detect {
    my ($repo, $tag) = @_;
    my $script = "$repo/../detect.sh";
    open(my $fh, '>', $script) or die $!; print $fh $check_script; close($fh);
    my $out_file = "$repo/../github_output";
    unlink $out_file;
    open(my $t, '>', $out_file) or die $!; close($t);
    local %ENV = (%ENV, %git_env, GITHUB_REF_NAME => $tag, GITHUB_OUTPUT => $out_file);
    my $pid = open(my $p, '-|');
    die "fork: $!" unless defined $pid;
    if (!$pid) { chdir $repo or die $!; open(STDERR, '>&', \*STDOUT); exec('bash', '-e', $script) or die "exec: $!"; }
    my $log = do { local $/; <$p> };
    close($p);
    my $rc = $? >> 8;
    my $prev = $log =~ /Previous tag:\s*(\S+)/ ? $1
             : $log =~ /forcing full build/    ? 'forced'
             :                                   'none';
    my $go = slurp($out_file);
    my ($rc_val) = $go =~ /^rust_changed=(\S+)/m;
    return ($prev, $rc_val // 'unset', $rc, $log);
}

sub commit_file {
    my ($repo, $path, $text, $msg) = @_;
    my $full = "$repo/$path";
    my $d = dirname($full);
    system('mkdir', '-p', $d) == 0 or die "mkdir $d";
    open(my $fh, '>>', $full) or die "$full: $!"; print $fh "$text\n"; close($fh);
    sh_in($repo, 'git', 'add', $path) == 0 or die "git add";
    sh_in($repo, 'git', 'commit', '-q', '-m', $msg) == 0 or die "git commit";
}

sub new_repo {
    my ($name) = @_;
    my $root = "$tmp/$name";
    my $repo = "$root/repo";
    system('mkdir', '-p', $repo) == 0 or die "mkdir";
    sh_in($repo, 'git', 'init', '-q') == 0 or die "git init";
    return $repo;
}

SKIP: {
    skip 'git is not installed', 6 if system('git --version >/dev/null 2>&1') != 0;
    skip 'bash is not installed', 6 if system('bash --version >/dev/null 2>&1') != 0;

    # Scenario one-beta: v3.5.8, Rust change, beta.1, Rust change, v4.0.0
    {
        my $repo = new_repo('one-beta');
        commit_file($repo, 'README.md', 'base', 'base');
        commit_file($repo, 'librespot-spoton/src/main.rs', 'fn a() {}', 'rust base');
        sh_in($repo, 'git', 'tag', 'v3.5.8') == 0 or die;
        commit_file($repo, 'librespot-spoton/src/main.rs', 'fn b() {}', 'rust change 1');
        sh_in($repo, 'git', 'tag', 'v4.0.0-beta.1') == 0 or die;
        my ($p1, $r1) = run_detect($repo, 'v4.0.0-beta.1');
        diag("one-beta: v4.0.0-beta.1 prev=$p1 rust_changed=$r1");
        commit_file($repo, 'librespot-spoton/src/main.rs', 'fn c() {}', 'rust change 2');
        sh_in($repo, 'git', 'tag', 'v4.0.0') == 0 or die;
        my ($p2, $r2) = run_detect($repo, 'v4.0.0');
        diag("one-beta: v4.0.0 prev=$p2 rust_changed=$r2");
        is($r1, 'true', 'detect-changes: beta.1 after a Rust change rebuilds');
        is($r2, 'true', 'detect-changes: final tag after one beta rebuilds');
    }

    # Scenario two-betas: v3.5.8, Rust change, beta.1, README-only, beta.2, Rust change, v4.0.0
    {
        my $repo = new_repo('two-betas');
        commit_file($repo, 'README.md', 'base', 'base');
        commit_file($repo, 'librespot-spoton/src/main.rs', 'fn a() {}', 'rust base');
        sh_in($repo, 'git', 'tag', 'v3.5.8') == 0 or die;
        commit_file($repo, 'librespot-spoton/src/main.rs', 'fn b() {}', 'rust change 1');
        sh_in($repo, 'git', 'tag', 'v4.0.0-beta.1') == 0 or die;
        my ($p1, $r1) = run_detect($repo, 'v4.0.0-beta.1');
        diag("two-betas: v4.0.0-beta.1 prev=$p1 rust_changed=$r1");
        commit_file($repo, 'README.md', 'doc only', 'readme only');
        sh_in($repo, 'git', 'tag', 'v4.0.0-beta.2') == 0 or die;
        my ($p2, $r2) = run_detect($repo, 'v4.0.0-beta.2');
        diag("two-betas: v4.0.0-beta.2 prev=$p2 rust_changed=$r2");
        commit_file($repo, 'librespot-spoton/src/main.rs', 'fn c() {}', 'rust change 2');
        sh_in($repo, 'git', 'tag', 'v4.0.0') == 0 or die;
        my ($p3, $r3) = run_detect($repo, 'v4.0.0');
        diag("two-betas: v4.0.0 prev=$p3 rust_changed=$r3");
        is($r1, 'true',  'detect-changes: two betas, beta.1 rebuilds');
        is($r2, 'false', 'detect-changes: two betas, beta.2 after a README-only change reuses (previous tag is beta.1)');
        is($r3, 'true',  'detect-changes: two betas, final tag rebuilds');
    }
}

done_testing();

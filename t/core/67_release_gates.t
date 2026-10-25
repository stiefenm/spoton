#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# 79-03: the two release gates carry their own selftests and public CI runs
# them without the rig (and without the off-repo literal files).
#
#   tools/ci/literal-gate.sh     selftest builds scratch repos with a SYNTHETIC
#                                literal and must read FAIL where one is planted
#                                and PASS where none is.
#   tools/ci/release-backstop.sh selftest builds scratch repos for the single
#                                release commit and must read FAIL on a planted
#                                .planning/ or soloist-releases/ path, on two
#                                commits and on a non-descendant.
#   tools/ci/build-release-commit.sh selftest builds scratch repos, checks the
#                                candidate (one parent, never-ship removed,
#                                overlay applied, deterministic) and must refuse
#                                a missing message file, an unknown base and a
#                                HEAD without the public .gitignore overlay.
#
# A gate that cannot fail is worse than no gate: every selftest must contain at
# least one MUST-FAIL case (expect=F got=F) and no case may disagree with itself.

# Resolve project root (t/<group>/x.t sits two levels below it)
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

plan skip_all => 'git is not installed'
    if system('git --version >/dev/null 2>&1') != 0;
plan skip_all => 'bash is not installed'
    if system('bash --version >/dev/null 2>&1') != 0;

# The selftests must not depend on the developer's literal files.
delete $ENV{LITERALS_DIR};

sub run_selftest {
    my ($script) = @_;
    my $out = qx{cd '$project_dir' && bash tools/ci/$script selftest 2>&1};
    my $rc  = $? >> 8;
    return ($out, $rc);
}

sub check_gate_selftest {
    my ($script, $min_must_fail) = @_;

    ok(-f "$project_dir/tools/ci/$script", "$script exists");

    my ($out, $rc) = run_selftest($script);
    is($rc, 0, "$script selftest exits 0");
    like($out, qr/^SELFTEST=PASS cases=\d+$/m, "$script selftest prints SELFTEST=PASS");

    my @cases = $out =~ /^case=(\S+) expect=([PFE]) got=([PFE])$/mg;
    my ($n, $bad, $must_fail) = (0, 0, 0);
    while (my ($name, $exp, $got) = splice(@cases, 0, 3)) {
        $n++;
        $bad++ if $exp ne $got;
        $must_fail++ if $exp eq 'F' && $got eq 'F';
    }
    cmp_ok($n, '>=', 1, "$script selftest lists its cases");
    is($bad, 0, "$script selftest: no case where expect differs from got");
    cmp_ok($must_fail, '>=', $min_must_fail,
        "$script selftest: at least $min_must_fail MUST-FAIL case(s) (expect=F got=F)");
    unlike($out, qr/^SELFTEST=FAIL/m, "$script selftest prints no SELFTEST=FAIL");
}

check_gate_selftest('literal-gate.sh', 1);
check_gate_selftest('release-backstop.sh', 4);
check_gate_selftest('build-release-commit.sh', 1);

done_testing();

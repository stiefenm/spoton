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

# 79-64 FULL-5 WR-09: test-baseline.sh retries every red test file once. A file
# that fails once and passes on the retry is a flake; it must be reported as
# `FLAKY <file>` and fail the gate unless it stands on the allow-list (with a
# reason). The fake suite below is the script's real input form: a test root
# with >= MIN_FILES (50) *.t files and a baseline in the record format.
{
    use File::Temp qw(tempdir);

    my $gate = "$project_dir/tools/ci/test-baseline.sh";

    # build_suite($with_flaky) -> ($parent, $baseline)
    #   50 always-green files plus, optionally, flaky.t which fails on its first
    #   run (it leaves a marker in the run directory) and passes on the second.
    my $build_suite = sub {
        my ($with_flaky) = @_;
        my $parent = tempdir('wr09-XXXXXX', TMPDIR => 1, CLEANUP => 1);
        mkdir "$parent/t" or die "mkdir: $!";
        my @rows;
        for my $i (1 .. 50) {
            my $f = sprintf('green%02d.t', $i);
            open my $fh, '>', "$parent/t/$f" or die "write $f: $!";
            print $fh "use Test::More tests => 1;\nok(1, 'green');\n";
            close $fh;
            push @rows, "t/$f\t1\tok";
        }
        if ($with_flaky) {
            open my $fh, '>', "$parent/t/flaky.t" or die "write flaky.t: $!";
            print $fh <<'EOT';
use Test::More tests => 1;
my $mark = 'flaky.mark';
if (-e $mark) { ok(1, 'second run passes') }
else { open my $m, '>', $mark or die; close $m; ok(0, 'first run fails') }
EOT
            close $fh;
            push @rows, "t/flaky.t\t1\tok";
        }
        my $n = scalar @rows;
        open my $bh, '>', "$parent/baseline.txt" or die "write baseline: $!";
        print $bh "$_\n" for @rows;
        print $bh "TOTAL_FILES=$n\nTOTAL_TESTS=$n\n";
        close $bh;
        return ($parent, "$parent/baseline.txt");
    };

    my $run = sub {
        my ($parent, $baseline, @opt) = @_;
        my $o = join ' ', map { "'$_'" } @opt;
        my $out = qx{cd '$parent' && bash '$gate' check '$baseline' t $o 2>/dev/null};
        return ($out, $? >> 8);
    };

    # Case 1: flaky.t fails once, passes on the retry, not allow-listed (the
    # default allow-list next to the script, which never names flaky.t).
    {
        my ($p, $b) = $build_suite->(1);
        my ($out, $rc) = $run->($p, $b);
        like($out, qr/^FLAKY flaky\.t\b/m, 'WR-09: a retried red file is reported FLAKY');
        is($rc, 1, 'WR-09: a FLAKY file that is not allow-listed fails the gate (exit 1)');
        like($out, qr/^BASELINE_CHECK=FAIL$/m, 'WR-09: not allow-listed FLAKY reads BASELINE_CHECK=FAIL');
    }

    # Case 2: the same run with flaky.t on the allow-list (entry with a reason).
    {
        my ($p, $b) = $build_suite->(1);
        my $allow = "$p/allow.txt";
        open my $ah, '>', $allow or die;
        print $ah "# basename<TAB>reason\nflaky.t\tknown race in the fake suite\n";
        close $ah;
        my ($out, $rc) = $run->($p, $b, '--flaky-list', $allow);
        like($out, qr/^FLAKY flaky\.t\b/m, 'WR-09: an allow-listed flake still prints its FLAKY line');
        is($rc, 0, 'WR-09: an allow-listed flake passes the gate (exit 0)');
        like($out, qr/^BASELINE_CHECK=PASS$/m, 'WR-09: allow-listed FLAKY reads BASELINE_CHECK=PASS');
    }

    # Case 3: an allow-list entry without a reason is refused (exit 2).
    {
        my ($p, $b) = $build_suite->(1);
        my $allow = "$p/allow-noreason.txt";
        open my $ah, '>', $allow or die; print $ah "flaky.t\n"; close $ah;
        my ($out, $rc) = $run->($p, $b, '--flaky-list', $allow);
        is($rc, 2, 'WR-09: an allow-list entry without a reason is refused (exit 2)');
    }

    # Case 4: every file passes the first time.
    {
        my ($p, $b) = $build_suite->(0);
        my ($out, $rc) = $run->($p, $b);
        unlike($out, qr/^FLAKY /m, 'WR-09: an all-green first run prints no FLAKY line');
        is($rc, 0, 'WR-09: an all-green first run passes (exit 0)');
        like($out, qr/^BASELINE_CHECK=PASS$/m, 'WR-09: all-green reads BASELINE_CHECK=PASS');
    }
}

# 79-64 FULL-5 WR-05: the literal gate looked at file CONTENT only and
# decompressed *.gz only. A literal that sits only in a file name, or only
# inside a .zip member, passed. Release-like scratch trees (a git repo for the
# tree and worktree modes, an extracted directory for the dir mode) with a
# SYNTHETIC literal must read FAIL, and the gate must never print the literal.
{
    use File::Temp qw(tempdir);
    use File::Path qw(make_path);
    use IO::Compress::Zip qw(zip $ZipError);

    my $gate = "$project_dir/tools/ci/literal-gate.sh";
    my $SUB  = 'zqlit-sub-6464';
    my $WRD  = 'zqlitword6464';

    my $lits = tempdir('wr05-lits-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    for (['literals-substr.txt', $SUB], ['literals-word.txt', $WRD]) {
        open my $fh, '>', "$lits/$_->[0]" or die; print $fh "$_->[1]\n"; close $fh;
    }

    my $write = sub {
        my ($path, $content) = @_;
        (my $d = $path) =~ s{/[^/]+$}{};
        make_path($d);
        open my $fh, '>', $path or die "write $path: $!"; print $fh $content; close $fh;
    };
    my $mkzip = sub {
        my ($path, $member, $content) = @_;
        (my $d = $path) =~ s{/[^/]+$}{};
        make_path($d);
        zip(\$content => $path, Name => $member) or die "zip: $ZipError";
    };
    my $git_repo = sub {
        my ($fill) = @_;
        my $r = tempdir('wr05-repo-XXXXXX', TMPDIR => 1, CLEANUP => 1);
        system("git -C '$r' init -q") == 0 or die;
        $write->("$r/README.txt", "release tree\n");
        $fill->($r);
        system("cd '$r' && git add -A -f && git -c user.name=t -c user.email=t\@t -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m clean") == 0 or die;
        return $r;
    };
    my $run = sub {
        my ($cwd, @args) = @_;
        my $a = join ' ', map { "'$_'" } @args;
        my $out = qx{cd '$cwd' && LITERALS_DIR='$lits' bash '$gate' $a 2>&1};
        return ($out, $? >> 8);
    };
    my $expect_fail = sub {
        my ($name, $cwd, @args) = @_;
        my ($out, $rc) = $run->($cwd, @args);
        is($rc, 1, "WR-05 $name: gate exits 1");
        like($out, qr/^LITERAL_GATE=FAIL$/m, "WR-05 $name: LITERAL_GATE=FAIL");
        unlike($out, qr/zqlit/i, "WR-05 $name: the gate output never carries the literal");
    };

    # literal only in a file name (substring and whole-word variants)
    my $rn = $git_repo->(sub { $write->("$_[0]/tools/uat/$SUB-probe.sh", "echo fine\n") });
    $expect_fail->('name-substr tree',     $rn, 'tree', 'HEAD');
    $expect_fail->('name-substr worktree', $rn, 'worktree');
    my $rw = $git_repo->(sub { $write->("$_[0]/t/fixtures/$WRD/run1.txt", "fine\n") });
    $expect_fail->('name-word tree', $rw, 'tree', 'HEAD');

    # literal only inside a .zip member (deflated, invisible to the byte passes)
    my $rz = $git_repo->(sub { $mkzip->("$_[0]/data/bundle.zip", 'inner.txt', ("x" x 200) . " $SUB " . ("y" x 200) . "\n") });
    $expect_fail->('zip-member tree',     $rz, 'tree', 'HEAD');
    $expect_fail->('zip-member worktree', $rz, 'worktree');

    # dir mode (an extracted release zip): name and zip member
    my $dn = tempdir('wr05-dir-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    $write->("$dn/Plugins/SpotOn/$SUB.txt", "fine\n");
    $expect_fail->('name dir', $dn, 'dir', $dn);
    my $dz = tempdir('wr05-dirz-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    $mkzip->("$dz/inner.zip", 'm.txt', ("x" x 200) . " $WRD " . ("y" x 200) . "\n");
    $expect_fail->('zip-member dir', $dz, 'dir', $dz);

    # MUST-PASS: the same shapes without a literal stay PASS
    my $rc0 = $git_repo->(sub {
        $write->("$_[0]/tools/uat/plain-probe.sh", "echo fine\n");
        $mkzip->("$_[0]/data/bundle.zip", 'inner.txt', "nothing to see\n");
    });
    my ($out0, $rc0x) = $run->($rc0, 'tree', 'HEAD');
    is($rc0x, 0, 'WR-05 clean names and zip member: gate exits 0');
    like($out0, qr/^LITERAL_GATE=PASS$/m, 'WR-05 clean names and zip member: LITERAL_GATE=PASS');
}

# 79-64 FULL-5 WR-06: the beta descriptor docs/beta/repo.xml sat outside every
# release check, and its version form is a trap: `4.0.0-beta.2.2` rates higher
# than the installed `4.0.0beta2.2` in LMS, so the plugin manager offers the
# same zip forever. The backstop must read the descriptor of the candidate.
# Real input: the project's own docs/beta/repo.xml and install.xml, copied into
# a scratch candidate; the mutant is the same copy with the trap form.
{
    use File::Temp qw(tempdir);
    use File::Path qw(make_path);
    use File::Compare qw(compare);

    my $backstop = "$project_dir/tools/ci/release-backstop.sh";
    my $slurp = sub { my ($f) = @_; open my $fh, '<', $f or die "read $f: $!"; local $/; my $c = <$fh>; close $fh; $c };
    my $spew  = sub { my ($f, $c) = @_; (my $d = $f) =~ s{/[^/]+$}{}; make_path($d); open my $fh, '>', $f or die "write $f: $!"; print $fh $c; close $fh };
    my $gitc  = "git -c user.name=t -c user.email=t\@t -c commit.gpgsign=false -c core.hooksPath=/dev/null";

    my $real_repo = $slurp->("$project_dir/docs/beta/repo.xml");
    my $real_inst = $slurp->("$project_dir/Plugins/SpotOn/install.xml");

    # candidate($repo_xml, $install_xml) -> ($out, $rc): one commit on base0
    my $candidate = sub {
        my ($repo_xml, $install_xml) = @_;
        my $r = tempdir('wr06-XXXXXX', TMPDIR => 1, CLEANUP => 1);
        $spew->("$r/src/a.txt", "plugin\n");
        system("cd '$r' && git init -q && git add -A && $gitc commit -q -m base && git branch -M base0 && git checkout -q -b cand") == 0 or die;
        $spew->("$r/docs/beta/repo.xml", $repo_xml) if defined $repo_xml;
        $spew->("$r/Plugins/SpotOn/install.xml", $install_xml) if defined $install_xml;
        system("cd '$r' && git add -A -f && $gitc commit -q -m cand") == 0 or die;
        my $out = qx{cd '$r' && bash '$backstop' cand base0 2>&1};
        return ($out, $? >> 8, $r);
    };

    # MUST-PASS: the real files as they are in this tree
    my ($o1, $rc1) = $candidate->($real_repo, $real_inst);
    is($rc1, 0, 'WR-06 real descriptor and install.xml: backstop exits 0');
    like($o1, qr/^CHECK beta ok /m, 'WR-06 real files: the backstop checks the beta descriptor (CHECK beta ok)');

    # MUST-FAIL: the real descriptor with the trap version form (cmp-checked mutant)
    (my $trap = $real_repo) =~ s/(<plugin\b[^>]*?\sversion=")(\d+\.\d+\.\d+)beta(\d+(?:\.\d+)?)"/$1$2-beta.$3"/s;
    isnt($trap, $real_repo, 'WR-06 mutant: the trap-form copy differs from the real descriptor');
    my ($o2, $rc2, $r2) = $candidate->($trap, $real_inst);
    isnt(compare("$r2/docs/beta/repo.xml", "$project_dir/docs/beta/repo.xml"), 0, 'WR-06 mutant: cmp says the committed copy differs from the real file');
    is($rc2, 1, 'WR-06 trap form 4.0.0-beta.N in the descriptor: backstop exits 1');
    like($o2, qr/^BACKSTOP=FAIL reason=beta /m, 'WR-06 trap form: BACKSTOP=FAIL reason=beta');

    # MUST-FAIL: the url names a different tag than the version
    (my $url = $real_repo) =~ s{(/releases/download/v)(\d+\.\d+\.\d+-beta\.\d+(?:\.\d+)?)(/SpotOn-v)\2(\.zip)}{${1}9.9.9-beta.9${3}9.9.9-beta.9$4};
    isnt($url, $real_repo, 'WR-06 mutant: the url copy differs from the real descriptor');
    my ($o3, $rc3) = $candidate->($url, $real_inst);
    is($rc3, 1, 'WR-06 url names another tag: backstop exits 1');
    like($o3, qr/^BACKSTOP=FAIL reason=beta /m, 'WR-06 url names another tag: BACKSTOP=FAIL reason=beta');

    # MUST-FAIL: the descriptor offers a newer version than the candidate ships
    (my $inst_old = $real_inst) =~ s{<version>(\d+\.\d+\.\d+)beta(\d+)(?:\.\d+)?</version>}{"<version>$1beta" . ($2 > 1 ? $2 - 1 : 0) . "</version>"}e;
    isnt($inst_old, $real_inst, 'WR-06 mutant: the older install.xml copy differs from the real one');
    my ($o4, $rc4) = $candidate->($real_repo, $inst_old);
    is($rc4, 1, 'WR-06 descriptor ahead of install.xml: backstop exits 1');
    like($o4, qr/^BACKSTOP=FAIL reason=beta /m, 'WR-06 descriptor ahead of install.xml: BACKSTOP=FAIL reason=beta');
}

done_testing();

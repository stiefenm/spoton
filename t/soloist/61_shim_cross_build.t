#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use Cwd qw(abs_path);

# 79-26 (D-17): CI cross-build of the fake-libpulse shim.
#
# Defect (HEAD ee8a829a): in a fresh checkout the tracked x86_64
# Plugins/SpotOn/Bin/fake-libpulse/libpulse.so.0 is not older than its .c
# (same checkout mtime), so `make -C ... CC=<cross-gcc>` prints "Nothing to be
# done" and the Prepare step copies the x86_64 ELF into Bin/aarch64-linux and
# Bin/armhf-linux. The Verify step only checks the glibc NEEDED entry and
# passes the wrong ELF.
#
# This test runs the workflow's OWN step text (Build libpulse.so.0, Prepare
# binary, Verify binary), extracted from the job block with the matrix values
# substituted, in a sandbox whose three shim files share one mtime (the
# fresh-checkout condition). It needs no LMS modules and no rig.
#
#   SHIM_BUILD_WORKFLOW   path of the zip workflow (default
#                         .github/workflows/build-librespot.yml, job
#                         build-fake-libpulse); a MUST-FAIL dry run points it
#                         at the ee8a829a text.
#   SHIM_MANUAL_WORKFLOW  path of the manual workflow (default
#                         .github/workflows/build-fake-libpulse.yml, job build);
#                         same cells without the real cross chain (the step
#                         text is shared, one real chain is enough evidence).
#
# Linux only (plan skip_all on other systems); a missing tool dies, never
# skips. Only in-file SKIP blocks (cross compiler not installed) may skip, so
# the whole file never counts as skipped on the amputation leg.

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

plan skip_all => 'shim cross-build test is Linux-only' unless $^O eq 'linux';

for my $tool (qw(make bash readelf file)) {
    my $found = `command -v $tool 2>/dev/null`;
    die "required tool missing: $tool (79-26: die, never skip)\n" unless length $found;
}

my $shim_src_dir = "$project_dir/Plugins/SpotOn/Bin/fake-libpulse";
for my $f (qw(Makefile fake-libpulse.c libpulse.so.0)) {
    die "missing $shim_src_dir/$f\n" unless -f "$shim_src_dir/$f";
}

# Machine value of `LC_ALL=C readelf -h` per matrix bin_dir (the test's own map).
my %MACHINE = (
    'x86_64-linux'  => 'Advanced Micro Devices X86-64',
    'aarch64-linux' => 'AArch64',
    'armhf-linux'   => 'ARM',
);
my @BIN_DIRS = ('x86_64-linux', 'aarch64-linux', 'armhf-linux');
my $FIXED_MTIME = 1_700_000_000;

my $BUILD_STEP   = 'Build libpulse.so.0';
my $PREPARE_STEP = 'Prepare binary';
my $VERIFY_STEP  = 'Verify binary (glibc, not musl -- Pitfall 3)';

sub slurp_lines {
    my ($file) = @_;
    open(my $fh, '<', $file) or die "Cannot open $file: $!";
    my @l = <$fh>;
    close($fh);
    chomp @l;
    return @l;
}

sub unquote {
    my ($v) = @_;
    $v =~ s/^\s+|\s+$//g;
    if ($v =~ /^'(.*)'$/ || $v =~ /^"(.*)"$/) { return $1; }
    return $v;
}

# The job block: from its key line to the next two-space job key.
sub job_block {
    my ($lines, $job) = @_;
    my @block;
    my $in = 0;
    for my $l (@$lines) {
        if (!$in) {
            $in = 1 if $l =~ /^  \Q$job\E:\s*$/;
            next;
        }
        last if $l =~ /^  [A-Za-z0-9_-]+:\s*$/;
        push @block, $l;
    }
    return \@block;
}

sub matrix_entries {
    my ($block) = @_;
    my (@entries, $in_inc);
    for my $l (@$block) {
        if ($l =~ /^\s+include:\s*$/) { $in_inc = 1; next; }
        last if $in_inc && $l =~ /^\s+steps:\s*$/;
        next unless $in_inc;
        if ($l =~ /^\s+-\s+(\w+):\s*(.*?)\s*$/) {
            push @entries, { $1 => unquote($2) };
        } elsif ($l =~ /^\s+(\w+):\s*(.*?)\s*$/ && @entries) {
            $entries[-1]{$1} = unquote($2);
        }
    }
    return \@entries;
}

# name => de-indented `run: |` body of the first step with that name.
sub step_bodies {
    my ($block) = @_;
    my (%body, $name);
    for (my $i = 0; $i < @$block; $i++) {
        my $l = $block->[$i];
        if ($l =~ /^\s+-\s+name:\s*(.*?)\s*$/) { $name = $1; next; }
        next unless defined $name && $l =~ /^(\s+)run:\s*\|\s*$/;
        my $run_indent = length $1;
        my (@raw, $strip);
        for (my $j = $i + 1; $j < @$block; $j++) {
            my $b = $block->[$j];
            if ($b =~ /^\s*$/) { push @raw, ''; next; }
            my ($ind) = $b =~ /^(\s*)/;
            last if length($ind) <= $run_indent;
            $strip //= length $ind;
            push @raw, substr($b, $strip);
        }
        $body{$name} //= join("\n", @raw) . "\n";
    }
    return \%body;
}

sub substitute {
    my ($text, $entry, $cc_override) = @_;
    my %e = %$entry;
    $e{cc} = $cc_override if defined $cc_override;
    $text =~ s/\$\{\{\s*matrix\.(\w+)\s*\}\}/exists $e{$1} ? $e{$1} : "\${{ matrix.$1 }}"/ge;
    return $text;
}

# A fresh-checkout sandbox: the three shim files share one mtime.
sub make_sandbox {
    my $sb = tempdir('shim-cross-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    my $d  = "$sb/Plugins/SpotOn/Bin/fake-libpulse";
    make_path($d);
    for my $f (qw(Makefile fake-libpulse.c libpulse.so.0)) {
        copy("$shim_src_dir/$f", "$d/$f") or die "copy $f: $!";
        utime($FIXED_MTIME, $FIXED_MTIME, "$d/$f") or die "utime $f: $!";
    }
    return $sb;
}

# bash --noprofile --norc -eo pipefail -c <text> from the sandbox root, LC_ALL=C.
sub run_step {
    my ($sb, $text) = @_;
    my $pid = open(my $fh, '-|');
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        chdir $sb or die "chdir $sb: $!";
        $ENV{LC_ALL} = 'C';
        open(STDERR, '>&', \*STDOUT);
        exec('bash', '--noprofile', '--norc', '-eo', 'pipefail', '-c', $text) or die "exec: $!";
    }
    local $/;
    my $out = <$fh>;
    close($fh);
    return ($? >> 8, $out // '');
}

sub write_fake_cc {
    my ($sb, $bin_dir) = @_;
    my $path = "$sb/fakecc";
    open(my $fh, '>', $path) or die "write $path: $!";
    print $fh <<"SH";
#!/bin/sh
out=
while [ \$# -gt 0 ]; do
  if [ "\$1" = "-o" ]; then out=\$2; fi
  shift
done
printf 'FAKECC $bin_dir\\n' > "\$out"
SH
    close($fh);
    chmod 0755, $path;
    return $path;
}

sub read_file {
    my ($f) = @_;
    open(my $fh, '<', $f) or return undef;
    local $/;
    my $c = <$fh>;
    close($fh);
    return $c;
}

sub machine_of {
    my ($file) = @_;
    my $out = `LC_ALL=C readelf -h "$file" 2>&1`;
    return $out =~ /^\s*Machine:\s*(.+?)\s*$/m ? $1 : "(no Machine: $out)";
}

# All cells for one workflow file. $label names the cells, $real_chain turns
# the real cross-compiler chain on.
sub workflow_cells {
    my ($label, $path, $job, $real_chain) = @_;
    note("workflow: $path");
    die "workflow file missing: $path\n" unless -f $path;

    my @lines = slurp_lines($path);
    my $block = job_block(\@lines, $job);
    ok(scalar(@$block) > 0, "79-26: $label: job '$job' found in the workflow");

    my $entries = matrix_entries($block);
    is_deeply([ map { $_->{bin_dir} // '' } @$entries ], [@BIN_DIRS],
        "79-26: $label: matrix holds exactly x86_64-linux, aarch64-linux, armhf-linux");

    my $bodies = step_bodies($block);
    for my $s ($BUILD_STEP, $PREPARE_STEP, $VERIFY_STEP) {
        ok(defined $bodies->{$s}, "79-26: $label: step '$s' has a run body");
    }

    for my $bin_dir (@BIN_DIRS) {
        my ($entry) = grep { ($_->{bin_dir} // '') eq $bin_dir } @$entries;
        $entry //= { bin_dir => $bin_dir, cc => 'cc' };

        # The matrix entry carries the ELF machine the Verify step must expect.
        is($entry->{elf_machine}, $MACHINE{$bin_dir},
            "79-26: $label: $bin_dir matrix entry carries elf_machine '$MACHINE{$bin_dir}'");

        my %text = map { $_ => substitute($bodies->{$_} // '', $entry) } ($BUILD_STEP, $PREPARE_STEP, $VERIFY_STEP);
        my $unsub = join(',', grep { $text{$_} =~ /\$\{\{/ } sort keys %text);
        is($unsub, '', "79-26: $label: $bin_dir step text has no unsubstituted \${{ expression");
        my $runnable = ($unsub eq '' && length $text{$BUILD_STEP} && length $text{$PREPARE_STEP} && length $text{$VERIFY_STEP});

        # Fake compiler: the Build step must really invoke the matrix compiler
        # although the sandbox holds a .so that is not older than its .c.
        {
            my $name = "79-26: $label: $bin_dir fresh-checkout build invokes the compiler (fake cc marker reaches Bin/$bin_dir)";
            if (!$runnable) { fail($name); }
            else {
                my $sb = make_sandbox();
                my $fake = write_fake_cc($sb, $bin_dir);
                my %ft = map { $_ => substitute($bodies->{$_}, $entry, $fake) } ($BUILD_STEP, $PREPARE_STEP);
                my ($rb, $ob) = run_step($sb, $ft{$BUILD_STEP});
                my ($rp, $op) = run_step($sb, $ft{$PREPARE_STEP});
                my $got = read_file("$sb/Plugins/SpotOn/Bin/$bin_dir/libpulse.so.0");
                $got = '(missing)' unless defined $got;
                my $ok = is($got, "FAKECC $bin_dir\n", $name);
                diag("build rc=$rb prepare rc=$rp\n$ob") unless $ok;
            }
        }

        # Verify against the tracked x86_64 shim placed under this arch name.
        {
            my $name;
            if ($bin_dir eq 'x86_64-linux') {
                $name = "79-26: $label: $bin_dir Verify passes on the x86_64 shim (MUST-PASS)";
            } else {
                $name = "79-26: $label: $bin_dir Verify fails on the x86_64 shim (wrong-arch MUST-FAIL)";
            }
            if (!$runnable) { fail($name); }
            else {
                my $sb = make_sandbox();
                my $dest = "$sb/Plugins/SpotOn/Bin/$bin_dir";
                make_path($dest);
                copy("$shim_src_dir/libpulse.so.0", "$dest/libpulse.so.0") or die "copy: $!";
                my ($rv, $ov) = run_step($sb, $text{$VERIFY_STEP});
                if ($bin_dir eq 'x86_64-linux') {
                    my $ok = is($rv, 0, $name);
                    diag($ov) unless $ok;
                } else {
                    my $ok = isnt($rv, 0, $name);
                    diag("Verify exit 0 on a wrong-architecture member:\n$ov") unless $ok;
                }
            }
        }

        # Real chain when the matrix compiler exists on this machine.
        if ($real_chain) {
            SKIP: {
                my $cc = $entry->{cc} // '';
                my $found = length $cc ? `command -v $cc 2>/dev/null` : '';
                skip("79-26: $label: $bin_dir real chain (compiler '$cc' not on PATH)", 1) unless length $found;
                my $name = "79-26: $label: $bin_dir real Build, Prepare, Verify give Machine '$MACHINE{$bin_dir}'";
                if (!$runnable) { fail($name); }
                else {
                    my $sb = make_sandbox();
                    my @rcs;
                    my $all = '';
                    for my $s ($BUILD_STEP, $PREPARE_STEP, $VERIFY_STEP) {
                        my ($r, $o) = run_step($sb, $text{$s});
                        push @rcs, $r;
                        $all .= $o;
                    }
                    my $member = "$sb/Plugins/SpotOn/Bin/$bin_dir/libpulse.so.0";
                    my $machine = -f $member ? machine_of($member) : '(member missing)';
                    my $ok = ok(
                        !(grep { $_ != 0 } @rcs) && $machine eq $MACHINE{$bin_dir},
                        $name);
                    diag("exit codes build/prepare/verify: @rcs; Machine: $machine\n$all") unless $ok;
                    note("$bin_dir real chain: Machine=$machine exit codes=@rcs");
                }
            }
        }
    }
}

workflow_cells(
    'zip',
    $ENV{SHIM_BUILD_WORKFLOW} || "$project_dir/.github/workflows/build-librespot.yml",
    'build-fake-libpulse',
    1,
);
workflow_cells(
    'manual',
    $ENV{SHIM_MANUAL_WORKFLOW} || "$project_dir/.github/workflows/build-fake-libpulse.yml",
    'build',
    0,
);

done_testing();

package Plugins::SpotOn::Unified::HostEnv;

# 79-57 (GH #183): facts about the host LMS runs on, without any Slim::*
# dependency (loadable on its own, inside a bare container perl too).
#
# runsInContainer($root) -- 1 when the system looks like a container, else 0:
#   - $root/.dockerenv exists (Docker),
#   - $root/run/.containerenv exists (Podman),
#   - $root/proc/1/cgroup names docker, containerd, kubepods or lxc
#     (cgroup v1 and the cgroup v2 forms that keep the path).
# $root defaults to '' (the real root); tests pass a fixture root. Cached per
# root for the process lifetime: a running LMS does not change containers.
# Only reads; never runs anything.

use strict;
use warnings;

my %cache;

sub runsInContainer {
    shift if @_ && defined $_[0] && $_[0] eq __PACKAGE__;
    my ($root) = @_;
    $root = '' unless defined $root;

    return $cache{$root} if exists $cache{$root};

    my $found = 0;
    if (-e "$root/.dockerenv" || -e "$root/run/.containerenv") {
        $found = 1;
    }
    elsif (open(my $fh, '<', "$root/proc/1/cgroup")) {
        local $/;
        my $cg = <$fh> // '';
        close($fh);
        $found = 1 if $cg =~ m{(?:docker|containerd|kubepods|lxc)}i;
    }

    return $cache{$root} = $found;
}

sub _resetCache { %cache = () }

1;

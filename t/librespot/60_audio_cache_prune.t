#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# ============================================================
# 74b-04 Task 3 (D-17, T-74b-14, T-74b-15): the librespot audio cache is
# bounded from Perl at daemon start. The harness head is the isolated-require
# stub harness of t/librespot/39_daemon_buffer_latency.t (real
# Unified::Daemon, stubbed LMS). Every fixture lives in a tempdir - never the
# real cache dir /var/lib/squeezeboxserver/cache/spoton. Layout (confirmed
# from librespot-core core/src/cache.rs file_path): <audio location>/<first
# two hex chars>/<remaining 38 hex chars>.
# ============================================================

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

my $module = "$project_dir/Plugins/SpotOn/Unified/Daemon.pm";
unless (-f $module) {
    die "Plugins/SpotOn/Unified/Daemon.pm not present in this checkout -- wrong project root or broken checkout (84-09: die, never skip)\n";
}

my $stub_dir  = tempdir(CLEANUP => 1);
my $cache_dir = tempdir(CLEANUP => 1);
make_path("$cache_dir/spoton");

sub write_stub {
    my ($dir, $pkg, $code) = @_;
    my @parts = split /::/, $pkg;
    my $file  = pop @parts;
    my $path  = $dir . '/' . join('/', @parts);
    make_path($path) unless -d $path;
    open(my $fh, '>', "$path/$file.pm") or die "Cannot write stub $pkg: $!";
    print $fh $code;
    close($fh);
}

write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub logger { return bless {}, 'Slim::Utils::Log' }
sub info  { }
sub warn  { }
sub error { }
sub debug { }
sub is_info  { 1 }
sub is_debug { 0 }
sub AUTOLOAD { }
sub can { 1 }
1;
END

my $prefs_cache_dir = $cache_dir;
write_stub($stub_dir, 'Slim::Utils::Prefs', <<"END");
package Slim::Utils::Prefs;
my \%_ns_store = ( server => { cachedir => '$prefs_cache_dir', httpport => 9000, authorize => 0 } );
sub import {
    my \$class = shift;
    my \$caller = caller;
    no strict 'refs';
    *{"\${caller}::preferences"} = \\\&preferences;
}
sub preferences { my \$ns = \$_[0] eq 'Slim::Utils::Prefs' ? \$_[1] : \$_[0]; return bless { _ns => \$ns }, 'Slim::Utils::Prefs'; }
sub get { my (\$self, \$key) = \@_; return \$_ns_store{ \$self->{_ns} }{\$key}; }
sub set { my (\$self, \$key, \$val) = \@_; \$_ns_store{ \$self->{_ns} }{\$key} = \$val; }
sub client {
    my (\$self, \$client) = \@_;
    my \$ns = \$self->{_ns} . '_client';
    \$_ns_store{\$ns} ||= { enableSpotifyConnect => 1, discoveryDisabledByCrashLoop => 0, disableDiscovery => 0, digitalVolumeControl => undef, enableAutoplay => undef };
    return bless { _ns => \$ns }, 'Slim::Utils::Prefs';
}
1;
END

write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
sub killTimers { }
sub setTimer   { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Accessor', <<'END');
package Slim::Utils::Accessor;
use Scalar::Util qw(weaken);
my %slot;
sub new { return bless [], shift }
sub mk_accessor {
    my ($class, $type, @names) = @_;
    no strict 'refs';
    for my $name (@names) {
        my $n = $slot{$class}{$name};
        if (!defined $n) {
            $n = keys %{ $slot{$class} };
            $slot{$class}{$name} = $n;
        }
        *{"${class}::${name}"} = sub {
            my $self = shift;
            $self->[$n] = shift if @_;
            return $self->[$n];
        };
    }
}
1;
END

write_stub($stub_dir, 'Slim::Player::Client', <<'END');
package Slim::Player::Client;
our $FAKE_CLIENT;
sub getClient { return $FAKE_CLIENT; }
1;
END

write_stub($stub_dir, 'Slim::Utils::Network', <<'END');
package Slim::Utils::Network;
sub serverAddr { return '127.0.0.1'; }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Helper', <<'END');
package Plugins::SpotOn::Helper;
sub get { return '/fake/soloist-helper'; }
sub getCapability { return 0; }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Plugin', <<'END');
package Plugins::SpotOn::Plugin;
sub _bitrateConfigForClient { return 320; }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Unified::DaemonManager', <<'END');
package Plugins::SpotOn::Unified::DaemonManager;
sub deviceNameForClient { return 'Test Player'; }
sub resolvePassthroughForClient { return 0; }
1;
END

# Records the argv the daemon would spawn, without launching a real process.
write_stub($stub_dir, 'Proc::Background', <<'END');
package Proc::Background;
our @LAST_ARGS;
our $LAST_PATH;
sub new {
    my ($class, $opts, $path, @args) = @_;
    @LAST_ARGS = @args;
    $LAST_PATH = $path;
    return bless {}, $class;
}
sub alive { return 1; }
1;
END

BEGIN {
    no warnings 'redefine';
    *main::INFOLOG   = sub () { 0 };
    *main::ISWINDOWS  = sub () { 0 };
    *main::ISMAC      = sub () { 0 };
}

unshift @INC, $stub_dir, $project_dir;

require_ok('Slim::Player::Client')
    or BAIL_OUT("Failed to load the Slim::Player::Client stub");
require_ok('Proc::Background')
    or BAIL_OUT("Failed to load the Proc::Background stub");

require_ok('Slim::Utils::Network')
    or BAIL_OUT("Failed to load the Slim::Utils::Network stub");
require_ok('Plugins::SpotOn::Helper')
    or BAIL_OUT("Failed to load the Plugins::SpotOn::Helper stub");
require_ok('Plugins::SpotOn::Plugin')
    or BAIL_OUT("Failed to load the Plugins::SpotOn::Plugin stub");
require_ok('Plugins::SpotOn::Unified::DaemonManager')
    or BAIL_OUT("Failed to load the DaemonManager stub");

require_ok('Plugins::SpotOn::Unified::Daemon')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Unified::Daemon");

package Test::FakeClient;
sub new {
    my ($class, %args) = @_;
    return bless { volume => 50, %args }, $class;
}
sub isSynced { return $_[0]->{isSynced}; }
sub model    { return $_[0]->{model} // 'squeezelite'; }
sub volume   { return $_[0]->{volume}; }

package main;

my $D  = 'Plugins::SpotOn::Unified::Daemon';
my $KB = 1024;

# ---- helpers: fixtures with distinct mtimes
my $hex38 = sub { my $n = shift; return sprintf('%038x', $n) };
my $mkfile = sub {
    my ($path, $bytes, $mtime) = @_;
    open(my $fh, '>:raw', $path) or die "mk $path: $!";
    print $fh 'x' x $bytes;
    close($fh);
    utime($mtime, $mtime, $path) if defined $mtime;
};

# a prune that dies shows up as a failing cell (one DIED element), not as an
# aborted test file
my $prune = sub {
    my @r = eval { $D->_pruneAudioCache(@_) };
    return $@ ? ("DIED: $@") : @r;
};

is($D->can('AUDIO_CACHE_LIMIT_BYTES') ? $D->AUDIO_CACHE_LIMIT_BYTES : undef, 1024 * 1024 * 1024,
    'D-17: AUDIO_CACHE_LIMIT_BYTES is 1 GiB');

# ==================================================================
# Cell 1: three 600 KB cache files, limit 1 MB -> the two oldest go.
# ==================================================================
{
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/ab");
    $mkfile->("$dir/credentials.json", 300, time() - 9000);
    $mkfile->("$dir/volume", 5, time() - 9000);
    my $now = time();
    $mkfile->("$dir/ab/" . $hex38->(1), 600 * $KB, $now - 3000);    # oldest
    $mkfile->("$dir/ab/" . $hex38->(2), 600 * $KB, $now - 2000);
    $mkfile->("$dir/ab/" . $hex38->(3), 600 * $KB, $now - 1000);    # newest

    my @r = $prune->($dir, 1024 * $KB);
    is_deeply(\@r, [ 2, 1228800 ], 'D-17: two oldest files deleted, (count, bytes) returned');
    ok(!-e "$dir/ab/" . $hex38->(1) && !-e "$dir/ab/" . $hex38->(2), 'D-17: the two oldest cache files are gone');
    ok(-e "$dir/ab/" . $hex38->(3), 'D-17: the newest cache file stays');
    ok(-s "$dir/credentials.json" == 300 && -e "$dir/volume", 'D-17: credentials.json and volume stay');
}

# ==================================================================
# Cell 2: everything that is not a strict cache file survives, even with a
# limit that would delete every eligible file (T-74b-14).
# ==================================================================
{
    my $dir     = tempdir(CLEANUP => 1);
    my $outside = tempdir(CLEANUP => 1);
    make_path("$dir/ab", "$dir/zz", "$dir/ef", "$dir/abc");
    $mkfile->("$dir/credentials.json", 300, time() - 9000);
    $mkfile->("$dir/volume", 5, time() - 9000);
    $mkfile->("$dir/ab/" . $hex38->(1), 600 * $KB, time() - 3000);           # eligible
    $mkfile->("$dir/ab/" . $hex38->(2), 600 * $KB, time() - 2000);           # eligible
    $mkfile->("$dir/ab/notahexname", 600 * $KB, time() - 9000);              # wrong name
    $mkfile->("$dir/ab/" . uc($hex38->(255)), 600 * $KB, time() - 9000);     # upper case hex
    $mkfile->("$dir/ab/" . substr($hex38->(7), 1), 600 * $KB, time() - 9000);   # 37 chars
    $mkfile->("$dir/ab/0" . $hex38->(7), 600 * $KB, time() - 9000);          # 39 chars
    $mkfile->("$dir/zz/" . $hex38->(3), 600 * $KB, time() - 9000);           # non-hex dir
    $mkfile->("$dir/abc/" . $hex38->(4), 600 * $KB, time() - 9000);          # 3-char dir
    $mkfile->("$dir/loose" . $hex38->(5), 600 * $KB, time() - 9000);         # file in the account dir itself

    # symlinked directory 'cd' pointing outside, holding a 38-hex file
    $mkfile->("$outside/" . $hex38->(8), 600 * $KB, time() - 9000);
    symlink($outside, "$dir/cd") or die "symlink: $!";
    # real two-hex dir holding a 38-hex SYMLINK to a file outside
    $mkfile->("$outside/target-file", 600 * $KB, time() - 9000);
    symlink("$outside/target-file", "$dir/ef/" . $hex38->(9)) or die "symlink: $!";

    my @r = $prune->($dir, 1);
    is_deeply(\@r, [ 2, 1228800 ], 'D-17: only the two strict cache files are deleted');
    ok(-s "$dir/credentials.json" == 300 && -e "$dir/volume", 'D-17: credentials.json and volume survive an aggressive prune');
    ok(-e "$dir/ab/notahexname", 'D-17: a non-hex file name in a hex dir survives');
    ok(-e "$dir/ab/" . uc($hex38->(255)), 'D-17: an upper case hex name survives');
    ok(-e "$dir/ab/" . substr($hex38->(7), 1) && -e "$dir/ab/0" . $hex38->(7), 'D-17: 37- and 39-character names survive');
    ok(-e "$dir/zz/" . $hex38->(3), 'D-17: a 38-hex file in a non-hex directory survives');
    ok(-e "$dir/abc/" . $hex38->(4), 'D-17: a 38-hex file in a three-character directory survives');
    ok(-e "$dir/loose" . $hex38->(5), 'D-17: a file directly in the account dir survives');
    ok(-l "$dir/cd" && -e "$outside/" . $hex38->(8), 'D-17: a symlinked hex directory is not followed (target file untouched)');
    ok(-l "$dir/ef/" . $hex38->(9) && -e "$outside/target-file", 'D-17: a symlinked 38-hex file is not deleted and its target is untouched');
}

# ==================================================================
# Cell 3: under the limit, missing and empty dirs never die.
# ==================================================================
{
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/ab");
    $mkfile->("$dir/ab/" . $hex38->(1), 100 * $KB, time() - 100);
    my @r = $prune->($dir, 1024 * $KB);
    is_deeply(\@r, [ 0, 0 ], 'D-17: a total below the limit deletes nothing');
    ok(-e "$dir/ab/" . $hex38->(1), 'D-17: the file below the limit stays');

    my $empty = tempdir(CLEANUP => 1);
    @r = eval { $D->_pruneAudioCache($empty, 1024) };
    is_deeply(\@r, [ 0, 0 ], 'D-17: an empty dir returns (0, 0)');
    @r = eval { $D->_pruneAudioCache("$empty/does-not-exist", 1024) };
    ok(!$@, 'D-17: a missing dir does not die');
    is_deeply(\@r, [ 0, 0 ], 'D-17: a missing dir returns (0, 0)');
    @r = eval { $D->_pruneAudioCache(undef, 1024) };
    ok(!$@ && @r == 2 && $r[0] == 0, 'D-17: an undefined dir returns (0, 0) without dying');
}

# ==================================================================
# Cell 4: start() prunes the ACCOUNT cache dir with the 1 GiB limit, only
# when an active account is set, and a failing prune never blocks the start.
# ==================================================================
{
    my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');
    my @calls;
    no warnings 'redefine';
    local *Plugins::SpotOn::Unified::Daemon::_pruneAudioCache = sub {
        my ($self, $dir, $limit) = @_;
        push @calls, [ $dir, $limit ];
        return (0, 0);
    };

    $Slim::Player::Client::FAKE_CLIENT = Test::FakeClient->new(isSynced => 0, model => 'squeezelite');

    $prefs->set('activeAccount', 'acct0001');
    Plugins::SpotOn::Unified::Daemon->new('aa:bb:cc:dd:ee:60');
    is_deeply(\@calls, [ [ "$cache_dir/spoton/acct0001", 1024 * 1024 * 1024 ] ],
        'D-17: start() prunes the account cache dir with the 1 GiB limit');

    @calls = ();
    $prefs->set('activeAccount', '');
    Plugins::SpotOn::Unified::Daemon->new('aa:bb:cc:dd:ee:61');
    is(scalar(@calls), 0, 'D-17: start() does not prune without an active account');

    # a dying prune must not block the daemon start
    local *Plugins::SpotOn::Unified::Daemon::_pruneAudioCache = sub { die "boom\n" };
    $prefs->set('activeAccount', 'acct0001');
    @Proc::Background::LAST_ARGS = ();
    my $d = eval { Plugins::SpotOn::Unified::Daemon->new('aa:bb:cc:dd:ee:62') };
    ok(!$@ && $d && scalar(@Proc::Background::LAST_ARGS), 'D-17: a dying prune does not block the daemon start');
}

done_testing();

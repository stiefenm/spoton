#!/usr/bin/perl
# t/core/73_orphan_sweep_pairing.t -- 79-42 (D-33 FULL-1 CR-01).
#
# The hourly orphan sweep (Plugin.pm _killOrphanedProcesses) TERMs every
# process whose command line carries the helper path and that is in neither
# protected set. The ZeroConf pairing helper (Credentials.pm startPairing,
# `<helper> -n NAME --cache STAGING --discover-once`) is the same binary and
# lived only in Credentials' %_pairing, so a sweep during a pairing killed it.
# The fix: Credentials->pairingPid, added to the protected set before both
# the Unix and the Windows branch.
#
# Real processes: the Helper stub's path is a temp Perl script that sleeps,
# so `pgrep -f '<path>'` sees exactly the children this file starts (the
# path lives in a File::Temp dir). Proc::Background is a fork/exec stand-in
# (the real module is LMS-bundled, not in the test env). Liveness is read
# with waitpid(WNOHANG), never kill 0 (a killed, unreaped child is a zombie
# that kill 0 reads as alive). The stub bootstrap is t/core/10's (lines
# 66-401) with this file's Helper and Proc::Background; no LMS tree needed.
#
# pgrep is required: without it the file dies (never skip -- an inner SKIP
# would hide the cases from the CI skip gate, 79-REVIEW WR-02 class).
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use POSIX qw(WNOHANG);

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

my $pgrep_ok = system('sh', '-c', 'command -v pgrep >/dev/null 2>&1') == 0;
die "pgrep not available (never skip)\n" unless $pgrep_ok;

my $stub_dir  = tempdir(CLEANUP => 1);
my $cache_dir = tempdir(CLEANUP => 1);
my $bin_dir   = tempdir(CLEANUP => 1);

# The fake helper binary: a Perl script that sleeps until killed.
my $fake_helper = "$bin_dir/spoton-fake-helper";
{
    open(my $fh, '>', $fake_helper) or die "cannot write $fake_helper: $!";
    print $fh "#!$^X\nsleep 120;\n";
    close($fh);
    chmod(0755, $fake_helper) or die "chmod $fake_helper: $!";
}

my @started;   # every child PID this file started (END kills them)
END {
    local $?;    # waitpid below must not overwrite the exit status
    for my $pid (@started) {
        kill 'KILL', $pid;
        waitpid($pid, 0);
    }
}

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

# ============================================================
# LMS Module Stubs (t/core/10 lines 66-401, Helper replaced below)
# ============================================================

# Stub: Log::Log4perl::Logger
write_stub($stub_dir, 'Log::Log4perl::Logger', <<'END');
package Log::Log4perl::Logger;
sub new     { bless {}, shift }
sub AUTOLOAD { }
sub can     { 1 }
1;
END

# Stub: Log::Log4perl
write_stub($stub_dir, 'Log::Log4perl', <<'END');
package Log::Log4perl;
sub get_logger { return bless {}, 'Log::Log4perl::Logger' }
sub init { }
1;
END

# Stub: Slim::Utils::Log (exports logger() for all consumers)
write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
use Exporter 'import';
our @EXPORT = qw(logger logWarning logError logBacktrace);
sub addLogCategory { return bless {}, 'Slim::Utils::Log' }
sub logger { return bless { _calls => [] }, 'Slim::Utils::Log' }
sub logWarning { }
sub logError   { }
sub logBacktrace { }
sub info  { }
sub warn  { }
sub error { }
sub debug { }
sub is_info  { 0 }
sub is_debug { 0 }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Stub: Slim::Utils::Prefs (with client() support for per-player prefs)
my $prefs_cache_dir = $cache_dir;
write_stub($stub_dir, 'Slim::Utils::Prefs', <<"END");
package Slim::Utils::Prefs;
use parent 'Exporter';
our \@EXPORT_OK = qw(preferences);
my %_store;
my %_ns_store = ( server => { cachedir => '$prefs_cache_dir' } );

sub import {
    my \$class = shift;
    my \$caller = caller;
    no strict 'refs';
    *{"\${caller}::preferences"} = \\&preferences;
}

sub preferences {
    my \$ns = \$_[0] eq 'Slim::Utils::Prefs' ? \$_[1] : \$_[0];
    return bless { _ns => \$ns }, 'Slim::Utils::Prefs';
}

sub init {
    my (\$self, \$defaults) = \@_;
    for my \$k (keys \%{\$defaults}) {
        \$_store{ \$self->{_ns} }{\$k} //= \$defaults->{\$k};
    }
}

sub get {
    my (\$self, \$key) = \@_;
    if (exists \$_ns_store{ \$self->{_ns} }) {
        return \$_ns_store{ \$self->{_ns} }{\$key};
    }
    return \$_store{ \$self->{_ns} }{\$key};
}

sub set {
    my (\$self, \$key, \$val) = \@_;
    \$_store{ \$self->{_ns} }{\$key} = \$val;
}

sub client {
    my (\$self, \$client) = \@_;
    my \$client_id = ref \$client ? "\$client" : (\$client // 'default');
    return bless { _ns => \$self->{_ns} . '_client_' . \$client_id }, 'Slim::Utils::Prefs';
}

sub setChange { }
sub AUTOLOAD  { }
1;
END

# Stub: Slim::Utils::Cache
write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
my %_store;
my %_ttl;
sub new    { bless {}, shift }
sub get    { $_store{$_[1]} }
sub set    { $_store{$_[1]} = $_[2]; $_ttl{$_[1]} = $_[3]; 1 }
sub remove { delete $_store{$_[1]}; delete $_ttl{$_[1]} }
sub ttl    { $_ttl{$_[1]} }
sub clear  { %_store = (); %_ttl = () }
1;
END

# Stub: Slim::Utils::Timers
write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
sub setTimer   { }
sub killTimers { }
1;
END

# Stub: Slim::Utils::Strings
write_stub($stub_dir, 'Slim::Utils::Strings', <<'END');
package Slim::Utils::Strings;
use parent 'Exporter';
our @EXPORT_OK = qw(string cstring);
sub string  { join(' ', grep { defined } @_[1..$#_]) }
sub cstring { join(' ', grep { defined } @_[1..$#_]) }
1;
END

# Stub: Slim::Utils::Unicode
write_stub($stub_dir, 'Slim::Utils::Unicode', <<'END');
package Slim::Utils::Unicode;
sub utf8toLatin1Transliterate { $_[1] }
1;
END

# Stub: Slim::Utils::Versions (needed by ProtocolHandler.pm; CI has no LMS tree)
write_stub($stub_dir, 'Slim::Utils::Versions', <<'END');
package Slim::Utils::Versions;
sub compareVersions { 0 }
1;
END

# Stub: JSON::XS (Plugin.pm uses 'use JSON::XS qw(encode_json)')
# JSON::XS is an XS module bundled by LMS but not available in the test env.
# Delegate to JSON::PP (pure-Perl equivalent) so stubs stay test-env clean.
write_stub($stub_dir, 'JSON::XS', <<'END');
package JSON::XS;
use parent 'Exporter';
our @EXPORT_OK = qw(encode_json decode_json);
use JSON::PP ();
sub encode_json { JSON::PP::encode_json($_[0]) }
sub decode_json { JSON::PP::decode_json($_[0]) }
1;
END

# Stub: JSON::XS::VersionOneAndTwo
write_stub($stub_dir, 'JSON::XS::VersionOneAndTwo', <<'END');
package JSON::XS::VersionOneAndTwo;
use parent 'Exporter';
our @EXPORT = qw(from_json to_json);
use JSON::PP ();
sub from_json { JSON::PP::decode_json($_[0]) }
sub to_json   { JSON::PP::encode_json($_[0]) }
1;
END

# Stub: Time::HiRes
write_stub($stub_dir, 'Time::HiRes', <<'END');
package Time::HiRes;
use POSIX qw();
sub time  { POSIX::floor(CORE::time()) + 0 }
sub sleep { CORE::sleep($_[1]) }
1;
END

# Stub: Slim::Plugin::OPMLBased
write_stub($stub_dir, 'Slim::Plugin::OPMLBased', <<'END');
package Slim::Plugin::OPMLBased;
sub new        { bless {}, shift }
sub initPlugin { }
sub _pluginDataFor { }
sub AUTOLOAD   { }
sub can        { 1 }
1;
END

# Stub: Slim::Player::ProtocolHandlers
write_stub($stub_dir, 'Slim::Player::ProtocolHandlers', <<'END');
package Slim::Player::ProtocolHandlers;
sub registerHandler { }
1;
END

# Stub: Slim::Player::TranscodingHelper
write_stub($stub_dir, 'Slim::Player::TranscodingHelper', <<'END');
package Slim::Player::TranscodingHelper;
our %commandTable;
sub getConvertCommand2 { return ('command', 'type', 'F', 'T', 0, 1) }
sub Conversions { return \%commandTable }
# 74b-02: counting checkBin. It reports lame as missing, like a server without
# the tool; the label path must never reach it (a diagnosis per menu item
# would log one warning per item).
our $checkBinCalls = 0;
sub checkBin { $checkBinCalls++; $@ = 'lame'; return 0 }
1;
END

# Stub: Slim::Formats::RemoteStream
write_stub($stub_dir, 'Slim::Formats::RemoteStream', <<'END');
package Slim::Formats::RemoteStream;
sub new      { bless {}, shift }
sub AUTOLOAD { }
sub can      { 1 }
1;
END

# Stub: Plugins::SpotOn::Helper with controllable getCapability
write_stub($stub_dir, 'Plugins::SpotOn::Helper', <<"END");
package Plugins::SpotOn::Helper;
our \$PATH = '$fake_helper';
our %caps = ('discover-once' => 1);
sub get { return \$PATH }
sub init { }
sub getCapability { my (\$class, \$key) = \@_; return \$caps{\$key}; }
1;
END

# Stub: Proc::Background -- a real fork/exec stand-in. alive() reaps with
# waitpid(WNOHANG) (a zombie is not alive); die() TERMs and reaps.
write_stub($stub_dir, 'Proc::Background', <<'END');
package Proc::Background;
use POSIX qw(WNOHANG);
our @SPAWNED;
sub new {
    my ($class, $opts, @cmd) = @_;
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) { exec { $cmd[0] } @cmd; POSIX::_exit(127); }
    push @SPAWNED, $pid;
    return bless { pid => $pid, done => 0 }, $class;
}
sub pid { return $_[0]->{pid} }
sub alive {
    my $self = shift;
    return 0 if $self->{done};
    my $r = waitpid($self->{pid}, WNOHANG);
    if ($r == $self->{pid} || $r == -1) { $self->{done} = 1; return 0; }
    return 1;
}
sub die {
    my $self = shift;
    return 1 if $self->{done};
    kill 'TERM', $self->{pid};
    waitpid($self->{pid}, 0);
    $self->{done} = 1;
    return 1;
}
1;
END

# Stub: URI::Escape - not Perl core, bundled by LMS
write_stub($stub_dir, 'URI::Escape', <<'END');
package URI::Escape;
use Exporter 'import';
our @EXPORT_OK = qw(uri_escape);
sub uri_escape { my ($s) = @_; $s =~ s/([^A-Za-z0-9\-._~])/sprintf("%%%02X", ord($1))/ge; return $s; }
1;
END

# Stub: Slim::Utils::Accessor - hash-based replacement for LMS array-based accessor
# Needed when Daemon.pm is loaded via DaemonManager.pm cascade
write_stub($stub_dir, 'Slim::Utils::Accessor', <<'END');
package Slim::Utils::Accessor;
sub new { return bless {}, ref($_[0]) || $_[0] }
sub mk_accessor {
    my $class = shift;
    my $type  = shift;
    for my $attr (@_) {
        no strict 'refs';
        *{"${class}::${attr}"} = sub {
            $_[0]->{$attr} = $_[1] if @_ > 1;
            return $_[0]->{$attr};
        };
    }
}
1;
END

# Stub: Slim::Networking::SimpleAsyncHTTP - DaemonManager.pm uses at module level
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
sub new  { bless {}, shift }
sub get  { }
sub post { }
1;
END

# Stub: Slim::Player::Sync - resolver uses slaves() for D-08 sync-group aggregation
write_stub($stub_dir, 'Slim::Player::Sync', <<'END');
package Slim::Player::Sync;
our %_slaves;
sub slaves {
    my $master = shift;
    my $id = "$master";
    return @{ $_slaves{$id} // [] };
}
sub isSlave  { 0 }
sub syncname { ref $_[0] ? "$_[0]" : ($_[0] // '') }
1;
END

# Stub: Slim::Utils::Network - Daemon.pm start() references serverAddr
write_stub($stub_dir, 'Slim::Utils::Network', <<'END');
package Slim::Utils::Network;
sub serverAddr { '127.0.0.1' }
1;
END

# Stub: Slim::Player::Client - DaemonManager runtime calls (not needed for resolver)
write_stub($stub_dir, 'Slim::Player::Client', <<'END');
package Slim::Player::Client;
sub getClient { undef }
sub clients   { () }
1;
END

# ============================================================
# main:: constants
# ============================================================
BEGIN {
    no warnings 'redefine';
    *main::TRANSCODING = sub () { 0 };
    *main::WEBUI       = sub () { 0 };
    *main::SCANNER     = sub () { 0 };
    *main::INFOLOG     = sub () { 0 };
    *main::DEBUGLOG    = sub () { 0 };
    *main::ISWINDOWS   = sub () { 0 };
    *main::ISMAC       = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
}

# 84-09 (W9): the two backend ROLE classes are per-file mocks in this core
# half -- it never loads the real Backend/Librespot.pm or Backend/Soloist.pm.
# The registry Plugins::SpotOn::Backend itself stays real: its classFor()
# `require`s these files from $stub_dir (first in @INC). Cells that need the
# real role logic live in the t/librespot and t/soloist halves.
write_stub($stub_dir, 'Plugins::SpotOn::Backend::Librespot', <<'END');
package Plugins::SpotOn::Backend::Librespot;
sub new { my ($class, $mac) = @_; return bless { mac => (ref $mac ? $mac->id : $mac) }, $class }
sub mac { return $_[0]->{mac} }
# resolvePassthroughForClient reads backendClass()->capabilitiesDefault;
# the mock answers the Helper stub's passthrough capability, so the player /
# sync-group cells below exercise DaemonManager's resolver, not the role.
# 74b-02: ProtocolHandler->contentTypeFor names the resolver from this key and
# ProtocolHandler::contentType reads contentType; the values mirror the real
# Backend::Librespot (son, resolvePassthroughForClient).
sub capabilitiesDefault { return { passthrough => (Plugins::SpotOn::Helper->getCapability('passthrough') ? 1 : 0), formats => 'resolvePassthroughForClient', contentType => 'son' } }
sub binaryPath { return '/usr/bin/false' }
sub daemonClass { return 'Plugins::SpotOn::Unified::Daemon' }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Backend::Soloist', <<'END');
package Plugins::SpotOn::Backend::Soloist;
sub new { my ($class, $mac) = @_; return bless { mac => (ref $mac ? $mac->id : $mac) }, $class }
sub mac { return $_[0]->{mac} }
# 74b-02: the values mirror the real Backend::Soloist (soc, resolveSoloistFormat).
sub capabilitiesDefault { return { formats => 'resolveSoloistFormat', contentType => 'soc' } }
sub binaryPath { return undef }
sub daemonClass { return 'Plugins::SpotOn::Unified::SoloistDaemon' }
1;
END


unshift @INC, $stub_dir, $project_dir;
require Plugins::SpotOn::Helper;
require Slim::Player::Sync;

require_ok('Plugins::SpotOn::Plugin') or BAIL_OUT("Failed to load Plugin.pm");
require_ok('Plugins::SpotOn::API::Credentials') or BAIL_OUT("Failed to load Credentials.pm");
require Proc::Background;
require Plugins::SpotOn::Backend;
require Slim::Player::Client;     # the stub: clients() -> () (no busy player)

my $C = 'Plugins::SpotOn::API::Credentials';

# A live child is not reaped (waitpid WNOHANG returns 0); an exited one is.
sub child_alive {
    my ($pid) = @_;
    my $r = waitpid($pid, WNOHANG);
    return $r == 0 ? 1 : 0;
}

# An orphan of the same binary, started outside the pairing slot.
sub start_orphan {
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) { exec { $fake_helper } $fake_helper, '--unified', 'orphan'; POSIX::_exit(127); }
    push @started, $pid;
    return $pid;
}

# Waits up to ~5 s until pgrep sees $pid with the helper path on its command line.
sub wait_visible {
    my ($pid) = @_;
    (my $pat = quotemeta($fake_helper)) =~ s/'/'\\''/g;
    for (1 .. 50) {
        my %seen = map { /^\s*(\d+)/ ? ($1 => 1) : () } `pgrep -f '$pat'`;
        return 1 if $seen{$pid};
        select(undef, undef, undef, 0.1);
    }
    return 0;
}

# Waits up to ~5 s for $pid to exit (TERM is asynchronous).
sub wait_gone {
    my ($pid) = @_;
    for (1 .. 50) {
        return 1 unless child_alive($pid);
        select(undef, undef, undef, 0.1);
    }
    return 0;
}

no warnings 'redefine', 'once';
# Only the helper path is swept here; the per-backend loop is pinned in t/core/10.
*Plugins::SpotOn::Backend::available = sub { return () };

# P1: no pairing -> undef.
{
    $C->cancelPairing;
    ok($C->can('pairingPid'), 'D-33 FULL-1 P1: Credentials has pairingPid');
    is(eval { $C->pairingPid }, undef, 'D-33 FULL-1 P1: no pairing -> pairingPid is undef');
}

# P2: a started pairing -> its child's PID; after cancel -> undef.
{
    my ($ok, $why) = $C->startPairing;
    ok($ok, 'D-33 FULL-1 P2: startPairing spawns the stubbed helper') or diag("reason: " . ($why // ''));
    my $child = $Proc::Background::SPAWNED[-1];
    push @started, $child if $child;
    ok($child && wait_visible($child), 'D-33 FULL-1 P2: the pairing child carries the helper path (pgrep sees it)');
    is(eval { $C->pairingPid }, $child, 'D-33 FULL-1 P2: pairingPid is the live pairing child PID');
    $C->cancelPairing;
    is(eval { $C->pairingPid }, undef, 'D-33 FULL-1 P2: after cancelPairing -> undef');
    ok(!child_alive($child), 'D-33 FULL-1 P2: cancelPairing ended the child');
}

# S1: real processes -- the sweep spares the pairing child, kills the orphan.
{
    my ($ok) = $C->startPairing;
    my $pairing = $Proc::Background::SPAWNED[-1];
    push @started, $pairing;
    my $orphan = start_orphan();
    ok(wait_visible($pairing) && wait_visible($orphan), 'D-33 FULL-1 S1: pgrep sees both children before the sweep');

    Plugins::SpotOn::Plugin->_killOrphanedProcesses();

    ok(wait_gone($orphan), 'D-33 FULL-1 S1: the orphan of the same binary is terminated by the sweep');
    ok(child_alive($pairing), 'D-33 FULL-1 S1: the live pairing child survives the sweep');
    $C->cancelPairing;
}

# S2: structure -- the protected set handed to _killOrphansForBinary for the
# helper path holds the pairing PID (the Windows branch reads the same set).
{
    my ($ok) = $C->startPairing;
    my $pairing = $Proc::Background::SPAWNED[-1];
    push @started, $pairing;
    my @calls;
    {
        local *Plugins::SpotOn::Plugin::_killOrphansForBinary = sub { push @calls, [ $_[0], { %{ $_[2] || {} } } ] };
        Plugins::SpotOn::Plugin->_killOrphanedProcesses();
    }
    my ($helperCall) = grep { $_->[0] eq $fake_helper } @calls;
    ok($helperCall, 'D-33 FULL-1 S2: the helper path is swept');
    ok($helperCall && $helperCall->[1]{$pairing}, 'D-33 FULL-1 S2: the protected set for the helper path holds the pairing PID');
    $C->cancelPairing;
    my @after;
    {
        local *Plugins::SpotOn::Plugin::_killOrphansForBinary = sub { push @after, [ $_[0], { %{ $_[2] || {} } } ] };
        Plugins::SpotOn::Plugin->_killOrphanedProcesses();
    }
    ok(!($after[0] && $after[0][1]{$pairing}), 'D-33 FULL-1 S2: after cancelPairing the PID is no longer protected');
}

done_testing();

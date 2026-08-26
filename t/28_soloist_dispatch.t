#!/usr/bin/perl
use strict;
use warnings;
no warnings 'once';
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# Resolve project root: t/ is directly under the project root
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname($test_dir);

my $module = "$project_dir/Plugins/SpotOn/Unified/DaemonManager.pm";
unless (-f $module) {
    plan skip_all => 'Plugins/SpotOn/Unified/DaemonManager.pm not yet present in this checkout';
}

my $stub_dir = tempdir(CLEANUP => 1);

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
# LMS module stubs required to load DaemonManager.pm in isolation.
# DaemonManager.pm has never had test coverage before this plan (71-02) --
# it is intentionally absent from t/05_perl_syntax.t's @pm_files because a
# straight `perl -c` against a real LMS checkout fails on JSON::XS's XS
# binary not being installed in this sandbox (pre-existing environment gap,
# unrelated to this plan -- see 71-02-SUMMARY.md). Full isolated `require`
# below is a strictly stronger check than `perl -c` since it also executes
# the module's top-level statements.
# ============================================================

write_stub($stub_dir, 'Log::Log4perl::Logger', <<'END');
package Log::Log4perl::Logger;
sub new { bless {}, shift }
sub AUTOLOAD { }
sub can { 1 }
1;
END

write_stub($stub_dir, 'Log::Log4perl', <<'END');
package Log::Log4perl;
sub get_logger { return bless {}, 'Log::Log4perl::Logger' }
sub init { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
use parent 'Exporter';
our @EXPORT_OK = qw(logger);
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
sub is_warn  { 1 }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Task 2 (73-01): backed by a package hash so tests can control arbitrary
# pref keys (e.g. 'backend', 'cachedir') without a bespoke stub per key.
write_stub($stub_dir, 'Slim::Utils::Prefs', <<'END');
package Slim::Utils::Prefs;
our %FAKE_VALUES = ( cachedir => '/tmp/spoton-test-cachedir' );
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::preferences"} = \&preferences;
}
sub preferences { return bless { _ns => $_[0] }, 'Slim::Utils::Prefs' }
sub get      { my ($self, $key) = @_; return $FAKE_VALUES{$key}; }
sub set      { my ($self, $key, $val) = @_; $FAKE_VALUES{$key} = $val; }
sub client   { return bless {}, 'Slim::Utils::Prefs' }
sub setChange { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
sub new    { return bless {}, shift }
sub get    { return undef }
sub set    { }
sub remove { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Strings', <<'END');
package Slim::Utils::Strings;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::cstring"} = sub { '' };
    *{"${caller}::string"}  = sub { '' };
}
1;
END

write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
sub killTimers { }
sub setTimer   { }
1;
END

write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
sub new { return bless {}, shift }
sub get { }
sub post { }
1;
END

write_stub($stub_dir, 'JSON::XS::VersionOneAndTwo', <<'END');
package JSON::XS::VersionOneAndTwo;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::to_json"}   = sub { '{}' };
    *{"${caller}::from_json"} = sub { {} };
}
1;
END

# Task 2 (73-01): needed for the REAL Plugins::SpotOn::Soloist module (loaded
# below, not stubbed out) which `use`s this at compile time (_arch()).
write_stub($stub_dir, 'Slim::Utils::OSDetect', <<'END');
package Slim::Utils::OSDetect;
sub details { return { osArch => 'x86_64-linux-gnu-thread-multi' } }
1;
END

# Task 2 (73-01): needed for the REAL Plugins::SpotOn::Unified::SoloistDaemon
# module (isolated-require target below) which `use base qw(Slim::Utils::Accessor)`.
write_stub($stub_dir, 'Slim::Utils::Accessor', <<'END');
package Slim::Utils::Accessor;
sub new { return bless {}, shift }
sub mk_accessor {
    my ($class, $type, @names) = @_;
    no strict 'refs';
    for my $name (@names) {
        *{"${class}::${name}"} = sub {
            my $self = shift;
            $self->{$name} = shift if @_;
            return $self->{$name};
        };
    }
}
1;
END

# Minimal stand-in -- DaemonManager.pm only needs the CACHE_VERSION constant
# and _pluginDataFor at load time. Task 2 (73-01): $FAKE_BASEDIR is settable
# per-test so ensureWsLib()'s vendor-fallback push resolves the REAL
# Plugins/SpotOn/Vendor tree (see the ensureWsLib block below).
write_stub($stub_dir, 'Plugins::SpotOn::Plugin', <<'END');
package Plugins::SpotOn::Plugin;
use constant SPOTON_CACHE_VERSION => 4;
our $FAKE_BASEDIR = 'test-basedir';
sub _pluginDataFor { return $FAKE_BASEDIR }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Unified::Daemon', <<'END');
package Plugins::SpotOn::Unified::Daemon;
sub new { return bless {}, shift }
1;
END

BEGIN {
    no warnings 'redefine';
    *main::TRANSCODING = sub () { 0 };
    *main::WEBUI       = sub () { 0 };
    *main::SCANNER     = sub () { 0 };
    *main::INFOLOG     = sub () { 0 };
    *main::DEBUGLOG    = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
}
our $FAKE_ISWINDOWS = 0;
our $FAKE_ISMAC     = 0;
BEGIN {
    no warnings 'redefine';
    *main::ISWINDOWS   = sub () { $main::FAKE_ISWINDOWS };
    *main::ISMAC       = sub () { $main::FAKE_ISMAC };
}

unshift @INC, $stub_dir, $project_dir;

# Task 2 (73-01): the REAL Plugins::SpotOn::Soloist module is loaded (not a
# fake stand-in) so dataDirForClient/cacheDirForClient/readKey/ensureWsLib
# are exercised as actual production code. Only get()/hasKey() are
# monkey-patched afterward (glob assignment) so _backendPrereqState()'s
# three soloist-branch outcomes stay controllable per test case, exactly
# like the previous fake-package approach.
require_ok('Plugins::SpotOn::Soloist')
    or BAIL_OUT("Failed to load the real Plugins::SpotOn::Soloist");

our $FAKE_BINARY  = undef;   # undef = missing; any true value = present
our $FAKE_HAS_KEY = 0;
{
    no warnings 'redefine';
    *Plugins::SpotOn::Soloist::get    = sub { return $FAKE_BINARY };
    *Plugins::SpotOn::Soloist::hasKey = sub { return $FAKE_HAS_KEY };
}

require_ok('Plugins::SpotOn::Unified::DaemonManager')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Unified::DaemonManager");

sub reset_all {
    $FAKE_BINARY  = undef;
    $FAKE_HAS_KEY = 0;
    $FAKE_ISWINDOWS = 0;
    $FAKE_ISMAC     = 0;
}

# ============================================================
# (a) backend 'librespot' -> 'librespot' (default/unmodified path)
# ============================================================
{
    reset_all();
    is(
        Plugins::SpotOn::Unified::DaemonManager::_backendPrereqState('librespot'),
        'librespot',
        "backend 'librespot' -> 'librespot'"
    );
}

# Unknown/tampered pref values fall back to 'librespot' (T-71-05) --
# same code path as the plain 'librespot' case, worth asserting explicitly.
{
    reset_all();
    is(
        Plugins::SpotOn::Unified::DaemonManager::_backendPrereqState('bogus-value'),
        'librespot',
        "unknown backend value -> 'librespot' (fail-safe fallback, T-71-05)"
    );
}

{
    reset_all();
    is(
        Plugins::SpotOn::Unified::DaemonManager::_backendPrereqState(undef),
        'librespot',
        "undef backend -> 'librespot' (fail-safe fallback)"
    );
}

# ============================================================
# (b) backend 'soloist', binary+key present, Linux -> 'soloist_ready'
# ============================================================
{
    reset_all();
    $FAKE_BINARY  = '/fake/cachedir/spoton/soloist/x86_64-linux/soloist';
    $FAKE_HAS_KEY = 1;

    is(
        Plugins::SpotOn::Unified::DaemonManager::_backendPrereqState('soloist'),
        'soloist_ready',
        "backend 'soloist', binary+key present, Linux -> 'soloist_ready'"
    );
}

# ============================================================
# (c) soloist, no binary -> 'soloist_missing_binary'
# ============================================================
{
    reset_all();
    $FAKE_BINARY  = undef;
    $FAKE_HAS_KEY = 1;   # key present is irrelevant -- binary checked first

    is(
        Plugins::SpotOn::Unified::DaemonManager::_backendPrereqState('soloist'),
        'soloist_missing_binary',
        "soloist, no binary -> 'soloist_missing_binary'"
    );
}

# ============================================================
# (d) soloist, binary present but no key -> 'soloist_missing_key'
# ============================================================
{
    reset_all();
    $FAKE_BINARY  = '/fake/cachedir/spoton/soloist/x86_64-linux/soloist';
    $FAKE_HAS_KEY = 0;

    is(
        Plugins::SpotOn::Unified::DaemonManager::_backendPrereqState('soloist'),
        'soloist_missing_key',
        "soloist, binary present, no key -> 'soloist_missing_key'"
    );
}

# ============================================================
# (e) soloist on ISWINDOWS/ISMAC -> 'soloist_unsupported_os'
# ============================================================
{
    reset_all();
    $FAKE_BINARY  = '/fake/soloist';
    $FAKE_HAS_KEY = 1;
    $FAKE_ISWINDOWS = 1;

    is(
        Plugins::SpotOn::Unified::DaemonManager::_backendPrereqState('soloist'),
        'soloist_unsupported_os',
        "soloist on ISWINDOWS (even with binary+key present) -> 'soloist_unsupported_os'"
    );
}

{
    reset_all();
    $FAKE_BINARY  = '/fake/soloist';
    $FAKE_HAS_KEY = 1;
    $FAKE_ISMAC = 1;

    is(
        Plugins::SpotOn::Unified::DaemonManager::_backendPrereqState('soloist'),
        'soloist_unsupported_os',
        "soloist on ISMAC (even with binary+key present) -> 'soloist_unsupported_os'"
    );
}

reset_all();

# ============================================================
# Task 2 (D-01/D-02): per-player dir shapes (real Soloist.pm code)
# ============================================================
{
    my $dataDir = Plugins::SpotOn::Soloist::dataDirForClient('aa:bb:cc:dd:ee:ff');
    like($dataDir, qr{players/aabbccddeeff/data$}, "dataDirForClient() shape (D-01 per-player dir)");

    my $cacheDir = Plugins::SpotOn::Soloist::cacheDirForClient('aa:bb:cc:dd:ee:ff');
    like($cacheDir, qr{players/aabbccddeeff/cache$}, "cacheDirForClient() shape (D-01 per-player dir)");
}

# ============================================================
# Task 2 (D-08): ensureWsLib() -- vendor fallback vs. bundled precedence
# ============================================================
{
    # (1) No bundled copy anywhere in @INC -- must fall back to the real
    # vendored Plugins/SpotOn/Vendor/Protocol/WebSocket/Client.pm tree.
    delete $INC{'Protocol/WebSocket/Client.pm'};
    delete $INC{'Protocol/WebSocket.pm'};

    local $Plugins::SpotOn::Plugin::FAKE_BASEDIR = "$project_dir/Plugins/SpotOn";

    my $ok = Plugins::SpotOn::Soloist::ensureWsLib();
    is($ok, 1, "ensureWsLib() loads the vendored Protocol::WebSocket::Client when no bundled copy is present");
    like($INC{'Protocol/WebSocket/Client.pm'} // '', qr{Vendor}, "loaded from the real Plugins/SpotOn/Vendor tree (D-08)");
}

{
    # (2) A bundled copy earlier in @INC (stub_dir precedes any vendor push)
    # must win -- push, not unshift, in ensureWsLib().
    delete $INC{'Protocol/WebSocket/Client.pm'};
    write_stub($stub_dir, 'Protocol::WebSocket::Client', <<'END');
package Protocol::WebSocket::Client;
sub new { bless {}, shift }
1;
END

    my $ok = Plugins::SpotOn::Soloist::ensureWsLib();
    is($ok, 1, "ensureWsLib() succeeds when an LMS-bundled copy is present");
    like($INC{'Protocol/WebSocket/Client.pm'} // '', qr{^\Q$stub_dir\E}, "prefers the bundled copy over the vendored fallback");
}

# ============================================================
# Task 2 (D-04): resolvePassthroughForClient() soloist short-circuit
# ============================================================
{
    local $Slim::Utils::Prefs::FAKE_VALUES{backend} = 'soloist';
    my $fakeClient = bless {}, 'FakeClient';

    is(
        Plugins::SpotOn::Unified::DaemonManager->resolvePassthroughForClient($fakeClient),
        0,
        "resolvePassthroughForClient() returns 0 unconditionally when backend='soloist' (D-04)"
    );
}

# ============================================================
# Task 2 (D-05): SoloistDaemon.pm isolated-require + _spawnArgs()
# ============================================================
require_ok('Plugins::SpotOn::Unified::SoloistDaemon')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Unified::SoloistDaemon");

{
    my @args = Plugins::SpotOn::Unified::SoloistDaemon->_spawnArgs(
        '/fake/soloist', 'the-spak-key', 'Living Room',
        '/fake/data', '/fake/cache', 40,
    );

    is_deeply(
        \@args,
        [ '/fake/soloist', '-n', 'Living Room', '-k', 'the-spak-key',
          '-D', '/fake/data', '-C', '/fake/cache', '-w', '127.0.0.1:0', '-i', 40 ],
        "_spawnArgs() builds the expected argv (D-05, T-73-01 -- hard-coded 127.0.0.1:0 bind)"
    );
}

# ============================================================
# Task 2 (73-04): Sync-group pinning for the soloist backend. Pattern 7 says
# the librespot sync machinery (initHelpers()'s slave-delegates-to-master
# branch, deviceNameForClient()'s suffix, and the sync-change handler's
# name-comparison restart) transfers 1:1 to SoloistDaemon, unmodified. This
# section PROVES it against the REAL DaemonManager module (not a stub of it).
#
# Minimal stand-ins for Slim::Player::Client / Slim::Player::Sync /
# Slim::Control::Request: DaemonManager.pm only ever calls these
# fully-qualified (never `use`s them), so a plain in-process package
# declaration is sufficient -- no stub file on disk needed.
# ============================================================
require Time::HiRes;    # real core module (t/31's own precedent) -- needed
                         # once initHelpers()/init() start evaluating timer args.

{
    package Test::SyncClient;
    sub new {
        my ($class, %args) = @_;
        return bless {
            id     => $args{id},
            name   => $args{name} // 'Player',
            synced => $args{synced} // 0,
            master => $args{master},
            model  => $args{model} // 'squeezebox',
        }, $class;
    }
    sub id          { return $_[0]->{id}; }
    sub name        { return $_[0]->{name}; }
    sub isSynced    { return $_[0]->{synced}; }
    sub master      { return $_[0]->{master}; }
    sub model       { return $_[0]->{model}; }
    sub volume      { return 40; }
    sub isPlaying   { return 0; }
    sub playingSong { return undef; }
    sub connected   { return 1; }
    sub formats     { return (); }
}

{
    package Slim::Player::Client;
    our @ALL_CLIENTS = ();
    our %BY_ID       = ();
    sub clients   { return @ALL_CLIENTS; }
    sub getClient { return $BY_ID{ $_[0] }; }
}

{
    package Slim::Player::Sync;
    our %SLAVE_OF = ();    # slaveId => masterId
    sub isSlave { return exists $SLAVE_OF{ $_[0]->id } ? 1 : 0; }
    sub slaves  { return (); }    # not exercised by this 2-player scenario
}

{
    package Slim::Control::Request;
    our @SUBSCRIPTIONS = ();
    sub subscribe   { push @SUBSCRIPTIONS, [ $_[0], $_[1] ]; }
    sub unsubscribe { }
}

{
    package Test::SyncRequest;
    sub new          { return bless { client => $_[1] }, $_[0]; }
    sub isNotCommand { return 0; }    # pretend it IS a ['sync'] command
    sub client       { return $_[0]->{client}; }
}

# Test double for SoloistDaemon's process-lifecycle methods only -- name()/
# mac() stay the REAL Slim::Utils::Accessor-generated accessors (mk_accessor
# ran for real at module-load time), so blessed hash fields work normally.
# Blessed into the literal production package name (73-03-SUMMARY.md
# precedent) so every isa('...::SoloistDaemon') check in DaemonManager.pm
# still passes.
my (@NEW_CALLS, @STOP_CALLS, @STOPFORSYNC_CALLS);
{
    no warnings 'redefine';
    *Plugins::SpotOn::Unified::SoloistDaemon::new = sub {
        my ($class, $id) = @_;
        push @NEW_CALLS, $id;
        my $self = bless {}, $class;
        $self->mac($id);
        return $self;
    };
    *Plugins::SpotOn::Unified::SoloistDaemon::alive = sub {
        return $_[0]->{_test_alive} // 1;
    };
    *Plugins::SpotOn::Unified::SoloistDaemon::stop = sub {
        my $self = shift;
        push @STOP_CALLS, $self->mac;
        $self->{_test_alive} = 0;
    };
    *Plugins::SpotOn::Unified::SoloistDaemon::stopForSync = sub {
        my $self = shift;
        push @STOPFORSYNC_CALLS, $self->mac;
        $self->{_test_alive} = 0;
    };
}

reset_all();
$FAKE_BINARY  = '/fake/cachedir/spoton/soloist/x86_64-linux/soloist';
$FAKE_HAS_KEY = 1;
local $Slim::Utils::Prefs::FAKE_VALUES{backend} = 'soloist';

my $master = Test::SyncClient->new(id => 'aa:bb:cc:dd:ee:01', name => 'Living Room', synced => 1);
my $slave  = Test::SyncClient->new(id => 'aa:bb:cc:dd:ee:02', name => 'Kitchen',      synced => 1, master => $master);

$Slim::Player::Client::BY_ID{ $master->id } = $master;
$Slim::Player::Client::BY_ID{ $slave->id }  = $slave;
@Slim::Player::Client::ALL_CLIENTS          = ( $slave, $master );
$Slim::Player::Sync::SLAVE_OF{ $slave->id } = $master->id;

# ============================================================
# (a) initHelpers() delegation: a synced client-pair stub (slave with
# master) -- the soloist evaluation path delegates the daemon to the
# master's MAC and stops any slave-tracked helper (mirrors the librespot
# flow, GH #143 mechanism unmodified for soloist).
# ============================================================
{
    # Pre-condition: the slave was previously a standalone soloist player
    # and already has its own tracked daemon (simulates "was solo, just got
    # synced" -- the scenario where a slave-tracked helper must be stopped).
    Plugins::SpotOn::Unified::DaemonManager->startHelper($slave);
    is(scalar(@NEW_CALLS), 1, "pre-condition: slave's standalone soloist daemon was created");

    @NEW_CALLS = ();    # isolate the delegation call below

    Plugins::SpotOn::Unified::DaemonManager::initHelpers();

    is_deeply(\@NEW_CALLS, [ $master->id ],
        "initHelpers() creates exactly one SoloistDaemon, keyed by the sync MASTER's mac (Pattern 7 delegation)");
    is_deeply(\@STOP_CALLS, [ $slave->id ],
        "initHelpers() stops the slave's own previously-tracked soloist daemon (Pattern 7)");

    my @remaining = map { $_->mac } Plugins::SpotOn::Unified::DaemonManager->helperInstances();
    is_deeply(\@remaining, [ $master->id ],
        "only the sync master's daemon remains registered after delegation");

    ok(Plugins::SpotOn::Unified::DaemonManager->helperForClient($slave->id),
        "helperForClient() resolves the slave's id to the master's daemon via the sync fallback");
}

# ============================================================
# (b) deviceNameForClient() suffix/cap + soloist start-path name consumption:
# a synced non-group client gets the localized suffix appended within the
# 60-char cap -- and the soloist start path (_spawnArgs) consumes exactly
# this name.
# ============================================================
{
    no warnings 'redefine';
    local *Plugins::SpotOn::Unified::DaemonManager::cstring = sub { return 'Sync Group'; };

    my $expectedName = Plugins::SpotOn::Unified::DaemonManager->deviceNameForClient($master);
    like($expectedName, qr/Sync Group$/,
        "deviceNameForClient() appends the localized sync-group suffix for a synced non-group client");
    ok(length($expectedName) <= 60, "deviceNameForClient() result stays within the 60-char cap");

    my @spawnArgs = Plugins::SpotOn::Unified::SoloistDaemon->_spawnArgs(
        '/fake/soloist', 'the-spak-key', $expectedName, '/fake/data', '/fake/cache', 40,
    );
    is($spawnArgs[2], $expectedName,
        "the soloist start path (_spawnArgs) consumes exactly deviceNameForClient()'s synced name");

    # ============================================================
    # (c) sync-change handler: the same name-comparison restart DaemonManager
    # uses for librespot also applies to a SoloistDaemon instance -- a
    # helper->name vs deviceNameForClient mismatch triggers stopForSync()
    # when idle.
    # ============================================================
    Plugins::SpotOn::Unified::DaemonManager->init();

    my ($syncEntry) = grep { ref($_->[1]) eq 'ARRAY' && ($_->[1][0][0] // '') eq 'sync' }
        @Slim::Control::Request::SUBSCRIPTIONS;
    ok($syncEntry, "DaemonManager->init() subscribed a ['sync'] request handler");

    my $masterHelper = Plugins::SpotOn::Unified::DaemonManager->helperForClient($master->id);
    $masterHelper->name('Stale Old Name');    # real Slim::Utils::Accessor-generated accessor

    @STOPFORSYNC_CALLS = ();

    $syncEntry->[0]->( Test::SyncRequest->new($slave) );

    is_deeply(\@STOPFORSYNC_CALLS, [ $master->id ],
        "sync-change handler calls stopForSync() on a SoloistDaemon whose name no longer matches "
        . "deviceNameForClient (idle) -- GH #143 mechanism unmodified for soloist");
}

done_testing();

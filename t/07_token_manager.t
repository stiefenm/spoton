#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# Resolve project root: t/ is directly under the project root
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname($test_dir);

# Create a temporary directory for LMS stubs (CLEANUP on test exit)
my $stub_dir = tempdir(CLEANUP => 1);

# Cache dir for mock tests
my $cache_dir = tempdir(CLEANUP => 1);

# ============================================================
# Helper: write a stub Perl module into the stub directory
# ============================================================
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
# LMS Module Stubs required by TokenManager.pm
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

# Stub: Slim::Utils::Log
# logger() is exported as a function when modules do 'use Slim::Utils::Log'
write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
use parent 'Exporter';
our @EXPORT_OK = qw(logger);
# Also install logger() into caller namespace via import so bare 'logger(...)' works
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub addLogCategory {
    return bless { _calls => [] }, 'Slim::Utils::Log';
}
sub logger {
    return bless { _calls => [] }, 'Slim::Utils::Log';
}
sub info  { push @{$_[0]->{_calls}}, ['info',  $_[1]] }
sub warn  { push @{$_[0]->{_calls}}, ['warn',  $_[1]] }
sub error { push @{$_[0]->{_calls}}, ['error', $_[1]] }
sub debug { push @{$_[0]->{_calls}}, ['debug', $_[1]] }
sub is_info  { 0 }
sub is_debug { 0 }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Stub: Slim::Utils::Prefs
# Supports preferences('server')->get('cachedir') returning $cache_dir
my $prefs_cache_dir = $cache_dir;
write_stub($stub_dir, 'Slim::Utils::Prefs', <<"END");
package Slim::Utils::Prefs;
my %_store;
my %_ns_store = ( server => { cachedir => '$prefs_cache_dir', httpport => 9000, libraryname => 'TestServer' } );

sub import {
    my \$class = shift;
    my \$caller = caller;
    no strict 'refs';
    *{"\${caller}::preferences"} = \\\&preferences;
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
    return bless { _ns => \$self->{_ns} . '_client_' . (\$client // 'default') }, 'Slim::Utils::Prefs';
}

sub setChange { }
sub AUTOLOAD  { }
1;
END

# Stub: Slim::Utils::Cache (in-memory, records TTL for inspection)
write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
my %_store;
my %_ttl;
sub new    { bless {}, shift }
sub get    { $_store{$_[1]} }
sub set    { $_store{$_[1]} = $_[2]; $_ttl{$_[1]} = $_[3]; 1 }
sub remove { delete $_store{$_[1]}; delete $_ttl{$_[1]} }
sub ttl    { $_ttl{$_[1]} }   # extra method for test inspection
sub clear  { %_store = (); %_ttl = () }
1;
END

# Stub: Slim::Utils::Timers (records calls for inspection)
write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
our @set_calls  = ();
our @kill_calls = ();
our @deferred_callbacks = ();
sub setTimer   {
    my ($obj, $time, $cb) = @_;
    push @set_calls, [@_];
    # Execute deferred callbacks synchronously for testability
    push @deferred_callbacks, $cb if ref $cb eq 'CODE';
}
sub killTimers { push @kill_calls, [@_]; }
sub reset_calls {
    @set_calls = ();
    @kill_calls = ();
    @deferred_callbacks = ();
}
sub run_deferred {
    # Run all accumulated deferred callbacks
    while (my $cb = shift @deferred_callbacks) {
        $cb->();
    }
}
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

# Stub: JSON::XS::VersionOneAndTwo (delegates to JSON::PP)
write_stub($stub_dir, 'JSON::XS::VersionOneAndTwo', <<'END');
package JSON::XS::VersionOneAndTwo;
use parent 'Exporter';
our @EXPORT = qw(from_json to_json);
use JSON::PP ();
sub from_json { JSON::PP::decode_json($_[0]) }
sub to_json   { JSON::PP::encode_json($_[0]) }
1;
END

# Stub: Time::HiRes (pass through to real Time::HiRes)
write_stub($stub_dir, 'Time::HiRes', <<'END');
package Time::HiRes;
use POSIX qw();
sub time  { POSIX::floor(CORE::time()) + 0 }
sub sleep { CORE::sleep($_[1]) }
1;
END

# Stub: Slim::Plugin::OPMLBased (empty base class)
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

# Stub: Slim::Web::Settings
write_stub($stub_dir, 'Slim::Web::Settings', <<'END');
package Slim::Web::Settings;
sub new     { bless {}, shift }
sub handler { }
sub AUTOLOAD { }
sub can     { 1 }
1;
END

# Stub: Slim::Web::HTTP::CSRF
write_stub($stub_dir, 'Slim::Web::HTTP::CSRF', <<'END');
package Slim::Web::HTTP::CSRF;
sub protectCommand { $_[1] }
sub protectName    { $_[1] }
sub protectURI     { $_[1] }
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

# ============================================================
# Stubs for Keymaster TokenManager
# ============================================================

# Stub: Slim::Networking::SimpleAsyncHTTP
# Captures callbacks and request data for test inspection.
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
our ($last_success_cb, $last_error_cb, $last_url, $last_body);
sub new {
    my ($class, $success, $error, $opts) = @_;
    $last_success_cb = $success;
    $last_error_cb   = $error;
    return bless {}, $class;
}
sub post {
    my ($self, $url, @rest) = @_;
    $last_url = $url;
    $last_body = $rest[-1] if @rest % 2 != 0;
    return $self;
}
sub get {
    my ($self, $url, @rest) = @_;
    $last_url = $url;
    return $self;
}
# Helper: simulate a successful HTTP response
sub simulate_success {
    my ($class, $json_str) = @_;
    my $mock_http = bless { _content => $json_str }, 'Slim::Networking::MockHTTP';
    $last_success_cb->($mock_http) if $last_success_cb;
}
# Helper: simulate an HTTP error
sub simulate_error {
    my ($class, $error_str) = @_;
    $last_error_cb->(undef, $error_str) if $last_error_cb;
}

package Slim::Networking::MockHTTP;
sub content { $_[0]->{_content} }
1;
END

# Stub: URI::Escape — uri_escape/uri_escape_utf8 are used by Client.pm
write_stub($stub_dir, 'URI::Escape', <<'END');
package URI::Escape;
use Exporter 'import';
our @EXPORT_OK = qw(uri_escape uri_escape_utf8);
sub uri_escape {
    my ($s) = @_;
    die "Can't escape multibyte character" if $s =~ /[^\x00-\xFF]/;
    $s =~ s/([^A-Za-z0-9\-._~])/sprintf("%%%02X", ord($1))/ge;
    return $s;
}
sub uri_escape_utf8 {
    my ($s) = @_;
    utf8::encode($s) if utf8::is_utf8($s);
    $s =~ s/([^A-Za-z0-9\-._~])/sprintf("%%%02X", ord($1))/ge;
    return $s;
}
1;
END

# Stub: Proc::Background — records spawn calls, writes configurable output
# to the stdout redirect target (mimics the merged stdout+stderr tempfile).
write_stub($stub_dir, 'Proc::Background', <<'END');
package Proc::Background;
our @spawn_calls;
our $mock_output = '';
our $mock_alive  = 0;
our $mock_exit   = 0;
sub new {
    my ($class, $opts, @args) = @_;
    push @spawn_calls, { opts => $opts, args => [@args] };
    if ($opts && ref $opts eq 'HASH' && $opts->{stdout} && !ref $opts->{stdout}) {
        if (open(my $fh, '>', $opts->{stdout})) {
            print $fh $mock_output;
            close($fh);
        }
    }
    return bless { pid => 12345, died => 0 }, $class;
}
sub alive { $mock_alive }
sub pid   { $_[0]->{pid} }
sub die   { $_[0]->{died} = 1 }
sub wait  { $mock_exit }
sub reset_spawns { @spawn_calls = (); $mock_output = ''; $mock_alive = 0; $mock_exit = 0 }
1;
END

# Stub: Plugins::SpotOn::Helper — returns configurable fake binary path
my $fake_binary = '/fake/spoton';
write_stub($stub_dir, 'Plugins::SpotOn::Helper', <<"END");
package Plugins::SpotOn::Helper;
our \$fake_path = '$fake_binary';
sub get  { return wantarray ? (\$fake_path, '1.0.0') : \$fake_path }
sub init { }
1;
END

# ============================================================
# main:: constants (TRANSCODING, WEBUI, SCANNER, INFOLOG, etc.)
# ============================================================
BEGIN {
    no warnings 'redefine';
    *main::TRANSCODING = sub () { 0 };
    *main::WEBUI       = sub () { 0 };
    *main::SCANNER     = sub () { 0 };
    *main::INFOLOG     = sub () { 0 };
    *main::ISWINDOWS   = sub () { 0 };
    *main::ISMAC       = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
}

# M5: SPOTON_CACHE_VERSION is defined in Plugin.pm (single source of truth);
# submodules resolve it via a fully-qualified call at load time. Production
# always compiles Plugin.pm first — provide the constant for standalone loads.
BEGIN {
    package Plugins::SpotOn::Plugin;
    use constant SPOTON_CACHE_VERSION => 4;
}

# ============================================================
# Add stub_dir and project_dir to @INC
# ============================================================
unshift @INC, $stub_dir, $project_dir;

# Load stub modules so their import() methods run and install functions
# into main:: namespace (e.g., preferences(), logger()).
require Slim::Utils::Prefs;
Slim::Utils::Prefs->import();
require Slim::Utils::Log;
Slim::Utils::Log->import();
require Proc::Background;   # stub — used by _fetchKeymasterToken (H2)

# ============================================================
# Tests: TokenManager.pm (skip if not yet created)
# ============================================================

my $tm_module = "$project_dir/Plugins/SpotOn/API/TokenManager.pm";

SKIP: {
    skip "TokenManager.pm not yet created", 22
        unless -f $tm_module;

    require_ok('Plugins::SpotOn::API::TokenManager')
        or BAIL_OUT("Failed to load TokenManager.pm");

    # Helper: reset prefs and cache state between tests
    sub reset_state {
        Slim::Utils::Cache->new()->clear();
        Slim::Utils::Timers::reset_calls();
    }

    # --------------------------------------------------------
    # AUTH-02: Token caching
    # --------------------------------------------------------

    # AUTH-02: _cacheToken stores access token with correct key and TTL
    {
        reset_state();
        Plugins::SpotOn::API::TokenManager->_cacheToken('testacct', 'own', 'tok123', 3600);
        my $cache = Slim::Utils::Cache->new();
        is($cache->get('spoton_token_testacct_own'), 'tok123',
            'AUTH-02: _cacheToken stores token under spoton_token_<accountId>_<flavor>');
        is($cache->ttl('spoton_token_testacct_own'), 3300,
            'AUTH-02: _cacheToken TTL is expires_in(3600) - 300 = 3300');
    }

    # AUTH-02: _cacheToken with expiresIn between 60 and 300 uses expiresIn directly
    {
        reset_state();
        Plugins::SpotOn::API::TokenManager->_cacheToken('shortacct', 'own', 'tok456', 200);
        my $ttl = Slim::Utils::Cache->new()->ttl('spoton_token_shortacct_own');
        is($ttl, 200, 'AUTH-02: _cacheToken uses expiresIn(200) as TTL when expiresIn < TOKEN_EXPIRY_BUFFER');
    }

    # --------------------------------------------------------
    # AUTH-03: refreshAllTokens re-arms timer
    # --------------------------------------------------------
    {
        reset_state();
        Plugins::SpotOn::API::TokenManager->refreshAllTokens();
        my @sets = @Slim::Utils::Timers::set_calls;
        ok(scalar(@sets) >= 1, 'AUTH-03: refreshAllTokens re-arms timer via setTimer');
    }

    # --------------------------------------------------------
    # AUTH-05: Account management
    # --------------------------------------------------------

    # AUTH-05: getAccountIds returns all account IDs
    {
        preferences('plugin.spoton')->set('accounts', {
            'acct_aaa' => { displayName => 'Alice', spotifyUserId => 'alice123' },
            'acct_bbb' => { displayName => 'Bob',   spotifyUserId => 'bob456' },
        });
        my @ids = Plugins::SpotOn::API::TokenManager->getAccountIds();
        is(scalar(@ids), 2, 'AUTH-05: getAccountIds returns 2 IDs for 2 seeded accounts');
    }

    # AUTH-05: removeAccount removes from prefs and cache
    # M2: removeAccount also deletes the account's credentials dir from disk
    {
        reset_state();
        preferences('plugin.spoton')->set('accounts', {
            'remove_me' => { displayName => 'Remove', spotifyUserId => 'removeme' },
        });
        Slim::Utils::Cache->new()->set('spoton_token_remove_me_own', 'cached_tok', 3600);

        # M2: seed a credentials dir for the account
        use File::Spec::Functions qw(catdir catfile);
        my $acct_dir = catdir($cache_dir, 'spoton', 'remove_me');
        File::Path::make_path($acct_dir);
        open(my $cfh, '>', catfile($acct_dir, 'credentials.json')) or die "seed creds: $!";
        print $cfh '{"username":"removeme"}';
        close($cfh);

        Plugins::SpotOn::API::TokenManager->removeAccount('remove_me');

        my %accts = map { $_ => 1 } Plugins::SpotOn::API::TokenManager->getAccountIds();
        ok(!exists $accts{remove_me},
            'AUTH-05: removeAccount removes account from prefs');
        ok(!defined Slim::Utils::Cache->new()->get('spoton_token_remove_me_own'),
            'AUTH-05: removeAccount clears cached access token');
        ok(!-d $acct_dir,
            'M2: removeAccount deletes the account credentials dir from disk');
        ok(-d catdir($cache_dir, 'spoton'),
            'M2: shared spoton cache root is NOT removed');
    }

    # --------------------------------------------------------
    # AUTH-05: getActiveAccountName
    # --------------------------------------------------------
    {
        preferences('plugin.spoton')->set('accounts', {
            'active_acct' => { displayName => 'Alice Spotify', spotifyUserId => 'alice' },
        });
        preferences('plugin.spoton')->set('activeAccount', 'active_acct');

        my $name = Plugins::SpotOn::API::TokenManager->getActiveAccountName(undef);
        is($name, 'Alice Spotify', 'AUTH-05: getActiveAccountName returns displayName of active account');
    }

    # --------------------------------------------------------
    # getToken: cache hit path (no async call if cached)
    # --------------------------------------------------------
    {
        reset_state();
        Slim::Utils::Cache->new()->set('spoton_token_cached_acct_own', 'existing_tok', 3300);

        my $got_token;
        Plugins::SpotOn::API::TokenManager->getToken('cached_acct', sub {
            $got_token = shift;
        });

        is($got_token, 'existing_tok',
            'getToken: returns cached token without spawning binary');
    }

    # --------------------------------------------------------
    # Keymaster: _fetchKeymasterToken spawns async via Proc::Background (H2)
    # --------------------------------------------------------
    {
        reset_state();
        Proc::Background::reset_spawns();
        $Proc::Background::mock_output = '{"accessToken":"async_tok","expiresIn":3600}';
        # mock_alive = 0: process "exits" immediately, first poll completes fetch

        my $got_token;
        Plugins::SpotOn::API::TokenManager->_fetchKeymasterToken('keymaster_acct', 'own', sub {
            $got_token = shift;
        });

        is(scalar(@Proc::Background::spawn_calls), 1,
            'H2: _fetchKeymasterToken spawns via Proc::Background (no blocking backtick)');
        my $call = $Proc::Background::spawn_calls[0];
        ok((grep { $_ eq '--get-token' } @{ $call->{args} }),
            'H2: --get-token passed as argument-list element (no shell string)');
        ok(scalar(@Slim::Utils::Timers::set_calls) >= 1,
            'H2: poll timer armed — fetch is asynchronous');
        ok(!defined $got_token,
            'H2: callback not yet fired before poll timer runs (truly async)');

        # Run the deferred poll — process has exited, output parsed, token delivered
        Slim::Utils::Timers::run_deferred();
        is($got_token, 'async_tok',
            'H2: token delivered via async poll completion');
    }

    # --------------------------------------------------------
    # H3: concurrent getToken calls for same account/flavor coalesce
    # --------------------------------------------------------
    {
        reset_state();
        Proc::Background::reset_spawns();
        $Proc::Background::mock_output = '{"accessToken":"coal_tok","expiresIn":3600}';

        my @results;
        Plugins::SpotOn::API::TokenManager->getToken('coalacct', 'own', sub { push @results, $_[0] });
        Plugins::SpotOn::API::TokenManager->getToken('coalacct', 'own', sub { push @results, $_[0] });

        is(scalar(@Proc::Background::spawn_calls), 1,
            'H3: two concurrent getToken calls start exactly one --get-token subprocess');

        Slim::Utils::Timers::run_deferred();

        is(scalar(@results), 2, 'H3: both queued callbacks fire on completion');
        is($results[0], 'coal_tok', 'H3: first waiter receives the token');
        is($results[1], 'coal_tok', 'H3: second (coalesced) waiter receives the same token');
    }

    # --------------------------------------------------------
    # _getLmsServerName returns a string <= 60 chars
    # --------------------------------------------------------
    {
        my $name = Plugins::SpotOn::API::TokenManager->_getLmsServerName();
        ok(defined $name, '_getLmsServerName returns a defined value');
        ok(length($name) <= 60, '_getLmsServerName result <= 60 chars (Spotify device name limit)');
        ok(length($name) > 0,  '_getLmsServerName result is non-empty');
    }

    # --------------------------------------------------------
    # autoStartDiscoveryIfNeeded: calls startDiscovery when no accounts exist
    # --------------------------------------------------------
    {
        reset_state();
        # No accounts in prefs
        preferences('plugin.spoton')->set('accounts', {});

        my $discovery_called = 0;
        {
            no warnings 'redefine';
            local *Plugins::SpotOn::API::TokenManager::startDiscovery = sub {
                $discovery_called++;
            };
            Plugins::SpotOn::API::TokenManager->autoStartDiscoveryIfNeeded();
        }
        ok($discovery_called >= 1,
            'autoStartDiscoveryIfNeeded: calls startDiscovery when no accounts exist');
    }

    # --------------------------------------------------------
    # autoStartDiscoveryIfNeeded: does NOT call startDiscovery if credentials exist
    # --------------------------------------------------------
    {
        reset_state();

        # Create a fake credentials.json in a temp account dir
        use File::Spec::Functions qw(catdir catfile);
        my $account_id  = 'acct1234';
        my $acct_dir    = catdir($cache_dir, 'spoton', $account_id);
        File::Path::make_path($acct_dir);
        my $creds_file  = catfile($acct_dir, 'credentials.json');
        open(my $fh, '>', $creds_file) or die "Cannot write fake credentials: $!";
        print $fh '{"username":"testuser"}';
        close $fh;

        preferences('plugin.spoton')->set('accounts', {
            $account_id => { displayName => 'Test', spotifyUserId => 'testuser' },
        });

        my $discovery_called = 0;
        {
            no warnings 'redefine';
            local *Plugins::SpotOn::API::TokenManager::startDiscovery = sub {
                $discovery_called++;
            };
            Plugins::SpotOn::API::TokenManager->autoStartDiscoveryIfNeeded();
        }
        is($discovery_called, 0,
            'autoStartDiscoveryIfNeeded: does NOT call startDiscovery when credentials.json exists');
    }

    # --------------------------------------------------------
    # isDiscoveryRunning: returns false when no process running
    # --------------------------------------------------------
    {
        my $running = Plugins::SpotOn::API::TokenManager->isDiscoveryRunning();
        ok(!$running, 'isDiscoveryRunning: returns false when no discovery process active');
    }
}

done_testing();

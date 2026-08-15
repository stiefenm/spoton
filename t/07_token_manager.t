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
sub ttl    { $_ttl{$_[1]} }   # extra method for test inspection: verifies TTL arg passed to set()
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

# Stub: Slim::Networking::SimpleAsyncHTTP
# Used by _fetchDisplayName's /me lookup. Captures the last request for
# inspection; not directly exercised by most of this file's subtests since
# PKCE.pm itself is stubbed below (refresh flow never reaches real HTTP).
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
sub simulate_success {
    my ($class, $json_str) = @_;
    my $mock_http = bless { _content => $json_str }, 'Slim::Networking::MockHTTP';
    $last_success_cb->($mock_http) if $last_success_cb;
}
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

# ============================================================
# Stub: Plugins::SpotOn::API::PKCE — PKCE-refresh-flow test double.
# Real PKCE.pm is not loaded here (this stub shadows it via @INC order) —
# TokenManager.pm's behavior around loadTokens/refreshAccessToken/
# storeTokens is what this file tests, not PKCE.pm's own HTTP/crypto
# internals (those live in PKCE.pm itself, no dedicated unit test yet).
# ============================================================
write_stub($stub_dir, 'Plugins::SpotOn::API::PKCE', <<'END');
package Plugins::SpotOn::API::PKCE;

our @loadTokens_calls          = ();
our @refreshAccessToken_calls  = ();
our @storeTokens_calls         = ();

our $loadTokens_result;                  # default fallback for loadTokens()
our %loadTokens_by_account     = ();     # per-account override

our $refreshAccessToken_result;          # tokenData hashref on success, else undef
our $refreshAccessToken_error;           # error string on failure
our $refreshAccessToken_errorDetail;     # { http_code => N, oauth_error => str|undef }
our $refreshAccessToken_defer = 0;       # when true, queue $cb instead of firing immediately
our @refreshAccessToken_pending = ();

our $storeTokens_result = 1;

sub loadTokens {
    my ($accountId) = @_;
    push @loadTokens_calls, $accountId;
    return exists $loadTokens_by_account{$accountId}
        ? $loadTokens_by_account{$accountId}
        : $loadTokens_result;
}

sub refreshAccessToken {
    my ($refreshToken, $clientId, $cb) = @_;
    push @refreshAccessToken_calls, { refresh_token => $refreshToken, client_id => $clientId };

    if ($refreshAccessToken_defer) {
        push @refreshAccessToken_pending, $cb;
        return;
    }

    if ($refreshAccessToken_result) {
        $cb->($refreshAccessToken_result);
    } else {
        $cb->(undef, $refreshAccessToken_error, $refreshAccessToken_errorDetail);
    }
}

# Fires all queued (deferred) refreshAccessToken callbacks with the given
# result args -- used by the in-flight coalescing test to control exactly
# when the "in-flight" refresh resolves.
sub fire_pending {
    my (@args) = @_;
    my @cbs = @refreshAccessToken_pending;
    @refreshAccessToken_pending = ();
    $_->(@args) for @cbs;
}

sub storeTokens {
    my ($accountId, $tokenData) = @_;
    push @storeTokens_calls, { accountId => $accountId, tokenData => $tokenData };
    return $storeTokens_result;
}

sub reset_stub {
    @loadTokens_calls              = ();
    @refreshAccessToken_calls      = ();
    @storeTokens_calls             = ();
    $loadTokens_result             = undef;
    %loadTokens_by_account         = ();
    $refreshAccessToken_result     = undef;
    $refreshAccessToken_error      = undef;
    $refreshAccessToken_errorDetail = undef;
    $refreshAccessToken_defer      = 0;
    @refreshAccessToken_pending    = ();
    $storeTokens_result            = 1;
}
1;
END

# ============================================================
# Stub: Plugins::SpotOn::Status — tracks recordError() calls (D-08 Channel 3)
# ============================================================
write_stub($stub_dir, 'Plugins::SpotOn::Status', <<'END');
package Plugins::SpotOn::Status;
our @recordError_calls = ();
sub recordError {
    my ($class, $level, $module, $message) = @_;
    push @recordError_calls, { level => $level, module => $module, message => $message };
}
sub reset_stub { @recordError_calls = () }
1;
END

# ============================================================
# Stub: Plugins::SpotOn::API::Credentials — credentialsPathFor() only.
# Mirrors the real _accountDir logic ({cachedir}/spoton/{accountId}/) using
# the same $cache_dir the Prefs stub already exposes as cachedir, so
# accountNeedsMigration's -f check resolves to the same directory the tests
# write credentials.json/pkce_tokens.json fixtures into (D-05 migration
# detection tests, Task 1).
# ============================================================
write_stub($stub_dir, 'Plugins::SpotOn::API::Credentials', <<"END");
package Plugins::SpotOn::API::Credentials;
use File::Spec::Functions qw(catdir catfile);
my \$stub_cache_dir = '$cache_dir';
sub credentialsPathFor {
    my (\$class, \$accountId) = \@_;
    return catfile(\$stub_cache_dir, 'spoton', \$accountId, 'credentials.json');
}
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
# into main:: namespace (e.g., preferences(), logger()), and so package
# globals (PKCE/Status stubs) exist before tests manipulate them.
require Slim::Utils::Prefs;
Slim::Utils::Prefs->import();
require Slim::Utils::Log;
Slim::Utils::Log->import();
require Plugins::SpotOn::API::PKCE;
require Plugins::SpotOn::API::Credentials;
require Plugins::SpotOn::Status;

# ============================================================
# Tests: TokenManager.pm (skip if not yet created)
# ============================================================

my $tm_module = "$project_dir/Plugins/SpotOn/API/TokenManager.pm";

SKIP: {
    skip "TokenManager.pm not yet created", 34
        unless -f $tm_module;

    require_ok('Plugins::SpotOn::API::TokenManager')
        or BAIL_OUT("Failed to load TokenManager.pm");

    # Helper: reset cache + timer call state between tests
    sub reset_state {
        Slim::Utils::Cache->new()->clear();
        Slim::Utils::Timers::reset_calls();
    }

    # Helper: reset cache/timers AND the PKCE/Status test doubles
    sub reset_all {
        reset_state();
        Plugins::SpotOn::API::PKCE::reset_stub();
        Plugins::SpotOn::Status::reset_stub();
    }

    # --------------------------------------------------------
    # _cacheToken: token caching (D-04 -- no flavor param)
    # --------------------------------------------------------
    {
        reset_all();
        Plugins::SpotOn::API::TokenManager->_cacheToken('testacct', 'tok123', 3600);
        my $cache = Slim::Utils::Cache->new();
        is($cache->get('spoton_token_testacct'), 'tok123',
            '_cacheToken stores token under spoton_token_<accountId> (no flavor suffix, D-04)');
        is($cache->ttl('spoton_token_testacct'), 3300,
            '_cacheToken TTL is expires_in(3600) - 300 = 3300');
    }

    {
        reset_all();
        Plugins::SpotOn::API::TokenManager->_cacheToken('shortacct', 'tok456', 200);
        my $ttl = Slim::Utils::Cache->new()->ttl('spoton_token_shortacct');
        is($ttl, 200, '_cacheToken uses expiresIn(200) as TTL when expiresIn < TOKEN_EXPIRY_BUFFER');
    }

    # --------------------------------------------------------
    # refreshAllTokens re-arms timer (no accounts -- sanity check)
    # --------------------------------------------------------
    {
        reset_all();
        preferences('plugin.spoton')->set('accounts', {});
        Plugins::SpotOn::API::TokenManager->refreshAllTokens();
        my @sets = @Slim::Utils::Timers::set_calls;
        ok(scalar(@sets) >= 1, 'refreshAllTokens re-arms timer via setTimer');
    }

    # --------------------------------------------------------
    # Account management (unchanged by this rewrite)
    # --------------------------------------------------------
    {
        preferences('plugin.spoton')->set('accounts', {
            'acct_aaa' => { displayName => 'Alice', spotifyUserId => 'alice123' },
            'acct_bbb' => { displayName => 'Bob',   spotifyUserId => 'bob456' },
        });
        my @ids = Plugins::SpotOn::API::TokenManager->getAccountIds();
        is(scalar(@ids), 2, 'getAccountIds returns 2 IDs for 2 seeded accounts');
    }

    {
        preferences('plugin.spoton')->set('accounts', {
            'active_acct' => { displayName => 'Alice Spotify', spotifyUserId => 'alice' },
        });
        preferences('plugin.spoton')->set('activeAccount', 'active_acct');

        my $name = Plugins::SpotOn::API::TokenManager->getActiveAccountName(undef);
        is($name, 'Alice Spotify', 'getActiveAccountName returns displayName of active account');
    }

    # --------------------------------------------------------
    # 1. cache hit skips refresh
    # --------------------------------------------------------
    {
        reset_all();
        Slim::Utils::Cache->new()->set('spoton_token_cache_hit_acct', 'existing_tok', 3300);

        my $got_token;
        Plugins::SpotOn::API::TokenManager->getToken('cache_hit_acct', sub {
            $got_token = shift;
        });

        is(scalar(@Plugins::SpotOn::API::PKCE::refreshAccessToken_calls), 0,
            'getToken: cache hit does not call PKCE::refreshAccessToken');
        is($got_token, 'existing_tok',
            'getToken: cache hit returns cached token');
    }

    # --------------------------------------------------------
    # 2. cache miss triggers PKCE refresh (loadTokens -> refreshAccessToken
    #    -> storeTokens with ROTATED refresh_token -> _cacheToken)
    # --------------------------------------------------------
    {
        reset_all();
        $Plugins::SpotOn::API::PKCE::loadTokens_result = { refresh_token => 'rt', client_id => 'cid' };
        $Plugins::SpotOn::API::PKCE::refreshAccessToken_result = {
            access_token => 'at', refresh_token => 'new_rt', expires_in => 3600,
        };

        my $got_token;
        Plugins::SpotOn::API::TokenManager->getToken('miss_acct', sub {
            $got_token = shift;
        });

        is(scalar(@Plugins::SpotOn::API::PKCE::loadTokens_calls), 1,
            'getToken: cache miss calls PKCE::loadTokens');
        is(scalar(@Plugins::SpotOn::API::PKCE::refreshAccessToken_calls), 1,
            'getToken: cache miss calls PKCE::refreshAccessToken');
        is($Plugins::SpotOn::API::PKCE::refreshAccessToken_calls[0]{refresh_token}, 'rt',
            'getToken: refreshAccessToken called with the on-disk refresh_token');
        is(scalar(@Plugins::SpotOn::API::PKCE::storeTokens_calls), 1,
            'getToken: cache miss calls PKCE::storeTokens');
        is($Plugins::SpotOn::API::PKCE::storeTokens_calls[0]{tokenData}{refresh_token}, 'new_rt',
            'getToken: storeTokens persists the ROTATED refresh_token, not the original');
        is($got_token, 'at', 'getToken: callback receives the new access_token');
    }

    # --------------------------------------------------------
    # 3. invalid_grant sets reauth flag
    # --------------------------------------------------------
    {
        reset_all();
        $Plugins::SpotOn::API::PKCE::loadTokens_result = { refresh_token => 'rt3', client_id => 'cid' };
        $Plugins::SpotOn::API::PKCE::refreshAccessToken_error = 'invalid_grant';
        $Plugins::SpotOn::API::PKCE::refreshAccessToken_errorDetail = {
            http_code => 400, oauth_error => 'invalid_grant',
        };

        my $got_token;
        Plugins::SpotOn::API::TokenManager->getToken('reauth_acct3', sub { $got_token = shift });

        is(Plugins::SpotOn::API::TokenManager->needsReauth('reauth_acct3'), 1,
            'invalid_grant failure sets needsReauth flag');
        ok((grep { $_->{module} eq 'Auth' } @Plugins::SpotOn::Status::recordError_calls),
            'invalid_grant failure calls Status::recordError with module Auth');
        ok(!defined $got_token, 'invalid_grant failure delivers undef to caller');
    }

    # --------------------------------------------------------
    # 4. 400 without parseable oauth_error sets reauth flag (M-6)
    # --------------------------------------------------------
    {
        reset_all();
        $Plugins::SpotOn::API::PKCE::loadTokens_result = { refresh_token => 'rt4', client_id => 'cid' };
        $Plugins::SpotOn::API::PKCE::refreshAccessToken_error = 'bad request';
        $Plugins::SpotOn::API::PKCE::refreshAccessToken_errorDetail = {
            http_code => 400, oauth_error => undef,
        };

        Plugins::SpotOn::API::TokenManager->getToken('reauth_acct4', sub { });

        is(Plugins::SpotOn::API::TokenManager->needsReauth('reauth_acct4'), 1,
            'M-6: HTTP 400 without parseable oauth_error still sets needsReauth');
    }

    # --------------------------------------------------------
    # 5. transient error does not set reauth flag
    # --------------------------------------------------------
    {
        reset_all();
        $Plugins::SpotOn::API::PKCE::loadTokens_result = { refresh_token => 'rt5', client_id => 'cid' };
        $Plugins::SpotOn::API::PKCE::refreshAccessToken_error = 'timeout';
        $Plugins::SpotOn::API::PKCE::refreshAccessToken_errorDetail = {
            http_code => 0, oauth_error => undef,
        };

        Plugins::SpotOn::API::TokenManager->getToken('reauth_acct5', sub { });

        is(Plugins::SpotOn::API::TokenManager->needsReauth('reauth_acct5'), 0,
            'transient error (timeout, no HTTP code) does not set needsReauth');
        ok(!(grep { $_->{module} eq 'Auth' } @Plugins::SpotOn::Status::recordError_calls),
            'transient error does not call Status::recordError for Auth module');
    }

    # --------------------------------------------------------
    # 6. getToken short-circuits on needsReauth (M-4)
    # --------------------------------------------------------
    {
        reset_all();
        Slim::Utils::Cache->new()->set('spoton_needs_reauth_shortcircuit_acct',
            { reason => 'invalid_grant', ts => time() }, 'never');

        my $got_token = 'unset';
        Plugins::SpotOn::API::TokenManager->getToken('shortcircuit_acct', sub {
            $got_token = shift;
        });

        is(scalar(@Plugins::SpotOn::API::PKCE::loadTokens_calls), 0,
            'M-4: getToken short-circuit does not call PKCE::loadTokens');
        is(scalar(@Plugins::SpotOn::API::PKCE::refreshAccessToken_calls), 0,
            'M-4: getToken short-circuit does not call PKCE::refreshAccessToken');
        ok(!defined $got_token, 'M-4: getToken short-circuit delivers undef to caller');
    }

    # --------------------------------------------------------
    # 7. refreshAllTokens skips accounts without pkce_tokens.json
    # --------------------------------------------------------
    {
        reset_all();
        preferences('plugin.spoton')->set('accounts', {
            has_tok => { displayName => 'HasTok', spotifyUserId => 'has_tok_user' },
            no_tok  => { displayName => 'NoTok',  spotifyUserId => 'no_tok_user' },
        });
        $Plugins::SpotOn::API::PKCE::loadTokens_by_account{has_tok} = { refresh_token => 'rt7', client_id => 'cid' };
        # no_tok deliberately left unset -> loadTokens returns undef (no pkce_tokens.json)
        $Plugins::SpotOn::API::PKCE::refreshAccessToken_result = {
            access_token => 'at7', refresh_token => 'rt7b', expires_in => 3600,
        };

        Plugins::SpotOn::API::TokenManager->refreshAllTokens();

        is(scalar(@Plugins::SpotOn::API::PKCE::refreshAccessToken_calls), 1,
            'refreshAllTokens: only the account WITH pkce_tokens.json triggers a refresh');
        is(Plugins::SpotOn::API::TokenManager->needsReauth('no_tok'), 0,
            'refreshAllTokens: account without pkce_tokens.json is skipped, not flagged as expired (Pitfall 3)');
    }

    # --------------------------------------------------------
    # 8. refreshAllTokens calls _refreshToken not getToken (bypasses cache, M-5)
    # --------------------------------------------------------
    {
        reset_all();
        preferences('plugin.spoton')->set('accounts', {
            acct8 => { displayName => 'X', spotifyUserId => 'x' },
        });
        Slim::Utils::Cache->new()->set('spoton_token_acct8', 'cached_tok8', 3300);
        $Plugins::SpotOn::API::PKCE::loadTokens_by_account{acct8} = { refresh_token => 'rt8', client_id => 'cid' };
        $Plugins::SpotOn::API::PKCE::refreshAccessToken_result = {
            access_token => 'at8', refresh_token => 'rt8b', expires_in => 3600,
        };

        Plugins::SpotOn::API::TokenManager->refreshAllTokens();

        is(scalar(@Plugins::SpotOn::API::PKCE::refreshAccessToken_calls), 1,
            'M-5: refreshAllTokens forces a real refresh even when the cache is warm '
            . '(a getToken cache-hit would have skipped this)');
    }

    # --------------------------------------------------------
    # 9. in-flight coalescing (H3, T-50-02)
    # --------------------------------------------------------
    {
        reset_all();
        $Plugins::SpotOn::API::PKCE::loadTokens_result = { refresh_token => 'rt9', client_id => 'cid' };
        $Plugins::SpotOn::API::PKCE::refreshAccessToken_defer = 1;

        my @results;
        Plugins::SpotOn::API::TokenManager->getToken('coalacct9', sub { push @results, $_[0] });
        Plugins::SpotOn::API::TokenManager->getToken('coalacct9', sub { push @results, $_[0] });

        is(scalar(@Plugins::SpotOn::API::PKCE::refreshAccessToken_calls), 1,
            'H3: two concurrent getToken calls for the same account share one refreshAccessToken call');
        is(scalar(@results), 0, 'H3: neither callback fires before the in-flight refresh resolves');

        Plugins::SpotOn::API::PKCE::fire_pending({
            access_token => 'coal_tok', refresh_token => 'rt9b', expires_in => 3600,
        });

        is(scalar(@results), 2, 'H3: both queued callbacks fire once the refresh resolves');
        is($results[0], 'coal_tok', 'H3: first waiter receives the token');
        is($results[1], 'coal_tok', 'H3: second (coalesced) waiter receives the same token');
    }

    # --------------------------------------------------------
    # 10. removeAccount clears token and reauth caches
    # --------------------------------------------------------
    {
        reset_all();
        preferences('plugin.spoton')->set('accounts', {
            'remove_me' => { displayName => 'Remove', spotifyUserId => 'removeme' },
        });
        Slim::Utils::Cache->new()->set('spoton_token_remove_me', 'cached_tok', 3600);
        Slim::Utils::Cache->new()->set('spoton_needs_reauth_remove_me', { reason => 'x' }, 'never');

        # M2: seed a credentials dir for the account
        use File::Spec::Functions qw(catdir catfile);
        my $acct_dir = catdir($cache_dir, 'spoton', 'remove_me');
        File::Path::make_path($acct_dir);
        open(my $cfh, '>', catfile($acct_dir, 'pkce_tokens.json')) or die "seed creds: $!";
        print $cfh '{"refresh_token":"rt"}';
        close($cfh);

        Plugins::SpotOn::API::TokenManager->removeAccount('remove_me');

        my %accts = map { $_ => 1 } Plugins::SpotOn::API::TokenManager->getAccountIds();
        ok(!exists $accts{remove_me}, 'removeAccount removes account from prefs');
        ok(!defined Slim::Utils::Cache->new()->get('spoton_token_remove_me'),
            'removeAccount clears cached access token (spoton_token_{id}, no flavor suffix)');
        ok(!defined Slim::Utils::Cache->new()->get('spoton_needs_reauth_remove_me'),
            'removeAccount clears the needsReauth flag');
        ok(!-d $acct_dir, 'M2: removeAccount deletes the account credentials dir from disk');
        ok(-d catdir($cache_dir, 'spoton'), 'M2: shared spoton cache root is NOT removed');
    }

    # --------------------------------------------------------
    # 11. needsReauth flag uses 'never' TTL (M-1)
    # --------------------------------------------------------
    {
        reset_all();
        $Plugins::SpotOn::API::PKCE::loadTokens_result = { refresh_token => 'rt11', client_id => 'cid' };
        $Plugins::SpotOn::API::PKCE::refreshAccessToken_error = 'invalid_grant';
        $Plugins::SpotOn::API::PKCE::refreshAccessToken_errorDetail = {
            http_code => 400, oauth_error => 'invalid_grant',
        };

        Plugins::SpotOn::API::TokenManager->getToken('ttl_acct11', sub { });

        is(Slim::Utils::Cache->new()->ttl('spoton_needs_reauth_ttl_acct11'), 'never',
            "M-1: _markNeedsReauth passes the string 'never' as the cache TTL "
            . '(DbCache default is 1h -- an omitted TTL would silently expire the flag)');
    }

    # --------------------------------------------------------
    # 12. clearNeedsReauth on successful refresh
    # --------------------------------------------------------
    {
        reset_all();
        # Simulate a stale flag from a prior failure, then drive a successful
        # refresh directly via _refreshToken (the path refreshAllTokens uses,
        # M-5) -- getToken itself would short-circuit on the flag (M-4).
        Slim::Utils::Cache->new()->set('spoton_needs_reauth_clear_acct12',
            { reason => 'invalid_grant', ts => time() }, 'never');

        $Plugins::SpotOn::API::PKCE::loadTokens_result = { refresh_token => 'rt12', client_id => 'cid' };
        $Plugins::SpotOn::API::PKCE::refreshAccessToken_result = {
            access_token => 'at12', refresh_token => 'rt12b', expires_in => 3600,
        };

        Plugins::SpotOn::API::TokenManager->_refreshToken('clear_acct12', sub { });

        is(Plugins::SpotOn::API::TokenManager->needsReauth('clear_acct12'), 0,
            'clearNeedsReauth: a successful refresh clears a previously-set needsReauth flag');
    }

    # --------------------------------------------------------
    # clearNeedsReauth is a public method (L-6) -- direct call succeeds
    # --------------------------------------------------------
    {
        reset_all();
        Slim::Utils::Cache->new()->set('spoton_needs_reauth_public_test', { reason => 'x' }, 'never');
        Plugins::SpotOn::API::TokenManager->clearNeedsReauth('public_test');
        is(Plugins::SpotOn::API::TokenManager->needsReauth('public_test'), 0,
            'L-6: clearNeedsReauth is callable as a public (non-underscore) cross-module method');
    }

    # --------------------------------------------------------
    # anyAccountNeedsReauth: aggregate query across all accounts
    # --------------------------------------------------------
    {
        reset_all();
        preferences('plugin.spoton')->set('accounts', {
            fine_acct    => { displayName => 'Fine', spotifyUserId => 'fine' },
            expired_acct => { displayName => 'Expired', spotifyUserId => 'expired' },
        });
        is(Plugins::SpotOn::API::TokenManager->anyAccountNeedsReauth(), 0,
            'anyAccountNeedsReauth: returns 0 when no account is flagged');

        Slim::Utils::Cache->new()->set('spoton_needs_reauth_expired_acct', { reason => 'x' }, 'never');
        is(Plugins::SpotOn::API::TokenManager->anyAccountNeedsReauth(), 1,
            'anyAccountNeedsReauth: returns 1 when at least one account is flagged');
    }

    # --------------------------------------------------------
    # accountNeedsMigration / anyAccountNeedsMigration (D-05, AUTH-07, Plan 03 Task 1)
    # --------------------------------------------------------

    # (A) credentials.json present, no pkce_tokens.json -- v2.x migration account
    {
        reset_all();
        my $acct_dir = catdir($cache_dir, 'spoton', 'mig_needs');
        File::Path::make_path($acct_dir);
        open(my $cfh, '>', catfile($acct_dir, 'credentials.json')) or die "seed creds: $!";
        print $cfh '{"auth_type":1,"username":"u","auth_data":"d"}';
        close($cfh);
        $Plugins::SpotOn::API::PKCE::loadTokens_by_account{mig_needs} = undef;

        is(Plugins::SpotOn::API::TokenManager->accountNeedsMigration('mig_needs'), 1,
            'accountNeedsMigration: credentials.json present + no pkce_tokens.json => needs migration (D-05)');
    }

    # (B) credentials.json present AND PKCE tokens loadable -- already migrated (D-06 auto-dismiss)
    {
        reset_all();
        my $acct_dir = catdir($cache_dir, 'spoton', 'mig_has_pkce');
        File::Path::make_path($acct_dir);
        open(my $cfh, '>', catfile($acct_dir, 'credentials.json')) or die "seed creds: $!";
        print $cfh '{"auth_type":1,"username":"u","auth_data":"d"}';
        close($cfh);
        $Plugins::SpotOn::API::PKCE::loadTokens_by_account{mig_has_pkce} =
            { refresh_token => 'rt', client_id => 'cid' };

        is(Plugins::SpotOn::API::TokenManager->accountNeedsMigration('mig_has_pkce'), 0,
            'accountNeedsMigration: credentials.json + pkce_tokens.json present => already migrated (D-06)');
    }

    # (C) no credentials.json at all -- not a v2.x user, nothing to migrate
    {
        reset_all();
        is(Plugins::SpotOn::API::TokenManager->accountNeedsMigration('mig_no_creds'), 0,
            'accountNeedsMigration: no credentials.json => not a v2.x account, returns 0');
    }

    # (D) anyAccountNeedsMigration: at least one account needs migration
    {
        reset_all();
        my $needs_dir = catdir($cache_dir, 'spoton', 'agg_needs');
        File::Path::make_path($needs_dir);
        open(my $cfh1, '>', catfile($needs_dir, 'credentials.json')) or die "seed creds: $!";
        print $cfh1 '{"auth_type":1,"username":"u","auth_data":"d"}';
        close($cfh1);
        $Plugins::SpotOn::API::PKCE::loadTokens_by_account{agg_needs} = undef;

        my $has_pkce_dir = catdir($cache_dir, 'spoton', 'agg_has_pkce');
        File::Path::make_path($has_pkce_dir);
        open(my $cfh2, '>', catfile($has_pkce_dir, 'credentials.json')) or die "seed creds: $!";
        print $cfh2 '{"auth_type":1,"username":"u","auth_data":"d"}';
        close($cfh2);
        $Plugins::SpotOn::API::PKCE::loadTokens_by_account{agg_has_pkce} =
            { refresh_token => 'rt', client_id => 'cid' };

        preferences('plugin.spoton')->set('accounts', {
            agg_needs    => { displayName => 'Needs',   spotifyUserId => 'needs' },
            agg_has_pkce => { displayName => 'HasPkce',  spotifyUserId => 'haspkce' },
        });

        is(Plugins::SpotOn::API::TokenManager->anyAccountNeedsMigration(), 1,
            'anyAccountNeedsMigration: returns 1 when at least one known account needs migration');
    }

    # (E) anyAccountNeedsMigration: no account needs migration
    {
        reset_all();
        my $dir1 = catdir($cache_dir, 'spoton', 'agg_ok1');
        File::Path::make_path($dir1);
        open(my $cfh1, '>', catfile($dir1, 'credentials.json')) or die "seed creds: $!";
        print $cfh1 '{"auth_type":1,"username":"u","auth_data":"d"}';
        close($cfh1);
        $Plugins::SpotOn::API::PKCE::loadTokens_by_account{agg_ok1} =
            { refresh_token => 'rt1', client_id => 'cid' };

        my $dir2 = catdir($cache_dir, 'spoton', 'agg_ok2');
        File::Path::make_path($dir2);
        open(my $cfh2, '>', catfile($dir2, 'credentials.json')) or die "seed creds: $!";
        print $cfh2 '{"auth_type":1,"username":"u","auth_data":"d"}';
        close($cfh2);
        $Plugins::SpotOn::API::PKCE::loadTokens_by_account{agg_ok2} =
            { refresh_token => 'rt2', client_id => 'cid' };

        preferences('plugin.spoton')->set('accounts', {
            agg_ok1 => { displayName => 'Ok1', spotifyUserId => 'ok1' },
            agg_ok2 => { displayName => 'Ok2', spotifyUserId => 'ok2' },
        });

        is(Plugins::SpotOn::API::TokenManager->anyAccountNeedsMigration(), 0,
            'anyAccountNeedsMigration: returns 0 when every known account already has PKCE tokens');
    }

    # (F) Permanent regression guard (review finding #5, AUTH-07): TokenManager.pm
    # source must never re-introduce the retired Keymaster HTTP token service
    # (Mercury hm://keymaster minting, removed in Phase 53). Plan 66-01
    # reverts the 65-04 refinement: the refresh-fallback client_id is the
    # bundled Extended-Quota default again (D-01), not the Keymaster ID --
    # the guard returns to its original Phase-53 strict form, banning every
    # "keymaster" reference in non-comment code with no whitelist.
    {
        open(my $src_fh, '<', $tm_module) or die "cannot read $tm_module: $!";
        local $/;
        my $source = <$src_fh>;
        close($src_fh);

        my $code = join("\n", grep { !/^\s*#/ } split /\n/, $source);

        my @hits = ($code =~ /keymaster/gi);
        is(scalar(@hits), 0,
            'AUTH-07 regression guard: TokenManager.pm has no keymaster reference '
            . 'in non-comment code (plan 66-01)');
    }
}

done_testing();

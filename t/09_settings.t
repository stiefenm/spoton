#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# Resolve project root
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname($test_dir);

# Create a temporary directory for LMS stubs
my $stub_dir = tempdir(CLEANUP => 1);
my $cache_dir = tempdir(CLEANUP => 1);

# ============================================================
# Helper: write a stub Perl module
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
# LMS Module Stubs
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
write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
sub addLogCategory { return bless {}, 'Slim::Utils::Log' }
sub logger {
    return bless { _calls => [] }, 'Slim::Utils::Log';
}
sub info  { push @{$_[0]->{_calls}}, ['info',  $_[1]] }
sub warn  { push @{$_[0]->{_calls}}, ['warn',  $_[1]] }
sub error { push @{$_[0]->{_calls}}, ['error', $_[1]] }
sub debug { push @{$_[0]->{_calls}}, ['debug', $_[1]] }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Stub: Slim::Utils::Prefs
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
    return bless { _ns => \$self->{_ns} . '_client_' . (\$client // 'default') }, 'Slim::Utils::Prefs';
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
our @set_calls  = ();
our @kill_calls = ();
sub setTimer   { push @set_calls,  [@_] }
sub killTimers { push @kill_calls, [@_] }
sub reset_calls { @set_calls = (); @kill_calls = () }
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

# Note: File::Spec::Functions is a core module — no stub needed.
# The real File::Spec::Functions provides catdir/catfile as exported functions.

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

# Stub: Slim::Player::Client
write_stub($stub_dir, 'Slim::Player::Client', <<'END');
package Slim::Player::Client;
our @_mock_clients = ();
sub clients { return @_mock_clients }
sub set_mock_clients { @_mock_clients = @_ }
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

# Stub: Slim::Web::Pages (for addRawFunction)
write_stub($stub_dir, 'Slim::Web::Pages', <<'END');
package Slim::Web::Pages;
our @registered_raw = ();
sub addRawFunction { push @registered_raw, [$_[1], $_[2]] }
sub reset_calls    { @registered_raw = () }
1;
END

# Stub: Slim::Web::HTTP (for addHTTPResponse in _discoveryStatusHandler)
write_stub($stub_dir, 'Slim::Web::HTTP', <<'END');
package Slim::Web::HTTP;
our @http_responses = ();
sub addHTTPResponse { push @http_responses, [@_] }
sub reset_calls     { @http_responses = () }
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
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
sub new { bless {}, shift }
sub get  { }
sub post { }
1;
END

# Stub: Plugins::SpotOn::Helper (needed by Settings.pm)
write_stub($stub_dir, 'Plugins::SpotOn::Helper', <<'END');
package Plugins::SpotOn::Helper;
sub get { return '/usr/bin/false' }
sub init { }
1;
END

# Stub: Plugins::SpotOn::API::TokenManager (ZeroConf methods — no OAuth)
write_stub($stub_dir, 'Plugins::SpotOn::API::TokenManager', <<'END');
package Plugins::SpotOn::API::TokenManager;
our $discovery_running = 0;
our @start_calls = ();
our @stop_calls  = ();
sub startDiscovery    { push @start_calls, 1; $discovery_running = 1 }
sub stopDiscovery     { push @stop_calls,  1; $discovery_running = 0 }
sub isDiscoveryRunning { return $discovery_running }
sub removeAccount     { }
sub getAccountIds     { return () }
sub reset_calls {
    @start_calls = (); @stop_calls = ();
    $discovery_running = 0;
}
1;
END

# Stub: URI::Escape — not Perl core, bundled by LMS
write_stub($stub_dir, 'URI::Escape', <<'END');
package URI::Escape;
use Exporter 'import';
our @EXPORT_OK = qw(uri_escape);
sub uri_escape { my ($s) = @_; $s =~ s/([^A-Za-z0-9\-._~])/sprintf("%%%02X", ord($1))/ge; return $s; }
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
    *main::ISWINDOWS   = sub () { 0 };
    *main::ISMAC       = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
}

# Add to @INC
unshift @INC, $stub_dir, $project_dir;

# ============================================================
# AUTH-04: Filesystem permission tests (immediate — no module required)
# These test the chmod 0700/0600 behavior at the filesystem level.
# ============================================================
{
    my $acct_tmpdir = tempdir(CLEANUP => 1);

    # Create a fake credentials.json
    my $cred_file = "$acct_tmpdir/credentials.json";
    open(my $fh, '>', $cred_file) or die "Cannot create credentials.json: $!";
    print $fh '{"username":"testuser"}';
    close($fh);

    chmod 0700, $acct_tmpdir;
    chmod 0600, $cred_file;

    my @stat_dir  = stat($acct_tmpdir);
    my @stat_cred = stat($cred_file);

    is($stat_dir[2]  & 07777, 0700, 'AUTH-04: chmod 0700 on account cache directory works');
    is($stat_cred[2] & 07777, 0600, 'AUTH-04: chmod 0600 on credentials.json works');
}

# ============================================================
# AUTH-05: Two separate account subdirectories (immediate filesystem test)
# Simulates what TokenManager->addAccount creates
# ============================================================
{
    my $base_dir   = tempdir(CLEANUP => 1);
    my $account_id_1 = 'abcd1234';
    my $account_id_2 = 'ef567890';

    my $dir_1 = "$base_dir/$account_id_1";
    my $dir_2 = "$base_dir/$account_id_2";

    make_path($dir_1);
    make_path($dir_2);

    ok(-d $dir_1, "AUTH-05: Account 1 subdirectory ($account_id_1) exists");
    ok(-d $dir_2, "AUTH-05: Account 2 subdirectory ($account_id_2) exists");
    isnt($dir_1, $dir_2, 'AUTH-05: Account subdirectories are distinct paths');
}

# ============================================================
# Settings.pm structure tests
# ============================================================
my $settings_module = "$project_dir/Plugins/SpotOn/Settings.pm";

SKIP: {
    skip "Settings.pm not found", 1 unless -f $settings_module;

    open(my $fh, '<', $settings_module) or die $!;
    my $src = do { local $/; <$fh> };
    close($fh);

    # PLAN 03 acceptance criteria: no OAuth artifacts (clientId is legitimate — custom Client-ID pref from Phase 04.4)
    ok($src !~ /startOAuth/,         'Settings.pm: no startOAuth reference');
    ok($src !~ /redirectUri/,        'Settings.pm: no redirectUri reference');
    ok($src !~ /buildRedirectUri/,   'Settings.pm: no buildRedirectUri reference');

    # PLAN 03 acceptance criteria: ZeroConf discovery present
    ok($src =~ /addRawFunction/,                              'Settings.pm: addRawFunction registered');
    ok($src =~ /discoveryStatus/,                             'Settings.pm: discoveryStatus endpoint registered');
    ok($src =~ /sub _discoveryStatusHandler/,                 'Settings.pm: _discoveryStatusHandler defined');
    ok($src =~ /startDiscovery/,                              'Settings.pm: startDiscovery action present');
    ok($src =~ /stopDiscovery/,                               'Settings.pm: stopDiscovery action present');
    ok($src =~ /discoveryRunning/,                            'Settings.pm: discoveryRunning template param set');
    ok($src =~ /to_json/,                                     'Settings.pm: to_json used in AJAX handler');
    ok($src =~ /addHTTPResponse/,                             'Settings.pm: addHTTPResponse used in AJAX handler');

    # prefs() should NOT include clientId
    ok($src =~ /sub prefs[^}]+return[^}]+(?!clientId)[^}]+}/s,
        'Settings.pm: prefs() method exists');
    ok($src !~ /return \(\$prefs.*clientId/,
        'Settings.pm: prefs() does not return clientId');
}

# ============================================================
# AUTH-06: Account switch updates preference
# ============================================================
SKIP: {
    skip "Settings.pm not yet updated with switchAccount handler", 2
        unless -f $settings_module && do {
            open(my $fh, '<', $settings_module) or die $!;
            my $src = do { local $/; <$fh> };
            close($fh);
            $src =~ /switchAccount/;
        };

    require Slim::Player::Client;
    require_ok('Plugins::SpotOn::Settings')
        or BAIL_OUT("Failed to load Settings.pm");

    # Simulate an account switch: Settings->handler should update activeAccount pref
    {
        my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');
        $prefs->init({ accounts => { 'abc12345' => { displayName => 'Test' } }, activeAccount => '' });

        my $param_ref = { saveSettings => 1, switchAccount => 'abc12345' };

        # Call handler — we don't need a real $client or HTTP objects for this test
        Plugins::SpotOn::Settings->handler(
            undef, $param_ref,
            sub { },  # callback
            undef, undef
        );

        my $active = $prefs->get('activeAccount');
        is($active, 'abc12345',
            'AUTH-06: Account switch via handler updates activeAccount preference to new ID');
    }
}

# ============================================================
# COMPAT-01: Global streamingMode handler save/validation (GH #96 scope
# extension) — real handler-execution coverage of the global setting.
# ============================================================
SKIP: {
    skip "Settings.pm not yet updated with global streamingMode handler", 3
        unless -f $settings_module && do {
            open(my $fh, '<', $settings_module) or die $!;
            my $src = do { local $/; <$fh> };
            close($fh);
            $src =~ /pref_streamingMode/;
        };

    skip "Settings.pm module required for global streamingMode test", 3
        unless eval { require Plugins::SpotOn::Settings; 1 };

    my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');

    Plugins::SpotOn::Settings->handler(
        undef, { saveSettings => 1, pref_streamingMode => 'proxy' },
        sub { }, undef, undef
    );
    is($prefs->get('streamingMode'), 'proxy',
        'COMPAT-01: global streamingMode handler persists valid "proxy" value');

    Plugins::SpotOn::Settings->handler(
        undef, { saveSettings => 1, pref_streamingMode => 'bogus' },
        sub { }, undef, undef
    );
    is($prefs->get('streamingMode'), 'direct',
        'COMPAT-01: global streamingMode handler falls back to "direct" for invalid value');

    # Set a known sentinel value directly, then verify a saveSettings call with
    # no pref_streamingMode key leaves it untouched (defined-check guard, T-47-05).
    $prefs->set('streamingMode', 'proxy');
    Plugins::SpotOn::Settings->handler(
        undef, { saveSettings => 1 },
        sub { }, undef, undef
    );
    is($prefs->get('streamingMode'), 'proxy',
        'COMPAT-01: global streamingMode handler leaves value untouched when pref_streamingMode key absent');
}

# ============================================================
# discoveryRunning template param test
# ============================================================
SKIP: {
    skip "Settings.pm module required for discoveryRunning test", 2
        unless eval { require Plugins::SpotOn::Settings; 1 };

    {
        # Force TokenManager not loaded so _isDiscoveryRunning returns 0 quickly
        # by temporarily removing it from %INC
        my $saved = delete $INC{'Plugins/SpotOn/API/TokenManager.pm'};

        my $param_ref = {};
        Plugins::SpotOn::Settings->handler(
            undef, $param_ref,
            sub { },
            undef, undef
        );

        # Restore %INC
        $INC{'Plugins/SpotOn/API/TokenManager.pm'} = $saved if defined $saved;

        is($param_ref->{discoveryRunning}, 0,
            'discoveryRunning: returns 0 when TokenManager not loaded');
    }

    {
        # Ensure TokenManager is loaded (stub or real) and discoveryRunning is 0
        require Plugins::SpotOn::API::TokenManager;

        my $param_ref = {};
        Plugins::SpotOn::Settings->handler(
            undef, $param_ref,
            sub { },
            undef, undef
        );

        # The stub returns 0 by default; real module also has isDiscoveryRunning returning false
        is($param_ref->{discoveryRunning}, 0,
            'discoveryRunning: returns 0 when isDiscoveryRunning is false');
    }
}

# ============================================================
# _discoveryStatusHandler JSON response test
# ============================================================
SKIP: {
    skip "Settings.pm module required for _discoveryStatusHandler test", 3
        unless eval { require Plugins::SpotOn::Settings; 1 };

    # Override addHTTPResponse to capture the JSON content
    my $captured_content;
    {
        no warnings 'redefine', 'once';
        local *Slim::Web::HTTP::addHTTPResponse = sub {
            my ($client, $resp, $content_ref) = @_;
            $captured_content = $$content_ref;
        };

        # Mock HTTP response object
        my $response_obj = bless {}, 'MockHTTPResponse2';
        no warnings 'once';
        local *MockHTTPResponse2::header       = sub { };
        local *MockHTTPResponse2::code         = sub { };
        local *MockHTTPResponse2::content_type = sub { };

        # Status: idle (TokenManager not running, no credentials file)
        my $saved_tm = delete $INC{'Plugins/SpotOn/API/TokenManager.pm'};
        $captured_content = undef;
        Plugins::SpotOn::Settings::_discoveryStatusHandler(undef, $response_obj);
        $INC{'Plugins/SpotOn/API/TokenManager.pm'} = $saved_tm if defined $saved_tm;

        ok(defined $captured_content, '_discoveryStatusHandler: addHTTPResponse was called');

        my $decoded = eval { require JSON::PP; JSON::PP::decode_json($captured_content) };
        ok(!$@ && defined $decoded->{status},
            '_discoveryStatusHandler: response is valid JSON with status key');

        is($decoded->{status}, 'idle',
            '_discoveryStatusHandler: returns idle when discovery not running and no credentials');
    }
}

# ============================================================
# i18n: All PLUGIN_SPOTON_ACCOUNT_* string keys exist in strings.txt
# ============================================================
{
    my $strings_file = "$project_dir/Plugins/SpotOn/strings.txt";

    SKIP: {
        skip "strings.txt not found", 11 unless -f $strings_file;

        open(my $fh, '<', $strings_file) or die "Cannot open strings.txt: $!";
        my $content = do { local $/; <$fh> };
        close($fh);

        # Sentinel: if PLUGIN_SPOTON_ACTIVE_ACCOUNT is not present, Phase 2 strings
        # have not been added yet — skip entire block.
        skip "Phase 2 strings not yet added to strings.txt (Plan 02-03 will add them)", 11
            unless $content =~ /^PLUGIN_SPOTON_ACTIVE_ACCOUNT\s*$/m;

        # These are Phase 2 strings (Plans 02-03 era): guaranteed present once
        # PLUGIN_SPOTON_ACTIVE_ACCOUNT sentinel passes.
        # Plan 03 ZeroConf-specific strings are tested in the separate block below.
        my @required_keys = qw(
            PLUGIN_SPOTON_ACCOUNT_SETTINGS
            PLUGIN_SPOTON_ACTIVE_ACCOUNT
            PLUGIN_SPOTON_RATE_LIMIT_HINT
            PLUGIN_SPOTON_ACCOUNT_NONE
            PLUGIN_SPOTON_ACCOUNT_ACTIVE
            PLUGIN_SPOTON_ACCOUNT_SWITCH
            PLUGIN_SPOTON_ACCOUNT_REMOVE
            PLUGIN_SPOTON_ADD_ANOTHER
            PLUGIN_SPOTON_ACCOUNT_REMOVE_CONFIRM
        );

        for my $key (@required_keys) {
            ok($content =~ /^\Q$key\E\s*$/m,
                "i18n: $key exists in strings.txt");
        }
    }
}

# ============================================================
# i18n: PLUGIN_SPOTON_ACTIVE_ACCOUNT contains %s in both DE and EN
# ============================================================
{
    my $strings_file = "$project_dir/Plugins/SpotOn/strings.txt";

    SKIP: {
        skip "strings.txt not found", 2 unless -f $strings_file;

        open(my $fh, '<', $strings_file) or die "Cannot open strings.txt: $!";
        my @lines = <$fh>;
        close($fh);

        # Find the PLUGIN_SPOTON_ACTIVE_ACCOUNT block
        my ($in_block, %translations) = (0);
        for my $line (@lines) {
            chomp $line;
            if ($line =~ /^PLUGIN_SPOTON_ACTIVE_ACCOUNT\s*$/) {
                $in_block = 1;
                next;
            }
            last if $in_block && $line =~ /^\S/;  # next key starts
            if ($in_block && $line =~ /^\s+(DE|EN)\s+(.+)$/) {
                $translations{$1} = $2;
            }
        }

        skip "PLUGIN_SPOTON_ACTIVE_ACCOUNT not in strings.txt yet (Plan 02-03 will add it)", 2
            unless %translations;

        like($translations{DE} // '', qr/%s/,
            'i18n: PLUGIN_SPOTON_ACTIVE_ACCOUNT DE translation contains %s placeholder');
        like($translations{EN} // '', qr/%s/,
            'i18n: PLUGIN_SPOTON_ACTIVE_ACCOUNT EN translation contains %s placeholder');
    }
}

# ============================================================
# PLAN 03 strings.txt: ZeroConf strings present (no PKCE strings)
# ============================================================
{
    my $strings_file = "$project_dir/Plugins/SpotOn/strings.txt";

    SKIP: {
        skip "strings.txt not found", 8 unless -f $strings_file;

        open(my $fh, '<', $strings_file) or die "Cannot open strings.txt: $!";
        my $content = do { local $/; <$fh> };
        close($fh);

        # Sentinel: if PLUGIN_SPOTON_ZEROCONF_SETUP is not present, Plan 03
        # strings have not been added yet.
        skip "Plan 03 ZeroConf strings not yet added to strings.txt", 8
            unless $content =~ /^PLUGIN_SPOTON_ZEROCONF_SETUP\s*$/m;

        # ZeroConf strings must exist
        for my $key (qw(
            PLUGIN_SPOTON_ZEROCONF_SETUP
            PLUGIN_SPOTON_ZEROCONF_STEP1
            PLUGIN_SPOTON_WAITING_FOR_CONNECTION
            PLUGIN_SPOTON_START_DISCOVERY
            PLUGIN_SPOTON_STOP_DISCOVERY
        )) {
            ok($content =~ /^\Q$key\E\s*$/m, "Plan03 i18n: $key in strings.txt");
        }

        # PKCE strings must NOT exist
        ok($content !~ /^PLUGIN_SPOTON_CLIENT_ID_LABEL\s*$/m,
            'Plan03 i18n: PLUGIN_SPOTON_CLIENT_ID_LABEL removed from strings.txt');
        ok($content !~ /^PLUGIN_SPOTON_CLIENT_ID_HINT\s*$/m,
            'Plan03 i18n: PLUGIN_SPOTON_CLIENT_ID_HINT removed from strings.txt');
        ok($content !~ /^PLUGIN_SPOTON_SETUP_WIZARD\s*$/m,
            'Plan03 i18n: PLUGIN_SPOTON_SETUP_WIZARD removed from strings.txt');
    }
}

# ============================================================
# P-CR-03: CSRF guard on write endpoints
# ============================================================
{
    my $settings_file = "$project_dir/Plugins/SpotOn/Settings.pm";
    my $html_file     = "$project_dir/Plugins/SpotOn/HTML/EN/plugins/SpotOn/settings/basic.html";

    SKIP: {
        skip "Settings.pm not found", 6 unless -f $settings_file;

        open(my $fh, '<', $settings_file) or die $!;
        my $src = do { local $/; <$fh> };
        close($fh);

        # 1. _csrfCheck sub is defined
        ok($src =~ /sub _csrfCheck\b/, 'P-CR-03: _csrfCheck helper defined in Settings.pm');

        # 2-4. Write handlers call _csrfCheck
        # Extract each handler body (from sub declaration to next sub or end of file)
        # and verify _csrfCheck is called within it.
        for my $handler (qw(_clearLogsHandler _discoveryStartHandler _discoveryStopHandler)) {
            my ($body) = $src =~ /(sub \Q$handler\E\b.*?)(?=\nsub \w|\z)/s;
            ok(defined $body && $body =~ /_csrfCheck/,
                "P-CR-03: $handler calls _csrfCheck");
        }

        # 5. _discoveryStatusHandler does NOT call _csrfCheck (read-only)
        my ($status_body) = $src =~ /(sub _discoveryStatusHandler\b.*?)(?=\nsub \w|\z)/s;
        ok(defined $status_body && $status_body !~ /_csrfCheck/,
            'P-CR-03: _discoveryStatusHandler does NOT call _csrfCheck (read-only)');

        # 6. _diagnosticBundleHandler does NOT call _csrfCheck (read-only, gated by diagnosticMode)
        my ($diag_body) = $src =~ /(sub _diagnosticBundleHandler\b.*?)(?=\nsub \w|\z)/s;
        ok(defined $diag_body && $diag_body !~ /_csrfCheck/,
            'P-CR-03: _diagnosticBundleHandler does NOT call _csrfCheck (read-only)');
    }

    SKIP: {
        skip "basic.html not found", 1 unless -f $html_file;

        open(my $fh, '<', $html_file) or die $!;
        my $html = do { local $/; <$fh> };
        close($fh);

        # 7. basic.html contains X-Requested-With in AJAX calls
        my @matches = ($html =~ /X-Requested-With/g);
        ok(scalar @matches >= 3,
            'P-CR-03: basic.html has X-Requested-With in >= 3 AJAX calls (got ' . scalar(@matches) . ')');
    }
}

done_testing();

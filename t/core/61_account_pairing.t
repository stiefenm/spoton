#!/usr/bin/perl
# Phase 85 plan 10 Task 1 (D-05, D-22, D-04, D-06, D-21): account-less ZeroConf
# pairing. One pairing without any pre-existing account creates the account
# (id = first 8 hex of md5(credentials.json username), spotifyUserId = that
# username) AND installs its playback credentials.
#
# Stub header cloned from t/core/24_player_auth.t / t/core/16_credentials.t
# (write_stub, queue-based Timers, Proc::Background fake) plus: a log stub that
# records (level, message), per-client prefs, a SpClient->getDisplayName stub,
# a controllable clock (CORE::GLOBAL::time) and (85-18, CR-01) the REAL
# Login5 behind a capped Slim::Networking::SimpleAsyncHTTP stub: the D-06
# verdicts ("a revoked login reported by login5") come from login5 reply
# bytes in the librespot LoginResponse layout, not from an injected
# loginState (the old injection hid that Login5.pm read the wrong fields).
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use Digest::MD5 qw(md5_hex);
use File::Spec::Functions qw(catdir catfile);

# Controllable clock: Credentials.pm uses bare time() for the pairing window
# and the success hold. Must exist before the module is compiled.
BEGIN {
    *CORE::GLOBAL::time = sub () {
        return defined $main::NOW ? $main::NOW : CORE::time();
    };
}
our $NOW;

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

my $stub_dir  = tempdir(CLEANUP => 1);
my $cache_dir = tempdir(CLEANUP => 1);

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

# ---- Slim::Utils::Log: records (level, message) ----
write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
our @logged = ();      # [level, message]
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub addLogCategory { return bless {}, 'Slim::Utils::Log' }
sub logger { return bless {}, 'Slim::Utils::Log' }
sub info  { push @logged, ['info',  $_[1]] if defined $_[1]; }
sub warn  { push @logged, ['warn',  $_[1]] if defined $_[1]; }
sub error { push @logged, ['error', $_[1]] if defined $_[1]; }
sub debug { push @logged, ['debug', $_[1]] if defined $_[1]; }
sub is_info  { 1 }
sub is_debug { 0 }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# ---- Slim::Utils::Prefs: namespaces + per-client prefs ----
write_stub($stub_dir, 'Slim::Utils::Prefs', <<"END");
package Slim::Utils::Prefs;
my \%_store;
my \%_ns_store = ( server => { cachedir => '$cache_dir' } );
our \$savenow_calls = 0;

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
sub get {
    my (\$self, \$key) = \@_;
    return \$_ns_store{ \$self->{_ns} }{\$key} if exists \$_ns_store{ \$self->{_ns} };
    return \$_store{ \$self->{_ns} }{\$key};
}
sub set {
    my (\$self, \$key, \$val) = \@_;
    if (exists \$_ns_store{ \$self->{_ns} }) { \$_ns_store{ \$self->{_ns} }{\$key} = \$val; return; }
    \$_store{ \$self->{_ns} }{\$key} = \$val;
}
sub remove {
    my (\$self, \$key) = \@_;
    delete \$_store{ \$self->{_ns} }{\$key};
}
sub client {
    my (\$self, \$c) = \@_;
    return bless { _ns => \$self->{_ns} . '|client|' . (\$c // 'default') }, 'Slim::Utils::Prefs';
}
sub savenow { \$savenow_calls++ }
sub setChange { }
sub AUTOLOAD  { }
1;
END

write_stub($stub_dir, 'Slim::Player::Client', <<'END');
package Slim::Player::Client;
our @clients = ('cl1', 'cl2', 'cl3');
sub clients { return @clients }
1;
END

write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
my %_store;
sub new    { bless {}, shift }
sub get    { $_store{$_[1]} }
sub set    { $_store{$_[1]} = $_[2]; 1 }
sub remove { delete $_store{$_[1]} }
sub clear  { %_store = () }
1;
END

# Queue-based timers: pairing sits in 'waiting' across assertions.
write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
our @pending = ();
sub setTimer {
    my ($obj, $time, $cb, @args) = @_;
    push @pending, [$obj, $cb, \@args];
}
sub killTimers {
    my ($obj, $cb) = @_;
    @pending = grep { !($_->[0] == $obj && $_->[1] == $cb) } @pending;
}
sub fire_all {
    my @batch = @pending;
    @pending = ();
    for my $t (@batch) { $t->[1]->($t->[0], @{ $t->[2] }); }
}
sub reset_calls { @pending = () }
1;
END

write_stub($stub_dir, 'Time::HiRes', <<'END');
package Time::HiRes;
use POSIX qw();
sub time  { POSIX::floor(CORE::time()) + 0 }
sub sleep { CORE::sleep($_[1]) }
1;
END

write_stub($stub_dir, 'JSON::XS::VersionOneAndTwo', <<'END');
package JSON::XS::VersionOneAndTwo;
use parent 'Exporter';
our @EXPORT = qw(from_json to_json);
use JSON::PP ();
sub from_json { JSON::PP::decode_json($_[0]) }
sub to_json   { JSON::PP::encode_json($_[0]) }
1;
END

write_stub($stub_dir, 'Proc::Background', <<'END');
package Proc::Background;
our @spawns = ();
our $next_alive = 0;
our $new_dies = 0;
our $last_proc;
sub new {
    my $class = shift;
    my $opts  = shift;
    my @args  = @_;
    die "simulated spawn failure\n" if $new_dies;
    push @spawns, [@args];
    $last_proc = bless { alive => $next_alive, died => 0 }, $class;
    return $last_proc;
}
sub alive { return $_[0]->{alive} }
sub die   { $_[0]->{alive} = 0; $_[0]->{died} = 1; }
sub reset_stub { @spawns = (); $next_alive = 0; $new_dies = 0; $last_proc = undef; }
1;
END

my $fake_helper_path = "$cache_dir/fake-spoton";
write_stub($stub_dir, 'Plugins::SpotOn::Helper', <<"END");
package Plugins::SpotOn::Helper;
our \$fake_path = '$fake_helper_path';
our \%caps = ('token-login' => 1, 'token-env' => 1, 'discover-once' => 1);
sub get { return \$fake_path }
sub getCapability { my (\$class, \$key) = \@_; return \$caps{\$key}; }
sub reset_stub {
    \$fake_path = '$fake_helper_path';
    \%caps = ('token-login' => 1, 'token-env' => 1, 'discover-once' => 1);
}
1;
END

write_stub($stub_dir, 'Slim::Utils::Misc', <<'END');
package Slim::Utils::Misc;
our $library_name = 'Test Library';
sub getLibraryName { return $library_name }
1;
END

write_stub($stub_dir, 'Plugins::SpotOn::Unified::DaemonManager', <<'END');
package Plugins::SpotOn::Unified::DaemonManager;
our $schedule_init_calls = 0;
our @shutdown_calls = ();
sub scheduleInit { $schedule_init_calls++ }
sub shutdown     { shift; push @shutdown_calls, [@_] }
sub reset_calls  { $schedule_init_calls = 0; @shutdown_calls = () }
1;
END

# SpClient->getDisplayName (85-06): synchronous stub, answer configurable.
write_stub($stub_dir, 'Plugins::SpotOn::API::SpClient', <<'END');
package Plugins::SpotOn::API::SpClient;
our @display_calls = ();
our $answer;
sub getDisplayName {
    my ($class, $accountId, $cb) = @_;
    push @display_calls, $accountId;
    $cb->($answer);
}
sub reset_stub { @display_calls = (); $answer = undef; }
1;
END

# Login5 is the REAL module (85-18, CR-01). Only its HTTP transport is a stub:
# one scripted reply per POST, every request recorded, and a hard cap so a
# runaway retry loop shows as a failed assertion instead of a hang (Login5
# catches the die in its own dispatch eval).
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
our @requests = ();
our $reply_content = '';
our $cap = 20;
# WR-15: $hold = 1 parks the reply instead of delivering it, so a test can keep
# a mint in flight; release_held() delivers the parked replies in order.
our $hold = 0;
our @held = ();
sub new {
    my ($class, $success_cb, $error_cb, $opts) = @_;
    return bless { success_cb => $success_cb, error_cb => $error_cb }, $class;
}
sub post {
    my ($self, $url, @rest) = @_;
    push @requests, { url => $url, body => $rest[-1] };
    die "request cap exceeded\n" if @requests > $cap;
    my $resp = bless { _content => $reply_content }, 'Slim::Networking::SimpleAsyncHTTP::Response';
    if ($hold) { push @held, [$self->{success_cb}, $resp]; return; }
    $self->{success_cb}->($resp);
}
# release_held($index, $content): deliver one parked reply (optionally with new content).
sub release_held {
    my ($index, $content) = @_;
    my $h = splice(@held, $index, 1) or return 0;
    $h->[1]{_content} = $content if defined $content;
    $h->[0]->($h->[1]);
    return 1;
}
sub reset_stub { @requests = (); $reply_content = ''; $hold = 0; @held = (); }
package Slim::Networking::SimpleAsyncHTTP::Response;
sub content { $_[0]->{_content} }
sub code    { 200 }
1;
END

BEGIN {
    no warnings 'redefine';
    *main::TRANSCODING = sub () { 0 };
    *main::WEBUI       = sub () { 0 };
    *main::SCANNER     = sub () { 0 };
    *main::INFOLOG     = sub () { 1 };
    *main::ISWINDOWS   = sub () { 0 };
    *main::ISMAC       = sub () { 0 };
    *main::PERFMON     = sub () { 0 };
}
BEGIN {
    package Plugins::SpotOn::Plugin;
    use constant SPOTON_CACHE_VERSION => 4;
}

unshift @INC, $stub_dir, $project_dir;

require Slim::Utils::Prefs;   Slim::Utils::Prefs->import();
require Slim::Utils::Log;     Slim::Utils::Log->import();
require Slim::Utils::Timers;
require Slim::Utils::Cache;
require Proc::Background;
require Plugins::SpotOn::Helper;
require Plugins::SpotOn::Unified::DaemonManager;
require Plugins::SpotOn::API::SpClient;
require Slim::Networking::SimpleAsyncHTTP;
require Plugins::SpotOn::API::ProtobufLite;
require Plugins::SpotOn::API::Login5;
require Slim::Player::Client;
require JSON::PP;

require_ok('Plugins::SpotOn::API::Credentials')
    or BAIL_OUT("Failed to load Plugins::SpotOn::API::Credentials");
require_ok('Plugins::SpotOn::API::TokenManager')
    or BAIL_OUT("Failed to load Plugins::SpotOn::API::TokenManager");

my $CREDS = Plugins::SpotOn::API::Credentials::;
my $TM    = Plugins::SpotOn::API::TokenManager::;
my $prefs = preferences('plugin.spoton');

# ---- helpers ----
sub id_for       { substr(md5_hex($_[0]), 0, 8) }
sub account_dir  { catdir($cache_dir, 'spoton', $_[0]) }
sub live_file    { catfile(account_dir($_[0]), 'credentials.json') }
sub pairing_dir  { catdir($cache_dir, 'spoton', 'pairing-tmp') }
sub staged_file  { catfile(pairing_dir(), 'credentials.json') }

sub write_creds {
    my ($dir, $data) = @_;
    make_path($dir) unless -d $dir;
    my $file = catfile($dir, 'credentials.json');
    open(my $fh, '>', $file) or die "write_creds: $!";
    print $fh (ref $data ? JSON::PP::encode_json($data) : $data);
    close($fh);
    return $file;
}
sub slurp { open(my $fh, '<', $_[0]) or die "slurp: $!"; local $/; my $c = <$fh>; close($fh); $c }

sub reset_all {
    $main::NOW = 1_800_000_000;
    Proc::Background::reset_stub();
    Plugins::SpotOn::Helper::reset_stub();
    Plugins::SpotOn::Unified::DaemonManager::reset_calls();
    Plugins::SpotOn::API::SpClient::reset_stub();
    Plugins::SpotOn::API::Login5->reset;
    Slim::Networking::SimpleAsyncHTTP::reset_stub();
    Slim::Utils::Timers::reset_calls();
    Slim::Utils::Cache->new->clear;     # playback-auth flags are persistent -- never leak across cases
    $CREDS->cancelPairing();
    $prefs->set('accounts', {});
    $prefs->set('activeAccount', '');
    for my $c (@Slim::Player::Client::clients) { $prefs->client($c)->remove('activeAccount'); }
    @Slim::Utils::Log::logged = ();
}

# One full pairing round: start, helper writes the staged file, helper exits,
# the poll loop installs. Returns pairingStatus().
sub pair_as {
    my ($creds) = @_;
    $Proc::Background::next_alive = 1;
    my ($ok, $reason) = $CREDS->startPairing();
    return { state => 'start_failed:' . ($reason // 'undef') } unless $ok;
    write_creds(pairing_dir(), $creds);
    $Proc::Background::last_proc->{alive} = 0;
    Slim::Utils::Timers::fire_all();
    return $CREDS->pairingStatus();
}

# ---- login5 wire fixtures (85-18, CR-01) ----
# LoginResponse layout (librespot login5.proto, pinned commit 19959512, as
# tools/spclient-smoke.pl:672-678 cites it):
#   LoginResponse{ ok = 1, error = 2, challenges = 3, login_context = 5 }
#   LoginError { UNKNOWN_ERROR=0, INVALID_CREDENTIALS=1, BAD_REQUEST=2, ... }
# INVALID_CREDENTIALS = LoginResponse.error (response field 2, varint) = 1.
my $L5_INVALID_CREDENTIALS = Plugins::SpotOn::API::ProtobufLite::encode_field(2, 0, 1);
# Control: BAD_REQUEST = LoginResponse.error (field 2, varint) = 2. Never a
# revoked login.
my $L5_BAD_REQUEST = Plugins::SpotOn::API::ProtobufLite::encode_field(2, 0, 2);

# login5_reply($accountId, $bytes): the real Login5->getToken for the account,
# answered with $bytes by the stubbed transport. Returns
# { token, reason, detail, posts, died }.
sub login5_reply {
    my ($accountId, $bytes) = @_;
    no warnings 'once';   # the stub package is written to disk, not compiled with this file
    Slim::Networking::SimpleAsyncHTTP::reset_stub();
    $Slim::Networking::SimpleAsyncHTTP::reply_content = $bytes;
    my @args;
    my $ok = eval { Plugins::SpotOn::API::Login5->getToken($accountId, sub { @args = @_ }); 1 };
    return {
        token  => $args[0],
        reason => $args[1],
        detail => $args[2],
        posts  => scalar(@Slim::Networking::SimpleAsyncHTTP::requests),
        died   => $ok ? undef : $@,
    };
}

# An existing, usable account (credentials file + prefs entry).
sub seed_account {
    my ($username, %extra) = @_;
    my $id = id_for($username);
    write_creds(account_dir($id), { username => $username, auth_type => 1, auth_data => 'T1JJRw==' });
    my $accounts = $prefs->get('accounts') || {};
    $accounts->{$id} = { displayName => $username, spotifyUserId => $username,
                         playbackCredSource => 'zeroconf', %extra };
    $prefs->set('accounts', $accounts);
    return $id;
}

# ============================================================
# 1. zero accounts: spawn contract
# ============================================================
{
    reset_all();
    $Proc::Background::next_alive = 1;
    my ($ok, $reason) = $CREDS->startPairing();
    is($ok, 1, 'startPairing without any account returns 1');
    is($reason, undef, 'startPairing without any account has no refusal reason');
    my @args = @{ $Proc::Background::spawns[0] || [] };
    my ($ci) = grep { $args[$_] eq '--cache' } 0 .. $#args;
    is($args[$ci + 1], pairing_dir(),
        'spawn --cache is <cachedir>/spoton/pairing-tmp (account-less staging dir)') if defined $ci;
    ok(defined $ci, 'spawn args carry --cache') unless defined $ci;
    ok((grep { $_ eq '--discover-once' } @args), 'spawn args carry --discover-once');
    ok(-d pairing_dir(), 'staging dir exists while waiting');
    SKIP: {
        skip 'mode assertion not meaningful on Windows', 1 if $^O eq 'MSWin32';
        is((stat(pairing_dir()))[2] & 07777, 0700, 'staging dir is mode 0700');
    }
    is($CREDS->pairingStatus()->{state}, 'waiting', 'state is waiting after start');
    $CREDS->cancelPairing();
}

# ============================================================
# 2. D-05/D-22: first pairing creates the account + installs credentials
# ============================================================
{
    reset_all();
    $Plugins::SpotOn::API::SpClient::answer = 'Alice Wonderland';
    my $id = id_for('alice_secret_name');
    my $st = pair_as({ username => 'alice_secret_name', auth_type => 1, auth_data => 'QUJDREVG' });

    is($st->{state}, 'success', 'pairing without a pre-existing account ends in state success');
    is($st->{accountId}, $id, 'pairingStatus reports the md5-prefix account id');
    my $acc = ($prefs->get('accounts') || {})->{$id};
    ok($acc, 'account entry created under id = first 8 hex of md5(username)');
    is($acc->{spotifyUserId}, 'alice_secret_name', 'spotifyUserId is the credentials.json username');
    is($acc->{playbackCredSource}, 'zeroconf', 'playbackCredSource is zeroconf');
    ok(-f live_file($id), 'credentials.json installed under the new account dir');
    SKIP: {
        skip 'mode assertion not meaningful on Windows', 2 if $^O eq 'MSWin32';
        is((stat(live_file($id)))[2] & 07777, 0600, 'installed credentials.json is mode 0600');
        is((stat(account_dir($id)))[2] & 07777, 0700, 'account dir is mode 0700');
    }
    ok(!-e staged_file() && !-d pairing_dir(), 'staging file and staging dir are gone after install');
    is($prefs->get('activeAccount'), $id, 'first account becomes the active account');
    is(scalar(@Plugins::SpotOn::API::SpClient::display_calls), 1, 'SpClient->getDisplayName called once');
    is($acc->{displayName}, 'Alice Wonderland', 'a non-empty getDisplayName answer replaces the display name');
    is($Plugins::SpotOn::Unified::DaemonManager::schedule_init_calls, 1, 'DaemonManager->scheduleInit called once');

    # W11: one summary line, WARN level, masked
    my @lines = grep { $_->[1] =~ /^Pairing: paired credentials installed for account / } @Slim::Utils::Log::logged;
    my $expected = 'Pairing: paired credentials installed for account ' . substr($id, 0, 4) . '****'
                 . ' (source zeroconf)';
    ok(@lines == 1 && $lines[0][0] eq 'warn' && $lines[0][1] eq $expected
        && $lines[0][1] !~ /alice_secret_name/ && $lines[0][1] !~ /QUJDREVG/,
        'install summary line at WARN, masked')
        or diag(join "\n", map { "[$_->[0]] $_->[1]" } @lines);
    ok(!(grep { $_->[1] =~ /alice_secret_name|QUJDREVG/ } @Slim::Utils::Log::logged),
        'no log line of the whole pairing contains the username or auth_data (T-85-15)');
}

# ============================================================
# 3. fallback display name = username
# ============================================================
{
    reset_all();
    my $id = id_for('carol');
    pair_as({ username => 'carol', auth_type => 1, auth_data => 'QUJD' });
    is((($prefs->get('accounts') || {})->{$id} || {})->{displayName}, 'carol',
        'display name falls back to the username when getDisplayName answers nothing');
}

# ============================================================
# 4. D-04: re-pair the same user refreshes the same id
# ============================================================
{
    reset_all();
    my $id = seed_account('alice', sp_dc => 'cookie-value');
    my $accounts = $prefs->get('accounts');
    $accounts->{$id}{displayName} = 'Alice Real';
    $prefs->set('accounts', $accounts);
    $prefs->set('activeAccount', $id);
    my $before = slurp(live_file($id));

    my $st = pair_as({ username => 'alice', auth_type => 1, auth_data => 'TkVXREFUQQ==' });
    my $acc = ($prefs->get('accounts') || {});
    is($st->{accountId}, $id, 're-pairing the same user yields the same account id');
    is(scalar(keys %$acc), 1, 're-pairing the same user does not add a second account');
    isnt(slurp(live_file($id)), $before, 're-pairing replaces the credentials file');
    is($acc->{$id}{displayName}, 'Alice Real', 're-pairing preserves the display name');
    is($acc->{$id}{sp_dc}, 'cookie-value', 're-pairing preserves sp_dc');
}

# ============================================================
# 5. D-04 / D-06: second user, active-switch rule
# ============================================================
{
    reset_all();
    my $a = seed_account('alice');
    my $bob = id_for('bob');
    $prefs->set('activeAccount', $a);
    $prefs->client('cl1')->set('activeAccount', $a);
    $prefs->client('cl2')->set('activeAccount', $a);
    $prefs->client('cl3')->set('activeAccount', 'ffffffff');

    pair_as({ username => 'bob', auth_type => 1, auth_data => 'QUJD' });
    is(scalar(keys %{ $prefs->get('accounts') }), 2, 'pairing a different user adds a second account');
    is($prefs->get('activeAccount'), $a, 'D-04: active account stays while its login is valid');
    is($prefs->client('cl1')->get('activeAccount'), $a, 'D-04: per-player activeAccount untouched while the login is valid');
}
{
    reset_all();
    my $a = seed_account('alice');
    my $bob = id_for('bob');
    $prefs->set('activeAccount', $a);
    $prefs->client('cl1')->set('activeAccount', $a);
    $prefs->client('cl2')->set('activeAccount', $a);
    $prefs->client('cl3')->set('activeAccount', 'ffffffff');
    $CREDS->markNeedsPlaybackAuth($a, 'credential_error');

    pair_as({ username => 'bob', auth_type => 1, auth_data => 'QUJD' });
    is($prefs->get('activeAccount'), $bob, 'D-06: needsPlaybackAuth active account is replaced by the new pairing');
    ok($prefs->client('cl1')->get('activeAccount') eq $bob && $prefs->client('cl2')->get('activeAccount') eq $bob,
        'D-06: every per-player activeAccount equal to the replaced one switches too');
    is($prefs->client('cl3')->get('activeAccount'), 'ffffffff',
        'D-06: a per-player activeAccount pointing elsewhere is left alone');
}
{
    reset_all();
    my $a = seed_account('alice');
    $prefs->set('activeAccount', $a);
    unlink live_file($a);
    pair_as({ username => 'bob', auth_type => 1, auth_data => 'QUJD' });
    is($prefs->get('activeAccount'), id_for('bob'), 'D-06: active account without a credentials file is replaced');
}
{
    reset_all();
    my $a = seed_account('alice');
    $prefs->set('activeAccount', $a);
    my $r = login5_reply($a, $L5_INVALID_CREDENTIALS);
    is($r->{posts}, 1, 'D-06 wire: an INVALID_CREDENTIALS reply costs exactly one login5 POST');
    is($r->{reason}, 'invalid_credentials', 'D-06 wire: LoginResponse.error = INVALID_CREDENTIALS (field 2 = 1) resolves invalid_credentials');
    is(Plugins::SpotOn::API::Login5->loginState($a), 'invalid_credentials',
        'D-06 wire: Login5->loginState is invalid_credentials after the reply (no injection)');
    is($TM->hasValidLogin($a), 0, 'D-06 wire: hasValidLogin is 0 after the reply (Home hint and _authRequiredItem condition)');
    pair_as({ username => 'bob', auth_type => 1, auth_data => 'QUJD' });
    is($prefs->get('activeAccount'), id_for('bob'), 'D-06 wire: a new pairing takes over after a login5 INVALID_CREDENTIALS reply');
}
{
    # The genuine login5 reply (85-18 Task 3): ONE request with the librespot client id, the account's
    # username and random auth_data was sent to login5.spotify.com by the smoke tool; the 2 bytes below
    # are what came back (spoton-messdaten/85-18-capture-261017-215357/out/login5-reply.bin).
    my $L5_CAPTURED_REPLY = pack('H*', '1001');
    reset_all();
    my $a = seed_account('alice');
    $prefs->set('activeAccount', $a);
    my $r = login5_reply($a, $L5_CAPTURED_REPLY);
    is($r->{reason}, 'invalid_credentials', 'D-06 wire (captured): the genuine reply resolves invalid_credentials');
    is(Plugins::SpotOn::API::Login5->loginState($a), 'invalid_credentials',
        'D-06 wire (captured): the genuine reply drives Login5->loginState to invalid_credentials');
    pair_as({ username => 'bob', auth_type => 1, auth_data => 'QUJD' });
    is($prefs->get('activeAccount'), id_for('bob'), 'D-06 wire (captured): a new pairing takes over after the genuine reply');
}
{
    # Control: BAD_REQUEST is not a revoked login, so no takeover.
    reset_all();
    my $a = seed_account('alice');
    $prefs->set('activeAccount', $a);
    my $r = login5_reply($a, $L5_BAD_REQUEST);
    is($r->{posts}, 1, 'D-06 wire (control): a BAD_REQUEST reply costs exactly one login5 POST');
    is($r->{reason}, 'mint_failed', 'D-06 wire (control): BAD_REQUEST (field 2 = 2) resolves plain mint_failed');
    is($TM->hasValidLogin($a), 1, 'D-06 wire (control): hasValidLogin stays 1 after a BAD_REQUEST reply');
    pair_as({ username => 'bob', auth_type => 1, auth_data => 'QUJD' });
    is($prefs->get('activeAccount'), $a, 'D-06 wire (control): a BAD_REQUEST reply does NOT let a new pairing replace the active account');
}

# ============================================================
# 6. TokenManager->hasValidLogin
# ============================================================
{
    reset_all();
    my $a = seed_account('alice');
    is($TM->hasValidLogin($a), 1, 'hasValidLogin: usable credentials, no flag, no Login5 verdict');
    $CREDS->markNeedsPlaybackAuth($a, 'credential_error');
    is($TM->hasValidLogin($a), 0, 'hasValidLogin: needsPlaybackAuth means no valid login');
    $CREDS->clearNeedsPlaybackAuth($a);
    login5_reply($a, $L5_INVALID_CREDENTIALS);
    is($TM->hasValidLogin($a), 0, 'D-06 wire: hasValidLogin 0 because a login5 INVALID_CREDENTIALS reply set the verdict');
    is($TM->hasValidLogin('deadbeef'), 0, 'hasValidLogin: unknown account has no valid login');
}

# ============================================================
# 6b. WR-02: credentials.json that is valid JSON but not an object
# ============================================================
{
    reset_all();
    my $a = seed_account('alice');
    write_creds(account_dir($a), '[1,2,3]');

    # Login5 is the real module; count callbacks to prove "exactly once".
    my @cb;
    Slim::Networking::SimpleAsyncHTTP::reset_stub();
    my $ok = eval { Plugins::SpotOn::API::Login5->getToken($a, sub { push @cb, [@_] }); 1 };
    ok($ok, 'WR-02: getToken does not die for a credentials.json holding a JSON array') or diag("died: $@");
    is(scalar(@cb), 1, 'WR-02: the getToken callback runs exactly once for the array file');
    ok(@cb && !defined $cb[0][0] && ($cb[0][1] // '') eq 'no_credentials',
        'WR-02: the array file resolves (undef, no_credentials)');
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, 'WR-02: the array file sends no login5 POST');

    my $mm = eval { $CREDS->accountMismatch($a) };
    ok(!$@ && defined $mm && $mm == 0, 'WR-02: accountMismatch returns 0 for the array file and does not die')
        or diag("mismatch=" . ($mm // 'undef') . " err=$@");
    my $hv = eval { $TM->hasValidLogin($a) };
    ok(!$@ && defined $hv && $hv == 0, 'WR-02: hasValidLogin returns 0 for the array file and does not die')
        or diag("hasValidLogin=" . ($hv // 'undef') . " err=$@");
    my $vc = eval { $CREDS->verifyCredentials($a) };
    ok(!$@ && !defined $vc, 'WR-02: verifyCredentials returns undef for the array file and does not die')
        or diag("err=$@");

    # A scalar and a string are not objects either.
    for my $raw ('"x"', '42') {
        write_creds(account_dir($a), $raw);
        my $r = eval { $CREDS->verifyCredentials($a) };
        ok(!$@ && !defined $r, "WR-02: verifyCredentials returns undef for $raw and does not die") or diag("err=$@");
    }

    # The slot was released: restore a valid file and the next mint sends one POST.
    write_creds(account_dir($a), { username => 'alice', auth_type => 1, auth_data => 'T1JJRw==' });
    my $r2 = login5_reply($a, $L5_BAD_REQUEST);
    is($r2->{posts}, 1, 'WR-02: the mint after the array file sends exactly one login5 POST (slot released)');
    ok(!$r2->{died}, 'WR-02: the mint after the array file does not die') or diag($r2->{died});
}

# ============================================================
# 7. invalid staged files
# ============================================================
for my $case (
    [ 'auth_type 0',      { username => 'dave', auth_type => 0, auth_data => 'QUJD' } ],
    [ 'empty username',   { username => '',     auth_type => 1, auth_data => 'QUJD' } ],
    [ 'empty auth_data',  { username => 'dave', auth_type => 1, auth_data => '' } ],
    [ 'oversized file',   { username => 'dave', auth_type => 1, auth_data => ('A' x 70000) } ],
    [ 'corrupt JSON',     '{ not json ]]]' ],
) {
    reset_all();
    my ($name, $creds) = @$case;
    my $st = pair_as($creds);
    ok($st->{state} eq 'failed' && !keys %{ $prefs->get('accounts') || {} }
        && !-d pairing_dir() && !-d account_dir(id_for('dave')),
        "invalid staged file ($name): state failed, no account, staging removed");
}

# ============================================================
# 8. T-85-14: a path-like username never becomes a path component
# ============================================================
{
    reset_all();
    my $evil = '../../evil';
    my $st = pair_as({ username => $evil, auth_type => 1, auth_data => 'QUJD' });
    ok($st->{state} eq 'success' && $st->{accountId} =~ /\A[0-9a-f]{8}\z/
        && -f live_file($st->{accountId}) && !-e catdir($cache_dir, 'evil') && !-e catdir($cache_dir, '..', 'evil'),
        'path-like username: id is a hex prefix, nothing written outside the account dir');
}

# ============================================================
# 9. state machine: already_running, just_paired, window
# ============================================================
{
    reset_all();
    $Proc::Background::next_alive = 1;
    $CREDS->startPairing();
    my ($ok, $reason) = $CREDS->startPairing();
    ok($ok == 0 && $reason eq 'already_running', 'startPairing while waiting resolves (0, already_running)');
    is(scalar(@Proc::Background::spawns), 1, 'no second spawn while waiting');
    $CREDS->cancelPairing();
}
{
    reset_all();
    pair_as({ username => 'erin', auth_type => 1, auth_data => 'QUJD' });
    $Proc::Background::next_alive = 1;
    my ($ok, $reason) = $CREDS->startPairing();
    ok($ok == 0 && $reason eq 'just_paired', 'startPairing right after a success resolves (0, just_paired)');
    $main::NOW += $CREDS->PAIRING_SUCCESS_HOLD_SECONDS + 1;
    my ($ok2) = $CREDS->startPairing();
    is($ok2, 1, 'startPairing after PAIRING_SUCCESS_HOLD_SECONDS is allowed again');
    $CREDS->cancelPairing();
}
{
    is($CREDS->PAIRING_WINDOW_SECONDS, 300, 'D-21: PAIRING_WINDOW_SECONDS is 300');
    cmp_ok($CREDS->PAIRING_WINDOW_SECONDS, '<', 900, 'D-21: the window is below the helper own 900 s self-timeout');
    is($CREDS->PAIRING_SUCCESS_HOLD_SECONDS, 10, 'PAIRING_SUCCESS_HOLD_SECONDS is 10');
}
{
    reset_all();
    $Proc::Background::next_alive = 1;
    $CREDS->startPairing();
    $main::NOW += 299;
    Slim::Utils::Timers::fire_all();
    is($CREDS->pairingStatus()->{state}, 'waiting', 'still waiting 299 s into the window');
    $main::NOW += 2;
    Slim::Utils::Timers::fire_all();
    is($CREDS->pairingStatus()->{state}, 'timeout', 'D-21: state timeout once the 300 s window has passed');
    is($Proc::Background::last_proc->{died}, 1, 'D-21: the helper is killed at the window end');
    ok(!-d pairing_dir(), 'D-21: staging removed at the window end');
}

{
    # 85-10 Task 3 (D-02): a pairing answers the migration hint -- the needsPairing
    # flag of the account it (re-)creates is cleared, other accounts keep theirs.
    reset_all();
    my $frank = id_for('frank');
    $prefs->set('accounts', { $frank => { displayName => 'Frank', needsPairing => 1 },
                              ffffffff => { displayName => 'Other', needsPairing => 1 } });
    pair_as({ username => 'frank', auth_type => 1, auth_data => 'QUJD' });
    my $accts = $prefs->get('accounts');
    ok(!$accts->{$frank}{needsPairing} && $accts->{ffffffff}{needsPairing},
        'pairing clears needsPairing on the paired account only (D-02 hint answered)');
}

# ============================================================
# 85-11 Task 2 (D-23, T-85-19): the __DISCOVER__ folder. A credentials.json
# dropped into <cachedir>/spoton/__DISCOVER__/ becomes an account on the next
# settings page load or plugin start (Docker/VLAN setups where mDNS cannot
# reach the phone). Fixed path only, symlinks refused, same validation as the
# pairing, never a remove_tree of an existing account directory.
# ============================================================
sub discover_dir  { catdir($cache_dir, 'spoton', '__DISCOVER__') }
sub discover_file { catfile(discover_dir(), 'credentials.json') }
sub intake        { my @r = eval { $CREDS->intakeDiscoverFolder() }; return $@ ? ('died', "$@") : @r }
sub clean_discover { File::Path::remove_tree(discover_dir()) if -e discover_dir() || -l discover_dir(); unlink discover_dir() if -l discover_dir(); }
sub warned        { scalar grep { $_->[0] eq 'warn' } @Slim::Utils::Log::logged }

is(eval { $CREDS->DISCOVER_SUBDIR } // 'undef', '__DISCOVER__', '__DISCOVER__: the folder name is the DISCOVER_SUBDIR constant');

{
    reset_all(); clean_discover();
    my @r = intake();
    is_deeply(\@r, [0, 'none'], '__DISCOVER__: no folder, nothing to import -> (0, none)');
}
{
    reset_all(); clean_discover();
    write_creds(discover_dir(), { username => 'gina', auth_type => 1, auth_data => 'QUJD' });
    my ($ok, $res) = intake();
    my $id = id_for('gina');
    ok($ok && $res eq $id, '__DISCOVER__: a valid credentials.json is imported -> (1, <account id>)');
    my $acct = ($prefs->get('accounts') || {})->{$id};
    ok($acct && $acct->{playbackCredSource} eq 'discover' && $acct->{spotifyUserId} eq 'gina',
        '__DISCOVER__: the account exists with playbackCredSource discover');
    ok(-f live_file($id), '__DISCOVER__: the credentials are installed in the account directory');
    ok(!-e discover_file(), '__DISCOVER__: the dropped file is consumed');
    ok(!-d discover_dir(), '__DISCOVER__: the empty folder is removed');
    my $mode = (stat live_file($id))[2] & 07777;
    is(sprintf('%04o', $mode), '0600', '__DISCOVER__: the installed credentials.json is chmod 0600 (T-85-19)');
}
for my $case (
    [ 'bad JSON',            '{ not json ]]]' ],
    [ 'auth_type != 1',      { username => 'hal', auth_type => 2, auth_data => 'QUJD' } ],
    [ 'oversized (> 64 KB)', { username => 'hal', auth_type => 1, auth_data => ('A' x 70000) } ],
    [ 'empty username',      { username => '', auth_type => 1, auth_data => 'QUJD' } ],
) {
    reset_all(); clean_discover();
    my ($name, $creds) = @$case;
    write_creds(discover_dir(), $creds);
    my ($ok, $res) = intake();
    ok(!$ok && $res eq 'invalid_credentials' && -f discover_file()
        && !keys %{ $prefs->get('accounts') || {} } && warned() >= 1,
        "__DISCOVER__: invalid file ($name) -> (0, invalid_credentials), file left in place, WARN logged, no account");
    unlink discover_file();
    rmdir discover_dir();
}
{
    # An existing account directory is refreshed in place: its other files and
    # its prefs entry (display name) survive. The old _autoSetupAccount removed
    # the whole directory -- that is the behaviour this guards against.
    reset_all(); clean_discover();
    my $id = id_for('ida');
    $prefs->set('accounts', { $id => { displayName => 'Ida Display', spotifyUserId => 'ida', playbackCredSource => 'zeroconf' } });
    write_creds(account_dir($id), { username => 'ida', auth_type => 1, auth_data => 'T0xE' });
    my $marker = catfile(account_dir($id), 'audio-cache-marker');
    open(my $mfh, '>', $marker) or die $!; print $mfh "x"; close($mfh);
    write_creds(discover_dir(), { username => 'ida', auth_type => 1, auth_data => 'TkVX' });
    my ($ok, $res) = intake();
    my $acct = ($prefs->get('accounts') || {})->{$id};
    ok($ok && $res eq $id && -f $marker && slurp(live_file($id)) =~ /TkVX/
        && $acct->{displayName} eq 'Ida Display' && $acct->{playbackCredSource} eq 'discover',
        '__DISCOVER__: an existing account directory is refreshed in place (files and display name survive)');
}
{
    # A symlink in place of credentials.json is refused and never followed.
    reset_all(); clean_discover();
    my $real = catdir($cache_dir, 'discover-real');
    my $realfile = write_creds($real, { username => 'jo', auth_type => 1, auth_data => 'QUJD' });
    make_path(discover_dir());
    symlink($realfile, discover_file()) or die "symlink: $!";
    my ($ok, $res) = intake();
    ok(!$ok && -l discover_file() && -f $realfile && !keys %{ $prefs->get('accounts') || {} } && warned() >= 1,
        '__DISCOVER__: a symlink in place of credentials.json is refused, left alone, WARN logged');
    unlink discover_file();
    rmdir discover_dir();
    unlink $realfile; rmdir $real;
}
{
    # A symlinked __DISCOVER__ folder is refused as well.
    reset_all(); clean_discover();
    my $real = catdir($cache_dir, 'discover-dir-real');
    write_creds($real, { username => 'kay', auth_type => 1, auth_data => 'QUJD' });
    make_path(catdir($cache_dir, 'spoton'));
    symlink($real, discover_dir()) or die "symlink: $!";
    my ($ok, $res) = intake();
    ok(!$ok && -l discover_dir() && -f catfile($real, 'credentials.json') && !keys %{ $prefs->get('accounts') || {} },
        '__DISCOVER__: a symlinked folder is refused and its target file is not consumed');
    unlink discover_dir();
    unlink catfile($real, 'credentials.json'); rmdir $real;
}
{
    # Idempotent: a second call after the import finds nothing and changes nothing.
    reset_all(); clean_discover();
    write_creds(discover_dir(), { username => 'lee', auth_type => 1, auth_data => 'QUJD' });
    my ($ok1) = intake();
    my @again = intake();
    ok($ok1 && "@again" eq '0 none', '__DISCOVER__: a second call right after the import is a no-op (0, none)');
}
{
    # No remove_tree in the intake path (the _autoSetupAccount defect, 6169a2b^).
    open(my $cfh, '<', "$project_dir/Plugins/SpotOn/API/Credentials.pm") or die $!;
    my $src = do { local $/; <$cfh> };
    close($cfh);
    my ($sub) = $src =~ /^(sub intakeDiscoverFolder\b.*?^\})/ms;
    ok(defined $sub && length $sub && $sub !~ /remove_tree|rmtree/,
        '__DISCOVER__: intakeDiscoverFolder never removes a directory tree');
}
{
    # Race guards (3fd1632 layer 2): the settings handler takes the intake
    # BEFORE any other handling, the plugin start before DaemonManager->init().
    open(my $sfh, '<', "$project_dir/Plugins/SpotOn/Settings.pm") or die $!;
    my $ssrc = do { local $/; <$sfh> };
    close($sfh);
    my ($handler) = $ssrc =~ /^sub handler \{(.*?)^\}/ms;
    my $intake = defined $handler ? index($handler, 'intakeDiscoverFolder') : -1;
    my $save   = defined $handler ? index($handler, '$paramRef->{saveSettings}') : -1;
    ok($intake >= 0 && $save > $intake,
        '__DISCOVER__: Settings handler calls intakeDiscoverFolder before any saveSettings handling');

    open(my $pfh, '<', "$project_dir/Plugins/SpotOn/Plugin.pm") or die $!;
    my $psrc = do { local $/; <$pfh> };
    close($pfh);
    my ($start) = $psrc =~ /^sub _startUnifiedDaemons \{(.*?)^\}/ms;
    my $pi  = defined $start ? index($start, 'intakeDiscoverFolder') : -1;
    my $mig = defined $start ? index($start, "get('authChainMigrated')") : -1;
    my $ini = defined $start ? rindex($start, 'DaemonManager->init()') : -1;
    ok($pi > $mig && $mig >= 0 && $ini > $pi,
        '__DISCOVER__: plugin start calls intakeDiscoverFolder after the auth chain migration and before DaemonManager->init()');
}

# ============================================================
# 8b. WR-10: a stale login5 verdict dies with the credentials it judged
# ============================================================
# Two entry points: installAccountCredentials (re-pairing the same user, same
# id) and TokenManager->removeAccount (remove, then pair the same user again).
{
    reset_all();
    my $a = seed_account('alice');
    $prefs->set('activeAccount', $a);
    login5_reply($a, $L5_INVALID_CREDENTIALS);
    is(Plugins::SpotOn::API::Login5->loginState($a), 'invalid_credentials', 'WR-10 setup: the account carries an invalid_credentials verdict');
    Slim::Utils::Cache->new->set("spoton_login5_token_$a", 'stale-token', 3000);

    my $st = pair_as({ username => 'alice', auth_type => 1, auth_data => 'QUJD' });
    is($st->{state}, 'success', 'WR-10 (installAccountCredentials): re-pairing the same user succeeds');
    is($st->{accountId}, $a, 'WR-10 (installAccountCredentials): re-pairing the same user keeps the account id');
    is(Plugins::SpotOn::API::Login5->loginState($a), undef,
        'WR-10 (installAccountCredentials): the old invalid_credentials verdict is gone after the re-pairing');
    is($TM->hasValidLogin($a), 1, 'WR-10 (installAccountCredentials): hasValidLogin is 1 again with the fresh credentials');
    ok(!defined Slim::Utils::Cache->new->get("spoton_login5_token_$a"),
        'WR-10 (installAccountCredentials): the cached token minted with the old credentials is dropped');

    $main::NOW += 600;    # past the just_paired replay guard
    my $bst = pair_as({ username => 'bob', auth_type => 1, auth_data => 'QUJD' });
    is($bst->{state}, 'success', 'WR-10 (installAccountCredentials): the second pairing itself succeeds');
    is($prefs->get('activeAccount'), $a, 'WR-10 (installAccountCredentials): a SECOND pairing no longer takes the active slot from the re-paired account');
}
{
    reset_all();
    my $a = seed_account('alice');
    $prefs->set('activeAccount', $a);
    login5_reply($a, $L5_INVALID_CREDENTIALS);
    Slim::Utils::Cache->new->set("spoton_login5_token_$a", 'stale-token', 3000);
    $TM->removeAccount($a);
    is(Plugins::SpotOn::API::Login5->loginState($a), undef,
        'WR-10 (removeAccount): removing the account drops its invalid_credentials verdict');
    ok(!defined Slim::Utils::Cache->new->get("spoton_login5_token_$a"),
        'WR-10 (removeAccount): the cached token of the removed account is dropped');

    $prefs->set('activeAccount', '');
    pair_as({ username => 'alice', auth_type => 1, auth_data => 'QUJD' });
    is($TM->hasValidLogin($a), 1, 'WR-10 (removeAccount): pairing the same user again after the removal has a valid login');
    $main::NOW += 600;    # past the just_paired replay guard
    my $bst = pair_as({ username => 'bob', auth_type => 1, auth_data => 'QUJD' });
    is($bst->{state}, 'success', 'WR-10 (removeAccount): the second pairing itself succeeds');
    is($prefs->get('activeAccount'), $a, 'WR-10 (removeAccount): the second pairing does not take the slot from the re-added account');
}

# ============================================================
# 8c. WR-15: a mint of the OLD credentials still in flight when the account is
# re-paired must neither record a verdict nor damp, and new callers must not
# coalesce onto it.
# ============================================================
{
    reset_all();
    no warnings 'once';
    my $L5 = 'Plugins::SpotOn::API::Login5';
    my $a  = seed_account('alice');
    $prefs->set('activeAccount', $a);
    my $login_ok = Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2,
        Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, 'n' x 100)
        . Plugins::SpotOn::API::ProtobufLite::encode_field(4, 0, 3600));

    # old mint parked in flight (built from the ORIG credentials)
    $Slim::Networking::SimpleAsyncHTTP::hold = 1;
    my @old;
    $L5->getToken($a, sub { @old = @_ });
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 1, 'WR-15 setup: the old mint is in flight');
    like($Slim::Networking::SimpleAsyncHTTP::requests[0]{body}, qr/ORIG/, 'WR-15 setup: the old mint carries the old credentials');

    my $st = pair_as({ username => 'alice', auth_type => 1, auth_data => 'QUJD' });
    is($st->{state}, 'success', 'WR-15 setup: re-pairing the same user succeeds while the old mint is in flight');

    # a getToken after the re-pairing starts its own mint with the NEW credentials
    my @new;
    $L5->getToken($a, sub { @new = @_ });
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 2,
        'WR-15: a getToken after the re-pairing does not coalesce onto the old mint (own POST)');
    like($Slim::Networking::SimpleAsyncHTTP::requests[1]{body}, qr/ABC/, 'WR-15: the new mint carries the new credentials');
    unlike($Slim::Networking::SimpleAsyncHTTP::requests[1]{body}, qr/ORIG/, 'WR-15: and not the old ones');

    # the old mint now resolves with INVALID_CREDENTIALS (index 0 = the old one)
    Slim::Networking::SimpleAsyncHTTP::release_held(0, $L5_INVALID_CREDENTIALS);
    is($old[1], 'invalid_credentials', 'WR-15: the old mint\'s own callers still get its answer (queue drained)');
    is($L5->loginState($a), undef, 'WR-15: the stale invalid_credentials verdict is NOT recorded');
    is($TM->hasValidLogin($a), 1, 'WR-15: hasValidLogin stays 1 for the freshly paired credentials');

    # the new mint resolves OK
    Slim::Networking::SimpleAsyncHTTP::release_held(0, $login_ok);
    ok($new[0], 'WR-15: the new mint delivers a token to the new caller');
    is($L5->loginState($a), 'ok', 'WR-15: the new mint records ok');

    # the stale answer did not damp: after the cache is dropped the next getToken POSTs
    Slim::Utils::Cache->new->remove("spoton_login5_token_$a");
    $Slim::Networking::SimpleAsyncHTTP::hold = 0;
    $Slim::Networking::SimpleAsyncHTTP::reply_content = $login_ok;
    my @after;
    $L5->getToken($a, sub { @after = @_ });
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 3, 'WR-15: the stale failure did not damp the account (next getToken POSTs)');
    ok($after[0], 'WR-15: and mints a token');
}
{
    # same ordering, old mint resolving AFTER the new one: it must not overwrite the new state
    reset_all();
    no warnings 'once';
    my $L5 = 'Plugins::SpotOn::API::Login5';
    my $a  = seed_account('alice');
    $prefs->set('activeAccount', $a);
    my $login_ok = Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2,
        Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, 'n' x 100)
        . Plugins::SpotOn::API::ProtobufLite::encode_field(4, 0, 3600));
    $Slim::Networking::SimpleAsyncHTTP::hold = 1;
    $L5->getToken($a, sub { });
    pair_as({ username => 'alice', auth_type => 1, auth_data => 'QUJD' });
    my @new;
    $L5->getToken($a, sub { @new = @_ });
    Slim::Networking::SimpleAsyncHTTP::release_held(1, $login_ok);
    is($L5->loginState($a), 'ok', 'WR-15 (new first): the new mint records ok');
    Slim::Networking::SimpleAsyncHTTP::release_held(0, $L5_INVALID_CREDENTIALS);
    is($L5->loginState($a), 'ok', 'WR-15 (old last): the stale answer does not overwrite the new state');
    my @again;
    $Slim::Networking::SimpleAsyncHTTP::hold = 0;
    $L5->getToken($a, sub { @again = @_ });
    ok($again[0], 'WR-15 (old last): the account still serves a token (cache intact, no damping)');
}

# ============================================================
# 8d. WR-17: a mint of forgotten credentials that SUCCEEDS must not write its
# token into the cache (the write is skipped, never undone: a post-hoc remove
# would delete the NEW mint's token in the old-last ordering).
# ============================================================
{
    # removal: the token of the removed account never reaches the cache
    reset_all();
    no warnings 'once';
    my $L5 = 'Plugins::SpotOn::API::Login5';
    my $a  = seed_account('alice');
    $prefs->set('activeAccount', $a);
    my $ok_old = Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2,
        Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, 'o' x 100)
        . Plugins::SpotOn::API::ProtobufLite::encode_field(4, 0, 3600));

    $Slim::Networking::SimpleAsyncHTTP::hold = 1;
    my @old;
    $L5->getToken($a, sub { @old = @_ });
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 1, 'WR-17 setup: the mint is in flight');
    $TM->removeAccount($a);
    Slim::Networking::SimpleAsyncHTTP::release_held(0, $ok_old);
    is($old[0], 'o' x 100, 'WR-17 (removeAccount): the in-flight caller still receives the token it asked for');
    ok(!defined Slim::Utils::Cache->new->get("spoton_login5_token_$a"),
        'WR-17 (removeAccount): the stale token is NOT cached under the removed account id');
    is($L5->loginState($a), undef, 'WR-17 (removeAccount): and no state is recorded');
}
{
    # re-pair, old mint resolves OK LAST: the new mint's cached token survives
    reset_all();
    no warnings 'once';
    my $L5 = 'Plugins::SpotOn::API::Login5';
    my $a  = seed_account('alice');
    $prefs->set('activeAccount', $a);
    my $ok_old = Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2,
        Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, 'o' x 100)
        . Plugins::SpotOn::API::ProtobufLite::encode_field(4, 0, 3600));
    my $ok_new = Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2,
        Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, 'n' x 100)
        . Plugins::SpotOn::API::ProtobufLite::encode_field(4, 0, 3600));

    $Slim::Networking::SimpleAsyncHTTP::hold = 1;
    my @old;
    $L5->getToken($a, sub { @old = @_ });
    pair_as({ username => 'alice', auth_type => 1, auth_data => 'QUJD' });
    my @new;
    $L5->getToken($a, sub { @new = @_ });
    Slim::Networking::SimpleAsyncHTTP::release_held(1, $ok_new);
    is(Slim::Utils::Cache->new->get("spoton_login5_token_$a"), 'n' x 100, 'WR-17 (new first): the new mint caches its token');
    Slim::Networking::SimpleAsyncHTTP::release_held(0, $ok_old);
    is($old[0], 'o' x 100, 'WR-17 (old last): the old caller still receives its own token');
    is(Slim::Utils::Cache->new->get("spoton_login5_token_$a"), 'n' x 100,
        'WR-17 (old last): the stale token neither overwrites nor removes the new mint\'s cached token');
    is($L5->loginState($a), 'ok', 'WR-17 (old last): the state stays ok');
}
{
    # re-pair, old mint resolves OK FIRST: the stale token never lands in the cache
    reset_all();
    no warnings 'once';
    my $L5 = 'Plugins::SpotOn::API::Login5';
    my $a  = seed_account('alice');
    $prefs->set('activeAccount', $a);
    my $ok_old = Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2,
        Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, 'o' x 100)
        . Plugins::SpotOn::API::ProtobufLite::encode_field(4, 0, 3600));
    my $ok_new = Plugins::SpotOn::API::ProtobufLite::encode_field(1, 2,
        Plugins::SpotOn::API::ProtobufLite::encode_field(2, 2, 'n' x 100)
        . Plugins::SpotOn::API::ProtobufLite::encode_field(4, 0, 3600));

    $Slim::Networking::SimpleAsyncHTTP::hold = 1;
    $L5->getToken($a, sub { });
    pair_as({ username => 'alice', auth_type => 1, auth_data => 'QUJD' });
    my @new;
    $L5->getToken($a, sub { @new = @_ });
    Slim::Networking::SimpleAsyncHTTP::release_held(0, $ok_old);
    ok(!defined Slim::Utils::Cache->new->get("spoton_login5_token_$a"),
        'WR-17 (old first): the stale token is not cached while the new mint is still in flight');
    Slim::Networking::SimpleAsyncHTTP::release_held(0, $ok_new);
    is(Slim::Utils::Cache->new->get("spoton_login5_token_$a"), 'n' x 100, 'WR-17 (old first): the new mint then caches its own token');
}

# ============================================================
# 9. D-06 consumers read the same verdict (85-18, CR-01)
# ============================================================
# The wire tests above prove Login5->loginState and hasValidLogin; these pins
# prove the three places that SHOW the verdict read exactly those two values.
{
    sub _slurp_src { my ($rel) = @_; open(my $fh, '<', "$project_dir/$rel") or die "$rel: $!"; local $/; my $c = <$fh>; close($fh); return $c }
    my $psrc = _slurp_src('Plugins/SpotOn/Plugin.pm');

    my ($feed) = $psrc =~ /^(sub handleFeed \{.*?^\})/ms;
    ok(defined $feed && $feed =~ /TokenManager->hasValidLogin\(\$activeAccountId\)/,
        'D-06 wire (consumer pin): handleFeed shows the pairing hint through TokenManager->hasValidLogin($activeAccountId)');

    my ($auth) = $psrc =~ /^(sub _authRequiredItem \{.*?^\})/ms;
    ok(defined $auth && $auth =~ /TokenManager->hasValidLogin\(\$accountId\)/,
        'D-06 wire (consumer pin): _authRequiredItem decides through TokenManager->hasValidLogin($accountId)');

    my $ssrc = _slurp_src('Plugins/SpotOn/API/SpClient.pm');
    my ($snap) = $ssrc =~ /^(sub statusSnapshot \{.*?^\})/ms;
    ok(defined $snap && $snap =~ /\$login5\{\$id\}\s*=\s*Plugins::SpotOn::API::Login5->loginState\(\$id\)/,
        'D-06 wire (consumer pin): SpClient statusSnapshot fills its login5 map from Login5->loginState');

    my $html = _slurp_src('Plugins/SpotOn/HTML/EN/plugins/SpotOn/status.html');
    ok($html =~ /login\.state === 'invalid_credentials'\s*\)\s*\{[^}]*pair the account again/,
        'D-06 wire (consumer pin): status.html maps invalid_credentials to the "pair the account again" row');
}

done_testing();

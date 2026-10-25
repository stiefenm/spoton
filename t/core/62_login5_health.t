#!/usr/bin/perl
# 85-06 (D-05, RESEARCH P2): the login5 health tick.
#   * forced mint for the global active account, loginState per account
#   * display-name repair (displayName eq spotifyUserId) via SpClient->getDisplayName
#   * the "network recovered" edge (DaemonManager->networkRecovered) that the
#     PKCE refresh carries until 85-14
use strict;
use warnings;
no warnings 'once';   # cross-package stub var/sub access below (t/36 pattern)
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use Time::HiRes ();

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

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
# LMS module stubs (t/core/35_login5.t pattern)
# ============================================================
write_stub($stub_dir, 'Log::Log4perl::Logger', <<'END');
package Log::Log4perl::Logger;
sub new     { bless {}, shift }
sub AUTOLOAD { }
sub can     { 1 }
1;
END

write_stub($stub_dir, 'Log::Log4perl', <<'END');
package Log::Log4perl;
sub get_logger { return bless {}, 'Log::Log4perl::Logger' }
sub init { }
1;
END

# The logger records every call so the test can assert WARN lines (and that
# no secret ever reaches a log line).
write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
use parent 'Exporter';
our @EXPORT_OK = qw(logger);
our @calls = ();
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub addLogCategory { return bless {}, 'Slim::Utils::Log' }
sub logger { return bless {}, 'Slim::Utils::Log' }
sub info     { push @calls, ['info',  $_[1]] }
sub warn     { push @calls, ['warn',  $_[1]] }
sub error    { push @calls, ['error', $_[1]] }
sub debug    { push @calls, ['debug', $_[1]] }
sub is_info  { 0 }
sub is_debug { 0 }
sub AUTOLOAD { }
sub can { 1 }
1;
END

write_stub($stub_dir, 'Slim::Utils::Prefs', <<'END');
package Slim::Utils::Prefs;
my %_store;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::preferences"} = \&preferences;
}
sub preferences {
    my $ns = ($_[0] eq 'Slim::Utils::Prefs') ? $_[1] : $_[0];
    return bless { _ns => $ns }, 'Slim::Utils::Prefs';
}
sub init { }
sub get  { $_store{$_[0]->{_ns}}{$_[1]} }
sub set  { $_store{$_[0]->{_ns}}{$_[1]} = $_[2] }
sub client { return bless { _ns => $_[0]->{_ns} . '_client' }, 'Slim::Utils::Prefs' }
sub setChange { }
sub AUTOLOAD { }
1;
END

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

# Timers: record every setTimer/killTimers so the test can read the delay
# the tick re-arms with (absolute fire time minus now).
write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
our @set_calls  = ();
our @kill_calls = ();
sub setTimer   { push @set_calls,  [@_] }
sub killTimers { push @kill_calls, [@_] }
sub reset_calls { @set_calls = (); @kill_calls = () }
1;
END

# SimpleAsyncHTTP: one POST per mint. $auto_mode: success | error | none.
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
our @requests = ();
our $auto_mode = 'success';   # success | error | none
our $auto_response_content = '';
# What the 'error' mode reports. LMS's Async::HTTP sends every non-2xx status
# through the same error callback as a socket failure: $error is the status
# line ("429 Too Many Requests") and $response the HTTP::Response; a socket
# failure has an error text without a status and NO response.
our $error_text  = 'Connection timed out';
our $error_code  = 0;
our %error_headers = ();
# WR-14: undef = legacy (the response object is passed when $error_code is
# non-zero). 1/0 force it: LMS creates the response at the header line, so a
# socket error AFTER a 2xx header line carries a 200 response next to a
# status-less error text ("Error on HTTP socket: ...").
our $error_with_response = undef;
sub new {
    my ($class, $success_cb, $error_cb, $opts) = @_;
    return bless { success_cb => $success_cb, error_cb => $error_cb, opts => $opts || {} }, $class;
}
sub post {
    my ($self, $method_url, @rest) = @_;
    push @requests, { url => $method_url, success_cb => $self->{success_cb}, error_cb => $self->{error_cb} };
    if ($auto_mode eq 'success') {
        my $resp = bless { _content => $auto_response_content, _code => 200 },
            'Slim::Networking::SimpleAsyncHTTP::Response';
        $self->{success_cb}->($resp);
    }
    elsif ($auto_mode eq 'error') {
        my $resp = bless { _code => $error_code, _headers => { %error_headers } }, 'Slim::Networking::SimpleAsyncHTTP::Response';
        # LMS: ecb->($self, $error, $http->response); a socket failure has no response
        my $pass = defined $error_with_response ? $error_with_response : $error_code;
        $self->{error_cb}->($resp, $error_text, $pass ? $resp : undef);
    }
}
sub reset_requests {
    @requests = (); $auto_mode = 'success'; $auto_response_content = '';
    $error_text = 'Connection timed out'; $error_code = 0; %error_headers = ();
    $error_with_response = undef;
}
package Slim::Networking::SimpleAsyncHTTP::Response;
sub content { $_[0]->{_content} }
sub code    { $_[0]->{_code} }
sub header  { $_[0]->{_headers} ? $_[0]->{_headers}{$_[1]} : undef }
1;
END

# Credentials: per-account controllable verifyCredentials.
write_stub($stub_dir, 'Plugins::SpotOn::API::Credentials', <<'END');
package Plugins::SpotOn::API::Credentials;
our %creds_for = ();
sub verifyCredentials {
    my ($class, $accountId) = @_;
    return $creds_for{$accountId};
}
1;
END

# SpClient: only getDisplayName is reached from the tick; the answer per
# account is scripted, every call is counted.
write_stub($stub_dir, 'Plugins::SpotOn::API::SpClient', <<'END');
package Plugins::SpotOn::API::SpClient;
our @getDisplayName_calls = ();
our %name_for = ();
sub getDisplayName {
    my ($class, $accountId, $cb) = @_;
    push @getDisplayName_calls, $accountId;
    $cb->($name_for{$accountId});
}
sub reset_calls { @getDisplayName_calls = (); %name_for = () }
1;
END

# DaemonManager: counts networkRecovered; can be told to die.
write_stub($stub_dir, 'Plugins::SpotOn::Unified::DaemonManager', <<'END');
package Plugins::SpotOn::Unified::DaemonManager;
our $recovered = 0;
our $die = 0;
sub networkRecovered {
    $recovered++;
    die "boom from networkRecovered\n" if $die;
    return 0;
}
sub reset_calls { $recovered = 0; $die = 0 }
1;
END

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

BEGIN {
    package Plugins::SpotOn::Plugin;
    use constant SPOTON_CACHE_VERSION => 4;
}

unshift @INC, $stub_dir, $project_dir;

require_ok('Plugins::SpotOn::API::ProtobufLite')
    or BAIL_OUT('Failed to load ProtobufLite.pm');
*encode_field = \&Plugins::SpotOn::API::ProtobufLite::encode_field;

require_ok('Plugins::SpotOn::API::Login5')
    or BAIL_OUT('Failed to load Login5.pm');

# Stubs the tick reaches only at runtime: load them up front so reset_all can
# reach their package state.
for my $m (qw(Slim::Utils::Timers Plugins::SpotOn::API::Credentials Plugins::SpotOn::API::SpClient Plugins::SpotOn::Unified::DaemonManager)) {
    require_ok($m) or BAIL_OUT("Failed to load stub $m");
}

my $L5    = 'Plugins::SpotOn::API::Login5';
my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');

sub reset_all {
    Slim::Networking::SimpleAsyncHTTP::reset_requests();
    Slim::Utils::Cache->new()->clear();
    Slim::Utils::Timers::reset_calls();
    Plugins::SpotOn::API::SpClient::reset_calls();
    Plugins::SpotOn::Unified::DaemonManager::reset_calls();
    @Slim::Utils::Log::calls = ();
    %Plugins::SpotOn::API::Credentials::creds_for = ();
    $L5->reset();
    $prefs->set('activeAccount', '');
    $prefs->set('accounts', {});
}

sub login_ok_response {
    my $loginOk = encode_field(1, 2, 'testuser')
        . encode_field(2, 2, 'a' x 438)
        . encode_field(4, 0, 3600)
        . encode_field(99, 2, 'p' x 300);
    return encode_field(1, 2, $loginOk);
}

sub set_creds { $Plugins::SpotOn::API::Credentials::creds_for{$_[0]} = { username => "user-$_[0]", auth_data => 'dGVzdGRhdGE=' } }

# Runs one tick and reports whether it died, as a named check -- a missing
# healthTick shows as `not ok`, not as a dead script.
sub tick {
    my $ran = eval { $L5->healthTick; 1 };
    fail('healthTick runs without dying: ' . ($@ =~ s/\s+\z//r)) unless $ran;
    return $ran;
}

# loginState without dying on a missing method (a RED run must report not ok).
sub state_of {
    my ($id) = @_;
    my $v = eval { $L5->loginState($id) };
    return $@ ? 'DIED' : $v;
}

# Seconds until the most recent re-arm, or undef when none happened.
sub last_arm_delay {
    my @s = @Slim::Utils::Timers::set_calls;
    return undef unless @s;
    return $s[-1][1] - Time::HiRes::time();
}

# ============================================================
# Task 1: tick -> display name -> prefs (tracer, D-05)
# ============================================================
can_ok($L5, qw(healthTick loginState));

# Tick for the global active account is a forced mint: it bypasses a cached token.
{
    reset_all();
    set_creds('acct1');
    $prefs->set('activeAccount', 'acct1');
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = login_ok_response();
    Slim::Utils::Cache->new()->set('spoton_login5_token_acct1', 'cached-token', 3000);

    tick();
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 1, 'tick: forced mint sends one login5 POST despite a cached token');
    is(state_of('acct1'), 'ok', 'tick: loginState is ok after a successful mint');
    my $d = last_arm_delay();
    ok(defined $d && abs($d - 2700) < 5, 'tick: re-armed after HEALTH_TICK_SECONDS (2700) on success');
}

# Display-name repair: only accounts whose displayName still equals the user id.
{
    reset_all();
    set_creds('acct1');
    $prefs->set('activeAccount', 'acct1');
    $prefs->set('accounts', {
        acct1 => { displayName => 'sp-user-1', spotifyUserId => 'sp-user-1' },
        acct2 => { displayName => 'sp-user-2', spotifyUserId => 'sp-user-2' },
        acct3 => { displayName => 'Real Name', spotifyUserId => 'sp-user-3' },
        acct4 => { displayName => 'sp-user-4', spotifyUserId => 'sp-user-4' },
    });
    %Plugins::SpotOn::API::SpClient::name_for = (
        acct1 => 'Alice Example',
        acct2 => 'Bob Example',
        acct4 => undef,                # lookup failed / empty name
    );
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = login_ok_response();

    tick();
    my %seen; $seen{$_}++ for @Plugins::SpotOn::API::SpClient::getDisplayName_calls;
    is_deeply(\%seen, { acct1 => 1, acct2 => 1, acct4 => 1 },
        'repair: exactly one getDisplayName call per account whose displayName eq spotifyUserId (acct3 untouched)');
    my $accts = $prefs->get('accounts');
    is($accts->{acct1}{displayName}, 'Alice Example', 'repair: non-empty name stored as displayName (active account)');
    is($accts->{acct2}{displayName}, 'Bob Example',   'repair: non-empty name stored as displayName (other account)');
    is($accts->{acct3}{displayName}, 'Real Name',     'repair: an account with a real name is left alone');
    is($accts->{acct4}{displayName}, 'sp-user-4',     'repair: an undef answer leaves the prefs entry unchanged');
    is($accts->{acct1}{spotifyUserId}, 'sp-user-1',   'repair: spotifyUserId is never touched');
}

# A failed mint repairs nothing.
{
    reset_all();
    set_creds('acct1');
    $prefs->set('activeAccount', 'acct1');
    $prefs->set('accounts', { acct1 => { displayName => 'sp-user-1', spotifyUserId => 'sp-user-1' } });
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error';

    tick();
    is(scalar(@Plugins::SpotOn::API::SpClient::getDisplayName_calls), 0, 'repair: no getDisplayName call after a failed mint');
}

# Plugin.pm arms the first tick: killTimers then setTimer, +20 s, outside SCANNER.
{
    open(my $fh, '<', "$project_dir/Plugins/SpotOn/Plugin.pm") or die "cannot read Plugin.pm: $!";
    my $src = do { local $/; <$fh> };
    close($fh);
    ok(scalar($src =~ qr{killTimers\(\s*'Plugins::SpotOn::API::Login5'\s*,\s*\\&Plugins::SpotOn::API::Login5::healthTick\s*\)}),
        'Plugin.pm initPlugin: kills a pending health timer first');
    ok(scalar($src =~ qr{setTimer\(\s*'Plugins::SpotOn::API::Login5'\s*,\s*Time::HiRes::time\(\)\s*\+\s*20\s*,\s*\\&Plugins::SpotOn::API::Login5::healthTick}s),
        'Plugin.pm initPlugin: arms the first health tick at +20 s');
}

# WR-04: shutdownPlugin kills the health timer initPlugin arms.
{
    open(my $fh, '<', "$project_dir/Plugins/SpotOn/Plugin.pm") or die "cannot read Plugin.pm: $!";
    my $src = do { local $/; <$fh> };
    close($fh);
    my ($body) = $src =~ /^(sub shutdownPlugin \{.*?^\})/ms;
    $body //= '';
    $body =~ s/^\s*#.*$//mg;    # a comment must not satisfy the check
    ok(scalar($body =~ qr{killTimers\(\s*'Plugins::SpotOn::API::Login5'\s*,\s*\\&Plugins::SpotOn::API::Login5::healthTick\s*\)}),
        'WR-04: shutdownPlugin kills the Login5 health timer with the same timer self initPlugin uses');
    # WR-09: ordering -- the kill and the latch come before the first shutdown
    # call that is not eval-guarded (the behaviour itself is proven above).
    my ($killPos)    = $body =~ /killTimers\(\s*'Plugins::SpotOn::API::Login5'/g ? ($-[0]) : (undef);
    my ($latchPos)   = $body =~ /Login5->shutdown/ ? ($-[0]) : (undef);
    my ($connectPos) = $body =~ /Connect->shutdown/ ? ($-[0]) : (undef);
    ok(defined $killPos && defined $latchPos && defined $connectPos
        && $killPos < $connectPos && $latchPos < $connectPos,
        'WR-09: shutdownPlugin stops the Login5 tick before Connect->shutdown / DaemonManager->shutdown');
}

# WR-09: a tick whose mint is still in flight when the plugin shuts down must
# not re-arm itself from the mint callback. shutdown() latches the tick off and
# kills the pending timer; reset() (initPlugin of a reload) lifts the latch.
{
    reset_all();
    set_creds('acct1');
    $prefs->set('activeAccount', 'acct1');
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'none';

    tick();
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 1, 'WR-09: the tick has a mint in flight');
    is(scalar(@Slim::Utils::Timers::set_calls), 0, 'WR-09: no re-arm while the mint is outstanding');

    my $ok = eval { $L5->shutdown; 1 };
    ok($ok, 'WR-09: Login5->shutdown exists and runs' . ($ok ? '' : ": $@"));
    ok(scalar(grep { $_->[0] eq 'Plugins::SpotOn::API::Login5' } @Slim::Utils::Timers::kill_calls),
        'WR-09: shutdown kills the pending health timer');

    # the outstanding mint now completes after the shutdown
    my $resp = bless { _content => login_ok_response(), _code => 200 }, 'Slim::Networking::SimpleAsyncHTTP::Response';
    $Slim::Networking::SimpleAsyncHTTP::requests[-1]{success_cb}->($resp);
    is(scalar(@Slim::Utils::Timers::set_calls), 0, 'WR-09: the mint callback after shutdown does not re-arm the health tick');

    # error path of an in-flight mint behaves the same
    Slim::Utils::Timers::reset_calls();
    $L5->reset();
    tick();
    $L5->shutdown if $ok;
    $Slim::Networking::SimpleAsyncHTTP::requests[-1]{error_cb}->(bless({ _code => 0 }, 'Slim::Networking::SimpleAsyncHTTP::Response'), 'Connection timed out');
    is(scalar(@Slim::Utils::Timers::set_calls), 0, 'WR-09: a failing mint callback after shutdown does not re-arm either');

    # a reload (initPlugin -> reset) arms the tick again
    $L5->reset();
    Slim::Utils::Timers::reset_calls();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = login_ok_response();
    tick();
    is(scalar(@Slim::Utils::Timers::set_calls), 1, 'WR-09: after reset() (plugin reload) the tick arms again');
}

# ============================================================
# Task 2: network-recovered edge and login state (RESEARCH P2)
# ============================================================

# A mint whose HTTP error callback fires resolves (undef, 'mint_failed',
# {transient => 1}); a two-argument consumer keeps working.
{
    reset_all();
    set_creds('acctT');
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error';

    my @three;
    $L5->getToken('acctT', sub { @three = @_ });
    is($three[1], 'mint_failed', 'HTTP error: reason is mint_failed');
    is_deeply($three[2], { transient => 1 }, 'HTTP error: third argument marks the failure transient');

    my ($t2, $r2);
    $L5->getToken('acctT', sub { ($t2, $r2) = @_ });
    is($r2, 'mint_failed', 'HTTP error: a two-argument consumer still gets (undef, mint_failed)');
    is(state_of('acctT'), 'transient', 'loginState is transient after an HTTP error');
}

# WR-12: an HTTP status failure is a deterministic answer, not a network outage.
# LMS reports a non-2xx status through the same error callback as a socket
# failure ($error = the status line); only a failure of the request itself
# (no status) or of the server (5xx) is transient.
for my $case (
    [ '429 Too Many Requests',    429 ],
    [ '400 Bad Request',          400 ],
    [ '403 Forbidden',            403 ],
) {
    my ($line, $code) = @$case;
    reset_all();
    set_creds('acctH');
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error';
    $Slim::Networking::SimpleAsyncHTTP::error_text = $line;
    $Slim::Networking::SimpleAsyncHTTP::error_code = $code;

    my @three;
    $L5->getToken('acctH', sub { @three = @_ });
    is($three[1], 'mint_failed', "WR-12 $code: reason is mint_failed");
    ok(!($three[2] && $three[2]{transient}), "WR-12 $code: the failure is NOT marked transient");
    isnt(state_of('acctH'), 'transient', "WR-12 $code: loginState is not transient (no 'Temporary problem (network?)')");
}
{
    # error text WITHOUT a status prefix, status only on the response object
    reset_all();
    set_creds('acctH');
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error';
    $Slim::Networking::SimpleAsyncHTTP::error_text = 'Too Many Requests';
    $Slim::Networking::SimpleAsyncHTTP::error_code = 429;
    my @three;
    $L5->getToken('acctH', sub { @three = @_ });
    ok(!($three[2] && $three[2]{transient}), 'WR-12: a status carried only by the response object is not transient either');
}
{
    # health tick: 429 and 400 re-arm at 2700 s, no networkFailing edge, no retry log
    for my $case ([ '429 Too Many Requests', 429 ], [ '400 Bad Request', 400 ]) {
        my ($line, $code) = @$case;
        reset_all();
        set_creds('acct1');
        $prefs->set('activeAccount', 'acct1');
        $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error';
        $Slim::Networking::SimpleAsyncHTTP::error_text = $line;
        $Slim::Networking::SimpleAsyncHTTP::error_code = $code;
        tick();
        my $d = last_arm_delay();
        ok(defined $d && abs($d - 2700) < 5, "WR-12 tick $code: re-armed after HEALTH_TICK_SECONDS (2700), not the 60 s retry");
        ok(!scalar(grep { $_->[0] eq 'info' && $_->[1] =~ /transient health-tick failure/ } @Slim::Utils::Log::calls),
            "WR-12 tick $code: not logged as a transient failure");

        Slim::Utils::Timers::reset_calls();
        $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
        $Slim::Networking::SimpleAsyncHTTP::auto_response_content = login_ok_response();
        tick();
        is($Plugins::SpotOn::Unified::DaemonManager::recovered, 0,
            "WR-12 tick $code: the next success fires no networkRecovered edge (never a network outage)");
    }
}
{
    # a server failure (5xx) stays transient, like a socket failure
    reset_all();
    set_creds('acct1');
    $prefs->set('activeAccount', 'acct1');
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error';
    $Slim::Networking::SimpleAsyncHTTP::error_text = '503 Service Unavailable';
    $Slim::Networking::SimpleAsyncHTTP::error_code = 503;
    tick();
    my $d = last_arm_delay();
    ok(defined $d && abs($d - 60) < 5, 'WR-12: a 5xx stays transient and re-arms after 60 s');
    is(state_of('acct1'), 'transient', 'WR-12: a 5xx reports loginState transient');
}

# WR-14: a socket failure AFTER login5's 2xx header line. LMS creates the
# response object when the header line is read (Async/HTTP.pm:418); a later
# connection reset or body stall arrives as "Error on HTTP socket: ..." with
# that 200 response next to it. That is a network failure (transient), not a
# deterministic answer.
for my $case (
    [ 'Error on HTTP socket: Connection reset by peer', 200 ],
    [ 'Timed out waiting for data',                      200 ],
    [ 'Redirection limit exceeded',                      302 ],
) {
    my ($text, $code) = @$case;
    reset_all();
    set_creds('acctW');
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error';
    $Slim::Networking::SimpleAsyncHTTP::error_text = $text;
    $Slim::Networking::SimpleAsyncHTTP::error_code = $code;
    $Slim::Networking::SimpleAsyncHTTP::error_with_response = 1;

    my @three;
    $L5->getToken('acctW', sub { @three = @_ });
    is($three[1], 'mint_failed', "WR-14 $code '$text': reason is mint_failed");
    is_deeply($three[2], { transient => 1 }, "WR-14 $code '$text': a socket failure after a $code response is transient");
    is(state_of('acctW'), 'transient', "WR-14 $code '$text': loginState is transient");
}
{
    reset_all();
    set_creds('acct1');
    $prefs->set('activeAccount', 'acct1');
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error';
    $Slim::Networking::SimpleAsyncHTTP::error_text = 'Error on HTTP socket: Connection reset by peer';
    $Slim::Networking::SimpleAsyncHTTP::error_code = 200;
    $Slim::Networking::SimpleAsyncHTTP::error_with_response = 1;
    tick();
    my $d = last_arm_delay();
    ok(defined $d && abs($d - 60) < 5, 'WR-14 tick: a socket failure after a 200 header line re-arms after 60 s');
    is(state_of('acct1'), 'transient', 'WR-14 tick: loginState is transient');

    Slim::Utils::Timers::reset_calls();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = login_ok_response();
    tick();
    is($Plugins::SpotOn::Unified::DaemonManager::recovered, 1,
        'WR-14 tick: the next success fires the networkRecovered edge');
}

# WR-11: a failed mint is damped for user-driven requests. getToken is the one
# entry SpClient::_doRequest, Pathfinder::_attempt and Soloist::Quality::_request
# all mint through; a failed mint cached nothing, so every Browse click re-POSTed
# to login5 (and with WR-12 a login5 429 was not damped either).
my $TIME_SHIFT = 0;
{
    no warnings 'redefine';
    my $real_time = \&Time::HiRes::time;
    *Time::HiRes::time = sub { $real_time->() + $TIME_SHIFT };
}
sub posts { scalar(@Slim::Networking::SimpleAsyncHTTP::requests) }
{
    reset_all();
    $TIME_SHIFT = 0;
    set_creds('acctD');
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error';
    $Slim::Networking::SimpleAsyncHTTP::error_text = '429 Too Many Requests';
    $Slim::Networking::SimpleAsyncHTTP::error_code = 429;
    $Slim::Networking::SimpleAsyncHTTP::error_headers{'Retry-After'} = 120;

    my @first; $L5->getToken('acctD', sub { @first = @_ });
    is(posts(), 1, 'WR-11: the first getToken POSTs to login5');
    is($first[1], 'mint_failed', 'WR-11: and fails');

    my @second; $L5->getToken('acctD', sub { @second = @_ });
    is(posts(), 1, 'WR-11: a second getToken right after the failure sends NO new POST');
    is($second[1], 'mint_failed', 'WR-11: the damped getToken still resolves (undef, mint_failed)');
    ok(!defined $second[0], 'WR-11: the damped getToken carries no token');
    ok(!($second[2] && $second[2]{transient}), 'WR-11: a damped 429 is still not transient');

    $TIME_SHIFT = 100;
    my @third; $L5->getToken('acctD', sub { @third = @_ });
    is(posts(), 1, 'WR-11: still damped 100 s later (Retry-After 120 s honoured)');

    $TIME_SHIFT = 130;
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = login_ok_response();
    my @fourth; $L5->getToken('acctD', sub { @fourth = @_ });
    is(posts(), 2, 'WR-11: past the Retry-After window the next getToken POSTs again');
    ok($fourth[0], 'WR-11: and the mint succeeds');

    # success lifted the damping; the token is cached, a later failure damps anew
    $TIME_SHIFT = 0;
}
# WR-16: the 429 (and its retry window) travels in the failure detail, on the
# live answer and on the damped replay, so callers can say "rate limited".
{
    reset_all();
    $TIME_SHIFT = 0;
    set_creds('acctR');
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error';
    $Slim::Networking::SimpleAsyncHTTP::error_text = '429 Too Many Requests';
    $Slim::Networking::SimpleAsyncHTTP::error_code = 429;
    $Slim::Networking::SimpleAsyncHTTP::error_headers{'Retry-After'} = 120;

    my @live; $L5->getToken('acctR', sub { @live = @_ });
    is($live[1], 'mint_failed', 'WR-16: a login5 429 keeps the mint_failed reason');
    is(ref($live[2]), 'HASH', 'WR-16: the live 429 answer carries a detail hash');
    is($live[2] && $live[2]{code}, 429, 'WR-16: the live detail carries code 429');
    is($live[2] && $live[2]{retryAfter}, 120, 'WR-16: the live detail carries the parsed Retry-After');
    ok(!($live[2] && $live[2]{transient}), 'WR-16: and is still not transient');

    my @damped; $L5->getToken('acctR', sub { @damped = @_ });
    is(posts(), 1, 'WR-16: the second getToken is the damped replay (no new POST)');
    is($damped[2] && $damped[2]{code}, 429, 'WR-16: the damped replay carries code 429 as well');
    is($damped[2] && $damped[2]{retryAfter}, 120, 'WR-16: and the retry window');

    # no Retry-After header: the throttle default window is carried
    reset_all();
    set_creds('acctR');
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error';
    $Slim::Networking::SimpleAsyncHTTP::error_text = '429 Too Many Requests';
    $Slim::Networking::SimpleAsyncHTTP::error_code = 429;
    my @nh; $L5->getToken('acctR', sub { @nh = @_ });
    is($nh[2] && $nh[2]{code}, 429, 'WR-16: a 429 without Retry-After still carries code 429');
    is($nh[2] && $nh[2]{retryAfter}, 60, 'WR-16: and the 60 s default window');

    # a 400 is no rate limit
    reset_all();
    set_creds('acctR');
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error';
    $Slim::Networking::SimpleAsyncHTTP::error_text = '400 Bad Request';
    $Slim::Networking::SimpleAsyncHTTP::error_code = 400;
    my @bad; $L5->getToken('acctR', sub { @bad = @_ });
    ok(!($bad[2] && $bad[2]{code}), 'WR-16: a 400 carries no 429 code');
    $TIME_SHIFT = 0;
}
# WR-18: the protobuf throttle answers (LoginError TIMEOUT 4, TOO_MANY_ATTEMPTS
# 6, TRY_AGAIN_LATER 8) travel as the same throttle verdict as the HTTP 429:
# detail { throttled => 1 } on the live answer and the damped replay, state
# cleared (no transient channel, WR-12), the 60 s window of WR-11 unchanged.
for my $le (4, 6, 8) {
    reset_all();
    $TIME_SHIFT = 0;
    set_creds('acctT');
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = encode_field(2, 0, $le);

    my @live; $L5->getToken('acctT', sub { @live = @_ });
    is($live[1], 'mint_failed', "WR-18: LoginError $le keeps the mint_failed reason");
    is(ref($live[2]), 'HASH', "WR-18: LoginError $le carries a detail hash");
    is($live[2] && $live[2]{throttled}, 1, "WR-18: LoginError $le is flagged throttled");
    is($live[2] && $live[2]{loginError}, $le, "WR-18: LoginError $le carries the error number");
    is($live[2] && $live[2]{retryAfter}, 60, "WR-18: LoginError $le carries the 60 s window");
    ok(!($live[2] && $live[2]{transient}), "WR-18: LoginError $le is not transient (WR-12 unchanged)");
    ok(!defined state_of('acctT'), "WR-18: LoginError $le clears the login state (WR-12 unchanged)");

    my @damped; $L5->getToken('acctT', sub { @damped = @_ });
    is(posts(), 1, "WR-18: LoginError $le is damped (WR-11 unchanged, no new POST)");
    is($damped[2] && $damped[2]{throttled}, 1, "WR-18: the damped replay of LoginError $le is flagged throttled as well");
    is($damped[2] && $damped[2]{loginError}, $le, "WR-18: and keeps the error number");

    $TIME_SHIFT = 59;
    my @inside; $L5->getToken('acctT', sub { @inside = @_ });
    is(posts(), 1, "WR-18: LoginError $le is still damped 59 s later");
    $TIME_SHIFT = 61;
    my @past; $L5->getToken('acctT', sub { @past = @_ });
    is(posts(), 2, "WR-18: past the 60 s window LoginError $le mints again");
    $TIME_SHIFT = 0;
}
{
    # the HTTP 429 carries the same flag; credential and other errors do not
    reset_all();
    $TIME_SHIFT = 0;
    set_creds('acctT');
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error';
    $Slim::Networking::SimpleAsyncHTTP::error_text = '429 Too Many Requests';
    $Slim::Networking::SimpleAsyncHTTP::error_code = 429;
    my @h; $L5->getToken('acctT', sub { @h = @_ });
    is($h[2] && $h[2]{throttled}, 1, 'WR-18: the HTTP 429 detail is flagged throttled too');
    is($h[2] && $h[2]{code}, 429, 'WR-18: and still carries code 429');

    for my $le (1, 2, 5) {
        reset_all();
        set_creds('acctT');
        $Slim::Networking::SimpleAsyncHTTP::auto_response_content = encode_field(2, 0, $le);
        my @o; $L5->getToken('acctT', sub { @o = @_ });
        ok(!($o[2] && ref $o[2] eq 'HASH' && $o[2]{throttled}), "WR-18: LoginError $le is no throttle");
    }
}
{
    # no Retry-After: a failed mint is damped for a short default, then retried
    reset_all();
    $TIME_SHIFT = 0;
    set_creds('acctD');
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error';    # socket failure (transient)
    $L5->getToken('acctD', sub { });
    $L5->getToken('acctD', sub { });
    is(posts(), 1, 'WR-11: a failed (transient) mint is damped without any Retry-After');
    my @d; $L5->getToken('acctD', sub { @d = @_ });
    is_deeply($d[2], { transient => 1 }, 'WR-11: a damped transient failure is still reported transient');
    $TIME_SHIFT = 30;
    $L5->getToken('acctD', sub { });
    is(posts(), 2, 'WR-11: the default damping is short (a retry 30 s later POSTs again)');
    $TIME_SHIFT = 0;
}
{
    # an invalid_credentials answer is damped too; re-pairing (forgetAccount) lifts it at once
    reset_all();
    $TIME_SHIFT = 0;
    set_creds('acctD');
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = encode_field(2, 0, 1);
    $L5->getToken('acctD', sub { });
    my @again; $L5->getToken('acctD', sub { @again = @_ });
    is(posts(), 1, 'WR-11: an invalid_credentials answer is damped as well');
    is($again[1], 'invalid_credentials', 'WR-11: the damped answer keeps the invalid_credentials reason');
    my $ok = eval { $L5->forgetAccount('acctD'); 1 };
    $L5->getToken('acctD', sub { });
    is(posts(), 2, 'WR-11: forgetAccount (re-pairing / removal) lifts the damping at once');
}
{
    # damping is per account, and no_credentials (no request made) is never damped
    reset_all();
    $TIME_SHIFT = 0;
    set_creds('acctA'); set_creds('acctB');
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error';
    $L5->getToken('acctA', sub { });
    $L5->getToken('acctB', sub { });
    is(posts(), 2, 'WR-11: damping is keyed by account (the other account still mints)');
    my @nc; $L5->getToken('acctNone', sub { @nc = @_ });
    set_creds('acctNone');
    $L5->getToken('acctNone', sub { @nc = @_ });
    is(posts(), 3, 'WR-11: a missing credentials file is not damped (nothing was sent)');
}
{
    # the health tick is a deliberate forced mint and is not blocked by the damping
    reset_all();
    $TIME_SHIFT = 0;
    set_creds('acct1');
    $prefs->set('activeAccount', 'acct1');
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error';
    $L5->getToken('acct1', sub { });
    is(posts(), 1, 'WR-11 setup: a failed user request damps the account');
    tick();
    is(posts(), 2, 'WR-11: the health tick mints regardless of the damping');
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = login_ok_response();
    tick();
    is(posts(), 3, 'WR-11 setup: the successful tick minted');
    Slim::Utils::Cache->new()->clear();    # drop the token the tick cached
    my @after; $L5->getToken('acct1', sub { @after = @_ });
    is(posts(), 4, 'WR-11: a successful tick lifts the damping (the next user request POSTs again)');
    ok($after[0], 'WR-11: and gets a token');
}

# loginState: invalid_credentials after LoginError INVALID_CREDENTIALS, no_credentials without a file,
# and a non-transient mint failure is not reported as ok.
{
    reset_all();
    set_creds('acctI');
    # LoginResponse{ ok=1, error=2, challenges=3, login_context=5 } (librespot
    # login5.proto, commit 19959512): INVALID_CREDENTIALS = error (field 2) = 1.
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = encode_field(2, 0, 1);
    my ($tok, $why, $detail);
    $L5->getToken('acctI', sub { ($tok, $why, $detail) = @_ });
    is(state_of('acctI'), 'invalid_credentials', 'loginState is invalid_credentials after LoginError INVALID_CREDENTIALS (response field 2 = 1)');
    ok(!($detail && $detail->{transient}), 'invalid_credentials is not marked transient');

    Slim::Networking::SimpleAsyncHTTP::reset_requests();
    $L5->getToken('acctNone', sub { });
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, 'getToken without credentials sends no request');
    is(state_of('acctNone'), 'no_credentials', 'loginState is no_credentials without a credentials file');

    reset_all();
    set_creds('acctG');
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = login_ok_response();
    $L5->getToken('acctG', sub { });
    is(state_of('acctG'), 'ok', 'loginState ok before the garbage answer');
    Slim::Utils::Cache->new()->clear();
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = "\xff\xff\xff";
    $L5->getToken('acctG', sub { });
    isnt(state_of('acctG'), 'ok', 'a non-transient mint failure no longer reports ok');
}

# transient failure -> retry after 60 s; the next success -> exactly one networkRecovered.
{
    reset_all();
    set_creds('acct1');
    $prefs->set('activeAccount', 'acct1');

    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error';
    tick();
    my $d = last_arm_delay();
    ok(defined $d && abs($d - 60) < 5, 'transient failure: re-armed after HEALTH_RETRY_SECONDS (60)');
    is($Plugins::SpotOn::Unified::DaemonManager::recovered, 0, 'transient failure: no networkRecovered yet');
    is(state_of('acct1'), 'transient', 'transient failure: loginState transient');

    Slim::Utils::Timers::reset_calls();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = login_ok_response();
    tick();
    is($Plugins::SpotOn::Unified::DaemonManager::recovered, 1, 'next success: exactly one networkRecovered');
    $d = last_arm_delay();
    ok(defined $d && abs($d - 2700) < 5, 'next success: re-armed after HEALTH_TICK_SECONDS (2700)');
    is(scalar(@Slim::Utils::Timers::set_calls), 1, 'a tick re-arms exactly once');

    tick();
    is($Plugins::SpotOn::Unified::DaemonManager::recovered, 1, 'a further success does not fire the edge again');
}

# invalid_credentials / no_credentials never trigger the edge and never set the transient flag.
{
    reset_all();
    set_creds('acct1');
    $prefs->set('activeAccount', 'acct1');

    # LoginResponse{ ok=1, error=2, challenges=3, login_context=5 } (librespot
    # login5.proto, commit 19959512): INVALID_CREDENTIALS = error (field 2) = 1.
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = encode_field(2, 0, 1);
    tick();
    is(state_of('acct1'), 'invalid_credentials', 'tick: invalid_credentials is recorded');
    my $d = last_arm_delay();
    ok(defined $d && abs($d - 2700) < 5, 'invalid_credentials: re-armed after HEALTH_TICK_SECONDS, not the retry delay');

    %Plugins::SpotOn::API::Credentials::creds_for = ();
    tick();
    is(state_of('acct1'), 'no_credentials', 'tick: no_credentials is recorded');

    set_creds('acct1');
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = login_ok_response();
    tick();
    is($Plugins::SpotOn::Unified::DaemonManager::recovered, 0, 'permanent failures never set the transient flag: a later success fires no edge');
}

# No active account -> no mint, re-armed after HEALTH_TICK_SECONDS.
{
    reset_all();
    tick();
    is(scalar(@Slim::Networking::SimpleAsyncHTTP::requests), 0, 'no active account: no mint');
    my $d = last_arm_delay();
    ok(defined $d && abs($d - 2700) < 5, 'no active account: re-armed after HEALTH_TICK_SECONDS');
}

# networkRecovered dying is caught and logged as WARN; the tick re-arms anyway.
{
    reset_all();
    set_creds('acct1');
    $prefs->set('activeAccount', 'acct1');
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error';
    tick();
    Slim::Utils::Timers::reset_calls();
    $Plugins::SpotOn::Unified::DaemonManager::die = 1;
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = login_ok_response();
    tick();
    is($Plugins::SpotOn::Unified::DaemonManager::recovered, 1, 'dying networkRecovered: it was called once');
    ok(scalar(grep { $_->[0] eq 'warn' && $_->[1] =~ /network recovery notice/ } @Slim::Utils::Log::calls),
        'dying networkRecovered: logged as WARN');
    my $d = last_arm_delay();
    ok(defined $d && abs($d - 2700) < 5, 'dying networkRecovered: the tick re-arms anyway');
}

# ============================================================
# CR-01 (85-18): LoginResponse.error (field 2) through the health tick
# ============================================================
# LoginError: INVALID_CREDENTIALS=1 UNKNOWN_IDENTIFIER=5 TOO_MANY_ATTEMPTS=6
# (librespot login5.proto, commit 19959512). Only a credential-bound rejection
# marks the account invalid; throttling answers are NOT the transient channel.
{
    reset_all();
    set_creds('acct1');
    $prefs->set('activeAccount', 'acct1');
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = encode_field(2, 0, 5);
    tick();
    is(state_of('acct1'), 'invalid_credentials', 'CR-01: a tick answered UNKNOWN_IDENTIFIER records invalid_credentials');
    my $d = last_arm_delay();
    ok(defined $d && abs($d - 2700) < 5, 'CR-01: a tick answered UNKNOWN_IDENTIFIER re-arms after 2700 s');
}
{
    reset_all();
    set_creds('acct1');
    $prefs->set('activeAccount', 'acct1');
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = encode_field(2, 0, 6);
    tick();
    isnt(state_of('acct1'), 'transient', 'CR-01: a tick answered TOO_MANY_ATTEMPTS records no transient state');
    my $d = last_arm_delay();
    ok(defined $d && abs($d - 2700) < 5, 'CR-01: a tick answered TOO_MANY_ATTEMPTS re-arms after 2700 s, not the 60 s retry');
    ok(!scalar(grep { $_->[0] eq 'info' && $_->[1] =~ /transient health-tick failure/ } @Slim::Utils::Log::calls),
        'CR-01: a tick answered TOO_MANY_ATTEMPTS is not logged as a transient failure');

    Slim::Utils::Timers::reset_calls();
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = login_ok_response();
    tick();
    is(state_of('acct1'), 'ok', 'CR-01: the success after TOO_MANY_ATTEMPTS records ok');
    is($Plugins::SpotOn::Unified::DaemonManager::recovered, 0,
        'CR-01: a success after TOO_MANY_ATTEMPTS fires no networkRecovered edge');
}
{
    reset_all();
    set_creds('acct-secret-77');
    $prefs->set('activeAccount', 'acct-secret-77');
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = encode_field(2, 0, 1);
    tick();
    my @warn = grep { $_->[0] eq 'warn' } @Slim::Utils::Log::calls;
    my ($line) = grep { $_ =~ /INVALID_CREDENTIALS/ } map { $_->[1] } @warn;
    ok(defined $line, 'CR-01: the WARN line for an error reply names the LoginError enum (INVALID_CREDENTIALS)');
    ok(defined $line && $line =~ /acct\*\*\*\*/ && $line !~ /acct-secret-77/ && $line !~ /user-acct-secret-77/,
        'CR-01: the WARN line carries the masked account id only, neither the full id nor the credentials username');
}

done_testing();

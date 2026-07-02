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
# logger() is exported as a function when modules do 'use Slim::Utils::Log'
write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
use parent 'Exporter';
our @EXPORT_OK = qw(logger);
# Install logger() into caller namespace so bare 'logger(...)' works
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub addLogCategory { return bless {}, 'Slim::Utils::Log' }
sub logger {
    return bless { _calls => [] }, 'Slim::Utils::Log';
}
sub info     { push @{$_[0]->{_calls}}, ['info',  $_[1]] }
sub warn     { push @{$_[0]->{_calls}}, ['warn',  $_[1]] }
sub error    { push @{$_[0]->{_calls}}, ['error', $_[1]] }
sub debug    { push @{$_[0]->{_calls}}, ['debug', $_[1]] }
sub is_info  { 0 }
sub is_debug { 0 }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Stub: Slim::Utils::Prefs
# preferences() is exported as a function when modules do 'use Slim::Utils::Prefs'
my $prefs_cache_dir = $cache_dir;
write_stub($stub_dir, 'Slim::Utils::Prefs', <<"END");
package Slim::Utils::Prefs;
my %_store;
my %_ns_store = ( server => { cachedir => '$prefs_cache_dir' } );

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

# Stub: Slim::Utils::Cache (in-memory, records TTL)
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

# Stub: File::Spec::Functions
write_stub($stub_dir, 'File::Spec::Functions', <<'END');
package File::Spec::Functions;
use parent 'Exporter';
use File::Spec ();
our @EXPORT_OK = qw(catdir catfile);
*catdir  = \&File::Spec::catdir;
*catfile = \&File::Spec::catfile;
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
# Stub: Slim::Networking::SimpleAsyncHTTP
# Controllable: captures request args, allows manual callback invocation
# ============================================================
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;

our @requests  = ();  # Each entry: { method, url, headers, success_cb, error_cb }
our $auto_mode = 'success';  # 'success', 'error_429', 'error_generic', 'none'
our $last_response_headers = {};
our $auto_response_content = undef;  # Override response body (undef = use default)

sub new {
    my ($class, $success_cb, $error_cb, $opts) = @_;
    return bless {
        success_cb => $success_cb,
        error_cb   => $error_cb,
        opts       => $opts || {},
    }, $class;
}

sub get    { _dispatch(shift, 'GET',    @_) }
sub post   { _dispatch(shift, 'POST',   @_) }
sub put    { _dispatch(shift, 'PUT',    @_) }
sub delete { _dispatch(shift, 'DELETE', @_) }

sub _dispatch {
    my ($self, $method, $url, %headers) = @_;

    my $entry = {
        method     => $method,
        url        => $url,
        headers    => \%headers,
        success_cb => $self->{success_cb},
        error_cb   => $self->{error_cb},
    };
    push @requests, $entry;

    if ($auto_mode eq 'success') {
        my $content = defined($auto_response_content)
            ? $auto_response_content
            : '{"display_name":"Test User","id":"spotify_user"}';
        my $mock_response = bless {
            _content => $content,
            _code    => 200,
        }, 'Slim::Networking::SimpleAsyncHTTP::Response';
        $self->{success_cb}->($mock_response);
    }
    elsif ($auto_mode eq 'error_429') {
        my $mock_response = bless {
            _code    => 429,
            _headers => $last_response_headers,
        }, 'Slim::Networking::SimpleAsyncHTTP::MockResponse';
        $self->{error_cb}->($self, '429 Rate limit exceeded', $mock_response);
    }
    elsif ($auto_mode eq 'error_generic') {
        my $mock_response = bless {
            _code    => 500,
            _headers => {},
        }, 'Slim::Networking::SimpleAsyncHTTP::MockResponse';
        $self->{error_cb}->($self, '500 Internal server error', $mock_response);
    }
    # 'none': no callback, simulates hanging request
}

sub reset_requests { @requests = (); $auto_mode = 'success'; $last_response_headers = {}; $auto_response_content = undef }

package Slim::Networking::SimpleAsyncHTTP::Response;
sub content  { $_[0]->{_content} }
sub code     { $_[0]->{_code} }
sub response { $_[0] }
sub header   { $_[0]->{_headers}{$_[1]} }

package Slim::Networking::SimpleAsyncHTTP::ErrorResponse;
sub content  { '' }
sub code     { $_[0]->{_code} }
sub response { $_[0] }
sub header   { $_[0]->{_headers}{$_[1]} }

package Slim::Networking::SimpleAsyncHTTP::MockResponse;
sub code     { $_[0]->{_code} }
sub header   { $_[0]->{_headers}{$_[1]} }
sub can      { 1 }
1;
END

# Stub: Plugins::SpotOn::API::TokenManager
# For Client tests: getToken invokes callback immediately with a mock token
write_stub($stub_dir, 'Plugins::SpotOn::API::TokenManager', <<'END');
package Plugins::SpotOn::API::TokenManager;
our $mock_token = 'mock_token_abc123';
sub getToken {
    my ($class, $accountId, $flavorOrCb, $cb) = @_;
    if (ref $flavorOrCb eq 'CODE') {
        $cb = $flavorOrCb;
    }
    $cb->($mock_token);
}
sub refreshToken {
    my ($class, $accountId, $flavorOrCb, $cb) = @_;
    if (ref $flavorOrCb eq 'CODE') {
        $cb = $flavorOrCb;
    }
    $cb->($mock_token);
}
1;
END

# Stub: URI::Escape — not Perl core, bundled by LMS
# Mirrors real behavior: uri_escape dies on codepoints > 255 (wide chars),
# uri_escape_utf8 UTF-8-encodes first and never dies.
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

# Add paths to @INC
unshift @INC, $stub_dir, $project_dir;

# ============================================================
# Tests: API/Client.pm (skip if not yet created)
# ============================================================

my $client_module = "$project_dir/Plugins/SpotOn/API/Client.pm";

SKIP: {
    skip "Client.pm not yet created (Plan 02-03 will create it)", 10
        unless -f $client_module;

    require_ok('Plugins::SpotOn::API::Client')
        or BAIL_OUT("Failed to load Client.pm");

    # Reset state before tests
    Slim::Networking::SimpleAsyncHTTP::reset_requests();
    Plugins::SpotOn::API::Client->reset() if Plugins::SpotOn::API::Client->can('reset');
    Slim::Utils::Cache->new()->clear();

    # API-01: getMe routes through _request which uses SimpleAsyncHTTP
    {
        Slim::Networking::SimpleAsyncHTTP::reset_requests();
        $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';

        Plugins::SpotOn::API::Client->getMe('testacct', sub { });

        my @reqs = @Slim::Networking::SimpleAsyncHTTP::requests;
        ok(scalar(@reqs) > 0, 'API-01: getMe triggers a SimpleAsyncHTTP request');

        my $req = $reqs[0];
        like($req->{url}, qr{api\.spotify\.com/v1/me},
            'API-01: Request URL contains Spotify API /me endpoint');
        like($req->{headers}{'Authorization'}, qr/^Bearer /,
            'API-01: Request includes Authorization: Bearer header');
    }

    # API-02: MAX_CONCURRENT_REQUESTS limits to 3 concurrent dispatches
    {
        Slim::Networking::SimpleAsyncHTTP::reset_requests();
        Plugins::SpotOn::API::Client->reset() if Plugins::SpotOn::API::Client->can('reset');

        # Suspend auto-callback to simulate inflight requests
        $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'none';

        # Fire 5 requests rapidly
        for my $i (1..5) {
            Plugins::SpotOn::API::Client->getMe('testacct', sub { });
        }

        my @reqs = @Slim::Networking::SimpleAsyncHTTP::requests;
        my $dispatched = scalar(@reqs);
        ok($dispatched <= 3,
            "API-02: MAX_CONCURRENT_REQUESTS=3 respected (dispatched $dispatched of 5 requested)");

        # Reset for subsequent tests
        $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
        Plugins::SpotOn::API::Client->reset() if Plugins::SpotOn::API::Client->can('reset');
    }

    # API-03: _cacheTTL returns correct values
    {
        my $ttl_player  = Plugins::SpotOn::API::Client->_cacheTTL('me/player');
        my $ttl_tracks  = Plugins::SpotOn::API::Client->_cacheTTL('me/tracks');
        my $ttl_meta    = Plugins::SpotOn::API::Client->_cacheTTL('tracks/abc123');
        my $ttl_pl      = Plugins::SpotOn::API::Client->_cacheTTL('playlists/abc123');

        is($ttl_player, 0,    'API-03: _cacheTTL returns 0 for me/player (no caching for live state)');
        is($ttl_tracks, 60,   'API-03: _cacheTTL returns 60 for me/tracks (library items)');
        is($ttl_meta,   3600, 'API-03: _cacheTTL returns 3600 for tracks/<id> (metadata)');
        is($ttl_pl,     300,  'API-03: _cacheTTL returns 300 for playlists/<id>');
    }

    # API-04: 429 response sets per-flavor rate-limit key with Retry-After TTL
    {
        Slim::Utils::Cache->new()->clear();
        Plugins::SpotOn::API::Client->reset() if Plugins::SpotOn::API::Client->can('reset');
        Slim::Networking::SimpleAsyncHTTP::reset_requests();

        # me/* needs clientId pref to route via flavor=own (D-05 fallback change)
        Slim::Utils::Prefs->preferences('plugin.spoton')->set('clientId', 'test-client-id');

        $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_429';
        $Slim::Networking::SimpleAsyncHTTP::last_response_headers = { 'Retry-After' => 60 };

        my ($result, $err);
        Plugins::SpotOn::API::Client->getMe('testacct', sub {
            ($result, $err) = @_;
        });

        my $cache = Slim::Utils::Cache->new();
        ok($cache->get('spoton_rate_limit_own'), 'API-04: per-flavor rate-limit key set in cache after 429');

        my $ttl = $cache->ttl('spoton_rate_limit_own');
        is($ttl, 60, 'API-04: Rate limit cache TTL equals Retry-After header value');

        # Reset for next test
        $cache->clear();
        $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
        Slim::Utils::Prefs->preferences('plugin.spoton')->set('clientId', undef);
        Plugins::SpotOn::API::Client->reset() if Plugins::SpotOn::API::Client->can('reset');
    }

    # API-04: Retry-After > 300 is capped at 300
    {
        Slim::Utils::Cache->new()->clear();
        Plugins::SpotOn::API::Client->reset() if Plugins::SpotOn::API::Client->can('reset');
        Slim::Networking::SimpleAsyncHTTP::reset_requests();

        Slim::Utils::Prefs->preferences('plugin.spoton')->set('clientId', 'test-client-id');

        $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'error_429';
        $Slim::Networking::SimpleAsyncHTTP::last_response_headers = { 'Retry-After' => 9999 };

        Plugins::SpotOn::API::Client->getMe('testacct', sub { });

        my $ttl = Slim::Utils::Cache->new()->ttl('spoton_rate_limit_own');
        ok($ttl <= 300,
            "API-04: Retry-After capped at 300s (got $ttl)");

        # Reset
        Slim::Utils::Cache->new()->clear();
        $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
        Slim::Utils::Prefs->preferences('plugin.spoton')->set('clientId', undef);
        Plugins::SpotOn::API::Client->reset() if Plugins::SpotOn::API::Client->can('reset');
    }
}

# API-05: No batch methods exist — verified by source inspection
SKIP: {
    skip "Client.pm not yet created", 1
        unless -f $client_module;

    open(my $fh, '<', $client_module) or BAIL_OUT("Cannot open $client_module: $!");
    my $source = do { local $/; <$fh> };
    close($fh);

    unlike($source, qr/\bgetTracks\b|\bgetAlbums\b|\bgetArtists\b/,
        'API-05: No batch methods (getTracks/getAlbums/getArtists) in Client.pm');
}

# LIB-01: saveTracks sends PUT to /me/library with uris query param
SKIP: {
    skip "Client.pm not yet created", 5
        unless -f $client_module;

    Slim::Networking::SimpleAsyncHTTP::reset_requests();
    Plugins::SpotOn::API::Client->reset() if Plugins::SpotOn::API::Client->can('reset');
    $Slim::Networking::SimpleAsyncHTTP::auto_mode    = 'success';
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = '';  # Empty body — 200 OK

    my ($got_result, $got_err);
    Plugins::SpotOn::API::Client->saveTracks('testacct', ['spotify:track:ABC123'], sub {
        ($got_result, $got_err) = @_;
    });

    my @reqs = @Slim::Networking::SimpleAsyncHTTP::requests;
    is(scalar(@reqs), 1, 'LIB-01: saveTracks dispatches exactly one HTTP request');
    is($reqs[0]->{method}, 'PUT', 'LIB-01: saveTracks uses PUT method');
    like($reqs[0]->{url}, qr{/me/library}, 'LIB-01: saveTracks URL contains /me/library');
    like($reqs[0]->{url}, qr{uris=}, 'LIB-01: saveTracks URL contains uris= query param');
    is($got_err, undef, 'LIB-01: Empty-body guard — saveTracks callback receives no error on 200 empty response');
}

# LIB-02: removeTracks sends DELETE to /me/library with uris query param
SKIP: {
    skip "Client.pm not yet created", 5
        unless -f $client_module;

    Slim::Networking::SimpleAsyncHTTP::reset_requests();
    Plugins::SpotOn::API::Client->reset() if Plugins::SpotOn::API::Client->can('reset');
    $Slim::Networking::SimpleAsyncHTTP::auto_mode    = 'success';
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = '';  # Empty body — 200 OK

    my ($got_result, $got_err);
    Plugins::SpotOn::API::Client->removeTracks('testacct', ['spotify:track:ABC123'], sub {
        ($got_result, $got_err) = @_;
    });

    my @reqs = @Slim::Networking::SimpleAsyncHTTP::requests;
    is(scalar(@reqs), 1, 'LIB-02: removeTracks dispatches exactly one HTTP request');
    is($reqs[0]->{method}, 'DELETE', 'LIB-02: removeTracks uses DELETE method');
    like($reqs[0]->{url}, qr{/me/library}, 'LIB-02: removeTracks URL contains /me/library');
    like($reqs[0]->{url}, qr{uris=}, 'LIB-02: removeTracks URL contains uris= query param');
    is($got_err, undef, 'LIB-02: Empty-body guard — removeTracks callback receives no error on 200 empty response');
}

# LIB-03: checkTracks sends GET to /me/library/contains, returns [true]/[false]
SKIP: {
    skip "Client.pm not yet created", 6
        unless -f $client_module;

    Slim::Networking::SimpleAsyncHTTP::reset_requests();
    Plugins::SpotOn::API::Client->reset() if Plugins::SpotOn::API::Client->can('reset');
    $Slim::Networking::SimpleAsyncHTTP::auto_mode    = 'success';
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = '[true]';

    my ($got_result, $got_err);
    Plugins::SpotOn::API::Client->checkTracks('testacct', ['spotify:track:ABC123'], sub {
        ($got_result, $got_err) = @_;
    });

    my @reqs = @Slim::Networking::SimpleAsyncHTTP::requests;
    is(scalar(@reqs), 1, 'LIB-03: checkTracks dispatches exactly one HTTP request');
    is($reqs[0]->{method}, 'GET', 'LIB-03: checkTracks uses GET method');
    like($reqs[0]->{url}, qr{/me/library/contains}, 'LIB-03: checkTracks URL contains /me/library/contains');
    like($reqs[0]->{url}, qr{uris=}, 'LIB-03: checkTracks URL contains uris= query param');
    ok($got_result && ref($got_result) eq 'ARRAY' && $got_result->[0], 'LIB-03: checkTracks returns [true] array');
    is($got_err, undef, 'LIB-03: checkTracks callback receives no error');
}

# LIB-04: checkTracks with _noCache => 1 always dispatches an HTTP request
# (Client.pm does NOT cache — caching responsibility lies in Plugin.pm per D-07)
SKIP: {
    skip "Client.pm not yet created", 2
        unless -f $client_module;

    Slim::Networking::SimpleAsyncHTTP::reset_requests();
    Plugins::SpotOn::API::Client->reset() if Plugins::SpotOn::API::Client->can('reset');
    Slim::Utils::Cache->new()->clear();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode    = 'success';
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = '[false]';

    # First call
    Plugins::SpotOn::API::Client->checkTracks('testacct', ['spotify:track:XYZ999'], sub { });
    my $first_count = scalar(@Slim::Networking::SimpleAsyncHTTP::requests);
    is($first_count, 1, 'LIB-04: First checkTracks call issues one HTTP request');

    # Second call with same args — Client.pm must issue another request (_noCache => 1)
    Plugins::SpotOn::API::Client->checkTracks('testacct', ['spotify:track:XYZ999'], sub { });
    my $second_count = scalar(@Slim::Networking::SimpleAsyncHTTP::requests);
    is($second_count, 2,
        'LIB-04: checkTracks with _noCache => 1 always dispatches HTTP (Client.pm does not cache)');
}

# LIB-05: SPOTON_CACHE_VERSION is 4 in Plugin.pm; cache namespace version is 4 in Client.pm
SKIP: {
    skip "Client.pm not yet created", 2
        unless -f $client_module;

    my $plugin_file = "$project_dir/Plugins/SpotOn/Plugin.pm";
    SKIP: {
        skip "Plugin.pm not yet created", 1 unless -f $plugin_file;
        open(my $fh, '<', $plugin_file) or die "Cannot open $plugin_file: $!";
        my $src = do { local $/; <$fh> };
        close($fh);
        like($src, qr/SPOTON_CACHE_VERSION\s*=>\s*4\b/,
            'LIB-05: Plugin.pm SPOTON_CACHE_VERSION is 4');
    }

    open(my $cfh, '<', $client_module) or die "Cannot open $client_module: $!";
    my $csrc = do { local $/; <$cfh> };
    close($cfh);
    like($csrc, qr/new\('spoton',\s*4\)/,
        "LIB-05: Client.pm cache namespace version is 4");
}

# LIB-06: saveShows sends PUT to /me/shows with ids query param
SKIP: {
    skip "Client.pm not yet created", 5
        unless -f $client_module;

    Slim::Networking::SimpleAsyncHTTP::reset_requests();
    Plugins::SpotOn::API::Client->reset() if Plugins::SpotOn::API::Client->can('reset');
    $Slim::Networking::SimpleAsyncHTTP::auto_mode    = 'success';
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = '';  # Empty body — 200 OK

    my ($got_result, $got_err);
    Plugins::SpotOn::API::Client->saveShows('testacct', ['spotify:show:ABC123'], sub {
        ($got_result, $got_err) = @_;
    });

    my @reqs = @Slim::Networking::SimpleAsyncHTTP::requests;
    is(scalar(@reqs), 1, 'LIB-06: saveShows dispatches exactly one HTTP request');
    is($reqs[0]->{method}, 'PUT', 'LIB-06: saveShows uses PUT method');
    like($reqs[0]->{url}, qr{/me/shows\b}, 'LIB-06: saveShows URL contains /me/shows');
    like($reqs[0]->{url}, qr{ids=ABC123}, 'LIB-06: saveShows URL contains ids= with extracted show ID');
    is($got_err, undef, 'LIB-06: Empty-body guard — saveShows callback receives no error on 200 empty response');
}

# LIB-07: removeShows sends DELETE to /me/shows with ids query param
SKIP: {
    skip "Client.pm not yet created", 5
        unless -f $client_module;

    Slim::Networking::SimpleAsyncHTTP::reset_requests();
    Plugins::SpotOn::API::Client->reset() if Plugins::SpotOn::API::Client->can('reset');
    $Slim::Networking::SimpleAsyncHTTP::auto_mode    = 'success';
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = '';  # Empty body — 200 OK

    my ($got_result, $got_err);
    Plugins::SpotOn::API::Client->removeShows('testacct', ['spotify:show:ABC123'], sub {
        ($got_result, $got_err) = @_;
    });

    my @reqs = @Slim::Networking::SimpleAsyncHTTP::requests;
    is(scalar(@reqs), 1, 'LIB-07: removeShows dispatches exactly one HTTP request');
    is($reqs[0]->{method}, 'DELETE', 'LIB-07: removeShows uses DELETE method');
    like($reqs[0]->{url}, qr{/me/shows\b}, 'LIB-07: removeShows URL contains /me/shows');
    like($reqs[0]->{url}, qr{ids=ABC123}, 'LIB-07: removeShows URL contains ids= with extracted show ID');
    is($got_err, undef, 'LIB-07: Empty-body guard — removeShows callback receives no error on 200 empty response');
}

# LIB-08: checkShows sends GET to /me/shows/contains, returns [true]/[false]
SKIP: {
    skip "Client.pm not yet created", 6
        unless -f $client_module;

    Slim::Networking::SimpleAsyncHTTP::reset_requests();
    Plugins::SpotOn::API::Client->reset() if Plugins::SpotOn::API::Client->can('reset');
    $Slim::Networking::SimpleAsyncHTTP::auto_mode    = 'success';
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = '[true]';

    my ($got_result, $got_err);
    Plugins::SpotOn::API::Client->checkShows('testacct', ['spotify:show:ABC123'], sub {
        ($got_result, $got_err) = @_;
    });

    my @reqs = @Slim::Networking::SimpleAsyncHTTP::requests;
    is(scalar(@reqs), 1, 'LIB-08: checkShows dispatches exactly one HTTP request');
    is($reqs[0]->{method}, 'GET', 'LIB-08: checkShows uses GET method');
    like($reqs[0]->{url}, qr{/me/shows/contains}, 'LIB-08: checkShows URL contains /me/shows/contains');
    like($reqs[0]->{url}, qr{ids=ABC123}, 'LIB-08: checkShows URL contains ids= with extracted show ID');
    ok($got_result && ref($got_result) eq 'ARRAY' && $got_result->[0], 'LIB-08: checkShows returns [true] array');
    is($got_err, undef, 'LIB-08: checkShows callback receives no error');
}

# LIB-09: checkShows with _noCache => 1 always dispatches an HTTP request
# (Client.pm does NOT cache — caching responsibility lies in Plugin.pm per D-07)
SKIP: {
    skip "Client.pm not yet created", 2
        unless -f $client_module;

    Slim::Networking::SimpleAsyncHTTP::reset_requests();
    Plugins::SpotOn::API::Client->reset() if Plugins::SpotOn::API::Client->can('reset');
    Slim::Utils::Cache->new()->clear();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode    = 'success';
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = '[false]';

    # First call
    Plugins::SpotOn::API::Client->checkShows('testacct', ['spotify:show:XYZ999'], sub { });
    my $first_count = scalar(@Slim::Networking::SimpleAsyncHTTP::requests);
    is($first_count, 1, 'LIB-09: First checkShows call issues one HTTP request');

    # Second call with same args — Client.pm must issue another request (_noCache => 1)
    Plugins::SpotOn::API::Client->checkShows('testacct', ['spotify:show:XYZ999'], sub { });
    my $second_count = scalar(@Slim::Networking::SimpleAsyncHTTP::requests);
    is($second_count, 2,
        'LIB-09: checkShows with _noCache => 1 always dispatches HTTP (Client.pm does not cache)');
}

# H1: Wide-character query params must not die and must not leak the
# inflight counter (regression test for uri_escape dying on codepoints > 255
# AFTER $inflightCount++, which deadlocked the request pipeline).
SKIP: {
    skip "Client.pm not yet created", 3
        unless -f $client_module;

    Slim::Networking::SimpleAsyncHTTP::reset_requests();
    Plugins::SpotOn::API::Client->reset() if Plugins::SpotOn::API::Client->can('reset');
    Slim::Utils::Cache->new()->clear();
    $Slim::Networking::SimpleAsyncHTTP::auto_mode = 'success';
    $Slim::Networking::SimpleAsyncHTTP::auto_response_content = '{"tracks":{"items":[]}}';

    my ($called, $got_result, $got_err);
    my $lived = eval {
        Plugins::SpotOn::API::Client->search('testacct', { q => "Mot\x{f6}rhead \x{263A}" }, sub {
            $called = 1;
            ($got_result, $got_err) = @_;
        });
        1;
    };
    ok($lived, 'H1: request with wide-char query param does not die');
    ok($called, 'H1: callback is invoked (result or error) for wide-char query');

    my $snap = Plugins::SpotOn::API::Client->statusSnapshot;
    is($snap->{inflightCount}, 0,
        'H1: inflight counter returns to 0 after wide-char request');

    Slim::Utils::Cache->new()->clear();
    Slim::Networking::SimpleAsyncHTTP::reset_requests();
    Plugins::SpotOn::API::Client->reset() if Plugins::SpotOn::API::Client->can('reset');
}

# API-06: No LWP or SimpleSyncHTTP in API/ modules — grep test (runs immediately)
{
    my @api_files = glob("$project_dir/Plugins/SpotOn/API/*.pm");

    if (!@api_files) {
        pass('API-06: No API/*.pm files yet — nothing to check for blocking HTTP');
    }
    else {
        for my $f (@api_files) {
            open(my $fh, '<', $f) or die "Cannot open $f: $!";
            my $content = do { local $/; <$fh> };
            close($fh);

            unlike($content, qr/LWP::UserAgent|SimpleSyncHTTP/,
                "API-06: $f contains no blocking HTTP (LWP::UserAgent, SimpleSyncHTTP)");
        }
    }
}

done_testing();

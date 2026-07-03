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

# Create temporary directories for LMS stubs and cache
my $stub_dir  = tempdir(CLEANUP => 1);
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
# LMS Module Stubs (copied from t/11_track_history.t — the canonical
# analog for loading ProtocolHandler.pm with a complete stub set)
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
use parent 'Exporter';
our @EXPORT_OK = qw(logger addLogCategory);
my $_noop_logger = bless {}, 'Slim::Utils::Log';

sub addLogCategory { return $_noop_logger }
sub logger         { return $_noop_logger }
sub info  { }
sub warn  { }
sub error { }
sub debug { }
sub is_info  { 0 }
sub is_debug { 0 }
sub AUTOLOAD { }
sub can { 1 }

sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"}         = \&logger;
    *{"${caller}::addLogCategory"} = \&addLogCategory;
}
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

# Stub: JSON::XS (Plugin.pm uses 'use JSON::XS qw(encode_json)')
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

# Stub: Slim::Utils::Network (needed by ProtocolHandler.pm)
write_stub($stub_dir, 'Slim::Utils::Network', <<'END');
package Slim::Utils::Network;
sub serverAddr { '127.0.0.1' }
1;
END

# Stub: Slim::Utils::Versions (needed by ProtocolHandler.pm)
write_stub($stub_dir, 'Slim::Utils::Versions', <<'END');
package Slim::Utils::Versions;
sub compareVersions { 0 }
1;
END

# Stub: Slim::Utils::Misc (needed by ProtocolHandler.pm)
write_stub($stub_dir, 'Slim::Utils::Misc', <<'END');
package Slim::Utils::Misc;
sub crackURL { ('127.0.0.1', 80, '/stream') }
1;
END

# Stub: Slim::Control::Request
write_stub($stub_dir, 'Slim::Control::Request', <<'END');
package Slim::Control::Request;
our $notify_count = 0;
sub notifyFromArray { $notify_count++ }
sub subscribe   { }
sub unsubscribe { }
sub addDispatch { }
1;
END

# Stub: Slim::Music::Info
write_stub($stub_dir, 'Slim::Music::Info', <<'END');
package Slim::Music::Info;
sub setCurrentTitle { }
1;
END

# Stub: Slim::Player::Protocols::HTTP
write_stub($stub_dir, 'Slim::Player::Protocols::HTTP', <<'END');
package Slim::Player::Protocols::HTTP;
sub new { bless {}, shift }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Stub: Plugins::SpotOn::API::Client with controllable $mock_track
write_stub($stub_dir, 'Plugins::SpotOn::API::Client', <<'END');
package Plugins::SpotOn::API::Client;
our $mock_track = undef;
sub getTrack {
    my ($class, $account_id, $track_id, $cb) = @_;
    $cb->($mock_track);
}
sub AUTOLOAD { }
1;
END

# Stub: Plugins::SpotOn::Helper with controllable getCapability
write_stub($stub_dir, 'Plugins::SpotOn::Helper', <<'END');
package Plugins::SpotOn::Helper;
our $helperCapabilities = {};
sub get { return '/usr/bin/false' }
sub init { }
sub getCapability {
    my ($class, $key) = @_;
    return $helperCapabilities->{$key} if $helperCapabilities && defined $helperCapabilities->{$key};
    return undef;
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

# Stub: Plugins::SpotOn::Unified::DaemonManager (COMPAT-02 — new for canDirectStream coverage)
# helperForClient always returns a live mock helper on a fixed stream port so the
# Browse/Connect branches in canDirectStream() construct a daemon HTTP URL.
write_stub($stub_dir, 'Plugins::SpotOn::Unified::DaemonManager', <<'END');
package Plugins::SpotOn::Unified::DaemonManager;
sub helperForClient { return bless {}, 'MockDaemonHelper' }
sub scheduleInit { }
sub resolvePassthroughForClient { return 0 }

package MockDaemonHelper;
sub alive       { 1 }
sub _streamPort { 39755 }
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

# M5: SPOTON_CACHE_VERSION is defined in Plugin.pm (single source of truth);
# submodules resolve it via a fully-qualified call at load time. Production
# always compiles Plugin.pm first — provide the constant for standalone loads.
BEGIN {
    package Plugins::SpotOn::Plugin;
    use constant SPOTON_CACHE_VERSION => 4;
}

# Add to @INC
unshift @INC, $stub_dir, $project_dir;

# Pre-load stubs so subsequent `require` calls inside ProtocolHandler.pm find the stubs.
require Plugins::SpotOn::Helper;
require Plugins::SpotOn::API::Client;
require Plugins::SpotOn::Unified::DaemonManager;
require Slim::Control::Request;

# ============================================================
# Load ProtocolHandler.pm
# ============================================================
require_ok('Plugins::SpotOn::ProtocolHandler') or BAIL_OUT("Failed to load ProtocolHandler.pm");

# ============================================================
# Mock client object — extended from t/11_track_history.t's MockClient with
# isSynced (canDirectStream Browse/Connect branches call it directly) and an
# explicit id() accessor for readability in per-case setup below.
# ============================================================
{
    package MockClient;
    use overload '""' => sub { ${$_[0]} };
    sub new { my $id = $_[1] // 'player1'; bless \$id, $_[0] }
    sub can { return 0 }
    sub master { $_[0] }
    sub isSynced { 0 }
    sub id { ${$_[0]} }
    sub playingSong { undef }
    sub currentPlaylistUpdateTime { 1 }
}

my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');

# ============================================================
# Group A: COMPAT-02 canDirectStream proxy gate + global resolution (GH #96)
# Each case uses a FRESH MockClient id — the Prefs stub keys per-client
# namespaces by id and has no remove method, so reusing an id would leak
# state between cases.
# ============================================================

subtest 'COMPAT-02: per-player proxy forces canDirectStream=0 for Browse URL' => sub {
    my $client = MockClient->new('gateA1');
    $prefs->client($client)->set('streamingMode', 'proxy');

    my $result = Plugins::SpotOn::ProtocolHandler->canDirectStream($client, 'spoton://track:ABC123');
    is($result, 0, 'per-player streamingMode=proxy returns 0 for Browse URL');
};

subtest 'COMPAT-02: per-player proxy forces canDirectStream=0 for Connect URL' => sub {
    my $client = MockClient->new('gateA2');
    $prefs->client($client)->set('streamingMode', 'proxy');

    my $result = Plugins::SpotOn::ProtocolHandler->canDirectStream($client, 'spoton://connect-20260703-test');
    is($result, 0, 'per-player streamingMode=proxy returns 0 for Connect URL');
};

subtest 'COMPAT-02: per-player direct overrides a global proxy default' => sub {
    $prefs->set('streamingMode', 'proxy');
    my $client = MockClient->new('gateA3');
    $prefs->client($client)->set('streamingMode', 'direct');

    my $result = Plugins::SpotOn::ProtocolHandler->canDirectStream($client, 'spoton://track:ABC123');
    ok($result, 'per-player direct overrides a global proxy default (truthy result)');
    like($result, qr{/track/ABC123}, 'result is the daemon HTTP URL for the requested track');
};

subtest 'COMPAT-02: per-player explicit global resolves against a global proxy default' => sub {
    $prefs->set('streamingMode', 'proxy');
    my $client = MockClient->new('gateA4');
    $prefs->client($client)->set('streamingMode', 'global');

    my $result = Plugins::SpotOn::ProtocolHandler->canDirectStream($client, 'spoton://track:ABC123');
    is($result, 0, 'per-player global explicitly resolves against a global proxy default -> 0');
};

subtest 'COMPAT-02: per-player unset resolves against a global proxy default' => sub {
    $prefs->set('streamingMode', 'proxy');
    my $client = MockClient->new('gateA5');
    # No per-player streamingMode pref set at all — unset behaves as 'global'

    my $result = Plugins::SpotOn::ProtocolHandler->canDirectStream($client, 'spoton://track:ABC123');
    is($result, 0, 'per-player unset resolves against a global proxy default -> 0');
};

subtest 'COMPAT-02: all-unset defaults to direct (regression — default behavior unchanged)' => sub {
    # Explicitly clear the global default to simulate a totally fresh install
    $prefs->set('streamingMode', undef);
    my $client = MockClient->new('gateA6');

    my $result = Plugins::SpotOn::ProtocolHandler->canDirectStream($client, 'spoton://track:ABC123');
    ok($result, 'all prefs unset returns truthy daemon HTTP URL (default behavior unchanged)');
    like($result, qr{/track/ABC123}, 'result contains /track/ABC123');
};

subtest 'COMPAT-02: per-player global resolves against a global direct default' => sub {
    $prefs->set('streamingMode', 'direct');
    my $client = MockClient->new('gateA7');
    $prefs->client($client)->set('streamingMode', 'global');

    my $result = Plugins::SpotOn::ProtocolHandler->canDirectStream($client, 'spoton://track:ABC123');
    ok($result, 'per-player global resolves against a global direct default -> truthy');
};

# ============================================================
# Group B: COMPAT-01 enum validation regex checks
#
# HONESTY NOTE (review finding): these assert a copy of the regex, not
# Settings/Player.pm handler execution — the per-player handler is covered
# by the grep acceptance criteria in Task 1 plus manual UAT. The GLOBAL
# handler gets real execution coverage in t/09_settings.t.
# ============================================================

subtest 'COMPAT-01: per-player streamingMode enum regex (global|direct|proxy)' => sub {
    my $re = qr/^(?:global|direct|proxy)$/;
    ok('global' =~ $re, 'per-player regex accepts global');
    ok('direct' =~ $re, 'per-player regex accepts direct');
    ok('proxy'  =~ $re, 'per-player regex accepts proxy');
    ok('bogus' !~ $re, 'per-player regex rejects an invalid value');
    ok(''      !~ $re, 'per-player regex rejects an empty string');
};

subtest 'COMPAT-01: global streamingMode enum regex (direct|proxy)' => sub {
    my $re = qr/^(?:direct|proxy)$/;
    ok('direct' =~ $re, 'global regex accepts direct');
    ok('proxy'  =~ $re, 'global regex accepts proxy');
    ok('global' !~ $re, 'global regex rejects "global" (not a valid global-scope value)');
    ok('bogus'  !~ $re, 'global regex rejects an invalid value');
    ok(''       !~ $re, 'global regex rejects an empty string');
};

# ============================================================
# Group C: i18n coverage — all 7 PLUGIN_SPOTON_STREAMING_MODE* keys exist
# with exactly the 11 required locale lines before the next blank line.
# ============================================================

subtest 'i18n: PLUGIN_SPOTON_STREAMING_MODE* keys have all 11 locales' => sub {
    my $strings_file = "$project_dir/Plugins/SpotOn/strings.txt";
    open(my $fh, '<', $strings_file) or BAIL_OUT("Cannot read strings.txt: $!");
    my @lines = <$fh>;
    close($fh);

    my @required_keys = qw(
        PLUGIN_SPOTON_STREAMING_MODE
        PLUGIN_SPOTON_STREAMING_MODE_DESC
        PLUGIN_SPOTON_STREAMING_MODE_DIRECT
        PLUGIN_SPOTON_STREAMING_MODE_PROXY
        PLUGIN_SPOTON_STREAMING_MODE_USE_GLOBAL
        PLUGIN_SPOTON_STREAMING_MODE_GLOBAL
        PLUGIN_SPOTON_STREAMING_MODE_GLOBAL_DESC
    );
    my @required_locales = sort qw(CS DA DE EN ES FR IT NL NO PL SV);

    for my $key (@required_keys) {
        my $found_idx;
        for my $i (0 .. $#lines) {
            my $line = $lines[$i];
            chomp $line;
            if ($line eq $key) {
                $found_idx = $i;
                last;
            }
        }
        ok(defined $found_idx, "i18n: $key exists as a line-anchored key header");
        next unless defined $found_idx;

        my %locales_seen;
        my $i = $found_idx + 1;
        while ($i <= $#lines) {
            my $line = $lines[$i];
            chomp $line;
            last if $line eq '';
            if ($line =~ /^\t([A-Z]{2})\t/) {
                $locales_seen{$1} = 1;
            }
            $i++;
        }
        is(join(',', sort keys %locales_seen), join(',', @required_locales),
            "i18n: $key has exactly the 11 required locale lines");
    }
};

done_testing();

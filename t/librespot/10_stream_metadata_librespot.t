#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# Resolve project root (84-09: librespot half of t/10_stream_metadata.t --
# META-02/D-05 passthrough=1 => OGG needs the REAL Backend::Librespot
# capabilitiesDefault (a mock would make these two cells tautologies); the
# other 22 cells live in t/core/10_stream_metadata_core.t)
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

# Create a temporary directory for LMS stubs
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

# Stub: Slim::Utils::Accessor — hash-based replacement for LMS array-based accessor
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

# Stub: Slim::Networking::SimpleAsyncHTTP — DaemonManager.pm uses at module level
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
sub new  { bless {}, shift }
sub get  { }
sub post { }
1;
END

# Stub: Slim::Player::Sync — resolver uses slaves() for D-08 sync-group aggregation
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

# Stub: Slim::Utils::Network — Daemon.pm start() references serverAddr
write_stub($stub_dir, 'Slim::Utils::Network', <<'END');
package Slim::Utils::Network;
sub serverAddr { '127.0.0.1' }
1;
END

# Stub: Slim::Player::Client — DaemonManager runtime calls (not needed for resolver)
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

# Add to @INC
unshift @INC, $stub_dir, $project_dir;

# Pre-load the Helper stub so _typeString's require finds the stub, not the real module.
# The stub uses a package variable ($helperCapabilities) that tests can control.
require Plugins::SpotOn::Helper;

# Pre-load Slim::Player::Sync stub so the resolver's sync-group iteration works.
# The stub provides a controllable slaves() function for D-08 sync-group tests.
require Slim::Player::Sync;

# ============================================================
# Load Plugin.pm
# ============================================================
require_ok('Plugins::SpotOn::Plugin') or BAIL_OUT("Failed to load Plugin.pm");

# ============================================================
# Mock client object
# ============================================================
# A blessed hashref that the Prefs stub can stringify for client() namespace.
{
    package MockClient;
    use overload '""' => sub { ${$_[0]} }, fallback => 1;
    our %_model;    # id => model string, default 'squeezelite'
    our %_formats;  # id => arrayref, default ['ogg','pcm','flac','mp3']
    our %_synced;   # id => boolean
    our %_master;   # id => MockClient instance or undef
    sub new { my $id = $_[1] // 'player1'; bless \$id, $_[0] }
    # 79-34 D-29: real clients always have an id; the served resolver reaches helperForClient, which reads ->id
    sub id  { return ${$_[0]} }
    sub can {
        my ($self, $method) = @_;
        return 1 if $method eq 'master' && $_master{${$self}};
        return 0;
    }
    sub model   { return $_model{${$_[0]}}   // 'squeezelite' }
    sub formats { return @{ $_formats{${$_[0]}} // ['ogg','pcm','flac','mp3'] } }
    sub isSynced { return $_synced{${$_[0]}} // 0 }
    sub master  { return $_master{${$_[0]}} }
    sub playingSong { undef }
}

# ============================================================
# Helper to set prefs for a test case
# ============================================================
sub setup_prefs {
    my (%opts) = @_;
    my $prefs = Slim::Utils::Prefs::preferences('plugin.spoton');

    # Global prefs
    $prefs->set('bitrate', $opts{bitrate}) if exists $opts{bitrate};

    # Per-player prefs (if client provided)
    if ($opts{client}) {
        my $cp = $prefs->client($opts{client});
        $cp->set('bitrateOverride', $opts{bitrateOverride}) if exists $opts{bitrateOverride};
        $cp->set('streamFormat', $opts{streamFormat}) if exists $opts{streamFormat};
        $cp->set('connectOggOverride', $opts{connectOggOverride}) if exists $opts{connectOggOverride};

        # MockClient per-instance state (keyed by stringified client id)
        my $id = "${$opts{client}}";
        $MockClient::_model{$id}   = $opts{model}   if exists $opts{model};
        $MockClient::_formats{$id} = $opts{formats}  if exists $opts{formats};
        $MockClient::_synced{$id}  = $opts{synced}   if exists $opts{synced};
        $MockClient::_master{$id}  = $opts{master_client} if exists $opts{master_client};

        # Slim::Player::Sync slave list for sync-group tests (D-08)
        if (exists $opts{sync_slaves}) {
            $Slim::Player::Sync::_slaves{$id} = $opts{sync_slaves};
        }
    }

    # Helper passthrough capability
    if (exists $opts{passthrough}) {
        $Plugins::SpotOn::Helper::helperCapabilities = { passthrough => $opts{passthrough} };
    }
}

# ============================================================
# Test 1: _typeString returns format + mode only (LMS shows bitrate separately)
# ============================================================
{
    my $client = MockClient->new('player_ogg');
    setup_prefs(
        bitrate      => 320,
        client       => $client,
        streamFormat => 'ogg',
    );
    my $result = Plugins::SpotOn::Plugin->_typeString($client, 'Browse');
    is($result, 'OGG, SpotOn Browse',
        'META-02: streamFormat=ogg + passthrough=1 => "OGG, SpotOn Browse"');
}




# ============================================================
# Test 5: _typeString with streamFormat=auto + passthrough=1
# D-05: auto resolves to OGG when passthrough capability is true
# ============================================================
{
    my $client = MockClient->new('player_auto_pt');
    setup_prefs(
        client       => $client,
        streamFormat => 'auto',
        passthrough  => 1,
    );
    my $result = Plugins::SpotOn::Plugin->_typeString($client, 'Browse');
    is($result, 'OGG, SpotOn Browse',
        'D-05: streamFormat=auto + passthrough=1 => "OGG, SpotOn Browse"');
}
















done_testing();

#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

# Resolve the project root: t/ is directly under the project root
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname($test_dir);

my @pm_files = (
    "$project_dir/Plugins/SpotOn/Plugin.pm",
    "$project_dir/Plugins/SpotOn/ProtocolHandler.pm",
    "$project_dir/Plugins/SpotOn/Helper.pm",
    "$project_dir/Plugins/SpotOn/Soloist.pm",
    "$project_dir/Plugins/SpotOn/Settings.pm",
    "$project_dir/Plugins/SpotOn/API/TokenManager.pm",
    "$project_dir/Plugins/SpotOn/API/Client.pm",
    "$project_dir/Plugins/SpotOn/API/PKCE.pm",
    "$project_dir/Plugins/SpotOn/API/WebPlayer.pm",
    "$project_dir/Plugins/SpotOn/API/Credentials.pm",
    "$project_dir/Plugins/SpotOn/API/ProtobufLite.pm",
    "$project_dir/Plugins/SpotOn/API/Login5.pm",
    "$project_dir/Plugins/SpotOn/API/SpClient.pm",
    "$project_dir/Plugins/SpotOn/Settings/Callback.pm",
    "$project_dir/Plugins/SpotOn/Connect.pm",
    "$project_dir/Plugins/SpotOn/Connect/Daemon.pm",
    "$project_dir/Plugins/SpotOn/Status.pm",
    "$project_dir/Plugins/SpotOn/HomeExtras.pm",
    "$project_dir/Plugins/SpotOn/Unified/Daemon.pm",
    "$project_dir/t/21_webplayer_mint_errors.t",
);

# Check which files actually exist
my @found = grep { -f $_ } @pm_files;

if (!@found) {
    plan skip_all => '.pm files not yet present in this checkout — will pass after merge with plans 01-01 and 01-02';
}

plan tests => scalar(@found);

# Create a temporary directory with stub modules so perl -c can resolve
# LMS-specific modules. This mirrors what the LMS runtime provides.
# Outside the LMS process, constants like main::SCANNER, main::PERFMON,
# main::TRANSCODING, main::ISWINDOWS, main::ISMAC, main::WEBUI, main::INFOLOG
# are not defined, and base classes like Slim::Plugin::OPMLBased cannot be
# loaded because their transitive deps (Log::Log4perl, Path::Class) are absent.
my $stub_dir = tempdir(CLEANUP => 1);

# Helper: write a stub Perl module
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

# Stub: Log::Log4perl::Logger (base class that Slim::Utils::Log inherits)
write_stub($stub_dir, 'Log::Log4perl::Logger', <<'END');
package Log::Log4perl::Logger;
sub new { bless {}, shift }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Stub: Log::Log4perl (pulled in transitively)
write_stub($stub_dir, 'Log::Log4perl', <<'END');
package Log::Log4perl;
sub get_logger { return bless {}, 'Log::Log4perl::Logger' }
sub init { }
1;
END

# Stub: Path::Class (required by Slim::Music::Info)
write_stub($stub_dir, 'Path::Class', <<'END');
package Path::Class;
sub import { }
1;
END

# Stub: Path::Class::Dir
write_stub($stub_dir, 'Path::Class::Dir', <<'END');
package Path::Class::Dir;
sub new { bless {}, shift }
1;
END

# Stub: Path::Class::File
write_stub($stub_dir, 'Path::Class::File', <<'END');
package Path::Class::File;
sub new { bless {}, shift }
1;
END

# Stub: JSON::XS::VersionOneAndTwo (used by Helper.pm)
write_stub($stub_dir, 'JSON::XS::VersionOneAndTwo', <<'END');
package JSON::XS::VersionOneAndTwo;
use parent 'Exporter';
our @EXPORT = qw(from_json to_json);
sub from_json { }
sub to_json   { }
1;
END

# Stub: Slim::Utils::Log (provides logger(), addLogCategory())
# import() exports logger() into caller namespace so bare logger(...) calls work in API modules
write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub addLogCategory { return bless {}, 'Slim::Utils::Log' }
sub logger { return bless {}, 'Slim::Utils::Log' }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Stub: Slim::Utils::Prefs (provides preferences())
# import() exports preferences() into caller namespace so bare preferences(...) calls work
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

# Stub: Slim::Utils::Timers (needed by TokenManager, Client, and Plugin)
write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
sub setTimer   { }
sub killTimers { }
1;
END

# Stub: Slim::Utils::Cache (needed by TokenManager, Client, and Plugin)
write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
my %_store;
sub new    { bless {}, shift }
sub get    { $_store{$_[1]} }
sub set    { $_store{$_[1]} = $_[2]; 1 }
sub remove { delete $_store{$_[1]} }
1;
END

# Stub: Slim::Utils::Unicode (needed by TokenManager)
write_stub($stub_dir, 'Slim::Utils::Unicode', <<'END');
package Slim::Utils::Unicode;
sub utf8toLatin1Transliterate { $_[1] }
1;
END

# Stub: Slim::Networking::SimpleAsyncHTTP (needed by Client)
write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
sub new  { bless { _success => $_[1], _error => $_[2] }, shift }
sub get  { }
sub post { }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Stub: Slim::Utils::Strings
write_stub($stub_dir, 'Slim::Utils::Strings', <<'END');
package Slim::Utils::Strings;
use parent 'Exporter';
our @EXPORT_OK = qw(string cstring);
sub string  { }
sub cstring { }
1;
END

# Stub: Slim::Utils::Versions
write_stub($stub_dir, 'Slim::Utils::Versions', <<'END');
package Slim::Utils::Versions;
sub compareVersions { 0 }
1;
END

# Stub: Slim::Utils::Misc
write_stub($stub_dir, 'Slim::Utils::Misc', <<'END');
package Slim::Utils::Misc;
sub findbin { }
sub addFindBinPaths { }
1;
END

# Stub: Slim::Utils::OSDetect
write_stub($stub_dir, 'Slim::Utils::OSDetect', <<'END');
package Slim::Utils::OSDetect;
sub OS      { 'unix' }
sub details { return { osArch => 'x86_64' } }
sub getOS   { return bless {}, 'Slim::Utils::OSDetect' }
sub decodeExternalHelperPath { $_[1] }
1;
END

# Stub: Slim::Plugin::OPMLBased (base of Plugin.pm)
write_stub($stub_dir, 'Slim::Plugin::OPMLBased', <<'END');
package Slim::Plugin::OPMLBased;
sub new        { bless {}, shift }
sub initPlugin { }
sub _pluginDataFor { }
sub AUTOLOAD   { }
sub can        { 1 }
1;
END

# Stub: Slim::Formats::RemoteStream (base of ProtocolHandler.pm)
write_stub($stub_dir, 'Slim::Formats::RemoteStream', <<'END');
package Slim::Formats::RemoteStream;
sub new      { bless {}, shift }
sub AUTOLOAD { }
sub can      { 1 }
1;
END

# Stub: Slim::Player::ProtocolHandlers
write_stub($stub_dir, 'Slim::Player::ProtocolHandlers', <<'END');
package Slim::Player::ProtocolHandlers;
sub registerHandler { }
1;
END

# Stub: Slim::Web::Settings (base of Settings.pm)
write_stub($stub_dir, 'Slim::Web::Settings', <<'END');
package Slim::Web::Settings;
sub new     { bless {}, shift }
sub handler { }
sub AUTOLOAD { }
sub can     { 1 }
1;
END

# Stub: Slim::Web::HTTP (needed by Status.pm _jsonResponse)
write_stub($stub_dir, 'Slim::Web::HTTP', <<'END');
package Slim::Web::HTTP;
sub addHTTPResponse { }
1;
END

# Stub: Slim::Web::HTTP::CSRF
write_stub($stub_dir, 'Slim::Web::HTTP::CSRF', <<'END');
package Slim::Web::HTTP::CSRF;
sub protectName { $_[1] }
sub protectURI  { $_[1] }
1;
END

# Stub: Slim::Web::Pages (needed by Settings/Callback.pm and Status.pm)
write_stub($stub_dir, 'Slim::Web::Pages', <<'END');
package Slim::Web::Pages;
sub addPageFunction { }
sub addRawFunction  { }
1;
END

# Stub: Slim::Utils::Accessor (base class for Connect/Daemon.pm)
write_stub($stub_dir, 'Slim::Utils::Accessor', <<'END');
package Slim::Utils::Accessor;
sub new { bless {}, shift }
sub mk_accessor { }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Stub: Slim::Player::Client (Daemon.pm calls getClient() at runtime)
write_stub($stub_dir, 'Slim::Player::Client', <<'END');
package Slim::Player::Client;
sub getClient { undef }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Stub: Slim::Player::Sync (Daemon.pm calls syncname() at runtime)
write_stub($stub_dir, 'Slim::Player::Sync', <<'END');
package Slim::Player::Sync;
sub syncname { '' }
1;
END

# Stub: Slim::Control::Request (Connect.pm uses for event dispatch/subscription)
write_stub($stub_dir, 'Slim::Control::Request', <<'END');
package Slim::Control::Request;
sub new { bless {}, shift }
sub addDispatch { }
sub subscribe { }
sub unsubscribe { }
sub notifyFromArray { }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Stub: Slim::Music::Info (Connect.pm references for metadata)
write_stub($stub_dir, 'Slim::Music::Info', <<'END');
package Slim::Music::Info;
sub setCurrentTitle { }
sub setRemoteMetadata { }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Stub: Slim::Player::Source (Connect.pm calls songTime())
write_stub($stub_dir, 'Slim::Player::Source', <<'END');
package Slim::Player::Source;
sub songTime { 0 }
1;
END

# Stub: Plugins::MaterialSkin::HomeExtraBase (base class for SpotOn HomeExtras)
# perl -c compiles `use base` at BEGIN time but does not execute runtime
# statements, so a minimal stub suffices.
write_stub($stub_dir, 'Plugins::MaterialSkin::HomeExtraBase', <<'END');
package Plugins::MaterialSkin::HomeExtraBase;
sub initPlugin { 1 }
1;
END

# Define main:: constants that LMS plugins use
my $main_constants = join(' ', map { "-e 'use constant $_ => 0;'" }
    qw(TRANSCODING WEBUI SCANNER INFOLOG ISWINDOWS ISMAC PERFMON));

# Build the include path: stubs first, then project root, then LMS system path
my $inc = "-I$stub_dir -I$project_dir -I/usr/share/squeezeboxserver";

for my $pm_file (@found) {
    my $basename = (split m{/}, $pm_file)[-1];

    my $cmd    = "perl $inc $main_constants -c \"$pm_file\" 2>&1";
    my $output = `$cmd`;
    my $exit   = $? >> 8;

    is($exit, 0, "$basename passes perl -c syntax check")
        or diag("perl -c output:\n$output");
}

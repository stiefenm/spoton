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

# Cache dir for mock tests (Slim::Utils::Prefs->preferences('server')->get('cachedir'))
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
# LMS Module Stubs required by Credentials.pm
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
our @EXPORT_OK = qw(logger);
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub addLogCategory {
    return bless {}, 'Slim::Utils::Log';
}
sub logger {
    return bless {}, 'Slim::Utils::Log';
}
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

# Stub: Slim::Utils::Prefs
my $prefs_cache_dir = $cache_dir;
write_stub($stub_dir, 'Slim::Utils::Prefs', <<"END");
package Slim::Utils::Prefs;
my \%_store;
my \%_ns_store = ( server => { cachedir => '$prefs_cache_dir' } );

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
    if (exists \$_ns_store{ \$self->{_ns} }) {
        return \$_ns_store{ \$self->{_ns} }{\$key};
    }
    return \$_store{ \$self->{_ns} }{\$key};
}

sub set {
    my (\$self, \$key, \$val) = \@_;
    \$_store{ \$self->{_ns} }{\$key} = \$val;
}

sub client { return bless { _ns => \$_[0]->{_ns} . '_client' }, 'Slim::Utils::Prefs' }
sub setChange { }
sub AUTOLOAD  { }
1;
END

# Stub: Slim::Utils::Timers (unused by classifier but required transitively)
write_stub($stub_dir, 'Slim::Utils::Timers', <<'END');
package Slim::Utils::Timers;
sub setTimer  { }
sub killTimers { }
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

# Stub: Slim::Utils::Cache (GH #147: Credentials.pm stores the persistent
# playback-auth flag here -- must shadow any system-installed Slim)
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
# Credentials.pm resolves it via a fully-qualified call at load time (GH #147
# playback-auth flag cache). Production always compiles Plugin.pm first --
# provide the constant for standalone loads (same pattern as t/16).
BEGIN {
    package Plugins::SpotOn::Plugin;
    use constant SPOTON_CACHE_VERSION => 4;
}

# ============================================================
# Add stub_dir and project_dir to @INC (stub_dir first so our stubs shadow
# real modules)
# ============================================================
unshift @INC, $stub_dir, $project_dir;

require Slim::Utils::Prefs;
Slim::Utils::Prefs->import();
require Slim::Utils::Log;
Slim::Utils::Log->import();

# ============================================================
# Load the module under test
# ============================================================
require_ok('Plugins::SpotOn::API::Credentials')
    or BAIL_OUT("Failed to load Plugins::SpotOn::API::Credentials");

# ============================================================
# D-02: classifyAudioKeyError -- 7 documented behaviors
# ============================================================

is(Plugins::SpotOn::API::Credentials->classifyAudioKeyError('error audio key 0 1'),
    'denied',
    'Test 1: exact "error audio key 0 1" signature classifies as denied');

is(Plugins::SpotOn::API::Credentials->classifyAudioKeyError("lots of output\nerror audio key 0 1\nmore output"),
    'denied',
    'Test 2: "error audio key 0 1" embedded in surrounding stderr noise classifies as denied');

is(Plugins::SpotOn::API::Credentials->classifyAudioKeyError('error audio key 0 2'),
    'throttled',
    'Test 3: exact "error audio key 0 2" signature classifies as throttled');

is(Plugins::SpotOn::API::Credentials->classifyAudioKeyError('some random stderr text'),
    undef,
    'Test 4: unrecognized stderr text classifies as undef');

is(Plugins::SpotOn::API::Credentials->classifyAudioKeyError(undef),
    undef,
    'Test 5: undef input classifies as undef');

is(Plugins::SpotOn::API::Credentials->classifyAudioKeyError(''),
    undef,
    'Test 6: empty string input classifies as undef');

is(Plugins::SpotOn::API::Credentials->classifyAudioKeyError("error audio key 0 1\nerror audio key 0 2"),
    'denied',
    'Test 7: when both signatures are present, permanent denial takes priority');

done_testing();

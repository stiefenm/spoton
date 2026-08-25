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

my $module = "$project_dir/Plugins/SpotOn/ProtocolHandler.pm";
unless (-f $module) {
    plan skip_all => 'Plugins/SpotOn/ProtocolHandler.pm not yet present in this checkout';
}

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
# LMS module stubs required to load ProtocolHandler.pm in isolation
# (Phase 72 Wave-0 gap -- ProtocolHandler.pm has never had dedicated test
# coverage before this plan; t/28's write_stub pattern is copied verbatim).
# ============================================================

write_stub($stub_dir, 'Log::Log4perl::Logger', <<'END');
package Log::Log4perl::Logger;
sub new { bless {}, shift }
sub AUTOLOAD { }
sub can { 1 }
1;
END

write_stub($stub_dir, 'Log::Log4perl', <<'END');
package Log::Log4perl;
sub get_logger { return bless {}, 'Log::Log4perl::Logger' }
sub init { }
1;
END

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
sub logger { return bless {}, 'Slim::Utils::Log' }
sub info  { }
sub warn  { }
sub error { }
sub debug { }
sub is_info  { 1 }
sub is_debug { 0 }
sub is_warn  { 1 }
sub AUTOLOAD { }
sub can { 1 }
1;
END

# Controllable Prefs stub -- get() reads from a controllable %FAKE hash so
# individual test cases can flip 'backend' without touching the real
# Slim::Utils::Prefs machinery.
write_stub($stub_dir, 'Slim::Utils::Prefs', <<'END');
package Slim::Utils::Prefs;
our %FAKE;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::preferences"} = \&preferences;
}
sub preferences { return bless { _ns => $_[0] }, 'Slim::Utils::Prefs' }
sub get    { my ($self, $key) = @_; return $FAKE{$key}; }
sub set    { my ($self, $key, $val) = @_; $FAKE{$key} = $val; }
sub client { return bless {}, 'Slim::Utils::Prefs' }
sub setChange { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Strings', <<'END');
package Slim::Utils::Strings;
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::cstring"} = sub { '' };
    *{"${caller}::string"}  = sub { '' };
}
1;
END

write_stub($stub_dir, 'Slim::Utils::Versions', <<'END');
package Slim::Utils::Versions;
sub compareVersions { return 1 }
1;
END

write_stub($stub_dir, 'Slim::Utils::Cache', <<'END');
package Slim::Utils::Cache;
sub new    { return bless {}, shift }
sub get    { return undef }
sub set    { }
sub remove { }
1;
END

write_stub($stub_dir, 'Slim::Utils::Network', <<'END');
package Slim::Utils::Network;
sub serverAddr { return '127.0.0.1' }
1;
END

write_stub($stub_dir, 'Slim::Utils::Misc', <<'END');
package Slim::Utils::Misc;
sub crackURL         { return ('127.0.0.1', 80, '/') }
sub findbin           { }
sub addFindBinPaths   { }
1;
END

write_stub($stub_dir, 'Slim::Music::Info', <<'END');
package Slim::Music::Info;
sub setCurrentTitle { }
1;
END

write_stub($stub_dir, 'Slim::Schema::RemoteTrack', <<'END');
package Slim::Schema::RemoteTrack;
sub fetch { return undef }
1;
END

write_stub($stub_dir, 'Slim::Formats::RemoteStream', <<'END');
package Slim::Formats::RemoteStream;
sub new      { return bless {}, shift }
sub AUTOLOAD { }
sub can      { 1 }
1;
END

write_stub($stub_dir, 'Slim::Player::Protocols::HTTP', <<'END');
package Slim::Player::Protocols::HTTP;
sub new { return bless {}, shift }
1;
END

# Minimal stand-in -- ProtocolHandler.pm only needs the CACHE_VERSION
# constant at load time (Cache->new('spoton', SPOTON_CACHE_VERSION())).
write_stub($stub_dir, 'Plugins::SpotOn::Plugin', <<'END');
package Plugins::SpotOn::Plugin;
use constant SPOTON_CACHE_VERSION => 4;
sub _pluginDataFor { return 'test-basedir' }
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
    *main::PERFMON     = sub () { 0 };
    *main::ISWINDOWS   = sub () { 0 };
    *main::ISMAC       = sub () { 0 };
}

# canSeek()'s librespot branch compares $::VERSION -- fix it to a value the
# real Slim::Utils::Versions stub is happy with regardless (stub always
# returns 1), but set a plausible LMS version string for realism.
our $VERSION;
$::VERSION = '9.0.0';

unshift @INC, $stub_dir, $project_dir;

# ProtocolHandler.pm calls Plugins::SpotOn::Plugin::SPOTON_CACHE_VERSION()
# as a fully-qualified sub at load time -- pre-load the stub so Perl doesn't
# need an implicit require for it.
require_ok('Plugins::SpotOn::Plugin')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Plugin stub");

require_ok('Plugins::SpotOn::ProtocolHandler')
    or BAIL_OUT("Failed to load Plugins::SpotOn::ProtocolHandler");

# new()'s fallthrough calls Slim::Player::Protocols::HTTP->new($args) as a
# fully-qualified call, never require'd by ProtocolHandler.pm itself --
# pre-load the stub so that call resolves.
require_ok('Slim::Player::Protocols::HTTP')
    or BAIL_OUT("Failed to load Slim::Player::Protocols::HTTP stub");

sub reset_backend {
    my ($value) = @_;
    if (defined $value) {
        $Slim::Utils::Prefs::FAKE{backend} = $value;
    } else {
        delete $Slim::Utils::Prefs::FAKE{backend};
    }
}

my $pkg = 'Plugins::SpotOn::ProtocolHandler';

# Plain blessed hash -- the soloist gate in canDirectStream() sits before
# any per-client pref access (->can('master'), streamingMode, etc.), so no
# richer client double is required.
my $clientStub = bless {}, 'FakeClient';

# ============================================================
# backend = 'soloist' (D-01/D-02/D-03/Pitfall 3)
# ============================================================
{
    reset_backend('soloist');

    is($pkg->contentType(), 'sol', "contentType() eq 'sol' when backend=soloist");

    is($pkg->getFormatForURL('spoton://track:abc123'), 'sol',
        "getFormatForURL(track) eq 'sol' when backend=soloist");
    is($pkg->getFormatForURL('spoton://episode:abc123'), 'sol',
        "getFormatForURL(episode) eq 'sol' when backend=soloist");

    is($pkg->canDirectStream($clientStub, 'spoton://track:abc123'), 0,
        "canDirectStream() == 0 for Browse URL when backend=soloist (D-03)");

    is($pkg->canSeek($clientStub), 0,
        "canSeek() == 0 when backend=soloist (Pitfall 3)");

    my $streamObj = $pkg->new({ url => 'spoton://track:abc123', client => undef });
    ok(defined $streamObj, "new({url => spoton://track:..., client => undef}) is defined when backend=soloist");
}

# ============================================================
# backend = 'librespot' (pre-phase behavior unchanged)
# ============================================================
{
    reset_backend('librespot');

    is($pkg->contentType(), 'son', "contentType() eq 'son' when backend=librespot");

    is($pkg->getFormatForURL('spoton://track:abc123'), 'soc',
        "getFormatForURL(track) eq 'soc' when backend=librespot (pre-phase behavior)");

    ok($pkg->canSeek($clientStub), "canSeek() truthy when backend=librespot");
}

# ============================================================
# backend unset (default -> librespot behavior)
# ============================================================
{
    reset_backend(undef);

    is($pkg->contentType(), 'son', "contentType() eq 'son' when backend is unset (default librespot)");

    is($pkg->getFormatForURL('spoton://track:abc123'), 'soc',
        "getFormatForURL(track) eq 'soc' when backend is unset (default librespot)");

    ok($pkg->canSeek($clientStub), "canSeek() truthy when backend is unset (default librespot)");
}

done_testing();

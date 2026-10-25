#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Find qw(find);
use Cwd qw(abs_path);

# Resolve the project root (t/<group>/x.t sits two levels below it)
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";

# ============================================================
# 84-09 (todo t05-perl-syntax-check-ist-ein-no-op): a REAL compile of every
# product module. The old chain put `-e 'use constant ...'` snippets before
# the file, so perl compiled only the snippets and never the file (a broken
# Status.pm still read `ok 16 - Status.pm passes perl -c syntax check`). The
# main:: constants now come from a stub module loaded with -M, so
# `perl -c <file>` compiles the file itself, and every module must say
# `syntax OK`.
#
# The module list and its fence are DERIVED, never a fixed number:
#   <root> = $ENV{SPOTON_MODULE_ROOT} || the project root (the red-copy hook)
#   * <root>/tools/ci/amputation/core.files (84-12): every listed module
#     must be present AND compile; a missing or empty core.files dies.
#   * librespot.files / soloist.files: every listed module (directory lines
#     end in /) compiles when present; an absent one prints
#     `# optional (amputation): <path>` (amputated tree) -- never a skip.
#   * t/core/66_made_for_you.t always compiles (85-12: replaces the deleted
#     t/core/21_webplayer_mint_errors.t, same fence), from the PROJECT
#     root (never <root>): it is a test, not a product module.
#   * fence: compiled >= count(core.files) + 1, count(core.files) >= 1.
# ============================================================
my $root = (defined $ENV{SPOTON_MODULE_ROOT} && length $ENV{SPOTON_MODULE_ROOT})
    ? $ENV{SPOTON_MODULE_ROOT} : $project_dir;
my $amp  = "$root/tools/ci/amputation";

sub manifest_lines {
    my ($file) = @_;
    open(my $fh, '<', $file) or die "amputation manifest missing: $file\n";
    my @l = grep { length && !/^\s*#/ } map { s/\s+\z//r } <$fh>;
    close($fh);
    return @l;
}

my @core = manifest_lines("$amp/core.files");
die "core.files is empty: $amp/core.files\n" unless @core;

# [ label, absolute path, required ]
my @targets = map { [ ($_ =~ s{^Plugins/SpotOn/}{}r), "$root/$_", 1 ] } @core;
my @optional_absent;
for my $side (qw(librespot soloist)) {
    for my $line (manifest_lines("$amp/$side.files")) {
        my $abs = "$root/$line";
        if ($line =~ m{/\z}) {
            if (!-d $abs) { push @optional_absent, $line; next; }
            my @pm;
            find(sub { push @pm, $File::Find::name if -f $_ && /\.pm\z/ }, $abs);
            for my $f (sort @pm) {
                (my $rel = $f) =~ s{^\Q$root\E/}{};
                push @targets, [ ($rel =~ s{^Plugins/SpotOn/}{}r), $f, 0 ];
            }
        }
        elsif ($line =~ /\.p[ml]\z/) {
            if (-f $abs) { push @targets, [ ($line =~ s{^Plugins/SpotOn/}{}r), $abs, 0 ] }
            else         { push @optional_absent, $line }
        }
    }
}
push @targets, [ 't/core/66_made_for_you.t', "$project_dir/t/core/66_made_for_you.t", 1 ];

diag("optional (amputation): $_") for @optional_absent;

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

# main:: constants that LMS plugins use -- a stub module loaded with -M, so
# the file named after -c stays perl's only program source (84-09).
# It also makes the compile hermetic: an @INC hook dies on any Slim:: or
# MaterialSkin module that has no stub here, so the compile can never reach
# an installed LMS (present on a dev host, absent on CI) and reads the same
# everywhere.
write_stub($stub_dir, 'SpotOnMainConstants', <<'END' . "my \$STUBS = '$stub_dir';\n" . <<'END2');
package main;
use constant TRANSCODING => 0;
use constant WEBUI       => 0;
use constant SCANNER     => 0;
use constant INFOLOG     => 0;
use constant DEBUGLOG    => 0;
use constant ISWINDOWS   => 0;
use constant ISMAC       => 0;
use constant PERFMON     => 0;
END
BEGIN {
    unshift @INC, sub {
        my (undef, $f) = @_;
        return unless $f =~ m{^(?:Slim|Plugins/MaterialSkin)/};
        return if -f "$STUBS/$f";
        die "t/05: no stub for LMS module $f -- the compile must not reach an installed LMS\n";
    };
}
1;
END2

# Stubs the real compile needs beyond the historic set (84-09).
write_stub($stub_dir, 'JSON::XS', <<'END');
package JSON::XS;
sub new { bless {}, shift }
sub AUTOLOAD { }
sub can { 1 }
sub encode_json { '{}' }
sub decode_json { {} }
sub import {
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::encode_json"} = \&encode_json;
    *{"${caller}::decode_json"} = \&decode_json;
}
1;
END

write_stub($stub_dir, 'Slim::Player::Playlist', <<'END');
package Slim::Player::Playlist;
sub AUTOLOAD { }
sub can { 1 }
1;
END

write_stub($stub_dir, 'Slim::Networking::Select', <<'END');
package Slim::Networking::Select;
sub addRead    { }
sub removeRead { }
sub AUTOLOAD   { }
sub can        { 1 }
1;
END

write_stub($stub_dir, 'Slim::Utils::Network', <<'END');
package Slim::Utils::Network;
sub serverAddr { '127.0.0.1' }
1;
END

write_stub($stub_dir, 'Slim::Plugin::DontStopTheMusic::Plugin', <<'END');
package Slim::Plugin::DontStopTheMusic::Plugin;
sub registerHandler { }
1;
END

# Include path: stubs first, then the module root, the vendored library root
# (Plugins/SpotOn/Vendor is its own root, Soloist::ensureWsLib), then the
# LMS-bundled CPAN path.
my @inc = ("-I$stub_dir", "-I$root");
push @inc, "-I$root/Plugins/SpotOn/Vendor" if -d "$root/Plugins/SpotOn/Vendor";
push @inc, '-I/usr/share/squeezeboxserver/CPAN', '-I/usr/share/squeezeboxserver';

my $compiled = 0;
for my $t (@targets) {
    my ($label, $file, $required) = @$t;
    if (!-f $file) {
        fail("$label passes perl -c syntax check");
        diag($required ? "listed in core.files but missing: $file" : "missing: $file");
        next;
    }
    my $pid = open(my $out, '-|');
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        open(STDERR, '>&', \*STDOUT);
        exec($^X, @inc, '-MSpotOnMainConstants', '-c', $file) or die "exec: $!";
    }
    my $output = do { local $/; <$out> };
    close($out);
    my $exit = $? >> 8;
    my $ok = ($exit == 0 && $output =~ /syntax OK/) ? 1 : 0;
    $compiled++ if $ok;
    ok($ok, "$label passes perl -c syntax check")
        or diag("perl -c output (exit $exit):\n$output");
}

# Fence: derived from core.files -- an empty or shrunken sweep cannot pass.
cmp_ok(scalar(@core), '>=', 1, 'core.files lists at least one module');
cmp_ok($compiled, '>=', scalar(@core) + 1,
    'compiled >= count(core.files) + 1 (every core module plus t/core/66)');

done_testing();

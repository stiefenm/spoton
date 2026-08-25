#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use File::Spec::Functions qw(catdir catfile);

# Resolve project root: t/ is directly under the project root
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname($test_dir);

my $module = "$project_dir/Plugins/SpotOn/Soloist.pm";
unless (-f $module) {
    plan skip_all => 'Plugins/SpotOn/Soloist.pm not yet present in this checkout';
}

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

# ============================================================
# LMS Module Stubs required by Soloist.pm
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

# Records every info/warn/error/debug message into @logged so Test 6 (T-71-02)
# can assert the raw spak-key never appears in any log line.
write_stub($stub_dir, 'Slim::Utils::Log', <<'END');
package Slim::Utils::Log;
use parent 'Exporter';
our @EXPORT_OK = qw(logger);
our @logged = ();
sub import {
    my $class = shift;
    my $caller = caller;
    no strict 'refs';
    *{"${caller}::logger"} = \&logger;
}
sub addLogCategory { return bless {}, 'Slim::Utils::Log' }
sub logger { return bless {}, 'Slim::Utils::Log' }
sub info  { push @logged, $_[1] if defined $_[1]; }
sub warn  { push @logged, $_[1] if defined $_[1]; }
sub error { push @logged, $_[1] if defined $_[1]; }
sub debug { push @logged, $_[1] if defined $_[1]; }
sub is_info  { 1 }
sub is_debug { 0 }
sub AUTOLOAD { }
sub can { 1 }
1;
END

my $prefs_cache_dir = $cache_dir;
write_stub($stub_dir, 'Slim::Utils::Prefs', <<"END");
package Slim::Utils::Prefs;
my \%_store;
my \%_ns_store = ( server => { cachedir => '$prefs_cache_dir' } );
my \%_change_cbs;

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
    if (\$_change_cbs{ \$self->{_ns} }{\$key}) {
        \$_->(\$self, \$val) for \@{ \$_change_cbs{ \$self->{_ns} }{\$key} };
    }
}

sub client { return bless { _ns => \$_[0]->{_ns} . '_client' }, 'Slim::Utils::Prefs' }

sub setChange {
    my (\$self, \$cb, \$key) = \@_;
    push \@{ \$_change_cbs{ \$self->{_ns} }{\$key} }, \$cb;
}

sub AUTOLOAD  { }
1;
END

write_stub($stub_dir, 'Slim::Utils::OSDetect', <<'END');
package Slim::Utils::OSDetect;
our $osArch = 'x86_64';
sub details { return { osArch => $osArch } }
sub OS      { 'unix' }
sub getOS   { return bless {}, 'Slim::Utils::OSDetect' }
1;
END

write_stub($stub_dir, 'Slim::Networking::SimpleAsyncHTTP', <<'END');
package Slim::Networking::SimpleAsyncHTTP;
sub new { bless {}, shift }
sub get { }
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

unshift @INC, $stub_dir, $project_dir;

require Slim::Utils::Prefs;
Slim::Utils::Prefs->import();
require Slim::Utils::Log;
Slim::Utils::Log->import();
require Slim::Utils::OSDetect;
require Slim::Networking::SimpleAsyncHTTP;

require_ok('Plugins::SpotOn::Soloist')
    or BAIL_OUT("Failed to load Plugins::SpotOn::Soloist");

my $TEST_KEY = 'spak_' . ('X' x 40) . '_super_secret_key_value';

# ============================================================
# Test 1: hasKey() is false before any key is stored
# ============================================================
{
    is(Plugins::SpotOn::Soloist::hasKey(), 0, 'hasKey() is false before storeKey()');
}

# ============================================================
# Test 2: storeKey() writes the file with mode exactly 0600
# ============================================================
{
    my @result = Plugins::SpotOn::Soloist->storeKey($TEST_KEY);
    ok($result[0], 'storeKey() reports success') or diag(explain(\@result));

    my $path = Plugins::SpotOn::Soloist::keyPath();
    ok(-f $path, 'spak.key file exists after storeKey()');

    my $mode = (stat($path))[2] & 0777;
    is($mode, 0600, 'spak.key file mode is exactly 0600');
}

# ============================================================
# Test 3: hasKey() is true after storeKey()
# ============================================================
{
    is(Plugins::SpotOn::Soloist::hasKey(), 1, 'hasKey() is true after storeKey()');
}

# ============================================================
# Test 4: stored content round-trips exactly (no corruption/truncation)
# ============================================================
{
    my $path = Plugins::SpotOn::Soloist::keyPath();
    open(my $fh, '<', $path) or die "cannot read $path: $!";
    local $/;
    my $content = <$fh>;
    close($fh);
    is($content, $TEST_KEY, 'stored spak.key content matches the value passed to storeKey()');
}

# ============================================================
# Test 5: re-storing (overwrite) replaces content and keeps mode 0600
# ============================================================
{
    my $newKey = 'spak_' . ('Y' x 40) . '_rotated_key';
    my @result = Plugins::SpotOn::Soloist->storeKey($newKey);
    ok($result[0], 'storeKey() succeeds on overwrite');

    my $path = Plugins::SpotOn::Soloist::keyPath();
    my $mode = (stat($path))[2] & 0777;
    is($mode, 0600, 'spak.key file mode remains 0600 after overwrite');

    open(my $fh, '<', $path) or die $!;
    local $/;
    my $content = <$fh>;
    close($fh);
    is($content, $newKey, 'overwritten spak.key content matches the new value');
}

# ============================================================
# Test 6: the raw key is NEVER logged (T-71-02)
# ============================================================
{
    @Slim::Utils::Log::logged = ();
    Plugins::SpotOn::Soloist->storeKey($TEST_KEY);

    my $leaked = grep { index($_, $TEST_KEY) >= 0 } @Slim::Utils::Log::logged;
    ok(!$leaked, 'storeKey() never logs the raw key value (T-71-02)');
}

# ============================================================
# Test 7: source code never interpolates the key variable into a $log call
# (static grep, defense-in-depth beyond the runtime assertion above)
# ============================================================
{
    my $src = do {
        local $/;
        open(my $fh, '<', "$project_dir/Plugins/SpotOn/Soloist.pm") or die $!;
        <$fh>;
    };
    unlike($src, qr/\$log->(?:info|warn|error|debug)\([^)]*\$key\b/,
        'no $log call interpolates the $key variable');
}

# ============================================================
# Test 8: write path is atomic (staging + rename), never an in-place '>' open
# on the target file (code-assertion: no direct open(..., '>', $target))
# ============================================================
{
    my $src = do {
        local $/;
        open(my $fh, '<', "$project_dir/Plugins/SpotOn/Soloist.pm") or die $!;
        <$fh>;
    };
    unlike($src, qr/open\([^)]*'>'\s*,\s*\$target\)/, 'no in-place open(..., ">", $target) write to the key target path');
    like($src, qr/File::Temp::tempfile\('spak-XXXX'/, 'storeKey() stages via File::Temp::tempfile()');
    like($src, qr/rename\(\$staging,\s*\$target\)/, 'storeKey() installs atomically via rename()');
}

# ============================================================
# Test 9: clearKey() removes the file; hasKey() becomes false
# ============================================================
{
    Plugins::SpotOn::Soloist::clearKey();
    is(Plugins::SpotOn::Soloist::hasKey(), 0, 'hasKey() is false after clearKey()');
    ok(!-f Plugins::SpotOn::Soloist::keyPath(), 'spak.key file is removed after clearKey()');
}

# ============================================================
# Test 10: clearKey() on an already-absent key is a safe no-op
# ============================================================
{
    my $ok = eval { Plugins::SpotOn::Soloist::clearKey(); 1 };
    ok($ok, 'clearKey() does not die when no key file is present') or diag($@);
    is(Plugins::SpotOn::Soloist::hasKey(), 0, 'hasKey() remains false');
}

# ============================================================
# Test 11: storeKey() rejects an empty/undef key without writing a file
# ============================================================
{
    my @result = Plugins::SpotOn::Soloist->storeKey('');
    ok(!$result[0], 'storeKey("") fails');
    is(Plugins::SpotOn::Soloist::hasKey(), 0, 'no key file is created for an empty key');

    @result = Plugins::SpotOn::Soloist->storeKey(undef);
    ok(!$result[0], 'storeKey(undef) fails');
}

done_testing();

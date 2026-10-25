#!/usr/bin/perl
#
# tools/ci/refcheck.pl -- static reference gate of the backend seam
# (84-12, SEAM-6.3.1/6.3.2; finished green by 84-13, run in CI by 84-10).
#
# Warum: Stubs in den Tests verdecken, dass eine Backend-Seite fehlt. Nach
# tools/ci/amputate.sh darf KEIN verbliebenes Modul unter Plugins/SpotOn einen
# Paketnamen der entfernten Seite nennen (ausser den Bereichen in
# tools/ci/amputation/allow.txt), und jedes verbliebene Modul muss ein echtes
# `perl -c` bestehen.
#
# Aufruf (root = Wurzel der Wegwerfkopie, Default .):
#   refcheck.pl --collect <side> [root]
#       VOR dem Loeschen: leitet die entfernten Paketnamen aus dem Manifest ab
#       (Datei -> ihre `package`-Zeilen; Verzeichnis -> jede .pm darunter,
#       per File::Find ueber den Baum, nie git ls-files: eine git-archive-Kopie
#       hat kein .git) und schreibt sie nach <root>/.refcheck-<side>.names.
#       Ausgabe: COLLECTED <side> names=<n> files=<m>  | MISSING <pfad> (Exit 1)
#   refcheck.pl <side> [root]
#       NACH amputate.sh: Zaun (jede core.files-Datei vorhanden, gescannte
#       Anzahl >= Anzahl core.files), Namenssuche ueber jede verbliebene
#       Plugins/SpotOn/**/*.pm (nur Nicht-Kommentarzeilen, Paketgrenze
#       \bNAME(?![A-Za-z0-9_]) -- Plugins::SpotOn::Unified::Daemon trifft
#       Unified::Daemon->new und isa('...Unified::Daemon'), aber NICHT
#       Unified::DaemonManager), dann `perl -c` jedes verbliebenen Moduls
#       gegen generierte LMS-Stubs.
#       Zeilen:  REFCHECK FAIL <file>:<line>: <name>
#                ALLOWED <file>:<line> <reason>
#                REFCHECK FENCE <grund>
#       Letzte Zeile: REFCHECK PASS <side> modules=<n> allowed=<k>
#                 oder REFCHECK FAIL <side> hits=<n>
#   refcheck.pl --core-only [root]
#       G2X-Bericht ohne Amputation: Soloist-Familie (Plugins::SpotOn::Soloist)
#       in den sieben Kerndateien (ProtocolHandler, Connect, Plugin, Status,
#       Settings, Settings/Player, DaemonManager), mit denselben
#       allow.txt-Bereichen. Helper.pm ist Kern und kein Backend-Name
#       (Nutzerentscheidung 2026-10-11, 84-13).
#       Zeilen: G2X HIT <file>:<line>: <name> | G2X ALLOWED <file>:<line> <reason>
#       Letzte Zeile: G2X PASS files=<n> allowed=<k> | G2X FAIL hits=<n>
#   refcheck.pl --core-files [root]
#       Erzeugt <root>/tools/ci/amputation/core.files: jede
#       Plugins/SpotOn/**/*.pm, die unter KEINEM der beiden Manifeste liegt.
#       Ausgabe: CORE_FILES n=<n>
#
# Exit: 0 = PASS | 1 = Befund (FAIL/MISSING) | 2 = Aufruf-/Eingabefehler
#
# Pure Perl 5.10, nur Kernmodule (File::Find, File::Temp, File::Spec).

use strict;
use warnings;
use File::Find ();
use File::Spec;
use File::Temp qw(tempdir);

my @SIDES = qw(librespot soloist);

my @CORE_ONLY_FILES = qw(
    Plugins/SpotOn/ProtocolHandler.pm
    Plugins/SpotOn/Connect.pm
    Plugins/SpotOn/Plugin.pm
    Plugins/SpotOn/Status.pm
    Plugins/SpotOn/Settings.pm
    Plugins/SpotOn/Settings/Player.pm
    Plugins/SpotOn/Unified/DaemonManager.pm
);
my @CORE_ONLY_NAMES = qw(Plugins::SpotOn::Soloist);

sub usage {
    print STDERR "usage: refcheck.pl --collect <side> [root] | refcheck.pl <side> [root]\n"
               . "       refcheck.pl --core-only [root] | refcheck.pl --core-files [root]\n";
    exit 2;
}

my $mode = 'check';
if (@ARGV && $ARGV[0] =~ /^--(collect|core-only|core-files)$/) {
    $mode = $1;
    shift @ARGV;
}

if ($mode eq 'core-only') {
    my $root = shift(@ARGV) // '.';
    exit core_only($root);
}
if ($mode eq 'core-files') {
    my $root = shift(@ARGV) // '.';
    exit write_core_files($root);
}

my $side = shift(@ARGV) // usage();
usage() unless grep { $_ eq $side } @SIDES;
my $root = shift(@ARGV) // '.';

exit($mode eq 'collect' ? collect($side, $root) : check($side, $root));

# ---------------------------------------------------------------------------

sub read_manifest {
    my ($root, $side) = @_;
    my $path = "$root/tools/ci/amputation/$side.files";
    open(my $fh, '<', $path) or do { print "MISSING $path\n"; return; };
    my @entries;
    while (my $l = <$fh>) {
        chomp $l;
        next if $l =~ /^\s*(#|$)/;
        $l =~ s/\s+\z//;
        push @entries, $l;
    }
    close $fh;
    return \@entries;
}

# Every .pm (and, for a .pl entry, the file itself) a manifest entry covers.
sub manifest_files {
    my ($root, $entry) = @_;
    (my $rel = $entry) =~ s{/+\z}{};
    my $abs = "$root/$rel";
    return [$rel] if -f $abs;
    return undef unless -d $abs;
    my @files;
    File::Find::find({ no_chdir => 1, wanted => sub {
        return unless -f $_ && /\.p[ml]\z/;
        (my $r = $File::Find::name) =~ s{^\Q$root\E/}{};
        push @files, $r;
    } }, $abs);
    return [ sort @files ];
}

sub packages_of {
    my ($absFile) = @_;
    open(my $fh, '<', $absFile) or return ();
    my @pkgs;
    while (my $l = <$fh>) {
        last if $l =~ /^__(END|DATA)__/;
        push @pkgs, $1 if $l =~ /^\s*package\s+([A-Za-z_][\w:]*)\s*[;{]/;
    }
    close $fh;
    return grep { $_ ne 'main' } @pkgs;
}

sub collect {
    my ($side, $root) = @_;
    my $entries = read_manifest($root, $side) or return 1;
    my (%names, $nfiles);
    for my $e (@$entries) {
        my $files = manifest_files($root, $e);
        unless ($files) { print "MISSING $e\n"; return 1; }
        for my $f (@$files) {
            next unless $f =~ /\.p[ml]\z/;
            $nfiles++;
            $names{$_} = 1 for packages_of("$root/$f");
        }
    }
    my $out = "$root/.refcheck-$side.names";
    open(my $fh, '>', $out) or do { print STDERR "cannot write $out: $!\n"; return 2; };
    print $fh "$_\n" for sort keys %names;
    close $fh;
    printf "COLLECTED %s names=%d files=%d\n", $side, scalar(keys %names), $nfiles // 0;
    return 0;
}

# allow.txt -> [ { file, from, to, reason } ]
sub read_allow {
    my ($root) = @_;
    my $path = "$root/tools/ci/amputation/allow.txt";
    my @allow;
    open(my $fh, '<', $path) or return \@allow;
    while (my $l = <$fh>) {
        chomp $l;
        next if $l =~ /^\s*(#|$)/;
        if ($l =~ /^(\S+?)(?::(\d+)-(\d+))?:\s+(.+?)\s*\z/) {
            push @allow, { file => $1, from => $2, to => $3, reason => $4 };
        }
        else {
            print "REFCHECK FENCE allow.txt: unparsable entry: $l\n";
        }
    }
    close $fh;
    return \@allow;
}

sub allowed_reason {
    my ($allow, $file, $line) = @_;
    for my $a (@$allow) {
        next unless $a->{file} eq $file;
        return $a->{reason} unless defined $a->{from};
        return $a->{reason} if $line >= $a->{from} && $line <= $a->{to};
    }
    return undef;
}

# [ [lineNo, text], ... ] of non-comment code lines (full-line comments, POD
# and anything after __END__/__DATA__ excluded).
sub code_lines {
    my ($absFile) = @_;
    open(my $fh, '<', $absFile) or return [];
    my (@out, $pod);
    my $n = 0;
    while (my $l = <$fh>) {
        $n++;
        last if $l =~ /^__(END|DATA)__\b/;
        if ($l =~ /^=(\w+)/) { $pod = ($1 ne 'cut'); next; }
        next if $pod;
        next if $l =~ /^\s*#/;
        push @out, [ $n, $l ];
    }
    close $fh;
    return \@out;
}

sub plugin_modules {
    my ($root) = @_;
    my @mods;
    my $base = "$root/Plugins/SpotOn";
    return [] unless -d $base;
    File::Find::find({ no_chdir => 1, wanted => sub {
        return unless -f $_ && /\.pm\z/;
        (my $r = $File::Find::name) =~ s{^\Q$root\E/}{};
        push @mods, $r;
    } }, $base);
    return [ sort @mods ];
}

sub read_core_files {
    my ($root) = @_;
    my $path = "$root/tools/ci/amputation/core.files";
    open(my $fh, '<', $path) or return;
    my @core;
    while (my $l = <$fh>) {
        chomp $l;
        next if $l =~ /^\s*(#|$)/;
        push @core, $l;
    }
    close $fh;
    return \@core;
}

sub write_core_files {
    my ($root) = @_;
    my %side;
    for my $s (@SIDES) {
        my $entries = read_manifest($root, $s) or return 1;
        for my $e (@$entries) {
            my $files = manifest_files($root, $e);
            unless ($files) { print "MISSING $e\n"; return 1; }
            $side{$_} = $s for @$files;
        }
    }
    my @core = grep { !$side{$_} } @{ plugin_modules($root) };
    my $out = "$root/tools/ci/amputation/core.files";
    open(my $fh, '>', $out) or do { print STDERR "cannot write $out: $!\n"; return 2; };
    print $fh "# Core modules (84-12): every Plugins/SpotOn/**/*.pm under neither amputation\n"
            . "# manifest. Generated by `tools/ci/refcheck.pl --core-files`; regenerate after\n"
            . "# adding/removing a module. refcheck's fence requires every listed module to\n"
            . "# survive an amputation and the scanned module count to reach this list's size.\n";
    print $fh "$_\n" for @core;
    close $fh;
    printf "CORE_FILES n=%d\n", scalar @core;
    return 0;
}

sub scan_refs {
    my ($root, $files, $names, $allow, $hitPrefix, $allowPrefix) = @_;
    my ($hits, $allowed) = (0, 0);
    my @res = map { [ $_, qr/\b\Q$_\E(?![A-Za-z0-9_])/ ] } @$names;
    for my $f (@$files) {
        for my $cl (@{ code_lines("$root/$f") }) {
            my ($n, $text) = @$cl;
            for my $r (@res) {
                next unless $text =~ $r->[1];
                my $why = allowed_reason($allow, $f, $n);
                if (defined $why) {
                    print "$allowPrefix $f:$n $why\n";
                    $allowed++;
                }
                else {
                    print "$hitPrefix $f:$n: $r->[0]\n";
                    $hits++;
                }
                last;    # one line, one verdict
            }
        }
    }
    return ($hits, $allowed);
}

# A stub dir whose one module installs an @INC hook FIRST in @INC: every LMS
# or LMS-bundled module (Slim::*, JSON::XS*, URI*, ...) is synthesised as an
# AUTOLOAD stub whose import() predeclares the requested names, so `perl -c`
# compiles the plugin code alone -- locally and in CI alike (a local LMS
# install under /usr/share/perl5 is never consulted). main:: constants the
# plugin reads at compile time are defined as 0.
sub stub_dir {
    my $dir = tempdir(CLEANUP => 1);
    open(my $fh, '>', "$dir/_RefcheckStubs.pm") or die "stub: $!";
    print $fh <<'END';
package _RefcheckStubs;
use strict;
no strict 'refs';
my @ROOTS = qw(Slim Log::Log4perl Path::Class JSON::XS URI HTTP::Date Crypt::OpenSSL
               Plugins::MaterialSkin EV AnyEvent Proc::Background);
my %DEFAULT = (
    'Slim::Utils::Log'           => [qw(logger)],
    'Slim::Utils::Prefs'         => [qw(preferences)],
    'JSON::XS::VersionOneAndTwo' => [qw(to_json from_json encode_json decode_json)],
    'JSON::XS'                   => [qw(encode_json decode_json)],
    'URI::Escape'                => [qw(uri_escape uri_escape_utf8 uri_unescape)],
    'HTTP::Date'                 => [qw(time2str str2time)],
);
sub export {
    my ($class, $caller, @want) = @_;
    for my $n ((grep { defined && /^[A-Za-z_]\w*\z/ } @want), @{ $DEFAULT{$class} || [] }) {
        *{"${caller}::$n"} = sub { return undef } unless defined &{"${caller}::$n"};
    }
}
unshift @INC, sub {
    my ($self, $file) = @_;
    return unless $file =~ /\.pm\z/;
    (my $mod = $file) =~ s{/}{::}g;
    $mod =~ s/\.pm\z//;
    return unless grep { $mod eq $_ || index($mod, "${_}::") == 0 } @ROOTS;
    my $src = "package $mod; sub import { my \$c = shift; _RefcheckStubs::export(\$c, scalar caller, \@_) } "
            . "sub AUTOLOAD { return undef } sub DESTROY { } 1;\n";
    open(my $fh, '<', \$src) or return;
    return $fh;
};
package main;
use constant { map { $_ => 0 } qw(SCANNER INFOLOG DEBUGLOG ISWINDOWS ISMAC TRANSCODING WEBUI PERFMON
                                  IMAGE VIDEO MEDIASUPPORT LOCALFILE STATISTICS SB1SLIMP3SYNC NOMYSB) };
1;
END
    close $fh;
    return $dir;
}

sub perl_c {
    my ($root, $stubs, $file) = @_;
    # Plugins/SpotOn/Vendor is a library root of its own (Protocol::WebSocket::*,
    # loaded by Soloist::ensureWsLib from there), so it joins @INC when present.
    my @vendor = -d "$root/Plugins/SpotOn/Vendor" ? ("-I$root/Plugins/SpotOn/Vendor") : ();
    my @cmd = ($^X, "-I$stubs", "-I$root", @vendor, '-M_RefcheckStubs', '-c', "$root/$file");
    my $pid = open(my $out, '-|');
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        open(STDERR, '>&', \*STDOUT);
        exec(@cmd) or exit 127;
    }
    local $/;
    my $txt = <$out> // '';
    close $out;
    my $rc = $? >> 8;
    return ($rc == 0 && $txt =~ /syntax OK\s*\z/) ? undef : $txt;
}

sub check {
    my ($side, $root) = @_;
    my $hits = 0;

    my $namesFile = "$root/.refcheck-$side.names";
    my @names;
    if (open(my $fh, '<', $namesFile)) {
        @names = grep { length } map { chomp; $_ } <$fh>;
        close $fh;
    }
    unless (@names) {
        print "REFCHECK FENCE no removed names in $namesFile (run --collect $side before amputate.sh)\n";
        print "REFCHECK FAIL $side hits=1\n";
        return 1;
    }

    # Derived fence: every core module present, scanned >= count(core.files).
    my $core = read_core_files($root);
    unless ($core && @$core) {
        print "REFCHECK FENCE core.files missing or empty\n";
        print "REFCHECK FAIL $side hits=1\n";
        return 1;
    }
    my $mods = plugin_modules($root);
    my %present = map { $_ => 1 } @$mods;
    for my $c (@$core) {
        next if $present{$c};
        print "REFCHECK FENCE core module missing after amputation: $c\n";
        $hits++;
    }
    if (@$mods < @$core) {
        printf "REFCHECK FENCE scanned %d modules < %d core modules\n", scalar @$mods, scalar @$core;
        $hits++;
    }

    my ($refHits, $allowed) = scan_refs($root, $mods, \@names, read_allow($root), 'REFCHECK FAIL', 'ALLOWED');
    $hits += $refHits;

    my $stubs = stub_dir();
    for my $m (@$mods) {
        my $err = perl_c($root, $stubs, $m);
        next unless defined $err;
        my ($first) = grep { length } split /\n/, $err;
        print "REFCHECK FAIL $m:0: perl -c: " . ($first // 'no output') . "\n";
        $hits++;
    }

    if ($hits) {
        print "REFCHECK FAIL $side hits=$hits\n";
        return 1;
    }
    printf "REFCHECK PASS %s modules=%d allowed=%d\n", $side, scalar @$mods, $allowed;
    return 0;
}

sub core_only {
    my ($root) = @_;
    my @files = grep { -f "$root/$_" } @CORE_ONLY_FILES;
    my ($hits, $allowed) = scan_refs($root, \@files, \@CORE_ONLY_NAMES, read_allow($root), 'G2X HIT', 'G2X ALLOWED');
    if (@files != @CORE_ONLY_FILES) {
        print "G2X FENCE " . (@CORE_ONLY_FILES - @files) . " core file(s) missing\n";
        $hits++;
    }
    if ($hits) {
        print "G2X FAIL hits=$hits\n";
        return 1;
    }
    printf "G2X PASS files=%d allowed=%d\n", scalar @files, $allowed;
    return 0;
}

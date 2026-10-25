#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# Guards T-wh5-01: a SpotOn row in custom-types.conf must never claim a MIME
# that Slim::Music::Info's last-writer-wins loader (Info.pm:128) would also
# hand to a standard LMS type. Row parsing below mirrors
# Slim::Music::Info::loadTypesConfig (Info.pm:114-120): strip `#` to end of
# line, trim, keep 4-field lines, split the MIME field on `,`, skip `-`,
# lowercase MIME keys.

# Resolve the project root (t/<group>/x.t sits two levels below it)
my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname(dirname($test_dir));   # t/<group>/x.t -> repo root
die "wrong project root: $project_dir" unless -f "$project_dir/Plugins/SpotOn/Plugin.pm";
my $conf_file   = "$project_dir/Plugins/SpotOn/custom-types.conf";

# Standard LMS MIMEs that no SpotOn row may claim (compared case-insensitively).
my %FORBIDDEN_MIME = map { lc($_) => 1 } (
    'audio/mpeg', 'audio/ogg', 'audio/flac', 'audio/x-flac',
    'audio/wav', 'audio/L16', 'audio/aac', 'audio/mp4',
);

sub parse_types_conf {
    my ($content) = @_;
    my @rows;
    for my $line (split /\n/, $content) {
        my $l = $line;
        $l =~ s/#.*$//;
        $l =~ s/^\s+|\s+$//g;
        next unless length $l;
        my @fields = split /\s+/, $l;
        next unless @fields == 4;
        push @rows, {
            type     => $fields[0],
            suffixes => $fields[1],
            mimes    => $fields[2],
            slimtype => $fields[3],
        };
    }
    return @rows;
}

sub primary_mime {
    my ($row) = @_;
    my ($mime) = grep { $_ ne '-' } split(/,/, $row->{mimes});
    return $mime;
}

ok(-f $conf_file, "custom-types.conf exists at $conf_file");

open(my $fh, '<', $conf_file) or die "Cannot open $conf_file: $!";
my $content = do { local $/; <$fh> };
close($fh);

my @rows = parse_types_conf($content);

ok(scalar(@rows) > 0, "at least one type row was parsed from custom-types.conf");

my %seen_mime;
for my $row (@rows) {
    my $mime = primary_mime($row);
    my $lc_mime = lc($mime);

    ok(!$FORBIDDEN_MIME{$lc_mime},
        "type $row->{type}: MIME is not a standard LMS MIME (got $mime)");

    ok($lc_mime =~ m{^audio/x-sb-spoton-},
        "type $row->{type}: MIME is namespaced under audio/x-sb-spoton- (got $mime)");

    push @{ $seen_mime{$lc_mime} }, $row->{type};
}

is(scalar(keys %seen_mime), scalar(@rows),
    "no two SpotOn rows share the same MIME (" . scalar(@rows) . " rows, " . scalar(keys %seen_mime) . " distinct MIMEs)");

# Loader replay: mirror Info.pm's last-writer-wins assignment (Info.pm:128)
# by loading the server's types.conf first, then this plugin's
# custom-types.conf into the SAME hash, and confirm the standard MP3/Ogg
# MIMEs still resolve to LMS's own mp3/ogg types afterward. This is the
# assertion that fails for exactly the reason MP3/Ogg internet radio broke.
my $server_types_conf = $ENV{LMS_TYPES_CONF} || '/etc/squeezeboxserver/types.conf';

SKIP: {
    skip "no server types.conf reachable at $server_types_conf for loader replay", 2
        unless -f $server_types_conf && -r $server_types_conf;

    open(my $server_fh, '<', $server_types_conf)
        or skip("cannot open $server_types_conf: $!", 2);
    my $server_content = do { local $/; <$server_fh> };
    close($server_fh);

    my @server_rows = parse_types_conf($server_content);

    my %mime_to_type;
    for my $row (@server_rows, @rows) {
        for my $mime (split /,/, $row->{mimes}) {
            next if $mime eq '-';
            $mime_to_type{lc($mime)} = $row->{type};
        }
    }

    # The standard MP3/Ogg MIME strings (same literals as %FORBIDDEN_MIME).
    # Each server type row lists SEVERAL MIME aliases comma-separated
    # (e.g. ogg: audio/x-ogg,application/ogg,audio/ogg,application/x-ogg);
    # the plugin's `son`/`smp` rows collide on the "audio/ogg" and
    # "audio/mpeg" aliases specifically, not necessarily on the first-listed
    # alias -- so these are checked directly rather than derived from
    # primary_mime() on the server row.
    my $mp3_mime = 'audio/mpeg';
    my $ogg_mime = 'audio/ogg';

    is($mime_to_type{$mp3_mime}, 'mp3',
        "standard MP3 MIME ($mp3_mime) still resolves to LMS type mp3 after loading SpotOn's custom-types.conf");

    is($mime_to_type{$ogg_mime}, 'ogg',
        "standard Ogg MIME ($ogg_mime) still resolves to LMS type ogg after loading SpotOn's custom-types.conf");
}

done_testing();

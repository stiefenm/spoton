#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

# ProtobufLite.pm has ZERO Slim:: dependencies -- no LMS stub scaffolding
# needed. This mirrors the module's own design goal (standalone-loadable,
# Task 1 acceptance criterion).

my $test_dir    = dirname(abs_path($0));
my $project_dir = dirname($test_dir);

unshift @INC, $project_dir;

require_ok('Plugins::SpotOn::API::ProtobufLite')
    or BAIL_OUT('Failed to load ProtobufLite.pm');

# ProtobufLite exposes plain (non-OOP) functions -- alias them locally rather
# than repeating the fully-qualified package name everywhere below.
*encode_varint = \&Plugins::SpotOn::API::ProtobufLite::encode_varint;
*encode_field  = \&Plugins::SpotOn::API::ProtobufLite::encode_field;
*parse_fields  = \&Plugins::SpotOn::API::ProtobufLite::parse_fields;
*field_first   = \&Plugins::SpotOn::API::ProtobufLite::field_first;

# ------------------------------------------------------------
# encode_varint
# ------------------------------------------------------------
is(encode_varint(50), "\x32", 'encode_varint(50) is a single byte');
is(encode_varint(300), "\xAC\x02", 'encode_varint(300) is multi-byte');

# ------------------------------------------------------------
# encode_field -- PageRequest golden vector (Rust-parity, S-06 D-01/D-02)
# ------------------------------------------------------------
{
    my $encoded = encode_field(1, 2, 'alice')
        . encode_field(2, 2, 'starred')
        . encode_field(3, 2, 'tok')
        . encode_field(4, 0, 50);

    my $hex = unpack('H*', $encoded);

    # Captured from `cargo run -- protobuf --schema collection-v2 --mode encode`
    # against spoton-helper (still present pre-D-02 Rust-code deletion) for
    # JSON {"username":"alice","set":"starred","pagination_token":"tok","limit":50}
    # -- byte-identical Rust-parity golden vector.
    is($hex, '0a05616c6963651207737461727265641a03746f6b2032',
        'encode_field builds the PageRequest wire bytes, Rust-parity verified');
}

# ------------------------------------------------------------
# parse_fields -- repeated CollectionItem items (A1) + next_page_token
# ------------------------------------------------------------
{
    # CollectionItem: uri=1(string), added_at=2(varint), is_removed=3(varint bool)
    my $item1 = encode_field(1, 2, 'spotify:album:abc111')
        . encode_field(2, 0, 1_700_000_000)   # multi-byte varint (S-01 class)
        . encode_field(3, 0, 0);
    my $item2 = encode_field(1, 2, 'spotify:album:def222')
        . encode_field(2, 0, 1_700_000_005)
        . encode_field(3, 0, 1);

    # PageResponse: items=1(repeated, len), next_page_token=2(string)
    my $pageResponse = encode_field(1, 2, $item1)
        . encode_field(1, 2, $item2)
        . encode_field(2, 2, 'next_tok_xyz');

    my $fields = parse_fields($pageResponse);
    ok($fields, 'parse_fields decodes the PageResponse without dying');
    is(ref($fields->{1}), 'ARRAY', 'field 1 (repeated items) is an arrayref');
    is(scalar(@{ $fields->{1} }), 2, 'A1: BOTH repeated CollectionItems are returned, not last-item-wins');

    my $decodedItem1 = parse_fields($fields->{1}[0]);
    my $decodedItem2 = parse_fields($fields->{1}[1]);
    is(field_first($decodedItem1, 1), 'spotify:album:abc111', 'item 1 uri round-trips');
    is(field_first($decodedItem1, 2), 1_700_000_000, 'item 1 added_at (multi-byte varint) round-trips intact');
    is(field_first($decodedItem2, 1), 'spotify:album:def222', 'item 2 uri round-trips');
    is(field_first($decodedItem2, 3), 1, 'item 2 is_removed round-trips');

    is(field_first($fields, 2), 'next_tok_xyz', 'field_first returns next_page_token (field 2)');
}

# ------------------------------------------------------------
# Long length-delimited payload (>127 bytes -- forces a 2-byte varint length,
# the exact S-01 failure class: a single-byte-length-only parser truncates)
# ------------------------------------------------------------
{
    my $longPayload = 'x' x 200;
    my $encoded = encode_field(1, 2, $longPayload);
    my $fields  = parse_fields($encoded);
    is(length(field_first($fields, 1)), 200,
        'a >127-byte length-delimited field (2-byte varint length) round-trips intact');
}

# ------------------------------------------------------------
# Malformed input -- never dies, never loops, returns undef
# ------------------------------------------------------------
{
    # Truncated varint: continuation bit set, buffer ends immediately after.
    my $truncated = "\x80";
    is(parse_fields($truncated), undef, 'truncated varint returns undef, not a die');

    # Declared length overruns the remaining buffer.
    my $tag = encode_varint((1 << 3) | 2);     # field 1, wire type 2
    my $badLen = encode_varint(50);            # claims 50 bytes...
    my $overrun = $tag . $badLen . 'short';    # ...but only 5 follow
    is(parse_fields($overrun), undef, 'a length overrunning the buffer returns undef');

    # Unknown wire type (7) -- field 15, wire 7: tag = (15<<3)|7 = 127.
    my $unknownWire = encode_varint((15 << 3) | 7);
    is(parse_fields($unknownWire), undef, 'unknown wire type returns undef');

    # The Rust fixture's 0xFF garbage bytes (protobuf_cmd.rs malformed_protobuf_returns_error_not_panic).
    my $rustFixture = pack('C*', 0xFF, 0x00, 0xAB, 0xCD, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF);
    is(parse_fields($rustFixture), undef, 'Rust-fixture 0xFF garbage bytes return undef, never die/loop');
}

done_testing();

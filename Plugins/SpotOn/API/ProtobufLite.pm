package Plugins::SpotOn::API::ProtobufLite;

# Generic protobuf wire-format encoder/decoder (D-01, Phase 75). This is the
# ONLY protobuf path in SpotOn -- no external process spawn, no generated
# schema code. It understands the wire format only (varint + length-delimited
# + the two fixed-width types), not any specific .proto message -- callers
# interpret field numbers themselves. Unknown fields are transparently
# preserved (never dropped), which makes this decoder forward-compatible with
# schema additions Spotify may ship without warning.
#
# Deliberately pure Perl with ZERO LMS-framework dependencies (not even the
# logging module) -- the standalone smoke script from plan 75-06 loads this
# module outside the LMS process entirely. Do not add any LMS-namespaced
# `use` line here (this file must stay standalone-loadable, Task 1
# acceptance criterion).
#
# Security (V5 / T-75-02): every parse loop is bounded by `pos < len`. A
# declared length-delimited length that would overrun the remaining buffer,
# a truncated varint (buffer ends mid-continuation-byte), or an unknown wire
# type all return undef -- this decoder NEVER dies and NEVER loops on
# malformed/adversarial input (spclient responses are untrusted network
# data).

use strict;
use warnings;

# Bound how many continuation bytes a single varint may consume. A
# well-formed protobuf varint never needs more than 10 bytes (64-bit value).
# Anything longer is malformed input -- abort rather than let $shift grow
# without bound.
use constant MAX_VARINT_BYTES => 10;

# encode_varint($value)
# Encodes a non-negative integer as a protobuf-style base-128 varint.
sub encode_varint {
    my ($value) = @_;
    my $out = '';
    while ($value > 0x7F) {
        $out .= chr(($value & 0x7F) | 0x80);
        $value >>= 7;
    }
    $out .= chr($value & 0x7F);
    return $out;
}

# encode_field($field, $wire, $data)
# $wire == 2 (length-delimited): $data is a byte string -- emits tag + varint
#   length + bytes.
# $wire == 0 (varint): $data is a non-negative integer -- emits tag + varint.
# Any other $wire: emits tag + $data verbatim (caller-supplied raw bytes;
# not used by Phase 75 callers, kept for completeness/symmetry with parse).
sub encode_field {
    my ($field, $wire, $data) = @_;
    my $tag = encode_varint(($field << 3) | $wire);
    if ($wire == 2) {
        return $tag . encode_varint(length $data) . $data;
    }
    elsif ($wire == 0) {
        return $tag . encode_varint($data);
    }
    return $tag . $data;
}

# _read_varint(\$data, \$pos, $len)
# Reads one varint starting at $$posRef, advancing it past the value.
# Returns ($value, 1) on success, (0, 0) on truncation/overflow -- never dies.
sub _read_varint {
    my ($dataRef, $posRef, $len) = @_;
    my ($value, $shift, $bytesRead) = (0, 0, 0);
    while ($$posRef < $len) {
        my $byte = ord(substr($$dataRef, $$posRef, 1));
        $$posRef++;
        $bytesRead++;
        $value |= ($byte & 0x7F) << $shift;
        return ($value, 1) unless $byte & 0x80;
        return (0, 0) if $bytesRead >= MAX_VARINT_BYTES;
        $shift += 7;
    }
    # Ran out of bytes mid-varint (truncated input, S-01-class bug if this
    # ever happens on a real varint) -- malformed, not a bug to retry.
    return (0, 0);
}

# parse_fields($data)
# Decodes a flat protobuf message into { field_num => [values...] } --
# EVERY occurrence of a field is collected (push, never overwrite), which is
# what makes `repeated` fields (e.g. collection/v2 PageResponse.items, A1)
# come back complete instead of only the last occurrence surviving.
# Length-delimited (wire 2) values are returned as raw byte strings (the
# caller re-parses embedded messages by calling parse_fields again on the
# bytes). Varint (wire 0) values are returned as plain integers. Wire types 1
# (8-byte) and 5 (4-byte) are read and skipped correctly. Any other wire type,
# or any bounds violation, returns undef immediately -- never dies, never
# loops (Security V5/T-75-02).
sub parse_fields {
    my ($data) = @_;
    return undef unless defined $data;

    my %out;
    my $pos = 0;
    my $len = length($data);

    while ($pos < $len) {
        my ($tag, $tagOk) = _read_varint(\$data, \$pos, $len);
        return undef unless $tagOk;

        my $field = $tag >> 3;
        my $wire  = $tag & 0x07;

        if ($wire == 2) {
            my ($fieldLen, $lenOk) = _read_varint(\$data, \$pos, $len);
            return undef unless $lenOk;
            return undef if $fieldLen < 0 || ($pos + $fieldLen) > $len;
            push @{ $out{$field} }, substr($data, $pos, $fieldLen);
            $pos += $fieldLen;
        }
        elsif ($wire == 0) {
            my ($value, $ok) = _read_varint(\$data, \$pos, $len);
            return undef unless $ok;
            push @{ $out{$field} }, $value;
        }
        elsif ($wire == 5) {
            return undef if ($pos + 4) > $len;
            push @{ $out{$field} }, substr($data, $pos, 4);
            $pos += 4;
        }
        elsif ($wire == 1) {
            return undef if ($pos + 8) > $len;
            push @{ $out{$field} }, substr($data, $pos, 8);
            $pos += 8;
        }
        else {
            # Unknown wire type (3/4 are deprecated group start/end, or
            # genuinely malformed/adversarial input) -- abort the parse.
            return undef;
        }
    }

    return \%out;
}

# field_first($fields, $num)
# Convenience accessor: first occurrence of field $num, or undef if absent.
# $fields is the hashref returned by parse_fields (every value an arrayref).
sub field_first {
    my ($fields, $num) = @_;
    return undef unless $fields && ref($fields) eq 'HASH';
    my $values = $fields->{$num};
    return undef unless $values && ref($values) eq 'ARRAY' && @{$values};
    return $values->[0];
}

1;

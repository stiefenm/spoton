//! Per-arch FLAC24 gate instruction-encoding scaffolding.
//!
//! The FLAC24 enum-downgrade gates are immediate-compare instructions whose
//! byte encoding differs across the three supported architectures. This
//! module documents the *shape* of that difference and gives the engine an
//! arch-dispatch point to validate against -- it intentionally contains no
//! concrete opcodes or immediate values (those are private-injected via
//! `patterns.rs`, see its module doc).

/// The instruction family used to encode a FLAC24 gate compare, per arch.
/// Documents the shape of the private RE output (RESEARCH.md A2), not its
/// bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GateEncoding {
    /// x86_64: `cmp r/m8, imm8` -- an 8-bit-immediate compare.
    X86_64CmpImm8,
    /// aarch64: `cmp wN, #imm` -- a 32-bit register-immediate compare.
    Aarch64CmpImm,
    /// armhf (armv7): `cmp rN, #imm` -- a 32-bit register-immediate compare.
    ArmhfCmpImm,
}

/// Map a bindir arch string (the `arch::read_arch` vocabulary) to the gate
/// encoding family used on that architecture. Returns `None` for an
/// unrecognized arch -- callers must fail closed, not guess an encoding.
pub fn encoding_for(arch: &str) -> Option<GateEncoding> {
    match arch {
        "x86_64-linux" => Some(GateEncoding::X86_64CmpImm8),
        "aarch64-linux" => Some(GateEncoding::Aarch64CmpImm),
        "armhf-linux" => Some(GateEncoding::ArmhfCmpImm),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_arches_have_an_encoding() {
        assert_eq!(encoding_for("x86_64-linux"), Some(GateEncoding::X86_64CmpImm8));
        assert_eq!(encoding_for("aarch64-linux"), Some(GateEncoding::Aarch64CmpImm));
        assert_eq!(encoding_for("armhf-linux"), Some(GateEncoding::ArmhfCmpImm));
    }

    #[test]
    fn unknown_arch_fails_closed() {
        assert_eq!(encoding_for("riscv64-linux"), None);
    }
}

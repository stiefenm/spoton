//! ELF `e_machine` detection without a full ELF parser.
//!
//! We only need one field (the target architecture), so a 20-line read beats
//! pulling in `object`/`goblin` as a dependency. See RESEARCH.md Pattern 2.

/// ELF magic bytes at file offset 0x00.
const ELF_MAGIC: [u8; 4] = [0x7f, b'E', b'L', b'F'];

/// Offset of the 2-byte little-endian `e_machine` field in the ELF header.
const E_MACHINE_OFFSET: usize = 0x12;

/// x86_64 (EM_X86_64)
const EM_X86_64: u16 = 0x3E;
/// AArch64 (EM_AARCH64)
const EM_AARCH64: u16 = 0xB7;
/// ARM (EM_ARM) -- covers armv7/armhf builds
const EM_ARM: u16 = 0x28;

/// Read the ELF `e_machine` field and map it to the SpotOn bindir vocabulary
/// (`Plugins/SpotOn/Soloist.pm` `@ARCH_MAP`). Returns `None` if the magic is
/// missing, the file is too short, or the machine value is unrecognized --
/// arch detection fails closed rather than guessing.
pub fn read_arch(bytes: &[u8]) -> Option<&'static str> {
    if bytes.len() < E_MACHINE_OFFSET + 2 {
        return None;
    }
    if bytes[0..4] != ELF_MAGIC {
        return None;
    }

    let e_machine = u16::from_le_bytes([bytes[E_MACHINE_OFFSET], bytes[E_MACHINE_OFFSET + 1]]);

    match e_machine {
        EM_X86_64 => Some("x86_64-linux"),
        EM_AARCH64 => Some("aarch64-linux"),
        EM_ARM => Some("armhf-linux"),
        _ => None,
    }
}

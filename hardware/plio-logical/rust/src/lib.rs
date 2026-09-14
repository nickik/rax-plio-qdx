#![forbid(unsafe_code)]

pub const PLIO_TIMEOUT_CYCLES: u16 = 256;
pub const WORKER_ADDRESS_MASK: u32 = 0x01ff_ffff;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Space {
    Worker = 0,
    HostDma = 1,
    Controller = 2,
    Reserved = 3,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum BurstWords {
    #[default]
    One,
    Four,
    Eight,
    Sixteen,
}

impl BurstWords {
    pub const fn words(self) -> u8 {
        match self {
            Self::One => 1,
            Self::Four => 4,
            Self::Eight => 8,
            Self::Sixteen => 16,
        }
    }

    pub const fn bytes(self) -> u8 { self.words() * 4 }

    pub const fn blen(self) -> u8 {
        match self {
            Self::One => 0,
            Self::Four => 1,
            Self::Eight => 2,
            Self::Sixteen => 3,
        }
    }

    pub const fn from_blen(blen: u8) -> Option<Self> {
        match blen {
            0 => Some(Self::One),
            1 => Some(Self::Four),
            2 => Some(Self::Eight),
            3 => Some(Self::Sixteen),
            _ => None,
        }
    }
}

/// Resolved signals driven toward one peripheral card by the PLIO side.
/// Booleans use asserted=true even when the physical signal is active-low.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct BusToCard {
    pub reset: bool,
    pub selected: bool,
    pub grant: bool,
    pub ad: Option<u32>,
    pub par: Option<u8>,
    pub space: Option<Space>,
    pub address_strobe: bool,
    pub read: bool,
    pub byte_enable: u8,
    pub burst: BurstWords,
    pub data_strobe: bool,
    pub ack: bool,
    pub err: bool,
}

/// Signals driven by one peripheral card toward PLIO.
/// Tri-stated buses are represented by Option::None.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct CardToBus {
    pub request: bool,
    pub ad: Option<u32>,
    pub par: Option<u8>,
    pub space: Option<Space>,
    pub address_strobe: bool,
    pub read: bool,
    pub byte_enable: u8,
    pub burst: BurstWords,
    pub data_strobe: bool,
    pub ack: bool,
    pub err: bool,
}

/// Return the odd-parity bit for one byte lane.
pub fn odd_parity_bit(byte: u8) -> bool { byte.count_ones() % 2 == 0 }

/// PAR[3:0], with bit n protecting byte lane n.
pub fn odd_parity_32(word: u32) -> u8 {
    let mut parity = 0u8;
    for lane in 0..4 {
        let byte = ((word >> (lane * 8)) & 0xff) as u8;
        if odd_parity_bit(byte) { parity |= 1 << lane; }
    }
    parity
}

pub fn parity_matches(word: u32, parity: u8, byte_enable: u8) -> bool {
    let expected = odd_parity_32(word);
    for lane in 0..4 {
        let lane_mask = 1u8 << lane;
        if byte_enable & lane_mask != 0 && (expected & lane_mask) != (parity & lane_mask) {
            return false;
        }
    }
    true
}

pub fn valid_worker_address(address: u32) -> bool { address & !WORKER_ADDRESS_MASK == 0 }

/// PLIO v0.6 naturally-aligned worker transfer encoding.
/// The byte address selects the first addressed byte and BE selects the
/// corresponding lane(s) in the containing 32-bit longword.
pub fn valid_worker_byte_enable(address: u32, byte_enable: u8) -> bool {
    if byte_enable & !0x0f != 0 { return false; }
    matches!(
        (address & 3, byte_enable),
        (0, 0b0001)
            | (1, 0b0010)
            | (2, 0b0100)
            | (3, 0b1000)
            | (0, 0b0011)
            | (2, 0b1100)
            | (0, 0b1111)
    )
}

pub fn valid_worker_transfer(address: u32, byte_enable: u8) -> bool {
    valid_worker_address(address) && valid_worker_byte_enable(address, byte_enable)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn burst_encoding_matches_plio() {
        for (burst, code, words) in [
            (BurstWords::One, 0, 1),
            (BurstWords::Four, 1, 4),
            (BurstWords::Eight, 2, 8),
            (BurstWords::Sixteen, 3, 16),
        ] {
            assert_eq!(burst.blen(), code);
            assert_eq!(burst.words(), words);
            assert_eq!(BurstWords::from_blen(code), Some(burst));
        }
        assert_eq!(BurstWords::from_blen(4), None);
    }

    #[test]
    fn parity_makes_each_lane_odd() {
        let word = 0x00ff_0180u32;
        let p = odd_parity_32(word);
        assert!(parity_matches(word, p, 0xf));
        for lane in 0..4 {
            let byte = ((word >> (lane * 8)) & 0xff) as u8;
            let parity_bit = (p >> lane) & 1;
            assert_eq!((byte.count_ones() + parity_bit as u32) % 2, 1);
        }
    }

    #[test]
    fn parity_only_checks_enabled_worker_lanes() {
        let word = 0x1234_5678;
        let good = odd_parity_32(word);
        assert!(parity_matches(word, good ^ 0b1000, 0b0011));
        assert!(!parity_matches(word, good ^ 0b0010, 0b0011));
    }

    #[test]
    fn worker_address_is_25_bit() {
        assert!(valid_worker_address(0x01ff_ffff));
        assert!(!valid_worker_address(0x0200_0000));
    }

    #[test]
    fn worker_byte_enables_encode_only_natural_8_16_32_bit_accesses() {
        for (address, be) in [
            (0x100, 0b0001),
            (0x101, 0b0010),
            (0x102, 0b0100),
            (0x103, 0b1000),
            (0x100, 0b0011),
            (0x102, 0b1100),
            (0x100, 0b1111),
        ] {
            assert!(valid_worker_byte_enable(address, be), "address={address:#x} be={be:04b}");
        }

        for (address, be) in [
            (0x101, 0b0011),
            (0x100, 0b1100),
            (0x102, 0b1111),
            (0x100, 0b0101),
            (0x100, 0),
            (0x100, 0x10),
        ] {
            assert!(!valid_worker_byte_enable(address, be), "address={address:#x} be={be:04b}");
        }
    }
}

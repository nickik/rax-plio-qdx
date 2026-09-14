#![forbid(unsafe_code)]

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Space {
    Worker = 0,
    HostDma = 1,
    Controller = 2,
    Reserved = 3,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BurstWords {
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

    pub const fn blen(self) -> u8 {
        match self {
            Self::One => 0,
            Self::Four => 1,
            Self::Eight => 2,
            Self::Sixteen => 3,
        }
    }
}

/// Return the odd-parity bit for one byte lane.
/// The returned bit makes the total number of one bits odd.
pub fn odd_parity_bit(byte: u8) -> bool {
    byte.count_ones() % 2 == 0
}

/// PAR[3:0], with bit n protecting byte lane n.
pub fn odd_parity_32(word: u32) -> u8 {
    let mut parity = 0u8;
    for lane in 0..4 {
        let byte = ((word >> (lane * 8)) & 0xff) as u8;
        if odd_parity_bit(byte) {
            parity |= 1 << lane;
        }
    }
    parity
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn burst_encoding_matches_plio() {
        assert_eq!(BurstWords::One.blen(), 0);
        assert_eq!(BurstWords::Four.blen(), 1);
        assert_eq!(BurstWords::Eight.blen(), 2);
        assert_eq!(BurstWords::Sixteen.blen(), 3);
    }

    #[test]
    fn parity_makes_each_lane_odd() {
        let word = 0x00ff_0180u32;
        let p = odd_parity_32(word);
        for lane in 0..4 {
            let byte = ((word >> (lane * 8)) & 0xff) as u8;
            let parity_bit = (p >> lane) & 1;
            assert_eq!((byte.count_ones() + parity_bit as u32) % 2, 1);
        }
    }
}

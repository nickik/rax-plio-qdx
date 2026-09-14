#![forbid(unsafe_code)]

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum TokenKind {
    Idle = 0,
    DataLo = 1,
    DataHi = 2,
    Control = 3,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Token {
    pub kind: TokenKind,
    /// PTD[17:0]: payload[15:0] plus two parity bits in [17:16].
    pub ptd: u32,
}

impl Token {
    pub fn new(kind: TokenKind, data: u16, parity: u8) -> Result<Self, &'static str> {
        if parity > 0b11 {
            return Err("PTI token parity fragment must fit two bits");
        }
        Ok(Self { kind, ptd: u32::from(data) | (u32::from(parity) << 16) })
    }

    pub fn data(self) -> u16 {
        self.ptd as u16
    }

    pub fn parity(self) -> u8 {
        ((self.ptd >> 16) & 0x3) as u8
    }
}

pub fn encode_data_beat(data: u32, parity: u8) -> Result<[Token; 2], &'static str> {
    if parity > 0x0f {
        return Err("PLIO beat parity must fit four bits");
    }
    Ok([
        Token::new(TokenKind::DataLo, data as u16, parity & 0x3)?,
        Token::new(TokenKind::DataHi, (data >> 16) as u16, (parity >> 2) & 0x3)?,
    ])
}

pub fn decode_data_beat(tokens: [Token; 2]) -> Result<(u32, u8), &'static str> {
    if tokens[0].kind != TokenKind::DataLo || tokens[1].kind != TokenKind::DataHi {
        return Err("PTI data beat must be ordered LO then HI");
    }
    let data = u32::from(tokens[0].data()) | (u32::from(tokens[1].data()) << 16);
    let parity = tokens[0].parity() | (tokens[1].parity() << 2);
    Ok((data, parity))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ControlImage {
    pub space: u8,
    pub address_strobe: bool,
    pub read: bool,
    pub byte_enable: u8,
    pub burst_len: u8,
    pub data_strobe: bool,
    pub drive_ad_par: bool,
    pub drive_control: bool,
}

impl ControlImage {
    pub fn pack(self) -> Result<u16, &'static str> {
        if self.space > 3 || self.byte_enable > 0x0f || self.burst_len > 3 {
            return Err("PTI control field out of range");
        }
        Ok(u16::from(self.space)
            | ((self.address_strobe as u16) << 2)
            | ((self.read as u16) << 3)
            | (u16::from(self.byte_enable) << 4)
            | (u16::from(self.burst_len) << 8)
            | ((self.data_strobe as u16) << 10)
            | ((self.drive_ad_par as u16) << 11)
            | ((self.drive_control as u16) << 12))
    }

    pub fn unpack(bits: u16) -> Result<Self, &'static str> {
        if bits & 0xe000 != 0 {
            return Err("PTI control reserved bits must be zero");
        }
        Ok(Self {
            space: (bits & 0x3) as u8,
            address_strobe: bits & (1 << 2) != 0,
            read: bits & (1 << 3) != 0,
            byte_enable: ((bits >> 4) & 0x0f) as u8,
            burst_len: ((bits >> 8) & 0x3) as u8,
            data_strobe: bits & (1 << 10) != 0,
            drive_ad_par: bits & (1 << 11) != 0,
            drive_control: bits & (1 << 12) != 0,
        })
    }
}

pub fn encode_control(image: ControlImage) -> Result<Token, &'static str> {
    Token::new(TokenKind::Control, image.pack()?, 0)
}

pub fn decode_control(token: Token) -> Result<ControlImage, &'static str> {
    if token.kind != TokenKind::Control || token.parity() != 0 {
        return Err("invalid PTI control token");
    }
    ControlImage::unpack(token.data())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn full_plio_data_and_parity_fit_exactly_two_tokens() {
        let encoded = encode_data_beat(0x89ab_cdef, 0b1010).unwrap();
        assert_eq!(encoded[0].data(), 0xcdef);
        assert_eq!(encoded[0].parity(), 0b10);
        assert_eq!(encoded[1].data(), 0x89ab);
        assert_eq!(encoded[1].parity(), 0b10);
        assert_eq!(decode_data_beat(encoded).unwrap(), (0x89ab_cdef, 0b1010));
    }

    #[test]
    fn high_without_low_is_rejected() {
        let mut encoded = encode_data_beat(0x1234_5678, 0).unwrap();
        encoded.swap(0, 1);
        assert!(decode_data_beat(encoded).is_err());
    }

    #[test]
    fn control_image_round_trips() {
        let image = ControlImage {
            space: 2,
            address_strobe: true,
            read: true,
            byte_enable: 0xf,
            burst_len: 3,
            data_strobe: true,
            drive_ad_par: true,
            drive_control: false,
        };
        let token = encode_control(image).unwrap();
        assert_eq!(decode_control(token).unwrap(), image);
    }

    #[test]
    fn reserved_control_bits_are_rejected() {
        assert!(ControlImage::unpack(0x8000).is_err());
    }
}

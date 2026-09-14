#![forbid(unsafe_code)]

use qli_model::{
    DmaCompletion, DmaDirection, DmaRequest, DmaStatus, DmaWord, MmioRequest, MmioResponse,
    NotificationRequest,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum TokenType {
    Idle = 0,
    MmioHeader = 1,
    MmioData = 2,
    MmioResponse = 3,
    DmaHeader = 4,
    DmaData = 5,
    DmaCompletion = 6,
    Notification = 7,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    QicToDevice,
    DeviceToQic,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Token {
    pub kind: TokenType,
    pub payload: u16,
    pub direction: Direction,
}

fn token(kind: TokenType, payload: u16, direction: Direction) -> Token {
    Token { kind, payload, direction }
}

pub fn encode_mmio_request(req: MmioRequest) -> Result<Vec<Token>, &'static str> {
    req.validate()?;
    let meta = (((req.address >> 16) & 0x1ff) as u16)
        | ((req.write as u16) << 9)
        | (((req.byte_enable & 0x0f) as u16) << 10);
    let mut out = vec![
        token(TokenType::MmioHeader, req.address as u16, Direction::QicToDevice),
        token(TokenType::MmioHeader, meta, Direction::QicToDevice),
    ];
    if req.write {
        out.push(token(TokenType::MmioData, req.write_data as u16, Direction::QicToDevice));
        out.push(token(TokenType::MmioData, (req.write_data >> 16) as u16, Direction::QicToDevice));
    }
    Ok(out)
}

pub fn decode_mmio_request(tokens: &[Token]) -> Result<MmioRequest, &'static str> {
    if tokens.len() != 2 && tokens.len() != 4 {
        return Err("QLI-16 MMIO request must contain 2 or 4 tokens");
    }
    if tokens[0].kind != TokenType::MmioHeader || tokens[1].kind != TokenType::MmioHeader {
        return Err("QLI-16 MMIO request missing header");
    }
    if tokens.iter().any(|t| t.direction != Direction::QicToDevice) {
        return Err("QLI-16 MMIO request has wrong direction");
    }
    let meta = tokens[1].payload;
    if meta & 0xc000 != 0 {
        return Err("QLI-16 MMIO reserved bits must be zero");
    }
    let write = (meta & (1 << 9)) != 0;
    if write != (tokens.len() == 4) {
        return Err("QLI-16 MMIO token count does not match write bit");
    }
    let address = u32::from(tokens[0].payload) | (u32::from(meta & 0x01ff) << 16);
    let byte_enable = ((meta >> 10) & 0x0f) as u8;
    let write_data = if write {
        if tokens[2].kind != TokenType::MmioData || tokens[3].kind != TokenType::MmioData {
            return Err("QLI-16 MMIO write missing data");
        }
        u32::from(tokens[2].payload) | (u32::from(tokens[3].payload) << 16)
    } else {
        0
    };
    let req = MmioRequest { address, write, byte_enable, write_data };
    req.validate()?;
    Ok(req)
}

pub fn encode_mmio_response(resp: MmioResponse) -> Vec<Token> {
    let dir = Direction::DeviceToQic;
    match resp {
        MmioResponse::ReadOk(data) => vec![
            token(TokenType::MmioResponse, 0, dir),
            token(TokenType::MmioData, data as u16, dir),
            token(TokenType::MmioData, (data >> 16) as u16, dir),
        ],
        MmioResponse::WriteOk => vec![token(TokenType::MmioResponse, 1, dir)],
        MmioResponse::Error => vec![token(TokenType::MmioResponse, 2, dir)],
    }
}

pub fn decode_mmio_response(tokens: &[Token]) -> Result<MmioResponse, &'static str> {
    if tokens.is_empty() || tokens[0].kind != TokenType::MmioResponse {
        return Err("QLI-16 MMIO response missing status");
    }
    if tokens.iter().any(|t| t.direction != Direction::DeviceToQic) {
        return Err("QLI-16 MMIO response has wrong direction");
    }
    if tokens[0].payload & !0x0003 != 0 {
        return Err("QLI-16 MMIO response reserved bits must be zero");
    }
    match tokens[0].payload & 3 {
        0 => {
            if tokens.len() != 3 || tokens[1].kind != TokenType::MmioData || tokens[2].kind != TokenType::MmioData {
                return Err("QLI-16 ReadOk requires two data tokens");
            }
            Ok(MmioResponse::ReadOk(u32::from(tokens[1].payload) | (u32::from(tokens[2].payload) << 16)))
        }
        1 if tokens.len() == 1 => Ok(MmioResponse::WriteOk),
        2 if tokens.len() == 1 => Ok(MmioResponse::Error),
        _ => Err("invalid QLI-16 MMIO response"),
    }
}

/// QLI-16 has no spare token class. MMIO_CANCEL therefore reuses the
/// MMIO_RESPONSE class in the otherwise-unused QIC->device direction.
/// Payload zero is the only valid cancellation encoding.
pub fn encode_mmio_cancel() -> Token {
    token(TokenType::MmioResponse, 0, Direction::QicToDevice)
}

pub fn is_mmio_cancel(token: Token) -> bool {
    token.kind == TokenType::MmioResponse
        && token.direction == Direction::QicToDevice
        && token.payload == 0
}

fn burst_code(req: &DmaRequest) -> u16 {
    match req.words.words() {
        1 => 0,
        4 => 1,
        8 => 2,
        16 => 3,
        _ => unreachable!(),
    }
}

pub fn encode_dma_request(req: DmaRequest) -> Result<Vec<Token>, &'static str> {
    req.validate()?;
    let meta = match req.direction {
        DmaDirection::HostToDevice => 0,
        DmaDirection::DeviceToHost => 1,
    } | (burst_code(&req) << 1);
    Ok(vec![
        token(TokenType::DmaHeader, req.address as u16, Direction::DeviceToQic),
        token(TokenType::DmaHeader, (req.address >> 16) as u16, Direction::DeviceToQic),
        token(TokenType::DmaHeader, meta, Direction::DeviceToQic),
    ])
}

pub fn encode_dma_word(word: DmaWord, direction: Direction) -> [Token; 2] {
    [
        token(TokenType::DmaData, word.data as u16, direction),
        token(TokenType::DmaData, (word.data >> 16) as u16, direction),
    ]
}

pub fn decode_dma_word(tokens: &[Token]) -> Result<DmaWord, &'static str> {
    if tokens.len() != 2 || tokens[0].kind != TokenType::DmaData || tokens[1].kind != TokenType::DmaData {
        return Err("QLI-16 DMA word requires two data tokens");
    }
    if tokens[0].direction != tokens[1].direction {
        return Err("QLI-16 DMA word changed direction mid-word");
    }
    Ok(DmaWord { data: u32::from(tokens[0].payload) | (u32::from(tokens[1].payload) << 16) })
}

fn status_code(status: DmaStatus) -> u16 {
    match status {
        DmaStatus::Ok => 0,
        DmaStatus::BusError => 1,
        DmaStatus::ParityError => 2,
        DmaStatus::Timeout => 3,
        DmaStatus::ProtocolError => 4,
    }
}

pub fn encode_dma_completion(c: DmaCompletion) -> Result<Token, &'static str> {
    if c.words_completed > 16 {
        return Err("QLI-16 completion word count out of range");
    }
    Ok(token(
        TokenType::DmaCompletion,
        status_code(c.status) | (u16::from(c.words_completed) << 3),
        Direction::QicToDevice,
    ))
}

pub fn encode_notification(req: NotificationRequest) -> Result<Token, &'static str> {
    req.validate()?;
    Ok(token(TokenType::Notification, u16::from(req.channel), Direction::DeviceToQic))
}

#[cfg(test)]
mod tests {
    use super::*;
    use plio_logical_model::BurstWords;
    use qli_model::{DmaDirection, DmaStatus};

    #[test]
    fn mmio_round_trip_read_and_write() {
        for req in [
            MmioRequest { address: 0x101, write: false, byte_enable: 0x2, write_data: 0 },
            MmioRequest { address: 0x104, write: true, byte_enable: 0xf, write_data: 0x89ab_cdef },
        ] {
            let encoded = encode_mmio_request(req).unwrap();
            assert_eq!(decode_mmio_request(&encoded).unwrap(), req);
        }
    }

    #[test]
    fn mmio_response_round_trip() {
        for resp in [MmioResponse::ReadOk(0x1234_5678), MmioResponse::WriteOk, MmioResponse::Error] {
            let encoded = encode_mmio_response(resp);
            assert_eq!(decode_mmio_response(&encoded).unwrap(), resp);
        }
    }

    #[test]
    fn mmio_cancel_is_unambiguous_from_device_responses() {
        let cancel = encode_mmio_cancel();
        assert!(is_mmio_cancel(cancel));
        assert_eq!(cancel.kind, TokenType::MmioResponse);
        assert_eq!(cancel.direction, Direction::QicToDevice);
        assert_eq!(cancel.payload, 0);
        for response in [MmioResponse::ReadOk(0), MmioResponse::WriteOk, MmioResponse::Error] {
            assert!(encode_mmio_response(response).iter().all(|t| !is_mmio_cancel(*t)));
        }
        assert!(!is_mmio_cancel(Token { kind: TokenType::MmioResponse, payload: 1, direction: Direction::QicToDevice }));
    }

    #[test]
    fn dma_word_is_exactly_two_halfwords() {
        let tokens = encode_dma_word(DmaWord { data: 0xaabb_ccdd }, Direction::DeviceToQic);
        assert_eq!(tokens[0].payload, 0xccdd);
        assert_eq!(tokens[1].payload, 0xaabb);
        assert_eq!(decode_dma_word(&tokens).unwrap().data, 0xaabb_ccdd);
    }

    #[test]
    fn dma_request_encodes_all_bursts() {
        for burst in [BurstWords::One, BurstWords::Four, BurstWords::Eight, BurstWords::Sixteen] {
            let req = DmaRequest { direction: DmaDirection::DeviceToHost, address: 0x1234_5000, words: burst };
            let encoded = encode_dma_request(req).unwrap();
            assert_eq!(encoded.len(), 3);
            assert_eq!(encoded[2].payload & 1, 1);
        }
    }

    #[test]
    fn completion_and_notification_fit_one_token() {
        let c = encode_dma_completion(DmaCompletion { status: DmaStatus::ParityError, words_completed: 7 }).unwrap();
        assert_eq!(c.payload, 2 | (7 << 3));
        let n = encode_notification(NotificationRequest { channel: 3 }).unwrap();
        assert_eq!(n.payload, 3);
    }

    #[test]
    fn malformed_reserved_mmio_bits_are_rejected() {
        let mut tokens = encode_mmio_request(MmioRequest { address: 0x100, write: false, byte_enable: 1, write_data: 0 }).unwrap();
        tokens[1].payload |= 0x8000;
        assert!(decode_mmio_request(&tokens).is_err());
    }
}

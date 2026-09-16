use crate::{
    encode_dma_completion, encode_dma_request, encode_dma_word, encode_mmio_cancel,
    encode_mmio_request, encode_mmio_response, encode_notification, Direction, Token, TokenType,
};
use qli_model::{
    DeviceToQic, DmaCompletion, DmaRequest, DmaWord, MmioRequest, MmioResponse,
    NotificationRequest, QicToDevice,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SlotTrace {
    pub valid: bool,
    pub ack: bool,
    pub token: Token,
}

impl SlotTrace {
    fn idle() -> Self {
        Self {
            valid: false,
            ack: false,
            token: Token {
                kind: TokenType::Idle,
                payload: 0,
                direction: Direction::QicToDevice,
            },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum QTag {
    MmioRequest(MmioRequest),
    MmioCancel,
    DmaRead(DmaWord),
    DmaCompletion(DmaCompletion),
    NotificationCompletion(NotificationRequest),
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum DTag {
    MmioResponse(MmioResponse),
    DmaRequest(DmaRequest),
    DmaWrite(DmaWord),
    NotificationRequest(NotificationRequest),
}

#[derive(Debug, Clone)]
struct Tx<T> {
    tokens: Vec<Token>,
    index: usize,
    tag: T,
}

impl<T> Tx<T> {
    fn current(&self) -> Token { self.tokens[self.index] }
    fn final_token(&self) -> bool { self.index + 1 == self.tokens.len() }
}

#[derive(Debug, Clone)]
pub struct CycleResult {
    pub to_qic: DeviceToQic,
    pub to_device: QicToDevice,
    pub slots: [SlotTrace; 2],
    pub protocol_fault: bool,
}

/// Stateful QLI-16 physical link reference model.
///
/// One call to `cycle` represents one PLIO clock and therefore exactly two
/// QLI-16 local transfer slots. Semantic valid/ready handshakes complete only
/// when the final token of a message is accepted on the physical link.
#[derive(Debug, Clone, Default)]
pub struct LinkCodec {
    q2d: Option<Tx<QTag>>,
    d2q: Option<Tx<DTag>>,
    last_direction: Option<Direction>,
    notification_to_qic: Option<NotificationRequest>,
    notification_completion_pending: Option<NotificationRequest>,
    protocol_fault: bool,
}

impl LinkCodec {
    pub fn new() -> Self { Self::default() }

    pub fn protocol_fault(&self) -> bool { self.protocol_fault }

    pub fn reset(&mut self) {
        *self = Self::default();
    }

    fn q2d_start(&mut self, qic: &QicToDevice) {
        if self.q2d.is_some() { return; }

        if qic.mmio_cancel {
            self.q2d = Some(Tx { tokens: vec![encode_mmio_cancel()], index: 0, tag: QTag::MmioCancel });
        } else if let Some(req) = qic.mmio_request {
            if let Ok(tokens) = encode_mmio_request(req) {
                self.q2d = Some(Tx { tokens, index: 0, tag: QTag::MmioRequest(req) });
            } else {
                self.protocol_fault = true;
            }
        } else if let Some(word) = qic.dma_read {
            self.q2d = Some(Tx {
                tokens: encode_dma_word(word, Direction::QicToDevice).to_vec(),
                index: 0,
                tag: QTag::DmaRead(word),
            });
        } else if let Some(completion) = qic.dma_completion {
            match encode_dma_completion(completion) {
                Ok(token) => self.q2d = Some(Tx { tokens: vec![token], index: 0, tag: QTag::DmaCompletion(completion) }),
                Err(_) => self.protocol_fault = true,
            }
        } else if let Some(req) = self.notification_completion_pending {
            match encode_notification_completion(req) {
                Ok(token) => self.q2d = Some(Tx { tokens: vec![token], index: 0, tag: QTag::NotificationCompletion(req) }),
                Err(_) => self.protocol_fault = true,
            }
        }
    }

    fn d2q_start(&mut self, qic: &QicToDevice, device: &DeviceToQic) {
        if self.d2q.is_some() { return; }

        if let Some(resp) = device.mmio_response {
            self.d2q = Some(Tx { tokens: encode_mmio_response(resp), index: 0, tag: DTag::MmioResponse(resp) });
        } else if let Some(req) = device.dma_request {
            match encode_dma_request(req) {
                Ok(tokens) => self.d2q = Some(Tx { tokens, index: 0, tag: DTag::DmaRequest(req) }),
                Err(_) => self.protocol_fault = true,
            }
        } else if let Some(word) = device.dma_write {
            // QLI-16 is half duplex and direction changes are only legal
            // between complete messages. Do not put the first DMA_DATA token
            // on the wire until QIC can accept the complete semantic word;
            // otherwise its final token can stall the D2Q direction and block
            // an intervening worker MMIO request in the reverse direction.
            if qic.dma_write_ready {
                self.d2q = Some(Tx {
                    tokens: encode_dma_word(word, Direction::DeviceToQic).to_vec(),
                    index: 0,
                    tag: DTag::DmaWrite(word),
                });
            }
            // DMA data retains its priority while valid. In particular, do not
            // bypass a blocked data word with a lower-priority notification.
        } else if self.notification_to_qic.is_none() && self.notification_completion_pending.is_none() {
            if let Some(req) = device.notification_request {
                match encode_notification(req) {
                    Ok(token) => self.d2q = Some(Tx { tokens: vec![token], index: 0, tag: DTag::NotificationRequest(req) }),
                    Err(_) => self.protocol_fault = true,
                }
            }
        }
    }

    fn desired_direction(&self) -> Option<Direction> {
        match self.last_direction {
            Some(Direction::QicToDevice) if self.q2d.is_some() => Some(Direction::QicToDevice),
            Some(Direction::DeviceToQic) if self.d2q.is_some() => Some(Direction::DeviceToQic),
            _ if self.q2d.is_some() => Some(Direction::QicToDevice),
            _ if self.d2q.is_some() => Some(Direction::DeviceToQic),
            _ => None,
        }
    }

    fn q2d_final_ready(tag: &QTag, device: &DeviceToQic) -> bool {
        match tag {
            QTag::MmioRequest(_) => device.mmio_ready,
            QTag::MmioCancel => true,
            QTag::DmaRead(_) => device.dma_read_ready,
            QTag::DmaCompletion(_) => device.dma_completion_ready,
            QTag::NotificationCompletion(_) => true,
        }
    }

    fn d2q_final_ready(tag: &DTag, qic: &QicToDevice) -> bool {
        match tag {
            DTag::MmioResponse(_) => qic.mmio_response_ready,
            DTag::DmaRequest(_) => qic.dma_request_ready,
            DTag::DmaWrite(_) => qic.dma_write_ready,
            DTag::NotificationRequest(_) => true,
        }
    }

    fn accept_q2d(&mut self, result: &mut CycleResult) {
        let tx = self.q2d.take().expect("q2d tx");
        match tx.tag {
            QTag::MmioRequest(req) => {
                result.to_device.mmio_request = Some(req);
                result.to_qic.mmio_ready = true;
            }
            QTag::MmioCancel => result.to_device.mmio_cancel = true,
            QTag::DmaRead(word) => {
                result.to_device.dma_read = Some(word);
                result.to_qic.dma_read_ready = true;
            }
            QTag::DmaCompletion(c) => {
                result.to_device.dma_completion = Some(c);
                result.to_qic.dma_completion_ready = true;
            }
            QTag::NotificationCompletion(req) => {
                result.to_device.notification_ready = true;
                if self.notification_completion_pending == Some(req) {
                    self.notification_completion_pending = None;
                } else {
                    self.protocol_fault = true;
                }
            }
        }
    }

    fn accept_d2q(&mut self, result: &mut CycleResult) {
        let tx = self.d2q.take().expect("d2q tx");
        match tx.tag {
            DTag::MmioResponse(resp) => {
                result.to_qic.mmio_response = Some(resp);
                result.to_device.mmio_response_ready = true;
            }
            DTag::DmaRequest(req) => {
                result.to_qic.dma_request = Some(req);
                result.to_device.dma_request_ready = true;
            }
            DTag::DmaWrite(word) => {
                result.to_qic.dma_write = Some(word);
                result.to_device.dma_write_ready = true;
            }
            DTag::NotificationRequest(req) => {
                if self.notification_to_qic.is_none() {
                    self.notification_to_qic = Some(req);
                    result.to_qic.notification_request = Some(req);
                } else if self.notification_to_qic != Some(req) {
                    self.protocol_fault = true;
                }
            }
        }
    }

    fn one_slot(&mut self, qic: &QicToDevice, device: &DeviceToQic, result: &mut CycleResult) -> SlotTrace {
        let Some(direction) = self.desired_direction() else {
            self.last_direction = None;
            return SlotTrace::idle();
        };

        if let Some(last) = self.last_direction {
            if last != direction {
                self.last_direction = None;
                return SlotTrace::idle();
            }
        }

        self.last_direction = Some(direction);
        match direction {
            Direction::QicToDevice => {
                let (token, final_token, ack) = {
                    let tx = self.q2d.as_ref().expect("q2d");
                    let final_token = tx.final_token();
                    let ack = !final_token || Self::q2d_final_ready(&tx.tag, device);
                    (tx.current(), final_token, ack)
                };
                if ack {
                    if final_token {
                        self.accept_q2d(result);
                    } else if let Some(tx) = self.q2d.as_mut() {
                        tx.index += 1;
                    }
                }
                SlotTrace { valid: true, ack, token }
            }
            Direction::DeviceToQic => {
                let (token, final_token, ack) = {
                    let tx = self.d2q.as_ref().expect("d2q");
                    let final_token = tx.final_token();
                    let ack = !final_token || Self::d2q_final_ready(&tx.tag, qic);
                    (tx.current(), final_token, ack)
                };
                if ack {
                    if final_token {
                        self.accept_d2q(result);
                    } else if let Some(tx) = self.d2q.as_mut() {
                        tx.index += 1;
                    }
                }
                SlotTrace { valid: true, ack, token }
            }
        }
    }

    pub fn cycle(&mut self, reset: bool, qic: QicToDevice, device: DeviceToQic) -> CycleResult {
        if reset {
            self.reset();
            let mut result = CycleResult {
                to_qic: DeviceToQic::default(),
                to_device: QicToDevice::default(),
                slots: [SlotTrace::idle(), SlotTrace::idle()],
                protocol_fault: false,
            };
            result.to_device.reset = true;
            return result;
        }

        if let Some(req) = self.notification_to_qic {
            if qic.notification_ready {
                self.notification_to_qic = None;
                self.notification_completion_pending = Some(req);
            }
        }

        self.q2d_start(&qic);
        self.d2q_start(&qic, &device);

        let mut result = CycleResult {
            to_qic: DeviceToQic::default(),
            to_device: QicToDevice::default(),
            slots: [SlotTrace::idle(), SlotTrace::idle()],
            protocol_fault: self.protocol_fault,
        };
        if let Some(req) = self.notification_to_qic {
            result.to_qic.notification_request = Some(req);
        }

        result.slots[0] = self.one_slot(&qic, &device, &mut result);
        result.slots[1] = self.one_slot(&qic, &device, &mut result);
        result.protocol_fault = self.protocol_fault;
        result
    }

    /// Simulation hook for malformed physical input tests. It validates the
    /// reserved/directional constraints that can be checked from one token and
    /// makes the local protocol fault sticky until reset.
    pub fn inject_raw_token(&mut self, token: Token) {
        let malformed = match token.kind {
            TokenType::Idle => token.payload != 0,
            TokenType::MmioResponse if token.direction == Direction::QicToDevice => token.payload != 0,
            TokenType::MmioResponse => token.payload & !0x0003 != 0 || (token.payload & 3) == 3,
            TokenType::DmaHeader => token.direction != Direction::DeviceToQic,
            TokenType::DmaCompletion => token.direction != Direction::QicToDevice || token.payload & 0xff00 != 0 || (token.payload & 7) > 4,
            TokenType::Notification => token.payload & !0x0003 != 0,
            _ => false,
        };
        self.protocol_fault |= malformed;
    }
}

/// QIC->device NOTIFICATION is the completion half of the directional
/// Notification pair. Device->QIC remains the request encoding.
pub fn encode_notification_completion(req: NotificationRequest) -> Result<Token, &'static str> {
    req.validate()?;
    Ok(Token {
        kind: TokenType::Notification,
        payload: u16::from(req.channel),
        direction: Direction::QicToDevice,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use plio_logical_model::BurstWords;
    use qli_model::{DmaDirection, DmaStatus};

    #[test]
    fn final_token_holds_until_semantic_ready() {
        let mut link = LinkCodec::new();
        let req = MmioRequest { address: 0x100, write: false, byte_enable: 0xf, write_data: 0 };
        let qic = QicToDevice { mmio_request: Some(req), ..Default::default() };
        let dev = DeviceToQic::default();
        let first = link.cycle(false, qic, dev);
        assert!(first.slots[0].ack);
        assert!(!first.slots[1].ack);
        let second = link.cycle(false, qic, dev);
        assert_eq!(first.slots[1].token, second.slots[0].token);
        assert!(!second.slots[0].ack);
        let ready = DeviceToQic { mmio_ready: true, ..Default::default() };
        let third = link.cycle(false, qic, ready);
        assert!(third.slots.iter().any(|s| s.ack));
        assert_eq!(third.to_device.mmio_request, Some(req));
        assert!(third.to_qic.mmio_ready);
    }

    #[test]
    fn direction_change_inserts_idle_slot() {
        let mut link = LinkCodec::new();
        let qic = QicToDevice { mmio_cancel: true, ..Default::default() };
        let _ = link.cycle(false, qic, DeviceToQic::default());
        let resp = DeviceToQic { mmio_response: Some(MmioResponse::WriteOk), ..Default::default() };
        let qready = QicToDevice { mmio_response_ready: true, ..Default::default() };
        let c = link.cycle(false, qready, resp);
        assert!(!c.slots[0].valid, "turnaround must consume one idle slot");
        assert!(c.slots[1].valid);
        assert_eq!(c.slots[1].token.direction, Direction::DeviceToQic);
    }

    #[test]
    fn unready_device_dma_word_does_not_block_reverse_mmio() {
        let mut link = LinkCodec::new();
        let word = DmaWord { data: 0x1234_5678 };
        let req = MmioRequest { address: 0x134, write: false, byte_enable: 0xf, write_data: 0 };
        let device = DeviceToQic { dma_write: Some(word), mmio_ready: true, ..Default::default() };
        let qic = QicToDevice { mmio_request: Some(req), dma_write_ready: false, ..Default::default() };

        let mut saw_mmio = false;
        for _ in 0..4 {
            let cycle = link.cycle(false, qic, device);
            assert!(cycle.slots.iter().all(|slot| !slot.valid || slot.token.direction != Direction::DeviceToQic),
                "unready DMA_DATA must not claim the D2Q wire");
            saw_mmio |= cycle.to_device.mmio_request == Some(req);
        }
        assert!(saw_mmio, "reverse MMIO must make progress while DMA data waits for QIC readiness");

        let ready_qic = QicToDevice { dma_write_ready: true, ..Default::default() };
        let mut saw_dma = false;
        for _ in 0..3 {
            let cycle = link.cycle(false, ready_qic, DeviceToQic { dma_write: Some(word), ..Default::default() });
            saw_dma |= cycle.to_qic.dma_write == Some(word);
        }
        assert!(saw_dma, "DMA_DATA must cross once QIC advertises readiness");
    }

    #[test]
    fn notification_ready_crosses_back_as_completion_token() {
        let mut link = LinkCodec::new();
        let req = NotificationRequest { channel: 3 };
        let dev = DeviceToQic { notification_request: Some(req), ..Default::default() };
        let accepted = link.cycle(false, QicToDevice::default(), dev);
        assert_eq!(accepted.to_qic.notification_request, Some(req));
        let qic = QicToDevice { notification_ready: true, ..Default::default() };
        let completed = link.cycle(false, qic, dev);
        assert!(completed.slots.iter().any(|s| s.valid && s.token.direction == Direction::QicToDevice && s.token.kind == TokenType::Notification));
        assert!(completed.to_device.notification_ready);
    }

    #[test]
    fn all_dma_bursts_and_completion_cross_physical_link() {
        for words in [BurstWords::One, BurstWords::Four, BurstWords::Eight, BurstWords::Sixteen] {
            let mut link = LinkCodec::new();
            let req = DmaRequest { direction: DmaDirection::DeviceToHost, address: 0x1000, words };
            let dev = DeviceToQic { dma_request: Some(req), ..Default::default() };
            let qic = QicToDevice { dma_request_ready: true, ..Default::default() };
            let mut seen = false;
            for _ in 0..3 {
                let c = link.cycle(false, qic, dev);
                seen |= c.to_qic.dma_request == Some(req);
            }
            assert!(seen);
        }

        let mut link = LinkCodec::new();
        let c = DmaCompletion { status: DmaStatus::BusError, words_completed: 3 };
        let qic = QicToDevice { dma_completion: Some(c), ..Default::default() };
        let dev = DeviceToQic { dma_completion_ready: true, ..Default::default() };
        let r = link.cycle(false, qic, dev);
        assert_eq!(r.to_device.dma_completion, Some(c));
    }

    #[test]
    fn malformed_reserved_token_sets_sticky_fault_and_reset_clears_it() {
        let mut link = LinkCodec::new();
        link.inject_raw_token(Token { kind: TokenType::Notification, payload: 0x8000, direction: Direction::DeviceToQic });
        assert!(link.protocol_fault());
        let r = link.cycle(true, QicToDevice::default(), DeviceToQic::default());
        assert!(!r.protocol_fault);
        assert!(!link.protocol_fault());
    }
}

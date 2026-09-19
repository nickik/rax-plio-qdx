#![forbid(unsafe_code)]

use plio_logical_model::BurstWords;
use qli_model::{
    DeviceToQic, DmaDirection, DmaRequest, DmaStatus, DmaWord, MmioRequest,
    MmioResponse, NotificationRequest, QicToDevice,
};

pub const QDX_CAP_VALUE: u32 = 0x0032_4501;

pub const REG_QDX_CAP: u32 = 0x0000_1000;
pub const REG_QDX_STATUS: u32 = 0x0000_1004;
pub const REG_QDX_CONTROL: u32 = 0x0000_1008;
pub const REG_SQ_BASE: u32 = 0x0000_1010;
pub const REG_SQ_SIZE: u32 = 0x0000_1014;
pub const REG_SQ_TAIL: u32 = 0x0000_1018;
pub const REG_CQ_BASE: u32 = 0x0000_1020;
pub const REG_CQ_SIZE: u32 = 0x0000_1024;
pub const REG_CQ_HEAD: u32 = 0x0000_1028;
pub const REG_SQ_HEAD: u32 = 0x0000_1030;
pub const REG_CQ_TAIL: u32 = 0x0000_1034;
pub const REG_QDX_ERROR: u32 = 0x0000_1038;

pub type QdxACommand = [u32; 8];
pub type QdxACompletion = [u32; 4];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QdxAState {
    Disabled,
    ReadyIdle,
    SqRequest,
    SqReceive,
    SqCompletion,
    EndpointOffer,
    EndpointCompletion,
    CqRequest,
    CqSend,
    CqCompletion,
    Notify,
    Fault,
}

impl QdxAState {
    pub const fn trace_name(self) -> &'static str {
        match self {
            Self::Disabled => "disabled",
            Self::ReadyIdle => "ready",
            Self::SqRequest => "sq_req",
            Self::SqReceive => "sq_recv",
            Self::SqCompletion => "sq_done",
            Self::EndpointOffer => "ep_offer",
            Self::EndpointCompletion => "ep_wait",
            Self::CqRequest => "cq_req",
            Self::CqSend => "cq_send",
            Self::CqCompletion => "cq_done",
            Self::Notify => "notify",
            Self::Fault => "fault",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QdxAError {
    None,
    BadConfig,
    SqDma,
    CqDma,
    QueueProtocol,
    EndpointProtocol,
}

impl QdxAError {
    pub const fn code(self) -> u32 {
        match self {
            Self::None => 0,
            Self::BadConfig => 1,
            Self::SqDma => 2,
            Self::CqDma => 3,
            Self::QueueProtocol => 4,
            Self::EndpointProtocol => 5,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct EndpointIn {
    pub command_ready: bool,
    pub completion: Option<QdxACompletion>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct EndpointOut {
    pub reset: bool,
    pub command: Option<QdxACommand>,
    pub completion_ready: bool,
}

#[derive(Debug, Clone)]
pub struct QdxA {
    state: QdxAState,
    error: QdxAError,
    enabled: bool,
    notify_enable: bool,
    sq_base: u32,
    sq_size: u16,
    sq_head: u16,
    sq_tail: u16,
    cq_base: u32,
    cq_size: u16,
    cq_head: u16,
    cq_tail: u16,
    mmio_response: Option<MmioResponse>,
    command_buffer: QdxACommand,
    completion_buffer: QdxACompletion,
    sq_word: u8,
    cq_word: u8,
    endpoint_reset_pulse: bool,
}

impl Default for QdxA {
    fn default() -> Self {
        Self::new()
    }
}

impl QdxA {
    pub const fn new() -> Self {
        Self {
            state: QdxAState::Disabled,
            error: QdxAError::None,
            enabled: false,
            notify_enable: false,
            sq_base: 0,
            sq_size: 0,
            sq_head: 0,
            sq_tail: 0,
            cq_base: 0,
            cq_size: 0,
            cq_head: 0,
            cq_tail: 0,
            mmio_response: None,
            command_buffer: [0; 8],
            completion_buffer: [0; 4],
            sq_word: 0,
            cq_word: 0,
            endpoint_reset_pulse: false,
        }
    }

    pub const fn state(&self) -> QdxAState { self.state }
    pub const fn error(&self) -> QdxAError { self.error }
    pub const fn sq_head(&self) -> u16 { self.sq_head }
    pub const fn sq_tail(&self) -> u16 { self.sq_tail }
    pub const fn cq_head(&self) -> u16 { self.cq_head }
    pub const fn cq_tail(&self) -> u16 { self.cq_tail }

    pub fn qic_port(&self, qic: &QicToDevice) -> DeviceToQic {
        let mut out = DeviceToQic::default();
        out.mmio_ready = self.mmio_response.is_none() && !qic.reset;
        out.mmio_response = self.mmio_response;

        match self.state {
            QdxAState::SqRequest => {
                out.dma_request = Some(DmaRequest {
                    direction: DmaDirection::HostToDevice,
                    address: sq_entry_address(self.sq_base, self.sq_head),
                    words: BurstWords::Eight,
                });
            }
            QdxAState::SqReceive => out.dma_read_ready = true,
            QdxAState::SqCompletion => out.dma_completion_ready = true,
            QdxAState::CqRequest => {
                out.dma_request = Some(DmaRequest {
                    direction: DmaDirection::DeviceToHost,
                    address: cq_entry_address(self.cq_base, self.cq_tail),
                    words: BurstWords::Four,
                });
            }
            QdxAState::CqSend => {
                out.dma_write = Some(DmaWord {
                    data: self.completion_buffer[self.cq_word as usize],
                });
            }
            QdxAState::CqCompletion => out.dma_completion_ready = true,
            QdxAState::Notify => {
                out.notification_request = Some(NotificationRequest { channel: 0 });
            }
            _ => {}
        }
        out
    }

    pub fn endpoint_port(&self, qic: &QicToDevice) -> EndpointOut {
        EndpointOut {
            reset: qic.reset || self.endpoint_reset_pulse,
            command: (self.state == QdxAState::EndpointOffer).then_some(self.command_buffer),
            completion_ready: self.state == QdxAState::EndpointCompletion
                && self.cq_tail.wrapping_sub(self.cq_head) < 4,
        }
    }

    pub fn advance(&mut self, qic: &QicToDevice, endpoint: &EndpointIn) {
        let accepts_mmio = self.mmio_response.is_none() && !qic.reset && qic.mmio_request.is_some();
        let req = qic.mmio_request;
        let soft_reset = accepts_mmio
            && matches!(req, Some(r) if r.write
                && r.address == REG_QDX_CONTROL
                && r.byte_enable == 0xf
                && (r.write_data & 0x2) != 0);

        if qic.reset {
            self.hard_reset();
            return;
        }
        if soft_reset {
            self.soft_reset_with_response();
            return;
        }

        self.endpoint_reset_pulse = false;

        // Match the PR #6 Bluespec control priority exactly. MMIO response
        // consumption/cancel, MMIO request acceptance, and engine advancement
        // are mutually exclusive within one cycle.
        if self.mmio_response.is_some() && qic.mmio_response_ready {
            self.mmio_response = None;
            return;
        } else if qic.mmio_cancel {
            self.mmio_response = None;
            return;
        } else if accepts_mmio {
            self.accept_mmio(req.expect("accepts_mmio implies request"));
            return;
        }

        match self.state {
            QdxAState::Disabled => {}
            QdxAState::ReadyIdle => {
                let cq_used = self.cq_tail.wrapping_sub(self.cq_head);
                if self.sq_head != self.sq_tail && cq_used < 4 {
                    self.sq_word = 0;
                    self.state = QdxAState::SqRequest;
                }
            }
            QdxAState::SqRequest => {
                if qic.dma_request_ready {
                    self.sq_word = 0;
                    self.state = QdxAState::SqReceive;
                }
            }
            QdxAState::SqReceive => {
                if let Some(word) = qic.dma_read {
                    self.command_buffer[self.sq_word as usize] = word.data;
                    if self.sq_word == 7 {
                        self.state = QdxAState::SqCompletion;
                    } else {
                        self.sq_word += 1;
                    }
                }
            }
            QdxAState::SqCompletion => {
                if let Some(completion) = qic.dma_completion {
                    if completion.status == DmaStatus::Ok && completion.words_completed == 8 {
                        self.sq_head = self.sq_head.wrapping_add(1);
                        self.state = QdxAState::EndpointOffer;
                    } else {
                        self.error = QdxAError::SqDma;
                        self.state = QdxAState::Fault;
                    }
                }
            }
            QdxAState::EndpointOffer => {
                if endpoint.command_ready {
                    self.state = QdxAState::EndpointCompletion;
                }
            }
            QdxAState::EndpointCompletion => {
                let cq_used = self.cq_tail.wrapping_sub(self.cq_head);
                if let Some(completion) = endpoint.completion {
                    if cq_used < 4 {
                        self.completion_buffer = completion;
                        self.cq_word = 0;
                        self.state = QdxAState::CqRequest;
                    }
                }
            }
            QdxAState::CqRequest => {
                if qic.dma_request_ready {
                    self.cq_word = 0;
                    self.state = QdxAState::CqSend;
                }
            }
            QdxAState::CqSend => {
                if qic.dma_write_ready {
                    if self.cq_word == 3 {
                        self.state = QdxAState::CqCompletion;
                    } else {
                        self.cq_word += 1;
                    }
                }
            }
            QdxAState::CqCompletion => {
                if let Some(completion) = qic.dma_completion {
                    if completion.status == DmaStatus::Ok && completion.words_completed == 4 {
                        let was_empty = self.cq_tail == self.cq_head;
                        self.cq_tail = self.cq_tail.wrapping_add(1);
                        self.state = if was_empty && self.notify_enable {
                            QdxAState::Notify
                        } else {
                            QdxAState::ReadyIdle
                        };
                    } else {
                        self.error = QdxAError::CqDma;
                        self.state = QdxAState::Fault;
                    }
                }
            }
            QdxAState::Notify => {
                if qic.notification_ready {
                    self.state = QdxAState::ReadyIdle;
                }
            }
            QdxAState::Fault => {}
        }
    }

    fn hard_reset(&mut self) {
        self.state = QdxAState::Disabled;
        self.error = QdxAError::None;
        self.enabled = false;
        self.notify_enable = false;
        self.sq_base = 0;
        self.sq_size = 0;
        self.sq_head = 0;
        self.sq_tail = 0;
        self.cq_base = 0;
        self.cq_size = 0;
        self.cq_head = 0;
        self.cq_tail = 0;
        self.mmio_response = None;
        self.command_buffer = [0; 8];
        self.completion_buffer = [0; 4];
        self.sq_word = 0;
        self.cq_word = 0;
        self.endpoint_reset_pulse = true;
    }

    fn soft_reset_with_response(&mut self) {
        self.hard_reset();
        self.mmio_response = Some(MmioResponse::WriteOk);
    }

    fn accept_mmio(&mut self, req: MmioRequest) {
        let response = if !req.write {
            self.mmio_read(req)
        } else {
            self.mmio_write(req)
        };
        self.mmio_response = Some(response.unwrap_or(MmioResponse::Error));
    }

    fn mmio_read(&self, req: MmioRequest) -> Option<MmioResponse> {
        let data = match req.address {
            REG_QDX_CAP if req.byte_enable == 0xf => QDX_CAP_VALUE,
            REG_QDX_STATUS if req.byte_enable == 0xf => status_value(self.state),
            REG_QDX_CONTROL if req.byte_enable == 0xf => {
                (self.enabled as u32) | ((self.notify_enable as u32) << 2)
            }
            REG_SQ_BASE if req.byte_enable == 0xf => self.sq_base,
            REG_SQ_SIZE if req.byte_enable == 0x3 => u32::from(self.sq_size),
            REG_SQ_TAIL if req.byte_enable == 0x3 => u32::from(self.sq_tail),
            REG_CQ_BASE if req.byte_enable == 0xf => self.cq_base,
            REG_CQ_SIZE if req.byte_enable == 0x3 => u32::from(self.cq_size),
            REG_CQ_HEAD if req.byte_enable == 0x3 => u32::from(self.cq_head),
            REG_SQ_HEAD if req.byte_enable == 0x3 => u32::from(self.sq_head),
            REG_CQ_TAIL if req.byte_enable == 0x3 => u32::from(self.cq_tail),
            REG_QDX_ERROR if req.byte_enable == 0xf => self.error.code(),
            _ => return None,
        };
        Some(MmioResponse::ReadOk(data))
    }

    fn mmio_write(&mut self, req: MmioRequest) -> Option<MmioResponse> {
        match req.address {
            REG_QDX_CONTROL if req.byte_enable == 0xf && self.state == QdxAState::Disabled => {
                self.notify_enable = (req.write_data & 0x4) != 0;
                if (req.write_data & 0x1) != 0 {
                    self.enabled = true;
                    if valid_configuration(self.sq_base, self.sq_size, self.cq_base, self.cq_size) {
                        self.error = QdxAError::None;
                        self.state = QdxAState::ReadyIdle;
                    } else {
                        self.error = QdxAError::BadConfig;
                        self.state = QdxAState::Fault;
                    }
                } else {
                    self.enabled = false;
                }
                Some(MmioResponse::WriteOk)
            }
            REG_SQ_BASE if req.byte_enable == 0xf && self.state == QdxAState::Disabled => {
                self.sq_base = req.write_data;
                Some(MmioResponse::WriteOk)
            }
            REG_SQ_SIZE if req.byte_enable == 0x3 && self.state == QdxAState::Disabled => {
                self.sq_size = req.write_data as u16;
                Some(MmioResponse::WriteOk)
            }
            REG_CQ_BASE if req.byte_enable == 0xf && self.state == QdxAState::Disabled => {
                self.cq_base = req.write_data;
                Some(MmioResponse::WriteOk)
            }
            REG_CQ_SIZE if req.byte_enable == 0x3 && self.state == QdxAState::Disabled => {
                self.cq_size = req.write_data as u16;
                Some(MmioResponse::WriteOk)
            }
            REG_SQ_TAIL if req.byte_enable == 0x3 && is_ready_state(self.state) => {
                let new_tail = req.write_data as u16;
                let occupancy = new_tail.wrapping_sub(self.sq_head);
                if occupancy <= 4 {
                    self.sq_tail = new_tail;
                    Some(MmioResponse::WriteOk)
                } else {
                    self.error = QdxAError::QueueProtocol;
                    self.state = QdxAState::Fault;
                    None
                }
            }
            REG_CQ_HEAD if req.byte_enable == 0x3 && is_ready_state(self.state) => {
                let new_head = req.write_data as u16;
                let used = self.cq_tail.wrapping_sub(self.cq_head);
                let consumed = new_head.wrapping_sub(self.cq_head);
                if consumed <= used {
                    self.cq_head = new_head;
                    Some(MmioResponse::WriteOk)
                } else {
                    self.error = QdxAError::QueueProtocol;
                    self.state = QdxAState::Fault;
                    None
                }
            }
            _ => None,
        }
    }
}

pub fn sq_entry_address(base: u32, position: u16) -> u32 {
    let delta = u32::from(position & 3) << 5;
    (base & 0xff00_0000) | ((base.wrapping_add(delta)) & 0x00ff_ffff)
}

pub fn cq_entry_address(base: u32, position: u16) -> u32 {
    let delta = u32::from(position & 3) << 4;
    (base & 0xff00_0000) | ((base.wrapping_add(delta)) & 0x00ff_ffff)
}

pub fn valid_configuration(sq_base: u32, sq_size: u16, cq_base: u32, cq_size: u16) -> bool {
    sq_size == 4
        && cq_size == 4
        && (sq_base & 0x1f) == 0
        && (cq_base & 0x0f) == 0
        && (sq_base & 0x00ff_ffff) <= 0x00ff_ff80
        && (cq_base & 0x00ff_ffff) <= 0x00ff_ffc0
}

fn is_ready_state(state: QdxAState) -> bool {
    state != QdxAState::Disabled && state != QdxAState::Fault
}

fn status_value(state: QdxAState) -> u32 {
    match state {
        QdxAState::Disabled => 0,
        QdxAState::Fault => 2,
        _ => 1,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use qli_model::DmaCompletion;

    fn mmio_write(address: u32, byte_enable: u8, data: u32) -> QicToDevice {
        QicToDevice {
            mmio_request: Some(MmioRequest {
                address,
                write: true,
                byte_enable,
                write_data: data,
            }),
            ..Default::default()
        }
    }

    fn consume_response(chip: &mut QdxA) {
        assert!(chip.qic_port(&QicToDevice::default()).mmio_response.is_some());
        chip.advance(
            &QicToDevice { mmio_response_ready: true, ..Default::default() },
            &EndpointIn::default(),
        );
    }

    fn write_reg(chip: &mut QdxA, address: u32, byte_enable: u8, data: u32) {
        let q = mmio_write(address, byte_enable, data);
        assert!(chip.qic_port(&q).mmio_ready);
        chip.advance(&q, &EndpointIn::default());
        consume_response(chip);
    }

    fn configure(chip: &mut QdxA) {
        for (address, be, data) in [
            (REG_SQ_BASE, 0xf, 0x1200_1000),
            (REG_SQ_SIZE, 0x3, 4),
            (REG_CQ_BASE, 0xf, 0x2300_2000),
            (REG_CQ_SIZE, 0x3, 4),
            (REG_QDX_CONTROL, 0xf, 5),
        ] {
            write_reg(chip, address, be, data);
        }
    }

    fn launch_sq(chip: &mut QdxA) {
        write_reg(chip, REG_SQ_TAIL, 0x3, 1);
        assert_eq!(chip.state(), QdxAState::ReadyIdle);
        chip.advance(&QicToDevice::default(), &EndpointIn::default());
        assert_eq!(chip.state(), QdxAState::SqRequest);
        chip.advance(
            &QicToDevice { dma_request_ready: true, ..Default::default() },
            &EndpointIn::default(),
        );
        assert_eq!(chip.state(), QdxAState::SqReceive);
    }

    fn reach_cq_completion(chip: &mut QdxA) {
        launch_sq(chip);
        for i in 0..8u32 {
            chip.advance(
                &QicToDevice { dma_read: Some(DmaWord { data: 0xa000_0000 + i }), ..Default::default() },
                &EndpointIn::default(),
            );
        }
        chip.advance(
            &QicToDevice {
                dma_completion: Some(DmaCompletion { status: DmaStatus::Ok, words_completed: 8 }),
                ..Default::default()
            },
            &EndpointIn::default(),
        );
        assert_eq!(chip.state(), QdxAState::EndpointOffer);
        chip.advance(
            &QicToDevice::default(),
            &EndpointIn { command_ready: true, ..Default::default() },
        );
        chip.advance(
            &QicToDevice::default(),
            &EndpointIn { completion: Some([1, 2, 3, 4]), ..Default::default() },
        );
        assert_eq!(chip.state(), QdxAState::CqRequest);
        chip.advance(
            &QicToDevice { dma_request_ready: true, ..Default::default() },
            &EndpointIn::default(),
        );
        for _ in 0..4 {
            chip.advance(
                &QicToDevice { dma_write_ready: true, ..Default::default() },
                &EndpointIn::default(),
            );
        }
        assert_eq!(chip.state(), QdxAState::CqCompletion);
    }

    #[test]
    fn reset_and_configuration_match_minimal_contract() {
        let mut chip = QdxA::new();
        chip.advance(&QicToDevice { reset: true, ..Default::default() }, &EndpointIn::default());
        assert_eq!(chip.state(), QdxAState::Disabled);
        configure(&mut chip);
        assert_eq!(chip.state(), QdxAState::ReadyIdle);
        assert_eq!(chip.error(), QdxAError::None);
    }

    #[test]
    fn bad_configuration_enters_fault() {
        let mut chip = QdxA::new();
        chip.advance(&mmio_write(REG_QDX_CONTROL, 0xf, 1), &EndpointIn::default());
        assert_eq!(chip.state(), QdxAState::Fault);
        assert_eq!(chip.error(), QdxAError::BadConfig);
    }

    #[test]
    fn ring_addresses_preserve_dma_channel_generation_byte_and_wrap_slot() {
        assert_eq!(sq_entry_address(0xab00_1000, 3), 0xab00_1060);
        assert_eq!(sq_entry_address(0xab00_1000, 4), 0xab00_1000);
        assert_eq!(cq_entry_address(0xcd00_2000, 3), 0xcd00_2030);
        assert_eq!(cq_entry_address(0xcd00_2000, 4), 0xcd00_2000);
    }

    #[test]
    fn mmio_response_consumption_has_priority_over_engine_progress() {
        let mut chip = QdxA::new();
        configure(&mut chip);
        chip.advance(&mmio_write(REG_SQ_TAIL, 0x3, 1), &EndpointIn::default());
        assert_eq!(chip.state(), QdxAState::ReadyIdle);
        assert_eq!(chip.sq_tail(), 1);
        consume_response(&mut chip);
        assert_eq!(chip.state(), QdxAState::ReadyIdle);
        chip.advance(&QicToDevice::default(), &EndpointIn::default());
        assert_eq!(chip.state(), QdxAState::SqRequest);
    }

    #[test]
    fn illegal_sq_tail_movement_faults_without_accepting_new_tail() {
        let mut chip = QdxA::new();
        configure(&mut chip);
        chip.advance(&mmio_write(REG_SQ_TAIL, 0x3, 5), &EndpointIn::default());
        assert_eq!(chip.state(), QdxAState::Fault);
        assert_eq!(chip.error(), QdxAError::QueueProtocol);
        assert_eq!(chip.sq_tail(), 0);
        assert_eq!(chip.qic_port(&QicToDevice::default()).mmio_response, Some(MmioResponse::Error));
    }

    #[test]
    fn sq_dma_failure_or_short_completion_does_not_advance_head() {
        for completion in [
            DmaCompletion { status: DmaStatus::BusError, words_completed: 8 },
            DmaCompletion { status: DmaStatus::Ok, words_completed: 7 },
        ] {
            let mut chip = QdxA::new();
            configure(&mut chip);
            launch_sq(&mut chip);
            for i in 0..8 {
                chip.advance(
                    &QicToDevice { dma_read: Some(DmaWord { data: i }), ..Default::default() },
                    &EndpointIn::default(),
                );
            }
            chip.advance(
                &QicToDevice { dma_completion: Some(completion), ..Default::default() },
                &EndpointIn::default(),
            );
            assert_eq!(chip.state(), QdxAState::Fault);
            assert_eq!(chip.sq_head(), 0);
            assert_eq!(chip.error(), QdxAError::SqDma);
        }
    }

    #[test]
    fn cq_dma_failure_or_short_completion_does_not_advance_tail() {
        for completion in [
            DmaCompletion { status: DmaStatus::BusError, words_completed: 4 },
            DmaCompletion { status: DmaStatus::Ok, words_completed: 3 },
        ] {
            let mut chip = QdxA::new();
            configure(&mut chip);
            reach_cq_completion(&mut chip);
            chip.advance(
                &QicToDevice { dma_completion: Some(completion), ..Default::default() },
                &EndpointIn::default(),
            );
            assert_eq!(chip.state(), QdxAState::Fault);
            assert_eq!(chip.cq_tail(), 0);
            assert_eq!(chip.error(), QdxAError::CqDma);
        }
    }

    #[test]
    fn endpoint_backpressure_keeps_command_stable_and_uncommitted() {
        let mut chip = QdxA::new();
        configure(&mut chip);
        launch_sq(&mut chip);
        for i in 0..8u32 {
            chip.advance(
                &QicToDevice { dma_read: Some(DmaWord { data: 0x5000_0000 + i }), ..Default::default() },
                &EndpointIn::default(),
            );
        }
        chip.advance(
            &QicToDevice {
                dma_completion: Some(DmaCompletion { status: DmaStatus::Ok, words_completed: 8 }),
                ..Default::default()
            },
            &EndpointIn::default(),
        );
        let first = chip.endpoint_port(&QicToDevice::default()).command;
        assert!(first.is_some());
        for _ in 0..8 {
            chip.advance(&QicToDevice::default(), &EndpointIn::default());
            assert_eq!(chip.state(), QdxAState::EndpointOffer);
            assert_eq!(chip.endpoint_port(&QicToDevice::default()).command, first);
            assert_eq!(chip.cq_tail(), 0);
        }
    }

    #[test]
    fn hard_reset_during_sq_receive_clears_inflight_state_and_pulses_endpoint_reset() {
        let mut chip = QdxA::new();
        configure(&mut chip);
        launch_sq(&mut chip);
        chip.advance(
            &QicToDevice { dma_read: Some(DmaWord { data: 0xdead_beef }), ..Default::default() },
            &EndpointIn::default(),
        );
        chip.advance(&QicToDevice { reset: true, ..Default::default() }, &EndpointIn::default());
        assert_eq!(chip.state(), QdxAState::Disabled);
        assert_eq!(chip.error(), QdxAError::None);
        assert_eq!((chip.sq_head(), chip.sq_tail(), chip.cq_head(), chip.cq_tail()), (0, 0, 0, 0));
        assert!(chip.endpoint_port(&QicToDevice::default()).reset);
        assert!(chip.qic_port(&QicToDevice::default()).dma_request.is_none());
    }

    #[test]
    fn soft_reset_during_endpoint_wait_clears_all_progress_and_returns_write_ok() {
        let mut chip = QdxA::new();
        configure(&mut chip);
        launch_sq(&mut chip);
        for i in 0..8 {
            chip.advance(
                &QicToDevice { dma_read: Some(DmaWord { data: i }), ..Default::default() },
                &EndpointIn::default(),
            );
        }
        chip.advance(
            &QicToDevice {
                dma_completion: Some(DmaCompletion { status: DmaStatus::Ok, words_completed: 8 }),
                ..Default::default()
            },
            &EndpointIn::default(),
        );
        chip.advance(
            &QicToDevice::default(),
            &EndpointIn { command_ready: true, ..Default::default() },
        );
        assert_eq!(chip.state(), QdxAState::EndpointCompletion);
        chip.advance(&mmio_write(REG_QDX_CONTROL, 0xf, 0x2), &EndpointIn::default());
        assert_eq!(chip.state(), QdxAState::Disabled);
        assert_eq!((chip.sq_head(), chip.sq_tail(), chip.cq_head(), chip.cq_tail()), (0, 0, 0, 0));
        assert_eq!(chip.qic_port(&QicToDevice::default()).mmio_response, Some(MmioResponse::WriteOk));
        assert!(chip.endpoint_port(&QicToDevice::default()).reset);
    }
}

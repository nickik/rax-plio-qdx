#![forbid(unsafe_code)]

use plio_logical_model::{
    odd_parity_32, parity_matches, valid_worker_transfer, BusToCard, BurstWords, CardToBus,
    Space, PLIO_TIMEOUT_CYCLES,
};

pub const PLIO_SLOT_COUNT: u8 = 8;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkerWidth {
    U8,
    U16,
    U32,
}

impl WorkerWidth {
    pub const fn bytes(self) -> u32 {
        match self {
            Self::U8 => 1,
            Self::U16 => 2,
            Self::U32 => 4,
        }
    }

    pub const fn value_mask(self) -> u32 {
        match self {
            Self::U8 => 0xff,
            Self::U16 => 0xffff,
            Self::U32 => u32::MAX,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WorkerRequest {
    pub slot: u8,
    pub address: u32,
    pub width: WorkerWidth,
    pub write: bool,
    pub value: u32,
}

impl WorkerRequest {
    pub fn read(slot: u8, address: u32, width: WorkerWidth) -> Result<Self, WorkerStartError> {
        let request = Self { slot, address, width, write: false, value: 0 };
        request.validate()?;
        Ok(request)
    }

    pub fn write(slot: u8, address: u32, width: WorkerWidth, value: u32) -> Result<Self, WorkerStartError> {
        let request = Self { slot, address, width, write: true, value };
        request.validate()?;
        Ok(request)
    }

    pub fn byte_enable(self) -> u8 {
        let lane = (self.address & 3) as u8;
        match self.width {
            WorkerWidth::U8 => 1 << lane,
            WorkerWidth::U16 => 0b0011 << lane,
            WorkerWidth::U32 => 0b1111,
        }
    }

    pub fn bus_write_data(self) -> u32 {
        (self.value & self.width.value_mask()) << ((self.address & 3) * 8)
    }

    pub fn extract_read_data(self, bus_word: u32) -> u32 {
        (bus_word >> ((self.address & 3) * 8)) & self.width.value_mask()
    }

    pub fn validate(self) -> Result<(), WorkerStartError> {
        if self.slot >= PLIO_SLOT_COUNT {
            return Err(WorkerStartError::BadSlot);
        }
        if self.address % self.width.bytes() != 0 {
            return Err(WorkerStartError::Misaligned);
        }
        if !valid_worker_transfer(self.address, self.byte_enable()) {
            return Err(WorkerStartError::BadAddress);
        }
        if self.write && self.value & !self.width.value_mask() != 0 {
            return Err(WorkerStartError::ValueTooWide);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkerStartError {
    Busy,
    CompletionPending,
    BadSlot,
    BadAddress,
    Misaligned,
    ValueTooWide,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkerError {
    BusError,
    ReadParity,
    Timeout,
    Reset,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkerResult {
    Read(u32),
    WriteOk,
}

pub type WorkerCompletion = Result<WorkerResult, WorkerError>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostMemoryRequest {
    Read32 { physical_address: u32 },
    Write32 { physical_address: u32, value: u32 },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostMemoryFault {
    Access,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostMemoryResponse {
    ReadData(u32),
    WriteDone,
    Fault(HostMemoryFault),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct HostMemoryOut {
    pub request: Option<HostMemoryRequest>,
    pub response_ready: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct HostMemoryIn {
    pub request_ready: bool,
    pub response: Option<HostMemoryResponse>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkerState {
    Idle,
    Address,
    Data,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WorkerDebug {
    pub state: WorkerState,
    pub selected_slot: Option<u8>,
    pub wait_cycles: u16,
    pub request: Option<WorkerRequest>,
    pub completion_pending: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HostBusDrive {
    pub selected_slot: Option<u8>,
    pub bus: BusToCard,
}

#[derive(Debug, Clone)]
pub struct WorkerMmioEngine {
    state: WorkerState,
    request: Option<WorkerRequest>,
    wait_cycles: u16,
    completion: Option<WorkerCompletion>,
}

impl Default for WorkerMmioEngine {
    fn default() -> Self { Self::new() }
}

impl WorkerMmioEngine {
    pub const fn new() -> Self {
        Self { state: WorkerState::Idle, request: None, wait_cycles: 0, completion: None }
    }

    pub fn ready(&self) -> bool { self.state == WorkerState::Idle && self.completion.is_none() }

    pub fn start(&mut self, request: WorkerRequest) -> Result<(), WorkerStartError> {
        request.validate()?;
        if self.completion.is_some() { return Err(WorkerStartError::CompletionPending); }
        if self.state != WorkerState::Idle { return Err(WorkerStartError::Busy); }
        self.request = Some(request);
        self.wait_cycles = 0;
        self.state = WorkerState::Address;
        Ok(())
    }

    pub fn drive(&self, reset: bool) -> HostBusDrive {
        let mut bus = BusToCard::default();
        bus.reset = reset;
        if reset { return HostBusDrive { selected_slot: None, bus }; }
        let Some(request) = self.request else {
            return HostBusDrive { selected_slot: None, bus };
        };
        match self.state {
            WorkerState::Idle => HostBusDrive { selected_slot: None, bus },
            WorkerState::Address => {
                bus.selected = true;
                bus.ad = Some(request.address);
                bus.par = Some(odd_parity_32(request.address));
                bus.space = Some(Space::Worker);
                bus.address_strobe = true;
                bus.read = !request.write;
                bus.byte_enable = request.byte_enable();
                bus.burst = BurstWords::One;
                HostBusDrive { selected_slot: Some(request.slot), bus }
            }
            WorkerState::Data => {
                bus.selected = true;
                bus.data_strobe = true;
                bus.read = !request.write;
                bus.byte_enable = request.byte_enable();
                bus.burst = BurstWords::One;
                if request.write {
                    let data = request.bus_write_data();
                    bus.ad = Some(data);
                    bus.par = Some(odd_parity_32(data));
                }
                HostBusDrive { selected_slot: Some(request.slot), bus }
            }
        }
    }

    pub fn clock(&mut self, reset: bool, card: CardToBus) {
        if reset {
            if self.state != WorkerState::Idle {
                self.completion = Some(Err(WorkerError::Reset));
            }
            self.state = WorkerState::Idle;
            self.request = None;
            self.wait_cycles = 0;
            return;
        }

        let Some(request) = self.request else { return; };
        match self.state {
            WorkerState::Idle => {}
            WorkerState::Address => {
                if card.err {
                    self.finish(Err(WorkerError::BusError));
                } else if card.ack {
                    self.state = WorkerState::Data;
                    self.wait_cycles = 0;
                } else {
                    self.wait_or_timeout();
                }
            }
            WorkerState::Data => {
                if card.err {
                    self.finish(Err(WorkerError::BusError));
                } else if card.ack {
                    if request.write {
                        self.finish(Ok(WorkerResult::WriteOk));
                    } else if let (Some(data), Some(parity)) = (card.ad, card.par) {
                        if parity_matches(data, parity, request.byte_enable()) {
                            self.finish(Ok(WorkerResult::Read(request.extract_read_data(data))));
                        } else {
                            self.finish(Err(WorkerError::ReadParity));
                        }
                    } else {
                        self.finish(Err(WorkerError::ReadParity));
                    }
                } else {
                    self.wait_or_timeout();
                }
            }
        }
    }

    fn wait_or_timeout(&mut self) {
        if self.wait_cycles + 1 >= PLIO_TIMEOUT_CYCLES {
            self.finish(Err(WorkerError::Timeout));
        } else {
            self.wait_cycles += 1;
        }
    }

    fn finish(&mut self, completion: WorkerCompletion) {
        self.completion = Some(completion);
        self.state = WorkerState::Idle;
        self.request = None;
        self.wait_cycles = 0;
    }

    pub fn completion(&self) -> Option<WorkerCompletion> { self.completion }

    pub fn take_completion(&mut self) -> Option<WorkerCompletion> { self.completion.take() }

    pub fn debug(&self) -> WorkerDebug {
        WorkerDebug {
            state: self.state,
            selected_slot: self.request.map(|r| r.slot),
            wait_cycles: self.wait_cycles,
            request: self.request,
            completion_pending: self.completion.is_some(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use plio_testbench::TestPeer;

    fn ack() -> CardToBus { CardToBus { ack: true, ..CardToBus::default() } }

    #[test]
    fn validates_slot_alignment_and_width() {
        assert_eq!(WorkerRequest::read(8, 0, WorkerWidth::U32), Err(WorkerStartError::BadSlot));
        assert_eq!(WorkerRequest::read(0, 1, WorkerWidth::U16), Err(WorkerStartError::Misaligned));
        assert_eq!(WorkerRequest::read(0, 2, WorkerWidth::U32), Err(WorkerStartError::Misaligned));
        assert_eq!(WorkerRequest::write(0, 0, WorkerWidth::U8, 0x100), Err(WorkerStartError::ValueTooWide));
    }

    #[test]
    fn byte_enable_and_lane_placement_match_worker_bus() {
        let r = WorkerRequest::write(1, 0x102, WorkerWidth::U16, 0xbeef).unwrap();
        assert_eq!(r.byte_enable(), 0b1100);
        assert_eq!(r.bus_write_data(), 0xbeef_0000);
        assert_eq!(r.extract_read_data(0xbeef_0000), 0xbeef);
    }

    #[test]
    fn address_and_write_data_are_stable_through_waits() {
        let request = WorkerRequest::write(3, 0x102, WorkerWidth::U16, 0xbeef).unwrap();
        let mut host = WorkerMmioEngine::new();
        host.start(request).unwrap();
        let address = host.drive(false);
        for _ in 0..7 {
            assert_eq!(host.drive(false), address);
            host.clock(false, CardToBus::default());
        }
        host.clock(false, ack());
        let data = host.drive(false);
        for _ in 0..7 {
            assert_eq!(host.drive(false), data);
            host.clock(false, CardToBus::default());
        }
        host.clock(false, ack());
        assert_eq!(host.take_completion(), Some(Ok(WorkerResult::WriteOk)));
    }

    #[test]
    fn selected_lane_parity_controls_read_acceptance() {
        let request = WorkerRequest::read(0, 0x101, WorkerWidth::U8).unwrap();
        let mut host = WorkerMmioEngine::new();
        host.start(request).unwrap();
        host.clock(false, ack());
        let word = 0x1234_5a78;
        let good = odd_parity_32(word);
        host.clock(false, CardToBus { ack: true, ad: Some(word), par: Some(good ^ 0b1000), ..CardToBus::default() });
        assert_eq!(host.take_completion(), Some(Ok(WorkerResult::Read(0x5a))));

        host.start(request).unwrap();
        host.clock(false, ack());
        host.clock(false, CardToBus { ack: true, ad: Some(word), par: Some(good ^ 0b0010), ..CardToBus::default() });
        assert_eq!(host.take_completion(), Some(Err(WorkerError::ReadParity)));
    }

    #[test]
    fn address_and_data_timeout_at_exact_plio_bound() {
        let request = WorkerRequest::read(0, 0x100, WorkerWidth::U32).unwrap();
        let mut host = WorkerMmioEngine::new();
        host.start(request).unwrap();
        for _ in 0..PLIO_TIMEOUT_CYCLES { host.clock(false, CardToBus::default()); }
        assert_eq!(host.take_completion(), Some(Err(WorkerError::Timeout)));

        host.start(request).unwrap();
        host.clock(false, ack());
        for _ in 0..PLIO_TIMEOUT_CYCLES { host.clock(false, CardToBus::default()); }
        assert_eq!(host.take_completion(), Some(Err(WorkerError::Timeout)));
    }

    #[test]
    fn reset_cancels_address_and_data_phases_and_tristates_drive() {
        let request = WorkerRequest::read(2, 0x100, WorkerWidth::U32).unwrap();
        let mut host = WorkerMmioEngine::new();
        host.start(request).unwrap();
        assert_eq!(host.drive(true).selected_slot, None);
        assert!(host.drive(true).bus.reset);
        host.clock(true, CardToBus::default());
        assert_eq!(host.take_completion(), Some(Err(WorkerError::Reset)));

        host.start(request).unwrap();
        host.clock(false, ack());
        assert_eq!(host.debug().state, WorkerState::Data);
        host.clock(true, CardToBus::default());
        assert_eq!(host.take_completion(), Some(Err(WorkerError::Reset)));
    }

    #[test]
    fn testpeer_is_worker_cycle_oracle_for_read_and_write_images() {
        let mut host = WorkerMmioEngine::new();
        let mut peer = TestPeer::new();

        let read = WorkerRequest::read(0, 0x100, WorkerWidth::U32).unwrap();
        host.start(read).unwrap();
        peer.start_worker_read(0x100, 0xf);
        assert_eq!(host.drive(false).bus, peer.bus_inputs());
        host.clock(false, ack());
        peer.clock(&ack());
        assert_eq!(host.drive(false).bus, peer.bus_inputs());

        let read_word = 0x1234_5678;
        let read_ack = CardToBus { ack: true, ad: Some(read_word), par: Some(odd_parity_32(read_word)), ..CardToBus::default() };
        host.clock(false, read_ack);
        peer.clock(&read_ack);
        assert_eq!(host.take_completion(), Some(Ok(WorkerResult::Read(read_word))));

        let write = WorkerRequest::write(0, 0x102, WorkerWidth::U16, 0xbeef).unwrap();
        host.start(write).unwrap();
        peer.start_worker_write(0x102, 0b1100, 0xbeef_0000);
        assert_eq!(host.drive(false).bus, peer.bus_inputs());
        host.clock(false, ack());
        peer.clock(&ack());
        assert_eq!(host.drive(false).bus, peer.bus_inputs());
    }
}

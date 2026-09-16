#![forbid(unsafe_code)]

use plio_host_dma_model::{MemoryRequest as PlioMemoryRequest, MemoryResponse};

/// General request contract owned by the shared memory controller.
///
/// Addresses remain 32-bit word aligned at the controller boundary. `byte_enable`
/// selects byte lanes for writes: bit 0 controls bits 7:0, bit 1 controls 15:8,
/// bit 2 controls 23:16, and bit 3 controls 31:24. Reads return the complete
/// 32-bit word; their byte-enable value is retained for exact request tracing but
/// does not mask the returned data.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MemoryRequest {
    physical_address: u32,
    write: bool,
    byte_enable: u8,
    write_data: u32,
}

impl MemoryRequest {
    pub const fn new(physical_address: u32, write: bool, byte_enable: u8, write_data: u32) -> Self {
        Self { physical_address, write, byte_enable: byte_enable & 0x0f, write_data }
    }

    pub const fn read(physical_address: u32, byte_enable: u8) -> Self {
        Self::new(physical_address, false, byte_enable, 0)
    }

    pub const fn write(physical_address: u32, byte_enable: u8, write_data: u32) -> Self {
        Self::new(physical_address, true, byte_enable, write_data)
    }

    /// Adapt a PLIO DMA request to the shared memory-controller contract.
    /// PLIO remains aligned full-word DMA, so every adapted request uses BE=1111.
    pub const fn from_plio(request: PlioMemoryRequest) -> Self {
        match request {
            PlioMemoryRequest::Read32 { physical_address } => Self::read(physical_address, 0x0f),
            PlioMemoryRequest::Write32 { physical_address, value } => Self::write(physical_address, 0x0f, value),
        }
    }

    pub const fn physical_address(self) -> u32 { self.physical_address }
    pub const fn is_write(self) -> bool { self.write }
    pub const fn byte_enable(self) -> u8 { self.byte_enable }
    pub const fn write_data(self) -> u32 { self.write_data }
}

/// Apply the shared memory-controller byte-lane convention to one 32-bit word.
/// Bits above BE[3:0] are ignored.
pub const fn masked_write(old: u32, write_data: u32, byte_enable: u8) -> u32 {
    let byte_enable = byte_enable & 0x0f;
    let mut result = old;
    let mut lane = 0;
    while lane < 4 {
        if byte_enable & (1 << lane) != 0 {
            let shift = lane * 8;
            let mask = 0xff_u32 << shift;
            result = (result & !mask) | (write_data & mask);
        }
        lane += 1;
    }
    result
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ControllerState { Idle, BackendRequest, BackendResponse, HostResponse }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ControllerDebug {
    pub state: ControllerState,
    pub host_request_ready: bool,
    pub backend_request_valid: bool,
    pub host_response_valid: bool,
}

pub trait MemoryBackend {
    fn request_ready(&self) -> bool;
    fn accept_request(&mut self, request: MemoryRequest) -> bool;
    fn tick(&mut self);
    fn response(&self) -> Option<MemoryResponse>;
    fn consume_response(&mut self);
    fn reset(&mut self);
}

#[derive(Debug, Clone)]
pub struct MemoryController {
    state: ControllerState,
    request: Option<MemoryRequest>,
    response: Option<MemoryResponse>,
}

impl Default for MemoryController { fn default() -> Self { Self::new() } }

impl MemoryController {
    pub const fn new() -> Self { Self { state: ControllerState::Idle, request: None, response: None } }
    pub fn host_request_ready(&self) -> bool { self.state == ControllerState::Idle }

    pub fn accept_host_request(&mut self, request: MemoryRequest) -> bool {
        if !self.host_request_ready() { return false; }
        if request.physical_address() & 3 != 0 {
            self.request = None;
            self.response = Some(MemoryResponse::Fault);
            self.state = ControllerState::HostResponse;
            return true;
        }
        self.request = Some(request);
        self.response = None;
        self.state = ControllerState::BackendRequest;
        true
    }

    pub fn accept_plio_request(&mut self, request: PlioMemoryRequest) -> bool {
        self.accept_host_request(MemoryRequest::from_plio(request))
    }

    pub fn backend_request_valid(&self) -> bool { self.state == ControllerState::BackendRequest }
    pub fn backend_request(&self) -> Option<MemoryRequest> { self.request }
    pub fn backend_request_accepted(&mut self) -> bool {
        if self.state != ControllerState::BackendRequest { return false; }
        self.state = ControllerState::BackendResponse;
        true
    }
    pub fn backend_response_ready(&self) -> bool { self.state == ControllerState::BackendResponse }

    pub fn accept_backend_response(&mut self, response: MemoryResponse) -> bool {
        if !self.backend_response_ready() { return false; }
        let mapped = match (self.request, response) {
            (Some(request), MemoryResponse::ReadData(data)) if !request.is_write() => MemoryResponse::ReadData(data),
            (Some(request), MemoryResponse::WriteDone) if request.is_write() => MemoryResponse::WriteDone,
            (_, MemoryResponse::Fault) => MemoryResponse::Fault,
            _ => MemoryResponse::Fault,
        };
        self.response = Some(mapped);
        self.state = ControllerState::HostResponse;
        true
    }

    pub fn host_response(&self) -> Option<MemoryResponse> {
        if self.state == ControllerState::HostResponse { self.response } else { None }
    }
    pub fn consume_host_response(&mut self) -> bool {
        if self.state != ControllerState::HostResponse { return false; }
        self.request = None;
        self.response = None;
        self.state = ControllerState::Idle;
        true
    }
    pub fn reset(&mut self) {
        self.state = ControllerState::Idle;
        self.request = None;
        self.response = None;
    }
    pub fn tick_backend<B: MemoryBackend>(&mut self, backend: &mut B) {
        if self.backend_request_valid() && backend.request_ready() {
            if let Some(request) = self.backend_request() {
                if backend.accept_request(request) { self.backend_request_accepted(); }
            }
        }
        backend.tick();
        if self.backend_response_ready() {
            if let Some(response) = backend.response() {
                self.accept_backend_response(response);
                backend.consume_response();
            }
        }
    }
    pub fn debug(&self) -> ControllerDebug {
        ControllerDebug {
            state: self.state,
            host_request_ready: self.host_request_ready(),
            backend_request_valid: self.backend_request_valid(),
            host_response_valid: self.host_response().is_some(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct FakeMemory {
    words: Vec<u32>,
    latency: u8,
    request_holdoff: u8,
    pending: Option<(MemoryRequest, u8)>,
    response: Option<MemoryResponse>,
}

impl FakeMemory {
    pub fn new(words: usize, latency: u8) -> Self {
        Self { words: vec![0; words], latency, request_holdoff: 0, pending: None, response: None }
    }
    pub fn set_request_holdoff(&mut self, cycles: u8) { self.request_holdoff = cycles; }
    pub fn preload_word(&mut self, physical_address: u32, value: u32) -> bool {
        let Some(index) = self.word_index(physical_address) else { return false; };
        self.words[index] = value;
        true
    }
    pub fn peek_word(&self, physical_address: u32) -> Option<u32> {
        self.word_index(physical_address).map(|i| self.words[i])
    }
    fn word_index(&self, physical_address: u32) -> Option<usize> {
        if physical_address & 3 != 0 { return None; }
        let index = (physical_address >> 2) as usize;
        (index < self.words.len()).then_some(index)
    }
    fn execute(&mut self, request: MemoryRequest) -> MemoryResponse {
        if !request.is_write() {
            return self.peek_word(request.physical_address()).map(MemoryResponse::ReadData).unwrap_or(MemoryResponse::Fault);
        }
        if let Some(index) = self.word_index(request.physical_address()) {
            let old = self.words[index];
            self.words[index] = masked_write(old, request.write_data(), request.byte_enable());
            MemoryResponse::WriteDone
        } else {
            MemoryResponse::Fault
        }
    }
}

impl MemoryBackend for FakeMemory {
    fn request_ready(&self) -> bool { self.request_holdoff == 0 && self.pending.is_none() && self.response.is_none() }
    fn accept_request(&mut self, request: MemoryRequest) -> bool {
        if !self.request_ready() { return false; }
        self.pending = Some((request, self.latency));
        true
    }
    fn tick(&mut self) {
        if self.request_holdoff > 0 { self.request_holdoff -= 1; }
        let Some((request, remaining)) = self.pending else { return; };
        if remaining > 0 { self.pending = Some((request, remaining - 1)); }
        else {
            self.pending = None;
            self.response = Some(self.execute(request));
        }
    }
    fn response(&self) -> Option<MemoryResponse> { self.response }
    fn consume_response(&mut self) { self.response = None; }
    fn reset(&mut self) {
        self.pending = None;
        self.response = None;
        self.request_holdoff = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn run_to_response(c: &mut MemoryController, m: &mut FakeMemory) {
        while c.host_response().is_none() { c.tick_backend(m); }
    }

    #[test]
    fn request_constrains_byte_enable_and_retains_read_mask() {
        let request = MemoryRequest::read(0x100, 0xf5);
        assert_eq!(request.byte_enable(), 0x05);
        assert!(!request.is_write());
        assert_eq!(request.physical_address(), 0x100);
    }

    #[test]
    fn plio_requests_adapt_to_full_word_byte_enable() {
        let read = MemoryRequest::from_plio(PlioMemoryRequest::Read32 { physical_address: 0x100 });
        assert_eq!(read, MemoryRequest::read(0x100, 0x0f));
        let write = MemoryRequest::from_plio(PlioMemoryRequest::Write32 { physical_address: 0x104, value: 0xaabb_ccdd });
        assert_eq!(write, MemoryRequest::write(0x104, 0x0f, 0xaabb_ccdd));
    }

    #[test]
    fn masked_write_exhaustively_matches_lane_reference() {
        let old = 0x1122_3344;
        let value = 0xaabb_ccdd;
        for byte_enable in 0_u8..16 {
            let mut expected = old;
            for lane in 0..4 {
                if byte_enable & (1 << lane) != 0 {
                    let shift = lane * 8;
                    let mask = 0xff_u32 << shift;
                    expected = (expected & !mask) | (value & mask);
                }
            }
            assert_eq!(masked_write(old, value, byte_enable), expected, "BE={byte_enable:04b}");
        }
    }

    #[test]
    fn masked_write_lane_mapping_and_edge_masks() {
        assert_eq!(masked_write(0x1122_3344, 0xaabb_ccdd, 0b0000), 0x1122_3344);
        assert_eq!(masked_write(0x1122_3344, 0xaabb_ccdd, 0b1111), 0xaabb_ccdd);
        assert_eq!(masked_write(0x1122_3344, 0xaabb_ccdd, 0b0001), 0x1122_33dd);
        assert_eq!(masked_write(0x1122_3344, 0xaabb_ccdd, 0b0010), 0x1122_cc44);
        assert_eq!(masked_write(0x1122_3344, 0xaabb_ccdd, 0b0100), 0x11bb_3344);
        assert_eq!(masked_write(0x1122_3344, 0xaabb_ccdd, 0b1000), 0xaa22_3344);
        assert_eq!(masked_write(0x1122_3344, 0xaabb_ccdd, 0b0101), 0x11bb_33dd);
        assert_eq!(masked_write(0x1122_3344, 0xaabb_ccdd, 0b1010), 0xaa22_cc44);
    }

    #[test]
    fn request_is_stable_until_backend_accepts() {
        let mut c = MemoryController::new();
        let request = MemoryRequest::read(0x100, 0x03);
        assert!(c.accept_host_request(request));
        assert_eq!(c.backend_request(), Some(request));
        for _ in 0..8 { assert_eq!(c.backend_request(), Some(request)); }
        assert!(c.backend_request_accepted());
        assert_eq!(c.debug().state, ControllerState::BackendResponse);
    }

    #[test]
    fn response_is_stable_until_host_consumes_it() {
        let mut c = MemoryController::new();
        c.accept_host_request(MemoryRequest::read(0x100, 0x0f));
        c.backend_request_accepted();
        c.accept_backend_response(MemoryResponse::ReadData(0x1234_5678));
        for _ in 0..8 { assert_eq!(c.host_response(), Some(MemoryResponse::ReadData(0x1234_5678))); }
        assert!(c.consume_host_response());
        assert!(c.host_request_ready());
    }

    #[test]
    fn mismatched_backend_response_becomes_fault() {
        let mut c = MemoryController::new();
        c.accept_host_request(MemoryRequest::read(0x100, 0x0f));
        c.backend_request_accepted();
        c.accept_backend_response(MemoryResponse::WriteDone);
        assert_eq!(c.host_response(), Some(MemoryResponse::Fault));
    }

    #[test]
    fn misaligned_host_request_faults_without_touching_backend() {
        let mut c = MemoryController::new();
        assert!(c.accept_host_request(MemoryRequest::read(0x102, 0x0f)));
        assert!(!c.backend_request_valid());
        assert_eq!(c.host_response(), Some(MemoryResponse::Fault));
    }

    #[test]
    fn fake_memory_handles_all_masks_and_multiple_addresses() {
        let mut c = MemoryController::new();
        let mut m = FakeMemory::new(1024, 0);
        for mask in 0_u8..16 {
            let address = 0x100 + u32::from(mask) * 4;
            assert!(m.preload_word(address, 0x1122_3344));
            assert!(c.accept_host_request(MemoryRequest::write(address, mask, 0xaabb_ccdd)));
            run_to_response(&mut c, &mut m);
            assert_eq!(c.host_response(), Some(MemoryResponse::WriteDone));
            assert_eq!(m.peek_word(address), Some(masked_write(0x1122_3344, 0xaabb_ccdd, mask)));
            assert!(c.consume_host_response());
        }
    }

    #[test]
    fn fake_memory_composes_consecutive_masked_writes() {
        let mut c = MemoryController::new();
        let mut m = FakeMemory::new(1024, 0);
        assert!(m.preload_word(0x100, 0x1122_3344));
        assert!(c.accept_host_request(MemoryRequest::write(0x100, 0b0101, 0xaabb_ccdd)));
        run_to_response(&mut c, &mut m);
        assert!(c.consume_host_response());
        assert_eq!(m.peek_word(0x100), Some(0x11bb_33dd));
        assert!(c.accept_host_request(MemoryRequest::write(0x100, 0b1010, 0x5566_7788)));
        run_to_response(&mut c, &mut m);
        assert!(c.consume_host_response());
        assert_eq!(m.peek_word(0x100), Some(0x55bb_77dd));
        assert!(c.accept_host_request(MemoryRequest::read(0x100, 0x0f)));
        run_to_response(&mut c, &mut m);
        assert_eq!(c.host_response(), Some(MemoryResponse::ReadData(0x55bb_77dd)));
    }

    #[test]
    fn fake_memory_handles_backpressure_latency_reads_writes_and_faults() {
        let mut c = MemoryController::new();
        let mut m = FakeMemory::new(1024, 2);
        assert!(m.preload_word(0x100, 0x1122_3344));
        m.set_request_holdoff(2);
        c.accept_host_request(MemoryRequest::read(0x100, 0x0f));
        for _ in 0..2 {
            c.tick_backend(&mut m);
            assert!(c.backend_request_valid());
        }
        run_to_response(&mut c, &mut m);
        assert_eq!(c.host_response(), Some(MemoryResponse::ReadData(0x1122_3344)));
        c.consume_host_response();
        c.accept_host_request(MemoryRequest::write(0x104, 0b0101, 0xaabb_ccdd));
        run_to_response(&mut c, &mut m);
        assert_eq!(c.host_response(), Some(MemoryResponse::WriteDone));
        assert_eq!(m.peek_word(0x104), Some(0x00bb_00dd));
        c.consume_host_response();
        c.accept_host_request(MemoryRequest::read(0x4000, 0x0f));
        run_to_response(&mut c, &mut m);
        assert_eq!(c.host_response(), Some(MemoryResponse::Fault));
    }

    #[test]
    fn reset_discards_in_flight_masked_request() {
        let mut c = MemoryController::new();
        c.accept_host_request(MemoryRequest::write(0x100, 0b0101, 0xaabb_ccdd));
        c.backend_request_accepted();
        c.reset();
        assert_eq!(c.debug().state, ControllerState::Idle);
        assert!(c.host_request_ready());
        assert_eq!(c.host_response(), None);
        assert_eq!(c.backend_request(), None);
    }
}

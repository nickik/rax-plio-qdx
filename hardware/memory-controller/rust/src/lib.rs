#![forbid(unsafe_code)]

use plio_host_dma_model::{MemoryRequest, MemoryResponse};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ControllerState {
    Idle,
    BackendRequest,
    BackendResponse,
    HostResponse,
}

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

impl Default for MemoryController {
    fn default() -> Self { Self::new() }
}

impl MemoryController {
    pub const fn new() -> Self {
        Self { state: ControllerState::Idle, request: None, response: None }
    }

    pub fn host_request_ready(&self) -> bool { self.state == ControllerState::Idle }

    pub fn accept_host_request(&mut self, request: MemoryRequest) -> bool {
        if !self.host_request_ready() { return false; }
        let address = match request {
            MemoryRequest::Read32 { physical_address } => physical_address,
            MemoryRequest::Write32 { physical_address, .. } => physical_address,
        };
        if address & 3 != 0 {
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
            (Some(MemoryRequest::Read32 { .. }), MemoryResponse::ReadData(data)) => MemoryResponse::ReadData(data),
            (Some(MemoryRequest::Write32 { .. }), MemoryResponse::WriteDone) => MemoryResponse::WriteDone,
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
                if backend.accept_request(request) {
                    self.backend_request_accepted();
                }
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
        match request {
            MemoryRequest::Read32 { physical_address } => {
                self.peek_word(physical_address).map(MemoryResponse::ReadData).unwrap_or(MemoryResponse::Fault)
            }
            MemoryRequest::Write32 { physical_address, value } => {
                if let Some(index) = self.word_index(physical_address) {
                    self.words[index] = value;
                    MemoryResponse::WriteDone
                } else {
                    MemoryResponse::Fault
                }
            }
        }
    }
}

impl MemoryBackend for FakeMemory {
    fn request_ready(&self) -> bool {
        self.request_holdoff == 0 && self.pending.is_none() && self.response.is_none()
    }

    fn accept_request(&mut self, request: MemoryRequest) -> bool {
        if !self.request_ready() { return false; }
        self.pending = Some((request, self.latency));
        true
    }

    fn tick(&mut self) {
        if self.request_holdoff > 0 { self.request_holdoff -= 1; }
        let Some((request, remaining)) = self.pending else { return; };
        if remaining > 0 {
            self.pending = Some((request, remaining - 1));
        } else {
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

    #[test]
    fn request_is_stable_until_backend_accepts() {
        let mut c = MemoryController::new();
        let request = MemoryRequest::Read32 { physical_address: 0x100 };
        assert!(c.accept_host_request(request));
        assert_eq!(c.backend_request(), Some(request));
        for _ in 0..8 { assert_eq!(c.backend_request(), Some(request)); }
        assert!(c.backend_request_accepted());
        assert_eq!(c.debug().state, ControllerState::BackendResponse);
    }

    #[test]
    fn response_is_stable_until_host_consumes_it() {
        let mut c = MemoryController::new();
        c.accept_host_request(MemoryRequest::Read32 { physical_address: 0x100 });
        c.backend_request_accepted();
        c.accept_backend_response(MemoryResponse::ReadData(0x1234_5678));
        for _ in 0..8 { assert_eq!(c.host_response(), Some(MemoryResponse::ReadData(0x1234_5678))); }
        assert!(c.consume_host_response());
        assert!(c.host_request_ready());
    }

    #[test]
    fn mismatched_backend_response_becomes_fault() {
        let mut c = MemoryController::new();
        c.accept_host_request(MemoryRequest::Read32 { physical_address: 0x100 });
        c.backend_request_accepted();
        c.accept_backend_response(MemoryResponse::WriteDone);
        assert_eq!(c.host_response(), Some(MemoryResponse::Fault));
    }

    #[test]
    fn misaligned_host_request_faults_without_touching_backend() {
        let mut c = MemoryController::new();
        assert!(c.accept_host_request(MemoryRequest::Read32 { physical_address: 0x102 }));
        assert!(!c.backend_request_valid());
        assert_eq!(c.host_response(), Some(MemoryResponse::Fault));
    }

    #[test]
    fn fake_memory_handles_backpressure_latency_reads_writes_and_faults() {
        let mut c = MemoryController::new();
        let mut m = FakeMemory::new(1024, 2);
        assert!(m.preload_word(0x100, 0x1122_3344));
        m.set_request_holdoff(2);
        c.accept_host_request(MemoryRequest::Read32 { physical_address: 0x100 });
        for _ in 0..2 {
            c.tick_backend(&mut m);
            assert!(c.backend_request_valid());
        }
        while c.host_response().is_none() { c.tick_backend(&mut m); }
        assert_eq!(c.host_response(), Some(MemoryResponse::ReadData(0x1122_3344)));
        c.consume_host_response();

        c.accept_host_request(MemoryRequest::Write32 { physical_address: 0x104, value: 0xaabb_ccdd });
        while c.host_response().is_none() { c.tick_backend(&mut m); }
        assert_eq!(c.host_response(), Some(MemoryResponse::WriteDone));
        assert_eq!(m.peek_word(0x104), Some(0xaabb_ccdd));
        c.consume_host_response();

        c.accept_host_request(MemoryRequest::Read32 { physical_address: 0x4000 });
        while c.host_response().is_none() { c.tick_backend(&mut m); }
        assert_eq!(c.host_response(), Some(MemoryResponse::Fault));
    }

    #[test]
    fn reset_discards_in_flight_state() {
        let mut c = MemoryController::new();
        c.accept_host_request(MemoryRequest::Read32 { physical_address: 0x100 });
        c.backend_request_accepted();
        c.reset();
        assert_eq!(c.debug().state, ControllerState::Idle);
        assert!(c.host_request_ready());
        assert_eq!(c.host_response(), None);
    }
}

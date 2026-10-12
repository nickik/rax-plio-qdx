#![forbid(unsafe_code)]

//! Executable reference model for the base two-port QDX-GNET endpoint card.
//! It deliberately models endpoint I/O only: there is no GDP parsing,
//! forwarding, routing table, or host-networking shortcut.

use std::collections::VecDeque;

pub const PORTS: usize = 2;
pub const DEFAULT_FIFO_FRAMES: usize = 8;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LinkState { Down, Training, Up, Resetting }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Success,
    InvalidPort,
    NotReady,
    BufferTooSmall,
    LinkDown,
    LinkReset,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Counters {
    pub rx_frames: u32,
    pub tx_frames: u32,
    pub rx_no_buffer_drops: u32,
    pub rx_oversize_drops: u32,
    pub link_faults: u32,
    pub resets: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Completion {
    pub status: Status,
    pub port: u8,
    pub bytes_done: u32,
    pub info: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct PostedReceive { capacity: usize }

#[derive(Debug, Clone)]
struct Port {
    state: LinkState,
    address: u64,
    promiscuous: bool,
    rx: VecDeque<PostedReceive>,
    wire_tx: VecDeque<Vec<u8>>,
    counters: Counters,
}

impl Port {
    fn new() -> Self {
        Self {
            state: LinkState::Down,
            address: 0,
            promiscuous: false,
            rx: VecDeque::new(),
            wire_tx: VecDeque::new(),
            counters: Counters::default(),
        }
    }
}

/// Model of the card-local state after QDX descriptors have been consumed.
///
/// QDX/DMA descriptor fetching, CQ writes, and PLIO Notification belong to the
/// outer QDX card harness. This model owns the endpoint-specific, per-port
/// bounded FIFOs and the frame/link-facing behaviour that the Rust and FPGA
/// implementations must share.
#[derive(Debug, Clone)]
pub struct TwoPortEndpoint {
    ports: [Port; PORTS],
    max_frame_bytes: usize,
    max_posted_receives: usize,
}

impl Default for TwoPortEndpoint {
    fn default() -> Self { Self::new(1500, DEFAULT_FIFO_FRAMES) }
}

impl TwoPortEndpoint {
    pub fn new(max_frame_bytes: usize, max_posted_receives: usize) -> Self {
        assert!(max_frame_bytes > 0);
        assert!(max_posted_receives > 0);
        Self {
            ports: std::array::from_fn(|_| Port::new()),
            max_frame_bytes,
            max_posted_receives,
        }
    }

    fn port_mut(&mut self, port: u8) -> Result<&mut Port, Status> {
        self.ports.get_mut(port as usize).ok_or(Status::InvalidPort)
    }

    fn port(&self, port: u8) -> Result<&Port, Status> {
        self.ports.get(port as usize).ok_or(Status::InvalidPort)
    }

    pub fn set_link_state(&mut self, port: u8, state: LinkState) -> Result<(), Status> {
        self.port_mut(port)?.state = state;
        Ok(())
    }

    pub fn set_address(&mut self, port: u8, address: u64) -> Result<(), Status> {
        self.port_mut(port)?.address = address;
        Ok(())
    }

    pub fn set_promiscuous(&mut self, port: u8, enabled: bool) -> Result<(), Status> {
        self.port_mut(port)?.promiscuous = enabled;
        Ok(())
    }

    pub fn link_state(&self, port: u8) -> Result<LinkState, Status> { Ok(self.port(port)?.state) }
    pub fn address(&self, port: u8) -> Result<u64, Status> { Ok(self.port(port)?.address) }
    pub fn counters(&self, port: u8) -> Result<Counters, Status> { Ok(self.port(port)?.counters) }

    pub fn post_receive(&mut self, port: u8, capacity: usize) -> Completion {
        let limit = self.max_posted_receives;
        match self.port_mut(port) {
            Err(status) => Completion { status, port, bytes_done: 0, info: 0 },
            Ok(p) if p.state != LinkState::Up => Completion { status: Status::LinkDown, port, bytes_done: 0, info: 0 },
            Ok(p) if capacity == 0 || p.rx.len() == limit =>
                Completion { status: Status::NotReady, port, bytes_done: 0, info: 0 },
            Ok(p) => {
                p.rx.push_back(PostedReceive { capacity });
                Completion { status: Status::Success, port, bytes_done: 0, info: 0 }
            }
        }
    }

    pub fn transmit(&mut self, port: u8, frame: &[u8]) -> Completion {
        let max = self.max_frame_bytes;
        match self.port_mut(port) {
            Err(status) => Completion { status, port, bytes_done: 0, info: 0 },
            Ok(p) if p.state != LinkState::Up => Completion { status: Status::LinkDown, port, bytes_done: 0, info: 0 },
            Ok(_) if frame.is_empty() || frame.len() > max =>
                Completion { status: Status::BufferTooSmall, port, bytes_done: 0, info: frame.len() as u32 },
            Ok(p) => {
                p.wire_tx.push_back(frame.to_vec());
                p.counters.tx_frames = p.counters.tx_frames.saturating_add(1);
                Completion { status: Status::Success, port, bytes_done: frame.len() as u32, info: 0 }
            }
        }
    }

    /// Inject one complete frame from the physical link. An actual FPGA calls
    /// this only after its DLP receiver has accepted the frame.
    pub fn receive_from_link(&mut self, port: u8, frame: &[u8]) -> Completion {
        let max = self.max_frame_bytes;
        match self.port_mut(port) {
            Err(status) => Completion { status, port, bytes_done: 0, info: 0 },
            Ok(p) if p.state != LinkState::Up => Completion { status: Status::LinkDown, port, bytes_done: 0, info: 0 },
            Ok(p) if frame.len() > max => {
                p.counters.rx_oversize_drops = p.counters.rx_oversize_drops.saturating_add(1);
                Completion { status: Status::BufferTooSmall, port, bytes_done: 0, info: frame.len() as u32 }
            }
            Ok(p) => match p.rx.pop_front() {
                None => {
                    p.counters.rx_no_buffer_drops = p.counters.rx_no_buffer_drops.saturating_add(1);
                    Completion { status: Status::NotReady, port, bytes_done: 0, info: frame.len() as u32 }
                }
                Some(posted) if frame.len() > posted.capacity => {
                    p.counters.rx_oversize_drops = p.counters.rx_oversize_drops.saturating_add(1);
                    Completion { status: Status::BufferTooSmall, port, bytes_done: 0, info: frame.len() as u32 }
                }
                Some(_) => {
                    p.counters.rx_frames = p.counters.rx_frames.saturating_add(1);
                    Completion { status: Status::Success, port, bytes_done: frame.len() as u32, info: 0 }
                }
            }
        }
    }

    pub fn take_wire_tx(&mut self, port: u8) -> Result<Option<Vec<u8>>, Status> {
        Ok(self.port_mut(port)?.wire_tx.pop_front())
    }

    pub fn reset_port(&mut self, port: u8) -> Result<(), Status> {
        let p = self.port_mut(port)?;
        p.state = LinkState::Down;
        p.rx.clear();
        p.wire_tx.clear();
        p.counters.resets = p.counters.resets.saturating_add(1);
        Ok(())
    }

    pub fn reset(&mut self) {
        for port in 0..PORTS { self.reset_port(port as u8).expect("fixed port"); }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ports_are_independent_endpoint_links() {
        let mut card = TwoPortEndpoint::default();
        card.set_link_state(0, LinkState::Up).unwrap();
        card.set_link_state(1, LinkState::Up).unwrap();

        assert_eq!(card.post_receive(0, 64).status, Status::Success);
        assert_eq!(card.receive_from_link(0, b"on-zero").bytes_done, 7);
        assert_eq!(card.transmit(1, b"on-one").bytes_done, 6);
        assert_eq!(card.take_wire_tx(0).unwrap(), None);
        assert_eq!(card.take_wire_tx(1).unwrap(), Some(b"on-one".to_vec()));
        assert_eq!(card.counters(0).unwrap().rx_frames, 1);
        assert_eq!(card.counters(1).unwrap().tx_frames, 1);
    }

    #[test]
    fn receive_is_bounded_and_does_not_forward() {
        let mut card = TwoPortEndpoint::new(16, 1);
        card.set_link_state(0, LinkState::Up).unwrap();
        card.set_link_state(1, LinkState::Up).unwrap();
        assert_eq!(card.receive_from_link(0, b"drop").status, Status::NotReady);
        assert_eq!(card.take_wire_tx(1).unwrap(), None);
        assert_eq!(card.counters(0).unwrap().rx_no_buffer_drops, 1);
    }

    #[test]
    fn reset_cancels_queued_card_local_work() {
        let mut card = TwoPortEndpoint::default();
        card.set_link_state(0, LinkState::Up).unwrap();
        card.post_receive(0, 64);
        card.transmit(0, b"queued");
        card.reset_port(0).unwrap();
        assert_eq!(card.link_state(0).unwrap(), LinkState::Down);
        assert_eq!(card.take_wire_tx(0).unwrap(), None);
        assert_eq!(card.receive_from_link(0, b"x").status, Status::LinkDown);
    }
}

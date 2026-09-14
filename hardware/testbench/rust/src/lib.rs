#![forbid(unsafe_code)]

use plio_logical_model::{odd_parity_32, parity_matches, BusToCard, BurstWords, CardToBus, Space};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkerResult {
    Read(u32),
    WriteOk,
    Error,
    ReadParityError,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum WorkerOp {
    Read { address: u32, byte_enable: u8 },
    Write { address: u32, byte_enable: u8, data: u32 },
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum State {
    Idle,
    WorkerAddress(WorkerOp),
    WorkerData(WorkerOp),
    Grant,
    DmaData { read: bool, total: u8, beat: u8, wait_left: u16 },
    NotificationData { channel: u8, wait_left: u16 },
}

#[derive(Debug, Clone)]
pub struct TestPeer {
    state: State,
    worker_result: Option<WorkerResult>,
    pub dma_wait_cycles: u16,
    pub dma_error_beat: Option<u8>,
    pub dma_bad_parity_beat: Option<u8>,
    pub notification_wait_cycles: u16,
    pub dma_read_base: u32,
    dma_writes: Vec<u32>,
    notifications: Vec<u8>,
    last_dma_address: Option<u32>,
    last_dma_burst: Option<BurstWords>,
    grant_count: u32,
    manager_transactions: u32,
}

impl Default for TestPeer {
    fn default() -> Self { Self::new() }
}

impl TestPeer {
    pub fn new() -> Self {
        Self {
            state: State::Idle,
            worker_result: None,
            dma_wait_cycles: 0,
            dma_error_beat: None,
            dma_bad_parity_beat: None,
            notification_wait_cycles: 0,
            dma_read_base: 0x1000_0000,
            dma_writes: Vec::new(),
            notifications: Vec::new(),
            last_dma_address: None,
            last_dma_burst: None,
            grant_count: 0,
            manager_transactions: 0,
        }
    }

    pub fn start_worker_read(&mut self, address: u32, byte_enable: u8) {
        assert!(matches!(self.state, State::Idle));
        self.worker_result = None;
        self.state = State::WorkerAddress(WorkerOp::Read { address, byte_enable });
    }

    pub fn start_worker_write(&mut self, address: u32, byte_enable: u8, data: u32) {
        assert!(matches!(self.state, State::Idle));
        self.worker_result = None;
        self.state = State::WorkerAddress(WorkerOp::Write { address, byte_enable, data });
    }

    pub fn worker_result(&self) -> Option<WorkerResult> { self.worker_result }
    pub fn dma_writes(&self) -> &[u32] { &self.dma_writes }
    pub fn notifications(&self) -> &[u8] { &self.notifications }
    pub fn last_dma_address(&self) -> Option<u32> { self.last_dma_address }
    pub fn last_dma_burst(&self) -> Option<BurstWords> { self.last_dma_burst }
    pub fn grant_count(&self) -> u32 { self.grant_count }
    pub fn manager_transactions(&self) -> u32 { self.manager_transactions }

    pub fn bus_inputs(&self) -> BusToCard {
        let mut bus = BusToCard::default();
        match self.state {
            State::Idle => {}
            State::WorkerAddress(op) => {
                let (address, byte_enable, read) = match op {
                    WorkerOp::Read { address, byte_enable } => (address, byte_enable, true),
                    WorkerOp::Write { address, byte_enable, .. } => (address, byte_enable, false),
                };
                bus.selected = true;
                bus.ad = Some(address);
                bus.par = Some(odd_parity_32(address));
                bus.space = Some(Space::Worker);
                bus.address_strobe = true;
                bus.read = read;
                bus.byte_enable = byte_enable;
                bus.burst = BurstWords::One;
            }
            State::WorkerData(op) => {
                bus.selected = true;
                bus.data_strobe = true;
                match op {
                    WorkerOp::Read { byte_enable, .. } => {
                        bus.read = true;
                        bus.byte_enable = byte_enable;
                    }
                    WorkerOp::Write { byte_enable, data, .. } => {
                        bus.read = false;
                        bus.byte_enable = byte_enable;
                        bus.ad = Some(data);
                        bus.par = Some(odd_parity_32(data));
                    }
                }
            }
            State::Grant => bus.grant = true,
            State::DmaData { read, beat, wait_left, .. } => {
                bus.grant = true;
                if wait_left == 0 {
                    if self.dma_error_beat == Some(beat) {
                        bus.err = true;
                    } else {
                        bus.ack = true;
                        if read {
                            let data = self.dma_read_base.wrapping_add(u32::from(beat) * 4);
                            bus.ad = Some(data);
                            let mut par = odd_parity_32(data);
                            if self.dma_bad_parity_beat == Some(beat) { par ^= 1; }
                            bus.par = Some(par);
                        }
                    }
                }
            }
            State::NotificationData { wait_left, .. } => {
                bus.grant = true;
                if wait_left == 0 { bus.ack = true; }
            }
        }
        bus
    }

    pub fn clock(&mut self, card: &CardToBus) {
        self.state = match self.state.clone() {
            State::Idle => {
                if card.request {
                    self.grant_count += 1;
                    State::Grant
                } else {
                    State::Idle
                }
            }
            State::WorkerAddress(op) => {
                if card.err {
                    self.worker_result = Some(WorkerResult::Error);
                    State::Idle
                } else {
                    State::WorkerData(op)
                }
            }
            State::WorkerData(op) => {
                if card.err {
                    self.worker_result = Some(WorkerResult::Error);
                    State::Idle
                } else if card.ack {
                    match op {
                        WorkerOp::Read { byte_enable, .. } => {
                            if let (Some(data), Some(par)) = (card.ad, card.par) {
                                self.worker_result = Some(if parity_matches(data, par, byte_enable) {
                                    WorkerResult::Read(data)
                                } else {
                                    WorkerResult::ReadParityError
                                });
                            } else {
                                self.worker_result = Some(WorkerResult::Error);
                            }
                        }
                        WorkerOp::Write { .. } => self.worker_result = Some(WorkerResult::WriteOk),
                    }
                    State::Idle
                } else {
                    State::WorkerData(op)
                }
            }
            State::Grant => {
                if card.address_strobe {
                    self.manager_transactions += 1;
                    match card.space {
                        Some(Space::HostDma) => {
                            self.last_dma_address = card.ad;
                            self.last_dma_burst = Some(card.burst);
                            State::DmaData {
                                read: card.read,
                                total: card.burst.words(),
                                beat: 0,
                                wait_left: self.dma_wait_cycles,
                            }
                        }
                        Some(Space::Controller) => {
                            let channel = card.ad.unwrap_or(0) / 4;
                            State::NotificationData { channel: channel as u8, wait_left: self.notification_wait_cycles }
                        }
                        _ => State::Idle,
                    }
                } else if card.request {
                    State::Grant
                } else {
                    State::Idle
                }
            }
            State::DmaData { read, total, beat, wait_left } => {
                if !card.request {
                    State::Idle
                } else if card.data_strobe {
                    if wait_left > 0 {
                        State::DmaData { read, total, beat, wait_left: wait_left - 1 }
                    } else if self.dma_error_beat == Some(beat) {
                        State::Idle
                    } else {
                        if !read {
                            if let Some(data) = card.ad { self.dma_writes.push(data); }
                        }
                        let next = beat + 1;
                        if next == total {
                            State::Idle
                        } else {
                            State::DmaData { read, total, beat: next, wait_left: self.dma_wait_cycles }
                        }
                    }
                } else {
                    State::DmaData { read, total, beat, wait_left }
                }
            }
            State::NotificationData { channel, wait_left } => {
                if !card.request {
                    State::Idle
                } else if card.data_strobe {
                    if wait_left > 0 {
                        State::NotificationData { channel, wait_left: wait_left - 1 }
                    } else {
                        self.notifications.push(channel);
                        State::Idle
                    }
                } else {
                    State::NotificationData { channel, wait_left }
                }
            }
        };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn peer_emits_worker_address_then_data() {
        let mut peer = TestPeer::new();
        peer.start_worker_read(0x10, 0xf);
        let address = peer.bus_inputs();
        assert!(address.address_strobe);
        assert_eq!(address.space, Some(Space::Worker));
        peer.clock(&CardToBus::default());
        assert!(peer.bus_inputs().data_strobe);
    }

    #[test]
    fn each_manager_transaction_starts_with_a_fresh_grant() {
        let mut peer = TestPeer::new();
        peer.clock(&CardToBus { request: true, ..CardToBus::default() });
        assert_eq!(peer.grant_count(), 1);
        assert_eq!(peer.manager_transactions(), 0);
    }
}

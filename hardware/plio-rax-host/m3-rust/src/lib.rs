#![forbid(unsafe_code)]

use plio_logical_model::{odd_parity_32, parity_matches, PLIO_TIMEOUT_CYCLES};

pub const SLOT_COUNT: usize = 8;
pub const CHANNEL_COUNT: usize = 16;
pub const MAX_MAPPING_LEN: u32 = 1 << 24;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Capability {
    pub host_physical_base: u32,
    pub length: u32,
    pub device_read: bool,
    pub device_write: bool,
    pub generation: u8,
    pub valid: bool,
}

impl Default for Capability {
    fn default() -> Self {
        Self { host_physical_base: 0, length: 0, device_read: false, device_write: false, generation: 0xf, valid: false }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DmaDirection { DeviceRead, DeviceWrite }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BindError { BadSlot, BadChannel, BadLength, MisalignedBase, ActiveInterlock }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StartError { Busy, BadSlot, BadBurst, MisalignedOffset, Unbound, StaleGeneration, Permission, Range }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DmaError { Protection, MemoryFault, Parity, Timeout, Reset, Revoked }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MemoryRequest { Read32 { physical_address: u32 }, Write32 { physical_address: u32, value: u32 } }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MemoryResponse { ReadData(u32), WriteDone, Fault }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DmaState { Idle, AwaitDeviceWrite, MemRequest, MemResponse, DeviceReadReady }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DmaDebug {
    pub state: DmaState,
    pub slot: Option<u8>,
    pub channel: Option<u8>,
    pub generation: Option<u8>,
    pub physical_address: Option<u32>,
    pub acknowledged_beats: u8,
    pub total_beats: u8,
    pub wait_cycles: u16,
    pub revoke_pending: bool,
}

#[derive(Debug, Clone, Copy)]
struct Active {
    slot: u8,
    channel: u8,
    generation: u8,
    direction: DmaDirection,
    physical_address: u32,
    total: u8,
    acknowledged: u8,
    pending_write: Option<u32>,
    read_data: Option<u32>,
    wait_cycles: u16,
    revoke_pending: bool,
}

#[derive(Debug, Clone)]
pub struct DmaHostM3 {
    caps: [[Capability; CHANNEL_COUNT]; SLOT_COUNT],
    state: DmaState,
    active: Option<Active>,
    completion: Option<Result<u8, DmaError>>,
}

impl Default for DmaHostM3 { fn default() -> Self { Self::new() } }

impl DmaHostM3 {
    pub fn new() -> Self {
        Self { caps: [[Capability::default(); CHANNEL_COUNT]; SLOT_COUNT], state: DmaState::Idle, active: None, completion: None }
    }

    pub fn capability(&self, slot: u8, channel: u8) -> Option<Capability> {
        self.caps.get(slot as usize).and_then(|s| s.get(channel as usize)).copied()
    }

    pub fn bind(&mut self, slot: u8, channel: u8, base: u32, length: u32, device_read: bool, device_write: bool) -> Result<u8, BindError> {
        if slot as usize >= SLOT_COUNT { return Err(BindError::BadSlot); }
        if channel as usize >= CHANNEL_COUNT { return Err(BindError::BadChannel); }
        if length == 0 || length > MAX_MAPPING_LEN { return Err(BindError::BadLength); }
        if base & 3 != 0 { return Err(BindError::MisalignedBase); }
        if self.active_matches(slot, channel) { return Err(BindError::ActiveInterlock); }
        let old = self.caps[slot as usize][channel as usize];
        let generation = old.generation.wrapping_add(1) & 0xf;
        self.caps[slot as usize][channel as usize] = Capability {
            host_physical_base: base, length, device_read, device_write, generation, valid: true,
        };
        Ok(generation)
    }

    pub fn revoke(&mut self, slot: u8, channel: u8) -> Result<bool, BindError> {
        if slot as usize >= SLOT_COUNT { return Err(BindError::BadSlot); }
        if channel as usize >= CHANNEL_COUNT { return Err(BindError::BadChannel); }
        self.caps[slot as usize][channel as usize].valid = false;
        if self.active_matches(slot, channel) {
            self.active.as_mut().unwrap().revoke_pending = true;
            Ok(false)
        } else {
            Ok(true)
        }
    }

    fn active_matches(&self, slot: u8, channel: u8) -> bool {
        self.active.map(|a| a.slot == slot && a.channel == channel).unwrap_or(false)
    }

    pub fn start(&mut self, slot: u8, dma_address: u32, burst_words: u8, direction: DmaDirection) -> Result<(), StartError> {
        if self.active.is_some() || self.completion.is_some() { return Err(StartError::Busy); }
        if slot as usize >= SLOT_COUNT { return Err(StartError::BadSlot); }
        if !matches!(burst_words, 1 | 4 | 8 | 16) { return Err(StartError::BadBurst); }
        let channel = ((dma_address >> 28) & 0xf) as u8;
        let generation = ((dma_address >> 24) & 0xf) as u8;
        let offset = dma_address & 0x00ff_ffff;
        if offset & 3 != 0 { return Err(StartError::MisalignedOffset); }
        let cap = self.caps[slot as usize][channel as usize];
        if !cap.valid { return Err(StartError::Unbound); }
        if cap.generation != generation { return Err(StartError::StaleGeneration); }
        let permitted = match direction { DmaDirection::DeviceRead => cap.device_read, DmaDirection::DeviceWrite => cap.device_write };
        if !permitted { return Err(StartError::Permission); }
        let bytes = u32::from(burst_words) * 4;
        if offset.checked_add(bytes).filter(|end| *end <= cap.length).is_none() { return Err(StartError::Range); }
        let physical_address = cap.host_physical_base.checked_add(offset).ok_or(StartError::Range)?;
        self.active = Some(Active { slot, channel, generation, direction, physical_address, total: burst_words, acknowledged: 0, pending_write: None, read_data: None, wait_cycles: 0, revoke_pending: false });
        self.state = match direction { DmaDirection::DeviceRead => DmaState::MemRequest, DmaDirection::DeviceWrite => DmaState::AwaitDeviceWrite };
        Ok(())
    }

    pub fn offer_device_write(&mut self, word: u32, parity: u8) -> Result<(), DmaError> {
        let Some(mut a) = self.active else { return Err(DmaError::Protection); };
        if self.state != DmaState::AwaitDeviceWrite || a.direction != DmaDirection::DeviceWrite { return Err(DmaError::Protection); }
        if !parity_matches(word, parity, 0xf) { self.abort(DmaError::Parity); return Err(DmaError::Parity); }
        if a.revoke_pending { self.abort(DmaError::Revoked); return Err(DmaError::Revoked); }
        a.pending_write = Some(word);
        a.wait_cycles = 0;
        self.active = Some(a);
        self.state = DmaState::MemRequest;
        Ok(())
    }

    pub fn memory_request(&self) -> Option<MemoryRequest> {
        if self.state != DmaState::MemRequest { return None; }
        let a = self.active?;
        Some(match a.direction {
            DmaDirection::DeviceRead => MemoryRequest::Read32 { physical_address: a.physical_address },
            DmaDirection::DeviceWrite => MemoryRequest::Write32 { physical_address: a.physical_address, value: a.pending_write? },
        })
    }

    pub fn memory_request_accepted(&mut self) {
        if self.state == DmaState::MemRequest {
            if let Some(a) = self.active.as_mut() { a.wait_cycles = 0; }
            self.state = DmaState::MemResponse;
        }
    }

    pub fn memory_response(&mut self, response: MemoryResponse) {
        if self.state != DmaState::MemResponse { return; }
        let Some(mut a) = self.active else { return; };
        match (a.direction, response) {
            (_, MemoryResponse::Fault) => self.abort(DmaError::MemoryFault),
            (DmaDirection::DeviceWrite, MemoryResponse::WriteDone) => {
                a.acknowledged += 1;
                a.pending_write = None;
                a.wait_cycles = 0;
                a.physical_address = a.physical_address.wrapping_add(4);
                self.active = Some(a);
                if a.revoke_pending { self.abort(DmaError::Revoked); }
                else if a.acknowledged == a.total { self.finish_ok(a.acknowledged); }
                else { self.state = DmaState::AwaitDeviceWrite; }
            }
            (DmaDirection::DeviceRead, MemoryResponse::ReadData(data)) => {
                a.read_data = Some(data);
                a.wait_cycles = 0;
                self.active = Some(a);
                self.state = DmaState::DeviceReadReady;
            }
            _ => self.abort(DmaError::MemoryFault),
        }
    }

    pub fn device_read_data(&self) -> Option<(u32, u8)> {
        if self.state != DmaState::DeviceReadReady { return None; }
        let data = self.active?.read_data?;
        Some((data, odd_parity_32(data)))
    }

    pub fn acknowledge_device_read(&mut self) {
        if self.state != DmaState::DeviceReadReady { return; }
        let Some(mut a) = self.active else { return; };
        a.acknowledged += 1;
        a.read_data = None;
        a.wait_cycles = 0;
        a.physical_address = a.physical_address.wrapping_add(4);
        self.active = Some(a);
        if a.revoke_pending { self.abort(DmaError::Revoked); }
        else if a.acknowledged == a.total { self.finish_ok(a.acknowledged); }
        else { self.state = DmaState::MemRequest; }
    }

    pub fn wait_cycle(&mut self) {
        let Some(a) = self.active.as_mut() else { return; };
        a.wait_cycles += 1;
        if a.wait_cycles >= PLIO_TIMEOUT_CYCLES { self.abort(DmaError::Timeout); }
    }

    pub fn reset(&mut self) {
        if self.active.is_some() { self.abort(DmaError::Reset); }
        self.state = DmaState::Idle;
    }

    fn finish_ok(&mut self, beats: u8) {
        self.completion = Some(Ok(beats));
        self.active = None;
        self.state = DmaState::Idle;
    }

    fn abort(&mut self, error: DmaError) {
        let partial = self.active.map(|a| a.acknowledged).unwrap_or(0);
        self.completion = Some(Err(error));
        self.active = None;
        self.state = DmaState::Idle;
        let _ = partial;
    }

    pub fn completion(&self) -> Option<Result<u8, DmaError>> { self.completion }
    pub fn take_completion(&mut self) -> Option<Result<u8, DmaError>> { self.completion.take() }

    pub fn debug(&self) -> DmaDebug {
        let a = self.active;
        DmaDebug {
            state: self.state,
            slot: a.map(|x| x.slot), channel: a.map(|x| x.channel), generation: a.map(|x| x.generation),
            physical_address: a.map(|x| x.physical_address), acknowledged_beats: a.map(|x| x.acknowledged).unwrap_or(0),
            total_beats: a.map(|x| x.total).unwrap_or(0), wait_cycles: a.map(|x| x.wait_cycles).unwrap_or(0),
            revoke_pending: a.map(|x| x.revoke_pending).unwrap_or(false),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn handle(channel: u8, generation: u8, offset: u32) -> u32 {
        (u32::from(channel) << 28) | (u32::from(generation) << 24) | offset
    }

    fn bind_rw(h: &mut DmaHostM3, slot: u8, channel: u8, length: u32) -> u8 {
        h.bind(slot, channel, 0x1000_0000 + u32::from(slot) * 0x0100_0000, length, true, true).unwrap()
    }

    #[test]
    fn capability_generation_range_and_permissions_are_enforced() {
        let mut h = DmaHostM3::new();
        let g = h.bind(2, 3, 0x2000_0000, 0x100, true, false).unwrap();
        assert_eq!(g, 0);
        assert_eq!(h.start(2, handle(3, 1, 0), 1, DmaDirection::DeviceRead), Err(StartError::StaleGeneration));
        assert_eq!(h.start(2, handle(3, g, 0), 1, DmaDirection::DeviceWrite), Err(StartError::Permission));
        assert_eq!(h.start(2, handle(3, g, 0xfc), 4, DmaDirection::DeviceRead), Err(StartError::Range));
    }

    #[test]
    fn every_burst_size_works_in_both_directions() {
        for words in [1, 4, 8, 16] {
            let mut w = DmaHostM3::new();
            let g = bind_rw(&mut w, 0, 1, 0x1000);
            w.start(0, handle(1, g, 0x40), words, DmaDirection::DeviceWrite).unwrap();
            for beat in 0..words {
                let data = 0xa000_0000 | u32::from(beat);
                w.offer_device_write(data, odd_parity_32(data)).unwrap();
                assert_eq!(w.memory_request(), Some(MemoryRequest::Write32 { physical_address: 0x1000_0040 + u32::from(beat) * 4, value: data }));
                w.memory_request_accepted();
                w.memory_response(MemoryResponse::WriteDone);
            }
            assert_eq!(w.take_completion(), Some(Ok(words)));

            let mut r = DmaHostM3::new();
            let g = bind_rw(&mut r, 0, 1, 0x1000);
            r.start(0, handle(1, g, 0x40), words, DmaDirection::DeviceRead).unwrap();
            for beat in 0..words {
                assert_eq!(r.memory_request(), Some(MemoryRequest::Read32 { physical_address: 0x1000_0040 + u32::from(beat) * 4 }));
                r.memory_request_accepted();
                let data = 0xb000_0000 | u32::from(beat);
                r.memory_response(MemoryResponse::ReadData(data));
                assert_eq!(r.device_read_data(), Some((data, odd_parity_32(data))));
                r.acknowledge_device_read();
            }
            assert_eq!(r.take_completion(), Some(Ok(words)));
        }
    }

    #[test]
    fn memory_backpressure_does_not_ack_early() {
        let mut h = DmaHostM3::new();
        let g = bind_rw(&mut h, 0, 0, 0x100);
        h.start(0, handle(0, g, 0), 1, DmaDirection::DeviceWrite).unwrap();
        let data = 0x1122_3344;
        h.offer_device_write(data, odd_parity_32(data)).unwrap();
        for _ in 0..5 { h.wait_cycle(); assert_eq!(h.completion(), None); }
        h.memory_request_accepted();
        for _ in 0..5 { h.wait_cycle(); assert_eq!(h.completion(), None); }
        h.memory_response(MemoryResponse::WriteDone);
        assert_eq!(h.take_completion(), Some(Ok(1)));
    }

    #[test]
    fn parity_memory_fault_timeout_and_reset_preserve_partial_progress_semantics() {
        let mut h = DmaHostM3::new();
        let g = bind_rw(&mut h, 0, 0, 0x100);
        h.start(0, handle(0, g, 0), 4, DmaDirection::DeviceWrite).unwrap();
        let d0 = 0x1111_1111;
        h.offer_device_write(d0, odd_parity_32(d0)).unwrap(); h.memory_request_accepted(); h.memory_response(MemoryResponse::WriteDone);
        assert_eq!(h.debug().acknowledged_beats, 1);
        assert_eq!(h.offer_device_write(0x2222_2222, 0), Err(DmaError::Parity));
        assert_eq!(h.take_completion(), Some(Err(DmaError::Parity)));

        h.start(0, handle(0, g, 0), 1, DmaDirection::DeviceRead).unwrap(); h.memory_request_accepted(); h.memory_response(MemoryResponse::Fault);
        assert_eq!(h.take_completion(), Some(Err(DmaError::MemoryFault)));

        h.start(0, handle(0, g, 0), 1, DmaDirection::DeviceRead).unwrap();
        for _ in 0..PLIO_TIMEOUT_CYCLES { h.wait_cycle(); }
        assert_eq!(h.take_completion(), Some(Err(DmaError::Timeout)));

        h.start(0, handle(0, g, 0), 1, DmaDirection::DeviceRead).unwrap(); h.reset();
        assert_eq!(h.take_completion(), Some(Err(DmaError::Reset)));
    }

    #[test]
    fn revoke_interlocks_active_burst_after_current_memory_beat() {
        let mut h = DmaHostM3::new();
        let g = bind_rw(&mut h, 1, 2, 0x100);
        h.start(1, handle(2, g, 0), 4, DmaDirection::DeviceWrite).unwrap();
        let d = 0x1234_5678;
        h.offer_device_write(d, odd_parity_32(d)).unwrap();
        h.memory_request_accepted();
        assert_eq!(h.revoke(1, 2), Ok(false));
        assert!(!h.capability(1, 2).unwrap().valid);
        h.memory_response(MemoryResponse::WriteDone);
        assert_eq!(h.take_completion(), Some(Err(DmaError::Revoked)));
        assert_eq!(h.bind(1, 2, 0x3000_0000, 0x100, true, true), Ok(1));
    }
}

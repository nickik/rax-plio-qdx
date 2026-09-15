#![forbid(unsafe_code)]

use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::Path;

use plio_logical_model::BurstWords;
use qdx_a_model::{EndpointIn, EndpointOut, QdxACommand, QdxACompletion};
use qli_model::{DmaCompletion, DmaDirection, DmaRequest, DmaStatus, DmaWord};

pub const OP_NOP: u8 = 0x00;
pub const OP_IDENTIFY_CONTROLLER: u8 = 0x01;
pub const OP_IDENTIFY_NAMESPACE: u8 = 0x02;
pub const OP_IDENTIFY_INTEGRITY: u8 = 0x03;
pub const OP_READ: u8 = 0x10;
pub const OP_WRITE: u8 = 0x11;
pub const OP_FLUSH: u8 = 0x12;
pub const OP_GET_HEALTH: u8 = 0x13;
pub const OP_WRITE_DURABLE: u8 = 0x14;

pub const ST_SUCCESS: u16 = 0x0000;
pub const ST_INVALID_OPCODE: u16 = 0x0001;
pub const ST_INVALID_NAMESPACE: u16 = 0x0002;
pub const ST_INVALID_FIELD: u16 = 0x0003;
pub const ST_LBA_RANGE: u16 = 0x0004;
pub const ST_DMA_FAULT: u16 = 0x0005;
pub const ST_MEDIA_ERROR: u16 = 0x0006;
pub const ST_WRITE_PROTECTED: u16 = 0x0007;
pub const ST_NOT_READY: u16 = 0x0008;
pub const ST_QUEUE_ERROR: u16 = 0x0009;
pub const ST_INTERNAL_ERROR: u16 = 0x000a;

pub const CF_WRITE_DURABLE_DONE: u16 = 1 << 3;
pub const MAX_SG: usize = 16;
pub const MAX_TRANSFER_BLOCKS: u32 = 1;
pub const NS_BLOCKS: u32 = 64;
const DMA_OFFSET_MASK: u32 = 0x00ff_ffff;
const DMA_OFFSET_SPACE: u32 = 0x0100_0000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ProfileDmaIn {
    pub request: Option<DmaRequest>,
    pub read_ready: bool,
    pub write: Option<DmaWord>,
    pub completion_ready: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ProfileDmaOut {
    pub request_ready: bool,
    pub read: Option<DmaWord>,
    pub write_ready: bool,
    pub completion: Option<DmaCompletion>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
struct SgEntry {
    address: u32,
    length_bytes: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Command {
    pub opcode: u8,
    pub flags: u8,
    pub namespace_id: u16,
    pub tag: u32,
    pub lba: u32,
    pub block_count: u16,
    pub sg_count: u8,
    pub reserved0: u8,
    pub data_addr: u32,
    pub sg_addr: u32,
    pub command_arg: u32,
    pub reserved1: u32,
}

impl Command {
    pub fn decode(words: QdxACommand) -> Self {
        Self {
            opcode: (words[0] & 0xff) as u8,
            flags: ((words[0] >> 8) & 0xff) as u8,
            namespace_id: (words[0] >> 16) as u16,
            tag: words[1],
            lba: words[2],
            block_count: (words[3] & 0xffff) as u16,
            sg_count: ((words[3] >> 16) & 0xff) as u8,
            reserved0: ((words[3] >> 24) & 0xff) as u8,
            data_addr: words[4],
            sg_addr: words[5],
            command_arg: words[6],
            reserved1: words[7],
        }
    }
}

pub trait BlockBackend: Send {
    fn block_size(&self) -> usize;
    fn total_blocks(&self) -> u32;
    fn read_only(&self) -> bool { false }
    fn read_block(&mut self, lba: u32, dst: &mut [u32]) -> Result<(), String>;
    fn write_block(&mut self, lba: u32, src: &[u32]) -> Result<(), String>;
    fn flush(&mut self) -> Result<(), String> { Ok(()) }
}

#[derive(Debug, Clone)]
pub struct RamDisk {
    block_size: usize,
    blocks: u32,
    data: Vec<u32>,
    read_only: bool,
}

impl RamDisk {
    pub fn new(blocks: u32, block_size: usize) -> Result<Self, String> {
        Self::with_read_only(blocks, block_size, false)
    }

    pub fn with_read_only(blocks: u32, block_size: usize, read_only: bool) -> Result<Self, String> {
        validate_geometry(blocks, block_size)?;
        let words = (blocks as usize)
            .checked_mul(block_size / 4)
            .ok_or("RAM disk size overflow")?;
        Ok(Self { block_size, blocks, data: vec![0; words], read_only })
    }

    fn range(&self, lba: u32) -> Result<std::ops::Range<usize>, String> {
        if lba >= self.blocks { return Err("QDX-B LBA exceeds namespace capacity".into()); }
        let words = self.block_size / 4;
        let start = lba as usize * words;
        Ok(start..start + words)
    }
}

impl BlockBackend for RamDisk {
    fn block_size(&self) -> usize { self.block_size }
    fn total_blocks(&self) -> u32 { self.blocks }
    fn read_only(&self) -> bool { self.read_only }

    fn read_block(&mut self, lba: u32, dst: &mut [u32]) -> Result<(), String> {
        let range = self.range(lba)?;
        if dst.len() < range.len() { return Err("destination buffer too small".into()); }
        dst[..range.len()].copy_from_slice(&self.data[range]);
        Ok(())
    }

    fn write_block(&mut self, lba: u32, src: &[u32]) -> Result<(), String> {
        if self.read_only { return Err("namespace is read-only".into()); }
        let range = self.range(lba)?;
        if src.len() < range.len() { return Err("source buffer too small".into()); }
        let n = range.len();
        self.data[range].copy_from_slice(&src[..n]);
        Ok(())
    }
}

#[derive(Debug)]
pub struct FileDisk {
    file: File,
    block_size: usize,
    blocks: u32,
    read_only: bool,
}

impl FileDisk {
    pub fn create(path: impl AsRef<Path>, blocks: u32, block_size: usize) -> Result<Self, String> {
        validate_geometry(blocks, block_size)?;
        let bytes = (blocks as u64)
            .checked_mul(block_size as u64)
            .ok_or("file disk size overflow")?;
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .open(path)
            .map_err(|e| format!("create QDX-B file disk: {e}"))?;
        file.set_len(bytes).map_err(|e| format!("size QDX-B file disk: {e}"))?;
        Ok(Self { file, block_size, blocks, read_only: false })
    }

    pub fn open(path: impl AsRef<Path>, block_size: usize, read_only: bool) -> Result<Self, String> {
        if block_size < 4 || block_size & 3 != 0 { return Err("block size must be a multiple of 4".into()); }
        let file = OpenOptions::new()
            .read(true)
            .write(!read_only)
            .open(path)
            .map_err(|e| format!("open QDX-B file disk: {e}"))?;
        let len = file.metadata().map_err(|e| format!("stat QDX-B file disk: {e}"))?.len();
        if len == 0 || len % block_size as u64 != 0 { return Err("file disk size must contain whole blocks".into()); }
        let blocks = u32::try_from(len / block_size as u64).map_err(|_| "file disk has too many blocks")?;
        validate_geometry(blocks, block_size)?;
        Ok(Self { file, block_size, blocks, read_only })
    }

    fn seek_block(&mut self, lba: u32) -> Result<(), String> {
        if lba >= self.blocks { return Err("QDX-B LBA exceeds namespace capacity".into()); }
        self.file
            .seek(SeekFrom::Start(u64::from(lba) * self.block_size as u64))
            .map(|_| ())
            .map_err(|e| format!("seek QDX-B file disk: {e}"))
    }
}

impl BlockBackend for FileDisk {
    fn block_size(&self) -> usize { self.block_size }
    fn total_blocks(&self) -> u32 { self.blocks }
    fn read_only(&self) -> bool { self.read_only }

    fn read_block(&mut self, lba: u32, dst: &mut [u32]) -> Result<(), String> {
        self.seek_block(lba)?;
        let words = self.block_size / 4;
        if dst.len() < words { return Err("destination buffer too small".into()); }
        let mut bytes = vec![0u8; self.block_size];
        self.file.read_exact(&mut bytes).map_err(|e| format!("read QDX-B file disk: {e}"))?;
        for (i, chunk) in bytes.chunks_exact(4).enumerate() {
            dst[i] = u32::from_le_bytes(chunk.try_into().unwrap());
        }
        Ok(())
    }

    fn write_block(&mut self, lba: u32, src: &[u32]) -> Result<(), String> {
        if self.read_only { return Err("namespace is read-only".into()); }
        self.seek_block(lba)?;
        let words = self.block_size / 4;
        if src.len() < words { return Err("source buffer too small".into()); }
        let mut bytes = Vec::with_capacity(self.block_size);
        for word in src.iter().take(words) { bytes.extend_from_slice(&word.to_le_bytes()); }
        self.file.write_all(&bytes).map_err(|e| format!("write QDX-B file disk: {e}"))
    }

    fn flush(&mut self) -> Result<(), String> {
        self.file.sync_data().map_err(|e| format!("flush QDX-B file disk: {e}"))
    }
}

fn validate_geometry(blocks: u32, block_size: usize) -> Result<(), String> {
    if blocks == 0 { return Err("QDX-B namespace must contain at least one block".into()); }
    if block_size < 4 || block_size & 3 != 0 { return Err("QDX-B block size must be a multiple of 4".into()); }
    Ok(())
}

pub struct FakeMedia {
    ns512: Box<dyn BlockBackend>,
    ns1024: Box<dyn BlockBackend>,
    pub flushes: u32,
}

impl Default for FakeMedia {
    fn default() -> Self { Self::new() }
}

impl FakeMedia {
    pub fn new() -> Self {
        Self::with_backends(
            Box::new(RamDisk::new(NS_BLOCKS, 512).expect("valid QDX-B NS1 RAM disk")),
            Box::new(RamDisk::new(NS_BLOCKS, 1024).expect("valid QDX-B NS2 RAM disk")),
        ).expect("valid default QDX-B media")
    }

    pub fn with_backends(ns512: Box<dyn BlockBackend>, ns1024: Box<dyn BlockBackend>) -> Result<Self, String> {
        if ns512.block_size() != 512 || ns512.total_blocks() != NS_BLOCKS {
            return Err("QDX-B namespace 1 must be 64 x 512-byte blocks".into());
        }
        if ns1024.block_size() != 1024 || ns1024.total_blocks() != NS_BLOCKS {
            return Err("QDX-B namespace 2 must be 64 x 1024-byte blocks".into());
        }
        Ok(Self { ns512, ns1024, flushes: 0 })
    }

    pub fn file_backed(path512: impl AsRef<Path>, path1024: impl AsRef<Path>) -> Result<Self, String> {
        Self::with_backends(
            Box::new(FileDisk::create(path512, NS_BLOCKS, 512)?),
            Box::new(FileDisk::create(path1024, NS_BLOCKS, 1024)?),
        )
    }

    pub const fn block_size(namespace_id: u16) -> Option<usize> {
        match namespace_id { 1 => Some(512), 2 => Some(1024), _ => None }
    }

    fn backend_mut(&mut self, ns: u16) -> Option<&mut (dyn BlockBackend + '_)> {
        match ns {
            1 => Some(self.ns512.as_mut()),
            2 => Some(self.ns1024.as_mut()),
            _ => None,
        }
    }

    pub fn seed_block(&mut self, ns: u16, lba: u32, base: u32) {
        let Some(bytes) = Self::block_size(ns) else { return; };
        let mut block = vec![0u32; bytes / 4];
        for (i, w) in block.iter_mut().enumerate() { *w = base.wrapping_add((i as u32) * 4); }
        if let Some(backend) = self.backend_mut(ns) { let _ = backend.write_block(lba, &block); }
    }

    pub fn read_block(&mut self, ns: u16, lba: u32, dst: &mut [u32; 256]) -> bool {
        let Some(backend) = self.backend_mut(ns) else { return false; };
        backend.read_block(lba, dst).is_ok()
    }

    pub fn write_block(&mut self, ns: u16, lba: u32, src: &[u32; 256]) -> bool {
        let Some(backend) = self.backend_mut(ns) else { return false; };
        backend.write_block(lba, src).is_ok()
    }

    pub fn flush(&mut self, ns: u16) {
        if let Some(backend) = self.backend_mut(ns) {
            if backend.flush().is_ok() { self.flushes = self.flushes.wrapping_add(1); }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HighState { Idle, FetchSg, Transfer, MediaCommit, Complete }
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DmaPhase { Idle, Request, Transfer, Completion }
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DmaKind { None, SgAddress, SgLength, Payload }

#[derive(Debug, Clone)]
pub struct QdxBEndpoint {
    state: HighState,
    command: Option<Command>,
    completion: Option<QdxACompletion>,
    sg: [SgEntry; MAX_SG],
    sg_entry: u8,
    sg_part: u8,
    transfer_words: usize,
    transfer_index: usize,
    segment_index: usize,
    segment_word_offset: usize,
    payload: [u32; 256],
    dma_phase: DmaPhase,
    dma_kind: DmaKind,
    dma_req: Option<DmaRequest>,
    dma_moved: u8,
    pending_status: u16,
    pending_flags: u16,
}

impl Default for QdxBEndpoint { fn default() -> Self { Self::new() } }

impl QdxBEndpoint {
    pub const fn new() -> Self {
        Self {
            state: HighState::Idle,
            command: None,
            completion: None,
            sg: [SgEntry { address: 0, length_bytes: 0 }; MAX_SG],
            sg_entry: 0,
            sg_part: 0,
            transfer_words: 0,
            transfer_index: 0,
            segment_index: 0,
            segment_word_offset: 0,
            payload: [0; 256],
            dma_phase: DmaPhase::Idle,
            dma_kind: DmaKind::None,
            dma_req: None,
            dma_moved: 0,
            pending_status: ST_SUCCESS,
            pending_flags: 0,
        }
    }

    pub fn drive(&self, qdx: EndpointOut, _dma: ProfileDmaOut) -> (EndpointIn, ProfileDmaIn) {
        let endpoint = EndpointIn {
            command_ready: self.state == HighState::Idle && self.completion.is_none() && !qdx.reset,
            completion: self.completion,
        };
        let mut p = ProfileDmaIn::default();
        match self.dma_phase {
            DmaPhase::Request => p.request = self.dma_req,
            DmaPhase::Transfer => {
                if let Some(req) = self.dma_req {
                    match req.direction {
                        DmaDirection::HostToDevice => p.read_ready = true,
                        DmaDirection::DeviceToHost => {
                            if self.dma_kind == DmaKind::Payload {
                                let i = self.transfer_index + self.dma_moved as usize;
                                p.write = Some(DmaWord { data: self.payload[i] });
                            }
                        }
                    }
                }
            }
            DmaPhase::Completion => p.completion_ready = true,
            DmaPhase::Idle => {}
        }
        (endpoint, p)
    }

    pub fn clock(&mut self, qdx: EndpointOut, dma: ProfileDmaOut, media: &mut FakeMedia) {
        if qdx.reset {
            *self = Self::new();
            return;
        }

        if self.state == HighState::Complete {
            if qdx.completion_ready && self.completion.is_some() {
                self.completion = None;
                self.command = None;
                self.state = HighState::Idle;
            }
            return;
        }

        if self.state == HighState::Idle {
            if let Some(words) = qdx.command {
                self.accept_command(Command::decode(words), media);
            }
            return;
        }

        self.clock_dma(dma, media);

        if self.state == HighState::MediaCommit && self.dma_phase == DmaPhase::Idle {
            self.commit_media(media);
        }
    }

    fn accept_command(&mut self, cmd: Command, media: &mut FakeMedia) {
        self.command = Some(cmd);
        self.pending_status = ST_SUCCESS;
        self.pending_flags = 0;
        self.transfer_index = 0;
        self.segment_index = 0;
        self.segment_word_offset = 0;
        self.sg_entry = 0;
        self.sg_part = 0;
        self.sg = [SgEntry::default(); MAX_SG];

        if cmd.flags != 0 || cmd.reserved0 != 0 || cmd.reserved1 != 0 || cmd.sg_count as usize > MAX_SG {
            self.finish(ST_INVALID_FIELD, 0, 0);
            return;
        }

        let status = self.validate_command(cmd);
        if status != ST_SUCCESS {
            self.finish(status, 0, 0);
            return;
        }

        match cmd.opcode {
            OP_NOP => self.finish(ST_SUCCESS, 0, 0),
            OP_FLUSH => {
                media.flush(cmd.namespace_id);
                self.finish(ST_SUCCESS, 0, 0);
            }
            OP_IDENTIFY_CONTROLLER | OP_IDENTIFY_NAMESPACE | OP_GET_HEALTH | OP_READ | OP_WRITE | OP_WRITE_DURABLE => {
                if cmd.sg_count > 0 {
                    self.state = HighState::FetchSg;
                    self.start_sg_word_dma();
                } else {
                    self.start_operation(media);
                }
            }
            _ => self.finish(ST_INVALID_OPCODE, 0, 0),
        }
    }

    fn validate_command(&self, cmd: Command) -> u16 {
        if cmd.command_arg != 0 { return ST_INVALID_FIELD; }
        let valid_ns = matches!(cmd.namespace_id, 1 | 2);
        match cmd.opcode {
            OP_NOP => {
                if cmd.namespace_id != 0 || cmd.block_count != 0 || cmd.sg_count != 0 || cmd.data_addr != 0 || cmd.sg_addr != 0 { ST_INVALID_FIELD } else { ST_SUCCESS }
            }
            OP_IDENTIFY_CONTROLLER => {
                if cmd.namespace_id != 0 || cmd.block_count != 0 { ST_INVALID_FIELD } else { self.validate_data_buffer(cmd, 64) }
            }
            OP_IDENTIFY_NAMESPACE => {
                if !valid_ns { ST_INVALID_NAMESPACE }
                else if cmd.block_count != 0 { ST_INVALID_FIELD }
                else { self.validate_data_buffer(cmd, 64) }
            }
            OP_IDENTIFY_INTEGRITY => ST_INVALID_OPCODE,
            OP_GET_HEALTH => {
                if cmd.namespace_id > 2 { ST_INVALID_NAMESPACE }
                else if cmd.block_count != 0 { ST_INVALID_FIELD }
                else { self.validate_data_buffer(cmd, 64) }
            }
            OP_READ | OP_WRITE | OP_WRITE_DURABLE => {
                if !valid_ns { return ST_INVALID_NAMESPACE; }
                if cmd.block_count == 0 || u32::from(cmd.block_count) > MAX_TRANSFER_BLOCKS { return ST_INVALID_FIELD; }
                if cmd.lba >= NS_BLOCKS || cmd.lba.saturating_add(u32::from(cmd.block_count)) > NS_BLOCKS { return ST_LBA_RANGE; }
                let bytes = FakeMedia::block_size(cmd.namespace_id).unwrap_or(0);
                self.validate_data_buffer(cmd, bytes)
            }
            OP_FLUSH => {
                if !valid_ns { ST_INVALID_NAMESPACE }
                else if cmd.block_count != 0 || cmd.sg_count != 0 || cmd.data_addr != 0 || cmd.sg_addr != 0 { ST_INVALID_FIELD }
                else { ST_SUCCESS }
            }
            _ => ST_INVALID_OPCODE,
        }
    }

    fn validate_data_buffer(&self, cmd: Command, bytes: usize) -> u16 {
        if cmd.sg_count == 0 {
            if handle_range_ok(cmd.data_addr, bytes as u32) { ST_SUCCESS } else { ST_INVALID_FIELD }
        } else {
            let list_bytes = u32::from(cmd.sg_count) * 8;
            if handle_range_ok(cmd.sg_addr, list_bytes) { ST_SUCCESS } else { ST_INVALID_FIELD }
        }
    }

    fn start_operation(&mut self, media: &mut FakeMedia) {
        let cmd = self.command.expect("command");
        match cmd.opcode {
            OP_IDENTIFY_CONTROLLER => {
                self.payload = [0; 256];
                self.build_identify_controller();
                self.transfer_words = 16;
                self.state = HighState::Transfer;
                self.start_payload_dma(DmaDirection::DeviceToHost);
            }
            OP_IDENTIFY_NAMESPACE => {
                self.payload = [0; 256];
                self.build_identify_namespace(cmd.namespace_id);
                self.transfer_words = 16;
                self.state = HighState::Transfer;
                self.start_payload_dma(DmaDirection::DeviceToHost);
            }
            OP_GET_HEALTH => {
                self.payload = [0; 256];
                self.payload[0] = 1;
                self.transfer_words = 16;
                self.state = HighState::Transfer;
                self.start_payload_dma(DmaDirection::DeviceToHost);
            }
            OP_READ => {
                self.payload = [0; 256];
                if !media.read_block(cmd.namespace_id, cmd.lba, &mut self.payload) {
                    self.finish(ST_MEDIA_ERROR, 0, 0);
                    return;
                }
                self.transfer_words = FakeMedia::block_size(cmd.namespace_id).unwrap() / 4;
                self.state = HighState::Transfer;
                self.start_payload_dma(DmaDirection::DeviceToHost);
            }
            OP_WRITE | OP_WRITE_DURABLE => {
                self.payload = [0; 256];
                self.transfer_words = FakeMedia::block_size(cmd.namespace_id).unwrap() / 4;
                self.state = HighState::Transfer;
                self.start_payload_dma(DmaDirection::HostToDevice);
            }
            _ => self.finish(ST_INTERNAL_ERROR, 0, 0),
        }
    }

    fn start_sg_word_dma(&mut self) {
        let cmd = self.command.expect("command");
        let delta = u32::from(self.sg_entry) * 8 + u32::from(self.sg_part) * 4;
        let address = handle_add(cmd.sg_addr, delta);
        self.dma_req = Some(DmaRequest { direction: DmaDirection::HostToDevice, address, words: BurstWords::One });
        self.dma_kind = if self.sg_part == 0 { DmaKind::SgAddress } else { DmaKind::SgLength };
        self.dma_moved = 0;
        self.dma_phase = DmaPhase::Request;
    }

    fn start_payload_dma(&mut self, direction: DmaDirection) {
        if self.transfer_index >= self.transfer_words {
            self.payload_done();
            return;
        }
        let cmd = self.command.expect("command");
        let (address, segment_words) = if cmd.sg_count == 0 {
            (handle_add(cmd.data_addr, (self.transfer_index as u32) * 4), self.transfer_words - self.transfer_index)
        } else {
            while self.segment_index < cmd.sg_count as usize {
                let words = self.sg[self.segment_index].length_bytes as usize / 4;
                if self.segment_word_offset < words { break; }
                self.segment_index += 1;
                self.segment_word_offset = 0;
            }
            if self.segment_index >= cmd.sg_count as usize {
                self.finish(ST_INVALID_FIELD, 0, 0);
                return;
            }
            let entry = self.sg[self.segment_index];
            let words = entry.length_bytes as usize / 4;
            (
                handle_add(entry.address, (self.segment_word_offset as u32) * 4),
                words - self.segment_word_offset,
            )
        };
        let remaining = self.transfer_words - self.transfer_index;
        let n = choose_burst(remaining.min(segment_words));
        self.dma_req = Some(DmaRequest { direction, address, words: n });
        self.dma_kind = DmaKind::Payload;
        self.dma_moved = 0;
        self.dma_phase = DmaPhase::Request;
    }

    fn clock_dma(&mut self, dma: ProfileDmaOut, media: &mut FakeMedia) {
        let Some(req) = self.dma_req else { return; };
        match self.dma_phase {
            DmaPhase::Request => {
                if dma.request_ready { self.dma_phase = DmaPhase::Transfer; }
            }
            DmaPhase::Transfer => match req.direction {
                DmaDirection::HostToDevice => {
                    if let Some(word) = dma.read {
                        if self.dma_kind == DmaKind::Payload {
                            let i = self.transfer_index + self.dma_moved as usize;
                            if i < self.payload.len() { self.payload[i] = word.data; }
                        } else if self.dma_kind == DmaKind::SgAddress {
                            self.sg[self.sg_entry as usize].address = word.data;
                        } else if self.dma_kind == DmaKind::SgLength {
                            self.sg[self.sg_entry as usize].length_bytes = word.data;
                        }
                        self.dma_moved += 1;
                        if self.dma_moved == req.words.words() { self.dma_phase = DmaPhase::Completion; }
                    }
                }
                DmaDirection::DeviceToHost => {
                    if dma.write_ready {
                        self.dma_moved += 1;
                        if self.dma_moved == req.words.words() { self.dma_phase = DmaPhase::Completion; }
                    }
                }
            },
            DmaPhase::Completion => {
                if let Some(c) = dma.completion {
                    if c.status != DmaStatus::Ok || c.words_completed != req.words.words() {
                        self.dma_phase = DmaPhase::Idle;
                        self.dma_req = None;
                        self.finish(ST_DMA_FAULT, 0, 0);
                        return;
                    }
                    let moved = req.words.words() as usize;
                    self.dma_phase = DmaPhase::Idle;
                    self.dma_req = None;
                    match self.dma_kind {
                        DmaKind::SgAddress => {
                            self.sg_part = 1;
                            self.start_sg_word_dma();
                        }
                        DmaKind::SgLength => {
                            self.sg_part = 0;
                            self.sg_entry += 1;
                            let count = self.command.expect("command").sg_count;
                            if self.sg_entry < count {
                                self.start_sg_word_dma();
                            } else if self.validate_sg() {
                                self.start_operation(media);
                            } else {
                                self.finish(ST_INVALID_FIELD, 0, 0);
                            }
                        }
                        DmaKind::Payload => {
                            self.transfer_index += moved;
                            if self.command.expect("command").sg_count > 0 {
                                self.segment_word_offset += moved;
                            }
                            if self.transfer_index >= self.transfer_words {
                                self.payload_done();
                            } else {
                                self.start_payload_dma(req.direction);
                            }
                        }
                        DmaKind::None => self.finish(ST_INTERNAL_ERROR, 0, 0),
                    }
                }
            }
            DmaPhase::Idle => {}
        }
    }

    fn validate_sg(&self) -> bool {
        let cmd = self.command.expect("command");
        let needed = if matches!(cmd.opcode, OP_IDENTIFY_CONTROLLER | OP_IDENTIFY_NAMESPACE | OP_GET_HEALTH) {
            64
        } else {
            FakeMedia::block_size(cmd.namespace_id).unwrap_or(0)
        } as u64;
        let mut total = 0u64;
        for e in self.sg.iter().take(cmd.sg_count as usize) {
            if e.length_bytes == 0 || e.length_bytes & 3 != 0 || !handle_range_ok(e.address, e.length_bytes) { return false; }
            total = total.saturating_add(u64::from(e.length_bytes));
        }
        total >= needed
    }

    fn payload_done(&mut self) {
        self.dma_phase = DmaPhase::Idle;
        self.dma_req = None;
        let cmd = self.command.expect("command");
        if matches!(cmd.opcode, OP_WRITE | OP_WRITE_DURABLE) {
            self.state = HighState::MediaCommit;
        } else {
            let blocks = if cmd.opcode == OP_READ { u32::from(cmd.block_count) } else { 0 };
            self.finish(ST_SUCCESS, blocks, 0);
        }
    }

    fn commit_media(&mut self, media: &mut FakeMedia) {
        let cmd = self.command.expect("command");
        if !media.write_block(cmd.namespace_id, cmd.lba, &self.payload) {
            self.finish(ST_MEDIA_ERROR, 0, 0);
            return;
        }
        let flags = if cmd.opcode == OP_WRITE_DURABLE { CF_WRITE_DURABLE_DONE } else { 0 };
        self.finish(ST_SUCCESS, u32::from(cmd.block_count), flags);
    }

    fn finish(&mut self, status: u16, blocks_done: u32, flags: u16) {
        let tag = self.command.map_or(0, |c| c.tag);
        self.completion = Some([tag, u32::from(status) | (u32::from(flags) << 16), blocks_done, 0]);
        self.pending_status = status;
        self.pending_flags = flags;
        self.dma_phase = DmaPhase::Idle;
        self.dma_req = None;
        self.state = HighState::Complete;
    }

    fn build_identify_controller(&mut self) {
        self.payload[0] = (2u32 << 16) | 5;
        self.payload[1] = 16;
        self.payload[2] = MAX_TRANSFER_BLOCKS;
        self.payload[3] = 0;
        put_ascii(&mut self.payload[4..8], b"DEC QDX-B BASE   ");
        put_ascii(&mut self.payload[8..12], b"SIM0000000000001");
    }

    fn build_identify_namespace(&mut self, ns: u16) {
        let block_size = FakeMedia::block_size(ns).unwrap_or(0) as u32;
        self.payload[0] = u32::from(ns);
        self.payload[1] = block_size;
        self.payload[2] = NS_BLOCKS;
        self.payload[3] = block_size;
        if ns == 1 {
            put_ascii(&mut self.payload[4..8], b"FAKE-512        ");
            put_ascii(&mut self.payload[8..12], b"NS00000000000001");
        } else {
            put_ascii(&mut self.payload[4..8], b"FAKE-1024       ");
            put_ascii(&mut self.payload[8..12], b"NS00000000000002");
        }
    }

    pub fn pending_status(&self) -> u16 { self.pending_status }
    pub fn pending_flags(&self) -> u16 { self.pending_flags }
}

fn choose_burst(words: usize) -> BurstWords {
    if words >= 16 { BurstWords::Sixteen }
    else if words >= 8 { BurstWords::Eight }
    else if words >= 4 { BurstWords::Four }
    else { BurstWords::One }
}

fn handle_range_ok(handle: u32, bytes: u32) -> bool {
    if handle & 3 != 0 || bytes == 0 || bytes > DMA_OFFSET_SPACE { return false; }
    let offset = handle & DMA_OFFSET_MASK;
    offset <= DMA_OFFSET_SPACE - bytes
}

fn handle_add(handle: u32, delta: u32) -> u32 {
    let upper = handle & !DMA_OFFSET_MASK;
    let offset = (handle & DMA_OFFSET_MASK) + delta;
    debug_assert!(offset <= DMA_OFFSET_MASK);
    upper | offset
}

fn put_ascii(dst: &mut [u32], bytes: &[u8]) {
    for (i, word) in dst.iter_mut().enumerate() {
        let mut v = 0u32;
        for b in 0..4 {
            if let Some(x) = bytes.get(i * 4 + b) { v |= u32::from(*x) << (8 * b); }
        }
        *word = v;
    }
}

pub fn merge_profile_dma(mut core: qli_model::DeviceToQic, state: qdx_a_model::QdxAState, p: ProfileDmaIn) -> qli_model::DeviceToQic {
    if state == qdx_a_model::QdxAState::EndpointCompletion {
        if let Some(r) = p.request { core.dma_request = Some(r); }
        core.dma_read_ready = p.read_ready;
        core.dma_write = p.write;
        core.dma_completion_ready = p.completion_ready;
    }
    core
}

pub fn profile_dma_response(state: qdx_a_model::QdxAState, qic: &qli_model::QicToDevice) -> ProfileDmaOut {
    if state != qdx_a_model::QdxAState::EndpointCompletion { return ProfileDmaOut::default(); }
    ProfileDmaOut {
        request_ready: qic.dma_request_ready,
        read: qic.dma_read,
        write_ready: qic.dma_write_ready,
        completion: qic.dma_completion,
    }
}

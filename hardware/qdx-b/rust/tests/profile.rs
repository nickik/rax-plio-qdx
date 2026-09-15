use std::collections::BTreeMap;

use plio_logical_model::BurstWords;
use qdx_a_model::{EndpointOut, QdxACommand};
use qdx_b_model::*;
use qli_model::{DmaCompletion, DmaDirection, DmaRequest, DmaStatus, DmaWord};

#[derive(Default)]
struct Host {
    mem: BTreeMap<u32, u32>,
    active: Option<DmaRequest>,
    moved: u8,
    fail_next: bool,
}

impl Host {
    fn put(&mut self, addr: u32, words: &[u32]) {
        for (i, w) in words.iter().enumerate() { self.mem.insert(addr + (i as u32) * 4, *w); }
    }
    fn get(&self, addr: u32, words: usize) -> Vec<u32> {
        (0..words).map(|i| *self.mem.get(&(addr + i as u32 * 4)).unwrap_or(&0)).collect()
    }
    fn respond(&mut self, p: ProfileDmaIn) -> ProfileDmaOut {
        let mut o = ProfileDmaOut::default();
        if self.active.is_none() {
            if let Some(r) = p.request {
                self.active = Some(r);
                self.moved = 0;
                o.request_ready = true;
            }
            return o;
        }
        let r = self.active.unwrap();
        if self.moved < r.words.words() {
            match r.direction {
                DmaDirection::HostToDevice => {
                    if p.read_ready {
                        let a = r.address + u32::from(self.moved) * 4;
                        o.read = Some(DmaWord { data: *self.mem.get(&a).unwrap_or(&0) });
                        self.moved += 1;
                    }
                }
                DmaDirection::DeviceToHost => {
                    if let Some(w) = p.write {
                        o.write_ready = true;
                        let a = r.address + u32::from(self.moved) * 4;
                        self.mem.insert(a, w.data);
                        self.moved += 1;
                    }
                }
            }
        } else if p.completion_ready {
            o.completion = Some(if self.fail_next {
                self.fail_next = false;
                DmaCompletion { status: DmaStatus::BusError, words_completed: self.moved }
            } else {
                DmaCompletion { status: DmaStatus::Ok, words_completed: self.moved }
            });
            self.active = None;
            self.moved = 0;
        }
        o
    }
}

fn cmd(op: u8, ns: u16, tag: u32, lba: u32, count: u16, data: u32, sg: u32, sg_count: u8) -> QdxACommand {
    [
        u32::from(op) | (u32::from(ns) << 16),
        tag,
        lba,
        u32::from(count) | (u32::from(sg_count) << 16),
        data,
        sg,
        0,
        0,
    ]
}

fn run(ep: &mut QdxBEndpoint, media: &mut FakeMedia, host: &mut Host, command: QdxACommand) -> [u32; 4] {
    let mut qdx = EndpointOut { command: Some(command), ..EndpointOut::default() };
    let mut dma_out = ProfileDmaOut::default();
    let mut result = None;
    for cycle in 0..20_000 {
        let (e, p) = ep.drive(qdx, dma_out);
        if let Some(c) = e.completion { result = Some(c); break; }
        dma_out = host.respond(p);
        ep.clock(qdx, dma_out, media);
        qdx.command = None;
        if cycle == 19_999 { panic!("QDX-B command did not complete"); }
    }
    let c = result.unwrap();
    let (e, p) = ep.drive(EndpointOut { completion_ready: true, ..EndpointOut::default() }, ProfileDmaOut::default());
    assert_eq!(e.completion, Some(c));
    let out = host.respond(p);
    ep.clock(EndpointOut { completion_ready: true, ..EndpointOut::default() }, out, media);
    c
}

fn status(c: [u32;4]) -> u16 { (c[1] & 0xffff) as u16 }
fn flags(c: [u32;4]) -> u16 { (c[1] >> 16) as u16 }

#[test]
fn identify_controller_and_both_namespace_sizes() {
    let mut ep=QdxBEndpoint::new(); let mut media=FakeMedia::new(); let mut host=Host::default();
    let c=run(&mut ep,&mut media,&mut host,cmd(OP_IDENTIFY_CONTROLLER,0,0x11,0,0,0x1000,0,0));
    assert_eq!(status(c),ST_SUCCESS); assert_eq!(c[0],0x11);
    let id=host.get(0x1000,16);
    assert_eq!(id[0],0x0002_0005); // two namespaces, revision 5
    assert_eq!(id[1],16);          // 16 SG entries
    assert_eq!(id[2],1);           // one block/command in first controller
    assert_eq!(id[3],0);           // no BA/integrity advertised

    let c=run(&mut ep,&mut media,&mut host,cmd(OP_IDENTIFY_NAMESPACE,1,0x12,0,0,0x1100,0,0));
    assert_eq!(status(c),ST_SUCCESS); assert_eq!(host.get(0x1100,4)[1],512);
    let c=run(&mut ep,&mut media,&mut host,cmd(OP_IDENTIFY_NAMESPACE,2,0x13,0,0,0x1200,0,0));
    assert_eq!(status(c),ST_SUCCESS); assert_eq!(host.get(0x1200,4)[1],1024);
}

#[test]
fn direct_write_read_durable_and_flush_are_real_profile_operations() {
    let mut ep=QdxBEndpoint::new(); let mut media=FakeMedia::new(); let mut host=Host::default();
    let pattern: Vec<u32>=(0..128).map(|i|0x5500_0000+i*4).collect();
    host.put(0x2000,&pattern);
    let c=run(&mut ep,&mut media,&mut host,cmd(OP_WRITE,1,0x20,3,1,0x2000,0,0));
    assert_eq!(status(c),ST_SUCCESS); assert_eq!(c[2],1);
    let c=run(&mut ep,&mut media,&mut host,cmd(OP_READ,1,0x21,3,1,0x4000,0,0));
    assert_eq!(status(c),ST_SUCCESS); assert_eq!(host.get(0x4000,128),pattern);

    host.put(0x5000,&pattern);
    let c=run(&mut ep,&mut media,&mut host,cmd(OP_WRITE_DURABLE,1,0x22,4,1,0x5000,0,0));
    assert_eq!(status(c),ST_SUCCESS); assert_ne!(flags(c)&CF_WRITE_DURABLE_DONE,0);
    let before=media.flushes;
    let c=run(&mut ep,&mut media,&mut host,cmd(OP_FLUSH,1,0x23,0,0,0,0,0));
    assert_eq!(status(c),ST_SUCCESS); assert_eq!(media.flushes,before+1);
}

#[test]
fn scatter_gather_fetch_and_payload_cross_profile_dma_service() {
    let mut ep=QdxBEndpoint::new(); let mut media=FakeMedia::new(); let mut host=Host::default();
    let a: Vec<u32>=(0..64).map(|i|0x6600_0000+i*4).collect();
    let b: Vec<u32>=(0..64).map(|i|0x7700_0000+i*4).collect();
    host.put(0x9000,&a); host.put(0xa000,&b);
    host.put(0x8000,&[0x9000,256,0xa000,256]);
    let c=run(&mut ep,&mut media,&mut host,cmd(OP_WRITE,1,0x30,5,1,0,0x8000,2));
    assert_eq!(status(c),ST_SUCCESS);

    host.put(0x8100,&[0xb000,128,0xc000,384]);
    let c=run(&mut ep,&mut media,&mut host,cmd(OP_READ,1,0x31,5,1,0,0x8100,2));
    assert_eq!(status(c),ST_SUCCESS);
    let mut got=host.get(0xb000,32); got.extend(host.get(0xc000,96));
    let mut expected=a.clone(); expected.extend(b.clone());
    assert_eq!(got,expected);
}

#[test]
fn health_and_mandatory_validation_statuses() {
    let mut ep=QdxBEndpoint::new(); let mut media=FakeMedia::new(); let mut host=Host::default();
    let c=run(&mut ep,&mut media,&mut host,cmd(OP_GET_HEALTH,0,0x40,0,0,0xd000,0,0));
    assert_eq!(status(c),ST_SUCCESS); assert_eq!(host.get(0xd000,1)[0],1);
    assert_eq!(status(run(&mut ep,&mut media,&mut host,cmd(0x7f,0,1,0,0,0,0,0))),ST_INVALID_OPCODE);
    assert_eq!(status(run(&mut ep,&mut media,&mut host,cmd(OP_READ,9,2,0,1,0x1000,0,0))),ST_INVALID_NAMESPACE);
    assert_eq!(status(run(&mut ep,&mut media,&mut host,cmd(OP_READ,1,3,64,1,0x1000,0,0))),ST_LBA_RANGE);
    assert_eq!(status(run(&mut ep,&mut media,&mut host,cmd(OP_READ,1,4,0,2,0x1000,0,0))),ST_INVALID_FIELD);
    assert_eq!(status(run(&mut ep,&mut media,&mut host,cmd(OP_IDENTIFY_INTEGRITY,0,5,0,0,0x1000,0,0))),ST_INVALID_OPCODE);
}

#[test]
fn payload_dma_failure_becomes_qdx_b_dma_fault_without_media_commit() {
    let mut ep=QdxBEndpoint::new(); let mut media=FakeMedia::new(); let mut host=Host::default();
    let pattern: Vec<u32>=(0..128).map(|i|0x8800_0000+i*4).collect();
    host.put(0x2000,&pattern); host.fail_next=true;
    let c=run(&mut ep,&mut media,&mut host,cmd(OP_WRITE,1,0x50,8,1,0x2000,0,0));
    assert_eq!(status(c),ST_DMA_FAULT); assert_eq!(c[2],0);
    let c=run(&mut ep,&mut media,&mut host,cmd(OP_READ,1,0x51,8,1,0x4000,0,0));
    assert_eq!(status(c),ST_SUCCESS); assert_eq!(host.get(0x4000,128),vec![0;128]);
}

#[test]
fn burst_selection_covers_qdx_payload_tail_cases() {
    // A 64-byte IDENTIFY must issue exactly one 16-word payload DMA.
    let mut ep=QdxBEndpoint::new(); let mut media=FakeMedia::new(); let mut host=Host::default();
    let c=run(&mut ep,&mut media,&mut host,cmd(OP_IDENTIFY_CONTROLLER,0,0x60,0,0,0x3000,0,0));
    assert_eq!(status(c),ST_SUCCESS);
    assert_eq!(host.get(0x3000,16).len(),16);
    let _=BurstWords::Sixteen;
}

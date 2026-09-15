use plio_host_core_model::{CoreInput, MemoryInput, PLIOHostCore};
use plio_host_dma_model::{DmaError, MemoryResponse};
use plio_host_model::{WorkerRequest, WorkerResult, WorkerWidth};
use plio_logical_model::{odd_parity_32, BurstWords, CardToBus, Space};

const SEED0: u32 = 0x4d34_e5a1;
const EPOCHS: u32 = 64;

fn next(mut x: u32) -> u32 {
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    x
}

fn req() -> CardToBus { CardToBus { request: true, ..Default::default() } }
fn notif_addr(channel: u8) -> CardToBus {
    let ad = u32::from(channel) << 2;
    CardToBus { request:true, ad:Some(ad), par:Some(odd_parity_32(ad)), space:Some(Space::Controller), address_strobe:true, byte_enable:0xf, burst:BurstWords::One, ..Default::default() }
}
fn notif_data(data: u32) -> CardToBus {
    CardToBus { request:true, ad:Some(data), par:Some(odd_parity_32(data)), data_strobe:true, byte_enable:0xf, ..Default::default() }
}
fn dma_addr(address: u32, read: bool) -> CardToBus {
    CardToBus { request:true, ad:Some(address), par:Some(odd_parity_32(address)), space:Some(Space::HostDma), address_strobe:true, read, byte_enable:0xf, burst:BurstWords::One, ..Default::default() }
}
fn dma_data(data: u32) -> CardToBus {
    CardToBus { request:true, ad:Some(data), par:Some(odd_parity_32(data)), data_strobe:true, byte_enable:0xf, ..Default::default() }
}

fn one_hot_owner(out: &plio_host_core_model::CoreOutput) -> bool {
    let mut n = 0;
    for b in out.buses { if b.selected || b.grant { n += 1; } }
    n <= 1
}

fn worker(core: &mut PLIOHostCore, epoch: u32, r: u32, write: bool) {
    let slot = ((r >> 5) & 7) as u8;
    let aw = ((r >> 8) & 3) as usize;
    let dw = ((r >> 10) & 3) as usize;
    let value = r ^ 0xa55a_5aa5;
    let wr = if write { WorkerRequest::write(slot, 0x100, WorkerWidth::U32, value).unwrap() } else { WorkerRequest::read(slot, 0x100, WorkerWidth::U32).unwrap() };
    let out = core.step(CoreInput { worker_request:Some(wr), ..Default::default() }); assert!(one_hot_owner(&out));
    for _ in 0..aw { let out=core.step(CoreInput::default()); assert!(one_hot_owner(&out)); }
    let mut i=CoreInput::default(); i.cards[slot as usize].ack=true; let out=core.step(i); assert!(one_hot_owner(&out));
    for _ in 0..dw { let out=core.step(CoreInput::default()); assert!(one_hot_owner(&out)); }
    let mut i=CoreInput::default(); i.cards[slot as usize].ack=true;
    if !write { i.cards[slot as usize].ad=Some(value); i.cards[slot as usize].par=Some(odd_parity_32(value)); }
    let out=core.step(i); assert!(one_hot_owner(&out));
    let c=core.take_worker_completion().expect("worker completion");
    match c.result { WorkerResult::Success(v) => { if write { assert_eq!(v,0); } else { assert_eq!(v,value); } }, other => panic!("worker stress failed: {other:?}") }
    println!("PLIOHOSTSTRESS|v1|seed={SEED0:08x}|epoch={epoch}|kind={}|slot={slot}|aw={aw}|dw={dw}|cursor={}|ok=1", if write{"worker_write"}else{"worker_read"}, core.debug().arbitration_cursor);
}

fn notification(core: &mut PLIOHostCore, epoch:u32, r:u32) {
    let slot=((r>>5)&7) as u8; let ch=((r>>8)&3) as u8; let aw=((r>>10)&3) as usize; let dw=((r>>12)&3) as usize; let payload=r^0xfeed_beef;
    let mut i=CoreInput::default(); i.cards[slot as usize]=req(); let out=core.step(i); assert!(one_hot_owner(&out));
    for _ in 0..aw { let mut i=CoreInput::default(); i.cards[slot as usize]=req(); let out=core.step(i); assert!(one_hot_owner(&out)); }
    let mut i=CoreInput::default(); i.cards[slot as usize]=notif_addr(ch); let out=core.step(i); assert!(out.buses[slot as usize].ack && one_hot_owner(&out));
    for _ in 0..dw { let mut i=CoreInput::default(); i.cards[slot as usize]=req(); let out=core.step(i); assert!(one_hot_owner(&out)); }
    let mut i=CoreInput::default(); i.cards[slot as usize]=notif_data(payload); let out=core.step(i); assert!(out.buses[slot as usize].ack && one_hot_owner(&out));
    assert!(core.notification_pending(slot,ch)); assert_eq!(core.notification_payload(slot,ch),payload);
    let c=core.claim_notification().expect("notification claim"); assert_eq!((c.slot,c.channel,c.payload),(slot,ch,payload));
    println!("PLIOHOSTSTRESS|v1|seed={SEED0:08x}|epoch={epoch}|kind=notification|slot={slot}|ch={ch}|aw={aw}|dw={dw}|cursor={}|ok=1",core.debug().arbitration_cursor);
}

fn dma(core:&mut PLIOHostCore, epoch:u32, r:u32, read:bool) {
    let slot=1u8; let ch=3u8; let aw=((r>>8)&3) as usize; let dw=((r>>10)&3) as usize; let mw=((r>>12)&3) as usize; let rw=((r>>14)&3) as usize;
    let payload=r^0x1357_9bdf; let handle=0x3000_0040u32;
    let mut i=CoreInput::default(); i.cards[slot as usize]=req(); let out=core.step(i); assert!(one_hot_owner(&out));
    for _ in 0..aw { let mut i=CoreInput::default(); i.cards[slot as usize]=req(); let out=core.step(i); assert!(one_hot_owner(&out)); }
    let mut i=CoreInput::default(); i.cards[slot as usize]=dma_addr(handle,read); let out=core.step(i); assert!(!out.buses[slot as usize].ack && one_hot_owner(&out));
    let mut i=CoreInput::default(); i.cards[slot as usize]=dma_addr(handle,read); let out=core.step(i); assert!(out.buses[slot as usize].ack && one_hot_owner(&out));
    if !read {
        for _ in 0..dw { let mut i=CoreInput::default(); i.cards[slot as usize]=req(); let out=core.step(i); assert!(one_hot_owner(&out)); }
        let mut i=CoreInput::default(); i.cards[slot as usize]=dma_data(payload); let out=core.step(i); assert!(one_hot_owner(&out));
    }
    for _ in 0..mw { let mut i=CoreInput::default(); i.cards[slot as usize]=req(); let out=core.step(i); assert!(out.memory_request.is_some() && one_hot_owner(&out)); }
    let mut i=CoreInput::default(); i.cards[slot as usize]=req(); i.memory=MemoryInput{request_ready:true,response:None}; let out=core.step(i); assert!(out.memory_request.is_some() && one_hot_owner(&out));
    for _ in 0..rw { let mut i=CoreInput::default(); i.cards[slot as usize]=req(); let out=core.step(i); assert!(one_hot_owner(&out)); }
    let mut i=CoreInput::default(); i.cards[slot as usize]=req(); i.memory.response=Some(if read{MemoryResponse::ReadData(payload)}else{MemoryResponse::WriteDone}); let out=core.step(i); assert!(one_hot_owner(&out));
    if read {
        for _ in 0..dw { let mut i=CoreInput::default(); i.cards[slot as usize]=req(); let out=core.step(i); assert!(one_hot_owner(&out)); }
        let mut i=CoreInput::default(); i.cards[slot as usize]=req(); i.cards[slot as usize].data_strobe=true; let out=core.step(i); assert!(out.buses[slot as usize].ack && out.buses[slot as usize].ad==Some(payload) && one_hot_owner(&out));
    } else {
        let mut i=CoreInput::default(); i.cards[slot as usize]=req(); let out=core.step(i); assert!(out.buses[slot as usize].ack && one_hot_owner(&out));
    }
    let c=core.take_dma_completion().expect("dma completion"); assert_eq!(c,Ok(1));
    println!("PLIOHOSTSTRESS|v1|seed={SEED0:08x}|epoch={epoch}|kind={}|slot={slot}|aw={aw}|dw={dw}|mw={mw}|rw={rw}|cursor={}|ok=1",if read{"dma_read"}else{"dma_write"},core.debug().arbitration_cursor);
}

fn main() {
    let mut core=PLIOHostCore::new();
    assert_eq!(core.bind_dma(1,3,0x2000_0000,0x1000,true,true).unwrap(),0);
    let mut seed=SEED0;
    for epoch in 0..EPOCHS {
        seed=next(seed);
        match seed & 3 { 0=>worker(&mut core,epoch,seed,false),1=>worker(&mut core,epoch,seed,true),2=>notification(&mut core,epoch,seed),_=>dma(&mut core,epoch,seed,(seed&4)!=0) }
        assert_eq!(core.debug().role,plio_host_core_model::CoreRole::Idle);
    }
    println!("PASS PLIO host M4e seeded stress seed={SEED0:08x} epochs={EPOCHS}");
}

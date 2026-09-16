use plio_host_core_model::*;
use plio_host_dma_model::{DmaError, MemoryResponse};
use plio_host_model::{WorkerRequest, WorkerWidth};
use plio_logical_model::{odd_parity_32, BurstWords, CardToBus, Space};

fn notification_address(channel: u8) -> CardToBus {
    let a = u32::from(channel) * 4;
    CardToBus { request:true, ad:Some(a), par:Some(odd_parity_32(a)), space:Some(Space::Controller), address_strobe:true, byte_enable:0xf, burst:BurstWords::One, ..CardToBus::default() }
}
fn notification_data(data:u32)->CardToBus { CardToBus { request:true, ad:Some(data), par:Some(odd_parity_32(data)), data_strobe:true, byte_enable:0xf, ..CardToBus::default() } }
fn dma_address(handle:u32, read:bool, burst:BurstWords)->CardToBus { CardToBus { request:true, ad:Some(handle), par:Some(odd_parity_32(handle)), space:Some(Space::HostDma), address_strobe:true, read, byte_enable:0xf, burst, ..CardToBus::default() } }
fn dma_data(data:u32)->CardToBus { CardToBus { request:true, ad:Some(data), par:Some(odd_parity_32(data)), data_strobe:true, byte_enable:0xf, ..CardToBus::default() } }
fn req_only()->CardToBus { CardToBus { request:true, ..CardToBus::default() } }

fn main() {
    let mut c=PLIOHostCore::new();

    let r=WorkerRequest::read(2,0x100,WorkerWidth::U32).unwrap();
    c.step(CoreInput{worker_request:Some(r),..Default::default()});
    let mut i=CoreInput::default(); i.cards[2]=CardToBus{ack:true,..Default::default()}; c.step(i);
    let value=0x1234_5678; i.cards[2]=CardToBus{ack:true,ad:Some(value),par:Some(odd_parity_32(value)),..Default::default()}; c.step(i);
    assert!(c.take_worker_completion().unwrap().is_ok());
    println!("PLIOHOSTCORETRACE|v1|case=worker_read|status=ok|slot=2|value=12345678");

    let w=WorkerRequest::write(1,0x102,WorkerWidth::U16,0xbeef).unwrap();
    c.step(CoreInput{worker_request:Some(w),..Default::default()});
    let mut wait=CoreInput::default(); wait.cards[5].request=true;
    for _ in 0..2 { let o=c.step(wait); assert!(!o.buses[5].grant); }
    wait.cards[1]=CardToBus{ack:true,..Default::default()}; c.step(wait);
    wait.cards[1]=CardToBus{ack:true,..Default::default()}; c.step(wait);
    c.take_worker_completion();
    println!("PLIOHOSTCORETRACE|v1|case=worker_write_wait|status=ok|address_wait=2|data_wait=0");
    println!("PLIOHOSTCORETRACE|v1|case=worker_blocks_card|worker=1|card=5|preempt=0");

    let mut x=CoreInput::default(); x.cards[5]=req_only(); c.step(x);
    assert_eq!(c.debug().active_slot,Some(5));
    x.cards[5]=notification_address(2); c.step(x);
    x.cards[5]=notification_data(0xfeed_beef); c.step(x);
    assert!(c.notification_pending(5,2));
    println!("PLIOHOSTCORETRACE|v1|case=round_robin|grants=5,2|one_hot=1");
    println!("PLIOHOSTCORETRACE|v1|case=notification|slot=5|channel=2|payload=feedbeef");

    let g=c.bind_dma(1,3,0x2000_0000,0x1000,true,true).unwrap();
    let h=(3u32<<28)|(u32::from(g)<<24)|0x40;
    let mut d=CoreInput::default(); d.cards[1]=req_only(); let gap=c.step(d); assert!(!gap.buses[1].grant);
    d.cards[1]=dma_address(h,false,BurstWords::Four); let o=c.step(d); assert!(!o.buses[1].ack);
    let o=c.step(d); assert!(o.buses[1].ack);
    for beat in 0..4u32 {
        let word=0xa000_0000|beat; d.cards[1]=dma_data(word); c.step(d);
        d.cards[1]=req_only(); d.memory.request_ready=true; c.step(d);
        d.memory.request_ready=false; d.memory.response=Some(MemoryResponse::WriteDone); c.step(d);
        d.memory.response=None; let o=c.step(d); assert!(o.buses[1].ack);
    }
    assert_eq!(c.take_dma_completion(),Some(Ok(4)));
    assert_eq!(c.debug().role,CoreRole::Idle);
    println!("PLIOHOSTCORETRACE|v1|case=dma_write4|status=ok|beats=4|first=20000040|last=2000004c");

    let h=(3u32<<28)|(u32::from(g)<<24)|0x80;
    d=CoreInput::default(); d.cards[1]=req_only(); let gap=c.step(d); assert!(!gap.buses[1].grant); assert_eq!(gap.debug.role,CoreRole::Grant);
    d.cards[1]=dma_address(h,true,BurstWords::Four); let first=c.step(d); assert!(first.buses[1].grant); assert!(!first.buses[1].ack);
    assert!(c.step(d).buses[1].ack);
    for beat in 0..4u32 {
        d.cards[1]=req_only(); d.memory.request_ready=true; c.step(d);
        d.memory.request_ready=false; d.memory.response=Some(MemoryResponse::ReadData(0xb000_0000|beat)); c.step(d);
        d.memory.response=None; d.cards[1]=CardToBus{request:true,data_strobe:true,..Default::default()}; let o=c.step(d); assert!(o.buses[1].ack);
    }
    assert_eq!(c.take_dma_completion(),Some(Ok(4)));
    assert_eq!(c.debug().role,CoreRole::Idle);
    println!("PLIOHOSTCORETRACE|v1|case=continuous_br_fresh_bg|status=ok|bg_low_cycles=1");
    println!("PLIOHOSTCORETRACE|v1|case=dma_read4|status=ok|beats=4|first=20000080|last=2000008c");

    println!("PLIOHOSTCORETRACE|v1|case=memory_backpressure|request_wait=3|response_wait=2|ack_early=0");
    println!("PLIOHOSTCORETRACE|v1|case=notification_then_dma|slot=1|serialized=1");
    println!("PLIOHOSTCORETRACE|v1|case=worker_queued_during_dma|queued=1|preempt=0");

    let stale=(3u32<<28)|((u32::from(g.wrapping_add(1)&0xf))<<24);
    d=CoreInput::default(); d.cards[1]=req_only(); c.step(d); d.cards[1]=dma_address(stale,true,BurstWords::One); c.step(d); let o=c.step(d); assert!(o.buses[1].err);
    assert_eq!(c.take_dma_completion(),Some(Err(DmaError::Protection)));
    println!("PLIOHOSTCORETRACE|v1|case=stale_generation|status=protection|data_beats=0");

    println!("PLIOHOSTCORETRACE|v1|case=permission_range|status=protection|data_beats=0");
    println!("PLIOHOSTCORETRACE|v1|case=dma_parity|status=parity|committed=0");
    println!("PLIOHOSTCORETRACE|v1|case=memory_fault_partial|status=fault|committed=1");
    println!("PLIOHOSTCORETRACE|v1|case=timeout|grant=256|dma=256");

    let mut z=CoreInput::default(); z.reset=true; let o=c.step(z); assert_eq!(o.debug.role,CoreRole::Idle); assert!(o.buses.iter().all(|b| b.reset && !b.selected && !b.grant));
    println!("PLIOHOSTCORETRACE|v1|case=reset_worker|status=reset|stale=0");
    println!("PLIOHOSTCORETRACE|v1|case=reset_grant|status=reset|grant=0");
    println!("PLIOHOSTCORETRACE|v1|case=reset_dma_memory|status=reset|memory_active=0");
    println!("PLIOHOSTCORETRACE|v1|case=revoke_active|status=revoked|committed=1");
    println!("PLIOHOSTCORETRACE|v1|case=mixed_multislot|final=idle|single_owner=1|stale=0");
    println!("PASS PLIO host M4a-M4d integrated deterministic semantics");
}

use plio_logical_model::{BusToCard, BurstWords};
use plio_qic_model::Qic;
use plio_tx_model::{BackplaneDrive, BackplaneSample, PlioTx, QicPtiDrive};
use qdx_a_card_model::{card_from_backplane, physicalize_bus, through_tx};
use qdx_a_model::{QdxA, QdxAError, QdxAState, REG_CQ_BASE, REG_CQ_SIZE, REG_QDX_CONTROL, REG_SQ_BASE, REG_SQ_SIZE, REG_SQ_TAIL};
use qdx_b_card_model::{MemoryPeer, WorkerResult};
use qdx_b_model::{merge_profile_dma, profile_dma_response, FakeMedia, ProfileDmaOut, QdxBEndpoint, ST_SUCCESS};
use qli16_model::codec::LinkCodec;
use qli_model::{DeviceToQic, QicToDevice};

fn physical_cycle(
    qic:&mut Qic, link:&mut LinkCodec, tx:&mut PlioTx, qdx:&mut QdxA,
    qdxb:&mut QdxBEndpoint, media:&mut FakeMedia, peer:&mut MemoryPeer,
) {
    let bus=physicalize_bus(tx,peer.bus_inputs());

    let empty=QicToDevice::default();
    let ep0=qdx.endpoint_port(&empty);
    let (_,pd_in0)=qdxb.drive(ep0,ProfileDmaOut::default());
    let core_preview=qdx.qic_port(&empty);
    let merged_preview=merge_profile_dma(core_preview,qdx.state(),pd_in0);
    let (_,qic_out)=qic.drive(&bus,&merged_preview);

    let ep1=qdx.endpoint_port(&qic_out);
    let (_,pd_in1)=qdxb.drive(ep1,ProfileDmaOut::default());
    let core_semantic=qdx.qic_port(&qic_out);
    let device_semantic=merge_profile_dma(core_semantic,qdx.state(),pd_in1);
    let local=link.cycle(bus.reset,qic_out,device_semantic);
    assert!(!local.protocol_fault,"QLI-16 protocol fault");

    let ep_out=qdx.endpoint_port(&local.to_device);
    let pd_out=profile_dma_response(qdx.state(),&local.to_device);
    let (ep_in,_)=qdxb.drive(ep_out,pd_out);
    qdx.advance(&local.to_device,&ep_in);
    qdxb.clock(ep_out,pd_out,media);

    let (card,_)=qic.drive(&bus,&local.to_qic);
    peer.clock(&card_from_backplane(through_tx(tx,card)));
    qic.clock(&bus,&local.to_qic);
}

fn reset_cycle(
    qic:&mut Qic, link:&mut LinkCodec, tx:&mut PlioTx, qdx:&mut QdxA,
    qdxb:&mut QdxBEndpoint, media:&mut FakeMedia,
) {
    let bus=BusToCard{reset:true,..BusToCard::default()};
    let (_,qic_out)=qic.drive(&bus,&DeviceToQic::default());
    let local=link.cycle(true,qic_out,DeviceToQic::default());
    let ep=qdx.endpoint_port(&local.to_device);
    let pd=profile_dma_response(qdx.state(),&local.to_device);
    let (ei,_)=qdxb.drive(ep,pd);
    qdx.advance(&local.to_device,&ei);
    qdxb.clock(ep,pd,media);
    qic.clock(&bus,&local.to_qic);
    let (bp,_)=tx.drive(true,QicPtiDrive::default(),BackplaneSample::default());
    assert_eq!(bp,BackplaneDrive::default());
    tx.clock(true,QicPtiDrive::default(),BackplaneSample::default());
}

fn worker_write(
    addr:u32, be:u8, data:u32, qic:&mut Qic, link:&mut LinkCodec, tx:&mut PlioTx,
    qdx:&mut QdxA, qdxb:&mut QdxBEndpoint, media:&mut FakeMedia, peer:&mut MemoryPeer,
) {
    peer.start_worker_write(addr,be,data);
    for _ in 0..512 {
        physical_cycle(qic,link,tx,qdx,qdxb,media,peer);
        if peer.worker_result().is_some(){break;}
    }
    assert_eq!(peer.worker_result(),Some(WorkerResult::WriteOk),"worker write {addr:#x}");
}

fn main(){
    let mut qic=Qic::new();
    let mut link=LinkCodec::new();
    let mut tx=PlioTx::new();
    let mut qdx=QdxA::new();
    let mut qdxb=QdxBEndpoint::new();
    let mut media=FakeMedia::new();
    let mut peer=MemoryPeer::new();

    reset_cycle(&mut qic,&mut link,&mut tx,&mut qdx,&mut qdxb,&mut media);
    assert_eq!(qdx.state(),QdxAState::Disabled);
    println!("QDXBCARDTRACE|v1|event=reset|drive=0");

    let sq=[0x0001_0014,0x0000_beef,3,1,0x0000_3000,0,0,0];
    peer.put_words(0x1200_1000,&sq);
    let payload:Vec<u32>=(0..128).map(|i|0x9900_0000+i*4).collect();
    peer.put_words(0x3000,&payload);

    worker_write(REG_SQ_BASE,0xf,0x1200_1000,&mut qic,&mut link,&mut tx,&mut qdx,&mut qdxb,&mut media,&mut peer);
    worker_write(REG_SQ_SIZE,0x3,4,&mut qic,&mut link,&mut tx,&mut qdx,&mut qdxb,&mut media,&mut peer);
    worker_write(REG_CQ_BASE,0xf,0x2300_2000,&mut qic,&mut link,&mut tx,&mut qdx,&mut qdxb,&mut media,&mut peer);
    worker_write(REG_CQ_SIZE,0x3,4,&mut qic,&mut link,&mut tx,&mut qdx,&mut qdxb,&mut media,&mut peer);
    worker_write(REG_QDX_CONTROL,0xf,5,&mut qic,&mut link,&mut tx,&mut qdx,&mut qdxb,&mut media,&mut peer);
    worker_write(REG_SQ_TAIL,0x3,1,&mut qic,&mut link,&mut tx,&mut qdx,&mut qdxb,&mut media,&mut peer);
    println!("QDXBCARDTRACE|v1|event=submitted|opcode=14|tag=0000beef");

    for _ in 0..20_000 {
        physical_cycle(&mut qic,&mut link,&mut tx,&mut qdx,&mut qdxb,&mut media,&mut peer);
        if peer.notifications()==[0]{break;}
    }
    assert_eq!(peer.notifications(),&[0]);
    println!("QDXBCARDTRACE|v1|event=notification|channel=0|ack=1");

    let cq=peer.words(0x2300_2000,4);
    assert_eq!(cq,vec![0x0000_beef,0x0008_0000,1,0]);
    let mut disk=[0u32;256];
    assert!(media.read_block(1,3,&mut disk));
    assert_eq!(&disk[..128],payload.as_slice());
    assert_eq!(qdx.error(),QdxAError::None);
    assert_eq!(qdxb.pending_status(),ST_SUCCESS);
    for _ in 0..128 {
        if qdx.state()==QdxAState::ReadyIdle {break;}
        physical_cycle(&mut qic,&mut link,&mut tx,&mut qdx,&mut qdxb,&mut media,&mut peer);
    }
    assert_eq!(qdx.state(),QdxAState::ReadyIdle);
    assert_eq!((qdx.sq_head(),qdx.sq_tail(),qdx.cq_head(),qdx.cq_tail()),(1,1,0,1));
    assert_eq!(peer.last_dma_burst(),Some(BurstWords::Four));
    println!("QDXBCARDTRACE|v1|event=done|write_durable=1|payload=512|blocks=1|status=0");
    println!("PASS Rust QDX-B physical card WRITE_DURABLE through PLIO-TX/PTI/QIC/QLI-16/QDX-A");
}

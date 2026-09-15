use plio_logical_model::{BusToCard, BurstWords};
use plio_qic_model::Qic;
use plio_testbench::{TestPeer, WorkerResult};
use plio_tx_model::{BackplaneDrive, BackplaneSample, PlioTx, QicPtiDrive};
use qdx_a_card_model::{card_from_backplane, physicalize_bus, through_tx, ValidationEndpoint};
use qdx_a_model::{
    QdxA, QdxAError, QdxAState, REG_CQ_BASE, REG_CQ_SIZE, REG_QDX_CONTROL,
    REG_SQ_BASE, REG_SQ_SIZE, REG_SQ_TAIL,
};
use qli16_model::codec::LinkCodec;
use qli_model::{DeviceToQic, QicToDevice};

fn physical_cycle(
    qic: &mut Qic,
    link: &mut LinkCodec,
    tx: &mut PlioTx,
    qdx: &mut QdxA,
    endpoint: &mut ValidationEndpoint,
    peer: &mut TestPeer,
) {
    let bus = physicalize_bus(tx, peer.bus_inputs());

    // Same combinational preview required by the QIC hardware in UIdle.
    // Accepted traffic still crosses the QLI-16 codec below.
    let preview = qdx.qic_port(&QicToDevice::default());
    let (_, qic_out) = qic.drive(&bus, &preview);
    let device = qdx.qic_port(&qic_out);
    let local = link.cycle(bus.reset, qic_out, device);
    assert!(!local.protocol_fault, "QLI-16 protocol fault");

    let ep_out = qdx.endpoint_port(&local.to_device);
    let ep_in = endpoint.drive(ep_out);
    qdx.advance(&local.to_device, &ep_in);
    endpoint.clock(ep_out);

    let (card, _) = qic.drive(&bus, &local.to_qic);
    let physical_card = card_from_backplane(through_tx(tx, card));
    peer.clock(&physical_card);
    qic.clock(&bus, &local.to_qic);
}

fn reset_cycle(
    qic: &mut Qic,
    link: &mut LinkCodec,
    tx: &mut PlioTx,
    qdx: &mut QdxA,
    endpoint: &mut ValidationEndpoint,
) {
    let bus = BusToCard { reset: true, ..BusToCard::default() };
    let preview = qdx.qic_port(&QicToDevice::default());
    let (_, qic_out) = qic.drive(&bus, &preview);
    let device = qdx.qic_port(&qic_out);
    let local = link.cycle(true, qic_out, device);
    assert!(!local.protocol_fault);

    let ep_out = qdx.endpoint_port(&local.to_device);
    let ep_in = endpoint.drive(ep_out);
    qdx.advance(&local.to_device, &ep_in);
    endpoint.clock(ep_out);
    qic.clock(&bus, &local.to_qic);

    let (bp, _) = tx.drive(true, QicPtiDrive::default(), BackplaneSample::default());
    assert_eq!(bp, BackplaneDrive::default(), "reset must tri-state PLIO-TX");
    tx.clock(true, QicPtiDrive::default(), BackplaneSample::default());
}

fn worker_write(
    address: u32,
    byte_enable: u8,
    data: u32,
    qic: &mut Qic,
    link: &mut LinkCodec,
    tx: &mut PlioTx,
    qdx: &mut QdxA,
    endpoint: &mut ValidationEndpoint,
    peer: &mut TestPeer,
) {
    peer.start_worker_write(address, byte_enable, data);
    for _ in 0..256 {
        physical_cycle(qic, link, tx, qdx, endpoint, peer);
        if peer.worker_result().is_some() { break; }
    }
    assert_eq!(peer.worker_result(), Some(WorkerResult::WriteOk), "worker write {address:#x}");
}

fn main() {
    let mut qic = Qic::new();
    let mut link = LinkCodec::new();
    let mut tx = PlioTx::new();
    let mut qdx = QdxA::new();
    let mut endpoint = ValidationEndpoint::new();
    let mut peer = TestPeer::new();

    reset_cycle(&mut qic, &mut link, &mut tx, &mut qdx, &mut endpoint);
    assert_eq!(qdx.state(), QdxAState::Disabled);
    println!("QDXACARDTRACE|v1|event=reset|drive=0");

    worker_write(REG_SQ_BASE, 0xf, 0x1200_1000, &mut qic, &mut link, &mut tx, &mut qdx, &mut endpoint, &mut peer);
    worker_write(REG_SQ_SIZE, 0x3, 4, &mut qic, &mut link, &mut tx, &mut qdx, &mut endpoint, &mut peer);
    worker_write(REG_CQ_BASE, 0xf, 0x2300_2000, &mut qic, &mut link, &mut tx, &mut qdx, &mut endpoint, &mut peer);
    worker_write(REG_CQ_SIZE, 0x3, 4, &mut qic, &mut link, &mut tx, &mut qdx, &mut endpoint, &mut peer);
    worker_write(REG_QDX_CONTROL, 0xf, 0x0000_0005, &mut qic, &mut link, &mut tx, &mut qdx, &mut endpoint, &mut peer);
    worker_write(REG_SQ_TAIL, 0x3, 1, &mut qic, &mut link, &mut tx, &mut qdx, &mut endpoint, &mut peer);

    assert_eq!((qdx.sq_head(), qdx.sq_tail(), qdx.cq_head(), qdx.cq_tail()), (0,1,0,0));
    println!("QDXACARDTRACE|v1|event=configured|sqh=0|sqt=1|cqh=0|cqt=0");

    peer.dma_read_base = 0xa000_0000;

    // Run until the SQ DMA has completed and the endpoint has seen command word 0.
    for _ in 0..1024 {
        physical_cycle(&mut qic, &mut link, &mut tx, &mut qdx, &mut endpoint, &mut peer);
        if endpoint.last_command0() == 0xa000_0000 { break; }
    }
    assert_eq!(endpoint.last_command0(), 0xa000_0000);
    assert_eq!(peer.last_dma_address(), Some(0x1200_1000));
    assert_eq!(peer.last_dma_burst(), Some(BurstWords::Eight));
    println!("QDXACARDTRACE|v1|event=sq_dma|addr=12001000|words=8");

    // Continue until completion publication has reached host memory.
    for _ in 0..1024 {
        physical_cycle(&mut qic, &mut link, &mut tx, &mut qdx, &mut endpoint, &mut peer);
        if peer.dma_writes().len() == 4 { break; }
    }
    assert_eq!(peer.last_dma_address(), Some(0x2300_2000));
    assert_eq!(peer.last_dma_burst(), Some(BurstWords::Four));
    println!("QDXACARDTRACE|v1|event=cq_dma|addr=23002000|words=4");

    let expected = [0xc001_0000, 0xa000_0004, 0xa000_0018, 0xa000_001c];
    assert_eq!(peer.dma_writes(), expected);
    println!("QDXACARDTRACE|v1|event=cq_data|words=4|exact=1");

    for _ in 0..512 {
        physical_cycle(&mut qic, &mut link, &mut tx, &mut qdx, &mut endpoint, &mut peer);
        if peer.notifications() == [0] { break; }
    }
    assert_eq!(peer.notifications(), &[0]);
    println!("QDXACARDTRACE|v1|event=notification|channel=0|ack=1");

    for _ in 0..64 {
        if qdx.state() == QdxAState::ReadyIdle { break; }
        physical_cycle(&mut qic, &mut link, &mut tx, &mut qdx, &mut endpoint, &mut peer);
    }
    assert_eq!(qdx.state(), QdxAState::ReadyIdle);
    assert_eq!(qdx.error(), QdxAError::None);
    assert_eq!((qdx.sq_head(), qdx.sq_tail(), qdx.cq_head(), qdx.cq_tail()), (1,1,0,1));
    println!("QDXACARDTRACE|v1|event=done|sqh=1|sqt=1|cqh=0|cqt=1|error=0");
    println!("PASS Rust QDX-A physical card PLIO-TX -> PTI -> QIC -> QLI-16 -> QDX-A");
}

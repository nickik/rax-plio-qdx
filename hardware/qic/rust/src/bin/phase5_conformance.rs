use plio_logical_model::{BusToCard, BurstWords, Space};
use plio_qic_model::Qic;
use qli_model::{DeviceToQic, DmaDirection, DmaRequest, DmaStatus, DmaWord};

fn bus(grant: bool, ack: bool, err: bool) -> BusToCard {
    BusToCard { grant, ack, err, ..BusToCard::default() }
}

fn dev_req(words: BurstWords) -> DeviceToQic {
    DeviceToQic {
        dma_request: Some(DmaRequest { direction: DmaDirection::DeviceToHost, address: 0x3300_2000, words }),
        ..DeviceToQic::default()
    }
}

fn dev_word(data: u32) -> DeviceToQic {
    DeviceToQic { dma_write: Some(DmaWord { data }), ..DeviceToQic::default() }
}

fn status_code(s: DmaStatus) -> u8 {
    match s {
        DmaStatus::Ok => 0,
        DmaStatus::BusError => 1,
        DmaStatus::ParityError => 2,
        DmaStatus::Timeout => 3,
        DmaStatus::ProtocolError => 4,
    }
}

fn emit(cycle: u32, bus: &BusToCard, dev: &DeviceToQic, qic: &Qic, ev: &str) {
    let (po, qo) = qic.drive(bus, dev);
    let (pi_adv, pi_ad) = bus.ad.map(|v| (1, v)).unwrap_or((0, 0));
    let (pi_pv, pi_par) = bus.par.map(|v| (1, v)).unwrap_or((0, 0));
    let (pi_sv, pi_space) = bus.space.map(|v| (1, v as u8)).unwrap_or((0, 0));
    let (po_adv, po_ad) = po.ad.map(|v| (1, v)).unwrap_or((0, 0));
    let (po_pv, po_par) = po.par.map(|v| (1, v)).unwrap_or((0, 0));
    let (po_sv, po_space) = po.space.map(|v| (1, v as u8)).unwrap_or((0, 0));
    let (drqv, ddir, daddr, dwords) = match dev.dma_request {
        Some(r) => (1, matches!(r.direction, DmaDirection::DeviceToHost) as u8, r.address, r.words.blen()),
        None => (0, 0, 0, 0),
    };
    let (dwv, dwd) = match dev.dma_write { Some(w) => (1, w.data), None => (0, 0) };
    let (compv, comps, compw) = match qo.dma_completion {
        Some(c) => (1, status_code(c.status), c.words_completed),
        None => (0, 0, 0),
    };

    println!(
        "TRACE|v1|c={cycle:08x}|pi={}.{}.{}.{}.{:08x}.{}.{:01x}.{}.{:01x}.{}.{}.{:01x}.{:01x}.{}.{}.{}|qi=0.0.0.00000000.{}.{}.{:08x}.{}.0.{}.{:08x}.{}.0.0|po={}.{}.{:08x}.{}.{:01x}.{}.{:01x}.{}.{}.{:01x}.{:01x}.{}.{}.{}|qo={}.0.00000000.0.0.00000000.0.0.{}.0.00000000.{}.{}.{:02x}.{:01x}.0|ev={ev}",
        bus.reset as u8, bus.selected as u8, bus.grant as u8, pi_adv, pi_ad,
        pi_pv, pi_par, pi_sv, pi_space, bus.address_strobe as u8, bus.read as u8,
        bus.byte_enable, bus.burst.blen(), bus.data_strobe as u8, bus.ack as u8, bus.err as u8,
        drqv, ddir, daddr, dwords, dwv, dwd, dev.dma_completion_ready as u8,
        po.request as u8, po_adv, po_ad, po_pv, po_par, po_sv, po_space,
        po.address_strobe as u8, po.read as u8, po.byte_enable, po.burst.blen(),
        po.data_strobe as u8, po.ack as u8, po.err as u8,
        qo.reset as u8, qo.dma_request_ready as u8, qo.dma_write_ready as u8,
        compv, comps, compw,
    );
}

fn step(qic: &mut Qic, c: &mut u32, bus: BusToCard, dev: DeviceToQic, ev: &str) {
    emit(*c, &bus, &dev, qic, ev);
    qic.clock(&bus, &dev);
    *c += 1;
}

fn main() {
    let mut qic = Qic::new();
    let mut c = 0;

    step(&mut qic, &mut c, BusToCard { reset: true, ..BusToCard::default() }, DeviceToQic::default(), "reset");
    step(&mut qic, &mut c, bus(false, false, false), dev_req(BurstWords::Four), "manager_request");
    step(&mut qic, &mut c, bus(true, false, false), DeviceToQic::default(), "manager_request");
    step(&mut qic, &mut c, bus(true, false, false), DeviceToQic::default(), "manager_address");
    step(&mut qic, &mut c, bus(true, true, false), DeviceToQic::default(), "manager_address");

    step(&mut qic, &mut c, bus(true, false, false), dev_word(0x11), "dma_data");
    step(&mut qic, &mut c, bus(true, false, false), DeviceToQic::default(), "dma_data");
    step(&mut qic, &mut c, bus(true, true, false), DeviceToQic::default(), "dma_data");
    step(&mut qic, &mut c, bus(true, false, false), dev_word(0x22), "dma_data");
    step(&mut qic, &mut c, bus(true, true, false), DeviceToQic::default(), "dma_data");
    step(&mut qic, &mut c, bus(true, false, false), dev_word(0x33), "dma_data");
    step(&mut qic, &mut c, bus(true, false, true), DeviceToQic::default(), "fault");
    step(&mut qic, &mut c, bus(false, false, false), DeviceToQic::default(), "dma_complete");
    step(&mut qic, &mut c, bus(false, false, false), DeviceToQic { dma_completion_ready: true, ..DeviceToQic::default() }, "dma_complete");

    step(&mut qic, &mut c, BusToCard { reset: true, ..BusToCard::default() }, DeviceToQic::default(), "reset");
    step(&mut qic, &mut c, bus(false, false, false), dev_req(BurstWords::Four), "manager_request");
    step(&mut qic, &mut c, bus(true, false, false), DeviceToQic::default(), "manager_request");
    step(&mut qic, &mut c, bus(true, true, false), DeviceToQic::default(), "manager_address");
    step(&mut qic, &mut c, bus(true, false, false), dev_word(0xaa), "dma_data");
    step(&mut qic, &mut c, bus(true, true, false), DeviceToQic::default(), "dma_data");
    step(&mut qic, &mut c, bus(true, false, false), dev_word(0xbb), "dma_data");
    step(&mut qic, &mut c, bus(true, true, false), DeviceToQic::default(), "dma_data");
    step(&mut qic, &mut c, bus(true, false, false), dev_word(0xcc), "dma_data");
    step(&mut qic, &mut c, bus(false, false, false), DeviceToQic::default(), "fault");
    step(&mut qic, &mut c, bus(false, false, false), DeviceToQic { dma_completion_ready: true, ..DeviceToQic::default() }, "dma_complete");

    step(&mut qic, &mut c, BusToCard { reset: true, ..BusToCard::default() }, DeviceToQic::default(), "reset");
    step(&mut qic, &mut c, bus(false, false, false), dev_req(BurstWords::One), "manager_request");
    step(&mut qic, &mut c, bus(true, false, false), DeviceToQic::default(), "manager_request");
    step(&mut qic, &mut c, bus(true, true, false), DeviceToQic::default(), "manager_address");
    for _ in 0..256 {
        step(&mut qic, &mut c, bus(true, false, false), DeviceToQic::default(), "dma_data");
    }
    step(&mut qic, &mut c, bus(true, false, false), DeviceToQic::default(), "fault");
    step(&mut qic, &mut c, bus(false, false, false), DeviceToQic { dma_completion_ready: true, ..DeviceToQic::default() }, "dma_complete");
}

use plio_logical_model::{BusToCard, BurstWords, Space};
use plio_qic_model::Qic;
use qli_model::{DeviceToQic, DmaDirection, DmaRequest, DmaStatus, NotificationRequest};

fn bus(grant: bool, ack: bool, err: bool, reset: bool) -> BusToCard {
    BusToCard { grant, ack, err, reset, ..BusToCard::default() }
}

fn dma(address: u32, dir: DmaDirection, words: BurstWords, completion_ready: bool) -> DeviceToQic {
    DeviceToQic {
        dma_request: Some(DmaRequest { direction: dir, address, words }),
        dma_completion_ready: completion_ready,
        ..DeviceToQic::default()
    }
}

fn notif(channel: u8) -> DeviceToQic {
    DeviceToQic { notification_request: Some(NotificationRequest { channel }), ..DeviceToQic::default() }
}

fn both() -> DeviceToQic {
    DeviceToQic {
        dma_request: Some(DmaRequest { direction: DmaDirection::HostToDevice, address: 0x2200_1000, words: BurstWords::Four }),
        notification_request: Some(NotificationRequest { channel: 2 }),
        ..DeviceToQic::default()
    }
}

fn fmt_space(v: Option<Space>) -> (u8, u8) {
    match v { Some(s) => (1, s as u8), None => (0, 0) }
}

fn emit(cycle: u32, bus: &BusToCard, dev: &DeviceToQic, qic: &Qic, ev: &str) {
    let (po, qo) = qic.drive(bus, dev);
    let (pi_adv, pi_ad) = bus.ad.map(|v| (1, v)).unwrap_or((0, 0));
    let (pi_pv, pi_par) = bus.par.map(|v| (1, v)).unwrap_or((0, 0));
    let (pi_sv, pi_space) = fmt_space(bus.space);
    let (po_adv, po_ad) = po.ad.map(|v| (1, v)).unwrap_or((0, 0));
    let (po_pv, po_par) = po.par.map(|v| (1, v)).unwrap_or((0, 0));
    let (po_sv, po_space) = fmt_space(po.space);

    let (qi_dv, qi_dd, qi_da, qi_dw) = match dev.dma_request {
        Some(r) => (1, r.direction as u8, r.address, r.words.blen()),
        None => (0, 0, 0, 0),
    };
    let (qi_nv, qi_nc) = dev.notification_request.map(|r| (1, r.channel)).unwrap_or((0, 0));
    let (qo_cv, qo_cs, qo_cw) = match qo.dma_completion {
        Some(c) => (1, match c.status {
            DmaStatus::Ok => 0,
            DmaStatus::BusError => 1,
            DmaStatus::ParityError => 2,
            DmaStatus::Timeout => 3,
            DmaStatus::ProtocolError => 4,
        }, c.words_completed),
        None => (0, 0, 0),
    };

    println!(
        "TRACE|v1|c={cycle:08x}|pi={}.{}.{}.{}.{:08x}.{}.{:01x}.{}.{:01x}.{}.{}.{:01x}.{:01x}.{}.{}.{}|qi=0.0.0.00000000.{}.{}.{:08x}.{:01x}.0.0.00000000.{}.{}.{:01x}|po={}.{}.{:08x}.{}.{:01x}.{}.{:01x}.{}.{}.{:01x}.{:01x}.{}.{}.{}|qo={}.0.00000000.0.0.00000000.0.0.{}.0.00000000.0.{}.{:02x}.{:01x}.0|ev={ev}",
        bus.reset as u8, bus.selected as u8, bus.grant as u8, pi_adv, pi_ad,
        pi_pv, pi_par, pi_sv, pi_space, bus.address_strobe as u8, bus.read as u8,
        bus.byte_enable, bus.burst.blen(), bus.data_strobe as u8, bus.ack as u8, bus.err as u8,
        qi_dv, qi_dd, qi_da, qi_dw, dev.dma_completion_ready as u8, qi_nv, qi_nc,
        po.request as u8, po_adv, po_ad, po_pv, po_par, po_sv, po_space,
        po.address_strobe as u8, po.read as u8, po.byte_enable, po.burst.blen(),
        po.data_strobe as u8, po.ack as u8, po.err as u8,
        qo.reset as u8, qo.dma_request_ready as u8, qo_cv, qo_cs, qo_cw,
    );
}

fn step(qic: &mut Qic, cycle: &mut u32, bus: BusToCard, dev: DeviceToQic, ev: &str) {
    emit(*cycle, &bus, &dev, qic, ev);
    qic.clock(&bus, &dev);
    *cycle += 1;
}

fn main() {
    let mut qic = Qic::new();
    let mut c = 0u32;

    // Notification wins at an idle boundary; DMA is not accepted.
    step(&mut qic, &mut c, bus(false, false, false, true), DeviceToQic::default(), "reset");
    step(&mut qic, &mut c, bus(false, false, false, false), both(), "manager_request");
    step(&mut qic, &mut c, bus(false, false, false, false), both(), "manager_request");
    step(&mut qic, &mut c, bus(true, false, false, false), both(), "manager_request");
    step(&mut qic, &mut c, bus(true, false, false, false), both(), "manager_address");
    step(&mut qic, &mut c, bus(true, true, false, false), both(), "manager_address");
    step(&mut qic, &mut c, bus(false, false, false, true), DeviceToQic::default(), "reset");

    // DMA address wait then target ERR -> held BusError completion.
    step(&mut qic, &mut c, bus(false, false, false, false), dma(0x3300_2000, DmaDirection::DeviceToHost, BurstWords::Four, false), "manager_request");
    step(&mut qic, &mut c, bus(false, false, false, false), DeviceToQic::default(), "manager_request");
    step(&mut qic, &mut c, bus(true, false, false, false), DeviceToQic::default(), "manager_request");
    step(&mut qic, &mut c, bus(true, false, false, false), DeviceToQic::default(), "manager_address");
    step(&mut qic, &mut c, bus(true, false, true, false), DeviceToQic::default(), "fault");
    step(&mut qic, &mut c, bus(false, false, false, false), DeviceToQic::default(), "dma_complete");
    step(&mut qic, &mut c, bus(false, false, false, false), DeviceToQic { dma_completion_ready: true, ..DeviceToQic::default() }, "dma_complete");

    // DMA loses BG before address completion -> ProtocolError completion.
    step(&mut qic, &mut c, bus(false, false, false, true), DeviceToQic::default(), "reset");
    step(&mut qic, &mut c, bus(false, false, false, false), dma(0x4400_0000, DmaDirection::HostToDevice, BurstWords::One, false), "manager_request");
    step(&mut qic, &mut c, bus(false, false, false, false), DeviceToQic::default(), "manager_request");
    step(&mut qic, &mut c, bus(true, false, false, false), DeviceToQic::default(), "manager_request");
    step(&mut qic, &mut c, bus(true, false, false, false), DeviceToQic::default(), "manager_address");
    step(&mut qic, &mut c, bus(false, false, false, false), DeviceToQic::default(), "fault");
    step(&mut qic, &mut c, bus(false, false, false, false), DeviceToQic { dma_completion_ready: true, ..DeviceToQic::default() }, "dma_complete");

    // DMA address timeout: 256 outstanding address clocks.
    step(&mut qic, &mut c, bus(false, false, false, true), DeviceToQic::default(), "reset");
    step(&mut qic, &mut c, bus(false, false, false, false), dma(0x5500_0000, DmaDirection::HostToDevice, BurstWords::Sixteen, false), "manager_request");
    step(&mut qic, &mut c, bus(false, false, false, false), DeviceToQic::default(), "manager_request");
    step(&mut qic, &mut c, bus(true, false, false, false), DeviceToQic::default(), "manager_request");
    for _ in 0..256 {
        step(&mut qic, &mut c, bus(true, false, false, false), DeviceToQic::default(), "manager_address");
    }
    step(&mut qic, &mut c, bus(false, false, false, false), DeviceToQic { dma_completion_ready: true, ..DeviceToQic::default() }, "dma_complete");

    // Fresh-grant rule: even with BG already high, a new request spends one
    // RequestBus cycle asserting BR before it may drive the address phase.
    step(&mut qic, &mut c, bus(false, false, false, true), DeviceToQic::default(), "reset");
    step(&mut qic, &mut c, bus(true, false, false, false), dma(0x6600_1000, DmaDirection::HostToDevice, BurstWords::Four, false), "manager_request");
    step(&mut qic, &mut c, bus(true, false, false, false), DeviceToQic::default(), "manager_request");
    step(&mut qic, &mut c, bus(true, false, false, false), DeviceToQic::default(), "manager_address");
    step(&mut qic, &mut c, bus(true, true, false, false), DeviceToQic::default(), "manager_address");
    step(&mut qic, &mut c, bus(false, false, false, true), DeviceToQic::default(), "reset");

    // Invalid local requests are ignored and never raise BR/ready.
    step(&mut qic, &mut c, bus(false, false, false, false), dma(0x7000_0002, DmaDirection::HostToDevice, BurstWords::One, false), "idle");
    step(&mut qic, &mut c, bus(false, false, false, false), notif(4), "idle");
}

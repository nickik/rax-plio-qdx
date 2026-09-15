use plio_logical_model::{odd_parity_32, BusToCard, BurstWords, Space};
use plio_qic_model::Qic;
use qli_model::{DeviceToQic, MmioResponse};

fn bus_default() -> BusToCard { BusToCard::default() }
fn dev_default() -> DeviceToQic { DeviceToQic::default() }

fn worker_addr(address: u32, read: bool, be: u8) -> BusToCard {
    BusToCard {
        selected: true,
        ad: Some(address),
        par: Some(odd_parity_32(address)),
        space: Some(Space::Worker),
        address_strobe: true,
        read,
        byte_enable: be,
        burst: BurstWords::One,
        ..BusToCard::default()
    }
}

fn data_cycle(data: Option<u32>, parity: Option<u8>) -> BusToCard {
    BusToCard { data_strobe: true, ad: data, par: parity, ..BusToCard::default() }
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

    let (qi_rv, qi_rk, qi_rd) = match dev.mmio_response {
        Some(MmioResponse::ReadOk(v)) => (1, 1, v),
        Some(MmioResponse::WriteOk) => (1, 2, 0),
        Some(MmioResponse::Error) => (1, 3, 0),
        None => (0, 0, 0),
    };
    let (qo_rqv, qo_addr, qo_wr, qo_be, qo_wd) = match qo.mmio_request {
        Some(r) => (1, r.address, r.write as u8, r.byte_enable, r.write_data),
        None => (0, 0, 0, 0, 0),
    };

    println!(
        "TRACE|v1|c={cycle:08x}|pi={}.{}.{}.{}.{:08x}.{}.{:01x}.{}.{:01x}.{}.{}.{:01x}.{:01x}.{}.{}.{}|qi={}.{}.{}.{:08x}.0.0.00000000.0.0.0.00000000.0.0.0|po={}.{}.{:08x}.{}.{:01x}.{}.{:01x}.{}.{}.{:01x}.{:01x}.{}.{}.{}|qo={}.{}.{:08x}.{}.{:01x}.{:08x}.{}.{}.0.0.00000000.0.0.00.0.{}|ev={ev}",
        bus.reset as u8, bus.selected as u8, bus.grant as u8, pi_adv, pi_ad,
        pi_pv, pi_par, pi_sv, pi_space, bus.address_strobe as u8, bus.read as u8,
        bus.byte_enable, bus.burst.blen(), bus.data_strobe as u8, bus.ack as u8, bus.err as u8,
        dev.mmio_ready as u8, qi_rv, qi_rk, qi_rd,
        po.request as u8, po_adv, po_ad, po_pv, po_par, po_sv, po_space,
        po.address_strobe as u8, po.read as u8, po.byte_enable, po.burst.blen(),
        po.data_strobe as u8, po.ack as u8, po.err as u8,
        qo.reset as u8, qo_rqv, qo_addr, qo_wr, qo_be, qo_wd,
        qo.mmio_response_ready as u8, qo.mmio_cancel as u8, qo.notification_ready as u8,
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

    step(&mut qic, &mut c, BusToCard { reset: true, ..bus_default() }, dev_default(), "reset");
    step(&mut qic, &mut c, worker_addr(0x100, true, 0xf), dev_default(), "worker_address");
    step(&mut qic, &mut c, bus_default(), dev_default(), "worker_data");
    step(&mut qic, &mut c, data_cycle(None, None), dev_default(), "worker_data");
    step(&mut qic, &mut c, bus_default(), dev_default(), "worker_data");
    step(&mut qic, &mut c, bus_default(), DeviceToQic { mmio_ready: true, ..dev_default() }, "worker_data");
    step(&mut qic, &mut c, bus_default(), DeviceToQic { mmio_response: Some(MmioResponse::ReadOk(0xdead_beef)), ..dev_default() }, "worker_data");
    step(&mut qic, &mut c, data_cycle(None, None), DeviceToQic { mmio_response: Some(MmioResponse::ReadOk(0xdead_beef)), ..dev_default() }, "worker_data");

    step(&mut qic, &mut c, worker_addr(0x102, false, 0xc), dev_default(), "worker_address");
    let w = 0x1234_5678;
    step(&mut qic, &mut c, data_cycle(Some(w), Some(odd_parity_32(w))), dev_default(), "worker_data");
    step(&mut qic, &mut c, bus_default(), DeviceToQic { mmio_ready: true, ..dev_default() }, "worker_data");
    step(&mut qic, &mut c, data_cycle(None, None), DeviceToQic { mmio_response: Some(MmioResponse::WriteOk), ..dev_default() }, "worker_data");

    step(&mut qic, &mut c, worker_addr(0x100, false, 0xf), dev_default(), "worker_address");
    let bad = 0xa5a5_5a5a;
    step(&mut qic, &mut c, data_cycle(Some(bad), Some(odd_parity_32(bad) ^ 1)), dev_default(), "fault");

    step(&mut qic, &mut c, BusToCard { reset: true, ..bus_default() }, dev_default(), "reset");
    step(&mut qic, &mut c, worker_addr(0x104, true, 0xf), dev_default(), "worker_address");
    step(&mut qic, &mut c, data_cycle(None, None), dev_default(), "worker_data");
    step(&mut qic, &mut c, bus_default(), DeviceToQic { mmio_ready: true, ..dev_default() }, "worker_data");

    for _ in 0..255 {
        step(&mut qic, &mut c, bus_default(), dev_default(), "worker_data");
    }
    step(&mut qic, &mut c, bus_default(), dev_default(), "fault");

    step(&mut qic, &mut c, BusToCard { reset: true, ..bus_default() }, dev_default(), "reset");
}

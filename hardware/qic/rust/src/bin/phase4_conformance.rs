use plio_logical_model::{odd_parity_32, BusToCard, BurstWords, Space};
use plio_qic_model::Qic;
use qli_model::{DeviceToQic, DmaDirection, DmaRequest, DmaStatus};

fn bus(grant: bool) -> BusToCard { BusToCard { grant, ..BusToCard::default() } }
fn dev() -> DeviceToQic { DeviceToQic::default() }
fn req(words: BurstWords) -> DeviceToQic {
    DeviceToQic {
        dma_request: Some(DmaRequest { direction: DmaDirection::HostToDevice, address: 0x2100_1000, words }),
        ..dev()
    }
}
fn data(grant: bool, ack: bool, err: bool, value: Option<u32>, bad_parity: bool) -> BusToCard {
    let par = value.map(|v| odd_parity_32(v) ^ u8::from(bad_parity));
    BusToCard { grant, ack, err, ad: value, par, ..BusToCard::default() }
}

fn emit(c: u32, bus: &BusToCard, d: &DeviceToQic, q: &Qic, ev: &str) {
    let (po, qo) = q.drive(bus, d);
    let opt32 = |v: Option<u32>| v.map(|x| (1u8, x)).unwrap_or((0, 0));
    let opt8 = |v: Option<u8>| v.map(|x| (1u8, x)).unwrap_or((0, 0));
    let (pi_adv, pi_ad) = opt32(bus.ad);
    let (pi_pv, pi_par) = opt8(bus.par);
    let (pi_sv, pi_space) = bus.space.map(|s| (1u8, s as u8)).unwrap_or((0, 0));
    let (po_adv, po_ad) = opt32(po.ad);
    let (po_pv, po_par) = opt8(po.par);
    let (po_sv, po_space) = po.space.map(|s| (1u8, s as u8)).unwrap_or((0, 0));

    let (qi_dv, qi_dir, qi_addr, qi_words) = match d.dma_request {
        Some(r) => (1u8, r.direction as u8, r.address, r.words.blen()),
        None => (0, 0, 0, 0),
    };
    let (qo_drv, qo_drd) = qo.dma_read.map(|w| (1u8, w.data)).unwrap_or((0, 0));
    let (qo_cv, qo_cs, qo_cw) = match qo.dma_completion {
        Some(x) => (1u8, x.status as u8, x.words_completed),
        None => (0, 0, 0),
    };

    println!(
        "TRACE|v1|c={c:08x}|pi={}.{}.{}.{}.{:08x}.{}.{:01x}.{}.{:01x}.{}.{}.{:01x}.{:01x}.{}.{}.{}|qi=0.0.0.00000000.{}.{}.{:08x}.{}.{}.0.00000000.{}.0.0|po={}.{}.{:08x}.{}.{:01x}.{}.{:01x}.{}.{}.{:01x}.{:01x}.{}.{}.{}|qo={}.0.00000000.0.0.00000000.0.0.{}.{}.{:08x}.{}.{}.{:02x}.{:01x}.0|ev={ev}",
        bus.reset as u8, bus.selected as u8, bus.grant as u8, pi_adv, pi_ad,
        pi_pv, pi_par, pi_sv, pi_space, bus.address_strobe as u8, bus.read as u8,
        bus.byte_enable, bus.burst.blen(), bus.data_strobe as u8, bus.ack as u8, bus.err as u8,
        qi_dv, qi_dir, qi_addr, qi_words, d.dma_read_ready as u8, d.dma_completion_ready as u8,
        po.request as u8, po_adv, po_ad, po_pv, po_par, po_sv, po_space,
        po.address_strobe as u8, po.read as u8, po.byte_enable, po.burst.blen(), po.data_strobe as u8, po.ack as u8, po.err as u8,
        qo.reset as u8, qo.dma_request_ready as u8, qo_drv, qo_drd, qo.dma_write_ready as u8,
        qo_cv, qo_cs, qo_cw,
    );
}

fn step(q: &mut Qic, c: &mut u32, b: BusToCard, d: DeviceToQic, ev: &str) {
    emit(*c, &b, &d, q, ev);
    q.clock(&b, &d);
    *c += 1;
}

fn main() {
    let mut q = Qic::new();
    let mut c = 0;

    step(&mut q, &mut c, BusToCard { reset: true, ..bus(false) }, dev(), "reset");
    step(&mut q, &mut c, bus(false), req(BurstWords::Four), "manager_request");
    step(&mut q, &mut c, bus(true), dev(), "manager_request");
    step(&mut q, &mut c, BusToCard { grant: true, ack: true, ..bus(true) }, dev(), "manager_address");
    step(&mut q, &mut c, bus(true), dev(), "dma_data");

    for (i, value) in [0x1111_1111, 0x2222_2222, 0x3333_3333, 0x4444_4444].into_iter().enumerate() {
        step(&mut q, &mut c, data(true, true, false, Some(value), false), dev(), "dma_data");
        let final_word = i == 3;
        if final_word {
            step(&mut q, &mut c, bus(false), dev(), "dma_data");
            step(&mut q, &mut c, bus(false), DeviceToQic { dma_read_ready: true, ..dev() }, "dma_data");
        } else {
            let ready = i != 0;
            step(&mut q, &mut c, bus(true), DeviceToQic { dma_read_ready: ready, ..dev() }, "dma_data");
            if !ready {
                step(&mut q, &mut c, bus(true), DeviceToQic { dma_read_ready: true, ..dev() }, "dma_data");
            }
        }
    }
    step(&mut q, &mut c, bus(false), dev(), "dma_complete");
    step(&mut q, &mut c, bus(false), DeviceToQic { dma_completion_ready: true, ..dev() }, "dma_complete");

    step(&mut q, &mut c, BusToCard { reset: true, ..bus(false) }, dev(), "reset");
    step(&mut q, &mut c, bus(false), req(BurstWords::One), "manager_request");
    step(&mut q, &mut c, bus(true), dev(), "manager_request");
    step(&mut q, &mut c, BusToCard { grant: true, ack: true, ..bus(true) }, dev(), "manager_address");
    step(&mut q, &mut c, data(true, false, true, None, false), dev(), "fault");
    step(&mut q, &mut c, bus(true), dev(), "dma_complete");
    step(&mut q, &mut c, bus(true), DeviceToQic { dma_completion_ready: true, ..dev() }, "dma_complete");

    step(&mut q, &mut c, BusToCard { reset: true, ..bus(false) }, dev(), "reset");
    step(&mut q, &mut c, bus(false), req(BurstWords::One), "manager_request");
    step(&mut q, &mut c, bus(true), dev(), "manager_request");
    step(&mut q, &mut c, BusToCard { grant: true, ack: true, ..bus(true) }, dev(), "manager_address");
    step(&mut q, &mut c, data(true, true, false, Some(0xfeed_beef), true), dev(), "fault");
    step(&mut q, &mut c, bus(true), dev(), "dma_complete");

    let _ = (Space::HostDma, DmaStatus::Ok);
}

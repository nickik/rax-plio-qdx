use plio_logical_model::{odd_parity_32, BusToCard, BurstWords, CardToBus, Space};
use plio_qic_model::Qic;
use qli_model::{DeviceToQic, DmaDirection, DmaRequest, DmaStatus, DmaWord, MmioResponse, NotificationRequest, QicToDevice};

fn reset_pi() -> BusToCard { BusToCard { reset: true, ..BusToCard::default() } }
fn grant_pi(ack: bool, err: bool) -> BusToCard { BusToCard { grant: true, ack, err, ..BusToCard::default() } }
fn worker_addr(a: u32, read: bool, be: u8) -> BusToCard {
    BusToCard { selected: true, ad: Some(a), par: Some(odd_parity_32(a)), space: Some(Space::Worker), address_strobe: true, read, byte_enable: be, burst: BurstWords::One, ..BusToCard::default() }
}
fn worker_data(d: u32) -> BusToCard { BusToCard { data_strobe: true, ad: Some(d), par: Some(odd_parity_32(d)), ..BusToCard::default() } }
fn dma_req(dir: DmaDirection, addr: u32, words: BurstWords) -> DeviceToQic {
    DeviceToQic { dma_request: Some(DmaRequest { direction: dir, address: addr, words }), ..DeviceToQic::default() }
}
fn notif_req(ch: u8) -> DeviceToQic { DeviceToQic { notification_request: Some(NotificationRequest { channel: ch }), ..DeviceToQic::default() } }

fn worker_pi(l: u16, write: bool, addr: u32, be: u8, data: u32) -> BusToCard {
    match l {
        0 => reset_pi(),
        1 => worker_addr(addr, !write, be),
        2 if write => worker_data(data),
        2 | 4 => BusToCard { data_strobe: true, ..BusToCard::default() },
        _ => BusToCard::default(),
    }
}
fn worker_qi(l: u16, write: bool, response_data: u32) -> DeviceToQic {
    match l {
        3 => DeviceToQic { mmio_ready: true, ..DeviceToQic::default() },
        4 => DeviceToQic { mmio_response: Some(if write { MmioResponse::WriteOk } else { MmioResponse::ReadOk(response_data) }), ..DeviceToQic::default() },
        _ => DeviceToQic::default(),
    }
}
fn notification_pi(l: u16) -> BusToCard {
    match l { 0 => reset_pi(), 2 => grant_pi(false, false), 3 | 4 => grant_pi(true, false), _ => BusToCard::default() }
}
fn notification_qi(l: u16, ch: u8) -> DeviceToQic { if (1..=4).contains(&l) { notif_req(ch) } else { DeviceToQic::default() } }

fn h2d_pi(l: u16, n: u16) -> BusToCard {
    if l == 0 { return reset_pi(); }
    if l == 2 { return grant_pi(false, false); }
    if l == 3 { return grant_pi(true, false); }
    if l >= 4 && l < 4 + 2*n {
        if l % 2 == 0 {
            let d = 0x1100_0000u32 + u32::from((l-4)/2);
            return BusToCard { ad: Some(d), par: Some(odd_parity_32(d)), ..grant_pi(true, false) };
        }
        if l != 3 + 2*n { return grant_pi(false, false); }
    }
    BusToCard::default()
}
fn h2d_qi(l: u16, n: u16, addr: u32, words: BurstWords) -> DeviceToQic {
    if l == 1 { return dma_req(DmaDirection::HostToDevice, addr, words); }
    if l >= 5 && l <= 3 + 2*n && l % 2 == 1 { return DeviceToQic { dma_read_ready: true, ..DeviceToQic::default() }; }
    if l == 4 + 2*n { return DeviceToQic { dma_completion_ready: true, ..DeviceToQic::default() }; }
    DeviceToQic::default()
}
fn d2h_pi(l: u16, n: u16) -> BusToCard {
    if l == 0 { return reset_pi(); }
    if l == 2 { return grant_pi(false, false); }
    if l == 3 { return grant_pi(true, false); }
    if l >= 4 && l < 4 + 2*n { return grant_pi(l % 2 == 1, false); }
    BusToCard::default()
}
fn d2h_qi(l: u16, n: u16, addr: u32, words: BurstWords) -> DeviceToQic {
    if l == 1 { return dma_req(DmaDirection::DeviceToHost, addr, words); }
    if l >= 4 && l < 4 + 2*n && l % 2 == 0 {
        return DeviceToQic { dma_write: Some(DmaWord { data: 0x2200_0000u32 + u32::from((l-4)/2) }), ..DeviceToQic::default() };
    }
    if l == 4 + 2*n { return DeviceToQic { dma_completion_ready: true, ..DeviceToQic::default() }; }
    DeviceToQic::default()
}

fn pi_for(c: u16) -> BusToCard {
    match c {
        0..=4 => worker_pi(c, false, 0x100, 0x1, 0),
        5..=9 => worker_pi(c-5, false, 0x102, 0x3, 0),
        10..=14 => worker_pi(c-10, false, 0x104, 0xf, 0),
        15..=19 => worker_pi(c-15, true, 0x108, 0x1, 0x0000_005a),
        20..=24 => worker_pi(c-20, true, 0x10a, 0x3, 0x0000_a55a),
        25..=29 => worker_pi(c-25, true, 0x10c, 0xf, 0xa55a_5aa5),
        30..=35 => notification_pi(c-30),
        36..=41 => notification_pi(c-36),
        42..=47 => notification_pi(c-42),
        48..=53 => notification_pi(c-48),
        54 => reset_pi(),
        56 | 59 | 61 => grant_pi(false, false),
        57 | 58 => grant_pi(true, false),
        62 => reset_pi(),
        63..=69 => h2d_pi(c-63, 1),
        70..=82 => h2d_pi(c-70, 4),
        83..=103 => h2d_pi(c-83, 8),
        104..=140 => h2d_pi(c-104, 16),
        141..=147 => d2h_pi(c-141, 1),
        148..=160 => d2h_pi(c-148, 4),
        161..=181 => d2h_pi(c-161, 8),
        182..=218 => d2h_pi(c-182, 16),
        219 | 224 | 229 | 235 | 496 | 757 | 1016 => reset_pi(),
        221 | 226 | 231 | 237 | 1018 | 1021 | 1025 => grant_pi(false, false),
        222 | 1019 | 1023 => grant_pi(false, true),
        232 | 1022 | 1026 | 1027 => grant_pi(true, false),
        233 => {
            let d=0xdead_beef;
            BusToCard { ad: Some(d), par: Some(odd_parity_32(d)^1), ..grant_pi(true,false) }
        }
        238..=494 => grant_pi(false, false),
        497 => worker_addr(0x180, true, 0xf),
        498 => BusToCard { data_strobe: true, ..BusToCard::default() },
        500..=755 => BusToCard { data_strobe: true, ..BusToCard::default() },
        758 => worker_addr(0x184, true, 0xf),
        759 => BusToCard { data_strobe: true, ..BusToCard::default() },
        _ => BusToCard::default(),
    }
}

fn qi_for(c: u16) -> DeviceToQic {
    match c {
        0..=4 => worker_qi(c, false, 0x0000_0011),
        5..=9 => worker_qi(c-5, false, 0x0000_2233),
        10..=14 => worker_qi(c-10, false, 0x4455_6677),
        15..=19 => worker_qi(c-15, true, 0),
        20..=24 => worker_qi(c-20, true, 0),
        25..=29 => worker_qi(c-25, true, 0),
        30..=35 => notification_qi(c-30, 0),
        36..=41 => notification_qi(c-36, 1),
        42..=47 => notification_qi(c-42, 2),
        48..=53 => notification_qi(c-48, 3),
        55..=58 => {
            let mut q=notif_req(2);
            q.dma_request=Some(DmaRequest { direction:DmaDirection::HostToDevice,address:0x3300_0000,words:BurstWords::One });
            q
        }
        59..=61 => dma_req(DmaDirection::HostToDevice,0x3300_0000,BurstWords::One),
        63..=69 => h2d_qi(c-63,1,0x4000_1000,BurstWords::One),
        70..=82 => h2d_qi(c-70,4,0x4000_2000,BurstWords::Four),
        83..=103 => h2d_qi(c-83,8,0x4000_3000,BurstWords::Eight),
        104..=140 => h2d_qi(c-104,16,0x4000_4000,BurstWords::Sixteen),
        141..=147 => d2h_qi(c-141,1,0x5000_1000,BurstWords::One),
        148..=160 => d2h_qi(c-148,4,0x5000_2000,BurstWords::Four),
        161..=181 => d2h_qi(c-161,8,0x5000_3000,BurstWords::Eight),
        182..=218 => d2h_qi(c-182,16,0x5000_4000,BurstWords::Sixteen),
        220..=223 => { let mut q=dma_req(DmaDirection::HostToDevice,0x6000_1000,BurstWords::One); if c==223 { q.dma_completion_ready=true; } q },
        225..=228 => { let mut q=dma_req(DmaDirection::HostToDevice,0x6000_2000,BurstWords::One); if c==228 { q.dma_completion_ready=true; } q },
        230..=234 => { let mut q=dma_req(DmaDirection::HostToDevice,0x6000_3000,BurstWords::One); if c==234 { q.dma_completion_ready=true; } q },
        236..=495 => { let mut q=dma_req(DmaDirection::DeviceToHost,0x6000_4000,BurstWords::One); if c==495 { q.dma_completion_ready=true; } q },
        499 => DeviceToQic { mmio_ready:true, ..DeviceToQic::default() },
        1017..=1027 => notif_req(3),
        _ => DeviceToQic::default(),
    }
}

fn mmio_kind(r: Option<MmioResponse>) -> u8 { match r { None=>0, Some(MmioResponse::ReadOk(_))=>1, Some(MmioResponse::WriteOk)=>2, Some(MmioResponse::Error)=>3 } }
fn mmio_data(r: Option<MmioResponse>) -> u32 { match r { Some(MmioResponse::ReadOk(d))=>d, _=>0 } }
fn dma_status(s: DmaStatus) -> u8 { match s { DmaStatus::Ok=>0, DmaStatus::BusError=>1, DmaStatus::ParityError=>2, DmaStatus::Timeout=>3, DmaStatus::ProtocolError=>4 } }

fn emit(c:u16, pi:&BusToCard, qi:&DeviceToQic, po:&CardToBus, qo:&QicToDevice) {
    let (piav,pia)=pi.ad.map(|v|(1u8,v)).unwrap_or((0,0)); let (pipv,pip)=pi.par.map(|v|(1u8,v)).unwrap_or((0,0)); let (pisv,pis)=pi.space.map(|v|(1u8,v as u8)).unwrap_or((0,0));
    let (poav,poa)=po.ad.map(|v|(1u8,v)).unwrap_or((0,0)); let (popv,pop)=po.par.map(|v|(1u8,v)).unwrap_or((0,0)); let (posv,pos)=po.space.map(|v|(1u8,v as u8)).unwrap_or((0,0));
    let (qdrv,qdir,qaddr,qwords)=qi.dma_request.map(|r|(1u8,r.direction as u8,r.address,r.words.blen())).unwrap_or((0,0,0,0));
    let (qdwv,qdwd)=qi.dma_write.map(|w|(1u8,w.data)).unwrap_or((0,0)); let (qnsv,qns)=qi.notification_request.map(|n|(1u8,n.channel)).unwrap_or((0,0));
    let (qomv,qoma,qomw,qombe,qomd)=qo.mmio_request.map(|r|(1u8,r.address,r.write as u8,r.byte_enable,r.write_data)).unwrap_or((0,0,0,0,0));
    let (qorv,qord)=qo.dma_read.map(|w|(1u8,w.data)).unwrap_or((0,0)); let (qocv,qocs,qocw)=qo.dma_completion.map(|x|(1u8,dma_status(x.status),x.words_completed)).unwrap_or((0,0,0));
    println!("TRACE|v2|c={c:08x}|pi={}.{}.{}.{}.{:08x}.{}.{:01x}.{}.{:01x}.{}.{}.{:01x}.{:01x}.{}.{}.{ }|qi={}.{}.{:01x}.{:08x}.{}.{}.{:08x}.{}.{}.{}.{:08x}.{}.{}.{:02x}|po={}.{}.{:08x}.{}.{:01x}.{}.{:01x}.{}.{}.{:01x}.{:01x}.{}.{}.{ }|qo={}.{}.{:08x}.{}.{:01x}.{:08x}.{}.{}.{}.{}.{:08x}.{}.{}.{:02x}.{:01x}.{}|ev=phase8",
        pi.reset as u8,pi.selected as u8,pi.grant as u8,piav,pia,pipv,pip,pisv,pis,pi.address_strobe as u8,pi.read as u8,pi.byte_enable,pi.burst.blen(),pi.data_strobe as u8,pi.ack as u8,pi.err as u8,
        qi.mmio_ready as u8,qi.mmio_response.is_some() as u8,mmio_kind(qi.mmio_response),mmio_data(qi.mmio_response),qdrv,qdir,qaddr,qwords,qi.dma_read_ready as u8,qdwv,qdwd,qi.dma_completion_ready as u8,qnsv,qns,
        po.request as u8,poav,poa,popv,pop,posv,pos,po.address_strobe as u8,po.read as u8,po.byte_enable,po.burst.blen(),po.data_strobe as u8,po.ack as u8,po.err as u8,
        qo.reset as u8,qomv,qoma,qomw,qombe,qomd,qo.mmio_response_ready as u8,qo.mmio_cancel as u8,qo.dma_request_ready as u8,qorv,qord,qo.dma_write_ready as u8,qocv,qocs,qocw,qo.notification_ready as u8);
}

fn main() {
    let mut q=Qic::new();
    for c in 0u16..=1027 {
        let pi=pi_for(c); let qi=qi_for(c); let (po,qo)=q.drive(&pi,&qi); emit(c,&pi,&qi,&po,&qo); q.clock(&pi,&qi);
    }
}

use plio_logical_model::{BusToCard, BurstWords, CardToBus, Space};
use plio_qic_model::Qic;
use plio_testbench::TestPeer;
use plio_tx_model::{BackplaneDrive, BackplaneSample, PlioTx, PtiDirection, QicPtiDrive};
use pti_model::{encode_control, encode_data_beat, ControlImage, Token, TokenKind};
use qli16_model::codec::LinkCodec;
use qli_model::{DeviceToQic, DmaDirection, DmaRequest, DmaStatus, DmaWord, NotificationRequest};

fn idle() -> Token { Token::new(TokenKind::Idle, 0, 0).unwrap() }
fn qdrive(token: Token) -> QicPtiDrive { QicPtiDrive { token, ..Default::default() } }
fn clock_slot(tx: &mut PlioTx, q: QicPtiDrive, bus: BackplaneSample) { let (_, obs) = tx.drive(false, q, bus); assert!(!obs.protocol_fault, "PTI protocol fault before clock: {obs:?}"); tx.clock(false, q, bus); }

fn through_tx(tx: &mut PlioTx, card: CardToBus) -> BackplaneDrive {
    clock_slot(tx, qdrive(idle()), BackplaneSample::default());
    let has_control = card.space.is_some() || card.address_strobe || card.data_strobe;
    let has_data = card.ad.is_some() || card.par.is_some();
    let needs_drive = has_control || has_data;
    if needs_drive {
        let control = ControlImage { space: card.space.unwrap_or(Space::Worker) as u8, address_strobe: card.address_strobe, read: card.read, byte_enable: card.byte_enable, burst_len: card.burst.blen(), data_strobe: card.data_strobe, drive_ad_par: has_data, drive_control: has_control };
        clock_slot(tx, qdrive(encode_control(control).unwrap()), BackplaneSample::default());
    }
    if let (Some(ad), Some(par)) = (card.ad, card.par) { for t in encode_data_beat(ad, par).unwrap() { clock_slot(tx, qdrive(t), BackplaneSample::default()); } }
    clock_slot(tx, qdrive(idle()), BackplaneSample::default());
    let q = QicPtiDrive { token: idle(), drive_enable: needs_drive, response_enable: card.ack || card.err, response_ack: card.ack, response_err: card.err, bus_request: card.request, ..Default::default() };
    let (bp, obs) = tx.drive(false, q, BackplaneSample::default()); assert!(!obs.protocol_fault, "legal QIC image caused PLIO-TX fault"); tx.clock(false, q, BackplaneSample::default()); bp
}

fn sample_ad(tx: &mut PlioTx, ad: u32, par: u8) -> (u32, u8) {
    let bus = BackplaneSample { ad, par, ..Default::default() };
    let turn = QicPtiDrive { direction: PtiDirection::TxToQic, token: idle(), ..Default::default() }; clock_slot(tx, turn, bus);
    let loq = QicPtiDrive { direction: PtiDirection::TxToQic, token: Token::new(TokenKind::DataLo, 0, 0).unwrap(), ..Default::default() }; let (_, lo) = tx.drive(false, loq, bus); tx.clock(false, loq, bus); let lot = lo.rx_token.expect("low receive bank");
    let hiq = QicPtiDrive { direction: PtiDirection::TxToQic, token: Token::new(TokenKind::DataHi, 0, 0).unwrap(), ..Default::default() }; let (_, hi) = tx.drive(false, hiq, bus); tx.clock(false, hiq, bus); let hit = hi.rx_token.expect("high receive bank");
    (u32::from(lot.data()) | (u32::from(hit.data()) << 16), lot.parity() | (hit.parity() << 2))
}
fn physicalize_bus(tx: &mut PlioTx, mut bus: BusToCard) -> BusToCard { if let (Some(ad), Some(par)) = (bus.ad, bus.par) { let (a, p) = sample_ad(tx, ad, par); bus.ad = Some(a); bus.par = Some(p); } bus }
fn card_from_backplane(bp: BackplaneDrive) -> CardToBus { let mut c = CardToBus { request: bp.request, ..Default::default() }; if let Some((a,p))=bp.ad_par { c.ad=Some(a); c.par=Some(p); } if let Some(x)=bp.control { c.space=match x.space {0=>Some(Space::Worker),1=>Some(Space::HostDma),2=>Some(Space::Controller),_=>Some(Space::Reserved)}; c.address_strobe=x.address_strobe; c.read=x.read; c.byte_enable=x.byte_enable; c.burst=BurstWords::from_blen(x.burst_len).unwrap(); c.data_strobe=x.data_strobe; } if let Some((a,e))=bp.response { c.ack=a; c.err=e; } c }

#[derive(Clone, Copy)] struct DmaCase { direction: DmaDirection, words: BurstWords, address_wait: u16, data_wait: u16, error_beat: Option<u8>, bad_parity_beat: Option<u8> }
fn run_dma(case: DmaCase) -> (DmaStatus, u8, usize, u32) {
    let mut qic=Qic::new(); let mut link=LinkCodec::new(); let mut tx=PlioTx::new(); let mut peer=TestPeer::new(); peer.manager_address_wait_cycles=case.address_wait; peer.dma_wait_cycles=case.data_wait; peer.dma_error_beat=case.error_beat; peer.dma_bad_parity_beat=case.bad_parity_beat; peer.dma_read_base=0x7000_0000;
    let request=DmaRequest { direction:case.direction, address:0x1234_5000, words:case.words }; let mut pending=true; let mut write_index=0u8; let mut received=Vec::new(); let mut final_status=None;
    for _ in 0..2048 {
        let bus=physicalize_bus(&mut tx, peer.bus_inputs());
        let preview=if pending { DeviceToQic { dma_request:Some(request), ..Default::default() } } else { Default::default() };
        let (_, qout)=qic.drive(&bus, &preview);
        let mut device=DeviceToQic { dma_completion_ready:true, ..Default::default() };
        if pending { device.dma_request=Some(request); }
        if !pending && case.direction==DmaDirection::DeviceToHost && write_index<case.words.words() && qout.dma_write_ready { device.dma_write=Some(DmaWord { data:0x4000_0000 + u32::from(write_index)*4 }); }
        if case.direction==DmaDirection::HostToDevice { device.dma_read_ready=true; }
        let local=link.cycle(false, qout, device); assert!(!local.protocol_fault);
        if local.to_device.dma_request_ready { pending=false; }
        if local.to_device.dma_write_ready { write_index+=1; }
        if let Some(word)=local.to_device.dma_read { received.push(word.data); }
        if let Some(c)=local.to_device.dma_completion { final_status=Some((c.status,c.words_completed)); }
        let (card,_)=qic.drive(&bus,&local.to_qic); peer.clock(&card_from_backplane(through_tx(&mut tx,card))); qic.clock(&bus,&local.to_qic);
        if final_status.is_some() { break; }
    }
    let (status,completed)=final_status.expect("DMA completion did not cross the physical stack"); (status,completed,received.len(),peer.manager_transactions())
}
fn status_code(status:DmaStatus)->u8 { match status { DmaStatus::Ok=>0,DmaStatus::BusError=>1,DmaStatus::ParityError=>2,DmaStatus::Timeout=>3,DmaStatus::ProtocolError=>4 } }

#[test] fn plio_address_and_data_waits_cross_complete_stack() { let (s,c,_,t)=run_dma(DmaCase { direction:DmaDirection::DeviceToHost,words:BurstWords::Four,address_wait:3,data_wait:2,error_beat:None,bad_parity_beat:None }); assert_eq!((s,c),(DmaStatus::Ok,4)); assert_eq!(t,1); println!("FAULTTRACE|v1|case=waits|status=0|completed=4"); }
#[test] fn dma_target_errors_preserve_progress_in_both_directions() { for d in [DmaDirection::DeviceToHost,DmaDirection::HostToDevice] { for b in [0u8,1,3] { let (s,c,_,_)=run_dma(DmaCase { direction:d,words:BurstWords::Four,address_wait:0,data_wait:0,error_beat:Some(b),bad_parity_beat:None }); assert_eq!(s,DmaStatus::BusError); assert_eq!(c,b); let dir=if d==DmaDirection::DeviceToHost{"d2h"}else{"h2d"}; println!("FAULTTRACE|v1|case=bus_error|dir={dir}|beat={b}|status={}|completed={c}",status_code(s)); } } }
#[test] fn h2d_bad_parity_never_delivers_corrupt_word() { for b in [0u8,1,3] { let (s,c,n,_)=run_dma(DmaCase { direction:DmaDirection::HostToDevice,words:BurstWords::Four,address_wait:0,data_wait:0,error_beat:None,bad_parity_beat:Some(b) }); assert_eq!(s,DmaStatus::ParityError); assert_eq!(c,b); assert_eq!(n,usize::from(b)); println!("FAULTTRACE|v1|case=parity|beat={b}|status={}|completed={c}",status_code(s)); } }
#[test] fn manager_address_and_data_timeout_cross_complete_stack() { for (aw,dw,label) in [(300,0,"address_timeout"),(0,300,"data_timeout")] { let (s,c,_,_)=run_dma(DmaCase { direction:DmaDirection::DeviceToHost,words:BurstWords::Four,address_wait:aw,data_wait:dw,error_beat:None,bad_parity_beat:None }); assert_eq!((s,c),(DmaStatus::Timeout,0)); println!("FAULTTRACE|v1|case={label}|status=3|completed=0"); } }

#[test] fn notification_retries_after_address_error_and_completes_only_after_ack() {
    let mut qic=Qic::new(); let mut link=LinkCodec::new(); let mut tx=PlioTx::new(); let mut peer=TestPeer::new(); peer.manager_address_error=true; peer.notification_wait_cycles=3; let request=NotificationRequest { channel:2 }; let mut completed=false; let mut transported=false;
    for _ in 0..1024 {
        if peer.manager_transactions()>=1 { peer.manager_address_error=false; }
        let bus=physicalize_bus(&mut tx,peer.bus_inputs()); let device=DeviceToQic { notification_request:Some(request), ..Default::default() }; let preview=if transported { DeviceToQic { notification_request:Some(request), ..Default::default() } } else { Default::default() }; let (_,qout)=qic.drive(&bus,&preview); let local=link.cycle(false,qout,device); transported|=local.to_qic.notification_request==Some(request);
        let (card,_)=qic.drive(&bus,&local.to_qic); peer.clock(&card_from_backplane(through_tx(&mut tx,card))); qic.clock(&bus,&local.to_qic);
        if local.to_device.notification_ready { assert!(!peer.notifications().is_empty(),"ready preceded physical bus completion"); completed=true; break; }
    }
    assert!(completed); assert_eq!(peer.notifications(),&[2]); assert!(peer.manager_transactions()>=2,"Notification was not retried"); println!("FAULTTRACE|v1|case=notification_retry|channel=2|ready=1|transactions=2");
}

#[test] fn qli_backpressure_holds_final_token_stable_and_reset_clears_everything() {
    let mut link=LinkCodec::new(); let req=qli_model::MmioRequest { address:0x100,write:false,byte_enable:0xf,write_data:0 }; let qic=qli_model::QicToDevice { mmio_request:Some(req), ..Default::default() };
    let first=link.cycle(false,qic,Default::default()); let second=link.cycle(false,qic,Default::default()); assert!(second.slots.iter().any(|s|s.valid&&!s.ack)); let held=second.slots.iter().find(|s|s.valid&&!s.ack).unwrap().token; let third=link.cycle(false,qic,Default::default()); let held_again=third.slots.iter().find(|s|s.valid&&!s.ack).unwrap().token; assert_eq!(held,held_again); assert!(first.slots.iter().any(|s|s.valid));
    let reset=link.cycle(true,Default::default(),Default::default()); assert!(reset.to_device.reset); assert!(!reset.protocol_fault);
    let tx=PlioTx::new(); let q=QicPtiDrive { token:idle(),drive_enable:true,response_enable:true,response_ack:true,bus_request:true,..Default::default() }; let (bp,_)=tx.drive(true,q,BackplaneSample::default()); assert_eq!(bp,BackplaneDrive::default(),"reset must tri-state every PLIO-TX output"); println!("FAULTTRACE|v1|case=backpressure_reset|stable=1|tristate=1");
}

#[test] fn malformed_qli16_is_sticky_until_reset() {
    let mut link=LinkCodec::new(); link.inject_raw_token(qli16_model::Token { kind:qli16_model::TokenType::DmaCompletion,payload:0xff00,direction:qli16_model::Direction::DeviceToQic }); assert!(link.protocol_fault()); let bad=link.cycle(false,Default::default(),Default::default()); assert!(bad.protocol_fault); let reset=link.cycle(true,Default::default(),Default::default()); assert!(!reset.protocol_fault); println!("FAULTTRACE|v1|case=malformed_reset|fault=1|recovered=1");
}

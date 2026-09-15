use plio_logical_model::{odd_parity_32, BusToCard, BurstWords, CardToBus, Space};
use plio_qic_model::Qic;
use plio_tx_model::{BackplaneSample, PlioTx, QicPtiDrive};
use pti_model::{encode_control, encode_data_beat, ControlImage, Token, TokenKind};
use qli_model::{DeviceToQic,DmaDirection,DmaRequest,DmaWord,MmioResponse,NotificationRequest};

fn idle()->Token{Token::new(TokenKind::Idle,0,0).unwrap()}
fn slot(tx:&mut PlioTx,q:QicPtiDrive){let b=BackplaneSample::default();let _=tx.drive(false,q,b);tx.clock(false,q,b)}
fn through(tx:&mut PlioTx,c:CardToBus)->plio_tx_model::BackplaneDrive{
 let hc=c.space.is_some()||c.address_strobe||c.data_strobe; let hd=c.ad.is_some()&&c.par.is_some();
 if hc{let i=ControlImage{space:c.space.unwrap_or(Space::Worker) as u8,address_strobe:c.address_strobe,read:c.read,byte_enable:c.byte_enable,burst_len:c.burst.blen(),data_strobe:c.data_strobe,drive_ad_par:hd,drive_control:true};slot(tx,QicPtiDrive{token:encode_control(i).unwrap(),..Default::default()});}
 if let(Some(a),Some(p))=(c.ad,c.par){for t in encode_data_beat(a,p).unwrap(){slot(tx,QicPtiDrive{token:t,..Default::default()});}}
 slot(tx,QicPtiDrive{token:idle(),..Default::default()});
 let q=QicPtiDrive{token:idle(),drive_enable:hc,response_enable:c.ack||c.err,response_ack:c.ack,response_err:c.err,bus_request:c.request,..Default::default()};
 let b=BackplaneSample::default();let (x,o)=tx.drive(false,q,b);assert!(!o.protocol_fault);tx.clock(false,q,b);x
}
fn main(){
 let mut qic=Qic::new();let mut tx=PlioTx::new();let mut q=DeviceToQic::default();
 let mut b=BusToCard{selected:true,ad:Some(0x100),par:Some(odd_parity_32(0x100)),space:Some(Space::Worker),address_strobe:true,read:true,byte_enable:0xf,burst:BurstWords::One,..Default::default()};
 let _=through(&mut tx,qic.drive(&b,&q).0);qic.clock(&b,&q);b=BusToCard{data_strobe:true,..Default::default()};qic.clock(&b,&q);q.mmio_ready=true;qic.clock(&BusToCard::default(),&q);q.mmio_response=Some(MmioResponse::ReadOk(0x89ab_cdef));
 let x=through(&mut tx,qic.drive(&b,&q).0);println!("QTXTRACE|v1|case=worker_read|ad={:08x}|par={:01x}|ack=1|err=0",x.ad_par.unwrap().0,x.ad_par.unwrap().1);qic.clock(&b,&q);

 q=DeviceToQic{dma_request:Some(DmaRequest{direction:DmaDirection::DeviceToHost,address:0x2000,words:BurstWords::One}),..Default::default()};qic.clock(&BusToCard::default(),&q);b=BusToCard{grant:true,..Default::default()};let _=through(&mut tx,qic.drive(&b,&q).0);qic.clock(&b,&q);
 let x=through(&mut tx,qic.drive(&b,&q).0);println!("QTXTRACE|v1|case=d2h_address|ad={:08x}|space={:01x}|rd=0|as=1",x.ad_par.unwrap().0,x.control.unwrap().space);qic.clock(&BusToCard{grant:true,ack:true,..Default::default()},&q);
 q.dma_write=Some(DmaWord{data:0x1122_3344});qic.clock(&b,&q);let x=through(&mut tx,qic.drive(&b,&q).0);println!("QTXTRACE|v1|case=d2h_data|ad={:08x}|par={:01x}|ds=1",x.ad_par.unwrap().0,x.ad_par.unwrap().1);qic.clock(&BusToCard{grant:true,ack:true,..Default::default()},&q);q.dma_completion_ready=true;qic.clock(&b,&q);

 q=DeviceToQic{notification_request:Some(NotificationRequest{channel:3}),..Default::default()};qic.clock(&BusToCard::default(),&q);b=BusToCard{grant:true,..Default::default()};let _=through(&mut tx,qic.drive(&b,&q).0);qic.clock(&b,&q);let x=through(&mut tx,qic.drive(&b,&q).0);println!("QTXTRACE|v1|case=notification_address|ad={:08x}|space=2|as=1",x.ad_par.unwrap().0);qic.clock(&BusToCard{grant:true,ack:true,..Default::default()},&q);
 let x=through(&mut tx,qic.drive(&b,&q).0);let (_,qo)=qic.drive(&BusToCard{grant:true,ack:true,..Default::default()},&q);assert!(qo.notification_ready);assert_eq!(x.ad_par.unwrap().0,0);println!("QTXTRACE|v1|case=notification_data|ad=00000000|ds=1|ready=1");
}

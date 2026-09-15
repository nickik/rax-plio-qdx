use plio_logical_model::{odd_parity_32, BusToCard, BurstWords, Space};
use plio_qic_model::Qic;
use qli_model::{DeviceToQic, DmaDirection, DmaRequest, NotificationRequest};

fn emit(c: u32, qic: &Qic, bus: BusToCard, dev: DeviceToQic, ev: &str) {
    let (po, qo) = qic.drive(&bus, &dev);
    let (piv, pia) = bus.ad.map(|v|(1,v)).unwrap_or((0,0));
    let (ppv, ppa) = bus.par.map(|v|(1,v)).unwrap_or((0,0));
    let (psv, psp) = bus.space.map(|v|(1,v as u8)).unwrap_or((0,0));
    let (pov, poa) = po.ad.map(|v|(1,v)).unwrap_or((0,0));
    let (popv, popa) = po.par.map(|v|(1,v)).unwrap_or((0,0));
    let (posv, posp) = po.space.map(|v|(1,v as u8)).unwrap_or((0,0));
    let (nrv,nrc)=dev.notification_request.map(|n|(1,n.channel)).unwrap_or((0,0));
    let (drv,drd,dra,drw)=dev.dma_request.map(|d|(1,d.direction as u8,d.address,d.words.blen())).unwrap_or((0,0,0,0));
    println!("TRACE|v1|c={c:08x}|pi={}.{}.{}.{}.{:08x}.{}.{:01x}.{}.{:01x}.{}.{}.{:01x}.{:01x}.{}.{}.{}|qi=0.0.0.00000000.{}.{drd}.{:08x}.{drw}.0.0.00000000.0.{nrv}.{:02x}|po={}.{}.{:08x}.{}.{:01x}.{}.{:01x}.{}.{}.{:01x}.{:01x}.{}.{}.{}|qo={}.0.00000000.0.0.00000000.0.0.{}.0.00000000.0.0.00.0.{}|ev={ev}",
        bus.reset as u8,bus.selected as u8,bus.grant as u8,piv,pia,ppv,ppa,psv,psp,bus.address_strobe as u8,bus.read as u8,bus.byte_enable,bus.burst.blen(),bus.data_strobe as u8,bus.ack as u8,bus.err as u8,
        drv,dra,nrc,
        po.request as u8,pov,poa,popv,popa,posv,posp,po.address_strobe as u8,po.read as u8,po.byte_enable,po.burst.blen(),po.data_strobe as u8,po.ack as u8,po.err as u8,
        qo.reset as u8,qo.dma_request_ready as u8,qo.notification_ready as u8);
}

fn step(c:&mut u32,qic:&mut Qic,bus:BusToCard,dev:DeviceToQic,ev:&str){emit(*c,qic,bus,dev,ev);qic.clock(&bus,&dev);*c+=1;}
fn n(ch:u8)->DeviceToQic{DeviceToQic{notification_request:Some(NotificationRequest{channel:ch}),..Default::default()}}
fn nd(ch:u8)->DeviceToQic{DeviceToQic{notification_request:Some(NotificationRequest{channel:ch}),dma_request:Some(DmaRequest{direction:DmaDirection::HostToDevice,address:0x4400_0000,words:BurstWords::Four}),..Default::default()}}

fn main(){
 let mut q=Qic::new(); let mut c=0;
 step(&mut c,&mut q,BusToCard{reset:true,..Default::default()},Default::default(),"reset");
 // Notification wins over simultaneous DMA.
 step(&mut c,&mut q,Default::default(),nd(2),"manager_request");
 step(&mut c,&mut q,Default::default(),nd(2),"manager_request");
 step(&mut c,&mut q,BusToCard{grant:true,..Default::default()},nd(2),"manager_request");
 // address wait then ACK
 step(&mut c,&mut q,BusToCard{grant:true,..Default::default()},nd(2),"manager_address");
 step(&mut c,&mut q,BusToCard{grant:true,..Default::default()},nd(2),"manager_address");
 step(&mut c,&mut q,BusToCard{grant:true,ack:true,..Default::default()},nd(2),"manager_address");
 // data wait, then ACK; this alone completes.
 step(&mut c,&mut q,BusToCard{grant:true,..Default::default()},nd(2),"notification_data");
 step(&mut c,&mut q,BusToCard{grant:true,ack:true,..Default::default()},nd(2),"notification_data");
 // producer removes notification after seeing ready, DMA can then schedule.
 step(&mut c,&mut q,Default::default(),DeviceToQic{dma_request:Some(DmaRequest{direction:DmaDirection::HostToDevice,address:0x4400_0000,words:BurstWords::Four}),..Default::default()},"idle");

 // Address ERR: no ready; request is retained and retried.
 step(&mut c,&mut q,BusToCard{reset:true,..Default::default()},Default::default(),"reset");
 step(&mut c,&mut q,Default::default(),n(1),"manager_request");
 step(&mut c,&mut q,BusToCard{grant:true,..Default::default()},n(1),"manager_request");
 step(&mut c,&mut q,BusToCard{grant:true,err:true,..Default::default()},n(1),"fault");
 step(&mut c,&mut q,Default::default(),n(1),"manager_request");

 // Data ERR: address succeeds, data fails, then retry.
 step(&mut c,&mut q,BusToCard{reset:true,..Default::default()},Default::default(),"reset");
 step(&mut c,&mut q,Default::default(),n(3),"manager_request");
 step(&mut c,&mut q,BusToCard{grant:true,..Default::default()},n(3),"manager_request");
 step(&mut c,&mut q,BusToCard{grant:true,ack:true,..Default::default()},n(3),"manager_address");
 step(&mut c,&mut q,BusToCard{grant:true,err:true,..Default::default()},n(3),"fault");
 step(&mut c,&mut q,Default::default(),n(3),"manager_request");

 // BG loss during data: retry, no ready.
 step(&mut c,&mut q,BusToCard{reset:true,..Default::default()},Default::default(),"reset");
 step(&mut c,&mut q,Default::default(),n(0),"manager_request");
 step(&mut c,&mut q,BusToCard{grant:true,..Default::default()},n(0),"manager_request");
 step(&mut c,&mut q,BusToCard{grant:true,ack:true,..Default::default()},n(0),"manager_address");
 step(&mut c,&mut q,Default::default(),n(0),"fault");
 step(&mut c,&mut q,Default::default(),n(0),"manager_request");

 // Data timeout after successful address.
 step(&mut c,&mut q,BusToCard{reset:true,..Default::default()},Default::default(),"reset");
 step(&mut c,&mut q,Default::default(),n(2),"manager_request");
 step(&mut c,&mut q,BusToCard{grant:true,..Default::default()},n(2),"manager_request");
 step(&mut c,&mut q,BusToCard{grant:true,ack:true,..Default::default()},n(2),"manager_address");
 for _ in 0..256 { step(&mut c,&mut q,BusToCard{grant:true,..Default::default()},n(2),"notification_data"); }
 step(&mut c,&mut q,Default::default(),n(2),"manager_request");

 // Wrong producer channel at ACK must not get ready.
 step(&mut c,&mut q,BusToCard{reset:true,..Default::default()},Default::default(),"reset");
 step(&mut c,&mut q,Default::default(),n(1),"manager_request");
 step(&mut c,&mut q,BusToCard{grant:true,..Default::default()},n(1),"manager_request");
 step(&mut c,&mut q,BusToCard{grant:true,ack:true,..Default::default()},n(1),"manager_address");
 step(&mut c,&mut q,BusToCard{grant:true,ack:true,..Default::default()},n(2),"notification_data");
}

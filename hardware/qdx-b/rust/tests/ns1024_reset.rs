use std::collections::BTreeMap;
use qdx_a_model::{EndpointOut,QdxACommand};
use qdx_b_model::*;
use qli_model::{DmaCompletion,DmaDirection,DmaRequest,DmaStatus,DmaWord};

#[derive(Default)]
struct Host { mem:BTreeMap<u32,u32>, active:Option<DmaRequest>, moved:u8 }
impl Host {
    fn put(&mut self,a:u32,w:&[u32]){for(i,x)in w.iter().enumerate(){self.mem.insert(a+i as u32*4,*x);}}
    fn get(&self,a:u32,n:usize)->Vec<u32>{(0..n).map(|i|*self.mem.get(&(a+i as u32*4)).unwrap_or(&0)).collect()}
    fn step(&mut self,p:ProfileDmaIn)->ProfileDmaOut{
        let mut o=ProfileDmaOut::default();
        if self.active.is_none(){if let Some(r)=p.request{self.active=Some(r);self.moved=0;o.request_ready=true;}return o;}
        let r=self.active.unwrap();
        if self.moved<r.words.words(){match r.direction{
            DmaDirection::HostToDevice=>if p.read_ready{let a=r.address+u32::from(self.moved)*4;o.read=Some(DmaWord{data:*self.mem.get(&a).unwrap_or(&0)});self.moved+=1;},
            DmaDirection::DeviceToHost=>if let Some(w)=p.write{o.write_ready=true;let a=r.address+u32::from(self.moved)*4;self.mem.insert(a,w.data);self.moved+=1;},
        }} else if p.completion_ready{o.completion=Some(DmaCompletion{status:DmaStatus::Ok,words_completed:self.moved});self.active=None;self.moved=0;}
        o
    }
}
fn cmd(op:u8,ns:u16,tag:u32,lba:u32,data:u32)->QdxACommand{[u32::from(op)|(u32::from(ns)<<16),tag,lba,1,data,0,0,0]}
fn run(ep:&mut QdxBEndpoint,m:&mut FakeMedia,h:&mut Host,c:QdxACommand)->[u32;4]{
    let mut q=EndpointOut{command:Some(c),..EndpointOut::default()};let mut d=ProfileDmaOut::default();
    for _ in 0..30000{let(e,p)=ep.drive(q,d);if let Some(x)=e.completion{let ack=EndpointOut{completion_ready:true,..EndpointOut::default()};let(_,p2)=ep.drive(ack,ProfileDmaOut::default());let d2=h.step(p2);ep.clock(ack,d2,m);return x;}d=h.step(p);ep.clock(q,d,m);q.command=None;}
    panic!("timeout")
}
#[test]
fn namespace_2_moves_a_full_1024_byte_block_and_survives_qdx_reset(){
    let mut ep=QdxBEndpoint::new();let mut media=FakeMedia::new();let mut host=Host::default();
    let pattern:Vec<u32>=(0..256).map(|i|0xaa00_0000+i*4).collect();host.put(0x2000,&pattern);
    let w=run(&mut ep,&mut media,&mut host,cmd(OP_WRITE,2,1,9,0x2000));assert_eq!(w[1]&0xffff,u32::from(ST_SUCCESS));
    ep.clock(EndpointOut{reset:true,..EndpointOut::default()},ProfileDmaOut::default(),&mut media);
    let r=run(&mut ep,&mut media,&mut host,cmd(OP_READ,2,2,9,0x6000));assert_eq!(r[1]&0xffff,u32::from(ST_SUCCESS));
    assert_eq!(host.get(0x6000,256),pattern);
}
#[test]
fn nop_is_a_real_zero_data_command(){
    let mut ep=QdxBEndpoint::new();let mut media=FakeMedia::new();let mut host=Host::default();
    let c=[u32::from(OP_NOP),0x1234,0,0,0,0,0,0];let r=run(&mut ep,&mut media,&mut host,c);
    assert_eq!(r,[0x1234,0,0,0]);
}

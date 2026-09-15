#![forbid(unsafe_code)]

use std::collections::BTreeMap;
use plio_logical_model::{odd_parity_32, parity_matches, BusToCard, BurstWords, CardToBus, Space};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkerResult { WriteOk, Error }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum WorkerOp { Write { address:u32, byte_enable:u8, data:u32 } }

#[derive(Debug, Clone, PartialEq, Eq)]
enum State {
    Idle,
    WorkerAddress(WorkerOp),
    WorkerData(WorkerOp),
    Grant,
    DmaAddress { read:bool, total:u8, address:u32 },
    DmaData { read:bool, total:u8, beat:u8, address:u32 },
    NotificationAddress { channel:u8 },
    NotificationData { channel:u8 },
}

#[derive(Debug, Clone)]
pub struct MemoryPeer {
    state: State,
    worker_result: Option<WorkerResult>,
    memory: BTreeMap<u32,u32>,
    notifications: Vec<u8>,
    last_dma_address: Option<u32>,
    last_dma_burst: Option<BurstWords>,
}

impl Default for MemoryPeer { fn default()->Self { Self::new() } }

impl MemoryPeer {
    pub fn new()->Self {
        Self { state:State::Idle, worker_result:None, memory:BTreeMap::new(), notifications:Vec::new(), last_dma_address:None, last_dma_burst:None }
    }
    pub fn put_words(&mut self,address:u32,words:&[u32]) { for (i,w) in words.iter().enumerate(){self.memory.insert(address+i as u32*4,*w);} }
    pub fn words(&self,address:u32,count:usize)->Vec<u32> { (0..count).map(|i|*self.memory.get(&(address+i as u32*4)).unwrap_or(&0)).collect() }
    pub fn notifications(&self)->&[u8] { &self.notifications }
    pub fn last_dma_address(&self)->Option<u32> { self.last_dma_address }
    pub fn last_dma_burst(&self)->Option<BurstWords> { self.last_dma_burst }
    pub fn worker_result(&self)->Option<WorkerResult> { self.worker_result }

    pub fn start_worker_write(&mut self,address:u32,byte_enable:u8,data:u32) {
        assert!(matches!(self.state,State::Idle));
        self.worker_result=None;
        self.state=State::WorkerAddress(WorkerOp::Write{address,byte_enable,data});
    }

    pub fn bus_inputs(&self)->BusToCard {
        let mut b=BusToCard::default();
        match self.state {
            State::Idle=>{}
            State::WorkerAddress(WorkerOp::Write{address,byte_enable,..})=>{
                b.selected=true;b.ad=Some(address);b.par=Some(odd_parity_32(address));b.space=Some(Space::Worker);b.address_strobe=true;b.read=false;b.byte_enable=byte_enable;b.burst=BurstWords::One;
            }
            State::WorkerData(WorkerOp::Write{byte_enable,data,..})=>{
                b.selected=true;b.data_strobe=true;b.read=false;b.byte_enable=byte_enable;b.ad=Some(data);b.par=Some(odd_parity_32(data));
            }
            State::Grant=>b.grant=true,
            State::DmaAddress{..}=>{b.grant=true;b.ack=true;}
            State::DmaData{read,beat,address,..}=>{
                b.grant=true;b.ack=true;
                if read { let a=address+u32::from(beat)*4; let d=*self.memory.get(&a).unwrap_or(&0); b.ad=Some(d);b.par=Some(odd_parity_32(d)); }
            }
            State::NotificationAddress{..}=>{b.grant=true;b.ack=true;}
            State::NotificationData{..}=>{b.grant=true;b.ack=true;}
        }
        b
    }

    pub fn clock(&mut self,card:&CardToBus) {
        self.state=match self.state.clone() {
            State::Idle=>if card.request {State::Grant}else{State::Idle},
            State::WorkerAddress(op)=>{
                if card.err {self.worker_result=Some(WorkerResult::Error);State::Idle}
                else if card.ack {State::WorkerData(op)} else {State::WorkerAddress(op)}
            }
            State::WorkerData(op)=>{
                if card.err {self.worker_result=Some(WorkerResult::Error);State::Idle}
                else if card.ack {self.worker_result=Some(WorkerResult::WriteOk);State::Idle}
                else {State::WorkerData(op)}
            }
            State::Grant=>{
                if card.address_strobe {
                    let address=card.ad.unwrap_or(0);
                    let address_ok=card.ad.is_some() && card.par.is_some() && parity_matches(address,card.par.unwrap_or(0),0xf);
                    if !address_ok {State::Idle}
                    else { match card.space {
                        Some(Space::HostDma)=>{
                            self.last_dma_address=Some(address); self.last_dma_burst=Some(card.burst);
                            State::DmaAddress{read:card.read,total:card.burst.words(),address}
                        }
                        Some(Space::Controller)=>State::NotificationAddress{channel:(address/4) as u8},
                        _=>State::Idle,
                    }}
                } else if card.request {State::Grant}else{State::Idle}
            }
            State::DmaAddress{read,total,address}=>{
                if !card.request {State::Idle}else{State::DmaData{read,total,beat:0,address}}
            }
            State::DmaData{read,total,beat,address}=>{
                if !card.request {State::Idle}
                else if card.data_strobe {
                    if !read { if let Some(d)=card.ad { self.memory.insert(address+u32::from(beat)*4,d); } }
                    let n=beat+1;
                    if n==total {State::Idle}else{State::DmaData{read,total,beat:n,address}}
                } else {State::DmaData{read,total,beat,address}}
            }
            State::NotificationAddress{channel}=>if !card.request {State::Idle}else{State::NotificationData{channel}},
            State::NotificationData{channel}=>{
                if !card.request {State::Idle}
                else if card.data_strobe {self.notifications.push(channel);State::Idle}
                else {State::NotificationData{channel}}
            }
        };
    }
}

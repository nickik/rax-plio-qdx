#![forbid(unsafe_code)]

use plio_host_dma_model::{BindError, DmaDirection, DmaError, DmaHostM3, DmaState, MemoryRequest, MemoryResponse};
use plio_host_manager_model::{NotificationClaim, NotificationConfig, DEFAULT_NOTIFICATION_CONFIG};
use plio_host_model::{WorkerCompletion, WorkerMmioEngine, WorkerRequest, WorkerState};
use plio_logical_model::{parity_matches, BusToCard, CardToBus, Space, PLIO_TIMEOUT_CYCLES};

pub const SLOT_COUNT: usize = 8;
pub const NOTIFICATION_CHANNELS: usize = 4;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CoreRole { Idle, Worker, Grant, Notification, Dma }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CoreFault {
    BadManagerAddress, AddressParity, DataParity, RequestDropped, Timeout,
    DmaProtection, DmaParity, DmaMemory, DmaReset, DmaRevoked,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CoreDebug {
    pub role: CoreRole,
    pub active_slot: Option<u8>,
    pub worker_state: WorkerState,
    pub dma_state: DmaState,
    pub arbitration_cursor: u8,
    pub wait_cycles: u16,
    pub dma_acknowledged: u8,
    pub memory_active: bool,
    pub last_fault: Option<CoreFault>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct MemoryInput { pub request_ready: bool, pub response: Option<MemoryResponse> }

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CoreInput {
    pub cards: [CardToBus; SLOT_COUNT],
    pub worker_request: Option<WorkerRequest>,
    pub memory: MemoryInput,
    pub reset: bool,
}
impl Default for CoreInput {
    fn default() -> Self { Self { cards:[CardToBus::default();SLOT_COUNT], worker_request:None, memory:MemoryInput::default(), reset:false } }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CoreOutput {
    pub buses: [BusToCard; SLOT_COUNT],
    pub worker_completion: Option<WorkerCompletion>,
    pub memory_request: Option<MemoryRequest>,
    pub dma_completion: Option<Result<u8,DmaError>>,
    pub notification_claim: Option<NotificationClaim>,
    pub debug: CoreDebug,
}

#[derive(Debug, Clone)]
pub struct PLIOHostCore {
    worker: WorkerMmioEngine,
    dma: DmaHostM3,
    role: CoreRole,
    active_slot: Option<u8>,
    notification_channel: u8,
    cursor: u8,
    wait_cycles: u16,
    queued_worker: Option<WorkerRequest>,
    worker_completion: Option<WorkerCompletion>,
    dma_completion: Option<Result<u8,DmaError>>,
    dma_direction: Option<DmaDirection>,
    dma_address_pending: Option<(bool,DmaDirection)>,
    write_ack_pending: bool,
    dma_wait_request_drop: bool,
    last_fault: Option<CoreFault>,
    notification_pending: [[bool;NOTIFICATION_CHANNELS];SLOT_COUNT],
    notification_payload: [[u32;NOTIFICATION_CHANNELS];SLOT_COUNT],
    notification_config: [[NotificationConfig;NOTIFICATION_CHANNELS];SLOT_COUNT],
}

impl Default for PLIOHostCore { fn default()->Self { Self::new() } }
impl PLIOHostCore {
    pub fn new()->Self {
        Self {
            worker:WorkerMmioEngine::new(), dma:DmaHostM3::new(), role:CoreRole::Idle, active_slot:None,
            notification_channel:0, cursor:0, wait_cycles:0, queued_worker:None, worker_completion:None,
            dma_completion:None, dma_direction:None, dma_address_pending:None, write_ack_pending:false,
            dma_wait_request_drop:false, last_fault:None,
            notification_pending:[[false;NOTIFICATION_CHANNELS];SLOT_COUNT], notification_payload:[[0;NOTIFICATION_CHANNELS];SLOT_COUNT],
            notification_config:[[DEFAULT_NOTIFICATION_CONFIG;NOTIFICATION_CHANNELS];SLOT_COUNT],
        }
    }
    pub fn bind_dma(&mut self,slot:u8,channel:u8,base:u32,length:u32,device_read:bool,device_write:bool)->Result<u8,BindError>{self.dma.bind(slot,channel,base,length,device_read,device_write)}
    pub fn revoke_dma(&mut self,slot:u8,channel:u8)->Result<bool,BindError>{self.dma.revoke(slot,channel)}
    pub fn dma_generation(&self,slot:u8,channel:u8)->Option<u8>{self.dma.capability(slot,channel).map(|c|c.generation)}
    pub fn set_notification_config(&mut self,slot:u8,channel:u8,config:NotificationConfig){self.notification_config[slot as usize][channel as usize]=config;}
    pub fn notification_pending(&self,slot:u8,channel:u8)->bool{self.notification_pending[slot as usize][channel as usize]}
    pub fn notification_payload(&self,slot:u8,channel:u8)->u32{self.notification_payload[slot as usize][channel as usize]}
    pub fn peek_notification(&self)->Option<NotificationClaim>{
        for s in 0..SLOT_COUNT { for ch in 0..NOTIFICATION_CHANNELS { let cfg=self.notification_config[s][ch]; if self.notification_pending[s][ch]&&cfg.enabled&&!cfg.masked{return Some(NotificationClaim{slot:s as u8,channel:ch as u8,payload:self.notification_payload[s][ch],class:cfg.class});}}} None
    }
    pub fn claim_notification(&mut self)->Option<NotificationClaim>{let c=self.peek_notification()?;self.notification_pending[c.slot as usize][c.channel as usize]=false;Some(c)}
    fn choose_request(&self,cards:&[CardToBus;SLOT_COUNT])->Option<u8>{for o in 0..SLOT_COUNT{let s=((self.cursor as usize+o)&7)as u8;if cards[s as usize].request{return Some(s);}}None}
    fn selected_card(&self,cards:&[CardToBus;SLOT_COUNT])->CardToBus{self.active_slot.map(|s|cards[s as usize]).unwrap_or_default()}
    fn finish_card_transaction(&mut self){if let Some(s)=self.active_slot{self.cursor=(s+1)&7;}self.role=CoreRole::Idle;self.active_slot=None;self.wait_cycles=0;self.dma_direction=None;self.dma_address_pending=None;self.write_ack_pending=false;self.dma_wait_request_drop=false;}
    fn finish_successful_dma(&mut self,c:Result<u8,DmaError>){self.dma_completion=Some(c);self.dma_wait_request_drop=true;self.wait_cycles=0;}
    fn fault_from_dma(e:DmaError)->CoreFault{match e{DmaError::Protection=>CoreFault::DmaProtection,DmaError::MemoryFault=>CoreFault::DmaMemory,DmaError::Parity=>CoreFault::DmaParity,DmaError::Timeout=>CoreFault::Timeout,DmaError::Reset=>CoreFault::DmaReset,DmaError::Revoked=>CoreFault::DmaRevoked}}
    fn decode_notification(card:CardToBus)->Result<u8,CoreFault>{let ad=card.ad.ok_or(CoreFault::BadManagerAddress)?;let par=card.par.ok_or(CoreFault::AddressParity)?;if !parity_matches(ad,par,0xf){return Err(CoreFault::AddressParity);}if card.space!=Some(Space::Controller)||card.read||card.byte_enable!=0xf||card.burst.words()!=1||ad&3!=0||ad>12{return Err(CoreFault::BadManagerAddress);}Ok((ad/4)as u8)}
    fn decode_dma(card:CardToBus)->Result<(u32,u8,DmaDirection),CoreFault>{let ad=card.ad.ok_or(CoreFault::BadManagerAddress)?;let par=card.par.ok_or(CoreFault::AddressParity)?;if !parity_matches(ad,par,0xf){return Err(CoreFault::AddressParity);}if card.space!=Some(Space::HostDma)||card.byte_enable!=0xf||ad&3!=0{return Err(CoreFault::BadManagerAddress);}Ok((ad,card.burst.words(),if card.read{DmaDirection::DeviceRead}else{DmaDirection::DeviceWrite}))}

    pub fn step(&mut self,input:CoreInput)->CoreOutput{
        if let Some(r)=input.worker_request{if self.queued_worker.is_none(){self.queued_worker=Some(r);}}
        let mut buses=[BusToCard::default();SLOT_COUNT];
        let mut memory_request=self.dma.memory_request();
        if input.reset{
            for b in &mut buses{b.reset=true;}
            self.worker.clock(true,self.selected_card(&input.cards)); self.dma.reset();
            self.worker_completion=self.worker.take_completion(); self.dma_completion=self.dma.take_completion();
            self.role=CoreRole::Idle;self.active_slot=None;self.queued_worker=None;self.cursor=0;self.wait_cycles=0;self.dma_direction=None;self.dma_address_pending=None;self.write_ack_pending=false;self.dma_wait_request_drop=false;self.last_fault=None;
            self.notification_pending=[[false;NOTIFICATION_CHANNELS];SLOT_COUNT];self.notification_payload=[[0;NOTIFICATION_CHANNELS];SLOT_COUNT];memory_request=None;return self.output(buses,memory_request);
        }
        match self.role{
            CoreRole::Idle=>{if let Some(r)=self.queued_worker.take(){if self.worker.start(r).is_ok(){self.role=CoreRole::Worker;self.active_slot=Some(r.slot);}}else if let Some(s)=self.choose_request(&input.cards){self.role=CoreRole::Grant;self.active_slot=Some(s);self.wait_cycles=0;self.last_fault=None;}},
            CoreRole::Worker=>{let s=self.active_slot.unwrap();buses[s as usize]=self.worker.drive(false).bus;self.worker.clock(false,input.cards[s as usize]);if let Some(c)=self.worker.take_completion(){self.worker_completion=Some(c);self.role=CoreRole::Idle;self.active_slot=None;}},
            CoreRole::Grant=>{let s=self.active_slot.unwrap();let card=input.cards[s as usize];buses[s as usize].grant=true;
                if let Some((valid,dir))=self.dma_address_pending{
                    if !card.request{self.last_fault=Some(CoreFault::RequestDropped);self.finish_card_transaction();}
                    else if valid{buses[s as usize].ack=true;self.dma_address_pending=None;self.dma_direction=Some(dir);self.role=CoreRole::Dma;self.wait_cycles=0;}
                    else{buses[s as usize].err=true;self.dma_completion=Some(Err(DmaError::Protection));self.last_fault=Some(CoreFault::DmaProtection);self.finish_card_transaction();}
                }else if !card.request{self.last_fault=Some(CoreFault::RequestDropped);self.finish_card_transaction();}
                else if card.address_strobe{match card.space{
                    Some(Space::Controller)=>match Self::decode_notification(card){Ok(ch)=>{buses[s as usize].ack=true;self.notification_channel=ch;self.role=CoreRole::Notification;self.wait_cycles=0;}Err(f)=>{buses[s as usize].err=true;self.last_fault=Some(f);self.finish_card_transaction();}},
                    Some(Space::HostDma)=>match Self::decode_dma(card){Ok((a,w,d))=>{let ok=self.dma.start(s,a,w,d).is_ok();self.dma_address_pending=Some((ok,d));if !ok{self.last_fault=Some(CoreFault::DmaProtection);}self.wait_cycles=0;}Err(f)=>{buses[s as usize].err=true;self.last_fault=Some(f);self.finish_card_transaction();}},
                    _=>{buses[s as usize].err=true;self.last_fault=Some(CoreFault::BadManagerAddress);self.finish_card_transaction();}}}
                else if self.wait_cycles+1>=PLIO_TIMEOUT_CYCLES{buses[s as usize].err=true;self.last_fault=Some(CoreFault::Timeout);self.finish_card_transaction();}else{self.wait_cycles+=1;}
            },
            CoreRole::Notification=>{let s=self.active_slot.unwrap();let card=input.cards[s as usize];buses[s as usize].grant=true;if !card.request{self.last_fault=Some(CoreFault::RequestDropped);self.finish_card_transaction();}else if card.data_strobe{match(card.ad,card.par){(Some(data),Some(par))if card.byte_enable==0xf&&parity_matches(data,par,0xf)=>{buses[s as usize].ack=true;self.notification_pending[s as usize][self.notification_channel as usize]=true;self.notification_payload[s as usize][self.notification_channel as usize]=data;self.finish_card_transaction();}_=>{buses[s as usize].err=true;self.last_fault=Some(CoreFault::DataParity);self.finish_card_transaction();}}}else if self.wait_cycles+1>=PLIO_TIMEOUT_CYCLES{buses[s as usize].err=true;self.last_fault=Some(CoreFault::Timeout);self.finish_card_transaction();}else{self.wait_cycles+=1;}},
            CoreRole::Dma=>{let s=self.active_slot.unwrap();let card=input.cards[s as usize];buses[s as usize].grant=true;
                if self.dma_wait_request_drop{
                    if !card.request{self.finish_card_transaction();}
                    else if self.wait_cycles+1>=PLIO_TIMEOUT_CYCLES{buses[s as usize].err=true;self.last_fault=Some(CoreFault::Timeout);self.finish_card_transaction();}
                    else{self.wait_cycles+=1;}
                }else if !card.request{self.last_fault=Some(CoreFault::RequestDropped);self.dma.reset();self.dma_completion=self.dma.take_completion();self.finish_card_transaction();}
                else if self.write_ack_pending{buses[s as usize].ack=true;self.write_ack_pending=false;if let Some(c)=self.dma.take_completion(){match c{Ok(_)=>self.finish_successful_dma(c),Err(e)=>{self.last_fault=Some(Self::fault_from_dma(e));self.dma_completion=Some(c);buses[s as usize].err=true;self.finish_card_transaction();}}}}
                else{match self.dma.debug().state{
                    DmaState::AwaitDeviceWrite=>{if card.data_strobe{match(card.ad,card.par){(Some(data),Some(par))=>if let Err(e)=self.dma.offer_device_write(data,par){self.last_fault=Some(Self::fault_from_dma(e));},_=>self.last_fault=Some(CoreFault::DmaParity)}}else{self.dma.wait_cycle();}},
                    DmaState::MemRequest=>{memory_request=self.dma.memory_request();if input.memory.request_ready{self.dma.memory_request_accepted();}else{self.dma.wait_cycle();}},
                    DmaState::MemResponse=>{if let Some(resp)=input.memory.response{let write=self.dma_direction==Some(DmaDirection::DeviceWrite);self.dma.memory_response(resp);if write&&resp==MemoryResponse::WriteDone{self.write_ack_pending=true;}}else{self.dma.wait_cycle();}},
                    DmaState::DeviceReadReady=>{if card.data_strobe{if let Some((data,par))=self.dma.device_read_data(){buses[s as usize].ack=true;buses[s as usize].ad=Some(data);buses[s as usize].par=Some(par);self.dma.acknowledge_device_read();if let Some(c)=self.dma.take_completion(){match c{Ok(_)=>self.finish_successful_dma(c),Err(e)=>{self.last_fault=Some(Self::fault_from_dma(e));self.dma_completion=Some(c);buses[s as usize].err=true;self.finish_card_transaction();}}}}}else{self.dma.wait_cycle();}},
                    DmaState::Idle=>{if let Some(c)=self.dma.take_completion(){match c{Ok(_)=>self.finish_successful_dma(c),Err(e)=>{self.last_fault=Some(Self::fault_from_dma(e));self.dma_completion=Some(c);buses[s as usize].err=true;self.finish_card_transaction();}}}}
                }
                if self.role==CoreRole::Dma&&!self.dma_wait_request_drop{if let Some(Err(e))=self.dma.completion(){self.last_fault=Some(Self::fault_from_dma(e));buses[s as usize].err=true;self.dma_completion=self.dma.take_completion();self.finish_card_transaction();}}
            }}
        }
        self.output(buses,memory_request)
    }
    fn output(&self,buses:[BusToCard;SLOT_COUNT],memory_request:Option<MemoryRequest>)->CoreOutput{CoreOutput{buses,worker_completion:self.worker_completion,memory_request,dma_completion:self.dma_completion,notification_claim:self.peek_notification(),debug:self.debug()}}
    pub fn take_worker_completion(&mut self)->Option<WorkerCompletion>{self.worker_completion.take()}
    pub fn take_dma_completion(&mut self)->Option<Result<u8,DmaError>>{self.dma_completion.take()}
    pub fn debug(&self)->CoreDebug{let d=self.dma.debug();CoreDebug{role:self.role,active_slot:self.active_slot,worker_state:self.worker.debug().state,dma_state:d.state,arbitration_cursor:self.cursor,wait_cycles:if self.role==CoreRole::Worker{self.worker.debug().wait_cycles}else if self.role==CoreRole::Dma&&self.dma_wait_request_drop{self.wait_cycles}else if self.role==CoreRole::Dma{d.wait_cycles}else{self.wait_cycles},dma_acknowledged:d.acknowledged_beats,memory_active:matches!(d.state,DmaState::MemRequest|DmaState::MemResponse),last_fault:self.last_fault}}
}

#[cfg(test)] mod tests{
    use super::*;use plio_host_model::{WorkerResult,WorkerWidth};use plio_logical_model::odd_parity_32;
    #[test]fn worker_owns_bus_until_completion(){let mut c=PLIOHostCore::new();let r=WorkerRequest::read(2,0x100,WorkerWidth::U32).unwrap();c.step(CoreInput{worker_request:Some(r),..Default::default()});let mut i=CoreInput::default();i.cards[5].request=true;let o=c.step(i);assert!(o.buses[2].selected);assert!(!o.buses[5].grant);i.cards[2]=CardToBus{ack:true,..Default::default()};c.step(i);let v=0x12345678;i.cards[2]=CardToBus{ack:true,ad:Some(v),par:Some(odd_parity_32(v)),..Default::default()};c.step(i);assert_eq!(c.take_worker_completion(),Some(Ok(WorkerResult::Read(v))));}
    #[test]fn successful_dma_drain_blocks_queued_worker_until_request_drops(){let mut c=PLIOHostCore::new();let r=WorkerRequest::read(2,0x100,WorkerWidth::U32).unwrap();c.role=CoreRole::Dma;c.active_slot=Some(2);c.dma_wait_request_drop=true;c.dma_completion=Some(Ok(1));c.queued_worker=Some(r);let mut i=CoreInput::default();i.cards[2].request=true;let o=c.step(i);assert_eq!(o.debug.role,CoreRole::Dma);assert!(o.buses[2].grant);assert!(!o.buses[2].selected);i.cards[2].request=false;let o=c.step(i);assert_eq!(o.debug.role,CoreRole::Idle);let o=c.step(CoreInput::default());assert_eq!(o.debug.role,CoreRole::Worker);}
}

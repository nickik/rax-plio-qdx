#![forbid(unsafe_code)]

use plio_logical_model::{BusToCard, CardToBus, Space};
use plio_tx_model::{BackplaneDrive, BackplaneSample, PlioTx, PtiDirection, QicPtiDrive};
use pti_model::{encode_control, encode_data_beat, ControlImage, Token, TokenKind};
use qdx_a_model::{EndpointIn, EndpointOut, QdxACommand, QdxACompletion};

pub struct ValidationEndpoint {
    pending: Option<QdxACompletion>,
    last_command0: u32,
}

impl Default for ValidationEndpoint {
    fn default() -> Self { Self::new() }
}

impl ValidationEndpoint {
    pub const fn new() -> Self {
        Self { pending: None, last_command0: 0 }
    }

    pub fn drive(&self, from_qdx: EndpointOut) -> EndpointIn {
        EndpointIn {
            command_ready: self.pending.is_none() && !from_qdx.reset,
            completion: self.pending,
        }
    }

    pub fn clock(&mut self, from_qdx: EndpointOut) {
        if from_qdx.reset {
            self.pending = None;
            self.last_command0 = 0;
            return;
        }
        if let Some(cmd) = from_qdx.command {
            if self.pending.is_none() {
                self.last_command0 = cmd[0];
                self.pending = Some(make_completion(cmd));
            }
        }
        if from_qdx.completion_ready && self.pending.is_some() {
            self.pending = None;
        }
    }

    pub const fn last_command0(&self) -> u32 { self.last_command0 }
}

pub fn make_completion(cmd: QdxACommand) -> QdxACompletion {
    [
        0xc001_0000 | (cmd[0] & 0x0000_ffff),
        cmd[1],
        cmd[6],
        cmd[7],
    ]
}

fn idle() -> Token { Token::new(TokenKind::Idle, 0, 0).expect("idle token") }

fn qdrive(token: Token) -> QicPtiDrive {
    QicPtiDrive { token, ..QicPtiDrive::default() }
}

fn clock_slot(tx: &mut PlioTx, q: QicPtiDrive, bus: BackplaneSample) {
    let (_, obs) = tx.drive(false, q, bus);
    assert!(!obs.protocol_fault, "PTI protocol fault before clock: {obs:?}");
    tx.clock(false, q, bus);
}

fn turn_qic_to_tx(tx: &mut PlioTx) {
    clock_slot(tx, qdrive(idle()), BackplaneSample::default());
}

pub fn through_tx(tx: &mut PlioTx, card: CardToBus) -> BackplaneDrive {
    turn_qic_to_tx(tx);

    let has_control = card.space.is_some() || card.address_strobe || card.data_strobe;
    let has_data = card.ad.is_some() || card.par.is_some();
    let needs_drive = has_control || has_data;

    if needs_drive {
        let control = ControlImage {
            space: card.space.unwrap_or(Space::Worker) as u8,
            address_strobe: card.address_strobe,
            read: card.read,
            byte_enable: card.byte_enable,
            burst_len: card.burst.blen(),
            data_strobe: card.data_strobe,
            drive_ad_par: has_data,
            drive_control: has_control,
        };
        clock_slot(tx, qdrive(encode_control(control).expect("control token")), BackplaneSample::default());
    }
    if let (Some(ad), Some(par)) = (card.ad, card.par) {
        for token in encode_data_beat(ad, par).expect("data beat") {
            clock_slot(tx, qdrive(token), BackplaneSample::default());
        }
    }
    clock_slot(tx, qdrive(idle()), BackplaneSample::default());

    let q = QicPtiDrive {
        token: idle(),
        drive_enable: needs_drive,
        response_enable: card.ack || card.err,
        response_ack: card.ack,
        response_err: card.err,
        bus_request: card.request,
        ..QicPtiDrive::default()
    };
    let (bp, obs) = tx.drive(false, q, BackplaneSample::default());
    assert!(!obs.protocol_fault, "legal card image caused PLIO-TX fault");
    tx.clock(false, q, BackplaneSample::default());
    bp
}

fn sample_ad(tx: &mut PlioTx, ad: u32, par: u8) -> (u32, u8) {
    let bus = BackplaneSample { ad, par, ..BackplaneSample::default() };
    let turn = QicPtiDrive { direction: PtiDirection::TxToQic, token: idle(), ..QicPtiDrive::default() };
    clock_slot(tx, turn, bus);

    let loq = QicPtiDrive {
        direction: PtiDirection::TxToQic,
        token: Token::new(TokenKind::DataLo, 0, 0).expect("lo select"),
        ..QicPtiDrive::default()
    };
    let (_, lo) = tx.drive(false, loq, bus);
    tx.clock(false, loq, bus);
    let lot = lo.rx_token.expect("low receive bank");

    let hiq = QicPtiDrive {
        direction: PtiDirection::TxToQic,
        token: Token::new(TokenKind::DataHi, 0, 0).expect("hi select"),
        ..QicPtiDrive::default()
    };
    let (_, hi) = tx.drive(false, hiq, bus);
    tx.clock(false, hiq, bus);
    let hit = hi.rx_token.expect("high receive bank");
    (
        u32::from(lot.data()) | (u32::from(hit.data()) << 16),
        lot.parity() | (hit.parity() << 2),
    )
}

pub fn physicalize_bus(tx: &mut PlioTx, mut bus: BusToCard) -> BusToCard {
    if let (Some(ad), Some(par)) = (bus.ad, bus.par) {
        let (sampled, sampled_par) = sample_ad(tx, ad, par);
        bus.ad = Some(sampled);
        bus.par = Some(sampled_par);
    }
    bus
}

pub fn card_from_backplane(bp: BackplaneDrive) -> CardToBus {
    let mut card = CardToBus { request: bp.request, ..CardToBus::default() };
    if let Some((ad, par)) = bp.ad_par {
        card.ad = Some(ad);
        card.par = Some(par);
    }
    if let Some(control) = bp.control {
        card.space = match control.space {
            0 => Some(Space::Worker),
            1 => Some(Space::HostDma),
            2 => Some(Space::Controller),
            _ => Some(Space::Reserved),
        };
        card.address_strobe = control.address_strobe;
        card.read = control.read;
        card.byte_enable = control.byte_enable;
        card.burst = plio_logical_model::BurstWords::from_blen(control.burst_len).expect("valid BLEN");
        card.data_strobe = control.data_strobe;
    }
    if let Some((ack, err)) = bp.response {
        card.ack = ack;
        card.err = err;
    }
    card
}

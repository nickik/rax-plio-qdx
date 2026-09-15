#![forbid(unsafe_code)]

use pti_model::{decode_control, ControlImage, Token, TokenKind};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum PtiDirection {
    QicToTx = 0,
    TxToQic = 1,
}

impl Default for PtiDirection {
    fn default() -> Self { Self::QicToTx }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct BackplaneControl {
    pub space: u8,
    pub address_strobe: bool,
    pub read: bool,
    pub byte_enable: u8,
    pub burst_len: u8,
    pub data_strobe: bool,
}

impl BackplaneControl {
    pub fn to_receive_image(self) -> ControlImage {
        ControlImage {
            space: self.space,
            address_strobe: self.address_strobe,
            read: self.read,
            byte_enable: self.byte_enable,
            burst_len: self.burst_len,
            data_strobe: self.data_strobe,
            drive_ad_par: false,
            drive_control: false,
        }
    }

    pub fn from_drive_image(image: ControlImage) -> Self {
        Self {
            space: image.space,
            address_strobe: image.address_strobe,
            read: image.read,
            byte_enable: image.byte_enable,
            burst_len: image.burst_len,
            data_strobe: image.data_strobe,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct BackplaneSample {
    pub ad: u32,
    pub par: u8,
    pub control: BackplaneControl,
    pub ack: bool,
    pub err: bool,
    pub selected: bool,
    pub grant: bool,

    /// Simulation-only ownership hints. They detect overlap; they do not model
    /// analog resolution or PLIO protocol policy.
    pub external_ad_par_drive: bool,
    pub external_control_drive: bool,
    pub external_response_drive: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct QicPtiDrive {
    pub direction: PtiDirection,
    /// `kind` is always meaningful. `ptd` is consumed only in QIC_TO_TX.
    pub token: Token,
    pub drive_enable: bool,
    pub response_enable: bool,
    pub response_ack: bool,
    pub response_err: bool,
    pub bus_request: bool,
}

impl Default for QicPtiDrive {
    fn default() -> Self {
        Self {
            direction: PtiDirection::QicToTx,
            token: Token { kind: TokenKind::Idle, ptd: 0 },
            drive_enable: false,
            response_enable: false,
            response_ack: false,
            response_err: false,
            bus_request: false,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct BackplaneDrive {
    pub ad_par: Option<(u32, u8)>,
    pub control: Option<BackplaneControl>,
    pub response: Option<(bool, bool)>,
    pub request: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct PtiObserve {
    pub rx_token: Option<Token>,
    pub sample_ack: bool,
    pub sample_err: bool,
    pub sample_selected: bool,
    pub sample_grant: bool,
    pub protocol_fault: bool,
    pub contention: bool,
}

#[derive(Debug, Clone)]
pub struct PlioTx {
    out_control: Option<ControlImage>,
    out_data: Option<(u32, u8)>,
    out_low_pending: Option<(u16, u8)>,
    in_sample: Option<(u32, u8)>,
    in_low_pending: bool,
    direction: Option<PtiDirection>,
    previous_slot_idle: bool,
    drive_active: bool,
    protocol_fault: bool,
    contention: bool,
}

impl Default for PlioTx {
    fn default() -> Self { Self::new() }
}

impl PlioTx {
    pub fn new() -> Self {
        Self {
            out_control: None,
            out_data: None,
            out_low_pending: None,
            in_sample: None,
            in_low_pending: false,
            direction: None,
            previous_slot_idle: true,
            drive_active: false,
            protocol_fault: false,
            contention: false,
        }
    }

    /// Combinational image for the current PTI slot. Slot state is committed by
    /// `clock`; therefore a just-presented CONTROL or DATA_HI affects later slots.
    pub fn drive(
        &self,
        reset: bool,
        qic: QicPtiDrive,
        bus: BackplaneSample,
    ) -> (BackplaneDrive, PtiObserve) {
        if reset {
            return (BackplaneDrive::default(), PtiObserve::default());
        }

        let direction_illegal = self.direction.is_some()
            && qic.token.kind != TokenKind::Idle
            && self.direction != Some(qic.direction);
        let drive_rise_illegal = qic.drive_enable
            && !self.drive_active
            && !self.previous_slot_idle;
        let response_illegal = qic.response_enable && qic.response_ack && qic.response_err;
        let token_illegal = self.token_illegal(qic, direction_illegal);

        let mut backplane = BackplaneDrive::default();
        backplane.request = qic.bus_request;

        let mut missing_control = false;
        let mut missing_data = false;
        let effective_drive = qic.drive_enable && !drive_rise_illegal;

        if effective_drive {
            match self.out_control {
                Some(control) => {
                    if control.drive_control {
                        backplane.control = Some(BackplaneControl::from_drive_image(control));
                    }
                    if control.drive_ad_par {
                        match self.out_data {
                            Some((ad, par)) => backplane.ad_par = Some((ad, par)),
                            None => missing_data = true,
                        }
                    }
                }
                None => missing_control = true,
            }
        }

        if qic.response_enable && !response_illegal {
            backplane.response = Some((qic.response_ack, qic.response_err));
        }

        let contention_now = (backplane.ad_par.is_some() && bus.external_ad_par_drive)
            || (backplane.control.is_some() && bus.external_control_drive)
            || (backplane.response.is_some() && bus.external_response_drive);

        let rx_token = if direction_illegal || qic.direction != PtiDirection::TxToQic {
            None
        } else {
            self.receive_token(qic.token.kind, bus)
        };

        (
            backplane,
            PtiObserve {
                rx_token,
                sample_ack: if qic.response_enable { false } else { bus.ack },
                sample_err: if qic.response_enable { false } else { bus.err },
                sample_selected: bus.selected,
                sample_grant: bus.grant,
                protocol_fault: self.protocol_fault
                    || direction_illegal
                    || drive_rise_illegal
                    || response_illegal
                    || token_illegal
                    || missing_control
                    || missing_data,
                contention: self.contention || contention_now,
            },
        )
    }

    /// Commit one PT_STB slot.
    pub fn clock(&mut self, reset: bool, qic: QicPtiDrive, bus: BackplaneSample) {
        if reset {
            *self = Self::new();
            return;
        }

        let previous_slot_idle = self.previous_slot_idle;
        let previous_drive_active = self.drive_active;
        let (_, observe) = self.drive(reset, qic, bus);
        let direction_illegal = self.direction.is_some()
            && qic.token.kind != TokenKind::Idle
            && self.direction != Some(qic.direction);

        self.protocol_fault = observe.protocol_fault;
        self.contention = observe.contention;

        if qic.token.kind == TokenKind::Idle {
            // IDLE is the only legal direction-change slot. It also abandons
            // any incomplete halfword pair rather than carrying it across a
            // turnaround.
            if self.out_low_pending.is_some() || self.in_low_pending {
                self.protocol_fault = true;
            }
            self.out_low_pending = None;
            self.in_low_pending = false;
            self.in_sample = None;
            self.direction = Some(qic.direction);
            if qic.direction == PtiDirection::QicToTx && qic.token.ptd != 0 {
                self.protocol_fault = true;
            }
        } else if direction_illegal {
            self.out_low_pending = None;
            self.in_low_pending = false;
            self.in_sample = None;
        } else {
            if self.direction.is_none() {
                self.direction = Some(qic.direction);
            }
            match qic.direction {
                PtiDirection::QicToTx => self.clock_qic_to_tx(qic.token),
                PtiDirection::TxToQic => self.clock_tx_to_qic(qic.token.kind, bus),
            }
        }

        self.previous_slot_idle = qic.token.kind == TokenKind::Idle;
        self.drive_active = if !qic.drive_enable {
            false
        } else if previous_drive_active {
            true
        } else {
            previous_slot_idle
        };
    }

    /// One complete logical PTI slot: observe first, then commit state.
    pub fn step(
        &mut self,
        reset: bool,
        qic: QicPtiDrive,
        bus: BackplaneSample,
    ) -> (BackplaneDrive, PtiObserve) {
        let out = self.drive(reset, qic, bus);
        self.clock(reset, qic, bus);
        out
    }

    pub fn committed_data(&self) -> Option<(u32, u8)> { self.out_data }
    pub fn committed_control(&self) -> Option<ControlImage> { self.out_control }
    pub fn protocol_fault(&self) -> bool { self.protocol_fault }
    pub fn contention(&self) -> bool { self.contention }

    fn receive_token(&self, kind: TokenKind, bus: BackplaneSample) -> Option<Token> {
        match kind {
            TokenKind::Idle => None,
            TokenKind::Control => {
                let bits = bus.control.to_receive_image().pack().ok()?;
                Token::new(TokenKind::Control, bits, 0).ok()
            }
            TokenKind::DataLo => {
                Token::new(TokenKind::DataLo, bus.ad as u16, bus.par & 0x3).ok()
            }
            TokenKind::DataHi => {
                let (ad, par) = self.in_sample?;
                if !self.in_low_pending { return None; }
                Token::new(TokenKind::DataHi, (ad >> 16) as u16, (par >> 2) & 0x3).ok()
            }
        }
    }

    fn token_illegal(&self, qic: QicPtiDrive, direction_illegal: bool) -> bool {
        if direction_illegal { return true; }

        if qic.token.kind == TokenKind::Idle {
            return self.out_low_pending.is_some()
                || self.in_low_pending
                || (qic.direction == PtiDirection::QicToTx && qic.token.ptd != 0);
        }

        match qic.direction {
            PtiDirection::QicToTx => {
                if qic.token.ptd & !0x3ffff != 0 { return true; }
                match qic.token.kind {
                    TokenKind::Idle => unreachable!(),
                    TokenKind::Control => {
                        self.out_low_pending.is_some() || decode_control(qic.token).is_err()
                    }
                    TokenKind::DataLo => self.out_low_pending.is_some(),
                    TokenKind::DataHi => self.out_low_pending.is_none(),
                }
            }
            PtiDirection::TxToQic => match qic.token.kind {
                TokenKind::Idle => unreachable!(),
                TokenKind::Control => self.in_low_pending,
                TokenKind::DataLo => self.in_low_pending,
                TokenKind::DataHi => !self.in_low_pending || self.in_sample.is_none(),
            },
        }
    }

    fn clock_qic_to_tx(&mut self, token: Token) {
        if self.out_low_pending.is_some() && token.kind != TokenKind::DataHi {
            self.protocol_fault = true;
            self.out_low_pending = None;
        }

        match token.kind {
            TokenKind::Idle => unreachable!(),
            TokenKind::Control => match decode_control(token) {
                Ok(image) => self.out_control = Some(image),
                Err(_) => self.protocol_fault = true,
            },
            TokenKind::DataLo => {
                self.out_low_pending = Some((token.data(), token.parity()));
            }
            TokenKind::DataHi => match self.out_low_pending.take() {
                Some((lo, lo_par)) => {
                    let ad = u32::from(lo) | (u32::from(token.data()) << 16);
                    let par = lo_par | (token.parity() << 2);
                    self.out_data = Some((ad, par));
                }
                None => self.protocol_fault = true,
            },
        }
    }

    fn clock_tx_to_qic(&mut self, kind: TokenKind, bus: BackplaneSample) {
        if self.in_low_pending && kind != TokenKind::DataHi {
            self.protocol_fault = true;
            self.in_low_pending = false;
            self.in_sample = None;
        }

        match kind {
            TokenKind::Idle => unreachable!(),
            TokenKind::Control => {}
            TokenKind::DataLo => {
                self.in_sample = Some((bus.ad, bus.par & 0x0f));
                self.in_low_pending = true;
            }
            TokenKind::DataHi => {
                if self.in_low_pending && self.in_sample.is_some() {
                    self.in_low_pending = false;
                } else {
                    self.protocol_fault = true;
                    self.in_sample = None;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pti_model::{encode_control, encode_data_beat};

    fn idle(direction: PtiDirection) -> QicPtiDrive {
        QicPtiDrive { direction, ..QicPtiDrive::default() }
    }

    #[test]
    fn outbound_pair_commits_atomically_and_drives_only_after_idle_turnaround() {
        let mut tx = PlioTx::new();
        let control = ControlImage {
            space: 1,
            address_strobe: true,
            read: true,
            byte_enable: 0xf,
            burst_len: 2,
            data_strobe: false,
            drive_ad_par: true,
            drive_control: true,
        };
        tx.step(false, QicPtiDrive { token: encode_control(control).unwrap(), ..Default::default() }, BackplaneSample::default());
        let pair = encode_data_beat(0x89ab_cdef, 0b1010).unwrap();
        tx.step(false, QicPtiDrive { token: pair[0], ..Default::default() }, BackplaneSample::default());
        assert_eq!(tx.committed_data(), None);
        tx.step(false, QicPtiDrive { token: pair[1], ..Default::default() }, BackplaneSample::default());
        assert_eq!(tx.committed_data(), Some((0x89ab_cdef, 0b1010)));

        tx.step(false, idle(PtiDirection::QicToTx), BackplaneSample::default());
        let (drive, obs) = tx.step(false, QicPtiDrive { drive_enable: true, bus_request: true, ..Default::default() }, BackplaneSample::default());
        assert_eq!(drive.ad_par, Some((0x89ab_cdef, 0b1010)));
        assert_eq!(drive.control, Some(BackplaneControl::from_drive_image(control)));
        assert!(drive.request);
        assert!(!obs.protocol_fault);
    }

    #[test]
    fn receive_pair_is_coherent_even_if_backplane_changes_between_halves() {
        let mut tx = PlioTx::new();
        tx.step(false, idle(PtiDirection::TxToQic), BackplaneSample::default());

        let first = BackplaneSample { ad: 0x1122_3344, par: 0b1010, ..Default::default() };
        let second = BackplaneSample { ad: 0xaabb_ccdd, par: 0b0101, ..Default::default() };
        let (_, lo) = tx.step(false, QicPtiDrive { direction: PtiDirection::TxToQic, token: Token { kind: TokenKind::DataLo, ptd: 0 }, ..Default::default() }, first);
        let (_, hi) = tx.step(false, QicPtiDrive { direction: PtiDirection::TxToQic, token: Token { kind: TokenKind::DataHi, ptd: 0 }, ..Default::default() }, second);
        assert_eq!(lo.rx_token.unwrap().data(), 0x3344);
        assert_eq!(lo.rx_token.unwrap().parity(), 0b10);
        assert_eq!(hi.rx_token.unwrap().data(), 0x1122);
        assert_eq!(hi.rx_token.unwrap().parity(), 0b10);
    }

    #[test]
    fn receive_control_has_no_outbound_drive_bits() {
        let mut tx = PlioTx::new();
        tx.step(false, idle(PtiDirection::TxToQic), BackplaneSample::default());
        let bus = BackplaneSample {
            control: BackplaneControl { space: 2, address_strobe: true, read: false, byte_enable: 0xc, burst_len: 3, data_strobe: true },
            ..Default::default()
        };
        let (_, obs) = tx.step(false, QicPtiDrive { direction: PtiDirection::TxToQic, token: Token { kind: TokenKind::Control, ptd: 0 }, ..Default::default() }, bus);
        let got = decode_control(obs.rx_token.unwrap()).unwrap();
        assert_eq!(got.space, 2);
        assert!(got.address_strobe);
        assert_eq!(got.byte_enable, 0xc);
        assert!(got.data_strobe);
        assert!(!got.drive_ad_par);
        assert!(!got.drive_control);
    }

    #[test]
    fn high_without_low_faults_and_does_not_commit() {
        let mut tx = PlioTx::new();
        let hi = Token::new(TokenKind::DataHi, 0x1234, 2).unwrap();
        let (_, obs) = tx.step(false, QicPtiDrive { token: hi, ..Default::default() }, BackplaneSample::default());
        assert!(obs.protocol_fault);
        assert_eq!(tx.committed_data(), None);
        assert!(tx.protocol_fault());
    }

    #[test]
    fn direction_change_requires_idle() {
        let mut tx = PlioTx::new();
        let control = ControlImage { space: 0, ..ControlImage::default() };
        tx.step(false, QicPtiDrive { token: encode_control(control).unwrap(), ..Default::default() }, BackplaneSample::default());
        let (_, obs) = tx.step(false, QicPtiDrive { direction: PtiDirection::TxToQic, token: Token { kind: TokenKind::Control, ptd: 0 }, ..Default::default() }, BackplaneSample::default());
        assert!(obs.protocol_fault);
    }

    #[test]
    fn response_pair_is_sampled_or_driven_under_response_enable() {
        let tx = PlioTx::new();
        let bus = BackplaneSample { ack: true, err: false, selected: true, grant: true, ..Default::default() };
        let (_, sampled) = tx.drive(false, QicPtiDrive::default(), bus);
        assert!(sampled.sample_ack);
        assert!(sampled.sample_selected);
        assert!(sampled.sample_grant);

        let (drive, observed) = tx.drive(false, QicPtiDrive { response_enable: true, response_ack: true, ..Default::default() }, bus);
        assert_eq!(drive.response, Some((true, false)));
        assert!(!observed.sample_ack);
    }

    #[test]
    fn simultaneous_ack_and_err_is_suppressed_and_faulted() {
        let tx = PlioTx::new();
        let (drive, obs) = tx.drive(false, QicPtiDrive { response_enable: true, response_ack: true, response_err: true, ..Default::default() }, BackplaneSample::default());
        assert_eq!(drive.response, None);
        assert!(obs.protocol_fault);
    }

    #[test]
    fn drive_enable_rise_without_previous_idle_is_suppressed() {
        let mut tx = PlioTx::new();
        let control = ControlImage { drive_control: true, ..ControlImage::default() };
        tx.step(false, QicPtiDrive { token: encode_control(control).unwrap(), ..Default::default() }, BackplaneSample::default());
        let (drive, obs) = tx.step(false, QicPtiDrive { drive_enable: true, ..Default::default() }, BackplaneSample::default());
        assert!(drive.control.is_none());
        assert!(obs.protocol_fault);
    }

    #[test]
    fn contention_is_reported_without_analog_resolution() {
        let mut tx = PlioTx::new();
        let control = ControlImage {
            space: 0, address_strobe: false, read: false, byte_enable: 0xf, burst_len: 0,
            data_strobe: true, drive_ad_par: true, drive_control: false,
        };
        tx.step(false, QicPtiDrive { token: encode_control(control).unwrap(), ..Default::default() }, BackplaneSample::default());
        let pair = encode_data_beat(0x0102_0304, 0xf).unwrap();
        tx.step(false, QicPtiDrive { token: pair[0], ..Default::default() }, BackplaneSample::default());
        tx.step(false, QicPtiDrive { token: pair[1], ..Default::default() }, BackplaneSample::default());
        tx.step(false, idle(PtiDirection::QicToTx), BackplaneSample::default());
        let (_, obs) = tx.step(false, QicPtiDrive { drive_enable: true, ..Default::default() }, BackplaneSample { external_ad_par_drive: true, ..Default::default() });
        assert!(obs.contention);
        assert!(tx.contention());
    }

    #[test]
    fn reset_forces_safe_outputs_and_clears_faults() {
        let mut tx = PlioTx::new();
        let hi = Token::new(TokenKind::DataHi, 0, 0).unwrap();
        tx.step(false, QicPtiDrive { token: hi, ..Default::default() }, BackplaneSample::default());
        assert!(tx.protocol_fault());
        let (drive, obs) = tx.step(true, QicPtiDrive { drive_enable: true, response_enable: true, response_ack: true, bus_request: true, ..Default::default() }, BackplaneSample::default());
        assert_eq!(drive, BackplaneDrive::default());
        assert_eq!(obs, PtiObserve::default());
        assert!(!tx.protocol_fault());
    }
}

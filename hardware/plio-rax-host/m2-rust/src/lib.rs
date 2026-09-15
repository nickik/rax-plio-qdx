#![forbid(unsafe_code)]

use plio_logical_model::{odd_parity_32, parity_matches, BusToCard, BurstWords, CardToBus, Space, PLIO_TIMEOUT_CYCLES};

pub const PLIO_SLOT_COUNT: usize = 8;
pub const NOTIFICATION_CHANNEL_COUNT: usize = 4;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NotificationConfig {
    pub enabled: bool,
    pub masked: bool,
    pub class: u8,
}

pub const DEFAULT_NOTIFICATION_CONFIG: NotificationConfig = NotificationConfig {
    enabled: true,
    masked: false,
    class: 0,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NotificationClaim {
    pub slot: u8,
    pub channel: u8,
    pub payload: u32,
    pub class: u8,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ManagerState {
    Idle,
    Grant { slot: u8 },
    NotificationData { slot: u8, channel: u8 },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ManagerFault {
    BadNotificationAddress,
    AddressParity,
    BadNotificationData,
    DataParity,
    Timeout,
    RequestDropped,
    Reset,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ManagerDebug {
    pub state: ManagerState,
    pub round_robin_cursor: u8,
    pub wait_cycles: u16,
    pub last_fault: Option<ManagerFault>,
    pub grants: [u32; PLIO_SLOT_COUNT],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ManagerDrive {
    pub buses: [BusToCard; PLIO_SLOT_COUNT],
    pub granted_slot: Option<u8>,
}

#[derive(Debug, Clone)]
pub struct PlioManagerM2 {
    state: ManagerState,
    cursor: u8,
    wait_cycles: u16,
    pending: [[bool; NOTIFICATION_CHANNEL_COUNT]; PLIO_SLOT_COUNT],
    payload: [[u32; NOTIFICATION_CHANNEL_COUNT]; PLIO_SLOT_COUNT],
    config: [[NotificationConfig; NOTIFICATION_CHANNEL_COUNT]; PLIO_SLOT_COUNT],
    grants: [u32; PLIO_SLOT_COUNT],
    last_fault: Option<ManagerFault>,
}

impl Default for PlioManagerM2 {
    fn default() -> Self { Self::new() }
}

impl PlioManagerM2 {
    pub const fn new() -> Self {
        Self {
            state: ManagerState::Idle,
            cursor: 0,
            wait_cycles: 0,
            pending: [[false; NOTIFICATION_CHANNEL_COUNT]; PLIO_SLOT_COUNT],
            payload: [[0; NOTIFICATION_CHANNEL_COUNT]; PLIO_SLOT_COUNT],
            config: [[DEFAULT_NOTIFICATION_CONFIG; NOTIFICATION_CHANNEL_COUNT]; PLIO_SLOT_COUNT],
            grants: [0; PLIO_SLOT_COUNT],
            last_fault: None,
        }
    }

    pub fn state(&self) -> ManagerState { self.state }
    pub fn cursor(&self) -> u8 { self.cursor }
    pub fn last_fault(&self) -> Option<ManagerFault> { self.last_fault }
    pub fn grant_count(&self, slot: u8) -> u32 { self.grants[slot as usize] }

    pub fn set_notification_config(&mut self, slot: u8, channel: u8, config: NotificationConfig) {
        assert!((slot as usize) < PLIO_SLOT_COUNT);
        assert!((channel as usize) < NOTIFICATION_CHANNEL_COUNT);
        self.config[slot as usize][channel as usize] = config;
    }

    pub fn notification_pending(&self, slot: u8, channel: u8) -> bool {
        self.pending[slot as usize][channel as usize]
    }

    pub fn notification_payload(&self, slot: u8, channel: u8) -> u32 {
        self.payload[slot as usize][channel as usize]
    }

    pub fn peek_claim(&self) -> Option<NotificationClaim> {
        for slot in 0..PLIO_SLOT_COUNT {
            for channel in 0..NOTIFICATION_CHANNEL_COUNT {
                if self.pending[slot][channel] {
                    let cfg = self.config[slot][channel];
                    if cfg.enabled && !cfg.masked {
                        return Some(NotificationClaim {
                            slot: slot as u8,
                            channel: channel as u8,
                            payload: self.payload[slot][channel],
                            class: cfg.class,
                        });
                    }
                }
            }
        }
        None
    }

    pub fn claim(&mut self) -> Option<NotificationClaim> {
        let claim = self.peek_claim()?;
        self.pending[claim.slot as usize][claim.channel as usize] = false;
        Some(claim)
    }

    pub fn drive(
        &self,
        reset: bool,
        cards: &[CardToBus; PLIO_SLOT_COUNT],
        notification_ready: bool,
    ) -> ManagerDrive {
        let mut buses = [BusToCard::default(); PLIO_SLOT_COUNT];
        if reset {
            for bus in &mut buses { bus.reset = true; }
            return ManagerDrive { buses, granted_slot: None };
        }

        let (slot, channel) = match self.state {
            ManagerState::Idle => return ManagerDrive { buses, granted_slot: None },
            ManagerState::Grant { slot } => (slot, None),
            ManagerState::NotificationData { slot, channel } => (slot, Some(channel)),
        };

        let bus = &mut buses[slot as usize];
        let card = cards[slot as usize];
        bus.grant = true;

        match self.state {
            ManagerState::Idle => {}
            ManagerState::Grant { .. } => {
                if card.address_strobe {
                    match validate_notification_address(card) {
                        Ok(_) => bus.ack = true,
                        Err(_) => bus.err = true,
                    }
                } else if self.wait_cycles + 1 >= PLIO_TIMEOUT_CYCLES {
                    bus.err = true;
                }
            }
            ManagerState::NotificationData { .. } => {
                if card.data_strobe && notification_ready {
                    match validate_notification_data(card) {
                        Ok(_) => bus.ack = true,
                        Err(_) => bus.err = true,
                    }
                } else if self.wait_cycles + 1 >= PLIO_TIMEOUT_CYCLES {
                    bus.err = true;
                }
            }
        }

        let _ = channel;
        ManagerDrive { buses, granted_slot: Some(slot) }
    }

    pub fn clock(
        &mut self,
        reset: bool,
        cards: &[CardToBus; PLIO_SLOT_COUNT],
        notification_ready: bool,
    ) {
        if reset {
            if self.state != ManagerState::Idle { self.last_fault = Some(ManagerFault::Reset); }
            self.state = ManagerState::Idle;
            self.cursor = 0;
            self.wait_cycles = 0;
            self.pending = [[false; NOTIFICATION_CHANNEL_COUNT]; PLIO_SLOT_COUNT];
            self.payload = [[0; NOTIFICATION_CHANNEL_COUNT]; PLIO_SLOT_COUNT];
            return;
        }

        match self.state {
            ManagerState::Idle => {
                if let Some(slot) = choose_request(self.cursor, cards) {
                    self.state = ManagerState::Grant { slot };
                    self.wait_cycles = 0;
                    self.grants[slot as usize] += 1;
                    self.last_fault = None;
                }
            }
            ManagerState::Grant { slot } => {
                let card = cards[slot as usize];
                if !card.request {
                    self.fail(slot, ManagerFault::RequestDropped);
                } else if card.address_strobe {
                    match validate_notification_address(card) {
                        Ok(channel) => {
                            self.state = ManagerState::NotificationData { slot, channel };
                            self.wait_cycles = 0;
                        }
                        Err(fault) => self.fail(slot, fault),
                    }
                } else {
                    self.wait_or_timeout(slot);
                }
            }
            ManagerState::NotificationData { slot, channel } => {
                let card = cards[slot as usize];
                if !card.request {
                    self.fail(slot, ManagerFault::RequestDropped);
                } else if card.data_strobe && notification_ready {
                    match validate_notification_data(card) {
                        Ok(payload) => {
                            self.pending[slot as usize][channel as usize] = true;
                            self.payload[slot as usize][channel as usize] = payload;
                            self.complete(slot);
                        }
                        Err(fault) => self.fail(slot, fault),
                    }
                } else {
                    self.wait_or_timeout(slot);
                }
            }
        }
    }

    fn wait_or_timeout(&mut self, slot: u8) {
        if self.wait_cycles + 1 >= PLIO_TIMEOUT_CYCLES {
            self.fail(slot, ManagerFault::Timeout);
        } else {
            self.wait_cycles += 1;
        }
    }

    fn complete(&mut self, slot: u8) {
        self.state = ManagerState::Idle;
        self.cursor = (slot + 1) & 7;
        self.wait_cycles = 0;
        self.last_fault = None;
    }

    fn fail(&mut self, slot: u8, fault: ManagerFault) {
        self.state = ManagerState::Idle;
        self.cursor = (slot + 1) & 7;
        self.wait_cycles = 0;
        self.last_fault = Some(fault);
    }

    pub fn debug(&self) -> ManagerDebug {
        ManagerDebug {
            state: self.state,
            round_robin_cursor: self.cursor,
            wait_cycles: self.wait_cycles,
            last_fault: self.last_fault,
            grants: self.grants,
        }
    }
}

fn choose_request(cursor: u8, cards: &[CardToBus; PLIO_SLOT_COUNT]) -> Option<u8> {
    for offset in 0..PLIO_SLOT_COUNT {
        let slot = ((cursor as usize + offset) & 7) as u8;
        if cards[slot as usize].request { return Some(slot); }
    }
    None
}

fn validate_notification_address(card: CardToBus) -> Result<u8, ManagerFault> {
    let address = card.ad.ok_or(ManagerFault::BadNotificationAddress)?;
    let parity = card.par.ok_or(ManagerFault::AddressParity)?;
    if !parity_matches(address, parity, 0xf) { return Err(ManagerFault::AddressParity); }
    if card.space != Some(Space::Controller)
        || card.read
        || card.byte_enable != 0xf
        || card.burst != BurstWords::One
        || address & 3 != 0
        || address > 12
    {
        return Err(ManagerFault::BadNotificationAddress);
    }
    Ok((address / 4) as u8)
}

fn validate_notification_data(card: CardToBus) -> Result<u32, ManagerFault> {
    let data = card.ad.ok_or(ManagerFault::BadNotificationData)?;
    let parity = card.par.ok_or(ManagerFault::DataParity)?;
    if card.byte_enable != 0xf { return Err(ManagerFault::BadNotificationData); }
    if !parity_matches(data, parity, 0xf) { return Err(ManagerFault::DataParity); }
    Ok(data)
}

pub fn notification_address(channel: u8) -> u32 {
    assert!(channel < 4);
    u32::from(channel) * 4
}

pub fn make_notification_address(slot_request: bool, channel: u8) -> CardToBus {
    let address = notification_address(channel);
    CardToBus {
        request: slot_request,
        ad: Some(address),
        par: Some(odd_parity_32(address)),
        space: Some(Space::Controller),
        address_strobe: true,
        read: false,
        byte_enable: 0xf,
        burst: BurstWords::One,
        ..CardToBus::default()
    }
}

pub fn make_notification_data(slot_request: bool, payload: u32) -> CardToBus {
    CardToBus {
        request: slot_request,
        ad: Some(payload),
        par: Some(odd_parity_32(payload)),
        byte_enable: 0xf,
        data_strobe: true,
        ..CardToBus::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn empty_cards() -> [CardToBus; PLIO_SLOT_COUNT] { [CardToBus::default(); PLIO_SLOT_COUNT] }

    fn enter_grant(manager: &mut PlioManagerM2, slot: usize) -> [CardToBus; PLIO_SLOT_COUNT] {
        let mut cards = empty_cards();
        cards[slot].request = true;
        manager.clock(false, &cards, true);
        assert_eq!(manager.state(), ManagerState::Grant { slot: slot as u8 });
        cards
    }

    fn complete_notification(manager: &mut PlioManagerM2, slot: usize, channel: u8, payload: u32) {
        let mut cards = enter_grant(manager, slot);
        cards[slot] = make_notification_address(true, channel);
        assert!(manager.drive(false, &cards, true).buses[slot].ack);
        manager.clock(false, &cards, true);
        cards[slot] = make_notification_data(true, payload);
        assert!(manager.drive(false, &cards, true).buses[slot].ack);
        manager.clock(false, &cards, true);
    }

    #[test]
    fn rotating_round_robin_is_fair_and_one_hot() {
        let mut manager = PlioManagerM2::new();
        let mut cards = empty_cards();
        cards[2].request = true;
        cards[5].request = true;
        cards[7].request = true;
        manager.clock(false, &cards, true);
        assert_eq!(manager.drive(false, &cards, true).granted_slot, Some(2));

        cards[2] = make_notification_address(true, 0);
        manager.clock(false, &cards, true);
        cards[2] = make_notification_data(true, 0x22);
        manager.clock(false, &cards, true);
        manager.clock(false, &cards, true);
        assert_eq!(manager.drive(false, &cards, true).granted_slot, Some(5));

        let drive = manager.drive(false, &cards, true);
        assert_eq!(drive.buses.iter().filter(|b| b.grant).count(), 1);
    }

    #[test]
    fn repeated_request_gets_fresh_transaction_grants() {
        let mut manager = PlioManagerM2::new();
        complete_notification(&mut manager, 3, 0, 0x11);
        let mut cards = empty_cards();
        cards[3].request = true;
        manager.clock(false, &cards, true);
        assert_eq!(manager.state(), ManagerState::Grant { slot: 3 });
        assert_eq!(manager.grant_count(3), 2);
    }

    #[test]
    fn notification_data_backpressure_holds_grant_and_payload() {
        let mut manager = PlioManagerM2::new();
        let mut cards = enter_grant(&mut manager, 1);
        cards[1] = make_notification_address(true, 2);
        manager.clock(false, &cards, true);
        cards[1] = make_notification_data(true, 0xfeed_beef);
        for wait in 1..=3 {
            let drive = manager.drive(false, &cards, false);
            assert!(drive.buses[1].grant);
            assert!(!drive.buses[1].ack);
            manager.clock(false, &cards, false);
            assert_eq!(manager.debug().wait_cycles, wait);
        }
        manager.clock(false, &cards, true);
        assert!(manager.notification_pending(1, 2));
        assert_eq!(manager.notification_payload(1, 2), 0xfeed_beef);
    }

    #[test]
    fn address_and_data_errors_are_typed() {
        let mut manager = PlioManagerM2::new();
        let mut cards = enter_grant(&mut manager, 0);
        cards[0] = make_notification_address(true, 0);
        cards[0].par = Some(cards[0].par.unwrap() ^ 1);
        assert!(manager.drive(false, &cards, true).buses[0].err);
        manager.clock(false, &cards, true);
        assert_eq!(manager.last_fault(), Some(ManagerFault::AddressParity));

        let mut cards = enter_grant(&mut manager, 0);
        cards[0] = make_notification_address(true, 0);
        manager.clock(false, &cards, true);
        cards[0] = make_notification_data(true, 0x1234_5678);
        cards[0].par = Some(cards[0].par.unwrap() ^ 1);
        manager.clock(false, &cards, true);
        assert_eq!(manager.last_fault(), Some(ManagerFault::DataParity));
    }

    #[test]
    fn timeout_and_request_drop_release_grant() {
        let mut manager = PlioManagerM2::new();
        let cards = enter_grant(&mut manager, 6);
        for _ in 0..PLIO_TIMEOUT_CYCLES { manager.clock(false, &cards, true); }
        assert_eq!(manager.last_fault(), Some(ManagerFault::Timeout));
        assert_eq!(manager.state(), ManagerState::Idle);

        let mut manager = PlioManagerM2::new();
        let _ = enter_grant(&mut manager, 4);
        manager.clock(false, &empty_cards(), true);
        assert_eq!(manager.last_fault(), Some(ManagerFault::RequestDropped));
    }

    #[test]
    fn reset_withdraws_grant_and_clears_pending() {
        let mut manager = PlioManagerM2::new();
        complete_notification(&mut manager, 2, 1, 0xaa55_aa55);
        assert!(manager.notification_pending(2, 1));
        let cards = enter_grant(&mut manager, 5);
        let drive = manager.drive(true, &cards, true);
        assert_eq!(drive.granted_slot, None);
        assert!(drive.buses.iter().all(|b| b.reset && !b.grant));
        manager.clock(true, &cards, true);
        assert!(!manager.notification_pending(2, 1));
        assert_eq!(manager.cursor(), 0);
    }

    #[test]
    fn deterministic_claim_order_honors_enable_mask_and_class() {
        let mut manager = PlioManagerM2::new();
        complete_notification(&mut manager, 4, 0, 0x40);
        complete_notification(&mut manager, 1, 3, 0x13);
        complete_notification(&mut manager, 1, 1, 0x11);
        manager.set_notification_config(1, 1, NotificationConfig { enabled: true, masked: true, class: 2 });
        manager.set_notification_config(1, 3, NotificationConfig { enabled: true, masked: false, class: 7 });
        manager.set_notification_config(4, 0, NotificationConfig { enabled: false, masked: false, class: 9 });

        assert_eq!(manager.peek_claim(), Some(NotificationClaim { slot: 1, channel: 3, payload: 0x13, class: 7 }));
        assert_eq!(manager.claim().unwrap().channel, 3);
        manager.set_notification_config(1, 1, NotificationConfig { enabled: true, masked: false, class: 2 });
        assert_eq!(manager.claim(), Some(NotificationClaim { slot: 1, channel: 1, payload: 0x11, class: 2 }));
        assert_eq!(manager.claim(), None);
    }
}

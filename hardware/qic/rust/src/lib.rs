#![forbid(unsafe_code)]

use plio_logical_model::{
    odd_parity_32, parity_matches, valid_worker_transfer, BusToCard, BurstWords,
    CardToBus, Space, PLIO_TIMEOUT_CYCLES,
};
use qli_model::{
    DeviceToQic, DmaCompletion, DmaDirection, DmaRequest, DmaStatus, DmaWord,
    MmioRequest, MmioResponse, NotificationRequest, QicToDevice,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ManagerWork {
    Dma(DmaRequest),
    Notification(NotificationRequest),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum State {
    Idle,
    WorkerReadData { address: u32, byte_enable: u8, wait: u16 },
    WorkerWriteData { address: u32, byte_enable: u8, wait: u16 },
    WorkerOffer { request: MmioRequest, wait: u16 },
    WorkerResponse { read: bool, wait: u16 },
    RequestBus(ManagerWork),
    DmaAddress { request: DmaRequest, wait: u16 },
    DmaData {
        request: DmaRequest,
        completed: u8,
        wait: u16,
        buffer: Option<DmaWord>,
    },
    DmaComplete { completion: DmaCompletion },
    NotificationAddress { request: NotificationRequest, wait: u16 },
    NotificationData { request: NotificationRequest, wait: u16 },
}

#[derive(Debug, Clone, Copy)]
pub struct Qic {
    state: State,
    suspended: Option<ManagerWork>,
}

impl Default for Qic {
    fn default() -> Self { Self::new() }
}

impl Qic {
    pub const fn new() -> Self {
        Self { state: State::Idle, suspended: None }
    }

    pub fn is_idle(&self) -> bool { self.state == State::Idle && self.suspended.is_none() }

    pub fn drive(&self, bus: &BusToCard, device: &DeviceToQic) -> (CardToBus, QicToDevice) {
        let mut card = CardToBus::default();
        let mut qli = QicToDevice::default();

        if bus.reset {
            qli.reset = true;
            return (card, qli);
        }

        // A manager request remains asserted while the card is temporarily
        // servicing a selected worker transaction before bus grant.  No
        // manager address/data is driven until the host actually grants BG.
        if self.suspended.is_some() {
            card.request = true;
        }

        match self.state {
            State::Idle => {
                if worker_address_cycle(bus) {
                    if worker_address_valid(bus) { card.ack = true; } else { card.err = true; }
                } else if let Some(notification) = device.notification_request {
                    let _ = notification.validate();
                    // Notification uses completion-based ready, so no early ready.
                } else if let Some(request) = device.dma_request {
                    if request.validate().is_ok() { qli.dma_request_ready = true; }
                }
            }
            State::WorkerReadData { wait, .. } => {
                if timed_out(wait) { card.err = true; }
            }
            State::WorkerWriteData { byte_enable, wait, .. } => {
                if timed_out(wait) {
                    card.err = true;
                } else if bus.data_strobe
                    && (bus.ad.is_none()
                        || bus.par.is_none()
                        || !parity_matches(bus.ad.unwrap_or(0), bus.par.unwrap_or(0), byte_enable))
                {
                    card.err = true;
                }
            }
            State::WorkerOffer { request, wait } => {
                if timed_out(wait) {
                    card.err = true;
                } else {
                    qli.mmio_request = Some(request);
                }
            }
            State::WorkerResponse { read, wait } => {
                if timed_out(wait) {
                    card.err = true;
                    qli.mmio_cancel = true;
                } else {
                    qli.mmio_response_ready = bus.data_strobe;
                    if bus.data_strobe {
                        if let Some(response) = device.mmio_response {
                            match response {
                                MmioResponse::ReadOk(data) if read => {
                                    card.ad = Some(data);
                                    card.par = Some(odd_parity_32(data));
                                    card.ack = true;
                                }
                                MmioResponse::WriteOk if !read => card.ack = true,
                                MmioResponse::Error => card.err = true,
                                _ => card.err = true,
                            }
                        }
                    }
                }
            }
            State::RequestBus(_) => {
                card.request = true;
                if worker_address_cycle(bus) {
                    if worker_address_valid(bus) { card.ack = true; } else { card.err = true; }
                }
            }
            State::DmaAddress { request, wait } => {
                card.request = true;
                if bus.grant && !timed_out(wait) {
                    card.ad = Some(request.address);
                    card.par = Some(odd_parity_32(request.address));
                    card.space = Some(Space::HostDma);
                    card.address_strobe = true;
                    card.read = request.direction == DmaDirection::HostToDevice;
                    card.byte_enable = 0xf;
                    card.burst = request.words;
                }
            }
            State::DmaData { request, completed, wait, buffer } => {
                let final_read_buffer = is_final_read_buffer(request, completed, buffer);
                card.request = !final_read_buffer;

                if timed_out(wait) { return (card, qli); }
                if !final_read_buffer && !bus.grant { return (card, qli); }

                match request.direction {
                    DmaDirection::HostToDevice => {
                        if let Some(word) = buffer {
                            qli.dma_read = Some(word);
                        } else if completed < request.words.words() {
                            card.data_strobe = true;
                        }
                    }
                    DmaDirection::DeviceToHost => {
                        if let Some(word) = buffer {
                            card.ad = Some(word.data);
                            card.par = Some(odd_parity_32(word.data));
                            card.data_strobe = true;
                        } else if completed < request.words.words() {
                            qli.dma_write_ready = true;
                        }
                    }
                }
            }
            State::DmaComplete { completion } => qli.dma_completion = Some(completion),
            State::NotificationAddress { request, wait } => {
                card.request = true;
                if bus.grant && !timed_out(wait) {
                    let address = u32::from(request.channel) * 4;
                    card.ad = Some(address);
                    card.par = Some(odd_parity_32(address));
                    card.space = Some(Space::Controller);
                    card.address_strobe = true;
                    card.read = false;
                    card.byte_enable = 0xf;
                    card.burst = BurstWords::One;
                }
            }
            State::NotificationData { request, wait } => {
                card.request = true;
                if bus.grant && !timed_out(wait) {
                    card.ad = Some(0);
                    card.par = Some(odd_parity_32(0));
                    card.data_strobe = true;
                    if bus.ack {
                        qli.notification_ready = device.notification_request == Some(request);
                    }
                }
            }
        }

        (card, qli)
    }

    pub fn clock(&mut self, bus: &BusToCard, device: &DeviceToQic) {
        if bus.reset {
            self.state = State::Idle;
            self.suspended = None;
            return;
        }

        // BR does not make the card bus manager; BG does.  A host may still
        // select this card as a worker while its accepted manager work waits
        // for grant.  Suspend that arbitration state, service the worker
        // transaction, then resume the exact accepted manager request.
        if let State::RequestBus(work) = self.state {
            if worker_address_cycle(bus) {
                if worker_address_valid(bus) {
                    let address = bus.ad.unwrap_or(0);
                    self.suspended = Some(work);
                    self.state = if bus.read {
                        State::WorkerReadData { address, byte_enable: bus.byte_enable, wait: 0 }
                    } else {
                        State::WorkerWriteData { address, byte_enable: bus.byte_enable, wait: 0 }
                    };
                }
                return;
            }
        }

        // BG is authority to drive manager-side PLIO. The one exception is
        // draining the already-ACKed final host->device word from the QIC's
        // local buffer; no PLIO bus work remains at that point.
        match self.state {
            State::DmaAddress { .. } if !bus.grant => {
                self.state = State::DmaComplete {
                    completion: DmaCompletion { status: DmaStatus::ProtocolError, words_completed: 0 },
                };
                return;
            }
            State::DmaData { request, completed, buffer, .. }
                if !bus.grant && !is_final_read_buffer(request, completed, buffer) =>
            {
                self.state = State::DmaComplete {
                    completion: DmaCompletion { status: DmaStatus::ProtocolError, words_completed: completed },
                };
                return;
            }
            State::NotificationAddress { .. } | State::NotificationData { .. } if !bus.grant => {
                // Notification is idempotent. No local completion means the
                // producer retains it and the QIC retries from Idle.
                self.state = State::Idle;
                return;
            }
            _ => {}
        }

        self.state = match self.state {
            State::Idle => {
                if worker_address_cycle(bus) {
                    if !worker_address_valid(bus) {
                        State::Idle
                    } else {
                        let address = bus.ad.unwrap_or(0);
                        if bus.read {
                            State::WorkerReadData { address, byte_enable: bus.byte_enable, wait: 0 }
                        } else {
                            State::WorkerWriteData { address, byte_enable: bus.byte_enable, wait: 0 }
                        }
                    }
                } else if let Some(notification) = device.notification_request {
                    if notification.validate().is_ok() {
                        State::RequestBus(ManagerWork::Notification(notification))
                    } else {
                        State::Idle
                    }
                } else if let Some(request) = device.dma_request {
                    if request.validate().is_ok() {
                        State::RequestBus(ManagerWork::Dma(request))
                    } else {
                        State::Idle
                    }
                } else {
                    State::Idle
                }
            }
            State::WorkerReadData { address, byte_enable, wait } => {
                if timed_out(wait) {
                    State::Idle
                } else if bus.data_strobe {
                    State::WorkerOffer {
                        request: MmioRequest { address, write: false, byte_enable, write_data: 0 },
                        wait,
                    }
                } else {
                    State::WorkerReadData { address, byte_enable, wait: wait.saturating_add(1) }
                }
            }
            State::WorkerWriteData { address, byte_enable, wait } => {
                if timed_out(wait) {
                    State::Idle
                } else if bus.data_strobe {
                    match (bus.ad, bus.par) {
                        (Some(data), Some(parity)) if parity_matches(data, parity, byte_enable) => {
                            State::WorkerOffer {
                                request: MmioRequest { address, write: true, byte_enable, write_data: data },
                                wait: 0,
                            }
                        }
                        _ => State::Idle,
                    }
                } else {
                    State::WorkerWriteData { address, byte_enable, wait: wait.saturating_add(1) }
                }
            }
            State::WorkerOffer { request, wait } => {
                if timed_out(wait) {
                    State::Idle
                } else if device.mmio_ready {
                    // The same PLIO data phase remains outstanding, so do not
                    // restart the 256-clock timeout when QLI accepts the request.
                    State::WorkerResponse { read: !request.write, wait }
                } else {
                    State::WorkerOffer { request, wait: wait.saturating_add(1) }
                }
            }
            State::WorkerResponse { read, wait } => {
                if timed_out(wait) {
                    State::Idle
                } else if bus.data_strobe && device.mmio_response.is_some() {
                    State::Idle
                } else {
                    State::WorkerResponse { read, wait: wait.saturating_add(1) }
                }
            }
            State::RequestBus(work) => {
                if bus.grant {
                    match work {
                        ManagerWork::Dma(request) => State::DmaAddress { request, wait: 0 },
                        ManagerWork::Notification(request) => State::NotificationAddress { request, wait: 0 },
                    }
                } else {
                    State::RequestBus(work)
                }
            }
            State::DmaAddress { request, wait } => {
                if timed_out(wait) {
                    State::DmaComplete {
                        completion: DmaCompletion { status: DmaStatus::Timeout, words_completed: 0 },
                    }
                } else if bus.err {
                    State::DmaComplete {
                        completion: DmaCompletion { status: DmaStatus::BusError, words_completed: 0 },
                    }
                } else if bus.ack {
                    State::DmaData { request, completed: 0, wait: 0, buffer: None }
                } else {
                    State::DmaAddress { request, wait: wait.saturating_add(1) }
                }
            }
            State::DmaData { request, completed, wait, buffer } => {
                if timed_out(wait) {
                    State::DmaComplete {
                        completion: DmaCompletion { status: DmaStatus::Timeout, words_completed: completed },
                    }
                } else {
                    match request.direction {
                        DmaDirection::HostToDevice => {
                            if let Some(word) = buffer {
                                if device.dma_read_ready {
                                    if completed == request.words.words() {
                                        State::DmaComplete {
                                            completion: DmaCompletion { status: DmaStatus::Ok, words_completed: completed },
                                        }
                                    } else {
                                        State::DmaData { request, completed, wait: 0, buffer: None }
                                    }
                                } else {
                                    State::DmaData {
                                        request,
                                        completed,
                                        wait: wait.saturating_add(1),
                                        buffer: Some(word),
                                    }
                                }
                            } else if bus.err {
                                State::DmaComplete {
                                    completion: DmaCompletion { status: DmaStatus::BusError, words_completed: completed },
                                }
                            } else if bus.ack {
                                match (bus.ad, bus.par) {
                                    (Some(data), Some(parity)) if parity_matches(data, parity, 0xf) => {
                                        State::DmaData {
                                            request,
                                            completed: completed + 1,
                                            wait: 0,
                                            buffer: Some(DmaWord { data }),
                                        }
                                    }
                                    _ => State::DmaComplete {
                                        completion: DmaCompletion { status: DmaStatus::ParityError, words_completed: completed },
                                    },
                                }
                            } else {
                                State::DmaData {
                                    request,
                                    completed,
                                    wait: wait.saturating_add(1),
                                    buffer: None,
                                }
                            }
                        }
                        DmaDirection::DeviceToHost => {
                            if let Some(word) = buffer {
                                if bus.err {
                                    State::DmaComplete {
                                        completion: DmaCompletion { status: DmaStatus::BusError, words_completed: completed },
                                    }
                                } else if bus.ack {
                                    let next = completed + 1;
                                    if next == request.words.words() {
                                        State::DmaComplete {
                                            completion: DmaCompletion { status: DmaStatus::Ok, words_completed: next },
                                        }
                                    } else {
                                        State::DmaData { request, completed: next, wait: 0, buffer: None }
                                    }
                                } else {
                                    State::DmaData {
                                        request,
                                        completed,
                                        wait: wait.saturating_add(1),
                                        buffer: Some(word),
                                    }
                                }
                            } else if let Some(word) = device.dma_write {
                                State::DmaData { request, completed, wait: 0, buffer: Some(word) }
                            } else {
                                // A device that initiated a write DMA must make
                                // bounded progress; otherwise it would pin BG forever.
                                State::DmaData {
                                    request,
                                    completed,
                                    wait: wait.saturating_add(1),
                                    buffer: None,
                                }
                            }
                        }
                    }
                }
            }
            State::DmaComplete { completion } => {
                if device.dma_completion_ready { State::Idle } else { State::DmaComplete { completion } }
            }
            State::NotificationAddress { request, wait } => {
                if timed_out(wait) || bus.err {
                    State::Idle
                } else if bus.ack {
                    State::NotificationData { request, wait: 0 }
                } else {
                    State::NotificationAddress { request, wait: wait.saturating_add(1) }
                }
            }
            State::NotificationData { request, wait } => {
                if timed_out(wait) || bus.err || bus.ack {
                    State::Idle
                } else {
                    State::NotificationData { request, wait: wait.saturating_add(1) }
                }
            }
        };

        if self.state == State::Idle {
            if let Some(work) = self.suspended.take() {
                self.state = State::RequestBus(work);
            }
        }
    }
}

fn is_final_read_buffer(request: DmaRequest, completed: u8, buffer: Option<DmaWord>) -> bool {
    request.direction == DmaDirection::HostToDevice
        && buffer.is_some()
        && completed == request.words.words()
}

fn worker_address_cycle(bus: &BusToCard) -> bool {
    bus.selected && bus.address_strobe && bus.space == Some(Space::Worker)
}

fn worker_address_valid(bus: &BusToCard) -> bool {
    let Some(address) = bus.ad else { return false; };
    let Some(parity) = bus.par else { return false; };
    bus.burst == BurstWords::One
        && valid_worker_transfer(address, bus.byte_enable)
        && parity_matches(address, parity, 0xf)
}

fn timed_out(wait: u16) -> bool { wait >= PLIO_TIMEOUT_CYCLES - 1 }

#[cfg(test)]
mod tests {
    use super::*;

    fn worker_read_address(address: u32) -> BusToCard {
        BusToCard {
            selected: true,
            ad: Some(address),
            par: Some(odd_parity_32(address)),
            space: Some(Space::Worker),
            address_strobe: true,
            read: true,
            byte_enable: 0xf,
            burst: BurstWords::One,
            ..BusToCard::default()
        }
    }

    fn complete_worker_read(qic: &mut Qic, address: u32, value: u32) {
        let address_cycle = worker_read_address(address);
        qic.clock(&address_cycle, &DeviceToQic::default());

        let data = BusToCard { selected: true, read: true, data_strobe: true, ..BusToCard::default() };
        qic.clock(&data, &DeviceToQic::default());

        let ready = DeviceToQic { mmio_ready: true, ..DeviceToQic::default() };
        let (_, local) = qic.drive(&data, &ready);
        assert_eq!(
            local.mmio_request,
            Some(MmioRequest { address, write: false, byte_enable: 0xf, write_data: 0 })
        );
        qic.clock(&data, &ready);

        let response = DeviceToQic {
            mmio_response: Some(MmioResponse::ReadOk(value)),
            ..DeviceToQic::default()
        };
        let (card, _) = qic.drive(&data, &response);
        assert!(card.ack);
        assert_eq!(card.ad, Some(value));
        qic.clock(&data, &response);
    }

    #[test]
    fn invalid_worker_address_parity_is_rejected_immediately() {
        let qic = Qic::new();
        let address = 0x100;
        let bus = BusToCard {
            selected: true,
            ad: Some(address),
            par: Some(odd_parity_32(address) ^ 1),
            space: Some(Space::Worker),
            address_strobe: true,
            read: true,
            byte_enable: 0xf,
            ..BusToCard::default()
        };
        let (card, _) = qic.drive(&bus, &DeviceToQic::default());
        assert!(card.err);
        assert!(!card.ack);
    }

    #[test]
    fn invalid_worker_write_data_parity_never_reaches_qli() {
        let mut qic = Qic::new();
        let address = 0x100;
        let address_cycle = BusToCard {
            selected: true,
            ad: Some(address),
            par: Some(odd_parity_32(address)),
            space: Some(Space::Worker),
            address_strobe: true,
            read: false,
            byte_enable: 0xf,
            ..BusToCard::default()
        };
        qic.clock(&address_cycle, &DeviceToQic::default());

        let data = 0x1234_5678;
        let bad_data = BusToCard {
            selected: true,
            ad: Some(data),
            par: Some(odd_parity_32(data) ^ 1),
            data_strobe: true,
            byte_enable: 0xf,
            ..BusToCard::default()
        };
        let (card, local) = qic.drive(&bad_data, &DeviceToQic::default());
        assert!(card.err);
        assert!(local.mmio_request.is_none());
    }

    #[test]
    fn valid_worker_address_is_acknowledged_before_data_phase() {
        let qic = Qic::new();
        let address = 0x104;
        let bus = BusToCard {
            selected: true,
            ad: Some(address),
            par: Some(odd_parity_32(address)),
            space: Some(Space::Worker),
            address_strobe: true,
            read: true,
            byte_enable: 0xf,
            burst: BurstWords::One,
            ..BusToCard::default()
        };
        let (card, _) = qic.drive(&bus, &DeviceToQic::default());
        assert!(card.ack);
        assert!(!card.err);
    }

    #[test]
    fn worker_write_data_parity_uses_latched_address_byte_enable() {
        let mut qic = Qic::new();
        let address = 0x100;
        let address_cycle = BusToCard {
            selected: true,
            ad: Some(address),
            par: Some(odd_parity_32(address)),
            space: Some(Space::Worker),
            address_strobe: true,
            read: false,
            byte_enable: 0x3,
            burst: BurstWords::One,
            ..BusToCard::default()
        };
        qic.clock(&address_cycle, &DeviceToQic::default());

        let data = 0x1234_5678;
        let data_cycle = BusToCard {
            selected: true,
            ad: Some(data),
            par: Some(odd_parity_32(data) ^ 0x1),
            data_strobe: true,
            // BE is an address-phase control. Deliberately change the sampled
            // data-phase value to prove the QIC uses its latched copy.
            byte_enable: 0,
            ..BusToCard::default()
        };
        let (card, local) = qic.drive(&data_cycle, &DeviceToQic::default());
        assert!(card.err);
        assert!(local.mmio_request.is_none());
    }

    #[test]
    fn worker_read_does_not_reach_qli_before_data_strobe() {
        let mut qic = Qic::new();
        let address = 0x108;
        let address_cycle = BusToCard {
            selected: true,
            ad: Some(address),
            par: Some(odd_parity_32(address)),
            space: Some(Space::Worker),
            address_strobe: true,
            read: true,
            byte_enable: 0xf,
            burst: BurstWords::One,
            ..BusToCard::default()
        };
        qic.clock(&address_cycle, &DeviceToQic::default());

        let no_data = BusToCard { selected: true, read: true, ..BusToCard::default() };
        let (_, local) = qic.drive(&no_data, &DeviceToQic::default());
        assert!(local.mmio_request.is_none());

        qic.clock(&no_data, &DeviceToQic::default());
        let data = BusToCard { selected: true, read: true, data_strobe: true, ..BusToCard::default() };
        qic.clock(&data, &DeviceToQic::default());
        let (_, local) = qic.drive(&data, &DeviceToQic::default());
        assert_eq!(local.mmio_request, Some(MmioRequest { address, write: false, byte_enable: 0xf, write_data: 0 }));
    }

    #[test]
    fn manager_drives_only_request_before_grant() {
        let mut qic = Qic::new();
        let request = DmaRequest {
            direction: DmaDirection::HostToDevice,
            address: 0x1000,
            words: BurstWords::Four,
        };
        qic.clock(
            &BusToCard::default(),
            &DeviceToQic { dma_request: Some(request), ..DeviceToQic::default() },
        );
        let (card, _) = qic.drive(&BusToCard::default(), &DeviceToQic::default());
        assert!(card.request);
        assert!(!card.address_strobe);
        assert!(!card.data_strobe);
        assert!(card.ad.is_none());
        assert!(card.par.is_none());
        assert!(card.space.is_none());
    }

    #[test]
    fn worker_read_does_not_drop_pending_notification_before_grant() {
        let mut qic = Qic::new();
        let notification = NotificationRequest { channel: 2 };
        qic.clock(
            &BusToCard::default(),
            &DeviceToQic { notification_request: Some(notification), ..DeviceToQic::default() },
        );

        let address_cycle = worker_read_address(0x134);
        let (card, _) = qic.drive(&address_cycle, &DeviceToQic::default());
        assert!(card.request);
        assert!(card.ack);

        complete_worker_read(&mut qic, 0x134, 0xfeed_beef);

        let (requesting, _) = qic.drive(&BusToCard::default(), &DeviceToQic::default());
        assert!(requesting.request);
        assert!(!requesting.address_strobe);

        qic.clock(&BusToCard { grant: true, ..BusToCard::default() }, &DeviceToQic::default());
        let (address, _) = qic.drive(
            &BusToCard { grant: true, ..BusToCard::default() },
            &DeviceToQic::default(),
        );
        assert!(address.request);
        assert!(address.address_strobe);
        assert_eq!(address.space, Some(Space::Controller));
        assert_eq!(address.ad, Some(8));
    }

    #[test]
    fn accepted_dma_survives_worker_read_before_grant() {
        let mut qic = Qic::new();
        let request = DmaRequest {
            direction: DmaDirection::HostToDevice,
            address: 0x2468,
            words: BurstWords::Four,
        };
        qic.clock(
            &BusToCard::default(),
            &DeviceToQic { dma_request: Some(request), ..DeviceToQic::default() },
        );

        let address_cycle = worker_read_address(0x138);
        let (card, _) = qic.drive(&address_cycle, &DeviceToQic::default());
        assert!(card.request);
        assert!(card.ack);

        complete_worker_read(&mut qic, 0x138, 0x1234_5678);

        qic.clock(&BusToCard { grant: true, ..BusToCard::default() }, &DeviceToQic::default());
        let (address, _) = qic.drive(
            &BusToCard { grant: true, ..BusToCard::default() },
            &DeviceToQic::default(),
        );
        assert!(address.request);
        assert!(address.address_strobe);
        assert_eq!(address.space, Some(Space::HostDma));
        assert_eq!(address.ad, Some(request.address));
        assert!(address.read);
        assert_eq!(address.burst, request.words);
    }

    #[test]
    fn reset_cancels_an_inflight_manager_request() {
        let mut qic = Qic::new();
        let request = DmaRequest {
            direction: DmaDirection::HostToDevice,
            address: 0x1000,
            words: BurstWords::Four,
        };
        qic.clock(
            &BusToCard::default(),
            &DeviceToQic { dma_request: Some(request), ..DeviceToQic::default() },
        );
        assert!(!qic.is_idle());
        qic.clock(&BusToCard { reset: true, ..BusToCard::default() }, &DeviceToQic::default());
        assert!(qic.is_idle());
    }
}

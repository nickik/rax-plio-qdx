#![forbid(unsafe_code)]

use plio_logical_model::{
    odd_parity_32, parity_matches, valid_worker_address, BusToCard, BurstWords,
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
    WorkerWriteData { address: u32, byte_enable: u8, wait: u16 },
    WorkerOffer { request: MmioRequest, wait: u16 },
    WorkerResponse { read: bool, wait: u16 },
    RequestBus(ManagerWork),
    DmaAddress(DmaRequest),
    DmaData {
        request: DmaRequest,
        completed: u8,
        wait: u16,
        buffer: Option<DmaWord>,
    },
    DmaComplete { completion: DmaCompletion },
    NotificationAddress(NotificationRequest),
    NotificationData { request: NotificationRequest, wait: u16 },
}

#[derive(Debug, Clone, Copy)]
pub struct Qic {
    state: State,
}

impl Default for Qic {
    fn default() -> Self { Self::new() }
}

impl Qic {
    pub const fn new() -> Self { Self { state: State::Idle } }

    pub fn is_idle(&self) -> bool { self.state == State::Idle }

    pub fn drive(&self, bus: &BusToCard, device: &DeviceToQic) -> (CardToBus, QicToDevice) {
        let mut card = CardToBus::default();
        let mut qli = QicToDevice::default();

        if bus.reset {
            qli.reset = true;
            return (card, qli);
        }

        match self.state {
            State::Idle => {
                if worker_address_cycle(bus) {
                    if !worker_address_valid(bus) { card.err = true; }
                } else if let Some(notification) = device.notification_request {
                    let _ = notification.validate();
                    // Completion-based handshake: ready stays low until PLIO ACK.
                } else if let Some(request) = device.dma_request {
                    if request.validate().is_ok() { qli.dma_request_ready = true; }
                }
            }
            State::WorkerWriteData { wait, .. } => {
                if timed_out(wait) { card.err = true; }
                if bus.data_strobe
                    && (bus.ad.is_none()
                        || bus.par.is_none()
                        || !parity_matches(bus.ad.unwrap_or(0), bus.par.unwrap_or(0), bus.byte_enable))
                {
                    card.err = true;
                }
            }
            State::WorkerOffer { request, wait } => {
                if timed_out(wait) { card.err = true; }
                qli.mmio_request = Some(request);
            }
            State::WorkerResponse { read, wait } => {
                if timed_out(wait) { card.err = true; }
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
                            MmioResponse::Error(_) => card.err = true,
                            _ => card.err = true,
                        }
                    }
                }
            }
            State::RequestBus(_) => card.request = true,
            State::DmaAddress(request) => {
                card.request = true;
                if bus.grant {
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
                if (!final_read_buffer && !bus.grant) || (!final_read_buffer && timed_out(wait)) {
                    return (card, qli);
                }

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
            State::NotificationAddress(request) => {
                card.request = true;
                if bus.grant {
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
            return;
        }

        // BG is authority to drive PLIO. The one exception is draining the
        // already-ACKed final host->device word from the QIC's local buffer;
        // no PLIO bus work remains at that point.
        match self.state {
            State::DmaAddress(_) if !bus.grant => {
                self.state = State::DmaComplete {
                    completion: DmaCompletion {
                        status: DmaStatus::ProtocolError,
                        words_completed: 0,
                    },
                };
                return;
            }
            State::DmaData { request, completed, buffer, .. }
                if !bus.grant && !is_final_read_buffer(request, completed, buffer) =>
            {
                self.state = State::DmaComplete {
                    completion: DmaCompletion {
                        status: DmaStatus::ProtocolError,
                        words_completed: completed,
                    },
                };
                return;
            }
            State::NotificationAddress(_) | State::NotificationData { .. } if !bus.grant => {
                // Notification is idempotent. No local acknowledgement means
                // the producer keeps it asserted and the QIC retries.
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
                            State::WorkerOffer {
                                request: MmioRequest {
                                    address,
                                    write: false,
                                    byte_enable: bus.byte_enable,
                                    write_data: 0,
                                },
                                wait: 0,
                            }
                        } else {
                            State::WorkerWriteData {
                                address,
                                byte_enable: bus.byte_enable,
                                wait: 0,
                            }
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
            State::WorkerWriteData { address, byte_enable, wait } => {
                if timed_out(wait) {
                    State::Idle
                } else if bus.data_strobe {
                    match (bus.ad, bus.par) {
                        (Some(data), Some(parity)) if parity_matches(data, parity, byte_enable) => {
                            State::WorkerOffer {
                                request: MmioRequest {
                                    address,
                                    write: true,
                                    byte_enable,
                                    write_data: data,
                                },
                                wait: 0,
                            }
                        }
                        _ => State::Idle,
                    }
                } else {
                    State::WorkerWriteData {
                        address,
                        byte_enable,
                        wait: wait.saturating_add(1),
                    }
                }
            }
            State::WorkerOffer { request, wait } => {
                if timed_out(wait) {
                    State::Idle
                } else if device.mmio_ready {
                    State::WorkerResponse {
                        read: !request.write,
                        wait: 0,
                    }
                } else {
                    State::WorkerOffer {
                        request,
                        wait: wait.saturating_add(1),
                    }
                }
            }
            State::WorkerResponse { read, wait } => {
                if timed_out(wait) {
                    State::Idle
                } else if bus.data_strobe && device.mmio_response.is_some() {
                    State::Idle
                } else {
                    State::WorkerResponse {
                        read,
                        wait: wait.saturating_add(1),
                    }
                }
            }
            State::RequestBus(work) => {
                if bus.grant {
                    match work {
                        ManagerWork::Dma(request) => State::DmaAddress(request),
                        ManagerWork::Notification(request) => State::NotificationAddress(request),
                    }
                } else {
                    State::RequestBus(work)
                }
            }
            State::DmaAddress(request) => {
                if bus.err {
                    State::DmaComplete {
                        completion: DmaCompletion {
                            status: DmaStatus::BusError,
                            words_completed: 0,
                        },
                    }
                } else {
                    State::DmaData {
                        request,
                        completed: 0,
                        wait: 0,
                        buffer: None,
                    }
                }
            }
            State::DmaData { request, completed, wait, buffer } => {
                if is_final_read_buffer(request, completed, buffer) {
                    if device.dma_read_ready {
                        State::DmaComplete {
                            completion: DmaCompletion {
                                status: DmaStatus::Ok,
                                words_completed: completed,
                            },
                        }
                    } else {
                        State::DmaData { request, completed, wait, buffer }
                    }
                } else if timed_out(wait) {
                    State::DmaComplete {
                        completion: DmaCompletion {
                            status: DmaStatus::Timeout,
                            words_completed: completed,
                        },
                    }
                } else {
                    match request.direction {
                        DmaDirection::HostToDevice => {
                            if let Some(word) = buffer {
                                if device.dma_read_ready {
                                    State::DmaData {
                                        request,
                                        completed,
                                        wait: 0,
                                        buffer: None,
                                    }
                                } else {
                                    State::DmaData {
                                        request,
                                        completed,
                                        wait,
                                        buffer: Some(word),
                                    }
                                }
                            } else if bus.err {
                                State::DmaComplete {
                                    completion: DmaCompletion {
                                        status: DmaStatus::BusError,
                                        words_completed: completed,
                                    },
                                }
                            } else if bus.ack {
                                match (bus.ad, bus.par) {
                                    (Some(data), Some(parity)) if parity_matches(data, parity, 0xf) => {
                                        let next = completed + 1;
                                        State::DmaData {
                                            request,
                                            completed: next,
                                            wait: 0,
                                            buffer: Some(DmaWord {
                                                data,
                                                last: next == request.words.words(),
                                            }),
                                        }
                                    }
                                    _ => State::DmaComplete {
                                        completion: DmaCompletion {
                                            status: DmaStatus::ParityError,
                                            words_completed: completed,
                                        },
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
                                        completion: DmaCompletion {
                                            status: DmaStatus::BusError,
                                            words_completed: completed,
                                        },
                                    }
                                } else if bus.ack {
                                    let next = completed + 1;
                                    if next == request.words.words() {
                                        State::DmaComplete {
                                            completion: DmaCompletion {
                                                status: DmaStatus::Ok,
                                                words_completed: next,
                                            },
                                        }
                                    } else {
                                        State::DmaData {
                                            request,
                                            completed: next,
                                            wait: 0,
                                            buffer: None,
                                        }
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
                                let expected_last = completed + 1 == request.words.words();
                                if word.last != expected_last {
                                    State::DmaComplete {
                                        completion: DmaCompletion {
                                            status: DmaStatus::ProtocolError,
                                            words_completed: completed,
                                        },
                                    }
                                } else {
                                    State::DmaData {
                                        request,
                                        completed,
                                        wait: 0,
                                        buffer: Some(word),
                                    }
                                }
                            } else {
                                State::DmaData {
                                    request,
                                    completed,
                                    wait,
                                    buffer: None,
                                }
                            }
                        }
                    }
                }
            }
            State::DmaComplete { completion } => {
                if device.dma_completion_ready {
                    State::Idle
                } else {
                    State::DmaComplete { completion }
                }
            }
            State::NotificationAddress(request) => {
                if bus.err {
                    State::Idle
                } else {
                    State::NotificationData { request, wait: 0 }
                }
            }
            State::NotificationData { request, wait } => {
                if timed_out(wait) || bus.err {
                    State::Idle
                } else if bus.ack && device.notification_request == Some(request) {
                    State::Idle
                } else {
                    State::NotificationData {
                        request,
                        wait: wait.saturating_add(1),
                    }
                }
            }
        };
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
    bus.burst == BurstWords::One
        && bus.ad.is_some()
        && valid_worker_address(bus.ad.unwrap_or(u32::MAX))
        && bus.par.is_some()
        && parity_matches(bus.ad.unwrap_or(0), bus.par.unwrap_or(0), 0xf)
        && bus.byte_enable != 0
        && bus.byte_enable & !0xf == 0
}

fn timed_out(wait: u16) -> bool { wait >= PLIO_TIMEOUT_CYCLES - 1 }

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_worker_address(read: bool) -> BusToCard {
        let address = 0x100;
        BusToCard {
            selected: true,
            ad: Some(address),
            par: Some(odd_parity_32(address)),
            space: Some(Space::Worker),
            address_strobe: true,
            read,
            byte_enable: 0xf,
            ..BusToCard::default()
        }
    }

    #[test]
    fn invalid_worker_address_parity_is_rejected_immediately() {
        let qic = Qic::new();
        let mut bus = valid_worker_address(true);
        bus.par = Some(bus.par.unwrap() ^ 1);
        let (card, _) = qic.drive(&bus, &DeviceToQic::default());
        assert!(card.err);
        assert!(!card.ack);
    }

    #[test]
    fn invalid_worker_write_data_parity_never_reaches_qli() {
        let mut qic = Qic::new();
        let address = valid_worker_address(false);
        qic.clock(&address, &DeviceToQic::default());

        let data = 0x1234_5678;
        let bus = BusToCard {
            selected: true,
            ad: Some(data),
            par: Some(odd_parity_32(data) ^ 1),
            data_strobe: true,
            byte_enable: 0xf,
            ..BusToCard::default()
        };
        let (card, qli) = qic.drive(&bus, &DeviceToQic::default());
        assert!(card.err);
        assert!(qli.mmio_request.is_none());
        qic.clock(&bus, &DeviceToQic::default());
        let (_, qli_after) = qic.drive(&BusToCard::default(), &DeviceToQic::default());
        assert!(qli_after.mmio_request.is_none());
        assert!(qic.is_idle());
    }

    #[test]
    fn reset_cancels_an_inflight_manager_request() {
        let mut qic = Qic::new();
        let request = DmaRequest {
            direction: DmaDirection::HostToDevice,
            address: 0x1000,
            words: BurstWords::Four,
        };
        let device = DeviceToQic { dma_request: Some(request), ..DeviceToQic::default() };
        qic.clock(&BusToCard::default(), &device);
        assert!(!qic.is_idle());

        let reset = BusToCard { reset: true, ..BusToCard::default() };
        let (card, local) = qic.drive(&reset, &device);
        assert!(local.reset);
        assert!(!card.request);
        qic.clock(&reset, &device);
        assert!(qic.is_idle());
    }

    #[test]
    fn losing_grant_during_unfinished_dma_reports_protocol_error() {
        let mut qic = Qic::new();
        let request = DmaRequest {
            direction: DmaDirection::HostToDevice,
            address: 0x1000,
            words: BurstWords::Four,
        };
        let device = DeviceToQic { dma_request: Some(request), ..DeviceToQic::default() };
        qic.clock(&BusToCard::default(), &device);
        qic.clock(&BusToCard { grant: true, ..BusToCard::default() }, &device);
        qic.clock(&BusToCard { grant: true, ..BusToCard::default() }, &DeviceToQic::default());

        let lost = BusToCard::default();
        qic.clock(&lost, &DeviceToQic::default());
        let (_, local) = qic.drive(&lost, &DeviceToQic::default());
        assert_eq!(
            local.dma_completion,
            Some(DmaCompletion { status: DmaStatus::ProtocolError, words_completed: 0 })
        );
    }
}

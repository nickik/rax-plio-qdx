use std::collections::VecDeque;

use plio_logical_model::BurstWords;
use plio_qic_model::Qic;
use plio_testbench::TestPeer;
use qli_model::{
    DeviceToQic, DmaCompletion, DmaDirection, DmaRequest, DmaStatus, DmaWord,
    NotificationRequest, QicToDevice,
};

#[derive(Default)]
struct ScriptDevice {
    dma_request: Option<DmaRequest>,
    dma_write_words: VecDeque<DmaWord>,
    dma_reads: Vec<u32>,
    completion: Option<DmaCompletion>,
    notification: Option<NotificationRequest>,
}

impl ScriptDevice {
    fn drive(&self) -> DeviceToQic {
        DeviceToQic {
            mmio_ready: true,
            dma_request: self.dma_request,
            dma_read_ready: true,
            dma_write: self.dma_write_words.front().copied(),
            dma_completion_ready: true,
            notification_request: self.notification,
            ..DeviceToQic::default()
        }
    }

    fn clock(&mut self, qic: &QicToDevice) {
        if qic.dma_request_ready { self.dma_request = None; }
        if let Some(word) = qic.dma_read { self.dma_reads.push(word.data); }
        if qic.dma_write_ready && !self.dma_write_words.is_empty() { self.dma_write_words.pop_front(); }
        if let Some(completion) = qic.dma_completion { self.completion = Some(completion); }
        if qic.notification_ready { self.notification = None; }
    }
}

fn step(qic: &mut Qic, dev: &mut ScriptDevice, peer: &mut TestPeer) {
    let bus = peer.bus_inputs();
    let dev_drive = dev.drive();
    let (card, qic_drive) = qic.drive(&bus, &dev_drive);
    peer.clock(&card);
    dev.clock(&qic_drive);
    qic.clock(&bus, &dev_drive);
}

fn run(qic: &mut Qic, dev: &mut ScriptDevice, peer: &mut TestPeer, limit: usize) {
    for _ in 0..limit {
        step(qic, dev, peer);
        if dev.completion.is_some() || (dev.notification.is_none() && !peer.notifications().is_empty()) { return; }
    }
    panic!("transaction did not finish in {limit} cycles");
}

#[test]
fn host_to_device_dma_supports_all_baseline_bursts() {
    for burst in [BurstWords::One, BurstWords::Four, BurstWords::Eight, BurstWords::Sixteen] {
        let mut qic = Qic::new();
        let mut dev = ScriptDevice {
            dma_request: Some(DmaRequest { direction: DmaDirection::HostToDevice, address: 0x2100_1000, words: burst }),
            ..ScriptDevice::default()
        };
        let mut peer = TestPeer::new();
        run(&mut qic, &mut dev, &mut peer, 512);
        assert_eq!(dev.completion, Some(DmaCompletion { status: DmaStatus::Ok, words_completed: burst.words() }));
        assert_eq!(dev.dma_reads.len(), usize::from(burst.words()));
        for (index, data) in dev.dma_reads.iter().enumerate() {
            assert_eq!(*data, peer.dma_read_base + index as u32 * 4);
        }
        assert_eq!(peer.last_dma_address(), Some(0x2100_1000));
        assert_eq!(peer.last_dma_burst(), Some(burst));
    }
}

#[test]
fn host_to_device_dma_tolerates_plio_wait_states() {
    let mut qic = Qic::new();
    let mut dev = ScriptDevice {
        dma_request: Some(DmaRequest { direction: DmaDirection::HostToDevice, address: 0x2200_0000, words: BurstWords::Four }),
        ..ScriptDevice::default()
    };
    let mut peer = TestPeer::new();
    peer.dma_wait_cycles = 3;
    run(&mut qic, &mut dev, &mut peer, 256);
    assert_eq!(dev.completion, Some(DmaCompletion { status: DmaStatus::Ok, words_completed: 4 }));
    assert_eq!(dev.dma_reads.len(), 4);
}

#[test]
fn device_to_host_dma_streams_words_and_reports_completion() {
    let words = [0x11, 0x22, 0x33, 0x44];
    let mut dev = ScriptDevice {
        dma_request: Some(DmaRequest { direction: DmaDirection::DeviceToHost, address: 0x3300_2000, words: BurstWords::Four }),
        dma_write_words: words.into_iter().map(|data| DmaWord { data }).collect(),
        ..ScriptDevice::default()
    };
    let mut qic = Qic::new();
    let mut peer = TestPeer::new();
    run(&mut qic, &mut dev, &mut peer, 128);
    assert_eq!(peer.dma_writes(), words);
    assert_eq!(dev.completion, Some(DmaCompletion { status: DmaStatus::Ok, words_completed: 4 }));
}

#[test]
fn dma_error_reports_exact_partial_progress() {
    let words = [1, 2, 3, 4];
    let mut dev = ScriptDevice {
        dma_request: Some(DmaRequest { direction: DmaDirection::DeviceToHost, address: 0x4400_0000, words: BurstWords::Four }),
        dma_write_words: words.into_iter().map(|data| DmaWord { data }).collect(),
        ..ScriptDevice::default()
    };
    let mut qic = Qic::new();
    let mut peer = TestPeer::new();
    peer.dma_error_beat = Some(2);
    run(&mut qic, &mut dev, &mut peer, 128);
    assert_eq!(dev.completion, Some(DmaCompletion { status: DmaStatus::BusError, words_completed: 2 }));
    assert_eq!(peer.dma_writes(), &[1, 2]);
}

#[test]
fn bad_read_parity_aborts_before_corrupted_word_is_delivered() {
    let mut dev = ScriptDevice {
        dma_request: Some(DmaRequest { direction: DmaDirection::HostToDevice, address: 0x5500_0000, words: BurstWords::Four }),
        ..ScriptDevice::default()
    };
    let mut qic = Qic::new();
    let mut peer = TestPeer::new();
    peer.dma_bad_parity_beat = Some(1);
    run(&mut qic, &mut dev, &mut peer, 128);
    assert_eq!(dev.completion, Some(DmaCompletion { status: DmaStatus::ParityError, words_completed: 1 }));
    assert_eq!(dev.dma_reads.len(), 1);
}

#[test]
fn notification_ready_means_bus_transaction_completed() {
    let mut dev = ScriptDevice { notification: Some(NotificationRequest { channel: 2 }), ..ScriptDevice::default() };
    let mut qic = Qic::new();
    let mut peer = TestPeer::new();
    peer.notification_wait_cycles = 3;

    for _ in 0..5 {
        step(&mut qic, &mut dev, &mut peer);
        assert_eq!(dev.notification, Some(NotificationRequest { channel: 2 }));
    }
    run(&mut qic, &mut dev, &mut peer, 64);
    assert!(dev.notification.is_none());
    assert_eq!(peer.notifications(), &[2]);
}

#[test]
fn notification_wins_over_new_dma_but_never_preempts_active_dma() {
    let mut qic = Qic::new();
    let mut peer = TestPeer::new();
    let mut dev = ScriptDevice {
        dma_request: Some(DmaRequest { direction: DmaDirection::HostToDevice, address: 0x6600_0000, words: BurstWords::Four }),
        notification: Some(NotificationRequest { channel: 1 }),
        ..ScriptDevice::default()
    };

    // At an idle boundary Notification has priority, so the DMA request must
    // remain unaccepted until the Notification transaction finishes.
    for _ in 0..32 {
        step(&mut qic, &mut dev, &mut peer);
        if dev.notification.is_none() { break; }
        assert!(dev.dma_request.is_some());
    }
    assert_eq!(peer.notifications(), &[1]);
    assert!(dev.dma_request.is_some());

    run(&mut qic, &mut dev, &mut peer, 128);
    assert_eq!(dev.completion, Some(DmaCompletion { status: DmaStatus::Ok, words_completed: 4 }));
}

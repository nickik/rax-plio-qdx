use naked_card::{
    NakedDevice, CFG_DEVICE_CONTROL, CFG_ID, CFG_VENDOR_DEVICE, PLIO_ID, TEST_DEVICE_ID,
    TEST_VENDOR_ID,
};
use plio_qic_model::Qic;
use plio_testbench::{TestPeer, WorkerResult};

fn step(qic: &mut Qic, device: &mut NakedDevice, peer: &mut TestPeer) {
    let bus = peer.bus_inputs();
    let device_drive = device.drive();
    let (card, qic_drive) = qic.drive(&bus, &device_drive);
    peer.clock(&card);
    device.clock(&qic_drive);
    qic.clock(&bus, &device_drive);
}

fn run_until_result(qic: &mut Qic, device: &mut NakedDevice, peer: &mut TestPeer) -> WorkerResult {
    for _ in 0..64 {
        step(qic, device, peer);
        if let Some(result) = peer.worker_result() { return result; }
    }
    panic!("worker transaction did not finish");
}

#[test]
fn naked_card_plio_read_reaches_qli_device() {
    let mut qic = Qic::new();
    let mut device = NakedDevice::new();
    let mut peer = TestPeer::new();
    peer.start_worker_read(CFG_ID, 0xf);
    assert_eq!(run_until_result(&mut qic, &mut device, &mut peer), WorkerResult::Read(PLIO_ID));
    assert!(qic.is_idle());
}

#[test]
fn naked_card_supports_natural_8_16_32_bit_worker_reads() {
    let expected = u32::from(TEST_VENDOR_ID) | (u32::from(TEST_DEVICE_ID) << 16);
    for (address, be) in [
        (CFG_VENDOR_DEVICE, 0xf),
        (CFG_VENDOR_DEVICE, 0x3),
        (CFG_VENDOR_DEVICE + 2, 0xc),
        (CFG_VENDOR_DEVICE + 3, 0x8),
    ] {
        let mut qic = Qic::new();
        let mut device = NakedDevice::new();
        let mut peer = TestPeer::new();
        peer.start_worker_read(address, be);
        assert_eq!(run_until_result(&mut qic, &mut device, &mut peer), WorkerResult::Read(expected));
    }
}

#[test]
fn naked_card_rejects_misaligned_worker_access_before_qli() {
    let mut qic = Qic::new();
    let mut device = NakedDevice::new();
    let mut peer = TestPeer::new();
    peer.start_worker_read(CFG_VENDOR_DEVICE + 1, 0x3);
    assert_eq!(run_until_result(&mut qic, &mut device, &mut peer), WorkerResult::Error);
}

#[test]
fn naked_card_worker_write_reaches_qli_device() {
    let mut qic = Qic::new();
    let mut device = NakedDevice::new();
    let mut peer = TestPeer::new();
    peer.start_worker_write(CFG_DEVICE_CONTROL, 0xf, 0x1234_5678);
    assert_eq!(run_until_result(&mut qic, &mut device, &mut peer), WorkerResult::WriteOk);
}

#[test]
fn naked_card_unknown_mmio_returns_plio_error() {
    let mut qic = Qic::new();
    let mut device = NakedDevice::new();
    let mut peer = TestPeer::new();
    peer.start_worker_read(0x80, 0xf);
    assert_eq!(run_until_result(&mut qic, &mut device, &mut peer), WorkerResult::Error);
}

#[test]
fn naked_card_never_requests_bus_manager_ownership() {
    let mut qic = Qic::new();
    let mut device = NakedDevice::new();
    let mut peer = TestPeer::new();
    for _ in 0..32 {
        let bus = peer.bus_inputs();
        let device_drive = device.drive();
        let (card, qic_drive) = qic.drive(&bus, &device_drive);
        assert!(!card.request);
        peer.clock(&card);
        device.clock(&qic_drive);
        qic.clock(&bus, &device_drive);
    }
}

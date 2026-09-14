#![forbid(unsafe_code)]

use plio_logical_model::BurstWords;

pub const QLI_VERSION: u16 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MmioRequest {
    pub address: u32,
    pub write: bool,
    pub byte_enable: u8,
    pub write_data: u32,
}

impl MmioRequest {
    pub fn validate(&self) -> Result<(), &'static str> {
        if self.address >= (1 << 25) {
            return Err("QLI MMIO address exceeds 25-bit PLIO worker space");
        }
        if self.byte_enable == 0 || self.byte_enable & !0x0f != 0 {
            return Err("QLI MMIO byte_enable must select at least one of four lanes");
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MmioResponse {
    ReadOk(u32),
    WriteOk,
    Error(u8),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DmaDirection {
    HostToDevice,
    DeviceToHost,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DmaRequest {
    pub direction: DmaDirection,
    pub address: u32,
    pub words: BurstWords,
}

impl DmaRequest {
    pub fn validate(&self) -> Result<(), &'static str> {
        if self.address & 3 != 0 {
            return Err("QLI DMA handle offset must be longword aligned");
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DmaWord {
    pub data: u32,
    pub last: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DmaStatus {
    Ok,
    BusError,
    ParityError,
    Timeout,
    ProtocolError,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DmaCompletion {
    pub status: DmaStatus,
    pub words_completed: u8,
}

impl DmaCompletion {
    pub fn validate(&self, requested: BurstWords) -> Result<(), &'static str> {
        if self.words_completed > requested.words() {
            return Err("QLI DMA completion exceeds requested burst length");
        }
        if self.status == DmaStatus::Ok && self.words_completed != requested.words() {
            return Err("successful QLI DMA completion must report the entire burst");
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NotificationRequest {
    pub channel: u8,
}

impl NotificationRequest {
    pub fn validate(&self) -> Result<(), &'static str> {
        if self.channel > 3 {
            return Err("QLI notification channel must be 0..3");
        }
        Ok(())
    }
}

/// Local-device signals sampled by the QIC in one QLI clock step.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct DeviceToQic {
    pub mmio_ready: bool,
    pub mmio_response: Option<MmioResponse>,
    pub dma_request: Option<DmaRequest>,
    pub dma_read_ready: bool,
    pub dma_write: Option<DmaWord>,
    pub dma_completion_ready: bool,
    pub notification_request: Option<NotificationRequest>,
}

/// QIC signals sampled by the local device in one QLI clock step.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct QicToDevice {
    pub reset: bool,
    pub mmio_request: Option<MmioRequest>,
    pub mmio_response_ready: bool,
    pub dma_request_ready: bool,
    pub dma_read: Option<DmaWord>,
    pub dma_write_ready: bool,
    pub dma_completion: Option<DmaCompletion>,
    /// Completion-based Notification handshake: the producer holds the
    /// request stable until the PLIO CONTROLLER transaction is ACKed.
    pub notification_ready: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mmio_is_slot_relative_only() {
        let good = MmioRequest { address: 0x01ff_fffc, write: false, byte_enable: 0xf, write_data: 0 };
        let bad = MmioRequest { address: 0x0200_0000, ..good };
        assert!(good.validate().is_ok());
        assert!(bad.validate().is_err());
    }

    #[test]
    fn dma_handle_must_be_longword_aligned() {
        let mut req = DmaRequest { direction: DmaDirection::HostToDevice, address: 0x1200_1000, words: BurstWords::Four };
        assert!(req.validate().is_ok());
        req.address += 2;
        assert!(req.validate().is_err());
    }

    #[test]
    fn successful_completion_must_be_complete() {
        let bad = DmaCompletion { status: DmaStatus::Ok, words_completed: 3 };
        let partial_error = DmaCompletion { status: DmaStatus::BusError, words_completed: 3 };
        assert!(bad.validate(BurstWords::Four).is_err());
        assert!(partial_error.validate(BurstWords::Four).is_ok());
    }

    #[test]
    fn notification_is_only_a_small_channel_number() {
        assert!(NotificationRequest { channel: 3 }.validate().is_ok());
        assert!(NotificationRequest { channel: 4 }.validate().is_err());
    }
}

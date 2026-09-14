#![forbid(unsafe_code)]

use plio_logical_model::{valid_worker_transfer, BurstWords};

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
        if !valid_worker_transfer(self.address, self.byte_enable) {
            return Err("QLI MMIO must be a naturally aligned 8/16/32-bit PLIO worker transfer inside the 25-bit slot space");
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MmioResponse {
    ReadOk(u32),
    WriteOk,
    Error,
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
            return Err("QLI DMA handle must be longword aligned");
        }
        Ok(())
    }
}

/// One 32-bit word on either QLI DMA data channel.
/// There is deliberately no LAST field: the accepted DmaRequest already fixes
/// the transfer length at 1/4/8/16 words and both sides count the words.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DmaWord {
    pub data: u32,
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
/// Option<T> is the cycle-model representation of a valid payload.
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
    /// Cancels a previously accepted MMIO request whose PLIO transaction
    /// terminated before its response could be consumed.
    pub mmio_cancel: bool,
    pub mmio_request: Option<MmioRequest>,
    pub mmio_response_ready: bool,
    pub dma_request_ready: bool,
    pub dma_read: Option<DmaWord>,
    pub dma_write_ready: bool,
    pub dma_completion: Option<DmaCompletion>,
    /// Completion-based Notification handshake. The producer holds the same
    /// request stable until the PLIO CONTROLLER transaction has been ACKed.
    pub notification_ready: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mmio_accepts_exactly_natural_8_16_32_bit_worker_transfers() {
        for req in [
            MmioRequest { address: 0x100, write: false, byte_enable: 0x1, write_data: 0 },
            MmioRequest { address: 0x101, write: false, byte_enable: 0x2, write_data: 0 },
            MmioRequest { address: 0x102, write: false, byte_enable: 0xc, write_data: 0 },
            MmioRequest { address: 0x100, write: true, byte_enable: 0xf, write_data: 0x1234_5678 },
        ] {
            assert!(req.validate().is_ok());
        }

        for req in [
            MmioRequest { address: 0x0200_0000, write: false, byte_enable: 0x1, write_data: 0 },
            MmioRequest { address: 0x101, write: false, byte_enable: 0x3, write_data: 0 },
            MmioRequest { address: 0x100, write: false, byte_enable: 0x5, write_data: 0 },
            MmioRequest { address: 0x100, write: false, byte_enable: 0, write_data: 0 },
        ] {
            assert!(req.validate().is_err());
        }
    }

    #[test]
    fn dma_handle_must_be_longword_aligned() {
        let mut req = DmaRequest { direction: DmaDirection::HostToDevice, address: 0x1200_1000, words: BurstWords::Four };
        assert!(req.validate().is_ok());
        req.address += 2;
        assert!(req.validate().is_err());
    }

    #[test]
    fn successful_completion_must_be_complete_but_faults_may_be_partial() {
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

    #[test]
    fn dma_word_has_no_redundant_end_marker() {
        assert_eq!(core::mem::size_of::<DmaWord>(), core::mem::size_of::<u32>());
    }
}

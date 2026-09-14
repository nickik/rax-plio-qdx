#![forbid(unsafe_code)]

use plio_logical_model::BurstWords;

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
        if self.byte_enable & !0x0f != 0 || self.byte_enable == 0 {
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DmaStatus {
    Ok,
    BusError,
    ParityError,
    Timeout,
    Reset,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DmaCompletion {
    pub status: DmaStatus,
    pub words_completed: u8,
}

impl DmaCompletion {
    pub fn validate(self, requested: BurstWords) -> Result<Self, &'static str> {
        if self.words_completed > requested.words() {
            return Err("QLI DMA completion exceeds requested burst length");
        }
        Ok(self)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NotificationRequest {
    pub channel: u8,
}

impl NotificationRequest {
    pub fn validate(self) -> Result<Self, &'static str> {
        if self.channel > 3 {
            return Err("QLI notification channel must be 0..3");
        }
        Ok(self)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_host_address_sized_mmio() {
        let req = MmioRequest { address: 1 << 25, write: false, byte_enable: 0xf, write_data: 0 };
        assert!(req.validate().is_err());
    }

    #[test]
    fn notification_is_only_a_small_channel_number() {
        assert!(NotificationRequest { channel: 3 }.validate().is_ok());
        assert!(NotificationRequest { channel: 4 }.validate().is_err());
    }
}

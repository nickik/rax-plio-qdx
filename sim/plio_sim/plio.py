from __future__ import annotations

from dataclasses import dataclass

from .memory import HostMemory


class DMAFault(RuntimeError):
    pass


@dataclass(frozen=True)
class DMAChannel:
    """One controller-owned DMA capability channel for one PLIO slot."""

    host_base: int
    length: int
    readable: bool = True
    writable: bool = True

    def translate(self, offset: int, length: int, *, write_to_host: bool) -> int | None:
        if offset < 0 or length < 0 or offset + length > self.length:
            return None
        if write_to_host and not self.writable:
            return None
        if not write_to_host and not self.readable:
            return None
        return self.host_base + offset


class PLIOController:
    """Aggregate functional model of the central PLIO controller."""

    SLOT_COUNT = 8
    DMA_CHANNELS = 4
    DMA_CHANNEL_SHIFT = 30
    DMA_OFFSET_MASK = (1 << DMA_CHANNEL_SHIFT) - 1
    NOTIFY_CHANNELS = 4
    NOTIFY_CLASSES = 4

    def __init__(self, memory: HostMemory):
        self.memory = memory
        self._dma_channels: list[list[DMAChannel | None]] = [
            [None] * self.DMA_CHANNELS for _ in range(self.SLOT_COUNT)
        ]
        self._notify_pending = [
            [False] * self.NOTIFY_CHANNELS for _ in range(self.SLOT_COUNT)
        ]
        self._notify_masked = [
            [False] * self.NOTIFY_CHANNELS for _ in range(self.SLOT_COUNT)
        ]
        self._notify_enabled = [
            [True] * self.NOTIFY_CHANNELS for _ in range(self.SLOT_COUNT)
        ]
        self._notify_class = [
            [1] * self.NOTIFY_CHANNELS for _ in range(self.SLOT_COUNT)
        ]
        self._notify_last_data = [
            [0] * self.NOTIFY_CHANNELS for _ in range(self.SLOT_COUNT)
        ]

    def _check_slot(self, slot: int) -> None:
        if not 0 <= slot < self.SLOT_COUNT:
            raise ValueError(f"invalid PLIO slot {slot}")

    def _check_channel(self, channel: int, limit: int) -> None:
        if not 0 <= channel < limit:
            raise ValueError(f"invalid channel {channel}")

    @classmethod
    def dma_address(cls, channel: int, offset: int) -> int:
        if not 0 <= channel < cls.DMA_CHANNELS:
            raise ValueError("DMA channel must be 0..3")
        if not 0 <= offset <= cls.DMA_OFFSET_MASK:
            raise ValueError("DMA offset outside 30-bit range")
        return (channel << cls.DMA_CHANNEL_SHIFT) | offset

    def bind_dma_channel(self, slot: int, channel: int, mapping: DMAChannel) -> None:
        self._check_slot(slot)
        self._check_channel(channel, self.DMA_CHANNELS)
        self._dma_channels[slot][channel] = mapping

    def revoke_dma_channel(self, slot: int, channel: int) -> None:
        self._check_slot(slot)
        self._check_channel(channel, self.DMA_CHANNELS)
        self._dma_channels[slot][channel] = None

    def _translate(self, slot: int, device_address: int, length: int, *, write_to_host: bool) -> int:
        self._check_slot(slot)
        if not 0 <= device_address <= 0xFFFFFFFF:
            raise DMAFault("device DMA address outside 32-bit range")
        channel = (device_address >> self.DMA_CHANNEL_SHIFT) & 0x3
        offset = device_address & self.DMA_OFFSET_MASK
        mapping = self._dma_channels[slot][channel]
        if mapping is not None:
            translated = mapping.translate(offset, length, write_to_host=write_to_host)
            if translated is not None:
                return translated
        direction = "write" if write_to_host else "read"
        raise DMAFault(
            f"slot {slot} DMA {direction} not permitted: channel={channel} "
            f"offset=0x{offset:x} length={length}"
        )

    def dma_read(self, slot: int, device_address: int, length: int) -> bytes:
        """Device reads host memory through a protected capability channel."""
        host_address = self._translate(slot, device_address, length, write_to_host=False)
        return self.memory.read(host_address, length)

    def dma_write(self, slot: int, device_address: int, data: bytes) -> None:
        """Device writes host memory through a protected capability channel."""
        host_address = self._translate(slot, device_address, len(data), write_to_host=True)
        self.memory.write(host_address, data)

    def configure_notification(
        self,
        slot: int,
        channel: int,
        *,
        notify_class: int,
        enabled: bool = True,
    ) -> None:
        self._check_slot(slot)
        self._check_channel(channel, self.NOTIFY_CHANNELS)
        if not 0 <= notify_class < self.NOTIFY_CLASSES:
            raise ValueError("notification class must be 0..3")
        self._notify_class[slot][channel] = notify_class
        self._notify_enabled[slot][channel] = enabled

    def notify(self, slot: int, channel: int = 0, data: int = 0) -> None:
        """Model a device PLIO NOTIFY write; source slot is bus-controller context."""
        self._check_slot(slot)
        self._check_channel(channel, self.NOTIFY_CHANNELS)
        if not 0 <= data <= 0xFFFFFFFF:
            raise ValueError("notification data must be 32-bit")
        if not self._notify_enabled[slot][channel]:
            return
        self._notify_last_data[slot][channel] = data
        self._notify_pending[slot][channel] = True

    def mask_notification(self, slot: int, channel: int = 0) -> None:
        self._check_slot(slot)
        self._check_channel(channel, self.NOTIFY_CHANNELS)
        self._notify_masked[slot][channel] = True

    def unmask_notification(self, slot: int, channel: int = 0) -> None:
        self._check_slot(slot)
        self._check_channel(channel, self.NOTIFY_CHANNELS)
        self._notify_masked[slot][channel] = False

    @property
    def normal_notification_pending(self) -> bool:
        return any(
            self._notify_pending[slot][channel]
            and self._notify_enabled[slot][channel]
            and not self._notify_masked[slot][channel]
            for slot in range(self.SLOT_COUNT)
            for channel in range(self.NOTIFY_CHANNELS)
        )

    def next_notification(self) -> tuple[int, int] | None:
        candidates = [
            (slot, channel)
            for slot in range(self.SLOT_COUNT)
            for channel in range(self.NOTIFY_CHANNELS)
            if self._notify_pending[slot][channel]
            and self._notify_enabled[slot][channel]
            and not self._notify_masked[slot][channel]
        ]
        if not candidates:
            return None
        return min(
            candidates,
            key=lambda item: (-self._notify_class[item[0]][item[1]], item[0], item[1]),
        )

    def claim_notification(self) -> tuple[int, int] | None:
        selected = self.next_notification()
        if selected is None:
            return None
        slot, channel = selected
        self._notify_pending[slot][channel] = False
        return selected

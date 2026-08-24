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
    generation: int = 0

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
    SLOT_WINDOW_SIZE = 32 * 1024 * 1024

    SPACE_WORKER = 0b00
    SPACE_HOST_DMA = 0b01
    SPACE_CONTROLLER = 0b10
    SPACE_RESERVED = 0b11

    BURST_WORDS = (1, 4, 8, 16)
    BURST_BYTES = tuple(words * 4 for words in BURST_WORDS)
    MAX_BURST_WORDS = 16
    MAX_BURST_BYTES = 64

    CONTROLLER_NOTIFY_BASE = 0x00000000
    CONTROLLER_NOTIFY_STRIDE = 4

    DMA_CHANNEL_BITS = 4
    DMA_GENERATION_BITS = 4
    DMA_OFFSET_BITS = 24
    DMA_CHANNELS = 1 << DMA_CHANNEL_BITS
    DMA_GENERATIONS = 1 << DMA_GENERATION_BITS
    DMA_CHANNEL_SHIFT = DMA_GENERATION_BITS + DMA_OFFSET_BITS
    DMA_GENERATION_SHIFT = DMA_OFFSET_BITS
    DMA_CHANNEL_MASK = DMA_CHANNELS - 1
    DMA_GENERATION_MASK = DMA_GENERATIONS - 1
    DMA_OFFSET_MASK = (1 << DMA_OFFSET_BITS) - 1
    DMA_MAX_LENGTH = DMA_OFFSET_MASK + 1

    NOTIFY_CHANNELS = 4
    NOTIFY_CLASSES = 4

    def __init__(self, memory: HostMemory):
        self.memory = memory
        self._dma_channels: list[list[DMAChannel | None]] = [
            [None] * self.DMA_CHANNELS for _ in range(self.SLOT_COUNT)
        ]
        self._dma_generation = [
            [0] * self.DMA_CHANNELS for _ in range(self.SLOT_COUNT)
        ]
        self._dma_ever_bound = [
            [False] * self.DMA_CHANNELS for _ in range(self.SLOT_COUNT)
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
    def notification_offset(cls, channel: int) -> int:
        if not 0 <= channel < cls.NOTIFY_CHANNELS:
            raise ValueError("notification channel must be 0..3")
        return cls.CONTROLLER_NOTIFY_BASE + cls.CONTROLLER_NOTIFY_STRIDE * channel

    @classmethod
    def burst_words(cls, blen: int) -> int:
        if not 0 <= blen < len(cls.BURST_WORDS):
            raise ValueError("BLEN must be 0..3")
        return cls.BURST_WORDS[blen]

    @classmethod
    def dma_address(cls, channel: int, generation: int, offset: int) -> int:
        if not 0 <= channel < cls.DMA_CHANNELS:
            raise ValueError("DMA channel must be 0..15")
        if not 0 <= generation < cls.DMA_GENERATIONS:
            raise ValueError("DMA generation must be 0..15")
        if not 0 <= offset <= cls.DMA_OFFSET_MASK:
            raise ValueError("DMA offset outside 24-bit range")
        return (
            (channel << cls.DMA_CHANNEL_SHIFT)
            | (generation << cls.DMA_GENERATION_SHIFT)
            | offset
        )

    @classmethod
    def decode_dma_address(cls, device_address: int) -> tuple[int, int, int]:
        if not 0 <= device_address <= 0xFFFFFFFF:
            raise ValueError("device DMA address outside 32-bit range")
        channel = (device_address >> cls.DMA_CHANNEL_SHIFT) & cls.DMA_CHANNEL_MASK
        generation = (
            device_address >> cls.DMA_GENERATION_SHIFT
        ) & cls.DMA_GENERATION_MASK
        offset = device_address & cls.DMA_OFFSET_MASK
        return channel, generation, offset

    def bind_dma_channel(self, slot: int, channel: int, mapping: DMAChannel) -> int:
        """Bind an unbound channel and return the generation for device DMA handles."""
        self._check_slot(slot)
        self._check_channel(channel, self.DMA_CHANNELS)
        if self._dma_channels[slot][channel] is not None:
            raise RuntimeError("DMA channel must be revoked before it is rebound")
        if mapping.length <= 0 or mapping.length > self.DMA_MAX_LENGTH:
            raise ValueError("DMA capability length must be 1..16 MiB")

        if self._dma_ever_bound[slot][channel]:
            current = self._dma_generation[slot][channel]
            if current == self.DMA_GENERATION_MASK:
                raise RuntimeError(
                    "DMA generation wrap requires slot quiesce/reset before rebinding"
                )
            generation = current + 1
        else:
            generation = 0

        bound = DMAChannel(
            mapping.host_base,
            mapping.length,
            mapping.readable,
            mapping.writable,
            generation,
        )
        self._dma_channels[slot][channel] = bound
        self._dma_generation[slot][channel] = generation
        self._dma_ever_bound[slot][channel] = True
        return generation

    def revoke_dma_channel(self, slot: int, channel: int) -> None:
        self._check_slot(slot)
        self._check_channel(channel, self.DMA_CHANNELS)
        self._dma_channels[slot][channel] = None

    def reset_dma_channels(self, slot: int) -> None:
        """Model a slot reset that guarantees no pre-reset DMA request can survive."""
        self._check_slot(slot)
        self._dma_channels[slot] = [None] * self.DMA_CHANNELS
        self._dma_generation[slot] = [0] * self.DMA_CHANNELS
        self._dma_ever_bound[slot] = [False] * self.DMA_CHANNELS

    def _translate(
        self,
        slot: int,
        device_address: int,
        length: int,
        *,
        write_to_host: bool,
    ) -> int:
        self._check_slot(slot)
        if not 0 <= device_address <= 0xFFFFFFFF:
            raise DMAFault("device DMA address outside 32-bit range")

        channel, generation, offset = self.decode_dma_address(device_address)
        mapping = self._dma_channels[slot][channel]
        if mapping is not None and generation == mapping.generation:
            translated = mapping.translate(offset, length, write_to_host=write_to_host)
            if translated is not None:
                return translated

        direction = "write" if write_to_host else "read"
        raise DMAFault(
            f"slot {slot} DMA {direction} not permitted: channel={channel} "
            f"generation={generation} offset=0x{offset:x} length={length}"
        )

    def validate_dma_burst(
        self,
        slot: int,
        device_address: int,
        blen: int,
        *,
        write_to_host: bool,
    ) -> int:
        """Validate the complete baseline burst and return its first host address."""
        words = self.burst_words(blen)
        if device_address & 0x3:
            raise DMAFault("PLIO burst address must be 32-bit aligned")
        return self._translate(
            slot,
            device_address,
            words * 4,
            write_to_host=write_to_host,
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
        """Model one bus-local SPACE=CONTROLLER notification write."""
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

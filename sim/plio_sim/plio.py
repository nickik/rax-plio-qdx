from __future__ import annotations

from dataclasses import dataclass

from .memory import HostMemory


class DMAFault(RuntimeError):
    pass


@dataclass(frozen=True)
class DMAWindow:
    """One controller-programmed contiguous DMA window for a bus manager."""

    device_base: int
    host_base: int
    length: int
    readable: bool = True
    writable: bool = True

    def translate(self, device_address: int, length: int, *, write_to_host: bool) -> int | None:
        if length < 0:
            return None
        offset = device_address - self.device_base
        if offset < 0 or offset + length > self.length:
            return None
        if write_to_host and not self.writable:
            return None
        if not write_to_host and not self.readable:
            return None
        return self.host_base + offset


class PLIOController:
    """Aggregate functional model of the central PLIO controller."""

    SLOT_COUNT = 8
    MAX_DMA_WINDOWS = 4
    IRQ_CLASSES = 4

    def __init__(self, memory: HostMemory):
        self.memory = memory
        self._dma_windows: list[list[DMAWindow]] = [[] for _ in range(self.SLOT_COUNT)]
        self._irq_pending = [False] * self.SLOT_COUNT
        self._irq_masked = [False] * self.SLOT_COUNT
        self._irq_class = [1] * self.SLOT_COUNT

    def _check_slot(self, slot: int) -> None:
        if not 0 <= slot < self.SLOT_COUNT:
            raise ValueError(f"invalid PLIO slot {slot}")

    def set_dma_windows(self, slot: int, windows: list[DMAWindow]) -> None:
        self._check_slot(slot)
        if len(windows) > self.MAX_DMA_WINDOWS:
            raise ValueError("too many DMA windows")
        self._dma_windows[slot] = list(windows)

    def _translate(self, slot: int, device_address: int, length: int, *, write_to_host: bool) -> int:
        self._check_slot(slot)
        for window in self._dma_windows[slot]:
            translated = window.translate(device_address, length, write_to_host=write_to_host)
            if translated is not None:
                return translated
        direction = "write" if write_to_host else "read"
        raise DMAFault(
            f"slot {slot} DMA {direction} not permitted: device=0x{device_address:x} length={length}"
        )

    def dma_read(self, slot: int, device_address: int, length: int) -> bytes:
        """Device reads host memory."""
        host_address = self._translate(slot, device_address, length, write_to_host=False)
        return self.memory.read(host_address, length)

    def dma_write(self, slot: int, device_address: int, data: bytes) -> None:
        """Device writes host memory."""
        host_address = self._translate(slot, device_address, len(data), write_to_host=True)
        self.memory.write(host_address, data)

    def configure_irq(self, slot: int, irq_class: int) -> None:
        self._check_slot(slot)
        if not 0 <= irq_class < self.IRQ_CLASSES:
            raise ValueError("IRQ class must be 0..3")
        self._irq_class[slot] = irq_class

    def assert_irq(self, slot: int) -> None:
        self._check_slot(slot)
        self._irq_pending[slot] = True

    def clear_irq(self, slot: int) -> None:
        self._check_slot(slot)
        self._irq_pending[slot] = False

    def mask_irq(self, slot: int) -> None:
        self._check_slot(slot)
        self._irq_masked[slot] = True

    def unmask_irq(self, slot: int) -> None:
        self._check_slot(slot)
        self._irq_masked[slot] = False

    @property
    def normal_irq_pending(self) -> bool:
        return any(pending and not masked for pending, masked in zip(self._irq_pending, self._irq_masked))

    def next_irq(self) -> int | None:
        """Return highest-class pending source; lower slot wins ties."""
        candidates = [
            slot
            for slot in range(self.SLOT_COUNT)
            if self._irq_pending[slot] and not self._irq_masked[slot]
        ]
        if not candidates:
            return None
        return min(candidates, key=lambda slot: (-self._irq_class[slot], slot))

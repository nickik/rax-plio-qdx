from __future__ import annotations

from .memory import HostMemory
from .plio import DMAWindow, PLIOController
from .qdx_b import BlockCommand, BlockController, BlockOpcode, Namespace


def main() -> None:
    memory = HostMemory(1 << 20)
    plio = PLIOController(memory)
    slot = 1
    plio.set_dma_windows(slot, [DMAWindow(0, 0, memory.size)])
    plio.configure_irq(slot, 1)

    disk = BlockController(plio, slot)
    disk.add_namespace(1, Namespace(256))

    source = bytes((i % 251 for i in range(512)))
    memory.write(0x1000, source)

    disk.submit(BlockCommand(BlockOpcode.WRITE, tag=1, namespace=1, lba=4, block_count=1, buffer_address=0x1000))
    disk.process_one()
    print("WRITE:", disk.reap())

    memory.write(0x2000, bytes(512))
    disk.submit(BlockCommand(BlockOpcode.READ, tag=2, namespace=1, lba=4, block_count=1, buffer_address=0x2000))
    disk.process_one()
    print("READ :", disk.reap())

    restored = memory.read(0x2000, 512)
    print("MATCH:", restored == source)


if __name__ == "__main__":
    main()

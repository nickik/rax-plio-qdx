import unittest

from sim.plio_sim import DMAWindow, HostMemory, PLIOController
from sim.plio_sim.qdx_b import BlockCommand, BlockController, BlockOpcode, BlockStatus, Namespace


class QDXBTests(unittest.TestCase):
    def setUp(self) -> None:
        self.memory = HostMemory(1 << 16)
        self.plio = PLIOController(self.memory)
        self.slot = 0
        self.plio.set_dma_windows(self.slot, [DMAWindow(0, 0, self.memory.size)])
        self.device = BlockController(self.plio, self.slot)
        self.device.add_namespace(1, Namespace(32))

    def test_write_then_read(self) -> None:
        payload = bytes((i & 0xFF for i in range(512)))
        self.memory.write(0x1000, payload)
        self.device.submit(BlockCommand(BlockOpcode.WRITE, 10, 1, lba=2, block_count=1, buffer_address=0x1000))
        self.assertTrue(self.device.process_one())
        self.assertEqual(self.device.reap().status, BlockStatus.SUCCESS)

        self.memory.write(0x2000, bytes(512))
        self.device.submit(BlockCommand(BlockOpcode.READ, 11, 1, lba=2, block_count=1, buffer_address=0x2000))
        self.device.process_one()
        completion = self.device.reap()
        self.assertEqual(completion.status, BlockStatus.SUCCESS)
        self.assertEqual(completion.bytes_transferred, 512)
        self.assertEqual(self.memory.read(0x2000, 512), payload)

    def test_invalid_namespace(self) -> None:
        self.device.submit(BlockCommand(BlockOpcode.READ, 12, 99, lba=0, block_count=1, buffer_address=0x1000))
        self.device.process_one()
        self.assertEqual(self.device.reap().status, BlockStatus.INVALID_NAMESPACE)

    def test_dma_fault(self) -> None:
        self.plio.set_dma_windows(self.slot, [DMAWindow(0, 0, 128)])
        self.device.submit(BlockCommand(BlockOpcode.READ, 13, 1, lba=0, block_count=1, buffer_address=0))
        self.device.process_one()
        self.assertEqual(self.device.reap().status, BlockStatus.DMA_FAULT)


if __name__ == "__main__":
    unittest.main()

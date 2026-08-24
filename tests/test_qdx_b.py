import unittest

from sim.plio_sim import DMAChannel, HostMemory, PLIOController
from sim.plio_sim.qdx_b import BlockCommand, BlockController, BlockOpcode, BlockStatus, Namespace


class QDXBTests(unittest.TestCase):
    def setUp(self) -> None:
        self.memory = HostMemory(1 << 16)
        self.plio = PLIOController(self.memory)
        self.slot = 0
        self.plio.bind_dma_channel(self.slot, 0, DMAChannel(0, self.memory.size))
        self.plio.configure_notification(self.slot, 0, notify_class=1)
        self.device = BlockController(self.plio, self.slot)
        self.device.add_namespace(1, Namespace(32))

    def test_write_then_read(self) -> None:
        payload = bytes((i & 0xFF for i in range(512)))
        self.memory.write(0x1000, payload)
        self.device.submit(BlockCommand(BlockOpcode.WRITE, 10, 1, lba=2, block_count=1, buffer_address=0x1000))
        self.assertTrue(self.device.process_one())
        self.assertEqual(self.plio.claim_notification(), (self.slot, 0))
        self.assertEqual(self.device.reap().status, BlockStatus.SUCCESS)

        self.memory.write(0x2000, bytes(512))
        self.device.submit(BlockCommand(BlockOpcode.READ, 11, 1, lba=2, block_count=1, buffer_address=0x2000))
        self.device.process_one()
        self.assertEqual(self.plio.claim_notification(), (self.slot, 0))
        completion = self.device.reap()
        self.assertEqual(completion.status, BlockStatus.SUCCESS)
        self.assertEqual(completion.bytes_transferred, 512)
        self.assertEqual(self.memory.read(0x2000, 512), payload)

    def test_notification_coalesces_while_cq_nonempty(self) -> None:
        self.device.submit(BlockCommand(BlockOpcode.FLUSH, 20, 1))
        self.device.submit(BlockCommand(BlockOpcode.FLUSH, 21, 1))
        self.device.process_one()
        self.device.process_one()
        self.assertEqual(self.plio.claim_notification(), (self.slot, 0))
        self.assertIsNone(self.plio.claim_notification())
        self.device.reap()
        self.device.reap()

    def test_invalid_namespace(self) -> None:
        self.device.submit(BlockCommand(BlockOpcode.READ, 12, 99, lba=0, block_count=1, buffer_address=0x1000))
        self.device.process_one()
        self.assertEqual(self.device.reap().status, BlockStatus.INVALID_NAMESPACE)

    def test_dma_fault(self) -> None:
        self.plio.bind_dma_channel(self.slot, 0, DMAChannel(0, 128))
        self.device.submit(BlockCommand(BlockOpcode.READ, 13, 1, lba=0, block_count=1, buffer_address=0))
        self.device.process_one()
        self.assertEqual(self.device.reap().status, BlockStatus.DMA_FAULT)


if __name__ == "__main__":
    unittest.main()

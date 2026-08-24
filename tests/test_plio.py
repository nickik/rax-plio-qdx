import unittest

from sim.plio_sim import DMAChannel, DMAFault, HostMemory, PLIOController


class PLIOTests(unittest.TestCase):
    def setUp(self) -> None:
        self.memory = HostMemory(4096)
        self.plio = PLIOController(self.memory)
        self.gen0 = self.plio.bind_dma_channel(2, 0, DMAChannel(0x400, 0x400))

    def addr(self, channel: int, generation: int, offset: int) -> int:
        return self.plio.dma_address(channel, generation, offset)

    def test_dma_translation(self) -> None:
        self.memory.write(0x440, b"RAX")
        self.assertEqual(self.plio.dma_read(2, self.addr(0, self.gen0, 0x40), 3), b"RAX")
        self.plio.dma_write(2, self.addr(0, self.gen0, 0x80), b"QDX")
        self.assertEqual(self.memory.read(0x480, 3), b"QDX")

    def test_dma_channel_selection(self) -> None:
        gen15 = self.plio.bind_dma_channel(2, 15, DMAChannel(0x800, 0x100))
        address = self.addr(15, gen15, 0x20)
        self.memory.write(0x820, b"CAP")
        self.assertEqual(self.plio.dma_read(2, address, 3), b"CAP")
        self.assertEqual(self.plio.DMA_CHANNELS, 16)

    def test_dma_fault_and_revocation(self) -> None:
        with self.assertRaises(DMAFault):
            self.plio.dma_read(2, self.addr(0, self.gen0, 0x500), 4)
        stale = self.addr(0, self.gen0, 0x40)
        self.plio.revoke_dma_channel(2, 0)
        with self.assertRaises(DMAFault):
            self.plio.dma_read(2, stale, 4)

    def test_stale_generation_rejected_after_rebind(self) -> None:
        stale = self.addr(0, self.gen0, 0x40)
        self.plio.revoke_dma_channel(2, 0)
        new_generation = self.plio.bind_dma_channel(2, 0, DMAChannel(0x800, 0x100))
        self.assertNotEqual(new_generation, self.gen0)

        self.memory.write(0x840, b"NEW")
        with self.assertRaises(DMAFault):
            self.plio.dma_read(2, stale, 3)
        fresh = self.addr(0, new_generation, 0x40)
        self.assertEqual(self.plio.dma_read(2, fresh, 3), b"NEW")

    def test_generation_wrap_requires_reset(self) -> None:
        generation = self.gen0
        for _ in range(15):
            self.plio.revoke_dma_channel(2, 0)
            generation = self.plio.bind_dma_channel(2, 0, DMAChannel(0x400, 0x100))
        self.assertEqual(generation, 15)

        self.plio.revoke_dma_channel(2, 0)
        with self.assertRaises(RuntimeError):
            self.plio.bind_dma_channel(2, 0, DMAChannel(0x400, 0x100))

        self.plio.reset_dma_channels(2)
        generation = self.plio.bind_dma_channel(2, 0, DMAChannel(0x400, 0x100))
        self.assertEqual(generation, 0)

    def test_notification_priority_masking_and_claim(self) -> None:
        self.plio.configure_notification(1, 0, notify_class=1)
        self.plio.configure_notification(3, 0, notify_class=3)
        self.plio.notify(1, 0)
        self.plio.notify(3, 0)
        self.assertTrue(self.plio.normal_notification_pending)
        self.assertEqual(self.plio.next_notification(), (3, 0))
        self.plio.mask_notification(3, 0)
        self.assertEqual(self.plio.claim_notification(), (1, 0))
        self.plio.unmask_notification(3, 0)
        self.assertEqual(self.plio.claim_notification(), (3, 0))

    def test_notification_coalesces_pending_bit(self) -> None:
        self.plio.notify(0, 0, 1)
        self.plio.notify(0, 0, 2)
        self.assertEqual(self.plio.claim_notification(), (0, 0))
        self.assertFalse(self.plio.normal_notification_pending)


if __name__ == "__main__":
    unittest.main()

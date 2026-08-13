import unittest

from sim.plio_sim import DMAFault, DMAWindow, HostMemory, PLIOController


class PLIOTests(unittest.TestCase):
    def setUp(self) -> None:
        self.memory = HostMemory(4096)
        self.plio = PLIOController(self.memory)
        self.plio.set_dma_windows(2, [DMAWindow(0x1000, 0x400, 0x400)])

    def test_dma_translation(self) -> None:
        self.memory.write(0x440, b"RAX")
        self.assertEqual(self.plio.dma_read(2, 0x1040, 3), b"RAX")
        self.plio.dma_write(2, 0x1080, b"QDX")
        self.assertEqual(self.memory.read(0x480, 3), b"QDX")

    def test_dma_fault(self) -> None:
        with self.assertRaises(DMAFault):
            self.plio.dma_read(2, 0x2000, 4)

    def test_irq_priority_and_masking(self) -> None:
        self.plio.configure_irq(1, 1)
        self.plio.configure_irq(3, 3)
        self.plio.assert_irq(1)
        self.plio.assert_irq(3)
        self.assertTrue(self.plio.normal_irq_pending)
        self.assertEqual(self.plio.next_irq(), 3)
        self.plio.mask_irq(3)
        self.assertEqual(self.plio.next_irq(), 1)


if __name__ == "__main__":
    unittest.main()

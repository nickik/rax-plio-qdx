import unittest

from sim.plio_sim import DMAChannel, DMAFault, HostMemory, PLIOController


class PLIOV05Tests(unittest.TestCase):
    def setUp(self) -> None:
        self.memory = HostMemory(4096)
        self.plio = PLIOController(self.memory)
        self.generation = self.plio.bind_dma_channel(0, 0, DMAChannel(0, 256))

    def test_transaction_spaces_are_distinct(self) -> None:
        self.assertEqual(
            {
                self.plio.SPACE_WORKER,
                self.plio.SPACE_HOST_DMA,
                self.plio.SPACE_CONTROLLER,
                self.plio.SPACE_RESERVED,
            },
            {0, 1, 2, 3},
        )

    def test_notification_offsets_are_bus_local(self) -> None:
        self.assertEqual(
            [self.plio.notification_offset(i) for i in range(4)],
            [0x0, 0x4, 0x8, 0xC],
        )
        with self.assertRaises(ValueError):
            self.plio.notification_offset(4)

    def test_blen_mapping(self) -> None:
        self.assertEqual([self.plio.burst_words(i) for i in range(4)], [1, 4, 8, 16])
        self.assertEqual(self.plio.MAX_BURST_BYTES, 64)

    def test_full_burst_extent_is_validated_before_start(self) -> None:
        valid = self.plio.dma_address(0, self.generation, 192)
        self.assertEqual(
            self.plio.validate_dma_burst(0, valid, 3, write_to_host=True),
            192,
        )

        crosses_boundary = self.plio.dma_address(0, self.generation, 196)
        with self.assertRaises(DMAFault):
            self.plio.validate_dma_burst(0, crosses_boundary, 3, write_to_host=True)

    def test_burst_requires_longword_alignment(self) -> None:
        unaligned = self.plio.dma_address(0, self.generation, 2)
        with self.assertRaises(DMAFault):
            self.plio.validate_dma_burst(0, unaligned, 1, write_to_host=False)


if __name__ == "__main__":
    unittest.main()

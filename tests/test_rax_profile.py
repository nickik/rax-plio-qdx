import unittest

from sim.plio_sim.rax_profile import (
    RAX_PLIO_HOST_CSR_BASE,
    RAX_PLIO_MMIO_BASE,
    decode_plio_mmio,
    encode_plio_mmio,
)


class RAXPLIOProfileTests(unittest.TestCase):
    def test_geographic_mmio_mapping(self) -> None:
        self.assertEqual(decode_plio_mmio(0xF000_1234), (0, 0x1234))
        self.assertEqual(decode_plio_mmio(0xF600_0020), (3, 0x20))
        self.assertEqual(decode_plio_mmio(0xFFFF_FFFF), (7, 0x1FF_FFFF))
        self.assertEqual(encode_plio_mmio(3, 0x20), 0xF600_0020)

    def test_host_map_is_profile_specific(self) -> None:
        self.assertEqual(RAX_PLIO_MMIO_BASE, 0xF000_0000)
        self.assertEqual(RAX_PLIO_HOST_CSR_BASE, 0xEFFF_F000)

    def test_outside_map_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            decode_plio_mmio(0xEFFF_F000)
        with self.assertRaises(ValueError):
            encode_plio_mmio(8, 0)


if __name__ == "__main__":
    unittest.main()

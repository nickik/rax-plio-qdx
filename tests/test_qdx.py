import unittest

from sim.plio_sim.qdx import QDX_BYTE_ORDER, decode_u16, decode_u32, encode_u16, encode_u32


class QDXByteOrderTests(unittest.TestCase):
    def test_canonical_byte_order_is_little_endian(self) -> None:
        self.assertEqual(QDX_BYTE_ORDER, "little")
        self.assertEqual(encode_u16(0x1234), b"\x34\x12")
        self.assertEqual(encode_u32(0x01020304), b"\x04\x03\x02\x01")
        self.assertEqual(decode_u16(b"\x78\x56"), 0x5678)
        self.assertEqual(decode_u32(b"\xEF\xCD\xAB\x89"), 0x89ABCDEF)


if __name__ == "__main__":
    unittest.main()

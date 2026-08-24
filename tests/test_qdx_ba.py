import unittest

from sim.plio_sim.qdx_ba import (
    BA_RESULT_ATTEMPTED,
    BA_RESULT_SELECTED,
    BA_STATUS_PARTIAL_SUCCESS,
    BA_TARGET_NOT_ATTEMPTED,
    BAParameterBlock,
    BATarget,
    BATargetResult,
    BlockAccelOpcode,
    pack_parameter_block,
    pack_target_results,
    unpack_parameter_block,
    unpack_target_results,
)


class QDXBATests(unittest.TestCase):
    def test_opcode_assignments(self) -> None:
        self.assertEqual(int(BlockAccelOpcode.READ_OR), 0x20)
        self.assertEqual(int(BlockAccelOpcode.WRITE_OR), 0x21)
        self.assertEqual(int(BlockAccelOpcode.MULTI_WRITE), 0x22)
        self.assertEqual(int(BlockAccelOpcode.COPY), 0x23)

    def test_parameter_block_round_trip(self) -> None:
        block = BAParameterBlock(
            results_addr=0xA123_4000,
            targets=(
                BATarget(namespace_id=1, lba=10_000),
                BATarget(namespace_id=2, lba=50_000),
            ),
        )
        encoded = pack_parameter_block(block)
        self.assertEqual(len(encoded), 32)
        self.assertEqual(unpack_parameter_block(encoded), block)

    def test_parameter_block_is_little_endian(self) -> None:
        block = BAParameterBlock(
            results_addr=0x1234_5678,
            targets=(BATarget(namespace_id=0x1234, lba=0x89AB_CDEF),),
        )
        encoded = pack_parameter_block(block)
        self.assertEqual(encoded[0:2], b"\x01\x00")
        self.assertEqual(encoded[2:4], b"\x01\x00")
        self.assertEqual(encoded[8:12], b"\x78\x56\x34\x12")
        self.assertEqual(encoded[16:18], b"\x34\x12")
        self.assertEqual(encoded[20:24], b"\xef\xcd\xab\x89")

    def test_result_array_round_trip(self) -> None:
        results = (
            BATargetResult(status=0x0006, flags=BA_RESULT_ATTEMPTED, blocks_done=2),
            BATargetResult(
                status=0x0000,
                flags=BA_RESULT_ATTEMPTED | BA_RESULT_SELECTED,
                blocks_done=8,
            ),
            BATargetResult(status=BA_TARGET_NOT_ATTEMPTED, flags=0, blocks_done=0),
        )
        encoded = pack_target_results(results)
        self.assertEqual(len(encoded), 24)
        self.assertEqual(unpack_target_results(encoded), results)

    def test_rejects_too_many_targets(self) -> None:
        targets = tuple(BATarget(namespace_id=1, lba=i) for i in range(17))
        with self.assertRaises(ValueError):
            pack_parameter_block(BAParameterBlock(results_addr=0, targets=targets))

    def test_extension_status_value(self) -> None:
        self.assertEqual(BA_STATUS_PARTIAL_SUCCESS, 0x0100)


if __name__ == "__main__":
    unittest.main()

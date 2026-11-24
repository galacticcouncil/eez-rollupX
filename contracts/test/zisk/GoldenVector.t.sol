// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test, console2} from "forge-std/Test.sol";
import {ZiskPublicValues} from "../../src/zisk/ZiskProofSystem.sol";

/// Pins the schema-1 public-values string for fixed inputs so off-chain
/// encoders (Rust stub prover, test harness) can pin byte-identical output.
/// The expected bytes are `test/fixtures/zisk/golden_pv_schema1_h11_vk22_rid7.hex`,
/// a byte-identical copy of hydration-zisk's
/// `contracts/eez/test/fixtures/golden_pv_schema1_h11_vk22_rid7.hex`.
contract GoldenVectorTest is Test {
    string internal constant GOLDEN_PV_PATH = "/test/fixtures/zisk/golden_pv_schema1_h11_vk22_rid7.hex";

    function test_goldenVector_schema1() public view {
        bytes memory pv = ZiskPublicValues.encode(
            1,
            0x1111111111111111111111111111111111111111111111111111111111111111,
            0x2222222222222222222222222222222222222222222222222222222222222222,
            7
        );
        assertEq(pv.length, 512);
        console2.log("GOLDEN_PV_HEX");
        console2.logBytes(pv);
        bytes memory golden = vm.parseBytes(vm.trim(vm.readFile(string.concat(vm.projectRoot(), GOLDEN_PV_PATH))));
        assertEq(pv, golden, "encoder output != golden vector file");
        (uint32 schema, bytes32 h, bytes32 vk, uint64 rid) = ZiskPublicValues.decode(golden);
        assertEq(schema, 1);
        assertEq(h, bytes32(0x1111111111111111111111111111111111111111111111111111111111111111));
        assertEq(vk, bytes32(0x2222222222222222222222222222222222222222222222222222222222222222));
        assertEq(rid, 7);
    }
}

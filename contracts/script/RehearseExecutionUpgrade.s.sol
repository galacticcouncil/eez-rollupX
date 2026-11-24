// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "eez-core-protocol/src/EEZ.sol";
import {Rollup} from "eez-core-protocol/src/rollupContract/Rollup.sol";
import {EEZProxy} from "eez-core-protocol/src/proxy/EEZProxy.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ECDSAProofSystem} from "../src/ECDSAProofSystem.sol";
import {UpgradeController} from "../src/governance/UpgradeController.sol";
import {ExecutionUpgradeSchedule} from "../src/governance/ExecutionUpgradeSchedule.sol";

/// @notice Local authorization simulation, not a running L2 or a proof rehearsal.
contract RehearseExecutionUpgrade is Script {
    address private constant AUTHORITY = address(0xA11CE);
    bytes32 private constant SOURCE = keccak256("bootstrap rehearsal");

    function run() external {
        EEZ eez = EEZ(address(new EEZProxy(address(new EEZ(address(0xCAFE))), AUTHORITY)));
        address[] memory systems = new address[](1);
        systems[0] = address(new ECDSAProofSystem(address(0x51)));
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = bytes32(uint256(0x51));
        Rollup manager = Rollup(
            address(
                new TransparentUpgradeableProxy(
                    address(new Rollup(address(eez))),
                    AUTHORITY,
                    abi.encodeCall(Rollup.initialize, (AUTHORITY, 1, systems, keys))
                )
            )
        );
        vm.prank(AUTHORITY);
        uint64 rollupId = eez.registerRollup(address(manager), keccak256("initial root"));
        UpgradeController controller = new UpgradeController(address(eez), rollupId, AUTHORITY, SOURCE, 100);
        vm.prank(AUTHORITY);
        manager.transferOwnership(address(controller));

        ExecutionUpgradeSchedule.Release memory genesis = _release(0);
        ExecutionUpgradeSchedule.Release memory next = _release(1);
        ExecutionUpgradeSchedule schedule = new ExecutionUpgradeSchedule(
            controller, 31338, keccak256("fixture genesis"), uint64(block.timestamp), 2, 1_000, 200, genesis
        );
        bytes memory data = abi.encodeCall(schedule.schedule, (genesis.releaseHash, next, uint64(1_000)));
        UpgradeController.Operation memory op = UpgradeController.Operation({
            authorityEpoch: 1,
            nonce: 1,
            sourceDomain: SOURCE,
            target: address(schedule),
            calldataHash: keccak256(data),
            notBefore: uint64(block.timestamp + 100),
            expiresAt: uint64(block.timestamp + 500)
        });
        vm.prank(AUTHORITY);
        controller.schedule(op);
        require(schedule.releaseAt(1_000).runtimeVersion == 0, "queue changed execution schedule");
        vm.warp(op.notBefore);
        controller.execute(op, data);
        require(schedule.releaseAt(999).runtimeVersion == 0, "old history changed");
        require(schedule.releaseAt(1_000).runtimeVersion == 1, "boundary not recorded");
        require(schedule.releaseAt(1_001).runtimeVersion == 1, "new version not retained");
        require(manager.verificationKey(systems[0]) == keys[0], "schedule must not switch manager key");
        console.log("PASS: timelock enactment, runtime 0/1 boundary, immutable history, unchanged manager key");
        console.log("EXECUTION_SCHEDULE=%s", address(schedule));
        console.log("Simulation only: no L2 node or proof verification was exercised.");
    }

    function _release(uint32 version) private pure returns (ExecutionUpgradeSchedule.Release memory) {
        return ExecutionUpgradeSchedule.Release({
            runtimeVersion: version,
            releaseHash: keccak256(abi.encode("fixture manifest", version)),
            nodeArtifactHash: keccak256(abi.encode("fixture node", version)),
            guestArtifactHash: keccak256(abi.encode("fixture guest", version)),
            programVKey: bytes32(0)
        });
    }
}

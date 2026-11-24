// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "eez-core-protocol/src/EEZ.sol";
import {Rollup} from "eez-core-protocol/src/rollupContract/Rollup.sol";
import {EEZProxy} from "eez-core-protocol/src/proxy/EEZProxy.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ECDSAProofSystem} from "../src/ECDSAProofSystem.sol";
import {AuthorityRegistry} from "../src/governance/AuthorityRegistry.sol";
import {UpgradeController} from "../src/governance/UpgradeController.sol";

/// @notice Local simulation only: no RPC, funded keys, broadcast, or public deployment.
contract RehearseGovernance is Script {
    address private constant BOOTSTRAP = address(0xA11CE);
    address private constant NATIVE = address(0xB0B);
    bytes32 private constant SOURCE = keccak256("alpha bootstrap");
    uint64 private constant DELAY = 1 days;

    function run() external {
        EEZ eez = EEZ(address(new EEZProxy(address(new EEZ(address(0xCAFE))), BOOTSTRAP)));
        ECDSAProofSystem proofSystem = new ECDSAProofSystem(address(0x51));
        address[] memory systems = new address[](1);
        systems[0] = address(proofSystem);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = bytes32(uint256(0x51));
        Rollup manager = Rollup(
            address(
                new TransparentUpgradeableProxy(
                    address(new Rollup(address(eez))),
                    BOOTSTRAP,
                    abi.encodeCall(Rollup.initialize, (BOOTSTRAP, 1, systems, keys))
                )
            )
        );
        vm.prank(BOOTSTRAP);
        uint64 rollupId = eez.registerRollup(address(manager), keccak256("initial root"));
        UpgradeController controller = new UpgradeController(address(eez), rollupId, BOOTSTRAP, SOURCE, DELAY);
        vm.prank(BOOTSTRAP);
        manager.transferOwnership(address(controller));
        require(manager.owner() == address(controller), "handoff failed");

        bytes32 nextKey = keccak256("rehearsal version two");
        bytes memory data = abi.encodeCall(manager.updateVerificationKey, (address(proofSystem), nextKey));
        UpgradeController.Operation memory op = _operation(controller, 1, address(manager), data);
        vm.prank(BOOTSTRAP);
        controller.schedule(op);
        require(manager.verificationKey(address(proofSystem)) == keys[0], "executed before delay");
        vm.warp(op.notBefore);
        controller.execute(op, data);
        require(manager.verificationKey(address(proofSystem)) == nextKey, "key update failed");

        // One queued epoch-1 operation must become unexecutable at rotation.
        data = abi.encodeCall(manager.setThreshold, (2));
        UpgradeController.Operation memory stale = _operation(controller, 2, address(manager), data);
        vm.prank(BOOTSTRAP);
        controller.schedule(stale);
        AuthorityRegistry registry = controller.AUTHORITY_REGISTRY();
        bytes memory rotation = abi.encodeCall(registry.rotateAuthority, (NATIVE, keccak256("native governance")));
        op = _operation(controller, 3, address(registry), rotation);
        vm.prank(BOOTSTRAP);
        controller.schedule(op);
        vm.warp(op.notBefore);
        controller.execute(op, rotation);
        require(registry.epoch() == 2 && registry.authority() == NATIVE, "cutover failed");
        (bool success, bytes memory reason) =
            address(controller).call(abi.encodeCall(controller.execute, (stale, data)));
        require(!success && bytes4(reason) == UpgradeController.WrongAuthority.selector, "stale operation accepted");

        op = _operation(controller, 1, address(manager), data);
        vm.prank(NATIVE);
        controller.schedule(op);
        vm.warp(op.notBefore);
        controller.execute(op, data);
        require(manager.threshold() == 2, "native operation failed");
        console.log("PASS: handoff, delayed manager change, authority cutover, stale rejection, native execution");
        console.log("UPGRADE_CONTROLLER=%s", address(controller));
        console.log("AUTHORITY_REGISTRY=%s", address(registry));
    }

    function _operation(
        UpgradeController controller,
        uint64 nonce,
        address target,
        bytes memory data
    )
        private
        view
        returns (UpgradeController.Operation memory)
    {
        AuthorityRegistry registry = controller.AUTHORITY_REGISTRY();
        return UpgradeController.Operation({
            authorityEpoch: registry.epoch(),
            nonce: nonce,
            sourceDomain: registry.sourceDomain(),
            target: target,
            calldataHash: keccak256(data),
            notBefore: uint64(block.timestamp + DELAY),
            expiresAt: uint64(block.timestamp + DELAY + 1 days)
        });
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {RollupDeployment} from "./utils/RollupDeployment.sol";
import {EEZ} from "eez-core-protocol/src/EEZ.sol";
import {Rollup} from "eez-core-protocol/src/rollupContract/Rollup.sol";
import {DeployUpgradeController} from "../script/DeployUpgradeController.s.sol";
import {UpgradeController} from "../src/governance/UpgradeController.sol";

contract DeployUpgradeControllerTest is Test {
    function testScriptHandsRegisteredManagerToController() external {
        // startBroadcast() uses the transaction origin when no signer is supplied.
        (EEZ eez, Rollup manager) = _manager(tx.origin);
        vm.prank(tx.origin);
        uint64 rollupId = eez.registerRollup(address(manager), keccak256("genesis"));
        DeployUpgradeController deployment = new DeployUpgradeController();
        UpgradeController controller = deployment.run(address(manager), address(0xA11CE), keccak256("alpha"), 1 days);
        assertEq(manager.owner(), address(controller));
        assertEq(controller.EEZ_REGISTRY(), address(eez));
        assertEq(controller.ROLLUP_ID(), rollupId);
        assertEq(controller.AUTHORITY_REGISTRY().authority(), address(0xA11CE));
    }

    function testScriptRejectsWrongOwnerBeforeDeployment() external {
        (EEZ eez, Rollup manager) = _manager(address(0xBAD));
        vm.prank(address(0xBAD));
        eez.registerRollup(address(manager), keccak256("genesis"));
        DeployUpgradeController deployment = new DeployUpgradeController();
        vm.expectRevert("broadcast as current owner");
        deployment.run(address(manager), address(0xA11CE), keccak256("alpha"), 1 days);
        assertEq(manager.owner(), address(0xBAD));
    }

    function testScriptRejectsUnregisteredManager() external {
        (, Rollup manager) = _manager(tx.origin);
        DeployUpgradeController deployment = new DeployUpgradeController();
        vm.expectRevert("manager not registered");
        deployment.run(address(manager), address(0xA11CE), keccak256("alpha"), 1 days);
    }

    function _manager(address owner) private returns (EEZ eez, Rollup manager) {
        eez = RollupDeployment.deployEEZ(address(0xCAFE), address(this));
        manager = RollupDeployment.deploy(address(eez), owner, 1, new address[](0), new bytes32[](0));
    }
}

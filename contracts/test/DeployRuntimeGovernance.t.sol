// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {RollupDeployment} from "./utils/RollupDeployment.sol";
import {EEZ} from "eez-core-protocol/src/EEZ.sol";
import {Rollup} from "eez-core-protocol/src/rollupContract/Rollup.sol";
import {DeployRuntimeGovernance} from "../script/DeployRuntimeGovernance.s.sol";
import {UpgradeController} from "../src/governance/UpgradeController.sol";
import {ExecutionUpgradeSchedule} from "../src/governance/ExecutionUpgradeSchedule.sol";

contract DeployRuntimeGovernanceTest is Test {
    function _config(address owner) private returns (DeployRuntimeGovernance.Deployment memory d) {
        EEZ eez = RollupDeployment.deployEEZ(address(0xCAFE), address(this));
        Rollup manager = RollupDeployment.deploy(address(eez), owner, 1, new address[](0), new bytes32[](0));
        vm.prank(owner);
        eez.registerRollup(address(manager), keccak256("genesis state"));
        d = DeployRuntimeGovernance.Deployment({
            manager: address(manager),
            authority: address(0xA11CE),
            sourceDomain: keccak256("bootstrap"),
            minDelay: 100,
            l2ChainId: 31338,
            l2GenesisHash: keccak256("genesis header"),
            l2GenesisTimestamp: uint64(block.timestamp),
            blockSeconds: 2,
            minNotice: 1_000,
            cancelNotice: 200,
            genesis: ExecutionUpgradeSchedule.Release(
                0, keccak256("manifest"), keccak256("node"), keccak256("guest"), bytes32(0)
            )
        });
    }

    function testDeploysAndHandsOffOnlyAfterScheduleExists() external {
        DeployRuntimeGovernance.Deployment memory d = _config(tx.origin);
        (UpgradeController controller, ExecutionUpgradeSchedule schedule) = new DeployRuntimeGovernance().run(d);
        assertEq(Rollup(d.manager).owner(), address(controller));
        assertEq(address(schedule.CONTROLLER()), address(controller));
        assertEq(schedule.L2_GENESIS_HASH(), d.l2GenesisHash);
        assertEq(schedule.L2_GENESIS_TIMESTAMP(), d.l2GenesisTimestamp);
        assertEq(schedule.releaseAt(0).runtimeVersion, 0);
    }

    function testRejectsWrongOwnerWithoutHandoff() external {
        DeployRuntimeGovernance.Deployment memory d = _config(address(0xBAD));
        DeployRuntimeGovernance script = new DeployRuntimeGovernance();
        vm.expectRevert("broadcast as current owner");
        script.run(d);
        assertEq(Rollup(d.manager).owner(), address(0xBAD));
    }

    function testRejectsUnsafeNoticeMargins() external {
        DeployRuntimeGovernance.Deployment memory d = _config(tx.origin);
        d.minNotice = d.minDelay + d.cancelNotice;
        DeployRuntimeGovernance script = new DeployRuntimeGovernance();
        vm.expectRevert("no cancellation response window");
        script.run(d);
        assertEq(Rollup(d.manager).owner(), tx.origin);
    }
}

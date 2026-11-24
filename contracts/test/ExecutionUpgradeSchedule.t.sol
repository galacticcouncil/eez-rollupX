// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {RollupDeployment} from "./utils/RollupDeployment.sol";
import {EEZ} from "eez-core-protocol/src/EEZ.sol";
import {UpgradeController} from "../src/governance/UpgradeController.sol";
import {ExecutionUpgradeSchedule} from "../src/governance/ExecutionUpgradeSchedule.sol";

contract ExecutionUpgradeScheduleTest is Test {
    address private constant AUTHORITY = address(0xA11CE);
    bytes32 private constant SOURCE = keccak256("bootstrap");
    uint64 private constant GENESIS_TIME = 1_000_000;
    uint64 private constant DELAY = 100;
    uint64 private constant NOTICE = 1_000;
    uint64 private constant CANCEL_NOTICE = 200;
    uint64 private constant ACTIVATION = 1_000;

    UpgradeController private controller;
    ExecutionUpgradeSchedule private schedule;
    uint64 private nonce;

    function setUp() external {
        vm.warp(GENESIS_TIME);
        EEZ eez = RollupDeployment.deployEEZ(address(0xCAFE), address(this));
        controller = new UpgradeController(address(eez), 1, AUTHORITY, SOURCE, DELAY);
        schedule = _deploy(2, NOTICE, CANCEL_NOTICE, _release(0));
    }

    function _release(uint32 version) private pure returns (ExecutionUpgradeSchedule.Release memory) {
        return ExecutionUpgradeSchedule.Release({
            runtimeVersion: version,
            releaseHash: keccak256(abi.encode("release manifest", version)),
            nodeArtifactHash: keccak256(abi.encode("node", version)),
            guestArtifactHash: keccak256(abi.encode("guest", version)),
            programVKey: bytes32(0)
        });
    }

    function _deploy(
        uint64 period,
        uint64 notice,
        uint64 cancellation,
        ExecutionUpgradeSchedule.Release memory genesis
    )
        private
        returns (ExecutionUpgradeSchedule)
    {
        return new ExecutionUpgradeSchedule(
            controller, 31338, keccak256("L2 genesis"), GENESIS_TIME, period, notice, cancellation, genesis
        );
    }

    function _queue(bytes memory data) private returns (UpgradeController.Operation memory op) {
        op = UpgradeController.Operation({
            authorityEpoch: 1,
            nonce: nonce++,
            sourceDomain: SOURCE,
            target: address(schedule),
            calldataHash: keccak256(data),
            notBefore: uint64(block.timestamp + DELAY),
            expiresAt: uint64(block.timestamp + DELAY + 5_000)
        });
        vm.prank(AUTHORITY);
        controller.schedule(op);
    }

    function _enact() private returns (bytes32 id) {
        ExecutionUpgradeSchedule.Release memory next = _release(1);
        bytes memory data = abi.encodeCall(schedule.schedule, (_release(0).releaseHash, next, ACTIVATION));
        UpgradeController.Operation memory op = _queue(data);
        vm.warp(op.notBefore);
        controller.execute(op, data);
        return schedule.hashUpgrade(_release(0).releaseHash, next, ACTIVATION);
    }

    function testGenesisZeroAndExactHeightBoundaryThroughTimelock() external {
        assertEq(schedule.releaseAt(type(uint64).max).runtimeVersion, 0);
        bytes32 id = _enact();
        assertTrue(schedule.used(id));
        assertEq(schedule.entryCount(), 2);
        assertEq(schedule.releaseAt(0).runtimeVersion, 0);
        assertEq(schedule.releaseAt(ACTIVATION - 1).runtimeVersion, 0);
        assertEq(schedule.releaseAt(ACTIVATION).runtimeVersion, 1);
        assertEq(schedule.releaseAt(type(uint64).max).runtimeVersion, 1);
        assertEq(schedule.entryAt(1).upgradeId, id);
        assertEq(schedule.activationTimestamp(ACTIVATION), GENESIS_TIME + 2 * ACTIVATION);
    }

    function testAuthorityAndDeployerCannotBypassTimelock() external {
        vm.expectRevert(ExecutionUpgradeSchedule.Unauthorized.selector);
        schedule.schedule(_release(0).releaseHash, _release(1), ACTIVATION);
        vm.prank(AUTHORITY);
        vm.expectRevert(ExecutionUpgradeSchedule.Unauthorized.selector);
        schedule.schedule(_release(0).releaseHash, _release(1), ACTIVATION);
        bytes32 id = _enact();
        vm.prank(AUTHORITY);
        vm.expectRevert(ExecutionUpgradeSchedule.Unauthorized.selector);
        schedule.cancel(id);
    }

    function testNoticeStartsAtExecutionNotQueueTime() external {
        bytes memory data = abi.encodeCall(schedule.schedule, (_release(0).releaseHash, _release(1), ACTIVATION));
        UpgradeController.Operation memory op = _queue(data);
        vm.warp(GENESIS_TIME + 1_001);
        vm.expectRevert(
            abi.encodeWithSelector(
                UpgradeController.TargetCallFailed.selector,
                abi.encodeWithSelector(ExecutionUpgradeSchedule.InsufficientNotice.selector)
            )
        );
        controller.execute(op, data);
        assertEq(schedule.entryCount(), 1);
        assertEq(uint256(controller.status(controller.hashOperation(op))), uint256(UpgradeController.Status.Scheduled));
    }

    function testExactNoticeBoundary() external {
        vm.warp(GENESIS_TIME + 1_000);
        vm.prank(address(controller));
        schedule.schedule(_release(0).releaseHash, _release(1), ACTIVATION);
        assertEq(schedule.entryCount(), 2);
    }

    function testOnlyOnePendingUpgradeAndNoVersionSkips() external {
        vm.prank(address(controller));
        vm.expectRevert(ExecutionUpgradeSchedule.InvalidRelease.selector);
        schedule.schedule(_release(0).releaseHash, _release(2), ACTIVATION);
        _enact();
        vm.prank(address(controller));
        vm.expectRevert(ExecutionUpgradeSchedule.PendingUpgrade.selector);
        schedule.schedule(_release(1).releaseHash, _release(2), 2_000);
    }

    function testRejectsWrongPredecessorAndMissingArtifact() external {
        vm.prank(address(controller));
        vm.expectRevert(ExecutionUpgradeSchedule.WrongPredecessor.selector);
        schedule.schedule(bytes32(0), _release(1), ACTIVATION);
        ExecutionUpgradeSchedule.Release memory next = _release(1);
        next.guestArtifactHash = bytes32(0);
        vm.prank(address(controller));
        vm.expectRevert(ExecutionUpgradeSchedule.InvalidRelease.selector);
        schedule.schedule(_release(0).releaseHash, next, ACTIVATION);
    }

    function testCancellationViaTimelockRetainsReplayProtection() external {
        bytes32 id = _enact();
        bytes memory data = abi.encodeCall(schedule.cancel, (id));
        UpgradeController.Operation memory op = _queue(data);
        vm.warp(op.notBefore);
        controller.execute(op, data);
        assertEq(schedule.entryCount(), 1);
        assertEq(schedule.releaseAt(ACTIVATION).runtimeVersion, 0);
        assertTrue(schedule.used(id));
        vm.prank(address(controller));
        vm.expectRevert(ExecutionUpgradeSchedule.AlreadyUsed.selector);
        schedule.schedule(_release(0).releaseHash, _release(1), ACTIVATION);
    }

    function testCannotCancelAtOrInsideSafetyWindow() external {
        bytes32 id = _enact();
        vm.warp(schedule.activationTimestamp(ACTIVATION) - CANCEL_NOTICE);
        vm.prank(address(controller));
        vm.expectRevert(ExecutionUpgradeSchedule.CancellationTooLate.selector);
        schedule.cancel(id);
        vm.warp(schedule.activationTimestamp(ACTIVATION));
        vm.prank(address(controller));
        vm.expectRevert(ExecutionUpgradeSchedule.CancellationTooLate.selector);
        schedule.cancel(id);
    }

    function testCancellationImmediatelyBeforeSafetyWindow() external {
        bytes32 id = _enact();
        vm.warp(schedule.activationTimestamp(ACTIVATION) - CANCEL_NOTICE - 1);
        vm.prank(address(controller));
        schedule.cancel(id);
        assertEq(schedule.entryCount(), 1);
    }

    function testCancelledControllerOperationDoesNotRewriteEnactedSchedule() external {
        bytes32 id = _enact();
        bytes memory data = abi.encodeCall(schedule.cancel, (id));
        UpgradeController.Operation memory op = _queue(data);
        vm.prank(AUTHORITY);
        controller.cancel(op);
        assertEq(schedule.releaseAt(ACTIVATION).runtimeVersion, 1);
    }

    function testAppendAfterActivationPreservesHistoricalRules() external {
        _enact();
        vm.warp(schedule.activationTimestamp(ACTIVATION));
        vm.prank(address(controller));
        schedule.schedule(_release(1).releaseHash, _release(2), 2_000);
        assertEq(schedule.releaseAt(999).runtimeVersion, 0);
        assertEq(schedule.releaseAt(1_000).runtimeVersion, 1);
        assertEq(schedule.releaseAt(1_999).runtimeVersion, 1);
        assertEq(schedule.releaseAt(2_000).runtimeVersion, 2);
        bytes32 oldId = schedule.entryAt(1).upgradeId;
        vm.prank(address(controller));
        vm.expectRevert(ExecutionUpgradeSchedule.NotPending.selector);
        schedule.cancel(oldId);
    }

    function testDescriptorBindsChainScheduleArtifactsAndHeight() external {
        bytes32 from = _release(0).releaseHash;
        ExecutionUpgradeSchedule.Release memory next = _release(1);
        bytes32 id = schedule.hashUpgrade(from, next, ACTIVATION);
        assertNotEq(id, schedule.hashUpgrade(from, next, ACTIVATION + 1));
        assertNotEq(id, schedule.hashUpgrade(bytes32(0), next, ACTIVATION));
        next.nodeArtifactHash = keccak256("other node");
        assertNotEq(id, schedule.hashUpgrade(from, next, ACTIVATION));
        next = _release(1);
        ExecutionUpgradeSchedule other = _deploy(2, NOTICE, CANCEL_NOTICE, _release(0));
        assertNotEq(id, other.hashUpgrade(from, next, ACTIVATION));
        vm.chainId(block.chainid + 1);
        assertNotEq(id, schedule.hashUpgrade(from, next, ACTIVATION));
    }

    function testRejectsInvalidConfigurationAndNonzeroGenesis() external {
        vm.expectRevert(ExecutionUpgradeSchedule.InvalidConfiguration.selector);
        _deploy(0, NOTICE, CANCEL_NOTICE, _release(0));
        vm.expectRevert(ExecutionUpgradeSchedule.InvalidConfiguration.selector);
        _deploy(2, 0, CANCEL_NOTICE, _release(0));
        vm.expectRevert(ExecutionUpgradeSchedule.InvalidConfiguration.selector);
        _deploy(2, NOTICE, NOTICE + 1, _release(0));
        vm.expectRevert(ExecutionUpgradeSchedule.InvalidRelease.selector);
        _deploy(2, NOTICE, CANCEL_NOTICE, _release(1));
    }

    function testFuzzHistoricalLookup(uint64 height) external {
        _enact();
        assertEq(schedule.releaseAt(height).runtimeVersion, height < ACTIVATION ? 0 : 1);
    }
}

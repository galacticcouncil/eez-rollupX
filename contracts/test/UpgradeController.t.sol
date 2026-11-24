// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {RollupDeployment} from "./utils/RollupDeployment.sol";
import {OwnableUpgradeable as Ownable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {EEZ} from "eez-core-protocol/src/EEZ.sol";
import {Rollup} from "eez-core-protocol/src/rollupContract/Rollup.sol";
import {ECDSAProofSystem} from "../src/ECDSAProofSystem.sol";
import {AuthorityRegistry} from "../src/governance/AuthorityRegistry.sol";
import {UpgradeController} from "../src/governance/UpgradeController.sol";

/// @notice Real EEZ/Rollup ownership handoff, with no mocked governance permissions.
contract UpgradeControllerTest is Test {
    address private constant AUTHORITY = address(0xA11CE);
    address private constant NEXT_AUTHORITY = address(0xB0B);
    bytes32 private constant SOURCE = keccak256("alpha bootstrap authority");
    bytes32 private constant NEXT_SOURCE = keccak256("native governance adapter");
    bytes32 private constant NEW_KEY = keccak256("version two");
    uint64 private constant DELAY = 1 days;

    EEZ private eez;
    Rollup private manager;
    ECDSAProofSystem private proofSystem;
    UpgradeController private controller;
    AuthorityRegistry private registry;

    function setUp() external {
        vm.warp(1_000_000);
        eez = RollupDeployment.deployEEZ(address(0xCAFE), address(this));
        proofSystem = new ECDSAProofSystem(address(0x51));
        address[] memory systems = new address[](1);
        systems[0] = address(proofSystem);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = bytes32(uint256(0x51));
        manager = RollupDeployment.deploy(address(eez), address(this), 1, systems, keys);
        uint64 rollupId = eez.registerRollup(address(manager), keccak256("initial root"));
        controller = new UpgradeController(address(eez), rollupId, AUTHORITY, SOURCE, DELAY);
        registry = controller.AUTHORITY_REGISTRY();
        manager.transferOwnership(address(controller));
    }

    function testOwnershipHandoffAndConfiguration() external view {
        assertEq(manager.owner(), address(controller));
        assertEq(registry.CONTROLLER(), address(controller));
        assertEq(registry.authority(), AUTHORITY);
        assertEq(registry.sourceDomain(), SOURCE);
        assertEq(registry.epoch(), 1);
        assertEq(controller.EEZ_REGISTRY(), address(eez));
        assertEq(controller.ROLLUP_ID(), manager.rollupId());
        assertEq(controller.MIN_DELAY(), DELAY);
    }

    function testPermissionlessExecutionAfterDelay() external {
        (UpgradeController.Operation memory op, bytes memory data) = _keyOperation(1);
        bytes32 id = _schedule(op);
        assertEq(uint256(controller.status(id)), uint256(UpgradeController.Status.Scheduled));
        assertEq(manager.verificationKey(address(proofSystem)), bytes32(uint256(0x51)));
        vm.warp(op.notBefore);
        vm.prank(address(0xF00D));
        controller.execute(op, data);
        assertEq(manager.verificationKey(address(proofSystem)), NEW_KEY);
        assertEq(uint256(controller.status(id)), uint256(UpgradeController.Status.Executed));
    }

    function testFormerOwnerAndAuthorityCannotBypassDelay() external {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        manager.updateVerificationKey(address(proofSystem), NEW_KEY);
        vm.prank(AUTHORITY);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, AUTHORITY));
        manager.setThreshold(0);
    }

    function testRejectsUnauthorizedScheduleAndCancellation() external {
        (UpgradeController.Operation memory op,) = _keyOperation(1);
        vm.expectRevert(UpgradeController.Unauthorized.selector);
        controller.schedule(op);
        _schedule(op);
        vm.expectRevert(UpgradeController.Unauthorized.selector);
        controller.cancel(op);
    }

    function testRejectsEarlyAndExpiredExecutionAtExactBoundaries() external {
        (UpgradeController.Operation memory op, bytes memory data) = _keyOperation(1);
        _schedule(op);
        vm.warp(op.notBefore - 1);
        vm.expectRevert(UpgradeController.NotReady.selector);
        controller.execute(op, data);
        vm.warp(op.expiresAt);
        vm.expectRevert(UpgradeController.Expired.selector);
        controller.execute(op, data);
    }

    function testExecutesImmediatelyBeforeExpiry() external {
        (UpgradeController.Operation memory op, bytes memory data) = _keyOperation(1);
        _schedule(op);
        vm.warp(op.expiresAt - 1);
        controller.execute(op, data);
        assertEq(manager.verificationKey(address(proofSystem)), NEW_KEY);
    }

    function testCancellationIsTerminalAndNonceCannotBeReused() external {
        (UpgradeController.Operation memory op, bytes memory data) = _keyOperation(1);
        bytes32 id = _schedule(op);
        vm.prank(AUTHORITY);
        controller.cancel(op);
        assertEq(uint256(controller.status(id)), uint256(UpgradeController.Status.Cancelled));
        vm.warp(op.notBefore);
        vm.expectRevert(UpgradeController.NotScheduled.selector);
        controller.execute(op, data);
        op.notBefore = uint64(block.timestamp + DELAY);
        op.expiresAt = op.notBefore + 1 days;
        vm.prank(AUTHORITY);
        vm.expectRevert(UpgradeController.NonceAlreadyUsed.selector);
        controller.schedule(op);
    }

    function testCannotCancelExecutedOperation() external {
        (UpgradeController.Operation memory op, bytes memory data) = _keyOperation(1);
        _schedule(op);
        vm.warp(op.notBefore);
        controller.execute(op, data);
        vm.prank(AUTHORITY);
        vm.expectRevert(UpgradeController.NotScheduled.selector);
        controller.cancel(op);
    }

    function testExecutionReplayRejected() external {
        (UpgradeController.Operation memory op, bytes memory data) = _keyOperation(1);
        _schedule(op);
        vm.warp(op.notBefore);
        controller.execute(op, data);
        vm.expectRevert(UpgradeController.NotScheduled.selector);
        controller.execute(op, data);
    }

    function testNonceCannotScheduleDifferentPayload() external {
        (UpgradeController.Operation memory op,) = _keyOperation(1);
        _schedule(op);
        op.calldataHash = keccak256("different payload");
        vm.prank(AUTHORITY);
        vm.expectRevert(UpgradeController.NonceAlreadyUsed.selector);
        controller.schedule(op);
    }

    function testRejectsUnscheduledAndChangedOperation() external {
        (UpgradeController.Operation memory op, bytes memory data) = _keyOperation(1);
        vm.expectRevert(UpgradeController.NotScheduled.selector);
        controller.execute(op, data);
        _schedule(op);
        vm.warp(op.notBefore);
        op.expiresAt += 1;
        vm.expectRevert(UpgradeController.NotScheduled.selector);
        controller.execute(op, data);
    }

    function testRejectsChangedCalldata() external {
        (UpgradeController.Operation memory op,) = _keyOperation(1);
        _schedule(op);
        vm.warp(op.notBefore);
        vm.expectRevert(UpgradeController.CalldataMismatch.selector);
        controller.execute(op, abi.encodeCall(manager.setThreshold, (0)));
    }

    function testRejectsWrongEpochAndSourceDomain() external {
        (UpgradeController.Operation memory op,) = _keyOperation(1);
        op.authorityEpoch = 2;
        vm.prank(AUTHORITY);
        vm.expectRevert(UpgradeController.WrongAuthority.selector);
        controller.schedule(op);
        op.authorityEpoch = 1;
        op.sourceDomain = NEXT_SOURCE;
        vm.prank(AUTHORITY);
        vm.expectRevert(UpgradeController.WrongAuthority.selector);
        controller.schedule(op);
    }

    function testRejectsInvalidWindows() external {
        (UpgradeController.Operation memory op,) = _keyOperation(1);
        op.notBefore -= 1;
        vm.prank(AUTHORITY);
        vm.expectRevert(UpgradeController.InvalidWindow.selector);
        controller.schedule(op);
        op.notBefore += 1;
        op.expiresAt = op.notBefore;
        vm.prank(AUTHORITY);
        vm.expectRevert(UpgradeController.InvalidWindow.selector);
        controller.schedule(op);
    }

    function testRejectsEOAAndSelfTargets() external {
        (UpgradeController.Operation memory op,) = _keyOperation(1);
        op.target = AUTHORITY;
        vm.prank(AUTHORITY);
        vm.expectRevert(UpgradeController.InvalidTarget.selector);
        controller.schedule(op);
        op.target = address(controller);
        vm.prank(AUTHORITY);
        vm.expectRevert(UpgradeController.InvalidTarget.selector);
        controller.schedule(op);
    }

    function testTargetWithoutCodeCannotExecute() external {
        (UpgradeController.Operation memory op, bytes memory data) = _keyOperation(1);
        _schedule(op);
        vm.warp(op.notBefore);
        vm.etch(op.target, hex"");
        vm.expectRevert(UpgradeController.InvalidTarget.selector);
        controller.execute(op, data);
    }

    function testHashSeparatedAcrossChainsControllersRegistriesAndRollups() external {
        (UpgradeController.Operation memory op,) = _keyOperation(1);
        bytes32 id = controller.hashOperation(op);
        vm.chainId(block.chainid + 1);
        assertNotEq(controller.hashOperation(op), id);
        vm.chainId(block.chainid - 1);
        UpgradeController other = new UpgradeController(address(eez), 1, AUTHORITY, SOURCE, DELAY);
        assertNotEq(other.hashOperation(op), id);
        // Explicitly pin the hash preimage: registry and rollup are domain fields,
        // rather than relying on different deployed controller addresses alone.
        assertEq(id, _hashAt(op, address(eez), manager.rollupId()));
        assertNotEq(id, _hashAt(op, address(0x1234), manager.rollupId()));
        assertNotEq(id, _hashAt(op, address(eez), manager.rollupId() + 1));
    }

    function testTargetFailureRollsBackAndCanRetry() external {
        RetryTarget target = new RetryTarget();
        bytes memory data = abi.encodeCall(target.invoke, ());
        UpgradeController.Operation memory op = _operation(1, address(target), data);
        bytes32 id = _schedule(op);
        vm.warp(op.notBefore);
        vm.expectRevert(
            abi.encodeWithSelector(
                UpgradeController.TargetCallFailed.selector, abi.encodeWithSignature("Error(string)", "try later")
            )
        );
        controller.execute(op, data);
        assertEq(uint256(controller.status(id)), uint256(UpgradeController.Status.Scheduled));
        target.allow();
        assertEq(abi.decode(controller.execute(op, data), (uint256)), 42);
    }

    function testReentrancyCannotExecuteAnotherReadyOperation() external {
        (UpgradeController.Operation memory inner, bytes memory data) = _keyOperation(1);
        _schedule(inner);
        ReentrantTarget target = new ReentrantTarget(controller, inner, data);
        UpgradeController.Operation memory outer = _operation(2, address(target), abi.encodeCall(target.invoke, ()));
        _schedule(outer);
        vm.warp(outer.notBefore);
        controller.execute(outer, abi.encodeCall(target.invoke, ()));
        assertEq(target.failure(), UpgradeController.ReentrantExecution.selector);
        assertEq(manager.verificationKey(address(proofSystem)), bytes32(uint256(0x51)));
        controller.execute(inner, data);
        assertEq(manager.verificationKey(address(proofSystem)), NEW_KEY);
    }

    function testRotationRequiresDelayAndInvalidatesAllOldOperations() external {
        (UpgradeController.Operation memory stale, bytes memory staleData) = _keyOperation(1);
        _schedule(stale);
        bytes memory rotation = abi.encodeCall(registry.rotateAuthority, (NEXT_AUTHORITY, NEXT_SOURCE));
        UpgradeController.Operation memory op = _operation(2, address(registry), rotation);
        _schedule(op);
        vm.expectRevert(UpgradeController.NotReady.selector);
        controller.execute(op, rotation);
        vm.warp(op.notBefore);
        controller.execute(op, rotation);
        assertEq(registry.authority(), NEXT_AUTHORITY);
        assertEq(registry.sourceDomain(), NEXT_SOURCE);
        assertEq(registry.epoch(), 2);
        vm.expectRevert(UpgradeController.WrongAuthority.selector);
        controller.execute(stale, staleData);
        vm.prank(AUTHORITY);
        vm.expectRevert(UpgradeController.Unauthorized.selector);
        controller.schedule(stale);

        // Nonce 1 may be reused in epoch 2, but still requires a fresh complete delay.
        (UpgradeController.Operation memory fresh, bytes memory freshData) = _keyOperation(1);
        vm.prank(NEXT_AUTHORITY);
        controller.schedule(fresh);
        vm.expectRevert(UpgradeController.NotReady.selector);
        controller.execute(fresh, freshData);
        vm.warp(fresh.notBefore);
        controller.execute(fresh, freshData);
        assertEq(manager.verificationKey(address(proofSystem)), NEW_KEY);
    }

    function testDirectRotationRejectedEvenFromAuthority() external {
        vm.prank(AUTHORITY);
        vm.expectRevert(AuthorityRegistry.Unauthorized.selector);
        registry.rotateAuthority(NEXT_AUTHORITY, NEXT_SOURCE);
    }

    function testRetiredAuthorityAndDomainCannotBeReactivated() external {
        bytes memory rotation = abi.encodeCall(registry.rotateAuthority, (NEXT_AUTHORITY, NEXT_SOURCE));
        UpgradeController.Operation memory op = _operation(1, address(registry), rotation);
        _schedule(op);
        vm.warp(op.notBefore);
        controller.execute(op, rotation);
        assertTrue(registry.retiredAuthority(AUTHORITY));
        assertTrue(registry.retiredDomain(SOURCE));
        vm.prank(address(controller));
        vm.expectRevert(AuthorityRegistry.InvalidAuthority.selector);
        registry.rotateAuthority(AUTHORITY, keccak256("new label"));
        vm.prank(address(controller));
        vm.expectRevert(AuthorityRegistry.InvalidAuthority.selector);
        registry.rotateAuthority(address(0x1234), SOURCE);
    }

    function testCanRotateAdapterWithinSameSourceDomain() external {
        bytes memory rotation = abi.encodeCall(registry.rotateAuthority, (NEXT_AUTHORITY, SOURCE));
        UpgradeController.Operation memory op = _operation(1, address(registry), rotation);
        _schedule(op);
        vm.warp(op.notBefore);
        controller.execute(op, rotation);
        assertEq(registry.epoch(), 2);
        assertEq(registry.sourceDomain(), SOURCE);
        assertFalse(registry.retiredDomain(SOURCE));
        assertTrue(registry.retiredAuthority(AUTHORITY));
    }

    function testRejectsInvalidAuthorityAndConfiguration() external {
        vm.expectRevert(UpgradeController.InvalidConfiguration.selector);
        new UpgradeController(AUTHORITY, 1, AUTHORITY, SOURCE, DELAY);
        vm.expectRevert(UpgradeController.InvalidConfiguration.selector);
        new UpgradeController(address(eez), 0, AUTHORITY, SOURCE, DELAY);
        vm.expectRevert(UpgradeController.InvalidConfiguration.selector);
        new UpgradeController(address(eez), 1, AUTHORITY, SOURCE, 0);
        vm.expectRevert(AuthorityRegistry.InvalidAuthority.selector);
        new UpgradeController(address(eez), 1, address(0), SOURCE, DELAY);
        vm.expectRevert(AuthorityRegistry.InvalidAuthority.selector);
        new UpgradeController(address(eez), 1, AUTHORITY, bytes32(0), DELAY);
        vm.prank(address(controller));
        vm.expectRevert(AuthorityRegistry.InvalidAuthority.selector);
        registry.rotateAuthority(address(controller), NEXT_SOURCE);
        vm.prank(address(controller));
        vm.expectRevert(AuthorityRegistry.InvalidAuthority.selector);
        registry.rotateAuthority(address(registry), NEXT_SOURCE);
    }

    function testFuzzPayloadBinding(bytes memory changedData) external {
        (UpgradeController.Operation memory op, bytes memory data) = _keyOperation(1);
        vm.assume(keccak256(changedData) != keccak256(data));
        _schedule(op);
        vm.warp(op.notBefore);
        vm.expectRevert(UpgradeController.CalldataMismatch.selector);
        controller.execute(op, changedData);
    }

    function testFuzzEarlyExecution(uint64 timestamp) external {
        (UpgradeController.Operation memory op, bytes memory data) = _keyOperation(1);
        _schedule(op);
        timestamp = uint64(bound(timestamp, block.timestamp, op.notBefore - 1));
        vm.warp(timestamp);
        vm.expectRevert(UpgradeController.NotReady.selector);
        controller.execute(op, data);
    }

    function _hashAt(
        UpgradeController.Operation memory op,
        address registryAddress,
        uint64 rollupId
    )
        private
        view
        returns (bytes32)
    {
        return
            keccak256(
                abi.encode(controller.DOMAIN(), block.chainid, address(controller), registryAddress, rollupId, op)
            );
    }

    function _schedule(UpgradeController.Operation memory op) private returns (bytes32) {
        vm.prank(AUTHORITY);
        return controller.schedule(op);
    }

    function _keyOperation(uint64 nonce)
        private
        view
        returns (UpgradeController.Operation memory op, bytes memory data)
    {
        data = abi.encodeCall(manager.updateVerificationKey, (address(proofSystem), NEW_KEY));
        op = _operation(nonce, address(manager), data);
    }

    function _operation(
        uint64 nonce,
        address target,
        bytes memory data
    )
        private
        view
        returns (UpgradeController.Operation memory)
    {
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

contract RetryTarget {
    bool private ready;

    function allow() external {
        ready = true;
    }

    function invoke() external view returns (uint256) {
        require(ready, "try later");
        return 42;
    }
}

contract ReentrantTarget {
    UpgradeController private immutable controller;
    UpgradeController.Operation private operation;
    bytes private data;
    bytes4 public failure;

    constructor(UpgradeController executor, UpgradeController.Operation memory op, bytes memory callData) {
        controller = executor;
        operation = op;
        data = callData;
    }

    function invoke() external {
        try controller.execute(operation, data) {
            revert("reentry succeeded");
        } catch (bytes memory reason) {
            failure = bytes4(reason);
            require(failure == UpgradeController.ReentrantExecution.selector, "unexpected failure");
        }
    }
}

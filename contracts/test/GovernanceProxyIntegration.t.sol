// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {RollupDeployment} from "./utils/RollupDeployment.sol";
import {EEZ} from "eez-core-protocol/src/EEZ.sol";
import {Rollup} from "eez-core-protocol/src/rollupContract/Rollup.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {UpgradeController} from "../src/governance/UpgradeController.sol";

contract GovernanceProxyIntegrationTest is Test {
    bytes32 private constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
    bytes32 private constant IMPL_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    address private constant AUTHORITY = address(0xA11CE);
    bytes32 private constant SOURCE = keccak256("bootstrap");

    function testOperationalHandoffDoesNotTransferProxyAdmin() external {
        (Rollup manager, UpgradeController controller, ProxyAdmin admin) = _deploy();
        assertEq(manager.owner(), address(controller));
        assertEq(admin.owner(), address(this));
        assertNotEq(admin.owner(), address(controller));
    }

    function testExplicitAdminHandoffRequiresTimelockForImplementationChange() external {
        (Rollup manager, UpgradeController controller, ProxyAdmin admin) = _deploy();
        admin.transferOwnership(address(controller));
        Rollup implementation = new Rollup(manager.EEZContract());
        bytes memory data = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (ITransparentUpgradeableProxy(address(manager)), address(implementation), bytes(""))
        );
        UpgradeController.Operation memory op = UpgradeController.Operation({
            authorityEpoch: 1,
            nonce: 1,
            sourceDomain: SOURCE,
            target: address(admin),
            calldataHash: keccak256(data),
            notBefore: uint64(block.timestamp + 100),
            expiresAt: uint64(block.timestamp + 1_000)
        });
        vm.prank(AUTHORITY);
        controller.schedule(op);
        vm.expectRevert(UpgradeController.NotReady.selector);
        controller.execute(op, data);
        vm.warp(op.notBefore);
        controller.execute(op, data);
        assertEq(address(uint160(uint256(vm.load(address(manager), IMPL_SLOT)))), address(implementation));
        assertEq(manager.owner(), address(controller));
        assertEq(manager.rollupId(), controller.ROLLUP_ID());
    }

    function _deploy() private returns (Rollup manager, UpgradeController controller, ProxyAdmin admin) {
        EEZ eez = RollupDeployment.deployEEZ(address(0xCAFE), address(this));
        manager = RollupDeployment.deploy(address(eez), address(this), 1, new address[](0), new bytes32[](0));
        uint64 id = eez.registerRollup(address(manager), keccak256("genesis"));
        controller = new UpgradeController(address(eez), id, AUTHORITY, SOURCE, 100);
        admin = ProxyAdmin(address(uint160(uint256(vm.load(address(manager), ADMIN_SLOT)))));
        manager.transferOwnership(address(controller));
    }
}

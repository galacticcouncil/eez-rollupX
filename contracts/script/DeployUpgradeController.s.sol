// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "eez-core-protocol/src/EEZ.sol";
import {Rollup} from "eez-core-protocol/src/rollupContract/Rollup.sol";
import {UpgradeController} from "../src/governance/UpgradeController.sol";

/// @notice Deploy a controller for a registered rollup and transfer its ownership.
/// @dev Run as the CURRENT manager owner. Validates ownership before deployment.
///      No private keys are read or logged; use Foundry's external signer options.
contract DeployUpgradeController is Script {
    function run(
        address managerAddress,
        address authority,
        bytes32 sourceDomain,
        uint64 minDelay
    )
        external
        returns (UpgradeController controller)
    {
        Rollup manager = Rollup(managerAddress);
        uint64 rollupId = manager.rollupId();
        require(rollupId != 0, "manager not registered");
        (address registeredManager,,) = EEZ(payable(manager.EEZContract())).rollups(rollupId);
        require(registeredManager == managerAddress, "wrong registered manager");

        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        require(manager.owner() == broadcaster, "broadcast as current owner");
        controller = new UpgradeController(manager.EEZContract(), rollupId, authority, sourceDomain, minDelay);
        manager.transferOwnership(address(controller));
        vm.stopBroadcast();

        require(manager.owner() == address(controller), "ownership handoff failed");
        console.log("UPGRADE_CONTROLLER=%s", address(controller));
        console.log("AUTHORITY_REGISTRY=%s", address(controller.AUTHORITY_REGISTRY()));
        console.log("Manager owner only: ProxyAdmin and recovery ownership are unchanged.");
    }
}

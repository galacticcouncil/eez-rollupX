// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {EEZ} from "eez-core-protocol/src/EEZ.sol";
import {Rollup} from "eez-core-protocol/src/rollupContract/Rollup.sol";
import {UpgradeController} from "../src/governance/UpgradeController.sol";
import {ExecutionUpgradeSchedule} from "../src/governance/ExecutionUpgradeSchedule.sol";

/// @notice Explicit opt-in devnet deployment. Run as the manager's owner.
/// @dev Deploys both contracts before handing off ownership. Three transactions:
///      partial broadcasts need inspection/recovery before retrying. No keys read.
contract DeployRuntimeGovernance is Script {
    struct Deployment {
        address manager;
        address authority;
        bytes32 sourceDomain;
        uint64 minDelay;
        uint256 l2ChainId;
        bytes32 l2GenesisHash;
        uint64 l2GenesisTimestamp;
        uint64 blockSeconds;
        uint64 minNotice;
        uint64 cancelNotice;
        ExecutionUpgradeSchedule.Release genesis;
    }

    function run(Deployment memory d)
        external
        returns (UpgradeController controller, ExecutionUpgradeSchedule schedule)
    {
        Rollup manager = Rollup(d.manager);
        uint64 rollupId = manager.rollupId();
        require(rollupId != 0, "manager not registered");
        (address registeredManager,,) = EEZ(payable(manager.EEZContract())).rollups(rollupId);
        require(registeredManager == d.manager, "wrong registered manager");
        require(uint256(d.minNotice) > uint256(d.minDelay) + d.cancelNotice, "no cancellation response window");
        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        require(manager.owner() == broadcaster, "broadcast as current owner");
        controller = new UpgradeController(manager.EEZContract(), rollupId, d.authority, d.sourceDomain, d.minDelay);
        schedule = new ExecutionUpgradeSchedule(
            controller,
            d.l2ChainId,
            d.l2GenesisHash,
            d.l2GenesisTimestamp,
            d.blockSeconds,
            d.minNotice,
            d.cancelNotice,
            d.genesis
        );
        manager.transferOwnership(address(controller));
        vm.stopBroadcast();
        require(manager.owner() == address(controller), "ownership handoff failed");
        console.log("UPGRADE_CONTROLLER=%s", address(controller));
        console.log("EXECUTION_SCHEDULE=%s", address(schedule));
        console.log("AUTHORITY_REGISTRY=%s", address(controller.AUTHORITY_REGISTRY()));
        console.log("Manager owner only: ProxyAdmin and recovery ownership are unchanged.");
    }
}

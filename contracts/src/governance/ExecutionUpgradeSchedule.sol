// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {UpgradeController} from "./UpgradeController.sol";

/// @notice Controller-owned rehearsal schedule: retained history and a cancellable future tail.
/// @dev Records authorization, NOT proof verification or observed L2 progress.
///      The immutable timestamp grid must match the L2 genesis/slot configuration.
contract ExecutionUpgradeSchedule {
    struct Release {
        uint32 runtimeVersion;
        bytes32 releaseHash;
        bytes32 nodeArtifactHash;
        bytes32 guestArtifactHash;
        // May be zero for the ECDSA rehearsal, which has no ZisK program key.
        bytes32 programVKey;
    }

    struct Entry {
        uint64 activationBlock;
        bytes32 upgradeId;
        Release release;
    }

    bytes32 public constant DOMAIN = keccak256("HYDRATION_EEZ_EXECUTION_SCHEDULE_V1");
    UpgradeController public immutable CONTROLLER;
    uint256 public immutable L2_CHAIN_ID;
    bytes32 public immutable L2_GENESIS_HASH;
    uint64 public immutable L2_GENESIS_TIMESTAMP;
    uint64 public immutable L2_BLOCK_SECONDS;
    uint64 public immutable MIN_NOTICE;
    uint64 public immutable CANCEL_NOTICE;

    Entry[] private entries;
    mapping(bytes32 upgradeId => bool) public used;

    error Unauthorized();
    error InvalidConfiguration();
    error InvalidRelease();
    error PendingUpgrade();
    error WrongPredecessor();
    error InsufficientNotice();
    error AlreadyUsed();
    error NotPending();
    error CancellationTooLate();

    event UpgradeScheduled(bytes32 indexed upgradeId, uint64 indexed activationBlock, Release release);
    event UpgradeCancelled(bytes32 indexed upgradeId);

    constructor(
        UpgradeController controller,
        uint256 l2ChainId,
        bytes32 l2GenesisHash,
        uint64 l2GenesisTimestamp,
        uint64 l2BlockSeconds,
        uint64 minNotice,
        uint64 cancelNotice,
        Release memory genesis
    ) {
        if (
            address(controller).code.length == 0 || l2ChainId == 0 || l2GenesisHash == bytes32(0)
                || l2GenesisTimestamp > block.timestamp || l2BlockSeconds == 0 || minNotice == 0 || cancelNotice == 0
                || cancelNotice > minNotice
        ) revert InvalidConfiguration();
        _validateRelease(genesis);
        if (genesis.runtimeVersion != 0) revert InvalidRelease();
        CONTROLLER = controller;
        L2_CHAIN_ID = l2ChainId;
        L2_GENESIS_HASH = l2GenesisHash;
        L2_GENESIS_TIMESTAMP = l2GenesisTimestamp;
        L2_BLOCK_SECONDS = l2BlockSeconds;
        MIN_NOTICE = minNotice;
        CANCEL_NOTICE = cancelNotice;
        entries.push(Entry(0, bytes32(0), genesis));
    }

    /// @notice Canonical descriptor hash, including predecessor and chain/rollup domain.
    function hashUpgrade(
        bytes32 fromReleaseHash,
        Release memory next,
        uint64 activationBlock
    )
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                DOMAIN,
                block.chainid,
                address(this),
                address(CONTROLLER),
                CONTROLLER.EEZ_REGISTRY(),
                CONTROLLER.ROLLUP_ID(),
                L2_CHAIN_ID,
                L2_GENESIS_HASH,
                L2_GENESIS_TIMESTAMP,
                L2_BLOCK_SECONDS,
                fromReleaseHash,
                next,
                activationBlock
            )
        );
    }

    function activationTimestamp(uint64 activationBlock) public view returns (uint256) {
        return uint256(L2_GENESIS_TIMESTAMP) + uint256(activationBlock) * L2_BLOCK_SECONDS;
    }

    /// @notice Called by the timelock at execution, not when a proposal is queued.
    function schedule(
        bytes32 fromReleaseHash,
        Release calldata next,
        uint64 activationBlock
    )
        external
        returns (bytes32 upgradeId)
    {
        _onlyController();
        Entry storage previous = entries[entries.length - 1];
        if (activationTimestamp(previous.activationBlock) > block.timestamp) revert PendingUpgrade();
        if (fromReleaseHash != previous.release.releaseHash) revert WrongPredecessor();
        _validateRelease(next);
        if (
            uint256(next.runtimeVersion) != uint256(previous.release.runtimeVersion) + 1
                || next.releaseHash == fromReleaseHash
        ) revert InvalidRelease();
        if (
            activationBlock <= previous.activationBlock
                || activationTimestamp(activationBlock) < block.timestamp + MIN_NOTICE
        ) revert InsufficientNotice();
        upgradeId = hashUpgrade(fromReleaseHash, next, activationBlock);
        if (used[upgradeId]) revert AlreadyUsed();
        used[upgradeId] = true;
        entries.push(Entry(activationBlock, upgradeId, next));
        emit UpgradeScheduled(upgradeId, activationBlock, next);
    }

    /// @notice Only the future tail can be cancelled, with its own safety margin.
    ///         Cancelling a queued controller operation does NOT cancel this schedule.
    function cancel(bytes32 upgradeId) external {
        _onlyController();
        Entry storage pending = entries[entries.length - 1];
        if (entries.length == 1 || pending.upgradeId != upgradeId) revert NotPending();
        if (activationTimestamp(pending.activationBlock) <= block.timestamp + CANCEL_NOTICE) {
            revert CancellationTooLate();
        }
        entries.pop();
        emit UpgradeCancelled(upgradeId);
    }

    /// @notice Historical lookup: reports the scheduled rules at an L2 height,
    ///         not whether that block exists or its schedule is L1-finalized.
    function releaseAt(uint64 l2Block) public view returns (Release memory) {
        uint256 low;
        uint256 high = entries.length;
        while (low + 1 < high) {
            uint256 middle = (low + high) / 2;
            if (entries[middle].activationBlock <= l2Block) low = middle;
            else high = middle;
        }
        return entries[low].release;
    }

    function entryCount() external view returns (uint256) {
        return entries.length;
    }

    function entryAt(uint256 index) external view returns (Entry memory) {
        return entries[index];
    }

    function _onlyController() private view {
        if (msg.sender != address(CONTROLLER)) revert Unauthorized();
    }

    function _validateRelease(Release memory release) private pure {
        if (
            release.releaseHash == bytes32(0) || release.nodeArtifactHash == bytes32(0)
                || release.guestArtifactHash == bytes32(0)
        ) revert InvalidRelease();
    }
}

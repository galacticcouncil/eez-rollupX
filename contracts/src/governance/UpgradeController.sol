// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AuthorityRegistry} from "./AuthorityRegistry.sol";

/// @notice Alpha Root executor: authenticated scheduling, immutable delay,
///         permissionless execution, cancellation, expiry, and authority epochs.
/// @dev Controls the EEZ manager only after its operational ownership handoff;
///      ProxyAdmin/recovery ownership is separate. This settlement-chain timelock does not
///      enforce an L2-height execution/program schedule. No immediate-execution path.
contract UpgradeController {
    struct Operation {
        uint64 authorityEpoch;
        uint64 nonce;
        bytes32 sourceDomain;
        address target;
        bytes32 calldataHash;
        uint64 notBefore;
        uint64 expiresAt;
    }

    enum Status {
        Unset,
        Scheduled,
        Cancelled,
        Executed
    }

    bytes32 public constant DOMAIN = keccak256("HYDRATION_EEZ_GOVERNANCE_V1");
    address public immutable EEZ_REGISTRY;
    uint64 public immutable ROLLUP_ID;
    uint64 public immutable MIN_DELAY;
    AuthorityRegistry public immutable AUTHORITY_REGISTRY;

    mapping(bytes32 operationId => Status) public status;
    mapping(uint64 epoch => mapping(uint64 nonce => bool used)) public nonceUsed;
    bool private executing;

    error InvalidConfiguration();
    error Unauthorized();
    error WrongAuthority();
    error InvalidTarget();
    error InvalidWindow();
    error NonceAlreadyUsed();
    error NotScheduled();
    error NotReady();
    error Expired();
    error CalldataMismatch();
    error ReentrantExecution();
    error TargetCallFailed(bytes reason);

    event OperationScheduled(
        bytes32 indexed operationId, uint64 indexed epoch, uint64 indexed nonce, Operation operation
    );
    event OperationCancelled(bytes32 indexed operationId);
    event OperationExecuted(bytes32 indexed operationId);

    constructor(address eezRegistry, uint64 rollupId, address authority, bytes32 sourceDomain, uint64 minDelay) {
        if (eezRegistry.code.length == 0 || rollupId == 0 || minDelay == 0) revert InvalidConfiguration();
        EEZ_REGISTRY = eezRegistry;
        ROLLUP_ID = rollupId;
        MIN_DELAY = minDelay;
        AUTHORITY_REGISTRY = new AuthorityRegistry(address(this), authority, sourceDomain);
    }

    /// @notice Binds the full operation to this chain, executor, EEZ registry, and rollup.
    function hashOperation(Operation memory operation) public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN, block.chainid, address(this), EEZ_REGISTRY, ROLLUP_ID, operation));
    }

    function schedule(Operation calldata operation) external returns (bytes32 operationId) {
        _onlyAuthority();
        _checkEpoch(operation);
        if (operation.target == address(this) || operation.target.code.length == 0) revert InvalidTarget();
        if (uint256(operation.notBefore) < block.timestamp + MIN_DELAY || operation.expiresAt <= operation.notBefore) {
            revert InvalidWindow();
        }
        if (nonceUsed[operation.authorityEpoch][operation.nonce]) revert NonceAlreadyUsed();
        nonceUsed[operation.authorityEpoch][operation.nonce] = true;
        operationId = hashOperation(operation);
        status[operationId] = Status.Scheduled;
        emit OperationScheduled(operationId, operation.authorityEpoch, operation.nonce, operation);
    }

    /// @notice Cancelled nonces remain consumed. Resubmission needs a fresh nonce and delay.
    function cancel(Operation calldata operation) external {
        _onlyAuthority();
        _checkEpoch(operation);
        bytes32 operationId = hashOperation(operation);
        if (status[operationId] != Status.Scheduled) revert NotScheduled();
        status[operationId] = Status.Cancelled;
        emit OperationCancelled(operationId);
    }

    /// @notice Anyone may deliver the approved calldata after the delay.
    /// @dev No ETH value transfers in the first PoC. A failed call leaves the operation
    ///      scheduled for retry until expiry. Reentrancy cannot execute another operation.
    function execute(Operation calldata operation, bytes calldata data) external returns (bytes memory result) {
        if (executing) revert ReentrantExecution();
        _checkEpoch(operation);
        bytes32 operationId = hashOperation(operation);
        if (status[operationId] != Status.Scheduled) revert NotScheduled();
        if (block.timestamp < operation.notBefore) revert NotReady();
        if (block.timestamp >= operation.expiresAt) revert Expired();
        if (keccak256(data) != operation.calldataHash) revert CalldataMismatch();
        if (operation.target.code.length == 0) revert InvalidTarget();

        status[operationId] = Status.Executed;
        executing = true;
        (bool success, bytes memory output) = operation.target.call(data);
        if (!success) revert TargetCallFailed(output);
        executing = false;
        emit OperationExecuted(operationId);
        return output;
    }

    function _onlyAuthority() private view {
        if (msg.sender != AUTHORITY_REGISTRY.authority()) revert Unauthorized();
    }

    function _checkEpoch(Operation calldata operation) private view {
        if (
            operation.authorityEpoch != AUTHORITY_REGISTRY.epoch()
                || operation.sourceDomain != AUTHORITY_REGISTRY.sourceDomain()
        ) revert WrongAuthority();
    }
}

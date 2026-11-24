// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IZiskVerifier} from "./IZiskVerifier.sol";

/// @title MockZiskVerifier
/// @notice TEST DOUBLE for ZisK's `ZiskVerifier`: accepts every proof unless `rejectAll` is set.
///         It performs NO cryptographic check. A devnet using it is not ZisK-proven; the only
///         real gate is whatever other proof system the rollup manager requires at its threshold.
///         Swap for the real `ZiskVerifier` (same interface) once real proofs exist.
///
/// @dev `verifySnarkProof` is `view` in `IZiskVerifier`, so this mock cannot record what the
///      adapter forwarded; tests observe the adapter through `ZiskProofSystem.verify` (an
///      `eth_call`) and the batch's on-chain outcome instead. `setRejectAll` is restricted to
///      the deployer so nobody else on a shared devnet can halt (or un-halt) settlement.
contract MockZiskVerifier is IZiskVerifier {
    error InvalidProof();
    error NotOwner(address caller, address owner);

    /// @notice The deployer: the only account allowed to flip `rejectAll`.
    address public immutable OWNER;

    /// @notice When true every call reverts `InvalidProof()`, so tests can drive the rejection path.
    bool public rejectAll;

    constructor() {
        OWNER = msg.sender;
    }

    /// @notice Owner-only switch between accept-all (default) and reject-all.
    function setRejectAll(bool value) external {
        if (msg.sender != OWNER) revert NotOwner(msg.sender, OWNER);
        rejectAll = value;
    }

    /// @inheritdoc IZiskVerifier
    function verifySnarkProof(
        bytes32 programVK,
        bytes32 rootCVadcopFinal,
        bytes calldata publicValues,
        bytes calldata /* proofBytes */
    )
        external
        view
    {
        // `view` in the interface: record nothing, only decide.
        programVK;
        rootCVadcopFinal;
        publicValues;
        if (rejectAll) revert InvalidProof();
    }
}

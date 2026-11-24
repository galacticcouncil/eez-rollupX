// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Single Root authority for the alpha. An adapter can later authenticate
///         OpenGov, native governance, or matching approvals from both systems.
/// @dev Only the timelocked controller rotates authority. Rotation invalidates
///      all pending operations from previous epochs; none are implicitly imported.
contract AuthorityRegistry {
    address public immutable CONTROLLER;
    address public authority;
    bytes32 public sourceDomain;
    uint64 public epoch = 1;
    mapping(address retired => bool) public retiredAuthority;
    mapping(bytes32 retired => bool) public retiredDomain;

    error Unauthorized();
    error InvalidAuthority();

    event AuthorityActivated(uint64 indexed epoch, address indexed authority, bytes32 sourceDomain);

    constructor(address controller, address initialAuthority, bytes32 initialDomain) {
        if (controller == address(0)) revert InvalidAuthority();
        CONTROLLER = controller;
        _validate(initialAuthority, initialDomain);
        authority = initialAuthority;
        sourceDomain = initialDomain;
        emit AuthorityActivated(epoch, initialAuthority, initialDomain);
    }

    /// @notice Schedule this through CONTROLLER with the same delay as other Root operations.
    function rotateAuthority(address nextAuthority, bytes32 nextDomain) external {
        if (msg.sender != CONTROLLER) revert Unauthorized();
        _validate(nextAuthority, nextDomain);
        retiredAuthority[authority] = true;
        if (nextDomain != sourceDomain) retiredDomain[sourceDomain] = true;
        ++epoch;
        authority = nextAuthority;
        sourceDomain = nextDomain;
        emit AuthorityActivated(epoch, nextAuthority, nextDomain);
    }

    function _validate(address candidate, bytes32 domain) private view {
        if (
            candidate == address(0) || candidate == CONTROLLER || candidate == address(this) || candidate == authority
                || retiredAuthority[candidate] || domain == bytes32(0) || retiredDomain[domain]
        ) {
            revert InvalidAuthority();
        }
    }
}

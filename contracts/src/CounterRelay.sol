// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title CounterRelay
/// @notice Hydration-side source of an OUTBOUND cross-chain call. Lives on the L2 and,
///         in one L2 transaction: bumps the native counter precompile at `0x…0800`,
///         takes the new count the precompile returns, and pushes it to an L1 `Value`
///         contract through that contract's L2-side `CrossChainProxy`. The composer
///         precomputes the L1 leg from its L2 simulation, so the `setValue(count)`
///         calldata is derived from precompile state, and the `(changed, newValue)`
///         tuple L1 returns is decoded back into this frame.
///         No access control: this is a pipeline test, not a product contract.
contract CounterRelay {
    /// `hydration_config::COUNTER_ADDRESS` (`hydration_zisk_evm::COUNTER_ADDRESS` in hydration-zisk).
    address public constant COUNTER = 0x0000000000000000000000000000000000000800;
    /// `increment() -> uint256`, returns the NEW count.
    bytes4 private constant SELECTOR_INCREMENT = 0xd09de08a;

    /// L2 `CrossChainProxy` of the L1 `Value` contract.
    address public immutable proxy;
    /// Completed relays.
    uint256 public relayed;
    /// Last count pushed to L1.
    uint256 public lastCount;
    /// L1's answer to the last push: whether its stored value changed.
    bool public lastChanged;

    event Relayed(uint256 count, bool changed, uint256 l1Value);

    constructor(address _proxy) {
        proxy = _proxy;
    }

    /// Bump the precompile, then relay the new count to L1 synchronously.
    function bumpAndRelay() external {
        (bool okInc, bytes memory counted) = COUNTER.call(abi.encodeWithSelector(SELECTOR_INCREMENT));
        require(okInc && counted.length == 32, "counter: increment failed");
        uint256 count = abi.decode(counted, (uint256));

        (bool ok, bytes memory ret) = proxy.call(abi.encodeWithSignature("setValue(uint256)", count));
        require(ok, "cross-chain setValue reverted");
        (bool changed, uint256 newValue) = abi.decode(ret, (bool, uint256));

        relayed++;
        lastCount = count;
        lastChanged = changed;
        emit Relayed(count, changed, newValue);
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title Callback for IBubblyPoolActions#swap
/// @notice Any contract that calls IBubblyPoolActions#swap must implement this interface
interface IBubblySwapCallback {
    /// @notice Called to `msg.sender` after executing a swap via IBubblyPool#swap.
    /// @dev In the implementation you must pay the pool tokens owed for the swap.
    /// The caller of this method must be checked to be a BubblyPool deployed by the canonical BubblyFactory.
    /// amount0Delta and amount1Delta can both be 0 if no tokens were swapped.

    /// @param amount1Delta The amount of token1 that was sent (negative) or must be received (positive) by the pool by
    /// the end of the swap. If positive, the callback must send that amount of token1 to the pool.
    /// @param data Any data passed through by the caller via the IBubblyPoolActions#swap call
    function BubblySwapCallback(
        bool isOpen,
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external;
}

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import '../interfaces/IBubblyPool.sol';
import './PoolAddress.sol';

/// @notice Provides validation for callbacks from Bubbly Pools
library CallbackValidation {
    /// @notice Returns the address of a valid Bubbly Pool
    /// @param factory The contract address of the Bubbly factory
    /// @param tokenA The contract address of either token0 or token1
    /// @param tokenB The contract address of the other token
    /// @param fee The fee collected upon every swap in the pool, denominated in hundredths of a bip
    /// @return pool The V3 pool contract address
    function verifyCallback(
        address quoteToken,
        address factory,
        address tokenA,
        address tokenB,
        uint24 fee
        
    ) internal view returns (IBubblyPool pool) {
        return verifyCallback(factory, PoolAddress.getPoolKey(tokenA, tokenB, fee , quoteToken));
    }

    /// @notice Returns the address of a valid Bubbly Pool
    /// @param factory The contract address of the Bubbly factory
    /// @param poolKey The identifying key of the Bubbly pool
    /// @return pool The Bubbly pool contract address
    function verifyCallback(address factory, PoolAddress.PoolKey memory poolKey)
        internal
        view
        returns (IBubblyPool pool)
    {
        pool = IBubblyPool(PoolAddress.computeAddress(factory, poolKey));
        require(msg.sender == address(pool),'valierr');
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.7.5;
pragma abicoder v2;

import '../interfaces/callback/IBubblySwapCallback.sol';

/// @title Router token swapping functionality
/// @notice Functions for swapping tokens via Bubbly
interface ICollateralPositionManager is IBubblySwapCallback {
    struct ExactInputSingleParams {
        address quoteToken;
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
        bool isOpen;
    }
    struct internalExactInputSingleParams {
        uint256 amountIn;
        address recipient;
        uint160 sqrtPriceLimitX96;
        bool isOpen;
        uint256 collateralamount;
        address quoteToken;
    }
    struct internalExactOutputSingleParams {
        uint256 amountOut;
        address recipient;
        uint160 sqrtPriceLimitX96;
        bool isOpen;
        uint256 collateralamount;
        address quoteToken;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another token
    /// @param params The parameters necessary for the swap, encoded as `ExactInputSingleParams` in calldata
    /// @return amountOut The amount of the received token
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }



    struct ExactOutputSingleParams {
        address quoteToken;
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
        bool isOpen;
    }

    /// @notice Swaps as little as possible of one token for `amountOut` of another token
    /// @param params The parameters necessary for the swap, encoded as `ExactOutputSingleParams` in calldata
    /// @return amountIn The amount of the input token
    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);

    struct ExactOutputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
    }
    
    function mintWithoutSwap(MintWithoutSwapParams calldata params) external ;
    struct MintWithoutSwapParams {
        address pool;
        uint256 amount0;
        uint256 amount1;
        uint256 amount0used;
        uint256 amount1used;
        address recipient;
        //uint256 deadline;
    }
    function getLongPosition(
        address pool,
        address user
    ) external view returns (uint256 ,uint256);

    function getShortPosition(
        address pool,
        address user
    ) external view returns (uint256 ,uint256);
}

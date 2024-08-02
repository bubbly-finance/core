// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import './libraries/SafeCast.sol';
import './libraries/TickMath.sol';
import './libraries/TickBitmap.sol';
import './interfaces/IBubblyPool.sol';
import './interfaces/callback/IBubblySwapCallback.sol';

import './interfaces/IQuoterV2.sol';
import './base/PeripheryImmutableState.sol';
import './libraries/Path.sol';
import './libraries/PoolAddress.sol';
import './libraries/CallbackValidation.sol';
import './libraries/PoolTicksCounter.sol';
import './libraries/LiquidityAmounts.sol';
import './libraries/SqrtPriceMathPartial.sol';
import 'hardhat/console.sol';
/// @title Provides quotes for swaps
/// @notice Allows getting the expected amount out or amount in for a given swap without executing the swap
/// @dev These functions are not gas efficient and should _not_ be called on chain. Instead, optimistically execute
/// the swap and check the amounts in the callback.
contract QuoterV2 is IQuoterV2, IBubblySwapCallback, PeripheryImmutableState {
    using Path for bytes;
    using SafeCast for uint256;
    using PoolTicksCounter for IBubblyPool;

    /// @dev Transient storage variable used to check a safety condition in exact output swaps.
    uint256 private amountOutCached;

    constructor(address _factory) PeripheryImmutableState(_factory) {}
    struct PreMintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
    }

    function getPool(
        address quoteToken,
        address tokenA,
        address tokenB,
        uint24 fee
    ) private view returns (IBubblyPool) {
        return IBubblyPool(PoolAddress.computeAddress(factory, PoolAddress.getPoolKey(tokenA, tokenB, fee, quoteToken)));
    }

    /// @inheritdoc IBubblySwapCallback
    function BubblySwapCallback(
        
        bool isOpen,
        int256 amount0Delta,
        int256 amount1Delta,
        bytes memory path
    ) external view override {
        require(amount1Delta > 0 || amount0Delta > 0 ); // swaps entirely within 0-liquidity regions are not supported
        (address tokenIn, address tokenOut, uint24 fee) = path.decodeFirstPool();
        //CallbackValidation.verifyCallback(factory, tokenIn, tokenOut, fee);
        address quoteToken = IBubblyPool(msg.sender).token1();
        (bool isExactInput, uint256 amountToPay, uint256 amountReceived) =
            amount0Delta > 0
                ? (tokenIn != quoteToken, uint256(amount0Delta), uint256(-amount1Delta))
                : (tokenOut != quoteToken, uint256(amount1Delta), uint256(-amount0Delta));

        IBubblyPool pool = getPool(quoteToken, tokenIn, tokenOut, fee);
        (uint160 sqrtPriceX96After, int24 tickAfter, , , , , ) = pool.slot0();

        if (isExactInput) {
            assembly {
                let ptr := mload(0x40)
                mstore(ptr, amountReceived)
                mstore(add(ptr, 0x20), sqrtPriceX96After)
                mstore(add(ptr, 0x40), tickAfter)
                revert(ptr, 96)
            }
        } else {
            // if the cache has been populated, ensure that the full output amount has been received

            //if (amountOutCached != 0) require(amountReceived == amountOutCached);
            assembly {
                let ptr := mload(0x40)
                mstore(ptr, amountToPay)
                mstore(add(ptr, 0x20), sqrtPriceX96After)
                mstore(add(ptr, 0x40), tickAfter)
                revert(ptr, 96)
            }
        }
    }

    /// @dev Parses a revert reason that should contain the numeric quote
    function parseRevertReason(bytes memory reason)
        private
        pure
        returns (
            uint256 amount,
            uint160 sqrtPriceX96After,
            int24 tickAfter
        )
    {
        if (reason.length != 96) {
            if (reason.length < 68) revert('Unexpected error');
            assembly {
                reason := add(reason, 0x04)
            }
            revert(abi.decode(reason, (string)));
        }
        return abi.decode(reason, (uint256, uint160, int24));
    }

    function handleRevert(
        bytes memory reason,
        IBubblyPool pool,
        uint256 gasEstimate
    )
        private
        view
        returns (
            uint256 amount,
            uint160 sqrtPriceX96After,
            //uint32 initializedTicksCrossed,
            uint256
        )
    {
        int24 tickBefore;
        int24 tickAfter;
        (, tickBefore, , , , , ) = pool.slot0();
        (amount, sqrtPriceX96After, tickAfter) = parseRevertReason(reason);

        //initializedTicksCrossed = pool.countInitializedTicksCrossed(tickBefore, tickAfter);

        return (amount, sqrtPriceX96After, gasEstimate);
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        public
        override
        returns (
            uint256 amountOut,
            uint160 sqrtPriceX96After,
            //uint32 initializedTicksCrossed,
            uint256 gasEstimate
        )
    {
        bool zeroForOne = params.tokenIn != params.quoteToken;
        IBubblyPool pool = getPool(params.quoteToken, params.tokenIn, params.tokenOut, params.fee);

        uint256 gasBefore = gasleft();
        try
            pool.swap(
                IBubblyPoolActions.SwapParams({
                    recipient : address(this), // address(0) might cause issues with some tokens
                    zeroForOne : zeroForOne,
                    amountSpecified : params.amountIn.toInt256(),
                    isOpen : params.isOpen,
                    collateralamount : uint256(0),
                    sqrtPriceLimitX96: params.sqrtPriceLimitX96 == 0
                    ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                    : params.sqrtPriceLimitX96
                }),
                abi.encodePacked(params.tokenIn, params.fee, params.tokenOut)
            )
        {} catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            
            
            return handleRevert(reason, pool, gasEstimate);
        }
    }


    function quoteExactOutputSingle(QuoteExactOutputSingleParams memory params)
        public
        override
        returns (
            uint256 amountIn,
            uint160 sqrtPriceX96After,
            //uint32 initializedTicksCrossed,
            uint256 gasEstimate
        )
    {
        bool zeroForOne = params.tokenIn != params.quoteToken;
        
        IBubblyPool pool = getPool(params.quoteToken ,params.tokenIn, params.tokenOut, params.fee);

        // if no price limit has been specified, cache the output amount for comparison in the swap callback
        if (params.sqrtPriceLimitX96 == 0) amountOutCached = params.amount;
        uint256 gasBefore = gasleft();
        try
            pool.swap(
                IBubblyPoolActions.SwapParams({
                    recipient : address(this), // address(0) might cause issues with some tokens
                    zeroForOne : zeroForOne,
                    amountSpecified : -params.amount.toInt256(),
                    isOpen : params.isOpen,
                    collateralamount : uint256(0),
                    sqrtPriceLimitX96: params.sqrtPriceLimitX96 == 0
                    ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                    : params.sqrtPriceLimitX96
                }),
                abi.encodePacked(params.tokenOut, params.fee, params.tokenIn)
            )
        {} catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            
            if (params.sqrtPriceLimitX96 == 0) delete amountOutCached; // clear cache
            return handleRevert(reason, pool, gasEstimate);
        }
    }
    function mintPreview(PreMintParams calldata params)
        view
        public
        returns (
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1,
            uint256 collateral
        )
    {
        IBubblyPool pool;
        PoolAddress.PoolKey memory poolKey =
            PoolAddress.PoolKey({token0: params.token0, token1: params.token1, fee: params.fee});
        pool = IBubblyPool(PoolAddress.computeAddress(factory,poolKey));
                // compute the liquidity amount
        
            (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
            uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(params.tickLower);
            uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(params.tickUpper);
        {
            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                sqrtRatioAX96,
                sqrtRatioBX96,
                params.amount0Desired,
                params.amount1Desired
            );
        }
        uint256 amount0inUSD;
        if ( sqrtPriceX96 < sqrtRatioAX96 ){
            amount0inUSD = SqrtPriceMathPartial.getAmount1Delta(
                sqrtRatioAX96,
                sqrtRatioBX96,
                liquidity,
                true
            );
        }else if(sqrtPriceX96 > sqrtRatioBX96){
            amount1 = SqrtPriceMathPartial.getAmount1Delta(
                sqrtRatioAX96,
                sqrtRatioBX96,
                liquidity,
                true
            );

        }
        else {
            //uint128 amount1liquidity = getLiquidityForAmount1(tickLowersqrtPriceX96, slot0.sqrtPriceX96, amount1);
            amount0inUSD = SqrtPriceMathPartial.getAmount1Delta(
                sqrtPriceX96,
                sqrtRatioBX96,
                liquidity,
                true
            );
            amount0 = SqrtPriceMathPartial.getAmount1Delta(
                sqrtPriceX96,
                sqrtRatioBX96,
                liquidity,
                true
            );
            amount1 = SqrtPriceMathPartial.getAmount1Delta(
                sqrtRatioAX96,
                sqrtPriceX96,
                liquidity,
                true
            );
        }
        collateral = amount0inUSD > amount1 ? amount0inUSD : amount1;
    }
}

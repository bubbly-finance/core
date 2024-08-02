// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;
import './interfaces/IBubblyPool.sol';

import './NoDelegateCall.sol';

import './libraries/LowGasSafeMath.sol';
import './libraries/SafeCast.sol';
import './libraries/Tick.sol';
import './libraries/TickBitmap.sol';
import './libraries/Position.sol';
import './libraries/Oracle.sol';

import './libraries/FullMath.sol';
import './libraries/FixedPoint128.sol';
import './libraries/FixedPoint96.sol';
import './libraries/TransferHelper.sol';
import './libraries/TickMath.sol';
import './libraries/LiquidityMath.sol';
import './libraries/SqrtPriceMath.sol';
import './libraries/SwapMath.sol';
import './libraries/LiquidityAmounts.sol';

import './interfaces/IBubblyPoolDeployer.sol';
import './interfaces/IBubblyFactory.sol';
import './interfaces/IERC20Minimal.sol';
import './interfaces/callback/IBubblyMintCallback.sol';
import './interfaces/callback/IBubblySwapCallback.sol';

import 'hardhat/console.sol';
contract BubblyPool is IBubblyPool, NoDelegateCall {
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;
    using Oracle for Oracle.Observation[65535];

    /// @inheritdoc IBubblyPoolImmutables
    address public immutable override factory;
    /// @inheritdoc IBubblyPoolImmutables
    address public immutable override token0;
    /// @inheritdoc IBubblyPoolImmutables
    address public immutable override token1;
    /// @inheritdoc IBubblyPoolImmutables
    uint24 public immutable override fee;

    /// @inheritdoc IBubblyPoolImmutables
    int24 public immutable override tickSpacing;

    /// @inheritdoc IBubblyPoolImmutables
    uint128 public immutable override maxLiquidityPerTick;

    struct Slot0 {
        // the current price
        uint160 sqrtPriceX96;
        // the current tick
        int24 tick;
        // the most-recently updated index of the observations array
        uint16 observationIndex;
        // the current maximum number of observations that are being stored
        uint16 observationCardinality;
        // the next maximum number of observations to store, triggered in observations.write
        uint16 observationCardinalityNext;
        // the current protocol fee as a percentage of the swap fee taken on withdrawal
        // represented as an integer denominator (1/x)%
        uint8 feeProtocol;
        // whether the pool is locked
        bool unlocked;
    }
    /// @inheritdoc IBubblyPoolState
    Slot0 public override slot0;

    /// @inheritdoc IBubblyPoolState
    
    uint256 public override feeGrowthGlobalX128;
    // accumulated protocol fees in token0/token1 units
    struct ProtocolFees {
        uint128 token0;
        uint128 token1;
    }
    /// @inheritdoc IBubblyPoolState
    ProtocolFees public override protocolFees;

    /// @inheritdoc IBubblyPoolState
    uint128 public override liquidity;

    /// @inheritdoc IBubblyPoolState
    mapping(int24 => Tick.Info) public override ticks;
    /// @inheritdoc IBubblyPoolState
    mapping(int16 => uint256) public override tickBitmap;
    /// @inheritdoc IBubblyPoolState
    mapping(bytes32 => Position.Info) public override positions;
    /// @inheritdoc IBubblyPoolState
    Oracle.Observation[65535] public override observations;
    bool public override deliveryflag ;
    address public CPM;
    address public NPM;
    address public Delivery;
    /// @dev Mutually exclusive reentrancy protection into the pool to/from a method. This method also prevents entrance
    /// to a function before the pool is initialized. The reentrancy guard is required throughout the contract because
    /// we use balance checks to determine the payment status of interactions such as mint, swap and flash.
    modifier lock() {
        require(slot0.unlocked, 'LOK');
        slot0.unlocked = false;
        _;
        slot0.unlocked = true;
    }

    /// @dev Prevents calling a function from anyone except the address returned by IBubblyFactory#owner()
    modifier onlyFactoryOwner() {
        require(msg.sender == IBubblyFactory(factory).owner());
        _;
    }

    modifier onlyNPM() {
        require(msg.sender == NPM);
        _;
    }

    constructor() {
        int24 _tickSpacing;
        (CPM ,NPM ,factory, token0, token1, fee, _tickSpacing) = IBubblyPoolDeployer(msg.sender).parameters();
        tickSpacing = _tickSpacing;

        maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(_tickSpacing);
    }
    function setDeliveryFlag() onlyFactoryOwner external {
        require(Delivery != address(0));
        deliveryflag = true;
        //approve collateral for delivery
        TransferHelper.safeApprove(token1, Delivery, balance1());
    }
    function setDelivery(address _Delivery) onlyFactoryOwner external {
        emit DeliverySet(_Delivery);
        Delivery = _Delivery;
    }
    /// @dev Common checks for valid tick inputs.
    function checkTicks(int24 tickLower, int24 tickUpper) private pure {
        require(tickLower < tickUpper, 'TLU');
        require(tickLower >= TickMath.MIN_TICK, 'TLM');
        require(tickUpper <= TickMath.MAX_TICK, 'TUM');
    }

    /// @dev Returns the block timestamp truncated to 32 bits, i.e. mod 2**32. This method is overridden in tests.
    function _blockTimestamp() internal view virtual returns (uint32) {
        return uint32(block.timestamp); // truncation is desired
    }

    /// @dev Get the pool's balance of token1
    /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
    /// check
    function balance1() private view returns (uint256) {
        (bool success, bytes memory data) =
            token1.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }


    /// @inheritdoc IBubblyPoolActions
    /// @dev not locked because it initializes unlocked
    function initialize(uint160 sqrtPriceX96) external override onlyFactoryOwner{
        require(slot0.sqrtPriceX96 == 0, 'AI');

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        (uint16 cardinality, uint16 cardinalityNext) = observations.initialize(_blockTimestamp());

        slot0 = Slot0({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            observationIndex: 0,
            observationCardinality: cardinality,
            observationCardinalityNext: cardinalityNext,
            feeProtocol: 0,
            unlocked: true
        });

        emit Initialize(sqrtPriceX96, tick);
    }

    struct ModifyPositionParams {
        // the address that owns the position
        address owner;
        // the lower and upper tick of the position
        int24 tickLower;
        int24 tickUpper;
        // any change in liquidity
        int128 liquidityDelta;
    }

    /// @dev Effect some changes to a position
    /// @param params the position details and the change to the position's liquidity to effect
    /// @return position a storage pointer referencing the position with the given owner and tick range
    /// @return amount0 the amount of token0 owed to the pool, negative if the pool should pay the recipient
    /// @return amount1 the amount of token1 owed to the pool, negative if the pool should pay the recipient
    function _modifyPosition(ModifyPositionParams memory params)
        private
        noDelegateCall
        returns (
            Position.Info storage position,
            int256 amount0,
            int256 amount1
        )
    {
        
        checkTicks(params.tickLower, params.tickUpper);
    
        Slot0 memory _slot0 = slot0; // SLOAD for gas optimization

        position = _updatePosition(
            params.owner,
            params.tickLower,
            params.tickUpper,
            params.liquidityDelta,
            _slot0.tick
        );

        if (params.liquidityDelta != 0) {
            if (_slot0.tick < params.tickLower) {
                // current tick is below the passed range; liquidity can only become in range by crossing from left to
                // right, when we'll need _more_ token0 (it's becoming more valuable) so user must provide it
                amount0 = SqrtPriceMath.getAmount0Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            } else if (_slot0.tick < params.tickUpper) {
                // current tick is inside the passed range
                uint128 liquidityBefore = liquidity; // SLOAD for gas optimization

                // write an oracle entry
                (slot0.observationIndex, slot0.observationCardinality) = observations.write(
                    _slot0.observationIndex,
                    _blockTimestamp(),
                    _slot0.tick,
                    liquidityBefore,
                    _slot0.observationCardinality,
                    _slot0.observationCardinalityNext
                );

                amount0 = SqrtPriceMath.getAmount0Delta(
                    _slot0.sqrtPriceX96,
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    _slot0.sqrtPriceX96,
                    params.liquidityDelta
                );

                liquidity = LiquidityMath.addDelta(liquidityBefore, params.liquidityDelta);
            } else {
                // current tick is above the passed range; liquidity can only become in range by crossing from right to
                // left, when we'll need _more_ token1 (it's becoming more valuable) so user must provide it
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            }
        }
        
    }

    /// @dev Gets and updates a position with the given liquidity delta
    /// @param owner the owner of the position
    /// @param tickLower the lower tick of the position's tick range
    /// @param tickUpper the upper tick of the position's tick range
    /// @param tick the current tick, passed to avoid sloads
    function _updatePosition(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta,
        int24 tick
    ) private returns (Position.Info storage position) {

        position = positions.get(owner, tickLower, tickUpper);

        uint256 _feeGrowthGlobalX128 = feeGrowthGlobalX128; // SLOAD for gas optimization
        
        // if we need to update the ticks, do it
        bool flippedLower;
        bool flippedUpper;
        if (liquidityDelta != 0) {
            uint32 time = _blockTimestamp();
            (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) =
                observations.observeSingle(
                    time,
                    0,
                    slot0.tick,
                    slot0.observationIndex,
                    liquidity,
                    slot0.observationCardinality
                );
            
            flippedLower = ticks.update(
                tickLower,
                tick,
                liquidityDelta,
                _feeGrowthGlobalX128,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                false,
                maxLiquidityPerTick
            );
            flippedUpper = ticks.update(
                tickUpper,
                tick,
                liquidityDelta,
                _feeGrowthGlobalX128,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                true,
                maxLiquidityPerTick
            );
            
            if (flippedLower) {
                tickBitmap.flipTick(tickLower, tickSpacing);
            }
            if (flippedUpper) {
                tickBitmap.flipTick(tickUpper, tickSpacing);
            }
        }

        uint256 feeGrowthInsideX128 = 
            ticks.getFeeGrowthInside(tickLower, tickUpper, tick, _feeGrowthGlobalX128);

        position.update(liquidityDelta, feeGrowthInsideX128);
        // clear any tick data that is no longer needed
        if (liquidityDelta < 0) {
            if (flippedLower) {
                ticks.clear(tickLower);
            }
            if (flippedUpper) {
                ticks.clear(tickUpper);
            }
        }
        
    }

    /// @inheritdoc IBubblyPoolActions
    /// @dev noDelegateCall is applied indirectly via _modifyPosition
    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external override lock onlyNPM returns (uint256 amount0, uint256 amount1,uint256 collateral) {
        require(!deliveryflag);
        require(amount > 0);

        (, int256 amount0Int, int256 amount1Int) =
            _modifyPosition(
                ModifyPositionParams({
                    owner: recipient,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: int256(amount).toInt128()
                })
            );

        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);
        uint256 amount0inUSD;  
        //stack too deep
        {
            uint160 tickUppersqrtPriceX96 = TickMath.getSqrtRatioAtTick(tickUpper);
            uint160 tickLowersqrtPriceX96 = TickMath.getSqrtRatioAtTick(tickLower);

            if ( slot0.sqrtPriceX96 < tickLowersqrtPriceX96 || slot0.sqrtPriceX96 >= tickUppersqrtPriceX96){
                amount0inUSD = SqrtPriceMath.getAmount1Delta(
                    tickLowersqrtPriceX96,
                    tickUppersqrtPriceX96,
                    amount,
                    true
                );
            }else {
                amount0inUSD = SqrtPriceMath.getAmount1Delta(
                    slot0.sqrtPriceX96,
                    tickUppersqrtPriceX96,
                    amount,
                    true
                );
            }
        }
        
        uint256 balance1Before;
        //choose max amount within token0 and token1
        collateral = amount0inUSD > amount1? amount0inUSD : amount1 ;
        
        if (collateral > 0) balance1Before = balance1();
        
        IBubblyMintCallback(msg.sender).BubblyMintCallback(amount0inUSD, amount1, data);
        if (collateral > 0) require(balance1Before.add(collateral) <= balance1(), 'M1');
        emit Mint(msg.sender, recipient, tickLower, tickUpper, amount, amount0, amount1,collateral);
    }

    /// @inheritdoc IBubblyPoolActions
    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amountRequested
    ) external override lock onlyNPM returns (uint128 amount) {
        // we don't need to checkTicks here, because invalid positions will never have non-zero tokensOwed{0,1}
        Position.Info storage position = positions.get(msg.sender, tickLower, tickUpper);
        
        amount = amountRequested > position.tokensOwed ? position.tokensOwed : amountRequested;

        if (amount > 0) {
            position.tokensOwed -= amount;
           
            TransferHelper.safeTransfer(token1, recipient, amount > balance1() ? balance1() : amount);
        }
        emit Collect(msg.sender, recipient, tickLower, tickUpper, amount);
    }

    /// @inheritdoc IBubblyPoolActions
    /// @dev noDelegateCall is applied indirectly via _modifyPosition

    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        burnParams calldata burnparams
    ) external override lock onlyNPM returns (uint256 amount0, uint256 amount1,uint256 amount0used, uint256 amount1used,uint256 amountowed) {
        
        (Position.Info storage position, int256 amount0Int, int256 amount1Int) =
            _modifyPosition(
                ModifyPositionParams({
                    owner: msg.sender,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: -int256(amount).toInt128()
                })
            );

        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);
        uint256 amount0inUSD;
        if(amount0 > 0){
            uint160 tickUpperSqrtPriceX96 =  TickMath.getSqrtRatioAtTick(tickUpper);
            uint160 tickLowerSqrtPriceX96 =  TickMath.getSqrtRatioAtTick(tickLower);
            
            if ( slot0.sqrtPriceX96 < tickLowerSqrtPriceX96 || slot0.sqrtPriceX96 >= tickUpperSqrtPriceX96){
                amount0inUSD = SqrtPriceMath.getAmount1Delta(tickLowerSqrtPriceX96, tickUpperSqrtPriceX96, amount, false);
            }else{
                amount0inUSD = SqrtPriceMath.getAmount1Delta(slot0.sqrtPriceX96, tickUpperSqrtPriceX96, amount, false);
            }
            
        }
        
        if(burnparams.liquidity > 0){
            
            amount0used =  FullMath.mulDivRoundingUp(uint256(amount), burnparams.lpamount0, uint256(burnparams.liquidity));
            amount1used =  FullMath.mulDivRoundingUp(uint256(amount), burnparams.lpamount1, uint256(burnparams.liquidity));

            uint256 amount1delta = amount1used > amount1 ? (amount1used - amount1) : (amount1 - amount1used);
      
            amountowed = FullMath.mulDiv(burnparams.lpcollateral,uint256(amount), uint256(burnparams.liquidity)) - amount1delta;

            if(amountowed > 0){
                position.tokensOwed += uint128(amountowed);
            }            
        }
        emit Burn(msg.sender, tickLower, tickUpper, amount, amount0, amount1, amountowed);
    }

    struct SwapCache {
        // the protocol fee for the input token
        uint8 feeProtocol;
        // liquidity at the beginning of the swap
        uint128 liquidityStart;
        // the timestamp of the current block
        uint32 blockTimestamp;
        // the current value of the tick accumulator, computed only if we cross an initialized tick
        int56 tickCumulative;
        // the current value of seconds per liquidity accumulator, computed only if we cross an initialized tick
        uint160 secondsPerLiquidityCumulativeX128;
        // whether we've computed and cached the above two accumulators
        bool computedLatestObservation;
    }

    // the top level state of the swap, the results of which are recorded in storage at the end
    struct SwapState {
        // the amount remaining to be swapped in/out of the input/output asset
        int256 amountSpecifiedRemaining;
        // the amount already swapped out/in of the output/input asset
        int256 amountCalculated;
        // current sqrt(price)
        uint160 sqrtPriceX96;
        // the tick associated with the current price
        int24 tick;
        // the global fee growth of the input token
        uint256 feeGrowthGlobalX128;
        // amount of input token paid as protocol fee
        uint128 protocolFee;
        // the current liquidity in range
        uint128 liquidity;
    }

    struct StepComputations {
        // the price at the beginning of the step
        uint160 sqrtPriceStartX96;
        // the next tick to swap to from the current tick in the swap direction
        int24 tickNext;
        // whether tickNext is initialized or not
        bool initialized;
        // sqrt(price) for the next tick (1/0)
        uint160 sqrtPriceNextX96;
        // how much is being swapped in in this step
        uint256 amountIn;
        // how much is being swapped out
        uint256 amountOut;
        // how much fee is being paid in
        uint256 feeAmount;
    }

    /// @inheritdoc IBubblyPoolActions
    function swap(
        SwapParams calldata swapParams,
        bytes calldata data
    ) external override noDelegateCall returns (int256 amount0, int256 amount1, uint256 totalFeeInQuoteToken ) {
        require(!deliveryflag);
        require(swapParams.amountSpecified != 0, 'AS');
        Slot0 memory slot0Start = slot0;
        require(slot0Start.unlocked, 'LOK');
        require(
            swapParams.zeroForOne
                ? swapParams.sqrtPriceLimitX96 < slot0Start.sqrtPriceX96 && swapParams.sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO
                : swapParams.sqrtPriceLimitX96 > slot0Start.sqrtPriceX96 && swapParams.sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO,
            'SPL'
        );

        slot0.unlocked = false;

        SwapCache memory cache =
            SwapCache({
                liquidityStart: liquidity,
                blockTimestamp: _blockTimestamp(),
                feeProtocol: swapParams.zeroForOne ? (slot0Start.feeProtocol % 16) : (slot0Start.feeProtocol >> 4),
                secondsPerLiquidityCumulativeX128: 0,
                tickCumulative: 0,
                computedLatestObservation: false
            });

        bool exactInput = swapParams.amountSpecified > 0;

        SwapState memory state =
            SwapState({
                amountSpecifiedRemaining: swapParams.amountSpecified,
                amountCalculated: 0,
                sqrtPriceX96: slot0Start.sqrtPriceX96,
                tick: slot0Start.tick,
                feeGrowthGlobalX128: feeGrowthGlobalX128,
                protocolFee: 0,
                liquidity: cache.liquidityStart
            });
        
        // continue swapping as long as we haven't used the entire input/output and haven't reached the price limit
        uint256 totalFeeInBaseToken;
        while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != swapParams.sqrtPriceLimitX96) {
            StepComputations memory step;
            
            step.sqrtPriceStartX96 = state.sqrtPriceX96;
            
            (step.tickNext, step.initialized) = tickBitmap.nextInitializedTickWithinOneWord(
                state.tick,
                tickSpacing,
                swapParams.zeroForOne
            );

            // ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds
            if (step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            } else if (step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            // get the price for the next tick
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);
            
            // compute values to swap to the target tick, price limit, or point where input/output amount is exhausted
            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                (swapParams.zeroForOne ? step.sqrtPriceNextX96 < swapParams.sqrtPriceLimitX96 : step.sqrtPriceNextX96 > swapParams.sqrtPriceLimitX96)
                    ? swapParams.sqrtPriceLimitX96
                    : step.sqrtPriceNextX96,
                state.liquidity,
                state.amountSpecifiedRemaining,
                fee
            );

            if (exactInput) {
                state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount).toInt256();
                state.amountCalculated = state.amountCalculated.sub(step.amountOut.toInt256());
            } else {
                state.amountSpecifiedRemaining += step.amountOut.toInt256();
                state.amountCalculated = state.amountCalculated.add((step.amountIn + step.feeAmount).toInt256());
            }
            
            if(swapParams.zeroForOne && step.feeAmount > 0){   
                
                uint160 sqrtRatioAX96 = step.sqrtPriceStartX96;
                uint160 sqrtRatioBX96 = state.sqrtPriceX96;
                if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
                uint128 feeliquidity = LiquidityAmounts.getLiquidityForAmount0(sqrtRatioAX96, sqrtRatioBX96, step.feeAmount);
                uint256 feeInQuoteToken = SqrtPriceMath.getAmount1Delta(
                    sqrtRatioAX96,
                    sqrtRatioBX96,
                    feeliquidity,
                    true
                );
                totalFeeInBaseToken += step.feeAmount;
                step.feeAmount = feeInQuoteToken;
                totalFeeInQuoteToken += feeInQuoteToken;
                
            }
            if(!swapParams.zeroForOne && step.feeAmount > 0) totalFeeInQuoteToken += step.feeAmount;

            // if the protocol fee is on, calculate how much is owed, decrement feeAmount, and increment protocolFee
            if (cache.feeProtocol > 0) {
                uint256 delta = step.feeAmount / cache.feeProtocol;
                step.feeAmount -= delta;
                state.protocolFee += uint128(delta);
            }

            // update global fee tracker
            
            if (state.liquidity > 0)
                state.feeGrowthGlobalX128 += FullMath.mulDiv(step.feeAmount, FixedPoint128.Q128, state.liquidity);
            
            // shift tick if we reached the next price
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // if the tick is initialized, run the tick transition
                if (step.initialized) {
                    // check for the placeholder value, which we replace with the actual value the first time the swap
                    // crosses an initialized tick
                    if (!cache.computedLatestObservation) {
                        (cache.tickCumulative, cache.secondsPerLiquidityCumulativeX128) = observations.observeSingle(
                            cache.blockTimestamp,
                            0,
                            slot0Start.tick,
                            slot0Start.observationIndex,
                            cache.liquidityStart,
                            slot0Start.observationCardinality
                        );
                        cache.computedLatestObservation = true;
                    }
                    int128 liquidityNet =
                        ticks.cross(
                            step.tickNext,
                            state.feeGrowthGlobalX128,
                            cache.secondsPerLiquidityCumulativeX128,
                            cache.tickCumulative,
                            cache.blockTimestamp
                        );
                    // if we're moving leftward, we interpret liquidityNet as the opposite sign
                    // safe because liquidityNet cannot be type(int128).min
                    if (swapParams.zeroForOne) liquidityNet = -liquidityNet;

                    state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet);
                }

                state.tick = swapParams.zeroForOne ? step.tickNext - 1 : step.tickNext;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }


        // update tick and write an oracle entry if the tick change
        if (state.tick != slot0Start.tick) {
            (uint16 observationIndex, uint16 observationCardinality) =
                observations.write(
                    slot0Start.observationIndex,
                    cache.blockTimestamp,
                    slot0Start.tick,
                    cache.liquidityStart,
                    slot0Start.observationCardinality,
                    slot0Start.observationCardinalityNext
                );
            (slot0.sqrtPriceX96, slot0.tick, slot0.observationIndex, slot0.observationCardinality) = (
                state.sqrtPriceX96,
                state.tick,
                observationIndex,
                observationCardinality
            );
        } else {
            // otherwise just update the price
            slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }

        // update liquidity if it changed
        if (cache.liquidityStart != state.liquidity) liquidity = state.liquidity;

        // update fee growth global and, if necessary, protocol fees
        // overflow is acceptable, protocol has to withdraw before it hits type(uint128).max fees
        
        feeGrowthGlobalX128 = state.feeGrowthGlobalX128;
        if (state.protocolFee > 0) protocolFees.token1 += state.protocolFee;
   

        (amount0, amount1) = swapParams.zeroForOne == exactInput
            ? (swapParams.amountSpecified - state.amountSpecifiedRemaining, state.amountCalculated)
            : (state.amountCalculated, swapParams.amountSpecified - state.amountSpecifiedRemaining);

        // do the transfers and collect payment
        if (swapParams.zeroForOne) {
            if(!swapParams.isOpen){
                //0->1 close long position 
                //sub swap fee    
                if (amount1 < 0) {
                    amount1 = amount1 + int256(totalFeeInQuoteToken);
                    require(amount1 < 0);
                    TransferHelper.safeTransfer(token1, swapParams.recipient, uint256(-amount1));
                }
                //for quoter        

                IBubblySwapCallback(msg.sender).BubblySwapCallback(swapParams.isOpen, amount0, amount1, data);
            }
            else{
                //open short position
                uint256 balance1Before = balance1();
                //add swap fee
                amount1 = amount1 - int256(totalFeeInQuoteToken);       
                amount0 = amount0 - int256(totalFeeInBaseToken);
                IBubblySwapCallback(msg.sender).BubblySwapCallback(swapParams.isOpen, amount0, amount1, data);
                require(balance1Before.add(uint256(-amount1)) <= balance1(), 'IIA');
            }

        } 
        else {
            if(!swapParams.isOpen){
                //close short position 
                //ensure collateralamount > 0 ,confirm by periphery

                uint256 amountToPay = 2 * swapParams.collateralamount > uint256(amount1).sub(totalFeeInQuoteToken) ? (2 * swapParams.collateralamount).sub(uint256(amount1).sub(totalFeeInQuoteToken)):0;
                if (amount1 > 0) TransferHelper.safeTransfer(token1, swapParams.recipient, amountToPay - totalFeeInQuoteToken); 

                //for quoter       
                IBubblySwapCallback(msg.sender).BubblySwapCallback(swapParams.isOpen, amount0, amount1, data);
            }
            else{
                //1->0 open long position
                //add fee for position record
                
                uint256 balance1Before = balance1();
                IBubblySwapCallback(msg.sender).BubblySwapCallback(swapParams.isOpen, amount0, amount1, data);
                require(balance1Before.add(uint256(amount1)) <= balance1(), 'IIA');
            }

        }
        //for quoter ,change the position of access control
        require(msg.sender == CPM ,'NCPM');
        emit Swap(swapParams.recipient, amount0, amount1, state.sqrtPriceX96, state.liquidity, state.tick,totalFeeInQuoteToken);
        slot0.unlocked = true;
    }


    /// @inheritdoc IBubblyPoolOwnerActions
    function setFeeProtocol(uint8 feeProtocol0, uint8 feeProtocol1) external override lock onlyFactoryOwner {
        require(
            (feeProtocol0 == 0 || (feeProtocol0 >= 4 && feeProtocol0 <= 10)) &&
                (feeProtocol1 == 0 || (feeProtocol1 >= 4 && feeProtocol1 <= 10))
        );
        uint8 feeProtocolOld = slot0.feeProtocol;
        slot0.feeProtocol = feeProtocol0 + (feeProtocol1 << 4);
        emit SetFeeProtocol(feeProtocolOld % 16, feeProtocolOld >> 4, feeProtocol0, feeProtocol1);
    }

    /// @inheritdoc IBubblyPoolOwnerActions
    function collectProtocol(
        address recipient,
        uint128 amountRequested
    ) external override lock onlyFactoryOwner returns (uint128 amount) {
        amount = amountRequested > protocolFees.token1 ? protocolFees.token1 : amountRequested;

        if (amount > 0) {
            if (amount == protocolFees.token1) amount--; // ensure that the slot is not cleared, for gas savings
            protocolFees.token1 -= amount;
            TransferHelper.safeTransfer(token1, recipient, amount);
        }

        emit CollectProtocol(msg.sender, recipient, amount);
    }


}

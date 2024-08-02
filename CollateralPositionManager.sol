// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import './libraries/SafeCast.sol';
import './libraries/TickMath.sol';
import './interfaces/IBubblyPool.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';

import './interfaces/ICollateralPositionManager.sol';
import './interfaces/IBubblyFactory.sol';
import './base/PeripheryImmutableState.sol';
import './base/PeripheryValidation.sol';
import './base/PeripheryPaymentsWithFee.sol';
import './base/Multicall.sol';
import './base/SelfPermit.sol';
import './libraries/Path.sol';
import './libraries/PoolAddress.sol';
import './libraries/CallbackValidation.sol';
import './libraries/FullMath.sol';

import 'hardhat/console.sol';

/// @title Bubbly CollateralPositionManager

contract CollateralPositionManager is
    ICollateralPositionManager,
    PeripheryImmutableState,
    PeripheryValidation,
    PeripheryPayments,
    Multicall,
    SelfPermit
{
    event updatePosition(address indexed recipient, address indexed pool,uint256 amount0, uint256 amount1, bool long,bool isOpen);
    struct CollateralPosition {
        uint256 token0amount;
        uint256 token1amount;
    }

    using Path for bytes;
    using SafeCast for uint256;
    using SafeMath for uint256;
    
    /// @dev IDs of pools assigned by this contract
    mapping(address => uint80) private _poolIds;
    // IDs -> Poolkey
    /// @dev Pool keys by pool ID, to save on SSTOREs for position data
    mapping(uint80 => PoolAddress.PoolKey) private _poolIdToPoolKey;
    /// @dev The collateral position data
    mapping(address => mapping(address => CollateralPosition)) private _longpositions;
    mapping(address => mapping(address => CollateralPosition)) private _shortpositions;

    /// @dev Used as the placeholder value for amountInCached, because the computed amount in for an exact output swap
    /// can never actually be this value
    uint256 private constant DEFAULT_AMOUNT_IN_CACHED = type(uint256).max;

    /// @dev Transient storage variable used for returning the computed amount in for an exact output swap.
    uint256 private amountInCached = DEFAULT_AMOUNT_IN_CACHED;
    address public NPM;
    //pool -> admin
    mapping (address => address) public EmergencyAdmin;
    mapping (address => bool) public EmergencyPause;
    event SetEmergencyAdmin(address indexed pool, address admin);
    event SetEmergencyPause(address indexed pool, bool flag);
    struct UpdatePositionParams{
        bool isOpen;
        bool long;
        address recipient;
        address pool;
        uint256 amount0;
        uint256 amount1;
    }
    constructor(address _factory) PeripheryImmutableState(_factory) {
        
    }
    modifier onlyFactoryOwnerOrAdmin(address pool) {
        require(msg.sender == IBubblyFactory(factory).owner() || msg.sender == EmergencyAdmin[pool] );
        _;
    }
    modifier onlyNPM() {
        require(msg.sender == NPM);
        _;
    }
    modifier onlyFactoryOwner() {
        require(msg.sender == IBubblyFactory(factory).owner());
        _;
    }
    function setNPM(address npm) external onlyFactoryOwner {
        NPM = npm;
    }

    /// @dev Returns the pool for the given token pair and fee. The pool contract may or may not exist.
    function getPool(
        address quoteToken,
        address tokenA,
        address tokenB,
        uint24 fee
    ) private view returns (IBubblyPool) {
        return IBubblyPool(PoolAddress.computeAddress(factory,PoolAddress.getPoolKey(tokenA, tokenB, fee, quoteToken)));
    }
    //position information getter
    
    function getLongPosition(
        address pool,
        address user
    ) public view override returns (uint256 ,uint256) {
        return (_longpositions[pool][user].token0amount, _longpositions[pool][user].token1amount);
    }
    function getShortPosition(
        address pool,
        address user
    ) public view override returns (uint256 ,uint256) {
        return (_shortpositions[pool][user].token0amount, _shortpositions[pool][user].token1amount);
    }
    struct SwapCallbackData {
        bytes path;
        address payer;
    }

    /// @inheritdoc IBubblySwapCallback
    function BubblySwapCallback(
        bool isOpen,
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata _data
    ) external override {
        //callback always pay quoteToken
        require(amount1Delta != 0); // swaps entirely within 0-liquidity regions are not supported
        SwapCallbackData memory data = abi.decode(_data, (SwapCallbackData));
        (address tokenIn, address tokenOut, uint24 fee) = data.path.decodeFirstPool();
        address quoteToken  = IBubblyPool(msg.sender).token1();
        CallbackValidation.verifyCallback(quoteToken, factory, tokenIn, tokenOut, fee);
        
        uint256 amountToPay =
            amount1Delta > 0
                ?  uint256(amount1Delta)
                : uint256(-amount1Delta);

        if (isOpen){
            pay(quoteToken, data.payer, msg.sender, amountToPay);            
        }
    }

    /// @dev Performs a single exact input swap
    function exactInputInternal(
        internalExactInputSingleParams memory params,
        SwapCallbackData memory data
    ) private returns (uint256 amountOut) {
        // allow swapping to the router address with address 0
        if (params.recipient == address(0)) params.recipient = address(this);

        (address tokenIn, address tokenOut, uint24 fee) = data.path.decodeFirstPool();
        address pool = address(getPool(params.quoteToken, tokenIn, tokenOut, fee));
        require(EmergencyPause[pool] == false);
        bool zeroForOne = tokenIn != params.quoteToken;
        if(params.isOpen == false){
            //tokenIn is always basetoken when close a position
            require(tokenIn != params.quoteToken); 
        }
        require(params.quoteToken == IBubblyPool(pool).token1());
        (int256 amount0, int256 amount1 ,uint256 totalFeeInQuoteToken) =
            getPool(params.quoteToken, tokenIn, tokenOut, fee).swap(
                IBubblyPoolActions.SwapParams({
                    recipient : params.recipient,
                    zeroForOne : zeroForOne,
                    amountSpecified : params.amountIn.toInt256(),
                    isOpen : params.isOpen,
                    collateralamount : params.collateralamount,
                    sqrtPriceLimitX96 : params.sqrtPriceLimitX96 == 0
                    ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                    : params.sqrtPriceLimitX96
                }),
                abi.encode(data)
            );
        //long or short
        bool long = params.isOpen != zeroForOne;
        
        //only happened in exactinput , close a long position 
        int256 amount1OnPosition;
        if(!params.isOpen && zeroForOne){
            amount1OnPosition = amount1 - int256(totalFeeInQuoteToken);
        }
        else{
            amount1OnPosition = amount1 > 0 ? amount1 - int256(totalFeeInQuoteToken) : amount1 + int256(totalFeeInQuoteToken) ;
        }
        
        _updateposition(
            UpdatePositionParams({
                isOpen : params.isOpen,
                long : long,
                recipient : params.recipient,
                pool : pool,
                amount0 : uint256((amount0 > 0) ? amount0 : (-amount0)) ,
                amount1 : uint256((amount1OnPosition > 0)? amount1OnPosition:(-amount1OnPosition))
            })
        );
        
        return uint256(-(zeroForOne ? amount1 : amount0));
    }

    /// @inheritdoc ICollateralPositionManager
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 amountOut)
    {
        
        require(params.recipient == msg.sender);
        uint256 collateralamount = _getcollateral(params.isOpen, params.tokenIn != params.quoteToken, address(getPool(params.quoteToken, params.tokenIn, params.tokenOut, params.fee)), params.recipient, params.amountIn);
        amountOut = exactInputInternal(internalExactInputSingleParams({
            amountIn : params.amountIn,
            recipient : params.recipient,
            sqrtPriceLimitX96: params.sqrtPriceLimitX96,
            isOpen: params.isOpen,
            collateralamount : collateralamount,
            quoteToken : params.quoteToken
            }),
            SwapCallbackData({path: abi.encodePacked(params.tokenIn, params.fee, params.tokenOut), payer: msg.sender})
        );
        require(amountOut >= params.amountOutMinimum, 'Too little received');
    }
    function _getcollateral(bool isOpen, bool zeroForOne, address pool, address recipient, uint256 amount) internal view returns (uint256 collateralamount){
        if (!isOpen){
            CollateralPosition memory position = _checkposition(isOpen != zeroForOne, recipient, pool); 
            collateralamount = FullMath.mulDiv(amount, position.token1amount, position.token0amount);
        }
    }
    /// @dev Performs a single exact output swap
    function exactOutputInternal(
        internalExactOutputSingleParams memory params,
        SwapCallbackData memory data
    ) private returns (uint256 amountIn) {

        require(params.recipient == msg.sender);
        (address tokenOut, address tokenIn, uint24 fee) = data.path.decodeFirstPool();
        address pool = address(getPool(params.quoteToken, tokenIn, tokenOut, fee));
        require(EmergencyPause[pool] == false);
        bool zeroForOne = tokenIn != params.quoteToken;
        if(params.isOpen == false){
            //tokenIn is always quotetoken when close a position
            require(tokenIn == params.quoteToken); 
        }
        require(params.quoteToken == IBubblyPool(pool).token1());
        (int256 amount0Delta, int256 amount1Delta, uint256 totalFeeInQuoteToken) =
            getPool(params.quoteToken, tokenIn, tokenOut, fee).swap(
                IBubblyPoolActions.SwapParams({
                    recipient : params.recipient,
                    zeroForOne : zeroForOne,
                    amountSpecified : -params.amountOut.toInt256(),
                    isOpen : params.isOpen,
                    collateralamount : params.collateralamount,
                    sqrtPriceLimitX96: params.sqrtPriceLimitX96 == 0
                    ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                    : params.sqrtPriceLimitX96
                }),
                abi.encode(data)
            );
        //stack too deep
        {
            uint256 amountOutReceived;
            (amountIn, amountOutReceived) = zeroForOne
                ? (uint256(amount0Delta), uint256(-amount1Delta))
                : (uint256(amount1Delta), uint256(-amount0Delta));
            
            // it's technically possible to not receive the full output amount,
            // so if no price limit has been specified, require this possibility away
            
            if (params.sqrtPriceLimitX96 == 0 && tokenOut == params.quoteToken){
                require(amountOutReceived == params.amountOut + totalFeeInQuoteToken);
            }
            else if (params.sqrtPriceLimitX96 == 0  && tokenOut != params.quoteToken){
                require(amountOutReceived == params.amountOut);
            }     
        }
        
        bool long = params.isOpen != zeroForOne;
        int256 amount1OnPosition = amount1Delta > 0 ? amount1Delta - int256(totalFeeInQuoteToken) : amount1Delta + int256(totalFeeInQuoteToken) ;
        _updateposition(
            UpdatePositionParams({
                isOpen : params.isOpen,
                long : long,
                recipient : params.recipient,
                pool : pool,
                amount0 : uint256((amount0Delta > 0) ? amount0Delta : (-amount0Delta)),
                amount1 : uint256((amount1OnPosition > 0) ? amount1OnPosition : (-amount1OnPosition))
            })
        );
    }

    /// @inheritdoc ICollateralPositionManager
    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 amountIn)
    {
        // avoid an SLOAD by using the swap return data
        uint256 collateralamount = _getcollateral(params.isOpen, params.tokenIn != params.quoteToken, address(getPool(params.quoteToken, params.tokenIn, params.tokenOut, params.fee)), params.recipient, params.amountOut);
        amountIn = exactOutputInternal(internalExactOutputSingleParams({
            amountOut : params.amountOut,
            recipient : params.recipient,
            sqrtPriceLimitX96 : params.sqrtPriceLimitX96,
            isOpen : params.isOpen,
            collateralamount : collateralamount,
            quoteToken : params.quoteToken
            }),
            SwapCallbackData({path: abi.encodePacked(params.tokenOut, params.fee, params.tokenIn), payer: msg.sender})
        );

        require(amountIn <= params.amountInMaximum, 'Too much requested');

    }

    function _checkposition(bool long, address recipient ,address pool ) internal view returns (CollateralPosition memory oldposition){
        if (long){
            oldposition = _longpositions[pool][recipient];
        } 
        else{
            oldposition = _shortpositions[pool][recipient];
        }
    }

    function _updateposition(UpdatePositionParams memory params) internal{
        CollateralPosition memory oldposition = _checkposition(params.long, params.recipient, params.pool);
        CollateralPosition memory newposition;
        if(params.isOpen){
            newposition = CollateralPosition({
                                                token0amount:oldposition.token0amount.add(params.amount0) ,
                                                token1amount:oldposition.token1amount.add(params.amount1) 
                                                    }); 
        }else{
            require(oldposition.token0amount >= params.amount0,'pne');
            uint256 token1left = FullMath.mulDiv(oldposition.token1amount, (oldposition.token0amount - params.amount0), oldposition.token0amount);
            newposition = CollateralPosition({
                                                token0amount:oldposition.token0amount.sub(params.amount0) ,
                                                token1amount:(oldposition.token0amount == params.amount0) ? 0 : token1left 
                                                    }); 
        }

        if (params.long) {
            _longpositions[params.pool][params.recipient] = newposition;
        }
        else{
            _shortpositions[params.pool][params.recipient] = newposition;
        }        
        
        emit updatePosition(params.recipient, params.pool, newposition.token0amount, newposition.token1amount, params.long, params.isOpen);
    }
   
    function mintWithoutSwap(MintWithoutSwapParams calldata params) onlyNPM override external
    {
        require(EmergencyPause[params.pool] == false);
        bool long = params.amount1 < params.amount1used;
        uint256 amount1delta = params.amount1 > params.amount1used? (params.amount1-params.amount1used): (params.amount1used-params.amount1);
        uint256 amount0delta = params.amount0 > params.amount0used? (params.amount0-params.amount0used): (params.amount0used-params.amount0);
        //always open a position
        _updateposition(
            UpdatePositionParams({
                isOpen : true,
                long : long,
                recipient : params.recipient,
                pool : params.pool,
                amount0 : amount0delta,
                amount1 : amount1delta
            })
        );
    }
    function setEmergencyAdmin (address _pool ,address _admin) external onlyFactoryOwnerOrAdmin(_pool) {
        
        EmergencyAdmin[_pool] = _admin;
        emit SetEmergencyAdmin(_pool, _admin);
    }

    function setEmergencyPause (address _pool ,bool _flag ) external onlyFactoryOwnerOrAdmin(_pool) {
        EmergencyPause[_pool] = _flag;
        emit SetEmergencyPause(_pool, _flag);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import './interfaces/IBubblyFactory.sol';

import './BubblyPoolDeployer.sol';
import './NoDelegateCall.sol';

import './BubblyPool.sol';

/// @title Canonical BubblyFactory 
/// @notice Deploys Bubblypools and manages ownership and control over pool protocol fees
contract BubblyFactory is IBubblyFactory, BubblyPoolDeployer, NoDelegateCall {
    /// @inheritdoc IBubblyFactory
    address public override owner;

    /// @inheritdoc IBubblyFactory
    mapping(uint24 => int24) public override feeAmountTickSpacing;
    /// @inheritdoc IBubblyFactory
    mapping(address => mapping(address => mapping(uint24 => address))) public override getPool;

    address public CPM;
    address public NPM;
    constructor() {
        owner = msg.sender;
        
        emit OwnerChanged(address(0), msg.sender);

        feeAmountTickSpacing[500] = 10;
        emit FeeAmountEnabled(500, 10);
        feeAmountTickSpacing[3000] = 60;
        emit FeeAmountEnabled(3000, 60);
        feeAmountTickSpacing[10000] = 200;
        emit FeeAmountEnabled(10000, 200);
    }

    /// @inheritdoc IBubblyFactory
    function createPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external override noDelegateCall returns (address pool) {
        require(msg.sender == owner);
        //check NPM&&CPM initialized
        require(NPM != address(0),'NPM0');
        require(CPM != address(0),'CPM0');
        require(tokenA != tokenB);
        //token1 always quoteToken
        (address token0, address token1) =  (tokenA, tokenB) ;
        require(token0 != address(0));
        int24 tickSpacing = feeAmountTickSpacing[fee];
        require(tickSpacing != 0);
        require(getPool[token0][token1][fee] == address(0));
        pool = deploy(CPM, NPM, address(this), token0, token1, fee, tickSpacing);
        getPool[token0][token1][fee] = pool;
        // populate mapping in the reverse direction, deliberate choice to avoid the cost of comparing addresses
        getPool[token1][token0][fee] = pool;
        emit PoolCreated(token0, token1, fee, tickSpacing, pool);
    }

    /// @inheritdoc IBubblyFactory
    function setOwner(address _owner) external override {
        require(msg.sender == owner);
        emit OwnerChanged(owner, _owner);
        owner = _owner;
    }

    function setCPM(address _CPM) external {
        require(msg.sender == owner);
        emit CPMSet(_CPM);
        CPM = _CPM;
    }

    function setNPM(address _NPM) external {
        require(msg.sender == owner);
        emit NPMSet(_NPM);
        NPM = _NPM;
    }

    /// @inheritdoc IBubblyFactory
    function enableFeeAmount(uint24 fee, int24 tickSpacing) public override {
        require(msg.sender == owner);
        require(fee < 1000000);
        // tick spacing is capped at 16384 to prevent the situation where tickSpacing is so large that
        // TickBitmap#nextInitializedTickWithinOneWord overflows int24 container from a valid tick
        // 16384 ticks represents a >5x price change with ticks of 1 bips
        require(tickSpacing > 0 && tickSpacing < 16384);
        require(feeAmountTickSpacing[fee] == 0);

        feeAmountTickSpacing[fee] = tickSpacing;
        emit FeeAmountEnabled(fee, tickSpacing);
    }
}

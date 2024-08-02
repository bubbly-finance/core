// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import './interfaces/IBubblyPool.sol';
import './libraries/FixedPoint128.sol';
import './libraries/FullMath.sol';
import './interfaces/ICollateralPositionManager.sol';
import './interfaces/IBubblyFactory.sol';
import './interfaces/INonfungiblePositionManager.sol';
import './interfaces/INonfungibleTokenPositionDescriptor.sol';
import './libraries/PositionKey.sol';
import './libraries/PoolAddress.sol';
import './base/LiquidityManagement.sol';
import './base/PeripheryImmutableState.sol';
import './base/Multicall.sol';
import './base/ERC721Permit.sol';
import './base/PeripheryValidation.sol';
import './base/SelfPermit.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';

import 'hardhat/console.sol';

/// @title NFT positions
/// @notice Wraps Bubbly positions in the ERC721 non-fungible token interface
contract NonfungiblePositionManager is
    INonfungiblePositionManager,
    Multicall,
    ERC721Permit,
    PeripheryImmutableState,
    LiquidityManagement,
    PeripheryValidation,
    SelfPermit
{
    // details about the bubbly position
    struct Position {
        // the nonce for permits
        uint96 nonce;
        // the address that is approved for spending this token
        address operator;
        // the ID of the pool with which this token is connected
        uint80 poolId;
        // the tick range of the position
        int24 tickLower;
        int24 tickUpper;
        // the liquidity of the position
        uint128 liquidity;
        // the fee growth of the aggregate position as of the last action on the individual position
        uint256 feeGrowthInsideLastX128;
        
        // how many uncollected tokens are owed to the position, as of the last computation
        uint128 tokensOwed;
        
        //for removeliquidity calculation
        uint256 lpamount0;
        uint256 lpamount1;
        uint256 lpcollateral;
    }

    using SafeMath for uint256;
    /// @dev IDs of pools assigned by this contract
    mapping(address => uint80) private _poolIds;

    /// @dev Pool keys by pool ID, to save on SSTOREs for position data
    mapping(uint80 => PoolAddress.PoolKey) private _poolIdToPoolKey;

    /// @dev The token ID position data
    mapping(uint256 => Position) private _positions;

    /// @dev The ID of the next token that will be minted. Skips 0
    uint176 private _nextId = 1;
    /// @dev The ID of the next pool that is used for the first time. Skips 0
    uint80 private _nextPoolId = 1;

    /// @dev The address of the token descriptor contract, which handles generating token URIs for position tokens
    address private immutable _tokenDescriptor;
    // initialize in constructor
    address public immutable CPM;
    //pool -> admin
    mapping (address => address) public EmergencyAdmin;
    mapping (address => bool) public EmergencyPause;
    event SetEmergencyAdmin(address indexed pool, address admin);
    event SetEmergencyPause(address indexed pool, bool flag);
    constructor(
        address _factory,
        address _tokenDescriptor_,
        address _CPM
    ) ERC721Permit('Bubbly Positions NFT', 'BUL-POS', '1') PeripheryImmutableState(_factory) {
        _tokenDescriptor = _tokenDescriptor_;
        CPM = _CPM;
    }

    modifier onlyFactoryOwner() {
        require(msg.sender == IBubblyFactory(factory).owner());
        _;
    }

    modifier onlyFactoryOwnerOrAdmin(address pool) {
        require(msg.sender == IBubblyFactory(factory).owner() || msg.sender == EmergencyAdmin[pool] );
        _;
    }
    /// @inheritdoc INonfungiblePositionManager
    function positions(uint256 tokenId)
        external
        view
        override
        returns (
            uint96 nonce,
            address operator,
            address pool,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInsideLastX128,
            uint128 tokensOwed,
            uint256 lpamount0,
            uint256 lpamount1,
            uint256 lpcollateral
        )
    {
        Position memory position = _positions[tokenId];
        require(position.poolId != 0, 'IID');
        PoolAddress.PoolKey memory poolKey = _poolIdToPoolKey[position.poolId];
        pool = address(IBubblyPool(PoolAddress.computeAddress(factory, poolKey)));
        return (
            position.nonce,
            position.operator,
            pool,
            position.tickLower,
            position.tickUpper,
            position.liquidity,
            position.feeGrowthInsideLastX128,
            position.tokensOwed,
            position.lpamount0,
            position.lpamount1,
            position.lpcollateral
        );
    }

    /// @dev Caches a pool key
    function cachePoolKey(address pool, PoolAddress.PoolKey memory poolKey) private returns (uint80 poolId) {
        poolId = _poolIds[pool];
        if (poolId == 0) {
            _poolIds[pool] = (poolId = _nextPoolId++);
            _poolIdToPoolKey[poolId] = poolKey;
        }
    }

    /// @inheritdoc INonfungiblePositionManager
    function mint(MintParams calldata params)
        external
        override
        checkDeadline(params.deadline)
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1,
            uint256 collateral
        )
    {
        IBubblyPool pool;
        (liquidity, amount0, amount1,collateral, pool) = addLiquidity(
            AddLiquidityParams({
                token0: params.token0,
                token1: params.token1,
                fee: params.fee,
                recipient: address(this),
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                amount0Desired: params.amount0Desired,
                amount1Desired: params.amount1Desired,
                amount0Min: params.amount0Min,
                amount1Min: params.amount1Min
            })
        );
        require(EmergencyPause[address(pool)] == false);
        _mint(params.recipient, (tokenId = _nextId++));

        bytes32 positionKey = PositionKey.compute(address(this), params.tickLower, params.tickUpper);
        (, uint256 feeGrowthInsideLastX128, ) = pool.positions(positionKey);

        // idempotent set
        uint80 poolId =
            cachePoolKey(
                address(pool),
                PoolAddress.PoolKey({token0: params.token0, token1: params.token1, fee: params.fee})
            );

        _positions[tokenId] = Position({
            nonce: 0,
            operator: address(0),
            poolId: poolId,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: liquidity,
            feeGrowthInsideLastX128: feeGrowthInsideLastX128,
            tokensOwed: 0,
            lpamount0: amount0,
            lpamount1: amount1,
            lpcollateral: collateral
        });

        emit IncreaseLiquidity(tokenId, liquidity, amount0, amount1);
    }

    modifier isAuthorizedForToken(uint256 tokenId) {
        require(_isApprovedOrOwner(msg.sender, tokenId), 'NP');
        _;
    }

    function tokenURI(uint256 tokenId) public view override(ERC721, IERC721Metadata) returns (string memory) {
        require(_exists(tokenId));
        return INonfungibleTokenPositionDescriptor(_tokenDescriptor).tokenURI(this, tokenId);
    }

    // save bytecode by removing implementation of unused method
    function baseURI() public pure override returns (string memory) {}

    /// @inheritdoc INonfungiblePositionManager
    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        override
        checkDeadline(params.deadline)
        returns (
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        Position storage position = _positions[params.tokenId];

        PoolAddress.PoolKey memory poolKey = _poolIdToPoolKey[position.poolId];

        IBubblyPool pool;
        uint256 collateral;
        (liquidity, amount0, amount1, collateral,pool) = addLiquidity(
            AddLiquidityParams({
                token0: poolKey.token0,
                token1: poolKey.token1,
                fee: poolKey.fee,
                tickLower: position.tickLower,
                tickUpper: position.tickUpper,
                amount0Desired: params.amount0Desired,
                amount1Desired: params.amount1Desired,
                amount0Min: params.amount0Min,
                amount1Min: params.amount1Min,
                recipient: address(this)
            })
        );
        require(EmergencyPause[address(pool)] == false);
        bytes32 positionKey = PositionKey.compute(address(this), position.tickLower, position.tickUpper);

        // this is now updated to the current transaction
        (, uint256 feeGrowthInsideLastX128, ) = pool.positions(positionKey);

        position.tokensOwed += uint128(
            FullMath.mulDiv(
                feeGrowthInsideLastX128 - position.feeGrowthInsideLastX128,
                position.liquidity,
                FixedPoint128.Q128
            )
        );

        position.feeGrowthInsideLastX128 = feeGrowthInsideLastX128;
        position.liquidity = position.liquidity + liquidity;
        position.lpcollateral = position.lpcollateral.add(collateral);
        position.lpamount0 = position.lpamount0.add(amount0);
        position.lpamount1 = position.lpamount1.add(amount1);

        emit IncreaseLiquidity(params.tokenId, liquidity, amount0, amount1);
    }

    /// @inheritdoc INonfungiblePositionManager
    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        override
        isAuthorizedForToken(params.tokenId)
        checkDeadline(params.deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        require(params.liquidity > 0);
        Position storage position = _positions[params.tokenId];

        uint128 positionLiquidity = position.liquidity;
        require(positionLiquidity >= params.liquidity);
        uint256 amount0used;
        uint256 amount1used;
        uint256 amountowed;
        PoolAddress.PoolKey memory poolKey = _poolIdToPoolKey[position.poolId];
        IBubblyPool pool = IBubblyPool(PoolAddress.computeAddress(factory, poolKey));
        require(EmergencyPause[address(pool)] == false);
        (amount0, amount1,amount0used,amount1used,amountowed) = pool.burn(
                                        position.tickLower,
                                        position.tickUpper, 
                                        params.liquidity,
                                        IBubblyPoolActions.burnParams({
                                            liquidity:position.liquidity,
                                            lpamount0:position.lpamount0,
                                            lpamount1:position.lpamount1,
                                            lpcollateral:position.lpcollateral 
                                        })
                                    );
        //use more informatino to calculate collateral position

        require(amount0 >= params.amount0Min && amount1 >= params.amount1Min, 'PLC');
        //stack too deep
        {
            //release
            bytes32 positionKey = PositionKey.compute(address(this), position.tickLower, position.tickUpper);
            // this is now updated to the current transaction
            (, uint256 feeGrowthInsideLastX128, ) = pool.positions(positionKey);

            position.tokensOwed +=
                uint128(amountowed) +
                uint128(
                    FullMath.mulDiv(
                        feeGrowthInsideLastX128 - position.feeGrowthInsideLastX128,
                        positionLiquidity,
                        FixedPoint128.Q128
                    )
                );

            position.feeGrowthInsideLastX128 = feeGrowthInsideLastX128;
            // subtraction is safe because we checked positionLiquidity is gte params.liquidity
            position.liquidity = positionLiquidity - params.liquidity;
            position.lpcollateral = position.lpcollateral.sub(amountowed) ;

        }
        //safe sbu
        position.lpamount0 = position.lpamount0 - amount0used;
        position.lpamount1 = position.lpamount1 - amount1used;
        
        if(position.lpamount0 == 0 && position.lpamount1 ==0) position.lpcollateral = 0; 
        emit DecreaseLiquidity(params.tokenId, params.liquidity, amount0, amount1,amountowed);

        if(amount1 != amount1used ){
            address owner = ownerOf(params.tokenId);

            ICollateralPositionManager(CPM).mintWithoutSwap(ICollateralPositionManager.MintWithoutSwapParams({
                    pool:address(pool),
                    amount0: amount0,
                    amount1: amount1,
                    amount0used: amount0used,
                    amount1used: amount1used,
                    recipient: owner
            }));
        }    
        
    }

    /// @inheritdoc INonfungiblePositionManager
    function collect(CollectParams memory params)
        public
        override
        isAuthorizedForToken(params.tokenId)
        returns (uint256 amount)
    {
        require(params.amountMax > 0 );
        // allow collecting to the nft position manager address with address 0
        address recipient = params.recipient == address(0) ? address(this) : params.recipient;

        Position storage position = _positions[params.tokenId];

        PoolAddress.PoolKey memory poolKey = _poolIdToPoolKey[position.poolId];

        IBubblyPool pool = IBubblyPool(PoolAddress.computeAddress(factory, poolKey));
        require(EmergencyPause[address(pool)] == false);
        uint128 tokensOwed = position.tokensOwed;

        // trigger an update of the position fees owed and fee growth snapshots if it has any liquidity
        if (position.liquidity > 0) {
            IBubblyPoolActions.burnParams memory emptyBurn;
            pool.burn(position.tickLower, position.tickUpper, 0 ,emptyBurn);
            (, uint256 feeGrowthInsideLastX128,  ) =
                pool.positions(PositionKey.compute(address(this), position.tickLower, position.tickUpper));

            tokensOwed += uint128(
                FullMath.mulDiv(
                    feeGrowthInsideLastX128 - position.feeGrowthInsideLastX128,
                    position.liquidity,
                    FixedPoint128.Q128
                )
            );
            position.feeGrowthInsideLastX128 = feeGrowthInsideLastX128;
            
        }

        // compute the arguments to give to the pool#collect method
        uint128 amountCollect = params.amountMax > tokensOwed ? tokensOwed : params.amountMax;
                 
        // the actual amounts collected are returned
        amount = pool.collect(
            recipient,
            position.tickLower,
            position.tickUpper,
            amountCollect
        );

        // sometimes there will be a few less wei than expected due to rounding down in core, but we just subtract the full amount expected
        // instead of the actual amount so we can burn the token
        position.tokensOwed = tokensOwed - amountCollect ;
        emit Collect(params.tokenId, recipient, amountCollect);
    }
    
    /// @inheritdoc INonfungiblePositionManager
    function burn(uint256 tokenId) external override isAuthorizedForToken(tokenId) {
        Position storage position = _positions[tokenId];
        require(position.liquidity == 0 && position.tokensOwed == 0 , 'NC');
        delete _positions[tokenId];
        _burn(tokenId);
    }

    function _getAndIncrementNonce(uint256 tokenId) internal override returns (uint256) {
        return uint256(_positions[tokenId].nonce++);
    }

    /// @inheritdoc IERC721
    function getApproved(uint256 tokenId) public view override(ERC721, IERC721) returns (address) {
        require(_exists(tokenId), 'NET');

        return _positions[tokenId].operator;
    }

    /// @dev Overrides _approve to use the operator in the position, which is packed with the position permit nonce
    function _approve(address to, uint256 tokenId) internal override(ERC721) {
        _positions[tokenId].operator = to;
        emit Approval(ownerOf(tokenId), to, tokenId);
    }
    
    function batchCollect(uint256[] calldata ids, uint128[] calldata amounts) public returns (uint256 totalfee) {
        for (uint256 i = 0; i < ids.length; i++) {
            totalfee += collect(CollectParams({
                tokenId : ids[i],
                recipient : msg.sender,
                amountMax : amounts[i]
            }));
        }
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

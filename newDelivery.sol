
// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;
import './interfaces/IDelivery.sol';
import './interfaces/ICollateralPositionManager.sol';
import './interfaces/IBubblyPool.sol';
import './interfaces/IBubblyFactory.sol';
import './libraries/LowGasSafeMath.sol';
import './libraries/TransferHelper.sol';
import './libraries/FullMath.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import './interfaces/IERC20Minimal.sol';
import 'hardhat/console.sol';

contract newDelivery  {
    struct DeliveryInfo{
        uint256 amount0Bought; 
        uint256 amount0Distributed;
    }

    mapping(address => address) public vtokenToToken;
    //for price calculation
    mapping(address => uint256) public poolTotalToken;
    mapping(address => uint256) public poolTotalQuoteToken;
    mapping(address => uint256) public poolReserve;
    mapping(address => uint32) public DeliverBeginTime;
    mapping(address => uint32) public DeliverEpoch;
    mapping(address => mapping(address => bool)) public sellerDeliverList;
    mapping(address => mapping(address => bool)) public buyerDeliverList;
    mapping(address => address[]) public buyersSortedList;
    //for binary search
    mapping(address => uint256[]) public auxiliaryList;
    //pool -> point
    mapping(address => uint256) public listPoint;
    //pool -> buyer -> info
    mapping(address => mapping(address => DeliveryInfo)) public buyersInfo;

    address immutable CPM;
    address immutable factory;
    //pool -> admin
    mapping (address => address) public EmergencyAdmin;
    mapping (address => bool) public EmergencyPause;
    using LowGasSafeMath for uint256;

    event SetEmergencyAdmin(address indexed pool, address admin);
    event SetEmergencyPause(address indexed pool, bool flag);
    event DeliverBeforeDeadline(address indexed recipient, uint256 amount0, uint256 amont1, bool forX,address pool);
    event DeliverAfterDeadline(address indexed recipient, uint256 amountX, uint256 amountY, address pool);
    event SetDeliveryToken(address indexed pool, address vtoken ,address token);
    event SetDeliveryTime(address indexed pool, uint32 timeStamp);
    event SetDeliveryEpoch(address indexed pool, uint32 epoch);

    constructor(address _factory, address _CPM) {
        CPM = _CPM;
        factory = _factory;
    }
    modifier onlyFactoryOwnerOrAdmin(address pool) {
        require(msg.sender == IBubblyFactory(factory).owner() || msg.sender == EmergencyAdmin[pool] );
        _;
    }
    modifier onlyFactoryOwner() {
        require(msg.sender == IBubblyFactory(factory).owner());
        _;
    }
    function _bSerach (address pool, uint256 target) public returns (uint256){
        //find the first number index bigger than target
        uint256 low = 0;
        uint256 high = auxiliaryList[pool].length - 1;
        while(low <= high)
        {
            uint256 mid = (low + high) / 2 ;
            if(auxiliaryList[pool][mid] <= target){
                low = mid + 1;
            }
            else{
                if(high == 0){
                    break;
                }
                high = mid -1;
            }      
        }
        //if low == length, then all tokens are dilvered
        return low;
    }
    function setDeliverEpoch(address pool, uint32 epoch) onlyFactoryOwner public{
        DeliverEpoch[pool] = epoch;
        emit SetDeliveryEpoch(pool, epoch);
    } 
    function setBuyerSortedList(address[] calldata buyers, DeliveryInfo[] calldata info ,address pool) onlyFactoryOwner public{
        require(buyers.length == info.length,'length error');
        uint256 length = buyersSortedList[pool].length;
        if(length == 0){
            buyersSortedList[pool] = buyers;
            auxiliaryList[pool] = new uint256[](buyers.length);
            for(uint256 i = 0; i < buyers.length; i++){
                buyersInfo[pool][buyers[i]] = info[i];
                //update auxiliaryList
                if (i == 0){
                    auxiliaryList[pool][i] = info[i].amount0Bought;
                }else{
                    auxiliaryList[pool][i] = info[i].amount0Bought + auxiliaryList[pool][i-1];
                }
            }    
        }else{
            //push
            for(uint256 i = 0; i < buyers.length; i++){
                buyersSortedList[pool].push(buyers[i]);
                buyersInfo[pool][buyers[i]] = info[i];
                //update auxiliaryList
                auxiliaryList[pool].push(info[i].amount0Bought + auxiliaryList[pool][length + i -1]);
            }  
            
        }
    
    } 
    function Deliver(address pool, bool forX) public returns (uint256 amount0,uint256 amount1 ,bool getToken){
        // pool flag check
        require(EmergencyPause[pool] == false);
        require(DeliverBeginTime[pool] != uint32(0),'Time not set');
        require(_blockTimestamp() >= DeliverBeginTime[pool], 'Delivery not start');
        require(DeliverEpoch[pool] != uint32(0));
        //check overflow
        require(_blockTimestamp() <= DeliverBeginTime[pool] + DeliverEpoch[pool], 'Delivery after 24hs');
        require(IBubblyPool(pool).deliveryflag());
        // check token address
        require(vtokenToToken[IBubblyPool(pool).token0()]!= address(0));
        getToken = forX;
        (amount0, amount1) = _getPosition(pool, forX);
        //check tokenBalance
        if(!forX){
            //seller delivery
            require(!sellerDeliverList[msg.sender][pool], 'already delivered' );
            sellerDeliverList[msg.sender][pool] = true;
            //transfer real tokenY from msg.sender to contract for delivery
            TransferHelper.safeTransferFrom(vtokenToToken[IBubblyPool(pool).token0()], msg.sender,address(this), amount0);
            TransferHelper.safeTransferFrom(IBubblyPool(pool).token1(), pool, msg.sender, 2 * amount1);
            //change state
            //for bsearch
            poolTotalToken[pool] = poolTotalToken[pool].add(amount0);
            //for balance 
            poolReserve[pool] = poolReserve[pool].add(amount0);
            //update buyerlist
            uint256 oldPoint = listPoint[pool];
            uint256 point = _bSerach(pool, poolTotalToken[pool]);

            for(uint256 i = oldPoint ; i < point ; i++){
                //update info
                buyersInfo[pool][buyersSortedList[pool][i]].amount0Distributed = buyersInfo[pool][buyersSortedList[pool][i]].amount0Bought;
            }
            //if no number bigger than target , point == infolength, we finish update in cycle
            if(point != buyersSortedList[pool].length && point > 0){
                buyersInfo[pool][buyersSortedList[pool][point]].amount0Distributed += poolTotalToken[pool] - auxiliaryList[pool][point-1];
            }
            else if (point == 0){
                buyersInfo[pool][buyersSortedList[pool][point]].amount0Distributed += amount0;
            }
            //update point
            listPoint[pool] = point;
        }
        else{
            //buyer delivery
            require(!buyerDeliverList[msg.sender][pool], 'already delivered' );
            buyerDeliverList[msg.sender][pool] = true;
            require(poolReserve[pool] >= amount0 , 'not enough balance');
            require(buyersInfo[pool][msg.sender].amount0Bought == buyersInfo[pool][msg.sender].amount0Distributed);
            TransferHelper.safeTransfer(vtokenToToken[IBubblyPool(pool).token0()], msg.sender, amount0);
            poolReserve[pool] = poolReserve[pool].sub(amount0);
        }
        emit DeliverBeforeDeadline(msg.sender, amount0, amount1, forX, pool);
    } 
   function DeliverforX(address pool) external returns (uint256 amountX,uint256 amountY){
        //pool flag check
        require(EmergencyPause[pool] == false);
        require(DeliverBeginTime[pool] != uint32(0),'Time not set');
        require(DeliverEpoch[pool] != uint32(0));
        require(_blockTimestamp() > DeliverBeginTime[pool] + DeliverEpoch[pool], 'Delivery before 24hs');
        require(IBubblyPool(pool).deliveryflag());
        // check token address
        require(vtokenToToken[IBubblyPool(pool).token0()]!= address(0));
        (uint256 amount0, uint256 amount1) = _getPosition(pool, true);
        uint256 amount0Distributed = buyersInfo[pool][msg.sender].amount0Distributed;
        uint256 amount0Bought = buyersInfo[pool][msg.sender].amount0Bought;
        if(amount0Distributed == amount0Bought){
            //get all tokenX
            amountX = buyersInfo[pool][msg.sender].amount0Distributed;
            TransferHelper.safeTransfer(vtokenToToken[IBubblyPool(pool).token0()], msg.sender, amountX);
            poolReserve[pool] = poolReserve[pool].sub(amountX);
        }
        else if(amount0Distributed == uint256(0)){
            //get double collateral
            amountY = 2 * amount1 ;    
            TransferHelper.safeTransferFrom(IBubblyPool(pool).token1(), pool, msg.sender, amountY > balance1(pool) ? balance1(pool) : amountY);
        }
        else{
            amountX = amount0Distributed;
            TransferHelper.safeTransfer(vtokenToToken[IBubblyPool(pool).token0()], msg.sender, amountX);
            poolReserve[pool] = poolReserve[pool].sub(amountX);
            //maker sure that amount0 and amount0Bought are same  
            amountY = 2 * (amount1 - FullMath.mulDiv(amountX , amount1 , amount0)); 
            if(amountY != 0) TransferHelper.safeTransferFrom(IBubblyPool(pool).token1(), pool, msg.sender, amountY > balance1(pool) ? balance1(pool) : amountY);
        }
        //buyer delivery
        require(!buyerDeliverList[msg.sender][pool], 'already delivered' );
        buyerDeliverList[msg.sender][pool] = true;
        emit DeliverAfterDeadline(msg.sender, amountX, amountY, pool);
    }
    function _blockTimestamp() internal view virtual returns (uint32) {
        return uint32(block.timestamp); // truncation is desired
    }


    function setToken(
        address pool,
        address token,
        address vtoken
    ) external onlyFactoryOwner {
        require(IBubblyPool(pool).deliveryflag());
        require(vtokenToToken[vtoken] == address(0));
        vtokenToToken[vtoken] = token;
        emit SetDeliveryToken(pool, vtoken ,token);
    }
    function setDeliveryTime(
        address pool,
        uint32 time
    ) external onlyFactoryOwner {
        DeliverBeginTime[pool] = time;
        emit SetDeliveryTime(pool, time);
    }

    function _getPosition(address pool, bool forX) internal view returns (uint256 amount0 ,uint256 amount1){
        if(!forX){
            (amount0, amount1) =  ICollateralPositionManager(CPM).getShortPosition(pool, msg.sender);
        }else{
            (amount0, amount1) =  ICollateralPositionManager(CPM).getLongPosition(pool, msg.sender);
        }
    }
    //handle accurate issue
    function balance1(address pool) private view returns (uint256) {
        (bool success, bytes memory data) =
            IBubblyPool(pool).token1().staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, pool));
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    function emergencyTokenTransfer(address token, address to, uint256 amount) external onlyFactoryOwner {
        TransferHelper.safeTransfer(token, to, amount);
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


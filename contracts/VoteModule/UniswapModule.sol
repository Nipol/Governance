/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

import "UniswapV3Pack/v3-core/interfaces/IUniswapV3Pool.sol";
import "UniswapV3Pack/v3-core/interfaces/IUniswapV3Factory.sol";
import "UniswapV3Pack/v3-core/interfaces/callback/IUniswapV3MintCallback.sol";
import "UniswapV3Pack/v3-core/libraries/TickMath.sol";
import "UniswapV3Pack/v3-periphery/interfaces/ISwapRouter.sol";
import "UniswapV3Pack/v3-periphery/interfaces/IQuoterV2.sol";
import {PositionKey} from "UniswapV3Pack/v3-periphery/libraries/PositionKey.sol";
import {LiquidityAmounts} from "UniswapV3Pack/v3-periphery/libraries/LiquidityAmounts.sol";
import "@beandao/contracts/interfaces/IERC165.sol";

import "./Math.sol";
import "./IModule.sol";

error UnorderedTick();
error NotEnoughVotes();
error NotAllowedAddress(address delegatee);

/**
 * @author  yoonsung.eth
 * @title   UniswapModule
 * @notice  투표권을 등록하는 방식을 유니스왑에 유동성을 공급하는 방법으로 수행합니다. 지정한 토큰과, 가치를 보장하기 위한 페어 토큰을 지정하여 유동성 풀을
 *          만들어 해당 모듈을 통해 공급된 유동성은 투표권으로 계산됩니다. 해당 모듈이 초기화 될 때 유동성의 가격 범위를 지정할 수 있으며, 해당 영역에
 *          대하여 유동성이 추가됩니다.
 * @dev     모든 토큰은 해당 모듈을 사용하는 Council로 전송되어 Pool로 전송되는 과정을 거칩니다.
 * TODO: FEE Policy, Optimization
 */
contract UniswapModule is IModule, IERC165, IUniswapV3MintCallback {
    struct Checkpoint {
        uint32 fromBlock;
        uint224 votes;
    }

    struct Storage {
        mapping(address => uint256) balances;
        mapping(address => address) delegates;
        mapping(address => Checkpoint[]) checkpoints;
        Checkpoint[] totalCheckpoints;
    }

    struct StakeParam {
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct StakeSingleParam {
        uint256 amountIn;
        uint256 amountInForSwap;
        uint256 amountOutMin;
        bool isAmountIn0;
        uint256 deadline;
    }

    // address public constant WETH = ;
    bytes32 constant POSITION = keccak256("eth.dao.bean.stakemodule.uniswapv3");
    address public constant UNIV3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address public constant UNIV3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address public constant UNIV3_QUOTOR_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    uint256 internal constant DUST_THRESHOLD = 1e6;

    address public immutable council;
    address public immutable token0;
    address public immutable token1;
    address public immutable pool;
    int24 public immutable lowerTick;
    int24 public immutable upperTick;
    int24 public immutable tickSpacing;
    uint24 public immutable fee;
    uint32 public immutable undelegatePeriod;

    modifier onlyCouncil() {
        if (address(this) != council) revert();
        _;
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert();
        _;
    }

    event Delegate(address to, uint256 prevVotes, uint256 nextVotes);

    /**
     * @notice 해당 모듈을 초기화 하는데 사용하는 함수, 해당 함수는 Council을 통해서
     */
    constructor(
        address councilAddr,
        address _token0,
        address _token1,
        uint24 _fee,
        uint160 _sqrtPriceX96,
        int24 _lowerTick,
        int24 _upperTick,
        uint32 _undelegatePeriod
    ) {
        (council, fee, undelegatePeriod) = (councilAddr, _fee, _undelegatePeriod);

        address tmppool = IUniswapV3Factory(UNIV3_FACTORY).getPool(_token0, _token1, _fee);
        pool = tmppool == address(0) ? IUniswapV3Factory(UNIV3_FACTORY).createPool(_token0, _token1, _fee) : tmppool;
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(pool).slot0();
        if (sqrtPriceX96 == 0) {
            IUniswapV3Pool(pool).initialize(_sqrtPriceX96);
        }
        tickSpacing = IUniswapV3Pool(pool).tickSpacing();

        unchecked {
            // validate tick
            lowerTick = (_lowerTick % tickSpacing) != 0
                ? _lowerTick - (_lowerTick % tickSpacing) + (_lowerTick < 0 ? -tickSpacing : tickSpacing)
                : _lowerTick;
            upperTick = (_upperTick % tickSpacing) != 0
                ? _upperTick - (_upperTick % tickSpacing) + (_upperTick < 0 ? -tickSpacing : tickSpacing)
                : _upperTick;
        }
        if (upperTick <= lowerTick) revert UnorderedTick();
        (token0, token1) = _token0 > _token1 ? (_token1, _token0) : (_token0, _token1);
    }

    /**
     * @notice  두 개의 토큰을 이용하여, 투표권으로 변환합니다.
     * @dev     추가되어야 할 수량값은 급격하게 가격이 변동하는 경우를 대비한 값이 입력되어야 합니다.
     * @param   params token0과 token1의 수량과 최소한 추가되어야 할 수량 값
     */
    function stake(StakeParam calldata params) external checkDeadline(params.deadline) onlyCouncil {
        // 둘 다 0으로 들어오는 경우 실패
        if (params.amount0Desired == 0 && params.amount1Desired == 0) revert();
        Storage storage s = moduleStorage();

        address currentDelegatee = s.delegates[msg.sender];
        bytes32 positionKey = PositionKey.compute(address(this), lowerTick, upperTick);

        // 현재 포지션에 있는 유동성
        (uint128 existingLiquidity, , , , ) = IUniswapV3Pool(pool).positions(positionKey);
        // 현재 Pool의 가격
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(pool).slot0();

        // Pool에 더해야 하는 유동성 계산
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(lowerTick),
            TickMath.getSqrtRatioAtTick(upperTick),
            params.amount0Desired,
            params.amount1Desired
        );

        if (liquidity == 0) revert();

        // 해당 시점에서, Council이 가지고 있는 토큰을 등록함
        (uint256 amount0, uint256 amount1) = IUniswapV3Pool(pool).mint(
            address(this),
            lowerTick,
            upperTick,
            liquidity,
            abi.encode(msg.sender)
        );

        // 실제로 추가된 토큰 수량 체크
        if (amount0 < params.amount0Min && amount1 < params.amount1Min) revert();

        // added totalShare
        uint256 existingShareSupply;
        unchecked {
            uint256 length = s.totalCheckpoints.length;
            existingShareSupply = length != 0 ? s.totalCheckpoints[length - 1].votes : 0;
        }

        uint256 shares;

        if (existingShareSupply == 0) {
            shares = liquidity;
        } else {
            shares = Math.mulDiv(existingShareSupply, liquidity, existingLiquidity);
        }

        unchecked {
            s.balances[msg.sender] += shares;
        }

        // 누군가에게 위임을 했다면,
        if (currentDelegatee != msg.sender && currentDelegatee != address(0)) {
            // 추가된 수량만큼 기존 위임자에게 위임 수량 증가.
            delegateVotes(address(0), currentDelegatee, shares);
        } else {
            delegateVotes(address(0), msg.sender, shares);
            s.delegates[msg.sender] = msg.sender;
        }

        // 총 위임량 업데이트
        writeCheckpoint(s.totalCheckpoints, _add, shares);
    }

    /**
     * @notice  하나의 토큰만 예치하여, swap을 통해 희석한 다음 투표권으로 변환합니다.
     * @dev     추가되어야 할 수량값은 급격하게 가격이 변동하는 경우를 대비한 값이 입력되어야 합니다. param에 사용될 값은 `getSingleSidedAmount`
     *          함수로 미리 계산되어야 합니다.
     * @param   params 추가할 총 토큰 수량, 교환할 토큰 수량, 최소로 교환된 토큰 수량, 입력되는 토큰이
     * TODO: Deadline.
     */
    function stake(StakeSingleParam calldata params) external checkDeadline(params.deadline) onlyCouncil {
        if (params.amountInForSwap > params.amountIn) revert();
        Storage storage s = moduleStorage();

        address currentDelegatee = s.delegates[msg.sender];
        (address tokenIn, address tokenOut) = params.isAmountIn0 ? (token0, token1) : (token1, token0);

        safeTransferFrom(tokenIn, msg.sender, address(this), params.amountIn);

        safeApprove(tokenIn, UNIV3_ROUTER, params.amountInForSwap);

        uint256 amountOut = ISwapRouter(UNIV3_ROUTER).exactInput(
            ISwapRouter.ExactInputParams({
                path: abi.encodePacked(tokenIn, fee, tokenOut),
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: params.amountInForSwap,
                amountOutMinimum: params.amountOutMin
            })
        );

        bytes32 positionKey = PositionKey.compute(address(this), lowerTick, upperTick);

        (uint128 existingLiquidity, , , , ) = IUniswapV3Pool(pool).positions(positionKey);
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(pool).slot0();

        (uint256 amount0, uint256 amount1) = params.isAmountIn0
            ? (params.amountIn - params.amountInForSwap, amountOut)
            : (amountOut, params.amountIn - params.amountInForSwap);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(lowerTick),
            TickMath.getSqrtRatioAtTick(upperTick),
            amount0,
            amount1
        );

        if (liquidity == 0) revert();

        // this stage for token transfered
        (amount0, amount1) = IUniswapV3Pool(pool).mint(
            address(this),
            lowerTick,
            upperTick,
            liquidity,
            abi.encode(this)
        );

        // added totalShare
        uint256 existingShareSupply;
        unchecked {
            uint256 length = s.totalCheckpoints.length;
            existingShareSupply = length != 0 ? s.totalCheckpoints[length - 1].votes : 0;
        }
        uint256 shares;

        if (existingShareSupply == 0) {
            shares = liquidity;
        } else {
            shares = Math.mulDiv(existingShareSupply, liquidity, existingLiquidity);
        }

        unchecked {
            s.balances[msg.sender] += shares;
        }

        // 누군가에게 위임을 했다면,
        if (currentDelegatee != msg.sender && currentDelegatee != address(0)) {
            // 추가된 수량만큼 기존 위임자에게 위임 수량 증가.
            delegateVotes(address(0), currentDelegatee, shares);
        } else {
            delegateVotes(address(0), msg.sender, shares);
            s.delegates[msg.sender] = msg.sender;
        }

        // 총 위임량 업데이트
        writeCheckpoint(s.totalCheckpoints, _add, shares);

        // 남아있는 dust 전송
        {
            (bool success, bytes memory data) = token0.staticcall(
                abi.encodeWithSignature("balanceOf(address)", address(this))
            );
            require(success && data.length >= 32);
            uint256 dust0 = abi.decode(data, (uint256));

            (success, data) = token1.staticcall(abi.encodeWithSignature("balanceOf(address)", address(this)));
            require(success && data.length >= 32);
            uint256 dust1 = abi.decode(data, (uint256));

            if (dust0 != 0) safeTransfer(token0, msg.sender, dust0);
            if (dust1 != 0) safeTransfer(token1, msg.sender, dust1);
        }
    }

    function unstake(uint256 shares) external onlyCouncil {
        if (shares == 0) revert();
        Storage storage s = moduleStorage();

        s.balances[msg.sender] -= shares;

        (address currentDelegate, uint256 latestBalance) = (s.delegates[msg.sender], s.balances[msg.sender]);

        uint256 currentTotalSupply;
        unchecked {
            uint256 length = s.totalCheckpoints.length;
            currentTotalSupply = length != 0 ? s.totalCheckpoints[length - 1].votes : 0;
        }

        bytes32 positionKey = PositionKey.compute(address(this), lowerTick, upperTick);

        (uint128 existingLiquidity, , , , ) = IUniswapV3Pool(pool).positions(positionKey);
        uint128 removedLiquidity = uint128(Math.mulDiv(existingLiquidity, shares, currentTotalSupply));
        // 유동성 해제,
        (uint256 amount0, uint256 amount1) = IUniswapV3Pool(pool).burn(lowerTick, upperTick, removedLiquidity);
        // 해제된 유동성 전송
        (amount0, amount1) = IUniswapV3Pool(pool).collect(
            msg.sender,
            lowerTick,
            upperTick,
            uint128(amount0),
            uint128(amount1)
        );

        // 현재 위임에서 share 만큼 삭감
        delegateVotes(currentDelegate, address(0), shares);
        unchecked {
            // 잔액이 0이라면 기존 밸런스 모두 삭제.
            if (latestBalance - shares == 0) {
                delete s.balances[msg.sender];
                delete s.delegates[msg.sender];
            } else {
                // 잔액이 남았다면 차감만 함
                s.balances[msg.sender] -= shares;
            }
        }

        writeCheckpoint(s.totalCheckpoints, _sub, shares);
    }

    /**
     * @notice 예치된 투표권을 특정 주소로 위임합니다.
     */
    function delegate(address delegatee) external onlyCouncil {
        if (delegatee == address(0)) revert NotAllowedAddress(delegatee);
        Storage storage s = moduleStorage();

        (address currentDelegate, uint256 latestBalance) = (s.delegates[msg.sender], s.balances[msg.sender]);

        if (latestBalance == 0) revert NotEnoughVotes();

        if (currentDelegate != delegatee) {
            delegateVotes(currentDelegate, delegatee, latestBalance);
            s.delegates[msg.sender] = delegatee;
        }
    }

    function getSingleSidedAmount(uint256 amountIn, bool isAmountIn0)
        external
        onlyCouncil
        returns (uint128 liquidity, uint256 amountForSwap)
    {
        (uint160 lowerSqrtPrice, uint160 upperSqrtPrice) = (
            TickMath.getSqrtRatioAtTick(lowerTick),
            TickMath.getSqrtRatioAtTick(upperTick)
        );

        (address tokenIn, address tokenOut) = isAmountIn0 ? (token0, token1) : (token1, token0);

        amountForSwap = amountIn / 2;
        uint256 i; // Cur binary search iteration
        (uint256 low, uint256 high) = (0, amountIn);
        uint256 amountOutRecv;
        uint160 sqrtRatioX96; // current price
        uint256 leftoverAmount0;
        uint256 leftoverAmount1;

        while (i != 128) {
            (amountOutRecv, sqrtRatioX96, , ) = IQuoterV2(UNIV3_QUOTOR_V2).quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    amountIn: amountForSwap,
                    fee: fee,
                    sqrtPriceLimitX96: 0
                })
            );

            uint256 amountInPostSwap = amountIn - amountForSwap;

            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtRatioX96,
                lowerSqrtPrice,
                upperSqrtPrice,
                isAmountIn0 ? amountInPostSwap : amountOutRecv,
                isAmountIn0 ? amountOutRecv : amountInPostSwap
            );

            // Get the amounts needed for post swap end sqrt ratio end state
            (uint256 lpAmount0, uint256 lpAmount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtRatioX96,
                lowerSqrtPrice,
                upperSqrtPrice,
                liquidity
            );

            // Calculate leftover amounts with Trimming some dust
            if (isAmountIn0) {
                leftoverAmount0 = ((amountInPostSwap - lpAmount0) / 100) * 100;
                leftoverAmount1 = ((amountOutRecv - lpAmount1) / 100) * 100;
            } else {
                leftoverAmount0 = ((amountOutRecv - lpAmount0) / 100) * 100;
                leftoverAmount1 = ((amountInPostSwap - lpAmount1) / 100) * 100;
            }

            // Termination condition, we approximated enough
            if (leftoverAmount0 <= DUST_THRESHOLD && leftoverAmount1 <= DUST_THRESHOLD) {
                break;
            }

            if (isAmountIn0) {
                if (leftoverAmount0 > 0) {
                    (low, amountForSwap, high) = (amountForSwap, (high + amountForSwap) / 2, high);
                } else if (leftoverAmount1 > 0) {
                    (low, amountForSwap, high) = (low, (low + amountForSwap) / 2, amountForSwap);
                } else {
                    break;
                }
            } else {
                if (leftoverAmount1 > 0) {
                    (low, amountForSwap, high) = (amountForSwap, (high + amountForSwap) / 2, high);
                } else if (leftoverAmount0 > 0) {
                    (low, amountForSwap, high) = (low, (low + amountForSwap) / 2, amountForSwap);
                } else {
                    break;
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice 누적된 특정 주소의 투표권 정보 개수를 가져옵니다.
     */
    function numCheckpoints(address account) public view onlyCouncil returns (uint32) {
        Storage storage s = moduleStorage();
        return uint32(s.checkpoints[account].length);
    }

    /**
     * @notice BlockNumber를 기준으로, target의 정량적인 투표권을 가져옵니다.
     * @param target 대상이 되는 주소
     * @param blockNumber 기반이 되는 블록 숫자
     * @return votes 투표 권한
     */
    function getPriorVotes(address target, uint256 blockNumber) external view onlyCouncil returns (uint256 votes) {
        if (blockNumber > block.number) revert();
        Storage storage s = moduleStorage();
        votes = _checkpointsLookup(s.checkpoints[target], blockNumber);
    }

    /**
     * @notice BlockNumber를 기준으로, target의 투표권을 비율화 하여 가져옵니다.
     * @param target 대상이 되는 주소
     * @param blockNumber 기반이 되는 블록 숫자
     * @return rate 비율
     */
    function getPriorRate(address target, uint256 blockNumber) external view onlyCouncil returns (uint256 rate) {
        if (blockNumber > block.number) revert();
        Storage storage s = moduleStorage();
        rate =
            (_checkpointsLookup(s.checkpoints[target], blockNumber) * 1e4) /
            _checkpointsLookup(s.totalCheckpoints, blockNumber);
    }

    /**
     * @notice BlockNumber를 기준으로, 특정 수치의 투표권을 총 투표권의 비율로 계산하는 함수
     * @param votes 계산하고자 하는 투표권한
     * @param blockNumber 기반이 되는 블록 숫자
     */
    function getVotesToRate(uint256 votes, uint256 blockNumber) external view onlyCouncil returns (uint256 rate) {
        if (blockNumber > block.number) revert();
        Storage storage s = moduleStorage();
        rate = (votes * 1e4) / _checkpointsLookup(s.totalCheckpoints, blockNumber);
    }

    /**
     * @notice 입력된 블록을 기준하여, 총 투표권을 반환합니다.
     * @param blockNumber 기반이 되는 블록 숫자
     * @return totalVotes 총 투표권
     */
    function getPriorTotalSupply(uint256 blockNumber) external view onlyCouncil returns (uint256 totalVotes) {
        if (blockNumber > block.number) revert();
        Storage storage s = moduleStorage();
        totalVotes = _checkpointsLookup(s.totalCheckpoints, blockNumber);
    }

    /**
     * @notice 특정 주소의 총 예치 수량을 반환합니다.
     */
    function balanceOf(address target) public view onlyCouncil returns (uint256 balance) {
        Storage storage s = moduleStorage();
        balance = s.balances[target];
    }

    /**
     * @notice 특정 주소의 총 투표권을 반환합니다.
     */
    function voteOf(address target) public view onlyCouncil returns (uint256 votes) {
        Storage storage s = moduleStorage();
        uint256 length = s.checkpoints[target].length;
        unchecked {
            votes = length != 0 ? s.checkpoints[target][length - 1].votes : 0;
        }
    }

    /**
     * @notice 특정 주소가 투표권을 위임하고 있는 주소를 반환합니다.
     */
    function getDelegate(address target) public view onlyCouncil returns (address delegatee) {
        Storage storage s = moduleStorage();
        delegatee = s.delegates[target];
    }

    // 총 투표권 수량
    function totalSupply() external view onlyCouncil returns (uint256 amount) {
        Storage storage s = moduleStorage();
        unchecked {
            uint256 length = s.totalCheckpoints.length;
            amount = length != 0 ? s.totalCheckpoints[length - 1].votes : 0;
        }
    }

    function getTokens() public view onlyCouncil returns (address, address) {
        return (token0, token1);
    }

    // Pool에서 fallback으로 호출되는 함수
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external onlyCouncil {
        address from = abi.decode(data, (address));
        if (from != address(this)) {
            if (amount0Owed != 0) safeTransferFrom(token0, from, pool, amount0Owed);
            if (amount1Owed != 0) safeTransferFrom(token1, from, pool, amount1Owed);
        } else if (from == address(this)) {
            if (amount0Owed != 0) safeTransfer(token0, pool, amount0Owed);
            if (amount1Owed != 0) safeTransfer(token1, pool, amount1Owed);
        }
    }

    function supportsInterface(bytes4 interfaceID) external pure returns (bool) {
        return interfaceID == type(IModule).interfaceId || interfaceID == type(IERC165).interfaceId;
    }

    /**
     * @notice amount 수량만큼, from으로 부터 to로 이관합니다.
     * @dev from이 Zero Address라면, 새로운 amount를 등록하는 것이며, to가 Zero Address라면 기존에 있던 amount를 감소시킵니다.
     * @param from 위임을 부여할 대상
     * @param to 위임이 이전될 대상
     * @param amount 위임 수량
     */
    function delegateVotes(
        address from,
        address to,
        uint256 amount
    ) internal {
        Storage storage s = moduleStorage();

        if (from != to && amount != 0) {
            if (from != address(0)) {
                (uint256 oldWeight, uint256 newWeight) = writeCheckpoint(s.checkpoints[from], _sub, amount);
                emit Delegate(from, oldWeight, newWeight);
            }

            if (to != address(0)) {
                (uint256 oldWeight, uint256 newWeight) = writeCheckpoint(s.checkpoints[to], _add, amount);
                emit Delegate(to, oldWeight, newWeight);
            }
        }
    }

    function writeCheckpoint(
        Checkpoint[] storage ckpts,
        function(uint256, uint256) view returns (uint256) op,
        uint256 delta
    ) internal returns (uint256 oldWeight, uint256 newWeight) {
        uint256 length = ckpts.length;
        oldWeight = length != 0 ? ckpts[length - 1].votes : 0;
        newWeight = op(oldWeight, delta);

        if (length > 0 && ckpts[length - 1].fromBlock == block.number) {
            ckpts[length - 1].votes = uint224(newWeight);
        } else {
            ckpts.push(Checkpoint({fromBlock: uint32(block.number), votes: uint224(newWeight)}));
        }
    }

    function _checkpointsLookup(Checkpoint[] storage ckpts, uint256 blockNumber) private view returns (uint256 votes) {
        uint256 high = ckpts.length;
        uint256 low = 0;
        uint256 mid;
        while (low < high) {
            unchecked {
                mid = ((low & high) + (low ^ high) / 2);
            }
            if (ckpts[mid].fromBlock > blockNumber) {
                high = mid;
            } else {
                unchecked {
                    low = mid + 1;
                }
            }
        }

        unchecked {
            votes = high != 0 ? ckpts[high - 1].votes : 0;
        }
    }

    /// @notice Modified from Gnosis
    /// (https://github.com/gnosis/gp-v2-contracts/blob/main/src/contracts/libraries/GPv2SafeERC20.sol)
    function safeTransferFrom(
        address tokenAddr,
        address from,
        address to,
        uint256 amount
    ) internal returns (bool success) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            let freePointer := mload(0x40)
            mstore(freePointer, 0x23b872dd00000000000000000000000000000000000000000000000000000000)
            mstore(add(freePointer, 4), from)
            mstore(add(freePointer, 36), to)
            mstore(add(freePointer, 68), amount)

            let callStatus := call(gas(), tokenAddr, 0, freePointer, 100, 0, 0)

            let returnDataSize := returndatasize()
            if iszero(callStatus) {
                // Copy the revert message into memory.
                returndatacopy(0, 0, returnDataSize)

                // Revert with the same message.
                revert(0, returnDataSize)
            }
            switch returnDataSize
            case 32 {
                // Copy the return data into memory.
                returndatacopy(0, 0, returnDataSize)

                // Set success to whether it returned true.
                success := iszero(iszero(mload(0)))
            }
            case 0 {
                // There was no return data.
                success := 1
            }
            default {
                // It returned some malformed input.
                success := 0
            }
        }
    }

    function safeTransfer(
        address tokenAddr,
        address to,
        uint256 amount
    ) internal returns (bool success) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            let freePointer := mload(0x40)
            mstore(freePointer, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
            mstore(add(freePointer, 4), to)
            mstore(add(freePointer, 36), amount)

            let callStatus := call(gas(), tokenAddr, 0, freePointer, 68, 0, 0)

            let returnDataSize := returndatasize()
            if iszero(callStatus) {
                // Copy the revert message into memory.
                returndatacopy(0, 0, returnDataSize)

                // Revert with the same message.
                revert(0, returnDataSize)
            }
            switch returnDataSize
            case 32 {
                // Copy the return data into memory.
                returndatacopy(0, 0, returnDataSize)

                // Set success to whether it returned true.
                success := iszero(iszero(mload(0)))
            }
            case 0 {
                // There was no return data.
                success := 1
            }
            default {
                // It returned some malformed input.
                success := 0
            }
        }
    }

    function safeApprove(
        address tokenAddr,
        address to,
        uint256 amount
    ) internal returns (bool success) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            let freePointer := mload(0x40)

            mstore(freePointer, 0x095ea7b300000000000000000000000000000000000000000000000000000000)
            mstore(add(freePointer, 4), to)
            mstore(add(freePointer, 36), amount)

            let callStatus := call(gas(), tokenAddr, 0, freePointer, 68, 0, 0)

            let returnDataSize := returndatasize()
            if iszero(callStatus) {
                // Copy the revert message into memory.
                returndatacopy(0, 0, returnDataSize)

                // Revert with the same message.
                revert(0, returnDataSize)
            }
            switch returnDataSize
            case 32 {
                // Copy the return data into memory.
                returndatacopy(0, 0, returnDataSize)

                // Set success to whether it returned true.
                success := iszero(iszero(mload(0)))
            }
            case 0 {
                // There was no return data.
                success := 1
            }
            default {
                // It returned some malformed input.
                success := 0
            }
        }
    }

    function _add(uint256 a, uint256 b) private pure returns (uint256) {
        return a + b;
    }

    function _sub(uint256 a, uint256 b) private pure returns (uint256) {
        return a - b;
    }

    function moduleStorage() internal pure returns (Storage storage s) {
        bytes32 position = POSITION;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            s.slot := position
        }
    }
}

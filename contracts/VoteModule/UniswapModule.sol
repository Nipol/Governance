/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import {PositionKey} from "@uniswap/v3-periphery/contracts/libraries/PositionKey.sol";
import {LiquidityAmounts} from "./uniswap/LiquidityAmounts.sol";
import "@beandao/contracts/interfaces/IERC165.sol";

import "./uniswap/INonfungiblePositionManager.sol";
import "./uniswap/Math.sol";
import "./uniswap/TickMath.sol";
import "./IModule.sol";

library UniswapStorage {
    bytes32 constant POSITION = keccak256("eth.dao.bean.stakemodule.uniswapv3");

    struct Checkpoint {
        uint32 fromBlock;
        uint224 votes;
    }

    struct Storage {
        bool initialized;
        uint256 totalSupply;
        address pool;
        bytes32 PositionKey;
        address token0;
        address token1;
        int24 lowerTick;
        int24 upperTick;
        uint24 fee;
        int24 tickSpacing;
        uint32 undelegatePeriod;
        mapping(address => uint256) balanceOf;
    }

    function moduleStorage() internal pure returns (Storage storage s) {
        bytes32 position = POSITION;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            s.slot := position
        }
    }
}

/**
 * @author  yoonsung.eth
 * @title   UniswapModule
 * @notice  투표권을 등록하는 방식을 유니스왑에 유동성을 공급하는 방법으로 수행합니다. 지정한 토큰과, 가치를 보장하기 위한 페어 토큰을 지정하여 유동성 풀을
 *          만들어 해당 모듈을 통해 공급된 유동성은 투표권으로 계산됩니다. 해당 모듈이 초기화 될 때 유동성의 가격 범위를 지정할 수 있으며, 해당 영역에
 *          대하여 유동성이 추가됩니다.
 * @dev     모든 토큰은 해당 모듈을 사용하는 Council로 전송되어 Pool로 전송되는 과정을 거칩니다.
 * TODO: DEADLINE, SNAPSHOT, FEE Policy, ETH to WETH, Optimization
 */
contract UniswapModule is IModule, IERC165, IUniswapV3MintCallback {
    address public constant UNIV3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address public constant UNIV3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address public constant UNIV3_QUOTOR_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;

    uint256 internal constant DUST_THRESHOLD = 1e6;

    modifier initializer() {
        UniswapStorage.Storage storage s = UniswapStorage.moduleStorage();
        if (s.initialized) revert();
        s.initialized = true;
        _;
    }

    // 모듈 초기화...
    function initialize(bytes calldata data) external initializer {
        address pool;
        address token0;
        address token1;
        uint24 poolFee;
        uint160 sqrtPriceX96;
        int24 lowerTick;
        int24 upperTick;
        uint32 period;
        // 토큰0, 토큰 1, 수수료, 토큰0을 기준 초기 가격, 틱 시작, 틱 종료, undelegate 기간
        (token0, token1, poolFee, sqrtPriceX96, lowerTick, upperTick, period) = abi.decode(
            data,
            (address, address, uint24, uint160, int24, int24, uint32)
        );

        UniswapStorage.Storage storage s = UniswapStorage.moduleStorage();

        // Pool이 만들어지는 과정에서 토큰의 순서는 신경쓰지 않음.
        pool = IUniswapV3Factory(UNIV3_FACTORY).createPool(token0, token1, poolFee);
        IUniswapV3Pool(pool).initialize(sqrtPriceX96);
        int24 tickSpacing = IUniswapV3Pool(pool).tickSpacing();

        // 각 토큰이 Pool과 Router에 무제한 토큰 허용
        safeApprove(token0, UNIV3_ROUTER, type(uint256).max);
        safeApprove(token1, UNIV3_ROUTER, type(uint256).max);

        if (lowerTick > upperTick) {
            (upperTick, lowerTick) = (lowerTick, upperTick);
        }

        unchecked {
            // validate tick
            if ((lowerTick % tickSpacing) != 0)
                lowerTick = lowerTick - (lowerTick % tickSpacing) + (lowerTick < 0 ? -tickSpacing : tickSpacing);
            if ((upperTick % tickSpacing) != 0)
                upperTick = upperTick - (upperTick % tickSpacing) + (upperTick < 0 ? -tickSpacing : tickSpacing);
        }

        if (upperTick <= lowerTick) revert();

        // 포지션 키 저장
        bytes32 positionKey = PositionKey.compute(address(this), lowerTick, upperTick);

        if (token0 > token1) {
            (token0, token1) = (token1, token0);
        }

        (
            s.pool,
            s.PositionKey,
            s.token0,
            s.token1,
            s.lowerTick,
            s.upperTick,
            s.fee,
            s.tickSpacing,
            s.undelegatePeriod
        ) = (pool, positionKey, token0, token1, lowerTick, upperTick, poolFee, tickSpacing, period);
    }

    struct StakeParam {
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
    }

    /**
     * @notice  두 개의 토큰을 이용하여, 투표권으로 변환합니다.
     * @dev     추가되어야 할 수량값은 급격하게 가격이 변동하는 경우를 대비한 값이 입력되어야 합니다.
     * @param   params token0과 token1의 수량과 최소한 추가되어야 할 수량 값
     * TODO: Deadline.
     */
    function stake(StakeParam calldata params) external {
        // 둘 다 0으로 들어오는 경우 실패
        if (params.amount0Desired == 0 && params.amount1Desired == 0) revert();

        // 저장된 데이터 조회
        UniswapStorage.Storage storage s = UniswapStorage.moduleStorage();
        (IUniswapV3Pool pool, bytes32 positionKey, int24 lowerTick, int24 upperTick) = (
            IUniswapV3Pool(s.pool),
            s.PositionKey,
            s.lowerTick,
            s.upperTick
        );

        // 현재 포지션에 있는 유동성
        (uint128 existingLiquidity, , , , ) = pool.positions(positionKey);
        // 현재 Pool의 가격
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(lowerTick);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(upperTick);

        // Pool에 더해야 하는 유동성 계산
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            params.amount0Desired,
            params.amount1Desired
        );

        if (liquidity == 0) revert();

        // 해당 시점에서, Council이 가지고 있는 토큰을 등록함
        (uint256 amount0, uint256 amount1) = pool.mint(
            address(this),
            s.lowerTick,
            s.upperTick,
            liquidity,
            abi.encode(msg.sender)
        );

        // 실제로 추가된 토큰 수량 체크
        if (amount0 < params.amount0Min && amount1 < params.amount1Min) revert();

        // added totalShare
        uint256 existingShareSupply = s.totalSupply;
        uint256 shares;

        if (existingShareSupply == 0) {
            shares = liquidity;
        } else {
            // shares = existingShareSupply * liquidity / existingLiquidity;
            shares = Math.mulDiv(existingShareSupply, liquidity, existingLiquidity);
        }

        s.balanceOf[msg.sender] += shares;
        s.totalSupply += shares;
    }

    struct StakeSingleParam {
        uint256 amountIn;
        uint256 amountInForSwap;
        uint256 amountOutMin;
        bool isAmountIn0;
    }

    /**
     * @notice  하나의 토큰만 예치하여, swap을 통해 희석한 다음 투표권으로 변환합니다.
     * @dev     추가되어야 할 수량값은 급격하게 가격이 변동하는 경우를 대비한 값이 입력되어야 합니다. param에 사용될 값은 `getSingleSidedAmount`
     *          함수로 미리 계산되어야 합니다.
     * @param   params 추가할 총 토큰 수량, 교환할 토큰 수량, 최소로 교환된 토큰 수량, 입력되는 토큰이
     * TODO: Deadline.
     */
    function stake(StakeSingleParam calldata params) external {
        if (params.amountInForSwap > params.amountIn) revert();

        UniswapStorage.Storage storage s = UniswapStorage.moduleStorage();
        (
            IUniswapV3Pool pool,
            address token0,
            address token1,
            uint24 poolFee,
            bytes32 positionKey,
            int24 lowerTick,
            int24 upperTick
        ) = (IUniswapV3Pool(s.pool), s.token0, s.token1, s.fee, s.PositionKey, s.lowerTick, s.upperTick);

        (address tokenIn, address tokenOut) = params.isAmountIn0 ? (token0, token1) : (token1, token0);

        safeTransferFrom(tokenIn, msg.sender, address(this), params.amountIn);

        ISwapRouter v3router = ISwapRouter(UNIV3_ROUTER);

        uint256 amountOut = v3router.exactInput(
            ISwapRouter.ExactInputParams({
                path: abi.encodePacked(tokenIn, poolFee, tokenOut),
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: params.amountInForSwap,
                amountOutMinimum: params.amountOutMin
            })
        );

        (uint128 existingLiquidity, , , , ) = pool.positions(positionKey);
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(lowerTick);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(upperTick);

        (uint256 amount0, uint256 amount1) = params.isAmountIn0
            ? (params.amountIn - params.amountInForSwap, amountOut)
            : (amountOut, params.amountIn - params.amountInForSwap);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            amount0,
            amount1
        );

        if (liquidity == 0) revert();

        // this stage for token transfered
        (amount0, amount1) = pool.mint(address(this), s.lowerTick, s.upperTick, liquidity, abi.encode(this));

        // added totalShare
        uint256 existingShareSupply = s.totalSupply;
        uint256 shares;

        if (existingShareSupply == 0) {
            shares = liquidity;
        } else {
            // shares = existingShareSupply * liquidity / existingLiquidity;
            shares = Math.mulDiv(existingShareSupply, liquidity, existingLiquidity);
        }

        s.balanceOf[msg.sender] += shares;
        s.totalSupply += shares;

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

    function unstake(uint256 shares) external {
        UniswapStorage.Storage storage s = UniswapStorage.moduleStorage();

        s.balanceOf[msg.sender] -= shares;

        (IUniswapV3Pool pool, uint256 currentTotalSupply, bytes32 key, int24 lowerTick, int24 upperTick) = (
            IUniswapV3Pool(s.pool),
            s.totalSupply,
            s.PositionKey,
            s.lowerTick,
            s.upperTick
        );

        (uint128 existingLiquidity, , , , ) = pool.positions(key);
        uint128 removedLiquidity = uint128(Math.mulDiv(existingLiquidity, shares, currentTotalSupply));
        // 유동성 해제,
        (uint256 amount0, uint256 amount1) = pool.burn(lowerTick, upperTick, removedLiquidity);
        // 해제된 유동성 전송
        (amount0, amount1) = pool.collect(msg.sender, lowerTick, upperTick, uint128(amount0), uint128(amount1));

        unchecked {
            s.totalSupply -= shares;
        }
    }

    function getSingleSidedAmount(uint256 amountIn, bool isAmountIn0)
        external
        returns (uint128 liquidity, uint256 amountForSwap)
    {
        UniswapStorage.Storage storage s = UniswapStorage.moduleStorage();

        (address token0, address token1, int24 lowerTick, int24 upperTick, uint24 fee) = (
            s.token0,
            s.token1,
            s.lowerTick,
            s.upperTick,
            s.fee
        );

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
     * @notice BlockNumber를 기준으로, target의 정량적인 투표권을 가져옵니다.
     * @param target 대상이 되는 주소
     * @param blockNumber 기반이 되는 블록 숫자
     * @return votes 투표 권한
     */
    function getPriorVotes(address target, uint256 blockNumber) external view returns (uint256 votes) {}

    /**
     * @notice BlockNumber를 기준으로, target의 투표권을 비율화 하여 가져옵니다.
     * @param target 대상이 되는 주소
     * @param blockNumber 기반이 되는 블록 숫자
     * @return rate 비율
     */
    function getPriorRate(address target, uint256 blockNumber) external view returns (uint256 rate) {}

    /**
     * @notice BlockNumber를 기준으로, 특정 수치의 투표권을 총 투표권의 비율로 계산하는 함수
     * @param votes 계산하고자 하는 투표권한
     * @param blockNumber 기반이 되는 블록 숫자
     */
    function getVotesToRate(uint256 votes, uint256 blockNumber) external view returns (uint256 rate) {}

    /**
     * @notice 입력된 블록을 기준하여, 총 투표권을 반환합니다.
     * @param blockNumber 기반이 되는 블록 숫자
     * @return totalVotes 총 투표권
     */
    function getPriorTotalSupply(uint256 blockNumber) external view returns (uint256 totalVotes) {}

    function supportsInterface(bytes4 interfaceID) external pure returns (bool) {
        return interfaceID == type(IModule).interfaceId || interfaceID == type(IERC165).interfaceId;
    }

    // 총 투표권 수량
    function totalSupply() external view returns (uint256 amount) {
        UniswapStorage.Storage storage s = UniswapStorage.moduleStorage();
        amount = s.totalSupply;
    }

    // 사용자별 현재 투표권
    function balanceOf(address owner) external view returns (uint256 amount) {
        UniswapStorage.Storage storage s = UniswapStorage.moduleStorage();
        amount = s.balanceOf[owner];
    }

    function getToken0() public view returns (address token) {
        UniswapStorage.Storage storage s = UniswapStorage.moduleStorage();
        token = s.token0;
    }

    function getToken1() public view returns (address token) {
        UniswapStorage.Storage storage s = UniswapStorage.moduleStorage();
        token = s.token1;
    }

    function getTokens() public view returns (address token0, address token1) {
        UniswapStorage.Storage storage s = UniswapStorage.moduleStorage();
        (token0, token1) = (s.token0, s.token1);
    }

    function getPool() public view returns (address pool) {
        UniswapStorage.Storage storage s = UniswapStorage.moduleStorage();
        pool = s.pool;
    }

    // Pool에서 fallback으로 호출되는 함수
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external {
        UniswapStorage.Storage storage s = UniswapStorage.moduleStorage();

        address from = abi.decode(data, (address));
        (address pool, address token0, address token1) = (s.pool, s.token0, s.token1);
        if (from != address(this)) {
            if (amount0Owed != 0) safeTransferFrom(token0, from, pool, amount0Owed);
            if (amount1Owed != 0) safeTransferFrom(token1, from, pool, amount1Owed);
        } else if (from == address(this)) {
            if (amount0Owed != 0) safeTransfer(token0, pool, amount0Owed);
            if (amount1Owed != 0) safeTransfer(token1, pool, amount1Owed);
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
}

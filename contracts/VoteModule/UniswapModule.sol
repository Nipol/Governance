/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import {PositionKey} from "@uniswap/v3-periphery/contracts/libraries/PositionKey.sol";
import {LiquidityAmounts} from "./uniswap/LiquidityAmounts.sol";
import "@beandao/contracts/interfaces/IERC165.sol";

import "./uniswap/INonfungiblePositionManager.sol";
import "./uniswap/Math.sol";
import "./uniswap/TickMath.sol";
import "./IModule.sol";

library UniswapStorage {
    bytes32 constant POSITION = keccak256("eth.dao.bean.stakemodule.uniswapv3");

    struct Storage {
        uint256 totalSupply;
        address pool;
        bytes32 PositionKey;
        address token0;
        address token1;
        int24 lowerTick;
        int24 upperTick;
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

contract UniswapModule is IModule, IERC165, IUniswapV3MintCallback {
    address public constant UNIV3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address public constant UNIV3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address public constant UNIV3_POS_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;

    // 모듈 초기화...
    function initialize(bytes calldata data) external {
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

        pool = IUniswapV3Factory(UNIV3_FACTORY).createPool(token0, token1, poolFee);
        IUniswapV3Pool(pool).initialize(sqrtPriceX96);

        int24 tickSpacing = IUniswapV3Pool(pool).tickSpacing();

        unchecked {
            if ((lowerTick % tickSpacing) != 0) lowerTick = lowerTick - (lowerTick % tickSpacing);
            if ((upperTick % tickSpacing) != 0) upperTick = upperTick - (upperTick % tickSpacing);
        }

        (token0, token1) = token0 > token1 ? (token1, token0) : (token0, token1);

        bytes32 positionKey = PositionKey.compute(address(this), lowerTick, upperTick);

        (s.pool, s.PositionKey, s.token0, s.token1, s.lowerTick, s.upperTick, s.undelegatePeriod) = (
            pool,
            positionKey,
            token0,
            token1,
            lowerTick,
            upperTick,
            period
        );
    }

    function stake(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) external {
        if (amount0Desired == 0 && amount1Desired == 0) {
            revert();
        }
        UniswapStorage.Storage storage s = UniswapStorage.moduleStorage();

        (IUniswapV3Pool pool, bytes32 positionKey, int24 lowerTick, int24 upperTick) = (
            IUniswapV3Pool(s.pool),
            s.PositionKey,
            s.lowerTick,
            s.upperTick
        );

        (uint128 existingLiquidity, , , , ) = pool.positions(positionKey);
        // current sqrtPriceX96
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(lowerTick);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(upperTick);

        // addLiquidity
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            amount0Desired,
            amount1Desired
        );

        // this stage for token transfered
        (uint256 amount0, uint256 amount1) = pool.mint(
            address(this),
            s.lowerTick,
            s.upperTick,
            liquidity,
            abi.encode(msg.sender)
        );

        // check slippage
        require(amount0 >= amount0Min && amount1 >= amount1Min, "SLIP");

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

    function supportsInterface(bytes4 interfaceID) external pure returns (bool) {
        return interfaceID == type(IModule).interfaceId || interfaceID == type(IERC165).interfaceId;
    }

    // Pool에서 fallback으로 호출되는 함수
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external {
        UniswapStorage.Storage storage s = UniswapStorage.moduleStorage();

        (address pool, address token0, address token1) = (s.pool, s.token0, s.token1);
        if (amount0Owed != 0) safeTransferFrom(token0, abi.decode(data, (address)), pool, amount0Owed);
        if (amount1Owed != 0) safeTransferFrom(token1, abi.decode(data, (address)), pool, amount1Owed);
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
            mstore(add(freePointer, 4), and(from, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(freePointer, 36), and(to, 0xffffffffffffffffffffffffffffffffffffffff))
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
            mstore(add(freePointer, 4), and(to, 0xffffffffffffffffffffffffffffffffffffffff))
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

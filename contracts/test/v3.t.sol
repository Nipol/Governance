// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// TODO: 토큰 순서 반대인 경우 테스트 작성할 것.

import "ds-test/test.sol";

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "../VoteModule/Uniswap/INonfungiblePositionManager.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {TickMath} from "../VoteModule/Uniswap/TickMath.sol";
import "../VoteModule/Uniswap/Math.sol";
import "../VoteModule/Uniswap/LiquidityAmounts.sol";
import {PositionKey} from "@uniswap/v3-periphery/contracts/libraries/PositionKey.sol";

import "@beandao/contracts/interfaces/IERC165.sol";
import {ERC20, IERC20} from "@beandao/contracts/library/ERC20.sol";
import {ERC2612, IERC2612} from "@beandao/contracts/library/ERC2612.sol";
import {Ownership, IERC173} from "@beandao/contracts/library/Ownership.sol";
import {Multicall, IMulticall} from "@beandao/contracts/library/Multicall.sol";

interface HEVM {
    function prank(address) external;

    function expectRevert(bytes calldata) external;

    function label(address addr, string calldata label) external;

    function warp(uint256) external;

    function roll(uint256) external;
}

contract StandardToken is ERC20, ERC2612, Ownership, Multicall, IERC165 {
    constructor(
        string memory tokenName,
        string memory tokenSymbol,
        uint8 tokenDecimals,
        uint256 amount
    ) ERC20(tokenName, tokenSymbol, tokenDecimals) ERC2612(tokenName, "1") {
        totalSupply = amount;
        balanceOf[msg.sender] = amount;
    }

    function mint(uint256 amount) external {
        balanceOf[msg.sender] += amount;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            // ERC20
            interfaceId == type(IERC20).interfaceId ||
            // ERC173
            interfaceId == type(IERC173).interfaceId ||
            // ERC2612
            interfaceId == type(IERC2612).interfaceId;
    }
}

contract V3Test is DSTest {
    address public constant UNIV3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address public constant UNIV3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address public constant UNIV3_POS_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address public constant UNIV3_QUOTOR_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    HEVM vm = HEVM(HEVM_ADDRESS);

    INonfungiblePositionManager nfpm = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    ISwapRouter v3router = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    IUniswapV3Factory v3Factory = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
    IUniswapV3Pool pool;

    uint24 constant fee = 3000;
    int24 tickSpacing;

    StandardToken token0;
    StandardToken token1;

    function testNewPoolWithToken0() public {
        // Making token
        token0 = new StandardToken("AlleyA", "A", 18, 100000e18);
        token1 = new StandardToken("AlleyB", "B", 18, 0);

        vm.label(address(token0), "AlleyA");
        vm.label(address(token1), "AlleyB");

        emit log_named_address("token0 Address", address(token0));
        emit log_named_address("token1 Address", address(token1));

        // 토큰 순서가 고려된 가격 지표
        // 1 token : 0.01 ~ 0.00001
        uint160 initialPrice = Math.encodePriceSqrt(address(token0), address(token1), 1e18, 0.01 ether);
        uint160 upperPrice = Math.encodePriceSqrt(address(token0), address(token1), 1e18, 10 ether);

        // making pool - 만들어 지면서 토큰 순서 내부적으로 알아서 저장됨.
        pool = IUniswapV3Pool(v3Factory.createPool(address(token0), address(token1), fee));
        pool.initialize(initialPrice);
        tickSpacing = pool.tickSpacing();

        // fee 0.3% with move to 1 tick upper
        int24 lowerTick = TickMath.getTickAtSqrtRatio(initialPrice) +
            (address(token0) > address(token1) ? int24(-tickSpacing) : int24(tickSpacing));
        int24 upperTick = TickMath.getTickAtSqrtRatio(upperPrice) +
            (address(token0) > address(token1) ? int24(-tickSpacing) : int24(tickSpacing));

        // 꼭 해야함... 안하면 안됨... 언제 터질지 모름...
        (lowerTick, upperTick) = Math.validateTicks(tickSpacing, lowerTick, upperTick);

        emit log_named_int("initialPrice", TickMath.getTickAtSqrtRatio(initialPrice));
        emit log_named_int("lowertick", lowerTick);
        emit log_named_int("uppertick", upperTick);

        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(lowerTick);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(upperTick);

        emit log_named_uint("sqrtPrice", sqrtPriceX96);
        emit log_named_uint("lowerPrice", sqrtRatioAX96);
        emit log_named_uint("upperPrice", sqrtRatioBX96);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            address(token0) > address(token1) ? 0 : 100e18,
            address(token0) > address(token1) ? 100e18 : 0
        );
        emit log_named_uint("Liquidity", liquidity);

        // uppertick은 언제나 lowerTick 보다 큽니다
        (uint256 amount0, uint256 amount1) = pool.mint(
            address(this),
            lowerTick > upperTick ? upperTick : lowerTick, // lowerTick
            lowerTick > upperTick ? lowerTick : upperTick, // upperTick
            liquidity,
            abi.encode(address(this))
        );

        emit log_named_uint("amount0", amount0);
        emit log_named_uint("amount1", amount1);

        // Exact Input, tokenIn -> tokenOut
        // in this cases token1 to token0
        token1.mint(10e18);
        token1.approve(UNIV3_ROUTER, 10e18);
        v3router.exactInput(
            ISwapRouter.ExactInputParams({
                path: abi.encodePacked(address(token1), fee, address(token0)),
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: 10e18,
                amountOutMinimum: 0 // 슬리피지
            })
        );
        //93_50189_32381_32578_982

        // Exact Output tokenIn <- tokenOut
        // v3router.exactOutput(
        //     ISwapRouter.ExactOutputParams({
        //         // Path is reversed
        //         path: abi.encodePacked(address(token1), fee, address(token0)),
        //         recipient: address(this),
        //         deadline: block.timestamp,
        //         amountInMaximum: 20e18, // 슬리피지
        //         amountOut: 10000e18
        //     })
        // );
    }

    function testNewPoolWithToken1() public {
        // Making token
        token0 = new StandardToken("AlleyA", "A", 18, 0);
        token1 = new StandardToken("AlleyB", "B", 18, 100000e18);

        vm.label(address(token0), "AlleyA");
        vm.label(address(token1), "AlleyB");

        emit log_named_address("token0 Address", address(token0));
        emit log_named_address("token1 Address", address(token1));

        // 토큰 순서가 고려된 가격 지표
        // 1 token : 0.01 ~ 0.00001
        uint160 initialPrice = Math.encodePriceSqrt(address(token1), address(token0), 1e18, 0.01 ether);
        uint160 upperPrice = Math.encodePriceSqrt(address(token1), address(token0), 1e18, 10 ether);

        // making pool - 만들어 지면서 토큰 순서 내부적으로 알아서 저장됨.
        pool = IUniswapV3Pool(v3Factory.createPool(address(token0), address(token1), fee));
        pool.initialize(initialPrice);
        tickSpacing = pool.tickSpacing();

        // fee 0.3% with move to 1 tick upper
        int24 lowerTick = TickMath.getTickAtSqrtRatio(initialPrice) +
            (address(token0) > address(token1) ? int24(tickSpacing) : int24(-tickSpacing));
        int24 upperTick = TickMath.getTickAtSqrtRatio(upperPrice) +
            (address(token0) > address(token1) ? int24(tickSpacing) : int24(-tickSpacing));

        // 꼭 해야함... 안하면 안됨... 유동성 공급 안됨
        (lowerTick, upperTick) = Math.validateTicks(tickSpacing, lowerTick, upperTick);

        emit log_named_int("initialPrice", TickMath.getTickAtSqrtRatio(initialPrice));
        emit log_named_int("lowertick", lowerTick);
        emit log_named_int("uppertick", upperTick);

        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(lowerTick);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(upperTick);

        emit log_named_uint("sqrtPrice", sqrtPriceX96);
        emit log_named_uint("lowerPrice", sqrtRatioAX96);
        emit log_named_uint("upperPrice", sqrtRatioBX96);

        emit log_named_uint("liquidity amount0", address(token0) > address(token1) ? 0 : 100e18);
        emit log_named_uint("liquidity amount1", address(token0) > address(token1) ? 100e18 : 0);

        // 토큰 순서까지 보장된 토큰 수량이 입력되어야 함.
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            address(token0) > address(token1) ? 100e18 : 0,
            address(token0) > address(token1) ? 0 : 100e18
        );
        emit log_named_uint("Liquidity", liquidity);

        // uppertick은 언제나 lowerTick 보다 큽니다
        (uint256 amount0, uint256 amount1) = pool.mint(
            address(this),
            lowerTick > upperTick ? upperTick : lowerTick, // lowerTick
            lowerTick > upperTick ? lowerTick : upperTick, // upperTick
            liquidity,
            abi.encode(address(this))
        );

        emit log_named_uint("amount0", amount0);
        emit log_named_uint("amount1", amount1);

        // Exact Input, tokenIn -> tokenOut
        // in this cases token1 to token0
        token0.mint(10e18);
        token0.approve(UNIV3_ROUTER, 10e18);
        v3router.exactInput(
            ISwapRouter.ExactInputParams({
                path: abi.encodePacked(address(token0), fee, address(token1)),
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: 10e18,
                amountOutMinimum: 0 // 슬리피지
            })
        );
        //93_50189_32381_32578_982

        // Exact Output tokenIn <- tokenOut
        // v3router.exactOutput(
        //     ISwapRouter.ExactOutputParams({
        //         // Path is reversed
        //         path: abi.encodePacked(address(token1), fee, address(token0)),
        //         recipient: address(this),
        //         deadline: block.timestamp,
        //         amountInMaximum: 20e18, // 슬리피지
        //         amountOut: 10000e18
        //     })
        // );
    }

    function testNewPoolWithBaseToken() public {
        // Deploy token
        token1 = new StandardToken("AlleyB", "A", 18, 100000e18);
        token0 = new StandardToken("AlleyA", "B", 18, 100000e18);

        vm.label(address(token0), "AlleyA");
        vm.label(address(token1), "AlleyB");

        bool isToken0Base = false;

        // 베이스 토큰의 초기 가격을 pair를 통해서 설정합니다.
        uint160 initialPrice = Math.encodePriceSqrt(
            isToken0Base ? address(token0) : address(token1),
            isToken0Base ? address(token1) : address(token0),
            1e18,
            0.01 ether
        );

        // 베이스 토큰의 최대 가격을 pair를 통해서 설정합니다.
        uint160 upperPrice = Math.encodePriceSqrt(
            isToken0Base ? address(token0) : address(token1),
            isToken0Base ? address(token1) : address(token0),
            1e18,
            10 ether
        );

        pool = IUniswapV3Pool(v3Factory.createPool(address(token0), address(token1), fee));
        pool.initialize(initialPrice);
        tickSpacing = pool.tickSpacing();

        // fee 0.3% with move to 1 tick upper
        int24 lowerTick = TickMath.getTickAtSqrtRatio(initialPrice);
        int24 upperTick = TickMath.getTickAtSqrtRatio(upperPrice);
        emit log_named_int("lowertick", lowerTick);
        emit log_named_int("uppertick", upperTick);

        (upperTick, lowerTick) = lowerTick > upperTick
            ? (
                lowerTick + (lowerTick > 0 ? int24(-tickSpacing) : int24(tickSpacing)),
                upperTick + (upperTick > 0 ? int24(tickSpacing) : int24(-tickSpacing))
            )
            : (
                upperTick + (upperTick > 0 ? int24(tickSpacing) : int24(-tickSpacing)),
                lowerTick + (lowerTick > 0 ? int24(-tickSpacing) : int24(tickSpacing))
            );

        // 꼭 해야함... 안하면 안됨... 유동성 공급 안됨
        (lowerTick, upperTick) = Math.validateTicks(tickSpacing, lowerTick, upperTick);

        emit log_named_int("initialPrice", TickMath.getTickAtSqrtRatio(initialPrice));
        emit log_named_int("lowertick", lowerTick);
        emit log_named_int("uppertick", upperTick);

        require(lowerTick < upperTick);

        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(lowerTick);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(upperTick);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            initialPrice,
            sqrtRatioAX96,
            sqrtRatioBX96,
            (!isToken0Base && !(address(token0) > address(token1))) ? 0 : 100e18, // false
            (!isToken0Base && !(address(token0) > address(token1))) ? 100e18 : 0
        );

        emit log_named_uint("Liquidity", liquidity);

        (uint256 amount0, uint256 amount1) = pool.mint(
            address(this),
            lowerTick,
            upperTick,
            liquidity,
            abi.encode(address(this))
        );

        emit log_named_uint("added amount0", amount0);
        emit log_named_uint("added amount1", amount1);

        // token0.approve(UNIV3_ROUTER, 10e18);
        // token1.approve(UNIV3_ROUTER, 10e18);

        // // Exact Output tokenIn <- tokenOut
        // v3router.exactOutput(
        //     ISwapRouter.ExactOutputParams({
        //         // Path is reversed
        //         path: abi.encodePacked(address(token0), fee, address(token1)),
        //         recipient: address(this),
        //         deadline: block.timestamp,
        //         amountInMaximum: 100e18, // 슬리피지
        //         amountOut: 1e18
        //     })
        // );
        // // 1e18 : 0.01016_26726_07389_024
    }

    // 일반적인 경우 transferFrom으로 구현되어야 함.
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata
    ) external {
        (address token0Addr, address token1Addr) = address(token0) > address(token1)
            ? (address(token1), address(token0))
            : (address(token0), address(token1));

        emit log_string("uniswapV3MintCallback");
        if (amount0Owed != 0) {
            emit log_named_address("token 0", address(token0Addr));
            emit log_named_uint("token 0 amount", amount0Owed);
            safeTransfer(address(token0Addr), address(pool), amount0Owed);
        }
        if (amount1Owed != 0) {
            emit log_named_address("token 1", address(token1Addr));
            emit log_named_uint("token 1 amount", amount1Owed);
            safeTransfer(address(token1Addr), address(pool), amount1Owed);
        }
    }

    // function testOneSideLiquidityToken0() public {
    //     // Making token
    //     StandardToken token0 = new StandardToken("AlleyA", "A", 18, 100000e18);
    //     StandardToken token1 = new StandardToken("AlleyB", "B", 18, 0);

    //     // for debug
    //     emit log_address(address(token0));
    //     emit log_address(address(token1));

    //     // making pool
    //     pool = IUniswapV3Pool(v3Factory.createPool(address(token0), address(token1), fee));

    //     // 범위 시작 가격 진짜 개수당 가격을 입력하는 거임... 1개에 0.01 이더...
    //     // 주소 align 알아서 해줌
    //     uint160 sqrt = Math.encodePriceSqrt(address(token0), address(token1), 1e18, 10 ether);
    //     //
    //     // uint160 sqrtTarget = Math.encodePriceSqrt(address(token0), address(token1), 1e18, 12 ether);
    //     // emit log_named_uint("initial sqrtPriceX96: ", sqrt);
    //     // emit log_named_int("tick from sqrtPriceX96: ", TickMath.getTickAtSqrtRatio(sqrt));

    //     // 1000 token0 = 1 token1
    //     // uint160 sqrtPriceX96 = Math.encodePriceSqrt(address(token0), address(token1), 1000e18, 10e18);

    //     // 0x13ead562000000000000000000000000420000000000000000000000000000000000000600000000000000000000000060f45b32cfdef80b745baead605117e2a7153dfe0000000000000000000000000000000000000000000000000000000000000bb80000000000000000000000000000000000000009ffffdb095fbe08e5cf63390d
    //     pool.initialize(sqrt);
    //     tickSpacing = pool.tickSpacing();

    //     // Add liquidity to pool
    //     // Get tick spacing
    //     (, int24 curTick, , , , , ) = pool.slot0();

    //     // 최소 tick을 한 단계 올림.
    //     (int24 lowerTick, int24 upperTick) = Math.validateTicks(tickSpacing, -887272, curTick - tickSpacing);

    //     emit log_named_int("current Tick: ", curTick);
    //     // emit log_named_int("current Tick validate: ", curTick % tickSpacing);
    //     // emit log_named_int("Tick Spacing: ", tickSpacing);
    //     emit log_named_int("lower Tick: ", lowerTick);
    //     // emit log_named_int("lower Tick validate: ", lowerTick % tickSpacing);
    //     // emit log_named_uint("price from lower Tick: ", TickMath.getSqrtRatioAtTick(lowerTick));
    //     emit log_named_int("upper Tick: ", upperTick);
    //     // emit log_named_int("upper Tick validate: ", upperTick % tickSpacing);
    //     // emit log_named_uint("price from upper Tick: ", TickMath.getSqrtRatioAtTick(upperTick));

    //     token0.approve(address(nfpm), type(uint256).max);

    //     token1.approve(address(nfpm), type(uint256).max);

    //     // uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(lowerTick);
    //     // uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(upperTick);

    //     // uint128 liquidity = getLiquidityForAmounts(sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, 0, 100000e18);

    //     // emit log_uint(liquidity);

    //     //mine (fail)
    //     //0x88316456
    //     //00000000000000000000000018669eb6c7dfc21dcdb787feb4b3f1ebb3172400
    //     //0000000000000000000000000c7bbb021d72db4ffba37bdf4ef055eecdbc0a29
    //     //0000000000000000000000000000000000000000000000000000000000000bb8
    //     //ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff4c78 fee + lower
    //     //00000000000000000000000000000000000000000000000000000000000d8978 upper
    //     //00000000000000000000000000000000000000000000152d02c7e14af6800000 amount0
    //     //0000000000000000000000000000000000000000000000000000000000000000 amount1
    //     //0000000000000000000000000000000000000000000000000000000000000000
    //     //0000000000000000000000000000000000000000000000000000000000000000
    //     //00000000000000000000000062d69f6867a0a084c6d313943dc22023bc263691
    //     //00000000000000000000000000000000000000000000000000000000626f5361

    //     // mine2
    //     //0x88316456
    //     //0000000000000000000000000c7bbb021d72db4ffba37bdf4ef055eecdbc0a29
    //     //00000000000000000000000018669eb6c7dfc21dcdb787feb4b3f1ebb3172400
    //     //0000000000000000000000000000000000000000000000000000000000000bb8
    //     //ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff4c78
    //     //00000000000000000000000000000000000000000000000000000000000d8978
    //     //0000000000000000000000000000000000000000000000000000000000000000 amount0
    //     //00000000000000000000000000000000000000000000152d02c7e14af67ffff7 amount1
    //     //0000000000000000000000000000000000000000000000000000000000000000 min0
    //     //00000000000000000000000000000000000000000000152d02c7e14af67ffff7 min1
    //     //00000000000000000000000062d69f6867a0a084c6d313943dc22023bc263691 recei
    //     //00000000000000000000000000000000000000000000000000000000626f7677 timestamp

    //     // uniswap (onchain)
    //     //0x88316456
    //     //0000000000000000000000004200000000000000000000000000000000000006
    //     //00000000000000000000000060f45b32cfdef80b745baead605117e2a7153dfe
    //     //0000000000000000000000000000000000000000000000000000000000000bb8
    //     //fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffef23c
    //     //000000000000000000000000000000000000000000000000000000000000b3c4 upper
    //     //0000000000000000000000000000000000000000000000000000000000000000 amount0
    //     //00000000000000000000000000000000000000000000152d02c7e14af67ffff7 amount1
    //     //0000000000000000000000000000000000000000000000000000000000000000 min0
    //     //00000000000000000000000000000000000000000000152d02c7e14af67ffff7 min1
    //     //0000000000000000000000002e6be9855a3bf02c73ba74b7d756a63db7762238
    //     //00000000000000000000000000000000000000000000000000000000625a6da3

    //     //uniswap (onchain)
    //     //0x88316456
    //     //0000000000000000000000003e550a5697e146dd52fabc4533f67af73af171df token
    //     //0000000000000000000000004200000000000000000000000000000000000006 Dai
    //     //0000000000000000000000000000000000000000000000000000000000000bb8
    //     //ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff4c3c
    //     //0000000000000000000000000000000000000000000000000000000000021bc4
    //     //00000000000000000000000000000000000000000000152d02c7e14af67ffff7
    //     //0000000000000000000000000000000000000000000000000000000000000000
    //     //00000000000000000000000000000000000000000000152d02c7e14af67ffff7
    //     //0000000000000000000000000000000000000000000000000000000000000000
    //     //0000000000000000000000002e6be9855a3bf02c73ba74b7d756a63db7762238
    //     //00000000000000000000000000000000000000000000000000000000625a6eda

    //     //uniswap (onchain) - liquidity token upper
    //     //0x88316456
    //     //0000000000000000000000007f5c764cbc14f9669b88837ca1490cca17c31607 USDT
    //     //000000000000000000000000b316bfb654cf4b0fc0592bbb703f8590bb0975fb token
    //     //0000000000000000000000000000000000000000000000000000000000000bb8 fee
    //     //00000000000000000000000000000000000000000000000000000000000167c4 lower
    //     //000000000000000000000000000000000000000000000000000000000003dd4c upper
    //     //0000000000000000000000000000000000000000000000000000000000000000 amount0
    //     //00000000000000000000000000000000000000000000152d02c7e14af67d3b4a amount1
    //     //0000000000000000000000000000000000000000000000000000000000000000 min0
    //     //00000000000000000000000000000000000000000000152d02c7e14af67d3b4a min1
    //     //0000000000000000000000002e6be9855a3bf02c73ba74b7d756a63db7762238 recei
    //     //00000000000000000000000000000000000000000000000000000000626fc833

    //     //uniswap (onchain) - liquidity token upper 2
    //     //0x88316456
    //     //0000000000000000000000004911b761993b9c8c0d14ba2d86902af6b0074f5b
    //     //00000000000000000000000078011ff2a50a0225333671072f055d8658d6ba7e
    //     //0000000000000000000000000000000000000000000000000000000000000bb8
    //     //fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffd3078
    //     //ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffa600
    //     //0000000000000000000000000000000000000000000000000000000000000000
    //     //00000000000000000000000000000000000000000000152d02c7e14af6800000
    //     //0000000000000000000000000000000000000000000000000000000000000000
    //     //00000000000000000000000000000000000000000000152d02c7e14af6800000
    //     //0000000000000000000000002e6be9855a3bf02c73ba74b7d756a63db7762238
    //     //00000000000000000000000000000000000000000000000000000000626fd4ea

    //     // emit log_named_int("lower", -int24(0xd3078));
    //     // emit log_named_int("upper", -int24(0xa600));

    //     // mine
    //     //0000000000000000000000000c7bbb021d72db4ffba37bdf4ef055eecdbc0a29
    //     //00000000000000000000000018669eb6c7dfc21dcdb787feb4b3f1ebb3172400
    //     //0000000000000000000000000000000000000000000000000000000000000bb8
    //     //000000000000000000000000000000000000000000000000000000000000b422
    //     //00000000000000000000000000000000000000000000000000000000000d89b4
    //     //0000000000000000000000000000000000000000000000000000000000000000
    //     //00000000000000000000000000000000000000000000152d02c7e14af67ffff7
    //     //0000000000000000000000000000000000000000000000000000000000000000
    //     //00000000000000000000000000000000000000000000152d02c7e14af67ffff7
    //     //00000000000000000000000062d69f6867a0a084c6d313943dc22023bc263691
    //     //00000000000000000000000000000000000000000000000000000000626fc1ed

    //     // 일단 낮은 순서대로
    //     nfpm.mint(
    //         INonfungiblePositionManager.MintParams({
    //             token0: pool.token0(),
    //             token1: pool.token1(),
    //             fee: fee,
    //             tickLower: lowerTick,
    //             tickUpper: upperTick,
    //             amount0Desired: pool.token0() == address(token0) ? 100000e18 : 0e18,
    //             amount1Desired: pool.token0() == address(token1) ? 100000e18 : 0e18,
    //             amount0Min: 0e18,
    //             amount1Min: 0e18,
    //             recipient: address(this),
    //             deadline: block.timestamp
    //         })
    //     );
    // }

    // function testPartialLiquidityExistTokenDai() public {
    //     StandardToken token0 = new StandardToken("AlleyA", "A", 18, 100000e18);
    //     StandardToken token1 = StandardToken(0x6B175474E89094C44Da98b954EedeAC495271d0F);

    //     emit log_address(address(token0));
    //     emit log_address(address(token1));

    //     pool = IUniswapV3Pool(v3Factory.createPool(address(token0), address(token1), fee));

    //     // 범위 시작 가격 진짜 개수당 가격을 입력하는 거임... 1개에 10 Dai
    //     uint160 sqrt = Math.encodePriceSqrt(address(token0), address(token1), 1e18, 10 ether);
    //     emit log_uint(sqrt);
    //     //
    //     // uint160 sqrtTarget = Math.encodePriceSqrt(address(token0), address(token1), 1e18, 12 ether);
    //     // emit log_named_uint("initial sqrtPriceX96: ", sqrt);
    //     // emit log_named_int("tick from sqrtPriceX96: ", TickMath.getTickAtSqrtRatio(sqrt));

    //     // 1000 token0 = 1 token1
    //     // uint160 sqrtPriceX96 = Math.encodePriceSqrt(address(token0), address(token1), 1000e18, 10e18);

    //     pool.initialize(sqrt);
    //     tickSpacing = pool.tickSpacing();

    //     // Add liquidity to pool
    //     // Get tick spacing
    //     (uint160 sqrtPriceX96, int24 curTick, , , , , ) = pool.slot0();

    //     // 최소 tick을 한 단계 올림.
    //     (int24 lowerTick, int24 upperTick) = Math.validateTicks(
    //         tickSpacing,
    //         curTick + tickSpacing,
    //         int24(887272) - tickSpacing
    //     );

    //     // emit log_named_int("current Tick: ", curTick);
    //     // emit log_named_int("current Tick validate: ", curTick % tickSpacing);
    //     // emit log_named_int("Tick Spacing: ", tickSpacing);
    //     // emit log_named_int("lower Tick: ", lowerTick);
    //     // emit log_named_int("lower Tick validate: ", lowerTick % tickSpacing);
    //     // emit log_named_uint("price from lower Tick: ", TickMath.getSqrtRatioAtTick(lowerTick));
    //     // emit log_named_int("upper Tick: ", upperTick);
    //     // emit log_named_int("upper Tick validate: ", upperTick % tickSpacing);
    //     // emit log_named_uint("price from upper Tick: ", TickMath.getSqrtRatioAtTick(upperTick));

    //     token0.approve(address(nfpm), type(uint256).max);
    //     token0.approve(address(v3router), type(uint256).max);
    //     token0.approve(address(pool), type(uint256).max);

    //     token1.approve(address(nfpm), type(uint256).max);
    //     token1.approve(address(v3router), type(uint256).max);
    //     token1.approve(address(pool), type(uint256).max);

    //     nfpm.mint(
    //         INonfungiblePositionManager.MintParams({
    //             token0: pool.token0(),
    //             token1: pool.token1(),
    //             fee: fee,
    //             tickLower: lowerTick,
    //             tickUpper: upperTick,
    //             amount0Desired: 100000e18,
    //             amount1Desired: 0e18,
    //             amount0Min: 0e18,
    //             amount1Min: 0e18,
    //             recipient: address(this),
    //             deadline: block.timestamp
    //         })
    //     );
    // }

    // function testPartialLiquidityExistTokenWETH() public {
    //     StandardToken token0 = new StandardToken("AlleyA", "A", 18, 100000e18);
    //     StandardToken token1 = StandardToken(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    //     emit log_address(address(token0));
    //     emit log_address(address(token1));

    //     pool = IUniswapV3Pool(v3Factory.createPool(address(token0), address(token1), fee));

    //     // 범위 시작 가격 진짜 개수당 가격을 입력하는 거임... 1개에 10 Dai
    //     uint160 sqrt = Math.encodePriceSqrt(address(token0), address(token1), 1e18, 0.01 ether);
    //     emit log_uint(sqrt);

    //     //
    //     // uint160 sqrtTarget = Math.encodePriceSqrt(address(token0), address(token1), 1e18, 12 ether);
    //     // emit log_named_uint("initial sqrtPriceX96: ", sqrt);
    //     // emit log_named_int("tick from sqrtPriceX96: ", TickMath.getTickAtSqrtRatio(sqrt));

    //     // 1000 token0 = 1 token1
    //     // uint160 sqrtPriceX96 = Math.encodePriceSqrt(address(token0), address(token1), 1000e18, 10e18);

    //     pool.initialize(sqrt);
    //     tickSpacing = pool.tickSpacing();

    //     // Add liquidity to pool
    //     // Get tick spacing
    //     (, int24 curTick, , , , , ) = pool.slot0();

    //     // 최소 tick을 한 단계 올림.
    //     (int24 lowerTick, int24 upperTick) = Math.validateTicks(
    //         tickSpacing,
    //         curTick + tickSpacing,
    //         int24(887272) - tickSpacing
    //     );

    //     emit log_named_int("current Tick: ", curTick);
    //     emit log_named_int("current Tick validate: ", curTick % tickSpacing);
    //     emit log_named_int("Tick Spacing: ", tickSpacing);
    //     emit log_named_int("lower Tick: ", lowerTick);
    //     emit log_named_int("lower Tick validate: ", lowerTick % tickSpacing);
    //     // emit log_named_uint("price from lower Tick: ", TickMath.getSqrtRatioAtTick(lowerTick));
    //     emit log_named_int("upper Tick: ", upperTick);
    //     emit log_named_int("upper Tick validate: ", upperTick % tickSpacing);
    //     // emit log_named_uint("price from upper Tick: ", TickMath.getSqrtRatioAtTick(upperTick));

    //     token0.approve(address(nfpm), type(uint256).max);
    //     token0.approve(address(v3router), type(uint256).max);
    //     token0.approve(address(pool), type(uint256).max);

    //     token1.approve(address(nfpm), type(uint256).max);
    //     token1.approve(address(v3router), type(uint256).max);
    //     token1.approve(address(pool), type(uint256).max);

    //     nfpm.mint(
    //         INonfungiblePositionManager.MintParams({
    //             token0: pool.token0(),
    //             token1: pool.token1(),
    //             fee: fee,
    //             tickLower: lowerTick,
    //             tickUpper: upperTick,
    //             amount0Desired: 100000e18,
    //             amount1Desired: 0e18,
    //             amount0Min: 0e18,
    //             amount1Min: 0e18,
    //             recipient: address(this),
    //             deadline: block.timestamp
    //         })
    //     );
    // }

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

    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) external pure returns (bytes4) {
        return 0x150b7a02;
    }
}

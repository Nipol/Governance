/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../Council.sol";
import "../mocks/Deployer.sol";
import "../mocks/GovernanceMock.sol";
import "../mocks/ERC20.sol";
import "../mocks/ProxyMock.sol";
import "UniswapV3Pack/v3-core/interfaces/IUniswapV3Pool.sol";
import "UniswapV3Pack/v3-core/interfaces/IUniswapV3Factory.sol";
import "UniswapV3Pack/v3-periphery/interfaces/ISwapRouter.sol";

contract CouncilExistPoolTest is Test {
    uint16 proposalQuorum = 1000; // 10%
    uint16 voteQuorum = 7000; // 70%
    uint16 emergencyQuorum = 9500; // 95%
    uint32 voteStartDelay = 0; // 투표 시작 딜레이 0일
    uint32 votePeriod = 604800; // 투표 기간 7일
    uint32 voteChangableDelay = 345600; // 투표 변경 가능한 기간 4일
    uint32 withdrawDelay = 7 days;
    address public constant UNIV3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    uint24 constant fee = 3000;
    StandardToken token0;
    StandardToken token1;
    Council public c;

    uint160 initialPrice;
    uint160 upperPrice;
    int24 lowerTick;
    int24 upperTick;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"));
        token0 = new StandardToken("bean the token", "BEAN", 18);
        token1 = new StandardToken("Wrapped Ether", "WETH", 18);
        initialPrice = Math.encodePriceSqrt(address(token0), address(token1), 1e18, 0.01 ether);

        address pool = IUniswapV3Factory(UNIV3_FACTORY).createPool(address(token0), address(token1), fee);
        IUniswapV3Pool(pool).initialize(initialPrice);

        // 베이스 토큰의 최대 가격을 pair를 통해서 설정합니다.
        upperPrice = Math.encodePriceSqrt(address(token0), address(token1), 1e18, 10 ether);

        // 최소 tick과 최대 tick
        lowerTick =
            TickMath.getTickAtSqrtRatio(initialPrice) +
            (address(token0) > address(token1) ? int24(-60) : int24(60));
        upperTick = TickMath.getTickAtSqrtRatio(upperPrice);

        if (lowerTick > upperTick) {
            (lowerTick, upperTick) = (upperTick, lowerTick);
        }
    }

    function testExistedPool() public {
        c = new Council(
            proposalQuorum,
            voteQuorum,
            emergencyQuorum,
            voteStartDelay,
            votePeriod,
            voteChangableDelay,
            withdrawDelay,
            address(token0),
            address(token1),
            3000,
            initialPrice,
            lowerTick,
            upperTick
        );
    }

    function testReversedToken() public {
        c = new Council(
            proposalQuorum,
            voteQuorum,
            emergencyQuorum,
            voteStartDelay,
            votePeriod,
            voteChangableDelay,
            withdrawDelay,
            address(token1),
            address(token0),
            3000,
            initialPrice,
            lowerTick,
            upperTick
        );
    }

    function testReversedTick() public {
        c = new Council(
            proposalQuorum,
            voteQuorum,
            emergencyQuorum,
            voteStartDelay,
            votePeriod,
            voteChangableDelay,
            withdrawDelay,
            address(token0),
            address(token1),
            3000,
            initialPrice,
            upperTick,
            lowerTick
        );
    }
}

/**
 * @notice 유니스왑 모듈을 배포하는데 사용됩니다.
 */
abstract contract ZeroState is Test {
    address public constant UNIV3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    uint24 constant fee = 3000;

    uint16 proposalQuorum = 1000; // 10%
    uint16 voteQuorum = 7000; // 70%
    uint16 emergencyQuorum = 9500; // 95%
    uint32 voteStartDelay = 0; // 투표 시작 딜레이 0일
    uint32 votePeriod = 604800; // 투표 기간 7일
    uint32 voteChangableDelay = 345600; // 투표 변경 가능한 기간 4일
    uint32 withdrawDelay = 7 days;

    Council public c;
    StandardToken token0;
    StandardToken token1;
    address pm;
    address base;

    function setUp() public virtual {
        vm.createSelectFork(vm.rpcUrl("mainnet"));
        token0 = new StandardToken("bean the token", "BEAN", 18);
        token1 = new StandardToken("Wrapped Ether", "WETH", 18);
        base = address(token0);

        // 베이스 토큰의 초기 가격을 pair를 통해서 설정합니다.
        uint160 initialPrice = Math.encodePriceSqrt(address(token0), address(token1), 1e18, 0.01 ether);

        // 베이스 토큰의 최대 가격을 pair를 통해서 설정합니다.
        uint160 upperPrice = Math.encodePriceSqrt(address(token0), address(token1), 1e18, 10 ether);

        // 최소 tick과 최대 tick
        int24 lowerTick = TickMath.getTickAtSqrtRatio(initialPrice) +
            (address(token0) > address(token1) ? int24(-60) : int24(60));
        int24 upperTick = TickMath.getTickAtSqrtRatio(upperPrice);

        if (lowerTick > upperTick) {
            (lowerTick, upperTick) = (upperTick, lowerTick);
        }

        c = new Council(
            proposalQuorum,
            voteQuorum,
            emergencyQuorum,
            voteStartDelay,
            votePeriod,
            voteChangableDelay,
            withdrawDelay,
            address(token0),
            address(token1),
            3000,
            initialPrice,
            lowerTick,
            upperTick
        );
        vm.label(address(c), "Council");
        vm.label(address(this), "Caller");
        vm.label(address(token0), "BaseToken");
        vm.label(address(token1), "PairToken");

        token0.mint(101e18);
        token0.approve(address(c), type(uint256).max);
        token0.approve(UNIV3_ROUTER, type(uint256).max);

        token1.mint(10e18);
        token1.approve(address(c), type(uint256).max);
        token1.approve(UNIV3_ROUTER, type(uint256).max);

        address pool = c.pool();
        vm.label(pool, "bean:WETH Pool");
        vm.label(0x1F98431c8aD98523631AE4a59f267346ea31F984, "Uniswap Factory");
        vm.label(0xE592427A0AEce92De3Edee1F18E0157C05861564, "Uniswap Router");
    }
}

contract CouncilDeployTest is ZeroState {
    function setUp() public override {
        super.setUp();
    }

    function testName() public {
        assertEq(c.name(), "Council");
    }

    function testSlot() public {
        (
            uint16 _proposalQuorum,
            uint16 _voteQuorum,
            uint16 _emergencyQuorum,
            uint32 _voteStartDelay,
            uint32 _votePeriod,
            uint32 _voteChangableDelay,
            uint32 _withdrawDelay
        ) = c.slot();

        assertEq(_proposalQuorum, proposalQuorum);
        assertEq(_voteQuorum, voteQuorum);
        assertEq(_emergencyQuorum, emergencyQuorum);
        assertEq(_voteStartDelay, voteStartDelay);
        assertEq(_votePeriod, votePeriod);
        assertEq(_voteChangableDelay, voteChangableDelay);
        assertEq(_withdrawDelay, withdrawDelay);
    }

    function testTokens() public {
        (address _token0, address _token1) = c.getTokens();
        assertEq(_token0, address(token0) > address(token1) ? address(token1) : address(token0));
        assertEq(_token1, address(token0) > address(token1) ? address(token0) : address(token1));
    }

    function testTotalSupply() public {
        assertEq(c.totalSupply(), 0);
    }

    function testStake__BaseToken() public {
        (address _token0, ) = c.getTokens();
        (bool isToken0Base, bool isToken1Base) = base == _token0 ? (true, false) : (false, true);

        c.stake(
            ICouncil.StakeParam({
                amount0Desired: isToken0Base ? 100e18 : 0,
                amount1Desired: isToken1Base ? 100e18 : 0,
                amount0Min: isToken0Base ? 100e18 : 0,
                amount1Min: isToken1Base ? 100e18 : 0,
                deadline: block.timestamp
            })
        );
        assertEq(c.balanceOf(address(this)), 10_34448_07667_71197_919);
        assertEq(c.totalSupply(), 10_34448_07667_71197_919);
    }

    function testStake__PairToken() public {
        (address _token0, ) = c.getTokens();
        (bool isToken0Base, bool isToken1Base) = base == _token0 ? (true, false) : (false, true);

        vm.expectRevert();
        c.stake(
            ICouncil.StakeParam({
                amount0Desired: !isToken0Base ? 100e18 : 0,
                amount1Desired: !isToken1Base ? 100e18 : 0,
                amount0Min: !isToken0Base ? 100e18 : 0,
                amount1Min: !isToken1Base ? 100e18 : 0,
                deadline: block.timestamp
            })
        );
    }

    function testStakeAndSwap() public {
        (address _token0, address _token1) = c.getTokens();
        (bool isToken0Base, bool isToken1Base, address pair) = base == _token0
            ? (true, false, _token1)
            : (false, true, _token0);

        c.stake(
            ICouncil.StakeParam({
                amount0Desired: isToken0Base ? 100e18 : 0,
                amount1Desired: isToken1Base ? 100e18 : 0,
                amount0Min: isToken0Base ? 100e18 : 0,
                amount1Min: isToken1Base ? 100e18 : 0,
                deadline: block.timestamp
            })
        );
        assertEq(c.balanceOf(address(this)), 10_34448_07667_71197_919);
        assertEq(c.totalSupply(), 10_34448_07667_71197_919);

        ISwapRouter v3router = ISwapRouter(UNIV3_ROUTER);

        // Exact Output tokenIn <- tokenOut
        v3router.exactOutput(
            ISwapRouter.ExactOutputParams({
                // Path is reversed
                path: abi.encodePacked(base, fee, pair),
                recipient: address(this),
                deadline: block.timestamp,
                amountInMaximum: 2e18, // 슬리피지
                amountOut: 1e18
            })
        );
    }

    function testCallUniswapCallbackFromEOA() public {
        vm.expectRevert();
        c.uniswapV3MintCallback(0, 0, new bytes(0));
    }

    function testCallUniswapCallbackFromPool() public {
        vm.prank(c.pool());
        c.uniswapV3MintCallback(0, 0, abi.encode(address(1234)));
    }
}

abstract contract StakedState is ZeroState {
    function setUp() public virtual override {
        super.setUp();
        (address _token0, ) = c.getTokens();
        (bool isToken0Base, bool isToken1Base) = base == _token0 ? (true, false) : (false, true);

        c.stake(
            ICouncil.StakeParam({
                amount0Desired: isToken0Base ? 100e18 : 0,
                amount1Desired: isToken1Base ? 100e18 : 0,
                amount0Min: isToken0Base ? 100e18 : 0,
                amount1Min: isToken1Base ? 100e18 : 0,
                deadline: block.timestamp
            })
        );
    }
}

contract CouncilStakedTest is StakedState {
    function testCalculatePairAmountForSwap() public {
        (address _token0, ) = c.getTokens();
        (bool isToken0Base, ) = base == _token0 ? (true, false) : (false, true);
        // Add liquidity Single Side with PairToken
        uint256 amountIn = 10e18;
        (, uint256 amountForSwap) = c.getSingleSidedAmount(amountIn, isToken0Base ? false : true);
        assertEq(amountForSwap, 2_61553_46757_19999_310);

        // check
        // c.stake(
        //     Council.StakeSingleParam({
        //         amountIn: amountIn,
        //         amountInForSwap: amountForSwap,
        //         amountOutMin: 0, // ignore slippage
        //         isAmountIn0: isToken0Base ? false : true
        //     })
        // );
        // bool isToken0Base = address(token1) > address(token0);
        // (address base, address pair) = isToken0Base
        //     ? (address(token0), address(token1))
        //     : (address(token1), address(token0));
        // address pool = c.getPool();
        // ISwapRouter v3router = ISwapRouter(UNIV3_ROUTER);
        // // Exact Input pair -> base
        // uint256 tokenBaseOut = v3router.exactInput(
        //     ISwapRouter.ExactInputParams({
        //         path: abi.encodePacked(address(pair), fee, address(base)),
        //         recipient: address(this),
        //         deadline: block.timestamp,
        //         amountIn: amountForSwap,
        //         amountOutMinimum: 0
        //     })
        // );
        // c.stake(tokenBaseOut, amountIn - amountForSwap, 0, 0);
        // // Add liquidity Single Side with BaseToken
        // amountIn = 1e18;
        // (liquidity, amountForSwap) = c.getSingleSidedAmount(amountIn, true);
        // // Exact Input pair -> base
        // tokenBaseOut = v3router.exactInput(
        //     ISwapRouter.ExactInputParams({
        //         path: abi.encodePacked(address(base), fee, address(pair)),
        //         recipient: address(this),
        //         deadline: block.timestamp,
        //         amountIn: amountForSwap,
        //         amountOutMinimum: 0
        //     })
        // );
        // // 토큰을 어떤 걸 넣는지에 따라 순서 조정되면 됨.
        // c.stake(amountIn - amountForSwap, tokenBaseOut, 0, 0);
        // emit log_named_uint("token0 balanceOf(this)", token0.balanceOf(address(this)));
        // emit log_named_uint("token1 balanceOf(this)", token1.balanceOf(address(this)));
        // emit log_named_uint("token0 balanceOf(Pool)", token0.balanceOf(pool));
        // emit log_named_uint("token1 balanceOf(Pool)", token1.balanceOf(pool));
    }

    function testSingleSidedStake__PairToken() public {
        uint256 amountForSwap;
        uint256 amountIn;
        (address _token0, ) = c.getTokens();
        (bool isToken0Base, ) = base == _token0 ? (true, false) : (false, true);
        amountIn = 10e18;

        // Add liquidity Single Side with PairToken
        (, amountForSwap) = c.getSingleSidedAmount(amountIn, isToken0Base ? false : true);

        c.stake(
            ICouncil.StakeSingleParam({
                amountIn: amountIn,
                amountInForSwap: amountForSwap,
                amountOutMin: 0, // ignore slippage
                isAmountIn0: isToken0Base ? false : true,
                deadline: block.timestamp
            })
        );

        address pool = c.pool();
        emit log_named_uint("token0 balanceOf(this)", token0.balanceOf(address(this)));
        emit log_named_uint("token1 balanceOf(this)", token1.balanceOf(address(this)));
        emit log_named_uint("token0 balanceOf(Pool)", token0.balanceOf(pool));
        emit log_named_uint("token1 balanceOf(Pool)", token1.balanceOf(pool));
    }

    function testSingleSidedStake__BaseToken() public {
        (address _token0, ) = c.getTokens();
        (bool isToken0Base, ) = base == _token0 ? (true, false) : (false, true);

        vm.expectRevert(bytes("AS"));
        c.stake(
            ICouncil.StakeSingleParam({
                amountIn: 1e18,
                amountInForSwap: 0,
                amountOutMin: 0, // ignore slippage
                isAmountIn0: isToken0Base ? true : false,
                deadline: block.timestamp
            })
        );

        address pool = c.pool();
        emit log_named_uint("token0 balanceOf(this)", token0.balanceOf(address(this)));
        emit log_named_uint("token1 balanceOf(this)", token1.balanceOf(address(this)));
        emit log_named_uint("token0 balanceOf(Pool)", token0.balanceOf(pool));
        emit log_named_uint("token1 balanceOf(Pool)", token1.balanceOf(pool));
    }
}

abstract contract SwapState is StakedState {
    uint256 amountForSwap;
    uint256 amountIn;

    function setUp() public virtual override {
        super.setUp();
        (address _token0, ) = c.getTokens();
        (bool isToken0Base, ) = base == _token0 ? (true, false) : (false, true);
        amountIn = 10e18;

        (, amountForSwap) = c.getSingleSidedAmount(amountIn, isToken0Base ? false : true);

        c.stake(
            ICouncil.StakeSingleParam({
                amountIn: amountIn,
                amountInForSwap: amountForSwap,
                amountOutMin: 0, // ignore slippage
                isAmountIn0: isToken0Base ? false : true,
                deadline: block.timestamp
            })
        );
    }
}

contract CouncilSwappedTest is SwapState {
    function testUnstake() public {
        (address t0, address t1) = c.getTokens();
        address pool = c.pool();

        emit log_named_uint("token0 balanceOf(this)", token0.balanceOf(address(this)));
        emit log_named_uint("token1 balanceOf(this)", token1.balanceOf(address(this)));
        emit log_named_uint("token0 balanceOf(Pool)", token0.balanceOf(pool));
        emit log_named_uint("token1 balanceOf(Pool)", token1.balanceOf(pool));
        uint256 shares = c.balanceOf(address(this));
        emit log_named_uint("shares", shares);

        c.unstake(shares);

        emit log_named_uint("token0 balanceOf(this)", token0.balanceOf(address(this)));
        emit log_named_uint("token1 balanceOf(this)", token1.balanceOf(address(this)));
        emit log_named_uint("token0 balanceOf(Pool)", token0.balanceOf(pool));
        emit log_named_uint("token1 balanceOf(Pool)", token1.balanceOf(pool));

        (uint128 amount0, uint128 amount1, uint256 timestamp) = c.withdraws(address(this));
        assertEq(IERC20(t0).balanceOf(address(c)), amount0);
        assertEq(IERC20(t1).balanceOf(address(c)), amount1);
        assertEq(block.timestamp, timestamp);
    }

    function testUnstake__halfAmount() public {
        (address t0, address t1) = c.getTokens();
        address pool = c.pool();

        emit log_named_uint("token0 balanceOf(this)", token0.balanceOf(address(this)));
        emit log_named_uint("token1 balanceOf(this)", token1.balanceOf(address(this)));
        emit log_named_uint("token0 balanceOf(Pool)", token0.balanceOf(pool));
        emit log_named_uint("token1 balanceOf(Pool)", token1.balanceOf(pool));
        uint256 shares = c.balanceOf(address(this)) / 2;
        emit log_named_uint("shares", shares);

        c.unstake(shares);

        emit log_named_uint("token0 balanceOf(this)", token0.balanceOf(address(this)));
        emit log_named_uint("token1 balanceOf(this)", token1.balanceOf(address(this)));
        emit log_named_uint("token0 balanceOf(Pool)", token0.balanceOf(pool));
        emit log_named_uint("token1 balanceOf(Pool)", token1.balanceOf(pool));

        (uint128 amount0, uint128 amount1, uint256 timestamp) = c.withdraws(address(this));
        assertEq(IERC20(t0).balanceOf(address(c)), amount0);
        assertEq(IERC20(t1).balanceOf(address(c)), amount1);
        assertEq(block.timestamp, timestamp);
    }

    function testUnstake__NoneAmount() public {
        vm.expectRevert();
        c.unstake(0);
    }

    function testUnstake__OverAmount() public {
        uint256 shares = c.balanceOf(address(this)) + 1;

        vm.expectRevert();
        c.unstake(shares);
    }
}

abstract contract UnstakedState is SwapState {
    uint256 latestTimestamp;

    function setUp() public virtual override {
        super.setUp();
        uint256 shares = c.balanceOf(address(this));
        latestTimestamp = block.timestamp;
        c.unstake(shares);
    }
}

contract UnstakedTest is UnstakedState {
    function testWithdraw() public {
        (address t0, address t1) = c.getTokens();

        vm.warp(latestTimestamp + withdrawDelay);
        c.withdraw(address(this));

        (uint128 amount0, uint128 amount1, uint256 timestamp) = c.withdraws(address(this));
        assertEq(0, amount0);
        assertEq(0, amount1);
        assertEq(0, timestamp);
        assertEq(IERC20(t0).balanceOf(address(c)), 0);
        assertEq(IERC20(t1).balanceOf(address(c)), 0);
    }

    function testWithdrawWithNotEligibleAddress() public {
        vm.expectRevert();
        c.withdraw(address(1234));
    }

    function testWithdrawBeforeDelayedTime() public {
        (address t0, address t1) = c.getTokens();

        vm.expectRevert();
        c.withdraw(address(this));

        (uint128 amount0, uint128 amount1, uint256 timestamp) = c.withdraws(address(this));
        assertEq(IERC20(t0).balanceOf(address(c)), amount0);
        assertEq(IERC20(t1).balanceOf(address(c)), amount1);
        assertEq(block.timestamp, timestamp);
    }
}

// // contract CouncilTest is DSTest {
// //     uint256 constant PRECISION = 2**96;

// //     HEVM vm = HEVM(HEVM_ADDRESS);
// //     Council c;
// //     V3LiquidityModule uniModule;
// //     GovernanceMock g;

// //     function setUp() public {
// //         Council tc = new Council();
// //         Deployer d = new Deployer(address(tc));
// //         uniModule = new V3LiquidityModule();
// //         c = Council(payable(d.deployIncrement()));
// //         vm.label(address(c), "Council");
// //         vm.label(address(this), "caller");
// //     }

// //     function testInitializeWithCouncil() public {
// //         StandardToken token0 = new StandardToken("bean the token", "BEAN", 18);
// //         StandardToken token1 = new StandardToken("SAMPLE", "SMP", 18);

// //         // 1 token : 0.01 ~ 0.00001
// //         uint160 initialPrice = Math.encodePriceSqrt(address(token0), address(token1), 1e18, 0.01 ether);
// //         uint160 upperPrice = Math.encodePriceSqrt(address(token0), address(token1), 1e18, 0.00001 ether);
// //         // fee 0.3% with move to 1 tick upper
// //         int24 lowerTick = (TickMath.getTickAtSqrtRatio(initialPrice)) + 1;
// //         int24 upperTick = TickMath.getTickAtSqrtRatio(upperPrice);

// //         // 토큰0, 토큰 1, 수수료, 토큰0을 기준 초기 가격, 틱 시작, 틱 종료, undelegate 기간
// //         bytes memory voteModuleData = abi.encodeWithSignature(
// //             "initialize(bytes)",
// //             abi.encode(address(token0), address(token1), 3000, initialPrice, lowerTick, upperTick, 10 days)
// //         );

// //         uint16 proposalQuorum = 1000;
// //         uint16 voteQuorum = 7000;
// //         uint16 emergencyQuorum = 9500;
// //         uint16 voteStartDelay = 0;
// //         uint16 votePeriod = 5;
// //         uint16 voteChangableDelay = 10;

// //         c.initialize(
// //             address(uniModule),
// //             voteModuleData,
// //             proposalQuorum,
// //             voteQuorum,
// //             emergencyQuorum,
// //             voteStartDelay,
// //             votePeriod,
// //             voteChangableDelay
// //         );
// //     }

// //     function testInitializeWithCouncilAndStake() public {
// //         StandardToken token0 = new StandardToken("bean the token", "BEAN", 18);
// //         StandardToken token1 = new StandardToken("SAMPLE", "SMP", 18);
// //         vm.label(address(token0), "token 0");
// //         vm.label(address(token1), "token 1");

// //         // 1 token : 0.01 ~ 0.00001
// //         uint160 initialPrice = Math.encodePriceSqrt(address(token0), address(token1), 1e18, 0.01 ether);
// //         uint160 upperPrice = Math.encodePriceSqrt(address(token0), address(token1), 1e18, 0.00001 ether);
// //         // fee 0.3% with move to 1 tick upper
// //         int24 lowerTick = TickMath.getTickAtSqrtRatio(initialPrice) + 60;
// //         int24 upperTick = TickMath.getTickAtSqrtRatio(upperPrice);

// //         // 토큰0, 토큰 1, 수수료, 토큰0을 기준 초기 가격, 틱 시작, 틱 종료, undelegate 기간
// //         bytes memory voteModuleData = abi.encodeWithSignature(
// //             "initialize(bytes)",
// //             abi.encode(address(token0), address(token1), 3000, initialPrice, lowerTick, upperTick, 10 days)
// //         );

// //         uint16 proposalQuorum = 1000;
// //         uint16 voteQuorum = 7000;
// //         uint16 emergencyQuorum = 9500;
// //         uint16 voteStartDelay = 0;
// //         uint16 votePeriod = 5;
// //         uint16 voteChangableDelay = 10;

// //         c.initialize(
// //             address(uniModule),
// //             voteModuleData,
// //             proposalQuorum,
// //             voteQuorum,
// //             emergencyQuorum,
// //             voteStartDelay,
// //             votePeriod,
// //             voteChangableDelay
// //         );

// //         token0.mint(2e18);
// //         token0.approve(address(c), 2e18);

// //         token0.mintTo(address(1234), 2e18);
// //         vm.prank(address(1234));
// //         token0.approve(address(c), 2e18);

// //         V3LiquidityModule(address(c)).stake(1e18, 0, 1e18, 0);
// //         assertEq(V3LiquidityModule(address(c)).balanceOf(address(this)), 10_34135_51279_89261_028);
// //         assertEq(V3LiquidityModule(address(c)).totalSupply(), 10_34135_51279_89261_028);

// //         vm.prank(address(1234));
// //         V3LiquidityModule(address(c)).stake(2e18, 0, 2e18, 0);
// //         assertEq(V3LiquidityModule(address(c)).balanceOf(address(1234)), 20_68271_02559_78522_056);
// //         assertEq(V3LiquidityModule(address(c)).totalSupply(), 31_02406_53839_67783_084);

// //         vm.prank(address(1234));
// //         V3LiquidityModule(address(c)).unstake(20_68271_02559_78522_056);

// //         assertEq(token0.balanceOf(address(1234)), 2e18 - 1);
// //     }
// // }

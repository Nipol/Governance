/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

import "ds-test/test.sol";
import "../Council.sol";
import "../mocks/Deployer.sol";
import "../mocks/GovernanceMock.sol";
import "../mocks/ERC20.sol";

import {UniswapModule, Math, TickMath} from "../VoteModule/UniswapModule.sol";

import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

interface HEVM {
    function prank(address) external;

    function expectRevert(bytes calldata) external;

    function label(address addr, string calldata label) external;

    function warp(uint256) external;

    function roll(uint256) external;
}

/**
 * @notice 카운슬을 배포하는데 사용합니다
 */
abstract contract ZeroState is DSTest {
    address public constant UNIV3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    uint24 constant fee = 3000;

    HEVM vm = HEVM(HEVM_ADDRESS);
    Council public c;
    StandardToken token0;
    StandardToken token1;
    UniswapModule uniModule;

    function setUp() public virtual {
        token0 = new StandardToken("bean the token", "BEAN", 18);
        token1 = new StandardToken("Wrapped Ether", "WETH", 18);

        uniModule = new UniswapModule();

        uint16 proposalQuorum = 1000;
        uint16 voteQuorum = 7000;
        uint16 emergencyQuorum = 9500;
        uint16 voteStartDelay = 0; // 투표 시작 딜레이 0일
        uint16 votePeriod = 7; // 투표 기간 7일
        uint16 voteChangableDelay = 4; // 투표 변경 가능한 기간 4일

        bytes memory voteModuleData = new bytes(0);

        Council tc = new Council(
            address(uniModule),
            voteModuleData,
            proposalQuorum,
            voteQuorum,
            emergencyQuorum,
            voteStartDelay,
            votePeriod,
            voteChangableDelay
        );
        Deployer d = new Deployer(address(tc));

        c = Council(payable(d.deployIncrement()));

        vm.label(address(c), "Council");
        vm.label(address(this), "Caller");
        vm.label(address(token0), "Token 0");
        vm.label(address(token1), "Token 1");
    }
}

contract UniswapModuleTest is ZeroState {
    function testUniswapModule__initialize() public {
        uint16 proposalQuorum = 1000;
        uint16 voteQuorum = 7000;
        uint16 emergencyQuorum = 9500;
        uint16 voteStartDelay = 0;
        uint16 votePeriod = 5;
        uint16 voteChangableDelay = 10;

        // // 1 token : 0.01 ~ 0.00001
        // uint160 initialPrice = Math.encodePriceSqrt(address(token0), address(token1), 1e18, 0.01 ether);
        // uint160 upperPrice = Math.encodePriceSqrt(address(token0), address(token1), 1e18, 10 ether);
        // // fee 0.3% with move to 1 tick upper
        // int24 lowerTick = TickMath.getTickAtSqrtRatio(initialPrice) +
        //     (address(token0) > address(token1) ? int24(-60) : int24(60));
        // int24 upperTick = TickMath.getTickAtSqrtRatio(upperPrice);

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

        int24 lowerTick = TickMath.getTickAtSqrtRatio(initialPrice);
        int24 upperTick = TickMath.getTickAtSqrtRatio(upperPrice);

        // token0, token1, uniswap fee, initialPrice, lowerTick, upperTick, undelegatePeriod
        bytes memory voteModuleData = abi.encodeWithSignature(
            "initialize(bytes)",
            abi.encode(address(token0), address(token1), 3000, initialPrice, lowerTick, upperTick, 10 days)
        );

        c.initialize(
            address(uniModule),
            voteModuleData,
            proposalQuorum,
            voteQuorum,
            emergencyQuorum,
            voteStartDelay,
            votePeriod,
            voteChangableDelay
        );

        assertEq(UniswapModule(address(c)).getBaseToken(), address(token0));
        assertEq(UniswapModule(address(c)).getPairToken(), address(token1));
    }
}

abstract contract UniswapModule__initialized is ZeroState {
    function setUp() public virtual override {
        super.setUp();

        uint16 proposalQuorum = 1000;
        uint16 voteQuorum = 7000;
        uint16 emergencyQuorum = 9500;
        uint16 voteStartDelay = 0;
        uint16 votePeriod = 5;
        uint16 voteChangableDelay = 10;

        // 1 token : 0.01 ~ 0.00001
        uint160 initialPrice = Math.encodePriceSqrt(address(token0), address(token1), 1e18, 0.01 ether);
        uint160 upperPrice = Math.encodePriceSqrt(address(token0), address(token1), 1e18, 10 ether);
        // fee 0.3% with move to 1 tick upper
        int24 lowerTick = TickMath.getTickAtSqrtRatio(initialPrice) +
            (address(token0) > address(token1) ? int24(-60) : int24(60));
        int24 upperTick = TickMath.getTickAtSqrtRatio(upperPrice);

        emit log_int(TickMath.getTickAtSqrtRatio(initialPrice));
        emit log_int(lowerTick);
        emit log_int(upperTick);

        // token0, token1, uniswap fee, initialPrice, lowerTick, upperTick, undelegatePeriod
        bytes memory voteModuleData = abi.encodeWithSignature(
            "initialize(bytes)",
            abi.encode(address(token0), address(token1), 3000, initialPrice, lowerTick, upperTick, 10 days)
        );

        c.initialize(
            address(uniModule),
            voteModuleData,
            proposalQuorum,
            voteQuorum,
            emergencyQuorum,
            voteStartDelay,
            votePeriod,
            voteChangableDelay
        );

        token0.mint(100e18);
        token0.approve(address(c), 100e18);
        token0.approve(UNIV3_ROUTER, 100e18);

        token1.mint(100e18);
        token1.approve(address(c), 100e18);
        token1.approve(UNIV3_ROUTER, 100e18);

    }
}

contract UniswapModuleTest__Stake is UniswapModule__initialized {
    function testStake() public {
        UniswapModule(address(c)).stake(100e18, 0, 100e18, 0);
        assertEq(UniswapModule(address(c)).balanceOf(address(this)), 10_37555_92495_89802_677);
        assertEq(UniswapModule(address(c)).totalSupply(), 10_37555_92495_89802_677);

        address pair = UniswapModule(address(c)).getPairToken();
        address base = UniswapModule(address(c)).getBaseToken();

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

    // function testPoolSwap() public {
    //     address pool = UniswapModule(payable(c)).getPool();
    //     token1.mint(address(this), 10e18);
    //     uint256 token1Out = ISwapRouter(UNIV3_ROUTER).exactInput(
    //         ISwapRouter.ExactInputParams({
    //             path: abi.encodePacked(address(token1), 3000, address(token0)),
    //             recipient: address(this),
    //             deadline: block.timestamp,
    //             amountIn: token1ToSwap,
    //             amountOutMinimum: 0
    //         })
    //     );
    // }
}

// contract CouncilTest is DSTest {
//     uint256 constant PRECISION = 2**96;

//     HEVM vm = HEVM(HEVM_ADDRESS);
//     Council c;
//     V3LiquidityModule uniModule;
//     GovernanceMock g;

//     function setUp() public {
//         Council tc = new Council();
//         Deployer d = new Deployer(address(tc));
//         uniModule = new V3LiquidityModule();
//         c = Council(payable(d.deployIncrement()));
//         vm.label(address(c), "Council");
//         vm.label(address(this), "caller");
//     }

//     function testInitializeWithUniswapModule() public {
//         StandardToken token0 = new StandardToken("bean the token", "BEAN", 18);
//         StandardToken token1 = new StandardToken("SAMPLE", "SMP", 18);

//         // 1 token : 0.01 ~ 0.00001
//         uint160 initialPrice = Math.encodePriceSqrt(address(token0), address(token1), 1e18, 0.01 ether);
//         uint160 upperPrice = Math.encodePriceSqrt(address(token0), address(token1), 1e18, 0.00001 ether);
//         // fee 0.3% with move to 1 tick upper
//         int24 lowerTick = (TickMath.getTickAtSqrtRatio(initialPrice)) + 1;
//         int24 upperTick = TickMath.getTickAtSqrtRatio(upperPrice);

//         // 토큰0, 토큰 1, 수수료, 토큰0을 기준 초기 가격, 틱 시작, 틱 종료, undelegate 기간
//         bytes memory voteModuleData = abi.encodeWithSignature(
//             "initialize(bytes)",
//             abi.encode(address(token0), address(token1), 3000, initialPrice, lowerTick, upperTick, 10 days)
//         );

//         uint16 proposalQuorum = 1000;
//         uint16 voteQuorum = 7000;
//         uint16 emergencyQuorum = 9500;
//         uint16 voteStartDelay = 0;
//         uint16 votePeriod = 5;
//         uint16 voteChangableDelay = 10;

//         c.initialize(
//             address(uniModule),
//             voteModuleData,
//             proposalQuorum,
//             voteQuorum,
//             emergencyQuorum,
//             voteStartDelay,
//             votePeriod,
//             voteChangableDelay
//         );
//     }

//     function testInitializeWithUniswapModuleAndStake() public {
//         StandardToken token0 = new StandardToken("bean the token", "BEAN", 18);
//         StandardToken token1 = new StandardToken("SAMPLE", "SMP", 18);
//         vm.label(address(token0), "token 0");
//         vm.label(address(token1), "token 1");

//         // 1 token : 0.01 ~ 0.00001
//         uint160 initialPrice = Math.encodePriceSqrt(address(token0), address(token1), 1e18, 0.01 ether);
//         uint160 upperPrice = Math.encodePriceSqrt(address(token0), address(token1), 1e18, 0.00001 ether);
//         // fee 0.3% with move to 1 tick upper
//         int24 lowerTick = TickMath.getTickAtSqrtRatio(initialPrice) + 60;
//         int24 upperTick = TickMath.getTickAtSqrtRatio(upperPrice);

//         // 토큰0, 토큰 1, 수수료, 토큰0을 기준 초기 가격, 틱 시작, 틱 종료, undelegate 기간
//         bytes memory voteModuleData = abi.encodeWithSignature(
//             "initialize(bytes)",
//             abi.encode(address(token0), address(token1), 3000, initialPrice, lowerTick, upperTick, 10 days)
//         );

//         uint16 proposalQuorum = 1000;
//         uint16 voteQuorum = 7000;
//         uint16 emergencyQuorum = 9500;
//         uint16 voteStartDelay = 0;
//         uint16 votePeriod = 5;
//         uint16 voteChangableDelay = 10;

//         c.initialize(
//             address(uniModule),
//             voteModuleData,
//             proposalQuorum,
//             voteQuorum,
//             emergencyQuorum,
//             voteStartDelay,
//             votePeriod,
//             voteChangableDelay
//         );

//         token0.mint(2e18);
//         token0.approve(address(c), 2e18);

//         token0.mintTo(address(1234), 2e18);
//         vm.prank(address(1234));
//         token0.approve(address(c), 2e18);

//         V3LiquidityModule(address(c)).stake(1e18, 0, 1e18, 0);
//         assertEq(V3LiquidityModule(address(c)).balanceOf(address(this)), 10_34135_51279_89261_028);
//         assertEq(V3LiquidityModule(address(c)).totalSupply(), 10_34135_51279_89261_028);

//         vm.prank(address(1234));
//         V3LiquidityModule(address(c)).stake(2e18, 0, 2e18, 0);
//         assertEq(V3LiquidityModule(address(c)).balanceOf(address(1234)), 20_68271_02559_78522_056);
//         assertEq(V3LiquidityModule(address(c)).totalSupply(), 31_02406_53839_67783_084);

//         vm.prank(address(1234));
//         V3LiquidityModule(address(c)).unstake(20_68271_02559_78522_056);

//         assertEq(token0.balanceOf(address(1234)), 2e18 - 1);
//     }
// }

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
import {SnapshotModule} from "../VoteModule/SnapshotModule.sol";

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
    HEVM vm = HEVM(HEVM_ADDRESS);
    Council public c;
    StandardToken token0;
    StandardToken token1;
    UniswapModule uniModule;
    SnapshotModule snapModule;

    function setUp() public virtual {
        Council tc = new Council();
        Deployer d = new Deployer(address(tc));

        token0 = new StandardToken("bean the token", "BEAN", 18);
        token1 = new StandardToken("Wrapped Ether", "WETH", 18);

        uniModule = new UniswapModule();
        snapModule = new SnapshotModule();

        c = Council(payable(d.deployIncrement()));

        vm.label(address(c), "Council");
        vm.label(address(this), "Caller");
        vm.label(address(token0), "Token 0");
        vm.label(address(token1), "Token 1");
    }
}

contract CouncilTest is ZeroState {
    function testCouncil__UniswapModule__initialize() public {
        uint16 proposalQuorum = 1000;
        uint16 voteQuorum = 7000;
        uint16 emergencyQuorum = 9500;
        uint16 voteStartDelay = 0;
        uint16 votePeriod = 5;
        uint16 voteChangableDelay = 10;

        // 1 token : 0.01 ~ 0.00001
        uint160 initialPrice = Math.encodePriceSqrt(address(token0), address(token1), 1e18, 0.01 ether);
        uint160 upperPrice = Math.encodePriceSqrt(address(token0), address(token1), 1e18, 0.00001 ether);
        // fee 0.3% with move to 1 tick upper
        int24 lowerTick = TickMath.getTickAtSqrtRatio(initialPrice) +
            (address(token0) > address(token1) ? int24(-60) : int24(60));
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

        assertEq(
            UniswapModule(address(c)).getToken0(),
            (address(token0) > address(token1) ? address(token1) : address(token0))
        );
        assertEq(
            UniswapModule(address(c)).getToken1(),
            (address(token0) > address(token1) ? address(token0) : address(token1))
        );
    }

    function testCouncil__SnapshotModule__initialize() public {
        uint16 proposalQuorum = 1000;
        uint16 voteQuorum = 7000;
        uint16 emergencyQuorum = 9500;
        uint16 voteStartDelay = 0;
        uint16 votePeriod = 5;
        uint16 voteChangableDelay = 10;

        bytes memory voteModuleData = abi.encodeWithSignature("initialize(bytes)", abi.encode(address(token0)));

        c.initialize(
            address(snapModule),
            voteModuleData,
            proposalQuorum,
            voteQuorum,
            emergencyQuorum,
            voteStartDelay,
            votePeriod,
            voteChangableDelay
        );

        assertEq(SnapshotModule(address(c)).getToken(), address(token0));
    }
}

abstract contract SnapshotModule__initialized is ZeroState {
    function setUp() public virtual override {
        super.setUp();

        uint16 proposalQuorum = 1000;
        uint16 voteQuorum = 7000;
        uint16 emergencyQuorum = 9500;
        uint16 voteStartDelay = 0;
        uint16 votePeriod = 5;
        uint16 voteChangableDelay = 10;

        bytes memory voteModuleData = abi.encodeWithSignature("initialize(bytes)", abi.encode(address(token0)));

        c.initialize(
            address(snapModule),
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

        token0.mintTo(address(1234), 100e18);
        vm.prank(address(1234));
        token0.approve(address(c), 100e18);

        token0.mintTo(address(5678), 100e18);
        vm.prank(address(5678));
        token0.approve(address(c), 100e18);
    }
}

contract SnapshotCouncilTest__Stake is SnapshotModule__initialized {
    function testStake() public {
        SnapshotModule(address(c)).stake(1e18);
        assertEq(SnapshotModule(address(c)).getVotes(address(this)), 1e18);
        assertEq(SnapshotModule(address(c)).getDelegate(address(this)), address(this));
        assertEq(SnapshotModule(address(c)).getTotalSupply(), 1e18);
    }

    function testStake__AmountZero() public {
        vm.expectRevert("");
        SnapshotModule(address(c)).stake(0);
        assertEq(SnapshotModule(address(c)).getVotes(address(this)), 0);
        assertEq(SnapshotModule(address(c)).getDelegate(address(this)), address(0));
        assertEq(SnapshotModule(address(c)).getTotalSupply(), 0);
    }

    function testStake__OverAmount() public {
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        SnapshotModule(address(c)).stake(101e18);
        assertEq(SnapshotModule(address(c)).getVotes(address(this)), 0);
        assertEq(SnapshotModule(address(c)).getDelegate(address(this)), address(0));
        assertEq(SnapshotModule(address(c)).getTotalSupply(), 0);
    }

    function testStake__AndStakeWithDelegate() public {
        SnapshotModule(address(c)).stake(1e18);
        assertEq(SnapshotModule(address(c)).getVotes(address(this)), 1e18);
        assertEq(SnapshotModule(address(c)).getDelegate(address(this)), address(this));

        SnapshotModule(address(c)).stakeWithDelegate(1e18, address(1234));
        assertEq(SnapshotModule(address(c)).getVotes(address(1234)), 2e18);
        assertEq(SnapshotModule(address(c)).getDelegate(address(this)), address(1234));
        assertEq(SnapshotModule(address(c)).getTotalSupply(), 2e18);
    }

    function testStake__AndStakeWithDelegate__ForMe() public {
        SnapshotModule(address(c)).stake(1e18);
        assertEq(SnapshotModule(address(c)).getVotes(address(this)), 1e18);
        assertEq(SnapshotModule(address(c)).getDelegate(address(this)), address(this));

        vm.expectRevert("");
        SnapshotModule(address(c)).stakeWithDelegate(1e18, address(this));
        assertEq(SnapshotModule(address(c)).getVotes(address(this)), 1e18);
        assertEq(SnapshotModule(address(c)).getDelegate(address(this)), address(this));
        assertEq(SnapshotModule(address(c)).getTotalSupply(), 1e18);
    }

    function testStakeWithDelegate() public {
        SnapshotModule(address(c)).stakeWithDelegate(1e18, address(1234));
        assertEq(SnapshotModule(address(c)).getVotes(address(1234)), 1e18);
        assertEq(SnapshotModule(address(c)).getDelegate(address(this)), address(1234));
        assertEq(SnapshotModule(address(c)).getTotalSupply(), 1e18);
    }

    function testStakeWithDelegate__AmountZero() public {
        vm.expectRevert("");
        SnapshotModule(address(c)).stakeWithDelegate(0, address(1234));
        assertEq(SnapshotModule(address(c)).getVotes(address(1234)), 0);
        assertEq(SnapshotModule(address(c)).getDelegate(address(this)), address(0));
        assertEq(SnapshotModule(address(c)).getTotalSupply(), 0);
    }

    function testStakeWithDelegate__OverAmount() public {
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        SnapshotModule(address(c)).stakeWithDelegate(101e18, address(1234));
        assertEq(SnapshotModule(address(c)).getVotes(address(1234)), 0);
        assertEq(SnapshotModule(address(c)).getDelegate(address(this)), address(0));
        assertEq(SnapshotModule(address(c)).getTotalSupply(), 0);
    }

    function testStakeWithDelegate__AndStakeForMe() public {
        SnapshotModule(address(c)).stakeWithDelegate(1e18, address(1234));
        assertEq(SnapshotModule(address(c)).getVotes(address(1234)), 1e18);
        assertEq(SnapshotModule(address(c)).getDelegate(address(this)), address(1234));

        SnapshotModule(address(c)).stake(1e18);
        assertEq(SnapshotModule(address(c)).getVotes(address(this)), 2e18);
        assertEq(SnapshotModule(address(c)).getVotes(address(1234)), 0);
        assertEq(SnapshotModule(address(c)).getDelegate(address(this)), address(this));
        assertEq(SnapshotModule(address(c)).getTotalSupply(), 2e18);
    }

    function testStakeWithDelegate__AndAgain() public {
        SnapshotModule(address(c)).stakeWithDelegate(1e18, address(1234));
        assertEq(SnapshotModule(address(c)).getVotes(address(1234)), 1e18);
        assertEq(SnapshotModule(address(c)).getDelegate(address(this)), address(1234));

        SnapshotModule(address(c)).stakeWithDelegate(1e18, address(1234));
        assertEq(SnapshotModule(address(c)).getVotes(address(1234)), 2e18);
        assertEq(SnapshotModule(address(c)).getDelegate(address(this)), address(1234));
        assertEq(SnapshotModule(address(c)).getTotalSupply(), 2e18);
    }
}

contract SnapshotCouncilTest__StakedSelf is SnapshotModule__initialized {
    function setUp() public override {
        super.setUp();

        SnapshotModule(address(c)).stake(1e18);

        vm.prank(address(1234));
        SnapshotModule(address(c)).stake(1e18);

        vm.prank(address(5678));
        SnapshotModule(address(c)).stake(1e18);
    }

    function testUnstake__FullAmount() public {
        SnapshotModule(address(c)).unstake(1e18);
        assertEq(SnapshotModule(address(c)).getVotes(address(this)), 0);
        assertEq(SnapshotModule(address(c)).getDelegate(address(this)), address(0));
        assertEq(SnapshotModule(address(c)).getTotalSupply(), 2e18);
        assertEq(token0.balanceOf(address(this)), 100e18);
    }

    function testUnstake__LessAmount() public {
        SnapshotModule(address(c)).unstake(5e17);
        assertEq(SnapshotModule(address(c)).getVotes(address(this)), 5e17);
        assertEq(SnapshotModule(address(c)).getDelegate(address(this)), address(this));
        assertEq(SnapshotModule(address(c)).getTotalSupply(), 25e17);
        assertEq(token0.balanceOf(address(this)), 995e17);
    }

    function testUnstake__OverAmount() public {
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        SnapshotModule(address(c)).unstake(2e18);
        assertEq(SnapshotModule(address(c)).getVotes(address(this)), 1e18);
        assertEq(SnapshotModule(address(c)).getDelegate(address(this)), address(this));
        assertEq(SnapshotModule(address(c)).getTotalSupply(), 3e18);
        assertEq(token0.balanceOf(address(this)), 99e18);
    }

    function testDelegate() public {
        SnapshotModule(address(c)).delegate(address(1234));
        assertEq(SnapshotModule(address(c)).getDelegate(address(this)), address(1234));
        assertEq(SnapshotModule(address(c)).getVotes(address(this)), 0);
        assertEq(SnapshotModule(address(c)).getVotes(address(1234)), 2e18);
        assertEq(SnapshotModule(address(c)).getTotalSupply(), 3e18);
    }

    function testDelegate__AgainDelegatee() public {
        SnapshotModule(address(c)).delegate(address(1234));
        SnapshotModule(address(c)).delegate(address(1234));
        assertEq(SnapshotModule(address(c)).getDelegate(address(this)), address(1234));
        assertEq(SnapshotModule(address(c)).getVotes(address(this)), 0);
        assertEq(SnapshotModule(address(c)).getVotes(address(1234)), 2e18);
        assertEq(SnapshotModule(address(c)).getTotalSupply(), 3e18);
    }

    function testDelegate__NotStaked() public {
        vm.prank(address(0xa));
        vm.expectRevert(abi.encodeWithSignature("NotEnoughVotes()"));
        SnapshotModule(address(c)).delegate(address(1234));
        assertEq(SnapshotModule(address(c)).getDelegate(address(0xa)), address(0));
        assertEq(SnapshotModule(address(c)).getVotes(address(0xa)), 0);
        assertEq(SnapshotModule(address(c)).getVotes(address(1234)), 1e18);
        assertEq(SnapshotModule(address(c)).getTotalSupply(), 3e18);
    }
}

contract SnapshotCouncilTest__StakedToDelegatee is SnapshotModule__initialized {
    function setUp() public override {
        super.setUp();

        SnapshotModule(address(c)).stakeWithDelegate(1e18, address(0xa));
        vm.roll(block.number + 1);

        vm.prank(address(1234));
        SnapshotModule(address(c)).stakeWithDelegate(1e18, address(0xb));
        vm.roll(block.number + 1);

        vm.prank(address(5678));
        SnapshotModule(address(c)).stakeWithDelegate(1e18, address(0xb));
        vm.roll(block.number + 1);
    }

    function testUnstake__FullAmount() public {
        // unstake with undelegate 0xa
        SnapshotModule(address(c)).unstake(1e18);
        vm.roll(block.number + 1);

        // past
        assertEq(SnapshotModule(address(c)).getPastVotes(address(0xa), block.number - 3), 1e18);
        // now
        assertEq(SnapshotModule(address(c)).getPastVotes(address(0xa), block.number), 0);

        assertEq(SnapshotModule(address(c)).getVotes(address(0xa)), 0);
        assertEq(SnapshotModule(address(c)).getDelegate(address(this)), address(0));
        assertEq(SnapshotModule(address(c)).getTotalSupply(), 2e18);
        assertEq(token0.balanceOf(address(this)), 100e18);
    }

    function testUnstake__LessAmount() public {
        SnapshotModule(address(c)).unstake(5e17);
        vm.roll(block.number + 1);

        // past
        assertEq(SnapshotModule(address(c)).getPastVotes(address(0xa), block.number - 3), 1e18);
        // now
        assertEq(SnapshotModule(address(c)).getPastVotes(address(0xa), block.number), 5e17);

        assertEq(SnapshotModule(address(c)).getVotes(address(0xa)), 5e17);
        assertEq(SnapshotModule(address(c)).getDelegate(address(this)), address(0xa));
        assertEq(SnapshotModule(address(c)).getTotalSupply(), 25e17);
        assertEq(token0.balanceOf(address(this)), 995e17);
    }

    function testUnstake__OverAmount() public {
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        SnapshotModule(address(c)).unstake(2e18);
        vm.roll(block.number + 1);

        // past
        assertEq(SnapshotModule(address(c)).getPastVotes(address(0xa), block.number - 3), 1e18);
        // now
        assertEq(SnapshotModule(address(c)).getPastVotes(address(0xa), block.number), 1e18);

        assertEq(SnapshotModule(address(c)).getVotes(address(0xa)), 1e18);
        assertEq(SnapshotModule(address(c)).getDelegate(address(this)), address(0xa));
        assertEq(SnapshotModule(address(c)).getTotalSupply(), 3e18);
        assertEq(token0.balanceOf(address(this)), 99e18);
    }
}

abstract contract UniswapV3Module__initialized is ZeroState {
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
        uint160 upperPrice = Math.encodePriceSqrt(address(token0), address(token1), 1e18, 0.00001 ether);
        // fee 0.3% with move to 1 tick upper
        int24 lowerTick = TickMath.getTickAtSqrtRatio(initialPrice) +
            (address(token0) > address(token1) ? int24(-60) : int24(60));
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

        token0.mint(100e18);
        token0.approve(address(c), 100e18);

        token1.mint(100e18);
        token1.approve(address(c), 100e18);
    }
}

contract UniswapV3CouncilTest__initialized is UniswapV3Module__initialized {

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

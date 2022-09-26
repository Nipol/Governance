/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {Governance, IGovernance} from "../Governance.sol";
import "../mocks/Deployer.sol";
import "../mocks/CouncilMock.sol";

contract SlotUpdater {
    uint256 public dummy;

    function set() external {
        dummy = 0;
    }
}

contract Counter {
    uint256 public count = 0;

    event Current(uint256 count);

    function increase() external {
        count++;
        emit Current(count);
    }

    function decrease() external {
        count--;
        emit Current(count);
    }
}

abstract contract InitialGovernance is Test {
    Governance g;

    function setUp() public virtual {
        g = new Governance(1 days);
    }
}

contract GovernanceTest is InitialGovernance {
    function testGetName() public {
        assertEq("bean the DAO", g.name());
    }

    function testProposeFromNotCouncil() public {
        IGovernance.ProposalParams memory p = IGovernance.ProposalParams({
            proposer: address(this),
            spells: new bytes32[](0),
            elements: new bytes[](0)
        });

        vm.prank(address(1234));
        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("Governance__FromNotCouncil(address)")), address(1234))
        );
        g.propose(p);
    }

    function testPropose() public {
        IGovernance.ProposalParams memory p = IGovernance.ProposalParams({
            proposer: address(this),
            spells: new bytes32[](0),
            elements: new bytes[](0)
        });

        bytes32 proposalId = g.propose(p);
        IGovernance.ProposalState st = g.proposals(proposalId);
        assertEq(uint8(st), uint8(IGovernance.ProposalState.AWAIT));
    }

    function testApproveWithoutProposal() public {
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("Governance__NotProposed(bytes32)")), bytes32(0)));
        g.approve(bytes32(0));
    }
}

abstract contract ProposedGovernance is InitialGovernance {
    bytes32 pId;

    function setUp() public virtual override {
        super.setUp();
        IGovernance.ProposalParams memory p = IGovernance.ProposalParams({
            proposer: address(this),
            spells: new bytes32[](0),
            elements: new bytes[](0)
        });

        pId = g.propose(p);
    }
}

contract ProposedGov is ProposedGovernance {
    function setUp() public override {
        super.setUp();
    }

    function testApprove() public {
        g.approve(bytes32(pId));
        IGovernance.ProposalState st = g.proposals(pId);
        assertEq(uint8(st), uint8(IGovernance.ProposalState.APPROVED));
    }

    function testDropWithoutProposal() public {
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("Governance__NotProposed(bytes32)")), bytes32(0)));
        g.drop(bytes32(0));
    }

    function testDrop() public {
        g.drop(pId);
        IGovernance.ProposalState st = g.proposals(pId);
        assertEq(uint8(st), uint8(IGovernance.ProposalState.DROPPED));
    }

    function testExecuteNotResolved() public {
        g.approve(bytes32(pId));

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("Scheduler__RemainingTime(bytes32)")), pId));
        g.execute(pId);

        IGovernance.ProposalState st = g.proposals(pId);
        assertEq(uint8(st), uint8(IGovernance.ProposalState.APPROVED));
    }

    function testAfterGracePeriodExecute() public {
        g.approve(bytes32(pId));

        vm.warp(block.timestamp + 10 days);
        g.execute(pId);

        IGovernance.ProposalState st = g.proposals(pId);
        assertEq(uint8(st), uint8(IGovernance.ProposalState.DROPPED));
    }
}

abstract contract PreparedGovernance is InitialGovernance {
    Counter c;
    bytes32 pId;

    function setUp() public virtual override {
        super.setUp();

        c = new Counter();
        bytes32 spell = bytes32(
            abi.encodePacked(
                Counter.increase.selector,
                bytes1(0x40),
                bytes1(0xff),
                bytes1(0xff),
                bytes1(0xff),
                bytes1(0xff),
                bytes1(0xff),
                bytes1(0xff),
                bytes1(0xff),
                address(c)
            )
        );
        bytes32[] memory spells = new bytes32[](2);
        spells[0] = spell;
        spells[1] = spell;

        bytes[] memory elements = new bytes[](0);

        IGovernance.ProposalParams memory p = IGovernance.ProposalParams({
            proposer: address(this),
            spells: spells,
            elements: elements
        });
        pId = g.propose(p);
        g.approve(bytes32(pId));
        vm.warp(block.timestamp + 2 days);
    }
}

contract ExePrepGovernance is PreparedGovernance {
    function testExecute() public {
        g.execute(pId);

        assertEq(c.count(), 2);

        IGovernance.ProposalState st = g.proposals(pId);
        assertEq(uint8(st), uint8(IGovernance.ProposalState.EXECUTED));
    }
}

abstract contract SlotUpdateGovernance is InitialGovernance {
    SlotUpdater c;
    bytes32 pId;

    function setUp() public virtual override {
        super.setUp();

        c = new SlotUpdater();

        bytes32 spell = bytes32(
            abi.encodePacked(
                SlotUpdater.set.selector,
                bytes1(0x00),
                bytes1(0xff),
                bytes1(0xff),
                bytes1(0xff),
                bytes1(0xff),
                bytes1(0xff),
                bytes1(0xff),
                bytes1(0xff),
                address(c)
            )
        );

        bytes32[] memory spells = new bytes32[](1);
        spells[0] = spell;
        bytes[] memory elements = new bytes[](0);

        IGovernance.ProposalParams memory p = IGovernance.ProposalParams({
            proposer: address(this),
            spells: spells,
            elements: elements
        });

        pId = g.propose(p);
        g.approve(bytes32(pId));
        vm.warp(block.timestamp + 2 days);
    }
}

contract SlotExeGovernance is SlotUpdateGovernance {
    function testExecute() public {
        g.execute(pId);

        assertEq(g.delay(), 0);

        IGovernance.ProposalState st = g.proposals(pId);
        assertEq(uint8(st), uint8(IGovernance.ProposalState.EXECUTED));
    }
}

abstract contract CouncilUpdateGovernance is InitialGovernance {
    CouncilMock cm;
    bytes32 pId;
    bytes32 pId2;
    bytes32 pId3;

    function setUp() public virtual override {
        super.setUp();

        cm = new CouncilMock();

        bytes32 spell = bytes32(
            abi.encodePacked(
                g.changeCouncil.selector,
                bytes1(0x40),
                bytes1(0x00),
                bytes1(0xff),
                bytes1(0xff),
                bytes1(0xff),
                bytes1(0xff),
                bytes1(0xff),
                bytes1(0xff),
                address(g)
            )
        );

        bytes32[] memory spells = new bytes32[](1);
        spells[0] = spell;
        bytes[] memory elements = new bytes[](1);
        elements[0] = abi.encode(address(cm));

        IGovernance.ProposalParams memory p = IGovernance.ProposalParams({
            proposer: address(this),
            spells: spells,
            elements: elements
        });

        pId = g.propose(p);
        g.approve(bytes32(pId));

        elements[0] = abi.encode(address(this));
        p = IGovernance.ProposalParams({proposer: address(this), spells: spells, elements: elements});

        pId2 = g.propose(p);
        g.approve(bytes32(pId2));
        vm.warp(block.timestamp + 2 days);
    }
}

contract NotImplementedERC165 is CouncilUpdateGovernance {
    function setUp() public override {
        super.setUp();
    }

    function testChangeCouncilButNotImplementedERC165() public {
        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("Governance__NoneERC165Interface(address)")), address(this))
        );
        g.execute(pId2);
    }
}

contract CouncilToGovernance is CouncilUpdateGovernance {
    function setUp() public override {
        super.setUp();
    }

    function testChangeCouncil() public {
        g.execute(pId);

        assertEq(g.council(), address(cm));
    }

    function testChangeCouncilFromNotGovernance() public {
        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("Governance__FromNotGovernance(address)")), address(this))
        );
        g.changeCouncil(address(1553));
    }

    function testChangeCouncilButNotCouncil() public {
        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("Governance__NotCouncilContract(address)")), address(this))
        );
        g.execute(pId2);
    }

    function supportsInterface(bytes4) public pure returns (bool) {
        return false;
    }
}

abstract contract DelayUpdateGovernance is InitialGovernance {
    bytes32 pId;

    function setUp() public virtual override {
        super.setUp();

        bytes32 spell = bytes32(
            abi.encodePacked(
                g.changeDelay.selector,
                bytes1(0x40),
                bytes1(0x00),
                bytes1(0xff),
                bytes1(0xff),
                bytes1(0xff),
                bytes1(0xff),
                bytes1(0xff),
                bytes1(0xff),
                address(g)
            )
        );

        bytes32[] memory spells = new bytes32[](1);
        spells[0] = spell;
        bytes[] memory elements = new bytes[](1);
        elements[0] = abi.encode(2 days);

        IGovernance.ProposalParams memory p = IGovernance.ProposalParams({
            proposer: address(this),
            spells: spells,
            elements: elements
        });

        pId = g.propose(p);
        g.approve(bytes32(pId));
        vm.warp(block.timestamp + 2 days);
    }
}

contract DelayToGovernance is DelayUpdateGovernance {
    function setUp() public override {
        super.setUp();
    }

    function testChangeDelay() public {
        g.execute(pId);
        assertEq(g.delay(), 2 days);
    }

    function testChangeDelayFromNotGovernance() public {
        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("Governance__FromNotGovernance(address)")), address(this))
        );
        g.changeDelay(2 days);
    }
}

// function testEmergencyExecute() public {
//     Counter c = new Counter();

//     bytes32 spell = bytes32(
//         abi.encodePacked(
//             Counter.increase.selector,
//             bytes1(0x40),
//             bytes1(0xff),
//             bytes1(0xff),
//             bytes1(0xff),
//             bytes1(0xff),
//             bytes1(0xff),
//             bytes1(0xff),
//             bytes1(0xff),
//             address(c)
//         )
//     );

//     bytes32[] memory spells = new bytes32[](2);
//     spells[0] = spell;
//     spells[1] = spell;
//     bytes[] memory elements = new bytes[](0);

//     g.emergencyExecute(spells, elements);
//     assertEq(c.count(), 2);
//     assertEq(g.nonce(), 1);
// }

// function testEmergencyCouncilChange() public {
//     bytes32 spell = bytes32(
//         abi.encodePacked(
//             g.emergencyCouncil.selector,
//             bytes1(0x40),
//             bytes1(0x00),
//             bytes1(0xff),
//             bytes1(0xff),
//             bytes1(0xff),
//             bytes1(0xff),
//             bytes1(0xff),
//             bytes1(0xff),
//             address(g)
//         )
//     );

//     bytes32[] memory spells = new bytes32[](1);
//     spells[0] = spell;
//     bytes[] memory elements = new bytes[](1);
//     elements[0] = abi.encode(address(1559));

//     g.emergencyExecute(spells, elements);

//     assertEq(g.nonce(), 1);
//     assertEq(g.council(), address(1559));
// }

// function testEmergencyCouncilNotAllowedGovernance() public {
//     bytes32 spell = bytes32(
//         abi.encodePacked(
//             g.emergencyCouncil.selector,
//             bytes1(0x40),
//             bytes1(0x00),
//             bytes1(0xff),
//             bytes1(0xff),
//             bytes1(0xff),
//             bytes1(0xff),
//             bytes1(0xff),
//             bytes1(0xff),
//             address(g)
//         )
//     );

//     bytes32[] memory spells = new bytes32[](1);
//     spells[0] = spell;
//     bytes[] memory elements = new bytes[](1);
//     elements[0] = abi.encode(address(g));

//     vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("Governance__InvalidAddress(address)")), address(g)));
//     g.emergencyExecute(spells, elements);

//     assertEq(g.nonce(), 0);
//     assertEq(g.council(), address(this));
// }

// function testEmergencyCouncilNotAllowedAlreadyCouncil() public {
//     bytes32 spell = bytes32(
//         abi.encodePacked(
//             g.emergencyCouncil.selector,
//             bytes1(0x40),
//             bytes1(0x00),
//             bytes1(0xff),
//             bytes1(0xff),
//             bytes1(0xff),
//             bytes1(0xff),
//             bytes1(0xff),
//             bytes1(0xff),
//             address(g)
//         )
//     );

//     bytes32[] memory spells = new bytes32[](1);
//     spells[0] = spell;
//     bytes[] memory elements = new bytes[](1);
//     elements[0] = abi.encode(address(this));

//     vm.expectRevert(
//         abi.encodeWithSelector(bytes4(keccak256("Governance__InvalidAddress(address)")), address(this))
//     );
//     g.emergencyExecute(spells, elements);

//     assertEq(g.nonce(), 0);
//     assertEq(g.council(), address(this));
// }

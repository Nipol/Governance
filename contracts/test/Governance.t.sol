/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

import "ds-test/test.sol";
import {Governance, IGovernance} from "../Governance.sol";
import "../mocks/Deployer.sol";
import "../mocks/CouncilMock.sol";

interface HEVM {
    function prank(address) external;

    function expectRevert(bytes calldata) external;

    function warp(uint256) external;
}

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

contract GovernanceTest is DSTest {
    HEVM vm = HEVM(HEVM_ADDRESS);
    Governance g;

    modifier govInit() {
        g.initialize("bean the DAO", address(this), 1 days);
        _;
    }

    function setUp() public {
        // 0xce71065d4017f316ec606fe4422e11eb2c47c246
        Governance tg = new Governance();
        // 0x185a4dc360ce69bdccee33b3784b0282f7961aea
        Deployer d = new Deployer(address(tg));
        // 0x6e7c83fc225ef4b94e1f4cba9572226cc4ed6c9f
        g = Governance(d.deployIncrement());
    }

    function testInitialize() public {
        string memory _name = "bean the DAO";

        g.initialize(_name, address(this), 1 days);

        assertEq(g.name(), _name);
        assertEq(g.council(), address(this));
    }

    function testProposeFromNotCouncil() public {
        IGovernance.ProposalParams memory p = IGovernance.ProposalParams({
            proposer: address(this),
            spells: new bytes32[](0),
            elements: new bytes[](0)
        });

        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("Governance__FromNotCouncil(address)")), address(this))
        );
        g.propose(p);
    }

    function testPropose() public govInit {
        IGovernance.ProposalParams memory p = IGovernance.ProposalParams({
            proposer: address(this),
            spells: new bytes32[](0),
            elements: new bytes[](0)
        });

        bytes16 _magichash = bytes16(
            keccak256(abi.encode(keccak256(abi.encodePacked(new bytes32[](0))), keccak256(abi.encode(new bytes[](0)))))
        );

        (bytes32 proposalId, uint96 id) = g.propose(p);
        assertEq(id, g.nonce());

        (, bytes16 magichash, IGovernance.ProposalState state, ) = g.proposals(proposalId);
        assertEq(id, 1);
        assertEq(magichash, _magichash);
        assertEq(uint8(state), uint8(IGovernance.ProposalState.AWAIT));
    }

    function testApproveWithoutProposal() public govInit {
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("Governance__NotProposed(bytes32)")), bytes32(0)));
        g.approve(bytes32(0));
    }

    function testApprove() public govInit {
        IGovernance.ProposalParams memory p = IGovernance.ProposalParams({
            proposer: address(this),
            spells: new bytes32[](0),
            elements: new bytes[](0)
        });

        (bytes32 proposalId, ) = g.propose(p);
        g.approve(bytes32(proposalId));

        (, , IGovernance.ProposalState state, ) = g.proposals(proposalId);
        assertEq(uint8(state), uint8(IGovernance.ProposalState.APPROVED));
    }

    function testDropWithoutProposal() public govInit {
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("Governance__NotProposed(bytes32)")), bytes32(0)));
        g.drop(bytes32(0));
    }

    function testDrop() public govInit {
        IGovernance.ProposalParams memory p = IGovernance.ProposalParams({
            proposer: address(this),
            spells: new bytes32[](0),
            elements: new bytes[](0)
        });

        (bytes32 proposalId, ) = g.propose(p);
        g.drop(proposalId);
        (, , IGovernance.ProposalState state, ) = g.proposals(proposalId);
        assertEq(uint8(state), uint8(IGovernance.ProposalState.DROPPED));
    }

    function testExecute() public govInit {
        Counter c = new Counter();

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

        (bytes32 proposalId, ) = g.propose(p);
        g.approve(bytes32(proposalId));

        vm.warp(block.timestamp + 2 days);
        g.execute(proposalId, spells, elements);

        assertEq(c.count(), 2);

        (, , IGovernance.ProposalState state, ) = g.proposals(proposalId);
        assertEq(uint8(state), uint8(IGovernance.ProposalState.EXECUTED));
    }

    function testExecuteForSlotUpdate() public govInit {
        SlotUpdater c = new SlotUpdater();

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

        (bytes32 proposalId, ) = g.propose(p);
        g.approve(bytes32(proposalId));

        vm.warp(block.timestamp + 2 days);
        g.execute(proposalId, spells, elements);

        assertEq(g.delay(), 0);

        (, , IGovernance.ProposalState state, ) = g.proposals(proposalId);
        assertEq(uint8(state), uint8(IGovernance.ProposalState.EXECUTED));
    }

    function testExecuteNotResolved() public govInit {
        IGovernance.ProposalParams memory p = IGovernance.ProposalParams({
            proposer: address(this),
            spells: new bytes32[](0),
            elements: new bytes[](0)
        });

        bytes32[] memory spells = new bytes32[](0);
        bytes[] memory elements = new bytes[](0);

        (bytes32 proposalId, ) = g.propose(p);
        g.approve(bytes32(proposalId));

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("Scheduler__RemainingTime(bytes32)")), proposalId));
        g.execute(proposalId, spells, elements);

        (, , IGovernance.ProposalState state, ) = g.proposals(proposalId);
        assertEq(uint8(state), uint8(IGovernance.ProposalState.APPROVED));
    }

    function testExecuteNotValidSpells() public govInit {
        bytes32[] memory spells = new bytes32[](1);
        bytes[] memory elements = new bytes[](1);

        IGovernance.ProposalParams memory p = IGovernance.ProposalParams({
            proposer: address(this),
            spells: spells,
            elements: elements
        });

        (bytes32 proposalId, ) = g.propose(p);
        g.approve(bytes32(proposalId));

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
        spells[0] = spell;

        bytes16 magichash = bytes16(
            keccak256(abi.encode(keccak256(abi.encodePacked(spells)), keccak256(abi.encode(new bytes[](1)))))
        );

        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("Governance__InvalidExecuteData(bytes16)")), magichash)
        );
        g.execute(proposalId, spells, elements);

        (, , IGovernance.ProposalState state, ) = g.proposals(proposalId);
        assertEq(uint8(state), uint8(IGovernance.ProposalState.APPROVED));
    }

    function testAfterGracePeriodExecute() public govInit {
        bytes32[] memory spells = new bytes32[](0);
        bytes[] memory elements = new bytes[](0);

        IGovernance.ProposalParams memory p = IGovernance.ProposalParams({
            proposer: address(this),
            spells: spells,
            elements: elements
        });

        (bytes32 proposalId, ) = g.propose(p);
        g.approve(bytes32(proposalId));

        vm.warp(block.timestamp + 10 days);
        g.execute(proposalId, spells, elements);

        (, , IGovernance.ProposalState state, ) = g.proposals(proposalId);
        assertEq(uint8(state), uint8(IGovernance.ProposalState.DROPPED));
    }

    function testChangeCouncil() public govInit {
        CouncilMock cm = new CouncilMock();

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

        (bytes32 proposalId, ) = g.propose(p);
        g.approve(bytes32(proposalId));

        assertEq(g.council(), address(this));

        vm.warp(block.timestamp + 2 days);
        g.execute(proposalId, spells, elements);

        assertEq(g.council(), address(cm));
    }

    function testChangeCouncilFromNotGovernance() public govInit {
        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("Governance__FromNotGovernance(address)")), address(this))
        );
        g.changeCouncil(address(1553));
    }

    function testChangeCouncilButNotCouncil() public govInit {
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
        elements[0] = abi.encode(address(this));

        IGovernance.ProposalParams memory p = IGovernance.ProposalParams({
            proposer: address(this),
            spells: spells,
            elements: elements
        });

        (bytes32 proposalId, ) = g.propose(p);
        g.approve(bytes32(proposalId));

        assertEq(g.council(), address(this));

        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("Governance__NotCouncilContract(address)")), address(this))
        );
        g.execute(proposalId, spells, elements);

        assertEq(g.council(), address(this));
    }

    function testChangeDelay() public govInit {
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

        (bytes32 proposalId, ) = g.propose(p);
        g.approve(bytes32(proposalId));

        assertEq(g.delay(), 1 days);

        vm.warp(block.timestamp + 2 days);
        g.execute(proposalId, spells, elements);

        assertEq(g.delay(), 2 days);
    }

    function testChangeDelayFromNotGovernance() public govInit {
        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("Governance__FromNotGovernance(address)")), address(this))
        );
        g.changeDelay(2 days);
    }

    function testEmergencyExecute() public govInit {
        Counter c = new Counter();

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

        g.emergencyExecute(spells, elements);
        assertEq(c.count(), 2);
        assertEq(g.nonce(), 1);
    }

    function testEmergencyCouncilChange() public govInit {
        bytes32 spell = bytes32(
            abi.encodePacked(
                g.emergencyCouncil.selector,
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
        elements[0] = abi.encode(address(1559));

        g.emergencyExecute(spells, elements);

        assertEq(g.nonce(), 1);
        assertEq(g.council(), address(1559));
    }

    function testEmergencyCouncilNotAllowedGovernance() public govInit {
        bytes32 spell = bytes32(
            abi.encodePacked(
                g.emergencyCouncil.selector,
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
        elements[0] = abi.encode(address(g));

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("Governance__InvalidAddress(address)")), address(g)));
        g.emergencyExecute(spells, elements);

        assertEq(g.nonce(), 0);
        assertEq(g.council(), address(this));
    }

    function testEmergencyCouncilNotAllowedAlreadyCouncil() public govInit {
        bytes32 spell = bytes32(
            abi.encodePacked(
                g.emergencyCouncil.selector,
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
        elements[0] = abi.encode(address(this));

        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("Governance__InvalidAddress(address)")), address(this))
        );
        g.emergencyExecute(spells, elements);

        assertEq(g.nonce(), 0);
        assertEq(g.council(), address(this));
    }

    function supportsInterface(bytes4) public pure returns (bool) {
        return false;
    }
}

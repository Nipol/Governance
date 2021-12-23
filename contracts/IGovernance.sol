/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

import "@beandao/contracts/interfaces/IERC721TokenReceiver.sol";
import "@beandao/contracts/interfaces/IERC1271.sol";

/**
 * @title IGovernance
 */
interface IGovernance is IERC1271, IERC721TokenReceiver {
    enum ProposalState {
        UNKNOWN,
        AWAIT,
        ABSTAIN
    }

    struct Proposal {
        uint128 id;
        address proposer;
        bytes32[] spells;
        bytes[] elements;
        bool executed;
        bool canceled;
        ProposalState state;
    }

    struct ProposalParams {
        address proposer;
        bytes32[] spells;
        bytes[] elements;
    }

    struct VoteParam {
        bytes32 uniqueId;
        uint128 forAmount;
        uint128 againstAmount;
    }

    event Proposed(
        bytes32 indexed proposalId,
        uint128 id,
        bytes32[] spells,
        address indexed council,
        address indexed proposer
    );

    event Ready(bytes32 indexed proposalId);

    event Dropped(bytes32 indexed proposalId);

    event Executed(bytes32 indexed proposalId);

    function propose(ProposalParams memory params) external returns (bytes32 proposalId, uint128 id);

    function ready(bytes32 proposalId) external returns (bool success);

    function drop(bytes32 proposalId) external returns (bool success);

    function execute(bytes32 proposalId) external;

    function changeCouncil(address councilAddr) external;

    function changeDelay(uint32 executeDelay) external;

    function emergencyExecute(bytes32[] calldata spells, bytes[] memory elements) external;

    function emergencyCouncil(address councilorAddr) external;
}

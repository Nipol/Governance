/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

import "bean-contracts/contracts/interfaces/IERC721TokenReceiver.sol";
import "bean-contracts/contracts/interfaces/IERC1271.sol";

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
        bytes32 magichash;
        bool executed;
        bool canceled;
        ProposalState state;
    }

    struct ProposalParams {
        address proposer;
        bytes32 magichash;
    }

    struct VoteParam {
        bytes32 uniqueId;
        uint128 forAmount;
        uint128 againstAmount;
    }

    event Proposed(
        bytes32 indexed proposalId,
        string version,
        uint128 id,
        address indexed council,
        address indexed proposer,
        bytes32 magichash
    );

    event Approved(bytes32 indexed proposalId);

    event Dropped(bytes32 indexed proposalId);

    event Executed(bytes32 indexed proposalId);

    function propose(ProposalParams calldata params) external returns (bytes32 proposalId, uint128 id);

    function approve(bytes32 proposalId) external returns (bool success);

    function drop(bytes32 proposalId) external returns (bool success);

    function execute(
        bytes32 proposalId,
        bytes32[] calldata spells,
        bytes[] calldata elements
    ) external;

    function changeCouncil(address councilAddr) external;

    function changeDelay(uint32 executeDelay) external;

    function emergencyExecute(bytes32[] calldata spells, bytes[] memory elements) external;

    function emergencyCouncil(address councilorAddr) external;
}

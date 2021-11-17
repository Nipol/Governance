/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

/**
 * @title IGovernance
 */
interface IGovernance {
    enum ProposalState {
        UNKNOWN,
        AWAIT,
        ABSTAIN
    }

    struct Proposal {
        uint128 id;
        address proposer;
        bytes32[] commands;
        uint128[] values;
        bytes[] variables;
        bool executed;
        bool canceled;
        ProposalState state;
    }

    struct VoteParam {
        bytes32 uniqueId;
        uint128 forAmount;
        uint128 againstAmount;
    }

    event Proposed();

    struct ProposalParams {
        address proposer;
        uint32 startTime;
        uint32 endTime;
        bytes32[] commands;
        uint128[] values;
        bytes[] variables;
    }

    function propose(ProposalParams memory params) external returns (bytes32 uniqueId, uint128 id);

    function standby(bytes32 proposalId) external returns (bool success);

    function drop(bytes32 proposalId) external returns (bool success);
}

/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

/**
 * @title IGovernance
 */
interface IGovernance {
    struct Proposal {
        uint128 id;
        address proposer;
        uint32 startBlock;
        uint32 endBlock;
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        bool executed;
        bool canceled;
    }

    struct VoteParam {
        bytes32 uniqueId;
        uint128 forAmount;
        uint128 againstAmount;
    }

    event Proposed();
}

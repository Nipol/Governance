/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

import "@beandao/contracts/interfaces/IERC165.sol";
import "@beandao/contracts/interfaces/IERC721TokenReceiver.sol";
import "@beandao/contracts/interfaces/IERC1155TokenReceiver.sol";
import "@beandao/contracts/interfaces/IERC1271.sol";

/**
 * @title IGovernance
 */
interface IGovernance is IERC165, IERC1271, IERC721TokenReceiver, IERC1155TokenReceiver {
    enum ProposalState {
        NOT_PROPOSED, // 등록되지 않은 모든 제안서의 상태
        AWAIT, // 등록 직후의 상태
        APPROVED, // 허가된 제안서 상태
        DROPPED, // 버려진 제안서 상태
        EXECUTED // 실행된 제안서
    }

    struct Proposal {
        uint96 id; // remain 160 bit
        bytes16 magichash; // remain 32 bit
        ProposalState state; // remain 24 bit
        uint24 dummy; // dummy
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
        string version,
        uint96 id,
        address indexed council,
        address indexed proposer,
        bytes32[] spells,
        bytes[] elements,
        bytes16 magichash
    );

    event Approved(bytes32 indexed proposalId);

    event Dropped(bytes32 indexed proposalId);

    event Executed(bytes32 indexed proposalId);

    function name() external view returns (string memory);

    function council() external view returns (address);

    function nonce() external view returns (uint96);

    function propose(ProposalParams calldata params) external returns (bytes32 proposalId, uint96 id);

    function approve(bytes32 proposalId) external returns (bool);

    function drop(bytes32 proposalId) external returns (bool);

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

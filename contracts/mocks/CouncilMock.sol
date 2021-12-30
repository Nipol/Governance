/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

import {ICouncil, IERC165} from "../ICouncil.sol";

/**
 * @title CouncilMock
 */
contract CouncilMock is ICouncil {
    /**
     * @notice 프로포절에 기록된 투표 정보
     */
    mapping(bytes32 => Proposal) public proposals;

    function initialize(
        address voteModuleAddr,
        uint16 proposalQuorum,
        uint16 voteQuorum,
        uint16 emergencyQuorum,
        uint16 voteStartDelay,
        uint16 votePeriod,
        uint16 voteChangableDelay
    ) external {}

    function propose(
        address governance,
        bytes32[] memory spells,
        bytes[] calldata elements
    ) external {}

    function vote(bytes32 proposalId, bool support) external {}

    function resolve(bytes32 proposalId) external returns (bool success) {}

    function getProposalState(bytes32 proposalId) internal view returns (ProposalState state, Proposal storage p) {
        p = proposals[proposalId];
    }

    function supportsInterface(bytes4 interfaceID) external pure returns (bool) {
        return interfaceID == type(ICouncil).interfaceId || interfaceID == type(IERC165).interfaceId;
    }
}

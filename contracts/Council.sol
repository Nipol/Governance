/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

import "@beandao/contracts/library/Initializer.sol";
// import "@beandao/contracts/library/Scheduler.sol";

import "./VoteModule/IModule.sol";
import "./ICouncil.sol";
import "./IGovernance.sol";

/**
 * @title Council
 * @notice 투표권과 투표 정보를 컨트롤하는 컨트랙트. 거버넌스 정보는 이곳에 저장하지 않으며,
 */
contract Council is ICouncil, Initializer {
    string public constant version = "1";
    Slot public slot;
    /**
     * @notice 프로포절에 기록된 투표 정보
     */
    mapping(bytes32 => Proposal) public proposals;

    function initialize(
        address voteModuleAddr,
        uint32 voteStartDelay,
        uint32 votePeriod,
        uint32 voteChangableDelay
    ) external initializer {
        slot.voteModule = voteModuleAddr;
        slot.voteStartDelay = voteStartDelay;
        slot.votePeriod = votePeriod;
        slot.voteChangableDelay = voteChangableDelay;
    }

    fallback() external payable {
        address module = slot.voteModule;
        assembly {
            // copy function selector and any arguments
            calldatacopy(0, 0, calldatasize())
            // execute function call using the facet
            let result := delegatecall(gas(), module, 0, calldatasize(), 0, 0)
            // get any return value
            returndatacopy(0, 0, returndatasize())
            // return any return value or error back to the caller
            switch result
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }

    function propose(
        address governance,
        bytes32[] memory commands,
        uint128[] calldata values,
        bytes[] calldata variables
    ) external {
        // 한 블럭 이전 or 지난 epoch에, msg.sender의 보팅 권한이 최소 쿼럼을 만족하는지 체크
        require(IModule(address(this)).getPriorPower(msg.sender, block.number - 1) >= slot.proposalQuorum);

        // 투표 시작 지연 추가
        uint32 start = uint32(block.timestamp) + slot.voteStartDelay;
        uint32 end = start + slot.votePeriod;
        // 거버넌스 컨트랙트에 등록할 proposal 정보
        IGovernance.ProposalParams memory params = IGovernance.ProposalParams({
            proposer: msg.sender,
            startTime: start,
            endTime: end,
            commands: commands,
            values: values,
            variables: variables
        });

        // 거버넌스 컨트랙트에 proposal 등록
        (bytes32 proposalId, ) = IGovernance(governance).propose(params);
        // 반횐된 uid에 대해 council 버전의 proposal 저장.
        (ProposalState state, Proposal storage p) = getProposalState(proposalId);
        // 한번도 사용되지 않은 유니크 아이디인지 확인
        assert(state == ProposalState.UNKNOWN); // check never used
        (p.startTime, p.endTime, p.yea, p.nay, p.abstain, p.totalVotes, p.blockNumber, p.timestamp, p.epoch) = (
            start,
            end,
            0, //yea
            0, //nay
            0, //abstain
            0, // totalVotes
            uint32(block.number), // block number for Verification.
            uint32(block.timestamp), // block timestamp for Verification.
            0 // Epoch logic...
        );
        emit Proposed(proposalId);
    }

    function vote(bytes32 proposalId, uint8 support) external {
        (ProposalState state, Proposal storage p) = getProposalState(proposalId);
        // 존재하는 Proposal인지 & 활성 상태인지 확인
        assert(state == ProposalState.ACTIVE);
        // 기록된 블록의 - 1 기준으로 투표권 확인
        uint256 power = IModule(address(this)).getPriorPower(msg.sender, p.blockNumber - 1);
        Vote storage v = p.votes[msg.sender];
        // timestamp 0인지 체크 -> 처음 투표 과정(support 에 따라서 파워 기록, votes에 기록)
        if (v.ts == 0) {
            v.ts = uint32(block.timestamp);
            v.state = support == 0x00 ? VoteState.YEA : support == 0x01 ? VoteState.NAY : support == 0x02
                ? VoteState.ABSENT
                : VoteState.UNKNOWN;
            p.totalVotes += uint96(power);
            p.yea += support == 0x00 ? uint96(power) : 0;
            p.nay += support == 0x01 ? uint96(power) : 0;
            p.abstain += support == 0x02 ? uint96(power) : 0;
        } else {
            require((v.ts + slot.voteChangableDelay) < uint32(block.timestamp), "changing period");
            v.ts = uint32(block.timestamp);
            p.yea -= support == 0x00 ? uint96(power) : 0;
            p.nay -= support == 0x01 ? uint96(power) : 0;
            p.abstain -= support == 0x02 ? uint96(power) : 0;
            v.state = support == 0x00 ? VoteState.YEA : support == 0x01 ? VoteState.NAY : support == 0x02
                ? VoteState.ABSENT
                : VoteState.UNKNOWN;
            p.yea += support == 0x00 ? uint96(power) : 0;
            p.nay += support == 0x01 ? uint96(power) : 0;
            p.abstain += support == 0x02 ? uint96(power) : 0;
        }
        // 만약 기록되어 있다면, 투표 딜레이 지났는지 확인하고, 바뀐 투표 확인하고, 이전 power 줄이고, 새로운 Power 상승. 타임스탬프 기록
    }

    function getProposalState(bytes32 proposalId) internal view returns (ProposalState state, Proposal storage p) {
        p = proposals[proposalId];
        if (p.startTime > uint32(block.timestamp)) {
            state = ProposalState.PENDING;
        } else if (p.startTime <= uint32(block.timestamp)) {
            state = ProposalState.ACTIVE;
        } else if (p.startTime == 0) {
            state = ProposalState.UNKNOWN;
        }
    }
}

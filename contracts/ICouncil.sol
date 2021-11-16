/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

/**
 * @title ICouncil
 */
interface ICouncil {
    /// @notice 투표 기간에 대한 정보만 기록
    enum ProposalState {
        UNKNOWN,
        PENDING,
        ACTIVE
    }
    enum VoteState {
        UNKNOWN,
        YEA,
        NAY,
        ABSENT
    }

    struct Slot {
        // 프로포절 제안 정족 수량 - 총 발행량의 10%으로 설정할 것
        uint96 proposalQuorum;
        // 투표 정족 수 - 총 발행량의 10%으로 설정할 것
        uint96 voteQuorum;
        // 투표 시작 지연 기간 - 1일
        uint32 voteStartDelay;
        // 투표 기간 - 5일
        uint32 votePeriod;
        // 투표 변경 가능 period - 2일
        uint32 voteChangableDelay;
        // 투표권 모듈 컨트랙트 정보
        address voteModule;
        // 이전 투표권 모듈
        address prevModule;
    }

    /// @notice 프로포절에 대한 투표 정보 기록
    struct Proposal {
        uint32 startTime;
        uint32 endTime;
        uint96 yea;
        uint96 nay;
        uint96 abstain;
        uint96 totalVotes;
        uint32 blockNumber;
        uint32 timestamp;
        uint32 epoch; // 블록이 포함되어 있는 1주 단위의 epoch 또는 블록 번호... 타임 스탬프 흠
        mapping(address => Vote) votes;
    }

    /// @notice 개개인의 투표 정보 기록
    struct Vote {
        uint32 ts;
        VoteState state;
    }

    event Proposed(bytes32 uid);
}

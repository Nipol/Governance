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
        UNKNOWN, // 사용되지 않음
        PENDING, // 투표가 시작되길 기다림
        ACTIVE, // 투표가 진행중
        STANDBY, // 투표가 종료되어 집계를 기다림
        QUEUED, // 거버넌스로 제안 전송됨
        LEFTOUT // 거버전스로 제안되지 않고 버려짐
    }
    enum VoteState {
        UNKNOWN,
        YEA,
        NAY,
        ABSENT
    }

    struct Slot {
        /// SLOT 0 START ---------- ----------
        // 프로포절 제안 정족 수량 - ex) 총 발행량의 10%
        uint96 proposalQuorum;
        // 투표 정족 수 - ex) 총 발행량의 50%
        uint96 voteQuorum;
        // 투표 시작 지연 기간 - ex) 1일
        uint32 voteStartDelay;
        // 투표 기간 - ex) 5일
        uint32 votePeriod;
        /// SLOT 1 START ---------- ----------
        // 투표 변경 가능 period - ex) 2일
        uint32 voteChangableDelay;
        // 투표권 모듈 컨트랙트 정보
        address voteModule;
        uint64 slot1dummy64;
        /// SLOT 2 START ---------- ----------
        // 이전 투표권 모듈
        address prevModule;
        uint96 slot2dummy96;
    }

    /// @notice 프로포절에 대한 투표 정보 기록
    struct Proposal {
        /// SLOT 0 START ---------- ----------
        address governance;
        uint32 startTime;
        uint32 endTime;
        uint32 timestamp; /// slot 0
        /// SLOT 1 START ---------- ----------
        uint32 blockNumber;
        uint32 epoch;
        uint96 yea;
        uint96 nay; /// slot 1
        /// SLOT 2 START ---------- ----------
        uint96 totalVotes;
        bool queued;
        bool leftout;
        /// padding158bit
        /// SLOT 3 START ---------- ----------
        mapping(address => Vote) votes;
    }

    /// @notice 개개인의 투표 정보 기록
    struct Vote {
        uint32 ts;
        VoteState state;
    }

    event Proposed(bytes32 uid);
}

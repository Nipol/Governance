/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

/**
 * @title ICouncil
 * @author yoonsung.eth
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

    //
    struct Checkpoint {
        uint128 fromBlock;
        uint128 votes;
    }

    struct WithdrawPoint {
        uint96 amount0;
        uint96 amount1;
        uint64 timestamp;
    }

    struct StakeParam {
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct StakeSingleParam {
        uint256 amountIn;
        uint256 amountInForSwap;
        uint256 amountOutMin;
        bool isAmountIn0;
        uint256 deadline;
    }

    struct Slot {
        /// SLOT 0 START ---------- ----------
        // 제안 정족 수량 비율 - ex) 총 발행량의 10%
        uint16 proposalQuorum;
        // 제안 통과 정족 수 - ex) 총 발행량의 50%
        uint16 voteQuorum;
        // 긴급 제안 통과 비율 - ex) 총 발행량의 95%
        uint16 emergencyQuorum;
        // 투표 시작 지연 기간 - ex) 1일을 초로 환산
        uint32 voteStartDelay;
        // 투표 기간 - ex) 5일
        uint32 votePeriod;
        // 투표 변경 가능 period - ex) 2일
        uint32 voteChangableDelay;
        // 출금 기간 - ex) 6 month
        uint32 withdrawDelay;
    }

    /// @notice 프로포절에 대한 투표 정보 기록
    struct Proposal {
        address governance;
        uint32 startTime;
        uint32 endTime;
        uint32 blockNumber;
        uint128 yea;
        uint128 nay;
        uint128 abstain;
        uint128 totalVotes;
        bool queued;
        bool leftout;
        mapping(address => Vote) votes;
        bytes32[] spells;
        bytes[] elements;
    }

    /// @notice 개개인의 투표 정보 기록
    struct Vote {
        uint32 ts;
        VoteState state;
    }

    event Proposed(bytes32 indexed uid);
    event Voted(address indexed voter, bytes32 indexed uid, uint256 power);
    event Resolved(bytes32 indexed uid);

    function propose(address governance, bytes32[] calldata spells, bytes[] calldata elements) external;

    function vote(bytes32 proposalId, bool support) external;

    function resolve(bytes32 proposalId) external returns (bool success);
}

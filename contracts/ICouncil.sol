/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

/**
 * @title ICouncil
 */
interface ICouncil {
    enum States { UNKNOWN, YAY, NAY, ABSENT }

    struct inside {
        // 최소 프로포절 제안 가능 수량
        // 최소 투표 참여 수량
        // 최소 투표 기간
        // 투표 변경 period
    }

    struct Vote {
        uint96 forVote;
        uint96 againstVote;
    }

    struct Receipt {
        uint32 timestamp;
        States stats;
    }


}

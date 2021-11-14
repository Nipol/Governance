/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

contract VoteForV3Liquidity {
    address public immutable voteToken;

    bytes4 public constant STAKE_SIG = 0x12345678;
    bytes4 public constant UNSTAKE_SIG = 0x12345678;
    constructor(address token) {
        voteToken = token;
    }

    /// 투표권 비표준 토큰 주소

    /// 입금

    /// 출금

    /// 토큰 수량, balanceof
}

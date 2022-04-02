/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

contract VoteForV3Liquidity {
    function initialize(bytes calldata data) external {
        address token = abi.decode(data, (address));
        // StakeStorage.Storage storage s = StakeStorage.stakeStorage();
        // s.voteToken = token;
    }

    /// 투표권 비표준 토큰 주소

    /// 입금

    /// 출금

    /// 토큰 수량, balanceof
}

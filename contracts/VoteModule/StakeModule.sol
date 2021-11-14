/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

import "@beandao/contracts/interfaces/IERC20.sol";

library StakeStorage {
    bytes32 constant POSITION = keccak256("dao.bean.stakemodule");

    struct Storage {
        mapping(address => uint256) balanceOf;
    }

    function stakeStorage() internal pure returns (Storage storage s) {
        bytes32 position = POSITION;
        assembly {
            s.slot := position
        }
    }
}

contract StakeModule {
    address public immutable voteToken;
    bytes4 public constant STAKE_SIG = 0xa694fc3a;
    bytes4 public constant UNSTAKE_SIG = 0x2e17de78;
    bytes4 public constant PRIOR_VOTE = 0x83115109;

    constructor(address token) {
        voteToken = token;
    }

    function stake(uint256 amount) external returns (bool success) {
        StakeStorage.Storage storage s = StakeStorage.stakeStorage();
        require(IERC20(voteToken).transferFrom(msg.sender, address(this), amount));
        s.balanceOf[msg.sender] = amount;
        return true;
    }

    function unstake(uint256 amount) external returns (bool success) {
        StakeStorage.Storage storage s = StakeStorage.stakeStorage();
        s.balanceOf[msg.sender] -= amount;
        require(IERC20(voteToken).transfer(msg.sender, amount));
        return true;
    }

    function getPriorVote(address target, uint256 epoch) external returns (uint256 vote) {
        
    }

    /// 투표권 비표준 토큰 주소

    /// 입금

    /// 출금

    /// 토큰 수량, balanceof
}

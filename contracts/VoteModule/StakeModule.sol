/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

import "@beandao/contracts/interfaces/IERC20.sol";
import "./IModule.sol";

library StakeStorage {
    bytes32 constant POSITION = keccak256("dao.bean.stakemodule");

    struct Checkpoint {
        uint32 fromBlock;
        uint96 power;
    }

    struct Storage {
        mapping(address => mapping(uint32 => Checkpoint)) checkpoints;
        mapping(address => uint32) numCheckpoints;
        // mapping(address => uint256) balanceOf;
    }

    function stakeStorage() internal pure returns (Storage storage s) {
        bytes32 position = POSITION;
        assembly {
            s.slot := position
        }
    }
}

contract StakeModule is IModule {
    address public immutable voteToken;

    constructor(address token) {
        voteToken = token;
    }

    // self Delegate
    function stake(uint96 amount) external returns (bool success) {
        StakeStorage.Storage storage s = StakeStorage.stakeStorage();
        require(IERC20(voteToken).transferFrom(msg.sender, address(this), amount));

        uint32 blockNumber = uint32(block.number);
        uint32 nCheckpoints = s.numCheckpoints[msg.sender];
        s.checkpoints[msg.sender][nCheckpoints] = StakeStorage.Checkpoint({fromBlock: blockNumber, power: amount});
        s.numCheckpoints[msg.sender] = nCheckpoints + 1;
        success = true;
    }

    function unstake(uint96 amount) external returns (bool success) {
        StakeStorage.Storage storage s = StakeStorage.stakeStorage();

        uint32 blockNumber = uint32(block.number);
        uint32 nCheckpoints = s.numCheckpoints[msg.sender];
        (s.checkpoints[msg.sender][nCheckpoints].fromBlock, s.checkpoints[msg.sender][nCheckpoints].power) = (
            blockNumber,
            s.checkpoints[msg.sender][nCheckpoints].power - amount
        );
        s.numCheckpoints[msg.sender] = nCheckpoints + 1;
        require(IERC20(voteToken).transfer(msg.sender, amount));
        success = true;
    }

    function delegate(address delegatee) external returns (bool success) {}

    function delegateWithSig(
        address delegatee,
        bytes32 r,
        bytes32 s,
        uint8 v
    ) external returns (bool success) {}

    /// @inheritdoc IModule
    function getPriorPower(address target, uint256 blockNumber) external view returns (uint256 power) {
        require(blockNumber < block.number, "getPriorVotes: not yet determined");
        StakeStorage.Storage storage s = StakeStorage.stakeStorage();

        // 기록된 체크포인트 0의 블록이 값 보다 크면 0
        if (s.checkpoints[target][0].fromBlock > blockNumber) {
            return 0;
        }

        // 이용자의 checkpoint가 아무 것도 설정되어 있지 않다면, stake 하지 않은 것임.
        uint32 nCheckpoints = s.numCheckpoints[target];
        if (nCheckpoints == 0) {
            return 0;
        }

        // 블록이 보다 작다면, 마지막 투표 파워
        if (s.checkpoints[target][nCheckpoints - 1].fromBlock <= blockNumber) {
            return s.checkpoints[target][nCheckpoints - 1].power;
        }

        uint32 lower = 0;
        uint32 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint32 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            StakeStorage.Checkpoint memory cp = s.checkpoints[target][center];
            if (cp.fromBlock == blockNumber) {
                return cp.power;
            } else if (cp.fromBlock < blockNumber) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return s.checkpoints[target][lower].power;
    }
}

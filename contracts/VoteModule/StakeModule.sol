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
        uint256 totalSupply;
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

    function stake(uint96 amount) external returns (bool success) {
        StakeStorage.Storage storage s = StakeStorage.stakeStorage();
        require(IERC20(voteToken).transferFrom(msg.sender, address(this), amount));

        uint32 blockNumber = uint32(block.number);
        uint32 checkpoint = s.numCheckpoints[msg.sender];
        uint32 tcheckpoint = s.numCheckpoints[address(0)];
        unchecked {
            if (checkpoint > 0 && s.checkpoints[msg.sender][checkpoint - 1].fromBlock == blockNumber) {
                s.checkpoints[msg.sender][checkpoint - 1] = StakeStorage.Checkpoint({
                    fromBlock: blockNumber,
                    power: s.checkpoints[msg.sender][checkpoint - 1].power += amount
                });
            } else {
                s.checkpoints[msg.sender][checkpoint] = StakeStorage.Checkpoint({
                    fromBlock: blockNumber,
                    power: amount
                });
                s.numCheckpoints[msg.sender]++;
            }

            s.totalSupply += amount;

            if (tcheckpoint > 0 && s.checkpoints[address(0)][tcheckpoint - 1].fromBlock == blockNumber) {
                s.checkpoints[address(0)][tcheckpoint - 1].power = uint96(s.totalSupply);
            } else {
                s.checkpoints[address(0)][tcheckpoint] = StakeStorage.Checkpoint({
                    fromBlock: blockNumber,
                    power: uint96(s.totalSupply)
                });
                s.numCheckpoints[address(0)]++;
            }
        }
        success = true;
    }

    function unstake(uint96 amount) external returns (bool success) {
        StakeStorage.Storage storage s = StakeStorage.stakeStorage();

        uint32 blockNumber = uint32(block.number);
        uint32 checkpoint = s.numCheckpoints[msg.sender];
        uint32 tcheckpoint = s.numCheckpoints[address(0)];
        assert(checkpoint > 0);
        s.checkpoints[msg.sender][checkpoint] = StakeStorage.Checkpoint({
            fromBlock: blockNumber,
            power: s.checkpoints[msg.sender][checkpoint].power -= amount
        });
        require(IERC20(voteToken).transfer(msg.sender, amount));
        unchecked {
            s.numCheckpoints[msg.sender]++;

            s.totalSupply -= amount;
            s.checkpoints[address(0)][tcheckpoint] = StakeStorage.Checkpoint({
                fromBlock: blockNumber,
                power: s.checkpoints[address(0)][tcheckpoint].power -= amount
            });
            s.numCheckpoints[address(0)]++;
        }
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
        power = getVotes(target, blockNumber);
    }

    /// @inheritdoc IModule
    function getPriorRate(address target, uint256 blockNumber) external view returns (uint256 rate) {
        require(blockNumber < block.number, "getPriorVotes: not yet determined");
        rate = (getVotes(target, blockNumber) * 1e4) / getVotes(address(0), blockNumber);
    }

    function getPowerToRate(uint256 power, uint256 blockNumber) external view returns (uint256 rate) {
        require(blockNumber < block.number, "getPriorVotes: not yet determined");
        rate = (power * 1e4) / getVotes(address(0), blockNumber);
    }

    function supportsInterface(bytes4 interfaceID) external pure returns (bool) {
        return interfaceID == type(IModule).interfaceId || interfaceID == type(IERC165).interfaceId;
    }

    function getVotes(address target, uint256 blockNumber) internal view returns (uint256) {
        StakeStorage.Storage storage s = StakeStorage.stakeStorage();

        // 이용자의 checkpoint가 아무 것도 설정되어 있지 않다면, stake 하지 않은 것임.
        uint32 nCheckpoints = s.numCheckpoints[target];
        if (nCheckpoints == 0) {
            return 0;
        }

        // 블록이 보다 작다면, 마지막 투표 파워
        if (s.checkpoints[target][nCheckpoints - 1].fromBlock <= blockNumber) {
            return s.checkpoints[target][nCheckpoints - 1].power;
        }

        // 기록된 체크포인트 0의 블록이 값 보다 크면 0
        // 추가 스테이킹이 있는 경우, 0으로 잡힘...
        if (s.checkpoints[target][0].fromBlock > blockNumber) {
            return 0;
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

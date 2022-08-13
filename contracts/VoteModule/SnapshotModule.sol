/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

import "@beandao/contracts/interfaces/IERC20.sol";
import "@beandao/contracts/interfaces/IERC165.sol";
import "./IModule.sol";

error NotEnoughVotes();
error NotAllowedAddress(address delegatee);
contract SnapshotModule is IModule, IERC165 {
    struct Checkpoint {
        uint32 fromBlock;
        uint224 votes;
    }

    struct Storage {
        mapping(address => uint256) balances;
        mapping(address => address) delegates;
        mapping(address => Checkpoint[]) checkpoints;
        Checkpoint[] totalCheckpoints;
    }

    bytes32 constant POSITION = keccak256("eth.dao.bean.stakemodule.snapshot");
    address public immutable council;
    address public immutable token;

    event Delegate(address to, uint256 prevVotes, uint256 nextVotes);

    modifier onlyDelegateCouncil() {
        if (address(this) != council) revert();
        _;
    }

    /**
     * @param tokenAddr 인코딩된 투표권으로 사용할 토큰 컨트랙트 주소
     */
    constructor(address councilAddr, address tokenAddr) {
        council = councilAddr;
        token = tokenAddr;
    }

    /**
     * @notice 해당 모듈에 지정된 토큰을 입력된 수량만큼 예치하여 투표권으로 바꿔둡니다.
     */
    function stake(uint256 amount) external {
        if (!(amount != 0)) revert();
        Storage storage s = moduleStorage();
        address currentDelegatee = s.delegates[msg.sender];

        safeTransferFrom(token, msg.sender, address(this), amount);
        unchecked {
            s.balances[msg.sender] += amount;
        }

        // 누군가에게 위임을 했다면,
        if (currentDelegatee != msg.sender && currentDelegatee != address(0)) {
            // 추가된 수량만큼 기존 위임자에게 위임 수량 증가.
            delegateVotes(address(0), currentDelegatee, amount);
        } else {
            delegateVotes(address(0), msg.sender, amount);
            s.delegates[msg.sender] = msg.sender;
        }

        writeCheckpoint(s.totalCheckpoints, _add, amount);
    }

    /**
     * @notice 해당 모듈에 지정된 토큰을 입력된 수량만큼 예치하여 투표권으로 변경하고, 투표권을 다른 주소에게 위임합니다.
     */
    function stakeWithDelegate(uint256 amount, address delegatee) external {
        if (!(amount != 0)) revert();
        if (delegatee == msg.sender || delegatee == address(0)) revert();
        Storage storage s = moduleStorage();
        (address currentDelegatee, uint256 latestBalance) = (s.delegates[msg.sender], s.balances[msg.sender]);

        // 추가되는 투표권 카운슬로 전송
        safeTransferFrom(token, msg.sender, address(this), amount);

        // 추가되는 만큼 밸런스 업데이트
        unchecked {
            s.balances[msg.sender] += amount;
        }

        // 위임 대상이 기존과 동일하다면 추가 금액만 위임.
        if (delegatee == currentDelegatee) {
            delegateVotes(address(0), delegatee, amount);
        } else {
            // 다른 위임 대상이라면 이전 위임을 취소하여 투표권을 새로운 대상으로 변경
            delegateVotes(currentDelegatee, delegatee, latestBalance);
            // 새로운 투표권을 새로운 delegatee에게 위임
            delegateVotes(address(0), delegatee, amount);
            // 누구에게 위임하고 있는지 정보 변경,
            s.delegates[msg.sender] = delegatee;
        }

        // 총 위임량 업데이트
        writeCheckpoint(s.totalCheckpoints, _add, amount);
    }

    /**
     * @notice 예치된 투표권을 토큰으로 변환하여 출금합니다.
     */
    function unstake(uint256 amount) external {
        // 수량 0이 들어오는 경우 취소됩니다.
        if (!(amount != 0)) revert();

        Storage storage s = moduleStorage();
        (address currentDelegatee, uint256 latestBalance) = (s.delegates[msg.sender], s.balances[msg.sender]);

        // 현재 위임된 수량 해지.
        delegateVotes(currentDelegatee, address(0), amount);
        unchecked {
            // 잔액이 0이라면 기존 밸런스 모두 삭제.
            if (latestBalance - amount == 0) {
                delete s.balances[msg.sender];
                delete s.delegates[msg.sender];
            } else {
                // 잔액이 남았다면 차감만 함
                s.balances[msg.sender] -= amount;
            }
        }

        // 총 위임량 업데이트
        writeCheckpoint(s.totalCheckpoints, _sub, amount);

        safeTransfer(token, msg.sender, amount);
    }

    /**
     * @notice 예치된 투표권을 특정 주소로 위임합니다.
     */
    function delegate(address delegatee) external {
        if (delegatee == address(0)) revert NotAllowedAddress(delegatee);
        Storage storage s = moduleStorage();
        (address currentDelegate, uint256 latestBalance) = (s.delegates[msg.sender], s.balances[msg.sender]);

        if (latestBalance == 0) revert NotEnoughVotes();

        if (currentDelegate != delegatee) {
            delegateVotes(currentDelegate, delegatee, latestBalance);
            s.delegates[msg.sender] = delegatee;
        }
    }

    /**
     * @notice 특정 주소의 리비전에 따른 투표권 정보를 반환합니다.
     */
    function checkpoints(address account, uint32 pos) public view returns (Checkpoint memory) {
        Storage storage s = moduleStorage();
        return s.checkpoints[account][pos];
    }

    /**
     * @notice 누적된 특정 주소의 투표권 정보 개수를 가져옵니다.
     */
    function numCheckpoints(address account) public view returns (uint32) {
        Storage storage s = moduleStorage();
        return uint32(s.checkpoints[account].length);
    }

    /**
     * @notice 입력된 블록을 기준하여 주소의 정량적인 투표권을 가져옵니다
     * @param account 대상이 되는 주소
     * @param blockNumber 기반이 되는 블록 숫자
     * @return votes 투표 권한
     */
    function getPriorVotes(address account, uint256 blockNumber) external view returns (uint256 votes) {
        if (blockNumber > block.number) revert();
        Storage storage s = moduleStorage();
        votes = _checkpointsLookup(s.checkpoints[account], blockNumber);
    }

    /**
     * @notice 입력된 블록을 기준하여, 주소의 정량적인 투표권을 비율화하여 가져옵니다.
     * @param account 대상이 되는 주소
     * @param blockNumber 기반이 되는 블록 숫자
     * @return rate 비율
     */
    function getPriorRate(address account, uint256 blockNumber) external view returns (uint256 rate) {
        if (blockNumber > block.number) revert();
        Storage storage s = moduleStorage();

        rate =
            (_checkpointsLookup(s.checkpoints[account], blockNumber) * 1e4) /
            _checkpointsLookup(s.totalCheckpoints, blockNumber);
    }

    /**
     * @notice 입력된 블록을 기준하여, 특정 수치의 투표권을 총 투표권의 비율로 계산하는 함수
     * @param votes 계산하고자 하는 투표권한
     * @param blockNumber 기반이 되는 블록 숫자
     * @return rate 비율
     */
    function getVotesToRate(uint256 votes, uint256 blockNumber) external view returns (uint256 rate) {
        if (blockNumber > block.number) revert();
        Storage storage s = moduleStorage();
        rate = (votes * 1e4) / _checkpointsLookup(s.totalCheckpoints, blockNumber);
    }

    /**
     * @notice 해당 되는 블록 숫자를 기준하여 총 투표권 숫자를 반환합니다.
     */
    function getPriorTotalSupply(uint256 blockNumber) external view returns (uint256 totalVotes) {
        if (blockNumber > block.number) revert();
        Storage storage s = moduleStorage();
        totalVotes = _checkpointsLookup(s.totalCheckpoints, blockNumber);
    }

    /**
     * @notice 특정 주소의 총 예치 수량을 반환합니다.
     */
    function balanceOf(address target) public view returns (uint256 balance) {
        Storage storage s = moduleStorage();
        balance = s.balances[target];
    }

    /**
     * @notice 특정 주소의 총 투표권을 반환합니다.
     */
    function voteOf(address target) public view returns (uint256 votes) {
        Storage storage s = moduleStorage();
        uint256 length = s.checkpoints[target].length;
        unchecked {
            votes = length != 0 ? s.checkpoints[target][length - 1].votes : 0;
        }
    }

    /**
     * @notice 특정 주소가 투표권을 위임하고 있는 주소를 반환합니다.
     */
    function getDelegate(address target) public view returns (address delegatee) {
        Storage storage s = moduleStorage();
        delegatee = s.delegates[target];
    }

    /**
     * @notice 현재 총 투표권을 반환합니다.
     */
    function totalSupply() public view returns (uint256 amount) {
        Storage storage s = moduleStorage();
        unchecked {
            uint256 length = s.totalCheckpoints.length;
            amount = length != 0 ? s.totalCheckpoints[length - 1].votes : 0;
        }
    }

    /**
     * @notice 해당 모듈이 사용하는 토큰 주소를 반환합니다.
     */
    function getToken() public view returns (address) {
        return token;
    }

    /**
     * @notice amount 수량만큼, from으로 부터 to로 이관합니다.
     * @dev from이 Zero Address라면, 새로운 amount를 등록하는 것이며, to가 Zero Address라면 기존에 있던 amount를 감소시킵니다.
     * @param from 위임을 부여할 대상
     * @param to 위임이 이전될 대상
     * @param amount 위임 수량
     */
    function delegateVotes(
        address from,
        address to,
        uint256 amount
    ) internal {
        Storage storage s = moduleStorage();

        if (from != to && amount != 0) {
            if (from != address(0)) {
                (uint256 oldWeight, uint256 newWeight) = writeCheckpoint(s.checkpoints[from], _sub, amount);
                emit Delegate(from, oldWeight, newWeight);
            }

            if (to != address(0)) {
                (uint256 oldWeight, uint256 newWeight) = writeCheckpoint(s.checkpoints[to], _add, amount);
                emit Delegate(to, oldWeight, newWeight);
            }
        }
    }

    function writeCheckpoint(
        Checkpoint[] storage ckpts,
        function(uint256, uint256) view returns (uint256) op,
        uint256 delta
    ) internal returns (uint256 oldWeight, uint256 newWeight) {
        uint256 length = ckpts.length;
        oldWeight = length != 0 ? ckpts[length - 1].votes : 0;
        newWeight = op(oldWeight, delta);

        if (length > 0 && ckpts[length - 1].fromBlock == block.number) {
            ckpts[length - 1].votes = uint224(newWeight);
        } else {
            ckpts.push(Checkpoint({fromBlock: uint32(block.number), votes: uint224(newWeight)}));
        }
    }

    function safeTransferFrom(
        address tokenAddr,
        address from,
        address to,
        uint256 amount
    ) internal returns (bool success) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            let freePointer := mload(0x40)
            mstore(freePointer, 0x23b872dd00000000000000000000000000000000000000000000000000000000)
            mstore(add(freePointer, 4), from)
            mstore(add(freePointer, 36), to)
            mstore(add(freePointer, 68), amount)

            let callStatus := call(gas(), tokenAddr, 0, freePointer, 100, 0, 0)

            let returnDataSize := returndatasize()
            if iszero(callStatus) {
                // Copy the revert message into memory.
                returndatacopy(0, 0, returnDataSize)

                // Revert with the same message.
                revert(0, returnDataSize)
            }
            switch returnDataSize
            case 32 {
                // Copy the return data into memory.
                returndatacopy(0, 0, returnDataSize)

                // Set success to whether it returned true.
                success := iszero(iszero(mload(0)))
            }
            case 0 {
                // There was no return data.
                success := 1
            }
            default {
                // It returned some malformed input.
                success := 0
            }
        }
    }

    function safeTransfer(
        address tokenAddr,
        address to,
        uint256 amount
    ) internal returns (bool success) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            let freePointer := mload(0x40)
            mstore(freePointer, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
            mstore(add(freePointer, 4), to)
            mstore(add(freePointer, 36), amount)

            let callStatus := call(gas(), tokenAddr, 0, freePointer, 68, 0, 0)

            let returnDataSize := returndatasize()
            if iszero(callStatus) {
                // Copy the revert message into memory.
                returndatacopy(0, 0, returnDataSize)

                // Revert with the same message.
                revert(0, returnDataSize)
            }
            switch returnDataSize
            case 32 {
                // Copy the return data into memory.
                returndatacopy(0, 0, returnDataSize)

                // Set success to whether it returned true.
                success := iszero(iszero(mload(0)))
            }
            case 0 {
                // There was no return data.
                success := 1
            }
            default {
                // It returned some malformed input.
                success := 0
            }
        }
    }

    function _checkpointsLookup(Checkpoint[] storage ckpts, uint256 blockNumber) private view returns (uint256 votes) {
        uint256 high = ckpts.length;
        uint256 low = 0;
        uint256 mid;
        while (low < high) {
            unchecked {
                mid = ((low & high) + (low ^ high) / 2);
            }
            if (ckpts[mid].fromBlock > blockNumber) {
                high = mid;
            } else {
                unchecked {
                    low = mid + 1;
                }
            }
        }

        unchecked {
            votes = high != 0 ? ckpts[high - 1].votes : 0;
        }
    }

    function _add(uint256 a, uint256 b) private pure returns (uint256) {
        return a + b;
    }

    function _sub(uint256 a, uint256 b) private pure returns (uint256) {
        return a - b;
    }

    function supportsInterface(bytes4 interfaceID) external pure returns (bool) {
        return interfaceID == type(IModule).interfaceId || interfaceID == type(IERC165).interfaceId;
    }

    function moduleStorage() internal pure returns (Storage storage s) {
        bytes32 position = POSITION;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            s.slot := position
        }
    }
}

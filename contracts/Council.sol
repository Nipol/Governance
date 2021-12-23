/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

import "@beandao/contracts/library/Initializer.sol";
import "./VoteModule/IModule.sol";
import "./IGovernance.sol";
import {ICouncil, IERC165} from "./ICouncil.sol";

/**
 * @title Council
 * @notice 투표권과 투표 정보를 컨트롤하는 컨트랙트. 거버넌스 정보는 이곳에 저장하지 않으며,
 * @dev 다른 투표 모듈과의 상호작용 필요함
 */
contract Council is ICouncil, Initializer {
    string public constant version = "1";
    Slot public slot;
    /**
     * @notice 프로포절에 기록된 투표 정보
     */
    mapping(bytes32 => Proposal) public proposals;

    function initialize(
        address voteModuleAddr,
        uint96 proposalQuorum,
        uint96 voteQuorum,
        uint32 voteStartDelay,
        uint32 votePeriod,
        uint32 voteChangableDelay
    ) external initializer {
        slot.voteModule = voteModuleAddr;
        slot.proposalQuorum = proposalQuorum;
        slot.voteQuorum = voteQuorum;
        slot.voteStartDelay = voteStartDelay;
        slot.votePeriod = votePeriod;
        slot.voteChangableDelay = voteChangableDelay;
    }

    /**
     * @notice 현재 컨트랙트에서 일치하지 않는 인터페이스를 voteModule로 이관하기 위한
     */
    fallback() external payable {
        address module = slot.voteModule;
        assembly {
            // copy function selector and any arguments
            calldatacopy(0, 0, calldatasize())
            // execute function call using the facet
            let result := delegatecall(gas(), module, 0, calldatasize(), 0, 0)
            // get any return value
            returndatacopy(0, 0, returndatasize())
            // return any return value or error back to the caller
            switch result
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }

    receive() external payable {
        revert();
    }

    /**
     * @notice 거버넌스로 제안서를 보내는 역할을 하며, 해당 컨트랙트에서도 투표만을 위한 제안서를 동일하게 생성한다.
     * @param governance Council이 목표로 하는 거버넌스 컨트랙트 주소
     * @param spells GPE-command array
     * @param elements variable for commands array
     */
    function propose(
        address governance,
        bytes32[] memory spells,
        bytes[] calldata elements
    ) external {
        // 한 블럭 이전 or 지난 epoch에, msg.sender의 보팅 권한이 최소 쿼럼을 만족하는지 체크
        require(
            IModule(address(this)).getPriorPower(msg.sender, block.number - 1) >= slot.proposalQuorum,
            "Council/Not Reached Quorum"
        );

        // 투표 시작 지연 추가
        uint32 start = uint32(block.timestamp) + slot.voteStartDelay;
        uint32 end = start + slot.votePeriod;
        // 거버넌스 컨트랙트에 등록할 proposal 정보
        IGovernance.ProposalParams memory params = IGovernance.ProposalParams({
            proposer: msg.sender,
            spells: spells,
            elements: elements
        });

        // 거버넌스 컨트랙트에 proposal 등록
        (bytes32 proposalId, ) = IGovernance(governance).propose(params);
        // 반횐된 uid에 대해 council 버전의 proposal 저장.
        (ProposalState state, Proposal storage p) = getProposalState(proposalId);
        // 한번도 사용되지 않은 유니크 아이디인지 확인
        assert(state == ProposalState.UNKNOWN); // check never used
        (p.governance, p.startTime, p.endTime, p.timestamp, p.blockNumber) = (
            governance,
            start,
            end,
            uint32(block.timestamp), // block timestamp for Verification.
            uint32(block.number) // block number for Verification.
        );
        // p.epoch = 0 // Epoch logic... TODO
        emit Proposed(proposalId);
    }

    /**
     * @notice 제안서에 투표를 하며, 투표 상태가 활성화 되어 있어야만 가능 함.
     * 투표를 변경하는 경우 변경에 필요한 지연이 충분히 지나고, 이전 투표를 새 투표로 옮김
     * @param proposalId 제안서의 고유 아이디
     * @param support 해시 형태로, 어떤 값에 투표할 것인지 -> 값의 스펙트럼이 넓은 이유는 off-chain vote를 위한 것
     */
    function vote(bytes32 proposalId, uint8 support) external {
        (ProposalState state, Proposal storage p) = getProposalState(proposalId);
        // 존재하는 Proposal인지 & 활성 상태인지 확인
        assert(state == ProposalState.ACTIVE);
        // 기록된 블록의 - 1 기준으로 투표권 확인
        uint256 power = IModule(address(this)).getPriorPower(msg.sender, p.blockNumber - 1);
        Vote storage v = p.votes[msg.sender];
        // timestamp 0인지 체크 -> 처음 투표 과정(support 에 따라서 파워 기록, votes에 기록)
        if (v.ts == 0) {
            v.ts = uint32(block.timestamp);
            v.state = support == 0x00 ? VoteState.YEA : support == 0x01 ? VoteState.NAY : VoteState.UNKNOWN;
            p.totalVotes += uint96(power);
            p.yea += support == 0x00 ? uint96(power) : 0;
            p.nay += support == 0x01 ? uint96(power) : 0;
        } else {
            // 투표 딜레이 확인
            require((v.ts + slot.voteChangableDelay) < uint32(block.timestamp), "Not Reached delay");
            // 새로운 타임스탬프 기록
            v.ts = uint32(block.timestamp);
            // 이전 투표 파워 삭제
            p.yea -= support == 0x00 ? uint96(power) : 0;
            p.nay -= support == 0x01 ? uint96(power) : 0;
            // 새로운 투표 상태 업데이트
            v.state = support == 0x00 ? VoteState.YEA : support == 0x01 ? VoteState.NAY : VoteState.UNKNOWN;
            // 새로운 투표 파워 업데이트
            p.yea += support == 0x00 ? uint96(power) : 0;
            p.nay += support == 0x01 ? uint96(power) : 0;
        }
        // 만약 기록되어 있다면, 투표 딜레이 지났는지 확인하고, 바뀐 투표 확인하고, 이전 power 줄이고, 새로운 Power 상승. 타임스탬프 기록
    }

    /**
     * @notice 투표 기간이 종료 되었을 때 투표 상태를 검증하여, 거버넌스로 투표 정보에 따른 실행 여부를 전송함.
     * @param proposalId 제안서의 고유 아이디
     */
    function resolve(bytes32 proposalId) external returns (bool success) {
        (ProposalState state, Proposal storage p) = getProposalState(proposalId);
        require(state == ProposalState.STANDBY, "Council/Can't Resolvable");
        // 총 투표량이 쿼럼을 넘는지 체크
        require(p.totalVotes >= slot.voteQuorum, "Council/Not Reached Quorum");
        // yea > nay -> queued -> 거버넌스의 대기열에 등록
        // nay < yea -> leftout -> 거버넌스의 canceling
        (p.queued, p.leftout) = p.yea > p.nay
            ? (IGovernance(p.governance).ready(proposalId), false)
            : (false, IGovernance(p.governance).drop(proposalId));
        success = true;
    }

    function getProposalState(bytes32 proposalId) internal view returns (ProposalState state, Proposal storage p) {
        p = proposals[proposalId];
        if (p.startTime == 0) {
            state = ProposalState.UNKNOWN;
        } else if (p.startTime > uint32(block.timestamp)) {
            state = ProposalState.PENDING;
        } else if (p.startTime <= uint32(block.timestamp) && p.endTime > uint32(block.timestamp)) {
            state = ProposalState.ACTIVE;
        } else if (p.startTime < uint32(block.timestamp) && p.endTime <= uint32(block.timestamp)) {
            state = p.queued == true ? ProposalState.QUEUED : p.leftout == true
                ? ProposalState.LEFTOUT
                : ProposalState.STANDBY;
        }
    }

    function supportsInterface(bytes4 interfaceID) external pure returns (bool) {
        return interfaceID == type(ICouncil).interfaceId || interfaceID == type(IERC165).interfaceId;
    }
}

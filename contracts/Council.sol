/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

import "@beandao/contracts/library/Initializer.sol";
import "@beandao/contracts/interfaces/IERC165.sol";
import "./VoteModule/IModule.sol";
import "./IGovernance.sol";
import "./ICouncil.sol";

error Council__NotReachedDelay();

error Council__NotReachedQuorum();

error Council__NotResolvable(bytes32 proposalId);

error Council__AlreadyProposed(bytes32 proposalId);

error Council__NotActiveProposal(bytes32 proposalId);

error Council__AlreadyVoted(bytes32 proposalId, bool vote);

/**
 * @title Council
 * @notice 투표권과 투표 정보를 컨트롤하는 컨트랙트. 거버넌스 정보는 이곳에 저장하지 않으며 거버넌스가 신뢰할 Council이 있음
 * 투표는 최대 255개의 타입을 가질 수 있으며, 타입마다 해석의 방식을 지정할 수 있다.
 * @dev
 */
contract Council is IERC165, ICouncil {
    string public constant version = "1";
    address public voteModule;
    Slot public slot;

    /**
     * @notice 프로포절에 기록된 투표 정보
     */
    mapping(bytes32 => Proposal) public proposals;

    /**
     * @notice 컨트랙트를 초기화 하기 위한 함수이며, 단 한 번만 실행이 가능합니다.
     * @param proposalQuorum 제안서를 만들기 위한 제안 임계 백분율, 최대 10000
     * 긴급 제안서 만들기 위한 임계값?
     * @param emergencyQuorum 긴급 제안서를 통과 시키기 위한 임계 백분율, 최대 10000
     * @param voteQuorum 제안서를 통과시키기 위한 임계 백분율, 최대 10000
     * @param voteStartDelay 제안서의 투표 시작 지연 값, 단위 일
     * @param votePeriod 제안서의 투표 기간, 단위 일
     * @param voteChangableDelay 투표를 변경할 때 지연 값, 단위 일
     */
    constructor(
        uint16 proposalQuorum,
        uint16 voteQuorum,
        uint16 emergencyQuorum,
        uint32 voteStartDelay,
        uint32 votePeriod,
        uint32 voteChangableDelay
    ) {
        require(proposalQuorum <= 1e4);
        require(voteQuorum <= 1e4);
        require(emergencyQuorum <= 1e4);
        (
            slot.proposalQuorum,
            slot.voteQuorum,
            slot.emergencyQuorum,
            slot.voteStartDelay,
            slot.votePeriod,
            slot.voteChangableDelay
        ) = (proposalQuorum, voteQuorum, emergencyQuorum, voteStartDelay, votePeriod, voteChangableDelay);
    }

    /**
     * @notice 현재 컨트랙트에서 일치하지 않는 인터페이스를 voteModule로 이관하기 위한
     */
    fallback() external payable {
        address module = voteModule;
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

    function initialVoteModule(address voteModuleAddr) external {
        if (voteModule != address(0)) revert();
        voteModule = voteModuleAddr;
    }

    /**
     * @notice 거버넌스로 제안서를 보내는 역할을 하며, 해당 컨트랙트에서도 투표만을 위한 제안서를 동일하게 생성한다.
     * @param governance Council이 목표로 하는 거버넌스 컨트랙트 주소
     * @param spells GPE-command array
     * @param elements variable for commands array
     */
    function propose(
        address governance,
        bytes32[] calldata spells,
        bytes[] calldata elements
    ) external {
        Slot memory s = slot;
        // 한 블럭 이전 or 지난 epoch에, msg.sender의 보팅 권한이 최소 쿼럼을 만족하는지 체크
        if (IModule(address(this)).getPriorRate(msg.sender, block.number - 1) < s.proposalQuorum)
            revert Council__NotReachedQuorum();

        // 투표 시작 지연 추가
        uint32 start = uint32(block.timestamp) + s.voteStartDelay;
        uint32 end = start + s.votePeriod;
        // 거버넌스에 등록할 proposal 정보
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
        if (state != ProposalState.UNKNOWN) revert Council__AlreadyProposed(proposalId);

        (p.governance, p.startTime, p.endTime, p.timestamp, p.blockNumber, p.spells, p.elements) = (
            governance,
            start,
            end,
            uint32(block.timestamp), // block timestamp for Verification.
            uint32(block.number), // block number for Verification.
            spells,
            elements
        );
        // p.epoch = 0 // Epoch logic... TODO
        emit Proposed(proposalId);
    }

    /**
     * TODO: 전용 구조체, 전용 이벤트, 날짜 uint8로 변경
     * @notice 응급 제안서를 처리하기 위한 전용함수
     * @param governance Council이 목표로 하는 거버넌스 컨트랙트 주소
     * @param spells GPE-command array
     * @param elements variable for commands array
     */
    function emergencyProposal(
        address governance,
        bytes32[] memory spells,
        bytes[] calldata elements
    ) external {}

    /**
     * @notice 제안서에 투표를 하며, 투표 상태가 활성화 되어 있어야만 가능 함.
     * 투표를 변경하는 경우 변경에 필요한 지연이 충분히 지나고, 이전 투표를 새 투표로 옮김
     * @param proposalId 제안서의 고유 아이디
     * @param support 해시 형태로, 어떤 값에 투표할 것인지 -> 값의 스펙트럼이 넓은 이유는 off-chain vote를 위한 것
     */
    function vote(bytes32 proposalId, bool support) external {
        (ProposalState state, Proposal storage p) = getProposalState(proposalId);
        // 존재하는 Proposal인지 & 활성 상태인지 확인
        if (state != ProposalState.ACTIVE) revert Council__NotActiveProposal(proposalId);
        // 기록된 블록의 - 1 기준으로 투표권 확인
        uint256 power = IModule(address(this)).getPriorVotes(msg.sender, p.blockNumber - 1);
        // 제안서의 현재 투표 상태
        Vote storage v = p.votes[msg.sender];
        // timestamp 0인지 체크 -> 처음 투표 과정(support 에 따라서 파워 기록, votes에 기록)
        if (v.ts == 0) {
            v.ts = uint32(block.timestamp);
            v.state = support ? VoteState.YEA : VoteState.NAY;
            p.yea += support ? uint96(power) : 0;
            p.nay += support ? 0 : uint96(power);
            p.totalVotes += uint96(power);
        } else {
            // 투표 변경 딜레이 확인
            if ((v.ts + slot.voteChangableDelay) > uint32(block.timestamp)) revert Council__NotReachedDelay();
            if (!support ? p.nay > 0 : p.yea > 0) revert Council__AlreadyVoted(proposalId, support);
            // 새로운 타임스탬프 기록
            v.ts = uint32(block.timestamp);
            // 이전 투표 파워 삭제
            p.yea -= support ? 0 : uint96(power);
            p.nay -= support ? uint96(power) : 0;
            // 새로운 투표 상태 업데이트
            v.state = support ? VoteState.YEA : VoteState.NAY;
            // 새로운 투표 파워 업데이트
            p.yea += support ? uint96(power) : 0;
            p.nay += support ? 0 : uint96(power);
        }
        emit Voted(msg.sender, proposalId, power);
    }

    /**
     * @notice 투표 기간이 종료 되었을 때 투표 상태를 검증하여, 거버넌스로 투표 정보에 따른 실행 여부를 전송함.
     * @param proposalId 제안서의 고유 아이디
     * @return success 해당 제안서가 검증을 통과했는지 여부
     */
    function resolve(bytes32 proposalId) external returns (bool success) {
        (ProposalState state, Proposal storage p) = getProposalState(proposalId);
        if (state != ProposalState.STANDBY) revert Council__NotResolvable(proposalId);
        // 총 투표량이 쿼럼을 넘는지 체크
        if (IModule(address(this)).getVotesToRate(p.totalVotes, p.blockNumber - 1) < slot.voteQuorum)
            revert Council__NotReachedQuorum();

        // yea > nay -> queued -> 거버넌스의 대기열에 등록
        // nay < yea -> leftout -> 거버넌스의 canceling
        (p.queued, p.leftout) = p.yea > p.nay
            ? (IGovernance(p.governance).approve(proposalId), false)
            : (false, IGovernance(p.governance).drop(proposalId));
        success = true;
        emit Resolved(proposalId);
    }

    function supportsInterface(bytes4 interfaceID) external pure returns (bool) {
        return interfaceID == type(ICouncil).interfaceId || interfaceID == type(IERC165).interfaceId;
    }

    function getProposalState(bytes32 proposalId) internal view returns (ProposalState state, Proposal storage p) {
        p = proposals[proposalId];

        if (p.startTime == 0) {
            // 시작시간 0이면 등록되지 않은 제안서
            state = ProposalState.UNKNOWN;
        } else if (p.startTime > uint32(block.timestamp)) {
            // 제안서에 기록된 시작 시간이 현재 시간 보다 클 때: 투표 대기중
            state = ProposalState.PENDING;
        } else if (p.startTime <= uint32(block.timestamp) && p.endTime > uint32(block.timestamp)) {
            // 제안서에 기록된 시작 시간이 현재 시간보다 작으며, 종료 시간이 현재 시간보다 클 때: 투표 중
            state = ProposalState.ACTIVE;
        } else if (p.startTime < uint32(block.timestamp) && p.endTime <= uint32(block.timestamp)) {
            state = p.queued == true ? ProposalState.QUEUED : p.leftout == true
                ? ProposalState.LEFTOUT
                : ProposalState.STANDBY;
        }
    }

    function name() public pure returns (string memory) {
        // Council
        // solhint-disable-next-line no-inline-assembly
        assembly {
            mstore(0x20, 0x20)
            mstore(0x4c, 0x07436f756e63696c)
            return(0x20, 0x60)
        }
    }
}

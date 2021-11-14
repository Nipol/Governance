/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

import "@beandao/contracts/library/Initializer.sol";
import "@beandao/contracts/library/Scheduler.sol";

import "./VoteModule/IModule.sol";
import "./ICouncil.sol";
import "./IGovernance.sol";

/**
 * @title Council
 * @notice 투표권과 투표 정보를 컨트롤하는 컨트랙트. 거버넌스 정보는 이곳에 저장하지 않으며,
 */
contract Council is ICouncil, Scheduler, Initializer {
    string public constant version = "1";
    Slot public slot;
    /**
     * @notice 프로포절에 기록된 투표 정보
     */
    mapping(bytes32 => Proposal) public proposals;

    function initialize(address voteModuleAddr, uint32 voteDelay) external initializer {
        slot.voteModule = voteModuleAddr;
        setDelay(voteDelay);
    }

    fallback() external payable {
        // get facet from function selector
        address module = slot.voteModule;
        // Execute external function from facet using delegatecall and return any value.
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

    function propose(
        address governance,
        bytes32[] memory spells,
        uint128[] calldata values,
        bytes[] calldata calldatas
    ) external {
        // 한 블럭 이전 or 지난 epoch에, msg.sender의 보팅 권한이 최소 쿼럼을 만족하는지 체크
        require(IModule(address(this)).getPriorVote(msg.sender, block.number) >= slot.proposalQuorum);

        // 투표 시작 지연 추가
        uint32 start = uint32(block.timestamp) + slot.voteDelay;
        uint32 end = start + delay;
        IGovernance.ProposalParams memory params = IGovernance.ProposalParams({
            proposer: msg.sender,
            startTime: start,
            endTime: end,
            spells: spells,
            values: values,
            calldatas: calldatas
        });
        (bytes32 uid, ) = IGovernance(governance).propose(params);
        Proposal storage p = proposals[uid];
        assert(p.state == ProposalState.UNKNOWN); // check never used
        (p.startTime, p.endTime, p.yea, p.nay, p.abstain, p.state) = (
            start,
            end,
            0,
            0,
            0,
            slot.voteDelay == 0 ? ProposalState.ACTIVE : ProposalState.PENDING
        );

        // Proposal({startTime: start, endTime: end, yay: 0, nay: 0});
        // proposals[uid] = p;
    }

    function vote(bytes32 proposalId, uint8 support) external {
        // 투표 가능 수량 가져오기
        // 투표 수량 입력하기
    }

    // function queue(bytes32 proposqlId) external {}
}

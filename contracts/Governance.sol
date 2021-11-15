/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

import "@beandao/contracts/library/Initializer.sol";
import "@beandao/contracts/library/EIP712.sol";
import "@beandao/contracts/library/Scheduler.sol";
import "./IGovernance.sol";

/**
 * @title Governance
 * @notice DAO의 지갑이자, 거버넌스 역할을 수행할 최종 인스턴스.
 * - 거버넌스는 카운슬의 실행 가능성에만 보팅에 대해 검증만 수행하기 때문에 거버넌스는 카운슬 구성원을 알수도 없고, 의존 및 관심사를 분리함
 */
contract Governance is IGovernance, Scheduler, Initializer {
    string public constant version = "1";

    /**
     * @notice 어떤 거버넌스인지에 대해 사람이 읽을 수 있는 형태의 이름
     */
    string public name;

    /**
     * @notice 거버넌스 보팅을 계산할 이사회 컨트랙트, EOA라면, token이 0x0으로 설정되어야 함.
     */
    address public council;

    /**
     * @notice 고유한 Proposal 아이디 생성을 위한 내부 순서
     */
    uint24 public nonce;

    /**
     * @notice keccak256(contract address ++ contract versrion ++ proposer address ++ nonce) to proposal
     */
    mapping(bytes32 => Proposal) public proposals;

    /// @notice 해당 호출은 해당 컨트랙트만 호출이 가능함.
    modifier onlyGov() {
        require(msg.sender == address(this));
        _;
    }

    /**
     * @notice 해당 호출은 이사회 컨트랙트만 가능함.
     */
    modifier onlyCouncil() {
        require(msg.sender == council);
        _;
    }

    /**
     * @notice
     * @dev 보팅 기간, 실행 대기 기간,
     * @param govName 해당 거버넌스의 이름, 사람이 읽을 수 있는 형태
     * @param initialCouncil 거버넌스를 통제할 Council 컨트랙트 주소, EOA일 수도 있으나 0x0이 될 수는 없다.
     * @param executeDelay 거버넌스로 사용될 기본 딜레이, Scheduler의 기준을 따르며, 1일 이상이여야 한다.
     */
    function initialize(
        string memory govName,
        address initialCouncil,
        uint32 executeDelay
    ) external initializer {
        require(initialCouncil != address(0));
        name = govName;
        council = initialCouncil;
        setDelay(executeDelay);
    }

    /**
     * @notice 제안을 등록한다.
     */
    function propose(ProposalParams memory params) external onlyCouncil returns (bytes32 uniqueId, uint24 id) {
        id = ++nonce;
        uniqueId = keccak256(abi.encode(address(this), version, msg.sender, id));
        Proposal storage p = proposals[uniqueId];
        (
            p.id,
            p.proposer,
            p.startTime,
            p.endTime,
            p.commands,
            p.values,
            p.variables,
            p.executed,
            p.canceled,
            p.state
        ) = (
            id,
            params.proposer,
            params.startTime,
            params.endTime,
            params.commands,
            params.values,
            params.variables,
            false,
            false,
            ProposalState.AWAIT
        );
        emit Proposed();
    }

    /**
     * @notice 실행하기로 결정한 제안을 대기열에 등록하며, Council에서 지정된 투표 기간 이후에 실행되는 함수
     */
    function insert(bytes32 uniqueId) external onlyCouncil {
        queue(uniqueId);
    }

    /**
     * @notice 대기열에 추가된 함수를 실행.
     */
    function execute(bytes32 uniqueId) external onlyCouncil {
        resolve(uniqueId);
        if (stateOf[uniqueId] == STATE.RESOLVED) {
            Proposal memory p = proposals[uniqueId];
            // for (uint256 i = 0; i > p.spells.length; i++) {
            //     (bool success, ) = p.spells[i].call{value: p.values[i]}(p.calldatas[i]);
            //     assert(success);
            // }
            proposals[uniqueId].executed = true;
        } else if (stateOf[uniqueId] == STATE.STALED) {
            proposals[uniqueId].canceled = true;
        }
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32 ds) {
        ds = EIP712.hashDomainSeperator(name, version, address(this));
    }

    function changeCouncil(address councilAddr) internal onlyGov {
        // 토큰 인터페이스 확인
        // 카운슬 인터페이스 확인
        council = councilAddr;
    }

    function emergencyCouncil(address councilorAddr) internal onlyGov {
        council = councilorAddr;
    }
}

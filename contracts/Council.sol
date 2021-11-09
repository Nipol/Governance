/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

import "@beandao/contracts/library/Initializer.sol";
import "./ICouncil.sol";

/**
 * @title Council
 * @notice 투표권을 계산하는 컨트랙트
 */
contract Council is ICouncil, Initializer {
    string public constant version = "1";

    /**
     * @notice 거버넌스의 결정이 어떤 토큰에 의해 결정되는지
     */
    address public token;

    /**
     * @notice 투표권 모듈
     */
    address public adaptor;

    /**
     * @notice 프로포절에 기록된 투표 정보
     */
    mapping(bytes32 => Vote) public votes;
    mapping(bytes32 => mapping(address => Receipt)) public VoteStates;

    function initialize(address tokenAddr, address adaptorAddr) external initializer {
        token = tokenAddr;
        adaptor = adaptorAddr;
    }

    function vote(bytes32 proposalId, uint8 support) external {
        // 투표 가능 수량 가져오기
        // 투표 수량 입력하기
    }

    function queue(bytes32 proposqlId) external {}

    function states(bytes32 proposalId) external returns (States) {
        // 프로포절이 언제 시작되었는지에 따라 달라지는 정보
    }
}

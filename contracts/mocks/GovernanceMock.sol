/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

import "../IGovernance.sol";

/**
 * @title Governance
 * @notice DAO의 지갑이자, 거버넌스 역할을 수행할 최종 인스턴스.
 * - 거버넌스는 카운슬의 실행 가능성에만 보팅에 대해 검증만 수행하기 때문에 거버넌스는 카운슬 구성원을 알수도 없고, 의존 및 관심사를 분리함
 */
contract GovernanceMock is IGovernance {
    function propose(ProposalParams memory params) external returns (bytes32 uniqueId, uint128 id) {
        uniqueId = bytes32(0x00000000000000000000000000000000000000000000000000000000000000f1);
        id = 0;
    }

    function approve(bytes32 proposalId) external returns (bool success) {
        success = true;
    }

    function drop(bytes32 proposalId) external returns (bool success) {
        success = true;
    }

    function execute(
        bytes32 proposalId,
        bytes32[] calldata spells,
        bytes[] calldata elements
    ) external {}

    function changeCouncil(address councilAddr) external {}

    function changeDelay(uint32 executeDelay) external {}

    function emergencyExecute(bytes32[] calldata spells, bytes[] memory elements) external {}

    function emergencyCouncil(address councilorAddr) external {}

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4 magicValue) {}

    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) external pure returns (bytes4) {
        return bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"));
    }
}

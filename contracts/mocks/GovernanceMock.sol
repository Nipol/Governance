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
    string public name;

    address public council;

    uint96 public nonce;

    mapping(bytes32 => Proposal) public proposals;

    function initialize(
        string memory govName,
        address initialCouncil,
        uint32 executeDelay
    ) external {}

    function propose(ProposalParams memory) external pure returns (bytes32 proposalId) {
        proposalId = bytes32(0x00000000000000000000000000000000000000000000000000000000000000f1);
    }

    function approve(bytes32) external pure returns (bool success) {
        success = true;
    }

    function drop(bytes32) external pure returns (bool success) {
        success = true;
    }

    function execute(bytes32 proposalId) external {}

    function changeCouncil(address) external {}

    function changeDelay(uint32) external {}

    function emergencyExecute(bytes32[] calldata, bytes[] memory) external {}

    function emergencyCouncil(address) external {}

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4 magicValue) {}

    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) external pure returns (bytes4) {
        return bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"));
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return 0xf23a6e61;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return 0xbc197c81;
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

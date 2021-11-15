/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

interface IModule {
    /**
     * @notice BlockNumber를 기반으로 한 target의 보팅 파워를 가져옵니다.
     * @dev 아래의 모든 정보들은 사용되지 않을 수 있습니다.
     * @param target 대상이 되는 주소
     * @param blockNumber 기반이 되는 블록 숫자
     */
    function getPriorPower(address target, uint256 blockNumber) external view returns (uint256 power);
}

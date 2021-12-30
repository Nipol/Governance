/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

import "@beandao/contracts/interfaces/IERC165.sol";

/**
 * @title IModule
 * @notice Council에서 사용할 Module 인터페이스
 */
interface IModule is IERC165 {
    /**
     * @notice BlockNumber를 기반으로, target의 정량적인 투표권을 가져옵니다.
     * @dev 아래의 모든 정보들은 사용되지 않을 수 있습니다.
     * @param target 대상이 되는 주소
     * @param blockNumber 기반이 되는 블록 숫자
     */
    function getPriorPower(address target, uint256 blockNumber) external view returns (uint256 power);

    /**
     * @notice BlockNumber를 기반으로, target의 투표권을 비율화 하여 가져옵니다.
     * @dev 아래의 모든 정보들은 사용되지 않을 수 있습니다.
     * @param target 대상이 되는 주소
     * @param blockNumber 기반이 되는 블록 숫자
     */
    function getPriorRate(address target, uint256 blockNumber) external view returns (uint256 rate);

    function getPowerToRate(uint256 power, uint256 blockNumber) external view returns (uint256 rate);
}

/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

/**
 * @title IModule
 * @notice Council에 부착 가능한 투표권 Module 인터페이스 집합
 */
interface IModule {
    /**
     * @notice 해당 모듈을 초기화하기 위한 함수 호출
     * @param data abi encode된 데이터가 주입되어 각 모듈에 맞게 해석합니다.
     */
    function initialize(bytes calldata data) external;

    /**
     * @notice BlockNumber를 기준으로, target의 정량적인 투표권을 가져옵니다.
     * @param target 대상이 되는 주소
     * @param blockNumber 기반이 되는 블록 숫자
     * @return power 투표 권한
     */
    function getPriorPower(address target, uint256 blockNumber) external view returns (uint256 power);

    /**
     * @notice BlockNumber를 기준으로, target의 투표권을 비율화 하여 가져옵니다.
     * @param target 대상이 되는 주소
     * @param blockNumber 기반이 되는 블록 숫자
     * @return rate 비율
     */
    function getPriorRate(address target, uint256 blockNumber) external view returns (uint256 rate);

    /**
     * @notice BlockNumber를 기준으로, 특정 수치의 투표권을 총 투표권의 비율로 계산하는 함수
     * @param power 계산하고자 하는 투표권한
     * @param blockNumber 기반이 되는 블록 숫자
     */
    function getPowerToRate(uint256 power, uint256 blockNumber) external view returns (uint256 rate);
}

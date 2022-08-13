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
     * @notice 입력된 블록을 기준하여 주소의 정량적인 투표권을 가져옵니다
     * @param account 대상이 되는 주소
     * @param blockNumber 기반이 되는 블록 숫자
     * @return votes 투표 권한
     */
    function getPriorVotes(address account, uint256 blockNumber) external view returns (uint256 votes);

    /**
     * @notice 입력된 블록을 기준하여, 주소의 정량적인 투표권을 비율화하여 가져옵니다.
     * @param account 대상이 되는 주소
     * @param blockNumber 기반이 되는 블록 숫자
     * @return rate 비율
     */
    function getPriorRate(address account, uint256 blockNumber) external view returns (uint256 rate);

    /**
     * @notice 입력된 블록을 기준하여, 특정 수치의 투표권을 총 투표권의 비율로 계산하는 함수
     * @param votes 계산하고자 하는 투표권한
     * @param blockNumber 기반이 되는 블록 숫자
     * @return rate 비율
     */
    function getVotesToRate(uint256 votes, uint256 blockNumber) external view returns (uint256 rate);

    /**
     * @notice 입력된 블록을 기준하여, 총 투표권을 반환합니다.
     * @param blockNumber 기반이 되는 블록 숫자
     * @return totalVotes 총 투표권
     */
    function getPriorTotalSupply(uint256 blockNumber) external view returns (uint256 totalVotes);
}

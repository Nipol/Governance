/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

interface IModule {
    function stake(uint256 amount) external payable returns (bool success);

    function unstake(uint256 amount) external returns (bool success);

    function delegate(address delegatee) external returns (bool success);

    function delegateWithSig(
        address delegate,
        bytes32 r,
        bytes32 s,
        uint8 v
    ) external returns (bool success);

    function getPriorVote(address target, uint256 epoch) external returns (uint256 vote);
}

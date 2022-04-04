/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

import "@beandao/contracts/library/MinimalProxy.sol";

contract Deployer {
    address tmp;

    constructor(address template) {
        tmp = template;
    }

    function calculate() external view returns (address addr) {
        (, addr) = MinimalProxy.seedSearch(tmp);
    }

    function deployIncrement() external returns (address addr) {
        (bytes32 seed, ) = MinimalProxy.seedSearch(tmp);
        addr = MinimalProxy.deploy(tmp, seed);
    }
}

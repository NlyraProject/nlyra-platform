// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "../ForkBase.sol";
// PoC TOK-OPS-1: infra only. setUp (ForkBase) forks robin@74180000; with the emptied cache it 403s.
contract V_TOK_OPS_1 is ForkBase {
    function test_forkSetUpWorks() public view { assertTrue(address(st).code.length > 0); }
}

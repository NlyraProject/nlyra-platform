// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {RealYieldStaking} from "../../src/RealYieldStaking.sol";
import {NlyraFeeSplitter} from "../../src/NlyraFeeSplitter.sol";
import {IPonsLaunchLocker} from "../../src/interfaces/External.sol";
import {ForkPin} from "../ForkBase.sol";

interface ILockerX { function factory() external view returns (address); function owner() external view returns (address); }
interface IFactoryX { function getLaunchedToken(address) external view; }

contract VDosGasHarvestBrickedForeignPonsRevert is Test {
    IERC20 constant NLYRA = IERC20(0xB9d3824149aD8ac984153CeEc91D5a2405d1FB95);
    IERC20 constant WETH = IERC20(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73);
    IERC20 constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    address constant POOL_NLYRA = 0x483C24d1e36Df01b650F1E9BEEB2a1c31C005C39;
    address constant POOL_USDG = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    IPonsLaunchLocker constant LOCKER = IPonsLaunchLocker(0x736D76699C26D0d966744cAe304C000d471f7F35);
    address constant TREASURY = 0xe30647793192D15BFA6E53aE8651368d332fe04C;
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    RealYieldStaking st;
    NlyraFeeSplitter sp;
    address factory;

    function setUp() public {
        vm.createSelectFork("robin", vm.envOr("FORK_BLOCK", ForkPin.BLOCK));
        st = new RealYieldStaking(
            makeAddr("owner"), address(NLYRA), address(WETH), address(USDG), POOL_NLYRA, POOL_USDG,
            address(LOCKER), TREASURY, 5_000, 1 days
        );
        sp = NlyraFeeSplitter(payable(st.feeSplitter()));
        vm.prank(TREASURY);
        LOCKER.setFeeRedirect(address(NLYRA), address(sp));
        factory = ILockerX(address(LOCKER)).factory();
    }

    /// Reachability probe: are locker/factory proxies? who owns them?
    function test_probe_ponsMutability() public {
        emit log_named_address("factory", factory);
        emit log_named_uint("factory codesize", factory.code.length);
        emit log_named_uint("locker codesize", address(LOCKER).code.length);
        emit log_named_uint("factory has upgradeToAndCall sel", _has(factory.code, 0x4f1ef286) ? 1 : 0);
        emit log_named_uint("factory has paused() sel", _has(factory.code, 0x5c975abb) ? 1 : 0);
        emit log_named_uint("locker has upgradeToAndCall sel", _has(address(LOCKER).code, 0x4f1ef286) ? 1 : 0);
        // baseline: real Pons, harvest works
        deal(address(WETH), address(sp), 1 ether);
        sp.harvest();
        assertEq(WETH.balanceOf(address(sp)), 0);
    }

    function _has(bytes memory c, uint32 sel) internal pure returns (bool) {
        for (uint256 i; i + 4 <= c.length; ++i) {
            if (uint32(uint8(c[i])) << 24 | uint32(uint8(c[i+1])) << 16 | uint32(uint8(c[i+2])) << 8 | uint32(uint8(c[i+3])) == sel) return true;
        }
        return false;
    }

    /// Foreign revert (custom error from the position manager's collect) is re-thrown -> harvest bricked
    /// for as long as the external condition lasts; donations stuck; stream not renewed.
    function test_poc_foreignRevert_bricksHarvest() public {
        deal(address(WETH), address(sp), 1 ether);
        deal(address(NLYRA), address(sp), 1000e18);
        vm.mockCallRevert(
            address(LOCKER), abi.encodeWithSelector(IPonsLaunchLocker.collectFees.selector, address(NLYRA)),
            abi.encodeWithSignature("SomethingElse()")
        );
        for (uint256 i; i < 5; ++i) {
            vm.expectRevert(abi.encodeWithSignature("SomethingElse()"));
            sp.harvest();
            vm.warp(vm.getBlockTimestamp() + 1 days);
        }
        assertEq(sp.lastHarvest(), 0);
        assertEq(WETH.balanceOf(address(sp)), 1 ether);
        vm.expectRevert(NlyraFeeSplitter.NotSweepable.selector);
        sp.sweep(address(WETH));
        vm.expectRevert(RealYieldStaking.OnlySplitter.selector);
        st.notifyRewards(0, 0);
        // treasury escape (redirect away) does not free the already-held balance
        vm.prank(TREASURY);
        LOCKER.setFeeRedirect(address(NLYRA), TREASURY);
        vm.expectRevert(abi.encodeWithSignature("SomethingElse()"));
        sp.harvest();
        // recovers only when the external condition clears
        vm.clearMockedCalls();
        sp.harvest();
        assertEq(WETH.balanceOf(address(sp)), 0);
    }

    /// Empty-data revert (e.g. a factory call that reverts without reason) is also re-thrown.
    function test_poc_emptyRevertFromFactory_bricksHarvestAndEscape() public {
        deal(address(WETH), address(sp), 1 ether);
        vm.mockCallRevert(factory, abi.encodeWithSelector(IFactoryX.getLaunchedToken.selector), "");
        vm.expectRevert();
        sp.harvest();
        vm.prank(TREASURY);
        vm.expectRevert();
        LOCKER.setFeeRedirect(address(NLYRA), TREASURY);
        assertEq(WETH.balanceOf(address(sp)), 1 ether);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {RealYieldStaking} from "../../src/RealYieldStaking.sol";
import {NlyraFeeSplitter} from "../../src/NlyraFeeSplitter.sol";
import {IPonsLaunchLocker} from "../../src/interfaces/External.sol";
import {ForkPin} from "../ForkBase.sol";

interface ILockerFactoryV { function factory() external view returns (address); function owner() external view returns (address); }
interface IFactoryGLTV { function getLaunchedToken(address) external view; }

contract VSplitterHarvestLivenessCoupledToPons is Test {
    IERC20 constant NLYRA = IERC20(0xB9d3824149aD8ac984153CeEc91D5a2405d1FB95);
    IERC20 constant WETH = IERC20(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73);
    IERC20 constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    address constant POOL_NLYRA = 0x483C24d1e36Df01b650F1E9BEEB2a1c31C005C39;
    address constant POOL_USDG = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    IPonsLaunchLocker constant LOCKER = IPonsLaunchLocker(0x736D76699C26D0d966744cAe304C000d471f7F35);
    address constant TREASURY = 0xe30647793192D15BFA6E53aE8651368d332fe04C;
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

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
        factory = ILockerFactoryV(address(LOCKER)).factory();
    }

    /// Which Pons contracts can actually change behaviour? (proxy slots / code size)
    function test_v_ponsUpgradeability() public {
        emit log_named_address("factory", factory);
        emit log_named_uint("factory code size", factory.code.length);
        bytes memory fc = factory.code;
        emit log_named_uint("factory has paused() selector", _has(fc, 0x5c975abb) ? 1 : 0);
        emit log_named_uint("factory has upgradeToAndCall selector", _has(fc, 0x4f1ef286) ? 1 : 0);
        emit log_named_uint("factory has DELEGATECALL byte", _hasByte(fc, 0xf4) ? 1 : 0);
        emit log_named_uint("locker code size", address(LOCKER).code.length);
        emit log_named_uint("locker has upgradeToAndCall selector", _has(address(LOCKER).code, 0x4f1ef286) ? 1 : 0);
        // baseline: harvest works today against real Pons
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
    function _hasByte(bytes memory c, uint8 b) internal pure returns (bool) {
        for (uint256 i; i < c.length; ++i) if (uint8(c[i]) == b) return true;
        return false;
    }

    /// Hypothetical: Pons factory getLaunchedToken reverts (no data). Harvest bricked, escape hatch dead,
    /// donations stuck, notify unreachable. Only recovers when Pons recovers.
    function test_v_harvestBricked_ifFactoryReverts() public {
        deal(address(WETH), address(sp), 1 ether);
        (bool ok,) = address(sp).call{value: 1 ether}("");
        assertTrue(ok);
        deal(address(NLYRA), address(sp), 1000e18);

        vm.mockCallRevert(factory, abi.encodeWithSelector(IFactoryGLTV.getLaunchedToken.selector), "");

        vm.expectRevert();
        sp.harvest();

        vm.prank(TREASURY);
        vm.expectRevert();
        LOCKER.setFeeRedirect(address(NLYRA), TREASURY);

        for (uint256 i; i < 3; ++i) {
            vm.warp(vm.getBlockTimestamp() + 2 days);
            vm.expectRevert();
            sp.harvest();
        }
        assertEq(sp.lastHarvest(), 0);

        vm.expectRevert(NlyraFeeSplitter.NotSweepable.selector);
        sp.sweep(address(WETH));
        vm.expectRevert(NlyraFeeSplitter.NotSweepable.selector);
        sp.sweep(address(NLYRA));

        deal(address(WETH), address(st), 5 ether);
        vm.expectRevert(RealYieldStaking.OnlySplitter.selector);
        st.notifyRewards(0, 0);
        // ronda 2 (C): las fees que llegan DIRECTO al staking ya no dependen del splitter ni de Pons
        st.sweepDonations();
        assertEq(st.tranches().length, 1, "tramo abierto sin el splitter");
        assertGe(uint256(st.tranches()[0].rateWeth) * 7 days, 5 ether - 7 days);

        vm.clearMockedCalls();
        sp.harvest();
        assertEq(WETH.balanceOf(address(sp)), 0);
        assertEq(address(sp).balance, 0);
    }

    /// TokenNotFound from locker is not in the allowlist.
    function test_v_harvestBricked_byTokenNotFound() public {
        deal(address(WETH), address(sp), 1 ether);
        vm.mockCallRevert(
            address(LOCKER), abi.encodeWithSelector(IPonsLaunchLocker.collectFees.selector, address(NLYRA)),
            abi.encodeWithSignature("TokenNotFound()")
        );
        vm.expectRevert(abi.encodeWithSignature("TokenNotFound()"));
        sp.harvest();
    }
}

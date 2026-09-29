// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {RealYieldStaking} from "../../src/RealYieldStaking.sol";
import {ForkPin} from "../ForkBase.sol";

interface IPoolMetaV {
    function factory() external view returns (address);
    function fee() external view returns (uint24);
    function token0() external view returns (address);
    function token1() external view returns (address);
}


interface ICbV {
    function uniswapV3SwapCallback(int256, int256, bytes calldata) external;
}

/// look-alike: correct token0/token1 (constants, so it can be vm.etch'ed onto an already-cached fork account:
/// the development RPC could not serve uncached accounts at the pinned block), asks for the WHOLE tokenIn
/// balance of the caller in the callback, then lies in its return deltas to pass the PartialFill check.
contract LookAlikePoolV {
    address public constant token0 = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73; // WETH
    address public constant token1 = 0xB9d3824149aD8ac984153CeEc91D5a2405d1FB95; // NLYRA

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata)
        external
        returns (int256, int256)
    {
        address tin = zeroForOne ? token0 : token1;
        int256 bal = int256(IERC20(tin).balanceOf(recipient));
        if (zeroForOne) ICbV(msg.sender).uniswapV3SwapCallback(bal, 0, "");
        else ICbV(msg.sender).uniswapV3SwapCallback(0, bal, "");
        return zeroForOne ? (amountSpecified, int256(0)) : (int256(0), amountSpecified);
    }
}

/// look-alike que ademas imita factory() y fee(): igual no pasa, porque su direccion no sale de CREATE2.
contract LookAlikeSpoofV is LookAlikePoolV {
    address public constant factory = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    uint24 public constant fee = 10000;
}

/// REGRESION hallazgo 6 (antes: el constructor aceptaba un look-alike con el par correcto y el primer
/// claim(ALL_ETH) le entregaba 1.011.000 NLYRA, todo el principal). Ahora el constructor exige que el pool
/// sea el de CREATE2(factory, token0, token1, fee) con el init code canonico, y el callback paga solo al
/// pool en curso, solo el token de entrada y solo el monto exacto pedido.
contract VSwapMevMisdeployPoolCallbackTrust is Test {
    IERC20 constant NLYRA = IERC20(0xB9d3824149aD8ac984153CeEc91D5a2405d1FB95);
    IERC20 constant WETH = IERC20(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73);
    IERC20 constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    address constant POOL_NLYRA = 0x483C24d1e36Df01b650F1E9BEEB2a1c31C005C39;
    address constant POOL_USDG = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    address constant LOCKER = 0x736D76699C26D0d966744cAe304C000d471f7F35;
    address constant TREASURY = 0xe30647793192D15BFA6E53aE8651368d332fe04C;

    function setUp() public {
        vm.createSelectFork("robin", vm.envOr("FORK_BLOCK", ForkPin.BLOCK));
    }

    function _deployAndFund(address poolNlyra) internal returns (RealYieldStaking st, address alice, address bob) {
        st = new RealYieldStaking(
            makeAddr("owner"), address(NLYRA), address(WETH), address(USDG), poolNlyra, POOL_USDG, LOCKER, TREASURY,
            5_000, 1 days
        );
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        deal(address(NLYRA), bob, 1_000_000e18);
        vm.startPrank(bob);
        NLYRA.approve(address(st), type(uint256).max);
        st.stakeLocked(1_000_000e18, 2);
        vm.stopPrank();
        deal(address(NLYRA), alice, 1_000e18);
        vm.startPrank(alice);
        NLYRA.approve(address(st), type(uint256).max);
        st.stake(1_000e18);
        vm.stopPrank();
        deal(address(NLYRA), address(st), NLYRA.balanceOf(address(st)) + 10_000e18);
        vm.prank(st.feeSplitter());
        st.notifyRewards(0, 0);
        vm.warp(vm.getBlockTimestamp() + 7 days);
    }

    /// A: el constructor rechaza el look-alike (con y sin factory()/fee() falsos)
    function test_A_lookAlikeRejectedAtDeploy() public {
        address evil = makeAddr("dave"); // cuenta cacheada del fork
        vm.etch(evil, type(LookAlikePoolV).runtimeCode);
        vm.expectRevert(); // ni siquiera tiene factory()
        new RealYieldStaking(
            makeAddr("owner"), address(NLYRA), address(WETH), address(USDG), evil, POOL_USDG, LOCKER, TREASURY,
            5_000, 1 days
        );
        vm.etch(evil, type(LookAlikeSpoofV).runtimeCode);
        assertEq(IPoolMetaV(evil).factory(), IPoolMetaV(POOL_NLYRA).factory());
        vm.expectRevert(RealYieldStaking.BadPool.selector);
        new RealYieldStaking(
            makeAddr("owner"), address(NLYRA), address(WETH), address(USDG), evil, POOL_USDG, LOCKER, TREASURY,
            5_000, 1 days
        );
    }

    /// B: los pools reales son canonicos y cobran exacto amountIn
    function test_B_realPoolsCanonicalExact() public {
        assertEq(IPoolMetaV(POOL_NLYRA).factory(), 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA);
        assertEq(IPoolMetaV(POOL_USDG).factory(), 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA);
        assertEq(IPoolMetaV(POOL_NLYRA).fee(), 10000);
        assertEq(IPoolMetaV(POOL_USDG).fee(), 100);
        (RealYieldStaking st, address alice,) = _deployAndFund(POOL_NLYRA);
        uint256 before = NLYRA.balanceOf(address(st));
        (, uint256 en) = st.earned(alice);
        vm.prank(alice);
        st.claim(RealYieldStaking.OutMode.ALL_ETH, 0);
        assertEq(before - NLYRA.balanceOf(address(st)), en, "real pool pulled != amountIn");
    }

    /// C: defensa en profundidad: aunque el codigo del pool cambiara (vm.etch sobre el pool real) y pidiera
    ///    mas de lo debido, el callback revierte y el principal queda intacto.
    function test_C_callbackPaysOnlyExactAmount() public {
        (RealYieldStaking st, address alice,) = _deployAndFund(POOL_NLYRA);
        vm.etch(POOL_NLYRA, type(LookAlikePoolV).runtimeCode);
        uint256 before = NLYRA.balanceOf(address(st));
        vm.prank(alice);
        vm.expectRevert(RealYieldStaking.BadCallback.selector);
        st.claim(RealYieldStaking.OutMode.ALL_ETH, 0);
        assertEq(NLYRA.balanceOf(address(st)), before, "principal intacto");
    }
}

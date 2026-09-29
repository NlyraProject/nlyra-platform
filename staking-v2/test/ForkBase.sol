// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {RealYieldStaking} from "../src/RealYieldStaking.sol";
import {NlyraFeeSplitter} from "../src/NlyraFeeSplitter.sol";
import {IPonsLaunchLocker, IUniswapV3PoolLike} from "../src/interfaces/External.sol";

/// The single pinned block used by EVERY fork test. Override it with the FORK_BLOCK env var.
/// Forking this exact block needs an archive RPC (or a warm foundry cache in
/// ~/.foundry/cache/rpc/4663/<block>). With a non-archive RPC, fork a recent block instead:
///   RH_RPC=https://rpc.mainnet.chain.robinhood.com FORK_BLOCK=$(cast block-number --rpc-url $RH_RPC) ///   FOUNDRY_PROFILE=dev forge test
/// To re-pin: pick a recent block, run the suite once with FORK_BLOCK=<block> (dev and default profiles,
/// one forge process at a time), and only then change the constant.
library ForkPin {
    uint256 internal constant BLOCK = 74_478_703; // Sep 28, 2026 ~03:35 UTC
}

/// Shared base (no tests) for the main suite and the audit regressions.
/// Forks Robinhood Chain (4663) at the pinned block ForkPin.BLOCK (or FORK_BLOCK from the environment)
/// through the `robin` RPC endpoint (RH_RPC, see foundry.toml). All accounts are fresh makeAddr() accounts
/// (alice, bob, carol, dave, owner, botEscrow, and the test's own deploys).
abstract contract ForkBase is Test {

    IERC20 constant NLYRA = IERC20(0xB9d3824149aD8ac984153CeEc91D5a2405d1FB95);
    IERC20 constant WETH = IERC20(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73);
    IERC20 constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    address constant POOL_NLYRA = 0x483C24d1e36Df01b650F1E9BEEB2a1c31C005C39; // WETH/NLYRA 1%
    address constant POOL_USDG = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca; // WETH/USDG 0.01%
    IPonsLaunchLocker constant LOCKER = IPonsLaunchLocker(0x736D76699C26D0d966744cAe304C000d471f7F35);
    address constant TREASURY = 0xe30647793192D15BFA6E53aE8651368d332fe04C;

    RealYieldStaking st;
    NlyraFeeSplitter sp;
    address owner;
    address alice;
    address bob;
    address carol;
    address dave;

    function setUp() public virtual {
        vm.createSelectFork("robin", _forkBlock());
        owner = _fresh("owner");
        alice = _fresh("alice");
        bob = _fresh("bob");
        carol = _fresh("carol");
        dave = _fresh("dave");
        st = new RealYieldStaking(
            owner, address(NLYRA), address(WETH), address(USDG), POOL_NLYRA, POOL_USDG, address(LOCKER), TREASURY,
            5_000, 1 days
        );
        sp = NlyraFeeSplitter(payable(st.feeSplitter()));
        vm.prank(TREASURY);
        LOCKER.setFeeRedirect(address(NLYRA), address(sp));
        assertEq(LOCKER.feeRedirects(address(NLYRA)), address(sp));
    }

    // ------------------------------------------------------------------ helpers

    function _forkBlock() internal view returns (uint256) {
        return vm.envOr("FORK_BLOCK", ForkPin.BLOCK);
    }

    /// deploy igual al del setUp (para los tests que rearman el staking)
    function _deployStaking() internal {
        st = new RealYieldStaking(
            owner, address(NLYRA), address(WETH), address(USDG), POOL_NLYRA, POOL_USDG, address(LOCKER), TREASURY,
            5_000, 1 days
        );
        sp = NlyraFeeSplitter(payable(st.feeSplitter()));
    }

    /// premio de fees "del splitter": `amt` NLYRA directo al splitter + harvest (a stakers va la mitad y
    /// cuenta para el bonus). Requiere que el intervalo del splitter ya haya pasado.
    function _splitterNlyra(uint256 amt) internal {
        _giveNlyra(address(sp), amt);
        sp.harvest();
    }

    /// donacion directa al staking + sweepDonations (NO cuenta para el bonus)
    function _donateNlyra(uint256 amt) internal {
        _giveNlyra(address(st), amt);
        st.sweepDonations();
    }

    function _fresh(string memory label) internal returns (address a) {
        a = makeAddr(label);
        assertEq(a.code.length, 0, "cuenta de test con codigo");
    }

    function _giveNlyra(address to, uint256 amt) internal {
        deal(address(NLYRA), to, NLYRA.balanceOf(to) + amt);
    }

    function _stake(address u, uint256 amt, uint8 tier) internal {
        _giveNlyra(u, amt);
        vm.startPrank(u);
        NLYRA.approve(address(st), amt);
        if (tier == 0) st.stake(amt);
        else st.stakeLocked(amt, tier);
        vm.stopPrank();
    }

    function _fund(address from, uint256 amt) internal {
        _giveNlyra(from, amt);
        vm.startPrank(from);
        NLYRA.approve(address(st), amt);
        st.fundBonusReserve(amt);
        vm.stopPrank();
    }

    /// genera fees en el pool real: compra y venta de `wethAmt` ida y vuelta
    function _trade(uint256 wethAmt, uint256 rounds) internal {
        deal(address(WETH), address(this), WETH.balanceOf(address(this)) + wethAmt);
        for (uint256 i; i < rounds; ++i) {
            (, int256 a1) = IUniswapV3PoolLike(POOL_NLYRA).swap(address(this), true, int256(wethAmt), 4295128740, "");
            uint256 got = uint256(-a1);
            (int256 b0,) = IUniswapV3PoolLike(POOL_NLYRA).swap(
                address(this), false, int256(got), 1461446703485210103287273052203988822378723970341, ""
            );
            wethAmt = uint256(-b0);
        }
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external virtual {
        require(msg.sender == POOL_NLYRA || msg.sender == POOL_USDG, "pool");
        if (a0 > 0) IERC20(IUniswapV3PoolLike(msg.sender).token0()).transfer(msg.sender, uint256(a0));
        if (a1 > 0) IERC20(IUniswapV3PoolLike(msg.sender).token1()).transfer(msg.sender, uint256(a1));
    }

    /// Each swap at a new timestamp writes the next oracle observation (slot 8 + index). On a
    /// cache-only fork, observations from index 82 on were not available, so long swap sequences reset
    /// slot0's observationIndex to 79. This only touches the pool's TWAP, which nothing here uses;
    /// price, tick and liquidity are unchanged.
    function _resetOracle() internal {
        bytes32 s0 = vm.load(POOL_NLYRA, bytes32(0));
        uint256 v = uint256(s0) & ~(uint256(0xffff) << 184);
        vm.store(POOL_NLYRA, bytes32(0), bytes32(v | (uint256(79) << 184)));
    }

    /// saldo de premios del staking (WETH, NLYRA libre de principal)
    function _rewardBal() internal view returns (uint256 w, uint256 n) {
        (,,,, uint256 ts, uint256 tc, uint256 br) = st.rewardInfo();
        w = WETH.balanceOf(address(st));
        n = NLYRA.balanceOf(address(st)) - ts - tc - br;
    }

    /// harvest real: trade -> fees -> harvest. Devuelve lo que entro al staking.
    function _tradeAndHarvest() internal returns (uint256 w, uint256 n) {
        _trade(2 ether, 3);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        (uint256 w0, uint256 n0) = _rewardBal();
        sp.harvest();
        (uint256 w1, uint256 n1) = _rewardBal();
        return (w1 - w0, n1 - n0);
    }

    function _users() internal view returns (address[] memory u) {
        u = new address[](4);
        u[0] = alice;
        u[1] = bob;
        u[2] = carol;
        u[3] = dave;
    }

    /// Lo que los tramos activos todavia tienen que emitir desde ahora (calculado desde la vista cruda).
    function _pendingNow() internal view returns (uint256 w, uint256 n) {
        RealYieldStaking.Tranche[] memory trs = st.tranches();
        for (uint256 k; k < trs.length; ++k) {
            if (trs[k].end > block.timestamp) {
                w += uint256(trs[k].rateWeth) * (trs[k].end - block.timestamp);
                n += uint256(trs[k].rateNlyra) * (trs[k].end - block.timestamp);
            }
        }
    }

    /// INVARIANTES DE SOLVENCIA:
    ///  WETH.balance  >= deuda devengada + tramos pendientes
    ///  NLYRA.balance >= totalStaked + totalCooling + bonusReserve + deuda devengada + tramos pendientes
    ///  y lo que los usuarios pueden cobrar no supera la deuda devengada.
    function _checkSolvency(address[] memory users) internal view {
        _checkSolvency(users, false);
    }

    /// `exact`: `users` son TODOS los stakers, asi que ademas cuadra el principal y el peso total.
    function _checkSolvency(address[] memory users, bool exact) internal view {
        (uint256 cw, uint256 cn) = st.committedRewards();
        (,,, uint256 tb, uint256 ts, uint256 tc, uint256 br) = st.rewardInfo();
        assertGe(WETH.balanceOf(address(st)), cw, "WETH insolvente");
        assertGe(NLYRA.balanceOf(address(st)), ts + tc + br + cn, "NLYRA insolvente");
        (uint256 pw, uint256 pn) = _pendingNow();
        assertLe(pw, cw, "pendiente WETH > comprometido");
        assertLe(pn, cn, "pendiente NLYRA > comprometido");
        uint256[5] memory sum = _sums(users); // earnedW, earnedN, principal, cooling, peso
        assertLe(sum[0], cw - pw, "WETH: usuarios > devengado");
        assertLe(sum[1], cn - pn, "NLYRA: usuarios > devengado");
        if (exact) {
            assertEq(sum[2], ts, "principal != totalStaked");
            assertEq(sum[3], tc, "cooling != totalCooling");
            assertEq(sum[4], tb, "peso != totalBoosted");
        }
    }

    function _sums(address[] memory users) internal view returns (uint256[5] memory sum) {
        for (uint256 k; k < users.length; ++k) {
            (RealYieldStaking.Account memory ac, uint256 ew, uint256 en,) = st.userInfo(users[k]);
            sum[0] += ew;
            sum[1] += en;
            sum[2] += uint256(ac.flexible) + ac.locked;
            sum[3] += ac.cooling;
            sum[4] += st.boostedBalanceOf(users[k]);
        }
    }
}

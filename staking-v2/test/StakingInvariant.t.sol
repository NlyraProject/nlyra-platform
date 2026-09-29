// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {RealYieldStaking} from "../src/RealYieldStaking.sol";
import {NlyraFeeSplitter} from "../src/NlyraFeeSplitter.sol";
import {ForkBase} from "./ForkBase.sol";

/// Handler del test de invariantes: 4 stakers (cuentas cacheadas en el fork) hacen de todo, con el
/// tiempo avanzando al azar. Nunca revierte (cada accion se salta si no aplica).
contract StakingHandler is Test {
    RealYieldStaking immutable st;
    NlyraFeeSplitter immutable sp;
    IERC20 immutable NLYRA;
    IERC20 immutable WETH;
    address immutable POOL;
    address[4] users;
    mapping(string => uint256) public calls;

    constructor(RealYieldStaking st_, address[4] memory us, address pool) {
        st = st_;
        sp = NlyraFeeSplitter(payable(st_.feeSplitter()));
        NLYRA = st_.NLYRA();
        WETH = st_.WETH();
        POOL = pool;
        users = us;
    }

    function _u(uint256 i) internal view returns (address) {
        return users[i % 4];
    }

    /// ver ForkBase._resetOracle
    function _resetOracle() internal {
        bytes32 s0 = vm.load(POOL, bytes32(0));
        uint256 v = uint256(s0) & ~(uint256(0xffff) << 184);
        vm.store(POOL, bytes32(0), bytes32(v | (uint256(79) << 184)));
    }

    modifier step(uint256 dt) {
        _;
        _resetOracle();
        vm.warp(vm.getBlockTimestamp() + bound(dt, 0, 12 days));
    }

    function stake(uint256 i, uint256 amt, uint8 tier, uint256 dt) external step(dt) {
        address u = _u(i);
        amt = bound(amt, 1, 5_000_000e18);
        tier = uint8(bound(tier, 0, 3));
        (,,, uint256 pc) = st.userInfo(u);
        if (tier != 0 && pc == 32) return;
        deal(address(NLYRA), u, NLYRA.balanceOf(u) + amt);
        vm.startPrank(u);
        NLYRA.approve(address(st), amt);
        if (tier == 0) st.stake(amt);
        else st.stakeLocked(amt, tier);
        vm.stopPrank();
        calls["stake"]++;
    }

    function requestUnstake(uint256 i, uint256 amt, uint256 dt) external step(dt) {
        address u = _u(i);
        (RealYieldStaking.Account memory ac,,,) = st.userInfo(u);
        if (ac.flexible == 0) return;
        vm.prank(u);
        st.requestUnstake(bound(amt, 1, ac.flexible));
        calls["requestUnstake"]++;
    }

    function withdrawOrCancel(uint256 i, bool cancel, uint256 dt) external step(dt) {
        address u = _u(i);
        (RealYieldStaking.Account memory ac,,,) = st.userInfo(u);
        if (ac.cooling == 0) return;
        vm.prank(u);
        if (cancel) {
            st.cancelUnstake();
            calls["cancel"]++;
        } else if (block.timestamp >= ac.cooldownEnd) {
            st.withdraw();
            calls["withdraw"]++;
        }
    }

    function claim(uint256 i, uint8 mode, uint256 dt) external step(dt) {
        address u = _u(i);
        (uint256 ew, uint256 en) = st.earned(u);
        if (ew + en == 0) return;
        mode = uint8(bound(mode, 0, 2)); // USDG no: el pool USDG del fork no tiene sus slots de oracle en cache
        // modos con swap solo con montos chicos (el pool del fork tiene liquidez limitada)
        if (mode != 0 && (ew > 0.05 ether || en > 20_000_000e18)) mode = 0;
        vm.prank(u);
        st.claim(RealYieldStaking.OutMode(mode), 0);
        calls["claim"]++;
    }

    /// compound a flex, a un lock nuevo o dentro de un lock abierto (si las reglas de extend lo permiten)
    function compound(uint256 i, uint8 tier, uint256 k, uint256 dt) external step(dt) {
        address u = _u(i);
        (uint256 ew, uint256 en) = st.earned(u);
        (,,, uint256 pc) = st.userInfo(u);
        tier = uint8(bound(tier, 0, 3));
        if (ew + en == 0 || ew > 0.05 ether) return;
        uint256 pid = type(uint256).max;
        RealYieldStaking.Position[] memory ps = st.positionsOf(u);
        if (tier != 0 && k % 2 == 0 && ps.length != 0) {
            uint256 j = k % ps.length;
            RealYieldStaking.Position memory p = ps[j];
            if (p.amount != 0 && (block.timestamp >= p.unlockTime || tier >= p.tier)) pid = j;
        }
        if (tier != 0 && pid == type(uint256).max && pc == 32) return;
        vm.prank(u);
        st.compound(0, tier, pid);
        calls[pid == type(uint256).max ? "compound" : "compoundInto"]++;
    }

    function harvest(uint256 w, uint256 n, uint256 dt) external step(dt) {
        if (sp.harvestableIn() != 0) return;
        deal(address(WETH), address(sp), WETH.balanceOf(address(sp)) + bound(w, 0, 2 ether));
        deal(address(NLYRA), address(sp), NLYRA.balanceOf(address(sp)) + bound(n, 0, 3_000_000e18));
        if (WETH.balanceOf(address(sp)) + NLYRA.balanceOf(address(sp)) == 0) return;
        sp.harvest();
        calls["harvest"]++;
    }

    function donateToStaking(uint256 w, uint256 n, uint256 dt) external step(dt) {
        deal(address(WETH), address(st), WETH.balanceOf(address(st)) + bound(w, 0, 0.5 ether));
        deal(address(NLYRA), address(st), NLYRA.balanceOf(address(st)) + bound(n, 0, 2_000_000e18));
        calls["donate"]++;
        if (block.timestamp >= uint256(st.lastDonationSweep()) + 1 days) {
            st.sweepDonations();
            calls["sweepDonations"]++;
        }
    }

    function fundReserve(uint256 n, uint256 dt) external step(dt) {
        n = bound(n, 1, 2_000_000e18);
        address d = users[3];
        deal(address(NLYRA), d, NLYRA.balanceOf(d) + n);
        vm.startPrank(d);
        NLYRA.approve(address(st), n);
        st.fundBonusReserve(n);
        vm.stopPrank();
        calls["fundReserve"]++;
    }

    function lockAction(uint256 i, uint256 k, uint8 action, uint8 tier, uint256 dt) external step(dt) {
        address u = _u(i);
        RealYieldStaking.Position[] memory ps = st.positionsOf(u);
        if (ps.length == 0) return;
        k = bound(k, 0, ps.length - 1);
        RealYieldStaking.Position memory p = ps[k];
        if (p.amount == 0) return;
        bool expired = block.timestamp >= p.unlockTime;
        tier = uint8(bound(tier, 1, 3));
        action = uint8(bound(action, 0, 2));
        if (action == 0 && expired) {
            vm.prank(u);
            st.withdrawLocked(k);
            calls["withdrawLocked"]++;
        } else if (action == 1 && (expired || tier >= p.tier)) {
            vm.prank(u);
            st.extendLock(k, tier);
            calls["extendLock"]++;
        } else if (action == 2 && expired && p.tier != 0) {
            st.kick(u, k);
            calls["kick"]++;
        }
    }
}

/// Invariantes de solvencia (con el handler de arriba):
///  - WETH.balance  >= devengado sin cobrar + lo que falta emitir de los tramos
///  - NLYRA.balance >= totalStaked + totalCooling + bonusReserve + devengado + pendiente
///  - lo cobrable por los usuarios <= devengado; principal, cooling y peso cuadran exacto con los usuarios
///  - la suma de las bajas de boost agendadas a futuro = peso extra vigente (totalBoosted - totalStaked)
/// forge-config: default.invariant.runs = 48
/// forge-config: default.invariant.depth = 60
/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: dev.invariant.runs = 48
/// forge-config: dev.invariant.depth = 60
/// forge-config: dev.invariant.fail-on-revert = true
contract StakingInvariantTest is ForkBase {
    StakingHandler h;

    function setUp() public override {
        super.setUp();
        h = new StakingHandler(st, [alice, bob, carol, dave], POOL_NLYRA);
        // primer harvest con los fees reales pendientes + una donacion
        deal(address(WETH), address(sp), 1 ether);
        sp.harvest();
        targetContract(address(h));
        targetSender(alice);
    }

    function invariant_solvent() public view {
        _checkSolvency(_users(), true);
    }

    function invariant_rewardAccounting() public view {
        for (uint256 i; i < 2; ++i) {
            RealYieldStaking.RewardState memory r = st.rewardState(i);
            assertLe(r.paid, r.distributed, "pagado > asignado");
        }
        assertLe(st.tranches().length, 14, "splitter <= 7 + sweepDonations <= 7");
    }

    function invariant_boostDropsMatchExtraWeight() public view {
        (,,, uint256 tb, uint256 ts,,) = st.rewardInfo();
        uint256 m = (block.timestamp / 1 days + 1) * 1 days;
        uint256 sum;
        for (uint256 d; d <= 31; ++d) sum += st.boostDrop(m + d * 1 days);
        assertEq(sum, tb - ts, "boostDrop futuros != peso extra vigente");
    }

    function afterInvariant() external view {
        string[14] memory k = [
            "stake", "requestUnstake", "cancel", "withdraw", "claim", "compound", "compoundInto", "harvest",
            "donate", "sweepDonations", "fundReserve", "withdrawLocked", "extendLock", "kick"
        ];
        for (uint256 i; i < 14; ++i) {
            console2.log(k[i], h.calls(k[i]));
        }
    }
}

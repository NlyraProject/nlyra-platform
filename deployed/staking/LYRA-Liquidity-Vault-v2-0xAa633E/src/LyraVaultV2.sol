// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ============================================================
// INVEST WITH LYRA — the liquidity vault (Robinhood Chain)
// by NERON & LYRA · nlyra.xyz
//
// "You bring the ETH. I bring the judgement. The code brings the walls."
//
// Users deposit ETH and receive shares. LYRA (the keeper) deploys the
// pot as concentrated Uniswap-V3-style liquidity across the NLYRA
// ecosystem: launchpad pools with real volume (the yield) and the
// Architect Swap NLYRA pair (the mission — seeding our own DEX).
//
// The walls, enforced by code — not by trust in LYRA:
//  - Funds can only travel into LP positions of WETH-paired pools that
//    belong to the TWO known factories (Uniswap RH + Architect Swap),
//    at the 1% tier. Nowhere else. There is no arbitrary transfer.
//  - The keeper can open/close/collect positions and swap inside those
//    same pools. Every destination is this vault.
//  - Withdrawals pay ACTUAL PROCEEDS: your share of every position is
//    unwound and sold at market in the same transaction — the payout
//    can't be gamed with a spoofed valuation, because there is none.
//  - Season cap hardcoded at deploy. High-water-mark performance fee
//    on realized profit only. Withdraw fee goes to the treasury.
//
// HIGH RISK, stated plainly: this is concentrated liquidity on
// memecoin pools. When a token dumps, the pool buys it with the
// vault's ETH. Fees must outrun impermanent loss. You can lose.
// ============================================================

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface INPM {
    struct MintParams {
        address token0; address token1; uint24 fee; int24 tickLower; int24 tickUpper;
        uint256 amount0Desired; uint256 amount1Desired; uint256 amount0Min; uint256 amount1Min;
        address recipient; uint256 deadline;
    }
    struct DecreaseParams { uint256 tokenId; uint128 liquidity; uint256 amount0Min; uint256 amount1Min; uint256 deadline; }
    struct CollectParams { uint256 tokenId; address recipient; uint128 amount0Max; uint128 amount1Max; }

    function createAndInitializePoolIfNecessary(address, address, uint24, uint160) external payable returns (address);
    function mint(MintParams calldata) external payable returns (uint256 tokenId, uint128 liquidity, uint256, uint256);
    function increaseLiquidity(uint256, uint256, uint256, uint256, uint256) external payable returns (uint128, uint256, uint256);
    function decreaseLiquidity(DecreaseParams calldata) external payable returns (uint256, uint256);
    function collect(CollectParams calldata) external payable returns (uint256, uint256);
    function positions(uint256) external view returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128);
    function burn(uint256) external payable;
}

interface IV3Factory { function getPool(address, address, uint24) external view returns (address); }

interface IV3Pool {
    function swap(address, bool, int256, uint160, bytes calldata) external returns (int256, int256);
    function slot0() external view returns (uint160 sqrtPriceX96, int24, uint16, uint16, uint16, uint8, bool);
}

contract LyraLiquidityVaultV2 {
    // Multi-tier (v2): this chain's majors live in different fee tiers —
    // USDG/WETH is deep at 0.05% and EMPTY at 1%. Any canonical Uniswap tier
    // is allowed, nothing else. The walls stay identical: WETH pairs only,
    // known factories only, funds can only ever be LP or ETH inside them.
    uint24 public constant POOL_FEE = 10000;       // default tier (NLYRA lives here)
    function _validTier(uint24 f) internal pure returns (bool) {
        return f == 100 || f == 500 || f == 3000 || f == 10000;
    }
    uint16 public constant WITHDRAW_FEE_BPS = 50;  // 0.5% → treasury
    uint16 public constant PERF_FEE_BPS = 2000;    // 20% of realized profit → treasury
    uint8 public constant MAX_POSITIONS = 15;
    uint256 private constant Q96 = 2 ** 96;

    address public immutable weth;
    address public immutable treasury;
    address public immutable keeper;      // LYRA's hands (the ops wallet)
    address public immutable npmUni;
    address public immutable npmOurs;
    address public immutable facUni;
    address public immutable facOurs;
    uint256 public immutable seasonCap;   // hard TVL ceiling for this season, in wei

    struct Pos { uint256 id; address npm; address pool; address token; bool weth0; uint24 fee; }
    Pos[] public positions;

    uint256 public totalShares;
    mapping(address => uint256) public shares;
    mapping(address => uint256) public costBasis; // ETH ever deposited minus basis consumed on withdrawals
    uint256 public totalDeposited;                // lifetime, for the record
    uint256 public treasuryEarned;

    address private expectedPool;                 // transient: swap callback guard
    uint256 private unlocked = 1;
    modifier lock() { require(unlocked == 1, "reentrancy"); unlocked = 0; _; unlocked = 1; }
    modifier onlyKeeper() { require(msg.sender == keeper, "keeper"); _; }

    event Deposited(address indexed user, uint256 eth, uint256 sharesOut);
    event Withdrawn(address indexed user, uint256 sharesIn, uint256 ethOut, uint256 perfFee, uint256 exitFee);
    event PositionOpened(uint256 indexed idx, address pool, address token, uint256 tokenId);
    event PositionClosed(uint256 indexed idx, address pool, uint256 tokenId);
    event Swapped(address pool, bool wethIn, uint256 amountIn, uint256 amountOut);
    event FeesCollected(uint256 positionsTouched);

    constructor(
        address _weth, address _treasury, address _keeper,
        address _npmUni, address _npmOurs, address _facUni, address _facOurs,
        uint256 _seasonCap
    ) {
        weth = _weth; treasury = _treasury; keeper = _keeper;
        npmUni = _npmUni; npmOurs = _npmOurs; facUni = _facUni; facOurs = _facOurs;
        seasonCap = _seasonCap;
    }

    receive() external payable {} // WETH.withdraw + pool callbacks land here

    // ── investors ─────────────────────────────────────────────
    function deposit() external payable lock {
        require(msg.value >= 0.0001 ether, "min 0.0001");
        uint256 navBefore = nav() - msg.value; // msg.value already sits in balance
        require(navBefore + msg.value <= seasonCap, "season cap reached");
        uint256 out = totalShares == 0 ? msg.value : (msg.value * totalShares) / (navBefore == 0 ? 1 : navBefore);
        require(out > 0, "zero shares");
        shares[msg.sender] += out;
        totalShares += out;
        costBasis[msg.sender] += msg.value;
        totalDeposited += msg.value;
        emit Deposited(msg.sender, msg.value, out);
    }

    // Withdraw pays what your slice ACTUALLY sells for, right now:
    // your fraction of idle ETH + your fraction of every position,
    // unwound and swapped to ETH in this same transaction.
    function withdraw(uint256 shareAmt, uint256 minEthOut) external lock {
        require(shareAmt > 0 && shareAmt <= shares[msg.sender], "shares");
        uint256 ts = totalShares;

        // 0) sweep pending fees into the common pot first, so the exiting
        //    slice below is pure principal and nobody's fees are skimmed
        for (uint256 i = 0; i < positions.length; i++) {
            try INPM(positions[i].npm).collect(INPM.CollectParams(positions[i].id, address(this), type(uint128).max, type(uint128).max)) {} catch {}
        }

        // 1) realize the slice of every position (principal + its fees)
        uint256 realized;
        for (uint256 i = 0; i < positions.length; i++) {
            realized += _unwindFraction(i, shareAmt, ts);
        }
        // 2) slice of idle funds (collected fees, un-deployed ETH)
        uint256 wIdle = IWETH9(weth).balanceOf(address(this));
        if (wIdle > 0) IWETH9(weth).withdraw(wIdle);
        uint256 idleSlice = ((address(this).balance - realized) * shareAmt) / ts;
        uint256 gross = realized + idleSlice;

        // 3) fees: exit fee + performance on profit above cost basis slice
        uint256 basisSlice = (costBasis[msg.sender] * shareAmt) / shares[msg.sender];
        uint256 perfFee = gross > basisSlice ? ((gross - basisSlice) * PERF_FEE_BPS) / 10000 : 0;
        uint256 exitFee = (gross * WITHDRAW_FEE_BPS) / 10000;
        uint256 out = gross - perfFee - exitFee;
        require(out >= minEthOut, "minEthOut");

        shares[msg.sender] -= shareAmt;
        totalShares -= shareAmt;
        costBasis[msg.sender] -= basisSlice;

        if (perfFee + exitFee > 0) {
            (bool okT, ) = treasury.call{ value: perfFee + exitFee }("");
            require(okT, "treasury");
            treasuryEarned += perfFee + exitFee;
        }
        (bool ok, ) = msg.sender.call{ value: out }("");
        require(ok, "payout");
        emit Withdrawn(msg.sender, shareAmt, out, perfFee, exitFee);
    }

    function _unwindFraction(uint256 i, uint256 shareAmt, uint256 ts) internal returns (uint256 ethOut) {
        Pos memory P = positions[i];
        (, , , , , , , uint128 liq, , , , ) = INPM(P.npm).positions(P.id);
        uint128 dec = uint128((uint256(liq) * shareAmt) / ts);
        uint256 tokBefore = IERC20(P.token).balanceOf(address(this));
        uint256 wBefore = IWETH9(weth).balanceOf(address(this));
        if (dec > 0) {
            INPM(P.npm).decreaseLiquidity(INPM.DecreaseParams(P.id, dec, 0, 0, block.timestamp + 300));
        }
        // collect the decreased principal + the slice's fee share (all fees, split by fraction below is imprecise but fees also flow to idle — kept simple: collect everything owed; the non-slice part becomes idle for everyone)
        INPM(P.npm).collect(INPM.CollectParams(P.id, address(this), type(uint128).max, type(uint128).max));
        uint256 tokGot = IERC20(P.token).balanceOf(address(this)) - tokBefore;
        uint256 wGot = IWETH9(weth).balanceOf(address(this)) - wBefore;
        if (tokGot > 0) wGot += _swapToWeth(P.pool, P.token, tokGot);
        if (wGot > 0) { IWETH9(weth).withdraw(wGot); ethOut = wGot; }
    }

    // ── LYRA's hands (keeper) — every path ends inside the walls ──
    function _checkPool(address npm, address token, uint24 fee) internal view returns (address pool, bool weth0) {
        require(npm == npmUni || npm == npmOurs, "npm");
        require(_validTier(fee), "tier");
        address fac = npm == npmUni ? facUni : facOurs;
        pool = IV3Factory(fac).getPool(weth, token, fee);
        require(pool != address(0), "no pool");
        weth0 = weth < token;
    }

    function seedPool(address npm, address token, uint24 fee, uint160 sqrtPriceX96) external onlyKeeper returns (address pool) {
        require(npm == npmUni || npm == npmOurs, "npm");
        bool w0 = weth < token;
        (address t0, address t1) = w0 ? (weth, token) : (token, weth);
        require(_validTier(fee), "tier");
        pool = INPM(npm).createAndInitializePoolIfNecessary(t0, t1, fee, sqrtPriceX96);
    }

    function openPosition(address npm, address token, uint24 fee, int24 tickLo, int24 tickHi, uint256 wethAmt, uint256 tokenAmt)
        external onlyKeeper lock returns (uint256 idx)
    {
        require(positions.length < MAX_POSITIONS, "max positions");
        (address pool, bool weth0) = _checkPool(npm, token, fee);
        uint256 ethBal = address(this).balance;
        if (ethBal > 0) IWETH9(weth).deposit{ value: ethBal }();
        IWETH9(weth).approve(npm, wethAmt);
        IERC20(token).approve(npm, tokenAmt);
        (address t0, address t1) = weth0 ? (weth, token) : (token, weth);
        (uint256 a0, uint256 a1) = weth0 ? (wethAmt, tokenAmt) : (tokenAmt, wethAmt);
        (uint256 id, , , ) = INPM(npm).mint(INPM.MintParams(t0, t1, fee, tickLo, tickHi, a0, a1, 0, 0, address(this), block.timestamp + 300));
        positions.push(Pos(id, npm, pool, token, weth0, fee));
        emit PositionOpened(positions.length - 1, pool, token, id);
        return positions.length - 1;
    }

    function closePosition(uint256 idx, bool sellTokenSide) external onlyKeeper lock {
        Pos memory P = positions[idx];
        (, , , , , , , uint128 liq, , , , ) = INPM(P.npm).positions(P.id);
        if (liq > 0) INPM(P.npm).decreaseLiquidity(INPM.DecreaseParams(P.id, liq, 0, 0, block.timestamp + 300));
        INPM(P.npm).collect(INPM.CollectParams(P.id, address(this), type(uint128).max, type(uint128).max));
        INPM(P.npm).burn(P.id);
        if (sellTokenSide) {
            uint256 tb = IERC20(P.token).balanceOf(address(this));
            if (tb > 0) _swapToWeth(P.pool, P.token, tb);
        }
        positions[idx] = positions[positions.length - 1];
        positions.pop();
        emit PositionClosed(idx, P.pool, P.id);
    }

    function collectAll() external lock returns (uint256 n) {
        // anyone can trigger fee collection — fees only ever land in the vault
        for (uint256 i = 0; i < positions.length; i++) {
            try INPM(positions[i].npm).collect(INPM.CollectParams(positions[i].id, address(this), type(uint128).max, type(uint128).max)) { n++; } catch {}
        }
        emit FeesCollected(n);
    }

    // rebalance inside the walls: swap WETH↔token in a whitelisted pool
    function swapInPool(address npm, address token, uint24 fee, bool wethIn, uint256 amountIn, uint256 minOut)
        external onlyKeeper lock returns (uint256 out)
    {
        (address pool, ) = _checkPool(npm, token, fee);
        if (wethIn) {
            uint256 ethBal = address(this).balance;
            if (ethBal > 0) IWETH9(weth).deposit{ value: ethBal }();
            out = _swapFromWeth(pool, token, amountIn);
        } else {
            out = _swapToWeth(pool, token, amountIn);
        }
        require(out >= minOut, "minOut");
        emit Swapped(pool, wethIn, amountIn, out);
    }

    function _swapToWeth(address pool, address token, uint256 amountIn) internal returns (uint256 out) {
        bool zeroForOne = token < weth;
        expectedPool = pool;
        (int256 d0, int256 d1) = IV3Pool(pool).swap(address(this), zeroForOne, int256(amountIn),
            zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341, abi.encode(token));
        expectedPool = address(0);
        out = uint256(-(zeroForOne ? d1 : d0));
    }

    function _swapFromWeth(address pool, address token, uint256 amountIn) internal returns (uint256 out) {
        bool zeroForOne = weth < token;
        expectedPool = pool;
        (int256 d0, int256 d1) = IV3Pool(pool).swap(address(this), zeroForOne, int256(amountIn),
            zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341, abi.encode(weth));
        expectedPool = address(0);
        out = uint256(-(zeroForOne ? d1 : d0));
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        require(msg.sender == expectedPool && expectedPool != address(0), "callback");
        address payToken = abi.decode(data, (address));
        uint256 owed = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        require(IERC20(payToken).transfer(msg.sender, owed), "pay pool");
    }

    // ── NAV: only used to price DEPOSIT shares (withdrawals pay real proceeds).
    // Position value at spot price; spot is manipulable, so deposits are
    // capped by the season cap and the share math self-corrects at exit.
    function nav() public view returns (uint256 v) {
        v = address(this).balance + IWETH9(weth).balanceOf(address(this));
        for (uint256 i = 0; i < positions.length; i++) {
            v += _positionValue(positions[i]);
        }
    }

    function _positionValue(Pos memory P) internal view returns (uint256 v) {
        (, , , , , int24 tickLo, int24 tickHi, uint128 liq, , , uint128 owed0, uint128 owed1) = INPM(P.npm).positions(P.id);
        (uint160 sp, , , , , , ) = IV3Pool(P.pool).slot0();
        uint160 lo = _sqrtAtTick(tickLo);
        uint160 hi = _sqrtAtTick(tickHi);
        uint160 p = sp < lo ? lo : (sp > hi ? hi : sp);
        // amount0 = L*Q96*(1/p - 1/hi) · amount1 = L*(p - lo)/Q96
        uint256 a0 = liq == 0 ? 0 : (uint256(liq) * Q96) / p - (uint256(liq) * Q96) / hi;
        uint256 a1 = liq == 0 ? 0 : (uint256(liq) * (p - lo)) / Q96;
        a0 += owed0; a1 += owed1;
        uint256 wethSide; uint256 tokSide; bool tokIs0;
        if (P.weth0) { wethSide = a0; tokSide = a1; tokIs0 = false; }
        else { wethSide = a1; tokSide = a0; tokIs0 = true; }
        v = wethSide + _tokenToWeth(tokSide, sp, tokIs0);
    }

    function _tokenToWeth(uint256 amt, uint160 sp, bool tokIs0) internal pure returns (uint256) {
        if (amt == 0) return 0;
        if (tokIs0) {
            // price of token0 in token1(WETH) = (sp/Q96)^2
            return ((amt * sp) / Q96) * sp / Q96;
        }
        // token is token1; 1 token0(WETH) = (sp/Q96)^2 token1 → token1 → WETH = amt * Q96^2 / sp^2
        return ((amt * Q96) / sp) * Q96 / sp;
    }

    // minimal TickMath (Uniswap V3): sqrt(1.0001^tick) * 2^96
    function _sqrtAtTick(int24 tick) internal pure returns (uint160) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= 887272, "tick");
        uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;
        if (tick > 0) ratio = type(uint256).max / ratio;
        return uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }

    // frontend helpers
    function positionCount() external view returns (uint256) { return positions.length; }
    function sharePrice() external view returns (uint256) {
        return totalShares == 0 ? 1 ether : (nav() * 1 ether) / totalShares;
    }
}

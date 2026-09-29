// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ============================================================
// ARCHITECT PRESALE — the presale that cannot rug (Robinhood Chain)
// by NERON & LYRA · nlyra.xyz
//
// "Your ETH never touches the creator's hands until the pool exists."
//
// - Contributions are escrowed in this contract. The creator has NO
//   function to withdraw them. None. Ever.
// - Finalize (anyone can call): platform fee → treasury, the promised
//   share of the raise becomes a full-range V3 position at the listing
//   price, and the position NFT lives in this contract FOREVER — there
//   is no function to move, decrease or burn it. LP is locked by
//   construction, not by a 30-day locker.
// - The creator keeps earning: pool fees accrue to the locked position
//   and collectFees() splits them creator/treasury at the immutable
//   ratio — same eternal-fees model as Architect Launch.
// - Soft cap missed → everyone refunds, creator reclaims tokens.
// - Creator can cancel any time BEFORE finalize → same refund path.
// - If finalize is impossible (hostile pre-created pool) for 7 days
//   after the end, refunds open anyway. Nobody's ETH can be trapped.
// - Unsold tokens and unused liquidity tokens are burned at finalize.
// ============================================================

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable returns (address pool);

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);
}

interface IV3Pool {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
}

// ------------------------------------------------------------
// One instance per presale. Immutable terms, escrowed funds.
// ------------------------------------------------------------
contract ArchitectPresale {
    uint24 public constant POOL_FEE = 10000;   // 1% tier, same as Architect Launch
    int24 internal constant TICK_MIN = -887200; // full range, spacing 200
    int24 internal constant TICK_MAX = 887200;
    uint256 public constant GRACE = 7 days;     // finalize impossible → refunds open
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public immutable factory;
    IERC20 public immutable token;
    address public immutable creator;
    address public immutable treasury;
    address public immutable weth;
    address public immutable npm;          // position manager of the chosen venue
    uint16 public immutable creatorFeeBps; // pool-fee split: 90 (ours) / 80 (uniswap), over 100
    uint16 public immutable platformFeeBps; // on the raise, over 10000
    uint8 public immutable venue;           // 1 = Architect Swap V3, 2 = Uniswap V3

    uint256 public immutable softCap;      // wei
    uint256 public immutable hardCap;      // wei
    uint256 public immutable minBuy;       // wei per wallet
    uint256 public immutable maxBuy;       // wei per wallet
    uint64 public immutable startTime;
    uint64 public immutable endTime;
    uint256 public immutable presaleRate;  // token raw units per 1 ETH
    uint256 public immutable listingRate;  // token raw units per 1 ETH in the pool (<= presaleRate)
    uint16 public immutable liqBps;        // share of (raise - fee) that becomes liquidity, over 10000

    uint256 public raised;
    bool public finalized;
    bool public cancelled;
    address public pool;
    uint256 public positionId;             // locked in this contract forever
    uint256 public creatorEarned;
    mapping(address => uint256) public contributions;
    mapping(address => bool) public claimed;

    uint256 private unlocked = 1;
    modifier lock() { require(unlocked == 1, "reentrancy"); unlocked = 0; _; unlocked = 1; }

    event Contributed(address indexed buyer, uint256 amount, uint256 raised);
    event Finalized(address pool, uint256 positionId, uint256 liqEth, uint256 liqTokens, uint256 creatorEth, uint256 feeEth);
    event Claimed(address indexed buyer, uint256 tokens);
    event Refunded(address indexed buyer, uint256 amount);
    event Cancelled();
    event TokensReclaimed(uint256 amount);
    event FeesCollected(uint256 ethToCreator, uint256 ethToTreasury, uint256 tokensToCreator, uint256 tokensToTreasury);

    struct Terms {
        address token;
        address creator;
        uint8 venue;
        uint256 softCap;
        uint256 hardCap;
        uint256 minBuy;
        uint256 maxBuy;
        uint64 startTime;
        uint64 endTime;
        uint256 presaleRate;
        uint256 listingRate;
        uint16 liqBps;
    }

    constructor(Terms memory t, address _treasury, address _weth, address _npm, uint16 _platformFeeBps) {
        factory = msg.sender;
        token = IERC20(t.token);
        creator = t.creator;
        treasury = _treasury;
        weth = _weth;
        npm = _npm;
        venue = t.venue;
        creatorFeeBps = t.venue == 2 ? 80 : 90;
        platformFeeBps = _platformFeeBps;
        softCap = t.softCap;
        hardCap = t.hardCap;
        minBuy = t.minBuy;
        maxBuy = t.maxBuy;
        startTime = t.startTime;
        endTime = t.endTime;
        presaleRate = t.presaleRate;
        listingRate = t.listingRate;
        liqBps = t.liqBps;
    }

    // tokens the contract must hold to honor every promise at hard cap
    function tokensForSale() public view returns (uint256) { return (hardCap * presaleRate) / 1e18; }
    function tokensForLiquidity() public view returns (uint256) {
        // worst case: full raise, all of (raise - fee) * liqBps into the pool
        uint256 liqEthMax = ((hardCap - (hardCap * platformFeeBps) / 10000) * liqBps) / 10000;
        return (liqEthMax * listingRate) / 1e18;
    }

    // ── contribute ────────────────────────────────────────────
    function contribute() external payable lock {
        require(block.timestamp >= startTime, "not started");
        require(block.timestamp < endTime, "ended");
        require(!finalized && !cancelled, "closed");
        require(raised + msg.value <= hardCap, "hard cap");
        uint256 c = contributions[msg.sender] + msg.value;
        require(msg.value > 0 && c >= minBuy, "below min");
        require(c <= maxBuy, "above max");
        contributions[msg.sender] = c;
        raised += msg.value;
        emit Contributed(msg.sender, msg.value, raised);
    }

    receive() external payable {
        require(msg.sender == weth, "use contribute()"); // WETH.withdraw only
    }

    // ── finalize: fee → treasury, LP → locked forever, rest → creator ──
    function finalize() external lock {
        require(!finalized && !cancelled, "closed");
        require(raised >= softCap, "soft cap not met");
        require(block.timestamp >= endTime || raised == hardCap, "still running");
        // past the grace the refund path owns the ETH — the two must never overlap
        require(block.timestamp < uint256(endTime) + GRACE, "grace passed");
        finalized = true;

        uint256 fee = (raised * platformFeeBps) / 10000;
        uint256 liqEth = ((raised - fee) * liqBps) / 10000;
        uint256 liqTok = (liqEth * listingRate) / 1e18;
        uint256 creatorEth = raised - fee - liqEth;

        // pool at the listing price — buyers' floor is set before anyone is paid
        IWETH9(weth).deposit{ value: liqEth }();
        bool weth0 = weth < address(token);
        (address t0, address t1) = weth0 ? (weth, address(token)) : (address(token), weth);
        (uint256 a0d, uint256 a1d) = weth0 ? (liqEth, liqTok) : (liqTok, liqEth);

        uint160 sqrtP = _sqrtPriceX96(a0d, a1d);
        pool = INonfungiblePositionManager(npm).createAndInitializePoolIfNecessary(t0, t1, POOL_FEE, sqrtP);
        // a hostile pre-created pool at another price would let a sniper drain
        // the position — refuse, and let the 7-day grace open refunds instead.
        (uint160 cur,,,,,,) = IV3Pool(pool).slot0();
        require(cur > (sqrtP / 100) * 99 && cur < (sqrtP / 100) * 101, "pool price hostile");

        require(token.approve(npm, liqTok), "approve tok");
        _approveWeth(liqEth);
        (uint256 id,, uint256 a0, uint256 a1) = INonfungiblePositionManager(npm).mint(
            INonfungiblePositionManager.MintParams({
                token0: t0,
                token1: t1,
                fee: POOL_FEE,
                tickLower: TICK_MIN,
                tickUpper: TICK_MAX,
                amount0Desired: a0d,
                amount1Desired: a1d,
                amount0Min: (a0d * 95) / 100,
                amount1Min: (a1d * 95) / 100,
                recipient: address(this), // locked here forever
                deadline: block.timestamp + 600
            })
        );
        positionId = id;

        // unused WETH back to ETH so the creator payout below is complete
        uint256 wLeft = IWETH9(weth).balanceOf(address(this));
        if (wLeft > 0) { IWETH9(weth).withdraw(wLeft); creatorEth += wLeft; }

        if (fee > 0) { (bool okF, ) = treasury.call{ value: fee }(""); require(okF, "fee"); }
        if (creatorEth > 0) { (bool okC, ) = creator.call{ value: creatorEth }(""); require(okC, "creator"); }

        // burn everything not promised to buyers: unsold sale tokens + unused liq tokens
        uint256 owedBuyers = (raised * presaleRate) / 1e18;
        uint256 bal = token.balanceOf(address(this));
        if (bal > owedBuyers) require(token.transfer(DEAD, bal - owedBuyers), "burn");

        uint256 usedTok = weth0 ? a1 : a0;
        emit Finalized(pool, id, liqEth, usedTok, creatorEth, fee);
    }

    function _approveWeth(uint256 amount) internal {
        require(IERC20(weth).approve(npm, amount), "approve weth");
    }

    // ── claim / refund ───────────────────────────────────────
    function claim() external lock {
        require(finalized, "not finalized");
        require(!claimed[msg.sender], "claimed");
        uint256 c = contributions[msg.sender];
        require(c > 0, "nothing");
        claimed[msg.sender] = true;
        require(token.transfer(msg.sender, (c * presaleRate) / 1e18), "transfer");
        emit Claimed(msg.sender, (c * presaleRate) / 1e18);
    }

    function refundsOpen() public view returns (bool) {
        if (finalized) return false;
        if (cancelled) return true;
        if (block.timestamp >= endTime && raised < softCap) return true;
        if (block.timestamp >= uint256(endTime) + GRACE) return true; // finalize griefed → escape hatch
        return false;
    }

    function refund() external lock {
        require(refundsOpen(), "no refunds");
        uint256 c = contributions[msg.sender];
        require(c > 0, "nothing");
        contributions[msg.sender] = 0;
        (bool okR, ) = msg.sender.call{ value: c }("");
        require(okR, "refund");
        emit Refunded(msg.sender, c);
    }

    function cancel() external {
        require(msg.sender == creator, "auth");
        require(!finalized && !cancelled, "closed");
        cancelled = true;
        emit Cancelled();
    }

    function reclaimTokens() external lock {
        require(msg.sender == creator, "auth");
        require(refundsOpen(), "not refunding");
        uint256 bal = token.balanceOf(address(this));
        require(bal > 0, "nothing");
        require(token.transfer(creator, bal), "transfer");
        emit TokensReclaimed(bal);
    }

    // ── eternal fees on the locked LP — same model as Architect Launch ──
    function collectFees() external lock returns (uint256 creatorEth, uint256 treasuryEth) {
        require(positionId != 0, "no position");
        INonfungiblePositionManager(npm).collect(
            INonfungiblePositionManager.CollectParams(positionId, address(this), type(uint128).max, type(uint128).max)
        );
        uint256 tokenBal = token.balanceOf(address(this));
        uint256 wBal = IWETH9(weth).balanceOf(address(this));
        if (wBal > 0) IWETH9(weth).withdraw(wBal);
        uint256 ethBal = address(this).balance;
        require(ethBal > 0 || tokenBal > 0, "nothing to collect");

        creatorEth = (ethBal * creatorFeeBps) / 100;
        treasuryEth = ethBal - creatorEth;
        uint256 creatorTok = (tokenBal * creatorFeeBps) / 100;
        uint256 treasuryTok = tokenBal - creatorTok;

        if (creatorEth > 0) {
            (bool okC, ) = creator.call{ value: creatorEth }("");
            if (okC) creatorEarned += creatorEth;
            else { treasuryEth += creatorEth; creatorEth = 0; }
        }
        if (treasuryEth > 0) { (bool okT, ) = treasury.call{ value: treasuryEth }(""); require(okT, "treasury"); }
        if (creatorTok > 0 && !token.transfer(creator, creatorTok)) { treasuryTok += creatorTok; creatorTok = 0; }
        if (treasuryTok > 0) require(token.transfer(treasury, treasuryTok), "tok");

        emit FeesCollected(creatorEth, treasuryEth, creatorTok, treasuryTok);
    }

    // sqrt(amount1/amount0) * 2^96 — integer sqrt keeps ~1e-8 relative
    // precision for real-world amounts; mint mins at 95% absorb the drift.
    function _sqrtPriceX96(uint256 amount0, uint256 amount1) internal pure returns (uint160) {
        require(amount0 > 0 && amount1 > 0, "amounts");
        uint256 r = (_sqrt(amount1) << 96) / _sqrt(amount0);
        require(r > 4295128739 && r < 1461446703485210103287273052203988822378723970342, "price range");
        return uint160(r);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) { y = z; z = (x / z + z) / 2; }
    }

    // one call for the frontend
    function info()
        external
        view
        returns (
            address token_, address creator_, uint8 venue_,
            uint256 softCap_, uint256 hardCap_, uint256 minBuy_, uint256 maxBuy_,
            uint64 start_, uint64 end_, uint256 presaleRate_, uint256 listingRate_, uint16 liqBps_,
            uint256 raised_, bool finalized_, bool cancelled_, bool refundsOpen_, address pool_
        )
    {
        return (
            address(token), creator, venue,
            softCap, hardCap, minBuy, maxBuy,
            startTime, endTime, presaleRate, listingRate, liqBps,
            raised, finalized, cancelled, refundsOpen(), pool
        );
    }
}

// ------------------------------------------------------------
// The factory: escrows the full token budget at creation.
// ------------------------------------------------------------
contract ArchitectPresaleFactory {
    address public immutable treasury;  // the NLYRA BuybackBurner
    address public immutable weth;
    address public immutable npmOurs;   // Architect Swap V3
    address public immutable npmUni;    // Uniswap V3
    uint16 public immutable platformFeeBps; // on the raise

    struct Sale {
        address presale;
        address token;
        address creator;
        uint256 createdAt;
    }

    Sale[] public sales;
    mapping(address => uint256[]) public salesOfToken;

    event PresaleCreated(address indexed presale, address indexed token, address indexed creator, uint256 hardCap, uint64 start, uint64 end);

    constructor(address _treasury, address _weth, address _npmOurs, address _npmUni, uint16 _platformFeeBps) {
        require(_platformFeeBps <= 1000, "fee cap 10%"); // immutable promise: never more
        treasury = _treasury;
        weth = _weth;
        npmOurs = _npmOurs;
        npmUni = _npmUni;
        platformFeeBps = _platformFeeBps;
    }

    function createPresale(
        address token,
        uint8 venue,
        uint256 softCap,
        uint256 hardCap,
        uint256 minBuy,
        uint256 maxBuy,
        uint64 startTime,
        uint64 endTime,
        uint256 presaleRate,
        uint256 listingRate,
        uint16 liqBps
    ) external returns (address presaleAddr) {
        require(token != address(0), "token");
        require(venue == 1 || venue == 2, "venue");
        require(softCap > 0 && softCap <= hardCap, "caps");
        require(softCap >= hardCap / 4, "soft cap >= 25% of hard cap");
        require(minBuy > 0 && minBuy <= maxBuy && maxBuy <= hardCap, "buy limits");
        require(startTime >= block.timestamp && endTime > startTime, "times");
        require(endTime - startTime <= 30 days, "max 30 days");
        require(presaleRate > 0 && listingRate > 0, "rates");
        require(listingRate <= presaleRate, "listing price below presale");
        require(liqBps >= 5000 && liqBps <= 10000, "liquidity 50-100%");

        ArchitectPresale.Terms memory t = ArchitectPresale.Terms(
            token, msg.sender, venue, softCap, hardCap, minBuy, maxBuy,
            startTime, endTime, presaleRate, listingRate, liqBps
        );
        ArchitectPresale p = new ArchitectPresale(t, treasury, weth, venue == 1 ? npmOurs : npmUni, platformFeeBps);

        // escrow the full budget now — the promise must be fully backed.
        // fee-on-transfer tokens are rejected: what arrives must be what was promised.
        uint256 need = p.tokensForSale() + p.tokensForLiquidity();
        require(need > 0, "empty sale");
        uint256 before = IERC20(token).balanceOf(address(p));
        require(IERC20(token).transferFrom(msg.sender, address(p), need), "escrow");
        require(IERC20(token).balanceOf(address(p)) == before + need, "fee-on-transfer token");

        sales.push(Sale(address(p), token, msg.sender, block.timestamp));
        salesOfToken[token].push(sales.length - 1);
        emit PresaleCreated(address(p), token, msg.sender, hardCap, startTime, endTime);
        return address(p);
    }

    function saleCount() external view returns (uint256) {
        return sales.length;
    }
}

// ------------------------------------------------------------
// Minimal test token — only used by the e2e deploy test, never in prod.
// ------------------------------------------------------------
contract PresaleTestToken {
    string public name = "Presale Test";
    string public symbol = "PTEST";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor() { totalSupply = 1_000_000_000e18; balanceOf[msg.sender] = totalSupply; emit Transfer(address(0), msg.sender, totalSupply); }
    function transfer(address to, uint256 v) external returns (bool) { return _t(msg.sender, to, v); }
    function approve(address s, uint256 v) external returns (bool) { allowance[msg.sender][s] = v; emit Approval(msg.sender, s, v); return true; }
    function transferFrom(address f, address to, uint256 v) external returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) { require(a >= v, "allowance"); allowance[f][msg.sender] = a - v; }
        return _t(f, to, v);
    }
    function _t(address f, address to, uint256 v) internal returns (bool) {
        require(balanceOf[f] >= v, "balance");
        unchecked { balanceOf[f] -= v; }
        balanceOf[to] += v;
        emit Transfer(f, to, v);
        return true;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ============================================================
// ARCHITECT LAUNCH — HOLDER REWARDS EDITION (Robinhood Chain)
// by NERON & LYRA · nlyra.xyz
//
// "Hold it, and the pool pays you."
//
// Fork of ArchitectLaunchFactoryV2 (verified) with ONE change of
// substance: the pool's 1% trading fee splits three ways instead
// of two — 30% creator · 20% treasury · 50% holder rewards.
// The rewards share lands in a per-launch RewardsDistributor that
// converts it to the reward token the CREATOR chose at birth
// (WETH, NLYRA, anything with a WETH pool) and rains it on
// holders. The split is immutable. The venue is Uniswap V3 — the
// same pools the Robinhood app trades against.
//
// Same guarantees as every Architect launch: entire supply born
// inside a locked full-range-side position owned by the vault
// forever, no owner, no pause, no rug. Token is a bone-standard
// ERC20 — no transfer tax (V3-compatible by construction).
//
// Trust note, stated honestly: conversion + distribution are
// EXECUTED by the NLYRA keeper (funds can only move pool→holders
// along the coded paths — the keeper cannot redirect value to
// itself except by being a holder), because "who holds how much"
// lives off-chain in Blockscout. Every step is public.
// ============================================================

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function allowance(address, address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
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

    function createAndInitializePoolIfNecessary(address token0, address token1, uint24 fee, uint160 sqrtPriceX96)
        external payable returns (address pool);
    function mint(MintParams calldata params)
        external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);
    function positions(uint256 tokenId)
        external view
        returns (uint96, address, address token0, address token1, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128);
}

interface IV3Pool {
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external returns (int256 amount0, int256 amount1);
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
}

interface IV3Factory {
    function getPool(address, address, uint24) external view returns (address);
}

interface IRewardsVaultLike {
    function pool() external view returns (address);
    function token() external view returns (IERC20);
}

// ------------------------------------------------------------
// Same minimal token as every Architect launch. No tax, no owner.
// ------------------------------------------------------------
contract ArchitectTokenHR is IERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public constant override totalSupply = 1_000_000_000e18;

    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, address vault) {
        name = _name;
        symbol = _symbol;
        balanceOf[vault] = totalSupply;
        emit Transfer(address(0), vault, totalSupply);
    }

    function transfer(address to, uint256 value) external override returns (bool) { return _transfer(msg.sender, to, value); }

    function approve(address spender, uint256 value) external override returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= value, "allowance");
            allowance[from][msg.sender] = allowed - value;
        }
        return _transfer(from, to, value);
    }

    function _transfer(address from, address to, uint256 value) internal returns (bool) {
        require(to != address(0), "zero to");
        uint256 bal = balanceOf[from];
        require(bal >= value, "balance");
        unchecked { balanceOf[from] = bal - value; }
        balanceOf[to] += value;
        emit Transfer(from, to, value);
        return true;
    }
}

// ------------------------------------------------------------
// The rewards pot: receives the holders' 50% share of pool fees
// (raw ETH + launch tokens), converts to the reward token, and
// the keeper rains it on holders — airdrop-style, no claiming.
// Value can only travel pool → holders. No withdraw. No owner.
// ------------------------------------------------------------
contract RewardsDistributor {
    address public immutable weth;
    address public immutable v3factory;   // Uniswap V3 factory (to locate the reward pool)
    address public immutable rewardToken; // what holders are paid in — the creator's choice
    address public immutable keeper;      // NLYRA ops: runs convert + distribute, cannot redirect funds
    address public vault;                 // set once by the factory right after both exist

    uint24 public constant POOL_FEE = 10000;
    address private swappingPool;         // transient guard for the swap callback

    uint256 private unlocked = 1;
    modifier lock() { require(unlocked == 1, "reentrancy"); unlocked = 0; _; unlocked = 1; }

    event Converted(uint256 launchTokensIn, uint256 ethIn, uint256 rewardsOut);
    event Distributed(uint256 holders, uint256 total);

    constructor(address _weth, address _v3factory, address _rewardToken, address _keeper) {
        weth = _weth;
        v3factory = _v3factory;
        rewardToken = _rewardToken;
        keeper = _keeper;
    }

    function init(address _vault) external {
        require(vault == address(0), "init once");
        vault = _vault;
    }

    receive() external payable {} // the vault forwards the holders' ETH share here

    // Convert everything held into the reward token:
    //   launch tokens → WETH through the launch pool, then
    //   WETH → rewardToken through the reward pool (skipped if reward IS WETH).
    // Keeper-only because minOut must be set by someone accountable —
    // an open call with minOut=0 would be a free sandwich.
    function convert(uint256 minWethOut, uint256 minRewardOut) external lock {
        require(msg.sender == keeper, "keeper");
        IERC20 launchTok = IRewardsVaultLike(vault).token();
        address launchPool = IRewardsVaultLike(vault).pool();

        uint256 tokBal = launchTok.balanceOf(address(this));
        if (tokBal > 0) {
            bool zeroForOne = address(launchTok) < weth;
            swappingPool = launchPool;
            (int256 d0, int256 d1) = IV3Pool(launchPool).swap(
                address(this), zeroForOne, int256(tokBal),
                zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341,
                abi.encode(address(launchTok))
            );
            swappingPool = address(0);
            uint256 got = uint256(-(zeroForOne ? d1 : d0));
            require(got >= minWethOut, "minWethOut");
        }

        uint256 ethBal = address(this).balance;
        if (ethBal > 0) IWETH9(weth).deposit{ value: ethBal }();
        uint256 wBal = IWETH9(weth).balanceOf(address(this));

        if (rewardToken != weth && wBal > 0) {
            address rewardPool = IV3Factory(v3factory).getPool(weth, rewardToken, POOL_FEE);
            require(rewardPool != address(0), "no reward pool");
            bool zeroForOne2 = weth < rewardToken;
            swappingPool = rewardPool;
            (int256 e0, int256 e1) = IV3Pool(rewardPool).swap(
                address(this), zeroForOne2, int256(wBal),
                zeroForOne2 ? 4295128740 : 1461446703485210103287273052203988822378723970341,
                abi.encode(weth)
            );
            swappingPool = address(0);
            uint256 out = uint256(-(zeroForOne2 ? e1 : e0));
            require(out >= minRewardOut, "minRewardOut");
        }
        emit Converted(tokBal, ethBal, IERC20(rewardToken).balanceOf(address(this)));
    }

    // The pool is read from STORAGE, armed by convert() immediately before the
    // swap and cleared right after. Never from `data` — that is caller-supplied,
    // and comparing it against msg.sender compares the caller against itself.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        require(msg.sender == swappingPool && swappingPool != address(0), "callback");
        address payToken = abi.decode(data, (address));
        uint256 owed = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        require(IERC20(payToken).transfer(msg.sender, owed), "pay pool");
    }

    // Rain the pot on holders. Snapshot is computed off-chain from the
    // explorer (public, verifiable); transfers are plain and on-chain.
    // Two hard rules, enforced HERE and not in the snapshot:
    //  - it can never revert: a bad recipient is skipped, the rest get paid,
    //    and whatever was skipped stays in the pot for the next round.
    //  - it can never pay a contract: pools, vaults, routers — anything with
    //    code is skipped on-chain. Rewards go to people, not to plumbing.
    function distribute(address[] calldata to, uint256[] calldata amount) external lock {
        require(msg.sender == keeper, "keeper");
        require(to.length == amount.length, "length");
        uint256 total;
        uint256 paid;
        for (uint256 i = 0; i < to.length; i++) {
            address r = to[i];
            if (r == address(0) || r.code.length > 0) continue; // never contracts, never pools
            (bool ok, bytes memory ret) = rewardToken.call(
                abi.encodeWithSelector(IERC20.transfer.selector, r, amount[i])
            );
            if (!ok || (ret.length > 0 && !abi.decode(ret, (bool)))) continue; // never revert the batch
            total += amount[i];
            paid++;
        }
        emit Distributed(paid, total);
    }
}

// ------------------------------------------------------------
// The vault: identical to ArchitectPoolVault except the fee split.
// Uniswap V3 only. 30% creator · 20% treasury · 50% distributor.
// ------------------------------------------------------------
contract ArchitectRewardsVault {
    uint256 public constant SUPPLY = 1_000_000_000e18;
    uint256 public constant MAX_BUY = 50_000_000e18; // 5% cap on the creator's atomic first buy
    uint24 public constant POOL_FEE = 10000;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    int24 internal constant TICK_MIN = -887200;
    int24 internal constant TICK_MAX = 887200;

    uint16 public constant CREATOR_BPS = 30;  // over 100
    uint16 public constant TREASURY_BPS = 20;
    uint16 public constant HOLDERS_BPS = 50;

    address public immutable factory;
    address public immutable treasury;
    address public immutable weth;
    address public immutable npm;
    address public immutable creator;
    address public immutable distributor;

    IERC20 public token;
    address public pool;
    uint256 public positionId;
    uint256 public creatorEarned;
    uint256 public holdersEarned; // ETH routed to rewards, lifetime

    uint160 internal immutable sqrtWeth0;
    uint160 internal immutable sqrtWeth1;
    int24 internal immutable tickEdgeWeth0;
    int24 internal immutable tickEdgeWeth1;

    uint256 private unlocked = 1;
    modifier lock() { require(unlocked == 1, "reentrancy"); unlocked = 0; _; unlocked = 1; }

    event BornInPool(address indexed token, address pool, uint256 positionId, address rewardToken);
    event DevFirstBuy(address indexed creator, uint256 ethIn, uint256 tokensOut);
    event FeesCollected(uint256 ethToCreator, uint256 ethToTreasury, uint256 ethToHolders, uint256 tokensToHolders);

    constructor(
        address _treasury, address _weth, address _npm, address _creator, address _distributor,
        uint160 _sqrtWeth0, uint160 _sqrtWeth1, int24 _tickEdgeWeth0, int24 _tickEdgeWeth1
    ) {
        factory = msg.sender;
        treasury = _treasury;
        weth = _weth;
        npm = _npm;
        creator = _creator;
        distributor = _distributor;
        sqrtWeth0 = _sqrtWeth0;
        sqrtWeth1 = _sqrtWeth1;
        tickEdgeWeth0 = _tickEdgeWeth0;
        tickEdgeWeth1 = _tickEdgeWeth1;
    }

    function init(address _token) external payable lock {
        require(msg.sender == factory && address(token) == address(0), "init");
        token = IERC20(_token);

        bool weth0 = weth < _token;
        (address t0, address t1) = weth0 ? (weth, _token) : (_token, weth);
        (int24 lo, int24 hi) = weth0 ? (TICK_MIN, tickEdgeWeth0) : (tickEdgeWeth1, TICK_MAX);

        pool = INonfungiblePositionManager(npm).createAndInitializePoolIfNecessary(t0, t1, POOL_FEE, weth0 ? sqrtWeth0 : sqrtWeth1);
        (uint160 cur,,,,,,) = IV3Pool(pool).slot0();
        require(cur == (weth0 ? sqrtWeth0 : sqrtWeth1), "pool price hostile");

        require(token.approve(npm, SUPPLY), "approve");
        (uint256 id,, uint256 a0, uint256 a1) = INonfungiblePositionManager(npm).mint(
            INonfungiblePositionManager.MintParams({
                token0: t0, token1: t1, fee: POOL_FEE, tickLower: lo, tickUpper: hi,
                amount0Desired: weth0 ? 0 : SUPPLY, amount1Desired: weth0 ? SUPPLY : 0,
                amount0Min: 0, amount1Min: 0, recipient: address(this), deadline: block.timestamp + 600
            })
        );
        positionId = id;
        uint256 used = weth0 ? a1 : a0;
        if (SUPPLY > used) require(token.transfer(DEAD, SUPPLY - used), "dust burn");

        emit BornInPool(_token, pool, id, RewardsDistributor(payable(distributor)).rewardToken());

        if (msg.value > 0) {
            (int256 d0, int256 d1) = IV3Pool(pool).swap(
                creator, weth0, int256(msg.value),
                weth0 ? 4295128740 : 1461446703485210103287273052203988822378723970341, ""
            );
            uint256 got = uint256(-(weth0 ? d1 : d0));
            require(got <= MAX_BUY, "max buy 5%");
            emit DevFirstBuy(creator, msg.value, got);
        }
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == pool, "callback");
        uint256 owed = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        IWETH9(weth).deposit{ value: owed }();
        require(IWETH9(weth).transfer(pool, owed), "pay pool");
    }

    // The eternal fees, three ways. Anyone can call — every destination is
    // hardcoded. The holders' share (ETH + launch tokens) goes RAW to the
    // distributor; conversion happens there with slippage protection.
    function collectFees() external lock returns (uint256 creatorEth, uint256 treasuryEth, uint256 holdersEth) {
        require(positionId != 0, "no position");

        (,, address t0, address t1,,,,,,,,) = INonfungiblePositionManager(npm).positions(positionId);
        INonfungiblePositionManager(npm).collect(
            INonfungiblePositionManager.CollectParams(positionId, address(this), type(uint128).max, type(uint128).max)
        );

        address tk = t0 == weth ? t1 : t0;
        uint256 tokenBal = IERC20(tk).balanceOf(address(this));
        uint256 wBal = IWETH9(weth).balanceOf(address(this));
        if (wBal > 0) IWETH9(weth).withdraw(wBal);
        uint256 ethBal = address(this).balance;
        require(ethBal > 0 || tokenBal > 0, "nothing to collect");

        creatorEth = (ethBal * CREATOR_BPS) / 100;
        treasuryEth = (ethBal * TREASURY_BPS) / 100;
        holdersEth = ethBal - creatorEth - treasuryEth;

        uint256 creatorTok = (tokenBal * CREATOR_BPS) / 100;
        uint256 treasuryTok = (tokenBal * TREASURY_BPS) / 100;
        uint256 holdersTok = tokenBal - creatorTok - treasuryTok;

        if (creatorEth > 0) {
            (bool okC, ) = creator.call{ value: creatorEth }("");
            if (okC) creatorEarned += creatorEth;
            else { treasuryEth += creatorEth; creatorEth = 0; }
        }
        if (treasuryEth > 0) { (bool okT, ) = treasury.call{ value: treasuryEth }(""); require(okT, "treasury eth"); }
        if (holdersEth > 0) { (bool okH, ) = distributor.call{ value: holdersEth }(""); require(okH, "holders eth"); holdersEarned += holdersEth; }

        if (creatorTok > 0 && !IERC20(tk).transfer(creator, creatorTok)) { treasuryTok += creatorTok; creatorTok = 0; }
        if (treasuryTok > 0) require(IERC20(tk).transfer(treasury, treasuryTok), "tok treasury");
        if (holdersTok > 0) require(IERC20(tk).transfer(distributor, holdersTok), "tok holders");

        emit FeesCollected(creatorEth, treasuryEth, holdersEth, holdersTok);
    }

    receive() external payable {}
}

// ------------------------------------------------------------
// The factory: one call = token + pool + locked position +
// rewards distributor wired to the creator's chosen reward token.
// ------------------------------------------------------------
contract ArchitectLaunchFactoryHR {
    address public immutable treasury;
    address public immutable weth;
    address public immutable npmUni;
    address public immutable v3factoryUni;
    address public immutable keeper; // NLYRA ops — executes convert/distribute on every distributor
    uint160 public immutable sqrtWeth0;
    uint160 public immutable sqrtWeth1;
    int24 public immutable tickEdgeWeth0;
    int24 public immutable tickEdgeWeth1;

    struct Launch {
        address token;
        address vault;
        address distributor;
        address rewardToken;
        address creator;
        string name;
        string symbol;
        string image;
        string description;
        string telegram;
        string xLink;
        uint256 createdAt;
    }

    Launch[] public launches;
    mapping(address => uint256) public indexOfToken; // token => index+1

    event LaunchCreated(
        address indexed token, address indexed vault, address indexed creator,
        address pool, address distributor, address rewardToken, string name, string symbol
    );

    constructor(
        address _treasury, address _weth, address _npmUni, address _v3factoryUni, address _keeper,
        uint160 _sqrtWeth0, uint160 _sqrtWeth1, int24 _tickEdgeWeth0, int24 _tickEdgeWeth1
    ) {
        treasury = _treasury;
        weth = _weth;
        npmUni = _npmUni;
        v3factoryUni = _v3factoryUni;
        keeper = _keeper;
        sqrtWeth0 = _sqrtWeth0;
        sqrtWeth1 = _sqrtWeth1;
        tickEdgeWeth0 = _tickEdgeWeth0;
        tickEdgeWeth1 = _tickEdgeWeth1;
    }

    function create(
        string calldata name,
        string calldata symbol,
        string calldata image,
        string calldata description,
        string calldata telegram,
        string calldata xLink,
        address rewardToken
    ) external payable returns (address tokenAddr, address vaultAddr) {
        require(bytes(name).length > 0 && bytes(name).length <= 40, "name");
        require(bytes(symbol).length > 0 && bytes(symbol).length <= 12, "symbol");
        require(bytes(telegram).length <= 100 && bytes(xLink).length <= 100, "links");
        require(rewardToken != address(0), "reward token");
        // the reward must be payable: WETH itself, or something with a WETH pool
        require(
            rewardToken == weth || IV3Factory(v3factoryUni).getPool(weth, rewardToken, 10000) != address(0),
            "reward token has no WETH pool"
        );

        RewardsDistributor dist = new RewardsDistributor(weth, v3factoryUni, rewardToken, keeper);
        ArchitectRewardsVault vault = new ArchitectRewardsVault(
            treasury, weth, npmUni, msg.sender, address(dist),
            sqrtWeth0, sqrtWeth1, tickEdgeWeth0, tickEdgeWeth1
        );
        dist.init(address(vault));
        ArchitectTokenHR token = new ArchitectTokenHR(name, symbol, address(vault));
        vault.init{ value: msg.value }(address(token));

        launches.push(Launch(address(token), address(vault), address(dist), rewardToken, msg.sender, name, symbol, image, description, telegram, xLink, block.timestamp));
        indexOfToken[address(token)] = launches.length;

        emit LaunchCreated(address(token), address(vault), msg.sender, vault.pool(), address(dist), rewardToken, name, symbol);
        return (address(token), address(vault));
    }

    function launchCount() external view returns (uint256) {
        return launches.length;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ============================================================
// ARCHITECT LAUNCH v2 — born IN the pool (Robinhood Chain)
// by NERON & LYRA · nlyra.xyz
//
// "Every token born here is born safe — and visible."
//
// v1 used a bonding curve: mathematically perfect, but invisible to
// DexScreener until graduation. v2 keeps the SAME curve math with a
// different wrapper: the entire supply is minted as a single-sided
// concentrated V3 position (a V3 range IS a constant-product curve),
// so every token is born inside a REAL pool — indexed by DexScreener
// and tradeable from any aggregator from block one. No graduation,
// no migration, EVER: the pool it's born in is the pool it lives in.
//
// - The creator picks the venue at birth: Architect Swap V3 (creator
//   keeps 90% of pool fees) or Uniswap V3 (80%). Immutable.
// - The position NFT is owned by the launch VAULT forever — there is
//   no function to move, decrease or burn it. Rugs are impossible.
// - Pool fee tier: 1%. All of it accrues to the locked position and
//   collectFees() splits it creator/treasury at the immutable ratio.
//   Anyone can trigger the split; the money always goes to fixed
//   destinations. Treasury = the NLYRA BuybackBurner.
// - Optional dev first buy INSIDE create(), hard-capped at 5% of
//   supply (Pons rule) — atomic, nobody can front-run the creator.
// - Floor price: fixed protocol constant (~0.5 ETH starting mcap),
//   encoded as sqrtPriceX96 constants for both token orderings.
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
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96, address, address token0, address token1, uint24, int24, int24, uint128,
            uint256, uint256, uint128, uint128
        );
}

interface IV3Pool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
}

interface ISwapRouterV3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

// ------------------------------------------------------------
// The token template: minimal, immutable, no owner, no surprises.
// ------------------------------------------------------------
contract ArchitectToken is IERC20 {
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
        balanceOf[vault] = totalSupply; // 100% to the vault → straight into the locked pool position
        emit Transfer(address(0), vault, totalSupply);
    }

    function transfer(address to, uint256 value) external override returns (bool) {
        return _transfer(msg.sender, to, value);
    }

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
// The vault: owns the locked position for life, splits the fees.
// One instance per launch. No withdraw. No owner. No exceptions.
// ------------------------------------------------------------
contract ArchitectPoolVault {
    uint256 public constant SUPPLY = 1_000_000_000e18;
    uint256 public constant MAX_BUY = 50_000_000e18; // 5% — cap on the creator's atomic first buy
    uint24 public constant POOL_FEE = 10000;         // 1% tier
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    int24 internal constant TICK_MIN = -887200;      // full range bound, spacing 200
    int24 internal constant TICK_MAX = 887200;

    address public immutable factory;
    address public immutable treasury;   // the NLYRA BuybackBurner
    address public immutable weth;
    address public immutable npm;        // position manager of the chosen venue
    address public immutable swapRouter; // our classic V3 router (fee auto-sell); zero on Uniswap venue
    address public immutable creator;
    uint16 public immutable creatorFeeBps; // 90 (our venue) / 80 (Uniswap), over 100
    uint8 public immutable venue;          // 1 = Architect Swap V3, 2 = Uniswap V3

    IERC20 public token;
    address public pool;
    uint256 public positionId;   // the locked position — owned by THIS contract forever
    uint256 public creatorEarned;

    // floor-price constants for both token orderings (computed off-chain once)
    uint160 internal immutable sqrtWeth0; // init price when WETH is token0
    uint160 internal immutable sqrtWeth1; // init price when WETH is token1
    int24 internal immutable tickEdgeWeth0; // tickUpper of the range when WETH is token0
    int24 internal immutable tickEdgeWeth1; // tickLower of the range when WETH is token1

    uint256 private unlocked = 1;
    modifier lock() { require(unlocked == 1, "reentrancy"); unlocked = 0; _; unlocked = 1; }

    event BornInPool(address indexed token, address pool, uint256 positionId, uint8 venue);
    event DevFirstBuy(address indexed creator, uint256 ethIn, uint256 tokensOut);
    event FeesCollected(uint256 ethToCreator, uint256 ethToTreasury, uint256 tokensToCreator, uint256 tokensToTreasury);

    constructor(
        address _treasury,
        address _weth,
        address _npm,
        address _swapRouter,
        address _creator,
        uint8 _venue,
        uint160 _sqrtWeth0,
        uint160 _sqrtWeth1,
        int24 _tickEdgeWeth0,
        int24 _tickEdgeWeth1
    ) {
        require(_venue == 1 || _venue == 2, "venue");
        factory = msg.sender;
        treasury = _treasury;
        weth = _weth;
        npm = _npm;
        swapRouter = _venue == 1 ? _swapRouter : address(0);
        creator = _creator;
        venue = _venue;
        creatorFeeBps = _venue == 2 ? 80 : 90;
        sqrtWeth0 = _sqrtWeth0;
        sqrtWeth1 = _sqrtWeth1;
        tickEdgeWeth0 = _tickEdgeWeth0;
        tickEdgeWeth1 = _tickEdgeWeth1;
    }

    // Called once by the factory right after the token is deployed:
    // creates the pool at the floor price, locks the entire supply as a
    // single-sided position, and (optionally) executes the creator's
    // capped first buy — all in the create() transaction.
    function init(address _token) external payable lock {
        require(msg.sender == factory && address(token) == address(0), "init");
        token = IERC20(_token);

        bool weth0 = weth < _token;
        (address t0, address t1) = weth0 ? (weth, _token) : (_token, weth);
        // the token side sits in a range next to the current price; buys walk
        // the price through the range — identical math to a bonding curve.
        (int24 lo, int24 hi) = weth0 ? (TICK_MIN, tickEdgeWeth0) : (tickEdgeWeth1, TICK_MAX);

        pool = INonfungiblePositionManager(npm).createAndInitializePoolIfNecessary(
            t0, t1, POOL_FEE, weth0 ? sqrtWeth0 : sqrtWeth1
        );
        // if the pool pre-existed at another price, minting single-sided would
        // revert or skew — demand the floor price for a virgin launch.
        (uint160 cur,,,,,,) = IV3Pool(pool).slot0();
        require(cur == (weth0 ? sqrtWeth0 : sqrtWeth1), "pool price hostile");

        require(token.approve(npm, SUPPLY), "approve");
        (uint256 id,, uint256 a0, uint256 a1) = INonfungiblePositionManager(npm).mint(
            INonfungiblePositionManager.MintParams({
                token0: t0,
                token1: t1,
                fee: POOL_FEE,
                tickLower: lo,
                tickUpper: hi,
                amount0Desired: weth0 ? 0 : SUPPLY,
                amount1Desired: weth0 ? SUPPLY : 0,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this), // the vault owns the NFT forever
                deadline: block.timestamp + 600
            })
        );
        positionId = id;
        uint256 used = weth0 ? a1 : a0;
        if (SUPPLY > used) require(token.transfer(DEAD, SUPPLY - used), "dust burn"); // rounding dust only

        emit BornInPool(_token, pool, id, venue);

        // ── optional atomic dev first buy, hard-capped at 5% ──
        if (msg.value > 0) {
            (int256 d0, int256 d1) = IV3Pool(pool).swap(
                creator,
                weth0, // paying WETH: token0 in → price down (weth0) / token1 in → price up
                int256(msg.value),
                weth0 ? 4295128740 : 1461446703485210103287273052203988822378723970341, // MIN_SQRT+1 / MAX_SQRT-1
                ""
            );
            uint256 got = uint256(-(weth0 ? d1 : d0));
            require(got <= MAX_BUY, "max buy 5%");
            emit DevFirstBuy(creator, msg.value, got);
        }
    }

    // pool calls back during the dev first buy: wrap and pay the ETH owed
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == pool, "callback");
        uint256 owed = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        IWETH9(weth).deposit{ value: owed }();
        require(IWETH9(weth).transfer(pool, owed), "pay pool");
    }

    // ── THE ETERNAL FEES ──────────────────────────────────────────
    // 1% of every pool trade accrues to the locked position, forever.
    // - minEthForTokens == 0: in-kind split (WETH side as ETH + tokens).
    //   Anyone can call — funds only ever go to fixed destinations.
    // - minEthForTokens > 0: auto-sells the token side to ETH in this
    //   same pool and delivers EVERYTHING in ETH. Creator/treasury only
    //   (the minOut protects them from sandwiches).
    function collectFees(uint256 minEthForTokens) external lock returns (uint256 creatorEth, uint256 treasuryEth) {
        require(positionId != 0, "no position");
        if (minEthForTokens > 0) require(msg.sender == creator || msg.sender == treasury, "auth");

        (,, address t0, address t1,,,,,,,,) = INonfungiblePositionManager(npm).positions(positionId);
        INonfungiblePositionManager(npm).collect(
            INonfungiblePositionManager.CollectParams(positionId, address(this), type(uint128).max, type(uint128).max)
        );

        address tk = t0 == weth ? t1 : t0;
        uint256 tokenBal = IERC20(tk).balanceOf(address(this));

        if (minEthForTokens > 0 && tokenBal > 0 && swapRouter != address(0)) {
            require(IERC20(tk).approve(swapRouter, tokenBal), "approve");
            ISwapRouterV3(swapRouter).exactInputSingle(
                ISwapRouterV3.ExactInputSingleParams(tk, weth, POOL_FEE, address(this), block.timestamp, tokenBal, minEthForTokens, 0)
            );
            tokenBal = 0;
        }

        uint256 wBal = IWETH9(weth).balanceOf(address(this));
        if (wBal > 0) IWETH9(weth).withdraw(wBal);
        uint256 ethBal = address(this).balance;
        require(ethBal > 0 || tokenBal > 0, "nothing to collect");

        creatorEth = (ethBal * creatorFeeBps) / 100;
        treasuryEth = ethBal - creatorEth;
        uint256 creatorTok = (tokenBal * creatorFeeBps) / 100;
        uint256 treasuryTok = tokenBal - creatorTok;

        if (creatorEth > 0) {
            (bool ok, ) = creator.call{ value: creatorEth }("");
            if (ok) creatorEarned += creatorEth;
            else { treasuryEth += creatorEth; creatorEth = 0; }
        }
        if (treasuryEth > 0) { (bool ok2, ) = treasury.call{ value: treasuryEth }(""); require(ok2, "treasury eth"); }
        if (creatorTok > 0 && !IERC20(tk).transfer(creator, creatorTok)) { treasuryTok += creatorTok; creatorTok = 0; }
        if (treasuryTok > 0) require(IERC20(tk).transfer(treasury, treasuryTok), "tok transfer");

        emit FeesCollected(creatorEth, treasuryEth, creatorTok, treasuryTok);
    }

    receive() external payable {} // WETH.withdraw refunds here
}

// ------------------------------------------------------------
// The factory: one call = token + pool + locked position (+ dev buy).
// ------------------------------------------------------------
contract ArchitectLaunchFactoryV2 {
    address public immutable treasury;       // the NLYRA BuybackBurner
    address public immutable weth;
    address public immutable npmOurs;        // Architect Swap V3
    address public immutable npmUni;         // Uniswap V3
    address public immutable swapRouterOurs;
    uint160 public immutable sqrtWeth0;
    uint160 public immutable sqrtWeth1;
    int24 public immutable tickEdgeWeth0;
    int24 public immutable tickEdgeWeth1;

    struct Launch {
        address token;
        address vault;
        address creator;
        string name;
        string symbol;
        string image;
        string description;
        string telegram;
        string xLink;
        uint256 createdAt;
        uint8 venue;
    }

    Launch[] public launches;
    mapping(address => uint256) public indexOfToken; // token => index+1

    event LaunchCreated(
        address indexed token,
        address indexed vault,
        address indexed creator,
        address pool,
        string name,
        string symbol,
        uint8 venue
    );

    constructor(
        address _treasury,
        address _weth,
        address _npmOurs,
        address _npmUni,
        address _swapRouterOurs,
        uint160 _sqrtWeth0,
        uint160 _sqrtWeth1,
        int24 _tickEdgeWeth0,
        int24 _tickEdgeWeth1
    ) {
        treasury = _treasury;
        weth = _weth;
        npmOurs = _npmOurs;
        npmUni = _npmUni;
        swapRouterOurs = _swapRouterOurs;
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
        uint8 venue
    ) external payable returns (address tokenAddr, address vaultAddr) {
        require(bytes(name).length > 0 && bytes(name).length <= 40, "name");
        require(bytes(symbol).length > 0 && bytes(symbol).length <= 12, "symbol");
        require(bytes(telegram).length <= 100 && bytes(xLink).length <= 100, "links");
        require(venue == 1 || venue == 2, "venue");

        ArchitectPoolVault vault = new ArchitectPoolVault(
            treasury, weth, venue == 1 ? npmOurs : npmUni, swapRouterOurs, msg.sender, venue,
            sqrtWeth0, sqrtWeth1, tickEdgeWeth0, tickEdgeWeth1
        );
        ArchitectToken token = new ArchitectToken(name, symbol, address(vault));
        vault.init{ value: msg.value }(address(token)); // dev's optional capped first buy rides along

        launches.push(Launch(address(token), address(vault), msg.sender, name, symbol, image, description, telegram, xLink, block.timestamp, venue));
        indexOfToken[address(token)] = launches.length;

        emit LaunchCreated(address(token), address(vault), msg.sender, vault.pool(), name, symbol, venue);
        return (address(token), address(vault));
    }

    function launchCount() external view returns (uint256) {
        return launches.length;
    }
}

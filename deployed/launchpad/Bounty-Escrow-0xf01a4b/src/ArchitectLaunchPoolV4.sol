// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ============================================================
// ARCHITECT LAUNCH v4 — born IN the pool, in ANY approved pair
// by NERON & LYRA · nlyra.xyz
//
// Everything v2 promised, plus two powers:
//
// 1) createFor(feeWallet, …): whoever SIGNS the launch is no longer
//    forced to be whoever EARNS the fees. This unlocks LAUNCH FREE —
//    the protocol's relayer pays the gas and launches on behalf of a
//    creator who chooses any wallet (cold storage, community multisig)
//    to receive their fees, forever. It also lets wallet-connected
//    creators route fees away from their hot wallet.
//
// 2) Approved pairs beyond WETH: tokens can be born against USDG
//    (Robinhood Chain's native stablecoin) or approved tokenized
//    stocks. The pair is fixed at birth, the pool it's born in is the
//    pool it lives in, and creator fees are paid IN that pair asset.
//    The pair list is additive-only: ops can add or disable pairs for
//    FUTURE launches, but can never touch an existing pool, position
//    or fee split. Immutability where it matters.
//
// Everything else is untouched v2 law: entire supply locked for life
// as a single-sided V3 position owned by an ownerless vault, no
// graduation, no migration, dev first buy capped at 5% atomically,
// fees split creator/treasury at an immutable 90/10 (our venue) or
// 80/20 (Uniswap), treasury = the NLYRA BuybackBurner (non-WETH fee
// assets arrive there and sweepToken() moves them to ops — split in
// stone either way).
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
// The token template: byte-identical to v2. One template, forever.
// ------------------------------------------------------------
contract ArchitectTokenV4 is IERC20 {
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
// The vault: owns the locked position for life, splits the fees
// in the pair asset. One instance per launch. No withdraw. No owner.
// ------------------------------------------------------------
contract ArchitectPoolVaultV4 {
    uint256 public constant SUPPLY = 1_000_000_000e18;
    uint256 public constant MAX_BUY = 50_000_000e18; // 5% — cap on the creator's atomic first buy
    uint24 public constant POOL_FEE = 10000;         // 1% tier
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    int24 internal constant TICK_MIN = -887200;      // full range bound, spacing 200
    int24 internal constant TICK_MAX = 887200;

    address public immutable factory;
    address public immutable treasury;   // the NLYRA BuybackBurner
    address public immutable quote;      // the pair asset: WETH, USDG or an approved tokenized stock
    bool public immutable quoteIsWeth;   // native path: wrap/unwrap ETH; token path: plain ERC20
    address public immutable npm;        // position manager of the chosen venue
    address public immutable swapRouter; // our classic V3 router (fee auto-sell); zero on Uniswap venue
    address public immutable creator;    // the FEE WALLET — chosen at birth, immutable forever
    uint16 public immutable creatorFeeBps; // 90 (our venue) / 80 (Uniswap), over 100
    uint8 public immutable venue;          // 1 = Architect Swap V3, 2 = Uniswap V3

    IERC20 public token;
    address public pool;
    uint256 public positionId;   // the locked position — owned by THIS contract forever
    uint256 public creatorEarned; // lifetime creator payout, in the quote asset's smallest unit

    // floor-price constants for both token orderings (computed off-chain per pair)
    uint160 internal immutable sqrtQuote0; // init price when quote is token0
    uint160 internal immutable sqrtQuote1; // init price when quote is token1
    int24 internal immutable tickEdgeQuote0; // tickUpper of the range when quote is token0
    int24 internal immutable tickEdgeQuote1; // tickLower of the range when quote is token1

    uint256 private unlocked = 1;
    modifier lock() { require(unlocked == 1, "reentrancy"); unlocked = 0; _; unlocked = 1; }

    event BornInPool(address indexed token, address pool, uint256 positionId, uint8 venue, address quote);
    event DevFirstBuy(address indexed creator, uint256 quoteIn, uint256 tokensOut);
    event FeesCollected(uint256 quoteToCreator, uint256 quoteToTreasury, uint256 tokensToCreator, uint256 tokensToTreasury);

    constructor(
        address _treasury,
        address _quote,
        bool _quoteIsWeth,
        address _npm,
        address _swapRouter,
        address _creator,
        uint8 _venue,
        uint160 _sqrtQuote0,
        uint160 _sqrtQuote1,
        int24 _tickEdgeQuote0,
        int24 _tickEdgeQuote1
    ) {
        require(_venue == 1 || _venue == 2, "venue");
        require(_creator != address(0), "creator");
        factory = msg.sender;
        treasury = _treasury;
        quote = _quote;
        quoteIsWeth = _quoteIsWeth;
        npm = _npm;
        swapRouter = _venue == 1 ? _swapRouter : address(0);
        creator = _creator;
        venue = _venue;
        creatorFeeBps = _venue == 2 ? 80 : 90;
        sqrtQuote0 = _sqrtQuote0;
        sqrtQuote1 = _sqrtQuote1;
        tickEdgeQuote0 = _tickEdgeQuote0;
        tickEdgeQuote1 = _tickEdgeQuote1;
    }

    // Called once by the factory right after the token is deployed:
    // creates the pool at the floor price, locks the entire supply as a
    // single-sided position, and (optionally) executes the creator's
    // capped first buy — all in the create transaction.
    // WETH pair: the first buy rides in as msg.value.
    // Token pair: the factory pre-funds this vault with `devBuyQuote`
    // of the quote asset before calling (msg.value must be zero).
    function init(address _token, uint256 devBuyQuote) external payable lock {
        require(msg.sender == factory && address(token) == address(0), "init");
        if (!quoteIsWeth) require(msg.value == 0, "eth on token pair");
        token = IERC20(_token);

        bool quote0 = quote < _token;
        (address t0, address t1) = quote0 ? (quote, _token) : (_token, quote);
        // the token side sits in a range next to the current price; buys walk
        // the price through the range — identical math to a bonding curve.
        (int24 lo, int24 hi) = quote0 ? (TICK_MIN, tickEdgeQuote0) : (tickEdgeQuote1, TICK_MAX);

        pool = INonfungiblePositionManager(npm).createAndInitializePoolIfNecessary(
            t0, t1, POOL_FEE, quote0 ? sqrtQuote0 : sqrtQuote1
        );
        // if the pool pre-existed at another price, minting single-sided would
        // revert or skew — demand the floor price for a virgin launch.
        (uint160 cur,,,,,,) = IV3Pool(pool).slot0();
        require(cur == (quote0 ? sqrtQuote0 : sqrtQuote1), "pool price hostile");

        require(token.approve(npm, SUPPLY), "approve");
        (uint256 id,, uint256 a0, uint256 a1) = INonfungiblePositionManager(npm).mint(
            INonfungiblePositionManager.MintParams({
                token0: t0,
                token1: t1,
                fee: POOL_FEE,
                tickLower: lo,
                tickUpper: hi,
                amount0Desired: quote0 ? 0 : SUPPLY,
                amount1Desired: quote0 ? SUPPLY : 0,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this), // the vault owns the NFT forever
                deadline: block.timestamp + 600
            })
        );
        positionId = id;
        uint256 used = quote0 ? a1 : a0;
        if (SUPPLY > used) require(token.transfer(DEAD, SUPPLY - used), "dust burn"); // rounding dust only

        emit BornInPool(_token, pool, id, venue, quote);

        // ── optional atomic dev first buy, hard-capped at 5% ──
        uint256 payIn = quoteIsWeth ? msg.value : devBuyQuote;
        if (payIn > 0) {
            (int256 d0, int256 d1) = IV3Pool(pool).swap(
                creator,
                quote0, // paying quote: token0 in → price down (quote0) / token1 in → price up
                int256(payIn),
                quote0 ? 4295128740 : 1461446703485210103287273052203988822378723970341, // MIN_SQRT+1 / MAX_SQRT-1
                ""
            );
            uint256 got = uint256(-(quote0 ? d1 : d0));
            require(got <= MAX_BUY, "max buy 5%");
            emit DevFirstBuy(creator, payIn, got);
        }
    }

    // pool calls back during the dev first buy: pay the quote owed.
    // WETH pair wraps the ETH held from msg.value; token pairs pay from
    // the quote balance the factory pre-funded.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == pool, "callback");
        uint256 owed = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        if (quoteIsWeth) {
            IWETH9(quote).deposit{ value: owed }();
            require(IWETH9(quote).transfer(pool, owed), "pay pool");
        } else {
            require(IERC20(quote).transfer(pool, owed), "pay pool");
        }
    }

    // ── THE ETERNAL FEES ──────────────────────────────────────────
    // 1% of every pool trade accrues to the locked position, forever.
    // Paid out in the QUOTE asset (ETH for WETH pairs, USDG for USDG
    // pairs — "get your fees in dollars").
    // - minQuoteForTokens == 0: in-kind split (quote side + token side).
    //   Anyone can call — funds only ever go to fixed destinations.
    // - minQuoteForTokens > 0: auto-sells the token side to quote in
    //   this same pool and delivers EVERYTHING in the quote asset.
    //   Creator/treasury only (the minOut protects them from sandwiches).
    function collectFees(uint256 minQuoteForTokens) external lock returns (uint256 creatorQuote, uint256 treasuryQuote) {
        require(positionId != 0, "no position");
        if (minQuoteForTokens > 0) require(msg.sender == creator || msg.sender == treasury, "auth");

        (,, address t0, address t1,,,,,,,,) = INonfungiblePositionManager(npm).positions(positionId);
        INonfungiblePositionManager(npm).collect(
            INonfungiblePositionManager.CollectParams(positionId, address(this), type(uint128).max, type(uint128).max)
        );

        address tk = t0 == quote ? t1 : t0;
        uint256 tokenBal = IERC20(tk).balanceOf(address(this));

        if (minQuoteForTokens > 0 && tokenBal > 0 && swapRouter != address(0)) {
            require(IERC20(tk).approve(swapRouter, tokenBal), "approve");
            ISwapRouterV3(swapRouter).exactInputSingle(
                ISwapRouterV3.ExactInputSingleParams(tk, quote, POOL_FEE, address(this), block.timestamp, tokenBal, minQuoteForTokens, 0)
            );
            tokenBal = 0;
        }

        uint256 qBal;
        if (quoteIsWeth) {
            uint256 wBal = IWETH9(quote).balanceOf(address(this));
            if (wBal > 0) IWETH9(quote).withdraw(wBal);
            qBal = address(this).balance;
        } else {
            qBal = IERC20(quote).balanceOf(address(this));
        }
        require(qBal > 0 || tokenBal > 0, "nothing to collect");

        creatorQuote = (qBal * creatorFeeBps) / 100;
        treasuryQuote = qBal - creatorQuote;
        uint256 creatorTok = (tokenBal * creatorFeeBps) / 100;
        uint256 treasuryTok = tokenBal - creatorTok;

        if (quoteIsWeth) {
            if (creatorQuote > 0) {
                (bool ok, ) = creator.call{ value: creatorQuote }("");
                if (ok) creatorEarned += creatorQuote;
                else { treasuryQuote += creatorQuote; creatorQuote = 0; }
            }
            if (treasuryQuote > 0) { (bool ok2, ) = treasury.call{ value: treasuryQuote }(""); require(ok2, "treasury eth"); }
        } else {
            if (creatorQuote > 0) {
                if (IERC20(quote).transfer(creator, creatorQuote)) creatorEarned += creatorQuote;
                else { treasuryQuote += creatorQuote; creatorQuote = 0; }
            }
            if (treasuryQuote > 0) require(IERC20(quote).transfer(treasury, treasuryQuote), "treasury quote");
        }
        if (creatorTok > 0 && !IERC20(tk).transfer(creator, creatorTok)) { treasuryTok += creatorTok; creatorTok = 0; }
        if (treasuryTok > 0) require(IERC20(tk).transfer(treasury, treasuryTok), "tok transfer");

        emit FeesCollected(creatorQuote, treasuryQuote, creatorTok, treasuryTok);
    }

    receive() external payable {} // WETH.withdraw refunds here
}

// ------------------------------------------------------------
// The factory: one call = token + pool + locked position (+ dev buy).
// v4 adds the fee-wallet parameter and the approved-pair registry.
// ------------------------------------------------------------
contract ArchitectLaunchFactoryV4 {
    // custom errors: same protections as v2's require strings, ~600 bytes
    // lighter — the factory sits right at the EIP-170 size limit.
    error BadInput();
    error PairErr();
    error OpsOnly();
    error PullFail();

    address public immutable treasury;       // the NLYRA BuybackBurner
    address public immutable weth;
    address public immutable npmOurs;        // Architect Swap V3
    address public immutable npmUni;         // Uniswap V3
    address public immutable swapRouterOurs;
    address public immutable ops;            // may ADD pairs / disable for future launches. Nothing else.

    struct PairCfg {
        address quote;          // WETH, USDG, tokenized stock…
        uint160 sqrtQuote0;     // floor price when quote is token0
        uint160 sqrtQuote1;     // floor price when quote is token1
        int24 tickEdgeQuote0;
        int24 tickEdgeQuote1;
        bool enabled;           // gates FUTURE launches only
    }

    PairCfg[] public pairs;     // pair 0 = WETH, seeded at deploy

    struct Launch {
        address token;
        address vault;
        address creator;        // the fee wallet
        string name;
        string symbol;
        string image;
        string description;
        string telegram;
        string xLink;
        uint256 createdAt;
        uint8 venue;
        address quote;          // the pair asset this launch was born against
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
        uint8 venue,
        address quote
    );
    event PairAdded(uint256 indexed pairId, address quote);
    event PairEnabled(uint256 indexed pairId, bool enabled);

    modifier onlyOps() { if (msg.sender != ops) revert OpsOnly(); _; }

    constructor(
        address _treasury,
        address _weth,
        address _npmOurs,
        address _npmUni,
        address _swapRouterOurs,
        address _ops,
        uint160 _sqrtWeth0,
        uint160 _sqrtWeth1,
        int24 _tickEdgeWeth0,
        int24 _tickEdgeWeth1
    ) {
        if (_ops == address(0)) revert OpsOnly();
        treasury = _treasury;
        weth = _weth;
        npmOurs = _npmOurs;
        npmUni = _npmUni;
        swapRouterOurs = _swapRouterOurs;
        ops = _ops;
        pairs.push(PairCfg(_weth, _sqrtWeth0, _sqrtWeth1, _tickEdgeWeth0, _tickEdgeWeth1, true));
        emit PairAdded(0, _weth);
    }

    // Additive-only registry: a new pair can be born, an existing pair can
    // be closed to FUTURE launches. Live pools and vaults are untouchable —
    // there is no code path from here to them.
    function addPair(
        address quote_,
        uint160 sqrtQuote0,
        uint160 sqrtQuote1,
        int24 tickEdgeQuote0,
        int24 tickEdgeQuote1
    ) external onlyOps returns (uint256 pairId) {
        if (quote_ == address(0)) revert PairErr();
        for (uint256 i = 0; i < pairs.length; i++) if (pairs[i].quote == quote_) revert PairErr();
        pairs.push(PairCfg(quote_, sqrtQuote0, sqrtQuote1, tickEdgeQuote0, tickEdgeQuote1, true));
        pairId = pairs.length - 1;
        emit PairAdded(pairId, quote_);
    }

    function setPairEnabled(uint256 pairId, bool enabled) external onlyOps {
        pairs[pairId].enabled = enabled;
        emit PairEnabled(pairId, enabled);
    }

    function pairCount() external view returns (uint256) { return pairs.length; }

    // v2-compatible entry: launch for yourself, against WETH.
    // The existing frontend keeps working unchanged.
    function create(
        string calldata name,
        string calldata symbol,
        string calldata image,
        string calldata description,
        string calldata telegram,
        string calldata xLink,
        uint8 venue
    ) external payable returns (address tokenAddr, address vaultAddr) {
        return _create(msg.sender, name, symbol, image, description, telegram, xLink, venue, 0, 0);
    }

    // v4 entry: launch on behalf of a fee wallet, against any approved pair.
    // - LAUNCH FREE: the relayer signs and pays gas; `creator` is the
    //   user's chosen fee wallet; no first buy (devBuyQuote = 0).
    // - Wallet flow with a non-WETH pair: approve the factory for
    //   devBuyQuote of the quote asset first; it is pulled and swapped
    //   atomically inside this call, capped at 5% of supply.
    function createFor(
        address creator,
        string calldata name,
        string calldata symbol,
        string calldata image,
        string calldata description,
        string calldata telegram,
        string calldata xLink,
        uint8 venue,
        uint256 pairId,
        uint256 devBuyQuote
    ) external payable returns (address tokenAddr, address vaultAddr) {
        return _create(creator, name, symbol, image, description, telegram, xLink, venue, pairId, devBuyQuote);
    }

    function _create(
        address creator,
        string calldata name,
        string calldata symbol,
        string calldata image,
        string calldata description,
        string calldata telegram,
        string calldata xLink,
        uint8 venue,
        uint256 pairId,
        uint256 devBuyQuote
    ) internal returns (address tokenAddr, address vaultAddr) {
        if (bytes(name).length == 0 || bytes(name).length > 40) revert BadInput();
        if (bytes(symbol).length == 0 || bytes(symbol).length > 12) revert BadInput();
        if (bytes(telegram).length > 100 || bytes(xLink).length > 100) revert BadInput();
        if (venue != 1 && venue != 2) revert BadInput();
        if (pairId >= pairs.length) revert PairErr();
        PairCfg memory pc = pairs[pairId];
        if (!pc.enabled) revert PairErr();
        bool isWeth = pc.quote == weth;
        if (!isWeth && msg.value != 0) revert BadInput();

        ArchitectPoolVaultV4 vault = new ArchitectPoolVaultV4(
            treasury, pc.quote, isWeth, venue == 1 ? npmOurs : npmUni, swapRouterOurs, creator, venue,
            pc.sqrtQuote0, pc.sqrtQuote1, pc.tickEdgeQuote0, pc.tickEdgeQuote1
        );
        ArchitectTokenV4 token = new ArchitectTokenV4(name, symbol, address(vault));

        // token-pair first buy: pull the quote into the vault so the swap
        // callback can pay the pool — atomic, capped at 5% inside init.
        if (!isWeth && devBuyQuote > 0) {
            if (!IERC20(pc.quote).transferFrom(msg.sender, address(vault), devBuyQuote)) revert PullFail();
        }
        vault.init{ value: msg.value }(address(token), devBuyQuote);

        launches.push(Launch(
            address(token), address(vault), creator, name, symbol, image, description,
            telegram, xLink, block.timestamp, venue, pc.quote
        ));
        indexOfToken[address(token)] = launches.length;

        emit LaunchCreated(address(token), address(vault), creator, vault.pool(), name, symbol, venue, pc.quote);
        return (address(token), address(vault));
    }

    function launchCount() external view returns (uint256) {
        return launches.length;
    }
}

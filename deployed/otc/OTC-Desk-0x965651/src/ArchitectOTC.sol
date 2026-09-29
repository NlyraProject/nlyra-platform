// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*  ArchitectOTC - peer-to-peer block trades on Robinhood Chain, settled atomically
    ---------------------------------------------------------------------------
    A seller escrows a token here and names a price in ETH, USDG or NLYRA.
    A buyer pays, and in the same transaction the tokens leave the escrow and
    the payment reaches the seller. No pool is touched, so there is no price
    impact and no slippage: the price is the one the seller wrote.

    Every completed fill pays a small fee (feeBps of the payment, capped at 1%)
    that goes to the NLYRA buyback burner:
      - paid in ETH   -> forwarded to the burner in the same transaction
      - paid in NLYRA -> sent straight to 0x...dEaD
      - paid in USDG  -> held here and swapped to ETH for the burner by the
                         flusher (a bounded, non-custodial job: it can only move
                         accrued fees, never escrow)

    Non-custodial: escrowed tokens can only go to the buyer (fill) or back to
    the seller (cancel / expiry). There is no admin withdraw of escrow and no
    upgrade path. The owner can set the fee (<= 1%), the allowed quote assets,
    the flusher, and pause new offers/fills (cancel always works).
*/

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IWETH {
    function withdraw(uint256) external;
}

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

contract ArchitectOTC {
    uint256 internal constant BPS = 10_000;
    uint16  public  constant MAX_FEE_BPS = 100;          // 1% hard cap
    uint64  public  constant MAX_TTL = 365 days;
    address public  constant DEAD = 0x000000000000000000000000000000000000dEaD;

    enum Status { Open, Filled, Cancelled }

    struct Offer {
        address seller;
        address token;     // what is sold
        address quote;     // what is paid: address(0) = ETH, else an allowed ERC-20 (USDG, NLYRA)
        address taker;     // address(0) = anyone may fill
        uint128 amount;    // token still for sale (raw units)
        uint128 want;      // quote still to be paid for `amount` (raw units); price = want / amount
        uint128 amount0;   // original amount (for display)
        uint128 want0;     // original want (for display)
        uint128 minFill;   // smallest partial payment accepted (raw quote units); 0 = any
        uint64  expiry;
        uint8   status;    // Status
    }

    address public immutable WETH;
    address public immutable NLYRA;
    address payable public immutable BURNER;   // BuybackBurner: receive() takes ETH, burn() buys NLYRA to 0xdEaD
    ISwapRouter02 public immutable ROUTER;     // official Uniswap V3 SwapRouter02 (fee flush only)

    address public owner;
    address public pendingOwner;
    address public flusher;
    uint16  public feeBps;
    bool    public paused;

    uint256 public count;
    mapping(uint256 => Offer)   public offers;
    mapping(address => bool)    public isQuote;       // allowed ERC-20 quote assets
    mapping(address => uint256) public escrowed;      // token => sum of open offers' amount (users' money)
    mapping(address => uint256) public accruedFee;    // quote => fee held here awaiting flush (address(0) = ETH that bounced off the burner)
    mapping(address => uint256) public pendingEth;    // ETH payouts that bounced, claimable by the payee
    uint256 public totalPendingEth;
    mapping(address => uint256) public totalFee;      // quote => lifetime fee taken
    mapping(address => uint256) public totalVolume;   // quote => lifetime quote paid through fills
    uint256 public totalNlyraBurned;                  // NLYRA-quoted fees sent to 0xdEaD
    uint256 public totalEthToBurner;                  // ETH forwarded to the burner (fills + flushes)

    event OfferCreated(uint256 indexed id, address indexed seller, address indexed token, address quote, uint256 amount, uint256 want, uint256 minFill, uint64 expiry, address taker);
    event OfferFilled(uint256 indexed id, address indexed buyer, address indexed seller, address token, address quote, uint256 tokenOut, uint256 quoteIn, uint256 fee, bool closed);
    event OfferCancelled(uint256 indexed id, address indexed seller, uint256 returned, bool expired);
    event FeeToBurner(address indexed quote, uint256 amount, uint256 ethOut);
    event FeeBurned(uint256 nlyra);
    event EthPending(address indexed to, uint256 amount);
    event EthClaimed(address indexed to, uint256 amount);
    event QuoteSet(address indexed quote, bool allowed);
    event FeeSet(uint16 feeBps);
    event FlusherSet(address flusher);
    event PausedSet(bool paused);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOwner();
    error NotSeller();
    error NotTaker();
    error NotFlusher();
    error NotOpen();
    error Expired();
    error NotExpired();
    error BadParams();
    error BadQuote();
    error BadFee();
    error BadValue();
    error BelowMinFill();
    error TooMuch();
    error ZeroOut();
    error TransferFailed();
    error IsPaused();
    error ZeroAddress();
    error Nothing();

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }
    modifier whenNotPaused() { if (paused) revert IsPaused(); _; }

    modifier lock() {
        // transient reentrancy guard (TSTORE: evmVersion cancun)
        assembly ("memory-safe") { if tload(0) { mstore(0, 0) revert(0, 0) } tstore(0, 1) }
        _;
        assembly ("memory-safe") { tstore(0, 0) }
    }

    /// @param weth    WETH9 on Robinhood Chain
    /// @param nlyra   the NLYRA token
    /// @param burner  BuybackBurner (payable receive)
    /// @param router  Uniswap V3 SwapRouter02 (used only to turn USDG fees into ETH)
    /// @param usdg    first allowed ERC-20 quote (may be address(0))
    /// @param flusher_ EOA allowed to flush accrued ERC-20 fees (may be address(0))
    /// @param feeBps_ initial fee in bps (<= 100)
    constructor(address weth, address nlyra, address payable burner, address router, address usdg, address flusher_, uint16 feeBps_) {
        if (weth == address(0) || nlyra == address(0) || burner == address(0) || router == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert BadFee();
        WETH = weth; NLYRA = nlyra; BURNER = burner; ROUTER = ISwapRouter02(router);
        owner = msg.sender; flusher = flusher_; feeBps = feeBps_;
        isQuote[nlyra] = true; emit QuoteSet(nlyra, true);
        if (usdg != address(0)) { isQuote[usdg] = true; emit QuoteSet(usdg, true); }
        emit FeeSet(feeBps_);
        emit FlusherSet(flusher_);
    }

    /// ETH may only arrive from WETH.withdraw (fee flush) or from fills (msg.value).
    receive() external payable { if (msg.sender != WETH) revert BadValue(); }

    // ------------------------------ offers ------------------------------

    /// Escrow `amount` of `token` and ask `want` of `quote` for all of it (price = want / amount).
    /// Tokens with a transfer tax are escrowed at the amount that actually arrived.
    function create(address token, uint128 amount, address quote, uint128 want, uint128 minFill, uint64 expiry, address taker)
        external lock whenNotPaused returns (uint256 id)
    {
        if (token == address(0) || token == quote || amount == 0 || want == 0) revert BadParams();
        if (quote != address(0) && !isQuote[quote]) revert BadQuote();
        if (expiry <= block.timestamp || expiry > block.timestamp + MAX_TTL) revert BadParams();
        if (minFill > want) revert BadParams();
        uint256 before = IERC20(token).balanceOf(address(this));
        _pull(token, msg.sender, amount);
        uint256 got = IERC20(token).balanceOf(address(this)) - before;
        if (got == 0 || got > type(uint128).max) revert BadParams();
        // a taxed token arrives short: keep the seller's price per unit by scaling `want` down with it
        uint128 want_ = got == amount ? want : uint128((uint256(want) * got) / amount);
        if (want_ == 0) revert BadParams();
        escrowed[token] += got;
        id = ++count;
        offers[id] = Offer({
            seller: msg.sender, token: token, quote: quote, taker: taker,
            amount: uint128(got), want: want_, amount0: uint128(got), want0: want_,
            minFill: minFill > want_ ? want_ : minFill, expiry: expiry, status: uint8(Status.Open)
        });
        emit OfferCreated(id, msg.sender, token, quote, got, want_, minFill, expiry, taker);
    }

    /// Pay `quoteAmount` of the offer's quote (ETH: send it as msg.value) and receive the matching share of the tokens.
    /// Partial fills are allowed above `minFill`; paying the whole remaining `want` closes the offer.
    function fill(uint256 id, uint128 quoteAmount) external payable lock whenNotPaused {
        Offer storage o = offers[id];
        if (o.status != uint8(Status.Open)) revert NotOpen();
        if (block.timestamp > o.expiry) revert Expired();
        if (o.taker != address(0) && msg.sender != o.taker) revert NotTaker();
        uint256 paid;
        if (o.quote == address(0)) {
            paid = msg.value;
        } else {
            if (msg.value != 0) revert BadValue();
            uint256 before = IERC20(o.quote).balanceOf(address(this));
            _pull(o.quote, msg.sender, quoteAmount);
            paid = IERC20(o.quote).balanceOf(address(this)) - before;
        }
        if (paid == 0) revert BadValue();
        if (paid > o.want) revert TooMuch();
        if (paid < o.minFill && paid != o.want) revert BelowMinFill();
        uint256 tokenOut = (uint256(o.amount) * paid) / o.want;
        if (tokenOut == 0) revert ZeroOut();

        // effects
        uint256 fee = (paid * feeBps) / BPS;
        uint256 toSeller = paid - fee;
        bool closed;
        uint256 leftover;
        o.amount -= uint128(tokenOut);
        o.want -= uint128(paid);
        if (o.want == 0 || o.amount == 0) {
            closed = true;
            leftover = o.amount;     // rounding dust when want hits zero first
            o.amount = 0;
            o.status = uint8(Status.Filled);
        }
        escrowed[o.token] -= tokenOut + leftover;
        totalFee[o.quote] += fee;
        totalVolume[o.quote] += paid;

        // interactions
        _push(o.token, msg.sender, tokenOut);
        if (leftover != 0) _push(o.token, o.seller, leftover);
        if (o.quote == address(0)) {
            _sendEth(o.seller, toSeller);
            if (fee != 0) _ethToBurner(fee);
        } else {
            _push(o.quote, o.seller, toSeller);
            if (fee != 0) {
                if (o.quote == NLYRA) { _push(NLYRA, DEAD, fee); totalNlyraBurned += fee; emit FeeBurned(fee); }
                else accruedFee[o.quote] += fee;
            }
        }
        emit OfferFilled(id, msg.sender, o.seller, o.token, o.quote, tokenOut, paid, fee, closed);
    }

    /// The seller may cancel at any time; after expiry anyone may trigger the refund (it always goes to the seller).
    function cancel(uint256 id) external lock {
        Offer storage o = offers[id];
        if (o.status != uint8(Status.Open)) revert NotOpen();
        bool expired = block.timestamp > o.expiry;
        if (msg.sender != o.seller && !expired) revert NotSeller();
        uint256 back = o.amount;
        o.amount = 0;
        o.status = uint8(Status.Cancelled);
        escrowed[o.token] -= back;
        if (back != 0) _push(o.token, o.seller, back);
        emit OfferCancelled(id, o.seller, back, expired);
    }

    /// Offers [from, from+n) for the front-end (ids start at 1).
    function getOffers(uint256 from, uint256 n) external view returns (Offer[] memory out) {
        if (from == 0) from = 1;
        uint256 last = count;
        if (from > last) return out;
        if (from + n - 1 > last) n = last - from + 1;
        out = new Offer[](n);
        for (uint256 i = 0; i < n; i++) out[i] = offers[from + i];
    }

    // ------------------------------ fees ------------------------------

    /// Flusher (or owner): swap an accrued ERC-20 fee balance into ETH and hand it to the burner.
    /// `poolFee` picks the Uniswap V3 tier; `minEthOut` is the slippage guard the caller computed off-chain.
    function flush(address token, uint24 poolFee, uint256 minEthOut) external lock returns (uint256 ethOut) {
        if (msg.sender != flusher && msg.sender != owner) revert NotFlusher();
        if (token == address(0)) revert BadParams();
        uint256 amt = accruedFee[token];
        if (amt == 0) revert Nothing();
        accruedFee[token] = 0;
        if (!IERC20(token).approve(address(ROUTER), amt)) revert TransferFailed();
        ethOut = ROUTER.exactInputSingle(ISwapRouter02.ExactInputSingleParams(token, WETH, poolFee, address(this), amt, minEthOut, 0));
        IWETH(WETH).withdraw(ethOut);
        (bool ok, ) = BURNER.call{value: ethOut}("");
        if (!ok) revert TransferFailed();
        totalEthToBurner += ethOut;
        emit FeeToBurner(token, amt, ethOut);
    }

    /// Anyone: retry ETH fees that could not reach the burner at fill time.
    function flushEth() external lock {
        uint256 amt = accruedFee[address(0)];
        if (amt == 0) revert Nothing();
        accruedFee[address(0)] = 0;
        (bool ok, ) = BURNER.call{value: amt}("");
        if (!ok) revert TransferFailed();
        totalEthToBurner += amt;
        emit FeeToBurner(address(0), amt, amt);
    }

    /// Payee: collect an ETH payout that bounced (a seller that is a contract without receive()).
    function claimEth() external lock {
        uint256 amt = pendingEth[msg.sender];
        if (amt == 0) revert Nothing();
        pendingEth[msg.sender] = 0;
        totalPendingEth -= amt;
        (bool ok, ) = msg.sender.call{value: amt}("");
        if (!ok) revert TransferFailed();
        emit EthClaimed(msg.sender, amt);
    }

    // ------------------------------ owner ------------------------------

    function setFeeBps(uint16 bps) external onlyOwner { if (bps > MAX_FEE_BPS) revert BadFee(); feeBps = bps; emit FeeSet(bps); }
    function setQuote(address quote, bool allowed) external onlyOwner { if (quote == address(0) || quote == WETH) revert BadQuote(); isQuote[quote] = allowed; emit QuoteSet(quote, allowed); }
    function setFlusher(address f) external onlyOwner { flusher = f; emit FlusherSet(f); }
    function setPaused(bool p) external onlyOwner { paused = p; emit PausedSet(p); }
    function transferOwnership(address to) external onlyOwner { pendingOwner = to; emit OwnershipTransferStarted(owner, to); }
    function acceptOwnership() external { if (msg.sender != pendingOwner) revert NotOwner(); emit OwnershipTransferred(owner, msg.sender); owner = msg.sender; pendingOwner = address(0); }

    /// Owner: sweep tokens that are neither escrow nor accrued fee (airdrops, mistakes). Escrow is untouchable.
    function rescue(address token, address to) external onlyOwner lock {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(0)) {
            uint256 free = address(this).balance - accruedFee[address(0)] - totalPendingEth;
            if (free == 0) revert Nothing();
            (bool ok, ) = to.call{value: free}(""); if (!ok) revert TransferFailed();
        } else {
            uint256 free = IERC20(token).balanceOf(address(this)) - escrowed[token] - accruedFee[token];
            if (free == 0) revert Nothing();
            _push(token, to, free);
        }
    }

    // ------------------------------ internals ------------------------------

    function _pull(address token, address from, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, address(this), amount));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    function _push(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    /// Pays ETH with a gas ceiling; if the payee refuses it, the amount waits in pendingEth.
    function _sendEth(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = to.call{value: amount, gas: 60_000}("");
        if (!ok) { pendingEth[to] += amount; totalPendingEth += amount; emit EthPending(to, amount); }
    }

    function _ethToBurner(uint256 amount) internal {
        (bool ok, ) = BURNER.call{value: amount, gas: 60_000}("");
        if (ok) { totalEthToBurner += amount; emit FeeToBurner(address(0), amount, amount); }
        else accruedFee[address(0)] += amount;
    }
}

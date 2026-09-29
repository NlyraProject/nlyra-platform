// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ============================================================
// NLYRA BUYBACK BURNER — the launchpad's treasury, split in stone
// by NERON & LYRA · nlyra.xyz
//
// Every wei of protocol revenue that lands here has exactly two
// destinations, fixed at deploy and immutable forever:
//   - keepBps → the protocol treasury (ops, immutable address)
//   - the rest → buys $NLYRA on Architect Swap, straight to 0xdEaD
// No owner, no withdraw, no upgrade, no admin key. Anyone can pull
// the trigger; nobody can point the gun elsewhere.
//
// Fed by the launchpad: the protocol's share of every pool's
// eternal fees. Every launch makes $NLYRA scarcer — hardcoded.
// Token-side fees (paid in launched tokens) sweep to the treasury.
// ============================================================

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

interface IV3PoolMin {
    function slot0() external view returns (uint160 sqrtPriceX96, int24, uint16, uint16, uint16, uint8, bool);
    function token0() external view returns (address);
    function fee() external view returns (uint24);
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

contract BuybackBurner {
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    ISwapRouter02 public immutable router; // official Uniswap V3 SwapRouter02 — the deep NLYRA pool lives there
    address public immutable pool;         // the NLYRA/WETH V3 pool (price source for the slippage guard)
    uint24 public immutable poolFee;
    bool internal immutable wethIs0;
    address public immutable nlyra;
    address public immutable weth;
    address public immutable treasury; // protocol ops wallet — fixed forever
    uint16 public immutable keepBps;   // treasury share of every burn, in bps (e.g. 5000 = 50%)
    uint256 public totalEthUsed;      // lifetime ETH converted to burns
    uint256 public totalEthKept;      // lifetime ETH sent to the treasury
    uint256 public totalNlyraBurned;  // lifetime $NLYRA sent to 0xdEaD

    event Burned(address indexed caller, uint256 ethBurn, uint256 ethKept, uint256 nlyraBurned);

    constructor(address _router, address _nlyra, address _weth, address _pool, address _treasury, uint16 _keepBps) {
        require(_keepBps <= 10000 && _treasury != address(0), "cfg");
        router = ISwapRouter02(_router);
        nlyra = _nlyra;
        weth = _weth;
        pool = _pool;
        poolFee = IV3PoolMin(_pool).fee();
        wethIs0 = IV3PoolMin(_pool).token0() == _weth;
        treasury = _treasury;
        keepBps = _keepBps;
    }

    receive() external payable {}

    // fees que llegan en TOKENS lanzados (lado token de collectFees in-kind):
    // cualquiera puede barrerlas al tesoro — destino fijo, sin discreción.
    function sweepToken(address tk) external {
        require(tk != address(0), "tk");
        uint256 bal = IERC20Min(tk).balanceOf(address(this));
        require(bal > 0, "nothing");
        require(IERC20Min(tk).transfer(treasury, bal), "sweep");
    }

    // Swap the FULL ETH balance for $NLYRA, delivered directly to 0xdEaD.
    // minNlyraOut = 0 → auto-guard: 95% of the live on-chain quote (covers
    // pool fee + rounding; pushing the price in the same block only makes
    // the pusher pay trading fees into our own pool). Pass an explicit
    // minNlyraOut to be stricter.
    function burn(uint256 minNlyraOut) external returns (uint256 burned) {
        uint256 bal = address(this).balance;
        require(bal > 0, "nothing to burn");
        uint256 keep = (bal * keepBps) / 10000;
        if (keep > 0) {
            (bool ok, ) = treasury.call{ value: keep }("");
            require(ok, "treasury send");
            totalEthKept += keep;
        }
        uint256 toBurn = bal - keep;
        if (toBurn > 0) {
            if (minNlyraOut == 0) {
                // guard automático: 95% del precio spot del pool (menos el fee del tier)
                (uint160 s,,,,,,) = IV3PoolMin(pool).slot0();
                uint256 exp;
                if (wethIs0) { exp = (uint256(s) * toBurn) >> 96; exp = (exp * uint256(s)) >> 96; }
                else { exp = (toBurn << 96) / uint256(s); exp = (exp << 96) / uint256(s); }
                minNlyraOut = (((exp * (1_000_000 - poolFee)) / 1_000_000) * 95) / 100;
            }
            burned = router.exactInputSingle{ value: toBurn }(
                ISwapRouter02.ExactInputSingleParams(weth, nlyra, poolFee, DEAD, toBurn, minNlyraOut, 0)
            );
            totalEthUsed += toBurn;
            totalNlyraBurned += burned;
        }
        emit Burned(msg.sender, toBurn, keep, burned);
    }
}

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

interface IV2Router {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory);
    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory);
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

contract BuybackBurner {
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    IV2Router public immutable router; // Architect Swap V2 (the NLYRA/ETH pool lives there)
    address public immutable nlyra;
    address public immutable weth;
    address public immutable treasury; // protocol ops wallet — fixed forever
    uint16 public immutable keepBps;   // treasury share of every burn, in bps (e.g. 5000 = 50%)
    uint256 public totalEthUsed;      // lifetime ETH converted to burns
    uint256 public totalEthKept;      // lifetime ETH sent to the treasury
    uint256 public totalNlyraBurned;  // lifetime $NLYRA sent to 0xdEaD

    event Burned(address indexed caller, uint256 ethBurn, uint256 ethKept, uint256 nlyraBurned);

    constructor(address _router, address _nlyra, address _weth, address _treasury, uint16 _keepBps) {
        require(_keepBps <= 10000 && _treasury != address(0), "cfg");
        router = IV2Router(_router);
        nlyra = _nlyra;
        weth = _weth;
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
            address[] memory path = new address[](2);
            path[0] = weth;
            path[1] = nlyra;
            if (minNlyraOut == 0) {
                uint256[] memory q = router.getAmountsOut(toBurn, path);
                minNlyraOut = (q[1] * 95) / 100;
            }
            uint256[] memory out = router.swapExactETHForTokens{ value: toBurn }(
                minNlyraOut, path, DEAD, block.timestamp + 300
            );
            burned = out[1];
            totalEthUsed += toBurn;
            totalNlyraBurned += burned;
        }
        emit Burned(msg.sender, toBurn, keep, burned);
    }
}

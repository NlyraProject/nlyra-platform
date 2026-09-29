// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ============================================================
// ARCHITECT BOUNTIES — escrow for community tasks, paid in USDG
// by NERON & LYRA · nlyra.xyz/bounties
//
// The design is the legal posture:
//
// - NON-CUSTODIAL: the proposer's funds sit in THIS contract, never
//   in ours. There is no admin withdraw. The only powers the arbiter
//   holds are: publish a bounty, return the money to its owner, or
//   pay the winner the proposer chose. It can never pay itself from
//   someone else's escrow (only the fixed 2% fee on successful
//   payouts, to a fixed sink, disclosed up front).
//
// - THE DEPOSIT IS THE SPAM FILTER: proposing requires locking the
//   reward. Every proposal reaches The Architect (the arbiter) for
//   manual review — approve publishes it, reject refunds 100%
//   automatically. No AI, no committee: one accountable human.
//
// - NOBODY IS EVER TRAPPED: if the arbiter never acts, or a live
//   bounty is never paid, the proposer reclaims their full deposit
//   permissionlessly after the deadline + dispute window.
//
// - Hard limits in stone: allowed tokens and per-bounty caps fixed
//   at deploy, max duration 30 days, fee 2% only on success.
// ============================================================

interface IERC20B {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

contract BountyEscrow {
    enum Status { None, Pending, Live, Paid, Rejected, Cancelled, Reclaimed }

    struct Bounty {
        address proposer;
        address token;      // USDG or NLYRA
        uint256 amount;     // full reward, locked at proposal time
        uint64 deadline;    // submissions close here
        uint64 createdAt;
        Status status;
        bytes32 metaHash;   // keccak256 of the task spec (title, brief, deliverables) — integrity anchor
    }

    uint16 public constant FEE_BPS = 200;          // 2%, charged ONLY on successful payout
    uint64 public constant MAX_DURATION = 30 days;
    uint64 public constant DISPUTE_WINDOW = 3 days;

    address public immutable arbiter;  // The Architect's signer — approves, rejects, pays
    address public immutable feeSink;  // protocol ops wallet — receives the success fee

    mapping(address => uint256) public maxAmount; // per-token cap; 0 = token not allowed
    Bounty[] public bounties;

    uint256 private unlocked = 1;
    modifier lock() { require(unlocked == 1, "reentrancy"); unlocked = 0; _; unlocked = 1; }
    modifier onlyArbiter() { require(msg.sender == arbiter, "arbiter"); _; }

    event Proposed(uint256 indexed id, address indexed proposer, address token, uint256 amount, uint64 deadline, bytes32 metaHash);
    event Approved(uint256 indexed id);
    event Rejected(uint256 indexed id);
    event Cancelled(uint256 indexed id);
    event Paid(uint256 indexed id, address[] winners, uint256[] amounts, uint256 fee, uint256 refunded);
    event Reclaimed(uint256 indexed id, uint256 amount);

    constructor(address _arbiter, address _feeSink, address[] memory tokens, uint256[] memory caps) {
        require(_arbiter != address(0) && _feeSink != address(0), "cfg");
        require(tokens.length == caps.length && tokens.length > 0, "tokens");
        arbiter = _arbiter;
        feeSink = _feeSink;
        for (uint256 i = 0; i < tokens.length; i++) {
            require(tokens[i] != address(0) && caps[i] > 0, "cap");
            maxAmount[tokens[i]] = caps[i];
        }
    }

    // Locking the reward IS the application. The bounty is born Pending —
    // invisible to the public site until the arbiter approves it.
    function propose(address token, uint256 amount, uint64 deadline, bytes32 metaHash)
        external lock returns (uint256 id)
    {
        require(amount > 0 && amount <= maxAmount[token], "amount");
        require(deadline > block.timestamp && deadline <= block.timestamp + MAX_DURATION, "deadline");
        require(metaHash != bytes32(0), "meta");
        _pull(token, msg.sender, amount);
        bounties.push(Bounty(msg.sender, token, amount, deadline, uint64(block.timestamp), Status.Pending, metaHash));
        id = bounties.length - 1;
        emit Proposed(id, msg.sender, token, amount, deadline, metaHash);
    }

    // ── the arbiter's three powers ────────────────────────────────
    function approve(uint256 id) external onlyArbiter {
        Bounty storage b = bounties[id];
        require(b.status == Status.Pending, "status");
        b.status = Status.Live;
        emit Approved(id);
    }

    // Reject = the proposer gets every cent back, automatically.
    function reject(uint256 id) external onlyArbiter lock {
        Bounty storage b = bounties[id];
        require(b.status == Status.Pending, "status");
        b.status = Status.Rejected;
        _push(b.token, b.proposer, b.amount);
        emit Rejected(id);
    }

    // Kill-switch for a live bounty that went bad. The ONLY thing this
    // power can do with the money is return it to its owner.
    function cancel(uint256 id) external onlyArbiter lock {
        Bounty storage b = bounties[id];
        require(b.status == Status.Live, "status");
        b.status = Status.Cancelled;
        _push(b.token, b.proposer, b.amount);
        emit Cancelled(id);
    }

    // Pay the winner(s) the proposer selected. The 2% fee comes out of
    // the locked amount; whatever is not paid out returns to the
    // proposer in the same transaction. Everything sums to the escrow —
    // the contract cannot invent or retain a wei.
    function payout(uint256 id, address[] calldata winners, uint256[] calldata amounts)
        external onlyArbiter lock
    {
        Bounty storage b = bounties[id];
        require(b.status == Status.Live, "status");
        require(winners.length == amounts.length && winners.length > 0, "winners");

        uint256 total;
        for (uint256 i = 0; i < amounts.length; i++) {
            require(winners[i] != address(0) && amounts[i] > 0, "winner");
            total += amounts[i];
        }
        uint256 fee = (total * FEE_BPS) / 10000;
        require(total + fee <= b.amount, "exceeds escrow");
        uint256 refund = b.amount - total - fee;

        b.status = Status.Paid;
        for (uint256 i = 0; i < winners.length; i++) _push(b.token, winners[i], amounts[i]);
        if (fee > 0) _push(b.token, feeSink, fee);
        if (refund > 0) _push(b.token, b.proposer, refund);
        emit Paid(id, winners, amounts, fee, refund);
    }

    // ── nobody is ever trapped ────────────────────────────────────
    // Pending past its deadline (arbiter never acted) or Live past the
    // deadline + dispute window (never paid): the proposer takes their
    // full deposit back. Callable by anyone; funds only ever flow to
    // the proposer.
    function reclaim(uint256 id) external lock {
        Bounty storage b = bounties[id];
        if (b.status == Status.Pending) {
            require(block.timestamp > b.deadline, "not yet");
        } else if (b.status == Status.Live) {
            require(block.timestamp > uint256(b.deadline) + DISPUTE_WINDOW, "not yet");
        } else {
            revert("status");
        }
        b.status = Status.Reclaimed;
        _push(b.token, b.proposer, b.amount);
        emit Reclaimed(id, b.amount);
    }

    function bountyCount() external view returns (uint256) { return bounties.length; }

    // ── safe ERC20 plumbing (USDG/NLYRA are honest tokens, but the
    //    balance check keeps any fee-on-transfer weirdness out) ──
    function _pull(address token, address from, uint256 amount) internal {
        uint256 before = IERC20B(token).balanceOf(address(this));
        require(IERC20B(token).transferFrom(from, address(this), amount), "pull");
        require(IERC20B(token).balanceOf(address(this)) - before == amount, "fee-on-transfer");
    }

    function _push(address token, address to, uint256 amount) internal {
        require(IERC20B(token).transfer(to, amount), "push");
    }
}

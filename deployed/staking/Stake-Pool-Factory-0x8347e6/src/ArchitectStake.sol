// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ============================================================
// ARCHITECT STAKE — self-service staking pools for launchpad
// creators · NERON & LYRA · nlyra.xyz/stake
//
// A creator gives their community a reason to hold: they pick an
// APY (the UI offers 10/20/30/40%), pick a duration, and lock a
// reward reserve of their own token. Stakers earn that fixed APY,
// paid from the reserve — never from thin air.
//
// The design is the legal posture:
//
// - THE PROMISE IS ALWAYS SOLVENT: every stake pre-commits its
//   full reward up front. When the reserve can't back another
//   stake's rewards, the pool simply stops accepting stakes.
//   A 40% APY here can never be a lie — it's escrowed.
//
// - PRINCIPAL IS UNTOUCHABLE: stakers can unstake at ANY moment
//   and take their tokens plus everything accrued so far. The
//   creator can never touch staked principal. Ever.
//
// - THE CREATOR IS PROTECTED TOO: rewards not committed to any
//   staker are theirs to reclaim once the pool ends. Nothing is
//   trapped on either side.
//
// - NOBODY ELSE HAS POWER: no owner, no pause, no upgrade, no
//   admin. The factory only deploys and lists.
//
// Not supported: fee-on-transfer / rebasing tokens (launchpad
// tokens use the audited template — plain ERC20, no taxes).
// ============================================================

interface IERC20S {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

contract FixedAPYPool {
    uint256 private constant YEAR = 365 days;
    uint256 private constant BPS = 10_000;

    address public immutable token;
    address public immutable creator;
    uint256 public immutable apyBps;    // 1000 = 10%
    uint64 public immutable start;
    uint64 public immutable end;

    uint256 public totalStaked;
    uint256 public rewardReserve;       // funded by creator, shrinks as rewards pay out
    uint256 public committed;           // rewards promised to open positions, not yet paid

    struct Position {
        uint256 amount;      // principal
        uint256 entitlement; // total reward if held from posStart to end
        uint256 claimed;     // rewards already paid on this position
        uint64 posStart;
    }
    mapping(address => Position) public positions;

    uint256 private unlocked = 1;
    modifier lock() { require(unlocked == 1, "reentrancy"); unlocked = 0; _; unlocked = 1; }

    event Staked(address indexed user, uint256 amount, uint256 entitlement);
    event Unstaked(address indexed user, uint256 principal, uint256 rewards);
    event Claimed(address indexed user, uint256 rewards);
    event Funded(address indexed from, uint256 amount);
    event Reclaimed(uint256 leftover);

    /// Deployed only by the factory, which transfers `initialReserve`
    /// of `token_` here within the same transaction — atomically.
    constructor(address token_, address creator_, uint256 apyBps_, uint64 end_, uint256 initialReserve_) {
        token = token_; creator = creator_; apyBps = apyBps_;
        start = uint64(block.timestamp); end = end_;
        rewardReserve = initialReserve_;
    }

    // Reward a stake earns if held from now to the pool's end.
    function entitlementFor(uint256 amount) public view returns (uint256) {
        if (block.timestamp >= end) return 0;
        return (amount * apyBps * (end - block.timestamp)) / (YEAR * BPS);
    }

    // Linear accrual over the position's own window.
    function earned(address who) public view returns (uint256) {
        Position memory p = positions[who];
        if (p.amount == 0 || p.entitlement == 0) return 0;
        uint256 until = block.timestamp < end ? block.timestamp : end;
        uint256 accrued = (p.entitlement * (until - p.posStart)) / (end - p.posStart);
        return accrued - p.claimed;
    }

    // How much MORE can be staked right now with the promise still solvent.
    function capacityLeft() public view returns (uint256) {
        if (block.timestamp >= end) return 0;
        uint256 free = rewardReserve - committed;
        return (free * YEAR * BPS) / (apyBps * (end - block.timestamp));
    }

    /// Stake more of the token. An existing position is settled first
    /// (accrued rewards paid, unearned commitment released) and reopened
    /// combined — every promise is priced at the moment it's made.
    function stake(uint256 amount) external lock {
        require(amount > 0, "zero");
        require(block.timestamp < end, "pool ended");
        Position storage p = positions[msg.sender];
        uint256 payout;
        uint256 principal = amount;
        if (p.amount > 0) {
            payout = earned(msg.sender);
            committed -= (p.entitlement - p.claimed);   // release the old promise
            rewardReserve -= payout;                    // pay what was accrued
            principal += p.amount;
        }
        uint256 ent = entitlementFor(principal);
        require(committed + ent <= rewardReserve, "pool full - reserve can't back this stake");
        committed += ent;
        totalStaked += amount;
        positions[msg.sender] = Position(principal, ent, 0, uint64(block.timestamp));
        require(IERC20S(token).transferFrom(msg.sender, address(this), amount), "transfer");
        if (payout > 0) require(IERC20S(token).transfer(msg.sender, payout), "pay");
        emit Staked(msg.sender, amount, ent);
    }

    /// Take everything home: principal + accrued rewards. Any time.
    function unstake() external lock {
        Position memory p = positions[msg.sender];
        require(p.amount > 0, "nothing staked");
        uint256 payout = earned(msg.sender);
        committed -= (p.entitlement - p.claimed);
        rewardReserve -= payout;
        totalStaked -= p.amount;
        delete positions[msg.sender];
        require(IERC20S(token).transfer(msg.sender, p.amount + payout), "transfer");
        emit Unstaked(msg.sender, p.amount, payout);
    }

    /// Pocket accrued rewards, keep the stake running.
    function claim() external lock {
        uint256 payout = earned(msg.sender);
        require(payout > 0, "nothing accrued");
        positions[msg.sender].claimed += payout;
        committed -= payout;
        rewardReserve -= payout;
        require(IERC20S(token).transfer(msg.sender, payout), "transfer");
        emit Claimed(msg.sender, payout);
    }

    /// Anyone may add rewards (the creator usually; a generous friend too).
    function fund(uint256 amount) external lock {
        require(amount > 0, "zero");
        require(block.timestamp < end, "pool ended");
        rewardReserve += amount;
        require(IERC20S(token).transferFrom(msg.sender, address(this), amount), "transfer");
        emit Funded(msg.sender, amount);
    }

    /// After the pool ends the creator takes back whatever the reserve
    /// never had to promise. Committed-but-unclaimed rewards stay.
    function reclaim() external lock {
        require(msg.sender == creator, "creator only");
        require(block.timestamp >= end, "pool still running");
        uint256 leftover = rewardReserve - committed;
        require(leftover > 0, "nothing to reclaim");
        rewardReserve -= leftover;
        require(IERC20S(token).transfer(creator, leftover), "transfer");
        emit Reclaimed(leftover);
    }

    function poolInfo() external view returns (
        address token_, address creator_, uint256 apyBps_, uint64 start_, uint64 end_,
        uint256 totalStaked_, uint256 rewardReserve_, uint256 committed_, uint256 capacityLeft_
    ) {
        return (token, creator, apyBps, start, end, totalStaked, rewardReserve, committed, capacityLeft());
    }
}

contract StakePoolFactory {
    address[] public pools;
    mapping(address => address[]) public poolsOf; // token → its pools

    event PoolCreated(address indexed pool, address indexed token, address indexed creator, uint256 apyBps, uint64 end, uint256 initialReserve);

    /// Permissionless: anyone can open a pool for any plain ERC20, but
    /// the deposit IS the commitment — an unfunded pool cannot exist.
    /// The site curates which pools it shows.
    function createPool(address token, uint256 apyBps, uint256 durationDays, uint256 initialReserve)
        external returns (address pool)
    {
        require(apyBps >= 100 && apyBps <= 10_000, "APY 1-100%");
        require(durationDays >= 7 && durationDays <= 365, "7-365 days");
        require(initialReserve > 0, "fund the promise");
        uint64 end = uint64(block.timestamp + durationDays * 1 days);
        pool = address(new FixedAPYPool(token, msg.sender, apyBps, end, initialReserve));
        pools.push(pool);
        poolsOf[token].push(pool);
        require(IERC20S(token).transferFrom(msg.sender, pool, initialReserve), "transfer");
        emit PoolCreated(pool, token, msg.sender, apyBps, end, initialReserve);
    }

    function poolCount() external view returns (uint256) { return pools.length; }
    function poolCountOf(address token) external view returns (uint256) { return poolsOf[token].length; }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// ============================================================================
// LYRA SLOTS V2 — a three-reel machine played with real $NLYRA.
//
// ONE SIGNATURE, UP TO 10 SPINS. V1 asked for a wallet confirmation on every
// single pull, which made the machine unplayable. Here you buy a BATCH: one
// transaction, one commit, and the batch resolves into N independent spins
// (each spin takes its own slice of the entropy, so they are genuinely
// different pulls — not the same result repeated).
//
// Same non-custodial, provably-fair engine as LyraRouletteV2 (dice2.win
// commit-reveal): the croupier SIGNS keccak256(reveal) before the bet exists,
// then reveals; the reels come from keccak(reveal, blockhash-of-the-bet-block),
// which neither side can steer because that block does not exist yet when the
// secret is signed. The contract pays winners itself, and if the croupier ever
// goes quiet the player calls refundBet and takes the stake back.
//
// THE MATH IS PUBLIC AND FIXED IN CODE (computed by enumerating all 8^3
// outcomes, not estimated):
//   RTP 95.62% · house edge 4.38% · pays on 32.3% of spins · top win 228.9x
// Reel weights out of 100 virtual stops:
//   💀18  🪙20  💧18  ⚡15  🛡️12  🔒9  ◆5  🌙3
// Payouts are stored in TENTHS of the bet (PAY_DEN = 10) so small pair wins
// keep their precision — rounding them to whole multiples silently cost 5
// points of RTP during design.
//
// 💀 SKULL is the rug: it never pays, not as a pair, not as a triple.
//
// ⚠️ Robinhood Chain is an Arbitrum-style L2: `block.number` here is the L1
// block. Anything off-chain computing a deadline must read `l1BlockNumber`.
// ============================================================================

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract LyraSlotsV2 {
    uint256 public constant WHEEL = 100;      // virtual stops per reel
    uint256 public constant PAY_DEN = 10;     // payouts are in tenths of the bet
    uint256 constant BET_EXPIRATION_BLOCKS = 250;

    IERC20 public immutable token;
    address public owner;
    address public nextOwner;
    address public secretSigner;
    address public croupier;

    uint256 public minBet;
    uint256 public maxBet;
    uint256 public maxProfit;
    uint256 public lockedInBets;
    bool public closed;

    struct Spin {
        uint128 amount;      // per spin
        uint128 maxWinnable; // worst case for the whole batch
        uint40 blockNo;
        uint8 count;         // how many pulls in this batch
        address gambler;
    }

    uint8 public constant MAX_SPINS = 10;
    mapping(uint256 => Spin) public spins; // commit => spin

    event SpinPlaced(uint256 indexed commit, address indexed gambler, uint256 amount, uint8 count);
    /// packedReels holds 3 symbols per spin, 4 bits each, spin 0 in the low
    /// bits — 10 spins fit in 120 bits. The UI unpacks it to animate each pull.
    event SpinSettled(uint256 indexed commit, address indexed gambler, uint256 amountPerSpin,
                      uint8 count, uint256 packedReels, uint256 payout);
    event SpinRefunded(uint256 indexed commit, address indexed gambler, uint256 amount);
    event BankFunded(address indexed from, uint256 amount);

    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }

    constructor(address token_, address secretSigner_, address croupier_, uint256 minBet_, uint256 maxBet_, uint256 maxProfit_) {
        require(token_ != address(0) && secretSigner_ != address(0) && croupier_ != address(0), "zero addr");
        token = IERC20(token_);
        owner = msg.sender;
        secretSigner = secretSigner_;
        croupier = croupier_;
        minBet = minBet_;
        maxBet = maxBet_;
        maxProfit = maxProfit_;
    }

    // --- admin ---------------------------------------------------------
    function setSecretSigner(address a) external onlyOwner { require(a != address(0), "zero"); secretSigner = a; }
    function setCroupier(address a) external onlyOwner { require(a != address(0), "zero"); croupier = a; }
    function setLimits(uint256 min_, uint256 max_, uint256 maxProfit_) external onlyOwner {
        require(min_ > 0 && max_ >= min_, "bad limits");
        minBet = min_; maxBet = max_; maxProfit = maxProfit_;
    }
    function setClosed(bool v) external onlyOwner { closed = v; }
    function transferOwnership(address a) external onlyOwner { nextOwner = a; }
    function acceptOwnership() external { require(msg.sender == nextOwner, "not next"); owner = nextOwner; nextOwner = address(0); }

    function fundBank(uint256 amount) external {
        require(token.transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        emit BankFunded(msg.sender, amount);
    }
    function withdrawBank(address to, uint256 amount) external onlyOwner {
        require(amount <= bankAvailable(), "would break pending bets");
        require(token.transfer(to, amount), "transfer failed");
    }
    function bankAvailable() public view returns (uint256) {
        uint256 bal = token.balanceOf(address(this));
        return bal > lockedInBets ? bal - lockedInBets : 0;
    }

    // --- the reels ------------------------------------------------------
    /// Cumulative weights: 💀18 🪙20 💧18 ⚡15 🛡️12 🔒9 ◆5 🌙3  (=100)
    function symbolAt(uint256 stop) public pure returns (uint8) {
        if (stop < 18) return 0;   // SKULL
        if (stop < 38) return 1;   // COIN
        if (stop < 56) return 2;   // DROP
        if (stop < 71) return 3;   // BOLT
        if (stop < 83) return 4;   // SHIELD
        if (stop < 92) return 5;   // LOCK
        if (stop < 97) return 6;   // EYE
        return 7;                  // MOON
    }

    /// Payout for three of a kind, in TENTHS of the bet.
    function pay3(uint8 s) public pure returns (uint256) {
        if (s == 1) return 114;    // 🪙 11.4x
        if (s == 2) return 160;    // 💧 16.0x
        if (s == 3) return 229;    // ⚡ 22.9x
        if (s == 4) return 343;    // 🛡️ 34.3x
        if (s == 5) return 572;    // 🔒 57.2x
        if (s == 6) return 1259;   // ◆ 125.9x
        if (s == 7) return 2289;   // 🌙 228.9x
        return 0;                  // 💀 the rug pays nothing
    }

    /// Payout for a pair in any position, in TENTHS of the bet.
    function pay2(uint8 s) public pure returns (uint256) {
        if (s == 1) return 11;     // 🪙 1.1x
        if (s == 2) return 14;     // 💧 1.4x
        if (s == 3) return 17;     // ⚡ 1.7x
        if (s == 4) return 23;     // 🛡️ 2.3x
        if (s == 5) return 34;     // 🔒 3.4x
        if (s == 6) return 69;     // ◆ 6.9x
        if (s == 7) return 172;    // 🌙 17.2x
        return 0;                  // 💀
    }

    /// The most a bet of `amount` can ever pay (three moons).
    function maxPayout(uint256 amount) public pure returns (uint256) {
        return amount * 2289 / PAY_DEN;
    }

    /// What this combination pays. Public so anyone can audit the table.
    function payoutFor(uint8 a, uint8 b, uint8 c, uint256 amount) public pure returns (uint256) {
        if (a == b && b == c) return amount * pay3(a) / PAY_DEN;
        uint8 pair;
        if (a == b) pair = a;
        else if (a == c) pair = a;
        else if (b == c) pair = b;
        else return 0;
        return amount * pay2(pair) / PAY_DEN;
    }

    /// The three reels for a given (reveal, blockhash) — pure, so a player can
    /// replay their own spin off-chain and confirm the machine did not lie.
    function reelsFor(uint256 reveal, bytes32 bh, uint8 index) public pure returns (uint8 r1, uint8 r2, uint8 r3) {
        uint256 e = uint256(keccak256(abi.encodePacked(reveal, bh, index)));
        r1 = symbolAt((e >> 0) % WHEEL);
        r2 = symbolAt((e >> 64) % WHEEL);
        r3 = symbolAt((e >> 128) % WHEEL);
    }

    // --- play ------------------------------------------------------------
    function spin(
        uint256 amount,
        uint8 count,
        uint256 commitLastBlock,
        uint256 commit,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(!closed, "machine closed");
        require(spins[commit].gambler == address(0), "commit used");
        require(block.number <= commitLastBlock, "commit expired");
        require(count > 0 && count <= MAX_SPINS, "bad spin count");
        require(amount >= minBet && amount <= maxBet, "bet out of range");

        bytes32 signatureHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n64", commitLastBlock, commit));
        require(ecrecover(signatureHash, v, r, s) == secretSigner, "bad signature");

        uint256 total = amount * count;
        uint256 worst = maxPayout(amount) * count;
        require(worst - total <= maxProfit, "profit over machine limit");

        require(token.transferFrom(msg.sender, address(this), total), "transferFrom failed");
        require(lockedInBets + worst <= token.balanceOf(address(this)), "bank cannot cover it");
        lockedInBets += worst;

        spins[commit] = Spin({
            amount: uint128(amount),
            maxWinnable: uint128(worst),
            blockNo: uint40(block.number),
            count: count,
            gambler: msg.sender
        });
        emit SpinPlaced(commit, msg.sender, amount, count);
    }

    function settleBet(uint256 reveal) external {
        require(msg.sender == croupier, "not croupier");
        uint256 commit = uint256(keccak256(abi.encodePacked(reveal)));
        Spin storage sp = spins[commit];
        address gambler = sp.gambler;
        require(gambler != address(0), "no such bet");

        uint256 placeBlock = sp.blockNo;
        require(block.number > placeBlock, "same block");
        require(block.number <= placeBlock + BET_EXPIRATION_BLOCKS, "bet expired, refund it");
        bytes32 bh = blockhash(placeBlock);
        require(bh != bytes32(0), "blockhash unavailable");

        uint256 amount = sp.amount;
        uint8 count = sp.count;
        uint256 payout;
        uint256 packed;
        for (uint8 i = 0; i < count; i++) {
            (uint8 a, uint8 b, uint8 c) = reelsFor(reveal, bh, i);
            payout += payoutFor(a, b, c, amount);
            packed |= (uint256(a) | (uint256(b) << 4) | (uint256(c) << 8)) << (uint256(i) * 12);
        }

        lockedInBets -= sp.maxWinnable;
        delete spins[commit];

        if (payout > 0) require(token.transfer(gambler, payout), "payout failed");
        emit SpinSettled(commit, gambler, amount, count, packed, payout);
    }

    function refundBet(uint256 commit) external {
        Spin storage sp = spins[commit];
        address gambler = sp.gambler;
        require(gambler != address(0), "no such bet");
        require(block.number > uint256(sp.blockNo) + BET_EXPIRATION_BLOCKS, "not expired yet");

        uint256 total = uint256(sp.amount) * sp.count;
        lockedInBets -= sp.maxWinnable;
        delete spins[commit];

        require(token.transfer(gambler, total), "refund failed");
        emit SpinRefunded(commit, gambler, total);
    }

    /// Minimal view the croupier polls.
    function betOwner(uint256 commit) external view returns (address gambler, uint40 blockNo) {
        Spin storage sp = spins[commit];
        return (sp.gambler, sp.blockNo);
    }
}

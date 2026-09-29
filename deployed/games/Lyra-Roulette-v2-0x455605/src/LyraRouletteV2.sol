// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// ============================================================================
// LYRA ROULETTE V2 — a real table: many chips, one ball.
//
// V1 took a single position per spin, so covering 7 + 13 + red meant three
// transactions and three DIFFERENT balls. That is not roulette. Here you lay
// as many chips as you like on the felt and ONE spin pays every one of them
// that lands.
//
// Same non-custodial, provably-fair core as V1 (dice2.win commit-reveal):
//   1. the croupier SIGNS keccak256(reveal) before the bet exists,
//   2. the player places the batch with that signed commit,
//   3. the croupier reveals; the ball is keccak(reveal, blockhash-of-the-bet-
//      block) % 37 — neither side can steer it, the block did not exist yet,
//   4. if the croupier ever goes silent, the player calls refundBet and takes
//      the whole batch back. The house cannot hold anyone's money.
//
// Bank safety with many chips: the contract locks the WORST CASE — it walks
// all 37 pockets and locks the highest total the batch could ever win. A
// player covering half the board can never win more than the bank can pay.
//
// House edge is the single zero and nothing else: 1/37 = 2.70%.
//
// ⚠️ Robinhood Chain is an Arbitrum-style L2: `block.number` here is the L1
// block (~12s), NOT the 0.1s L2 block. Anything off-chain that computes a
// deadline must read `l1BlockNumber`, never eth_blockNumber.
// ============================================================================

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract LyraRouletteV2 {
    // --- bet types -----------------------------------------------------
    uint8 constant BET_NUMBER = 0; // value 0..36            pays 35:1
    uint8 constant BET_COLOR  = 1; // 0 = red, 1 = black     pays  1:1
    uint8 constant BET_PARITY = 2; // 0 = even, 1 = odd      pays  1:1
    uint8 constant BET_HALF   = 3; // 0 = 1-18, 1 = 19-36    pays  1:1
    uint8 constant BET_DOZEN  = 4; // 0,1,2                  pays  2:1
    uint8 constant BET_COLUMN = 5; // 0,1,2                  pays  2:1

    uint64 constant RED_MASK = 0x154aad52aa; // bit i set => pocket i is red
    uint256 constant BET_EXPIRATION_BLOCKS = 250;
    uint256 public constant MAX_POSITIONS = 12; // bounds the worst-case scan

    IERC20 public immutable token;
    address public owner;
    address public nextOwner;
    address public secretSigner;
    address public croupier;

    uint256 public minBet;      // per position
    uint256 public maxBet;      // per batch (everything on the felt)
    uint256 public maxProfit;   // most a single spin may take from the bank
    uint256 public lockedInBets;
    bool public closed;

    struct Batch {
        uint128 totalAmount;  // everything staked
        uint128 maxWinnable;  // worst case for the bank across all 37 pockets
        uint40 blockNo;
        address gambler;
        uint8[] betTypes;
        uint8[] betValues;
        uint128[] amounts;
    }
    mapping(uint256 => Batch) internal batches; // commit => batch

    event BetPlaced(uint256 indexed commit, address indexed gambler, uint256 totalAmount, uint256 positions);
    event BetSettled(uint256 indexed commit, address indexed gambler, uint256 totalAmount, uint8 spin, uint256 payout);
    event BetRefunded(uint256 indexed commit, address indexed gambler, uint256 amount);
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

    // --- odds ----------------------------------------------------------
    function multiplier(uint8 betType) public pure returns (uint256) {
        if (betType == BET_NUMBER) return 36;
        if (betType == BET_COLOR || betType == BET_PARITY || betType == BET_HALF) return 2;
        if (betType == BET_DOZEN || betType == BET_COLUMN) return 3;
        return 0;
    }

    function validPosition(uint8 betType, uint8 betValue) public pure returns (bool) {
        if (betType == BET_NUMBER) return betValue <= 36;
        if (betType == BET_COLOR || betType == BET_PARITY || betType == BET_HALF) return betValue <= 1;
        if (betType == BET_DOZEN || betType == BET_COLUMN) return betValue <= 2;
        return false;
    }

    function isWinner(uint8 betType, uint8 betValue, uint8 spin) public pure returns (bool) {
        if (betType == BET_NUMBER) return spin == betValue;
        if (spin == 0) return false; // the green zero takes every outside bet
        if (betType == BET_COLOR)  return (((RED_MASK >> spin) & 1) == 1) == (betValue == 0);
        if (betType == BET_PARITY) return (spin % 2 == 0) == (betValue == 0);
        if (betType == BET_HALF)   return (spin <= 18) == (betValue == 0);
        if (betType == BET_DOZEN)  return (spin - 1) / 12 == betValue;
        if (betType == BET_COLUMN) return (spin - 1) % 3 == betValue;
        return false;
    }

    /// What this batch would pay if the ball landed on `spin`.
    function payoutForSpin(
        uint8[] memory betTypes, uint8[] memory betValues, uint128[] memory amounts, uint8 spin
    ) public pure returns (uint256 total) {
        for (uint256 i = 0; i < betTypes.length; i++) {
            if (isWinner(betTypes[i], betValues[i], spin)) {
                total += uint256(amounts[i]) * multiplier(betTypes[i]);
            }
        }
    }

    /// The most this batch could ever win — what the bank must be able to pay.
    function worstCase(
        uint8[] memory betTypes, uint8[] memory betValues, uint128[] memory amounts
    ) public pure returns (uint256 worst) {
        for (uint8 spin = 0; spin <= 36; spin++) {
            uint256 p = payoutForSpin(betTypes, betValues, amounts, spin);
            if (p > worst) worst = p;
        }
    }

    /// Read a pending batch (for the UI / the croupier).
    function betInfo(uint256 commit) external view returns (
        uint128 totalAmount, uint128 maxWinnable, uint40 blockNo, address gambler,
        uint8[] memory betTypes, uint8[] memory betValues, uint128[] memory amounts
    ) {
        Batch storage b = batches[commit];
        return (b.totalAmount, b.maxWinnable, b.blockNo, b.gambler, b.betTypes, b.betValues, b.amounts);
    }

    /// Minimal view the croupier polls.
    function betOwner(uint256 commit) external view returns (address gambler, uint40 blockNo) {
        Batch storage b = batches[commit];
        return (b.gambler, b.blockNo);
    }

    // --- play ----------------------------------------------------------
    /// Lay every chip in one go; they all ride the SAME ball.
    function placeBets(
        uint8[] calldata betTypes,
        uint8[] calldata betValues,
        uint128[] calldata amounts,
        uint256 commitLastBlock,
        uint256 commit,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(!closed, "table closed");
        require(batches[commit].gambler == address(0), "commit used");
        require(block.number <= commitLastBlock, "commit expired");

        uint256 n = betTypes.length;
        require(n > 0 && n <= MAX_POSITIONS, "bad position count");
        require(betValues.length == n && amounts.length == n, "length mismatch");

        bytes32 signatureHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n64", commitLastBlock, commit));
        require(ecrecover(signatureHash, v, r, s) == secretSigner, "bad signature");

        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            require(validPosition(betTypes[i], betValues[i]), "bad position");
            require(amounts[i] >= minBet, "chip below minimum");
            total += amounts[i];
        }
        require(total <= maxBet, "batch over table limit");

        uint256 worst = worstCase(betTypes, betValues, amounts);
        require(worst > total ? worst - total <= maxProfit : true, "profit over table limit");

        require(token.transferFrom(msg.sender, address(this), total), "transferFrom failed");
        require(lockedInBets + worst <= token.balanceOf(address(this)), "bank cannot cover it");
        lockedInBets += worst;

        Batch storage b = batches[commit];
        b.totalAmount = uint128(total);
        b.maxWinnable = uint128(worst);
        b.blockNo = uint40(block.number);
        b.gambler = msg.sender;
        b.betTypes = betTypes;
        b.betValues = betValues;
        b.amounts = amounts;

        emit BetPlaced(commit, msg.sender, total, n);
    }

    /// One reveal, one ball, every chip paid at once.
    function settleBet(uint256 reveal) external {
        require(msg.sender == croupier, "not croupier");
        uint256 commit = uint256(keccak256(abi.encodePacked(reveal)));
        Batch storage b = batches[commit];
        address gambler = b.gambler;
        require(gambler != address(0), "no such bet");

        uint256 placeBlock = b.blockNo;
        require(block.number > placeBlock, "same block");
        require(block.number <= placeBlock + BET_EXPIRATION_BLOCKS, "bet expired, refund it");
        bytes32 bh = blockhash(placeBlock);
        require(bh != bytes32(0), "blockhash unavailable");

        uint8 spin = uint8(uint256(keccak256(abi.encodePacked(reveal, bh))) % 37);
        uint256 payout = payoutForSpin(b.betTypes, b.betValues, b.amounts, spin);
        uint256 totalAmount = b.totalAmount;

        lockedInBets -= b.maxWinnable;
        delete batches[commit];

        if (payout > 0) require(token.transfer(gambler, payout), "payout failed");
        emit BetSettled(commit, gambler, totalAmount, spin, payout);
    }

    /// Croupier vanished? Anyone can hand the whole batch back to the player.
    function refundBet(uint256 commit) external {
        Batch storage b = batches[commit];
        address gambler = b.gambler;
        require(gambler != address(0), "no such bet");
        require(block.number > uint256(b.blockNo) + BET_EXPIRATION_BLOCKS, "not expired yet");

        uint256 amount = b.totalAmount;
        lockedInBets -= b.maxWinnable;
        delete batches[commit];

        require(token.transfer(gambler, amount), "refund failed");
        emit BetRefunded(commit, gambler, amount);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * ArchitectRegistry — identity for The Desk.
 *
 * A name is the thing copy trading, referrals and the leaderboard all hang
 * off: you follow a person, not a hex string. Keeping it on-chain costs
 * ~$0.0002 here, and buys three properties an off-chain table cannot:
 * the referral link is verifiable by anyone, the fee router can resolve a
 * referrer without trusting our backend, and the name survives us.
 *
 * Non-custodial by construction: this contract never touches a token.
 */
contract ArchitectRegistry {
    error NameTaken();
    error NameInvalid();
    error AlreadyRegistered();
    error NotRegistered();
    error SelfReferral();
    error ReferrerUnknown();
    error ReferralLocked();
    error CooldownActive(uint64 until);

    /// A name is claimed once and kept. Changing it is allowed but rate
    /// limited, so a leaderboard identity cannot be swapped every block to
    /// dodge a reputation.
    uint64 public constant RENAME_COOLDOWN = 7 days;
    uint8  public constant MIN_LEN = 3;
    uint8  public constant MAX_LEN = 20;

    struct Account {
        bytes32 nameHash;      // keccak of the lowercased name
        address referrer;      // set once, never changes
        uint64  since;
        uint64  renameAfter;
    }

    mapping(address => Account) public accounts;
    mapping(bytes32 => address) public ownerOfName;
    mapping(address => string)  public nameOf;          // display form, as typed
    mapping(address => uint32)  public referralCount;

    uint32 public totalAccounts;

    event Registered(address indexed user, string name, address indexed referrer);
    event Renamed(address indexed user, string oldName, string newName);
    event ReferralBound(address indexed user, address indexed referrer);

    // ── claiming ───────────────────────────────────────────────────────────
    /// @param name  3-20 chars, [a-z0-9_], case preserved for display
    /// @param referrer  zero address if none. Set once and permanent: a
    ///        referrer that can be rewritten is a referrer that gets stolen.
    function register(string calldata name, address referrer) external {
        Account storage a = accounts[msg.sender];
        if (a.since != 0) revert AlreadyRegistered();

        bytes32 h = _normalize(name);
        if (ownerOfName[h] != address(0)) revert NameTaken();

        if (referrer != address(0)) {
            if (referrer == msg.sender) revert SelfReferral();
            if (accounts[referrer].since == 0) revert ReferrerUnknown();
            a.referrer = referrer;
            unchecked { referralCount[referrer] += 1; }
            emit ReferralBound(msg.sender, referrer);
        }

        a.nameHash = h;
        a.since = uint64(block.timestamp);
        a.renameAfter = uint64(block.timestamp) + RENAME_COOLDOWN;
        ownerOfName[h] = msg.sender;
        nameOf[msg.sender] = name;
        unchecked { totalAccounts += 1; }

        emit Registered(msg.sender, name, referrer);
    }

    function rename(string calldata newName) external {
        Account storage a = accounts[msg.sender];
        if (a.since == 0) revert NotRegistered();
        if (block.timestamp < a.renameAfter) revert CooldownActive(a.renameAfter);

        bytes32 h = _normalize(newName);
        if (ownerOfName[h] != address(0)) revert NameTaken();

        string memory old = nameOf[msg.sender];
        delete ownerOfName[a.nameHash];
        a.nameHash = h;
        a.renameAfter = uint64(block.timestamp) + RENAME_COOLDOWN;
        ownerOfName[h] = msg.sender;
        nameOf[msg.sender] = newName;

        emit Renamed(msg.sender, old, newName);
    }

    /// Bind a referrer after the fact — only if none was ever set.
    function setReferrer(address referrer) external {
        Account storage a = accounts[msg.sender];
        if (a.since == 0) revert NotRegistered();
        if (a.referrer != address(0)) revert ReferralLocked();
        if (referrer == msg.sender) revert SelfReferral();
        if (accounts[referrer].since == 0) revert ReferrerUnknown();
        a.referrer = referrer;
        unchecked { referralCount[referrer] += 1; }
        emit ReferralBound(msg.sender, referrer);
    }

    // ── reads the fee router and the UI use ────────────────────────────────
    function referrerOf(address user) external view returns (address) {
        return accounts[user].referrer;
    }

    function resolve(string calldata name) external view returns (address) {
        return ownerOfName[_hash(name)];
    }

    function isAvailable(string calldata name) external view returns (bool) {
        if (!_valid(name)) return false;
        return ownerOfName[_hash(name)] == address(0);
    }

    function profile(address user)
        external view returns (string memory name, address referrer, uint64 since, uint32 refs)
    {
        Account storage a = accounts[user];
        return (nameOf[user], a.referrer, a.since, referralCount[user]);
    }

    // ── validation ─────────────────────────────────────────────────────────
    function _normalize(string calldata name) internal pure returns (bytes32) {
        if (!_valid(name)) revert NameInvalid();
        return _hash(name);
    }

    /// Lowercase before hashing so "Architect" and "architect" are the same
    /// identity and nobody can impersonate by case.
    function _hash(string calldata name) internal pure returns (bytes32) {
        bytes memory b = bytes(name);
        for (uint256 i; i < b.length; ++i) {
            uint8 c = uint8(b[i]);
            if (c >= 0x41 && c <= 0x5A) b[i] = bytes1(c + 32);
        }
        return keccak256(b);
    }

    function _valid(string calldata name) internal pure returns (bool) {
        bytes memory b = bytes(name);
        if (b.length < MIN_LEN || b.length > MAX_LEN) return false;
        for (uint256 i; i < b.length; ++i) {
            uint8 c = uint8(b[i]);
            bool ok = (c >= 0x61 && c <= 0x7A)        // a-z
                   || (c >= 0x41 && c <= 0x5A)        // A-Z
                   || (c >= 0x30 && c <= 0x39)        // 0-9
                   || c == 0x5F;                      // _
            if (!ok) return false;
        }
        // no leading or trailing underscore: keeps names readable in a list
        if (b[0] == 0x5F || b[b.length - 1] == 0x5F) return false;
        return true;
    }
}

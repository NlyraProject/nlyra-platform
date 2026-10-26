// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*  Mocks SOLO para el fork test (test/forktest-bsc.js). No se deployan en mainnet.
      - MockTaxToken:      fee-on-transfer (tax en cada transfer, salvo exentos). El caso "token con tax que se cuela".
      - MockBlockingToken: revierte transfer a una direccion bloqueada (blacklist / honeypot de salida).
      - MockFalseToken:    devuelve false (sin revertir) en transfer a una direccion bloqueada.
      - GreedyReceiver:    contrato maker/usuario con receive() que revierte a voluntad (prueba pendingEth / withdrawEth).
*/

contract MockERC20 {
    string public name; string public symbol; uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    constructor(string memory n, string memory s, uint8 d) { name = n; symbol = s; decimals = d; }
    function mint(address to, uint256 amt) external { totalSupply += amt; balanceOf[to] += amt; emit Transfer(address(0), to, amt); }
    function approve(address sp, uint256 amt) external returns (bool) { allowance[msg.sender][sp] = amt; emit Approval(msg.sender, sp, amt); return true; }
    function transfer(address to, uint256 amt) external virtual returns (bool) { return _move(msg.sender, to, amt); }
    function transferFrom(address from, address to, uint256 amt) external virtual returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) { require(a >= amt, "allowance"); allowance[from][msg.sender] = a - amt; }
        return _move(from, to, amt);
    }
    function _move(address from, address to, uint256 amt) internal virtual returns (bool) {
        require(balanceOf[from] >= amt, "balance");
        balanceOf[from] -= amt; balanceOf[to] += amt; emit Transfer(from, to, amt); return true;
    }
}

/// Tax de `taxBps` en cada transferencia (el que recibe cobra menos; el tax va a taxWallet). Exentos: sin tax.
contract MockTaxToken is MockERC20 {
    uint256 public taxBps; address public taxWallet;
    mapping(address => bool) public exempt;
    constructor(uint256 bps, address wallet) MockERC20("Mock Tax Token", "TAXD", 18) { taxBps = bps; taxWallet = wallet; }
    function setExempt(address a, bool v) external { exempt[a] = v; }
    function _move(address from, address to, uint256 amt) internal override returns (bool) {
        require(balanceOf[from] >= amt, "balance");
        balanceOf[from] -= amt;
        uint256 tax = (exempt[from] || exempt[to]) ? 0 : (amt * taxBps) / 10_000;
        balanceOf[to] += amt - tax;
        if (tax != 0) balanceOf[taxWallet] += tax;
        emit Transfer(from, to, amt - tax);
        return true;
    }
}

/// Revierte cualquier transferencia hacia una direccion bloqueada.
contract MockBlockingToken is MockERC20 {
    mapping(address => bool) public blocked;
    constructor() MockERC20("Mock Blocking Token", "BLCK", 18) {}
    function setBlocked(address a, bool v) external { blocked[a] = v; }
    function _move(address from, address to, uint256 amt) internal override returns (bool) {
        require(!blocked[to], "BLOCKED");
        return super._move(from, to, amt);
    }
}

/// Devuelve false (sin revertir) en transferencias hacia una direccion bloqueada.
contract MockFalseToken is MockERC20 {
    mapping(address => bool) public blocked;
    constructor() MockERC20("Mock False Token", "FALS", 18) {}
    function setBlocked(address a, bool v) external { blocked[a] = v; }
    function _move(address from, address to, uint256 amt) internal override returns (bool) {
        if (blocked[to]) return false;
        return super._move(from, to, amt);
    }
}

/// Maker/usuario contrato: receive() revierte cuando `reject` esta prendido. exec() reenvia cualquier llamada.
contract GreedyReceiver {
    bool public reject;
    function setReject(bool v) external { reject = v; }
    receive() external payable { if (reject) revert("no"); }
    function exec(address target, bytes calldata data) external payable returns (bytes memory) {
        (bool ok, bytes memory r) = target.call{value: msg.value}(data);
        if (!ok) { assembly ("memory-safe") { revert(add(r, 32), mload(r)) } }
        return r;
    }
}

/// Reflexion: en cada transferencia el que MANDA recibe el 1 % de lo que mando (como un token RFI que reparte a
/// todos los holders, el que envia incluido). El saldo del que manda baja menos que `amt` aunque la transferencia
/// salio entera: es el caso que hacia cobrar dos veces al maker (revision 24/10).
contract MockReflectToken is MockERC20 {
    constructor() MockERC20("Mock Reflect Token", "REFL", 18) {}
    function _move(address from, address to, uint256 amt) internal override returns (bool) {
        bool r = super._move(from, to, amt);
        uint256 refl = amt / 100;
        if (refl != 0 && from != address(0)) { totalSupply += refl; balanceOf[from] += refl; emit Transfer(address(0), from, refl); }
        return r;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*  ArchitectBotBase - esqueleto compartido por los bots escrow de The Desk
    ---------------------------------------------------------------------------
    Mismo patron que ArchitectLadder / ArchitectMartingale: fondos en ESTE
    contrato, keeper allowlisteado que solo TIMEA, ruta fija por hash, router v2
    con swapWithFee / swapETH / swapToETH, rescue solo del exceso, ownership en
    2 pasos, pause (solo bloquea fills: stop / refund siempre funcionan), lock
    TSTORE, pagos en ETH con techo de gas + pendingEth.

    El quote vive como WETH dentro del contrato (escrowed[WETH]); el base como
    el token (escrowed[token]). _buy / _sell dejan el resultado ACA y lo miden
    por delta de balance. Los contratos hijos hacen la contabilidad por bot.
*/

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface IArchitectRouter {
    function WETH() external view returns (address);
    function minFeeBps() external view returns (uint16);
    function maxFeeBps() external view returns (uint16);
    function swapWithFee(
        address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut,
        address recipient, uint16 feeBps, address referrer, uint256 deadline, bytes calldata route
    ) external returns (uint256 amountOut);
    function swapETH(address tokenOut, uint256 minAmountOut, uint16 feeBps, address referrer, uint256 deadline, bytes calldata route)
        external payable returns (uint256 amountOut);
    function swapToETH(address tokenIn, uint256 amountIn, uint256 minAmountOut, uint16 feeBps, address referrer, uint256 deadline, bytes calldata route)
        external returns (uint256 amountOut);
}

/// PoolKey de Uniswap V4 (solo para detectar currency0 == ETH nativo en la ruta)
struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }

abstract contract ArchitectBotBase {
    uint8   internal constant ROUTE_V4 = 2;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant Q = 1e18;          // escala de precios: quoteWei * 1e18 / baseRaw

    enum Status { Open, Stopped }

    IArchitectRouter public immutable ROUTER;
    address          public immutable WETH;

    address public owner;
    address public pendingOwner;
    bool    public paused;
    uint256 public count;
    mapping(address => bool)    public isKeeper;
    mapping(address => uint256) public escrowed;      // token => total escrowado (fondos de usuarios)
    mapping(address => uint256) public pendingEth;    // pagos en ETH que rebotaron

    /// @dev maker es topic 2 (la tape atribuye el fill al maker). level: indice (spot) o k (infinity). side 0 BUY, 1 SELL. profit en quote (solo SELL).
    event GridFilled(bytes32 indexed id, address indexed maker, address indexed keeper, int256 level, uint8 side, uint256 amountIn, uint256 amountOut, uint256 profit);
    /// @param kind 0 stop sellAll, 1 stop keep, 2 expired, 3 stop-loss, 4 take-profit
    event GridStopped(bytes32 indexed id, address indexed maker, uint8 kind, uint256 baseSold, uint256 proceeds, uint256 baseReturned, uint256 quoteReturned);
    event KeeperSet(address keeper, bool allowed);
    event EthPending(address indexed to, uint256 amount);
    event EthWithdrawn(address indexed to, uint256 amount);
    event PausedSet(bool paused);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOwner();
    error NotMaker();
    error NotKeeper();
    error Expired();
    error NotExpired();
    error NotOpen();
    error BadParams();
    error BadGrid();
    error BadFee();
    error BadRouteHash();
    error BadValue();
    error BadLevel();
    error BelowFloor();
    error NothingToSell();
    error InsufficientBudget();
    error InsufficientOutput(uint256 got, uint256 want);
    error PriceNotReached(uint256 got, uint256 want);
    error TransferFailed();
    error IsPaused();
    error ZeroAddress();
    error NothingToRefund();

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }
    modifier onlyKeeper() { if (!isKeeper[msg.sender]) revert NotKeeper(); _; }
    modifier whenNotPaused() { if (paused) revert IsPaused(); _; }

    modifier lock() {
        // reentrancy guard transitorio (TSTORE: evmVersion cancun)
        assembly ("memory-safe") { if tload(0) { mstore(0, 0) revert(0, 0) } tstore(0, 1) }
        _;
        assembly ("memory-safe") { tstore(0, 0) }
    }

    /// @param router ArchitectFeeRouter v2 (este contrato debe estar en su allowlist de callers)
    /// @param weth   debe coincidir con router.WETH()
    /// @param keeper primer keeper allowlisteado (puede ser address(0))
    constructor(address router, address weth, address keeper) {
        if (router == address(0) || weth == address(0)) revert ZeroAddress();
        if (IArchitectRouter(router).WETH() != weth) revert BadGrid();
        ROUTER = IArchitectRouter(router);
        WETH   = weth;
        owner  = msg.sender;
        if (keeper != address(0)) { isKeeper[keeper] = true; emit KeeperSet(keeper, true); }
    }

    /// ETH entra solo desde el router (swapToETH) o desde WETH (withdraw).
    receive() external payable {
        if (msg.sender != address(ROUTER) && msg.sender != WETH) revert BadGrid();
    }

    // ------------------------------ comun ------------------------------

    function _newId() internal returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), ++count, msg.sender));
    }

    function _checkCommon(address token, uint64 expiry, uint16 feeBps) internal view {
        if (token == address(0) || token == WETH) revert BadGrid();
        if (expiry <= block.timestamp) revert Expired();
        if (feeBps < ROUTER.minFeeBps() || feeBps > ROUTER.maxFeeBps()) revert BadFee();
    }

    /// Envuelve msg.value y lo escrowa como WETH.
    function _wrap(uint256 amount) internal {
        if (amount == 0) return;
        IWETH(WETH).deposit{value: amount}();
        escrowed[WETH] += amount;
    }

    /// Compra: WETH -> token; el token queda ACA. Salida medida por delta de balance. NO toca escrowed.
    function _buy(address token, uint16 feeBps, address referrer, uint256 amountIn, uint256 minOut, bytes calldata route)
        internal returns (uint256 amountOut)
    {
        if (minOut == 0) revert BadParams();
        uint256 before = IERC20(token).balanceOf(address(this));
        if (_routeIsNativeV4(route)) {
            IWETH(WETH).withdraw(amountIn);
            ROUTER.swapETH{value: amountIn}(token, minOut, feeBps, address(0), block.timestamp, route);
        } else {
            _approve(WETH, address(ROUTER), amountIn);
            ROUTER.swapWithFee(WETH, token, amountIn, minOut, address(this), feeBps, referrer, block.timestamp, route);
        }
        amountOut = IERC20(token).balanceOf(address(this)) - before;
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
    }

    /// Venta: token -> WETH; el WETH queda ACA (en V4 nativo el ETH se re-envuelve). NO toca escrowed.
    function _sell(address token, uint16 feeBps, address referrer, uint256 amountIn, uint256 minOut, bytes calldata route)
        internal returns (uint256 amountOut)
    {
        if (minOut == 0) revert BadParams();
        _approve(token, address(ROUTER), amountIn);
        if (_routeIsNativeV4(route)) {
            uint256 before = address(this).balance;
            ROUTER.swapToETH(token, amountIn, minOut, feeBps, address(0), block.timestamp, route);
            amountOut = address(this).balance - before;
            IWETH(WETH).deposit{value: amountOut}();
        } else {
            uint256 before = IERC20(WETH).balanceOf(address(this));
            ROUTER.swapWithFee(token, WETH, amountIn, minOut, address(this), feeBps, referrer, block.timestamp, route);
            amountOut = IERC20(WETH).balanceOf(address(this)) - before;
        }
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
    }

    /// Cierre: des-escrowa base + quote; vende el base (sell) o lo devuelve; el ETH (quote + proceeds) va al maker.
    function _settle(address token, uint16 feeBps, address referrer, address maker, uint256 base, uint256 quote, bytes calldata route, uint256 minOut, bool sell)
        internal returns (uint256 proceeds, uint256 baseRet)
    {
        escrowed[token] -= base;
        escrowed[WETH]  -= quote;
        if (sell && base != 0) proceeds = _sell(token, feeBps, referrer, base, minOut, route);
        else if (base != 0) { _send(token, maker, base); baseRet = base; }
        uint256 eth = quote + proceeds;
        if (eth != 0) { IWETH(WETH).withdraw(eth); _payEth(maker, eth); }
    }

    // ------------------------------ transferencias ------------------------------

    function _pull(address token, address from, uint256 amount) internal {
        uint256 before = IERC20(token).balanceOf(address(this));
        (bool ok, bytes memory d) = token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, address(this), amount));
        if (!ok || (d.length != 0 && !abi.decode(d, (bool)))) revert TransferFailed();
        // fee-on-transfer que entregue menos de lo declarado: revierte en vez de dejar un bot corto
        if (IERC20(token).balanceOf(address(this)) - before < amount) revert TransferFailed();
    }
    /// Aprobacion exacta: el router tira justo amountIn, no queda allowance viva.
    function _approve(address token, address spender, uint256 amount) internal {
        (bool ok0, bytes memory d0) = token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, 0));
        if (!ok0 || (d0.length != 0 && !abi.decode(d0, (bool)))) revert TransferFailed();
        (bool ok, bytes memory d) = token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
        if (!ok || (d.length != 0 && !abi.decode(d, (bool)))) revert TransferFailed();
    }
    function _send(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory d) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!ok || (d.length != 0 && !abi.decode(d, (bool)))) revert TransferFailed();
    }
    /// Pago en ETH con techo de gas: un maker contrato con receive() caro no bloquea nada; el ETH queda reclamable con withdrawEth().
    function _payEth(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount, gas: 30_000}("");
        if (!ok) { pendingEth[to] += amount; emit EthPending(to, amount); }
    }
    function withdrawEth() external lock returns (uint256 amount) {
        amount = pendingEth[msg.sender];
        pendingEth[msg.sender] = 0;
        if (amount != 0) {
            (bool ok,) = msg.sender.call{value: amount}("");
            if (!ok) revert TransferFailed();
            emit EthWithdrawn(msg.sender, amount);
        }
    }

    function _routeIsNativeV4(bytes calldata route) internal pure returns (bool) {
        (uint8 kind, bytes memory payload) = abi.decode(route, (uint8, bytes));
        if (kind != ROUTE_V4) return false;
        (PoolKey memory key,) = abi.decode(payload, (PoolKey, bytes));
        return key.currency0 == address(0);
    }

    // ------------------------------ admin ------------------------------

    function setKeeper(address k, bool allowed) external onlyOwner { isKeeper[k] = allowed; emit KeeperSet(k, allowed); }
    function setPaused(bool v) external onlyOwner { paused = v; emit PausedSet(v); }

    /// @notice Saca solo lo que NO esta escrowado (tokens enviados por error). Nunca fondos de usuarios.
    function rescue(address token, address to) external onlyOwner lock {
        if (to == address(0)) revert ZeroAddress();
        uint256 excess = IERC20(token).balanceOf(address(this)) - escrowed[token];
        if (excess == 0) revert NothingToRefund();
        _send(token, to, excess);
    }

    function transferOwnership(address n) external onlyOwner {
        if (n == address(0)) revert ZeroAddress();
        pendingOwner = n;
        emit OwnershipTransferStarted(owner, n);
    }
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }
}

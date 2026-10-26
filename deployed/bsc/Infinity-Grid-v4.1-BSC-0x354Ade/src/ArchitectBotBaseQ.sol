// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*  ArchitectBotBaseQ (BSC, v4.1) - esqueleto compartido por los bots escrow de The Desk en BNB Smart Chain,
    con QUOTE POR GRID: WBNB (como siempre) o un ERC20 que el router acepta como quote (USDT, USDC).
    ---------------------------------------------------------------------------
    Es ArchitectBotBase (el que corre bajo ArchitectInfinityGridV4BSC desde el 24/10/2026) con una sola
    diferencia: _buy / _sell / _settle reciben el quote del grid en vez de asumir WBNB. Todo lo demas es
    identico: fondos en ESTE contrato, keeper allowlisteado que solo TIMEA, ruta fija por hash, router
    propio con swapWithFee, rescue solo del exceso, ownership en 2 pasos, pause (solo bloquea fills:
    stop / refund siempre funcionan), lock TSTORE, pagos en BNB con techo de gas + pendingEth,
    pendingToken para tokens que no se dejan transferir al cerrar.

    Que cambia con un quote ERC20 (y por que):
      1. El quote vive como escrowed[quote]; la reserva de gas sigue viviendo en WBNB (escrowed[WETH]),
         porque el keeper cobra su gas en WBNB y lo desenvuelve: un grid en USDT paga el gas en BNB igual.
      2. Al cerrar, el quote vuelve al maker como ERC20 (transfer); si el token lo rechaza queda en
         pendingToken[maker][quote] y se retira con withdrawToken(). Con quote WBNB vuelve como BNB nativo.
      3. El base puede ser WBNB cuando el quote es un ERC20 (un grid BNB/USDT): escrowed[WETH] suma
         entonces reservas de gas + base de esos grids, cada camino lo anota y lo descuenta por separado,
         asi que rescue() sigue viendo solo el exceso. Al devolver ese base se desenvuelve y va como BNB.
      4. Un quote ERC20 se trae con _pull (exige recibir lo declarado): un quote con fee-on-transfer no entra.
    Los contratos hijos hacen la contabilidad por bot.
*/

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

/// WBNB: misma interfaz que WETH9
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface IArchitectRouter {
    function WETH() external view returns (address);
    function minFeeBps() external view returns (uint16);
    function maxFeeBps() external view returns (uint16);
    function isQuoteToken(address) external view returns (bool);
    function swapWithFee(
        address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut,
        address recipient, uint16 feeBps, address referrer, uint256 deadline, bytes calldata route
    ) external returns (uint256 amountOut);
}

abstract contract ArchitectBotBaseQ {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant Q = 1e18;          // escala de precios: quoteWei * 1e18 / baseRaw

    /// @notice Cotas duras de los limites de precio de gas que el owner puede fijar.
    uint256 public constant MAX_GAS_PRICE_FLOOR = 1 gwei;
    uint256 public constant MAX_GAS_PRICE_CAP   = 50 gwei;

    enum Status { Open, Stopped }

    IArchitectRouter public immutable ROUTER;
    /// @notice WBNB. Se llama WETH por compatibilidad de ABI con los bots de Robinhood Chain.
    address          public immutable WETH;

    address public owner;
    address public pendingOwner;
    bool    public paused;
    uint256 public count;
    mapping(address => bool)    public isKeeper;
    mapping(address => uint256) public escrowed;      // token => total escrowado (fondos de usuarios)
    mapping(address => uint256) public pendingEth;    // pagos en BNB que rebotaron
    /// @notice BSC: base (o quote ERC20) que al cerrar no se pudo entregar al maker. Sigue dentro de escrowed[token].
    mapping(address => mapping(address => uint256)) public pendingToken;

    /// @notice BSC: precio de gas efectivo = max(tx.gasprice, basefee) acotado a [floor, cap]. Ver _gasPrice().
    uint256 public gasPriceFloor = 0.05 gwei;      // minimo que aceptan los validadores de BSC (eth_gasPrice el 21/10/2026)
    uint256 public gasPriceCap   = 5 gwei;         // 5-100x el precio normal de BSC: el keeper nunca cobra mas que esto por gas

    /// @dev maker es topic 2 (la tape atribuye el fill al maker). level: indice (spot) o k (infinity). side 0 BUY, 1 SELL. profit en quote (solo SELL).
    event GridFilled(bytes32 indexed id, address indexed maker, address indexed keeper, int256 level, uint8 side, uint256 amountIn, uint256 amountOut, uint256 profit);
    /// @param kind 0 stop sellAll, 1 stop keep, 2 expired, 3 stop-loss, 4 take-profit
    event GridStopped(bytes32 indexed id, address indexed maker, uint8 kind, uint256 baseSold, uint256 proceeds, uint256 baseReturned, uint256 quoteReturned);
    event KeeperSet(address keeper, bool allowed);
    event EthPending(address indexed to, uint256 amount);
    event EthWithdrawn(address indexed to, uint256 amount);
    /// @dev BSC: el base (o el quote ERC20) de un cierre quedo reclamable (el token rechazo la transferencia al maker).
    event TokenPending(address indexed to, address indexed token, uint256 amount);
    event TokenWithdrawn(address indexed to, address indexed token, uint256 amount);
    event GasPriceBoundsSet(uint256 floor, uint256 cap);
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
        // reentrancy guard transitorio (TSTORE: evmVersion cancun; BSC lo tiene desde Tycho, jun-2024)
        assembly ("memory-safe") { if tload(0) { mstore(0, 0) revert(0, 0) } tstore(0, 1) }
        _;
        assembly ("memory-safe") { tstore(0, 0) }
    }

    /// @param router ArchitectFeeRouterBSC (este contrato debe estar en su allowlist de callers)
    /// @param weth   WBNB; debe coincidir con router.WETH()
    /// @param keeper primer keeper allowlisteado (puede ser address(0))
    constructor(address router, address weth, address keeper) {
        if (router == address(0) || weth == address(0)) revert ZeroAddress();
        if (IArchitectRouter(router).WETH() != weth) revert BadGrid();
        ROUTER = IArchitectRouter(router);
        WETH   = weth;
        owner  = msg.sender;
        if (keeper != address(0)) { isKeeper[keeper] = true; emit KeeperSet(keeper, true); }
    }

    /// @notice Alias explicito de WETH() para BSC.
    function WBNB() external view returns (address) { return WETH; }

    /// BNB entra solo desde el router o desde WBNB (withdraw).
    receive() external payable virtual {
        if (msg.sender != address(ROUTER) && msg.sender != WETH) revert BadGrid();
    }

    // ------------------------------ comun ------------------------------

    function _newId() internal returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), ++count, msg.sender));
    }

    /// Grid con quote WBNB: el base no puede ser WBNB.
    function _checkCommon(address token, uint64 expiry, uint16 feeBps) internal view {
        if (token == address(0) || token == WETH) revert BadGrid();
        _checkTerms(expiry, feeBps);
    }
    /// v4.1: grid con quote ERC20. El quote tiene que estar en la lista del router (USDT, USDC) y no ser WBNB
    /// (para eso esta openWithEth); el base puede ser WBNB (grid BNB/USDT) pero nunca el propio quote.
    function _checkQuote(address token, address quote, uint64 expiry, uint16 feeBps) internal view {
        if (token == address(0) || quote == address(0) || quote == WETH || token == quote) revert BadGrid();
        if (!ROUTER.isQuoteToken(quote)) revert BadGrid();
        _checkTerms(expiry, feeBps);
    }
    function _checkTerms(uint64 expiry, uint16 feeBps) internal view {
        if (expiry <= block.timestamp) revert Expired();
        if (feeBps < ROUTER.minFeeBps() || feeBps > ROUTER.maxFeeBps()) revert BadFee();
    }

    /// BSC: precio de gas que se le cobra al grid por cada unidad. Ver la cabecera de ArchitectBotBase (punto 3).
    function _gasPrice() internal view returns (uint256 price) {
        price = tx.gasprice > block.basefee ? tx.gasprice : block.basefee;
        if (price < gasPriceFloor) price = gasPriceFloor;
        if (price > gasPriceCap) price = gasPriceCap;
    }

    /// Envuelve msg.value y lo escrowa como WBNB.
    function _wrap(uint256 amount) internal {
        if (amount == 0) return;
        IWETH(WETH).deposit{value: amount}();
        escrowed[WETH] += amount;
    }

    /// Compra: quote -> token; el token queda ACA. Salida medida por delta de balance. NO toca escrowed.
    function _buy(address quote, address token, uint16 feeBps, address referrer, uint256 amountIn, uint256 minOut, bytes calldata route)
        internal returns (uint256 amountOut)
    {
        if (minOut == 0) revert BadParams();
        uint256 before = IERC20(token).balanceOf(address(this));
        _approve(quote, address(ROUTER), amountIn);
        ROUTER.swapWithFee(quote, token, amountIn, minOut, address(this), feeBps, referrer, block.timestamp, route);
        amountOut = IERC20(token).balanceOf(address(this)) - before;
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
    }

    /// Venta: token -> quote; el quote queda ACA. NO toca escrowed.
    function _sell(address token, address quote, uint16 feeBps, address referrer, uint256 amountIn, uint256 minOut, bytes calldata route)
        internal returns (uint256 amountOut)
    {
        if (minOut == 0) revert BadParams();
        _approve(token, address(ROUTER), amountIn);
        uint256 before = IERC20(quote).balanceOf(address(this));
        ROUTER.swapWithFee(token, quote, amountIn, minOut, address(this), feeBps, referrer, block.timestamp, route);
        amountOut = IERC20(quote).balanceOf(address(this)) - before;
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
    }

    /// Cierre: des-escrowa quote (+ base si se vende o se entrega); vende el base (sell) o lo devuelve; el quote (+ proceeds) va al maker:
    /// como BNB nativo si el quote es WBNB, como ERC20 si no. BSC: si un token rechaza la transferencia al maker, lo que no se pudo
    /// entregar queda en pendingToken (sigue escrowado) y el resto vuelve igual. Un base WBNB se devuelve desenvuelto, como BNB.
    function _settle(address token, address quote, uint16 feeBps, address referrer, address maker, uint256 base, uint256 quoteAmt, bytes calldata route, uint256 minOut, bool sell)
        internal returns (uint256 proceeds, uint256 baseRet)
    {
        escrowed[quote] -= quoteAmt;
        if (sell && base != 0) {
            escrowed[token] -= base;
            proceeds = _sell(token, quote, feeBps, referrer, base, minOut, route);
        } else if (base != 0) {
            if (token == WETH) { escrowed[WETH] -= base; IWETH(WETH).withdraw(base); _payEth(maker, base); baseRet = base; }
            else if (_trySend(token, maker, base)) { escrowed[token] -= base; baseRet = base; }
            else { pendingToken[maker][token] += base; emit TokenPending(maker, token, base); }
        }
        uint256 out = quoteAmt + proceeds;
        if (out != 0) {
            if (quote == WETH) { IWETH(WETH).withdraw(out); _payEth(maker, out); }
            else if (!_trySend(quote, maker, out)) { escrowed[quote] += out; pendingToken[maker][quote] += out; emit TokenPending(maker, quote, out); }
        }
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
    /// Transferencia que NO revierte: false solo si la llamada revierte o devuelve false (ahi el token no se movio
    /// y queda en pendingToken). Si la llamada salio bien el token YA se entrego, aunque el saldo de este contrato no
    /// baje exactamente `amount` (un token con reflexion le acredita al contrato en la misma transferencia).
    function _trySend(address token, address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory d) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        return ok && (d.length == 0 || (d.length >= 32 && abi.decode(d, (bool))));
    }
    /// Pago en BNB con techo de gas: un maker contrato con receive() caro no bloquea nada; el BNB queda reclamable con withdrawEth().
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
    /// @notice BSC: el maker retira el base (o el quote ERC20) que un cierre no pudo entregarle (sale del escrow recien aca).
    function withdrawToken(address token) external lock returns (uint256 amount) {
        amount = pendingToken[msg.sender][token];
        if (amount == 0) revert NothingToRefund();
        pendingToken[msg.sender][token] = 0;
        escrowed[token] -= amount;
        _send(token, msg.sender, amount);
        emit TokenWithdrawn(msg.sender, token, amount);
    }

    // ------------------------------ admin ------------------------------

    function setKeeper(address k, bool allowed) external onlyOwner { isKeeper[k] = allowed; emit KeeperSet(k, allowed); }
    function setPaused(bool v) external onlyOwner { paused = v; emit PausedSet(v); }

    /// @notice BSC: limites del precio de gas que se cobra de la reserva. floor <= cap, acotados por las constantes.
    function setGasPriceBounds(uint256 floor_, uint256 cap_) external onlyOwner {
        if (floor_ > MAX_GAS_PRICE_FLOOR || cap_ > MAX_GAS_PRICE_CAP || floor_ > cap_ || cap_ == 0) revert BadParams();
        gasPriceFloor = floor_;
        gasPriceCap = cap_;
        emit GasPriceBoundsSet(floor_, cap_);
    }

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

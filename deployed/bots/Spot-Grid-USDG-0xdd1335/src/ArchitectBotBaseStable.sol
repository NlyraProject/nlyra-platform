// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*  ArchitectBotBaseStable - esqueleto compartido por los bots escrow de The Desk
    con QUOTE ERC20 (USDG, 6 decimales) en vez de WETH/ETH nativo.
    ---------------------------------------------------------------------------
    Es ArchitectBotBase con la capa de quote reemplazada, punto por punto:

      ArchitectBotBase (WETH)                ArchitectBotBaseStable (USDG)
      ------------------------------------   ------------------------------------
      fondeo con msg.value + _wrap()          fondeo con _pullQuote() (transferFrom)
      retiro: IWETH.withdraw + _payEth        retiro: transfer ERC20 (_pay)
      receive() payable                       NO EXISTE (el contrato no toca ETH)
      swapETH / swapToETH (ruta V4 nativa)    NO SE USAN: siempre swapWithFee token<->token
      pendingEth / withdrawEth                pending[to][token] / withdrawPending
      IERC20 con decode(bool) crudo           SafeT (acepta returndata vacia, exige code.length)

    Invariantes que NO cambian:
      - los fondos viven en ESTE contrato, contabilizados en escrowed[token];
      - el keeper solo TIMEA: los minimos de cada swap los calcula el contrato
        a partir de los precios que fijo el maker, y la ruta esta clavada por hash;
      - el maker puede retirar SIEMPRE (stop / refundExpired no son pausables y no
        llaman al router si sellAll == false);
      - el owner no puede tocar fondos de usuarios (rescue solo saca el exceso);
      - lock TSTORE en todo camino de fondos, CEI estricto.

    NOTA DE SEGURIDAD - callback de swap: este contrato NO tiene receive(), NO tiene
    fallback() y NO implementa ningun *Callback (uniswapV3SwapCallback, unlockCallback,
    etc). Los callbacks viven en ArchitectFeeRouter, que los protege con el patron
    "armar antes / exigir el pool canonico / limpiar despues" (transient _CB_TOKEN_IN /
    _CB_TOKEN_OUT / _CB_FEE + msg.sender == V3_FACTORY.getPool(...), y
    msg.sender == V4_POOL_MANAGER en unlockCallback). Al no exponer ninguna superficie
    de callback aca, no hay forma de que un pool o un hook entre a este contrato:
    la unica reentrada posible es via el token base durante un transfer, y todos los
    caminos de fondos estan bajo lock().
*/

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IArchitectRouter {
    function WETH() external view returns (address);
    function minFeeBps() external view returns (uint16);
    function maxFeeBps() external view returns (uint16);
    function isQuoteToken(address) external view returns (bool);
    function isCaller(address) external view returns (bool);
    /// El unico camino de swap que usa esta variante: token <-> token, sin ETH nativo.
    function swapWithFee(
        address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut,
        address recipient, uint16 feeBps, address referrer, uint256 deadline, bytes calldata route
    ) external returns (uint256 amountOut);
}

/*  SafeT - SafeERC20 minimo.
    USDG es un proxy upgradeable: no se asume que devuelva bool, ni que el bool sea
    decodificable, ni que el token sea un contrato. Un `.call` a una EOA devuelve
    ok == true con returndata vacia; sin el chequeo de code.length un "token" que no
    es contrato pareceria transferir con exito.  */
library SafeT {
    error TransferFailed();
    error NotAContract();

    function _ok(bool ok, bytes memory d) private pure returns (bool) {
        if (!ok) return false;
        if (d.length == 0) return true;
        if (d.length < 32) return false;
        return abi.decode(d, (bool));
    }

    /// Transfer que NO revierte: devuelve false y deja que el llamador decida (pending).
    function trySend(address t, address to, uint256 a) internal returns (bool) {
        if (t.code.length == 0) return false;
        (bool ok, bytes memory d) = t.call(abi.encodeWithSelector(IERC20.transfer.selector, to, a));
        return _ok(ok, d);
    }

    function safeTransfer(address t, address to, uint256 a) internal {
        if (!trySend(t, to, a)) revert TransferFailed();
    }

    function safeTransferFrom(address t, address f, address to, uint256 a) internal {
        if (t.code.length == 0) revert NotAContract();
        (bool ok, bytes memory d) = t.call(abi.encodeWithSelector(IERC20.transferFrom.selector, f, to, a));
        if (!_ok(ok, d)) revert TransferFailed();
    }

    /// Aprobacion exacta con reset a 0 primero (USDT y clones lo exigen).
    function safeApprove(address t, address s, uint256 a) internal {
        if (t.code.length == 0) revert NotAContract();
        (bool ok0, bytes memory d0) = t.call(abi.encodeWithSelector(IERC20.approve.selector, s, 0));
        if (!_ok(ok0, d0)) revert TransferFailed();
        if (a == 0) return;
        (bool ok, bytes memory d) = t.call(abi.encodeWithSelector(IERC20.approve.selector, s, a));
        if (!_ok(ok, d)) revert TransferFailed();
    }

    /// Revocacion best-effort: se llama DESPUES del swap, cuando el router ya tiro
    /// exactamente amountIn y la allowance deberia ser 0. Si un token raro revierte
    /// al re-aprobar 0, no queremos tumbar un fill que ya salio bien.
    function revokeBestEffort(address t, address s) internal {
        if (t.code.length == 0) return;
        (bool ok, bytes memory d) = t.call(abi.encodeWithSelector(IERC20.approve.selector, s, uint256(0)));
        ok; d;
    }
}

abstract contract ArchitectBotBaseStable {
    using SafeT for address;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant Q   = 1e18;          // escala de precios: quoteRaw * 1e18 / baseRaw

    /*  Resolucion minima de precio.
        P = quoteRaw * 1e18 / baseRaw. Con USDG de 6 decimales y un base de 18, un token
        a USD 0.000122 da P = 122: cada unidad de P vale 0.82% del precio. El grid exige
        gBps / stepBps >= 250 (2.5%), asi que con P >= 100 el redondeo del step (<= 1%)
        nunca lo vuelve nulo ni negativo. Por debajo de P = BPS/step = 40, la cuenta
        p * (BPS + s) / BPS devolveria el MISMO p: el nivel de venta seria igual al de
        compra y el bot venderia sin ganancia. MIN_PRICE = 100 deja margen 2.5x sobre eso.  */
    uint256 internal constant MIN_PRICE = 100;

    /*  Techo de precio: garantiza que base(uint128) * price no desborde ni con el
        factor BPS encima -> 2^128 * 2^112 * 2^14 = 2^254 < 2^256.  */
    uint256 internal constant MAX_PRICE = 2 ** 112;

    enum Status { Open, Stopped }

    IArchitectRouter public immutable ROUTER;
    address          public immutable QUOTE;           // USDG
    uint8            public immutable QUOTE_DECIMALS;  // 6
    uint256          public immutable MIN_QUOTE;       // 0.1 unidades de quote (100_000 con 6 dec)

    address public owner;
    address public pendingOwner;
    bool    public paused;
    uint256 public count;
    mapping(address => bool)    public isKeeper;
    mapping(address => uint256) public escrowed;                              // token => total escrowado
    mapping(address => mapping(address => uint256)) public pending;           // beneficiario => token => monto

    /// @dev maker es topic 2. level: indice (spot) o k (infinity). side 0 BUY, 1 SELL. profit en quote (solo SELL).
    event GridFilled(bytes32 indexed id, address indexed maker, address indexed keeper, int256 level, uint8 side, uint256 amountIn, uint256 amountOut, uint256 profit);
    /// @param kind 0 stop sellAll, 1 stop keep, 2 expired, 3 stop-loss, 4 take-profit
    event GridStopped(bytes32 indexed id, address indexed maker, uint8 kind, uint256 baseSold, uint256 proceeds, uint256 baseReturned, uint256 quoteReturned);
    event KeeperSet(address keeper, bool allowed);
    event TokenPending(address indexed to, address indexed token, uint256 amount);
    event TokenWithdrawn(address indexed to, address indexed token, uint256 amount);
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
    error PriceOutOfRange(uint256 price, uint256 min, uint256 max);
    error AmountTooSmall(uint256 got, uint256 min);
    error TransferFailed();
    error IsPaused();
    error ZeroAddress();
    error NothingToRefund();
    error NotQuoteToken();

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
    /// @param quote  token de quote, USDG. Tiene que estar marcado como isQuoteToken en el router:
    ///               de lo contrario el router cobraria la comision del lado equivocado (o revertiria
    ///               con NoQuoteToken al vender, porque allowExoticPairs esta en false).
    /// @param keeper primer keeper allowlisteado (puede ser address(0))
    constructor(address router, address quote, address keeper) {
        if (router == address(0) || quote == address(0)) revert ZeroAddress();
        if (quote.code.length == 0) revert BadGrid();
        if (!IArchitectRouter(router).isQuoteToken(quote)) revert NotQuoteToken();
        ROUTER = IArchitectRouter(router);
        QUOTE  = quote;
        uint8 d = IERC20(quote).decimals();
        if (d == 0 || d > 30) revert BadGrid();
        QUOTE_DECIMALS = d;
        MIN_QUOTE = 10 ** uint256(d) / 10;      // 0.1 USDG = 100_000 raw
        owner = msg.sender;
        if (keeper != address(0)) { isKeeper[keeper] = true; emit KeeperSet(keeper, true); }
    }

    // NO hay receive() ni fallback(): este contrato no recibe ni mueve ETH nativo.

    // ------------------------------ comun ------------------------------

    function _newId() internal returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), ++count, msg.sender));
    }

    function _checkCommon(address token, uint64 expiry, uint16 feeBps) internal view {
        if (token == address(0) || token == QUOTE) revert BadGrid();
        if (token.code.length == 0) revert BadGrid();
        if (expiry <= block.timestamp) revert Expired();
        if (feeBps < ROUTER.minFeeBps() || feeBps > ROUTER.maxFeeBps()) revert BadFee();
    }

    /// Todo precio que el maker fija (o que sale del seed) pasa por aca.
    function _checkPrice(uint256 p) internal pure {
        if (p < MIN_PRICE || p > MAX_PRICE) revert PriceOutOfRange(p, MIN_PRICE, MAX_PRICE);
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /// Cobra `amount` de quote al maker y lo escrowa. Reemplaza a msg.value + _wrap().
    function _pullQuote(uint256 amount) internal {
        if (amount == 0) return;
        _pull(QUOTE, msg.sender, amount);
        escrowed[QUOTE] += amount;
    }

    /// Compra: QUOTE -> token; el token queda ACA. Salida medida por delta de balance. NO toca escrowed.
    function _buy(address token, uint16 feeBps, address referrer, uint256 amountIn, uint256 minOut, bytes calldata route)
        internal returns (uint256 amountOut)
    {
        if (minOut == 0) revert BadParams();
        uint256 before = IERC20(token).balanceOf(address(this));
        QUOTE.safeApprove(address(ROUTER), amountIn);
        ROUTER.swapWithFee(QUOTE, token, amountIn, minOut, address(this), feeBps, referrer, block.timestamp, route);
        QUOTE.revokeBestEffort(address(ROUTER));
        amountOut = IERC20(token).balanceOf(address(this)) - before;
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
    }

    /// Venta: token -> QUOTE; el quote queda ACA. NO toca escrowed.
    function _sell(address token, uint16 feeBps, address referrer, uint256 amountIn, uint256 minOut, bytes calldata route)
        internal returns (uint256 amountOut)
    {
        if (minOut == 0) revert BadParams();
        uint256 before = IERC20(QUOTE).balanceOf(address(this));
        token.safeApprove(address(ROUTER), amountIn);
        ROUTER.swapWithFee(token, QUOTE, amountIn, minOut, address(this), feeBps, referrer, block.timestamp, route);
        token.revokeBestEffort(address(ROUTER));
        amountOut = IERC20(QUOTE).balanceOf(address(this)) - before;
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
    }

    /// Cierre: des-escrowa base + quote; vende el base (sell) o lo devuelve; el quote va a `to`.
    function _settle(address token, uint16 feeBps, address referrer, address to, uint256 base, uint256 quote, bytes calldata route, uint256 minOut, bool sell)
        internal returns (uint256 proceeds, uint256 baseRet)
    {
        escrowed[token] -= base;
        escrowed[QUOTE] -= quote;
        if (sell && base != 0) proceeds = _sell(token, feeBps, referrer, base, minOut, route);
        else if (base != 0) { _pay(token, to, base); baseRet = base; }
        uint256 q = quote + proceeds;
        if (q != 0) _pay(QUOTE, to, q);
    }

    // ------------------------------ transferencias ------------------------------

    function _pull(address token, address from, uint256 amount) internal {
        uint256 before = IERC20(token).balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        // fee-on-transfer que entregue menos de lo declarado: revierte en vez de dejar un bot corto
        if (IERC20(token).balanceOf(address(this)) - before < amount) revert TransferFailed();
    }

    /*  Pago que NUNCA revierte.
        USDG es una stable regulada: puede congelar una direccion. Si el transfer al maker
        falla (blacklist, o un token base roto), el monto se acredita como `pending` y el
        maker lo retira despues a la direccion que quiera con withdrawPending(token, to).
        El monto vuelve a escrowed[] para que rescue() NO lo pueda tocar.  */
    function _pay(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (token.trySend(to, amount)) return;
        escrowed[token] += amount;
        pending[to][token] += amount;
        emit TokenPending(to, token, amount);
    }

    /// @notice Retira lo que quedo pendiente. `to` permite escapar de un freeze sobre msg.sender.
    function withdrawPending(address token, address to) external lock returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = pending[msg.sender][token];
        if (amount == 0) revert NothingToRefund();
        pending[msg.sender][token] = 0;
        escrowed[token] -= amount;
        token.safeTransfer(to, amount);
        emit TokenWithdrawn(msg.sender, token, amount);
    }

    // ------------------------------ admin ------------------------------

    function setKeeper(address k, bool allowed) external onlyOwner { isKeeper[k] = allowed; emit KeeperSet(k, allowed); }
    function setPaused(bool v) external onlyOwner { paused = v; emit PausedSet(v); }

    /// @notice Saca solo lo que NO esta escrowado (tokens enviados por error). Nunca fondos de usuarios.
    function rescue(address token, address to) external onlyOwner lock {
        if (to == address(0)) revert ZeroAddress();
        uint256 excess = IERC20(token).balanceOf(address(this)) - escrowed[token];
        if (excess == 0) revert NothingToRefund();
        token.safeTransfer(to, excess);
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

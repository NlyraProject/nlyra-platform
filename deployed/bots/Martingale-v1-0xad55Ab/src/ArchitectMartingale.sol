// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*  ArchitectMartingale v1 - ciclos "martingale" (DCA agresivo) para The Desk
    ---------------------------------------------------------------------------
    Un ciclo = comprar `base` ETH de un token; cada vez que el precio cae
    `stepBps` volver a comprar con monto x `multBps` (hasta `levels` niveles);
    los tokens quedan escrowados ACA; cuando todo lo escrowado se puede vender
    por >= spentWei x (1 + tpBps) el keeper vende todo y el ciclo cierra
    (opcionalmente reinicia con el presupuesto no usado).

    Mismo esqueleto que ArchitectLadder (escrow, keeper allowlisteado, routeHash,
    router v2 con swapWithFee / swapETH / swapToETH, rescue solo del exceso,
    ownership en 2 pasos, pause, lock TSTORE).

    Garantias:
      - El keeper solo TIMEA. No puede comprar antes de tiempo: en el nivel k>0
        el minOut que manda tiene que implicar un precio <= precio del ultimo
        fill / (1 + stepBps) (ver levelMinOut) y el router lo hace cumplir. En
        el nivel 0 rige firstMinOut (el piso de slippage que acepto el maker).
      - El keeper no puede vender a perdida: takeProfit usa
        minOut = spentWei x (10000 + tpBps) / 10000, fijo por contrato.
      - Todo lo que sale va al maker (ETH nativo). Nada queda en el contrato
        salvo lo escrowado. El maker cierra cuando quiere (close = vender a
        mercado con SU minOut; withdraw = llevarse tokens + ETH sin vender).
      - Paused: solo close / withdraw / refundExpired.
      - Fees: misma ruta y mismo router que ladder/limit. Pools V4 nativos
        (currency0 = 0): swapETH / swapToETH con referrer = 0.
*/

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
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

contract ArchitectMartingale {
    uint8   internal constant ROUTE_V4 = 2;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant Q = 1e18;            // escala de lastBuyPriceQ (tokens por wei x 1e18)
    uint8   public   constant MAX_LEVELS = 12;
    uint16  public   constant MAX_MULT_BPS = 30_000; // x3 por nivel como maximo
    uint16  public   constant MAX_STEP_BPS = 5_000;  // -50% por nivel como maximo
    uint16  public   constant MAX_TP_BPS = 10_000;   // +100% como maximo

    /// @notice Parametros del ciclo, fijados por el maker en open().
    /// @param base        ETH (wei) del nivel 0
    /// @param multBps     multiplicador por nivel en bps (15000 = x1.5)
    /// @param stepBps     caida de precio entre niveles en bps (500 = 5%)
    /// @param levels      cantidad de niveles (1..12); el presupuesto es la suma de todos
    /// @param tpBps       take-profit sobre el ETH gastado en bps (300 = +3%)
    /// @param autoRestart al cobrar el TP, reiniciar con el presupuesto no usado
    /// @param firstMinOut piso de tokens para el nivel 0 (slippage aceptado por el maker)
    struct Params {
        uint128 base;
        uint16  multBps;
        uint16  stepBps;
        uint8   levels;
        uint16  tpBps;
        bool    autoRestart;
        uint128 firstMinOut;
    }

    enum Status { Open, Closed, Cancelled }

    struct Cycle {
        address maker;
        address token;          // lo que se compra (el lado quote es siempre WETH/ETH)
        address referrer;
        bytes32 routeHash;      // keccak256(route): el keeper no elige el pool
        Params  p;
        uint128 budget;         // ETH depositado al abrir (solo informativo tras un restart)
        uint128 remaining;      // ETH (como WETH) todavia escrowado y sin gastar
        uint128 spentWei;       // ETH gastado en la ronda actual
        uint128 tokens;         // tokens escrowados de la ronda actual
        uint256 lastBuyPriceQ;  // tokensOut * 1e18 / amountIn del ultimo fill (tokens por wei, escala 1e18)
        uint64  expiry;
        uint16  feeBps;
        uint16  round;          // cuantas veces reinicio
        uint8   level;          // proximo nivel a comprar (0..levels)
        Status  status;
    }

    IArchitectRouter public immutable ROUTER;
    address          public immutable WETH;

    address public owner;
    address public pendingOwner;
    bool    public paused;
    uint256 public count;
    mapping(address => bool)    public isKeeper;
    mapping(bytes32 => Cycle)   internal _cycles;
    mapping(address => uint256) public escrowed;      // token => total escrowado (fondos de usuarios)
    mapping(address => uint256) public pendingEth;    // pagos en ETH que rebotaron

    event CycleOpened(bytes32 indexed id, address indexed maker, address token, uint256 budget, Params p, uint64 expiry, uint16 feeBps, address referrer, bytes32 routeHash);
    /// @dev maker es topic 2 (la tape atribuye la compra al maker, via 'martingale').
    event LevelBought(bytes32 indexed id, address indexed maker, address indexed keeper, uint8 level, uint16 round, uint256 amountIn, uint256 amountOut, uint16 feeBps);
    /// @dev idem: la venta del TP es del maker.
    event TookProfit(bytes32 indexed id, address indexed maker, address indexed keeper, uint16 round, uint256 spentWei, uint256 tokensSold, uint256 proceeds, bool restarted);
    /// @param kind 0 = close (vendio a mercado), 1 = withdraw, 2 = refundExpired
    event CycleClosed(bytes32 indexed id, address indexed maker, uint8 kind, uint256 tokensSold, uint256 proceeds, uint256 tokensReturned, uint256 ethReturned);
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
    error BadCycle();
    error BadFee();
    error BadRouteHash();
    error BadValue();
    error NoMoreLevels();
    error InsufficientBudget();
    error MinOutTooLow(uint256 got, uint256 want);
    error InsufficientOutput(uint256 got, uint256 want);
    error NothingToSell();
    error TransferFailed();
    error IsPaused();
    error ZeroAddress();
    error NothingToRefund();

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }
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
        if (IArchitectRouter(router).WETH() != weth) revert BadCycle();
        ROUTER = IArchitectRouter(router);
        WETH   = weth;
        owner  = msg.sender;
        if (keeper != address(0)) { isKeeper[keeper] = true; emit KeeperSet(keeper, true); }
    }

    /// ETH entra solo desde el router (swapToETH) o desde WETH (withdraw).
    receive() external payable {
        if (msg.sender != address(ROUTER) && msg.sender != WETH) revert BadCycle();
    }

    // ------------------------------ presupuesto ------------------------------

    /// @notice Monto del nivel i: base x (multBps/10000)^i.
    function amountAt(Params memory p, uint256 i) public pure returns (uint256 a) {
        a = p.base;
        for (uint256 k = 0; k < i; k++) a = (a * p.multBps) / BPS;
    }

    /// @notice Presupuesto total = suma de amountAt(p, i) para i < levels. Es lo que open() exige como msg.value.
    function budgetOf(Params memory p) public pure returns (uint256 total) {
        uint256 a = p.base;
        for (uint256 i = 0; i < p.levels; i++) { total += a; a = (a * p.multBps) / BPS; }
    }

    function _checkParams(Params calldata p) internal pure {
        if (p.base == 0 || p.levels == 0 || p.levels > MAX_LEVELS) revert BadParams();
        if (p.multBps < BPS || p.multBps > MAX_MULT_BPS) revert BadParams();
        if (p.stepBps == 0 || p.stepBps > MAX_STEP_BPS) revert BadParams();
        if (p.tpBps == 0 || p.tpBps > MAX_TP_BPS) revert BadParams();
        if (p.firstMinOut == 0) revert BadParams();
    }

    // ------------------------------ abrir ------------------------------

    /// @notice Abre un ciclo WETH -> token. msg.value == budgetOf(p); se envuelve a WETH adentro.
    /// @param route calldata opaco del router: abi.encode(uint8 kind, bytes payload). Se guarda solo su hash.
    function open(address token, bytes calldata route, uint64 expiry, uint16 feeBps, address referrer, Params calldata p)
        external payable lock whenNotPaused returns (bytes32 id)
    {
        if (token == address(0) || token == WETH) revert BadCycle();
        if (expiry <= block.timestamp) revert Expired();
        if (feeBps < ROUTER.minFeeBps() || feeBps > ROUTER.maxFeeBps()) revert BadFee();
        _checkParams(p);
        uint256 total = budgetOf(p);
        if (total > type(uint128).max) revert BadParams();
        if (msg.value != total) revert BadValue();
        if (referrer == msg.sender) referrer = address(0);

        IWETH(WETH).deposit{value: total}();
        escrowed[WETH] += total;

        id = keccak256(abi.encode(block.chainid, address(this), ++count, msg.sender));
        Cycle storage C = _cycles[id];
        C.maker = msg.sender;
        C.token = token;
        C.referrer = referrer;
        C.routeHash = keccak256(route);
        C.p = p;
        C.budget = uint128(total);
        C.remaining = uint128(total);
        C.expiry = expiry;
        C.feeBps = feeBps;
        emit CycleOpened(id, msg.sender, token, total, p, expiry, feeBps, referrer, C.routeHash);
    }

    // ------------------------------ keeper ------------------------------

    /// @notice Compra el proximo nivel. Solo keepers, solo mientras el ciclo este abierto y no vencido.
    /// @dev Regla anti "disparo temprano": para level > 0 exigimos
    ///        minOut >= amountIn x lastBuyPriceQ x (10000 + stepBps) / (1e18 x 10000)
    ///      o sea, el keeper se compromete a recibir por wei al menos (1 + stepBps) veces los
    ///      tokens por wei del ultimo fill => precio <= lastPrice / (1 + stepBps). El router
    ///      revierte si el pool no entrega ese minOut, asi que un nivel nunca se compra con el
    ///      precio por encima del escalon. Para level == 0 el piso es p.firstMinOut.
    ///      Los tokens llegan a ESTE contrato y quedan escrowados.
    function buyLevel(bytes32 id, bytes calldata route, uint256 minOut)
        external lock whenNotPaused returns (uint256 amountOut)
    {
        if (!isKeeper[msg.sender]) revert NotKeeper();
        Cycle storage C = _cycles[id];
        if (C.maker == address(0)) revert BadCycle();
        if (C.status != Status.Open) revert NotOpen();
        if (block.timestamp > C.expiry) revert Expired();
        if (keccak256(route) != C.routeHash) revert BadRouteHash();
        uint8 lvl = C.level;
        if (lvl >= C.p.levels) revert NoMoreLevels();
        uint256 amountIn = amountAt(C.p, lvl);
        if (amountIn == 0 || amountIn > C.remaining) revert InsufficientBudget();
        uint256 floor = _levelMinOut(C, amountIn);
        if (minOut < floor) revert MinOutTooLow(minOut, floor);

        // CEI: contabilidad antes del swap
        C.level = lvl + 1;
        C.remaining -= uint128(amountIn);
        C.spentWei += uint128(amountIn);
        escrowed[WETH] -= amountIn;

        amountOut = _buy(C, amountIn, minOut, route);
        if (amountOut > type(uint128).max) revert BadValue();
        C.tokens += uint128(amountOut);
        escrowed[C.token] += amountOut;
        C.lastBuyPriceQ = (amountOut * Q) / amountIn;
        emit LevelBought(id, C.maker, msg.sender, lvl, C.round, amountIn, amountOut, C.feeBps);
    }

    /// @notice Vende TODO lo escrowado por >= spentWei x (1 + tpBps). Solo keepers. El ETH va al maker.
    /// @dev Si autoRestart y el remanente cubre al menos el nivel 0, el ciclo vuelve a level 0
    ///      (round++) con el presupuesto no usado; si no, cierra y devuelve el remanente.
    function takeProfit(bytes32 id, bytes calldata route) external lock whenNotPaused returns (uint256 proceeds) {
        if (!isKeeper[msg.sender]) revert NotKeeper();
        Cycle storage C = _cycles[id];
        if (C.maker == address(0)) revert BadCycle();
        if (C.status != Status.Open) revert NotOpen();
        if (keccak256(route) != C.routeHash) revert BadRouteHash();
        uint256 tokens = C.tokens;
        if (tokens == 0) revert NothingToSell();
        uint256 minOut = (uint256(C.spentWei) * (BPS + C.p.tpBps)) / BPS;
        uint256 spent = C.spentWei;
        uint16 round = C.round;

        // CEI
        C.tokens = 0;
        C.spentWei = 0;
        C.lastBuyPriceQ = 0;
        C.level = 0;
        escrowed[C.token] -= tokens;

        proceeds = _sell(C, tokens, minOut, route);
        _payEth(C.maker, proceeds);

        bool restart = C.p.autoRestart && C.remaining >= C.p.base && block.timestamp <= C.expiry;
        if (restart) {
            C.round = round + 1;
        } else {
            uint256 rem = C.remaining;
            C.remaining = 0;
            C.status = Status.Closed;
            if (rem != 0) { escrowed[WETH] -= rem; IWETH(WETH).withdraw(rem); _payEth(C.maker, rem); }
        }
        emit TookProfit(id, C.maker, msg.sender, round, spent, tokens, proceeds, restart);
        if (!restart) emit CycleClosed(id, C.maker, 0, tokens, proceeds, 0, 0);
    }

    // ------------------------------ maker ------------------------------

    /// @notice El maker vende todo a mercado (con SU minOut) y recupera el ETH sin usar. Funciona pausado.
    function close(bytes32 id, bytes calldata route, uint256 minOut) external lock returns (uint256 proceeds) {
        Cycle storage C = _cycles[id];
        if (msg.sender != C.maker) revert NotMaker();
        if (C.status != Status.Open) revert NotOpen();
        if (keccak256(route) != C.routeHash) revert BadRouteHash();
        uint256 tokens = C.tokens;
        uint256 rem = C.remaining;
        C.tokens = 0; C.spentWei = 0; C.remaining = 0; C.lastBuyPriceQ = 0;
        C.status = Status.Closed;
        if (tokens != 0) {
            if (minOut == 0) revert MinOutTooLow(0, 1);
            escrowed[C.token] -= tokens;
            proceeds = _sell(C, tokens, minOut, route);
        }
        if (rem != 0) { escrowed[WETH] -= rem; IWETH(WETH).withdraw(rem); }
        _payEth(C.maker, proceeds + rem);
        emit CycleClosed(id, C.maker, 0, tokens, proceeds, 0, rem);
    }

    /// @notice El maker se lleva los tokens escrowados + el ETH sin usar, sin vender. Funciona pausado.
    function withdraw(bytes32 id) external lock {
        Cycle storage C = _cycles[id];
        if (msg.sender != C.maker) revert NotMaker();
        _return(id, C, 1);
    }

    /// @notice Pasado el expiry, cualquiera puede devolverle tokens + ETH al maker.
    function refundExpired(bytes32 id) external lock {
        Cycle storage C = _cycles[id];
        if (C.maker == address(0)) revert BadCycle();
        if (block.timestamp <= C.expiry) revert NotExpired();
        _return(id, C, 2);
    }

    function _return(bytes32 id, Cycle storage C, uint8 kind) internal {
        if (C.status != Status.Open) revert NotOpen();
        uint256 tokens = C.tokens;
        uint256 rem = C.remaining;
        if (tokens == 0 && rem == 0) revert NothingToRefund();
        C.tokens = 0; C.spentWei = 0; C.remaining = 0; C.lastBuyPriceQ = 0;
        C.status = Status.Cancelled;
        if (tokens != 0) { escrowed[C.token] -= tokens; _send(C.token, C.maker, tokens); }
        if (rem != 0) { escrowed[WETH] -= rem; IWETH(WETH).withdraw(rem); _payEth(C.maker, rem); }
        emit CycleClosed(id, C.maker, kind, 0, 0, tokens, rem);
    }

    // ------------------------------ swaps ------------------------------

    /// Compra: el token llega a este contrato (escrow). Salida medida por delta de balance.
    function _buy(Cycle storage C, uint256 amountIn, uint256 minOut, bytes calldata route) internal returns (uint256 amountOut) {
        address token = C.token;
        uint256 before = IERC20(token).balanceOf(address(this));
        if (_routeIsNativeV4(route)) {
            IWETH(WETH).withdraw(amountIn);
            ROUTER.swapETH{value: amountIn}(token, minOut, C.feeBps, address(0), block.timestamp, route);
        } else {
            _approve(WETH, address(ROUTER), amountIn);
            ROUTER.swapWithFee(WETH, token, amountIn, minOut, address(this), C.feeBps, C.referrer, block.timestamp, route);
        }
        amountOut = IERC20(token).balanceOf(address(this)) - before;
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
    }

    /// Venta: todo a ETH nativo en este contrato; el caller lo paga al maker.
    function _sell(Cycle storage C, uint256 tokens, uint256 minOut, bytes calldata route) internal returns (uint256 amountOut) {
        address token = C.token;
        _approve(token, address(ROUTER), tokens);
        uint256 before = address(this).balance;
        if (_routeIsNativeV4(route)) {
            ROUTER.swapToETH(token, tokens, minOut, C.feeBps, address(0), block.timestamp, route);
        } else {
            uint256 w = ROUTER.swapWithFee(token, WETH, tokens, minOut, address(this), C.feeBps, C.referrer, block.timestamp, route);
            IWETH(WETH).withdraw(w);
        }
        amountOut = address(this).balance - before;
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
    }

    // ------------------------------ vistas ------------------------------

    function cycle(bytes32 id) external view returns (Cycle memory) { return _cycles[id]; }

    /// @notice ETH del proximo nivel (0 si no quedan niveles o el ciclo no esta abierto).
    function levelAmount(bytes32 id) external view returns (uint256) {
        Cycle storage C = _cycles[id];
        if (C.status != Status.Open || C.level >= C.p.levels) return 0;
        return amountAt(C.p, C.level);
    }

    /// @notice Piso de minOut que buyLevel exige para el proximo nivel (firstMinOut en el nivel 0).
    function levelMinOut(bytes32 id) external view returns (uint256) {
        Cycle storage C = _cycles[id];
        if (C.status != Status.Open || C.level >= C.p.levels) return 0;
        return _levelMinOut(C, amountAt(C.p, C.level));
    }

    function _levelMinOut(Cycle storage C, uint256 amountIn) internal view returns (uint256) {
        if (C.level == 0) return C.p.firstMinOut;
        // tokens por wei del ultimo fill x (1 + step) => precio <= lastPrice / (1 + step)
        return (amountIn * C.lastBuyPriceQ * (BPS + C.p.stepBps)) / (Q * BPS);
    }

    /// @notice ETH minimo que takeProfit exige por la venta de todo lo escrowado.
    function tpMinOut(bytes32 id) external view returns (uint256) {
        Cycle storage C = _cycles[id];
        if (C.status != Status.Open || C.tokens == 0) return 0;
        return (uint256(C.spentWei) * (BPS + C.p.tpBps)) / BPS;
    }

    function isOpen(bytes32 id) external view returns (bool) {
        Cycle storage C = _cycles[id];
        return C.maker != address(0) && C.status == Status.Open;
    }

    // ------------------------------ transferencias ------------------------------

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
    /// Pago en ETH con techo de gas: un maker contrato con receive() caro no
    /// bloquea nada; el ETH queda reclamable con withdrawEth().
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

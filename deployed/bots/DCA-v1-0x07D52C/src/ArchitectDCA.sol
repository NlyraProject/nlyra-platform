// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*  ArchitectDCA v1 - compras programadas (dollar-cost averaging) para The Desk
    ---------------------------------------------------------------------------
    Un plan = `n` compras de `amountPer` ETH de un token, una cada `intervalS`
    segundos (minimo 300 s). El ETH queda escrowado ACA (como WETH); el keeper
    llama execute() cuando vence el plazo; el token va al maker en cada compra
    (deliver = true) o queda escrowado para un take-profit (deliver = false).

    Mismo esqueleto que ArchitectLadder / ArchitectMartingale: escrow, keeper
    allowlisteado, routeHash fijado por el maker, router v2 (swapWithFee /
    swapETH / swapToETH), rescue solo del exceso, ownership en 2 pasos, pause,
    lock TSTORE.

    Garantias (sin oracle):
      - El keeper solo TIMEA. No puede ejecutar antes de `nextAt`, ni mas de
        `n` veces, ni comprar en rafaga despues de una caida del keeper:
        nextAt se re-arma desde block.timestamp, no desde el plazo vencido.
      - El keeper no puede rellenar mal: el minOut que manda tiene que ser
        >= amountPer x lastPriceQ x (1 - maxDeviationBps), o sea el precio de
        esta compra no puede ser mas de maxDeviationBps peor que el de la
        compra anterior (la primera usa firstMinOut, fijado por el maker). El
        router hace cumplir el minOut. Si el mercado sube mas que la banda el
        plan se FRENA (no compra caro): el maker lo re-ancla con reanchor().
      - Take-profit (solo con deliver = false): takeProfit() vende todo lo
        escrowado por >= spentWei x (1 + tpBps), fijo por contrato.
      - Todo lo que sale va al maker. stop() (maker) devuelve el ETH no usado y
        los tokens escrowados (o los vende con SU minOut); refundExpired()
        (cualquiera, post expiry) devuelve ambos. Ambos funcionan pausado.
      - Pools V4 nativos (currency0 = 0): swapETH / swapToETH con referrer 0.
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

contract ArchitectDCA {
    uint8   internal constant ROUTE_V4 = 2;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant Q = 1e18;              // escala de lastPriceQ (tokens por wei x 1e18)
    uint16  public   constant MAX_N = 1000;
    uint32  public   constant MIN_INTERVAL_S = 300;  // 5 min
    uint16  public   constant MAX_DEVIATION_BPS = 5_000;
    uint16  public   constant MAX_TP_BPS = 10_000;   // +100% como maximo

    /// @notice Parametros del plan, fijados por el maker en open().
    /// @param amountPer       ETH (wei) por compra
    /// @param n               cantidad de compras (1..1000); el deposito es n x amountPer
    /// @param intervalS       segundos entre compras (>= 300)
    /// @param maxDeviationBps cuanto peor que la compra anterior puede ser el precio de la siguiente (1..5000)
    /// @param tpBps           take-profit sobre el ETH gastado (0 = sin TP; solo con deliver = false)
    /// @param deliver         true: cada compra va directo al maker; false: queda escrowada (habilita TP)
    /// @param firstMinOut     piso de tokens de la primera compra (slippage aceptado por el maker)
    struct Params {
        uint128 amountPer;
        uint16  n;
        uint32  intervalS;
        uint16  maxDeviationBps;
        uint16  tpBps;
        bool    deliver;
        uint128 firstMinOut;
    }

    enum Status { Open, Closed, Cancelled }

    struct Plan {
        address maker;
        address token;          // lo que se compra (el lado quote es siempre WETH/ETH)
        address referrer;
        bytes32 routeHash;      // keccak256(route): el keeper no elige el pool
        Params  p;
        uint128 remaining;      // ETH (como WETH) todavia escrowado y sin gastar
        uint128 spentWei;       // ETH gastado
        uint128 tokens;         // tokens escrowados (solo deliver = false)
        uint128 bought;         // tokens comprados en total (informativo: costo promedio on-chain)
        uint256 lastPriceQ;     // tokensOut * 1e18 / amountIn de la ultima compra (0 = usar firstMinOut)
        uint64  nextAt;         // proxima compra permitida (unix)
        uint64  expiry;
        uint16  feeBps;
        uint16  done;           // compras ejecutadas
        Status  status;
    }

    IArchitectRouter public immutable ROUTER;
    address          public immutable WETH;

    address public owner;
    address public pendingOwner;
    bool    public paused;
    uint256 public count;
    mapping(address => bool)    public isKeeper;
    mapping(bytes32 => Plan)    internal _plans;
    mapping(address => uint256) public escrowed;      // token => total escrowado (fondos de usuarios)
    mapping(address => uint256) public pendingEth;    // pagos en ETH que rebotaron

    event DcaOpened(bytes32 indexed id, address indexed maker, address token, uint256 total, Params p, uint64 expiry, uint16 feeBps, address referrer, bytes32 routeHash);
    /// @dev maker es topic 2 (la tape atribuye la compra al maker, via 'dca').
    event DcaExecuted(bytes32 indexed id, address indexed maker, address indexed keeper, uint16 i, uint256 amountIn, uint256 amountOut, uint16 feeBps);
    event DcaTookProfit(bytes32 indexed id, address indexed maker, address indexed keeper, uint256 spentWei, uint256 tokensSold, uint256 proceeds);
    /// @param kind 0 = vendio a mercado (stop sellAll o takeProfit), 1 = stop con tokens devueltos, 2 = refundExpired, 3 = completo (ultima compra entregada)
    event DcaStopped(bytes32 indexed id, address indexed maker, uint8 kind, uint256 tokensSold, uint256 proceeds, uint256 tokensReturned, uint256 ethReturned);
    event DcaReanchored(bytes32 indexed id, uint256 nextMinOut);
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
    error NotDue(uint64 nextAt);
    error BadParams();
    error BadPlan();
    error BadFee();
    error BadRouteHash();
    error BadValue();
    error Done();
    error NoTakeProfit();
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
        if (IArchitectRouter(router).WETH() != weth) revert BadPlan();
        ROUTER = IArchitectRouter(router);
        WETH   = weth;
        owner  = msg.sender;
        if (keeper != address(0)) { isKeeper[keeper] = true; emit KeeperSet(keeper, true); }
    }

    /// ETH entra solo desde el router (swapToETH) o desde WETH (withdraw).
    receive() external payable {
        if (msg.sender != address(ROUTER) && msg.sender != WETH) revert BadPlan();
    }

    function _checkParams(Params calldata p) internal pure {
        if (p.amountPer == 0 || p.n == 0 || p.n > MAX_N) revert BadParams();
        if (p.intervalS < MIN_INTERVAL_S) revert BadParams();
        if (p.maxDeviationBps == 0 || p.maxDeviationBps > MAX_DEVIATION_BPS) revert BadParams();
        if (p.tpBps > MAX_TP_BPS) revert BadParams();
        if (p.tpBps != 0 && p.deliver) revert BadParams();   // TP solo con tokens escrowados
        if (p.firstMinOut == 0) revert BadParams();
    }

    // ------------------------------ abrir ------------------------------

    /// @notice Abre un plan WETH -> token. msg.value == n x amountPer; se envuelve a WETH adentro.
    /// @dev La primera compra puede ejecutarse de inmediato (nextAt = ahora). expiry acota el plan entero.
    /// @param route calldata opaco del router: abi.encode(uint8 kind, bytes payload). Se guarda solo su hash.
    function open(address token, bytes calldata route, uint64 expiry, uint16 feeBps, address referrer, Params calldata p)
        external payable lock whenNotPaused returns (bytes32 id)
    {
        if (token == address(0) || token == WETH) revert BadPlan();
        if (expiry <= block.timestamp) revert Expired();
        if (feeBps < ROUTER.minFeeBps() || feeBps > ROUTER.maxFeeBps()) revert BadFee();
        _checkParams(p);
        uint256 total = uint256(p.amountPer) * p.n;
        if (total > type(uint128).max) revert BadParams();
        if (msg.value != total) revert BadValue();
        if (referrer == msg.sender) referrer = address(0);

        IWETH(WETH).deposit{value: total}();
        escrowed[WETH] += total;

        id = keccak256(abi.encode(block.chainid, address(this), ++count, msg.sender));
        Plan storage P = _plans[id];
        P.maker = msg.sender;
        P.token = token;
        P.referrer = referrer;
        P.routeHash = keccak256(route);
        P.p = p;
        P.remaining = uint128(total);
        P.nextAt = uint64(block.timestamp);
        P.expiry = expiry;
        P.feeBps = feeBps;
        emit DcaOpened(id, msg.sender, token, total, p, expiry, feeBps, referrer, P.routeHash);
    }

    // ------------------------------ keeper ------------------------------

    /// @notice Ejecuta la proxima compra. Solo keepers, solo si vencio nextAt y el plan esta abierto.
    /// @dev minOut >= piso (ver nextMinOut). Si deliver, el token va al maker; si no, queda escrowado.
    ///      Tras la ultima compra con deliver = true el plan cierra solo (kind 3).
    function execute(bytes32 id, bytes calldata route, uint256 minOut)
        external lock whenNotPaused returns (uint256 amountOut)
    {
        if (!isKeeper[msg.sender]) revert NotKeeper();
        Plan storage P = _plans[id];
        if (P.maker == address(0)) revert BadPlan();
        if (P.status != Status.Open) revert NotOpen();
        if (block.timestamp > P.expiry) revert Expired();
        if (keccak256(route) != P.routeHash) revert BadRouteHash();
        uint16 i = P.done;
        if (i >= P.p.n) revert Done();
        if (block.timestamp < P.nextAt) revert NotDue(P.nextAt);
        uint256 amountIn = P.p.amountPer;
        if (amountIn > P.remaining) amountIn = P.remaining;   // defensivo: nunca mas que lo escrowado
        if (amountIn == 0) revert NothingToRefund();
        uint256 floor = _floor(P, amountIn);
        if (minOut < floor) revert MinOutTooLow(minOut, floor);

        // CEI: contabilidad antes del swap
        P.done = i + 1;
        P.remaining -= uint128(amountIn);
        P.spentWei += uint128(amountIn);
        P.nextAt = uint64(block.timestamp + P.p.intervalS);
        escrowed[WETH] -= amountIn;

        bool deliver = P.p.deliver;
        amountOut = _buy(P, amountIn, minOut, route, deliver ? P.maker : address(this));
        if (amountOut > type(uint128).max) revert BadValue();
        P.bought += uint128(amountOut);
        P.lastPriceQ = (amountOut * Q) / amountIn;
        if (!deliver) { P.tokens += uint128(amountOut); escrowed[P.token] += amountOut; }
        emit DcaExecuted(id, P.maker, msg.sender, i, amountIn, amountOut, P.feeBps);

        // ultima compra entregada: no queda nada en escrow, el plan cierra
        if (deliver && P.done == P.p.n) {
            uint256 rem = P.remaining;
            P.remaining = 0;
            P.status = Status.Closed;
            if (rem != 0) { escrowed[WETH] -= rem; IWETH(WETH).withdraw(rem); _payEth(P.maker, rem); }
            emit DcaStopped(id, P.maker, 3, 0, 0, 0, rem);
        }
    }

    /// @notice Vende TODO lo escrowado por >= spentWei x (1 + tpBps) y cierra el plan. Solo keepers, solo con tpBps > 0.
    function takeProfit(bytes32 id, bytes calldata route) external lock whenNotPaused returns (uint256 proceeds) {
        if (!isKeeper[msg.sender]) revert NotKeeper();
        Plan storage P = _plans[id];
        if (P.maker == address(0)) revert BadPlan();
        if (P.status != Status.Open) revert NotOpen();
        if (P.p.tpBps == 0) revert NoTakeProfit();
        if (keccak256(route) != P.routeHash) revert BadRouteHash();
        uint256 tokens = P.tokens;
        if (tokens == 0) revert NothingToSell();
        uint256 spent = P.spentWei;
        uint256 minOut = (spent * (BPS + P.p.tpBps)) / BPS;
        uint256 rem = P.remaining;

        // CEI
        P.tokens = 0;
        P.remaining = 0;
        P.status = Status.Closed;
        escrowed[P.token] -= tokens;
        if (rem != 0) escrowed[WETH] -= rem;

        proceeds = _sell(P, tokens, minOut, route);
        if (rem != 0) IWETH(WETH).withdraw(rem);
        _payEth(P.maker, proceeds + rem);
        emit DcaTookProfit(id, P.maker, msg.sender, spent, tokens, proceeds);
        emit DcaStopped(id, P.maker, 0, tokens, proceeds, 0, rem);
    }

    // ------------------------------ maker ------------------------------

    /// @notice El maker cierra el plan: recupera el ETH no usado y los tokens escrowados
    ///         (sellAll = true: los vende a mercado con SU minOut; false: se los lleva). Funciona pausado.
    function stop(bytes32 id, bytes calldata route, uint256 minOut, bool sellAll) external lock returns (uint256 proceeds) {
        Plan storage P = _plans[id];
        if (msg.sender != P.maker) revert NotMaker();
        if (P.status != Status.Open) revert NotOpen();
        uint256 tokens = P.tokens;
        uint256 rem = P.remaining;
        if (tokens == 0 && rem == 0) revert NothingToRefund();
        P.tokens = 0; P.remaining = 0;
        P.status = Status.Cancelled;
        if (rem != 0) { escrowed[WETH] -= rem; IWETH(WETH).withdraw(rem); }
        bool sold = sellAll && tokens != 0;
        if (tokens != 0) {
            escrowed[P.token] -= tokens;
            if (sold) {
                if (keccak256(route) != P.routeHash) revert BadRouteHash();
                if (minOut == 0) revert MinOutTooLow(0, 1);
                proceeds = _sell(P, tokens, minOut, route);
            } else {
                _send(P.token, P.maker, tokens);
            }
        }
        _payEth(P.maker, proceeds + rem);
        emit DcaStopped(id, P.maker, sold ? 0 : 1, sold ? tokens : 0, proceeds, sold ? 0 : tokens, rem);
    }

    /// @notice El maker re-ancla el piso de la proxima compra (el mercado subio mas que la banda y el plan se freno).
    /// @param minOutNext nuevo piso de tokens para la proxima compra (> 0). Rige hasta la siguiente ejecucion.
    function reanchor(bytes32 id, uint128 minOutNext) external {
        Plan storage P = _plans[id];
        if (msg.sender != P.maker) revert NotMaker();
        if (P.status != Status.Open) revert NotOpen();
        if (minOutNext == 0) revert BadParams();
        P.p.firstMinOut = minOutNext;
        P.lastPriceQ = 0;          // la proxima compra usa firstMinOut como piso
        emit DcaReanchored(id, minOutNext);
    }

    /// @notice Pasado el expiry, cualquiera puede devolverle tokens + ETH al maker.
    function refundExpired(bytes32 id) external lock {
        Plan storage P = _plans[id];
        if (P.maker == address(0)) revert BadPlan();
        if (block.timestamp <= P.expiry) revert NotExpired();
        if (P.status != Status.Open) revert NotOpen();
        uint256 tokens = P.tokens;
        uint256 rem = P.remaining;
        if (tokens == 0 && rem == 0) revert NothingToRefund();
        P.tokens = 0; P.remaining = 0;
        P.status = Status.Cancelled;
        if (tokens != 0) { escrowed[P.token] -= tokens; _send(P.token, P.maker, tokens); }
        if (rem != 0) { escrowed[WETH] -= rem; IWETH(WETH).withdraw(rem); _payEth(P.maker, rem); }
        emit DcaStopped(id, P.maker, 2, 0, 0, tokens, rem);
    }

    // ------------------------------ swaps ------------------------------

    /// Compra: salida medida por delta de balance del destinatario.
    function _buy(Plan storage P, uint256 amountIn, uint256 minOut, bytes calldata route, address to) internal returns (uint256 amountOut) {
        address token = P.token;
        if (_routeIsNativeV4(route)) {
            // V4 nativo: el token llega aca y, si corresponde, se reenvia
            IWETH(WETH).withdraw(amountIn);
            uint256 before = IERC20(token).balanceOf(address(this));
            ROUTER.swapETH{value: amountIn}(token, minOut, P.feeBps, address(0), block.timestamp, route);
            amountOut = IERC20(token).balanceOf(address(this)) - before;
            if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
            if (to != address(this)) _send(token, to, amountOut);
        } else {
            _approve(WETH, address(ROUTER), amountIn);
            uint256 before = IERC20(token).balanceOf(to);
            ROUTER.swapWithFee(WETH, token, amountIn, minOut, to, P.feeBps, P.referrer, block.timestamp, route);
            amountOut = IERC20(token).balanceOf(to) - before;
            if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
        }
    }

    /// Venta: todo a ETH nativo en este contrato; el caller lo paga al maker.
    function _sell(Plan storage P, uint256 tokens, uint256 minOut, bytes calldata route) internal returns (uint256 amountOut) {
        address token = P.token;
        _approve(token, address(ROUTER), tokens);
        uint256 before = address(this).balance;
        if (_routeIsNativeV4(route)) {
            ROUTER.swapToETH(token, tokens, minOut, P.feeBps, address(0), block.timestamp, route);
        } else {
            uint256 w = ROUTER.swapWithFee(token, WETH, tokens, minOut, address(this), P.feeBps, P.referrer, block.timestamp, route);
            IWETH(WETH).withdraw(w);
        }
        amountOut = address(this).balance - before;
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
    }

    // ------------------------------ vistas ------------------------------

    function plan(bytes32 id) external view returns (Plan memory) { return _plans[id]; }

    /// @notice Piso de minOut que execute() exige para la proxima compra (0 si no corresponde).
    function nextMinOut(bytes32 id) external view returns (uint256) {
        Plan storage P = _plans[id];
        if (P.status != Status.Open || P.done >= P.p.n) return 0;
        uint256 amountIn = P.p.amountPer;
        if (amountIn > P.remaining) amountIn = P.remaining;
        return _floor(P, amountIn);
    }

    function _floor(Plan storage P, uint256 amountIn) internal view returns (uint256) {
        if (P.lastPriceQ == 0) return P.p.firstMinOut;
        // tokens por wei de la ultima compra x (1 - maxDeviation) => precio <= lastPrice / (1 - maxDeviation)
        return (amountIn * P.lastPriceQ * (BPS - P.p.maxDeviationBps)) / (Q * BPS);
    }

    /// @notice ETH minimo que takeProfit exige (0 si no hay TP o nada escrowado).
    function tpMinOut(bytes32 id) external view returns (uint256) {
        Plan storage P = _plans[id];
        if (P.status != Status.Open || P.tokens == 0 || P.p.tpBps == 0) return 0;
        return (uint256(P.spentWei) * (BPS + P.p.tpBps)) / BPS;
    }

    function isOpen(bytes32 id) external view returns (bool) {
        Plan storage P = _plans[id];
        return P.maker != address(0) && P.status == Status.Open;
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

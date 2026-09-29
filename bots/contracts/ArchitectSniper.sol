// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./ArchitectBotBase.sol";

/*  ArchitectSniper - launch sniper no custodial para The Desk (2026-09-20)
    ---------------------------------------------------------------------------
    El maker deposita ETH (+ reserva de gas) y elige SUS limites: cuanto por
    entrada, cuantas posiciones a la vez, tope por token, stop-loss, take-profit,
    fuentes permitidas. La ESTRATEGIA (que lanzamientos, con que filtros, cuando
    salir) vive en el keeper, configurada por el maker en The Desk; este contrato
    solo garantiza la plata:

      · nunca gasta mas de `perTrade` por entrada, ni abre mas de `maxPositions`
        tokens distintos, ni pone mas de `maxPerToken` en un mismo token;
      · una salida nunca entrega menos que `minOut`; stop-loss y take-profit exigen
        ADEMAS la relacion con el costo (proceeds <= cost*(1-sl) / >= cost*(1+tp));
      · el 1 % se cobra en WETH en CADA compra y venta: en pools lo cobra el
        ArchitectFeeRouter (allowlist de pares y hooks del Desk); en curvas de Pons
        lo aparta este contrato y lo manda a `feeTo` antes de tocar la curva;
      · una curva solo se acepta si la FACTORY de Pons la tiene registrada para ese
        token (`getLaunchedToken(token)`: la curva no puede auto-declararse);
      · una compra que la curva recorta (cerca de graduar) devuelve el sobrante al
        presupuesto del maker y el fee se cobra sobre lo efectivamente gastado;
      · una posicion cuya curva ya graduo se vende por el router (pool V4 del token);
      · stop() nunca se traba por un token que no se deja transferir: ese token queda
        reclamable con claimToken() y el ETH + la reserva vuelven igual;
      · el keeper cobra su gas de la reserva (GasPaid), nunca del capital;
      · stop() devuelve TODO (ETH, reserva y tokens) sin pasar por ningun pool ni
        curva: funciona pausado, vencido y con el keeper caido; vencido, cualquiera
        puede llamarlo por el maker.

    Fuentes (bitmask `sources`): 1 = curvas de Pons (bonding curve, ETH nativo),
    2 = pools via router (V2 / V3 / V4 con hook allowlisteado). Misma mecanica de
    gas y escrow que Shadow / Spot v4: fondos ACA, keeper solo ejecuta, rescue solo
    del exceso, lock TSTORE, pendingEth.
*/

interface IPonsCurve {
    function buy(uint256 eth, uint256 minTokens, address to) external payable returns (uint256);
    function sell(uint256 tokens, uint256 minEth, address to) external;
}

interface IRouterTreasury { function treasury() external view returns (address); }

contract ArchitectSniper is ArchitectBotBase {
    uint256 internal constant MAX_POSITIONS = 20;
    uint256 internal constant SL_SLIP_BPS = 500;      // stop-loss: hasta 5 % por debajo de cost*(1-sl)
    uint8   internal constant SRC_CURVE = 1;          // sources bit 1
    uint8   internal constant SRC_POOL  = 2;          // sources bit 2
    uint256 private constant _CURVE_SLOT = 7;         // transient: curva que puede mandarnos ETH durante una venta

    /// @param perTrade     ETH (wei) maximo por entrada
    /// @param maxPerToken  tope de ETH acumulado en un mismo token (0 = perTrade)
    /// @param maxPositions tokens distintos abiertos a la vez (1..MAX_POSITIONS)
    /// @param slBps / tpBps  stop-loss / take-profit por posicion, en bps sobre el costo (0 = sin)
    /// @param sources      bitmask SRC_CURVE | SRC_POOL
    struct Params { uint128 perTrade; uint128 maxPerToken; uint16 maxPositions; uint16 slBps; uint16 tpBps; uint64 expiry; uint16 feeBps; uint8 sources; address referrer; }

    /// @dev venue = curva (kind 1) o address(0) (kind 0, pool via router)
    struct Position { uint128 base; uint128 cost; uint32 buys; uint32 sells; uint8 kind; address venue; }

    struct Bot {
        address maker;
        address referrer;
        uint128 perTrade;
        uint128 maxPerToken;
        uint128 quoteHeld;      // WETH escrowado para operar
        uint128 gasReserve;     // WETH reservado para el keeper. Dentro de escrowed[WETH].
        uint128 profit;         // ganancias realizadas de por vida, en quote
        uint128 loss;           // perdidas realizadas de por vida, en quote
        uint64  expiry;
        uint16  feeBps;
        uint16  maxPositions;
        uint16  slBps;
        uint16  tpBps;
        uint16  nOpen;
        uint8   sources;
        Status  status;
    }

    mapping(bytes32 => Bot) internal _bots;
    mapping(bytes32 => mapping(address => Position)) internal _pos;
    mapping(bytes32 => address[]) internal _tokens;

    uint256 public gasEscrowed;
    uint256 public constant gasOverhead = 80_000;   // fijo: medido 80k en Spot v4 / Shadow (bookkeeping fuera del gasleft)
    address public ponsFactory;       // factory de las curvas de Pons; address(0) = curvas deshabilitadas

    event BotOpened(bytes32 indexed id, address indexed maker, uint256 quoteIn, uint128 perTrade, uint128 maxPerToken, uint16 maxPositions, uint16 slBps, uint16 tpBps, uint64 expiry, uint16 feeBps, uint8 sources, address referrer);
    /// @dev kind 0 pool, 1 curva. fee = WETH cobrado por este contrato (solo curvas; en pools lo cobra el router)
    event Entered(bytes32 indexed id, address indexed maker, address indexed keeper, address token, address venue, uint8 kind, uint256 amountIn, uint256 amountOut, uint256 fee);
    /// @dev reason 0 keeper (silencio/tiempo/estrategia), 1 total por keeper, 2 maker, 3 stop-loss, 4 take-profit. pnl signed.
    event Exited(bytes32 indexed id, address indexed maker, address indexed keeper, address token, uint8 reason, uint256 base, uint256 proceeds, uint256 cost, int256 pnl, uint256 fee);
    event PositionClosed(bytes32 indexed id, address indexed token, uint8 reason, uint256 base, uint256 proceeds, uint256 cost);
    /// @dev kind 0 stop, 2 expired
    event BotStopped(bytes32 indexed id, address indexed maker, uint8 kind, uint256 quoteReturned, uint256 tokensReturned);
    event ToppedUp(bytes32 indexed id, address indexed maker, uint256 amountIn);
    event GasPaid(bytes32 indexed id, address indexed keeper, uint256 owed, uint256 remaining);
    event GasAdded(bytes32 indexed id, address indexed maker, uint256 amount);
    event GasRefunded(bytes32 indexed id, address indexed maker, uint256 amount);
    event LimitsSet(bytes32 indexed id, uint128 perTrade, uint128 maxPerToken, uint16 maxPositions, uint16 slBps, uint16 tpBps, uint8 sources);
    event TokenStuck(bytes32 indexed id, address indexed token, uint256 base);
    event PonsFactorySet(address factory);

    error NoGas(uint256 owed, uint256 reserve);
    error GasPayFailed();
    error TooManyPositions();
    error TokenCapReached();
    error NoPosition();
    error BadCurve();
    error SourceOff();
    error WrongVenue();

    constructor(address router, address weth, address keeper, address ponsFactory_) ArchitectBotBase(router, weth, keeper) {
        if (IRouterTreasury(router).treasury() == address(0)) revert ZeroAddress();
        ponsFactory = ponsFactory_;
    }
    /// @notice A donde va el 1 % de las operaciones en curva: la tesoreria del router, leida en vivo (el router cobra el suyo solo).
    function feeTo() public view returns (address) { return IRouterTreasury(address(ROUTER)).treasury(); }

    /// ETH entra desde el router (swapToETH), desde WETH (withdraw) o desde la curva a la que le estamos vendiendo.
    receive() external payable override {
        if (msg.sender == address(ROUTER) || msg.sender == WETH) return;
        address c; assembly ("memory-safe") { c := tload(_CURVE_SLOT) }
        if (msg.sender != c || c == address(0)) revert BadGrid();
    }

    // ------------------------------ abrir ------------------------------

    /// @notice Abre un sniper: msg.value == quoteIn + gasReserve. No compra nada: espera al keeper.
    function openWithEth(Params calldata p, uint256 gasReserve) external payable lock whenNotPaused returns (bytes32 id) {
        if (p.expiry <= block.timestamp) revert Expired();
        if (p.feeBps < ROUTER.minFeeBps() || p.feeBps > ROUTER.maxFeeBps()) revert BadFee();
        if (p.perTrade == 0 || p.maxPositions == 0 || p.maxPositions > MAX_POSITIONS) revert BadParams();
        if (p.slBps >= BPS || p.tpBps >= BPS * 100) revert BadParams();
        if (p.sources == 0 || p.sources > (SRC_CURVE | SRC_POOL)) revert BadParams();
        if (gasReserve > type(uint128).max || msg.value <= gasReserve) revert BadValue();
        uint256 quoteIn = msg.value - gasReserve;
        if (quoteIn < p.perTrade || quoteIn > type(uint128).max) revert BadValue();
        _wrap(msg.value);
        id = _newId();
        Bot storage B = _bots[id];
        B.maker = msg.sender;
        B.referrer = p.referrer == msg.sender ? address(0) : p.referrer;
        B.perTrade = p.perTrade;
        B.maxPerToken = p.maxPerToken == 0 ? p.perTrade : p.maxPerToken;
        B.quoteHeld = uint128(quoteIn);
        B.expiry = p.expiry;
        B.feeBps = p.feeBps;
        B.maxPositions = p.maxPositions;
        B.slBps = p.slBps;
        B.tpBps = p.tpBps;
        B.sources = p.sources;
        if (gasReserve != 0) { B.gasReserve = uint128(gasReserve); gasEscrowed += gasReserve; emit GasAdded(id, msg.sender, gasReserve); }
        emit BotOpened(id, msg.sender, quoteIn, p.perTrade, B.maxPerToken, p.maxPositions, p.slBps, p.tpBps, p.expiry, p.feeBps, p.sources, B.referrer);
    }

    // ------------------------------ gas (igual que Shadow / Spot v4) ------------------------------

    function _payGas(bytes32 id, Bot storage B, uint256 g0, bool soft) internal {
        uint256 price = tx.gasprice > block.basefee ? tx.gasprice : block.basefee;
        uint256 owed = ((g0 - gasleft()) + gasOverhead) * price;
        uint256 reserve = B.gasReserve;
        if (owed > reserve) {
            if (!soft) revert NoGas(owed, reserve);
            owed = reserve;
        }
        if (owed == 0) return;
        B.gasReserve = uint128(reserve - owed);
        gasEscrowed   -= owed;
        escrowed[WETH] -= owed;
        if (!IERC20(WETH).transfer(msg.sender, owed)) revert GasPayFailed();
        emit GasPaid(id, msg.sender, owed, reserve - owed);
    }

    function _refundGas(bytes32 id, Bot storage B) internal {
        uint256 r = B.gasReserve;
        if (r == 0) return;
        B.gasReserve = 0;
        gasEscrowed   -= r;
        escrowed[WETH] -= r;
        IWETH(WETH).withdraw(r);
        _payEth(B.maker, r);
        emit GasRefunded(id, B.maker, r);
    }

    // ------------------------------ keeper: entradas ------------------------------

    function _live(bytes32 id) internal view returns (Bot storage B) {
        B = _bots[id];
        if (B.maker == address(0)) revert BadGrid();
        if (B.status != Status.Open) revert NotOpen();
        if (block.timestamp > B.expiry) revert Expired();
    }

    /// Reserva el presupuesto de una entrada y abre la posicion si es nueva (CEI: antes de tocar ningun contrato externo).
    function _reserveEntry(bytes32 id, Bot storage B, address token, uint256 amountIn, uint8 kind, address venue) internal returns (Position storage P) {
        if (token == address(0) || token == WETH) revert BadGrid();
        if (amountIn == 0 || amountIn > B.perTrade) revert BadParams();
        if (amountIn > B.quoteHeld) revert InsufficientBudget();
        P = _pos[id][token];
        if (P.base == 0) {
            if (B.nOpen >= B.maxPositions) revert TooManyPositions();
            B.nOpen++;
            _tokens[id].push(token);
            P.kind = kind; P.venue = venue;
        } else if (P.kind != kind || P.venue != venue) revert WrongVenue();
        if (uint256(P.cost) + amountIn > B.maxPerToken) revert TokenCapReached();
        B.quoteHeld -= uint128(amountIn);
        escrowed[WETH] -= amountIn;
    }

    function _bookEntry(bytes32 id, Bot storage B, Position storage P, address token, address venue, uint8 kind, uint256 amountIn, uint256 amountOut, uint256 fee) internal {
        if (amountOut > type(uint128).max) revert BadValue();
        P.base += uint128(amountOut);
        P.cost += uint128(amountIn);
        P.buys++;
        escrowed[token] += amountOut;
        emit Entered(id, B.maker, msg.sender, token, venue, kind, amountIn, amountOut, fee);
    }

    /// @notice Entrada del keeper. curve == 0: pool via router (`route`; el router cobra el fee y valida par / hook).
    ///         curve != 0: curva de Pons (aparta el fee en WETH, desenvuelve el resto y compra con ETH nativo). minOut > 0 obligatorio.
    function enter(bytes32 id, address token, address curve, bytes calldata route, uint256 amountIn, uint256 minOut)
        external lock whenNotPaused onlyKeeper returns (uint256 amountOut)
    {
        uint256 g0 = gasleft();
        Bot storage B = _live(id);
        if (curve == address(0)) {
            if (B.sources & SRC_POOL == 0) revert SourceOff();
            Position storage Q = _reserveEntry(id, B, token, amountIn, 0, address(0));
            amountOut = _buy(token, B.feeBps, B.referrer, amountIn, minOut, route);
            _bookEntry(id, B, Q, token, address(0), 0, amountIn, amountOut, 0);
            _payGas(id, B, g0, false);
            return amountOut;
        }
        if (B.sources & SRC_CURVE == 0) revert SourceOff();
        if (minOut == 0) revert BadParams();
        _checkCurve(curve, token);
        if (_graduated(curve)) revert BadCurve();
        Position storage P = _reserveEntry(id, B, token, amountIn, 1, curve);
        uint256 feeMax = (amountIn * B.feeBps) / BPS;
        uint256 spend = amountIn - feeMax;
        IWETH(WETH).withdraw(spend);
        uint256 before = IERC20(token).balanceOf(address(this));
        uint256 ethBefore = address(this).balance - spend;
        assembly ("memory-safe") { tstore(_CURVE_SLOT, curve) }
        IPonsCurve(curve).buy{value: spend}(spend, minOut, address(this));
        assembly ("memory-safe") { tstore(_CURVE_SLOT, 0) }
        uint256 refund = address(this).balance - ethBefore;       // lo que la curva devolvio (compra recortada por capacidad)
        amountOut = IERC20(token).balanceOf(address(this)) - before;
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
        uint256 fee = ((spend - refund) * B.feeBps) / (BPS - B.feeBps);   // 1 % del gasto efectivo
        if (fee > feeMax) fee = feeMax;
        if (refund != 0) IWETH(WETH).deposit{value: refund}();
        uint256 back = feeMax + refund - fee;                       // vuelve al presupuesto del maker
        if (back != 0) { B.quoteHeld += uint128(back); escrowed[WETH] += back; }
        if (fee != 0) _send(WETH, feeTo(), fee);
        _bookEntry(id, B, P, token, curve, 1, amountIn - back, amountOut, fee);
        _payGas(id, B, g0, false);
    }

    /// La factory de Pons responde getLaunchedToken(token) con un struct cuyo segundo word es la curva (cero si no existe).
    /// Es la unica fuente que el keeper no controla: una curva falsa que "diga" token()/factory() no pasa.
    function _checkCurve(address curve, address token) internal view {
        if (ponsFactory == address(0) || curve == address(0)) revert BadCurve();
        (bool ok, bytes memory d) = ponsFactory.staticcall(abi.encodeWithSelector(0x3cf28b5a, token));   // getLaunchedToken(address)
        if (!ok || d.length < 64) revert BadCurve();
        uint256 w; assembly ("memory-safe") { w := mload(add(d, 64)) }
        if (w == 0 || w != uint256(uint160(curve))) revert BadCurve();
    }
    /// graduated() de la curva; una curva graduada ya no compra ni vende: la posicion sale por el router.
    function _graduated(address curve) internal view returns (bool) {
        (bool ok, bytes memory d) = curve.staticcall(abi.encodeWithSelector(0xe7c2b772));
        return ok && d.length >= 32 && abi.decode(d, (bool));
    }

    // ------------------------------ keeper: salidas ------------------------------

    /// @notice Salida del keeper. mode 0 = estrategia (silencio, tiempo, señal, parcial): vende `sellBps` a >= minOut, gas duro.
    ///         mode 3 = stop-loss (solo con slBps): vende todo y prueba proceeds <= cost*(1-sl), minOut >= piso (sl - 5 %), gas blando.
    ///         mode 4 = take-profit (solo con tpBps): vende todo y exige proceeds >= cost*(1+tp), gas blando.
    function close(bytes32 id, address token, bytes calldata route, uint256 sellBps, uint256 minOut, uint8 mode)
        external lock whenNotPaused onlyKeeper returns (uint256 proceeds)
    {
        uint256 g0 = gasleft();
        Bot storage B = _live(id);
        if (mode == 0) {
            if (sellBps == 0 || sellBps > BPS) revert BadParams();
            (, , , proceeds) = _sellPart(id, B, token, route, sellBps, minOut, sellBps == BPS ? 1 : 0);
            _payGas(id, B, g0, false);
            return proceeds;
        }
        Position storage P = _pos[id][token];
        if (P.base == 0) revert NoPosition();
        if (mode == 3) {
            if (B.slBps == 0) revert BadParams();
            uint256 cap = (uint256(P.cost) * (BPS - B.slBps)) / BPS;
            uint256 floor = (cap * (BPS - SL_SLIP_BPS)) / BPS;
            if (minOut < floor) minOut = floor;
            (, , , proceeds) = _sellPart(id, B, token, route, BPS, minOut, 3);
            if (proceeds > cap) revert PriceNotReached(proceeds, cap);
        } else if (mode == 4) {
            if (B.tpBps == 0) revert BadParams();
            uint256 want = (uint256(P.cost) * (BPS + B.tpBps)) / BPS;
            if (minOut < want) minOut = want;
            (, , , proceeds) = _sellPart(id, B, token, route, BPS, minOut, 4);
        } else revert BadParams();
        _payGas(id, B, g0, true);
    }

    /// Vende sellBps de la posicion (pool via router o curva), contabiliza pnl realizado y cierra si quedo en 0.
    function _sellPart(bytes32 id, Bot storage B, address token, bytes calldata route, uint256 sellBps, uint256 minOut, uint8 reason)
        internal returns (uint256 base, uint256 cost, int256 pnl, uint256 amountOut)
    {
        Position storage P = _pos[id][token];
        if (P.base == 0) revert NoPosition();
        base = (uint256(P.base) * sellBps) / BPS;
        if (base == 0) revert NothingToSell();
        cost = (uint256(P.cost) * sellBps) / BPS;
        if (sellBps == BPS) { base = P.base; cost = P.cost; }
        // CEI
        P.base -= uint128(base);
        P.cost -= uint128(cost);
        P.sells++;
        escrowed[token] -= base;
        uint256 fee;
        if (P.kind == 1 && !_graduated(P.venue)) (amountOut, fee) = _sellCurve(P.venue, token, base, minOut, B.feeBps);
        else amountOut = _sell(token, B.feeBps, B.referrer, base, minOut, route);
        if (amountOut > type(uint128).max) revert BadValue();
        escrowed[WETH] += amountOut;
        B.quoteHeld += uint128(amountOut);
        if (amountOut >= cost) { uint256 g = amountOut - cost; B.profit += uint128(g); pnl = int256(g); }
        else { uint256 l = cost - amountOut; B.loss += uint128(l); pnl = -int256(l); }
        emit Exited(id, B.maker, msg.sender, token, reason, base, amountOut, cost, pnl, fee);
        if (P.base == 0) { _dropToken(id, token); B.nOpen--; emit PositionClosed(id, token, reason, base, amountOut, cost); }
    }

    /// Venta en curva: approve exacto, sell con ETH a este contrato (aceptado solo desde ESA curva), fee sobre lo recibido, resto re-envuelto.
    function _sellCurve(address curve, address token, uint256 base, uint256 minOut, uint16 feeBps) internal returns (uint256 net, uint256 fee) {
        if (minOut == 0) revert BadParams();
        _approve(token, curve, base);
        uint256 before = address(this).balance;
        assembly ("memory-safe") { tstore(_CURVE_SLOT, curve) }
        IPonsCurve(curve).sell(base, 0, address(this));
        assembly ("memory-safe") { tstore(_CURVE_SLOT, 0) }
        uint256 got = address(this).balance - before;
        IWETH(WETH).deposit{value: got}();
        fee = (got * feeBps) / BPS;
        net = got - fee;
        if (net < minOut) revert InsufficientOutput(net, minOut);
        if (fee != 0) _send(WETH, feeTo(), fee);
    }

    function _dropToken(bytes32 id, address token) internal {
        address[] storage T = _tokens[id];
        uint256 n = T.length;
        for (uint256 i = 0; i < n; i++) if (T[i] == token) { T[i] = T[n - 1]; T.pop(); return; }
    }

    // ------------------------------ maker ------------------------------

    /// @notice El maker vende UNA posicion entera con SU minOut. Funciona pausado. `route` se ignora en curvas.
    function sellPosition(bytes32 id, address token, bytes calldata route, uint256 minOut) external lock returns (uint256 proceeds) {
        Bot storage B = _bots[id];
        if (msg.sender != B.maker) revert NotMaker();
        if (B.status != Status.Open) revert NotOpen();
        (, , , proceeds) = _sellPart(id, B, token, route, BPS, minOut, 2);
    }

    /// @notice Cierra: devuelve el ETH que quedo, la reserva y TODOS los tokens tal cual (sin vender). Funciona pausado y vencido.
    ///         El maker cuando quiera (kind 0); pasado el expiry, cualquiera (kind 2).
    function stop(bytes32 id) external lock returns (uint256 quoteReturned, uint256 tokensReturned) {
        Bot storage B = _bots[id];
        if (B.maker == address(0)) revert BadGrid();
        if (msg.sender == B.maker) return _close(id, B, 0);
        if (block.timestamp <= B.expiry) revert NotExpired();
        return _close(id, B, 2);
    }

    function _close(bytes32 id, Bot storage B, uint8 kind) internal returns (uint256 quoteReturned, uint256 tokensReturned) {
        if (B.status != Status.Open) revert NotOpen();
        B.status = Status.Stopped;
        address[] storage T = _tokens[id];
        uint256 n = T.length;
        for (uint256 i = 0; i < n; i++) {
            address tk = T[i];
            Position storage P = _pos[id][tk];
            uint256 b = P.base;
            if (b == 0) continue;
            // transferencia acotada: un token con blacklist / pausa / revert no puede retener el ETH ni la reserva del maker
            (bool ok, bytes memory d) = tk.call{gas: 150_000}(abi.encodeWithSelector(IERC20.transfer.selector, B.maker, b));
            if (ok && (d.length == 0 || abi.decode(d, (bool)))) { P.base = 0; P.cost = 0; escrowed[tk] -= b; tokensReturned++; }
            else emit TokenStuck(id, tk, b);
        }
        delete _tokens[id];
        B.nOpen = 0;
        quoteReturned = B.quoteHeld;
        B.quoteHeld = 0;
        if (quoteReturned != 0) { escrowed[WETH] -= quoteReturned; IWETH(WETH).withdraw(quoteReturned); _payEth(B.maker, quoteReturned); }
        _refundGas(id, B);
        emit BotStopped(id, B.maker, kind, quoteReturned, tokensReturned);
    }

    /// @notice Tras un stop con un token que no se dejo transferir: el maker lo reclama cuando el token vuelva a moverse.
    function claimToken(bytes32 id, address token) external lock returns (uint256 base) {
        Bot storage B = _bots[id];
        if (msg.sender != B.maker) revert NotMaker();
        if (B.status != Status.Stopped) revert NotOpen();
        Position storage P = _pos[id][token];
        base = P.base;
        if (base == 0) revert NoPosition();
        P.base = 0; P.cost = 0;
        escrowed[token] -= base;
        _send(token, B.maker, base);   // (la Transfer del token es el registro; sin evento propio por tamaño EIP-170)
    }

    /// @notice El maker agrega ETH: msg.value = capital + gasAdd. Se puede cargar solo gas.
    function topUp(bytes32 id, uint256 gasAdd) external payable lock whenNotPaused {
        Bot storage B = _live(id);
        if (msg.sender != B.maker) revert NotMaker();
        if (gasAdd > msg.value || msg.value == 0) revert BadValue();
        uint256 capital = msg.value - gasAdd;
        _wrap(msg.value);
        if (gasAdd != 0) {
            if (uint256(B.gasReserve) + gasAdd > type(uint128).max) revert BadValue();
            B.gasReserve += uint128(gasAdd); gasEscrowed += gasAdd;
            emit GasAdded(id, msg.sender, gasAdd);
        }
        if (capital != 0) {
            if (uint256(B.quoteHeld) + capital > type(uint128).max) revert BadValue();
            B.quoteHeld += uint128(capital);
            emit ToppedUp(id, msg.sender, capital);
        }
    }

    /// @notice El maker cambia sus limites a mitad de corrida.
    function setLimits(bytes32 id, uint128 perTrade, uint128 maxPerToken, uint16 maxPositions, uint16 slBps, uint16 tpBps, uint8 sources) external lock {
        Bot storage B = _bots[id];
        if (msg.sender != B.maker) revert NotMaker();
        if (B.status != Status.Open) revert NotOpen();
        if (perTrade == 0 || maxPositions == 0 || maxPositions > MAX_POSITIONS || slBps >= BPS || tpBps >= BPS * 100) revert BadParams();
        if (sources == 0 || sources > (SRC_CURVE | SRC_POOL)) revert BadParams();
        B.perTrade = perTrade;
        B.maxPerToken = maxPerToken == 0 ? perTrade : maxPerToken;
        B.maxPositions = maxPositions;
        B.slBps = slBps;
        B.tpBps = tpBps;
        B.sources = sources;
        emit LimitsSet(id, perTrade, B.maxPerToken, maxPositions, slBps, tpBps, sources);
    }

    // ------------------------------ admin ------------------------------

    /// @notice Factory de las curvas de Pons. address(0) apaga las entradas en curva (las salidas y el stop siguen).
    function setPonsFactory(address v) external onlyOwner { ponsFactory = v; emit PonsFactorySet(v); }

    // ------------------------------ vistas ------------------------------

    function bot(bytes32 id) external view returns (Bot memory) { return _bots[id]; }
    function position(bytes32 id, address token) external view returns (Position memory) { return _pos[id][token]; }
    function tokensOf(bytes32 id) external view returns (address[] memory) { return _tokens[id]; }
}

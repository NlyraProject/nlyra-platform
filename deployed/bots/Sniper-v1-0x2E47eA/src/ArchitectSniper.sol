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
      · una curva solo se acepta si `curve.factory()` es la factory de Pons
        registrada por el owner y `curve.token()` es el token declarado;
      · el keeper cobra su gas de la reserva (GasPaid), nunca del capital;
      · stop() y refundExpired() devuelven TODO (ETH, reserva y tokens) sin pasar
        por ningun pool ni curva: funcionan pausado, vencido y con el keeper caido.

    Fuentes (bitmask `sources`): 1 = curvas de Pons (bonding curve, ETH nativo),
    2 = pools via router (V2 / V3 / V4 con hook allowlisteado). Misma mecanica de
    gas y escrow que Shadow / Spot v4: fondos ACA, keeper solo ejecuta, rescue solo
    del exceso, lock TSTORE, pendingEth.
*/

interface IPonsCurve {
    function token() external view returns (address);
    function factory() external view returns (address);
    function buy(uint256 eth, uint256 minTokens, address to) external payable returns (uint256);
    function sell(uint256 tokens, uint256 minEth, address to) external;
}

interface IRouterTreasury { function treasury() external view returns (address); }

contract ArchitectSniper is ArchitectBotBase {
    uint256 internal constant MAX_POSITIONS = 20;
    uint256 internal constant MAX_GAS_OVERHEAD = 200_000;
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
    uint256 public gasOverhead = 80_000;
    address public feeTo;             // a donde va el 1 % de las operaciones en curva (el router cobra el suyo solo)
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
    event GasOverheadSet(uint256 overhead);
    event FeeToSet(address feeTo);
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
        feeTo = IRouterTreasury(router).treasury();
        if (feeTo == address(0)) revert ZeroAddress();
        ponsFactory = ponsFactory_;
    }

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

    /// @notice Entra en un pool via router (el router cobra el fee y valida par / hook). minOut > 0 obligatorio.
    function enterPool(bytes32 id, address token, bytes calldata route, uint256 amountIn, uint256 minOut)
        external lock whenNotPaused onlyKeeper returns (uint256 amountOut)
    {
        uint256 g0 = gasleft();
        Bot storage B = _live(id);
        if (B.sources & SRC_POOL == 0) revert SourceOff();
        Position storage P = _reserveEntry(id, B, token, amountIn, 0, address(0));
        amountOut = _buy(token, B.feeBps, B.referrer, amountIn, minOut, route);
        _bookEntry(id, B, P, token, address(0), 0, amountIn, amountOut, 0);
        _payGas(id, B, g0, false);
    }

    /// @notice Entra en una curva de Pons: aparta el fee en WETH, desenvuelve el resto y compra con ETH nativo.
    function enterCurve(bytes32 id, address token, address curve, uint256 amountIn, uint256 minOut)
        external lock whenNotPaused onlyKeeper returns (uint256 amountOut)
    {
        uint256 g0 = gasleft();
        Bot storage B = _live(id);
        if (B.sources & SRC_CURVE == 0) revert SourceOff();
        if (minOut == 0) revert BadParams();
        _checkCurve(curve, token);
        Position storage P = _reserveEntry(id, B, token, amountIn, 1, curve);
        uint256 fee = (amountIn * B.feeBps) / BPS;
        uint256 spend = amountIn - fee;
        if (fee != 0) _send(WETH, feeTo, fee);
        IWETH(WETH).withdraw(spend);
        uint256 before = IERC20(token).balanceOf(address(this));
        IPonsCurve(curve).buy{value: spend}(spend, minOut, address(this));
        amountOut = IERC20(token).balanceOf(address(this)) - before;
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
        _bookEntry(id, B, P, token, curve, 1, amountIn, amountOut, fee);
        _payGas(id, B, g0, false);
    }

    /// staticcall crudo: un contrato que no sea una curva (o una EOA) revierte con BadCurve, no con un revert vacio.
    function _checkCurve(address curve, address token) internal view {
        if (ponsFactory == address(0) || curve == address(0)) revert BadCurve();
        (bool ok, bytes memory d) = curve.staticcall(abi.encodeWithSelector(IPonsCurve.factory.selector));
        if (!ok || d.length < 32 || abi.decode(d, (address)) != ponsFactory) revert BadCurve();
        (ok, d) = curve.staticcall(abi.encodeWithSelector(IPonsCurve.token.selector));
        if (!ok || d.length < 32 || abi.decode(d, (address)) != token) revert BadCurve();
    }

    // ------------------------------ keeper: salidas ------------------------------

    /// @notice Salida por estrategia (silencio, tiempo, señal): vende `sellBps` de la posicion a >= minOut.
    function exit(bytes32 id, address token, bytes calldata route, uint256 sellBps, uint256 minOut)
        external lock whenNotPaused onlyKeeper returns (uint256 proceeds)
    {
        uint256 g0 = gasleft();
        Bot storage B = _live(id);
        if (sellBps == 0 || sellBps > BPS) revert BadParams();
        (, , , proceeds) = _sellPart(id, B, token, route, sellBps, minOut, sellBps == BPS ? 1 : 0);
        _payGas(id, B, g0, false);
    }

    /// @notice Stop-loss: vende todo. Solo con slBps. La venta prueba que proceeds <= cost*(1-sl).
    function stopLoss(bytes32 id, address token, bytes calldata route, uint256 minOut) external lock whenNotPaused onlyKeeper returns (uint256 proceeds) {
        uint256 g0 = gasleft();
        Bot storage B = _live(id);
        if (B.slBps == 0) revert BadParams();
        Position storage P = _pos[id][token];
        if (P.base == 0) revert NoPosition();
        uint256 cap = (uint256(P.cost) * (BPS - B.slBps)) / BPS;
        uint256 floor = (cap * (BPS - SL_SLIP_BPS)) / BPS;
        if (minOut < floor) minOut = floor;
        (, , , proceeds) = _sellPart(id, B, token, route, BPS, minOut, 3);
        if (proceeds > cap) revert PriceNotReached(proceeds, cap);
        _payGas(id, B, g0, true);
    }

    /// @notice Take-profit: vende todo. Solo con tpBps. Exige proceeds >= cost*(1+tp).
    function takeProfit(bytes32 id, address token, bytes calldata route, uint256 minOut) external lock whenNotPaused onlyKeeper returns (uint256 proceeds) {
        uint256 g0 = gasleft();
        Bot storage B = _live(id);
        if (B.tpBps == 0) revert BadParams();
        Position storage P = _pos[id][token];
        if (P.base == 0) revert NoPosition();
        uint256 want = (uint256(P.cost) * (BPS + B.tpBps)) / BPS;
        if (minOut < want) minOut = want;
        (, , , proceeds) = _sellPart(id, B, token, route, BPS, minOut, 4);
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
        if (P.kind == 1) (amountOut, fee) = _sellCurve(P.venue, token, base, minOut, B.feeBps);
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
        if (fee != 0) _send(WETH, feeTo, fee);
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

    /// @notice El maker cierra: devuelve el ETH que quedo, la reserva y TODOS los tokens tal cual (sin vender). Funciona pausado y vencido.
    function stop(bytes32 id) external lock returns (uint256 quoteReturned, uint256 tokensReturned) {
        Bot storage B = _bots[id];
        if (msg.sender != B.maker) revert NotMaker();
        return _close(id, B, 0);
    }

    /// @notice Pasado el expiry, cualquiera devuelve todo al maker sin vender.
    function refundExpired(bytes32 id) external lock returns (uint256 quoteReturned, uint256 tokensReturned) {
        Bot storage B = _bots[id];
        if (B.maker == address(0)) revert BadGrid();
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
            P.base = 0; P.cost = 0;
            escrowed[tk] -= b;
            _send(tk, B.maker, b);
            tokensReturned++;
        }
        delete _tokens[id];
        B.nOpen = 0;
        quoteReturned = B.quoteHeld;
        B.quoteHeld = 0;
        if (quoteReturned != 0) { escrowed[WETH] -= quoteReturned; IWETH(WETH).withdraw(quoteReturned); _payEth(B.maker, quoteReturned); }
        _refundGas(id, B);
        emit BotStopped(id, B.maker, kind, quoteReturned, tokensReturned);
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

    function setGasOverhead(uint256 v) external onlyOwner {
        if (v > MAX_GAS_OVERHEAD) revert BadParams();
        gasOverhead = v;
        emit GasOverheadSet(v);
    }
    function setFeeTo(address v) external onlyOwner { if (v == address(0)) revert ZeroAddress(); feeTo = v; emit FeeToSet(v); }
    /// @notice Factory de las curvas de Pons. address(0) apaga las entradas en curva (las salidas y el stop siguen).
    function setPonsFactory(address v) external onlyOwner { ponsFactory = v; emit PonsFactorySet(v); }

    // ------------------------------ vistas ------------------------------

    function bot(bytes32 id) external view returns (Bot memory) { return _bots[id]; }
    function position(bytes32 id, address token) external view returns (Position memory) { return _pos[id][token]; }
    function tokensOf(bytes32 id) external view returns (address[] memory) { return _tokens[id]; }
    /// @notice minOut que stopLoss exigira como piso para `token` (0 si no aplica).
    function stopLossFloor(bytes32 id, address token) external view returns (uint256) {
        Bot storage B = _bots[id]; Position storage P = _pos[id][token];
        if (B.slBps == 0 || P.base == 0) return 0;
        return (((uint256(P.cost) * (BPS - B.slBps)) / BPS) * (BPS - SL_SLIP_BPS)) / BPS;
    }
    /// @notice minOut que takeProfit exigira para `token` (0 si no aplica).
    function takeProfitMin(bytes32 id, address token) external view returns (uint256) {
        Bot storage B = _bots[id]; Position storage P = _pos[id][token];
        if (B.tpBps == 0 || P.base == 0) return 0;
        return (uint256(P.cost) * (BPS + B.tpBps)) / BPS;
    }
}

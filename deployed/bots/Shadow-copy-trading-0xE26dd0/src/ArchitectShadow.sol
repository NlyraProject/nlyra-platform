// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./ArchitectBotBase.sol";

/*  ArchitectShadow - copy trading no custodial para The Desk (2026-09-13)
    ---------------------------------------------------------------------------
    El maker (seguidor) deposita ETH, elige un LIDER (cualquier wallet de la
    cadena) y un tamaño por operacion. Cuando el lider compra un token, el keeper
    espeja la compra con `perTrade` de la reserva del seguidor; cuando el lider
    vende una fraccion de lo que tiene, el keeper vende la misma fraccion de la
    posicion del seguidor. Todo pasa por el ArchitectFeeRouter (1 % al Desk, con
    su parte de referido si `referrer` esta registrado) y por el allowlist de
    pares del router: el keeper no puede mandar la plata a un pool que el Desk
    no permita.

    Lo que ESTE contrato garantiza al seguidor (lo que no depende del keeper):
      · nunca gasta mas de `perTrade` por espejo, ni abre mas de `maxPositions`
        tokens distintos, ni pone mas de `maxPerToken` en un mismo token;
      · una venta espejo o un cierre nunca entrega menos que `minOut`, y el
        take-profit / stop-loss exigen ADEMAS la relacion con el costo
        (proceeds >= cost*(1+tp) / proceeds <= cost*(1-sl));
      · el keeper cobra su gas de la reserva del seguidor (GasPaid), nunca de la
        plata para operar, y al cerrar lo que sobra vuelve al seguidor;
      · stop() y refundExpired() devuelven TODO (ETH, reserva y tokens) sin
        pasar por ningun pool: funcionan pausado, vencido y con el keeper caido.

    Lo que SI depende del keeper (igual que el take-profit de los grids): que el
    precio de cada espejo sea razonable. El keeper es nuestro, esta
    allowlisteado, quotea antes de mandar y pasa un minOut sobre esa quote. No
    hay oraculo de precio en la cadena para hacerlo mejor sin mentir.

    Misma mecanica de gas que el Spot v4 (tx.gasprice == basefee en esta cadena,
    calldata L1 = 0), reserva adentro de escrowed[WETH], gasEscrowed como
    sub-libro. Igual que los grids: fondos ACA, keeper solo timea, rescue solo del
    exceso, lock TSTORE, pendingEth.
*/
contract ArchitectShadow is ArchitectBotBase {
    uint256 public constant MAX_POSITIONS = 20;
    uint256 public constant MAX_GAS_OVERHEAD = 200_000;
    uint256 internal constant SL_SLIP_BPS = 500;      // stop-loss: hasta 5% por debajo de cost*(1-sl)

    /// @param perTrade     quote (wei) por espejo de compra
    /// @param maxPerToken  tope de quote acumulado en un mismo token (0 = perTrade)
    /// @param maxPositions tokens distintos abiertos a la vez (1..MAX_POSITIONS)
    /// @param slBps        stop-loss por posicion, en bps sobre el costo (0 = sin)
    /// @param tpBps        take-profit por posicion, en bps sobre el costo (0 = sin)
    struct Params { uint128 perTrade; uint128 maxPerToken; uint16 maxPositions; uint16 slBps; uint16 tpBps; uint64 expiry; uint16 feeBps; address referrer; }

    struct Position { uint128 base; uint128 cost; uint32 buys; uint32 sells; }

    struct Shadow {
        address maker;
        address leader;
        address referrer;
        uint128 perTrade;
        uint128 maxPerToken;
        uint128 quoteHeld;      // WETH escrowado para operar
        uint128 gasReserve;     // WETH reservado para el keeper. Dentro de escrowed[WETH].
        uint128 profit;         // realizado de por vida, en quote. NUNCA baja (puede ser negativo? no: ver lossTotal)
        uint128 loss;           // perdidas realizadas de por vida, en quote
        uint64  expiry;
        uint16  feeBps;
        uint16  maxPositions;
        uint16  slBps;
        uint16  tpBps;
        uint16  nOpen;          // tokens con base > 0
        Status  status;
    }

    mapping(bytes32 => Shadow) internal _shadows;
    mapping(bytes32 => mapping(address => Position)) internal _pos;
    mapping(bytes32 => address[]) internal _tokens;          // tokens con posicion abierta (sin duplicados)

    uint256 public gasEscrowed;
    uint256 public gasOverhead = 80_000;

    event ShadowOpened(bytes32 indexed id, address indexed maker, address indexed leader, uint256 quoteIn, uint128 perTrade, uint128 maxPerToken, uint16 maxPositions, uint16 slBps, uint16 tpBps, uint64 expiry, uint16 feeBps, address referrer, bytes32 routeHash);
    /// @dev side 0 BUY, 1 SELL. leaderTx = hash de la tx del lider que se espejo. pnl solo en SELL (signed).
    event Mirrored(bytes32 indexed id, address indexed maker, address indexed keeper, address token, uint8 side, uint256 amountIn, uint256 amountOut, int256 pnl, bytes32 leaderTx);
    /// @dev kind 0 mirror-sell (parcial), 1 mirror-sell (total), 2 maker sold, 3 stop-loss, 4 take-profit
    event PositionClosed(bytes32 indexed id, address indexed token, uint8 kind, uint256 base, uint256 proceeds, uint256 cost);
    /// @dev kind 0 stop, 2 expired. tokensReturned = cuantos tokens distintos volvieron al maker sin vender.
    event ShadowStopped(bytes32 indexed id, address indexed maker, uint8 kind, uint256 quoteReturned, uint256 tokensReturned);
    event ToppedUp(bytes32 indexed id, address indexed maker, uint256 amountIn);
    event GasPaid(bytes32 indexed id, address indexed keeper, uint256 owed, uint256 remaining);
    event GasAdded(bytes32 indexed id, address indexed maker, uint256 amount);
    event GasRefunded(bytes32 indexed id, address indexed maker, uint256 amount);
    event LimitsSet(bytes32 indexed id, uint128 perTrade, uint128 maxPerToken, uint16 maxPositions, uint16 slBps, uint16 tpBps);
    event GasOverheadSet(uint256 overhead);

    error NoGas(uint256 owed, uint256 reserve);
    error GasPayFailed();
    error TooManyPositions();
    error TokenCapReached();
    error NoPosition();
    error BadLeader();

    constructor(address router, address weth, address keeper) ArchitectBotBase(router, weth, keeper) {}

    // ------------------------------ abrir ------------------------------

    /// @notice Abre un shadow: msg.value == quoteIn + gasReserve. No compra nada: espera al lider.
    function openWithEth(address leader, Params calldata p, uint256 gasReserve) external payable lock whenNotPaused returns (bytes32 id) {
        if (leader == address(0) || leader == msg.sender) revert BadLeader();
        if (p.expiry <= block.timestamp) revert Expired();
        if (p.feeBps < ROUTER.minFeeBps() || p.feeBps > ROUTER.maxFeeBps()) revert BadFee();
        if (p.perTrade == 0 || p.maxPositions == 0 || p.maxPositions > MAX_POSITIONS) revert BadParams();
        if (p.slBps >= BPS || p.tpBps >= BPS * 100) revert BadParams();
        if (gasReserve > type(uint128).max || msg.value <= gasReserve) revert BadValue();
        uint256 quoteIn = msg.value - gasReserve;
        if (quoteIn < p.perTrade || quoteIn > type(uint128).max) revert BadValue();
        _wrap(msg.value);
        id = _newId();
        Shadow storage S = _shadows[id];
        S.maker = msg.sender;
        S.leader = leader;
        S.referrer = p.referrer == msg.sender ? address(0) : p.referrer;
        S.perTrade = p.perTrade;
        S.maxPerToken = p.maxPerToken == 0 ? p.perTrade : p.maxPerToken;
        S.quoteHeld = uint128(quoteIn);
        S.expiry = p.expiry;
        S.feeBps = p.feeBps;
        S.maxPositions = p.maxPositions;
        S.slBps = p.slBps;
        S.tpBps = p.tpBps;
        if (gasReserve != 0) { S.gasReserve = uint128(gasReserve); gasEscrowed += gasReserve; emit GasAdded(id, msg.sender, gasReserve); }
        emit ShadowOpened(id, msg.sender, leader, quoteIn, p.perTrade, S.maxPerToken, p.maxPositions, p.slBps, p.tpBps, p.expiry, p.feeBps, S.referrer, keccak256(abi.encode(leader)));
    }

    // ------------------------------ gas (igual que Spot v4) ------------------------------

    function _payGas(bytes32 id, Shadow storage S, uint256 g0, bool soft) internal {
        uint256 price = tx.gasprice > block.basefee ? tx.gasprice : block.basefee;
        uint256 owed = ((g0 - gasleft()) + gasOverhead) * price;
        uint256 reserve = S.gasReserve;
        if (owed > reserve) {
            if (!soft) revert NoGas(owed, reserve);
            owed = reserve;
        }
        if (owed == 0) return;
        S.gasReserve = uint128(reserve - owed);
        gasEscrowed   -= owed;
        escrowed[WETH] -= owed;
        if (!IERC20(WETH).transfer(msg.sender, owed)) revert GasPayFailed();
        emit GasPaid(id, msg.sender, owed, reserve - owed);
    }

    function _refundGas(bytes32 id, Shadow storage S) internal {
        uint256 r = S.gasReserve;
        if (r == 0) return;
        S.gasReserve = 0;
        gasEscrowed   -= r;
        escrowed[WETH] -= r;
        IWETH(WETH).withdraw(r);
        _payEth(S.maker, r);
        emit GasRefunded(id, S.maker, r);
    }

    // ------------------------------ keeper: espejos ------------------------------

    function _live(bytes32 id) internal view returns (Shadow storage S) {
        S = _shadows[id];
        if (S.maker == address(0)) revert BadGrid();
        if (S.status != Status.Open) revert NotOpen();
        if (block.timestamp > S.expiry) revert Expired();
    }

    /// @notice Espeja una COMPRA del lider: gasta `amountIn` (<= perTrade) de la reserva del seguidor en `token`.
    /// @param minOut piso del keeper (obligatorio > 0, lo exige _buy). El contrato pone los topes; el precio lo pone el keeper.
    function mirrorBuy(bytes32 id, address token, bytes calldata route, uint256 amountIn, uint256 minOut, bytes32 leaderTx)
        external lock whenNotPaused onlyKeeper returns (uint256 amountOut)
    {
        uint256 g0 = gasleft();
        Shadow storage S = _live(id);
        if (token == address(0) || token == WETH) revert BadGrid();
        if (amountIn == 0 || amountIn > S.perTrade) revert BadParams();
        if (amountIn > S.quoteHeld) revert InsufficientBudget();
        Position storage P = _pos[id][token];
        if (P.base == 0) {
            if (S.nOpen >= S.maxPositions) revert TooManyPositions();
            S.nOpen++;
            _tokens[id].push(token);
        }
        if (uint256(P.cost) + amountIn > S.maxPerToken) revert TokenCapReached();
        // CEI
        S.quoteHeld -= uint128(amountIn);
        escrowed[WETH] -= amountIn;
        amountOut = _buy(token, S.feeBps, S.referrer, amountIn, minOut, route);
        if (amountOut > type(uint128).max) revert BadValue();
        P.base += uint128(amountOut);
        P.cost += uint128(amountIn);
        P.buys++;
        escrowed[token] += amountOut;
        emit Mirrored(id, S.maker, msg.sender, token, 0, amountIn, amountOut, 0, leaderTx);
        _payGas(id, S, g0, false);
    }

    /// @notice Espeja una VENTA del lider: vende `sellBps` (1..10000) de la posicion del seguidor en `token`.
    function mirrorSell(bytes32 id, address token, bytes calldata route, uint256 sellBps, uint256 minOut, bytes32 leaderTx)
        external lock whenNotPaused onlyKeeper returns (uint256 amountOut)
    {
        uint256 g0 = gasleft();
        Shadow storage S = _live(id);
        if (sellBps == 0 || sellBps > BPS) revert BadParams();
        (uint256 base, uint256 cost, int256 pnl, uint256 out) = _sellPart(id, S, token, route, sellBps, minOut, sellBps == BPS ? 1 : 0);
        amountOut = out;
        emit Mirrored(id, S.maker, msg.sender, token, 1, base, out, pnl, leaderTx);
        cost; // (ya emitido en PositionClosed)
        _payGas(id, S, g0, false);
    }

    /// @notice Stop-loss de UNA posicion: vende todo el token. Solo con slBps. La venta prueba que proceeds <= cost*(1-sl).
    function stopLoss(bytes32 id, address token, bytes calldata route, uint256 minOut) external lock whenNotPaused onlyKeeper returns (uint256 proceeds) {
        uint256 g0 = gasleft();
        Shadow storage S = _live(id);
        if (S.slBps == 0) revert BadParams();
        Position storage P = _pos[id][token];
        if (P.base == 0) revert NoPosition();
        uint256 cap = (uint256(P.cost) * (BPS - S.slBps)) / BPS;               // por encima de esto NO es stop-loss
        uint256 floor = (cap * (BPS - SL_SLIP_BPS)) / BPS;                     // hasta 5 % por debajo del SL
        if (minOut < floor) minOut = floor;
        (, , , proceeds) = _sellPart(id, S, token, route, BPS, minOut, 3);
        if (proceeds > cap) revert PriceNotReached(proceeds, cap);
        _payGas(id, S, g0, true);     // soft: la proteccion no depende de la reserva
    }

    /// @notice Take-profit de UNA posicion: vende todo el token. Solo con tpBps. Exige proceeds >= cost*(1+tp).
    function takeProfit(bytes32 id, address token, bytes calldata route, uint256 minOut) external lock whenNotPaused onlyKeeper returns (uint256 proceeds) {
        uint256 g0 = gasleft();
        Shadow storage S = _live(id);
        if (S.tpBps == 0) revert BadParams();
        Position storage P = _pos[id][token];
        if (P.base == 0) revert NoPosition();
        uint256 want = (uint256(P.cost) * (BPS + S.tpBps)) / BPS;
        if (minOut < want) minOut = want;
        (, , , proceeds) = _sellPart(id, S, token, route, BPS, minOut, 4);
        _payGas(id, S, g0, true);
    }

    /// Vende sellBps de la posicion, contabiliza pnl realizado y cierra la posicion si quedo en 0.
    function _sellPart(bytes32 id, Shadow storage S, address token, bytes calldata route, uint256 sellBps, uint256 minOut, uint8 kind)
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
        amountOut = _sell(token, S.feeBps, S.referrer, base, minOut, route);
        if (amountOut > type(uint128).max) revert BadValue();
        escrowed[WETH] += amountOut;
        S.quoteHeld += uint128(amountOut);
        if (amountOut >= cost) { uint256 g = amountOut - cost; S.profit += uint128(g); pnl = int256(g); }
        else { uint256 l = cost - amountOut; S.loss += uint128(l); pnl = -int256(l); }
        if (P.base == 0) { _dropToken(id, token); S.nOpen--; emit PositionClosed(id, token, kind, base, amountOut, cost); }
    }

    function _dropToken(bytes32 id, address token) internal {
        address[] storage T = _tokens[id];
        uint256 n = T.length;
        for (uint256 i = 0; i < n; i++) if (T[i] == token) { T[i] = T[n - 1]; T.pop(); return; }
    }

    // ------------------------------ maker ------------------------------

    /// @notice El maker vende UNA posicion con SU minOut (sin esperar al lider ni al keeper). Funciona pausado.
    function sellPosition(bytes32 id, address token, bytes calldata route, uint256 minOut) external lock returns (uint256 proceeds) {
        Shadow storage S = _shadows[id];
        if (msg.sender != S.maker) revert NotMaker();
        if (S.status != Status.Open) revert NotOpen();
        (, , , proceeds) = _sellPart(id, S, token, route, BPS, minOut, 2);
    }

    /// @notice El maker cierra: devuelve el ETH que quedo, la reserva de gas y TODOS los tokens tal cual (sin vender).
    ///         Funciona pausado y vencido. Para salir en ETH, vender primero con sellPosition().
    function stop(bytes32 id) external lock returns (uint256 quoteReturned, uint256 tokensReturned) {
        Shadow storage S = _shadows[id];
        if (msg.sender != S.maker) revert NotMaker();
        return _close(id, S, 0);
    }

    /// @notice Pasado el expiry, cualquiera devuelve todo al maker sin vender.
    function refundExpired(bytes32 id) external lock returns (uint256 quoteReturned, uint256 tokensReturned) {
        Shadow storage S = _shadows[id];
        if (S.maker == address(0)) revert BadGrid();
        if (block.timestamp <= S.expiry) revert NotExpired();
        return _close(id, S, 2);
    }

    function _close(bytes32 id, Shadow storage S, uint8 kind) internal returns (uint256 quoteReturned, uint256 tokensReturned) {
        if (S.status != Status.Open) revert NotOpen();
        S.status = Status.Stopped;
        address[] storage T = _tokens[id];
        uint256 n = T.length;
        for (uint256 i = 0; i < n; i++) {
            address tk = T[i];
            Position storage P = _pos[id][tk];
            uint256 b = P.base;
            if (b == 0) continue;
            P.base = 0; P.cost = 0;
            escrowed[tk] -= b;
            _send(tk, S.maker, b);
            tokensReturned++;
        }
        delete _tokens[id];
        S.nOpen = 0;
        quoteReturned = S.quoteHeld;
        S.quoteHeld = 0;
        if (quoteReturned != 0) { escrowed[WETH] -= quoteReturned; IWETH(WETH).withdraw(quoteReturned); _payEth(S.maker, quoteReturned); }
        _refundGas(id, S);
        emit ShadowStopped(id, S.maker, kind, quoteReturned, tokensReturned);
    }

    /// @notice El maker agrega ETH: msg.value = capital + gasAdd. Se puede cargar solo gas.
    function topUp(bytes32 id, uint256 gasAdd) external payable lock whenNotPaused {
        Shadow storage S = _live(id);
        if (msg.sender != S.maker) revert NotMaker();
        if (gasAdd > msg.value || msg.value == 0) revert BadValue();
        uint256 capital = msg.value - gasAdd;
        _wrap(msg.value);
        if (gasAdd != 0) {
            if (uint256(S.gasReserve) + gasAdd > type(uint128).max) revert BadValue();
            S.gasReserve += uint128(gasAdd); gasEscrowed += gasAdd;
            emit GasAdded(id, msg.sender, gasAdd);
        }
        if (capital != 0) {
            if (uint256(S.quoteHeld) + capital > type(uint128).max) revert BadValue();
            S.quoteHeld += uint128(capital);
            emit ToppedUp(id, msg.sender, capital);
        }
    }

    /// @notice El maker cambia los limites a mitad de corrida (no el lider: para eso se abre otro shadow).
    function setLimits(bytes32 id, uint128 perTrade, uint128 maxPerToken, uint16 maxPositions, uint16 slBps, uint16 tpBps) external lock {
        Shadow storage S = _shadows[id];
        if (msg.sender != S.maker) revert NotMaker();
        if (S.status != Status.Open) revert NotOpen();
        if (perTrade == 0 || maxPositions == 0 || maxPositions > MAX_POSITIONS || slBps >= BPS || tpBps >= BPS * 100) revert BadParams();
        S.perTrade = perTrade;
        S.maxPerToken = maxPerToken == 0 ? perTrade : maxPerToken;
        S.maxPositions = maxPositions;
        S.slBps = slBps;
        S.tpBps = tpBps;
        emit LimitsSet(id, perTrade, S.maxPerToken, maxPositions, slBps, tpBps);
    }

    // ------------------------------ admin ------------------------------

    function setGasOverhead(uint256 v) external onlyOwner {
        if (v > MAX_GAS_OVERHEAD) revert BadParams();
        gasOverhead = v;
        emit GasOverheadSet(v);
    }

    // ------------------------------ vistas ------------------------------

    function shadow(bytes32 id) external view returns (Shadow memory) { return _shadows[id]; }
    function position(bytes32 id, address token) external view returns (Position memory) { return _pos[id][token]; }
    function tokensOf(bytes32 id) external view returns (address[] memory) { return _tokens[id]; }
    function isOpen(bytes32 id) external view returns (bool) { Shadow storage S = _shadows[id]; return S.maker != address(0) && S.status == Status.Open; }
    /// @notice minOut que stopLoss exigira como piso para `token` (0 si no aplica).
    function stopLossFloor(bytes32 id, address token) external view returns (uint256) {
        Shadow storage S = _shadows[id]; Position storage P = _pos[id][token];
        if (S.slBps == 0 || P.base == 0) return 0;
        return (((uint256(P.cost) * (BPS - S.slBps)) / BPS) * (BPS - SL_SLIP_BPS)) / BPS;
    }
    /// @notice minOut que takeProfit exigira para `token` (0 si no aplica).
    function takeProfitMin(bytes32 id, address token) external view returns (uint256) {
        Shadow storage S = _shadows[id]; Position storage P = _pos[id][token];
        if (S.tpBps == 0 || P.base == 0) return 0;
        return (uint256(P.cost) * (BPS + S.tpBps)) / BPS;
    }
}

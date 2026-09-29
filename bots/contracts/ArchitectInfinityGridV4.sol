// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./ArchitectBotBase.sol";

/*  ArchitectInfinityGrid v4 - grid sin techo (modelo KuCoin) para The Desk
    ---------------------------------------------------------------------------
    v4 = el Infinity v3 que corre en produccion (src/ArchitectInfinityGrid.sol:
    stop-loss + topUp) mas lo MISMO que ArchitectSpotGridV4 agrego al Spot, y
    nada mas:

    1. RESERVA DE GAS: cada grid paga a su propio keeper.
       El maker deposita una reserva (WETH) al abrir y al hacer topUp. Al final
       de cada fill del keeper (fillUp, fillDown, stopLoss, takeProfit) el
       contrato mide el gas usado, lo cobra de la reserva y se lo paga al keeper
       en WETH, en la misma tx. Si la reserva no alcanza revierte NoGas(): el
       keeper hace staticCall antes de mandar, asi que un grid sin reserva se
       saltea, no falla. Al cerrar, lo que sobra vuelve al maker.
       La reserva vive ADENTRO de escrowed[WETH] (rescue no la ve como exceso);
       gasEscrowed es el sub-libro: gasEscrowed <= escrowed[WETH].
       Exacto en ESTA cadena: sin fee de prioridad y sin cobro de calldata L1.

    2. REINVERSION (compound): la ganancia AGRANDA LA POSICION.
       En un Infinity la posicion es V (valor objetivo del base, en quote). Con
       compound activo, la ganancia realizada de cada fillUp se suma a V: la
       proxima compra hacia abajo compra mas (V - valor actual) y la proxima
       venta hacia arriba deja mas base en la posicion. La plata ya esta en
       quoteHeld (la venta la dejo ahi): no hay movimiento nuevo, solo un
       objetivo mas alto que el bot persigue con su propia ganancia.
       `profit` sigue siendo el realizado de por vida y NUNCA baja; `reinvested`
       es cuanto de eso ya se sumo a V. V nunca baja.

    Lo que NO cambia: la comision (se cobra en el router), la matematica de los
    niveles (P_k = P0 * (1+s)^k), el emparejamiento LIFO de lotes que garantiza
    >= s neto por vuelta, el floor, el stop-loss probado por la venta misma,
    stop, refundExpired, y todos los invariantes de v3.

    El stop-loss pasa a vivir en Params/Grid (slPrice) en vez de un mapping
    aparte: es un contrato nuevo, no hace falta preservar el grid() de v3.
*/
contract ArchitectInfinityGridV4 is ArchitectBotBase {
    uint16  public constant MIN_STEP_BPS = 250;
    uint16  public constant MAX_STEP_BPS = 5_000;
    int32   public constant MAX_K = 240;
    uint16  public constant SL_SLIP_BPS = 300;       // stop-loss: la venta rinde al menos SL - 3%
    uint256 public constant MAX_GAS_OVERHEAD = 200_000;

    /// @notice Parametros del maker. openWithEth usa V (P0 sale del seed); openWithBase usa P0 (V = base * P0 / 1e18).
    /// @param slPrice  stop-loss (quote por base x 1e18, efectivo; 0 = sin); debe ser < P0
    /// @param compound v4: la ganancia realizada se suma a V
    struct Params { uint128 V; uint128 P0; uint16 stepBps; uint128 floorPrice; uint128 tpPrice; uint128 slPrice; uint64 expiry; uint16 feeBps; address referrer; bool compound; }

    /// @notice Lote comprado en el nivel k (fillDown); se vende en el nivel k+1 (fillUp).
    struct Lot { uint128 base; uint128 cost; }

    struct Grid {
        address maker;
        address token;
        address referrer;
        bytes32 routeHash;
        uint128 V;              // valor objetivo del base, en quote. v4: crece con compound y con topUp. NUNCA baja.
        uint128 P0;             // precio ancla (nivel k = 0)
        uint128 quoteHeld;      // WETH escrowado (reserva de compra + profit)
        uint128 baseHeld;       // token escrowado
        uint128 costBasis;      // quote pagado por baseHeld (para el PnL)
        uint128 profit;         // grid profit realizado de por vida, en quote. NUNCA baja.
        uint128 reinvested;     // v4: cuanto del profit ya se sumo a V
        uint128 gasReserve;     // v4: WETH reservado para pagar al keeper. Dentro de escrowed[WETH].
        uint128 floorPrice;
        uint128 tpPrice;
        uint128 slPrice;        // v4: antes vivia en un mapping aparte
        uint64  expiry;
        uint16  feeBps;
        uint16  stepBps;
        int32   lastK;
        bool    compound;       // v4
        Status  status;
    }

    mapping(bytes32 => Grid) internal _grids;
    mapping(bytes32 => mapping(int32 => Lot)) internal _lots;

    /// @notice v4: suma de todas las reservas de gas. Invariante: gasEscrowed <= escrowed[WETH].
    uint256 public gasEscrowed;
    /// @notice v4: gas que gasleft() no ve (intrinsecos, calldata, modifiers, el propio pago). Owner-settable, acotado.
    uint256 public gasOverhead = 80_000;

    event GridOpened(bytes32 indexed id, address indexed maker, address token, uint256 quoteIn, uint256 baseIn, uint128 V, uint128 P0, uint16 stepBps, uint128 floorPrice, uint64 expiry, uint16 feeBps, address referrer, bytes32 routeHash);
    /// @dev maker es topic 2 (la tape atribuye la venta al maker). Se emite junto con GridStopped(kind 3).
    event StopLoss(bytes32 indexed id, address indexed maker, address indexed keeper, uint256 baseSold, uint256 quoteOut);
    event StopLossSet(bytes32 indexed id, uint128 slPrice);
    /// @dev v3: el maker agrego fondos. amountIn = capital agregado; baseBought = base comprado a mercado con la mitad.
    event ToppedUp(bytes32 indexed id, address indexed maker, uint256 amountIn, uint256 baseBought);
    /// @dev v4: el keeper cobro `owed` de la reserva del grid. `remaining` es lo que queda.
    event GasPaid(bytes32 indexed id, address indexed keeper, uint256 owed, uint256 remaining);
    /// @dev v4: entro reserva de gas (open o topUp).
    event GasAdded(bytes32 indexed id, address indexed maker, uint256 amount);
    /// @dev v4: al cerrar, la reserva que sobro volvio al maker.
    event GasRefunded(bytes32 indexed id, address indexed maker, uint256 amount);
    /// @dev v4: la ganancia `amount` de la venta en el nivel k se sumo a V.
    event Reinvested(bytes32 indexed id, int256 k, uint256 amount, uint256 newV);
    event CompoundSet(bytes32 indexed id, bool compound);
    event GasOverheadSet(uint256 overhead);

    error NoGas(uint256 owed, uint256 reserve);
    error GasPayFailed();

    constructor(address router, address weth, address keeper) ArchitectBotBase(router, weth, keeper) {}

    // ------------------------------ abrir ------------------------------

    /// @notice Abre fondeado con ETH: msg.value = V + reserva para comprar hacia abajo + gasReserve.
    ///         Compra V de base en esta misma tx (seedMinOut del maker) y ancla P0 ahi.
    /// @param gasReserve v4: WETH que este grid reserva para pagar a su keeper (puede ser 0: el grid no se llena hasta que haya)
    function openWithEth(address token, bytes calldata route, Params calldata p, uint256 seedMinOut, uint256 gasReserve)
        external payable lock whenNotPaused returns (bytes32 id)
    {
        _checkCommon(token, p.expiry, p.feeBps);
        _checkStep(p);
        if (p.V == 0 || gasReserve > type(uint128).max || msg.value < uint256(p.V) + gasReserve || msg.value > type(uint128).max) revert BadValue();
        _wrap(msg.value);
        id = _store(token, route, p, msg.value - p.V - gasReserve, gasReserve);
        Grid storage G = _grids[id];
        escrowed[WETH] -= p.V;
        uint256 baseOut = _buy(token, p.feeBps, G.referrer, p.V, seedMinOut, route);
        if (baseOut > type(uint128).max) revert BadValue();
        escrowed[token] += baseOut;
        G.V = p.V;
        G.baseHeld = uint128(baseOut);
        G.costBasis = p.V;
        uint256 p0 = (uint256(p.V) * Q) / baseOut;
        if (p0 == 0 || p0 > type(uint128).max) revert BadValue();
        G.P0 = uint128(p0);
        _checkAnchor(G);
        emit GridOpened(id, msg.sender, token, msg.value - gasReserve, baseOut, G.V, G.P0, p.stepBps, p.floorPrice, p.expiry, p.feeBps, G.referrer, G.routeHash);
    }

    /// @notice Abre aportando el base (approve a este contrato): V = baseAmount * P0 / 1e18; msg.value = reserva de quote + gasReserve.
    function openWithBase(address token, bytes calldata route, Params calldata p, uint256 baseAmount, uint256 gasReserve)
        external payable lock whenNotPaused returns (bytes32 id)
    {
        _checkCommon(token, p.expiry, p.feeBps);
        _checkStep(p);
        if (p.P0 == 0 || baseAmount == 0 || baseAmount > type(uint128).max) revert BadParams();
        if (gasReserve > type(uint128).max || msg.value < gasReserve || msg.value > type(uint128).max) revert BadValue();
        uint256 v = (baseAmount * p.P0) / Q;
        if (v == 0 || v > type(uint128).max) revert BadParams();
        _wrap(msg.value);
        _pull(token, msg.sender, baseAmount);
        escrowed[token] += baseAmount;
        id = _store(token, route, p, msg.value - gasReserve, gasReserve);
        Grid storage G = _grids[id];
        G.V = uint128(v);
        G.P0 = p.P0;
        G.baseHeld = uint128(baseAmount);
        G.costBasis = uint128(v);
        _checkAnchor(G);
        emit GridOpened(id, msg.sender, token, msg.value - gasReserve, baseAmount, G.V, G.P0, p.stepBps, p.floorPrice, p.expiry, p.feeBps, G.referrer, G.routeHash);
    }

    function _checkStep(Params calldata p) internal pure {
        if (p.stepBps < MIN_STEP_BPS || p.stepBps > MAX_STEP_BPS) revert BadParams();
    }
    function _checkAnchor(Grid storage G) internal view {
        if (G.floorPrice >= G.P0) revert BadParams();                 // el floor tiene que quedar abajo
        if (G.tpPrice != 0 && G.tpPrice <= G.P0) revert BadParams();  // el TP arriba
        if (G.slPrice != 0 && G.slPrice >= G.P0) revert BadParams();  // el SL abajo del ancla, como el floor
    }

    function _store(address token, bytes calldata route, Params calldata p, uint256 reserve, uint256 gasReserve) internal returns (bytes32 id) {
        id = _newId();
        Grid storage G = _grids[id];
        G.maker = msg.sender;
        G.token = token;
        G.referrer = p.referrer == msg.sender ? address(0) : p.referrer;
        G.routeHash = keccak256(route);
        G.quoteHeld = uint128(reserve);
        G.floorPrice = p.floorPrice;
        G.tpPrice = p.tpPrice;
        G.slPrice = p.slPrice;
        G.expiry = p.expiry;
        G.feeBps = p.feeBps;
        G.stepBps = p.stepBps;
        G.compound = p.compound;
        if (p.slPrice != 0) emit StopLossSet(id, p.slPrice);
        if (gasReserve != 0) {
            G.gasReserve = uint128(gasReserve);
            gasEscrowed += gasReserve;
            emit GasAdded(id, msg.sender, gasReserve);
        }
    }

    // ------------------------------ niveles ------------------------------

    /// @notice P_k = P0 * (1 + stepBps)^k, |k| <= MAX_K.
    function levelPrice(bytes32 id, int32 k) public view returns (uint256) {
        Grid storage G = _grids[id];
        return _price(G.P0, G.stepBps, k);
    }
    function _price(uint256 p0, uint256 s, int32 k) internal pure returns (uint256 p) {
        if (k > MAX_K || k < -MAX_K) revert BadLevel();
        p = p0;
        if (k >= 0) { for (int32 j = 0; j < k; j++) p = (p * (BPS + s)) / BPS; }
        else { for (int32 j = 0; j > k; j--) p = (p * BPS) / (BPS + s); }
    }

    // ------------------------------ v4: gas ------------------------------

    /// Cobra al grid el gas de esta tx y se lo paga al keeper en WETH. Va al FINAL de cada fill (CEI).
    /// @param soft  true en stopLoss / takeProfit: son la PROTECCION del maker, se cobra lo que haya y nunca se revierte por gas.
    function _payGas(bytes32 id, Grid storage G, uint256 g0, bool soft) internal {
        // max(tx.gasprice, block.basefee): en un eth_call tx.gasprice es 0 y NoGas nunca dispararia (pre-flight ciego).
        uint256 price = tx.gasprice > block.basefee ? tx.gasprice : block.basefee;
        uint256 owed = ((g0 - gasleft()) + gasOverhead) * price;
        uint256 reserve = G.gasReserve;
        if (owed > reserve) {
            if (!soft) revert NoGas(owed, reserve);
            owed = reserve;
        }
        if (owed == 0) return;
        G.gasReserve = uint128(reserve - owed);
        gasEscrowed   -= owed;
        escrowed[WETH] -= owed;
        if (!IERC20(WETH).transfer(msg.sender, owed)) revert GasPayFailed();
        emit GasPaid(id, msg.sender, owed, reserve - owed);
    }

    /// Al cerrar: la reserva que sobro vuelve al maker como ETH (pendingEth si su receive() es caro).
    function _refundGas(bytes32 id, Grid storage G) internal {
        uint256 r = G.gasReserve;
        if (r == 0) return;
        G.gasReserve = 0;
        gasEscrowed   -= r;
        escrowed[WETH] -= r;
        IWETH(WETH).withdraw(r);
        _payEth(G.maker, r);
        emit GasRefunded(id, G.maker, r);
    }

    // ------------------------------ keeper ------------------------------

    function _live(bytes32 id, bytes calldata route) internal view returns (Grid storage G) {
        G = _grids[id];
        if (G.maker == address(0)) revert BadGrid();
        if (G.status != Status.Open) revert NotOpen();
        if (block.timestamp > G.expiry) revert Expired();
        if (keccak256(route) != G.routeHash) revert BadRouteHash();
    }

    /// @notice El precio cruzo P_{lastK+1} subiendo: vende el excedente para volver a V. Exige quoteOut * 1e18 >= sellAmt * P_k.
    ///         v4: con compound, la ganancia de esta venta se suma a V. Cobra el gas de la reserva.
    function fillUp(bytes32 id, bytes calldata route) external lock whenNotPaused onlyKeeper returns (uint256 amountOut) {
        uint256 g0 = gasleft();
        Grid storage G = _live(id, route);
        int32 k = G.lastK + 1;
        uint256 pk = _price(G.P0, G.stepBps, k);
        uint256 base = G.baseHeld;
        uint256 target = (uint256(G.V) * Q) / pk;
        if (base <= target) revert NothingToSell();
        uint256 sellAmt = base - target;
        uint256 minOut = (sellAmt * pk + Q - 1) / Q;
        // costo de lo vendido: lote comprado en k-1 (LIFO) y, lo que no cubra, el seed a P0
        uint256 costSold;
        {
            Lot storage lot = _lots[id][k - 1];
            uint256 fromLot = sellAmt < lot.base ? sellAmt : lot.base;
            if (fromLot != 0) {
                uint256 c = (uint256(lot.cost) * fromLot) / lot.base;
                costSold += c;
                lot.base -= uint128(fromLot); lot.cost -= uint128(c);
            }
            costSold += ((sellAmt - fromLot) * G.P0) / Q;
            if (costSold > G.costBasis) costSold = G.costBasis;
        }
        // CEI
        G.lastK = k;
        G.baseHeld = uint128(target);
        G.costBasis -= uint128(costSold);
        escrowed[G.token] -= sellAmt;
        amountOut = _sell(G.token, G.feeBps, G.referrer, sellAmt, minOut, route);
        if (amountOut > type(uint128).max) revert BadValue();
        escrowed[WETH] += amountOut;
        G.quoteHeld += uint128(amountOut);
        uint256 gain = amountOut > costSold ? amountOut - costSold : 0;
        G.profit += uint128(gain);
        emit GridFilled(id, G.maker, msg.sender, int256(k), 1, sellAmt, amountOut, gain);
        // v4: la ganancia agranda la posicion. La plata ya esta en quoteHeld: el proximo fillDown la usa.
        if (G.compound && gain != 0 && uint256(G.V) + gain <= type(uint128).max) {
            G.V += uint128(gain);
            G.reinvested += uint128(gain);
            emit Reinvested(id, int256(k), gain, G.V);
        }
        _payGas(id, G, g0, false);
    }

    /// @notice El precio cruzo P_{lastK-1} bajando (P_k >= floor): compra el faltante para volver a V. Exige baseOut * P_k >= buyQuote * 1e18.
    function fillDown(bytes32 id, bytes calldata route) external lock whenNotPaused onlyKeeper returns (uint256 amountOut) {
        uint256 g0 = gasleft();
        Grid storage G = _live(id, route);
        int32 k = G.lastK - 1;
        uint256 pk = _price(G.P0, G.stepBps, k);
        if (pk < G.floorPrice) revert BelowFloor();
        uint256 curVal = (uint256(G.baseHeld) * pk) / Q;
        if (curVal >= G.V) revert BadLevel();
        uint256 buyQuote = G.V - curVal;
        if (buyQuote > G.quoteHeld) revert InsufficientBudget();
        uint256 minOut = (buyQuote * Q + pk - 1) / pk;
        // CEI
        G.lastK = k;
        G.quoteHeld -= uint128(buyQuote);
        escrowed[WETH] -= buyQuote;
        amountOut = _buy(G.token, G.feeBps, G.referrer, buyQuote, minOut, route);
        if (amountOut > type(uint128).max) revert BadValue();
        escrowed[G.token] += amountOut;
        G.baseHeld += uint128(amountOut);
        G.costBasis += uint128(buyQuote);
        Lot storage lot = _lots[id][k];
        lot.base += uint128(amountOut); lot.cost += uint128(buyQuote);
        emit GridFilled(id, G.maker, msg.sender, int256(k), 0, buyQuote, amountOut, 0);
        _payGas(id, G, g0, false);
    }

    /// @notice Stop-loss: vende TODO el base y cierra (kind 3). Solo keepers, solo con slPrice.
    ///         La venta prueba el precio: quoteOut * 1e18 <= base * sl y quoteOut >= max(minOut, base * sl * 0.97).
    ///         v4: gas soft (se cobra lo que haya, nunca revierte por gas) y la reserva que sobra vuelve al maker.
    function stopLoss(bytes32 id, bytes calldata route, uint256 minOut) external lock whenNotPaused onlyKeeper returns (uint256 proceeds) {
        uint256 g0 = gasleft();
        Grid storage G = _live(id, route);
        uint256 sl = G.slPrice;
        if (sl == 0) revert BadParams();
        uint256 base = G.baseHeld;
        if (base == 0) revert NothingToSell();
        uint256 floor = (base * sl * (BPS - SL_SLIP_BPS)) / (Q * BPS);
        if (minOut < floor) minOut = floor;
        address maker = G.maker;
        proceeds = _close(id, G, 3, route, minOut, true);
        if (proceeds * Q > base * sl) revert PriceNotReached(proceeds, (base * sl) / Q);
        emit StopLoss(id, maker, msg.sender, base, proceeds);
        _payGas(id, G, g0, true);
        _refundGas(id, G);
    }

    /// @notice Take-profit: vende TODO el base y cierra. Solo keepers, solo con tpPrice. Exige quoteOut * 1e18 >= base * tpPrice.
    function takeProfit(bytes32 id, bytes calldata route) external lock whenNotPaused onlyKeeper returns (uint256 proceeds) {
        uint256 g0 = gasleft();
        Grid storage G = _live(id, route);
        if (G.tpPrice == 0) revert BadParams();
        uint256 base = G.baseHeld;
        if (base == 0) revert NothingToSell();
        proceeds = _close(id, G, 4, route, (base * G.tpPrice) / Q, true);
        _payGas(id, G, g0, true);
        _refundGas(id, G);
    }

    // ------------------------------ maker ------------------------------

    /// @notice El maker cierra: sellAll vende el base con SU minOut y devuelve ETH; si no, devuelve base + ETH. Funciona pausado y vencido.
    ///         v4: la reserva de gas que sobro vuelve tambien.
    function stop(bytes32 id, bytes calldata route, uint256 minOut, bool sellAll) external lock returns (uint256 proceeds) {
        Grid storage G = _grids[id];
        if (msg.sender != G.maker) revert NotMaker();
        if (sellAll && G.baseHeld != 0 && keccak256(route) != G.routeHash) revert BadRouteHash();
        proceeds = _close(id, G, sellAll ? 0 : 1, route, minOut, sellAll);
        _refundGas(id, G);
    }

    /// @notice v3: el maker agrega fondos a un grid abierto: la mitad del capital compra base a mercado (seedMinOut del maker,
    ///         misma ruta que el grid) y la otra mitad entra a la reserva de quote. V crece en la mitad comprada; el base nuevo
    ///         se anota como lote en lastK con su costo real. Exige precio efectivo de la compra <= P_{lastK+1}.
    ///         v4: msg.value = capital + gasAdd. Se puede cargar SOLO gas (capital = 0) sin tocar la posicion.
    function topUp(bytes32 id, bytes calldata route, uint256 seedMinOut, uint256 gasAdd) external payable lock whenNotPaused returns (uint256 baseOut) {
        Grid storage G = _live(id, route);
        if (msg.sender != G.maker) revert NotMaker();
        if (gasAdd > msg.value || msg.value > type(uint128).max) revert BadValue();
        uint256 capital = msg.value - gasAdd;
        if (capital == 0 && gasAdd == 0) revert BadValue();
        if (capital == 1) revert BadValue();                          // no se puede partir
        _wrap(msg.value);
        if (gasAdd != 0) {
            if (uint256(G.gasReserve) + gasAdd > type(uint128).max) revert BadValue();
            G.gasReserve += uint128(gasAdd);
            gasEscrowed  += gasAdd;
            emit GasAdded(id, msg.sender, gasAdd);
        }
        if (capital != 0) {
            uint256 half = capital / 2;
            uint256 reserve = capital - half;
            if (uint256(G.V) + half > type(uint128).max || uint256(G.quoteHeld) + reserve > type(uint128).max) revert BadValue();
            uint256 next = _price(G.P0, G.stepBps, G.lastK + 1);
            escrowed[WETH] -= half;
            G.quoteHeld += uint128(reserve);
            baseOut = _buy(G.token, G.feeBps, G.referrer, half, seedMinOut, route);
            if (baseOut == 0 || baseOut > type(uint128).max) revert BadValue();
            uint256 pc = (half * Q + baseOut - 1) / baseOut;
            if (pc > next) revert PriceNotReached(pc, next);
            escrowed[G.token] += baseOut;
            G.baseHeld += uint128(baseOut);
            G.costBasis += uint128(half);
            G.V += uint128(half);
            Lot storage lot = _lots[id][G.lastK];
            lot.base += uint128(baseOut); lot.cost += uint128(half);
            emit ToppedUp(id, msg.sender, capital, baseOut);
        }
    }

    /// @notice El maker pone, mueve o quita (0) el stop-loss de un grid abierto. quote por base x 1e18, efectivo.
    function setStopLoss(bytes32 id, uint128 sl) external {
        Grid storage G = _grids[id];
        if (msg.sender != G.maker) revert NotMaker();
        if (G.status != Status.Open) revert NotOpen();
        G.slPrice = sl;
        emit StopLossSet(id, sl);
    }

    /// @notice v4: el maker prende o apaga la reinversion a mitad de corrida. Lo ya sumado a V queda (V nunca baja).
    function setCompound(bytes32 id, bool compound) external lock {
        Grid storage G = _grids[id];
        if (msg.sender != G.maker) revert NotMaker();
        if (G.status != Status.Open) revert NotOpen();
        G.compound = compound;
        emit CompoundSet(id, compound);
    }

    /// @notice Pasado el expiry, cualquiera devuelve base + ETH (+ reserva de gas) al maker sin vender.
    function refundExpired(bytes32 id, bytes calldata route) external lock {
        Grid storage G = _grids[id];
        if (G.maker == address(0)) revert BadGrid();
        if (block.timestamp <= G.expiry) revert NotExpired();
        _close(id, G, 2, route, 0, false);
        _refundGas(id, G);
    }

    function _close(bytes32 id, Grid storage G, uint8 kind, bytes calldata route, uint256 minOut, bool sell) internal returns (uint256 proceeds) {
        if (G.status != Status.Open) revert NotOpen();
        uint256 base = G.baseHeld; uint256 quote = G.quoteHeld;
        G.status = Status.Stopped;
        G.baseHeld = 0; G.quoteHeld = 0; G.costBasis = 0;
        uint256 baseRet;
        (proceeds, baseRet) = _settle(G.token, G.feeBps, G.referrer, G.maker, base, quote, route, minOut, sell);
        emit GridStopped(id, G.maker, kind, sell ? base : 0, proceeds, baseRet, quote);
    }

    // ------------------------------ admin (v4) ------------------------------

    /// @notice Calibra el gas que gasleft() no ve. Acotado para que el owner no pueda hacer sobrepagar al keeper.
    function setGasOverhead(uint256 v) external onlyOwner {
        if (v > MAX_GAS_OVERHEAD) revert BadParams();
        gasOverhead = v;
        emit GasOverheadSet(v);
    }

    // ------------------------------ vistas ------------------------------

    function grid(bytes32 id) external view returns (Grid memory) { return _grids[id]; }
    function lotAt(bytes32 id, int32 k) external view returns (Lot memory) { return _lots[id][k]; }
    /// @notice Piso de quote que stopLoss exige (0 si no hay SL, nada que vender o el grid no esta abierto).
    function slMinOut(bytes32 id) external view returns (uint256) {
        Grid storage G = _grids[id]; uint256 sl = G.slPrice;
        if (G.status != Status.Open || sl == 0 || G.baseHeld == 0) return 0;
        return (uint256(G.baseHeld) * sl * (BPS - SL_SLIP_BPS)) / (Q * BPS);
    }
    function isOpen(bytes32 id) external view returns (bool) {
        Grid storage G = _grids[id];
        return G.maker != address(0) && G.status == Status.Open;
    }
    /// @notice Que haria el proximo fillUp: (k, precio, base a vender, minOut). base 0 = nada que vender.
    function nextUp(bytes32 id) external view returns (int32 k, uint256 pk, uint256 sellAmt, uint256 minOut) {
        Grid storage G = _grids[id];
        if (G.status != Status.Open || G.lastK >= MAX_K) return (0, 0, 0, 0);
        k = G.lastK + 1; pk = _price(G.P0, G.stepBps, k);
        uint256 target = (uint256(G.V) * Q) / pk;
        if (G.baseHeld > target) { sellAmt = G.baseHeld - target; minOut = (sellAmt * pk + Q - 1) / Q; }
    }
    /// @notice Que haria el proximo fillDown: (k, precio, quote a gastar, minOut). quote 0 = pausado (floor) o sin presupuesto.
    function nextDown(bytes32 id) external view returns (int32 k, uint256 pk, uint256 buyQuote, uint256 minOut) {
        Grid storage G = _grids[id];
        if (G.status != Status.Open || G.lastK <= -MAX_K) return (k, pk, 0, 0);
        k = G.lastK - 1; pk = _price(G.P0, G.stepBps, k);
        if (pk < G.floorPrice) return (k, pk, 0, 0);
        uint256 curVal = (uint256(G.baseHeld) * pk) / Q;
        if (curVal >= G.V) return (k, pk, 0, 0);
        buyQuote = G.V - curVal;
        if (buyQuote > G.quoteHeld) return (k, pk, 0, 0);
        minOut = (buyQuote * Q + pk - 1) / pk;
    }
}

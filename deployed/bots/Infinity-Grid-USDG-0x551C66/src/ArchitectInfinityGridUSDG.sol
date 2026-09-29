// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./ArchitectBotBaseStable.sol";

/*  ArchitectInfinityGridUSDG - ArchitectInfinityGrid v3 con quote USDG (6 decimales).
    ---------------------------------------------------------------------------
    Logica de grid IDENTICA a ArchitectInfinityGrid v3 (src/ArchitectInfinityGrid.sol,
    verificada byte a byte contra 0x177a8837c0444e18677b618624C2a853573d2D7D).
    Cambia SOLO la capa de quote:

      openWithEth(...) payable, msg.value = V + reserva
        -> openWithQuote(token, route, p, quoteIn, seedMinOut), cobra quoteIn de USDG
      openWithBase(...) payable, msg.value = reserva
        -> openWithBase(token, route, p, baseAmount, reserve)
      topUp(id, route, seedMinOut) payable
        -> topUp(id, amountIn, route, seedMinOut)
      stop / refundExpired devuelven USDG por transfer (no unwrap + call{value})

    Endurecimientos por los 6 decimales (todos a favor del usuario, ver informe):
      - _checkPrice sobre P0, floorPrice, tpPrice y el stop-loss (MIN_PRICE 100).
        Con P < BPS/step = 40 la cuenta p*(BPS+s)/BPS devuelve el MISMO p: el nivel
        de venta seria igual al de compra y el bot venderia sin ganancia. Ese es EL
        riesgo de esta variante y se corta en la apertura.
      - _price revierte si el precio se hace 0 (division por cero aguas abajo) o si
        se pasa de MAX_PRICE (garantiza que base*price no desborda).
      - V >= 1 unidad de quote (1.00 USDG).
      - el piso del stop-loss y el minimo del take-profit se redondean HACIA ARRIBA.

    Eventos y storage con la MISMA forma que v3: el backend los lee igual.
*/
contract ArchitectInfinityGridUSDG is ArchitectBotBaseStable {
    uint16 public constant MIN_STEP_BPS = 250;
    uint16 public constant MAX_STEP_BPS = 5_000;
    int32  public constant MAX_K = 240;
    uint16 public constant SL_SLIP_BPS = 300;      // stop-loss: la venta rinde al menos SL - 3%

    /*  Resolucion MINIMA del escalon, en unidades enteras de precio.
        La escalera es P_{k+1} = P_k * (1 + s) / BPS con division ENTERA. Con 18 decimales de
        quote el truncado era 1e-18 y no se notaba; con USDG de 6 decimales el precio interno
        de un token barato es un numero chico (NLYRA a USD 0.000122 -> P = 122) y truncar se
        come una parte del escalon: a P = 100 y s = 250 bps el paso REALIZADO es 2.0%, no 2.5%.
        Exigiendo P0 * s / BPS >= 20 el truncado se lleva como mucho 1/20 = 5% del escalon
        nominal (un step de 2.5% entrega >= 2.375%). No es una perdida - el escalon sigue
        siendo positivo y el profit sigue siendo neto de fees - pero SI seria entregarle al
        maker menos de lo que pidio, y eso se corta en la apertura con un error claro.
        Tabla: s = 250bps -> P0 >= 800 (USD 0.0008 en un token de 18 dec)
               s = 1000bps -> P0 >= 200 · s = 2500bps -> P0 >= 80
        Ningun token con pool USDG en la chain hoy queda ni cerca (el mas barato, COPPERINU,
        tiene P = 14.850). El grid de un token mas barato que eso hay que abrirlo con un
        step mas grande, que es exactamente lo correcto.  */
    uint256 internal constant MIN_STEP_UNITS = 20;

    error StepTooCoarse(uint256 stepUnits, uint256 min);

    /// @notice stop-loss por grid (quote por base x 1e18, efectivo; 0 = sin). Vive fuera de Grid para no cambiar grid().
    mapping(bytes32 => uint128) public slPriceQ;

    /// @notice Parametros del maker. openWithQuote usa V (P0 sale del seed); openWithBase usa P0 (V = base * P0 / 1e18).
    struct Params { uint128 V; uint128 P0; uint16 stepBps; uint128 floorPrice; uint128 tpPrice; uint64 expiry; uint16 feeBps; address referrer; }

    /// @notice Lote comprado en el nivel k (fillDown); se vende en el nivel k+1 (fillUp).
    struct Lot { uint128 base; uint128 cost; }

    struct Grid {
        address maker;
        address token;
        address referrer;
        bytes32 routeHash;
        uint128 V;              // valor objetivo del base, en quote
        uint128 P0;             // precio ancla (nivel k = 0)
        uint128 quoteHeld;      // USDG escrowado (reserva + profit)
        uint128 baseHeld;       // token escrowado
        uint128 costBasis;      // quote pagado por baseHeld (para el PnL)
        uint128 profit;         // grid profit realizado, en quote
        uint128 floorPrice;
        uint128 tpPrice;
        uint64  expiry;
        uint16  feeBps;
        uint16  stepBps;
        int32   lastK;
        Status  status;
    }

    mapping(bytes32 => Grid) internal _grids;
    mapping(bytes32 => mapping(int32 => Lot)) internal _lots;

    event GridOpened(bytes32 indexed id, address indexed maker, address token, uint256 quoteIn, uint256 baseIn, uint128 V, uint128 P0, uint16 stepBps, uint128 floorPrice, uint64 expiry, uint16 feeBps, address referrer, bytes32 routeHash);
    /// @dev maker es topic 2. Se emite junto con GridStopped(kind 3).
    event StopLoss(bytes32 indexed id, address indexed maker, address indexed keeper, uint256 baseSold, uint256 quoteOut);
    event StopLossSet(bytes32 indexed id, uint128 slPriceQ);
    /// @dev el maker agrego fondos. amountIn = USDG aportado (la mitad compro baseBought, la otra mitad fue a la reserva).
    event ToppedUp(bytes32 indexed id, address indexed maker, uint256 amountIn, uint256 baseBought);

    constructor(address router, address quote, address keeper) ArchitectBotBaseStable(router, quote, keeper) {}

    // ------------------------------ abrir ------------------------------

    /// @notice Abre fondeado con USDG: quoteIn = V + reserva para comprar hacia abajo (transferFrom, aprobar antes).
    ///         Compra V de base en esta misma tx (seedMinOut del maker) y ancla P0 ahi.
    function openWithQuote(address token, bytes calldata route, Params calldata p, uint256 quoteIn, uint256 seedMinOut)
        external lock whenNotPaused returns (bytes32 id)
    {
        id = _openWithQuote(token, route, p, quoteIn, seedMinOut, 0);
    }
    /// @notice Igual que openWithQuote, con stop-loss (sl = quote por base x 1e18, efectivo; 0 = sin). Exige sl < P0 del seed.
    function openWithQuoteSL(address token, bytes calldata route, Params calldata p, uint256 quoteIn, uint256 seedMinOut, uint128 sl)
        external lock whenNotPaused returns (bytes32 id)
    {
        id = _openWithQuote(token, route, p, quoteIn, seedMinOut, sl);
    }
    function _openWithQuote(address token, bytes calldata route, Params calldata p, uint256 quoteIn, uint256 seedMinOut, uint128 sl) internal returns (bytes32 id) {
        _checkCommon(token, p.expiry, p.feeBps);
        _checkStep(p);
        if (p.V == 0 || quoteIn < p.V || quoteIn > type(uint128).max) revert BadValue();
        if (p.V < MIN_QUOTE * 10) revert AmountTooSmall(p.V, MIN_QUOTE * 10);
        _pullQuote(quoteIn);
        id = _store(token, route, p, quoteIn - p.V);
        Grid storage G = _grids[id];
        escrowed[QUOTE] -= p.V;
        uint256 baseOut = _buy(token, p.feeBps, G.referrer, p.V, seedMinOut, route);
        if (baseOut > type(uint128).max) revert BadValue();
        escrowed[token] += baseOut;
        G.V = p.V;
        G.baseHeld = uint128(baseOut);
        G.costBasis = p.V;
        uint256 p0 = (uint256(p.V) * Q) / baseOut;
        _checkPrice(p0);
        G.P0 = uint128(p0);
        _checkAnchor(G);
        _setSl(id, G, sl);
        emit GridOpened(id, msg.sender, token, quoteIn, baseOut, G.V, G.P0, p.stepBps, p.floorPrice, p.expiry, p.feeBps, G.referrer, G.routeHash);
    }

    /// @notice Abre aportando el base (transferFrom): V = baseAmount * P0 / 1e18; reserve = reserva de quote (transferFrom).
    function openWithBase(address token, bytes calldata route, Params calldata p, uint256 baseAmount, uint256 reserve)
        external lock whenNotPaused returns (bytes32 id)
    {
        id = _openWithBase(token, route, p, baseAmount, reserve, 0);
    }
    /// @notice Igual que openWithBase, con stop-loss (0 = sin). Exige sl < P0.
    function openWithBaseSL(address token, bytes calldata route, Params calldata p, uint256 baseAmount, uint256 reserve, uint128 sl)
        external lock whenNotPaused returns (bytes32 id)
    {
        id = _openWithBase(token, route, p, baseAmount, reserve, sl);
    }
    function _openWithBase(address token, bytes calldata route, Params calldata p, uint256 baseAmount, uint256 reserve, uint128 sl) internal returns (bytes32 id) {
        _checkCommon(token, p.expiry, p.feeBps);
        _checkStep(p);
        if (p.P0 == 0 || baseAmount == 0 || baseAmount > type(uint128).max || reserve > type(uint128).max) revert BadParams();
        _checkPrice(p.P0);
        uint256 v = (baseAmount * p.P0) / Q;
        if (v > type(uint128).max) revert BadParams();
        if (v < MIN_QUOTE * 10) revert AmountTooSmall(v, MIN_QUOTE * 10);
        _pullQuote(reserve);
        _pull(token, msg.sender, baseAmount);
        escrowed[token] += baseAmount;
        id = _store(token, route, p, reserve);
        Grid storage G = _grids[id];
        G.V = uint128(v);
        G.P0 = p.P0;
        G.baseHeld = uint128(baseAmount);
        G.costBasis = uint128(v);
        _checkAnchor(G);
        _setSl(id, G, sl);
        emit GridOpened(id, msg.sender, token, reserve, baseAmount, G.V, G.P0, p.stepBps, p.floorPrice, p.expiry, p.feeBps, G.referrer, G.routeHash);
    }

    function _checkStep(Params calldata p) internal pure {
        if (p.stepBps < MIN_STEP_BPS || p.stepBps > MAX_STEP_BPS) revert BadParams();
    }
    function _checkAnchor(Grid storage G) internal view {
        if (G.floorPrice >= G.P0) revert BadParams();                 // el floor tiene que quedar abajo
        if (G.tpPrice != 0) { _checkPrice(G.tpPrice); if (G.tpPrice <= G.P0) revert BadParams(); }  // el TP arriba
        // el escalon tiene que ser expresable en enteros con precision razonable (ver MIN_STEP_UNITS)
        uint256 stepUnits = (uint256(G.P0) * G.stepBps) / BPS;
        if (stepUnits < MIN_STEP_UNITS) revert StepTooCoarse(stepUnits, MIN_STEP_UNITS);
    }
    /// Al abrir: el SL tiene que quedar por debajo del ancla (como el floor).
    function _setSl(bytes32 id, Grid storage G, uint128 sl) internal {
        if (sl == 0) return;
        _checkPrice(sl);
        if (sl >= G.P0) revert BadParams();
        slPriceQ[id] = sl;
        emit StopLossSet(id, sl);
    }

    function _store(address token, bytes calldata route, Params calldata p, uint256 reserve) internal returns (bytes32 id) {
        id = _newId();
        Grid storage G = _grids[id];
        G.maker = msg.sender;
        G.token = token;
        G.referrer = p.referrer == msg.sender ? address(0) : p.referrer;
        G.routeHash = keccak256(route);
        G.quoteHeld = uint128(reserve);
        G.floorPrice = p.floorPrice;
        G.tpPrice = p.tpPrice;
        G.expiry = p.expiry;
        G.feeBps = p.feeBps;
        G.stepBps = p.stepBps;
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
        if (k >= 0) { for (int32 j = 0; j < k; j++) { p = (p * (BPS + s)) / BPS; if (p > MAX_PRICE) revert BadLevel(); } }
        else { for (int32 j = 0; j > k; j--) p = (p * BPS) / (BPS + s); }
        // con 6 decimales el precio interno es chico: si la escalera hacia abajo lo lleva a 0,
        // aguas abajo habria division por cero. Se corta aca, claro.
        if (p == 0) revert BadLevel();
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
    function fillUp(bytes32 id, bytes calldata route) external lock whenNotPaused onlyKeeper returns (uint256 amountOut) {
        Grid storage G = _live(id, route);
        int32 k = G.lastK + 1;
        uint256 pk = _price(G.P0, G.stepBps, k);
        uint256 base = G.baseHeld;
        uint256 target = (uint256(G.V) * Q) / pk;
        if (base <= target) revert NothingToSell();
        uint256 sellAmt = base - target;
        uint256 minOut = _ceilDiv(sellAmt * pk, Q);
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
        escrowed[QUOTE] += amountOut;
        G.quoteHeld += uint128(amountOut);
        uint256 gain = amountOut > costSold ? amountOut - costSold : 0;
        G.profit += uint128(gain);
        emit GridFilled(id, G.maker, msg.sender, int256(k), 1, sellAmt, amountOut, gain);
    }

    /// @notice El precio cruzo P_{lastK-1} bajando (P_k >= floor): compra el faltante para volver a V. Exige baseOut * P_k >= buyQuote * 1e18.
    function fillDown(bytes32 id, bytes calldata route) external lock whenNotPaused onlyKeeper returns (uint256 amountOut) {
        Grid storage G = _live(id, route);
        int32 k = G.lastK - 1;
        uint256 pk = _price(G.P0, G.stepBps, k);
        if (pk < G.floorPrice) revert BelowFloor();
        uint256 curVal = (uint256(G.baseHeld) * pk) / Q;
        if (curVal >= G.V) revert BadLevel();
        uint256 buyQuote = G.V - curVal;
        if (buyQuote > G.quoteHeld) revert InsufficientBudget();
        uint256 minOut = _ceilDiv(buyQuote * Q, pk);
        // CEI
        G.lastK = k;
        G.quoteHeld -= uint128(buyQuote);
        escrowed[QUOTE] -= buyQuote;
        amountOut = _buy(G.token, G.feeBps, G.referrer, buyQuote, minOut, route);
        if (amountOut > type(uint128).max) revert BadValue();
        escrowed[G.token] += amountOut;
        G.baseHeld += uint128(amountOut);
        G.costBasis += uint128(buyQuote);
        Lot storage lot = _lots[id][k];
        lot.base += uint128(amountOut); lot.cost += uint128(buyQuote);
        emit GridFilled(id, G.maker, msg.sender, int256(k), 0, buyQuote, amountOut, 0);
    }

    /// @notice Stop-loss: vende TODO el base y cierra (kind 3). Solo keepers, solo con slPriceQ.
    ///         La venta prueba el precio: quoteOut * 1e18 <= base * sl (precio <= SL) y quoteOut >= max(minOut, base * sl * 0.97).
    function stopLoss(bytes32 id, bytes calldata route, uint256 minOut) external lock whenNotPaused onlyKeeper returns (uint256 proceeds) {
        Grid storage G = _live(id, route);
        uint256 sl = slPriceQ[id];
        if (sl == 0) revert BadParams();
        uint256 base = G.baseHeld;
        if (base == 0) revert NothingToSell();
        uint256 floor = _slFloor(base, sl);
        if (minOut < floor) minOut = floor;
        address maker = G.maker;
        proceeds = _close(id, G, 3, route, minOut, true);
        if (proceeds * Q > base * sl) revert PriceNotReached(proceeds, (base * sl) / Q);
        emit StopLoss(id, maker, msg.sender, base, proceeds);
    }

    /// Piso del stop-loss sin el producto triple base*price*BPS, con ceil en las dos divisiones.
    function _slFloor(uint256 base, uint256 sl) internal pure returns (uint256) {
        return _ceilDiv(_ceilDiv(base * sl, Q) * (BPS - SL_SLIP_BPS), BPS);
    }

    /// @notice Take-profit: vende TODO el base y cierra. Solo keepers, solo con tpPrice. Exige quoteOut * 1e18 >= base * tpPrice.
    function takeProfit(bytes32 id, bytes calldata route) external lock whenNotPaused onlyKeeper returns (uint256 proceeds) {
        Grid storage G = _live(id, route);
        if (G.tpPrice == 0) revert BadParams();
        uint256 base = G.baseHeld;
        if (base == 0) revert NothingToSell();
        proceeds = _close(id, G, 4, route, _ceilDiv(base * G.tpPrice, Q), true);
    }

    // ------------------------------ maker ------------------------------

    /// @notice El maker cierra: sellAll vende el base con SU minOut y devuelve USDG; si no, devuelve base + USDG.
    ///         Funciona pausado y vencido. `stop(id, "", 0, false)` es la salida garantizada: no llama al router.
    function stop(bytes32 id, bytes calldata route, uint256 minOut, bool sellAll) external lock returns (uint256 proceeds) {
        proceeds = _stopTo(id, route, minOut, sellAll, msg.sender);
    }

    /// @notice Igual que stop, pero paga a `to`. Solo el maker. Existe porque USDG es una stable
    ///         regulada: si congelan la direccion del maker, esta es la salida sin perder fondos.
    function stopTo(bytes32 id, bytes calldata route, uint256 minOut, bool sellAll, address to) external lock returns (uint256 proceeds) {
        if (to == address(0)) revert ZeroAddress();
        proceeds = _stopTo(id, route, minOut, sellAll, to);
    }

    function _stopTo(bytes32 id, bytes calldata route, uint256 minOut, bool sellAll, address to) internal returns (uint256 proceeds) {
        Grid storage G = _grids[id];
        if (msg.sender != G.maker) revert NotMaker();
        if (sellAll && G.baseHeld != 0 && keccak256(route) != G.routeHash) revert BadRouteHash();
        proceeds = _closeTo(id, G, sellAll ? 0 : 1, route, minOut, sellAll, to);
    }

    /// @notice El maker agrega fondos a un grid abierto. La mitad compra base a mercado (seedMinOut del maker,
    ///         misma ruta que el grid) y la otra mitad entra a la reserva de quote. V crece en la mitad comprada; el
    ///         base nuevo se anota como lote en lastK con su costo real. Exige precio efectivo de la compra <= P_{lastK+1}.
    ///         Cobra amountIn de USDG por transferFrom.
    function topUp(bytes32 id, uint256 amountIn, bytes calldata route, uint256 seedMinOut) external lock whenNotPaused returns (uint256 baseOut) {
        Grid storage G = _live(id, route);
        if (msg.sender != G.maker) revert NotMaker();
        if (amountIn < 2 || amountIn > type(uint128).max) revert BadValue();
        uint256 half = amountIn / 2;
        uint256 reserve = amountIn - half;
        if (uint256(G.V) + half > type(uint128).max || uint256(G.quoteHeld) + reserve > type(uint128).max) revert BadValue();
        uint256 next = _price(G.P0, G.stepBps, G.lastK + 1);
        _pullQuote(amountIn);
        escrowed[QUOTE] -= half;
        G.quoteHeld += uint128(reserve);
        baseOut = _buy(G.token, G.feeBps, G.referrer, half, seedMinOut, route);
        if (baseOut == 0 || baseOut > type(uint128).max) revert BadValue();
        uint256 pc = _ceilDiv(half * Q, baseOut);
        if (pc > next) revert PriceNotReached(pc, next);
        escrowed[G.token] += baseOut;
        G.baseHeld += uint128(baseOut);
        G.costBasis += uint128(half);
        G.V += uint128(half);
        Lot storage lot = _lots[id][G.lastK];
        lot.base += uint128(baseOut); lot.cost += uint128(half);
        emit ToppedUp(id, msg.sender, amountIn, baseOut);
    }

    /// @notice El maker pone, mueve o quita (0) el stop-loss de un grid abierto. quote por base x 1e18, efectivo.
    function setStopLoss(bytes32 id, uint128 sl) external {
        Grid storage G = _grids[id];
        if (msg.sender != G.maker) revert NotMaker();
        if (G.status != Status.Open) revert NotOpen();
        if (sl != 0) _checkPrice(sl);
        slPriceQ[id] = sl;
        emit StopLossSet(id, sl);
    }

    /// @notice Pasado el expiry, cualquiera devuelve base + USDG al maker sin vender.
    function refundExpired(bytes32 id, bytes calldata route) external lock {
        Grid storage G = _grids[id];
        if (G.maker == address(0)) revert BadGrid();
        if (block.timestamp <= G.expiry) revert NotExpired();
        _close(id, G, 2, route, 0, false);
    }

    function _close(bytes32 id, Grid storage G, uint8 kind, bytes calldata route, uint256 minOut, bool sell) internal returns (uint256 proceeds) {
        proceeds = _closeTo(id, G, kind, route, minOut, sell, G.maker);
    }

    function _closeTo(bytes32 id, Grid storage G, uint8 kind, bytes calldata route, uint256 minOut, bool sell, address to) internal returns (uint256 proceeds) {
        if (G.status != Status.Open) revert NotOpen();
        uint256 base = G.baseHeld; uint256 quote = G.quoteHeld;
        G.status = Status.Stopped;
        G.baseHeld = 0; G.quoteHeld = 0; G.costBasis = 0;
        uint256 baseRet;
        (proceeds, baseRet) = _settle(G.token, G.feeBps, G.referrer, to, base, quote, route, minOut, sell);
        emit GridStopped(id, G.maker, kind, sell ? base : 0, proceeds, baseRet, quote);
    }

    // ------------------------------ vistas ------------------------------

    function grid(bytes32 id) external view returns (Grid memory) { return _grids[id]; }
    function lotAt(bytes32 id, int32 k) external view returns (Lot memory) { return _lots[id][k]; }
    /// @notice Piso de quote que stopLoss exige (0 si no hay SL, nada que vender o el grid no esta abierto).
    function slMinOut(bytes32 id) external view returns (uint256) {
        Grid storage G = _grids[id]; uint256 sl = slPriceQ[id];
        if (G.status != Status.Open || sl == 0 || G.baseHeld == 0) return 0;
        return _slFloor(G.baseHeld, sl);
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
        if (G.baseHeld > target) { sellAmt = G.baseHeld - target; minOut = _ceilDiv(sellAmt * pk, Q); }
    }
    /// @notice Que haria el proximo fillDown: (k, precio, quote a gastar, minOut). quote 0 = pausado (floor) o sin presupuesto.
    function nextDown(bytes32 id) external view returns (int32 k, uint256 pk, uint256 buyQuote, uint256 minOut) {
        Grid storage G = _grids[id];
        if (G.status != Status.Open || G.lastK <= -MAX_K) return (0, 0, 0, 0);
        k = G.lastK - 1; pk = _price(G.P0, G.stepBps, k);
        if (pk < G.floorPrice) return (k, pk, 0, 0);
        uint256 curVal = (uint256(G.baseHeld) * pk) / Q;
        if (curVal >= G.V) return (k, pk, 0, 0);
        buyQuote = G.V - curVal;
        if (buyQuote > G.quoteHeld) return (k, pk, 0, 0);
        minOut = _ceilDiv(buyQuote * Q, pk);
    }
}

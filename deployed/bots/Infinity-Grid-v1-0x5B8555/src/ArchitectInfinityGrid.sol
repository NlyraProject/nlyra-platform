// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./ArchitectBotBase.sol";

/*  ArchitectInfinityGrid v1 - grid sin techo (modelo KuCoin) para The Desk
    ---------------------------------------------------------------------------
    El contrato guarda V (valor objetivo del base, en quote), P0 (precio ancla
    = precio efectivo de la compra inicial), stepBps y floorPrice. Los niveles
    son geometricos, P_k = P0 * (1+s)^k, calculados al vuelo.

      fillUp:   el precio cruzo P_{lastK+1} subiendo -> vende el base que sobra
                para que el valor vuelva a V. Exige quoteOut * 1e18 >= sellAmt * P_k.
      fillDown: el precio cruzo P_{lastK-1} bajando (y P_k >= floor) -> compra el
                quote que falta para volver a V. Exige baseOut * P_k >= buyQuote * 1e18.

    Cada venta en P_k se empareja (LIFO) con la compra previa en P_{k-1} del
    mismo lote: como esa compra costo <= lot.base * P_{k-1} y la venta rinde
    >= sellAmt * P_k = sellAmt * P_{k-1} * (1+s), el profit neto es >= s sobre lo
    vendido. Lo que no tiene lote (el seed) costo P0 <= P_{k-1}: idem.
    Por debajo del floor el bot no compra (pausa); sube sin limite.
    Precios: quoteWei * 1e18 / baseRaw, efectivos (netos del fee del router).
*/
contract ArchitectInfinityGrid is ArchitectBotBase {
    uint16 public constant MIN_STEP_BPS = 250;
    uint16 public constant MAX_STEP_BPS = 5_000;
    int32  public constant MAX_K = 240;

    /// @notice Parametros del maker. openWithEth usa V (P0 sale del seed); openWithBase usa P0 (V = base * P0 / 1e18).
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
        uint128 quoteHeld;      // WETH escrowado (reserva + profit)
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

    constructor(address router, address weth, address keeper) ArchitectBotBase(router, weth, keeper) {}

    // ------------------------------ abrir ------------------------------

    /// @notice Abre fondeado con ETH: msg.value = V + reserva para comprar hacia abajo. Compra V de base en esta misma tx (seedMinOut del maker) y ancla P0 ahi.
    function openWithEth(address token, bytes calldata route, Params calldata p, uint256 seedMinOut)
        external payable lock whenNotPaused returns (bytes32 id)
    {
        _checkCommon(token, p.expiry, p.feeBps);
        _checkStep(p);
        if (p.V == 0 || msg.value < p.V || msg.value > type(uint128).max) revert BadValue();
        _wrap(msg.value);
        id = _store(token, route, p, msg.value - p.V);
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
        emit GridOpened(id, msg.sender, token, msg.value, baseOut, G.V, G.P0, p.stepBps, p.floorPrice, p.expiry, p.feeBps, G.referrer, G.routeHash);
    }

    /// @notice Abre aportando el base (approve a este contrato): V = baseAmount * P0 / 1e18; msg.value = reserva de quote.
    function openWithBase(address token, bytes calldata route, Params calldata p, uint256 baseAmount)
        external payable lock whenNotPaused returns (bytes32 id)
    {
        _checkCommon(token, p.expiry, p.feeBps);
        _checkStep(p);
        if (p.P0 == 0 || baseAmount == 0 || baseAmount > type(uint128).max || msg.value > type(uint128).max) revert BadParams();
        uint256 v = (baseAmount * p.P0) / Q;
        if (v == 0 || v > type(uint128).max) revert BadParams();
        _wrap(msg.value);
        _pull(token, msg.sender, baseAmount);
        escrowed[token] += baseAmount;
        id = _store(token, route, p, msg.value);
        Grid storage G = _grids[id];
        G.V = uint128(v);
        G.P0 = p.P0;
        G.baseHeld = uint128(baseAmount);
        G.costBasis = uint128(v);
        _checkAnchor(G);
        emit GridOpened(id, msg.sender, token, msg.value, baseAmount, G.V, G.P0, p.stepBps, p.floorPrice, p.expiry, p.feeBps, G.referrer, G.routeHash);
    }

    function _checkStep(Params calldata p) internal pure {
        if (p.stepBps < MIN_STEP_BPS || p.stepBps > MAX_STEP_BPS) revert BadParams();
    }
    function _checkAnchor(Grid storage G) internal view {
        if (G.floorPrice >= G.P0) revert BadParams();                 // el floor tiene que quedar abajo
        if (G.tpPrice != 0 && G.tpPrice <= G.P0) revert BadParams();  // el TP arriba
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
        if (k >= 0) { for (int32 j = 0; j < k; j++) p = (p * (BPS + s)) / BPS; }
        else { for (int32 j = 0; j > k; j--) p = (p * BPS) / (BPS + s); }
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
    }

    /// @notice Take-profit: vende TODO el base y cierra. Solo keepers, solo con tpPrice. Exige quoteOut * 1e18 >= base * tpPrice.
    function takeProfit(bytes32 id, bytes calldata route) external lock whenNotPaused onlyKeeper returns (uint256 proceeds) {
        Grid storage G = _live(id, route);
        if (G.tpPrice == 0) revert BadParams();
        uint256 base = G.baseHeld;
        if (base == 0) revert NothingToSell();
        proceeds = _close(id, G, 4, route, (base * G.tpPrice) / Q, true);
    }

    // ------------------------------ maker ------------------------------

    /// @notice El maker cierra: sellAll vende el base con SU minOut y devuelve ETH; si no, devuelve base + ETH. Funciona pausado y vencido.
    function stop(bytes32 id, bytes calldata route, uint256 minOut, bool sellAll) external lock returns (uint256 proceeds) {
        Grid storage G = _grids[id];
        if (msg.sender != G.maker) revert NotMaker();
        if (sellAll && G.baseHeld != 0 && keccak256(route) != G.routeHash) revert BadRouteHash();
        proceeds = _close(id, G, sellAll ? 0 : 1, route, minOut, sellAll);
    }

    /// @notice Pasado el expiry, cualquiera devuelve base + ETH al maker sin vender.
    function refundExpired(bytes32 id, bytes calldata route) external lock {
        Grid storage G = _grids[id];
        if (G.maker == address(0)) revert BadGrid();
        if (block.timestamp <= G.expiry) revert NotExpired();
        _close(id, G, 2, route, 0, false);
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

    // ------------------------------ vistas ------------------------------

    function grid(bytes32 id) external view returns (Grid memory) { return _grids[id]; }
    function lotAt(bytes32 id, int32 k) external view returns (Lot memory) { return _lots[id][k]; }
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
        if (G.status != Status.Open || G.lastK <= -MAX_K) return (0, 0, 0, 0);
        k = G.lastK - 1; pk = _price(G.P0, G.stepBps, k);
        if (pk < G.floorPrice) return (k, pk, 0, 0);
        uint256 curVal = (uint256(G.baseHeld) * pk) / Q;
        if (curVal >= G.V) return (k, pk, 0, 0);
        buyQuote = G.V - curVal;
        if (buyQuote > G.quoteHeld) return (k, pk, 0, 0);
        minOut = (buyQuote * Q + pk - 1) / pk;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./ArchitectBotBase.sol";

/*  ArchitectSpotGrid v3 - grid bot entre dos precios para The Desk
    v3: topUp(id, route, seedMinOut) payable, solo maker, grid abierto: reparte msg.value entre
    los N niveles (perLevel += msg.value / N) exactamente como open: la parte de los niveles en
    BASE se compra a mercado (minOut del maker, misma ruta) y se suma a esos niveles (cost += add);
    la parte de los niveles en QUOTE queda en el escrow para las compras de abajo. Mismo gBps,
    mismas lineas. Emite ToppedUp(id, maker, amountIn, baseBought).
    ---------------------------------------------------------------------------
    N niveles con precio de compra (buyPrice) y de venta (sellPrice) fijados por
    el maker, monto fijo de quote por nivel (perLevel). Cada nivel esta armado
    para comprar (QUOTE) o para vender (BASE). Los niveles por encima del precio
    de entrada nacen en BASE: el base se compra a mercado EN LA MISMA TX de
    apertura con un minOut que acepto el maker (o el maker lo deposita).

    Lo que el contrato hace cumplir (el keeper solo elige el momento):
      - fillBuy(i):  baseOut * buyPrice[i] >= perLevel * 1e18   -> compro a <= buyPrice, neto de fee
      - fillSell(i): quoteOut >= max(cost * (1 + gBps), base * sellPrice[i])  -> profit NETO >= gBps por grid
      - gBps >= 250 y sellPrice[i] >= buyPrice[i] * (1 + gBps): un grid que no
        puede ganar no se puede abrir.
      - stopLoss / takeProfit: la venta misma prueba el precio (quoteOut vs base * slPrice / tpPrice).
    El profit realizado queda en el escrow (quoteHeld) y es verificable en grid(id).profit.
    Precios: quoteWei * 1e18 / baseRaw, efectivos (netos del fee del router).
*/
contract ArchitectSpotGrid is ArchitectBotBase {
    uint16  public constant MIN_G_BPS = 250;
    uint256 public constant MAX_LEVELS = 60;
    uint256 internal constant SL_SLIP_BPS = 500;      // stop-loss: hasta 5% por debajo del SL

    uint8 internal constant QUOTE = 0;   // armado para comprar
    uint8 internal constant BASE  = 1;   // armado para vender

    /// @notice Un nivel del grid. base/cost solo cuando state == BASE.
    struct Level { uint128 buyPrice; uint128 sellPrice; uint128 base; uint128 cost; uint8 state; }

    /// @notice Parametros fijados por el maker en open*.
    /// @param perLevel quote (wei) por nivel
    /// @param gBps     profit NETO minimo por grid, en bps (>= 250)
    /// @param nSeed    cuantos niveles DE ARRIBA nacen en BASE
    /// @param slPrice  stop-loss (0 = sin); debe ser < buyPrice[0]
    /// @param tpPrice  take-profit (0 = sin); debe ser > sellPrice[n-1]
    struct Params { uint128 perLevel; uint16 gBps; uint16 nSeed; uint128 slPrice; uint128 tpPrice; uint64 expiry; uint16 feeBps; address referrer; }

    struct Grid {
        address maker;
        address token;
        address referrer;
        bytes32 routeHash;
        uint128 perLevel;
        uint128 quoteHeld;      // WETH escrowado para este grid (incluye profit)
        uint128 baseHeld;       // token escrowado para este grid
        uint128 profit;         // grid profit realizado, en quote
        uint128 slPrice;
        uint128 tpPrice;
        uint64  expiry;
        uint16  feeBps;
        uint16  gBps;
        uint16  nLevels;
        uint16  nSeed;
        Status  status;
    }

    mapping(bytes32 => Grid)    internal _grids;
    mapping(bytes32 => Level[]) internal _levels;

    event GridOpened(bytes32 indexed id, address indexed maker, address token, uint256 quoteIn, uint256 baseIn, uint16 nLevels, uint16 nSeed, uint16 gBps, uint64 expiry, uint16 feeBps, address referrer, bytes32 routeHash);
    /// @dev v3: el maker agrego fondos. amountIn = msg.value; baseBought = base comprado a mercado para los niveles en BASE.
    event ToppedUp(bytes32 indexed id, address indexed maker, uint256 amountIn, uint256 baseBought);

    constructor(address router, address weth, address keeper) ArchitectBotBase(router, weth, keeper) {}

    // ------------------------------ abrir ------------------------------

    /// @notice Abre un grid fondeado con ETH (msg.value == perLevel * n). Los nSeed niveles de arriba se compran a mercado en esta misma tx.
    /// @param route      calldata opaco del router: abi.encode(uint8 kind, bytes payload). Se guarda solo su hash.
    /// @param buyPrice   precios de compra por nivel, ascendentes (quoteWei * 1e18 / baseRaw, efectivos)
    /// @param sellPrice  precios de venta por nivel, cada uno >= buyPrice[i] * (1 + gBps)
    /// @param seedMinOut minimo de base aceptado por el maker para la compra inicial (perLevel * nSeed de quote); 0 solo si nSeed == 0
    function openWithEth(address token, bytes calldata route, Params calldata p, uint128[] calldata buyPrice, uint128[] calldata sellPrice, uint256 seedMinOut)
        external payable lock whenNotPaused returns (bytes32 id)
    {
        uint256 n = _checkOpen(token, p, buyPrice, sellPrice);
        uint256 total = uint256(p.perLevel) * n;
        if (msg.value != total) revert BadValue();
        _wrap(total);
        id = _store(token, route, p, buyPrice, sellPrice, total);
        uint256 baseOut;
        if (p.nSeed != 0) {
            Grid storage G = _grids[id];
            uint256 seedQuote = uint256(p.perLevel) * p.nSeed;
            G.quoteHeld -= uint128(seedQuote);
            escrowed[WETH] -= seedQuote;
            baseOut = _buy(token, p.feeBps, G.referrer, seedQuote, seedMinOut, route);
            _armSeed(id, G, baseOut);
        }
        emit GridOpened(id, msg.sender, token, total, baseOut, uint16(n), p.nSeed, p.gBps, p.expiry, p.feeBps, _grids[id].referrer, keccak256(route));
    }

    /// @notice Abre un grid aportando el base directamente: msg.value == perLevel * (n - nSeed) y baseAmount del token (approve a este contrato).
    ///         El base se reparte en los nSeed niveles de arriba con cost = perLevel cada uno.
    function openWithBase(address token, bytes calldata route, Params calldata p, uint128[] calldata buyPrice, uint128[] calldata sellPrice, uint256 baseAmount)
        external payable lock whenNotPaused returns (bytes32 id)
    {
        uint256 n = _checkOpen(token, p, buyPrice, sellPrice);
        if (p.nSeed == 0 || baseAmount == 0 || baseAmount > type(uint128).max) revert BadParams();
        uint256 quoteIn = uint256(p.perLevel) * (n - p.nSeed);
        if (msg.value != quoteIn) revert BadValue();
        _wrap(quoteIn);
        _pull(token, msg.sender, baseAmount);
        id = _store(token, route, p, buyPrice, sellPrice, quoteIn);
        _armSeed(id, _grids[id], baseAmount);
        emit GridOpened(id, msg.sender, token, quoteIn, baseAmount, uint16(n), p.nSeed, p.gBps, p.expiry, p.feeBps, _grids[id].referrer, keccak256(route));
    }

    function _checkOpen(address token, Params calldata p, uint128[] calldata buyPrice, uint128[] calldata sellPrice) internal view returns (uint256 n) {
        _checkCommon(token, p.expiry, p.feeBps);
        n = buyPrice.length;
        if (n == 0 || n > MAX_LEVELS || sellPrice.length != n) revert BadParams();
        if (p.perLevel == 0 || p.gBps < MIN_G_BPS || p.gBps > BPS || p.nSeed > n) revert BadParams();
        if (uint256(p.perLevel) * n > type(uint128).max) revert BadParams();
        for (uint256 i = 0; i < n; i++) {
            if (buyPrice[i] == 0) revert BadParams();
            if (i != 0 && buyPrice[i] <= buyPrice[i - 1]) revert BadParams();
            // el grid tiene que poder ganar gBps neto en cada nivel
            if (uint256(sellPrice[i]) < (uint256(buyPrice[i]) * (BPS + p.gBps)) / BPS) revert BadParams();
        }
        if (p.slPrice != 0 && p.slPrice >= buyPrice[0]) revert BadParams();
        if (p.tpPrice != 0 && p.tpPrice <= sellPrice[n - 1]) revert BadParams();
    }

    function _store(address token, bytes calldata route, Params calldata p, uint128[] calldata buyPrice, uint128[] calldata sellPrice, uint256 quoteIn) internal returns (bytes32 id) {
        id = _newId();
        Grid storage G = _grids[id];
        G.maker = msg.sender;
        G.token = token;
        G.referrer = p.referrer == msg.sender ? address(0) : p.referrer;
        G.routeHash = keccak256(route);
        G.perLevel = p.perLevel;
        G.quoteHeld = uint128(quoteIn);
        G.slPrice = p.slPrice;
        G.tpPrice = p.tpPrice;
        G.expiry = p.expiry;
        G.feeBps = p.feeBps;
        G.gBps = p.gBps;
        G.nLevels = uint16(buyPrice.length);
        G.nSeed = p.nSeed;
        Level[] storage L = _levels[id];
        for (uint256 i = 0; i < buyPrice.length; i++) L.push(Level({ buyPrice: buyPrice[i], sellPrice: sellPrice[i], base: 0, cost: 0, state: QUOTE }));
    }

    /// Reparte el base entre los nSeed niveles de arriba (el resto del redondeo va al ultimo).
    function _armSeed(bytes32 id, Grid storage G, uint256 baseIn) internal {
        if (baseIn > type(uint128).max) revert BadValue();
        escrowed[G.token] += baseIn;
        G.baseHeld += uint128(baseIn);
        Level[] storage L = _levels[id];
        uint256 n = G.nLevels; uint256 s = G.nSeed;
        uint256 per = baseIn / s;
        for (uint256 j = 0; j < s; j++) {
            Level storage lv = L[n - s + j];
            lv.base = uint128(j == s - 1 ? baseIn - per * (s - 1) : per);
            lv.cost = G.perLevel;
            lv.state = BASE;
        }
    }

    // ------------------------------ keeper ------------------------------

    function _live(bytes32 id, bytes calldata route) internal view returns (Grid storage G) {
        G = _grids[id];
        if (G.maker == address(0)) revert BadGrid();
        if (G.status != Status.Open) revert NotOpen();
        if (block.timestamp > G.expiry) revert Expired();
        if (keccak256(route) != G.routeHash) revert BadRouteHash();
    }

    /// @notice Compra el nivel i con perLevel de quote. Solo keepers. Exige baseOut * buyPrice[i] >= perLevel * 1e18.
    function fillBuy(bytes32 id, uint256 i, bytes calldata route) external lock whenNotPaused onlyKeeper returns (uint256 amountOut) {
        Grid storage G = _live(id, route);
        if (i >= G.nLevels) revert BadLevel();
        Level storage L = _levels[id][i];
        if (L.state != QUOTE) revert BadLevel();
        uint256 q = G.perLevel;
        if (q > G.quoteHeld) revert InsufficientBudget();
        uint256 minOut = (q * Q + L.buyPrice - 1) / L.buyPrice;      // ceil: nunca por encima de buyPrice
        // CEI
        G.quoteHeld -= uint128(q);
        escrowed[WETH] -= q;
        L.state = BASE;
        L.cost = uint128(q);
        amountOut = _buy(G.token, G.feeBps, G.referrer, q, minOut, route);
        if (amountOut > type(uint128).max) revert BadValue();
        L.base = uint128(amountOut);
        G.baseHeld += uint128(amountOut);
        escrowed[G.token] += amountOut;
        emit GridFilled(id, G.maker, msg.sender, int256(i), 0, q, amountOut, 0);
    }

    /// @notice Vende el base del nivel i. Solo keepers. Exige quoteOut >= max(cost * (1 + gBps), base * sellPrice[i]): profit neto garantizado.
    function fillSell(bytes32 id, uint256 i, bytes calldata route) external lock whenNotPaused onlyKeeper returns (uint256 amountOut) {
        Grid storage G = _live(id, route);
        if (i >= G.nLevels) revert BadLevel();
        Level storage L = _levels[id][i];
        if (L.state != BASE) revert BadLevel();
        uint256 base = L.base; uint256 cost = L.cost;
        if (base == 0) revert NothingToSell();
        uint256 minOut = (cost * (BPS + G.gBps)) / BPS;
        uint256 byLine = (base * L.sellPrice) / Q;
        if (byLine > minOut) minOut = byLine;
        // CEI
        L.base = 0; L.cost = 0; L.state = QUOTE;
        G.baseHeld -= uint128(base);
        escrowed[G.token] -= base;
        amountOut = _sell(G.token, G.feeBps, G.referrer, base, minOut, route);
        if (amountOut > type(uint128).max) revert BadValue();
        escrowed[WETH] += amountOut;
        G.quoteHeld += uint128(amountOut);
        uint256 gain = amountOut - cost;
        G.profit += uint128(gain);
        emit GridFilled(id, G.maker, msg.sender, int256(i), 1, base, amountOut, gain);
    }

    /// @notice Stop-loss: vende TODO el base y cierra. Solo keepers, solo con slPrice. La venta prueba que el precio esta <= slPrice.
    /// @param minOut piso del keeper; el contrato impone al menos base * slPrice * 0.95.
    function stopLoss(bytes32 id, bytes calldata route, uint256 minOut) external lock whenNotPaused onlyKeeper returns (uint256 proceeds) {
        Grid storage G = _live(id, route);
        if (G.slPrice == 0) revert BadParams();
        uint256 base = G.baseHeld;
        if (base == 0) revert NothingToSell();
        uint256 floor = (base * G.slPrice * (BPS - SL_SLIP_BPS)) / (Q * BPS);
        if (minOut < floor) minOut = floor;
        proceeds = _close(id, G, 3, route, minOut, true);
        if (proceeds * Q > base * G.slPrice) revert PriceNotReached(proceeds, (base * G.slPrice) / Q);
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

    /// @notice v3: el maker agrega fondos a un grid abierto, repartidos como en open: perLevel += msg.value / N. Los niveles en BASE
    ///         reciben base comprado a mercado (seedMinOut del maker, misma ruta; cost += add cada uno), los niveles en QUOTE
    ///         quedan cubiertos por el escrow. El resto del redondeo queda en quoteHeld (vuelve al maker al cerrar).
    function topUp(bytes32 id, bytes calldata route, uint256 seedMinOut) external payable lock whenNotPaused returns (uint256 baseOut) {
        Grid storage G = _live(id, route);
        if (msg.sender != G.maker) revert NotMaker();
        uint256 n = G.nLevels;
        uint256 add = msg.value / n;
        if (add == 0 || msg.value > type(uint128).max) revert BadValue();
        if ((uint256(G.perLevel) + add) * n > type(uint128).max || uint256(G.quoteHeld) + msg.value > type(uint128).max) revert BadValue();
        Level[] storage L = _levels[id];
        uint256 nBase;
        for (uint256 i = 0; i < n; i++) if (L[i].state == BASE) nBase++;
        uint256 seedQuote = add * nBase;
        _wrap(msg.value);
        G.perLevel += uint128(add);
        G.quoteHeld += uint128(msg.value - seedQuote);
        if (nBase != 0) {
            escrowed[WETH] -= seedQuote;
            baseOut = _buy(G.token, G.feeBps, G.referrer, seedQuote, seedMinOut, route);
            if (baseOut > type(uint128).max) revert BadValue();
            escrowed[G.token] += baseOut;
            G.baseHeld += uint128(baseOut);
            uint256 per = baseOut / nBase; uint256 left = baseOut; uint256 j;
            for (uint256 i = 0; i < n; i++) {
                Level storage lv = L[i];
                if (lv.state != BASE) continue;
                j++;
                uint256 share = j == nBase ? left : per;
                left -= share;
                lv.base += uint128(share);
                lv.cost += uint128(add);
            }
        }
        emit ToppedUp(id, msg.sender, msg.value, baseOut);
    }

    function _close(bytes32 id, Grid storage G, uint8 kind, bytes calldata route, uint256 minOut, bool sell) internal returns (uint256 proceeds) {
        if (G.status != Status.Open) revert NotOpen();
        uint256 base = G.baseHeld; uint256 quote = G.quoteHeld;
        G.status = Status.Stopped;
        G.baseHeld = 0; G.quoteHeld = 0;
        uint256 baseRet;
        (proceeds, baseRet) = _settle(G.token, G.feeBps, G.referrer, G.maker, base, quote, route, minOut, sell);
        emit GridStopped(id, G.maker, kind, sell ? base : 0, proceeds, baseRet, quote);
    }

    // ------------------------------ vistas ------------------------------

    function grid(bytes32 id) external view returns (Grid memory) { return _grids[id]; }
    function levels(bytes32 id) external view returns (Level[] memory) { return _levels[id]; }
    function isOpen(bytes32 id) external view returns (bool) {
        Grid storage G = _grids[id];
        return G.maker != address(0) && G.status == Status.Open;
    }
    /// @notice minOut que fillBuy exigira para el nivel i (0 si no esta armado para comprar).
    function buyMinOut(bytes32 id, uint256 i) external view returns (uint256) {
        Grid storage G = _grids[id]; Level storage L = _levels[id][i];
        if (G.status != Status.Open || L.state != QUOTE) return 0;
        return (uint256(G.perLevel) * Q + L.buyPrice - 1) / L.buyPrice;
    }
    /// @notice minOut que fillSell exigira para el nivel i (0 si no esta armado para vender).
    function sellMinOut(bytes32 id, uint256 i) external view returns (uint256) {
        Grid storage G = _grids[id]; Level storage L = _levels[id][i];
        if (G.status != Status.Open || L.state != BASE) return 0;
        uint256 m = (uint256(L.cost) * (BPS + G.gBps)) / BPS;
        uint256 byLine = (uint256(L.base) * L.sellPrice) / Q;
        return byLine > m ? byLine : m;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./ArchitectBotBaseStable.sol";

/*  ArchitectSpotGridUSDG - ArchitectSpotGrid v3 con quote USDG (6 decimales).
    ---------------------------------------------------------------------------
    Logica de grid IDENTICA a ArchitectSpotGrid v3 (src/ArchitectSpotGrid.sol,
    verificada byte a byte contra 0x994Cf0A4f0E876f52f3b76a2856D93924DA71511).
    Cambia SOLO la capa de quote:

      openWithEth(...) payable, msg.value == perLevel * n
        -> openWithQuote(...), cobra perLevel * n de USDG por transferFrom
      openWithBase(...) payable, msg.value == perLevel * (n - nSeed)
        -> openWithBase(...), cobra perLevel * (n - nSeed) de USDG + baseAmount del token
      topUp(id, route, seedMinOut) payable
        -> topUp(id, amountIn, route, seedMinOut)
      stop / refundExpired devuelven USDG por transfer (no unwrap + call{value})

    Endurecimientos por los 6 decimales (todos a favor del usuario, ver informe):
      - todo precio pasa por _checkPrice (MIN_PRICE 100, MAX_PRICE 2^112);
      - perLevel >= MIN_QUOTE (0.10 USDG): con 6 decimales, montos mas chicos
        hacen que 1 unidad raw sea una fraccion no despreciable del nivel;
      - los minOut que exige el contrato se redondean HACIA ARRIBA (ceil) en vez
        de truncar: con 18 decimales truncar costaba 1e-18 ETH, con 6 cuesta
        1e-6 USDG por fill y siempre en contra del maker;
      - el piso del stop-loss se calcula sin el producto triple base*price*BPS.

    Eventos y storage con la MISMA forma que v3: el backend los lee igual.
*/
contract ArchitectSpotGridUSDG is ArchitectBotBaseStable {
    uint16  public constant MIN_G_BPS = 250;
    uint256 public constant MAX_LEVELS = 60;
    uint256 internal constant SL_SLIP_BPS = 500;      // stop-loss: hasta 5% por debajo del SL

    uint8 internal constant QUOTE_S = 0;   // armado para comprar
    uint8 internal constant BASE    = 1;   // armado para vender

    /// @notice Un nivel del grid. base/cost solo cuando state == BASE.
    struct Level { uint128 buyPrice; uint128 sellPrice; uint128 base; uint128 cost; uint8 state; }

    /// @notice Parametros fijados por el maker en open*.
    /// @param perLevel quote (raw USDG) por nivel
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
        uint128 quoteHeld;      // USDG escrowado para este grid (incluye profit)
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
    /// @dev el maker agrego fondos. amountIn = USDG aportado; baseBought = base comprado a mercado para los niveles en BASE.
    event ToppedUp(bytes32 indexed id, address indexed maker, uint256 amountIn, uint256 baseBought);

    constructor(address router, address quote, address keeper) ArchitectBotBaseStable(router, quote, keeper) {}

    // ------------------------------ abrir ------------------------------

    /// @notice Abre un grid fondeado con USDG (cobra perLevel * n por transferFrom; el maker tiene que aprobar antes).
    ///         Los nSeed niveles de arriba se compran a mercado en esta misma tx.
    /// @param route      calldata opaco del router: abi.encode(uint8 kind, bytes payload). Se guarda solo su hash.
    /// @param buyPrice   precios de compra por nivel, ascendentes (quoteRaw * 1e18 / baseRaw, efectivos)
    /// @param sellPrice  precios de venta por nivel, cada uno >= buyPrice[i] * (1 + gBps)
    /// @param seedMinOut minimo de base aceptado por el maker para la compra inicial; 0 solo si nSeed == 0
    function openWithQuote(address token, bytes calldata route, Params calldata p, uint128[] calldata buyPrice, uint128[] calldata sellPrice, uint256 seedMinOut)
        external lock whenNotPaused returns (bytes32 id)
    {
        uint256 n = _checkOpen(token, p, buyPrice, sellPrice);
        uint256 total = uint256(p.perLevel) * n;
        _pullQuote(total);
        id = _store(token, route, p, buyPrice, sellPrice, total);
        uint256 baseOut;
        if (p.nSeed != 0) {
            Grid storage G = _grids[id];
            uint256 seedQuote = uint256(p.perLevel) * p.nSeed;
            G.quoteHeld -= uint128(seedQuote);
            escrowed[QUOTE] -= seedQuote;
            baseOut = _buy(token, p.feeBps, G.referrer, seedQuote, seedMinOut, route);
            _armSeed(id, G, baseOut);
        }
        emit GridOpened(id, msg.sender, token, total, baseOut, uint16(n), p.nSeed, p.gBps, p.expiry, p.feeBps, _grids[id].referrer, keccak256(route));
    }

    /// @notice Abre aportando el base directamente: cobra perLevel * (n - nSeed) de USDG y baseAmount del token
    ///         (ambos por transferFrom: aprobar los dos). El base se reparte en los nSeed niveles de arriba con cost = perLevel cada uno.
    function openWithBase(address token, bytes calldata route, Params calldata p, uint128[] calldata buyPrice, uint128[] calldata sellPrice, uint256 baseAmount)
        external lock whenNotPaused returns (bytes32 id)
    {
        uint256 n = _checkOpen(token, p, buyPrice, sellPrice);
        if (p.nSeed == 0 || baseAmount == 0 || baseAmount > type(uint128).max) revert BadParams();
        uint256 quoteIn = uint256(p.perLevel) * (n - p.nSeed);
        _pullQuote(quoteIn);
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
        // 6 decimales: por debajo de 0.1 USDG el redondeo de 1 unidad raw pesa demasiado
        if (p.perLevel < MIN_QUOTE) revert AmountTooSmall(p.perLevel, MIN_QUOTE);
        if (uint256(p.perLevel) * n > type(uint128).max) revert BadParams();
        for (uint256 i = 0; i < n; i++) {
            _checkPrice(buyPrice[i]);
            _checkPrice(sellPrice[i]);
            if (i != 0 && buyPrice[i] <= buyPrice[i - 1]) revert BadParams();
            // el grid tiene que poder ganar gBps neto en cada nivel
            if (uint256(sellPrice[i]) < _ceilDiv(uint256(buyPrice[i]) * (BPS + p.gBps), BPS)) revert BadParams();
        }
        if (p.slPrice != 0) { _checkPrice(p.slPrice); if (p.slPrice >= buyPrice[0]) revert BadParams(); }
        if (p.tpPrice != 0) { _checkPrice(p.tpPrice); if (p.tpPrice <= sellPrice[n - 1]) revert BadParams(); }
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
        for (uint256 i = 0; i < buyPrice.length; i++) L.push(Level({ buyPrice: buyPrice[i], sellPrice: sellPrice[i], base: 0, cost: 0, state: QUOTE_S }));
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
        if (L.state != QUOTE_S) revert BadLevel();
        uint256 q = G.perLevel;
        if (q > G.quoteHeld) revert InsufficientBudget();
        uint256 minOut = _ceilDiv(q * Q, L.buyPrice);                // ceil: nunca por encima de buyPrice
        // CEI
        G.quoteHeld -= uint128(q);
        escrowed[QUOTE] -= q;
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
        // ceil en los dos: con 6 decimales truncar regalaba hasta 1 unidad raw por fill
        uint256 minOut = _ceilDiv(cost * (BPS + G.gBps), BPS);
        uint256 byLine = _ceilDiv(base * L.sellPrice, Q);
        if (byLine > minOut) minOut = byLine;
        // CEI
        L.base = 0; L.cost = 0; L.state = QUOTE_S;
        G.baseHeld -= uint128(base);
        escrowed[G.token] -= base;
        amountOut = _sell(G.token, G.feeBps, G.referrer, base, minOut, route);
        if (amountOut > type(uint128).max) revert BadValue();
        escrowed[QUOTE] += amountOut;
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
        uint256 floor = _slFloor(base, G.slPrice);
        if (minOut < floor) minOut = floor;
        uint256 slp = G.slPrice;
        proceeds = _close(id, G, 3, route, minOut, true);
        if (proceeds * Q > base * slp) revert PriceNotReached(proceeds, (base * slp) / Q);
    }

    /// Piso del stop-loss sin el producto triple base*price*BPS (desbordaria con uint128 al limite),
    /// y con ceil en las dos divisiones (siempre a favor del maker).
    function _slFloor(uint256 base, uint256 slPrice) internal pure returns (uint256) {
        return _ceilDiv(_ceilDiv(base * slPrice, Q) * (BPS - SL_SLIP_BPS), BPS);
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

    /// @notice Pasado el expiry, cualquiera devuelve base + USDG al maker sin vender.
    function refundExpired(bytes32 id, bytes calldata route) external lock {
        Grid storage G = _grids[id];
        if (G.maker == address(0)) revert BadGrid();
        if (block.timestamp <= G.expiry) revert NotExpired();
        _close(id, G, 2, route, 0, false);
    }

    /// @notice El maker agrega fondos a un grid abierto, repartidos como en open: perLevel += amountIn / N.
    ///         Los niveles en BASE reciben base comprado a mercado (seedMinOut del maker, misma ruta; cost += add cada uno),
    ///         los niveles en QUOTE quedan cubiertos por el escrow. El resto del redondeo queda en quoteHeld
    ///         (vuelve al maker al cerrar). Cobra amountIn de USDG por transferFrom.
    function topUp(bytes32 id, uint256 amountIn, bytes calldata route, uint256 seedMinOut) external lock whenNotPaused returns (uint256 baseOut) {
        Grid storage G = _live(id, route);
        if (msg.sender != G.maker) revert NotMaker();
        uint256 n = G.nLevels;
        uint256 add = amountIn / n;
        if (add == 0 || amountIn > type(uint128).max) revert BadValue();
        if ((uint256(G.perLevel) + add) * n > type(uint128).max || uint256(G.quoteHeld) + amountIn > type(uint128).max) revert BadValue();
        Level[] storage L = _levels[id];
        uint256 nBase;
        for (uint256 i = 0; i < n; i++) if (L[i].state == BASE) nBase++;
        uint256 seedQuote = add * nBase;
        _pullQuote(amountIn);
        G.perLevel += uint128(add);
        G.quoteHeld += uint128(amountIn - seedQuote);
        if (nBase != 0) {
            escrowed[QUOTE] -= seedQuote;
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
        emit ToppedUp(id, msg.sender, amountIn, baseOut);
    }

    function _close(bytes32 id, Grid storage G, uint8 kind, bytes calldata route, uint256 minOut, bool sell) internal returns (uint256 proceeds) {
        proceeds = _closeTo(id, G, kind, route, minOut, sell, G.maker);
    }

    function _closeTo(bytes32 id, Grid storage G, uint8 kind, bytes calldata route, uint256 minOut, bool sell, address to) internal returns (uint256 proceeds) {
        if (G.status != Status.Open) revert NotOpen();
        uint256 base = G.baseHeld; uint256 quote = G.quoteHeld;
        G.status = Status.Stopped;
        G.baseHeld = 0; G.quoteHeld = 0;
        uint256 baseRet;
        (proceeds, baseRet) = _settle(G.token, G.feeBps, G.referrer, to, base, quote, route, minOut, sell);
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
        if (G.status != Status.Open || L.state != QUOTE_S) return 0;
        return _ceilDiv(uint256(G.perLevel) * Q, L.buyPrice);
    }
    /// @notice minOut que fillSell exigira para el nivel i (0 si no esta armado para vender).
    function sellMinOut(bytes32 id, uint256 i) external view returns (uint256) {
        Grid storage G = _grids[id]; Level storage L = _levels[id][i];
        if (G.status != Status.Open || L.state != BASE) return 0;
        uint256 m = _ceilDiv(uint256(L.cost) * (BPS + G.gBps), BPS);
        uint256 byLine = _ceilDiv(uint256(L.base) * L.sellPrice, Q);
        return byLine > m ? byLine : m;
    }
    /// @notice Piso de quote que stopLoss exige (0 si no hay SL, nada que vender o el grid no esta abierto).
    function slMinOut(bytes32 id) external view returns (uint256) {
        Grid storage G = _grids[id];
        if (G.status != Status.Open || G.slPrice == 0 || G.baseHeld == 0) return 0;
        return _slFloor(G.baseHeld, G.slPrice);
    }
}

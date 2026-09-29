// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./ArchitectBotBase.sol";

/*  ArchitectSpotGrid v4 - grid bot entre dos precios para The Desk
    ---------------------------------------------------------------------------
    v4 = v3 + dos cosas, y nada mas:

    1. RESERVA DE GAS: cada grid paga a su propio keeper.
       El maker deposita una reserva (WETH) al abrir y al hacer topUp. Al final
       de cada fill del keeper (fillBuy, fillSell, stopLoss, takeProfit) el
       contrato mide el gas usado, lo cobra de la reserva y se lo paga al keeper
       en WETH, en la misma tx. Si la reserva no alcanza, revierte NoGas(): el
       keeper hace staticCall antes de mandar, asi que un grid sin reserva se
       saltea, no falla. Al cerrar, lo que sobra vuelve al maker.

       Por que es exacto en ESTA cadena: no hay fee de prioridad (tx.gasprice ==
       basefee, verificado) y ArbGasInfo.perL1CalldataByte == 0 (no se cobra
       posteo a L1). En Ethereum o en Arbitrum One esto NO seria exacto y el
       diseño no se puede copiar sin cambiarlo.

       La reserva vive ADENTRO de escrowed[WETH], con la misma proteccion que el
       capital: rescue() calcula el excedente como balance - escrowed y si la
       reserva quedara afuera el owner podria barrerla. gasEscrowed es un
       sub-libro para el invariante gasEscrowed <= escrowed[WETH].

       Se paga en WETH y no en ETH nativo a proposito: un call{gas:2300} rompe
       el dia que el keeper sea un contrato (bundler, cuenta 4337).

    2. REINVERSION (compound): la ganancia crece la grilla.
       `profit` sigue siendo el realizado de por vida y NUNCA baja: es el numero
       que el maker ve. `profitFree` es la parte todavia no reinvertida. Con
       compound activo, cada fillBuy compra perLevel + profitFree / nLevels y
       absorbe ese boost. La plata ya esta en quoteHeld (el profit queda ahi),
       asi que no hay movimiento nuevo: es una compra mas grande con plata que
       ya era del grid. `cost` registra el lote mayor y minOut = cost*(1+gBps)
       escala solo: la garantia de gBps neto se mantiene sobre el lote grande.

    Lo que NO cambia: la comision (se cobra en el router, en _buy/_sell), la
    maquina de estados de los niveles, topUp, stop, refundExpired, y todos los
    invariantes de v3.
*/
contract ArchitectSpotGridV4 is ArchitectBotBase {
    uint16  public constant MIN_G_BPS = 250;
    uint256 public constant MAX_LEVELS = 60;
    uint256 internal constant SL_SLIP_BPS = 500;      // stop-loss: hasta 5% por debajo del SL
    uint256 public  constant MAX_GAS_OVERHEAD = 200_000;

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
    /// @param compound v4: la ganancia realizada se reinvierte en las compras siguientes
    struct Params { uint128 perLevel; uint16 gBps; uint16 nSeed; uint128 slPrice; uint128 tpPrice; uint64 expiry; uint16 feeBps; address referrer; bool compound; }

    struct Grid {
        address maker;
        address token;
        address referrer;
        bytes32 routeHash;
        uint128 perLevel;
        uint128 quoteHeld;      // WETH escrowado para este grid (incluye profit)
        uint128 baseHeld;       // token escrowado para este grid
        uint128 profit;         // grid profit realizado de por vida, en quote. NUNCA baja.
        uint128 profitFree;     // v4: profit todavia no reinvertido (solo crece con compound)
        uint128 gasReserve;     // v4: WETH reservado para pagar al keeper. Dentro de escrowed[WETH].
        uint128 slPrice;
        uint128 tpPrice;
        uint64  expiry;
        uint16  feeBps;
        uint16  gBps;
        uint16  nLevels;
        uint16  nSeed;
        bool    compound;       // v4
        Status  status;
    }

    mapping(bytes32 => Grid)    internal _grids;
    mapping(bytes32 => Level[]) internal _levels;

    /// @notice v4: suma de todas las reservas de gas. Invariante: gasEscrowed <= escrowed[WETH].
    uint256 public gasEscrowed;
    /// @notice v4: gas que gasleft() no ve (intrinsecos, calldata, modifiers, el propio pago). Owner-settable, acotado.
    ///         Medido en fork: lo no medido varia entre 49k y 68k segun el estado (frio/caliente). Con 50k el keeper
    ///         quedo al 97-100 % del costo real; 80k lo deja al 105-110 %, que es el lado correcto del error.
    uint256 public gasOverhead = 80_000;

    event GridOpened(bytes32 indexed id, address indexed maker, address token, uint256 quoteIn, uint256 baseIn, uint16 nLevels, uint16 nSeed, uint16 gBps, uint64 expiry, uint16 feeBps, address referrer, bytes32 routeHash);
    /// @dev v3: el maker agrego fondos. amountIn = capital agregado; baseBought = base comprado a mercado para los niveles en BASE.
    event ToppedUp(bytes32 indexed id, address indexed maker, uint256 amountIn, uint256 baseBought);
    /// @dev v4: el keeper cobro `owed` de la reserva del grid. `remaining` es lo que queda.
    event GasPaid(bytes32 indexed id, address indexed keeper, uint256 owed, uint256 remaining);
    /// @dev v4: entro reserva de gas (open o topUp).
    event GasAdded(bytes32 indexed id, address indexed maker, uint256 amount);
    /// @dev v4: al cerrar, la reserva que sobro volvio al maker.
    event GasRefunded(bytes32 indexed id, address indexed maker, uint256 amount);
    /// @dev v4: un fillBuy compro `boost` de mas con ganancia reinvertida.
    event Reinvested(bytes32 indexed id, uint256 level, uint256 boost);
    event CompoundSet(bytes32 indexed id, bool compound);
    event GasOverheadSet(uint256 overhead);

    error NoGas(uint256 owed, uint256 reserve);
    error GasPayFailed();

    constructor(address router, address weth, address keeper) ArchitectBotBase(router, weth, keeper) {}

    // ------------------------------ abrir ------------------------------

    /// @notice Abre un grid fondeado con ETH: msg.value == perLevel * n + gasReserve. Los nSeed niveles de arriba se compran a mercado en esta misma tx.
    /// @param route      calldata opaco del router: abi.encode(uint8 kind, bytes payload). Se guarda solo su hash.
    /// @param buyPrice   precios de compra por nivel, ascendentes (quoteWei * 1e18 / baseRaw, efectivos)
    /// @param sellPrice  precios de venta por nivel, cada uno >= buyPrice[i] * (1 + gBps)
    /// @param seedMinOut minimo de base aceptado por el maker para la compra inicial (perLevel * nSeed de quote); 0 solo si nSeed == 0
    /// @param gasReserve v4: WETH que este grid reserva para pagar a su keeper (puede ser 0: el grid no se llena hasta que haya)
    function openWithEth(address token, bytes calldata route, Params calldata p, uint128[] calldata buyPrice, uint128[] calldata sellPrice, uint256 seedMinOut, uint256 gasReserve)
        external payable lock whenNotPaused returns (bytes32 id)
    {
        uint256 n = _checkOpen(token, p, buyPrice, sellPrice);
        uint256 total = uint256(p.perLevel) * n;
        if (msg.value != total + gasReserve || gasReserve > type(uint128).max) revert BadValue();
        _wrap(total + gasReserve);
        id = _store(token, route, p, buyPrice, sellPrice, total, gasReserve);
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

    /// @notice Abre un grid aportando el base directamente: msg.value == perLevel * (n - nSeed) + gasReserve y baseAmount del token (approve a este contrato).
    function openWithBase(address token, bytes calldata route, Params calldata p, uint128[] calldata buyPrice, uint128[] calldata sellPrice, uint256 baseAmount, uint256 gasReserve)
        external payable lock whenNotPaused returns (bytes32 id)
    {
        uint256 n = _checkOpen(token, p, buyPrice, sellPrice);
        if (p.nSeed == 0 || baseAmount == 0 || baseAmount > type(uint128).max) revert BadParams();
        uint256 quoteIn = uint256(p.perLevel) * (n - p.nSeed);
        if (msg.value != quoteIn + gasReserve || gasReserve > type(uint128).max) revert BadValue();
        _wrap(quoteIn + gasReserve);
        _pull(token, msg.sender, baseAmount);
        id = _store(token, route, p, buyPrice, sellPrice, quoteIn, gasReserve);
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

    function _store(address token, bytes calldata route, Params calldata p, uint128[] calldata buyPrice, uint128[] calldata sellPrice, uint256 quoteIn, uint256 gasReserve) internal returns (bytes32 id) {
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
        G.compound = p.compound;
        if (gasReserve != 0) {
            G.gasReserve = uint128(gasReserve);
            gasEscrowed += gasReserve;
            emit GasAdded(id, msg.sender, gasReserve);
        }
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

    // ------------------------------ v4: gas ------------------------------

    /// Cobra al grid el gas de esta tx y se lo paga al keeper en WETH. Va al FINAL de cada fill,
    /// despues de todo el estado y de la llamada al router (CEI). gasOverhead cubre lo que
    /// gasleft() no ve. En esta cadena tx.gasprice == basefee: el keeper no lo puede inflar.
    /// @param soft  true en stopLoss / takeProfit. Son la PROTECCION del maker: una reserva vacia no puede dejarlo
    ///              sin stop-loss. Ahi se cobra lo que haya y nunca se revierte por gas (auditoria F1).
    function _payGas(bytes32 id, Grid storage G, uint256 g0, bool soft) internal {
        // max(tx.gasprice, block.basefee): en un eth_call tx.gasprice es 0 y NoGas nunca dispararia, asi que el
        // staticCall de pre-flight del keeper seria ciego y la tx real revertiria sin pago. block.basefee SI esta
        // definido en eth_call. En esta cadena los dos son iguales en toda tx real (verificado 2.485/2.485);
        // el max cubre el dia que exista fee de prioridad, para que el keeper no quede corto.
        uint256 price = tx.gasprice > block.basefee ? tx.gasprice : block.basefee;
        uint256 owed = ((g0 - gasleft()) + gasOverhead) * price;
        uint256 reserve = G.gasReserve;
        if (owed > reserve) {
            if (!soft) revert NoGas(owed, reserve);
            owed = reserve;                              // proteccion: se cobra lo que hay
        }
        if (owed == 0) return;
        G.gasReserve = uint128(reserve - owed);
        gasEscrowed   -= owed;
        escrowed[WETH] -= owed;
        if (!IERC20(WETH).transfer(msg.sender, owed)) revert GasPayFailed();
        emit GasPaid(id, msg.sender, owed, reserve - owed);
    }

    /// Al cerrar: la reserva que sobro vuelve al maker como ETH (con el mismo pendingEth de siempre si su receive() es caro).
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

    /// @notice Compra el nivel i. Solo keepers. Exige baseOut * buyPrice[i] >= q * 1e18, con q = perLevel (+ boost si compound).
    function fillBuy(bytes32 id, uint256 i, bytes calldata route) external lock whenNotPaused onlyKeeper returns (uint256 amountOut) {
        uint256 g0 = gasleft();
        Grid storage G = _live(id, route);
        if (i >= G.nLevels) revert BadLevel();
        Level storage L = _levels[id][i];
        if (L.state != QUOTE) revert BadLevel();
        uint256 q = G.perLevel;
        // v4: la ganancia reinvertida se reparte en la escalera. La plata ya esta en quoteHeld.
        uint256 boost;
        if (G.compound && G.profitFree != 0) {
            boost = uint256(G.profitFree) / G.nLevels;
            if (boost != 0) { q += boost; G.profitFree -= uint128(boost); }
        }
        if (q > G.quoteHeld || q > type(uint128).max) revert InsufficientBudget();
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
        if (boost != 0) emit Reinvested(id, i, boost);
        _payGas(id, G, g0, false);
    }

    /// @notice Vende el base del nivel i. Solo keepers. Exige quoteOut >= max(cost * (1 + gBps), base * sellPrice[i]): profit neto garantizado.
    function fillSell(bytes32 id, uint256 i, bytes calldata route) external lock whenNotPaused onlyKeeper returns (uint256 amountOut) {
        uint256 g0 = gasleft();
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
        if (G.compound) G.profitFree += uint128(gain);     // v4
        emit GridFilled(id, G.maker, msg.sender, int256(i), 1, base, amountOut, gain);
        _payGas(id, G, g0, false);
    }

    /// @notice Stop-loss: vende TODO el base y cierra. Solo keepers, solo con slPrice. La venta prueba que el precio esta <= slPrice.
    /// @param minOut piso del keeper; el contrato impone al menos base * slPrice * 0.95.
    function stopLoss(bytes32 id, bytes calldata route, uint256 minOut) external lock whenNotPaused onlyKeeper returns (uint256 proceeds) {
        uint256 g0 = gasleft();
        Grid storage G = _live(id, route);
        if (G.slPrice == 0) revert BadParams();
        uint256 base = G.baseHeld;
        if (base == 0) revert NothingToSell();
        uint256 floor = (base * G.slPrice * (BPS - SL_SLIP_BPS)) / (Q * BPS);
        if (minOut < floor) minOut = floor;
        proceeds = _close(id, G, 3, route, minOut, true);
        if (proceeds * Q > base * G.slPrice) revert PriceNotReached(proceeds, (base * G.slPrice) / Q);
        _payGas(id, G, g0, true);     // soft: el stop-loss protege al maker aunque la reserva este vacia
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
        _payGas(id, G, g0, true);     // soft: idem stop-loss
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

    /// @notice Pasado el expiry, cualquiera devuelve base + ETH (+ reserva de gas) al maker sin vender.
    function refundExpired(bytes32 id, bytes calldata route) external lock {
        Grid storage G = _grids[id];
        if (G.maker == address(0)) revert BadGrid();
        if (block.timestamp <= G.expiry) revert NotExpired();
        _close(id, G, 2, route, 0, false);
        _refundGas(id, G);
    }

    /// @notice v3: el maker agrega capital a un grid abierto (perLevel += capital / N, los niveles en BASE compran a mercado).
    ///         v4: msg.value = capital + gasAdd. Se puede cargar SOLO gas (capital = 0) sin tocar la grilla.
    function topUp(bytes32 id, bytes calldata route, uint256 seedMinOut, uint256 gasAdd) external payable lock whenNotPaused returns (uint256 baseOut) {
        Grid storage G = _live(id, route);
        if (msg.sender != G.maker) revert NotMaker();
        if (gasAdd > msg.value) revert BadValue();
        uint256 capital = msg.value - gasAdd;
        if (capital == 0 && gasAdd == 0) revert BadValue();
        _wrap(msg.value);
        if (gasAdd != 0) {
            if (uint256(G.gasReserve) + gasAdd > type(uint128).max) revert BadValue();
            G.gasReserve += uint128(gasAdd);
            gasEscrowed  += gasAdd;
            emit GasAdded(id, msg.sender, gasAdd);
        }
        if (capital != 0) {
            uint256 n = G.nLevels;
            uint256 add = capital / n;
            if (add == 0 || capital > type(uint128).max) revert BadValue();
            if ((uint256(G.perLevel) + add) * n > type(uint128).max || uint256(G.quoteHeld) + capital > type(uint128).max) revert BadValue();
            Level[] storage L = _levels[id];
            uint256 nBase;
            for (uint256 i = 0; i < n; i++) if (L[i].state == BASE) nBase++;
            uint256 seedQuote = add * nBase;
            G.perLevel += uint128(add);
            G.quoteHeld += uint128(capital - seedQuote);
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
            emit ToppedUp(id, msg.sender, capital, baseOut);
        }
    }

    /// @notice v4: el maker prende o apaga la reinversion a mitad de corrida. Lo ya acumulado en profitFree queda como esta.
    function setCompound(bytes32 id, bool compound) external lock {
        Grid storage G = _grids[id];
        if (msg.sender != G.maker) revert NotMaker();
        if (G.status != Status.Open) revert NotOpen();
        G.compound = compound;
        emit CompoundSet(id, compound);
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

    // ------------------------------ admin (v4) ------------------------------

    /// @notice Calibra el gas que gasleft() no ve. Acotado para que el owner no pueda hacer sobrepagar de mas al keeper.
    function setGasOverhead(uint256 v) external onlyOwner {
        if (v > MAX_GAS_OVERHEAD) revert BadParams();
        gasOverhead = v;
        emit GasOverheadSet(v);
    }

    // ------------------------------ vistas ------------------------------

    function grid(bytes32 id) external view returns (Grid memory) { return _grids[id]; }
    function levels(bytes32 id) external view returns (Level[] memory) { return _levels[id]; }
    function isOpen(bytes32 id) external view returns (bool) {
        Grid storage G = _grids[id];
        return G.maker != address(0) && G.status == Status.Open;
    }
    /// @notice quote que gastara el proximo fillBuy (perLevel + boost si compound). Lo que el front tiene que mostrar.
    function nextBuyQuote(bytes32 id) public view returns (uint256 q) {
        Grid storage G = _grids[id];
        q = G.perLevel;
        if (G.compound && G.profitFree != 0) q += uint256(G.profitFree) / G.nLevels;
    }
    /// @notice minOut que fillBuy exigira para el nivel i (0 si no esta armado para comprar). v4: incluye el boost.
    function buyMinOut(bytes32 id, uint256 i) external view returns (uint256) {
        Grid storage G = _grids[id]; Level storage L = _levels[id][i];
        if (G.status != Status.Open || L.state != QUOTE) return 0;
        return (nextBuyQuote(id) * Q + L.buyPrice - 1) / L.buyPrice;
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

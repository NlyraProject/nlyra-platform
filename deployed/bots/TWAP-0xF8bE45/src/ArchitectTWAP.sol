// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*  ArchitectTWAP v1 - una orden grande partida en el tiempo, para The Desk
    ---------------------------------------------------------------------------
    Una orden (buy: WETH -> token, sell: token -> WETH) partida en `slices`
    tajadas iguales, una cada `intervalS` segundos (minimo 60 s). Los fondos
    viven ACA (escrow); el keeper ejecuta cada tajada cuando vence su plazo; el
    output va DIRECTO al maker; stop() (maker) o refundExpired() (cualquiera,
    post expiry) devuelven lo no ejecutado.

    Mismo esqueleto que ArchitectLadder: escrow, keeper allowlisteado, routeHash
    fijado por el maker, router v2 (swapWithFee / swapETH / swapToETH), rescue
    solo del exceso, ownership en 2 pasos, pause, lock TSTORE.

    Garantias (sin oracle):
      - El keeper solo TIMEA: no antes de nextAt, nunca en rafaga (nextAt se
        re-arma desde block.timestamp), nunca mas que `slices` veces ni por mas
        que el monto de la tajada.
      - Precio limite en TODAS las tajadas: minOut >= sliceIn x limitQ / 1e18,
        con limitQ (output por unidad de input, escala 1e18) fijado por el
        maker. El keeper puede exigir MAS (su cotizacion menos slippage), nunca
        menos. El router hace cumplir el minOut.
      - Pools V4 nativos (currency0 = 0): swapETH / swapToETH con referrer 0.
*/

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
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

contract ArchitectTWAP {
    uint8   internal constant ROUTE_V4 = 2;
    uint256 internal constant Q = 1e18;             // escala de limitQ (output por unidad de input x 1e18)
    uint16  public   constant MAX_SLICES = 200;
    uint32  public   constant MIN_INTERVAL_S = 60;

    /// @notice Parametros de la orden, fijados por el maker en open().
    /// @param total     monto total de tokenIn (wei si es WETH)
    /// @param slices    cantidad de tajadas (1..200); cada una es total / slices (la ultima lleva el resto)
    /// @param intervalS segundos entre tajadas (>= 60)
    /// @param limitQ    peor output aceptable por unidad de input, escala 1e18 (precio limite, neto del fee)
    struct Params {
        uint128 total;
        uint16  slices;
        uint32  intervalS;
        uint256 limitQ;
    }

    enum Status { Open, Done, Cancelled }

    struct Order {
        address maker;
        address tokenIn;
        address tokenOut;
        address referrer;
        bytes32 routeHash;      // keccak256(route): el keeper no elige el pool
        Params  p;
        uint128 remaining;      // tokenIn todavia escrowado
        uint128 spent;          // tokenIn ejecutado
        uint128 received;       // tokenOut entregado al maker (informativo: precio promedio on-chain)
        uint64  nextAt;         // proxima tajada permitida (unix)
        uint64  expiry;
        uint16  feeBps;
        uint16  done;           // tajadas ejecutadas
        Status  status;
    }

    IArchitectRouter public immutable ROUTER;
    address          public immutable WETH;

    address public owner;
    address public pendingOwner;
    bool    public paused;
    uint256 public count;
    mapping(address => bool)    public isKeeper;
    mapping(bytes32 => Order)   internal _orders;
    mapping(address => uint256) public escrowed;      // token => total escrowado (fondos de usuarios)
    mapping(address => uint256) public pendingEth;    // pagos en ETH que rebotaron

    event TwapOpened(bytes32 indexed id, address indexed maker, address tokenIn, address tokenOut, Params p, uint64 expiry, uint16 feeBps, address referrer, bytes32 routeHash);
    /// @dev maker es topic 2 (la tape atribuye la tajada al maker, via 'twap').
    event TwapSliced(bytes32 indexed id, address indexed maker, address indexed keeper, uint16 i, uint256 amountIn, uint256 amountOut, uint16 feeBps);
    /// @param kind 0 = stop (maker), 1 = refundExpired, 2 = completa (ultima tajada)
    event TwapStopped(bytes32 indexed id, address indexed maker, uint8 kind, uint256 refunded);
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
    error BadOrder();
    error BadFee();
    error BadRouteHash();
    error BadValue();
    error MinOutTooLow(uint256 got, uint256 want);
    error InsufficientOutput(uint256 got, uint256 want);
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
        if (IArchitectRouter(router).WETH() != weth) revert BadOrder();
        ROUTER = IArchitectRouter(router);
        WETH   = weth;
        owner  = msg.sender;
        if (keeper != address(0)) { isKeeper[keeper] = true; emit KeeperSet(keeper, true); }
    }

    /// ETH entra solo desde el router (swapToETH) o desde WETH (withdraw).
    receive() external payable {
        if (msg.sender != address(ROUTER) && msg.sender != WETH) revert BadOrder();
    }

    // ------------------------------ abrir ------------------------------

    /// @notice Abre la orden y deposita p.total de tokenIn.
    /// @dev Buy (tokenIn == WETH): msg.value == p.total, se envuelve adentro. Sell (tokenOut == WETH):
    ///      msg.value == 0 y el maker aprobo ESTE contrato por p.total (sin Permit2).
    ///      La primera tajada puede ejecutarse de inmediato (nextAt = ahora).
    /// @param route calldata opaco del router: abi.encode(uint8 kind, bytes payload). Se guarda solo su hash.
    function open(address tokenIn, address tokenOut, bytes calldata route, uint64 expiry, uint16 feeBps, address referrer, Params calldata p)
        external payable lock whenNotPaused returns (bytes32 id)
    {
        if (tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut) revert BadOrder();
        if (tokenIn != WETH && tokenOut != WETH) revert BadOrder();
        if (expiry <= block.timestamp) revert Expired();
        if (feeBps < ROUTER.minFeeBps() || feeBps > ROUTER.maxFeeBps()) revert BadFee();
        if (p.total == 0 || p.slices == 0 || p.slices > MAX_SLICES || p.intervalS < MIN_INTERVAL_S || p.limitQ == 0) revert BadParams();
        if (uint256(p.total) / p.slices == 0) revert BadParams();
        if (referrer == msg.sender) referrer = address(0);

        uint256 total = p.total;
        if (msg.value != 0) {
            if (tokenIn != WETH || msg.value != total) revert BadValue();
            IWETH(WETH).deposit{value: total}();
        } else {
            // escrow medido por delta de balance: un token fee-on-transfer que entregue menos revierte
            uint256 before = IERC20(tokenIn).balanceOf(address(this));
            _pull(tokenIn, msg.sender, total);
            if (IERC20(tokenIn).balanceOf(address(this)) - before < total) revert TransferFailed();
        }
        escrowed[tokenIn] += total;

        id = keccak256(abi.encode(block.chainid, address(this), ++count, msg.sender));
        Order storage O = _orders[id];
        O.maker = msg.sender;
        O.tokenIn = tokenIn;
        O.tokenOut = tokenOut;
        O.referrer = referrer;
        O.routeHash = keccak256(route);
        O.p = p;
        O.remaining = uint128(total);
        O.nextAt = uint64(block.timestamp);
        O.expiry = expiry;
        O.feeBps = feeBps;
        emit TwapOpened(id, msg.sender, tokenIn, tokenOut, p, expiry, feeBps, referrer, O.routeHash);
    }

    // ------------------------------ keeper ------------------------------

    /// @notice Ejecuta la proxima tajada. Solo keepers, solo si vencio nextAt. El output va al maker.
    /// @dev minOut >= sliceIn x limitQ / 1e18 (ver sliceMinOut). La ultima tajada lleva el resto y cierra la orden.
    function slice(bytes32 id, bytes calldata route, uint256 minOut)
        external lock whenNotPaused returns (uint256 amountOut)
    {
        if (!isKeeper[msg.sender]) revert NotKeeper();
        Order storage O = _orders[id];
        if (O.maker == address(0)) revert BadOrder();
        if (O.status != Status.Open) revert NotOpen();
        if (block.timestamp > O.expiry) revert Expired();
        if (keccak256(route) != O.routeHash) revert BadRouteHash();
        if (block.timestamp < O.nextAt) revert NotDue(O.nextAt);
        uint16 i = O.done;
        uint256 amountIn = _sliceIn(O, i);
        if (amountIn == 0) revert NothingToRefund();
        uint256 floor = (amountIn * O.p.limitQ) / Q;
        if (minOut < floor) revert MinOutTooLow(minOut, floor);

        // CEI: contabilidad antes del swap
        O.done = i + 1;
        O.remaining -= uint128(amountIn);
        O.spent += uint128(amountIn);
        O.nextAt = uint64(block.timestamp + O.p.intervalS);
        escrowed[O.tokenIn] -= amountIn;
        bool last = O.done == O.p.slices || O.remaining == 0;
        if (last) O.status = Status.Done;

        amountOut = _swap(O, amountIn, minOut, route);
        if (amountOut > type(uint128).max) revert BadValue();
        O.received += uint128(amountOut);
        emit TwapSliced(id, O.maker, msg.sender, i, amountIn, amountOut, O.feeBps);

        if (last) {
            uint256 rem = O.remaining;   // 0 salvo redondeo; nunca queda nada escrowado
            O.remaining = 0;
            if (rem != 0) { escrowed[O.tokenIn] -= rem; _refund(O, rem); }
            emit TwapStopped(id, O.maker, 2, rem);
        }
    }

    // ------------------------------ maker / expiry ------------------------------

    /// @notice El maker para la orden y recupera lo no ejecutado (ETH nativo si tokenIn == WETH). Funciona pausado.
    function stop(bytes32 id) external lock {
        Order storage O = _orders[id];
        if (msg.sender != O.maker) revert NotMaker();
        _close(id, O, 0);
    }

    /// @notice Pasado el expiry, cualquiera puede devolverle el remanente al maker.
    function refundExpired(bytes32 id) external lock {
        Order storage O = _orders[id];
        if (O.maker == address(0)) revert BadOrder();
        if (block.timestamp <= O.expiry) revert NotExpired();
        _close(id, O, 1);
    }

    function _close(bytes32 id, Order storage O, uint8 kind) internal {
        if (O.status != Status.Open) revert NotOpen();
        uint256 rem = O.remaining;
        if (rem == 0) revert NothingToRefund();
        O.remaining = 0;
        O.status = Status.Cancelled;
        escrowed[O.tokenIn] -= rem;
        _refund(O, rem);
        emit TwapStopped(id, O.maker, kind, rem);
    }

    function _refund(Order storage O, uint256 amount) internal {
        if (O.tokenIn == WETH) { IWETH(WETH).withdraw(amount); _payEth(O.maker, amount); }
        else _send(O.tokenIn, O.maker, amount);
    }

    // ------------------------------ swap ------------------------------

    function _swap(Order storage O, uint256 amountIn, uint256 minOut, bytes calldata route) internal returns (uint256 amountOut) {
        address tokenIn = O.tokenIn; address tokenOut = O.tokenOut; address maker = O.maker;
        bool native = _routeIsNativeV4(route);
        if (native && tokenIn == WETH) {
            // BUY en pool V4 nativo: ETH viaja tal cual, el token llega aca y se reenvia
            IWETH(WETH).withdraw(amountIn);
            uint256 before = IERC20(tokenOut).balanceOf(address(this));
            ROUTER.swapETH{value: amountIn}(tokenOut, minOut, O.feeBps, address(0), block.timestamp, route);
            amountOut = IERC20(tokenOut).balanceOf(address(this)) - before;
            if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
            _send(tokenOut, maker, amountOut);
        } else if (native && tokenOut == WETH) {
            // SELL en pool V4 nativo: el maker recibe ETH nativo
            _approve(tokenIn, address(ROUTER), amountIn);
            uint256 before = address(this).balance;
            ROUTER.swapToETH(tokenIn, amountIn, minOut, O.feeBps, address(0), block.timestamp, route);
            amountOut = address(this).balance - before;
            if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
            _payEth(maker, amountOut);
        } else {
            _approve(tokenIn, address(ROUTER), amountIn);
            uint256 before = IERC20(tokenOut).balanceOf(maker);
            ROUTER.swapWithFee(tokenIn, tokenOut, amountIn, minOut, maker, O.feeBps, O.referrer, block.timestamp, route);
            amountOut = IERC20(tokenOut).balanceOf(maker) - before;
            if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
        }
    }

    // ------------------------------ vistas ------------------------------

    function order(bytes32 id) external view returns (Order memory) { return _orders[id]; }

    /// @notice Monto de la tajada i (la ultima lleva el resto).
    function _sliceIn(Order storage O, uint16 i) internal view returns (uint256) {
        if (i >= O.p.slices) return 0;
        uint256 per = uint256(O.p.total) / O.p.slices;
        uint256 rem = O.remaining;
        if (i + 1 == O.p.slices || per > rem) return rem;
        return per;
    }

    /// @notice Monto de la proxima tajada (0 si la orden no esta abierta).
    function nextSliceIn(bytes32 id) external view returns (uint256) {
        Order storage O = _orders[id];
        if (O.status != Status.Open) return 0;
        return _sliceIn(O, O.done);
    }

    /// @notice Piso de minOut que slice() exige para la proxima tajada (0 si no corresponde).
    function sliceMinOut(bytes32 id) external view returns (uint256) {
        Order storage O = _orders[id];
        if (O.status != Status.Open) return 0;
        return (_sliceIn(O, O.done) * O.p.limitQ) / Q;
    }

    function isOpen(bytes32 id) external view returns (bool) {
        Order storage O = _orders[id];
        return O.maker != address(0) && O.status == Status.Open;
    }

    // ------------------------------ transferencias ------------------------------

    function _pull(address token, address from, uint256 amount) internal {
        (bool ok, bytes memory d) = token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, address(this), amount));
        if (!ok || (d.length != 0 && !abi.decode(d, (bool)))) revert TransferFailed();
    }
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

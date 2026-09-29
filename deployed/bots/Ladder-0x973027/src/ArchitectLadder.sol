// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*  ArchitectLadder v1 - ordenes "ladder" (escalera) para The Desk
    ---------------------------------------------------------------------------
    Un deposito, N ordenes limit (rungs) repartidas en un rango de precio, al
    estilo "spread" de Meteora DLMM. A diferencia de ArchitectLimitOrders (que
    no custodia: Permit2 + witness), aca los fondos viven EN ESTE CONTRATO
    porque una sola firma no puede autorizar N transferencias parciales.

    Garantias:
      - El keeper solo puede ejecutar rungs con el minOut que fijo el maker y
        por la ruta que fijo el maker (routeHash). No puede elegir pool ni
        rellenar peor. El output va directo al maker, nunca queda aca.
      - El maker cancela cuando quiere y recupera el remanente; cualquiera puede
        devolverle el remanente despues del expiry.
      - Ningun camino del owner toca fondos escrowados: rescue() solo saca lo
        que excede el total escrowado por token.
      - Fees: misma ruta y mismo router que las ordenes limit (swapWithFee con
        feeBps >= router.minFeeBps), asi que el 1% / 30% referrer se acumula
        exactamente igual. En pools V4 nativos (currency0 = 0) el router no
        acepta WETH por swapWithFee: se usa swapETH / swapToETH con
        referrer = 0, igual que ArchitectLimitOrders.
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

contract ArchitectLadder {
    uint8   internal constant ROUTE_V4 = 2;
    uint256 public   constant MAX_RUNGS = 60;

    /// @notice Un escalon: cuanto entra y el piso de salida (precio limite, neto de fee).
    struct Rung { uint128 amountIn; uint128 minOut; }

    struct Ladder {
        address maker;
        address tokenIn;
        address tokenOut;
        address referrer;
        bytes32 routeHash;     // keccak256(route): el keeper no elige el pool
        uint128 remaining;     // tokenIn todavia escrowado para esta ladder
        uint64  expiry;
        uint64  filledMask;    // bit i = rung i ejecutado
        uint16  feeBps;
        uint16  nRungs;
        bool    cancelled;     // cancelada o devuelta (expiry)
    }

    IArchitectRouter public immutable ROUTER;
    address          public immutable WETH;

    address public owner;
    address public pendingOwner;
    bool    public paused;
    uint256 public count;                               // ids emitidos
    mapping(address => bool)    public isKeeper;
    mapping(bytes32 => Ladder)  internal _ladders;
    mapping(bytes32 => Rung[])  internal _rungs;
    mapping(address => uint256) public escrowed;        // token => total escrowado (fondos de usuarios)
    mapping(address => uint256) public pendingEth;      // pagos en ETH que rebotaron

    event LadderCreated(
        bytes32 indexed id, address indexed maker, address tokenIn, address tokenOut,
        uint256 total, uint16 nRungs, uint64 expiry, uint16 feeBps, address referrer, bytes32 routeHash
    );
    /// @dev maker es topic 2, igual que OrderFilled de ArchitectLimitOrders (la tape atribuye el fill al maker).
    event RungFilled(bytes32 indexed id, address indexed maker, address indexed keeper, uint256 i, uint256 amountIn, uint256 amountOut, uint16 feeBps);
    event LadderCancelled(bytes32 indexed id, address indexed maker, uint256 refunded, bool expired);
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
    error Cancelled();
    error AlreadyFilled();
    error BadRung();
    error BadLadder();
    error BadFee();
    error BadRouteHash();
    error BadValue();
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
        if (IArchitectRouter(router).WETH() != weth) revert BadLadder();
        ROUTER = IArchitectRouter(router);
        WETH   = weth;
        owner  = msg.sender;
        if (keeper != address(0)) { isKeeper[keeper] = true; emit KeeperSet(keeper, true); }
    }

    /// ETH entra solo desde el router (swapToETH) o desde WETH (withdraw).
    receive() external payable {
        if (msg.sender != address(ROUTER) && msg.sender != WETH) revert BadLadder();
    }

    // ------------------------------ crear ------------------------------

    /// @notice Deposita la suma de amountIn de todos los rungs y abre la ladder.
    /// @dev tokenIn == WETH y msg.value > 0: se envuelve el ETH (msg.value == total).
    ///      Si no, transferFrom(maker) por el total: el maker aprueba ESTE contrato.
    /// @param route  calldata opaco del router: abi.encode(uint8 kind, bytes payload). Se guarda solo su hash.
    function createLadder(
        address tokenIn, address tokenOut, bytes calldata route, uint64 expiry,
        uint16 feeBps, address referrer, Rung[] calldata rungs
    ) external payable lock whenNotPaused returns (bytes32 id) {
        uint256 n = rungs.length;
        if (n == 0 || n > MAX_RUNGS) revert BadRung();
        if (tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut) revert BadLadder();
        if (expiry <= block.timestamp) revert Expired();
        if (feeBps < ROUTER.minFeeBps() || feeBps > ROUTER.maxFeeBps()) revert BadFee();
        if (referrer == msg.sender) referrer = address(0);

        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            if (rungs[i].amountIn == 0 || rungs[i].minOut == 0) revert BadRung();
            total += rungs[i].amountIn;
        }
        if (total > type(uint128).max) revert BadRung();

        // fondeo. El escrow se mide por balance delta: un token fee-on-transfer
        // que entregue menos de lo declarado revierte en vez de dejar una ladder corta.
        if (msg.value != 0) {
            if (tokenIn != WETH || msg.value != total) revert BadValue();
            IWETH(WETH).deposit{value: total}();
        } else {
            uint256 before = IERC20(tokenIn).balanceOf(address(this));
            _pull(tokenIn, msg.sender, total);
            if (IERC20(tokenIn).balanceOf(address(this)) - before < total) revert TransferFailed();
        }
        escrowed[tokenIn] += total;

        id = keccak256(abi.encode(block.chainid, address(this), ++count, msg.sender));
        Ladder storage L = _ladders[id];
        L.maker = msg.sender;
        L.tokenIn = tokenIn;
        L.tokenOut = tokenOut;
        L.referrer = referrer;
        L.routeHash = keccak256(route);
        L.remaining = uint128(total);
        L.expiry = expiry;
        L.feeBps = feeBps;
        L.nRungs = uint16(n);
        Rung[] storage R = _rungs[id];
        for (uint256 i = 0; i < n; i++) R.push(rungs[i]);

        emit LadderCreated(id, msg.sender, tokenIn, tokenOut, total, uint16(n), expiry, feeBps, referrer, L.routeHash);
    }

    // ------------------------------ ejecutar ------------------------------

    /// @notice Ejecuta el rung i por la ruta fijada por el maker. Solo keepers.
    /// @dev CEI: el rung se marca y el remanente se descuenta ANTES del swap.
    ///      El router aplica minOut (fijado por el maker): el keeper no puede rellenar peor.
    function fillRung(bytes32 id, uint256 i, bytes calldata route)
        external lock whenNotPaused returns (uint256 amountOut)
    {
        if (!isKeeper[msg.sender]) revert NotKeeper();
        Ladder storage L = _ladders[id];
        if (L.maker == address(0)) revert BadLadder();
        if (L.cancelled) revert Cancelled();
        if (block.timestamp > L.expiry) revert Expired();
        if (i >= L.nRungs) revert BadRung();
        uint64 bit = uint64(1) << uint64(i);
        if (L.filledMask & bit != 0) revert AlreadyFilled();
        if (keccak256(route) != L.routeHash) revert BadRouteHash();

        Rung memory r = _rungs[id][i];
        L.filledMask |= bit;
        L.remaining -= r.amountIn;
        escrowed[L.tokenIn] -= r.amountIn;

        amountOut = _swap(L, r, route);
        emit RungFilled(id, L.maker, msg.sender, i, r.amountIn, amountOut, L.feeBps);
    }

    function _swap(Ladder storage L, Rung memory r, bytes calldata route) internal returns (uint256 amountOut) {
        address tokenIn = L.tokenIn; address tokenOut = L.tokenOut; address maker = L.maker;
        uint256 amountIn = r.amountIn; uint256 minOut = r.minOut;
        bool native = _routeIsNativeV4(route);
        if (native && tokenIn == WETH) {
            // BUY en pool V4 nativo: ETH viaja tal cual, el token llega aca y se reenvia
            IWETH(WETH).withdraw(amountIn);
            uint256 before = IERC20(tokenOut).balanceOf(address(this));
            ROUTER.swapETH{value: amountIn}(tokenOut, minOut, L.feeBps, address(0), L.expiry, route);
            amountOut = IERC20(tokenOut).balanceOf(address(this)) - before;
            if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
            _send(tokenOut, maker, amountOut);
        } else if (native && tokenOut == WETH) {
            // SELL en pool V4 nativo: el maker recibe ETH nativo
            _approve(tokenIn, address(ROUTER), amountIn);
            uint256 before = address(this).balance;
            ROUTER.swapToETH(tokenIn, amountIn, minOut, L.feeBps, address(0), L.expiry, route);
            amountOut = address(this).balance - before;
            if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
            _payEth(maker, amountOut);
        } else {
            _approve(tokenIn, address(ROUTER), amountIn);
            amountOut = ROUTER.swapWithFee(tokenIn, tokenOut, amountIn, minOut, maker, L.feeBps, L.referrer, L.expiry, route);
            if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
        }
    }

    // ------------------------------ cancelar / devolver ------------------------------

    /// @notice El maker cierra la ladder y recupera el remanente (ETH nativo si tokenIn == WETH).
    function cancel(bytes32 id) external lock {
        Ladder storage L = _ladders[id];
        if (msg.sender != L.maker) revert NotMaker();
        _close(id, L, false);
    }

    /// @notice Pasado el expiry, cualquiera puede devolverle el remanente al maker.
    function refundExpired(bytes32 id) external lock {
        Ladder storage L = _ladders[id];
        if (L.maker == address(0)) revert BadLadder();
        if (block.timestamp <= L.expiry) revert NotExpired();
        _close(id, L, true);
    }

    function _close(bytes32 id, Ladder storage L, bool expired) internal {
        if (L.cancelled) revert Cancelled();
        uint256 amount = L.remaining;
        if (amount == 0) revert NothingToRefund();
        L.cancelled = true;
        L.remaining = 0;
        escrowed[L.tokenIn] -= amount;
        if (L.tokenIn == WETH) {
            // se fondeo con ETH: vuelve como ETH
            IWETH(WETH).withdraw(amount);
            _payEth(L.maker, amount);
        } else {
            _send(L.tokenIn, L.maker, amount);
        }
        emit LadderCancelled(id, L.maker, amount, expired);
    }

    // ------------------------------ vistas ------------------------------

    function ladder(bytes32 id) external view returns (Ladder memory L, Rung[] memory rungs) {
        L = _ladders[id];
        rungs = _rungs[id];
    }
    function remaining(bytes32 id) external view returns (uint256) { return _ladders[id].remaining; }
    function isFilled(bytes32 id, uint256 i) external view returns (bool) {
        return _ladders[id].filledMask & (uint64(1) << uint64(i)) != 0;
    }
    /// @notice open = existe, no cancelada, no vencida y con remanente.
    function isOpen(bytes32 id) external view returns (bool) {
        Ladder storage L = _ladders[id];
        return L.maker != address(0) && !L.cancelled && block.timestamp <= L.expiry && L.remaining != 0;
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
    /// bloquea ni el fill ni el cancel; el ETH queda reclamable con withdrawEth().
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

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*  ArchitectLimitOrders v2 - ejecutor de ordenes LIMIT para The Desk
    ---------------------------------------------------------------------------
    Modelo: el usuario firma UNA sola firma EIP-712 que ES la firma de Permit2
    (permitWitnessTransferFrom) y que lleva la orden adjunta como "witness".
      - No hay custodia: los fondos salen de la wallet del maker recien en el
        momento de la ejecucion, y el output va al maker.
      - El keeper no puede robar: minAmountOut (= precio limite), feeBps,
        expiry Y AHORA LA RUTA estan firmados por el usuario y se verifican
        on-chain.
      - Permit2 quema el nonce -> sin replay. Cancelar = cancel() aca (barato)
        o permit2.invalidateUnorderedNonces(wordPos, mask) desde el maker.

    IMPORTANTE (bug #1 de integracion con Permit2): el campo `spender` del
    typed-data NO esta en el struct de Solidity; Permit2 lo inyecta desde
    msg.sender. Como quien llama a permitWitnessTransferFrom es ESTE contrato,
    el frontend debe firmar spender = address(ArchitectLimitOrders).

    CAMBIOS DE SEGURIDAD v2 (security review 2026-08):
      1. routeHash firmado. Antes el keeper elegia la `route` libremente: podia
         mandar la orden por un pool basura suyo y quedarse con la diferencia
         hasta el limite de minAmountOut. Ahora la ruta esta en el witness.
      2. deadline propagado al router v2 (el router ya no acepta calldata vieja).
      3. Pago en ETH con gas cap 30k + pendingEth/withdrawEth: un maker
         contrato con receive() caro ya no puede tumbar el fill.
      4. Ownership en 2 pasos + pausa de emergencia.

    Rutas y entrega:
      - BUY  (tokenIn == WETH): el maker firma sobre WETH (Permit2 solo mueve
        ERC20: la UI debe envolver ETH antes). Pools V2/V3 -> router.swapWithFee,
        output directo al maker. Pools V4 con ETH nativo (currency0 = 0) ->
        se desenvuelve el WETH y se usa router.swapETH; el token llega aca y se
        reenvia al maker (medido por balance delta).
      - SELL (tokenOut == WETH): pools V2/V3 -> swapWithFee, el maker recibe
        WETH. Pools V4 nativos -> router.swapToETH, el maker recibe ETH nativo.
      En los caminos nativos (swapETH/swapToETH) el router atribuye el referral
      a msg.sender (= este contrato), asi que se pasa referrer = 0: el fee se
      cobra igual (va entero al treasury) pero el referidor no se acredita.
*/

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IWETH {
    function withdraw(uint256) external;
}

interface ISignatureTransfer {
    struct TokenPermissions { address token; uint256 amount; }
    struct PermitTransferFrom { TokenPermissions permitted; uint256 nonce; uint256 deadline; }
    struct SignatureTransferDetails { address to; uint256 requestedAmount; }

    function permitWitnessTransferFrom(
        PermitTransferFrom memory permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external;

    function nonceBitmap(address owner, uint256 wordPos) external view returns (uint256);
}

interface IArchitectRouter {
    function WETH() external view returns (address);
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

contract ArchitectLimitOrders {
    uint8 internal constant ROUTE_V4 = 2;

    struct Order {
        address maker;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;   // precio limite: piso duro de salida (ya neto de fee)
        uint256 expiry;         // = deadline de Permit2
        uint16  feeBps;         // comision de plataforma, FIRMADA por el usuario
        address referrer;
        uint256 nonce;          // nonce de Permit2 (unordered, 256 bits)
        bytes32 routeHash;      // keccak256(route): el keeper no elige el pool
    }

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(address maker,address tokenIn,address tokenOut,uint256 amountIn,uint256 minAmountOut,uint256 expiry,uint16 feeBps,address referrer,uint256 nonce,bytes32 routeHash)"
    );

    // Structs referenciados en ORDEN ALFABETICO: "Order" < "TokenPermissions".
    // Si se invierte, la firma no valida. Testealo con
    // ethers.TypedDataEncoder.from(types).encodeType("PermitWitnessTransferFrom")
    string public constant WITNESS_TYPE_STRING =
        "Order witness)"
        "Order(address maker,address tokenIn,address tokenOut,uint256 amountIn,uint256 minAmountOut,uint256 expiry,uint16 feeBps,address referrer,uint256 nonce,bytes32 routeHash)"
        "TokenPermissions(address token,uint256 amount)";

    ISignatureTransfer public immutable PERMIT2;
    IArchitectRouter   public immutable ROUTER;
    address            public immutable WETH;

    address public owner;
    address public pendingOwner;
    bool    public paused;
    uint16  public maxFeeBps = 200; // techo duro 2%
    mapping(address => bool) public isKeeper;
    mapping(bytes32 => bool) public cancelled;
    mapping(address => uint256) public pendingEth;

    event OrderFilled(
        bytes32 indexed orderHash, address indexed maker, address indexed keeper,
        uint256 amountIn, uint256 amountOut, uint16 feeBps
    );
    event OrderCancelled(bytes32 indexed orderHash, address indexed maker);
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
    error AlreadyCancelled();
    error FeeTooHigh();
    error InsufficientOutput(uint256 got, uint256 want);
    error BadOrder();
    error BadRouteHash();
    error TransferFailed();
    error IsPaused();
    error ZeroAddress();

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }
    modifier whenNotPaused() { if (paused) revert IsPaused(); _; }

    modifier lock() {
        // reentrancy guard transitorio (TSTORE disponible: evmVersion cancun)
        assembly ("memory-safe") { if tload(0) { mstore(0, 0) revert(0, 0) } tstore(0, 1) }
        _;
        assembly ("memory-safe") { tstore(0, 0) }
    }

    constructor(address permit2, address router) {
        if (permit2 == address(0) || router == address(0)) revert ZeroAddress();
        PERMIT2 = ISignatureTransfer(permit2);
        ROUTER  = IArchitectRouter(router);
        WETH    = IArchitectRouter(router).WETH();
        owner   = msg.sender;
        isKeeper[msg.sender] = true;
        emit KeeperSet(msg.sender, true);
    }

    /// ETH entra solo desde el router (swapToETH) o desde WETH (withdraw).
    receive() external payable {
        if (msg.sender != address(ROUTER) && msg.sender != WETH) revert BadOrder();
    }

    function hashOrder(Order calldata o) public pure returns (bytes32) {
        return keccak256(abi.encode(
            ORDER_TYPEHASH, o.maker, o.tokenIn, o.tokenOut, o.amountIn, o.minAmountOut,
            o.expiry, o.feeBps, o.referrer, o.nonce, o.routeHash
        ));
    }

    /// @param signature firma Permit2 (PermitWitnessTransferFrom) hecha por el maker
    /// @param route     calldata opaco para el router: abi.encode(uint8 kind, bytes payload).
    ///                  DEBE hashear a o.routeHash — el keeper no puede cambiar de pool.
    function execute(
        Order calldata o,
        bytes calldata signature,
        bytes calldata route
    ) external lock whenNotPaused returns (uint256 amountOut) {
        if (!isKeeper[msg.sender]) revert NotKeeper();
        if (block.timestamp > o.expiry) revert Expired();
        if (o.feeBps > maxFeeBps) revert FeeTooHigh();
        if (o.amountIn == 0 || o.minAmountOut == 0) revert BadOrder();
        if (o.tokenIn == o.tokenOut || o.maker == address(0)) revert BadOrder();
        // la ruta es parte de lo firmado: sin esto el keeper elige el pool y se
        // queda con todo lo que sobre por encima de minAmountOut
        if (keccak256(route) != o.routeHash) revert BadRouteHash();

        bytes32 orderHash = hashOrder(o);
        if (cancelled[orderHash]) revert AlreadyCancelled();

        // 1) tirar de los fondos del maker con SU firma. Permit2 valida firma, deadline
        //    y quema el nonce -> replay imposible sin storage propio.
        PERMIT2.permitWitnessTransferFrom(
            ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({token: o.tokenIn, amount: o.amountIn}),
                nonce: o.nonce,
                deadline: o.expiry
            }),
            ISignatureTransfer.SignatureTransferDetails({to: address(this), requestedAmount: o.amountIn}),
            o.maker,
            orderHash, // el witness es el hash de la orden
            WITNESS_TYPE_STRING,
            signature
        );

        // 2) swap. El router cobra la comision firmada; el output va al maker.
        bool native = _routeIsNativeV4(route);
        if (native && o.tokenIn == WETH) {
            // BUY en pool V4 nativo: ETH viaja tal cual, el token llega aca y se reenvia
            IWETH(WETH).withdraw(o.amountIn);
            uint256 before = IERC20(o.tokenOut).balanceOf(address(this));
            ROUTER.swapETH{value: o.amountIn}(o.tokenOut, o.minAmountOut, o.feeBps, address(0), o.expiry, route);
            amountOut = IERC20(o.tokenOut).balanceOf(address(this)) - before;
            if (amountOut < o.minAmountOut) revert InsufficientOutput(amountOut, o.minAmountOut);
            _send(o.tokenOut, o.maker, amountOut);
        } else if (native && o.tokenOut == WETH) {
            // SELL en pool V4 nativo: el maker recibe ETH nativo
            _approve(o.tokenIn, address(ROUTER), o.amountIn);
            uint256 before = address(this).balance;
            ROUTER.swapToETH(o.tokenIn, o.amountIn, o.minAmountOut, o.feeBps, address(0), o.expiry, route);
            amountOut = address(this).balance - before;
            if (amountOut < o.minAmountOut) revert InsufficientOutput(amountOut, o.minAmountOut);
            _payEth(o.maker, amountOut);
        } else {
            _approve(o.tokenIn, address(ROUTER), o.amountIn);
            amountOut = ROUTER.swapWithFee(
                o.tokenIn, o.tokenOut, o.amountIn, o.minAmountOut,
                o.maker, o.feeBps, o.referrer, o.expiry, route
            );
            // defensa en profundidad: aunque el router mienta en su return value, esto corta
            if (amountOut < o.minAmountOut) revert InsufficientOutput(amountOut, o.minAmountOut);
        }

        emit OrderFilled(orderHash, o.maker, msg.sender, o.amountIn, amountOut, o.feeBps);
    }

    function _routeIsNativeV4(bytes calldata route) internal pure returns (bool) {
        (uint8 kind, bytes memory payload) = abi.decode(route, (uint8, bytes));
        if (kind != ROUTE_V4) return false;
        (PoolKey memory key,) = abi.decode(payload, (PoolKey, bytes));
        return key.currency0 == address(0);
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

    /// Pago en ETH con techo de gas: un maker contrato con receive() caro o que
    /// revierte no puede bloquear el fill; el ETH queda reclamable.
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

    // ---------------------------- cancelacion ----------------------------

    /// Barata (~30k gas): marca esta orden puntual. El nonce de Permit2 queda
    /// libre para reusar en otra orden.
    function cancel(Order calldata o) external {
        if (msg.sender != o.maker) revert NotMaker();
        bytes32 h = hashOrder(o);
        cancelled[h] = true;
        emit OrderCancelled(h, msg.sender);
    }

    /// Helper para el frontend. La invalidacion "nuclear" la llama el propio
    /// maker contra Permit2: permit2.invalidateUnorderedNonces(wordPos, mask)
    function nonceWord(uint256 nonce) external pure returns (uint256 wordPos, uint256 mask) {
        wordPos = nonce >> 8;
        mask = 1 << (nonce & 0xff);
    }

    function isNonceUsed(address maker, uint256 nonce) external view returns (bool) {
        uint256 bit = 1 << (nonce & 0xff);
        return PERMIT2.nonceBitmap(maker, nonce >> 8) & bit != 0;
    }

    // ------------------------------ admin ------------------------------
    function setKeeper(address k, bool allowed) external onlyOwner {
        isKeeper[k] = allowed;
        emit KeeperSet(k, allowed);
    }
    function setMaxFeeBps(uint16 bps) external onlyOwner {
        require(bps <= 500, "techo 5%");
        maxFeeBps = bps;
    }
    function setPaused(bool v) external onlyOwner { paused = v; emit PausedSet(v); }

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

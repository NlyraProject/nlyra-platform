// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*  ArchitectFeeRouterBSC - el fee router de The Desk en BNB Smart Chain (chain id 56)
    ---------------------------------------------------------------------------
    Port de ArchitectFeeRouter v2 (Robinhood Chain, 0x9d1eA9Ab...3565, security review 2026-08).
    Misma contabilidad de comision, mismo ownership, misma logica de quote tokens, mismo referral,
    mismas propiedades de seguridad. Cambian las rutas (PancakeSwap en vez de Uniswap) y el trato a
    los tokens con tax, que en BSC son moneda corriente.

    REGLA DE ORO (sin cambios): la comision se cobra SIEMPRE en el token "quote" (WBNB u otro token
    de la whitelist: USDT, USDC...), NUNCA en el memecoin.
      - COMPRA (quote -> TOKEN): fee sobre el INPUT, antes del swap. Exacto y barato.
      - VENTA  (TOKEN -> quote): fee sobre el OUTPUT, despues del swap. Exacto.
      - TOKEN -> TOKEN sin quote: fee sobre el output medido por balance delta (solo con allowExoticPairs).
    Todos los montos de tokens no confiables se miden con balanceBefore/balanceAfter.

    RUTAS en BSC (abi.encode(uint8 kind, bytes payload)):
      0  ROUTE_V3        PancakeSwap V3, un pool directo: payload = abi.encode(uint24 fee)  (100/500/2500/10000)
                         Se llama pool.swap() y se paga en pancakeV3SwapCallback (verificado contra la factory).
      1  ROUTE_V2        PancakeSwap V2 por el PancakeRouter: payload = abi.encode(address[] path)
                         (swapExactTokensForTokensSupportingFeeOnTransferTokens: multi-hop y tokens con tax)
      2  (reservado)     era Uniswap V4 en Robinhood. En BSC no existe: revierte BadRoute.
      3  ROUTE_V2_DIRECT PancakeSwap V2 golpeando el pair: payload = abi.encode(address pair, uint256 feeNum)
                         feeNum en diezmilesimas: 9975 = 0,25 % (PancakeSwap V2). Un pair de la factory
                         canonica EXIGE 9975; otros pairs solo via isPairAllowed (feeNum 9000..10000).
      4  ROUTE_V3_PATH   PancakeSwap V3 multi-hop por el SmartRouter: payload = abi.encode(bytes path)
                         (path = tokenIn | fee | mid | fee | tokenOut, como exactInput de la periferia V3)
    Los bots guardan UNA ruta (su hash) y la usan para comprar y para vender: ROUTE_V3 y ROUTE_V2_DIRECT no
    tienen direccion; ROUTE_V2 y ROUTE_V3_PATH se dan vuelta solos si el path viene al reves.

    DIFERENCIAS CON ROBINHOOD (y por que):
      a. Sin PoolManager V4: se fueron unlock/unlockCallback, isHook/setHook y la rama de ETH nativo.
         receive() solo acepta BNB de WBNB.
      b. WETH -> WBNB. La funcion WETH() se mantiene (misma ABI para UI, keeper y bots); WBNB() es alias.
      c. Callback V3: PancakeSwap llama pancakeV3SwapCallback (no uniswapV3SwapCallback). Mismo chequeo:
         msg.sender tiene que ser el pool canonico de la factory para la terna guardada en transient storage.
      d. Fee V2 0,25 %: la formula de ROUTE_V2_DIRECT usa 9975/10000 (Uniswap V2 usa 997/1000).
      e. Fee-on-transfer: lo que ENTRA tambien se mide por delta de balance (_pullIn). Robinhood asumia
         amountIn exacto en swap/swapToETH/swapWithFee; un token con tax entregaba menos y el swap
         revertia (o, peor, consumia polvo del router). Ahora se opera con lo que llego de verdad y el
         fee se calcula sobre eso. Por V3 un token con tax NO se puede vender (el pool exige recibir el
         monto exacto, 'IIA'): es una regla de PancakeSwap, no nuestra; por V2 si.
      f. SIN REFERIDOS (decision del dueno, 24/10/2026): todo el fee va a la tesoreria. Los parametros
         `referrer` siguen en las firmas y el evento Swap conserva el campo (siempre 0) para que el ABI
         sea el de Robinhood, pero se ignoran: no hay referrerOf, referrerShareBps ni tarifa referida,
         y el piso de fee es 1 %.
      g. tokenIn == tokenOut y amountIn == 0 revierten BadRoute (antes dependia del pool).

    CAMBIOS DE SEGURIDAD v2 que se conservan: onlyCaller en swapWithFee, minFeeBps, validacion del pair
    contra la factory, salidas medidas en DESTINO contra minAmountOut, deadline, approve por low-level
    call (0 primero), pagos en BNB con gas cap + pendingEth/withdrawEth, ownership en 2 pasos + pausa.
*/

/// WBNB (0xbb4CdB9CBd36B01bD1cBaEbF2De08d9173bc095c): misma interfaz que WETH9
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}
interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
}

/// PancakeSwap V3 pool: mismo swap() que Uniswap V3; el callback se llama pancakeV3SwapCallback
interface IPancakeV3Pool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

interface IPancakeV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IPancakeV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

interface IPancakeV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function token0() external view returns (address);
}

/// PancakeRouter (V2): clon de UniswapV2Router02
interface IPancakeV2Router {
    function factory() external view returns (address);
    function WETH() external view returns (address);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline
    ) external;
}

/// PancakeSwap SmartRouter (0x13f4EA83D0bd40E75C8222255bc855a974568Dd4): estilo SwapRouter02, sin deadline en el struct
interface IPancakeSmartRouter {
    struct ExactInputParams { bytes path; address recipient; uint256 amountIn; uint256 amountOutMinimum; }
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
    function factory() external view returns (address);
    function WETH9() external view returns (address);
}

library SafeTransfer {
    error TransferFailed();
    function send(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory d) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!ok || (d.length != 0 && !abi.decode(d, (bool)))) revert TransferFailed();
    }
    function pull(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory d) =
            token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
        if (!ok || (d.length != 0 && !abi.decode(d, (bool)))) revert TransferFailed();
    }
    /// USDT (Ethereum) y sus clones NO devuelven bool en approve: hay que llamar en crudo
    /// y aceptar returndata vacia. En BSC el USDT de Binance-Peg si devuelve bool, pero
    /// se conserva por los clones.
    function approveRaw(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory d) = token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
        if (!ok || (d.length != 0 && !abi.decode(d, (bool)))) revert TransferFailed();
    }
}

contract ArchitectFeeRouterBSC {
    using SafeTransfer for address;

    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    uint8 internal constant ROUTE_V3 = 0;
    uint8 internal constant ROUTE_V2 = 1;
    // 2: reservado (Uniswap V4 en Robinhood; no existe en BSC)
    uint8 internal constant ROUTE_V2_DIRECT = 3;
    uint8 internal constant ROUTE_V3_PATH = 4;

    /// @notice Fee de PancakeSwap V2 en diezmilesimas: 0,25 % => 9975 (balance0Adjusted = balance0*10000 - amount0In*25).
    uint256 public constant V2_FEE_NUM = 9975;
    uint256 internal constant V2_FEE_DEN = 10_000;

    IPancakeV3Factory   public immutable V3_FACTORY;
    IPancakeV2Router    public immutable V2_ROUTER;
    IPancakeV2Factory   public immutable V2_FACTORY;
    IPancakeSmartRouter public immutable SMART_ROUTER;
    /// @notice WBNB. Se llama WETH por compatibilidad de ABI con el router de Robinhood Chain.
    address             public immutable WETH;

    address public owner;
    address public pendingOwner;
    address public treasury;
    bool    public paused;
    uint16  public maxFeeBps = 200;                 // techo duro 2%
    uint16  public minFeeBps = 100;                 // piso 1 %: en BSC no hay tarifa referida
    bool    public allowExoticPairs;
    bool    public allowUnverifiedPairs;            // saltarse la validacion de la V2 factory
    mapping(address => bool) public isQuoteToken;   // WBNB y stables: sobre estos se cobra
    mapping(address => bool) public isCaller;       // contratos autorizados a usar swapWithFee
    mapping(address => bool) public isPairAllowed;  // pairs V2 fuera de la factory, uno a uno

    // contabilidad barata: 1 SSTORE por swap
    mapping(address => mapping(address => uint256)) public accrued; // beneficiario => token => monto
    mapping(address => uint256) public pendingEth;                  // pagos en BNB que rebotaron

    // transient slots
    uint256 private constant _LOCK_SLOT = 0;
    uint256 private constant _CB_TOKEN_IN  = 1;
    uint256 private constant _CB_TOKEN_OUT = 2;
    uint256 private constant _CB_FEE       = 3;

    event Swap(
        address indexed user, address indexed tokenIn, address indexed tokenOut,
        uint256 amountIn, uint256 amountOut, address feeToken, uint256 feeAmount, address referrer
    );
    event Accrued(address indexed beneficiary, address indexed token, uint256 amount);
    event Claimed(address indexed beneficiary, address indexed token, uint256 amount);
    event EthPending(address indexed to, uint256 amount);
    event EthWithdrawn(address indexed to, uint256 amount);
    event CallerSet(address indexed caller, bool allowed);
    event PairAllowed(address indexed pair, bool allowed);
    event QuoteTokenSet(address indexed token, bool allowed);
    event TreasurySet(address indexed treasury);
    event PausedSet(bool paused);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOwner();
    error NotCaller();
    error Reentrant();
    error FeeTooHigh();
    error FeeTooLow();
    error Slippage(uint256 got, uint256 want);
    error BadPool();
    error BadRoute();
    error NoQuoteToken();
    error Expired();
    error IsPaused();
    error ZeroAddress();
    error EthTransferFailed();

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }
    modifier onlyCaller() { if (!isCaller[msg.sender]) revert NotCaller(); _; }
    modifier whenNotPaused() { if (paused) revert IsPaused(); _; }
    modifier notExpired(uint256 deadline) { if (block.timestamp > deadline) revert Expired(); _; }

    modifier lock() {
        assembly ("memory-safe") { if tload(_LOCK_SLOT) { mstore(0, 0) revert(0, 0) } tstore(_LOCK_SLOT, 1) }
        _;
        assembly ("memory-safe") { tstore(_LOCK_SLOT, 0) }
    }

    /// @param v3Factory   PancakeV3Factory      0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865
    /// @param v2Router    PancakeRouter (V2)    0x10ED43C718714eb63d5aA57B78B54704E256024E
    /// @param v2Factory   PancakeFactory (V2)   0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73
    /// @param smartRouter SmartRouter (V3 path) 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4 (puede ser 0: sin ROUTE_V3_PATH)
    /// @param treasury_   tesoreria en BSC
    /// @param wbnb        WBNB                  0xbb4CdB9CBd36B01bD1cBaEbF2De08d9173bc095c
    /// Las direcciones de PancakeSwap se cruzan entre si en el constructor: un deploy con una direccion
    /// equivocada revierte en vez de nacer roto.
    constructor(
        address v3Factory,
        address v2Router,
        address v2Factory,
        address smartRouter,
        address treasury_,
        address wbnb
    ) {
        if (treasury_ == address(0) || wbnb == address(0) || v3Factory == address(0) || v2Factory == address(0)) revert ZeroAddress();
        if (v2Router != address(0)) {
            if (IPancakeV2Router(v2Router).WETH() != wbnb || IPancakeV2Router(v2Router).factory() != v2Factory) revert BadRoute();
        }
        if (smartRouter != address(0)) {
            if (IPancakeSmartRouter(smartRouter).WETH9() != wbnb || IPancakeSmartRouter(smartRouter).factory() != v3Factory) revert BadRoute();
        }
        V3_FACTORY   = IPancakeV3Factory(v3Factory);
        V2_ROUTER    = IPancakeV2Router(v2Router);
        V2_FACTORY   = IPancakeV2Factory(v2Factory);
        SMART_ROUTER = IPancakeSmartRouter(smartRouter);
        treasury     = treasury_;
        owner        = msg.sender;
        WETH         = wbnb;
        isQuoteToken[wbnb] = true;
        emit QuoteTokenSet(wbnb, true);
        emit TreasurySet(treasury_);
    }

    /// @notice Alias explicito de WETH() para BSC.
    function WBNB() external view returns (address) { return WETH; }

    // ─────────────────────── entrada publica del usuario ───────────────────────

    /// Entrada normal desde la UI. El usuario aprueba ESTE router (o pasa por Permit2).
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint16  feeBps,
        address /* referrer: sin referidos en BSC */,
        uint256 deadline,
        bytes calldata route
    ) external lock whenNotPaused notExpired(deadline) returns (uint256 amountOut) {
        _precheck(tokenIn, tokenOut, feeBps);
        uint256 actualIn = _pullIn(tokenIn, msg.sender, amountIn);
        amountOut = _run(tokenIn, tokenOut, amountIn, actualIn, minAmountOut, msg.sender, feeBps, route);
    }

    /// Compra pagando con BNB nativo: se envuelve aca mismo y se opera en WBNB. El fee se cobra
    /// SIEMPRE en WBNB, antes de tocar el pool.
    function swapETH(
        address tokenOut,
        uint256 minAmountOut,
        uint16  feeBps,
        address /* referrer: sin referidos en BSC */,
        uint256 deadline,
        bytes calldata route
    ) external payable lock whenNotPaused notExpired(deadline) returns (uint256 amountOut) {
        if (msg.value == 0 || tokenOut == address(0) || tokenOut == WETH) revert BadRoute();
        _checkFee(feeBps);

        uint256 feeAmount = (msg.value * feeBps) / 10_000;
        uint256 swapIn = msg.value - feeAmount;
        IWETH(WETH).deposit{value: msg.value}();
        amountOut = _swapTo(WETH, tokenOut, swapIn, msg.sender, route);
        if (amountOut < minAmountOut) revert Slippage(amountOut, minAmountOut);

        _bookFee(WETH, feeAmount);
        emit Swap(msg.sender, address(0), tokenOut, msg.value, amountOut, WETH, feeAmount, address(0));
    }

    /// Venta cobrando BNB nativo. El pool entrega WBNB a este contrato; se mide lo recibido, el fee
    /// se aparta en WBNB y el resto sale como BNB al usuario.
    function swapToETH(
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        uint16  feeBps,
        address /* referrer: sin referidos en BSC */,
        uint256 deadline,
        bytes calldata route
    ) external lock whenNotPaused notExpired(deadline) returns (uint256 amountOut) {
        if (tokenIn == address(0) || tokenIn == WETH) revert BadRoute();
        _checkFee(feeBps);
        uint256 actualIn = _pullIn(tokenIn, msg.sender, amountIn);

        uint256 received = _swapTo(tokenIn, WETH, actualIn, address(this), route);

        uint256 feeAmount = (received * feeBps) / 10_000;
        amountOut = received - feeAmount;
        if (amountOut < minAmountOut) revert Slippage(amountOut, minAmountOut);
        IWETH(WETH).withdraw(amountOut);
        _payEth(msg.sender, amountOut);

        _bookFee(WETH, feeAmount);
        emit Swap(msg.sender, tokenIn, address(0), amountIn, amountOut, WETH, feeAmount, address(0));
    }

    /// BNB entra solo desde WBNB (withdraw).
    receive() external payable {
        if (msg.sender != WETH) revert BadRoute();
    }

    /// Entrada desde los bots y el ejecutor de ordenes limit. SOLO contratos allowlisteados
    /// (deciden el destinatario). El `referrer` se ignora: sin referidos en BSC.
    function swapWithFee(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint16  feeBps,
        address /* referrer: sin referidos en BSC */,
        uint256 deadline,
        bytes calldata route
    ) external lock whenNotPaused onlyCaller notExpired(deadline) returns (uint256 amountOut) {
        if (recipient == address(0)) revert ZeroAddress();
        _precheck(tokenIn, tokenOut, feeBps);
        uint256 actualIn = _pullIn(tokenIn, msg.sender, amountIn);
        amountOut = _run(tokenIn, tokenOut, amountIn, actualIn, minAmountOut, recipient, feeBps, route);
    }

    // ────────────────────────────── nucleo ──────────────────────────────

    function _checkFee(uint16 feeBps) internal view {
        if (feeBps > maxFeeBps) revert FeeTooHigh();
        if (feeBps < minFeeBps) revert FeeTooLow();
    }

    /// Lo barato se chequea ANTES de mover tokens: fee, par y politica de quote. Las rutas se validan al ejecutarlas.
    function _precheck(address tokenIn, address tokenOut, uint16 feeBps) internal view {
        _checkFee(feeBps);
        if (tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut) revert BadRoute();
        if (!isQuoteToken[tokenIn] && !isQuoteToken[tokenOut] && !allowExoticPairs) revert NoQuoteToken();
    }

    /// Trae `amount` del usuario y devuelve lo que LLEGO (un token con tax entrega menos).
    function _pullIn(address token, address from, uint256 amount) internal returns (uint256 actualIn) {
        if (amount == 0) revert BadRoute();
        uint256 before = IERC20(token).balanceOf(address(this));
        token.pull(from, address(this), amount);
        actualIn = IERC20(token).balanceOf(address(this)) - before;
        if (actualIn == 0) revert BadRoute();
    }

    /// @param amountIn nominal (lo que el usuario mando; va al evento). @param actualIn lo que llego (se opera con esto).
    function _run(
        address tokenIn, address tokenOut, uint256 amountIn, uint256 actualIn, uint256 minAmountOut,
        address recipient, uint16 feeBps, bytes calldata route
    ) internal returns (uint256 amountOut) {
        _checkFee(feeBps);
        if (tokenIn == tokenOut || tokenOut == address(0)) revert BadRoute();

        address feeToken;
        uint256 feeAmount;

        if (isQuoteToken[tokenIn]) {
            // ── COMPRA: fee sobre el input, exacto, y el output va directo al usuario
            feeToken  = tokenIn;
            feeAmount = (actualIn * feeBps) / 10_000;
            uint256 swapIn = actualIn - feeAmount;
            amountOut = _swapTo(tokenIn, tokenOut, swapIn, recipient, route);
            if (amountOut < minAmountOut) revert Slippage(amountOut, minAmountOut);
        } else {
            // ── VENTA / token-token: swap a este contrato y fee sobre el output medido
            if (!isQuoteToken[tokenOut]) {
                // si ninguno de los dos es quote, igual cobramos sobre el output;
                // asumir el riesgo de un token raro es decision del owner via whitelist
                if (!allowExoticPairs) revert NoQuoteToken();
            }
            uint256 received = _swapTo(tokenIn, tokenOut, actualIn, address(this), route);

            feeToken  = tokenOut;
            feeAmount = (received * feeBps) / 10_000;
            amountOut = received - feeAmount;
            if (amountOut < minAmountOut) revert Slippage(amountOut, minAmountOut);
            tokenOut.send(recipient, amountOut);
        }

        _bookFee(feeToken, feeAmount);
        emit Swap(recipient, tokenIn, tokenOut, amountIn, amountOut, feeToken, feeAmount, address(0));
    }

    /// Contabilidad: 1 SSTORE. Todo el fee a la tesoreria; se cobra con claim (pull over push).
    function _bookFee(address token, uint256 amount) internal {
        if (amount == 0) return;
        accrued[treasury][token] += amount;
        emit Accrued(treasury, token, amount);
    }

    function claim(address token) external lock returns (uint256 amount) {
        amount = accrued[msg.sender][token];
        accrued[msg.sender][token] = 0;   // efecto antes de la interaccion
        if (amount != 0) token.send(msg.sender, amount);
        emit Claimed(msg.sender, token, amount);
    }

    // ────────────────────────── pagos en BNB ──────────────────────────
    //
    // Un `recipient` contrato con receive() caro (o que revierte a proposito)
    // bloqueaba toda la venta y podia quemarnos el gas restante. Con gas cap y
    // saldo pendiente el swap SIEMPRE termina y el BNB queda reclamable.
    function _payEth(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount, gas: 30_000}("");
        if (!ok) {
            pendingEth[to] += amount;
            emit EthPending(to, amount);
        }
    }

    function withdrawEth() external lock returns (uint256 amount) {
        amount = pendingEth[msg.sender];
        pendingEth[msg.sender] = 0;
        if (amount != 0) {
            (bool ok,) = msg.sender.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
            emit EthWithdrawn(msg.sender, amount);
        }
    }

    // ────────────────────────────── swap engine ──────────────────────────────

    /// Devuelve SIEMPRE el delta de balance medido en `to`: ni el return value del pool V3 ni
    /// el del SmartRouter son confiables frente a tokens con fee-on-transfer o rebase.
    function _swapTo(
        address tokenIn, address tokenOut, uint256 amountIn, address to, bytes calldata route
    ) internal returns (uint256 out) {
        if (amountIn == 0) revert BadRoute();   // 0 es "usar el balance del contrato" en el SmartRouter: jamas
        (uint8 kind, bytes memory payload) = abi.decode(route, (uint8, bytes));
        uint256 balBefore = IERC20(tokenOut).balanceOf(to);

        if (kind == ROUTE_V3) {
            uint24 poolFee = abi.decode(payload, (uint24));
            address pool = V3_FACTORY.getPool(tokenIn, tokenOut, poolFee);
            if (pool == address(0)) revert BadPool();

            bool zeroForOne = tokenIn < tokenOut;
            // guardar el contexto del callback en transient storage (mas barato que memoria+abi.encode)
            assembly ("memory-safe") {
                tstore(_CB_TOKEN_IN, tokenIn)
                tstore(_CB_TOKEN_OUT, tokenOut)
                tstore(_CB_FEE, poolFee)
            }
            IPancakeV3Pool(pool).swap(
                to, zeroForOne, int256(amountIn),
                zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1,
                hex"01"
            );
        } else if (kind == ROUTE_V2) {
            if (address(V2_ROUTER) == address(0)) revert BadRoute();
            address[] memory path = abi.decode(payload, (address[]));
            uint256 n = path.length;
            if (n < 2) revert BadRoute();
            // los bots usan UNA ruta (un solo hash) para comprar y vender: un path al reves se da vuelta
            if (path[0] == tokenOut && path[n - 1] == tokenIn) {
                for (uint256 i = 0; i < n / 2; i++) { (path[i], path[n - 1 - i]) = (path[n - 1 - i], path[i]); }
            }
            if (path[0] != tokenIn || path[n - 1] != tokenOut) revert BadRoute();
            _approveExact(tokenIn, address(V2_ROUTER), amountIn);
            // la variante SupportingFeeOnTransfer no devuelve montos: medimos nosotros
            V2_ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amountIn, 0, path, to, block.timestamp
            );
            _revoke(tokenIn, address(V2_ROUTER));   // nunca queda allowance viva
        } else if (kind == ROUTE_V2_DIRECT) {
            // Ruta correcta para tokens con fee-on-transfer.
            // El token viaja UNA sola vez (este contrato -> pair), asi que el token
            // cobra su tax una sola vez. Pasar por el PancakeRouter obliga a
            // usuario -> router -> pair = DOS taxes.
            (address pair, uint256 feeNum) = abi.decode(payload, (address, uint256)); // feeNum: 9975 en PancakeSwap V2
            _checkPair(pair, tokenIn, tokenOut, feeNum);
            bool zeroForOne = tokenIn < tokenOut;

            uint256 pairBalBefore = IERC20(tokenIn).balanceOf(pair);
            tokenIn.send(pair, amountIn);
            // amountIn REAL que llego al pair (post-tax), no el nominal
            uint256 actualIn = IERC20(tokenIn).balanceOf(pair) - pairBalBefore;

            (uint112 r0, uint112 r1,) = IPancakeV2Pair(pair).getReserves();
            (uint256 rIn, uint256 rOut) = zeroForOne ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
            uint256 amtInWithFee = actualIn * feeNum;
            uint256 amountOutCalc = (amtInWithFee * rOut) / (rIn * V2_FEE_DEN + amtInWithFee);

            IPancakeV2Pair(pair).swap(
                zeroForOne ? 0 : amountOutCalc,
                zeroForOne ? amountOutCalc : 0,
                to, ""
            );
        } else if (kind == ROUTE_V3_PATH) {
            if (address(SMART_ROUTER) == address(0)) revert BadRoute();
            bytes memory path = abi.decode(payload, (bytes));
            path = _orientPath(path, tokenIn, tokenOut);
            _approveExact(tokenIn, address(SMART_ROUTER), amountIn);
            SMART_ROUTER.exactInput(IPancakeSmartRouter.ExactInputParams({
                path: path, recipient: to, amountIn: amountIn, amountOutMinimum: 0
            }));
            _revoke(tokenIn, address(SMART_ROUTER));
        } else {
            revert BadRoute();
        }

        out = IERC20(tokenOut).balanceOf(to) - balBefore; // medido en DESTINO, siempre
    }

    /// El `pair` de ROUTE_V2_DIRECT es un parametro del usuario y recibe sus tokens con un
    /// transfer directo: sin esta comprobacion, un "pair" de mentira se queda con todo y
    /// devuelve 0. Un pair de la factory canonica tiene que declarar 9975 (su fee real):
    /// un feeNum mas bajo regalaria la diferencia al pool, uno mas alto revierte con 'Pancake: K'.
    function _checkPair(address pair, address tokenIn, address tokenOut, uint256 feeNum) internal view {
        if (pair == address(0)) revert BadPool();
        if (feeNum > V2_FEE_DEN || feeNum < 9000) revert BadRoute();
        if (isPairAllowed[pair]) return;
        if (V2_FACTORY.getPair(tokenIn, tokenOut) == pair) {
            if (feeNum != V2_FEE_NUM) revert BadRoute();
            return;
        }
        if (!allowUnverifiedPairs) revert BadPool();
    }

    /// path de la periferia V3: 20 bytes token, 3 bytes fee, 20 bytes token, ... Tiene que empezar en tokenIn y
    /// terminar en tokenOut. Si viene al reves (los bots usan UNA ruta para comprar y vender) se da vuelta.
    function _orientPath(bytes memory path, address tokenIn, address tokenOut) internal pure returns (bytes memory) {
        uint256 n = path.length;
        if (n < 43 || (n - 20) % 23 != 0) revert BadRoute();
        address first; address last;
        assembly ("memory-safe") {
            first := shr(96, mload(add(path, 32)))
            last := shr(96, mload(add(add(path, 32), sub(n, 20))))
        }
        if (first == tokenIn && last == tokenOut) return path;
        if (first != tokenOut || last != tokenIn) revert BadRoute();
        // reves: tokens en 23*i (i = 0..hops), fees en 23*i + 20 (i = 0..hops-1)
        uint256 hops = (n - 20) / 23;
        bytes memory r = new bytes(n);
        for (uint256 i = 0; i <= hops; i++) {
            uint256 src = 23 * i; uint256 dst = 23 * (hops - i);
            for (uint256 b = 0; b < 20; b++) r[dst + b] = path[src + b];
        }
        for (uint256 i = 0; i < hops; i++) {
            uint256 src = 23 * i + 20; uint256 dst = 23 * (hops - 1 - i) + 20;
            for (uint256 b = 0; b < 3; b++) r[dst + b] = path[src + b];
        }
        return r;
    }

    /// Callback de PancakeSwap V3. La unica defensa valida es comprobar que msg.sender
    /// ES el pool canonico de la factory para esa terna; si no, cualquiera puede
    /// llamarnos y hacernos pagar.
    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        address tokenIn; address tokenOut; uint24 poolFee;
        assembly ("memory-safe") {
            tokenIn  := tload(_CB_TOKEN_IN)
            tokenOut := tload(_CB_TOKEN_OUT)
            poolFee  := tload(_CB_FEE)
        }
        if (tokenIn == address(0)) revert BadPool();
        if (msg.sender != V3_FACTORY.getPool(tokenIn, tokenOut, poolFee)) revert BadPool();

        uint256 owed = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        tokenIn.send(msg.sender, owed);

        assembly ("memory-safe") { tstore(_CB_TOKEN_IN, 0) tstore(_CB_TOKEN_OUT, 0) tstore(_CB_FEE, 0) }
    }

    /// Aprobacion exacta, y se revoca en la misma transaccion.
    ///
    /// No se aprueba type(uint256).max: este contrato guarda las comisiones acumuladas hasta que
    /// alguien las reclama, o sea que tiene saldo real. Una aprobacion infinita viva convierte
    /// cualquier problema futuro del router aprobado en un drenaje de ese saldo.
    /// Por low-level call y se pone a 0 primero (clones de USDT exigen allowance cero antes de reescribirla).
    function _approveExact(address token, address spender, uint256 amount) internal {
        token.approveRaw(spender, 0);
        token.approveRaw(spender, amount);
    }

    function _revoke(address token, address spender) internal {
        token.approveRaw(spender, 0);
    }

    // ────────────────────────────── admin ──────────────────────────────
    function setQuoteToken(address t, bool ok) external onlyOwner { isQuoteToken[t] = ok; emit QuoteTokenSet(t, ok); }
    function setTreasury(address t) external onlyOwner {
        if (t == address(0)) revert ZeroAddress();
        treasury = t;
        emit TreasurySet(t);
    }
    function setMaxFeeBps(uint16 b) external onlyOwner {
        require(b <= 300 && b >= minFeeBps, "techo");
        maxFeeBps = b;
    }
    function setMinFeeBps(uint16 b) external onlyOwner {
        require(b <= maxFeeBps, "piso");
        minFeeBps = b;
    }
    function setAllowExoticPairs(bool v) external onlyOwner { allowExoticPairs = v; }
    function setAllowUnverifiedPairs(bool v) external onlyOwner { allowUnverifiedPairs = v; }
    function setCaller(address c, bool allowed) external onlyOwner { isCaller[c] = allowed; emit CallerSet(c, allowed); }
    function setPairAllowed(address p, bool allowed) external onlyOwner { isPairAllowed[p] = allowed; emit PairAllowed(p, allowed); }
    function setPaused(bool v) external onlyOwner { paused = v; emit PausedSet(v); }

    /// Ownership en 2 pasos: una direccion mal tipeada ya no deja el contrato
    /// sin dueno. El destino debe aceptar explicitamente.
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

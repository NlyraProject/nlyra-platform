// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*  ArchitectFeeRouter v2 - router propio que cobra comision en CADA swap
    ---------------------------------------------------------------------------
    REGLA DE ORO: la comision se cobra SIEMPRE en el token "quote" (WETH u otro
    token de la whitelist), NUNCA en el memecoin. Motivos:
      1. Un token fee-on-transfer / rebase / con blacklist rompe el calculo si le
         cobras a el. WETH no.
      2. La contabilidad de revenue queda en UNA sola unidad -> no acumulas polvo
         en 500 tokens distintos ni necesitas venderlos despues.
      3. El referral y el rebate se pagan en algo que el usuario quiere.

    Por lo tanto:
      - COMPRA (WETH -> TOKEN): fee sobre el INPUT, antes del swap. Exacto y barato.
      - VENTA  (TOKEN -> WETH): fee sobre el OUTPUT, despues del swap. Exacto.
      - TOKEN -> TOKEN sin quote: fee sobre el output medido por balance delta.

    Todos los montos de tokens no confiables se miden con balanceBefore/balanceAfter,
    nunca con el valor de retorno del pool.

    CAMBIOS DE SEGURIDAD v2 (security review 2026-08):
      1. swapWithFee es onlyCaller (allowlist del owner). Antes cualquiera podia
         llamarla pasando `referrer` arbitrario y regalarse el 30% del fee.
         Ahora el referidor sale de referrerOf[recipient] (first-touch), nunca
         del parametro crudo.
      2. minFeeBps: piso duro de comision. Sin el, cualquiera armaba su propio
         calldata con feeBps = 0 y usaba el router gratis.
      3. ROUTE_V2_DIRECT valida el pair contra la V2 factory canonica. Antes se
         podia pasar un "pair" falso que se quedaba con el token del usuario.
      4. V4 exige hooks == address(0) salvo allowlist: un hook arbitrario corre
         codigo del atacante dentro de nuestro unlock.
      5. Todas las salidas se miden por balance delta del DESTINO y se comparan
         contra minAmountOut (V3 y V4 confiaban en el return del pool).
      6. deadline en todas las entradas.
      7. approve por low-level call (USDT y clones no devuelven bool).
      8. pagos en ETH con gas cap 30k + pendingEth/withdrawEth: un recipient
         contrato con receive() caro ya no puede bloquear la operacion ni
         consumir todo el gas.
      9. ownership en 2 pasos + pausa de emergencia.
*/

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

interface IUniswapV3Pool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external returns (int256 swapDelta);   // BalanceDelta empaquetado en un int256
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
}

/// PoolKey de Uniswap V4. currency0 < currency1; address(0) = ETH nativo.
struct PoolKey {
    address currency0;
    address currency1;
    uint24  fee;         // 0x800000 = fee dinamico (lo usan los hooks de esta chain)
    int24   tickSpacing;
    address hooks;
}

struct SwapParams {
    bool    zeroForOne;
    int256  amountSpecified;   // NEGATIVO = exact input
    uint160 sqrtPriceLimitX96;
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function token0() external view returns (address);
}

interface IUniswapV2Router {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline
    ) external;
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
    /// USDT y sus clones NO devuelven bool en approve: hay que llamar en crudo
    /// y aceptar returndata vacia. IERC20(t).approve(...) revierte con ellos.
    function approveRaw(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory d) = token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
        if (!ok || (d.length != 0 && !abi.decode(d, (bool)))) revert TransferFailed();
    }
}

contract ArchitectFeeRouter {
    using SafeTransfer for address;

    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    uint8 internal constant ROUTE_V3 = 0;
    uint8 internal constant ROUTE_V2 = 1;
    uint8 internal constant ROUTE_V4 = 2;
    uint8 internal constant ROUTE_V2_DIRECT = 3; // V2 golpeando el pair directo (1 solo hop de token)

    IUniswapV3Factory public immutable V3_FACTORY;
    IUniswapV2Router  public immutable V2_ROUTER;
    IUniswapV2Factory public immutable V2_FACTORY;
    IPoolManager      public immutable V4_POOL_MANAGER;
    address           public immutable WETH;

    address public owner;
    address public pendingOwner;
    address public treasury;
    bool    public paused;
    uint16  public maxFeeBps = 200;                 // techo duro 2%
    uint16  public minFeeBps = 90;                  // piso duro 0.90% (tarifa referida)
    uint16  public referrerShareBps = 3000;         // 30% del fee va al referidor
    bool    public allowExoticPairs;
    bool    public allowUnverifiedPairs;            // saltarse la validacion de la V2 factory
    mapping(address => bool) public isQuoteToken;   // WETH y stables: sobre estos se cobra
    mapping(address => bool) public isCaller;       // contratos autorizados a usar swapWithFee
    mapping(address => bool) public isHook;         // hooks V4 auditados por el owner
    mapping(address => bool) public isPairAllowed;  // pairs V2 fuera de la factory, uno a uno

    // contabilidad barata: 1 SSTORE por swap con referidor
    mapping(address => mapping(address => uint256)) public accrued; // beneficiario => token => monto
    mapping(address => address) public referrerOf;                  // referido persistente (first-touch)
    mapping(address => uint256) public pendingEth;                  // pagos en ETH que rebotaron

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
    event HookSet(address indexed hooks, bool allowed);
    event PairAllowed(address indexed pair, bool allowed);
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
    error BadHook();
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

    constructor(
        address v3Factory,
        address v2Router,
        address v2Factory,
        address v4PoolManager,
        address treasury_,
        address weth
    ) {
        if (treasury_ == address(0) || weth == address(0)) revert ZeroAddress();
        V3_FACTORY = IUniswapV3Factory(v3Factory);
        V2_ROUTER  = IUniswapV2Router(v2Router);
        V2_FACTORY = IUniswapV2Factory(v2Factory);
        V4_POOL_MANAGER = IPoolManager(v4PoolManager);
        treasury   = treasury_;
        owner      = msg.sender;
        WETH       = weth;
        isQuoteToken[weth] = true;
    }

    // ─────────────────────── entrada publica del usuario ───────────────────────

    /// Entrada normal desde la UI. El usuario aprueba ESTE router (o pasa por Permit2).
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint16  feeBps,
        address referrer,
        uint256 deadline,
        bytes calldata route
    ) external lock whenNotPaused notExpired(deadline) returns (uint256 amountOut) {
        _bindReferrer(msg.sender, referrer);
        tokenIn.pull(msg.sender, address(this), amountIn);
        amountOut = _run(tokenIn, tokenOut, amountIn, minAmountOut, msg.sender, feeBps,
                         referrerOf[msg.sender], route);
    }

    /// Compra pagando con ETH nativo. En esta chain los pools V4 cotizan en ETH
    /// NATIVO (currency0 = address(0)), los V2/V3 en WETH: si la ruta es V4
    /// nativa el ETH viaja tal cual, si no se envuelve aca mismo. El fee se
    /// cobra SIEMPRE en WETH, antes de tocar el pool.
    function swapETH(
        address tokenOut,
        uint256 minAmountOut,
        uint16  feeBps,
        address referrer,
        uint256 deadline,
        bytes calldata route
    ) external payable lock whenNotPaused notExpired(deadline) returns (uint256 amountOut) {
        if (msg.value == 0 || tokenOut == address(0)) revert BadRoute();
        _checkFee(feeBps);
        _bindReferrer(msg.sender, referrer);

        uint256 feeAmount = (msg.value * feeBps) / 10_000;
        uint256 swapIn = msg.value - feeAmount;
        if (feeAmount != 0) IWETH(WETH).deposit{value: feeAmount}();

        (uint8 kind, bytes memory payload) = abi.decode(route, (uint8, bytes));
        if (kind == ROUTE_V4 && _v4IsNative(payload)) {
            // el token lo entrega el PoolManager directo al usuario: medimos ALLA
            uint256 before = IERC20(tokenOut).balanceOf(msg.sender);
            _swapV4(payload, address(0), tokenOut, swapIn, msg.sender);
            amountOut = IERC20(tokenOut).balanceOf(msg.sender) - before;
        } else {
            IWETH(WETH).deposit{value: swapIn}();
            amountOut = _swapTo(WETH, tokenOut, swapIn, msg.sender, route);
        }
        if (amountOut < minAmountOut) revert Slippage(amountOut, minAmountOut);

        _bookFee(WETH, feeAmount, referrerOf[msg.sender]);
        emit Swap(msg.sender, address(0), tokenOut, msg.value, amountOut, WETH, feeAmount, referrerOf[msg.sender]);
    }

    /// Venta cobrando ETH nativo. El pool entrega WETH (V2/V3) o ETH (V4
    /// nativo) a este contrato; se mide lo recibido, el fee se aparta en WETH
    /// y el resto sale como ETH al usuario.
    function swapToETH(
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        uint16  feeBps,
        address referrer,
        uint256 deadline,
        bytes calldata route
    ) external lock whenNotPaused notExpired(deadline) returns (uint256 amountOut) {
        if (tokenIn == address(0) || tokenIn == WETH) revert BadRoute();
        _checkFee(feeBps);
        _bindReferrer(msg.sender, referrer);
        tokenIn.pull(msg.sender, address(this), amountIn);

        (uint8 kind, bytes memory payload) = abi.decode(route, (uint8, bytes));
        uint256 received;
        if (kind == ROUTE_V4 && _v4IsNative(payload)) {
            uint256 before = address(this).balance;
            _swapV4(payload, tokenIn, address(0), amountIn, address(this));
            received = address(this).balance - before;
        } else {
            received = _swapTo(tokenIn, WETH, amountIn, address(this), route);
            IWETH(WETH).withdraw(received);
        }

        uint256 feeAmount = (received * feeBps) / 10_000;
        amountOut = received - feeAmount;
        if (amountOut < minAmountOut) revert Slippage(amountOut, minAmountOut);
        if (feeAmount != 0) IWETH(WETH).deposit{value: feeAmount}();
        _payEth(msg.sender, amountOut);

        _bookFee(WETH, feeAmount, referrerOf[msg.sender]);
        emit Swap(msg.sender, tokenIn, address(0), amountIn, amountOut, WETH, feeAmount, referrerOf[msg.sender]);
    }

    /// ETH entra solo desde WETH (withdraw) o desde el PoolManager (take nativo).
    receive() external payable {
        if (msg.sender != WETH && msg.sender != address(V4_POOL_MANAGER)) revert BadRoute();
    }

    /// Entrada desde el ejecutor de ordenes limit. SOLO contratos allowlisteados:
    /// el `referrer` que llega aca es un parametro, y si cualquiera pudiera
    /// llamarla se auto-acreditaria el 30% del fee de todos los swaps.
    function swapWithFee(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint16  feeBps,
        address referrer,
        uint256 deadline,
        bytes calldata route
    ) external lock whenNotPaused onlyCaller notExpired(deadline) returns (uint256 amountOut) {
        if (recipient == address(0)) revert ZeroAddress();
        // el referral pertenece al DESTINATARIO, no a quien llama, y es first-touch
        _bindReferrer(recipient, referrer);
        tokenIn.pull(msg.sender, address(this), amountIn);
        amountOut = _run(tokenIn, tokenOut, amountIn, minAmountOut, recipient, feeBps,
                         referrerOf[recipient], route);
    }

    // ────────────────────────────── nucleo ──────────────────────────────

    function _checkFee(uint16 feeBps) internal view {
        if (feeBps > maxFeeBps) revert FeeTooHigh();
        if (feeBps < minFeeBps) revert FeeTooLow();
    }

    function _bindReferrer(address user, address referrer) internal {
        if (referrerOf[user] == address(0) && referrer != address(0) && referrer != user) {
            referrerOf[user] = referrer;
        }
    }

    function _v4IsNative(bytes memory payload) internal pure returns (bool) {
        (PoolKey memory key,) = abi.decode(payload, (PoolKey, bytes));
        return key.currency0 == address(0);
    }

    function _run(
        address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut,
        address recipient, uint16 feeBps, address referrer, bytes calldata route
    ) internal returns (uint256 amountOut) {
        _checkFee(feeBps);

        address feeToken;
        uint256 feeAmount;

        if (isQuoteToken[tokenIn]) {
            // ── COMPRA: fee sobre el input, exacto, y el output va directo al usuario
            feeToken  = tokenIn;
            feeAmount = (amountIn * feeBps) / 10_000;
            uint256 swapIn = amountIn - feeAmount;
            amountOut = _swapTo(tokenIn, tokenOut, swapIn, recipient, route);
            if (amountOut < minAmountOut) revert Slippage(amountOut, minAmountOut);
        } else {
            // ── VENTA / token-token: swap a este contrato y fee sobre el output medido
            if (!isQuoteToken[tokenOut]) {
                // si ninguno de los dos es quote, igual cobramos sobre el output;
                // asumir el riesgo de un token raro es decision del owner via whitelist
                if (!allowExoticPairs) revert NoQuoteToken();
            }
            uint256 received = _swapTo(tokenIn, tokenOut, amountIn, address(this), route);

            feeToken  = tokenOut;
            feeAmount = (received * feeBps) / 10_000;
            amountOut = received - feeAmount;
            if (amountOut < minAmountOut) revert Slippage(amountOut, minAmountOut);
            tokenOut.send(recipient, amountOut);
        }

        _bookFee(feeToken, feeAmount, referrer);
        emit Swap(recipient, tokenIn, tokenOut, amountIn, amountOut, feeToken, feeAmount, referrer);
    }

    /// Contabilidad: 1-2 SSTORE. A 0.02 gwei esto cuesta ~USD 0.0004, asi que no
    /// hace falta Merkle: se acumula on-chain y se cobra con claim (pull over push).
    function _bookFee(address token, uint256 amount, address referrer) internal {
        if (amount == 0) return;
        uint256 refCut = 0;
        if (referrer != address(0)) {
            refCut = (amount * referrerShareBps) / 10_000;
            if (refCut != 0) {
                accrued[referrer][token] += refCut;
                emit Accrued(referrer, token, refCut);
            }
        }
        accrued[treasury][token] += amount - refCut;
        emit Accrued(treasury, token, amount - refCut);
    }

    function claim(address token) external lock returns (uint256 amount) {
        amount = accrued[msg.sender][token];
        accrued[msg.sender][token] = 0;   // efecto antes de la interaccion
        if (amount != 0) token.send(msg.sender, amount);
        emit Claimed(msg.sender, token, amount);
    }

    // ────────────────────────── pagos en ETH ──────────────────────────
    //
    // Un `recipient` contrato con receive() caro (o que revierte a proposito)
    // bloqueaba toda la venta y podia quemarnos el gas restante. Con gas cap y
    // saldo pendiente el swap SIEMPRE termina y el ETH queda reclamable.
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

    /// Devuelve SIEMPRE el delta de balance medido en `to`: ni el return value
    /// del pool V3 ni el BalanceDelta de V4 son confiables frente a tokens con
    /// fee-on-transfer, rebase o hooks que se quedan una parte.
    function _swapTo(
        address tokenIn, address tokenOut, uint256 amountIn, address to, bytes calldata route
    ) internal returns (uint256 out) {
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
            IUniswapV3Pool(pool).swap(
                to, zeroForOne, int256(amountIn),
                zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1,
                hex"01"
            );
        } else if (kind == ROUTE_V2) {
            address[] memory path = abi.decode(payload, (address[]));
            if (path.length < 2 || path[0] != tokenIn || path[path.length - 1] != tokenOut) revert BadRoute();
            _approveExact(tokenIn, address(V2_ROUTER), amountIn);
            // la variante SupportingFeeOnTransfer no devuelve montos: medimos nosotros
            V2_ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amountIn, 0, path, to, block.timestamp
            );
            _revoke(tokenIn, address(V2_ROUTER));   // nunca queda allowance viva
        } else if (kind == ROUTE_V4) {
            _swapV4(payload, tokenIn, tokenOut, amountIn, to);
        } else if (kind == ROUTE_V2_DIRECT) {
            // Ruta correcta para tokens con fee-on-transfer.
            // El token viaja UNA sola vez (este contrato -> pair), asi que el token
            // cobra su tax una sola vez. Pasar por el V2Router obliga a
            // usuario -> router -> pair = DOS taxes. Es el error que evitan
            // Maestro y Banana Gun mandando el token directo al pair.
            (address pair, uint256 feeNum) = abi.decode(payload, (address, uint256)); // feeNum: 997 en un fork estandar
            if (feeNum > 1000 || feeNum < 900) revert BadRoute();
            _checkPair(pair, tokenIn, tokenOut);
            bool zeroForOne = tokenIn < tokenOut;

            uint256 pairBalBefore = IERC20(tokenIn).balanceOf(pair);
            tokenIn.send(pair, amountIn);
            // amountIn REAL que llego al pair (post-tax), no el nominal
            uint256 actualIn = IERC20(tokenIn).balanceOf(pair) - pairBalBefore;

            (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
            (uint256 rIn, uint256 rOut) = zeroForOne ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
            uint256 amtInWithFee = actualIn * feeNum;
            uint256 amountOutCalc = (amtInWithFee * rOut) / (rIn * 1000 + amtInWithFee);

            IUniswapV2Pair(pair).swap(
                zeroForOne ? 0 : amountOutCalc,
                zeroForOne ? amountOutCalc : 0,
                to, ""
            );
        } else {
            revert BadRoute();
        }

        out = IERC20(tokenOut).balanceOf(to) - balBefore; // medido en DESTINO, siempre
    }

    /// El `pair` de ROUTE_V2_DIRECT es un parametro del usuario y recibe sus
    /// tokens con un transfer directo: sin esta comprobacion, un "pair" de
    /// mentira se queda con todo y devuelve 0.
    function _checkPair(address pair, address tokenIn, address tokenOut) internal view {
        if (pair == address(0)) revert BadPool();
        if (isPairAllowed[pair]) return;
        if (address(V2_FACTORY) == address(0)) {
            if (!allowUnverifiedPairs) revert BadPool();
            return;
        }
        if (V2_FACTORY.getPair(tokenIn, tokenOut) != pair) {
            if (!allowUnverifiedPairs) revert BadPool();
        }
    }

    /// V4 vive en un singleton: se abre un unlock y se liquidan los deltas en
    /// el callback. tokenIn/tokenOut = address(0) significa ETH nativo.
    function _swapV4(bytes memory payload, address tokenIn, address tokenOut, uint256 amountIn, address to)
        internal returns (uint256 out)
    {
        (PoolKey memory key, bytes memory hookData) = abi.decode(payload, (PoolKey, bytes));
        // un hook arbitrario es codigo del atacante corriendo dentro de nuestro
        // unlock, con nuestros deltas abiertos: se exige hook nulo o allowlist
        if (key.hooks != address(0) && !isHook[key.hooks]) revert BadHook();
        bytes memory res = V4_POOL_MANAGER.unlock(abi.encode(key, tokenIn, tokenOut, amountIn, to, hookData));
        out = abi.decode(res, (uint256));
    }

    /// Callback del PoolManager de V4. Solo el singleton puede llamarlo.
    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(V4_POOL_MANAGER)) revert BadPool();
        (PoolKey memory key, address tokenIn, address tokenOut, uint256 amountIn,
         address to, bytes memory hookData) =
            abi.decode(raw, (PoolKey, address, address, uint256, address, bytes));

        bool zeroForOne = tokenIn == key.currency0;
        if (!zeroForOne && tokenIn != key.currency1) revert BadRoute();
        if (tokenOut != (zeroForOne ? key.currency1 : key.currency0)) revert BadRoute();

        int256 packed = V4_POOL_MANAGER.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),   // negativo = exact input
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1
            }),
            hookData
        );
        // BalanceDelta: amount0 en los 128 bits altos, amount1 en los bajos
        int128 amount0 = int128(packed >> 128);
        int128 amount1 = int128(packed);
        int128 deltaIn  = zeroForOne ? amount0 : amount1;   // negativo: lo debemos
        int128 deltaOut = zeroForOne ? amount1 : amount0;   // positivo: nos lo llevamos

        uint256 owed = uint256(uint128(-deltaIn));
        if (tokenIn == address(0)) {
            V4_POOL_MANAGER.settle{value: owed}();          // ETH nativo: se paga con value
        } else {
            V4_POOL_MANAGER.sync(tokenIn);
            tokenIn.send(address(V4_POOL_MANAGER), owed);
            V4_POOL_MANAGER.settle();
        }

        uint256 got = uint256(uint128(deltaOut));
        V4_POOL_MANAGER.take(tokenOut, to, got);
        return abi.encode(got);
    }

    /// Callback de Uniswap V3. La unica defensa valida es comprobar que msg.sender
    /// ES el pool canonico de la factory para esa terna; si no, cualquiera puede
    /// llamarnos y hacernos pagar.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
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
    /// La variante comoda es aprobar type(uint256).max una vez y olvidarse.
    /// No la usamos: este contrato guarda las comisiones acumuladas hasta que
    /// alguien las reclama, o sea que tiene saldo real. Una aprobacion infinita
    /// viva convierte cualquier problema futuro del router aprobado en un
    /// drenaje de ese saldo. A 0.02 gwei los dos SSTORE extra cuestan
    /// centesimas de centavo; el riesgo que sacan de encima no.
    ///
    /// Por low-level call: USDT y clones no devuelven bool y hacen revertir a
    /// IERC20(t).approve(). Ademas se pone a 0 primero (USDT exige allowance
    /// cero antes de reescribirla).
    function _approveExact(address token, address spender, uint256 amount) internal {
        token.approveRaw(spender, 0);
        token.approveRaw(spender, amount);
    }

    function _revoke(address token, address spender) internal {
        token.approveRaw(spender, 0);
    }

    // ────────────────────────────── admin ──────────────────────────────
    function setQuoteToken(address t, bool ok) external onlyOwner { isQuoteToken[t] = ok; }
    function setTreasury(address t) external onlyOwner {
        if (t == address(0)) revert ZeroAddress();
        treasury = t;
    }
    function setMaxFeeBps(uint16 b) external onlyOwner {
        require(b <= 300 && b >= minFeeBps, "techo");
        maxFeeBps = b;
    }
    function setMinFeeBps(uint16 b) external onlyOwner {
        require(b <= maxFeeBps, "piso");
        minFeeBps = b;
    }
    function setReferrerShareBps(uint16 b) external onlyOwner { require(b <= 10_000, "bps"); referrerShareBps = b; }
    function setAllowExoticPairs(bool v) external onlyOwner { allowExoticPairs = v; }
    function setAllowUnverifiedPairs(bool v) external onlyOwner { allowUnverifiedPairs = v; }
    function setCaller(address c, bool allowed) external onlyOwner { isCaller[c] = allowed; emit CallerSet(c, allowed); }
    function setHook(address h, bool allowed) external onlyOwner { isHook[h] = allowed; emit HookSet(h, allowed); }
    function setPairAllowed(address p, bool allowed) external onlyOwner { isPairAllowed[p] = allowed; emit PairAllowed(p, allowed); }
    function setPaused(bool v) external onlyOwner { paused = v; emit PausedSet(v); }

    /// Ownership en 2 pasos: una direccion mal tipeada ya no deja el contrato
    /// sin dueño. El destino debe aceptar explicitamente.
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

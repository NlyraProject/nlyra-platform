// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*  ArchitectSendTo - comprar con una wallet y recibir en otra (2026-09-20)
    ---------------------------------------------------------------------------
    Envoltorio minimo del ArchitectFeeRouter v2 para The Desk: el usuario paga
    desde la wallet que firma y la salida (tokens o ETH) llega a `recipient`.
    No guarda fondos, no tiene estrategia, no tiene keeper. Todo lo que valida
    el router (fee, pares, hooks, deadline, slippage) sigue valiendo: este
    contrato solo esta en su allowlist de callers para poder nombrar al destinatario.

      · compra con ETH: ETH -> WETH -> router.swapWithFee(recipient) (el router
        entrega el token directo al destinatario; ruta V4 nativa: swapETH y este
        contrato reenvia el token);
      · compra con token (USDG u otro): transferFrom del que firma -> router -> destinatario;
      · venta a ETH: transferFrom del que firma -> router.swapToETH -> ETH reenviado
        al destinatario (gas acotado; si el destinatario es un contrato que rechaza
        ETH, la operacion revierte entera: nada queda aca);
      · el referral del router se ata al DESTINATARIO (first-touch) en los caminos
        swapWithFee (compras y ventas a token); en swapETH / swapToETH el "usuario"
        para el router es ESTE contrato, asi que ahi se pasa referrer = 0 siempre:
        si no, el primer referido que pasara por ese camino quedaria atado al contrato
        y cobraria el 30 % del fee de todos los que vinieran despues.

    Lo que se ve en cadena es lo mismo que siempre: quien pago y quien recibio.
    Es comodidad (wallet caliente -> wallet fria), no privacidad.
*/

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}
interface IWETH { function deposit() external payable; function withdraw(uint256) external; }
interface IArchitectRouter {
    function WETH() external view returns (address);
    function swapWithFee(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient, uint16 feeBps, address referrer, uint256 deadline, bytes calldata route) external returns (uint256);
    function swapETH(address tokenOut, uint256 minAmountOut, uint16 feeBps, address referrer, uint256 deadline, bytes calldata route) external payable returns (uint256);
    function swapToETH(address tokenIn, uint256 amountIn, uint256 minAmountOut, uint16 feeBps, address referrer, uint256 deadline, bytes calldata route) external returns (uint256);
}
struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }

contract ArchitectSendTo {
    uint8 internal constant ROUTE_V4 = 2;
    IArchitectRouter public immutable ROUTER;
    address public immutable WETH;
    address public owner;
    address public pendingOwner;

    /// @dev tokenIn address(0) = ETH nativo; tokenOut address(0) = ETH nativo
    event SentTo(address indexed payer, address indexed recipient, address indexed tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOwner();
    error ZeroAddress();
    error BadValue();
    error TransferFailed();
    error EthTransferFailed();
    error InsufficientOutput(uint256 got, uint256 want);
    error BadRoute();

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }
    modifier lock() {
        assembly ("memory-safe") { if tload(0) { mstore(0, 0) revert(0, 0) } tstore(0, 1) }
        _;
        assembly ("memory-safe") { tstore(0, 0) }
    }

    constructor(address router) {
        if (router == address(0)) revert ZeroAddress();
        ROUTER = IArchitectRouter(router);
        WETH = IArchitectRouter(router).WETH();
        owner = msg.sender;
    }

    /// ETH entra solo desde el router (swapToETH) o desde WETH (withdraw).
    receive() external payable { if (msg.sender != address(ROUTER) && msg.sender != WETH) revert BadRoute(); }

    // ------------------------------ compras ------------------------------

    /// @notice Compra `tokenOut` pagando con el ETH enviado; el token llega a `recipient`.
    function buyWithETH(address tokenOut, uint256 minOut, uint16 feeBps, address referrer, uint256 deadline, bytes calldata route, address recipient)
        external payable lock returns (uint256 amountOut)
    {
        if (recipient == address(0) || tokenOut == address(0)) revert ZeroAddress();
        if (msg.value == 0) revert BadValue();
        if (_routeIsNativeV4(route)) {
            // el PoolManager cotiza en ETH nativo: el router entrega el token a msg.sender (este contrato) y se reenvia
            uint256 before = IERC20(tokenOut).balanceOf(address(this));
            ROUTER.swapETH{value: msg.value}(tokenOut, minOut, feeBps, address(0), deadline, route);   // referrer 0: ver cabecera
            amountOut = IERC20(tokenOut).balanceOf(address(this)) - before;
            if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
            _send(tokenOut, recipient, amountOut);
        } else {
            IWETH(WETH).deposit{value: msg.value}();
            _approve(WETH, address(ROUTER), msg.value);
            amountOut = ROUTER.swapWithFee(WETH, tokenOut, msg.value, minOut, recipient, feeBps, referrer, deadline, route);
        }
        emit SentTo(msg.sender, recipient, address(0), tokenOut, msg.value, amountOut);
    }

    /// @notice Compra `tokenOut` pagando con `tokenIn` (USDG u otro token aprobado a este contrato); la salida llega a `recipient`.
    function buyWithToken(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint16 feeBps, address referrer, uint256 deadline, bytes calldata route, address recipient)
        external lock returns (uint256 amountOut)
    {
        if (recipient == address(0) || tokenIn == address(0) || tokenOut == address(0)) revert ZeroAddress();
        if (amountIn == 0) revert BadValue();
        _pull(tokenIn, msg.sender, amountIn);
        _approve(tokenIn, address(ROUTER), amountIn);
        amountOut = ROUTER.swapWithFee(tokenIn, tokenOut, amountIn, minOut, recipient, feeBps, referrer, deadline, route);
        emit SentTo(msg.sender, recipient, tokenIn, tokenOut, amountIn, amountOut);
    }

    // ------------------------------ ventas ------------------------------

    /// @notice Vende `tokenIn` (aprobado a este contrato) y el ETH llega a `recipient`.
    function sellToETH(address tokenIn, uint256 amountIn, uint256 minOut, uint16 feeBps, address /*referrer, no aplica: ver cabecera*/, uint256 deadline, bytes calldata route, address recipient)
        external lock returns (uint256 amountOut)
    {
        if (recipient == address(0) || tokenIn == address(0)) revert ZeroAddress();
        if (amountIn == 0) revert BadValue();
        _pull(tokenIn, msg.sender, amountIn);
        _approve(tokenIn, address(ROUTER), amountIn);
        uint256 before = address(this).balance;
        ROUTER.swapToETH(tokenIn, amountIn, minOut, feeBps, address(0), deadline, route);   // referrer 0: ver cabecera
        amountOut = address(this).balance - before;
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
        (bool ok,) = recipient.call{value: amountOut, gas: 50_000}("");
        if (!ok) revert EthTransferFailed();
        emit SentTo(msg.sender, recipient, tokenIn, address(0), amountIn, amountOut);
    }

    /// @notice Vende `tokenIn` por otro token (p. ej. USDG); la salida llega a `recipient`.
    function sellToToken(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, uint16 feeBps, address referrer, uint256 deadline, bytes calldata route, address recipient)
        external lock returns (uint256 amountOut)
    {
        if (recipient == address(0) || tokenIn == address(0) || tokenOut == address(0)) revert ZeroAddress();
        if (amountIn == 0) revert BadValue();
        _pull(tokenIn, msg.sender, amountIn);
        _approve(tokenIn, address(ROUTER), amountIn);
        amountOut = ROUTER.swapWithFee(tokenIn, tokenOut, amountIn, minOut, recipient, feeBps, referrer, deadline, route);
        emit SentTo(msg.sender, recipient, tokenIn, tokenOut, amountIn, amountOut);
    }

    // ------------------------------ internas ------------------------------

    function _routeIsNativeV4(bytes calldata route) internal pure returns (bool) {
        (uint8 kind, bytes memory payload) = abi.decode(route, (uint8, bytes));
        if (kind != ROUTE_V4) return false;
        (PoolKey memory key,) = abi.decode(payload, (PoolKey, bytes));
        return key.currency0 == address(0);
    }
    function _pull(address token, address from, uint256 amount) internal {
        uint256 before = IERC20(token).balanceOf(address(this));
        (bool ok, bytes memory d) = token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, address(this), amount));
        if (!ok || (d.length != 0 && !abi.decode(d, (bool)))) revert TransferFailed();
        if (IERC20(token).balanceOf(address(this)) - before < amount) revert TransferFailed();   // fee-on-transfer: revierte en vez de vender menos de lo declarado
    }
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

    // ------------------------------ admin ------------------------------

    /// @notice Este contrato no debe tener saldo: lo que quede (polvo de un token raro, ETH mandado por error) lo saca el owner.
    function sweep(address token, address to) external onlyOwner lock {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(0)) { (bool ok,) = to.call{value: address(this).balance}(""); if (!ok) revert EthTransferFailed(); }
        else _send(token, to, IERC20(token).balanceOf(address(this)));
    }
    function transferOwnership(address n) external onlyOwner { if (n == address(0)) revert ZeroAddress(); pendingOwner = n; emit OwnershipTransferStarted(owner, n); }
    function acceptOwnership() external { if (msg.sender != pendingOwner) revert NotOwner(); emit OwnershipTransferred(owner, msg.sender); owner = msg.sender; pendingOwner = address(0); }
}

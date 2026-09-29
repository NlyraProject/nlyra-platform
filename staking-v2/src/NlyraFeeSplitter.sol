// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {SafeERC20} from "oz/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "oz/utils/ReentrancyGuard.sol";
import {IPonsLaunchLocker, IWETH9, IRealYieldStakingNotify} from "./interfaces/External.sol";

/// @title NlyraFeeSplitter
/// @notice Destino del feeRedirect de NLYRA en Pons. `harvest()` (cualquiera puede llamarlo) cobra los
///         fees del creador en el locker y reparte TODO el WETH y NLYRA que tenga: SPLIT_BPS al staking
///         (que lo paga en un tramo propio de 7 dias) y el resto al treasury. Tambien reparte donaciones directas (WETH,
///         NLYRA o ETH nativo, que se envuelve) de otras fuentes de fees (router del Desk, OTC, bots).
///         Lo que llega al staking por aca cuenta para el bonus de compound; lo que va directo al staking, no.
/// @dev Sin owner, sin setters, sin retiro. Todo inmutable. Si hay que cambiarlo, el deployer de NLYRA
///      en Pons (treasury) redirige los fees a otro lado con setFeeRedirect: esa es la salida.
contract NlyraFeeSplitter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant MIN_SPLIT_BPS = 1_000; // al menos 10% a stakers
    /// como mucho 90% a stakers: una "donacion" que pasa por aca deja >= 10% en el treasury, asi que
    /// auto-donarse premios elegibles para el bonus (5%) nunca rinde (0,9 * 1,05 < 1)
    uint256 public constant MAX_SPLIT_BPS = 9_000;
    uint256 public constant MIN_INTERVAL = 1 days; // => nunca mas de 7 tramos activos del splitter
    uint256 public constant MAX_INTERVAL = 7 days;

    IPonsLaunchLocker public immutable LOCKER;
    IERC20 public immutable NLYRA;
    IERC20 public immutable WETH;
    address public immutable STAKING;
    address public immutable TREASURY;
    uint256 public immutable SPLIT_BPS;
    /// Minimo entre harvests (>= 1 dia). Cada harvest abre como mucho un tramo de 7 dias en el staking y
    /// los tramos ya abiertos no se tocan, asi que harvests extra (o de 1 wei) no estiran ningun pago;
    /// el intervalo acota la cantidad de tramos activos (<= 7).
    uint256 public immutable MIN_HARVEST_INTERVAL;

    uint256 public lastHarvest;

    event Harvested(
        address indexed caller,
        bool collected,
        uint256 wethToStaking,
        uint256 nlyraToStaking,
        uint256 wethToTreasury,
        uint256 nlyraToTreasury
    );
    event CollectSkipped(bytes4 reason);
    event Swept(address indexed token, uint256 amount);

    error ZeroAddress();
    error BadSplit();
    error BadInterval();
    error TooSoon(uint256 nextAllowed);
    error NotSweepable();
    error NotAContract();

    constructor(
        address locker,
        address nlyra,
        address weth,
        address staking,
        address treasury,
        uint256 splitBps,
        uint256 minHarvestInterval
    ) {
        if (locker == address(0) || nlyra == address(0) || weth == address(0) || staking == address(0)
            || treasury == address(0)) revert ZeroAddress();
        if (locker.code.length == 0) revert NotAContract();
        if (splitBps < MIN_SPLIT_BPS || splitBps > MAX_SPLIT_BPS) revert BadSplit();
        if (minHarvestInterval < MIN_INTERVAL || minHarvestInterval > MAX_INTERVAL) revert BadInterval();
        LOCKER = IPonsLaunchLocker(locker);
        NLYRA = IERC20(nlyra);
        WETH = IERC20(weth);
        STAKING = staking;
        TREASURY = treasury;
        SPLIT_BPS = splitBps;
        MIN_HARVEST_INTERVAL = minHarvestInterval;
    }

    /// Donaciones en ETH nativo: se envuelven a WETH en el proximo harvest.
    receive() external payable {}

    /// @notice Cobra fees de Pons (si hay y si todavia somos el feeRedirect), reparte todo el saldo y
    ///         SIEMPRE avisa al staking, que abre un tramo con lo nuevo mas lo que le hayan mandado directo
    ///         (si no es polvo). Aunque no haya nada para repartir, no revierte: igual consume el intervalo.
    function harvest() external nonReentrant {
        uint256 next = lastHarvest + MIN_HARVEST_INTERVAL;
        if (lastHarvest != 0 && block.timestamp < next) revert TooSoon(next);
        lastHarvest = block.timestamp;

        // 1) cobrar. Solo se toleran dos errores "esperables": no hay fees, o ya no somos el
        //    destinatario (el treasury revirtio el redirect). Cualquier otro error (incluido quedarse
        //    sin gas, que llega sin datos) revierte todo: asi nadie puede "quemar" el intervalo sin cobrar.
        bool collected;
        try LOCKER.collectFees(address(NLYRA)) {
            collected = true;
        } catch (bytes memory err) {
            bytes4 sel = err.length == 4 ? bytes4(err) : bytes4(0);
            if (sel != IPonsLaunchLocker.NoFeesToCollect.selector && sel != IPonsLaunchLocker.NotAuthorized.selector) {
                assembly { revert(add(err, 32), mload(err)) }
            }
            emit CollectSkipped(sel);
        }

        // 2) ETH nativo donado -> WETH
        uint256 eth = address(this).balance;
        if (eth != 0) IWETH9(address(WETH)).deposit{value: eth}();

        // 3) repartir todo el saldo
        uint256 w = WETH.balanceOf(address(this));
        uint256 n = NLYRA.balanceOf(address(this));

        uint256 ws = (w * SPLIT_BPS) / BPS;
        uint256 ns = (n * SPLIT_BPS) / BPS;
        if (ws != 0) WETH.safeTransfer(STAKING, ws);
        if (ns != 0) NLYRA.safeTransfer(STAKING, ns);
        if (w - ws != 0) WETH.safeTransfer(TREASURY, w - ws);
        if (n - ns != 0) NLYRA.safeTransfer(TREASURY, n - ns);

        // 4) el staking abre un tramo con su saldo libre (lo que mandamos cuenta para el bonus de compound;
        //    las fees que llegaron directo al staking entran igual, pero sin bonus). Con polvo no abre nada.
        IRealYieldStakingNotify(STAKING).notifyRewards(ws, ns);

        emit Harvested(msg.sender, collected, ws, ns, w - ws, n - ns);
    }

    /// @notice Tokens que no son WETH ni NLYRA (mandados por error) van al treasury. Cualquiera puede llamarlo.
    function sweep(address token) external nonReentrant {
        if (token == address(WETH) || token == address(NLYRA)) revert NotSweepable();
        uint256 bal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(TREASURY, bal);
        emit Swept(token, bal);
    }

    /// @notice Segundos hasta que se pueda volver a cosechar (0 = ya).
    function harvestableIn() external view returns (uint256) {
        if (lastHarvest == 0) return 0;
        uint256 next = lastHarvest + MIN_HARVEST_INTERVAL;
        return block.timestamp >= next ? 0 : next - block.timestamp;
    }
}

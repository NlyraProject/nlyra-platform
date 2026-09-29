// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {SafeERC20} from "oz/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "oz/utils/ReentrancyGuardTransient.sol";
import {Ownable} from "oz/access/Ownable.sol";
import {Ownable2Step} from "oz/access/Ownable2Step.sol";
import {Math} from "oz/utils/math/Math.sol";
import {IUniswapV3PoolLike} from "./interfaces/External.sol";
import {NlyraFeeSplitter} from "./NlyraFeeSplitter.sol";

/// @title RealYieldStaking (NLYRA staking v2, con los arreglos de las auditorias internas del 27/9 y del 28/9)
/// @notice Stakeas NLYRA, cobras en WETH y NLYRA de los fees reales del token.
///  - Premios por TRAMOS: cada notify crea un tramo que paga lo nuevo en 7 dias exactos (tasa propia y
///    fin propio). El splitter abre como mucho 1 por dia y sweepDonations() otro por dia: nunca mas de 14
///    activos (tope 16).
///  - Tiers: flexible 1x (cooldown de 2 dias), lock 7d 1.25x, lock 14d 1.5x, lock 30d 2x. Los locks vencen
///    a la medianoche UTC siguiente a los 7/14/30 dias y el boost se apaga EXACTO en ese momento para el
///    total (sin keeper) y para el usuario (se liquida al vencimiento en su proxima accion o con kick).
///  - Salir SIEMPRE pasa por el cooldown de 2 dias (flexible y locks vencidos).
///  - compound(minOut, tier, positionId): bonus de la reserva (5%) SOLO al componer al lock de 30 dias y
///    SOLO sobre lo ganado de los fees que mando el splitter (nunca sobre donaciones ni saldo suelto).
///    Se puede componer dentro de un lock abierto (sin gastar slots).
///  - Ronda 3: un lock se puede pasar a otra wallet en dos pasos (offerPosition -> acceptPosition). Lo
///    devengado hasta ese momento queda del que lo entrega; el que lo recibe gana desde la transferencia.
///    Eso habilita el PositionMarket (contrato aparte), que compra por el comprador con acceptPositionTo.
/// @dev Solvencia (NLYRA es a la vez stake y premio):
///  NLYRA.balance >= totalStaked + totalCooling + bonusReserve + (distributed - paid)[NLYRA] + tramos pendientes
///  WETH.balance  >=                                               (distributed - paid)[WETH]  + tramos pendientes
///  Los tramos solo reparten el saldo libre (saldo - deuda devengada - lo que falta pagar de los tramos).
///  Ademas de los 2 flujos de premio (WETH, NLYRA) se lleva la PARTE "elegible para bonus" de cada uno
///  (lo que vino del splitter), con el mismo motor: indices 2 y 3 de rate/rpb/rewards.
contract RealYieldStaking is Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ parametros
    uint256 public constant REWARD_DURATION = 7 days;
    uint256 public constant UNSTAKE_COOLDOWN = 2 days;
    uint256 public constant LOCK_7 = 7 days;
    uint256 public constant LOCK_14 = 14 days;
    uint256 public constant LOCK_30 = 30 days;
    uint256 public constant BPS = 10_000;
    uint256 public constant BOOST_FLEX = 10_000; // 1x
    uint256 public constant BOOST_7 = 12_500; // 1.25x
    uint256 public constant BOOST_14 = 15_000; // 1.5x
    uint256 public constant BOOST_30 = 20_000; // 2x
    uint256 public constant COMPOUND_BONUS_BPS = 500; // +5%, solo compound al lock de 30 dias
    uint256 public constant MAX_POSITIONS = 32; // locks ABIERTOS por wallet (los slots se reusan)
    uint256 public constant MAX_TRANCHES = 16;
    uint256 public constant MIN_NOTIFY_WETH = 1e12; // por debajo (en ambos tokens) no se abre tramo
    uint256 public constant MIN_NOTIFY_NLYRA = 1e18;
    uint256 public constant DONATION_INTERVAL = 1 days; // sweepDonations: como mucho 1 tramo por dia
    uint256 public constant MAX_PAUSE = 30 days; // la pausa vence sola
    uint256 public constant PAUSE_GAP = 30 days; // despues de una pausa, 30 dias abiertos antes de otra
    uint256 public constant NEW_POSITION = type(uint256).max; // compound: abrir un lock nuevo
    /// Uniswap v3 factory de Robinhood Chain y el hash del init code del pool (el canonico de v3-core,
    /// verificado contra los dos pools reales: CREATE2(factory, salt, hash) == pool).
    address public constant UNI_V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    bytes32 public constant POOL_INIT_CODE_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    uint24 public constant FEE_NLYRA_POOL = 10_000; // WETH/NLYRA 1%
    uint24 public constant FEE_USDG_POOL = 100; // WETH/USDG 0.01%
    uint256 private constant PRECISION = 1e36;
    uint160 private constant MIN_SQRT_RATIO_P1 = 4295128739 + 1;
    uint160 private constant MAX_SQRT_RATIO_M1 = 1461446703485210103287273052203988822378723970342 - 1;
    // storage transitorio del swap en curso
    uint256 private constant T_POOL = 0x4e4c5952415f504f4f4c; // pool esperado
    uint256 private constant T_TOKEN = 0x4e4c5952415f544f4b; // token de entrada
    uint256 private constant T_AMOUNT = 0x4e4c5952415f414d54; // monto exacto a pagar
    uint256 private constant T_DIR = 0x4e4c5952415f444952; // zeroForOne

    uint8 public constant TIER_FLEX = 0;
    uint8 public constant TIER_7 = 1;
    uint8 public constant TIER_14 = 2;
    uint8 public constant TIER_30 = 3;

    enum OutMode {
        AS_IS, // WETH + NLYRA como estan
        ALL_ETH, // todo en WETH (el NLYRA se vende en el pool WETH/NLYRA)
        ALL_NLYRA, // todo en NLYRA (el WETH compra NLYRA)
        ALL_USDG // todo en USDG (NLYRA -> WETH -> USDG)
    }

    // indices de los flujos: 0/1 premios, 2/3 la parte elegible para bonus de cada uno
    uint256 private constant I_WETH = 0;
    uint256 private constant I_NLYRA = 1;
    uint256 private constant E_WETH = 2;
    uint256 private constant E_NLYRA = 3;
    uint256 private constant FLOWS = 4;

    // ------------------------------------------------------------------ inmutables
    IERC20 public immutable NLYRA;
    IERC20 public immutable WETH;
    IERC20 public immutable USDG;
    address public immutable POOL_NLYRA; // Uniswap v3 WETH/NLYRA
    address public immutable POOL_USDG; // Uniswap v3 WETH/USDG
    bool private immutable WETH_T0_NLYRA_POOL;
    bool private immutable WETH_T0_USDG_POOL;
    address public immutable feeSplitter;

    // ------------------------------------------------------------------ estado de premios
    struct RewardState {
        uint256 rate; // suma de las tasas de los tramos activos (tokens por segundo)
        uint256 rewardPerBoosted; // acumulado * 1e36
        uint256 distributed; // total asignado a stakers (cota superior de lo reclamable)
        uint256 paid; // total ya pagado/compuesto
    }

    /// Parte elegible para bonus (lo que vino del splitter): solo tasa y acumulado.
    struct EligState {
        uint256 rate;
        uint256 rewardPerBoosted;
    }

    struct Tranche {
        uint96 rateWeth;
        uint96 rateNlyra;
        uint64 end;
        uint96 eligWeth; // parte de rateWeth que vino del splitter
        uint96 eligNlyra; // parte de rateNlyra que vino del splitter
    }

    RewardState[2] internal _reward; // 0 = WETH, 1 = NLYRA
    EligState[2] internal _elig; // 0 = WETH, 1 = NLYRA
    uint64 public lastUpdateTime;
    uint64 public periodFinish; // fin del tramo mas nuevo (solo informativo)
    uint32 internal _trHead;
    uint32 internal _trCount;
    uint64 public pausedUntil; // fin de la pausa vigente o de la ultima (tambien ancla el PAUSE_GAP)
    uint64 public lastDonationSweep; // ultimo tramo abierto por sweepDonations
    Tranche[16] internal _tranches; // cola circular, ordenada por fin

    // ------------------------------------------------------------------ estado de stakes
    struct Position {
        uint128 amount; // NLYRA (0 = slot libre)
        uint64 unlockTime; // medianoche UTC
        uint8 tier; // TIER_7 / TIER_14 / TIER_30 con boost; 0 = vencido y ya liquidado a 1x
    }

    struct Account {
        uint128 flexible; // stake flexible (1x)
        uint128 locked; // suma de locks abiertos (vencidos o no)
        uint128 boosted; // peso liquidado (los locks vencidos se bajan en la proxima accion)
        uint128 cooling; // en cooldown: NO gana premios
        uint64 cooldownEnd;
        uint64 nextExpiry; // cota inferior del proximo vencimiento con boost (0 = ninguno)
        uint64 recentDay; // dia UTC (timestamp / 1 dia) del balde recentCur (eligibleBalance)
        uint32 usedMask; // slots de posicion ocupados
        uint128 recentCur; // stake agregado en el dia recentDay
        uint128 recentPrev; // stake agregado en el dia recentDay - 1
    }

    uint256 public totalBoosted; // al lastUpdateTime
    uint256 public totalStaked; // flexible + locked (sin cooling)
    uint256 public totalCooling;
    uint256 public bonusReserve;

    /// medianoche UTC => peso extra (boost - 1x) de los locks que vencen ahi
    mapping(uint256 => uint256) public boostDrop;
    mapping(uint256 => uint256[4]) internal _rpbAt; // rewardPerBoosted (4 flujos) en esa medianoche
    mapping(address => Account) internal _accounts;
    mapping(address => Position[]) internal _positions;
    mapping(address => uint256[4]) internal _userRewardPerBoostedPaid;
    mapping(address => uint256[4]) internal _rewards; // [WETH, NLYRA, WETH elegible, NLYRA elegible]
    /// holder => id del lock => a quien se le ofrecio (0 = sin oferta). Se borra con cualquier cambio del
    /// lock (extendLock, compound a ese lock, withdrawLocked, transferencia): nunca queda colgada de un slot
    /// reusado ni de un lock distinto al que se ofrecio.
    mapping(address => mapping(uint256 => address)) public positionOffer;

    // ------------------------------------------------------------------ eventos / errores
    event Staked(address indexed user, uint256 amount, uint8 tier, uint256 positionId, uint64 unlockTime);
    event UnstakeRequested(address indexed user, uint256 amount, uint64 cooldownEnd);
    event UnstakeCancelled(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event LockReleased(address indexed user, uint256 positionId, uint256 amount);
    /// `added` = NLYRA sumado al lock (0 en extendLock, total + bonus en un compound a ese lock)
    event LockExtended(address indexed user, uint256 positionId, uint8 tier, uint64 unlockTime, uint256 added);
    event LockExpired(address indexed user, uint256 positionId);
    event Kicked(address indexed user, uint256 positionId, address indexed caller);
    event RewardsNotified(uint256 wethRate, uint256 nlyraRate, uint64 end, uint256 eligWethRate, uint256 eligNlyraRate);
    event NotifySkipped(uint256 wethFree, uint256 nlyraFree);
    event Claimed(
        address indexed user, address indexed recipient, OutMode mode, uint256 wethReward, uint256 nlyraReward,
        address tokenOut, uint256 amountOut
    );
    event Compounded(
        address indexed user,
        uint256 wethReward,
        uint256 nlyraReward,
        uint256 nlyraBought,
        uint256 bonus,
        uint8 tier,
        uint256 positionId
    );
    event BonusFunded(address indexed from, uint256 amount);
    event Recovered(address indexed token, address indexed to, uint256 amount);
    event Paused(uint64 until);
    event PositionOffered(address indexed from, uint256 indexed positionId, address indexed to);
    event PositionOfferCancelled(address indexed from, uint256 indexed positionId);
    /// `operator` = quien acepto (el destinatario, o el PositionMarket en una venta)
    event PositionTransferred(
        address indexed from,
        uint256 fromId,
        address indexed to,
        uint256 toId,
        uint256 amount,
        uint64 unlockTime,
        uint8 tier,
        address indexed operator
    );
    event Unpaused();

    error ZeroAmount();
    error ZeroAddress();
    error BadTier();
    error BadPool();
    error BadRecipient();
    error TooManyPositions();
    error InsufficientBalance();
    error CooldownActive(uint64 until);
    error NothingCooling();
    error StillLocked(uint64 until);
    error BadPosition();
    error AlreadyKicked();
    error CannotShorten();
    error OnlySplitter();
    error Slippage(uint256 out, uint256 minOut);
    error BadCallback();
    error PartialFill();
    error FeeOnTransfer();
    error NotRecoverable();
    error Overflow();
    error EnforcedPause();
    error NotPaused();
    error PauseCooldown(uint256 allowedAt);
    error TooSoon(uint256 allowedAt);
    error RenounceDisabled();
    error NotOffered();

    modifier whenNotPaused() {
        if (block.timestamp < pausedUntil) revert EnforcedPause();
        _;
    }

    /// @dev Ownable ya rechaza owner_ == 0 (OwnableInvalidOwner). El script de deploy chequea el resto.
    constructor(
        address owner_,
        address nlyra,
        address weth,
        address usdg,
        address poolNlyra,
        address poolUsdg,
        address locker,
        address treasury,
        uint256 splitBps,
        uint256 minHarvestInterval
    ) Ownable(owner_) {
        if (nlyra == address(0) || weth == address(0) || usdg == address(0)) revert ZeroAddress();
        NLYRA = IERC20(nlyra);
        WETH = IERC20(weth);
        USDG = IERC20(usdg);
        // cada pool tiene que ser un Uniswap v3 GENUINO del factory, del par y del fee tier esperados: su
        // direccion sale de CREATE2 con el init code canonico, asi que el codigo es el del pool real.
        WETH_T0_NLYRA_POOL = _checkPool(poolNlyra, weth, nlyra, FEE_NLYRA_POOL);
        WETH_T0_USDG_POOL = _checkPool(poolUsdg, weth, usdg, FEE_USDG_POOL);
        POOL_NLYRA = poolNlyra;
        POOL_USDG = poolUsdg;
        feeSplitter = address(
            new NlyraFeeSplitter(locker, nlyra, weth, address(this), treasury, splitBps, minHarvestInterval)
        );
        lastUpdateTime = uint64(block.timestamp);
        periodFinish = uint64(block.timestamp);
    }

    function _checkPool(address pool, address weth, address other, uint24 fee) private view returns (bool wethIsT0) {
        if (pool.code.length == 0) revert BadPool();
        (address t0, address t1) = weth < other ? (weth, other) : (other, weth);
        IUniswapV3PoolLike p = IUniswapV3PoolLike(pool);
        if (p.token0() != t0 || p.token1() != t1 || p.factory() != UNI_V3_FACTORY || p.fee() != fee) revert BadPool();
        bytes32 salt = keccak256(abi.encode(t0, t1, fee));
        bytes32 h = keccak256(abi.encodePacked(hex"ff", UNI_V3_FACTORY, salt, POOL_INIT_CODE_HASH));
        if (address(uint160(uint256(h))) != pool) revert BadPool();
        return t0 == weth;
    }

    // =================================================================== premios: nucleo

    /// @dev Foto en memoria del estado global, para avanzar el tiempo por tramos y medianoches.
    struct G {
        uint256 last;
        uint256 tb;
        uint256 head;
        uint256 count;
        uint256[4] rate;
        uint256[4] rpb;
        uint256[2] dist;
    }

    function _load() internal view returns (G memory g) {
        g.last = lastUpdateTime;
        g.tb = totalBoosted;
        g.head = _trHead;
        g.count = _trCount;
        for (uint256 i; i < 2; ++i) {
            RewardState storage r = _reward[i];
            g.rate[i] = r.rate;
            g.rpb[i] = r.rewardPerBoosted;
            g.dist[i] = r.distributed;
            EligState storage e = _elig[i];
            g.rate[i + 2] = e.rate;
            g.rpb[i + 2] = e.rewardPerBoosted;
        }
    }

    function _accrue(G memory g, uint256 dt) internal pure {
        if (dt == 0 || g.tb == 0) return; // sin stakers lo emitido no se asigna: vuelve en el proximo notify
        for (uint256 i; i < FLOWS; ++i) {
            if (g.rate[i] == 0) continue;
            uint256 d = (g.rate[i] * dt * PRECISION) / g.tb;
            g.rpb[i] += d;
            // redondeo para arriba: la suma de lo que cada uno cobra (para abajo) nunca lo supera
            if (i < 2) g.dist[i] += Math.mulDiv(d, g.tb, PRECISION, Math.Rounding.Ceil);
        }
    }

    /// @dev Avanza `g` hasta `to` en orden: fin de tramos (baja la tasa) y medianoches (baja el boost de
    ///      los locks que vencen). Devuelve true apenas aplica una baja de boost (g.last = esa medianoche),
    ///      para que quien escribe guarde el rewardPerBoosted de ese momento.
    function _advance(G memory g, uint256 to) internal view returns (bool dropped) {
        while (g.last < to) {
            uint256 next = (g.last / 1 days + 1) * 1 days;
            bool isDay = next <= to;
            if (!isDay) next = to;
            if (g.count != 0) {
                uint256 end = _tranches[g.head % MAX_TRANCHES].end;
                if (end < next) {
                    next = end;
                    isDay = false;
                }
            }
            if (next > g.last) _accrue(g, next - g.last);
            g.last = next;
            while (g.count != 0) {
                Tranche memory t = _tranches[g.head % MAX_TRANCHES];
                if (t.end > next) break;
                g.rate[I_WETH] -= t.rateWeth;
                g.rate[I_NLYRA] -= t.rateNlyra;
                g.rate[E_WETH] -= t.eligWeth;
                g.rate[E_NLYRA] -= t.eligNlyra;
                ++g.head;
                --g.count;
            }
            if (isDay) {
                uint256 drop = boostDrop[next];
                if (drop != 0) {
                    g.tb -= drop;
                    return true;
                }
            }
        }
    }

    function _sim(uint256 to) internal view returns (G memory g) {
        g = _load();
        while (_advance(g, to)) {}
    }

    function _updateGlobal() internal returns (G memory g) {
        g = _load();
        if (g.last == block.timestamp) return g;
        while (_advance(g, block.timestamp)) {
            _rpbAt[g.last] = g.rpb;
        }
        lastUpdateTime = uint64(g.last);
        _trHead = uint32(g.head);
        _trCount = uint32(g.count);
        totalBoosted = g.tb;
        for (uint256 i; i < 2; ++i) {
            RewardState storage r = _reward[i];
            r.rate = g.rate[i];
            r.rewardPerBoosted = g.rpb[i];
            r.distributed = g.dist[i];
            EligState storage e = _elig[i];
            e.rate = g.rate[i + 2];
            e.rewardPerBoosted = g.rpb[i + 2];
        }
    }

    /// @dev Liquida al usuario. Un lock vencido cobra con boost solo hasta su medianoche de vencimiento:
    ///      se descuenta extra * (rpb_ahora - rpb_al_vencer), exacto, y el peso se baja a 1x.
    function _update(address user) internal {
        G memory g = _updateGlobal();
        Account storage a = _accounts[user];
        uint256[4] storage paid = _userRewardPerBoostedPaid[user];
        uint256 b = a.boosted;
        uint256[4] memory num;
        for (uint256 i; i < FLOWS; ++i) num[i] = b * (g.rpb[i] - paid[i]);
        uint256 ne = a.nextExpiry;
        if (ne != 0 && ne <= block.timestamp) {
            (uint256 removed, uint256 next) = _demote(user, a.usedMask, g.rpb, num);
            a.boosted = uint128(b - removed);
            a.nextExpiry = uint64(next);
        }
        uint256[4] storage rw = _rewards[user];
        for (uint256 i; i < FLOWS; ++i) {
            if (num[i] != 0) rw[i] += num[i] / PRECISION;
            paid[i] = g.rpb[i];
        }
    }

    /// @dev Baja a 1x los locks vencidos del usuario y descuenta de `num` lo cobrado de mas desde su
    ///      vencimiento. Devuelve el peso quitado y el proximo vencimiento con boost (0 = ninguno).
    function _demote(address user, uint256 mask, uint256[4] memory rpb, uint256[4] memory num)
        internal
        returns (uint256 removed, uint256 next)
    {
        Position[] storage ps = _positions[user];
        for (uint256 i; mask != 0; ++i) {
            if (mask & 1 != 0) {
                Position storage p = ps[i];
                uint256 u = p.unlockTime;
                if (p.tier != 0) {
                    if (u <= block.timestamp) {
                        uint256 extra = _boosted(p.amount, p.tier) - p.amount;
                        uint256[4] storage at = _rpbAt[u];
                        for (uint256 k; k < FLOWS; ++k) num[k] -= extra * (rpb[k] - at[k]);
                        removed += extra;
                        p.tier = 0;
                        emit LockExpired(user, i);
                    } else if (next == 0 || u < next) {
                        next = u;
                    }
                }
            }
            mask >>= 1;
        }
    }

    /// @dev Saldo del contrato que pertenece a premios (asignados o por asignar).
    function _rewardBalance(uint256 i) internal view returns (uint256) {
        if (i == I_WETH) return WETH.balanceOf(address(this));
        return NLYRA.balanceOf(address(this)) - totalStaked - totalCooling - bonusReserve;
    }

    /// @dev Lo que los tramos de `g` todavia tienen que emitir desde `t`.
    function _pending(G memory g, uint256 t) internal view returns (uint256[2] memory p) {
        for (uint256 k; k < g.count; ++k) {
            Tranche storage tr = _tranches[(g.head + k) % MAX_TRANCHES];
            uint256 end = tr.end;
            if (end > t) {
                p[I_WETH] += uint256(tr.rateWeth) * (end - t);
                p[I_NLYRA] += uint256(tr.rateNlyra) * (end - t);
            }
        }
    }

    /// @notice Lo llama el splitter despues de transferir `wethIn`/`nlyraIn`. Abre un tramo nuevo de 7 dias
    ///         con TODO el saldo libre (lo nuevo + lo emitido sin stakers + donaciones directas); solo la
    ///         parte que mando el splitter cuenta para el bonus de compound.
    function notifyRewards(uint256 wethIn, uint256 nlyraIn) external nonReentrant {
        if (msg.sender != feeSplitter) revert OnlySplitter();
        _notify(wethIn, nlyraIn);
    }

    /// @notice Cualquiera: abre un tramo con el saldo libre (fees mandados directo al staking por el Desk,
    ///         OTC o bots, donaciones, lo emitido sin stakers). Como mucho un tramo por dia; con polvo no
    ///         abre nada ni consume el intervalo. Lo que entra por aca NO cuenta para el bonus de compound.
    function sweepDonations() external nonReentrant {
        uint256 next = uint256(lastDonationSweep) + DONATION_INTERVAL;
        if (block.timestamp < next) revert TooSoon(next);
        if (_notify(0, 0)) lastDonationSweep = uint64(block.timestamp);
    }

    /// @dev Tramo nuevo con el saldo libre. Los tramos que ya estaban siguen igual: nadie puede estirarlos.
    ///      Con polvo, o con la cola llena (imposible: <= 7 del splitter + <= 7 de sweepDonations), no abre.
    function _notify(uint256 wethIn, uint256 nlyraIn) internal returns (bool opened) {
        G memory g = _updateGlobal();
        uint256[2] memory pend = _pending(g, block.timestamp);
        uint256[2] memory add;
        for (uint256 i; i < 2; ++i) {
            uint256 used = g.dist[i] - _reward[i].paid + pend[i];
            uint256 bal = _rewardBalance(i);
            add[i] = bal > used ? bal - used : 0;
        }
        if ((add[I_WETH] < MIN_NOTIFY_WETH && add[I_NLYRA] < MIN_NOTIFY_NLYRA) || g.count == MAX_TRANCHES) {
            emit NotifySkipped(add[I_WETH], add[I_NLYRA]);
            return false;
        }
        uint256 end = block.timestamp + REWARD_DURATION;
        uint256 rw = Math.min(add[I_WETH] / REWARD_DURATION, type(uint96).max);
        uint256 rn = Math.min(add[I_NLYRA] / REWARD_DURATION, type(uint96).max);
        // la parte elegible nunca supera lo que realmente entra al tramo
        uint256 ew = Math.min(Math.min(wethIn, add[I_WETH]) / REWARD_DURATION, rw);
        uint256 en = Math.min(Math.min(nlyraIn, add[I_NLYRA]) / REWARD_DURATION, rn);
        _reward[I_WETH].rate = g.rate[I_WETH] + rw;
        _reward[I_NLYRA].rate = g.rate[I_NLYRA] + rn;
        _elig[I_WETH].rate = g.rate[E_WETH] + ew;
        _elig[I_NLYRA].rate = g.rate[E_NLYRA] + en;
        _tranches[(g.head + g.count) % MAX_TRANCHES] = Tranche(uint96(rw), uint96(rn), uint64(end), uint96(ew), uint96(en));
        _trCount = uint32(g.count + 1);
        periodFinish = uint64(end);
        emit RewardsNotified(rw, rn, uint64(end), ew, en);
        return true;
    }

    // =================================================================== stake / unstake

    function stake(uint256 amount) external nonReentrant whenNotPaused {
        _update(msg.sender);
        _addFlex(msg.sender, _pullNlyra(msg.sender, amount));
    }

    /// @param tier TIER_7 (1.25x), TIER_14 (1.5x) o TIER_30 (2x). Cada lock es una posicion aparte.
    function stakeLocked(uint256 amount, uint8 tier) external nonReentrant whenNotPaused {
        _checkLockTier(tier);
        _update(msg.sender);
        _openLock(msg.sender, _pullNlyra(msg.sender, amount), tier);
    }

    function _addFlex(address user, uint256 amt) internal {
        Account storage a = _accounts[user];
        a.flexible = _u128(a.flexible + amt);
        a.boosted = _u128(a.boosted + amt);
        totalBoosted += amt;
        totalStaked += amt;
        _markIncrease(a, amt);
        emit Staked(user, amt, TIER_FLEX, type(uint256).max, 0);
    }

    /// @dev Abre un lock en el primer slot libre (los ids de las posiciones abiertas no cambian nunca).
    function _openLock(address user, uint256 amt, uint8 tier) internal returns (uint256 id) {
        Account storage a = _accounts[user];
        uint64 unlock = _unlockFor(tier);
        id = _putPosition(user, a, Position(_u128(amt), unlock, tier));
        uint256 b = _boosted(amt, tier);
        a.locked = _u128(a.locked + amt);
        a.boosted = _u128(a.boosted + b);
        totalBoosted += b;
        totalStaked += amt;
        boostDrop[unlock] += b - amt;
        if (a.nextExpiry == 0 || unlock < a.nextExpiry) a.nextExpiry = unlock;
        _markIncrease(a, amt);
        emit Staked(user, amt, tier, id, unlock);
    }

    /// @dev Guarda `p` en el primer slot libre del usuario (tope MAX_POSITIONS abiertos) y devuelve su id.
    function _putPosition(address user, Account storage a, Position memory p) internal returns (uint256 id) {
        uint256 mask = a.usedMask;
        while (id < MAX_POSITIONS && (mask >> id) & 1 != 0) ++id;
        if (id == MAX_POSITIONS) revert TooManyPositions();
        Position[] storage ps = _positions[user];
        if (id == ps.length) ps.push(p);
        else ps[id] = p;
        a.usedMask = uint32(mask | (1 << id));
    }

    /// @dev Suma `amt` (puede ser 0) a un lock abierto y lo re-lockea desde ahora con `tier`. Reglas de
    ///      extend: un lock con boost solo pasa a un tier igual o mayor y nunca vence antes; uno vencido
    ///      (ya en 1x) acepta cualquier tier. Requiere _update(user) antes.
    function _addToLock(address user, uint256 id, uint256 amt, uint8 tier) internal {
        Position storage p = _openPosition(user, id);
        uint256 old = p.amount;
        uint256 oldTier = p.tier;
        uint64 unlock = _unlockFor(tier);
        if (oldTier != 0) {
            if (tier < oldTier || unlock < p.unlockTime) revert CannotShorten();
            boostDrop[p.unlockTime] -= _boosted(old, oldTier) - old;
        }
        uint256 newAmt = old + amt;
        uint256 oldB = _boosted(old, oldTier);
        uint256 newB = _boosted(newAmt, tier);
        Account storage a = _accounts[user];
        a.locked = _u128(a.locked + amt);
        a.boosted = _u128(a.boosted - oldB + newB);
        totalBoosted = totalBoosted - oldB + newB;
        totalStaked += amt;
        boostDrop[unlock] += newB - newAmt;
        p.amount = _u128(newAmt);
        p.unlockTime = unlock;
        p.tier = tier;
        if (a.nextExpiry == 0 || unlock < a.nextExpiry) a.nextExpiry = unlock;
        if (amt != 0) _markIncrease(a, amt);
        delete positionOffer[user][id]; // el lock cambio: una oferta vieja no vale para el lock nuevo
        emit LockExtended(user, id, tier, unlock, amt);
    }

    /// @notice Renueva un lock en el mismo slot, sin mover tokens: arranca de nuevo desde ahora con `tier`.
    ///         Solo al mismo tier o a uno mas largo, y nunca vence antes. Sirve tambien para un lock vencido.
    function extendLock(uint256 positionId, uint8 tier) external nonReentrant whenNotPaused {
        _checkLockTier(tier);
        _openPosition(msg.sender, positionId);
        _update(msg.sender); // si vencio, queda liquidado y en 1x (tier 0)
        _addToLock(msg.sender, positionId, 0, tier);
    }

    /// @notice Pasa `amount` del stake flexible a cooldown (deja de ganar). Si habia un cooldown ya
    ///         cumplido, ese monto se paga en el acto; si habia uno sin cumplir, se suma y el reloj reinicia.
    function requestUnstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _update(msg.sender);
        Account storage a = _accounts[msg.sender];
        if (amount > a.flexible) revert InsufficientBalance();
        a.flexible -= uint128(amount);
        a.boosted -= uint128(amount);
        totalBoosted -= amount;
        totalStaked -= amount;
        _startCooldown(msg.sender, a, amount);
    }

    /// @notice Libera un lock vencido: pasa al cooldown de 2 dias como el flexible y libera el slot.
    function withdrawLocked(uint256 positionId) external nonReentrant {
        Position storage p = _openPosition(msg.sender, positionId);
        if (block.timestamp < p.unlockTime) revert StillLocked(p.unlockTime);
        _update(msg.sender); // vencido => tier 0 (1x)
        uint256 amt = p.amount;
        Account storage a = _accounts[msg.sender];
        delete _positions[msg.sender][positionId];
        delete positionOffer[msg.sender][positionId]; // el slot se libera: la oferta muere con el lock
        a.usedMask &= ~uint32(1 << positionId);
        a.locked -= uint128(amt);
        a.boosted -= uint128(amt);
        totalBoosted -= amt;
        totalStaked -= amt;
        emit LockReleased(msg.sender, positionId, amt);
        _startCooldown(msg.sender, a, amt);
    }

    function _startCooldown(address user, Account storage a, uint256 amt) internal {
        uint256 matured;
        if (a.cooling != 0 && block.timestamp >= a.cooldownEnd) {
            matured = a.cooling;
            a.cooling = 0;
            totalCooling -= matured;
        }
        a.cooling = _u128(a.cooling + amt);
        a.cooldownEnd = uint64(block.timestamp + UNSTAKE_COOLDOWN);
        totalCooling += amt;
        emit UnstakeRequested(user, amt, a.cooldownEnd);
        if (matured != 0) {
            NLYRA.safeTransfer(user, matured);
            emit Withdrawn(user, matured);
        }
    }

    /// @notice Vuelve a stakear (flexible) todo lo que esta en cooldown.
    function cancelUnstake() external nonReentrant whenNotPaused {
        _update(msg.sender);
        Account storage a = _accounts[msg.sender];
        uint256 c = a.cooling;
        if (c == 0) revert NothingCooling();
        a.cooling = 0;
        a.cooldownEnd = 0;
        totalCooling -= c;
        a.flexible += uint128(c);
        a.boosted += uint128(c);
        totalStaked += c;
        totalBoosted += c;
        _markIncrease(a, c);
        emit UnstakeCancelled(msg.sender, c);
    }

    /// @notice Retira lo que termino el cooldown. Siempre al propio staker. Solo toca NLYRA (nunca WETH/USDG).
    function withdraw() external nonReentrant {
        Account storage a = _accounts[msg.sender];
        uint256 c = a.cooling;
        if (c == 0) revert NothingCooling();
        if (block.timestamp < a.cooldownEnd) revert CooldownActive(a.cooldownEnd);
        a.cooling = 0;
        a.cooldownEnd = 0;
        totalCooling -= c;
        NLYRA.safeTransfer(msg.sender, c);
        emit Withdrawn(msg.sender, c);
    }

    /// @notice Opcional: el boost de un lock vencido ya se apaga solo a la hora exacta (para el total y,
    ///         al liquidar, para el usuario). kick solo deja el storage del usuario al dia. No mueve fondos.
    function kick(address user, uint256 positionId) external nonReentrant {
        Position storage p = _openPosition(user, positionId);
        if (block.timestamp < p.unlockTime) revert StillLocked(p.unlockTime);
        if (p.tier == 0) revert AlreadyKicked();
        _update(user);
        emit Kicked(user, positionId, msg.sender);
    }

    function _openPosition(address user, uint256 id) internal view returns (Position storage p) {
        Position[] storage ps = _positions[user];
        if (id >= ps.length) revert BadPosition();
        p = ps[id];
        if (p.amount == 0) revert BadPosition();
    }

    // =================================================================== transferencia de locks (ronda 3)
    //
    // Dos pasos: el holder ofrece un lock a UNA direccion (offerPosition) y esa direccion lo acepta
    // (acceptPosition, o acceptPositionTo si es un operador como el PositionMarket). Reglas:
    //  - Se mueve el lock entero, tal cual: monto, vencimiento (unlockTime) y tier/peso. El peso total, el
    //    stake total y el boostDrop no cambian (el lock sigue existiendo y vence igual).
    //  - Premios: al aceptar se liquida a los dos. Lo devengado hasta ese segundo (incluida la parte elegible
    //    para bonus) queda acreditado al que entrega, que lo cobra con claim cuando quiera; el que recibe
    //    gana desde la transferencia en adelante. Nadie hereda premios ni elegibilidad ajena.
    //  - Un lock vencido tambien se puede pasar (llega en 1x, listo para withdrawLocked del que lo recibe):
    //    sirve para "stakear desde una wallet y retirar desde otra".
    //  - El cooldown es de la CUENTA, no del lock: withdrawLocked saca el monto del lock y libera el slot,
    //    asi que un lock con retiro pedido ya no existe y no se puede transferir. El cooling nunca viaja.
    //  - El que recibe usa su primer slot libre (tope de 32 abiertos: si esta lleno, revierte) y el id puede
    //    ser distinto. Para eligibleBalance el lock cuenta como aporte NUEVO del que recibe (queda afuera
    //    24-48 h): pasarse un lock no sirve para el descuento del Desk. Al que entrega le baja en el acto.
    //  - Pausa: ofrecer y aceptar quedan frenados; cancelar una oferta nunca.

    /// @notice Paso 1: ofrece el lock `positionId` a `to`. Reemplaza la oferta anterior de ese lock. La
    ///         oferta se borra sola si el lock cambia (extendLock, compound a ese lock, withdrawLocked).
    function offerPosition(uint256 positionId, address to) external whenNotPaused {
        _openPosition(msg.sender, positionId);
        _checkRecipient(to);
        if (to == msg.sender) revert BadRecipient();
        positionOffer[msg.sender][positionId] = to;
        emit PositionOffered(msg.sender, positionId, to);
    }

    /// @notice Retira la oferta de un lock. Anda tambien en pausa.
    function cancelPositionOffer(uint256 positionId) external {
        if (positionOffer[msg.sender][positionId] == address(0)) revert NotOffered();
        delete positionOffer[msg.sender][positionId];
        emit PositionOfferCancelled(msg.sender, positionId);
    }

    /// @notice Paso 2: el destinatario de la oferta se queda con el lock. Devuelve su id en la wallet nueva.
    function acceptPosition(address from, uint256 positionId) external nonReentrant whenNotPaused returns (uint256) {
        return _transferPosition(from, positionId, msg.sender);
    }

    /// @notice Paso 2 por un operador: el destinatario de la oferta (p.ej. el PositionMarket) entrega el lock
    ///         a `recipient`. Solo lo puede llamar aquel a quien el holder le ofrecio ESE lock.
    function acceptPositionTo(address from, uint256 positionId, address recipient)
        external
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        _checkRecipient(recipient);
        return _transferPosition(from, positionId, recipient);
    }

    function _checkRecipient(address to) internal view {
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this) || to == feeSplitter) revert BadRecipient();
    }

    /// @dev Mueve el lock `id` de `from` a `to` (primer slot libre). Liquida a los dos antes de mover el peso.
    function _transferPosition(address from, uint256 id, address to) internal returns (uint256 newId) {
        if (positionOffer[from][id] != msg.sender) revert NotOffered();
        if (to == from) revert BadRecipient();
        Position storage ps = _openPosition(from, id);
        delete positionOffer[from][id];
        _update(from); // lo devengado hasta ahora queda del que entrega (y un lock vencido baja a 1x aca)
        _update(to);
        Position memory p = ps;
        uint256 amt = p.amount;
        uint256 b = _boosted(amt, p.tier);
        Account storage af = _accounts[from];
        delete _positions[from][id];
        af.usedMask &= ~uint32(1 << id);
        af.locked -= uint128(amt);
        af.boosted -= uint128(b);
        // af.nextExpiry sigue siendo una cota inferior valida (a lo sumo sobra un recorrido de _demote)
        Account storage at = _accounts[to];
        newId = _putPosition(to, at, p);
        at.locked = _u128(at.locked + amt);
        at.boosted = _u128(at.boosted + b);
        if (p.tier != 0 && (at.nextExpiry == 0 || p.unlockTime < at.nextExpiry)) at.nextExpiry = p.unlockTime;
        _markIncrease(at, amt); // anti flash-transfer: para el Desk es stake nuevo del que recibe
        emit PositionTransferred(from, id, to, newId, amt, p.unlockTime, p.tier, msg.sender);
    }

    // =================================================================== claim / compound

    function claim(OutMode mode, uint256 minOut) external nonReentrant returns (uint256 amountOut) {
        return _claim(msg.sender, msg.sender, mode, minOut);
    }

    /// @notice Igual que claim pero el staker elige a quien le llega (p.ej. el escrow de un bot).
    function claimTo(address recipient, OutMode mode, uint256 minOut) external nonReentrant returns (uint256 amountOut) {
        if (recipient == address(0)) revert ZeroAddress();
        if (recipient == address(this) || recipient == feeSplitter) revert BadRecipient();
        return _claim(msg.sender, recipient, mode, minOut);
    }

    /// @dev Devuelve [WETH, NLYRA, WETH elegible, NLYRA elegible] y los deja en 0.
    function _takeRewards(address user) internal returns (uint256[4] memory r) {
        _update(user);
        uint256[4] storage rw = _rewards[user];
        for (uint256 i; i < FLOWS; ++i) {
            r[i] = rw[i];
            if (r[i] != 0) rw[i] = 0;
        }
        if (r[I_WETH] == 0 && r[I_NLYRA] == 0) revert ZeroAmount();
        _reward[I_WETH].paid += r[I_WETH];
        _reward[I_NLYRA].paid += r[I_NLYRA];
    }

    /// @dev AS_IS no convierte nada: minOut se ignora y amountOut = 0 (los montos van en el evento).
    ///      En los demas modos minOut es el piso del token de salida (WETH, NLYRA o USDG, 6 dec).
    function _claim(address user, address to, OutMode mode, uint256 minOut) internal returns (uint256 out) {
        uint256[4] memory r = _takeRewards(user);
        uint256 w = r[I_WETH];
        uint256 n = r[I_NLYRA];
        address tokenOut;
        if (mode == OutMode.AS_IS) {
            if (w != 0) WETH.safeTransfer(to, w);
            if (n != 0) NLYRA.safeTransfer(to, n);
            emit Claimed(user, to, mode, w, n, address(0), 0);
            return 0;
        } else if (mode == OutMode.ALL_ETH) {
            out = w + _sellNlyra(n);
            tokenOut = address(WETH);
        } else if (mode == OutMode.ALL_NLYRA) {
            out = n + _buyNlyra(w);
            tokenOut = address(NLYRA);
        } else {
            out = _swap(POOL_USDG, address(WETH), WETH_T0_USDG_POOL, w + _sellNlyra(n));
            tokenOut = address(USDG);
        }
        if (out < minOut) revert Slippage(out, minOut);
        if (out != 0) IERC20(tokenOut).safeTransfer(to, out);
        emit Claimed(user, to, mode, w, n, tokenOut, out);
    }

    /// @notice Compra NLYRA con el premio en WETH y lo suma todo al stake.
    ///  - tier = TIER_FLEX: al flexible, SIN bonus (positionId tiene que ser NEW_POSITION).
    ///  - tier = TIER_7 / TIER_14: a un lock (nuevo o existente), SIN bonus.
    ///  - tier = TIER_30: a un lock (nuevo o existente) con bonus de la reserva =
    ///    min(5% de lo compuesto que vino de fees del splitter, reserva). Donaciones: sin bonus.
    /// @param minOut piso de NLYRA compuesto SIN contar el bonus (premio NLYRA + comprado).
    /// @param positionId NEW_POSITION abre un lock nuevo; si no, suma a ese lock abierto y lo re-lockea
    ///        desde ahora con `tier` (mismas reglas que extendLock: tier igual o mayor, nunca vence antes).
    function compound(uint256 minOut, uint8 tier, uint256 positionId)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 added)
    {
        if (tier > TIER_30) revert BadTier();
        if (tier == TIER_FLEX && positionId != NEW_POSITION) revert BadPosition();
        uint256[4] memory r = _takeRewards(msg.sender);
        uint256 bought = _buyNlyra(r[I_WETH]);
        uint256 total = r[I_NLYRA] + bought;
        if (total < minOut) revert Slippage(total, minOut);
        if (total == 0) revert ZeroAmount();
        uint256 bonus;
        if (tier == TIER_30) bonus = _bonus(r, bought);
        added = total + bonus;
        if (tier == TIER_FLEX) _addFlex(msg.sender, added);
        else if (positionId == NEW_POSITION) positionId = _openLock(msg.sender, added, tier);
        else _addToLock(msg.sender, positionId, added, tier);
        emit Compounded(msg.sender, r[I_WETH], r[I_NLYRA], bought, bonus, tier, positionId);
    }

    /// @dev 5% de la parte elegible (NLYRA elegible + lo comprado con el WETH elegible), tope = reserva.
    function _bonus(uint256[4] memory r, uint256 bought) internal returns (uint256 bonus) {
        uint256 elig = Math.min(r[E_NLYRA], r[I_NLYRA]);
        if (r[I_WETH] != 0) elig += Math.mulDiv(bought, Math.min(r[E_WETH], r[I_WETH]), r[I_WETH]);
        bonus = Math.min((elig * COMPOUND_BONUS_BPS) / BPS, bonusReserve);
        if (bonus != 0) bonusReserve -= bonus;
    }

    /// @notice Cualquiera puede fondear la reserva del bonus de compound. Es de una sola via: solo sale
    ///         como bonus hacia locks de 30 dias. No acepta fondos con el contrato en pausa.
    function fundBonusReserve(uint256 amount) external nonReentrant whenNotPaused {
        uint256 received = _pullNlyra(msg.sender, amount);
        bonusReserve += received;
        emit BonusFunded(msg.sender, received);
    }

    // =================================================================== swaps (directo al pool v3)

    function _sellNlyra(uint256 amt) internal returns (uint256) {
        return _swap(POOL_NLYRA, address(NLYRA), !WETH_T0_NLYRA_POOL, amt);
    }

    function _buyNlyra(uint256 amt) internal returns (uint256) {
        return _swap(POOL_NLYRA, address(WETH), WETH_T0_NLYRA_POOL, amt);
    }

    /// @dev exactInput contra un pool inmutable; exige que se consuma todo el input (sin fills parciales).
    ///      El callback paga solo al pool en curso, solo el token de entrada y solo el monto exacto.
    function _swap(address pool, address tokenIn, bool zeroForOne, uint256 amountIn) internal returns (uint256 out) {
        if (amountIn == 0) return 0;
        if (amountIn > uint256(type(int256).max)) revert Overflow();
        assembly {
            tstore(T_POOL, pool)
            tstore(T_TOKEN, tokenIn)
            tstore(T_AMOUNT, amountIn)
            tstore(T_DIR, zeroForOne)
        }
        (int256 a0, int256 a1) = IUniswapV3PoolLike(pool).swap(
            address(this), zeroForOne, int256(amountIn), zeroForOne ? MIN_SQRT_RATIO_P1 : MAX_SQRT_RATIO_M1, ""
        );
        assembly {
            tstore(T_POOL, 0)
        }
        (int256 paidIn, int256 got) = zeroForOne ? (a0, a1) : (a1, a0);
        if (paidIn != int256(amountIn) || got > 0) revert PartialFill();
        out = uint256(-got);
    }

    /// @dev Un pool que pide MAS de lo acordado revierte con BadCallback; uno que pide menos (llenado
    ///      parcial por liquidez o limite de precio) revierte con PartialFill.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        address pool;
        address tokenIn;
        uint256 amountIn;
        bool zeroForOne;
        assembly {
            pool := tload(T_POOL)
            tokenIn := tload(T_TOKEN)
            amountIn := tload(T_AMOUNT)
            zeroForOne := tload(T_DIR)
        }
        if (pool == address(0) || msg.sender != pool) revert BadCallback();
        int256 owed = zeroForOne ? amount0Delta : amount1Delta;
        if (owed <= 0 || uint256(owed) > amountIn) revert BadCallback();
        if (uint256(owed) != amountIn) revert PartialFill();
        assembly {
            tstore(T_POOL, 0) // un solo pago por swap
        }
        IERC20(tokenIn).safeTransfer(pool, amountIn);
    }

    // =================================================================== owner (limitado)

    /// @notice Frena entradas nuevas (stake, locks, extend, compound, cancel, reserva) y las transferencias
    ///         de locks (ofrecer/aceptar, y por lo tanto las ventas del PositionMarket) por hasta 30 dias.
    ///         No se puede renovar: una pausa nueva recien 30 dias despues de que termino la anterior (por
    ///         vencimiento o unpause). Nunca frena claim, requestUnstake, withdrawLocked, withdraw ni kick.
    function pause() external onlyOwner {
        uint256 allowedAt = uint256(pausedUntil) + PAUSE_GAP;
        if (block.timestamp < allowedAt) revert PauseCooldown(allowedAt);
        pausedUntil = uint64(block.timestamp + MAX_PAUSE);
        emit Paused(pausedUntil);
    }

    function unpause() external onlyOwner {
        if (block.timestamp >= pausedUntil) revert NotPaused();
        pausedUntil = uint64(block.timestamp);
        emit Unpaused();
    }

    function paused() external view returns (bool) {
        return block.timestamp < pausedUntil;
    }

    /// @notice Deshabilitado: sin owner no se podria despausar antes de tiempo ni rescatar tokens ajenos.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @notice Rescata tokens AJENOS mandados por error. Nunca NLYRA ni WETH (principal y premios).
    function recoverERC20(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(NLYRA) || token == address(WETH)) revert NotRecoverable();
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Recovered(token, to, amount);
    }

    // =================================================================== helpers

    function _pullNlyra(address from, uint256 amount) internal returns (uint256 received) {
        if (amount == 0) revert ZeroAmount();
        uint256 b0 = NLYRA.balanceOf(address(this));
        NLYRA.safeTransferFrom(from, address(this), amount);
        received = NLYRA.balanceOf(address(this)) - b0;
        if (received != amount) revert FeeOnTransfer();
    }

    /// @dev Dos baldes por dia UTC: lo agregado el dia D queda fuera de eligibleBalance durante D y D+1
    ///      (entre 24 y 48 h), sin acumularse: aportes seguidos no reinician lo de dias anteriores.
    function _markIncrease(Account storage a, uint256 amt) internal {
        uint256 e = block.timestamp / 1 days;
        uint256 d = a.recentDay;
        if (e != d) {
            a.recentPrev = e == d + 1 ? a.recentCur : 0;
            a.recentCur = 0;
            a.recentDay = uint64(e);
        }
        a.recentCur = _u128(a.recentCur + amt);
    }

    function _checkLockTier(uint8 tier) internal pure {
        if (tier != TIER_7 && tier != TIER_14 && tier != TIER_30) revert BadTier();
    }

    function _boosted(uint256 amt, uint256 tier) internal pure returns (uint256) {
        uint256 boost = tier == TIER_30 ? BOOST_30 : tier == TIER_14 ? BOOST_14 : tier == TIER_7 ? BOOST_7 : BOOST_FLEX;
        return (amt * boost) / BPS;
    }

    /// @dev Vence a la medianoche UTC en o despues de ahora + duracion (asi las bajas de boost son por dia).
    function _unlockFor(uint256 tier) internal view returns (uint64) {
        uint256 t = block.timestamp + (tier == TIER_30 ? LOCK_30 : tier == TIER_14 ? LOCK_14 : LOCK_7);
        return uint64(Math.ceilDiv(t, 1 days) * 1 days);
    }

    function _u128(uint256 x) internal pure returns (uint128) {
        if (x > type(uint128).max) revert Overflow();
        return uint128(x);
    }

    // =================================================================== vistas

    function rewardPerBoosted(uint256 i) public view returns (uint256) {
        return _sim(block.timestamp).rpb[i];
    }

    function _rpbAtView(uint256 day) internal view returns (uint256[4] memory) {
        if (day <= lastUpdateTime) return _rpbAt[day];
        return _sim(day).rpb;
    }

    /// @dev [WETH, NLYRA, WETH elegible, NLYRA elegible] sin cobrar, con los locks vencidos liquidados.
    function _earned(address user) internal view returns (uint256[4] memory out) {
        G memory g = _sim(block.timestamp);
        Account storage a = _accounts[user];
        uint256[4] storage paid = _userRewardPerBoostedPaid[user];
        uint256[4] memory num;
        for (uint256 k; k < FLOWS; ++k) num[k] = uint256(a.boosted) * (g.rpb[k] - paid[k]);
        Position[] storage ps = _positions[user];
        for (uint256 i; i < ps.length; ++i) {
            Position memory p = ps[i];
            if (p.tier != 0 && p.amount != 0 && p.unlockTime <= block.timestamp) {
                uint256 extra = _boosted(p.amount, p.tier) - p.amount;
                uint256[4] memory at = _rpbAtView(p.unlockTime);
                for (uint256 k; k < FLOWS; ++k) num[k] -= extra * (g.rpb[k] - at[k]);
            }
        }
        uint256[4] storage rw = _rewards[user];
        for (uint256 k; k < FLOWS; ++k) out[k] = rw[k] + num[k] / PRECISION;
    }

    /// @notice Premios acumulados sin cobrar (con los locks vencidos liquidados a su vencimiento).
    function earned(address user) public view returns (uint256 wethAmt, uint256 nlyraAmt) {
        uint256[4] memory e = _earned(user);
        return (e[I_WETH], e[I_NLYRA]);
    }

    /// @notice De lo que devuelve earned(), la parte que vino de fees del splitter (base del bonus de
    ///         compound a 30 dias: 5% de esto, con lo WETH convertido a NLYRA al precio del compound).
    function earnedBonusEligible(address user) external view returns (uint256 wethAmt, uint256 nlyraAmt) {
        uint256[4] memory e = _earned(user);
        return (Math.min(e[E_WETH], e[I_WETH]), Math.min(e[E_NLYRA], e[I_NLYRA]));
    }

    /// @notice Insumos de APR: premio por segundo de cada token (suma de tramos activos) y el peso total.
    ///  APR(tier) = rate * 365d * precio_token / (totalBoosted * precio_NLYRA) * boost(tier)
    function rewardInfo()
        external
        view
        returns (
            uint256 wethRate,
            uint256 nlyraRate,
            uint256 finish,
            uint256 totalBoosted_,
            uint256 totalStaked_,
            uint256 totalCooling_,
            uint256 bonusReserve_
        )
    {
        G memory g = _sim(block.timestamp);
        return (g.rate[I_WETH], g.rate[I_NLYRA], periodFinish, g.tb, totalStaked, totalCooling, bonusReserve);
    }

    /// @notice Lo que el contrato debe hoy en premios (devengado sin cobrar + lo que falta emitir de los
    ///         tramos). Solvencia: WETH.balance >= weth; NLYRA.balance >= staked + cooling + reserva + nlyra.
    function committedRewards() external view returns (uint256 weth, uint256 nlyra) {
        G memory g = _sim(block.timestamp);
        uint256[2] memory p = _pending(g, block.timestamp);
        weth = g.dist[I_WETH] - _reward[I_WETH].paid + p[I_WETH];
        nlyra = g.dist[I_NLYRA] - _reward[I_NLYRA].paid + p[I_NLYRA];
    }

    /// @notice Tramos activos (tasa por segundo, fin, y la parte de la tasa elegible para bonus).
    function tranches() external view returns (Tranche[] memory out) {
        G memory g = _sim(block.timestamp);
        out = new Tranche[](g.count);
        for (uint256 k; k < g.count; ++k) out[k] = _tranches[(g.head + k) % MAX_TRANCHES];
    }

    /// @notice Contabilidad cruda de un token de premio (0 = WETH, 1 = NLYRA), al lastUpdateTime.
    function rewardState(uint256 i) external view returns (RewardState memory) {
        return _reward[i];
    }

    /// @notice positionCount = locks abiertos (los que ocupan slot)
    function userInfo(address user)
        external
        view
        returns (Account memory account, uint256 earnedWeth, uint256 earnedNlyra, uint256 positionCount)
    {
        account = _accounts[user];
        (earnedWeth, earnedNlyra) = earned(user);
        for (uint256 m = account.usedMask; m != 0; m >>= 1) positionCount += m & 1;
    }

    /// @notice Todas las posiciones (amount == 0 = slot libre que se va a reusar). El id es el indice.
    function positionsOf(address user) external view returns (Position[] memory) {
        return _positions[user];
    }

    /// @notice Un lock (amount == 0 = slot libre o id fuera de rango).
    function positionOf(address user, uint256 id) external view returns (Position memory p) {
        if (id < _positions[user].length) p = _positions[user][id];
    }

    /// @notice NLYRA stakeado y activo (flexible + locks, sin lo que esta en cooldown).
    function stakeOf(address user) external view returns (uint256) {
        Account storage a = _accounts[user];
        return uint256(a.flexible) + a.locked;
    }

    /// @notice Stake que el Desk puede usar para descuentos: el stake activo MENOS lo que entro hoy o ayer
    ///         (dia UTC) por stake, lock, compound o cancelUnstake. Todo aporte queda afuera entre 24 y 48 h y
    ///         despues cuenta, aunque haya aportes nuevos. Las bajas cuentan en el acto. Un flash-stake da 0.
    function eligibleBalance(address user) external view returns (uint256) {
        Account storage a = _accounts[user];
        uint256 active = uint256(a.flexible) + a.locked;
        uint256 e = block.timestamp / 1 days;
        uint256 d = a.recentDay;
        uint256 r = e == d ? uint256(a.recentCur) + a.recentPrev : e == d + 1 ? a.recentCur : 0;
        return active > r ? active - r : 0;
    }

    /// @notice Peso actual en los premios (los locks vencidos ya cuentan 1x).
    function boostedBalanceOf(address user) external view returns (uint256 b) {
        b = _accounts[user].boosted;
        Position[] storage ps = _positions[user];
        for (uint256 i; i < ps.length; ++i) {
            Position memory p = ps[i];
            if (p.tier != 0 && p.amount != 0 && p.unlockTime <= block.timestamp) b -= _boosted(p.amount, p.tier) - p.amount;
        }
    }
}

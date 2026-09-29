// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*  ArchitectPredict — BTC UP/DOWN en rondas de 5 minutos, para The Desk
    ---------------------------------------------------------------------------
    Patron PancakeSwap Prediction, con las garantias de los contratos del Desk:
    ownership en 2 pasos, pause, lock de reentrancia con TSTORE, pagos en ETH
    con techo de gas y fallback pendingEth, CEI en todos los caminos de plata.

    COMO CORRE
      Tres rondas vivas a la vez. Cada intervalo el operador (keeper) llama
      executeRound(), que en UNA sola lectura del oraculo:
        - cierra la ronda n-1 (closePrice)
        - lockea la ronda n     (lockPrice)   <- misma lectura, igual que Pancake
        - abre la ronda n+1
      La ronda n+1 acepta apuestas hasta su lockTs. Se apuesta sobre el FUTURO:
      cuando apostas, el precio de lock todavia no existe.

    EL ORACULO (leer PredictOracle.sol)
      Este contrato lee un AggregatorV3Interface y nada mas. Arranca apuntando a
      PredictOracle (compuesto BTC/USD acotado por Chainlink en cadena) porque el
      feed Chainlink CRUDO de esta chain se actualiza cada ~2.6 h de mediana
      (0.5% desviacion / 86400s heartbeat, medido on-chain 2026-08-23) y no puede
      liquidar rondas de 5 minutos: daria lockPrice == closePrice casi siempre.
      setOracle() apunta al feed crudo el dia que exista uno rapido.

    NUNCA LIQUIDA CON DATO PODRIDO
      Si en el momento de ejecutar el oraculo esta rancio (updatedAt mas viejo
      que oracleUpdateAllowance) o su roundId no avanzo, la ronda que iba a
      lockear y la que iba a cerrar se CANCELAN y quedan 100% reembolsables.
      Preferimos devolver la plata antes que inventar un resultado.

    SI EL KEEPER SE CAE
      _safeLockRound / _safeEndRound solo aceptan dentro de la ventana
      [ts, ts + bufferSeconds]. Pasado eso executeRound() revierte y el juego
      queda trabado a proposito: el operador hace pause() -> unpause() ->
      genesisStartRound() y arranca de nuevo. Las rondas que quedaron colgadas
      son reembolsables sin intervencion de nadie: refundable() devuelve true
      pasado closeTs + buffer sin oracleCalled. La plata de la gente NUNCA
      depende de que el keeper vuelva.

    FEE
      3% del pozo, cobrado SOLO cuando hay ganadores de verdad. Empate
      (closePrice == lockPrice) o lado ganador vacio => reembolso total, fee 0.
      El fee se acumula en treasuryAmount y se retira con claimTreasury() (pull).
      Referidos: 30% del fee que aporto cada apostador va a quien lo refirio,
      acumulado por epoch y reclamable con claimReferral().
*/

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IPushableOracle {
    function push(int256 answer) external returns (uint80);
}

contract ArchitectPredict {
    // ------------------------------ tipos ------------------------------

    enum Position { None, Bull, Bear }

    /// @dev Empaquetado en 5 slots. El orden de declaracion ES el layout, no reordenar a ciegas.
    struct Round {
        uint64  epoch;
        uint64  startTs;
        uint64  lockTs;
        uint64  closeTs;
        // ---- slot ----
        int64   lockPrice;        // 8 decimales, 0 hasta que lockea
        int64   closePrice;       // 8 decimales, 0 hasta que cierra
        uint80  lockOracleId;
        bool    oracleCalled;     // la ronda se liquido con precios reales
        bool    cancelled;        // la ronda murio: todo reembolsable
        // ---- slot ----
        uint80  closeOracleId;
        uint128 totalAmount;
        // ---- slot ----
        uint128 bullAmount;
        uint128 bearAmount;
        // ---- slot ----
        uint128 rewardBaseCalAmount;  // pozo del lado ganador (0 => empate/sin ganadores => reembolso)
        uint128 rewardAmount;         // total a repartir, ya neto de fee
    }

    struct BetInfo {
        Position position;
        uint128  amount;
        bool     claimed;
    }

    // ------------------------------ constantes ------------------------------

    uint256 public constant MAX_FEE_BPS      = 500;    // 5%, techo duro
    uint256 public constant MAX_REFERRAL_BPS = 5000;   // 50% del fee, techo duro
    uint256 internal constant BPS            = 10_000;
    uint256 internal constant MAX_CLAIM      = 128;    // epochs por claim(), corta el gas

    // ------------------------------ estado ------------------------------

    address public owner;
    address public pendingOwner;
    address public operator;          // el keeper: solo timea, nunca toca fondos
    address public treasury;
    bool    public paused;

    AggregatorV3Interface public oracle;

    uint256 public currentEpoch;
    uint64  public intervalSeconds        = 300;   // 5 minutos
    uint64  public bufferSeconds          = 30;
    uint64  public oracleUpdateAllowance  = 120;   // frescura exigida al oraculo
    uint128 public minBetAmount;
    uint16  public feeBps      = 300;              // 3%
    uint16  public referralBps = 3000;             // 30% del fee
    bool    public genesisStartOnce;
    bool    public genesisLockOnce;

    uint256 public treasuryAmount;                 // fee acumulado, pull
    uint80  public lastOracleRoundId;              // el roundId del ultimo settle, debe avanzar

    mapping(uint256 => Round) public rounds;
    mapping(uint256 => mapping(address => BetInfo)) public ledger;
    mapping(address => uint256[]) internal _userRounds;

    mapping(address => address) public referrerOf;                        // usuario => quien lo refirio (una sola vez)
    mapping(uint256 => mapping(address => uint256)) public referralOf;    // epoch => referrer => acumulado
    mapping(uint256 => uint256) public referralAccrued;                   // epoch => total referido (se resta del fee)
    mapping(address => uint256) public pendingEth;                        // pagos en ETH que rebotaron

    // ------------------------------ eventos ------------------------------

    event StartRound(uint256 indexed epoch, uint256 startTs, uint256 lockTs, uint256 closeTs);
    event LockRound(uint256 indexed epoch, uint256 indexed oracleId, int256 price);
    event EndRound(uint256 indexed epoch, uint256 indexed oracleId, int256 price);
    event CancelRound(uint256 indexed epoch, string reason);
    event RewardsCalculated(uint256 indexed epoch, uint256 rewardBaseCalAmount, uint256 rewardAmount, uint256 treasuryFee);
    event BetBull(address indexed sender, uint256 indexed epoch, uint256 amount, address referrer);
    event BetBear(address indexed sender, uint256 indexed epoch, uint256 amount, address referrer);
    event Claim(address indexed sender, uint256 indexed epoch, uint256 amount, bool refund);
    event ReferralAccrued(address indexed referrer, uint256 indexed epoch, address indexed better, uint256 amount);
    event ReferralClaimed(address indexed referrer, uint256 amount);
    event TreasuryClaimed(address indexed to, uint256 amount);
    event EthPending(address indexed to, uint256 amount);
    event EthWithdrawn(address indexed to, uint256 amount);
    event OperatorSet(address indexed operator);
    event TreasurySet(address indexed treasury);
    event OracleSet(address indexed oracle);
    event MinBetSet(uint256 amount);
    event FeeSet(uint16 feeBps, uint16 referralBps);
    event TimingSet(uint64 intervalSeconds, uint64 bufferSeconds, uint64 oracleUpdateAllowance);
    event PausedSet(bool paused);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    // ------------------------------ errores ------------------------------

    error NotOwner();
    error NotOperator();
    error ZeroAddress();
    error BadParam();
    error IsPaused();
    error NotPaused();
    error GenesisDone();
    error GenesisMissing();
    error RoundNotBettable();
    error BelowMinBet();
    error AlreadyBet();
    error RoundNotStarted();
    error RoundNotEnded();
    error NothingToClaim();
    error NotEligible();
    error TooManyEpochs();
    error TransferFailed();
    error OracleDown();
    error LockTooEarly();
    error LockTooLate();
    error CloseTooEarly();
    error CloseTooLate();
    error PrevRoundNotClosed();

    // ------------------------------ modifiers ------------------------------

    modifier onlyOwner()    { if (msg.sender != owner)    revert NotOwner();    _; }
    modifier onlyOperator() { if (msg.sender != operator) revert NotOperator(); _; }
    modifier whenNotPaused(){ if (paused) revert IsPaused(); _; }

    /// @dev guard de reentrancia transitorio (TSTORE, evmVersion cancun)
    modifier lock() {
        assembly ("memory-safe") { if tload(0) { mstore(0, 0) revert(0, 0) } tstore(0, 1) }
        _;
        assembly ("memory-safe") { tstore(0, 0) }
    }

    /// @param oracle_    AggregatorV3 con 8 decimales (PredictOracle o un feed Chainlink rapido)
    /// @param operator_  keeper que llama executeRound
    /// @param treasury_  destino del fee (pull con claimTreasury)
    /// @param minBet     apuesta minima en wei
    constructor(address oracle_, address operator_, address treasury_, uint128 minBet) {
        if (oracle_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (AggregatorV3Interface(oracle_).decimals() != 8) revert BadParam();
        if (minBet == 0) revert BadParam();
        owner        = msg.sender;
        oracle       = AggregatorV3Interface(oracle_);
        operator     = operator_;
        treasury     = treasury_;
        minBetAmount = minBet;
        emit OracleSet(oracle_);
        emit OperatorSet(operator_);
        emit TreasurySet(treasury_);
        emit MinBetSet(minBet);
    }

    /// @dev Nadie manda ETH suelto aca: entra por betBull/betBear o no entra.
    receive() external payable { revert BadParam(); }

    // ============================ apostar ============================

    /// @notice Apuesta a que BTC SUBE en esta ronda.
    function betBull(uint256 epoch) external payable { _bet(epoch, Position.Bull, address(0)); }

    /// @notice Apuesta a que BTC BAJA en esta ronda.
    function betBear(uint256 epoch) external payable { _bet(epoch, Position.Bear, address(0)); }

    /// @notice Igual que betBull, fijando quien te refirio (solo la primera vez que apostas).
    function betBull(uint256 epoch, address referrer) external payable { _bet(epoch, Position.Bull, referrer); }

    /// @notice Igual que betBear, fijando quien te refirio (solo la primera vez que apostas).
    function betBear(uint256 epoch, address referrer) external payable { _bet(epoch, Position.Bear, referrer); }

    function _bet(uint256 epoch, Position side, address referrer) internal lock whenNotPaused {
        if (epoch != currentEpoch) revert RoundNotBettable();
        if (!_bettable(epoch)) revert RoundNotBettable();
        uint256 amount = msg.value;
        if (amount < minBetAmount) revert BelowMinBet();
        if (amount > type(uint128).max) revert BadParam();

        BetInfo storage b = ledger[epoch][msg.sender];
        if (b.amount != 0) revert AlreadyBet();   // un solo lado por usuario por ronda

        Round storage r = rounds[epoch];
        r.totalAmount += uint128(amount);
        if (side == Position.Bull) r.bullAmount += uint128(amount);
        else                       r.bearAmount += uint128(amount);

        b.position = side;
        b.amount   = uint128(amount);
        _userRounds[msg.sender].push(epoch);

        _accrueReferral(epoch, msg.sender, referrer, amount);

        if (side == Position.Bull) emit BetBull(msg.sender, epoch, amount, referrerOf[msg.sender]);
        else                       emit BetBear(msg.sender, epoch, amount, referrerOf[msg.sender]);
    }

    /// @dev El referrer se fija UNA sola vez y nunca puede ser uno mismo.
    ///      Se acumula por epoch porque el fee solo se cobra si la ronda liquida
    ///      con ganadores: si termina en reembolso, no hubo fee y no hay comision.
    function _accrueReferral(uint256 epoch, address better, address referrer, uint256 amount) internal {
        address ref = referrerOf[better];
        if (ref == address(0) && referrer != address(0) && referrer != better) {
            ref = referrer;
            referrerOf[better] = ref;
        }
        if (ref == address(0)) return;
        uint256 cut = (amount * feeBps * referralBps) / (BPS * BPS);
        if (cut == 0) return;
        referralOf[epoch][ref] += cut;
        referralAccrued[epoch] += cut;
        emit ReferralAccrued(ref, epoch, better, cut);
    }

    // ============================ rondas ============================

    /// @notice Arranca la primera ronda. Una sola vez (o de nuevo tras un pause/unpause de recuperacion).
    function genesisStartRound() external onlyOperator whenNotPaused {
        if (genesisStartOnce) revert GenesisDone();
        currentEpoch = currentEpoch + 1;
        _startRound(currentEpoch);
        genesisStartOnce = true;
    }

    /// @notice Lockea la ronda genesis y abre la siguiente.
    function genesisLockRound() external onlyOperator whenNotPaused {
        if (!genesisStartOnce) revert GenesisMissing();
        if (genesisLockOnce) revert GenesisDone();

        (bool fresh, uint80 oracleId, int256 price) = _peekOracle();
        uint256 cur = currentEpoch;
        if (fresh) {
            _safeLockRound(cur, oracleId, price);
            lastOracleRoundId = oracleId;
        } else {
            _cancelRound(cur, "oracle stale at genesis lock");
        }
        currentEpoch = cur + 1;
        _startRound(currentEpoch);
        genesisLockOnce = true;
    }

    /// @notice El latido del juego: cierra n-1, lockea n, abre n+1. Una lectura de oraculo para las dos.
    function executeRound() external onlyOperator whenNotPaused { _executeRound(); }

    /// @notice Publica el precio en el PredictOracle y ejecuta la ronda en UNA sola tx.
    /// @dev Ahorra la mitad del gas del keeper. Requiere que este contrato sea pusher
    ///      del oraculo; si el oraculo es un feed Chainlink crudo esto revierte y el
    ///      keeper debe usar executeRound() a secas.
    function pushAndExecute(int256 answer) external onlyOperator whenNotPaused {
        IPushableOracle(address(oracle)).push(answer);
        _executeRound();
    }

    function _executeRound() internal {
        if (!genesisStartOnce || !genesisLockOnce) revert GenesisMissing();

        (bool fresh, uint80 oracleId, int256 price) = _peekOracle();
        uint256 cur = currentEpoch;

        if (fresh) {
            // el mismo precio cierra n-1 y lockea n, igual que Pancake.
            // Una ronda que nunca llego a lockear (cancelada por oraculo rancio
            // en el tick anterior) no se puede cerrar: se cancela y se sigue.
            // Sin esto, un solo tick con dato viejo trababa executeRound() para
            // siempre y el juego no volvia a arrancar nunca.
            Round storage prev = rounds[cur - 1];
            if (prev.cancelled || prev.lockOracleId == 0) {
                _cancelRound(cur - 1, "never locked");
            } else {
                _safeEndRound(cur - 1, oracleId, price);
                _calculateRewards(cur - 1);
            }
            _safeLockRound(cur, oracleId, price);
            lastOracleRoundId = oracleId;
        } else {
            // dato podrido: no inventamos resultado, cancelamos y devolvemos
            _cancelRound(cur - 1, "oracle stale at close");
            _cancelRound(cur,     "oracle stale at lock");
        }

        currentEpoch = cur + 1;
        _safeStartRound(currentEpoch);
    }

    function _startRound(uint256 epoch) internal {
        Round storage r = rounds[epoch];
        r.epoch   = uint64(epoch);
        r.startTs = uint64(block.timestamp);
        r.lockTs  = uint64(block.timestamp) + intervalSeconds;
        r.closeTs = uint64(block.timestamp) + intervalSeconds * 2;
        emit StartRound(epoch, r.startTs, r.lockTs, r.closeTs);
    }

    /// @dev Solo se abre n+1 si n-1 ya cerro de verdad. Evita que un keeper
    ///      desincronizado abra rondas encima de rondas sin liquidar.
    function _safeStartRound(uint256 epoch) internal {
        if (rounds[epoch - 2].closeTs == 0) revert PrevRoundNotClosed();
        if (block.timestamp < rounds[epoch - 2].closeTs) revert PrevRoundNotClosed();
        _startRound(epoch);
    }

    function _safeLockRound(uint256 epoch, uint80 oracleId, int256 price) internal {
        Round storage r = rounds[epoch];
        if (r.startTs == 0) revert RoundNotStarted();
        if (block.timestamp < r.lockTs) revert LockTooEarly();
        if (block.timestamp > uint256(r.lockTs) + bufferSeconds) revert LockTooLate();
        r.lockPrice    = int64(price);
        r.lockOracleId = oracleId;
        r.closeTs      = uint64(block.timestamp) + intervalSeconds;
        emit LockRound(epoch, oracleId, price);
    }

    function _safeEndRound(uint256 epoch, uint80 oracleId, int256 price) internal {
        Round storage r = rounds[epoch];
        if (r.lockTs == 0 || r.lockOracleId == 0) revert RoundNotStarted();
        if (block.timestamp < r.closeTs) revert CloseTooEarly();
        if (block.timestamp > uint256(r.closeTs) + bufferSeconds) revert CloseTooLate();
        r.closePrice    = int64(price);
        r.closeOracleId = oracleId;
        r.oracleCalled  = true;
        emit EndRound(epoch, oracleId, price);
    }

    /// @dev Cancelar es siempre seguro: la ronda queda 100% reembolsable y no paga fee.
    function _cancelRound(uint256 epoch, string memory reason) internal {
        Round storage r = rounds[epoch];
        if (r.startTs == 0 || r.cancelled || r.oracleCalled) return;
        r.cancelled = true;
        emit CancelRound(epoch, reason);
    }

    /// @dev Fee SOLO cuando gano un lado con plata adentro. Empate o lado ganador
    ///      vacio => rewardBaseCalAmount 0 => todos reembolsables, casa cobra 0.
    function _calculateRewards(uint256 epoch) internal {
        Round storage r = rounds[epoch];
        if (!r.oracleCalled || r.cancelled) return;
        if (r.rewardBaseCalAmount != 0 || r.rewardAmount != 0) return;

        uint256 total = r.totalAmount;
        uint256 base;
        uint256 reward;
        uint256 fee;

        if (r.closePrice > r.lockPrice && r.bullAmount > 0) {
            base   = r.bullAmount;
            fee    = (total * feeBps) / BPS;
            reward = total - fee;
        } else if (r.closePrice < r.lockPrice && r.bearAmount > 0) {
            base   = r.bearAmount;
            fee    = (total * feeBps) / BPS;
            reward = total - fee;
        } else {
            // empate exacto, o gano un lado sin apuestas: nadie cobra, todos recuperan
            base = 0; reward = 0; fee = 0;
        }

        r.rewardBaseCalAmount = uint128(base);
        r.rewardAmount        = uint128(reward);

        if (fee != 0) {
            // la parte de referidos ya esta reservada; la casa se lleva el resto
            uint256 refCut = referralAccrued[epoch];
            if (refCut > fee) refCut = fee;      // invariante: refCut <= fee * referralBps / BPS
            treasuryAmount += fee - refCut;
        }
        emit RewardsCalculated(epoch, base, reward, fee);
    }

    /// @dev Lee el oraculo y dice si sirve para liquidar. No revierte por dato
    ///      viejo: devuelve fresh=false y el que llama cancela la ronda.
    function _peekOracle() internal view returns (bool fresh, uint80 oracleId, int256 price) {
        try oracle.latestRoundData() returns (uint80 rid, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0 || answer > type(int64).max) return (false, rid, 0);
            if (updatedAt == 0) return (false, rid, answer);
            if (block.timestamp > updatedAt + oracleUpdateAllowance) return (false, rid, answer);
            if (rid <= lastOracleRoundId) return (false, rid, answer);   // el roundId tiene que avanzar
            return (true, rid, answer);
        } catch {
            return (false, 0, 0);
        }
    }

    // ============================ cobrar ============================

    /// @notice Cobra premios y/o reembolsos de varias rondas en una tx.
    function claim(uint256[] calldata epochs) external lock {
        uint256 n = epochs.length;
        if (n == 0) revert NothingToClaim();
        if (n > MAX_CLAIM) revert TooManyEpochs();

        uint256 reward;
        for (uint256 i = 0; i < n; i++) {
            uint256 epoch = epochs[i];
            Round storage r = rounds[epoch];
            if (r.startTs == 0) revert RoundNotStarted();

            BetInfo storage b = ledger[epoch][msg.sender];
            if (b.amount == 0 || b.claimed) revert NothingToClaim();

            uint256 add;
            bool isRefund;
            if (claimable(epoch, msg.sender)) {
                add = (uint256(b.amount) * r.rewardAmount) / r.rewardBaseCalAmount;
            } else if (refundable(epoch, msg.sender)) {
                add = b.amount;
                isRefund = true;
            } else {
                revert NotEligible();
            }

            b.claimed = true;          // CEI: marcado antes de sumar y pagar
            reward += add;
            emit Claim(msg.sender, epoch, add, isRefund);
        }

        if (reward == 0) revert NothingToClaim();
        _payEth(msg.sender, reward);
    }

    /// @notice El referido cobra su 30% del fee de las rondas que liquidaron con ganadores.
    function claimReferral(uint256[] calldata epochs) external lock {
        uint256 n = epochs.length;
        if (n == 0 || n > MAX_CLAIM) revert TooManyEpochs();
        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            uint256 epoch = epochs[i];
            uint256 amount = referralOf[epoch][msg.sender];
            if (amount == 0) continue;
            Round storage r = rounds[epoch];
            // solo se paga si esa ronda realmente cobro fee
            if (!r.oracleCalled || r.cancelled || r.rewardBaseCalAmount == 0) continue;
            referralOf[epoch][msg.sender] = 0;
            total += amount;
        }
        if (total == 0) revert NothingToClaim();
        emit ReferralClaimed(msg.sender, total);
        _payEth(msg.sender, total);
    }

    /// @notice Manda el fee acumulado al treasury. Pull: cualquiera puede gatillarlo,
    ///         siempre va al treasury, nunca a quien llama.
    function claimTreasury() external lock {
        uint256 amount = treasuryAmount;
        if (amount == 0) revert NothingToClaim();
        treasuryAmount = 0;
        emit TreasuryClaimed(treasury, amount);
        _payEth(treasury, amount);
    }

    /// @notice ETH que reboto (destinatario contrato con receive() caro).
    function withdrawEth() external lock returns (uint256 amount) {
        amount = pendingEth[msg.sender];
        if (amount == 0) revert NothingToClaim();
        pendingEth[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit EthWithdrawn(msg.sender, amount);
    }

    /// @dev Pago con techo de gas: un ganador contrato no puede trabar nada.
    function _payEth(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount, gas: 30_000}("");
        if (!ok) { pendingEth[to] += amount; emit EthPending(to, amount); }
    }

    // ============================ vistas ============================

    /// @notice true si el usuario gano esa ronda y todavia no cobro.
    function claimable(uint256 epoch, address user) public view returns (bool) {
        Round storage r = rounds[epoch];
        BetInfo storage b = ledger[epoch][user];
        if (b.amount == 0 || b.claimed) return false;
        if (r.cancelled || !r.oracleCalled) return false;
        if (r.rewardBaseCalAmount == 0) return false;   // empate/sin ganadores => camino reembolso
        return (r.closePrice > r.lockPrice && b.position == Position.Bull)
            || (r.closePrice < r.lockPrice && b.position == Position.Bear);
    }

    /// @notice true si al usuario le corresponde que le devuelvan la apuesta entera.
    /// @dev Incluye el caso "el keeper nunca volvio": pasado closeTs + buffer la
    ///      ronda ya no puede liquidarse nunca, asi que se vuelve reembolsable
    ///      sola. La plata no depende de que alguien la rescate.
    function refundable(uint256 epoch, address user) public view returns (bool) {
        Round storage r = rounds[epoch];
        BetInfo storage b = ledger[epoch][user];
        if (b.amount == 0 || b.claimed) return false;
        if (r.cancelled) return true;
        if (r.oracleCalled) return r.rewardBaseCalAmount == 0;          // empate o lado ganador vacio
        if (paused) return true;                                        // pausado con la ronda abierta
        return r.closeTs != 0 && block.timestamp > uint256(r.closeTs) + bufferSeconds;
    }

    /// @notice Rondas en las que apostó el usuario, paginado desde el final (mas nuevas primero).
    function getUserRounds(address user, uint256 cursor, uint256 size)
        external view
        returns (uint256[] memory epochs, BetInfo[] memory bets, uint256 nextCursor)
    {
        uint256 len = _userRounds[user].length;
        if (cursor >= len) return (new uint256[](0), new BetInfo[](0), len);
        uint256 n = size;
        if (n > len - cursor) n = len - cursor;
        epochs = new uint256[](n);
        bets   = new BetInfo[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 e = _userRounds[user][len - 1 - cursor - i];   // del mas nuevo al mas viejo
            epochs[i] = e;
            bets[i]   = ledger[e][user];
        }
        nextCursor = cursor + n;
    }

    function getUserRoundsLength(address user) external view returns (uint256) { return _userRounds[user].length; }

    /// @notice Multiplicadores de pago que veria la UI si cada lado ganara ahora (1e4 = 1.0000x).
    function multipliers(uint256 epoch) external view returns (uint256 bullMul, uint256 bearMul) {
        Round storage r = rounds[epoch];
        uint256 total = r.totalAmount;
        if (total == 0) return (0, 0);
        uint256 net = total - (total * feeBps) / BPS;
        bullMul = r.bullAmount == 0 ? 0 : (net * BPS) / r.bullAmount;
        bearMul = r.bearAmount == 0 ? 0 : (net * BPS) / r.bearAmount;
    }

    /// @notice true si la ronda acepta apuestas ahora mismo.
    function bettable(uint256 epoch) external view returns (bool) { return !paused && _bettable(epoch); }

    function _bettable(uint256 epoch) internal view returns (bool) {
        Round storage r = rounds[epoch];
        return r.startTs != 0
            && r.lockTs  != 0
            && !r.cancelled
            && !r.oracleCalled
            && block.timestamp > r.startTs
            && block.timestamp < r.lockTs;
    }

    /// @notice Lo que el oraculo dice ahora, y si serviria para liquidar en este instante.
    function oracleStatus()
        external view
        returns (uint80 roundId, int256 price, uint256 updatedAt, uint256 age, bool fresh)
    {
        (bool f, uint80 rid, int256 p) = _peekOracle();
        uint256 u;
        try oracle.latestRoundData() returns (uint80, int256, uint256, uint256 upd, uint80) { u = upd; } catch { u = 0; }
        return (rid, p, u, u == 0 ? 0 : (block.timestamp > u ? block.timestamp - u : 0), f);
    }

    // ============================ admin ============================

    function setOperator(address o) external onlyOwner {
        if (o == address(0)) revert ZeroAddress();
        operator = o;
        emit OperatorSet(o);
    }

    function setTreasury(address t) external onlyOwner {
        if (t == address(0)) revert ZeroAddress();
        treasury = t;
        emit TreasurySet(t);
    }

    function setOracle(address o) external onlyOwner {
        if (o == address(0)) revert ZeroAddress();
        if (AggregatorV3Interface(o).decimals() != 8) revert BadParam();
        oracle = AggregatorV3Interface(o);
        lastOracleRoundId = 0;      // el roundId del oraculo nuevo arranca su propia serie
        emit OracleSet(o);
    }

    function setMinBet(uint128 amount) external onlyOwner {
        if (amount == 0) revert BadParam();
        minBetAmount = amount;
        emit MinBetSet(amount);
    }

    /// @param fee_ bps de la casa, techo 5%. @param ref_ bps del fee al referido, techo 50%.
    /// @dev Solo con el juego pausado. referralAccrued[] se calcula con el feeBps
    ///      vigente AL APOSTAR: bajar el fee con rondas vivas dejaria comisiones de
    ///      referido por encima del fee realmente cobrado, comiendose el pozo.
    function setFee(uint16 fee_, uint16 ref_) external onlyOwner {
        if (!paused) revert NotPaused();
        if (fee_ > MAX_FEE_BPS || ref_ > MAX_REFERRAL_BPS) revert BadParam();
        feeBps = fee_;
        referralBps = ref_;
        emit FeeSet(fee_, ref_);
    }

    /// @dev Solo con el juego pausado: cambiar el intervalo con rondas vivas las desincroniza.
    function setTiming(uint64 interval_, uint64 buffer_, uint64 allowance_) external onlyOwner {
        if (!paused) revert NotPaused();
        if (interval_ < 60 || interval_ > 3600) revert BadParam();
        if (buffer_ == 0 || buffer_ >= interval_) revert BadParam();
        if (allowance_ == 0 || allowance_ > 3600) revert BadParam();
        intervalSeconds = interval_;
        bufferSeconds = buffer_;
        oracleUpdateAllowance = allowance_;
        emit TimingSet(interval_, buffer_, allowance_);
    }

    /// @notice Pausa el juego. Las rondas abiertas quedan reembolsables (refundable()).
    function pause() external onlyOwner {
        paused = true;
        emit PausedSet(true);
    }

    /// @notice Reanuda. Rearma el genesis: el keeper vuelve a llamar genesisStartRound().
    function unpause() external onlyOwner {
        paused = false;
        genesisStartOnce = false;
        genesisLockOnce  = false;
        emit PausedSet(false);
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

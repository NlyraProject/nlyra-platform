// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*  PredictOracle — adaptador AggregatorV3 para PREDICT, acotado por Chainlink
    ---------------------------------------------------------------------------
    POR QUE EXISTE

    Robinhood Chain tiene Chainlink Data Feeds vivos y BTC/USD responde:
        BTC / USD  0xa2c5184bF03d373Dc9dE4876eb4Bce595B460251  (8 decimales)

    Pero TODOS los feeds de esta chain estan configurados 0.5% desviacion /
    86400s heartbeat. Medido on-chain el 2026-08-23: la mediana entre rondas
    del feed BTC/USD es 9543 s (~2.6 h) y el mejor gap observado fue 660 s.

    Un juego de 5 minutos leyendo ese feed directo daria el MISMO precio en lock
    y en close en la enorme mayoria de las rondas -> todas empatadas, y
    cualquier chequeo de frescura razonable cancelaria todas. El feed crudo no
    puede liquidar un juego de 5 minutos. No es una opinion: es el dato.

    QUE HACE ESTE CONTRATO

    Publica un compuesto BTC/USD con la granularidad que el juego necesita, y lo
    ACOTA CONTRA CHAINLINK EN CADENA: un push que se aparte mas de
    maxDeviationBps del ultimo answer de Chainlink revierte. Chainlink sigue
    siendo el ancla de verdad; este adaptador solo aporta granularidad.

    El pusher (el keeper) NO puede imprimir un precio arbitrario: como mucho
    puede moverse dentro de la banda alrededor del ancla, y cada push queda
    registrado con su desviacion para auditarlo desde afuera.

    Interfaz identica a Chainlink (AggregatorV3Interface), asi que
    ArchitectPredict no sabe ni le importa cual de los dos esta leyendo:
    setOracle() apunta a este o al feed crudo el dia que la chain tenga un feed
    rapido, sin tocar el juego.
*/

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    function latestRoundData()
        external view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function getRoundData(uint80 _roundId)
        external view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

contract PredictOracle is AggregatorV3Interface {
    /// @notice Igual que los feeds USD de Chainlink en esta chain.
    uint8   public constant override decimals = 8;
    uint256 public constant override version  = 1;

    string  public override description = "BTC / USD (Desk Predict composite, Chainlink-bounded)";

    address public owner;
    address public pendingOwner;

    /// @notice Feed de Chainlink que acota cada push. Es el ancla de verdad.
    AggregatorV3Interface public anchor;

    /// @notice Desviacion maxima permitida contra el ancla, en bps. 1000 = 10%.
    /// @dev El ancla se mueve por desviacion 0.5%, asi que entre updates puede
    ///      quedar rezagada; la banda tiene que tolerar ese drift real de BTC.
    uint16 public maxDeviationBps = 1000;

    /// @notice Push minimo entre rondas, en segundos. Corta spam y limita el gasto de gas.
    uint32 public minPushInterval = 1;

    mapping(address => bool) public isPusher;

    struct Data { int192 answer; uint64 updatedAt; }
    uint80 public latestRound;
    mapping(uint80 => Data) internal _data;

    event Pushed(uint80 indexed roundId, int256 answer, int256 anchorAnswer, int256 deviationBps, uint256 updatedAt);
    event PusherSet(address indexed pusher, bool allowed);
    event AnchorSet(address indexed anchor);
    event MaxDeviationSet(uint16 bps);
    event MinPushIntervalSet(uint32 s);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOwner();
    error NotPusher();
    error ZeroAddress();
    error BadAnswer();
    error TooSoon();
    error OffAnchor(int256 answer, int256 anchorAnswer, int256 deviationBps, uint16 maxBps);
    error AnchorDown();
    error NoData();
    error BadParam();

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }

    /// @param anchor_ feed Chainlink BTC/USD de esta chain (8 decimales)
    /// @param pusher  primer pusher permitido (el keeper), puede ser address(0)
    constructor(address anchor_, address pusher) {
        if (anchor_ == address(0)) revert ZeroAddress();
        // el ancla tiene que hablar y tener nuestros mismos decimales, o la
        // comparacion de desviacion no significa nada
        if (AggregatorV3Interface(anchor_).decimals() != decimals) revert BadParam();
        anchor = AggregatorV3Interface(anchor_);
        owner = msg.sender;
        if (pusher != address(0)) { isPusher[pusher] = true; emit PusherSet(pusher, true); }
        emit AnchorSet(anchor_);
    }

    // ------------------------------ push ------------------------------

    /// @notice Publica un precio nuevo. Solo pushers, y solo dentro de la banda del ancla.
    /// @param answer precio BTC/USD con 8 decimales
    /// @return roundId la ronda recien escrita
    function push(int256 answer) external returns (uint80 roundId) {
        if (!isPusher[msg.sender]) revert NotPusher();
        if (answer <= 0 || answer > type(int192).max) revert BadAnswer();

        uint80 last = latestRound;
        if (last != 0 && block.timestamp < uint256(_data[last].updatedAt) + minPushInterval) revert TooSoon();

        // ── la banda: Chainlink manda ─────────────────────────────────────
        (, int256 aAns,, uint256 aUpd,) = anchor.latestRoundData();
        if (aAns <= 0 || aUpd == 0) revert AnchorDown();

        int256 diff = answer > aAns ? answer - aAns : aAns - answer;
        int256 devBps = (diff * 10_000) / aAns;
        if (devBps > int256(uint256(maxDeviationBps))) {
            revert OffAnchor(answer, aAns, devBps, maxDeviationBps);
        }

        roundId = last + 1;
        latestRound = roundId;
        _data[roundId] = Data({ answer: int192(answer), updatedAt: uint64(block.timestamp) });

        emit Pushed(roundId, answer, aAns, devBps, block.timestamp);
    }

    // ------------------------------ lectura (AggregatorV3) ------------------------------

    function latestRoundData()
        external view override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        roundId = latestRound;
        if (roundId == 0) revert NoData();
        Data storage d = _data[roundId];
        return (roundId, int256(d.answer), d.updatedAt, d.updatedAt, roundId);
    }

    function getRoundData(uint80 _roundId)
        external view override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        Data storage d = _data[_roundId];
        if (d.updatedAt == 0) revert NoData();
        return (_roundId, int256(d.answer), d.updatedAt, d.updatedAt, _roundId);
    }

    /// @notice Lo que dice el ancla ahora mismo, para auditar desde afuera sin dos llamadas.
    function anchorData()
        external view
        returns (uint80 roundId, int256 answer, uint256 updatedAt, uint256 age)
    {
        (uint80 r, int256 a,, uint256 u,) = anchor.latestRoundData();
        return (r, a, u, block.timestamp > u ? block.timestamp - u : 0);
    }

    // ------------------------------ admin ------------------------------

    function setPusher(address p, bool allowed) external onlyOwner {
        if (p == address(0)) revert ZeroAddress();
        isPusher[p] = allowed;
        emit PusherSet(p, allowed);
    }

    function setAnchor(address a) external onlyOwner {
        if (a == address(0)) revert ZeroAddress();
        if (AggregatorV3Interface(a).decimals() != decimals) revert BadParam();
        anchor = AggregatorV3Interface(a);
        emit AnchorSet(a);
    }

    /// @dev Techo duro de 20%: ni el owner puede abrir la banda hasta volverla decorativa.
    function setMaxDeviationBps(uint16 bps) external onlyOwner {
        if (bps == 0 || bps > 2000) revert BadParam();
        maxDeviationBps = bps;
        emit MaxDeviationSet(bps);
    }

    function setMinPushInterval(uint32 s) external onlyOwner {
        if (s > 300) revert BadParam();
        minPushInterval = s;
        emit MinPushIntervalSet(s);
    }

    function setDescription(string calldata d) external onlyOwner { description = d; }

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

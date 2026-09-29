// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReentrancyGuardTransient} from "oz/utils/ReentrancyGuardTransient.sol";
import {RealYieldStaking} from "./RealYieldStaking.sol";
import {NlyraFeeSplitter} from "./NlyraFeeSplitter.sol";

/// @title PositionMarket (ronda 3): mercado de locks de RealYieldStaking en ETH nativo
/// @notice El vendedor publica UN lock propio TODAVIA BLOQUEADO a un precio fijo en ETH; el comprador paga
///         y recibe el lock en la misma transaccion. Comision fija del 0,5% al NlyraFeeSplitter (que la
///         envuelve a WETH y la reparte 50/50 stakers/treasury en su proximo harvest); el resto es del
///         vendedor, que lo retira con withdrawProceeds (pull-payment).
/// @dev Como funciona la autorizacion: el vendedor tiene que ofrecerle ESE lock al mercado en el staking
///      (`staking.offerPosition(id, market)`) y publicarlo aca (`list`). No existe aprobacion general: el
///      mercado solo puede mover el lock que se le ofrecio, y solo dentro de `buy`, hacia quien paga.
///      Ademas cada publicacion guarda una foto del lock (monto, vencimiento, tier): si el vendedor lo
///      cambia (extendLock, compound a ese lock), lo transfiere, lo retira o retira la oferta, la
///      publicacion deja de poder comprarse. El comprador pasa el precio que vio (`expectedPrice`) y el id
///      de la publicacion, que cambia si el vendedor la vuelve a publicar: un cambio de precio de ultimo
///      momento nunca lo agarra.
///      Sin owner, sin setters, sin upgrade: la comision es una constante (50 bps). Nadie (ni el owner del
///      staking, ni quien deployo esto) puede sacar un lock publicado ni la plata de los vendedores.
///      Locks vencidos: NO se pueden publicar ni comprar (ya son liquidos: el dueno los retira con el
///      cooldown normal de 2 dias; venderlos seria vender NLYRA con otra envoltura). Un lock que vence
///      estando publicado queda sin poder comprarse automaticamente.
///      Premios: lo que el lock devengo hasta la venta es del vendedor (el staking se lo liquida al
///      transferir); el comprador gana desde la compra. El precio es solo por el lock.
contract PositionMarket is ReentrancyGuardTransient {
    uint256 public constant FEE_BPS = 50; // 0,5%, inmutable
    uint256 public constant BPS = 10_000;

    RealYieldStaking public immutable STAKING;
    /// NlyraFeeSplitter del staking (receive() acepta ETH; harvest() lo envuelve y lo reparte)
    address public immutable FEE_RECIPIENT;

    struct Listing {
        address seller;
        uint64 expiry; // la publicacion vale mientras block.timestamp < expiry
        uint32 positionId;
        uint128 price; // wei de ETH nativo
        uint128 amount; // foto del lock al publicar
        uint64 unlockTime;
        uint8 tier;
    }

    uint256 public nextListingId = 1; // 0 = ninguna
    mapping(uint256 => Listing) internal _listings;
    /// vendedor => id del lock => publicacion vigente (0 = ninguna). Publicar de nuevo reemplaza la anterior.
    mapping(address => mapping(uint256 => uint256)) public activeListing;
    /// ETH de ventas pendiente de retiro, por vendedor
    mapping(address => uint256) public proceeds;
    uint256 public totalProceeds;

    event Listed(
        uint256 indexed listingId,
        address indexed seller,
        uint256 indexed positionId,
        uint256 price,
        uint64 expiry,
        uint256 amount,
        uint64 unlockTime,
        uint8 tier
    );
    event ListingCancelled(uint256 indexed listingId, address indexed seller);
    event Sold(
        uint256 indexed listingId,
        address indexed seller,
        address indexed buyer,
        uint256 positionId,
        uint256 buyerPositionId,
        uint256 price,
        uint256 fee
    );
    event ProceedsWithdrawn(address indexed seller, address to, uint256 amount);
    event ExcessSwept(uint256 amount);

    error ZeroAddress();
    error BadStaking();
    error BadPrice();
    error BadExpiry();
    error NotLocked();
    error NotOfferedToMarket();
    error NotSeller();
    error NotListed();
    error ListingExpired();
    error PriceMismatch(uint256 price);
    error BadPayment();
    error PositionChanged();
    error NothingToWithdraw();
    error EthTransferFailed();

    constructor(address staking) {
        if (staking == address(0)) revert ZeroAddress();
        if (staking.code.length == 0) revert BadStaking();
        address splitter = RealYieldStaking(staking).feeSplitter();
        if (splitter == address(0) || NlyraFeeSplitter(payable(splitter)).STAKING() != staking) revert BadStaking();
        STAKING = RealYieldStaking(staking);
        FEE_RECIPIENT = splitter;
    }

    // =================================================================== vendedor

    /// @notice Publica el lock `positionId` (propio y todavia bloqueado) a `price` wei hasta `expiry`.
    ///         Antes hay que ofrecerselo al mercado en el staking: `staking.offerPosition(positionId, market)`.
    ///         Si ese lock ya estaba publicado, la publicacion anterior se cancela (su id deja de valer).
    function list(uint256 positionId, uint256 price, uint64 expiry) external nonReentrant returns (uint256 listingId) {
        if (price == 0 || price > type(uint128).max) revert BadPrice();
        if (expiry <= block.timestamp) revert BadExpiry();
        RealYieldStaking.Position memory p = STAKING.positionOf(msg.sender, positionId);
        if (p.amount == 0 || p.tier == 0 || p.unlockTime <= block.timestamp) revert NotLocked();
        if (STAKING.positionOffer(msg.sender, positionId) != address(this)) revert NotOfferedToMarket();
        uint256 old = activeListing[msg.sender][positionId];
        if (old != 0) {
            delete _listings[old];
            emit ListingCancelled(old, msg.sender);
        }
        listingId = nextListingId++;
        _listings[listingId] =
            Listing(msg.sender, expiry, uint32(positionId), uint128(price), p.amount, p.unlockTime, p.tier);
        activeListing[msg.sender][positionId] = listingId;
        emit Listed(listingId, msg.sender, positionId, price, expiry, p.amount, p.unlockTime, p.tier);
    }

    /// @notice Baja una publicacion propia. (La oferta en el staking se retira aparte, con
    ///         `staking.cancelPositionOffer(positionId)`; sin publicacion el mercado no la puede usar igual.)
    function cancel(uint256 listingId) external nonReentrant {
        Listing storage l = _listings[listingId];
        if (l.seller == address(0)) revert NotListed();
        if (l.seller != msg.sender) revert NotSeller();
        delete activeListing[msg.sender][l.positionId];
        delete _listings[listingId];
        emit ListingCancelled(listingId, msg.sender);
    }

    /// @notice Retira el ETH de las ventas a `to` (pull-payment: una venta nunca depende de que el vendedor
    ///         pueda recibir ETH).
    function withdrawProceeds(address to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amt = proceeds[msg.sender];
        if (amt == 0) revert NothingToWithdraw();
        proceeds[msg.sender] = 0;
        totalProceeds -= amt;
        emit ProceedsWithdrawn(msg.sender, to, amt);
        (bool ok,) = to.call{value: amt}("");
        if (!ok) revert EthTransferFailed();
    }

    // =================================================================== comprador

    /// @notice Compra la publicacion `listingId`. `msg.value` tiene que ser EXACTO el precio y
    ///         `expectedPrice` el precio que viste (si cambio, revierte). El lock llega a tu wallet (primer
    ///         slot libre; hace falta tener menos de 32 locks abiertos) con el mismo monto, vencimiento y
    ///         tier; ganas premios desde este momento. Devuelve el id del lock en tu wallet.
    function buy(uint256 listingId, uint256 expectedPrice) external payable nonReentrant returns (uint256 newId) {
        Listing memory l = _listings[listingId];
        if (l.seller == address(0)) revert NotListed();
        if (l.price != expectedPrice) revert PriceMismatch(l.price);
        if (msg.value != l.price) revert BadPayment();
        if (block.timestamp >= l.expiry) revert ListingExpired();
        _checkPosition(l);
        // efectos antes de cualquier llamada
        delete _listings[listingId];
        delete activeListing[l.seller][l.positionId];
        uint256 fee = (uint256(l.price) * FEE_BPS + BPS - 1) / BPS; // redondeo para arriba
        uint256 net = l.price - fee;
        proceeds[l.seller] += net;
        totalProceeds += net;
        // el staking exige que la oferta de ESE lock sea para este mercado (si no, NotOffered) y lo entrega
        // directo al comprador; liquida los premios del vendedor hasta ahora
        newId = STAKING.acceptPositionTo(l.seller, l.positionId, msg.sender);
        (bool ok,) = FEE_RECIPIENT.call{value: fee}("");
        if (!ok) revert EthTransferFailed();
        emit Sold(listingId, l.seller, msg.sender, l.positionId, newId, l.price, fee);
    }

    // =================================================================== mantenimiento

    /// @notice ETH que llego sin pasar por una venta (p.ej. forzado con selfdestruct) va al splitter:
    ///         nada queda trabado. Cualquiera puede llamarlo; los fondos de los vendedores no se tocan.
    function sweepExcess() external nonReentrant {
        uint256 excess = address(this).balance - totalProceeds;
        if (excess == 0) revert NothingToWithdraw();
        emit ExcessSwept(excess);
        (bool ok,) = FEE_RECIPIENT.call{value: excess}("");
        if (!ok) revert EthTransferFailed();
    }

    // =================================================================== vistas

    function getListing(uint256 listingId) external view returns (Listing memory) {
        return _listings[listingId];
    }

    /// @notice true si hoy se puede comprar (publicada, sin vencer, el lock igual que en la foto, todavia
    ///         bloqueado y ofrecido al mercado, y el staking sin pausa). No mira el cupo de 32 del comprador.
    function isBuyable(uint256 listingId) external view returns (bool) {
        Listing memory l = _listings[listingId];
        if (l.seller == address(0) || block.timestamp >= l.expiry || STAKING.paused()) return false;
        if (STAKING.positionOffer(l.seller, l.positionId) != address(this)) return false;
        RealYieldStaking.Position memory p = STAKING.positionOf(l.seller, l.positionId);
        return p.amount == l.amount && p.unlockTime == l.unlockTime && p.tier == l.tier
            && block.timestamp < p.unlockTime;
    }

    /// @notice Comision y neto para el vendedor de un precio dado.
    function quote(uint256 price) external pure returns (uint256 fee, uint256 sellerGets) {
        fee = (price * FEE_BPS + BPS - 1) / BPS;
        sellerGets = price - fee;
    }

    /// @dev El lock tiene que seguir exactamente como cuando se publico y todavia bloqueado.
    function _checkPosition(Listing memory l) internal view {
        RealYieldStaking.Position memory p = STAKING.positionOf(l.seller, l.positionId);
        if (p.amount != l.amount || p.unlockTime != l.unlockTime || p.tier != l.tier) revert PositionChanged();
        if (block.timestamp >= p.unlockTime) revert NotLocked();
    }
}

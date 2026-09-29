// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {RealYieldStaking} from "../src/RealYieldStaking.sol";
import {NlyraFeeSplitter} from "../src/NlyraFeeSplitter.sol";
import {PositionMarket} from "../src/PositionMarket.sol";
import {IPonsLaunchLocker} from "../src/interfaces/External.sol";

/// DEPLOY (NO EJECUTADO). Uso previsto, a mano por el dueno y despues de la auditoria:
///   1) EXPECTED_OWNER = la tesoreria (decision del dueno 28/9: "el dueno del contrato voy a ser yo, la treasury");
///   2) STAKING_OWNER=0x<la tesoreria> forge script script/Deploy.s.sol --rpc-url robin          # simulacion
///   3) ... --broadcast --ledger / --account <keystore>                                            # real
/// Nunca con una clave en texto plano en la linea de comandos.
/// El owner se escribe DIRECTO en el constructor (no hay acceptOwnership) y renounceOwnership esta
/// deshabilitado: un owner equivocado no tiene arreglo. Por eso, ANTES de transmitir, el script exige:
///   - EXPECTED_OWNER completado y STAKING_OWNER == EXPECTED_OWNER (dos fuentes que tienen que coincidir);
///   - chainid 4663 (Robinhood Chain);
///   - que el owner sea exactamente la tesoreria (EOA, con o sin delegate EIP-7702). Decision del dueno 28/9:
///     sin multisig. Riesgo aceptado: si se pierde o roban la clave de la tesoreria, el ladron controla la pausa
///     y los parametros del staking (NO puede tocar el principal de los stakers).
/// Ronda 3: en la misma corrida se deploya el PositionMarket (mercado de locks, sin owner, fee fija 0,5% al
/// splitter), cableado al staking; el splitter lo toma del propio staking. Post-deploy se verifica todo.
/// Despues del deploy, el TREASURY (deployer de NLYRA en Pons) firma:
///   PonsLaunchLocker(0x736D...7F35).setFeeRedirect(NLYRA, <feeSplitter>)
contract Deploy is Script {
    /// EL OWNER: la tesoreria de NLYRA (decision del dueno 28/9, sin multisig).
    address public constant EXPECTED_OWNER = 0xe30647793192D15BFA6E53aE8651368d332fe04C;

    uint256 constant CHAIN_ID = 4663;
    address constant NLYRA = 0xB9d3824149aD8ac984153CeEc91D5a2405d1FB95;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant POOL_NLYRA = 0x483C24d1e36Df01b650F1E9BEEB2a1c31C005C39; // WETH/NLYRA 1%
    address constant POOL_USDG = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca; // WETH/USDG 0.01%
    address constant LOCKER = 0x736D76699C26D0d966744cAe304C000d471f7F35;
    address constant TREASURY = 0xe30647793192D15BFA6E53aE8651368d332fe04C;
    uint256 constant SPLIT_BPS = 5_000; // 50% a stakers
    uint256 constant MIN_HARVEST_INTERVAL = 1 days;

    function run() external returns (RealYieldStaking st, NlyraFeeSplitter sp, PositionMarket mk) {
        return deploy(vm.envAddress("STAKING_OWNER"), EXPECTED_OWNER);
    }

    /// Separado de run() para poder simularlo en tests con otro `expected`.
    function deploy(address owner_, address expected)
        public
        returns (RealYieldStaking st, NlyraFeeSplitter sp, PositionMarket mk)
    {
        checkOwner(owner_, expected);
        console2.log("chainid", block.chainid);
        console2.log("owner (verificar: la tesoreria)", owner_);
        vm.startBroadcast();
        st = new RealYieldStaking(
            owner_, NLYRA, WETH, USDG, POOL_NLYRA, POOL_USDG, LOCKER, TREASURY, SPLIT_BPS, MIN_HARVEST_INTERVAL
        );
        mk = new PositionMarket(address(st));
        vm.stopBroadcast();
        sp = NlyraFeeSplitter(payable(st.feeSplitter()));
        console2.log("RealYieldStaking", address(st));
        console2.log("NlyraFeeSplitter", address(sp));
        console2.log("PositionMarket", address(mk));
        checkDeployed(st, sp, owner_);
        checkMarket(mk, st, sp);
    }

    function checkOwner(address owner_, address expected) public view {
        require(expected != address(0), "EXPECTED_OWNER sin completar");
        require(owner_ != address(0), "STAKING_OWNER = 0");
        require(owner_ == expected, "STAKING_OWNER != EXPECTED_OWNER");
        require(block.chainid == CHAIN_ID, "chainid != 4663");
        require(owner_ == TREASURY, "el owner tiene que ser la tesoreria");
        // la tesoreria es una EOA (hoy con delegate 7702 de MetaMask): se acepta sin codigo o con 0xef0100...
        bytes memory code = owner_.code;
        require(
            code.length == 0 || (code.length == 23 && code[0] == 0xef && code[1] == 0x01 && code[2] == 0x00),
            "owner con codigo de contrato: no es la tesoreria"
        );
    }

    /// Verificaciones post-deploy (lecturas): owner, pools, tokens, splitter.
    function checkDeployed(RealYieldStaking st, NlyraFeeSplitter sp, address owner_) public view {
        require(st.owner() == owner_ && st.pendingOwner() == address(0), "owner");
        require(!st.paused(), "pausado");
        require(address(st.NLYRA()) == NLYRA && address(st.WETH()) == WETH && address(st.USDG()) == USDG, "tokens");
        require(st.POOL_NLYRA() == POOL_NLYRA && st.POOL_USDG() == POOL_USDG, "pools");
        require(address(sp) == vm.computeCreateAddress(address(st), 1), "splitter");
        require(sp.STAKING() == address(st) && sp.TREASURY() == TREASURY && sp.SPLIT_BPS() == SPLIT_BPS, "split");
        require(address(sp.LOCKER()) == LOCKER && sp.MIN_HARVEST_INTERVAL() == MIN_HARVEST_INTERVAL, "locker");
        require(address(sp.NLYRA()) == NLYRA && address(sp.WETH()) == WETH, "splitter tokens");
        // el redirect lo firma despues el treasury: recien ahi feeRedirects(NLYRA) == splitter
        console2.log("feeRedirects(NLYRA) hoy", IPonsLaunchLocker(LOCKER).feeRedirects(NLYRA));
    }

    /// Verificaciones post-deploy del mercado: cableado al staking y al splitter, fee 50 bps, vacio.
    function checkMarket(PositionMarket mk, RealYieldStaking st, NlyraFeeSplitter sp) public view {
        require(address(mk).code.length > 0, "market sin codigo");
        require(address(mk.STAKING()) == address(st), "market: staking");
        require(mk.FEE_RECIPIENT() == address(sp) && sp.STAKING() == address(st), "market: fee al splitter");
        require(mk.FEE_BPS() == 50 && mk.BPS() == 10_000, "market: fee 0,5%");
        require(mk.nextListingId() == 1 && mk.totalProceeds() == 0 && address(mk).balance == 0, "market: no vacio");
        (uint256 fee, uint256 net) = mk.quote(1 ether);
        require(fee == 0.005 ether && net == 0.995 ether, "market: quote");
    }
}

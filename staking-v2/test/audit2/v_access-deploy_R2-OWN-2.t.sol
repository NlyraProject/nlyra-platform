// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {RealYieldStaking} from "../../src/RealYieldStaking.sol";
import {PositionMarket} from "../../src/PositionMarket.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {MLocker, MToken} from "./inv2_stateful_local.t.sol";

contract MockPoolOwn2 {
    address public factory = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address public token0;
    address public token1;
    uint24 public fee;
    function set(address a, address b, uint24 f) external { token0 = a; token1 = b; fee = f; }
}

/// REGRESION R2-OWN-2 / hallazgo F (local, sin fork: pools y locker mock en sus direcciones reales).
/// Antes: el script aceptaba un typo de 1 bit, cualquier chainid y un owner EOA/7702, y era permanente.
/// Ahora el script exige EXPECTED_OWNER completado == STAKING_OWNER, chainid 4663 y (decision del dueno del
/// 28/9, ronda 3) que el owner sea EXACTAMENTE la tesoreria: sin codigo o con delegate 7702. Cualquier otra
/// direccion, o la tesoreria con codigo de contrato normal, se rechaza. Todo ANTES de transmitir.
contract V_R2_OWN_2 is Test {
    address constant NLYRA = 0xB9d3824149aD8ac984153CeEc91D5a2405d1FB95;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant POOL_NLYRA = 0x483C24d1e36Df01b650F1E9BEEB2a1c31C005C39;
    address constant POOL_USDG = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    address constant LOCKER = 0x736D76699C26D0d966744cAe304C000d471f7F35;

    function setUp() public {
        vm.warp(1_790_000_000); // timestamp realista (la primera pausa exige now >= 30 dias)
        address impl = address(new MockPoolOwn2());
        vm.etch(POOL_NLYRA, impl.code);
        vm.etch(POOL_USDG, impl.code);
        (address a, address b) = WETH < NLYRA ? (WETH, NLYRA) : (NLYRA, WETH);
        MockPoolOwn2(POOL_NLYRA).set(a, b, 10000);
        (a, b) = WETH < USDG ? (WETH, USDG) : (USDG, WETH);
        MockPoolOwn2(POOL_USDG).set(a, b, 100);
        vm.store(POOL_NLYRA, bytes32(uint256(0)), bytes32(uint256(uint160(0x1f7d7550B1b028f7571E69A784071F0205FD2EfA))));
        vm.store(POOL_USDG, bytes32(uint256(0)), bytes32(uint256(uint160(0x1f7d7550B1b028f7571E69A784071F0205FD2EfA))));
        // locker mock (el splitter exige codigo; checkDeployed lee feeRedirects)
        MLocker l = new MLocker(MToken(WETH), MToken(NLYRA));
        vm.etch(LOCKER, address(l).code);
    }

    address constant TREASURY = 0xe30647793192D15BFA6E53aE8651368d332fe04C;

    function test_scriptRejectsTypo_wrongChain_otherOwners_contractCode() public {
        address safe = makeAddr("multisig");
        vm.etch(safe, hex"6080604052"); // un "Safe" (tiene codigo): ya no es el owner decidido
        Deploy d = new Deploy();
        assertEq(d.EXPECTED_OWNER(), TREASURY, "la constante es la tesoreria");

        // run() con otro STAKING_OWNER: no deploya
        vm.chainId(4663);
        vm.setEnv("STAKING_OWNER", vm.toString(safe));
        vm.expectRevert(bytes("STAKING_OWNER != EXPECTED_OWNER"));
        d.run();

        // otra cadena (31337)
        vm.chainId(31337);
        vm.expectRevert(bytes("chainid != 4663"));
        d.deploy(TREASURY, TREASURY);
        vm.chainId(4663);

        // typo de 1 bit contra lo esperado
        address typo = address(uint160(TREASURY) ^ 1);
        vm.expectRevert(bytes("STAKING_OWNER != EXPECTED_OWNER"));
        d.deploy(typo, TREASURY);

        // aunque "lo esperado" tambien sea otra direccion: EOA, Safe o EOA delegada no pasan
        vm.expectRevert(bytes("el owner tiene que ser la tesoreria"));
        d.deploy(typo, typo);
        vm.expectRevert(bytes("el owner tiene que ser la tesoreria"));
        d.deploy(safe, safe);
        address del = makeAddr("delegated");
        vm.etch(del, abi.encodePacked(hex"ef0100", address(0xBEEF)));
        vm.expectRevert(bytes("el owner tiene que ser la tesoreria"));
        d.deploy(del, del);

        // la tesoreria con codigo de contrato normal: rechazada
        vm.etch(TREASURY, hex"6080604052");
        vm.expectRevert(bytes("owner con codigo de contrato: no es la tesoreria"));
        d.deploy(TREASURY, TREASURY);

        // la tesoreria SIN codigo: deploya (staking + splitter + mercado, todo cableado)
        vm.etch(TREASURY, "");
        (RealYieldStaking s1,, PositionMarket m1) = d.deploy(TREASURY, TREASURY);
        assertEq(s1.owner(), TREASURY);
        assertEq(address(m1.STAKING()), address(s1));
        assertEq(m1.FEE_RECIPIENT(), s1.feeSplitter());

        // la tesoreria CON delegate 7702 (como hoy, MetaMask): deploya, tambien via run()
        vm.etch(TREASURY, abi.encodePacked(hex"ef0100", address(0xBEEF)));
        vm.setEnv("STAKING_OWNER", vm.toString(TREASURY));
        (RealYieldStaking s2,, PositionMarket m2) = d.run();
        assertEq(s2.owner(), TREASURY);
        assertEq(address(m2.STAKING()), address(s2));
        vm.prank(TREASURY);
        s2.pause(); // el owner correcto controla la pausa
    }
}

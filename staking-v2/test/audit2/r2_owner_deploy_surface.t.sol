// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ForkBase} from "../ForkBase.sol";
import {RealYieldStaking} from "../../src/RealYieldStaking.sol";
import {NlyraFeeSplitter} from "../../src/NlyraFeeSplitter.sol";
import {PositionMarket} from "../../src/PositionMarket.sol";
import {Deploy} from "../../script/Deploy.s.sol";

/// Ronda 2 (owner / deploy), en el fork (chainid 4663). Nada se transmite.
///  - Hallazgo B (regresion): la pausa no se puede renovar; entre pausas hay >= 30 dias abiertos.
///  - Hallazgo F (regresion, actualizada en la ronda 3 por decision del dueno del 28/9: owner = tesoreria
///    EOA, sin multisig): el script exige EXPECTED_OWNER == STAKING_OWNER, chainid 4663 y que el owner sea
///    EXACTAMENTE la tesoreria, sin codigo o con delegate 7702 (0xef0100...); cualquier otra direccion, o la
///    tesoreria con codigo de contrato normal, se rechaza. El constructor rechaza owner 0.
contract R2OwnerDeploySurface is ForkBase {
    function setUp() public override {
        super.setUp();
        vm.coinbase(address(this)); // the sequencer account was not served by the development RPC
    }

    /// Antes: el owner renovaba la pausa cada 29 dias y nunca habia ventana de entrada. Ahora: en 1 ano de
    /// intentos, cada vez que la pausa termina hay 30 dias en los que se puede stakear y componer.
    function test_pause_notRenewable_entryWindowsAlwaysOpen() public {
        _stake(alice, 1e24, 3);
        _fund(dave, 1_000e18);
        vm.prank(owner);
        st.pause();
        uint64 firstUntil = st.pausedUntil();
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RealYieldStaking.PauseCooldown.selector, uint256(firstUntil) + 30 days));
        st.pause();
        assertEq(st.pausedUntil(), firstUntil, "no se renovo");

        _giveNlyra(carol, 1e24);
        vm.prank(carol);
        NLYRA.approve(address(st), 1e24);
        uint256 openDays;
        for (uint256 d; d < 365; ++d) {
            vm.warp(vm.getBlockTimestamp() + 1 days);
            // el owner intenta pausar todos los dias
            vm.prank(owner);
            try st.pause() {} catch {}
            if (!st.paused()) ++openDays;
        }
        emit log_named_uint("dias abiertos en 1 ano (owner hostil)", openDays);
        assertGe(openDays, 175, "~la mitad del tiempo abierto (30 de cada 60 dias)");
        // ... y en una ventana abierta se puede entrar y componer (la reserva no queda congelada)
        while (st.paused()) vm.warp(vm.getBlockTimestamp() + 1 days);
        _resetOracle();
        _tradeAndHarvest();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        if (st.paused()) vm.warp(st.pausedUntil());
        vm.prank(carol);
        st.stake(1e24);
        vm.prank(alice);
        st.compound(0, 3, 0);
        assertLt(st.bonusReserve(), 1_000e18, "la reserva sale");
    }

    /// El constructor sigue aceptando cualquier owner != 0 (la defensa esta en el script): un typo es
    /// definitivo, por eso el script ahora lo frena antes de transmitir.
    function test_ownerTypo_isPermanent_ifScriptBypassed() public {
        address typo = address(0xdead);
        _touchCreates(address(this));
        RealYieldStaking s2 = new RealYieldStaking(
            typo, address(NLYRA), address(WETH), address(USDG), POOL_NLYRA, POOL_USDG, address(LOCKER), TREASURY,
            5_000, 1 days
        );
        assertEq(s2.owner(), typo);
        assertEq(s2.pendingOwner(), address(0));
        vm.expectRevert();
        s2.transferOwnership(owner);
    }

    /// the development RPC 403'd on uncached accounts: pre-touch the next CREATE addresses (and their nonce-1 child)
    function _touchCreates(address deployer) internal {
        uint64 n = vm.getNonce(deployer);
        for (uint64 k; k < 3; ++k) {
            address a = vm.computeCreateAddress(deployer, n + k);
            vm.deal(a, 0);
            vm.deal(vm.computeCreateAddress(a, 1), 0);
        }
    }

    /// Script real contra el fork (simulacion, sin broadcast): con owner = tesoreria (como este en el bloque
    /// fijo, con o sin delegate 7702) deploya staking + splitter + PositionMarket y deja todo cableado.
    /// run() con otro STAKING_OWNER no deploya.
    function test_deployScript_simulation() public {
        Deploy d = new Deploy();
        _touchCreates(tx.origin);
        _touchCreates(address(d));
        (RealYieldStaking s2, NlyraFeeSplitter sp2, PositionMarket mk2) = d.deploy(TREASURY, TREASURY);
        assertEq(s2.owner(), TREASURY);
        assertFalse(s2.paused());
        assertEq(sp2.STAKING(), address(s2));
        assertEq(address(sp2), vm.computeCreateAddress(address(s2), 1));
        assertEq(address(mk2.STAKING()), address(s2));
        assertEq(mk2.FEE_RECIPIENT(), address(sp2));
        // el treasury firma el redirect y queda apuntando al splitter
        vm.prank(TREASURY);
        LOCKER.setFeeRedirect(address(NLYRA), address(sp2));
        assertEq(LOCKER.feeRedirects(address(NLYRA)), address(sp2));
        // run() con un STAKING_OWNER que no es la constante: no deploya
        vm.setEnv("STAKING_OWNER", vm.toString(owner));
        vm.expectRevert(bytes("STAKING_OWNER != EXPECTED_OWNER"));
        d.run();
    }

    /// Regla nueva (ronda 3): la tesoreria se acepta sin codigo y con delegate 7702; cualquier otra
    /// direccion (EOA, Safe o delegada) se rechaza; la tesoreria con codigo de contrato normal tambien.
    function test_deployScript_rejectsBadOwners() public {
        Deploy d = new Deploy();
        assertEq(d.EXPECTED_OWNER(), TREASURY);
        // typo de 1 bit contra lo esperado
        address typo = address(uint160(TREASURY) ^ 1);
        vm.expectRevert(bytes("STAKING_OWNER != EXPECTED_OWNER"));
        d.checkOwner(typo, TREASURY);
        vm.expectRevert(bytes("STAKING_OWNER = 0"));
        d.checkOwner(address(0), TREASURY);
        vm.expectRevert(bytes("EXPECTED_OWNER sin completar"));
        d.checkOwner(TREASURY, address(0));
        // otra direccion, aunque coincida consigo misma: EOA, "Safe" con codigo y EOA delegada
        vm.expectRevert(bytes("el owner tiene que ser la tesoreria"));
        d.checkOwner(alice, alice);
        address safe = owner;
        vm.etch(safe, hex"6080604052");
        vm.expectRevert(bytes("el owner tiene que ser la tesoreria"));
        d.checkOwner(safe, safe);
        vm.etch(bob, abi.encodePacked(hex"ef0100", address(0xBEEF)));
        vm.expectRevert(bytes("el owner tiene que ser la tesoreria"));
        d.checkOwner(bob, bob);
        // otra cadena
        vm.chainId(1);
        vm.expectRevert(bytes("chainid != 4663"));
        d.checkOwner(TREASURY, TREASURY);
        vm.chainId(4663);
        // la tesoreria: con delegate 7702 (como hoy, MetaMask) y sin codigo, pasa
        vm.etch(TREASURY, abi.encodePacked(hex"ef0100", address(0xBEEF)));
        d.checkOwner(TREASURY, TREASURY);
        vm.etch(TREASURY, "");
        d.checkOwner(TREASURY, TREASURY);
        // la tesoreria con codigo de contrato normal: no es la EOA de la tesoreria, se rechaza
        vm.etch(TREASURY, hex"6080604052");
        vm.expectRevert(bytes("owner con codigo de contrato: no es la tesoreria"));
        d.checkOwner(TREASURY, TREASURY);
    }
}

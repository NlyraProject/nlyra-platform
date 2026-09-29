// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// REGRESION del hallazgo "swap callback trusts pool owed" (hallazgo 6, lente reentrancy). SIN fork: tokens y
// pools son mocks locales. Antes el constructor aceptaba el GreedyPoolV y un claim(ALL_ETH) drenaba todo el
// principal. Ahora ningun mock pasa el constructor: la direccion del pool tiene que salir de
// CREATE2(factory canonico, token0, token1, fee, init code de v3). Que el callback no se pueda llamar desde
// afuera y que los pools reales cobren exacto se prueba en el fork (suite principal y v_swap-mev_misdeploy).
import {Test} from "forge-std/Test.sol";
import {ERC20} from "oz/token/ERC20/ERC20.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {RealYieldStaking} from "../../src/RealYieldStaking.sol";

contract MockTokV is ERC20 {
    constructor(string memory n) ERC20(n, n) {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// Pool honesto (modelo del v3 real sin limite de precio): pide exactamente amountIn, paga 1:1 y
/// verifica que recibio lo pedido.
contract HonestPoolV {
    address public token0;
    address public token1;
    constructor(address t0, address t1) { token0 = t0; token1 = t1; }
    function swap(address rcpt, bool z, int256 amt, uint160, bytes calldata) external returns (int256 a0, int256 a1) {
        (address tin, address tout) = z ? (token0, token1) : (token1, token0);
        MockTokV(tout).mint(rcpt, uint256(amt));
        uint256 b = IERC20(tin).balanceOf(address(this));
        (a0, a1) = z ? (amt, -amt) : (-amt, amt);
        (bool ok,) = msg.sender.call(abi.encodeWithSignature("uniswapV3SwapCallback(int256,int256,bytes)", a0, a1, bytes("")));
        require(ok, "cb");
        require(IERC20(tin).balanceOf(address(this)) == b + uint256(amt), "IIA");
    }
}

/// Pool falso: token0/token1 correctos, pide en el callback TODO el saldo de tokenIn y miente en el retorno.
contract GreedyPoolV {
    address public token0;
    address public token1;
    constructor(address t0, address t1) { token0 = t0; token1 = t1; }
    function swap(address, bool z, int256 amt, uint160, bytes calldata) external returns (int256, int256) {
        address tin = z ? token0 : token1;
        int256 greedy = int256(IERC20(tin).balanceOf(msg.sender));
        (int256 d0, int256 d1) = z ? (greedy, int256(-1)) : (int256(-1), greedy);
        (bool ok,) = msg.sender.call(abi.encodeWithSignature("uniswapV3SwapCallback(int256,int256,bytes)", d0, d1, bytes("")));
        require(ok, "cb");
        return z ? (amt, int256(-1)) : (int256(-1), amt);
    }
}

/// Mock que ademas imita factory()/fee() del factory real.
contract SpoofPoolV is GreedyPoolV {
    constructor(address t0, address t1) GreedyPoolV(t0, t1) {}
    function factory() external pure returns (address) { return 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA; }
    function fee() external pure returns (uint24) { return 10000; }
}

contract VSwapCallbackTrustsPoolOwedTest is Test {
    MockTokV weth; MockTokV nlyra; MockTokV usdg;
    address splitterLocker = address(0x1111);
    address treasury = address(0x2222);

    function setUp() public {
        weth = new MockTokV("WETH"); nlyra = new MockTokV("NLYRA"); usdg = new MockTokV("USDG");
    }

    function _deploy(address poolN, address poolU) internal returns (RealYieldStaking st) {
        st = new RealYieldStaking(address(this), address(nlyra), address(weth), address(usdg), poolN, poolU,
            splitterLocker, treasury, 5_000, 1 days);
    }

    function test_greedyPool_rejectedAtDeploy() public {
        GreedyPoolV fake = new GreedyPoolV(address(weth), address(nlyra));
        HonestPoolV pu = new HonestPoolV(address(weth), address(usdg));
        vm.expectRevert(); // sin factory(): el constructor revierte
        _deploy(address(fake), address(pu));
    }

    function test_spoofedFactory_rejectedAtDeploy() public {
        SpoofPoolV fake = new SpoofPoolV(address(weth), address(nlyra));
        SpoofPoolV fakeU = new SpoofPoolV(address(weth), address(usdg));
        vm.expectRevert(RealYieldStaking.BadPool.selector);
        _deploy(address(fake), address(fakeU));
    }

    function test_noCodePool_rejectedAtDeploy() public {
        vm.expectRevert(RealYieldStaking.BadPool.selector);
        _deploy(address(0xdead), address(0xbeef));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Interfaces minimas de contratos externos (Pons, Uniswap v3, WETH).
/// Copiadas de las fuentes verificadas; solo lo que usamos.

/// PonsLaunchLocker 0x736D76699C26D0d966744cAe304C000d471f7F35
interface IPonsLaunchLocker {
    error NotAuthorized();
    error NoFeesToCollect();
    function collectFees(address token) external returns (uint256 amount0, uint256 amount1);
    function feeRedirects(address token) external view returns (address);
    function setFeeRedirect(address token, address newFeeWallet) external;
}

/// Uniswap v3 pool (solo swap + inmutables para validarlo contra el factory).
interface IUniswapV3PoolLike {
    function factory() external view returns (address);
    function fee() external view returns (uint24);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

interface IWETH9 {
    function deposit() external payable;
}

interface IRealYieldStakingNotify {
    function notifyRewards(uint256 wethIn, uint256 nlyraIn) external;
}

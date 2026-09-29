# Architect Swap: Uniswap V2 and V3, deployed verbatim

**Live at [nlyra.xyz/dex](https://nlyra.xyz/dex).** We deployed Uniswap V2 and V3 on Robinhood Chain **byte-for-byte unmodified** and put both behind one page. The swap box quotes V2 and V3 and executes on whichever returns more tokens. In the liquidity tab you choose between a classic V2 pool and a concentrated V3 position.

| Contract | Address | Verified source |
|---|---|---|
| UniswapV2Factory | [`0xfa6253ee74F7956b022998F7bfa271990C8A82a8`](https://robinhoodchain.blockscout.com/address/0xfa6253ee74F7956b022998F7bfa271990C8A82a8) | [`deployed/dex/UniswapV2Factory-0xfa6253/`](../deployed/dex/UniswapV2Factory-0xfa6253/) |
| UniswapV2Router02 | [`0xA5deC66ECa62AE363dC47965bB790C3B8870b6B6`](https://robinhoodchain.blockscout.com/address/0xA5deC66ECa62AE363dC47965bB790C3B8870b6B6) | [`deployed/dex/UniswapV2Router02-0xA5deC6/`](../deployed/dex/UniswapV2Router02-0xA5deC6/) |
| UniswapV3Factory | [`0x3FdaBf7AB5d871B89F1d9DA04Dc2E0733dB70CaF`](https://robinhoodchain.blockscout.com/address/0x3FdaBf7AB5d871B89F1d9DA04Dc2E0733dB70CaF) | [`deployed/dex/UniswapV3Factory-0x3FdaBf/`](../deployed/dex/UniswapV3Factory-0x3FdaBf/) |
| SwapRouter (V3) | [`0x4D0d17F66d1da788da50CF5217894F36684F958E`](https://robinhoodchain.blockscout.com/address/0x4D0d17F66d1da788da50CF5217894F36684F958E) | [`deployed/dex/SwapRouter-V3-0x4D0d17/`](../deployed/dex/SwapRouter-V3-0x4D0d17/) |
| NonfungiblePositionManager (V3) | [`0x4b71BE063E72b0BE36F690535C9C0cE533A9FB5C`](https://robinhoodchain.blockscout.com/address/0x4b71BE063E72b0BE36F690535C9C0cE533A9FB5C) | [`deployed/dex/NonfungiblePositionManager-V3-0x4b71BE/`](../deployed/dex/NonfungiblePositionManager-V3-0x4b71BE/) |
| QuoterV2 (V3) | [`0x7346b0435f165D33c5b8166fA227A3224646891F`](https://robinhoodchain.blockscout.com/address/0x7346b0435f165D33c5b8166fA227A3224646891F) | [`deployed/dex/QuoterV2-V3-0x7346b0/`](../deployed/dex/QuoterV2-V3-0x7346b0/) |

- V2 uses `solc 0.5.16` (core) and `0.6.6` (periphery), and V3 uses `0.7.6`, the same compilers and settings as the Uniswap releases.
- [`DEPLOYED.json`](DEPLOYED.json) records the V2 deployment, including the pair `initCodeHash` (`0xfbbc…e3a7`) that routers and SDKs need.
- The code is Uniswap's, under Uniswap's licenses (GPL-2.0 / GPL-3.0 / BUSL-1.1). The only admin powers are the protocol-fee switches (V2 `feeTo`, V3 `setFeeProtocol`). They route a share of swap fees and cannot touch liquidity.

[`dex.html`](dex.html) is the whole frontend in one static file. It talks to the chain only through the user's wallet, so it can be hosted anywhere.

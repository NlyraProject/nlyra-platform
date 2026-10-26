# NLYRA bridge: Robinhood Chain <-> Arbitrum One (LayerZero V2 OFT)

Live since 19 October 2026 at [nlyra.xyz/bridge](https://nlyra.xyz/bridge). NLYRA has no owner and cannot be modified, so the bridge is an **OFTAdapter** on Robinhood Chain that locks NLYRA, and an **OFT** on Arbitrum One that mints the same amount and burns it on the way back. Supply on Arbitrum never exceeds what is locked in the adapter. Messaging and verification by LayerZero V2 with two required DVNs (LayerZero Labs and Nethermind), message libraries pinned.

| Contract | Network | Address |
|---|---|---|
| [`NlyraOFTAdapter`](src/NlyraOFTAdapter.sol) | Robinhood Chain (4663) | [`0xe7b3…3264`](https://robinhoodchain.blockscout.com/address/0xe7b3171b76B959Db805874926aA0D62b1A5d3264?tab=contract) |
| [`NlyraOFT`](src/NlyraOFT.sol) | Arbitrum One (42161) | [`0x834e…06b5`](https://arbiscan.io/address/0x834e80509b23dC82d79F982510a32348986B06b5#code) |

The only code added to the stock LayerZero contracts is an outbound rate limit (LayerZero's own `RateLimiter`, owner-settable), set to 20,000,000 NLYRA per day per destination. The owner of both contracts, and the LayerZero delegate, is the treasury `0xe30647793192D15BFA6E53aE8651368d332fe04C`. No NLYRA fee: a user pays the LayerZero message and gas.

The exact verified sources (41 and 43 files, all pinned LayerZero and OpenZeppelin packages), the ABIs and the compiler settings are in [`../deployed/bridge/`](../deployed/bridge/). Endpoints, eids and the Arbitrum market are in [`../deployments/bridge-addresses.json`](../deployments/bridge-addresses.json).

## Tests

`test/NlyraBridge.t.sol` runs the two contracts against LayerZero's `TestHelperOz5` mock endpoints: send and receive both ways, supply invariants, the rate limit, owner-only setters. `script/NlyraBridgePlan.sol` holds every production parameter and builds every calldata of the deployment and wiring plan; `script/BuildPlan.s.sol` writes them without any RPC.

```
forge install   # pinned packages, see package.json of the working project
forge test
```

Compiler: solc 0.8.22, optimizer 200 runs, EVM paris (no PUSH0, the same bytecode is safe on both chains).

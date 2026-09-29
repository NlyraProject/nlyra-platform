# Infinity Grid v4 (compound): contract, tests, deployment, verification

## What the contract does

[`ArchitectInfinityGridV4`](../contracts/ArchitectInfinityGridV4.sol) is an infinity grid (no price ceiling) held in the owner's own escrow record. It builds on Infinity Grid v3 (floor price, take-profit, stop-loss, `topUp`), whose verified source is in [`../../deployed/bots/Infinity-Grid-v3-0x177a88/`](../../deployed/bots/Infinity-Grid-v3-0x177a88/), and adds the same two features that `ArchitectSpotGridV4` brought to the spot grid:

- **Per-bot gas reserve.** `openWithEth(..., gasReserve)` and `topUp(..., gasAdd)` fund a reserve that pays the keeper the exact gas of each fill (`GasPaid`). A bot without enough reserve reverts with `NoGas`. `stop` and `refundExpired` return what is left of it (`GasRefunded`). `gasOverhead` is bounded by `setGasOverhead`.
- **Compound.** The profit of each `fillUp` is added to the position size V (`Reinvested(id, k, amount, newV)`, `reinvested` in the struct). V never decreases. Compounding can be switched per bot with `setCompound`.
- The stop-loss price lives in `Params.slPrice` / `Grid.slPrice`.

Only the owner can `stop` and withdraw. The keeper can call only the fill / stop-loss / take-profit paths the bot already authorised.

Compiled with solc `0.8.24`, optimizer 200 runs, `evmVersion: cancun`, `viaIR: true` (runtime 18,676 bytes) by [`../scripts/compile-infv4.js`](../scripts/compile-infv4.js).

## Tests (anvil fork of Robinhood Chain mainnet)

| File | Covers | Result (Sep 12, 2026) |
|---|---|---|
| [`forktest-infv4.js`](../test/forktest-infv4.js) | T1 open with reserve, T2 `fillUp` pays the keeper, T3 `NoGas`, T4 `fillDown` pays, T5 gas and capital top-ups, T6 `stop` refunds gas, T7 `refundExpired` refunds gas, T8 `setCompound`, T9 compound grows V (and `fillDown` buys against the new V), T10 overhead, F1 stop-loss with a small reserve plus `setStopLoss`, invariant fuzz I1-I9 (30 steps) | 81 OK, 0 failing, 1 skipped |
| [`tpcheck-infv4.js`](../test/tpcheck-infv4.js) | Direct take-profit (kind 4), soft gas, reserve refunded | 11 OK |
| [`slcheck-infv4.js`](../test/slcheck-infv4.js) | Stop-loss actually executed after 16 fine-grained price drops | 9 OK |

See [`../README.md`](../README.md#running-a-fork-test) for how to run a suite.

## Deployment

| | |
|---|---|
| Address | [`0xBdC77e3D589D161489f7C986d8f654F30b88DDeb`](https://robinhoodchain.blockscout.com/address/0xBdC77e3D589D161489f7C986d8f654F30b88DDeb) |
| Deploy tx | [`0xaa42408ccf12911d8487d081638241c7de613d8e50a324790d604e311534c9cb`](https://robinhoodchain.blockscout.com/tx/0xaa42408ccf12911d8487d081638241c7de613d8e50a324790d604e311534c9cb) (block 61,248,237, Sep 12, 2026 ~16:30 UTC) |
| Router allowlist tx | [`0x18dde2a4c433505d850b3a008ccc87718e9f4b7085c07c21908296abcd76ab25`](https://robinhoodchain.blockscout.com/tx/0x18dde2a4c433505d850b3a008ccc87718e9f4b7085c07c21908296abcd76ab25) (`router.setCaller(infinityGridV4, true)`) |
| Constructor args | router `0x9d1eA9Abbb99D813b7acA7666285CDed7f833565`, WETH `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`, keeper `0x96D0B8008d1E38d45A1B9cFCCCC932629059246c` |

## Verification

- **Blockscout:** full match.
- **Sourcify:** exact match ([`../scripts/verify-infv4.js`](../scripts/verify-infv4.js) is the script we ran).
- To reproduce it yourself, submit [`../artifacts/ArchitectInfinityGridV4/ArchitectInfinityGridV4.input.json`](../artifacts/ArchitectInfinityGridV4/ArchitectInfinityGridV4.input.json) as standard-JSON input with compiler `0.8.24+commit.e11b9ed9` and the constructor arguments above.
- The verified source for the address is in [`../../deployed/bots/Infinity-Grid-v4-compound-0xBdC77e/`](../../deployed/bots/Infinity-Grid-v4-compound-0xBdC77e/).

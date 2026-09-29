# Verified sources of every deployed contract

One folder per deployed address, grouped by product. Each folder contains:

| File | What it is |
|---|---|
| `README.md` | Address, Blockscout and Sourcify status, status (live / retired), whether it holds user funds, compiler settings, constructor arguments |
| `src/` | The exact source files Blockscout (or, where noted, Sourcify) verified for that address, with their original paths |
| `compiler.json` | Compiler version and the full settings used for the match |
| `abi.json` | The verified ABI (when Blockscout serves one) |

These files were extracted on 2026-09-28 through the Blockscout API (`/api/v2/smart-contracts/<address>`). Sniper v1 and the first Predict deploy came from Sourcify, where they are exact matches. Nothing in `src/` has been edited, so you can diff it against the working copies in [`../bots/`](../bots/), [`../otc/`](../otc/) and [`../launchpad/`](../launchpad/).

The index of all of them, with what each contract does, is [`../CONTRACTS.md`](../CONTRACTS.md).

Third-party code keeps its own license: Uniswap V2/V3 in [`dex/`](dex/), the 0xbow Privacy Pools contracts and Poseidon libraries in [`shield/`](shield/), and OpenZeppelin wherever it is imported.

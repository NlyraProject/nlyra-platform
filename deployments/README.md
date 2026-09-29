# Address book

[`desk-addresses.json`](desk-addresses.json) is the machine-readable record of every Desk and bot contract. It lists each address, its deploy transaction and block, and the transaction that authorised it on the fee router (`…CallerTx`). It also holds the shared addresses (WETH, USDG, Permit2, the keeper, the treasury). The fork tests and the deploy/verify scripts in [`../bots/`](../bots/) and [`../otc/`](../otc/) read it; point them at another copy with `DESK_ADDRESSES=<path>`.

The human-readable version, with what each contract does and its verification status, is [`../CONTRACTS.md`](../CONTRACTS.md).

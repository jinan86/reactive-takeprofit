# DEMO.md — TakeProfit live demo evidence (testnet, 22 Nov 2026)

Full log: `demo-run.log`. Video: `demo-video.mp4` (104 s).

## Contracts (v2, current)

| Contract | Chain | Address |
| --- | --- | --- |
| tUSD | Base Sepolia | `0x594874a10bC1d0197344d636db835d37e41BC4cf` |
| tTOKEN | Base Sepolia | `0xE29FB5755A06f63B6885E8bCFb91F6D66f7056d3` |
| MockPriceOracle | Base Sepolia | `0xf3b5fe72dEDf5EcD0C937EA67089e3503358B099` |
| OrderVault | Base Sepolia | `0x9A2563B6c28C0fD0b4776567C6403A2494Fb9B1E` |
| TakeProfitReactive | Lasna | `0x3986fd00e872773fC987a718c6468ffF48c6CBFB` |
| OrderExecutor | Base Sepolia | `0xD9Cb23D635024fdD9ab5053B0e56D04d97222E0D` |

Deployer/payee wallet (project-only, testnet): `0x9e377851c1DF9aCB840d5081572E3AF7C45ac449`.

## Demo run (order #2 — sell 10 tTOKEN at ≥ $2,000)

1. **Approve** vault for 10 tTOKEN —
   [`0x1b45a297…ea138`](https://sepolia.basescan.org/tx/0x1b45a2979b6199adc120c4ad601759e9cc0ad887f7d0e9eaccacb9be6bdea138)
2. **Create order #2** — 10 tTOKEN locked in vault —
   [`0xd9327b33…e06b209`](https://sepolia.basescan.org/tx/0xd9327b33ce0c774264433e2a177e4bf77bedc37241897951020095700e06b209)
3. **Price $1,500 (below target)** — setPrice
   [`0x93102d4b…cb4b52`](https://sepolia.basescan.org/tx/0x93102d4bae4ad2335671cc2287075a1a64d43bbdfdb0ebf1595f52ed51cb4b52),
   react (Lasna)
   [`0x939e9a51…04e1fc`](https://lasna.reactscan.net/tx/0x939e9a51bcbc996daadc8fb77d36ce531387228494c5e63665071961aa04e1fc).
   Result: `reactCount` 1→2, `actedCount` 0, order active, payee tUSD 0.
4. **Price $2,100 (target hit)** — setPrice
   [`0xb39200fd…2796f8`](https://sepolia.basescan.org/tx/0xb39200fd771630810a0519223da81a5571720ce04764551118ecd86daa2796f8)
   (block 61941256), react (Lasna)
   [`0xa3f5c2cf…441196b`](https://lasna.reactscan.net/tx/0xa3f5c2cf974da5220e5a9617599faf65aa895b2e3888bdfc9e6e8a5d1441196b),
   callback
   [`0x7e86a502…bc4b7b`](https://sepolia.basescan.org/tx/0x7e86a502ede9d43da41b4910d084465a613368edec0ff65aaf1d799223bc4b7b)
   (block 61941264, ~10 s later). Result: `actedCount` 1, order executed,
   payee received exactly **21,000 tUSD** (10 × $2,100); vault tUSD
   1,000,000 → 979,000.
5. **Price $2,200 (again)** — setPrice
   [`0x4c6eb2e9…89fb9d`](https://sepolia.basescan.org/tx/0x4c6eb2e918059802f8ae1a5089e763cc0e0c8c1ac3462c14fb1c08e13989fb9d),
   react (Lasna)
   [`0x1ab5e55b…208b8e`](https://lasna.reactscan.net/tx/0x1ab5e55bfd830d06c2214fc6c3db3021987349bdaddbe5822e2922d731208b8e).
   Result: `actedCount` 2 (duplicate callback requested) but payee balance
   stayed exactly **21,000 tUSD** — no double pay.
6. **Direct execution attempts** — `vault.executeOrder` as deployer reverts
   `NotExecutor`; `executor.execute` as deployer reverts `NotAuthorized`
   (only the callback proxy may call). No tx (reverts).

Final verified state: `reactCount = 4`, `actedCount = 2`,
`lastPrice = $2,200`; order #2 `active = false`, `executed = true`;
reactive ~0.423 lREACT, executor ~0.001 ETH.

## v1 post-mortem

The first reactive (`0xbE1284eaff6F75e79828c97f5bF38A48502BE0AC`, executor
`0x659460a6962b7786bCD8Ed1AfEcf3070FA7F793D`) never fired: its `react()`
copied Sentinel's `opCode != 3` gate, but `opCode` is the LOGn index and
our events are LOG1 (PriceUpdate), LOG2 (OrderCancelled), LOG4
(OrderCreated) — every `react()` returned early while the network still
billed it (balance 0.5 → ~0.477 lREACT). The network itself was proven
alive by a probe verdict on Sentinel (reactCount 12→13 in ~90 s). Fix:
dispatch on `topic0` only; regression test `testReactFiresOnRealisticOpcodes`
covers LOG1/LOG2/LOG4. v1 contracts abandoned (stranded ~0.477 lREACT +
0.001 ETH, testnet dust). Order #1 (created against v1) was cancelled for
a full refund: `0xdc5d46a5ddb91d16fa3ece23b6d8c62f75be708094823a24010c76e744651907`.

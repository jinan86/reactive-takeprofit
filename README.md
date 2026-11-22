# TakeProfit — deterministic take-profit / limit-order executor on Reactive Network

> **Set it and forget it.** Set once — "sell X of my token when the price
> reaches Y" — and a Reactive smart contract watches the price and executes
> the sale for you. No bot, no server, no keeper, no AI in the loop.

Built for the **Reactive Omni Buildathon** (DoraHacks), track **Set It and
Forget It**. Testnet only — Lasna (chain 5318007) + Base Sepolia (chain
84532). No mainnet, no real funds.

## The problem

A take-profit order on a DEX today means one of three bad options: leave
funds on a centralized exchange, run your own bot 24/7 (server costs,
downtime, key management), or trust a keeper network. A price target is a
purely deterministic rule — `if price >= target: sell` — so it should be
enforceable by a contract that reacts to price events, with no
infrastructure in between.

## How it works

```
User (once)                    Base Sepolia                    Lasna
  │  createOrder(token,          │                               │
  │  amount, target, payee)      │                               │
  ├─────────────────────────────► OrderVault                    │
  │  tokens locked in vault      │  emits OrderCreated           │
  │                              ├──────────────────────────────►│
  │                              │                        TakeProfitReactive
  │                              │                        mirrors order
  │                              │                               │
  │  MockPriceOracle.setPrice()  │                               │
  ├─────────────────────────────► PriceUpdate event             │
  │                              ├──────────────────────────────►│
  │                              │                   price >= target?
  │                              │                   YES -> requestCallback
  │                              │                               │
  │                              │◄──────────────────────────────┤
  │                       OrderExecutor.execute(orderId)          │
  │                       (authenticated callback)                │
  │  re-checks: order active,                                     │
  │  not executed, price still                                    │
  │  >= target — fail closed                                      │
  │                              │                               │
  │  vault.executeOrder():                                        │
  │  proceeds = amount * price / 1e8 paid in tUSD to payee        │
  │  order marked executed (can never execute twice)              │
```

Contracts:

| Contract | Chain | Address |
| --- | --- | --- |
| tUSD (mock stablecoin) | Base Sepolia | `0x594874a10bC1d0197344d636db835d37e41BC4cf` |
| tTOKEN (mock token sold) | Base Sepolia | `0xE29FB5755A06f63B6885E8bCFb91F6D66f7056d3` |
| MockPriceOracle | Base Sepolia | `0xf3b5fe72dEDf5EcD0C937EA67089e3503358B099` |
| OrderVault | Base Sepolia | `0x9A2563B6c28C0fD0b4776567C6403A2494Fb9B1E` |
| TakeProfitReactive | Lasna | `0x3986fd00e872773fC987a718c6468ffF48c6CBFB` |
| OrderExecutor | Base Sepolia | `0xD9Cb23D635024fdD9ab5053B0e56D04d97222E0D` |

Deploy transactions (current, v2 — see note below):

| Step | Tx |
| --- | --- |
| tUSD deploy | [`0xcb96d44e…0d714`](https://sepolia.basescan.org/tx/0xcb96d44e974935f2caa4f07c52a24c686350086c2698b13507a2c02a7970d714) |
| tTOKEN deploy | [`0x760a4da9…b6`](https://sepolia.basescan.org/tx/0x760a4da9566480ecc144c139c235ae8d5dc8b98eccc1c413a9ba4d5b5ec786b6) |
| MockPriceOracle deploy | [`0x67b02d32…c0`](https://sepolia.basescan.org/tx/0x67b02d32877cee29e41767c334c138d887879b011afd60f77b755661f0ddf4c0) |
| OrderVault deploy | [`0x9a9b3e42…ff814`](https://sepolia.basescan.org/tx/0x9a9b3e4224875e90f1c3f790e2582caffec1cf343ab6107daf4b1af3851ff814) |
| TakeProfitReactive deploy (Lasna, v2) | [`0xac1509a3…7e47db`](https://lasna.reactscan.net/tx/0xac1509a3656a6e25aed1cf28bdf9a3d4d28593f63c38525e8b6356ef3b7e47db) |
| OrderExecutor deploy (v2) | [`0x87bc376e…9b994da0`](https://sepolia.basescan.org/tx/0x87bc376e3ddf30cd606c11b0a8d40ceed9dc55aab6b0e035e68054ad9b994da0) |
| `reactive.setExecutor(executor)` (Lasna, v2) | [`0x45b8030f…a153b`](https://lasna.reactscan.net/tx/0x45b8030f387a8cd758737beecba7c13108a38e589e8bfed608f90bfee44a153b) |
| `vault.setExecutor(executor)` (v2) | [`0x4acdf016…73ab7`](https://sepolia.basescan.org/tx/0x4acdf016c8ebb4933f4c023c5a59247d6f86159bd41d9c7233b0ef1d79573ab7) |

> **v1 post-mortem (honest).** The first reactive (`0xbE1284e…`, executor
> `0x659460a6…`) never fired: its `react()` copied Sentinel's
> `opCode != 3` gate, but `opCode` is the LOGn index — our events are
> LOG1/LOG2/LOG4, so every `react()` returned early while the network
> still billed it (~0.023 lREACT). The bug was caught live because the
> network itself was proven alive via a probe verdict on Sentinel
> (reactCount 12→13). Fixed by dispatching on `topic0` only; v1
> contracts are abandoned (stranded ~0.477 lREACT + 0.001 ETH, testnet
> dust) and the demo below ran entirely on v2.

## Live demo (testnet, 22 Nov 2026)

Scenario: sell **10 tTOKEN when price ≥ $2,000**, payee = deployer wallet
(order #2; order #1 was created against the v1 reactive, then cancelled
for a full refund before the v2 redeploy). Watch it:
[`demo-video.mp4`](./demo-video.mp4) (~2 min). Full log: `demo-run.log`.

| Step | What happened | Tx |
| --- | --- | --- |
| 0. Approve | Vault approved for 10 tTOKEN | [`0x1b45a297…ea138`](https://sepolia.basescan.org/tx/0x1b45a2979b6199adc120c4ad601759e9cc0ad887f7d0e9eaccacb9be6bdea138) |
| 1. Create order | Order #2: 10 tTOKEN locked, target $2,000 | [`0xd9327b33…e06b209`](https://sepolia.basescan.org/tx/0xd9327b33ce0c774264433e2a177e4bf77bedc37241897951020095700e06b209) |
| 2. Price $1,500 | Below target — `reactCount` 1→2, `actedCount` stays **0**, order active, payee tUSD **0** | [`0x93102d4b…cb4b52`](https://sepolia.basescan.org/tx/0x93102d4bae4ad2335671cc2287075a1a64d43bbdfdb0ebf1595f52ed51cb4b52) (setPrice) · [`0x939e9a51…04e1fc`](https://lasna.reactscan.net/tx/0x939e9a51bcbc996daadc8fb77d36ce531387228494c5e63665071961aa04e1fc) (react, Lasna) |
| 3. Price $2,100 | Target hit — `actedCount` → 1, callback settles: payee receives exactly **21,000 tUSD** (10 × $2,100), vault tUSD 1,000,000 → 979,000 | [`0xb39200fd…2796f8`](https://sepolia.basescan.org/tx/0xb39200fd771630810a0519223da81a5571720ce04764551118ecd86daa2796f8) (setPrice) · [`0xa3f5c2cf…441196b`](https://lasna.reactscan.net/tx/0xa3f5c2cf974da5220e5a9617599faf65aa895b2e3888bdfc9e6e8a5d1441196b) (react, Lasna) · [`0x7e86a502…bc4b7b`](https://sepolia.basescan.org/tx/0x7e86a502ede9d43da41b4910d084465a613368edec0ff65aaf1d799223bc4b7b) (callback, block 61941264) |
| 4. Price $2,200 | Second callback requested (`actedCount` → 2) but order already executed — payee stays at exactly **21,000 tUSD**, no double pay | [`0x4c6eb2e9…89fb9d`](https://sepolia.basescan.org/tx/0x4c6eb2e918059802f8ae1a5089e763cc0e0c8c1ac3462c14fb1c08e13989fb9d) (setPrice) · [`0x1ab5e55b…208b8e`](https://lasna.reactscan.net/tx/0x1ab5e55bfd830d06c2214fc6c3db3021987349bdaddbe5822e2922d731208b8e) (react, Lasna) |
| 5. Direct attacks | `vault.executeOrder` as deployer → reverts `NotExecutor`; `executor.execute` as deployer → reverts `NotAuthorized` (only the proxy may call) | (reverts — no tx) |

Final verified state: `reactive.reactCount = 4`, `actedCount = 2`,
`lastPrice = $2,200`; order #2 `active = false`, `executed = true`;
reactive holds ~0.423 lREACT, executor ~0.001 ETH. End-to-end
price-cross → settlement took ~10 s (setPrice block 61941256 → callback
block 61941264).

## What this is NOT (differences from other builds)

- **vs GuardianLepas** (same track, Reactive buildathon build 51455): that
  project rescues **lending positions from liquidation** — it watches
  health factors, collateral, and debt. TakeProfit has **no health factor,
  no lending, no collateral, no debt anywhere**: it executes a
  **price-threshold sell order**. Different trigger, different mechanism,
  different user problem.
- **vs Tripwire** (bars26/tripwire): that project is an **allowlist
  dead-bolt** — it blocks transfers to non-allowlisted addresses.
  TakeProfit uses **no allowlist or denylist** as its mechanism; the only
  rule is a price threshold.
- **vs Sentinel** (our own Reactive Meets AI build): Sentinel puts an **LLM
  in the loop** to score risk. TakeProfit is **fully deterministic** —
  `price >= target` is the whole decision procedure, no model, no
  off-chain agent, no judgement call.

## Design decisions & limitations (honest)

- **Mock oracle.** `MockPriceOracle.setPrice()` is owner-only and exists
  for the demo. Production swaps it for a real feed (Chainlink price feed
  or Uniswap TWAP) with the same `PriceUpdate` event shape — the reactive
  contract and executor only read the event + current price, so the swap
  is a drop-in at the oracle address.
- **Mock settlement.** The sale is settled from a pre-funded tUSD pool in
  the vault (`proceeds = amount * price / 1e8` at the oracle price when
  the callback lands), not routed through a DEX. Production would swap
  through a DEX inside the executor instead of paying from a pool.
- **Execution price = oracle price at callback time.** The reactive
  contract fires when a price event crosses the target; the executor
  re-checks the live price and settles at that price. In a fast-moving
  market the fill price can differ from the target — that is the honest
  semantics of a market take-profit, not a limit fill at exactly target.
- **Bounded scan.** The reactive contract scans at most `MAX_SCAN = 50`
  mirrored order ids per `PriceUpdate` (oldest first) so `react()` gas
  stays bounded. Keep the live order set small, or re-create orders after
  execution.
- **Duplicate callbacks are harmless.** If the price stays above target
  and another `PriceUpdate` arrives, a second callback is requested — but
  the executor refuses to execute an already-executed order (fail closed),
  so the payee can never be paid twice. Demonstrated live in the demo.
- **No re-arm on price dip.** If the price crosses the target but dips
  below it before the callback lands, the executor refuses to settle and
  the order stays active; the next `PriceUpdate` above target triggers a
  fresh callback.
- **Funding.** The Lasna reactive contract holds lREACT (plain transfer;
  the system settles via `pay()`/`coverDebt()`); the Base Sepolia executor
  holds Sepolia ETH for callback billing (`coverDebt()`). Both are
  testnet-only and worthless.

## Run it yourself

```bash
# Foundry (forge/cast in ~/.foundry/bin)
forge test            # 17 unit tests, no fork needed

# Deploy (needs the project wallet key in
# ../sentinel/.wallet.json — testnet only, never commit it)
./deploy.sh

# End-to-end demo: order -> price below target -> price above target
# -> execution -> double-execution attempt
./demo.sh
```

Key files: `src/MockPriceOracle.sol`, `src/OrderVault.sol`,
`src/TakeProfitReactive.sol`, `src/OrderExecutor.sol`,
`src/MockToken.sol`, `test/TakeProfit.t.sol`, `script/Deploy*.s.sol`,
`deploy.sh`, `demo.sh`.

## Tests

`forge test`: **18/18 green** — order creation + token lock; below-target
price triggers nothing; target hit requests exactly the right callback and
settles exactly `amount * price / 1e8`; second execution reverts;
cancel refunds and blocks later execution; unauthenticated callbacks
revert; executor re-checks the live price before settling;
non-owner `setPrice` reverts.

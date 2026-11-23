# Reactive Limit Order

**Track: Every Second Counts — Reactive Omni Buildathon (DoraHacks)**

A token limit order with no keeper, no polling bot, no cron. A trader deposits
token A into the `LimitOrderVault` on **Unichain Sepolia** with a target price.
The `LimitOrderReactive` contract on **Reactive Network Lasna** watches the
pool's `Swap` events in real time and fires an execution callback the moment
the pool price crosses the target. Measured full loop: **swap → execution in
2 seconds** (one block).

## How it works

```
 Trader                Unichain Sepolia (1301)            Reactive Lasna (5318007)
   │   1. createOrder(10 A, target 9.5 B/A)                        │
   │ ───────────────► LimitOrderVault                             │
   │                     emits OrderCreated ──────────────────►   │ mirrors order
   │                                                               │
 anyone  2. swapAforB(50 A)                                        │
   │ ───────────────► MiniPool                                    │
   │                     emits Swap(reserveA, reserveB) ────────► │ price 8.90 ≤ 9.5
   │                                                               │ requestCallback
   │   3. execute(orderId) ◄── callback proxy ◄─────────────────── │
   │ ◄─────────────── 88.9 B to trader                            │
   │                     emits OrderExecuted                       │
```

- `MiniPool` — minimal constant-product pair (x·y = k, zero fee) that exists
  to produce a live on-chain price feed. Every swap carries the post-swap
  reserves in its event, so the reactive contract prices the pair from the
  event alone, with zero extra RPC reads.
- `LimitOrderVault` (destination) — holds deposits, executes only through the
  chain's Reactive callback proxy **and** only when the injected reactive
  sender matches. The price check runs again on-chain at execution time, so a
  stale trigger can never move funds.
- `LimitOrderReactive` (Lasna) — subscribes to `OrderCreated`,
  `OrderCancelled` and `Swap`; mirrors open orders; fires a single
  `execute(orderId, observedPrice)` callback on the first crossing swap.

## Live deployment (Unichain Sepolia + Reactive Lasna)

| Contract | Chain | Address |
|---|---|---|
| TestToken A (TKA) | Unichain Sepolia 1301 | `0xafBF77C5587E365712416D6EFF9A40FDF2545F95` |
| TestToken B (TKB) | Unichain Sepolia 1301 | `0xfCE2AaC5c2B6e83D504AAF9844ed92ABbba91A10` |
| MiniPool | Unichain Sepolia 1301 | `0xd85d36a11c0bEaF58d29095b6A1d69D324593220` |
| LimitOrderVault | Unichain Sepolia 1301 | `0x6E6356ea484063Ac50e1D511244c96AB8BF0a18b` |
| LimitOrderReactive | Reactive Lasna 5318007 | `0x6E6356ea484063Ac50e1D511244c96AB8BF0a18b` |

(The vault and reactive contracts share an address because the deployer used
the same nonce on both chains — they live on different networks.)

## Proof: order executed 2 seconds after the price crossed

1. Pool seeded 1,000 A / 10,000 B → price 10 B per A.
2. `createOrder(10 A, target 9.5 B/A)` — tx
   [`0x290af66418a776a07703a217c58ca0462a9cda41e41af5228c2647b162df809b`](https://sepolia.uniscan.xyz/tx/0x290af66418a776a07703a217c58ca0462a9cda41e41af5228c2647b162df809b)
3. `swapAforB(50 A)` pushes price to ≈ 8.90 — tx
   [`0xdfa718c98eb2afce4a23be34f337e964142d085d3eb45f7a58516e99a3dbedc1`](https://sepolia.uniscan.xyz/tx/0xdfa718c98eb2afce4a23be34f337e964142d085d3eb45f7a58516e99a3dbedc1) (block timestamp `0x6b04accc`)
4. Reactive Network delivered `execute(1, price)` — tx
   [`0x0746cb8d366dcac8b06de9faafcde49ed9cd0e0765fc5664272e3e4045e3dbbf`](https://sepolia.uniscan.xyz/tx/0x0746cb8d366dcac8b06de9faafcde49ed9cd0e0765fc5664272e3e4045e3dbbf),
   `OrderExecuted(orderId 1, 10 A in, ≈89.85 B out, price ≈ 9.00)` at block
   timestamp `0x6b04acce` — **2 seconds** after the crossing swap.
5. `callbacksFired()` on the reactive contract: `1`.

## Latency measurement

| Stage | Time |
|---|---|
| Swap lands on Unichain Sepolia (event emitted) | t = 0 |
| Callback `execute()` mined on Unichain Sepolia | t + 2 s |
| **Full event → execution loop** | **≈ 2 s (one block)** |

## Security properties

- `execute()` is callable **only** by the chain callback proxy
  (`onlyServiceProvider`) and only when the injected reactive-contract address
  matches the vault's registered sender (`onlyCallbackSender`).
- The vault re-reads the pool price at execution and reverts if the price no
  longer crosses the target — a stale or replayed trigger moves nothing.
- Reentrancy-guarded; deposits are refundable via `cancelOrder()` until
  execution.

## Tests

```
forge test
# 8 passed: deposit pull, cancel refund, execution on crossing,
# revert above target, wrong-sender rejection, direct-caller rejection,
# double-execution rejection, price math
```

## Stack

Solidity 0.8.29 · Foundry · Reactive Network (`reactive-lib-omni`,
`AbstractReactive` + `AbstractCallback`, `requestCallbackV_1_0`) · Unichain
Sepolia.

## Author

Samudra Scout — Reactive Omni Buildathon submission.
Contact: Telegram @Pasopatiiii · Discord samudis514

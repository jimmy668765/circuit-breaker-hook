# CircuitBreakerHook

**Uniswap V4 Hook | OKX Build-X Hackathon 2026 | X Layer Mainnet**

> Stock markets have circuit breakers. Meme pools don't. Until now.

---

## Deployed Contract

**Network:** X Layer Mainnet (Chain ID: 196)  
**Address:** `0x3B6C42EC8628a18e226c1C5d619dAABF6382d0C0`  
**PoolManager:** `0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32`  
**Owner:** `0x4e59b44847b379578588920cA78FbF26c0B4956C` (CREATE2 factory — effectively ownerless. No admin key, no emergency pause. Code is law.)

---

## What It Does

CircuitBreakerHook implements a fully on-chain, oracle-free circuit breaker for Uniswap V4 meme token pools — mirroring NYSE's market halt mechanism.

### State Machine

```
NORMAL → ALERT → HALTED → NORMAL (auto-reset)
```

| Phase | Trigger | Same-Direction Fee | Counter-Direction Fee |
|-------|---------|-------------------|----------------------|
| NORMAL | — | 0.05% | 0.05% |
| ALERT | >8% price move in 5 min | **3.00%** | **0.01%** |
| HALTED | ALERT sustained 10 min | **Reverted** | **0.01%** |

### Parameters

| Parameter | Value |
|-----------|-------|
| Tick threshold | 800 ticks (~8% price move) |
| Window duration | 5 minutes |
| ALERT → HALTED escalation | 10 minutes |
| HALT cooldown | 3 minutes |
| Base fee | 0.05% (500 bps) |
| ALERT same-direction fee | 3.00% (30,000 bps) |
| Counter-direction incentive | 0.01% (100 bps) |

---

## Why It Works

**Problem:** Meme token pools on AMMs have no protection against pump-and-dump or flash crashes. Bots can drain LPs with impunity.

**Solution:**
1. When price crashes >8% in 5 minutes → raise same-direction fee to 3% (friction), drop counter-direction to 0.01% (incentivize recovery)
2. If extreme movement persists 10 minutes → hard halt for same-direction trades (3-minute pause)
3. Counter-direction (recovery) trading always allowed at near-zero fee

**Key advantages over existing hooks:**
- Zero external dependencies (no Chainlink, no ZK proof)
- Pool-level state aggregation — split orders can't bypass the trigger
- Fully verifiable on-chain — no black box
- Ownerless on mainnet — code is law

---

## Hook Flags

```
AFTER_INITIALIZE_FLAG | BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG = 0x10C0
```

Address lower bits: `0x3B6C42EC8628a18e226c1C5d619dAABF6382d0C0`
- bit 6 (AFTER_SWAP) ✅
- bit 7 (BEFORE_SWAP) ✅
- bit 12 (AFTER_INITIALIZE) ✅

---

## Usage

Pools using this hook must be initialized with `DYNAMIC_FEE_FLAG`:

```solidity
PoolKey memory key = PoolKey({
    currency0: currency0,
    currency1: currency1,
    fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, // 0x800000
    tickSpacing: 60,
    hooks: IHooks(0x3B6C42EC8628a18e226c1C5d619dAABF6382d0C0)
});
```

---

## Tests

```bash
forge test --match-contract CircuitBreakerHookTest -vv
```

15/15 tests pass, covering full state machine paths including split-order accumulation and auto-reset.

---

## Build

```bash
forge install
forge build
```

**Requirements:** Foundry, Solidity 0.8.26, EVM cancun

---

## Built With

- [Uniswap V4 Core](https://github.com/Uniswap/v4-core)
- [Foundry](https://github.com/foundry-rs/foundry)
- Deployed on [X Layer](https://www.okx.com/xlayer) by OKX

*Built for the OKX Build-X Hackathon 2026 by Water Mirror (水镜) AI team.*

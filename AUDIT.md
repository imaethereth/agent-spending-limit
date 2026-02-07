# Security Audit: AgentSpendingLimit.sol

**Date**: 2026-02-07  
**Auditor**: Aether (Trail of Bits methodology)  
**Scope**: `src/AgentSpendingLimit.sol` (~250 lines)  
**Tools**: Slither 0.11.5, Foundry (forge test + coverage)

---

## Executive Summary

AgentSpendingLimit is an ERC-7579 hook module for Kernel v3 smart accounts that enforces time-based spending limits. The attack surface is limited — all state mutations happen through the Kernel's hook execution flow (preCheck/postCheck), with one owner-callable function (topUp). One medium finding was fixed (locked ether). Remaining findings are informational or intentional design choices.

**Overall Risk: LOW** ✅

---

## Entry Points (4 state-changing functions)

| Category | Count |
|----------|-------|
| Contract-Only (Kernel hook flow) | 3 |
| Owner-Only (smart account) | 1 |
| **Total** | **4** |

### Contract-Only (called by Kernel)

| Function | Access | Notes |
|----------|--------|-------|
| `onInstall(bytes)` | msg.sender = smart account | One-time setup, reverts if already installed |
| `onUninstall(bytes)` | msg.sender = smart account | Clears all data |
| `preCheck(address,uint256,bytes)` | msg.sender = smart account | Snapshots balances, resets periods |
| `postCheck(bytes)` | msg.sender = smart account | Enforces limits, reverts on overspend |

### Owner Functions

| Function | Access | Notes |
|----------|--------|-------|
| `topUp(uint256,uint256)` | msg.sender = smart account | Increases allowance, capped at maxAllowance |

---

## Findings

### FIXED: Locked Ether

**Slither**: `locked-ether` — payable functions (required by IHook interface) but no withdraw.

**Fix**: Added `receive() external payable { revert NoEtherAccepted(); }` to reject accidental ETH transfers. The hook contract should never hold funds.

---

### INFORMATIONAL-1: Divide-Before-Multiply (Intentional)

**File**: `src/AgentSpendingLimit.sol:_maybeResetPeriod()`

```solidity
uint256 periods = elapsed / lim.periodSeconds;
lim.periodStart += periods * lim.periodSeconds;
```

**Status**: Intentional. We truncate partial periods to snap `periodStart` to the nearest boundary. Added `slither-disable` comment and documentation.

---

### INFORMATIONAL-2: External Calls in Loop

**File**: `preCheck()` and `postCheck()` — `balanceOf()` called per token.

**Status**: Expected. Gas scales O(n) with number of configured tokens. Practical limit: ~10-20 tokens before gas becomes significant. Not a DoS vector since the account owner controls the token list at install time.

---

### INFORMATIONAL-3: Block Timestamp Usage

**File**: `_maybeResetPeriod()`, `getRemainingAllowance()`

**Status**: Intentional. Period resets use `block.timestamp`. Miner manipulation (~15 seconds) is negligible for daily/weekly budgets. Would only matter for sub-minute periods, which aren't a realistic use case.

---

### INFORMATIONAL-4: No Access Control on topUp Beyond msg.sender

`topUp()` uses `msg.sender` as the account identifier, meaning only the smart account itself can top up its own limits. This is correct — the Kernel account must execute the call. However, there's no granular role check (e.g., "only owner, not session key holder"). The assumption is that topUp would be called through a validator that requires owner auth, not an agent session key.

**Recommendation**: Document this trust assumption. If session keys can call arbitrary functions on installed modules, consider adding an explicit owner check.

---

## Code Maturity Score

| Category | Score | Notes |
|----------|-------|-------|
| Testing | 9/10 | 24 tests (3 fuzz), 97.56% line coverage, 85.71% branch |
| Documentation | 9/10 | NatSpec on all functions, clear comments, README |
| Access Control | 8/10 | Relies on Kernel's execution flow. topUp trust assumption noted. |
| Error Handling | 10/10 | Custom errors with context (token, spent, remaining) |
| Gas Optimization | 7/10 | Loop-based design, storage-heavy. Acceptable for hook pattern. |
| Dependencies | 9/10 | Only Kernel interfaces + Solady ERC20. Minimal surface. |
| **Overall** | **8.7/10** | |

### Coverage
```
╭-------------------------------+----------------+------------------+----------------+----------------╮
| File                          | % Lines        | % Statements     | % Branches     | % Funcs        |
+=====================================================================================================+
| src/AgentSpendingLimit.sol    | 97.56% (80/82) | 96.33% (105/109) | 85.71% (18/21) | 90.00% (9/10)  |
╰-------------------------------+----------------+------------------+----------------+----------------╯
```

---

## Slither Summary (our code only)

| Detector | Severity | Status |
|----------|----------|--------|
| locked-ether | Medium | ✅ FIXED |
| divide-before-multiply | Medium | Intentional (documented) |
| calls-loop | Low | Expected (documented) |
| timestamp | Info | Intentional (documented) |
| pragma | Info | Lib versions differ (expected with dependencies) |

---

## Methodology

Trail of Bits building-secure-contracts framework:
1. Entry point analysis (Slither + manual)
2. Guidelines review (11 assessment areas)
3. Token integration analysis (N/A — hook doesn't hold tokens)
4. Code maturity scoring
5. Property-based test coverage via fuzz tests

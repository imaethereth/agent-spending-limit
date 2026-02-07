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

---

## Kernel Integration Analysis

Traced the full execution flow through Kernel v3.3 (`Kernel.sol`, `HookManager.sol`, `ExecLib.sol`).

### Execution Flow

```
EntryPoint → Kernel.validateUserOp() → stores hook in executionHook[userOpHash]
EntryPoint → Kernel.executeUserOp():
    1. hook.preCheck(msg.sender, value, callData)    ← snapshots balances
    2. ExecLib.executeDelegatecall(this, callData)    ← ACTUAL EXECUTION
    3. hook.postCheck(context)                        ← enforces limits
```

**Key**: Hooks are called via regular `call()` (not `delegatecall`), so `msg.sender` in hook = Kernel account address. ✅ Correct assumption.

### 🔴 CRITICAL: topUp() Callable Between preCheck and postCheck

**The attack vector**: During step 2 (actual execution), the Kernel executes arbitrary calldata via `delegatecall` to itself. If a **batch execution** includes:
1. Transfer 10 ETH to attacker
2. Call `hook.topUp(0, 10 ether)` on our hook contract

Then the flow becomes:
- `preCheck`: snapshots balance = 100 ETH
- Execution: sends 10 ETH out, then tops up allowance by 10 ETH
- `postCheck`: sees 90 ETH balance, spent = 10 ETH, but allowance was refreshed by topUp

**This defeats the spending limit entirely.** An agent with a session key could call topUp on the hook as part of a batch, resetting their own allowance before postCheck runs.

**Fix**: `topUp()` must not be callable during hook execution. Options:
1. Add a reentrancy guard (lock during preCheck→postCheck)
2. Restrict topUp to only be callable through a specific validator (e.g., root validator only)
3. Remove topUp entirely and require reinstall to change allowances

**Severity**: CRITICAL — completely bypasses spending limits if attacker can batch transactions

---

### 🟡 MEDIUM: executeUserOp Uses delegatecall

`Kernel.executeUserOp()` calls `ExecLib.executeDelegatecall(address(this), callData)`. This means the execution runs in the Kernel's context. The hook's preCheck/postCheck run via external calls, so storage is isolated. However:

The `delegatecall` means the Kernel could theoretically execute code that modifies its own storage to change the hook address mid-execution. This is a Kernel-level concern, not specific to our hook, but worth noting.

**Impact on us**: None directly — our hook's storage is separate.

---

### 🟡 MEDIUM: Hook Doesn't Inspect callData

Our `preCheck` ignores the `msgData` parameter entirely. It could inspect the calldata to:
- Detect if the batch includes a call to `topUp()` on itself
- Detect if the batch includes calls to `onUninstall()`
- Block specific function selectors

**Recommendation**: Consider adding calldata inspection in preCheck to detect self-referential calls to the hook contract.

---

### 🟢 LOW: No Protection Against Hook Removal Mid-Session

If the Kernel owner removes the hook (via `uninstallModule`), the hook's `onUninstall` is called which clears all limits. A compromised session key that has permission to manage modules could remove the hook entirely.

**Impact**: Session key scope — if session keys can call `installModule`/`uninstallModule`, they can bypass any hook. This is a Kernel configuration concern (session keys should not have module management permissions).

---

### 🟢 LOW: entryPoint msg.sender in preCheck

In the `executeUserOp` flow, `msg.sender` passed to `preCheck` is the EntryPoint address (since Kernel is called by EntryPoint). Our hook ignores this parameter, which is fine — we only use `msg.sender` (= Kernel address) for storage lookups, not the `msgSender` parameter.

---

## Methodology

Trail of Bits building-secure-contracts framework:
1. Entry point analysis (Slither + manual)
2. Guidelines review (11 assessment areas)
3. Token integration analysis (N/A — hook doesn't hold tokens)
4. Code maturity scoring
5. Property-based test coverage via fuzz tests

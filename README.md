# AgentSpendingLimit

> ERC-7579 hook module for Kernel v3 smart accounts. Time-based spending limits for AI agent wallets.

Built by [imaether.eth](https://imaether.eth.limo) ✨

## Why?

AI agents need bounded autonomy. The existing `SpendingLimit` hook in kernel-7579-plugins is missing critical features for real agent use:

| Feature | kernel-7579-plugins | AgentSpendingLimit |
|---------|--------------------|--------------------|
| Aggregate limits | ✅ | ✅ |
| Per-transaction limits | ❌ | ✅ |
| Time-based resets (daily/weekly) | ❌ | ✅ |
| Events for monitoring | ❌ | ✅ |
| View functions | ❌ | ✅ |
| Owner top-up without reinstall | ❌ | ✅ |
| Kernel v3.3 IHook compatible | ❌ (old 3-param postCheck) | ✅ |

## Install

```bash
forge install imaethereth/agent-spending-limit
```

## Usage

```solidity
// Configure: 5 ETH daily budget, max 1 ETH per tx
TokenLimit[] memory limits = new TokenLimit[](1);
limits[0] = TokenLimit({
    token: address(0),       // ETH
    allowance: 5 ether,
    maxAllowance: 5 ether,
    maxPerTx: 1 ether,
    periodSeconds: 86400,    // 1 day
    periodStart: 0           // starts now
});

// Install on Kernel smart account
kernel.installHook(address(hook), abi.encode(limits));
```

## Tests

```bash
forge test -v
# 24 tests, including 3 fuzz tests
```

## License

MIT

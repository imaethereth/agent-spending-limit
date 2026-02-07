// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IHook, IModule} from "kernel/src/interfaces/IERC7579Modules.sol";
import {MODULE_TYPE_HOOK} from "kernel/src/types/Constants.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

/// @title AgentSpendingLimit — Time-based spending limits for AI agent wallets
/// @author imaether.eth (Aether ✨)
/// @notice ERC-7579 hook module for Kernel v3 smart accounts.
///         Enforces per-token spending limits with automatic time-based resets.
///         Built for AI agents that need bounded autonomy.
/// @dev Improvements over kernel-7579-plugins/spendlingLimits:
///      - Time-based budget resets (daily/weekly/monthly/custom)
///      - Per-transaction limits alongside aggregate limits
///      - Events for off-chain monitoring
///      - View functions for agent self-awareness
///      - Owner top-up without reinstall
///      - Compatible with current Kernel v3.3 IHook interface (1-param postCheck)

/// @notice Configuration for a single token's spending limit
struct TokenLimit {
    address token;          // address(0) = native ETH
    uint256 allowance;      // remaining allowance in current period
    uint256 maxAllowance;   // total allowance per period (for resets)
    uint256 maxPerTx;       // max spend per single transaction (0 = no per-tx limit)
    uint256 periodSeconds;  // reset period in seconds (0 = no reset, one-time budget)
    uint256 periodStart;    // timestamp when current period started
}

contract AgentSpendingLimit is IHook {
    // ═══════════════════════════════════════════════════════════════
    //                          STORAGE
    // ═══════════════════════════════════════════════════════════════

    /// @notice Number of token limits configured per account
    mapping(address account => uint256) public limitCount;

    /// @notice Reentrancy lock: true when hook is executing (preCheck→postCheck)
    mapping(address account => bool) public hookExecuting;

    /// @notice Token limit data: limitData[index][account]
    mapping(uint256 index => mapping(address account => TokenLimit)) public limitData;

    // ═══════════════════════════════════════════════════════════════
    //                          EVENTS
    // ═══════════════════════════════════════════════════════════════

    event LimitsInstalled(address indexed account, uint256 count);
    event LimitsUninstalled(address indexed account);
    event SpendRecorded(address indexed account, address indexed token, uint256 amount, uint256 remaining);
    event PeriodReset(address indexed account, address indexed token, uint256 newAllowance);
    event AllowanceTopUp(address indexed account, address indexed token, uint256 addedAmount, uint256 newAllowance);

    // ═══════════════════════════════════════════════════════════════
    //                          ERRORS
    // ═══════════════════════════════════════════════════════════════

    error ExceedsAllowance(address token, uint256 spent, uint256 remaining);
    error ExceedsPerTxLimit(address token, uint256 spent, uint256 maxPerTx);
    error AlreadyInstalled();
    error NotInstalled();
    error NoEtherAccepted();
    error ReentrantCall();

    // ═══════════════════════════════════════════════════════════════
    //                     MODULE LIFECYCLE
    // ═══════════════════════════════════════════════════════════════

    /// @notice Install the hook with token limit configurations
    /// @dev Data encoding: abi.encode(TokenLimit[])
    function onInstall(bytes calldata data) external payable override {
        if (limitCount[msg.sender] != 0) revert AlreadyInstalled();

        TokenLimit[] memory limits = abi.decode(data, (TokenLimit[]));

        for (uint256 i = 0; i < limits.length; i++) {
            TokenLimit memory lim = limits[i];
            // Set period start to now if using time-based resets
            if (lim.periodSeconds > 0 && lim.periodStart == 0) {
                lim.periodStart = block.timestamp;
            }
            limitData[i][msg.sender] = lim;
        }

        limitCount[msg.sender] = limits.length;
        emit LimitsInstalled(msg.sender, limits.length);
    }

    /// @notice Uninstall the hook, clearing all limit data
    /// @dev Cannot be called during hook execution (prevents bypass via batch uninstall)
    function onUninstall(bytes calldata) external payable override {
        if (hookExecuting[msg.sender]) revert ReentrantCall();
        uint256 count = limitCount[msg.sender];
        if (count == 0) revert NotInstalled();

        for (uint256 i = 0; i < count; i++) {
            delete limitData[i][msg.sender];
        }
        delete limitCount[msg.sender];

        emit LimitsUninstalled(msg.sender);
    }

    function isModuleType(uint256 typeID) external pure override returns (bool) {
        return typeID == MODULE_TYPE_HOOK;
    }

    function isInitialized(address smartAccount) external view override returns (bool) {
        return limitCount[smartAccount] != 0;
    }

    // ═══════════════════════════════════════════════════════════════
    //                      HOOK EXECUTION
    // ═══════════════════════════════════════════════════════════════

    /// @notice Called before each transaction — snapshots balances and locks
    function preCheck(
        address,
        uint256,
        bytes calldata
    ) external payable override returns (bytes memory) {
        uint256 count = limitCount[msg.sender];
        if (count == 0) return "";

        // Lock to prevent topUp/onUninstall during execution
        hookExecuting[msg.sender] = true;

        uint256[] memory balances = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            TokenLimit storage lim = limitData[i][msg.sender];

            // Auto-reset period if elapsed
            _maybeResetPeriod(lim, msg.sender);

            if (lim.token == address(0)) {
                balances[i] = msg.sender.balance;
            } else {
                balances[i] = ERC20(lim.token).balanceOf(msg.sender);
            }
        }

        return abi.encode(balances);
    }

    /// @notice Called after each transaction — enforces limits and unlocks
    /// @dev Uses 1-param postCheck signature (Kernel v3.3 compatible)
    function postCheck(bytes calldata hookData) external payable override {
        uint256 count = limitCount[msg.sender];
        if (count == 0) return;

        uint256[] memory preBalances = abi.decode(hookData, (uint256[]));

        for (uint256 i = 0; i < count; i++) {
            TokenLimit storage lim = limitData[i][msg.sender];

            uint256 currentBalance;
            if (lim.token == address(0)) {
                currentBalance = msg.sender.balance;
            } else {
                currentBalance = ERC20(lim.token).balanceOf(msg.sender);
            }

            // Balance increased or unchanged — no spend
            if (currentBalance >= preBalances[i]) continue;

            uint256 spent = preBalances[i] - currentBalance;

            // Check per-tx limit
            if (lim.maxPerTx > 0 && spent > lim.maxPerTx) {
                revert ExceedsPerTxLimit(lim.token, spent, lim.maxPerTx);
            }

            // Check aggregate allowance
            if (spent > lim.allowance) {
                revert ExceedsAllowance(lim.token, spent, lim.allowance);
            }

            lim.allowance -= spent;
            emit SpendRecorded(msg.sender, lim.token, spent, lim.allowance);
        }

        // Unlock after enforcement
        hookExecuting[msg.sender] = false;
    }

    // ═══════════════════════════════════════════════════════════════
    //                     OWNER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Top up an allowance without reinstalling
    /// @dev Called by the smart account itself (msg.sender = account).
    ///      Cannot be called during hook execution (prevents session key bypass via batch).
    function topUp(uint256 index, uint256 amount) external {
        if (hookExecuting[msg.sender]) revert ReentrantCall();
        uint256 count = limitCount[msg.sender];
        if (count == 0) revert NotInstalled();
        require(index < count, "Invalid index");

        TokenLimit storage lim = limitData[index][msg.sender];
        lim.allowance += amount;

        // Don't exceed max allowance per period
        if (lim.allowance > lim.maxAllowance) {
            lim.allowance = lim.maxAllowance;
        }

        emit AllowanceTopUp(msg.sender, lim.token, amount, lim.allowance);
    }

    // ═══════════════════════════════════════════════════════════════
    //                      VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Get remaining allowance for a token (with period reset applied)
    function getRemainingAllowance(address account, uint256 index) external view returns (
        address token,
        uint256 remaining,
        uint256 maxAllowance,
        uint256 periodSecondsLeft
    ) {
        TokenLimit memory lim = limitData[index][account];
        token = lim.token;
        maxAllowance = lim.maxAllowance;

        // Calculate as if period reset happened
        if (lim.periodSeconds > 0 && block.timestamp >= lim.periodStart + lim.periodSeconds) {
            remaining = lim.maxAllowance;
            periodSecondsLeft = lim.periodSeconds;
        } else {
            remaining = lim.allowance;
            if (lim.periodSeconds > 0) {
                uint256 elapsed = block.timestamp - lim.periodStart;
                periodSecondsLeft = lim.periodSeconds > elapsed ? lim.periodSeconds - elapsed : 0;
            }
        }
    }

    /// @notice Get all limits for an account
    function getAllLimits(address account) external view returns (TokenLimit[] memory) {
        uint256 count = limitCount[account];
        TokenLimit[] memory limits = new TokenLimit[](count);
        for (uint256 i = 0; i < count; i++) {
            limits[i] = limitData[i][account];
        }
        return limits;
    }

    // ═══════════════════════════════════════════════════════════════
    //                     ETH REJECTION
    // ═══════════════════════════════════════════════════════════════

    /// @notice Reject any ETH sent directly to this contract
    /// @dev Prevents locked ether. The hook contract itself should never hold funds.
    receive() external payable {
        revert NoEtherAccepted();
    }

    // ═══════════════════════════════════════════════════════════════
    //                       INTERNALS
    // ═══════════════════════════════════════════════════════════════

    /// @dev Reset allowance if the current period has elapsed
    function _maybeResetPeriod(TokenLimit storage lim, address account) internal {
        if (lim.periodSeconds == 0) return;
        if (block.timestamp < lim.periodStart + lim.periodSeconds) return;

        // Calculate how many full periods have elapsed and snap to boundary
        // Note: divide-before-multiply is intentional here — we want to truncate
        // partial periods and align periodStart to the nearest period boundary.
        // slither-disable-next-line divide-before-multiply
        uint256 elapsed = block.timestamp - lim.periodStart;
        uint256 periods = elapsed / lim.periodSeconds;
        lim.periodStart += periods * lim.periodSeconds;
        lim.allowance = lim.maxAllowance;

        emit PeriodReset(account, lim.token, lim.maxAllowance);
    }
}

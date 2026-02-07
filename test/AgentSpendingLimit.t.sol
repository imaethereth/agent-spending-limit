// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {AgentSpendingLimit, TokenLimit} from "../src/AgentSpendingLimit.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

/// @dev Mock ERC20 for testing
contract MockERC20 is ERC20 {
    function name() public pure override returns (string memory) { return "Mock"; }
    function symbol() public pure override returns (string memory) { return "MCK"; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract AgentSpendingLimitTest is Test {
    AgentSpendingLimit public hook;
    MockERC20 public token;

    address public agent = makeAddr("agent");     // the smart account
    address public attacker = makeAddr("attacker");

    uint256 constant ONE_DAY = 86400;
    uint256 constant ONE_ETH = 1 ether;

    function setUp() public {
        hook = new AgentSpendingLimit();
        token = new MockERC20();

        // Fund the "agent" account
        vm.deal(agent, 100 ether);
        token.mint(agent, 1000e18);
    }

    // ═══════════════════════════════════════════════════════════════
    //                      INSTALL / UNINSTALL
    // ═══════════════════════════════════════════════════════════════

    function test_Install() public {
        TokenLimit[] memory limits = _singleEthLimit(10 ether, 1 ether, ONE_DAY);

        vm.prank(agent);
        hook.onInstall(abi.encode(limits));

        assertTrue(hook.isInitialized(agent));
        assertEq(hook.limitCount(agent), 1);
    }

    function test_InstallMultipleTokens() public {
        TokenLimit[] memory limits = new TokenLimit[](2);
        limits[0] = TokenLimit({
            token: address(0),
            allowance: 5 ether,
            maxAllowance: 5 ether,
            maxPerTx: 1 ether,
            periodSeconds: ONE_DAY,
            periodStart: 0
        });
        limits[1] = TokenLimit({
            token: address(token),
            allowance: 100e18,
            maxAllowance: 100e18,
            maxPerTx: 0,
            periodSeconds: ONE_DAY * 7,
            periodStart: 0
        });

        vm.prank(agent);
        hook.onInstall(abi.encode(limits));

        assertEq(hook.limitCount(agent), 2);
    }

    function test_RevertDoubleInstall() public {
        TokenLimit[] memory limits = _singleEthLimit(10 ether, 0, 0);

        vm.prank(agent);
        hook.onInstall(abi.encode(limits));

        vm.prank(agent);
        vm.expectRevert(AgentSpendingLimit.AlreadyInstalled.selector);
        hook.onInstall(abi.encode(limits));
    }

    function test_Uninstall() public {
        _installEthLimit(10 ether, 0, 0);

        vm.prank(agent);
        hook.onUninstall("");

        assertFalse(hook.isInitialized(agent));
        assertEq(hook.limitCount(agent), 0);
    }

    function test_RevertUninstallNotInstalled() public {
        vm.prank(agent);
        vm.expectRevert(AgentSpendingLimit.NotInstalled.selector);
        hook.onUninstall("");
    }

    // ═══════════════════════════════════════════════════════════════
    //                     AGGREGATE LIMITS
    // ═══════════════════════════════════════════════════════════════

    function test_AllowSpendWithinLimit() public {
        _installEthLimit(5 ether, 0, 0); // 5 ETH total, no per-tx limit, no reset

        // Simulate a tx that spends 2 ETH
        _simulateSpend(agent, 2 ether);

        // Check remaining
        (,uint256 remaining,,) = hook.getRemainingAllowance(agent, 0);
        assertEq(remaining, 3 ether);
    }

    function test_RevertExceedsAllowance() public {
        _installEthLimit(1 ether, 0, 0);

        // Try to spend 2 ETH — should revert in postCheck
        vm.prank(agent);
        bytes memory hookData = hook.preCheck(address(0), 0, "");

        // Simulate balance decrease
        vm.deal(agent, 98 ether); // was 100, now 98 = spent 2 ETH

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentSpendingLimit.ExceedsAllowance.selector,
                address(0),
                2 ether,
                1 ether
            )
        );
        hook.postCheck(hookData);
    }

    function test_MultipleSpends() public {
        _installEthLimit(5 ether, 0, 0);

        // Spend 2 ETH
        _simulateSpend(agent, 2 ether);

        // Spend 2 more
        _simulateSpend(agent, 2 ether);

        // Check remaining = 1
        (,uint256 remaining,,) = hook.getRemainingAllowance(agent, 0);
        assertEq(remaining, 1 ether);

        // Spend 2 more — should fail (only 1 left)
        vm.prank(agent);
        bytes memory hookData = hook.preCheck(address(0), 0, "");
        vm.deal(agent, agent.balance - 2 ether);

        vm.prank(agent);
        vm.expectRevert();
        hook.postCheck(hookData);
    }

    // ═══════════════════════════════════════════════════════════════
    //                      PER-TX LIMITS
    // ═══════════════════════════════════════════════════════════════

    function test_PerTxLimitAllows() public {
        _installEthLimit(10 ether, 3 ether, 0); // 10 total, 3 per tx

        _simulateSpend(agent, 2 ether); // 2 < 3, should pass
        (,uint256 remaining,,) = hook.getRemainingAllowance(agent, 0);
        assertEq(remaining, 8 ether);
    }

    function test_RevertPerTxLimitExceeded() public {
        _installEthLimit(10 ether, 1 ether, 0); // 10 total, 1 per tx

        vm.prank(agent);
        bytes memory hookData = hook.preCheck(address(0), 0, "");
        vm.deal(agent, agent.balance - 2 ether); // spend 2

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentSpendingLimit.ExceedsPerTxLimit.selector,
                address(0),
                2 ether,
                1 ether
            )
        );
        hook.postCheck(hookData);
    }

    // ═══════════════════════════════════════════════════════════════
    //                     TIME-BASED RESETS
    // ═══════════════════════════════════════════════════════════════

    function test_PeriodReset() public {
        _installEthLimit(5 ether, 0, ONE_DAY);

        // Spend 4 ETH
        _simulateSpend(agent, 4 ether);
        (,uint256 remaining,,) = hook.getRemainingAllowance(agent, 0);
        assertEq(remaining, 1 ether);

        // Warp past the period
        vm.warp(block.timestamp + ONE_DAY + 1);

        // View should show full allowance
        (,uint256 remainingAfter,,) = hook.getRemainingAllowance(agent, 0);
        assertEq(remainingAfter, 5 ether);

        // Actual preCheck should reset it
        vm.prank(agent);
        hook.preCheck(address(0), 0, "");

        // Now storage is reset too
        TokenLimit[] memory limits = hook.getAllLimits(agent);
        assertEq(limits[0].allowance, 5 ether);
    }

    function test_PeriodResetMultiplePeriods() public {
        _installEthLimit(5 ether, 0, ONE_DAY);

        _simulateSpend(agent, 5 ether);

        // Warp 3 days ahead — should still just reset to max
        vm.warp(block.timestamp + ONE_DAY * 3 + 1);

        vm.prank(agent);
        hook.preCheck(address(0), 0, "");

        TokenLimit[] memory limits = hook.getAllLimits(agent);
        assertEq(limits[0].allowance, 5 ether);
    }

    function test_NoPeriodNoReset() public {
        _installEthLimit(5 ether, 0, 0); // periodSeconds = 0

        _simulateSpend(agent, 5 ether);

        vm.warp(block.timestamp + ONE_DAY * 365);

        // Still zero — no reset
        (,uint256 remaining,,) = hook.getRemainingAllowance(agent, 0);
        assertEq(remaining, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //                        TOP UP
    // ═══════════════════════════════════════════════════════════════

    function test_TopUp() public {
        _installEthLimit(5 ether, 0, 0);

        _simulateSpend(agent, 4 ether);
        (,uint256 remaining,,) = hook.getRemainingAllowance(agent, 0);
        assertEq(remaining, 1 ether);

        // Owner tops up 2 ETH
        vm.prank(agent);
        hook.topUp(0, 2 ether);

        (,uint256 afterTopUp,,) = hook.getRemainingAllowance(agent, 0);
        assertEq(afterTopUp, 3 ether);
    }

    function test_TopUpCappedAtMax() public {
        _installEthLimit(5 ether, 0, 0);

        // Top up 100 ETH — should cap at maxAllowance (5)
        vm.prank(agent);
        hook.topUp(0, 100 ether);

        (,uint256 remaining,,) = hook.getRemainingAllowance(agent, 0);
        assertEq(remaining, 5 ether);
    }

    function test_RevertTopUpNotInstalled() public {
        vm.prank(agent);
        vm.expectRevert(AgentSpendingLimit.NotInstalled.selector);
        hook.topUp(0, 1 ether);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    ERC20 TOKEN LIMITS
    // ═══════════════════════════════════════════════════════════════

    function test_ERC20SpendLimit() public {
        TokenLimit[] memory limits = new TokenLimit[](1);
        limits[0] = TokenLimit({
            token: address(token),
            allowance: 50e18,
            maxAllowance: 50e18,
            maxPerTx: 20e18,
            periodSeconds: ONE_DAY,
            periodStart: 0
        });

        vm.prank(agent);
        hook.onInstall(abi.encode(limits));

        // Simulate ERC20 spend (transfer out 15 tokens)
        vm.prank(agent);
        bytes memory hookData = hook.preCheck(address(0), 0, "");

        vm.prank(agent);
        token.transfer(attacker, 15e18);

        vm.prank(agent);
        hook.postCheck(hookData);

        (,uint256 remaining,,) = hook.getRemainingAllowance(agent, 0);
        assertEq(remaining, 35e18);
    }

    function test_ERC20PerTxRevert() public {
        TokenLimit[] memory limits = new TokenLimit[](1);
        limits[0] = TokenLimit({
            token: address(token),
            allowance: 100e18,
            maxAllowance: 100e18,
            maxPerTx: 10e18,
            periodSeconds: 0,
            periodStart: 0
        });

        vm.prank(agent);
        hook.onInstall(abi.encode(limits));

        vm.prank(agent);
        bytes memory hookData = hook.preCheck(address(0), 0, "");

        vm.prank(agent);
        token.transfer(attacker, 20e18); // exceeds 10e18 per-tx

        vm.prank(agent);
        vm.expectRevert();
        hook.postCheck(hookData);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    function test_GetRemainingAllowance() public {
        _installEthLimit(10 ether, 2 ether, ONE_DAY);

        (address tok, uint256 remaining, uint256 max, uint256 timeLeft) =
            hook.getRemainingAllowance(agent, 0);

        assertEq(tok, address(0));
        assertEq(remaining, 10 ether);
        assertEq(max, 10 ether);
        assertEq(timeLeft, ONE_DAY); // just installed
    }

    function test_GetAllLimits() public {
        _installEthLimit(10 ether, 2 ether, ONE_DAY);

        TokenLimit[] memory limits = hook.getAllLimits(agent);
        assertEq(limits.length, 1);
        assertEq(limits[0].maxAllowance, 10 ether);
        assertEq(limits[0].maxPerTx, 2 ether);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    BALANCE INCREASE (no-op)
    // ═══════════════════════════════════════════════════════════════

    function test_BalanceIncreaseSkipped() public {
        _installEthLimit(1 ether, 0, 0);

        vm.prank(agent);
        bytes memory hookData = hook.preCheck(address(0), 0, "");

        // Balance increases (received ETH)
        vm.deal(agent, agent.balance + 5 ether);

        vm.prank(agent);
        hook.postCheck(hookData); // should not revert

        // Allowance unchanged
        (,uint256 remaining,,) = hook.getRemainingAllowance(agent, 0);
        assertEq(remaining, 1 ether);
    }

    // ═══════════════════════════════════════════════════════════════
    //                  REENTRANCY PROTECTION
    // ═══════════════════════════════════════════════════════════════

    function test_RevertTopUpDuringExecution() public {
        _installEthLimit(5 ether, 0, 0);

        // Simulate: preCheck called (hook is now locked)
        vm.prank(agent);
        hook.preCheck(address(0), 0, "");

        // Now try topUp — should revert because hook is executing
        vm.prank(agent);
        vm.expectRevert(AgentSpendingLimit.ReentrantCall.selector);
        hook.topUp(0, 10 ether);

        // Cleanup: call postCheck to unlock
        // (balance unchanged, so no spend recorded)
        vm.prank(agent);
        hook.postCheck(abi.encode(new uint256[](1)));
    }

    function test_RevertUninstallDuringExecution() public {
        _installEthLimit(5 ether, 0, 0);

        vm.prank(agent);
        hook.preCheck(address(0), 0, "");

        vm.prank(agent);
        vm.expectRevert(AgentSpendingLimit.ReentrantCall.selector);
        hook.onUninstall("");

        // Cleanup
        vm.prank(agent);
        hook.postCheck(abi.encode(new uint256[](1)));
    }

    function test_TopUpWorksOutsideExecution() public {
        _installEthLimit(5 ether, 0, 0);

        _simulateSpend(agent, 3 ether);

        // hookExecuting should be false after postCheck
        assertFalse(hook.hookExecuting(agent));

        // topUp should work fine
        vm.prank(agent);
        hook.topUp(0, 2 ether);

        (,uint256 remaining,,) = hook.getRemainingAllowance(agent, 0);
        assertEq(remaining, 4 ether);
    }

    // ═══════════════════════════════════════════════════════════════
    //                      FUZZ TESTS
    // ═══════════════════════════════════════════════════════════════

    function testFuzz_SpendWithinLimit(uint256 allowance, uint256 spend) public {
        allowance = bound(allowance, 1, 100 ether);
        spend = bound(spend, 0, allowance);

        _installEthLimit(allowance, 0, 0);
        _simulateSpend(agent, spend);

        (,uint256 remaining,,) = hook.getRemainingAllowance(agent, 0);
        assertEq(remaining, allowance - spend);
    }

    function testFuzz_SpendExceedsReverts(uint256 allowance, uint256 spend) public {
        allowance = bound(allowance, 1, 50 ether);
        spend = bound(spend, allowance + 1, 100 ether);

        _installEthLimit(allowance, 0, 0);

        vm.prank(agent);
        bytes memory hookData = hook.preCheck(address(0), 0, "");
        vm.deal(agent, agent.balance - spend);

        vm.prank(agent);
        vm.expectRevert();
        hook.postCheck(hookData);
    }

    function testFuzz_PeriodReset(uint256 period, uint256 warpTime) public {
        period = bound(period, 1 hours, 365 days);
        warpTime = bound(warpTime, period, period * 10);

        _installEthLimit(5 ether, 0, period);
        _simulateSpend(agent, 5 ether);

        vm.warp(block.timestamp + warpTime);

        // After period elapses, view shows full reset
        (,uint256 remaining,,) = hook.getRemainingAllowance(agent, 0);
        assertEq(remaining, 5 ether);
    }

    // ═══════════════════════════════════════════════════════════════
    //                       HELPERS
    // ═══════════════════════════════════════════════════════════════

    function _singleEthLimit(uint256 allowance, uint256 maxPerTx, uint256 period)
        internal pure returns (TokenLimit[] memory)
    {
        TokenLimit[] memory limits = new TokenLimit[](1);
        limits[0] = TokenLimit({
            token: address(0),
            allowance: allowance,
            maxAllowance: allowance,
            maxPerTx: maxPerTx,
            periodSeconds: period,
            periodStart: 0
        });
        return limits;
    }

    function _installEthLimit(uint256 allowance, uint256 maxPerTx, uint256 period) internal {
        TokenLimit[] memory limits = _singleEthLimit(allowance, maxPerTx, period);
        vm.prank(agent);
        hook.onInstall(abi.encode(limits));
    }

    function _simulateSpend(address account, uint256 amount) internal {
        vm.prank(account);
        bytes memory hookData = hook.preCheck(address(0), 0, "");

        vm.deal(account, account.balance - amount);

        vm.prank(account);
        hook.postCheck(hookData);
    }
}

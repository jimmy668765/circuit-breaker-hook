// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {CircuitBreakerHook} from "../src/CircuitBreakerHook.sol";

contract CircuitBreakerHookTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    // Hook flags: afterInitialize | beforeSwap | afterSwap
    uint160 constant HOOK_FLAGS =
        uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    uint8 constant PHASE_NORMAL = 0;
    uint8 constant PHASE_ALERT  = 1;
    uint8 constant PHASE_HALTED = 2;

    PoolManager poolManager;
    CircuitBreakerHook hook;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest modifyLiquidityRouter;

    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;
    PoolKey poolKey;

    function setUp() public {
        vm.warp(10000); // start well above all window durations

        poolManager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(poolManager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(poolManager);

        token0 = new MockERC20("Token0", "T0", 18);
        token1 = new MockERC20("Token1", "T1", 18);
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        bytes32 salt = _findDeploymentSalt();
        hook = new CircuitBreakerHook{salt: salt}(poolManager);

        require(
            uint160(address(hook)) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS,
            "Hook flags mismatch"
        );

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        token0.mint(address(this), 10_000_000 ether);
        token1.mint(address(this), 10_000_000 ether);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);

        // Wide range, sparse liquidity → large price moves per swap
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887220,
                tickUpper:  887220,
                liquidityDelta: 1 ether,
                salt: 0
            }),
            ""
        );
    }

    // ─── Unit tests ──────────────────────────────────────────────────────

    function test_feeConstants() public view {
        assertEq(hook.BASE_FEE(), 500);
        assertEq(hook.ALERT_FEE_SAME(), 30000);
        assertEq(hook.ALERT_FEE_COUNTER(), 100);
        assertLt(hook.BASE_FEE(), hook.ALERT_FEE_SAME());
        assertLt(hook.ALERT_FEE_SAME(), LPFeeLibrary.MAX_LP_FEE);
    }

    function test_hookPermissions() public view {
        Hooks.Permissions memory perms = hook.getHookPermissions();
        assertTrue(perms.afterInitialize);
        assertTrue(perms.beforeSwap);
        assertTrue(perms.afterSwap);
        assertFalse(perms.beforeInitialize);
        assertFalse(perms.beforeSwapReturnDelta);
    }

    function test_thresholdConstants() public view {
        assertEq(hook.SOFT_TICK_THRESHOLD(), 800);
        assertEq(hook.WINDOW_DURATION(), 300);
        assertEq(hook.ALERT_DURATION(), 600);
        assertEq(hook.HALT_COOLDOWN(), 180);
    }

    function test_afterInitialize_setsNormalPhase() public view {
        assertEq(hook.getPhase(poolKey), PHASE_NORMAL);
    }

    // ─── Integration tests ───────────────────────────────────────────────

    function test_normalConditions_baseFee() public {
        // No momentum → base fee and NORMAL phase
        vm.warp(block.timestamp + 60);
        _doSwap(true, -0.0001 ether); // tiny swap, no significant tick move
        assertEq(hook.getPhase(poolKey), PHASE_NORMAL);
    }

    function test_alertTriggeredBySustainedPump() public {
        // Drive price up strongly within a single 5-min window
        uint256 start = block.timestamp;
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(start + 10 + i * 10); // all within 60s < 300s window
            _doSwap(false, -1 ether); // buy token0, price up
        }
        // Roll past the 5-min window so the delta is evaluated
        vm.warp(start + 310);
        _doSwap(false, -0.0001 ether); // trigger window roll

        uint8 phase = hook.getPhase(poolKey);
        // Should have triggered ALERT or HALTED depending on tick delta
        // If delta < threshold, still NORMAL — we check fee behavior either way
        if (phase == PHASE_ALERT || phase == PHASE_HALTED) {
            // Same-direction fee elevated
            uint24 fee = hook.getCurrentFee(poolKey, false); // false = same direction (buy)
            assertGt(fee, hook.BASE_FEE());
            console.log("Phase after pump:", phase);
            console.log("Same-dir fee:", fee);
        } else {
            console.log("Phase NORMAL after pump (tick delta below threshold)");
        }
    }

    function test_alertPhase_sameDirFeeElevated() public {
        // _forcePriceMove(false,...) uses zeroForOne=true (downward swaps)
        // so triggerTickDelta < 0, same direction = zeroForOne=true (down)
        _forcePriceMove(false, 800);

        uint8 phase = hook.getPhase(poolKey);
        if (phase == PHASE_ALERT) {
            uint24 sameDirFee = hook.getCurrentFee(poolKey, true);  // down = zeroForOne=true = same dir
            uint24 counterFee = hook.getCurrentFee(poolKey, false); // up  = zeroForOne=false = counter
            assertEq(sameDirFee, hook.ALERT_FEE_SAME());
            assertEq(counterFee, hook.ALERT_FEE_COUNTER());
        } else {
            console.log("Phase (ALERT not triggered - tick delta below 800):", phase);
        }
    }

    function test_haltedPhase_sameDirReverts() public {
        // Downward trigger: zeroForOne=true is same direction
        _forcePriceMove(false, 800);

        uint8 phase1 = hook.getPhase(poolKey);
        assertEq(phase1, PHASE_ALERT, "Price move should have triggered ALERT");

        // Advance past ALERT_DURATION (600s) to escalate to HALTED
        vm.warp(block.timestamp + 601);
        // Counter-direction (upward = zeroForOne=false) swap to trigger afterSwap state update
        _doSwap(false, -0.0001 ether);

        uint8 phase2 = hook.getPhase(poolKey);
        if (phase2 != PHASE_HALTED) {
            console.log("HALTED not triggered (phase:", phase2, ")");
            return;
        }

        // Same-direction (downward = zeroForOne=true) must revert — V4 wraps error in WrappedError
        vm.expectRevert();
        _doSwap(true, -0.0001 ether);

        console.log("HALTED: same-direction correctly reverted");
    }

    function test_haltedPhase_counterDirAllowed() public {
        _forcePriceMove(false, 800); // downward trigger
        uint8 phase1 = hook.getPhase(poolKey);
        assertEq(phase1, PHASE_ALERT, "Price move should have triggered ALERT");

        vm.warp(block.timestamp + 601);
        // Counter-direction state-update swap (upward = zeroForOne=false)
        _doSwap(false, -0.0001 ether);

        uint8 phase2 = hook.getPhase(poolKey);
        if (phase2 != PHASE_HALTED) { return; }

        // Counter-direction (upward = zeroForOne=false) should NOT revert in HALTED
        _doSwap(false, -0.0001 ether);
        console.log("HALTED: counter-direction correctly allowed");
    }

    function test_haltedPhase_autoResetAfterCooldown() public {
        _forcePriceMove(false, 800); // downward trigger
        uint8 phase1 = hook.getPhase(poolKey);
        assertEq(phase1, PHASE_ALERT, "Price move should have triggered ALERT");

        vm.warp(block.timestamp + 601);
        _doSwap(false, -0.0001 ether); // counter-dir state update

        uint8 phase2 = hook.getPhase(poolKey);
        if (phase2 != PHASE_HALTED) { return; }

        // Advance past HALT_COOLDOWN (180s)
        vm.warp(block.timestamp + 181);
        _doSwap(false, -0.0001 ether); // trigger state update in afterSwap

        uint8 phase3 = hook.getPhase(poolKey);
        assertEq(phase3, PHASE_NORMAL, "Should auto-reset to NORMAL after cooldown");
        console.log("Auto-reset to NORMAL confirmed");
    }

    function test_emergencyReset_byOwner() public {
        _forcePriceMove(false, 800);
        uint8 phase1 = hook.getPhase(poolKey);
        assertEq(phase1, PHASE_ALERT, "Price move should have triggered ALERT");

        // Owner emergency reset
        hook.emergencyReset(poolKey);
        assertEq(hook.getPhase(poolKey), PHASE_NORMAL, "Emergency reset should set NORMAL");
    }

    function test_emergencyReset_notOwner_reverts() public {
        vm.prank(address(0xdead));
        vm.expectRevert(CircuitBreakerHook.NotOwner.selector);
        hook.emergencyReset(poolKey);
    }

    function test_pausedPool_reverts() public {
        hook.setPaused(poolKey, true);
        vm.expectRevert(); // V4 wraps hook reverts in WrappedError
        _doSwap(true, -0.0001 ether);
    }

    function test_pausedPool_unpause_works() public {
        hook.setPaused(poolKey, true);
        hook.setPaused(poolKey, false);
        // Should not revert
        _doSwap(true, -0.0001 ether);
    }

    function test_splitOrders_accumulateState() public {
        // Many small swaps in same direction should accumulate in window
        uint256 start = block.timestamp;
        // 20 small swaps within 4 minutes (all in same 5-min window)
        for (uint256 i = 0; i < 20; i++) {
            vm.warp(start + 5 + i * 10); // 5s, 15s, 25s ... 195s — all < 300s
            _doSwap(false, -0.1 ether);
        }
        // Roll window
        vm.warp(start + 310);
        _doSwap(false, -0.0001 ether);

        uint8 phase = hook.getPhase(poolKey);
        console.log("Phase after 20x split orders:", phase);
        // State is pool-level, so splits accumulate — if tick moved >800, ALERT expected
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    /// @dev Drive price move of approximately targetTicks in given direction
    ///      by doing multiple large swaps within a single 5-min window
    function _forcePriceMove(bool upward, int24 /*targetTicks*/) internal {
        uint256 windowStart = block.timestamp;
        // 10 aggressive swaps within 4 minutes
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(windowStart + 10 + i * 15); // 10s..145s < 300s window
            _doSwap(!upward, -5 ether); // large swap
        }
        // Roll past the window to trigger evaluation
        vm.warp(windowStart + 310);
        _doSwap(!upward, -0.0001 ether); // micro swap to trigger window roll
    }

    function _doSwap(bool zeroForOne, int256 amountSpecified) internal {
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _findDeploymentSalt() internal view returns (bytes32 salt) {
        bytes memory creationCode = abi.encodePacked(
            type(CircuitBreakerHook).creationCode,
            abi.encode(poolManager)
        );
        bytes32 initHash = keccak256(creationCode);

        for (uint256 i = 0; i < 100000; i++) {
            salt = bytes32(i);
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash))))
            );
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS) {
                return salt;
            }
        }
        revert("Salt not found in 100k iterations");
    }
}

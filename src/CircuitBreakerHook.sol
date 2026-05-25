// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @title CircuitBreakerHook
/// @notice Uniswap V4 hook that implements an on-chain circuit breaker for meme token pools.
///
///         When price moves >8% in one direction within a 5-minute window:
///           ALERT phase: same-direction swaps taxed at 3%, counter-direction at 0.01%
///         If ALERT persists >10 minutes:
///           HALTED phase: same-direction swaps reverted, counter-direction at 0.01%
///         After 3-minute halt, auto-reset to NORMAL.
///
/// @dev Deployed on X Layer (OKX's L2) for the Build-X Hackathon 2026.
///      Hook address must encode flags: afterInitialize | beforeSwap | afterSwap
contract CircuitBreakerHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    IPoolManager public immutable poolManager;
    address public immutable owner;

    // ─── Fee parameters ───────────────────────────────────────────────────
    uint24 public constant BASE_FEE          = 500;   // 0.05% — normal market
    uint24 public constant ALERT_FEE_SAME    = 30000; // 3.00% — same direction during ALERT
    uint24 public constant ALERT_FEE_COUNTER = 100;   // 0.01% — counter direction (incentivize)

    // ─── Threshold parameters ─────────────────────────────────────────────
    // 8% price move ≈ 800 ticks  (ln(1.08) / ln(1.0001) ≈ 770, rounded up)
    int24  public constant SOFT_TICK_THRESHOLD = 800;
    uint32 public constant WINDOW_DURATION     = 300;  // 5 minutes
    uint32 public constant ALERT_DURATION      = 600;  // 10 minutes before escalation
    uint32 public constant HALT_COOLDOWN       = 180;  // 3 minutes halt period

    // ─── Phase constants ──────────────────────────────────────────────────
    uint8 constant PHASE_NORMAL = 0;
    uint8 constant PHASE_ALERT  = 1;
    uint8 constant PHASE_HALTED = 2;

    // ─── Per-pool state ───────────────────────────────────────────────────
    struct PoolState {
        uint8  phase;            // PHASE_NORMAL | PHASE_ALERT | PHASE_HALTED
        bool   paused;           // owner emergency kill switch
        int24  windowStartTick;  // tick at beginning of current 5-min window
        uint32 windowStartTime;  // timestamp when window started
        uint32 alertStartTime;   // timestamp when ALERT was entered
        uint32 haltStartTime;    // timestamp when HALTED was entered
        int24  triggerTickDelta; // tick delta that caused the trigger (encodes direction)
    }

    mapping(PoolId => PoolState) public poolStates;

    // ─── Errors ───────────────────────────────────────────────────────────
    error NotPoolManager();
    error NotOwner();
    error CircuitBreakerHalted();
    error MonitorPaused();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        owner = msg.sender;
    }

    // ─── Hook permissions ─────────────────────────────────────────────────

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize:               false,
            afterInitialize:                true,
            beforeAddLiquidity:             false,
            afterAddLiquidity:              false,
            beforeRemoveLiquidity:          false,
            afterRemoveLiquidity:           false,
            beforeSwap:                     true,
            afterSwap:                      true,
            beforeDonate:                   false,
            afterDonate:                    false,
            beforeSwapReturnDelta:          false,
            afterSwapReturnDelta:           false,
            afterAddLiquidityReturnDelta:   false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─── afterInitialize ──────────────────────────────────────────────────

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        external onlyPoolManager returns (bytes4)
    {
        PoolId id = key.toId();
        PoolState storage s = poolStates[id];
        s.phase = PHASE_NORMAL;
        s.windowStartTick = tick;
        s.windowStartTime = uint32(block.timestamp);
        return IHooks.afterInitialize.selector;
    }

    // ─── beforeSwap ───────────────────────────────────────────────────────

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId id = key.toId();
        PoolState storage s = poolStates[id];

        if (s.paused) revert MonitorPaused();

        uint8 phase = _currentPhase(s);

        if (phase == PHASE_HALTED) {
            if (_isSameDirection(params.zeroForOne, s.triggerTickDelta)) {
                revert CircuitBreakerHalted();
            }
            return (
                IHooks.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                ALERT_FEE_COUNTER | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
        }

        if (phase == PHASE_ALERT) {
            uint24 fee = _isSameDirection(params.zeroForOne, s.triggerTickDelta)
                ? ALERT_FEE_SAME
                : ALERT_FEE_COUNTER;
            return (
                IHooks.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                fee | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
        }

        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            BASE_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    // ─── afterSwap ────────────────────────────────────────────────────────

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        PoolId id = key.toId();
        (, int24 currentTick,,) = poolManager.getSlot0(id);
        _updateState(id, currentTick);
        return (IHooks.afterSwap.selector, 0);
    }

    // ─── Internal: phase resolution ───────────────────────────────────────

    function _currentPhase(PoolState storage s) internal view returns (uint8) {
        if (s.phase == PHASE_HALTED) {
            if (block.timestamp >= uint256(s.haltStartTime) + HALT_COOLDOWN) {
                return PHASE_NORMAL; // expired, treat as NORMAL (storage reset in afterSwap)
            }
            return PHASE_HALTED;
        }
        if (s.phase == PHASE_ALERT) {
            if (block.timestamp >= uint256(s.alertStartTime) + ALERT_DURATION) {
                return PHASE_HALTED; // escalate (storage update in afterSwap)
            }
            return PHASE_ALERT;
        }
        return PHASE_NORMAL;
    }

    // ─── Internal: state update ───────────────────────────────────────────

    function _updateState(PoolId id, int24 currentTick) internal {
        PoolState storage s = poolStates[id];
        uint32 now32 = uint32(block.timestamp);

        // Auto-expire phases based on time
        if (s.phase == PHASE_HALTED && now32 >= s.haltStartTime + HALT_COOLDOWN) {
            s.phase = PHASE_NORMAL;
            s.windowStartTick = currentTick;
            s.windowStartTime = now32;
            return;
        }
        if (s.phase == PHASE_ALERT && now32 >= s.alertStartTime + ALERT_DURATION) {
            s.phase = PHASE_HALTED;
            s.haltStartTime = now32;
            return;
        }

        // Roll measurement window every 5 minutes
        if (now32 - s.windowStartTime >= WINDOW_DURATION) {
            int24 windowDelta = currentTick - s.windowStartTick;
            int24 absDelta = windowDelta >= 0 ? windowDelta : -windowDelta;

            if (absDelta >= SOFT_TICK_THRESHOLD && s.phase == PHASE_NORMAL) {
                s.phase = PHASE_ALERT;
                s.alertStartTime = now32;
                s.triggerTickDelta = windowDelta;
            } else if (s.phase == PHASE_ALERT) {
                // Price has stabilized back — reset to normal if delta is small
                if (absDelta < SOFT_TICK_THRESHOLD) {
                    s.phase = PHASE_NORMAL;
                }
            }

            s.windowStartTick = currentTick;
            s.windowStartTime = now32;
        }
    }

    // ─── Internal: direction check ────────────────────────────────────────

    function _isSameDirection(bool zeroForOne, int24 triggerTickDelta) internal pure returns (bool) {
        // triggerTickDelta < 0: price fell (downward dump) — zeroForOne=true continues dump
        // triggerTickDelta > 0: price rose (upward pump) — zeroForOne=false continues pump
        if (triggerTickDelta < 0 && zeroForOne) return true;
        if (triggerTickDelta > 0 && !zeroForOne) return true;
        return false;
    }

    // ─── Owner controls ───────────────────────────────────────────────────

    /// @notice Emergency kill switch — disables circuit breaker logic for a pool
    function setPaused(PoolKey calldata key, bool paused) external onlyOwner {
        poolStates[key.toId()].paused = paused;
    }

    /// @notice Force-reset circuit breaker to NORMAL for a pool
    function emergencyReset(PoolKey calldata key) external onlyOwner {
        PoolId id = key.toId();
        PoolState storage s = poolStates[id];
        s.phase = PHASE_NORMAL;
        (, int24 currentTick,,) = poolManager.getSlot0(id);
        s.windowStartTick = currentTick;
        s.windowStartTime = uint32(block.timestamp);
    }

    // ─── View helpers ─────────────────────────────────────────────────────

    /// @notice Current effective phase (accounts for time-based auto-expiry)
    function getPhase(PoolKey calldata key) external view returns (uint8) {
        return _currentPhase(poolStates[key.toId()]);
    }

    /// @notice Current fee for a given swap direction (for UI)
    function getCurrentFee(PoolKey calldata key, bool zeroForOne) external view returns (uint24) {
        PoolState storage s = poolStates[key.toId()];
        if (s.paused) return BASE_FEE;
        uint8 phase = _currentPhase(s);
        if (phase == PHASE_HALTED) {
            if (_isSameDirection(zeroForOne, s.triggerTickDelta)) return type(uint24).max; // blocked
            return ALERT_FEE_COUNTER;
        }
        if (phase == PHASE_ALERT) {
            return _isSameDirection(zeroForOne, s.triggerTickDelta)
                ? ALERT_FEE_SAME
                : ALERT_FEE_COUNTER;
        }
        return BASE_FEE;
    }

    // ─── Stub hooks (unused) ──────────────────────────────────────────────

    function beforeInitialize(address, PoolKey calldata, uint160)
        external pure returns (bytes4) { return IHooks.beforeInitialize.selector; }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external pure returns (bytes4) { return IHooks.beforeAddLiquidity.selector; }

    function afterAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure returns (bytes4, BalanceDelta) { return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0)); }

    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external pure returns (bytes4) { return IHooks.beforeRemoveLiquidity.selector; }

    function afterRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure returns (bytes4, BalanceDelta) { return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0)); }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure returns (bytes4) { return IHooks.beforeDonate.selector; }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure returns (bytes4) { return IHooks.afterDonate.selector; }
}

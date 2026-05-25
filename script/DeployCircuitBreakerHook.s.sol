// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CircuitBreakerHook} from "../src/CircuitBreakerHook.sol";

/// @title DeployCircuitBreakerHook
/// @notice Deploy CircuitBreakerHook to X Layer mainnet (Chain ID: 196)
///
/// Usage:
///   forge script script/DeployCircuitBreakerHook.s.sol \
///     --rpc-url xlayer_mainnet \
///     --private-key $PRIVATE_KEY \
///     --broadcast
contract DeployCircuitBreakerHook is Script {
    uint256 constant XLAYER_CHAIN_ID = 196;

    // Official Uniswap V4 PoolManager on X Layer mainnet
    address constant POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;

    // Required hook flags: AFTER_INITIALIZE | BEFORE_SWAP | AFTER_SWAP = 0x10C0
    uint160 constant HOOK_FLAGS =
        uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    function run() external {
        require(block.chainid == XLAYER_CHAIN_ID, "Must deploy on X Layer mainnet (chainId 196)");

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console.log("=== CircuitBreakerHook Deployment ===");
        console.log("Network:     X Layer mainnet (Chain ID: 196)");
        console.log("Deployer:    ", deployer);
        console.log("PoolManager: ", POOL_MANAGER);

        IPoolManager poolManager = IPoolManager(POOL_MANAGER);

        console.log("Mining CREATE2 salt...");
        // Foundry routes new Contract{salt:...} through Nick's CREATE2 factory:
        // 0x4e59b44847b379578588920cA78FbF26c0B4956C
        address CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        (bytes32 salt, address predictedAddr) = _findSalt(CREATE2_FACTORY, poolManager);
        console.log("Found salt:  ", vm.toString(salt));
        console.log("Hook address:", predictedAddr);

        vm.startBroadcast(deployerKey);

        CircuitBreakerHook hook = new CircuitBreakerHook{salt: salt}(poolManager);

        require(address(hook) == predictedAddr, "Deployed address mismatch");
        require(
            uint160(address(hook)) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS,
            "Hook flags mismatch"
        );

        console.log("Hook deployed at:", address(hook));
        console.log("Owner (deployer):", hook.owner());

        vm.stopBroadcast();

        console.log("\n=== Deployment Complete ===");
        console.log("Next steps:");
        console.log("1. Create a pool with PoolKey.fee = 0x800000 (DYNAMIC_FEE_FLAG)");
        console.log("2. Add liquidity via a router");
        console.log("3. Verify hook on X Layer explorer");
    }

    function _findSalt(address deployer, IPoolManager poolManager)
        internal
        view
        returns (bytes32 salt, address predicted)
    {
        bytes memory creationCode = abi.encodePacked(
            type(CircuitBreakerHook).creationCode,
            abi.encode(poolManager)
        );
        bytes32 initHash = keccak256(creationCode);

        for (uint256 i = 0; i < 200000; i++) {
            salt = bytes32(i);
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initHash))))
            );
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS) {
                return (salt, predicted);
            }
        }
        revert("Salt not found in 200k iterations");
    }
}

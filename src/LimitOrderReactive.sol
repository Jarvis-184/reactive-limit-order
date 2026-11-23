// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";

/// @title LimitOrderReactive: the watcher on Reactive Network (Lasna).
/// @notice Mirrors every order created on the destination-chain vault and
///         watches the pool's Swap events. The moment a Swap event shows the
///         pool price at or below an order's target, it requests a callback
///         that executes that order — no keeper, no cron, one event-to-callback
///         hop measured in seconds.
contract LimitOrderReactive is AbstractReactive {
    uint256 public constant ORDER_CREATED_TOPIC_0 =
        uint256(keccak256("OrderCreated(uint256,address,uint256,uint256)"));
    uint256 public constant ORDER_CANCELLED_TOPIC_0 = uint256(keccak256("OrderCancelled(uint256)"));
    uint256 public constant SWAP_TOPIC_0 =
        uint256(keccak256("Swap(address,uint256,uint256,uint256,uint256,bool)"));

    uint256 public immutable originChainId;
    address public immutable vault;
    address public immutable pool;
    address public owner;

    uint64 public callbackGasLimit = 1_000_000;

    struct MirroredOrder {
        uint256 targetPrice;
        bool active;
        bool dispatched;
    }

    mapping(uint256 => MirroredOrder) public orders;
    uint256[] public activeIds;
    uint256 public callbacksFired;

    event OrderMirrored(uint256 indexed orderId, uint256 targetPrice);
    event OrderUnmirrored(uint256 indexed orderId);
    event ExecutionDispatched(uint256 indexed orderId, uint256 observedPrice, uint256 targetPrice);

    modifier onlyOwner() {
        require(msg.sender == owner, "LimitOrderReactive: not owner");
        _;
    }

    /// @param originChainId_ Chain id of the vault and pool (e.g. 1301 = Unichain Sepolia).
    /// @param vault_ LimitOrderVault on the origin chain.
    /// @param pool_ MiniPool on the origin chain.
    constructor(uint256 originChainId_, address vault_, address pool_) payable {
        owner = msg.sender;
        originChainId = originChainId_;
        vault = vault_;
        pool = pool_;
        SYSTEM.subscribe(originChainId_, vault_, ORDER_CREATED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(originChainId_, vault_, ORDER_CANCELLED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(originChainId_, pool_, SWAP_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    /// @inheritdoc IReactive
    function react(LogRecord memory log_) external onlySystem {
        if (log_.chainId != originChainId) return;

        if (log_.topic0 == ORDER_CREATED_TOPIC_0 && log_.contractAddress == vault) {
            uint256 orderId = log_.topic1;
            (, uint256 targetPrice) = abi.decode(log_.data, (uint256, uint256));
            if (!orders[orderId].active) {
                activeIds.push(orderId);
            }
            orders[orderId] = MirroredOrder({targetPrice: targetPrice, active: true, dispatched: false});
            emit OrderMirrored(orderId, targetPrice);
        } else if (log_.topic0 == ORDER_CANCELLED_TOPIC_0 && log_.contractAddress == vault) {
            uint256 orderId = log_.topic1;
            orders[orderId].active = false;
            emit OrderUnmirrored(orderId);
        } else if (log_.topic0 == SWAP_TOPIC_0 && log_.contractAddress == pool) {
            (,, uint256 reserveA, uint256 reserveB,) = abi.decode(log_.data, (uint256, uint256, uint256, uint256, bool));
            if (reserveA == 0) return;
            uint256 price = (reserveB * 1e18) / reserveA;
            for (uint256 i = 0; i < activeIds.length; i++) {
                uint256 orderId = activeIds[i];
                MirroredOrder storage o = orders[orderId];
                if (o.active && !o.dispatched && price <= o.targetPrice) {
                    o.dispatched = true;
                    o.active = false;
                    callbacksFired += 1;
                    SYSTEM.requestCallbackV_1_0(
                        ISystemContract.CallbackConfiguration_V_1_0({
                            chainId: originChainId,
                            recipient: vault,
                            gasLimit: callbackGasLimit,
                            // The network injects this contract's address as the
                            // first argument for authentication on the vault side.
                            payload: abi.encodeWithSignature("execute(address,uint256,uint256)", address(0), orderId, price)
                        })
                    );
                    emit ExecutionDispatched(orderId, price, o.targetPrice);
                }
            }
        }
    }

    /// @notice Tune the gas handed to each execution callback.
    function setCallbackGasLimit(uint64 gasLimit_) external onlyOwner {
        callbackGasLimit = gasLimit_;
    }

    /// @notice Recover unused funding.
    function withdraw(uint256 amount_) external onlyOwner {
        (bool ok,) = owner.call{value: amount_}("");
        require(ok, "LimitOrderReactive: withdraw failed");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {TestToken} from "./TestToken.sol";
import {MiniPool} from "./MiniPool.sol";

/// @title LimitOrderVault: a token-A limit-order book on the destination chain.
/// @notice A trader deposits token A with a target price. No keeper bot, no
///         polling script: the LimitOrderReactive contract on Reactive Network
///         watches the pool's Swap events and fires execute() through the
///         callback proxy within seconds of the price crossing. Only that
///         reactive contract, delivered by the chain's callback proxy, can
///         execute; the vault re-checks the price on-chain at execution time.
contract LimitOrderVault is AbstractCallback {
    event OrderCreated(uint256 indexed orderId, address indexed trader, uint256 amountIn, uint256 targetPrice);
    event OrderCancelled(uint256 indexed orderId);
    event OrderExecuted(
        uint256 indexed orderId, address indexed trader, uint256 amountIn, uint256 amountOut, uint256 price, uint256 at
    );

    struct Order {
        address trader;
        uint256 amountIn;
        uint256 targetPrice; // B per A, 1e18-scaled: execute when pool price <= target
        bool active;
    }

    TestToken public immutable tokenA;
    TestToken public immutable tokenB;
    MiniPool public immutable pool;
    uint256 public orderCount;
    mapping(uint256 => Order) public orders;
    bool private executing;

    modifier noReenter() {
        require(!executing, "LimitOrderVault: reentrant");
        executing = true;
        _;
        executing = false;
    }

    /// @param callbackProxy_ The chain's Reactive Network callback proxy.
    /// @param reactive_ The LimitOrderReactive contract allowed to trigger executions.
    /// @param tokenA_ Token deposited by traders (sold into tokenB on execution).
    /// @param pool_ The pool whose Swap events drive the reactive contract.
    constructor(IPayable callbackProxy_, address reactive_, TestToken tokenA_, MiniPool pool_)
        AbstractCallback(callbackProxy_, reactive_)
    {
        require(address(callbackProxy_) != address(0) && reactive_ != address(0), "LimitOrderVault: zero authority");
        tokenA = tokenA_;
        tokenB = pool_.tokenB();
        pool = pool_;
    }

    /// @notice Deposit token A and set the target price. Emits the event the reactive contract mirrors.
    /// @param amountIn_ Token A amount to sell (approve this vault first).
    /// @param targetPrice_ Execute when the pool price of A (B per A, 1e18-scaled) falls to or below this.
    function createOrder(uint256 amountIn_, uint256 targetPrice_) external noReenter returns (uint256 orderId) {
        require(amountIn_ > 0, "LimitOrderVault: zero amount");
        require(targetPrice_ > 0, "LimitOrderVault: zero target");
        orderId = ++orderCount;
        orders[orderId] = Order({trader: msg.sender, amountIn: amountIn_, targetPrice: targetPrice_, active: true});
        tokenA.transferFrom(msg.sender, address(this), amountIn_);
        emit OrderCreated(orderId, msg.sender, amountIn_, targetPrice_);
    }

    /// @notice Cancel an open order and take the deposit back.
    function cancelOrder(uint256 orderId_) external noReenter {
        Order storage o = orders[orderId_];
        require(o.active, "LimitOrderVault: not active");
        require(o.trader == msg.sender, "LimitOrderVault: not trader");
        o.active = false;
        tokenA.transfer(o.trader, o.amountIn);
        emit OrderCancelled(orderId_);
    }

    /// @notice Reactive-callback only: execute the order through the pool.
    /// @dev The network injects the reactive contract address as `rvm_id`;
    ///      `observedPrice` is what the reactive contract saw in the Swap event,
    ///      re-verified here against live pool state before any funds move.
    function execute(address rvm_id, uint256 orderId_, uint256 observedPrice)
        external
        onlyServiceProvider
        onlyCallbackSender(rvm_id)
        noReenter
    {
        Order storage o = orders[orderId_];
        require(o.active, "LimitOrderVault: not active");
        uint256 price = pool.priceBperA();
        require(price <= o.targetPrice, "LimitOrderVault: price no longer crossing");
        require(observedPrice <= o.targetPrice, "LimitOrderVault: stale trigger");
        o.active = false;
        uint256 amountIn = o.amountIn;
        tokenA.approve(address(pool), amountIn);
        uint256 out = pool.swapAforB(amountIn, 1);
        tokenB.transfer(o.trader, out);
        emit OrderExecuted(orderId_, o.trader, amountIn, out, price, block.timestamp);
    }

    /// @notice Current pool price of token A (B per A, 1e18-scaled).
    function currentPrice() external view returns (uint256) {
        return pool.priceBperA();
    }
}

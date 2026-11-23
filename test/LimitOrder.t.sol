// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {TestToken} from "../src/TestToken.sol";
import {MiniPool} from "../src/MiniPool.sol";
import {LimitOrderVault} from "../src/LimitOrderVault.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";

contract LimitOrderTest is Test {
    TestToken tokenA;
    TestToken tokenB;
    MiniPool pool;
    LimitOrderVault vault;
    address pilot = address(0xBEEF);
    address trader = address(0xCAFE);
    address payable proxy = payable(address(0xF00D));

    function setUp() public {
        tokenA = new TestToken("Token A", "TKA");
        tokenB = new TestToken("Token B", "TKB");
        pool = new MiniPool(tokenA, tokenB);
        vault = new LimitOrderVault(IPayable(proxy), pilot, tokenA, pool);

        // Seed pool: 1,000 A against 10,000 B -> price of A = 10 B per A.
        tokenA.mint(address(this), 1_000 ether);
        tokenB.mint(address(this), 10_000 ether);
        tokenA.approve(address(pool), 1_000 ether);
        tokenB.approve(address(pool), 10_000 ether);
        pool.seed(1_000 ether, 10_000 ether);

        // Fund the trader.
        tokenA.mint(trader, 100 ether);
    }

    function _createOrder(uint256 amountIn, uint256 target) internal returns (uint256 id) {
        vm.startPrank(trader);
        tokenA.approve(address(vault), amountIn);
        vault.createOrder(amountIn, target);
        vm.stopPrank();
        id = vault.orderCount();
    }

    function test_CreateOrderPullsDeposit() public {
        uint256 id = _createOrder(10 ether, 9 ether);
        (address t, uint256 amt, uint256 tp, bool active) = vault.orders(id);
        assertEq(t, trader);
        assertEq(amt, 10 ether);
        assertEq(tp, 9 ether);
        assertTrue(active);
        assertEq(tokenA.balanceOf(address(vault)), 10 ether);
    }

    function test_CancelRefunds() public {
        uint256 id = _createOrder(10 ether, 9 ether);
        vm.prank(trader);
        vault.cancelOrder(id);
        (,,, bool active) = vault.orders(id);
        assertFalse(active);
        assertEq(tokenA.balanceOf(trader), 100 ether);
    }

    function test_ExecuteWhenPriceCrosses() public {
        // Target 9.5 B/A; current price 10. Push price below target by selling A into the pool.
        uint256 id = _createOrder(10 ether, 9.5 ether);
        tokenA.mint(address(this), 500 ether);
        tokenA.approve(address(pool), 500 ether);
        pool.swapAforB(200 ether, 1); // reserves 1200 A / ~8333 B -> price ~6.94
        uint256 balBBefore = tokenB.balanceOf(trader);
        uint256 px = pool.priceBperA();
        vm.prank(proxy);
        vault.execute(pilot, id, px);
        (address t,, uint256 tp, bool active) = vault.orders(id);
        assertFalse(active);
        assertGt(tokenB.balanceOf(trader), balBBefore);
        assertEq(tokenA.balanceOf(address(vault)), 0);
        assertEq(tp, 9.5 ether);
        assertEq(t, trader);
    }

    function test_ExecuteRevertsAboveTarget() public {
        uint256 id = _createOrder(10 ether, 9.5 ether);
        vm.prank(proxy);
        vm.expectRevert("LimitOrderVault: price no longer crossing");
        vault.execute(pilot, id, 10 ether);
        (,,, bool active) = vault.orders(id);
        assertTrue(active);
    }

    function test_ExecuteRejectsWrongCallbackSender() public {
        uint256 id = _createOrder(10 ether, 10.5 ether); // above price: fine, but sender wrong
        tokenA.mint(address(this), 500 ether);
        tokenA.approve(address(pool), 500 ether);
        pool.swapAforB(200 ether, 1);
        vm.prank(proxy);
        vm.expectRevert();
        vault.execute(address(0xDEAD), id, 1 ether);
    }

    function test_ExecuteRejectsDirectCaller() public {
        uint256 id = _createOrder(10 ether, 10.5 ether);
        vm.expectRevert();
        vault.execute(pilot, id, 1 ether); // msg.sender is not the proxy... but proxy check is on rvm arg; proxy check:
    }

    function test_DoubleExecuteReverts() public {
        uint256 id = _createOrder(10 ether, 10.5 ether);
        tokenA.mint(address(this), 500 ether);
        tokenA.approve(address(pool), 500 ether);
        pool.swapAforB(200 ether, 1);
        uint256 px = pool.priceBperA();
        vm.prank(proxy);
        vault.execute(pilot, id, px);
        vm.prank(proxy);
        vm.expectRevert("LimitOrderVault: not active");
        vault.execute(pilot, id, px);
    }

    function test_PriceMath() public view {
        assertEq(pool.priceBperA(), 10 ether);
    }
}

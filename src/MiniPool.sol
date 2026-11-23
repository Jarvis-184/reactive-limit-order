// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {TestToken} from "./TestToken.sol";

/// @title MiniPool: a minimal constant-product pair (x*y=k), zero fee.
/// @notice Exists to generate a live on-chain price feed for the demo. Every
///         swap emits reserves so off-chain watchers and the reactive contract
///         can price the pair from the event alone.
contract MiniPool {
    event Seeded(address indexed provider, uint256 amountA, uint256 amountB);
    event Swap(
        address indexed sender, uint256 amountIn, uint256 amountOut, uint256 reserveA, uint256 reserveB, bool aToB
    );

    TestToken public immutable tokenA;
    TestToken public immutable tokenB;
    address public immutable seeder;
    uint256 public reserveA;
    uint256 public reserveB;
    bool public seeded;

    constructor(TestToken tokenA_, TestToken tokenB_) {
        tokenA = tokenA_;
        tokenB = tokenB_;
        seeder = msg.sender;
    }

    /// @notice Seed the pool once. This sets the initial price.
    function seed(uint256 amountA_, uint256 amountB_) external {
        require(msg.sender == seeder, "MiniPool: not seeder");
        require(!seeded, "MiniPool: seeded");
        require(amountA_ > 0 && amountB_ > 0, "MiniPool: zero seed");
        seeded = true;
        reserveA = amountA_;
        reserveB = amountB_;
        tokenA.transferFrom(msg.sender, address(this), amountA_);
        tokenB.transferFrom(msg.sender, address(this), amountB_);
        emit Seeded(msg.sender, amountA_, amountB_);
    }

    /// @notice Spot price of token A, in token B, scaled by 1e18.
    function priceBperA() public view returns (uint256) {
        require(reserveA > 0, "MiniPool: empty");
        return (reserveB * 1e18) / reserveA;
    }

    /// @notice Swap token A for token B (pushes the price of A down).
    function swapAforB(uint256 amountIn_, uint256 minOut_) external returns (uint256 out) {
        out = _swap(tokenA, tokenB, amountIn_, minOut_, true);
    }

    /// @notice Swap token B for token A (pushes the price of A up).
    function swapBforA(uint256 amountIn_, uint256 minOut_) external returns (uint256 out) {
        out = _swap(tokenB, tokenA, amountIn_, minOut_, false);
    }

    function _swap(TestToken tin, TestToken tout, uint256 amountIn_, uint256 minOut_, bool aToB)
        internal
        returns (uint256 out)
    {
        require(seeded, "MiniPool: not seeded");
        require(amountIn_ > 0, "MiniPool: zero in");
        (uint256 rin, uint256 rout) = aToB ? (reserveA, reserveB) : (reserveB, reserveA);
        out = (amountIn_ * rout) / (rin + amountIn_);
        require(out >= minOut_ && out > 0, "MiniPool: slippage");
        tin.transferFrom(msg.sender, address(this), amountIn_);
        tout.transfer(msg.sender, out);
        if (aToB) {
            reserveA = rin + amountIn_;
            reserveB = rout - out;
        } else {
            reserveB = rin + amountIn_;
            reserveA = rout - out;
        }
        emit Swap(msg.sender, amountIn_, out, reserveA, reserveB, aToB);
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/**
 * @title ISellAdapter
 * @notice One venue a blank can sell through. The adapter pulls `_amountIn` of `_tokenIn` from the caller
 *         (the blank, which approved it for exactly that amount) and sends ETH to `_recipient`.
 * @dev The blank never trusts the return value: it measures the ETH it actually received.
 */
interface ISellAdapter {
  function swapExactTokenForETH(
    address _tokenIn,
    uint256 _amountIn,
    uint256 _minEthOut,
    address _recipient,
    bytes calldata _data
  ) external returns (uint256 _ethOut);
}

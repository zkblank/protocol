// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/**
 * @title ISwapAdapter
 * @notice One venue the BurnerRouter can buy through (a launchpad curve, a Uniswap pool, ...).
 * @dev The router never trusts the adapter's return value: it measures what the blank actually received.
 */
interface ISwapAdapter {
  /**
   * @notice Swap all attached ETH for `_tokenOut` and send the output straight to `_recipient`
   * @param _tokenOut The token to buy
   * @param _minAmountOut The minimum the recipient must receive
   * @param _recipient The blank that receives the tokens
   * @param _data Venue specific parameters (pool fee tier, curve id, ...)
   * @return _amountOut The amount the adapter reports as sent
   */
  function swapExactETHForToken(
    address _tokenOut,
    uint256 _minAmountOut,
    address _recipient,
    bytes calldata _data
  ) external payable returns (uint256 _amountOut);
}

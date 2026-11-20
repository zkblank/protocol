// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IERC20} from '@oz/interfaces/IERC20.sol';
import {ERC20} from '@oz/token/ERC20/ERC20.sol';

import {ISellAdapter} from 'interfaces/zkblank/ISellAdapter.sol';
import {ISwapAdapter} from 'interfaces/zkblank/ISwapAdapter.sol';

// Test and local-chain only: a mintable token and a fixed-price venue. Never deployed to a public network.

/// @dev A token the mock venue can mint
contract MockToken is ERC20 {
  constructor() ERC20('Test Token', 'XYZ') {}

  function mint(address _to, uint256 _amount) external {
    _mint(_to, _amount);
  }
}

/// @dev A venue with one fixed price both ways. `shortBy` makes it under-deliver while reporting the full amount
contract MockVenue is ISwapAdapter, ISellAdapter {
  uint256 public immutable TOKENS_PER_ETH;
  uint256 public shortBy;

  constructor(uint256 _tokensPerEth) {
    TOKENS_PER_ETH = _tokensPerEth;
  }

  receive() external payable {}

  function setShortBy(uint256 _shortBy) external {
    shortBy = _shortBy;
  }

  function swapExactETHForToken(
    address _tokenOut,
    uint256 _minAmountOut,
    address _recipient,
    bytes calldata
  ) external payable returns (uint256 _amountOut) {
    _amountOut = (msg.value * TOKENS_PER_ETH) / 1 ether;
    MockToken(_tokenOut).mint(_recipient, _amountOut - shortBy);
    if (_amountOut < _minAmountOut) _amountOut = _minAmountOut;
  }

  function swapExactTokenForETH(
    address _tokenIn,
    uint256 _amountIn,
    uint256 _minEthOut,
    address _recipient,
    bytes calldata
  ) external returns (uint256 _ethOut) {
    IERC20(_tokenIn).transferFrom(msg.sender, address(this), _amountIn);
    _ethOut = (_amountIn * 1 ether) / TOKENS_PER_ETH;
    (bool _ok,) = _recipient.call{value: _ethOut - shortBy}('');
    require(_ok, 'venue: send failed');
    if (_ethOut < _minEthOut) _ethOut = _minEthOut;
  }
}

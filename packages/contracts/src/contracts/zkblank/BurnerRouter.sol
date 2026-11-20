// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IERC20} from '@oz/interfaces/IERC20.sol';
import {ReentrancyGuard} from '@oz/utils/ReentrancyGuard.sol';

import {Constants} from 'contracts/lib/Constants.sol';
import {ProofLib} from 'contracts/lib/ProofLib.sol';

import {IPrivacyPool} from 'interfaces/IPrivacyPool.sol';
import {IBurnerRouter} from 'interfaces/zkblank/IBurnerRouter.sol';
import {ISwapAdapter} from 'interfaces/zkblank/ISwapAdapter.sol';

/**
 * @title BurnerRouter
 * @notice ZKBLANK Burner Mode: a private note pays for a swap whose output lands in a blank.
 * @dev No owner, no upgrade path, holds no funds between calls. The proof is verified by the pool itself:
 *      `PrivacyPool.withdraw` requires msg.sender == processooor (this contract) and the proof's context ==
 *      keccak256(abi.encode(withdrawal, scope)), which covers every field of `BuyData`.
 */
contract BurnerRouter is IBurnerRouter, ReentrancyGuard {
  using ProofLib for ProofLib.WithdrawProof;

  /// @notice Upper bound on the relay fee a proof may grant (10%)
  uint256 public constant MAX_RELAY_FEE_BPS = 1000;

  uint256 internal constant _BPS = 10_000;

  /// @dev The pool currently paying out to this router; ETH from anyone else is refused
  address private _payingPool;

  /// @notice Accepts ETH only from the pool being spent in the current `buy`
  receive() external payable {
    if (msg.sender != _payingPool) revert UnexpectedSender();
  }

  /// @inheritdoc IBurnerRouter
  function buy(
    IPrivacyPool _pool,
    IPrivacyPool.Withdrawal calldata _withdrawal,
    ProofLib.WithdrawProof calldata _proof
  ) external nonReentrant returns (uint256 _amountOut) {
    if (_withdrawal.processooor != address(this)) revert InvalidProcessooor();
    if (_pool.ASSET() != Constants.NATIVE_ASSET) revert NativePoolOnly();

    BuyData memory _d = abi.decode(_withdrawal.data, (BuyData));
    if (_d.blank == address(0) || _d.tokenOut == address(0) || _d.adapter == address(0)) revert ZeroAddress();
    if (block.timestamp > _d.deadline) revert DeadlinePassed();
    if (_d.relayFeeBPS > MAX_RELAY_FEE_BPS) revert RelayFeeTooHigh();

    // Spend the note: the pool verifies the proof, the context binding, the roots and the nullifier
    uint256 _value = _proof.withdrawnValue();
    uint256 _before = address(this).balance;
    _payingPool = address(_pool);
    _pool.withdraw(_withdrawal, _proof);
    _payingPool = address(0);
    if (address(this).balance - _before != _value) revert UnexpectedWithdrawnAmount();

    uint256 _fee = (_value * _d.relayFeeBPS) / _BPS;
    if (_fee > 0 && _d.feeRecipient == address(0)) revert ZeroAddress();
    uint256 _spent = _value - _fee;

    // Swap and measure what the blank actually received; the adapter's return value is not trusted
    uint256 _blankBefore = IERC20(_d.tokenOut).balanceOf(_d.blank);
    ISwapAdapter(_d.adapter).swapExactETHForToken{value: _spent}(_d.tokenOut, _d.minAmountOut, _d.blank, _d.adapterData);
    _amountOut = IERC20(_d.tokenOut).balanceOf(_d.blank) - _blankBefore;
    if (_amountOut < _d.minAmountOut) revert InsufficientOutput();

    if (_fee > 0) {
      (bool _ok,) = _d.feeRecipient.call{value: _fee}('');
      if (!_ok) revert FailedToSendFee();
    }

    emit BoughtIntoBlank(_pool, _d.blank, _d.tokenOut, _spent, _amountOut, _fee);
  }
}

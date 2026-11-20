// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {ProofLib} from 'contracts/lib/ProofLib.sol';
import {IPrivacyPool} from 'interfaces/IPrivacyPool.sol';

/**
 * @title IBurnerRouter
 * @notice Spends a private note into a swap whose output lands in a one-life wallet (a blank).
 * @dev Everything the trade depends on lives in `Withdrawal.data` as a `BuyData`. The pool checks that the proof's
 *      `context` equals keccak256(abi.encode(withdrawal, scope)), so a relayer can carry the trade but cannot
 *      change the token, the minimum out, the blank, the deadline, the venue or its own fee.
 */
interface IBurnerRouter {
  /**
   * @notice The trade a note holder signs into the proof
   * @param blank The one-life wallet that receives the bought tokens
   * @param tokenOut The token to buy
   * @param minAmountOut The minimum the blank must receive
   * @param deadline Last timestamp at which the trade may execute
   * @param adapter The venue adapter to swap through
   * @param adapterData Venue specific parameters, passed to the adapter as is
   * @param feeRecipient Who is paid the relay fee
   * @param relayFeeBPS The relay fee, in basis points of the withdrawn value
   */
  struct BuyData {
    address blank;
    address tokenOut;
    uint256 minAmountOut;
    uint256 deadline;
    address adapter;
    bytes adapterData;
    address feeRecipient;
    uint256 relayFeeBPS;
  }

  /**
   * @notice Emitted when a note pays for a buy into a blank
   * @param pool The pool the note was spent from
   * @param blank The blank that received the tokens
   * @param tokenOut The token bought
   * @param spent The ETH swapped, after the relay fee
   * @param amountOut The tokens the blank received
   * @param relayFee The ETH paid to the fee recipient
   */
  event BoughtIntoBlank(
    IPrivacyPool indexed pool,
    address indexed blank,
    address indexed tokenOut,
    uint256 spent,
    uint256 amountOut,
    uint256 relayFee
  );

  error InvalidProcessooor();
  error NativePoolOnly();
  error ZeroAddress();
  error DeadlinePassed();
  error RelayFeeTooHigh();
  error UnexpectedWithdrawnAmount();
  error InsufficientOutput();
  error FailedToSendFee();
  error UnexpectedSender();

  /**
   * @notice Spend a note into a buy that lands in a blank. Anyone may call it (normally a relayer)
   * @param _pool The native asset pool to spend from
   * @param _withdrawal Withdrawal with `processooor` = this router and `data` = abi.encode(BuyData)
   * @param _proof The withdrawal proof whose context binds `_withdrawal`
   * @return _amountOut The tokens the blank received
   */
  function buy(
    IPrivacyPool _pool,
    IPrivacyPool.Withdrawal calldata _withdrawal,
    ProofLib.WithdrawProof calldata _proof
  ) external returns (uint256 _amountOut);
}

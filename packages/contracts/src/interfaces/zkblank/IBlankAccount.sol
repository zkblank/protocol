// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/**
 * @title IBlankAccount
 * @notice A one-life wallet. It holds one position, then sells it back into the vault as a new private note
 *         and retires. It never needs gas: the relayer that submits the sell is paid out of the proceeds.
 */
interface IBlankAccount {
  /**
   * @notice What the blank's owner key signs (EIP-712) to sell its position back into the dark
   * @param tokenIn The token the blank holds
   * @param amountIn How much of it to sell
   * @param minEthOut The minimum ETH the sale must return, before the relay fee
   * @param deadline Last timestamp at which the sale may execute
   * @param adapter The venue to sell through
   * @param adapterData Venue specific parameters
   * @param precommitment Hash(nullifier, secret) of the note the proceeds become; only the owner knows its preimage
   * @param feeRecipient Who is paid the relay fee
   * @param relayFeeBPS The relay fee, in basis points of the ETH received
   */
  struct SellIntent {
    address tokenIn;
    uint256 amountIn;
    uint256 minEthOut;
    uint256 deadline;
    address adapter;
    bytes adapterData;
    uint256 precommitment;
    address feeRecipient;
    uint256 relayFeeBPS;
  }

  /**
   * @notice Emitted once, when the blank sells and retires
   * @param tokenIn The token sold
   * @param amountIn The amount sold
   * @param ethReceived The ETH the sale returned
   * @param relayFee The ETH paid to the fee recipient
   * @param commitment The new note's commitment, inserted in the vault's tree
   */
  event SoldBackIntoTheDark(
    address indexed tokenIn, uint256 amountIn, uint256 ethReceived, uint256 relayFee, uint256 commitment
  );

  error OnlyFactory();
  error Retired();
  error DeadlinePassed();
  error RelayFeeTooHigh();
  error InvalidSignature();
  error ZeroAddress();
  error InsufficientOutput();
  error FailedToSendFee();
  error UnexpectedSender();

  /// @notice Called once by the factory right after the clone is deployed
  function initialize(address _owner) external;

  /// @notice Sell the position into the vault as a new note and retire. Anyone may submit it (a relayer)
  function sell(SellIntent calldata _intent, bytes calldata _signature) external returns (uint256 _commitment);

  /// @notice The key that signs this blank's single sale
  function owner() external view returns (address);

  /// @notice True once the blank has sold; a retired blank can never act again
  function retired() external view returns (bool);

  /// @notice The EIP-712 digest the owner signs for `_intent`
  function intentDigest(SellIntent calldata _intent) external view returns (bytes32);
}

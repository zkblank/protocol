// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IERC20} from '@oz/interfaces/IERC20.sol';
import {SafeERC20} from '@oz/token/ERC20/utils/SafeERC20.sol';
import {ECDSA} from '@oz/utils/cryptography/ECDSA.sol';
import {EIP712} from '@oz/utils/cryptography/EIP712.sol';

import {IEntrypoint} from 'interfaces/IEntrypoint.sol';
import {IBlankAccount} from 'interfaces/zkblank/IBlankAccount.sol';
import {ISellAdapter} from 'interfaces/zkblank/ISellAdapter.sol';

/**
 * @title BlankAccount
 * @notice ZKBLANK's one-life wallet. Deployed as a minimal clone by BlankFactory only when it sells, so while it
 *         holds its position it is just an address with no code, no gas and no funding transaction.
 * @dev One sale, ever: `retired` is set before any external call. The signature binds every field of the intent,
 *      the chain and this blank's address (EIP-712 domain), so a relayer can carry the sale but not change it.
 *      Immutables live in the implementation's code and are shared by every clone.
 */
contract BlankAccount is IBlankAccount, EIP712 {
  using SafeERC20 for IERC20;

  bytes32 public constant SELL_INTENT_TYPEHASH = keccak256(
    'SellIntent(address tokenIn,uint256 amountIn,uint256 minEthOut,uint256 deadline,address adapter,bytes adapterData,uint256 precommitment,address feeRecipient,uint256 relayFeeBPS)'
  );

  /// @notice Upper bound on the relay fee an intent may grant (10%)
  uint256 public constant MAX_RELAY_FEE_BPS = 1000;

  uint256 internal constant _BPS = 10_000;

  /// @notice The factory allowed to initialize clones
  address public immutable FACTORY;

  /// @notice Where the proceeds are deposited as a new note
  IEntrypoint public immutable ENTRYPOINT;

  /// @inheritdoc IBlankAccount
  address public owner;

  /// @inheritdoc IBlankAccount
  bool public retired;

  /// @dev The venue paying ETH during the current sale; ETH from anyone else is refused
  address private _payingVenue;

  constructor(IEntrypoint _entrypoint) EIP712('ZKBLANK Blank', '1') {
    FACTORY = msg.sender;
    ENTRYPOINT = _entrypoint;
    // The implementation itself can never be initialized or used
    retired = true;
  }

  receive() external payable {
    if (msg.sender != _payingVenue) revert UnexpectedSender();
  }

  /// @inheritdoc IBlankAccount
  function initialize(address _owner) external {
    if (msg.sender != FACTORY) revert OnlyFactory();
    if (owner != address(0) || retired) revert Retired();
    if (_owner == address(0)) revert ZeroAddress();
    owner = _owner;
  }

  /// @inheritdoc IBlankAccount
  function sell(SellIntent calldata _intent, bytes calldata _signature) external returns (uint256 _commitment) {
    if (retired || owner == address(0)) revert Retired();
    if (block.timestamp > _intent.deadline) revert DeadlinePassed();
    if (_intent.relayFeeBPS > MAX_RELAY_FEE_BPS) revert RelayFeeTooHigh();
    if (_intent.adapter == address(0) || _intent.tokenIn == address(0)) revert ZeroAddress();
    if (ECDSA.recover(_hashTypedDataV4(_structHash(_intent)), _signature) != owner) revert InvalidSignature();

    // One life: retire before touching anything outside
    retired = true;

    // Sell through the venue and measure what actually arrived
    IERC20(_intent.tokenIn).forceApprove(_intent.adapter, _intent.amountIn);
    uint256 _before = address(this).balance;
    _payingVenue = _intent.adapter;
    ISellAdapter(_intent.adapter).swapExactTokenForETH(
      _intent.tokenIn, _intent.amountIn, _intent.minEthOut, address(this), _intent.adapterData
    );
    _payingVenue = address(0);
    IERC20(_intent.tokenIn).forceApprove(_intent.adapter, 0);
    uint256 _received = address(this).balance - _before;
    if (_received < _intent.minEthOut) revert InsufficientOutput();

    // Pay the relayer out of the proceeds; the blank never held gas
    uint256 _fee = (_received * _intent.relayFeeBPS) / _BPS;
    if (_fee > 0) {
      if (_intent.feeRecipient == address(0)) revert ZeroAddress();
      (bool _ok,) = _intent.feeRecipient.call{value: _fee}('');
      if (!_ok) revert FailedToSendFee();
    }

    // Back into the dark: the rest becomes a note only the owner of the precommitment can spend
    _commitment = ENTRYPOINT.deposit{value: _received - _fee}(_intent.precommitment);

    emit SoldBackIntoTheDark(_intent.tokenIn, _intent.amountIn, _received, _fee, _commitment);
  }

  /// @inheritdoc IBlankAccount
  function intentDigest(SellIntent calldata _intent) external view returns (bytes32) {
    return _hashTypedDataV4(_structHash(_intent));
  }

  function _structHash(SellIntent calldata _i) internal pure returns (bytes32) {
    return keccak256(
      abi.encode(
        SELL_INTENT_TYPEHASH,
        _i.tokenIn,
        _i.amountIn,
        _i.minEthOut,
        _i.deadline,
        _i.adapter,
        keccak256(_i.adapterData),
        _i.precommitment,
        _i.feeRecipient,
        _i.relayFeeBPS
      )
    );
  }
}

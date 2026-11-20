// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {ECDSA} from '@oz/utils/cryptography/ECDSA.sol';
import {EIP712} from '@oz/utils/cryptography/EIP712.sol';

import {IEntrypoint} from 'interfaces/IEntrypoint.sol';
import {IDropBox} from 'interfaces/zkblank/IDropBox.sol';

/**
 * @title DropBox
 * @notice ZKBLANK Dark Drop. Its address is fixed by (drop key, precommitment, keeper fee) before it exists, so it can
 *         be paid from any wallet, bridge or exchange. The first sweep deploys it (a minimal clone, via DropFactory)
 *         and deposits the balance into the vault with the precommitment the address was derived from. Whoever
 *         sweeps gets exactly the keeper fee written into the address, nothing more, and cannot change the note.
 * @dev The depositor the vault records is this box, not the wallet that paid it. Immutables live in the
 *      implementation's code and are shared by every clone.
 */
contract DropBox is IDropBox, EIP712 {
  bytes32 public constant RESWEEP_TYPEHASH = keccak256('Resweep(uint256 precommitment,uint256 deadline)');

  /// @notice Upper bound on the keeper fee a drop may promise (1%)
  uint256 public constant MAX_KEEPER_FEE_BPS = 100;

  uint256 internal constant _BPS = 10_000;

  address public immutable FACTORY;
  IEntrypoint public immutable ENTRYPOINT;

  /// @notice The drop key: the only signer allowed to name a new note for later funds
  address public owner;
  uint256 public precommitment;
  uint256 public keeperFeeBPS;
  bool public swept;

  constructor(IEntrypoint _entrypoint) EIP712('ZKBLANK Drop', '1') {
    FACTORY = msg.sender;
    ENTRYPOINT = _entrypoint;
    // The implementation itself can never hold or sweep anything
    swept = true;
    owner = address(1);
  }

  /// @notice A drop address accepts ETH from anyone, before and after it is deployed
  receive() external payable {}

  /// @inheritdoc IDropBox
  function initialize(address _owner, uint256 _precommitment, uint256 _keeperFeeBPS) external {
    if (msg.sender != FACTORY) revert OnlyFactory();
    if (owner != address(0)) revert AlreadyInitialized();
    owner = _owner;
    precommitment = _precommitment;
    keeperFeeBPS = _keeperFeeBPS;
  }

  /// @inheritdoc IDropBox
  function sweep(address _keeper) external returns (uint256 _commitment) {
    if (msg.sender != FACTORY) revert OnlyFactory();
    if (swept) revert AlreadySwept();
    swept = true;
    _commitment = _depositBalance(precommitment, _keeper);
  }

  /// @inheritdoc IDropBox
  function resweep(Resweep calldata _r, bytes calldata _signature) external returns (uint256 _commitment) {
    if (!swept || owner == address(1)) revert NotSwept();
    if (block.timestamp > _r.deadline) revert DeadlinePassed();
    if (ECDSA.recover(_hashTypedDataV4(_structHash(_r)), _signature) != owner) revert InvalidSignature();
    // Replay is impossible: the Entrypoint refuses a precommitment it has seen before
    _commitment = _depositBalance(_r.precommitment, msg.sender);
  }

  /// @inheritdoc IDropBox
  function resweepDigest(Resweep calldata _r) external view returns (bytes32) {
    return _hashTypedDataV4(_structHash(_r));
  }

  function _depositBalance(uint256 _precommitment, address _keeper) internal returns (uint256 _commitment) {
    uint256 _amount = address(this).balance;
    if (_amount == 0) revert EmptyDrop();
    uint256 _fee = (_amount * keeperFeeBPS) / _BPS;
    if (_fee > 0) {
      (bool _ok,) = _keeper.call{value: _fee}('');
      if (!_ok) revert FailedToSendFee();
    }
    _commitment = ENTRYPOINT.deposit{value: _amount - _fee}(_precommitment);
    emit DropSwept(_amount, _fee, _commitment);
  }

  function _structHash(Resweep calldata _r) internal pure returns (bytes32) {
    return keccak256(abi.encode(RESWEEP_TYPEHASH, _r.precommitment, _r.deadline));
  }
}

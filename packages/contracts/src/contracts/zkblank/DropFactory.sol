// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Clones} from '@oz/proxy/Clones.sol';

import {DropBox} from 'contracts/zkblank/DropBox.sol';
import {IEntrypoint} from 'interfaces/IEntrypoint.sol';
import {IDropBox} from 'interfaces/zkblank/IDropBox.sol';

/**
 * @title DropFactory
 * @notice Dark Drop addresses. The browser derives (drop key, precommitment) and picks a keeper fee; the address is
 *         a CREATE2 clone salted with all three, so it exists before anything is deployed and can be paid from
 *         anywhere. Anyone (a keeper, a relayer, the user) can sweep it.
 * @dev No owner, no upgrade path. The salt commits to the precommitment and the fee, so a sweeper can only ever
 *      produce the note the user sealed, for the fee the user offered.
 */
contract DropFactory {
  /// @notice The shared DropBox implementation every clone delegates to
  address public immutable IMPLEMENTATION;

  event DropOpened(address indexed drop);

  error FeeTooHigh();

  constructor(IEntrypoint _entrypoint) {
    IMPLEMENTATION = address(new DropBox(_entrypoint));
  }

  /// @notice The drop address for a drop key, a precommitment and a keeper fee
  function predict(address _owner, uint256 _precommitment, uint256 _keeperFeeBPS) public view returns (address) {
    return Clones.predictDeterministicAddress(IMPLEMENTATION, _salt(_owner, _precommitment, _keeperFeeBPS));
  }

  /// @notice Deploy the drop and sweep its balance into the vault; the caller is the keeper and takes the fee
  function sweep(
    address _owner,
    uint256 _precommitment,
    uint256 _keeperFeeBPS
  ) external returns (address _drop, uint256 _commitment) {
    if (_keeperFeeBPS > DropBox(payable(IMPLEMENTATION)).MAX_KEEPER_FEE_BPS()) revert FeeTooHigh();
    _drop = predict(_owner, _precommitment, _keeperFeeBPS);
    if (_drop.code.length == 0) {
      Clones.cloneDeterministic(IMPLEMENTATION, _salt(_owner, _precommitment, _keeperFeeBPS));
      IDropBox(_drop).initialize(_owner, _precommitment, _keeperFeeBPS);
      emit DropOpened(_drop);
    }
    _commitment = IDropBox(_drop).sweep(msg.sender);
  }

  function _salt(address _owner, uint256 _precommitment, uint256 _keeperFeeBPS) internal pure returns (bytes32) {
    return keccak256(abi.encode(_owner, _precommitment, _keeperFeeBPS));
  }
}

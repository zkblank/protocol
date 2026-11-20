// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Clones} from '@oz/proxy/Clones.sol';

import {BlankAccount} from 'contracts/zkblank/BlankAccount.sol';
import {IEntrypoint} from 'interfaces/IEntrypoint.sol';
import {IBlankAccount} from 'interfaces/zkblank/IBlankAccount.sol';

/**
 * @title BlankFactory
 * @notice Counterfactual blanks. A blank's address is known from its owner key before anything exists on chain,
 *         so a buy can pay straight into it. The blank is deployed only in the transaction that sells it.
 * @dev No owner, no upgrade path. One blank per owner key (the app derives a fresh key per position).
 */
contract BlankFactory {
  /// @notice The shared BlankAccount implementation every clone delegates to
  address public immutable IMPLEMENTATION;

  event BlankDeployed(address indexed blank, address indexed owner);

  constructor(IEntrypoint _entrypoint) {
    IMPLEMENTATION = address(new BlankAccount(_entrypoint));
  }

  /// @notice The blank address for an owner key, deployed or not
  function predict(address _owner) public view returns (address) {
    return Clones.predictDeterministicAddress(IMPLEMENTATION, _salt(_owner));
  }

  /// @notice Deploy the blank for `_owner` if it is not deployed yet
  function deploy(address _owner) public returns (address _blank) {
    _blank = predict(_owner);
    if (_blank.code.length == 0) {
      Clones.cloneDeterministic(IMPLEMENTATION, _salt(_owner));
      IBlankAccount(_blank).initialize(_owner);
      emit BlankDeployed(_blank, _owner);
    }
  }

  /// @notice Deploy the blank and run its signed sale in one transaction (what a relayer calls)
  function deployAndSell(
    address _owner,
    IBlankAccount.SellIntent calldata _intent,
    bytes calldata _signature
  ) external returns (address _blank, uint256 _commitment) {
    _blank = deploy(_owner);
    _commitment = IBlankAccount(_blank).sell(_intent, _signature);
  }

  function _salt(address _owner) internal pure returns (bytes32) {
    return bytes32(uint256(uint160(_owner)));
  }
}

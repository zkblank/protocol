// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/**
 * @title IDropBox
 * @notice A Dark Drop address. Anyone pays it ETH from anywhere; anyone sweeps it into the vault as a note sealed
 *         with the owner's precommitment. The sweeper is paid a fee fixed in advance and cannot redirect anything.
 */
interface IDropBox {
  /**
   * @notice What the drop key signs (EIP-712) to sweep ETH that arrived after the first sweep into a new note
   * @param precommitment Hash(nullifier, secret) of the new note; must never have been used before
   * @param deadline Last timestamp at which the sweep may execute
   */
  struct Resweep {
    uint256 precommitment;
    uint256 deadline;
  }

  /**
   * @notice Emitted on every sweep
   * @param amount The ETH the box held
   * @param keeperFee The ETH paid to the sweeper
   * @param commitment The note's commitment, inserted in the vault's tree
   */
  event DropSwept(uint256 amount, uint256 keeperFee, uint256 commitment);

  error OnlyFactory();
  error AlreadyInitialized();
  error NotSwept();
  error AlreadySwept();
  error EmptyDrop();
  error DeadlinePassed();
  error InvalidSignature();
  error FailedToSendFee();

  /// @notice Called once by the factory right after the clone is deployed
  function initialize(address _owner, uint256 _precommitment, uint256 _keeperFeeBPS) external;

  /// @notice First sweep, through the factory: the whole balance becomes the note sealed in the address
  function sweep(address _keeper) external returns (uint256 _commitment);

  /// @notice Later sweeps: ETH that arrived after the first one, into a new note the drop key names. Anyone may submit
  function resweep(Resweep calldata _r, bytes calldata _signature) external returns (uint256 _commitment);

  /// @notice The EIP-712 digest the drop key signs for `_r`
  function resweepDigest(Resweep calldata _r) external view returns (bytes32);
}

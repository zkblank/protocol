// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IERC20} from '@oz/interfaces/IERC20.sol';

import {DropBox} from 'contracts/zkblank/DropBox.sol';
import {DropFactory} from 'contracts/zkblank/DropFactory.sol';
import {IEntrypoint} from 'interfaces/IEntrypoint.sol';
import {IDropBox} from 'interfaces/zkblank/IDropBox.sol';

import {Constants} from 'test/helper/Constants.sol';
import {ZkblankBase} from 'test/zkblank/ZkblankBase.sol';

/**
 * @notice Dark Drop: a one-time address derived from (drop key, precommitment, keeper fee), paid by a plain transfer
 *         from any wallet, swept by anyone into the note the user sealed. Run with:
 *         forge test --match-contract ZkblankDarkDrop --ffi
 */
contract ZkblankDarkDrop is ZkblankBase {
  uint256 internal constant _KEEPER_FEE_BPS = 10; // 0.10%, covers the sweep
  bytes32 internal constant _DOMAIN_TYPEHASH =
    keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)');

  address internal immutable _MALLORY = makeAddr('MALLORY');

  /// @dev The test contract sweeps in some cases, so it must be able to take the keeper fee
  receive() external payable {}

  /*///////////////////////////////////////////////////////////////
                    THE ROUND TRIP (real proofs)
  //////////////////////////////////////////////////////////////*/

  function test_payTheDropFromAnyWalletThenTradeFromTheNote() public {
    (address _dropKey,) = makeAddrAndKey('DROP_KEY');

    // The browser seals the note before any money moves
    Commitment memory _note;
    _note.asset = IERC20(Constants.NATIVE_ASSET);
    _note.nullifier = _genSecretBySeed('drop_n');
    _note.secret = _genSecretBySeed('drop_s');
    _note.precommitment = _hashPrecommitment(_note.nullifier, _note.secret);

    address _drop = _drops.predict(_dropKey, _note.precommitment, _KEEPER_FEE_BPS);
    assertEq(_drop.code.length, 0, 'nothing deployed yet');

    // A plain transfer from any wallet (or a bridge, or an exchange withdrawal)
    vm.deal(_ALICE, 1 ether);
    vm.prank(_ALICE);
    (bool _ok,) = _drop.call{value: 1 ether}('');
    assertTrue(_ok);

    // Any keeper sweeps it; the note is the one Alice sealed
    _note.label = _nextLabel();
    vm.prank(_RELAYER);
    (address _deployed, uint256 _commitment) = _drops.sweep(_dropKey, _note.precommitment, _KEEPER_FEE_BPS);

    uint256 _fee = (1 ether * _KEEPER_FEE_BPS) / 10_000;
    _note.value = (1 ether - _fee) - ((1 ether - _fee) * _VETTING_FEE_BPS) / 10_000;
    _note.hash = _hashCommitment(_note.value, _note.label, _note.precommitment);

    assertEq(_deployed, _drop, 'deployed where predicted');
    assertEq(_commitment, _note.hash, 'the sealed note');
    assertEq(_RELAYER.balance, _fee, 'keeper paid the fee in the address');
    assertEq(_drop.balance, 0, 'drop emptied');
    assertEq(_pool.depositors(_note.label), _drop, 'the vault records the drop, not the paying wallet');

    // The ASP approves it and the note pays for a buy into a blank
    _insertIntoShadowMerkleTree(_note.hash);
    _insertIntoShadowASPMerkleTree(_note.label);
    _approveLabels();

    (address _blankKey,) = makeAddrAndKey('BLANK_KEY_001');
    address _blank = _factory.predict(_blankKey);
    (, uint256 _bought) = _buy(_note, 0.5 ether, _buyData(_blank, 0));
    assertGt(_bought, 0, 'blank holds the position');
    assertEq(_blank.code.length, 0);
  }

  /*///////////////////////////////////////////////////////////////
                    WHAT A SWEEPER CAN AND CANNOT DO
  //////////////////////////////////////////////////////////////*/

  function test_anyoneCanSweepButOnlyIntoTheSealedNote() public {
    (address _dropKey,) = makeAddrAndKey('DROP_KEY');
    uint256 _pre = 42;
    address _drop = _fund(_dropKey, _pre, 1 ether);

    uint256 _label = _nextLabel();
    vm.prank(_MALLORY);
    (, uint256 _commitment) = _drops.sweep(_dropKey, _pre, _KEEPER_FEE_BPS);

    uint256 _fee = (1 ether * _KEEPER_FEE_BPS) / 10_000;
    uint256 _value = (1 ether - _fee) - ((1 ether - _fee) * _VETTING_FEE_BPS) / 10_000;
    assertEq(_commitment, _hashCommitment(_value, _label, _pre), 'note sealed by the user, not the sweeper');
    assertEq(_MALLORY.balance, _fee, 'the sweeper gets the fee and nothing else');
    assertEq(_drop.balance, 0);
  }

  function test_sweeperCannotChangeTheNoteOrTheFee() public {
    (address _dropKey,) = makeAddrAndKey('DROP_KEY');
    address _drop = _fund(_dropKey, 42, 1 ether);

    // Another precommitment or a higher fee is another address, and that address is empty
    vm.startPrank(_MALLORY);
    vm.expectRevert(IDropBox.EmptyDrop.selector);
    _drops.sweep(_dropKey, 43, _KEEPER_FEE_BPS);
    vm.expectRevert(IDropBox.EmptyDrop.selector);
    _drops.sweep(_dropKey, 42, 100);
    vm.stopPrank();

    assertEq(_drop.balance, 1 ether, 'the real drop is untouched');
  }

  function test_keeperFeeIsCapped() public {
    (address _dropKey,) = makeAddrAndKey('DROP_KEY');
    vm.expectRevert(DropFactory.FeeTooHigh.selector);
    _drops.sweep(_dropKey, 42, 101);
  }

  function test_emptyDropReverts() public {
    (address _dropKey,) = makeAddrAndKey('DROP_KEY');
    vm.expectRevert(IDropBox.EmptyDrop.selector);
    _drops.sweep(_dropKey, 42, _KEEPER_FEE_BPS);
  }

  function test_aDropIsSweptThroughTheFactoryOnce() public {
    (address _dropKey,) = makeAddrAndKey('DROP_KEY');
    address _drop = _fund(_dropKey, 42, 1 ether);
    _drops.sweep(_dropKey, 42, _KEEPER_FEE_BPS);

    vm.deal(_drop, 0.1 ether);
    vm.expectRevert(IDropBox.AlreadySwept.selector);
    _drops.sweep(_dropKey, 42, _KEEPER_FEE_BPS);
  }

  /*///////////////////////////////////////////////////////////////
                     LATE FUNDS: NEVER STUCK
  //////////////////////////////////////////////////////////////*/

  function test_lateFundsGoIntoANewNoteTheDropKeyNames() public {
    (address _dropKey, uint256 _pk) = makeAddrAndKey('DROP_KEY');
    address _drop = _fund(_dropKey, 42, 1 ether);
    _drops.sweep(_dropKey, 42, _KEEPER_FEE_BPS);

    // Someone pays the old address again
    vm.deal(_ALICE, 0.2 ether);
    vm.prank(_ALICE);
    (bool _ok,) = _drop.call{value: 0.2 ether}('');
    assertTrue(_ok);

    IDropBox.Resweep memory _r = IDropBox.Resweep({precommitment: 77, deadline: block.timestamp + 60});
    uint256 _label = _nextLabel();
    vm.prank(_MALLORY);
    uint256 _commitment = IDropBox(_drop).resweep(_r, _sign(_pk, _drop, _r));

    uint256 _fee = (0.2 ether * _KEEPER_FEE_BPS) / 10_000;
    uint256 _value = (0.2 ether - _fee) - ((0.2 ether - _fee) * _VETTING_FEE_BPS) / 10_000;
    assertEq(_commitment, _hashCommitment(_value, _label, 77));
    assertEq(_drop.balance, 0);
    assertEq(_MALLORY.balance, _fee);
  }

  function test_resweepNeedsTheDropKey() public {
    (address _dropKey,) = makeAddrAndKey('DROP_KEY');
    (, uint256 _otherPk) = makeAddrAndKey('NOT_THE_DROP_KEY');
    address _drop = _fund(_dropKey, 42, 1 ether);
    _drops.sweep(_dropKey, 42, _KEEPER_FEE_BPS);
    vm.deal(_drop, 0.2 ether);

    IDropBox.Resweep memory _r = IDropBox.Resweep({precommitment: 77, deadline: block.timestamp + 60});
    vm.expectRevert(IDropBox.InvalidSignature.selector);
    IDropBox(_drop).resweep(_r, _sign(_otherPk, _drop, _r));
  }

  function test_resweepCannotReuseANote() public {
    (address _dropKey, uint256 _pk) = makeAddrAndKey('DROP_KEY');
    address _drop = _fund(_dropKey, 42, 1 ether);
    _drops.sweep(_dropKey, 42, _KEEPER_FEE_BPS);
    vm.deal(_drop, 0.2 ether);

    // The first note's precommitment, or replaying a resweep, is refused by the Entrypoint
    IDropBox.Resweep memory _old = IDropBox.Resweep({precommitment: 42, deadline: block.timestamp + 60});
    vm.expectRevert(IEntrypoint.PrecommitmentAlreadyUsed.selector);
    IDropBox(_drop).resweep(_old, _sign(_pk, _drop, _old));

    IDropBox.Resweep memory _r = IDropBox.Resweep({precommitment: 77, deadline: block.timestamp + 60});
    bytes memory _sig = _sign(_pk, _drop, _r);
    IDropBox(_drop).resweep(_r, _sig);
    vm.deal(_drop, 0.1 ether);
    vm.expectRevert(IEntrypoint.PrecommitmentAlreadyUsed.selector);
    IDropBox(_drop).resweep(_r, _sig);
  }

  function test_anUnsweptDropHasNoCodeAndOnlyItsFirstSweepMovesIt() public {
    (address _dropKey,) = makeAddrAndKey('DROP_KEY');
    address _drop = _fund(_dropKey, 43, 1 ether);

    // Before its first sweep a drop is just an address: there is no code to call, nothing to resweep
    assertEq(_drop.code.length, 0);
    assertEq(_drop.balance, 1 ether);

    // Only the sweep with the sealed precommitment and fee deploys it and moves the funds
    _drops.sweep(_dropKey, 43, _KEEPER_FEE_BPS);
    assertEq(_drop.balance, 0);
    assertGt(_drop.code.length, 0);
  }

  function test_implementationCannotBeUsed() public {
    DropBox _impl = DropBox(payable(_drops.IMPLEMENTATION()));
    vm.expectRevert(IDropBox.OnlyFactory.selector);
    _impl.initialize(_ALICE, 1, 0);
    vm.expectRevert(IDropBox.OnlyFactory.selector);
    _impl.sweep(_ALICE);
    IDropBox.Resweep memory _r = IDropBox.Resweep({precommitment: 77, deadline: block.timestamp + 60});
    vm.expectRevert(IDropBox.NotSwept.selector);
    _impl.resweep(_r, '');
  }

  function test_onChainDigestMatchesWhatTheAppSigns() public {
    (address _dropKey,) = makeAddrAndKey('DROP_KEY');
    address _drop = _fund(_dropKey, 42, 1 ether);
    _drops.sweep(_dropKey, 42, _KEEPER_FEE_BPS);
    IDropBox.Resweep memory _r = IDropBox.Resweep({precommitment: 77, deadline: block.timestamp + 60});
    assertEq(IDropBox(_drop).resweepDigest(_r), _digest(_drop, _r));
  }

  /*///////////////////////////////////////////////////////////////
                             HELPERS
  //////////////////////////////////////////////////////////////*/

  function _fund(address _dropKey, uint256 _pre, uint256 _amount) internal returns (address _drop) {
    _drop = _drops.predict(_dropKey, _pre, _KEEPER_FEE_BPS);
    vm.deal(_ALICE, _amount);
    vm.prank(_ALICE);
    (bool _ok,) = _drop.call{value: _amount}('');
    assertTrue(_ok);
  }

  function _digest(address _drop, IDropBox.Resweep memory _r) internal view returns (bytes32) {
    bytes32 _domain =
      keccak256(abi.encode(_DOMAIN_TYPEHASH, keccak256('ZKBLANK Drop'), keccak256('1'), block.chainid, _drop));
    bytes32 _struct =
      keccak256(abi.encode(keccak256('Resweep(uint256 precommitment,uint256 deadline)'), _r.precommitment, _r.deadline));
    return keccak256(abi.encodePacked('\x19\x01', _domain, _struct));
  }

  function _sign(uint256 _pk, address _drop, IDropBox.Resweep memory _r) internal view returns (bytes memory) {
    (uint8 _v, bytes32 _rr, bytes32 _s) = vm.sign(_pk, _digest(_drop, _r));
    return abi.encodePacked(_rr, _s, _v);
  }
}

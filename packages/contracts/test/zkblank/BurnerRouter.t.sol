// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {ProofLib} from 'contracts/lib/ProofLib.sol';
import {IPrivacyPool} from 'interfaces/IPrivacyPool.sol';
import {IBurnerRouter} from 'interfaces/zkblank/IBurnerRouter.sol';

import {ZkblankBase} from 'test/zkblank/ZkblankBase.sol';

/**
 * @notice Burner Mode end to end with real Groth16 proofs (the upstream circuit and keys), no fork:
 *         deposit -> prove a spend bound to a BuyData -> relayer calls BurnerRouter.buy -> tokens land in a blank.
 *         Run with: forge test --match-contract ZkblankBurnerRouter --ffi
 */
contract ZkblankBurnerRouter is ZkblankBase {
  /// @notice One deposit pays two buys into two different blanks; the change stays a private note
  function test_twoBuysFromOneNoteLandInTwoBlanks() public {
    Commitment memory _note = _depositAndApprove('alice_n1', 'alice_s1', 1 ether);

    address _blank16 = makeAddr('BLANK_016');
    address _blank17 = makeAddr('BLANK_017');

    (Commitment memory _change, uint256 _out16) = _buy(_note, 0.5 ether, _buyData(_blank16, 0));
    (, uint256 _out17) = _buy(_change, 0.3 ether, _buyData(_blank17, 0));

    uint256 _fee16 = (0.5 ether * _RELAY_FEE_BPS) / 10_000;
    assertEq(_out16, ((0.5 ether - _fee16) * _TOKENS_PER_ETH) / 1 ether, 'blank #16 output');
    assertEq(_xyz.balanceOf(_blank16), _out16);
    assertEq(_xyz.balanceOf(_blank17), _out17);

    // The blanks were never sent gas and never deployed anything
    assertEq(_blank16.balance, 0);
    assertEq(_blank17.balance, 0);
    assertEq(_blank16.code.length, 0);

    // The relayer was paid from the trade, the router keeps nothing
    assertEq(_RELAYER.balance, _fee16 + (0.3 ether * _RELAY_FEE_BPS) / 10_000, 'relay fees');
    assertEq(address(_router).balance, 0);
  }

  /// @notice A relayer that lowers the minimum out (to sandwich the trade) breaks the proof
  function test_relayerCannotLowerMinimumOut() public {
    Commitment memory _note = _depositAndApprove('alice_n1', 'alice_s1', 1 ether);
    IBurnerRouter.BuyData memory _signed = _buyData(makeAddr('BLANK_016'), 1_000_000 ether);
    (IPrivacyPool.Withdrawal memory _w, ProofLib.WithdrawProof memory _proof,) = _prove(_note, 0.5 ether, _signed);

    IBurnerRouter.BuyData memory _tampered = _signed;
    _tampered.minAmountOut = 0;
    _w.data = abi.encode(_tampered);

    vm.prank(_RELAYER);
    vm.expectRevert(IPrivacyPool.ContextMismatch.selector);
    _router.buy(IPrivacyPool(address(_pool)), _w, _proof);
  }

  /// @notice A relayer that sends the tokens to its own wallet instead of the blank breaks the proof
  function test_relayerCannotRedirectTheBlank() public {
    Commitment memory _note = _depositAndApprove('alice_n1', 'alice_s1', 1 ether);
    IBurnerRouter.BuyData memory _signed = _buyData(makeAddr('BLANK_016'), 0);
    (IPrivacyPool.Withdrawal memory _w, ProofLib.WithdrawProof memory _proof,) = _prove(_note, 0.5 ether, _signed);

    IBurnerRouter.BuyData memory _tampered = _signed;
    _tampered.blank = _RELAYER;
    _w.data = abi.encode(_tampered);

    vm.prank(_RELAYER);
    vm.expectRevert(IPrivacyPool.ContextMismatch.selector);
    _router.buy(IPrivacyPool(address(_pool)), _w, _proof);
  }

  /// @notice A relayer cannot raise its own fee
  function test_relayerCannotRaiseItsFee() public {
    Commitment memory _note = _depositAndApprove('alice_n1', 'alice_s1', 1 ether);
    IBurnerRouter.BuyData memory _signed = _buyData(makeAddr('BLANK_016'), 0);
    (IPrivacyPool.Withdrawal memory _w, ProofLib.WithdrawProof memory _proof,) = _prove(_note, 0.5 ether, _signed);

    IBurnerRouter.BuyData memory _tampered = _signed;
    _tampered.relayFeeBPS = 1000;
    _w.data = abi.encode(_tampered);

    vm.prank(_RELAYER);
    vm.expectRevert(IPrivacyPool.ContextMismatch.selector);
    _router.buy(IPrivacyPool(address(_pool)), _w, _proof);
  }

  /// @notice A proof cannot be replayed: the note's nullifier is spent after the first buy
  function test_proofCannotBeReplayed() public {
    Commitment memory _note = _depositAndApprove('alice_n1', 'alice_s1', 1 ether);
    IBurnerRouter.BuyData memory _d = _buyData(makeAddr('BLANK_016'), 0);
    (IPrivacyPool.Withdrawal memory _w, ProofLib.WithdrawProof memory _proof,) = _prove(_note, 0.5 ether, _d);

    vm.prank(_RELAYER);
    _router.buy(IPrivacyPool(address(_pool)), _w, _proof);

    vm.prank(_RELAYER);
    vm.expectRevert();
    _router.buy(IPrivacyPool(address(_pool)), _w, _proof);
  }

  /// @notice A trade held back past its deadline cannot execute
  function test_expiredTradeReverts() public {
    Commitment memory _note = _depositAndApprove('alice_n1', 'alice_s1', 1 ether);
    IBurnerRouter.BuyData memory _d = _buyData(makeAddr('BLANK_016'), 0);
    (IPrivacyPool.Withdrawal memory _w, ProofLib.WithdrawProof memory _proof,) = _prove(_note, 0.5 ether, _d);

    vm.warp(_d.deadline + 1);
    vm.prank(_RELAYER);
    vm.expectRevert(IBurnerRouter.DeadlinePassed.selector);
    _router.buy(IPrivacyPool(address(_pool)), _w, _proof);
  }

  /// @notice The router measures the blank's balance itself, so a venue that under-delivers reverts the trade
  function test_shortVenueReverts() public {
    Commitment memory _note = _depositAndApprove('alice_n1', 'alice_s1', 1 ether);
    uint256 _fair = ((0.5 ether - (0.5 ether * _RELAY_FEE_BPS) / 10_000) * _TOKENS_PER_ETH) / 1 ether;
    IBurnerRouter.BuyData memory _d = _buyData(makeAddr('BLANK_016'), _fair);
    (IPrivacyPool.Withdrawal memory _w, ProofLib.WithdrawProof memory _proof,) = _prove(_note, 0.5 ether, _d);

    _venue.setShortBy(1);
    vm.prank(_RELAYER);
    vm.expectRevert(IBurnerRouter.InsufficientOutput.selector);
    _router.buy(IPrivacyPool(address(_pool)), _w, _proof);
  }

  /// @notice The router refuses stray ETH
  function test_routerRefusesStrayEth() public {
    vm.deal(_ALICE, 1 ether);
    vm.prank(_ALICE);
    (bool _ok,) = address(_router).call{value: 1 ether}('');
    assertFalse(_ok);
  }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IERC20} from '@oz/interfaces/IERC20.sol';

import {BlankAccount} from 'contracts/zkblank/BlankAccount.sol';
import {IBlankAccount} from 'interfaces/zkblank/IBlankAccount.sol';

import {Constants} from 'test/helper/Constants.sol';
import {ZkblankBase} from 'test/zkblank/ZkblankBase.sol';

/**
 * @notice A blank's whole life: a counterfactual address that receives a buy with no code and no gas, then one
 *         signed sale that deploys it, pays the relayer from the proceeds and deposits the rest as a new private
 *         note, which can pay for the next blank. Run with: forge test --match-contract ZkblankBlankLifecycle --ffi
 */
contract ZkblankBlankLifecycle is ZkblankBase {
  bytes32 internal constant _DOMAIN_TYPEHASH =
    keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)');

  /*///////////////////////////////////////////////////////////////
                       THE ROUND TRIP (real proofs)
  //////////////////////////////////////////////////////////////*/

  function test_buySellAndBuyAgainFromTheProceeds() public {
    Commitment memory _note = _depositAndApprove('alice_n1', 'alice_s1', 1 ether);

    // Blank #17 exists only as an address derived from its key
    (address _key17, uint256 _pk17) = makeAddrAndKey('BLANK_KEY_017');
    address _blank17 = _factory.predict(_key17);
    assertEq(_blank17.code.length, 0, 'counterfactual before the buy');

    // Buy 0.5 ETH of $XYZ into it from the private note
    (, uint256 _bought) = _buy(_note, 0.5 ether, _buyData(_blank17, 0));
    assertEq(_blank17.code.length, 0, 'still no code while holding the position');
    assertEq(_blank17.balance, 0, 'never sent gas');

    // Sell it back into the dark: the proceeds become a note only Alice can spend
    Commitment memory _sellNote;
    _sellNote.asset = IERC20(Constants.NATIVE_ASSET);
    _sellNote.nullifier = _genSecretBySeed('alice_sell_n');
    _sellNote.secret = _genSecretBySeed('alice_sell_s');
    _sellNote.precommitment = _hashPrecommitment(_sellNote.nullifier, _sellNote.secret);
    _sellNote.label = _nextLabel();

    IBlankAccount.SellIntent memory _intent = _sellIntent(_bought, 0, _sellNote.precommitment);
    bytes memory _sig = _sign(_pk17, _blank17, _intent);

    uint256 _relayerBefore = _RELAYER.balance;
    vm.prank(_RELAYER);
    (address _deployed, uint256 _commitment) = _factory.deployAndSell(_key17, _intent, _sig);

    uint256 _ethOut = (_bought * 1 ether) / _TOKENS_PER_ETH;
    uint256 _fee = (_ethOut * _RELAY_FEE_BPS) / 10_000;
    _sellNote.value = (_ethOut - _fee) - ((_ethOut - _fee) * _VETTING_FEE_BPS) / 10_000;
    _sellNote.hash = _hashCommitment(_sellNote.value, _sellNote.label, _sellNote.precommitment);

    assertEq(_deployed, _blank17, 'deployed where predicted');
    assertEq(_commitment, _sellNote.hash, 'proceeds became the note Alice sealed');
    assertTrue(IBlankAccount(_blank17).retired(), 'one life');
    assertEq(_xyz.balanceOf(_blank17), 0, 'position closed');
    assertEq(_blank17.balance, 0, 'blank keeps nothing');
    assertEq(_RELAYER.balance - _relayerBefore, _fee, 'relayer paid from the proceeds');

    // Once the ASP approves the new deposit, the proceeds pay for blank #18
    _insertIntoShadowMerkleTree(_sellNote.hash);
    _insertIntoShadowASPMerkleTree(_sellNote.label);
    _approveLabels();

    (address _key18,) = makeAddrAndKey('BLANK_KEY_018');
    address _blank18 = _factory.predict(_key18);
    (, uint256 _bought18) = _buy(_sellNote, _sellNote.value / 2, _buyData(_blank18, 0));
    assertGt(_bought18, 0, 'blank #18 holds the next position');
    assertEq(_blank18.code.length, 0);
  }

  /*///////////////////////////////////////////////////////////////
                        WHAT A RELAYER CANNOT DO
  //////////////////////////////////////////////////////////////*/

  function test_relayerCannotLowerTheMinimum() public {
    (address _key, uint256 _pk, address _blank) = _fundedBlank('K1', 1_000_000 ether);
    IBlankAccount.SellIntent memory _i = _sellIntent(1_000_000 ether, 0.4 ether, 1);
    bytes memory _sig = _sign(_pk, _blank, _i);

    _i.minEthOut = 0;
    vm.prank(_RELAYER);
    vm.expectRevert(IBlankAccount.InvalidSignature.selector);
    _factory.deployAndSell(_key, _i, _sig);
  }

  function test_relayerCannotRedirectTheProceeds() public {
    (address _key, uint256 _pk, address _blank) = _fundedBlank('K1', 1_000_000 ether);
    IBlankAccount.SellIntent memory _i = _sellIntent(1_000_000 ether, 0, 1);
    bytes memory _sig = _sign(_pk, _blank, _i);

    _i.precommitment = 2; // a note the relayer controls
    vm.prank(_RELAYER);
    vm.expectRevert(IBlankAccount.InvalidSignature.selector);
    _factory.deployAndSell(_key, _i, _sig);
  }

  function test_relayerCannotRaiseItsFee() public {
    (address _key, uint256 _pk, address _blank) = _fundedBlank('K1', 1_000_000 ether);
    IBlankAccount.SellIntent memory _i = _sellIntent(1_000_000 ether, 0, 1);
    bytes memory _sig = _sign(_pk, _blank, _i);

    _i.relayFeeBPS = 1000;
    vm.prank(_RELAYER);
    vm.expectRevert(IBlankAccount.InvalidSignature.selector);
    _factory.deployAndSell(_key, _i, _sig);
  }

  function test_anotherKeyCannotSell() public {
    (address _key,, address _blank) = _fundedBlank('K1', 1_000_000 ether);
    (, uint256 _otherPk) = makeAddrAndKey('NOT_THE_OWNER');
    IBlankAccount.SellIntent memory _i = _sellIntent(1_000_000 ether, 0, 1);

    vm.prank(_RELAYER);
    vm.expectRevert(IBlankAccount.InvalidSignature.selector);
    _factory.deployAndSell(_key, _i, _sign(_otherPk, _blank, _i));
  }

  function test_signatureIsBoundToOneBlank() public {
    (, uint256 _pkA, address _blankA) = _fundedBlank('KA', 1_000_000 ether);
    (address _keyB,, address _blankB) = _fundedBlank('KB', 1_000_000 ether);
    IBlankAccount.SellIntent memory _i = _sellIntent(1_000_000 ether, 0, 1);
    assertTrue(_blankA != _blankB);

    vm.prank(_RELAYER);
    vm.expectRevert(IBlankAccount.InvalidSignature.selector);
    _factory.deployAndSell(_keyB, _i, _sign(_pkA, _blankA, _i));
  }

  /*///////////////////////////////////////////////////////////////
                           ONE LIFE, AND LIMITS
  //////////////////////////////////////////////////////////////*/

  function test_aBlankLivesOnce() public {
    (address _key, uint256 _pk, address _blank) = _fundedBlank('K1', 2_000_000 ether);
    IBlankAccount.SellIntent memory _first = _sellIntent(1_000_000 ether, 0, 1);
    vm.prank(_RELAYER);
    _factory.deployAndSell(_key, _first, _sign(_pk, _blank, _first));

    // Even a fresh, valid signature from the owner cannot revive it
    IBlankAccount.SellIntent memory _second = _sellIntent(1_000_000 ether, 0, 3);
    bytes memory _sig = _sign(_pk, _blank, _second);
    vm.prank(_RELAYER);
    vm.expectRevert(IBlankAccount.Retired.selector);
    _factory.deployAndSell(_key, _second, _sig);
  }

  function test_expiredSaleReverts() public {
    (address _key, uint256 _pk, address _blank) = _fundedBlank('K1', 1_000_000 ether);
    IBlankAccount.SellIntent memory _i = _sellIntent(1_000_000 ether, 0, 1);
    bytes memory _sig = _sign(_pk, _blank, _i);

    vm.warp(_i.deadline + 1);
    vm.prank(_RELAYER);
    vm.expectRevert(IBlankAccount.DeadlinePassed.selector);
    _factory.deployAndSell(_key, _i, _sig);
  }

  function test_shortVenueReverts() public {
    (address _key, uint256 _pk, address _blank) = _fundedBlank('K1', 1_000_000 ether);
    uint256 _fair = (1_000_000 ether * 1 ether) / _TOKENS_PER_ETH;
    IBlankAccount.SellIntent memory _i = _sellIntent(1_000_000 ether, _fair, 1);
    bytes memory _sig = _sign(_pk, _blank, _i);

    _venue.setShortBy(1);
    vm.prank(_RELAYER);
    vm.expectRevert(IBlankAccount.InsufficientOutput.selector);
    _factory.deployAndSell(_key, _i, _sig);
  }

  function test_implementationCannotBeUsed() public {
    BlankAccount _impl = BlankAccount(payable(_factory.IMPLEMENTATION()));
    vm.expectRevert(IBlankAccount.OnlyFactory.selector);
    _impl.initialize(_ALICE);

    IBlankAccount.SellIntent memory _i = _sellIntent(1, 0, 1);
    vm.expectRevert(IBlankAccount.Retired.selector);
    _impl.sell(_i, '');
  }

  function test_onChainDigestMatchesWhatTheAppSigns() public {
    (address _key,, address _blank) = _fundedBlank('K1', 1);
    _factory.deploy(_key);
    IBlankAccount.SellIntent memory _i = _sellIntent(1, 0, 1);
    assertEq(IBlankAccount(_blank).intentDigest(_i), _digest(_blank, _i));
    assertEq(IBlankAccount(_blank).owner(), _key);
  }

  function test_blankRefusesStrayEth() public {
    (address _key,, address _blank) = _fundedBlank('K1', 1);
    _factory.deploy(_key);
    vm.deal(_ALICE, 1 ether);
    vm.prank(_ALICE);
    (bool _ok,) = _blank.call{value: 1 ether}('');
    assertFalse(_ok);
  }

  /*///////////////////////////////////////////////////////////////
                             HELPERS
  //////////////////////////////////////////////////////////////*/

  /// @dev A counterfactual blank already holding `_amount` $XYZ (as after a buy), without a proof
  function _fundedBlank(
    string memory _name,
    uint256 _amount
  ) internal returns (address _key, uint256 _pk, address _blank) {
    (_key, _pk) = makeAddrAndKey(_name);
    _blank = _factory.predict(_key);
    _xyz.mint(_blank, _amount);
  }

  function _sellIntent(
    uint256 _amountIn,
    uint256 _minEthOut,
    uint256 _precommitment
  ) internal view returns (IBlankAccount.SellIntent memory) {
    return IBlankAccount.SellIntent({
      tokenIn: address(_xyz),
      amountIn: _amountIn,
      minEthOut: _minEthOut,
      deadline: block.timestamp + 60,
      adapter: address(_venue),
      adapterData: '',
      precommitment: _precommitment,
      feeRecipient: _RELAYER,
      relayFeeBPS: _RELAY_FEE_BPS
    });
  }

  /// @dev The EIP-712 digest computed off chain, the way the app does before the blank exists
  function _digest(address _blank, IBlankAccount.SellIntent memory _i) internal view returns (bytes32) {
    bytes32 _domain = keccak256(
      abi.encode(_DOMAIN_TYPEHASH, keccak256('ZKBLANK Blank'), keccak256('1'), block.chainid, _blank)
    );
    bytes32 _struct = keccak256(
      abi.encode(
        keccak256(
          'SellIntent(address tokenIn,uint256 amountIn,uint256 minEthOut,uint256 deadline,address adapter,bytes adapterData,uint256 precommitment,address feeRecipient,uint256 relayFeeBPS)'
        ),
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
    return keccak256(abi.encodePacked('\x19\x01', _domain, _struct));
  }

  function _sign(
    uint256 _pk,
    address _blank,
    IBlankAccount.SellIntent memory _i
  ) internal view returns (bytes memory) {
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_pk, _digest(_blank, _i));
    return abi.encodePacked(_r, _s, _v);
  }
}

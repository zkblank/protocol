// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {ERC1967Proxy} from '@oz/proxy/ERC1967/ERC1967Proxy.sol';
import {ERC20} from '@oz/token/ERC20/ERC20.sol';

import {Entrypoint} from 'contracts/Entrypoint.sol';
import {PrivacyPoolSimple} from 'contracts/implementations/PrivacyPoolSimple.sol';
import {ProofLib} from 'contracts/lib/ProofLib.sol';
import {CommitmentVerifier} from 'contracts/verifiers/CommitmentVerifier.sol';
import {WithdrawalVerifier} from 'contracts/verifiers/WithdrawalVerifier.sol';
import {BurnerRouter} from 'contracts/zkblank/BurnerRouter.sol';

import {IERC20} from '@oz/interfaces/IERC20.sol';
import {IPrivacyPool} from 'interfaces/IPrivacyPool.sol';
import {IBurnerRouter} from 'interfaces/zkblank/IBurnerRouter.sol';
import {ISwapAdapter} from 'interfaces/zkblank/ISwapAdapter.sol';

import {IntegrationUtils} from 'test/integration/Utils.sol';
import {Constants} from 'test/helper/Constants.sol';
import {InternalLeanIMT, LeanIMTData} from 'lean-imt/InternalLeanIMT.sol';

/// @dev A token the mock venue can mint
contract MockToken is ERC20 {
  constructor() ERC20('Test Token', 'XYZ') {}

  function mint(address _to, uint256 _amount) external {
    _mint(_to, _amount);
  }
}

/// @dev A venue with a fixed price. `shortBy` makes it pay less than it reports, to test the router's own check
contract MockSwapAdapter is ISwapAdapter {
  uint256 public immutable TOKENS_PER_ETH;
  uint256 public shortBy;

  constructor(uint256 _tokensPerEth) {
    TOKENS_PER_ETH = _tokensPerEth;
  }

  function setShortBy(uint256 _shortBy) external {
    shortBy = _shortBy;
  }

  function swapExactETHForToken(
    address _tokenOut,
    uint256 _minAmountOut,
    address _recipient,
    bytes calldata
  ) external payable returns (uint256 _amountOut) {
    _amountOut = (msg.value * TOKENS_PER_ETH) / 1 ether;
    MockToken(_tokenOut).mint(_recipient, _amountOut - shortBy);
    // Reports the full amount even when short: the router must not trust this
    if (_amountOut < _minAmountOut) _amountOut = _minAmountOut;
  }
}

/**
 * @notice Burner Mode end to end with real Groth16 proofs (the upstream circuit and keys), no fork:
 *         deposit -> prove a spend bound to a BuyData -> relayer calls BurnerRouter.buy -> tokens land in a blank.
 *         Run with: forge test --match-contract ZkblankBurnerRouter --ffi
 */
contract ZkblankBurnerRouter is IntegrationUtils {
  using InternalLeanIMT for LeanIMTData;

  uint256 internal constant _SNARK_SCALAR_FIELD =
    21_888_242_871_839_275_222_246_405_745_257_275_088_548_364_400_416_034_343_698_204_186_575_808_495_617;
  uint256 internal constant _VETTING_FEE_BPS = 10; // 0.10%, the Dark Drop fee
  uint256 internal constant _RELAY_FEE_BPS = 25; // 0.25%
  uint256 internal constant _TOKENS_PER_ETH = 2_408_660 ether; // 0.5 ETH buys ~1,204,330 $XYZ

  address internal immutable _OWNER = makeAddr('OWNER');
  address internal immutable _POSTMAN = makeAddr('POSTMAN');
  address internal immutable _RELAYER = makeAddr('RELAYER');
  address internal immutable _ALICE = makeAddr('ALICE');

  Entrypoint internal _entrypoint;
  PrivacyPoolSimple internal _pool;
  BurnerRouter internal _router;
  MockToken internal _xyz;
  MockSwapAdapter internal _venue;

  function setUp() public {
    WithdrawalVerifier _withdrawalVerifier = new WithdrawalVerifier();
    CommitmentVerifier _commitmentVerifier = new CommitmentVerifier();

    address _impl = address(new Entrypoint());
    _entrypoint = Entrypoint(
      payable(address(new ERC1967Proxy(_impl, abi.encodeCall(Entrypoint.initialize, (_OWNER, _POSTMAN)))))
    );
    _pool = new PrivacyPoolSimple(address(_entrypoint), address(_withdrawalVerifier), address(_commitmentVerifier));

    vm.prank(_OWNER);
    _entrypoint.registerPool(IERC20(Constants.NATIVE_ASSET), IPrivacyPool(address(_pool)), 1, _VETTING_FEE_BPS, 500);

    _router = new BurnerRouter();
    _xyz = new MockToken();
    _venue = new MockSwapAdapter(_TOKENS_PER_ETH);
  }

  /*///////////////////////////////////////////////////////////////
                              TESTS
  //////////////////////////////////////////////////////////////*/

  /// @notice One deposit pays two buys into two different blanks; the change stays a private note
  function test_twoBuysFromOneNoteLandInTwoBlanks() public {
    Commitment memory _note = _depositAndApprove('alice_n1', 'alice_s1', 1 ether);

    address _blank16 = makeAddr('BLANK_016');
    address _blank17 = makeAddr('BLANK_017');

    // Buy 1: 0.5 ETH into blank #16
    (Commitment memory _change, uint256 _out16) = _buy(_note, 0.5 ether, _buyData(_blank16, 0), 'alice_n2', 'alice_s2');
    // Buy 2: 0.3 ETH from the change note into blank #17
    (, uint256 _out17) = _buy(_change, 0.3 ether, _buyData(_blank17, 0), 'alice_n3', 'alice_s3');

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

  /*///////////////////////////////////////////////////////////////
                             HELPERS
  //////////////////////////////////////////////////////////////*/

  function _buyData(address _blank, uint256 _minOut) internal view returns (IBurnerRouter.BuyData memory) {
    return IBurnerRouter.BuyData({
      blank: _blank,
      tokenOut: address(_xyz),
      minAmountOut: _minOut,
      deadline: block.timestamp + 60,
      adapter: address(_venue),
      adapterData: '',
      feeRecipient: _RELAYER,
      relayFeeBPS: _RELAY_FEE_BPS
    });
  }

  /// @dev Dark Drop stand-in: a public deposit whose label the ASP approves
  function _depositAndApprove(
    string memory _nullifierSeed,
    string memory _secretSeed,
    uint256 _amount
  ) internal returns (Commitment memory _c) {
    _c.asset = IERC20(Constants.NATIVE_ASSET);
    _c.nullifier = _genSecretBySeed(_nullifierSeed);
    _c.secret = _genSecretBySeed(_secretSeed);
    _c.label = uint256(keccak256(abi.encodePacked(_pool.SCOPE(), _pool.nonce() + 1))) % Constants.SNARK_SCALAR_FIELD;
    _c.value = _amount - (_amount * _VETTING_FEE_BPS) / 10_000;
    _c.precommitment = _hashPrecommitment(_c.nullifier, _c.secret);
    _c.hash = _hashCommitment(_c.value, _c.label, _c.precommitment);

    _insertIntoShadowMerkleTree(_c.hash);
    _insertIntoShadowASPMerkleTree(_c.label);

    vm.deal(_ALICE, _amount);
    vm.prank(_ALICE);
    _entrypoint.deposit{value: _amount}(_c.precommitment);

    vm.prank(_POSTMAN);
    _entrypoint.updateRoot(_shadowASPMerkleTree._root(), 'ipfs_cid_ipfs_cid_ipfs_cid_ipfs_cid_ipfs_cid_ipfs_cid');
  }

  /// @dev Builds the withdrawal bound to `_d` and a real proof for it
  function _prove(
    Commitment memory _note,
    uint256 _spend,
    IBurnerRouter.BuyData memory _d
  ) internal returns (IPrivacyPool.Withdrawal memory _w, ProofLib.WithdrawProof memory _proof, Commitment memory _change) {
    _w = IPrivacyPool.Withdrawal({processooor: address(_router), data: abi.encode(_d)});
    uint256 _context = uint256(keccak256(abi.encode(_w, _pool.SCOPE()))) % _SNARK_SCALAR_FIELD;

    _change.asset = _note.asset;
    _change.label = _note.label;
    _change.value = _note.value - _spend;
    _change.nullifier = _genSecretBySeed(string(abi.encodePacked('change_n', vm.toString(_note.hash))));
    _change.secret = _genSecretBySeed(string(abi.encodePacked('change_s', vm.toString(_note.hash))));
    _change.precommitment = _hashPrecommitment(_change.nullifier, _change.secret);
    _change.hash = _hashCommitment(_change.value, _change.label, _change.precommitment);

    _proof = _generateWithdrawalProof(
      WithdrawalProofParams({
        existingCommitment: _note.hash,
        withdrawnValue: _spend,
        context: _context,
        label: _note.label,
        existingValue: _note.value,
        existingNullifier: _note.nullifier,
        existingSecret: _note.secret,
        newNullifier: _change.nullifier,
        newSecret: _change.secret
      })
    );
  }

  function _buy(
    Commitment memory _note,
    uint256 _spend,
    IBurnerRouter.BuyData memory _d,
    string memory,
    string memory
  ) internal returns (Commitment memory _change, uint256 _out) {
    IPrivacyPool.Withdrawal memory _w;
    ProofLib.WithdrawProof memory _proof;
    (_w, _proof, _change) = _prove(_note, _spend, _d);

    vm.prank(_RELAYER);
    _out = _router.buy(IPrivacyPool(address(_pool)), _w, _proof);

    assertTrue(_pool.nullifierHashes(_proof.pubSignals[1]), 'note must be spent');
    _insertIntoShadowMerkleTree(_change.hash);
  }
}

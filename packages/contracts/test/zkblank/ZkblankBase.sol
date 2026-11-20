// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {ERC1967Proxy} from '@oz/proxy/ERC1967/ERC1967Proxy.sol';

import {Entrypoint} from 'contracts/Entrypoint.sol';
import {PrivacyPoolSimple} from 'contracts/implementations/PrivacyPoolSimple.sol';
import {ProofLib} from 'contracts/lib/ProofLib.sol';
import {CommitmentVerifier} from 'contracts/verifiers/CommitmentVerifier.sol';
import {WithdrawalVerifier} from 'contracts/verifiers/WithdrawalVerifier.sol';
import {BlankFactory} from 'contracts/zkblank/BlankFactory.sol';
import {BurnerRouter} from 'contracts/zkblank/BurnerRouter.sol';

import {IERC20} from '@oz/interfaces/IERC20.sol';
import {IPrivacyPool} from 'interfaces/IPrivacyPool.sol';
import {IBurnerRouter} from 'interfaces/zkblank/IBurnerRouter.sol';

import {InternalLeanIMT, LeanIMTData} from 'lean-imt/InternalLeanIMT.sol';
import {Constants} from 'test/helper/Constants.sol';
import {IntegrationUtils} from 'test/integration/Utils.sol';
import {MockToken, MockVenue} from 'test/zkblank/Mocks.sol';

/**
 * @notice Shared setup for ZKBLANK tests: the upstream Entrypoint and native pool with the real Groth16 verifiers,
 *         plus BurnerRouter, BlankFactory and a fixed-price venue. Proofs come from the upstream generator (ffi).
 */
contract ZkblankBase is IntegrationUtils {
  using InternalLeanIMT for LeanIMTData;

  uint256 internal constant _SNARK_SCALAR_FIELD =
    21_888_242_871_839_275_222_246_405_745_257_275_088_548_364_400_416_034_343_698_204_186_575_808_495_617;
  uint256 internal constant _VETTING_FEE_BPS = 10; // 0.10%, the Dark Drop fee
  uint256 internal constant _RELAY_FEE_BPS = 25; // 0.25%
  uint256 internal constant _TOKENS_PER_ETH = 2_408_660 ether; // 0.5 ETH buys ~1,204,330 $XYZ
  string internal constant _CID = 'ipfs_cid_ipfs_cid_ipfs_cid_ipfs_cid_ipfs_cid_ipfs_cid';

  address internal immutable _OWNER = makeAddr('OWNER');
  address internal immutable _POSTMAN = makeAddr('POSTMAN');
  address internal immutable _RELAYER = makeAddr('RELAYER');
  address internal immutable _ALICE = makeAddr('ALICE');

  Entrypoint internal _entrypoint;
  PrivacyPoolSimple internal _pool;
  BurnerRouter internal _router;
  BlankFactory internal _factory;
  MockToken internal _xyz;
  MockVenue internal _venue;

  function setUp() public virtual {
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
    _factory = new BlankFactory(_entrypoint);
    _xyz = new MockToken();
    _venue = new MockVenue(_TOKENS_PER_ETH);
    vm.deal(address(_venue), 1000 ether);
  }

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

  /// @dev The ASP approves every label in the shadow ASP tree
  function _approveLabels() internal {
    vm.prank(_POSTMAN);
    _entrypoint.updateRoot(_shadowASPMerkleTree._root(), _CID);
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
    _c.label = _nextLabel();
    _c.value = _amount - (_amount * _VETTING_FEE_BPS) / 10_000;
    _c.precommitment = _hashPrecommitment(_c.nullifier, _c.secret);
    _c.hash = _hashCommitment(_c.value, _c.label, _c.precommitment);

    _insertIntoShadowMerkleTree(_c.hash);
    _insertIntoShadowASPMerkleTree(_c.label);

    vm.deal(_ALICE, _amount);
    vm.prank(_ALICE);
    _entrypoint.deposit{value: _amount}(_c.precommitment);
    _approveLabels();
  }

  function _nextLabel() internal view returns (uint256) {
    return uint256(keccak256(abi.encodePacked(_pool.SCOPE(), _pool.nonce() + 1))) % Constants.SNARK_SCALAR_FIELD;
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

  /// @dev Proves and relays a buy; returns the change note and what the blank received
  function _buy(
    Commitment memory _note,
    uint256 _spend,
    IBurnerRouter.BuyData memory _d
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

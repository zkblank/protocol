// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {ERC1967Proxy} from '@oz/proxy/ERC1967/ERC1967Proxy.sol';
import {IERC20} from '@oz/interfaces/IERC20.sol';
import {Script} from 'forge-std/Script.sol';

import {Entrypoint} from 'contracts/Entrypoint.sol';
import {PrivacyPoolSimple} from 'contracts/implementations/PrivacyPoolSimple.sol';
import {Constants} from 'contracts/lib/Constants.sol';
import {CommitmentVerifier} from 'contracts/verifiers/CommitmentVerifier.sol';
import {WithdrawalVerifier} from 'contracts/verifiers/WithdrawalVerifier.sol';
import {BlankFactory} from 'contracts/zkblank/BlankFactory.sol';
import {DropFactory} from 'contracts/zkblank/DropFactory.sol';
import {BurnerRouter} from 'contracts/zkblank/BurnerRouter.sol';
import {IPrivacyPool} from 'interfaces/IPrivacyPool.sol';

import {MockToken, MockVenue} from 'test/zkblank/Mocks.sol';

/**
 * @notice ZKBLANK on a LOCAL chain (anvil, chain id 31337): the upstream Entrypoint and native pool with the real
 *         Groth16 verifiers, BurnerRouter, BlankFactory, and a test token plus a fixed-price venue.
 *         Refuses any other chain: the mock token and venue must never reach a public network.
 *
 *   DEPLOYER_PK=0x.. POSTMAN=0x.. forge script script/zkblank/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
 *
 * Writes the addresses to deployments/zkblank-local.json.
 */
contract DeployLocal is Script {
  uint256 internal constant _VETTING_FEE_BPS = 10; // 0.10%, the Dark Drop fee
  uint256 internal constant _MAX_RELAY_FEE_BPS = 500;
  uint256 internal constant _TOKENS_PER_ETH = 2_408_660 ether;

  struct Deployed {
    address entrypoint;
    address pool;
    uint256 scope;
    address router;
    address factory;
    address drops;
    address token;
    address venue;
  }

  function run() external {
    require(block.chainid == 31_337, 'DeployLocal: local chain only');
    uint256 _pk = vm.envUint('DEPLOYER_PK');
    address _postman = vm.envAddress('POSTMAN');

    vm.startBroadcast(_pk);
    Deployed memory _d = _deployCore(vm.addr(_pk), _postman);
    _deployLocalVenue(_d);
    vm.stopBroadcast();

    _write(_d, _postman);
  }

  function _deployCore(address _deployer, address _postman) internal returns (Deployed memory _d) {
    WithdrawalVerifier _withdrawalVerifier = new WithdrawalVerifier();
    CommitmentVerifier _commitmentVerifier = new CommitmentVerifier();
    address _impl = address(new Entrypoint());
    Entrypoint _entrypoint = Entrypoint(
      payable(address(new ERC1967Proxy(_impl, abi.encodeCall(Entrypoint.initialize, (_deployer, _postman)))))
    );
    PrivacyPoolSimple _pool =
      new PrivacyPoolSimple(address(_entrypoint), address(_withdrawalVerifier), address(_commitmentVerifier));
    _entrypoint.registerPool(
      IERC20(Constants.NATIVE_ASSET), IPrivacyPool(address(_pool)), 1, _VETTING_FEE_BPS, _MAX_RELAY_FEE_BPS
    );

    _d.entrypoint = address(_entrypoint);
    _d.pool = address(_pool);
    _d.scope = _pool.SCOPE();
    _d.router = address(new BurnerRouter());
    _d.factory = address(new BlankFactory(_entrypoint));
    _d.drops = address(new DropFactory(_entrypoint));
  }

  function _deployLocalVenue(Deployed memory _d) internal {
    _d.token = address(new MockToken());
    _d.venue = address(new MockVenue(_TOKENS_PER_ETH));
    (bool _ok,) = _d.venue.call{value: 100 ether}('');
    require(_ok, 'DeployLocal: venue funding failed');
  }

  function _write(Deployed memory _d, address _postman) internal {
    string memory _o = 'zkblank';
    vm.serializeUint(_o, 'chainId', block.chainid);
    vm.serializeUint(_o, 'startBlock', block.number);
    vm.serializeAddress(_o, 'entrypoint', _d.entrypoint);
    vm.serializeAddress(_o, 'pool', _d.pool);
    vm.serializeUint(_o, 'scope', _d.scope);
    vm.serializeAddress(_o, 'burnerRouter', _d.router);
    vm.serializeAddress(_o, 'blankFactory', _d.factory);
    vm.serializeAddress(_o, 'dropFactory', _d.drops);
    vm.serializeAddress(_o, 'token', _d.token);
    vm.serializeAddress(_o, 'venue', _d.venue);
    string memory _json = vm.serializeAddress(_o, 'postman', _postman);
    vm.writeJson(_json, 'deployments/zkblank-local.json');
  }
}

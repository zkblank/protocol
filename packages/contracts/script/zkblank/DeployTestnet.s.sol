// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {DeployLocal} from 'script/zkblank/DeployLocal.s.sol';

/// @dev Arbitrum precompile at 0x64: on Orbit chains block.number is the L1 block, arbBlockNumber() is the chain's own
interface IArbSys {
  function arbBlockNumber() external view returns (uint256);
}

/**
 * @notice ZKBLANK on Robinhood Chain TESTNET (chain id 46630) only. Same contracts as the local deploy, plus a test
 *         token and a fixed-price test venue so the full loop can run before real venues are wired. Refuses every
 *         other chain, mainnet 4663 included: the test token and venue must never reach mainnet.
 *
 *   DEPLOYER=0x.. POSTMAN=0x.. VENUE_FUNDING_WEI=.. forge script script/zkblank/DeployTestnet.s.sol \
 *     --rpc-url https://rpc.testnet.chain.robinhood.com --account <keystore> --broadcast --slow
 *
 * Writes the addresses to deployments/zkblank-testnet.json.
 */
contract DeployTestnet is DeployLocal {
  function run() external override {
    require(block.chainid == 46_630, 'DeployTestnet: Robinhood Chain testnet only');
    address _deployer = vm.envAddress('DEPLOYER');
    address _postman = vm.envAddress('POSTMAN');
    uint256 _funding = vm.envUint('VENUE_FUNDING_WEI');

    vm.startBroadcast(_deployer);
    Deployed memory _d = _deployCore(_deployer, _postman);
    _deployLocalVenue(_d, _funding);
    vm.stopBroadcast();

    _write(_d, _postman, 'deployments/zkblank-testnet.json');
  }

  function _startBlock() internal view override returns (uint256) {
    return IArbSys(address(100)).arbBlockNumber();
  }
}

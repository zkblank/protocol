# ZKBLANK fork of Privacy Pools core

Base: [0xbow-io/privacy-pools-core](https://github.com/0xbow-io/privacy-pools-core) at `df4bf73`, Apache-2.0.
Why this base: deposits, a Merkle tree of notes, nullifiers and association sets (ASP roots) are already built
and audited. ZKBLANK adds the trading side on top: spends that pay a swap into a one-life wallet (a blank) and
sells that come back in as new notes.

## Step 1: fork and baseline (2026-11-19)

| Check | Result |
|---|---|
| Circuits (circom 2.2.1, same as upstream CI) | 18 / 18 passing |
| Contracts unit tests (Foundry 1.8.1) | 107 / 110 passing |

Changes so far, toolchain only, no protocol logic touched:

- `packages/contracts/remappings.txt`: `lean-imt/` now points at `deps/lean-imt/`, a symlink to
  `node_modules/@zk-kit/lean-imt.sol`. Foundry 1.8.1 drops the trailing slash of a remapping target that
  ends in `.sol/`, so the upstream mapping no longer resolves.
- `packages/contracts/foundry.toml`: `evm_version = 'cancun'`. Newer Foundry defaults to Prague, which adds
  precompiles above `0x0a` that the upstream fuzz tests do not exclude.

Known open items (test harness, not contract logic):

- `UnitReceive.test_nativeAssetTransferToEntrypointFails`: the test sends ETH with `transfer` (2,300 gas),
  which runs out of gas inside the proxy before the expected `NativeAssetNotAccepted` revert. ETH is still
  refused; only the expected error differs.
- `UnitDeposit.test_DepositETHGivenValueMeetsMinimum` and `test_DepositERC20GivenValueMeetsMinimum`: fail
  for some fuzz inputs with very low addresses; under investigation in step 2.

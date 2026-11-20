# ZKBLANK fork of Privacy Pools core

Base: [0xbow-io/privacy-pools-core](https://github.com/0xbow-io/privacy-pools-core) at `df4bf73`, Apache-2.0.
Why this base: deposits, a Merkle tree of notes, nullifiers and association sets (ASP roots) are already built
and audited. ZKBLANK adds the trading side on top: spends that pay a swap into a one-life wallet (a blank) and
sells that come back in as new notes.

## Step 2: a spend that pays a swap into a blank (2026-11-20)

No circuit change. The upstream withdraw circuit already takes a public `context`, and `PrivacyPool.withdraw`
requires `context == keccak256(abi.encode(withdrawal, scope)) % SNARK_SCALAR_FIELD` and
`msg.sender == withdrawal.processooor`. So a buy is a withdrawal whose processooor is the new `BurnerRouter` and
whose `data` is the whole trade:

```solidity
struct BuyData {
  address blank;        // the one-life wallet that receives the tokens
  address tokenOut;
  uint256 minAmountOut;
  uint256 deadline;
  address adapter;      // the venue (launchpad curve, Uniswap pool, ...)
  bytes adapterData;
  address feeRecipient; // the relayer
  uint256 relayFeeBPS;  // capped at 10% by the router
}
```

Every field sits inside the proof's context, so a relayer can carry the trade but cannot change any of it.
The audited circuit and its keys stay untouched.

New files:

- `src/contracts/zkblank/BurnerRouter.sol`: no owner, no upgrade path, holds no funds between calls. Accepts ETH
  only from the pool it is spending in the current call, pays the relay fee, swaps the rest through the adapter
  straight into the blank, and checks the blank's own balance (the adapter's return value is not trusted).
- `src/interfaces/zkblank/IBurnerRouter.sol`, `src/interfaces/zkblank/ISwapAdapter.sol`.
- `test/zkblank/BurnerRouter.t.sol`: end to end with real Groth16 proofs from the upstream circuit and keys,
  no mainnet fork. Run with `forge test --match-contract ZkblankBurnerRouter --ffi`.

| Test (real proofs) | Result |
|---|---|
| One note pays two buys into two blanks; change stays a private note | pass |
| Relayer lowers the minimum out | reverts `ContextMismatch` |
| Relayer redirects the tokens away from the blank | reverts `ContextMismatch` |
| Relayer raises its own fee | reverts `ContextMismatch` |
| Same proof submitted twice | reverts (nullifier spent) |
| Trade held past its deadline | reverts `DeadlinePassed` |
| Venue under-delivers while reporting the full amount | reverts `InsufficientOutput` |
| Stray ETH sent to the router | refused |

Blanks are plain addresses in this step; counterfactual blank accounts (BlankFactory) and the sell path come
next. Native asset pools only for now.

## Step 1: fork and baseline (2026-11-19)

| Check | Step 1 | Now |
|---|---|---|
| Circuits (circom 2.2.1, same as upstream CI) | 18 / 18 | 18 / 18 |
| Contracts unit tests (Foundry 1.8.1, 5 fuzz seeds) | 107 / 110 | 110 / 110 |
| BurnerRouter, real proofs | | 8 / 8 |

Toolchain changes, no protocol logic touched:

- `packages/contracts/remappings.txt`: `lean-imt/` points at `deps/lean-imt/`, a symlink to
  `node_modules/@zk-kit/lean-imt.sol`. Foundry 1.8.1 drops the trailing slash of a remapping target that
  ends in `.sol/`, so the upstream mapping no longer resolves.
- `packages/contracts/foundry.toml`: `evm_version = 'cancun'`. Newer Foundry defaults to Prague, which adds
  precompiles above `0x0a` that the upstream fuzz tests do not exclude.

Test harness fixes (step 2), each marked `ZKBLANK fork:` in the test file:

- `UnitReceive.test_nativeAssetTransferToEntrypointFails`: sent ETH with `transfer` (2,300 gas), which ran out
  of gas inside the proxy before the expected `NativeAssetNotAccepted`. Now a plain call, checking the revert
  selector.
- `UnitDeposit.test_DepositETHGivenValueMeetsMinimum`: Foundry 1.x moves the value of a mocked call, so the
  pool receives the amount after fees and the Entrypoint keeps the fee. The assertion now checks both balances.
- `UnitDeposit.test_DepositERC20GivenValueMeetsMinimum`: the fuzzer fed the native asset sentinel as an ERC20
  address; it is now excluded.

Local note: the upstream SDK reads circuit files with `URL.pathname`, which breaks under a path with spaces.
Running from such a path needs `decodeURIComponent` in the SDK's `fetchArtifacts.node` (node_modules only, not
part of this repository).

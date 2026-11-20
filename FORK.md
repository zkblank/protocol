# ZKBLANK fork of Privacy Pools core

Base: [0xbow-io/privacy-pools-core](https://github.com/0xbow-io/privacy-pools-core) at `df4bf73`, Apache-2.0.
Why this base: deposits, a Merkle tree of notes, nullifiers and association sets (ASP roots) are already built
and audited. ZKBLANK adds the trading side on top: spends that pay a swap into a one-life wallet (a blank) and
sells that come back in as new notes.

## Step 6: live on Robinhood Chain testnet (2026-11-20)

Deployed with `script/zkblank/DeployTestnet.s.sol` (chain 46630 only) and verified on the testnet explorer.
Addresses: `packages/contracts/deployments/zkblank-testnet.json`.

| Contract | Address |
|---|---|
| Entrypoint (proxy) | [`0xfBBd680F1bA8dA5C491E140FbA057E7D151c84dA`](https://explorer.testnet.chain.robinhood.com/address/0xfBBd680F1bA8dA5C491E140FbA057E7D151c84dA) |
| PrivacyPoolSimple (ETH) | [`0x62C001eE57D276735860166864447252FEE5b6a2`](https://explorer.testnet.chain.robinhood.com/address/0x62C001eE57D276735860166864447252FEE5b6a2) |
| BurnerRouter | [`0xb16CC087A9fd8e3D854b34913889f3c15918F72D`](https://explorer.testnet.chain.robinhood.com/address/0xb16CC087A9fd8e3D854b34913889f3c15918F72D) |
| BlankFactory | [`0x5dC4263cDf4329556364553de438d8D692295d0c`](https://explorer.testnet.chain.robinhood.com/address/0x5dC4263cDf4329556364553de438d8D692295d0c) |
| DropFactory | [`0xe4d69C06d82B9fA8eB44EfAFbAf8eACE152cd59d`](https://explorer.testnet.chain.robinhood.com/address/0xe4d69C06d82B9fA8eB44EfAFbAf8eACE152cd59d) |
| Test token / test venue (testnet only) | `0x242dA7c3B3E191153e9cc47Deb1040B8B1F3699F` / `0xe2c87827FDD0CECB96E2Bc45bb9E618f3E23B2Fb` |

The full loop ran on testnet with the services pointed at the public RPC (`e2e/run-testnet.sh`):

| Step | Transaction |
|---|---|
| Pay a Dark Drop address by plain transfer | [pay](https://explorer.testnet.chain.robinhood.com/tx/0xefa0e734135d2d42a135c9790d23f87015d30e6dd16cffbf70eb5f9dcb44c4de) |
| Relayer sweeps it into the sealed note | [sweep](https://explorer.testnet.chain.robinhood.com/tx/0x96dabc805fe66f804c57f10a2bef18df96fe2553536bbecfe2bb3cbe4eec4e10) |
| Buy into blank #1 (proof built client side, ~2.8 s) | [buy](https://explorer.testnet.chain.robinhood.com/tx/0xdff98b8e8157e48bf4e77cde1933f64d03cf2727c7f1fdf5896305a717e8a236) |
| Sell blank #1 back into the vault | [sell](https://explorer.testnet.chain.robinhood.com/tx/0x2dedbf4486c654ba926a4cac27a9c062372f5b4f01f86ac2f13f18186b9a25bf) |
| Buy into blank #2 from the proceeds | [buy](https://explorer.testnet.chain.robinhood.com/tx/0x2d66a7cea58f3a29057e76808bcc58fe711bafa5ff36adcf69e7fe88e8e98b31) |
| Tampered buy | refused at simulation (`ContextMismatch`), no transaction |

Fixes found on a live chain:
- Robinhood Chain is an Arbitrum Orbit chain: `block.number` inside a contract is the L1 block. The testnet deploy
  records the start block from `ArbSys.arbBlockNumber()`.
- The indexer reads logs in windows of `MAX_RANGE` blocks (default 5,000) and the client waits for its note's leaf
  in the tree before proving.

Known gap: the reference services run on a developer machine for now; the relay, indexer and ASP are not yet hosted.

## Repository housekeeping (2026-11-20)

- `README.md` now describes ZKBLANK. The upstream README is in the upstream history (commit `df4bf73`).
- Upstream workflows moved to `.github/workflows-upstream/` so GitHub Actions never runs them here; two of them
  publish the upstream SDK to npm with upstream secrets.

## Step 5: Dark Drop, money in from anywhere (2026-11-20)

- `src/contracts/zkblank/DropFactory.sol`: `predict(dropKey, precommitment, keeperFeeBPS)` is a CREATE2 clone
  address that exists before anything is deployed, so it can be paid by a plain transfer from any wallet, bridge
  or exchange withdrawal. `sweep(...)` (anyone) deploys it and deposits the balance as the note the user sealed.
  The salt commits to the precommitment and the keeper fee (capped at 1%), so a sweeper can only ever produce the
  user's note and take the fee the user offered. No owner, no upgrade path.
- `src/contracts/zkblank/DropBox.sol`: the box itself. ETH that arrives after the first sweep is never stuck: the
  drop key signs an EIP-712 `Resweep(newPrecommitment, deadline)` and anyone submits it. A reused precommitment is
  refused by the Entrypoint, so a resweep cannot be replayed.
- Relayer: `POST /v1/relay/sweep { owner, precommitment, keeperFeeBPS }`. The e2e now starts with a Dark Drop.
- Tests: `test/zkblank/DarkDrop.t.sol`, 12 cases including a real-proof round trip (pay the drop from a wallet,
  sweep, buy into a blank from the note).

All ZKBLANK tests: 32 / 32 with real proofs (`forge test --match-path "test/zkblank/*" --ffi`). Upstream unit: 110 / 110.

Known limit, for the ASP: the vault records the drop box as the depositor, not the wallet that paid it. Screening
the real source means tracing the box's incoming transfers; the reference ASP still screens the depositor only.

## Step 4: the whole loop on a local chain, through real services (2026-11-20)

- `packages/contracts/script/zkblank/DeployLocal.s.sol`: deploys the upstream Entrypoint and native pool with the
  real verifiers, BurnerRouter, BlankFactory, and a test token plus venue. Refuses any chain but 31337.
- `packages/zkblank-services/`: indexer (public tree and roots, served whole), association-set provider (screens
  deposits, posts the approved root), relayer (`/v1/relay/buy`, `/v1/relay/sell`). Plain Node, no database,
  no cookies, no request logging. See its README.
- `packages/zkblank-services/e2e/run-local.sh`: anvil, deploy, services, then `e2e/client.mjs` acting as the app.

Last run (anvil 31337, all through HTTP):

| Step | Result |
|---|---|
| Deposit 1 ETH, ASP screens it and posts the root | approved |
| Buy 0.5 ETH into blank #1 (proof built in Node from the indexer's tree) | 1,201,319 $XYZ, blank has no code; proof ~3 s; 538k gas |
| Sell blank #1 back into the vault (EIP-712 intent) | proceeds note 0.497 ETH, blank emptied; 452k gas |
| Buy into blank #2 from the proceeds | 597,062 $XYZ; proof ~2.2 s; 506k gas |
| Tampered buy (blank swapped after proving) | relayer refuses at simulation: `ContextMismatch`, no transaction |

Mock token and venue live in `test/zkblank/Mocks.sol` and are deployed only by the local script.

## Step 3: counterfactual blanks and the sell back into the dark (2026-11-20)

A blank is now a real one-life account:

- `src/contracts/zkblank/BlankFactory.sol`: `predict(owner)` gives the blank's address from its key before
  anything exists on chain (CREATE2 minimal clone), so a buy pays straight into it. `deployAndSell` deploys it
  and runs its one sale in the same transaction. No owner, no upgrade path.
- `src/contracts/zkblank/BlankAccount.sol`: the owner key signs one EIP-712 `SellIntent` (token, amount, minimum
  ETH out, deadline, venue, the precommitment of the note the proceeds become, relay fee). The domain binds the
  chain and this blank's address. The blank sells through the venue, measures the ETH that arrived, pays the
  relayer from it, deposits the rest through `Entrypoint.deposit(precommitment)` and retires, before any
  external call. It never needs gas and accepts ETH only from the venue during its sale.
- `src/interfaces/zkblank/IBlankAccount.sol`, `src/interfaces/zkblank/ISellAdapter.sol`.
- Tests: `test/zkblank/ZkblankBase.sol` (shared setup and helpers), `test/zkblank/BlankLifecycle.t.sol`.

| Test | Result |
|---|---|
| Buy into a counterfactual blank, sell it back, buy blank #18 from the proceeds (real proofs) | pass |
| Relayer lowers the minimum out / redirects the proceeds / raises its fee | reverts `InvalidSignature` |
| Another key signs the sale | reverts `InvalidSignature` |
| A signature for one blank used on another | reverts `InvalidSignature` |
| A second sale, even with a fresh owner signature | reverts `Retired` |
| Sale past its deadline / venue under-delivers | reverts `DeadlinePassed` / `InsufficientOutput` |
| The implementation contract used directly | reverts |
| On-chain digest equals the one the app computes before the blank exists | pass |

All ZKBLANK tests at step 3: 20 / 20 (`forge test --match-path "test/zkblank/*" --ffi`). Upstream unit tests: 110 / 110.

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

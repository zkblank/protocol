// ZKBLANK association-set provider (local reference implementation).
// Screens every new deposit's source against a deny list, keeps the approved labels in order, and posts the
// approved root on chain with the postman key. Flagged deposits never join the set: they can only ragequit.
// Production screening (sanctions lists, exploit addresses) plugs in where `screen` is.
//   GET /v1/health   GET /v1/asp
import { LeanIMT } from '@zk-kit/lean-imt';
import { poseidon2 } from 'poseidon-lite';
import { keccak256, toHex } from 'viem';
import { ABI, clients, loadConfig, serve, shortError, sleep } from './common.mjs';

const cfg = loadConfig();
const { publicClient, walletClient } = clients(cfg, process.env.POSTMAN_PK);
const port = Number(process.env.ASP_PORT ?? 8702);
const indexer = process.env.INDEXER_URL ?? 'http://127.0.0.1:8701';
const deny = new Set((process.env.DENYLIST ?? '').split(',').filter(Boolean).map((a) => a.toLowerCase()));

const state = { seen: 0, labels: [], flagged: [], root: 0n, posted: 0n };

const screen = (deposit) => !deny.has(deposit.depositor.toLowerCase());

// The same LeanIMT (Poseidon, 2 inputs) the circuit and the pool use
const rootOf = (labels) => new LeanIMT((a, b) => poseidon2([a, b]), labels).root;

async function tick() {
  const r = await fetch(`${indexer}/v1/deposits`);
  const { deposits } = await r.json();
  for (const d of deposits.slice(state.seen)) {
    (screen(d) ? state.labels : state.flagged).push(BigInt(d.label));
  }
  state.seen = deposits.length;
  if (state.labels.length === 0) return;

  state.root = rootOf(state.labels);
  if (state.root === state.posted) return;

  // The CID would point at the published label list; locally it is a deterministic placeholder
  const cid = `local-asp-${keccak256(toHex(state.root)).slice(2, 44)}`;
  const hash = await walletClient.writeContract({
    address: cfg.dep.entrypoint,
    abi: ABI.entrypoint,
    functionName: 'updateRoot',
    args: [state.root, cid],
  });
  await publicClient.waitForTransactionReceipt({ hash });
  state.posted = state.root;
  console.log(`asp: approved ${state.labels.length} label(s), flagged ${state.flagged.length}, root posted`);
}

(async () => {
  // After a restart, do not re-post a root the chain already has
  try {
    state.posted = await publicClient.readContract({ address: cfg.dep.entrypoint, abi: ABI.entrypoint, functionName: 'latestRoot' });
  } catch (e) {
    console.error('asp: could not read latestRoot:', shortError(e));
  }
  for (;;) {
    try {
      await tick();
    } catch (e) {
      console.error('asp tick failed:', shortError(e));
    }
    await sleep(Number(process.env.POLL_MS ?? 800));
  }
})();

serve('asp', port, {
  'GET /v1/health': async () => [200, { ok: true, approved: state.labels.length, flagged: state.flagged.length }],
  'GET /v1/asp': async () => [200, { root: state.posted, labels: state.labels, flagged: state.flagged.length }],
});

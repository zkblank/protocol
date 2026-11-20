// ZKBLANK indexer: public chain data only. It follows the pool's tree and the ASP roots and serves them whole,
// so a browser can build its own Merkle proofs without telling anyone which leaf it cares about.
//   GET /v1/health   GET /v1/tree   GET /v1/deposits   GET /v1/roots
import { ABI, clients, loadConfig, serve, shortError, sleep } from './common.mjs';

const cfg = loadConfig();
const { publicClient } = clients(cfg);
const port = Number(process.env.INDEXER_PORT ?? 8701);

const state = { block: BigInt(cfg.dep.startBlock ?? 0) - 1n, leaves: [], deposits: [], aspRoot: 0n, stateRoot: 0n };

async function poll() {
  const latest = await publicClient.getBlockNumber();
  if (latest <= state.block) return;
  const range = { fromBlock: state.block + 1n, toBlock: latest };
  const [leaves, deposits, roots] = await Promise.all([
    publicClient.getContractEvents({ address: cfg.dep.pool, abi: ABI.pool, eventName: 'LeafInserted', ...range }),
    publicClient.getContractEvents({ address: cfg.dep.pool, abi: ABI.pool, eventName: 'Deposited', ...range }),
    publicClient.getContractEvents({ address: cfg.dep.entrypoint, abi: ABI.entrypoint, eventName: 'RootUpdated', ...range }),
  ]);
  for (const l of leaves) {
    // State emits the tree size after the insert, so the leaf's position is size - 1
    state.leaves[Number(l.args._index) - 1] = l.args._leaf;
    state.stateRoot = l.args._root;
  }
  for (const d of deposits) {
    state.deposits.push({
      depositor: d.args._depositor,
      commitment: d.args._commitment,
      label: d.args._label,
      value: d.args._value,
      block: d.blockNumber,
    });
  }
  for (const r of roots) state.aspRoot = r.args._root;
  state.block = latest;
}

(async () => {
  for (;;) {
    try {
      await poll();
    } catch (e) {
      console.error('indexer poll failed:', shortError(e));
    }
    await sleep(Number(process.env.POLL_MS ?? 800));
  }
})();

serve('indexer', port, {
  'GET /v1/health': async () => [200, { ok: true, block: state.block, leaves: state.leaves.length }],
  'GET /v1/tree': async () => [200, { block: state.block, root: state.stateRoot, leaves: state.leaves }],
  'GET /v1/deposits': async () => [200, { block: state.block, deposits: state.deposits }],
  'GET /v1/roots': async () => [200, { block: state.block, stateRoot: state.stateRoot, aspRoot: state.aspRoot }],
});

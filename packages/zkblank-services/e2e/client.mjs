// ZKBLANK end to end, the way the app will do it, against a running chain + indexer + ASP + relayer:
//   1. Dark Drop: Alice pays 1 ETH by plain transfer to a one-time drop address; the relayer sweeps it into the
//      note her browser sealed, and the ASP approves it
//   2. Burner Mode: her browser builds the Merkle proofs from the indexer's public tree, proves a spend bound to
//      a BuyData, and the relayer buys 0.5 ETH of $XYZ into blank #1 (an address with no code)
//   3. Sell back: blank #1's key signs one SellIntent; the relayer deploys it, sells, and the proceeds become a
//      new note sealed with Alice's precommitment
//   4. The proceeds pay for a buy into blank #2
// The client is the only party that ever holds a secret. Writes a summary to e2e/last-run.json.
import { randomBytes } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { Circuits, PrivacyPoolSDK, generateMerkleProof, getCommitment, hashPrecommitment } from '@0xbow/privacy-pools-core-sdk';
import { LeanIMT } from '@zk-kit/lean-imt';
import { poseidon2 } from 'poseidon-lite';
import { decodeAbiParameters, encodeAbiParameters, formatEther, getAddress, keccak256 } from 'viem';
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts';
import { ABI, BUY_DATA, SELL_TYPES, SNARK_SCALAR_FIELD, clients, loadConfig, sellDomain, sleep, toJson } from '../src/common.mjs';

const cfg = loadConfig();
const { publicClient, walletClient: alice } = clients(cfg, process.env.ALICE_PK);
const INDEXER = process.env.INDEXER_URL ?? 'http://127.0.0.1:8701';
const ASP = process.env.ASP_URL ?? 'http://127.0.0.1:8702';
const RELAYER = process.env.RELAYER_URL ?? 'http://127.0.0.1:8703';
const RELAY_FEE_BPS = 25n;
const TOKENS_PER_ETH = 2_408_660n * 10n ** 18n;
// The amount Alice drops; buys are half of the note. Local default 1 ETH, testnet runs pass a small DEPOSIT_WEI.
const AMOUNT = BigInt(process.env.DEPOSIT_WEI ?? 10n ** 18n);
const WAIT_MS = Number(process.env.WAIT_MS ?? 30000);

const sdk = new PrivacyPoolSDK(new Circuits({ browser: false }));
const scope = BigInt(cfg.dep.scope);
const summary = { chainId: cfg.chain.id, steps: [] };
const log = (step, data) => {
  summary.steps.push({ step, ...data });
  console.log(`✓ ${step}`, toJson(data));
};

const secret = () => BigInt(`0x${randomBytes(31).toString('hex')}`);
const getJson = async (url) => (await fetch(url)).json();
const post = async (url, body) => {
  const r = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: toJson(body) });
  const j = await r.json();
  if (!r.ok) throw new Error(`${url}: ${j.error}`);
  return j;
};

async function waitFor(what, fn, timeoutMs = WAIT_MS) {
  const t0 = Date.now();
  for (;;) {
    const v = await fn();
    if (v) return v;
    if (Date.now() - t0 > timeoutMs) throw new Error(`timed out waiting for ${what}`);
    await sleep(400);
  }
}

/** Waits until the indexer has the deposit and the ASP has approved its label on chain */
async function waitApproved(match) {
  const dep = await waitFor('deposit in the indexer', async () =>
    (await getJson(`${INDEXER}/v1/deposits`)).deposits.find(match),
  );
  await waitFor('ASP approval on chain', async () => {
    const asp = await getJson(`${ASP}/v1/asp`);
    const roots = await getJson(`${INDEXER}/v1/roots`);
    return asp.labels.includes(dep.label) && roots.aspRoot === asp.root && asp.root !== '0';
  });
  return dep;
}

/** Proves a spend of `note` bound to `buyData` and has the relayer buy into the blank */
async function buyIntoBlank(note, spend, buyData, tamper) {
  const withdrawal = {
    processooor: cfg.dep.burnerRouter,
    data: encodeAbiParameters(BUY_DATA, [buyData]),
  };
  const context =
    BigInt(
      keccak256(
        encodeAbiParameters(
          [{ type: 'tuple', components: [{ name: 'processooor', type: 'address' }, { name: 'data', type: 'bytes' }] }, { type: 'uint256' }],
          [withdrawal, scope],
        ),
      ),
    ) % SNARK_SCALAR_FIELD;

  // Everything below is public data the indexer serves whole: no request names the leaf we care about.
  // On a live chain the indexer can trail by a few blocks, so wait until the note's leaf is in the tree.
  const target = getCommitment(note.value, note.label, note.nullifier, note.secret).hash.toString();
  const tree = await waitFor('the note in the indexer tree', async () => {
    const t = await getJson(`${INDEXER}/v1/tree`);
    return t.leaves.includes(target) ? t : null;
  });
  const asp = await getJson(`${ASP}/v1/asp`);
  const leaves = tree.leaves.map(BigInt);
  const labels = asp.labels.map(BigInt);
  const commitment = getCommitment(note.value, note.label, note.nullifier, note.secret);
  const stateProof = generateMerkleProof(leaves, commitment.hash);
  const aspProof = generateMerkleProof(labels, note.label);
  const depth = (xs) => new LeanIMT((a, b) => poseidon2([a, b]), xs).depth;
  const pad = (s) => [...s, ...Array(32 - s.length).fill(0n)];
  const fixIndex = (p) => (Number.isNaN(p.index) ? 0 : p.index);

  const change = { value: note.value - spend, label: note.label, nullifier: secret(), secret: secret() };
  const t0 = Date.now();
  const { proof, publicSignals } = await sdk.proveWithdrawal(commitment, {
    context,
    withdrawalAmount: spend,
    stateMerkleProof: { root: stateProof.root, leaf: commitment.hash, index: fixIndex(stateProof), siblings: pad(stateProof.siblings) },
    aspMerkleProof: { root: aspProof.root, leaf: commitment.hash, index: fixIndex(aspProof), siblings: pad(aspProof.siblings) },
    stateRoot: stateProof.root,
    stateTreeDepth: BigInt(depth(leaves)),
    aspRoot: aspProof.root,
    aspTreeDepth: BigInt(depth(labels)),
    newSecret: change.secret,
    newNullifier: change.nullifier,
  });
  const proveMs = Date.now() - t0;

  // `tamper` lets the e2e play a dishonest relayer client: edit the request after proving
  const sent = tamper ? tamper(withdrawal) : withdrawal;
  const res = await post(`${RELAYER}/v1/relay/buy`, {
    withdrawal: sent,
    proof: {
      pA: proof.pi_a.slice(0, 2),
      pB: [
        [proof.pi_b[0][1], proof.pi_b[0][0]],
        [proof.pi_b[1][1], proof.pi_b[1][0]],
      ],
      pC: proof.pi_c.slice(0, 2),
      pubSignals: publicSignals.slice(0, 8),
    },
  });
  return { change, proveMs, res };
}

async function main() {
  const details = await getJson(`${RELAYER}/v1/relayer/details`);
  const feeRecipient = getAddress(details.feeRecipient);

  // 1. Dark Drop: a one-time address paid by a plain transfer, swept by the relayer, approved by the ASP
  const note = { nullifier: secret(), secret: secret() };
  const precommitment = hashPrecommitment(note.nullifier, note.secret);
  const dropKey = privateKeyToAccount(generatePrivateKey());
  const keeperFeeBPS = BigInt(details.minKeeperFeeBPS);
  const drop = await publicClient.readContract({
    address: cfg.dep.dropFactory, abi: ABI.drops, functionName: 'predict', args: [dropKey.address, precommitment, keeperFeeBPS],
  });
  const payHash = await alice.sendTransaction({ to: drop, value: AMOUNT });
  await publicClient.waitForTransactionReceipt({ hash: payHash });
  const dropCode = await publicClient.getCode({ address: drop });
  const sweep = await post(`${RELAYER}/v1/relay/sweep`, { owner: dropKey.address, precommitment, keeperFeeBPS });
  const dep1 = await waitApproved((d) => d.depositor.toLowerCase() === drop.toLowerCase());
  note.label = BigInt(dep1.label);
  note.value = BigInt(dep1.value);
  if (BigInt(dep1.commitment) !== getCommitment(note.value, note.label, note.nullifier, note.secret).hash) {
    throw new Error('the swept note is not the one Alice sealed');
  }
  log(`Dark Drop: pay ${formatEther(AMOUNT)} ETH to a one-time address, relayer sweeps, ASP approves`, {
    drop, dropHadCode: Boolean(dropCode && dropCode !== '0x'), payTx: payHash, sweepTx: sweep.txHash, noteValue: formatEther(note.value),
  });

  // 2. Buy into blank #1, a counterfactual address
  const blank1Key = privateKeyToAccount(generatePrivateKey());
  const blank1 = await publicClient.readContract({ address: cfg.dep.blankFactory, abi: ABI.factory, functionName: 'predict', args: [blank1Key.address] });
  const deadline = () => BigInt(Math.floor(Date.now() / 1000) + 300);
  const spend1 = note.value / 2n;
  const buy1 = await buyIntoBlank(note, spend1, {
    blank: blank1, tokenOut: cfg.dep.token, minAmountOut: 1n, deadline: deadline(),
    adapter: cfg.dep.venue, adapterData: '0x', feeRecipient, relayFeeBPS: RELAY_FEE_BPS,
  });
  const held = await publicClient.readContract({ address: cfg.dep.token, abi: ABI.erc20, functionName: 'balanceOf', args: [blank1] });
  const code1 = await publicClient.getCode({ address: blank1 });
  if (held === 0n || (code1 && code1 !== '0x')) throw new Error('blank #1 should hold tokens and have no code');
  log(`buy ${formatEther(spend1)} ETH into blank #1 via relayer`, {
    blank: blank1, tokens: formatEther(held), blankHasCode: false, proveMs: buy1.proveMs, tx: buy1.res.txHash, gasUsed: buy1.res.gasUsed,
  });

  // 3. Sell blank #1 back into the dark
  const sellNote = { nullifier: secret(), secret: secret() };
  const ethOut = (held * 10n ** 18n) / TOKENS_PER_ETH;
  const intent = {
    tokenIn: cfg.dep.token, amountIn: held, minEthOut: (ethOut * 99n) / 100n, deadline: deadline(),
    adapter: cfg.dep.venue, adapterData: '0x', precommitment: hashPrecommitment(sellNote.nullifier, sellNote.secret),
    feeRecipient, relayFeeBPS: RELAY_FEE_BPS,
  };
  const signature = await blank1Key.signTypedData({
    domain: sellDomain(cfg.chain.id, blank1), types: SELL_TYPES, primaryType: 'SellIntent', message: intent,
  });
  const sell = await post(`${RELAYER}/v1/relay/sell`, { owner: blank1Key.address, intent, signature });
  const dep2 = await waitApproved((d) => d.depositor.toLowerCase() === blank1.toLowerCase());
  sellNote.label = BigInt(dep2.label);
  sellNote.value = BigInt(dep2.value);
  const expected = getCommitment(sellNote.value, sellNote.label, sellNote.nullifier, sellNote.secret).hash;
  if (BigInt(dep2.commitment) !== expected) throw new Error('the proceeds note is not the one Alice sealed');
  const left = await publicClient.readContract({ address: cfg.dep.token, abi: ABI.erc20, functionName: 'balanceOf', args: [blank1] });
  log('sell blank #1 back into the vault via relayer', {
    proceedsNote: formatEther(sellNote.value), blankLeftTokens: left.toString(), tx: sell.txHash, gasUsed: sell.gasUsed,
  });

  // 4. The proceeds pay for blank #2
  const blank2Key = privateKeyToAccount(generatePrivateKey());
  const blank2 = await publicClient.readContract({ address: cfg.dep.blankFactory, abi: ABI.factory, functionName: 'predict', args: [blank2Key.address] });
  const buy2 = await buyIntoBlank(sellNote, sellNote.value / 2n, {
    blank: blank2, tokenOut: cfg.dep.token, minAmountOut: 1n, deadline: deadline(),
    adapter: cfg.dep.venue, adapterData: '0x', feeRecipient, relayFeeBPS: RELAY_FEE_BPS,
  });
  const held2 = await publicClient.readContract({ address: cfg.dep.token, abi: ABI.erc20, functionName: 'balanceOf', args: [blank2] });
  log('buy into blank #2 from the proceeds via relayer', {
    blank: blank2, tokens: formatEther(held2), proveMs: buy2.proveMs, tx: buy2.res.txHash, gasUsed: buy2.res.gasUsed,
  });

  // 5. Tampering: prove a buy into blank #3, then point it at another address before relaying. The relayer's
  //    simulation hits the pool's context check, so nothing is ever submitted.
  const change2 = buy2.change;
  const blank3 = getAddress(`0x${randomBytes(20).toString('hex')}`);
  const thief = getAddress(`0x${randomBytes(20).toString('hex')}`);
  const relayerNonce = () => publicClient.getTransactionCount({ address: feeRecipient });
  const before = await relayerNonce();
  let refused = '';
  try {
    await buyIntoBlank(change2, change2.value / 2n, {
      blank: blank3, tokenOut: cfg.dep.token, minAmountOut: 1n, deadline: deadline(),
      adapter: cfg.dep.venue, adapterData: '0x', feeRecipient, relayFeeBPS: RELAY_FEE_BPS,
    }, (w) => {
      const [d] = decodeAbiParameters(BUY_DATA, w.data);
      return { ...w, data: encodeAbiParameters(BUY_DATA, [{ ...d, blank: thief }]) };
    });
  } catch (e) {
    refused = String(e.message);
  }
  const after = await relayerNonce();
  if (!/ContextMismatch/.test(refused) || after !== before) {
    throw new Error(`a tampered buy must be refused at simulation, got: ${refused || 'no error'}`);
  }
  log('tampered buy refused by the relayer, no transaction sent', { reason: refused.slice(0, 120) });

  summary.ok = true;
  writeFileSync(new URL('./last-run.json', import.meta.url), JSON.stringify(summary, (_k, x) => (typeof x === 'bigint' ? x.toString() : x), 2));
  console.log('\nE2E PASSED');
  process.exit(0);
}

main().catch((e) => {
  console.error('E2E FAILED:', e.message ?? e);
  process.exit(1);
});

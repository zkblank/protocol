// ZKBLANK relayer. It carries trades it cannot change: a buy is a proof whose context binds the whole BuyData,
// a sale is the blank owner's EIP-712 signature over the whole SellIntent. The relayer only checks that it is
// the fee recipient at an acceptable fee, simulates, and submits. It keeps no logs and sets no cookies.
// A Dark Drop sweep carries nothing secret either: the drop address already commits to the note and the fee.
//   GET /v1/relayer/details   POST /v1/relay/buy   POST /v1/relay/sell   POST /v1/relay/sweep
import { decodeAbiParameters, getAddress } from 'viem';
import { ABI, BUY_DATA, clients, loadConfig, serve } from './common.mjs';

const cfg = loadConfig();
const { publicClient, walletClient, account } = clients(cfg, process.env.RELAYER_PK);
const port = Number(process.env.RELAYER_PORT ?? 8703);
const minFeeBPS = BigInt(process.env.MIN_FEE_BPS ?? 25);
const minKeeperFeeBPS = BigInt(process.env.MIN_KEEPER_FEE_BPS ?? 10);

const now = () => BigInt(Math.floor(Date.now() / 1000));
const big = (x) => BigInt(x);

function checkFee(feeRecipient, relayFeeBPS, deadline) {
  if (getAddress(feeRecipient) !== account.address) throw new Error('fee recipient is not this relayer');
  if (big(relayFeeBPS) < minFeeBPS) throw new Error(`relay fee below ${minFeeBPS} bps`);
  if (big(deadline) <= now()) throw new Error('deadline passed');
}

async function submit(request) {
  const { request: simulated } = await publicClient.simulateContract({ ...request, account });
  const hash = await walletClient.writeContract(simulated);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== 'success') throw new Error('transaction reverted');
  return { txHash: hash, block: receipt.blockNumber, gasUsed: receipt.gasUsed };
}

serve('relayer', port, {
  'GET /v1/relayer/details': async () => [
    200,
    {
      chainId: cfg.chain.id,
      feeRecipient: account.address,
      minFeeBPS,
      minKeeperFeeBPS,
      dropFactory: cfg.dep.dropFactory,
      pool: cfg.dep.pool,
      burnerRouter: cfg.dep.burnerRouter,
      blankFactory: cfg.dep.blankFactory,
    },
  ],

  // { withdrawal: { processooor, data }, proof: { pA, pB, pC, pubSignals } }
  'POST /v1/relay/buy': async ({ withdrawal, proof }) => {
    if (getAddress(withdrawal.processooor) !== getAddress(cfg.dep.burnerRouter)) {
      throw new Error('processooor must be the BurnerRouter');
    }
    const [d] = decodeAbiParameters(BUY_DATA, withdrawal.data);
    checkFee(d.feeRecipient, d.relayFeeBPS, d.deadline);
    const p = {
      pA: proof.pA.map(big),
      pB: proof.pB.map((r) => r.map(big)),
      pC: proof.pC.map(big),
      pubSignals: proof.pubSignals.map(big),
    };
    const out = await submit({
      address: cfg.dep.burnerRouter,
      abi: ABI.router,
      functionName: 'buy',
      args: [cfg.dep.pool, withdrawal, p],
    });
    return [200, { ...out, blank: d.blank }];
  },

  // { owner, precommitment, keeperFeeBPS }: the drop address is derived from exactly these three
  'POST /v1/relay/sweep': async ({ owner, precommitment, keeperFeeBPS }) => {
    if (big(keeperFeeBPS) < minKeeperFeeBPS) throw new Error(`keeper fee below ${minKeeperFeeBPS} bps`);
    const out = await submit({
      address: cfg.dep.dropFactory,
      abi: ABI.drops,
      functionName: 'sweep',
      args: [getAddress(owner), big(precommitment), big(keeperFeeBPS)],
    });
    return [200, out];
  },

  // { owner, intent: SellIntent, signature }
  'POST /v1/relay/sell': async ({ owner, intent, signature }) => {
    checkFee(intent.feeRecipient, intent.relayFeeBPS, intent.deadline);
    const i = {
      ...intent,
      amountIn: big(intent.amountIn),
      minEthOut: big(intent.minEthOut),
      deadline: big(intent.deadline),
      precommitment: big(intent.precommitment),
      relayFeeBPS: big(intent.relayFeeBPS),
    };
    const out = await submit({
      address: cfg.dep.blankFactory,
      abi: ABI.factory,
      functionName: 'deployAndSell',
      args: [owner, i, signature],
    });
    return [200, out];
  },
});

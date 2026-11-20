// Shared pieces for the ZKBLANK services: config, chain clients, ABIs and a tiny JSON HTTP server.
// Rules from the blueprint: no cookies, no accounts, no IP logging, no endpoint that takes an address or an
// amount to look something up. Requests that move funds carry a proof or a signature, nothing else.
import { readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { createPublicClient, createWalletClient, defineChain, http, parseAbi } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

export const SNARK_SCALAR_FIELD =
  21888242871839275222246405745257275088548364400416034343698204186575808495617n;

export function loadConfig() {
  const deploymentPath = process.env.DEPLOYMENT;
  if (!deploymentPath) throw new Error('DEPLOYMENT (path to the deployment json) is required');
  const dep = JSON.parse(readFileSync(deploymentPath, 'utf8'));
  const rpcUrl = process.env.RPC_URL ?? 'http://127.0.0.1:8545';
  const chain = defineChain({
    id: Number(dep.chainId),
    name: `zkblank-${dep.chainId}`,
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] } },
  });
  return { dep, rpcUrl, chain };
}

export function clients(cfg, privateKey) {
  const publicClient = createPublicClient({ chain: cfg.chain, transport: http(cfg.rpcUrl) });
  if (!privateKey) return { publicClient };
  const account = privateKeyToAccount(privateKey);
  const walletClient = createWalletClient({ account, chain: cfg.chain, transport: http(cfg.rpcUrl) });
  return { publicClient, walletClient, account };
}

// Errors the pool can revert with during a buy, so the relayer reports a readable reason
const POOL_ERRORS = [
  'error InvalidProof()', 'error InvalidProcessooor()', 'error ContextMismatch()', 'error UnknownStateRoot()',
  'error IncorrectASPRoot()', 'error InvalidTreeDepth()', 'error NullifierAlreadySpent()', 'error ScopeMismatch()',
];

export const ABI = {
  pool: parseAbi([
    'event LeafInserted(uint256 _index, uint256 _leaf, uint256 _root)',
    'event Deposited(address indexed _depositor, uint256 _commitment, uint256 _label, uint256 _value, uint256 _precommitmentHash)',
    'function SCOPE() view returns (uint256)',
    'function currentRoot() view returns (uint256)',
  ]),
  entrypoint: parseAbi([
    'event RootUpdated(uint256 _root, string _ipfsCID, uint256 _timestamp)',
    'function updateRoot(uint256 _root, string _ipfsCID) returns (uint256)',
    'function latestRoot() view returns (uint256)',
    'function deposit(uint256 _precommitment) payable returns (uint256)',
  ]),
  router: parseAbi([
    'struct Withdrawal { address processooor; bytes data; }',
    'struct WithdrawProof { uint256[2] pA; uint256[2][2] pB; uint256[2] pC; uint256[8] pubSignals; }',
    'function buy(address _pool, Withdrawal _withdrawal, WithdrawProof _proof) returns (uint256)',
    ...POOL_ERRORS,
    'error InvalidProcessooor()', 'error NativePoolOnly()', 'error ZeroAddress()', 'error DeadlinePassed()',
    'error RelayFeeTooHigh()', 'error UnexpectedWithdrawnAmount()', 'error InsufficientOutput()',
    'error FailedToSendFee()', 'error UnexpectedSender()',
  ]),
  factory: parseAbi([
    'struct SellIntent { address tokenIn; uint256 amountIn; uint256 minEthOut; uint256 deadline; address adapter; bytes adapterData; uint256 precommitment; address feeRecipient; uint256 relayFeeBPS; }',
    'function predict(address _owner) view returns (address)',
    'function deployAndSell(address _owner, SellIntent _intent, bytes _signature) returns (address, uint256)',
    'error OnlyFactory()', 'error Retired()', 'error DeadlinePassed()', 'error RelayFeeTooHigh()',
    'error InvalidSignature()', 'error ZeroAddress()', 'error InsufficientOutput()', 'error FailedToSendFee()',
    'error UnexpectedSender()', 'error ECDSAInvalidSignature()', 'error ECDSAInvalidSignatureLength(uint256)',
  ]),
  drops: parseAbi([
    'function predict(address _owner, uint256 _precommitment, uint256 _keeperFeeBPS) view returns (address)',
    'function sweep(address _owner, uint256 _precommitment, uint256 _keeperFeeBPS) returns (address, uint256)',
    'error FeeTooHigh()', 'error EmptyDrop()', 'error AlreadySwept()', 'error OnlyFactory()',
    'error FailedToSendFee()', 'error PrecommitmentAlreadyUsed()',
  ]),
  erc20: parseAbi(['function balanceOf(address) view returns (uint256)']),
};

// The BuyData tuple a buy proof binds (IBurnerRouter.BuyData)
export const BUY_DATA = [
  {
    type: 'tuple',
    components: [
      { name: 'blank', type: 'address' },
      { name: 'tokenOut', type: 'address' },
      { name: 'minAmountOut', type: 'uint256' },
      { name: 'deadline', type: 'uint256' },
      { name: 'adapter', type: 'address' },
      { name: 'adapterData', type: 'bytes' },
      { name: 'feeRecipient', type: 'address' },
      { name: 'relayFeeBPS', type: 'uint256' },
    ],
  },
];

// The EIP-712 types a blank's owner signs (BlankAccount.SELL_INTENT_TYPEHASH)
export const SELL_TYPES = {
  SellIntent: [
    { name: 'tokenIn', type: 'address' },
    { name: 'amountIn', type: 'uint256' },
    { name: 'minEthOut', type: 'uint256' },
    { name: 'deadline', type: 'uint256' },
    { name: 'adapter', type: 'address' },
    { name: 'adapterData', type: 'bytes' },
    { name: 'precommitment', type: 'uint256' },
    { name: 'feeRecipient', type: 'address' },
    { name: 'relayFeeBPS', type: 'uint256' },
  ],
};

export const sellDomain = (chainId, blank) => ({
  name: 'ZKBLANK Blank',
  version: '1',
  chainId,
  verifyingContract: blank,
});

/** JSON with bigints as decimal strings */
export const toJson = (v) => JSON.stringify(v, (_k, x) => (typeof x === 'bigint' ? x.toString() : x));

/**
 * A minimal JSON HTTP server. `routes` maps "METHOD /path" to async (body) => [status, payload].
 * No request logging at all (the relayer must not keep IPs), 64 KB body cap, permissive CORS, no cookies.
 */
export function serve(name, port, routes) {
  const server = createServer(async (req, res) => {
    res.setHeader('access-control-allow-origin', '*');
    res.setHeader('access-control-allow-headers', 'content-type');
    res.setHeader('cache-control', 'no-store');
    if (req.method === 'OPTIONS') return res.writeHead(204).end();
    const handler = routes[`${req.method} ${req.url.split('?')[0]}`];
    if (!handler) return send(res, 404, { error: 'not found' });
    let raw = '';
    for await (const chunk of req) {
      raw += chunk;
      if (raw.length > 65536) return send(res, 413, { error: 'body too large' });
    }
    try {
      const body = raw ? JSON.parse(raw) : {};
      const [status, payload] = await handler(body);
      send(res, status, payload);
    } catch (e) {
      send(res, 400, { error: shortError(e) });
    }
  });
  server.listen(port, '127.0.0.1', () => console.log(`${name} listening on 127.0.0.1:${port}`));
  return server;
}

function send(res, status, payload) {
  res.writeHead(status, { 'content-type': 'application/json' }).end(toJson(payload));
}

export function shortError(e) {
  // Prefer the decoded custom error name (e.g. ContextMismatch) when viem found one in the cause chain
  for (let c = e; c; c = c.cause) {
    if (c.data?.errorName) return `reverted: ${c.data.errorName}`;
  }
  const m = e?.shortMessage ?? e?.message ?? String(e);
  return m.split('\n')[0].slice(0, 300);
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

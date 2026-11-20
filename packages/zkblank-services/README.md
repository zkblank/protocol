# ZKBLANK services

Three small Node services, no framework, no database, no cookies, no request logging:

| Service | Port | Serves |
|---|---|---|
| `src/indexer.mjs` | 8701 | `GET /v1/tree` (every leaf), `/v1/deposits`, `/v1/roots`, `/v1/health`: public chain data, served whole |
| `src/asp.mjs` | 8702 | Screens each deposit's source against `DENYLIST`, posts the approved root with the postman key; `GET /v1/asp` |
| `src/relayer.mjs` | 8703 | `POST /v1/relay/buy` (a proof bound to a BuyData), `POST /v1/relay/sell` (a blank's EIP-712 SellIntent), `GET /v1/relayer/details` |

The relayer checks only that it is the fee recipient at an acceptable fee, simulates, and submits. It cannot
change a trade: a buy is bound by the proof's context, a sale by the blank owner's signature. A tampered buy is
refused at simulation (`ContextMismatch`) and never reaches the chain.

Environment: `DEPLOYMENT` (deployment json), `RPC_URL`, `RELAYER_PK`, `POSTMAN_PK`, `MIN_FEE_BPS` (default 25),
`DENYLIST`, ports `INDEXER_PORT` / `ASP_PORT` / `RELAYER_PORT`.

## The whole loop on a local chain

```bash
bash packages/zkblank-services/e2e/run-local.sh
```

Starts anvil, deploys with `packages/contracts/script/zkblank/DeployLocal.s.sol` (local chain only, test token
and fixed-price venue), starts the three services and runs `e2e/client.mjs`, which acts like the app: deposit,
wait for the ASP, build Merkle proofs from the indexer's public tree, prove in Node, buy into blank #1 through
the relayer, sell it back into the vault, buy into blank #2 from the proceeds, and check that a tampered buy is
refused. The last run is written to `e2e/last-run.json`.

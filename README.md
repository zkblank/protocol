<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/mark-dark.png">
    <img src=".github/assets/mark-light.png" alt="ZKBLANK mark" width="80">
  </picture>
</p>

<h1 align="center">ZKBLANK protocol</h1>

<p align="center"><b>Every buy leaves from a wallet that lives once.</b></p>

<p align="center">
  The contracts, circuits and services behind ZKBLANK: a private balance on Robinhood Chain that trades through
  one-life wallets called blanks.
</p>

<p align="center">
  <a href="https://zkblank.tech">Website</a> ·
  <a href="https://app.zkblank.tech">App</a> ·
  <a href="https://zkblank.tech/docs">Docs</a> ·
  <a href="https://x.com/zkblankRH">X @zkblankRH</a> ·
  <a href="FORK.md">FORK.md</a>
</p>

<p align="center">
  <img alt="License" src="https://img.shields.io/badge/license-Apache--2.0-F2F2EF?style=flat-square&labelColor=0B0B0D">
  <img alt="Chain" src="https://img.shields.io/badge/chain-Robinhood%20Chain-0B0B0D?style=flat-square">
  <img alt="Proofs" src="https://img.shields.io/badge/proofs-Groth16%20%C2%B7%20Circom%202-F2F2EF?style=flat-square&labelColor=0B0B0D">
  <img alt="Tests" src="https://img.shields.io/badge/ZKBLANK%20tests-32%2F32%20real%20proofs-FF6A00?style=flat-square&labelColor=0B0B0D">
  <img alt="Status" src="https://img.shields.io/badge/status-pre--audit%20%C2%B7%20local%20chain-FF6A00?style=flat-square&labelColor=0B0B0D">
</p>

---

## About

On a public chain every buy is a broadcast. Copy-trading bots mirror a wallet within a block, and a fresh wallet
does not help, because the transaction that funds it points straight back to its owner.

ZKBLANK keeps the balance inside a zero-knowledge vault as private notes. Every buy is paid from a note straight
into a **blank**: an address with no code, no history and no funding transaction. Every sale sends the proceeds
back into the vault as a new note, and the blank retires.

This repository is the protocol. It is a fork of
[Privacy Pools core](https://github.com/0xbow-io/privacy-pools-core) (0xbow), which already provides deposits, a
Merkle tree of notes, nullifiers and association sets, audited by Oxorio and Auditware. **The audited withdraw
circuit and its keys are untouched.** ZKBLANK adds the trading side on top as new contracts and services, and
every change is listed in [FORK.md](FORK.md).

**Status:** built and tested on a local chain. Not deployed to any public network and not audited: the upstream
audits cover the upstream code only. Do not use it with real funds.

## Features

| Feature | What it does | Where |
|---|---|---|
| **Dark Drop** | A one-time address derived from a drop key, the note's precommitment and a keeper fee. It is paid by a plain transfer from any wallet, bridge or exchange, and anyone can sweep it, but only into the note the user sealed, for the fee fixed in the address (at most 1%). Funds that arrive later go into a new note the drop key signs for. | `DropFactory`, `DropBox` |
| **Burner Mode** | A private note pays a swap whose output lands directly in a blank. The token, minimum out, blank, deadline, venue and relay fee are part of the withdrawal the proof commits to, so a relayer can carry the trade but cannot change any of it. | `BurnerRouter` |
| **Blanks** | One-life accounts whose address is known from their key before they exist. A blank holds one position, is never sent gas, and is deployed only by the transaction that sells it. | `BlankFactory`, `BlankAccount` |
| **Sell back into the dark** | The blank's key signs one EIP-712 sale. The relayer is paid from the proceeds, the rest becomes a new private note, and the blank retires for good. | `BlankAccount` |
| **Association sets** | Every spend proves its deposit is in the approved set posted by the association-set provider. Flagged deposits can only ragequit back to their source. | upstream `Entrypoint`, `PrivacyPool` |
| **Indexer, ASP and relayer** | Three small services: the indexer serves the public tree whole, the ASP screens deposits and posts the approved root, the relayer submits proofs and signed sales it cannot alter. No accounts, no cookies, no request logs. | `packages/zkblank-services` |
| **Local end to end** | One script runs a local chain, deploys everything, starts the services and walks a Dark Drop, a buy, a sale and a second buy from the proceeds, plus a tampered request the relayer refuses. | `packages/zkblank-services/e2e` |
| **Privacy Report Card, Crowd Fees, tiers, the 1,000-Hand Ceremony, public testnet** | Planned. | |

## Credits and license

Apache License 2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE). Built on Privacy Pools core by 0xbow and
Wonderland; the upstream history is kept in this repository.

---

<sub>ZKBLANK is privacy software for lawful use. Deposits are screened, and flagged deposits can only return to their
source. Zero-knowledge proofs hide the link between a deposit and a trade; they cannot hide behaviour such as
amounts, timing, network addresses and token choice. This code is pre-audit and has not been deployed to a public
network. Nothing here is financial, investment, legal or tax advice.</sub>

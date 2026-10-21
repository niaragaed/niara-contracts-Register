# niara-contracts-Register

EVM contract behind **Niara Register**: on-chain proof of existence and
authorship for documents. Only the document's SHA-256 hash is recorded. The
file itself never leaves the user's browser.

> Complementary evidentiary record. It does **not** replace a notary (cartório)
> or ICP-Brasil and has no automatic legal effect.

## Deployments

The same contract, deployed from the same wallet at nonce 0, so it has **the
same address on every EVM network**:

**`0x5627857ee73f37d6da96530ed08c07339dd9d93a`**

| Network | Chain ID | Deploy block | Contract | Deploy tx |
|---|---|---|---|---|
| Ethereum Sepolia | 11155111 | 11691295 | [Etherscan](https://sepolia.etherscan.io/address/0x5627857ee73f37d6da96530ed08c07339dd9d93a) | [`0x01221bfe…b515`](https://sepolia.etherscan.io/tx/0x01221bfeef63f64be89cf2e3a878270abcda2ff1259f99e7a56fdca1abf9b515) |
| Base Sepolia | 84532 | 47915732 | [BaseScan](https://sepolia.basescan.org/address/0x5627857ee73f37d6da96530ed08c07339dd9d93a) | [`0x8b31454e…8700`](https://sepolia.basescan.org/tx/0x8b31454e96c3eb8840871b1fbc71a47470ed3c1f22f2633270ec76693b588700) |
| Robinhood Chain Testnet | 46630 | 131998737 | [Robinhood Explorer](https://explorer.testnet.chain.robinhood.com/address/0x5627857ee73f37d6da96530ed08c07339dd9d93a) | [`0x4e68d6c9…df86`](https://explorer.testnet.chain.robinhood.com/tx/0x4e68d6c9d754efa313d37c77679ea436534d325a7bacbfca767344290026df86) |
| HyperEVM Testnet | 998 | 66500325 | [Niara RPC reader](https://niara-register.vercel.app/explorer/hyperevm-testnet/address/0x5627857ee73f37d6da96530ed08c07339dd9d93a)¹ | [`0xedbc0391…c517`](https://niara-register.vercel.app/explorer/hyperevm-testnet/tx/0xedbc0391b0368ffc182435769d3891d7837f1d2c56a2a76a3f41f0039bf1c517)¹ |
| Tempo Testnet (Moderato) | 42431 | 38942339 | [Tempo Explorer](https://explore.testnet.tempo.xyz/address/0x5627857ee73f37d6da96530ed08c07339dd9d93a) | [`0xc3814c78…31b8`](https://explore.testnet.tempo.xyz/tx/0xc3814c783ac0fbfe5e6c9f97102b8c4bdc386248e0cb36169a9a899c139d31b8) |

¹ HyperEVM Testnet has no working public block explorer (October 2026), so these
links open a page of the Niara Register site that reads the transaction or
address live from the official RPC (`https://rpc.hyperliquid-testnet.xyz/evm`)
and shows the `curl` calls to repeat the query yourself.

The deploy receipts for each network are versioned under
`broadcast/DeployRegistro.s.sol/<chain id>/`.

Niara Register also runs on **Solana devnet** with a native Anchor program that
follows the same rules:
[niaragaed/niara-register-solana](https://github.com/niaragaed/niara-register-solana).

Try it: [niara-register.vercel.app/signatures](https://niara-register.vercel.app/signatures).
Pick a network, drop a file, and sign with your own wallet. The ledger below the
form mirrors records from all six networks
([indexer](https://github.com/niaragaed/Niara-Register/tree/main/indexer)).

## Contract

`src/registro/RegistroAssinaturas.sol`

- `registrar(bytes32 hashDocumento, string nomeDocumento, string tipoDocumento)`
  records hash + signer (`msg.sender`) + `block.timestamp` + name and type.
- `verificar(bytes32 hashDocumento)` returns
  `(existe, assinante, timestamp, nomeDocumento, tipoDocumento)`.
  No wallet is needed to verify.
- Event: `DocumentoRegistrado(bytes32 indexed hashDocumento, address indexed assinante, string nomeDocumento, string tipoDocumento, uint256 timestamp)`.
- **One record per hash, immutable.** A second registration of the same hash
  reverts with `DocumentoJaRegistrado`, so nobody can overwrite or back-date a
  document. An all-zero hash reverts with `HashInvalido`.
- No owner, no admin functions and no upgradeability. The deployer key has no
  power over the contract after deployment.

## v2 (not deployed yet)

- [`src/v2/SignatureRegistryV2.sol`](src/v2/SignatureRegistryV2.sol): `register(recordHash, scheme, metadataCommitment)` stores no readable metadata and mints a **soulbound receipt** (ERC-721 + ERC-5192, fully on-chain metadata pointing to the verification page) to the signer in the same transaction. Scheme 0 = SHA-256 of a PAdES-signed PDF; scheme 1 = `SHA-256("niara-record-v1" ‖ salt ‖ SHA-256(file))`. Metadata commitment = `SHA-256("niara-meta-v1" ‖ salt ‖ {"name","type"} JSON)`.
- [`src/mletr/TransferableRecordRegistry.sol`](src/mletr/TransferableRecordRegistry.sol): transferable electronic records designed to line up with MLETR — one token per document hash (no hash ever reused), control by the holder, issuer-proposed / holder-accepted amendments, surrender and termination (including replacement by paper). Aligned with MLETR, not "compliant": Brazil has not enacted it.
- v1 (`RegistroAssinaturas`) stays deployed so old records remain verifiable; its name/type fields are public forever.

Deploy both on a network (the URL is baked into every receipt and cannot change):

```bash
PRIVATE_KEY=... VERIFY_BASE_URL=https://niara-register.vercel.app/verify/sepolia/ \
  forge script script/DeployV2.s.sol --rpc-url sepolia --broadcast
```

Repeat per network with its slug (`base-sepolia`, `robinhood-testnet`, `hyperevm-testnet`, `tempo-testnet`), then copy the addresses into Niara-Register's `lib/register-v2-evm.ts` and the indexer's `<PREFIX>_V2_*` variables.

Known limitation: `register` can be front-run from the public mempool (someone copies the hash and lands first). A commit-reveal step would close it.

## Run locally

```bash
cp .env.example .env   # PRIVATE_KEY of the deploy wallet, RPC_URL
forge build
forge test -vv
```

## Deploy

```bash
# Ethereum Sepolia (RPC_URL in .env)
forge script script/DeployRegistro.s.sol --rpc-url sepolia --broadcast

# Base Sepolia
forge script script/DeployRegistro.s.sol --rpc-url https://sepolia.base.org --broadcast

# Robinhood Chain Testnet
forge script script/DeployRegistro.s.sol --rpc-url https://rpc.testnet.chain.robinhood.com --broadcast

# HyperEVM Testnet (gas paid in HYPE)
forge script script/DeployRegistro.s.sol --rpc-url https://rpc.hyperliquid-testnet.xyz/evm --broadcast

# Tempo Testnet: no native gas token (fees in pathUSD), and contract creation
# costs ~5x more gas than on Ethereum, so Foundry's local estimate must be
# raised or the deployment runs out of gas.
forge script script/DeployRegistro.s.sol --rpc-url https://rpc.moderato.tempo.xyz --broadcast --gas-estimate-multiplier 700
```

To get the same address on a new network, the deployment must be the deploy
wallet's **first** transaction on that network.

## Development history (disclosure)

- **Sep 2026:** contract written and deployed on Ethereum Sepolia (2026-09-12),
  together with the Niara-Register site and its Sepolia indexer.
- **Oct 2026, during the Crypto World's Fair hackathon:** deployments on Base
  Sepolia, Robinhood Chain Testnet, HyperEVM Testnet and Tempo Testnet; the
  Solana program; and the multichain ledger and indexers.

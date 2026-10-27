# niara-contracts-Register

## Language

English is the default for everything in this repository: code, identifiers,
comments, docs, test names, scripts and commit messages.

Exception: names that are part of the deployed on-chain interface stay as they
are (`RegistroAssinaturas`, `registrar`, `verificar`, `DocumentoRegistrado`,
`DocumentoJaRegistrado`, `HashInvalido` and the struct/parameter names). The
contract is live at the same address on five EVM testnets and renaming would
change the ABI. New contracts should use English names from the start.

## Contracts

- `src/registro/RegistroAssinaturas.sol` — v1, live on five EVM testnets. Stores the
  document name and type in plain text, which is public forever; kept only so
  existing records stay verifiable. Do not point new flows at it.
- `src/v2/SignatureRegistryV2.sol` — current registry. Stores the record hash,
  the hash scheme and a salted metadata commitment (never readable metadata),
  and mints a soulbound receipt (ERC-721 + ERC-5192) to the signer in the same
  transaction. The hash recipes must stay byte-identical to the site's
  `lib/commitments.ts` in Niara-Register.
- `src/v3/SignatureRegistryV3.sol` — v2 plus commit-reveal registration and the optional
  ORB attestation (EIP-712 signature by `orbAttester`). New flows go here once it is deployed;
  v2 stays deployed so its records remain verifiable. `commitmentOf` and the EIP-712 type must
  stay identical to the site's implementation (cross-implementation vectors in the tests).
- `src/mletr/TransferableRecordRegistry.sol` — transferable electronic records
  designed to line up with MLETR (singularity, exclusive control, amendment,
  surrender, termination). Describe it as "aligned with MLETR", never as
  "MLETR compliant": Brazil has not enacted MLETR.

Dependencies are vendored in `lib/` (forge-std, OpenZeppelin `contracts/` only)
and pinned in `foundry.lock`.

## No AI attribution (hard rule)

Nothing in this repository credits an AI tool, anywhere:

- no `Co-Authored-By: Claude` or `Claude-Session:` trailers, and no "Generated with Claude Code"
  line, in commit messages;
- no AI tool as a commit author or committer: commits use the project identity
  (`git config user.name`/`user.email` = `Niara <niaragaed@gmail.com>`, set in every clone and
  environment before the first commit — some environments default to `Claude <noreply@anthropic.com>`);
- no "Generated with/by Claude Code" footer in pull request descriptions, comments, issues or files.

It's enforced in two layers: the versioned `.claude/settings.json` turns Claude Code's commit
and PR attribution off (`"attribution": {"commit": "", "pr": ""}`), and the `No AI attribution`
GitHub Actions check (`.github/workflows/no-ai-attribution.yml`) fails on any commit or pull
request description that carries it. Some hosted environments append a footer to PR
descriptions by themselves; if the check flags one, delete that line in the GitHub UI. The rule
applies to every Niara repository, including new ones: copy both files when creating a repo.


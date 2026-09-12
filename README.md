# niara-contracts-Register

Contrato de registro de assinaturas do Niara-Register — prova de existência
on-chain de documentos, via hash SHA-256, sem armazenar o documento em si.

## Contrato principal

`src/registro/RegistroAssinaturas.sol` — registra hash + endereço de quem
assinou + timestamp + metadado livre (nome e tipo do documento). Cada hash
só pode ser registrado uma vez (protege a prova de existência contra
sobrescrita).

## Rodando localmente

```bash
cp .env.example .env
# preencher PRIVATE_KEY (carteira dedicada, com Sepolia ETH) e RPC_URL

forge build
forge test -vv
```

## Deploy na Sepolia

```bash
forge script script/DeployRegistro.s.sol --rpc-url sepolia --broadcast
```

Endereço do contrato deployado fica registrado em
`broadcast/DeployRegistro.s.sol/11155111/run-latest.json` depois do deploy
real (chain ID 11155111 = Sepolia).

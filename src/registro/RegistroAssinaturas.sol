// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title RegistroAssinaturas
/// @notice Registro on-chain de prova de existência e autoria de documentos.
///         Guarda o hash SHA-256 do documento (nunca o documento em si),
///         quem assinou, quando, e um metadado descritivo. Serve como
///         registro probatório complementar — NÃO substitui cartório nem
///         ICP-Brasil, e não tem qualquer efeito jurídico automático.
/// @dev Cada hash só pode ser registrado uma vez — isso é o que dá valor
///      à prova de existência: ninguém consegue "re-registrar" um
///      documento já existente com uma data mais antiga ou mais nova.
contract RegistroAssinaturas {
    struct Assinatura {
        address assinante;
        uint64 timestamp;
        string nomeDocumento;
        string tipoDocumento;
    }

    /// hash SHA-256 do documento (32 bytes) => dados da assinatura
    mapping(bytes32 => Assinatura) private _assinaturas;

    event DocumentoRegistrado(
        bytes32 indexed hashDocumento,
        address indexed assinante,
        string nomeDocumento,
        string tipoDocumento,
        uint256 timestamp
    );

    error DocumentoJaRegistrado(bytes32 hashDocumento);
    error HashInvalido();

    /// @notice Registra a prova de existência de um documento pelo hash dele.
    /// @param hashDocumento Hash SHA-256 do documento (calculado no navegador,
    ///        o documento em si nunca é enviado nem armazenado aqui).
    /// @param nomeDocumento Nome/descrição livre do documento (ex.: "Ata de
    ///        reunião de sócios — 10/09/2026").
    /// @param tipoDocumento Categoria livre (ex.: "ata", "contrato", "cap table").
    function registrar(
        bytes32 hashDocumento,
        string calldata nomeDocumento,
        string calldata tipoDocumento
    ) external {
        if (hashDocumento == bytes32(0)) revert HashInvalido();
        if (_assinaturas[hashDocumento].timestamp != 0) {
            revert DocumentoJaRegistrado(hashDocumento);
        }

        _assinaturas[hashDocumento] = Assinatura({
            assinante: msg.sender,
            timestamp: uint64(block.timestamp),
            nomeDocumento: nomeDocumento,
            tipoDocumento: tipoDocumento
        });

        emit DocumentoRegistrado(
            hashDocumento,
            msg.sender,
            nomeDocumento,
            tipoDocumento,
            block.timestamp
        );
    }

    /// @notice Consulta os dados de registro de um hash. Retorna tudo zerado
    ///         se o hash nunca foi registrado — confira `existe` antes de
    ///         usar os outros campos.
    function verificar(bytes32 hashDocumento)
        external
        view
        returns (
            bool existe,
            address assinante,
            uint256 timestamp,
            string memory nomeDocumento,
            string memory tipoDocumento
        )
    {
        Assinatura memory a = _assinaturas[hashDocumento];
        existe = a.timestamp != 0;
        return (existe, a.assinante, a.timestamp, a.nomeDocumento, a.tipoDocumento);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title RegistroAssinaturas (document signature registry)
/// @notice On-chain proof of existence and authorship for documents.
///         Stores the document's SHA-256 hash (never the document itself),
///         who signed it, when, and descriptive metadata. It is a
///         complementary evidentiary record: it does NOT replace a notary
///         (cartório) or ICP-Brasil and has no automatic legal effect.
/// @dev Each hash can be registered only once. That is what gives the proof
///      of existence its value: nobody can "re-register" an existing
///      document with an earlier or later date.
/// @dev Identifiers (contract, struct, event, error and function names) are
///      kept in Portuguese because this contract is deployed at the same
///      address on several networks and its ABI is part of the public interface.
contract RegistroAssinaturas {
    /// A signature record: signer, timestamp, document name and document type.
    struct Assinatura {
        address assinante;
        uint64 timestamp;
        string nomeDocumento;
        string tipoDocumento;
    }

    /// Document SHA-256 hash (32 bytes) => signature data
    mapping(bytes32 => Assinatura) private _assinaturas;

    /// Emitted when a document is registered (DocumentoRegistrado = "document registered").
    event DocumentoRegistrado(
        bytes32 indexed hashDocumento,
        address indexed assinante,
        string nomeDocumento,
        string tipoDocumento,
        uint256 timestamp
    );

    /// The hash was already registered (DocumentoJaRegistrado = "document already registered").
    error DocumentoJaRegistrado(bytes32 hashDocumento);
    /// The hash is zero (HashInvalido = "invalid hash").
    error HashInvalido();

    /// @notice Registers proof of existence of a document by its hash.
    /// @param hashDocumento SHA-256 hash of the document (computed in the
    ///        browser; the document itself is never sent or stored here).
    /// @param nomeDocumento Free-form name/description of the document
    ///        (e.g. "Partners' meeting minutes, 2026-09-10").
    /// @param tipoDocumento Free-form category (e.g. "minutes", "contract", "cap table").
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

    /// @notice Looks up the registration data for a hash (verificar = "verify").
    ///         Returns all-zero values if the hash was never registered, so
    ///         check `existe` ("exists") before using the other fields.
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

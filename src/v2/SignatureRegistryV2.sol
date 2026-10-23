// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @notice Minimal soulbound NFT interface (ERC-5192).
interface IERC5192 {
    event Locked(uint256 tokenId);
    event Unlocked(uint256 tokenId);

    function locked(uint256 tokenId) external view returns (bool);
}

/// @title SignatureRegistryV2
/// @notice On-chain proof of existence and authorship for documents, with a
///         non-transferable receipt (ERC-721 + ERC-5192) minted to the signer
///         in the same transaction.
///
///         Privacy changes from v1 (`RegistroAssinaturas`):
///         - No readable metadata on-chain. Document name and type are kept
///           off-chain (in the holder's Verifiable Credential) and only a
///           salted commitment to them is stored here.
///         - The record hash is either the SHA-256 of a PAdES-signed PDF
///           (unguessable, because it contains the signer's signature) or a
///           salted commitment to the file's SHA-256, so documents built from
///           public templates cannot be found by trying variations.
///
///         This is a complementary evidentiary record. It does NOT replace a
///         notary (cartório), it does not issue or validate ICP-Brasil
///         certificates, and it has no automatic legal effect.
/// @dev No owner, no upgradeability, no admin functions. Each record hash can
///      be registered once; the receipt's token id is the record hash itself.
contract SignatureRegistryV2 is ERC721, IERC5192 {
    using Strings for uint256;

    /// How `recordHash` was computed. The contract cannot check it; the value
    /// tells verifiers which recipe to apply.
    /// - SignedPdfSha256 (0): SHA-256 of the final PAdES-signed PDF file.
    /// - SaltedSha256 (1): SHA-256("niara-record-v1" || salt || SHA-256(file)),
    ///   with a 32-byte random salt held by the signer.
    uint8 public constant SCHEME_SIGNED_PDF_SHA256 = 0;
    uint8 public constant SCHEME_SALTED_SHA256 = 1;

    /// Public document type, from a fixed list (never free text, so no names
    /// leak through it). 0 is invalid. Codes 1..11 have labels below; higher
    /// codes are accepted for types added later and are labelled generically.
    /// 1 Contract, 2 Meeting minutes, 3 Power of attorney, 4 Promissory note,
    /// 5 Declaration, 6 Receipt, 7 Agreement, 8 Articles of association / bylaws,
    /// 9 Shareholder register / cap table, 10 Report / appraisal, 11 Other.
    uint16 public constant LAST_LABELLED_TYPE = 11;

    struct Record {
        address signer;
        uint64 timestamp;
        uint8 scheme;
        uint16 documentType;
        bytes32 metadataCommitment;
    }

    /// Record hash => record.
    mapping(bytes32 => Record) private _records;

    /// Verification page prefix, e.g. "https://niara-register.vercel.app/verify/sepolia/".
    /// Set once at deployment; there is no setter.
    string private _verifyBaseUrl;

    event DocumentRegistered(
        bytes32 indexed recordHash,
        address indexed signer,
        uint8 scheme,
        uint16 documentType,
        bytes32 metadataCommitment,
        uint256 timestamp
    );

    error AlreadyRegistered(bytes32 recordHash);
    error InvalidHash();
    error UnknownScheme(uint8 scheme);
    error InvalidDocumentType();
    error Soulbound();

    constructor(string memory verifyBaseUrl_) ERC721("Niara Register Receipt", "NIARA-R") {
        _verifyBaseUrl = verifyBaseUrl_;
    }

    /// @notice Registers a document fingerprint and mints a soulbound receipt to the caller.
    /// @param recordHash See the scheme constants for how it is computed.
    /// @param scheme SCHEME_SIGNED_PDF_SHA256 or SCHEME_SALTED_SHA256.
    /// @param documentType Public type code (see LAST_LABELLED_TYPE); must not be 0.
    /// @param metadataCommitment SHA-256("niara-meta-v1" || salt || metadata JSON), or zero
    ///        when there is no metadata. Never the metadata itself.
    /// @return tokenId The receipt id, equal to uint256(recordHash).
    function register(bytes32 recordHash, uint8 scheme, uint16 documentType, bytes32 metadataCommitment)
        external
        returns (uint256 tokenId)
    {
        if (recordHash == bytes32(0)) revert InvalidHash();
        if (scheme > SCHEME_SALTED_SHA256) revert UnknownScheme(scheme);
        if (documentType == 0) revert InvalidDocumentType();
        if (_records[recordHash].timestamp != 0) revert AlreadyRegistered(recordHash);

        _records[recordHash] = Record({
            signer: msg.sender,
            timestamp: uint64(block.timestamp),
            scheme: scheme,
            documentType: documentType,
            metadataCommitment: metadataCommitment
        });

        tokenId = uint256(recordHash);
        // _mint, not _safeMint: no receiver callback, so no reentrancy surface,
        // and smart-contract wallets without the hook can still register.
        _mint(msg.sender, tokenId);

        emit Locked(tokenId);
        emit DocumentRegistered(recordHash, msg.sender, scheme, documentType, metadataCommitment, block.timestamp);
    }

    /// @notice Looks up a record. Returns all-zero values if the hash was never registered.
    function verify(bytes32 recordHash)
        external
        view
        returns (
            bool exists,
            address signer,
            uint256 timestamp,
            uint8 scheme,
            uint16 documentType,
            bytes32 metadataCommitment
        )
    {
        Record memory r = _records[recordHash];
        exists = r.timestamp != 0;
        return (exists, r.signer, r.timestamp, r.scheme, r.documentType, r.metadataCommitment);
    }

    /// @notice English label of a document type code ("Other (code N)" for codes added later).
    function documentTypeLabel(uint16 code) public pure returns (string memory) {
        if (code == 1) return "Contract";
        if (code == 2) return "Meeting minutes";
        if (code == 3) return "Power of attorney";
        if (code == 4) return "Promissory note";
        if (code == 5) return "Declaration";
        if (code == 6) return "Receipt";
        if (code == 7) return "Agreement";
        if (code == 8) return "Articles of association / bylaws";
        if (code == 9) return "Shareholder register / cap table";
        if (code == 10) return "Report / appraisal";
        if (code == 11) return "Other";
        return string.concat("Other (code ", uint256(code).toString(), ")");
    }

    // ------------------------------------------------------------------
    // Soulbound behaviour (ERC-5192)
    // ------------------------------------------------------------------

    function locked(uint256 tokenId) external view returns (bool) {
        _requireOwned(tokenId);
        return true;
    }

    /// Blocks every transfer and burn; only minting (from == 0) goes through.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (_ownerOf(tokenId) != address(0)) revert Soulbound();
        return super._update(to, tokenId, auth);
    }

    function approve(address, uint256) public pure override {
        revert Soulbound();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert Soulbound();
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IERC5192).interfaceId || super.supportsInterface(interfaceId);
    }

    // ------------------------------------------------------------------
    // Metadata: fully on-chain, nothing private in it
    // ------------------------------------------------------------------

    function verifyBaseUrl() external view returns (string memory) {
        return _verifyBaseUrl;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        Record memory r = _records[bytes32(tokenId)];
        string memory hashHex = tokenId.toHexString(32);

        // Built in two parts: one long string.concat is "stack too deep" with the optimizer on.
        string memory head = string.concat(
            '{"name":"Niara Register receipt",',
            '"description":"Proof that this wallet registered a document fingerprint on Niara Register. ',
            'The document itself is not on-chain. Non-transferable.",',
            '"external_url":"',
            _verifyBaseUrl,
            hashHex,
            '","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(_svg(hashHex)))
        );
        string memory json = string.concat(
            head,
            '","attributes":[{"trait_type":"Record hash","value":"',
            hashHex,
            '"},{"trait_type":"Document type","value":"',
            documentTypeLabel(r.documentType),
            '"},{"trait_type":"Hash scheme","value":"',
            r.scheme == SCHEME_SIGNED_PDF_SHA256 ? "Signed PDF (PAdES) SHA-256" : "Salted SHA-256",
            '"},{"display_type":"date","trait_type":"Registered at","value":',
            uint256(r.timestamp).toString(),
            "}]}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _svg(string memory hashHex) private pure returns (string memory) {
        // Short form: 0x + first 8 and last 8 hex digits.
        bytes memory h = bytes(hashHex);
        bytes memory head = new bytes(10);
        bytes memory tail = new bytes(8);
        for (uint256 i = 0; i < 10; i++) {
            head[i] = h[i];
        }
        for (uint256 i = 0; i < 8; i++) {
            tail[i] = h[h.length - 8 + i];
        }
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">',
            '<rect width="400" height="400" fill="#0f1720"/>',
            '<rect x="24" y="24" width="352" height="352" fill="none" stroke="#b08d57" stroke-width="2"/>',
            '<text x="200" y="150" fill="#f4f1ea" font-family="monospace" font-size="22" text-anchor="middle">NIARA REGISTER</text>',
            '<text x="200" y="185" fill="#b08d57" font-family="monospace" font-size="14" text-anchor="middle">signature receipt</text>',
            '<text x="200" y="250" fill="#f4f1ea" font-family="monospace" font-size="16" text-anchor="middle">',
            string(head),
            "...",
            string(tail),
            "</text>",
            '<text x="200" y="330" fill="#8a94a0" font-family="monospace" font-size="11" text-anchor="middle">non-transferable</text>',
            "</svg>"
        );
    }
}

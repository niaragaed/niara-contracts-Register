// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC5192} from "../v2/SignatureRegistryV2.sol";

/// @title SignatureRegistryV3
/// @notice SignatureRegistryV2 plus three changes:
///
///         1. Commit-reveal registration. In v2 anyone watching the mempool
///            could copy a pending `register` call and land first, taking the
///            record (and the receipt) with their own address. Now the signer
///            first publishes `commit(c)` with
///                c = keccak256(abi.encode(chainid, registry, signer, recordHash, nonce))
///            which reveals nothing about the document, and registers in a
///            LATER block. A copier who sees the reveal cannot use it: the
///            commitment is stored under the committer's address and must
///            already exist in an earlier block, which is impossible to arrange
///            after seeing the reveal.
///
///         2. ORB attestation. A record can carry the hash of an ORB analysis
///            report, accepted only with an EIP-712 signature from the ORB
///            attester key over (recordHash, reportHash, signer). The receipt
///            then states that the document went through ORB analysis. Without
///            the signature the flag cannot be set, so it is not a self-claim.
///            The report itself stays off-chain; sending a document to ORB is
///            optional.
///
///         3. One record per (document, signer), not one per document. In v2
///            the first wallet to register a hash owned it and everybody else
///            was locked out, so whoever held the hash first (the other party
///            of a contract, say) could take it. Now each wallet that registers
///            a hash gets its own record and receipt; nobody can block or take
///            anyone else's. `signersOf(recordHash)` lists them in order.
///
///         Same privacy model as v2: no readable metadata on-chain. This is a
///         complementary evidentiary record. It does NOT replace a notary
///         (cartório), does not issue or validate certificates, and has no
///         automatic legal effect.
/// @dev No owner, no upgradeability. The only privileged role is the ORB
///      attester, which can sign attestations and hand the role to a new key;
///      it cannot touch records. Deployed with attester = address(0), ORB is
///      permanently off for that deployment.
contract SignatureRegistryV3 is ERC721, IERC5192 {
    using Strings for uint256;

    uint8 internal constant SCHEME_SIGNED_PDF_SHA256 = 0;
    uint8 internal constant SCHEME_SALTED_SHA256 = 1;
    uint16 internal constant LAST_LABELLED_TYPE = 11;

    /// The reveal must land at least this many blocks after the commit.
    /// One is enough: the point is that the commit predates the reveal.
    uint256 internal constant MIN_REVEAL_DELAY_BLOCKS = 1;
    /// A commitment can be revealed for this long, then it must be redone.
    uint256 public constant COMMITMENT_TTL = 1 days;

    /// EIP-712 domain: name "Niara Register", version "3", this chain, this contract.
    /// Computed by hand (no ERC-5267 eip712Domain()) to keep the bytecode under
    /// HyperEVM's 3M-gas small-block limit.
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant DOMAIN_NAME_HASH = keccak256("Niara Register");
    bytes32 private constant DOMAIN_VERSION_HASH = keccak256("3");

    bytes32 public constant ORB_ATTESTATION_TYPEHASH =
        keccak256("OrbAttestation(bytes32 recordHash,bytes32 reportHash,address signer)");

    struct Record {
        address signer;
        uint64 timestamp;
        uint8 scheme;
        uint16 documentType;
        bytes32 recordHash;
        bytes32 metadataCommitment;
        /// Hash of the ORB analysis report, zero when the document was not analysed.
        bytes32 orbReportHash;
    }

    struct Commitment {
        uint64 blockNumber;
        uint64 timestamp;
    }

    /// recordIdOf(recordHash, signer) => record. The receipt's token id is the record id.
    mapping(bytes32 => Record) private _records;
    /// recordHash => wallets that registered it, in order.
    mapping(bytes32 => address[]) private _signers;
    /// committer => commitment => when it was made.
    mapping(address => mapping(bytes32 => Commitment)) private _commitments;

    string private _verifyBaseUrl;

    /// Key allowed to sign ORB attestations (address(0): ORB disabled).
    address public orbAttester;

    event Committed(address indexed signer, bytes32 indexed commitment, uint256 blockNumber);
    event DocumentRegistered(
        bytes32 indexed recordHash,
        address indexed signer,
        uint8 scheme,
        uint16 documentType,
        bytes32 metadataCommitment,
        bytes32 orbReportHash,
        uint256 tokenId,
        uint256 timestamp
    );
    event OrbAttesterChanged(address indexed previousAttester, address indexed newAttester);

    /// This signer already registered this hash (other signers still can).
    error AlreadyRegistered(bytes32 recordHash);
    error InvalidHash();
    error UnknownScheme(uint8 scheme);
    error InvalidDocumentType();
    error Soulbound();
    error InvalidCommitment();
    error CommitmentPending(bytes32 commitment);
    error NoCommitment();
    error RevealTooEarly(uint256 revealableAtBlock);
    error CommitmentExpired();
    error OrbDisabled();
    error InvalidOrbAttestation();
    error NotOrbAttester();

    constructor(string memory verifyBaseUrl_, address orbAttester_) ERC721("Niara Register Receipt", "NIARA-R") {
        _verifyBaseUrl = verifyBaseUrl_;
        orbAttester = orbAttester_;
        emit OrbAttesterChanged(address(0), orbAttester_);
    }

    // ------------------------------------------------------------------
    // Commit-reveal
    // ------------------------------------------------------------------

    /// @notice The value to pass to `commit`. Computable off-chain with the same encoding.
    function commitmentOf(address signer, bytes32 recordHash, bytes32 nonce) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), signer, recordHash, nonce));
    }

    /// @notice Step 1: publish a commitment to a record hash without revealing it.
    /// @dev Stored under msg.sender, so copying someone else's commit is useless.
    ///      A live commitment cannot be overwritten (that would reset its delay);
    ///      an expired one can be made again.
    function commit(bytes32 commitment) external {
        if (commitment == bytes32(0)) revert InvalidCommitment();
        Commitment storage c = _commitments[msg.sender][commitment];
        if (c.blockNumber != 0 && block.timestamp <= uint256(c.timestamp) + COMMITMENT_TTL) {
            revert CommitmentPending(commitment);
        }
        c.blockNumber = uint64(block.number);
        c.timestamp = uint64(block.timestamp);
        emit Committed(msg.sender, commitment, block.number);
    }

    /// @notice When `signer` made `commitment` (zeros if never, or already revealed).
    ///         Revealable from blockNumber + 1 until timestamp + COMMITMENT_TTL.
    function commitmentInfo(address signer, bytes32 commitment)
        external
        view
        returns (uint256 blockNumber, uint256 timestamp)
    {
        Commitment memory c = _commitments[signer][commitment];
        return (c.blockNumber, c.timestamp);
    }

    // ------------------------------------------------------------------
    // Registration (reveal)
    // ------------------------------------------------------------------

    /// @notice Step 2: registers a document fingerprint committed earlier and mints
    ///         a soulbound receipt to the caller.
    /// @param recordHash See the scheme constants (same recipes as v2).
    /// @param scheme SCHEME_SIGNED_PDF_SHA256 or SCHEME_SALTED_SHA256.
    /// @param documentType Public type code; must not be 0.
    /// @param metadataCommitment Salted commitment to the metadata, or zero.
    /// @param nonce The 32-byte secret used in `commitmentOf`.
    /// @param orbReportHash Hash of the ORB report, or zero when there is none.
    /// @param orbSignature EIP-712 OrbAttestation signature by `orbAttester`; empty when
    ///        `orbReportHash` is zero.
    /// @return tokenId The receipt id, equal to uint256(recordIdOf(recordHash, msg.sender)).
    function register(
        bytes32 recordHash,
        uint8 scheme,
        uint16 documentType,
        bytes32 metadataCommitment,
        bytes32 nonce,
        bytes32 orbReportHash,
        bytes calldata orbSignature
    ) external returns (uint256 tokenId) {
        if (recordHash == bytes32(0)) revert InvalidHash();
        if (scheme > SCHEME_SALTED_SHA256) revert UnknownScheme(scheme);
        if (documentType == 0) revert InvalidDocumentType();
        bytes32 id = recordIdOf(recordHash, msg.sender);
        if (_records[id].timestamp != 0) revert AlreadyRegistered(recordHash);

        _consumeCommitment(commitmentOf(msg.sender, recordHash, nonce));
        if (orbReportHash != bytes32(0)) {
            _checkOrbAttestation(recordHash, orbReportHash, msg.sender, orbSignature);
        } else if (orbSignature.length != 0) {
            revert InvalidOrbAttestation();
        }

        _records[id] = Record({
            signer: msg.sender,
            timestamp: uint64(block.timestamp),
            scheme: scheme,
            documentType: documentType,
            recordHash: recordHash,
            metadataCommitment: metadataCommitment,
            orbReportHash: orbReportHash
        });
        _signers[recordHash].push(msg.sender);

        tokenId = uint256(id);
        // _mint, not _safeMint: the receipt goes to the caller, no callback needed.
        _mint(msg.sender, tokenId);

        emit Locked(tokenId);
        emit DocumentRegistered(
            recordHash, msg.sender, scheme, documentType, metadataCommitment, orbReportHash, tokenId, block.timestamp
        );
    }

    /// @notice Id of `signer`'s record of `recordHash` (also its receipt's token id).
    function recordIdOf(bytes32 recordHash, address signer) public pure returns (bytes32) {
        return keccak256(abi.encode(recordHash, signer));
    }

    function _consumeCommitment(bytes32 commitment) private {
        Commitment memory c = _commitments[msg.sender][commitment];
        if (c.blockNumber == 0) revert NoCommitment();
        uint256 revealableAt = uint256(c.blockNumber) + MIN_REVEAL_DELAY_BLOCKS;
        if (block.number < revealableAt) revert RevealTooEarly(revealableAt);
        if (block.timestamp > uint256(c.timestamp) + COMMITMENT_TTL) revert CommitmentExpired();
        delete _commitments[msg.sender][commitment];
    }

    // ------------------------------------------------------------------
    // ORB attestation
    // ------------------------------------------------------------------

    /// @notice EIP-712 digest the ORB attester signs for a record.
    function orbAttestationDigest(bytes32 recordHash, bytes32 reportHash, address signer)
        public
        view
        returns (bytes32)
    {
        bytes32 domain = keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, DOMAIN_NAME_HASH, DOMAIN_VERSION_HASH, block.chainid, address(this))
        );
        bytes32 structHash = keccak256(abi.encode(ORB_ATTESTATION_TYPEHASH, recordHash, reportHash, signer));
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _checkOrbAttestation(bytes32 recordHash, bytes32 reportHash, address signer, bytes calldata sig)
        private
        view
    {
        address attester = orbAttester;
        if (attester == address(0)) revert OrbDisabled();
        (address recovered, ECDSA.RecoverError err,) =
            ECDSA.tryRecover(orbAttestationDigest(recordHash, reportHash, signer), sig);
        if (err != ECDSA.RecoverError.NoError || recovered != attester) revert InvalidOrbAttestation();
    }

    /// @notice Hands the attester role to a new key (key rotation). Only the
    ///         current attester can call it; address(0) turns ORB off for good.
    function setOrbAttester(address newAttester) external {
        if (msg.sender != orbAttester || msg.sender == address(0)) revert NotOrbAttester();
        emit OrbAttesterChanged(msg.sender, newAttester);
        orbAttester = newAttester;
    }

    // ------------------------------------------------------------------
    // Reads
    // ------------------------------------------------------------------

    /// @notice Wallets that registered `recordHash`, in registration order.
    function signersOf(bytes32 recordHash) external view returns (address[] memory) {
        return _signers[recordHash];
    }

    /// @notice `signer`'s record of `recordHash`. All zeros if that wallet never registered it.
    function verify(bytes32 recordHash, address signer)
        external
        view
        returns (
            bool exists,
            uint256 timestamp,
            uint8 scheme,
            uint16 documentType,
            bytes32 metadataCommitment,
            bytes32 orbReportHash,
            uint256 tokenId
        )
    {
        bytes32 id = recordIdOf(recordHash, signer);
        Record memory r = _records[id];
        exists = r.timestamp != 0;
        return (
            exists,
            r.timestamp,
            r.scheme,
            r.documentType,
            r.metadataCommitment,
            r.orbReportHash,
            exists ? uint256(id) : 0
        );
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
        string memory hashHex = uint256(r.recordHash).toHexString(32);

        // Built in parts: one long string.concat is "stack too deep" with the optimizer on.
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
        string memory attrs = string.concat(
            '","attributes":[{"trait_type":"Record hash","value":"',
            hashHex,
            '"},{"trait_type":"Document type","value":"',
            documentTypeLabel(r.documentType),
            '"},{"trait_type":"Hash scheme","value":"',
            r.scheme == SCHEME_SIGNED_PDF_SHA256 ? "Signed PDF (PAdES) SHA-256" : "Salted SHA-256"
        );
        string memory tail = string.concat(
            '"},{"trait_type":"Signer","value":"',
            Strings.toHexString(r.signer),
            '"},{"trait_type":"ORB analysis","value":"',
            r.orbReportHash != bytes32(0) ? "Yes" : "No",
            '"},{"display_type":"date","trait_type":"Registered at","value":',
            uint256(r.timestamp).toString(),
            "}]}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(string.concat(head, attrs, tail))));
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

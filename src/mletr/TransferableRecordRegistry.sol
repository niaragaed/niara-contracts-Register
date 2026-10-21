// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @title TransferableRecordRegistry
/// @notice Electronic transferable records (e.g. promissory notes, bills of
///         lading, warehouse receipts) represented as transferable ERC-721
///         tokens, designed to line up with the functional requirements of the
///         UNCITRAL Model Law on Electronic Transferable Records (MLETR):
///
///         - Singularity (art. 10): the token id is the hash of the original
///           document, and every document hash ever used (original or
///           amended) is burned for good, so the same record can never be
///           issued twice.
///         - Exclusive control and identification of the person in control
///           (art. 11): `ownerOf(tokenId)` is the person in control; only that
///           wallet (or its approved operator) can transfer it.
///         - Integrity over the life-cycle (art. 10, 16): the document hash is
///           immutable except through an amendment the issuer proposes and the
///           person in control accepts; every version is emitted as an event.
///         - Surrender and termination, including replacement by a paper
///           document (art. 18), as explicit, recorded steps.
///
///         "Designed to line up with" is the accurate claim: MLETR only has
///         legal effect where a jurisdiction has enacted it, and Brazil has
///         not. Whether this system counts as a "reliable method" (art. 12) is
///         decided by the applicable law, not by this contract.
/// @dev No owner, no upgradeability, no admin. The issuer of each record is
///      whoever called `issue` for it.
contract TransferableRecordRegistry is ERC721 {
    enum Status {
        None,
        Active,
        Surrendered,
        Terminated
    }

    enum TerminationReason {
        Fulfilled,
        ReplacedByPaper,
        Other
    }

    struct Record {
        address issuer;
        uint64 issuedAt;
        uint32 version;
        Status status;
        bytes32 documentHash;
        bytes32 metadataCommitment;
    }

    struct Amendment {
        bytes32 documentHash;
        bytes32 metadataCommitment;
    }

    mapping(uint256 => Record) private _records;
    mapping(uint256 => Amendment) private _pendingAmendments;
    /// Every document hash ever used, original or amended.
    mapping(bytes32 => bool) public hashUsed;

    event RecordIssued(
        uint256 indexed tokenId, address indexed issuer, address indexed holder, bytes32 documentHash, bytes32 metadataCommitment
    );
    event AmendmentProposed(uint256 indexed tokenId, bytes32 newDocumentHash, bytes32 newMetadataCommitment);
    event AmendmentCancelled(uint256 indexed tokenId);
    event RecordAmended(uint256 indexed tokenId, uint32 version, bytes32 documentHash, bytes32 metadataCommitment);
    event RecordSurrendered(uint256 indexed tokenId, address indexed by);
    event RecordTerminated(uint256 indexed tokenId, TerminationReason reason);

    error InvalidHash();
    error HashAlreadyUsed(bytes32 documentHash);
    error InvalidHolder();
    error NotIssuer();
    error NotController();
    error NotActive();
    error NotSurrendered();
    error NoPendingAmendment();
    error AmendmentMismatch();

    constructor() ERC721("Niara Transferable Record", "NIARA-ETR") {}

    // ------------------------------------------------------------------
    // Life-cycle
    // ------------------------------------------------------------------

    /// @notice Issues a new transferable record and gives control to `holder`.
    /// @param documentHash SHA-256 of the document (for example the PAdES-signed PDF).
    /// @param metadataCommitment Salted commitment to off-chain metadata, or zero.
    function issue(bytes32 documentHash, bytes32 metadataCommitment, address holder)
        external
        returns (uint256 tokenId)
    {
        if (documentHash == bytes32(0)) revert InvalidHash();
        if (hashUsed[documentHash]) revert HashAlreadyUsed(documentHash);
        if (holder == address(0)) revert InvalidHolder();

        hashUsed[documentHash] = true;
        tokenId = uint256(documentHash);
        _records[tokenId] = Record({
            issuer: msg.sender,
            issuedAt: uint64(block.timestamp),
            version: 1,
            status: Status.Active,
            documentHash: documentHash,
            metadataCommitment: metadataCommitment
        });

        _mint(holder, tokenId);
        emit RecordIssued(tokenId, msg.sender, holder, documentHash, metadataCommitment);
    }

    /// @notice The issuer proposes a new version of the document. Nothing
    ///         changes until the person in control accepts it.
    function proposeAmendment(uint256 tokenId, bytes32 newDocumentHash, bytes32 newMetadataCommitment) external {
        Record storage r = _activeRecord(tokenId);
        if (msg.sender != r.issuer) revert NotIssuer();
        if (newDocumentHash == bytes32(0)) revert InvalidHash();
        if (hashUsed[newDocumentHash]) revert HashAlreadyUsed(newDocumentHash);

        _pendingAmendments[tokenId] = Amendment({documentHash: newDocumentHash, metadataCommitment: newMetadataCommitment});
        emit AmendmentProposed(tokenId, newDocumentHash, newMetadataCommitment);
    }

    function cancelAmendment(uint256 tokenId) external {
        Record storage r = _activeRecord(tokenId);
        if (msg.sender != r.issuer) revert NotIssuer();
        if (_pendingAmendments[tokenId].documentHash == bytes32(0)) revert NoPendingAmendment();
        delete _pendingAmendments[tokenId];
        emit AmendmentCancelled(tokenId);
    }

    /// @notice The person in control accepts the pending amendment.
    /// @param expectedDocumentHash Must match the proposal, so a proposal
    ///        swapped right before acceptance cannot be accepted by mistake.
    function acceptAmendment(uint256 tokenId, bytes32 expectedDocumentHash) external {
        Record storage r = _activeRecord(tokenId);
        if (msg.sender != ownerOf(tokenId)) revert NotController();
        Amendment memory a = _pendingAmendments[tokenId];
        if (a.documentHash == bytes32(0)) revert NoPendingAmendment();
        if (a.documentHash != expectedDocumentHash) revert AmendmentMismatch();
        // Re-checked here: another record may have used the hash meanwhile.
        if (hashUsed[a.documentHash]) revert HashAlreadyUsed(a.documentHash);

        hashUsed[a.documentHash] = true;
        r.documentHash = a.documentHash;
        r.metadataCommitment = a.metadataCommitment;
        r.version += 1;
        delete _pendingAmendments[tokenId];
        emit RecordAmended(tokenId, r.version, a.documentHash, a.metadataCommitment);
    }

    /// @notice The person in control surrenders the record to the issuer
    ///         (presentation for payment/delivery, or a request to replace it
    ///         with paper). Control passes to the issuer and transfers stop.
    function surrender(uint256 tokenId) external {
        Record storage r = _activeRecord(tokenId);
        address controller = ownerOf(tokenId);
        if (msg.sender != controller) revert NotController();

        r.status = Status.Surrendered;
        delete _pendingAmendments[tokenId];
        if (controller != r.issuer) {
            // Internal move that bypasses the "active only" transfer rule.
            _transfer(controller, r.issuer, tokenId);
        }
        emit RecordSurrendered(tokenId, controller);
    }

    /// @notice The issuer ends a surrendered record. The token is burned; the
    ///         record data and its hashes stay on-chain for evidence.
    function terminate(uint256 tokenId, TerminationReason reason) external {
        Record storage r = _records[tokenId];
        if (r.status != Status.Surrendered) revert NotSurrendered();
        if (msg.sender != r.issuer) revert NotIssuer();

        r.status = Status.Terminated;
        _burn(tokenId);
        emit RecordTerminated(tokenId, reason);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function getRecord(uint256 tokenId) external view returns (Record memory) {
        return _records[tokenId];
    }

    function pendingAmendment(uint256 tokenId) external view returns (Amendment memory) {
        return _pendingAmendments[tokenId];
    }

    /// The person in control, or address(0) once terminated.
    function controllerOf(uint256 tokenId) external view returns (address) {
        return _ownerOf(tokenId);
    }

    // ------------------------------------------------------------------
    // Transfer rule: only active records move between holders
    // ------------------------------------------------------------------

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        bool isMint = from == address(0);
        bool isBurn = to == address(0);
        if (!isMint && !isBurn) {
            Status s = _records[tokenId].status;
            // `surrender` moves the token while the status is already Surrendered;
            // that path calls with auth == address(0) (no approval check).
            bool internalSurrender = s == Status.Surrendered && auth == address(0);
            if (s != Status.Active && !internalSurrender) revert NotActive();
        }
        return super._update(to, tokenId, auth);
    }

    function _activeRecord(uint256 tokenId) private view returns (Record storage r) {
        r = _records[tokenId];
        if (r.status != Status.Active) revert NotActive();
    }
}

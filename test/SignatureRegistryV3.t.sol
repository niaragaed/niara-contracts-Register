// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC5192} from "../src/v2/SignatureRegistryV2.sol";
import {SignatureRegistryV3} from "../src/v3/SignatureRegistryV3.sol";

contract SignatureRegistryV3Test is Test {
    SignatureRegistryV3 registry;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    uint256 orbKey = 0x0B5;
    address orb;

    uint16 constant CONTRACT_TYPE = 1;
    string constant BASE = "https://niara-register.vercel.app/verify/sepolia/";
    bytes32 constant NONCE = bytes32(uint256(0x4e4f4e4345));
    bytes32 constant REPORT = keccak256("orb report json");

    bytes32 FILE_SHA;
    bytes32 META;

    function setUp() public {
        orb = vm.addr(orbKey);
        registry = new SignatureRegistryV3(BASE, orb);
        FILE_SHA = sha256("signed pdf bytes");
        META = sha256(abi.encodePacked("niara-meta-v1", bytes32(uint256(0x5a17)), '{"name":"Lease","type":"contract"}'));
    }

    // --- helpers ----------------------------------------------------------

    function _commit(address who, bytes32 h, bytes32 nonce) internal {
        bytes32 c = registry.commitmentOf(who, h, nonce);
        vm.prank(who);
        registry.commit(c);
    }

    function _commitAndWait(address who, bytes32 h) internal {
        _commit(who, h, NONCE);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
    }

    function _register(address who, bytes32 h) internal returns (uint256) {
        vm.prank(who);
        return registry.register(h, 0, CONTRACT_TYPE, META, NONCE, bytes32(0), "");
    }

    function _orbSig(bytes32 h, bytes32 report, address signer, uint256 key) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, registry.orbAttestationDigest(h, report, signer));
        return abi.encodePacked(r, s, v);
    }

    // --- commitment encoding (cross-implementation) -------------------------

    /// The site computes the same value with viem:
    /// keccak256(encodeAbiParameters([uint256,address,address,bytes32,bytes32], [...])).
    function test_CommitmentEncoding() public view {
        bytes32 expected = keccak256(abi.encode(block.chainid, address(registry), alice, FILE_SHA, NONCE));
        assertEq(registry.commitmentOf(alice, FILE_SHA, NONCE), expected);
        // Different signer, nonce or hash => different commitment.
        assertTrue(registry.commitmentOf(bob, FILE_SHA, NONCE) != expected);
        assertTrue(registry.commitmentOf(alice, FILE_SHA, bytes32(uint256(1))) != expected);
        assertTrue(registry.commitmentOf(alice, META, NONCE) != expected);
    }

    /// Fixed vector shared with Niara-Register/tests/commit-reveal.test.ts.
    function test_CommitmentVector() public {
        vm.chainId(11155111);
        address reg = 0x1111111111111111111111111111111111111111;
        bytes32 c = keccak256(abi.encode(uint256(11155111), reg, alice, FILE_SHA, NONCE));
        assertEq(c, 0x62b38dd5b4af7624c09d1cbdd4ddd77eb508a8411f8cea746c408211570ffd8a);
    }

    // --- commit-reveal ----------------------------------------------------

    function test_CommitThenRevealInLaterBlock() public {
        _commitAndWait(alice, FILE_SHA);
        uint256 tokenId = _register(alice, FILE_SHA);
        assertEq(tokenId, uint256(FILE_SHA));
        assertEq(registry.ownerOf(tokenId), alice);
        (bool exists, address signer, uint256 ts, uint8 scheme, uint16 t, bytes32 meta, bytes32 orbHash) =
            registry.verify(FILE_SHA);
        assertTrue(exists);
        assertEq(signer, alice);
        assertEq(ts, block.timestamp);
        assertEq(scheme, 0);
        assertEq(t, CONTRACT_TYPE);
        assertEq(meta, META);
        assertEq(orbHash, bytes32(0));
    }

    function test_RevealWithoutCommitReverts() public {
        vm.prank(alice);
        vm.expectRevert(SignatureRegistryV3.NoCommitment.selector);
        registry.register(FILE_SHA, 0, CONTRACT_TYPE, META, NONCE, bytes32(0), "");
    }

    function test_RevealInSameBlockReverts() public {
        _commit(alice, FILE_SHA, NONCE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SignatureRegistryV3.RevealTooEarly.selector, block.number + 1));
        registry.register(FILE_SHA, 0, CONTRACT_TYPE, META, NONCE, bytes32(0), "");
    }

    function test_RevealAfterTtlReverts() public {
        _commit(alice, FILE_SHA, NONCE);
        vm.roll(block.number + 10);
        vm.warp(block.timestamp + registry.COMMITMENT_TTL() + 1);
        vm.prank(alice);
        vm.expectRevert(SignatureRegistryV3.CommitmentExpired.selector);
        registry.register(FILE_SHA, 0, CONTRACT_TYPE, META, NONCE, bytes32(0), "");
    }

    function test_RevealAtTtlBoundaryWorks() public {
        _commit(alice, FILE_SHA, NONCE);
        vm.roll(block.number + 10);
        vm.warp(block.timestamp + registry.COMMITMENT_TTL());
        _register(alice, FILE_SHA);
    }

    function test_WrongNonceReverts() public {
        _commitAndWait(alice, FILE_SHA);
        vm.prank(alice);
        vm.expectRevert(SignatureRegistryV3.NoCommitment.selector);
        registry.register(FILE_SHA, 0, CONTRACT_TYPE, META, bytes32(uint256(2)), bytes32(0), "");
    }

    /// The attack the change exists for: Bob sees Alice's reveal in the mempool
    /// and sends the same call. He has no commitment under his address.
    function test_FrontRunnerCopyingTheRevealFails() public {
        _commitAndWait(alice, FILE_SHA);
        vm.prank(bob);
        vm.expectRevert(SignatureRegistryV3.NoCommitment.selector);
        registry.register(FILE_SHA, 0, CONTRACT_TYPE, META, NONCE, bytes32(0), "");
        _register(alice, FILE_SHA);
        assertEq(registry.ownerOf(uint256(FILE_SHA)), alice);
    }

    /// Copying Alice's commit value does not help Bob either: it is bound to her address.
    function test_FrontRunnerCopyingTheCommitFails() public {
        bytes32 c = registry.commitmentOf(alice, FILE_SHA, NONCE);
        vm.prank(bob);
        registry.commit(c);
        vm.prank(alice);
        registry.commit(c);
        vm.roll(block.number + 1);
        vm.prank(bob);
        vm.expectRevert(SignatureRegistryV3.NoCommitment.selector);
        registry.register(FILE_SHA, 0, CONTRACT_TYPE, META, NONCE, bytes32(0), "");
        _register(alice, FILE_SHA);
    }

    /// Bob can still register the same document with his OWN commitment if he
    /// has the hash first (e.g. the other party of a contract). First valid
    /// reveal wins; the record shows who registered, not who authored the PDF.
    function test_FirstValidRevealWins() public {
        _commit(alice, FILE_SHA, NONCE);
        _commit(bob, FILE_SHA, NONCE);
        vm.roll(block.number + 1);
        _register(bob, FILE_SHA);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SignatureRegistryV3.AlreadyRegistered.selector, FILE_SHA));
        registry.register(FILE_SHA, 0, CONTRACT_TYPE, META, NONCE, bytes32(0), "");
    }

    function test_CommitmentIsConsumed() public {
        bytes32 c = registry.commitmentOf(alice, FILE_SHA, NONCE);
        _commitAndWait(alice, FILE_SHA);
        (uint256 bn,, uint256 revealable, uint256 expires) = registry.commitmentInfo(alice, c);
        assertEq(bn, block.number - 1);
        assertEq(revealable, block.number);
        assertEq(expires, block.timestamp - 12 + registry.COMMITMENT_TTL());
        _register(alice, FILE_SHA);
        (bn,,,) = registry.commitmentInfo(alice, c);
        assertEq(bn, 0);
    }

    function test_LiveCommitmentCannotBeReset() public {
        bytes32 c = registry.commitmentOf(alice, FILE_SHA, NONCE);
        vm.prank(alice);
        registry.commit(c);
        vm.roll(block.number + 5);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SignatureRegistryV3.CommitmentPending.selector, c));
        registry.commit(c);
    }

    function test_ExpiredCommitmentCanBeRemade() public {
        bytes32 c = registry.commitmentOf(alice, FILE_SHA, NONCE);
        vm.prank(alice);
        registry.commit(c);
        vm.warp(block.timestamp + registry.COMMITMENT_TTL() + 1);
        vm.roll(block.number + 1);
        vm.prank(alice);
        registry.commit(c);
        vm.roll(block.number + 1);
        _register(alice, FILE_SHA);
    }

    function test_ZeroCommitmentReverts() public {
        vm.expectRevert(SignatureRegistryV3.InvalidCommitment.selector);
        registry.commit(bytes32(0));
    }

    function test_CommitEmitsEvent() public {
        bytes32 c = registry.commitmentOf(alice, FILE_SHA, NONCE);
        vm.expectEmit(true, true, false, true);
        emit SignatureRegistryV3.Committed(alice, c, block.number);
        vm.prank(alice);
        registry.commit(c);
    }

    // --- validation (unchanged from v2) -------------------------------------

    function test_ValidationErrorsComeBeforeTheCommitmentCheck() public {
        vm.startPrank(alice);
        vm.expectRevert(SignatureRegistryV3.InvalidHash.selector);
        registry.register(bytes32(0), 0, CONTRACT_TYPE, META, NONCE, bytes32(0), "");
        vm.expectRevert(abi.encodeWithSelector(SignatureRegistryV3.UnknownScheme.selector, uint8(2)));
        registry.register(FILE_SHA, 2, CONTRACT_TYPE, META, NONCE, bytes32(0), "");
        vm.expectRevert(SignatureRegistryV3.InvalidDocumentType.selector);
        registry.register(FILE_SHA, 0, 0, META, NONCE, bytes32(0), "");
        vm.stopPrank();
    }

    function test_EmitsLockedAndDocumentRegistered() public {
        _commitAndWait(alice, FILE_SHA);
        vm.expectEmit(false, false, false, true);
        emit IERC5192.Locked(uint256(FILE_SHA));
        vm.expectEmit(true, true, false, true);
        emit SignatureRegistryV3.DocumentRegistered(
            FILE_SHA, alice, 0, CONTRACT_TYPE, META, bytes32(0), block.timestamp
        );
        _register(alice, FILE_SHA);
    }

    // --- ORB attestation ----------------------------------------------------

    function test_RegisterWithOrbAttestation() public {
        _commitAndWait(alice, FILE_SHA);
        bytes memory sig = _orbSig(FILE_SHA, REPORT, alice, orbKey);
        vm.expectEmit(true, true, false, true);
        emit SignatureRegistryV3.DocumentRegistered(FILE_SHA, alice, 0, CONTRACT_TYPE, META, REPORT, block.timestamp);
        vm.prank(alice);
        registry.register(FILE_SHA, 0, CONTRACT_TYPE, META, NONCE, REPORT, sig);
        (,,,,,, bytes32 orbHash) = registry.verify(FILE_SHA);
        assertEq(orbHash, REPORT);
    }

    function test_OrbFlagCannotBeSelfClaimed() public {
        _commitAndWait(alice, FILE_SHA);
        bytes memory forged = _orbSig(FILE_SHA, REPORT, alice, 0xBAD);
        vm.prank(alice);
        vm.expectRevert(SignatureRegistryV3.InvalidOrbAttestation.selector);
        registry.register(FILE_SHA, 0, CONTRACT_TYPE, META, NONCE, REPORT, forged);

        vm.prank(alice);
        vm.expectRevert(SignatureRegistryV3.InvalidOrbAttestation.selector);
        registry.register(FILE_SHA, 0, CONTRACT_TYPE, META, NONCE, REPORT, "");
    }

    /// An attestation is bound to the signer and the record: Bob cannot reuse
    /// Alice's, and it cannot be moved to another document or report.
    function test_OrbAttestationIsBound() public {
        bytes32 other = sha256("other pdf");
        _commit(alice, other, NONCE);
        _commit(bob, FILE_SHA, NONCE);
        _commit(alice, FILE_SHA, NONCE);
        vm.roll(block.number + 1);
        bytes memory sig = _orbSig(FILE_SHA, REPORT, alice, orbKey);

        vm.prank(bob);
        vm.expectRevert(SignatureRegistryV3.InvalidOrbAttestation.selector);
        registry.register(FILE_SHA, 0, CONTRACT_TYPE, META, NONCE, REPORT, sig);

        vm.prank(alice);
        vm.expectRevert(SignatureRegistryV3.InvalidOrbAttestation.selector);
        registry.register(other, 0, CONTRACT_TYPE, META, NONCE, REPORT, sig);

        vm.prank(alice);
        vm.expectRevert(SignatureRegistryV3.InvalidOrbAttestation.selector);
        registry.register(FILE_SHA, 0, CONTRACT_TYPE, META, NONCE, keccak256("other report"), sig);
    }

    function test_SignatureWithoutReportHashReverts() public {
        _commitAndWait(alice, FILE_SHA);
        bytes memory sig = _orbSig(FILE_SHA, REPORT, alice, orbKey);
        vm.prank(alice);
        vm.expectRevert(SignatureRegistryV3.InvalidOrbAttestation.selector);
        registry.register(FILE_SHA, 0, CONTRACT_TYPE, META, NONCE, bytes32(0), sig);
    }

    function test_OrbDisabledDeployment() public {
        SignatureRegistryV3 noOrb = new SignatureRegistryV3(BASE, address(0));
        bytes32 c = noOrb.commitmentOf(alice, FILE_SHA, NONCE);
        vm.prank(alice);
        noOrb.commit(c);
        vm.roll(block.number + 1);
        vm.prank(alice);
        vm.expectRevert(SignatureRegistryV3.OrbDisabled.selector);
        noOrb.register(FILE_SHA, 0, CONTRACT_TYPE, META, NONCE, REPORT, hex"00");
        vm.expectRevert(SignatureRegistryV3.NotOrbAttester.selector);
        noOrb.setOrbAttester(alice);
    }

    function test_OrbAttesterRotation() public {
        uint256 newKey = 0xC0FFEE;
        address newOrb = vm.addr(newKey);
        vm.prank(alice);
        vm.expectRevert(SignatureRegistryV3.NotOrbAttester.selector);
        registry.setOrbAttester(alice);

        vm.expectEmit(true, true, false, false);
        emit SignatureRegistryV3.OrbAttesterChanged(orb, newOrb);
        vm.prank(orb);
        registry.setOrbAttester(newOrb);
        assertEq(registry.orbAttester(), newOrb);

        _commitAndWait(alice, FILE_SHA);
        bytes memory oldSig = _orbSig(FILE_SHA, REPORT, alice, orbKey);
        vm.prank(alice);
        vm.expectRevert(SignatureRegistryV3.InvalidOrbAttestation.selector);
        registry.register(FILE_SHA, 0, CONTRACT_TYPE, META, NONCE, REPORT, oldSig);

        bytes memory newSig = _orbSig(FILE_SHA, REPORT, alice, newKey);
        vm.prank(alice);
        registry.register(FILE_SHA, 0, CONTRACT_TYPE, META, NONCE, REPORT, newSig);
    }

    // --- soulbound and metadata -------------------------------------------

    function test_ReceiptIsSoulbound() public {
        _commitAndWait(alice, FILE_SHA);
        uint256 tokenId = _register(alice, FILE_SHA);
        assertTrue(registry.locked(tokenId));
        vm.startPrank(alice);
        vm.expectRevert(SignatureRegistryV3.Soulbound.selector);
        registry.transferFrom(alice, bob, tokenId);
        vm.expectRevert(SignatureRegistryV3.Soulbound.selector);
        registry.approve(bob, tokenId);
        vm.expectRevert(SignatureRegistryV3.Soulbound.selector);
        registry.setApprovalForAll(bob, true);
        vm.stopPrank();
        assertTrue(registry.supportsInterface(0xb45a3c0e));
        assertTrue(registry.supportsInterface(0x80ac58cd));
    }

    function test_TokenURIWithoutOrb() public {
        _commitAndWait(alice, FILE_SHA);
        uint256 tokenId = _register(alice, FILE_SHA);
        string memory json = _json(registry.tokenURI(tokenId));
        assertTrue(_contains(json, string.concat('"external_url":"', BASE, vm.toString(FILE_SHA), '"')));
        assertTrue(_contains(json, '"trait_type":"Document type","value":"Contract"'));
        assertTrue(_contains(json, '"trait_type":"ORB analysis","value":"No"'));
        assertFalse(_contains(json, vm.toString(META)));
    }

    function test_TokenURIWithOrb() public {
        _commitAndWait(alice, FILE_SHA);
        bytes memory sig = _orbSig(FILE_SHA, REPORT, alice, orbKey);
        vm.prank(alice);
        uint256 tokenId = registry.register(FILE_SHA, 0, CONTRACT_TYPE, META, NONCE, REPORT, sig);
        string memory json = _json(registry.tokenURI(tokenId));
        assertTrue(_contains(json, '"trait_type":"ORB analysis","value":"Yes"'));
        // The report hash itself is not in the receipt.
        assertFalse(_contains(json, vm.toString(REPORT)));
    }

    function test_TokenURIRevertsForUnknownToken() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(7)));
        registry.tokenURI(7);
    }

    function testFuzz_CommitRevealAnyHash(bytes32 h, bytes32 nonce, uint8 scheme, uint16 docType, address who) public {
        vm.assume(h != bytes32(0) && who != address(0));
        scheme = uint8(bound(scheme, 0, 1));
        docType = uint16(bound(docType, 1, type(uint16).max));
        bytes32 c = registry.commitmentOf(who, h, nonce);
        vm.prank(who);
        registry.commit(c);
        vm.roll(block.number + 1);
        vm.prank(who);
        registry.register(h, scheme, docType, bytes32(0), nonce, bytes32(0), "");
        assertEq(registry.ownerOf(uint256(h)), who);
    }

    // --- string helpers -----------------------------------------------------

    function _json(string memory uri) private pure returns (string memory) {
        bytes memory a = bytes(uri);
        uint256 from = bytes("data:application/json;base64,").length;
        bytes memory out = new bytes(a.length - from);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = a[from + i];
        }
        return string(Base64.decode(string(out)));
    }

    function _contains(string memory s, string memory needle) private pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(needle);
        if (b.length > a.length) return false;
        for (uint256 i = 0; i + b.length <= a.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < b.length; j++) {
                if (a[i + j] != b[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SignatureRegistryV2, IERC5192} from "../src/v2/SignatureRegistryV2.sol";

contract SignatureRegistryV2Test is Test {
    SignatureRegistryV2 registry;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    string constant BASE = "https://niara-register.vercel.app/verify/sepolia/";

    // sha256 is a precompile call, so it would consume vm.prank/expectRevert if
    // evaluated inline; hashes are computed once in setUp.
    bytes32 FILE_SHA;
    bytes32 constant SALT = bytes32(uint256(0x5a17));
    bytes32 META;
    bytes32 SALTED;

    function setUp() public {
        registry = new SignatureRegistryV2(BASE);
        FILE_SHA = sha256("signed pdf bytes");
        // Same recipes the site uses (lib/commitments.ts).
        SALTED = sha256(abi.encodePacked("niara-record-v1", SALT, FILE_SHA));
        META = sha256(abi.encodePacked("niara-meta-v1", SALT, '{"name":"Lease","type":"contract"}'));
    }

    // --- registration -----------------------------------------------------

    function test_RegisterStoresRecordAndMintsReceipt() public {
        vm.prank(alice);
        uint256 tokenId = registry.register(FILE_SHA, 0, META);

        assertEq(tokenId, uint256(FILE_SHA));
        assertEq(registry.ownerOf(tokenId), alice);
        assertEq(registry.balanceOf(alice), 1);

        (bool exists, address signer, uint256 ts, uint8 scheme, bytes32 meta) = registry.verify(FILE_SHA);
        assertTrue(exists);
        assertEq(signer, alice);
        assertEq(ts, block.timestamp);
        assertEq(scheme, 0);
        assertEq(meta, META);
    }

    function test_RegisterSaltedScheme() public {
        vm.prank(alice);
        registry.register(SALTED, 1, bytes32(0));
        (bool exists,,, uint8 scheme, bytes32 meta) = registry.verify(SALTED);
        assertTrue(exists);
        assertEq(scheme, 1);
        assertEq(meta, bytes32(0));
    }

    function test_EmitsLockedAndDocumentRegistered() public {
        vm.expectEmit(false, false, false, true);
        emit IERC5192.Locked(uint256(FILE_SHA));
        vm.expectEmit(true, true, false, true);
        emit SignatureRegistryV2.DocumentRegistered(FILE_SHA, alice, 0, META, block.timestamp);
        vm.prank(alice);
        registry.register(FILE_SHA, 0, META);
    }

    function test_RevertsOnDuplicateEvenFromAnotherSigner() public {
        vm.prank(alice);
        registry.register(FILE_SHA, 0, META);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SignatureRegistryV2.AlreadyRegistered.selector, FILE_SHA));
        registry.register(FILE_SHA, 1, bytes32(0));
    }

    function test_RevertsOnZeroHash() public {
        vm.expectRevert(SignatureRegistryV2.InvalidHash.selector);
        registry.register(bytes32(0), 0, META);
    }

    function test_RevertsOnUnknownScheme() public {
        vm.expectRevert(abi.encodeWithSelector(SignatureRegistryV2.UnknownScheme.selector, uint8(2)));
        registry.register(FILE_SHA, 2, META);
    }

    function test_UnknownHashReturnsZeros() public view {
        (bool exists, address signer, uint256 ts, uint8 scheme, bytes32 meta) = registry.verify(FILE_SHA);
        assertFalse(exists);
        assertEq(signer, address(0));
        assertEq(ts, 0);
        assertEq(scheme, 0);
        assertEq(meta, bytes32(0));
    }

    // --- soulbound --------------------------------------------------------

    function test_ReceiptIsLocked() public {
        vm.prank(alice);
        uint256 tokenId = registry.register(FILE_SHA, 0, META);
        assertTrue(registry.locked(tokenId));
    }

    function test_LockedRevertsForUnknownToken() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(1)));
        registry.locked(1);
    }

    function test_TransfersRevert() public {
        vm.prank(alice);
        uint256 tokenId = registry.register(FILE_SHA, 0, META);

        vm.startPrank(alice);
        vm.expectRevert(SignatureRegistryV2.Soulbound.selector);
        registry.transferFrom(alice, bob, tokenId);
        vm.expectRevert(SignatureRegistryV2.Soulbound.selector);
        registry.safeTransferFrom(alice, bob, tokenId);
        vm.expectRevert(SignatureRegistryV2.Soulbound.selector);
        registry.safeTransferFrom(alice, bob, tokenId, "");
        vm.stopPrank();

        assertEq(registry.ownerOf(tokenId), alice);
    }

    function test_ApprovalsRevert() public {
        vm.prank(alice);
        uint256 tokenId = registry.register(FILE_SHA, 0, META);
        vm.startPrank(alice);
        vm.expectRevert(SignatureRegistryV2.Soulbound.selector);
        registry.approve(bob, tokenId);
        vm.expectRevert(SignatureRegistryV2.Soulbound.selector);
        registry.setApprovalForAll(bob, true);
        vm.stopPrank();
    }

    function test_SupportsInterfaces() public view {
        assertTrue(registry.supportsInterface(0xb45a3c0e)); // ERC-5192
        assertTrue(registry.supportsInterface(0x80ac58cd)); // ERC-721
        assertTrue(registry.supportsInterface(0x5b5e139f)); // ERC-721 Metadata
        assertTrue(registry.supportsInterface(0x01ffc9a7)); // ERC-165
        assertFalse(registry.supportsInterface(0xffffffff));
    }

    // --- metadata ---------------------------------------------------------

    function test_TokenURIIsOnChainJsonWithoutPrivateData() public {
        vm.prank(alice);
        uint256 tokenId = registry.register(FILE_SHA, 0, META);

        string memory uri = registry.tokenURI(tokenId);
        string memory prefix = "data:application/json;base64,";
        assertTrue(_startsWith(uri, prefix));

        string memory json = string(Base64.decode(_slice(uri, bytes(prefix).length)));
        string memory hashHex = vm.toString(FILE_SHA);
        assertTrue(_contains(json, string.concat('"external_url":"', BASE, hashHex, '"')));
        assertTrue(_contains(json, "Signed PDF (PAdES) SHA-256"));
        assertTrue(_contains(json, string.concat('"value":', vm.toString(block.timestamp))));
        // The metadata commitment is not exposed in the receipt.
        assertFalse(_contains(json, vm.toString(META)));
        assertEq(registry.verifyBaseUrl(), BASE);
    }

    function test_TokenURIRevertsForUnknownToken() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(7)));
        registry.tokenURI(7);
    }

    function testFuzz_RegisterAnyNonZeroHash(bytes32 h, uint8 scheme, bytes32 meta, address who) public {
        vm.assume(h != bytes32(0) && who != address(0));
        scheme = uint8(bound(scheme, 0, 1));
        vm.prank(who);
        uint256 tokenId = registry.register(h, scheme, meta);
        assertEq(registry.ownerOf(tokenId), who);
        (bool exists, address signer,, uint8 s, bytes32 m) = registry.verify(h);
        assertTrue(exists);
        assertEq(signer, who);
        assertEq(s, scheme);
        assertEq(m, meta);
    }

    // --- helpers ----------------------------------------------------------

    function _startsWith(string memory s, string memory p) private pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(p);
        if (b.length > a.length) return false;
        for (uint256 i = 0; i < b.length; i++) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    function _slice(string memory s, uint256 from) private pure returns (string memory) {
        bytes memory a = bytes(s);
        bytes memory out = new bytes(a.length - from);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = a[from + i];
        }
        return string(out);
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

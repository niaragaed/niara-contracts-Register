// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RegistroAssinaturas} from "../src/registro/RegistroAssinaturas.sol";

contract RegistroAssinaturasTest is Test {
    RegistroAssinaturas registry;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    bytes32 constant DOC_HASH_1 = keccak256("document-1");
    bytes32 constant DOC_HASH_2 = keccak256("document-2");

    function setUp() public {
        registry = new RegistroAssinaturas();
    }

    function test_RegistersDocumentSuccessfully() public {
        vm.prank(alice);
        registry.registrar(DOC_HASH_1, "Meeting minutes", "minutes");

        (bool exists, address signer, uint256 ts, string memory name, string memory docType) =
            registry.verificar(DOC_HASH_1);

        assertTrue(exists);
        assertEq(signer, alice);
        assertEq(ts, block.timestamp);
        assertEq(name, "Meeting minutes");
        assertEq(docType, "minutes");
    }

    function test_EmitsEventOnRegister() public {
        vm.expectEmit(true, true, false, true);
        emit RegistroAssinaturas.DocumentoRegistrado(
            DOC_HASH_1, alice, "Meeting minutes", "minutes", block.timestamp
        );

        vm.prank(alice);
        registry.registrar(DOC_HASH_1, "Meeting minutes", "minutes");
    }

    function test_RevertWhenDocumentAlreadyRegistered() public {
        vm.prank(alice);
        registry.registrar(DOC_HASH_1, "Meeting minutes", "minutes");

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(RegistroAssinaturas.DocumentoJaRegistrado.selector, DOC_HASH_1)
        );
        registry.registrar(DOC_HASH_1, "Overwrite attempt", "minutes");
    }

    function test_RevertWhenHashIsZero() public {
        vm.prank(alice);
        vm.expectRevert(RegistroAssinaturas.HashInvalido.selector);
        registry.registrar(bytes32(0), "Invalid document", "minutes");
    }

    function test_VerifyUnknownDocumentReturnsEmpty() public view {
        (bool exists, address signer, uint256 ts, string memory name, string memory docType) =
            registry.verificar(DOC_HASH_2);

        assertFalse(exists);
        assertEq(signer, address(0));
        assertEq(ts, 0);
        assertEq(name, "");
        assertEq(docType, "");
    }

    function test_TwoDifferentDocumentsDoNotCollide() public {
        vm.prank(alice);
        registry.registrar(DOC_HASH_1, "Document A", "contract");

        vm.prank(bob);
        registry.registrar(DOC_HASH_2, "Document B", "cap table");

        (, address signer1,,,) = registry.verificar(DOC_HASH_1);
        (, address signer2,,,) = registry.verificar(DOC_HASH_2);

        assertEq(signer1, alice);
        assertEq(signer2, bob);
    }

    function testFuzz_RegistersAnyNonZeroHash(bytes32 hash, address who) public {
        vm.assume(hash != bytes32(0));
        vm.assume(who != address(0));

        vm.prank(who);
        registry.registrar(hash, "Fuzz doc", "generic");

        (bool exists, address signer,,,) = registry.verificar(hash);
        assertTrue(exists);
        assertEq(signer, who);
    }
}

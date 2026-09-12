// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RegistroAssinaturas} from "../src/registro/RegistroAssinaturas.sol";

contract RegistroAssinaturasTest is Test {
    RegistroAssinaturas registro;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    bytes32 constant HASH_DOC_1 = keccak256("documento-1");
    bytes32 constant HASH_DOC_2 = keccak256("documento-2");

    function setUp() public {
        registro = new RegistroAssinaturas();
    }

    function test_RegistraDocumentoComSucesso() public {
        vm.prank(alice);
        registro.registrar(HASH_DOC_1, "Ata de reuniao", "ata");

        (bool existe, address assinante, uint256 ts, string memory nome, string memory tipo) =
            registro.verificar(HASH_DOC_1);

        assertTrue(existe);
        assertEq(assinante, alice);
        assertEq(ts, block.timestamp);
        assertEq(nome, "Ata de reuniao");
        assertEq(tipo, "ata");
    }

    function test_EmiteEventoAoRegistrar() public {
        vm.expectEmit(true, true, false, true);
        emit RegistroAssinaturas.DocumentoRegistrado(
            HASH_DOC_1, alice, "Ata de reuniao", "ata", block.timestamp
        );

        vm.prank(alice);
        registro.registrar(HASH_DOC_1, "Ata de reuniao", "ata");
    }

    function test_RevertQuandoDocumentoJaRegistrado() public {
        vm.prank(alice);
        registro.registrar(HASH_DOC_1, "Ata de reuniao", "ata");

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(RegistroAssinaturas.DocumentoJaRegistrado.selector, HASH_DOC_1)
        );
        registro.registrar(HASH_DOC_1, "Tentativa de sobrescrever", "ata");
    }

    function test_RevertQuandoHashZerado() public {
        vm.prank(alice);
        vm.expectRevert(RegistroAssinaturas.HashInvalido.selector);
        registro.registrar(bytes32(0), "Documento invalido", "ata");
    }

    function test_VerificarDocumentoInexistenteRetornaVazio() public view {
        (bool existe, address assinante, uint256 ts, string memory nome, string memory tipo) =
            registro.verificar(HASH_DOC_2);

        assertFalse(existe);
        assertEq(assinante, address(0));
        assertEq(ts, 0);
        assertEq(nome, "");
        assertEq(tipo, "");
    }

    function test_DoisDocumentosDiferentesNaoColidem() public {
        vm.prank(alice);
        registro.registrar(HASH_DOC_1, "Documento A", "contrato");

        vm.prank(bob);
        registro.registrar(HASH_DOC_2, "Documento B", "cap table");

        (, address assinante1,,,) = registro.verificar(HASH_DOC_1);
        (, address assinante2,,,) = registro.verificar(HASH_DOC_2);

        assertEq(assinante1, alice);
        assertEq(assinante2, bob);
    }

    function testFuzz_RegistraQualquerHashNaoZerado(bytes32 hash, address quem) public {
        vm.assume(hash != bytes32(0));
        vm.assume(quem != address(0));

        vm.prank(quem);
        registro.registrar(hash, "Doc fuzz", "generico");

        (bool existe, address assinante,,,) = registro.verificar(hash);
        assertTrue(existe);
        assertEq(assinante, quem);
    }
}

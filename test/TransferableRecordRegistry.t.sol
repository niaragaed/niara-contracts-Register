// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TransferableRecordRegistry} from "../src/mletr/TransferableRecordRegistry.sol";

contract TransferableRecordRegistryTest is Test {
    TransferableRecordRegistry etr;

    address issuer = address(0x1551);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xC4401);

    // sha256 is a precompile call, so it would consume vm.prank/expectRevert if
    // evaluated inline; hashes are computed once in setUp.
    bytes32 DOC;
    bytes32 DOC_V2;
    bytes32 OTHER;
    bytes32 constant META = bytes32(uint256(0xbeef));
    uint256 tokenId;

    function setUp() public {
        etr = new TransferableRecordRegistry();
        DOC = sha256("promissory note v1");
        DOC_V2 = sha256("promissory note v2");
        OTHER = sha256("other");
        vm.prank(issuer);
        tokenId = etr.issue(DOC, META, alice);
    }

    // --- issue ------------------------------------------------------------

    function test_IssueGivesControlToHolder() public view {
        assertEq(tokenId, uint256(DOC));
        assertEq(etr.ownerOf(tokenId), alice);
        assertEq(etr.controllerOf(tokenId), alice);
        TransferableRecordRegistry.Record memory r = etr.getRecord(tokenId);
        assertEq(r.issuer, issuer);
        assertEq(r.version, 1);
        assertEq(uint8(r.status), uint8(TransferableRecordRegistry.Status.Active));
        assertEq(r.documentHash, DOC);
        assertEq(r.metadataCommitment, META);
        assertTrue(etr.hashUsed(DOC));
    }

    function test_IssueEmitsEvent() public {
        bytes32 h = OTHER;
        vm.expectEmit(true, true, true, true);
        emit TransferableRecordRegistry.RecordIssued(uint256(h), issuer, bob, h, META);
        vm.prank(issuer);
        etr.issue(h, META, bob);
    }

    function test_SingularityNoReissue() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TransferableRecordRegistry.HashAlreadyUsed.selector, DOC));
        etr.issue(DOC, META, bob);
    }

    function test_IssueRejectsZeroHashAndHolder() public {
        vm.expectRevert(TransferableRecordRegistry.InvalidHash.selector);
        etr.issue(bytes32(0), META, bob);
        vm.expectRevert(TransferableRecordRegistry.InvalidHolder.selector);
        etr.issue(OTHER, META, address(0));
    }

    // --- exclusive control --------------------------------------------------

    function test_HolderTransfersControl() public {
        vm.prank(alice);
        etr.transferFrom(alice, bob, tokenId);
        assertEq(etr.controllerOf(tokenId), bob);
    }

    function test_NonHolderCannotTransfer() public {
        vm.prank(issuer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, issuer, tokenId)
        );
        etr.transferFrom(alice, bob, tokenId);
    }

    function test_ApprovedOperatorCanTransfer() public {
        vm.prank(alice);
        etr.approve(carol, tokenId);
        vm.prank(carol);
        etr.transferFrom(alice, bob, tokenId);
        assertEq(etr.ownerOf(tokenId), bob);
    }

    // --- amendment --------------------------------------------------------

    function test_AmendmentNeedsIssuerAndController() public {
        vm.prank(alice);
        vm.expectRevert(TransferableRecordRegistry.NotIssuer.selector);
        etr.proposeAmendment(tokenId, DOC_V2, META);

        vm.prank(issuer);
        etr.proposeAmendment(tokenId, DOC_V2, META);

        // Nothing changes before acceptance.
        assertEq(etr.getRecord(tokenId).documentHash, DOC);

        vm.prank(issuer);
        vm.expectRevert(TransferableRecordRegistry.NotController.selector);
        etr.acceptAmendment(tokenId, DOC_V2);

        vm.expectEmit(true, false, false, true);
        emit TransferableRecordRegistry.RecordAmended(tokenId, 2, DOC_V2, META);
        vm.prank(alice);
        etr.acceptAmendment(tokenId, DOC_V2);

        TransferableRecordRegistry.Record memory r = etr.getRecord(tokenId);
        assertEq(r.documentHash, DOC_V2);
        assertEq(r.version, 2);
        assertTrue(etr.hashUsed(DOC_V2));
        assertEq(etr.pendingAmendment(tokenId).documentHash, bytes32(0));
    }

    function test_AcceptRequiresMatchingHash() public {
        vm.prank(issuer);
        etr.proposeAmendment(tokenId, DOC_V2, META);
        vm.prank(alice);
        vm.expectRevert(TransferableRecordRegistry.AmendmentMismatch.selector);
        etr.acceptAmendment(tokenId, OTHER);
    }

    function test_AcceptWithoutProposalReverts() public {
        vm.prank(alice);
        vm.expectRevert(TransferableRecordRegistry.NoPendingAmendment.selector);
        etr.acceptAmendment(tokenId, DOC_V2);
    }

    function test_CancelAmendment() public {
        vm.prank(issuer);
        etr.proposeAmendment(tokenId, DOC_V2, META);
        vm.prank(issuer);
        etr.cancelAmendment(tokenId);
        vm.prank(alice);
        vm.expectRevert(TransferableRecordRegistry.NoPendingAmendment.selector);
        etr.acceptAmendment(tokenId, DOC_V2);
        vm.prank(issuer);
        vm.expectRevert(TransferableRecordRegistry.NoPendingAmendment.selector);
        etr.cancelAmendment(tokenId);
    }

    function test_AmendmentCannotReuseAnyHash() public {
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(TransferableRecordRegistry.HashAlreadyUsed.selector, DOC));
        etr.proposeAmendment(tokenId, DOC, META);

        // Proposed hash taken by another issuance before acceptance.
        vm.prank(issuer);
        etr.proposeAmendment(tokenId, DOC_V2, META);
        vm.prank(bob);
        etr.issue(DOC_V2, META, bob);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TransferableRecordRegistry.HashAlreadyUsed.selector, DOC_V2));
        etr.acceptAmendment(tokenId, DOC_V2);
    }

    function test_NewHolderAcceptsAmendmentAfterTransfer() public {
        vm.prank(issuer);
        etr.proposeAmendment(tokenId, DOC_V2, META);
        vm.prank(alice);
        etr.transferFrom(alice, bob, tokenId);
        vm.prank(alice);
        vm.expectRevert(TransferableRecordRegistry.NotController.selector);
        etr.acceptAmendment(tokenId, DOC_V2);
        vm.prank(bob);
        etr.acceptAmendment(tokenId, DOC_V2);
        assertEq(etr.getRecord(tokenId).version, 2);
    }

    // --- surrender and termination ------------------------------------------

    function test_SurrenderMovesControlToIssuerAndFreezes() public {
        vm.prank(alice);
        etr.transferFrom(alice, bob, tokenId);

        vm.prank(alice);
        vm.expectRevert(TransferableRecordRegistry.NotController.selector);
        etr.surrender(tokenId);

        vm.prank(bob);
        etr.surrender(tokenId);
        assertEq(etr.ownerOf(tokenId), issuer);
        assertEq(uint8(etr.getRecord(tokenId).status), uint8(TransferableRecordRegistry.Status.Surrendered));

        vm.prank(issuer);
        vm.expectRevert(TransferableRecordRegistry.NotActive.selector);
        etr.transferFrom(issuer, carol, tokenId);

        vm.prank(issuer);
        vm.expectRevert(TransferableRecordRegistry.NotActive.selector);
        etr.proposeAmendment(tokenId, DOC_V2, META);
    }

    function test_SurrenderClearsPendingAmendment() public {
        vm.prank(issuer);
        etr.proposeAmendment(tokenId, DOC_V2, META);
        vm.prank(alice);
        etr.surrender(tokenId);
        assertEq(etr.pendingAmendment(tokenId).documentHash, bytes32(0));
        assertFalse(etr.hashUsed(DOC_V2));
    }

    function test_SurrenderWhenIssuerAlreadyHolds() public {
        vm.prank(alice);
        etr.transferFrom(alice, issuer, tokenId);
        vm.prank(issuer);
        etr.surrender(tokenId);
        assertEq(etr.ownerOf(tokenId), issuer);
    }

    function test_TerminateOnlyAfterSurrenderAndOnlyIssuer() public {
        vm.prank(issuer);
        vm.expectRevert(TransferableRecordRegistry.NotSurrendered.selector);
        etr.terminate(tokenId, TransferableRecordRegistry.TerminationReason.Fulfilled);

        vm.prank(alice);
        etr.surrender(tokenId);

        vm.prank(alice);
        vm.expectRevert(TransferableRecordRegistry.NotIssuer.selector);
        etr.terminate(tokenId, TransferableRecordRegistry.TerminationReason.Fulfilled);

        vm.expectEmit(true, false, false, true);
        emit TransferableRecordRegistry.RecordTerminated(
            tokenId, TransferableRecordRegistry.TerminationReason.ReplacedByPaper
        );
        vm.prank(issuer);
        etr.terminate(tokenId, TransferableRecordRegistry.TerminationReason.ReplacedByPaper);

        assertEq(etr.controllerOf(tokenId), address(0));
        TransferableRecordRegistry.Record memory r = etr.getRecord(tokenId);
        assertEq(uint8(r.status), uint8(TransferableRecordRegistry.Status.Terminated));
        assertEq(r.documentHash, DOC); // kept as evidence

        // Cannot be revived or reissued.
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(TransferableRecordRegistry.HashAlreadyUsed.selector, DOC));
        etr.issue(DOC, META, alice);
        vm.prank(issuer);
        vm.expectRevert(TransferableRecordRegistry.NotSurrendered.selector);
        etr.terminate(tokenId, TransferableRecordRegistry.TerminationReason.Other);
    }

    function test_SurrenderedRecordCannotBeSurrenderedAgain() public {
        vm.prank(alice);
        etr.surrender(tokenId);
        vm.prank(issuer);
        vm.expectRevert(TransferableRecordRegistry.NotActive.selector);
        etr.surrender(tokenId);
    }

    function testFuzz_ControlFollowsTransfers(address[5] memory holders) public {
        address current = alice;
        for (uint256 i = 0; i < holders.length; i++) {
            address next = holders[i];
            vm.assume(next != address(0) && next.code.length == 0);
            vm.prank(current);
            etr.transferFrom(current, next, tokenId);
            assertEq(etr.controllerOf(tokenId), next);
            current = next;
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {HumanBond} from "../src/HumanBond.sol";
import {VowNFT} from "../src/VowNFT.sol";
import {MilestoneNFT} from "../src/MilestoneNFT.sol";
import {TimeToken} from "../src/TimeToken.sol";
import {MarriageIdHelper} from "./utils/MarriageHelper.sol";
import {MockWorldID} from "./utils/MockWorldId.sol";
import {DeployScript} from "../script/Deploy.s.sol";

contract AutomationFlowTest is Test {
    VowNFT vowNft;
    MilestoneNFT milestoneNft;
    TimeToken timeToken;
    MockWorldID worldId;
    HumanBond humanBond;
    DeployScript deployer;

    address leticia = makeAddr("leticia");
    address bob = makeAddr("bob");

    // Mock World ID parameters
    uint256 constant ROOT = 1;
    uint256 constant NULLIFIER_PROPOSE = 1111;
    uint256 constant NULLIFIER_ACCEPT = 2222;
    uint256[8] proof = [uint256(0), 0, 0, 0, 0, 0, 0, 0];

    function setUp() public {
        // Deploy mock WorldID
        worldId = new MockWorldID();

        // Deploy the other contracts
        vowNft = new VowNFT();
        milestoneNft = new MilestoneNFT();
        timeToken = new TimeToken();

        // Setup milestone years (same as deploy script)
        milestoneNft.setMilestoneURI(1, "ipfs://dummy1");
        milestoneNft.setMilestoneURI(2, "ipfs://dummy2");
        milestoneNft.setMilestoneURI(3, "ipfs://dummy3");
        milestoneNft.setMilestoneURI(4, "ipfs://dummy4");
        milestoneNft.freezeMilestones();

        // Deploy HumanBond using the mock
        humanBond = new HumanBond(
            address(worldId),
            address(vowNft),
            address(timeToken),
            address(milestoneNft),
            "app_test",
            "propose-bond",
            "accept-bond",
            1 minutes,
            3 minutes,
            5 minutes
        );

        // Wire up
        milestoneNft.setHumanBondContract(address(humanBond));
        vowNft.setHumanBondContract(address(humanBond));
        timeToken.setHumanBondContract(address(humanBond));

        // Give ETH
        vm.deal(leticia, 10 ether);
        vm.deal(bob, 10 ether);

        // Push block.timestamp past DIVORCE_COOLDOWN so fresh users (lastDivorceTimestamp=0)
        // don't hit HumanBond__CooldownActive. Foundry starts at timestamp=1 which is < cooldown.
        vm.warp(humanBond.DIVORCE_COOLDOWN() + 1);
    }

    //============================ MODIFIERS ============================//

    modifier marriedCouple() {
        vm.startPrank(leticia);
        humanBond.propose(bob, ROOT, NULLIFIER_PROPOSE, proof);
        vm.stopPrank();

        vm.startPrank(bob);
        humanBond.accept(leticia, ROOT, NULLIFIER_ACCEPT, proof);
        vm.stopPrank();
        _;
    }

    modifier proposalSent() {
        vm.prank(leticia);
        humanBond.propose(bob, ROOT, NULLIFIER_PROPOSE, proof);
        _;
    }

    //test_<unitUnderTest>_<stateOrCondition>_<expectedOutcome/Behaviour>

    //============================ PROPOSAL & ACCEPTANCE TESTS ============================//
    //=====================================================================================//

    function test_propose_reverts_ifCooldownActive() public marriedCouple {
        // Leticia divorces Bob to trigger cooldown
        vm.prank(leticia);
        humanBond.divorce(bob);

        // Attempt to propose during cooldown
        vm.prank(leticia);
        vm.expectRevert(HumanBond.HumanBond__CooldownActive.selector);
        humanBond.propose(address(0x03), ROOT, NULLIFIER_PROPOSE, proof);
    }

    function test_propose_reverts_whenProposeToYourself() public {
        vm.prank(leticia);
        vm.expectRevert(HumanBond.HumanBond__CannotProposeToSelf.selector);
        humanBond.propose(leticia, ROOT, NULLIFIER_PROPOSE, proof);
    }

    function test_propose_reverts_ifProposeToInvalidAddress() public {
        vm.prank(leticia);
        vm.expectRevert(HumanBond.HumanBond__InvalidAddress.selector);
        humanBond.propose(address(0), ROOT, NULLIFIER_PROPOSE, proof);
    }

    function test_propose_reverts_ifAlreadyHasProposalOpen() public proposalSent {
        vm.prank(leticia);
        vm.expectRevert(HumanBond.HumanBond__ProposalAlreadyExists.selector);
        humanBond.propose(address(0x01), NULLIFIER_PROPOSE + 1, 111, proof);
    }

    function test_propose_reverts_ifAlreadyMarried() public marriedCouple {
        vm.startPrank(leticia);
        vm.expectRevert(HumanBond.HumanBond__UserAlreadyMarried.selector);
        humanBond.propose(address(0x01), NULLIFIER_PROPOSE + 1, 111, proof);

        vm.startPrank(bob);
        vm.expectRevert(HumanBond.HumanBond__UserAlreadyMarried.selector);
        humanBond.propose(address(0x02), NULLIFIER_PROPOSE + 2, 111, proof);
    }

    // function test_propose_reverts_ifUsingSameNullifier() public proposalSent {
    //     vm.prank(leticia);
    //     humanBond.cancelProposal();
    //     bool usedNullfier = humanBond.usedNullifier(humanBond.externalNullifierPropose(), NULLIFIER_PROPOSE);
    //     assertEq(usedNullfier, true);

    //     vm.expectRevert(HumanBond.HumanBond__InvalidNullifier.selector);
    //     humanBond.propose(address(0x01), ROOT, NULLIFIER_PROPOSE, proof);
    // }

    function test_propose_works_afterDivorce() public marriedCouple {
        vm.startPrank(leticia);
        humanBond.divorce(bob);
        vm.stopPrank();

        // Wait out the divorce cooldown before remarrying
        skip(humanBond.DIVORCE_COOLDOWN() + 1);

        vm.startPrank(leticia);
        humanBond.propose(bob, ROOT, NULLIFIER_PROPOSE, proof);
        vm.stopPrank();

        vm.prank(bob);
        humanBond.accept(leticia, ROOT, NULLIFIER_ACCEPT, proof);
    }

    function test_propose_sucessfully_storeProposal() public proposalSent {
        uint256 timeStamp = block.timestamp;
        HumanBond.Proposal memory letisProposal = humanBond.getProposal(leticia);
        assertEq(letisProposal.proposer, leticia);
        assertEq(letisProposal.proposed, bob);
        assertEq(letisProposal.proposerNullifier, NULLIFIER_PROPOSE);
        assertEq(letisProposal.accepted, false);
        assertEq(letisProposal.timestamp, timeStamp);
    }

    function test_propose_emits_ProposalCreated() public {
        // Expect ProposalCreated
        vm.expectEmit(address(humanBond));
        emit HumanBond.ProposalCreated(leticia, bob);

        vm.prank(leticia);
        humanBond.propose(bob, ROOT, NULLIFIER_PROPOSE, proof);
    }

    //============================ ACCEPTANCE TESTS =======================================//
    //=====================================================================================//

    function test_accept_reverts_ifNotCorrectPartnerAccept() public proposalSent {
        vm.expectRevert(HumanBond.HumanBond__NotProposedToYou.selector);
        humanBond.accept(leticia, ROOT, NULLIFIER_ACCEPT, proof);
    }

    function test_accept_reverts_ifCooldownActive() public marriedCouple {
        // Leticia divorces Bob to trigger cooldown
        vm.prank(leticia);
        humanBond.divorce(bob);

        // Attempt to accept during cooldown
        vm.startPrank(address(0x04));
        humanBond.propose(bob, ROOT, NULLIFIER_PROPOSE + 1, proof);
        vm.stopPrank();

        vm.prank(leticia);
        vm.expectRevert(HumanBond.HumanBond__CooldownActive.selector);
        humanBond.accept(address(0x04), ROOT, NULLIFIER_ACCEPT, proof);
    }

    // function test_accept_reverts_ifNullifierAlreadyUsed() public marriedCouple {
    //     // recreates a new proposal because accept() deletes it
    //     vm.prank(leticia);
    //     humanBond.propose(bob, ROOT, 1002, proof);

    //     // bob tries to accept using SAME nullifier 2001 → should revert
    //     vm.prank(bob);
    //     vm.expectRevert(HumanBond.HumanBond__InvalidNullifier.selector);
    //     humanBond.accept(leticia, ROOT, NULLIFIER_ACCEPT, proof);
    // }

    function test_accept_getMarriageId_recordsMarriageIdSymmetryAndPushToArray() public marriedCouple {
        MarriageIdHelper helper = new MarriageIdHelper();

        bytes32 id1 = helper.exposedGetMarriageId(leticia, bob);
        bytes32 id2 = helper.exposedGetMarriageId(bob, leticia);
        bytes32 recordedMarriage = humanBond.marriageIds(0);

        assertEq(id1, id2, "Marriage IDs should be symmetric");
        assertEq(recordedMarriage, id1);
    }

    function test_accept_changeAcceptToTrue() public marriedCouple {
        bool currentStatus = humanBond.isMarried(leticia, bob);

        assertEq(currentStatus, true);
    }

    function test_accept_deletes_allPreviousProposals() public proposalSent {
        vm.startPrank(bob);
        humanBond.propose(address(0x01), ROOT, NULLIFIER_PROPOSE + 1, proof);
        humanBond.accept(leticia, ROOT, NULLIFIER_ACCEPT, proof);
        vm.stopPrank();
        HumanBond.Proposal memory bobsProposal = humanBond.getProposal(bob);
        assertEq(bobsProposal.proposer, address(0));
        assertEq(bobsProposal.proposed, address(0));
    }

    function test_accept_clearsIncomingProposalCorrectly() public {
        vm.prank(leticia);
        humanBond.propose(bob, ROOT, NULLIFIER_PROPOSE, proof);

        vm.prank(bob);
        humanBond.accept(leticia, ROOT, NULLIFIER_ACCEPT, proof);

        HumanBond.Proposal[] memory incoming = humanBond.getIncomingProposals(bob);
        assertEq(incoming.length, 0);

        HumanBond.Proposal memory p = humanBond.getProposal(leticia);
        assertEq(p.proposer, address(0));
    }

    function test_accpet_MintsVowNFTandSendTokens() public marriedCouple {
        assertEq(vowNft.ownerOf(1), leticia);
        assertEq(vowNft.ownerOf(2), bob);
        assertEq(timeToken.balanceOf(leticia), 1 ether);
        assertEq(timeToken.balanceOf(bob), 1 ether);
    }

    //======================================= YIELD TESTS ===============================//
    //===================================================================================//

    function test_pendingYield_returnsZeroWhenMarriageInactive() public marriedCouple {
        // Kill marriage
        vm.prank(leticia);
        humanBond.divorce(bob);

        uint256 pending = humanBond.getPendingYield(leticia, bob);
        assertEq(pending, 0);
    }

    function test_pendingYield_recordsBalanceCorrectly() public marriedCouple {
        // warp minutes (100 TIME)
        skip(100 minutes);
        uint256 expectedBalance = humanBond.getPendingYield(leticia, bob);
        assertEq(expectedBalance, 100 ether);
    }

    function test_claimYield_reverts_ifNoYield() public marriedCouple {
        vm.prank(leticia);
        vm.expectRevert(HumanBond.HumanBond__NothingToClaim.selector);
        humanBond.claimYield(bob);
    }

    function test_claimYield_reverts_ifMarriageInactive() public {
        vm.prank(leticia);
        vm.expectRevert(HumanBond.HumanBond__NoActiveMarriage.selector);
        humanBond.claimYield(bob);
    }

    function test_claimYield_splitsTokensEvenlyAndResetsCounter() public marriedCouple {
        skip(10 minutes);

        vm.prank(leticia);
        humanBond.claimYield(bob);

        // both receive 5 TIME token + 1 initial mint
        assertEq(timeToken.balanceOf(leticia), 1 ether + 5 ether);
        assertEq(timeToken.balanceOf(bob), 1 ether + 5 ether);

        // pending yield resets to 0
        uint256 pendingAfterClaim = humanBond.getPendingYield(leticia, bob);
        assertEq(pendingAfterClaim, 0);
    }

    //==================================  MILESTONES NFTS ===============================//
    //===================================================================================//
    function test_manualCheckAndMint_reverts_ifNoActiveMarriage() public {
        // Leticia is NOT married
        vm.prank(leticia);
        vm.expectRevert(HumanBond.HumanBond__NoActiveMarriage.selector);
        humanBond.manualCheckAndMint(bob);
    }

    function test_manualCheckAndMint_reverts_ifYearNotReached() public marriedCouple {
        // marriage just started
        vm.prank(leticia);
        vm.expectRevert(HumanBond.HumanBond__NothingToClaim.selector);
        humanBond.manualCheckAndMint(bob);
    }

    function test_manualCheckAndMint_reverts_ifYearExceedsMax() public marriedCouple {
        uint256 max = milestoneNft.latestYear();

        // warp to year = 5
        skip((max + 1));

        vm.prank(leticia);
        vm.expectRevert(HumanBond.HumanBond__NothingToClaim.selector);
        humanBond.manualCheckAndMint(bob);
    }

    function test_manualCheckAndMint_mintsWhenYearReached() public marriedCouple {
        // warp just over 1 year (YEAR = 3 minutes)
        skip(3 minutes + 1);

        vm.prank(leticia);
        humanBond.manualCheckAndMint(bob);

        // tokenId 0 and 1 minted (soulbound)
        assertEq(milestoneNft.ownerOf(1), leticia);
        assertEq(milestoneNft.ownerOf(2), bob);

        uint256 currentYear = humanBond.getCurrentMilestoneYear(leticia, bob);
        assertEq(currentYear, 1);
    }

    function test_manualCheckAndMint_reverts_ifAlreadyMintedForYear() public marriedCouple {
        // reach year = 1
        skip(3 minutes + 1);

        vm.prank(leticia);
        humanBond.manualCheckAndMint(bob);

        // attempt again
        vm.prank(leticia);
        vm.expectRevert(HumanBond.HumanBond__NothingToClaim.selector);
        humanBond.manualCheckAndMint(bob);
    }

    function test_manualCheckAndMint_mintsMultipleYears() public marriedCouple {
        // skip 3 years → YEAR = 3 minutes
        skip(3 * 3 minutes + 1);

        vm.prank(leticia);
        humanBond.manualCheckAndMint(bob);

        // EXPECT minted years 1, 2, 3 for both
        assertEq(milestoneNft.ownerOf(1), leticia);
        assertEq(milestoneNft.ownerOf(2), bob);

        assertEq(milestoneNft.ownerOf(3), leticia);
        assertEq(milestoneNft.ownerOf(4), bob);

        assertEq(milestoneNft.ownerOf(5), leticia);
        assertEq(milestoneNft.ownerOf(6), bob);

        // state updated to latest year
        uint256 currentYear = humanBond.getCurrentMilestoneYear(leticia, bob);
        assertEq(currentYear, 3);
    }

    function test_manualCheckAndMint_capsToLatestYear() public marriedCouple {
        uint256 max = milestoneNft.latestYear(); // suppose = 4

        // warp far beyond the max (simulate 10 years)
        skip(10 * 3 minutes + 1);

        vm.prank(leticia);
        humanBond.manualCheckAndMint(bob);

        // should only mint up to max year
        assertEq(humanBond.getCurrentMilestoneYear(leticia, bob), max);

        // verify token existence
        assertEq(milestoneNft.ownerOf(1), leticia);
        assertEq(milestoneNft.ownerOf(2), bob);

        assertEq(milestoneNft.ownerOf(3), leticia);
        assertEq(milestoneNft.ownerOf(4), bob);

        assertEq(milestoneNft.ownerOf(5), leticia);
        assertEq(milestoneNft.ownerOf(6), bob);

        assertEq(milestoneNft.ownerOf(7), leticia);
        assertEq(milestoneNft.ownerOf(8), bob);

        // should NOT mint year 3 or beyond
        vm.expectRevert();
        milestoneNft.ownerOf(9);
    }

    function test_manualCheckAndMint_updatesStateCorrectly() public marriedCouple {
        // warp 2 years
        skip(2 * 3 minutes + 1);

        vm.prank(leticia);
        humanBond.manualCheckAndMint(bob);

        // state should reflect latest year minted
        assertEq(humanBond.getCurrentMilestoneYear(leticia, bob), 2);

        // calling again should revert
        vm.prank(leticia);
        vm.expectRevert(HumanBond.HumanBond__NothingToClaim.selector);
        humanBond.manualCheckAndMint(bob);
    }

    function test_manualCheckAndMint_partialYears() public marriedCouple {
        // Only milestone up to 4 years exists
        assertEq(milestoneNft.latestYear(), 4);

        // skip 5 years
        skip(5 * 3 minutes + 1);

        vm.prank(leticia);
        humanBond.manualCheckAndMint(bob);

        // should mint up to 4 years only
        assertEq(humanBond.getCurrentMilestoneYear(leticia, bob), 4);

        // year 3 should NOT exist
        vm.expectRevert();
        milestoneNft.ownerOf(9);
    }

    function test_manualCheckAndMint_emitsEventsForAllYears() public marriedCouple {
        skip(2 * 3 minutes + 1);

        vm.startPrank(leticia);
        vm.recordLogs();
        humanBond.manualCheckAndMint(bob);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        vm.stopPrank();

        // should emit 2 AnniversaryAchieved events (one per year)
        uint256 count;
        for (uint256 i; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("AnniversaryAchieved(address,address,uint256,uint256)")) {
                count++;
            }
        }
        assertEq(count, 2);
    }

    //==================================  DIVORCE TESTS ===============================//
    //=================================================================================//

    function test_divorce_reverts_ifNotActiveMarriage() public {
        vm.prank(leticia);
        vm.expectRevert(HumanBond.HumanBond__NoActiveMarriage.selector);
        humanBond.divorce(bob);
    }

    function test_divorce_reverts_ifNotYourMarriage() public marriedCouple {
        // attacker tries to divorce them
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert(HumanBond.HumanBond__NoActiveMarriage.selector);
        humanBond.divorce(leticia);
    }

    function test_divorce_claimsPendingYieldAndSplitsEvenly() public marriedCouple {
        // simulate 20 minutes (20 TIME)
        skip(20 minutes);

        uint256 expectedSplit = (20 ether) / 2;

        vm.prank(leticia);
        humanBond.divorce(bob);

        // each receives initial 1 + 10
        assertEq(timeToken.balanceOf(leticia), 1 ether + expectedSplit);
        assertEq(timeToken.balanceOf(bob), 1 ether + expectedSplit);

        // marriage should now be inactive
        bool active = humanBond.isMarried(leticia, bob);
        assertEq(active, false);
    }

    function test_divorce_resetsActiveMarriageMapping() public marriedCouple {
        vm.prank(leticia);
        humanBond.divorce(bob);

        assertEq(humanBond.activeMarriageOf(leticia), bytes32(0));
        assertEq(humanBond.activeMarriageOf(bob), bytes32(0));
    }

    //============================ PROPOSAL TESTS =======================================//
    //===================================================================================//

    function test_cancelProposal_reverts_ifNoProposal() public {
        vm.prank(leticia);
        vm.expectRevert(HumanBond.HumanBond__InvalidAddress.selector);
        humanBond.cancelProposal();
    }

    function test_cancelProposal_clearsProposalCorrectly() public proposalSent {
        vm.prank(leticia);
        humanBond.cancelProposal();

        HumanBond.Proposal memory p = humanBond.getProposal(leticia);
        assertEq(p.proposer, address(0));
        assertEq(p.proposed, address(0));
    }

    function test_addProposal_tracksIncomingCorrectly() public {
        // Leticia proposes to Bob
        vm.prank(leticia);
        humanBond.propose(bob, ROOT, NULLIFIER_PROPOSE, proof);

        // Check via the getter
        HumanBond.Proposal[] memory incoming = humanBond.getIncomingProposals(bob);

        assertEq(incoming.length, 1);
        assertEq(incoming[0].proposer, leticia);
        assertEq(incoming[0].proposed, bob);

        // Check that index mapping was set
        assertEq(humanBond.proposerIndex(leticia), 0);
    }

    function test_addProposal_multipleIncoming() public {
        address alice = makeAddr("alice");

        vm.prank(leticia);
        humanBond.propose(bob, ROOT, 9001, proof);

        vm.prank(alice);
        humanBond.propose(bob, ROOT, 9002, proof);

        HumanBond.Proposal[] memory incoming = humanBond.getIncomingProposals(bob);

        assertEq(incoming.length, 2);

        // check proposers (order not guaranteed but initial mapping preserves push order)
        assertEq(incoming[0].proposer, leticia);
        assertEq(incoming[1].proposer, alice);
    }

    function test_getIncomingProposals_returnsCorrectStructures() public {
        vm.prank(leticia);
        humanBond.propose(bob, ROOT, NULLIFIER_PROPOSE, proof);

        HumanBond.Proposal[] memory incoming = humanBond.getIncomingProposals(bob);

        assertEq(incoming.length, 1);
        assertEq(incoming[0].proposer, leticia);
        assertEq(incoming[0].proposed, bob);
        assertEq(incoming[0].proposerNullifier, NULLIFIER_PROPOSE);
        assertEq(incoming[0].accepted, false);
    }

    function test_removeProposal_removesCorrectly_singleEntry() public {
        vm.prank(leticia);
        humanBond.propose(bob, ROOT, NULLIFIER_PROPOSE, proof);

        vm.prank(leticia);
        humanBond.cancelProposal();

        HumanBond.Proposal[] memory incoming = humanBond.getIncomingProposals(bob);
        assertEq(incoming.length, 0);

        // proposal struct cleared
        HumanBond.Proposal memory p = humanBond.getProposal(leticia);
        assertEq(p.proposer, address(0));
    }

    function test_removeProposal_swapsCorrectly_whenMiddleElement() public {
        address alice = makeAddr("alice");
        address carol = makeAddr("carol");

        vm.prank(leticia);
        humanBond.propose(bob, ROOT, 9001, proof);

        vm.prank(alice);
        humanBond.propose(bob, ROOT, 9002, proof);

        vm.prank(carol);
        humanBond.propose(bob, ROOT, 9003, proof);

        // Alice cancels (middle element)
        vm.prank(alice);
        humanBond.cancelProposal();

        HumanBond.Proposal[] memory incoming = humanBond.getIncomingProposals(bob);

        assertEq(incoming.length, 2);

        // ensure Alice is removed
        for (uint256 i = 0; i < incoming.length; i++) {
            assert(incoming[i].proposer != alice);
        }
    }

    //============================ REJECT PROPOSAL TESTS ================================//
    //===================================================================================//

    function test_rejectProposal_reverts_ifNotProposedToYou() public proposalSent {
        // Carol tries to reject a proposal not directed to her
        address carol = makeAddr("carol");
        vm.prank(carol);
        vm.expectRevert(HumanBond.HumanBond__NotProposedToYou.selector);
        humanBond.rejectProposal(leticia);
    }

    function test_rejectProposal_reverts_ifProposalDoesNotExist() public {
        // Bob tries to reject a proposal from leticia that was never made
        vm.prank(bob);
        vm.expectRevert(HumanBond.HumanBond__NotProposedToYou.selector);
        humanBond.rejectProposal(leticia);
    }

    function test_rejectProposal_clearsProposalStruct() public proposalSent {
        vm.prank(bob);
        humanBond.rejectProposal(leticia);

        HumanBond.Proposal memory p = humanBond.getProposal(leticia);
        assertEq(p.proposer, address(0));
        assertEq(p.proposed, address(0));
    }

    function test_rejectProposal_removesFromIncomingProposals() public proposalSent {
        vm.prank(bob);
        humanBond.rejectProposal(leticia);

        HumanBond.Proposal[] memory incoming = humanBond.getIncomingProposals(bob);
        assertEq(incoming.length, 0);
    }

    function test_rejectProposal_emits_ProposalCancelled() public proposalSent {
        vm.expectEmit(address(humanBond));
        emit HumanBond.ProposalCancelled(leticia, bob);

        vm.prank(bob);
        humanBond.rejectProposal(leticia);
    }

    function test_rejectProposal_allowsProposerToReproposeAfterRejection() public proposalSent {
        vm.prank(bob);
        humanBond.rejectProposal(leticia);

        // Leticia should be able to propose again (no ProposalAlreadyExists revert)
        vm.prank(leticia);
        humanBond.propose(bob, ROOT, NULLIFIER_PROPOSE, proof);

        HumanBond.Proposal memory p = humanBond.getProposal(leticia);
        assertEq(p.proposer, leticia);
        assertEq(p.proposed, bob);
    }

    function test_rejectProposal_removesCorrectProposal_fromMultipleIncoming() public {
        address alice = makeAddr("alice");

        vm.prank(leticia);
        humanBond.propose(bob, ROOT, 9001, proof);

        vm.prank(alice);
        humanBond.propose(bob, ROOT, 9002, proof);

        // Bob rejects only leticia's proposal
        vm.prank(bob);
        humanBond.rejectProposal(leticia);

        HumanBond.Proposal[] memory incoming = humanBond.getIncomingProposals(bob);
        assertEq(incoming.length, 1);
        assertEq(incoming[0].proposer, alice);
    }

    //================================ GETTERS TESTS ==================================//
    //=================================================================================//
    function test_getMarriageView_returnsCorrectData() public marriedCouple {
        HumanBond.MarriageView memory v = humanBond.getMarriageView(leticia, bob);

        assertEq(v.partnerA, leticia);
        assertEq(v.partnerB, bob);
        assertEq(v.active, true);
        assertEq(v.lastMilestoneYear, 0);
        assertEq(v.pendingYield, 0); // just married
        assertEq(v.marriageId, humanBond.activeMarriageOf(leticia));
    }

    function test_getCurrentMilestoneYear_returnsCorrectYear() public marriedCouple {
        skip(6 minutes + 1); // warp to year = 2

        vm.prank(leticia);
        humanBond.manualCheckAndMint(bob);

        uint256 year = humanBond.getCurrentMilestoneYear(leticia, bob);
        assertEq(year, 2);
    }

    function test_getPendingYield_returnsCorrectValue() public marriedCouple {
        // Elapsed = 10 minutes → 10 ether (because DAY = 1 minute in test)
        skip(10 minutes);

        uint256 pending = humanBond.getPendingYield(leticia, bob);
        assertEq(pending, 10 ether);
    }

    function test_getBondStart_returnsCorrectTimestamp() public marriedCouple {
        HumanBond.Marriage memory m = humanBond.getMarriage(leticia, bob);
        uint256 stored = humanBond.getBondStart(leticia, bob);

        assertEq(stored, m.bondStart);
        assertTrue(stored > 0);
    }

    function test_getProposal_returnsCorrectData() public {
        vm.prank(leticia);
        humanBond.propose(bob, ROOT, NULLIFIER_PROPOSE, proof);

        HumanBond.Proposal memory p = humanBond.getProposal(leticia);

        assertEq(p.proposer, leticia);
        assertEq(p.proposed, bob);
        assertEq(p.accepted, false);
        assertEq(p.proposerNullifier, NULLIFIER_PROPOSE);
    }

    function test_getUserDashboard_unmarriedUser() public view {
        HumanBond.UserDashboard memory d = humanBond.getUserDashboard(leticia);

        assertEq(d.isMarried, false);
        assertEq(d.partner, address(0));
        assertEq(d.pendingYield, 0);
    }

    function test_getUserDashboard_marriedUser() public marriedCouple {
        // warp 5 minutes to accumulate yield
        skip(5 minutes);

        HumanBond.UserDashboard memory d = humanBond.getUserDashboard(leticia);

        assertEq(d.isMarried, true);
        assertEq(d.partner, bob);
        assertEq(d.pendingYield, 5 ether);
    }

    //============================== PROTOCOL COUNTERS ==================================//
    //===================================================================================//

    function test_activeMarriageCount_incrementsOnAccept() public marriedCouple {
        assertEq(humanBond.activeMarriageCount(), 1);
    }

    function test_activeMarriageCount_decrementsOnDivorce() public marriedCouple {
        vm.prank(leticia);
        humanBond.divorce(bob);

        assertEq(humanBond.activeMarriageCount(), 0);
    }

    function test_activeMarriageCount_multipleCouplces() public {
        address alice = makeAddr("alice");
        address carol = makeAddr("carol");

        // Couple 1: leticia + bob
        vm.prank(leticia);
        humanBond.propose(bob, ROOT, 1001, proof);
        vm.prank(bob);
        humanBond.accept(leticia, ROOT, 1002, proof);

        // Couple 2: alice + carol
        vm.prank(alice);
        humanBond.propose(carol, ROOT, 2001, proof);
        vm.prank(carol);
        humanBond.accept(alice, ROOT, 2002, proof);

        assertEq(humanBond.activeMarriageCount(), 2);

        // One divorce → count drops to 1
        vm.prank(alice);
        humanBond.divorce(carol);

        assertEq(humanBond.activeMarriageCount(), 1);
    }

    function test_totalDivorceCount_incrementsOnDivorce() public marriedCouple {
        assertEq(humanBond.totalDivorceCount(), 0);

        vm.prank(leticia);
        humanBond.divorce(bob);

        assertEq(humanBond.totalDivorceCount(), 1);
    }

    function test_totalDivorceCount_doesNotDecrementOnRemarry() public marriedCouple {
        vm.prank(leticia);
        humanBond.divorce(bob);

        // Wait out cooldown and remarry
        skip(humanBond.DIVORCE_COOLDOWN() + 1);

        vm.prank(leticia);
        humanBond.propose(bob, ROOT, NULLIFIER_PROPOSE, proof);
        vm.prank(bob);
        humanBond.accept(leticia, ROOT, NULLIFIER_ACCEPT, proof);

        // Divorce count stays at 1; marriage count is back to 1
        assertEq(humanBond.totalDivorceCount(), 1);
        assertEq(humanBond.activeMarriageCount(), 1);
    }

    function test_counters_accumulateAcrossMultipleDivorces() public {
        address alice = makeAddr("alice");
        address carol = makeAddr("carol");

        address[3] memory proposers = [leticia, alice, carol];
        address[3] memory acceptors = [bob, makeAddr("dave"), makeAddr("eve")];
        uint256 nullBase = 3000;

        // Marry 3 couples
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(proposers[i]);
            humanBond.propose(acceptors[i], ROOT, nullBase + i * 2, proof);
            vm.prank(acceptors[i]);
            humanBond.accept(proposers[i], ROOT, nullBase + i * 2 + 1, proof);
        }

        assertEq(humanBond.activeMarriageCount(), 3);
        assertEq(humanBond.totalDivorceCount(), 0);

        // Divorce all 3
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(proposers[i]);
            humanBond.divorce(acceptors[i]);
        }

        assertEq(humanBond.activeMarriageCount(), 0);
        assertEq(humanBond.totalDivorceCount(), 3);
    }

    //====================================TIME TOKEN ====================================//
    //===================================================================================//
    function test_timetoken_onlyOwnerAndContractCanMint() public {
        timeToken.mint(leticia, 10 ether); // owner mint
        assertEq(timeToken.balanceOf(leticia), 10 ether);

        vm.prank(address(humanBond));
        timeToken.mint(bob, 5 ether); // humanBond mint
        assertEq(timeToken.balanceOf(bob), 5 ether);

        vm.prank(address(0x999));
        vm.expectRevert(TimeToken.NotAuthorized.selector);
        timeToken.mint(bob, 1 ether); // unauthorized mint
    }
}

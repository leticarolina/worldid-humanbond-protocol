// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {BondNFT} from "./BondNFT.sol";
import {TimeToken} from "./TimeToken.sol";
import {MilestoneNFT} from "./MilestoneNFT.sol";
import {ByteHasher} from "./helpers/ByteHasher.sol";
import {IWorldID} from "./helpers/IWorldID.sol";

/**
 * @title HumanBond
 * @author Leticia Azevedo (@letiweb3)
 * @notice Main contract managing bonds between World ID users.
 *  @dev Uses World ID verification to confirm both users are real humans,
 *      then mints dynamic metadata NFTs and TIME ERC-20 tokens for a verified bond.
 */
contract HumanBond is Ownable {
    using ByteHasher for bytes;

    error HumanBond__UserAlreadyBonded();
    error HumanBond__InvalidAddress();
    error HumanBond__ProposalAlreadyExists();
    error HumanBond__NotYourBond();
    error HumanBond__NoActiveBond();
    error HumanBond__CannotProposeToSelf();
    error HumanBond__NotProposedToYou();
    error HumanBond__NothingToClaim();
    error HumanBond__CooldownActive();
    error HumanBond__DissolutionAlreadyRequested();
    error HumanBond__NoDissolutionRequest();
    error HumanBond__DissolutionDelayNotMet();

    /* ----------------------------- STRUCTS ----------------------------- */
    //Represents a pending bond request:
    struct Proposal {
        address proposer;
        address proposed;
        uint256 proposerNullifier;
        bool accepted;
        uint256 timestamp;
    }

    //Represents an active partnership bond between two verified humans
    struct Bond {
        address partnerA;
        address partnerB;
        uint256 nullifierA; //represent human identities from World ID
        uint256 nullifierB;
        uint256 bondStart;
        uint256 lastClaim;
        uint256 lastMilestoneYear;
        bool active;
    }

    struct DissolutionRequest {
        address requester;
        uint256 requestedAt;
        bool active;
    }

    // View struct for external read-only access
    struct BondView {
        address partnerA;
        address partnerB;
        uint256 nullifierA;
        uint256 nullifierB;
        uint256 bondStart;
        uint256 lastClaim;
        uint256 lastMilestoneYear;
        bool active;
        uint256 pendingYield;
        bytes32 bondId;
    }

    // View struct for user dashboard
    struct UserDashboard {
        bool isBonded;
        bool hasProposal;
        address partner;
        uint256 pendingYield;
        uint256 timeBalance;
    }

    /* --------------------------- STATE VARS --------------------------- */
    mapping(address => Proposal) public proposals;
    mapping(address => address[]) public proposalsFor; // proposed address => array of proposers
    mapping(address => uint256) public proposerIndex; // proposer address => index in proposalsFor[proposed]
    mapping(bytes32 => Bond) public bonds;
    mapping(address => bytes32) public activeBondOf; // quick lookup of active bond ID by user address
    mapping(address => uint256) public lastDissolutionTimestamp;
    mapping(bytes32 => DissolutionRequest) public dissolutionRequests;

    bytes32[] public bondIds; //So every couple has a unique “bond fingerprint”

    IWorldID public immutable WORLD_ID;
    BondNFT public immutable BOND_NFT;
    TimeToken public immutable TIME_TOKEN;
    MilestoneNFT public immutable MILESTONE_NFT;
    uint256 public immutable EXTERNAL_NULLIFIER_PROPOSE;
    uint256 public immutable EXTERNAL_NULLIFIER_ACCEPT;
    uint256 public immutable DAY; // 1 day = 1 TIME token reward shared
    uint256 public immutable YEAR; // 1 YEAR = new milestone NFT eligibility
    uint256 public immutable REBOND_COOLDOWN; // time after dissolution during which a user cannot propose or accept new bonds
    uint256 public constant GROUP_ID = 1; // World ID Orb-only group. Required by World ID Route
    uint256 public dissolutionDelay = 3 days; // delay for dissolution to be finalized

    uint256 public activeBondCount;
    uint256 public totalDissolutionCount;

    /* ----------------------------- EVENTS ----------------------------- */
    event ProposalCreated(address indexed proposer, address indexed proposed, uint256 timestamp);
    event ProposalAccepted(address indexed partnerA, address indexed partnerB, uint256 timestamp);
    event YieldClaimed(address indexed partnerA, address indexed partnerB, uint256 rewardEach);
    event AnniversaryAchieved(address indexed partnerA, address indexed partnerB, uint256 year, uint256 timestamp);
    event BondDissolved(address indexed partnerA, address indexed partnerB, uint256 timestamp);
    event ProposalCancelled(address indexed proposer, address indexed proposed, uint256 timestamp);
    event ProposalRejected(address indexed proposer, address indexed proposed, uint256 timestamp);
    event DissolutionRequested(
        address indexed partnerA, address indexed partnerB, address indexed requester, uint256 timestamp
    );
    event DissolutionRequestCancelled(address indexed partnerA, address indexed partnerB, uint256 timestamp);

    /* --------------------------- CONSTRUCTOR -------------------------- */
    constructor(
        address _worldIdRouter,
        address _bondNft,
        address _timeToken,
        address _milestoneNft,
        string memory _appId,
        string memory _actionPropose,
        string memory _actionAccept,
        uint256 _day,
        uint256 _year,
        uint256 _dissolutionCooldown
    ) Ownable(msg.sender) {
        WORLD_ID = IWorldID(_worldIdRouter);
        BOND_NFT = BondNFT(_bondNft);
        TIME_TOKEN = TimeToken(_timeToken);
        MILESTONE_NFT = MilestoneNFT(_milestoneNft);

        // Compute external nullifiers exactly as World ID expects, define action domain for proofs
        EXTERNAL_NULLIFIER_PROPOSE =
            abi.encodePacked(abi.encodePacked(_appId).hashToField(), _actionPropose).hashToField();

        EXTERNAL_NULLIFIER_ACCEPT =
            abi.encodePacked(abi.encodePacked(_appId).hashToField(), _actionAccept).hashToField();
        DAY = _day;
        YEAR = _year;
        REBOND_COOLDOWN = _dissolutionCooldown;
    }

    /* ---------------------------- FUNCTIONS --------------------------- */

    /// @notice Propose a bond to another verified human using World ID.
    /// @param proposed The address of the person being proposed to.
    /// @param root The World ID root from the proof.
    /// @param proposerNullifier The unique nullifier preventing proof re-use.
    /// @param proof The zero-knowledge proof array.
    function propose(address proposed, uint256 root, uint256 proposerNullifier, uint256[8] calldata proof) external {
        if (block.timestamp - lastDissolutionTimestamp[msg.sender] < REBOND_COOLDOWN) {
            revert HumanBond__CooldownActive();
        }
        if (proposed == address(0)) {
            revert HumanBond__InvalidAddress();
        }
        if (proposed == msg.sender) {
            revert HumanBond__CannotProposeToSelf();
        }
        if (proposals[msg.sender].proposer != address(0)) {
            revert HumanBond__ProposalAlreadyExists();
        }
        if (activeBondOf[msg.sender] != bytes32(0) || activeBondOf[proposed] != bytes32(0)) {
            revert HumanBond__UserAlreadyBonded();
        }
        uint256 signalHash = abi.encodePacked(msg.sender).hashToField(); //prove msg.sender is signer
        // Verify proposer is a real human via World ID
        WORLD_ID.verifyProof(root, GROUP_ID, signalHash, proposerNullifier, EXTERNAL_NULLIFIER_PROPOSE, proof);

        //Store proposal
        proposals[msg.sender] = Proposal({
            proposer: msg.sender,
            proposed: proposed,
            proposerNullifier: proposerNullifier,
            accepted: false,
            timestamp: block.timestamp
        });

        _addProposal(msg.sender, proposed); //track who proposed to whom

        emit ProposalCreated(msg.sender, proposed, block.timestamp);
    }

    /// @notice Accept an existing proposal, verify humanity, and mint NFTs + ERC-20.
    /// @param proposer The address of the original proposer.
    /// @param root The World ID root from the proof.
    /// @param acceptorNullifier The unique nullifier preventing proof re-use.
    /// @param proof The zero-knowledge proof array.
    function accept(address proposer, uint256 root, uint256 acceptorNullifier, uint256[8] calldata proof) external {
        Proposal storage proposalOfProposer = proposals[proposer]; // the struct stored, previously created in propose()
        uint256 signalHash = abi.encodePacked(msg.sender).hashToField();

        if (block.timestamp - lastDissolutionTimestamp[msg.sender] < REBOND_COOLDOWN) {
            revert HumanBond__CooldownActive();
        }

        if (proposalOfProposer.proposed != msg.sender) {
            revert HumanBond__NotProposedToYou();
        }
        if (activeBondOf[proposer] != bytes32(0) || activeBondOf[msg.sender] != bytes32(0)) {
            revert HumanBond__UserAlreadyBonded();
        } //not reaching, propose function reverts before

        // Verify acceptor is also a real human
        WORLD_ID.verifyProof(
            root,
            GROUP_ID,
            signalHash, // signal = sender address
            acceptorNullifier,
            EXTERNAL_NULLIFIER_ACCEPT,
            proof
        );

        // Create bond ID
        bytes32 bondId = _getBondId(proposer, msg.sender);
        if (bonds[bondId].active) {
            revert HumanBond__UserAlreadyBonded();
        }

        // Record bond data
        bonds[bondId] = Bond({
            partnerA: proposer,
            partnerB: msg.sender,
            nullifierA: proposalOfProposer.proposerNullifier,
            nullifierB: acceptorNullifier,
            bondStart: block.timestamp,
            lastClaim: block.timestamp,
            lastMilestoneYear: 0,
            active: true
        });

        activeBondOf[proposer] = bondId; //active bond ID by user address
        activeBondOf[msg.sender] = bondId;
        activeBondCount++;

        bool crossProposed = proposals[msg.sender].proposed == proposer; //check if acceptor also proposed to proposer, if so clean up that proposal too
        delete proposals[proposer]; // clear proposer's outgoing proposal
        delete proposals[msg.sender]; // clear acceptor's outgoing proposal if one exists
        _removeProposal(proposer, msg.sender); // remove proposer from acceptor's incoming list
        if (crossProposed) _removeProposal(msg.sender, proposer); // remove acceptor from proposer's incoming list

        bondIds.push(bondId);

        // Mint identical NFTs for both partners
        BOND_NFT.mintBondNft(proposer, proposer, msg.sender, block.timestamp, bondId);
        BOND_NFT.mintBondNft(msg.sender, proposer, msg.sender, block.timestamp, bondId);

        // Reward both parties with 1 TOKEN immediately
        TIME_TOKEN.mint(proposer, 1 ether);
        TIME_TOKEN.mint(msg.sender, 1 ether);

        emit ProposalAccepted(proposer, msg.sender, block.timestamp);
    }

    /// @notice Owner can adjust the required waiting period between request and execution.
    function setDissolutionDelay(uint256 _delay) external onlyOwner {
        dissolutionDelay = _delay;
    }

    /// @notice Initiate a dissolution request. The requesting partner must wait dissolutionDelay before executing.
    function requestDissolution(address partner) external {
        bytes32 bondId = _getBondId(msg.sender, partner);
        Bond storage bond = bonds[bondId];

        if (!bond.active) revert HumanBond__NoActiveBond();
        if (msg.sender != bond.partnerA && msg.sender != bond.partnerB) {
            revert HumanBond__NotYourBond();
        }
        if (dissolutionRequests[bondId].active) {
            revert HumanBond__DissolutionAlreadyRequested();
        }

        dissolutionRequests[bondId] =
            DissolutionRequest({requester: msg.sender, requestedAt: block.timestamp, active: true});

        emit DissolutionRequested(bond.partnerA, bond.partnerB, msg.sender, block.timestamp);
    }

    /// @notice Execute a previously requested dissolution once the delay has elapsed.
    function executeDissolution(address partner) external {
        bytes32 bondId = _getBondId(msg.sender, partner);
        Bond storage bond = bonds[bondId];
        DissolutionRequest storage req = dissolutionRequests[bondId];

        if (!bond.active) revert HumanBond__NoActiveBond();
        if (!req.active) revert HumanBond__NoDissolutionRequest();
        if (msg.sender != req.requester) revert HumanBond__NotYourBond();
        if (block.timestamp < req.requestedAt + dissolutionDelay) {
            revert HumanBond__DissolutionDelayNotMet();
        }

        uint256 reward = _pendingYield(bondId);
        if (reward > 0) {
            uint256 split = reward / 2;
            TIME_TOKEN.mint(bond.partnerA, split);
            TIME_TOKEN.mint(bond.partnerB, reward - split);
        }

        bond.active = false;
        bond.lastClaim = block.timestamp;
        lastDissolutionTimestamp[bond.partnerA] = block.timestamp;
        lastDissolutionTimestamp[bond.partnerB] = block.timestamp;
        activeBondCount--;
        totalDissolutionCount++;

        activeBondOf[bond.partnerA] = bytes32(0);
        activeBondOf[bond.partnerB] = bytes32(0);

        delete dissolutionRequests[bondId];

        emit BondDissolved(bond.partnerA, bond.partnerB, block.timestamp);
    }

    /// @notice Cancel a pending dissolution request. Only the requester can cancel.
    function cancelDissolutionRequest(address partner) external {
        bytes32 bondId = _getBondId(msg.sender, partner);
        DissolutionRequest storage req = dissolutionRequests[bondId];

        if (!req.active) revert HumanBond__NoDissolutionRequest();
        if (msg.sender != req.requester) revert HumanBond__NotYourBond();

        Bond storage bond = bonds[bondId];
        delete dissolutionRequests[bondId];

        emit DissolutionRequestCancelled(bond.partnerA, bond.partnerB, block.timestamp);
    }

    /* ---------------------------- YIELD LOGIC --------------------------- */
    /// @dev Calculate pending yield for a bond, 1 token per day shared.
    /// @param bondId The unique ID representing the bond.
    function _pendingYield(bytes32 bondId) internal view returns (uint256) {
        Bond storage bond = bonds[bondId];
        if (!bond.active) return 0;
        uint256 daysElapsed = (block.timestamp - bond.lastClaim) / DAY;
        return daysElapsed * 1 ether;
    }

    /// @notice Claim accumulated yield for the calling user's bond.
    /// @param partner The address of the calling user's partner.
    function claimYield(address partner) external {
        bytes32 bondId = _getBondId(msg.sender, partner);
        Bond storage bond = bonds[bondId];
        if (!bond.active) revert HumanBond__NoActiveBond();

        uint256 reward = _pendingYield(bondId);
        if (reward == 0) {
            revert HumanBond__NothingToClaim();
        }

        uint256 split = reward / 2;

        TIME_TOKEN.mint(bond.partnerA, split);
        TIME_TOKEN.mint(bond.partnerB, reward - split); // captures remainder

        bond.lastClaim = block.timestamp;
        emit YieldClaimed(bond.partnerA, bond.partnerB, split);
    }

    /* ---------------------------- NFT's MINTING LOGIC --------------------------- */

    /// @notice Manually check and mint milestone NFTs for both partners based on years together.
    ///         if they missed previous years, mint all missing years up to current.
    function manualCheckAndMint(address partner) external {
        bytes32 id = _getBondId(msg.sender, partner); //get the deterministic bondId of the couple
        Bond storage m = bonds[id]; // get the bond struct based on the id

        if (!m.active) revert HumanBond__NoActiveBond();

        address a = m.partnerA;
        address b = m.partnerB;
        if (msg.sender != a && msg.sender != b) {
            revert HumanBond__NotYourBond();
        }

        uint256 bondStart = m.bondStart; // when the bond started
        uint256 yearsTogether = (block.timestamp - bondStart) / YEAR; // how many years together
        uint256 lastClaimed = m.lastMilestoneYear; // the last milestone year they claimed NFTs for
        uint256 highestYearSet = MILESTONE_NFT.latestYear(); // the max year defined by MilestoneNFT

        // If no milestones set since last claim or zero years together, revert
        if (yearsTogether <= lastClaimed || yearsTogether == 0) {
            revert HumanBond__NothingToClaim();
        }

        // if yearsTogether exceeds highestYearSet, cap it to highestYearSet
        uint256 endYear = yearsTogether > highestYearSet ? highestYearSet : yearsTogether;
        uint256 startYear = lastClaimed + 1; // the year after the last claimed milestone, +1 to avoid double minting

        // if the last claimed year is already the highest year set, nothing to mint
        if (startYear > endYear) revert HumanBond__NothingToClaim();

        // Mint all missing years
        _mintYearRange(a, b, id, startYear, endYear, bondStart);

        m.lastMilestoneYear = endYear;
    }

    function _mintYearRange(address a, address b, bytes32 id, uint256 startYear, uint256 endYear, uint256 bondStart)
        internal
    {
        for (uint256 y = startYear; y <= endYear;) {
            MILESTONE_NFT.mintMilestone(a, y, a, b, id, bondStart);
            MILESTONE_NFT.mintMilestone(b, y, a, b, id, bondStart);

            emit AnniversaryAchieved(a, b, y, block.timestamp);

            unchecked {
                y++;
            }
        }
    }

    /* --------------------------- PROPOSALS ------------------------------- */

    /// @notice Cancel an existing proposal made by the caller.
    function cancelProposal() external {
        Proposal memory proposalOfProposer = proposals[msg.sender];
        if (proposalOfProposer.proposer == address(0)) {
            revert HumanBond__InvalidAddress();
        }
        delete proposals[msg.sender];
        _removeProposal(msg.sender, proposalOfProposer.proposed);

        emit ProposalCancelled(msg.sender, proposalOfProposer.proposed, block.timestamp);
    }

    /// @notice Reject an incoming proposal made to the caller.
    /// @param proposer The address of the person who proposed to you.
    function rejectProposal(address proposer) external {
        Proposal memory incomingProposal = proposals[proposer];
        if (incomingProposal.proposed != msg.sender) {
            revert HumanBond__NotProposedToYou();
        }
        delete proposals[proposer];
        _removeProposal(proposer, msg.sender);

        emit ProposalRejected(proposer, msg.sender, block.timestamp);
    }

    /* --------------------------- INTERNAL HELPER -------------------------- */

    /// @dev Internal function to add a proposal to the tracking mappings.
    function _addProposal(address proposer, address proposed) internal {
        proposalsFor[proposed].push(proposer);
        proposerIndex[proposer] = proposalsFor[proposed].length - 1;
    }

    /// @dev Internal function to remove a proposal from the tracking mappings.
    function _removeProposal(address proposer, address proposed) internal {
        uint256 idx = proposerIndex[proposer];
        uint256 lastIdx = proposalsFor[proposed].length - 1;

        if (idx != lastIdx) {
            // swap with last element
            address lastProposer = proposalsFor[proposed][lastIdx];
            proposalsFor[proposed][idx] = lastProposer;
            proposerIndex[lastProposer] = idx;
        }

        proposalsFor[proposed].pop();
        delete proposerIndex[proposer];
    }

    /// @dev Generate a unique bond ID for a couple based on their addresses.
    ///      Order of addresses does not matter.
    function _getBondId(address a, address b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /* --------------------------- GETTERS FUNCTIONS -------------------------- */

    /// @dev Get all incoming proposals for a user, meaning proposals made to them.
    function getIncomingProposals(address user) external view returns (Proposal[] memory) {
        address[] memory proposers = proposalsFor[user];
        Proposal[] memory incoming = new Proposal[](proposers.length);

        for (uint256 i = 0; i < proposers.length; i++) {
            incoming[i] = proposals[proposers[i]];
        }

        return incoming;
    }

    /// @dev Get active bond struct for a couple, e.g. addresses, timestamps, status.
    function getBond(address a, address b) external view returns (Bond memory) {
        return bonds[_getBondId(a, b)];
    }

    /// @dev Get deterministic bond ID for a couple.
    function getBondId(address a, address b) external pure returns (bytes32) {
        return _getBondId(a, b);
    }

    /// @dev Check if two addresses are currently bonded
    function isBonded(address a, address b) external view returns (bool) {
        return bonds[_getBondId(a, b)].active;
    }

    /// @dev Get proposal info for a proposer
    function getProposal(address proposer) external view returns (Proposal memory) {
        return proposals[proposer];
    }

    /// @dev Get proposal info for a proposer
    function hasPendingProposal(address proposer) external view returns (bool) {
        return proposals[proposer].proposer != address(0);
    }

    /// @dev Get the current pending yield for a couple
    function getPendingYield(address a, address b) external view returns (uint256) {
        return _pendingYield(_getBondId(a, b));
    }

    /// @dev Get the current milestone year for a couple
    function getCurrentMilestoneYear(address a, address b) external view returns (uint256) {
        return bonds[_getBondId(a, b)].lastMilestoneYear;
    }

    /// @dev Get the bond start timestamp for a couple
    function getBondStart(address a, address b) external view returns (uint256) {
        return bonds[_getBondId(a, b)].bondStart;
    }

    /// @dev Get the dissolution request details for a couple, if any
    function getDissolutionRequest(address a, address b) external view returns (DissolutionRequest memory) {
        return dissolutionRequests[_getBondId(a, b)];
    }

    /// @dev Get a read-only view struct for a couple's bond details
    function getBondView(address a, address b) external view returns (BondView memory v) {
        bytes32 id = _getBondId(a, b);
        Bond memory m = bonds[id];

        v = BondView({
            partnerA: m.partnerA,
            partnerB: m.partnerB,
            nullifierA: m.nullifierA,
            nullifierB: m.nullifierB,
            bondStart: m.bondStart,
            lastClaim: m.lastClaim,
            lastMilestoneYear: m.lastMilestoneYear,
            active: m.active,
            pendingYield: _pendingYield(id),
            bondId: _getBondId(a, b)
        });
    }

    /// @dev Get user dashboard info: bond status, pending yield, TIME balance, proposal status
    function getUserDashboard(address user) external view returns (UserDashboard memory d) {
        bytes32 bondId = activeBondOf[user]; //Read active bond

        if (bondId == bytes32(0)) {
            // User is NOT bonded
            d.isBonded = false;
            d.partner = address(0);
            d.pendingYield = 0;
            d.hasProposal = proposals[user].proposer != address(0);
            d.timeBalance = TIME_TOKEN.balanceOf(user);
            return d;
        }

        // User IS bonded
        Bond storage m = bonds[bondId];
        d.isBonded = m.active;
        d.partner = (m.partnerA == user) ? m.partnerB : m.partnerA;
        d.pendingYield = _pendingYield(bondId);
        d.timeBalance = TIME_TOKEN.balanceOf(user);
        d.hasProposal = proposals[user].proposer != address(0);
    }
}

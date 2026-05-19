# HumanBond Protocol — V3

On-chain bonds, yield, milestones & relationship-proof infrastructure.

## Table of Contents

1. [Introduction](#introduction)
2. [Smart Contracts](#smart-contracts)
3. [Protocol Overview](#protocol-overview)
4. [View & Getter Functions](#view--getter-functions)
5. [Refactoring History](#refactoring-history)
6. [Author](#written-and-refactored-by)

---

## Introduction

HumanBond allows two verified humans (via World ID) to form a cryptographically provable bond on-chain.

A bond becomes:

- A permanent on-chain registry entry with a deterministic bond ID, and
- A two-person relationship with shared yield, annual milestones, and a full on-chain history.

With one proposal → one acceptance → a bond immediately receives:

- A soulbound Bond NFT (one per partner)
- Annual Milestone NFTs
- TIME token yield for each day bonded together

The protocol handles everything autonomously: proposals, acceptance, yield, milestones, and a two-step dissolution with cooldown protection.

---

## Smart Contracts

### World Chain Mainnet

- **HumanBond (Core Engine)**: [0xB3cbCB0294995FE1aCD7187B94aEDBD4555c5A63](https://worldscan.org/address/0xB3cbCB0294995FE1aCD7187B94aEDBD4555c5A63)
- **BondNFT (Soulbound)**: [0x8c64c304854F9284ddb976918dF37Bd4f5949F22](https://worldscan.org/address/0x8c64c304854F9284ddb976918dF37Bd4f5949F22)
- **MilestoneNFT (Soulbound)**: [0x566c4a366625F08A714dd092f8bD2F0E86f906f5](https://worldscan.org/address/0x566c4a366625F08A714dd092f8bD2F0E86f906f5)
- **TIME Token**: [0x39e629681a9db65D9352961d8dCD4C96C4A1169a](https://worldscan.org/address/0x39e629681a9db65D9352961d8dCD4C96C4A1169a)

### Contract Responsibilities

**HumanBond.sol** → Core logic: proposals, bond activation, two-step dissolution, cooldown enforcement, yield accrual, milestone triggering.

**BondNFT.sol** → Soulbound ERC-721 minted once per partner at bond creation. Stores dynamic on-chain metadata: partner addresses, bond start timestamp, and bond ID. Full bond history per couple tracked via `bondToToken` (dynamic array — supports rebonding).

**MilestoneNFT.sol** → Soulbound ERC-721 collection tracking yearly anniversaries. URIs are set per year by the owner and can be frozen to prevent further changes. Supports catch-up minting for missed years. Each token stores on-chain metadata: milestone year, partner addresses, bond ID, bond start, and claim timestamp.

**TimeToken.sol** → ERC-20 reward token. Accrues at 1 token per day per couple. Minting is controlled exclusively by HumanBond.

---

## Protocol Overview

### 1. Proposal

```bash
propose(address proposed, uint256 root, uint256 nullifier, uint256[8] proof)
```

- Caller must not be in an active bond
- Caller must not be within the rebond cooldown window after a dissolution
- Verifies the proposer is a real human via World ID (Orb-level, `GROUP_ID = 1`)
- Stores an outgoing proposal and adds the proposer to the recipient's incoming list
- One active outgoing proposal per address at a time

```bash
cancelProposal()
```

- Proposer can cancel their own outgoing proposal at any time

```bash
rejectProposal(address proposer)
```

- Recipient can reject an incoming proposal

### 2. Acceptance

```bash
accept(address proposer, uint256 root, uint256 nullifier, uint256[8] proof)
```

- Acceptor must also pass World ID verification (separate nullifier and action from propose)
- Acceptor must not be within the rebond cooldown window
- Creates the bond with a deterministic bond ID (`keccak256` of both addresses, order-independent)
- Mints one BondNFT to each partner
- Mints 1 TIME token to each partner immediately
- Clears all related proposals (including cross-proposals)
- Both partners' World ID nullifiers are stored on-chain as part of the bond record

### 3. Daily Yield

Partners accrue 1 TIME token per day together (shared, split 50/50 on claim).

```bash
claimYield(address partner)
```

- Calculates days elapsed since last claim
- Mints split TIME tokens directly to each partner

### 4. Milestones

```bash
manualCheckAndMint(address partner)
```

- Mints yearly anniversary MilestoneNFTs for both partners
- Supports catch-up minting if previous years were missed
- Capped at the highest year configured in MilestoneNFT (`latestYear`)

### 5. Dissolution (Two-Step)

```bash
requestDissolution(address partner)
```

- Either partner can initiate
- Starts a waiting period (`dissolutionDelay`, default 3 days)

```bash
executeDissolution(address partner)
```

- Only the requester can execute, after the delay has elapsed
- Auto-mints any pending yield before dissolving the bond
- Marks bond inactive, frees both partners
- Sets rebond cooldown (`REBOND_COOLDOWN`) on both addresses
- Preserves all historical bond data on-chain (bond struct is marked inactive, not deleted)

```bash
cancelDissolutionRequest(address partner)
```

- Requester can cancel before the delay elapses

> **Note:** `dissolutionDelay` is adjustable by the contract owner via `setDissolutionDelay(uint256 _delay)`. The default is 3 days.

### 6. Rebond Cooldown

After a dissolution, both partners enter a cooldown period (`REBOND_COOLDOWN`) during which they cannot propose or accept new bonds. This prevents dissolution/rebond spam cycles.

---

## View & Getter Functions

UI-ready read-only functions available on HumanBond:

| Function | Description |
|---|---|
| `isBonded(address a, address b)` | Returns `true` if the two addresses have an active bond |
| `getBondId(address a, address b)` | Returns the deterministic bond ID for a couple |
| `getBond(address a, address b)` | Returns the full `Bond` struct |
| `getBondView(address a, address b)` | Returns a `BondView` struct including pending yield and bond ID |
| `getUserDashboard(address user)` | Returns `UserDashboard`: bond status (`isBonded`), partner, pending yield, TIME balance, proposal status |
| `getIncomingProposals(address user)` | Returns all pending proposals made to a given address |
| `getProposal(address proposer)` | Returns the outgoing proposal for a given address |
| `hasPendingProposal(address proposer)` | Returns `true` if the address has an active outgoing proposal |
| `getPendingYield(address a, address b)` | Returns unclaimed TIME yield for a bond |
| `getBondStart(address a, address b)` | Returns the timestamp when the bond was created |
| `getCurrentMilestoneYear(address a, address b)` | Returns the last milestone year claimed |
| `getDissolutionRequest(address a, address b)` | Returns the active `DissolutionRequest` struct for a bond, if any |

On BondNFT:

| Function | Description |
|---|---|
| `getTokensByBond(bytes32 bondId)` | Returns all token IDs minted for a given bond ID (supports rebond history) |
| `getTokenMetadata(uint256 tokenId)` | Returns `partnerA`, `partnerB`, `bondStart`, `bondId` for a token |

---

## Refactoring History

### V2 — Post-Hackathon Refactor

- Clean architecture: O(1) proposal indexing and removal
- Deterministic bond IDs for easy lookups
- Dynamic BondNFT on-chain metadata
- MilestoneNFT with upgradeable year registry and freeze mechanism
- Catch-up minting for missed anniversaries
- Separate World ID external nullifiers for propose and accept actions
- UI-ready getter functions (`getBondView`, `getUserDashboard`, `getIncomingProposals`)

### V3 — Anti-Spam & Protocol Tracking

- Two-step dissolution: `requestDissolution()` → delay period → `executeDissolution()`
- `cancelDissolutionRequest()` — requester can back out before delay elapses
- `cancelProposal()` — proposer can cancel their own outgoing proposal
- `rejectProposal()` — recipient can reject incoming proposals
- `activeBondCount` — live count of currently bonded couples
- `totalDissolutionCount` — total dissolutions ever recorded
- `lastDissolutionTimestamp` + `REBOND_COOLDOWN` — per-user cooldown after dissolution
- `setDissolutionDelay()` — owner-adjustable dissolution waiting period
- BondNFT: `bondToToken` tracks full bond history per couple (dynamic array, rebond-safe)

---

## Written and refactored by

Leticia Azevedo — Smart Contracts Developer (Brazil)

# 💍 HumanBond Protocol — V3

On-chain bonds, yield, milestones & relationship-proof infrastructure.

## Table of Contents

1. [Introduction](#introduction)
2. [Smart Contracts](#smart-contracts)
3. [Protocol Overview](#protocol-overview)
4. [Refactoring History](#refactoring-history)
5. [Author](#written-and-refactored-by)

---

## Introduction

HumanBond allows two verified humans (via World ID) to form a cryptographically provable bond on-chain.

A bond becomes:

- A legal-fiction on-chain registry entry, and
- A two-person bond with shared yield, annual milestones, and a permanent on-chain history.

With one proposal → one acceptance → a bond immediately receives:

- A soulbound Bond NFT (one per partner)
- Annual Milestone NFTs
- TIME token yield for each day bonded together

The protocol handles everything autonomously: proposals, acceptance, yield, milestones, and a two-step divorce with cooldown protection.

---

## Smart Contracts

### World Chain Mainnet

- **HumanBond (Core Engine)**: [0xB3cbCB0294995FE1aCD7187B94aEDBD4555c5A63](https://worldscan.org/address/0xB3cbCB0294995FE1aCD7187B94aEDBD4555c5A63)
- **BondNFT (Soulbound)**: [0x8c64c304854F9284ddb976918dF37Bd4f5949F22](https://worldscan.org/address/0x8c64c304854F9284ddb976918dF37Bd4f5949F22)
- **MilestoneNFT (Soulbound)**: [0x566c4a366625F08A714dd092f8bD2F0E86f906f5](https://worldscan.org/address/0x566c4a366625F08A714dd092f8bD2F0E86f906f5)
- **TIME Token**: [0x39e629681a9db65D9352961d8dCD4C96C4A1169a](https://worldscan.org/address/0x39e629681a9db65D9352961d8dCD4C96C4A1169a)

### Contract Responsibilities

**HumanBond.sol** → Core logic: proposals, bond activation, two-step divorce, cooldown enforcement, yield accrual, milestone triggering.

**BondNFT.sol** → Soulbound ERC-721 minted once per partner at bond creation. Stores dynamic on-chain metadata: partner addresses, bond start timestamp, and marriage ID. Full bond history per couple tracked via `marriageToToken`.

**MilestoneNFT.sol** → Soulbound ERC-721 collection tracking yearly anniversaries. URIs are set per year by the owner and can be frozen to prevent further changes. Supports catch-up minting for missed years.

**TimeToken.sol** → ERC-20 reward token. Accrues at 1 token per day per couple. Minting is controlled exclusively by HumanBond.

---

## Protocol Overview

### 1. Proposal

```bash
propose(address proposed, uint256 root, uint256 nullifier, uint256[8] proof)
```

- Caller must not be in an active bond
- Caller must not be within the rebond cooldown window after a divorce
- Verifies the proposer is a real human via World ID (Orb-level, groupId = 1)
- Stores an outgoing proposal and adds proposer to the recipient's incoming list
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

- Acceptor must also pass World ID verification (separate nullifier and action)
- Acceptor must not be within the rebond cooldown window
- Creates the bond with a deterministic bond ID
- Mints one BondNFT to each partner
- Mints 1 TIME token to each partner immediately
- Clears all related proposals (including cross-proposals)

### 3. Daily Yield

Partners bonded accrue 1 TIME token per day together (shared, split 50/50 on claim).

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
- Capped at the highest year configured in MilestoneNFT

### 5. Divorce (Two-Step)

```bash
requestDivorce(address partner)
```

- Either partner can initiate
- Starts a 3-day waiting period

```bash
executeDivorce(address partner)
```

- Only the requester can execute, after the delay has elapsed
- Auto-mints any pending yield before dissolving the bond
- Marks bond inactive, frees both partners
- Sets rebond cooldown (`REBOND_COOLDOWN`) on both addresses
- Preserves all historical data on-chain

```bash
cancelDivorceRequest(address partner)
```

- Requester can cancel before the delay elapses

### 6. Rebond Cooldown

After a divorce, both partners enter a cooldown period during which they cannot propose or accept new bonds. This prevents divorce/rebond spam cycles.

---

## Refactoring History

### V2 — Post-Hackathon Refactor

- Clean architecture: O(1) proposal indexing and removal
- Deterministic marriage IDs for easy lookups
- Dynamic BondNFT on-chain metadata
- MilestoneNFT with upgradeable year registry
- Catch-up minting for missed anniversaries
- Separate World ID external nullifiers for propose and accept actions
- UI-ready getter functions (`getMarriageView`, `getUserDashboard`, `getIncomingProposals`)

### V3 — Anti-Spam & Protocol Tracking

- Two-step divorce: `requestDivorce()` → 3-day delay → `executeDivorce()`
- `cancelDivorceRequest()` — requester can back out before delay elapses
- `cancelProposal()` — proposer can cancel their own outgoing proposal
- `rejectProposal()` — recipient can reject incoming proposals
- `activeMarriageCount` — live count of currently bonded couples
- `totalDivorceCount` — total dissolutions ever recorded
- `lastDivorceTimestamp` + `REBOND_COOLDOWN` — per-user cooldown after divorce
- BondNFT: `marriageToToken` now tracks full bond history per couple (dynamic array)

---

## Written and refactored by

Leticia Azevedo — Smart Contracts Developer (Brazil)
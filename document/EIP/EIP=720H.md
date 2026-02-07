---
eip: XXXX
title: ERC-721H — Historical Ownership Extension for ERC-721
description: An extension to ERC-721 that preserves complete, on-chain ownership history through a three-layer model.
author: Emiliano Solazzi 
discussions-to: https://ethereum-magicians.org/t/erc-721h-historical-ownership-tracking/XXXX
status: Draft
type: Standards Track
category: ERC
created: 2026-02-07
requires: 165, 721
---

## Abstract

This EIP defines an extension to [ERC-721](https://eips.ethereum.org/EIPS/eip-721) that records the **complete ownership history** of every non-fungible token on-chain. ERC-721 tracks only the current owner; the moment a token is transferred, on-chain evidence that the previous holder ever possessed it is lost. ERC-721H introduces a **three-layer ownership model**:

| Layer | Name | Mutability | Purpose |
|:------|:-----|:-----------|:--------|
| 1 | Immutable Origin | Write-once | Records who minted / created the token |
| 2 | Historical Trail | Append-only | Chronological list of every past owner |
| 3 | Current Authority | Mutable | Standard ERC-721 `ownerOf()` semantics |

A compliant contract MUST implement ERC-721, ERC-165, and the `IERC721H` interface defined herein.

## Motivation

### The Problem

ERC-721 stores exactly one piece of ownership data: the **current** owner. When Alice transfers Token #1 to Bob, and Bob transfers to Charlie, there is zero on-chain state proving Alice ever held the token. The only evidence lives in `Transfer` event logs, which:

1. **Cannot be read by other smart contracts** — `eth_getLogs` is an off-chain JSON-RPC call, not an EVM opcode.
2. **Require off-chain indexers** — The Graph, Alchemy, or custom infrastructure must be trusted to reconstruct history.
3. **Are fragile** — Indexers go down, have lag, and cost money. Archive nodes are expensive.
4. **Cannot power on-chain governance** — A DAO cannot grant "founding member" privileges based on event logs alone.

### Real-World Use Cases That ERC-721 Cannot Serve

1. **Art Provenance**: A collector wants on-chain proof that a Picasso NFT passed through Christie's gallery. ERC-721 cannot answer "did address X ever own token Y?" without an indexer.

2. **Founder Benefits**: A project wants to give perpetual 2% royalties to the original minter of each token, even after they sell. ERC-721 discards the minter address on first transfer.

3. **Early Adopter Airdrops**: A protocol wants to airdrop governance tokens to everyone who held an NFT during the first 100 blocks. With ERC-721, this requires reconstructing history from logs off-chain and submitting a Merkle root — expensive, slow, and trust-dependent.

4. **Legal Proof-of-Custody**: In a dispute over rightful ownership, on-chain history provides a tamper-proof chain of custody. Event logs can be dismissed as "indexer output" in legal proceedings; storage slots cannot.

5. **Gaming Veteran Status**: A game wants to show a "Day 1 Player" badge to anyone who minted during launch week, regardless of whether they still hold the token.

### Why Extend ERC-721 Instead of Creating a New Standard?

ERC-721H is a **strict superset** of ERC-721. Every ERC-721H token is a valid ERC-721 token. Wallets, marketplaces, and existing tooling interact with it identically. The historical layer is additive — contracts that don't need history simply ignore it.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174.

### Interface

Every ERC-721H compliant contract MUST implement the `IERC721H` interface:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IERC721H {
    // ── Events ────────────────────────────────────────

    /// @notice Emitted every time a token's ownership history is extended.
    event OwnershipHistoryRecorded(
        uint256 indexed tokenId,
        address indexed newOwner,
        uint256 timestamp
    );

    /// @notice Emitted once at mint to record the immutable creator.
    event OriginalCreatorRecorded(
        uint256 indexed tokenId,
        address indexed creator
    );

    // ── Layer 1: Immutable Origin ─────────────────────

    /// @notice Returns the address that originally minted `tokenId`.
    function originalCreator(uint256 tokenId) external view returns (address);

    /// @notice Returns the block number at which `tokenId` was minted.
    function mintBlock(uint256 tokenId) external view returns (uint256);

    /// @notice Returns true if `account` was the original minter of `tokenId`.
    function isOriginalOwner(uint256 tokenId, address account) external view returns (bool);

    // ── Layer 2: Historical Trail ─────────────────────

    /// @notice Returns true if `account` has ever owned `tokenId`. MUST be O(1).
    function hasEverOwned(uint256 tokenId, address account) external view returns (bool);

    /// @notice Returns the complete chronological ownership chain for `tokenId`.
    function getOwnershipHistory(uint256 tokenId)
        external view returns (address[] memory owners, uint256[] memory timestamps);

    /// @notice Returns how many times `tokenId` has been transferred (excludes mint).
    function getTransferCount(uint256 tokenId) external view returns (uint256);

    /// @notice Returns every token `account` has ever owned (deduplicated).
    function getEverOwnedTokens(address account) external view returns (uint256[] memory);

    /// @notice Returns every token `creator` originally minted.
    function getOriginallyCreatedTokens(address creator) external view returns (uint256[] memory);

    /// @notice Returns true if `account` minted any token at or before `blockThreshold`.
    function isEarlyAdopter(address account, uint256 blockThreshold) external view returns (bool);

    // ── Layer 3: Current Authority ────────────────────

    /// @notice Returns true if `account` is the current owner of `tokenId`.
    function isCurrentOwner(uint256 tokenId, address account) external view returns (bool);

    // ── Aggregate Queries ─────────────────────────────

    /// @notice Returns a full provenance report for `tokenId` in a single call.
    function getProvenanceReport(uint256 tokenId)
        external view returns (
            address creator,
            uint256 creationBlock,
            address currentOwnerAddress,
            uint256 totalTransfers,
            address[] memory allOwners,
            uint256[] memory transferTimestamps
        );

    /// @notice Returns the total number of tokens currently in existence.
    function totalSupply() external view returns (uint256);

    // ── Lifecycle ─────────────────────────────────────

    /// @notice Burns `tokenId`. Layer 1 and Layer 2 data MUST be preserved.
    function burn(uint256 tokenId) external;
}
```

### Behavioral Requirements

#### Layer 1 — Immutable Origin

1. `originalCreator(tokenId)` MUST be set exactly once, at mint time.
2. `originalCreator(tokenId)` MUST NOT change after mint, even if the token is transferred or burned.
3. `mintBlock(tokenId)` MUST record `block.number` at the time of minting.
4. The contract MUST emit `OriginalCreatorRecorded(tokenId, creator)` exactly once per token, at mint.

#### Layer 2 — Historical Trail

5. On every transfer (including mint), the recipient address MUST be appended to the ownership history for `tokenId`.
6. The ownership history MUST be append-only. Entries MUST NOT be removed, modified, or reordered.
7. `hasEverOwned(tokenId, account)` MUST execute in O(1) time. Implementations SHOULD use a nested `mapping(uint256 => mapping(address => bool))`.
8. `getOwnershipHistory(tokenId)` MUST return two parallel arrays of equal length: addresses and timestamps, in chronological order. The first element MUST be the original creator.
9. The `_everOwnedTokens` mapping MUST be deduplicated — if an address receives the same token twice (e.g., Alice → Bob → Alice), the token ID MUST appear only once in Alice's list.
10. The contract MUST emit `OwnershipHistoryRecorded(tokenId, newOwner, timestamp)` on every mint and transfer.

#### Layer 3 — Current Authority

11. Layer 3 MUST behave identically to ERC-721. `ownerOf()`, `balanceOf()`, `transferFrom()`, `safeTransferFrom()`, `approve()`, `setApprovalForAll()`, `getApproved()`, and `isApprovedForAll()` MUST comply with ERC-721.

#### Burn Behavior

12. When a token is burned, Layer 3 data (current owner) MUST be cleared.
13. When a token is burned, Layer 1 data (`originalCreator`, `mintBlock`) MUST be preserved.
14. When a token is burned, Layer 2 data (`_ownershipHistory`, `_ownershipTimestamps`, `_hasOwnedToken`) MUST be preserved.
15. After burn, `originalCreator(tokenId)` MUST still return the original minter. `getOwnershipHistory(tokenId)` MAY revert (token no longer exists) or MAY return the preserved history — implementations SHOULD document their choice.

#### ERC-165

16. Compliant contracts MUST implement ERC-165 and return `true` for:
    - `0x01ffc9a7` (ERC-165)
    - `0x80ac58cd` (ERC-721)
    - The interface ID computed as the XOR of all function selectors in `IERC721H`

### Events

| Event | When Emitted |
|:------|:-------------|
| `OwnershipHistoryRecorded(uint256 tokenId, address newOwner, uint256 timestamp)` | Every mint and transfer |
| `OriginalCreatorRecorded(uint256 tokenId, address creator)` | Once, at mint |
| `Transfer(address from, address to, uint256 tokenId)` | Per ERC-721 |
| `Approval(address owner, address approved, uint256 tokenId)` | Per ERC-721 |
| `ApprovalForAll(address owner, address operator, bool approved)` | Per ERC-721 |

## Rationale

### Why Three Layers Instead of One Extended Mapping?

A single `mapping(uint256 => OwnershipRecord)` struct was considered but rejected because:

- **Layer 1 and Layer 2 have different mutability guarantees.** Layer 1 is write-once; Layer 2 is append-only; Layer 3 is freely mutable. Mixing them in one struct obscures these invariants.
- **Separate mappings allow independent optimization.** `hasEverOwned()` uses a dedicated `mapping(uint256 => mapping(address => bool))` for O(1) lookups without touching the history array.
- **The mental model is clearer.** Developers can reason about "which layer am I modifying?" during code review.

### Why O(1) `hasEverOwned()` Instead of Array Scan?

The most common on-chain query is: *"Has this address ever owned this token?"* — used for governance, airdrops, and access control. A linear scan of the history array would make this O(n) where n is the number of transfers, which becomes unbounded over time. The dedicated `_hasOwnedToken` mapping guarantees constant-time lookups at a cost of one additional `SSTORE` per first-time owner per token.

### Why Preserve History After Burn?

Burning a token destroys its economic value but not its historical significance. A burned Bored Ape still has provenance value — who created it, who held it, when it was destroyed. Legal disputes, insurance claims, and historical research all benefit from preserved Layer 1 and Layer 2 data. The storage cost is already paid; clearing it would refund a small gas amount but destroy irreplaceable data.

### Why an Append-Only History Instead of a Merkle Tree?

Merkle trees compress historical data but require off-chain computation to verify membership. The entire point of ERC-721H is that **other smart contracts** can query history natively. An append-only array is directly readable by any contract via `getOwnershipHistory()` without proof submission.

### Why Deduplicate `_everOwnedTokens`?

Without deduplication, a token bouncing between Alice and Bob (Alice → Bob → Alice → Bob) would add the token ID to each user's list on every transfer, growing unboundedly. The `_hasOwnedToken` mapping prevents this — each address appears in a token's per-address list at most once.

### Gas Trade-offs

| Operation | ERC-721 | ERC-721H | Overhead | Cause |
|:----------|:--------|:---------|:---------|:------|
| Mint | ~50,000 | ~80,000 | +60% | 3 additional SSTOREs (origin, history, timestamp) |
| Transfer | ~50,000 | ~90,000 | +80% | 2 SSTOREs (history append, timestamp) + 1 conditional SSTORE (dedup) |
| Burn | ~30,000 | ~45,000 | +50% | Skips SSTORE refunds for preserved data |
| Read | Free | Free | — | All queries are `view` |

This overhead is acceptable on L2s (Arbitrum, Base, Optimism) where gas is 10–100x cheaper than mainnet. On L1, the 60–80% premium is the explicit trade-off for permanent, trustless provenance.

## Backwards Compatibility

ERC-721H is **fully backwards compatible** with ERC-721. Every function defined in ERC-721 behaves identically. Wallets, marketplaces (OpenSea, Blur, Rarible), and tooling (ethers.js, viem, wagmi) that interact with ERC-721 will interact with ERC-721H tokens without modification.

The historical extension is purely additive:
- Existing ERC-721 contracts are **not** affected.
- No changes to ERC-721 semantics are proposed.
- Contracts that implement ERC-721H also implement ERC-721 by definition.
- `supportsInterface(IERC721H_ID)` allows runtime detection.

### Migration Path for Existing Collections

Existing ERC-721 collections cannot be retroactively upgraded to ERC-721H (storage layout differs). The recommended migration pattern is:

1. Deploy a new ERC-721H contract.
2. Implement a `wrapAndMint(uint256 originalTokenId)` function that locks the ERC-721 token in the new contract and mints an ERC-721H wrapper with the caller as `originalCreator`.
3. Historical ownership prior to wrapping is not captured — document this limitation to users.

## Reference Implementation

A complete reference implementation is provided in [ERC-721H.sol](../assets/eip-XXXX/ERC-721H.sol) and [IERC721H.sol](../assets/eip-XXXX/IERC721H.sol).

### Key Implementation Details

**Storage Layout (6 mappings for Layer 1 & 2):**

```solidity
// Layer 1
mapping(uint256 => address) public originalCreator;
mapping(uint256 => uint256) public mintBlock;
mapping(address => uint256[]) private _createdTokens;

// Layer 2
mapping(uint256 => address[]) private _ownershipHistory;
mapping(uint256 => uint256[]) private _ownershipTimestamps;
mapping(address => uint256[]) private _everOwnedTokens;
mapping(uint256 => mapping(address => bool)) private _hasOwnedToken;
```

**Mint (initializes all three layers):**

```solidity
function mint(address to) public onlyOwner returns (uint256) {
    if (to == address(0)) revert ZeroAddress();

    uint256 tokenId = _nextTokenId++;

    // Layer 1: Immutable origin
    originalCreator[tokenId] = to;
    mintBlock[tokenId] = block.number;
    _createdTokens[to].push(tokenId);
    emit OriginalCreatorRecorded(tokenId, to);

    // Layer 2: Start history trail
    _ownershipHistory[tokenId].push(to);
    _ownershipTimestamps[tokenId].push(block.timestamp);
    _everOwnedTokens[to].push(tokenId);
    _hasOwnedToken[tokenId][to] = true;
    emit OwnershipHistoryRecorded(tokenId, to, block.timestamp);

    // Layer 3: Current owner
    _currentOwner[tokenId] = to;
    _balances[to] += 1;
    emit Transfer(address(0), to, tokenId);

    return tokenId;
}
```

**Transfer (updates Layer 2 & 3, preserves Layer 1):**

```solidity
function _transfer(address from, address to, uint256 tokenId) internal nonReentrant {
    if (ownerOf(tokenId) != from) revert NotAuthorized();
    if (to == address(0)) revert ZeroAddress();

    delete _tokenApprovals[tokenId];

    // Layer 2: Append to history (deduplicated)
    _ownershipHistory[tokenId].push(to);
    _ownershipTimestamps[tokenId].push(block.timestamp);
    if (!_hasOwnedToken[tokenId][to]) {
        _everOwnedTokens[to].push(tokenId);
        _hasOwnedToken[tokenId][to] = true;
    }
    emit OwnershipHistoryRecorded(tokenId, to, block.timestamp);

    // Layer 3: Update current owner
    _currentOwner[tokenId] = to;
    _balances[from] -= 1;
    _balances[to] += 1;
    emit Transfer(from, to, tokenId);
}
```

**Burn (clears Layer 3, preserves Layer 1 & 2):**

```solidity
function burn(uint256 tokenId) public {
    address tokenOwner = ownerOf(tokenId);
    if (msg.sender != tokenOwner && !_isApprovedOrOwner(msg.sender, tokenId)) {
        revert NotApprovedOrOwner();
    }
    delete _tokenApprovals[tokenId];

    // Layer 1 & 2: PRESERVED
    // Layer 3: Cleared
    _currentOwner[tokenId] = address(0);
    _balances[tokenOwner] -= 1;
    emit Transfer(tokenOwner, address(0), tokenId);
}
```

**O(1) History Check:**

```solidity
function hasEverOwned(uint256 tokenId, address account) public view returns (bool) {
    return _hasOwnedToken[tokenId][account];
}
```

**ERC-165 Detection:**

```solidity
function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
    return interfaceId == 0x01ffc9a7                    // ERC-165
        || interfaceId == 0x80ac58cd                    // ERC-721
        || interfaceId == 0x5b5e139f                    // ERC-721 Metadata
        || interfaceId == type(IERC721H).interfaceId;   // ERC-721H
}
```

## Security Considerations

### Unbounded History Growth

The `_ownershipHistory` array grows by one entry per transfer. For heavily traded tokens (e.g., wash trading), this array could become very large. However:

- **Reading** the array via `getOwnershipHistory()` is a `view` call and costs no gas.
- **Writing** (appending) is O(1) and costs a fixed ~20,000 gas per SSTORE regardless of array length.
- **On-chain iteration** over the array (e.g., in `isEarlyAdopter`) should be avoided for tokens with large histories. Implementations MAY add a `maxHistory` cap.

### Reentrancy

The reference implementation uses a `nonReentrant` modifier on `_transfer()` to prevent reentrancy during the multi-step state update (Layer 2 append + Layer 3 update). Implementations MUST ensure that external calls (e.g., `onERC721Received`) occur **after** all state mutations.

### Privacy

All ownership history is permanently public on-chain. Users should be aware that transferring an ERC-721H token creates an **indelible, public record** linking their address to the token. This is by design (provenance requires transparency) but may conflict with privacy expectations. Users who require privacy SHOULD use fresh addresses for each interaction.

### Storage Cost Griefing

An attacker could repeatedly transfer a token to inflate `_ownershipHistory`. Each append costs the **sender** gas (not the contract), so the attacker pays for the attack. The `_everOwnedTokens` deduplication ensures that an address's per-address list grows at most once per unique token, limiting the blast radius.

### Burn Does Not Delete

Burning preserves Layer 1 and Layer 2 storage. This means storage slots are **not** refunded on burn, unlike standard ERC-721. This is intentional — the historical data has value — but implementers should document this behavior.


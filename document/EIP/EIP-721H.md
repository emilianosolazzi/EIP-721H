---
eip: XXXX (TBD)
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

ERC-721 stores exactly one piece of ownership data: the **current** owner. When Alice transfers Token #1 to Bob, and Bob transfers to Charlie, there is no storage-level ownership record accessible to other smart contracts proving Alice ever held the token. The only evidence lives in `Transfer` event logs, which:

1. **Cannot be read by other smart contracts** — `eth_getLogs` is an off-chain JSON-RPC call, not an EVM opcode.
2. **Require off-chain indexers** — The Graph, Alchemy, or custom infrastructure must be trusted to reconstruct history.
3. **Are fragile** — Indexers go down, have lag, and cost money. Archive nodes are expensive.
4. **Cannot power on-chain governance** — A DAO cannot grant "founding member" privileges based on event logs alone.

### Real-World Use Cases That ERC-721 Cannot Serve

1. **Art Provenance**: A collector wants on-chain proof that a Picasso NFT passed through Christie's gallery. ERC-721 cannot answer "did address X ever own token Y?" without an indexer.

2. **Founder Benefits**: A project wants to give perpetual 2% royalties to the original minter of each token, even after they sell. ERC-721 discards the minter address on first transfer.

3. **Early Adopter Airdrops**: A protocol wants to airdrop governance tokens to everyone who held an NFT during the first 100 blocks. With ERC-721, this requires reconstructing history from logs off-chain and submitting a Merkle root — expensive, slow, and trust-dependent.

4. **Proof-of-Custody**: In a dispute over rightful ownership, on-chain storage provides a directly queryable chain of custody. Event logs require off-chain reconstruction and indexer infrastructure; storage slots are natively readable by any smart contract.

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

    /// @notice Emitted when a token is burned (Layer 3 cleared, Layer 1 & 2 preserved).
    event HistoricalTokenBurned(uint256 indexed tokenId);

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

    /// @notice Returns the owner of `tokenId` at any arbitrary `blockNumber`.
    /// @dev Uses O(log n) binary search over chronological `_ownershipBlocks`.
    ///      Returns the owner who held the token at `blockNumber`, even if no
    ///      transfer happened at that exact block. Returns address(0) if the
    ///      token was not yet minted at `blockNumber`.
    ///      Uses block.number (not block.timestamp) to prevent validator manipulation.
    function getOwnerAtBlock(uint256 tokenId, uint256 blockNumber) external view returns (address);

    /// @notice DEPRECATED: Use getOwnerAtBlock() instead.
    /// @dev Always returns address(0). Kept for backwards compatibility.
    function getOwnerAtTimestamp(uint256 tokenId, uint256 timestamp) external pure returns (address);

    // ── Pagination Helpers (Anti-Griefing) ────────────

    /// @notice Returns the total number of entries in `tokenId`'s ownership history.
    function getHistoryLength(uint256 tokenId) external view returns (uint256);

    /// @notice Returns a paginated slice of ownership history.
    function getHistorySlice(uint256 tokenId, uint256 start, uint256 count)
        external view returns (address[] memory owners, uint256[] memory timestamps);

    // ── Per-Address Pagination (Anti-Griefing) ────────

    /// @notice Returns the number of distinct tokens `account` has ever owned.
    function getEverOwnedTokensLength(address account) external view returns (uint256);

    /// @notice Returns a paginated slice of tokens `account` has ever owned.
    function getEverOwnedTokensSlice(address account, uint256 start, uint256 count)
        external view returns (uint256[] memory tokenIds);

    /// @notice Returns the number of tokens `creator` originally minted.
    function getCreatedTokensLength(address creator) external view returns (uint256);

    /// @notice Returns a paginated slice of tokens `creator` originally minted.
    function getCreatedTokensSlice(address creator, uint256 start, uint256 count)
        external view returns (uint256[] memory tokenIds);

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

    /// @notice Returns the total number of tokens currently in existence (excludes burned).
    function totalSupply() external view returns (uint256);

    /// @notice Returns the total number of tokens ever minted (includes burned).
    function totalMinted() external view returns (uint256);

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

**Complexity Bounds:** `isEarlyAdopter(account, blockThreshold)` MUST execute in O(n) time where n is the number of tokens created by `account`. Implementations MUST NOT iterate over global token supply.

#### Per-Address Pagination (Anti-Griefing)

10a. `getEverOwnedTokensLength(account)` MUST return the length of the deduplicated `_everOwnedTokens[account]` array.
10b. `getEverOwnedTokensSlice(account, start, count)` MUST return a slice of at most `count` token IDs starting at index `start`.
10c. `getCreatedTokensLength(creator)` MUST return the length of the `_createdTokens[creator]` array.
10d. `getCreatedTokensSlice(creator, start, count)` MUST return a slice of at most `count` token IDs starting at index `start`.
10e. All pagination functions MUST return an empty array if `start >= length`. They MUST NOT revert.

#### Layer 3 — Current Authority

11. Layer 3 MUST behave identically to ERC-721. `ownerOf()`, `balanceOf()`, `transferFrom()`, `safeTransferFrom()`, `approve()`, `setApprovalForAll()`, `getApproved()`, and `isApprovedForAll()` MUST comply with ERC-721.

#### Sybil Protection (Dual-Layer)

17. Contracts SHOULD implement intra-transaction protection using EIP-1153 transient storage to block multiple transfers of the same token within one transaction (A→B→C chains).
18. Contracts SHOULD implement inter-transaction protection to enforce one owner per token per block number across separate transactions. The reference implementation derives this from `_ownershipBlocks[tokenId]` — if the last recorded block equals `block.number`, the transfer reverts. No dedicated `_ownerAtBlock` mapping is needed. When implemented, `block.number` MUST be used instead of `block.timestamp` to prevent validator manipulation.
19. `getOwnerAtBlock(tokenId, blockNumber)` MUST return the owner of `tokenId` at any arbitrary `blockNumber`, not just blocks where a transfer occurred. Implementations SHOULD use O(log n) binary search over the chronological `_ownershipBlocks` array to resolve the last transfer at or before `blockNumber`. Returns `address(0)` if the token was not yet minted at `blockNumber`.
20. `getOwnerAtTimestamp(uint256, uint256)` is DEPRECATED. Implementations MUST keep it for interface backwards compatibility but it MUST be `pure` and MUST always return `address(0)`.
21. Contracts MUST prevent self-transfers (`from == to`) to avoid polluting Layer 2 history without actual ownership change.

#### Burn Behavior

12. When a token is burned, Layer 3 data (current owner) MUST be cleared.
13. When a token is burned, Layer 1 data (`originalCreator`, `mintBlock`) MUST be preserved.
14. When a token is burned, Layer 2 data (`_ownershipHistory`, `_ownershipTimestamps`, `_hasOwnedToken`) MUST be preserved.
15. After burn, `originalCreator(tokenId)` MUST still return the original minter. `getOwnershipHistory(tokenId)` MUST return the preserved history. Implementations MUST use `originalCreator[tokenId]` (not `_currentOwner[tokenId]`) for existence checks in view functions so that Layer 2 queries survive burn.

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
| `HistoricalTokenBurned(uint256 tokenId)` | On burn (Layer 3 cleared, Layer 1 & 2 preserved) |
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
| Mint | ~50,000 | ~332,000 | +564% | 3 layers + dual Sybil guards (EIP-1153 transient + block.number) + history arrays |
| Transfer | ~50,000 | ~170,000 | +240% | 2 SSTOREs (history, timestamp) + Sybil guards + dedup check |
| Burn | ~25,000–45,000 | ~10,000–25,000 | Varies | Depends on storage warmth and refund conditions; Layer 1 & 2 slots are not cleared |
| Read | Free | Free | — | All queries are `view` |

This overhead is acceptable on L2s (Arbitrum, Base, Optimism) where gas is 10–100x cheaper than mainnet. On L1, the higher cost is the explicit trade-off for permanent, trustless provenance with Sybil-resistant block-number tracking.

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

A complete reference implementation is provided in:
- [ERC-721H.sol](../assets/eip-XXXX/ERC-721H.sol) — Core contract (v2.0.0)
- [IERC721H.sol](../assets/eip-XXXX/IERC721H.sol) — Interface (22 functions, 3 events)
- [ERC721HStorageLib.sol](../assets/eip-XXXX/ERC721HStorageLib.sol) — Low-level storage library
- [ERC721HCoreLib.sol](../assets/eip-XXXX/ERC721HCoreLib.sol) — High-level query library
- [ERC721HFactory.sol](../assets/eip-XXXX/ERC721HFactory.sol) — Production factory + collection wrapper (companion, not required for EIP compliance)

### Key Implementation Details

**Architecture (v2.0.0):**

The reference implementation uses a two-library architecture:

- **`ERC721HStorageLib`** — Low-level: HistoryStorage struct, `recordMint()`, `recordTransfer()`, binary search, Sybil guard, pagination.
- **`ERC721HCoreLib`** — High-level: `buildProvenanceReport()`, `getTransferCount()`, `isEarlyAdopter()`.

All library functions are `internal` — inlined at compile time for zero gas overhead.

A companion `ERC721HFactory.sol` provides:
- **`ERC721HCollection`** — Production wrapper: batch minting, supply cap, public mint with pricing/wallet limits, 5 batch historical query functions, configurable metadata URI.
- **`ERC721HFactory`** — Permissionless CREATE2 deployer with deterministic cross-chain addresses and paginated registry.

**Storage Layout (HistoryStorage struct in ERC721HStorageLib):**

```solidity
struct HistoryStorage {
    // Layer 1: Immutable Origin
    mapping(uint256 => address) originalCreator;
    mapping(uint256 => uint256) mintBlock;
    mapping(address => uint256[]) createdTokens;

    // Layer 2: Historical Trail
    mapping(uint256 => address[]) ownershipHistory;
    mapping(uint256 => uint256[]) ownershipTimestamps;
    mapping(uint256 => uint256[]) ownershipBlocks;        // O(log n) binary search support
    mapping(address => uint256[]) everOwnedTokens;
    mapping(uint256 => mapping(address => bool)) hasOwnedToken;
}

// Main contract:
using ERC721HStorageLib for ERC721HStorageLib.HistoryStorage;
using ERC721HCoreLib for ERC721HStorageLib.HistoryStorage;
ERC721HStorageLib.HistoryStorage private _history;
```

Note: The `_ownerAtBlock` mapping (used in versions prior to v1.5.0) has been eliminated. The Sybil guard is now derived from `_ownershipBlocks[tokenId]` — the last entry tells whether the current block already has a recorded transfer. The `getOwnerAtBlock()` query uses O(log n) binary search over `_ownershipBlocks` instead of a direct mapping lookup.

**Mint (virtual wrapper + internal primitive):**

```solidity
/// @notice Public mint — virtual so inheritors can add supply caps, allowlists, etc.
function mint(address to) public virtual onlyOwner returns (uint256) {
    return _mint(to);
}

/// @notice Internal mint — initializes all 3 layers. No access control.
/// @dev Callers MUST enforce authorization before calling.
///      Safe for inheriting contracts to build custom mint paths
///      (batch, public, allowlist) on top of this primitive.
function _mint(address to) internal returns (uint256) {
    if (to == address(0)) revert ZeroAddress();

    uint256 tokenId = _nextTokenId++;

    _beforeTokenTransfer(address(0), to, tokenId);

    // LAYER 1 & 2: Record origin + first history entry (via library)
    _history.recordMint(tokenId, to, block.number, block.timestamp);
    emit OriginalCreatorRecorded(tokenId, to);
    emit OwnershipHistoryRecorded(tokenId, to, block.timestamp);

    // LAYER 3: Set current owner (standard ERC-721)
    _currentOwner[tokenId] = to;
    _balances[to] += 1;
    _activeSupply += 1;

    emit Transfer(address(0), to, tokenId);

    _afterTokenTransfer(address(0), to, tokenId);

    return tokenId;
}
```

**Transfer (updates Layer 2 & 3, preserves Layer 1):**

```solidity
function _transfer(address from, address to, uint256 tokenId)
    internal nonReentrant oneTransferPerTokenPerTx(tokenId)
{
    if (_currentOwner[tokenId] != from) revert NotAuthorized();
    if (to == address(0)) revert ZeroAddress();
    if (from == to) revert InvalidRecipient(); // Prevent self-transfer (history pollution)

    _beforeTokenTransfer(from, to, tokenId);

    delete _tokenApprovals[tokenId];

    // SYBIL GUARD: One owner per token per block number (inter-TX)
    // Derived from _ownershipBlocks via library — zero additional storage.
    if (_history.isSameBlockTransfer(tokenId, block.number)) {
        revert OwnerAlreadyRecordedForBlock();
    }

    // LAYER 2: APPEND to ownership history (via library — auto-deduplicates)
    _history.recordTransfer(tokenId, to, block.number, block.timestamp);
    emit OwnershipHistoryRecorded(tokenId, to, block.timestamp);

    // LAYER 3: Update current owner (standard ERC-721)
    _currentOwner[tokenId] = to;
    _balances[from] -= 1;
    _balances[to] += 1;

    emit Transfer(from, to, tokenId);

    _afterTokenTransfer(from, to, tokenId);
}
```

**Burn (clears Layer 3, preserves Layer 1 & 2):**

```solidity
function burn(uint256 tokenId) public {
    address tokenOwner = ownerOf(tokenId);
    if (msg.sender != tokenOwner && !_isApprovedOrOwner(msg.sender, tokenId)) {
        revert NotApprovedOrOwner();
    }

    // Clear approvals
    delete _tokenApprovals[tokenId];

    // LAYER 1 & 2: PRESERVED (immutable history survives burn)

    // LAYER 3: Remove current owner
    _currentOwner[tokenId] = address(0);
    _balances[tokenOwner] -= 1;
    _activeSupply -= 1;

    emit Transfer(tokenOwner, address(0), tokenId);
    emit HistoricalTokenBurned(tokenId);
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

**Intra-TX Sybil Guard (EIP-1153 transient storage):**

```solidity
modifier oneTransferPerTokenPerTx(uint256 tokenId) {
    assembly {
        let flag := tload(tokenId)
        if eq(flag, 1) {
            let ptr := mload(0x40)
            mstore(ptr, shl(224, 0x96817234)) // TokenAlreadyTransferredThisTx()
            revert(ptr, 4)
        }
        tstore(tokenId, 1)
    }
    _;
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

### Pagination Anti-Griefing

All unbounded arrays (`_ownershipHistory`, `_everOwnedTokens`, `_createdTokens`) expose both full-return and paginated-slice functions. Frontends SHOULD prefer `getHistorySlice()`, `getEverOwnedTokensSlice()`, and `getCreatedTokensSlice()` for tokens or addresses with large histories to avoid RPC response limits or mobile wallet stalls.

### Binary Search Complexity

`getOwnerAtBlock()` uses O(log n) binary search over `_ownershipBlocks`. For a token with 1,000 transfers, this requires at most 10 comparisons — negligible gas for a `view` call. The `_ownershipBlocks` array is append-only and strictly monotonic (enforced by the Sybil guard), which guarantees binary search correctness.

### Burn Does Not Delete

Burning preserves Layer 1 and Layer 2 storage. This means storage slots are **not** refunded on burn, unlike standard ERC-721. This is intentional — the historical data has value — but implementers should document this behavior.

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).

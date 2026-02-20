# ERC-721H: Historical Ownership Extension for ERC-721

> **ERC-721 tells you WHO owns a token. ERC-721H tells you WHO has EVER owned it — on-chain, trustless, and queryable by other contracts.**


---

## The Problem

Standard ERC-721 loses all ownership history the moment a token is transferred. Once Alice sends to Bob, there is **zero on-chain proof** Alice ever held it. The only evidence lives in event logs, which:

- Cannot be read by other smart contracts
- Require off-chain indexers (The Graph, Alchemy) that can go down
- Cannot power on-chain governance or airdrops
- Are dismissed as "indexer output" in legal contexts

## The Solution: Three-Layer Ownership

ERC-721H maintains three parallel layers of ownership data:

```
┌─────────────────────────────────────────────────────────────────┐
│ Layer 1 — Immutable Origin     (write-once at mint)             │
│   originalCreator[tokenId] = Alice                              │
│   mintBlock[tokenId] = 18_500_000                               │
├─────────────────────────────────────────────────────────────────┤
│ Layer 2 — Historical Trail     (append-only, never deleted)     │
│   ownershipHistory[tokenId] = [Alice, Bob, Charlie]             │
│   hasEverOwned[tokenId][Bob] = true        ← O(1) lookup       │
├─────────────────────────────────────────────────────────────────┤
│ Layer 3 — Current Authority    (standard ERC-721)               │
│   ownerOf(tokenId) = Charlie                                    │
└─────────────────────────────────────────────────────────────────┘
```

Layer 1 never changes. Layer 2 only grows. Layer 3 works exactly like ERC-721.

## Use Cases

| Use Case | What ERC-721 Does | What ERC-721H Does |
|:---------|:------------------|:-------------------|
| Art Provenance | Nothing — history lost | Full chain: artist → gallery → collector |
| Founder Benefits | Minter forgotten after transfer | `isOriginalOwner()` returns `true` forever |
| Early Adopter Airdrops | Requires off-chain Merkle proof | `isEarlyAdopter()` — one on-chain call |
| Legal Proof-of-Custody | Event logs (fragile) | Storage slots (tamper-proof) |
| Gaming Veteran Status | Cannot prove past ownership | `hasEverOwned()` — O(1) on-chain |

## Quick Start

### Install

```bash
# Copy the two files into your project
cp IERC721H.sol your-project/contracts/
cp ERC-721H.sol your-project/contracts/
```

### Deploy

```solidity
import {ERC721H} from "./ERC-721H.sol";

contract MyNFT is ERC721H {
    constructor() ERC721H("MyCollection", "MYC") {}

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        // Your metadata logic
    }
}
```

### Interact (ethers.js v6)

```js
const nft = new ethers.Contract(address, ERC721H_ABI, signer);

// Mint
const tx = await nft.mint(recipientAddress);
const rc = await tx.wait();

// Query all three layers
const creator = await nft.originalCreator(tokenId);       // Layer 1
const history = await nft.getOwnershipHistory(tokenId);    // Layer 2
const current = await nft.ownerOf(tokenId);                // Layer 3

// O(1) historical check
const wasHolder = await nft.hasEverOwned(tokenId, someAddress);

// Full provenance in one call
const report = await nft.getProvenanceReport(tokenId);

// Detect ERC-721H support
const isHistorical = await nft.supportsInterface(IERC721H_ID);
```

## API Reference

### Layer 1 — Immutable Origin

| Function | Returns | Gas |
|:---------|:--------|:----|
| `originalCreator(tokenId)` | `address` — who minted it | Free |
| `mintBlock(tokenId)` | `uint256` — block number at mint | Free |
| `isOriginalOwner(tokenId, account)` | `bool` | Free |
| `getOriginallyCreatedTokens(creator)` | `uint256[]` — all tokens minted by address | Free |
| `isEarlyAdopter(account, blockThreshold)` | `bool` — minted before block N? | Free |

### Layer 2 — Historical Trail

| Function | Returns | Gas |
|:---------|:--------|:----|
| `hasEverOwned(tokenId, account)` | `bool` — O(1) mapping lookup | Free |
| `getOwnershipHistory(tokenId)` | `(address[], uint256[])` — owners + timestamps | Free |
| `getTransferCount(tokenId)` | `uint256` — number of transfers | Free |
| `getEverOwnedTokens(account)` | `uint256[]` — all tokens ever held (deduplicated) | Free |
| `getOwnerAtTimestamp(tokenId, timestamp)` | `address` — owner at specific timestamp (Sybil-resistant) | Free |

### Layer 3 — Current Authority (ERC-721 Compatible)

| Function | Returns | Gas |
|:---------|:--------|:----|
| `ownerOf(tokenId)` | `address` | Free |
| `balanceOf(account)` | `uint256` | Free |
| `transferFrom(from, to, tokenId)` | — | ~170,000 |
| `safeTransferFrom(from, to, tokenId)` | — | ~173,000 |
| `approve(to, tokenId)` | — | ~32,000 |
| `setApprovalForAll(operator, approved)` | — | ~38,000 |

### Aggregate

| Function | Returns | Gas |
|:---------|:--------|:----|
| `getProvenanceReport(tokenId)` | Full report (creator, block, owner, transfers, history) | Free |
| `totalSupply()` | `uint256` | Free |

### Lifecycle

| Function | Behavior | Gas |
|:---------|:---------|:----|
| `mint(to)` | Creates token, sets all 3 layers | ~332,000 |
| `burn(tokenId)` | Clears Layer 3, **preserves Layer 1 & 2** | ~10,000 |
| `transferOwnership(newOwner)` | Contract admin transfer | ~25,000 |

## Gas Overhead

| Operation | ERC-721 | ERC-721H | Overhead | Why |
|:----------|:--------|:---------|:---------|:----|
| Mint | ~50,000 | ~332,000 | +564% | 3 layers + Sybil guards (transient + timestamp) + history |
| Transfer | ~50,000 | ~170,000 | +240% | 2 SSTOREs (history, timestamp) + Sybil guards + dedup |
| Burn | ~30,000 | ~10,000 | -67% | Skips refunds — Layer 1 & 2 preserved |
| Read | Free | Free | — | All queries are `view` |

> Acceptable on L2s (Arbitrum, Base, Optimism) where gas is 10–100x cheaper. On L1, this is the explicit trade-off for permanent trustless provenance with dual Sybil protection.

## Security

- **Reentrancy**: `_transfer()` uses `nonReentrant` modifier. All state mutations complete before external calls.
- **Access Control**: `mint()` restricted to `onlyOwner`. `burn()` restricted to token owner or approved.
- **O(1) Lookups**: `hasEverOwned()` uses a dedicated mapping — no unbounded iteration.
- **Deduplication**: `_everOwnedTokens` deduped via `_hasOwnedToken` — wash trading cannot bloat per-address lists.
- **Sybil Protection (Dual-Layer)**:
  - **Intra-TX**: `oneTransferPerTokenPerTx` modifier using EIP-1153 transient storage blocks A→B→C→D chains within one transaction
  - **Inter-TX**: `ownerAtTimestamp` mapping enforces one owner per token per block timestamp across separate transactions
- **ERC-165**: `supportsInterface()` returns `true` for ERC-165, ERC-721, ERC-721 Metadata, and IERC721H.

## Repository Structure

```

1. **Interface**: `IERC721H.sol` — 13 functions, 2 events
2. **Reference Implementation**: `ERC-721H.sol` — fully functional, zero compiler warnings
3. **EIP Document**: `EIP-721H.md` — Preamble, Abstract, Motivation, Specification (16 behavioral requirements), Rationale, Backwards Compatibility, Reference Implementation, Security Considerations
4. **Status**: Draft
5. **Category**: Standards Track → ERC
6. **Requires**: EIP-165, EIP-721


## Backwards Compatibility

ERC-721H is a **strict superset** of ERC-721. Every ERC-721H token is a valid ERC-721 token. Wallets (MetaMask, Rainbow), marketplaces (OpenSea, Blur), and libraries (ethers.js, viem, wagmi) work without modification. The historical layer is purely additive.

## Author

**Emiliano Solazzi** — 2026

## License

[MIT](LICENSE)

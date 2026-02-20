# ERC-721H: Historical Ownership Extension for ERC-721

> **v2.0.0** — Library architecture + production factory
>
> **ERC-721 tells you WHO owns a token. ERC-721H tells you WHO has EVER owned it — on-chain, trustless, and queryable by other contracts.**

---

## The Problem

Standard ERC-721 loses all ownership history the moment a token is transferred. Once Alice sends to Bob, there is **no storage-level ownership record** accessible to other smart contracts. The only evidence lives in event logs, which:

- Cannot be read by other smart contracts (no EVM opcode for log access)
- Require off-chain indexers (The Graph, Alchemy) that can go down
- Cannot power on-chain governance or airdrops
- Require off-chain reconstruction for any practical use

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
| Proof-of-Custody | Event logs (off-chain reconstruction) | Storage slots (contract-queryable) |
| Gaming Veteran Status | Cannot prove past ownership | `hasEverOwned()` — O(1) on-chain |

## Quick Start

### Install

```bash
# Copy all source files into your project
cp IERC721H.sol           your-project/contracts/
cp ERC-721H.sol           your-project/contracts/
cp ERC721HStorageLib.sol  your-project/contracts/
cp ERC721HCoreLib.sol     your-project/contracts/
cp ERC721HFactory.sol     your-project/contracts/  # optional — factory + collection
```

### Deploy (Direct)

```solidity
import {ERC721H} from "./ERC-721H.sol";

contract MyNFT is ERC721H {
    constructor() ERC721H("MyCollection", "MYC") {}

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        // Your metadata logic
    }
}
```

### Deploy (Factory — Recommended for Production)

```js
const factory = new ethers.Contract(FACTORY_ADDRESS, FACTORY_ABI, signer);
const salt = ethers.id("my-unique-salt");

// Predict address before deploying (same on any EVM chain)
const predicted = await factory.predictAddress(
  "Founders", "FNDR", 10000, "https://api.example.com/meta/",
  salt, await signer.getAddress()
);

// Deploy via CREATE2 — ownership auto-transfers to caller
const tx = await factory.deployCollection(
  "Founders", "FNDR", 10000, "https://api.example.com/meta/", salt
);
const rc = await tx.wait();
```

The factory deploys `ERC721HCollection` instances — production wrappers with batch minting, supply caps, public mint with pricing, and batch historical queries.

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

// Historical owner at any arbitrary block — O(log n) binary search
const pastOwner = await nft.getOwnerAtBlock(tokenId, 18_500_000);

// Full provenance in one call
const report = await nft.getProvenanceReport(tokenId);

// Paginated queries (anti-griefing for large histories)
const [slice, times] = await nft.getHistorySlice(tokenId, 0, 50);
const ownedSlice = await nft.getEverOwnedTokensSlice(alice, 0, 50);

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
| `getOwnerAtBlock(tokenId, blockNumber)` | `address` — O(log n) binary search over `_ownershipBlocks` | Free |
| `getOwnerAtTimestamp(tokenId, timestamp)` | **DEPRECATED** — always returns `address(0)`. Use `getOwnerAtBlock`. | Free |
| `getHistoryLength(tokenId)` | `uint256` — entries in ownership history | Free |
| `getHistorySlice(tokenId, start, count)` | `(address[], uint256[])` — paginated slice (anti-griefing) | Free |
| `getEverOwnedTokensLength(account)` | `uint256` — total tokens ever held by address | Free |
| `getEverOwnedTokensSlice(account, start, count)` | `uint256[]` — paginated per-address token list | Free |
| `getCreatedTokensLength(creator)` | `uint256` — total tokens minted by address | Free |
| `getCreatedTokensSlice(creator, start, count)` | `uint256[]` — paginated per-creator token list | Free |

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
| `totalSupply()` | `uint256` — active tokens (excludes burned) | Free |
| `totalMinted()` | `uint256` — all-time minted (includes burned) | Free |

### Lifecycle

| Function | Behavior | Gas |
|:---------|:---------|:----|
| `mint(to)` | Creates token, sets all 3 layers (`virtual` — overridable) | ~332,000 |
| `_mint(to)` | Internal primitive — no access control. Used by inheritors for custom mint paths (batch, public, allowlist). | ~332,000 |
| `burn(tokenId)` | Clears Layer 3, **preserves Layer 1 & 2** | ~10,000–25,000 |
| `transferOwnership(newOwner)` | Contract admin transfer | ~25,000 |

### ERC721HCollection (via ERC721HFactory)

| Function | Behavior | Gas |
|:---------|:---------|:----|
| `batchMint(to, quantity)` | Owner-only batch mint to one address | ~332k × n |
| `batchMintTo(recipients[])` | Owner-only airdrop — one token per address | ~332k × n |
| `publicMint(quantity)` | Payable public mint with per-wallet limits + supply cap | ~332k × n |
| `batchTokenSummary(tokenIds[])` | Batch provenance: creator, block, owner, transfer count | Free |
| `batchOwnerAtBlock(tokenIds[], block)` | Batch historical snapshot — O(log n) per token | Free |
| `batchHasEverOwned(tokenIds[], account)` | Batch ownership check — O(1) per token | Free |
| `batchOriginalCreator(tokenIds[])` | Batch creator lookup | Free |
| `batchTransferCount(tokenIds[])` | Batch activity metric | Free |
| `setBaseURI(uri)` / `setMintPrice(price)` / `setMaxPerWallet(n)` / `togglePublicMint()` | Admin configuration | ~25k each |
| `withdraw()` | Withdraw all ETH revenue to owner | ~25k |

## Gas Overhead

| Operation | ERC-721 | ERC-721H | Overhead | Why |
|:----------|:--------|:---------|:---------|:----|
| Mint | ~50,000 | ~332,000 | +564% | 3 layers + Sybil guards (EIP-1153 transient + block.number) + history |
| Transfer | ~50,000 | ~170,000 | +240% | 2 SSTOREs (history, block) + Sybil guards + dedup |
| Burn | ~30,000 | ~10,000–25,000 | -67% to -17% | Skips refunds — Layer 1 & 2 preserved; varies with storage warmth |
| Read | Free | Free | — | All queries are `view` |

> More suitable for rollups (Arbitrum, Base, Optimism) where write costs are significantly lower. On L1, this is the explicit trade-off for permanent trustless provenance with dual Sybil protection. Gas numbers are approximate cold-path measurements; actual costs vary with storage warmth and network conditions.

## Security

- **Reentrancy**: `_transfer()` uses `nonReentrant` modifier with dedicated `Reentrancy()` error. All state mutations complete before external calls.
- **Access Control**: `mint()` restricted to `onlyOwner`. `burn()` restricted to token owner or approved.
- **O(1) Lookups**: `hasEverOwned()` uses a dedicated mapping — no unbounded iteration.
- **Deduplication**: `_everOwnedTokens` deduped via `_hasOwnedToken` — wash trading cannot bloat per-address lists.
- **Self-Transfer Prevention**: `from == to` reverts with `InvalidRecipient()` — blocks history pollution without real ownership change.
- **Burn Semantics**: `totalSupply()` decrements on burn; `totalMinted()` does not. `HistoricalTokenBurned` event signals Layer-3-only deletion to indexers.
- **Sybil Protection (Dual-Layer)**:
  - **Intra-TX**: `oneTransferPerTokenPerTx` modifier using EIP-1153 transient storage blocks A→B→C→D chains within one transaction
  - **Inter-TX**: Derived from `_ownershipBlocks[tokenId]` — if the last recorded block equals `block.number`, the transfer reverts with `OwnerAlreadyRecordedForBlock()`. No dedicated mapping needed (eliminated in v1.5.0). Uses `block.number`, not `block.timestamp`, to prevent validator manipulation.
- **O(log n) Historical Queries**: `getOwnerAtBlock()` uses binary search over `_ownershipBlocks[]` to resolve the owner at any arbitrary past block — not just transfer blocks.
- **ERC-165**: `supportsInterface()` returns `true` for ERC-165, ERC-721, ERC-721 Metadata, and IERC721H. The ERC-721H interface ID is computed deterministically as `type(IERC721H).interfaceId` (XOR of all function selectors in the interface).

## Repository Structure

```
empty_src/
├── IERC721H.sol            Interface — 22 functions, 3 events
├── ERC-721H.sol            Core contract (v2.0.0) — 3-layer ownership
├── ERC721HStorageLib.sol   Library — low-level storage, Sybil guard, binary search, pagination
├── ERC721HCoreLib.sol      Library — provenance report, transfer count, early adopter
├── ERC721HFactory.sol      Factory (CREATE2) + ERC721HCollection (production wrapper)
├── ERC-721H-Frontend.md    Frontend integration guide (ethers.js v6)
├── EIP-721H.md             EIP specification
└── README.md               This file
```

1. **Interface**: `IERC721H.sol` — 22 functions, 3 events
2. **Core Implementation**: `ERC-721H.sol` — v2.0.0, library architecture (1 intentional warning: unused parameter in deprecated `getOwnerAtTimestamp`)
3. **Storage Library**: `ERC721HStorageLib.sol` — HistoryStorage struct, recordMint/recordTransfer, binary search, Sybil guard, pagination
4. **Core Library**: `ERC721HCoreLib.sol` — buildProvenanceReport, getTransferCount, isEarlyAdopter
5. **Factory + Collection**: `ERC721HFactory.sol` — permissionless CREATE2 deployer + production wrapper with batch mint, batch queries, supply cap, public mint
6. **EIP Document**: `EIP-721H.md` — Preamble, Abstract, Motivation, Specification (21 behavioral requirements), Rationale, Backwards Compatibility, Reference Implementation, Security Considerations
7. **Status**: Draft
8. **Category**: Standards Track → ERC
9. **Requires**: EIP-165, EIP-721


## Architecture (v2.0.0)

```
┌───────────────────────────────────────────────────┐
│  ERC721HFactory (permissionless CREATE2 deployer) │
│    → deploys ERC721HCollection instances           │
│    → registry + predictAddress for cross-chain     │
├───────────────────────────────────────────────────┤
│  ERC721HCollection (production wrapper)            │
│    inherits ERC721H                                │
│    + batch minting (batchMint, batchMintTo)        │
│    + public mint (price, per-wallet limits, cap)   │
│    + 5 batch historical query functions            │
│    + configurable metadata URI + withdraw          │
├───────────────────────────────────────────────────┤
│  ERC-721H.sol (core contract)                      │
│    uses ERC721HStorageLib  (storage, Sybil, search)│
│    uses ERC721HCoreLib     (provenance, analytics) │
└───────────────────────────────────────────────────┘
```

- `_mint()` is `internal` — inheritors build custom mint paths on top
- `mint()` is `virtual` — overridable with supply caps, allowlists, etc.
- Libraries use `internal` functions → inlined at compile time, zero external call overhead
- Factory deploys full contracts (not clones) → no delegatecall risks, no initializer footguns
- CREATE2 with deployer-mixed salt → deterministic cross-chain addresses, front-run resistant

## Backwards Compatibility

ERC-721H is a **strict superset** of ERC-721. Every ERC-721H token is a valid ERC-721 token. Wallets (MetaMask, Rainbow), marketplaces (OpenSea, Blur), and libraries (ethers.js, viem, wagmi) work without modification. The historical layer is purely additive. ERC721HCollection inherits full ERC-721 compatibility.

## Author

**Emiliano Solazzi** — 2026

## License

[MIT](LICENSE)

# ERC-721H Frontend Integration Guide

## 1. Quick Start (ethers.js v6)

```js
import { ethers } from "ethers";

const provider = new ethers.BrowserProvider(window.ethereum);
const signer   = await provider.getSigner();
const nft      = new ethers.Contract(NFT_ADDRESS, ERC721H_ABI, signer);

// ── Mint ──────────────────────────────────────────────
const tx = await nft.mint(await signer.getAddress());
const receipt = await tx.wait();

// Safe log parsing: ERC-721H emits multiple events per mint,
// so filter by name instead of relying on index order.
const transferEvent = receipt.logs
  .map(log => { try { return nft.interface.parseLog(log); } catch { return null; } })
  .find(parsed => parsed?.name === "Transfer");
const tokenId = transferEvent.args.tokenId;        // BigInt
console.log("Minted token", tokenId.toString());
// NOTE: ethers v6 returns BigInt. Use .toString() for display
// or Number(tokenId) for small collections only.

// ── Transfer ──────────────────────────────────────────
await (await nft.transferFrom(alice, bob, tokenId)).wait();
await (await nft.transferFrom(bob, charlie, tokenId)).wait();
// History now: [alice, bob, charlie]

// ── Read Three-Layer Model ────────────────────────────
const creator = await nft.originalCreator(tokenId);     // Layer 1 – immutable
const [owners, timestamps] = await nft.getOwnershipHistory(tokenId); // Layer 2 – [addresses], [timestamps]
const current = await nft.ownerOf(tokenId);              // Layer 3 – current

// ── Provenance Check ──────────────────────────────────
const wasFounder = await nft.hasEverOwned(tokenId, founder);  // O(1) lookup
const minted     = await nft.getOriginallyCreatedTokens(alice);

// ── Historical Owner Query (any arbitrary block) ──────
const ownerAtBlock = await nft.getOwnerAtBlock(tokenId, blockNumber);
// O(log n) binary search — returns the owner at ANY block, not just transfer blocks.
// Returns address(0) only if the token was not yet minted at that block.
// UX: display "Not yet minted" for address(0) — do NOT show raw 0x000...000.
// getOwnerAtTimestamp() is DEPRECATED — always returns address(0)

// ── Collection Stats ──────────────────────────────────
const active = await nft.totalSupply();   // excludes burned tokens
const minted2 = await nft.totalMinted();  // includes burned tokens

// ── Pagination (anti-griefing for large histories) ────
// PREFER getHistorySlice() over getOwnershipHistory() for scalable UIs.
// getOwnershipHistory() returns the full array — safe for small histories,
// but can hit RPC response limits or stall mobile wallets on heavily-traded tokens.
const len = await nft.getHistoryLength(tokenId);
const [slice, times] = await nft.getHistorySlice(tokenId, 0, 50);

// ── Per-Address Pagination (anti-griefing for prolific holders) ──
const ownedCount = await nft.getEverOwnedTokensLength(alice);
const ownedSlice = await nft.getEverOwnedTokensSlice(alice, 0, 50);
const createdCount = await nft.getCreatedTokensLength(alice);
const createdSlice = await nft.getCreatedTokensSlice(alice, 0, 50);

// ── Burn (preserves Layer 1 & 2) ──────────────────────
await (await nft.burn(tokenId)).wait();
// totalSupply() decrements; totalMinted() unchanged
// originalCreator() and getOwnershipHistory() still return data
```

## 2. Demo: Frontend Panels

### Token Provenance Panel (Base ERC-721H)
```
 ┌────────────────────────────────────────────────┐
 │  Token #1 – Provenance Report                  │
 ├────────────────────────────────────────────────┤
 │  Original Creator : 0xAlic...e   (Layer 1)     │
 │  Current Owner    : 0xChar...ie  (Layer 3)     │
 │  Total Supply     : 42  (active, excl. burned) │
 │  Total Minted     : 45  (historical, all-time)  │
 │                                                │
 │  Ownership History (Layer 2):                  │
 │    1. 0xAlic...e   — minted                    │
 │    2. 0xBob...b    — transfer                  │
 │    3. 0xChar...ie  — transfer                  │
 │                                                │
 │  hasEverOwned(0xBob) : true   (O(1) lookup)    │
 │  Originally Created  : [#1, #7, #12]           │
 └────────────────────────────────────────────────┘
```

### Collection Dashboard (ERC721HCollection)
```
 ┌────────────────────────────────────────────────┐
 │  Founders – Collection Overview                │
 ├────────────────────────────────────────────────┤
 │  Contract   : 0x1234...abcd  (CREATE2)         │
 │  Max Supply : 10,000                           │
 │  Minted     : 3,241 / 10,000                   │
 │  Mint Price : 0.01 ETH                         │
 │  Per-Wallet : 5 max                            │
 │  Public Mint: ✅ Enabled                        │
 │                                                │
 │  Batch Summary (tokens #0–#4):                 │
 │    #0  creator: 0xAlic  owner: 0xBob   txs: 3  │
 │    #1  creator: 0xAlic  owner: 0xAlic  txs: 0  │
 │    #2  creator: 0xAlic  owner: burned  txs: 1  │
 │    #3  creator: 0xCharl owner: 0xCharl txs: 0  │
 │    #4  creator: 0xDave  owner: 0xEve   txs: 2  │
 │                                                │
 │  Revenue Balance: 32.41 ETH  [Withdraw]        │
 └────────────────────────────────────────────────┘
```

### Factory Registry Panel (ERC721HFactory)
```
 ┌────────────────────────────────────────────────┐
 │  ERC721HFactory – Deployment Registry          │
 ├────────────────────────────────────────────────┤
 │  Total Deployed : 47 collections               │
 │                                                │
 │  My Collections (deployer: 0xAlic...e):        │
 │    1. Founders (FNDR)   — 0x1234...abcd        │
 │    2. Gems (GEM)        — 0x5678...ef01        │
 │                                                │
 │  [Deploy New Collection]                       │
 │    Name:      ___________                      │
 │    Symbol:    ___________                      │
 │    Max Supply: ___________  (0 = unlimited)    │
 │    Base URI:  ___________                      │
 │    Salt:      ___________                      │
 │                                                │
 │  Predicted Address: 0xabcd...1234              │
 │  (Same address on Arbitrum / Base / Optimism)  │
 └────────────────────────────────────────────────┘
```

## 3. Comparison Chart

> Comparison vs **minimal ERC-721** (non-enumerable). ERC-721Enumerable adds supply tracking but not provenance.

| Feature                          | ERC-721          | ERC-721H              | ERC721HCollection     |
|:---------------------------------|:-----------------|:----------------------|:----------------------|
| Track current owner              | Yes              | Yes                   | Yes                   |
| Track original creator           | No               | Yes (immutable)       | Yes (immutable)       |
| Track full ownership history     | No (events only) | Yes (on-chain array)  | Yes (on-chain array)  |
| `hasEverOwned()` lookup          | N/A              | O(1) via mapping      | O(1) + batch          |
| Airdrop to original minters      | No               | Yes (`getOriginallyCreatedTokens`) | Yes + `batchMintTo` |
| Founder / early-adopter benefits | No               | Yes (survives transfer) | Yes (survives transfer) |
| Provenance proof                 | Fragile (logs)   | Solid (native)        | Solid + batch queries |
| History survives burn            | No               | Yes (Layer 1 & 2 persist) | Yes (Layer 1 & 2 persist) |
| Reentrancy protection            | Varies           | Built-in (`nonReentrant`) | Inherited             |
| Access-controlled mint           | Varies           | `onlyOwner`           | Owner + public paths  |
| Burn support                     | Varies           | Yes (owner/approved)  | Yes (owner/approved)  |
| Sybil protection                 | No               | Yes (dual-layer: EIP-1153 tstore + block.number) | Inherited |
| `totalSupply()` (active)         | No (ERC-721Enum) | Yes (excludes burned) | Yes (excludes burned) |
| `totalMinted()` (historical)     | No               | Yes (includes burned) | Yes (includes burned) |
| Pagination (`getHistorySlice`)   | N/A              | Yes (anti-griefing)   | Yes (anti-griefing)   |
| Supply cap (immutable)           | Manual           | No                    | Yes (`MAX_SUPPLY`)    |
| Batch minting                    | No               | No                    | Yes (`batchMint`, `batchMintTo`) |
| Public mint (payable)            | Manual           | No                    | Yes (price + per-wallet limits) |
| Batch historical queries         | No               | No                    | Yes (5 batch view functions) |
| Configurable metadata URI        | Manual           | No                    | Yes (`setBaseURI`)    |
| Revenue withdrawal               | Manual           | No                    | Yes (`withdraw()`)    |
| Deterministic deployment (CREATE2) | No             | No                    | Yes (via ERC721HFactory) |

## 4. Key ABI Snippets

### 4a. Base ERC-721H ABI

```json
[
  "function mint(address to) external returns (uint256)",
  "function burn(uint256 tokenId) external",
  "function transferFrom(address from, address to, uint256 tokenId) external",
  "function safeTransferFrom(address from, address to, uint256 tokenId) external",
  "function safeTransferFrom(address from, address to, uint256 tokenId, bytes data) external",
  "function approve(address to, uint256 tokenId) external",
  "function setApprovalForAll(address operator, bool approved) external",
  "function getApproved(uint256 tokenId) view returns (address)",
  "function isApprovedForAll(address account, address operator) view returns (bool)",
  "function ownerOf(uint256 tokenId) view returns (address)",
  "function balanceOf(address account) view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function totalMinted() view returns (uint256)",
  "function tokenURI(uint256 tokenId) view returns (string)",
  "function originalCreator(uint256 tokenId) view returns (address)",
  "function mintBlock(uint256 tokenId) view returns (uint256)",
  "function isOriginalOwner(uint256 tokenId, address account) view returns (bool)",
  "function isCurrentOwner(uint256 tokenId, address account) view returns (bool)",
  "function hasEverOwned(uint256 tokenId, address account) view returns (bool)",
  "function getOwnershipHistory(uint256 tokenId) view returns (address[], uint256[])",
  "function getTransferCount(uint256 tokenId) view returns (uint256)",
  "function getEverOwnedTokens(address account) view returns (uint256[])",
  "function getOriginallyCreatedTokens(address creator) view returns (uint256[])",
  "function isEarlyAdopter(address account, uint256 blockThreshold) view returns (bool)",
  "function getOwnerAtBlock(uint256 tokenId, uint256 blockNumber) view returns (address)",
  "function getOwnerAtTimestamp(uint256 tokenId, uint256 timestamp) pure returns (address)",
  "function getHistoryLength(uint256 tokenId) view returns (uint256)",
  "function getHistorySlice(uint256 tokenId, uint256 start, uint256 count) view returns (address[], uint256[])",
  "function getEverOwnedTokensLength(address account) view returns (uint256)",
  "function getEverOwnedTokensSlice(address account, uint256 start, uint256 count) view returns (uint256[])",
  "function getCreatedTokensLength(address creator) view returns (uint256)",
  "function getCreatedTokensSlice(address creator, uint256 start, uint256 count) view returns (uint256[])",
  "function getProvenanceReport(uint256 tokenId) view returns (address, uint256, address, uint256, address[], uint256[])",
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function owner() view returns (address)",
  "function transferOwnership(address newOwner) external"
]
```

### 4b. ERC721HCollection ABI (extends Base)

Includes all Base ABI functions above, plus:

```json
[
  "function MAX_SUPPLY() view returns (uint256)",
  "function mintPrice() view returns (uint256)",
  "function publicMintEnabled() view returns (bool)",
  "function maxPerWallet() view returns (uint256)",
  "function publicMintCount(address) view returns (uint256)",
  "function batchMint(address to, uint256 quantity) external returns (uint256[])",
  "function batchMintTo(address[] recipients) external returns (uint256[])",
  "function publicMint(uint256 quantity) payable returns (uint256[])",
  "function batchTokenSummary(uint256[] tokenIds) view returns (tuple(uint256 tokenId, address creator, uint256 creationBlock, address currentOwner, uint256 transferCount)[])",
  "function batchOwnerAtBlock(uint256[] tokenIds, uint256 blockNumber) view returns (address[])",
  "function batchHasEverOwned(uint256[] tokenIds, address account) view returns (bool[])",
  "function batchOriginalCreator(uint256[] tokenIds) view returns (address[])",
  "function batchTransferCount(uint256[] tokenIds) view returns (uint256[])",
  "function setBaseURI(string newBaseURI) external",
  "function setMintPrice(uint256 newPrice) external",
  "function setMaxPerWallet(uint256 newMax) external",
  "function togglePublicMint() external",
  "function withdraw() external"
]
```

### 4c. ERC721HFactory ABI

```json
[
  "function deployCollection(string name_, string symbol_, uint256 maxSupply_, string baseURI_, bytes32 salt) external returns (address)",
  "function predictAddress(string name_, string symbol_, uint256 maxSupply_, string baseURI_, bytes32 salt, address deployer) view returns (address)",
  "function isCollection(address) view returns (bool)",
  "function totalDeployed() view returns (uint256)",
  "function getCollections(uint256 start, uint256 count) view returns (address[])",
  "function getDeployerCollections(address deployer) view returns (address[])",
  "function getCollectionCount() view returns (uint256)",
  "event CollectionDeployed(address indexed collection, address indexed deployer, string name, string symbol, uint256 maxSupply, bytes32 salt)"
]
```

## 5. Gas Estimates

### Base ERC-721H

| Operation  | ERC-721   | ERC-721H  | Overhead |
|:-----------|:----------|:----------|:---------|
| Mint       | ~50,000   | ~332,000  | +564%    |
| Transfer   | ~50,000   | ~170,000  | +240%    |
| Burn       | ~30,000   | ~10,000   | -67%     |
| Read history | Free    | Free      | —        |

### ERC721HCollection (batch operations)

| Operation               | Gas (approx)            | Notes                                |
|:------------------------|:------------------------|:-------------------------------------|
| `batchMint(to, 10)`     | ~3,200,000              | Amortizes 21k TX base across 10 mints |
| `batchMintTo(10 addrs)` | ~3,200,000              | Same as batchMint, different recipients |
| `publicMint(3)`         | ~1,000,000              | Includes payment + wallet limit checks |
| `batchTokenSummary(5)`  | Free (view)             | 5 provenance lookups in one RPC call |
| `batchOwnerAtBlock(5)`  | Free (view)             | 5 × O(log n) binary searches         |
| `batchHasEverOwned(5)`  | Free (view)             | 5 × O(1) mapping lookups             |
| Factory `deployCollection` | ~4,500,000           | Full CREATE2 deploy (pennies on L2)  |

> **Trade-off**: Higher write gas for permanent on-chain provenance with dual Sybil protection.
>
> Gas numbers are approximate cold-path measurements. Actual costs vary with storage warmth, approval state, and L1 vs L2.
> On L2 (Arbitrum/Base/Optimism), batch minting 10 tokens costs < $0.10.

## 6. Same-Block Transfer Limit

⚠️ The dual Sybil guard enforces **one transfer per token per block** (and one per transaction).

If a user tries to transfer a token that already moved in the current block, the transaction reverts with `OwnerAlreadyRecordedForBlock()`.

**Frontend handling:**
```js
try {
  await (await nft.transferFrom(from, to, tokenId)).wait();
} catch (err) {
  if (err.message.includes("OwnerAlreadyRecordedForBlock")) {
    alert("This token was already transferred this block. Please retry next block.");
  }
}
```

Marketplaces should surface a friendly message — this is intentional Sybil protection, not a bug.

## 7. ERC721HCollection Error Handling

The Collection adds its own revert reasons on top of the base ERC-721H errors:

```js
try {
  await (await collection.publicMint(3, { value: ethers.parseEther("0.01") })).wait();
} catch (err) {
  const msg = err.message;
  if (msg.includes("PublicMintDisabled"))    alert("Public minting is not open yet.");
  if (msg.includes("InsufficientPayment"))   alert("Not enough ETH — check mint price.");
  if (msg.includes("MaxSupplyExceeded"))     alert("Collection is sold out.");
  if (msg.includes("MaxPerWalletExceeded"))  alert("Wallet limit reached.");
  if (msg.includes("QuantityZero"))          alert("Must mint at least 1.");
}
```

## 8. Indexer Integration

Unlike standard ERC-721, ERC-721H does **not** require off-chain indexers to reconstruct ownership history:

| Capability | ERC-721 | ERC-721H | ERC721HCollection |
|:-----------|:--------|:---------|:-------------------|
| Current owner | On-chain | On-chain | On-chain |
| Full ownership history | Requires indexer (The Graph, Alchemy) | On-chain (`getOwnershipHistory`) | On-chain (inherited) |
| "Has ever owned?" check | Requires indexer | On-chain O(1) (`hasEverOwned`) | O(1) + batch (`batchHasEverOwned`) |
| Original minter | Requires indexer | On-chain (`originalCreator`) | On-chain + batch (`batchOriginalCreator`) |
| Governance snapshot | Requires indexer | On-chain (`getOwnerAtBlock`) | Batch (`batchOwnerAtBlock`) |
| Provenance summary | Requires indexer | `getProvenanceReport` | Batch (`batchTokenSummary`) |

Subgraphs become **optional** — useful for caching and UI performance, but no longer mandatory for correctness. The source of truth lives in contract storage, not event logs.

## 9. Architecture: v2.0.0 Library Pattern

ERC-721H v2.0.0 uses a two-library architecture for composability:

```
┌─────────────────────────────────────────────────────┐
│  ERC721HCollection (production wrapper)              │
│    ↕ inherits                                       │
│  ERC-721H.sol (core contract)                       │
│    ↕ uses                                           │
│  ERC721HStorageLib  (low-level: storage, Sybil,     │
│                      binary search, pagination)     │
│  ERC721HCoreLib     (high-level: provenance report, │
│                      transfer count, early adopter) │
└─────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│  ERC721HFactory (permissionless CREATE2 deployer)    │
│    → deploys → ERC721HCollection instances           │
│    → registry: isCollection, getCollections,         │
│                getDeployerCollections                │
│    → predictAddress for cross-chain coordination     │
└─────────────────────────────────────────────────────┘
```

**Key design decisions:**
- `_mint()` is `internal` — subclasses (like ERC721HCollection) build custom mint paths on top
- `mint()` is `virtual` — inheritors can override with supply caps, allowlists, etc.
- Libraries use `internal` functions → inlined at compile time, zero external call overhead
- Factory uses full deploys (not clones) → no delegatecall risks, no initializer footguns

# ERC-721H Frontend Integration Guide

## 1. Quick Start (ethers.js v6)

```js
import { ethers } from "ethers";

const provider = new ethers.BrowserProvider(window.ethereum);
const signer   = await provider.getSigner();
const nft      = new ethers.Contract(NFT_ADDRESS, ERC721H_ABI, signer);

// ── Mint ──────────────────────────────────────────────
const tx = await nft.mint(await signer.getAddress());
const rc = await tx.wait();
const tokenId = rc.logs[0].args.tokenId;          // BigInt
console.log("Minted token", tokenId.toString());

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

// ── Collection Stats ──────────────────────────────────
const supply = await nft.totalSupply();

// ── Burn (preserves Layer 1 & 2) ──────────────────────
await (await nft.burn(tokenId)).wait();
// originalCreator() and getOwnershipHistory() still return data
```

## 2. Demo: Frontend Panel

```
 ┌────────────────────────────────────────────────┐
 │  Token #1 – Provenance Report                  │
 ├────────────────────────────────────────────────┤
 │  Original Creator : 0xAlic...e   (Layer 1)     │
 │  Current Owner    : 0xChar...ie  (Layer 3)     │
 │  Total Supply     : 42                         │
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

## 3. Comparison Chart

| Feature                          | ERC-721          | ERC-721H              |
|:---------------------------------|:-----------------|:----------------------|
| Track current owner              | Yes              | Yes                   |
| Track original creator           | No               | Yes (immutable)       |
| Track full ownership history     | No (events only) | Yes (on-chain array)  |
| `hasEverOwned()` lookup          | N/A              | O(1) via mapping      |
| Airdrop to original minters      | No               | Yes (`getOriginallyCreatedTokens`) |
| Founder / early-adopter benefits | No               | Yes (survives transfer) |
| Provenance proof                 | Fragile (logs)   | Solid (native)        |
| History survives burn            | No               | Yes (Layer 1 & 2 persist) |
| Reentrancy protection            | Varies           | Built-in (`nonReentrant`) |
| Access-controlled mint           | Varies           | `onlyOwner`           |
| Burn support                     | Varies           | Yes (owner/approved)  |
| Sybil protection                 | No               | Yes (dual-layer: tstore + timestamp) |
| `totalSupply()`                  | No (ERC-721Enum) | Yes (built-in)        |

## 4. Key ABI Snippet

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
  "function getOwnerAtTimestamp(uint256 tokenId, uint256 timestamp) view returns (address)",
  "function getProvenanceReport(uint256 tokenId) view returns (address, uint256, address, uint256, address[], uint256[])",
  "function transferOwnership(address newOwner) external"
]
```

## 5. Gas Estimates

| Operation  | ERC-721   | ERC-721H  | Overhead |
|:-----------|:----------|:----------|:---------|
| Mint       | ~50,000   | ~332,000  | +564%    |
| Transfer   | ~50,000   | ~170,000  | +240%    |
| Burn       | ~30,000   | ~10,000   | -67%     |
| Read history | Free    | Free      | —        |

> **Trade-off**: Higher write gas for permanent on-chain provenance with dual Sybil protection.

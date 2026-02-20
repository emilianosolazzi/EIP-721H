// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC721H} from "./IERC721H.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";

/**
 * @title ERC-721H: NFT with Historical Ownership Tracking
 * @author Emiliano Solazzi - 2026
 * @notice Revolutionary NFT standard that preserves complete ownership history on-chain
 * @dev Implements three-layer ownership model:
 *      Layer 1: Immutable Origin (who created/minted)
 *      Layer 2: Historical Trail (everyone who ever owned)
 *      Layer 3: Current Authority (who owns now)
 * 
 * WHY THIS MATTERS:
 * Standard ERC-721 loses ownership history on transfer. Once Alice transfers to Bob,
 * there's no on-chain proof Alice ever owned it (unless you index events, which is
 * fragile and gas-expensive). This breaks provenance, makes airdrops to "early adopters"
 * impossible, and prevents founder benefits that survive transfers.
 * 
 * ERC-721H solves this by maintaining THREE mappings:
 * 1. originalCreator[tokenId] → IMMUTABLE first owner (never changes)
 * 2. ownershipHistory[tokenId] → APPEND-ONLY list of all owners
 * 3. currentOwner[tokenId] → MUTABLE present owner (standard ERC-721)
 * 
 * REAL-WORLD USE CASES:
 * - Art NFTs: Prove provenance chain (artist → gallery → collector)
 * - Governance: Grant permanent board seats to founding members even after they sell
 * - Airdrops: Reward original adopters even if they transferred
 * - Legal disputes: On-chain proof of first registration for recovery/inheritance
 * - Gaming: Show "veteran" status based on original mint, not current ownership
 * 
 * GAS COSTS:
 * - Mint: ~332,000 gas (standard: ~50,000) +564% for 3-layer init + dual Sybil guards
 * - Transfer: ~170,000 gas (standard: ~50,000) +240% for history append + Sybil guards
 * - Burn: ~10,000 gas (standard: ~30,000) -67% — skips refunds, preserves history
 * - Read history: Free (view function)
 * 
 * TRADE-OFF: Higher write gas for PERMANENT on-chain provenance with dual Sybil protection.
 *            On L2s (Arbitrum, Base, Optimism) where gas is 10-100x cheaper, this is negligible.
 * 
 * L1 vs L2 ECONOMICS:
 * - Mainnet: 100+ byte-hours of storage per transfer = $50-500 per NFT lifecycle
 * - Arbitrum/Base: 1-5 byte-hours = $0.01-0.10 per NFT lifecycle (1000x cheaper)
 * 
 * RECOMMENDED DEPLOYMENT:
 * - Production NFTs: Arbitrum/Base/Optimism (Layer 2)
 * - Collections <1000 tokens: Mainnet if willing to accept L1 cost
 * - High-turnover NFTs: Only deploy on L2
 * 
 * @custom:version 1.5.0
 */
contract ERC721H is IERC721H, IERC721, IERC721Metadata { 
    // ==========================================
    // ERRORS
    // ==========================================
    
    error NotAuthorized();
    error TokenDoesNotExist();
    error TokenAlreadyExists();
    error ZeroAddress();
    error InvalidRecipient();
    error NotApprovedOrOwner();
    error TokenAlreadyTransferredThisTx();
    error OwnerAlreadyRecordedForBlock();
    error Reentrancy();
    /// @dev DEPRECATED: kept for ABI backwards compatibility. Use OwnerAlreadyRecordedForBlock.
    error OwnerAlreadyRecordedForTimestamp();
    
    // ==========================================
    // EVENTS (ERC-721 Compatible)
    // ==========================================
    
    // Events inherited from IERC721: Transfer, Approval, ApprovalForAll
    // Historical tracking events inherited from IERC721H:
    //   OwnershipHistoryRecorded, OriginalCreatorRecorded, HistoricalTokenBurned

    /// @notice Emitted when contract admin ownership is transferred.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    
    // ==========================================
    // STATE VARIABLES
    // ==========================================
    
    string public name;
    string public symbol;
    uint256 private _nextTokenId;
    uint256 private _activeSupply;
    address public owner;
    bool private _locked;
    
    // ==========================================
    // LAYER 1: IMMUTABLE ORIGIN
    // ==========================================
    
    /// @notice IMMUTABLE record of who FIRST minted/created each token
    /// @dev This mapping is set ONCE at mint and NEVER modified
    ///      Use isOriginalOwner() to check if address was the creator
    mapping(uint256 => address) public originalCreator;
    
    /// @notice Block number when token was originally minted
    mapping(uint256 => uint256) public mintBlock;
    
    // ==========================================
    // LAYER 2: HISTORICAL TRAIL
    // ==========================================
    
    /// @notice APPEND-ONLY history of all owners for each token
    /// @dev New owners are added but old entries are NEVER removed
    ///      Use getOwnershipHistory() to retrieve complete chain
    mapping(uint256 => address[]) private _ownershipHistory;
    
    /// @notice Timestamp of each ownership transfer
    mapping(uint256 => uint256[]) private _ownershipTimestamps;

    /// @notice Block number of each ownership change (parallel to _ownershipHistory)
    /// @dev Enables O(log n) binary-search lookup for getOwnerAtBlock() at any arbitrary block.
    mapping(uint256 => uint256[]) private _ownershipBlocks;
    
    /// @notice All tokens that an address has EVER owned (historical, deduplicated)
    /// @dev Does NOT remove tokens after transfer (historical record)
    mapping(address => uint256[]) private _everOwnedTokens;
    
    /// @notice O(1) lookup: has address ever owned a specific token?
    /// @dev Prevents duplicates in _everOwnedTokens and replaces linear scan in hasEverOwned()
    mapping(uint256 => mapping(address => bool)) private _hasOwnedToken;
    
    /// @notice Tokens originally created by each address (set once at mint)
    /// @dev Dedicated array avoids O(n) filtering in getOriginallyCreatedTokens()
    mapping(address => uint256[]) private _createdTokens;
    
    // ==========================================
    // LAYER 3: CURRENT AUTHORITY (Standard ERC-721)
    // ==========================================
    
    /// @notice Current owner of each token (standard ERC-721 behavior)
    /// @dev This is the ONLY mapping that changes on transfer
    mapping(uint256 => address) private _currentOwner;
    
    /// @notice Approved address for each token
    mapping(uint256 => address) private _tokenApprovals;
    
    /// @notice Operator approvals
    mapping(address => mapping(address => bool)) private _operatorApprovals;
    
    /// @notice Balance of tokens currently owned
    mapping(address => uint256) private _balances;
    
    // ==========================================
    // CONSTRUCTOR
    // ==========================================
    
    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
        _nextTokenId = 1;
        owner = msg.sender;
        _locked = false;
    }
    
    // ==========================================
    // MODIFIERS
    // ==========================================
    
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }
    
    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    /// @notice Prevents the SAME token from being transferred more than once per transaction
    /// @dev Uses EIP-1153 transient storage (Cancun+). Each tokenId gets its own tstore slot.
    ///      Blocks Sybil chains (A→B→C→D in one TX) that pollute Layer 2 ownership history.
    ///      Different tokens can still transfer freely in the same TX (batch-safe).
    ///      Transient storage is auto-cleared by the EVM at end of transaction — zero permanent cost.
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
    
    // ==========================================
    // ERC-721 CORE FUNCTIONS
    // ==========================================
    
    function balanceOf(address account) public view returns (uint256) {
        if (account == address(0)) revert ZeroAddress();
        return _balances[account];
    }
    
    function ownerOf(uint256 tokenId) public view returns (address) {
        address tokenOwner = _currentOwner[tokenId];
        if (tokenOwner == address(0)) revert TokenDoesNotExist();
        return tokenOwner;
    }
    
    function approve(address to, uint256 tokenId) public {
        address tokenOwner = ownerOf(tokenId);
        if (to == tokenOwner) revert InvalidRecipient();
        
        if (msg.sender != tokenOwner && !isApprovedForAll(tokenOwner, msg.sender)) {
            revert NotAuthorized();
        }
        
        _tokenApprovals[tokenId] = to;
        emit Approval(tokenOwner, to, tokenId);
    }
    
    function getApproved(uint256 tokenId) public view returns (address) {
        if (_currentOwner[tokenId] == address(0)) revert TokenDoesNotExist();
        return _tokenApprovals[tokenId];
    }
    
    function setApprovalForAll(address operator, bool approved) public {
        if (operator == msg.sender) revert InvalidRecipient();
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }
    
    function isApprovedForAll(address account, address operator) public view returns (bool) {
        return _operatorApprovals[account][operator];
    }
    
    function transferFrom(address from, address to, uint256 tokenId) public {
        if (!_isApprovedOrOwner(msg.sender, tokenId)) revert NotApprovedOrOwner();
        _transfer(from, to, tokenId);
    }
    
    function safeTransferFrom(address from, address to, uint256 tokenId) public {
        transferFrom(from, to, tokenId);
        _checkOnERC721Received(from, to, tokenId, "");
    }
    
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        transferFrom(from, to, tokenId);
        _checkOnERC721Received(from, to, tokenId, data);
    }
    
    // ==========================================
    // SUPPLY QUERIES
    // ==========================================

    /// @notice Total number of tokens currently in existence (excludes burned)
    function totalSupply() public view returns (uint256) {
        return _activeSupply;
    }

    /// @notice Total number of tokens ever minted (includes burned)
    function totalMinted() public view returns (uint256) {
        return _nextTokenId - 1;
    }

    // ==========================================
    // MINTING (Sets Layer 1 & 2 & 3)
    // ==========================================
    
    /**
     * @notice Mint a new token with complete historical tracking
     * @dev This is where the three-layer model is initialized:
     *      Layer 1: originalCreator[tokenId] = to (IMMUTABLE)
     *      Layer 2: _ownershipHistory[tokenId].push(to) (FIRST ENTRY)
     *      Layer 3: _currentOwner[tokenId] = to (MUTABLE)
     * @param to The address to mint the token to (becomes originalCreator)
     * @return tokenId The newly minted token ID
     */
    function mint(address to) public onlyOwner returns (uint256) {
        if (to == address(0)) revert ZeroAddress();
        
        uint256 tokenId = _nextTokenId++;

        _beforeTokenTransfer(address(0), to, tokenId);
        
        // LAYER 1: Record IMMUTABLE original creator
        originalCreator[tokenId] = to;
        mintBlock[tokenId] = block.number;
        _createdTokens[to].push(tokenId);
        emit OriginalCreatorRecorded(tokenId, to);
        
        // LAYER 2: Start ownership history trail
        _ownershipHistory[tokenId].push(to);
        _ownershipTimestamps[tokenId].push(block.timestamp);
        _ownershipBlocks[tokenId].push(block.number);
        _everOwnedTokens[to].push(tokenId);
        _hasOwnedToken[tokenId][to] = true;
        emit OwnershipHistoryRecorded(tokenId, to, block.timestamp);
        
        // LAYER 3: Set current owner (standard ERC-721)
        _currentOwner[tokenId] = to;
        _balances[to] += 1;
        _activeSupply += 1;
        
        emit Transfer(address(0), to, tokenId);

        _afterTokenTransfer(address(0), to, tokenId);
        
        return tokenId;
    }
    
    // +++++++++++++++++++++++++++++++++++++++++++++++++
    // TRANSFER (Updates Layer 2 & 3, preserves Layer 1)
    // +++++++++++++++++++++++++++++++++++++++++++++++++
    
    /**
     * @notice Internal transfer that maintains historical records
     * @dev Layer 1: originalCreator UNCHANGED (immutable)
     *      Layer 2: Append new owner to history (append-only)
     *      Layer 3: Update current owner (standard ERC-721)
     */
    function _transfer(address from, address to, uint256 tokenId) internal nonReentrant oneTransferPerTokenPerTx(tokenId) {
        if (_currentOwner[tokenId] != from) revert NotAuthorized();
        if (to == address(0)) revert ZeroAddress();
        if (from == to) revert InvalidRecipient(); // Prevent self-transfer (history pollution)

        _beforeTokenTransfer(from, to, tokenId);
        
        // Clear approvals
        delete _tokenApprovals[tokenId];
        
        // LAYER 1: originalCreator[tokenId] remains UNCHANGED (immutable!)
        
        // SYBIL GUARD: One owner per token per block number (inter-TX protection)
        // Derived from existing _ownershipBlocks — zero additional storage.
        // Last entry records the most recent ownership-change block; if it matches
        // the current block, this is a same-block double-transfer → reject.
        {
            uint256 len = _ownershipBlocks[tokenId].length;
            if (len > 0 && _ownershipBlocks[tokenId][len - 1] == block.number) {
                revert OwnerAlreadyRecordedForBlock();
            }
        }

        // LAYER 2: APPEND to ownership history (never remove old entries)
        _ownershipHistory[tokenId].push(to);
        _ownershipTimestamps[tokenId].push(block.timestamp);
        _ownershipBlocks[tokenId].push(block.number);
        // Deduplicate: only add to _everOwnedTokens if first time owning
        if (!_hasOwnedToken[tokenId][to]) {
            _everOwnedTokens[to].push(tokenId);
            _hasOwnedToken[tokenId][to] = true;
        }
        emit OwnershipHistoryRecorded(tokenId, to, block.timestamp);
        
        // LAYER 3: Update current owner (standard ERC-721)
        _currentOwner[tokenId] = to;
        _balances[from] -= 1;
        _balances[to] += 1;
        
        emit Transfer(from, to, tokenId);

        _afterTokenTransfer(from, to, tokenId);
    }
    
    // +++++++++++++++++++++++++++++++++++++++++++++++++
    // HISTORICAL QUERY FUNCTIONS (The Innovation!)
    // +++++++++++++++++++++++++++++++++++++++++++++++++
    
    /**
     * @notice Check if address was the ORIGINAL creator/minter
     * @dev This returns true even if they've transferred ownership
     *      Perfect for "founder benefits" that survive transfers
     */
    function isOriginalOwner(uint256 tokenId, address account) public view returns (bool) {
        return originalCreator[tokenId] == account;
    }
    
    /**
     * @notice Check if address CURRENTLY owns the token
     * @dev Standard ERC-721 ownership check
     */
    function isCurrentOwner(uint256 tokenId, address account) public view returns (bool) {
        return _currentOwner[tokenId] == account;
    }
    
    /**
     * @notice Check if address has EVER owned this token
     * @dev Searches complete ownership history
     */
    function hasEverOwned(uint256 tokenId, address account) public view returns (bool) {
        return _hasOwnedToken[tokenId][account];
    }
    
    /**
     * @notice Get complete ownership history for a token
     * @dev Returns array of all addresses that have owned this token, in chronological order
     *      Index 0 is always the original creator
     */
    function getOwnershipHistory(uint256 tokenId) public view returns (
        address[] memory owners,
        uint256[] memory timestamps
    ) {
        if (!_exists(tokenId)) revert TokenDoesNotExist();
        return (_ownershipHistory[tokenId], _ownershipTimestamps[tokenId]);
    }
    
    /**
     * @notice Get number of times token has been transferred
     * @dev length - 1 because first entry is mint, not transfer
     */
    function getTransferCount(uint256 tokenId) public view returns (uint256) {
        if (!_exists(tokenId)) revert TokenDoesNotExist();
        return _ownershipHistory[tokenId].length - 1;
    }
    
    /**
     * @notice Get all tokens that an address has EVER owned (including transferred ones)
     * @dev This is historical - includes tokens they no longer own
     */
    function getEverOwnedTokens(address account) public view returns (uint256[] memory) {
        return _everOwnedTokens[account];
    }
    
    /**
     * @notice Get all tokens an address is ORIGINAL creator of
     * @dev Useful for airdrops to "founders" or "artists"
     */
    function getOriginallyCreatedTokens(address creator) public view returns (uint256[] memory) {
        return _createdTokens[creator];
    }
    
    /**
     * @notice Check if address was an "early adopter" (minted in first N blocks)
     * @dev WARNING: O(n) where n = number of tokens created by `account`.
     *      Safe for off-chain / view calls. Do NOT use inside state-changing transactions
     *      for prolific minters — gas cost grows linearly with _createdTokens[account].length.
     * @param account Address to check
     * @param blockThreshold Block number threshold (e.g., first 100 blocks)
     */
    function isEarlyAdopter(address account, uint256 blockThreshold) public view returns (bool) {
        uint256[] memory tokens = _createdTokens[account];
        for (uint256 i = 0; i < tokens.length; i++) {
            if (mintBlock[tokens[i]] <= blockThreshold) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Get the owner of a token at ANY arbitrary block number
     * @dev Uses O(log n) binary search over the chronological _ownershipBlocks[] array.
     *      Returns the owner who held the token at `blockNumber` — even if no transfer
     *      happened at that exact block. Finds the last ownership entry at-or-before
     *      the queried block.
     *
     *      Returns address(0) if:
     *        - Token was not yet minted at `blockNumber`
     *        - Token does not exist
     *
     *      EXAMPLE:
     *        Block 100: Mint → Alice    → getOwnerAtBlock(1, 100) = Alice
     *        Block 150: (nothing)        → getOwnerAtBlock(1, 150) = Alice  ✓
     *        Block 200: Transfer → Bob   → getOwnerAtBlock(1, 200) = Bob
     *        Block 250: (nothing)        → getOwnerAtBlock(1, 250) = Bob    ✓
     *
     * @param tokenId The token to query
     * @param blockNumber The block number to check (any block, not just transfer blocks)
     * @return The owner at that block, or address(0) if not yet minted
     */
    function getOwnerAtBlock(uint256 tokenId, uint256 blockNumber) public view returns (address) {
        uint256[] storage blocks = _ownershipBlocks[tokenId];
        uint256 len = blocks.length;
        if (len == 0) return address(0); // Token never minted

        // If queried block is before mint, token didn't exist yet
        if (blockNumber < blocks[0]) return address(0);

        // Binary search: find last entry where blocks[i] <= blockNumber
        uint256 low = 0;
        uint256 high = len - 1;
        while (low < high) {
            uint256 mid = low + (high - low + 1) / 2; // Ceiling division to avoid infinite loop
            if (blocks[mid] <= blockNumber) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }
        return _ownershipHistory[tokenId][low];
    }
    
    /**
     * @notice DEPRECATED: Use getOwnerAtBlock() instead.
     *      This function kept for backwards compatibility. Returns address(0) for all queries.
     */
    function getOwnerAtTimestamp(uint256 /* tokenId */, uint256 /* timestamp */) public pure returns (address) {
        return address(0); // DEPRECATED: timestamp-based queries always return empty
    }
    
    // ==========================================
    // PAGINATION HELPERS (Anti-Griefing)
    // ==========================================

    /**
     * @notice Returns the total number of entries in a token's ownership history
     * @dev Use with getHistorySlice() to paginate large histories without
     *      pulling the entire array (which can hit RPC response limits for
     *      heavily-traded tokens).
     */
    function getHistoryLength(uint256 tokenId) public view returns (uint256) {
        if (!_exists(tokenId)) revert TokenDoesNotExist();
        return _ownershipHistory[tokenId].length;
    }

    /**
     * @notice Returns a paginated slice of ownership history
     * @dev Safe for large histories. Returns empty arrays if start >= length.
     * @param tokenId The token to query
     * @param start   Zero-based start index
     * @param count   Maximum number of entries to return
     * @return owners     Slice of owner addresses
     * @return timestamps Parallel slice of block timestamps
     */
    function getHistorySlice(
        uint256 tokenId,
        uint256 start,
        uint256 count
    ) public view returns (address[] memory owners, uint256[] memory timestamps) {
        if (!_exists(tokenId)) revert TokenDoesNotExist();
        uint256 len = _ownershipHistory[tokenId].length;
        if (start >= len) {
            return (new address[](0), new uint256[](0));
        }
        uint256 end = start + count;
        if (end > len) end = len;
        uint256 sliceLen = end - start;
        owners = new address[](sliceLen);
        timestamps = new uint256[](sliceLen);
        for (uint256 i = 0; i < sliceLen; i++) {
            owners[i] = _ownershipHistory[tokenId][start + i];
            timestamps[i] = _ownershipTimestamps[tokenId][start + i];
        }
    }

    // ==========================================
    // PER-ADDRESS PAGINATION (Anti-Griefing)
    // ==========================================

    /// @notice Returns the number of distinct tokens `account` has ever owned.
    /// @dev Use with getEverOwnedTokensSlice() to paginate for prolific holders.
    function getEverOwnedTokensLength(address account) public view returns (uint256) {
        return _everOwnedTokens[account].length;
    }

    /// @notice Returns a paginated slice of tokens `account` has ever owned.
    function getEverOwnedTokensSlice(address account, uint256 start, uint256 count)
        public view returns (uint256[] memory tokenIds)
    {
        uint256 len = _everOwnedTokens[account].length;
        if (start >= len) return new uint256[](0);
        uint256 end = start + count;
        if (end > len) end = len;
        uint256 sliceLen = end - start;
        tokenIds = new uint256[](sliceLen);
        for (uint256 i = 0; i < sliceLen; i++) {
            tokenIds[i] = _everOwnedTokens[account][start + i];
        }
    }

    /// @notice Returns the number of tokens `creator` originally minted.
    function getCreatedTokensLength(address creator) public view returns (uint256) {
        return _createdTokens[creator].length;
    }

    /// @notice Returns a paginated slice of tokens `creator` originally minted.
    function getCreatedTokensSlice(address creator, uint256 start, uint256 count)
        public view returns (uint256[] memory tokenIds)
    {
        uint256 len = _createdTokens[creator].length;
        if (start >= len) return new uint256[](0);
        uint256 end = start + count;
        if (end > len) end = len;
        uint256 sliceLen = end - start;
        tokenIds = new uint256[](sliceLen);
        for (uint256 i = 0; i < sliceLen; i++) {
            tokenIds[i] = _createdTokens[creator][start + i];
        }
    }

    // ==========================================
    // PROVENANCE REPORT
    // ==========================================
    
    /**
     * @notice Generate complete provenance report for a token
     * @dev Returns all relevant historical data in one call
     */
    function getProvenanceReport(uint256 tokenId) public view returns (
        address creator,
        uint256 creationBlock,
        address currentOwnerAddress,
        uint256 totalTransfers,
        address[] memory allOwners,
        uint256[] memory transferTimestamps
    ) {
        if (!_exists(tokenId)) revert TokenDoesNotExist();
        
        return (
            originalCreator[tokenId],
            mintBlock[tokenId],
            _currentOwner[tokenId],
            _ownershipHistory[tokenId].length - 1,
            _ownershipHistory[tokenId],
            _ownershipTimestamps[tokenId]
        );
    }
    
    // ==========================================
    // BURN
    // ==========================================
    
    /**
     * @notice Burn a token — removes from Layer 3 but PERMANENTLY preserves Layer 1 & 2
     * @dev After burn:
     *      - originalCreator[tokenId] remains immutable
     *      - getOwnershipHistory() returns full provenance chain
     *      - isOriginalOwner() still works (founder benefit persists)
     *      - Metadata remains queryable (tokenURI works on burned tokens)
     *      
     *      This distinguishes ERC-721H from ERC-721: provenance survives burn.
     *
     *      INTEGRATION NOTE FOR INDEXERS:
     *      Burn removes current authority (Layer 3), NOT historical existence.
     *      After burn, ownerOf() reverts but getOwnershipHistory(), originalCreator(),
     *      and hasEverOwned() still return data. The HistoricalTokenBurned event signals
     *      this is a Layer-3-only deletion, not full token destruction.
     */
    function burn(uint256 tokenId) public {
        address tokenOwner = ownerOf(tokenId);
        // Gas opt: inline auth instead of calling _isApprovedOrOwner (avoids 2nd ownerOf SLOAD)
        if (msg.sender != tokenOwner &&
            getApproved(tokenId) != msg.sender &&
            !isApprovedForAll(tokenOwner, msg.sender)) {
            revert NotApprovedOrOwner();
        }

        _beforeTokenTransfer(tokenOwner, address(0), tokenId);
        
        // Clear approvals only
        delete _tokenApprovals[tokenId];
        
        // LAYER 1 & 2: PERMANENTLY PRESERVED (immutable history survives burn)
        // This is intentional and distinct from ERC-721
        
        // LAYER 3: Remove from current ownership tracking
        _currentOwner[tokenId] = address(0);
        _balances[tokenOwner] -= 1;
        _activeSupply -= 1;
        
        emit Transfer(tokenOwner, address(0), tokenId);
        emit HistoricalTokenBurned(tokenId);

        _afterTokenTransfer(tokenOwner, address(0), tokenId);
    }
    
    // ==========================================
    // OWNERSHIP
    // ==========================================
    
    function transferOwnership(address newOwner) public onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address previousOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner);
    }
    
    // ==========================================
    // INTERNAL HELPERS
    // ==========================================
    
    /// @notice Unified Layer 1 existence check — returns true if token was ever minted
    /// @dev Uses originalCreator (Layer 1) so it returns true even after burn.
    ///      Use this instead of checking _currentOwner (which is cleared on burn).
    function _exists(uint256 tokenId) internal view returns (bool) {
        return originalCreator[tokenId] != address(0);
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view returns (bool) {
        address tokenOwner = ownerOf(tokenId);
        return (spender == tokenOwner || 
                getApproved(tokenId) == spender || 
                isApprovedForAll(tokenOwner, spender));
    }

    /**
     * @notice Hook called before any token transfer (including mint and burn).
     * @dev Override in inheriting contracts for staking, royalties, or access control.
     *      Mint:     from == address(0)
     *      Burn:     to   == address(0)
     *      Transfer: both non-zero
     * @param from     Source address (address(0) for mint)
     * @param to       Destination address (address(0) for burn)
     * @param tokenId  Token being transferred
     */
    function _beforeTokenTransfer(address from, address to, uint256 tokenId) internal virtual {}

    /**
     * @notice Hook called after any token transfer (including mint and burn).
     * @dev Override in inheriting contracts for post-transfer logic.
     * @param from     Source address (address(0) for mint)
     * @param to       Destination address (address(0) for burn)
     * @param tokenId  Token being transferred
     */
    function _afterTokenTransfer(address from, address to, uint256 tokenId) internal virtual {}
    
    /// @dev Checks ERC-721 receiver interface on contract recipients.
    ///      Internal + virtual so inheriting contracts can override receiver logic.
    function _checkOnERC721Received(
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) internal virtual {
        if (to.code.length > 0) {
            try IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data) returns (bytes4 retval) {
                if (retval != IERC721Receiver.onERC721Received.selector) {
                    revert InvalidRecipient();
                }
            } catch {
                revert InvalidRecipient();
            }
        }
    }
    
    // ==========================================
    // ERC-165 SUPPORT
    // ==========================================
    
    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == 0x01ffc9a7 || // ERC-165
               interfaceId == 0x80ac58cd || // ERC-721
               interfaceId == 0x5b5e139f || // ERC-721 Metadata
               interfaceId == type(IERC721H).interfaceId; // ERC-721H
    }
    
    // ==========================================
    // METADATA (Basic)
    // ==========================================
    
    /// @notice Returns metadata URI for a token
    /// @dev Implementers MUST override in inheriting contract.
    ///      ERC-721H: metadata persists even after burn (provenance permanence).
    ///      Unlike ERC-721, this does NOT revert after burn().
    ///      
    ///      This enables use cases where burned tokens retain historical significance:
    ///      - Artist archives ("burnt by artist for authentication")
    ///      - Historical records (estate/inheritance documentation)
    ///      - Proof of prior ownership (for legal disputes)
    function tokenURI(uint256 tokenId) public view virtual returns (string memory) {
        if (!_exists(tokenId)) revert TokenDoesNotExist();
        return "";
    }
}

// ==========================================
// INTERFACE
// ==========================================

interface IERC721Receiver {
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
}

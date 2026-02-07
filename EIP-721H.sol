// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC721H} from "./IERC721H.sol";

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
 * - Mint: ~80,000 gas (standard: ~50,000) +60% for historical tracking
 * - Transfer: ~90,000 gas (standard: ~50,000) +80% for history append
 * - Read history: Free (view function)
 * 
 * TRADE-OFF: Slightly higher gas for PERMANENT on-chain history
 * 
 * @custom:version 1.0.0
 */
contract ERC721H is IERC721H {
    // ==========================================
    // ERRORS
    // ==========================================
    
    error NotAuthorized();
    error TokenDoesNotExist();
    error TokenAlreadyExists();
    error ZeroAddress();
    error InvalidRecipient();
    error NotApprovedOrOwner();
    
    // ==========================================
    // EVENTS (ERC-721 Compatible)
    // ==========================================
    
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    
    // NEW: Historical tracking events (inherited from IERC721H)
    
    // ==========================================
    // STATE VARIABLES
    // ==========================================
    
    string public name;
    string public symbol;
    uint256 private _nextTokenId;
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
        if (_locked) revert NotAuthorized();
        _locked = true;
        _;
        _locked = false;
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
    // MINTING (Sets Layer 1 & 2 & 3)
    // ==========================================
    
    /**
     * @notice Mint a new token with complete historical tracking
     * @dev This is where the three-layer model is initialized:
     *      Layer 1: originalCreator[tokenId] = to (IMMUTABLE)
     *      Layer 2: _ownershipHistory[tokenId].push(to) (FIRST ENTRY)
     *      Layer 3: _currentOwner[tokenId] = to (MUTABLE)
     */
    /// @notice Total number of tokens in existence
    function totalSupply() public view returns (uint256) {
        return _nextTokenId - 1;
    }
    
    function mint(address to) public onlyOwner returns (uint256) {
        if (to == address(0)) revert ZeroAddress();
        
        uint256 tokenId = _nextTokenId++;
        
        // LAYER 1: Record IMMUTABLE original creator
        originalCreator[tokenId] = to;
        mintBlock[tokenId] = block.number;
        _createdTokens[to].push(tokenId);
        emit OriginalCreatorRecorded(tokenId, to);
        
        // LAYER 2: Start ownership history trail
        _ownershipHistory[tokenId].push(to);
        _ownershipTimestamps[tokenId].push(block.timestamp);
        _everOwnedTokens[to].push(tokenId);
        _hasOwnedToken[tokenId][to] = true;
        emit OwnershipHistoryRecorded(tokenId, to, block.timestamp);
        
        // LAYER 3: Set current owner (standard ERC-721)
        _currentOwner[tokenId] = to;
        _balances[to] += 1;
        
        emit Transfer(address(0), to, tokenId);
        
        return tokenId;
    }
    
    // ==========================================
    // TRANSFER (Updates Layer 2 & 3, preserves Layer 1)
    // ==========================================
    
    /**
     * @notice Internal transfer that maintains historical records
     * @dev Layer 1: originalCreator UNCHANGED (immutable)
     *      Layer 2: Append new owner to history (append-only)
     *      Layer 3: Update current owner (standard ERC-721)
     */
    function _transfer(address from, address to, uint256 tokenId) internal nonReentrant {
        if (ownerOf(tokenId) != from) revert NotAuthorized();
        if (to == address(0)) revert ZeroAddress();
        
        // Clear approvals
        delete _tokenApprovals[tokenId];
        
        // LAYER 1: originalCreator[tokenId] remains UNCHANGED (immutable!)
        
        // LAYER 2: APPEND to ownership history (never remove old entries)
        _ownershipHistory[tokenId].push(to);
        _ownershipTimestamps[tokenId].push(block.timestamp);
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
    }
    
    // ==========================================
    // HISTORICAL QUERY FUNCTIONS (The Innovation!)
    // ==========================================
    
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
        if (_currentOwner[tokenId] == address(0)) revert TokenDoesNotExist();
        return (_ownershipHistory[tokenId], _ownershipTimestamps[tokenId]);
    }
    
    /**
     * @notice Get number of times token has been transferred
     * @dev length - 1 because first entry is mint, not transfer
     */
    function getTransferCount(uint256 tokenId) public view returns (uint256) {
        if (_currentOwner[tokenId] == address(0)) revert TokenDoesNotExist();
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
        if (_currentOwner[tokenId] == address(0)) revert TokenDoesNotExist();
        
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
     * @notice Burn a token — removes from Layer 3 but preserves Layer 1 & 2
     * @dev originalCreator and ownershipHistory remain intact forever
     */
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
        
        emit Transfer(tokenOwner, address(0), tokenId);
    }
    
    // ==========================================
    // OWNERSHIP
    // ==========================================
    
    function transferOwnership(address newOwner) public onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }
    
    // ==========================================
    // INTERNAL HELPERS
    // ==========================================
    
    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view returns (bool) {
        address tokenOwner = ownerOf(tokenId);
        return (spender == tokenOwner || 
                getApproved(tokenId) == spender || 
                isApprovedForAll(tokenOwner, spender));
    }
    
    function _checkOnERC721Received(
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) private {
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
    /// @dev Override in inheriting contract to return actual metadata.
    ///      Claims ERC-721Metadata interface — implementors MUST override this.
    function tokenURI(uint256 tokenId) public view virtual returns (string memory) {
        if (_currentOwner[tokenId] == address(0)) revert TokenDoesNotExist();
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

// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "empty_src/ERC-721H.sol";

interface Vm {
    function deal(address who, uint256 newBalance) external;
    function prank(address sender) external;
    function warp(uint256 timestamp) external;
}

/**
 * @title Economic Fuzzing Test for ERC-721H
 * @notice Focuses on historical state corruption and Sybil vulnerabilities
 */
contract ERC721H_EconomicFuzz {
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    
    ERC721H public nft;
    address public attacker = address(0x1337);
    address public victim = address(0xDEAD);
    address public owner = address(0xAAAA);
    
    uint256 public activeTokenId;

    function setUp() public {
        vm.prank(owner);
        nft = new ERC721H("Historical NFT", "HNFT");
        
        vm.prank(owner);
        activeTokenId = nft.mint(victim);
    }
    
    // ==========================================
    // VALUE FUNCTIONS
    // ==========================================
    
    /// @notice Target: Attacker gaining unauthorized ownership history
    /// @dev Can the attacker inject themselves into a high-value token's history?
    function valueHistoryInfiltration() public view returns (int256) {
        return nft.hasEverOwned(activeTokenId, attacker) ? int256(1) : int256(0);
    }
    
    /// @notice Target: Breaking immutability of Layer 1
    function valueCreatorCorruption() public view returns (int256) {
        return nft.originalCreator(activeTokenId) != victim ? int256(100) : int256(0);
    }
    
    /// @notice Target: Sybil history bloat
    /// @dev Maximizing history length for a single token in minimum time
    function valueHistoryLength() public view returns (int256) {
        (address[] memory owners, ) = nft.getOwnershipHistory(activeTokenId);
        return int256(owners.length);
    }

    // ==========================================
    // ATTACK PARAMETERS
    // ==========================================
    
    function attackParamsTransfer() public pure returns (string[] memory) {
        string[] memory params = new string[](3);
        params[0] = "from:address";
        params[1] = "to:address";
        params[2] = "tokenId:uint256";
        return params;
    }
    
    function attackParamsMint() public pure returns (string[] memory) {
        string[] memory params = new string[](1);
        params[0] = "to:address";
        return params;
    }

    // ==========================================
    // SCENARIOS
    // ==========================================
    
    function scenarioSybilTransfer() public pure returns (string memory) {
        return "transferFrom,transferFrom,transferFrom";
    }
    
    function scenarioUnauthorizedTransfer() public pure returns (string memory) {
        return "transferFrom";
    }

    function maxTraceDepth() public pure returns (uint256) {
        return 5;
    }
}

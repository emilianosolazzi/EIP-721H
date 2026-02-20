// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "empty_src/ERC-721H.sol";

contract ERC721H_FullTest is Test {
    ERC721H public nft;
    address public owner = address(0xAAAA);
    address public user1 = address(0x1111);
    address public user2 = address(0x2222);
    address public user3 = address(0x3333);

    function setUp() public {
        vm.prank(owner);
        nft = new ERC721H("Historical NFT", "HNFT");
    }

    function testMintAndLayers() public {
        vm.prank(owner);
        uint256 tokenId = nft.mint(user1);

        // Layer 1: Immutable Origin
        assertEq(nft.originalCreator(tokenId), user1);
        assertEq(nft.mintBlock(tokenId), block.number);
        assertTrue(nft.isOriginalOwner(tokenId, user1));

        // Layer 2: Historical Trail
        assertTrue(nft.hasEverOwned(tokenId, user1));
        uint256[] memory everOwned = nft.getEverOwnedTokens(user1);
        assertEq(everOwned.length, 1);
        assertEq(everOwned[0], tokenId);

        (address[] memory owners, uint256[] memory timestamps) = nft.getOwnershipHistory(tokenId);
        assertEq(owners.length, 1);
        assertEq(owners[0], user1);
        assertEq(timestamps[0], block.timestamp);

        // Layer 3: Current Authority
        assertEq(nft.ownerOf(tokenId), user1);
        assertEq(nft.balanceOf(user1), 1);
    }

    function testSingleTransferAndHistory() public {
        vm.prank(owner);
        uint256 tokenId = nft.mint(user1);

        // First transfer: User1 to User2
        vm.roll(block.number + 1);
        vm.prank(user1);
        nft.transferFrom(user1, user2, tokenId);

        assertEq(nft.ownerOf(tokenId), user2);
        assertTrue(nft.hasEverOwned(tokenId, user1));
        assertTrue(nft.hasEverOwned(tokenId, user2));
        
        (address[] memory owners, ) = nft.getOwnershipHistory(tokenId);
        assertEq(owners.length, 2);
        assertEq(owners[0], user1);
        assertEq(owners[1], user2);
    }

    function testSybilGuardSameTxReverts() public {
        vm.prank(owner);
        uint256 tokenId = nft.mint(user1);

        // Attempting A -> B -> C in same TX should fail due to transient storage guard
        SybilAttacker attacker = new SybilAttacker(nft);
        vm.prank(user1);
        nft.approve(address(attacker), tokenId);

        vm.expectRevert(); 
        attacker.attackSameTx(user1, user2, user3, tokenId);
    }

    function testHistoryPreservedAfterBurn() public {
        vm.prank(owner);
        uint256 tokenId = nft.mint(user1);
        
        vm.roll(block.number + 1);
        vm.prank(user1);
        nft.transferFrom(user1, user2, tokenId);

        vm.prank(user2);
        nft.burn(tokenId);

        // History MUST survive burn (now allowed since we updated the contract)
        assertEq(nft.originalCreator(tokenId), user1);
        assertTrue(nft.hasEverOwned(tokenId, user1));
        assertTrue(nft.hasEverOwned(tokenId, user2));
        
        (address[] memory owners, ) = nft.getOwnershipHistory(tokenId);
        assertEq(owners.length, 2);
    }

    function testDeduplicationOfEverOwned() public {
        vm.prank(owner);
        uint256 token1 = nft.mint(user1);
        vm.prank(owner);
        uint256 token2 = nft.mint(user1);

        uint256[] memory everOwned = nft.getEverOwnedTokens(user1);
        assertEq(everOwned.length, 2);
        assertEq(everOwned[0], token1);
        assertEq(everOwned[1], token2);
    }

    function testProvenanceReport() public {
        vm.prank(owner);
        uint256 tokenId = nft.mint(user1);
        
        (
            address creator,
            uint256 creationBlock,
            address currentOwnerAddress,
            uint256 totalTransfers,
            address[] memory allOwners,
            uint256[] memory transferTimestamps
        ) = nft.getProvenanceReport(tokenId);

        assertEq(creator, user1);
        assertEq(creationBlock, block.number);
        assertEq(currentOwnerAddress, user1);
        assertEq(totalTransfers, 0);
        assertEq(allOwners.length, 1);
        assertEq(transferTimestamps.length, 1);
    }
}

contract SybilAttacker {
    ERC721H public nft;

    constructor(ERC721H _nft) {
        nft = _nft;
    }

    function attackSameTx(address from, address to1, address to2, uint256 tokenId) external {
        nft.transferFrom(from, to1, tokenId);
        nft.transferFrom(to1, to2, tokenId); // Should fail here
    }
}

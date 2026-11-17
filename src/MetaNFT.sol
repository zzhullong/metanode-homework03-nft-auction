// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { ERC721URIStorage } from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";

/// @notice Homework NFT: ERC721 with public minting and per-token metadata URI.
contract MetaNFT is ERC721URIStorage {
    uint256 private _nextTokenId = 1;

    error MintToZeroAddress();

    constructor() ERC721("MetaNode NFT", "META") { }

    function mint(address to, string calldata uri) external returns (uint256 tokenId) {
        if (to == address(0)) revert MintToZeroAddress();
        tokenId = _nextTokenId++;
        _mint(to, tokenId);
        _setTokenURI(tokenId, uri);
    }

    function totalMinted() external view returns (uint256) {
        return _nextTokenId - 1;
    }
}

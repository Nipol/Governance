/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

pragma solidity ^0.8.0;

import {ERC721, IERC721} from "@beandao/contracts/library/ERC721.sol";

contract ERC721Mock is ERC721 {
    constructor(string memory nftName, string memory nftSymbol) {
        name = nftName;
        symbol = nftSymbol;
    }

    function mint(uint256 tokenId) external {
        _mint(msg.sender, tokenId);
    }

    function mintTo(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    function safeMint(
        address to,
        uint256 tokenId,
        bytes memory data
    ) external {
        _safeMint(to, tokenId, data);
    }

    function safeMint(address to, uint256 tokenId) external {
        _safeMint(to, tokenId, "");
    }

    function burn(uint256 tokenId) external {
        _burn(tokenId);
    }

    function tokenURI(uint256) external pure returns (string memory) {
        return "";
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

contract GrassNFT is ERC721, ERC721Burnable, Ownable {
    
    using Counters for Counters.Counter;
    
    Counters.Counter private _tokenCounter;
 
    mapping (uint256 => NFT) private _nfts;
    string private baseURI;
    bool public mintEnabled;
    
    struct NFT {
        string uri;
        address creator;
    }
    
    event NFTCreated(uint256 tokenId, string uri, address creator, string name, string description);
    event NFTBurnt(uint256 tokenId);
    
    constructor() ERC721("GRASS","GRASS") {
        mintEnabled = false;
    }
    
    function _baseURI() internal view override virtual returns (string memory) {
        return baseURI;
    }

    function setBaseURI(string memory _newBaseURI) external virtual onlyOwner {
        baseURI = _newBaseURI;
    }
    
    function setMinting(bool isEnable) external onlyOwner {
        mintEnabled = isEnable;
    }
    
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        require(_exists(tokenId), "ERC721URIStorage: URI query for nonexistent token");

        string memory _tokenURI = _nfts[tokenId].uri;
        string memory base = _baseURI();

        // If there is no base URI, return the token URI.
        if (bytes(base).length == 0) {
            return _tokenURI;
        }
        // If both are set, concatenate the baseURI and tokenURI (via abi.encodePacked).
        if (bytes(_tokenURI).length > 0) {
            return string(abi.encodePacked(base, _tokenURI));
        }

        return super.tokenURI(tokenId);
    }


    function getNft(uint256 tokenId) external view returns( NFT memory) 
    {
        return _nfts[tokenId];
    }
    
    function getCreator(uint256 tokenId) external view returns (address)
    {
        return _nfts[tokenId].creator;
    }
     
    function getCurrentCount() external view returns(uint256)
    {
        return _tokenCounter.current();
    }
     
    /**
    * @dev Destroys `tokenId`.
    * The approval is cleared when the token is burned.
    *
    * Requirements:
    *
    * - `tokenId` must exist.
    *
    * Emits a {Transfer} event.
    */
     
    function _burn(uint256 tokenId) internal virtual override {
        super._burn(tokenId);
        delete _nfts[tokenId];
    }
    
    
    function mintNFT(address to, string memory uri, string memory name, string memory description) external returns (uint256) {
        
        require(mintEnabled || msg.sender == owner(), "MINT: minting is paused.");
        
        _tokenCounter.increment();

        uint256 tokenId = _tokenCounter.current();
        
        emit NFTCreated(tokenId, uri, to, name, description);
        
        _mint(to, tokenId);
        
        NFT memory newNFT = NFT(uri, to);
        
        _nfts[tokenId] = newNFT;
        //_setTokenURI(newItemId, uri);
        
        return tokenId;
    }

}

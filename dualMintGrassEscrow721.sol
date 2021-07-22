// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/escrow/Escrow.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {Counters} from "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

abstract contract GrassInterface {
    function safeTransferFrom(address from, address to, uint256 tokenId) public virtual;
    function transferFrom(address from, address to, uint256 tokenId) external virtual;
    function ownerOf(uint256 tokenId) public view virtual returns (address);
    function getPrice(uint256 tokenId) public view virtual returns (uint256);
    function unlistNFT(uint256 tokenId) public virtual;
    function isOnSale(uint256 tokenId) public view virtual returns(bool);
    function isOnAuction(uint256 tokenId) public view virtual returns(bool);
    function approve(address to, uint256 tokenId) public virtual;
    function getApproved(uint256 tokenId) external view virtual returns (address operator);
    function getArtist(uint256 tokenId) external view virtual returns (address);
    function getCreator(uint256 tokenId) external view virtual returns (address);
}

contract GrassEscrow is Ownable, Escrow, ReentrancyGuard  {
    
    using SafeMath for uint256;
    using Counters for Counters.Counter;
    
    struct Auction {
        uint256 auctionId;
        uint256 duration;
        uint256 firstBidTime;
        uint256 reservePrice;
        uint256 bid;
        address tokenOwner;
        address bidder;
    }
    
    struct Sale {
        uint256 saleId;
        uint256 price;
        address tokenOwner;
    }
    
    Counters.Counter private _saleCounter;
    Counters.Counter private _auctionCounter;
    
    address public grassAddress;
    GrassInterface grassContract;
    uint256 public timeBuffer;
    
    uint256 public curatorCutPercentage;
    uint256 public artistRoyaltyPercentage;
    uint256 public creatorRoyaltyPercentage;
    address public curator;
    
    mapping(uint256 => Auction) public auctions;
    mapping(uint256 => Sale) public sales;
    
    event SaleComplete (uint256 saleId, uint256 tokenId, address seller, address buyer, uint256 price);
    event AuctionCreated (uint256 auctionId, uint256 tokenId, uint256 duration, uint256 reservePrice, address tokenOwner, address curator, uint256 curatorFeePercentage);
    event AuctionBid (uint256 auctionId, uint256 tokenId, address bidder, uint256 bid, bool firstBid, bool extended);
    event AuctionDurationExtended (uint256 auctionId, uint256 tokenId, uint256 newDuration);
    event AuctionEnded (uint256 auctionId, uint256 tokenId, address tokenOwner, address curator, address bidder, uint256 ownerProfit, uint256 curatorFee);
    event AuctionCanceled (uint256 auctionId, uint256 tokenId, address tokenOwner);
    event SaleCreated (uint256 saleId, uint256 tokenId, uint256 price, address tokenOwner);
    event SaleCanceled (uint256 saleId, uint256 tokenId, address tokenOwner);
    
    modifier auctionExists(uint256 tokenId) {
        require(auctions[tokenId].tokenOwner != address(0), "Auction doesn't exist");
        _;
    }
    
    modifier saleExists(uint256 tokenId) {
        require(sales[tokenId].tokenOwner != address(0), "Token not for sale");
        _;
    }
        
    constructor(address _grass, uint256 _curatorCut, uint256 _artistRoyalty, uint256 _creatorRoyalty) Ownable()
    {
        timeBuffer = 15*60;
        curatorCutPercentage = _curatorCut;
        artistRoyaltyPercentage = _artistRoyalty;
        creatorRoyaltyPercentage = _creatorRoyalty;
        curator = msg.sender;
        grassAddress = _grass;
        grassContract = GrassInterface(grassAddress);
    }
    
    function setCurator(address _curator) external onlyOwner {
        curator = _curator;
    }
    
    function createAuction(uint256 tokenId, uint256 duration, uint256 reservePrice) public nonReentrant
    {
        address tokenOwner = grassContract.ownerOf(tokenId);
        require(msg.sender == grassContract.getApproved(tokenId) || msg.sender == tokenOwner, "Caller must be approved or owner for token id");
        
        require(sales[tokenId].tokenOwner == address(0), "Token is already on sale");
        
        _auctionCounter.increment();
        uint256 _auctionId = _auctionCounter.current();
        
        auctions[tokenId] = Auction({
            auctionId: _auctionId,
            bid: 0,
            duration: duration,
            firstBidTime: 0,
            reservePrice: reservePrice,
            tokenOwner: tokenOwner,
            bidder: address(0)
        });
        
        grassContract.transferFrom(tokenOwner, address(this), tokenId);
        
        emit AuctionCreated(_auctionId, tokenId, duration, reservePrice, tokenOwner, curator, 5);
    }
    
    function createBid(uint256 tokenId) external payable auctionExists(tokenId) nonReentrant
    {
        uint256 amount = msg.value;
        address lastBidder = auctions[tokenId].bidder;
        require(
            auctions[tokenId].firstBidTime == 0 ||
            block.timestamp <
            auctions[tokenId].firstBidTime.add(auctions[tokenId].duration),
            "Auction expired"
        );
        require( amount >= auctions[tokenId].reservePrice, "Must send at least reservePrice");
        require(
            amount >= auctions[tokenId].bid.add(auctions[tokenId].bid.mul(5).div(100)), 
            "Must send more than last bid by 5% amount"
        );
        
        if(auctions[tokenId].firstBidTime == 0) {
            auctions[tokenId].firstBidTime = block.timestamp;
        } 
        else if(lastBidder != address(0)) {
            payable(lastBidder).transfer(auctions[tokenId].bid);
        }
        
        auctions[tokenId].bid = amount;
        auctions[tokenId].bidder = msg.sender;
        
        bool extended = false;
        
        if (auctions[tokenId].firstBidTime.add(auctions[tokenId].duration).sub(block.timestamp) < timeBuffer){
            // Playing code golf for gas optimization:
            // uint256 expectedEnd = auctions[auctionId].firstBidTime.add(auctions[auctionId].duration);
            // uint256 timeRemaining = expectedEnd.sub(block.timestamp);
            // uint256 timeToAdd = timeBuffer.sub(timeRemaining);
            // uint256 newDuration = auctions[auctionId].duration.add(timeToAdd);
            uint256 oldDuration = auctions[tokenId].duration;
            auctions[tokenId].duration =
                oldDuration.add(timeBuffer.sub(auctions[tokenId].firstBidTime.add(oldDuration).sub(block.timestamp)));
            extended = true;
        }
        
        emit AuctionBid(
            auctions[tokenId].auctionId,
            tokenId,
            msg.sender,
            amount,
            lastBidder == address(0), // firstBid boolean
            extended
        );

        if (extended) {
            emit AuctionDurationExtended(
                auctions[tokenId].auctionId,
                tokenId,
                auctions[tokenId].duration
            );
        }
    }
    
    function endAuction(uint256 tokenId) external auctionExists(tokenId) nonReentrant
    {
        
        require( uint256(auctions[tokenId].firstBidTime) != 0, "Auction hasn't begun");
        require(block.timestamp >= auctions[tokenId].firstBidTime.add(auctions[tokenId].duration), "Auction hasn't completed");
        
        uint256 ownerProfit = auctions[tokenId].bid;
        address bidder = auctions[tokenId].bidder;
        address tokenOwner = auctions[tokenId].tokenOwner;
        
        address artist = grassContract.getArtist(tokenId);
        address creator = grassContract.getCreator(tokenId);
        
        uint256 curatorFee = ownerProfit.mul(curatorCutPercentage).div(100);
        uint256 artistRoyalty = ownerProfit.mul(artistRoyaltyPercentage).div(100);
        uint256 creatorRoyalty = ownerProfit.mul(creatorRoyaltyPercentage).div(100);
        
        ownerProfit = ownerProfit.sub(curatorFee);
        ownerProfit = ownerProfit.sub(creatorRoyalty);
        
        if(tokenOwner != artist)
        {
            ownerProfit = ownerProfit.sub(artistRoyalty);
            payable(artist).transfer(artistRoyalty);
        }
        payable(curator).transfer(curatorFee);
        payable(creator).transfer(creatorRoyalty);
        payable(tokenOwner).transfer(ownerProfit);
        
        grassContract.transferFrom(address(this), bidder,tokenId);
        
        emit AuctionEnded(auctions[tokenId].auctionId, tokenId, tokenOwner, curator, bidder, ownerProfit, curatorFee);
        
        unlistToken(tokenId);        
        
    }
    
    function cancelAuction(uint256 tokenId) external nonReentrant auctionExists(tokenId) {
        require(
            auctions[tokenId].tokenOwner == msg.sender || curator == msg.sender,
            "Can only be called by auction artist or curator"
        );
        require(
            uint256(auctions[tokenId].firstBidTime) == 0,
            "Can't cancel an auction once it's begun"
        );
        _cancelAuction(tokenId);
    }
    
    function _cancelAuction(uint256 tokenId) internal {
        address tokenOwner = auctions[tokenId].tokenOwner;
        grassContract.safeTransferFrom(address(this), tokenOwner, tokenId);

        emit AuctionCanceled(auctions[tokenId].auctionId, tokenId, tokenOwner);
        
        unlistToken(tokenId);
        
    }
    
    
    function getEndTime (uint256 tokenId) public view returns(uint256)
    {
        return auctions[tokenId].firstBidTime.add(auctions[tokenId].duration);
    }
    
    function getAuction (uint256 tokenId) public view auctionExists(tokenId) returns(Auction memory)
    {
        return auctions[tokenId];
    }
    
    function createSale (uint256 tokenId, uint256 price) external nonReentrant {
        
        address tokenOwner = grassContract.ownerOf(tokenId);
        require(msg.sender == grassContract.getApproved(tokenId) || msg.sender == tokenOwner, "Caller must be approved or owner for token id");
        
        require(auctions[tokenId].tokenOwner == address(0), "Token is already up for auction");
        
        _saleCounter.increment();
        uint256 _saleId = _saleCounter.current();
        
        sales[tokenId] = Sale({
            saleId: _saleId,
            price: price,
            tokenOwner: tokenOwner
        });
        
        grassContract.transferFrom(tokenOwner, address(this), tokenId);
        
        emit SaleCreated(_saleId, tokenId, price, tokenOwner);
    }
    
    function buySaleToken (uint256 tokenId) external payable saleExists(tokenId) nonReentrant {
        uint256 price = sales[tokenId].price;
        require(msg.value >= price, "Not enough funds sent");
        
        address tokenOwner = sales[tokenId].tokenOwner;
        require(msg.sender != address(0) && msg.sender != tokenOwner, "Owner cannot buy their own tokens");
        
        uint256 ownerProfit = msg.value;
        
        address artist = grassContract.getArtist(tokenId);
        address creator = grassContract.getCreator(tokenId);
        
        uint256 curatorFee = ownerProfit.mul(curatorCutPercentage).div(100);
        uint256 artistRoyalty = ownerProfit.mul(artistRoyaltyPercentage).div(100);
        uint256 creatorRoyalty = ownerProfit.mul(creatorRoyaltyPercentage).div(100);
        
        ownerProfit = ownerProfit.sub(curatorFee);
        ownerProfit = ownerProfit.sub(creatorRoyalty);
        
        if(tokenOwner != artist)
        {
            ownerProfit = ownerProfit.sub(artistRoyalty);
            payable(artist).transfer(artistRoyalty);
        }
        
        payable(curator).transfer(curatorFee);
        payable(creator).transfer(creatorRoyalty);
        payable(tokenOwner).transfer(ownerProfit);
        
        grassContract.safeTransferFrom(address(this),msg.sender,tokenId);
        
        emit SaleComplete(sales[tokenId].saleId, tokenId, tokenOwner, msg.sender, ownerProfit);
        
        unlistToken(tokenId);
    }
    
    function cancelSale(uint256 tokenId) external saleExists(tokenId) nonReentrant {
        require(
            sales[tokenId].tokenOwner == msg.sender || curator == msg.sender,
            "Can only be called by tokenOwner or curator"
        );
        address tokenOwner = sales[tokenId].tokenOwner;
        grassContract.safeTransferFrom(address(this), tokenOwner, tokenId);

        emit SaleCanceled(sales[tokenId].saleId, tokenId, tokenOwner);

        unlistToken(tokenId);

    }
    
    function getSale (uint256 tokenId) public view saleExists(tokenId) returns(Sale memory)
    {
        return sales[tokenId];
    }
    
    function unlistToken(uint tokenId) internal {
        delete sales[tokenId];
        delete auctions[tokenId];
    }
    
    // function getContractFunds() public onlyOwner {
    //     address owner = owner();
    //     payable(owner).transfer(address(this).balance);
    // }
    
    // function getContractBalance() public view onlyOwner returns(uint256) {
    //     return address(this).balance;
    // }
}
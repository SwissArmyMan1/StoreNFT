// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract NFTMarketplace is ReentrancyGuard {
    uint256 private _tokenIdCounter;
    uint256 private _auctionCounter;
    uint256 public platformFee = 250;
    address payable public feeRecipient;

    struct Auction {
        uint256 auctionId;
        bool isActive;
        bool isConcluded;
        uint256 auctionEnd;
        address payable leadingBidder;
        uint256 highestBid;
        address payable itemOwner;
        uint256 nftTokenId;
        address nftAddress;
    }

    struct MarketItem {
        uint256 itemId;
        uint256 tokenId;
        address payable currentOwner;
        uint256 askingPrice;
        bool isSold;
        address nftAddress;
    }

    mapping(uint256 => MarketItem) private itemIdToMarketItem; 
    mapping(uint256 => Auction) private auctionIdToAuction; 

    event ItemListedForSale(
        uint256 indexed itemId,
        uint256 indexed nftTokenId,
        address indexed nftAddress,
        uint256 price,
        address seller
    );
    event ItemBought(
        uint256 indexed itemId,
        uint256 indexed nftTokenId,
        address indexed nftAddress,
        uint256 price,
        address buyer
    );
    event AuctionStarted(
        uint256 indexed auctionId,
        uint256 indexed nftTokenId,
        address indexed seller,
        address nftAddress,
        uint256 auctionEndTime,
        uint256 initialBid
    );
    event BidSubmitted(
        uint256 indexed auctionId,
        address indexed bidder,
        uint256 bidAmount
    );
    event AuctionConcluded(
        uint256 indexed auctionId,
        address indexed winner,
        uint256 winningBid
    );
    event BidReturned(
        address indexed bidder,
        uint256 amount
    );

    event ItemSaleCanceled(uint256 indexed itemId, address indexed seller);
    event AuctionCanceled(uint256 indexed auctionId, address indexed seller);
    event PlatformFeeUpdated(uint256 oldFee, uint256 newFee);

    constructor() {
        feeRecipient = payable(msg.sender);
    }

    function listNFTForSale(address nftAddress, uint256 nftTokenId, uint256 price) public nonReentrant {
        require(price > 0, "Price must be greater than zero");

        IERC721(nftAddress).transferFrom(msg.sender, address(this), nftTokenId);

        _tokenIdCounter++;
        uint256 newItemId = _tokenIdCounter;

        itemIdToMarketItem[newItemId] = MarketItem(
            newItemId,
            nftTokenId,
            payable(msg.sender),
            price,
            false,
            nftAddress
        );

        emit ItemListedForSale(newItemId, nftTokenId, nftAddress, price, msg.sender);
    }

    function buyNFT(uint256 itemId) public payable nonReentrant {
        MarketItem storage marketItem = itemIdToMarketItem[itemId];
        require(msg.value == marketItem.askingPrice, "Submit the asking price");
        require(!marketItem.isSold, "Item has already been sold");

        uint256 fee = (msg.value * platformFee) / 10000;
        uint256 sellerProceeds = msg.value - fee;

        feeRecipient.transfer(fee);
        marketItem.currentOwner.transfer(sellerProceeds);

        IERC721(marketItem.nftAddress).transferFrom(address(this), msg.sender, marketItem.tokenId);

        marketItem.isSold = true;

        emit ItemBought(itemId, marketItem.tokenId, marketItem.nftAddress, marketItem.askingPrice, msg.sender);
    }

    function cancelSale(uint256 itemId) public nonReentrant {
        MarketItem storage marketItem = itemIdToMarketItem[itemId];
        require(!marketItem.isSold, "Item is already sold");
        require(marketItem.currentOwner == msg.sender, "Only owner can cancel sale");

        IERC721(marketItem.nftAddress).transferFrom(address(this), msg.sender, marketItem.tokenId);

        marketItem.isSold = true;

        emit ItemSaleCanceled(itemId, msg.sender);
    }

    function initiateAuction(
        address nftAddress, 
        uint256 tokenId, 
        uint256 startingBid, 
        uint256 duration
    ) 
        public 
        nonReentrant 
    {
        IERC721(nftAddress).transferFrom(msg.sender, address(this), tokenId);

        _auctionCounter++;
        uint256 auctionId = _auctionCounter;

        auctionIdToAuction[auctionId] = Auction(
            auctionId,
            true, // isActive
            false, // isConcluded
            block.timestamp + duration,
            payable(address(0)),  // leadingBidder
            startingBid,          // highestBid
            payable(msg.sender),  // itemOwner
            tokenId,
            nftAddress
        );

        emit AuctionStarted(
            auctionId,
            tokenId,
            msg.sender,
            nftAddress,
            block.timestamp + duration,
            startingBid
        );
    }

    function placeBid(uint256 auctionId) public payable nonReentrant {
        Auction storage auctionDetails = auctionIdToAuction[auctionId];
        require(auctionDetails.isActive, "Auction is not active");
        require(block.timestamp < auctionDetails.auctionEnd, "Auction has already ended");
        require(msg.value > auctionDetails.highestBid, "There is already a higher bid");

        if (auctionDetails.leadingBidder != address(0)) {
            (bool success, ) = auctionDetails.leadingBidder.call{value: auctionDetails.highestBid}("");
            require(success, "Failed to return the previous highest bid");
            emit BidReturned(auctionDetails.leadingBidder, auctionDetails.highestBid);
        }

        auctionDetails.leadingBidder = payable(msg.sender);
        auctionDetails.highestBid = msg.value;

        emit BidSubmitted(auctionId, msg.sender, msg.value);
    }

    function concludeAuction(uint256 auctionId) public nonReentrant {
        Auction storage auction = auctionIdToAuction[auctionId];
        require(block.timestamp >= auction.auctionEnd, "Auction is still ongoing");
        require(!auction.isConcluded, "Auction has already concluded");
        require(
            msg.sender == auction.itemOwner || msg.sender == feeRecipient,
            "Not authorized to conclude"
        );

        auction.isConcluded = true;
        auction.isActive = false;

        if (auction.leadingBidder != address(0)) {
            uint256 fee = (auction.highestBid * platformFee) / 10000;
            uint256 sellerProceeds = auction.highestBid - fee;

            feeRecipient.transfer(fee);
            auction.itemOwner.transfer(sellerProceeds);

            IERC721(auction.nftAddress).transferFrom(
                address(this),
                auction.leadingBidder,
                auction.nftTokenId
            );
        } else {
            IERC721(auction.nftAddress).transferFrom(
                address(this),
                auction.itemOwner,
                auction.nftTokenId
            );
        }

        emit AuctionConcluded(auctionId, auction.leadingBidder, auction.highestBid);
    }

    function cancelAuction(uint256 auctionId) public nonReentrant {
        Auction storage auction = auctionIdToAuction[auctionId];
        require(auction.isActive, "Auction is not active");
        require(auction.itemOwner == msg.sender, "Only the owner can cancel the auction");
        require(auction.leadingBidder == address(0), "Cannot cancel if someone has already bid");

        auction.isActive = false;
        auction.isConcluded = true;

        IERC721(auction.nftAddress).transferFrom(address(this), msg.sender, auction.nftTokenId);

        emit AuctionCanceled(auctionId, msg.sender);
    }

    function setPlatformFee(uint256 newFee) external {
        require(msg.sender == feeRecipient, "Only fee recipient can set fee");
        emit PlatformFeeUpdated(platformFee, newFee);
        platformFee = newFee;
    }
}
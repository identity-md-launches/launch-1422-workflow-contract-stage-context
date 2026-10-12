// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IHiveWars {
    function isSeasonFinalized(uint256 season) external view returns (bool);
    function isEligible(address account, uint256 season) external view returns (bool);
    function seasonWinner(uint256 season) external view returns (uint8);
}

/// @notice One immutable, fully onchain, soulbound conqueror crest per eligible wallet and season.
contract ConquerorBadge is ERC721, ReentrancyGuard {
    using Strings for uint256;

    IHiveWars public immutable hiveWars;
    uint256 public totalSupply;
    mapping(address => mapping(uint256 => uint256)) public badgeOf;

    struct BadgeData {
        uint256 season;
        uint8 colony;
    }

    mapping(uint256 => BadgeData) public badgeData;

    error InvalidGame();
    error SeasonNotEnded();
    error NotEligible();
    error AlreadyClaimed();
    error Soulbound();

    event BadgeClaimed(address indexed player, uint256 indexed season, uint256 indexed tokenId, uint8 colony);
    event Locked(uint256 tokenId);

    /// @param hiveWars_ The previously deployed $contract:HiveWars. No constructor external calls.
    constructor(address hiveWars_) ERC721("Hive Wars Conqueror", "COMB") {
        if (hiveWars_ == address(0)) revert InvalidGame();
        hiveWars = IHiveWars(hiveWars_);
    }

    function claim(uint256 season) external nonReentrant returns (uint256 tokenId) {
        if (address(hiveWars).code.length == 0) revert InvalidGame();
        if (!hiveWars.isSeasonFinalized(season)) revert SeasonNotEnded();
        if (badgeOf[msg.sender][season] != 0) revert AlreadyClaimed();
        if (!hiveWars.isEligible(msg.sender, season)) revert NotEligible();
        uint8 colony = hiveWars.seasonWinner(season);
        if (colony >= 4) revert NotEligible();
        tokenId = ++totalSupply;
        badgeOf[msg.sender][season] = tokenId;
        badgeData[tokenId] = BadgeData(season, colony);
        _safeMint(msg.sender, tokenId);
        emit Locked(tokenId);
        emit BadgeClaimed(msg.sender, season, tokenId, colony);
    }

    function approve(address, uint256) public pure override {
        revert Soulbound();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert Soulbound();
    }

    /// @notice ERC-5192: every minted token is permanently locked.
    function locked(uint256 tokenId) external view returns (bool) {
        _requireOwned(tokenId);
        return true;
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == 0xb45a3c0e || super.supportsInterface(interfaceId);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        address account = _requireOwned(tokenId);
        BadgeData memory data = badgeData[tokenId];
        string memory season = data.season.toString();
        (string memory colony, string memory color) = _colonyStyle(data.colony);
        string memory svg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">',
            '<rect width="512" height="512" fill="#0B0C10"/>',
            '<polygon points="256,36 446,146 446,366 256,476 66,366 66,146" fill="',
            color,
            '"/><polygon points="256,56 428,156 428,356 256,456 84,356 84,156" fill="#14151B"/>',
            '<g text-anchor="middle" font-family="monospace" fill="',
            color,
            '"><text x="256" y="174" font-size="22">HIVE WARS</text>'
        );
        svg = string.concat(
            svg,
            '<text x="256" y="236" font-size="18">SEASON ',
            season,
            ' CONQUEROR</text><text x="256" y="294" font-size="34">',
            colony,
            '</text><text x="256" y="348" font-size="20">',
            _shortAddress(account),
            "</text></g></svg>"
        );
        string memory json = string.concat(
            '{"name":"SEASON ',
            season,
            ' CONQUEROR","description":"Hive Wars: Battle for the Comb. A permanent, soulbound conqueror badge.",',
            '"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)),
            '","attributes":[{"trait_type":"Season","value":',
            season,
            '},{"trait_type":"Colony","value":"',
            colony,
            '"}]}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (_ownerOf(tokenId) != address(0)) revert Soulbound();
        return super._update(to, tokenId, auth);
    }

    function _colonyStyle(uint8 colony) private pure returns (string memory name_, string memory color) {
        if (colony == 0) return ("Amber", "#F5A524");
        if (colony == 1) return ("Obsidian", "#8B8BA7");
        if (colony == 2) return ("Jade", "#2BB673");
        return ("Crimson", "#E5484D");
    }

    function _shortAddress(address account) private pure returns (string memory) {
        bytes memory full = bytes(Strings.toHexString(account));
        bytes memory short = new bytes(13);
        for (uint256 i; i < 6; ++i) {
            short[i] = full[i];
        }
        short[6] = ".";
        short[7] = ".";
        short[8] = ".";
        for (uint256 i; i < 4; ++i) {
            short[i + 9] = full[i + 38];
        }
        return string(short);
    }
}

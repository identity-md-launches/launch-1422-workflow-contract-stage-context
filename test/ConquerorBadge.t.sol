// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HiveTestBase, ConquerorBadge} from "./TestBase.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract BadgeReceiver is IERC721Receiver {
    ConquerorBadge public badge;
    uint256 public season;
    bool public reject;
    bool public reentered;
    bytes public result;

    function claim(ConquerorBadge badge_, uint256 season_, bool reject_) external {
        badge = badge_;
        season = season_;
        reject = reject_;
        badge_.claim(season_);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        (reentered, result) = address(badge).call(abi.encodeCall(badge.claim, (season)));
        if (reject) revert("receiver rejected");
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract BadgeGameStub {
    uint8 public seasonWinner;
    bool public isSeasonFinalized = true;
    bool public eligible = true;

    constructor(uint8 winner) {
        seasonWinner = winner;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        bytes4 selector = bytes4(data[:4]);
        if (selector == bytes4(keccak256("isSeasonFinalized(uint256)"))) return abi.encode(isSeasonFinalized);
        if (selector == bytes4(keccak256("isEligible(address,uint256)"))) return abi.encode(eligible);
        if (selector == bytes4(keccak256("seasonWinner(uint256)"))) return abi.encode(seasonWinner);
        revert("unknown selector");
    }
}

contract ConquerorBadgeTest is HiveTestBase {
    function test_onlyEndedFinalizedEligibleSeasonCanClaim() public {
        vm.prank(alice);
        vm.expectRevert(ConquerorBadge.SeasonNotEnded.selector);
        badge.claim(1);
        _join(alice, 0);
        _deploy(alice, 0, 1_000 ether);
        _atEpoch(31);
        vm.prank(alice);
        vm.expectRevert(ConquerorBadge.SeasonNotEnded.selector);
        badge.claim(1);
        _settleThrough(30);
        vm.prank(bob);
        vm.expectRevert(ConquerorBadge.NotEligible.selector);
        badge.claim(1);
        vm.prank(alice);
        uint256 id = badge.claim(1);
        assertEq(id, 1);
        assertEq(badge.ownerOf(id), alice);
        assertEq(badge.balanceOf(alice), 1);
        assertEq(badge.badgeOf(alice, 1), id);
        assertEq(badge.totalSupply(), 1);
        (uint256 season, uint8 colony) = badge.badgeData(id);
        assertEq(season, 1);
        assertEq(colony, 0);
    }

    function test_onePerWalletPerSeasonAndMultipleSeasons() public {
        _prepareWinner();
        vm.startPrank(alice);
        badge.claim(1);
        vm.expectRevert(ConquerorBadge.AlreadyClaimed.selector);
        badge.claim(1);
        vm.stopPrank();
        _atEpoch(61);
        _settleThrough(60);
        vm.prank(alice);
        assertEq(badge.claim(2), 2);
        assertEq(badge.balanceOf(alice), 2);
        assertEq(badge.badgeOf(alice, 2), 2);
        assertEq(badge.totalSupply(), 2);
    }

    function test_multipleWinnersCanEachClaim() public {
        _join(alice, 0);
        _join(bob, 0);
        _deploy(alice, 0, 1_000 ether);
        _deploy(bob, 1, 1_000 ether);
        _atEpoch(31);
        _settleThrough(30);
        vm.prank(alice);
        badge.claim(1);
        vm.prank(bob);
        badge.claim(1);
        assertEq(badge.totalSupply(), 2);
        assertEq(badge.ownerOf(1), alice);
        assertEq(badge.ownerOf(2), bob);
    }

    function test_allTransfersAndApprovalsRevert() public {
        _prepareWinner();
        vm.startPrank(alice);
        badge.claim(1);
        vm.expectRevert(ConquerorBadge.Soulbound.selector);
        badge.transferFrom(alice, bob, 1);
        vm.expectRevert(ConquerorBadge.Soulbound.selector);
        badge.safeTransferFrom(alice, bob, 1);
        vm.expectRevert(ConquerorBadge.Soulbound.selector);
        badge.safeTransferFrom(alice, bob, 1, "payload");
        vm.expectRevert(ConquerorBadge.Soulbound.selector);
        badge.approve(bob, 1);
        vm.expectRevert(ConquerorBadge.Soulbound.selector);
        badge.setApprovalForAll(bob, true);
        vm.expectRevert();
        badge.transferFrom(alice, address(0), 1);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(ConquerorBadge.Soulbound.selector);
        badge.transferFrom(alice, bob, 1);
        assertEq(badge.ownerOf(1), alice);
        assertTrue(badge.locked(1));
        assertEq(badge.getApproved(1), address(0));
        assertFalse(badge.isApprovedForAll(alice, bob));
        (bool ok,) = address(badge).call(abi.encodeWithSignature("burn(uint256)", 1));
        assertFalse(ok);
    }

    function test_erc165InterfacesAndNonexistentTokens() public {
        assertTrue(badge.supportsInterface(0x01ffc9a7));
        assertTrue(badge.supportsInterface(0x80ac58cd));
        assertTrue(badge.supportsInterface(0x5b5e139f));
        assertTrue(badge.supportsInterface(0xb45a3c0e));
        assertFalse(badge.supportsInterface(0xffffffff));
        vm.expectRevert();
        badge.tokenURI(1);
        vm.expectRevert();
        badge.locked(1);
        vm.expectRevert(ConquerorBadge.InvalidGame.selector);
        new ConquerorBadge(address(0));
    }

    function test_realWinnerOnchainJSONSVGAndAttributes() public {
        _prepareWinner();
        vm.prank(alice);
        badge.claim(1);
        _checkMetadata(badge, 1, "Amber", "#F5A524");
        string memory before = badge.tokenURI(1);
        _join(alice, 3);
        assertEq(badge.tokenURI(1), before, "past badge art is immutable");
    }

    function test_allColonyPalettesAndMultiDigitSeasons() public {
        string[4] memory names = ["Amber", "Obsidian", "Jade", "Crimson"];
        string[4] memory colors = ["#F5A524", "#8B8BA7", "#2BB673", "#E5484D"];
        for (uint8 i; i < 4; ++i) {
            ConquerorBadge artBadge = new ConquerorBadge(address(new BadgeGameStub(i)));
            vm.prank(alice);
            artBadge.claim(123);
            _checkMetadata(artBadge, 123, names[i], colors[i]);
        }
    }

    function test_safeMintRejectingReceiverRollsBackAndCanRetry() public {
        BadgeReceiver receiver = new BadgeReceiver();
        _prepareReceiver(address(receiver));
        vm.expectRevert(bytes("receiver rejected"));
        receiver.claim(badge, 1, true);
        assertEq(badge.totalSupply(), 0);
        assertEq(badge.badgeOf(address(receiver), 1), 0);
        assertEq(badge.balanceOf(address(receiver)), 0);
        receiver.claim(badge, 1, false);
        assertEq(badge.ownerOf(1), address(receiver));
        assertEq(badge.totalSupply(), 1);
    }

    function test_receiverCannotReenterMint() public {
        BadgeReceiver receiver = new BadgeReceiver();
        _prepareReceiver(address(receiver));
        receiver.claim(badge, 1, false);
        assertFalse(receiver.reentered());
        assertEq(receiver.result(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(badge.totalSupply(), 1);
        assertEq(badge.balanceOf(address(receiver)), 1);
    }

    function _prepareReceiver(address receiver) private {
        _fund(receiver);
        _join(receiver, 0);
        _deploy(receiver, 0, 1_000 ether);
        _atEpoch(31);
        _settleThrough(30);
    }

    function _checkMetadata(ConquerorBadge target, uint256 season, string memory colony, string memory color)
        private
        view
    {
        string memory json = string(_decodeURI(target.tokenURI(1), "data:application/json;base64,"));
        assertEq(vm.parseJsonString(json, ".name"), string.concat("SEASON ", vm.toString(season), " CONQUEROR"));
        assertEq(vm.parseJsonUint(json, ".attributes[0].value"), season);
        assertEq(vm.parseJsonString(json, ".attributes[0].trait_type"), "Season");
        assertEq(vm.parseJsonString(json, ".attributes[1].value"), colony);
        assertEq(vm.parseJsonString(json, ".attributes[1].trait_type"), "Colony");
        string memory svg = string(_decodeURI(vm.parseJsonString(json, ".image"), "data:image/svg+xml;base64,"));
        assertTrue(_contains(svg, 'width="512" height="512"'));
        assertTrue(_contains(svg, 'viewBox="0 0 512 512"'));
        assertTrue(_contains(svg, "<polygon"));
        assertTrue(_contains(svg, color));
        assertTrue(_contains(svg, colony));
        assertTrue(_contains(svg, string.concat("SEASON ", vm.toString(season), " CONQUEROR")));
        bytes memory full = bytes(vm.toLowercase(vm.toString(alice)));
        bytes memory short = new bytes(13);
        for (uint256 i; i < 6; ++i) {
            short[i] = full[i];
        }
        short[6] = ".";
        short[7] = ".";
        short[8] = ".";
        for (uint256 i; i < 4; ++i) {
            short[9 + i] = full[38 + i];
        }
        assertTrue(_contains(svg, string(short)));
    }

    function _contains(string memory haystack, string memory needle) private pure returns (bool) {
        bytes memory a = bytes(haystack);
        bytes memory b = bytes(needle);
        if (b.length > a.length) return false;
        for (uint256 i; i <= a.length - b.length; ++i) {
            bool equal = true;
            for (uint256 j; j < b.length; ++j) {
                if (a[i + j] != b[j]) {
                    equal = false;
                    break;
                }
            }
            if (equal) return true;
        }
        return false;
    }

    // Independent test-only Base64 decoder, so JSON and SVG are checked after actual decoding.
    function _decodeURI(string memory uri, string memory prefix) private pure returns (bytes memory decoded) {
        bytes memory raw = bytes(uri);
        bytes memory p = bytes(prefix);
        require(raw.length >= p.length);
        for (uint256 i; i < p.length; ++i) {
            require(raw[i] == p[i], "URI prefix");
        }
        uint256 length = raw.length - p.length;
        require(length % 4 == 0);
        uint256 outputLength = length / 4 * 3;
        if (raw[raw.length - 1] == "=") --outputLength;
        if (raw[raw.length - 2] == "=") --outputLength;
        decoded = new bytes(outputLength);
        uint256 accumulator;
        uint256 bits;
        uint256 index;
        for (uint256 i = p.length; i < raw.length && raw[i] != "="; ++i) {
            accumulator = (accumulator << 6) | _digit(uint8(raw[i]));
            bits += 6;
            if (bits >= 8) {
                bits -= 8;
                decoded[index++] = bytes1(uint8(accumulator >> bits));
            }
        }
        require(index == outputLength);
    }

    function _digit(uint8 c) private pure returns (uint256) {
        if (c >= 65 && c <= 90) return c - 65;
        if (c >= 97 && c <= 122) return c - 71;
        if (c >= 48 && c <= 57) return c + 4;
        if (c == 43) return 62;
        if (c == 47) return 63;
        revert("invalid base64");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {HiveTestBase, ConquerorBadge} from "./TestBase.sol";

contract BadgeClaimLedgerHandler is Test {
    ConquerorBadge public immutable badge;
    address[4] public actors;
    uint256 public minted;
    uint256[3][4] public ids;
    mapping(uint256 => bytes32) public metadataHash;

    constructor(ConquerorBadge badge_, address[4] memory actors_) {
        badge = badge_;
        actors = actors_;
    }

    function claim(uint256 actorSeed, uint256 seasonSeed) public {
        uint256 actor = actorSeed % 4;
        uint256 season = seasonSeed % 4;
        // The fixture gives actors 0 and 2 winning stakes in seasons 1 and 2. This
        // entitlement is known from the scenario, not read from isEligible/badgeOf.
        vm.prank(actors[actor]);
        if (season == 0 || season == 3) {
            vm.expectRevert(ConquerorBadge.SeasonNotEnded.selector);
            badge.claim(season);
        } else if (ids[actor][season] != 0) {
            vm.expectRevert(ConquerorBadge.AlreadyClaimed.selector);
            badge.claim(season);
        } else if (actor % 2 == 1) {
            vm.expectRevert(ConquerorBadge.NotEligible.selector);
            badge.claim(season);
        } else {
            uint256 id = badge.claim(season);
            assertEq(id, minted + 1, "claim skipped or reused token id");
            ids[actor][season] = id;
            ++minted;
            metadataHash[id] = keccak256(bytes(badge.tokenURI(id)));
        }
    }

    function attemptTransfer(uint256 callerSeed, uint256 tokenSeed, uint256 recipientSeed, uint256 variant) external {
        uint256 id = bound(tokenSeed, 1, minted);
        address owner = badge.ownerOf(id);
        address recipient = actors[recipientSeed % 4];
        vm.prank(actors[callerSeed % 4]);
        vm.expectRevert(ConquerorBadge.Soulbound.selector);
        if (variant % 3 == 0) badge.transferFrom(owner, recipient, id);
        else if (variant % 3 == 1) badge.safeTransferFrom(owner, recipient, id);
        else badge.safeTransferFrom(owner, recipient, id, "must remain locked");
    }

    function attemptApproval(uint256 callerSeed, uint256 tokenSeed, uint256 recipientSeed, bool all, bool approved)
        external
    {
        uint256 id = bound(tokenSeed, 1, minted);
        address recipient = actors[recipientSeed % 4];
        vm.prank(actors[callerSeed % 4]);
        vm.expectRevert(ConquerorBadge.Soulbound.selector);
        if (all) badge.setApprovalForAll(recipient, approved);
        else badge.approve(recipient, id);
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 48
/// forge-config: default.invariant.fail-on-revert = true
contract ConquerorBadgeClaimInvariantTest is HiveTestBase {
    BadgeClaimLedgerHandler private handler;

    function setUp() public override {
        super.setUp();
        _join(alice, 0);
        _join(bob, 1);
        _join(carol, 0);
        _join(dave, 3);
        _deploy(alice, 0, 2_000 ether);
        _deploy(bob, 0, 1_000 ether); // Meets stake threshold, but loses.
        _deploy(carol, 1, 1_000 ether);
        _atEpoch(61);
        _settleThrough(60);
        handler = new BadgeClaimLedgerHandler(badge, [alice, bob, carol, dave]);
        handler.claim(0, 2); // Seed with a real badge and exercise reverse season order.
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.claim.selector;
        selectors[1] = handler.attemptTransfer.selector;
        selectors[2] = handler.attemptApproval.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_badgesRemainUniqueOwnedLockedAndUnchanged() public view {
        uint256 count;
        for (uint256 actor; actor < 4; ++actor) {
            address account = handler.actors(actor);
            uint256 walletCount;
            for (uint256 season = 1; season <= 2; ++season) {
                uint256 id = handler.ids(actor, season);
                assertEq(badge.badgeOf(account, season), id);
                if (id == 0) continue;
                ++count;
                ++walletCount;
                assertEq(badge.ownerOf(id), account);
                assertTrue(badge.locked(id));
                assertEq(badge.getApproved(id), address(0));
                (uint256 recordedSeason, uint8 colony) = badge.badgeData(id);
                assertEq(recordedSeason, season);
                assertEq(colony, 0);
                assertEq(keccak256(bytes(badge.tokenURI(id))), handler.metadataHash(id));
            }
            assertEq(badge.balanceOf(account), walletCount);
            assertEq(badge.badgeOf(account, 0), 0);
            assertEq(badge.badgeOf(account, 3), 0);
            for (uint256 other; other < 4; ++other) {
                assertFalse(badge.isApprovedForAll(account, handler.actors(other)));
            }
        }
        assertEq(badge.totalSupply(), count);
        assertEq(count, handler.minted());
        assertLe(count, 4);
    }

    function test_reverseSeasonClaimsCannotReuseOrStealBadge() public {
        handler.claim(0, 1);
        handler.claim(2, 2);
        handler.claim(2, 1);
        handler.claim(0, 2); // Duplicate.
        handler.claim(1, 1); // Losing colony, despite enough active epochs.
        handler.claim(3, 2); // No stake.
        handler.claim(0, 3); // Future season.
        handler.claim(0, 0); // Invalid season.
        invariant_badgesRemainUniqueOwnedLockedAndUnchanged();
        assertEq(badge.totalSupply(), 4);
    }
}

contract CrossSeasonBadgeReceiver is IERC721Receiver {
    ConquerorBadge private immutable badge;
    uint256 private alternateSeason;
    bool private wrongSelector;
    bool public nestedSucceeded;
    bytes public nestedResult;
    bool public transferSucceeded;
    bytes public transferResult;
    bytes32 public uriDuringCallback;

    constructor(ConquerorBadge badge_) {
        badge = badge_;
    }

    function claim(uint256 season, bool reject) external returns (uint256) {
        alternateSeason = season == 1 ? 2 : 1;
        wrongSelector = reject;
        return badge.claim(season);
    }

    function onERC721Received(address operator, address from, uint256 id, bytes calldata data)
        external
        returns (bytes4)
    {
        require(msg.sender == address(badge) && operator == address(this), "wrong mint sender/operator");
        require(from == address(0) && data.length == 0, "not a mint");
        require(badge.ownerOf(id) == address(this) && badge.locked(id), "callback sees unlocked or unowned badge");
        uriDuringCallback = keccak256(bytes(badge.tokenURI(id)));
        (nestedSucceeded, nestedResult) = address(badge).call(abi.encodeCall(badge.claim, (alternateSeason)));
        (transferSucceeded, transferResult) =
            address(badge).call(abi.encodeCall(badge.transferFrom, (address(this), address(this), id)));
        return wrongSelector ? bytes4(0) : IERC721Receiver.onERC721Received.selector;
    }
}

contract ConquerorBadgeCallbackEdgesTest is HiveTestBase {
    CrossSeasonBadgeReceiver private receiver;

    function setUp() public override {
        super.setUp();
        receiver = new CrossSeasonBadgeReceiver(badge);
        _fund(address(receiver));
        _join(address(receiver), 0);
        _deploy(address(receiver), 0, 1_000 ether);
        _atEpoch(61);
        _settleThrough(60);
    }

    function test_crossSeasonReentryCannotMintAnotherOtherwiseEligibleBadge() public {
        assertTrue(game.isEligible(address(receiver), 1));
        assertTrue(game.isEligible(address(receiver), 2));
        vm.expectEmit(true, true, true, true, address(badge));
        emit Transfer(address(0), address(receiver), 1);
        vm.expectEmit(false, false, false, true, address(badge));
        emit Locked(1);
        vm.expectEmit(true, true, true, true, address(badge));
        emit BadgeClaimed(address(receiver), 2, 1, 0);
        assertEq(receiver.claim(2, false), 1);
        assertFalse(receiver.nestedSucceeded());
        assertEq(receiver.nestedResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertFalse(receiver.transferSucceeded());
        assertEq(receiver.transferResult(), abi.encodeWithSelector(ConquerorBadge.Soulbound.selector));
        assertEq(receiver.uriDuringCallback(), keccak256(bytes(badge.tokenURI(1))));
        assertEq(badge.totalSupply(), 1);
        assertEq(badge.badgeOf(address(receiver), 1), 0);
        assertEq(badge.badgeOf(address(receiver), 2), 1);
        assertEq(receiver.claim(1, false), 2);
        assertEq(badge.totalSupply(), 2);
    }

    function test_wrongReceiverSelectorRollsBackMetadataIdAndClaimBeforeRetry() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(receiver)));
        receiver.claim(2, true);
        assertEq(badge.totalSupply(), 0);
        assertEq(badge.balanceOf(address(receiver)), 0);
        assertEq(badge.badgeOf(address(receiver), 2), 0);
        (uint256 season, uint8 colony) = badge.badgeData(1);
        assertEq(season, 0);
        assertEq(colony, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        badge.ownerOf(1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        badge.tokenURI(1);
        assertEq(receiver.claim(2, false), 1, "failed safe mint consumed token id");
        assertEq(badge.badgeOf(address(receiver), 2), 1);
        assertEq(badge.ownerOf(1), address(receiver));
    }

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Locked(uint256 tokenId);
    event BadgeClaimed(address indexed player, uint256 indexed season, uint256 indexed tokenId, uint8 colony);
}

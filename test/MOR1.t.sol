// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LockMultiplierMath} from "../src/mor/LockMultiplierMath.sol";

/// MOR-1: `claimFor` skips authorisation whenever the staker has set a `claimReceiver`, and a
/// claim permanently resets the staker's lock multiplier.
///   DepositPool.sol:284-292  claimFor: the `if (claimReceiver != 0)` branch has no caller check
///   DepositPool.sol:531      multiplier_ = _getUserTotalMultiplier(0, 0, userData.referrer)
///   DepositPool.sol:551-552  userData.claimLockStart = 0; userData.claimLockEnd = 0;
///   DepositPool.sol:744      LockMultiplierMath.getLockPeriodMultiplier(start, end)
/// This measures what the reset destroys.
contract MOR1 is Test {
    uint256 constant PRECISION = 1e25;

    /// The multiplier is a pure function of the recorded window: it does not decay with time,
    /// so it is still at full value when the lock expires and a forced claim can take it.
    function test_MOR1_multiplierDoesNotDecayWithTime() public {
        uint128 start = 1721908800;              // period start
        uint128 end = start + 365 days * 5;
        uint256 atLock = LockMultiplierMath.getLockPeriodMultiplier(start, end);

        vm.warp(uint256(end) + 400 days);        // long after the lock expired
        uint256 afterExpiry = LockMultiplierMath.getLockPeriodMultiplier(start, end);

        assertEq(afterExpiry, atLock, "the recorded window alone decides the multiplier");
        assertGt(atLock, PRECISION, "and it is above the floor");
        emit log_named_uint("multiplier held after a 5-year lock (1e25 = 1x)", atLock);
    }

    /// What `_claim` substitutes: (0,0) collapses to the floor.
    function test_MOR1_resetCollapsesToTheFloor() public pure {
        assertEq(LockMultiplierMath.getLockPeriodMultiplier(0, 0), PRECISION, "(0,0) is the minimum");
    }

    /// The size of the loss for a realistic lock.
    function test_MOR1_lossFromAForcedClaim() public {
        uint128 start = 1721908800;
        uint128 end = start + 365 days * 10;
        uint256 held = LockMultiplierMath.getLockPeriodMultiplier(start, end);
        uint256 afterForcedClaim = LockMultiplierMath.getLockPeriodMultiplier(0, 0);

        uint256 deposited = 100_000e18;
        uint256 virtualBefore = (deposited * held) / PRECISION;
        uint256 virtualAfter = (deposited * afterForcedClaim) / PRECISION;
        emit log_named_uint("virtualDeposited before the forced claim", virtualBefore);
        emit log_named_uint("virtualDeposited after  the forced claim", virtualAfter);
        emit log_named_uint("emission weight destroyed (x1e25)", ((virtualBefore - virtualAfter) * PRECISION) / virtualBefore);
        assertGt(virtualBefore, virtualAfter * 2, "a forced claim removes most of the staker's weight");
    }

    /// Massive: over every lock window the reset always lands on the floor, never partway.
    function testFuzz_MOR1_resetIsAlwaysTotal(uint128 start, uint32 span) public pure {
        start = uint128(bound(uint256(start), 1721908800, 2211192000 - 400 days));
        uint128 end = start + uint128(bound(uint256(span), 30 days, 3650 days));
        uint256 held = LockMultiplierMath.getLockPeriodMultiplier(start, end);
        assertGe(held, PRECISION, "never below the floor");
        assertEq(LockMultiplierMath.getLockPeriodMultiplier(0, 0), PRECISION, "reset always lands on the floor");
    }
}

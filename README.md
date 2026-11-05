# BP-006 PoC — third-party provider bid blocks a model owner's only stake exit

Self-contained Foundry project. Nothing here is broadcast, no real key is used, and no protocol
owner, admin or multisig is pranked: the actors are two `makeAddr` test wallets plus, in the
live-state test, the real model owner and the real holder of the blocking bid — on a pinned fork
those calls are reads of deployed state. `deal` funds the two synthetic wallets; it is a fixture,
not a role.

`forge-std` is vendored under `lib/forge-std`, so a plain `git clone` needs no submodule step and no
package install. Run from the repository root:

```
BASE_RPC=https://base-rpc.publicnode.com forge test -vv
```

Expected, at the time of writing:

```
Ran 7 tests for test/LumerinModelStakeFreeze.t.sol:LumerinModelStakeFreezeTest
[PASS] test_candidate_liveModelIsAlreadyLockedAtThePinnedBlock()
[PASS] test_candidate_oneWalletLocksEveryActiveModelItPointsAt()
[PASS] test_candidate_thirdPartyBidBlocksTheOwnersOnlyStakeExit()
[PASS] test_candidate_topUpIntoALockedModelIsAcceptedAndAlsoLocked()
[PASS] test_control_onlyTheProviderThatParkedTheBidCanReleaseIt()
[PASS] test_control_ownerExitsWithItsStakeWhenNoBidIsParked()
[PASS] test_control_ownerKeepsAdministrationOfALockedModelButNotExit()
Suite result: ok. 7 passed; 0 failed; 0 skipped
```

The two halves the report pairs, if you want them separately:

```
BASE_RPC=https://base-rpc.publicnode.com forge test --match-test test_candidate_ -vv   # exit 0
BASE_RPC=https://base-rpc.publicnode.com forge test --match-test test_control_    -vv  # exit 0
```

Fork target: `vm.createSelectFork(vm.envString("BASE_RPC"), 53467416)` — Base mainnet, chainId 8453,
diamond `0x6aBE1d282f72B474E54527D93b979A4f64d3030a`. An archive node is required; the RPC used here
answers POST only with a browser `User-Agent`, which `foundry.toml` does not need because forge sets
one. `test-output.log` in this directory is the transcript of the run that produced the report.

`setUp` asserts `getToken() == MOR`, that the deployed error selectors are
`ModelHasActiveBids() == 0x633910a0` and
`InsufficientRightsForOperation(address,address) == 0x2e980d14`, and then reads
`modelMinimumStake` / `providerMinimumStake` / `bidFee` / `bidMinPricePerSecond` from the live
diamond — so a fork pointing at other code cannot pass silently.

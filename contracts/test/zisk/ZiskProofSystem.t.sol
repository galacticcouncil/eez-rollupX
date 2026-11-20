// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test, console2} from "forge-std/Test.sol";

import {IRollupContract} from "eez-core-protocol/src/interfaces/IRollup.sol";
import {Rollup} from "eez-core-protocol/src/rollupContract/Rollup.sol";

import {IRollupVerificationKeys, ZiskProofSystem, ZiskPublicValues} from "../../src/zisk/ZiskProofSystem.sol";
import {IZiskVerifier} from "../../src/zisk/IZiskVerifier.sol";
import {MockZiskVerifier} from "../../src/zisk/MockZiskVerifier.sol";
import {RollupDeployment} from "../utils/RollupDeployment.sol";

/// @notice Minimal `IRollupContract`-conforming manager exposing the `verificationKey(address)` getter that
///         `Rollup.sol` gets from its public mapping; the vkey per proof system is configurable. Implementing
///         the pinned `IRollupContract` makes the build fail if the pin's manager interface changes shape.
contract MockRollupManager is IRollupContract {
    mapping(address proofSystem => bytes32 vkey) public verificationKey;
    uint64 public rollupId;

    error NotAllowed(address proofSystem);

    function setVerificationKey(address proofSystem, bytes32 vkey) external {
        verificationKey[proofSystem] = vkey;
    }

    function rollupContractRegistered(uint64 rollupId_, address) external {
        rollupId = rollupId_;
    }

    function checkProofSystemsAndGetVkeys(address[] calldata proofSystems)
        external
        view
        returns (bytes32[] memory vkeys)
    {
        vkeys = new bytes32[](proofSystems.length);
        for (uint256 i = 0; i < proofSystems.length; ++i) {
            bytes32 vk = verificationKey[proofSystems[i]];
            if (vk == bytes32(0)) revert NotAllowed(proofSystems[i]);
            vkeys[i] = vk;
        }
    }

    function getCustomData(uint64) external pure returns (bytes memory) {
        return "";
    }
}

/// @title ZiskProofSystemTest
/// @notice Unit tests of the EEZ adapter against `MockZiskVerifier` and a mock rollup manager.
contract ZiskProofSystemTest is Test {
    uint32 internal constant SCHEMA = 1;
    uint64 internal constant ROLLUP_ID = 7;
    bytes32 internal constant ROOT_C = keccak256("rootCVadcopFinal");
    bytes32 internal constant VKEY = keccak256("program vkey");
    bytes32 internal constant HASH = keccak256("publicInputsHash");

    MockZiskVerifier internal verifier;
    MockRollupManager internal manager;
    ZiskProofSystem internal ps;
    bytes internal proofBytes;

    function setUp() public {
        verifier = new MockZiskVerifier();
        manager = new MockRollupManager();
        ps = new ZiskProofSystem(address(manager), address(verifier), ROOT_C, SCHEMA, ROLLUP_ID);
        manager.setVerificationKey(address(ps), VKEY);

        // Opaque to the mock; sized like a real blake3 pilfflonk proof (abi.encode(bytes32[211]), 6,752 bytes).
        proofBytes = new bytes(6752);
        for (uint256 i = 0; i < proofBytes.length; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            proofBytes[i] = bytes1(uint8(i)); // i mod 256, on purpose
        }
    }

    // ------------------------------------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------------------------------------

    function _publicValues(
        uint32 schema,
        bytes32 hash,
        bytes32 vkey,
        uint64 rollupId
    )
        internal
        pure
        returns (bytes memory)
    {
        return ZiskPublicValues.encode(schema, hash, vkey, rollupId);
    }

    function _wellFormed() internal pure returns (bytes memory) {
        return _publicValues(SCHEMA, HASH, VKEY, ROLLUP_ID);
    }

    function _blob(bytes32 programVK, bytes memory publicValues) internal view returns (bytes memory) {
        return abi.encode(programVK, publicValues, proofBytes);
    }

    /// @dev Exact-calldata expectation: the adapter must forward (programVK, ROOT_C, publicValues, proofBytes).
    function _expectVerifierCall(bytes32 programVK, bytes memory publicValues, uint64 count) internal {
        vm.expectCall(
            address(verifier),
            abi.encodeCall(IZiskVerifier.verifySnarkProof, (programVK, ROOT_C, publicValues, proofBytes)),
            count
        );
    }

    function _expectNoVerifierCall() internal {
        vm.expectCall(address(verifier), abi.encodeWithSelector(IZiskVerifier.verifySnarkProof.selector), 0);
    }

    function _slice4(bytes memory b, uint256 offset) internal pure returns (bytes4 out) {
        for (uint256 i = 0; i < 4; ++i) {
            out |= bytes4(b[offset + i]) >> (8 * i);
        }
    }

    // ------------------------------------------------------------------------------------------------
    // construction
    // ------------------------------------------------------------------------------------------------

    function test_constructor_setsImmutables() public view {
        assertEq(address(ps.ROLLUP_MANAGER()), address(manager));
        assertEq(address(ps.ZISK_VERIFIER()), address(verifier));
        assertEq(ps.ROOT_C_VADCOP_FINAL(), ROOT_C);
        assertEq(ps.SCHEMA_VERSION(), SCHEMA);
        assertEq(ps.ROLLUP_ID(), ROLLUP_ID);
    }

    function test_RevertWhen_constructorZeroManager() public {
        vm.expectRevert(ZiskProofSystem.ZeroAddress.selector);
        new ZiskProofSystem(address(0), address(verifier), ROOT_C, SCHEMA, ROLLUP_ID);
    }

    function test_RevertWhen_constructorZeroVerifier() public {
        vm.expectRevert(ZiskProofSystem.ZeroAddress.selector);
        new ZiskProofSystem(address(manager), address(0), ROOT_C, SCHEMA, ROLLUP_ID);
    }

    // ------------------------------------------------------------------------------------------------
    // verify: accept
    // ------------------------------------------------------------------------------------------------

    function test_verify_acceptsWellFormedProof() public {
        bytes memory publicValues = _wellFormed();
        _expectVerifierCall(VKEY, publicValues, 1);
        assertTrue(ps.verify(_blob(VKEY, publicValues), HASH));
    }

    function test_verify_gasOverheadWithMockVerifier() public view {
        bytes memory blob = _blob(VKEY, _wellFormed());
        uint256 gasBefore = gasleft();
        bool ok = ps.verify(blob, HASH);
        uint256 gasUsed = gasBefore - gasleft();
        assertTrue(ok);
        console2.log(
            "ZiskProofSystem.verify gas with mock verifier (adapter overhead incl. 2 external calls):", gasUsed
        );
    }

    // ------------------------------------------------------------------------------------------------
    // verify: reject (returns false, never reverts) - and the verifier is not even consulted
    // ------------------------------------------------------------------------------------------------

    function test_verify_rejectsWrongPublicInputsHash() public {
        _expectNoVerifierCall();
        assertFalse(ps.verify(_blob(VKEY, _wellFormed()), keccak256("some other hash")));
    }

    function test_verify_rejectsCommittedHashMismatch() public {
        _expectNoVerifierCall();
        bytes memory publicValues = _publicValues(SCHEMA, keccak256("other"), VKEY, ROLLUP_ID);
        assertFalse(ps.verify(_blob(VKEY, publicValues), HASH));
    }

    function test_verify_rejectsWrongSchema() public {
        _expectNoVerifierCall();
        bytes memory publicValues = _publicValues(SCHEMA + 1, HASH, VKEY, ROLLUP_ID);
        assertFalse(ps.verify(_blob(VKEY, publicValues), HASH));
    }

    function test_verify_rejectsWrongRollupId() public {
        _expectNoVerifierCall();
        bytes memory publicValues = _publicValues(SCHEMA, HASH, VKEY, ROLLUP_ID + 1);
        assertFalse(ps.verify(_blob(VKEY, publicValues), HASH));
    }

    function test_verify_rejectsCommittedVkeyNotEqualToProgramVK() public {
        _expectNoVerifierCall();
        bytes32 other = keccak256("other vkey");
        // guest committed `other`, blob claims VKEY (which is the registered one)
        assertFalse(ps.verify(_blob(VKEY, _publicValues(SCHEMA, HASH, other, ROLLUP_ID)), HASH));
        // guest committed VKEY, blob claims `other`
        assertFalse(ps.verify(_blob(other, _wellFormed()), HASH));
    }

    function test_verify_rejectsVkeyNotRegisteredForThisAdapter() public {
        _expectNoVerifierCall();
        bytes32 other = keccak256("other vkey");
        // consistent statement for `other`, but the rollup registered VKEY for this adapter
        assertFalse(ps.verify(_blob(other, _publicValues(SCHEMA, HASH, other, ROLLUP_ID)), HASH));
    }

    function test_verify_rejectsWhenAdapterNotRegistered() public {
        manager.setVerificationKey(address(ps), bytes32(0));
        _expectNoVerifierCall();
        assertFalse(ps.verify(_blob(VKEY, _wellFormed()), HASH));
        // a zero vkey cannot be sneaked through the equality chain either
        assertFalse(ps.verify(_blob(bytes32(0), _publicValues(SCHEMA, HASH, bytes32(0), ROLLUP_ID)), HASH));
    }

    function test_verify_rejectsWrongPublicValuesLength() public {
        _expectNoVerifierCall();
        bytes memory good = _wellFormed();
        bytes memory shorter = new bytes(good.length - 1);
        bytes memory longer = new bytes(good.length + 1);
        for (uint256 i = 0; i < good.length; ++i) {
            if (i < shorter.length) shorter[i] = good[i];
            longer[i] = good[i];
        }
        assertFalse(ps.verify(_blob(VKEY, shorter), HASH));
        assertFalse(ps.verify(_blob(VKEY, longer), HASH));
        assertFalse(ps.verify(_blob(VKEY, ""), HASH));
    }

    function test_verify_returnsFalseWhenVerifierRejects() public {
        verifier.setRejectAll(true);
        bytes memory publicValues = _wellFormed();
        _expectVerifierCall(VKEY, publicValues, 1);
        assertFalse(ps.verify(_blob(VKEY, publicValues), HASH));
    }

    /// @notice A blob that is not `abi.encode(bytes32, bytes, bytes)` reverts in `abi.decode` (documented).
    function test_RevertWhen_proofBlobIsNotAbiEncoded() public {
        vm.expectRevert();
        ps.verify(hex"deadbeef", HASH);
    }

    function testFuzz_verify_rejectsAnyOtherHash(bytes32 other) public view {
        vm.assume(other != HASH);
        assertFalse(ps.verify(_blob(VKEY, _wellFormed()), other));
    }

    function testFuzz_verify_rejectsAnyOtherSchema(uint32 schema) public view {
        vm.assume(schema != SCHEMA);
        assertFalse(ps.verify(_blob(VKEY, _publicValues(schema, HASH, VKEY, ROLLUP_ID)), HASH));
    }

    function testFuzz_verify_rejectsAnyOtherRollupId(uint64 rollupId) public view {
        vm.assume(rollupId != ROLLUP_ID);
        assertFalse(ps.verify(_blob(VKEY, _publicValues(SCHEMA, HASH, VKEY, rollupId)), HASH));
    }

    // ------------------------------------------------------------------------------------------------
    // public-values layout
    // ------------------------------------------------------------------------------------------------

    function test_encodePublicValues_layout() public view {
        bytes memory pv = ps.encodePublicValues(SCHEMA, HASH, VKEY, ROLLUP_ID);
        assertEq(pv.length, 512);
        assertEq(_slice4(pv, 0), bytes4(SCHEMA), "slot 0 = schema");
        // (narrowing casts below deliberately select one 4-byte word)
        for (uint256 j = 0; j < 8; ++j) {
            // forge-lint: disable-next-line(unsafe-typecast)
            assertEq(_slice4(pv, (1 + j) * 8), bytes4(HASH << (32 * j)), "slots 1..8 = hash words");
            // forge-lint: disable-next-line(unsafe-typecast)
            assertEq(_slice4(pv, (9 + j) * 8), bytes4(VKEY << (32 * j)), "slots 9..16 = vkey words");
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(_slice4(pv, 17 * 8), bytes4(uint32(ROLLUP_ID >> 32)), "slot 17 = rollup id high");
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(_slice4(pv, 18 * 8), bytes4(uint32(ROLLUP_ID)), "slot 18 = rollup id low");
        // padding bytes of every slot and all reserved slots are zero
        for (uint256 slot = 0; slot < 64; ++slot) {
            assertEq(_slice4(pv, slot * 8 + 4), bytes4(0), "slot padding");
            if (slot > 18) assertEq(_slice4(pv, slot * 8), bytes4(0), "reserved slot");
        }
    }

    function testFuzz_encodeDecode_roundTrip(uint32 schema, bytes32 hash, bytes32 vkey, uint64 rollupId) public view {
        (uint32 s, bytes32 h, bytes32 v, uint64 r) =
            ps.decodePublicValues(ps.encodePublicValues(schema, hash, vkey, rollupId));
        assertEq(s, schema);
        assertEq(h, hash);
        assertEq(v, vkey);
        assertEq(r, rollupId);
    }

    function test_decodePublicValues_RevertWhen_wrongLength() public {
        vm.expectRevert(abi.encodeWithSelector(ZiskPublicValues.InvalidPublicValuesLength.selector, 511, 512));
        ps.decodePublicValues(new bytes(511));
    }

    // ------------------------------------------------------------------------------------------------
    // MockZiskVerifier (the test double the e2e fixtures deploy)
    // ------------------------------------------------------------------------------------------------

    function test_mockVerifier_onlyOwnerFlipsRejectAll() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(MockZiskVerifier.NotOwner.selector, stranger, address(this)));
        verifier.setRejectAll(true);
        assertFalse(verifier.rejectAll());

        verifier.setRejectAll(true);
        vm.expectRevert(MockZiskVerifier.InvalidProof.selector);
        verifier.verifySnarkProof(VKEY, ROOT_C, _wellFormed(), proofBytes);

        verifier.setRejectAll(false);
        verifier.verifySnarkProof(VKEY, ROOT_C, _wellFormed(), proofBytes);
    }
}

/// @title ZiskProofSystemRollupTest
/// @notice The adapter against the pinned core `Rollup` manager (behind its proxy, as `DeployRollup` deploys it)
///         instead of the mock: the `verificationKey(address)` getter the adapter calls is the real one, and the
///         key the adapter checks is the key `checkProofSystemsAndGetVkeys` hands to `EEZ`.
contract ZiskProofSystemRollupTest is Test {
    uint32 internal constant SCHEMA = 1;
    uint64 internal constant ROLLUP_ID = 7;
    bytes32 internal constant ROOT_C = keccak256("rootCVadcopFinal");
    bytes32 internal constant VKEY = keccak256("program vkey");
    bytes32 internal constant HASH = keccak256("publicInputsHash");

    MockZiskVerifier internal verifier;
    Rollup internal rollup;
    ZiskProofSystem internal ps;
    bytes internal blob;

    function setUp() public {
        verifier = new MockZiskVerifier();
        // No proof systems at initialization: the adapter needs the manager's address first.
        rollup = RollupDeployment.deploy(makeAddr("eez"), address(this), 1, new address[](0), new bytes32[](0));
        ps = new ZiskProofSystem(address(rollup), address(verifier), ROOT_C, SCHEMA, ROLLUP_ID);
        rollup.addProofSystem(address(ps), VKEY);
        blob = abi.encode(VKEY, ZiskPublicValues.encode(SCHEMA, HASH, VKEY, ROLLUP_ID), new bytes(6752));
    }

    function test_rollupGetterMatchesAdapterInterface() public view {
        assertEq(IRollupVerificationKeys.verificationKey.selector, rollup.verificationKey.selector);
        assertEq(IRollupVerificationKeys(address(rollup)).verificationKey(address(ps)), VKEY);

        address[] memory systems = new address[](1);
        systems[0] = address(ps);
        bytes32[] memory vkeys = rollup.checkProofSystemsAndGetVkeys(systems);
        assertEq(vkeys.length, 1);
        assertEq(vkeys[0], VKEY, "EEZ binds the same key the adapter checks");
    }

    function test_verify_followsRegisteredKey() public {
        assertTrue(ps.verify(blob, HASH));

        rollup.updateVerificationKey(address(ps), keccak256("rotated vkey"));
        assertFalse(ps.verify(blob, HASH), "rotated key");

        rollup.removeProofSystem(address(ps));
        assertFalse(ps.verify(blob, HASH), "removed");
    }
}

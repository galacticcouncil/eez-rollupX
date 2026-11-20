// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IProofSystem} from "eez-core-protocol/src/interfaces/IProofSystem.sol";
import {IZiskVerifier} from "./IZiskVerifier.sol";

/// @title IRollupVerificationKeys
/// @notice The single function of the per-rollup manager (`eez-core-protocol` `Rollup.sol`) this adapter
///         relies on: the auto-generated getter of `mapping(address proofSystem => bytes32 vkey) public
///         verificationKey`. It is not part of `IRollupContract`, hence this one-function interface.
interface IRollupVerificationKeys {
    function verificationKey(address proofSystem) external view returns (bytes32 vkey);
}

/// @title ZiskPublicValues
/// @notice Encoder/decoder for the EEZ layout of a ZisK program's public values (schema version 1).
///
/// @dev ZisK background. A guest program publishes up to 64 `u32` output slots with `ziskos::io::commit(value)` /
///      `ziskos::io::commit_slice(bytes)`, which append to one byte stream, 4 bytes per slot. The wrapped
///      pilfflonk proof commits to them as 64 Goldilocks field elements, and ZisK's
///      `ZiskVerifier.verifySnarkProof` receives them as `bytes publicValues` of exactly 64 * 8 = 512 bytes:
///      slot `i` occupies bytes `[8i, 8i + 8)`; its first four bytes are output `i` as a big-endian `u32`
///      and the remaining four bytes are zero (see README, "Public values layout"). Every byte of the 512
///      is bound by the proof (it is sha256-hashed into the single pilfflonk public signal), so the adapter
///      only needs to *interpret* the slots it cares about; it never has to police the rest.
///
///      EEZ layout (schema 1), by slot:
///        slot  0        : schema version (u32)
///        slots 1 .. 8   : publicInputsHash, 8 big-endian u32 words, most significant word first
///        slots 9 .. 16  : vkey used by the guest == programVK of the proof, same 8-word encoding
///        slots 17 .. 18 : rollup id (u64), high word then low word
///        slots 19 .. 63 : reserved for future schema versions (ignored by schema 1)
library ZiskPublicValues {
    /// @notice Number of `u32` output slots a ZisK guest can publish (`ziskos`: `id < 64`).
    uint256 internal constant SLOTS = 64;
    /// @notice Byte length of the on-chain `publicValues` string: one 8-byte slot per output.
    uint256 internal constant LENGTH = SLOTS * 8;

    uint256 internal constant SLOT_SCHEMA = 0;
    uint256 internal constant SLOT_PUBLIC_INPUTS_HASH = 1; // 8 slots
    uint256 internal constant SLOT_VKEY = 9; // 8 slots
    uint256 internal constant SLOT_ROLLUP_ID = 17; // 2 slots

    error InvalidPublicValuesLength(uint256 actual, uint256 expected);

    /// @notice Splits a 512-byte ZisK public-values string into the schema-1 fields.
    function decode(bytes memory publicValues)
        internal
        pure
        returns (uint32 schema, bytes32 publicInputsHash, bytes32 vkey, uint64 rollupId)
    {
        if (publicValues.length != LENGTH) revert InvalidPublicValuesLength(publicValues.length, LENGTH);
        schema = uint32(word(publicValues, SLOT_SCHEMA));
        publicInputsHash = word256(publicValues, SLOT_PUBLIC_INPUTS_HASH);
        vkey = word256(publicValues, SLOT_VKEY);
        rollupId = uint64(
            bytes8(
                bytes32(word(publicValues, SLOT_ROLLUP_ID)) | (bytes32(word(publicValues, SLOT_ROLLUP_ID + 1)) >> 32)
            )
        );
    }

    /// @notice Inverse of `decode`: builds the exact 512-byte string a schema-1 guest publishes.
    function encode(
        uint32 schema,
        bytes32 publicInputsHash,
        bytes32 vkey,
        uint64 rollupId
    )
        internal
        pure
        returns (bytes memory publicValues)
    {
        publicValues = new bytes(LENGTH);
        putWord(publicValues, SLOT_SCHEMA, bytes4(schema));
        // `bytes4(x << 32 * j)` deliberately keeps only word j of x (narrowing bytesN keeps the leftmost bytes).
        for (uint256 j = 0; j < 8; ++j) {
            // forge-lint: disable-next-line(unsafe-typecast)
            putWord(publicValues, SLOT_PUBLIC_INPUTS_HASH + j, bytes4(publicInputsHash << (32 * j)));
            // forge-lint: disable-next-line(unsafe-typecast)
            putWord(publicValues, SLOT_VKEY + j, bytes4(vkey << (32 * j)));
        }
        bytes8 rollupIdBytes = bytes8(rollupId); // big-endian
        // forge-lint: disable-next-line(unsafe-typecast)
        putWord(publicValues, SLOT_ROLLUP_ID, bytes4(rollupIdBytes)); // high word
        // forge-lint: disable-next-line(unsafe-typecast)
        putWord(publicValues, SLOT_ROLLUP_ID + 1, bytes4(rollupIdBytes << 32)); // low word
    }

    /// @notice The `u32` output stored in `slot`, as its four bytes in guest-memory order (big-endian for a
    ///         value the guest wrote with `to_be_bytes`, verbatim for a committed byte string).
    function word(bytes memory publicValues, uint256 slot) internal pure returns (bytes4 w) {
        uint256 end = slot * 8 + 4; // one past the last byte of the word
        if (end > publicValues.length) revert InvalidPublicValuesLength(publicValues.length, LENGTH);
        assembly ("memory-safe") {
            // Load the 32 bytes that END at `end` - always inside the allocation (length word + data) -
            // and move the low four bytes to the top: `bytesN` are left-aligned.
            w := shl(224, mload(add(publicValues, end)))
        }
    }

    /// @notice A `bytes32` spread over eight consecutive slots, most significant word first.
    function word256(bytes memory publicValues, uint256 firstSlot) internal pure returns (bytes32 out) {
        for (uint256 j = 0; j < 8; ++j) {
            out |= bytes32(word(publicValues, firstSlot + j)) >> (32 * j);
        }
    }

    function putWord(bytes memory publicValues, uint256 slot, bytes4 w) internal pure {
        uint256 offset = slot * 8;
        publicValues[offset] = w[0];
        publicValues[offset + 1] = w[1];
        publicValues[offset + 2] = w[2];
        publicValues[offset + 3] = w[3];
        // bytes [offset + 4, offset + 8) stay zero: a u32 output never touches them.
    }
}

/// @title ZiskProofSystem
/// @notice EEZ `IProofSystem` adapter for the ZisK zkVM (verifier contracts `v1.4.0-alpha`, blake3 pilfflonk).
///
/// @dev EEZ calls exactly one thing on a proof system: `verify(bytes proof, bytes32 publicInputsHash)`
///      (`EEZ._verifyProofSystemBatch`), and treats `false` as `InvalidProof()`. The adapter therefore
///      never sees the batch; the ZisK *guest* recomputes `publicInputsHash` and commits it as a public
///      value, together with the schema version, the vkey it was given as input and the rollup id
///      (docs/eez-e2e-poc-plan.md section 4.4). This contract checks the committed values against what
///      EEZ and the rollup manager say, then lets `ZiskVerifier` check the pilfflonk proof for `programVK`.
///
///      `proof` encoding: `abi.encode(bytes32 programVK, bytes publicValues, bytes proofBytes)` where
///        - `programVK`    the ZisK program verification key the proof was produced for (32 bytes, the
///                         4 Goldilocks limbs big-endian, as `cargo-zisk-dev export-solidity-calldata` prints it);
///        - `publicValues` the 512-byte ZisK public-values string in the layout of `ZiskPublicValues`;
///        - `proofBytes`   the wrapped pilfflonk proof, `abi.encode(bytes32[211])` (6,752 bytes) for the blake3
///                         hash family we standardise on (ERE's default proving key); a poseidon1/poseidon2
///                         verifier would take `bytes32[69]` (2,208 bytes). The adapter does not check the
///                         length. `ZiskVerifier`'s `abi.decode` needs at least 6,752 bytes (fewer reverts,
///                         so `false`) and ignores any trailing bytes.
///
///      Accepted iff ALL of:
///        1. `publicValues.length == 512`;
///        2. committed schema == `SCHEMA_VERSION`;
///        3. committed publicInputsHash == the `publicInputsHash` argument EEZ computed;
///        4. committed rollup id == `ROLLUP_ID`;
///        5. committed vkey == `programVK` == `ROLLUP_MANAGER.verificationKey(address(this))` (non-zero) -
///           the vkey the guest folded, the key the proof is checked against and the key the rollup
///           registered for this adapter are one and the same value;
///        6. `ZISK_VERIFIER.verifySnarkProof(programVK, ROOT_C_VADCOP_FINAL, publicValues, proofBytes)`
///           does not revert.
///      Any failed check returns `false` (never reverts), except a `proof` blob that is not valid ABI,
///      which reverts in `abi.decode` - EEZ rejects the batch either way.
///
///      Why `rootCVadcopFinal` is an immutable and not part of `proof`: `ZiskVerifier` takes it per call
///      and binds it only through the hashed preimage; it names the recursion circuit (vadcop_final for a
///      plain proof, the recurser's own key for an aggregated one) whose STARK proof the pilfflonk circuit
///      verified. Letting the prover choose it would let a prover substitute a different circuit.
contract ZiskProofSystem is IProofSystem {
    /// @notice Per-rollup manager (`Rollup.sol`) that registered this adapter with `addProofSystem`.
    IRollupVerificationKeys public immutable ROLLUP_MANAGER;
    /// @notice ZisK's `ZiskVerifier` (which is also the `PilfflonkVerifier`) for this ZisK release.
    IZiskVerifier public immutable ZISK_VERIFIER;
    /// @notice Verkey of the recursion circuit whose proofs are accepted; `ZiskVerifier.getRootCVadcopFinal()`
    ///         for plain (non-aggregated) proofs of ZisK v1.4.0-alpha.
    bytes32 public immutable ROOT_C_VADCOP_FINAL;
    /// @notice Public-values schema version the guest must commit (slot 0).
    uint32 public immutable SCHEMA_VERSION;
    /// @notice Rollup id the guest must commit (slots 17-18); `Rollup.rollupId()` once registered with EEZ.
    uint64 public immutable ROLLUP_ID;

    error ZeroAddress();

    constructor(
        address rollupManager,
        address ziskVerifier,
        bytes32 rootCVadcopFinal,
        uint32 schemaVersion,
        uint64 rollupId
    ) {
        if (rollupManager == address(0) || ziskVerifier == address(0)) revert ZeroAddress();
        ROLLUP_MANAGER = IRollupVerificationKeys(rollupManager);
        ZISK_VERIFIER = IZiskVerifier(ziskVerifier);
        ROOT_C_VADCOP_FINAL = rootCVadcopFinal;
        SCHEMA_VERSION = schemaVersion;
        ROLLUP_ID = rollupId;
    }

    /// @inheritdoc IProofSystem
    function verify(bytes calldata proof, bytes32 publicInputsHash) external view returns (bool valid) {
        (bytes32 programVK, bytes memory publicValues, bytes memory proofBytes) =
            abi.decode(proof, (bytes32, bytes, bytes));

        // 1. Exactly what ZisK emits; anything else cannot be a schema-1 statement.
        if (publicValues.length != ZiskPublicValues.LENGTH) return false;

        (uint32 schema, bytes32 committedHash, bytes32 committedVkey, uint64 committedRollupId) =
            ZiskPublicValues.decode(publicValues);

        // 2-4. The guest's statement is about this schema, this batch and this rollup.
        if (schema != SCHEMA_VERSION) return false;
        if (committedHash != publicInputsHash) return false;
        if (committedRollupId != ROLLUP_ID) return false;

        // 5. Break the vkey circularity: registered key == key folded by the guest == key verified against.
        if (committedVkey != programVK) return false;
        bytes32 registeredVkey = ROLLUP_MANAGER.verificationKey(address(this));
        if (registeredVkey == bytes32(0) || registeredVkey != programVK) return false;

        // 6. The pilfflonk proof itself. ZiskVerifier reverts with InvalidProof() instead of returning false.
        try ZISK_VERIFIER.verifySnarkProof(programVK, ROOT_C_VADCOP_FINAL, publicValues, proofBytes) {
            return true;
        } catch {
            return false;
        }
    }

    /// @notice Schema-1 view of a ZisK public-values string (tooling / tests). Reverts on a wrong length.
    function decodePublicValues(bytes memory publicValues)
        external
        pure
        returns (uint32 schema, bytes32 publicInputsHash, bytes32 vkey, uint64 rollupId)
    {
        return ZiskPublicValues.decode(publicValues);
    }

    /// @notice The exact 512-byte string a schema-1 guest must publish for these fields (tooling / tests).
    function encodePublicValues(
        uint32 schema,
        bytes32 publicInputsHash,
        bytes32 vkey,
        uint64 rollupId
    )
        external
        pure
        returns (bytes memory publicValues)
    {
        return ZiskPublicValues.encode(schema, publicInputsHash, vkey, rollupId);
    }
}

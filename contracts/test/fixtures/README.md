`l1-storage-eip1186.json` was captured from an isolated Foundry Anvil 1.7.1,
chain 1337, Osaka active, genesis timestamp 1700000000. Anvil's first public
development account sent the recorded `initCode` as a CREATE transaction at
timestamp 1700000001, gas limit 0x300000. Its constructor stores 64 values:
slot 7 holds 45, every other slot `i` in 0..63 holds `i + 100`; runtime is STOP.

The file contains the actual `eth_getProof` results at the mined block for that
contract's slots 7 and 999 and for the absent address 0xdead. `cast block --raw`
provided the canonical header; the recorded block hash independently checks it.
The tests use these bytes directly, without building their expected trie with
the verifier implementation. The header/proofs authenticate values and absence;
the fixtures do not test L1 consensus or the history import mechanism.

`zisk/golden_pv_schema1_h11_vk22_rid7.hex` is the 512-byte schema-1 ZisK
public-values string for schema 1, `publicInputsHash` 0x11…11, vkey 0x22…22 and
rollup id 7, as `0x`-prefixed hex with a trailing newline. It is a byte-identical
copy of hydration-zisk's `contracts/eez/test/fixtures/golden_pv_schema1_h11_vk22_rid7.hex`
(check with `cmp`). `test/zisk/GoldenVector.t.sol` asserts that
`ZiskPublicValues.encode` produces exactly these bytes. Any Rust encoder of the
same layout must match them too, so change the file, the Solidity encoder and the
Rust encoder together.

// The local beacon stub serves exactly the captured blobs of a canonical slot.
// Run: node --test scripts/local-network/beacon-stub.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { Beacon, capturedBlobs } from "./beacon-stub.mjs";

// The KZG commitment of an all-zero blob is the point at infinity; its
// versioned hash is a well-known constant, independent of this decoder.
const ZERO_COMMITMENT = Buffer.concat([Buffer.from([0xc0]), Buffer.alloc(47)]);
const ZERO_BLOB_HASH = "0x010657f37554c781402a22917dee2f75def7ab966d7b770905398eba3c444014";
const BLOB = Buffer.alloc(131072);
const OTHER_BLOB = Buffer.concat([Buffer.from([0x01]), Buffer.alloc(131071)]);
const OTHER_COMMITMENT = Buffer.concat([Buffer.from([0xc1]), Buffer.alloc(47)]);
const TX_BODY = [Buffer.from([0x05, 0x39]), Buffer.from([0x01]), Buffer.alloc(0), Buffer.alloc(0)];
const proofs = (count) => Array.from({ length: count }, () => Buffer.alloc(48));

// Independent RLP encoder, so the tests do not trust the decoder under test.
function rlp(item) {
  const prefix = (length, offset) => {
    if (length < 56) return Buffer.from([offset + length]);
    const size = []; // the length as big-endian bytes
    for (let rest = length; rest > 0; rest = Math.floor(rest / 256)) size.unshift(rest % 256);
    return Buffer.from([offset + 55 + size.length, ...size]);
  };
  if (Buffer.isBuffer(item)) {
    if (item.length === 1 && item[0] < 0x80) return item;
    return Buffer.concat([prefix(item.length, 0x80), item]);
  }
  const payload = Buffer.concat(item.map(rlp));
  return Buffer.concat([prefix(payload.length, 0xc0), payload]);
}

const pooled = (...fields) => "0x03" + rlp(fields).toString("hex");

test("osaka wrapper with cell proofs", () => {
  const raw = pooled(TX_BODY, Buffer.from([0x01]), [BLOB], [ZERO_COMMITMENT], proofs(128));
  assert.deepEqual(capturedBlobs(raw), { [ZERO_BLOB_HASH]: "0x" + BLOB.toString("hex") });
});

test("eip-4844 wrapper", () => {
  const raw = pooled(TX_BODY, [BLOB], [ZERO_COMMITMENT], proofs(1));
  assert.deepEqual(capturedBlobs(raw), { [ZERO_BLOB_HASH]: "0x" + BLOB.toString("hex") });
});

test("rejects a non-blob transaction", () => {
  assert.throws(() => capturedBlobs("0x02" + rlp(TX_BODY).toString("hex")), /not a blob transaction/);
});

// Blocks every 5 s from genesis 1000; block 2 carries the blobs named by `included`.
class FakeChainBeacon extends Beacon {
  constructor(captureDir, included) {
    super("http://unused", captureDir);
    this.blocks = [
      { timestamp: "0x3e8", transactions: [] },
      { timestamp: "0x3ed", transactions: [{ type: "0x2" }] },
      { timestamp: "0x3f2", transactions: [{ type: "0x3", blobVersionedHashes: included }] },
    ];
  }

  async rpc(method, ...params) {
    if (method === "eth_blockNumber") return "0x" + (this.blocks.length - 1).toString(16);
    return this.blocks[Number(params[0])];
  }
}

// A capture directory with two landed-or-not blob files and one partial write.
async function captureDir(t) {
  const directory = await mkdtemp(path.join(tmpdir(), "eez-local-beacon."));
  t.after(() => rm(directory, { recursive: true, force: true }));
  for (const [name, blob, commitment] of [["blob-a.json", BLOB, ZERO_COMMITMENT],
                                          ["blob-b.json", OTHER_BLOB, OTHER_COMMITMENT]]) {
    const raw = pooled(TX_BODY, Buffer.from([0x01]), [blob], [commitment], proofs(128));
    await writeFile(path.join(directory, name), JSON.stringify({ raw }));
  }
  await writeFile(path.join(directory, "blob-c.tmp"), "partial write");
  return directory;
}

test("serves only blobs named by the canonical block", async (t) => {
  const beacon = new FakeChainBeacon(await captureDir(t), [ZERO_BLOB_HASH]);
  assert.equal(await beacon.genesis(), 1000);
  assert.deepEqual(await beacon.blobsForSlot(10), ["0x" + BLOB.toString("hex")]);
});

test("slot without blobs or without a block is empty", async (t) => {
  const beacon = new FakeChainBeacon(await captureDir(t), [ZERO_BLOB_HASH]);
  assert.deepEqual(await beacon.blobsForSlot(5), []);
  assert.deepEqual(await beacon.blobsForSlot(7), []);
});

test("blob that never landed is not served", async (t) => {
  const beacon = new FakeChainBeacon(await captureDir(t), ["0x01" + "ab".repeat(31)]);
  assert.deepEqual(await beacon.blobsForSlot(10), []);
});

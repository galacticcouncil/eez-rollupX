#!/usr/bin/env node
// Minimal Beacon API for the local network's built-in L1. Not for production.
// Node standard library only; run with Node 22 or newer.
//
// The Composer's development L1 has no consensus client, so nothing serves the
// blob data that settlement and derivation read back. builder-stub.py, run with
// --capture-dir, saves every blob transaction it forwards. This server answers
// the three Beacon calls the node makes (crates/eez-l1/src/blob_source.rs):
//
//   /eth/v1/beacon/genesis       genesis_time: the L1 block zero timestamp
//   /eth/v1/config/spec          SECONDS_PER_SLOT: 1
//   /eth/v1/beacon/blobs/{slot}  blobs of the canonical L1 block whose timestamp
//                                is genesis_time + slot
//
// A captured blob is served only when its versioned hash is in that canonical
// block, so a bundle that never landed is never exposed. Same model as the Rust
// BeaconStub in crates/eez-testkit; the legacy blob_sidecars endpoint is absent
// because the node only falls back to it when /blobs is missing.
import { createHash } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import { createServer } from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

const SECONDS_PER_SLOT = 1;
const BLOBS_PATH = /^\/eth\/v1\/beacon\/blobs\/(\d+)$/;

// Decode the RLP item at `position`. Returns [item, next position]; an item is
// a Buffer or an array of items.
export function rlpDecode(data, position = 0) {
  const prefix = data[position];
  if (prefix < 0x80) return [data.subarray(position, position + 1), position + 1];
  if (prefix < 0xb8) return bytesItem(data, position + 1, prefix - 0x80);
  if (prefix < 0xc0) return bytesItem(data, ...longPayload(data, position, prefix - 0xb7));
  const [start, length] = prefix < 0xf8
    ? [position + 1, prefix - 0xc0]
    : longPayload(data, position, prefix - 0xf7);
  const end = checkedEnd(data, start, length);
  const items = [];
  for (let next = start; next < end;) {
    const [item, after] = rlpDecode(data, next);
    items.push(item);
    next = after;
  }
  return [items, end];
}

// Long strings and lists put their length in the next `sizeLength` bytes.
// Returns [payload start, payload length].
function longPayload(data, position, sizeLength) {
  checkedEnd(data, position + 1, sizeLength);
  return [position + 1 + sizeLength, data.readUIntBE(position + 1, sizeLength)];
}

function bytesItem(data, start, length) {
  const end = checkedEnd(data, start, length);
  return [data.subarray(start, end), end];
}

function checkedEnd(data, start, length) {
  if (start + length > data.length) throw new Error("RLP item runs past the end");
  return start + length;
}

// EIP-4844: version byte 0x01, then the last 31 bytes of sha256(commitment).
export function versionedHash(commitment) {
  return "0x01" + createHash("sha256").update(commitment).digest("hex").slice(2);
}

// Map versioned hash to blob for one pooled (network-form) blob transaction.
// EIP-4844 wraps [tx, blobs, commitments, proofs]; EIP-7594 (Osaka) wraps
// [tx, version, blobs, commitments, cell_proofs]. Both end the same way.
export function capturedBlobs(rawHex) {
  const raw = Buffer.from(rawHex.replace(/^0x/, ""), "hex");
  if (raw[0] !== 0x03) throw new Error("not a blob transaction");
  const [fields] = rlpDecode(raw, 1);
  const blobs = fields.at(-3);
  const commitments = fields.at(-2);
  if (blobs.length !== commitments.length) throw new Error("blob and commitment counts differ");
  return Object.fromEntries(
    commitments.map((commitment, i) => [versionedHash(commitment), "0x" + blobs[i].toString("hex")]),
  );
}

export class Beacon {
  constructor(l1Rpc, captureDir) {
    this.l1Rpc = l1Rpc;
    this.captureDir = captureDir;
    this.genesisTime = null;
    // Capture files never change, so remember only where each blob is;
    // the blobs themselves (128 KiB each) stay on disk.
    this.blobFiles = new Map(); // versioned hash -> capture file name
    this.indexed = new Set(); // capture files already read once
  }

  async rpc(method, ...params) {
    const response = await fetch(this.l1Rpc, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
      signal: AbortSignal.timeout(10_000),
    });
    const reply = await response.json();
    if (reply.error) throw new Error(`${method}: ${JSON.stringify(reply.error)}`);
    return reply.result;
  }

  block(number, full = false) {
    return this.rpc("eth_getBlockByNumber", "0x" + number.toString(16), full);
  }

  async genesis() {
    if (this.genesisTime === null) this.genesisTime = Number((await this.block(0)).timestamp);
    return this.genesisTime;
  }

  // Binary search the canonical chain for the block with this timestamp.
  async blockAt(timestamp) {
    let low = 0;
    let high = Number(await this.rpc("eth_blockNumber"));
    while (low <= high) {
      const middle = Math.floor((low + high) / 2);
      const found = Number((await this.block(middle)).timestamp);
      if (found === timestamp) return this.block(middle, true);
      if (found < timestamp) low = middle + 1;
      else high = middle - 1;
    }
    return null;
  }

  async readCapture(name) {
    const capture = JSON.parse(await readFile(path.join(this.captureDir, name), "utf8"));
    return capturedBlobs(capture.raw);
  }

  async indexCaptures() {
    for (const name of await readdir(this.captureDir)) {
      if (!name.endsWith(".json") || this.indexed.has(name)) continue;
      for (const blobHash of Object.keys(await this.readCapture(name))) {
        this.blobFiles.set(blobHash, name);
      }
      this.indexed.add(name);
    }
  }

  async blobsForSlot(slot) {
    const block = await this.blockAt((await this.genesis()) + slot * SECONDS_PER_SLOT);
    if (block === null) return [];
    const wanted = block.transactions.flatMap((tx) => tx.blobVersionedHashes ?? []);
    await this.indexCaptures();
    const blobs = [];
    for (const blobHash of wanted) {
      const name = this.blobFiles.get(blobHash);
      if (name) blobs.push((await this.readCapture(name))[blobHash]);
    }
    return blobs;
  }
}

// Returns [HTTP status, JSON body] for one GET path.
async function answer(beacon, url) {
  if (url === "/eth/v1/beacon/genesis") {
    return [200, { data: { genesis_time: String(await beacon.genesis()) } }];
  }
  if (url === "/eth/v1/config/spec") {
    return [200, { data: { SECONDS_PER_SLOT: String(SECONDS_PER_SLOT) } }];
  }
  const match = BLOBS_PATH.exec(url);
  if (match) return [200, { data: await beacon.blobsForSlot(Number(match[1])) }];
  return [404, { code: 404, message: "not found" }];
}

function serve(beacon, host, port) {
  createServer(async (request, response) => {
    let status, body;
    try {
      [status, body] = await answer(beacon, request.url);
    } catch (error) { // report, keep serving
      [status, body] = [500, { code: 500, message: String(error.message ?? error) }];
    }
    const payload = JSON.stringify(body);
    response.writeHead(status, {
      "Content-Type": "application/json",
      "Content-Length": Buffer.byteLength(payload),
    });
    response.end(payload);
  }).listen(port, host);
}

function main() {
  const { values } = parseArgs({
    options: {
      listen: { type: "string" },
      "l1-rpc": { type: "string" },
      "capture-dir": { type: "string" },
    },
  });
  for (const name of ["listen", "l1-rpc", "capture-dir"]) {
    if (!values[name]) throw new Error(`beacon-stub: --${name} is required`);
  }
  const separator = values.listen.lastIndexOf(":");
  const host = values.listen.slice(0, separator);
  const port = Number(values.listen.slice(separator + 1));
  serve(new Beacon(values["l1-rpc"], values["capture-dir"]), host, port);
}

// Run the server only when started directly, not when the tests import this file.
if (process.argv[1] === fileURLToPath(import.meta.url)) main();

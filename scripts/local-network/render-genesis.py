#!/usr/bin/env python3
"""Render the local network's L1 and L2 genesis files from the e2e fixture.

The Composer embeds the local L1, so the L2 genesis has to name an L1 block
zero that does not exist yet. `eez-genesis-block-hash --l1-reference` computes
that block offline with the node's own chain-spec loader, and the node checks
it again against the live L1 at startup. Mirrors the Rust process-test fixture
(`CrossChainConfig::new` and `add_hydration_section` in crates/eez-testkit).
"""
import argparse
import copy
import json
import subprocess
import time

COUNTER_ADDRESS = "0x0000000000000000000000000000000000000800"


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--l1-chain-id", type=int, required=True)
    parser.add_argument("--l2-chain-id", type=int, required=True)
    parser.add_argument("--l1-block-ms", type=int, required=True)
    parser.add_argument("--l2-block-ms", type=int, required=True)
    parser.add_argument("--oracle-updater", required=True)
    parser.add_argument("--pepl-keeper", required=True)
    args = parser.parse_args()
    if args.l2_block_ms % 1000 or args.l1_block_ms % args.l2_block_ms:
        raise SystemExit("render-genesis: block times must be whole seconds, L1 a multiple of L2")
    if args.l1_block_ms // args.l2_block_ms < 2:
        raise SystemExit("render-genesis: an L1 block must span at least two L2 blocks")
    return args


def write(path, document):
    with open(path, "w") as output:
        json.dump(document, output, indent=2)
        output.write("\n")


def l1_reference(l1_path):
    output = subprocess.run(
        ["eez-genesis-block-hash", "--l1-reference", l1_path],
        check=True, capture_output=True, text=True,
    ).stdout
    return json.loads(output)


def render_l1(fixture, chain_id):
    """The funded fixture as a plain Ethereum chain, starting now."""
    l1 = copy.deepcopy(fixture)
    l1["config"]["chainId"] = chain_id
    del l1["config"]["rollupX"]
    l1["timestamp"] = hex(int(time.time()))
    return l1


def render_l2(fixture, reference, args):
    """The fixture with Hydration's rules, bound to L1 block zero."""
    l2 = copy.deepcopy(fixture)
    l2["config"]["chainId"] = args.l2_chain_id
    if "hydration" in l2["config"] or COUNTER_ADDRESS in l2["alloc"]:
        raise SystemExit("render-genesis: fixture already carries Hydration settings")
    l2["config"]["hydration"] = {
        "rulesVersion": 1,
        "oracleUpdater": args.oracle_updater,
        "peplKeeper": args.pepl_keeper,
    }
    # Nonce 1 keeps the counter account from being deleted as empty (EIP-161).
    l2["alloc"][COUNTER_ADDRESS] = {"nonce": "0x1", "balance": "0x0"}

    # L2 starts one Sync interval after L1 block zero (`bind_l2_genesis_reference`).
    step = args.l2_block_ms // 1000
    positions = args.l1_block_ms // args.l2_block_ms
    reference_time = int(reference["timestamp"], 16)
    l2["timestamp"] = hex(reference_time + step * positions)
    l2["mixHash"] = reference["mixHash"]
    l2["config"]["rollupX"] = {
        "blockIntervalSeconds": step,
        "syncIntervalBlocks": positions,
        "historyUpdateOffset": min(2, positions - 1),
        "feeCollector": fixture["config"]["rollupX"]["feeCollector"],
        "l1Reference": {
            "chainId": args.l1_chain_id,
            "number": int(reference["number"], 16),
            "hash": reference["hash"],
            "timestamp": reference_time,
            "prevRandao": reference["mixHash"],
        },
    }
    return l2


def main():
    args = parse_args()
    with open(args.fixture) as source:
        fixture = json.load(source)
    l1_path = f"{args.out_dir}/l1-genesis.json"
    write(l1_path, render_l1(fixture, args.l1_chain_id))
    reference = l1_reference(l1_path)
    write(f"{args.out_dir}/l2-genesis.json", render_l2(fixture, reference, args))
    print(reference["hash"])


if __name__ == "__main__":
    main()

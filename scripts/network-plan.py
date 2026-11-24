#!/usr/bin/env python3
"""Validate public network intent against CI's existing runtime manifest."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys


def require(condition, message):
    if not condition:
        raise ValueError(message)


def load(path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "duplicate JSON field")
            result[key] = value
        return result

    raw = path.read_bytes()
    require(len(raw) <= 1024 * 1024, "manifest exceeds 1 MiB")
    return json.loads(raw, object_pairs_hook=unique), hashlib.sha256(raw).hexdigest()


def plan(network, release, checkout):
    require(isinstance(network, dict), "network must be an object")
    require(set(network) == {"schema", "name", "environment", "l1_chain_id", "l2_chain_id"},
            "network fields must match schema 1; credentials and URLs belong outside this file")
    require(type(network["schema"]) is int and network["schema"] == 1, "unsupported network schema")
    require(isinstance(network["name"], str) and
            re.fullmatch(r"[a-z][a-z0-9-]{0,39}", network["name"]), "invalid network name")
    environment = network["environment"]
    require(environment in ("local", "lark", "chiado"), "unknown environment")
    for key in ("l1_chain_id", "l2_chain_id"):
        require(type(network[key]) is int and 0 < network[key] < 2**64, "invalid " + key)
    require(network["l1_chain_id"] != network["l2_chain_id"], "chain IDs must differ")
    require(network["l1_chain_id"] == 10200 if environment == "chiado"
            else network["l1_chain_id"] not in (1, 100, 10200),
            "L1 must be Chiado for chiado, or a private chain for local/lark")
    require(isinstance(release, dict) and release.get("schema") == 2, "expected CI runtime schema 2")
    for key, length in (("root_commit", 40), ("protocol_commit", 40),
                        ("cargo_lock_sha256", 64), ("binaries_sha256", 64)):
        require(isinstance(release.get(key), str) and
                re.fullmatch(r"[0-9a-f]{%d}" % length, release[key]), "invalid release " + key)
    require(release.get("platform") == "linux/amd64" and release.get("profile") == "release",
            "expected linux/amd64 release artifacts")
    require(type(release.get("published")) is bool, "missing publication status")
    require(isinstance(release.get("images"), dict) and
            set(release["images"]) == {"node", "signer", "deploy"}, "expected node/signer/deploy images")
    for image in release["images"].values():
        require(isinstance(image, dict), "invalid image entry")
        require(re.fullmatch(r"sha256:[0-9a-f]{64}", image.get("image_id", "")), "invalid image ID")
        reference = image.get("reference", "")
        require(isinstance(reference, str) and
                re.fullmatch(r"[a-z0-9][a-z0-9./:_-]*(?:@sha256:[0-9a-f]{64})?", reference),
                "invalid image reference")
        if environment != "local" or release["published"]:
            require(release["published"] and re.search(r"@sha256:[0-9a-f]{64}$", reference),
                    "persistent networks require published digest-pinned images")
    def git(*args):
        return subprocess.check_output(["git", "-C", str(checkout), *args], text=True).strip()
    require(git("rev-parse", "HEAD") == release["root_commit"], "checkout/release revision mismatch")
    pin = git("ls-tree", "HEAD", "eez-core-protocol").split()
    require(len(pin) >= 3 and pin[2] == release["protocol_commit"], "protocol pin mismatch")
    require(hashlib.sha256((checkout / "Cargo.lock").read_bytes()).hexdigest() ==
            release["cargo_lock_sha256"], "Cargo.lock mismatch")
    return {"schema": 1, "network": network, "release": {
        key: release[key] for key in ("root_commit", "protocol_commit", "cargo_lock_sha256",
                                     "binaries_sha256", "platform", "profile", "published", "images")},
        "backend": {"local": "kurtosis", "lark": "swarm", "chiado": "swarm"}[environment],
        "proof_system": "ecdsa", "status": "planned-only",
        "next_step": "qualify artifacts and prepare environment-specific deployment inputs"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("network", type=Path)
    parser.add_argument("release", type=Path, help="CI runtime manifest.json")
    args = parser.parse_args()
    try:
        network, network_hash = load(args.network)
        release, release_hash = load(args.release)
        result = plan(network, release, Path(__file__).resolve().parents[1])
        result["inputs_sha256"] = {"network": network_hash, "release": release_hash}
        print(json.dumps(result, indent=2, sort_keys=True))
    except (ValueError, TypeError, KeyError, OSError, subprocess.CalledProcessError):
        # Never echo arbitrary manifest values: a mistaken input can contain secrets.
        print("network-plan: invalid manifest or checkout mismatch; see the manifest contract", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

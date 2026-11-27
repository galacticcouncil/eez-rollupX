#!/usr/bin/env python3
"""Replace the single-node fixture devnet, retaining images and diagnostic volumes."""
import argparse
import base64
import fcntl
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import stat
import subprocess
import sys
import time

import yaml


LOCAL = Path(__file__).resolve().parents[1]
REPO = LOCAL.parents[2]
STACKS = (
    "eez-devnet", "eez-devnet-414141-prep", "eez-devnet-pbs",
    "eez-devnet-pbs-bootstrap", "eez-devnet-builder", "eez-devnet-boost",
    "eez-devnet-l2", "eez-devnet-l2-deploy", "eez-devnet-explorers",
    "eez-devnet-builder-fund",
)
VOLUMES = tuple(f"eez-devnet-414141-{role}" for role in (
    "genesis", "execution", "beacon", "validators", "postgres", "redis", "pbs",
    "builder", "builder-beacon", "explorer-cache",
)) + tuple(f"eez-devnet-424242-{role}" for role in (
    "deployment", "broadcast", "node", "beacon", "explorer-cache",
)) + ("eez-devnet-explorers-postgres",)
SECRETS = (
    "eez-devnet-engine-jwt", "eez-devnet-relay-password", "eez-devnet-postgres-password",
    "eez-devnet-relay-signing-key", "eez-devnet-explorer-postgres-password",
    "eez-devnet-explorer-l1-password", "eez-devnet-explorer-l2-password",
    "eez-devnet-explorer-l1-web-secret", "eez-devnet-explorer-l2-web-secret",
)
IMAGE_INPUTS = {
    "EEZ_DEVNET_NODE_IMAGE": "eez-devnet-l2_eez-node",
    "EEZ_DEVNET_SIGNER_IMAGE": "eez-devnet-l2_eez-proof-signer",
    "EEZ_DEVNET_DEPLOY_IMAGE": "eez-devnet-l2-deploy_deploy",
    "EEZ_DEVNET_BLOCKSCOUT_IMAGE": "eez-devnet-explorers_l2-blockscout",
    "EEZ_DEVNET_EXPLORER_FRONTEND_IMAGE": "eez-devnet-explorers_l2-web",
}
FILES = (
    ("prepare.yml",), ("l1.yml",), ("relay.yml",), ("pbs-bootstrap.yml",),
    ("builder.yml",), ("boost.yml",), ("builder-fund.yml",),
    ("l2-deploy.yml",), ("l2.yml", "l2-fees.yml"),
    ("explorers.yml",),
)


def run(*args, env=None, input=None, merge_stderr=False):
    result = subprocess.run(args, input=input, text=True, capture_output=True,
                            env=env, timeout=120)
    if result.returncode:
        raise RuntimeError(f"{' '.join(args[:3])} failed: {result.stderr.strip()}")
    return (result.stdout + (result.stderr if merge_stderr else "")).strip()


def docker(*args, **kwargs):
    return run("docker", *args, **kwargs)


def objects(kind):
    ids = docker(kind, "ls", "-q").split()
    return json.loads(docker(kind, "inspect", *ids)) if ids else []


def namespace(obj):
    return obj.get("Spec", {}).get("Labels", {}).get("com.docker.stack.namespace")


def fixture_job(name):
    return name.startswith(("eez-devnet-", "eez-l2-canary-", "eez-restart-"))


def references(spec, network_ids, secret_ids, config_ids=()):
    task = spec["TaskTemplate"]
    container = task["ContainerSpec"]
    return (any(m.get("Type") == "volume" and m.get("Source") in VOLUMES
                for m in container.get("Mounts", []))
            or any(s["SecretID"] in secret_ids for s in container.get("Secrets", []))
            or any(c["ConfigID"] in config_ids for c in container.get("Configs", []))
            or any(n["Target"] in network_ids for n in task.get("Networks", [])))


def preflight():
    swarm = json.loads(docker("info", "--format", "{{json .Swarm}}"))
    nodes = objects("node")
    if (not swarm.get("ControlAvailable") or len(nodes) != 1
            or nodes[0]["ID"] != swarm["NodeID"]
            or nodes[0]["Spec"].get("Labels", {}).get("platform.data") != "true"):
        raise RuntimeError("Reset requires the single-node manager labelled platform.data=true.")
    services = objects("service")
    by_name = {s["Spec"]["Name"]: s for s in services}
    env = os.environ.copy()
    for key, service in IMAGE_INPUTS.items():
        if key in env:
            if not env[key]:
                raise RuntimeError(f"{key} cannot be empty.")
        elif service in by_name:
            env[key] = by_name[service]["Spec"]["TaskTemplate"]["ContainerSpec"]["Image"]
        else:
            raise RuntimeError(f"Set {key}; no installed service supplies it.")
    # Full reset installs the fee-enabled fixture profile and both explorers.
    gateways = [by_name.get(f"eez-devnet-explorers_{chain}-gateway") for chain in ("l1", "l2")]
    private = any(s and s.get("Endpoint", {}).get("Spec", {}).get("Ports") for s in gateways)
    env["EEZ_DEVNET_EXPLORER_ACCESS"] = env.get(
        "EEZ_DEVNET_EXPLORER_ACCESS", "private-host" if private else "overlay")
    if env["EEZ_DEVNET_EXPLORER_ACCESS"] not in ("overlay", "private-host"):
        raise RuntimeError("EEZ_DEVNET_EXPLORER_ACCESS must be overlay or private-host.")
    if env["EEZ_DEVNET_EXPLORER_ACCESS"] == "private-host":
        run("systemctl", "is-active", "--quiet", "eez-explorer-private-ports.service")
    env["EEZ_DEVNET_RELAY_PUBLIC_KEY"] = "0x" + "0" * 96  # Render only; replaced after startup.
    files = list(FILES)
    if env["EEZ_DEVNET_EXPLORER_ACCESS"] == "private-host":
        files[-1] = ("explorers.yml", "explorers-access.yml")
    images = set()
    for group in files:
        args = [arg for name in group for arg in ("-c", str(LOCAL / "stacks" / name))]
        rendered = yaml.safe_load(docker("stack", "config", *args, env=env))
        images.update(s["image"] for s in rendered["services"].values())
    for image in sorted(images):
        docker("image", "inspect", image)  # Fail before deletion; never build/pull during reset.
    networks = [n for n in objects("network")
                if n.get("Labels", {}).get("com.docker.stack.namespace") in STACKS]
    secret_ids = {s["ID"] for s in objects("secret") if s["Spec"]["Name"] in SECRETS}
    configs = [c["ID"] for c in objects("config") if namespace(c) in STACKS]
    network_ids = {n["Id"] for n in networks}
    owned = []
    for service in services:
        spec = service["Spec"]
        attached = references(spec, network_ids, secret_ids, configs)
        if namespace(service) in STACKS or (attached and fixture_job(spec["Name"])):
            owned.append(service)
        elif attached:
            raise RuntimeError(f"Foreign service uses devnet resources: {spec['Name']}")
    owned_ids = {s["ID"] for s in owned}
    container_ids = docker("container", "ls", "-aq").split()
    containers = json.loads(docker("container", "inspect", *container_ids)) if container_ids else []
    attached_containers = []
    for container in containers:
        if not any(m.get("Name") in VOLUMES for m in container.get("Mounts", [])):
            continue
        labels = container["Config"].get("Labels") or {}
        if labels.get("com.docker.swarm.service.id") not in owned_ids:
            raise RuntimeError(f"Foreign or orphan container uses a devnet volume: {container['Id']}")
        attached_containers.append(container["Id"])
    return env, owned, networks, configs, attached_containers


def wait_for(description, predicate, seconds):
    print(description, flush=True)
    deadline = time.monotonic() + seconds
    while not predicate():
        if time.monotonic() >= deadline:
            raise RuntimeError(f"Timed out: {description}. Inspect Swarm tasks/logs; no automatic retry.")
        time.sleep(3)


def wait_job(name, seconds):
    def complete():
        ids = docker("service", "ps", "--no-trunc", "-q", name).split()
        if not ids:
            return False
        tasks = json.loads(docker("inspect", *ids))
        for task in tasks:
            status = task["Status"]
            if status["State"] in ("failed", "rejected", "orphaned"):
                raise RuntimeError(f"Job {name} failed; inspect its tasks/logs before recovery.")
        return any(t["Status"]["State"] == "complete"
                   and t["Status"].get("ContainerStatus", {}).get("ExitCode") == 0 for t in tasks)
    wait_for(f"Waiting for job {name}", complete, seconds)


def deploy(stack, *files, env):
    args = [arg for name in files for arg in ("-c", str(LOCAL / "stacks" / name))]
    docker("stack", "deploy", "--detach=true", "--resolve-image", "never", *args, stack, env=env)


def helper(action, env):
    return run("bash", str(REPO / "scripts/local-devnet.sh"), action, env=env)


def check(action, env, seconds):
    output = helper(action, env)
    print(output, flush=True)
    name = re.search(r"Check task exit: docker service ps (\S+)", output)
    if not name:
        raise RuntimeError("Readiness helper did not return a job name.")
    wait_job(name[1], seconds)


def reset(env, owned, networks, configs, containers, seconds):
    # Scale every selected task to zero, including standalone checks, before deletion.
    names = [s["Spec"]["Name"] for s in owned]
    if names:
        docker("service", "scale", "--detach=true", *(f"{n}=0" for n in names))
        def stopped():
            for name in names:
                states = docker("service", "ps", "--format", "{{.CurrentState}}", name).splitlines()
                if any(s.split()[0] in ("New", "Pending", "Assigned", "Accepted", "Preparing",
                                       "Ready", "Starting", "Running") for s in states):
                    return False
            return True
        wait_for("Waiting for all devnet tasks to stop", stopped, seconds)
        docker("service", "rm", *names)
    # Swarm can leave completed task containers holding volume references.
    existing = set(docker("container", "ls", "-aq", "--no-trunc").split())
    for container in containers:
        if container in existing:
            # No force: a live task prevents deletion. Swarm may concurrently collect it.
            result = subprocess.run(["docker", "container", "rm", container],
                                    capture_output=True, timeout=30)
            if result.returncode and container in docker("container", "ls", "-aq", "--no-trunc").split():
                raise RuntimeError(f"Container still holds devnet state: {container}")
    if configs:
        docker("config", "rm", *configs)
    for network in networks:
        wait_for(f"Removing network {network['Name']}",
                 lambda n=network: remove_network(n["Id"]), seconds)
    existing_volumes = set(docker("volume", "ls", "-q").split())
    for volume in VOLUMES:
        if volume in existing_volumes:
            docker("volume", "rm", volume)
    existing_secrets = {s["Spec"]["Name"] for s in objects("secret")}
    for name in SECRETS:
        if name in existing_secrets:
            docker("secret", "rm", name)
    for name in SECRETS:
        value = "00" + secrets.token_hex(31) if name.endswith("signing-key") else secrets.token_hex(32)
        if name.endswith("web-secret"):
            value = base64.b64encode(secrets.token_bytes(64)).decode()
        docker("secret", "create", name, "-", input=value + "\n")
    for volume in VOLUMES:
        docker("volume", "create", volume)
    helper("prepare", env)
    wait_job("eez-devnet-414141-prep_prepare", seconds)
    helper("start", env)
    check("check", env, seconds)
    deploy("eez-devnet-pbs", "relay.yml", env=env)
    def relay_ready():
        logs = docker("service", "logs", "--raw", "eez-devnet-pbs_relay-api", merge_stderr=True)
        keys = re.findall(r"Using BLS key[^\n]*(0x[0-9a-f]{96})", logs)
        if keys:
            env["EEZ_DEVNET_RELAY_PUBLIC_KEY"] = keys[-1]
        return bool(keys)
    wait_for("Waiting for relay migrations and public BLS identity", relay_ready, seconds)
    deploy("eez-devnet-pbs-bootstrap", "pbs-bootstrap.yml", env=env)
    wait_job("eez-devnet-pbs-bootstrap_bootstrap", seconds)
    deploy("eez-devnet-builder-fund", "builder-fund.yml", env=env)
    wait_job("eez-devnet-builder-fund_fund", seconds)
    deploy("eez-devnet-builder", "builder.yml", env=env)
    deploy("eez-devnet-boost", "boost.yml", env=env)
    check("check-pbs", env, seconds)
    helper("l2-deploy", env)
    wait_job("eez-devnet-l2-deploy_deploy", seconds)
    deploy("eez-devnet-l2", "l2.yml", "l2-fees.yml", env=env)
    helper("explorer-prepare", env)
    helper("explorer-start", env)
    check("check-all", env, seconds)
    print("Fresh devnet ready: L1 414141 / L2 424242, fees enabled, both explorers installed.", flush=True)


def remove_network(identifier):
    current = {n["Id"] for n in objects("network")}
    if identifier not in current:
        return True
    result = subprocess.run(["docker", "network", "rm", identifier], capture_output=True, timeout=30)
    return result.returncode == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--yes", action="store_true", help="delete all current devnet state and recreate it")
    args = parser.parse_args()
    seconds = os.environ.get("EEZ_DEVNET_SETUP_WAIT_SECONDS", "1800")
    if not re.fullmatch(r"[1-9][0-9]{0,3}", seconds):
        parser.error("EEZ_DEVNET_SETUP_WAIT_SECONDS must be 1..9999.")
    # Shared by reset invocations across checkouts; never lock the inode being deleted.
    lock_dir = Path("/tmp/eez-devnet-reset")
    lock_dir.mkdir(mode=0o700, exist_ok=True)
    info = lock_dir.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise RuntimeError("Reset lock directory must be private and owned by the current user.")
    descriptor = os.open(lock_dir / "lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "r+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError("Another devnet reset is already running.") from error
        plan = preflight()
        env, owned, _, _, _ = plan
        print("Reset deletes current L1/L2 chains, validators, relay databases, explorer indexes and devnet secrets.")
        print("Services: " + " ".join(s["Spec"]["Name"] for s in owned))
        print("Volumes: " + " ".join(VOLUMES))
        print("Secrets: " + " ".join(SECRETS))
        print("Images retained; unrelated services, old-network archives, evidence and compiler caches retained.")
        for key in (*IMAGE_INPUTS, "EEZ_DEVNET_EXPLORER_ACCESS"):
            print(f"{key}={shlex.quote(env[key])}")
        if not args.yes:
            print("Plan only. To destroy and recreate this devnet: bash scripts/local-devnet.sh reset --yes")
            return
        print("Recreating from the current checkout; no image builds or pulls.", flush=True)
        reset(*plan, int(seconds))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired, OSError, ValueError) as error:
        print(f"Reset stopped: {error}", file=sys.stderr)
        sys.exit(1)

#!/usr/bin/env python3
"""Prepare and operate the dedicated EEZ Lark L1 and PBS through Swarmpit."""

import argparse
import json
import os
from pathlib import Path
import re
import stat
import sys
import urllib.error
import urllib.parse
import urllib.request

import yaml


REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "deploy/swarm/lark"))
from lifecycle import DeploymentError, Lifecycle, State  # noqa: E402
from pbs.lifecycle import PbsLifecycle  # noqa: E402


class PreflightError(Exception):
    pass


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Do not forward the administration token to a redirect target.
        raise PreflightError("Swarmpit redirected the request; use its direct HTTPS URL")


class Swarmpit:
    def __init__(self, url, token_file):
        parts = urllib.parse.urlsplit(url)
        if (parts.scheme != "https" or not parts.hostname or parts.username is not None
                or parts.password is not None or parts.query
                or parts.path.rstrip("/") not in ("", "/api")):
            raise PreflightError("use the direct Swarmpit HTTPS origin or /api URL")
        self.base = urllib.parse.urlunsplit(("https", parts.netloc, "/api", "", ""))
        # Read the opened file's permissions, rather than checking a different path.
        with token_file.open() as source:
            metadata = os.fstat(source.fileno())
            if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid()
                    or stat.S_IMODE(metadata.st_mode) & 0o077):
                raise PreflightError("token file must be owned by this user and private (chmod 600)")
            token = source.read(16385).strip()
        if token == "Bearer":
            token = ""
        elif token.startswith("Bearer "):
            token = token[7:]
        if not token or len(token) > 16384 or any(c.isspace() for c in token):
            raise PreflightError("token file is empty or malformed")
        self.authorization = "Bearer " + token
        self.opener = urllib.request.build_opener(NoRedirects())

    def get(self, resource):
        if (resource not in ("version", "nodes", "services", "stacks", "networks", "volumes", "secrets")
                and not re.fullmatch(r"services/[a-z0-9]{25}/(?:tasks|logs\?since=1970-01-01T00:00:00Z)", resource)
                and not re.fullmatch(r"stacks/eez-lark-1(?:-[a-z0-9-]+)?/(?:file|services)", resource)):
            raise PreflightError("unsupported preflight resource")
        return self.request("GET", resource)

    def post(self, resource, body):
        fields = {"volumes": "volumeName", "secrets": "secretName", "configs": "configName"}
        if resource in fields:
            name = body.get(fields[resource], "")
            allowed = bool(re.fullmatch(r"eez-lark-1-[a-z0-9-]+", name))
        elif resource == "stacks" or re.fullmatch(r"stacks/eez-lark-1(?:-[a-z0-9-]+)?", resource):
            name = body.get("name", "")
            allowed = (name == "eez-lark-1" or bool(re.fullmatch(r"eez-lark-1-[a-z0-9-]+", name)))
            allowed = allowed and (resource == "stacks" or resource == "stacks/" + name)
        else:
            allowed = False
        if not allowed:
            raise PreflightError("writes are restricted to dedicated eez-lark-1 resources")
        return self.request("POST", resource, body)

    def request(self, method, resource, body=None):
        request = urllib.request.Request(self.base + "/" + resource,
            method=method, data=json.dumps(body).encode() if body is not None else None,
            headers={"Authorization": self.authorization, "Accept": "application/json",
                     "Content-Type": "application/json"})
        try:
            with self.opener.open(request, timeout=30) as response:
                raw = response.read(16 * 1024 * 1024 + 1)
            if len(raw) > 16 * 1024 * 1024:
                raise PreflightError("Swarmpit response exceeds 16 MiB")
            return json.loads(raw) if raw.strip() else None
        except urllib.error.HTTPError as error:
            # Error bodies may contain server configuration or credentials.
            raise PreflightError(f"Swarmpit {resource}: HTTP {error.code}") from None
        except (urllib.error.URLError, TimeoutError, UnicodeError, json.JSONDecodeError):
            raise PreflightError(f"Swarmpit {resource}: request or JSON response failed") from None


def inventory(api):
    nodes, services, stacks, networks = (api.get(name) for name in
                                        ("nodes", "services", "stacks", "networks"))
    if not all(isinstance(value, list) and all(isinstance(item, dict) for item in value)
               for value in (nodes, services, stacks, networks)):
        raise PreflightError("unexpected Swarmpit inventory format")
    def node_summary(node):
        result = {key: node[key] for key in (
            "id", "nodeName", "role", "state", "availability", "labels",
            "arch", "os", "resources") if key in node}
        stats = node.get("stats") or {}
        result["stats"] = {group: {key: values[key] for key in fields if key in values}
            for group, fields in (
                ("cpu", ("cores", "usedPercentage")),
                ("memory", ("total", "free", "used", "usedPercentage")),
                ("disk", ("total", "free", "used", "usedPercentage")))
            if isinstance(values := stats.get(group), dict)}
        return result
    def service_summary(service):
        result = {key: service[key] for key in (
            "id", "serviceName", "stack", "state", "replicas") if key in service}
        status = service.get("status") or {}
        result["status"] = {key: status[key] for key in ("tasks", "update") if key in status}
        return result
    # Select fields explicitly. Never persist raw services, configs or secrets.
    return {"operation": "read-only", "l1_chain_id": 686868, "l2_chain_id": 696969,
        "nodes": [node_summary(node) for node in nodes],
        "services": [service_summary(service) for service in services],
        "stacks": [{key: stack[key] for key in ("stackName", "state") if key in stack}
                   for stack in stacks],
        "networks": [{key: network[key] for key in ("id", "networkName", "driver", "scope")
                      if key in network} for network in networks]}


def render_l1(node_id, fee_recipient):
    if not re.fullmatch(r"[a-z0-9]{25}", node_id):
        raise PreflightError("select a Swarm node ID from inspect")
    if (not re.fullmatch(r"0x[0-9a-fA-F]{40}", fee_recipient)
            or int(fee_recipient, 16) == 0):
        raise PreflightError("fee recipient must be a nonzero Ethereum address")
    fixtures = json.loads((REPO / "genesis.dev.json").read_text())["alloc"]
    funded = {address.lower() for address, value in fixtures.items()
              if int(value.get("balance", "0"), 0) > 0}
    if fee_recipient.lower().removeprefix("0x") in {a.removeprefix("0x") for a in funded}:
        raise PreflightError("Lark requires its own accounts, not funded local fixtures")
    source = (REPO / "deploy/swarm/lark/l1.yml").read_text()
    for name, value in (("EEZ_LARK_DATA_NODE", node_id),
                        ("EEZ_LARK_FEE_RECIPIENT", fee_recipient.lower())):
        source = re.sub(r"\$\{" + name + r":\?[^}]+\}", value, source)
    if "${" in source:
        raise PreflightError("unresolved Lark stack input")
    return yaml.safe_load(source)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    inspect = commands.add_parser("inspect", help="read-only cluster inventory")
    inspect.add_argument("--url", required=True, help="direct Swarmpit HTTPS origin")
    inspect.add_argument("--token-file", type=Path,
                         default=Path.home() / ".config/lark-swarmpit-token")
    render = commands.add_parser("render-l1", help="render a public L1 stack to stdout, offline")
    render.add_argument("--node-id", required=True)
    render.add_argument("--fee-recipient", required=True)
    for command in ("bootstrap-l1", "l1-start", "l1-stop", "l1-status", "l1-check",
                    "bootstrap-pbs", "up", "down", "status", "check", "diagnose", "retry-canary", "probe-pbs"):
        operation = commands.add_parser(command)
        operation.add_argument("--url", required=True)
        operation.add_argument("--token-file", type=Path,
                               default=Path.home() / ".config/lark-swarmpit-token")
        operation.add_argument("--state-dir", type=Path, default=Path.home() / ".config/eez-lark-1")
        operation.add_argument("--timeout", type=int, default=3600)
        if command == "bootstrap-l1":
            operation.add_argument("--node-id", required=True)
            operation.add_argument("--validator-tool", type=Path, required=True,
                                   help="eth2-val-tools extracted by deploy/swarm/lark/tools.sh")
        if command in ("bootstrap-pbs", "probe-pbs"):
            operation.add_argument("--cast", type=Path, required=True, help="pinned Foundry 1.7.1 cast binary")
    args = parser.parse_args()
    try:
        if args.command == "inspect":
            result = inventory(Swarmpit(args.url, args.token_file))
        elif args.command == "render-l1":
            result = render_l1(args.node_id, args.fee_recipient)
        else:
            if not 30 <= args.timeout <= 7200:
                raise PreflightError("timeout must be between 30 and 7200 seconds")
            api = Swarmpit(args.url, args.token_file)
            with State(args.state_dir, api.base, readonly=args.command in ("l1-status", "status")) as state:
                lifecycle = PbsLifecycle(api, state, render_l1, args.timeout)
                if args.command == "bootstrap-l1":
                    result = lifecycle.bootstrap(args.node_id, args.validator_tool)
                elif args.command == "l1-start":
                    result = lifecycle.scale(1)
                elif args.command == "l1-stop":
                    result = lifecycle.scale(0)
                elif args.command == "l1-check":
                    result = lifecycle.check()
                elif args.command == "bootstrap-pbs":
                    result = lifecycle.bootstrap_pbs(args.cast)
                elif args.command in ("up", "down"):
                    result = lifecycle.all_scale(int(args.command == "up"))
                elif args.command == "check":
                    result = lifecycle.pbs_check() if state.data.get('pbs') else lifecycle.check()
                elif args.command == "diagnose":
                    result = lifecycle.diagnose()
                elif args.command == "retry-canary":
                    result = lifecycle.retry_canary()
                elif args.command == "probe-pbs":
                    result = lifecycle.probe(args.cast)
                else:
                    result = lifecycle.status()
        # JSON is valid YAML and is accepted as a Compose document by Swarm.
        print(json.dumps(result, indent=2))
    except (PreflightError, DeploymentError) as error:
        print(f"lark-swarmpit: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("lark-swarmpit: interrupted; submitted EEZ jobs remain running and retained", file=sys.stderr)
        return 130
    except (OSError, ValueError, TypeError):
        print("lark-swarmpit: invalid input or unreadable private configuration/state", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

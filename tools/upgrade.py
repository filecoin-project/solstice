#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["safe-eth-py>=7.0,<8"]
# ///
# The `<8` cap keeps us on the safe-eth-py major version this was written and tested against; the exact
# versions actually installed are pinned by tools/upgrade.py.lock (run with `uv run --locked`).
"""Every step of an SRA/SWA implementation upgrade, as one command each. See docs/UPGRADE.md.

Both contracts are always upgraded together, so every operation acts on both.

The environment says where the tool runs and with which key (in GitHub, from the workflow and its environment);
arguments say what to do this time.

Environment:
  ETH_RPC_URL           required; selects the network (chain id 314 or 314159); forge and cast read it too
  DEPLOYER_PRIVATE_KEY  the operations key: registered once by an owner of each Safe as a proposer
                        (https://help.safe.global/articles/1671337645-proposers) for `propose`; any funded key
                        for `execute`
  DEPLOYER_ADDRESS      the operations key's public address (a GitHub Actions variable): `check-setup` reports on it
                        without needing the key; when set, every command that uses DEPLOYER_PRIVATE_KEY first stops
                        if the key's address differs

`propose` first makes the `check-setup` checks and posts nothing unless every owner Safe is an owner on its proxy
and has the key as a proposer. It then runs script/Verify.s.sol with the new addresses as candidates, which rebuilds
both implementations from the checked-out source and refuses unless the on-chain runtime code matches, so the queued
transactions always refer to code built from this commit. See docs/UPGRADE.md step 4 for what happens after the proposals are queued.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

from eth_abi import encode
from eth_account import Account
from eth_utils import keccak, to_checksum_address
from safe_eth.eth import EthereumClient, EthereumNetwork
from safe_eth.safe import Safe
from safe_eth.safe.api import TransactionServiceApi

ROOT = Path(__file__).resolve().parent.parent
TARGETS = ("sra", "swa")

# ERC-1967 implementation slot: keccak256("eip1967.proxy.implementation") - 1. Same constant as
# lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Utils.sol.
IMPLEMENTATION_SLOT = bytes.fromhex("360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc")
# ERC-7201 slot of the pending-task mapping: keccak256(abi.encode(uint256(keccak256("Solstice.PendingTasks")) - 1))
# & ~0xff. Same constant as src/lib/PendingTask.sol; test/StorageSlots.t.sol pins it.
PENDING_TASKS_SLOT = bytes.fromhex("635f64a8ec66823e68578973f5bc466fd4e0eadd655f760cfc91e860524aa300")
# ERC-7201 slot of the owner set: keccak256(abi.encode(uint256(keccak256("Solstice.Owners")) - 1)) & ~0xff. Same
# constant as src/lib/Owners.sol; word 0 is the ownerInfo mapping base, whose value's low byte is the owner's bit id.
OWNERS_SLOT = bytes.fromhex("7d2e7f914625694dd929b468ac404d7943373f4d24421c78ac93b57cc8efb500")
UPGRADE_SELECTOR = keccak(text="upgradeToAndCall(address,bytes)")[:4]
VETO_SELECTOR = keccak(text="veto(bytes32)")[:4]
# The labels the Upgrade workflow's `network` input uses, written into the release by `verify --record-release`.
NETWORK_NAMES = {314: "Mainnet", 314159: "Calibnet"}
SAFE_SERVICES = {
    314: "https://transaction.safe.filecoin.io",
    314159: "https://transaction-testnet.safe.filecoin.io",
}


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def forge_script(script, env=None):
    """Run a forge script against ETH_RPC_URL (no broadcast); print its log lines; exit on failure."""
    r = subprocess.run(
        ["forge", "script", script, "--rpc-url", os.environ["ETH_RPC_URL"]],
        cwd=ROOT, env={**os.environ, **(env or {})}, capture_output=True, text=True,
    )
    if r.returncode != 0:
        tail = [l for l in (r.stdout + r.stderr).splitlines() if "Error" in l or "Revert" in l] or r.stdout.splitlines()[-15:]
        print("\n".join(tail), file=sys.stderr)
        die(f"{script} failed")
    for line in script_logs(r.stdout):
        print(line)
    return r.stdout


def script_logs(stdout):
    """The console.log lines of a forge script run: everything between forge's `== Logs ==` marker and the next
    section header, stripped of indentation."""
    lines, on = [], False
    for line in stdout.splitlines():
        if line.strip() == "== Logs ==":
            on = True
            continue
        if on and (line.startswith("##") or line.startswith("== ") or line.startswith("Script ran")):
            break
        if on and line.strip():
            lines.append(line.strip())
    return lines


def deployer_address():
    """DEPLOYER_ADDRESS, checksummed, or None when unset."""
    value = os.environ.get("DEPLOYER_ADDRESS")
    return to_checksum_address(value) if value else None


def key_account(purpose):
    """The operations key and its account. Stops if DEPLOYER_ADDRESS is set and differs: GitHub never shows a
    secret, so this is how a run confirms the secret holds the intended key before it signs or sends anything."""
    key = os.environ.get("DEPLOYER_PRIVATE_KEY") or die(f"DEPLOYER_PRIVATE_KEY is required for {purpose}")
    account = Account.from_key(key)
    expected = deployer_address()
    if expected and account.address != expected:
        die(f"DEPLOYER_PRIVATE_KEY is the key for {account.address}, but DEPLOYER_ADDRESS is {expected}; nothing was "
            "sent. Set both to the same key (see the key rotation FAQ in docs/UPGRADE.md).")
    return key, account


def operations_address(purpose):
    """The operations key's address: DEPLOYER_ADDRESS, or else derived from DEPLOYER_PRIVATE_KEY."""
    return deployer_address() or key_account(purpose)[1].address


class Chain:
    def __init__(self):
        rpc = os.environ.get("ETH_RPC_URL") or die("ETH_RPC_URL is required")
        self.client = EthereumClient(rpc)
        self.w3 = self.client.w3
        self.chain_id = self.w3.eth.chain_id
        self.cfg = json.loads((ROOT / "deployments.json").read_text())[str(self.chain_id)]
        self.hold = int(self.cfg["hold"])

    def proxy(self, target):
        return to_checksum_address(self.cfg[target])

    def owners(self, target):
        return [to_checksum_address(self.cfg[f"{target}Owner1"]), to_checksum_address(self.cfg[f"{target}Owner2"])]

    def current_impl(self, target, block="latest"):
        return to_checksum_address(self.w3.eth.get_storage_at(self.proxy(target), IMPLEMENTATION_SLOT, block)[-20:])

    def owner_bit(self, target, owner):
        """The owner's bit id in the proxy's owner set (0 if not an owner); bit ids are 1-based."""
        slot = keccak(encode(["address", "bytes32"], [to_checksum_address(owner), OWNERS_SLOT]))
        return self.w3.eth.get_storage_at(self.proxy(target), slot)[-1]


class Task:
    """One `upgradeToAndCall(impl, "")` task on one proxy: its calldata, id, and on-chain state."""

    def __init__(self, chain, target, implementation):
        self.chain, self.target = chain, target
        self.name = target.upper()
        self.proxy = chain.proxy(target)
        self.impl = to_checksum_address(implementation)
        self.calldata = upgrade_calldata(self.impl)
        self.task_id = keccak(self.calldata)
        self.slot = keccak(encode(["bytes32", "bytes32"], [self.task_id, PENDING_TASKS_SLOT]))

    def word(self):
        return int.from_bytes(self.chain.w3.eth.get_storage_at(self.proxy, self.slot), "big")

    def state(self):
        """(last modified epoch, number of approvals); (0, 0) when no task is pending."""
        word = self.word()
        return word & ((1 << 64) - 1), bin((word >> 64) & ((1 << 160) - 1)).count("1")

    def approved_by(self, owner):
        """Whether this owner's approval bit is already set on the pending task."""
        return approval_set(self.word(), self.chain.owner_bit(self.target, owner))

    def executable(self, block):
        modified, approvals = self.state()
        return modified != 0 and approvals >= 2 and block >= modified + self.chain.hold

    def summary(self):
        print()
        print(f"== {self.name} upgrade on chain {self.chain.chain_id} ==")
        print(f"proxy                   {self.proxy}")
        print(f"current implementation  {self.chain.current_impl(self.target)}")
        print(f"implementation          {self.impl}")
        print(f"owner Safes             {'  '.join(self.chain.owners(self.target))}")
        print(f"hold (epochs)           {self.chain.hold}")
        print(f"task id                 0x{self.task_id.hex()}")
        print("calldata (to proxy, value 0):")
        print("0x" + self.calldata.hex())
        print("veto calldata (either owner, to proxy):")
        print("0x" + (VETO_SELECTOR + self.task_id).hex())

    def status(self):
        modified, approvals = self.state()
        block = self.chain.w3.eth.block_number
        print(f"[{self.name} task 0x{self.task_id.hex()[:10]}... -> {self.impl}] ", end="")
        if modified != 0:
            end = modified + self.chain.hold
            left = end - block
            if approvals >= 2:
                print(f"approved by both owners at epoch {modified}; "
                      + (f"hold ends at epoch {end} ({left} epochs, about {epochs_to_text(left)})" if left > 0 else "executable now by anyone"))
            else:
                print(f"{approvals} approval(s), last at epoch {modified}; the hold starts on the second approval")
        elif self.chain.current_impl(self.target) == self.impl:
            print("live: the proxy points at this implementation")
        else:
            print("no pending task (not submitted, or already executed or vetoed)")


def approval_set(task_word, bit_id):
    """Whether the owner with 1-based `bit_id` has approved, given the raw PendingTask word."""
    if bit_id == 0:
        return False
    approvals = (task_word >> 64) & ((1 << 160) - 1)
    return bool(approvals & (1 << (bit_id - 1)))


def epochs_to_text(epochs):
    """Filecoin epochs are 30 seconds; say it in minutes, hours or days as appropriate."""
    seconds = epochs * 30
    if seconds < 2 * 3600:
        return f"{seconds // 60} min"
    if seconds < 2 * 86400:
        return f"{seconds / 3600:.1f} h"
    return f"{seconds / 86400:.1f} days"


def at_block(read, timeout=90, sleep=time.sleep):
    """Run a read pinned to a block, retrying while the RPC backend has not seen that block yet. Glif load-balances
    across nodes that can lag a tipset, and a lagging one rejects the block with varying wording ("tipset height
    in future", "requested a future epoch", ...), so any error is retried until the deadline; the read is pure."""
    deadline = time.monotonic() + timeout
    while True:
        try:
            return read()
        except Exception:
            if time.monotonic() >= deadline:
                raise
            sleep(5)


def next_nonce(on_chain, queued):
    """Next free Safe nonce: after every queued transaction, but never below the on-chain nonce, since the
    service may still list stale proposals whose nonce has already been consumed."""
    return max([on_chain] + [n + 1 for n in queued if n >= on_chain])


def already_queued(queued, on_chain, to, data):
    """The queued (unexecuted) Safe transaction that already carries this exact call (a zero-value CALL to `to`
    with `data`), if any. Proposals whose nonce is below the on-chain nonce can never execute, so they do not
    count; neither does a DELEGATECALL or a value-carrying transaction with the same data, since the proxy would
    reject those and they cannot stand in for the approval."""
    for t in queued:
        if (int(t["nonce"]) >= on_chain and int(t.get("operation") or 0) == 0 and int(t.get("value") or 0) == 0
                and (t.get("to") or "").lower() == to.lower()
                and (t.get("data") or "").lower() == "0x" + data.hex()):
            return t
    return None


def upgrade_calldata(implementation):
    """`upgradeToAndCall(implementation, "")`, byte-identical for every sender; its keccak is the task id."""
    return UPGRADE_SELECTOR + encode(["address", "bytes"], [to_checksum_address(implementation), b""])


def tasks(chain, args):
    return [Task(chain, t, getattr(args, t)) for t in TARGETS]


def cmd_rehearse(args):
    print("== Rehearsing the SRA and SWA upgrades in a local fork (script/Rehearse.s.sol) ==")
    forge_script("script/Rehearse.s.sol")


def cmd_propose(args):
    chain = Chain()
    key, account = key_account("propose")
    base_url, api = safe_service(chain)
    todo = tasks(chain, args)
    # The same checks as `check-setup`, before anything is posted, so a missing proposer registration cannot leave
    # the upgrade queued on some Safes and not others.
    not_owners, not_proposers, ahead_of = check_setup(chain, account.address, api, {t.target: t.impl for t in todo})
    if not_owners:
        die(NOT_OWNERS + "; ".join(not_owners))
    if not_proposers and not args.dry_run:
        die(f"{account.address} is not a proposer on: " + "; ".join(not_proposers) + ". An owner of each registers it "
            "once in the Safe app; see the Operations key row in docs/UPGRADE.md. Nothing was posted.")
    if ahead_of:
        print("NOTE: the upgrade will queue behind other transactions on " + "; ".join(ahead_of) + ". Those owners "
              "must execute or reject them before they can execute the upgrade.")
        print()
    print("== Checking both candidates against a local build of the checked-out source (script/Verify.s.sol) ==")
    forge_script("script/Verify.s.sol", {f"NEW_IMPLEMENTATION_{t.name}": t.impl for t in todo})
    for task in todo:
        task.summary()
        print()
        print(f"== Queuing the {task.name} upgrade on its owner Safes as {account.address} via {base_url} ==")
        for owner in chain.owners(task.target):
            if task.approved_by(owner):
                print(f"Safe {owner}: already approved this task on chain; skipping (a second execution would revert)")
                continue
            safe = Safe(owner, chain.client)
            on_chain = safe.retrieve_nonce()
            queued = api.get_transactions(owner, executed="false", limit=100)
            same = already_queued(queued, on_chain, task.proxy, task.calldata)
            if same:
                print(f"Safe {owner}: already queued at nonce {same['nonce']} (safeTxHash {same['safeTxHash']}); skipping")
                continue
            nonce = next_nonce(on_chain, [int(t["nonce"]) for t in queued])
            safe_tx = safe.build_multisig_tx(to=task.proxy, value=0, data=task.calldata, safe_nonce=nonce)
            safe_tx.sign(key)
            print(f"Safe {owner}: nonce {nonce}, safeTxHash 0x{safe_tx.safe_tx_hash.hex()}")
            if args.dry_run:
                print(f"  dry run: would post to {base_url}/api/v2/safes/{owner}/multisig-transactions/")
                continue
            try:
                api.post_transaction(safe_tx)
            except Exception as e:  # SafeAPIException carries the service's reason
                die(f"  proposal rejected: {e}\n  Is {account.address} registered as a proposer on {owner}? An owner of that Safe "
                    "registers it once in the Safe app; see the Operations key row in docs/UPGRADE.md.")
            print(f"  queued; the owners of {owner} confirm and execute it at https://safe.filecoin.io")
    print()
    print("Next: tell each owner group their Safe has the upgrade queued. The first owner's execution submits it; "
          "the second's approves it and starts the hold.")


def cmd_status(args):
    chain = Chain()
    print(f"== Task status on chain {chain.chain_id}, epoch {chain.w3.eth.block_number} ==")
    for task in tasks(chain, args):
        task.status()
    for task in tasks(chain, args):
        task.summary()


def safe_service(chain):
    base_url = SAFE_SERVICES.get(chain.chain_id) or die(f"no Safe Transaction Service known for chain {chain.chain_id}")
    return base_url, TransactionServiceApi(EthereumNetwork(chain.chain_id), ethereum_client=chain.client, base_url=base_url)


def check_setup(chain, address, api, candidates):
    """Print what `propose` and `execute` depend on and return the problems as (not owners, not proposers, queued
    ahead), each a list of "<name> <Safe>" strings: for each owner Safe in deployments.json, whether it is an owner on
    the live proxy, whether the operations key's `address` is registered as its proposer, and what is queued at or above its on-chain nonce
    other than the candidate's own upgrade (an upgrade lines up behind those). `candidates` maps a target to an
    implementation address or None; for each given one, also whether the proxy already points at it."""
    print(f"== Operations key on chain {chain.chain_id} ==")
    print(f"address: {address}")
    print(f"balance: {chain.w3.eth.get_balance(address) / 10**18:.4f} FIL")
    not_owners, not_proposers, ahead_of = [], [], []
    for target in TARGETS:
        current = chain.current_impl(target)
        candidate = candidates.get(target)
        task = Task(chain, target, candidate) if candidate else None
        print()
        print(f"== {target.upper()} proxy {chain.proxy(target)}, implementation {current} ==")
        for n, owner in enumerate(chain.owners(target), 1):
            name = f"{target}Owner{n} {owner}"
            is_owner = chain.owner_bit(target, owner) != 0
            proposer = any(d["delegate"].lower() == address.lower() for d in api.get_delegates(owner))
            on_chain = Safe(owner, chain.client).retrieve_nonce()
            ahead = sorted(int(t["nonce"]) for t in api.get_transactions(owner, executed="false", limit=100)
                           if int(t["nonce"]) >= on_chain
                           and not (task and already_queued([t], on_chain, task.proxy, task.calldata)))
            not_owners += [] if is_owner else [name]
            not_proposers += [] if proposer else [name]
            ahead_of += [f"{name} (nonces {ahead})"] if ahead else []
            print(f"{name}: "
                  + ("owner on the proxy" if is_owner else "NOT an owner on the proxy") + "; "
                  + ("key is a proposer" if proposer else "key is NOT a proposer") + "; "
                  + f"nonce {on_chain}, " + (f"other transactions queued at nonces {ahead}" if ahead else "nothing else queued"))
        if task:
            if candidate == current:
                print(f"candidate {candidate}: the proxy already points at it")
            else:
                print(f"candidate {candidate}: the proxy points elsewhere (upgrade not yet executed)")
                task.status()
    print()
    return not_owners, not_proposers, ahead_of


NOT_OWNERS = "not owners on their proxy (deployments.json is out of date, or an owner was replaced): "


def cmd_check_setup(args):
    """Report what `propose` depends on, without sending anything (see check_setup). Needs only the operations key's
    address, so it runs without the gated environment. Fails if a deployments.json owner is not an owner on its proxy
    or does not have the address as a proposer, the two things `propose` refuses on; transactions queued ahead are
    only reported."""
    chain = Chain()
    _, api = safe_service(chain)
    address = operations_address("check-setup")
    not_owners, not_proposers, _ = check_setup(chain, address, api, {t: getattr(args, t) for t in TARGETS})
    if not_owners or not_proposers:
        die("; ".join(([NOT_OWNERS + "; ".join(not_owners)] if not_owners else [])
                      + ([f"{address} is not a proposer on: " + "; ".join(not_proposers)] if not_proposers else [])))


def release_ref(ref_type, ref_name):
    """Whether a dispatch ref is one the gated environments accept: the `main` branch or a `v*` tag."""
    return (ref_type == "branch" and ref_name == "main") or (ref_type == "tag" and ref_name.startswith("v"))


def pregate_report(title, actor, ref_name, ref_type, sha, rows, checks):
    """The run-summary section a reviewer reads before approving: what was dispatched, then each check as
    (passed, text)."""
    lines = [f"## Approving: {title}", "", "| | |", "|---|---|",
             f"| Dispatched by | `{actor}` |", f"| Ref | `{ref_name}` ({ref_type}) |", f"| Commit | `{sha}` |"]
    lines += [f"| {label} | `{value or '(none)'}` |" for label, value in rows]
    lines += [""] + [f"- {'✅' if ok else '❌'} {text}" for ok, text in checks]
    return "\n".join(lines) + "\n"


def cmd_pregate(args):
    """Before a job that waits for environment approval: summarize what is being approved (GitHub shows dispatch
    inputs nowhere on a run) and check the ref and addresses, failing before the approval request if one is wrong.
    Reads the dispatch from GitHub's GITHUB_* variables; appends to GITHUB_STEP_SUMMARY when set."""
    env = os.environ
    actor, ref_name, ref_type = env.get("GITHUB_ACTOR", ""), env.get("GITHUB_REF_NAME", ""), env.get("GITHUB_REF_TYPE", "")
    sha = env.get("GITHUB_SHA") or sh("git", "rev-parse", "HEAD")
    checks = []
    if release_ref(ref_type, ref_name):
        checks.append((True, f"ref `{ref_name}` is `main` or a `v*` tag"))
    else:
        checks.append((False, f"ref `{ref_name}` ({ref_type}) is neither `main` nor a `v*` tag"))
    on_main = subprocess.run(["git", "merge-base", "--is-ancestor", sha, "origin/main"], cwd=ROOT).returncode == 0
    checks.append((on_main, f"commit `{sha[:12]}` is {'' if on_main else 'not '}on `main`"))
    rows, chain = [], None
    for label, value in (("SRA", args.sra), ("SWA", args.swa)):
        if not value and not args.require_addresses:
            continue
        rows.append((label, value))
        if not value:
            checks.append((False, f"{label} address is missing"))
            continue
        try:
            addr = to_checksum_address(value)
        except Exception:
            checks.append((False, f"{label} `{value}` is not an address"))
            continue
        chain = chain or Chain()
        has_code = len(chain.w3.eth.get_code(addr)) > 0
        checks.append((has_code, f"{label} `{addr}` {'has' if has_code else 'has no'} code on chain"))
    report = pregate_report(args.title, actor, ref_name, ref_type, sha, rows, checks)
    print(report)
    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write(report)
    if not all(ok for ok, _ in checks):
        die("a pre-gate check failed; not requesting approval")


def cmd_execute(args):
    chain = Chain()
    key, account = key_account("execute")
    todo = [t for t in tasks(chain, args) if chain.current_impl(t.target) != t.impl]
    block = chain.w3.eth.block_number
    for task in todo:
        task.status()
    not_ready = []
    for t in todo:
        modified, _ = t.state()
        if modified == 0:
            not_ready.append(f"{t.name} has no pending task (never submitted, or vetoed)")
        elif not t.executable(block):
            not_ready.append(f"{t.name} not yet executable")
    if not_ready:
        die("not executing anything (both contracts must be ready): " + "; ".join(not_ready))
    # Filecoin state at "latest" lags a message whose receipt was just returned by one tipset, so take the nonce
    # from "pending" once and count up locally, and read results at the receipt's block rather than "latest".
    nonce = chain.w3.eth.get_transaction_count(account.address, "pending")
    for task in todo:
        print(f"== Executing the {task.name} upgrade from {account.address} ==")
        tx = {
            "from": account.address, "to": task.proxy, "data": task.calldata, "value": 0,
            "chainId": chain.chain_id, "nonce": nonce,
        }
        try:
            tx["gas"] = chain.w3.eth.estimate_gas(tx)
        except Exception as e:
            die(f"execution would revert: {e}")
        fees = chain.w3.eth.fee_history(1, "latest", [50])
        tx["maxPriorityFeePerGas"] = int(fees["reward"][0][0]) if fees.get("reward") else chain.w3.eth.max_priority_fee
        tx["maxFeePerGas"] = int(fees["baseFeePerGas"][-1]) * 2 + tx["maxPriorityFeePerGas"]
        tx_hash = chain.w3.eth.send_raw_transaction(account.sign_transaction(tx).raw_transaction)
        nonce += 1
        receipt = chain.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=600)
        print(f"tx 0x{tx_hash.hex()} status {receipt['status']} block {receipt['blockNumber']}")
        if receipt["status"] != 1:
            die("execution transaction reverted; rerun `execute` once the cause is fixed (it skips contracts already upgraded)")
        live = at_block(lambda: chain.current_impl(task.target, receipt["blockNumber"]))
        if live != task.impl:
            die(f"implementation slot at block {receipt['blockNumber']} is {live}, not {task.impl}")
        print(f"implementation slot now {task.impl}")
    print()
    for task in tasks(chain, args):
        task.status()


def cmd_verify(args):
    print("== script/Verify.s.sol against the live chain ==")
    if "ALL CHECKS PASSED" not in forge_script("script/Verify.s.sol"):
        die("verification did not pass")
    if args.record_release:
        record_release(args.record_release)


def sh(*cmd, check=True):
    return subprocess.run(cmd, cwd=ROOT, check=check, capture_output=True, text=True).stdout.strip()


def record_release(tag):
    """Append the verified implementations to the GitHub release for `tag`, which must point at this commit; on
    mainnet promote the pre-release to the final release. Only for commits on main, since this runs without
    reviewers. The tag is passed explicitly (the workflow passes the dispatched ref) rather than discovered with
    `git describe`, which picks an arbitrary tag when several point at the same commit."""
    sh("git", "fetch", "--quiet", "--tags", "origin", "main")
    head = sh("git", "rev-parse", "HEAD")
    if subprocess.run(["git", "merge-base", "--is-ancestor", head, "origin/main"], cwd=ROOT).returncode != 0:
        die(f"{head[:8]} is not on main; not touching the release")
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        print(f"{tag!r} is not a v* release tag; nothing to record")
        return
    tagged = sh("git", "rev-parse", f"{tag}^{{commit}}", check=False)
    if tagged != head:
        die(f"tag {tag} points at {tagged[:8] or 'nothing'}, not at HEAD {head[:8]}; not touching the release")
    if subprocess.run(["gh", "release", "view", tag], cwd=ROOT, capture_output=True).returncode != 0:
        print(f"no release {tag}; nothing to record")
        return
    chain = Chain()
    network = NETWORK_NAMES[chain.chain_id]
    facts = f"SRA implementation `{chain.current_impl('sra')}`, SWA implementation `{chain.current_impl('swa')}`"
    body = sh("gh", "release", "view", tag, "--json", "body", "-q", ".body")
    # Every successful verification is appended (epoch and run link included), so a rerun and a rollback's
    # re-verification both show in the release as what they are.
    run_url = os.environ.get("RUN_URL", "")
    body += (f"\n\n**Verified on {network}** at epoch {chain.w3.eth.block_number} from `{head[:8]}`"
             + (f" ([run]({run_url}))" if run_url else "") + f": {facts}.\n")
    notes = ROOT / "release-notes.tmp.md"
    notes.write_text(body)
    try:
        if network == "Mainnet":
            sh("gh", "release", "edit", tag, "--notes-file", str(notes), "--prerelease=false", "--latest")
            print(f"recorded verification in {tag} and made it the final release")
        else:
            sh("gh", "release", "edit", tag, "--notes-file", str(notes))
            print(f"recorded verification in pre-release {tag}")
    finally:
        notes.unlink(missing_ok=True)


def address(value):
    try:
        return to_checksum_address(value)
    except Exception:
        raise argparse.ArgumentTypeError(f"not an address: {value}")


def optional_address(value):
    """An address, or None for the empty string the workflow passes when the input is left blank."""
    return address(value) if value else None


def main(argv):
    p = argparse.ArgumentParser(prog="tools/upgrade.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="operation", required=True, metavar="operation")

    def impls(sp):
        sp.add_argument("--sra", type=address, required=True, help="SRA implementation address")
        sp.add_argument("--swa", type=address, required=True, help="SWA implementation address")

    sub.add_parser("rehearse", help="dry-run both upgrades in a local fork, built from the checked-out source")
    pr = sub.add_parser("propose", help="check both implementations and queue the upgrades on the owner Safes")
    impls(pr)
    pr.add_argument("--dry-run", action="store_true", help="build and sign the Safe transactions but do not post them")
    impls(sub.add_parser("status", help="approvals and hold end for both tasks (pass previous addresses to see a prepared rollback)"))
    impls(sub.add_parser("execute", help="send both upgrades once both holds have elapsed"))
    c = sub.add_parser("check-setup", help="report the operations key, owners, proposer registration and Safe queues (sends nothing)")
    c.add_argument("--sra", type=optional_address, help="also show this SRA candidate's task status")
    c.add_argument("--swa", type=optional_address, help="also show this SWA candidate's task status")
    g = sub.add_parser("pregate", help="summarize and check a dispatch before its environment approval (sends nothing; see cmd_pregate)")
    g.add_argument("--title", required=True, help='what is being approved, e.g. "propose on Calibnet"')
    # Raw strings, not `address`, so a malformed address is reported in the summary rather than by argparse.
    g.add_argument("--sra", default="", help="SRA implementation address, checked to have code")
    g.add_argument("--swa", default="", help="SWA implementation address, checked to have code")
    g.add_argument("--require-addresses", action="store_true", help="fail if --sra or --swa is missing")
    v = sub.add_parser("verify", help="run script/Verify.s.sol against the live chain")
    v.add_argument("--record-release", metavar="TAG", help="append the result to the GitHub release for TAG, which must point at HEAD; promote on mainnet")

    args = p.parse_args(argv)
    {"rehearse": cmd_rehearse, "propose": cmd_propose, "status": cmd_status, "execute": cmd_execute, "verify": cmd_verify,
     "check-setup": cmd_check_setup, "pregate": cmd_pregate}[args.operation](args)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

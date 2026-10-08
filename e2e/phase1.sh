#!/usr/bin/env bash
# Phase I walkthrough on a local mainnet fork: deposit into the 0.01 ETH pool and withdraw through
# every path, showing where each wei goes; then show the fees cannot leave the pool until the
# staking upgrade, simulate that upgrade, and watch a TORN locker claim the fees.
#
#   ./e2e/phase1.sh          run every step and write e2e/PHASE1-RESULTS.md
#   ./e2e/phase1.sh fork     only start the fork and keep it running, to run the steps one by one:
#                            node e2e/src/phase1.js setup | deposit | withdraw --via <path> | ...
#
# Needs Foundry (forge, cast, anvil) and Node.js. The mainnet RPC URL is read from ETH_RPC_URL or
# RPC_URL, or from a .env file in this repository or in its parent folder.
#
#   FORK_BLOCK         fork this block instead of the latest one (needs an archive RPC)
#   ANVIL_PORT         port for the local fork (default 8545)
#   TORNADO_KEYS_DIR   folder with tornado.json.gz and tornadoProvingKey.bin.gz
#                      (default ../classic-ui/static, the classic UI's static files)
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
mode="${1:-all}"

rpc_url="${ETH_RPC_URL:-${RPC_URL:-}}"
if [ -z "$rpc_url" ]; then
  for env_file in .env ../.env; do
    if [ -f "$env_file" ]; then
      rpc_url="$(grep -E '^(ETH_RPC_URL|RPC_URL)=' "$env_file" | head -n 1 | cut -d= -f2- | tr -d "\"' " || true)"
      [ -n "$rpc_url" ] && break
    fi
  done
fi
if [ -z "$rpc_url" ]; then
  echo "No mainnet RPC URL: set ETH_RPC_URL or RPC_URL, or put one in a .env file." >&2
  exit 1
fi

keys_dir="${TORNADO_KEYS_DIR:-$repo/../classic-ui/static}"
port="${ANVIL_PORT:-8545}"
local_rpc="http://127.0.0.1:$port"
mkdir -p "$repo/e2e/.work"

if cast block-number --rpc-url "$local_rpc" >/dev/null 2>&1; then
  echo "Something is already listening on port $port. Stop it or set ANVIL_PORT." >&2
  exit 1
fi

echo "==> Installing the test's Node dependencies"
(cd e2e && npm install --no-audit --no-fund --silent)

echo "==> Building the contracts"
forge build >/dev/null

echo "==> Starting a local fork of mainnet on port $port"
# Output is discarded: anvil prints the RPC URL, which may hold an API key.
anvil --fork-url "$rpc_url" ${FORK_BLOCK:+--fork-block-number "$FORK_BLOCK"} --port "$port" --auto-impersonate --silent >/dev/null 2>&1 &
anvil_pid=$!
trap 'kill "$anvil_pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 100); do
  cast block-number --rpc-url "$local_rpc" >/dev/null 2>&1 && break
  sleep 0.2
done
cast block-number --rpc-url "$local_rpc" >/dev/null 2>&1 || { echo "anvil did not start: check the RPC URL." >&2; exit 1; }

if [ "$mode" = "fork" ]; then
  echo "Fork of mainnet block $(cast block-number --rpc-url "$local_rpc") running at $local_rpc. Ctrl-C stops it."
  echo "In another terminal, from the repository root:"
  echo "  node e2e/src/phase1.js setup --rpc $local_rpc --keys \"$keys_dir\""
  echo "  node e2e/src/phase1.js deposit"
  echo "  node e2e/src/phase1.js withdraw --via registered     (then: unregistered, self, router)"
  echo "  node e2e/src/phase1.js sweep | phase2 | sweep | claim | report"
  wait "$anvil_pid"
  exit 0
fi

echo "==> Running the walkthrough"
node e2e/src/phase1.js all --rpc "$local_rpc" --keys "$keys_dir" --out "$repo/e2e/PHASE1-RESULTS.md"

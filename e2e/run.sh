#!/usr/bin/env bash
# End-to-end test on a local mainnet fork: deploy, pass the proposal through Governance, then make
# notes, deposit and withdraw with real proofs through every path, and collect staking rewards.
# Writes the measured amounts to e2e/RESULTS.md and stops at the first amount that is wrong.
#
#   ./e2e/run.sh
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
work="$repo/e2e/.work"
# First account of anvil's default mnemonic: it only pays for the deployments on the fork.
deployer=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
mkdir -p "$work"

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

echo "==> Deploying the proposal"
# The broadcast log goes to the scratch folder, so that it is not mistaken for a mainnet deployment.
FOUNDRY_BROADCAST="$work/broadcast" forge script script/Deploy.s.sol \
  --rpc-url "$local_rpc" --broadcast --unlocked --sender "$deployer" >"$work/deploy.log" 2>&1 \
  || { cat "$work/deploy.log" >&2; exit 1; }
proposal="$(grep -Eo "AddEthPoolsProposal 0x[0-9a-fA-F]{40}" "$work/deploy.log" | tail -n 1 | cut -d' ' -f2)"
[ -n "$proposal" ] || { echo "the deployment did not print the proposal's address:" >&2; cat "$work/deploy.log" >&2; exit 1; }
echo "  AddEthPoolsProposal $proposal"

echo "==> Running the end-to-end test"
node e2e/src/e2e.js --rpc "$local_rpc" --keys "$keys_dir" --proposal "$proposal" --out "$repo/e2e/RESULTS.md"

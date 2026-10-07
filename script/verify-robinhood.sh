#!/usr/bin/env bash
# Verify a contract on Robinhood Blockscout (cloudflare blocks forge's UA, so we curl with a browser UA)
# and on Sourcify. Usage: script/verify-robinhood.sh <address> <path/File.sol:Name> [0x<constructor-args>]
set -euo pipefail

ADDR=$1
CONTRACT=$2
ARGS=${3:-}
NAME=${CONTRACT##*:}
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
BS="https://robinhoodchain.blockscout.com"

echo "-> sourcify"
forge verify-contract "$ADDR" "$CONTRACT" --verifier sourcify --chain-id 4663 || true

echo "-> blockscout (standard-json)"
forge verify-contract "$ADDR" "$CONTRACT" --show-standard-json-input > /tmp/verify-stdjson.json
if [[ -n "$ARGS" ]]; then
  ARGFLAGS=(-F "constructor_args=$ARGS")
else
  ARGFLAGS=(-F "autodetect_constructor_args=true")
fi
curl -s -A "$UA" -X POST "$BS/api/v2/smart-contracts/$ADDR/verification/via/standard-input" \
  -F "compiler_version=v0.8.23+commit.f704f362" \
  -F "contract_name=$NAME" \
  -F "license_type=mit" \
  "${ARGFLAGS[@]}" \
  -F "files[0]=@/tmp/verify-stdjson.json;type=application/json"
echo

sleep 10
curl -s -A "$UA" "$BS/api/v2/smart-contracts/$ADDR" | python3 -c "
import json, sys
r = json.load(sys.stdin)
print('blockscout verified:', r.get('is_verified'), '| name:', r.get('name'))
"

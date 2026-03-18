#!/usr/bin/env bash
set -euo pipefail

NODE_VERSION="$(ls "$HOME/.nvm/versions/node" | sort -V | tail -1)"
export PATH="$HOME/.nvm/versions/node/$NODE_VERSION/bin:$PATH"

OPENAI_API_KEY="none" \
OPENAI_API_BASE="http://localhost:10000/v1" \
node ./docs-test/docs-mcp-server/dist/index.js --host 0.0.0.0 --config ./docs-config.yaml

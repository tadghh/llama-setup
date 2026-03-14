#!/usr/bin/env bash
set -euo pipefail

OPENAI_API_KEY="none" \
OPENAI_API_BASE="http://localhost:10001/v1" \
npx @arabold/docs-mcp-server@latest --host 0.0.0.0 --config ./docs-config.yaml

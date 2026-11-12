#!/bin/sh
set -eu

workflows=/project/workflows
marker=/home/node/.n8n/marketing-workflows.sha256

mkdir -p /data/packages /data/reviews
test -w /data
if [ "${MOCK_LLM:-true}" = false ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo 'Set ANTHROPIC_API_KEY when MOCK_LLM=false.' >&2
    exit 1
fi

checksum=$(sha256sum "$workflows/error-handler.json" "$workflows/marketing-brief.json")
if [ ! -f "$marker" ] || [ "$(cat "$marker")" != "$checksum" ]; then
    n8n import:workflow --input="$workflows/error-handler.json"
    n8n import:workflow --input="$workflows/marketing-brief.json"
    n8n publish:workflow --id=MarketingErrors1
    n8n publish:workflow --id=MarketingBrief01
    printf '%s\n' "$checksum" > "$marker"
fi

exec n8n start

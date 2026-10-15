#!/bin/bash
# Live smoke test of the Groq chat cleanup (requires GROQ_API_KEY env var).
set -euo pipefail
: "${GROQ_API_KEY:?Set GROQ_API_KEY to run this smoke test}"
curl -sS https://api.groq.com/openai/v1/chat/completions \
  -H "Authorization: Bearer $GROQ_API_KEY" -H "Content-Type: application/json" \
  -d '{"model":"openai/gpt-oss-120b","temperature":0.2,"reasoning_effort":"low","include_reasoning":false,"messages":[
    {"role":"system","content":"You clean up raw dictation. Remove fillers. Output only the cleaned text."},
    {"role":"user","content":"um so basically I was like thinking we should uh ship the thing on you know friday"}
  ]}' | python3 -c "import json,sys; print(json.load(sys.stdin)['choices'][0]['message']['content'])"

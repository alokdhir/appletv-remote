#!/usr/bin/env bash
# Crush PreToolUse hook: rewrite bash commands through `rtk rewrite`
# to cut LLM token usage on common dev commands (git, ls, grep, tests, etc.).
#
# Behavior:
#   - If rtk is missing or has no rewrite for the command, emit {} and let it run as-is.
#   - If rtk returns a rewrite, shallow-merge `updated_input.command` so Crush
#     runs the compact version. Permission flow is unchanged (no auto-allow).
#   - Project extension: rtk has no native xcodebuild proxy, so wrap
#     xcodebuild build/test invocations in `rtk err` / `rtk test` for the
#     same failures-only filtering rtk applies to swift/cargo/etc.
set -uo pipefail

emit_noop()    { echo '{}'; exit 0; }
emit_rewrite() { jq -cn --arg c "$1" '{updated_input: {command: $c}}'; exit 0; }

# rtk not installed — graceful no-op.
command -v rtk >/dev/null 2>&1 || emit_noop

cmd="${CRUSH_TOOL_INPUT_COMMAND:-}"

# Fall back to stdin JSON if env var isn't set.
if [[ -z "$cmd" ]]; then
  payload="$(cat || true)"
  if [[ -n "$payload" ]]; then
    cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
  fi
fi

[[ -z "$cmd" ]] && emit_noop

# Don't double-wrap commands the agent already prefixed with rtk.
if [[ "$cmd" =~ ^[[:space:]]*rtk([[:space:]]|$) ]]; then
  emit_noop
fi

# rtk 0.40 exits 3 when a rewrite is produced and 1 when none; the contract we
# rely on is "non-empty stdout means use it".
rewritten="$(rtk rewrite "$cmd" 2>/dev/null || true)"
rewritten="${rewritten%$'\n'}"

if [[ -n "$rewritten" && "$rewritten" != "$cmd" ]]; then
  emit_rewrite "$rewritten"
fi

# rtk has no native xcodebuild proxy. Wrap build/test invocations so output
# is filtered to failures/errors only. Introspection invocations
# (`-showBuildSettings`, `-list`, `-version`, etc.) produce structured data
# we want intact, so we leave them alone.
if [[ "$cmd" =~ ^[[:space:]]*xcodebuild([[:space:]]|$) ]]; then
  read -r -a __tokens <<< "$cmd"
  __has_test=0; __has_build=0
  for t in "${__tokens[@]}"; do
    case "$t" in
      test|test-without-building|build-for-testing) __has_test=1 ;;
      -only-testing:*|-skip-testing:*)              __has_test=1 ;;
      build|clean|archive|analyze|install)          __has_build=1 ;;
    esac
  done
  if   (( __has_test  )); then emit_rewrite "rtk test $cmd"
  elif (( __has_build )); then emit_rewrite "rtk err $cmd"
  fi
fi

emit_noop

#!/usr/bin/env bash
# UserPromptSubmit hook: stdout is added to the agent's context for this prompt.
cat <<'MSG'
[AGENTS.md maintenance] If this message contains a durable instruction, preference, decision, constraint or piece of feedback (a correction OR something the user liked), record it in /AGENTS.md before you finish: add a dated one-line entry under the matching section, rewrite or remove any entry it supersedes, and keep the file concise. One-off task requests that don't change how to work are not recorded.
MSG

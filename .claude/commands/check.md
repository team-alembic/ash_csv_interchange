---
description: Run the full local quality suite (format, credo, doctor, sobelow, dialyzer, tests, docs)
---

Run `mix check` and report results concisely.

If anything fails:
1. Group failures by tool.
2. For each group, show the minimal excerpt that identifies the root cause.
3. Propose fixes; do not apply them unless I ask.

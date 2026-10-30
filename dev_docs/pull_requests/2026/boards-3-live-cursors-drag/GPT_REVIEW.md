# GPT review — PR #3

Reviewer: Codex (OpenAI) · 2026-10-30  
Author: @alexdont · Merge: `4bad16a` · Reviewed against current `4187308`.

## BUG — HIGH, with PR #9: channel access outlives board access

The original signed token was valid for 24 hours regardless of whether the
associated page was still authorized. Once PR #9 added private boards and host
access rules, disconnecting a former viewer's LiveView alone could leave its
independent cursor/moving/drawing channel active.

Tokens now include the issuing LiveView PID. BoardChannel monitors that process
and stops when it ends, including across cluster nodes. BoardSocket rejects
tokens without a page PID. The client reuses an identical offer but replaces the
channel when a remount supplies a new token. During a rolling upgrade, old
tokens are refused and the existing LiveView fallback remains available until
the page obtains a new token.

Tests verify token claims, monitor-driven channel shutdown, and executable
client connection replacement. Existing cursor interpolation, drag, ghost,
reconnect-buffering, delta and preferences tests remain green. The private-board
revocation and durable event checks are documented under PR #9.

Validation: full suite and gate results are in PR #9's GPT review. No real
multi-node deployment or browser was exercised.

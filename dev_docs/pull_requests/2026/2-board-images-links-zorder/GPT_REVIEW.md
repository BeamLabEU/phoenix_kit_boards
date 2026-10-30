# GPT review — PR #2

Reviewer: Codex (OpenAI) · 2026-10-30  
Author: @alexdont · Merge: `a636904` · Reviewed against current `4187308`.

## BUG — HIGH: DNS rebinding bypasses the link-preview address check

The guard validated a DNS response, but Req then connected by hostname and
resolved it again. A hostname could answer with a public address during the
check and a private address during connection. This was documented as an
admin-only limitation; PR #9 exposes unfurling to ordinary authenticated board
users, making that rationale obsolete.

Fixed the common page/hero fetch path to connect to the validated IP. HTTP Host
and TLS hostname verification/SNI retain the original hostname, and relative
redirects resolve against the original URL. Every redirect is still validated;
automatic redirects remain disabled and streaming body caps remain in place.
No rasterizer dependency was added. Corrected the obsolete dependency comment
that suggested the host needed one.

Tests cover nonstandard HTTPS authority/path/query preservation and a real TCP
request to a supplied address with an intentionally unresolvable hostname,
verifying the original Host header arrives. Existing SSRF, metadata, SVG,
image-upload and z-order tests remain green. IPv6-only destinations remain
refused by the existing IPv4-only resolver.

Validation: full suite and gate results are in PR #9's GPT review.

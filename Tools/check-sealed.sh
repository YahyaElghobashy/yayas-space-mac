#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint
#
# Sealed-fork guard: the app may make exactly one kind of outbound request, a
# read-only HTTPS GET to api.github.com, and only from
# Sources/Vorssaint/Services/Update/UpdateService.swift through the wrapper in
# Sources/Vorssaint/Sealed/NetworkPolicy.swift. Any other use of a networking
# API anywhere under Sources/ fails this script, so a rebase onto upstream
# that brings a network path back cannot go unnoticed.
#
# Usage: Tools/check-sealed.sh   (exit 0 = sealed, 1 = a forbidden call site)
set -euo pipefail
cd "$(dirname "$0")/.."

ALLOWED=(
    "Sources/Vorssaint/Sealed/NetworkPolicy.swift"
    "Sources/Vorssaint/Services/Update/UpdateService.swift"
)

# Networking APIs that must not appear outside the allowed files.
FORBIDDEN_API='URLSession|URLRequest|dataTask\(|downloadTask\(|uploadTask\(|NWConnection|NWListener|CFStream|CFReadStreamCreate|CFWriteStreamCreate|NSURLConnection|CFHTTPMessage|CFSocket|NSStream|InputStream\(url|Network\.NW|WKWebView|SecureTransport|getaddrinfo|CFHost'
# Shell tools that would fetch or push over the network when spawned: matched
# as an executable path or a quoted command literal, so ordinary prose (and
# non-ASCII words that happen to contain "nc") never trips it.
FORBIDDEN_TOOLS='"(/usr/bin/|/bin/|/usr/local/bin/|/opt/homebrew/bin/)?(curl|wget|ssh|scp|sftp|rsync|nc|ncat|netcat)"|\b(curl|wget|ssh|scp|sftp|rsync|ncat|netcat) -[A-Za-z]|\bsoftwareupdate --|openssl s_client'

sealed_rc=0

hits="$(grep -rnE "$FORBIDDEN_API" Sources \
    --include='*.swift' --include='*.c' --include='*.h' --include='*.m' --include='*.pl' \
    | grep -vE '^\s*[^:]+:[0-9]+:\s*//' || true)"
for f in "${ALLOWED[@]}"; do
    hits="$(print -r -- "$hits" | grep -v "^$f:" || true)"
done
if [[ -n "$hits" ]]; then
    echo "✗ networking API outside the sealed update path:" >&2
    print -r -- "$hits" >&2
    sealed_rc=1
fi

# Even inside the allowed files, only the sealed wrapper may own a session.
owner_hits="$(grep -nE 'URLSession(\.shared|\()' Sources/Vorssaint/Services/Update/UpdateService.swift || true)"
if [[ -n "$owner_hits" ]]; then
    echo "✗ UpdateService must go through SealedURLSession, not URLSession directly:" >&2
    print -r -- "$owner_hits" >&2
    sealed_rc=1
fi

tool_hits="$(grep -rnE "$FORBIDDEN_TOOLS" Sources --include='*.swift' --include='*.pl' \
    | grep -vE '^\s*[^:]+:[0-9]+:\s*//' || true)"
if [[ -n "$tool_hits" ]]; then
    echo "✗ network-capable shell tool referenced under Sources/:" >&2
    print -r -- "$tool_hits" >&2
    sealed_rc=1
fi

# Every remote host literal in Sources/ must be api.github.com, github.com
# (release page / About links) or one of the About/social links that only
# open in the browser on a click.
host_hits="$(grep -rhoE 'https?://[A-Za-z0-9.-]+' Sources --include='*.swift' | sort -u \
    | grep -vE '^https://(api\.github\.com|github\.com|vorssaint\.com|buymeacoffee\.com|discord\.gg|x\.com|example\.invalid)$' || true)"
if [[ -n "$host_hits" ]]; then
    echo "✗ unexpected remote host literal under Sources/:" >&2
    print -r -- "$host_hits" >&2
    sealed_rc=1
fi

if (( sealed_rc == 0 )); then
    echo "✓ sealed: the only network call site is the api.github.com update GET"
fi
exit $sealed_rc

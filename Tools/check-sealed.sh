#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint
#
# Sealed-fork guard. Every outbound request the app makes is a read-only
# HTTPS GET through the wrapper in Sources/YayasSpace/Sealed/NetworkPolicy.swift
# (SealedURLSession), which refuses any host outside NetworkPolicy.allowedHosts:
#
#   api.github.com                 update check + upstream inspiration (Services/Update/UpdateService.swift)
#   itunes.apple.com               App Store lookup    (Services/AppUpdates/AppUpdatesService.swift)
#   uclient-api.itunes.apple.com   App Store lookup    (Services/AppUpdates/AppUpdatesService.swift)
#   formulae.brew.sh               cask catalog        (Services/AppUpdates/AppUpdatesService.swift)
#
# plus one per-call exception: the radial menu "Fetch Website Icon" button
# (Services/RadialMenu/RadialMenuSupport.swift) fetches /favicon.ico from
# exactly the host the person typed through SealedURLSession.get(_:allowingHost:).
#
# Any other use of a networking API under Sources/ fails this script, as does
# a URLSession owned anywhere but the wrapper, a network-capable shell tool,
# or a remote host literal outside the list above. The speed-test row runs
# Apple's /usr/bin/networkQuality as a local Process; that exact path is the
# only tool spawn allowed to reach the network.
#
# Usage: Tools/check-sealed.sh   (exit 0 = sealed, 1 = a forbidden call site)
set -euo pipefail
cd "$(dirname "$0")/.."

WRAPPER="Sources/YayasSpace/Sealed/NetworkPolicy.swift"
# Files that may build a URLRequest / read an HTTPURLResponse — each must hand
# the request to SealedURLSession (checked below).
CALL_SITES=(
    "Sources/YayasSpace/Services/Update/UpdateService.swift"
    "Sources/YayasSpace/Services/AppUpdates/AppUpdatesService.swift"
    "Sources/YayasSpace/Services/RadialMenu/RadialMenuSupport.swift"
)
ALLOWED=("$WRAPPER" "${CALL_SITES[@]}")

# Networking APIs that must not appear outside the allowed files.
FORBIDDEN_API='URLSession|URLRequest|HTTPURLResponse|dataTask\(|downloadTask\(|uploadTask\(|NWConnection|NWListener|CFStream|CFReadStreamCreate|CFWriteStreamCreate|NSURLConnection|CFHTTPMessage|CFSocket|NSStream|InputStream\(url|Network\.NW|WKWebView|SecureTransport|getaddrinfo|CFHost'
# Shell tools that would fetch or push over the network when spawned: matched
# as an executable path or a quoted command literal, so ordinary prose (and
# non-ASCII words that happen to contain "nc") never trips it. networkQuality
# is in the list; the one exact path literal below is exempted.
FORBIDDEN_TOOLS='"(/usr/bin/|/bin/|/usr/local/bin/|/opt/homebrew/bin/)?(curl|wget|ssh|scp|sftp|rsync|nc|ncat|netcat|networkQuality)"|\b(curl|wget|ssh|scp|sftp|rsync|ncat|netcat|networkQuality) -[A-Za-z]|\bsoftwareupdate --|openssl s_client'
ALLOWED_TOOL_LITERAL='"/usr/bin/networkQuality"'

sealed_rc=0

hits="$(grep -rnE "$FORBIDDEN_API" Sources \
    --include='*.swift' --include='*.c' --include='*.h' --include='*.m' --include='*.pl' \
    | grep -vE '^\s*[^:]+:[0-9]+:\s*//' || true)"
for f in "${ALLOWED[@]}"; do
    hits="$(print -r -- "$hits" | grep -v "^$f:" || true)"
done
if [[ -n "$hits" ]]; then
    echo "✗ networking API outside the sealed call sites:" >&2
    print -r -- "$hits" >&2
    sealed_rc=1
fi

# Only the wrapper may own a session or create a task: no raw URLSession.shared,
# URLSession(...) or dataTask anywhere else, the call sites included.
owner_hits="$(grep -rnE 'URLSession\.shared|URLSession\(|dataTask\(|downloadTask\(|uploadTask\(' Sources \
    --include='*.swift' | grep -v "^$WRAPPER:" \
    | grep -vE '^\s*[^:]+:[0-9]+:\s*//' || true)"
if [[ -n "$owner_hits" ]]; then
    echo "✗ a URLSession or task is owned outside SealedURLSession:" >&2
    print -r -- "$owner_hits" >&2
    sealed_rc=1
fi

# Every call site that builds a request must hand it to the wrapper.
for f in "${CALL_SITES[@]}"; do
    if ! grep -qE 'SealedURLSession\.get\(' "$f"; then
        echo "✗ $f builds requests but never calls SealedURLSession.get" >&2
        sealed_rc=1
    fi
done

tool_hits="$(grep -rnE "$FORBIDDEN_TOOLS" Sources --include='*.swift' --include='*.pl' \
    | grep -vE '^\s*[^:]+:[0-9]+:\s*//' \
    | grep -vF "$ALLOWED_TOOL_LITERAL" || true)"
if [[ -n "$tool_hits" ]]; then
    echo "✗ network-capable shell tool referenced under Sources/:" >&2
    print -r -- "$tool_hits" >&2
    sealed_rc=1
fi

# Every remote host literal in Sources/ must be one of the allowed API hosts
# or github.com (release pages, the repository and the upstream project,
# which only open in the browser on a click). Yaya's Space carries no
# donation, chat or social links.
host_hits="$(grep -rhoE 'https?://[A-Za-z0-9.-]+' Sources --include='*.swift' | sort -u \
    | grep -vE '^https://(api\.github\.com|itunes\.apple\.com|uclient-api\.itunes\.apple\.com|formulae\.brew\.sh|github\.com|example\.invalid)$' || true)"
if [[ -n "$host_hits" ]]; then
    echo "✗ unexpected remote host literal under Sources/:" >&2
    print -r -- "$host_hits" >&2
    sealed_rc=1
fi

# Paths that were removed on purpose and must not come back with a rebase:
# Homebrew analytics (popularity), publisher (Sparkle) feeds, the upload and
# feedback endpoints, the in-app speed test.
removed_hits="$(grep -rnE 'formulae\.brew\.sh/api/analytics|SUFeedURL|latest-mac\.yml|screenshots\.vorssaint\.com|speed\.cloudflare\.com|buymeacoffee\.com|discord\.gg|x\.com/|AppUpdateFeedLoader|AppUpdateFeedSupport' Sources \
    --include='*.swift' | grep -vE '^\s*[^:]+:[0-9]+:\s*//' || true)"
if [[ -n "$removed_hits" ]]; then
    echo "✗ a removed network path is referenced again:" >&2
    print -r -- "$removed_hits" >&2
    sealed_rc=1
fi

# The update check must target this fork's repository and read the upstream
# project only as inspiration (no other repository, no download URL).
UPDATE_SERVICE="Sources/YayasSpace/Services/Update/UpdateService.swift"
for repo in "YahyaElghobashy/yayas-space-mac" "vorssaint/vorssaint-utils"; do
    if ! grep -qF "\"$repo\"" "$UPDATE_SERVICE"; then
        echo "✗ $repo missing from UpdateService" >&2
        sealed_rc=1
    fi
done
if grep -qE 'releases/download|downloadTask\(|NSWorkspace\.shared\.open\(.*dmg' "$UPDATE_SERVICE"; then
    echo "✗ UpdateService references a download path" >&2
    sealed_rc=1
fi

# The allowlist in code must match this script's expectations exactly.
for host in api.github.com itunes.apple.com uclient-api.itunes.apple.com formulae.brew.sh; do
    if ! grep -qF "\"$host\"" "$WRAPPER"; then
        echo "✗ $host missing from NetworkPolicy.allowedHosts" >&2
        sealed_rc=1
    fi
done

if (( sealed_rc == 0 )); then
    echo "✓ sealed: every request goes through SealedURLSession to api.github.com, itunes.apple.com, uclient-api.itunes.apple.com or formulae.brew.sh (plus the one-click favicon host)"
fi
exit $sealed_rc

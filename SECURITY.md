# Security

Yaya's Space is a personal, single-maintainer fork. There is no bug bounty and
no promised response time, but reports are read.

## Reporting

Please keep vulnerabilities out of public issues. Open a private report at
<https://github.com/YahyaElghobashy/yayas-space-mac/security/advisories/new>
with the version from Settings, About, your macOS version and steps to
reproduce.

## Scope

The app runs locally and makes only read-only HTTPS GETs to the four hosts
listed in the README's network policy (`Sources/YayasSpace/Sealed/NetworkPolicy.swift`),
plus one per-click favicon fetch. The reports that matter most are anything
that lets the app reach another host, send data, or misuse a granted
permission. Issues in GitHub's or Apple's services are best taken to them.

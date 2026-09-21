# Privacy

Yaya's Space is local-first and sealed. Everything it shows you, from CPU and
memory load to temperatures, battery, network rates, the window list, per-app
volume and the files on the Shelf, is read through native macOS APIs and
displayed on your Mac. Nothing is logged remotely, uploaded or shared.

## What never happens

- No telemetry, crash reports, analytics, ad networks or device identifiers.
- No account, cloud dashboard or feedback endpoint.
- No uploads of any kind. The upstream "Create link" actions for screenshots
  and recordings were removed at the source; a "Share…" button opens the
  macOS share sheet on the local file instead, and macOS does the sending.
- No auto-install. An available update is a notice with a link; you rebuild
  from source to adopt it.

## Network connections

Every request goes through one wrapper, `SealedURLSession`, which refuses
anything that is not a body-less HTTPS GET to one of these hosts:

1. **`api.github.com`**: the update check for this repository's releases and
   the read-only "upstream inspiration" check of the upstream project's latest
   release. The request carries a standard user agent with the app name and
   version; no identifier or usage data. Both run a short while after launch
   and hourly while the app is open, and both stop when "Check for updates
   automatically" is off in Settings, About.
2. **`itunes.apple.com`** and **`uclient-api.itunes.apple.com`**: App Updates
   asks the App Store for the current version of installed store apps, by
   bundle id or store id. Apple sees your public IP address and the ids asked
   about.
3. **`formulae.brew.sh`**: App Updates reads the public Homebrew cask catalog
   (`/api/cask.json`) to match installed apps. Homebrew's analytics endpoint
   is not used.

Plus one per-click exception: the radial menu's "Fetch Website Icon" button
asks for `/favicon.ico` on exactly the host you typed, for that click only.

Homebrew actions in the Homebrew manager run the local `brew` command, which
contacts Homebrew, GitHub and package vendors on its own terms. The speed test
row runs Apple's `/usr/bin/networkQuality` or opens Speedtest.app; the app
measures nothing itself.

That is the entire list. `Tools/check-sealed.sh` scans the sources for any
other networking API, network-capable tool or remote host and fails if one
appears.

## Local storage

Preferences, saved state, Recent Captures (up to 12 screenshots within 256 MB)
and the private caches live under the app's own identifier,
`com.yahyaelghobashy.yayasspace`, on your Mac. `Tools/uninstall.sh` removes
all of it.

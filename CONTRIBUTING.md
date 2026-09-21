# Contributing to Yaya's Space

Thanks for the interest. This project aims to stay small, native and readable.

## License for contributions

Unless it is stated otherwise, contributions to this repository are accepted
under GPL-3.0-or-later.

## Getting started

```sh
git clone https://github.com/YahyaElghobashy/yayas-space-mac.git
cd yayas-space-mac
./build.sh --dev                   # → dist/Yaya's Space (Developer).app, signed ad hoc
./build/YayasSpaceDeveloper --selftest   # quick health check (SELFTEST OK)
./Tools/check-sealed.sh            # the network guard must stay green
```

You need macOS 14 or newer, Apple Silicon and the Xcode Command Line Tools. The
build is a plain `swiftc` invocation, see `build.sh`, with no Xcode project and
no external dependencies, reproducible by design. `Package.swift` is there so
SwiftPM aware editors can index the code.

Hitting a build or permission snag while developing? See the
[troubleshooting guide](docs/TROUBLESHOOTING.md).

### Stable signing

By default `build.sh` signs ad hoc, and that code hash changes on every build.
macOS ties Accessibility and Screen Recording grants to the hash, so each
rebuild silently orphans them: System Settings keeps showing the app as
granted, the app is no longer trusted, and no new prompt appears. Builds that
install (`--dev` or `--install`) therefore create a free, self signed identity
called `Yaya's Space Signing` in a dedicated keychain automatically when no
identity is installed. For a build you do not install, run the same setup once
yourself:

```sh
./Tools/setup-signing.sh
```

Either way `build.sh` then signs local builds with it and gives them a
constant designated requirement, so granted permissions stick across rebuilds.
If a permission was granted to an earlier ad-hoc build, clear the stale grant
once (`tccutil reset Accessibility com.yahyaelghobashy.yayasspace.dev`) and grant it
again. The identity is a local convenience only and never shows up outside
the keychain.

There is no notarized release channel: Yaya's Space is built from source by
the person using it. `build.sh` still prefers a Developer ID identity if one is
installed, then the self-signed one, then ad hoc.

## Project layout

| Folder | Role |
|---|---|
| `Sources/YayasSpace/App` | App lifecycle and the menu bar status item |
| `Sources/YayasSpace/Core` | Localization, permissions, UserDefaults keys |
| `Sources/YayasSpace/Services` | All behavior, like energy, monitor, scroll and switcher |
| `Sources/YayasSpace/UI` | SwiftUI views only, no business logic |
| `Sources/YayasSpace/Support` | `--selftest` and `--sensors` diagnostics |
| `Tools` | Icon generator and DMG packaging |

A few conventions to keep in mind.

- **UI observes services, and services never import SwiftUI.** Keep that boundary.
- Singletons are exposed as `Type.shared` and publish state with Combine through
  `ObservableObject`, with no Observation macros, since the project builds with
  the Command Line Tools.
- Comments explain *why*, not *what*. Keep them rare and useful.
- No new dependencies without talking it over first in an issue.
- Working with an agent? [Contributing with an
  agent](docs/AI-CONTRIBUTIONS.md) is the process that gets that work merged
  here, and it is written to be read by the agent as much as by you.

## Strings and translations

Every user facing string lives in `Core/Localization.swift` as a field of the
`Strings` struct. Adding a field forces **every** supported language to provide
it, and the compiler is the completeness check, so a translation can never
silently fall out of sync.

Yaya's Space ships these locales today: English (US), Português (Brasil),
Türkçe, Русский, Español, Deutsch, Français, Italiano, 日本語, 한국어, 简体中文,
繁體中文（台灣） and 繁體中文（香港）. The non-base translations live in
`Core/Localizations/`. To add a language, add a case to `AppLanguage`, provide
a complete `Strings` catalog and all feature-specific string catalogs, register
the locale in `Resources/Info.plist`, add localized permission prompts under
`Resources/<locale>.lproj/` when needed, and extend the localization coverage
tests.

## Sensors on new chips

Temperature mapping lives in `SystemMonitor.prepareSensorsIfNeeded()`. CPU keys
look like `Tp…` and `Te…`, GPU is `Tg…`, and battery runs from `TB0T` to
`TB2T`. If a new Apple Silicon generation renames the keys, run this

```sh
./build/YayasSpace --sensors
```

and open a PR with the dump and the adjusted prefixes.

## Reporting bugs and requesting features

You do not need to write code to help. Use the issue forms on the
[new issue](https://github.com/YahyaElghobashy/yayas-space-mac/issues/new/choose) page.

- **Bug report.** Include your Yaya's Space version from Settings under About and
  your macOS version, plus clear steps to reproduce. The
  [troubleshooting guide](docs/TROUBLESHOOTING.md) explains what makes a report
  useful.
- **Feature request.** Describe the problem you are trying to solve rather than
  only a specific solution.

For general help and every support channel, see [support](SUPPORT.md).

## Pull requests

1. One topic per PR, with a clear description of the behavior before and after.
2. `./build.sh` must finish without warnings and `--selftest` must pass.
3. New user facing text must land in **every** supported language, since the
   build will not compile until it does.
4. Match the style of the file you are editing.
5. Keep it small. Half of the open pull requests over a thousand added lines
   have been waiting a week or more; nothing under two hundred is waiting at
   all. When a change is large, splitting it moves it faster than explaining
   it does.
6. Settle the direction before writing the code. Scope is the most common
   reason a pull request is turned down here, and an issue costs far less
   than a branch. Four things decide it: what the feature is built on and
   whether that will still be here, what it exposes the project to, what it
   drags in as a runtime dependency and who then carries it when that breaks,
   and how much permanent surface it adds against how many people will ever
   switch it on. Yaya's Space reaches for what macOS almost does; it does not
   grow a subsystem of its own. Intel support, hardcoded integrations with
   particular third-party apps, a plugin system and video downloading have all
   been declined already, and [contributing with an
   agent](docs/AI-CONTRIBUTIONS.md) works the four through with the cases they
   came from.
7. Title it `type(scope): lowercase imperative phrase`, and do not add the PR
   number yourself, since squash merge appends it. Reuse a scope that already
   shows up in `git log --oneline` rather than inventing one, and leave the
   version and environment notes for the description.
8. Leave `CHANGELOG.md` alone. The maintainer writes the entry when merging,
   in the release notes voice and with your credit, so an entry in your branch
   is a conflict with every sibling PR and a wording that gets rewritten
   anyway. Say in the description what a user would notice; the entry is
   written from that.
9. **A pull request that has an issue must link it, written exactly as `Refs
   #123`.** Not `Closes`/`Fixes`, not a bare `#123`, not a sentence about it.
   That one line is the whole tie between the change and the person who
   reported it: the fix-status bot reads it on merge, labels the issue,
   comments again when a release carries the fix, and closes the issue after
   two weeks of silence. A branch that leaves it out drops that report out of
   the track entirely, and nobody finds out until the reporter asks months
   later. `Closes`/`Fixes` fails the other way, closing the report on merge
   when the fix is not on anyone's Mac yet. Several issues means several
   references, each on its own line and each starting with its own `Refs`:
   the bot reads the word and the number as a pair, so `Refs #123, #456`
   reaches #123 and leaves #456 sitting there. When the branch merges, say on
   the issue which part of it this covered and which part it did not. An issue
   here often carries more than one report, and a fix for one of them reads as
   a fix for all of them until somebody says otherwise. The issue itself stays
   open until the person who reported it confirms on a real build.
10. Fix the cause, not the path the report happened to take. A reporter names
    the symptom they hit; the same mistake usually sits in every sibling call
    site. Find the other callers of whatever you are about to change before
    you change it, and name in the description which ones you checked — one
    guard in the shared function is a smaller diff than a guard in each
    caller, and it is the difference between a fix and a fix for one person.
11. Verify on a real Mac, and describe where. Give as much of it as you have:
    the Mac model, the macOS version and build, the display and Spaces
    layout, whether it was a release build or one of your own, and the app
    language if the change touches text. Then say what you could not test.
    Every pull request is run locally before it is merged, on one
    maintainer's hardware, so the gap between your machine and that one is
    the part worth writing down; changes have passed review and then failed
    on a different Mac. Building with a stable signing identity, see above,
    keeps granted permissions across rebuilds and makes this cheap.
12. The pull request template lists the sections a description here usually
    has. Apart from the issue reference, nothing in it is required, and it is
    a prompt rather than a form, so delete what does not apply and write
    prose.
13. A new feature is not ready the day it compiles. Install your own build,
    live with it for a few days, and fix what surfaces. The rough edge you
    only notice on the third day is the one a reviewer cannot find and a user
    will. A fix or a small change does not need that wait; a feature does.
14. Even so, an unfinished branch is welcome. Open it as a **draft** and name
    in the description what is missing or what decision you need. A draft
    says on its own that it is not asking to be merged yet, and it says so
    everywhere the pull request appears.

## Releases

Tag the commit (`git tag v1.1.0`), push the tag and publish a GitHub release
with notes. Releases are source-only; the app's update check reads them from
`api.github.com` and shows a notice. There is no DMG and no signing secret.

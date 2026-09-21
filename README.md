# HEYCliKit

A Swift package that wraps the official [HEY CLI](https://github.com/basecamp/hey-cli) so native Mac apps can read and act on a HEY account. Unofficial and not affiliated with 37signals. HEY is a trademark of 37signals.

Every call goes through the `hey` executable as a child process. The package never talks to app.hey.com directly, never reads the CLI's Keychain item or credentials file, and never stores tokens. Your credentials stay with the CLI.

## What this repository is

This repository holds only the Swift package: the code that runs the `hey` executable the app hands it, decodes its JSON, and streams `hey watch`. It has no user interface and no app specific logic, and it holds one commit per release; [CONTRIBUTING.md](CONTRIBUTING.md) says how a change gets in. The Mac apps built on it, their website and their planning docs live in a separate Tools for HEY repository, which is private for now.

## Status

Early development. The current version is 0.5.0. The API is not stable yet, so pin an exact version and expect breaking changes until 1.0. An exact pin rather than a range, because a `from:` requirement spans everything below the next major, which while the package is at 0.x means every future minor, and a 0.x minor is allowed to break source.

## Requirements

- macOS 15 or later
- A Swift 6 toolchain (Xcode 16 or later)
- A copy of the HEY CLI. The package does not search for one: the app hands it the location of a `hey` executable. Tools for HEY bundle a pinned copy inside the app. The package publishes the CLI version its fixtures were captured from so an app can tell what it was tested against.

## Installation

Add the package to your `Package.swift`:

```swift
.package(url: "https://github.com/Soules-Studio-Ltd/HEYCliKit", exact: "0.5.0")
```

Then depend on the `HEYCliKit` product from your target. In Xcode, use File, Add Package Dependencies with the same URL.

## What it provides

- A client built from the location of a `hey` executable and an account selection, with one operation per CLI command it wraps.
- A runner for `hey <command> --json` that decodes the JSON envelope and maps exit codes, including exit code 3 for signed out.
- Reads: the sign in status, the CLI's version, the mail accounts, a page of postings from any box kind with the cursor that reads the next one, and the Screener with its total count, each decoded into a model of its own.
- Mutations: move postings between boxes, mark them seen or unseen, approve or deny Screener entries.
- An async stream over `hey watch` newline delimited JSON for live updates, covering one or more boxes.
- A login handle the app can start and cancel, and a logout operation.
- A `HEYCliKitTestSupport` product with the captured fixtures, a loader and a scripted fixture client for consumers' tests, with a queue for every operation the client has.

The vocabulary the API uses is defined in [CONTEXT.md](CONTEXT.md). Decisions that are hard to reverse are recorded under [docs/adr](docs/adr).

## Design rules

- Always `--json`. The human readable output is never parsed. Login is the one exception: it runs the CLI's own sign in flow, whose output the package never decodes, and carries neither `--json` nor `--account`.
- Exit code 3 means signed out. The package reports it and never signs in on its own initiative. Login only runs when the app starts it through the login handle.
- The app supplies the executable. The package never searches PATH or Homebrew for one.
- The account selection is fixed when the client is built and passed on every spawn, so a change made in the user's terminal cannot alter what the app shows.
- Mutations are never retried automatically. A failed write is returned to the caller.
- Nothing app specific lives here. No UI, no notifications, no persistence.

## Tests

```bash
swift test
```

Tests run against JSON fixtures captured from the real CLI and shipped in the `HEYCliKitTestSupport` product, in `Sources/HEYCliKitTestSupport/Fixtures`. Read the README in that folder before adding one. Fixtures must be scrubbed of personal data because this repository is public, and after 1.0 their names are part of the public API.

An app's own tests depend on the `HEYCliKitTestSupport` product, read a fixture with `HEYFixtures.data(named:)`, and script a client with `HEYFixtureClient`:

```swift
let fixtureClient = HEYFixtureClient()
try fixtureClient.script(.mailAccounts, fixture: "accounts.json")

let accounts = try await fixtureClient.client.mailAccounts()
```

Each operation has a queue of its own, so a second call can answer differently from the first, and an operation nobody scripted fails instead of answering silently. Scripted bytes go through the package's own envelope decoding and error mapping, so a test sees exactly what the live client would have returned or thrown. An operation a test is not about can be given a repeating answer instead, which answers every call once its queue is empty, and any queued answer, in each of those three spellings, can be held open with `scriptHeld` and released when the test says so. That is how a test reaches the interleaving between two calls in flight: make the held call from a task the test owns, await its invocation, then release and await that task.

An opt in live suite runs the same read only assertions against a real binary when `HEY_CLI_LIVE_EXECUTABLE` names it, and fails if that binary's version differs from the one the fixtures were captured from. It reads only, never a mutation, and every other run skips it. That binary is spawned with the same allowlisted environment every other spawn gets, so a maintainer whose shell exports `HEY_BASE_URL` for a staging host will find the child never sees it: pass it through `environment:` instead.

```bash
HEY_CLI_LIVE_EXECUTABLE=/path/to/hey swift test --filter LiveContractTests
```

## Contributing

Issues are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before proposing a change, and report a vulnerability privately as [SECURITY.md](SECURITY.md) describes, never in a public issue.

## Used by

Tools for HEY, free native Mac apps for HEY users, at toolsforhey.com.

## Licence

MIT. See [LICENSE](LICENSE).

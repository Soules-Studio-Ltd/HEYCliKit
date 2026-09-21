# Contributing

Thank you for looking. HEYCliKit is a small package, and it means to stay small.

## Issues

Issues are welcome for bugs, questions and ideas. For a bug, say which version of the package and which version of the HEY CLI you ran, what you expected and what happened instead. Leave out anything from your mailbox you would not want in public, and never paste a token or a credentials file.

A security problem is not an issue. See [SECURITY.md](SECURITY.md).

## Pull requests

Start with an issue before you open a pull request, and wait for a reply there. The public API is a contract that apps depend on, so a change to it is agreed before any code is written, and a small fix is still easier to review once we agree it is one.

This repository holds one commit per release, so a pull request is never merged here. Once a change is agreed, the maintainer applies your pull request and it ships in the next release, with you credited in the changelog and in the release commit. The pull request is closed when that release is published.

A pull request is ready when:

- `swift test` passes, with no warnings.
- Every change in behaviour comes with tests, written before the code that makes them pass.
- Everything public is documented.
- Any fixture it adds or changes has been scrubbed as the [fixtures README](Sources/HEYCliKitTestSupport/Fixtures/README.md) describes. This repository is public, so a capture that still holds a real address, name, id, cursor or credential instant cannot be accepted.

## Conventions

- Identifiers use American spelling and prose uses British spelling, as [ADR 0007](docs/adr/0007-public-identifiers-are-american-prose-is-british.md) records.
- All text, from doc comments to test display names and documents, is in sentence case and uses no em dashes or en dashes.
- Swift 6 language mode, macOS 15 or later, and Swift Concurrency only, apart from the two exceptions [ADR 0004](docs/adr/0004-blocking-pipe-reads-and-mutex-are-the-concurrency-exceptions.md) records.
- `Package.swift` stays at tools version 6.0, so the package still builds with Xcode 16.
- No third party dependencies.
- Tests use Swift Testing.

## Releases

Each release is one commit in this repository, on top of the previous release, tagged with its bare semver version such as `0.5.0`, and the [changelog](CHANGELOG.md) records what changed. `main` always equals the latest release. A published tag is never moved or deleted: a release that turns out to be wrong is fixed by a new patch version, as [ADR 0008](docs/adr/0008-a-published-tag-never-moves.md) records.

## Design rules

Every change follows the design rules in the [README](README.md#design-rules). In particular, HEY data only ever comes through the `hey` executable the app supplies: nothing calls app.hey.com directly, reads the CLI's Keychain item or credentials file, or stores a token. Nothing signs in on its own initiative, and nothing retries a mutation. Decisions that are hard to reverse are recorded under [docs/adr](docs/adr), and the vocabulary is in [CONTEXT.md](CONTEXT.md).

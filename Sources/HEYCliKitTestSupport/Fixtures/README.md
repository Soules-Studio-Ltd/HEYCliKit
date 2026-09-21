# Fixtures

JSON captured from the real HEY CLI with `--json`. The whole folder is copied into the `HEYCliKitTestSupport` bundle, and every test, in this package and in an app built on it, reads a fixture through `HEYFixtures` by file name. Nothing reaches for a resource bundle itself. After 1.0 these file names are public API, so a rename goes in the changelog.

What ships is what the package covers: the session, mail accounts, the CLI version, box pages, the Screener, mutations, the watch stream, and the failed envelopes behind the error mapping. A fixture earns its place by being read, so add one in the same change as the test that reads it.

## Capturing

Run the command you want to cover and save the raw envelope:

```bash
hey box view Imbox --json > Sources/HEYCliKitTestSupport/Fixtures/imbox.json
```

Name a fixture after what it captures, lower case, words joined with hyphens.

- A successful capture takes the subject of the command, with the subcommand joined on where the subject alone would not be clear: `imbox.json` for `hey box view Imbox`, then `accounts.json`, `boxes.json`, `screener.json`, `version.json`, `auth-status.json`, `screener-approve.json`, `screener-deny.json`.
- A variant of a capture adds what makes it different: `screener-empty.json`, `imbox-page-1.json` and `imbox-page-2.json`.
- A write confirmation carries the `mutation-` prefix: `mutation-move.json`, `mutation-seen.json`.
- A failed envelope carries the `error-` prefix and the meaning it maps to, narrowed when one meaning has more than one shape: `error-auth.json`, `error-usage.json`, `error-network.json`, `error-noninteractive.json`, `error-not-found.json` and `error-not-found-box.json`.
- A watch session carries the `watch-` prefix and what the session shows: `watch-session.ndjson`, `watch-bundle-growth.ndjson`, `watch-idle-imbox.ndjson`.

Anything a test needs that is none of those says plainly what it is. `edge-case-cwd.json` holds one `hey account list` run twice, from a folder carrying a local config and from the home folder, which is the capture behind the rule that every spawn runs from home. `screener-count.txt` is raw output that is not an envelope, for the one test that needs stdout the decoder must reject.

The extension says what the bytes are: `.json` for a single envelope, `.ndjson` for a `hey watch` stream, and `.txt` for output that is not JSON.

## Scrub before committing

This repository is public. Before a fixture is committed, replace every email address, display name, subject, snippet, topic id and account id with obviously fake values, and remove anything you would not paste in a public issue. Files whose name contains `-private` are ignored by git: they stay on the machine that captured them, they are still copied into a local build's bundle, and they can hold an unscrubbed capture while you work.

A cursor counts too, and it is the one a reader's eye slides straight over. A `next_page` value, and the `page=` value inside a `next_history_url`, are base64 of a small JSON object carrying a posting id and the `observed_at` time the page was read, so a cursor left as it was captured publishes a real id and a real timestamp out of the mailbox. Re-encode both copies, which the CLI prints identically, with an id in the fake `1000xx` range the rest of the file uses and with `2026-01-01T00:00:00.000000Z` as the observed time. `FixtureScrubTests` decodes every cursor in this folder and fails on anything else, because naming only the fields a person can read is exactly how three real posting ids survived a scrub once already.

A credential instant counts as well. A token's `expires_at` is replaced with `2026-01-01T00:00:00Z`, and `FixtureScrubTests` fails on any `expires_at` in this folder holding anything else. Other capture timestamps, such as when a posting was active, observed or updated, are kept as captured on purpose: once the ids, names, addresses and subjects are fake, a timestamp identifies nothing, and tests assert the values they were captured with.

## Watch fixtures

- `watch-session.ndjson`: first session on 2026-09-03, with spontaneous `disconnected` and `ready` lines, fresh mail, a topic read elsewhere, own seen and unseen mutations, and the burst from turning bundling on for a contact.
- `watch-bundle-growth.ndjson`: second session on 2026-09-03 started with `--since` six hours back. Fifteen replayed lines with `new: false` before `ready`, then five mails joining an existing bundle (each an `added` with `new: true` on the hidden single posting followed by an `updated` with `new: true` on the bundle row), then one Screener approval into the Imbox (an `added` with `new: true`).
- `watch-idle-imbox.ndjson`: `hey watch --box imbox --json --timeout 75s` on 2026-09-04 with nothing sent: the backlog replay with `new: false`, one bundle `updated` line, then `ready`.

All watch files are plain newline delimited JSON, one CLI line per row, no timestamp prefix.

## Session fixtures

Captured with hey 1.4.0. The signed out ones were captured on 2026-09-05 from a throwaway home folder and config, so the machine's own session was never touched.

- `auth-status.json`: `hey auth status --json` signed in. Exit 0, `authenticated` true, with `expired`, `expires_at`, `auth_type`, `refresh_available` and `storage` beside it.
- `auth-status-signed-out.json`: the same command signed out. Exit 0 and a success envelope again, `authenticated` false, and none of the credential keys, because there are no credentials. This is the one command that answers rather than fails while signed out, which is what makes it the first call an app makes.
- `error-auth.json`: the failed envelope every other command prints while signed out. `hey box view imbox --json`, `hey screener list --json` and `hey account list --json` were each run signed out on 2026-09-05 and all three printed exactly these bytes and exited 3. Note where they printed them: stdout was empty and the envelope came out on stderr.
- `error-noninteractive.json`: byte for byte the same envelope as `error-auth.json`. The captures above reproduce those bytes from ordinary reads run with `HEY_NONINTERACTIVE=1`, so the two files hold one shape and not two. Which command each was originally captured from is not recorded, and no signed out read fixture was added because there would be nothing in it that `error-auth.json` does not already hold.

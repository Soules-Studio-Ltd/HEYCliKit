# HEYCliKit

The language shared by HEYCliKit and the apps built on it. HEYCliKit wraps the official HEY command line interface so a Mac app can read and act on a HEY account, and these are the words the package's public API and its documentation use for what HEY exposes.

## Language

**Posting**:
A row in a box. It stands for one topic or for a bundle of them.
_Avoid_: Thread, box item, message, email

**Topic**:
One conversation in HEY, the thing a posting points at and the Screener holds a sender's first one of.
_Avoid_: Thread, conversation

**Single posting**:
A posting that stands for exactly one topic. The CLI spells this kind `topic`.
_Avoid_: Topic posting, thread row

**Bundle**:
A posting that groups several topics from one contact into one row.
_Avoid_: Bundle posting, group

**Subject**:
What a posting is about: the subject line of its topic, or the bundle's title. The CLI calls it `name`, and the API exposes it as `subject`.
_Avoid_: Name, title, headline

## Boxes

**Box**:
One of the places HEY sorts mail into. A box is identified by its kind, never by its display name or numeric id.
_Avoid_: Folder, mailbox, inbox

**Box kind**:
The stable identifier of a box: `imbox`, `feedbox`, `asidebox`, `laterbox`, `trailbox` or `bubblebox`. Display names are Imbox, The Feed, Set Aside, Reply Later, Paper Trail and Bubble Up.
_Avoid_: Box name, box type

## Spawning

**Child environment**:
What the `hey` child process is handed: a fixed allowlist of the app's own environment, `TMPDIR`, `LANG`, `LC_ALL` and `LC_CTYPE`, with `HOME` and `PATH` pinned rather than copied, then whatever the app passed to the client, then `HEY_NONINTERACTIVE` settled last. Every other variable the app inherited, `HEY_*` included, is dropped, so nothing exported into the user's session can point the CLI at another host or move its credentials. An app that needs a variable passes it explicitly (ADR 0005).
_Avoid_: Process environment, inherited environment, environment overlay

## Limits

**Output ceiling**:
The most bytes the package reads from one stream of one child, 32 MiB: stdout on a one shot command, stderr on any. A child that writes one byte more is terminated and the operation fails as output too large, never with the part that was read.
_Avoid_: Output limit, max output, truncation, cap

**Line ceiling**:
The longest line a watch may print, 64 KiB without its newline. A longer line is dropped whole, the child is terminated and the watch fails as line too large, because a partial line is not a watch line.
_Avoid_: Line limit, max line length, truncated line

**Watch buffer bound**:
How many watch lines are held for an app that has not read them yet, 1024, with a second bound of 4096 raw lines inside the runner behind it. A watch whose reader falls that far behind keeps the lines it already holds, drops the one that did not fit, terminates its child and fails as fallen behind, naming 1024 whichever of the two filled. Nothing is fabricated in place of what was dropped.
_Avoid_: Backpressure, queue size, buffer limit, overflow policy

**Termination escalation**:
What stopping a child means: SIGTERM, a five second grace, then SIGKILL for a child that has still not ended. It bounds how long a child can outlive a cancel, and it is not a timeout: nothing puts a deadline on a call (ADR 0006).
_Avoid_: Timeout, force quit, hard kill, deadline

## CLI output

**Envelope**:
The JSON object every `--json` command prints: `ok`, then either `data` or an `error` with a `code` and an optional `hint`. The package decodes `data` and carries everything else as opaque text, except `meta.total_count`, which the Screener list reads and nothing else does.
_Avoid_: Response, payload, result

## Paging

**Page**:
The postings one box read returns, together with a cursor when more follow.
_Avoid_: Batch, chunk, result set

**Page size**:
How many postings a page holds. HEY serves 30 first and 10 at a time after that, so a page size is 30 or a larger multiple of 10; any other number returns rows with no cursor.
_Avoid_: Limit, count

**Cursor**:
The opaque value a page carries when more postings follow, handed back to read the next page.
_Avoid_: Next page token, offset

## Acting on postings

**Move**:
Sending one or more postings to another box. A move succeeds or fails as a whole and is never retried by the package.
_Avoid_: Archive, file, triage, set aside, reply later (as verbs)

**Mutation**:
Any command that changes HEY: a move, a seen or unseen change, a Screener decision. HEY confirms most mutations with a summary only, so the package returns success or a mapped error and nothing else. A Screener decision is the exception: HEY confirms it with data, and the package returns the decisions.
_Avoid_: Action, write, update, command

## Reading state

**Seen**:
The state of a posting the user has opened. A posting is either seen or unseen; the CLI omits the `seen` key for unseen.
_Avoid_: Read, opened

**Unseen**:
The state of a posting the user has not opened yet.
_Avoid_: New, unread

## Watch

**Watch**:
A long lived CLI process that reports changes to one or more boxes as they happen, one line at a time.
_Avoid_: Subscription, poll, feed, push

**Watch line**:
One element of a watch: a change to a posting (`added`, `updated`, `deleted`), a signal about the watch itself (`ready`, `disconnected`, `resync`), or an unrecognised line the package passes through untouched.
_Avoid_: Event, message, notification

**Resync**:
A watch line saying the box changed faster than the watch could follow, so the caller must re-read that box.
_Avoid_: Refresh, reload

**New mail**:
The flag on a watch line that says the topic is unseen, not muted and active since the watch last looked. It is not the same as unseen.
_Avoid_: New, fresh

**Replayed line**:
A watch line delivered before the first `ready`, describing a change that happened before the watch began. Replayed lines are never new mail.
_Avoid_: Backlog, catch up

## Screener

**Screener**:
HEY's holding area where mail from a first time sender waits until the user decides about the sender.
_Avoid_: Quarantine, pending, spam

**Screener entry**:
One sender waiting in the Screener, together with the first topic they sent. The CLI calls its id a clearance id.
_Avoid_: Sender waiting, clearance, screener item

**Approve**:
The decision to let a Screener entry's sender through, into the Imbox or another box, now and in future.
_Avoid_: Screen in, allow, accept, yes

**Deny**:
The decision to turn a Screener entry's sender away, now and in future.
_Avoid_: Screen out, block, reject, no

**Decision**:
The CLI's confirmation of an approve or a deny, carrying the entry it was about and its outcome. It is what those two operations return.
_Avoid_: Result, receipt

## Accounts

**Mail account**:
One HEY mailbox linked to the signed in user, with a purpose such as home or work. Every posting belongs to one mail account.
_Avoid_: Account, mailbox, profile

**Account selection**:
Which mail accounts a command covers: one mail account, or all of them. The CLI's `all` row is a selection, not a mail account.
_Avoid_: Account filter, active account

## Session

**Signed in**:
The state where the CLI holds valid credentials and commands can reach HEY.
_Avoid_: Logged in, authenticated, authorised

**Signed out**:
The state the CLI reports with exit code 3. The package reports it and never signs in on its own initiative.
_Avoid_: Logged out, not logged in, unauthenticated, auth error

**Login**:
The act, started only by the app, of running the CLI's sign in flow to move from signed out to signed in.
_Avoid_: Auth, authenticate

**Login handle**:
What a started login leaves the app holding: how the sign in ended, and a way to stop it. It never times out.
_Avoid_: Login session, login task, auth handle

**Logout**:
The act, started only by the app, of signing the CLI out, moving it from signed in to signed out.
_Avoid_: Sign off, deauthenticate, revoke

## Testing

**Fixture**:
An envelope or watch stream captured from the real CLI, scrubbed of personal data, and shipped with the package so its tests and its consumers' tests decode the same bytes. Fixture names are part of the public API.
_Avoid_: Mock data, sample, stub

**Private capture**:
An envelope or watch stream captured from the real CLI and not yet scrubbed. It stays on the machine that captured it and never ships, and it becomes a fixture only once every personal value in it has been replaced.
_Avoid_: Raw fixture, private fixture, local capture, unscrubbed fixture

**Fixture client**:
A client whose operations answer from scripted fixtures in a fixed order, so a test can stage what the CLI would have said without spawning it.
_Avoid_: Mock client, stub client, fake CLI

**Held answer**:
A scripted answer that does not resolve until the test releases it, so one call can be left in flight while another runs to completion. Releasing it is what a test does, and nothing else releases it.
_Avoid_: Paused answer, blocked answer, gate

# Login runs through the package, but only when the app asks

The package must never sign in behind the app's back: a signed out result is reported, never prompted for and never retried. The apps still need to start the CLI's login flow, and spawning belongs in one place, so the package exposes an explicit login handle the app starts and can cancel. The rule is narrowed to "never on its own initiative, never as a retry" rather than "never at all".

## Considered options

- Keep login out of the package and have each app spawn `hey auth login` itself. Rejected because it duplicates process handling and spawn rules the package already owns.
- Ship login as a separate product so the read and write client never links it. Rejected as ceremony with no consumer that wants one without the other.

## Addendum: a cancel decides the outcome, the child's ending does not

Cancel is a request. The package sends SIGTERM, and what the child does with it is the CLI's business: it may die on the signal, and hey 1.4.0 does, but it is a Go binary and a build that trapped the signal for a graceful shutdown would exit cleanly instead. A handle that read the exit alone would then report a sign in the user walked away from as completed, which is the one answer it must never give. The package does insist on the process, though not on the outcome: a child that has still not ended once the termination grace has passed is sent SIGKILL (ADR 0006), which bounds how long it can outlive the cancel and changes nothing about how the sign in is reported.

So the handle remembers that cancel was asked for and reports the sign in as not completed whatever ending its child comes to, carrying that ending as it was rather than inventing a signal. The outcome is decided once, so a cancel that arrives after it was decided changes nothing, exactly as signalling a child that has already ended reaches nobody. The app confirms the session with the sign in status afterwards regardless.

Login is also the one command that needs the child's `PATH`: the CLI opens the sign in page with a bare `open` and lets Go search for it, so the four system directories the child environment pins are what lets a sign in reach a browser at all (ADR 0005).

## Addendum: the package classifies why a sign in was not completed

An app wants to know why a sign in was not completed, to say so to the user or to count it in a usage event, and the only place the CLI says why is its stderr, which also carries the sign in address with the machine's install id. Leaving the reading to each app would put knowledge of the CLI's wording in every app and tempt one into sending the stderr itself. So classifying the failure is the package's job, like the rest of what the CLI prints: a not completed sign in carries a kind, timed out, access denied, cancelled or not classified, and only the kind is meant to leave the machine.

The rule sits in the package beside the CLI's words, quoting the lines of the CLI source it depends on and the versions it was checked against. A cancel the app asked for decides the kind as it decides the outcome. Otherwise only an exit 3 is read, and it is read by looking for the envelope's quoted error string in stderr rather than by decoding it, because the CLI logs its progress to stderr before the envelope, so stderr as a whole is not JSON. The quote also keeps the sign in address from ever matching. Anything the rule does not recognise is not classified rather than guessed at, and a CLI that rewords its errors degrades to that, never to a wrong kind.

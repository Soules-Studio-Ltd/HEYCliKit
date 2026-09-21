# Security

## Reporting a vulnerability

Report a vulnerability privately, through GitHub's private vulnerability reporting on this repository: open the Security tab and choose Report a vulnerability. Never report one in a public issue, a pull request or a discussion.

Say what you found, which version it affects and how to reproduce it. You will get a reply there, and the fix and its release are coordinated with you before anything is made public.

## Scope

In scope is the package itself:

- how it starts, reads and stops a `hey` child process, including output and termination handling
- the environment it builds for that child
- anything that could expose a credential or another person's mail

Out of scope are HEY itself and the HEY CLI. Both belong to 37signals, and a problem in either is reported to them. This package is unofficial and not affiliated with 37signals.

## Supported versions

Only the latest release receives security fixes.

# The app supplies the hey executable, the package never searches for it

The apps built on HEYCliKit bundle a pinned copy of the official HEY CLI inside their app bundle, so the package takes the executable location from the caller and has no discovery step: no PATH search, no Homebrew lookup, no version negotiation at runtime. The package publishes the CLI version its fixtures were captured from, and the app decides which binary it ships. This keeps the package small, makes every spawn reproducible, and means a machine without Homebrew behaves exactly like one with it.

## Considered options

- Search PATH and the Homebrew prefix for `hey`, as a CLI wrapper normally would. Rejected because the apps ship their own copy and a stray user install could shadow it with a different version.
- Refuse to run against a CLI version outside a tested range. Rejected because a minor CLI bump usually still decodes and the app must not go dark over it.

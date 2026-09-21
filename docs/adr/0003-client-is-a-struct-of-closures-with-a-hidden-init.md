# The client is a struct of closures whose memberwise init is not public

The public client is a `Sendable` struct with one closure per operation. Consumers get it from two places only: the live constructor that spawns the bundled CLI, and the fixture client in the test support product. The memberwise initialiser stays out of the public API so adding an operation is never a source breaking change, and the process runner underneath is internal with no public escape hatch. It is `package` rather than internal, so the test support product can build a fixture client with it while it remains invisible to consumers.

## Considered options

- A protocol with a live and a fixture conformance. Rejected because faking one operation means conforming to all of them, and every added requirement breaks every conformance outside the package.
- A public memberwise initialiser so apps can assemble their own client. Rejected because it turns every new operation into a major version bump.
- A public process runner protocol as an escape hatch. Rejected because nobody has asked for it and anything public is a contract to maintain.

## Addendum: the closures are package, the surface is one method per operation

The closures are `package` rather than public, and every operation is called through one public method that carries the argument labels and the defaults. The decision above is unchanged: the client is still a Sendable struct of closures behind a package memberwise init, and adding an operation is still additive for an app.

What changed is the spelling an app writes. Public closures gave several operations two spellings, an unlabelled call through the closure and a labelled call through the method that forwarded to it, and they made each operation's exact parameter list public API, so adding an optional parameter to a box read after 1.0 would have been a major bump. One method per operation leaves one spelling and room for a labelled optional parameter that old callers never have to pass.

The stored closures carry an `Operation` suffix because a property cannot share a name with the method that calls it: for an operation with no parameters that is an invalid redeclaration, and where it does compile the property shadows the method everywhere inside the package. The initialiser's parameter labels are unchanged, so the live constructor and the fixture client build a client exactly as before.

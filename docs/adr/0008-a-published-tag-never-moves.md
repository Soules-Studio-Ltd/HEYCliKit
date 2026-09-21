# A published tag never moves

Once a version tag has been pushed, it is never moved to another commit and never deleted, and a tag of the same name is never pushed again. A release that turns out to be wrong, in its code, its documents or its history, is fixed by a new patch version on top of it, and the wrong one stays where it is. This holds for every tag, 0.x included.

The reason is what an app does with a tag. Swift Package Manager records the commit a version resolved to in the app's `Package.resolved`, and an app that builds with `-onlyUsePackageVersionsFromResolvedFile`, as a release build should, checks out exactly that commit. When the tag moves, the commit the lockfile names can disappear from the remote, and from then on every build from a clean derived data folder fails until someone notices, finds out why and takes a new lockfile. An exact version pin does not help, because the pin names the tag and the lockfile names the commit, and moving the tag separates the two. Swift Package Manager also remembers, for each user account, which commit a version tag named the first time it resolved it, and refuses a tag that now names another commit, even while the old commit can still be fetched. Dropping the flag does not help either: a resolve checks out the lockfile's pins before it consults the tag, so the way out is to delete the lockfile, and on any account that resolved the old tag the commit it recorded as well, and take both again. Nothing on the package's side reports any of this: the move is silent, and the failure appears later, in someone else's build.

This was recorded after a tag had been moved once, before the package was public, and its one consumer had to take its lockfile again.

## Considered options

- Allow a tag to move while the package is at 0.x. Rejected. A 0.x tag is pinned exactly for the same reason a 1.x one is, and the lockfile breaks the same way whatever the major version.
- Allow a tag to move when what it builds does not change. Rejected. The lockfile records a commit, not a tree or a product, so identical sources under a new commit still fail to check out.
- Rewrite history if something unpublishable is found in it. Rejected. What has been published cannot be recalled by a rewrite, so it would only break every lockfile without undoing the exposure. The fix is to remove the content in a new commit and, where a credential is involved, to revoke it.
- Were history rewritten anyway, keep the old commits reachable from a spare branch so an old lockfile still resolves. Rejected. It would publish the very history the rewrite set out to remove, and the lockfile would then build the tree that was meant to be gone.

## What it costs

A wrong release stays visible under its tag for ever, and correcting it costs a patch version and a changelog line rather than a quiet fix to the tag. That is cheaper than a broken build in an app nobody here can see.

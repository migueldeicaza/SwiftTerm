# Apps

Host applications and samples that consume SwiftTerm.

## a-Shell (`Apps/a-Shell`)

Git submodule: https://github.com/jiaomeimei0-prog/a-shell  
Pinned to that fork’s `master` (currently identical to upstream `holzschu/a-shell`).

a-Shell is an iOS terminal that embeds a **separate** SwiftTerm checkout via its own submodule (historically `holzschu/SwiftTerm` on a v1.x pin). This tree places the app under the SwiftTerm monorepo for joint work; it does **not** yet retarget a-Shell’s nested SwiftTerm submodule to this parent repository.

### Init

```sh
git submodule update --init Apps/a-Shell
# Optional — only if you need a-Shell’s nested SwiftTerm / cpython pins:
# cd Apps/a-Shell && git submodule update --init SwiftTerm
```

Build instructions remain those of a-Shell (prefer the `a-Shell-noPython` scheme). See `Apps/a-Shell/README.md`.

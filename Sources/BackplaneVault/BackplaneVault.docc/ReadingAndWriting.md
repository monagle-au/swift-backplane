# Reading and Writing

The read path, the locked write path, and the guarantee that
concurrent stores on one file never lose each other's keys.

## Overview

A ``ConfigStore`` composes synchronous, layered reads with
asynchronous, atomically-persisted writes. This article walks
through both paths, then states precisely what is — and is not —
guaranteed when several stores share one file.

## The read path

``ConfigStore/reader`` is a `ConfigReader` composed as follows:

```
ConfigReader
  ├─ EnvironmentVariablesProvider          (highest precedence)
  └─ DecryptingConfigProvider
       └─ MutableInMemoryProvider          (populated from the JSON file)
```

Reads are synchronous and thread-safe. The
``DecryptingConfigProvider`` only invokes decryption for values
flagged as secret — plaintext entries pass through with zero
crypto cost.

Environment-variable precedence preserves deployment-substitution
semantics: an env var override wins over the file-backed value,
exactly as a vanilla `ConfigReader` behaves. Pass
`environmentProvider: nil` at construction to disable the env
layer (useful in tests).

``ConfigStore/secret(forKey:)`` is a convenience equivalent to
`reader.string(forKey:)` that documents the key is expected to
hold a secret; decryption happens transparently either way.

## The write path

All writes are `async`. Each write is a **locked
read-merge-write**:

1. Acquire the file's cross-process ``FileLock``.
2. Re-read the JSON file fresh from disk.
3. Apply the single key change to that fresh state.
4. Write the result atomically (temp file + `rename(2)`) and
   release the lock.
5. Refresh the in-memory provider from the merged result, then
   re-assert the written key with the caller-declared secrecy
   flag.

The in-memory state is deliberately **never** the source of a file
write, so a write can only ever change its own key. Files are
created with `0o600` permissions (owner read + write only), and
pretty-printed with sorted keys so they stay diffable and
hand-editable.

``ConfigStore/setSecret(_:forKey:)`` encrypts *before* the write,
so the in-memory provider holds ciphertext just like the file
does. Plaintext exists only in the `setSecret` argument (briefly,
on the caller's stack) and in the decrypted return value of a read
(briefly, on the reader's stack) — never on disk, never in the
in-memory provider, never in a long-lived heap allocation.

``ConfigStore/remove(key:)`` clears the value from both the
in-memory provider and the file through the same locked merge; the
key is genuinely absent afterwards, not present-as-empty.

## Concurrent stores on one file

Multiple `ConfigStore`s may safely share one file — across
processes (a daemon and an admin CLI, say) and within one process.
Because every write merges into a fresh read of the file under an
exclusive ``FileLock``, a write can never erase keys another store
wrote after this store last loaded.

The guarantee, precisely: **no lost keys**, with per-key
last-writer-wins. It is *not* snapshot isolation and *not*
multi-key transactionality:

- Two writers updating the *same* key resolve to whichever
  committed last.
- Reads serve from this store's in-memory state. Deterministic
  visibility of another store's writes requires
  ``ConfigStore/reload()`` — a local write also refreshes
  opportunistically from the merged file, but only the
  no-destruction property is guaranteed.
- There is no cross-key transaction: each `set` is one
  independently-locked file write, and an interleaved writer may
  land between two `set` calls.

Call ``ConfigStore/reload()`` after known external modifications
(manual edits, CLI commands) to make them visible to reads.
`reload()` takes the same lock as writes, so it can never observe
a concurrent writer's intermediate state.

The rationale for the lock's design — why a sidecar file, why
`flock(2)`, why bounded waiting — is covered in
<doc:FileLocking>.

## Scoping

A store can be sliced into a subtree with
``ConfigStore/scoped(to:)``:

```swift
let root = try ConfigStore(
    filePath: "/var/lib/myapp/config.json",
    scope: "",
    encryption: encryption
)

// Per-feature slice. Reads/writes target keys under "metrics.*"
let metrics = root.scoped(to: "metrics")
try await metrics.set("https://otlp.example", forKey: "endpoint")
// Persists as {"metrics": {"endpoint": "..."}} in the JSON.
```

Scoped stores share the underlying backend: one file, one lock,
one in-memory state. Calling `reload()` on any of them reloads the
file once. The scope prefix is a value-type property, so a scoped
store is cheap to mint and cheap to pass into nested contexts —
different features cannot accidentally read or write each other's
slices unless they explicitly hold a sibling's store.

Dotted keys map to nested JSON objects on disk (`"bridge.ip"`
becomes `{"bridge": {"ip": ...}}`), which keeps files matching how
humans expect to read them.

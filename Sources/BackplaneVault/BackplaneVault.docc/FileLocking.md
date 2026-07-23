# File Locking

Reuse FileLock to protect your own whole-document files against
concurrent writers.

## Overview

``ConfigStore`` uses ``FileLock`` internally to make every write a
locked read-merge-write, but the primitive is public for a reason:
applications often own other whole-document files — device maps,
user registries, pairing records — with the same failure mode.
Two processes (or two independent handles in one process) doing
read-modify-write on the same document will destructively race:
whichever writes last silently erases the other's changes.
`FileLock` packages the locking reasoning so consumers don't have
to rederive it.

## Design, briefly

Each decision is load-bearing:

- **Advisory `flock(2)` on a sidecar file (`<file>.lock`), never
  on the data file.** Atomic writers replace the data file via
  temp file + `rename(2)`, which swaps inodes — a lock held on the
  data file's descriptor would silently stop excluding anyone who
  re-opened the path after the swap. The sidecar's inode is
  stable for the lifetime of the lock.
- **`flock`, not `fcntl(F_SETLK)`.** `flock` locks belong to the
  open file description, so two descriptors in *one* process
  exclude each other — POSIX `fcntl` locks are per-process and
  would silently self-grant. `flock` also dies with its holder, so
  a crashed process can never wedge the file permanently.
- **Bounded, non-blocking acquisition.** Acquisition polls
  `LOCK_EX | LOCK_NB` against a deadline (default 5 seconds, 10 ms
  interval) with `Task.sleep` between attempts — no thread is
  parked in a blocking syscall, and a wedged holder produces a
  descriptive ``FileLockError/timedOut(lockFilePath:timeout:)``
  instead of hanging every writer forever.
- **The sidecar is never deleted.** Removing a lock file while
  another process is opening it hands out locks on two different
  inodes, reintroducing the exact race the lock prevents. An empty
  leftover `.lock` file is normal; leave it alone.

## Protecting a consumer-owned document

Hold the lock across the entire read-modify-write, and write the
data file atomically while the lock is held:

```swift
import BackplaneVault
import Foundation

func addUser(_ user: User, at path: String) async throws {
    let lock = try await FileLock.acquire(forProtecting: path)
    defer { lock.release() }

    // Read fresh state *under the lock* — never a cached copy.
    let url = URL(fileURLWithPath: path)
    var registry = try loadRegistry(from: url)   // your decode
    registry.users.append(user)

    let data = try JSONEncoder().encode(registry)
    try data.write(to: url, options: .atomic)
}
```

The pattern that makes the guarantee hold is the same one
``ConfigStore`` uses: re-read the document *after* acquiring the
lock, apply the change to that fresh state, write atomically,
release. Reading before acquisition (or writing from a cached
snapshot) reintroduces the lost-update race the lock exists to
prevent.

For synchronous contexts,
``FileLock/acquireBlocking(forProtecting:timeout:)`` parks the
calling thread for at most the timeout instead of suspending.

``FileLock/lockFilePath(forProtecting:)`` exposes the sidecar
naming convention (`<file>.lock`), and the
``FileLock/acquire(lockFilePath:timeout:)`` variant accepts an
explicit lock path — useful when one lock must guard an invariant
spanning several files.

## Single-key JSON merges

For tooling that just needs to set one key in a
`ConfigStore`-format JSON file without constructing a store,
``ConfigWriter/merge(key:value:filePath:lockTimeout:)`` performs
the whole locked read-merge-write in one call — same lock, same
guarantee, so it composes safely with live stores on the same
file.

## When acquisition times out

``FileLockError/timedOut(lockFilePath:timeout:)`` means another
holder kept the lock past the deadline. That holder is either
legitimately slow — retry, or raise the `timeout` parameter — or
wedged, in which case stop the wedged process and retry. Do not
delete the `.lock` file: it does not go stale (a crashed holder's
lock is released by the kernel automatically), and removing it
undermines every other process currently using it.

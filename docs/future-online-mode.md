# Future Online Mode — design notes (NOT implemented)

**Status: documentation only.** Version 1 has no network access at all: no
`INTERNET` permission on Android, no networking code on iOS, no backend, no
accounts, no catalog client, no downloads, no sync. Nothing described here
exists in the apps.

## 1. What an online mode could offer

- Discovery of curated HolyC programs and games.
- Author information, descriptions, compatibility notes, source previews.
- Optional downloads into a local workspace.
- Community submissions, ratings, recommendations.
- Optional synchronization of the user's own projects.

## 2. Possible architecture

```text
Curated online program catalog (server, not built)
              │  HTTPS, pinned, metadata first
              ▼
Authenticated metadata / source retrieval
              │
              ▼
Package validation (size, format, hash/signature, manifest)
              │
              ▼
User reviews source, provenance and requested capabilities
              │
              ▼
Restricted local workspace on the virtual drive (C:/Downloaded/<id>/)
              │
              ▼
The same sandboxed HolyC interpreter used for everything else
```

The client side of this pipeline would reuse the V1 pieces: catalog-style
program records with stable ids and provenance fields, `LayeredFs` for the
workspace, and the interpreter's memory/time limits. The download step must
end in the same import path as Developer Mode (`future-developer-mode.md`),
never in a separate "trusted" execution path.

## 3. Independently controllable features

These must stay separately switchable so each can ship (or not) on its own:

| Feature | Requires network | Executes third-party code |
|---|---|---|
| Local import (Developer Mode) | no | yes |
| Read-only online documentation / news | yes | no |
| Online catalog with source previews only | yes | no |
| Online catalog with downloads | yes | yes |
| Project sync | yes | no (own code) |

A first online step could, for example, be read-only educational content with
no executable downloads.

## 4. Governance and security questions to answer first

- Platform policies on downloaded executable content (Apple App Review
  Guidelines 2.5.2 / 4.7, Google Play Device and Network Abuse policy) —
  re-read at the time; approval is not assumed.
- Authorship and licensing of submitted programs; TempleOS originals are
  public domain, community programs may not be.
- Moderation, abuse reporting, takedown, and content removal from devices.
- Integrity: package signatures or hashes, source-to-package consistency.
- Compatibility validation and versioning of programs.
- Transport security, privacy policy, data minimization, account deletion if
  accounts ever exist.
- Child safety and community rules.

A future online library must not become an unrestricted software installation
system: everything it delivers is HolyC source run in the interpreter sandbox
with the limits in `security-model.md`, plus the per-program capability
enforcement that Developer Mode would add.

## 5. What V1 deliberately does not contain

- No HTTP client, socket code, or networking dependency.
- No analytics, crash-reporting SDK or remote configuration.
- No login, account, or token storage.
- No catalog UI placeholders or disabled "coming soon" menu entries.
- No server code in this repository.

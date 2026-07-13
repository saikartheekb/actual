---
category: Enhancements
authors: [saikartheekb]
---

Migrated the sync server from native modules (`better-sqlite3`, `argon2`, and `bcrypt`) to Node.js built-in `node:sqlite` and pure-JS `hash-wasm`/`bcryptjs`. This removes the need for native build tooling on the target device, making it possible to run the sync server on Termux/Android and other constrained environments.

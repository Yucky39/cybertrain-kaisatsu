# cybertrain-kaisatsu

Authentication library (改札) for [CyberTrain](https://github.com/saeki-mototsune/CyberTrain).

Status: pre-alpha. See [docs/design.md](docs/design.md) and [docs/install.md](docs/install.md).

- Password hashing: PBKDF2-HMAC-SHA256 (600,000 iterations, about 0.5 s under Spinel), self-describing stored form, rehash on login.
- Server-side sessions: the cookie holds only a random id; ending a session takes effect at once.
- One-time tokens (password reset, e-mail confirmation): digest-only storage, single-use, expiring.
- Sign-in throttling in the database, same answer for a wrong password and an unknown account.
- E-mail confirmation (the link only shows a button; opening it confirms nothing) — reset links go only to confirmed addresses.
- Password reset by e-mail: one-time link, throttled requests, same answer for any address; mail goes out over cybertrain-postal through a spool and a separate worker (`--postal`).
- `kaisatsu install` adds all of it to a cybertrain application.

## License

MIT

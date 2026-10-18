# cybertrain-kaisatsu

Authentication library (改札) for [CyberTrain](https://github.com/saeki-mototsune/CyberTrain).

Status: pre-alpha. See [docs/design.md](docs/design.md) and [docs/install.md](docs/install.md).

- Password hashing: PBKDF2-HMAC-SHA256 (600,000 iterations, about 0.5 s under Spinel), self-describing stored form, rehash on login.
- Server-side sessions: the cookie holds only a random id; ending a session takes effect at once.
- One-time tokens (password reset, e-mail confirmation): digest-only storage, single-use, expiring.
- Sign-in throttling in the database, same answer for a wrong password and an unknown account.
- `kaisatsu install` adds all of it to a cybertrain application.

## License

MIT

# cybertrain-kaisatsu

Authentication for [CyberTrain](https://github.com/saeki-mototsune/CyberTrain) applications, written for [Spinel](https://github.com/matz/spinel). 改札 (*kaisatsu*) is the ticket gate: it decides who gets through.

**Status: pre-alpha.** It works end to end in generated applications (see "What is checked"), but the API may still change and it has not had a security review.

It adds sign-up, sign-in, sign-out, e-mail confirmation, password reset and address change to a CyberTrain application, as plain generated Ruby that you own and can edit. There is no runtime magic: CyberTrain applications cannot use `eval`, `send` or `method_missing`, and neither does this library.

## Requirements

- CyberTrain v0.3.1 with the Spinel it pins (2026.10.27.7020, installed by `cybertrain setup`). The library's tests also pass on Spinel 2026.09.12 with CyberTrain v0.2.1, which this was first written against.
- Ruby 3.2 or later for the `kaisatsu` generator command (the application itself never runs on CRuby).
- For sending mail: [cybertrain-postal](https://github.com/Yucky39/cybertrain-postal), and OpenSSL headers to build its worker (see "Sending mail").

## Quick start

```sh
cybertrain new myapp && cd myapp
ruby /path/to/cybertrain-kaisatsu/exe/kaisatsu install
cybertrain db migrate
cybertrain server
```

Then open `/signup` and `/login`. Protect a controller with one line:

```ruby
class PostsController < ApplicationController
  before_action :require_login   # not signed in: redirected to /login

  def index
    @owner = current_user_id     # the signed-in user's id, a String
  end
end
```

`kaisatsu install` writes migrations, a `User` model, controllers, views and routes, and makes small, repeatable edits to `spin.toml`, `config/app.rb`, `ApplicationController` and `config/routes.rb`. It never overwrites an existing file. Everything it creates is listed in [docs/install.md](docs/install.md).

## What you get

| | |
| --- | --- |
| **Passwords** | PBKDF2-HMAC-SHA256, 600,000 iterations (about 0.5 s under Spinel). The stored form carries its parameters, so raising the count later re-hashes at the next sign-in. 8 to 1024 bytes, no NUL. |
| **Sessions** | The cookie holds only a random id; the database holds its digest. Signing out, or changing a password or an address, ends sessions on the server at once, and a forged cookie grants nothing. Fourteen days. |
| **Sign-in limits** | 5 failures from one address against one account, 50 against one account from all addresses, and 20 from one address, in 15 minutes, then HTTP 429. Sign-up is limited to 10 tries per address in 15 minutes. Expired counters, sessions and tokens are swept on sign-in. A wrong password and an unknown account get the same answer and take the same time. |
| **E-mail confirmation** | A link valid for three days. Opening it only shows a button; pressing the button confirms. |
| **Password reset** | A one-hour, single-use link, sent only to a confirmed address. The answer is the same for any address; requests are limited per account and per address. A weak new password does not spend the link; success ends every session. |
| **Changing the address** | Needs the current password. A link goes to the *new* address and a notice to the old one. On confirming, every session and every outstanding link ends. An address already in use looks like success and sends nothing. |
| **Tokens** | 256 bits, stored only as a SHA-256 digest, single-use, expiring. |

Reset, confirmation and change links are built from `KAISATSU_BASE_URL`, never from the request's `Host` header.

## Sending mail

Without options, mail is printed to the log, which is for development only (a link is a secret). To send real mail:

```sh
ruby /path/to/cybertrain-kaisatsu/exe/kaisatsu install --postal
```

The web application only writes each message to a spool directory; a separate program, `bin/mail_worker.rb`, sends it over SMTP (STARTTLS required by default), retrying with backoff. They are separate on purpose: with CyberTrain v0.2.1 a binary that links OpenSSL cannot run the web server (every request fails), and SMTP over TLS needs OpenSSL. CyberTrain v0.3.1 fixed that ([CyberTrain#27](https://github.com/saeki-mototsune/CyberTrain/issues/27)); sending from the web binary then works too (put `require "openssl"` first in `config/app.rb`, see [docs/m2-notes.md](docs/m2-notes.md)), but the separate worker remains the default. The settings, and how to run the worker, are in [docs/install.md](docs/install.md).

## What is checked

- `spin test` runs the library's own tests under Spinel: password hashing against known answers, tokens, the database-backed stores, sign-in, reset, confirmation and address change, and a `SessionStore` → `Gate` → `Router` chain driven through cookies. `script/check-installer` (CRuby) checks the generator.
- Generated applications were driven end to end with `curl` against a real server and [Mailpit](https://github.com/axllent/mailpit): sign-up, wrong passwords, throttling, sign-out and replay of the old cookie, the mailed links, and each of the flows above.
- SQLite-backed tests cannot run under CRuby, so their snapshots come from the compiled binary (`script/regen-snapshot test/<name>.rb`).

## Known limits

- CyberTrain has no hook for adding middleware, so the session check runs from a `before_action` in `ApplicationController` (`Gate.resolve`).
- No two-factor authentication, passkeys, OAuth or roles yet.
- Unicode normalisation of passwords is not applied; the bytes are used as given.
- Two Spinel / CyberTrain problems found while building this were reported upstream and are fixed in CyberTrain v0.3.1: class-variable arrays sharing storage after a GC in the test harness ([#1](https://github.com/Yucky39/cybertrain-kaisatsu/issues/1), [CyberTrain#26](https://github.com/saeki-mototsune/CyberTrain/issues/26)), and `require "openssl"` breaking the web server ([#2](https://github.com/Yucky39/cybertrain-kaisatsu/issues/2), [CyberTrain#27](https://github.com/saeki-mototsune/CyberTrain/issues/27)).
- The request log of CyberTrain contains the path of a mailed link (`/password/reset/<token>`). Tokens are single-use and expire, but treat the log as sensitive.
- Behind a reverse proxy on the same machine, set `CYBERTRAIN_TRUSTED_PROXY=1` (see [docs/install.md](docs/install.md)). Without it every visitor shares the proxy's address in the sign-in limits, and one person's failed attempts can lock everyone out.
- Five failed sign-ins from one address lock that address out of that account for 15 minutes; 50 from all addresses together lock the account itself, so a determined, widely spread attacker who knows an address can still keep its owner out for a while ([#6](https://github.com/Yucky39/cybertrain-kaisatsu/issues/6)).
- Sign-up answers the same whether or not the address already has an account (the same hash cost, the same message); the owner of an existing address is mailed instead. Form errors that do not depend on other accounts (blank address, weak password) are still shown, and sign-up is limited to ten tries per address in 15 minutes.
- Without `--postal`, mail is only printed to the log, links included. With `--postal`, `KAISATSU_MAIL_FROM` must be set when `CYBERTRAIN_ENV=production`; the first mail is refused with an error otherwise, instead of being printed.
- Who is signed in is looked up in the database on every request and kept for that request only; it is not copied into the cookie. A controller that does not run the generated `before_action` sees nobody signed in.
- After an email change, the old address (if it was confirmed) gets a link that undoes it for a week.
- Mail has only been tried against Mailpit, not a real provider (see cybertrain-postal's Known limits).

## Documentation

Written in Japanese:

- [docs/install.md](docs/install.md): what the generator writes, settings, how each flow works.
- [docs/design.md](docs/design.md): the original design notes.
- [docs/m0-findings.md](docs/m0-findings.md), [docs/m2-notes.md](docs/m2-notes.md): measurements and the Spinel pitfalls met on the way.

## Development

```sh
export PATH=$HOME/.cybertrain/spinel/2026.10.27.7020/bin:$PATH   # after `cybertrain setup`
spin test                       # the library's tests, under Spinel
ruby script/check-installer     # the generator, under CRuby
```

## License

MIT

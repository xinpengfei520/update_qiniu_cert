# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single Bash script (`update_qiniu_cert.sh`) that auto-renews a Let's Encrypt SSL cert via `certbot` and uploads it to Qiniu CDN through Qiniu's SSL cert API. Intended to run daily via cron on a Linux server.

## Dependencies

The script requires these CLI tools (checked at startup in `main()`): `certbot`, `jq`, `curl`, `openssl`, `xxd`, and `docker`.

## Configuration

Config is **hardcoded at the top of the script** (no `.env` file): `QINIU_ACCESS_KEY`, `QINIU_SECRET_KEY`, `DOMAIN`, `CERT_ID_FILE`, `LOG_FILE`, `NGINX_CONTAINER_NAME`. These placeholders must be edited before deploying. The certbot email is derived as `admin@$DOMAIN`, and the renewal threshold (10 days / `864000` seconds) is hardcoded — both require editing the script to change.

## Key behaviors and gotchas

- **Docker nginx is stopped/started around certbot.** The script runs `certbot --standalone`, which needs port 80, so it `docker stop`s the nginx container, renews, then `docker start`s it. A `trap ... EXIT` guarantees nginx restarts even on failure. Don't remove this without providing another way to free port 80.
- **Cert ID is tracked in an external file** (`$CERT_ID_FILE`). On a missing file the script rediscovers the cert by querying Qiniu's cert list and filtering by domain; if still not found, it generates a fresh cert.
- **Qiniu auth is a custom HMAC-SHA1 signature** (not AWS SigV4 or standard OAuth), built inline. Format: `Qiniu <ACCESS_KEY>:<base64-signature>`. Be careful when touching the signing logic — it's easy to break.
- **Cross-platform date handling:** `format_timestamp()` branches on macOS (`date -r`) vs Linux (`date -d @`). Preserve both branches.
- **Verbose logging leaks secrets:** logs include full auth headers and signing strings. Treat `$LOG_FILE` as sensitive; don't add it to git or paste its contents.

## Git conventions

No conventions — commits go directly to `master` with free-form messages.

---
name: docker-nginx-ssl
description: Add Let's Encrypt HTTPS to a site served by an nginx container in docker compose, using certbot webroot validation and an automated renewal cron. Use when asked to set up SSL/TLS/HTTPS, install a certificate, fix a "not secure" warning, or move a dockerized site from port 80 to 443.
---

# Dockerized nginx + Let's Encrypt SSL

Terminate TLS in the existing nginx container. No snap, no host certbot, no
second web server.

## When NOT to use this

- **nginx runs on the host, not in a container** — use `certbot --nginx` from
  snap instead. It edits the config and reloads for you.
- **Nothing is on port 80 yet** — `certbot certonly --standalone` is simpler.
- **Port 80 is unreachable from the internet** (provider firewall, ISP block,
  internal-only host) — HTTP-01 validation is impossible. Use DNS-01
  (`--preferred-challenges dns` plus the plugin for the DNS provider).
- **The stack is small and the config is thin** — replacing nginx with
  `caddy:alpine` gives automatic certs and renewal in ~4 lines of Caddyfile.
  Fewer moving parts than everything below. Offer this first.

## Phase 1 — Verify before touching anything

Do not skip. Each of these has silently wasted a full setup attempt.

```bash
dig +short example.com
curl -s ifconfig.me
```

These must match. Then confirm port 80 is reachable **from outside the host**,
not just from `localhost` — a provider firewall or security group in front of
the VPS is invisible to `ufw status`. Have the user run `curl -I http://example.com/`
from their own machine.

```bash
sudo ss -tlnp | grep -E ':(80|443)\s'
```

443 must be free. 80 is expected to be held by the nginx container's
docker-proxy.

Then read the actual config before proposing edits:

```bash
cat nginx/nginx.conf
cat nginx/sites-available/*
```

Two things decide the whole plan:

1. Does `nginx.conf` contain `include /etc/nginx/sites-enabled/*;` inside
   `http { }`? Without it, new site files are never loaded and nothing you do
   has any effect.
2. What already answers on `listen 80`? You extend that server block. You do
   not add a competing one.

## Phase 2 — Compose

Add 443 and two volumes to the nginx service only:

```yaml
  nginx:
      ports:
          - "80:80"
          - "443:443"
      volumes:
          - ./certbot/conf:/etc/letsencrypt
          - ./certbot/www:/var/www/certbot
```

```bash
mkdir -p certbot/conf certbot/www certbot/logs
sudo docker compose up -d nginx
```

**`nginx -s reload` does not apply new ports or volumes.** Only a recreate
does. If the ACME challenge 404s later, this is almost always why — verify
with:

```bash
sudo docker inspect naamii_nginx --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'
```

Changing `ports:` recreates the container. For nginx that is a few seconds of
downtime and nothing else. Do not opportunistically edit other services'
`ports:` in the same pass — that recreates databases and is a separate
decision the user must make deliberately.

## Phase 3 — ACME path only

Add to the **existing** `listen 80` server block, above `location / {`:

```nginx
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
```

No redirect yet. The site keeps serving exactly as before, so a mistake here
costs nothing.

```bash
sudo docker exec naamii_nginx nginx -t && sudo docker exec naamii_nginx nginx -s reload
```

Prove the path works before spending a rate limit:

```bash
cd /path/to/deployment
mkdir -p certbot/www/.well-known/acme-challenge
echo hello | sudo tee certbot/www/.well-known/acme-challenge/test
curl http://example.com/.well-known/acme-challenge/test
```

Must print `hello`. Run this from the deployment root — running it from a
subdirectory creates a second stray `certbot/` tree and the file lands
somewhere nginx never looks.

## Phase 4 — Issue

Always `--dry-run` first. Let's Encrypt allows 5 failures per hostname per
hour; a dry run is what keeps a typo from costing an hour.

```bash
sudo docker run --rm \
  -v /path/to/deployment/certbot/conf:/etc/letsencrypt \
  -v /path/to/deployment/certbot/www:/var/www/certbot \
  -v /path/to/deployment/certbot/logs:/var/log/letsencrypt \
  certbot/certbot certonly --webroot -w /var/www/certbot \
  -d example.com --email admin@example.com \
  --agree-tos --no-eff-email --dry-run
```

Mount the logs directory. With `--rm` and no mount, `letsencrypt.log` is
destroyed on every run and failures cannot be diagnosed.

On success, rerun the identical command **without** `--dry-run`. Confirm:

```bash
sudo ls certbot/conf/live/example.com/
sudo rm certbot/www/.well-known/acme-challenge/test
```

## Phase 5 — TLS server block

Only now add the redirect and the 443 block. Mirror the existing `location`
blocks exactly — do not invent new ones, and do not consolidate specific
`/static/foo` prefixes into a blanket `location /static/`. Frontend build
assets under `/static/js` and `/static/css` usually live inside the app
container and must fall through to the proxy.

```nginx
server {
    listen       80;
    server_name  example.com;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen       443 ssl;
    server_name  example.com;

    ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

    add_header Content-Security-Policy "upgrade-insecure-requests";

    location / {
        proxy_pass  http://webapp;
        proxy_set_header    Host              $host;
        proxy_set_header    X-Real-IP         $remote_addr;
        proxy_set_header    X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header    X-Forwarded-Proto https;
    }

    location /api {
        proxy_pass   http://backend;
        proxy_set_header    Host              $host;
        proxy_set_header    X-Real-IP         $remote_addr;
        proxy_set_header    X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header    X-Forwarded-Proto https;
        proxy_http_version  1.1;
        proxy_set_header    Upgrade           $http_upgrade;
        proxy_set_header    Connection        $connection_upgrade;
    }
}
```

The ACME location stays in the port-80 block **permanently**. Renewal needs
it every 60 days.

`$connection_upgrade` requires a map in `nginx.conf` inside `http { }`:

```nginx
    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }
```

Add `X-Forwarded-Proto https` to every proxy block, or the backend generates
`http://` URLs and redirect loops follow.

Settings already global in `nginx.conf` — `client_max_body_size`, timeouts,
`upstream` definitions — are inherited. Do not repeat them.

```bash
sudo docker exec naamii_nginx nginx -t && sudo docker exec naamii_nginx nginx -s reload
curl -I http://example.com/
curl -I https://example.com/
```

Expect 301 then 200.

## Phase 6 — Renewal

```
0 3 * * 1 /usr/bin/docker run --rm -v /path/to/deployment/certbot/conf:/etc/letsencrypt -v /path/to/deployment/certbot/www:/var/www/certbot -v /path/to/deployment/certbot/logs:/var/log/letsencrypt certbot/certbot renew --quiet && /usr/bin/docker exec naamii_nginx nginx -s reload
```

Use absolute binary paths — cron's PATH is minimal. Verify with `which docker`.

Then verify renewal now, not in 60 days:

```bash
sudo docker run --rm \
  -v /path/to/deployment/certbot/conf:/etc/letsencrypt \
  -v /path/to/deployment/certbot/www:/var/www/certbot \
  -v /path/to/deployment/certbot/logs:/var/log/letsencrypt \
  certbot/certbot renew --dry-run --no-random-sleep-on-renew -v
```

## Phase 7 — Verify in a browser

`curl -I` proves the index page and the cert chain. It proves nothing about
the app. Have the user log in, exercise a real write action, and watch the
devtools Console and Network tabs — that is where a misrouted `/api`, a
missing websocket upgrade, or a mixed-content block appears.

Expect the mixed-content failure below on any SPA whose API base URL was
baked in as absolute `http://`. It is the single most common post-cutover
breakage and it presents as "all the data is gone".

Leave any pre-existing direct port (e.g. `8080:80` on the frontend) published
until this passes. It is the fallback.

## Troubleshooting

**Challenge 404s** — volumes not mounted (reload instead of recreate), or the
file was created from the wrong working directory. Check `docker inspect`
mounts first.

**`renew` hangs ~1-8 minutes with no output** — not a hang. Certbot inserts a
random sleep when it detects no TTY, so cron jobs worldwide do not synchronize.
`docker run` without `-it` looks non-interactive. Add
`--no-random-sleep-on-renew` for manual runs; leave it out of cron, where the
jitter is the point.

**`urn:ietf:params:acme:error:malformed :: authorization must be pending`** —
a previous successful validation left a cached valid authorization (Let's
Encrypt caches these 30 days) and certbot tried to answer its challenge again.
Common after two dry runs in quick succession. Drop the staging account and
retry:

```bash
sudo rm -rf certbot/conf/accounts/acme-staging-v02.api.letsencrypt.org
```

Staging accounts are stored separately from production — this cannot affect
the live certificate.

**App loads but shows no data; console says `blocked ... requested insecure
content` / `Not allowed to request resource` / `XMLHttpRequest cannot load ...
due to access control checks`** — mixed content. The frontend has an absolute
`http://example.com/api/...` base URL compiled in, and the browser refuses to
fetch it from an HTTPS page. Nothing is deleted; the fetch never leaves the
browser. The CORS-sounding line is a downstream artifact of the block, not a
real CORS problem.

Users report this as data loss, not as a TLS problem. Rule out a wipe first if
they are alarmed — logging in successfully proves the user table is intact,
and loading the app on its pre-existing direct port (e.g. `:8080`) bypasses
nginx entirely and settles it in seconds.

Fix with one line at **server level** in the 443 block, not inside a
`location`:

```nginx
    add_header Content-Security-Policy "upgrade-insecure-requests";
```

The browser then rewrites `http://` subresource requests to `https://` before
sending. `add_header` does not inherit into a `location` that declares its own
`add_header`, and the header must be present on the HTML response itself.

Hard-reload afterward; blocked responses may be cached.

The real fix is rebuilding the frontend with a **relative** API base (`/api/v1`),
which works on any scheme and host. That is a change in the app's source, so
treat it as a follow-up — the CSP header holds indefinitely in the meantime.

**Config edits have no effect** — `include /etc/nginx/sites-enabled/*;` is
missing from `nginx.conf`.

**Backups must live outside `sites-available/`.** That directory is globbed by
the `include`, so a `naamii.org.np.bak` is loaded as live config and produces
duplicate server blocks. Use a sibling `config-backups/` directory, or rely on
git.

## Adjacent issue worth raising once

Deployments like this frequently publish `3306`, `27017`, and `6379` on
`0.0.0.0`. Containers reach each other by service name over the compose
network without any `ports:` entry, so those publishes are pure exposure —
and an unauthenticated Mongo on a public IP is found by scanners within hours.

Mention it once, clearly, as separate from the TLS work. Do not bundle the
change in: it recreates database containers, and it is the user's call.

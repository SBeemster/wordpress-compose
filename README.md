# WordPress on Docker — VPS Runbook

WordPress + MariaDB + Redis, served through a **Cloudflare Tunnel** (no exposed host
ports). TLS is terminated at Cloudflare's edge; the stack speaks plain HTTP internally.

## Stack

| Service        | Role |
|----------------|------|
| `wordpress`    | PHP 8.3 / Apache, with `phpredis` + `msmtp` mail relay |
| `db`           | MariaDB 11 |
| `redis`        | Object cache (Redis 7) |
| `mailpit`      | Local email testing (SMTP on :1025, web UI on :8025) |
| `phpmyadmin`   | Database admin UI |
| `cloudflared`  | Cloudflare Tunnel client — the only outbound connection to the internet |
| `backup`       | Nightly `mysqldump` with 14-day rotation |

---

## Prerequisites

- Docker Engine ≥ 26 and Docker Compose v2 on the VPS
- A domain managed by Cloudflare
- A **Cloudflare Zero Trust** account (free tier is fine)

---

## Step 1 — Create the Cloudflare Tunnel

1. Go to **Cloudflare Zero Trust** → **Networks** → **Tunnels** → **Add a tunnel**.
2. Choose **Cloudflared** as the connector type.
3. Give the tunnel a name (e.g. `wordpress-vps`).
4. Copy the **token** shown on the next screen — you will need it in Step 2.

### Add public hostnames (still in the dashboard)

Under your new tunnel's **Public Hostname** tab, add:

| Subdomain / Domain          | Service type | Service URL       |
|-----------------------------|--------------|-------------------|
| `your-domain.example`       | HTTP         | `wordpress:80`    |
| `pma.your-domain.example`   | HTTP         | `phpmyadmin:80`   |
| `mail.your-domain.example`  | HTTP         | `mailpit:8025`    |

> **Tip:** Protect both `pma.` and `mail.` hostnames with **Cloudflare Access**
> policies (Zero Trust → Access → Applications → Add an application → Self-hosted)
> so they are not publicly reachable.

---

## Step 2 — Configure `.env`

```bash
cp .env.example .env
$EDITOR .env
```

Fill in at minimum:

| Variable       | Value |
|----------------|-------|
| `SITE_URL`     | Your full URL, e.g. `https://your-domain.example` |
| `TUNNEL_TOKEN` | The token you copied in Step 1 |

The DB passwords are pre-generated. Feel free to replace them with your own values
before the first `docker compose up`.

---

## Step 3 — Start the stack

```bash
# From /home/beemster/code/wp-docker
docker compose up -d --build
```

Check that everything is healthy:

```bash
docker compose ps
docker compose logs cloudflared   # should show "Registered tunnel connection"
```

---

## Step 4 — WordPress install

Browse to `https://your-domain.example` — you should see the WordPress setup wizard.
Complete the install (site title, admin user, password).

---

## Step 5 — Email testing with Mailpit

All mail sent by WordPress (WooCommerce order notifications, password resets,
etc.) is routed through **msmtp** inside the container to the `mailpit` service.
Nothing leaves your server during development.

### View the inbox

Browse to `https://mail.your-domain.example` (the Cloudflare Tunnel route you
added in Step 1). You will be challenged by Cloudflare Access before seeing the
inbox.

### Send a test email

The quickest way to generate a mail is to trigger a lost-password request on the
WordPress login screen. The email will appear in Mailpit within seconds.

You can also fire one from the CLI:

```bash
docker compose exec wordpress php -r '
  require "/var/www/html/wp-load.php";
  wp_mail("test@example.com", "Test from WordPress", "Hello from msmtp + Mailpit");
  echo "done\n";
'
```

### Verify msmtp is configured correctly

```bash
docker compose exec wordpress cat /etc/msmtprc
# Should show: host mailpit, port 1025, auth off, tls off
```

### Switch to a real mail provider

Edit `.env`, uncomment/fill in the production block, and restart:

```bash
# In .env:
SMTP_HOST=smtp.yourprovider.com
SMTP_PORT=587
SMTP_AUTH=on
SMTP_TLS=on
SMTP_USER=your-smtp-username
SMTP_PASS=your-smtp-password
SMTP_FROM=noreply@your-domain.example

docker compose up -d
# The container re-renders /etc/msmtprc on startup — no image rebuild needed.
```

---

## Step 6 — Enable Redis object cache

1. In the WordPress admin, go to **Plugins → Add New** and search for
   **Redis Object Cache** (by Till Krüss).
2. Install and activate it.
3. Go to **Settings → Redis** and click **Enable Object Cache**.
   Status should change to **Connected**.

Verify from the command line:

```bash
docker compose exec redis redis-cli info keyspace
# After a few page loads you should see: db0:keys=...,expires=...
```

---

## Day-to-day operations

### View logs

```bash
docker compose logs -f wordpress
docker compose logs -f cloudflared
```

### Update images

```bash
docker compose pull          # pull latest upstream images
docker compose up -d --build # rebuild wordpress image + recreate changed services
```

### Restart a single service

```bash
docker compose restart wordpress
```

### Stop the stack

```bash
docker compose down          # keeps volumes (data is safe)
docker compose down -v       # ⚠ also deletes volumes — use only to start fresh
```

---

## Backups

The `backup` service runs `mysqldump` every night at **03:00 UTC** and stores gzipped
dumps in the `db_backups` Docker volume (14-day rotation).

### Trigger a manual backup

```bash
docker compose exec backup /backup.sh
```

### List existing backups

```bash
docker compose run --rm backup ls -lh /backup
```

### Restore from a backup

```bash
# Copy the dump out of the volume
docker compose run --rm backup cat /backup/wordpress_YYYY-MM-DD.sql.gz \
  | gunzip \
  | docker compose exec -T db mysql -u wordpress -p"${MYSQL_PASSWORD}" wordpress
```

---

## File layout

```
.
├── docker-compose.yml          # Service definitions
├── Dockerfile                  # Extends wordpress:php8.3-apache with phpredis + msmtp
├── docker-entrypoint-mail.sh   # Renders /etc/msmtprc from env, then calls stock entrypoint
├── msmtp-sendmail.ini          # PHP conf.d: sendmail_path → msmtp
├── uploads.ini                 # PHP upload / memory limits
├── .env                        # Secrets (not committed)
├── .env.example                # Template committed to version control
├── .gitignore
└── README.md
```

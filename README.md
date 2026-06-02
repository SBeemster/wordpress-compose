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

## Step 7 — WooCommerce shop + Stripe payments

### Install WooCommerce

1. In the WordPress admin, go to **Plugins → Add New** and search for **WooCommerce**.
2. Install and **Activate** it. WooCommerce will run a setup wizard and auto-create
   the Shop, Cart, Checkout, and My Account pages.
3. Go to **Settings → Permalinks**, choose anything other than "Plain" (e.g. **Post
   name**), and click **Save Changes**. WooCommerce requires non-plain permalinks for
   product/checkout URLs to work.
4. Go to **WooCommerce → Status** and confirm there are no PHP requirement warnings.
   (All required extensions — `bcmath`, `exif`, `gd`, `intl`, `mysqli`, `zip`,
   `imagick` — ship with this image.)

### Install the Stripe payment gateway

1. Go to **Plugins → Add New**, search for **WooCommerce Stripe Payment Gateway**
   (by WooCommerce), install, and activate it.
2. Go to **WooCommerce → Settings → Payments → Stripe** and enter your keys.
   Use **test keys** first (publishable key + secret key from the Stripe Dashboard
   → Developers → API keys → Test mode).
3. The plugin shows a **webhook endpoint URL** (something like
   `https://your-domain.example/?wc-api=wc_stripe`). Copy it.
4. In the **Stripe Dashboard → Developers → Webhooks**, click **Add endpoint**,
   paste that URL, and select the events the plugin lists (or choose all events).
5. Copy the **Signing secret** Stripe generates and paste it back into the plugin's
   Webhook Secret field. Save.
6. Place a test order using Stripe's test card **4242 4242 4242 4242** (any future
   expiry, any CVC). The order should complete and you should see the confirmation
   email land in Mailpit.
7. When ready for real payments, swap the test keys for your live keys and register
   a second webhook endpoint pointing at the same URL in live mode.

> **HTTPS / Stripe compatibility**: Cloudflare terminates TLS and the HTTPS shim in
> `WORDPRESS_CONFIG_EXTRA` makes `is_ssl()` return `true`, which the Stripe gateway
> requires. Webhooks (`POST` callbacks from Stripe) arrive through the existing
> Cloudflare Tunnel without any additional routing changes.

> **Fraud signals**: Stripe Radar's primary signals (device fingerprint, IP, browser
> behaviour) are collected **client-side** by Stripe.js directly in the customer's
> browser — these reach Stripe regardless of the tunnel. The `CF-Connecting-IP`
> shim in `wp-config.php` additionally ensures the server-side customer IP recorded
> on each order (and passed as a Radar signal by the plugin) is the genuine visitor
> IP, not the `cloudflared` container's internal IP.

### Optional: real cron for WooCommerce

WooCommerce's Action Scheduler (scheduled emails, order processing) normally
piggybacks on WP-Cron, which only fires when someone visits the site. For reliable
background tasks on a low-traffic shop, disable WP-Cron's page-triggered mode and
run it on a real system cron:

```bash
# Add to crontab on the VPS (runs every 5 minutes):
*/5 * * * * docker compose -f /path/to/wp-docker/docker-compose.yml \
  exec -T wordpress php /var/www/html/wp-cron.php
```

And add to `WORDPRESS_CONFIG_EXTRA` in `docker-compose.yml`:

```php
define('DISABLE_WP_CRON', true);
```

This is optional for first launch but recommended before going live.

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

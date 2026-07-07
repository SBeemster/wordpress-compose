FROM wordpress:php8.3-apache

# Install the phpredis extension so WordPress can use Redis as an object cache.
# The Redis Object Cache plugin will detect this extension automatically.
RUN pecl install redis \
    && docker-php-ext-enable redis \
    && rm -rf /tmp/pear

# Install msmtp as the PHP mail transport so all outgoing mail is routed through an SMTP relay.
# Switch between Mailpit (dev) and a real provider (prod) via .env — no rebuild.
RUN apt-get update \
    && apt-get install -y --no-install-recommends msmtp msmtp-mta curl \
    && rm -rf /var/lib/apt/lists/*

# Tell PHP to hand mail() calls to msmtp.
COPY msmtp-sendmail.ini /usr/local/etc/php/conf.d/zz-msmtp.ini

# Opcache tuning beyond the base image's generic defaults — WP + WooCommerce +
# plugins is a lot of PHP files, and the default max_accelerated_files is too
# low to cache them all.
COPY opcache.ini /usr/local/etc/php/conf.d/zz-opcache.ini

# Wrapper entrypoint: renders /etc/msmtprc from env vars at startup, then
# delegates to the stock WordPress entrypoint so all its initialisation runs.
COPY docker-entrypoint-mail.sh /usr/local/bin/docker-entrypoint-mail.sh
RUN chmod +x /usr/local/bin/docker-entrypoint-mail.sh

ENTRYPOINT ["docker-entrypoint-mail.sh"]
CMD ["apache2-foreground"]

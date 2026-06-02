FROM wordpress:php8.3-apache

# Install the phpredis extension so WordPress can use Redis as an object cache.
# The Redis Object Cache plugin will detect this extension automatically.
RUN pecl install redis \
    && docker-php-ext-enable redis \
    && rm -rf /tmp/pear

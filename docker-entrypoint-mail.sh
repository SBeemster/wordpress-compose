#!/bin/sh
# Render /etc/msmtprc from environment variables, then hand off to the stock
# WordPress docker-entrypoint.sh so all its initialisation still runs.
#
# Dev (Mailpit):  SMTP_HOST=mailpit  SMTP_PORT=1025  SMTP_AUTH=off  SMTP_TLS=off
# Prod (real):    SMTP_HOST=...      SMTP_PORT=587   SMTP_AUTH=on   SMTP_TLS=on
#                 SMTP_USER=...      SMTP_PASS=...
set -e

: "${SMTP_HOST:=mailpit}"
: "${SMTP_PORT:=1025}"
: "${SMTP_AUTH:=off}"
: "${SMTP_TLS:=off}"
: "${SMTP_FROM:=wordpress@localhost}"

{
    echo "defaults"
    echo "logfile -"
    echo ""
    echo "account default"
    echo "host ${SMTP_HOST}"
    echo "port ${SMTP_PORT}"
    echo "from ${SMTP_FROM}"
    echo "auth ${SMTP_AUTH}"
    echo "tls ${SMTP_TLS}"
    if [ "${SMTP_TLS}" = "on" ]; then
        echo "tls_starttls on"
        echo "tls_trust_file /etc/ssl/certs/ca-certificates.crt"
    fi
    if [ "${SMTP_AUTH}" = "on" ]; then
        echo "user ${SMTP_USER}"
        echo "password ${SMTP_PASS}"
    fi
} > /etc/msmtprc
chown root:www-data /etc/msmtprc
chmod 640 /etc/msmtprc

exec docker-entrypoint.sh "$@"

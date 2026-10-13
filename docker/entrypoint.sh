#!/bin/bash
set -e

cd /var/www/html

# Railway injects PORT; Apache must listen on it
PORT="${PORT:-8080}"
sed -ri "s/^Listen .*/Listen ${PORT}/" /etc/apache2/ports.conf
sed -ri "s/<VirtualHost \*:[0-9]+>/<VirtualHost *:${PORT}>/" /etc/apache2/sites-available/000-default.conf

# Fall back to the variables provided by Railway's MySQL plugin
export DB_CONNECTION="${DB_CONNECTION:-mysql}"
export DB_HOST="${DB_HOST:-${MYSQLHOST:-localhost}}"
export DB_PORT="${DB_PORT:-${MYSQLPORT:-3306}}"
export DB_DATABASE="${DB_DATABASE:-${MYSQLDATABASE:-}}"
export DB_USERNAME="${DB_USERNAME:-${MYSQLUSER:-root}}"
export DB_PASSWORD="${DB_PASSWORD:-${MYSQLPASSWORD:-}}"
export DB_PREFIX="${DB_PREFIX:-}"

if [ -z "$APP_KEY" ]; then
    echo "ERROR: APP_KEY is not set. Generate one with:"
    echo "  echo \"base64:\$(openssl rand -base64 32)\""
    echo "and add it to the Railway service variables."
    exit 1
fi

# Storage may be a freshly mounted (empty) volume
mkdir -p \
    storage/app/public \
    storage/app/uploads \
    storage/framework/cache/data \
    storage/framework/sessions \
    storage/framework/views \
    storage/logs \
    bootstrap/cache
chown -R www-data:www-data storage bootstrap/cache

# Wait for the database, then detect an existing installation via the users table
TABLE_EXISTS=$(php -r '
$dsn = sprintf("mysql:host=%s;port=%s;dbname=%s", getenv("DB_HOST"), getenv("DB_PORT"), getenv("DB_DATABASE"));
for ($i = 0; $i < 30; $i++) {
    try {
        $pdo = new PDO($dsn, getenv("DB_USERNAME"), getenv("DB_PASSWORD"));
        $stmt = $pdo->prepare("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = ? AND table_name = ?");
        $stmt->execute([getenv("DB_DATABASE"), getenv("DB_PREFIX") . "users"]);
        echo $stmt->fetchColumn();
        exit(0);
    } catch (Throwable $e) {
        fwrite(STDERR, "Waiting for database: " . $e->getMessage() . PHP_EOL);
        sleep(2);
    }
}
fwrite(STDERR, "Database not reachable" . PHP_EOL);
exit(1);
')

if [ "$TABLE_EXISTS" = "1" ]; then
    echo "Existing installation found, running migrations..."
    export APP_INSTALLED=true
    su -s /bin/bash www-data -c "php artisan migrate --force"
elif [ -n "$ADMIN_EMAIL" ] && [ -n "$ADMIN_PASSWORD" ]; then
    echo "Installing Akaunting..."
    su -s /bin/bash www-data -c "php artisan install \
        --db-host='$DB_HOST' \
        --db-port='$DB_PORT' \
        --db-name='$DB_DATABASE' \
        --db-username='$DB_USERNAME' \
        --db-password='$DB_PASSWORD' \
        --db-prefix='$DB_PREFIX' \
        --company-name='${COMPANY_NAME:-My Company}' \
        --company-email='${COMPANY_EMAIL:-$ADMIN_EMAIL}' \
        --admin-email='$ADMIN_EMAIL' \
        --admin-password='$ADMIN_PASSWORD' \
        --locale='${APP_LOCALE:-en-GB}' \
        --no-interaction"
    export APP_INSTALLED=true
else
    echo "No installation found and ADMIN_EMAIL/ADMIN_PASSWORD not set; the web installer will be shown."
    echo "Note: the web installer writes to .env, which is lost on redeploy. Prefer the env-based install."
fi

su -s /bin/bash www-data -c "php artisan config:clear && php artisan view:clear" || true

exec "$@"

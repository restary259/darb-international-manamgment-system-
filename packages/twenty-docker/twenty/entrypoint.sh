#!/bin/sh
set -e

require_db_config() {
    if [ -z "${PG_DATABASE_URL}" ]; then
        echo "ERROR: PG_DATABASE_URL is not set, cannot run database setup." >&2
        echo "       Twenty reads PG_DATABASE_URL, not DATABASE_URL." >&2
        echo "       Railway: PG_DATABASE_URL=\${{ Postgres.DATABASE_PRIVATE_URL }}" >&2
        exit 1
    fi

    case "${PG_DATABASE_URL}" in
        postgres://* | postgresql://*) ;;
        *)
            echo "ERROR: PG_DATABASE_URL must be a postgres:// or postgresql:// URL." >&2
            exit 1
            ;;
    esac

    if [ -z "${REDIS_URL}" ]; then
        echo "WARNING: REDIS_URL is not set. The server and worker will fail to start." >&2
    fi
}

setup_and_migrate_db() {
    if [ "${DISABLE_DB_MIGRATIONS}" = "true" ]; then
        echo "Database setup and migrations are disabled, skipping..."
        return
    fi

    require_db_config

    echo "Running database setup and migrations..."

    # Run setup and migration scripts
    if ! has_schema=$(psql -tAc "SELECT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'core')" "${PG_DATABASE_URL}"); then
        echo "ERROR: could not query Postgres with the configured PG_DATABASE_URL." >&2
        echo "       Check the database service is running and its host is reachable from this service." >&2
        exit 1
    fi

    if [ "$has_schema" = "f" ]; then
        echo "Database appears to be empty, running migrations."
        yarn database:init:prod
    fi

    if ! yarn command:prod cache:flush; then
        echo "Warning: Failed to flush cache before upgrade, but continuing startup..."
    fi

    if ! yarn command:prod upgrade; then
        echo "Warning: Upgrade completed with errors. Some workspaces may not be fully migrated. Check logs for details."
    fi

    if ! yarn command:prod cache:flush; then
        echo "Warning: Failed to flush cache after upgrade, but continuing startup..."
    fi

    echo "Successfully migrated DB!"
}

register_background_jobs() {
    if [ "${DISABLE_CRON_JOBS_REGISTRATION}" = "true" ]; then
        echo "Cron job registration is disabled, skipping..."
        return
    fi

    echo "Registering background sync jobs..."
    if yarn command:prod cron:register:all; then
        echo "Successfully registered all background sync jobs!"
    else
        echo "Warning: Failed to register background jobs, but continuing startup..."
    fi
}

setup_and_migrate_db
register_background_jobs

# Continue with the original Docker command
exec "$@"

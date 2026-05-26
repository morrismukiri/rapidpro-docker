#!/bin/sh
# Ensures the script exits on any error and prints commands as they're run
set -e
set -x

# Collect static files if enabled
if [ "${MANAGEPY_COLLECTSTATIC:-off}" = "on" ]; then
    /venv/bin/python manage.py collectstatic --noinput --no-post-process
fi

# Clear the compressor cache if enabled
if [ "${CLEAR_COMPRESSOR_CACHE:-off}" = "on" ]; then
    /venv/bin/python clear-compressor-cache.py
fi

# Compress files if enabled (v9 uses .html templates + a dedicated settings module)
if [ "${MANAGEPY_COMPRESS:-off}" = "on" ]; then
    /venv/bin/python manage.py compress --extension=".html" --settings=temba.settings_compress --force -v0
fi

# Initialize the database if enabled
if [ "${MANAGEPY_INIT_DB:-off}" = "on" ]; then
    # Temporarily stop echoing commands to avoid leaking sensitive information
    set +x
    # Configure .pgpass for passwordless PostgreSQL operations
    echo "*:*:*:*:$(echo "$DATABASE_URL" | cut -d'@' -f1 | cut -d':' -f3)" > $HOME/.pgpass
    chmod 0600 $HOME/.pgpass
    set -x
    /venv/bin/python manage.py dbshell < init_db.sql
    rm $HOME/.pgpass
fi

# Run database migrations if enabled
if [ "${MANAGEPY_MIGRATE:-off}" = "on" ]; then
    /venv/bin/python manage.py migrate
fi

# Import GeoJSON files if enabled
if [ "${MANAGEPY_IMPORT_GEOJSON:-off}" = "on" ]; then
    echo "Downloading GeoJSON for relation_ids: $OSM_RELATION_IDS"
    /venv/bin/python manage.py download_geojson $OSM_RELATION_IDS
    /venv/bin/python manage.py import_geojson ./geojson/*.json
    echo "Imported GeoJSON for relation_ids: $OSM_RELATION_IDS"
fi

# Execute the command to start the server or other process
echo "Starting application with command: $STARTUP_CMD"
exec $STARTUP_CMD

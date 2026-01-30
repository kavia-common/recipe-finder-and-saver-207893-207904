#!/bin/bash

# Minimal PostgreSQL startup script with full paths
DB_NAME="myapp"
DB_USER="appuser"
DB_PASSWORD="dbuser123"
DB_PORT="5000"

echo "Starting PostgreSQL setup..."

# Find PostgreSQL version and set paths
PG_VERSION=$(ls /usr/lib/postgresql/ | head -1)
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"

echo "Found PostgreSQL version: ${PG_VERSION}"

# Check if PostgreSQL is already running on the specified port
if sudo -u postgres ${PG_BIN}/pg_isready -p ${DB_PORT} > /dev/null 2>&1; then
    echo "PostgreSQL is already running on port ${DB_PORT}!"
    echo "Database: ${DB_NAME}"
    echo "User: ${DB_USER}"
    echo "Port: ${DB_PORT}"
    echo ""
    echo "To connect to the database, use:"
    echo "psql -h localhost -U ${DB_USER} -d ${DB_NAME} -p ${DB_PORT}"
    
    # Check if connection info file exists
    if [ -f "db_connection.txt" ]; then
        echo "Or use: $(cat db_connection.txt)"
    fi
    
    echo ""
    echo "Script stopped - server already running."
    exit 0
fi

# Also check if there's a PostgreSQL process running (in case pg_isready fails)
if pgrep -f "postgres.*-p ${DB_PORT}" > /dev/null 2>&1; then
    echo "Found existing PostgreSQL process on port ${DB_PORT}"
    echo "Attempting to verify connection..."
    
    # Try to connect and verify the database exists
    if sudo -u postgres ${PG_BIN}/psql -p ${DB_PORT} -d ${DB_NAME} -c '\q' 2>/dev/null; then
        echo "Database ${DB_NAME} is accessible."
        echo "Script stopped - server already running."
        exit 0
    fi
fi

# Initialize PostgreSQL data directory if it doesn't exist
if [ ! -f "/var/lib/postgresql/data/PG_VERSION" ]; then
    echo "Initializing PostgreSQL..."
    sudo -u postgres ${PG_BIN}/initdb -D /var/lib/postgresql/data
fi

# Start PostgreSQL server in background
echo "Starting PostgreSQL server..."
sudo -u postgres ${PG_BIN}/postgres -D /var/lib/postgresql/data -p ${DB_PORT} &

# Wait for PostgreSQL to start
echo "Waiting for PostgreSQL to start..."
sleep 5

# Check if PostgreSQL is running
for i in {1..15}; do
    if sudo -u postgres ${PG_BIN}/pg_isready -p ${DB_PORT} > /dev/null 2>&1; then
        echo "PostgreSQL is ready!"
        break
    fi
    echo "Waiting... ($i/15)"
    sleep 2
done

# Create database and user
echo "Setting up database and user..."
sudo -u postgres ${PG_BIN}/createdb -p ${DB_PORT} ${DB_NAME} 2>/dev/null || echo "Database might already exist"

# Set up user and permissions with proper schema ownership
sudo -u postgres ${PG_BIN}/psql -p ${DB_PORT} -d postgres << EOF
-- Create user if doesn't exist
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
        CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD}';
    END IF;
    ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';
END
\$\$;

-- Grant database-level permissions
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};

-- Connect to the specific database for schema-level permissions
\c ${DB_NAME}

-- For PostgreSQL 15+, we need to handle public schema permissions differently
-- First, grant usage on public schema
GRANT USAGE ON SCHEMA public TO ${DB_USER};

-- Grant CREATE permission on public schema
GRANT CREATE ON SCHEMA public TO ${DB_USER};

-- Make the user owner of all future objects they create in public schema
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TYPES TO ${DB_USER};

-- If you want the user to be able to create objects without restrictions,
-- you can make them the owner of the public schema (optional but effective)
-- ALTER SCHEMA public OWNER TO ${DB_USER};

-- Alternative: Grant all privileges on schema public to the user
GRANT ALL ON SCHEMA public TO ${DB_USER};

-- Ensure the user can work with any existing objects
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO ${DB_USER};
EOF

# Additionally, connect to the specific database to ensure permissions
sudo -u postgres ${PG_BIN}/psql -p ${DB_PORT} -d ${DB_NAME} << EOF
-- Double-check permissions are set correctly in the target database
GRANT ALL ON SCHEMA public TO ${DB_USER};
GRANT CREATE ON SCHEMA public TO ${DB_USER};

-- Show current permissions for debugging
\dn+ public
EOF

# Save connection command to a file
echo "psql postgresql://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}" > db_connection.txt
echo "Connection string saved to db_connection.txt"

# Save environment variables to a file
cat > db_visualizer/postgres.env << EOF
export POSTGRES_URL="postgresql://localhost:${DB_PORT}/${DB_NAME}"
export POSTGRES_USER="${DB_USER}"
export POSTGRES_PASSWORD="${DB_PASSWORD}"
export POSTGRES_DB="${DB_NAME}"
export POSTGRES_PORT="${DB_PORT}"
EOF

echo "PostgreSQL setup complete!"
echo "Database: ${DB_NAME}"
echo "User: ${DB_USER}"
echo "Port: ${DB_PORT}"
echo ""

echo "Applying application schema + seed data (idempotent)..."

# Use the same connection details we write to db_connection.txt.
# (Rule: ALWAYS read connection from db_connection.txt)
DB_CONN="$(cat db_connection.txt)"

# Create tables / constraints / indexes. Keep it idempotent via IF NOT EXISTS.
# Note: each statement is executed in its own psql call, per container rules.
${DB_CONN} -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;"
${DB_CONN} -v ON_ERROR_STOP=1 -c "CREATE TABLE IF NOT EXISTS users (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), email TEXT NOT NULL UNIQUE, password_hash TEXT NOT NULL, display_name TEXT, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now());"
${DB_CONN} -v ON_ERROR_STOP=1 -c "CREATE TABLE IF NOT EXISTS recipes (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), title TEXT NOT NULL, description TEXT, image_url TEXT, source_url TEXT, ingredients JSONB NOT NULL DEFAULT '[]'::jsonb, instructions JSONB NOT NULL DEFAULT '[]'::jsonb, tags TEXT[] NOT NULL DEFAULT ARRAY[]::text[], created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now());"
${DB_CONN} -v ON_ERROR_STOP=1 -c "CREATE TABLE IF NOT EXISTS favorites (user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE, recipe_id UUID NOT NULL REFERENCES recipes(id) ON DELETE CASCADE, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), PRIMARY KEY (user_id, recipe_id));"

# Helpful indexes for common queries
${DB_CONN} -v ON_ERROR_STOP=1 -c "CREATE INDEX IF NOT EXISTS idx_recipes_title_trgm_placeholder ON recipes (title);"
${DB_CONN} -v ON_ERROR_STOP=1 -c "CREATE INDEX IF NOT EXISTS idx_favorites_user_id ON favorites (user_id);"
${DB_CONN} -v ON_ERROR_STOP=1 -c "CREATE INDEX IF NOT EXISTS idx_favorites_recipe_id ON favorites (recipe_id);"

# Seed a few starter recipes (idempotent using a deterministic UUID + ON CONFLICT DO UPDATE).
# We seed recipes only (users/favorites are app-managed).
${DB_CONN} -v ON_ERROR_STOP=1 -c "INSERT INTO recipes (id, title, description, image_url, source_url, ingredients, instructions, tags) VALUES ('00000000-0000-0000-0000-000000000001','Retro Diner Pancakes','Fluffy pancakes like a classic diner breakfast.','https://images.unsplash.com/photo-1528207776546-365bb710ee93','https://example.com/retro-diner-pancakes','[\"2 cups flour\",\"2 tbsp sugar\",\"2 tsp baking powder\",\"1/2 tsp salt\",\"2 eggs\",\"1 3/4 cups milk\",\"3 tbsp melted butter\",\"1 tsp vanilla\"]'::jsonb,'[\"Whisk dry ingredients.\",\"Whisk wet ingredients.\",\"Combine just until mixed.\",\"Cook on a buttered skillet until bubbles form, flip, finish.\"]'::jsonb,ARRAY['breakfast','sweet','quick']) ON CONFLICT (id) DO UPDATE SET title=EXCLUDED.title, description=EXCLUDED.description, image_url=EXCLUDED.image_url, source_url=EXCLUDED.source_url, ingredients=EXCLUDED.ingredients, instructions=EXCLUDED.instructions, tags=EXCLUDED.tags;"
${DB_CONN} -v ON_ERROR_STOP=1 -c "INSERT INTO recipes (id, title, description, image_url, source_url, ingredients, instructions, tags) VALUES ('00000000-0000-0000-0000-000000000002','Neon Nachos','Cheesy nachos with jalapeños and pico—party snack vibes.','https://images.unsplash.com/photo-1541592106381-b31e9677c0e5','https://example.com/neon-nachos','[\"Tortilla chips\",\"2 cups shredded cheese\",\"1/2 cup black beans\",\"1/4 cup pickled jalapeños\",\"Pico de gallo\",\"Sour cream\"]'::jsonb,'[\"Layer chips, beans, and cheese on a sheet pan.\",\"Bake at 425°F (220°C) for 6–8 minutes.\",\"Top with jalapeños, pico, sour cream.\"]'::jsonb,ARRAY['snack','party','vegetarian']) ON CONFLICT (id) DO UPDATE SET title=EXCLUDED.title, description=EXCLUDED.description, image_url=EXCLUDED.image_url, source_url=EXCLUDED.source_url, ingredients=EXCLUDED.ingredients, instructions=EXCLUDED.instructions, tags=EXCLUDED.tags;"
${DB_CONN} -v ON_ERROR_STOP=1 -c "INSERT INTO recipes (id, title, description, image_url, source_url, ingredients, instructions, tags) VALUES ('00000000-0000-0000-0000-000000000003','Synthwave Spaghetti','Garlicky tomato spaghetti with a punchy, bright finish.','https://images.unsplash.com/photo-1521389508051-d7ffb5dc8b21','https://example.com/synthwave-spaghetti','[\"12 oz spaghetti\",\"3 tbsp olive oil\",\"4 cloves garlic\",\"1/2 tsp chili flakes\",\"1 can crushed tomatoes\",\"Salt\",\"Black pepper\",\"Fresh basil\"]'::jsonb,'[\"Boil pasta until al dente.\",\"Sauté garlic in olive oil with chili flakes.\",\"Add tomatoes; simmer 10 minutes.\",\"Toss pasta with sauce; finish with basil.\"]'::jsonb,ARRAY['dinner','pasta','quick']) ON CONFLICT (id) DO UPDATE SET title=EXCLUDED.title, description=EXCLUDED.description, image_url=EXCLUDED.image_url, source_url=EXCLUDED.source_url, ingredients=EXCLUDED.ingredients, instructions=EXCLUDED.instructions, tags=EXCLUDED.tags;"

echo "Schema + seed complete."

echo "Environment variables saved to db_visualizer/postgres.env"
echo "To use with Node.js viewer, run: source db_visualizer/postgres.env"

echo "To connect to the database, use one of the following commands:"
echo "psql -h localhost -U ${DB_USER} -d ${DB_NAME} -p ${DB_PORT}"
echo "$(cat db_connection.txt)"

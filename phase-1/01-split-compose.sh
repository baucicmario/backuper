#!/bin/bash

# ==========================================
# Docker Compose & Env Splitter 
# ==========================================
# Usage: ./split_compose.sh [compose_file] [env_file]

# Get the directory where THIS script lives
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

COMPOSE_INPUT=${1:-docker-compose.yml}
ENV_INPUT=${2:-.env}
OUTPUT_DIR="split_composers"

# 1. Resolve absolute paths so it doesn't matter where the caller script is executing from
COMPOSE_FILE=$(readlink -f "$COMPOSE_INPUT")
ENV_FILE=$(readlink -f "$ENV_INPUT")

# Verify yq is installed globally and working
if ! command -v yq &> /dev/null; then
    echo "Error: 'yq' is missing from the system. Please run your global installer script first."
    exit 1
fi

if [ ! -f "$COMPOSE_FILE" ]; then
    echo "Error: Compose file '$COMPOSE_INPUT' (resolved to '$COMPOSE_FILE') not found."
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

#-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

# 2. Extract Service Names
echo "Analyzing $COMPOSE_FILE..."
SERVICES=$(yq '.services | keys | .[]' "$COMPOSE_FILE")

if [ -z "$SERVICES" ] || [ "$SERVICES" == "null" ]; then
    echo "No services found in $COMPOSE_FILE."
    exit 1
fi

#-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

# 3. Process Each Service
for service in $SERVICES; do
    echo "----------------------------------------"
    echo "Processing service: $service"
    
    TARGET_DIR="$OUTPUT_DIR/$service"
    TARGET_COMPOSE="$TARGET_DIR/docker-compose.yml"
    TARGET_ENV="$TARGET_DIR/.env"
    
    mkdir -p "$TARGET_DIR"
    
    # Extract individual service block and wrap it in 'services'
    yq -n ".services.\"$service\" = load(\"$COMPOSE_FILE\").services.\"$service\"" > "$TARGET_COMPOSE"
    
    # Handle .env Variables
    if [ -f "$ENV_FILE" ]; then
        # Parse the newly created compose file for variable patterns like ${VAR} or $VAR
        USED_VARS=$(grep -oE '\$[{]?[A-Za-z0-9_]+' "$TARGET_COMPOSE" | sed 's/[${}]//g' | sort -u)
        
        if [ -n "$USED_VARS" ]; then
            > "$TARGET_ENV" # Clear/create the target .env file
            
            VARS_FOUND=0
            for var in $USED_VARS; do
                # Extract the exact variable line from the source .env file
                if grep -E "^${var}=" "$ENV_FILE" >> "$TARGET_ENV"; then
                    VARS_FOUND=$((VARS_FOUND + 1))
                fi
            done
            
            if [ $VARS_FOUND -gt 0 ]; then
                echo "  ✓ Created .env ($VARS_FOUND variables extracted)"
            else
                rm "$TARGET_ENV"
                echo "  - No matching variables found in $ENV_FILE for this service."
            fi
        else
            echo "  - No variables required by this service."
        fi
    else
        echo "  - Source env file not found or not provided: $ENV_INPUT"
    fi
    
    echo "  ✓ Saved to $TARGET_COMPOSE"
done

echo "----------------------------------------"
echo "Done! All services have been split into the '$OUTPUT_DIR' directory."
#!/bin/bash

# AI MultiBarcode Capture - Unified Container Startup Script
# This script builds and starts the unified multibarcode-webinterface container

echo "🚀 AI MultiBarcode Capture - Unified Container Startup"
echo "======================================================"

# Load environment variables from .env file
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
    echo "✅ Loaded configuration from .env file"
else
    echo "⚠️  Warning: .env file not found, using default values"
fi

# Set defaults
WEB_PORT=${WEB_PORT:-3500}
EXPOSE_PHPMYADMIN=${EXPOSE_PHPMYADMIN:-false}
EXPOSE_MYSQL=${EXPOSE_MYSQL:-false}

echo ""
echo "📋 Configuration Summary:"
echo "- Container Image: multibarcode-webinterface"
echo "- Web Interface Port: $WEB_PORT"
echo "- phpMyAdmin Access: $([ "$EXPOSE_PHPMYADMIN" = "true" ] && echo "Enabled at /phpmyadmin" || echo "Disabled")"
echo "- MySQL Direct Access: $([ "$EXPOSE_MYSQL" = "true" ] && echo "Internal only" || echo "Internal only")"
echo ""

# Check for SSL certificates and generate if needed
echo "🔒 Checking SSL certificates..."
if [ ! -d "ssl" ]; then
    echo "📁 SSL directory does not exist, creating..."
    mkdir -p ssl
fi

MISSING_CERTS=false
[ ! -f "ssl/wms_ca.crt" ] && MISSING_CERTS=true
[ ! -f "ssl/wms.crt" ] && MISSING_CERTS=true
[ ! -f "ssl/wms.key" ] && MISSING_CERTS=true
[ ! -f "ssl/android_ca_system.pem" ] && MISSING_CERTS=true

if [ "$MISSING_CERTS" = "true" ]; then
    echo "🔑 SSL certificates missing, generating certificates..."
    ./create-certificates.sh
    if [ $? -ne 0 ]; then
        echo "❌ Error: Failed to generate SSL certificates"
        echo "   Please check the certificate generation script and try again"
        exit 1
    fi
    echo "✅ SSL certificates generated successfully"
else
    echo "✅ SSL certificates found"
fi

# Copy CA certificates to web directory for download
echo "📁 Copying CA certificates to web directory..."
mkdir -p "src/certificates"
cp "ssl/wms_ca.crt" "src/certificates/" 2>/dev/null || true
cp "ssl/android_ca_system.pem" "src/certificates/" 2>/dev/null || true
echo "✅ CA certificates copied to web directory"

# Verify all required certificates exist
CERT_ERROR=false
if [ ! -f "ssl/wms_ca.crt" ]; then
    echo "❌ Error: Missing CA certificate: ssl/wms_ca.crt"
    CERT_ERROR=true
fi
if [ ! -f "ssl/wms.crt" ]; then
    echo "❌ Error: Missing server certificate: ssl/wms.crt"
    CERT_ERROR=true
fi
if [ ! -f "ssl/wms.key" ]; then
    echo "❌ Error: Missing server private key: ssl/wms.key"
    CERT_ERROR=true
fi
if [ ! -f "ssl/android_ca_system.pem" ]; then
    echo "❌ Error: Missing Android system certificate: ssl/android_ca_system.pem"
    CERT_ERROR=true
fi

if [ "$CERT_ERROR" = "true" ]; then
    echo "❌ Error: Certificate validation failed - required certificates are missing"
    echo "   Please run ./create-certificates.sh manually to generate certificates"
    exit 1
fi

echo "✅ All required SSL certificates are present"
echo ""

# Check if Docker is running
if ! docker info > /dev/null 2>&1; then
    echo "❌ Error: Docker is not running or not accessible"
    echo "   Please start Docker Desktop and try again"
    exit 1
fi

# Clean up existing WebInterface containers, images, and volumes
echo "🧹 Cleaning up existing WebInterface containers, images, and volumes..."

# Stop and remove container if running
CONTAINER_ID=$(docker ps -aq -f name=multibarcode-webinterface)
if [ ! -z "$CONTAINER_ID" ]; then
    echo "  🛑 Stopping existing container..."
    docker stop multibarcode-webinterface 2>/dev/null || true
    echo "  🗑️ Removing existing container..."
    docker rm multibarcode-webinterface 2>/dev/null || true
fi

# Remove existing volumes
VOLUME_ID=$(docker volume ls -q -f name=multibarcode_mysql_data)
if [ ! -z "$VOLUME_ID" ]; then
    echo "  🗑️ Removing existing volume (multibarcode_mysql_data)..."
    docker volume rm multibarcode_mysql_data 2>/dev/null || true
fi

# Check for any additional volumes with EXACT multibarcode project names only
for volume in $(docker volume ls --format "{{.Name}}" | grep -E "^multibarcode_(mysql_data|data|web_data)$"); do
    if [ ! -z "$volume" ]; then
        echo "  🗑️ Removing existing volume ($volume)..."
        docker volume rm "$volume" 2>/dev/null || true
    fi
done

# Remove ONLY multibarcode-webinterface images (safely targeting specific project)
echo "  🗑️ Removing multibarcode-webinterface images..."

# Safety check: Only proceed if we're in the correct directory
if [ ! -f "Dockerfile" ] || [ ! -f "start-services.sh" ]; then
    echo "  ⚠️ Safety check failed: Not in multibarcode project directory"
    exit 1
fi

# Safely remove tagged multibarcode-webinterface images (without force flag)
# Images in use will be safely skipped without -f flag
docker rmi multibarcode-webinterface:latest 2>/dev/null || true
docker rmi multibarcode-webinterface 2>/dev/null || true

# Remove only unused images with EXACTLY "multibarcode-webinterface" repository name
MULTIBARCODE_IMAGES=$(docker images --format "{{.Repository}} {{.Tag}} {{.ID}}" | awk '$1 == "multibarcode-webinterface" {print $3}')
if [ ! -z "$MULTIBARCODE_IMAGES" ]; then
    echo "  🗑️ Safely removing unused multibarcode-webinterface images..."
    echo "$MULTIBARCODE_IMAGES" | xargs -r docker rmi 2>/dev/null || true
fi

# Skip dangling image cleanup entirely - too risky to affect other projects
# Dangling images from multibarcode builds will be cleaned up by Docker's automatic cleanup
echo "  ℹ️ Skipping dangling image cleanup (safety measure)"

# Stop docker-compose services ONLY if multibarcode-specific compose file exists
if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
    echo "  🛑 Stopping multibarcode docker-compose services (if any)..."
    docker-compose down -v 2>/dev/null || true
else
    echo "  ℹ️ No docker-compose file found - skipping compose cleanup"
fi

echo "✅ Cleanup completed"

# Build the unified image
echo "🔨 Building unified Docker image..."
docker build -t multibarcode-webinterface:latest .

if [ $? -ne 0 ]; then
    echo "❌ Error: Failed to build Docker image"
    exit 1
fi

echo "✅ Docker image built successfully"

# Detect host IP address for proper Android connectivity
echo "🔍 Detecting host IP address..."
HOST_IP=""

# Method 1: Try to get 192.168.x.x IP address (most common for home/office networks)
HOST_IP=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep '^192\.168\.' | head -1)

# Method 2: Fallback to any private IP that's not Docker
if [ -z "$HOST_IP" ]; then
    HOST_IP=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)'| grep -v '^172\.(1[7-9]|2[0-9]|3[0-1])\.' | head -1)
fi

# Method 3: Use ip route to get source IP for external connectivity
if [ -z "$HOST_IP" ]; then
    HOST_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
fi

# Method 4: Fallback to localhost
if [ -z "$HOST_IP" ]; then
    echo "⚠️  Warning: Could not detect host IP automatically, using localhost"
    HOST_IP="127.0.0.1"
else
    echo "✅ Detected host IP: $HOST_IP"
fi

echo "📡 IP addresses will be detected automatically by the website"

# Start the unified container with SSL certificates
echo "🚀 Starting unified container with SSL certificates..."
docker run -d \
    --name multibarcode-webinterface \
    -p $WEB_PORT:$WEB_PORT \
    -p 3543:3543 \
    -e MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-root_password} \
    -e MYSQL_DATABASE=${DB_NAME:-barcode_wms} \
    -e MYSQL_USER=${DB_USER:-wms_user} \
    -e MYSQL_PASSWORD=${DB_PASS:-wms_password} \
    -e DB_HOST=127.0.0.1 \
    -e DB_NAME=${DB_NAME:-barcode_wms} \
    -e DB_USER=${DB_USER:-wms_user} \
    -e DB_PASS=${DB_PASS:-wms_password} \
    -e WEB_PORT=$WEB_PORT \
    -e HOST_IP=$HOST_IP \
    -e EXPOSE_PHPMYADMIN=${EXPOSE_PHPMYADMIN:-false} \
    -e EXPOSE_MYSQL=${EXPOSE_MYSQL:-false} \
    -v multibarcode_mysql_data:/var/lib/mysql \
    -v "$(pwd)/ssl":/etc/ssl/certs \
    -v "$(pwd)/ssl":/etc/ssl/private \
    --restart unless-stopped \
    --health-cmd "curl -f http://localhost:$WEB_PORT/ || exit 1" \
    --health-interval 30s \
    --health-timeout 10s \
    --health-retries 3 \
    --health-start-period 60s \
    multibarcode-webinterface:latest

if [ $? -ne 0 ]; then
    echo "❌ Error: Failed to start container"
    exit 1
fi

echo ""
echo "✅ Container started successfully!"
echo ""

# Wait for services to be ready
echo "⏳ Waiting for services to be ready..."
sleep 10

# Check container health
CONTAINER_ID=$(docker ps -q -f name=multibarcode-webinterface)
if [ -z "$CONTAINER_ID" ]; then
    echo "❌ Error: Container is not running"
    echo "🔍 Checking container logs..."
    docker logs multibarcode-webinterface --tail 20
    exit 1
fi

echo "✅ Container is running with ID: $CONTAINER_ID"

# Test web interface
if curl -s -f http://localhost:$WEB_PORT/ > /dev/null; then
    echo "✅ Web interface is responding"
else
    echo "⚠️  Warning: Web interface may not be ready yet"
fi

echo ""
echo "🎉 AI MultiBarcode Capture is now running!"
echo ""
echo "📍 Access Points:"
echo "- 🌐 Web Management System: http://localhost:$WEB_PORT"
echo "- 🔒 Secure Web Management: https://localhost:3543/"

if [ "$EXPOSE_PHPMYADMIN" = "true" ]; then
    echo "- 📊 phpMyAdmin: http://localhost:$WEB_PORT/phpmyadmin"
fi

echo ""
echo "🔧 Management Commands:"
echo "- View logs: docker logs multibarcode-webinterface"
echo "- Stop container: docker stop multibarcode-webinterface"
echo "- Remove container: docker rm multibarcode-webinterface"
echo "- Restart container: docker restart multibarcode-webinterface"
echo ""
echo "📱 Android App Configuration:"
echo "- HTTP Endpoint: http://YOUR_IP:$WEB_PORT/api/barcodes.php"
echo "- HTTPS Endpoint: https://YOUR_IP:3543/api/barcodes.php"
echo "- Example HTTP: http://192.168.1.100:$WEB_PORT/api/barcodes.php"
echo "- Example HTTPS: https://192.168.1.100:3543/api/barcodes.php"
echo ""
echo "🔐 SSL Certificate Installation:"
echo "- For Android: Install ssl/android_ca_system.pem as system certificate"
echo "- For browsers: Import ssl/wms_ca.crt to trusted root certificates"
echo ""
echo "🎯 Everything is ready! You can now start scanning with your Android app using HTTP or HTTPS."
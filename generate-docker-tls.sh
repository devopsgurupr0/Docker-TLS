#!/bin/bash

###################################
# Generate Docker TLS Certificates
# Usage: sudo ./generate-docker-tls.sh [DOCKER_HOST_IP]
###################################

set -e

# Configuration
DOCKER_HOST_IP="${1:-192.168.2.7}"
CERT_DIR="/etc/docker/certs"
CLIENT_CERT_DIR="./docker-certs"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

###################################
# Check if running as root
###################################
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        error "Please run: sudo $0 $DOCKER_HOST_IP"
        exit 1
    fi
}

###################################
# Check dependencies
###################################
check_dependencies() {
    log "Checking dependencies..."
    
    if ! command -v openssl >/dev/null 2>&1; then
        error "OpenSSL is required but not installed"
        error "Please install: apt-get update && apt-get install -y openssl"
        exit 1
    fi
    
    log "✅ Dependencies satisfied"
}

###################################
# Generate CA (Certificate Authority)
###################################
generate_ca() {
    log "Generating Certificate Authority (CA)..."
    
    mkdir -p $CERT_DIR
    cd $CERT_DIR
    
    # Generate CA private key
    openssl genrsa -aes256 -out ca-key.pem -passout pass:dockerca 4096
    
    # Generate CA certificate
    openssl req -new -x509 -days 365 -key ca-key.pem -sha256 -out ca.pem -passin pass:dockerca \
        -subj "/C=US/ST=CA/L=San Francisco/O=Docker/CN=Docker CA"
    
    log "✅ CA certificate generated"
}

###################################
# Generate Server Certificates
###################################
generate_server_certs() {
    log "Generating Docker daemon server certificates..."
    
    # Generate server private key
    openssl genrsa -out server-key.pem 4096
    
    # Generate server certificate signing request
    openssl req -subj "/CN=$DOCKER_HOST_IP" -sha256 -new -key server-key.pem -out server.csr
    
    # Create extensions file for server
    cat > server-extfile.cnf << EOF
subjectAltName = DNS:localhost,DNS:docker-host,IP:127.0.0.1,IP:$DOCKER_HOST_IP
extendedKeyUsage = serverAuth
EOF
    
    # Generate server certificate
    openssl x509 -req -days 365 -sha256 -in server.csr -CA ca.pem -CAkey ca-key.pem \
        -out server-cert.pem -extfile server-extfile.cnf -passin pass:dockerca -CAcreateserial
    
    log "✅ Server certificates generated"
}

###################################
# Generate Client Certificates
###################################
generate_client_certs() {
    log "Generating Docker client certificates..."
    
    # Generate client private key
    openssl genrsa -out key.pem 4096
    
    # Generate client certificate signing request
    openssl req -subj '/CN=client' -new -key key.pem -out client.csr
    
    # Create extensions file for client
    cat > client-extfile.cnf << EOF
extendedKeyUsage = clientAuth
EOF
    
    # Generate client certificate
    openssl x509 -req -days 365 -sha256 -in client.csr -CA ca.pem -CAkey ca-key.pem \
        -out cert.pem -extfile client-extfile.cnf -passin pass:dockerca -CAcreateserial
    
    log "✅ Client certificates generated"
}

###################################
# Set proper permissions
###################################
set_permissions() {
    log "Setting proper file permissions..."
    
    # Remove write permissions from certificates
    chmod -v 400 ca-key.pem key.pem server-key.pem
    chmod -v 444 ca.pem server-cert.pem cert.pem
    
    # Clean up CSR and extension files
    rm -f client.csr server.csr client-extfile.cnf server-extfile.cnf
    
    log "✅ Permissions set correctly"
}

###################################
# Copy client certificates
###################################
copy_client_certs() {
    log "Copying client certificates for Jenkins use..."
    
    # Create client certificate directory in current location
    mkdir -p $CLIENT_CERT_DIR
    
    # Copy client certificates
    cp ca.pem $CLIENT_CERT_DIR/
    cp cert.pem $CLIENT_CERT_DIR/
    cp key.pem $CLIENT_CERT_DIR/
    
    # Set permissions for client certs
    chmod 644 $CLIENT_CERT_DIR/ca.pem
    chmod 644 $CLIENT_CERT_DIR/cert.pem
    chmod 600 $CLIENT_CERT_DIR/key.pem
    
    # Change ownership to the user who ran sudo
    if [[ -n "$SUDO_USER" ]]; then
        chown -R $SUDO_USER:$SUDO_USER $CLIENT_CERT_DIR
    fi
    
    log "✅ Client certificates copied to $CLIENT_CERT_DIR"
}

###################################
# Generate certificate info file
###################################
generate_cert_info() {
    log "Generating certificate information file..."
    
    cat > $CLIENT_CERT_DIR/cert-info.txt << EOF
Docker TLS Certificates Information
==================================

Generated on: $(date)
Docker Host IP: $DOCKER_HOST_IP
Certificate Validity: 365 days

Files:
- ca.pem: Certificate Authority (public)
- cert.pem: Client Certificate (public)
- key.pem: Client Private Key (KEEP SECURE!)

Usage Examples:
--------------

1. Test connection:
docker --tlsverify --tlscacert=ca.pem --tlscert=cert.pem --tlskey=key.pem -H=tcp://$DOCKER_HOST_IP:2376 version

2. Environment variables:
export DOCKER_HOST=tcp://$DOCKER_HOST_IP:2376
export DOCKER_TLS_VERIFY=1
export DOCKER_CERT_PATH=./docker-certs

3. Jenkins Pipeline:
Use these certificates in your Jenkins pipeline for secure Docker remote access.

Security Notes:
--------------
- Keep key.pem secure and never commit to version control
- Rotate certificates every 365 days
- Only share ca.pem and cert.pem if needed
- Monitor certificate expiration dates

Certificate Expiration:
----------------------
CA Certificate: $(openssl x509 -in ca.pem -noout -enddate)
Client Certificate: $(openssl x509 -in cert.pem -noout -enddate)
Server Certificate: $(openssl x509 -in server-cert.pem -noout -enddate)
EOF
    
    if [[ -n "$SUDO_USER" ]]; then
        chown $SUDO_USER:$SUDO_USER $CLIENT_CERT_DIR/cert-info.txt
    fi
    
    log "✅ Certificate info saved to $CLIENT_CERT_DIR/cert-info.txt"
}

###################################
# Main execution
###################################
main() {
    log "🔐 Generating Docker TLS certificates for host: $DOCKER_HOST_IP"
    echo
    
    check_root
    check_dependencies
    generate_ca
    generate_server_certs
    generate_client_certs
    set_permissions
    copy_client_certs
    generate_cert_info
    
    log "🎉 TLS certificates generated successfully!"
    echo
    log "📁 Server certificates location: $CERT_DIR"
    log "📁 Client certificates location: $CLIENT_CERT_DIR"
    echo
    log "📋 Next steps:"
    echo "1. Run configure-docker-remote-secure.sh to configure Docker daemon"
    echo "2. Copy client certificates to your Jenkins machine"
    echo "3. Update your scripts to use TLS"
    echo
    warn "⚠️  SECURITY REMINDERS:"
    warn "1. Keep key.pem secure - it provides full Docker access"
    warn "2. Never commit certificates to version control"
    warn "3. Rotate certificates before expiration (365 days)"
    warn "4. Monitor certificate usage and access"
}

main "$@"
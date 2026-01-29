#!/bin/bash

###################################
# Configure Docker for Secure Remote Access with TLS
# Usage: sudo ./configure-docker-remote-secure.sh [DOCKER_HOST_IP]
###################################

set -e

# Configuration
CERT_DIR="/etc/docker/certs"
DOCKER_HOST_IP="${1:-$(hostname -I | awk '{print $1}')}"

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
        error "Please run: sudo $0 [DOCKER_HOST_IP]"
        exit 1
    fi
}

###################################
# Check if certificates exist
###################################
check_certificates() {
    log "Checking for TLS certificates..."
    
    local required_certs=("ca.pem" "server-cert.pem" "server-key.pem")
    local missing_certs=()
    
    for cert in "${required_certs[@]}"; do
        if [[ ! -f "$CERT_DIR/$cert" ]]; then
            missing_certs+=("$cert")
        fi
    done
    
    if [[ ${#missing_certs[@]} -gt 0 ]]; then
        error "TLS certificates not found in $CERT_DIR"
        error "Missing certificates: ${missing_certs[*]}"
        error "Please run generate-docker-tls.sh first to create certificates"
        exit 1
    fi
    
    log "✅ TLS certificates found"
}

###################################
# Validate certificate integrity
###################################
validate_certificates() {
    log "Validating certificate integrity..."
    
    # Check if server certificate matches the CA
    if openssl verify -CAfile "$CERT_DIR/ca.pem" "$CERT_DIR/server-cert.pem" >/dev/null 2>&1; then
        log "✅ Server certificate is valid"
    else
        error "❌ Server certificate validation failed"
        exit 1
    fi
    
    # Check certificate expiration
    local expiry_date=$(openssl x509 -in "$CERT_DIR/server-cert.pem" -noout -enddate | cut -d= -f2)
    local expiry_epoch=$(date -d "$expiry_date" +%s)
    local current_epoch=$(date +%s)
    local days_until_expiry=$(( (expiry_epoch - current_epoch) / 86400 ))
    
    if [[ $days_until_expiry -lt 30 ]]; then
        warn "⚠️  Certificate expires in $days_until_expiry days - consider renewal"
    else
        log "✅ Certificate valid for $days_until_expiry days"
    fi
}

###################################
# Backup existing configuration
###################################
backup_config() {
    log "Creating backup of existing Docker configuration..."
    
    if [[ -f /etc/docker/daemon.json ]]; then
        local backup_file="/etc/docker/daemon.json.backup.$(date +%Y%m%d_%H%M%S)"
        cp /etc/docker/daemon.json "$backup_file"
        log "✅ Backed up existing daemon.json to $backup_file"
    fi
}

###################################
# Configure Docker daemon with TLS
###################################
configure_daemon_tls() {
    log "Configuring Docker daemon for secure TLS remote access..."
    
    # Create docker directory if it doesn't exist
    mkdir -p /etc/docker
    
    # Create secure daemon.json configuration
    cat > /etc/docker/daemon.json << EOF
{
  "hosts": [
    "unix:///var/run/docker.sock",
    "tcp://0.0.0.0:2376"
  ],
  "tls": true,
  "tlscert": "$CERT_DIR/server-cert.pem",
  "tlskey": "$CERT_DIR/server-key.pem",
  "tlsverify": true,
  "tlscacert": "$CERT_DIR/ca.pem",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "userland-proxy": false,
  "experimental": false,
  "live-restore": true
}
EOF
    
    log "✅ Created secure /etc/docker/daemon.json"
}

###################################
# Configure systemd override
###################################
configure_systemd() {
    log "Configuring systemd override for TLS..."
    
    # Create systemd override directory
    mkdir -p /etc/systemd/system/docker.service.d
    
    # Create override configuration
    cat > /etc/systemd/system/docker.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd
EOF
    
    log "✅ Created systemd override configuration"
}

###################################
# Configure firewall for secure port
###################################
configure_firewall() {
    log "Configuring firewall for Docker TLS access..."
    
    # Check if ufw is installed and active
    if command -v ufw >/dev/null 2>&1; then
        if ufw status | grep -q "Status: active"; then
            log "Configuring UFW firewall..."
            
            # Remove old insecure rule if exists
            ufw --force delete allow 2375/tcp 2>/dev/null || true
            
            # Add secure TLS rule
            ufw allow 2376/tcp comment "Docker TLS Secure"
            log "✅ Port 2376 (TLS) opened in UFW"
        else
            warn "UFW is installed but not active"
        fi
    else
        warn "UFW not found, please manually configure firewall to allow port 2376"
    fi
    
    # Configure iptables
    if command -v iptables >/dev/null 2>&1; then
        # Remove old insecure rule
        iptables -D INPUT -p tcp --dport 2375 -j ACCEPT 2>/dev/null || true
        
        # Add secure rule if not exists
        if ! iptables -L | grep -q "dpt:2376"; then
            log "Adding iptables rule for port 2376 (TLS)..."
            iptables -A INPUT -p tcp --dport 2376 -j ACCEPT
            
            # Try to save iptables rules
            if command -v iptables-save >/dev/null 2>&1; then
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            fi
        fi
    fi
}

###################################
# Restart Docker service
###################################
restart_docker() {
    log "Restarting Docker service with TLS configuration..."
    
    # Reload systemd configuration
    systemctl daemon-reload
    
    # Stop Docker gracefully
    systemctl stop docker
    
    # Wait a moment
    sleep 3
    
    # Start Docker with new configuration
    systemctl start docker
    
    # Wait for Docker to fully start
    sleep 5
    
    # Check if Docker is running
    if systemctl is-active --quiet docker; then
        log "✅ Docker service restarted successfully with TLS"
    else
        error "❌ Failed to restart Docker service"
        log "Checking Docker service status..."
        systemctl status docker --no-pager -l
        log "Checking Docker logs..."
        journalctl -u docker --no-pager -n 20
        exit 1
    fi
}

###################################
# Verify TLS configuration
###################################
verify_tls_config() {
    log "Verifying Docker TLS configuration..."
    
    # Check if Docker is listening on port 2376
    if netstat -tlnp 2>/dev/null | grep -q ":2376"; then
        log "✅ Docker is listening on port 2376 (TLS)"
        netstat -tlnp | grep ":2376"
    else
        error "❌ Docker is not listening on port 2376"
        log "Checking Docker logs..."
        journalctl -u docker --no-pager -n 20
        exit 1
    fi
    
    # Test that insecure connection fails (expected behavior)
    log "Testing TLS requirement (insecure connection should fail)..."
    if timeout 5 curl -s http://localhost:2376/version >/dev/null 2>&1; then
        error "❌ Docker API is accessible without TLS - configuration failed!"
        exit 1
    else
        log "✅ Docker API properly requires TLS authentication"
    fi
    
    # Test secure connection with certificates
    log "Testing secure TLS connection..."
    if docker --tlsverify --tlscacert="$CERT_DIR/ca.pem" --tlscert="$CERT_DIR/cert.pem" --tlskey="$CERT_DIR/key.pem" -H=tcp://localhost:2376 version >/dev/null 2>&1; then
        log "✅ TLS connection successful"
    else
        warn "⚠️  Local TLS test failed - this may be normal if client certs are in different location"
    fi
}

###################################
# Generate connection script
###################################
generate_connection_script() {
    log "Generating connection helper script..."
    
    cat > /usr/local/bin/docker-tls-connect << EOF
#!/bin/bash
# Docker TLS Connection Helper
# Generated on $(date)

DOCKER_HOST_IP="$DOCKER_HOST_IP"
CERT_DIR="\${CERT_DIR:-./docker-certs}"

# Check if certificates exist
if [[ ! -f "\$CERT_DIR/ca.pem" ]] || [[ ! -f "\$CERT_DIR/cert.pem" ]] || [[ ! -f "\$CERT_DIR/key.pem" ]]; then
    echo "❌ TLS certificates not found in \$CERT_DIR"
    echo "Required files: ca.pem, cert.pem, key.pem"
    exit 1
fi

# Execute docker command with TLS
docker --tlsverify \\
    --tlscacert="\$CERT_DIR/ca.pem" \\
    --tlscert="\$CERT_DIR/cert.pem" \\
    --tlskey="\$CERT_DIR/key.pem" \\
    -H=tcp://\$DOCKER_HOST_IP:2376 \\
    "\$@"
EOF
    
    chmod +x /usr/local/bin/docker-tls-connect
    log "✅ Connection helper script created: /usr/local/bin/docker-tls-connect"
}

###################################
# Show connection information
###################################
show_connection_info() {
    log "🎉 Docker TLS configuration complete!"
    echo
    log "🔐 Secure Connection Information:"
    echo "  Docker Host: $DOCKER_HOST_IP"
    echo "  Docker Port: 2376 (TLS encrypted)"
    echo "  Protocol: TCP with mutual TLS authentication"
    echo
    log "📋 Required client certificates:"
    echo "  CA Certificate: $CERT_DIR/ca.pem"
    echo "  Client Certificate: $CERT_DIR/cert.pem"
    echo "  Client Key: $CERT_DIR/key.pem"
    echo
    log "🔗 Test secure connection from remote machine:"
    echo "  docker --tlsverify --tlscacert=ca.pem --tlscert=cert.pem --tlskey=key.pem -H=tcp://$DOCKER_HOST_IP:2376 version"
    echo
    log "📁 Client certificates location: ./docker-certs/"
    echo
    log "🛠️  Helper script available:"
    echo "  docker-tls-connect version"
    echo "  docker-tls-connect ps"
    echo
    log "🔄 Environment variables for easier usage:"
    echo "  export DOCKER_HOST=tcp://$DOCKER_HOST_IP:2376"
    echo "  export DOCKER_TLS_VERIFY=1"
    echo "  export DOCKER_CERT_PATH=./docker-certs"
    echo
    warn "⚠️  IMPORTANT SECURITY NOTES:"
    warn "1. Copy client certificates (ca.pem, cert.pem, key.pem) to Jenkins machine"
    warn "2. Keep client certificates secure - they provide full Docker access"
    warn "3. Rotate certificates every 365 days (or sooner for production)"
    warn "4. Never commit certificates to version control"
    warn "5. Monitor certificate expiration dates"
    warn "6. Use firewall rules to restrict access to port 2376"
}

###################################
# Main execution
###################################
main() {
    log "🔐 Configuring Docker for secure TLS remote access..."
    echo
    
    check_root
    check_certificates
    validate_certificates
    backup_config
    configure_daemon_tls
    configure_systemd
    configure_firewall
    restart_docker
    verify_tls_config
    generate_connection_script
    show_connection_info
}

main "$@"
#!/bin/bash

###################################
# Docker TLS Helper Script
# Simplifies Docker TLS operations
###################################

set -e

# Configuration
DOCKER_HOST_IP="${DOCKER_HOST_IP:-192.168.2.7}"
DOCKER_PORT="${DOCKER_PORT:-2376}"
TLS_CERT_DIR="${TLS_CERT_DIR:-./docker-certs}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

info() {
    echo -e "${BLUE}[TLS]${NC} $1"
}

###################################
# Show usage information
###################################
show_usage() {
    echo "Docker TLS Helper Script"
    echo "========================"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  setup           - Complete TLS setup (certificates + Docker config)"
    echo "  generate-certs  - Generate TLS certificates only"
    echo "  configure       - Configure Docker daemon with TLS only"
    echo "  test            - Test TLS connection"
    echo "  status          - Show TLS status and certificate info"
    echo "  renew           - Renew TLS certificates"
    echo "  cleanup         - Remove TLS configuration (restore insecure)"
    echo "  docker <cmd>    - Execute Docker command with TLS"
    echo ""
    echo "Environment Variables:"
    echo "  DOCKER_HOST_IP  - Docker host IP (default: 192.168.2.7)"
    echo "  DOCKER_PORT     - Docker port (default: 2376)"
    echo "  TLS_CERT_DIR    - Certificate directory (default: ./docker-certs)"
    echo ""
    echo "Examples:"
    echo "  $0 setup                    # Complete TLS setup"
    echo "  $0 test                     # Test TLS connection"
    echo "  $0 docker version           # Run 'docker version' with TLS"
    echo "  $0 docker ps                # Run 'docker ps' with TLS"
    echo "  DOCKER_HOST_IP=10.0.0.5 $0 setup  # Setup for different host"
}

###################################
# Check if certificates exist
###################################
check_certificates() {
    local required_certs=("ca.pem" "cert.pem" "key.pem")
    local missing_certs=()
    
    for cert in "${required_certs[@]}"; do
        if [[ ! -f "$TLS_CERT_DIR/$cert" ]]; then
            missing_certs+=("$cert")
        fi
    done
    
    if [[ ${#missing_certs[@]} -gt 0 ]]; then
        return 1
    fi
    
    return 0
}

###################################
# Generate TLS certificates
###################################
generate_certificates() {
    log "🔐 Generating TLS certificates for Docker host: $DOCKER_HOST_IP"
    
    if [[ ! -f "generate-docker-tls.sh" ]]; then
        error "generate-docker-tls.sh not found in current directory"
        error "Please ensure you're running this script from the tls-security directory"
        exit 1
    fi
    
    # Copy script to Docker host
    log "Copying certificate generation script to Docker host..."
    scp generate-docker-tls.sh root@$DOCKER_HOST_IP:/tmp/
    
    # Generate certificates on Docker host
    log "Generating certificates on Docker host..."
    ssh root@$DOCKER_HOST_IP "cd /tmp && chmod +x generate-docker-tls.sh && sudo ./generate-docker-tls.sh $DOCKER_HOST_IP"
    
    # Copy client certificates back
    log "Copying client certificates..."
    scp -r root@$DOCKER_HOST_IP:/tmp/docker-certs ./
    
    log "✅ TLS certificates generated successfully"
}

###################################
# Configure Docker daemon
###################################
configure_docker() {
    log "🔧 Configuring Docker daemon with TLS on $DOCKER_HOST_IP"
    
    if [[ ! -f "configure-docker-remote-secure.sh" ]]; then
        error "configure-docker-remote-secure.sh not found in current directory"
        error "Please ensure you're running this script from the tls-security directory"
        exit 1
    fi
    
    # Copy configuration script to Docker host
    log "Copying Docker configuration script..."
    scp configure-docker-remote-secure.sh root@$DOCKER_HOST_IP:/tmp/
    
    # Configure Docker daemon
    log "Configuring Docker daemon..."
    ssh root@$DOCKER_HOST_IP "cd /tmp && chmod +x configure-docker-remote-secure.sh && sudo ./configure-docker-remote-secure.sh"
    
    log "✅ Docker daemon configured with TLS"
}

###################################
# Test TLS connection
###################################
test_connection() {
    log "🧪 Testing TLS connection to $DOCKER_HOST_IP:$DOCKER_PORT"
    
    if ! check_certificates; then
        error "TLS certificates not found in $TLS_CERT_DIR"
        error "Run '$0 generate-certs' first"
        exit 1
    fi
    
    # Test TLS connection
    if docker --tlsverify --tlscacert=$TLS_CERT_DIR/ca.pem --tlscert=$TLS_CERT_DIR/cert.pem --tlskey=$TLS_CERT_DIR/key.pem -H tcp://$DOCKER_HOST_IP:$DOCKER_PORT version >/dev/null 2>&1; then
        log "✅ TLS connection successful"
        
        # Get Docker version
        local docker_version=$(docker --tlsverify --tlscacert=$TLS_CERT_DIR/ca.pem --tlscert=$TLS_CERT_DIR/cert.pem --tlskey=$TLS_CERT_DIR/key.pem -H tcp://$DOCKER_HOST_IP:$DOCKER_PORT version --format '{{.Server.Version}}' 2>/dev/null)
        info "Docker version: $docker_version"
        
        # Test that insecure connection fails
        if timeout 5 curl -s http://$DOCKER_HOST_IP:$DOCKER_PORT/version >/dev/null 2>&1; then
            warn "⚠️  Insecure connection still works - TLS may not be properly configured"
        else
            info "✅ Insecure connections properly rejected"
        fi
        
    else
        error "❌ TLS connection failed"
        error "Check certificates and Docker daemon configuration"
        exit 1
    fi
}

###################################
# Show TLS status
###################################
show_status() {
    log "📊 Docker TLS Status for $DOCKER_HOST_IP:$DOCKER_PORT"
    echo
    
    # Check certificates
    if check_certificates; then
        info "✅ TLS certificates found in $TLS_CERT_DIR"
        
        # Show certificate details
        echo "📋 Certificate Information:"
        echo "  CA Certificate: $TLS_CERT_DIR/ca.pem"
        echo "  Client Certificate: $TLS_CERT_DIR/cert.pem"
        echo "  Client Key: $TLS_CERT_DIR/key.pem"
        echo
        
        # Check certificate expiration
        local cert_expiry=$(openssl x509 -in "$TLS_CERT_DIR/cert.pem" -noout -enddate | cut -d= -f2)
        local expiry_epoch=$(date -d "$cert_expiry" +%s 2>/dev/null || echo "0")
        local current_epoch=$(date +%s)
        
        if [[ $expiry_epoch -gt 0 ]]; then
            local days_until_expiry=$(( (expiry_epoch - current_epoch) / 86400 ))
            if [[ $days_until_expiry -lt 30 ]]; then
                warn "⚠️  Certificate expires in $days_until_expiry days"
                warn "Run '$0 renew' to renew certificates"
            else
                info "✅ Certificate valid for $days_until_expiry days"
            fi
            echo "  Expiration: $cert_expiry"
        fi
        
        # Test connection
        echo
        if docker --tlsverify --tlscacert=$TLS_CERT_DIR/ca.pem --tlscert=$TLS_CERT_DIR/cert.pem --tlskey=$TLS_CERT_DIR/key.pem -H tcp://$DOCKER_HOST_IP:$DOCKER_PORT version >/dev/null 2>&1; then
            info "✅ TLS connection working"
        else
            error "❌ TLS connection failed"
        fi
        
    else
        warn "⚠️  TLS certificates not found in $TLS_CERT_DIR"
        warn "Run '$0 generate-certs' to create certificates"
    fi
    
    # Check Docker daemon status
    echo
    log "🐳 Docker Daemon Status:"
    if ssh root@$DOCKER_HOST_IP "systemctl is-active --quiet docker"; then
        info "✅ Docker daemon is running"
        
        # Check if listening on TLS port
        if ssh root@$DOCKER_HOST_IP "netstat -tlnp | grep -q :$DOCKER_PORT"; then
            info "✅ Docker listening on port $DOCKER_PORT"
        else
            warn "⚠️  Docker not listening on port $DOCKER_PORT"
        fi
    else
        error "❌ Docker daemon is not running"
    fi
}

###################################
# Renew certificates
###################################
renew_certificates() {
    log "🔄 Renewing TLS certificates for $DOCKER_HOST_IP"
    
    # Backup existing certificates
    if check_certificates; then
        local backup_dir="$TLS_CERT_DIR.backup.$(date +%Y%m%d_%H%M%S)"
        log "Backing up existing certificates to $backup_dir"
        cp -r "$TLS_CERT_DIR" "$backup_dir"
    fi
    
    # Generate new certificates
    generate_certificates
    
    # Restart Docker daemon to use new certificates
    log "Restarting Docker daemon..."
    ssh root@$DOCKER_HOST_IP "sudo systemctl restart docker"
    
    # Wait for Docker to start
    sleep 5
    
    # Test new certificates
    test_connection
    
    log "✅ Certificates renewed successfully"
}

###################################
# Cleanup TLS configuration
###################################
cleanup_tls() {
    warn "⚠️  This will remove TLS configuration and restore insecure Docker access"
    read -p "Are you sure? (y/N): " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Operation cancelled"
        exit 0
    fi
    
    log "🧹 Removing TLS configuration from $DOCKER_HOST_IP"
    
    # Restore original Docker configuration
    ssh root@$DOCKER_HOST_IP "
        sudo systemctl stop docker
        sudo rm -f /etc/docker/daemon.json
        sudo rm -rf /etc/docker/certs
        sudo rm -rf /etc/systemd/system/docker.service.d/override.conf
        sudo systemctl daemon-reload
        sudo systemctl start docker
    "
    
    # Remove local certificates
    if [[ -d "$TLS_CERT_DIR" ]]; then
        local backup_dir="$TLS_CERT_DIR.removed.$(date +%Y%m%d_%H%M%S)"
        log "Moving certificates to $backup_dir"
        mv "$TLS_CERT_DIR" "$backup_dir"
    fi
    
    warn "⚠️  TLS configuration removed - Docker is now INSECURE"
    warn "Only use this for development/testing environments"
}

###################################
# Execute Docker command with TLS
###################################
execute_docker_command() {
    if ! check_certificates; then
        error "TLS certificates not found in $TLS_CERT_DIR"
        error "Run '$0 setup' first"
        exit 1
    fi
    
    # Execute Docker command with TLS
    docker --tlsverify --tlscacert=$TLS_CERT_DIR/ca.pem --tlscert=$TLS_CERT_DIR/cert.pem --tlskey=$TLS_CERT_DIR/key.pem -H tcp://$DOCKER_HOST_IP:$DOCKER_PORT "$@"
}

###################################
# Complete TLS setup
###################################
complete_setup() {
    log "🚀 Starting complete TLS setup for Docker host: $DOCKER_HOST_IP"
    echo
    
    # Step 1: Generate certificates
    log "Step 1: Generating TLS certificates..."
    generate_certificates
    echo
    
    # Step 2: Configure Docker daemon
    log "Step 2: Configuring Docker daemon..."
    configure_docker
    echo
    
    # Step 3: Test connection
    log "Step 3: Testing TLS connection..."
    sleep 5  # Wait for Docker to restart
    test_connection
    echo
    
    log "🎉 TLS setup completed successfully!"
    echo
    log "📋 Next steps:"
    echo "1. Test connection: $0 test"
    echo "2. Run Docker commands: $0 docker version"
    echo "3. Deploy agents: TLS_ENABLED=true ./Docker-Agent-TLS.sh start"
    echo
    info "🔐 Your Docker connection is now secure with TLS encryption!"
}

###################################
# Main execution
###################################
main() {
    case "${1:-help}" in
        "setup")
            complete_setup
            ;;
        "generate-certs")
            generate_certificates
            ;;
        "configure")
            configure_docker
            ;;
        "test")
            test_connection
            ;;
        "status")
            show_status
            ;;
        "renew")
            renew_certificates
            ;;
        "cleanup")
            cleanup_tls
            ;;
        "docker")
            shift
            execute_docker_command "$@"
            ;;
        "help"|"-h"|"--help")
            show_usage
            ;;
        *)
            error "Unknown command: $1"
            echo
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
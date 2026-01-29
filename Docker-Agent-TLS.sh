#!/bin/bash

###################################
# Jenkins SSH Agent Management Script with TLS Support
# Enhanced version with Docker TLS security
###################################

set -e

# Configuration
IMAGE_NAME="jenkins-ssh-agent"
NETWORK_NAME="macvlan_net"
SUBNET="192.168.2.0/24"
IP_RANGE_START=50  # Starting from 192.168.2.50 to avoid conflicts
SSH_KEY_PATH="${SSH_KEY_PATH:-./.ssh/jenkins_ssh_key.pub}"
DOCKER_HOST="${DOCKER_HOST:-192.168.2.7}"
DOCKER_PORT="${DOCKER_PORT:-2376}"
NUM_AGENTS="${NUM_AGENTS:-1}"  # Number of agents to create (default: 1)

# TLS Configuration
TLS_ENABLED="${TLS_ENABLED:-true}"
TLS_CERT_DIR="${TLS_CERT_DIR:-./docker-certs}"
TLS_VERIFY="${TLS_VERIFY:-true}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
# Setup Docker context with TLS support
###################################
setup_docker_context() {
    log "Setting up Docker context for remote host: $DOCKER_HOST"
    
    # Build Docker command based on TLS configuration
    if [[ "$TLS_ENABLED" == "true" ]]; then
        info "TLS encryption enabled - validating certificates..."
        
        # Check if TLS certificates exist
        local required_certs=("ca.pem" "cert.pem" "key.pem")
        local missing_certs=()
        
        for cert in "${required_certs[@]}"; do
            if [[ ! -f "$TLS_CERT_DIR/$cert" ]]; then
                missing_certs+=("$cert")
            fi
        done
        
        if [[ ${#missing_certs[@]} -gt 0 ]]; then
            error "TLS certificates not found in $TLS_CERT_DIR"
            error "Missing certificates: ${missing_certs[*]}"
            error "Required files: ca.pem, cert.pem, key.pem"
            error ""
            error "To fix this:"
            error "1. Copy certificates from Docker host: scp -r root@$DOCKER_HOST:/tmp/docker-certs ./"
            error "2. Or disable TLS temporarily: export TLS_ENABLED=false"
            exit 1
        fi
        
        # Validate certificate permissions
        if [[ ! -r "$TLS_CERT_DIR/key.pem" ]]; then
            error "Cannot read private key: $TLS_CERT_DIR/key.pem"
            error "Fix permissions: chmod 600 $TLS_CERT_DIR/key.pem"
            exit 1
        fi
        
        # Build TLS Docker command
        DOCKER_CMD="docker --tlsverify --tlscacert=$TLS_CERT_DIR/ca.pem --tlscert=$TLS_CERT_DIR/cert.pem --tlskey=$TLS_CERT_DIR/key.pem -H tcp://$DOCKER_HOST:$DOCKER_PORT"
        info "Using TLS-secured Docker connection"
        
        # Validate certificate expiration
        local cert_expiry=$(openssl x509 -in "$TLS_CERT_DIR/cert.pem" -noout -enddate | cut -d= -f2)
        local expiry_epoch=$(date -d "$cert_expiry" +%s 2>/dev/null || echo "0")
        local current_epoch=$(date +%s)
        
        if [[ $expiry_epoch -gt 0 ]]; then
            local days_until_expiry=$(( (expiry_epoch - current_epoch) / 86400 ))
            if [[ $days_until_expiry -lt 30 ]]; then
                warn "⚠️  TLS certificate expires in $days_until_expiry days - consider renewal"
            else
                info "✅ TLS certificate valid for $days_until_expiry days"
            fi
        fi
        
    else
        DOCKER_CMD="docker -H tcp://$DOCKER_HOST:$DOCKER_PORT"
        warn "⚠️  Using INSECURE Docker connection - not recommended for production!"
        warn "Enable TLS with: export TLS_ENABLED=true"
    fi
    
    # Test Docker connection
    log "Testing Docker connection..."
    if ! $DOCKER_CMD version >/dev/null 2>&1; then
        error "Cannot connect to Docker daemon at $DOCKER_HOST:$DOCKER_PORT"
        
        if [[ "$TLS_ENABLED" == "true" ]]; then
            error ""
            error "TLS connection failed. Please verify:"
            error "1. Docker daemon is running with TLS enabled on $DOCKER_HOST"
            error "2. Certificates are valid and accessible in $TLS_CERT_DIR"
            error "3. Network connectivity to $DOCKER_HOST:$DOCKER_PORT"
            error "4. Firewall allows port $DOCKER_PORT"
            error ""
            error "Debug steps:"
            error "- Test network: telnet $DOCKER_HOST $DOCKER_PORT"
            error "- Check certs: ls -la $TLS_CERT_DIR/"
            error "- Verify Docker daemon: ssh root@$DOCKER_HOST 'systemctl status docker'"
        else
            error ""
            error "Insecure connection failed. Please ensure:"
            error "1. Docker daemon is running on $DOCKER_HOST"
            error "2. Docker daemon is configured for remote access"
            error "3. Port $DOCKER_PORT is accessible"
        fi
        exit 1
    fi
    
    # Get Docker version info
    local docker_version=$($DOCKER_CMD version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
    log "✅ Successfully connected to Docker daemon (version: $docker_version)"
    
    if [[ "$TLS_ENABLED" == "true" ]]; then
        info "🔐 Connection secured with TLS encryption"
    fi
}

###################################
# Check if SSH key exists
###################################
check_ssh_key() {
    log "Validating SSH key configuration..."
    
    if [[ ! -f "$SSH_KEY_PATH" ]]; then
        error "SSH public key not found at $SSH_KEY_PATH"
        error ""
        error "Generate SSH key pair:"
        error "  ssh-keygen -t rsa -b 4096 -f .ssh/jenkins_ssh_key -N \"\" -C \"jenkins-agent-key\""
        error "  chmod 600 .ssh/jenkins_ssh_key"
        error "  chmod 644 .ssh/jenkins_ssh_key.pub"
        exit 1
    fi
    
    # Check if private key exists
    local private_key_path="${SSH_KEY_PATH%.*}"
    if [[ ! -f "$private_key_path" ]]; then
        warn "⚠️  Private key not found at $private_key_path"
        warn "You'll need the private key to connect to agents"
    else
        log "✅ SSH key pair found"
    fi
}

###################################
# Clean up existing containers
###################################
cleanup() {
    log "Cleaning up existing Jenkins agent containers on $DOCKER_HOST..."
    
    # Stop and remove containers based on NUM_AGENTS
    for i in $(seq 1 $NUM_AGENTS); do
        local container_name="jenkins-agent$i"
        if $DOCKER_CMD ps -a --format "table {{.Names}}" | grep -q "^$container_name$"; then
            log "Removing existing container: $container_name"
            $DOCKER_CMD rm -f $container_name 2>/dev/null || true
        fi
    done
    
    log "✅ Cleanup completed"
}

###################################
# Build Docker image on remote host
###################################
build_image() {
    log "Building Docker image on remote host: $DOCKER_HOST"
    
    # Create a temporary directory for build context
    BUILD_DIR=$(mktemp -d)
    
    # Copy Dockerfile to build context
    if [[ ! -f "Dockerfile" ]]; then
        error "Dockerfile not found in current directory"
        error "Please ensure you're running this script from the project root"
        exit 1
    fi
    cp Dockerfile "$BUILD_DIR/"
    
    # Create .ssh directory in build context and copy SSH public key
    mkdir -p "$BUILD_DIR/.ssh"
    cp "$SSH_KEY_PATH" "$BUILD_DIR/.ssh/"
    
    # Build the image on remote Docker host
    log "Building image $IMAGE_NAME..."
    $DOCKER_CMD build -t $IMAGE_NAME "$BUILD_DIR"
    
    # Clean up temporary directory
    rm -rf "$BUILD_DIR"
    
    log "✅ Docker image $IMAGE_NAME built successfully on $DOCKER_HOST"
}

###################################
# Create network and containers
###################################
create_infrastructure() {
    log "Deploying $NUM_AGENTS Jenkins SSH agent(s) on $DOCKER_HOST..."
    
    # Check if macvlan network exists
    if ! $DOCKER_CMD network ls --format "{{.Name}}" | grep -q "^$NETWORK_NAME$"; then
        error "Macvlan network '$NETWORK_NAME' not found!"
        error ""
        error "Create the network first:"
        error "  $DOCKER_CMD network create -d macvlan \\"
        error "    --subnet=$SUBNET \\"
        error "    --gateway=192.168.2.1 \\"
        error "    -o parent=eth0 $NETWORK_NAME"
        exit 1
    fi
    
    log "✅ Using existing macvlan network: $NETWORK_NAME"
    
    # Deploy agents
    for i in $(seq 1 $NUM_AGENTS); do
        local ip="192.168.2.$((IP_RANGE_START+i-1))"  # 192.168.2.50, 192.168.2.51, etc.
        local container_name="jenkins-agent$i"
        
        log "Creating $container_name with IP $ip..."
        
        $DOCKER_CMD run --detach \
            --name=$container_name \
            --hostname=$container_name \
            --network=$NETWORK_NAME \
            --ip=$ip \
            --restart=unless-stopped \
            --memory=1g \
            --cpus=1.0 \
            --health-cmd="ss -tuln | grep :22 || exit 1" \
            --health-interval=30s \
            --health-timeout=10s \
            --health-retries=3 \
            $IMAGE_NAME
        
        # Wait for container to start
        sleep 3
        
        # Check container health
        local health_status=$($DOCKER_CMD inspect --format='{{.State.Health.Status}}' $container_name 2>/dev/null || echo "unknown")
        if [[ "$health_status" == "healthy" ]] || [[ "$health_status" == "starting" ]]; then
            log "✅ $container_name is running (health: $health_status)"
        else
            warn "⚠️  $container_name health status: $health_status"
        fi
        
        # Test SSH connection
        log "Testing SSH connection to $ip..."
        if timeout 10 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "${SSH_KEY_PATH%.*}" jenkins@$ip "echo 'SSH OK'" >/dev/null 2>&1; then
            log "✅ SSH connection successful to $container_name"
        else
            warn "⚠️  SSH connection failed to $container_name - may need time to initialize"
        fi
    done
}

###################################
# Display connection information
###################################
show_info() {
    log "📊 Jenkins SSH Agents Status:"
    echo
    printf "%-15s %-15s %-15s %-10s %-15s %-10s\n" "Container" "IP Address" "Network" "SSH Port" "Status" "Health"
    printf "%-15s %-15s %-15s %-10s %-15s %-10s\n" "---------" "----------" "-------" "--------" "------" "------"
    
    for i in $(seq 1 $NUM_AGENTS); do
        local ip="192.168.2.$((IP_RANGE_START+i-1))"
        local container_name="jenkins-agent$i"
        local status=$($DOCKER_CMD ps --format "{{.Status}}" --filter "name=^$container_name$" 2>/dev/null | head -1)
        local health=$($DOCKER_CMD inspect --format='{{.State.Health.Status}}' $container_name 2>/dev/null || echo "none")
        
        if [[ -n "$status" ]]; then
            printf "%-15s %-15s %-15s %-10s %-15s %-10s\n" "$container_name" "$ip" "$NETWORK_NAME" "22" "Running" "$health"
        else
            printf "%-15s %-15s %-15s %-10s %-15s %-10s\n" "$container_name" "$ip" "$NETWORK_NAME" "22" "Stopped" "none"
        fi
    done
    
    echo
    log "🔗 SSH Connection Examples:"
    for i in $(seq 1 $NUM_AGENTS); do
        local ip="192.168.2.$((IP_RANGE_START+i-1))"
        echo "  ssh -i ${SSH_KEY_PATH%.*} jenkins@$ip"
    done
    
    echo
    log "🎯 Jenkins Node Configuration:"
    echo "  Host IPs: $(for i in $(seq 1 $NUM_AGENTS); do echo -n "192.168.2.$((IP_RANGE_START+i-1))"; [[ $i -lt $NUM_AGENTS ]] && echo -n ", "; done)"
    echo "  Port: 22 (standard SSH)"
    echo "  Username: jenkins"
    echo "  Private Key: ${SSH_KEY_PATH%.*}"
    echo "  Labels: $(for i in $(seq 1 $NUM_AGENTS); do echo -n "jenkins-agent$i"; [[ $i -lt $NUM_AGENTS ]] && echo -n ", "; done)"
    
    echo
    log "🔐 Security Status:"
    if [[ "$TLS_ENABLED" == "true" ]]; then
        info "✅ Docker connection secured with TLS"
        info "✅ Certificate location: $TLS_CERT_DIR"
    else
        warn "⚠️  Docker connection is INSECURE - enable TLS for production"
    fi
    
    echo
    log "🌐 Network Benefits:"
    echo "  ✅ Direct IP access from any network device"
    echo "  ✅ No port forwarding needed"
    echo "  ✅ Containers appear as separate network devices"
    echo "  ✅ Better network performance"
}

###################################
# Show usage information
###################################
show_usage() {
    echo "Usage: $0 {start|stop|status|restart|build}"
    echo ""
    echo "Commands:"
    echo "  start   - Build image and start all Jenkins agents (default)"
    echo "  stop    - Stop and remove all Jenkins agents"
    echo "  status  - Show current status of agents"
    echo "  restart - Stop and restart all agents"
    echo "  build   - Build Docker image only"
    echo ""
    echo "Environment Variables:"
    echo "  DOCKER_HOST     - Remote Docker host IP (default: 192.168.2.7)"
    echo "  DOCKER_PORT     - Remote Docker port (default: 2376)"
    echo "  SSH_KEY_PATH    - Path to SSH public key (default: ./.ssh/jenkins_ssh_key.pub)"
    echo "  NUM_AGENTS      - Number of agents to create (default: 1)"
    echo ""
    echo "TLS Security Variables:"
    echo "  TLS_ENABLED     - Enable TLS encryption (default: true)"
    echo "  TLS_CERT_DIR    - TLS certificates directory (default: ./docker-certs)"
    echo "  TLS_VERIFY      - Verify TLS certificates (default: true)"
    echo ""
    echo "Examples:"
    echo "  # Deploy 3 agents with TLS"
    echo "  NUM_AGENTS=3 TLS_ENABLED=true ./Docker-Agent-TLS.sh start"
    echo ""
    echo "  # Deploy without TLS (insecure)"
    echo "  TLS_ENABLED=false ./Docker-Agent-TLS.sh start"
    echo ""
    echo "  # Use custom certificate location"
    echo "  TLS_CERT_DIR=/path/to/certs ./Docker-Agent-TLS.sh start"
}

###################################
# Main execution
###################################
main() {
    case "${1:-start}" in
        "start")
            setup_docker_context
            check_ssh_key
            cleanup
            build_image
            create_infrastructure
            show_info
            ;;
        "stop")
            setup_docker_context
            cleanup
            log "✅ All Jenkins agents stopped and cleaned up on $DOCKER_HOST"
            ;;
        "status")
            setup_docker_context
            show_info
            ;;
        "restart")
            setup_docker_context
            cleanup
            build_image
            create_infrastructure
            show_info
            ;;
        "build")
            setup_docker_context
            build_image
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
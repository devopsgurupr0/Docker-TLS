#!/bin/bash

###################################
# Jenkins SSH Agent Management Script with Flexible Network Support
# Supports multiple network topologies and configurations
###################################

set -e

# Configuration
CONFIG_FILE="${CONFIG_FILE:-./network-config.env}"
IMAGE_NAME="${IMAGE_NAME:-jenkins-ssh-agent}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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
    echo -e "${BLUE}[NET]${NC} $1"
}

debug() {
    echo -e "${CYAN}[DEBUG]${NC} $1"
}

###################################
# Load configuration
###################################
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        log "Loading configuration from $CONFIG_FILE"
        source "$CONFIG_FILE"
    else
        warn "Configuration file $CONFIG_FILE not found, using defaults"
        set_default_config
    fi
    
    # Load environment-specific config if specified
    if [[ -n "$ENVIRONMENT" ]]; then
        source_env_config "$ENVIRONMENT"
    fi
    
    # Override with environment variables if set
    DOCKER_HOST_IP="${DOCKER_HOST_IP:-192.168.2.7}"
    DOCKER_HOST_PORT="${DOCKER_HOST_PORT:-2376}"
    NETWORK_TYPE="${NETWORK_TYPE:-macvlan}"
    NETWORK_NAME="${NETWORK_NAME:-jenkins_net}"
    NUM_AGENTS="${NUM_AGENTS:-1}"
    AGENT_NAME_PREFIX="${AGENT_NAME_PREFIX:-jenkins-agent}"
    TLS_ENABLED="${TLS_ENABLED:-true}"
    TLS_CERT_DIR="${TLS_CERT_DIR:-./docker-certs}"
    SSH_KEY_PATH="${SSH_KEY_PATH:-./.ssh/jenkins_ssh_key.pub}"
    
    debug "Configuration loaded:"
    debug "  Docker Host: $DOCKER_HOST_IP:$DOCKER_HOST_PORT"
    debug "  Network Type: $NETWORK_TYPE"
    debug "  Network Name: $NETWORK_NAME"
    debug "  Number of Agents: $NUM_AGENTS"
    debug "  TLS Enabled: $TLS_ENABLED"
}

###################################
# Set default configuration
###################################
set_default_config() {
    DOCKER_HOST_IP="192.168.2.7"
    DOCKER_HOST_PORT="2376"
    NETWORK_TYPE="macvlan"
    NETWORK_NAME="jenkins_net"
    MACVLAN_SUBNET="192.168.2.0/24"
    MACVLAN_GATEWAY="192.168.2.1"
    MACVLAN_PARENT_INTERFACE="eth0"
    MACVLAN_IP_RANGE_START="50"
    BRIDGE_SUBNET="172.20.0.0/16"
    BRIDGE_GATEWAY="172.20.0.1"
    BRIDGE_IP_RANGE_START="10"
    NUM_AGENTS="1"
    AGENT_NAME_PREFIX="jenkins-agent"
    TLS_ENABLED="true"
    TLS_CERT_DIR="./docker-certs"
    SSH_KEY_PATH="./.ssh/jenkins_ssh_key.pub"
    AGENT_MEMORY_LIMIT="1g"
    AGENT_CPU_LIMIT="1.0"
    AGENT_RESTART_POLICY="unless-stopped"
}

###################################
# Load environment-specific configuration
###################################
source_env_config() {
    local env_prefix="$1"
    
    if [[ -z "$env_prefix" ]]; then
        error "Environment prefix required (DEV, STAGING, PROD)"
        return 1
    fi
    
    log "Loading $env_prefix environment configuration"
    
    # Load environment-specific variables
    local docker_host_var="${env_prefix}_DOCKER_HOST_IP"
    local network_type_var="${env_prefix}_NETWORK_TYPE"
    local num_agents_var="${env_prefix}_NUM_AGENTS"
    
    [[ -n "${!docker_host_var}" ]] && DOCKER_HOST_IP="${!docker_host_var}"
    [[ -n "${!network_type_var}" ]] && NETWORK_TYPE="${!network_type_var}"
    [[ -n "${!num_agents_var}" ]] && NUM_AGENTS="${!num_agents_var}"
    
    # Load network-specific configuration
    case "$NETWORK_TYPE" in
        "macvlan")
            local subnet_var="${env_prefix}_MACVLAN_SUBNET"
            local gateway_var="${env_prefix}_MACVLAN_GATEWAY"
            [[ -n "${!subnet_var}" ]] && MACVLAN_SUBNET="${!subnet_var}"
            [[ -n "${!gateway_var}" ]] && MACVLAN_GATEWAY="${!gateway_var}"
            ;;
        "bridge")
            local subnet_var="${env_prefix}_BRIDGE_SUBNET"
            local gateway_var="${env_prefix}_BRIDGE_GATEWAY"
            [[ -n "${!subnet_var}" ]] && BRIDGE_SUBNET="${!subnet_var}"
            [[ -n "${!gateway_var}" ]] && BRIDGE_GATEWAY="${!gateway_var}"
            ;;
        "overlay")
            local subnet_var="${env_prefix}_OVERLAY_SUBNET"
            local gateway_var="${env_prefix}_OVERLAY_GATEWAY"
            [[ -n "${!subnet_var}" ]] && OVERLAY_SUBNET="${!subnet_var}"
            [[ -n "${!gateway_var}" ]] && OVERLAY_GATEWAY="${!gateway_var}"
            ;;
    esac
}

###################################
# Get Docker command with TLS support
###################################
get_docker_command() {
    if [[ "$TLS_ENABLED" == "true" ]]; then
        if [[ ! -f "$TLS_CERT_DIR/ca.pem" ]] || [[ ! -f "$TLS_CERT_DIR/cert.pem" ]] || [[ ! -f "$TLS_CERT_DIR/key.pem" ]]; then
            error "TLS certificates not found in $TLS_CERT_DIR"
            error "Required files: ca.pem, cert.pem, key.pem"
            exit 1
        fi
        echo "docker --tlsverify --tlscacert=$TLS_CERT_DIR/ca.pem --tlscert=$TLS_CERT_DIR/cert.pem --tlskey=$TLS_CERT_DIR/key.pem -H tcp://$DOCKER_HOST_IP:$DOCKER_HOST_PORT"
    else
        echo "docker -H tcp://$DOCKER_HOST_IP:$DOCKER_HOST_PORT"
    fi
}

###################################
# Calculate IP address for agent
###################################
calculate_agent_ip() {
    local agent_index="$1"
    
    case "$NETWORK_TYPE" in
        "macvlan")
            local base_ip=$(echo "$MACVLAN_SUBNET" | cut -d'/' -f1 | cut -d'.' -f1-3)
            local start_ip="$MACVLAN_IP_RANGE_START"
            echo "${base_ip}.$((start_ip + agent_index - 1))"
            ;;
        "bridge")
            local base_ip=$(echo "$BRIDGE_SUBNET" | cut -d'/' -f1 | cut -d'.' -f1-3)
            local start_ip="$BRIDGE_IP_RANGE_START"
            echo "${base_ip}.$((start_ip + agent_index - 1))"
            ;;
        "overlay")
            local base_ip=$(echo "$OVERLAY_SUBNET" | cut -d'/' -f1 | cut -d'.' -f1-3)
            echo "${base_ip}.$((10 + agent_index - 1))"
            ;;
        "host")
            echo "host-network"
            ;;
        *)
            error "Unsupported network type: $NETWORK_TYPE"
            exit 1
            ;;
    esac
}

###################################
# Get port mapping for agent (bridge network)
###################################
get_port_mapping() {
    local agent_index="$1"
    
    case "$NETWORK_TYPE" in
        "bridge")
            local ssh_port=$((2200 + agent_index))
            echo "-p $ssh_port:22"
            ;;
        "macvlan"|"overlay"|"host")
            echo ""  # No port mapping needed
            ;;
        *)
            echo ""
            ;;
    esac
}

###################################
# Setup Docker context
###################################
setup_docker_context() {
    log "Setting up Docker context for remote host: $DOCKER_HOST_IP"
    
    local docker_cmd=$(get_docker_command)
    
    # Test Docker connection
    if ! $docker_cmd version >/dev/null 2>&1; then
        error "Cannot connect to Docker daemon at $DOCKER_HOST_IP:$DOCKER_HOST_PORT"
        error "Please verify:"
        error "1. Docker daemon is running on $DOCKER_HOST_IP"
        error "2. Network connectivity to $DOCKER_HOST_IP:$DOCKER_HOST_PORT"
        if [[ "$TLS_ENABLED" == "true" ]]; then
            error "3. TLS certificates are valid and accessible"
        fi
        exit 1
    fi
    
    local docker_version=$($docker_cmd version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
    log "✅ Connected to Docker daemon (version: $docker_version)"
    
    if [[ "$TLS_ENABLED" == "true" ]]; then
        info "🔐 Connection secured with TLS encryption"
    fi
}

###################################
# Check SSH key
###################################
check_ssh_key() {
    log "Validating SSH key configuration..."
    
    if [[ ! -f "$SSH_KEY_PATH" ]]; then
        error "SSH public key not found at $SSH_KEY_PATH"
        error "Generate SSH key pair:"
        error "  ssh-keygen -t rsa -b 4096 -f .ssh/jenkins_ssh_key -N \"\" -C \"jenkins-agent-key\""
        exit 1
    fi
    
    local private_key_path="${SSH_KEY_PATH%.*}"
    if [[ ! -f "$private_key_path" ]]; then
        warn "⚠️  Private key not found at $private_key_path"
    else
        log "✅ SSH key pair found"
    fi
}

###################################
# Create or verify network
###################################
setup_network() {
    local docker_cmd=$(get_docker_command)
    
    if [[ "$NETWORK_TYPE" == "host" ]]; then
        info "Using host networking (no custom network needed)"
        return 0
    fi
    
    log "Setting up Docker network: $NETWORK_NAME (type: $NETWORK_TYPE)"
    
    # Check if network exists
    if $docker_cmd network ls --format "{{.Name}}" | grep -q "^$NETWORK_NAME$"; then
        info "✅ Network $NETWORK_NAME already exists"
        return 0
    fi
    
    # Create network based on type
    case "$NETWORK_TYPE" in
        "macvlan")
            info "Creating macvlan network with subnet $MACVLAN_SUBNET"
            $docker_cmd network create -d macvlan \
                --subnet="$MACVLAN_SUBNET" \
                --gateway="$MACVLAN_GATEWAY" \
                -o parent="$MACVLAN_PARENT_INTERFACE" \
                "$NETWORK_NAME"
            ;;
        "bridge")
            info "Creating bridge network with subnet $BRIDGE_SUBNET"
            $docker_cmd network create -d bridge \
                --subnet="$BRIDGE_SUBNET" \
                --gateway="$BRIDGE_GATEWAY" \
                "$NETWORK_NAME"
            ;;
        "overlay")
            info "Creating overlay network with subnet $OVERLAY_SUBNET"
            $docker_cmd network create -d overlay \
                --subnet="$OVERLAY_SUBNET" \
                --gateway="$OVERLAY_GATEWAY" \
                --attachable \
                "$NETWORK_NAME"
            ;;
        *)
            error "Unsupported network type: $NETWORK_TYPE"
            exit 1
            ;;
    esac
    
    log "✅ Network $NETWORK_NAME created successfully"
}

###################################
# Clean up existing containers
###################################
cleanup() {
    log "Cleaning up existing Jenkins agent containers..."
    
    local docker_cmd=$(get_docker_command)
    
    for i in $(seq 1 $NUM_AGENTS); do
        local container_name="${AGENT_NAME_PREFIX}$i"
        if $docker_cmd ps -a --format "{{.Names}}" | grep -q "^$container_name$"; then
            log "Removing existing container: $container_name"
            $docker_cmd rm -f "$container_name" 2>/dev/null || true
        fi
    done
    
    log "✅ Cleanup completed"
}

###################################
# Build Docker image
###################################
build_image() {
    log "Building Docker image on remote host: $DOCKER_HOST_IP"
    
    local docker_cmd=$(get_docker_command)
    
    # Create build context
    BUILD_DIR=$(mktemp -d)
    
    if [[ ! -f "Dockerfile" ]]; then
        error "Dockerfile not found in current directory"
        exit 1
    fi
    
    cp Dockerfile "$BUILD_DIR/"
    mkdir -p "$BUILD_DIR/.ssh"
    cp "$SSH_KEY_PATH" "$BUILD_DIR/.ssh/"
    
    # Build image
    $docker_cmd build -t "$IMAGE_NAME" "$BUILD_DIR"
    
    # Cleanup
    rm -rf "$BUILD_DIR"
    
    log "✅ Docker image $IMAGE_NAME built successfully"
}

###################################
# Deploy agents
###################################
deploy_agents() {
    log "Deploying $NUM_AGENTS Jenkins SSH agent(s) with $NETWORK_TYPE networking..."
    
    local docker_cmd=$(get_docker_command)
    
    for i in $(seq 1 $NUM_AGENTS); do
        local container_name="${AGENT_NAME_PREFIX}$i"
        local agent_ip=$(calculate_agent_ip $i)
        local port_mapping=$(get_port_mapping $i)
        
        log "Creating $container_name..."
        
        # Build docker run command based on network type
        local run_cmd="$docker_cmd run --detach --name=$container_name --hostname=$container_name"
        
        # Add resource limits
        run_cmd="$run_cmd --memory=${AGENT_MEMORY_LIMIT:-1g} --cpus=${AGENT_CPU_LIMIT:-1.0}"
        
        # Add restart policy
        run_cmd="$run_cmd --restart=${AGENT_RESTART_POLICY:-unless-stopped}"
        
        # Add health check
        run_cmd="$run_cmd --health-cmd=\"ss -tuln | grep :22 || exit 1\" --health-interval=30s --health-timeout=10s --health-retries=3"
        
        # Add network configuration
        case "$NETWORK_TYPE" in
            "macvlan"|"bridge"|"overlay")
                run_cmd="$run_cmd --network=$NETWORK_NAME"
                if [[ "$agent_ip" != "host-network" ]]; then
                    run_cmd="$run_cmd --ip=$agent_ip"
                fi
                ;;
            "host")
                run_cmd="$run_cmd --network=host"
                ;;
        esac
        
        # Add port mapping for bridge networks
        if [[ -n "$port_mapping" ]]; then
            run_cmd="$run_cmd $port_mapping"
        fi
        
        # Add image name
        run_cmd="$run_cmd $IMAGE_NAME"
        
        # Execute the command
        eval "$run_cmd"
        
        # Wait for container to start
        sleep 3
        
        # Check container health
        local health_status=$($docker_cmd inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null || echo "unknown")
        if [[ "$health_status" == "healthy" ]] || [[ "$health_status" == "starting" ]]; then
            log "✅ $container_name is running (health: $health_status)"
        else
            warn "⚠️  $container_name health status: $health_status"
        fi
        
        # Test SSH connection for direct IP access
        if [[ "$NETWORK_TYPE" != "bridge" ]] && [[ "$agent_ip" != "host-network" ]]; then
            log "Testing SSH connection to $agent_ip..."
            if timeout 10 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "${SSH_KEY_PATH%.*}" jenkins@"$agent_ip" "echo 'SSH OK'" >/dev/null 2>&1; then
                log "✅ SSH connection successful to $container_name"
            else
                warn "⚠️  SSH connection failed to $container_name - may need time to initialize"
            fi
        fi
    done
}

###################################
# Show deployment information
###################################
show_info() {
    log "📊 Jenkins SSH Agents Status:"
    echo
    
    local docker_cmd=$(get_docker_command)
    
    # Show network configuration
    info "🌐 Network Configuration:"
    printf "  %-15s: %s\n" "Type" "$NETWORK_TYPE"
    printf "  %-15s: %s\n" "Name" "$NETWORK_NAME"
    
    case "$NETWORK_TYPE" in
        "macvlan")
            printf "  %-15s: %s\n" "Subnet" "$MACVLAN_SUBNET"
            printf "  %-15s: %s\n" "Gateway" "$MACVLAN_GATEWAY"
            ;;
        "bridge")
            printf "  %-15s: %s\n" "Subnet" "$BRIDGE_SUBNET"
            printf "  %-15s: %s\n" "Gateway" "$BRIDGE_GATEWAY"
            ;;
        "overlay")
            printf "  %-15s: %s\n" "Subnet" "$OVERLAY_SUBNET"
            printf "  %-15s: %s\n" "Gateway" "$OVERLAY_GATEWAY"
            ;;
        "host")
            printf "  %-15s: %s\n" "Mode" "Host networking"
            ;;
    esac
    
    echo
    printf "%-15s %-15s %-15s %-10s %-15s %-10s\n" "Container" "IP/Port" "Network" "SSH" "Status" "Health"
    printf "%-15s %-15s %-15s %-10s %-15s %-10s\n" "---------" "--------" "-------" "---" "------" "------"
    
    for i in $(seq 1 $NUM_AGENTS); do
        local container_name="${AGENT_NAME_PREFIX}$i"
        local agent_ip=$(calculate_agent_ip $i)
        local status=$($docker_cmd ps --format "{{.Status}}" --filter "name=^$container_name$" 2>/dev/null | head -1)
        local health=$($docker_cmd inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null || echo "none")
        
        # Determine connection info
        local connection_info
        case "$NETWORK_TYPE" in
            "bridge")
                local ssh_port=$((2200 + i))
                connection_info="$DOCKER_HOST_IP:$ssh_port"
                ;;
            "host")
                connection_info="$DOCKER_HOST_IP:22"
                ;;
            *)
                connection_info="$agent_ip"
                ;;
        esac
        
        if [[ -n "$status" ]]; then
            printf "%-15s %-15s %-15s %-10s %-15s %-10s\n" "$container_name" "$connection_info" "$NETWORK_TYPE" "22" "Running" "$health"
        else
            printf "%-15s %-15s %-15s %-10s %-15s %-10s\n" "$container_name" "$connection_info" "$NETWORK_TYPE" "22" "Stopped" "none"
        fi
    done
    
    echo
    log "🔗 SSH Connection Examples:"
    for i in $(seq 1 $NUM_AGENTS); do
        case "$NETWORK_TYPE" in
            "bridge")
                local ssh_port=$((2200 + i))
                echo "  ssh -i ${SSH_KEY_PATH%.*} -p $ssh_port jenkins@$DOCKER_HOST_IP"
                ;;
            "host")
                echo "  ssh -i ${SSH_KEY_PATH%.*} jenkins@$DOCKER_HOST_IP"
                ;;
            *)
                local agent_ip=$(calculate_agent_ip $i)
                echo "  ssh -i ${SSH_KEY_PATH%.*} jenkins@$agent_ip"
                ;;
        esac
    done
    
    echo
    log "🎯 Jenkins Node Configuration:"
    case "$NETWORK_TYPE" in
        "bridge")
            echo "  Host: $DOCKER_HOST_IP"
            echo "  Ports: $(for i in $(seq 1 $NUM_AGENTS); do echo -n "$((2200 + i))"; [[ $i -lt $NUM_AGENTS ]] && echo -n ", "; done)"
            ;;
        "host")
            echo "  Host: $DOCKER_HOST_IP"
            echo "  Port: 22"
            ;;
        *)
            echo "  Host IPs: $(for i in $(seq 1 $NUM_AGENTS); do echo -n "$(calculate_agent_ip $i)"; [[ $i -lt $NUM_AGENTS ]] && echo -n ", "; done)"
            echo "  Port: 22"
            ;;
    esac
    echo "  Username: jenkins"
    echo "  Private Key: ${SSH_KEY_PATH%.*}"
    
    echo
    log "🔐 Security Status:"
    if [[ "$TLS_ENABLED" == "true" ]]; then
        info "✅ Docker connection secured with TLS"
    else
        warn "⚠️  Docker connection is INSECURE"
    fi
    
    echo
    log "📋 Network Benefits:"
    case "$NETWORK_TYPE" in
        "macvlan")
            echo "  ✅ Direct IP access from any network device"
            echo "  ✅ No port forwarding needed"
            echo "  ✅ Containers appear as separate network devices"
            ;;
        "bridge")
            echo "  ✅ Isolated network environment"
            echo "  ✅ Port-based access control"
            echo "  ✅ Easy firewall configuration"
            ;;
        "overlay")
            echo "  ✅ Multi-host networking support"
            echo "  ✅ Docker Swarm integration"
            echo "  ✅ Service discovery"
            ;;
        "host")
            echo "  ✅ Maximum network performance"
            echo "  ✅ Direct host network access"
            echo "  ⚠️  Shared network namespace"
            ;;
    esac
}

###################################
# Show usage information
###################################
show_usage() {
    echo "Flexible Jenkins SSH Agent Management"
    echo "===================================="
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  start     - Build image and start all Jenkins agents (default)"
    echo "  stop      - Stop and remove all Jenkins agents"
    echo "  status    - Show current status of agents"
    echo "  restart   - Stop and restart all agents"
    echo "  build     - Build Docker image only"
    echo "  network   - Show network configuration"
    echo ""
    echo "Environment Variables:"
    echo "  CONFIG_FILE       - Configuration file path (default: ./network-config.env)"
    echo "  ENVIRONMENT       - Load environment config (DEV, STAGING, PROD)"
    echo "  DOCKER_HOST_IP    - Docker host IP"
    echo "  NETWORK_TYPE      - Network type (macvlan, bridge, overlay, host)"
    echo "  NUM_AGENTS        - Number of agents to create"
    echo "  TLS_ENABLED       - Enable TLS encryption (true/false)"
    echo ""
    echo "Examples:"
    echo "  $0 start                                    # Use default configuration"
    echo "  CONFIG_FILE=prod.env $0 start               # Use custom config file"
    echo "  ENVIRONMENT=DEV $0 start                    # Load DEV environment"
    echo "  NETWORK_TYPE=bridge NUM_AGENTS=3 $0 start   # Override specific settings"
    echo ""
    echo "Supported Network Types:"
    echo "  macvlan   - Direct network access (requires host interface)"
    echo "  bridge    - Docker bridge network (isolated, port-mapped)"
    echo "  overlay   - Docker Swarm overlay network (multi-host)"
    echo "  host      - Host networking (shares host network)"
}

###################################
# Main execution
###################################
main() {
    load_config
    
    case "${1:-start}" in
        "start")
            setup_docker_context
            check_ssh_key
            setup_network
            cleanup
            build_image
            deploy_agents
            show_info
            ;;
        "stop")
            setup_docker_context
            cleanup
            log "✅ All Jenkins agents stopped and cleaned up"
            ;;
        "status")
            setup_docker_context
            show_info
            ;;
        "restart")
            setup_docker_context
            cleanup
            build_image
            deploy_agents
            show_info
            ;;
        "build")
            setup_docker_context
            build_image
            ;;
        "network")
            log "📊 Network Configuration:"
            echo "  Type: $NETWORK_TYPE"
            echo "  Name: $NETWORK_NAME"
            case "$NETWORK_TYPE" in
                "macvlan")
                    echo "  Subnet: $MACVLAN_SUBNET"
                    echo "  Gateway: $MACVLAN_GATEWAY"
                    ;;
                "bridge")
                    echo "  Subnet: $BRIDGE_SUBNET"
                    echo "  Gateway: $BRIDGE_GATEWAY"
                    ;;
                "overlay")
                    echo "  Subnet: $OVERLAY_SUBNET"
                    echo "  Gateway: $OVERLAY_GATEWAY"
                    ;;
            esac
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
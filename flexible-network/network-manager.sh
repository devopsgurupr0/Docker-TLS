#!/bin/bash

###################################
# Flexible Network Manager for Jenkins SSH Agents
# Supports multiple network topologies and configurations
###################################

set -e

# Default configuration file
CONFIG_FILE="${CONFIG_FILE:-./network-config.env}"

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
    
    # Override with environment variables if set
    DOCKER_HOST_IP="${DOCKER_HOST_IP:-192.168.2.7}"
    DOCKER_HOST_PORT="${DOCKER_HOST_PORT:-2376}"
    NETWORK_TYPE="${NETWORK_TYPE:-macvlan}"
    NETWORK_NAME="${NETWORK_NAME:-jenkins_net}"
    NUM_AGENTS="${NUM_AGENTS:-1}"
    
    debug "Configuration loaded:"
    debug "  Docker Host: $DOCKER_HOST_IP:$DOCKER_HOST_PORT"
    debug "  Network Type: $NETWORK_TYPE"
    debug "  Network Name: $NETWORK_NAME"
    debug "  Number of Agents: $NUM_AGENTS"
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
    NUM_AGENTS="1"
    TLS_ENABLED="true"
    TLS_CERT_DIR="./docker-certs"
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
    
    if [[ -n "${!docker_host_var}" ]]; then
        DOCKER_HOST_IP="${!docker_host_var}"
        info "Using $env_prefix Docker host: $DOCKER_HOST_IP"
    fi
    
    if [[ -n "${!network_type_var}" ]]; then
        NETWORK_TYPE="${!network_type_var}"
        info "Using $env_prefix network type: $NETWORK_TYPE"
    fi
    
    if [[ -n "${!num_agents_var}" ]]; then
        NUM_AGENTS="${!num_agents_var}"
        info "Using $env_prefix agent count: $NUM_AGENTS"
    fi
    
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
# Create Docker network
###################################
create_network() {
    local docker_cmd=$(get_docker_command)
    
    log "Creating Docker network: $NETWORK_NAME (type: $NETWORK_TYPE)"
    
    # Check if network already exists
    if $docker_cmd network ls --format "{{.Name}}" | grep -q "^$NETWORK_NAME$"; then
        info "Network $NETWORK_NAME already exists"
        return 0
    fi
    
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
        "host")
            info "Using host networking (no custom network needed)"
            return 0
            ;;
        *)
            error "Unsupported network type: $NETWORK_TYPE"
            exit 1
            ;;
    esac
    
    log "✅ Network $NETWORK_NAME created successfully"
}

###################################
# Remove Docker network
###################################
remove_network() {
    local docker_cmd=$(get_docker_command)
    
    if [[ "$NETWORK_TYPE" == "host" ]]; then
        info "Host networking used, no network to remove"
        return 0
    fi
    
    log "Removing Docker network: $NETWORK_NAME"
    
    if $docker_cmd network ls --format "{{.Name}}" | grep -q "^$NETWORK_NAME$"; then
        $docker_cmd network rm "$NETWORK_NAME" || warn "Failed to remove network $NETWORK_NAME"
        log "✅ Network $NETWORK_NAME removed"
    else
        info "Network $NETWORK_NAME does not exist"
    fi
}

###################################
# Show network information
###################################
show_network_info() {
    local docker_cmd=$(get_docker_command)
    
    log "📊 Network Configuration:"
    echo
    printf "%-20s %-30s\n" "Parameter" "Value"
    printf "%-20s %-30s\n" "---------" "-----"
    printf "%-20s %-30s\n" "Network Type" "$NETWORK_TYPE"
    printf "%-20s %-30s\n" "Network Name" "$NETWORK_NAME"
    
    case "$NETWORK_TYPE" in
        "macvlan")
            printf "%-20s %-30s\n" "Subnet" "$MACVLAN_SUBNET"
            printf "%-20s %-30s\n" "Gateway" "$MACVLAN_GATEWAY"
            printf "%-20s %-30s\n" "Parent Interface" "$MACVLAN_PARENT_INTERFACE"
            printf "%-20s %-30s\n" "IP Range Start" "$MACVLAN_IP_RANGE_START"
            ;;
        "bridge")
            printf "%-20s %-30s\n" "Subnet" "$BRIDGE_SUBNET"
            printf "%-20s %-30s\n" "Gateway" "$BRIDGE_GATEWAY"
            printf "%-20s %-30s\n" "IP Range Start" "$BRIDGE_IP_RANGE_START"
            ;;
        "overlay")
            printf "%-20s %-30s\n" "Subnet" "$OVERLAY_SUBNET"
            printf "%-20s %-30s\n" "Gateway" "$OVERLAY_GATEWAY"
            ;;
        "host")
            printf "%-20s %-30s\n" "Mode" "Host networking"
            ;;
    esac
    
    echo
    log "🔗 Agent IP Addresses:"
    for i in $(seq 1 $NUM_AGENTS); do
        local agent_ip=$(calculate_agent_ip $i)
        printf "  %-15s -> %s\n" "${AGENT_NAME_PREFIX}$i" "$agent_ip"
    done
    
    echo
    if [[ "$NETWORK_TYPE" != "host" ]]; then
        log "🌐 Network Details:"
        if $docker_cmd network ls --format "{{.Name}}" | grep -q "^$NETWORK_NAME$"; then
            $docker_cmd network inspect "$NETWORK_NAME" --format "  Driver: {{.Driver}}"
            $docker_cmd network inspect "$NETWORK_NAME" --format "  Subnet: {{range .IPAM.Config}}{{.Subnet}}{{end}}"
            $docker_cmd network inspect "$NETWORK_NAME" --format "  Gateway: {{range .IPAM.Config}}{{.Gateway}}{{end}}"
        else
            warn "Network $NETWORK_NAME does not exist"
        fi
    fi
}

###################################
# Validate network configuration
###################################
validate_network_config() {
    log "🔍 Validating network configuration..."
    
    local errors=0
    
    # Validate Docker host connectivity
    local docker_cmd=$(get_docker_command)
    if ! $docker_cmd version >/dev/null 2>&1; then
        error "Cannot connect to Docker host $DOCKER_HOST_IP:$DOCKER_HOST_PORT"
        ((errors++))
    else
        info "✅ Docker host connectivity verified"
    fi
    
    # Validate network type
    case "$NETWORK_TYPE" in
        "macvlan"|"bridge"|"overlay"|"host")
            info "✅ Network type '$NETWORK_TYPE' is supported"
            ;;
        *)
            error "Unsupported network type: $NETWORK_TYPE"
            ((errors++))
            ;;
    esac
    
    # Validate subnet format
    case "$NETWORK_TYPE" in
        "macvlan")
            if [[ ! "$MACVLAN_SUBNET" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
                error "Invalid macvlan subnet format: $MACVLAN_SUBNET"
                ((errors++))
            fi
            ;;
        "bridge")
            if [[ ! "$BRIDGE_SUBNET" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
                error "Invalid bridge subnet format: $BRIDGE_SUBNET"
                ((errors++))
            fi
            ;;
        "overlay")
            if [[ ! "$OVERLAY_SUBNET" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
                error "Invalid overlay subnet format: $OVERLAY_SUBNET"
                ((errors++))
            fi
            ;;
    esac
    
    # Validate agent count
    if [[ ! "$NUM_AGENTS" =~ ^[0-9]+$ ]] || [[ "$NUM_AGENTS" -lt 1 ]] || [[ "$NUM_AGENTS" -gt 100 ]]; then
        error "Invalid number of agents: $NUM_AGENTS (must be 1-100)"
        ((errors++))
    fi
    
    if [[ $errors -eq 0 ]]; then
        log "✅ Network configuration validation passed"
        return 0
    else
        error "❌ Network configuration validation failed with $errors error(s)"
        return 1
    fi
}

###################################
# Generate network configuration template
###################################
generate_config_template() {
    local env_name="${1:-custom}"
    local config_file="network-config-${env_name}.env"
    
    log "Generating network configuration template: $config_file"
    
    cat > "$config_file" << EOF
# Network Configuration for $env_name Environment
# Generated on $(date)

###################################
# Docker Host Configuration
###################################
DOCKER_HOST_IP="192.168.1.100"
DOCKER_HOST_PORT="2376"
DOCKER_HOST_USER="root"

###################################
# Network Configuration
###################################
# Network type: macvlan, bridge, host, overlay
NETWORK_TYPE="bridge"
NETWORK_NAME="jenkins_${env_name}_net"

# For macvlan networks
MACVLAN_SUBNET="192.168.1.0/24"
MACVLAN_GATEWAY="192.168.1.1"
MACVLAN_PARENT_INTERFACE="eth0"
MACVLAN_IP_RANGE_START="50"

# For bridge networks
BRIDGE_SUBNET="172.20.0.0/16"
BRIDGE_GATEWAY="172.20.0.1"
BRIDGE_IP_RANGE_START="10"

# For overlay networks (Docker Swarm)
OVERLAY_SUBNET="10.0.9.0/24"
OVERLAY_GATEWAY="10.0.9.1"

###################################
# Agent Configuration
###################################
NUM_AGENTS="2"
AGENT_NAME_PREFIX="jenkins-agent"
AGENT_MEMORY_LIMIT="1g"
AGENT_CPU_LIMIT="1.0"
AGENT_RESTART_POLICY="unless-stopped"

###################################
# SSH Configuration
###################################
SSH_KEY_PATH="./.ssh/jenkins_ssh_key.pub"
SSH_PRIVATE_KEY_PATH="./.ssh/jenkins_ssh_key"
SSH_PORT="22"

###################################
# TLS Configuration
###################################
TLS_ENABLED="true"
TLS_CERT_DIR="./docker-certs"
TLS_VERIFY="true"
EOF
    
    log "✅ Configuration template created: $config_file"
    log "Edit this file to customize your network settings"
}

###################################
# Show usage information
###################################
show_usage() {
    echo "Flexible Network Manager for Jenkins SSH Agents"
    echo "==============================================="
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  create-network     - Create Docker network based on configuration"
    echo "  remove-network     - Remove Docker network"
    echo "  show-info         - Display network configuration and status"
    echo "  validate          - Validate network configuration"
    echo "  generate-config   - Generate configuration template"
    echo "  test-connectivity - Test network connectivity"
    echo ""
    echo "Environment Variables:"
    echo "  CONFIG_FILE       - Configuration file path (default: ./network-config.env)"
    echo "  ENVIRONMENT       - Load environment config (DEV, STAGING, PROD)"
    echo ""
    echo "Examples:"
    echo "  $0 create-network                    # Create network with default config"
    echo "  CONFIG_FILE=prod.env $0 create-network  # Use custom config file"
    echo "  ENVIRONMENT=DEV $0 show-info         # Load DEV environment settings"
    echo "  $0 generate-config staging           # Generate staging config template"
    echo ""
    echo "Supported Network Types:"
    echo "  macvlan   - Direct network access (requires host network interface)"
    echo "  bridge    - Docker bridge network (isolated, with port mapping)"
    echo "  overlay   - Docker Swarm overlay network (multi-host)"
    echo "  host      - Host networking (shares host network stack)"
}

###################################
# Test network connectivity
###################################
test_connectivity() {
    log "🧪 Testing network connectivity..."
    
    local docker_cmd=$(get_docker_command)
    
    # Test Docker connectivity
    if ! $docker_cmd version >/dev/null 2>&1; then
        error "❌ Cannot connect to Docker host"
        return 1
    fi
    
    info "✅ Docker host connectivity OK"
    
    # Test network existence
    if [[ "$NETWORK_TYPE" != "host" ]]; then
        if $docker_cmd network ls --format "{{.Name}}" | grep -q "^$NETWORK_NAME$"; then
            info "✅ Network $NETWORK_NAME exists"
            
            # Test network functionality with a temporary container
            log "Testing network functionality..."
            local test_container="network-test-$$"
            
            case "$NETWORK_TYPE" in
                "macvlan"|"bridge"|"overlay")
                    local test_ip=$(calculate_agent_ip 1)
                    if $docker_cmd run --rm --name "$test_container" --network "$NETWORK_NAME" --ip "$test_ip" alpine:latest ping -c 1 8.8.8.8 >/dev/null 2>&1; then
                        info "✅ Network connectivity test passed"
                    else
                        warn "⚠️  Network connectivity test failed (may be expected in some environments)"
                    fi
                    ;;
            esac
        else
            warn "⚠️  Network $NETWORK_NAME does not exist"
            log "Run '$0 create-network' to create it"
        fi
    else
        info "✅ Host networking configured"
    fi
}

###################################
# Main execution
###################################
main() {
    # Load environment-specific config if specified
    if [[ -n "$ENVIRONMENT" ]]; then
        load_config
        source_env_config "$ENVIRONMENT"
    else
        load_config
    fi
    
    case "${1:-help}" in
        "create-network")
            validate_network_config
            create_network
            show_network_info
            ;;
        "remove-network")
            remove_network
            ;;
        "show-info")
            show_network_info
            ;;
        "validate")
            validate_network_config
            ;;
        "generate-config")
            generate_config_template "$2"
            ;;
        "test-connectivity")
            test_connectivity
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
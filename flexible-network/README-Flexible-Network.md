# 🌐 Flexible Network Configuration for Jenkins SSH Agents

This directory provides a complete solution for deploying Jenkins SSH agents with **flexible network configurations**. Instead of hardcoded IP addresses and network settings, you can now easily adapt to different environments and network topologies.

## 🎯 **Problem Solved**

**Before**: Hardcoded network settings (192.168.2.x) that only work in specific environments  
**After**: Flexible, configurable network support for any environment

## 📁 **Files Overview**

| File | Purpose | Description |
|------|---------|-------------|
| `network-config.env` | Main Configuration | Default network settings and environment templates |
| `network-manager.sh` | Network Management | Create, manage, and validate Docker networks |
| `Docker-Agent-Flexible.sh` | Agent Deployment | Deploy agents with flexible network support |
| `Jenkinsfile-Flexible-Network` | Jenkins Pipeline | Pipeline with environment-aware network configuration |
| `environment-configs/` | Environment Configs | Pre-configured settings for dev/staging/prod |

## 🚀 **Quick Start**

### **1. Choose Your Network Type**

```bash
# Option 1: Macvlan (Direct IP access, like your original setup)
export NETWORK_TYPE="macvlan"
export MACVLAN_SUBNET="10.0.1.0/24"
export MACVLAN_GATEWAY="10.0.1.1"

# Option 2: Bridge (Isolated network with port mapping)
export NETWORK_TYPE="bridge"
export BRIDGE_SUBNET="172.20.0.0/16"

# Option 3: Host (Share host network)
export NETWORK_TYPE="host"

# Option 4: Overlay (Docker Swarm multi-host)
export NETWORK_TYPE="overlay"
export OVERLAY_SUBNET="10.0.9.0/24"
```

### **2. Deploy with Custom Network**

```bash
cd flexible-network/

# Make scripts executable
chmod +x *.sh

# Deploy with bridge network (easiest setup)
export NETWORK_TYPE="bridge"
export DOCKER_HOST_IP="your-docker-host-ip"
export NUM_AGENTS="3"
./Docker-Agent-Flexible.sh start
```

### **3. Use Environment-Specific Configs**

```bash
# Development environment
export CONFIG_FILE="environment-configs/dev.env"
./Docker-Agent-Flexible.sh start

# Staging environment
export CONFIG_FILE="environment-configs/staging.env"
./Docker-Agent-Flexible.sh start

# Production environment
export CONFIG_FILE="environment-configs/prod.env"
./Docker-Agent-Flexible.sh start
```

## 🌐 **Supported Network Types**

### **1. Macvlan Network** (Like your original setup)
```bash
NETWORK_TYPE="macvlan"
MACVLAN_SUBNET="192.168.2.0/24"
MACVLAN_GATEWAY="192.168.2.1"
MACVLAN_PARENT_INTERFACE="eth0"
```

**Benefits:**
- ✅ Direct IP access (192.168.2.50, 192.168.2.51, etc.)
- ✅ No port forwarding needed
- ✅ Containers appear as separate network devices

**Requirements:**
- Host network interface (eth0)
- Network administrator access
- Compatible with your existing setup

### **2. Bridge Network** (Recommended for flexibility)
```bash
NETWORK_TYPE="bridge"
BRIDGE_SUBNET="172.20.0.0/16"
BRIDGE_GATEWAY="172.20.0.1"
```

**Benefits:**
- ✅ Works in any environment
- ✅ No host network interface required
- ✅ Isolated network security
- ✅ Port-based access control

**Access:**
- SSH via host ports: `ssh -p 2201 jenkins@docker-host-ip`
- Agent 1: port 2201, Agent 2: port 2202, etc.

### **3. Host Network** (Maximum performance)
```bash
NETWORK_TYPE="host"
```

**Benefits:**
- ✅ Maximum network performance
- ✅ Direct host network access
- ✅ No network configuration needed

**Considerations:**
- ⚠️ Shares host network namespace
- ⚠️ Potential port conflicts

### **4. Overlay Network** (Multi-host Docker Swarm)
```bash
NETWORK_TYPE="overlay"
OVERLAY_SUBNET="10.0.9.0/24"
```

**Benefits:**
- ✅ Multi-host networking
- ✅ Docker Swarm integration
- ✅ Service discovery

**Requirements:**
- Docker Swarm cluster
- Swarm manager node

## 📋 **Environment Configurations**

### **Development Environment** (`dev.env`)
```bash
# Optimized for local development
DOCKER_HOST_IP="192.168.1.100"
NETWORK_TYPE="bridge"          # Easy setup, no host interface needed
NUM_AGENTS="1"                 # Single agent for development
TLS_ENABLED="false"            # Simplified for development
AGENT_MEMORY_LIMIT="512m"      # Lower resources
```

### **Staging Environment** (`staging.env`)
```bash
# Production-like testing
DOCKER_HOST_IP="10.0.1.50"
NETWORK_TYPE="macvlan"         # Production-like networking
NUM_AGENTS="3"                 # Multiple agents for testing
TLS_ENABLED="true"             # Security enabled
AGENT_MEMORY_LIMIT="1g"        # Standard resources
```

### **Production Environment** (`prod.env`)
```bash
# High availability production
DOCKER_HOST_IP="10.0.2.100"
NETWORK_TYPE="overlay"         # Multi-host support
NUM_AGENTS="10"                # High capacity
TLS_ENABLED="true"             # Full security
AGENT_MEMORY_LIMIT="2g"        # High performance
```

## 🔧 **Configuration Options**

### **Network Configuration**
```bash
# Network type selection
NETWORK_TYPE="macvlan|bridge|overlay|host"

# Macvlan settings
MACVLAN_SUBNET="192.168.2.0/24"
MACVLAN_GATEWAY="192.168.2.1"
MACVLAN_PARENT_INTERFACE="eth0"
MACVLAN_IP_RANGE_START="50"

# Bridge settings
BRIDGE_SUBNET="172.20.0.0/16"
BRIDGE_GATEWAY="172.20.0.1"
BRIDGE_IP_RANGE_START="10"

# Overlay settings
OVERLAY_SUBNET="10.0.9.0/24"
OVERLAY_GATEWAY="10.0.9.1"
```

### **Agent Configuration**
```bash
NUM_AGENTS="3"                    # Number of agents
AGENT_NAME_PREFIX="jenkins-agent" # Container name prefix
AGENT_MEMORY_LIMIT="1g"           # Memory limit per agent
AGENT_CPU_LIMIT="1.0"             # CPU limit per agent
AGENT_RESTART_POLICY="unless-stopped"
```

### **Docker Host Configuration**
```bash
DOCKER_HOST_IP="your-docker-host"
DOCKER_HOST_PORT="2376"
TLS_ENABLED="true"
TLS_CERT_DIR="./docker-certs"
```

## 🛠️ **Usage Examples**

### **Example 1: Bridge Network (Recommended)**
```bash
# Create configuration
cat > my-bridge-config.env << EOF
DOCKER_HOST_IP="10.0.1.100"
NETWORK_TYPE="bridge"
BRIDGE_SUBNET="172.25.0.0/16"
NUM_AGENTS="3"
TLS_ENABLED="true"
EOF

# Deploy agents
CONFIG_FILE="my-bridge-config.env" ./Docker-Agent-Flexible.sh start

# Connect to agents
ssh -p 2201 -i jenkins_ssh_key jenkins@10.0.1.100  # Agent 1
ssh -p 2202 -i jenkins_ssh_key jenkins@10.0.1.100  # Agent 2
ssh -p 2203 -i jenkins_ssh_key jenkins@10.0.1.100  # Agent 3
```

### **Example 2: Custom Macvlan Network**
```bash
# Create configuration for your network
cat > my-macvlan-config.env << EOF
DOCKER_HOST_IP="172.16.1.50"
NETWORK_TYPE="macvlan"
MACVLAN_SUBNET="172.16.1.0/24"
MACVLAN_GATEWAY="172.16.1.1"
MACVLAN_PARENT_INTERFACE="ens192"
MACVLAN_IP_RANGE_START="100"
NUM_AGENTS="5"
EOF

# Deploy agents
CONFIG_FILE="my-macvlan-config.env" ./Docker-Agent-Flexible.sh start

# Connect to agents (direct IP access)
ssh -i jenkins_ssh_key jenkins@172.16.1.100  # Agent 1
ssh -i jenkins_ssh_key jenkins@172.16.1.101  # Agent 2
# etc.
```

### **Example 3: Multi-Environment Deployment**
```bash
# Development
ENVIRONMENT="DEV" ./Docker-Agent-Flexible.sh start

# Staging
ENVIRONMENT="STAGING" ./Docker-Agent-Flexible.sh start

# Production
ENVIRONMENT="PROD" ./Docker-Agent-Flexible.sh start
```

## 🔍 **Network Management Commands**

### **Network Manager Tool**
```bash
# Create network
./network-manager.sh create-network

# Show network information
./network-manager.sh show-info

# Validate configuration
./network-manager.sh validate

# Test connectivity
./network-manager.sh test-connectivity

# Generate custom config
./network-manager.sh generate-config my-env
```

### **Agent Management**
```bash
# Deploy agents
./Docker-Agent-Flexible.sh start

# Show status
./Docker-Agent-Flexible.sh status

# Stop agents
./Docker-Agent-Flexible.sh stop

# Restart agents
./Docker-Agent-Flexible.sh restart

# Show network configuration
./Docker-Agent-Flexible.sh network
```

## 🔄 **Migration from Hardcoded Setup**

### **Step 1: Identify Your Current Network**
```bash
# If you're using 192.168.2.x with macvlan
NETWORK_TYPE="macvlan"
MACVLAN_SUBNET="192.168.2.0/24"
MACVLAN_GATEWAY="192.168.2.1"
```

### **Step 2: Create Compatible Configuration**
```bash
# Create config file matching your current setup
cat > migration-config.env << EOF
DOCKER_HOST_IP="192.168.2.7"
NETWORK_TYPE="macvlan"
MACVLAN_SUBNET="192.168.2.0/24"
MACVLAN_GATEWAY="192.168.2.1"
MACVLAN_PARENT_INTERFACE="eth0"
MACVLAN_IP_RANGE_START="50"
NUM_AGENTS="3"
TLS_ENABLED="true"
EOF
```

### **Step 3: Test Migration**
```bash
# Stop current agents
./Docker-Agent.sh stop

# Test with flexible script
CONFIG_FILE="migration-config.env" ./Docker-Agent-Flexible.sh start

# Verify same IPs are assigned
./Docker-Agent-Flexible.sh status
```

### **Step 4: Adapt to New Environment**
```bash
# Now easily change to different network
sed -i 's/192.168.2/10.0.1/g' migration-config.env
sed -i 's/MACVLAN_IP_RANGE_START="50"/MACVLAN_IP_RANGE_START="100"/g' migration-config.env

# Deploy to new network
CONFIG_FILE="migration-config.env" ./Docker-Agent-Flexible.sh restart
```

## 🎯 **Jenkins Pipeline Integration**

### **Use Flexible Pipeline**
```groovy
// Use the flexible network pipeline
pipeline {
    agent any
    
    parameters {
        choice(name: 'ENVIRONMENT', choices: ['DEV', 'STAGING', 'PROD'])
        choice(name: 'NETWORK_TYPE', choices: ['auto', 'macvlan', 'bridge', 'overlay'])
        string(name: 'NUM_AGENTS', defaultValue: '')
    }
    
    stages {
        stage('Deploy') {
            steps {
                // Pipeline automatically loads environment-specific config
                build job: 'flexible-network-deploy', parameters: [
                    choice(name: 'ENVIRONMENT', value: params.ENVIRONMENT),
                    choice(name: 'NETWORK_TYPE', value: params.NETWORK_TYPE),
                    string(name: 'NUM_AGENTS', value: params.NUM_AGENTS)
                ]
            }
        }
    }
}
```

## 📊 **Network Type Comparison**

| Feature | Macvlan | Bridge | Overlay | Host |
|---------|---------|--------|---------|------|
| **Setup Complexity** | Medium | Easy | Hard | Easy |
| **Network Isolation** | High | High | High | None |
| **Performance** | High | Medium | Medium | Highest |
| **Multi-host Support** | No | No | Yes | No |
| **Port Management** | None | Required | None | Shared |
| **Firewall Friendly** | Medium | High | Medium | Low |
| **Production Ready** | Yes | Yes | Yes | Depends |

## 🔐 **Security Considerations**

### **Network Security by Type**

**Macvlan:**
- ✅ Network isolation from host
- ✅ Direct firewall control
- ⚠️ Requires network interface access

**Bridge:**
- ✅ Complete network isolation
- ✅ Port-based access control
- ✅ Easy firewall configuration

**Overlay:**
- ✅ Encrypted inter-host communication
- ✅ Service discovery security
- ⚠️ Requires Swarm cluster security

**Host:**
- ⚠️ Shares host network namespace
- ⚠️ No network isolation
- ✅ Maximum performance

## 🎉 **Benefits of Flexible Network Configuration**

### **✅ Environment Portability**
- Deploy same setup across dev/staging/prod
- Adapt to different network topologies
- No hardcoded IP addresses

### **✅ Network Flexibility**
- Support multiple network types
- Easy migration between network modes
- Environment-specific optimizations

### **✅ Operational Efficiency**
- Single codebase for all environments
- Automated network configuration
- Consistent deployment process

### **✅ Security Options**
- Choose appropriate network isolation
- Environment-specific security settings
- TLS support across all network types

---

**🌐 Your Jenkins SSH agents can now adapt to any network environment!** No more hardcoded IP addresses or network-specific limitations.
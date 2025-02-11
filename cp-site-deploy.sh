#!/bin/bash
# =========================================================================== #
# Script Name:      cp-site-deploy.sh
# Description:      Automated PHP site creation for CloudPanel
# Version:          1.0.0
# Author:           OctaHexa Media LLC
# Last Modified:    2025-02-11
# Dependencies:     Debian 12, CloudPanel
#
# Installation:     Run this one-line command:
# wget -qO /tmp/cp-site-deploy.sh https://raw.githubusercontent.com/WPSpeedExpert/cp-site-deploy/main/cp-site-deploy.sh && bash /tmp/cp-site-deploy.sh
# =========================================================================== #

# Ensure the script is being downloaded and not run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" && "${0}" != "/tmp/cp-site-deploy.sh" ]]; then
    echo "This script should be run using:"
    echo "wget -qO /tmp/cp-site-deploy.sh https://raw.githubusercontent.com/WPSpeedExpert/cp-site-deploy/main/cp-site-deploy.sh && bash /tmp/cp-site-deploy.sh"
    exit 1
fi

# Cleanup function
cleanup() {
    rm -f /tmp/cp-site-deploy.sh
}

# Register cleanup function on script exit
trap cleanup EXIT

#===============================================
# 1. SCRIPT CONFIGURATION
#===============================================
# Exit on error, undefined vars, and pipe failures
set -euo pipefail

# Get server IP
SERVER_IP=$(curl -s ifconfig.me)

#===============================================
# 2. UTILITY FUNCTIONS
#===============================================

# 2.1. Logging Functions
#---------------------------------------
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

error_exit() {
    log_message "ERROR: $1"
    exit 1
}

# 2.2. Password Generation
#---------------------------------------
generate_password() {
    < /dev/urandom tr -dc 'A-Za-z0-9' | head -c24
}

# 2.3. PHP Version Detection
#---------------------------------------
get_php_versions() {
    local versions=()
    for dir in /etc/php/*; do
        if [[ -d "$dir" && "$dir" =~ ^/etc/php/[0-9]+\.[0-9]+$ ]]; then
            versions+=($(basename "$dir"))
        fi
    done
    printf '%s\n' "${versions[@]}" | sort -Vr
}

get_latest_php_version() {
    get_php_versions | head -n1
}

#===============================================
# 3. DOMAIN MANAGEMENT
#===============================================

# 3.1. Domain Validation
#---------------------------------------
validate_domain() {
    local domain=$1
    if [[ ! $domain =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        log_message "Invalid domain name: $domain"
        return 1
    fi
}

# 3.2. Site User Generation
#---------------------------------------
derive_siteuser() {
    local domain=$1
    local main_domain=$(echo "$domain" | awk -F. '{print $(NF-1)}')
    local subdomain=$(echo "$domain" | awk -F. '{print $1}')

    if [[ "$subdomain" == "www" || "$subdomain" == "$main_domain" ]]; then
        echo "$main_domain"
    else
        echo "$main_domain-$subdomain"
    fi
}

# 3.3. Domain Existence Check
#---------------------------------------
domain_exists() {
    local domain=$1
    local site_user=$(derive_siteuser "$domain")

    if clpctl site:list 2>/dev/null | grep -q "$domain" || \
       [ -f "/etc/nginx/sites-enabled/$domain.conf" ] || \
       [ -d "/etc/letsencrypt/live/$domain" ] || \
       [ -d "/home/$site_user/htdocs/$domain" ]; then
        return 0
    fi
    return 1
}

# 3.4. DNS Check
#---------------------------------------
check_dns() {
    local domain=$1
    local domain_ip=$(dig +short "$domain" | grep -v "\.$" | head -n1)

    if [ -z "$domain_ip" ]; then
        error_exit "No DNS record found for $domain"
    fi

    if [ "$domain_ip" != "$SERVER_IP" ]; then
        error_exit "DNS record for $domain ($domain_ip) does not match server IP ($SERVER_IP)"
    fi
}

#===============================================
# 4. CREDENTIALS MANAGEMENT
#===============================================

# 4.1. Generate Credentials File
#---------------------------------------
generate_credentials() {
    local domain=$1
    local site_user=$2
    local site_pass=$3
    local db_name=$4
    local db_user=$5
    local db_pass=$6
    local creds_file="/home/$site_user/site_credentials.txt"

    cat > "$creds_file" << EOF
Site ---------------------------
IP Address: $SERVER_IP
Domain Name: https://$domain
Site User: $site_user
Password: $site_pass

Database ---------------------------
Host: 127.0.0.1
Port: 3306
Database Name: $db_name
Database User Name: $db_user
Database User Password: $db_pass
------------------------------------

Installation Date: $(date '+%Y-%m-%d %H:%M:%S')
Document Root: /home/$site_user/htdocs/$domain
EOF

    chown "$site_user:$site_user" "$creds_file"
    chmod 600 "$creds_file"

    # Display credentials on screen
    echo "Copy the credentials for the site:"
    echo "----------------------------------------"
    cat "$creds_file"
    echo "----------------------------------------"
    echo "Credentials file saved to: $creds_file"
}

#===============================================
# 5. MAIN INSTALLATION FUNCTION
#===============================================

main_installation() {
    clear
    echo "========================================="
    echo "   CloudPanel Site Deployment"
    echo "========================================="
    echo ""

    # 5.1 PHP Version Selection
    #---------------------------------------
    local php_versions=($(get_php_versions))
    local latest_version=$(get_latest_php_version)
    
    echo "Available PHP versions:"
    local i=1
    for version in "${php_versions[@]}"; do
        echo "$i) PHP $version"
        ((i++))
    done
    
    read -p "Select PHP version (1-${#php_versions[@]}, default: 1 for PHP $latest_version): " php_choice
    
    if [[ -z "$php_choice" ]]; then
        PHP_VERSION=$latest_version
    else
        if [[ "$php_choice" =~ ^[0-9]+$ ]] && [ "$php_choice" -ge 1 ] && [ "$php_choice" -le "${#php_versions[@]}" ]; then
            PHP_VERSION="${php_versions[$((php_choice-1))]}"
        else
            error_exit "Invalid PHP version selection"
        fi
    fi

    # 5.2 Domain Input
    #---------------------------------------
    while true; do
        read -p "Enter domain (e.g., www.example.com): " domain
        if validate_domain "$domain"; then
            break
        fi
        echo "Invalid domain format. Please try again."
    done

    # 5.3 Domain Checks
    #---------------------------------------
    if domain_exists "$domain"; then
        error_exit "Domain $domain already exists"
    fi

    echo "Checking DNS records..."
    check_dns "$domain"

    # 5.4 Generate Credentials
    #---------------------------------------
    site_user=$(derive_siteuser "$domain")
    site_pass=$(generate_password)
    db_name=$site_user
    db_user=$site_user
    db_pass=$(generate_password)

    # 5.5 Create Site
    #---------------------------------------
    log_message "Creating PHP site for $domain..."

    # Create site in CloudPanel
    clpctl site:add:php \
        --domainName="$domain" \
        --phpVersion="$PHP_VERSION" \
        --vhostTemplate="Generic" \
        --siteUser="$site_user" \
        --siteUserPassword="$site_pass" \
        || error_exit "Failed to create site"

    # 5.6 Create Database
    #---------------------------------------
    log_message "Creating database..."
    clpctl db:add \
        --domainName="$domain" \
        --databaseName="$db_name" \
        --databaseUserName="$db_user" \
        --databaseUserPassword="$db_pass" \
        || error_exit "Failed to create database"

    # 5.7 Install SSL Certificate
    #---------------------------------------
    log_message "Installing SSL certificate..."
    clpctl lets-encrypt:install:certificate --domainName="$domain" \
        || error_exit "Failed to install SSL certificate"

    # 5.8 Generate Credentials File
    #---------------------------------------
    generate_credentials "$domain" "$site_user" "$site_pass" "$db_name" "$db_user" "$db_pass"

    # Cleanup
    log_message "Cleaning up temporary files..."
    cleanup

    return 0
}

#===============================================
# 6. SCRIPT EXECUTION
#===============================================

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    error_exit "Please run as root"
fi

# Check if CloudPanel is installed
if ! command -v clpctl &> /dev/null; then
    error_exit "CloudPanel is not installed"
fi

# Run main installation
main_installation

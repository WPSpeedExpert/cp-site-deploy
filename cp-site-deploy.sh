#!/bin/bash
# =========================================================================== #
# Script Name:      cp-site-deploy.sh
# Description:      Automated PHP site creation for CloudPanel
# Version:          1.2.1
# Author:           OctaHexa Media LLC
# Last Modified:    2025-04-03
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
# Allow script to continue on errors for DNS check
set +e  # Temporarily disable exit on error
trap 'set -e' RETURN  # Re-enable exit on error when function returns

# Get server IPs
SERVER_IPV4=$(curl -s4 ifconfig.me)
SERVER_IPV6=$(curl -s6 ifconfig.me)

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
    
    # Handle compound TLDs (.co.uk, .co.za, etc.)
    # Extract domain parts
    IFS='.' read -ra DOMAIN_PARTS <<< "$domain"
    local num_parts=${#DOMAIN_PARTS[@]}
    
    # Get subdomain (first part) and determine if it's www
    local subdomain=${DOMAIN_PARTS[0]}
    
    # Identify the main domain name part (excluding TLD)
    local main_domain=""
    
    # Handle compound TLDs with known patterns
    if (( num_parts >= 3 )) && [[ "${DOMAIN_PARTS[-2]}" == "co" || 
                                 "${DOMAIN_PARTS[-2]}" == "com" || 
                                 "${DOMAIN_PARTS[-2]}" == "org" || 
                                 "${DOMAIN_PARTS[-2]}" == "net" || 
                                 "${DOMAIN_PARTS[-2]}" == "gov" || 
                                 "${DOMAIN_PARTS[-2]}" == "edu" ]]; then
        # This is likely a compound TLD like .co.za, .co.uk, .com.au
        # Main domain is the third from the end
        main_domain=${DOMAIN_PARTS[num_parts-3]}
    else
        # Standard TLD, main domain is second from the end
        main_domain=${DOMAIN_PARTS[num_parts-2]}
    fi
    
    # Generate site user based on subdomain and main domain
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
        echo "⚠️  No DNS record found for $domain"
        echo ""
        echo "Please add DNS records in your DNS settings:"
        echo ""
        echo "Type: A"
        echo "Name: $domain"
        echo "Value: $SERVER_IPV4"
        echo ""
        if [ ! -z "$SERVER_IPV6" ]; then
            echo "For IPv6 (optional):"
            echo "Type: AAAA"
            echo "Name: $domain"
            echo "Value: $SERVER_IPV6"
            echo ""
        fi
        echo "Note: Only IPv4 record is sufficient"
        echo ""
        read -p "Press Enter to retry DNS check or Ctrl+C to exit..."
        check_dns "$domain"
    elif [ "$domain_ip" != "$SERVER_IPV4" ] && [ "$domain_ip" != "$SERVER_IPV6" ]; then
        echo "⚠️  Warning: DNS record mismatch detected"
        echo "Domain IP: $domain_ip"
        echo ""
        echo "If you're using Cloudflare Proxy (orange cloud), this is expected."
        echo "Otherwise, please update your DNS record:"
        echo ""
        echo "Type: A"
        echo "Name: $domain"
        echo "Value: $SERVER_IPV4"
        echo ""
        if [ ! -z "$SERVER_IPV6" ]; then
            echo "Type: AAAA"
            echo "Name: $domain"
            echo "Value: $SERVER_IPV6"
            echo ""
        fi
        echo "Note: Only IPv4 record is sufficient"
        echo ""
        while true; do
            read -p "Continue anyway? Only proceed if you're sure the DNS is correctly configured (y/N): " dns_override
            case $dns_override in
                [Yy]*)
                    log_message "Proceeding with installation despite DNS mismatch..."
                    return 0
                    ;;
                [Nn]*|"")
                    error_exit "DNS check failed and user aborted installation"
                    ;;
                *)
                    echo "Please answer y or n."
                    ;;
            esac
        done
    fi
    return 0
}

#===============================================
# 4. DATABASE MANAGEMENT
#===============================================

# 4.1. Create Database and User
#---------------------------------------
create_database() {
    local db_name=$1
    local db_user=$2
    local db_pass=$3

    log_message "Creating database and user..."
    
    clpctl db:add \
        --domainName="$domain" \
        --databaseName="$db_name" \
        --databaseUserName="$db_user" \
        --databaseUserPassword="$db_pass" \
        || error_exit "Failed to create database"
}

#===============================================
# 5. CREDENTIALS MANAGEMENT
#===============================================

# 5.1. Generate Credentials File
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
Site 
- - - - - - - - - - - - - -
IP Address IPv4: $SERVER_IPV4
IP Address IPv6: $SERVER_IPV6
Domain Name: https://$domain
Site User: $site_user
Password: $site_pass

Database 
- - - - - - - - - - - - - -
Host: 127.0.0.1
Port: 3306
Database Name: $db_name
Database User Name: $db_user
Database User Password: $db_pass
- - - - - - - - - - - - - -

Installation Date: $(date '+%Y-%m-%d %H:%M:%S')
Document Root: /home/$site_user/htdocs/$domain
EOF

    chown "$site_user:$site_user" "$creds_file"
    chmod 600 "$creds_file"

    # Display credentials on screen
    echo "Site Credentials"
    echo "- - - - - - - - - - - - - -"
    cat "$creds_file"
    echo ""
    echo "Credentials saved to: $creds_file"
}

#===============================================
# 6. MAIN INSTALLATION FUNCTION
#===============================================

main_installation() {
    clear
    echo "========================================="
    echo "   CloudPanel Site Deployment"
    echo "========================================="
    echo ""

    # 6.1 PHP Version Selection
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

    # 6.2 VHost Template Selection
    #---------------------------------------
    echo ""
    echo "Select VHost template:"
    echo "1) WordPress"
    echo "2) WooCommerce"
    echo "3) Generic PHP"
    echo "4) Show all available templates"
    read -p "Choose template (1-4, default: 1): " template_choice

    case ${template_choice:-1} in
        1) VHOST_TEMPLATE="WordPress" ;;
        2) VHOST_TEMPLATE="WooCommerce" ;;
        3) VHOST_TEMPLATE="Generic" ;;
        4)
            echo ""
            echo "Available templates:"
            echo "-------------------"
            clpctl vhost-templates:list
            echo ""
            read -p "Enter template name exactly as shown above: " VHOST_TEMPLATE
            if ! clpctl vhost-templates:list | grep -q "^| $VHOST_TEMPLATE "; then
                error_exit "Invalid template name"
            fi
            ;;
        *) error_exit "Invalid template selection" ;;
    esac
    
    # 6.3 Domain Input
    #---------------------------------------
    while true; do
        read -p "Enter domain (e.g., www.example.com): " domain
        if ! validate_domain "$domain"; then
            echo "Invalid domain format. Please try again."
            continue
        fi

        # Use our proven domain_exists check
        if domain_exists "$domain"; then
            echo ""
            echo "⚠️  Domain $domain already exists!"
            echo ""
            echo "Options:"
            echo "1) Abort installation (default)"
            echo "2) Enter different domain name"
            echo "3) Delete existing site and continue"
            read -p "Choose option (1-3, default: 1): " domain_choice
            
            case ${domain_choice:-1} in
                1|"")
                    error_exit "Installation aborted by user"
                    ;;
                2)
                    continue
                    ;;
                3)
                    log_message "Deleting existing site..."
                    if clpctl site:delete --domainName="$domain" --force; then
                        log_message "Existing site deleted successfully"
                        break
                    else
                        error_exit "Failed to delete existing site"
                    fi
                    ;;
                *)
                    echo "Invalid choice. Please try again."
                    continue
                    ;;
            esac
        else
            # Domain doesn't exist, proceed with installation
            break
        fi
    done

    # 6.4 SSL Certificate Option and DNS Check
    #---------------------------------------
    echo ""
    read -p "Install SSL certificate? (Y/n): " install_ssl
    case ${install_ssl:-y} in
        [Yy]*) 
            SKIP_SSL=false
            # DNS Check (only when installing SSL)
            echo "Checking DNS records..."
            check_dns "$domain"
            ;;
        [Nn]*) 
            SKIP_SSL=true
            log_message "SSL certificate installation will be skipped"
            echo "You can install the SSL certificate later using:"
            echo "clpctl lets-encrypt:install:certificate --domainName=$domain"
            echo ""
            ;;
        *) error_exit "Invalid choice" ;;
    esac

    # 6.5 Generate Credentials
    #---------------------------------------
    log_message "Starting site creation..."
    site_user=$(derive_siteuser "$domain")
    site_pass=$(generate_password)
    db_name=$site_user
    db_user=$site_user
    db_pass=$(generate_password)

    # 6.6 Create Site
    #---------------------------------------
    clpctl site:add:php \
        --domainName="$domain" \
        --phpVersion="$PHP_VERSION" \
        --vhostTemplate="$VHOST_TEMPLATE" \
        --siteUser="$site_user" \
        --siteUserPassword="$site_pass" \
        || error_exit "Failed to create site"

    # 6.7 Create Database
    #---------------------------------------
    log_message "Creating database..."
    create_database "$db_name" "$db_user" "$db_pass"
        
    # 6.8 Install SSL Certificate
    #---------------------------------------
    if [ "$SKIP_SSL" = true ]; then
        log_message "Skipping SSL certificate installation (user requested)"
    else
        log_message "Installing SSL certificate..."
        SSL_RESULT=$(clpctl lets-encrypt:install:certificate --domainName="$domain" 2>&1)
        if [[ $SSL_RESULT == *"Too Many Requests"* ]] || [[ $SSL_RESULT == *"rateLimited"* ]]; then
            log_message "WARNING: Let's Encrypt rate limit reached"
            echo ""
            echo "⚠️  SSL Certificate installation skipped due to Let's Encrypt rate limit"
            echo "This is a temporary restriction and will be lifted within 12-36 hours."
            echo "You can install the SSL certificate later using:"
            echo "clpctl lets-encrypt:install:certificate --domainName=$domain"
            echo ""
        elif [[ $SSL_RESULT == *"error"* ]]; then
            log_message "WARNING: SSL Certificate installation failed"
            echo ""
            echo "⚠️  SSL Certificate installation failed with error:"
            echo "$SSL_RESULT"
            echo ""
            echo "You can try to install the SSL certificate later using:"
            echo "clpctl lets-encrypt:install:certificate --domainName=$domain"
            echo ""
        fi
    fi

    # 6.9 Generate Credentials File
    #---------------------------------------
    generate_credentials "$domain" "$site_user" "$site_pass" "$db_name" "$db_user" "$db_pass"

    # 6.10 Cleanup and completion
    #---------------------------------------
    log_message "Cleaning up temporary files..."
    cleanup
    
    log_message "Installation completed successfully!"
    echo "Your site is ready at: https://$domain"
    return 0
}

#===============================================
# 7. SCRIPT EXECUTION
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

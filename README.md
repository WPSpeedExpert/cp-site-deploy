# CloudPanel Site Deployment Script

Automated PHP site creation script for CloudPanel. This script streamlines the process of creating new sites with CloudPanel, including database creation and SSL certificate installation.

## Quick Install

Copy and paste this command to install and run the script:

```bash
wget -qO /tmp/cp-site-deploy.sh https://raw.githubusercontent.com/WPSpeedExpert/cp-site-deploy/main/cp-site-deploy.sh && bash /tmp/cp-site-deploy.sh
```

## Prerequisites

- Debian 12
- CloudPanel installed
- Root access
- Valid DNS records pointing to your server
- Port 443 open for SSL certificate generation

## Features

- Automated PHP site creation
- Automatic database creation
- Let's Encrypt SSL certificate installation
- Smart site user naming convention
- PHP version selection
- DNS verification
- Secure 24-character password generation
- Comprehensive credentials file

## Site User Naming Convention

The script follows these naming conventions:

- Domain: www.example.com → Site User: example
- Domain: example.com → Site User: example
- Domain: staging.example.com → Site User: example-staging

## Generated Files

The script creates a credentials file at:
```
/home/[site-user]/site_credentials.txt
```

## Security Features

- Secure password generation (24 characters)
- Automatic SSL certificate installation
- Proper file permissions
- DNS verification before installation
- Clean temporary file removal

## Usage

1. Run the installation command
2. Select PHP version
3. Enter your domain name
4. Follow the prompts
5. Copy the generated credentials

## Support

For issues and feature requests, please use the GitHub issues tracker.

## License

GPL 3 License - See LICENSE file for details

## Author

OctaHexa Media LLC - [https://octahexa.com](https://octahexa.com)

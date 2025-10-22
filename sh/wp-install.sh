#!/bin/bash

# Function to display message
display_message() {
    echo "=========================================="
    echo "$1"
    echo "=========================================="
}

# Function to generate a random string for passwords and db usernames
generate_random_string() {
    length=$1
    openssl rand -base64 $length | tr -dc 'a-zA-Z0-9' | fold -w $length | head -n 1
}

# Prompt for domain and convert domain name for DB name (replace '.' with '_')
read -p "Enter your domain (e.g., www.koderstory.com or subdomain.example.com): " domain

# Check if domain starts with "www." and determine root domain
if [[ $domain == www.* ]]; then
    domain_without_www=$(echo "$domain" | sed 's/^www\.//')
    server_names="$domain_without_www www.$domain_without_www"
else
    # For other subdomains or domains without 'www', only register as it is
    domain_without_www=$domain
    server_names=$domain_without_www
fi

# Convert the domain to a valid DB name by replacing dots with underscores
db_name=$(echo "$domain_without_www" | tr '.' '_')
db_user="${db_name}_$(generate_random_string 8)"
db_password=$(generate_random_string 16)

# Prompt for PHP version, with default as PHP 7.4
read -p "Enter PHP version to install (e.g., 7.4, 8.0, 8.1, 8.2) [default is 8.2]: " php_version
php_version=${php_version:-8.2}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script as root."
    exit
fi

# Step 1: Install necessary libraries
display_message "Installing necessary libraries and dependencies..."
sudo apt update -y
sudo apt install -y nginx mariadb-server mariadb-client curl git zip unzip software-properties-common

# Add PHP PPA and install selected PHP version with extensions
display_message "Adding PHP PPA repository and installing PHP $php_version..."
sudo LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
sudo apt update -y

# Install PHP and required extensions, skipping php-json for PHP 8.x+
if [[ "$php_version" =~ ^8 ]]; then
    sudo apt install -y php${php_version} php${php_version}-fpm php${php_version}-mysql php${php_version}-cli php${php_version}-curl php${php_version}-zip php${php_version}-xml php${php_version}-mbstring php${php_version}-gd php${php_version}-soap php${php_version}-intl php${php_version}-bcmath php${php_version}-xmlrpc
else
    sudo apt install -y php${php_version} php${php_version}-fpm php${php_version}-mysql php${php_version}-cli php${php_version}-curl php${php_version}-zip php${php_version}-xml php${php_version}-mbstring php${php_version}-gd php${php_version}-soap php${php_version}-intl php${php_version}-bcmath php${php_version}-xmlrpc php${php_version}-json
fi

# Configure PHP settings for WordPress
display_message "Configuring PHP settings..."
sudo sed -i "s/upload_max_filesize = .*/upload_max_filesize = 64M/" /etc/php/${php_version}/fpm/php.ini
sudo sed -i "s/post_max_size = .*/post_max_size = 64M/" /etc/php/${php_version}/fpm/php.ini
sudo sed -i "s/memory_limit = .*/memory_limit = 256M/" /etc/php/${php_version}/fpm/php.ini
sudo sed -i "s/max_execution_time = .*/max_execution_time = 300/" /etc/php/${php_version}/fpm/php.ini

# Step 2: Set up MariaDB database for WordPress
display_message "Setting up MariaDB database and user..."
sudo systemctl start mariadb
sudo systemctl enable mariadb

# Secure MariaDB installation (optional)
#display_message "Securing MariaDB installation..."
#sudo mysql_secure_installation

# Check if the database already exists
db_exists=$(sudo mysql -e "SHOW DATABASES LIKE '${db_name}';" | grep "${db_name}")

if [ "$db_exists" ]; then
    display_message "Database ${db_name} already exists."
    read -p "Do you want to delete the existing database and create a new one? (y/n): " delete_db
    if [ "$delete_db" == "y" ]; then
        sudo mysql -e "DROP DATABASE ${db_name};"
        sudo mysql -e "CREATE DATABASE ${db_name};"
    else
        display_message "Skipping database creation."
    fi
else
    sudo mysql -e "CREATE DATABASE ${db_name};"
fi

# Create or update the database user
sudo mysql -e "CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_password}';"
sudo mysql -e "GRANT ALL PRIVILEGES ON ${db_name}.* TO '${db_user}'@'localhost';"
sudo mysql -e "FLUSH PRIVILEGES;"

# Step 3: Download and configure WordPress
display_message "Downloading and configuring WordPress..."
sudo curl -O https://wordpress.org/latest.tar.gz
sudo tar -xzf latest.tar.gz
sudo mkdir -p /var/www/$domain_without_www
sudo mv wordpress/* /var/www/$domain_without_www
sudo chown -R www-data:www-data /var/www/$domain_without_www
sudo chmod -R 755 /var/www/$domain_without_www

# Create WordPress wp-config.php
sudo mv /var/www/$domain_without_www/wp-config-sample.php /var/www/$domain_without_www/wp-config.php

# Update wp-config.php with database information
sudo sed -i "s/database_name_here/${db_name}/" /var/www/$domain_without_www/wp-config.php
sudo sed -i "s/username_here/${db_user}/" /var/www/$domain_without_www/wp-config.php
sudo sed -i "s/password_here/${db_password}/" /var/www/$domain_without_www/wp-config.php

# Step 4: Configure Nginx server block
display_message "Configuring Nginx for domain $server_names..."

sudo tee /etc/nginx/sites-available/$domain_without_www > /dev/null <<EOL
server {
    listen 80;
    server_name $server_names;
    root /var/www/$domain_without_www;
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php${php_version}-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOL

# Enable Nginx site and reload configuration
sudo ln -s /etc/nginx/sites-available/$domain_without_www /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx

# Step 5: Set up UFW Firewall
display_message "Configuring UFW firewall to allow Nginx traffic..."
sudo ufw allow 'OpenSSH'
sudo ufw allow 'Nginx Full'
sudo ufw enable

# Step 6: Install Certbot and obtain SSL certificate for the domain
display_message "Installing Certbot and generating SSL certificates using Let's Encrypt..."

# Install Certbot
sudo apt install certbot python3-certbot-nginx -y

# Obtain an SSL certificate with Certbot using your email
sudo certbot --nginx -d $domain_without_www  --non-interactive --agree-tos --email hello@koderstory.com

# Step 7: Reload Nginx to apply SSL
display_message "Reloading Nginx to apply SSL..."
sudo systemctl reload nginx

# Display the database credentials for WordPress
display_message "WordPress installed successfully!"
echo "Database Name: $db_name"
echo "Database User: $db_user"
echo "Database Password: $db_password"
echo "Please complete the WordPress installation by visiting: https://$domain_without_www or https://www.$domain_without_www"

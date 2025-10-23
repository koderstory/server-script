# 🚀 server-script-main

A curated collection of automation scripts for managing servers, databases, and web stacks — especially **Odoo**, **PostgreSQL**, **Django**, and **WordPress** environments.

**Total Scripts:** 17  

---

## 🧭 How to Use
- Click any script name below to open it directly.  
- Read the short description before running.  
- Use `bash <script>.sh --help` or open the file to see parameters.

---

## ⚙️ Scripts Overview

### 🗄️ Database Utilities

- **[sh/db-add.sh](server-script-main/sh/db-add.sh)**  
  ➕ Creates a new PostgreSQL database and user.  
  Accepts `<db_user> <db_name> <db_password>` arguments.  
  Automates `psql` commands to create and assign ownership — ideal for initial project setup.

- **[sh/db-del.sh](server-script-main/sh/db-del.sh)**  
  ❌ Drops a PostgreSQL database and/or user.  
  Uses `dropdb` and `dropuser` safely after checking existence.  
  Helps clean up test or old instances efficiently.

- **[sh/db-remote-setup.sh](server-script-main/sh/db-remote-setup.sh)**  
  🌐 Configures remote DB access.  
  Edits PostgreSQL `pg_hba.conf` and `postgresql.conf` to allow external connections.  
  Useful for multi-server Odoo deployments or remote database management.

- **[sh/db-restore.sh](server-script-main/sh/db-restore.sh)**  
  ♻️ Restores PostgreSQL databases from `.dump` or `.zip` files.  
  Handles decompression and loads data via `psql` or `pg_restore`.  
  Commonly used for Odoo backups or migration workflows.

---

### 🧩 Odoo Stack Management

- **[sh/odoo-install.sh](server-script-main/sh/odoo-install.sh)**  
  🧰 Installs a complete Odoo instance (Community or Enterprise).  
  Automates Python venv setup, dependency installs, Nginx configuration, and service creation.  
  Input: `<domain> <email> <user>`. Produces a running Odoo server ready for use.

- **[sh/odoo-config.sh](server-script-main/sh/odoo-config.sh)**  
  ⚙️ Generates or updates `odoo.conf` for any Odoo instance.  
  Sets parameters such as `addons_path`, `db_user`, and `db_password`.  
  Integrates seamlessly with the `odoo-service.sh` script.

- **[sh/odoo-nginx.sh](server-script-main/sh/odoo-nginx.sh)**  
  🌐 Configures Nginx as a reverse proxy for Odoo.  
  Creates server blocks, sets proxy routes, and enables SSL via Certbot.  
  Accepts `<domain> <http_port> <gevent_port> [--no-reload]`.

- **[sh/odoo-service.sh](server-script-main/sh/odoo-service.sh)**  
  🧱 Creates and enables a **systemd** service for Odoo.  
  Defines environment, restart policies, and log handling.  
  Usage: `<domain> <linux_user> [--odoo-root /opt/odoo/18/ce] [--no-start]`.

---

### 🐍 Python & Django Utilities

- **[sh/python-add.sh](server-script-main/sh/python-add.sh)**  
  🐍 Installs Python and essential packages.  
  Configures virtual environments and `pip` tools for isolated app setups.

- **[sh/django-install.sh](server-script-main/sh/django-install.sh)**  
  🧱 Automates Django installation and environment preparation.  
  Installs dependencies, initializes a project folder, and sets up the database link.

---

### 🖥️ Server Setup & Security

- **[sh/server-setup.sh](server-script-main/sh/server-setup.sh)**  
  ⚡ Full server setup utility.  
  Installs dependencies, Python, PostgreSQL, and configures Odoo or web apps.  
  Ideal for provisioning new VPS instances from scratch.

- **[sh/server-setup-db.sh](server-script-main/sh/server-setup-db.sh)**  
  🧩 Prepares database settings during server setup —  
  especially for remote-access configurations or staging environments.

- **[sh/server-secure.sh](server-script-main/sh/server-secure.sh)**  
  🔒 Hardens your server.  
  Sets up firewall rules, manages SSL certificates, and tightens SSH permissions.  
  Ensures basic security posture for production servers.

- **[sh/ssl.sh](server-script-main/sh/ssl.sh)**  
  🔐 Automates SSL certificate generation using Let’s Encrypt (Certbot).  
  Usage: `<domain> <email>`  
  Renews certificates and reloads Nginx automatically.

---

### 👥 User & CMS Utilities

- **[sh/user-add.sh](server-script-main/sh/user-add.sh)**  
  👤 Adds a new Linux user, sets permissions, and configures SSH keys.  
  Helps manage system-level users for developers or services.

- **[sh/user-del.sh](server-script-main/sh/user-del.sh)**  
  🗑️ Removes a Linux user and cleans up their home directory.  
  Usage: `<username>`  
  Includes basic sanity checks to avoid deleting system accounts.

- **[sh/wp-install.sh](server-script-main/sh/wp-install.sh)**  
  📰 Automates WordPress setup with database and SSL configuration.  
  Prepares MySQL/PostgreSQL, retrieves certificates, and deploys the CMS files.


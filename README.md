# Redis
sudo mkdir -p /etc/redis
sudo cp /usr/share/redis/redis.conf /etc/redis/redis.conf;
sudo nano /etc/redis/redis.conf
 * maxmemory 1024mb
 * maxmemory-policy: allkeys-lru
sudo systemctl restart redis-server

# Redis possible fix for when Redis can't read it's own config files - it may work without this, but it may not be able to do internal analysis if it fails well - I didn't fully understand this. It came from AI advice.
sudo chmod 755 /etc/redis/ && sudo chown root:root /etc/redis/ && sudo chmod 644 /etc/redis/redis.conf && sudo 
  chown root:root /etc/redis/redis.conf && sudo chmod 755 /var/lib/redis && sudo chown redis:redis /var/lib/redis &&
   sudo chmod 755 /var/log/redis && sudo chown redis:redis /var/log/redis && sudo mkdir -p /run/redis && sudo chown 
  redis:redis /run/redis && sudo chmod 755 /run/redis && echo "d /run/redis 0755 redis redis -" | sudo tee 
  /etc/tmpfiles.d/redis-server.conf && sudo systemctl restart redis-server




# PHP OPcache
$ sudo nano /etc/php/8.4/fpm/conf.d/10-opcache.ini

; configuration for php opcache module
; priority=10
zend_extension=opcache.so

; Enable OPcache
opcache.enable=1
opcache.enable_cli=0

; Memory settings
opcache.memory_consumption=128
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000

; Performance settings
opcache.revalidate_freq=0
opcache.validate_timestamps=0
opcache.fast_shutdown=1

; For production - disable timestamp validation (faster)
; Set validate_timestamps=1 if you want to check file changes (slower but useful in dev)
opcache.validate_timestamps=0

; JIT compiler (optional, can improve performance further)
opcache.jit=1255
opcache.jit_buffer_size=64M









sudo apt install pigz;
sudo apt install getmail6;

$ sudo apt-get install php8.4-sqlite3



TODO
SHOULD INCREASE MAX UPLOAD SIZE
SHOULD TURN ON OPCACHE
SHOULD INSTALL NAXSI


Base installation package:
sudo apt update;sudo apt install mariadb-server certbot python3-certbot-nginx zip htop sendmail nginx sshfs curl git ufw fail2ban nginx php8.4-fpm php8.4-mysql php8.4-mbstring php8.4-zip php8.4-intl php8.4-imagick php8.4-gd php8.4-curl php8.4-dom php8.4-xml php8.4-cli redis-server php8.4-redis postfix unzip logrotate net-tools awscli composer ffmpeg -y;

Install AWS CLI:
unzip awscliv2.zip
sudo ./aws/install
rm -rf aws awscliv2.zip





** For low RAM servers, need swap file to stop shit crashing when memory maxes out: **
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
sudo swapon -s
sudo nano /etc/fstab
	# add this new line to the end of the file to make it reload on reboot
	/swapfile none swap sw 0 0



Add custom 404 (and 500/502/503/504) page to Varnish block - see Pressabl

Shouldn't add root key to external server - found near beginning of instructions

sudo apt-get install s3cmd - for backup server

Gzip settings in nginx.conf need added
worker_processes  1; // equal to number of CPU's

RSYNC FROM OTHER SERVER:
sudo rsync -chavzP --stats ryan@109.74.195.197:/usr/share/nginx/html/wp-content/blogs.dir/ /mnt/volume-nyc1-01/wordpress.hellyer.kiwi/public_html/wp-content/blogs.dir/



For pressabl, daisy chain the letsencrypts together all at once
# sudo letsencrypt certonly -a webroot --webroot-path=/mnt/volume-nyc1-01/wordpress.hellyer.kiwi/public_html/ -d tweets.hellyer.kiwi -d wordpress.hellyer.kiwi


This is all screwed up. Varnish should be on another port (used 8081 on new Pressabl), not port 80.
Can use the following to switch Varnish ports
# sudo service varnish stop
# sudo varnishd -f /etc/varnish/user.vcl -s malloc,1G -a 0.0.0.0:8081
# sudo service varnish start

custom-exec.conf is also still on port 80 and needs changed

Also need to add port 80 block to nginx config so letsencrypt works and it redirects to https otherwise
Alos need to remove redirect for https from VCL stuff


CHANGES: MyNewPassword - needs var set
CHANGED ALREADY: Change "cgi.fix_pathinfo" to "0" and uncomment it's line for improved security.
Replace with "domain.txt". - should be domain.conf
Doesn't match password created earlier: wp core config --dbname=pressabl --dbuser=ryan --dbpass=PASSWORD --dbhost=localhost --dbprefix=test
Needs the quotes like this, so that funky passwords work, the double quotes failed ....wp core config --dbname=pressabl --dbuser=ryan --dbpass='ztdpaA7387!#' --dbhost=localhost --dbprefix=pressabl
Need vars for these ... wp core install --url=https://wordpress.hellyer.kiwi --title="Test Site" --admin_user=wordpressadmin --admin_password=wordpresspassword --admin_email=wordpress@gmail.com
Needed wp-content added to the path ... sudo chown www-data:www-data wp-content/uploads -R



# Things to do first
* Install Ubuntu 16.04 with public key authentication
* Point domain at new IP address
* MOUNT 20 GB DRIVE AND USE THAT INSTEAD OF /VAR/WWW/ - automatically mounts on reboot

Variables which need to be changed before using this tutorial:

Server details

	IPAddress
	/var/www/
	your_email@example.com
	ryanuser
	droplet3.hellyer.kiwi

SQL

	ryansqluser
	SQLRootPassword
	wordpressdb

External backup server

	external_server_username
	IPExternalAddress
	/external/server/path/

GitHub

	git@github.com:ryanhellyer/server-setup.git
	ryanhellyer@gmail.com"
	Ryan Hellyer
	githubrepo
	github@gmail.com
	githubusername

WordPress

	Test Site
	wordpressadmin
	wordpresspassword
	wordpress@gmail.com


Select defaults unless otherwise specified.

# Login as root
	ssh root@IPAddress

# Create public key and copy to external server (used for backing stuff up later)
Choose defaults (no password).

	ssh-keygen -t rsa -b 4096 -C "your_email@example.com"

Copy public key to the ~/.ssh/authorized_keys file on the external server

	cat ~/.ssh/id_rsa.pub

# Setup new user
Create new user, set their password, give them sudo priviledges and log in as them.

	adduser ryanuser # Create new user
	usermod -aG sudo ryanuser
	exit
	ssh ryanuser@IPAddress

Remove the need for a password when logging in as the new user. First we create the new SSH folder, then add our own public key (found on your local computer) to the authorized_keys file.

	mkdir ~/.ssh
	nano ~/.ssh/authorized_keys
	chmod 600 ~/.ssh/authorized_keys

Improve security by changing the line that specifies "PasswordAuthentication". uncomment it, then change its value to "no". Then reload the SSH daemon.

	sudo nano /etc/ssh/sshd_config

	sudo systemctl reload sshd

Confirm the new login works with no password before continuing.

	exit
	ssh ryanuser@IPAddress

# Adjust firewall settings
 Allow OpenSSH and enable UFW by selecting "y"

	sudo ufw allow OpenSSH
	sudo ufw enable

# Install Nginx
	sudo apt-get update
	sudo apt-get install nginx
	sudo ufw allow 'Nginx HTTP'

# Implement new Nginx configuration - copy default.txt
	sudo nano /etc/nginx/sites-available/default

# Setup Lets Encrypt
	sudo apt-get install letsencrypt
	sudo mkdir /var/www/droplet3.hellyer.kiwi/
	sudo mkdir /var/www/droplet3.hellyer.kiwi/public_html/
	sudo service nginx restart
	sudo letsencrypt certonly -a webroot --webroot-path=/var/www/droplet3.hellyer.kiwi/public_html/ -d droplet3.hellyer.kiwi

Generate Diffie Hellman group - takes a while!

	sudo openssl dhparam -out /etc/ssl/certs/dhparam.pem 2048

Copy from "ssl-domain.conf".

	sudo nano /etc/nginx/snippets/ssl-droplet3.hellyer.kiwi.conf

Copy from "ssl-params.conf".

	sudo nano /etc/nginx/snippets/ssl-params.conf


Removing default config now that we've obtained our TLS certificate

	sudo rm /etc/nginx/sites-available/default

Allow Nginx HTTPS through the firewall

	sudo ufw allow 'Nginx Full'

Reboot Nginx (PROBABLY NOT NECESSARY)

	sudo service nginx restart

# Install Varnish
Add Varnish repository to aptitude.

	curl https://repo.varnish-cache.org/ubuntu/GPG-key.txt | sudo apt-key add -
	sudo sh -c 'echo "deb https://repo.varnish-cache.org/ubuntu/ trusty varnish-4.0" >> /etc/apt/sources.list.d/varnish-cache.list'
	sudo apt-get update
	sudo apt-get install varnish

Change the port to "80" and manually set config file location to "user.vcl".
DAEMON_OPTS="-a :8081 \
-f /etc/varnish/user.vcl \

	sudo nano /etc/default/varnish

Copy "user.vcl".

	sudo nano /etc/varnish/user.vcl

Reboot Nginx

	sudo service nginx restart

	sudo mkdir /etc/systemd/system/varnish.service.d/

Copy "customexec.conf".

	sudo nano /etc/systemd/system/varnish.service.d/customexec.conf

Restart Varnish

	sudo systemctl daemon-reload
	sudo service varnish restart

# Setup automatic security updates
# should also add features from here: https://help.ubuntu.com/lts/serverguide/automatic-updates.html
Follow the prompts to enable automatic security upgrades.

	sudo apt-get install unattended-upgrades
	sudo dpkg-reconfigure -plow unattended-upgrades

# Install MariaDB
	sudo apt-get install mariadb-server

Set MariaDB root password

	sudo mysql -u root
	[mysql] use mysql;
	[mysql] update user set plugin='' where User='root'; # Forcing password usage
	[mysql] flush privileges;
	[mysql] SET PASSWORD FOR 'root'@'localhost' = PASSWORD('SQLRootPassword');

Create new database and add new user to it

	[mysql]CREATE DATABASE wordpressdb;
	[mysql]GRANT ALL PRIVILEGES ON wordpressdb.* To 'ryansqluser'@'localhost' IDENTIFIED BY 'MyNewPassword';
	[mysql] exit;

# Install PHP 7
Install PHP FPM and PHP MySQL and PHP mbstring

	sudo apt install php7.3-fpm php7.3-mysql php7.3-mbstring php7.3-zip php7.3-intl php7.3-imagick php7.3-gd php7.3-curl php7.3-dom php7.3-dom

Change "cgi.fix_pathinfo" to "0" for improved security.

	sudo nano /etc/php/7.3/fpm/php.ini

Replace existing files with "nginx.conf", "restrictions.conf" and "wordpress.conf"

	sudo mkdir /etc/nginx/global/
	sudo nano /etc/nginx/global/restrictions.conf
	sudo nano /etc/nginx/nginx.conf
	sudo nano /etc/nginx/global/wordpress.conf

Replace with "domain.txt".

	sudo nano /etc/nginx/sites-available/droplet3.hellyer.kiwi.conf

Softlink to enable the site

	sudo ln -s /etc/nginx/sites-available/droplet3.hellyer.kiwi.conf /etc/nginx/sites-enabled/droplet3.hellyer.kiwi.conf

# Install WP CLI (it'd be nice to setup auto-updating in future)
	cd /var/www/
	sudo curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
	sudo chmod +x wp-cli.phar
	sudo mv wp-cli.phar /usr/local/bin/wp

	sudo chown ryan:ryan droplet3.hellyer.kiwi/public_html/
	cd /var/www/droplet3.hellyer.kiwi/public_html/
	wp core download
	wp core config --dbname=wordpressdb --dbuser=ryansqluser --dbpass=PASSWORD --dbhost=localhost --dbprefix=test

Move wp-config.php outside of the web root

	sudo mv /var/www/droplet3.hellyer.kiwi/public_html/wp-config.php /var/www/droplet3.hellyer.kiwi/wp-config.php

Add "wp-config.php" to beginning of file.

	sudo nano /var/www/droplet3.hellyer.kiwi/wp-config.php

Install WordPress.

	wp core install --url=https://droplet3.hellyer.kiwi --title="Test Site" --admin_user=wordpressadmin --admin_password=wordpresspassword --admin_email=wordpress@gmail.com

Set permalinks.
	wp rewrite structure '/%postname%/'
	sudo chown www-data:www-data uploads -R

Set permissions and ownership

	sudo chown www-data:www-data wp-content/uploads -R
	sudo chmod 744 wp-content/uploads -R
#	sudo chmod 400 ../../wp-config.php - this is causing problems

# Install Redis
Install the Redis object cache. This results in a substantial improvement in the loading of dynamic WordPress pages.

	sudo apt-get install redis-server redis-tools php-redis
	wp plugin install wp-redis --activate
	mv wp-content/plugins/wp-redis/object-cache.php wp-content/object-cache.php
	sudo service php7.0-fpm restart

# Remove and add plugins
	wp plugin uninstall hello
	wp plugin uninstall akismet
	wp plugin install google-authenticator --activate

# Setup Cron jobs for WP CLI
Copy "wordpress-updates.sh".

	sudo nano /var/www/wordpress-updates.sh

# Backup stuff to external server
Copy "wordpress-backups.sh".

	sudo nano /var/www/wordpress-backups.sh

# Automate stuff
Copy "crontab.txt".

	sudo crontab -e

Copy "wp-cron.sh" and edit it's domain name
	sudo nano /var/www/wp-cron.sh

# Auto-deployment from GitHub
ssh-keygen -t rsa -b 4096 -C "ryanhellyer@gmail.com"

Copy to GitHub - https://github.com/settings/ssh

	cat ~/.ssh/id_rsa.pub

	git clone git@github.com:githubrepo/server-setup.git .
	git config --user.email "github@gmail.com"
	git config --user.name "githubusername"

Copy "auto-deployment.sh"

	sudo nano /mnt/volume-nyc1-01/auto-deployment.sh


# Install HTOP for performance analysis
sudo apt-get install htop

# Setup mail handling
sudo apt-get install sendmail

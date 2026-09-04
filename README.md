## Project documentation

For OS2Display 3.x development and upgrade work, see:

- [AGENTS.md](AGENTS.md)
- [OS2Display 3 architecture](docs/architecture/os2display-v3.md)
- [Upgrade runbook](docs/runbooks/upgrade-v2-to-v3.md)
- [Current project state](docs/ai/CURRENT_STATE.md)
- [Architecture decisions](docs/decisions/)

# OSdisplay
Os2display install profile without docker. If you are looking for the older (debrecated) docker setup go [here](https://github.com/os2display/os2display-docker-compose)

See usefull links and latest changes at the buttom of the readme file. 

## How to install OS2display (a valid domain is needed for SSL)
This installation has been tested for Debian 12 server version and Ubuntu 24.04 server version. 
Both should work on the Desktop version as well. 

### Installation needs
- Server: Debain 12 or Ubuntu 24.04
- Root or sudo access
- A valid dns name that points to the ip address of your server

### Installation - step 1 - Server components
Issue the commands below and the needed server components will be installed  

(You can copy and paste all commands - except sudo - in one copy past to a terminal - they will execute after each other)

```bash
sudo -s
rm -rf /var/setup.sh
wget -P /var https://raw.githubusercontent.com/os2display/os2display-standard-installation/main/scripts/setup.sh
chmod a+x /var/setup.sh
cd /var
./setup.sh
```

### Installation - step 2 - OS2display
Issue the commands below to install OS2display and follow the instructions

DB credentials are saved in /var/www/[your_domain]
```bash
cd /var/www/display
./INSTALL.sh your-domain
```

### Installation - step 3 - Using Lets encrypt - Certbot for SSL
Lets encrypt needs a valid domain. As does this installation. :-)

Lets encrypt could be blocked by your domain owner.

To install via lets encrypt with a valid domain for your server execute "certbot" and follow the instructions: 


```bash
certbot
```

### Installation - step 3 - Using your own SSL certificate for Apache webserver
- Download your pfx / p12 file to the server in /etc/apache2/ssl (must be created first - se below) - or copy the extract_certs.sh [link](https://github.com/os2display/os2display-standard-installation/raw/refs/heads/main/scripts/extract_certs.sh) to your local computer. The example will continue as if we are on the newly installed server
- Execute the script
  
```bash
mkdir /etc/apache2/ssl/
mkdir /etc/apache2/ssl/[your.domain.dk]
cd /etc/apache2/ssl
/var/www/display/scripts/extract_certs.sh [your_certificate_filename]
ln -s /etc/apache2/sites-available/[your.domain.dk]-ssl.conf /etc/apache2/sites-enabled/
apachectl configtest
apachectl graceful
```
Make sure that the webserver is running. If not have a look in /var/log/apache2/error.log

## Access to OS2display
The installation can be accessed via these URL's
- API: [your.domain.dk]/
- Client: [your.domain.dk]/client
- Admin: [your.domain.dk]/admin (use the user created from the installation)

### OS2display / symfony management
The INSTALL.sh scripts helps with creating a tenant, admin user, templates, screens and feeds. 
For help on creating more of these type ./INSTALL.sh display (Not implemented yet)

Also look at the install scripts in ./public_html

## Latest changes
https://os2web.atlassian.net/browse/S2DSPL-45

1. Get the right composer.json file when installing. (no prompt)
2. Removing bindings to vendor server
3. Removing bindings to vendor github repo
4. Better installation / fix of RSS feeds - added seperate install.sh for feeds
5. Fixing apt installation error regarding to PHP
6. Added ssl enabeling to apache and documention on setup of SSL without certbot - added cert generation script for apache and link for doing it for nginx

## TODO
1. Install Symfony as non root user - tried to install with plugins disabled but they are needed. 
2. Display help info in INSTALL.sh
3. Descruption on how to update - or make an update script.

## LINKS
- Symfony for Apache configuration: https://symfony.com/doc/current/setup/web_server_configuration.html
- Online page for manualy adding certificates to nginx and apache https://xy2z.io/posts/2020-pfx-certificates-nginx-apache2/

## Next release to look at:
https://os2display.github.io/display-docs/CHANGELOG.html#2024-08-14
 

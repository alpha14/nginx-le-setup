# Nginx Letsencrypt setup


This script helps creating pre-configured virtual hosts using let's encrypt.  
It forces https redirection by default.  

## Installation
First we need some dependencies (only tested on debian based distros)
```
apt install nginx
pip3 install certbot
```
Get in from git
```
git clone https://github.com/alpha14/nginx-le-setup
cd nginx-le-setup
```

## Usage
Example for setting up a static website
```
sudo ./nginx-le-setup.sh add --name example.com --directory /opt/website --email me@example.com
```
Example for setting up a service in reverse proxy
```
sudo ./nginx-le-setup.sh add --name example.com --proxy 8080 --email me@example.com
```
## Configuration file

A config file can be placed in **~/.nginx-le-setup** to avoid specifying some parameters
```
EMAIL="me@example.com"

WEBROOT_PATH="/data/letsencrypt"

# Additional HSTS directive
HSTS="includeSubDomains; preload"  
```

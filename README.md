# Nginx Letsencrypt setup

## Description

This script helps creating pre-configured virtual hosts using let's encrypt.  
It forces https redirection by default.  

## Dependencies
 A Debian based distro  
 nginx  
 certbot (letsencrypt package is deprecated)  

## Installation

Your nginx default servername must be configured to use this script  
Example of a default servername :
```
     server_name _;  
     location ~ /\.well-known/acme-challenge {  
        allow all;  
        default_type "text/plain";  
        root /path/to/webroot;  
     }  
```
## Configuration file

A config file can be placed in ~/.nginx-le-setup to avoid specifying some parameters
```
	EMAIL="me@example.com"  
	WEBROOT_PATH="/data/letsencrypt"  
	# Additional HSTS directive
	HSTS="includeSubDomains; preload"  

```

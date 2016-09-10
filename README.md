# Nginx Letsencrytp setup

## Description

This script helps creating pre-configured virtual hosts using let's encrypt.
It forces https redirection by default.

## Dependencies
 Debian based distro
 nginx
 certbot (letsencrypt package is deprecated)

## Installation

Your nginx default servername must be configured to use this script
Example of a default servername
"""
     server_name _;
     location ~ /\.well-known/acme-challenge {
        allow all;
        default_type "text/plain";
        root /path/to/webroot;
     }
"""
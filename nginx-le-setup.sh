#!/bin/bash
# Setup a virtual host with a let's encrypt certificate
#

if [ "$(id -u)" != "0" ]; then
    echo "This script requires root privileges."
    exit 1
fi

check_dependency() {
    if ! command -v "$1" 1>/dev/null; then
    echo "This script requires $1." && exit 1
    fi
}

check_dependency certbot
check_dependency nginx
check_dependency curl

NGINX_DIR="/etc/nginx"
HTTP2_MIN_VERSION=1.9.5
# Internal variables
CONFIRM=0
FORCE=0
BACKUP=0
HTTP2=""
HSTS=""
LE_ARGS=""
NGINX_VERSION=$(nginx -v 2>&1 | cut -d '/' -f 2)
# Get absolute path of the script
DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"

domains() {
    find "${NGINX_DIR}/sites-enabled" -print0 \
        | xargs -0 egrep '^(\s|\t)*server_name' \
        | sed -r 's/(.*server_name\s*|;)//g' | grep -v "localhost\|_"
}

config() {

    STATIC="root ${VPATH};
        location / { try_files \$uri \$uri/ =404; }"
    PROXY="location / {
        proxy_pass ${VPROXY};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forward-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forward-Proto http;
        proxy_set_header X-Nginx-Proxy true;
        proxy_redirect off;
    }"
}

version_gt() { test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"; }

if ! version_gt "$HTTP2_MIN_VERSION" "$NGINX_VERSION"; then
    HTTP2=" http2"
fi

#Check for a config file
if [ -f ~/.nginx-le-setup ];then
    . ~/.nginx-le-setup
fi

# render a template configuration file
# expand variables + preserve formatting
render_template() {
    eval "echo \"$(cat "$1")\""
}

error () {
    echo "try '$0 --help' for more information"
}

usage () {
    echo "Usage: $0 <add|list> <params>"
    echo -e "\nCreate/Add arguments\n"
    echo -e "  -n,     --name \t\tDomains or domains to configure (-n arg for each)"
    echo -e "  -d,     --directory \t\tWebsite directory"
    echo -e "  -p,     --proxy \t\tIP:Port or Port to forward"
    echo -e "  -e,     --email \t\tLets encrypt email"
    echo -e "  -wb,    --webroot-path \tPath to place the http challenge"
    echo -e "  -f,     --force \t\tForce the creation of the virtualhost"
    echo -e "  -y\t\t\t\tAssume Yes to all queries and do not prompt"
    echo -e "  --staging \t\t\tDo not issue a trusted certificate"
}

backup_conf() {
    if cp "${NGINX_DIR}/sites-available/${VNAME}" "${NGINX_DIR}/sites-available/${VNAME}.backup"; then
        BACKUP=1
    fi
}

restore_conf() {
    if [[ $BACKUP == 1 ]]; then
        mv "${NGINX_DIR}/sites-available/${VNAME}.backup" "${NGINX_DIR}/sites-available/${VNAME}"
    fi
}

delete_conf() {
    if [[ $BACKUP == 0 ]]; then
        unlink "${NGINX_DIR}/sites-enabled/${VNAME}"
        rm -v "${NGINX_DIR}/sites-available/${VNAME}"
    fi
}

create () {
    while [[ $# -gt 0 ]]
    do
        key="$1"
        case $key in
            -n|--name)
                if [[ -z "$VNAME" ]]; then VNAME="$2"; fi
                VDOMAINS+="$2 "
                shift
                ;;
            -d|--dir|--directory)
                VPATH=$(readlink --canonicalize "$2")
                shift
                ;;
            -p|--proxy)
                VPROXY="$2"
                shift
                ;;
            -e|--email)
                EMAIL="$2"
                shift
                ;;
            -wb|--webroot-path)
                WEBROOT_PATH=$(readlink --canonicalize "$2")
                shift
                ;;
            --staging)
                LE_ARGS+="--staging "
                ;;
            -y)
                CONFIRM=1
                ;;
            -f|--force)
                FORCE=1
                CONFIRM=1
                ;;
            *)
                # unknown option
                ;;
        esac
        shift # past argument or value
    done

    if [[ -z "$VNAME" ]]; then
        echo "--name required" && error && exit 1
    elif [[ -z "$VPATH" ]] && [[ -z "$VPROXY" ]]; then
        echo "Directory (-d) or proxy mode (-p) is required" && error && exit 1
    elif [[ -z "$EMAIL" ]]; then
        echo "Lets encrypt email is required" && error && exit 1
    elif [[ -n "$VPATH" ]] && [[ -n "$VPROXY" ]]; then
        echo "--proxy and --directory parameters are mutually exclusive" && error && exit 1
    else
        for domain in $(domains); do
            if [[ "${domain}" == "${VNAME}" ]]; then

                if [[ $FORCE == 0 ]]; then
                    echo "Error : Domain '${VNAME}' already listed in nginx virtual hosts"
                    exit 2;
                fi
                echo "Warning : Domain '${VNAME}' already listed in nginx virtual hosts"
            fi
        done
    fi

    # If a webroot path is not specified, use the directory path for classic cases
    # or default nginx directory in proxy mode
    if [[ -z "${WEBROOT_PATH}" ]]; then
        if [[ -z "$VPATH" ]]; then
            WEBROOT_PATH=${VPATH}
        elif [[ -z "$VPROXY" ]]; then
            WEBROOT_PATH="/usr/share/nginx/html"
        fi
    fi
    # If VPROXY contains only a port
    if [[ -n "$VPROXY" ]] && [[ "$VPROXY" == ?(-)+([0-9]) ]]; then
        VPROXY="http://localhost:${VPROXY}"
    fi
    # IF VPROXY doesnt start by http
    if [[ -n "$VPROXY" ]] && [[ "$VPROXY" != "http://"* ]];then
        VPROXY="http://${VPROXY}"
    fi

    if [[ -n "$VPATH" ]] && [[ ! -d "${VPATH}" ]]; then
        echo "Error : directory '${VPATH}' does not exists" && exit 3
    elif [[ ! -d "${WEBROOT_PATH}" ]]; then
        echo "Error : Webroot path '${WEBROOT_PATH}' does not exists" && exit 3
    elif [[ -n "$VPROXY" ]] && ! curl "${VPROXY}" &>/dev/null; then
        echo "Error : '${VPROXY}' is not valid or not up" && exit 3
    elif ! nginx -t; then
        echo "Error: Current nginx configuration is incorrect, aborting." && exit 10;
    else
        echo "Creating certs and vhost for '${VDOMAINS}'"
    fi

    if [ -n "${VPATH}" ]; then
        echo "Website path : ${VPATH}"
    else
        echo "Proxy to : ${VPROXY}"
    fi
    echo "Webroot path : ${WEBROOT_PATH}"

    if [[ $CONFIRM == 0 ]]; then
        echo -n "Is this ok?? [y/N]: "
        read -r continue
        if [[ ${continue} != "y" ]]; then
            echo "Opertion aborted" && exit 3;
        fi
    fi

    if [[ -e "${NGINX_DIR}/sites-available/${VNAME}" ]]; then
        echo "Creating a backup file in ${NGINX_DIR}/sites-available/"
        backup_conf
    fi
    # Place a simple vhost for the acme challenge
    echo -e "
        server {
    	  listen 80;
    	  server_name ${VDOMAINS};
    	  location ~ /\.well-known/acme-challenge {
    	  allow all;
    	  default_type \"text/plain\";
    	  root ${WEBROOT_PATH};
          }
        }
    " > "${NGINX_DIR}/sites-available/${VNAME}";

    if [ -e "${NGINX_DIR}/sites-enabled/${VNAME}" ]; then
	rm "${NGINX_DIR}/sites-enabled/${VNAME}"
    fi
    ln -s "${NGINX_DIR}/sites-available/${VNAME}" "${NGINX_DIR}/sites-enabled/${VNAME}"

    systemctl reload nginx;
    for domain in $VDOMAINS; do QUERY_DMNS+="-d $domain "; done
    echo "Creating certificate(s)...."
    # Creating cert
    # shellcheck disable=SC2086
    if ! certbot certonly ${LE_ARGS} --rsa-key-size 4096 --non-interactive \
         --agree-tos --keep --text --email "${EMAIL}" -a webroot \
         --expand --webroot-path="${WEBROOT_PATH}" ${QUERY_DMNS}; then
        echo "Error when creating cert, aborting..." &&
            delete_conf && restore_conf && exit 4
    fi

    config
    # Adding virtual host
    if [ -n "${VPATH}" ]; then
        echo "Adding vhost file (static)"
        CONFIG=${STATIC}
    else
        echo "Adding vhost file (proxy)"
        CONFIG=${PROXY}
    fi

    # Install the vhost
    render_template "${DIR}/base.template" > "${NGINX_DIR}/sites-available/${VNAME}"

    # Reload nginx
    if nginx -t; then
        systemctl reload nginx
        echo "${VDOMAINS} is now activated and working"
    else
        echo "nginx config verification failed, rollbacking.."
        delete_conf && restore_conf
    fi
}


update() {
    echo "Updating certificates"
    (certbot renew --rsa-key-size 4096 &&  systemctl reload nginx &&
         echo "Done") || echo "Error when updating certificates" && exit 5
}

key="$1"

case $key in
    list)
        for domain in $(domains); do echo "$domain"; done
        ;;
    create|add)
        shift
        create "$@"
        ;;
    update)
        update
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        # unknown option, redirect to "create" by default
        create "$@"
        ;;
esac

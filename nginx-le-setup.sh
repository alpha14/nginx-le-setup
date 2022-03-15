#!/bin/bash
# Setup a virtual host with a let's encrypt certificate
#

NGINX_DIR="/etc/nginx"
HTTP2_MIN_VERSION=1.9.5
# Internal variables
CONFIRM=0
FORCE=0
_BACKUP=0
HTTP2=""
# shellcheck disable=SC2034
HSTS=""
_CERBOT_EXTRA_ARGS=""
_CREATE_POST_HOOK=1
_POST_HOOK_DIR="/etc/letsencrypt/renewal-hooks/post"
_POST_HOOK_PATH="${_POST_HOOK_DIR}/nginx.sh"
_HOOK="#!/bin/bash\n# Nginx-le-setup\necho 'Reloading nginx'\n(nginx -t && nginx -s reload) 2>&1"

_version_gt() { test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"; }

_check_dependency() {
  if ! command -v "$1" 1>/dev/null; then
    echo "This script requires $1." && exit 1
  fi
}

# render a template configuration file
# expand variables + preserve formatting
_render_template() {
  eval "echo \"$(cat "$1")\""
}

_initial_checks() {

  if [ "$(id -u)" != "0" ]; then
    echo "This script requires root privileges."
    exit 1
  fi

  _check_dependency certbot
  _check_dependency nginx
  _check_dependency curl
}

_initialize_variables() {
  # Get absolute path of the script
  _DIR=$(dirname "$(realpath "$0")")

  _NGINX_VERSION=$(nginx -v 2>&1 | cut -d '/' -f 2)

  if _version_gt "${_NGINX_VERSION}" "${HTTP2_MIN_VERSION}"; then
    # shellcheck disable=SC2034
    HTTP2=" http2"
  fi

  # Check for a config file
  if [ -r ~/.nginx-le-setup ]; then
    # shellcheck source=/dev/null
    . ~/.nginx-le-setup
  fi

}

_create_certbot_hook() {

  _BYPASS_CHECK=${1:-0}

  if [[ "${_BYPASS_CHECK}" -eq 0 ]]; then
    if [[ "${_CREATE_POST_HOOK}" -eq 0 ]]; then
      echo "Skipping post hook installation" && return
    elif [[ -x "${_POST_HOOK_PATH}" ]]; then
      return
    fi
    echo "Certbot hook is not installed or not readable, installing it"
  fi

  if (echo -e "${_HOOK}" >"${_POST_HOOK_PATH}"); then
    echo "Error when deploying post hook in ${_POST_HOOK_DIR}"
    return
  fi
  chmod 755 "${_POST_HOOK_PATH}" && echo "Post hook deployed in ${_POST_HOOK_PATH}"

}

_domains() {
  find "${NGINX_DIR}/sites-enabled" "${NGINX_DIR}/conf.d" -type f,l -print0 |
    xargs -0 egrep '^(\s|\t)*server_name' |
    sed -r 's/(.*server_name\s*|;)//g' | uniq | grep -v "localhost\|_"
}

_error() {
  echo "try '$0 --help' for more information"
}

_usage() {
  echo "Usage: $0 <add|list|update|hook> <params>"
  echo -e "\nCreate/Add arguments\n"
  echo -e "  -n,     --name \t\tDomains or domains to configure (-n arg for each)"
  echo -e "  -d,     --directory \t\tWebsite directory"
  echo -e "  -p,     --proxy \t\tIP:Port or Port to forward"
  echo -e "  -e,     --email \t\tLets encrypt email"
  echo -e "  -wb,    --webroot-path \tPath to place the http challenge"
  echo -e "  --no-hook,             \tDo not install certbot post hook for nginx"
  echo -e "  -f,     --force \t\tForce the creation of the virtualhost"
  echo -e "  -y\t\t\t\tAssume Yes to all queries and do not prompt"
  echo -e "  --staging \t\t\tDo not issue a trusted certificate"
}

_backup_conf() {
  if cp "${NGINX_DIR}/sites-available/${VNAME}" "${NGINX_DIR}/sites-available/${VNAME}.backup"; then
    _BACKUP=1
  fi
}

_restore_conf() {
  if [[ ${_BACKUP} == 1 ]]; then
    mv "${NGINX_DIR}/sites-available/${VNAME}.backup" "${NGINX_DIR}/sites-available/${VNAME}"
  fi
}

_delete_conf() {
  if [[ ${_BACKUP} == 0 ]]; then
    unlink "${NGINX_DIR}/sites-enabled/${VNAME}"
    rm -v "${NGINX_DIR}/sites-available/${VNAME}"
  fi
}

_create() {

  while [[ $# -gt 0 ]]; do
    key="$1"
    case ${key} in
    -n | --name)
      if [[ -z "${VNAME}" ]]; then VNAME="$2"; fi
      VDOMAINS+="$2 "
      shift
      ;;
    -d | --dir | --directory)
      VPATH=$(readlink --canonicalize "${2}")
      shift
      ;;
    -p | --proxy)
      VPROXY="$2"
      shift
      ;;
    -e | --email)
      EMAIL="$2"
      shift
      ;;
    -wb | --webroot-path)
      WEBROOT_PATH=$(readlink --canonicalize "${2}")
      shift
      ;;
    --staging)
      _CERTBOT_EXTRA_ARGS+="--staging "
      ;;
    --no-hook)
      _CREATE_POST_HOOK=0
      ;;
    -y)
      CONFIRM=1
      ;;
    -f | --force)
      FORCE=1
      CONFIRM=1
      ;;
    *)
      # unknown option
      ;;
    esac
    shift # past argument or value
  done

  if [[ -z "${VNAME}" ]]; then
    echo "--name required" && _error && exit 1
  elif [[ -z "${VPATH}" ]] && [[ -z "${VPROXY}" ]]; then
    echo "Directory (-d) or reverse proxy mode (-p) is required" && _error && exit 1
  elif [[ -z "${EMAIL}" ]]; then
    echo "Lets encrypt email is required" && _error && exit 1
  elif [[ -n "${VPATH}" ]] && [[ -n "${VPROXY}" ]]; then
    echo "--proxy and --directory parameters are mutually exclusive" && _error && exit 1
  else
    for domain in $(_domains); do
      if [[ "${domain}" == "${VNAME}" ]]; then

        if [[ ${FORCE} == 0 ]]; then
          echo "Error : Domain '${VNAME}' already listed in nginx virtual hosts"
          echo "Add '--force' option to override"
          exit 2
        fi
        echo "Warning : Domain '${VNAME}' already listed in nginx virtual hosts"
      fi
    done
  fi

  # If a webroot path is not specified, use the directory path for classic cases
  # or default nginx directory in proxy mode
  if [[ -z "${WEBROOT_PATH}" ]]; then
    if [[ -n "${VPATH}" ]]; then
      WEBROOT_PATH=${VPATH}
    else
      WEBROOT_PATH="/var/www/html"
    fi
  fi
  # If VPROXY contains only a port
  if [[ -n "${VPROXY}" ]] && [[ "${VPROXY}" == ?(-)+([0-9]) ]]; then
    VPROXY=http://localhost:${VPROXY}
  fi
  # IF VPROXY doesnt start by http
  if [[ -n "${VPROXY}" ]] && [[ "${VPROXY}" != "http://"* ]]; then
    VPROXY=http://${VPROXY}
  fi

  if [[ -n "${VPATH}" ]] && [[ ! -d "${VPATH}" ]]; then
    echo "Error : directory '${VPATH}' does not exists" && exit 3
  elif [[ ! -d "${WEBROOT_PATH}" ]]; then
    echo "Error : Webroot path '${WEBROOT_PATH}' does not exists" && exit 3
  elif [[ -n "${VPROXY}" ]] && ! curl "${VPROXY}" &>/dev/null; then
    echo "Error : Upstream '${VPROXY}' is unreachable" && exit 3
  elif ! nginx -t; then
    echo "Error: Current nginx configuration is incorrect, aborting." && exit 10
  else
    echo "Creating certs and vhost for '${VDOMAINS}'"
  fi

  if [ -n "${VPATH}" ]; then
    echo "Website path : ${VPATH}"
  else
    echo "Proxy to : ${VPROXY}"
  fi
  echo "Webroot path : ${WEBROOT_PATH}"

  if [[ ${CONFIRM} == 0 ]]; then
    echo -n "Is this ok?? [y/N]: "
    read -r continue
    if [[ ${continue} != "y" ]]; then
      echo "Opertion aborted" && exit 3
    fi
  fi

  if [[ -e "${NGINX_DIR}/sites-available/${VNAME}" ]]; then
    echo "Creating a backup file in ${NGINX_DIR}/sites-available/"
    _backup_conf
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
    " >"${NGINX_DIR}/sites-available/${VNAME}"

  if [ -e "${NGINX_DIR}/sites-enabled/${VNAME}" ]; then
    rm "${NGINX_DIR}/sites-enabled/${VNAME}"
  fi
  ln -s "${NGINX_DIR}/sites-available/${VNAME}" "${NGINX_DIR}/sites-enabled/${VNAME}"

  nginx -s reload || (
    echo "Unable to interact with nginx, aborting.." &&
      _delete_conf && _restore_conf && exit 10
  )
  _create_certbot_hook

  for domain in ${VDOMAINS}; do _DOMAINS+="-d ${domain} "; done

  _HOOK_ARG=""
  if [[ "${_CREATE_POST_HOOK}" == 1 ]]; then _HOOK_ARG="--post-hook ${_POST_HOOK_PATH}"; fi

  echo "Creating certificate(s)...."
  # shellcheck disable=SC2086
  if ! certbot certonly ${_CERBOT_EXTRA_ARGS} --rsa-key-size 4096 --non-interactive --agree-tos --keep \
    --text --email "${EMAIL}" ${_HOOK_ARG} \
    -a webroot --expand --webroot-path="${WEBROOT_PATH}" ${_DOMAINS}; then
    echo "Error when creating cert, aborting..." &&
      _delete_conf && _restore_conf && exit 4
  fi

  # Adding virtual host
  if [ -n "${VPATH}" ]; then
    # shellcheck disable=SC2034
    CONFIG="root ${VPATH};
        location / { try_files \$uri \$uri/ =404; }"
  else
    # shellcheck disable=SC2034
    CONFIG="location / {
        proxy_pass ${VPROXY};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forward-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forward-Proto http;
        proxy_set_header X-Nginx-Proxy true;
        proxy_redirect off;
    }"
  fi

  # Install the vhost
  _render_template "${_DIR}/base.template" >"${NGINX_DIR}/sites-available/${VNAME}"

  # Reload nginx
  if (nginx -t && nginx -s reload); then
    echo "${VDOMAINS} is now activated and working"
  else
    echo "nginx config verification failed, rollbacking.."
    _delete_conf && _restore_conf
  fi
}

_update() {
  _create_certbot_hook
  echo "Updating certificates"
  (certbot renew --rsa-key-size 4096 && echo "Done") ||
    echo "Error when updating certificates" && exit 5
}

nginx-le-setup() {

  _initial_checks
  _initialize_variables

  key="$1"

  case ${key} in
  list)
    for domain in $(_domains); do echo "${domain}"; done
    ;;
  create | add)
    shift
    _create "$@"
    ;;
  update)
    _update
    ;;
  hook)
    _create_certbot_hook 1
    ;;
  -h | --help | help)
    _usage
    ;;
  *)
    # unknown option, redirect to help by default
    _usage
    ;;
  esac
}

if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
  export -f nginx-le-setup
else
  nginx-le-setup "${@}"
  exit $?
fi

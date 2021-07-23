#!/bin/sh
#
# Create a client host.
#
# Note: currently, this script only works when all the repositories
# are from the same organisation, and uses the same Stratum 0 and
# Stratum 1 hosts.
#
# Copyright (C) 2021, QCIF Ltd.
#================================================================

PROGRAM='cvmfs-client-setup'
VERSION='1.1.0'

EXE=$(basename "$0" .sh)
EXE_EXT=$(basename "$0")

#----------------------------------------------------------------
# Constants

# Default port for the proxy cache
DEFAULT_PROXY_PORT=3128

# Default cache size in MiB (should be between 4 GiB and 50 GiB)
DEFAULT_CACHE_SIZE_MB=4096  # 4 GiB

# Minimum value allowed for --size option in MiB
MIN_CACHE_SIZE_MB=1024 # 1 GiB

#----------------

# Header inserted into generated files
PROGRAM_INFO="Created by $PROGRAM $VERSION [$(date '+%F %T %Z')]"

#----------------------------------------------------------------
# Error handling

# Exit immediately if a simple command exits with a non-zero status.
# Better to abort than to continue running when something went wrong.
set -e

set -u # fail on attempts to expand undefined environment variables

#----------------------------------------------------------------
# Utility functions

# Internally, REPOS contains a list of repository specifications.
# These functions extract out the fully qualified repository name
# (FQRN), public key filename and organisation from a repository
# specification.

_fqrn() {
  echo "$1" | sed 's/:.*$//' # everything before first colon
}

_pubkey_file() {
  echo "$1" | sed 's/^[^:]*://' # everything after the first colon
}

_org_id() {
  _fqrn "$1" | sed -E 's/^[^\.]+\.//'
}

# Parse a command line argument into the repository ID and public key filename
# Prints out "repo_id:filename"

_canonicalise_repo() {
  ARG="$1"

  if echo "$ARG" | grep -q ':'; then
    # Has colon: value should be repository_id:filename (split on first colon)
    REPO_ID=$(echo "$ARG" | sed 's/:.*$'// )
    FILENAME=$(echo "$ARG" | sed 's/^[^:]*://' )
  else
    # No colon: repository ID is the base of the filename
    REPO_ID=$(basename "$ARG" .pub)
    FILENAME="$ARG"
  fi

  # Check syntax of fully qualified repository name

  ORG=$(echo "$REPO_ID" | sed -E 's/^[^\.]+\.//')
  if [ -z "$ORG" ]; then
    echo "$EXE: error: invalid fully qualified repository name: $REPO_ID" >&2
    exit 1
  fi
  if [ "$ORG" = "$REPO_ID" ] || [ ".$ORG" = "$REPO_ID" ] ; then
    echo "$EXE: error: invalid fully qualified repository name: $REPO_ID" >&2
    exit 1
  fi

  # Success

  echo "$REPO_ID:$FILENAME"
}

#----------------------------------------------------------------
# Command line arguments
# Note: parsing does not support combining single letter options (e.g. "-vh")

STRATUM_1_HOSTS=
CVMFS_HTTP_PROXY=
NO_GEO_API=
CVMFS_QUOTA_LIMIT_MB=$DEFAULT_CACHE_SIZE_MB
QUIET=
VERBOSE=
VERY_VERBOSE=
SHOW_VERSION=
SHOW_HELP=
REPOS=

while [ $# -gt 0 ]
do
  case "$1" in
    -1|--s1|--stratum1|--stratum-1)
      STRATUM_1_HOSTS="$STRATUM_1_HOSTS $2"
      shift; shift
      ;;
    -p|--proxy)
      if [ "$CVMFS_HTTP_PROXY" = 'DIRECT' ]; then
        echo "$EXE: usage error: do not provide proxies with --direct" >&2
        exit 2
      fi

      if echo "$2" | grep -q '^http://'; then
        echo "$EXE: usage error: expecting an address, not a URL: \"$2\"" >&2
        exit 2
      fi
      if echo "$2" | grep -q '^https://'; then
        echo "$EXE: usage error: expecting an address, not a URL: \"$2\"" >&2
        exit 2
      fi

      if echo "$2" | grep -q ':'; then
        # Value has a port number
        P="http://$2"
      else
        # Use default port number
        P="http://$2:$DEFAULT_PROXY_PORT"
      fi

      if [ -z "$CVMFS_HTTP_PROXY" ]; then
        CVMFS_HTTP_PROXY="$P"
      else
        CVMFS_HTTP_PROXY="$CVMFS_HTTP_PROXY;$P"
        # Note: ";" separates groups, "|" separates proxies in the same group.
        # This example setup treats each proxy as belonging to its own group.
      fi

      shift; shift
      ;;
    -d|--direct)
      if [ -n "$CVMFS_HTTP_PROXY" ]; then
        echo "$EXE: usage error: do not use --direct with proxies" >&2
        exit 2
      fi
      CVMFS_HTTP_PROXY=DIRECT
      shift
      ;;
    -n|--no-geo|--no-geo-api)
      if [ $# -lt 2 ]; then
        echo "$EXE: usage error: $1 missing value" >&2
        exit 2
      fi
      NO_GEO_API=yes
      shift
      ;;
    -c|--cache-size)
      if [ $# -lt 2 ]; then
        echo "$EXE: usage error: $1 missing value" >&2
        exit 2
      fi
      CVMFS_QUOTA_LIMIT_MB="$2"
      shift; shift
      ;;
    -q|--quiet)
      QUIET=yes
      shift
      ;;
    -v|--verbose)
      if [ -z "$VERBOSE" ]; then
        VERBOSE=yes
      else
        VERY_VERBOSE=yes
      fi
      shift
      ;;
    --version)
      SHOW_VERSION=yes
      shift
      ;;
    -h|--help)
      SHOW_HELP=yes
      shift
      ;;
    -*)
      echo "$EXE: usage error: unknown option: $1" >&2
      exit 2
      ;;
    *)
      # Argument

      REPOS="$REPOS $(_canonicalise_repo "$1")"

      shift
      ;;
  esac
done

if [ -n "$SHOW_HELP" ]; then
  cat <<EOF
Usage: $EXE_EXT [options] { REPO_FQRN.pub | REPO_FQRN:PUBKEY }
Options:
  -1 | --stratum-1 HOST     Stratum 1 replica (mandatory; repeat for each)
  -p | --proxy HOST[:PORT]  proxy server and optional port (repeat for each)*
  -d | --direct             no proxies, connect to Stratum 1 (not recommended)*
  -n | --no-geo-api         do not use Geo API (default: use Geo API)
  -c | --cache-size NUM     size of cache in MiB (default: $DEFAULT_CACHE_SIZE_MB)
  -q | --quiet              output nothng unless an error occurs
  -v | --verbose            output extra information when running
       --version            display version information and exit
  -h | --help               display this help and exit
REPO_FQRN: fully qualified repository name
PUBKEY: file containing the repository's public key
* = at least one --proxy or --direct is required

e.g. $EXE_EXT --stratum-1 s1.example.org --proxy p.example.org -n
       data.example.org.pub tools.example.org:pubkey.pub

EOF

  if [ -n "$VERBOSE" ]; then
    cat <<EOF
Reload repository:
  cvmfs_config reload repo.organization.tld

EOF
  fi

  exit 0
fi

if [ -n "$SHOW_VERSION" ]; then
  echo "$PROGRAM $VERSION"
  exit 0
fi

#----------------

if [ -z "$STRATUM_1_HOSTS" ]; then
  echo "$EXE: usage error: missing one or more --stratum-1 hosts" >&2
  exit 2
fi

if [ -z "$CVMFS_HTTP_PROXY" ]; then
  echo "$EXE: usage error: missing --direct or one or more --proxy" >&2
  exit 2
fi

if [ -z "$REPOS" ]; then
  echo "$EXE: usage error: missing repositories (-h for help)" >&2
  exit 2
fi

if ! echo "$CVMFS_QUOTA_LIMIT_MB" | grep -qE '^[0-9]+$'; then
  echo "$EXE: usage error: invalid number: \"$CVMFS_QUOTA_LIMIT_MB\"" >&2
  exit 2
fi
if [ "$CVMFS_QUOTA_LIMIT_MB" -lt $MIN_CACHE_SIZE_MB ]; then
  echo "$EXE: usage error: cache is too small: $CVMFS_QUOTA_LIMIT_MB MiB" >&2
  exit 2
fi

#----------------
# Checks

# Check that all the public key files exist

for REPO in $REPOS; do
  FILENAME=$(_pubkey_file $REPO)

  if [ ! -f "$FILENAME" ]; then
    echo "$EXE: usage error: file does not exist: \"$FILENAME\"" >&2
    exit 2
  fi
done

# Check repository is not already configured on this host

for REPO in $REPOS; do
  FULLNAME=$(_fqrn $REPO)

  # Assumption: if the repository has been configured, its public key
  # exists in the common/expected places.

  for FILE in "/etc/cvmfs/keys/$(_org_id $REPO)/${FULLNAME}.pub" \
                "/etc/cvmfs/keys/${FULLNAME}.pub"; do
    if [ -e "$FILE" ]; then
      echo "$EXE: error: repository already configured: $FULLNAME ($FILE)" >&2
      exit 1
    fi
  done

done

# Check all organisations are the same

COMMON_ORG=
for REPO in $REPOS; do
  if [ -z "$COMMON_ORG" ]; then
    COMMON_ORG=$(_org_id $REPO)
  elif [ "$COMMON_ORG" != "$(_org_id $REPO)" ]; then
    echo "$EXE: error: multiple organisations not supported" >&2
    exit 1
  fi
done

# TODO: can this script also check if the repository exists via the proxy?

#----------------------------------------------------------------
# Detect tested systems

if [ -f '/etc/system-release' ]; then
  # Fedora based
  DISTRO=$(head -1 /etc/system-release)
elif which lsb_release >/dev/null 2>&1; then
  # Debian based
  DISTRO="$(lsb_release --id --short) $(lsb_release --release --short)"
elif which uname >/dev/null 2>&1; then
  # Other
  DISTRO="$(uname -s) $(uname -r)"
else
  DISTRO=unknown
fi

if echo "$DISTRO" | grep -q '^CentOS Linux release 7'; then
  :
elif echo "$DISTRO" | grep -q '^CentOS Linux release 8'; then
  :
elif echo "$DISTRO" | grep -q '^CentOS Stream release 8'; then
  :
elif [ "$DISTRO" = 'Ubuntu 21.04' ]; then
  :
elif [ "$DISTRO" = 'Ubuntu 20.10' ]; then
  :
elif [ "$DISTRO" = 'Ubuntu 20.04' ]; then
  :
else
  # Add additional elif-statements for tested systems
  echo "$EXE: warning: untested system: $DISTRO" >&2
fi

#----------------------------------------------------------------
# Check for root privileges

if [ "$(id -u)" -ne 0 ]; then
  echo "$EXE: error: root privileges required" >&2
  exit 1
fi

#----------------------------------------------------------------
# Install CernVM-FS client

# Use LOG file to suppress apt-get messages, only show on error
# Unfortunately, "apt-get -q" and "yum install -q" still produces output.
LOG="/tmp/${PROGRAM}.$$"

#----------------
# Fedora functions

_yum_not_installed() {
  if rpm -q "$1" >/dev/null; then
    return 1 # already installed
  else
    return 0 # not installed
  fi
}

_yum_no_repo() {
  # CentOS 7 has yum 3.4.3: no --enabled option, output is "cernvm/7/x86_64..."
  # CentOS Stream 8 has yum 4.4.2: has --enabled option, output is "cernvm "
  #
  # So use old "enabled" argument instead of --enabled option and look for
  # slash or space after the repo name.

  if $YUM repolist enabled | grep -q "^$1[/ ]"; then
    return 1 # has enabled repo
  else
    return 0 # no enabled repo
  fi
}

_yum_install_repo() {
  # Install the CernVM-FS YUM repository (if needed)
  local REPO_NAME="$1"
  local URL="$2"

  if _yum_no_repo "$REPO_NAME"; then
    # Repository not installed

    _yum_install "$URL"

    if _yum_no_repo "$REPO_NAME"; then
      echo "$EXE: internal error: $URL did not install repo \"$REPO_NAME\"" >&2
      exit 3
    fi
  else
    if [ -z "$QUIET" ]; then
      echo "$EXE: repository already installed: $REPO_NAME"
    fi
  fi
}

_yum_install() {
  local PKG="$1"

  local PKG_NAME=
  if ! echo "$PKG" | grep -q /^https:/; then
    # Value is a URL: extract package name from it
    PKG_NAME=$(echo "$PKG" | sed 's/^.*\///') # remove everything up to last /
    PKG_NAME=$(echo "$PKG_NAME" | sed 's/\.rpm$//') # remove .rpm
  else
    # Assume the entire value is the package name
    PKG_NAME="$PKG"
  fi

  if ! rpm -q $PKG_NAME >/dev/null ; then
    # Not already installed

    if [ -z "$QUIET" ]; then
      echo "$EXE: $YUM install: $PKG"
    fi

    if ! $YUM install -y $PKG >$LOG 2>&1; then
      cat $LOG
      rm $LOG
      echo "$EXE: error: $YUM install: $PKG failed" >&2
      exit 1
    fi
    rm $LOG

  else
    if [ -z "$QUIET" ]; then
      echo "$EXE: package already installed: $PKG"
    fi
  fi
}

#----------------
# Debian functions

_dpkg_not_installed() {
  if dpkg-query -s "$1" >/dev/null 2>&1; then
    return 1 # already installed
  else
    return 0 # not installed
  fi
}

_dpkg_download_and_install() {
  # Download a Debian file from a URL and install it.
  local PKG_NAME="$1"
  local URL="$2"

  if _dpkg_not_installed "$PKG_NAME"; then
    # Download it

    if [ -z "$QUIET" ]; then
      echo "$EXE: downloading $URL"
    fi

    DEB_FILE="/tmp/$(basename "$URL").$$"

    if ! wget --quiet -O "$DEB_FILE" $URL; then
      rm -f "$DEB_FILE"
      echo "$EXE: error: could not download: $URL" >&2
      exit 1
    fi

    # Install it

    if [ -z "$QUIET" ]; then
      echo "$EXE: dpkg installing download file"
    fi

    if ! dpkg --install "$DEB_FILE" >$LOG 2>&1; then
      cat $LOG
      rm $LOG
      echo "$EXE: error: dpkg install failed" >&2
      exit 1
    fi

    rm -f "$DEB_FILE"

    if _dpkg_not_installed "$PKG_NAME"; then
      # The package from the URL did not install the expected package
      echo "$EXE: internal error: $URL did not install $PKG_NAME" >&2
      exit 3
    fi

  else
    if [ -z "$QUIET" ]; then
      echo "$EXE: repository already installed: $REPO_NAME"
    fi
  fi
}

_apt_get_update() {
  if [ -z "$QUIET" ]; then
    echo "$EXE: apt-get update"
  fi

  if ! apt-get update >$LOG 2>&1; then
    cat $LOG
    rm $LOG
    echo "$EXE: error: apt-get update failed" >&2
    exit 1
  fi
}

_apt_get_install() {
  local PKG="$1"

  if _dpkg_not_installed "$PKG" ; then
    # Not already installed: install it

    if [ -z "$QUIET" ]; then
      echo "$EXE: apt-get install $PKG"
    fi

    if ! apt-get install -y "$PKG" >$LOG 2>&1; then
      cat $LOG
      rm $LOG
      echo "$EXE: error: apt-get install cvmfs failed" >&2
      exit 1
    fi
    rm $LOG

  else
    if [ -z "$QUIET" ]; then
      echo "$EXE: package already installed: $PKG"
    fi
  fi
}

#----------------
# Install for either Fedora or Debian based distributions

YUM=yum
if which dnf >/dev/null 2>&1; then
  YUM=dnf
fi

if which $YUM >/dev/null 2>&1; then
  # Installing for Fedora based distributions

  if _yum_not_installed 'cvmfs'; then

    _yum_install_repo 'cernvm' \
      https://ecsft.cern.ch/dist/cvmfs/cvmfs-release/cvmfs-release-latest.noarch.rpm

    _yum_install cvmfs

  else
    if [ -z "$QUIET" ]; then
      echo "$EXE: package already installed: cvmfs"
    fi
  fi

elif which apt-get >/dev/null 2>&1; then
  # Installing for Debian based distributions

  if _dpkg_not_installed 'cvmfs' ; then

    _dpkg_download_and_install 'cvmfs-release' \
      https://ecsft.cern.ch/dist/cvmfs/cvmfs-release/cvmfs-release-latest_all.deb

    _apt_get_update

    _apt_get_install cvmfs

  else
    if [ -z "$QUIET" ]; then
      echo "$EXE: package already installed: cvmfs"
    fi
  fi

else
  echo "$EXE: unsupported distribution: no apt-get, yum or dnf" >&2
  exit 3
fi

#----------------------------------------------------------------
# Configure CernVM-FS

#----------------
# Calculate CVMFS_SERVER_URL with all the Stratum 1 replica hosts

CVMFS_SERVER_URL=
for S1_HOST in $STRATUM_1_HOSTS; do
  URL="http://${S1_HOST}/cvmfs/@fqrn@"
  if [ -z "$CVMFS_SERVER_URL" ]; then
    CVMFS_SERVER_URL=$URL
  else
    CVMFS_SERVER_URL="$CVMFS_SERVER_URL;$URL"
  fi
done

# TODO: this does not work if there are multiple organisations.

#----------------
# Create the organisation config file(s)

for REPO in $REPOS; do
  ORG=$(_org_id $REPO)

  FILE=/etc/cvmfs/domain.d/${ORG}.conf

  if [ ! -e "$FILE" ]; then
    # Create organisation config file

    if [ -z "$QUIET" ]; then
      echo "$EXE: configuring organisation: $FILE"
    fi

    ORG_KEY_DIR="/etc/cvmfs/keys/$(_org_id $REPO)"

    cat > "$FILE" <<EOF
# CVMFS repository configuration: $ORG
# $PROGRAM_INFO

CVMFS_SERVER_URL="$CVMFS_SERVER_URL"
CVMFS_KEYS_DIR="$ORG_KEY_DIR"
EOF
  else
    if [ -n "$VERY_VERBOSE" ]; then
      echo "$EXE: organisation already configured: $FILE"
    fi
  fi
done

#----------------
# Add public keys to the organisation's key directory

for REPO in $REPOS; do
  FULLNAME=$(_fqrn $REPO)

  ORG_KEY_DIR="/etc/cvmfs/keys/$(_org_id $REPO)"

  if [ ! -e "$ORG_KEY_DIR" ]; then
    if ! mkdir "$ORG_KEY_DIR"; then
      echo "$EXE: error: could not create directory: $ORG_KEY_DIR" >&2
      exit 1
    fi
  fi

  REPO_PUBKEY_FILE="${ORG_KEY_DIR}/${FULLNAME}.pub"
  if [ -z "$QUIET" ]; then
    echo "$EXE: public key for repository: $REPO_PUBKEY_FILE"
  fi

  cp "$(_pubkey_file $REPO)" "$REPO_PUBKEY_FILE"
  chmod 644 "$REPO_PUBKEY_FILE"

  # TODO: what about configuring /etc/cvmfs/config.d/${FULLNAME}.conf?
done

#----------------------------------------------------------------
# The local defaults file

FILE="/etc/cvmfs/default.local"

NEW_IDS=
for REPO in $REPOS; do
  FULLNAME=$(_fqrn $REPO)

  if [ -z "$NEW_IDS" ]; then
    NEW_IDS="${FULLNAME}"
  else
    NEW_IDS="${NEW_IDS},${FULLNAME}"
  fi
done

if [ ! -f "$FILE" ] ; then
  CVMFS_REPOSITORIES="$NEW_IDS" # no previously configured repositories
else
  EXISTING_REPOS=$(grep CVMFS_REPOSITORIES /etc/cvmfs/default.local | \
                     sed 's/^CVMFS_REPOSITORIES=\(.*\)/\1/')
  CVMFS_REPOSITORIES="${EXISTING_REPOS},${NEW_IDS}" # append new repositories
fi

if [ -z "$QUIET" ]; then
  echo "$EXE: configuring: $FILE"
fi

GEO='CVMFS_USE_GEOAPI=yes  # sort servers by geographic distance from client'
if [ -n "$NO_GEO_API" ]; then
  GEO="# $GEO"
fi

cat > "$FILE" <<EOF
# CVMFS default.local
# $PROGRAM_INFO

# CVMFS_HTTP_PROXY
#
# Proxies within the same group are separated by a pipe character "|" and
# groups are separated from each other by a semicolon character ";".
# A proxy group can consist of only one proxy.

CVMFS_HTTP_PROXY='${CVMFS_HTTP_PROXY}'

CVMFS_QUOTA_LIMIT=${CVMFS_QUOTA_LIMIT_MB}  # cache size in MiB (recommended: 4GB to 50GB)

$GEO

CVMFS_REPOSITORIES='$CVMFS_REPOSITORIES'
EOF

#----------------------------------------------------------------
# Configure CVMFS

# Check

if ! cvmfs_config chksetup >$LOG 2>&1; then
  cat $LOG
  rm $LOG
  echo "$EXE: error: bad cvmfs setup" 2>&1
  exit 1
fi
rm $LOG

# Setup

if [ -z "$QUIET" ]; then
  echo "$EXE: running \"cvmfs_config setup\""
fi

if ! cvmfs_config setup >$LOG 2>&1; then
  cat $LOG
  rm $LOG
  echo "$EXE: error: cvmfs_config setup failed" 2>&1
  exit 1
fi
if [ -n "$VERY_VERBOSE" ]; then
  # This doesn't usually produce any output, but maybe it might in the future?
  cat $LOG
fi
rm $LOG

#----------------------------------------------------------------
# Success

if [ -z "$QUIET" ]; then
  echo "$EXE: done"
fi

exit 0

#EOF

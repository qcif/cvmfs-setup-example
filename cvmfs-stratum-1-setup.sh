#!/bin/sh
#
# Install and configure a CernVM-FS Stratum 1 replica server.
#
# WARNINGS
#
# CentOS 7 installs Squid 3.5.20 which deprecated: a newer release of
# Squid should be used.  Squid on Stratum 1 is mainly used to cache
# Geo API calls, so an old Squid is not too critical for an example
# repository. CentOS 7 is no longer receiving full updates and
# maintenance updates are only available until 2024-06-30, so it
# probably should not be used.
#
# Copyright (C) 2021, QCIF Ltd.
#================================================================

PROGRAM='cvmfs-stratum-1-setup'
VERSION='1.0.0'

EXE=$(basename "$0" .sh)
EXE_EXT=$(basename "$0")

#----------------------------------------------------------------
# Constants

#----------------
# Squid proxy

DEFAULT_MEM_CACHE_SIZE_MB=256

MIN_MEM_CACHE_SIZE_MB=10

#----------------
# Apache Web Server

DEFAULT_SERVERNAME=stratum1.cvmfs.example.org

#----------------

# Refresh step to use for the snapshot cron job
#
# Note: the refresh value is used as a step value for the cron job's
# minutes field.  For example, 14 will mean it runs at 0, 14, 28, 42
# and 56 minutes past the hour (with only 4 minutes delay before the
# runs that happen on the hour).

DEFAULT_REFRESH_MINUTES=5

# Default repository owner user account

if [ -n "$SUDO_USER" ]; then
  # Running under sudo, default to the user who invoked sudo
  DEFAULT_REPO_USER="$SUDO_USER"
else
  # Default to the user running the program
  DEFAULT_REPO_USER=$(id -u -n)
fi

# Header inserted into generated files
PROGRAM_INFO="Created by $PROGRAM $VERSION [$(date '+%F %T %Z')]"

#----------------------------------------------------------------
# Error handling

# Exit immediately if a simple command exits with a non-zero status.
# Better to abort than to continue running when something went wrong.
set -e

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

  if echo "$ARG" | grep ':' >/dev/null; then
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

STRATUM_0_HOST=
CVMFS_GEO_LICENSE_KEY=
REPO_USER="$DEFAULT_REPO_USER"
SERVERNAME="$DEFAULT_SERVERNAME"
REFRESH_MINUTES=$DEFAULT_REFRESH_MINUTES
MEM_CACHE_SIZE_MB=$DEFAULT_MEM_CACHE_SIZE_MB
VERBOSE=
VERY_VERBOSE=
SHOW_VERSION=
SHOW_HELP=
REPOS=

while [ $# -gt 0 ]
do
  case "$1" in
    -0|--s0|--stratum0|--stratum-0)
      if [ $# -lt 2 ]; then
        echo "$EXE: usage error: $1 missing value" >&2
        exit 2
      fi
      STRATUM_0_HOST="$2"
      shift; shift
      ;;
    -g|--geo|--geo-api|--geo-api-key)
      if [ $# -lt 2 ]; then
        echo "$EXE: usage error: $1 missing value" >&2
        exit 2
      fi
      CVMFS_GEO_LICENSE_KEY="$2"
      shift; shift
      ;;
    -s|--servername)
      if [ $# -lt 2 ]; then
        echo "$EXE: usage error: $1 missing value" >&2
        exit 2
      fi
      SERVERNAME="$2"
      shift; shift
      ;;
    -u|--user)
      if [ $# -lt 2 ]; then
        echo "$EXE: usage error: $1 missing value" >&2
        exit 2
      fi
      REPO_USER="$2"
      shift; shift
      ;;
    -r|--refresh)
      if [ $# -lt 2 ]; then
        echo "$EXE: usage error: $1 missing value" >&2
        exit 2
      fi
      REFRESH_MINUTES="$2"
      shift; shift;
      ;;
    -m|--mem-cache)
      if [ $# -lt 2 ]; then
        echo "$EXE: usage error: $1 missing value" >&2
        exit 2
      fi
      MEM_CACHE_SIZE_MB="$2"
      shift; shift
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
  -0 | --stratum-0 HOST   Stratum 0 central server (mandatory)
  -g | --geo-api-key KEY  Geo API license_key (optional)
  -s | --servername NAME  servername or IP address of this host (optional)
  -u | --user ID          repository owner account (default: $DEFAULT_REPO_USER)
  -r | --refresh MIN      minutes step for replica snapshots (default: $DEFAULT_REFRESH_MINUTES)
  -m | --mem-cache NUM    size of memory cache in MiB (default: $DEFAULT_MEM_CACHE_SIZE_MB)
  -v | --verbose          output extra information when running
       --version          display version information and exit
  -h | --help             display this help and exit
REPO_FQRN: fully qualified repository name
PUBKEY: file containing the repository's public key

e.g. $EXE_EXT --stratum-0 s0.example.net \\
       data.example.org.pub  tools.example.org:pubkey.pub

EOF
  if [ -n "$VERBOSE" ]; then
    cat <<EOF
To remove a replica:
  sudo cvmfs_server rmfs repo-fqrn

To manually synchronise repository:
  sudo cvmfs_server snapshot repo-fqrn

EOF
  fi
  exit 0
fi

if [ -n "$SHOW_VERSION" ]; then
  echo "$PROGRAM $VERSION"
  exit 0
fi

if [ -z "$STRATUM_0_HOST" ]; then
  echo "$EXE: usage error: missing Stratum 0 (-h for help)" >&2
  exit 2
fi

if [ -z "$REPOS" ]; then
  echo "$EXE: usage error: missing repositories (-h for help)" >&2
  exit 2
fi

if ! echo "$REFRESH_MINUTES" | grep -E '^[0-9]+$' >/dev/null ; then
  echo "$EXE: usage error: refresh minute step: invalid positive integer: \"$REFRESH_MINUTES\"" >&2
  exit 2
fi
if [ $REFRESH_MINUTES -lt 1 ] || [ $REFRESH_MINUTES -gt 30 ]; then
  echo "$EXE: usage error: refresh minute step: out of range (1-30): \"$REFRESH_MINUTES\"" >&2
  exit 2
fi


if ! id -u "$REPO_USER" >/dev/null 2>&1; then
  echo "$EXE: error: unknown user account: $REPO_USER" >&2
  exit 1
fi

if ! echo "$MEM_CACHE_SIZE_MB" | grep -E '^[0-9]+$' >/dev/null ; then
  echo "$EXE: usage error: memory cache: invalid number: \"$MEM_CACHE_SIZE_MB\"" >&2
  exit 2
fi
if [ "$MEM_CACHE_SIZE_MB" -lt $MIN_MEM_CACHE_SIZE_MB ]; then
  echo "$EXE: usage error: memory cache is too small: $MEM_CACHE_SIZE_MB MiB" >&2
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

# Check repository does not already exist on this host

for REPO in $REPOS; do
  FULLNAME=$(_fqrn "$REPO")

  if [ -e "/srv/cvmfs/$FULLNAME" ]; then
    echo "$EXE: error: repository/replica already exists: $FULLNAME" >&2
    exit 1
  fi
done

# Check if repository exists on the Stratum 0 server.
# The "add-replica" will fail, but it is nicer to catch typo errors earlier.

for REPO in $REPOS; do
  FULLNAME=$(_fqrn "$REPO")

  if ! curl --head --fail \
       http://$STRATUM_0_HOST/cvmfs/$FULLNAME/.cvmfs_master_replica \
       >/dev/null 2>&1; then
    echo "$EXE: error: repository does not exist on the Stratum 0: $FULLNAME at $STRATUM_0_HOST" >&2
    exit 1
  fi
done

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

if echo "$DISTRO" | grep '^CentOS Linux release 7' > /dev/null; then
  :
elif echo "$DISTRO" | grep '^CentOS Linux release 8' > /dev/null; then
  :
elif echo "$DISTRO" | grep '^CentOS Stream release 8' > /dev/null; then
  :
else
  # Add additional elif-statements for tested systems
  echo "$EXE: warning: untested system: $DISTRO" >&2
fi

# Not working on CentOS Stream 8, as of 2021-04-13.
#
# It doesn't like the syntax in /etc/httpd/conf.d/cvmfs.+webapi.conf of
# this line, even though it is the same and works on other distributions
# (include the older non-stream CentOS 8):
#
#     WSGIDaemonProcess cvmfsapi threads=64 display-name=%{GROUP}   python-path=/usr/share/cvmfs-server/webapi

#----------------------------------------------------------------
# Check for root privileges

if [ "$(id -u)" -ne 0 ]; then
  echo "$EXE: error: root privileges required" >&2
  exit 1
fi

#----------------------------------------------------------------
# Install CernVM-FS client and server, squid and mod_wsgi

# Use LOG file to suppress apt-get messages, only show on error
# Unfortunately, "apt-get -q" and "yum install -q" still produces output.
LOG="/tmp/${PROGRAM}.$$"

_yum_install() {
  PKG="$1"

  if ! echo "$PKG" | grep /^https:/ >/dev/null ; then
    # Value is a URL: extract package name from it
    PKG_NAME=$(echo "$PKG" | sed 's/^.*\///') # remove everything up to last /
    PKG_NAME=$(echo "$PKG_NAME" | sed 's/\.rpm$//') # remove .rpm
  else
    # Assume the entire value is the package name
    PKG_NAME="$PKG"
  fi

  if ! rpm -q $PKG_NAME >/dev/null ; then
    # Not already installed

    if [ -n "$VERBOSE" ]; then
      echo "$EXE: yum install: $PKG"
    fi

    if ! yum install -y $PKG >$LOG 2>&1; then
      cat $LOG
      rm $LOG
      echo "$EXE: error: yum install: $PKG failed" >&2
      exit 1
    fi
    rm $LOG

  else
    if [ -n "$VERBOSE" ]; then
      echo "$EXE: package already installed: $PKG"
    fi
  fi
}

#----------------

if which yum >/dev/null; then
  # Installing for Fedora based systems

  if ! rpm -q cvmfs >/dev/null || ! rpm -q cvmfs-server >/dev/null ; then
    # Need to install CVMFS packages, which first needs cvmfs-release-latest

    # Setup CernVM-FS YUM repository (if needed)

    EXPECTING='/etc/yum.repos.d/cernvm.repo'
    if [ ! -e "$EXPECTING" ]; then

      _yum_install https://ecsft.cern.ch/dist/cvmfs/cvmfs-release/cvmfs-release-latest.noarch.rpm

      if [ ! -e "$EXPECTING" ]; then
        # The expected file was not installed.
        # This means the above test for determining if the YUM repository
        # has been installed or not needs to be changed.
        echo "$EXE: internal error: file not found: $EXPECTING" >&2
        exit 3
      fi
    fi # if [ ! -e "$EXPECTING" ]

    # Installing cvmfs

    _yum_install cvmfs

    # Installing cvmfs-server

    if ! rpm -q jq >/dev/null && ! rpm -q epel-release >/dev/null ; then
      # neither "jq" nor "epel-release" (where "jq" comes from) is installed
      #
      # cvmfs-server depends on "jq" (command-line JSON processor)
      # which is already install by default on CentOS 8, but for
      # CentOS 7 it needs to come from EPEL, so install "epel-release"
      # before trying to install "cvmfs-server" (so it can install "jq").

      _yum_install epel-release
    fi

    _yum_install cvmfs-server
  else
    if [ -n "$VERBOSE" ]; then
      echo "$EXE: package already installed: cvmfs"
      echo "$EXE: package already installed: cvmfs-server"
    fi
  fi

  # Installing Squid

  _yum_install squid

  # Installing other packages
  #
  # WSGI is needed by CernVM-FS to query the Geo API.
  #
  # CentOS 7: mod_wsgi and python3-mod_wsgi are not installed by default
  # CentOS 8: mod_ssl and python_mod_wsgi are not installed by default
  #           but there is no mod_wsgi package to install!

  if echo "$DISTRO" | grep '^CentOS Linux release 7' > /dev/null; then
    _yum_install mod_wsgi
  fi

  for PKG in mod_ssl python3-mod_wsgi; do
    if ! rpm -q $PKG >/dev/null; then
      _yum_install $PKG
    fi
  done

elif which apt-get >/dev/null; then
  # Installing for Debian based systems

  echo "$EXE: Debian/Ubuntu not supported yet: please use CentOS" >&2
  exit 3

else
  echo "$EXE: unsupported system: no yum or apt-get" >&2
  exit 3
fi

#----------------------------------------------------------------
# Configure Squid

SQUID_CONF=/etc/squid/squid.conf

# if [ -e "$SQUID_CONF" ] && [ ! -e "${SQUID_CONF}.orig" ] ; then
#   mv "$SQUID_CONF" "${SQUID_CONF}.orig" # backup original config file
# fi

if [ -n "$VERBOSE" ]; then
  echo "$EXE: configuring reverse proxy: $SQUID_CONF"
fi

cat > "$SQUID_CONF" <<EOF
# Squid proxy configuration
# $PROGRAM_INFO

#----------------
# Service

# Port 80 = Apache Web Server
# Port 8000 = convention for CVMFS Stratum 1 Squid proxy frontend.

http_port 80 accel
http_port 8000 accel

#----------------
# Access control

http_access allow all

# Peer: the host-only Apache Web Server (httpd) listening on port 8080

cache_peer 127.0.0.1 parent 8080 0 no-query originserver

# Access control: only cache /cvmfs/*/api/

acl CVMFSAPI urlpath_regex ^/cvmfs/[^/]*/api/
cache deny !CVMFSAPI

#----------------
# Cache properties

cache_mem ${MEM_CACHE_SIZE_MB} MB

# Note: disk cache not required, since all files are local in the CVMFS replica
EOF

#----------------------------------------------------------------
# Configure Apache Web Server

# Set the ServerName (otherwise an error appears in the httpd logs)

sed -i "s/^#ServerName .*/ServerName $SERVERNAME:80/" \
    /etc/httpd/conf/httpd.conf

cat >/var/www/html/index.html <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <title>CVMFS Stratum 1</title>
  <style type="text/css">
body {
  font-family: sans-serif;
  background: #0A6A86;
}
h1 {
  padding: 3ex 0;
  text-align: center;
  font-size: 36pt;
  color: #fff;
}
p {
  text-align: center;
  font-size: 14pt;
  color: #999;
  position: fixed;
  width: 100%;
  bottom: 1ex;
}
</style>
</head>
<body>
  <h1>CernVM-FS Stratum 1 replica</h1>
  <p>Only caching proxies should use this server.</p>
</body>
</html>
EOF

#----------------------------------------------------------------
# Run the Apache Web Server

if [ -n "$VERBOSE" ]; then
  echo "$EXE: restarting and enabling httpd.service"
fi

# Note: in case it was already running, use restart instead of start.
if ! sudo systemctl restart httpd.service; then
  echo "$EXE: error: httpd restart failed" >&2
  exit 1
fi

if ! systemctl enable httpd.service 2>/dev/null; then
  echo "$EXE: error: httpd enable failed" >&2
  exit 1
fi

#----------------------------------------------------------------
# Run the Squid reverse proxy

if [ -n "$VERBOSE" ]; then
  echo "$EXE: restarting and enabling squid.service"
fi

# Note: in case it was already running, use restart instead of start.
if ! sudo systemctl restart squid.service; then
  echo "$EXE: error: squid restart failed" >&2
  exit 1
fi

if ! systemctl enable squid.service 2>/dev/null; then
  echo "$EXE: error: squid enable failed" >&2
  exit 1
fi

#----------------------------------------------------------------
# Configure Geo API key
#
# Get from <https://www.maxmind.com/en/accounts/YOUR_ACCOUNT_ID/license-key>

GEO_KEY_FILE=/etc/cvmfs/server.local

touch $GEO_KEY_FILE
chmod 600 $GEO_KEY_FILE # restrict access, since it may contain the license key

if [ -n "$CVMFS_GEO_LICENSE_KEY" ]; then
  # License key provided: using Geo API

  if [ -n "$VERBOSE" ]; then
    echo "$EXE: Geo API: configured key: $GEO_KEY_FILE"
  fi

  echo "CVMFS_GEO_LICENSE_KEY=$CVMFS_GEO_LICENSE_KEY" >> $GEO_KEY_FILE
else
  # Not using Geo API

  if [ -n "$VERBOSE" ]; then
    echo "$EXE: Geo API: disabled: $GEO_KEY_FILE"
  fi

  echo 'CVMFS_GEO_DB_FILE=NONE' > $GEO_KEY_FILE
fi

#----------------------------------------------------------------
# Add repository public key

for REPO in $REPOS; do
  ORG_KEY_DIR="/etc/cvmfs/keys/$(_org_id $REPO)"

  if [ ! -d "$ORG_KEY_DIR" ]; then
    mkdir "$ORG_KEY_DIR"
  fi

  REPO_PUBKEY_FILE="${ORG_KEY_DIR}/$(_fqrn $REPO).pub"

  cp "$(_pubkey_file $REPO)" "$REPO_PUBKEY_FILE"
  chmod 644 "$REPO_PUBKEY_FILE"
done

#----------------------------------------------------------------
# Setup the replicas

for REPO in $REPOS; do
  FULLNAME=$(_fqrn $REPO)

  # Add the replica

  if [ -n "$VERBOSE" ]; then
    echo "$EXE: add-replica: $FULLNAME from $STRATUM_0_HOST"
  fi

  if ! cvmfs_server add-replica -o "$REPO_USER" \
     http://${STRATUM_0_HOST}/cvmfs/${FULLNAME} \
     /etc/cvmfs/keys/$(_org_id $REPO) >$LOG 2>&1 ; then
    cat $LOG
    rm $LOG
    echo "$EXE: error: could not add replica: $FULLNAME from $STRATUM_0_HOST" >&2
    exit 1
  fi
  if [ -n "$VERY_VERBOSE" ]; then
    cat $LOG
  fi
  rm $LOG

  # Get initial snapshots of the repository
  #
  # Note: this must be done at least once, otherwise the cron job that
  # performs the periodic snapshotting does not include the
  # repository, since the cron job uses the "snapshot -a -i" option
  # that skips repositories that have not run initial snapshot.
  #
  # The alternative is to omit this step and not use "-i" in the cron job.
  # But that means the replica will not be available until after the first
  # run of the cron job.

  if [ -n "$VERBOSE" ]; then
    echo "$EXE: snapshot: $FULLNAME"
  fi

  if ! cvmfs_server snapshot $FULLNAME >$LOG 2>&1; then
    cat $LOG
    rm $LOG
    echo "$EXE: error: could not snapshot repository: $FULLNAME" >&2
    exit 1
  fi
  if [ -n "$VERY_VERBOSE" ]; then
    cat $LOG
  fi
  rm $LOG
done

#----------------------------------------------------------------
# Log rotate for CVMFS (needed otherwise "cvmfs_server snapshot -a" will fail)

cat > /etc/logrotate.d/cvmfs <<EOF
# Log rotate for CernVM-FS
# $PROGRAM_INFO

/var/log/cvmfs/*.log {
  weekly
  missingok
  notifempty
}
EOF

#----------------------------------------------------------------
# Cron job to synchronise all repositories

cat > '/etc/cron.d/cvmfs_stratum1_snapshot' <<EOF
# Cron job to synchronise **all** the Stratum 1 repositories
# $PROGRAM_INFO

# min hour day month day-of-week (i.e. every $REFRESH_MINUTES minutes or so)
*/$REFRESH_MINUTES * * * * root OUT=\$(/usr/bin/cvmfs_server snapshot -a -i 2>&1) || echo "\$OUT"
EOF

#----------------------------------------------------------------
# Success

if [ -n "$VERBOSE" ]; then
  echo "$EXE: ok"
fi

exit 0

#----------------------------------------------------------------

cat >/dev/null <<EOF
Notes:

The "cvmfs-server add-replica" command prints out these instructions
(which can be seen when runing in very verbose mode with "-v -v"):

Linking GeoIP Database

NOTE: If snapshot is not run regularly as root, the GeoIP database
will not be updated.

You have some options:
1. chown -R /var/lib/cvmfs-server/geo accordingly
2. Run update-geodb from cron as root
3. chown -R /var/lib/cvmfs-server/geo to a dedicated
user ID and run update-geodb monthly as that user
4. Use another update tool such as Maxmind's geoipupdate and
       set CVMFS_GEO_DB_FILE to point to the downloaded file
5. Disable the geo api with CVMFS_GEO_DB_FILE=none
  See 'Geo API Setup' in the cvmfs documentation for more info.

...

Make sure to install the repository public key in /etc/cvmfs/keys/
You might have to add the key in /etc/cvmfs/repositories.d/<REPO_FULL_NAME>/replica.conf

EOF

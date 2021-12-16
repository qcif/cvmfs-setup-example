#!/bin/sh
#
# Install and configure a CernVM-FS Stratum 0 central server.
#
# Takes about 2.5 minutes to run.
#
# Note: this is a POSIX "sh" script for maximum portability.
#
# Copyright (C) 2021, QCIF Ltd.
#================================================================

PROGRAM='cvmfs-stratum-0-setup'
VERSION='1.3.0'

EXE=$(basename "$0" .sh)
EXE_EXT=$(basename "$0")

#----------------------------------------------------------------
# Constants

DEFAULT_CVMFS_FILE_MBYTE_LIMIT=$((4 * 1024)) # MiB
MIN_CVMFS_FILE_MBYTE_LIMIT=10 # MiB

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

set -u # fail on attempts to expand undefined environment variables

#----------------------------------------------------------------
# Command line arguments
# Note: parsing does not support combining single letter options (e.g. "-vh")

REPO_USER="$DEFAULT_REPO_USER"
CVMFS_FILE_MBYTE_LIMIT=$DEFAULT_CVMFS_FILE_MBYTE_LIMIT
QUIET=
VERBOSE=
VERY_VERBOSE=
SHOW_VERSION=
SHOW_HELP=
REPO_IDS=

while [ $# -gt 0 ]
do
  case "$1" in
    -u|--user)
      if [ $# -lt 2 ]; then
        echo "$EXE: usage error: $1 missing value" >&2
        exit 2
      fi
      REPO_USER="$2"
      shift; shift
      ;;
    --file-limit)
      if [ $# -lt 2 ]; then
        echo "$EXE: usage error: $1 missing value" >&2
        exit 2
      fi
      CVMFS_FILE_MBYTE_LIMIT="$2"
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

      REPO_IDS="$REPO_IDS $1"

      shift
      ;;
  esac
done

if [ -n "$SHOW_HELP" ]; then
  cat <<EOF
Usage: $EXE_EXT [options] {REPOSITORY_IDS}
Options:
  -u | --user ID          repository owner account (default: $DEFAULT_REPO_USER)
       --file-limit SIZE  publish file size limit in MiB (default: $DEFAULT_CVMFS_FILE_MBYTE_LIMIT MiB)
  -q | --quiet            output nothing unless an error occurs
  -v | --verbose          output extra information when running
       --version          display version information and exit
  -h | --help             display this help and exit
REPOSITORY_IDS: fully qualified repository names of the repositories to create

e.g. $EXE_EXT \\
       data.example.org tools.example.org

EOF

  if [ -n "$VERBOSE" ]; then
    cat <<EOF
Update contents of a repository (run as the repository owner):
  1. Run: "cvmfs_server transaction REPOSITORY_ID"
  2. Modify the files under /cvmfs/REPOSITORY_ID
  3. Run: "cvmfs_server publish REPOSITORY_ID" or "cvmfs_server abort"

Create additional repositories:
  cvmfs_server mkfs -o USER_ID REPOSITORY_ID

Information about a repository:
  cvmfs_server info REPOSITORY_ID

Important: Don't forget to backup the master keys from: /etc/cvmfs/keys

EOF
  fi

  exit 0
fi

if [ -n "$SHOW_VERSION" ]; then
  echo "$PROGRAM $VERSION"
  exit 0
fi


if ! echo "$CVMFS_FILE_MBYTE_LIMIT" | grep -qE '^[0-9]+$'; then
  echo "$EXE: usage error: CVMFS_FILE MBYTE_LIMIT: invalid number: \"$CVMFS_FILE_MBYTE_LIMIT\"" >&2
  exit 2
fi
if [ "$CVMFS_FILE_MBYTE_LIMIT" -lt $MIN_CVMFS_FILE_MBYTE_LIMIT ]; then
  echo "$EXE: usage error: publish file limit is too small: $CVMFS_FILE_MBYTE_LIMIT MiB" >&2
  exit 2
fi

if [ -z "$REPO_IDS" ]; then
  echo "$EXE: usage error: missing repository names (-h for help)" >&2
  exit 2
fi

if ! id -u "$REPO_USER" >/dev/null 2>&1; then
  echo "$EXE: error: unknown user account: $REPO_USER" >&2
  exit 1
fi

#----------------

for FULLNAME in $REPO_IDS; do
  # Check names are fully qualified repository names

  ORG=$(echo "$FULLNAME" | sed -E 's/^[^\.]+\.//')
  if [ -z "$ORG" ]; then
    echo "$EXE: error: invalid fully qualified repository name: $FULLNAME" >&2
    exit 1
  fi
  if [ "$ORG" = "$FULLNAME" ] || [ ".$ORG" = "$FULLNAME" ] ; then
    echo "$EXE: error: invalid fully qualified repository name: $FULLNAME" >&2
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

case "$DISTRO" in
  'CentOS Linux release 7.'* \
    | 'CentOS Linux release 8.'* \
    | 'CentOS Stream release 8.'* \
    | 'Rocky Linux release 8.5 (Green Obsidian)' \
    | 'Ubuntu 21.04' \
    | 'Ubuntu 20.04' \
    | 'Ubuntu 20.10' )
    # Tested distribution (add to above, if others have been tested)
    ;;
  *)
    echo "$EXE: warning: untested system: $DISTRO" >&2
  ;;
esac

#----------------------------------------------------------------
# Check for root privileges

if [ "$(id -u)" -ne 0 ]; then
  echo "$EXE: error: root privileges required" >&2
  exit 1
fi

#----------------------------------------------------------------
# Install (cvmfs, cvmfs-server, and Apache Web Server)

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
  REPO_NAME="$1"
  URL="$2"

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
  PKG="$1"

  PKG_NAME=
  if ! echo "$PKG" | grep -q /^https:/; then
    # Value is a URL: extract package name from it
    PKG_NAME=$(echo "$PKG" | sed 's/^.*\///') # remove everything up to last /
    PKG_NAME=$(echo "$PKG_NAME" | sed 's/\.rpm$//') # remove .rpm
  else
    # Assume the entire value is the package name
    PKG_NAME="$PKG"
  fi

  if ! rpm -q "$PKG_NAME" >/dev/null ; then
    # Not already installed

    if [ -z "$QUIET" ]; then
      echo "$EXE: $YUM install: $PKG"
    fi

    if ! $YUM install -y "$PKG" >$LOG 2>&1; then
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
  PKG_NAME="$1"
  URL="$2"

  if _dpkg_not_installed "$PKG_NAME"; then
    # Download it

    if [ -z "$QUIET" ]; then
      echo "$EXE: downloading $URL"
    fi

    DEB_FILE="/tmp/$(basename "$URL").$$"

    if ! wget --quiet -O "$DEB_FILE" "$URL"; then
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
  PKG="$1"

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

  if _yum_not_installed 'cvmfs' || _yum_not_installed 'cvmfs-server' ; then

    # Get cvmfs-release-latest repo

    _yum_install_repo 'cernvm' \
      https://ecsft.cern.ch/dist/cvmfs/cvmfs-release/cvmfs-release-latest.noarch.rpm

    # Installing cvmfs

    _yum_install cvmfs

    # Installing dependencies that cvmfs-server requires

    if ! rpm -q jq >/dev/null && ! rpm -q epel-release >/dev/null ; then
      # neither jq nor epel-release (where jq comes from) is installed
      #
      # cvmfs-server depends on "jq" (command-line JSON processor)
      # which is already install by default on CentOS 8, but for
      # CentOS 7 it needs to come from EPEL.
      _yum_install epel-release
    fi

    # Installing cvmfs-server

    _yum_install cvmfs-server
  else
    if [ -z "$QUIET" ]; then
      echo "$EXE: package already installed: cvmfs"
      echo "$EXE: package already installed: cvmfs-server"
    fi
  fi

  # Apache Web Server (Note: was installed as a dependency of cvmfs-server)

  APACHE_SERVICE=httpd.service
  # APACHE_CONFIG=/etc/httpd/conf/httpd.conf

elif which apt-get >/dev/null 2>&1; then
  # Installing for Debian based distributions

  if _dpkg_not_installed 'cvmfs' || _dpkg_not_installed 'cvmfs-server'; then

    # Get cvmfs-release-latest-all repo

    _dpkg_download_and_install 'cvmfs-release' \
      https://ecsft.cern.ch/dist/cvmfs/cvmfs-release/cvmfs-release-latest_all.deb

    # Update and install cvmfs and cvmfs-server

    _apt_get_update

    _apt_get_install cvmfs
    _apt_get_install cvmfs-server
  else
    if [ -z "$QUIET" ]; then
      echo "$EXE: package already installed: cvmfs"
      echo "$EXE: package already installed: cvmfs-server"
    fi
  fi

  # Apache Web Server

  _apt_get_install apache2  # Apache Web Server not installed by cvmfs-server

  APACHE_SERVICE=apache2.service
  # APACHE_CONFIG=/etc/apache2/apache2.conf

else
  echo "$EXE: unsupported distribution: no apt-get, yum or dnf" >&2
  exit 3
fi

#----------------------------------------------------------------
# Configure Apache Web Server

# Set the ServerName (otherwise an error appears in the httpd logs)
# TODO: does not work on Debian systems, since ServerName is not in the file.
# sed -i "s/^#ServerName .*/ServerName $SERVERNAME:80/" "$APACHE_CONFIG"

cat >/var/www/html/index.html <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <title>CVMFS Stratum 0</title>
  <style type="text/css">
body {
  font-family: sans-serif;
  background: #363F53;
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
  <h1>CernVM-FS Stratum 0</h1>
  <p>Only Stratum 1 replicas should use this server.</p>
</body>
</html>
EOF

#----------------------------------------------------------------
# Run the Apache Web Server

if [ -z "$QUIET" ]; then
  echo "$EXE: restarting and enabling $APACHE_SERVICE"
fi

# Note: in case it was already running, use restart instead of start.
if ! sudo systemctl restart $APACHE_SERVICE; then
  echo "$EXE: error: httpd restart failed" >&2
  exit 1
fi

if ! systemctl enable $APACHE_SERVICE 2>/dev/null; then
  echo "$EXE: error: httpd enable failed" >&2
  exit 1
fi

#----------------------------------------------------------------
# Create the repositories

CREATED_FULLNAMES=

for FULLNAME in $REPO_IDS; do
  # Extract organization from the fully qualified repo name

  # ORG=$(echo "$REPO_NAME" | sed -E 's/^[^\.]+\.//')

  if [ ! -e "/srv/cvmfs/$FULLNAME" ] ; then
    # Repository does not exist: create it

    if [ -z "$QUIET" ]; then
      echo "$EXE: cvmfs_server mkfs: $FULLNAME"
    fi

    LOG="/tmp/$PROGRAM.$$"
    if ! cvmfs_server mkfs -o "$REPO_USER" "$FULLNAME" >$LOG 2>&1; then
      cat $LOG
      rm $LOG
      echo "$EXE: error creating CernVM-FS repository: $FULLNAME"
      exit 1
    fi
    if [ -n "$VERY_VERBOSE" ]; then
      cat $LOG
    fi
    rm $LOG

    # Add custom config

    cat >> "/etc/cvmfs/repositories.d/$FULLNAME/server.conf" <<EOF

# $PROGRAM_INFO
CVMFS_FILE_MBYTE_LIMIT=$CVMFS_FILE_MBYTE_LIMIT

EOF
    # Output information needed to configure clients

    if [ -z "$QUIET" ]; then
      echo "$EXE: public key: /etc/cvmfs/keys/$FULLNAME.pub"
    fi
    if [ -n "$VERY_VERBOSE" ]; then
      cat "/etc/cvmfs/keys/$FULLNAME.pub"
    fi

    # Append to list

    CREATED_FULLNAMES="$CREATED_FULLNAMES $FULLNAME"

  else
    echo "$EXE: repository already exists: $FULLNAME"
  fi
done

#----------------------------------------------------------------
# Cron job for re-signing whitelists

FILE="/etc/cron.d/cvmfs_resign"
FILE_WAS_CREATED=

if [ ! -e "$FILE" ]; then
  # Create cron job file preamble

  if [ -z "$QUIET" ]; then
    echo "$EXE: creating cron jobs file: $FILE"
  fi

  echo "# Cron jobs to re-sign CVMFS whitelists" > $FILE
  echo "# $PROGRAM_INFO" >> $FILE

  FILE_WAS_CREATED=yes
fi

# Only add cron jobs for new repositories that were actually created.
#
# Note: the file might contain existing cron jobs for repositories
# that were created in a previous run. This code appends the new cron
# jobs to any existing ones.

if [ -n "$CREATED_FULLNAMES" ]; then
  # There are cron jobs to add

  # Count the number of existing jobs, to offset each new job by one minute
  # from the previous job.
  # Note: do not use "grep -c", since that will have a failed exit status
  # when there is no existing jobs and this script will abort.
  MINUTE=$(grep resign "$FILE" | wc -l)

  echo '' >> $FILE
  echo "# Added [$(date '+%F %T %Z')]:" >> $FILE

  for FULLNAME in $CREATED_FULLNAMES; do
    if [ -z "$QUIET" ]; then
      echo "$EXE: adding cron job in $FILE to resign whitelist for $FULLNAME"
    fi

    # min hour day month day-of-week (i.e. 9pm every Sunday)
    echo "$MINUTE 21 * * 7 root /usr/bin/cvmfs_server resign $FULLNAME" >> $FILE

    MINUTE=$((MINUTE + 1))
    if [ $MINUTE -ge 60 ] ; then
      MINUTE=0
    fi
  done
else
  if [ -n "$FILE_WAS_CREATED" ]; then
    echo "$EXE: $FILE: not initialized with any jobs"
  else
    echo "$EXE: $FILE: no jobs added"
  fi
fi

#----------------------------------------------------------------
# Success

if [ -z "$QUIET" ]; then
  echo "$EXE: done"
fi

exit 0

#----------------------------------------------------------------
# Keys generated in /etc/cvmfs/keys
# Master key *.masterkey and *.pub (RSA)
#   - *.pub needed by clients
#   - *.masterkey to sign whitelist of known publisher certificates whitelist
# Repository key *.crt and *.key
# /var/spool/cvmfs (scratch space)

#EOF

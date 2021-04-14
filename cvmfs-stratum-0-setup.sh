#!/bin/sh
#
# Install and configure a CernVM-FS Stratum 0 central server.
#
# Takes about 2.5 minutes to run.
#
# Copyright (C) 2021, QCIF Ltd.
#================================================================

PROGRAM='cvmfs-stratum-0-setup'
VERSION='1.0.0'

EXE=$(basename "$0" .sh)
EXE_EXT=$(basename "$0")

#----------------------------------------------------------------
# Constants

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
# Command line arguments

REPO_USER="$DEFAULT_REPO_USER"
VERBOSE=
VERY_VERBOSE=
SHOW_VERSION=
SHOW_HELP=
REPO_IDS=

while [ $# -gt 0 ]
do
  case "$1" in
    -u|--user)
      REPO_USER="$2"
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
    *)
      if echo "$1" | grep ^- >/dev/null; then
        echo "$EXE: usage error: unknown option: \"$1\"" >&2
        exit 2
      else
        # Use as a repository name
        REPO_IDS="$REPO_IDS $1"
      fi
      shift # past argument
      ;;
  esac
done

if [ -n "$SHOW_HELP" ]; then
  cat <<EOF
Usage: $EXE_EXT [options] {REPOSITORY_IDS}
Options:
  -u | --user ID   repository owner account (default: $DEFAULT_REPO_USER)
  -v | --verbose   output extra information when running
       --version   display version information and exit
  -h | --help      display this help and exit
REPOSITORY_IDS: fully qualified repository names of the repositories to create

e.g. $EXE_EXT \\
       demo.example.org tools.example.org

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

#----------------------------------------------------------------
# Check for root privileges

if [ "$(id -u)" -ne 0 ]; then
  echo "$EXE: error: root privileges required" >&2
  exit 1
fi

#----------------------------------------------------------------
# Install CernVM-FS client and server

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
      # neither jq nor epel-release (where jq comes from) is installed
      #
      # cvmfs-server depends on "jq" (command-line JSON processor)
      # which is already install by default on CentOS 8, but for
      # CentOS 7 it needs to come from EPEL.

      _yum_install epel-release
    fi

    _yum_install cvmfs-server
  else
    if [ -n "$VERBOSE" ]; then
      echo "$EXE: package already installed: cvmfs"
      echo "$EXE: package already installed: cvmfs-server"
    fi
  fi

else
  echo "$EXE: unsupported system: no yum or apt-get" >&2
  exit 3
fi

#----------------------------------------------------------------
# Configure Apache Web Server

# Set the ServerName (otherwise an error appears in the httpd logs)

# sed -i "s/^#ServerName .*/ServerName $SERVERNAME:80/" \
#   /etc/httpd/conf/httpd.conf

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
# Create the repositories

CREATED_FULLNAMES=

for FULLNAME in $REPO_IDS; do
  # Extract organization from the fully qualified repo name

  # ORG=$(echo "$REPO_NAME" | sed -E 's/^[^\.]+\.//')

  if [ ! -e "/srv/cvmfs/$FULLNAME" ] ; then
    # Repository does not exist: create it

    if [ -n "$VERBOSE" ]; then
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

    # Output information needed to configure clients

    if [ -n "$VERBOSE" ]; then
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

if [ -n "$CREATED_FULLNAMES" ]; then
  echo '' # extra blank line after last public key
fi

#----------------------------------------------------------------
# Cron job for re-signing whitelists

FILE="/etc/cron.d/cvmfs_resign"
FILE_WAS_CREATED=

if [ ! -e "$FILE" ]; then
  # Create cron job file preamble

  if [ -n "$VERBOSE" ]; then
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

  MINUTE=$(grep resign "$FILE" | wc -l) # count number of existing jobs

  echo '' >> $FILE
  echo "# Added [$(date '+%F %T %Z')]:" >> $FILE

  for FULLNAME in $CREATED_FULLNAMES; do
    if [ -n "$VERBOSE" ]; then
      echo "$EXE: adding cron job in $FILE to resign whitelist for $FULLNAME"
    fi

    # min hour day month day-of-week (i.e. 9pm every Sunday)
    echo "$MINUTE 21 * * 7 root /usr/bin/cvmfs_server resign $FULLNAME" >> $FILE

    MINUTE=$(($MINUTE + 1))
    if [ $MINUTE -ge 60 ] ; then
      MINUTE=0
    fi
  done
fi

#----------------------------------------------------------------
# Success

if [ -n "$VERBOSE" ]; then
  echo "$EXE: ok"
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

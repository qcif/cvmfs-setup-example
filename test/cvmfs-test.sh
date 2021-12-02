#!/bin/bash
#
# Utility to simplify testing to easily:
#
# - copy the scripts to the test hosts;
# - copy the public keys from the Stratum 0 host to the Stratum 1 and client.
# - ssh to any of the four hosts.
#
# Typically, four new hosts are created and then:
#
# 0. Create a "cvmfs-test.conf" file with their addresses and account(s).
# 1. Use the `copy-scripts` command to copy the script to them.
# 2. Use `ssh-stratum0` to SSH to the Stratum 0 host and run the script on it.
# 3. Use `copy-pubkeys` to copy the public keys to the other hosts.
# 4. Use `ssh-stratum1` to SSH to the Stratum 1 host and run the script on it.
# 5. Use `ssh-proxy` to SSH to the Proxy host and run the script on it.
# 6. Use `ssh-client` to SSH to the Client host and run the script on it.
#
# The config file should set environment variables for the test environment.
# For example:
#
#     CVMFS_HOST_STRATUM0=192.168.1.100
#     CVMFS_HOST_STRATUM1=192.168.1.101
#     CVMFS_HOST_PROXY=192.168.1.200
#     CVMFS_HOST_CLIENT=192.168.1.201
#
#     # CVMFS_USERNAME=ubuntu
#     CVMFS_USERNAME=ec2-user  # use unless specific per-host username provided
#
#     #CVMFS_USERNAME_STRATUM0=ubuntu
#     #CVMFS_USERNAME_STRATUM1=ubuntu
#     #CVMFS_USERNAME_PROXY=ubuntu
#     CVMFS_USERNAME_CLIENT=ubuntu  # overrides CVMFS_USERNAME for this host
#
# The above example is for a client host running Ubuntu, and the other
# hosts are running CentOS.
#
# Copyright (C) 2021, QCIF Ltd.
#================================================================

PROGRAM='cvmfs-test'
VERSION='2.0.0'

EXE=$(basename "$0" .sh)
EXE_EXT=$(basename "$0")
EXE_DIR=$(dirname "$0")

#----------------------------------------------------------------
# Bash strict mode: http://redsymbol.net/articles/unofficial-bash-strict-mode/

# Exit immediately if a simple command exits with a non-zero status.
#   Trap ERR for better error messages than "set -e" gives (but ERR only
#   works for Bash and unlike "set -e" it doesn't propagate into functions.
#   Can't figure out which command failed? Run using "bash -x".
set -e
trap 'echo $EXE: aborted; exit 3' ERR

set -u # fail on attempts to expand undefined environment variables
set -o pipefail # prevents errors in a pipeline from being masked

#----------------------------------------------------------------
# Defaults

DEFAULT_CONFIG_FILES="
 cvmfs-test.conf
 $HOME/.cvmfs-test.conf
 $HOME/.config/cvmfs-test.conf
"

DEFAULT_CVMFS_FILE_MBYTE_LIMIT=4096  # MiB

DEFAULT_PROXY_DISK_CACHE_DIR=/var/spool/squid
DEFAULT_PROXY_DISK_CACHE_SIZE=5120  # MiB

#----------------------------------------------------------------
# Constants

PUBKEY_DIRNAME=cvmfs-pubkeys  # name of directory on Stratum 1 and client

PUBKEY_TAR_FILE_NAME=cvmfs-pubkeys.tar.gz  # name of file with the pubkeys

DOC_URL_PATH=info  # path for Web documentation on Stratum 1 host's Web server

#----------------------------------------------------------------
# Command line arguments

# Note: parsing does not support combining single letter options (e.g. "-vh")

CONFIG_FILE=
QUIET=
VERBOSE=
SHOW_VERSION=
SHOW_HELP=
COMMAND=

while [ $# -gt 0 ]
do
  case "$1" in
    --config|-c)
      if [ $# -lt 2 ]; then
        echo "$EXE: usage error: $1 missing value" >&2
        exit 2
      fi
      if [ -n "$CONFIG_FILE" ]; then
        echo "$EXE: usage error: multiple $1 options not allowed" >&2
        exit 2
      fi
      CONFIG_FILE="$2"
      shift; shift
      ;;

    -q|--quiet)
      QUIET=yes
      shift
      ;;
    -v|--verbose)
      VERBOSE=yes
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

      if [ -n "$COMMAND" ]; then
        echo "$EXE: usage error: too many arguments: $1" >&2
        exit 2
      fi
      COMMAND="$1"
      shift;
      ;;
  esac
done

if [ -n "$SHOW_HELP" ]; then
  cat <<EOF
Usage: $EXE_EXT [options] command
Options:
  -c | --config FILE           configuration file
  -v | --verbose               output extra information
       --version               display version information and exit
  -h | --help                  display this help and exit

Main commands:
  reset-all    rebuild and setup all the hosts (see minor commands below)
  setup-all    reset-all without rebuilding VM (they must already be ready)

  test-update  modify file on Stratum 0 and waits for change on the Client

  list-repos   list available repositories from the Stratum 0
  show-config  show the configuration that will be used

Commands to SSH to the hosts:
  s0 | ssh-s0          ssh to the Stratum 0 host
  s1 | ssh-s1          ssh to the Stratum 1 host
  sp | ssh-proxy       ssh to the Proxy host
  sc | ssh-client      ssh to the Client host
  pub | ssh-publisher  ssh to the Stratum 0 host as the repository publisher

Minor commands performed by "reset-all":
  rebuild-vm      rebuild the VM instances
  copy-scripts    copies the scripts to their respective hosts
  copy-pubkeys    copies public keys from Stratum 0 to Stratum 1 and Client
  run-scripts     runs the setup scripts on the hosts (also does copy-pubkey)
  document-repos  create documentation of repositories on Stratum 1 host
  populate-repos  populate the repositories

EOF
  exit 0
fi

if [ -n "$SHOW_VERSION" ]; then
  echo "$PROGRAM $VERSION"
  exit 0
fi


if [ -z "$COMMAND" ]; then
  cat >&2 <<EOF
$EXE: usage error: missing command
Common commands:
  reset-all
  setup-all
  test-update
  list-repos
  ssh-s0|s0, ssh-s1|s1, ssh-proxy|sp, ssh-client|sc, ssh-publisher|pub
  (see -h for help and a full list of commands)
EOF
  exit 2
fi

#----------------------------------------------------------------
# Utility functions

#----------------
# Normal echo
# For optional output. Does not output if --quiet used.

_echoN() {
  if [ -z "$QUIET" ]; then
    if [ -n "$*" ]; then
      echo "$EXE: $*"
    else
      echo
    fi
  fi
}

#----------------
# Verbose echo
# Only outputs if --verbose used.

_echoV() {
  if [ -n "$VERBOSE" ]; then
    echo "$EXE: $*"
  fi
}

#----------------
# Output error message on stderr and exit with failed status

_exit() {
  echo "$EXE: error: $*" >&2
  exit 1
}

#----------------
# Duration formatting (e.g. "15s", "3m15s" or "2h5m30s")

_duration_from() {
  # Usage: _duration_from start_seconds [end_seconds]

  local END
  if [ $# -gt 1 ]; then
    END="$2"
  else
    END=$(date '+%s')
  fi
  local SEC=$((END - $1))

  if [ $SEC -lt 60 ]; then
    echo "${SEC}s"
  elif [ $SEC -lt 3600 ]; then
    echo "$((SEC / 60))m$((SEC % 60))s"
  else
    echo "$((SEC / 3600))h$((SEC % 3600 / 60))m$((SEC % 60))s"
  fi
}


#----------------------------------------------------------------
# Run command remotely with SSH

#----------------
# Option for SSH (ssh and scp): StrictHostKeyChecking=off
# automatically add host key to ~/.ssh/known_hosts, and allows
# connections to hosts with changed hostkeys to proceed. THIS IS
# UNSAFE, but for testing it is more convenient when the host and
# their host keys often change.  Unfortunately, there is no way to not
# add the host keys to the file and to allow connections where the
# host key is not in the file.
#
# See `man ssh_config` for details

SSH_SHKC_OPTION=StrictHostKeyChecking=off

#----------------

_ssh_quiet() {
  ssh -t -q -o $SSH_SHKC_OPTION "$@"
}

#----------------

_ssh() {
  _echoV "ssh $*"

  _ssh_quiet "$@"
}

#----------------------------------------------------------------
# Load parameters from config file

_load_config() {
  CVMFS_HOST_STRATUM0=
  CVMFS_HOST_STRATUM1=
  CVMFS_HOST_PROXY=
  CVMFS_HOST_CLIENT=

  CVMFS_USERNAME_STRATUM0=
  CVMFS_USERNAME_STRATUM1=
  CVMFS_USERNAME_PROXY=
  CVMFS_USERNAME_CLIENT=
  PUBLISHER=

  REPO_NAMES=
  REPO_ORG=

  CVMFS_FILE_MBYTE_LIMIT=

  PROXY_DISK_CACHE_DIR=
  PROXY_DISK_CACHE_SIZE=
  PROXY_ALLOWED_CLIENTS=

  # Load

  if [ -n "$CONFIG_FILE" ]; then
    # Config file specified on command line
    if [ ! -f "$CONFIG_FILE" ]; then
      _exit "missing config file: $CONFIG_FILE"
    fi
  else
    # No config file from command line: try loading one of the default files

    for FILE in $DEFAULT_CONFIG_FILES ; do
      if [ -f "$FILE" ]; then
        CONFIG_FILE="$FILE"
        break; # stop looking after first file found
      fi
    done

    if [ -z "$CONFIG_FILE" ]; then
      for FILE in $DEFAULT_CONFIG_FILES ; do
        echo "$EXE: no file: $FILE" >&2
      done
      _exit "no config file found (specify one using --config)"
    fi
  fi

  # Config file specified on command line: only load that one file
  source "$CONFIG_FILE" # set environment variables from it

  local -r CFG_ERR="not defined: fix config file: $CONFIG_FILE"

  # Check test environment variables have been set

  if [ -z "$CVMFS_HOST_STRATUM0" ]; then
    _exit "CVMFS_HOST_STRATUM0 $CFG_ERR"
  fi
  if [ -z "$CVMFS_HOST_STRATUM1" ]; then
    _exit "CVMFS_HOST_STRATUM1 $CFG_ERR"
  fi
  if [ -z "$CVMFS_HOST_PROXY" ]; then
    _exit "CVMFS_HOST_PROXY $CFG_ERR"
  fi
  if [ -z "$CVMFS_HOST_CLIENT" ]; then
    _exit "CVMFS_HOST_CLIENT $CFG_ERR"
  fi

  # User accounts for setup

  if [ -z "$CVMFS_USERNAME_STRATUM0" ]; then
    _exit "CVMFS_USERNAME_STRATUM0 $CFG_ERR"
  fi
  if [ -z "$CVMFS_USERNAME_STRATUM1" ]; then
    _exit "CVMFS_USERNAME_STRATUM1 $CFG_ERR"
  fi
  if [ -z "$CVMFS_USERNAME_PROXY" ]; then
    _exit "CVMFS_USERNAME_PROXY $CFG_ERR"
  fi
  if [ -z "$CVMFS_USERNAME_CLIENT" ]; then
    _exit "CVMFS_USERNAME_CLIENT $CFG_ERR"
  fi

  # User account for publishing

  if [ -z "$PUBLISHER" ]; then
    PUBLISHER="$CVMFS_USERNAME_STRATUM0" # default to setup account
  fi

  # Repos

  if [ -z "$REPO_ORG" ]; then
    _exit "REPO_ORG $CFG_ERR"
  fi

  if [ -z "$REPO_NAMES" ]; then
    _exit "REPO_NAMES $CFG_ERR"
  fi
  REPO_NAMES=$(echo "$REPO_NAMES" | tr ',' ' ') # comma separated to space sep

  #----------------
  # Publish file size limit

  if [ -z "$CVMFS_FILE_MBYTE_LIMIT" ]; then
    CVMFS_FILE_MBYTE_LIMIT=$DEFAULT_CVMFS_FILE_MBYTE_LIMIT  # use default
  fi
  _check_num "$CONFIG_FILE: CVMFS_FILE MBYTE_LIMIT" "$CVMFS_FILE_MBYTE_LIMIT" 1

  # Proxy disk cache location

  if [ -z "$PROXY_DISK_CACHE_DIR" ]; then
    PROXY_DISK_CACHE_DIR=$DEFAULT_PROXY_DISK_CACHE_DIR
  fi

  # Proxy disk cache size

  if [ -z "$PROXY_DISK_CACHE_SIZE" ]; then
    PROXY_DISK_CACHE_SIZE=$DEFAULT_PROXY_DISK_CACHE_SIZE
  fi
  _check_num "$CONFIG_FILE:PROXY_DISK_CACHE_SIZE" "$PROXY_DISK_CACHE_SIZE" 1024

  if [ -z "$PROXY_ALLOWED_CLIENTS" ]; then
    _exit "$CONFIG_FILE: missing value for PROXY_ALLOWED_CLIENTS"
  fi

  #----------------
  # Check sanity of values

  if [ "$PROXY_DISK_CACHE_SIZE" -le "$CVMFS_FILE_MBYTE_LIMIT" ]; then
    # Error
    _exit "proxy disk cache size ($PROXY_DISK_CACHE_SIZE MiB) is smaller than the file size limit ($CVMFS_FILE_MBYTE_LIMIT MiB)" >&2
  fi

  local -r MULT=4 # multiplier from per-file limit to total disk cache limit

  if [ "$PROXY_DISK_CACHE_SIZE" -le $((CVMFS_FILE_MBYTE_LIMIT * MULT)) ]; then
    # Warning
    echo "$EXE: WARNING: proxy disk cache size ($PROXY_DISK_CACHE_SIZE MiB) might be too small for the file size limit ($CVMFS_FILE_MBYTE_LIMIT MiB)" >&2
  fi
}

# Check if a parameter is an non-negative integer. Error if it is not

_check_num() {
  local -r LABEL="$1"
  local -r VALUE="$2"
  local -r MINIMUM="$3"

  if ! echo "$VALUE" | grep -qE '^[1-9][0-9]*$'; then
    _exit "$LABEL: invalid number: \"$VALUE\"" >&2
  fi
  if [ -n "$MINIMUM" ] && [ "$VALUE" -lt "$MINIMUM" ]; then
    _exit "$LABEL: value too small: \"$VALUE\"" >&2
  fi
}

#----------------------------------------------------------------
# Main functions

#----------------

_reset_all() {
  local -r DO_REBUILD="$1"

  local -r START=$(date '+%s') # seconds past epoch

  if [ "$DO_REBUILD" = 'rebuild' ]; then
    _rebuild_vm_instances
    _wait_for_rpm_lock # needed to run the scripts immediately after rebuild
  fi

  _echoN; _copy_scripts
  _echoN; _run_scripts
  _echoN; _populate_repositories

  _echoN "done $(_duration_from "$START")"
}

#----------------
# This is needed for dnf install to finish and release transaction lock.
# Since on some Nectar images dnf_automatic is configured to run, and it
# prevents any packages from being installed immediately after the VM boots.
#
# This is only needed for some images (e.g. CentOS 8 Stream), but not
# others (e.g. CentOS 7).
#
# /var/lib/rpm/.rpm.lock

_wait_for_rpm_lock() {
  local MINUTES=5  # choose a large enough value that works (4 is too small)

  _echoN "waiting for RPM transaction locks to be released ($MINUTES minutes)"
  sleep $((MINUTES * 60))
}

#----------------

_test_update() {
  # Test how long it takes for a change to propagate from Stratum 0 to client
  local -r TEST_FILE=test-update.txt

  local -r REPO=$(echo "$REPO_NAMES" | awk '{print $1}') # use first if many

  local -r FQRN="$REPO.$REPO_ORG"

  if ! _ssh "$LOGIN_STRATUM0" test -e "/cvmfs/$FQRN" ; then
    _exit "repository does not exist: $FQRN"
  fi

  # If a transaction is still open, use this to discard its changes:
  # _ssh $LOGIN_STRATUM0 "sudo cvmfs_server abort $FQRN"

  _echoN "modifying \"$TEST_FILE\" in \"$FQRN\""
  _ssh "$LOGIN_PUBLISHER" "cvmfs_server transaction $FQRN"
  _ssh "$LOGIN_PUBLISHER" "date '+%F %T%z' > /cvmfs/$FQRN/$TEST_FILE"
  _ssh "$LOGIN_PUBLISHER" "cvmfs_server publish $FQRN"
  _echoN "/cvmfs/$FQRN/$TEST_FILE modified"
  _echoN
  _echoN "Waiting for update to appear on the client..."
  _ssh "$LOGIN_CLIENT" "./monitor-file.sh /cvmfs/$FQRN/$TEST_FILE"
}

#----------------

_repo_list() {
  _ssh "$LOGIN_STRATUM0" ls -1 /cvmfs
}

#----------------

_show_config() {
  cat <<EOF
Config file: $(cd "$(dirname "$CONFIG_FILE")"; pwd)/$(basename "$CONFIG_FILE")

Hosts:
  Stratum 0: $CVMFS_HOST_STRATUM0 ($CVMFS_USERNAME_STRATUM0; $PUBLISHER)
             VM instance: $VM_INSTANCE_S0
  Stratum 1: $CVMFS_HOST_STRATUM1 ($CVMFS_USERNAME_STRATUM1)
             VM instance: $VM_INSTANCE_S1
      Proxy: $CVMFS_HOST_PROXY ($CVMFS_USERNAME_PROXY)
             VM instance: $VM_INSTANCE_PROXY
     Client: $CVMFS_HOST_CLIENT ($CVMFS_USERNAME_CLIENT)
             VM instance: $VM_INSTANCE_CLIENT

Glance image for rebuilds: $REBUILD_IMAGE

Proxy:
  Disk cache location: $PROXY_DISK_CACHE_DIR
  Disk cache limit: $PROXY_DISK_CACHE_SIZE MiB
  Clients allowed access: $PROXY_ALLOWED_CLIENTS

Repositories (publishing file size limit: $CVMFS_FILE_MBYTE_LIMIT MiB):
EOF
  local NAME
  for NAME in $REPO_NAMES; do
    echo "  - $NAME.$REPO_ORG"
  done
}

#----------------------------------------------------------------
# Sub-commands

#----------------
# Rebuild VM instances and configure their volumes

_rebuild_vm_instances() {
  # Give the user an opportunity to abort

  _echoN "rebuilding VM instances (all four VM instances will be erased)"

  local X=10
  while [ "$X" -gt 0 ]; do
    sleep 1
    X=$((X - 1))
  done

  # Rebuild VM instances

  local -r START=$(date '+%s') # seconds past epoch

  "$EXE_DIR"/vm-rebuild.sh --config "$CONFIG_FILE"

  _echoN "VM instances rebuilt ($(_duration_from "$START"))"
}

#----------------

_copy_scripts() {
  # Copy scripts to respective hosts

  _echoN "copying scripts to hosts:"

  local -r MAIN_DIR="$EXE_DIR/.." # where the cvmfs-*-setup.sh scripts are

  _echoN "  cvmfs-stratum-0-setup.sh -> Stratum 0 ($CVMFS_HOST_STRATUM0)"
  scp -q -o $SSH_SHKC_OPTION "$MAIN_DIR/cvmfs-stratum-0-setup.sh" "$LOGIN_STRATUM0:"

  _echoN "  cvmfs-stratum-1-setup.sh -> Stratum 1 ($CVMFS_HOST_STRATUM1)"
  scp -q -o $SSH_SHKC_OPTION "$MAIN_DIR/cvmfs-stratum-1-setup.sh" "$LOGIN_STRATUM1:"

  _echoN "  cvmfs-proxy-setup.sh -> Proxy ($CVMFS_HOST_PROXY)"
  scp -q -o $SSH_SHKC_OPTION "$MAIN_DIR/cvmfs-proxy-setup.sh" "$LOGIN_PROXY:"

  _echoN "  cvmfs-client-setup.sh -> Client ($CVMFS_HOST_CLIENT)"
  scp -q -o $SSH_SHKC_OPTION "$MAIN_DIR/cvmfs-client-setup.sh" "$LOGIN_CLIENT:"

  # Client also gets the monitoring script that is used when testing updates

  _echoN "  monitor-file.sh -> Client ($CVMFS_HOST_CLIENT)"
  scp -q -o $SSH_SHKC_OPTION "$EXE_DIR/monitor-file.sh" "$LOGIN_CLIENT:"
}

#----------------
# This is automatically run as a part of _run_scripts, but can be run
# as a command too.

_copy_pubkeys() {
  # Copy all public keys from Stratum 0 host to Stratum 1 and Client hosts

  local TMP_DIR
  TMP_DIR="/tmp/${PROGRAM}-pubkeys-$$"
  mkdir "$TMP_DIR"

  KEYDIR=/etc/cvmfs/keys

  if ! _ssh_quiet "$LOGIN_STRATUM0" test -d $KEYDIR ; then
    _exit "no public keys: Stratum 0 not configured"
  fi

  _echoN "copying public keys from Stratum 0 ($CVMFS_HOST_STRATUM0):"

  for KEY in $(ssh -q -o $SSH_SHKC_OPTION "$LOGIN_STRATUM0" ls "$KEYDIR/*.pub");
  do
    local REPO
    REPO=$(basename "$KEY" .pub)

    _echoN "  Repository name: $REPO"

    # Copy public key from Stratum 0 to local computer

    local TMP
    TMP="$TMP_DIR/$REPO.pub"

    scp -q -o $SSH_SHKC_OPTION "$LOGIN_STRATUM0:$KEYDIR/$REPO.pub" "$TMP"
    chmod 644 "$TMP"

    # Copy public key from local computer to Stratum 1

    _echoN "    -> Stratum 1 ($CVMFS_HOST_STRATUM1)"
    _ssh_quiet "$LOGIN_STRATUM1"  mkdir -p $PUBKEY_DIRNAME
    scp -q -o $SSH_SHKC_OPTION \
        "$TMP" "$LOGIN_STRATUM1:$PUBKEY_DIRNAME/$REPO.pub"

    # Copy public key from local computer to client

    _echoN "    -> Client ($CVMFS_HOST_CLIENT)"
    _ssh_quiet "$LOGIN_CLIENT"  mkdir -p $PUBKEY_DIRNAME
    scp -q -o $SSH_SHKC_OPTION \
        "$TMP" "$LOGIN_CLIENT:$PUBKEY_DIRNAME/$REPO.pub"
  done

  # Clean up

  rm -r "$TMP_DIR"
}

#----

_stratum1_documentation_create_html() {
  local -r FILE="$1"

  # Using tee, since sudo privileges are required to write to the "$FILE".
  # The output from tee is saved into the file, but the output to stdout
  # is suppressed into /dev/null.

  _ssh "$LOGIN_STRATUM1" sudo tee "$FILE" >/dev/null <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <title>CVMFS Stratum 1</title>
  <style type="text/css">
body {
  font-family: sans-serif;
  background: #0A6A86;
  color: #fff;
  font-size: 14pt;
}
h1 {
  font-size: 36pt;
  color: #fff;
}
h2 {
  margin-top: 3ex;
}
a { color: #99f; }
a:hover { color: #cf0; }
.footer {
  margin-top: 8ex;
  font-size: smaller;
  opacity: 25%;
}
</style>
</head>
<body>
  <h1>CernVM-FS Stratum 1 replica</h1>

  <p>Only caching proxies should be connecting to this host.</p>

  <h2>Repositories</h2>

  <p>Fully qualified repository names:</p>

  <ul>
EOF

  # List the repositories (using the public key file names on Stratum 1)

  local PUBKEY
  for PUBKEY in $(_ssh "$LOGIN_STRATUM1" ls $PUBKEY_DIRNAME/*.pub); do
    PUBKEY="$(echo "$PUBKEY" | sed 's/\r*$//')" # strip trailing CR
    echo "    <li><code>$(basename "$PUBKEY" .pub)</code></li>" | \
      _ssh "$LOGIN_STRATUM1" sudo tee -a "$FILE" >/dev/null
  done

  _ssh "$LOGIN_STRATUM1" sudo tee -a "$FILE" >/dev/null <<EOF
  </ul>

  <h2>Public keys</h2>

  <p>The public keys for all the repositories can be
  downloaded as a gzipped tar file:</p>

  <ul>
    <li><a href="$PUBKEY_TAR_FILE_NAME">$PUBKEY_TAR_FILE_NAME</a></li>
  </ul>

<p class="footer">Last updated: $(date '+%F %T%z')</p>

</body>
</html>
EOF
}

#----

_create_stratum1_documentation() {
  _echoN "documenting repositories on Stratum 1's Web server"

  # Create directory

  local INSTALL_DIR=/var/www/html/$DOC_URL_PATH

  _ssh "$LOGIN_STRATUM1" sudo mkdir -p "$INSTALL_DIR"
  _ssh "$LOGIN_STRATUM1" sudo chown apache: "$INSTALL_DIR"
  _ssh "$LOGIN_STRATUM1" sudo chmod 755 "$INSTALL_DIR"

  # Create tar file containing the public keys

  local TAR_FILE=$INSTALL_DIR/$PUBKEY_TAR_FILE_NAME

  _ssh "$LOGIN_STRATUM1" sudo tar -c -f $TAR_FILE -z "$PUBKEY_DIRNAME"
  _ssh "$LOGIN_STRATUM1" sudo chown apache: $TAR_FILE
  _ssh "$LOGIN_STRATUM1" sudo chmod 644 $TAR_FILE

  # Create HTML file

  local HTML_FILE=$INSTALL_DIR/index.html

  _stratum1_documentation_create_html $HTML_FILE

  _ssh "$LOGIN_STRATUM1" sudo chown apache: $HTML_FILE
  _ssh "$LOGIN_STRATUM1" sudo chmod 644 $HTML_FILE

  _echoN "documented at <http://$CVMFS_HOST_STRATUM1/$DOC_URL_PATH>"
}

#----------------

_run_scripts() {
  _echoN "run-scripts"

  # Check if hosts are already setup: abort if any of them are

  local ALREADY_SETUP
  ALREADY_SETUP=
  if _ssh_quiet "$LOGIN_STRATUM0" 'test -e /cvmfs' ; then
    echo "$EXE: Stratum 0 already has CernVM-FS installed" >&2
    ALREADY_SETUP=yes
  fi
  if _ssh_quiet "$LOGIN_STRATUM1" 'test -e /cvmfs' ; then
    echo "$EXE: Stratum 1 already has CernVM-FS installed" >&2
    ALREADY_SETUP=yes
  fi
  if _ssh_quiet "$LOGIN_PROXY" 'test -e /etc/squid' ; then
    echo "$EXE: Proxy already has Squid installed" >&2
    ALREADY_SETUP=yes
  fi
  if _ssh_quiet "$LOGIN_CLIENT" 'test -e /cvmfs' ; then
    echo "$EXE: Client already has CernVM-FS installed" >&2
    ALREADY_SETUP=yes
  fi
  if [ -n "$ALREADY_SETUP" ]; then
    _exit "cannot run all the scripts, since some hosts already setup"
    exit 1
  fi

  # Run script on Stratum 0

  _echoN "setup Stratum 0"
  local -r START_0=$(date '+%s') # seconds past epoch

  if [ "$PUBLISHER" != "$CVMFS_USERNAME_STRATUM0" ]; then
    # Not using default user as the publisher: create the user account

    _echoN "publisher account: adduser: $PUBLISHER"
    _ssh "$LOGIN_STRATUM0" \
         sudo adduser "$PUBLISHER"

    _echoN "publisher account: creating ~$PUBLISHER/.ssh/authorized_keys"
    _ssh "$LOGIN_STRATUM0" sudo mkdir "~$PUBLISHER/.ssh"
    _ssh "$LOGIN_STRATUM0" sudo cp .ssh/authorized_keys "~$PUBLISHER/.ssh"
    _ssh "$LOGIN_STRATUM0" sudo chown -R "$PUBLISHER:" "~$PUBLISHER/.ssh"
  fi

  _ssh "$LOGIN_STRATUM0" \
       sudo ./cvmfs-stratum-0-setup.sh \
       --user "$PUBLISHER" \
       --file-limit $CVMFS_FILE_MBYTE_LIMIT \
       $(for N in $REPO_NAMES; do echo "$N.$REPO_ORG"; done)
  # The "for" in the above line can produce multiple arguments for the setup script.
  # Do not quote it, otherwise it becomes one argument.

  _echoN "setup Stratum 0: $(_duration_from "$START_0")"

  # Copy the keys to the Stratum 1 and Client

  _echoN
  _copy_pubkeys

  # Run script on Stratum 1

  _echoN
  _echoN "setup Stratum 1"
  local -r START_1=$(date '+%s') # seconds past epoch

  _ssh "$LOGIN_STRATUM1" \
       sudo ./cvmfs-stratum-1-setup.sh --stratum-0 "$CVMFS_HOST_STRATUM0" \
       --refresh 2 \
       $PUBKEY_DIRNAME/\*.pub

  # Create documentation on Stratum 1

  _create_stratum1_documentation

  _echoN "setup Stratum 1: $(_duration_from "$START_1")"

  # Run script on proxy

  _echoN
  _echoN "setup proxy"
  local -r START_P=$(date '+%s') # seconds past epoch

  _ssh "$LOGIN_PROXY" \
       sudo ./cvmfs-proxy-setup.sh \
       --stratum-1 "$CVMFS_HOST_STRATUM1" \
       --max-object-size "$CVMFS_FILE_MBYTE_LIMIT" \
       --disk-cache-dir "$PROXY_DISK_CACHE_DIR" \
       --disk-cache-size "$PROXY_DISK_CACHE_SIZE" \
       $PROXY_ALLOWED_CLIENTS

  _echoN "setup proxy: $(_duration_from "$START_P")"

  # Run script on client

  _echoN
  _echoN "setup client"
  local -r START_C=$(date '+%s') # seconds past epoch

  _ssh "$LOGIN_CLIENT" \
       sudo ./cvmfs-client-setup.sh --stratum-1 "$CVMFS_HOST_STRATUM1" \
       --proxy "$CVMFS_HOST_PROXY" \
       --no-geo-api \
       $PUBKEY_DIRNAME/\*.pub

  _echoN "setup client: $(_duration_from "$START_C")"
}

#----------------
# Populate the repositories

_populate_repositories() {
  _echoN "populating CernVM-FS repositories"

  local -r START=$(date '+%s') # seconds past epoch
  local -r POPULATE_SCRIPT="$EXE_DIR/repo-populate.sh"

  # Copy the populate script to the Stratum 0 host

  scp -q -o $SSH_SHKC_OPTION "$POPULATE_SCRIPT" "$LOGIN_PUBLISHER:"

  # Run it on each of the repositories

  local OPT
  if [ -n "$VERBOSE" ]; then
    OPT=--verbose
  elif [ -n "$QUIET" ]; then
    OPT=--quiet
  else
    OPT=
  fi

  local -r POPULATE_SCRIPT_NAME=$(basename "$POPULATE_SCRIPT")

  for NAME in $REPO_NAMES; do
    _ssh "$LOGIN_PUBLISHER" \
         "./$POPULATE_SCRIPT_NAME" $OPT "$CONTENT_DIR/$NAME" "$NAME.$REPO_ORG"
    _echoN
  done

  _echoN "populated CernVM-FS repositories: $(_duration_from "$START")"
}

#----------------------------------------------------------------
# Main

_main() {
  _load_config

  LOGIN_STRATUM0="$CVMFS_USERNAME_STRATUM0@$CVMFS_HOST_STRATUM0"
  LOGIN_STRATUM1="$CVMFS_USERNAME_STRATUM1@$CVMFS_HOST_STRATUM1"
  LOGIN_PROXY="$CVMFS_USERNAME_PROXY@$CVMFS_HOST_PROXY"
  LOGIN_CLIENT="$CVMFS_USERNAME_CLIENT@$CVMFS_HOST_CLIENT"
  LOGIN_PUBLISHER="$PUBLISHER@$CVMFS_HOST_STRATUM0"

  case $COMMAND in
    reset-all) _reset_all rebuild ;;
    setup-all) _reset_all no-rebuild ;;
    test-update) _test_update ;;

    list-repos) _repo_list ;;
    show-config) _show_config ;;

    ssh-stratum-0|ssh-s0|s0) _ssh $LOGIN_STRATUM0 ;;
    ssh-stratum-1|ssh-s1|s1) _ssh $LOGIN_STRATUM1 ;;
    ssh-proxy|sp) _ssh $LOGIN_PROXY ;;
    ssh-client|sc) _ssh $LOGIN_CLIENT ;;
    ssh-publisher|pub) _ssh $LOGIN_PUBLISHER ;;

    rebuild-vm) _rebuild_vm_instances ;;
    copy-scripts) _copy_scripts ;;
    copy-pubkeys) _copy_pubkeys ;;
    run-scripts) _run_scripts ;;
    document-repos) _create_stratum1_documentation ;;
    populate-repos) _populate_repositories ;;

    *)
      echo "$EXE: usage error: unknown command: $COMMAND (-h for help)" >&2
      exit 2
      ;;
  esac
}

#----------------

_main

#EOF

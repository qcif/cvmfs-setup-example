#!/bin/sh
#
# Utility to simplify testing to easily:
#
# - copy the scripts to the test hosts;
# - copy the public keys from the Stratum 0 host to the Stratum 1 and client.
# - ssh to any of the four hosts.
#
# Typically, four new hosts are created and then:
#
# 0. Create a "setup-example.conf" file with their addresses and account(s).
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

PROGRAM='setup-example'
VERSION='1.1.0'

EXE=$(basename "$0" .sh)
EXE_EXT=$(basename "$0")

#----------------------------------------------------------------
# Error handling

# Exit immediately if a simple command exits with a non-zero status.
# Better to abort than to continue running when something went wrong.
set -e

set -u # fail on attempts to expand undefined environment variables

#----------------------------------------------------------------
# Defaults

DEFAULT_CONFIG_FILES="
 $HOME/.config/cvmfs-setup-example.conf
 $HOME/.cvmfs-setup-example.conf
 cvmfs-setup-example.conf
 setup-example.conf
"

DEFAULT_REPOSITORIES="data.example.org tools.example.org"

#----------------------------------------------------------------
# Command line arguments
# Note: parsing does not support combining single letter options (e.g. "-vh")

CONFIG_FILE=
PROXY_ALLOWED_CLIENTS=
REPOSITORIES=
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
    --repository|--repo|-r)
      if [ $# -lt 2 ]; then
        echo "$EXE: usage error: $1 missing value" >&2
        exit 2
      fi
      REPOSITORIES="$REPOSITORIES $2"
      shift; shift
      ;;
    --allow-client|-a)
      if [ $# -lt 2 ]; then
        echo "$EXE: usage error: $1 missing value" >&2
        exit 2
      fi
      PROXY_ALLOWED_CLIENTS="$PROXY_ALLOWED_CLIENTS $2"
      shift; shift
      ;;
    --allow-all-clients|-A)
      # Not recommended, since it could allow any client in the world to
      # connect to the proxy. But is quick and easy for testing, when
      # the tester does not know the address range of their clients.
      PROXY_ALLOWED_CLIENTS=0.0.0.0/0
      shift;
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
        echo "$EXE: usage error: unexpected argument: $1" >&2
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
  -c | --config FILE           configuration of the hosts and accounts
  -r | --repository NAME       repositories for setup-all and test-update *
  -a | --allow-client CIDR     addresses of clients allowed to use the proxy *
  -A | --allow-all-clients     allow anyone to use the proxy (not recommended)
       --version               display version information and exit
  -h | --help                  display this help and exit
                               * = repeatable
Commands:
  show-config        show the configuration that will be used
  setup-all          run all the setup scripts on the respective hosts
  repo-list          list available repositories from the Stratum 0
  test-update        modify file on Stratum 0 and wait for change on the Client

  cs | copy-scripts  copies the scripts to their respective hosts
  cp | copy-pubkeys  copies public keys from Stratum 0 to Stratum 1 and Client
  s0 | ssh-s0        ssh to the Stratum 0 host
  s1 | ssh-s1        ssh to the Stratum 1 host
  sp | ssh-proxy     ssh to the Proxy host
  sc | ssh-client    ssh to the Client host

Default repositories: $DEFAULT_REPOSITORIES

Default config files (tried in order if --config not specified):
EOF

  # -v | --verbose      output extra information when running

  for F in $DEFAULT_CONFIG_FILES; do
    echo "  $F"
  done
  echo

  exit 0
fi

if [ -n "$SHOW_VERSION" ]; then
  echo "$PROGRAM $VERSION"
  exit 0
fi

#----------------------------------------------------------------
# Load test environment from config file

CVMFS_HOST_STRATUM0=
CVMFS_HOST_STRATUM1=
CVMFS_HOST_PROXY=
CVMFS_HOST_CLIENT=

CVMFS_USERNAME_STRATUM0=
CVMFS_USERNAME_STRATUM1=
CVMFS_USERNAME_PROXY=
CVMFS_USERNAME_CLIENT=

CVMFS_USERNAME=

SAVED_REPOSITORIES=$REPOSITORIES
SAVED_PROXY_ALLOWED_CLIENTS=$PROXY_ALLOWED_CLIENTS

if [ -n "$CONFIG_FILE" ]; then
  # Config file specified on command line: only load that one file
  source "$CONFIG_FILE" # set environment variables from it

  CFG_ERR="not defined: fix config file: $CONFIG_FILE"
else
  # No config file on command line: try loading all default files

  CFG_ERR='not defined: missing config file'

  for CONFIG_FILE in $DEFAULT_CONFIG_FILES ; do
    if [ -f "$CONFIG_FILE" ]; then
      CFG_ERR="not defined: fix config file: $CONFIG_FILE"
      source "$CONFIG_FILE" # set environment variables from it
    fi
  done
fi

# Restore command line values that override any values in the config file(s)

if [ -n "$SAVED_REPOSITORIES" ]; then
  REPOSITORIES="$SAVED_REPOSITORIES"
fi

if [ -n "$SAVED_PROXY_ALLOWED_CLIENTS" ]; then
  PROXY_ALLOWED_CLIENTS="$SAVED_PROXY_ALLOWED_CLIENTS"
fi

# Check test environment variables have been set

if [ -z "$CVMFS_HOST_STRATUM0" ]; then
  echo "$EXE: error: CVMFS_HOST_STRATUM0 $CFG_ERR" >&2
  exit 1
fi
if [ -z "$CVMFS_HOST_STRATUM1" ]; then
  echo "$EXE: error: CVMFS_HOST_STRATUM1 $CFG_ERR" >&2
  exit 1
fi
if [ -z "$CVMFS_HOST_PROXY" ]; then
  echo "$EXE: error: CVMFS_HOST_PROXY $CFG_ERR" >&2
  exit 1
fi
if [ -z "$CVMFS_HOST_CLIENT" ]; then
  echo "$EXE: error: CVMFS_HOST_CLIENT $CFG_ERR" >&2
  exit 1
fi

# Set per-host usernames

if [ -z "$CVMFS_USERNAME_STRATUM0" ]; then
  if [ -z "$CVMFS_USERNAME" ]; then
    echo "$EXE: error: CVMFS_USERNAME and CVMFS_USERNAME_STRATUM0 $CFG_ERR" >&2
    exit 1
  fi
  CVMFS_USERNAME_STRATUM0=$CVMFS_USERNAME
fi
if [ -z "$CVMFS_USERNAME_STRATUM1" ]; then
  if [ -z "$CVMFS_USERNAME" ]; then
    echo "$EXE: error: CVMFS_USERNAME and CVMFS_USERNAME_STRATUM1 $CFG_ERR" >&2
    exit 1
  fi
  CVMFS_USERNAME_STRATUM1=$CVMFS_USERNAME
fi
if [ -z "$CVMFS_USERNAME_PROXY" ]; then
  if [ -z "$CVMFS_USERNAME" ]; then
    echo "$EXE: error: CVMFS_USERNAME and CVMFS_USERNAME_PROXY $CFG_ERR" >&2
    exit 1
  fi
  CVMFS_USERNAME_PROXY=$CVMFS_USERNAME
fi
if [ -z "$CVMFS_USERNAME_CLIENT" ]; then
  if [ -z "$CVMFS_USERNAME" ]; then
    echo "$EXE: error: CVMFS_USERNAME and CVMFS_USERNAME_CLIENT $CFG_ERR" >&2
    exit 1
  fi
  CVMFS_USERNAME_CLIENT=$CVMFS_USERNAME
fi

# Set address variables

ADDR_STRATUM0="$CVMFS_USERNAME_STRATUM0@$CVMFS_HOST_STRATUM0"
ADDR_STRATUM1="$CVMFS_USERNAME_STRATUM1@$CVMFS_HOST_STRATUM1"
ADDR_PROXY="$CVMFS_USERNAME_PROXY@$CVMFS_HOST_PROXY"
ADDR_CLIENT="$CVMFS_USERNAME_CLIENT@$CVMFS_HOST_CLIENT"

#----------------------------------------------------------------
# Run command

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

_copy_scripts() {
  # Copy scripts to respective hosts

  echo "Copying scripts:"

  echo "  cvmfs-stratum-0-setup.sh -> Stratum 0 ($CVMFS_HOST_STRATUM0)"
  scp -q -o $SSH_SHKC_OPTION cvmfs-stratum-0-setup.sh $ADDR_STRATUM0:

  echo "  cvmfs-stratum-1-setup.sh -> Stratum 1 ($CVMFS_HOST_STRATUM1)"
  scp -q -o $SSH_SHKC_OPTION cvmfs-stratum-1-setup.sh $ADDR_STRATUM1:

  echo "  cvmfs-proxy-setup.sh -> Proxy ($CVMFS_HOST_PROXY)"
  scp -q -o $SSH_SHKC_OPTION cvmfs-proxy-setup.sh  $ADDR_PROXY:

  echo "  cvmfs-client-setup.sh -> Client ($CVMFS_HOST_CLIENT)"
  scp -q -o $SSH_SHKC_OPTION cvmfs-client-setup.sh $ADDR_CLIENT:

  echo "  monitor-file.sh -> Client ($CVMFS_HOST_CLIENT)"
  scp -q -o $SSH_SHKC_OPTION monitor-file.sh $ADDR_CLIENT:
}

#----------------

_copy_pubkeys() {
  # Copy all public keys from Stratum 0 host to Stratum 1 and Client hosts

  TMP="/tmp/${PROGRAM}-$$.pub"

  echo "Copying public keys from Stratum 0 ($CVMFS_HOST_STRATUM0):"

  KEYDIR=/etc/cvmfs/keys

  for KEY in $(ssh -o $SSH_SHKC_OPTION $ADDR_STRATUM0 ls "$KEYDIR/*.pub"); do
    REPO=$(basename $KEY .pub)

    echo "  Repository name: $REPO"

    scp -q -o $SSH_SHKC_OPTION $ADDR_STRATUM0:$KEYDIR/$REPO.pub $TMP
    chmod 644 $TMP

    echo "    -> Stratum 1 ($CVMFS_HOST_STRATUM1)"
    scp -q -o $SSH_SHKC_OPTION $TMP $ADDR_STRATUM1:$REPO.pub

    echo "    -> Client ($CVMFS_HOST_CLIENT)"
    scp -q -o $SSH_SHKC_OPTION $TMP $ADDR_CLIENT:$REPO.pub
  done

  rm -f $TMP
}

#----------------

_echo() {
  # Show information that will be useful when configuring that host.
  echo ">>> $*"
}

#----------------

_ssh_quiet() {
  # Run SSH
  ssh -q -o $SSH_SHKC_OPTION -t $*
}

_ssh() {
  # Run SSH
  _echo "ssh $*"
  _ssh_quiet $*
}

#----------------

_show_config() {
  echo "Configuration:"
  echo "  Stratum 0: $ADDR_STRATUM0"
  echo "  Stratum 1: $ADDR_STRATUM1"
  echo "      Proxy: $ADDR_PROXY"
  echo "     Client: $ADDR_CLIENT"
  if [ -n "$PROXY_ALLOWED_CLIENTS" ]; then
    echo "Proxy created by \"setup-all\" will allow connections from: $PROXY_ALLOWED_CLIENTS"
  fi
  if [ -n "$REPOSITORIES" ]; then
    echo "Repositories: $REPOSITORIES"
  fi
}

#----------------

_setup_all() {
  if [ -z "$REPOSITORIES" ]; then
    REPOSITORIES=$DEFAULT_REPOSITORIES
  fi
  if [ -z "$PROXY_ALLOWED_CLIENTS" ]; then
    echo "$EXE: usage error: missing --allow-client" >&2
    exit 2
  fi

  # Check if hosts are already setup

  if _ssh_quiet $ADDR_STRATUM0 'test -e /cvmfs' ; then
    echo "$EXE: error: Stratum 0 already has CernVM-FS installed" >&2
    exit 1
  fi
  if _ssh_quiet $ADDR_STRATUM1 'test -e /cvmfs' ; then
    echo "$EXE: error: Stratum 1 already has CernVM-FS installed" >&2
    exit 1
  fi
  if _ssh_quiet $ADDR_PROXY 'test -e /etc/squid' ; then
    echo "$EXE: error: Proxy already has Squid installed" >&2
    exit 1
  fi
  if _ssh_quiet $ADDR_CLIENT 'test -e /cvmfs' ; then
    echo "$EXE: error: Client already has CernVM-FS installed" >&2
    exit 1
  fi

  # Setup all the hosts

  _echo "setup-all:"
  _echo "  This will copy the scripts to the hosts and then run them,"
  _echo "  creating all four servers in about 10 minutes."
  _echo

  _copy_scripts
  echo

  _ssh $ADDR_STRATUM0 \
       sudo ./cvmfs-stratum-0-setup.sh $REPOSITORIES
  echo

  _copy_pubkeys
  echo

  _ssh $ADDR_STRATUM1 \
       sudo ./cvmfs-stratum-1-setup.sh --stratum-0 $CVMFS_HOST_STRATUM0 \
       --refresh 2 \
       \*.pub
  echo

  _ssh $ADDR_PROXY \
       sudo ./cvmfs-proxy-setup.sh --stratum-1 $CVMFS_HOST_STRATUM1 \
       $PROXY_ALLOWED_CLIENTS
  echo

  _ssh $ADDR_CLIENT \
       sudo ./cvmfs-client-setup.sh --stratum-1 $CVMFS_HOST_STRATUM1 \
       --proxy $CVMFS_HOST_PROXY \
       --no-geo-api \
       \*.pub
  echo

  echo "$EXE: done"
}

#----------------

_repo_list() {
  _ssh_quiet $ADDR_STRATUM0 ls -1 /cvmfs
}

#----------------

_test_update() {
  # Test how long it takes for a change to propagate from Stratum 0 to client
  TEST_FILE=test-update.txt
  if [ -z "$REPOSITORIES" ]; then
    REPOSITORIES=$DEFAULT_REPOSITORIES
  fi
  REPO=$(echo $REPOSITORIES | awk '{print $1}') # only use first, if multiples

  if ! _ssh_quiet $ADDR_STRATUM0 test -e /cvmfs/$REPO ; then
    echo "$EXE: error: repository does not exist: $REPO" >&2
    exit 1
  fi

  _echo "test-update:"
  _echo "  This will create/update a file on the Stratum 0"
  _echo "  and wait for it to propagate, via the Stratum 1"
  _echo "  and the Proxy, to change on the client."
  _echo
  _echo "Updating \"$TEST_FILE\" in the \"$REPO\" repository."

  # If a transaction is still open, use this to discard its changes:
  # _ssh $ADDR_STRATUM0 "sudo cvmfs_server abort $REPO"

  _ssh $ADDR_STRATUM0 "sudo cvmfs_server transaction $REPO"
  _ssh $ADDR_STRATUM0 "date > /cvmfs/$REPO/$TEST_FILE"
  _ssh $ADDR_STRATUM0 "sudo cvmfs_server publish $REPO"

  _echo "Waiting for update to appear in on the client..."
  _ssh $ADDR_CLIENT "./monitor-file.sh /cvmfs/$REPO/$TEST_FILE"

}

#----------------

case $COMMAND in
  show-config)
    _show_config
    ;;

  setup-all)
    _setup_all
    ;;

  repo-list)
    _repo_list
    ;;

  test-update)
    _test_update
    ;;

  copy-scripts)
    _copy_scripts
    ;;

  copy-pubkeys|copy-pubkey|cp)
    _copy_pubkeys
    ;;

  ssh-stratum-0|ssh-s0|s0)
    # SSH to Stratum 0
    _ssh $ADDR_STRATUM0
    ;;

  ssh-stratum-1|ssh-s1|s1)
    # SSH to Stratum 1
    _echo "Stratum 0: $CVMFS_HOST_STRATUM0"
    _ssh $ADDR_STRATUM1
    ;;

  ssh-proxy|sp)
    # SSH to Proxy
    _echo "Stratum 1: $CVMFS_HOST_STRATUM1"
    _ssh $ADDR_PROXY
    ;;

  ssh-client|sc)
    # SSH to Client
    _echo "Stratum 1: $CVMFS_HOST_STRATUM1"
    _echo "Proxy: $CVMFS_HOST_PROXY"
    _ssh $ADDR_CLIENT
    ;;

  '')
    echo "$EXE: usage error: missing command (-h for help)" >&2
    exit 2
    ;;

  *)
    echo "$EXE: usage error: unknown command: $COMMAND (-h for help)" >&2
    exit 2
    ;;
esac

#EOF

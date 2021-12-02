#!/bin/bash
#
# Copyright (C) 2021, QCIF Ltd.
#================================================================

PROGRAM='reset-vm'
VERSION='0.9.0'

EXE=$(basename "$0" .sh)
EXE_EXT=$(basename "$0")
EXE_DIR=$(cd "$(dirname "$0")"; pwd)

#----------------------------------------------------------------
# Constants

#----------------------------------------------------------------
# Defaults

DEFAULT_CONFIG_FILES="
 $HOME/.config/cvmfs-example-setup.conf
 $HOME/.cvmfs-example-setup.conf
 cvmfs-example-setup.conf
 example-setup.conf
"

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
# Command line arguments
# Note: parsing does not support combining single letter options (e.g. "-vh")

CONFIG_FILE=

QUIET=
VERBOSE=
SHOW_VERSION=
SHOW_HELP=

while [ $# -gt 0 ]
do
  case "$1" in
    -c|--config)
      if [ $# -lt 2 ]; then
        echo "$EXE: usage error: $1 missing value" >&2
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

      echo "$EXE: usage error: unexpected argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ -n "$SHOW_HELP" ]; then
  cat <<EOF
Usage: $EXE_EXT [options]
Options:
  -c | --config FILE  config file
  -q | --quiet        output nothing unless an error occurs
  -v | --verbose      output extra information
       --version      display version information and exit
  -h | --help         display this help and exit
EOF

  exit 0
fi

if [ -n "$SHOW_VERSION" ]; then
  echo "$PROGRAM $VERSION"
  exit 0
fi

#----------------------------------------------------------------
# Utility functions

#----------------
# Normal echo
# Does not output if --quiet used.

_echoN() {
  if [ -z "$QUIET" ]; then
    echo "$EXE: $*"
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

#----------------------------------------------------------------
# Checks

if ! which openstack >/dev/null; then
  _exit "openstack command line client not found"
fi

if [ -z "$OS_PROJECT_ID" ]; then
  _exit "project not defined: source an OpenStack RC file"
fi

if [ -z "$OS_USERNAME" ]; then
  _exit "user not defined: source an OpenStack RC file"
fi

#----------------------------------------------------------------

_rebuild_all() {
  for VM_INSTANCE in \
    $VM_INSTANCE_S0 $VM_INSTANCE_S1 $VM_INSTANCE_PROXY $VM_INSTANCE_CLIENT; do

    _echoN "rebuilding VM instance: $VM_INSTANCE"

    # Run command (saving output to a temporary file)

    local TMP=/tmp/$PROGRAM-openstack-rebuild-$$.txt

    if ! openstack server rebuild --image "$REBUILD_IMAGE" "$VM_INSTANCE" \
         -f yaml \
         --wait >$TMP 2>&1; then
      cat $TMP
      rm $TMP
      _exit "openstack server rebuild failed"
    fi

    # Show output

    if [ -n "$VERBOSE" ]; then
      cat $TMP
    elif [ -z "$QUIET" ]; then
      grep -E 'image|name|status' "$TMP"\
        | grep -v 'readline' | grep -v '^$' \
        | sed 's/^/  /'
    fi
    rm $TMP
  done
}

#----------------

_ssh_quiet() {
  # Run SSH
  ssh -q -o "$SSH_SHKC_OPTION" -t $*
}

_ssh() {
  # Run SSH
  _echoV "ssh $*"
  _ssh_quiet $*
}

#----------------------------------------------------------------

#----------------
# Option for SSH (ssh and scp): StrictHostKeyChecking=off
# automatically add host key to ~/.ssh/known_hosts, and allows
# connections to hosts with changed host keys to proceed. THIS IS
# UNSAFE, but for testing it is more convenient when the host and
# their host keys often change.  Unfortunately, there is no way to not
# add the host keys to the file and to allow connections where the
# host key is not in the file.
#
# See `man ssh_config` for details

SSH_SHKC_OPTION=StrictHostKeyChecking=off

PVOL_SCRIPT='vm-volume-setup.sh'

# Run vm-volume-setup.sh with --quiet unless this script is run with verbose

PVOL_QUIET_OPT=--quiet
if [ -n "$VERBOSE" ]; then
  PVOL_QUIET_OPT=
fi

#----------------

_volume_attach_s0() {

  # Stratum 0

  if [ -n "$VERBOSE" ]; then
    echo
  fi
  _echoN "volume setup for Stratum 0"

  local -r U=$CVMFS_USERNAME_STRATUM0@$CVMFS_HOST_STRATUM0

  scp -q -o $SSH_SHKC_OPTION "$EXE_DIR/$PVOL_SCRIPT" "$U:"

  _ssh_quiet "$U"  sudo bash ./$PVOL_SCRIPT -y $PVOL_QUIET_OPT cvmfs
  _ssh_quiet "$U"  rm $PVOL_SCRIPT
}

#----------------

_volume_attach_s1() {
  # Stratum 1

  if [ -n "$VERBOSE" ]; then
    echo
  fi
  _echoN "volume setup for Stratum 1"

  local -r U=$CVMFS_USERNAME_STRATUM1@$CVMFS_HOST_STRATUM1

  scp -q -o $SSH_SHKC_OPTION "$EXE_DIR/$PVOL_SCRIPT" "$U:"

  _ssh_quiet "$U"  sudo bash ./$PVOL_SCRIPT -y $PVOL_QUIET_OPT cvmfs
  _ssh_quiet "$U"  rm $PVOL_SCRIPT
}

#----------------

_volume_attach_proxy() {

  if [ -n "$VERBOSE" ]; then
    echo
  fi
  _echoN "volume setup for proxy"

  local -r U=$CVMFS_USERNAME_PROXY@$CVMFS_HOST_PROXY

  scp -q -o $SSH_SHKC_OPTION "$EXE_DIR/$PVOL_SCRIPT" "$U:"

  _ssh_quiet "$U"  sudo bash ./$PVOL_SCRIPT -y $PVOL_QUIET_OPT proxy
  _ssh_quiet "$U"  rm $PVOL_SCRIPT
}

#----------------

_volume_attach_client() {

  if [ -n "$VERBOSE" ]; then
    echo
  fi
  _echoN "volume setup for client: N/A"
}

#----------------------------------------------------------------
# Load configuration

if [ -n "$CONFIG_FILE" ]; then
  # Config file specified on command line: only load that one file
  source "$CONFIG_FILE" # set environment variables from it
else
  # No config file on command line: try loading all default files

  for CONFIG_FILE in $DEFAULT_CONFIG_FILES ; do
    if [ -f "$CONFIG_FILE" ]; then
      source "$CONFIG_FILE" # set environment variables from it
    fi
  done
fi

#----------------------------------------------------------------

_main() {
  # Rebuild VM instances

  _rebuild_all

  # Wait for VM instances to fully start up

  local MINUTES=1
  _echoN "waiting for VM instances to accept SSH connections ($MINUTES minute)"
  sleep $((MINUTES * 60))

  # Mount volume storage in VM instances

  _volume_attach_s0
  _volume_attach_s1
  _volume_attach_proxy
  _volume_attach_client
}

_main

#EOF

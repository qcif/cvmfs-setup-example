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
VERSION='1.0.0'

EXE=$(basename "$0" .sh)
EXE_EXT=$(basename "$0")

#----------------------------------------------------------------
# Error handling

# Exit immediately if a simple command exits with a non-zero status.
# Better to abort than to continue running when something went wrong.
set -e

set -u # fail on attempts to expand undefined environment variables

#----------------------------------------------------------------
# Configure test environment

CVMFS_HOST_STRATUM0=
CVMFS_HOST_STRATUM1=
CVMFS_HOST_PROXY=
CVMFS_HOST_CLIENT=

CVMFS_USERNAME_STRATUM0=
CVMFS_USERNAME_STRATUM1=
CVMFS_USERNAME_PROXY=
CVMFS_USERNAME_CLIENT=

CVMFS_USERNAME=

# Load from configuration file (if any of them exists)

CONFIG_FILES="$HOME/.cvmfs-setup-example.conf cvmfs-setup-example.conf setup-example.conf"

CFG_ERR='not defined: missing config file'

for CONFIG_FILE in $CONFIG_FILES ; do
  if [ -f "$CONFIG_FILE" ]; then
    CFG_ERR="not defined: fix config file: $CONFIG_FILE"
    # Source it to set environment variables
    . "$CONFIG_FILE"
  fi
done

# Check test environment variables have been set (usuall from a config file)

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

# Option for SSH: StrictHostKeyChecking=off automatically add host key
# to ~/.ssh/known_hosts, and allows connections to hosts with changed
# hostkeys to proceed. THIS IS UNSAFE, but for testing it is more
# convenient when the host and their host keys often change.
# Unfortunately, there is no way to not add the host keys to the file
# and to allow connections where the host key is not in the file.
#
# See `man ssh_config` for details

SSH_SHKC_OPTION=StrictHostKeyChecking=off

_ssh() {
  ssh -o $SSH_SHKC_OPTION "$1"
}

HIGHLIGHT_PREFIX='>>> '

#----------------

if [ $# -gt 1 ]; then
  echo "$EXE: usage error: too many arguments" >&2
  exit 2

elif [ $# -eq 0 ] || [ "$1" = '-h' ] || [ "$1" = '--help' ]; then
  # Help
  cat <<EOF
Usage: $EXE_EXT command
Commands:
  cs | copy-scripts  copies cvmfs-*-setup.sh scripts to their respective hosts
  cp | copy-pubkeys  copies public keys from Stratum 0 to Stratum 1 and Client
  s0 | ssh-s0        ssh to the Stratum 0 host
  s1 | ssh-s1        ssh to the Stratum 1 host
  sp | ssh-proxy     ssh to the Proxy host
  sc | ssh-client    ssh to the Client host

Configure hosts and accounts as environment variables in a config file:
EOF
  for F in $CONFIG_FILES; do
    echo "  $F"
  done
  exit 2

  #----------------
elif [ "$1" = 'copy-scripts' ] || [ "$1" = 'cs' ]; then
  # Copy scripts to hosts

  echo "Scripts:"

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

  #----------------
elif [ "$1" = 'copy-pubkeys' ] || [ "$1" = 'copy-pubkey' ] || \
       [ "$1" = 'cp' ]; then
  # Copy public keys from Stratum 0 central server to client

  echo "Public keys from Stratum 0 ($CVMFS_HOST_STRATUM0):"

  KEYDIR=/etc/cvmfs/keys

  for KEY in $(ssh -o $SSH_SHKC_OPTION $ADDR_STRATUM0 ls "$KEYDIR/*.pub"); do
    REPO=$(basename $KEY .pub)

    echo "  Repository name: $REPO"

    scp -q -o $SSH_SHKC_OPTION $ADDR_STRATUM0:$KEYDIR/$REPO.pub $REPO.pub
    chmod 644 $REPO.pub

    echo "    -> Stratum 1 ($CVMFS_HOST_STRATUM1)"
    scp -q -o $SSH_SHKC_OPTION $REPO.pub $ADDR_STRATUM1:$REPO.pub

    echo "    -> Client ($CVMFS_HOST_CLIENT)"
    scp -q -o $SSH_SHKC_OPTION $REPO.pub $ADDR_CLIENT:$REPO.pub
  done

  #----------------
elif [ "$1" = 'ssh-s0' ] || [ "$1" = 's0' ]; then
  # SSH to Stratum 0
  _ssh $ADDR_STRATUM0

  #----------------
elif [ "$1" = 'ssh-s1' ] || [ "$1" = 's1' ]; then
  # SSH to Stratum 1
  echo "${HIGHLIGHT_PREFIX}Stratum 0: $CVMFS_HOST_STRATUM0"
  _ssh $ADDR_STRATUM1

  #----------------
elif [ "$1" = 'ssh-proxy' ] || [ "$1" = 'sp' ]; then
  # SSH to Proxy
  echo "${HIGHLIGHT_PREFIX}Stratum 1: $CVMFS_HOST_STRATUM1"
  _ssh $ADDR_PROXY
  #----------------
elif [ "$1" = 'ssh-client' ] || [ "$1" = 'sc' ]; then
  # SSH to Client
  echo "${HIGHLIGHT_PREFIX}Stratum 1: $CVMFS_HOST_STRATUM1"
  echo "${HIGHLIGHT_PREFIX}Proxy: $CVMFS_HOST_PROXY"
  _ssh $ADDR_CLIENT

  #----------------
else
  echo "$EXE: usage error: unknown command: $1 (-h for help)" >&2
  exit 2
fi

# In the above SSH commands:
#
# - As a reminder, the above SSH commands displays ">>> address" for
#   address values that will be needed when configuring that
#   particular host.

#EOF

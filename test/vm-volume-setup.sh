#!/bin/bash
#
# Copyright (C) 2021, QCIF Ltd.
#================================================================

PROGRAM='setup-pvol'
VERSION='1.0.0'

EXE=$(basename "$0" .sh)
EXE_EXT=$(basename "$0")

BLOCK_DEVICE_NAME=vdb
VOL_MOUNT_DIR=/pvol

#----------------------------------------------------------------
# Error handling

# Exit immediately if a simple command exits with a non-zero status.
# Better to abort than to continue running when something went wrong.
set -e

set -u # fail on attempts to expand undefined environment variables

#----------------------------------------------------------------

#----------------------------------------------------------------
# Command line arguments
# Note: parsing does not support combining single letter options (e.g. "-vh")

INTERACTIVE=
QUIET=
VERBOSE=
SHOW_VERSION=
SHOW_HELP=
HOST_TYPE=

while [ $# -gt 0 ]
do
  case "$1" in
    -y|--yes)
      INTERACTIVE=yes
      shift
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

      HOST_TYPE="$1"

      shift
      ;;
  esac
done

if [ -n "$SHOW_HELP" ]; then
  cat <<EOF
Usage: $EXE_EXT [options] type
Options:
  -y | --yes       non-interactive
  -q | --quiet     output nothing unless an error occurs
  -v | --verbose   output extra information when running
       --version   display version information and exit
  -h | --help      display this help and exit
type:
  cvmfs
  proxy
EOF

  exit 0
fi

if [ -n "$SHOW_VERSION" ]; then
  echo "$PROGRAM $VERSION"
  exit 0
fi

if [ "$HOST_TYPE" != 'cvmfs' ] && [ "$HOST_TYPE" != 'proxy' ]; then
  echo "$EXE: usage error: unknown type (expecting cvmfs or proxy): $HOST_TYPE" >&2
  exit 2
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
# Check for root privileges

if [ "$(id -u)" -ne 0 ]; then
  _exit "root privileges required"
fi

#----------------------------------------------------------------

_mount_volume() {
  _echoN "mounting volume storage"

  # Check disk exists

  if ! lsblk --noheadings -o TYPE,NAME | grep -qE "^disk $BLOCK_DEVICE_NAME$";
  then
    _exit "disk block device not found: $BLOCK_DEVICE_NAME"
  fi

  # Check volume is not partitioned

  if lsblk --noheadings --ascii -o TYPE,NAME \
      | grep -qE "^part \`-$BLOCK_DEVICE_NAME";
  then
    _exit "partitioned volume not supported: $BLOCK_DEVICE_NAME"
  fi

  # Format volume if needed

  # TODO: Check volume has been formatted
  # to format:  mkfs -t ext4 "/dev/$BLOCK_DEVICE_NAME"

  # Create mount directory

  if [ ! -e "$VOL_MOUNT_DIR" ]; then
    _echoV "creating mount directory: $VOL_MOUNT_DIR"
    mkdir "$VOL_MOUNT_DIR"
  else
    _echoV "already exists: $VOL_MOUNT_DIR" >&2
  fi

  # Configure /etc/fstab

  local DEV
  DEV="/dev/$BLOCK_DEVICE_NAME"

  if ! grep -qE "^$DEV" /etc/fstab; then
    _echoV "configuring /etc/fstab to mount $DEV to $VOL_MOUNT_DIR"
    echo "$DEV  $VOL_MOUNT_DIR  auto  defaults,nofail  0  2" >> /etc/fstab
  else
    # TODO: the above pattern should also match the tab after the name
    _echoV "already configured: /etc/fstab" >&2
  fi

  # Mount

  if ! mount | grep -qE "^$DEV on"; then
    _echoV "mounting: $VOL_MOUNT_DIR"
    mount --target "$VOL_MOUNT_DIR"
  else
    _echoV "already mounted: $VOL_MOUNT_DIR" >&2
  fi
}

#----------------------------------------------------------------

_link_cvmfs_directories() {
  _echoN "configuring volume storage for CernVM-FS"

  # Check the symbolic links do not already exist

  for SYM in /srv/cvmfs /var/spool/cvmfs ; do
    if [ -L "$SYM" ]; then
      # Ignore existing symbolic link
      :
    elif [ -e "$SYM" ]; then
      _exit "directory already exists: $SYM"
    fi
  done

  # Reset CernVM-FS storage directories, if they exist

  STORAGE_DIR="$VOL_MOUNT_DIR/storage-cvmfs"

  if [ -e "$STORAGE_DIR" ]; then
    for DIR in "$STORAGE_DIR/srv" "$STORAGE_DIR/spool"; do

      if [ -e "$DIR" ]; then
        local INPUT

        if [ -n "$INTERACTIVE" ]; then
          INPUT=yes
        else
          read -p "Delete $DIR? [y/N] ?" INPUT
          INPUT=$(echo "$INPUT" | tr A-Z a-z)
        fi

        if [ "$INPUT" = 'y' ] || [ "$INPUT" = 'yes' ]; then
          _echoV "deleting $DIR"
          rm -rf "$DIR"
        fi
      fi

    done
  fi

  # Create the directories

  for DIR in "$STORAGE_DIR/srv" "$STORAGE_DIR/spool"; do
    if [ -e "$DIR" ]; then
      echo "$EXE: currently script cannot use existing directory: $DIR" >&2
      echo "$EXE: The directory must be deleted." >&2
      _exit "aborted"
      exit 1
    fi

    _echoV "creating directory: $DIR"
    mkdir -p "$DIR"
  done

  # Create symbolic links

  ln -f -s "$STORAGE_DIR/srv" /srv/cvmfs
  _echoV "created symbolic link: /srv/cvmfs -> $STORAGE_DIR/srv"

  ln -f -s "$STORAGE_DIR/spool" /var/spool/cvmfs
  _echoV "created symbolic link: /var/spool/cvmfs -> $STORAGE_DIR/spool"
}

#----------------------------------------------------------------

_link_squid_directory() {
  _echoN "configuring volume storage for Squid"

  # Delete Squid spool directory, if it exists

  STORAGE_DIR="$VOL_MOUNT_DIR/storage-squid"

  if [ -e "$STORAGE_DIR" ]; then

    local -r DIR="$STORAGE_DIR/spool"

      if [ -e "$DIR" ]; then
        local INPUT

        if [ -n "$INTERACTIVE" ]; then
          INPUT=yes
        else
          read -p "Delete $DIR? [y/N] ?" INPUT
          INPUT=$(echo "$INPUT" | tr A-Z a-z)
        fi

        if [ "$INPUT" = 'y' ] || [ "$INPUT" = 'yes' ]; then
          _echoV "deleting $DIR"
          rm -rf "$DIR"
        fi
      fi

  else
    _echoV "creating directory: $STORAGE_DIR"
    mkdir -p "$STORAGE_DIR"
  fi
}

#----------------------------------------------------------------

_mount_volume

case "$HOST_TYPE" in
  cvmfs)
    _link_cvmfs_directories
    ;;

  proxy)
    _link_squid_directory
    ;;

  *)
    _exit "internal error: $HOST_TYPE" >&2
    exit 3
    ;;
esac

# EOF

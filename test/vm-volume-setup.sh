#!/bin/bash
#
# Mounts volume storage and creates the links needed to offload the
# large storage requirements of either CernVM-FS or Squid to it.
#
# Copyright (C) 2021, 2022, QCIF Ltd.
#================================================================

PROGRAM='vm-volume-setup'
VERSION='1.1.0'

EXE=$(basename "$0" .sh)
EXE_EXT=$(basename "$0")

# The expected volume block device and where it will be mounted

BLOCK_DEVICE_NAME=vdb

VOL_MOUNT_DIR=/pvol

# If the volume is unformatted, format it using this filesystem.

FORMAT_FILESYSTEM=ext4

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
# Mount the volume.
#
# If the volume has not been formatted, it will be formatted.

_mount_volume() {
  _echoN "mounting volume storage"

  local DEV
  DEV="/dev/$BLOCK_DEVICE_NAME"

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

  # Check if volume has been formatted

  if ! lsblk --noheadings -o FSTYPE "$DEV" | grep -qE '^\S+$' ; then
    # Not formatted

    if [ -n "$INTERACTIVE" ]; then
      INPUT=yes
    else
      read -p "Format $DEV? [y/N] ?" INPUT
      INPUT=$(echo "$INPUT" | tr A-Z a-z)
    fi

    if [ "$INPUT" = 'y' ] || [ "$INPUT" = 'yes' ]; then
      # Permitted to format
      _echoN "formatting volume: $DEV"
      mkfs -t $FORMAT_FILESYSTEM "$DEV"
    else
      _exit "volume not formatted: $BLOCK_DEVICE_NAME"
    fi
  fi

  # Create mount directory

  if [ ! -e "$VOL_MOUNT_DIR" ]; then
    _echoV "creating mount directory: $VOL_MOUNT_DIR"
    mkdir -p "$VOL_MOUNT_DIR"
  else
    _echoV "already exists: $VOL_MOUNT_DIR" >&2
  fi

  # Configure /etc/fstab to mount the volume

  if ! grep -qE "^$DEV" /etc/fstab; then
    _echoV "configuring /etc/fstab to mount $DEV to $VOL_MOUNT_DIR"
    echo >> /etc/fstab
    echo '# CernVM-FS example testing' >> /etc/fstab
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
# Deletes a directory.
#
# If the directory exists, delete it. If the directory does not
# exist, don't do anything.

_delete_dir() {
  local -r DIR="$1"

  if [ -d "$DIR" ]; then
    # Directory exists: delete it

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

  elif [ -e "$DIR" ]; then
    # Unexpected type of file
    _exit "not a directory: $DIR"
  fi
}

#----------------------------------------------------------------
# Setup /crv/cvmfs and /var/spool/cvmfs to be on the volume storage.
#
# If the directories are not already on it, they are created.  But if
# they are already on it, they are deleted and recreated (since
# CernVM-FS will expect them to be initially empty).

_link_cvmfs_directories() {
  _echoN "configuring volume storage for CernVM-FS"

  local CVMFS_SRV=/srv/cvmfs
  local CVMFS_SPOOL=/var/spool/cvmfs

  # Check the two CernVM-FS directories do not already exist

  for DIR in $CVMFS_SRV $CVMFS_SPOOL ; do
    if [ -e "$DIR" ]; then
      _exit "directory already exists: $DIR"
    fi
  done

  # Setup empty directories on the volume to use

  local STORAGE_SRV="$VOL_MOUNT_DIR/storage-cvmfs/srv"
  local STORAGE_SPOOL="$VOL_MOUNT_DIR/storage-cvmfs/spool"

  for DIR in "$STORAGE_SRV" "$STORAGE_SPOOL"; do
    _delete_dir "$DIR"

    _echoV "creating directory: $DIR"
    mkdir -p "$DIR"
  done

  # Create bind mounts for the CernVM-FS directories to the empty
  # directories on the volume.

  _echoV "created bind mount: $CVMFS_SRV -> $STORAGE_SRV"
  _echoV "created bind mount: $CVMFS_SPOOL -> $STORAGE_SPOOL"

  cat >> /etc/fstab <<EOF
$STORAGE_SRV    $CVMFS_SRV        none    bind    0 0
$STORAGE_SPOOL  $CVMFS_SPOOL  none    bind    0 0
EOF

  mkdir -p  "$CVMFS_SRV"
  mount --target "$CVMFS_SRV"

  mkdir -p  "$CVMFS_SPOOL"
  mount --target "$CVMFS_SPOOL"
}

#----------------------------------------------------------------
# Setup a directory for the Squid disk cache to be on the volume storage.
#
# If the enclosing directory is not already on it, it is created. If
# the spool directtory itself already exists, delete it.
#
# The spool directory is not created/recreated, since Squid will
# create it.

_link_squid_directory() {
  _echoN "configuring volume storage for Squid"

  local -r STORAGE_DIR="$VOL_MOUNT_DIR/storage-squid"
  local -r SPOOL_DIR="$STORAGE_DIR/spool"

  if [ -d "$STORAGE_DIR" ]; then
    # Enclosing storage directory exists

    _delete_dir "$SPOOL_DIR"

    # Note: don't recreate the spool directory: Squid will create it

  elif [ -e "$STORAGE_DIR" ]; then
    # Unexpected type of file
    _exit "not a directory: $STORAGE_DIR"

  else
    # Create enclosing directory
    _echoV "creating directory: $STORAGE_DIR"
    mkdir -p "$STORAGE_DIR"
  fi
}

#----------------------------------------------------------------

# Common to both: mount the volume storage

_mount_volume

# Create directories to offload the bulk of the files to the volume.
# Obviously, this depends on whether the host will be running CernVM-FS
# or Squid.

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

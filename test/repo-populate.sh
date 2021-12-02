#!/bin/bash
#
# Populates a CernVM-FS by copying the files from a source directory into it.
#
# Usage: repo-populate.sh sourceDirectory fullyQualifiedRepositoryName
#
# This script is designed to be run on a Stratum 0 host.
#
# It performs these three actions:
#
# 1. Opens a transaction on a CernVM-FS repository;
# 2. Copies the files into it; and
# 3. Publishes the repository (i.e. closes the transaction).
#================================================================

PROGRAM='repo-populate'
VERSION='1.0.0'

EXE=$(basename "$0" .sh)
EXE_EXT=$(basename "$0")

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

SRC_DIR=
REPO_NAME=
QUIET=
VERBOSE=
SHOW_VERSION=
SHOW_HELP=

while [ $# -gt 0 ]
do
  case "$1" in
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
      if [ -z "$SRC_DIR" ]; then
        SRC_DIR="$1"
      elif [ -z "$REPO_NAME" ]; then
        REPO_NAME="$1"
      else
        echo "$EXE: usage error: too many arguments: $1" >&2
        exit 2
      fi
      shift;
      ;;
  esac
done

if [ -n "$SHOW_HELP" ]; then
  cat <<EOF
Usage: $EXE_EXT [options] srcDir FQRN
Options:
  -q | --quiet    output nothing unless an error occurs
  -v | --verbose  output extra information
       --version  display version information and exit
  -h | --help     display this help and exit

srcDir - directory containing the source files
FQRN - fully qualified repository name
EOF
  # -v | --verbose      output extra information when running
  exit 0
fi

if [ -n "$SHOW_VERSION" ]; then
  echo "$PROGRAM $VERSION"
  exit 0
fi

if [ -z "$SRC_DIR" ]; then
  echo "$EXE: usage error: missing source directory and repositoryName" >&2
  exit 2
elif [ -z "$REPO_NAME" ]; then
  echo "$EXE: usage error: repositoryName" >&2
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
# Timing

# Produces the duration that has passed (e.g. "15s", "3m15s" or "2h5m30s")

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

_populate_repo() {
  local SRC_DIR="$1"
  local REPO="$2"

  if [ ! -d "/cvmfs/$REPO" ]; then
    _exit "repository does not exist: $REPO"
  fi
  if [ ! -d "$SRC_DIR" ]; then
    echo "$EXE: WARNING: source directory does not exist: $SRC_DIR" >&2
    echo "$EXE: repository not populated: $REPO" >&2
    return
  fi

  #----------------
  # Open transaction

  _echoN "transaction for $REPO"

  cvmfs_server transaction "$REPO"

  #----------------
  # Put files into the repository

  rm -f "/cvmfs/$REPO/new_repository"  # remove any default dummy file

  # Copy all files from the source directory

  _echoN "copying: $SRC_DIR..."

  local -r SIZE=$(du -h -s "$SRC_DIR" | sed 's/\t.*//')
  local -r NUM_FILES=$(find "$SRC_DIR" -type f | wc -l)
  local -r NUM_DIRS=$(find "$SRC_DIR" -type d | wc -l)
  _echoV "$SRC_DIR: $SIZE in $NUM_FILES files and $NUM_DIRS directories"

  local -r START_COPY=$(date '+%s') # seconds past epoch

  cp -a "$SRC_DIR"/* "/cvmfs/$REPO"

  _echoN "copying: done ($(_duration_from "$START_COPY"))"

  #----------------
  # Publish changes

  _echoN "publish: $REPO..."

  local START_PUBLISH
  START_PUBLISH=$(date '+%s') # seconds past epoch

  cvmfs_server publish "$REPO"

  _echoN "publish: $REPO: done ($(_duration_from "$START_PUBLISH"))"
}

#----------------------------------------------------------------
# Main

_main() {
    _populate_repo "$SRC_DIR" "$REPO_NAME"
}

_main

#EOF

#!/bin/sh
#
# Monitor a file for changes.
#
# If the file exists, it watches for its last modified time to change
# or for it to be deleted. If the file does not exist, it watches for
# it to appear.
#
# This script can be used to watch a file, to see how long updates
# take to be propagated through to the local file system.
#
# For example,
#
#     monitor.sh /cvmfs/data.example.org/README.txt
#
# Copyright (C) 2021, QCIF Ltd.
#================================================================

PROGRAM='monitor-file'
VERSION='1.0.0'

EXE=$(basename "$0" .sh)
EXE_EXT=$(basename "$0")

#----------------------------------------------------------------
# Command line arguments

if [ $# -lt 1 ]; then
  echo "Usage error: missing file to monitor" >&2
  exit 2
elif [ $# -gt 1 ]; then
  echo "Usage error: too many arguments" >&2
  exit 2
fi

if [ "$1" = '-h' ] || [ "$1" = '--help' ]; then
  echo "Usage: $EXE_EXT filename"
  echo "$PROGRAM $VERSION"
  exit 0
elif echo "$1" | grep '^-' >/dev/null; then
  echo "Usage error: unknown option: $1" >&2
  exit 2
else
  FILE="$1"
fi

#----------------------------------------------------------------
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
  local SEC=$(($END - $1))

  if [ $SEC -lt 60 ]; then
    echo "${SEC}s"
  elif [ $SEC -lt 3600 ]; then
    echo "$(($SEC / 60))m$(($SEC % 60))s"
  else
    echo "$(($SEC / 3600))h$(($SEC % 3600 / 60))m$(($SEC % 60))s"
  fi
}

#----------------------------------------------------------------
# Display

# tput documentation: https://tldp.org/HOWTO/Bash-Prompt-HOWTO/x405.html

display_init() {
  START=$(date '+%s') # seconds past epoch

  /bin/echo -n "$FILE: "
  tput sc # save cursor position
}

display_progress() {
  tput rc # restore cursor position

  /bin/echo -n "waiting for file to be $STATE: "
  # tput smso # enter standout mode
  tput bold
  /bin/echo -n "$(_duration_from $START)"
  # tput rmso # exit standout mode
  tput sgr0 # turn off all attributes (i.e. remove bold)
  /bin/echo -n ' '
}

display_finish() {
  tput rc # restore cursor position
  echo "$STATE $(date "+%FT%T%z") after $(_duration_from $START)"
  tput bel # beep
}

#----------------------------------------------------------------

if [ -e "$FILE" ]; then
  # Monitor an existing file until it is modified or is deleted

  if stat --format=%Y "$FILE" >/dev/null 2>&1; then
    GNU_STAT=yes
    LAST_MOD=$(stat --format %Y "$FILE")
  else
    GNU_STAT=
    LAST_MOD=$(stat -f %m  "$FILE")
  fi

  CURRENT_MOD=$LAST_MOD

  STATE=modified
  display_init

  while [ "$CURRENT_MOD" = "$LAST_MOD" ]; do
    display_progress
    sleep 1
    if [ -e "$FILE" ]; then
      if [ -n "$GNU_STAT" ]; then
        CURRENT_MOD=$(stat --format %Y "$FILE")
      else
        CURRENT_MOD=$(stat -f %m  "$FILE")
      fi
    else
      CURRENT_MOD=none
      STATE=deleted
    fi
  done

else
  # Monitor non-existent file until it is created

  STATE=created
  display_init

  while [ ! -e "$FILE" ]; do
    display_progress
    sleep 1
  done

fi

#----------------------------------------------------------------
# Show time taken

display_finish

exit 0

#EOF

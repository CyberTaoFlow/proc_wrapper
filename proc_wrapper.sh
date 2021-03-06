#!/usr/bin/env bash
#
# Copyright (c) 2015, 2016 Philip Hane
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice,
#    this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright notice,
#    this list of conditions and the following disclaimer in the documentation
#    and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

set -eo pipefail

VERSION='0.1.1'

# Embedded awk program to convert ps output of etime to seconds.
PID_ETIME_AWK=$(cat << 'EOF'
  {
    if (NF == 2) {
      print $1 * 60 + $2;
    } else if (NF == 3) {
      split($1, arr, "-");
      if (arr[2] > 0) {
        print ( ( arr[1]* 24 + arr[2] ) * 60 + $2 ) * 60 + $3;
      } else {
        print ( $1 * 60 + $2 ) * 60 + $3;
      }
    }
  }
EOF
)

################################################################################
# Echo the command line usage information and exit.
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
################################################################################
usage() {
  echo "Usage:"
  echo
  echo "  $0 [-c '<string>'] [-n <string>] [-a] [-t <int>] [-ld <dir>]
    [-td <dir>] [-d] [-v]"
  echo
  echo "Options:"
  echo
  echo "  -c|--command '<string>' : Command (required)
    The command to run. Must be in single quotes.

  -n|--name '<string>' : Unique name (required)
    A unique name string used to identify this command. Needed for process
    tracking, log file names, and duplicate command support. Must be in quotes.

  -a|--active : Toggle active
    When set, this script remains active throughout the duration of the process
    or timeout. Disabled by default. Generally, this option should not be used
    when running via scheduled jobs e.g., cron.

  -t|--timeout <int> : Timeout (seconds)
    The maximum amount of seconds the command is allowed to run. The default
    value is 0, which does not set a time constraint on the command. Generally,
    this value should be greater than the scheduled interval when running via
    jobs e.g., cron.

  -ld|--logdir <dir> : Log directory path
    The path of the directory used to store log files. The default directory is
    /var/log.

  -td|--tempdir <dir> : Temp directory path
    The path of the temp directory used to store pid files. The default
    directory is /tmp.

  -d|--debug : Debug
    When set, verbose logging is enabled. Disabled by default.

  -v|--version : Version
    Prints the script version and exits."

  exit 1
}

################################################################################
# Log messages to file with timestamps.
# Globals:
#   None
# Arguments:
#   message - The message to log
# Returns:
#   None
################################################################################
log() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $@" >> "${log_file}"
}

################################################################################
# Check/create the directories selected, otherwise exit.
# Globals:
#   USER
# Arguments:
#   None
# Returns:
#   None
################################################################################
setup_dirs() {
  if [ -w "${log_dir}" ]; then
    [ -d "${log_dir}" ] || mkdir "${log_dir}"
  else
    echo "${USER} lacks write permissions to: ${log_dir}" 1>&2
    exit 1
  fi
  log_file="${log_dir}/${name}.log"

  if [ -w "${temp_dir}" ]; then
    [ -d "${temp_dir}" ] || mkdir "${temp_dir}"
  else
    echo "${USER} lacks write permissions to: ${temp_dir}" 1>&2
    exit 1
  fi
  pid_file="${temp_dir}/${name}.pid"
}

################################################################################
# Resets the process id and removes the pid file.
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
################################################################################
reset_pid() {
  [ -e "${pid_file}" ] && rm "${pid_file}"
  [ -n "${pid}" ] && pid="0"
}

################################################################################
# Kill the process associated with the input command.
# Globals:
#   None
# Arguments:
#   active - If set, will enable the active timer when killing a process.
# Returns:
#   status - The status code returned from killing the process.
################################################################################
kill_proc() {
  status=0
  if [ -e "${pid_file}" ]; then
    if [ ! -z "$1" ]; then
      if [ ! "${timeout}" -gt "0" ]; then
        wait ${pid}
        status=$?
        reset_pid
        log "[${name}] Process finished with code: ${status}."
        sleep 1
        return ${status}
      fi
      ((to = ${timeout}))
      while ((to > 0)); do
          sleep 1
          kill -0 ${pid} || break
          ((to -= 1))
      done
      kill -0 ${pid} || reset_pid
    fi
    if [ -e "${pid_file}" ] && [ -n "$(ps -o etime= -p ${pid} ||
    echo '')" ]; then
      log "[${name}] Run time has exceeded ${timeout} seconds. Killing ${pid}."
      kill ${pid}
      status=$?
      reset_pid
      log "[${name}] Kill result code: ${status}."
      sleep 1
    fi
  fi
  return ${status}
}

################################################################################
# Check the process associated with the input command, if any. If no process is
# found, do nothing. Kill the process if it is still running and has exceeded
# the set timeout, otherwise, exit.
# Globals:
#   PID_ETIME_AWK
# Arguments:
#   None
# Returns:
#   None
################################################################################
check_pid() {
  [ -e "${pid_file}" ] && pid="$(cat ${pid_file})"
  if [ -n "${pid}" ] && [ "${pid}" -gt "0" ]; then
    e_time="$(ps -o etime= -p ${pid} || echo '')"
    if [ -n "${e_time}" ]; then
      sec="$(echo ${e_time} | awk -F $':' "${PID_ETIME_AWK}")"
      if [ "${sec}" -gt "${timeout}" ]; then
        kill_proc
      elif [ ! "${active}" = "true" ]; then
        log "[${name}] Process (${pid}) is still running."
        exit 1
      fi
    else
      log "[${name}] Process (${pid}) finished at some point. Removing lock."
      reset_pid
    fi
  fi
}

################################################################################
# Run the input command and store the process id assigned. If the active option
# is selected, start the timer and begin checks.
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
################################################################################
run_cmd() {
  log "[${name}] Executing command: ${cmd}"
  [ "${active}" = "true" ] || set +x

  # Creates a subshell for prepending timestamps. Piping to awk works, but
  # depends on strftime, which is only in GNU awk.
  # TODO: Research other methods to eliminate additional background process.
  nohup ${cmd} > >(while IFS= read -r line; do
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: [${name}] [cmd] $line";
    done >> "${log_file}" ) 2>&1 </dev/null &

  [ "${active}" = "true" ] || set -x
  pid=$!
  log "[${name}] Locking process id: ${pid}"
  echo "${pid}" > "${pid_file}"
  chmod 644 "${pid_file}"
  if [ "${active}" = "true" ]; then
    $(kill_proc "true")
    exit $?
  fi
}

################################################################################
# The main function.
# Globals:
#   VERSION
# Arguments:
#   See usage options
# Returns:
#   None
################################################################################
main() {

  local cmd=""
  local name=""
  local active="false"
  local timeout="0"
  local log_dir="/var/log"
  local temp_dir="/tmp"
  local debug="false"
  local log_file=""
  local pid_file=""
  local pid="0"

  # Parse the script arguments
  while [[ $# > 0 ]] ; do
    case "$1" in
      -v|--version)
        echo "proc_wrapper ${VERSION}"
        exit 99
        ;;
      -c|--command)
        cmd=$2
        shift 2
        ;;
      -n|--name)
        name="$2"
        name=${name//[^a-zA-Z0-9]/_}
        [ ${#name} -gt 0 ] || usage
        shift 2
        ;;
      -a|--active)
        active='true'
        shift
        ;;
      -t|--timeout)
        timeout="$2"
        [ "${timeout}" -gt "0" ] || usage
        shift 2
        ;;
      -ld|--logdir)
        log_dir="$2"
        [ ${#log_dir} -gt 0 ] || usage
        shift 2
        ;;
      -td|--tempdir)
        temp_dir="$2"
        [ ${#temp_dir} -gt 0 ] || usage
        shift 2
        ;;
      -d|--debug)
        debug='true'
        set -x
        shift
        ;;
      *)
        usage
        ;;
    esac
  done

  # Required arguments
  ( [ ${#cmd} = 0 ] || [ ${#name} = 0 ] ) && usage

  setup_dirs
  check_pid
  run_cmd

  exit 0
}

main "$@"
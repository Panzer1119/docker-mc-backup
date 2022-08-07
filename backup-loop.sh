#!/bin/bash

set -euo pipefail

if [ "${DEBUG:-false}" == "true" ]; then
  set -x
fi

: "${SRC_DIR:=/data}"
: "${DEST_DIR:=/backups}"
: "${BACKUP_NAME:=world}"
: "${INITIAL_DELAY:=2m}"
: "${BACKUP_INTERVAL:=${INTERVAL_SEC:-24h}}"
: "${PAUSE_IF_NO_PLAYERS:=false}"
: "${PLAYERS_ONLINE_CHECK_INTERVAL:=5m}"
: "${BACKUP_METHOD:=tar}"        # currently one of tar, restic, borg
: "${TAR_COMPRESS_METHOD:=gzip}" # bzip2 gzip zstd
: "${ZSTD_PARAMETERS:=-3 --long=25 --single-thread}"
: "${PRUNE_BACKUPS_DAYS:=7}"
: "${PRUNE_RESTIC_RETENTION:=--keep-within ${PRUNE_BACKUP_DAYS:-7}d}"
: "${SERVER_PORT:=25565}"
: "${RCON_HOST:=localhost}"
: "${RCON_PORT:=25575}"
: "${RCON_PASSWORD_FILE:=}"
: "${RCON_PASSWORD:=minecraft}"
: "${RCON_RETRIES:=5}"
: "${RCON_RETRY_INTERVAL:=10s}"
: "${EXCLUDES:=*.jar,cache,logs}" # Comma separated list of glob(3) patterns
: "${LINK_LATEST:=false}"
: "${RESTIC_ADDITIONAL_TAGS:=mc_backups}" # Space separated list of restic tags
: "${XDG_CONFIG_HOME:=/config}"           # for rclone's base config path
: "${ONE_SHOT:=false}"
: "${TZ:=Etc/UTC}"
: "${RCLONE_COMPRESS_METHOD:=gzip}"
: "${RCLONE_REMOTE:=}"
: "${RCLONE_DEST_DIR:=}"
: "${BORG_REPO:=/borg}"
: "${BORG_COMPRESS_METHOD:=lz4}"
: "${BORG_ARCHIVE_PREFIX:=}"
: "${BORG_ARCHIVE_SUFFIX:=}"
: "${BORG_BASE_DIR:=/tmp/borg}"
: "${BORG_RELOCATED_REPO_ACCESS_IS_OK:=yes}"
: "${BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK:=yes}"
: "${BORG_PRUNE_GFS:=}"
: "${VERBOSE:=false}"
export TZ

export RCON_HOST
export RCON_PORT
export RCON_PASSWORD
export XDG_CONFIG_HOME
export BORG_BASE_DIR
export BORG_RELOCATED_REPO_ACCESS_IS_OK
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK

###############
##  common   ##
## functions ##
###############

is_one_shot() {
  if [[ ${ONE_SHOT^^} = TRUE ]]; then
    return 0
  else
    return 1
  fi
}

is_elem_in_array() {
  # $1 = element
  # All remaining arguments are array to search for the element in
  if [ "$#" -lt 2 ]; then
    log INTERNALERROR "Wrong number of arguments passed to is_elem_in_array function"
    return 2
  fi
  local element="${1}"
  shift
  local e
  for e; do
    if [ "${element}" == "${e}" ]; then
      return 0
    fi
  done
  return 1
}

log() {
  if [ "$#" -lt 1 ]; then
    log INTERNALERROR "Wrong number of arguments passed to log function"
    return 2
  fi
  local level="${1}"
  shift
  local valid_levels=(
    "INFO"
    "WARN"
    "ERROR"
    "INTERNALERROR"
  )
  if ! is_elem_in_array "${level}" "${valid_levels[@]}"; then
    log INTERNALERROR "Log level ${level} is not a valid level."
    return 2
  fi
  (
    # If any arguments are passed besides log level
    if [ "$#" -ge 1 ]; then
      # then use them as log message(s)
      cat <<<"${*}" -
    else
      # otherwise read log messages from standard input
      cat -
    fi
    if [ "${level}" == "INTERNALERROR" ]; then
      echo "Please report this: https://github.com/Panzer1119/docker-mc-backup/issues"
    fi
  ) | awk -v level="${level}" '{ printf("%s %s %s\n", strftime("%FT%T%z"), level, $0); fflush(); }'
} >&2

retry() {
  if [ "$#" -lt 3 ]; then
    log INTERNALERROR "Wrong number of arguments passed to retry function"
    return 1
  fi

  # How many times should we retry?
  # Value smaller than zero means infinitely
  local retries="${1}"
  # Time to sleep between retries
  local interval="${2}"
  readonly retries interval
  shift 2

  if ((retries < 0)); then
    local retries_msg="infinite"
  else
    local retries_msg="${retries}"
  fi

  local i=-1 # -1 since we will increment it before printing
  while ((retries >= ++i)) || [ "${retries_msg}" != "${retries}" ]; do
    # Send SIGINT after 5 minutes. If it doesn't shut down in 30 seconds, kill it.
    if output="$(timeout --signal=SIGINT --kill-after=30s 5m "${@}" 2>&1 | tr '\n' '\t')"; then
      log INFO "Command executed successfully ${*}"
      return 0
    else
      log ERROR "Unable to execute ${*} - try ${i}/${retries_msg}. Retrying in ${interval}"
      if [ -n "${output}" ]; then
        log ERROR "Failure reason: ${output}"
      fi
    fi
    # shellcheck disable=SC2086
    sleep ${interval}
  done
  return 2
}

is_function() {
  if [ "${#}" -ne 1 ]; then
    log INTERNALERROR "is_function expects 1 argument, received ${#}"
  fi
  name="${1}"
  [ "$(type -t "${name}")" == "function" ]
}

call_if_function_exists() {
  if [ "${#}" -lt 1 ]; then
    log INTERNALERROR "call_if_function_exists expects at least 1 argument, received ${#}"
    return 2
  fi
  function_name="${1}"
  if is_function "${function_name}"; then
    "${@}"
  else
    log INTERNALERROR "${function_name} is not a valid function!"
    return 2
  fi
}

#####################
## specific method ##
##    functions    ##
#####################
# Each function that corresponds to a name of a backup method
# Should define following functions inside them
# init() -> called before entering loop. Verify arguments, prepare for operations etc.
# backup() -> create backup. It's guaranteed that all data is already flushed to disk.
# prune() -> prune old backups. PRUNE_BACKUPS_DAYS is guaranteed to be positive.

tar() {
  _find_old_backups() {
    find "${DEST_DIR}" -maxdepth 1 -name "*.${backup_extension}" -mtime "+${PRUNE_BACKUPS_DAYS}" "${@}"
  }

  init() {
    mkdir -p "${DEST_DIR}"
    case "${TAR_COMPRESS_METHOD}" in
    gzip)
      readonly tar_parameters=("--gzip")
      readonly backup_extension="tgz"
      ;;

    bzip2)
      readonly tar_parameters=("--bzip2")
      readonly backup_extension="bz2"
      ;;

    zstd)
      readonly tar_parameters=("--use-compress-program" "zstd ${ZSTD_PARAMETERS}")
      readonly backup_extension="tar.zst"
      ;;

    *)
      log ERROR 'TAR_COMPRESS_METHOD is not valid!'
      exit 1
      ;;
    esac
  }
  backup() {
    ts=$(date +"%Y%m%d-%H%M%S")
    outFile="${DEST_DIR}/${BACKUP_NAME}-${ts}.${backup_extension}"
    tries=3
    while ((tries-- > 0)); do
      log INFO "Backing up content in ${SRC_DIR} to ${outFile}"
      command tar "${excludes[@]}" "${tar_parameters[@]}" -cf "${outFile}" -C "${SRC_DIR}" . || exitCode=$?
      if [ ${exitCode:-0} -eq 0 ]; then
        break
      elif [ ${exitCode:-0} -eq 1 ]; then
        if ((tries > 0)); then
          log INFO "...retrying backup in 5 seconds"
          sleep 5
          continue
        else
          log WARN "Giving up on this round of backup"
        fi
      elif [ ${exitCode:-0} -gt 1 ]; then
        log ERROR "tar exited with code ${exitCode}! Aborting"
        exit 1
      fi
    done
    if [ "${LINK_LATEST^^}" == "TRUE" ]; then
      ln -sf "${BACKUP_NAME}-${ts}.${backup_extension}" "${DEST_DIR}/latest.${backup_extension}"
    fi
  }
  prune() {
    if [ -n "$(_find_old_backups -print -quit)" ]; then
      log INFO "Pruning backup files older than ${PRUNE_BACKUPS_DAYS} days"
      _find_old_backups -print -delete | awk '{ printf "Removing %s\n", $0 }' | log INFO
    fi
  }
  call_if_function_exists "${@}"
}

restic() {
  _delete_old_backups() {
    # shellcheck disable=SC2086
    command restic forget --tag "${restic_tags_filter}" ${PRUNE_RESTIC_RETENTION} "${@}"
  }
  _check() {
    if ! output="$(command restic check 2>&1)"; then
      log ERROR "Repository contains error! Aborting"
      log <<<"${output}" ERROR
      return 1
    fi
  }
  init() {
    if [ -z "${RESTIC_PASSWORD:-}" ] &&
      [ -z "${RESTIC_PASSWORD_FILE:-}" ] &&
      [ -z "${RESTIC_PASSWORD_COMMAND:-}" ]; then
      log ERROR "At least one of" RESTIC_PASSWORD{,_FILE,_COMMAND} "needs to be set!"
      return 1
    fi
    if [ -z "${RESTIC_REPOSITORY:-}" ]; then
      log ERROR "RESTIC_REPOSITORY is not set!"
      return 1
    fi
    if output="$(command restic snapshots 2>&1 >/dev/null)"; then
      log INFO "Repository already initialized"
      _check
    elif grep <<<"${output}" -q '^Is there a repository at the following location?$'; then
      log INFO "Initializing new restic repository..."
      command restic init | log INFO
    elif grep <<<"${output}" -q 'wrong password'; then
      log <<<"${output}" ERROR
      log ERROR "Wrong password provided to an existing repository?"
      return 1
    else
      log <<<"${output}" ERROR
      log INTERNALERROR "Unhandled restic repository state."
      return 2
    fi

    # Used to construct tagging arguments and filters for snapshots
    read -ra restic_tags <<<${RESTIC_ADDITIONAL_TAGS}
    restic_tags+=("${BACKUP_NAME}")
    readonly restic_tags

    # Arguments to use to tag the snapshots with
    restic_tags_arguments=()
    local tag
    for tag in "${restic_tags[@]}"; do
      restic_tags_arguments+=(--tag "$tag")
    done
    readonly restic_tags_arguments
    # Used for filtering backups to only match ours
    restic_tags_filter="$(
      IFS=,
      echo "${restic_tags[*]}"
    )"
    readonly restic_tags_filter
  }
  backup() {
    log INFO "Backing up content in ${SRC_DIR}"
    command restic backup "${restic_tags_arguments[@]}" "${excludes[@]}" "${SRC_DIR}" | log INFO
  }
  prune() {
    # We cannot use `grep -q` here - see https://github.com/restic/restic/issues/1466
    if _delete_old_backups --dry-run | grep '^remove [[:digit:]]* snapshots:$' >/dev/null; then
      log INFO "Pruning snapshots using ${PRUNE_RESTIC_RETENTION}"
      _delete_old_backups --prune | log INFO
      _check | log INFO
    fi
  }
  call_if_function_exists "${@}"
}

rclone() {
  _find_old_backups() {
    command rclone lsf --format "tp" "${RCLONE_REMOTE}:${RCLONE_DEST_DIR}" | grep ${BACKUP_NAME} | awk \
      -v PRUNE_DATE="$(date '+%Y-%m-%d %H:%M:%S' --date="${PRUNE_BACKUPS_DAYS} days ago")" \
      -v DESTINATION="${RCLONE_DEST_DIR%/}" \
      'BEGIN { FS=";" } $1 < PRUNE_DATE { printf "%s/%s\n", DESTINATION, $2 }'
  }
  init() {
    # Check if rclone is installed and configured correctly
    mkdir -p "${DEST_DIR}"
    case "${RCLONE_COMPRESS_METHOD}" in
    gzip)
      readonly tar_parameters=("--gzip")
      readonly backup_extension="tgz"
      ;;

    bzip2)
      readonly tar_parameters=("--bzip2")
      readonly backup_extension="bz2"
      ;;

    zstd)
      readonly tar_parameters=("--use-compress-program" "zstd ${ZSTD_PARAMETERS}")
      readonly backup_extension="tar.zst"
      ;;

    *)
      log ERROR 'RCLONE_COMPRESS_METHOD is not valid!'
      exit 1
      ;;
    esac
  }
  backup() {
    ts=$(date +"%Y%m%d-%H%M%S")
    outFile="${DEST_DIR}/${BACKUP_NAME}-${ts}.${backup_extension}"
    log INFO "Backing up content in ${SRC_DIR} to ${outFile}"
    command tar "${excludes[@]}" "${tar_parameters[@]}" -cf "${outFile}" -C "${SRC_DIR}" . || exitCode=$?
    if [ ${exitCode:-0} -eq 1 ]; then
      log WARN "tar exited with code 1. Ignoring"
    fi
    if [ ${exitCode:-0} -gt 1 ]; then
      log ERROR "tar exited with code ${exitCode}! Aborting"
      exit 1
    fi

    command rclone copy "${outFile}" "${RCLONE_REMOTE}:${RCLONE_DEST_DIR}"
    rm "${outFile}"
  }
  prune() {
    if [ -n "$(_find_old_backups)" ]; then
      log INFO "Pruning backup files older than ${PRUNE_BACKUPS_DAYS} days"
      _find_old_backups | tee \
        >(awk '{ printf "Removing %s\n", $0 }' | log INFO) \
        >(while read -r path; do command rclone deletefile "${RCLONE_REMOTE}:${path}"; done)
    fi
  }
  call_if_function_exists "${@}"
}

borg() {
  _check() {
    if ! output="$(command borg check "${BORG_REPO}" 2>&1)"; then
      log ERROR "Borg repository contains errors! Aborting"
      log <<<"${output}" ERROR
      return 1
    fi
  }
  init() {
    #    if [ -z "${RESTIC_PASSWORD:-}" ] \
    #        && [ -z "${RESTIC_PASSWORD_FILE:-}" ] \
    #        && [ -z "${RESTIC_PASSWORD_COMMAND:-}" ]; then
    #      log ERROR "At least one of" RESTIC_PASSWORD{,_FILE,_COMMAND} "needs to be set!"
    #      return 1
    #    fi
    if [ -z "${BORG_REPO:-}" ]; then
      log ERROR "BORG_REPO is not set!"
      return 1
    fi
    borg_common_options=()
    borg_options_create=()
    borg_options_prune=()
    if [ "${DEBUG:-false}" == "true" ]; then
      borg_common_options+=(--debug)
    fi
    if [ "${VERBOSE:-false}" == "true" ]; then
      borg_common_options+=(--verbose)
      borg_common_options+=(--progress)
      borg_options_create+=(--stats)
      borg_options_prune+=(--stats)
    fi
    readonly borg_common_options
    readonly borg_options_create
    if output="$(command borg info "${BORG_REPO}" 2>&1 >/dev/null)"; then
      log INFO "Borg repository already initialized"
      _check
    else
      log INFO "Initializing new borg repository..."
      command borg "${borg_common_options[@]}" init --encryption none --make-parent-dirs "${BORG_REPO}"
      #TODO Encryption?
    fi
    borg_use_gfs=false
    #Borg GFS Parsing
    #borg_keep_secondly=-1 # Do not use this (then we don't need to decide whether to use s or S)
    borg_keep_yearly=-1
    borg_keep_monthly=-1
    borg_keep_weekly=-1
    borg_keep_daily=-1
    borg_keep_hourly=-1
    borg_keep_minutely=-1
    borg_keep_gfs_log=()
    if [ -n "${BORG_PRUNE_GFS}" ]; then
      mapfile -t borg_prune_gfs_array < <(echo "${BORG_PRUNE_GFS}" | tr "," "\n")
      local unit
      local value
      for i in "${borg_prune_gfs_array[@]}"; do
        unit="${i: -1}"
        value="${i::-1}"
        #log INFO "$unit: $value"
        case "${unit}" in

        y)
          #log INFO "Yearly"
          borg_keep_yearly="${value}"
          ;;

        m)
          #log INFO "Monthly"
          borg_keep_monthly="${value}"
          ;;

        w)
          #log INFO "weekly"
          borg_keep_weekly="${value}"
          ;;

        d)
          #log INFO "daily"
          borg_keep_daily="${value}"
          ;;

        H)
          #log INFO "hourly"
          borg_keep_hourly="${value}"
          ;;

        M)
          #log INFO "minutely"
          borg_keep_minutely="${value}"
          ;;

        *)
          log ERROR "Unknown unit \"${unit}\" in BORG_PRUNE_GFS"
          return 1
          ;;
        esac
      done
      if ((borg_keep_minutely > -1)); then
        borg_options_prune+=(--keep-minutely "${borg_keep_minutely}")
        borg_keep_gfs_log+=("${borg_keep_minutely} minutely")
        borg_use_gfs=true
      fi
      if ((borg_keep_hourly > -1)); then
        borg_options_prune+=(--keep-hourly "${borg_keep_hourly}")
        borg_keep_gfs_log+=("${borg_keep_hourly} hourly")
        borg_use_gfs=true
      fi
      if ((borg_keep_daily > -1)); then
        borg_options_prune+=(--keep-daily "${borg_keep_daily}")
        borg_keep_gfs_log+=("${borg_keep_daily} daily")
        borg_use_gfs=true
      fi
      if ((borg_keep_weekly > -1)); then
        borg_options_prune+=(--keep-weekly "${borg_keep_weekly}")
        borg_keep_gfs_log+=("${borg_keep_weekly} weekly")
        borg_use_gfs=true
      fi
      if ((borg_keep_monthly > -1)); then
        borg_options_prune+=(--keep-monthly "${borg_keep_monthly}")
        borg_keep_gfs_log+=("${borg_keep_monthly} monthly")
        borg_use_gfs=true
      fi
      if ((borg_keep_yearly > -1)); then
        borg_options_prune+=(--keep-yearly "${borg_keep_yearly}")
        borg_keep_gfs_log+=("${borg_keep_yearly} yearly")
        borg_use_gfs=true
      fi
    fi
    if [ "${borg_use_gfs}" == "false" ]; then
      borg_options_prune+=(--keep-within "${PRUNE_BACKUPS_DAYS}d")
    fi
    readonly borg_options_prune
    #log INFO "borg_options_prune: ${borg_options_prune[*]}"

    #    if output="$(command restic snapshots 2>&1 >/dev/null)"; then
    #      log INFO "Repository already initialized"
    #      _check
    #    elif <<<"${output}" grep -q '^Is there a repository at the following location?$'; then
    #      log INFO "Initializing new restic repository..."
    #      command restic init | log INFO
    #    elif <<<"${output}" grep -q 'wrong password'; then
    #      <<<"${output}" log ERROR
    #      log ERROR "Wrong password provided to an existing repository?"
    #      return 1
    #    else
    #      <<<"${output}" log ERROR
    #      log INTERNALERROR "Unhandled restic repository state."
    #      return 2
    #    fi
  }
  backup() {
    local ts
    local cwd
    local archive
    ts=$(date --utc +"%Y%m%d-%H%M%S")
    #ts=$(date --utc --iso-8601=seconds) # Nicer ISO 8601 Format
    cwd=$(pwd)
    archive="${BORG_ARCHIVE_PREFIX:=}${BACKUP_NAME}-${ts}${BORG_ARCHIVE_SUFFIX:=}"
    log INFO "Backing up content in ${SRC_DIR} to ${BORG_REPO}::${archive}"
    cd "${SRC_DIR}"
    command borg "${borg_common_options[@]}" create "${borg_options_create[@]}" --numeric-ids --compression "${BORG_COMPRESS_METHOD:=lz4}" "${excludes[@]}" "${BORG_REPO}"::"${archive}" . | log INFO
    cd "${cwd}"
  }
  prune() {
    if [ "${borg_use_gfs}" == "false" ]; then
      log INFO "Pruning borg archives older than ${PRUNE_BACKUPS_DAYS} days"
    else
      local joined
      for i in "${borg_keep_gfs_log[@]}"; do
        joined+="${i}, "
      done
      log INFO "Pruning borg archives, keeping ${joined::-2} archives"
    fi
    command borg "${borg_common_options[@]}" prune "${borg_options_prune[@]}" --prefix "${BORG_ARCHIVE_PREFIX:=}${BACKUP_NAME}-" "${BORG_REPO}"
    command borg "${borg_common_options[@]}" compact "${BORG_REPO}"
  }
  call_if_function_exists "${@}"
}

##########
## main ##
##########

if [[ $RCON_PASSWORD_FILE ]]; then
  if [ ! -e ${RCON_PASSWORD_FILE} ]; then
    log ERROR "Initial RCON password file ${RCON_PASSWORD_FILE} does not seems to exist."
    log ERROR "Please ensure your configuration."
    log ERROR "If you are using Docker Secrets feature, please check this for further information: "
    log ERROR " https://docs.docker.com/engine/swarm/secrets"
    exit 1
  else
    RCON_PASSWORD=$(cat ${RCON_PASSWORD_FILE})
    export RCON_PASSWORD
  fi
fi

if [ -n "${INTERVAL_SEC:-}" ]; then
  log WARN 'INTERVAL_SEC is deprecated. Use BACKUP_INTERVAL instead'
fi

if [ ! -d "${SRC_DIR}" ]; then
  log ERROR 'SRC_DIR does not point to an existing directory!'
  exit 1
fi

if ! is_function "${BACKUP_METHOD}"; then
  log ERROR "Invalid BACKUP_METHOD provided: ${BACKUP_METHOD}"
fi

# We unfortunately can't use a here-string, as it inserts new line at the end
readarray -td, excludes_patterns < <(printf '%s' "${EXCLUDES}")

excludes=()
for pattern in "${excludes_patterns[@]}"; do
  excludes+=(--exclude "${pattern}")
done

"${BACKUP_METHOD}" init

if ! is_one_shot; then
  log INFO "waiting initial delay of ${INITIAL_DELAY}..."
  # shellcheck disable=SC2086
  sleep ${INITIAL_DELAY}
fi

log INFO "waiting for rcon readiness..."
retry ${RCON_RETRIES} ${RCON_RETRY_INTERVAL} rcon-cli save-on

while true; do

  if retry ${RCON_RETRIES} ${RCON_RETRY_INTERVAL} rcon-cli save-off; then
    # No matter what we were doing, from now on if the script crashes
    # or gets shut down, we want to make sure saving is on
    trap 'retry 5 5s rcon-cli save-on' EXIT

    retry ${RCON_RETRIES} ${RCON_RETRY_INTERVAL} rcon-cli save-all flush
    retry ${RCON_RETRIES} ${RCON_RETRY_INTERVAL} sync

    "${BACKUP_METHOD}" backup

    retry ${RCON_RETRIES} ${RCON_RETRY_INTERVAL} rcon-cli save-on
    # Remove our exit trap now
    trap EXIT
  else
    log ERROR "Unable to turn saving off. Is the server running?"
    exit 1
  fi

  if ((PRUNE_BACKUPS_DAYS > 0)); then
    "${BACKUP_METHOD}" prune
  fi

  if is_one_shot; then
    break
  fi

  # If BACKUP_INTERVAL is not a valid number (i.e. 24h), we want to sleep.
  # Only raw numeric value <= 0 will break
  if ((BACKUP_INTERVAL <= 0)) &>/dev/null; then
    break
  fi

  if [[ ${PAUSE_IF_NO_PLAYERS^^} = TRUE ]]; then
    while true; do
      if ! PLAYERS_ONLINE=$(mc-monitor status --host "${RCON_HOST}" --port "${SERVER_PORT}" --show-player-count 2>&1); then
        log ERROR "Error querying the server, waiting ${PLAYERS_ONLINE_CHECK_INTERVAL}..."
        sleep "${PLAYERS_ONLINE_CHECK_INTERVAL}"
      elif [ "${PLAYERS_ONLINE}" = 0 ]; then
        log INFO "No players online, waiting ${PLAYERS_ONLINE_CHECK_INTERVAL}..."
        sleep "${PLAYERS_ONLINE_CHECK_INTERVAL}"
      else
        break
      fi
    done
  fi

  log INFO "sleeping ${BACKUP_INTERVAL}..."
  # shellcheck disable=SC2086
  sleep ${BACKUP_INTERVAL}
done

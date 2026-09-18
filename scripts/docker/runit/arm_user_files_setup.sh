#!/bin/bash
# This script is first to run due to this: https://github.com/phusion/baseimage-docker#running_startup_scripts.
#
# It updates the UIG or GID of the included arm user to whatever value the user
# passes at runtime, if the value set is not the default value of 1000
#
# If the container is run again without specifying UID and GID, this script
# resets the UID and GID of all files in ARM directories to the defaults

set -euo pipefail

export ARM_HOME="/home/arm"
DEFAULT_UID=1000
DEFAULT_GID=1000


# Run a command as the arm user (script itself runs as root)
as_arm() {
    if command -v runuser >/dev/null 2>&1; then
        runuser -u arm -- "$@"
        return
    fi
    local quoted=""
    local arg
    for arg in "$@"; do
        quoted+=$(printf '%q ' "$arg")
    done
    su -s /bin/sh arm -c "$quoted"
}

# Check that the ARM user can read, write, and traverse a working directory.
# Ownership is not required — group/other bits and ACLs are enough.
check_folder_access() {
    local check_dir="$1"
    local missing=()
    local perms

    echo "Checking access to $check_dir"

    if [[ ! -d "$check_dir" ]]; then
        echo "---------------------------------------------"
        echo "[ERROR]: Directory does not exist: $check_dir"
        echo "---------------------------------------------"
        exit 1
    fi

    if ! as_arm test -r "$check_dir"; then
        missing+=("read")
    fi
    if ! as_arm test -w "$check_dir"; then
        missing+=("write")
    fi
    if ! as_arm test -x "$check_dir"; then
        missing+=("execute")
    fi

    if (( ${#missing[@]} > 0 )); then
        perms=$(stat -c '%A (%a) owner=%U:%G (%u:%g)' "$check_dir")
        echo "---------------------------------------------"
        echo "[ERROR]: ARM user (uid=${ARM_UID} gid=${ARM_GID}) cannot ${missing[*]} $check_dir"
        echo "Read, write, and execute are required; ownership is not. Current: $perms"
        echo "---------------------------------------------"
        exit 1
    fi

    echo "[OK]: ARM has read/write/execute access to '$check_dir'"
}

### Setup User
if [[ $ARM_UID -ne $DEFAULT_UID ]]; then
  echo -e "Updating arm user id from $DEFAULT_UID to $ARM_UID..."
  usermod -u "$ARM_UID" arm
elif [[ $ARM_UID -eq $DEFAULT_UID ]]; then
  echo -e "Updating arm group id $ARM_UID to default (1000)..."
  usermod -u $DEFAULT_UID arm
fi

if [[ $ARM_GID -ne $DEFAULT_GID ]]; then
  echo -e "Updating arm group id from $DEFAULT_GID to $ARM_GID..."
  groupmod -og "$ARM_GID" arm
elif [[ $ARM_GID -eq $DEFAULT_GID ]]; then
  echo -e "Updating arm group id $ARM_GID to default (1000)..."
  groupmod -og $DEFAULT_GID arm
fi
echo "Adding arm user to 'render' group"
usermod -a -G render arm

### Setup Files
chown -R arm:arm /opt/arm

# Check access to the ARM home folder
check_folder_access "/home/arm"

# setup needed/expected dirs if not found
SUBDIRS="media media/completed media/raw media/movies media/transcode logs logs/progress db music .MakeMKV"
for dir in $SUBDIRS ; do
  thisDir="$ARM_HOME/$dir"
  if [[ ! -d "$thisDir" ]] ; then
    echo "Creating dir: $thisDir"
    mkdir -p "$thisDir"
    # Set the default ownership to arm instead of root
    chown -R arm:arm "$thisDir"
  fi
done

echo "Removing any link between music and Music"
if [ -h /home/arm/Music ]; then
  echo "Music symbolic link found, removing link"
  unlink /home/arm/Music
fi

##### Setup ARM-specific config files if not found
# Check access to the ARM config folder
check_folder_access "/etc/arm/config"

mkdir -p /etc/arm/config
CONFS="arm.yaml apprise.yaml"
for conf in $CONFS; do
  thisConf="/etc/arm/config/${conf}"
  if [[ ! -f "${thisConf}" ]] ; then
    echo "Config not found! Creating config file: ${thisConf}"
    # Don't overwrite with defaults during reinstall
    cp --no-clobber "/opt/arm/setup/${conf}" "${thisConf}"
  fi
done

##### abcde config setup
# abcde.conf is expected in /etc by the abcde installation
echo "Checking location of abcde configuration files"
# Test if abcde.conf is a hyperlink, if so remove it
if [ -h /etc/arm/config/abcde.conf ]; then
  echo "Old hyper link exists removing!"
  unlink /etc/arm/config/abcde.conf
fi
# check if abcde is in config main location - only copy if it doesnt exist
if ! [ -f /etc/arm/config/abcde.conf ]; then
  echo "abcde.conf doesnt exist"
  cp /opt/arm/setup/.abcde.conf /etc/arm/config/abcde.conf
  # chown arm:arm /etc/arm/config/abcde.conf
fi
# The system link to the fake default file -not really needed but as a precaution to the -C variable being blank
if ! [ -h /etc/abcde.conf ]; then
  echo "/etc/abcde.conf link doesnt exist"
  ln -sf /etc/arm/config/abcde.conf /etc/abcde.conf
fi

# symlink $ARM_HOME/Music to $ARM_HOME/music because the config for abcde doesn't match the docker compose docs
# separate rm and ln commands because "ln -sf" does the wrong thing if dest is a symlink to a directory
# rm -rf $ARM_HOME/music
# ln -s $ARM_HOME/Music $ARM_HOME/music

# Setup Timezone info
echo "Setting ARM Timezone info: $TZ"
DEBIAN_FRONTEND=noninteractive
ln -sf /usr/share/zoneinfo/$TZ /etc/localtime
dpkg-reconfigure --frontend noninteractive tzdata
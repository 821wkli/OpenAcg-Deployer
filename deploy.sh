#!/bin/sh
set -e
SCRIPT_COMMIT_SHA=UNKNOWN
## text color shown on console
BRed='\033[1;31m'    # Red
BGreen='\033[1;32m'  # Green
BYellow='\033[1;33m' # Yellow
BWhite='\033[1;37m'  # White
Breset=$(tput sgr0)  # default text color

## version code can be found here
## https://docs.docker.com/engine/install/
DEFAULT_VERSION="stable"
if [ -z "$VERSION" ]; then
  VERSION=$DEFAULT_DEFAULT_VERSION
fi

printf() {
  current_date_time="$(date +%m/%d/%Y/%H:%M:%S)"
  command echo ${BGreen}$(basename $0 .sh)-$current_date_time:${Breset} $1
}

# The latest release is currently hard-coded.
STABLE_VERSION="19.03.11"
STABLE_RELEASE_URL=
STABLE_RELEASE_ROOTLESS_URL=
case "$VERSION" in
"stable")
  printf "Installing stable version ${STABLE_VERSION}"
  STATIC_RELEASE_URL="https://download.docker.com/linux/static/$VERSION/$(uname -m)/docker-${STABLE_VERSION}.tgz"
  STATIC_RELEASE_ROOTLESS_URL="https://download.docker.com/linux/static/$VERSION/$(uname -m)/docker-rootless-extras-${STABLE_VERSION}.tgz"
  ;;
"nightly")
  printf "Installing nightly"
  STABLE_RELEASE_URL="https://master.dockerproject.org/linux/$(uname -m)/docker.tgz"
  STABLE_RELEASE_ROOTLESS_URL="https://master.dockerproject.org/linux/$(uname -m)/docker-rootless-extras.tgz"
  ;;
*)
  printf >&2 "Exiting because of unknown VERSION \"$VERSION\". Set \$VERSION to either \"stable\" or \"nightly\"."
  exit 1
  ;;
esac

init() {
  USER_BIN="${DOCKER_BIN:-$HOME/bin}" ## /home/ubuntu/bin

  DAEMON=dockerd
  SYSTEMD=
  if systemctl --user daemon-reload >/dev/null 2>&1; then
    SYSTEMD=1
  fi
}

check_dependices() {
  # HOST OS verification, make sure the scriot can only be run on Linux, blocked windows and mac
  case "$(uname)" in
  Linux) ;;

  *)
    printf >&2 "Deployment script cannot be installed on $(uname)"
    exit 1
    ;;
  esac

  # User verification: deny running as root (unless forced?)
  if [ "$(id -u)" = "0" ] && [ -z "$FORCE_ROOTLESS_INSTALL" ]; then
    printf >&2 "Please run this script in a non-root user"
    exit 1
  fi

  # check if home env has been set
  if [ ! -d "$HOME" ]; then
    printf >&2 "Exiting because HOME directory $HOME does not exist"
    exit 1
  fi

  if [ -d "$USER_BIN" ]; then
    if [ ! -w "$USER_BIN" ]; then
      printf >&2 "Exiting because $USER_BIN is not writable"
      printf >&2 "run -> sudo chown -R \$USER:\$USER $USER_BIN"
      exit 1
    fi
  else
    if [ ! -w "$HOME" ]; then
      printf >&2 "Aborting because HOME (\"$HOME\") is not writable"
      exit 1
    fi
  fi

  ## check if docker engine has been installed with the root user
  # Existing rootful docker verification
  if [ -w /var/run/docker.sock ] && [ -z "$FORCE_ROOTLESS_INSTALL" ]; then
    printf >&2 "Exiting -> Docker engine is running and accessible by root user. Set FORCE_ROOTLESS_INSTALL=1 to ignore."
    exit 1
  fi

  ## https://askubuntu.com/questions/872792/what-is-xdg-runtime-dir
  ## https://unix.stackexchange.com/questions/536164/systemd-user-not-started-xdg-runtime-dir-is-not-set-but-it-is
  ## https://bbs.archlinux.org/viewtopic.php?id=207536
  ## https://stackoverflow.com/questions/34167257/can-i-control-a-user-systemd-using-systemctl-user-after-sudo-su-myuser?rq=1
  ## https://unix.stackexchange.com/questions/462845/how-to-apply-lingering-immedeately
  ##
  # Validate XDG_RUNTIME_DIR
  if [-z "$XDG_RUNTIME_DIR" ] || [ ! -w "$XDG_RUNTIME_DIR" ]; then
    if [ -n "$SYSTEMD" ]; then
      printf >&2 "Exiting -> systemd was detected but XDG_RUNTIME_DIR (\"$XDG_RUNTIME_DIR\") does not exist or is not writable"
      printf >&2 "Hint: this could happen if you switched users with 'su' or 'sudo'. To work around this:"
      printf >&2 "- try again by first running with root privileges 'loginctl enable-linger <user>' where <user> is the unprivileged user and export XDG_RUNTIME_DIR to the value of RuntimePath as shown by 'loginctl show-user <user>'"
      printf >&2 "- or simply log back in as the desired unprivileged user"
      exit 1
    fi
    export XDG_RUNTIME_DIR="/tmp/docker-$(id -u)"
    mkdir -p "$XDG_RUNTIME_DIR"
    XDG_RUNTIME_DIR_CREATED=1
  fi

  TIPS=
  # uidmap dependency check
  if ! which newuidmap >/dev/null 2>&1; then
    if which apt-get >/dev/null 2>&1; then
      TIPS="${TIPS}\n apt-get install -y uidmap"
    elif which dnf >/dev/null 2>&1; then
      TIPS="${TIPS}\n dnf install -y shadow-utils"
    elif which yum >/dev/null 2>&1; then
      TIPS="${TIPS}\n curl -o /etc/yum.repos.d/vbatts-shadow-utils-newxidmap-epel-7.repo https://copr.fedorainfracloud.org/coprs/vbatts/shadow-utils-newxidmap/repo/epel-7/vbatts-shadow-utils-newxidmap-epel-7.repo
yum install -y shadow-utils46-newxidmap"
    else
      printf "newuidmap binary not found. Please install with a package manager."
      exit 1
    fi
  fi

  # curl check
  if ! which curl >/dev/null 2>&1; then
    if which apt-get >/dev/null 2>&1; then
      TIPS="${TIPS}\n apt-get install -y curl"
    elif which dnf >/dev/null 2>&1; then
      TIPS="${TIPS}\n dnf install -y curl"
    elif which yum >/dev/null 2>&1; then
      TIPS="${TIPS}\n yum install -y curl"
    else
      printf "curl package not found. Please install with a package manager."
      exit 1
    fi
  fi

  # iptables dependency check
  if [ -z "$SKIP_IPTABLES" ] && ! which iptables >/dev/null 2>&1 && [ ! -f /sbin/iptables ] && [ ! -f /usr/sbin/iptables ]; then
    if which apt-get >/dev/null 2>&1; then
      TIPS="${TIPS}
apt-get install -y iptables"
    elif which dnf >/dev/null 2>&1; then
      TIPS="${TIPS}
dnf install -y iptables"
    else
      printf "iptables binary not found. Please install with a package manager."
      exit 1
    fi
  fi

  # ip_tables module dependency check
  if [ -z "$SKIP_IPTABLES" ] && ! lsmod | grep ip_tables >/dev/null 2>&1 && ! cat /lib/modules/$(uname -r)/modules.builtin | grep ip_tables >/dev/null 2>&1; then
    TIPS="${TIPS}
modprobe ip_tables"
  fi

  # debian requires setting unprivileged_userns_clone
  # https://superuser.com/questions/1094597/enable-user-namespaces-in-debian-kernel
  # https://security.stackexchange.com/questions/209529/what-does-enabling-kernel-unprivileged-userns-clone-do
  if [ -f /proc/sys/kernel/unprivileged_userns_clone ]; then
    if [ "1" != "$(cat /proc/sys/kernel/unprivileged_userns_clone)" ]; then
      TIPS="${TIPS}
cat <<EOT > /etc/sysctl.d/50-rootless.conf
kernel.unprivileged_userns_clone = 1
EOT
sysctl --system"
    fi
  fi

  # centos requires setting max_user_namespaces
  # https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/8/html/building_running_and_managing_containers/starting-with-containers_building-running-and-managing-containers

  if [ -f /proc/sys/user/max_user_namespaces ]; then
    if [ "0" = "$(cat /proc/sys/user/max_user_namespaces)" ]; then
      INSTRUCTIONS="${INSTRUCTIONS}
cat <<EOT > /etc/sysctl.d/51-rootless.conf
user.max_user_namespaces = 28633
EOT
sysctl --system"
    fi
  fi

  if [ -n "$TIPS" ]; then
    printf "# Missing required dependencies. Please run following commands to
# install the dependencies and run this deployment script again.
# or can be disabled with SKIP_IPTABLES=1"

    echo
    printf "\n cat <<EOF | sudo sh -x $TIPS \n EOF"
    echo
    exit 1
  fi


}

main() {
  ## logic workflow
  ## check dependices -> install docker -> install docker compose -> clone repository->build image -> start containers
}

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

## https://docs.docker.com/config/daemon/systemd/
start_docker() {
  # check if overlay is supported
  ## https://unix.stackexchange.com/questions/75891/querying-an-overlayfs
  tmpdir=$(mktemp -d)
  mkdir -p $tmpdir/lower $tmpdir/upper $tmpdir/work $tmpdir/merged
  if "$USER_BIN"/rootlesskit mount -t overlay overlay -olowerdir=$tmpdir/lower,upperdir=$tmpdir/upper,workdir=$tmpdir/work $tmpdir/merged >/dev/null 2>&1; then
    USE_OVERLAY=1
  fi
  rm -rf "$tmpdir"

  if [ -z "$SYSTEMD" ]; then
    start_docker_nonsystemd
    return
  fi

  mkdir -p $HOME/.config/systemd/user

  DOCKERD_FLAGS="--experimental"

  if [ -n "$SKIP_IPTABLES" ]; then
    DOCKERD_FLAGS="$DOCKERD_FLAGS --iptables=false"
  fi

  if [ "$USE_OVERLAY" = "1" ]; then
    DOCKERD_FLAGS="$DOCKERD_FLAGS --storage-driver=overlay2"
  else
    DOCKERD_FLAGS="$DOCKERD_FLAGS --storage-driver=vfs"
  fi

  CFG_DIR="$HOME/.config"
  if [ -n "$XDG_CONFIG_HOME" ]; then
    CFG_DIR="$XDG_CONFIG_HOME"
  fi

  if [ ! -f $CFG_DIR/systemd/user/docker.service ]; then
    cat <<EOT >$CFG_DIR/systemd/user/docker.service
[Unit]
Description=Docker Engine
[Service]
Environment=PATH=$USER_BIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=$USER_BIN/dockerd-rootless.sh $DOCKERD_FLAGS
ExecReload=/bin/kill -s HUP \$MAINPID
TimeoutSec=0
RestartSec=2
Restart=always
StartLimitBurst=3
StartLimitInterval=60s
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
Delegate=yes
Type=simple
[Install]
WantedBy=default.target
EOT
    systemctl --user daemon-reload
  fi
  if ! systemctl --user status docker >/dev/null 2>&1; then
    printf "# starting systemd service"
    systemctl --user start docker
  fi
  systemctl --user status docker | cat

  sleep 1
  PATH="$USER_BIN:$PATH" DOCKER_HOST="unix://$XDG_RUNTIME_DIR/docker.sock" docker version
}

print_service_instructions() {
  if [ -z "$SYSTEMD" ]; then
    return
  fi
  cat <<EOT
#
# To control docker service run:
# systemctl --user (start|stop|restart) docker
#
EOT
}

start_docker_nonsystemd() {
  iptablesflag=
  if [ -n "$SKIP_IPTABLES" ]; then
    iptablesflag="--iptables=false "
  fi
  cat <<EOT
# systemd not detected, dockerd daemon needs to be started manually
$USER_BIN/dockerd-rootless.sh --experimental $iptablesflag--storage-driver vfs
EOT
}

print_instructions() {
  start_docker
  printf "# Docker binaries are installed in $USER_BIN"
  if [ "$(which $DAEMON)" != "$USER_BIN/$DAEMON" ]; then
    printf "# WARN: dockerd is not in your current PATH or pointing to $USER_BIN/$DAEMON"
  fi
  printf "# Missing the following environment variables"

  if [ -n "$XDG_RUNTIME_DIR_CREATED" ]; then
    printf "set XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR ok"
    echo "export XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR" >>~/.bashrc
  fi

  case :$PATH: in
  *:$USER_BIN:*) ;;
  *)
    printf "set PATH=$USER_BIN:$PATH ok"
    echo "export PATH=$USER_BIN:$PATH" >>~/.bashrc

    ;;
  esac

  # iptables is required but /sbin might not be in PATH
  if [ -z "$SKIP_IPTABLES" ] && ! which iptables >/dev/null 2>&1; then
    if [ -f /sbin/iptables ]; then
      printf "set PATH=$PATH:/sbin ok"
      echo "export PATH=$PATH:/sbin" >>~/.bashrc

    elif [ -f /usr/sbin/iptables ]; then
      printf "set PATH=$PATH:/usr/sbin ok "
      echo "export PATH=$PATH:/usr/sbin" >>~/.bashrc

    fi
  fi

  echo "export DOCKER_HOST=unix://$XDG_RUNTIME_DIR/docker.sock" >>~/.bashrc
  printf "set DOCKER_HOST=unix://$XDG_RUNTIME_DIR/docker.sock ok"
  echo
  print_service_instructions
}

install_docker() {
  init
  check_dependices

  tmp=$(mktemp -d)
  trap "rm -rf $tmp" EXIT INT TERM
  # Download docker distribution*
  (
    cd "$tmp"
    curl -L -o docker.tgz "$STABLE_RELEASE_URL"
    curl -L -o rootless.tgz "$STABLE_RELEASE_ROOTLESS_URL"
  )
  # Extract zipped archieve to /home/ubuntu/bin
  (
    mkdir -p "$USER_BIN"
    cd "$USERBIN"
    tar zxf "$tmp/docker.tgz" --strip-components=1
    tar zxf "$tmp/rootless.tgz" --strip-components=1
  )

  print_instructions

}

install_docker_compose() {
  desc="$HOME/bin/docker-compose"
  curl -L "https://github.com/docker/compose/releases/download/1.26.0/docker-compose-$(uname -s)-$(uname -m)" -o "$desc"
  if [ ! -f $desc ]; then
    printf "Download docker-compose failed, error code 365"
    exit 1
  fi
  chmod +x $desc

}

main() {
  ## logic workflow
  ## check dependices -> install docker -> install docker compose -> clone repository->build image -> start containers

  # check if need to install docker
  if [ -x "$(command -v docker)" ]; then
    printf "docker installed"

  else

    printf "Installing docker..."
    install_docker
    # command
  fi

  # command
  if [ -x "$(command -v docker-compose)" ]; then
    printf "docker-compose installed"
  else
    printf "Install docker-compose..."
    install_docker_compose
    printf "Install docker-compose done"
  fi

  # check if need to install git

  if [ -x "$(command -v git)" ]; then
    printf "git installed"

  else
    printf "missing git,please install it before running this script"
    exit 1

  fi

}

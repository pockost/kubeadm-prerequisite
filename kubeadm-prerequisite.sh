#!/bin/bash
#
# @file kubeadm-prerequisite
# @brief A bash script configuring system to handle proxy when using kubeadm

# Indicates if upgrade the system or not. Defaults to *false*.
UPGRADE=false

DEFAULT_NO_PROXY=localhost,127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16

# Global vars
# array of network interface
INTERFACES=()
declare -A INTERFACES_DETAILS
OUTPUT_INTERFACE=()

# @description Get bash parameters.
#
# Accepts:
#
#  - *h* (help).
#
# @arg '$@' string Bash arguments.
#
# @exitcode 0 if successful.
# @exitcode 1 on failure.
function get_parameters() {
    # Obtain parameters.
    while getopts 'h;' opt; do
        OPTARG=$(sanitize "$OPTARG")
        case "$opt" in
            h) help && exit 0;;
        esac
    done
    return 0
}

# @description Shows help message.
#
# @noargs
#
# @exitcode 0 if successful.
# @exitcode 1 on failure.
function help() {
    echo 'A bash script configuring system to handle proxy when using kubeadm'
    echo 'Parameters:'
    echo '-h (help): Show this help message.'
    echo 'Example:'
    echo "./kubeadm-prerequisite.sh -h"
    return 0
}

# @description Retreive list of all non loopback, bridged or docker related interfance.
#
# Result will be stored in INTERFACES global var.
#
# @noargs
#
# @exitcode 0 if successful.
# @exitcode 1 on failure.
function retreive_interface_list() {
  echo "Guessing network interfaces..."
  for int in $( ip link show | awk '{ print $2 }'|grep :$|cut -d: -f1|grep -v -E '^(lo|br-|virbr|docker|veth)' )
  do
    INTERFACES+=($int)
  done
  echo "FOUND ${#INTERFACES[@]} network interfaces (${INTERFACES[@]:0:3} ...)"

  return 0
}

# @description Retreive detail about given interface.
#
# Result will be stored in INTERFACES_DETAILS associative array.
#
# @arg $@ string interface name
#
# @exitcode 0 if successful.
# @exitcode 1 on failure.
function retreive_interface_detail() {
  nif=$1

  echo "Retreiving detail about network interfaces $nif"
  INTERFACES_DETAILS[$nif,state]=$( ip addr show $nif |head -n1|awk '{ print $9 }' )
  if [ "${INTERFACES_DETAILS[$nif,state]}" == "DOWN" ]
  then
    echo "Interface $nif is DOWN. Continue..."
    return 0
  fi

  # TODO from now there is only one IP managed
  INTERFACES_DETAILS[$nif,ip]=$( ip addr show $nif|grep "inet "|awk '{print $2}'|cut -d/ -f1|head -n1)

  test_connectivity $nif

  return 0
}



# @description A bash script to retreive curent network configuration
#
# @noargs
#
# @exitcode 0 if successful.
# @exitcode 1 on failure.
function retreive_network_config() {
  retreive_interface_list
  for int in ${INTERFACES[@]}
  do
    retreive_interface_detail $int
  done
}


# @description Test connectivity for given interface
#
# @args $@ string the interface name
#
# @exitcode 0 if successful.
# @exitcode 1 on failure.
function test_connectivity() {
  nif=$1

  # If interface is down return function
  ping -W 1 -c1 -I ${nif} ${INTERFACES_DETAILS[$nif,ip]}  &>/dev/null
  if [ $? -ne 0 ]
  then
    echo "CRITICAL network configuration for ${nif}"
  fi
  ping -W 2 -c1 -I ${nif} 8.8.8.8 &>/dev/null
  if [ $? -ne 0 ]
  then
    echo "INFO unable to ping 8.8.8.8 with ${nif}"
    echo "Trying direct HTTP access"
    wget --timeout=3 -q -O /dev/null google.fr
    if [ $? -ne 0 ]
    then
      echo "No internet connection for ${nif}"
      INTERFACES_DETAILS[$nif,internet]=1
      return 1
    fi
  fi
  echo "Internet is reachable with ${nif}"
  OUTPUT_INTERFACE+=($nif)
  INTERFACES_DETAILS[$nif,internet]=0
  return 0
}

# @description Ask user for proxy information, test and save config
#
# @noargs
#
# @exitcode 0 if successful.
# @exitcode 1 on failure.
function configure_proxy() {
  echo "Going to configure proxy"
  echo
  read -p "Give me your proxy URL: " proxy_url
  echo 

  echo "Testing proxy"
  http_proxy=$proxy_url wget -q -O /dev/null google.fr

  if [ $? -ne 0 ]
  then
    echo "Proxy is not working. Retry..."
    configure_proxy
    return $?
  fi

  echo "Proxy is working"
  echo "Injecting global env var in profile"
  echo "export http_proxy=$proxy_url" >> /etc/profile
  echo "export https_proxy=$proxy_url" >> /etc/profile
  echo "export ftp_proxy=$proxy_url" >> /etc/profile
  echo "export no_proxy=$DEFAULT_NO_PROXY" >> /etc/profile
  echo 'export HTTP_PROXY=$http_proxy' >> /etc/profile
  echo 'export HTTPS_PROXY=$https_proxy' >> /etc/profile
  echo 'export FTP_PROXY=$ftp_proxy' >> /etc/profile
  echo 'export NO_PROXY=$no_proxy' >> /etc/profile
  source /etc/profile

  echo
  echo "Configuration done"
  echo "Testing proxy"
  http_proxy=$proxy_url wget -q -O /dev/null google.fr

  if [ $? -ne 0 ]
  then
    echo "bash profile configuration failed"
    return 1
  else
    echo "We now have access to the internet"
  fi


}

function install_deps() {
  apt-get update
  apt-get install -y apt-transport-https curl grepcidr gnupg
  # Install kubectl
  curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
  echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" | tee -a /etc/apt/sources.list.d/kubernetes.list
  apt-get update
  apt-get install -y kubectl
  echo "Enabling iptables support"
  echo "net.bridge.bridge-nf-call-ip6tables = 1
  net.bridge.bridge-nf-call-iptables = 1" > /etc/sysctl.d/k8s.conf
  /usr/sbin/sysctl --system
}

function install_docker() {
  which docker &>/dev/null
  if [ $? -eq 0 ]
  then
    read -p "Docker is already installed du you want to re-run install script? (Yn): " reinstall_docker
    reinstall_docker=${reinstall_docker:-y}
    case $reinstall_docker in
      [yYoO]*)
        echo "Ok let's go"
        ;;
      [nN]*)
        return 0
        ;;
      *)
        echo "Please answer y or n for yes or no"
        bad_input=0
        ;;
      esac
  fi
  curl -fsSL https://get.docker.com -o get-docker.sh
  sh get-docker.sh
  /usr/sbin/usermod -aG docker $USER
}

function configure_docker() {
  echo "Configuring docker"

  if [ ! -z "$http_proxy" ]
  then
    echo "Found a proxy. Configuring docker to used this one"
    mkdir -p /etc/systemd/system/docker.service.d/
    echo "[Service]
Environment='HTTP_PROXY=$http_proxy'
Environment='HTTPS_PROXY=$https_proxy'
Environment='NO_PROXY=$DEFAULT_NO_PROXY'" > /etc/systemd/system/docker.service.d/http-proxy.conf
    echo '{"exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
  "max-size": "100m"
},
"storage-driver": "overlay2"}' > /etc/docker/daemon.json
    systemctl daemon-reload
    # TODO prevent to restart if no change
    systemctl restart docker
  fi

}

function disable_swap() {
  echo "disable swap"
  sed -i 's/^\([^\s]*\sswap\)/# \1/' /etc/fstab
  swapoff -a
}

function install_kubeadm() {
  echo "Installing kubeadm"
  apt-get install -y kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl
}


function configure_completion() {
  echo "Configuring user bashrc in order to enable completion"

  shell_name=$( echo $SHELL | awk -F'/' '{ print $NF }' )
  echo "source <(kubectl completion $shell_name )" >> /home/$USER/.${shell_name}rc
  echo "source <(kubeadm completion $shell_name )" >> /home/$USER/.${shell_name}rc
}

function rename_host() {
  echo "Going to rename the host"
  echo
  read -p "Give me the name you want for this host: " newhostname
  echo 

  if [[ "$newhostname" =~ ^(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9])\.)*([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\-]*[A-Za-z0-9])$ ]]
  then
    echo $newhostname > /etc/hostname
    sed -i "s/^127.0.1.1\s.*$/127.0.1.1 $newhostname/" /etc/hosts
  else
    echo "Hostname is invalid. Please retry"
    rename_host
  fi


}

function congratulation_message() {
  echo "Wonderfull!"
  echo
  echo "For now all the prerequisite for kubeadm usage are now installed and/or configured. For more information about what append in this script you can read the script in the following github account: https://github.com/pockost/kubeadm-prerequisite"
  echo 
  echo "You can now install a kubernetes master node or join a already running kubernetes install."
  echo 
  echo "If you plan to create a new kubernetes cluster (install master) run the following command (replace the <ip-address> part by one of yours ip ($(ip a s |grep enp|grep inet |awk '{ print $2 }'|cut -d '/' -f1|tr '\n' ' '))"
  echo
  echo "  # kubeadm init --pod-network-cidr=192.168.0.0/16 --apiserver-advertise-address=<ip-address>"
  echo
  echo "If you plan to join an existing cluster use the following command (replace placeholder data with correct ones)"
  echo
  echo '  # kubeadm join --token <token> <master-ip>:<master-port> --discovery-token-ca-cert-hash sha256:<hash>'
  echo
  echo "Have a lot of fun"
}

function reboot_host() {
  echo "Now rebooting !"
  /usr/sbin/reboot
}

function dummy_dhcp() {
  read -p "Do you want to force DHCP for all interface on startup (Don't use in production, it's ugly) ? (yN): " force_dhcp
    force_dhcp=${force_dhcp:-n}
    case $force_dhcp in
      [yYoO]*)
        echo "Adding dhclient to startup command"
        for i in $( ip a s |grep ': enp' |awk '{ print $2 }' | cut -d: -f1 )
        do
          echo "allow-hotplug $i" >> /etc/network/interfaces
          echo "iface $i inet dhcp" >> /etc/network/interfaces
        done
        ;;
      [nN]*)
        return 0
        ;;
      *)
        echo "Please answer y or n for yes or no"
        bad_input=0
        ;;
      esac
}

# @description A bash script configuring system to handle proxy when using kubeadm
#
# @arg $@ string Bash arguments.
#
# @exitcode 0 if successful.
# @exitcode 1 on failure.
function main() {

    get_parameters "$@"


    retreive_network_config

    if [ ${#OUTPUT_INTERFACE[@]} -eq 0 ]
    then
      echo "Unable to detect a working interface"
      echo
      end=1
      while [[ $end -ne 0 ]]; do
        read -p "Do you want to configure a proxy? (Yn): " configure_proxy
        configure_proxy=${configure_proxy:-y}
        case $configure_proxy in
          [yYoO]*)
            configure_proxy
            end=$?
            ;;
          [nN]*)
            end=0
            echo "Sorry I can do nothing..."
            echo "Bye"
            return 2
            ;;
          *)
            echo "Please answer y or n for yes or no"
            bad_input=0
            ;;
        esac
      done
    fi

    install_deps

    install_docker
    configure_docker

    disable_swap

    install_kubeadm
    configure_completion

    rename_host

    dummy_dhcp

    congratulation_message
    reboot_host

    return 0
}

# @description Sanitize input.
#
# The applied operations are:
#
# - Trim.
#
# @arg $1 string Text to sanitize.
#
# @exitcode 0 if successful.
# @exitcode 1 on failure.
#
# @stdout Sanitized input.
function sanitize() {
    [[ -z $1 ]] && echo '' && return 0
    local sanitized="$1"
    # Trim.
    sanitized="${sanitized## }"
    sanitized="${sanitized%% }"
    echo "$sanitized"
    return 0
}

function run_as_root() {
  if [ "$( id -u )" != "0" ]; then
    #echo "This script need to be root"
    #which sudo &>/dev/null
    #if [ $? -eq 0 ]
    #then
    #  sudo $0
    #else
    su -c "$0" root
    #fi

    echo "Please logout and reconnect to update $USER proxy env var"
    exit
  fi
}

# Avoid running the main function if we are sourcing this file.
return 0 2>/dev/null
run_as_root
main "$@"

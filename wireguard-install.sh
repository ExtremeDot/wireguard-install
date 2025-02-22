#!/bin/bash

# Secure WireGuard server installer
# https://github.com/angristan/wireguard-install

RED='\033[0;31m'
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'
EDVERSION=1.99
INSTART=0

clear

function isRoot() {
	if [ "${EUID}" -ne 0 ]; then
		echo "You need to run this script as root"
		exit 1
	fi
}


function back2Menu() {
echo 
if [ "$INSTART" -eq 0 ]; then
read -n 1 -s -r -p "Press any key to continue..."
clear
manageMenu
fi

}

function checkVirt() {
	if [ "$(systemd-detect-virt)" == "openvz" ]; then
		echo "OpenVZ is not supported"
		exit 1
	fi

	if [ "$(systemd-detect-virt)" == "lxc" ]; then
		echo "LXC is not supported (yet)."
		echo "WireGuard can technically run in an LXC container,"
		echo "but the kernel module has to be installed on the host,"
		echo "the container has to be run with some specific parameters"
		echo "and only the tools need to be installed in the container."
		exit 1
	fi
}

function checkOS() {
	source /etc/os-release
	OS="${ID}"
	if [[ ${OS} == "debian" || ${OS} == "raspbian" ]]; then
		if [[ ${VERSION_ID} -lt 10 ]]; then
			echo "Your version of Debian (${VERSION_ID}) is not supported. Please use Debian 10 Buster or later"
			exit 1
		fi
		OS=debian # overwrite if raspbian
	elif [[ ${OS} == "ubuntu" ]]; then
		RELEASE_YEAR=$(echo "${VERSION_ID}" | cut -d'.' -f1)
		if [[ ${RELEASE_YEAR} -lt 18 ]]; then
			echo "Your version of Ubuntu (${VERSION_ID}) is not supported. Please use Ubuntu 18.04 or later"
			exit 1
		fi
	elif [[ ${OS} == "fedora" ]]; then
		if [[ ${VERSION_ID} -lt 32 ]]; then
			echo "Your version of Fedora (${VERSION_ID}) is not supported. Please use Fedora 32 or later"
			exit 1
		fi
	elif [[ ${OS} == 'centos' ]] || [[ ${OS} == 'almalinux' ]] || [[ ${OS} == 'rocky' ]]; then
		if [[ ${VERSION_ID} == 7* ]]; then
			echo "Your version of CentOS (${VERSION_ID}) is not supported. Please use CentOS 8 or later"
			exit 1
		fi
	elif [[ -e /etc/oracle-release ]]; then
		source /etc/os-release
		OS=oracle
	elif [[ -e /etc/arch-release ]]; then
		OS=arch
	else
		echo "Looks like you aren't running this installer on a Debian, Ubuntu, Fedora, CentOS, AlmaLinux, Oracle or Arch Linux system"
		exit 1
	fi
}

function create_wg_exp_ctrl_script() {

	mkdir -p /usr/local/extDot/
	sleep 1
	touch /usr/local/extDot/wgExpCtrl.sh
	chmod 755 /usr/local/extDot/wgExpCtrl.sh
	sleep 1
	cat <<EOF > /usr/local/extDot/wgExpCtrl.sh
#!/bin/bash

check_client_expiration() {
    local client_name=\$1
    local wg_config_file="\$2"
    local user_info_file="/usr/local/extDot/userInfo.conf"

    if ! grep -qE "^### Client \$client_name$" "\$wg_config_file"; then
        echo "Client \$client_name is not defined in \$wg_config_file"
        return 1
    fi

    local client_section=\$(grep -E "^### Client \$client_name$" "\$wg_config_file")
    local allowed_ips_line=\$(grep -A 5 -E "^\$client_section\$" "\$wg_config_file" | awk '/AllowedIPs/')

    local current_date=\$(date +%Y-%m-%d)
    local expiration_date=\$(grep "\$client_name" "\$user_info_file" | awk -F'=' '{print \$2}')

    if [[ "\$current_date" > "\$expiration_date" ]]; then
        if ! grep -qE "^# \$allowed_ips_line" "\$wg_config_file"; then
            sed -i "/^\$client_section\$/,/AllowedIPs/s/^AllowedIPs/# AllowedIPs/" "\$wg_config_file"
        fi
    else
        sed -i "/^\$client_section\$/,/AllowedIPs/s/^# AllowedIPs/AllowedIPs/" "\$wg_config_file"
    fi
}

# Find all WireGuard configuration files in /etc/wireguard folder
config_files=\$(find /etc/wireguard -type f -name "*.conf")

while IFS='=' read -r client_name expiration_date || [[ -n "\$client_name" ]]; do
    for config_file in \$config_files; do
        check_client_expiration "\$client_name" "\$config_file"
    done
done < "/usr/local/extDot/userInfo.conf"


generate_hash() {
    file="\$1"
    hash_code=\$(sha256sum "\$file" | awk '{ print \$1 }')
}

store_hash() {
    interface="\$1"
    hash_code="\$2"
    echo "\$interface:\$hash_code" >> /usr/local/extDot/confHash.log
}

check_and_sync() {
    interface="\$1"
    config_file="\$2"
    previous_hash="\$3"

    current_hash=\$(generate_hash "\$config_file")

    if [[ "\$current_hash" != "\$previous_hash" ]]; then
        wg syncconf "\$interface" <(wg-quick strip "\$interface")
        store_hash "\$interface" "\$current_hash"

    fi
}

config_files=\$(find /etc/wireguard -type f -name "*.conf")

for config_file in \$config_files; do
    interface_name=\$(basename "\$config_file" .conf)
    previous_hash=\$(grep -e "^\$interface_name:" /usr/local/extDot/confHash.log | awk -F':' '{ print \$2 }')
    
    if [[ -z "\$previous_hash" ]]; then
        hash_code=\$(generate_hash "\$config_file")
        store_hash "\$interface_name" "\$hash_code"
    else
        check_and_sync "\$interface_name" "\$config_file" "\$previous_hash"
    fi
done

EOF

chmod +x /usr/local/extDot/wgExpCtrl.sh

}

function getHomeDirForClient() {
	local CLIENT_NAME=$1

	if [ -z "${CLIENT_NAME}" ]; then
		echo "Error: getHomeDirForClient() requires a client name as argument"
		exit 1
	fi

	# Home directory of the user, where the client configuration will be written
	if [ -e "/home/${CLIENT_NAME}" ]; then
		# if $1 is a user name
		HOME_DIR="/home/wireguard/${CLIENT_NAME}"
	elif [ "${SUDO_USER}" ]; then
		# if not, use SUDO_USER
		if [ "${SUDO_USER}" == "root" ]; then
			# If running sudo as root
			HOME_DIR="/root/wireguard"
		else
			HOME_DIR="/home/wireguard/${SUDO_USER}"
		fi
	else
		# if not SUDO_USER, use /root
		HOME_DIR="/root/wireguard"
	fi

	echo "$HOME_DIR"
}

function initialCheck() {
	isRoot
	checkVirt
	checkOS
}

function installQuestions() {
	echo "Welcome to the WireGuard installer!"
	echo "The git repository is available at: https://github.com/ExtremeDot/wireguard-install"
	echo ""
	echo "I need to ask you a few questions before starting the setup."
	echo "You can keep the default options and just press enter if you are ok with them."
	echo ""

	# Detect public IPv4 or IPv6 address and pre-fill for the user
	SERVER_PUB_IP=$(ip -4 addr | sed -ne 's|^.* inet \([^/]*\)/.* scope global.*$|\1|p' | awk '{print $1}' | head -1)
	if [[ -z ${SERVER_PUB_IP} ]]; then
		# Detect public IPv6 address
		SERVER_PUB_IP=$(ip -6 addr | sed -ne 's|^.* inet6 \([^/]*\)/.* scope global.*$|\1|p' | head -1)
	fi
	read -rp "IPv4 or IPv6 public address: " -e -i "${SERVER_PUB_IP}" SERVER_PUB_IP

	# Detect public interface and pre-fill for the user
	SERVER_NIC="$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)"
	until [[ ${SERVER_PUB_NIC} =~ ^[a-zA-Z0-9_]+$ ]]; do
		read -rp "Public interface: " -e -i "${SERVER_NIC}" SERVER_PUB_NIC
	done

	until [[ ${SERVER_WG_NIC} =~ ^[a-zA-Z0-9_]+$ && ${#SERVER_WG_NIC} -lt 16 ]]; do
		read -rp "WireGuard interface name: " -e -i wg0 SERVER_WG_NIC
	done

	until [[ ${SERVER_WG_IPV4} =~ ^([0-9]{1,3}\.){3} ]]; do
		read -rp "Server WireGuard IPv4: " -e -i 10.66.66.1 SERVER_WG_IPV4
	done

	until [[ ${SERVER_WG_IPV6} =~ ^([a-f0-9]{1,4}:){3,4}: ]]; do
		read -rp "Server WireGuard IPv6: " -e -i fd42:42:42::1 SERVER_WG_IPV6
	done

	# Generate random number within private ports range
	RANDOM_PORT=$(shuf -i49152-65535 -n1)
	until [[ ${SERVER_PORT} =~ ^[0-9]+$ ]] && [ "${SERVER_PORT}" -ge 1 ] && [ "${SERVER_PORT}" -le 65535 ]; do
		read -rp "Server WireGuard port [1-65535]: " -e -i "${RANDOM_PORT}" SERVER_PORT
	done

	# Adguard DNS by default
	until [[ ${CLIENT_DNS_1} =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
		read -rp "First DNS resolver to use for the clients: " -e -i 1.1.1.1 CLIENT_DNS_1
	done
	until [[ ${CLIENT_DNS_2} =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
		read -rp "Second DNS resolver to use for the clients (optional): " -e -i 1.0.0.1 CLIENT_DNS_2
		if [[ ${CLIENT_DNS_2} == "" ]]; then
			CLIENT_DNS_2="${CLIENT_DNS_1}"
		fi
	done

	until [[ ${ALLOWED_IPS} =~ ^.+$ ]]; do
		echo -e "\nWireGuard uses a parameter called AllowedIPs to determine what is routed over the VPN."
		read -rp "Allowed IPs list for generated clients (leave default to route everything): " -e -i '0.0.0.0/0,::/0' ALLOWED_IPS
		if [[ ${ALLOWED_IPS} == "" ]]; then
			ALLOWED_IPS="0.0.0.0/0,::/0"
		fi
	done

	echo ""
	echo "Okay, that was all I needed. We are ready to setup your WireGuard server now."
	echo "You will be able to generate a client at the end of the installation."
	read -n1 -r -p "Press any key to continue..."
}

function installWireGuard() {
	# Run setup questions first
	installQuestions

	# Install WireGuard tools and module
	if [[ ${OS} == 'ubuntu' ]] || [[ ${OS} == 'debian' && ${VERSION_ID} -gt 10 ]]; then
		apt-get update
		apt-get install -y wireguard iptables resolvconf qrencode
		create_wg_exp_ctrl_script
	elif [[ ${OS} == 'debian' ]]; then
		if ! grep -rqs "^deb .* buster-backports" /etc/apt/; then
			echo "deb http://deb.debian.org/debian buster-backports main" >/etc/apt/sources.list.d/backports.list
			apt-get update
		fi
		apt update
		apt-get install -y iptables resolvconf qrencode
		apt-get install -y -t buster-backports wireguard
		create_wg_exp_ctrl_script
	elif [[ ${OS} == 'fedora' ]]; then
		if [[ ${VERSION_ID} -lt 32 ]]; then
			dnf install -y dnf-plugins-core
			dnf copr enable -y jdoss/wireguard
			dnf install -y wireguard-dkms
		fi
		dnf install -y wireguard-tools iptables qrencode
	elif [[ ${OS} == 'centos' ]] || [[ ${OS} == 'almalinux' ]] || [[ ${OS} == 'rocky' ]]; then
		if [[ ${VERSION_ID} == 8* ]]; then
			yum install -y epel-release elrepo-release
			yum install -y kmod-wireguard
			yum install -y qrencode # not available on release 9
		fi
		yum install -y wireguard-tools iptables
	elif [[ ${OS} == 'oracle' ]]; then
		dnf install -y oraclelinux-developer-release-el8
		dnf config-manager --disable -y ol8_developer
		dnf config-manager --enable -y ol8_developer_UEKR6
		dnf config-manager --save -y --setopt=ol8_developer_UEKR6.includepkgs='wireguard-tools*'
		dnf install -y wireguard-tools qrencode iptables
	elif [[ ${OS} == 'arch' ]]; then
		pacman -S --needed --noconfirm wireguard-tools qrencode
	fi

	# Make sure the directory exists (this does not seem the be the case on fedora)
	mkdir /etc/wireguard >/dev/null 2>&1
	mkdir -p /usr/local/extDot >/dev/null 2>&1

	chmod 600 -R /etc/wireguard/
	chmod 600 -R /usr/local/extDot

	SERVER_PRIV_KEY=$(wg genkey)
	SERVER_PUB_KEY=$(echo "${SERVER_PRIV_KEY}" | wg pubkey)

	# Save WireGuard settings
	echo "SERVER_PUB_IP=${SERVER_PUB_IP}
SERVER_PUB_NIC=${SERVER_PUB_NIC}
SERVER_WG_NIC=${SERVER_WG_NIC}
SERVER_WG_IPV4=${SERVER_WG_IPV4}
SERVER_WG_IPV6=${SERVER_WG_IPV6}
SERVER_PORT=${SERVER_PORT}
SERVER_PRIV_KEY=${SERVER_PRIV_KEY}
SERVER_PUB_KEY=${SERVER_PUB_KEY}
CLIENT_DNS_1=${CLIENT_DNS_1}
CLIENT_DNS_2=${CLIENT_DNS_2}
ALLOWED_IPS=${ALLOWED_IPS}" >/etc/wireguard/params

	# Add server interface
	echo "[Interface]
Address = ${SERVER_WG_IPV4}/24,${SERVER_WG_IPV6}/64
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PRIV_KEY}" >"/etc/wireguard/${SERVER_WG_NIC}.conf"

	if pgrep firewalld; then
		FIREWALLD_IPV4_ADDRESS=$(echo "${SERVER_WG_IPV4}" | cut -d"." -f1-3)".0"
		FIREWALLD_IPV6_ADDRESS=$(echo "${SERVER_WG_IPV6}" | sed 's/:[^:]*$/:0/')
		echo "PostUp = firewall-cmd --add-port ${SERVER_PORT}/udp && firewall-cmd --add-rich-rule='rule family=ipv4 source address=${FIREWALLD_IPV4_ADDRESS}/24 masquerade' && firewall-cmd --add-rich-rule='rule family=ipv6 source address=${FIREWALLD_IPV6_ADDRESS}/24 masquerade'
PostDown = firewall-cmd --remove-port ${SERVER_PORT}/udp && firewall-cmd --remove-rich-rule='rule family=ipv4 source address=${FIREWALLD_IPV4_ADDRESS}/24 masquerade' && firewall-cmd --remove-rich-rule='rule family=ipv6 source address=${FIREWALLD_IPV6_ADDRESS}/24 masquerade'" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"
	else
		echo "PostUp = iptables -I INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostUp = iptables -I FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -j ACCEPT
PostUp = iptables -I FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
PostUp = ip6tables -I FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostUp = ip6tables -t nat -A POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
PostUp = /usr/local/extDot/wgExpCtrl.sh
PostDown = iptables -D INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = ip6tables -D FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostDown = ip6tables -t nat -D POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"
	fi

	# Enable routing on the server
	echo "net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1" >/etc/sysctl.d/wg.conf

	sysctl --system

	systemctl start "wg-quick@${SERVER_WG_NIC}"
	systemctl enable "wg-quick@${SERVER_WG_NIC}"
	
	if [ ! -f /usr/local/extDot/userInfo.conf ]; then
	echo "No userInfo file , creating ..."
	else
	echo "Old userInfo file has found, cleaning data on it ..."
	rm /usr/local/extDot/userInfo.conf
	sleep 1
	fi
	
	touch /usr/local/extDot/userInfo.conf
	
	chmod u+rw /usr/local/extDot/userInfo.conf
	
	INSTART=1
	sleep 1
	
	newClient
	
	echo -e "${GREEN}If you want to add more clients, you simply need to run this script another time!${NC}"

	# Check if WireGuard is running
	systemctl is-active --quiet "wg-quick@${SERVER_WG_NIC}"
	WG_RUNNING=$?

	# WireGuard might not work if we updated the kernel. Tell the user to reboot
	if [[ ${WG_RUNNING} -ne 0 ]]; then
		echo -e "\n${RED}WARNING: WireGuard does not seem to be running.${NC}"
		echo -e "${ORANGE}You can check if WireGuard is running with: systemctl status wg-quick@${SERVER_WG_NIC}${NC}"
		echo -e "${ORANGE}If you get something like \"Cannot find device ${SERVER_WG_NIC}\", please reboot!${NC}"
	else # WireGuard is running
		echo -e "\n${GREEN}WireGuard is running.${NC}"
		echo -e "${GREEN}You can check the status of WireGuard with: systemctl status wg-quick@${SERVER_WG_NIC}\n\n${NC}"
		echo -e "${ORANGE}If you don't have internet connectivity from your client, try to reboot the server.${NC}"
	fi
	
	
	# add a cronjob to refresh every 1 hour user expiration
	CRTLINE="/usr/local/extDot/wgExpCtrl.sh"
	CRONTAB=$(crontab -l)
	
	if [[ $CRONTAB == *"$CRTLINE"* ]]; then
		echo "Crontab has Updated Before."
	else
		echo "The specified line does not exist in the crontab."
		chmod +x /usr/local/extDot/wgExpCtrl.sh
		crontab -l | { cat; echo "45 * * * * /usr/local/extDot/wgExpCtrl.sh" ; } | crontab -
	fi

}

function updateSC() {
mkdir -p /tmp/extdotwg
cd /tmp/extdotwg
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf
wget https://raw.githubusercontent.com/ExtremeDot/wireguard-install/extreme/wireguard-install.sh
chmod +x wireguard-install.sh
mv /tmp/extdotwg/wireguard-install.sh /usr/local/bin/eXdot-WG
chmod +x /usr/local/bin/eXdot-WG
bash /usr/local/bin/eXdot-WG ; exit

}

function newClient() {

	# If SERVER_PUB_IP is IPv6, add brackets if missing
	if [[ ${SERVER_PUB_IP} =~ .*:.* ]]; then
		if [[ ${SERVER_PUB_IP} != *"["* ]] || [[ ${SERVER_PUB_IP} != *"]"* ]]; then
			SERVER_PUB_IP="[${SERVER_PUB_IP}]"
		fi
	fi
	ENDPOINT="${SERVER_PUB_IP}:${SERVER_PORT}"

	echo ""
	echo "Client configuration"
	echo ""
	echo "The client name must consist of alphanumeric character(s). It may also include underscores or dashes and can't exceed 15 chars."
	CLIENT_NAME=""
	until [[ ${CLIENT_NAME} =~ ^[a-zA-Z0-9_-]+$ && ${CLIENT_EXISTS} == '0' && ${#CLIENT_NAME} -lt 16 ]]; do
		read -rp "Client name: " -e CLIENT_NAME
		CLIENT_EXISTS=$(grep -c -E "^### Client ${CLIENT_NAME}\$" "/etc/wireguard/${SERVER_WG_NIC}.conf")

		if [[ ${CLIENT_EXISTS} != 0 ]]; then
			echo ""
			echo -e "${ORANGE}A client with the specified name was already created, please choose another name.${NC}"
			echo ""
		fi
	done

	for DOT_IP in {2..254}; do
		DOT_EXISTS=$(grep -c "${SERVER_WG_IPV4::-1}${DOT_IP}" "/etc/wireguard/${SERVER_WG_NIC}.conf")
		if [[ ${DOT_EXISTS} == '0' ]]; then
			break
		fi
	done

	if [[ ${DOT_EXISTS} == '1' ]]; then
		echo ""
		echo "The subnet configured supports only 253 clients."
		exit 1
	fi
	
	# Get current date
	current_date=$(date +'%Y-%m-%d')
	
	# Prompt user to set expiration date with default value of current date
	echo "Enter expiration date in (YYYY-MM-DD) format: "
	
	# Use default value if user input is empty
	read -rp "Expiration date: " -e -i "$current_date" expiration_date
	expiration_date=${expiration_date:-$current_date}
	
	# Check that the expiration date is in the correct format
		until date -d "$expiration_date" >/dev/null 2>&1; do
			echo -e "${RED} Error: Invalid date format. Please use the format YYYY-MM-DD ${NC}"
			read -rp "Expiration date: " -e -i "$current_date" expiration_date
		done
		
	# add to database
	# Check if file exists, create it if it doesn't
	if [ ! -f /usr/local/extDot/userInfo.conf ]; then
	touch /usr/local/extDot/userInfo.conf
	chmod u+rw /usr/local/extDot/userInfo.conf
	fi
	
	echo "${CLIENT_NAME}=$expiration_date" >> /usr/local/extDot/userInfo.conf
	
	# Clean VARS
	BASEIP=""
	IPV4_EXISTS=""
	IPV6_EXISTS=""
	
	BASE_IP=$(echo "$SERVER_WG_IPV4" | awk -F '.' '{ print $1"."$2"."$3 }')
	until [[ ${IPV4_EXISTS} == '0' ]]; do
		read -rp "Client WireGuard IPv4: ${BASE_IP}." -e -i "${DOT_IP}" DOT_IP
		CLIENT_WG_IPV4="${BASE_IP}.${DOT_IP}"
		IPV4_EXISTS=$(grep -c "$CLIENT_WG_IPV4/32" "/etc/wireguard/${SERVER_WG_NIC}.conf")

		if [[ ${IPV4_EXISTS} != 0 ]]; then
			echo ""
			echo -e "${ORANGE}A client with the specified IPv4 was already created, please choose another IPv4.${NC}"
			echo ""
		fi
	done

	BASE_IP=$(echo "$SERVER_WG_IPV6" | awk -F '::' '{ print $1 }')
	until [[ ${IPV6_EXISTS} == '0' ]]; do
		read -rp "Client WireGuard IPv6: ${BASE_IP}::" -e -i "${DOT_IP}" DOT_IP
		CLIENT_WG_IPV6="${BASE_IP}::${DOT_IP}"
		IPV6_EXISTS=$(grep -c "${CLIENT_WG_IPV6}/128" "/etc/wireguard/${SERVER_WG_NIC}.conf")

		if [[ ${IPV6_EXISTS} != 0 ]]; then
			echo ""
			echo -e "${ORANGE}A client with the specified IPv6 was already created, please choose another IPv6.${NC}"
			echo ""
		fi
	done

	# Generate key pair for the client
	CLIENT_PRIV_KEY=$(wg genkey)
	CLIENT_PUB_KEY=$(echo "${CLIENT_PRIV_KEY}" | wg pubkey)
	CLIENT_PRE_SHARED_KEY=$(wg genpsk)

	HOME_DIR=$(getHomeDirForClient "${CLIENT_NAME}")
	mkdir -p $HOME_DIR

	# Create client file and add the server as a peer
	echo "[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128
DNS = ${CLIENT_DNS_1},${CLIENT_DNS_2}

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT}
AllowedIPs = ${ALLOWED_IPS}" >"${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"

	# Add the client as a peer to the server
	echo -e "\n### Client ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
AllowedIPs = ${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"

	wg syncconf "${SERVER_WG_NIC}" <(wg-quick strip "${SERVER_WG_NIC}")

	# Generate QR code if qrencode is installed
	if command -v qrencode &>/dev/null; then
		echo -e "${GREEN}\nHere is your client config file as a QR Code:\n${NC}"
		qrencode -t ansiutf8 -l L <"${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"
		echo ""
	fi

	echo -e "${GREEN}Your client config file is in ${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf${NC}"
	
	back2Menu
}

function listClients() {
echo
echo "== All Clients Information =========================================================="
NUMBER_OF_CLIENTS=$(grep -c -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf")
if [[ ${NUMBER_OF_CLIENTS} -eq 0 ]]; then
	echo
	echo "You have no existing clients!"
	back2Menu
fi

WG_CONF="/etc/wireguard/${SERVER_WG_NIC}.conf"
USER_INFO="/usr/local/extDot/userInfo.conf"
clients=$(grep -E "^### Client" "$WG_CONF" | cut -d ' ' -f 3)
counter=1
while read -r client; do
    expiration_date=$(grep -E "^${client}=" "$USER_INFO" | cut -d '=' -f 2)
    if [[ "$(date +%Y-%m-%d)" > "$expiration_date" ]]; then
        echo -e "\e[31m  - $counter. [ $expiration_date ] - $client\e[0m"
    else
        echo "  - $counter. [ $expiration_date ] - $client"
    fi

    ((counter++))
done <<< "$clients"
back2Menu

}


function genQRClients() {
	NUMBER_OF_CLIENTS=$(grep -c -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf")
	if [[ ${NUMBER_OF_CLIENTS} == '0' ]]; then
		echo ""
		echo "You have no existing clients!"
		back2Menu
	fi
	CLIENT_NUMBER=""

	echo ""
	echo "Select the existing client you want to generate QR code for it"
	grep -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf" | cut -d ' ' -f 3 | nl -s ') '
	until [[ ${CLIENT_NUMBER} -ge 1 && ${CLIENT_NUMBER} -le ${NUMBER_OF_CLIENTS} ]]; do
		if [[ ${CLIENT_NUMBER} == '1' ]]; then
			read -rp "Select one client [1]: " CLIENT_NUMBER
		else
			read -rp "Select one client [1-${NUMBER_OF_CLIENTS}]: " CLIENT_NUMBER
		fi
	done

	# match the selected number to a client name
	CLIENT_NAME=$(grep -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf" | cut -d ' ' -f 3 | sed -n "${CLIENT_NUMBER}"p)
	HOME_DIR=$(getHomeDirForClient "${CLIENT_NAME}")
	# Generate QR code if qrencode is installed
	if command -v qrencode &>/dev/null; then
		echo -e "${GREEN}\nHere is your client config file as a QR Code:\n${NC}"
		qrencode -t ansiutf8 -l L <"${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"
		echo ""
	fi

	echo -e "${GREEN}Your client config file is in ${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf${NC}"
	
	back2Menu
	
	}
	
function updateExpClient() {
clients_file="/usr/local/extDot/userInfo.conf"
clients=($(grep -oP '^[^=]+' "$clients_file"))
echo "Existing clients:"
for i in "${!clients[@]}"; do
  echo "$((i+1)). ${clients[i]}"
done

client_number=""

# Prompt for client selection
read -p "Select a client number: " client_number
# Validate client selection
if [[ ! "$client_number" =~ ^[0-9]+$ ]] || [[ "$client_number" -lt 1 ]] || [[ "$client_number" -gt "${#clients[@]}" ]]; then
  echo "Invalid client number."
  exit 1
fi

# Get selected client name
selected_client="${clients[client_number-1]}"

current_date=$(date +'%Y-%m-%d')
echo "Enter expiration date in (YYYY-MM-DD) format: "
read -rp "Expiration date: " -e -i "$current_date" new_expiration_date
new_expiration_date=${new_expiration_date:-$current_date}
until date -d "$new_expiration_date" >/dev/null 2>&1; do
	echo -e "${RED} Error: Invalid date format. Please use the format YYYY-MM-DD ${NC}"
	read -rp "Expiration date: " -e -i "$current_date" new_expiration_date
done

# Update expiration date in the userInfo.conf file
sed -i "s/^$selected_client=.*/$selected_client=$new_expiration_date/" "$clients_file"
echo "Expiration date updated for $selected_client."
back2Menu

}

function revokeClient() {
	NUMBER_OF_CLIENTS=$(grep -c -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf")
	if [[ ${NUMBER_OF_CLIENTS} == '0' ]]; then
		echo ""
		echo "You have no existing clients!"
		back2Menu
	fi

	CLIENT_NUMBER=-100

	echo ""
	echo "Select the existing client you want to revoke"
	echo "     0) Back to Main Menu"
	grep -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf" | cut -d ' ' -f 3 | nl -s ') '
	until [[ ${CLIENT_NUMBER} -ge 0 && ${CLIENT_NUMBER} -le ${NUMBER_OF_CLIENTS} ]]; do
		if [[ ${CLIENT_NUMBER} == '1' ]]; then
			read -rp "Select one client [1]: " CLIENT_NUMBER
		else
			read -rp "Select one client [0-${NUMBER_OF_CLIENTS}]: " CLIENT_NUMBER
		fi
	done
	
	if [[ -n $CLIENT_NUMBER ]]; then
		if [[ $CLIENT_NUMBER -eq 0 ]]; then
			back2Menu
		elif [[ $CLIENT_NUMBER -eq -100 ]]; then
			back2Menu
		fi
	else
		back2Menu
	fi	
		
	# match the selected number to a client name
	CLIENT_NAME=$(grep -E "^### Client" "/etc/wireguard/${SERVER_WG_NIC}.conf" | cut -d ' ' -f 3 | sed -n "${CLIENT_NUMBER}"p)

	# remove [Peer] block matching $CLIENT_NAME
	sed -i "/^### Client ${CLIENT_NAME}\$/,/^$/d" "/etc/wireguard/${SERVER_WG_NIC}.conf"

	# remove generated client file
	HOME_DIR=$(getHomeDirForClient "${CLIENT_NAME}")
	rm -f "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"
	
	# remove expiration data 
	if [ -f "/usr/local/extDot/userInfo.conf" ]; then
		sed -i "/$CLIENT_NAME/d" "/usr/local/extDot/userInfo.conf"
		echo "Line containing '$CLIENT_NAME' has been removed from userInfo.conf."
	else
		echo "The file /usr/local/extDot/userInfo.conf does not exist."
	fi

	# restart wireguard to apply changes
	wg syncconf "${SERVER_WG_NIC}" <(wg-quick strip "${SERVER_WG_NIC}")
	back2Menu
}

function oldDataBackup() {
	current_datetime=$(date +'%Y-%m-%d_%H-%M-%S')
	backup_folder="/usr/local/extDot/backup/$current_datetime"
	mkdir -p "$backup_folder"
	cp -r /etc/wireguard/* "$backup_folder"
	mv /usr/local/extDot/userInfo.conf "$backup_folder/userInfo.conf"
}

function uninstallWg() {
	echo ""
	echo -e "\n${RED}WARNING: This will uninstall WireGuard and remove all the configuration files!${NC}"
	echo -e "${ORANGE}for Debian and Ubuntu ,Current configs will backed up into [/usr/local/exdotwg/backup] folder.\n${NC}"
	read -rp "Do you really want to remove WireGuard? [y/n]: " -e REMOVE
	REMOVE=${REMOVE:-n}
	if [[ $REMOVE == 'y' ]]; then
		
		checkOS
		systemctl stop "wg-quick@${SERVER_WG_NIC}"
		systemctl disable "wg-quick@${SERVER_WG_NIC}"

		if [[ ${OS} == 'ubuntu' ]]; then
			oldDataBackup		
			apt-get remove -y wireguard wireguard-tools qrencode
		elif [[ ${OS} == 'debian' ]]; then
			oldDataBackup
			apt-get remove -y wireguard wireguard-tools qrencode
		elif [[ ${OS} == 'fedora' ]]; then
			dnf remove -y --noautoremove wireguard-tools qrencode
			if [[ ${VERSION_ID} -lt 32 ]]; then
				dnf remove -y --noautoremove wireguard-dkms
				dnf copr disable -y jdoss/wireguard
			fi
		elif [[ ${OS} == 'centos' ]] || [[ ${OS} == 'almalinux' ]] || [[ ${OS} == 'rocky' ]]; then
			yum remove -y --noautoremove wireguard-tools
			if [[ ${VERSION_ID} == 8* ]]; then
				yum remove --noautoremove kmod-wireguard qrencode
			fi
		elif [[ ${OS} == 'oracle' ]]; then
			yum remove --noautoremove wireguard-tools qrencode
		elif [[ ${OS} == 'arch' ]]; then
			pacman -Rs --noconfirm wireguard-tools qrencode
		fi
		
		rm -rf /etc/wireguard
		rm -f /etc/sysctl.d/wg.conf

		# Reload sysctl
		sysctl --system

		# Check if WireGuard is running
		systemctl is-active --quiet "wg-quick@${SERVER_WG_NIC}"
		WG_RUNNING=$?

		if [[ ${WG_RUNNING} -eq 0 ]]; then
			echo "WireGuard failed to uninstall properly."
			exit 1
		else
			echo "WireGuard uninstalled successfully."
			exit 0
		fi
		
		CRTLINE="/usr/local/extDot/wgExpCtrl.sh"
		CRONTAB=$(crontab -l)
		if [[ $CRONTAB == *"$CRTLINE"* ]]; then
		NEW_CRONTAB=$(echo "$CRONTAB" | grep -v "$CRTLINE")
		echo "$NEW_CRONTAB" | crontab -
		echo "Line removed successfully."
		else
		echo "The specified line does not exist in the crontab."
		fi
	else
		echo ""
		echo "Removal aborted!"
	fi
}

function manageMenu() {
	echo "====================================================================================="
	echo "Welcome to WireGuard-installation Menu by ExtremeDOT                     Version $EDVERSION"
	echo "This script is forked from Angristan Script"						   
	echo
	echo "https://github.com/ExtremeDot/wireguard-install"
	echo " ------------------------------------------------------------------------------------"
	echo
	echo "   1) Add a new user                               6) Edit UserInfo"
	echo "   2) Show all users information                   7) Permission Fix for Script"
	echo "   3) Generate QR for Clients                      8) Syncing Configs to Apply Users"
	echo "   4) Update the User Expiration Date"
	echo "   5) Revoke existing user"
	echo
	echo " ------------------------------------------------------------------------------------"
	echo "   98) Uninstall WireGuard       99) Update Script to Latest               0) Exit"
	echo "====================================================================================="
	echo
	MENUITEMR=""
	until [[ $MENUITEMR =~ ^[0-9]+$ ]] && [ "$MENUITEMR" -ge 0 ] && [ "$MENUITEMR" -le 99 ]; do
	read -rp "$MENUITEMR [Please Select 0-99]: " -e  MENUITEMR
	done
	case $MENUITEMR in
		
	1)
		newClient
		;;
	2)
		listClients
		;;
	3)
		genQRClients
		;;
	4)
		updateExpClient
		;;		
	5)
		revokeClient
		;;
	6)
		nano /usr/local/extDot/userInfo.conf
		back2Menu
		;;
	7)
		sudo chmod +x /usr/local/extDot/wgExpCtrl.sh
		back2Menu
		;;
		
	8)
		sudo bash /usr/local/extDot/wgExpCtrl.sh
		back2Menu
		;;

	98)
		uninstallWg
		;;		
	99)
		updateSC
		;;
	0)
		exit
		;;
	esac
}

# Check for root, virt, OS...
initialCheck

# Check if WireGuard is already installed and load params
if [[ -e /etc/wireguard/params ]]; then
	source /etc/wireguard/params
	manageMenu
else
	installWireGuard
fi

# new branched

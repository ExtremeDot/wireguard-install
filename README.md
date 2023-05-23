### ExtremeDOT WireGuard Installer 

this script is based on Angristan WireGuard Installer

Updated the script to add User Expiration Date and also some extra options!


![image](https://github.com/ExtremeDot/wireguard-install/assets/120102306/9ee5ba7b-1781-4dd6-a716-550b5a3913ef)


## Usage

Download and execute the script. Answer the questions asked by the script and it will take care of the rest.

```bash
curl -O https://raw.githubusercontent.com/ExtremeDot/wireguard-install/extreme/wireguard-install.sh

chmod +x wireguard-install.sh

cp wireguard-install.sh /usr/local/bin/eXdot-WG && chmod +x /usr/local/bin/eXdot-WG

eXdot-WG

```

***

# WireGuard installer

**This project is a bash script that aims to setup a [WireGuard](https://www.wireguard.com/) VPN on a Linux server, as easily as possible!**

WireGuard is a point-to-point VPN that can be used in different ways. Here, we mean a VPN as in: the client will forward all its traffic through an encrypted tunnel to the server.
The server will apply NAT to the client's traffic so it will appear as if the client is browsing the web with the server's IP.

## Requirements
Supported distributions:
- AlmaLinux >= 8
- Arch Linux
- CentOS Stream >= 8
- Debian >= 10
- Fedora >= 32
- Oracle Linux
- Rocky Linux >= 8
- Ubuntu >= 18.04

***

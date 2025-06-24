#!/bin/bash -e

function remove_existing_installation() {
  if [ -e "/opt/connect-icmsolar" ]; then
    client_name=$(cat /home/pi/identity/client-name)
    client="${client_name// /}"

    sudo rm -r "/home/pi/identity"
    sudo rm "/home/pi/.ssh/$client"
    sudo rm "/home/pi/.ssh/$client.pub"
    sudo rm -r "/opt/connect-icmsolar"

    (crontab -l | sed -E 's/0\s(8|12)\s\*\s\*\s1\,4.+$//' | sed '/^$/d') | crontab -
  else
    return
  fi
  
}

# Retrieve identifiers and store them in files
function get_identifiers() {
  while true; do
    read -p "Enter client's full name: " client_name
    if [ ${#client_name} -gt 0 ]; then
      read -p "Is $client_name correct? (y/n): " answer
      case "$answer" in
      y | Y)
        echo "Client name confirmed! Continuing installation..."
        break
        ;;
      n | N)
        echo "Please correct client's name"
        ;;
      *)
        echo "Invalid Response. Please try again. (y/n)"
        ;;
      esac
    else
      echo "Empty string. Please try again"
    fi
  done
  if [ ! -d /home/pi/identity ]; then
    sudo mkdir /home/pi/identity
  fi
  if [ ! -d /home/pi/.ssh ]; then
    sudo mkdir /home/pi/.ssh
  fi
  echo "$client_name" >/home/pi/identity/client-name
  sudo cat /etc/machine-id >/home/pi/identity/machine-id
  sudo cat /sys/class/net/eth0/address >/home/pi/identity/mac-addresses
  sudo cat /sys/class/net/wlan0/address >>/home/pi/identity/mac-addresses

  name_to_format=$(sudo cat /home/pi/identity/client-name)
  client="${name_to_format// /}"

  machine_id=$(sudo cat /home/pi/identity/machine-id)
  mac_addresses=$(sudo cat /home/pi/identity/mac-addresses)
  sudo echo "Client: $client_name" >/home/pi/identity/$client.id
  sudo echo "ID: $machine_id" >>/home/pi/identity/$client.id
  sudo echo -e "MAC:\n$mac_addresses" >>/home/pi/identity/$client.id
  # At this point we will have the following files
  # client-name, machine-id, mac-addresses, $client.id
  # These are contained within the identity directory

  echo "Identifiers Complete."

}

# Create ssh key files, chmod 600 on the keys, Restart systemctl ssh
function create_keys() {

  sudo sed -i 's/^#PubkeyAuthentication yes$/PubkeyAuthentication yes/' /etc/ssh/sshd_config # enable PubkeyAuthentication

  client_name=$(sudo cat /home/pi/identity/client-name)
  client="${client_name// /}"

  sudo systemctl restart ssh
  echo "Restarting SSH Services. Please Wait."
  sleep 5s
  # generate key pair
  sudo ssh-keygen -t rsa -b 4096 -N "" -f "/home/pi/.ssh/$client" <<<y >/dev/null 2>&1
  sudo chmod 600 "/home/pi/.ssh/$client*"
  # add the key on the linux system
  sudo ssh-add "/home/pi/.ssh/$client"
  # copy the key to the identity folder for packaging
  sudo cp "/home/pi/.ssh/$client.pub" "/home/pi/identity/$client.pub"
  # restart the ssh service to make sure it works
  sudo systemctl restart ssh
  echo "Restarting SSH Services. Please Wait."
  sleep 10s

  echo "Secure Shell Keys Created."

}

function add_ssh_hostname() {
  # This function simply adds the host to the ssh_config file
  # In case the system ever restarts, the host is added and will automatically know where to send the files

  client_name=$(sudo cat /home/pi/identity/client-name)
  client="${client_name// /}"
  config_file="/etc/ssh/sshd_config"
  target_host="connect-icmsolar"
  new_hostname="igoteggs.ddns.net"

  sudo cp "$config_file" "$config_file.bak"  # Create a backup of the original file

  if grep -q "Host connect-icmsolar" "$config_file"; then
    # Correct the hostname for the target host
    sudo awk -v host="$target_host" -v new_hostname="$new_hostname" '
    BEGIN { in_block=0 }
    /^Host[ \t]+/ {
      if ($2 == host) {
        in_block = 1
      } else {
        in_block = 0
      }
    }
    in_block && /^[ \t]*Hostname[ \t]+/ {
      $2 = new_hostname
      print "     Hostname " new_hostname
      next
    }
    { print }
    ' "$config_file.bak" > "$config_file"
  else
    sudo echo -e "Host connect-icmsolar" >>/etc/ssh/ssh_config                    # Alias for system
    sudo echo -e "\tHostname igoteggs.ddns.net" >>/etc/ssh/ssh_config             # WindowsDDNS
    sudo echo -e "\tUser info" >>/etc/ssh/ssh_config                              # WindowsUsername
    sudo echo -e "\tPort 27472" >>/etc/ssh/ssh_config                             # WindowsPort
    sudo echo -e "\tIdentityFile /home/pi/.ssh/$client" >>/etc/ssh/ssh_config     # KeyFile
  fi

}

### Do I need to create an offset for each install?
### Update the scripts for crontab
# Set crontab
function set_crontab() {

  # Every Monday and Thursday @ 08:00 and 12:00
  (
    crontab -l 2>/dev/null
    echo "0 8 * * 1,4 /opt/connect-icmsolar/send_files.sh"
  ) | crontab -
  (
    crontab -l 2>/dev/null
    echo "0 12 * * 1,4 /opt/connect-icmsolar/send_files.sh"
  ) | crontab -

  echo "Cron Table Set."
}

function send_files() {
  # files that need to be sent for the initial install, will serve as one of the independant scripts
  # this will be the only time that the SSH.pub key will be sent
  # the independant will send only the .id file and the ICMSolar.db file
  client_name=$(sudo cat /home/pi/identity/client-name)
  client="${client_name// /}"
  int=$(echo $RANDOM)
  archive="$client($int).zip"

  sudo apt install zip -y

  sudo zip -q -j "/home/pi/identity/$archive" "/home/pi/identity/$client.id" "/home/pi/identity/$client.pub" "/home/pi/ICM/ICMSolar.db"
  sudo scp -P 27472 "/home/pi/identity/$archive" connect-icmsolar:C:/Connect-ICMSolar/LoadingBay

  sudo rm -f "/home/pi/identity/$archive"
  echo "Initial Files Sent."

}

# Copy scripts to the correct directory
function install_files() {

  if [ ! -d /opt/connect-icmsolar ]; then
    sudo mkdir /opt/connect-icmsolar
  fi

  script=$(cat <<'EOF' 
#!/bin/bash -e

function send_files () {
  # this independant script will send only the .id file and the ICMSolar.db file
  # the ssh.pub key was already sent and installed on the windows system during the initial install
  client_name=$(sudo cat /home/pi/identity/client-name)
  client="${client_name// /}" 
  int=$(echo $RANDOM) 
  archive="$client($int).zip"

  sudo zip -q -j "/home/pi/identity/$archive" "/home/pi/identity/$client.id" "/home/pi/ICM/ICMSolar.db"
  sudo scp -P 27472 "/home/pi/identity/$archive" connect-icmsolar:C:/Connect-ICMSolar/LoadingBay

  sleep 100
  sudo rm -f /home/pi/identity/*.zip
  echo "Files Sent."

}

send_files
EOF
)

  sudo echo "$script" > /opt/connect-icmsolar/send_files.sh
  sudo chmod 700 /opt/connect-icmsolar/send_files.sh

  echo "Script Installed."
}

################################
######### Running Code #########
################################

# Remove any existing installation files if found
remove_existing_installation
# Get identifiers and compile the identity file
get_identifiers
# Modify settings, create SSH keys, install on server and prepare Public Key for packaging
create_keys
# Append host to ssh_config file
add_ssh_hostname
# Install script for SCP transfers
install_files
# Set Crontab for automation
set_crontab
# Package and send client files to Windows
send_files

# Show Completion of tasks
echo "Installation is Complete. Please confirm the Database entry."

################################
########  End of Code   ########
################################

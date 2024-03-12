#!/usr/bin/env bash

# Set keymap to "no"
loadkeys no

# Set console font
setfont ter-132b

clear

echo -ne "This installer assumes UEFI mode. Checking if boot mode is UEFI:"

# Get the firmware platform size
platform_size=$(cat /sys/firmware/efi/fw_platform_size 2>/dev/null)

# Check if the platform size is "32" or "64"
if [ "$platform_size" == "32" ] || [ "$platform_size" == "64" ]; then
    echo "Boot mode is UEFI. Carrying on..."
    sleep 1
    clear
else
    echo "Boot mode is not UEFI. Exiting script..."
    exit 1
fi

#Check internet connection
echo -ne "Checking internet connection"
ping -c 1 archlinux.org > /dev/null 2>&1

if [ $? -eq 0 ]; then
    echo "Internet connection confirmed. Continuing with the installation."
    sleep 1
    clear
else
    echo "Error: Unable to reach archlinux.org. Please check your internet connection, then try to run the installer script again."
    exit 1
fi

# Update system clock
timedatectl

clear

# Select drive for root partition
while true; do
    echo "Available drives:"
    lsblk -o NAME,SIZE -d -n

    echo -e "\nPlease select the drive for the root partition:"
    read root_drive

    # Validate the input drive
    if [[ -b $root_drive ]]; then
        echo "You have selected $root_drive for the root partition."
        break
    else
        echo "Invalid drive selected. Please try again."
    fi
done

# Decide if /home should be on a separate drive or not
while true; do
    # Clear the console
    clear

    # Prompt the user for the choice
    echo "Do you want to create a separate partition for /home? (y/n)"
    read -r separate_home_choice

    # Variable to store the choice (0 for same drive, 1 for separate drive)
    separate_home=0

    # Check the user's choice
    if [ "$separate_home_choice" == "y" ] || [ "$separate_home_choice" == "Y" ]; then
        separate_home=1
        echo "You have chosen to create a separate partition for /home."
        break
    elif [ "$separate_home_choice" == "n" ] || [ "$separate_home_choice" == "N" ]; then
        echo "You have chosen to use the same drive for / and /home."
        break
    else
        # Display an error message and prompt the user to try again
        echo -e "Invalid choice. Try again."
        read -p "Press Enter to continue..."
    fi
done
sleep 1
clear

if [ "$separate_home" == 1 ]; then
    while true; do
        echo "Available drives:"
        lsblk -o NAME,SIZE -d -n

        echo -e "\nPlease select the drive for the home partition:"
        read home_drive

        # Validate the input drive
        if [[ -b $home_drive ]]; then
            # Check if the selected home drive is the same as root_drive
            if [ "$home_drive" == "$root_drive" ]; then
                echo "Error: The home drive cannot be the same as the root drive. Please try again."
            else
                echo "You have selected $home_drive for the home partition."
                break
            fi
        else
            echo "Invalid drive selected. Please try again."
        fi
    done
fi

sleep 1
clear

#Make and mount partitions

# Set default sizes in GB
default_efi_size=4
default_swap_size=20

# Function to prompt the user for partition size
get_partition_size() {
    local partition_name=$1
    local default_size=$2
    local available_space=$3

    while true; do
        read -p "Enter size in GB for $partition_name partition (default: $default_size): " size_input
        size_input="${size_input:-$default_size}"

        if [ "$size_input" -le "$available_space" ]; then
            break
        else
            echo "Error: Size exceeds available space. Please enter a valid size."
        fi
    done

    echo "$size_input"
}

# Function to create partitions
create_partitions() {
    local partition_index=1

    # EFI partition
    efi_size=$(get_partition_size "EFI" $default_efi_size)
    echo "Creating EFI partition..."
    efi_part="${root_drive}p${partition_index}"
    parted -s "$root_drive" mklabel gpt
    parted -s "$root_drive" mkpart primary fat32 1MiB ${efi_size}GiB
    parted -s "$root_drive" set 1 esp on
    ((partition_index++))

    # Swap partition
    swap_size=$(get_partition_size "Swap" $default_swap_size)
    echo "Creating Swap partition..."
    swap_part="${root_drive}p${partition_index}"
    parted -s "$root_drive" mkpart primary linux-swap ${efi_size}GiB $((efi_size + swap_size))GiB
    ((partition_index++))

    # Home partition (if separate_home is 1)
    if [ "$separate_home" == 1 ]; then
        home_size=$(get_partition_size "Home" "")
        echo "Creating Home partition..."
        home_part="${root_drive}p${partition_index}"
        parted -s "$root_drive" mkpart primary ext4 $((efi_size + swap_size))GiB $((efi_size + swap_size + home_size))GiB
        ((partition_index++))
    fi

    # Calculate available space for the root partition
    root_size=$(( $(lsblk -bdno SIZE "$root_drive") / (1024 * 1024 * 1024) ))  # in GB
    available_space=$((root_size - efi_size - swap_size - home_size))

    # Root partition (rest of the drive)
    root_part="${root_drive}p${partition_index}"
    root_size=$(get_partition_size "Root" "" $available_space)
    echo "Creating Root partition..."
    parted -s "$root_drive" mkpart primary ext4 $((efi_size + swap_size + home_size))GiB 100%
}

# Function to mount partitions
mount_partitions() {
    echo "Mounting partitions..."

    # Mount root partition
    mount "$root_part" /mnt

    # Create mount points for EFI and Home partitions
    mkdir -p /mnt/boot /mnt/home

    # Mount EFI partition
    echo "Mounting EFI partition..."
    mount "$efi_part" /mnt/boot

    # Mount Home partition if separate_home is set to 1
    if [ "$separate_home" == 1 ]; then
        echo "Mounting Home partition..."
        mount "$home_part" /mnt/home
    fi

    # Mount Swap partition
    echo "Enabling swap..."
    swapon "$swap_part"
}

# Main script
if [ "$separate_home" == 1 ] || [ "$separate_home" == 0 ]; then
    create_partitions
    mount_partitions
else
    echo "Invalid value for separate_home variable."
fi

# Display the created partitions with sizes
echo -e "\nThe following partitions have been made and mounted:"
echo "EFI partition: $efi_part (${efi_size}GB)"
echo "Swap partition: $swap_part (${swap_size}GB)"
echo "Home partition: $home_part (${home_size}GB)"
echo "Root partition: $root_part (${root_size}GB)"


echo "Press Enter to continue..."
read -s -n 1
clear

# Update mirrors:

# Update package databases
pacman -Syy --noconfirm

# Install reflector
pacman -S reflector --noconfirm

# Backup the existing mirrorlist
cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.bak

# Use reflector to generate an updated mirrorlist
reflector -c "NO" -f 12 -l 10 -n 12 --save /etc/pacman.d/mirrorlist


# Install essential packages:
pacstrap -K /mnt base base-devel linux linux-firmware sof-firmware vi vim nano sudo systemd openssh reflector git bash-completion

sleep 1
clear

# Generate fstab:
genfstab -U /mnt >> /mnt/etc/fstab


arch-chroot /mnt


# Time:
ln -sf /usr/share/zoneinfo/Europe/Oslo /etc/localtime

hwclock --systohc

# Locale
sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' | tee /etc/locale.conf
echo 'KEYMAP=no' | tee /etc/vconsole.conf


#Hostname:

# Ask the user to input the desired hostname
read -p "Enter the desired hostname: " user_hostname

# Update the /etc/hostname file
echo "$user_hostname" | sudo tee /etc/hostname > /dev/null

# Create /etc/hosts file
cat <<EOF > "/etc/hosts"
127.0.0.1	localhost
::1		localhost
127.0.1.1	$user_hostname
EOF

echo "Hostname set to $user_hostname"
sleep 1
echo "Press Enter to continue..."
read -s -n 1
clear

echo "Fix this then run the installer again."

# Set up wired network:

echo "Setting up wired network..."
printf "\n"
sleep 2

# Detect the active network interface
network_interface=$(ip route | awk '/default/ {print $5}')

# Check if a network interface is found
if [ -z "$network_interface" ]; then
    echo "Error: No active network interface found."
    exit 1
fi

# Install NetworkManager
pacman -S --noconfirm networkmanager

# Enable NetworkManager
systemctl enable NetworkManager

# Create a NetworkManager connection for the wired network interface
nmcli connection add con-name "Wired Connection" ifname "$network_interface" type ethernet
nmcli connection modify "Wired Connection" ipv4.method auto
nmcli connection up "Wired Connection"

# Enable and start systemd-resolved
systemctl enable systemd-resolved
systemctl start systemd-resolved

# Create a symbolic link for /etc/resolv.conf to /run/systemd/resolve/stub-resolv.conf
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

echo "Wired network configuration completed."

echo "Press Enter to continue..."
read -s -n 1
clear

#Set root password:
echo -ne "Set root password"

passwd


echo "Press Enter to continue..."
read -s -n 1
clear


# Create user:
echo -ne "Create a user."
printf "\n"

# Prompt user for a new username
read -p "Enter a new username: " new_username

# Check if the username is empty
if [ -z "$new_username" ]; then
    echo "Error: Username cannot be empty."
    exit 1
fi

# Create the new user
useradd -m -G wheel,audio,video,storage -s /bin/bash "$new_username"

# Prompt user for a password
echo "Set a password for the new user:"
passwd "$new_username"

# Add the new user to sudoers
echo "$new_username ALL=(ALL) ALL" >> /etc/sudoers

echo "User $new_username created and added to sudoers."

echo "Press Enter to continue..."
read -s -n 1
clear


# Install bootloader:

# Install GRUB and efibootmgr without user confirmation
pacman -S --noconfirm grub efibootmgr

# Create the /boot/efi directory if it doesn't exist
mkdir -p /boot/efi

# Mount the EFI partition
mount "$efi_part" /boot/efi

# Install GRUB to the EFI system partition
grub-install --target=x86_64-efi --bootloader-id=GRUB --efi-directory=/boot/efi --recheck

# Generate the GRUB configuration file
grub-mkconfig -o /boot/grub/grub.cfg


clear

exit

umount -R /mnt

echo -ne "Installation finished. Please remove install medium before system boots."
echo -ne "Rebooting system in 5 seconds..."
sleep 1
echo "4..."
sleep 1
echo "3..."
sleep 1
echo "2..."
sleep 1
echo "1..."

printf "\n"

Reboot

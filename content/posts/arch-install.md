---
title: 'An (opinionated) Arch Linux Install Guide'
description: "My personal Arch Linux guide, designed to tell me everything I need and nothing I don't"
date: 2025-08-16T18:53:00
draft: false
tags: ['Linux','Guide']
---

I haven't updated this site in a while, and thought I'd start of by sharing the notes I wrote back in 2024 while installing Arch for the first time. I reworked it into a full guide recently after needing to install Arch again for a new PC build, to skip any repetitive steps I'd need to do in the future. Because this is my guide for personal use, it's assumed:
- You're got a UK keyboard, want British English on your system and are in the London timezone.
- You might need to set up WiFi (my students halls didn't have Ethernet)
- You want to use GRUB as your boot manager. If you don't know the differences between boot managers, just use GRUB.
- You know how to use the vim text editor. If not, you might want to use nano.

If any of those apply to you, you might find some value in reading this alongside the official guide. If you want something more beginner friendly, I'd highly recommend Denshi's comfy guide.
{{< youtube 68z11VAYMS8 >}}

## Set the keyboard layout
Boot into your live media from the BIOS. Once you're greeted, load your keyboard settings.
```shell
loadkeys uk
```
## Connecting to WiFi
The easiest way to connect to WiFi on the live ISO is with [`iwd`](https://wiki.archlinux.org/title/Iwd), a wireless daemon for Linux written by Intel. 

First, if you do not know your wireless device name, list all WiFi devices:
```shell
[iwd]# device list
```
Then, to initiate a scan for networks (note that this command will not output anything):
```shell
[iwd]# station NAME scan
```
You can then list all available networks:
```shell
[iwd]# station NAME get-networks
```
Finally, to connect to a network:
```shell
[iwd]# station NAME connect SSID
```
### Automatic IP and DNS configuration via DHCP
For automatic IP and DNS configuration via DHCP, you have to [manually enable](https://wiki.archlinux.org/title/Iwd#Enable_built-in_network_configuration) the built-in [DHCP](https://linuxconfig.org/how-to-manage-wireless-connections-using-iwd-on-linux) client:
```shell
echo "[General]\nEnableNetworkConfiguration=true" > /etc/iwd/main.conf
sudo systemctl restart iwd
```

## Setting the timezone
After configuring the internet, `timedatectl` should sync the correct time from the internet. If not, use:
```shell
timedatectl set-timezone Europe/London
```
## Partition the disks
While the Arch Linux Installation Guide recommends using `fdisk`, a command-line application for partitioning disks, `cfdisk` is a simpler and more graphical option.
```
cfdisk
```

- Select `gpt` if prompted. Assuming you want to wipe the drive and use exclusively Arch Linux, use the left and right arrow keys to move to the `[ Delete ]` option at the bottom, before using the up and down keys and enter to delete the partitions. 
- Select `[   New   ]` and create a partition size of `500M`. This will be our **boot partition**, ensuring we have enough space for several kernels if needed.
- Create a swap partition for **virtual memory**. Consider how much RAM your system has, and how much you are likely to need in the future. 32G total of available RAM and swap is likely to be plenty. For example, `16G` for a system with 16Gb of RAM.
- Create a final partition, leaving the default value to ensure all the available space is used. This will be the main partition.
- `[  Write  ]` the changes.
- `[   Quit   ]`, list the partitions with `lsblk`, and format them as described in the wiki.
## Format partitions
### Warning!
From this point onwards, substitute `sda1`, `sda2` and `sda3` for the name of these partitions listed in `lsblk`
- `sda1` - name of the **boot** partition
- `sda2` - name of the **swap** partition
- `sda3` - name of the **main** or root partition

Now that the empty partitions have been created, they must be formatted with appropriate file systems. 

 If you created a new EFI boot partition, format it to `FAT32`:
```shell
mkfs.fat -F 32 /dev/sda1
```

Next, initialise the swap partition.
```shell
mkswap /dev/sda2
```

Finally, format the main partition to the `ext4` file system.
```shell
mkfs.ext4 /dev/sda3
```
## Mounting the file systems
We'll need to do this one out-of-order, starting with `sda3` first. Mount the root volume to the `/mnt` directory.
```shell
mount /dev/sda3 /mnt
```

Create the `/mnt/boot/efi` directory, and mount the boot partition to it.
```shell
mkdir -p /mnt/boot/efi
mount /dev/sda1 /mnt/boot/efi
```

Finally, initialise the swap partition (this does not need to be mounted to a directory).
```shell
swapon /dev/sda2
```

Using `lsblk` again should show that the partitions are now mounted appropriately.
# Installation
## Install essential packages
Use `pacstrap` to install packages in a way that is optimised for a new system installation. The `-K` option here initialises an empty pacman keyring in the target.
```shell
pacstrap -K /mnt base linux linux-firmware
```

As you can see, we have listed `base`, `linux` and `linux-firmware` packages separated by spaces, to show that we want these in our installation. You will also need to append several others to this command, including:
- CPU microcode updates (`amd-ucode` or `intel-ucode`) for hardware bug and security fixes.
- `base-devel` for various important functions, such as the AUR.
- A boot manager such as `grub`, combined with `efibootmgr`.
- A text editor, such as `vim` or `neovim`.
- `iwd` and `networkmanager` for Wi-Fi, as discussed before.
- `sof-firmware` for sound cards.
- Consult the wiki for any other essential packages that may be needed.
# Configuration
## Fstab
An `fstab` (file system tab) file is used to define how disk partitions, or other file systems, should be mounted into the file system. This can be displayed in the terminal.
```shell
genfstab /mnt
```

Redirect this output to the a file in the `/mnt/etc/fstab` directory. `-U` ensures the output uses UUIDs, rather than labels.
```shell
genfstab -U /mnt > /mnt/etc/fstab
```
## Chroot
Enter your new system, by changing root into the `/mnt` directory.
```shell
arch-chroot /mnt
```
## Time
Set the timezone by creating a symlink from the `London` timezone to `/etc/localtime`
```
ln -sf /usr/share/zoneinfo/Europe/London /etc/localtime
```

Run `hwclock` to generate a file in `/etc/adjtime`, to synchronise with the system clock.
```shell
hwclock --systohc
```
## Localisation
To ensure software knows to display British English, you will need to define your locale in **two files**. Open `/etc/locale.gen` in a text editor.
```shell
vim /etc/locale.gen
```

Scroll until you find the following locale, and uncomment it by deleting the proceeding `#`.
```
#en_GB.UTF-8 UTF-8
```

Save the file, and enter the following command.
```shell
locale-gen
```

Some programs, however, will look at `/etc/locale.conf` to find your locale. Enter the following string into the blank document.
```shell
echo "LANG=en_GB.UTF-8" > /etc/locale.conf
```

Finally, edit `etc/vconsole.conf` in order to make your keyboard layout persistent. Set the keyboard using the syntax from the start of the tutorial.
```shell
echo "KEYMAP=uk" > /etc/vconsole.conf
```
## Network configuration
Create the hostname file, for other devices to identify your computer.
```shell
echo "rhT480s" > /etc/hostname
```
## Root password
Set the root password.
```shell
passwd
```
## Adding a user
Before rebooting, it's recommended you configure several more things. Create your personal user with `useradd`, using `-m` to create a home directory and `-G wheel` to add the user to the `wheel` group (explained later).
```shell
useradd -m -G wheel richard
passwd richard
```
## Sudo privileges
To let the new user execute `sudo`-prefixed commands, open the sudoers file.
```shell
EDITOR=vim visudo
```

Scroll down to the following lines and uncomment the second one, allowing users in the `wheel` group to access `sudo` privileges.
```
## Uncomment to allow members of group wheel to execute any command
# %wheel ALL=(ALL) ALL
```
## System services
It seems that the only service needing to be enabled before reboot is `NetworkManager`. 
```
systemctl enable NetworkManager
```
## GRUB setup
Before rebooting the GRUB boot loader must be setup.
```shell
grub-install /dev/sda1
grub-mkconfig -o /boot/grub/grub.cfg
```

Finally, you may exit back to the USB drive, unmount any non-busy drives and reboot the system
```shell
exit
umount -a
reboot
```

## Post install
All done! Now just install the software you want, including:
- A desktop environment, such as `gnome`, or a window manager, such as `i3`.
- A terminal emulator, such as `kitty` or `alacritty`.
- A web browser, such as `firefox`.
- A file manager, such as `thunar`.

After this, start the login manager if you downloaded one.
```shell
sudo systemctl enable --now sddm
```
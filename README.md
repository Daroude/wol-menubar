# wol-menubar

Wake the computers on your home network from the macOS menu bar, with one click.

`wol-menubar` is a small [SwiftBar](https://github.com/swiftbar/SwiftBar) plugin that sends
[Wake-on-LAN](https://en.wikipedia.org/wiki/Wake-on-LAN) magic packets. It also shows which of
your computers are online.

```
🖥  ← green when at least one of your computers is online
├─ Click a computer to wake it
├─ ● gaming-pc        ▸  Online · 192.168.1.26
│                        Wake up
│                        MAC 74:56:3c:xx:xx:xx
│                        Remove
├─ ○ media-server     ▸  Offline · 192.168.1.40
├─────────────
├─ Add computer from network…
├─ Add computer manually…
└─ Edit device list
```

## Features

- **Finds your computers automatically.** *Add computer from network…* lists every device your Mac
  has recently seen on the LAN, with hostname, IP and MAC. Pick one and give it a name.
- **Manual entry** for machines that are switched off right now: you enter a name and MAC address,
  and optionally an IP.
- **Several computers**, each with its own online/offline status (checked by ping every 30 s).
- **Follows DHCP:** when a computer gets a new IP, the stored one is updated from the ARP cache.
- **No dependencies** besides SwiftBar. The magic packet is sent with the Perl that ships with macOS,
  and the dialogs use AppleScript.
- Sends the packet to the broadcast address of every active interface, plus `255.255.255.255`,
  on UDP ports 9 and 7.

## Install

```bash
git clone https://github.com/Daroude/wol-menubar.git ~/wol-menubar
~/wol-menubar/install.sh
```

The installer installs SwiftBar with Homebrew if it is missing. Then it symlinks the plugin into
your SwiftBar plugin folder. To update later:

```bash
cd ~/wol-menubar && git pull
```

Devices are stored in `~/.config/wol-menubar/devices`, one per line: `name|mac|ip`.

## Adding a computer

1. Switch the target computer on, so it appears on the network.
2. Menu bar icon → **Add computer from network…**
3. Pick it from the list. **Choose the wired (Ethernet) entry.** A machine with both Ethernet and
   Wi-Fi shows up twice, and Wake-on-LAN almost never works over Wi-Fi.
4. Give it a name. Done.

If the computer is off, use **Add computer manually…** and type its MAC address instead.

## Setting up Wake-on-LAN on the target computer

The plugin can only send the packet. The target machine has to listen for it. It is not possible
to tell from the network whether that is set up, so check these settings:

**BIOS/UEFI**
- Enable *Wake on LAN* / *Power On By PCI-E* / *Resume by LAN*. The name depends on the vendor.
- Disable *ErP* / *EuP Ready* / *Deep Sleep*. These cut power to the network card when the
  machine is off.

**Linux**
- Check with `sudo ethtool <iface>`. It should show `Wake-on: g`.
- Make it persistent with NetworkManager:
  `nmcli connection modify "<connection>" 802-3-ethernet.wake-on-lan magic`
- Or make it persistent with systemd-networkd: create a `.link` file with `WakeOnLan=magic`.

**Windows**
- Device Manager → network adapter → *Power Management*: allow this device to wake the computer.
- On the *Advanced* tab, enable *Wake on Magic Packet*.
- Consider disabling *Fast Startup*. It can stop the machine from waking from a full shutdown.

## Limitations

- **Local network only.** The Mac and the target have to be in the same LAN/broadcast domain.
  Waking a machine over the internet needs a VPN or a device at home that sends the packet.
- **Encrypted disks:** a machine with full-disk encryption (LUKS, BitLocker with PIN) boots up to
  the passphrase prompt and waits there. It shows as "offline" until someone unlocks it.
- The online status is a simple ping. Computers that block ICMP always show as offline, but can
  still be woken.

## Credits

Written by [Claude](https://claude.ai) (Anthropic) using [Claude Code](https://claude.com/claude-code),
for and together with [@Daroude](https://github.com/Daroude).

MIT licensed. See [LICENSE](LICENSE).

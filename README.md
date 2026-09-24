# WOL Menubar

A tiny native macOS menu bar app that wakes the computers on your home network with
[Wake-on-LAN](https://en.wikipedia.org/wiki/Wake-on-LAN), and shows which of them are online.

<img src="docs/panel.png" width="300" alt="WOL Menubar panel with three computers: one online, one offline with a Wake button, one waking up">

## Features

- **Finds your computers automatically.** *Add Computer… → From Network* lists the devices on your
  LAN with hostname, IP and MAC address. Pick one and you are done.
- **Manual entry** for machines that are switched off right now: you enter a name and MAC address.
- **Several computers**, each with a live status: online, offline, or waking up. The status is
  checked by ping every 30 s, and every 5 s while a machine boots.
- **Follows DHCP:** when a computer gets a new IP address, the app picks it up automatically.
- **Native and lightweight:** SwiftUI with no dependencies, universal binary (Apple Silicon + Intel),
  about 1 MB. Launch at Login is built in.
- Sends the magic packet to the broadcast address of every active interface, plus `255.255.255.255`,
  on UDP ports 9 and 7.

Requires macOS 13 Ventura or later.

## Install

### Download

1. Get `WOL-Menubar-x.y.z.zip` from the [latest release](https://github.com/Daroude/wol-menubar/releases/latest),
   unzip it and move **WOL Menubar.app** to `/Applications`.
2. Open it. The app is open source but not notarized by Apple (that needs a paid developer account),
   so macOS blocks it the first time. Go to **System Settings → Privacy & Security**, scroll down
   and click **Open Anyway**.
   Or clear the download flag in Terminal instead:
   ```bash
   xattr -dr com.apple.quarantine "/Applications/WOL Menubar.app"
   ```
3. When macOS asks whether *WOL Menubar* may find devices on your local network, click **Allow**.

### Build from source

You only need the Xcode Command Line Tools (`xcode-select --install`), not Xcode itself:

```bash
git clone https://github.com/Daroude/wol-menubar.git
cd wol-menubar
scripts/build.sh --install
```

This builds `WOL Menubar.app`, copies it to `/Applications` and starts it. When you build it
yourself, there is no Gatekeeper warning.

## Adding a computer

1. Switch the target computer on, so it appears on the network.
2. Click the menu bar icon → **Add Computer…** → **From Network**.
3. Pick it from the list. **Choose the wired (Ethernet) entry.** A machine with both Ethernet and
   Wi-Fi shows up twice, and Wake-on-LAN almost never works over Wi-Fi.
4. Check the name and click **Add**.

If the computer is off, use the **Manually** tab and type its MAC address instead.

Devices are stored in `~/.config/wol-menubar/devices`, one per line (`name|mac|ip`), so you can
also edit or back up the file by hand.

## Setting up Wake-on-LAN on the target computer

The app can only send the packet. The target machine has to listen for it. It is not possible to
tell from the network whether that is set up, so check these settings:

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
  the passphrase prompt and waits there. It shows as "waking" and then "offline" until someone
  unlocks it.
- The online status is a simple ping. Computers that block ICMP always show as offline, but can
  still be woken.

## Troubleshooting

**"No devices found" when adding a computer.** macOS only shows the LAN's device table to apps with
the *Local Network* permission. Enable **WOL Menubar** under **System Settings → Privacy & Security →
Local Network**, then click *Scan Again*.

**The menu bar icon does not show up.** On a MacBook with a notch, icons that do not fit next to
the notch are hidden behind it. On first launch the app places its icon right of the notch; if it
is still hidden, hold ⌘ and drag other icons away, or turn some off under **System Settings → Menu
Bar**. Clicking the app in Finder while it is already running does nothing visible.

**Diagnostics.** This runs a scan with the app's own permissions, writes a report and quits:

```bash
open -a "WOL Menubar" --env WOL_SELFTEST=$HOME/Desktop/wol-report.txt
```

## Credits

Written by [Claude](https://claude.ai) (Anthropic) using [Claude Code](https://claude.com/claude-code),
for and together with [@Daroude](https://github.com/Daroude).

MIT licensed. See [LICENSE](LICENSE).

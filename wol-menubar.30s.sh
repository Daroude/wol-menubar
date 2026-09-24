#!/bin/bash
# <swiftbar.title>WOL Menubar</swiftbar.title>
# <swiftbar.desc>Wake computers on your local network with Wake-on-LAN, straight from the menu bar.</swiftbar.desc>
# <swiftbar.author.github>Daroude</swiftbar.author.github>
# <swiftbar.abouturl>https://github.com/Daroude/wol-menubar</swiftbar.abouturl>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>

# Devices live in a plain text file, one per line: name|mac|ip
CONFIG_DIR="${WOL_MENUBAR_CONFIG_DIR:-$HOME/.config/wol-menubar}"
CONFIG="$CONFIG_DIR/devices"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# ---------- helpers ----------

notify() { osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1; }

# Normalise a MAC to lower-case aa:bb:cc:dd:ee:ff (arp prints "b0:f2:8:…"); empty if invalid
normalize_mac() {
  local m
  m="$(echo "$1" | tr 'A-Z-' 'a-z:' | tr -d ' ')"
  if [[ "$m" =~ ^[0-9a-f]{12}$ ]]; then m="$(echo "$m" | sed 's/../&:/g; s/:$//')"; fi
  IFS=: read -r -a parts <<<"$m"
  [ "${#parts[@]}" -eq 6 ] || return 0
  local out="" p
  for p in "${parts[@]}"; do
    [[ "$p" =~ ^[0-9a-f]{1,2}$ ]] || return 0
    out+="$(printf '%02s' "$p" | tr ' ' 0):"
  done
  echo "${out%:}"
}

# Current IP for a MAC from the ARP cache (DHCP may have changed it)
ip_for_mac() {
  arp -an 2>/dev/null | while read -r _ ip _ mac _; do
    [ "$(normalize_mac "$mac")" = "$1" ] && { echo "$ip" | tr -d '()'; break; }
  done
}

# Broadcast addresses of all active IPv4 interfaces, plus the limited broadcast
broadcasts() {
  ifconfig 2>/dev/null | awk '/inet .*broadcast/ {print $NF}' | sort -u
  echo 255.255.255.255
}

# Magic packet via Perl (ships with macOS, no developer tools needed)
send_magic() {
  local mac="$1"
  /usr/bin/perl -MSocket -e '
    my $mac = shift; $mac =~ s/://g;
    my $pkt = ("\xff" x 6) . (pack("H12", $mac) x 16);
    socket(my $s, PF_INET, SOCK_DGRAM, getprotobyname("udp")) or die $!;
    setsockopt($s, SOL_SOCKET, SO_BROADCAST, 1) or die $!;
    my $ok = 0;
    for my $a (@ARGV) {
      for my $p (9, 7) { $ok++ if send($s, $pkt, 0, sockaddr_in($p, inet_aton($a))); }
    }
    exit($ok ? 0 : 1);' "$mac" $(broadcasts)
}

# AppleScript dialogs; print the answer, or nothing when cancelled
ask() {
  osascript - "$1" "$2" <<'EOF' 2>/dev/null
on run argv
  set r to display dialog (item 1 of argv) default answer (item 2 of argv) with title "WOL Menubar"
  return text returned of r
end run
EOF
}

choose() { # $1 prompt, rest = entries
  local prompt="$1"; shift
  osascript - "$prompt" "$@" <<'EOF' 2>/dev/null
on run argv
  set r to choose from list (items 2 thru -1 of argv) with prompt (item 1 of argv) with title "WOL Menubar"
  if r is false then return ""
  return item 1 of r
end run
EOF
}

save_device() { # name mac ip
  mkdir -p "$CONFIG_DIR"
  touch "$CONFIG"
  grep -v "|$2|" "$CONFIG" >"$CONFIG.tmp" 2>/dev/null; mv "$CONFIG.tmp" "$CONFIG"
  echo "$1|$2|$3" >>"$CONFIG"
  notify "WOL Menubar" "Added $1 ($2)"
}

clean_name() { echo "$1" | tr -d '|\n' | sed 's/^ *//; s/ *$//'; }

# ---------- actions ----------

case "$1" in
  wake)
    if send_magic "$2"; then
      notify "Waking ${3:-$2}" "Magic packet sent – booting can take a minute."
    else
      notify "WOL Menubar" "Could not send the magic packet. Are you on the local network?"
    fi
    exit 0 ;;

  add-scan)
    # Everything the Mac has recently talked to: "hostname (ip) at mac on enX …"
    own="$(ifconfig | awk '/ether/ {print $2}')"
    entries=()
    seen=" "
    while read -r host ip _ mac _; do
      mac="$(normalize_mac "$mac")"; ip="$(echo "$ip" | tr -d '()')"
      [ -n "$mac" ] || continue
      case "$mac" in ff:ff:ff:ff:ff:ff|01:00:5e:*|33:33:*) continue ;; esac
      grep -qi "$mac" <<<"$own" && continue
      [[ "$seen" == *" $mac "* ]] && continue
      seen+="$mac "
      [ "$host" = "?" ] && host="unknown"
      entries+=("$host — $ip — $mac")
    done < <(arp -a 2>/dev/null | grep -v incomplete)
    if [ "${#entries[@]}" -eq 0 ]; then
      notify "WOL Menubar" "No devices found. Turn the computer on and try again."
      exit 0
    fi
    pick="$(choose "Pick the computer to wake (it must be switched on right now). Prefer its wired (Ethernet) entry – Wake-on-LAN rarely works over Wi-Fi." "${entries[@]}")"
    [ -n "$pick" ] || exit 0
    host="${pick%% — *}"; rest="${pick#* — }"; ip="${rest%% — *}"; mac="${rest##* — }"
    host="${host%%.*}"; [ "$host" = "unknown" ] && host=""
    name="$(clean_name "$(ask "Name for $mac:" "$host")")"
    [ -n "$name" ] || exit 0
    save_device "$name" "$mac" "$ip"
    exit 0 ;;

  add-manual)
    name="$(clean_name "$(ask "Name of the computer:" "")")"
    [ -n "$name" ] || exit 0
    mac="$(normalize_mac "$(ask "MAC address of $name (e.g. aa:bb:cc:dd:ee:ff):" "")")"
    if [ -z "$mac" ]; then notify "WOL Menubar" "That is not a valid MAC address."; exit 0; fi
    ip="$(ask "IP address of $name (optional, used to show whether it is online):" "$(ip_for_mac "$mac")")"
    save_device "$name" "$mac" "$(echo "$ip" | tr -d ' |')"
    exit 0 ;;

  remove)
    grep -v "|$2|" "$CONFIG" >"$CONFIG.tmp"; mv "$CONFIG.tmp" "$CONFIG"
    exit 0 ;;
esac

# ---------- menu ----------

mkdir -p "$CONFIG_DIR" && touch "$CONFIG"   # so "Edit device list" always has a file to open

lines=()
any_online=0
if [ -s "$CONFIG" ]; then
  while IFS='|' read -r name mac ip; do
    [ -n "$mac" ] || continue
    cur="$(ip_for_mac "$mac")"
    if [ -n "$cur" ] && [ "$cur" != "$ip" ]; then  # follow DHCP changes
      sed -i '' "s/^\(.*|$mac|\).*/\1$cur/" "$CONFIG"; ip="$cur"
    fi
    if [ -n "$ip" ] && ping -c1 -t1 "$ip" >/dev/null 2>&1; then
      any_online=1
      lines+=("$name | sfimage=circle.fill sfcolor=#34C759 bash='$SELF' param1=wake param2=$mac param3='$name' terminal=false refresh=true")
      lines+=("--Online · $ip")
    else
      lines+=("$name | sfimage=circle sfcolor=#8E8E93 bash='$SELF' param1=wake param2=$mac param3='$name' terminal=false refresh=true")
      lines+=("--${ip:+Offline · $ip}${ip:-No IP known}")
    fi
    lines+=("--Wake up | sfimage=power bash='$SELF' param1=wake param2=$mac param3='$name' terminal=false refresh=true")
    lines+=("--MAC $mac")
    lines+=("--Remove | sfimage=trash bash='$SELF' param1=remove param2=$mac terminal=false refresh=true")
  done <"$CONFIG"
fi

if [ "$any_online" = 1 ]; then echo ":desktopcomputer: | sfcolor=#34C759"; else echo ":desktopcomputer:"; fi
echo "---"
if [ "${#lines[@]}" -eq 0 ]; then
  echo "No computers yet"
else
  echo "Click a computer to wake it | size=11"
  printf '%s\n' "${lines[@]}"
fi
echo "---"
echo "Add computer from network… | sfimage=magnifyingglass bash='$SELF' param1=add-scan terminal=false refresh=true"
echo "Add computer manually… | sfimage=plus bash='$SELF' param1=add-manual terminal=false refresh=true"
echo "Edit device list | sfimage=doc.text bash=/usr/bin/open param1=-t param2='$CONFIG' terminal=false"

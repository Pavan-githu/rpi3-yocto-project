# RPi3 Yocto IoT Gateway — Changes & Explanation Guide

This document explains every change made to the project, why it was done,
and what effect it has when the image boots on the Raspberry Pi 3 Model B v1.2.

---

## Understanding the Big Picture First

Think of Yocto like a **recipe book for building a custom operating system**.
You write recipes (`.bb` files) that tell the build system what software to
include, how to compile it, and where to place it on the device.
The `local.conf` file is the **master settings file** that controls what the
final image looks like.

---

## Change 1 — Serial Terminal Login Was Not Working

### File: `sources/poky/build/conf/local.conf`

**The Problem:**  
After the Raspberry Pi booted, all the boot messages were visible on the serial
terminal (via USB-to-TTL cable) but a **login prompt never appeared**. The board
just sat silently at the last boot message forever.

**Root Cause — Two mistakes:**

**Mistake 1: Wrong variable name**

```
# WRONG (old, ignored by Yocto)
SERIAL_CONSOLE = "115200 ttyAMA0"

# CORRECT
SERIAL_CONSOLES = "115200;ttyAMA0"
```

Think of `SERIAL_CONSOLES` as the "phone number" for the login service.
The login program (getty) uses this variable to know which serial port to
listen on. Because the name was wrong (`SERIAL_CONSOLE` vs `SERIAL_CONSOLES`),
getty never got the number, so it defaulted to `ttyS0` (the mini UART) instead
of `ttyAMA0` (the PL011 UART — the real hardware serial port on the GPIO pins).

**Mistake 2: Wrong separator**

The format must be `baud_rate;device_name` with a **semicolon**, not a space.

**The Fix:**
```
SERIAL_CONSOLES = "115200;ttyAMA0"
KERNEL_CMDLINE += " console=ttyAMA0,115200 console=tty1"
```

**What this means for you:**
- `ttyAMA0` = the PL011 UART chip connected to GPIO pins 14 (TX) and 15 (RX)
- `115200` = the communication speed (baud rate) — your serial terminal must
  also be set to 115200
- `console=ttyAMA0` in the kernel command tells the Linux kernel to send all
  its boot messages to this serial port
- `console=tty1` = also show messages on the HDMI screen (if connected)

**Effect:** After this fix, the RPi shows the `raspberrypi3 login:` prompt on
the serial terminal.

---

## Change 2 — Root Login Needs a Password Setup

### File: `sources/poky/build/conf/local.conf`

```
INHERIT += "extrausers"
EXTRA_USERS_PARAMS = "usermod -P '' root; usermod -p '' root"
```

**The Problem:**
By default, the root account either has a locked password or a random one,
making it impossible to log in on the serial terminal during development.

**What `extrausers` does:**
It is a Yocto class (a plugin) that allows you to set up user accounts at
**image build time** — so the passwords are already configured when the SD
card is flashed.

**What `usermod -P '' root` does:**
Sets the root password to empty (blank). During development this is convenient
because you just press Enter at the password prompt and you're in.

> **Important:** This is set alongside `debug-tweaks` in
> `EXTRA_IMAGE_FEATURES` which is a development-only mode.
> Before shipping a production device, remove `debug-tweaks` and set a
> real password.

---

## Change 3 — WiFi Was Not Working (No wlan0 Interface)

### File: `sources/poky/build/conf/local.conf`

```
IMAGE_INSTALL:append = " ... kernel-module-brcmfmac kernel-module-brcmutil linux-firmware-rpidistro-bcm43430 ..."
```

**The Problem:**
The RPi3 has a built-in WiFi chip (Broadcom BCM43438). At boot the kernel
detected the SDIO card (`mmc1: new high speed SDIO card`) but the `wlan0`
network interface never appeared. The error was:
```
ip: SIOCGIFFLAGS: No such device
Failed to bring up interface: wlan0
```

**Why it happened:**
The WiFi chip needs two things to work:
1. A **kernel driver** (software that talks to the hardware)
2. A **firmware blob** (binary code that runs inside the WiFi chip itself)

The `meta-raspberrypi` layer lists these as "recommended" packages
(`MACHINE_EXTRA_RRECOMMENDS`) — which means Yocto may or may not include them
depending on the image type. `core-image-minimal` is a stripped-down image
that skipped them.

**The Fix — Three packages added explicitly:**

| Package | What it is |
|---|---|
| `kernel-module-brcmfmac` | The Linux kernel driver for the BCM43430/BCM43438 WiFi chip. Without this, the kernel cannot communicate with the WiFi hardware at all. |
| `kernel-module-brcmutil` | A helper utility module that `brcmfmac` depends on. Like a supporting library. |
| `linux-firmware-rpidistro-bcm43430` | The firmware binary that gets uploaded into the WiFi chip when it initialises. Without this, the driver loads but the chip cannot function — like having a radio with no software inside it. |

**Effect:** After this fix, `wlan0` appears at boot and WiFi setup works.

---

## Change 4 — openssl Binary Was Missing

### File: `sources/poky/build/conf/local.conf`

```
IMAGE_INSTALL:append = " ... openssl ..."
```

**The Problem:**
The application generates HTTPS certificates using the `openssl` command.
At runtime it showed:
```
Command failed with exit code: 32512
Failed to generate Root CA
```

Exit code 32512 = shell error 127 = **command not found**.

**Why it happened:**
`openssl` was listed in the recipe's `RDEPENDS` (runtime dependencies), but
for `core-image-minimal` this soft dependency was not being resolved into an
actual installed package.

**The Fix:**
Adding `openssl` explicitly to `IMAGE_INSTALL` forces Yocto to always include
the `openssl` binary package in the image, no matter what.

**Effect:** The openssl command is available at `/usr/bin/openssl` on the RPi.
The certificate generation succeeds and the HTTPS server starts properly.

---

## Change 5 — systemctl Command Not Found

### File: `sources/poky/build/conf/local.conf`

```
DISTRO_FEATURES:append = " systemd"
VIRTUAL-RUNTIME_init_manager = "systemd"
DISTRO_FEATURES_BACKFILL_CONSIDERED:append = " sysvinit"
VIRTUAL-RUNTIME_initscripts = "systemd-compat-units"
```

**The Problem:**
When trying to enable the Cloudflare tunnel service:
```
root@raspberrypi3:~# systemctl enable --now cloudflared
-sh: systemctl: not found
```

**Why it happened:**
By default, Yocto's `poky` distro uses **SysVinit** as the init system
(the first program that starts when Linux boots and manages all other services).
SysVinit is older and simpler — it uses `service` and `rc` scripts instead of
`systemctl`.

Both the `cloudflared.service` and `iot-gateway.service` files are written for
**systemd** — the modern init system used by almost all current Linux
distributions.

**What these lines mean:**

```
DISTRO_FEATURES:append = " systemd"
```
Tells the entire Yocto build: "Include systemd support everywhere. Any package
that has a systemd option should enable it."

```
VIRTUAL-RUNTIME_init_manager = "systemd"
```
This is like saying "When the RPi boots, use systemd as PID 1 (the first
process)." PID 1 is the parent of all other processes — it starts everything.

```
DISTRO_FEATURES_BACKFILL_CONSIDERED:append = " sysvinit"
```
Yocto has a feature where it "backfills" (automatically adds) features you
didn't explicitly request. This line stops it from sneaking SysVinit back in
automatically.

```
VIRTUAL-RUNTIME_initscripts = "systemd-compat-units"
```
Some packages still have old SysVinit-style startup scripts. This compatibility
layer converts them so they work under systemd too.

**Effect:** After this change, `systemctl` is available on the RPi. Both
`iot-gateway.service` and `cloudflared.service` are managed by systemd,
meaning they auto-start at boot, auto-restart on crash, and their status can
be checked with `systemctl status`.

---

## Change 6 — Cloudflare Tunnel Integration

### New files created:
- `recipes-apps/cloudflared/cloudflared_1.0.bb`
- `recipes-apps/cloudflared/files/cloudflared.service`
- `recipes-apps/cloudflared/files/cloudflared-env`
- `recipes-apps/cloudflared/files/cloudflared-domain`
- `scripts/download-cloudflared.sh`

### Updated: `main.cpp`, `local.conf`

**The Problem to Solve:**
The IoT Gateway HTTPS server runs on `localhost:8443` inside the RPi. To access
it from the internet (e.g. upload firmware remotely), you would normally need:
- A static public IP address (expensive, not always available)
- Router port forwarding (requires access to the router config)
- Opening firewall ports (security risk)

**The Solution — Cloudflare Tunnel:**

```
Your Phone / Browser                Cloudflare Network          Raspberry Pi
─────────────────────  ─────────────────────────────  ─────────────────────────
https://raceiotdevice.cc  ──►  Cloudflare Edge  ◄──  cloudflared daemon
                                                       (outbound connection)
                                                            │
                                                       localhost:8443
                                                       (iot-gateway HTTPS)
```

The `cloudflared` daemon on the RPi makes an **outbound** connection to
Cloudflare (like a phone call that the RPi initiates). No incoming ports need
to be opened. Cloudflare then routes traffic from your public domain through
that connection to your local server.

**File by File:**

---

### `scripts/download-cloudflared.sh`
**Purpose:** Downloads the cloudflared executable for ARM 32-bit (RPi3) from
Cloudflare's GitHub releases page and places it in the recipe's `files/`
directory on the **build server** before `bitbake` runs.

**Why on the build server?** Because Yocto builds the entire image on the
build server. All files must be present there before the build starts. The RPi
never needs to download anything itself.

---

### `cloudflared_1.0.bb` (Yocto Recipe)
**Purpose:** Tells Yocto how to package the cloudflared binary into the image.

Key decisions:
- `do_configure[noexec]` and `do_compile[noexec]` — nothing to compile, it's
  a pre-built binary. Skip those steps.
- `install -m 0600 ... cloudflared-env` — the token file is set to mode 0600
  meaning only root can read it. The tunnel token is a secret credential.
- `SYSTEMD_AUTO_ENABLE = "disable"` — the service does NOT start automatically
  at first boot because the token file is empty until you fill it in.

---

### `cloudflared.service` (systemd service)
**Purpose:** Defines how systemd starts, stops, and monitors the `cloudflared`
daemon.

```ini
After=network.target network-online.target
Wants=network-online.target
```
Wait until the network is fully ready before starting. If cloudflared starts
before the network is up, it cannot reach Cloudflare and fails.

```ini
EnvironmentFile=/etc/cloudflared/env
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate run --token ${CLOUDFLARE_TUNNEL_TOKEN}
```
Read the token from the env file, then start the tunnel. `--no-autoupdate`
prevents cloudflared from trying to update itself (the Yocto filesystem does
not allow that).

```ini
Restart=on-failure
RestartSec=15
StartLimitBurst=5
```
If it crashes (e.g. network dropped), restart after 15 seconds. But if it
fails 5 times in 2 minutes, stop retrying — this prevents an endless crash
loop if the token is wrong.

---

### `cloudflared-env`
**Purpose:** Holds the tunnel token. This is a secret key that proves to
Cloudflare that this RPi is authorised to use your tunnel.

Current state (token already filled in):
```
CLOUDFLARE_TUNNEL_TOKEN=eyJhIjoiY....(your token)
```

This file is baked into the image at build time. You will not need to edit
it on the RPi after flashing.

---

### `cloudflared-domain`
**Purpose:** Holds your public domain name. The `iot-gateway` application
reads this file when it starts and prints your public URL in the serial
terminal.

Current state:
```
https://raceiotdevice.cc/
```

---

### `main.cpp` changes
**Purpose:** Print the Cloudflare public URL in the terminal when the HTTPS
server starts, so you know where to reach it from the internet.

```cpp
std::ifstream cf_conf("/etc/cloudflared/domain");
// reads the domain file, skips comment lines starting with #
// prints: [HTTPS] Public URL: https://raceiotdevice.cc/upload
```

**Terminal output after this change:**
```
[HTTPS] Server running on port 8443
[HTTPS] WiFi URL:   https://192.168.1.42:8443/upload
[HTTPS] Local URL:  https://localhost:8443/upload
[HTTPS] Public URL: https://raceiotdevice.cc/upload   ← new
```

---

## Summary of All Changes

| # | What Changed | Why | Effect on RPi |
|---|---|---|---|
| 1 | `SERIAL_CONSOLES = "115200;ttyAMA0"` | Wrong variable name and separator | Login prompt appears on serial terminal |
| 2 | `EXTRA_USERS_PARAMS` sets blank root password | Root login was blocked | Can log in as root without password |
| 3 | Added `kernel-module-brcmfmac`, `brcmutil`, `bcm43430 firmware` | WiFi driver and firmware were not in minimal image | `wlan0` appears, WiFi works |
| 4 | Added `openssl` to IMAGE_INSTALL | openssl binary not installed despite being in RDEPENDS | Certificate generation works, HTTPS server starts |
| 5 | Added systemd as init manager | Default SysVinit doesn't have systemctl | `systemctl` works, services auto-start at boot |
| 6 | Added cloudflared recipe, service, token, domain | Expose HTTPS server to internet via public domain | `raceiotdevice.cc` routes to RPi's HTTPS server |

---

## How to Activate Cloudflare Tunnel After Flashing

The token is already baked into the image. After booting, on the serial
terminal:

```bash
# Enable and start cloudflared
systemctl enable --now cloudflared

# Check it connected successfully
systemctl status cloudflared
# Should show: Active: active (running)

# Your gateway is now reachable at:
# https://raceiotdevice.cc/upload
```

---

## Repository Structure

```
rpi3project/
├── build/conf/              ← tracked in github.com/Pavan-githu/rpi3-yocto-project
│   ├── local.conf           ← all settings described in this document
│   └── bblayers.conf        ← which Yocto layers are included
├── scripts/
│   └── download-cloudflared.sh  ← run once before bitbake
└── sources/
    └── meta-userapp-package/    ← tracked in github.com/Pavan-githu/meta-userapp-package
        └── recipes-apps/
            ├── iot-gateway/     ← main application
            └── cloudflared/     ← tunnel daemon
```

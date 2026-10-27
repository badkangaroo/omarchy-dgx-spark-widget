# DGX Spark Status Widget

Omarchy bar widget for a [NVIDIA DGX Spark](https://www.nvidia.com/en-us/products/workstations/dgx-spark/).

Plugin id: `alexokita.dgx-spark-widget`  
Display name: **DGX Spark Status Widget**

Reach the Spark over LAN iface, Tailscale, or SSH. Click the bar chip for a pop-out: sign in once with SSH credentials (password is used to install a local key and is not stored), then watch CPU / GPU / MEM sparklines, VRAM, LLM model + tok/s, and iface rates.

> Tested on Omarchy 4.0.6 / Quickshell. Requires network reachability to a DGX Spark. GPU graphs need working SSH after first sign-in (`nvidia-smi` on the Spark).

## Install

```sh
omarchy plugin add https://github.com/badkangaroo/omarchy-dgx-spark-widget.git --enable
omarchy bar put alexokita.dgx-spark-widget --section right
```

Plugins run unsandboxed with your user permissions. This one opens SSH to a machine you configure and stores a dedicated key at `~/.ssh/id_ed25519_dgx_spark`. Read `bin/dgx-spark-status` before you enable it.

Remove with:

```sh
omarchy plugin remove alexokita.dgx-spark-widget
```

## Use

- **Click** the bar chip to open the panel.
- Before SSH is set up: enter **host**, **username**, and **password**, then **Confirm**.
- Host can be a LAN IP, `*.local` mDNS name, or Tailscale MagicDNS / `100.x` address.
- After auth: GPU / CPU / MEM sparklines, VRAM, model name + tok/s (Tensorfold `/health` when present), and local iface UP/DOWN rates.
- **Disconnect SSH** clears the remembered target (the local key file is kept).

## Collector

```sh
bin/dgx-spark-status init-config
bin/dgx-spark-status connect --json
bin/dgx-spark-status status --json
bin/dgx-spark-status auth   # JSON on stdin: {"user","host","password"}
bin/dgx-spark-status auth-status --json
bin/dgx-spark-status logout
```

Config: `~/.config/omarchy/dgx-spark-widget/config.json`  
State: `~/.local/state/omarchy/dgx-spark-widget/`

### Example config

```json
{
  "transport": "auto",
  "iface": "eno1",
  "host": "192.168.1.50",
  "mdnsHost": "spark-xxxx.local",
  "tailscaleHost": "spark-xxxx",
  "tailscaleIp": "100.x.y.z",
  "llmPort": 8888,
  "refresh-related": "set on the bar widget via shell.json"
}
```

`transport: auto` tries iface/LAN HTTP, then Tailscale HTTP, then SSH.

## Services discovered

| Port | What we look for |
|------|------------------|
| `8888` | OpenAI-compatible `/v1/models`, `/health`, `/metrics` (e.g. Tensorfold) |
| `3000` | ComfyUI UI |
| `22` | SSH (device metrics after key auth) |

## Development

```sh
omarchy plugin validate .
omarchy-shell shell rescanPlugins
```

## License

MIT

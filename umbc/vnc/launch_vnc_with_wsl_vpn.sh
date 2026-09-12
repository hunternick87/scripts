#!/usr/bin/env bash
# Launch TurboVNC through an SSH tunnel, optionally bringing up UMBC's VPN
# inside WSL only. The Windows host network is not changed.

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
VPN_HOST="${VPN_HOST:-gpvpn.umbc.edu}"
VPN_TIMEOUT="${VPN_TIMEOUT:-120}"
USE_VPN=true
KEEP_VPN=false
VPN_STARTED=false
VPN_AS_GATEWAY=true
GPCLIENT=""
CLIENT_OPTIONS=()

usage() {
  cat <<'EOF'
Usage: launch_vnc_with_wsl_vpn.sh [options] [user@]server

Options:
  --openbox            Request Openbox instead of IceWM (existing sessions are reused).
  --fresh              Stop your VNC sessions on this host and start a new desktop.
  --no-vpn             Do not start the WSL VPN.
  --keep-vpn           Leave a VPN started by this script connected on exit.
  --vpn-host HOST      Override gpvpn.umbc.edu.
  --vpn-as-gateway     Connect directly to the VPN gateway (default).
  --vpn-as-portal      Use portal discovery instead of direct gateway mode.
  --vpn-timeout SEC    Wait at most SEC seconds for the WSL VPN (default: 120).
  -h, --help           Show this help.

The VPN client runs in your current WSL distribution; it does not install or
connect a VPN on Windows. A Windows TurboVNC viewer may still connect to the
localhost SSH port exposed by WSL.
EOF
}

while (($#)); do
  case "$1" in
    --openbox) CLIENT_OPTIONS+=(--openbox) ;;
    --fresh) CLIENT_OPTIONS+=(--fresh) ;;
    --no-vpn) USE_VPN=false ;;
    --keep-vpn) KEEP_VPN=true ;;
    --vpn-as-gateway) VPN_AS_GATEWAY=true ;;
    --vpn-as-portal) VPN_AS_GATEWAY=false ;;
    --vpn-host) VPN_HOST=${2:?"--vpn-host needs a value"}; shift ;;
    --vpn-timeout) VPN_TIMEOUT=${2:?"--vpn-timeout needs a value"}; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) break ;;
  esac
  shift
done

if (($# != 1)) || [[ ! "$1" =~ ^([[:alnum:]_.-]+@)?[[:alnum:]][[:alnum:]_.-]*$ ]]; then
  usage >&2
  exit 2
fi

if [[ ! -f "$SCRIPT_DIR/launch_client_vnc_wsl_new.sh" ]]; then
  echo "ERROR: Keep launch_client_vnc_wsl_new.sh in the same folder as this script." >&2
  exit 1
fi

if [[ ! "$VPN_TIMEOUT" =~ ^[1-9][0-9]{0,4}$ ]]; then
  echo "ERROR: --vpn-timeout must be a positive integer of at most 99999 seconds." >&2
  exit 2
fi

is_vpn_up() {
  ip -o link show 2>/dev/null | grep -qE ': (tun|gpd|utun)[[:alnum:]_.-]*:'
}

disconnect_vpn() {
  if "$VPN_STARTED" && ! "$KEEP_VPN"; then
    echo "Disconnecting WSL VPN..."
    if ! sudo -n "$GPCLIENT" disconnect >/dev/null 2>&1; then
      echo "Disconnecting requires your WSL sudo password on this computer." >&2
      if [[ -t 0 ]]; then
        sudo "$GPCLIENT" disconnect || \
          echo "Warning: VPN disconnect failed; disconnect it in the VPN terminal." >&2
      else
        echo "Warning: no interactive terminal; disconnect the VPN in its terminal." >&2
      fi
    fi
  fi
}

start_vpn() {
  GPCLIENT=$(command -v gpclient) || {
    echo "ERROR: gpclient is not installed in this WSL distribution." >&2
    exit 1
  }
  GPCLIENT=$(readlink -f "$GPCLIENT")

  if is_vpn_up; then
    echo "A WSL VPN tunnel is already active; reusing it."
    return
  fi

  # Authenticate sudo only in the VPN tab if required. A sudo timestamp in
  # this terminal need not carry over to another terminal.
  local vpn_command=(sudo "$GPCLIENT" connect --browser default)
  if "$VPN_AS_GATEWAY"; then
    vpn_command+=(--as-gateway)
  fi
  vpn_command+=("$VPN_HOST")
  echo "Opening a WSL terminal for UMBC VPN authentication..."
  echo "Enter your credentials and promptly approve the Duo push in that tab."

  if command -v wt.exe >/dev/null 2>&1 && [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
    wt.exe new-tab --title "UMBC VPN (WSL)" -- wsl.exe -d "$WSL_DISTRO_NAME" -u "$(id -un)" -- "${vpn_command[@]}" >/dev/null 2>&1 &
  elif command -v wt.exe >/dev/null 2>&1; then
    wt.exe new-tab -- wsl.exe -- "${vpn_command[@]}" >/dev/null 2>&1 &
  else
    echo "Windows Terminal was not found. Run this in another WSL terminal:" >&2
    printf '  %q' "${vpn_command[@]}" >&2
    printf '\n' >&2
  fi

  printf 'Waiting for the WSL VPN tunnel'
  local attempt
  for ((attempt = 1; attempt <= VPN_TIMEOUT; attempt++)); do
    sleep 1
    printf '.'
    if is_vpn_up; then
      printf '\nWSL VPN connected.\n'
      VPN_STARTED=true
      return
    fi
  done
  printf '\nERROR: no WSL VPN interface appeared within %s seconds.\n' "$VPN_TIMEOUT" >&2
  echo "Check the UMBC VPN terminal for a login or connection error." >&2
  exit 1
}

trap disconnect_vpn EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if "$USE_VPN"; then
  start_vpn
fi

# The child script owns the SSH tunnel and closes it when TurboVNC exits. Do
# not exec it: this wrapper must remain alive so its EXIT trap can disconnect
# the VPN that it started.
bash "$SCRIPT_DIR/launch_client_vnc_wsl_new.sh" "${CLIENT_OPTIONS[@]}" "$@"

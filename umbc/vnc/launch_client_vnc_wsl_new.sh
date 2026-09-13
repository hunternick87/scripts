#!/bin/bash
#
# Original script by Ryan Robucci @ UMBC
# Updated for WSL support, SSH connection reuse, and error checking.
#
# VNC Client Launcher - WSL/Linux compatible version
# Supports: TurboVNC on Linux, TurboVNC installed on Windows (called from WSL),
#           and TigerVNC on Linux.

set -Eeuo pipefail

script_path="/umbc/software/scripts/vnc/server-user/scripts"
desktop=icewm
fresh=false
kill_vnc=false
usage() {
  echo "Usage: $0 [--openbox] [--fresh | --kill-vnc] [user@]server"
  echo "  --openbox  Request Openbox instead of IceWM."
  echo "  --fresh    Stop your VNC sessions on this host before starting a new desktop."
  echo "  --kill-vnc Stop your VNC sessions and exit without opening a viewer."
  echo "Without --fresh or --kill-vnc, existing sessions are reused."
}
while (($#)); do
  case "$1" in
    --openbox) desktop=openbox ;;
    --fresh) fresh=true ;;
    --kill-vnc) kill_vnc=true ;;
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
ssh_target=$1
if "$fresh" && "$kill_vnc"; then
  echo "ERROR: Choose either --fresh or --kill-vnc, not both." >&2
  exit 2
fi

# Stop-only mode does not require a viewer installation.
if ! "$kill_vnc"; then
# --- Locate vncviewer ---
vncpath=""
vncviewer_cmd="${VNCVIEWER:-}"

# Check native Linux paths first (also valid in WSL if TurboVNC is installed there)
if [[ -n "$vncviewer_cmd" ]]; then
  if [[ ! -f "$vncviewer_cmd" ]]; then
    echo "ERROR: VNCVIEWER must name an existing viewer file." >&2
    exit 1
  fi
elif test -x /opt/TurboVNC/bin/vncviewer; then
  vncpath=/opt/TurboVNC
  vncviewer_cmd="${vncpath}/bin/vncviewer"
elif test -x /umbc/software/TurboVNC/bin/vncviewer; then
  vncpath=/umbc/software/TurboVNC
  vncviewer_cmd="${vncpath}/bin/vncviewer"
elif test -f /usr/bin/vncviewer; then
  vncpath=/usr
  vncviewer_cmd="${vncpath}/bin/vncviewer"
fi

# If running inside WSL and nothing found above, look for Windows TurboVNC
# Prefer .exe over .bat to avoid "Terminate batch job" CMD.exe prompt
if [[ "$vncviewer_cmd" == "" ]] && grep -qi microsoft /proc/version 2>/dev/null; then
  echo "Native TurboVNC not found. Checking Windows install paths (WSL mode)..."

  WIN_PATHS=(
    "/mnt/c/Program Files/TurboVNC/vncviewer.exe"
    "/mnt/c/Program Files (x86)/TurboVNC/vncviewer.exe"
    "/mnt/c/Program Files/TurboVNC/vncviewerw.exe"
    "/mnt/c/Program Files/TurboVNC/vncviewer.bat"
    "/mnt/c/Program Files (x86)/TurboVNC/vncviewer.bat"
    "/mnt/c/Program Files/TurboVNC/vncviewerw.bat"
  )
  for p in "${WIN_PATHS[@]}"; do
    if test -f "$p"; then
      vncviewer_cmd="$p"
      echo "Found Windows TurboVNC at: $p"
      break
    fi
  done
fi

if [[ "$vncviewer_cmd" == "" ]]; then
  echo "ERROR: No vncviewer found. Please install TurboVNC."
  echo "  Windows: https://sourceforge.net/projects/turbovnc/"
  echo "  Linux:   sudo apt install turbovnc  OR  download from above"
  exit 1
else
  echo "Using vncviewer: $vncviewer_cmd"
fi

fi

# Reuse one authenticated SSH connection for setup and forwarding.
temp_dir=$(mktemp -d)
control_file="$temp_dir/ssh"
cleanup() {
  local status=$?
  trap - EXIT
  ssh -S "$control_file" -O exit "$ssh_target" >/dev/null 2>&1 || true
  rm -f -- "$control_file"
  rmdir -- "$temp_dir" 2>/dev/null || true
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
echo "Connecting to $ssh_target..."
if ! ssh -S "$control_file" -M -o ControlPersist=no -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -fN "$ssh_target"; then
  echo "ERROR: SSH authentication or connection failed." >&2
  exit 1
fi
if "$fresh" || "$kill_vnc"; then
  # Run as the SSH user. TurboVNC -list consults that user's session records;
  # never use sudo, global process matching, or another user's display list.
  if ! ssh -S "$control_file" -o BatchMode=yes "$ssh_target" 'bash -s' <<'REMOTE_FRESH'
set -Eeuo pipefail
vncserver=/umbc/software/TurboVNC/bin/vncserver
list_displays() {
  local listing line number
  listing=$("$vncserver" -list) || {
    echo "ERROR: Could not list your TurboVNC sessions." >&2
    return 1
  }
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*: ]]; then
      if [[ ! "$line" =~ ^[[:space:]]*:([0-9]{1,5})[[:space:]] ]]; then
        echo "ERROR: Invalid display in TurboVNC session list; restart cancelled." >&2
        return 1
      fi
      number=$((10#${BASH_REMATCH[1]}))
      if ((number > 59635)); then
        echo "ERROR: TurboVNC display is outside the valid port range." >&2
        return 1
      fi
      printf ':%d\n' "$number"
    fi
  done <<< "$listing"
}
# Validate the entire list before stopping anything.
displays=$(list_displays)
if [[ -n "$displays" ]]; then
  stop_failed=false
  while IFS= read -r display; do
    echo "Existing VNC session found on $display."
    echo "Stopping VNC session $display..."
    "$vncserver" -kill "$display" || {
      echo "ERROR: Could not stop $display; continuing with other listed sessions." >&2
      stop_failed=true
    }
  done <<< "$displays"
  remaining=$(list_displays)
  if [[ -n "$remaining" ]]; then
    # TurboVNC may report success even when Xvnc ignored its TERM signal.
    # Re-read the session PID, then independently verify ownership, executable
    # name and display before escalating. Never trust a stale PID by itself.
    while IFS= read -r display; do
      listing=$("$vncserver" -list)
      pid=$(awk -v display="$display" '$1 == display {print $2}' <<< "$listing")
      if [[ ! "$pid" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: No unambiguous PID for $display; refusing a forced stop." >&2
        exit 1
      fi
      identity=$(ps -p "$pid" -o uid= -o comm= -o args=) || {
        echo "ERROR: Could not verify PID $pid; retry cleanup if it has exited." >&2
        exit 1
      }
      read -r process_uid process_name process_args <<< "$identity"
      if [[ "$process_uid" != "$(id -u)" || "$process_name" != Xvnc ]] ||
         [[ ! " $process_args " =~ [[:space:]]${display}[[:space:]] ]]; then
        echo "ERROR: PID $pid does not match your Xvnc session $display; refusing a forced stop." >&2
        exit 1
      fi
      echo "Session $display did not stop normally; force-stopping your Xvnc PID $pid..."
      kill -KILL -- "$pid" || {
        echo "ERROR: Could not force-stop PID $pid." >&2
        exit 1
      }
      # Allow process exit before asking TurboVNC to remove its PID/socket files.
      stopped=false
      for ((attempt = 0; attempt < 20; attempt++)); do
        state=$(ps -p "$pid" -o stat=) || state=""
        if [[ -z "$state" || "$state" == *Z* ]]; then
          stopped=true
          break
        fi
        sleep 0.1
      done
      if ! "$stopped"; then
        echo "ERROR: PID $pid is still present after SIGKILL; cleanup aborted." >&2
        exit 1
      fi
      "$vncserver" -kill "$display" || {
        echo "ERROR: Process stopped, but TurboVNC could not clean up $display." >&2
        exit 1
      }
    done <<< "$remaining"
    remaining=$(list_displays)
    if [[ -n "$remaining" ]]; then
      echo "ERROR: VNC sessions still remain:" >&2
      printf '%s\n' "$remaining" >&2
      exit 1
    fi
    stop_failed=false
  fi
  if "$stop_failed"; then
    exit 1
  fi

else
  echo "No existing sessions were found in your TurboVNC session list."
fi
REMOTE_FRESH
  then
    echo "ERROR: VNC cleanup failed; no new desktop was requested." >&2
    exit 1
  fi
  if "$kill_vnc"; then
    echo "VNC cleanup complete. No desktop or viewer will be started."
    exit 0
  fi
  echo "Starting new UMBC $desktop VNC session..."
else
  echo "Requesting UMBC $desktop TurboVNC session (existing sessions are reused)..."
fi
if ! ssh -S "$control_file" -o BatchMode=yes "$ssh_target" "$script_path/launch_vncserver_${desktop}.sh"; then
  echo "ERROR: The remote $desktop session launcher failed." >&2
  exit 1
fi

if ! display_response=$(ssh -S "$control_file" -o BatchMode=yes "$ssh_target" "$script_path/list_first_vnc_server.sh"); then
  echo "ERROR: Could not query the remote VNC display." >&2
  exit 1
fi
# Accept a number or :number surrounded by whitespace, never digits extracted
# from arbitrary error text. Convert leading zeroes as decimal, not octal.
if [[ ! "$display_response" =~ ^[[:space:]]*:?[0-9]{1,5}[[:space:]]*$ ]]; then
  echo "ERROR: The remote display helper returned an empty or invalid display." >&2
  exit 1
fi
display_digits=${display_response//[[:space:]]/}
display_digits=${display_digits#:}
display=$((10#$display_digits))
if ((display > 59635)); then
  echo "ERROR: Remote VNC display is outside the valid TCP port range." >&2
  exit 1
fi
printf -v display_padded '%02d' "$display"
if ! password=$(ssh -S "$control_file" -o BatchMode=yes "$ssh_target" "$script_path/get_vncpasswd.sh :$display_padded"); then
  echo "ERROR: Could not obtain the remote VNC password." >&2
  exit 1
fi
# Match the working Linux launcher's whitespace normalization.
password=${password//[[:space:]]/}
if [[ -z "$password" || "$password" == *[[:cntrl:]]* ]]; then
  echo "ERROR: The remote password helper returned an empty or invalid password." >&2
  exit 1
fi
remote_port=$((5900 + display))
local_port=$remote_port
# Choose an unused local port without terminating any existing processes.
if command -v ss >/dev/null 2>&1; then
  listeners=$(ss -ltnH)
  while awk '{print $4}' <<< "$listeners" | grep -qE ":${local_port}$"; do
    local_port=$((local_port + 1))
    if ((local_port > 65535)); then
      echo "ERROR: No available local port in the range $remote_port-65535." >&2
      exit 1
    fi
  done
fi
echo "Using Display: $display (remote port $remote_port, local port $local_port)"
# SSH catches bind failures, including races after checking the local ports.
if ! ssh -S "$control_file" -O forward -o ExitOnForwardFailure=yes -L "127.0.0.1:${local_port}:localhost:${remote_port}" "$ssh_target"; then
  echo "ERROR: Could not forward local port $local_port. It may already be in use." >&2
  exit 1
fi
echo "SSH tunnel established on localhost:$local_port."
# AutoPass reads from stdin, avoiding shell quoting and password log leaks.
if [[ "$vncviewer_cmd" == *.exe ]]; then
  echo "Launching Windows TurboVNC..."
  (cd /mnt/c && "$vncviewer_cmd" "localhost::${local_port}" -autopass <<< "$password")
elif [[ "$vncviewer_cmd" == *.bat ]]; then
  vncviewer_win=$(wslpath -w "$vncviewer_cmd")
  vncviewer_win=${vncviewer_win//\'/\'\'}
  echo "Launching Windows TurboVNC..."
  # PowerShell handles WSL-to-CMD quoting; a Windows cwd avoids UNC warnings.
  (cd /mnt/c && powershell.exe -NoProfile -NonInteractive -Command \
    "& '$vncviewer_win' 'localhost::${local_port}' '-autopass'; exit \$LASTEXITCODE" <<< "$password")
elif [[ "$(readlink -f "$vncviewer_cmd")" == *"xtigervncviewer"* ]]; then
  echo "Launching TigerVNC..."
  VNC_PASSWORD=$password "$vncviewer_cmd" "localhost::${local_port}"
else
  echo "Launching TurboVNC..."
  "$vncviewer_cmd" "localhost::${local_port}" -autopass <<< "$password"
fi
echo "Viewer closed."

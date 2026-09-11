#!/usr/bin/env bash
# Fetch and run the current shared scripts inside WSL.
set -Eeuo pipefail

# Only this small launcher needs to be kept locally.
DOWNLOAD_URL="${VNC_UPDATE_URL:-https://raw.githubusercontent.com/hunternick87/scripts/main/umbc/vnc}"

if [[ -z "$DOWNLOAD_URL" ]]; then
  echo "ERROR: No update URL configured. Set DOWNLOAD_URL in this script or VNC_UPDATE_URL." >&2
  exit 2
fi
if [[ "$DOWNLOAD_URL" != https://* ]]; then
  echo "ERROR: The update URL must use HTTPS." >&2
  exit 2
fi
for dependency in curl; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    echo "ERROR: Install $dependency in WSL before running this launcher." >&2
    exit 1
  fi
done

work_dir=$(mktemp -d)
cleanup() {
  local status=$?
  trap - EXIT
  rm -f -- "$work_dir/launch_vnc_with_wsl_vpn.sh" "$work_dir/launch_client_vnc_wsl_new.sh"
  rmdir -- "$work_dir" 2>/dev/null || true
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Fetching the latest VNC scripts..."
for script in launch_vnc_with_wsl_vpn.sh launch_client_vnc_wsl_new.sh; do
  if ! curl --fail --silent --show-error --location \
      --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 90 \
      -H 'Cache-Control: no-cache' --output "$work_dir/$script" "${DOWNLOAD_URL%/}/$script"; then
    echo "ERROR: Could not fetch $script; no launcher was started." >&2
    exit 1
  fi
  if [[ ! -s "$work_dir/$script" ]] || ! bash -n "$work_dir/$script"; then
    echo "ERROR: The server returned an empty or invalid script: $script" >&2
    exit 1
  fi
done

# Keep this process alive so downloads are removed after the viewer/VPN closes.
bash "$work_dir/launch_vnc_with_wsl_vpn.sh" "$@"

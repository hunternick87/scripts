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
# TLS chain repair (see prepare_vpn_ca_bundle). VPN_SYSTEM_CA_FILE and
# VPN_TLS_PORT are optional overrides; the defaults suit Ubuntu/Debian WSL.
VPN_TLS_PORT="${VPN_TLS_PORT:-443}"
SYSTEM_CA_FILE="${VPN_SYSTEM_CA_FILE:-}"
MAX_AIA_FETCHES=4
CERT_DIR=""
VPN_CA_BUNDLE=""

usage() {
  cat <<'EOF'
Usage: launch_vnc_with_wsl_vpn.sh [options] [user@]server

Options:
  --openbox            Request Openbox instead of IceWM (existing sessions are reused).
  --fresh              Stop your VNC sessions on this host and start a new desktop.
  --kill-vnc           Stop your VNC sessions and exit without starting a desktop.
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

If the VPN server omits an intermediate TLS certificate, the missing issuer is
fetched from the server certificate's AIA "CA Issuers" URL, verified against
your system's trusted roots and the VPN hostname, and given to gpclient in a
temporary CA bundle. Any other certificate problem stops the launch.
EOF
}

while (($#)); do
  case "$1" in
    --openbox) CLIENT_OPTIONS+=(--openbox) ;;
    --fresh) CLIENT_OPTIONS+=(--fresh) ;;
    --kill-vnc) CLIENT_OPTIONS+=(--kill-vnc) ;;
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

cleanup_cert_dir() {
  [[ -n "$CERT_DIR" && -d "$CERT_DIR" ]] || return 0
  if [[ -n "$VPN_CA_BUNDLE" ]] && "$VPN_STARTED" && "$KEEP_VPN"; then
    # gpclient may re-read the bundle when it reconnects.
    echo "Keeping the VPN CA bundle for the still-connected VPN: $CERT_DIR"
    return 0
  fi
  rm -rf -- "$CERT_DIR"
  CERT_DIR=""
}

on_exit() {
  disconnect_vpn
  cleanup_cert_dir
}

find_system_ca_file() {
  local candidate
  if [[ -n "$SYSTEM_CA_FILE" ]]; then
    [[ -f "$SYSTEM_CA_FILE" && -r "$SYSTEM_CA_FILE" ]] || return 1
    printf '%s\n' "$SYSTEM_CA_FILE"
    return 0
  fi
  for candidate in /etc/ssl/certs/ca-certificates.crt \
      /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/ca-bundle.pem /etc/ssl/cert.pem; do
    if [[ -f "$candidate" && -r "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# tls_probe CA_FILE OUTPUT: handshake with the VPN server, checking the chain
# and hostname against CA_FILE. Prints OpenSSL's verify code (0 = trusted),
# or nothing if no handshake took place.
tls_probe() {
  timeout 20 openssl s_client -connect "$VPN_HOST:$VPN_TLS_PORT" \
    -servername "$VPN_HOST" -verify_hostname "$VPN_HOST" \
    -CAfile "$1" -no-CApath -showcerts </dev/null >"$2" 2>&1 || true
  sed -n 's/^[[:space:]]*Verify return code: \([0-9][0-9]*\).*/\1/p' "$2" | tail -n 1
}

# Copy every PEM certificate block from $1 into $2 (nothing else).
pem_blocks() {
  awk '/-----BEGIN CERTIFICATE-----/ {p = 1} p {print} /-----END CERTIFICATE-----/ {p = 0}' "$1" >"$2"
}

# The first "CA Issuers - URI:" in the certificate's AIA extension.
aia_issuer_url() {
  openssl x509 -in "$1" -noout -text 2>/dev/null |
    sed -n 's/^[[:space:]]*CA Issuers - URI:\(.*\)$/\1/p' | head -n 1
}

# AIA files are DER (most common), PEM, or a PKCS#7 bundle (.p7c).
to_pem() {
  local in=$1 out=$2 form
  for form in DER PEM; do
    if openssl x509 -inform "$form" -in "$in" -out "$out" 2>/dev/null && [[ -s "$out" ]]; then
      return 0
    fi
  done
  for form in DER PEM; do
    if openssl pkcs7 -inform "$form" -in "$in" -print_certs -out "$out.p7" 2>/dev/null; then
      pem_blocks "$out.p7" "$out"
      [[ -s "$out" ]] && return 0
    fi
  done
  return 1
}

# Mirror Windows' AIA chasing: when the VPN server sends an incomplete chain,
# download the missing issuer(s) named in the certificates, then accept them
# only if the full chain and hostname verify against the system's trusted
# roots. On success VPN_CA_BUNDLE names a temporary bundle for gpclient;
# when no repair is needed it stays empty. Any doubt aborts the launch.
prepare_vpn_ca_bundle() {
  local system_ca code reason dir leaf untrusted fetched url fetch
  local -a seen_urls=()
  local url_re='^https?://[^][:space:][:cntrl:]"\\<>`{}|^]+$'

  if ! command -v openssl >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 ||
      ! command -v timeout >/dev/null 2>&1; then
    echo "Warning: openssl, curl or timeout is missing; skipping the TLS chain check." >&2
    echo "         (gpclient still verifies the server itself.)" >&2
    return 0
  fi
  if ! system_ca=$(find_system_ca_file); then
    echo "ERROR: no readable system CA bundle found${SYSTEM_CA_FILE:+ at $SYSTEM_CA_FILE}." >&2
    echo "Install ca-certificates in WSL (sudo apt-get install ca-certificates)." >&2
    exit 1
  fi

  CERT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/umbc-vpn-ca.XXXXXXXX")
  dir=$CERT_DIR
  chmod 700 -- "$dir"

  echo "Checking the TLS certificate of $VPN_HOST..."
  code=$(tls_probe "$system_ca" "$dir/probe.txt")
  case "$code" in
    0)
      echo "The VPN server certificate verified normally."
      return 0
      ;;
    20|21)
      echo "$VPN_HOST sent an incomplete certificate chain; looking up the missing issuer (AIA)..."
      ;;
    "")
      echo "Warning: could not reach $VPN_HOST:$VPN_TLS_PORT to pre-check its certificate." >&2
      echo "         Continuing; gpclient will verify the server itself." >&2
      return 0
      ;;
    *)
      reason=$(sed -n 's/^[[:space:]]*Verify return code: [0-9]* (\(.*\))$/\1/p' "$dir/probe.txt" | tail -n 1)
      echo "ERROR: the certificate of $VPN_HOST failed verification: ${reason:-code $code}." >&2
      echo "Not connecting. This is not a missing-intermediate problem that can be repaired." >&2
      exit 1
      ;;
  esac

  # Everything the server sent is untrusted; the leaf is its first certificate.
  untrusted="$dir/untrusted.pem"
  leaf="$dir/leaf.pem"
  pem_blocks "$dir/probe.txt" "$untrusted"
  if ! openssl x509 -in "$untrusted" -out "$leaf" 2>/dev/null; then
    echo "ERROR: could not read the certificate sent by $VPN_HOST." >&2
    exit 1
  fi
  : >"$dir/intermediates.pem"

  fetched=$leaf
  for ((fetch = 1; fetch <= MAX_AIA_FETCHES; fetch++)); do
    url=$(aia_issuer_url "$fetched")
    if [[ -z "$url" ]]; then
      if ((fetch == 1)); then
        echo "ERROR: the certificate chain is incomplete and names no CA Issuers (AIA) URL." >&2
      else
        echo "ERROR: the downloaded certificates do not lead to a root trusted by this system:" >&2
        sed 's/^/  /' "$dir/verify.txt" >&2
      fi
      exit 1
    fi
    # Only plain http(s) URLs. AIA is normally plain HTTP; that is safe because
    # the download is trusted only after it verifies against the system roots.
    if [[ ! "$url" =~ $url_re || ${#url} -gt 2048 ]]; then
      echo "ERROR: refusing an unusual AIA URL: $url" >&2
      exit 1
    fi
    if [[ " ${seen_urls[*]-} " == *" $url "* ]]; then
      echo "ERROR: the AIA URLs form a loop ($url)." >&2
      exit 1
    fi
    seen_urls+=("$url")

    echo "Downloading issuer certificate: $url"
    if ! curl --fail --silent --show-error --location \
        --proto '=http,https' --proto-redir '=http,https' --max-redirs 3 \
        --connect-timeout 10 --max-time 30 --max-filesize 1048576 \
        --output "$dir/issuer$fetch.raw" -- "$url"; then
      echo "ERROR: could not download the missing intermediate certificate." >&2
      exit 1
    fi
    if ! to_pem "$dir/issuer$fetch.raw" "$dir/issuer$fetch.pem"; then
      echo "ERROR: the downloaded file is not a certificate." >&2
      exit 1
    fi
    cat -- "$dir/issuer$fetch.pem" >>"$untrusted"
    cat -- "$dir/issuer$fetch.pem" >>"$dir/intermediates.pem"

    # Downloads go in -untrusted: they can only complete a path that ends at
    # a root already in the system store; they are never trust anchors here.
    if openssl verify -CAfile "$system_ca" -no-CApath -untrusted "$untrusted" \
        -purpose sslserver -verify_hostname "$VPN_HOST" "$leaf" >"$dir/verify.txt" 2>&1; then
      break
    fi
    if ((fetch == MAX_AIA_FETCHES)); then
      echo "ERROR: the downloaded certificates do not complete a trusted chain for $VPN_HOST:" >&2
      sed 's/^/  /' "$dir/verify.txt" >&2
      exit 1
    fi
    # Stop early on anything other than a still-missing issuer.
    if ! grep -qE 'error (2|20|21) at' "$dir/verify.txt"; then
      echo "ERROR: the downloaded certificate did not verify for $VPN_HOST:" >&2
      sed 's/^/  /' "$dir/verify.txt" >&2
      exit 1
    fi
    # Follow the AIA of the last certificate we downloaded.
    openssl x509 -in "$dir/issuer$fetch.pem" -out "$dir/next.pem" 2>/dev/null
    fetched="$dir/next.pem"
  done

  (umask 077 && cat -- "$system_ca" "$dir/intermediates.pem" >"$dir/ca-bundle.pem")

  # Final check: a live handshake with the server, chain and hostname, using
  # exactly the bundle gpclient will get.
  code=$(tls_probe "$dir/ca-bundle.pem" "$dir/probe2.txt")
  if [[ "$code" != 0 ]]; then
    echo "ERROR: $VPN_HOST still fails verification with the repaired chain (code ${code:-none})." >&2
    exit 1
  fi
  VPN_CA_BUNDLE="$dir/ca-bundle.pem"
  echo "Verified the repaired certificate chain for $VPN_HOST."
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

  prepare_vpn_ca_bundle

  # Authenticate sudo only in the VPN tab if required. A sudo timestamp in
  # this terminal need not carry over to another terminal. sudo refuses
  # "sudo SSL_CERT_FILE=...", so the bundle is passed through env(1).
  local vpn_command=(sudo)
  if [[ -n "$VPN_CA_BUNDLE" ]]; then
    vpn_command+=(env "SSL_CERT_FILE=$VPN_CA_BUNDLE")
  fi
  vpn_command+=("$GPCLIENT" connect --browser default)
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

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if "$USE_VPN"; then
  start_vpn
fi

# The child script owns the SSH tunnel and closes it when TurboVNC exits. Do
# not exec it: this wrapper must remain alive so its EXIT trap can disconnect
# the VPN that it started.
bash "$SCRIPT_DIR/launch_client_vnc_wsl_new.sh" "${CLIENT_OPTIONS[@]}" "$@"

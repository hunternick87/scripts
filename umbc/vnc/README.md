# UMBC VNC launcher for WSL

Keep `launch_vnc_with_wsl_vpn.sh` and `launch_client_vnc_wsl_new.sh` together.
Run from a WSL Bash terminal:

```bash
bash launch_vnc_with_wsl_vpn.sh YOUR_UMBC_USERNAME@YOUR_LAB_HOST
```

Use the lab hostname assigned or approved for your course. Direct VPN gateway
mode is the default. Use `--vpn-as-portal` if your VPN requires portal discovery.
Use `--no-vpn` when VPN setup is unnecessary, or `--keep-vpn` to leave a VPN
started by the launcher connected after the viewer closes.

IceWM is the default desktop. Request Openbox with:

```bash
bash launch_vnc_with_wsl_vpn.sh --openbox YOUR_UMBC_USERNAME@YOUR_LAB_HOST
```

Both server launchers reuse an existing VNC session, regardless of its desktop.
`--openbox` does not replace an already-running IceWM desktop or terminate it.
The client helper also accepts `--openbox` when run directly.

## Requirements

- A working WSL distribution with Bash, OpenSSH client, sudo, iproute2, and gpclient.
- gpclient must support `connect --browser default --as-gateway`.
- TurboVNC Viewer installed on Windows in a standard Program Files location,
  or a compatible native TurboVNC installation.
- Windows executable interoperability and Windows-to-WSL localhost forwarding
  must work. Windows Terminal is used to open the VPN authentication tab; if it
  is unavailable, follow the printed command in another WSL terminal.
- Your own UMBC credentials, Duo authentication, and access to the lab host.

## Automatic updates

Save `launch_vnc_latest.sh` once, then run it from WSL:

```bash
bash launch_vnc_latest.sh --openbox YOUR_UMBC_USERNAME@YOUR_LAB_HOST
```

It fetches the current two raw shell scripts from
`https://raw.githubusercontent.com/hunternick87/scripts/main/umbc/vnc`
on every run. They execute locally in WSL, with all options passed through.
Temporary copies let the wrapper call its helper by filename; those copies are
removed after the viewer and VPN close. No ZIP or permanent local copies of
the two implementation scripts are needed. `curl` and Internet access before
VPN setup are required.

To publish updates, commit the changed scripts together to `main` under
`umbc/vnc/`. GitHub caching can delay when an update becomes visible.
`VNC_UPDATE_URL` can override the HTTPS folder URL for testing or another host.
Recipients must trust the repository owner, since its scripts execute on their
computer. The GitHub owner and repository name are visible in the launcher.

For a custom viewer installation, set `VNCVIEWER` to its full WSL path:

```bash
VNCVIEWER='/mnt/c/path/to/TurboVNC/vncviewer.bat' bash launch_vnc_with_wsl_vpn.sh YOUR_UMBC_USERNAME@YOUR_LAB_HOST
```

Files copied through Windows do not need executable permissions when launched
with `bash` as above. Preserve Unix (LF) line endings.

## Sudo and authentication

The scripts work with ordinary sudo permissions. You may be prompted for your
own WSL password in the VPN tab and again when disconnecting. Passwordless sudo
is a separate, machine-local configuration; sharing these files does not copy
it or change anyone's sudo permissions. UMBC and Duo authentication still apply.

## Remote desktop setup

The client uses UMBC's desktop helpers in
`/umbc/software/scripts/vnc/server-user/scripts`:

1. `launch_vncserver_icewm.sh` (default) or `launch_vncserver_openbox.sh`
   (`--openbox`) starts or reuses the desktop.
2. `list_first_vnc_server.sh` identifies the display.
3. `get_vncpasswd.sh` supplies its VNC password.

This bypasses the MATE setup helper. The selected lab host must have these
scripts and a working selected desktop/TurboVNC installation. Local checks use simulated
SSH responses; a live desktop connection still needs verification.

## Sharing and privacy

Share the small `launch_vnc_latest.sh` launcher for automatic updates, or the two
implementation scripts and this README for a fixed local copy. They contain no
UMBC login, password, SSH key, VPN cookie, or personal home directory. Each
recipient supplies their own login and host. The updater includes the public
GitHub repository URL, and the original script author's attribution is retained.

Do not bundle terminal logs, SSH configuration, VPN/browser data, or your whole
project folder. Runtime output contains the login and host supplied by the user;
redact those before posting logs. Shell tracing (`bash -x`) can expose passwords.

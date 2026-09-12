Make sure you have WSL installed on your pc
Also make sure you have TurboVNC installed on your **Windows** machine

Install WSL
https://learn.microsoft.com/en-us/windows/wsl/install

Install TurboVNC
https://sourceforge.net/projects/turbovnc/

In WSL

download script
```
wget https://raw.githubusercontent.com/hunternick87/scripts/refs/heads/main/umbc/vnc/launch_vnc_latest.sh
```

run these commands
```
sudo add-apt-repository ppa:yuezk/globalprotect-openconnect
```
```
sudo apt-get update
```
```
sudo apt-get install globalprotect-openconnect
```
then you can run the script
```
./launch_vnc_latest.sh username@domain
```
When it asks for your sudo password its the password for your wsl. 
The login when its a username then password is your UMBC login that you use for the VPN.


Fresh desktop (ends all of your existing VNC sessions on the selected host):
```bash
bash launch_vnc_latest.sh --fresh username@domain
bash launch_vnc_latest.sh --fresh --openbox username@domain
```
IceWM remains the default. Without `--fresh`, an existing session is reused.
`--fresh` stops each session listed for your SSH account with TurboVNC's
`-kill :DISPLAY`, then starts the selected desktop. Programs in those sessions
are closed. Other users' sessions are not targeted. A listing or stop failure
aborts the launch instead of silently reusing a session.

If you saved the bootstrap as `latest.sh`, use the same flags with that name.
Existing bootstrap copies already forward all arguments, so no new download is
needed: they fetch the updated VPN wrapper and VNC client on their next run.
Both downloaded scripts also accept `--fresh` directly. Put options before the
`username@domain` argument; `--fresh` and `--openbox` work in either order.

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
When it asks for your sudo password its the password for your wsl, the login when it was for a username then password is your UMBC login that you use for the VPN.

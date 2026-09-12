# sang Valheim Serverpack

Windows client installer for the `sang` Valheim server.

## Install

Download the latest `valheim_serverpack.zip` from Releases, unzip it, then double-click:

`install-client.bat`

The installer opens a terminal window, shows the install log, finds your Steam Valheim installation, installs BepInEx, downloads the pinned Thunderstore mod versions, and launches Valheim.

If Valheim is installed somewhere unusual:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-client.ps1 -ValheimPath "D:\SteamLibrary\steamapps\common\Valheim"
```

To reinstall cleanly:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-client.ps1 -Force
```

## Connect

The server uses Crossplay / PlayFab.

Use Valheim's `Join Code` flow. Ask the server host for the current private join code and password.

Valheim does not currently provide a stable supported command-line option to add a Join Code server favorite automatically, so the script launches the game and asks players to enter the private code manually.

## Port Forwarding

With `CROSSPLAY=true`, players can connect using the PlayFab join code without router port forwarding in the normal case. The server still listens on UDP `2456-2458`, but friends should use the join code rather than the LAN address.

For LAN-only Steam backend connection by private IP, the server would need to be switched to `CROSSPLAY=false`.

## Pinned Mods

See `manifest.json` for the exact versions.

Some originally requested mods were replaced because the old packages were deprecated or failed against Valheim `1.0.12`:

- `DeathPinRemoval` -> `AutoRemoveDeathPin`
- `AzuSigns` -> `AdvancedSigns`
- `MSchmoecker/MultiUserChest` -> `MultiUserChest_Valheim1Compat`
- `Smoothbrain/TargetPortal` -> `TheLukoMan/TargetPortal`
- `SeasonalTweaks` is disabled because it errored on Valheim `1.0.12`

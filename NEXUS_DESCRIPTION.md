# Starmancer - Atmosphere, Thermal & Phantom Leak Fix

A permanent, standalone fix for Starmancer's most notorious game-breaking bugs: the **NaN temperature lock**, the **-273°C cascading room freeze**, and **phantom air leaks stuck in save files**.

---

## 📖 Description

If you have spent hours building a station in *Starmancer*, chances are you have encountered one of these game-ending disasters:
1. **The NaN Temperature Bug**: A newly built room, an airlock cycling, or a meteor breach suddenly displays `NaN` for temperature.
2. **The -273°C Cascading Deep Freeze**: Heat exchangers and wall vents connected to a glitched room immediately start draining heat from healthy rooms at **60°C every second**, freezing your colonists, crops, and machines down past absolute zero.
3. **Phantom Leaks in Save Files**: You patch a hole in the hull with walls and doors, but the game still treats the room as open to the vacuum of space, continuously venting all your air into nothingness.

**This mod permanently fixes all three issues directly inside the game code.** 

Best of all, **it automatically heals existing damaged saves**. If your current campaign is frozen or leaking, loading your save with this fix installed will restore your damaged rooms back to a comfortable **21°C** within seconds.

---

## ✨ Main Features

* 🛡️ **Fixes the NaN Glitch**: Stops the hidden division-by-zero that corrupts depressurized rooms into `NaN`.
* 🌡️ **Stops the -273°C Deep Freeze**: Protects wall vents and heat exchangers so they never drain heat into glitched or unpressurized rooms.
* 🚪 **Eliminates Phantom Leaks**: Every 10 leak ticks (~5 seconds), leaking rooms now double-check their surrounding walls. If you sealed the breach, the leak stops immediately and clears itself from the save file.
* 🩹 **Auto-Heals Damaged Saves**: You do **not** need to start a new game! Loading an existing broken save will safely thaw frozen rooms and repair corrupted tiles back to normal room temperature (21°C).
* ⚡ **100% Standalone & Lightweight**: No BepInEx, Doorstop, or mod loaders required. No background scripts or lag—just clean bytecode fixes that run natively with the game.
* 🏆 **Steam & Achievement Safe**: Does not interfere with Steam achievements or game stability.

---

## 🛠️ Installation Instructions

Choose whichever installation method is easiest for you:

### Option 1: Automated 1-Click Installer (Recommended)
1. Download the mod ZIP from the **Files** tab and extract it anywhere (e.g. your Desktop or Downloads folder).
2. Double-click **`apply-fix.bat`**.
3. The installer will automatically locate your Starmancer folder, create a safety backup of your original file (`StarmancerMod.dll.orig`), and patch the game in under 2 seconds.
4. Launch the game and enjoy your station!

### Option 2: Manual Drag-and-Drop
1. In Steam, right-click **Starmancer** in your library -> **Manage** -> **Browse local files**.
2. Go into: `Starmancer\Starmancer_Data\Managed\`
3. Rename the existing **`StarmancerMod.dll`** to **`StarmancerMod.dll.orig`** (this is your vanilla backup).
4. From the downloaded ZIP, open the **`prepatched/`** folder and copy **`StarmancerMod.dll`** into `Starmancer_Data\Managed\`.
5. Launch the game!

---

## 🔄 How to Uninstall

You can revert back to 100% vanilla at any time:
* **If you used the installer**: Double-click **`restore-vanilla.bat`**.
* **Manual**: Delete `StarmancerMod.dll` and rename `StarmancerMod.dll.orig` back to `StarmancerMod.dll`.
* **Steam**: Right-click Starmancer in Steam -> **Properties** -> **Installed Files** -> **Verify integrity of game files**.

---

## 📋 Requirements

* **Game**: *Starmancer* (Vanilla / Steam on Windows).
* **Other Mods**: None! No external frameworks, BepInEx, or third-party loaders are needed.
* **Save Compatibility**: Fully compatible with existing saves and brand-new games.

---

## 💖 Shout Outs & Credits

* **DavidGM91**: For initiating the investigation, testing saves, and making sure this fix was made available to the entire Starmancer community so everyone can enjoy this great game bug-free.
* **Antigravity (Google DeepMind)**: The AI coding partner who rolled up its digital sleeves, reverse-engineered the decompiled game assemblies, tracked down the exact mathematical root causes (the 0/0 division in `CalculateAverages`, the `Mathf.Min` NaN trap in `TransferHeat`, and the serialized opening state in `AtmosphereLeakToSpaceComponent`), and engineered the clean bytecode patches. Machine or not, great pair programming gets great results!
* **Ominux Games**: For creating the wonderful universe of *Starmancer*.

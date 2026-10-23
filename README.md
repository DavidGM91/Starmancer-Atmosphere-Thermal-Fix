# Starmancer Atmosphere, Thermal & Phantom Leak Fix

[![Game](https://img.shields.io/badge/Game-Starmancer-blue.svg)](https://store.steampowered.com/app/1062000/Starmancer/)
[![Platform](https://img.shields.io/badge/Platform-Windows-lightgrey.svg)]()
[![Mod Type](https://img.shields.io/badge/Type-Direct%20Assembly%20Patch-brightgreen.svg)]()
[![No Mod Loader Needed](https://img.shields.io/badge/Requires-Vanilla%20Game%20Only-orange.svg)]()
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A standalone bytecode fix that permanently resolves the game-breaking thermal and atmospheric bugs in **Starmancer**:

- 🧊 **The NaN Temperature Bug**: Depressurized or breached rooms trigger a division-by-zero that locks room temperatures to `NaN`.
- ❄️ **The -273°C Cascading Freeze**: Connected rooms drain heat at 60°C/sec down to absolute zero through heat exchangers/vents when adjacent to a `NaN` room.
- 💨 **Phantom Leaks in Save Files**: Sealed breaches and enclosed rooms permanently vent atmosphere into space across save/loads.
- 🩹 **Auto-Heals Corrupted Saves**: Damaged tiles, frozen rooms, and lingering phantom leaks in existing save files automatically repair themselves to 21°C within seconds of loading.

> **Note:** This fix modifies `StarmancerMod.dll` directly at the bytecode level. **No mod loaders (BepInEx, Harmony, Doorstop) are needed**, and there is zero performance impact.

---

## 📥 Installation Guide

Choose either **Method 1 (Automatic, 1-Click)** or **Method 2 (Manual Copy-Paste)**.

---

### Method 1: Automated Installer (Recommended — 1-Click)

The automated patcher automatically finds your game directory, creates a safety backup of your original files, and applies the fix in under 2 seconds.

1. **Download the fix**:
   - Go to the [**Releases**](../../releases) tab and download the latest `Starmancer-Atmosphere-Thermal-Fix.zip` (or click the green **Code** button at the top of this repository -> **Download ZIP**).
2. **Extract the ZIP** anywhere on your computer (e.g., your Desktop or Downloads folder).
3. **Double-click `apply-fix.bat`**.
   - The installer will automatically scan your drives and Steam registry to find your Starmancer installation.
   - It will automatically create a backup of your original unpatched file (`StarmancerMod.dll.orig`).
   - It will apply the 4 bytecode patches and display:
     ```text
     SUCCESS! Starmancer has been patched successfully.
     Your station atmosphere is now fully protected.
     ```
4. **Launch Starmancer and play!**

> **Troubleshooting:** If your game is installed in a non-standard custom directory, the script will simply ask you to paste your game folder path (e.g., `D:\Games\Steam\steamapps\common\Starmancer`).

---

### Method 2: Manual Installation (Drop-In File)

If you prefer not to run scripts, you can directly replace the game DLL with the pre-patched file included in this repository.

1. **Locate your Starmancer installation folder**:
   - Open **Steam**.
   - Right-click **Starmancer** in your library -> **Manage** -> **Browse local files**.
2. **Navigate to the Managed folder**:
   ```text
   Starmancer\Starmancer_Data\Managed\
   ```
3. **Back up the original file**:
   - Find `StarmancerMod.dll`.
   - Rename it to:
     ```text
     StarmancerMod.dll.orig
     ```
4. **Copy the patched file**:
   - From this repository, open the `prepatched/` folder.
   - Copy `StarmancerMod.dll` into your game's `Starmancer_Data\Managed\` folder.
5. **Launch the game!**

---

## 🔄 How to Uninstall / Restore Vanilla

To revert back to 100% original vanilla at any time:

- **Automatic**: Double-click **`restore-vanilla.bat`**.
- **Manual**: Delete `StarmancerMod.dll` from `Starmancer_Data\Managed\` and rename `StarmancerMod.dll.orig` back to `StarmancerMod.dll`.
- **Via Steam**: In Steam, right-click **Starmancer** -> **Properties** -> **Installed Files** -> **Verify integrity of game files**.

---

## ✅ How to Verify the Fix is Working

1. **In Existing Corrupted Saves**:
   - Load a save file where rooms were stuck at `NaN` or frozen into negative temperatures.
   - Within 1–5 seconds of unpausing, the tiles and atmosphere will automatically reset to normal room temperature (**21°C**).
2. **Breaches and Repairs**:
   - If a room was breached or an airlock opened, sealing the breach with walls or doors will immediately cause the room to stop leaking.
   - The game will re-test room boundaries every 10 leak cycles (~5s) and cancel the leak permanently once sealed.

---

## 🛠️ Summary of Patches Applied

| # | Component & Method | Vanilla Bug | Patched Behavior |
| :-: | :--- | :--- | :--- |
| **1** | **`AtmosphereFlowDaemonComponent`**<br>`CalculateAverages` | Divides total room temperature by the count of pressurized floors (`num2`). In depressurized rooms, `num2 == 0`, causing **`0.0 / 0.0 = NaN`**. | Guards against division by zero (`num2 <= 0`). If a room has no gas, sets the average to a safe neutral `21.0°C` instead of NaN. |
| **2** | **`PeriodicTemperatureExchangerComponent`**<br>`TransferHeat` | Computes temperature delta: `Mathf.Min((temp1 - temp2)/2, 1.0f)`. If one room is NaN, `NaN < 1.0f` is false, returning `1.0f`. It then **subtracts 1.0°C every single tick (60°C/sec)** from the healthy room down past $-273^\circ\text{C}$. | Adds an instant guard: if either room's temperature is `NaN` or `Infinity`, heat transfer aborts immediately (`ret`). |
| **3** | **`AtmosphereUnit`**<br>`MoveToAverage` | When `!HasPressure()`, unpressurized floors adopt the room's temperature average directly. Once NaN is stored, future math is corrupted forever. | **Sanitizes inputs:** Replaces incoming `NaN`/`Infinity` with `21.0°C`.<br>**Auto-heals existing saves:** If a floor's stored temperature is `NaN` or $< -273.15^\circ\text{C}$, it heals it back to `21.0°C`. |
| **4** | **`AtmosphereLeakToSpaceComponent`**<br>`OnLeakAtmosphere` & `RefreshRoomAdjacency` | Leaking floors serialize `isLeakingAtmosphere_ = true` and `numberOfOpenings_ > 0` into save files. On load, the game only checks `numberOfOpenings_ == 0` without verifying if space is still open. Repaired rooms leak forever, bleeding air to 0 pressure. | **Periodic Adjacency Retest:** Every 10 leak ticks (~5s), the floor triggers `RefreshRoomAdjacency(room)`, forcing an adjacency check against live walls/doors. If enclosed, the leak halts immediately and zeros out the opening count. |

---

## ❓ Frequently Asked Questions (FAQ)

#### Will this disable Steam Achievements?
**No.** Starmancer does not disable achievements when running modified assemblies.

#### Is this safe for my existing save files?
**Yes.** In fact, it is specifically designed to heal damaged saves. If your station was already ruined by the NaN temperature bug, loading it with this fix will repair the damaged rooms within seconds.

#### Does this require BepInEx or other mods?
**No.** It is a standalone, direct assembly patch. It has no external dependencies.

#### What happens if the game updates?
If Starmancer receives an official update through Steam, Steam will replace `StarmancerMod.dll` with the new official version. You can simply run `apply-fix.bat` again to reapply the fix to the new update.

---

## 📜 License

This project is licensed under the [MIT License](LICENSE).

## 🤖 AI Disclosure

This project was partially made with Gemini 3.8 Flash using the anti-gravity editor.

# Starmancer Community Engine & Thermal Fix

[![Starmancer](https://img.shields.io/badge/Game-Starmancer-blue.svg)](https://store.steampowered.com/app/1062000/Starmancer/)
[![Platform](https://img.shields.io/badge/Platform-Windows-lightgrey.svg)](https://store.steampowered.com/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

A high-performance, standalone bytecode community patch for **Starmancer** that permanently fixes 3 game-breaking vanilla engine bugs:
1. **The NaN Room Temperature Freeze** (rooms plunging to -273.15°C absolute zero).
2. **Permanent Space Breaches** (repaired rooms eternally leaking atmosphere).
3. **Colonist Move Order UI Lockup** (Escape key breaking task cursor and trapping the UI).
4. **Auto-Healing for Existing Corrupted Save Files**.

---

## 🔍 The Bugs & Root Causes

### 1. The NaN Temperature Freeze Bug (`AtmosphereFlowDaemonComponent` & `PeriodicTemperatureExchangerComponent`)
- **Vanilla Flaw**: In any unpressurized or depressurized space (airlocks, breaches, or newly constructed rooms), the number of pressurized tiles is zero (`num2 == 0`). In `AtmosphereFlowDaemonComponent.CalculateAverages()`, calculating average room temperature divides `totalTemperature / num2`, which results in `0.0 / 0.0 = double.NaN`.
- **The Cascade**: Connected wall vents and heat pipes run `PeriodicTemperatureExchangerComponent.TransferHeat()` up to 60 times per second. They calculate `Mathf.Min((roomTemp - targetTemp) / 2f, amountOfHeat)`. Under IEEE 754 floating-point rules, comparing `NaN < 1.0f` is always `false`. Consequently, `Mathf.Min` evaluates to `1.0f`, **sucking 1.0°C per tick out of adjacent pressurized rooms**.
- **Result**: Within seconds, healthy living quarters drop from +21°C to -50°C, -150°C, and all the way down to **-273.15°C (absolute zero)**, freezing colonists and destroying stations.
- **The Fix**:
  - Guards `CalculateAverages` so that vacuum defaults safely to 21.0°C instead of dividing by zero.
  - Injects guards into `PeriodicTemperatureExchangerComponent.TransferHeat` to instantly abort heat transfer if either tile has `NaN` or `Infinity` temperature.
  - Automatically heals any tile with `NaN` or sub-absolute-zero temperature (`< -273.15°C`) back to 21°C inside `AtmosphereUnit.MoveToAverage()`.

---

### 2. The Permanent Space Breach Bug (`AtmosphereLeakToSpaceComponent`)
- **Vanilla Flaw**: When a room breaches, `AtmosphereLeakToSpaceComponent` checks the 8 surrounding neighbor tiles. If fewer than 8 solid tiles exist, it marks the room as leaking and sets `isLeakingAtmosphere_ = true`. Because these fields are annotated with `[ProtoMember]`, **the leaking status is written directly into your save file**.
- **The Cascade**: Even after you build walls to seal the breach, `IsLeakValid()` in vanilla only verified `numberOfOpenings_ == 0` without re-evaluating whether walls were completed. The room was permanently stuck leaking into space forever.
- **The Fix**:
  - Injects a leak counter (`leakCounter_`) and a live room adjacency refresh (`RefreshRoomAdjacency`).
  - Every 10 leak ticks, it dispatches an `OnRefreshAdjacentObjects` event to all room tiles, allowing newly placed walls to automatically seal the room live without requiring station demolition.

---

### 3. The Colonist Move Order Esc-Key Lockup (`GoToFloorOrderBlueprintComponent`)
- **Vanilla Flaw**: When ordering a colonist to walk or perform a task (`GoToFloorOrderBlueprintComponent`), `OnUserActionInvoked` only listened for confirmation clicks (`UniversalConfirmUp`) and completely ignored `CloseWindow` and `Cancel` (the `Escape` key).
- **The Cascade**: Pressing `Esc` closed the colonist window canvas in the background. On the next tick, `IsColonistValid()` failed, causing `OnTick` to enter an infinite loop calling `OnRemoved` without removing the cursor, without unregistering global events, and without deactivating hero mode. The player was permanently locked in task-order cursor mode.
- **The Fix**:
  - Rewires `OnUserActionInvoked` to intercept `CloseWindow` and `Cancel` at priority 11.
  - Absorbs user input cleanly, unselects moused-over objects, clears visual deletion grids, deactivates hero mode, unregisters global event hooks, and cleanly returns the cursor to normal play.

---

## ⚡ Why Mono.Cecil Direct Bytecode Patching?

Unlike other games, Starmancer runs on a stripped Unity Mono runtime where `mscorlib.dll` lacks `Module.GetPEKind`. This causes external mod loaders like **BepInEx** and **Doorstop** to crash or fail silently. Furthermore, background polling mods that only check rooms once per second leave 59 frames per second where vents can freeze rooms.

By patching `StarmancerMod.dll` directly using **Mono.Cecil**:
- **Zero Overhead**: Injected directly into the compiled CIL bytecode.
- **Zero Dependencies**: Requires no mod loader, Doorstop, or third-party injector.
- **Instant Auto-Heal**: Runs on the exact native engine ticks.
- **Update-Proof**: Includes a one-click PowerShell script (`reapply-fix.ps1`) that backs up `StarmancerMod.dll` to `StarmancerMod.dll.orig` and reapplies the fix in under 2 seconds whenever Steam updates the game.

---

## 📥 Installation

### Method 1: Pre-Patched DLL (Fastest)
1. Go to your Starmancer managed assemblies directory:
   ```
   <Starmancer Install Directory>\Starmancer_Data\Managed\
   ```
   *(e.g., `C:\Program Files (x86)\Steam\steamapps\common\Starmancer\Starmancer_Data\Managed\`)*
2. Rename `StarmancerMod.dll` to `StarmancerMod.dll.orig` (to keep a safe backup).
3. Copy the patched `StarmancerMod.dll` from this release into `Starmancer_Data\Managed\`.
4. Launch the game! Any corrupted save files with freezing rooms will automatically heal back to 21°C.

### Method 2: Automated PowerShell Patcher
If you prefer patching your own local game copy:
1. Extract the release folder anywhere on your PC.
2. Open PowerShell as Administrator.
3. Run:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\reapply-fix.ps1 -GameRoot "C:\Program Files (x86)\Steam\steamapps\common\Starmancer"
   ```
4. The script will automatically create `StarmancerMod.dll.orig` and apply all patches in under 2 seconds.

---

## 🗑️ Uninstallation

To revert to 100% vanilla:
1. Delete `StarmancerMod.dll` in `Starmancer_Data\Managed\`.
2. Rename `StarmancerMod.dll.orig` back to `StarmancerMod.dll`.
*(Or verify integrity of game files via Steam).*

---

## 📜 License

Distributed under the MIT License. See `LICENSE` for more information.

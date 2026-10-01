# Courseplay: Unload Me (FS25_CourseplayPlayerUnload)

[![Game](https://img.shields.io/badge/Game-Farming%20Simulator%2025-green.svg)](https://www.farming-simulator.com/)
[![Courseplay Add-on](https://img.shields.io/badge/Add--on%20for-Courseplay-blue.svg)](https://github.com/Courseplay/Courseplay_FS25)
[![GitHub Repository](https://img.shields.io/badge/GitHub-FS25__CourseplayPlayerUnload-181717?logo=github)](https://github.com/exekx/FS25_CourseplayPlayerUnload)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Version](https://img.shields.io/badge/Version-1.1.3.0-brightgreen.svg)](https://github.com/exekx/FS25_CourseplayPlayerUnload/releases)

A standalone add-on mod for **Farming Simulator 25** and **Courseplay** that enables Courseplay AI unloader tractors to automatically approach, track, match speed, and unload combines and forage harvesters (choppers) driven by human players!

**Repository:** [https://github.com/exekx/FS25_CourseplayPlayerUnload](https://github.com/exekx/FS25_CourseplayPlayerUnload)

---

## What's New in v1.1.3.0

- 🛡️ **GIANTS Engine Bug Safety Guard:**
  Integrated an engine patch preventing repeating LUA console error spam (`AIVehicleUtil.lua:337: attempt to index nil with 'getAttachedImplements'`) whenever unloader tractors or player machines tow trailers or implements lacking rear attacher joints (e.g. Krampe SB 30/60).
- 🌽 **Forage Harvester (Chopper) Overhaul:**
  Fixed collisions where unloaders treated stationary or slow forage harvesters as stopped grain combines and drove directly into the cab or header. Forage harvesters now strictly operate in dynamic follow mode (`followChopper`), keeping the unloader 5m behind the chopper cab on the safe side, both when stopped and in motion.
- 🌾 **Smart Windrow & Swath Pickup Logic:**
  When picking up grass/hay windrows where standing crop height is uniform across the field, the unloader intelligently stays on the side it is already approaching from instead of cutting across the front of the pickup header.
- 🎯 **Safe Side Pathfinding:**
  Initial pathfinding routes directly to the designated lateral clearance offset behind the machine, preventing the unloader from driving through the center rear or cutting in front of the cutter.
- ⏱️ **Dismissal Timing Fix:**
  Prevented premature unloader dismissal on forage harvesters during the approach phase before crops begin actively discharging.

---

## Overview

In standard Courseplay, combine unloader drivers only service combines that are operated by Courseplay fieldwork AI workers. When you choose to drive the combine or forage harvester yourself, Courseplay unloaders remain idle at their wait points.

**Courseplay: Unload Me** creates a bridge between your player-driven machine and Courseplay's unloading subsystem. Without changing how you drive or harvest, idle Courseplay tractors will automatically respond to your physical actions or key presses, pull up alongside under the pipe/spout on the fly, match your speed while you continue cutting, and depart smoothly once full or when unloading is done.

---

## How Unloader Calling Works

### 1. Opening the Pipe / Turning On Cutter — Always Active (Physical Command)
You don't need to press any hotkeys to get unloaded! Extending your discharge pipe or operating your machine serves as an intuitive physical command:
- **Combines with Grain Tank:** As long as your tank contains crops (> 1%), extending your discharge pipe **ALWAYS automatically calls the nearest idle Courseplay unloader**, regardless of your Auto-Call toggle setting.
- **Forage Harvesters / Choppers (No Tank):** Unfolding the pipe/spout and turning on the cutter or driving forward **ALWAYS automatically calls an unloader**. The unloader remains by your side continuously until its trailer is filled or you fold the pipe / turn off the machine.
- **Fold / Close the Pipe:** 
  - If the unloader is currently alongside you unloading, closing the pipe signals that you are done. The unloader immediately finishes, steers away, and departs.
  - If the unloader is still on its way across the field and you fold the pipe, the call is cancelled and the tractor safely returns to its waiting position.

### 2. <kbd>Right Shift</kbd> + <kbd>I</kbd> — 80% Tank Auto-Call (Combines with Tanks)
- **What this toggle actually does:** <kbd>Right Shift</kbd> + <kbd>I</kbd> **ONLY** controls whether an unloader is called automatically in advance when your grain tank reaches **80% capacity** (before you have even opened the pipe).
- **Disabled by default:** This is turned **OFF** by default so you don't have tractors driving over until you are ready.
- **Enabled:** If turned ON, an unloader will set off towards you as soon as your tank reaches 80% fill, so it is already waiting alongside when you unfold the pipe.
- *(Note: For forage harvesters without grain tanks, opening the pipe or activating the cutter calls the unloader directly).*

### 3. <kbd>Right Shift</kbd> + <kbd>U</kbd> — Instant Manual Call
- Press <kbd>Right Shift</kbd> + <kbd>U</kbd> at any moment to immediately summon the nearest available Courseplay unloader on demand, regardless of pipe position or fill level.

---

## Trailer Compatibility Note
- **Supported Trailers:** Standard tipping trailers, dump trailers, silage trailers, and auger wagons with single axle, tandem, or tridem configurations.
- **Turntable / Dolly Drawbar Trailers:** Courseplay's internal AI unloader driver restricts turntable drawbar trailers (trailers with a steerable front axle/dolly) when backing up or maneuvering. For best results with Courseplay unloaders, use rigid/tandem trailers or auger wagons.

---

## Key Features

- **Dynamic Real-Time Vector Tracking:**
  The unloader calculates pipe geometry, combine ground speed, heading, and turning angle in real time to smoothly match your pace and keep the trailer perfectly centered under the auger.
- **Natural Drive-Away Routine:**
  Utilizes Courseplay's collision-free pull-away maneuvers (`MOVING_BACK` state) so the tractor turns safely away from your combine when departing.
- **Zero Input Interference:**
  Operates completely in the background without affecting manual combine controls, thresher toggles, cutter header height, or steering.
- **Optimized & Lag-Free:**
  Cached target resolution and low-overhead periodic scanning ensure smooth gameplay and zero FPS drops.
- **Multiplayer & Dedicated Server Ready:**
  Fully compatible with multiplayer sessions and dedicated servers.
- **27 Languages Supported:**
  Includes full translations for all 27 languages supported by Courseplay in Farming Simulator 25.

---

## Controls

| Keybinding | Action | Description |
| :--- | :--- | :--- |
| <kbd>Right Shift</kbd> + <kbd>U</kbd> | **Call Unloader** | Dispatches the nearest idle Courseplay unloader to your combine immediately. |
| <kbd>Right Shift</kbd> + <kbd>I</kbd> | **Toggle 80% Auto-Call** | Enables or disables automatic advance calling when grain tank hits 80% (Disabled by default; opening the pipe always calls an unloader regardless). |

*Keybindings can be customized at any time in the in-game Controls Options menu.*

---

## Requirements

- **Farming Simulator 25** (Version 1.2 or higher)
- **FS25_Courseplay** installed and activated in your game.

---

## Installation

1. Download the latest `FS25_CourseplayPlayerUnload.zip` from the [Releases](https://github.com/exekx/FS25_CourseplayPlayerUnload/releases) section.
2. Place the `.zip` file into your Farming Simulator 25 mods folder:
   - **Windows:** `Documents\My Games\FarmingSimulator2025\mods\`
   - **Mac:** `~/Library/Application Support/FarmingSimulator2025/mods/`
3. Launch the game and ensure both **Courseplay** and **Courseplay: Unload Me** are checked in the mod selection screen.

---

## Credits & License

- **Add-on Author:** `exekx` ([GitHub Profile](https://github.com/exekx))
- **Add-on Repository:** [exekx/FS25_CourseplayPlayerUnload](https://github.com/exekx/FS25_CourseplayPlayerUnload)
- **Original Courseplay:** Special thanks and gratitude to the **Courseplay.devTeam** for creating and maintaining the Courseplay mod for Farming Simulator 25 ([Courseplay GitHub Repository](https://github.com/Courseplay/Courseplay_FS25)).
- **License:** Distributed under the **GNU General Public License v3.0 (GPL-3.0)**.

---

## Support the Project

If you find this add-on helpful and enjoy your harvesting workflow, consider supporting ongoing development:

[![Support me on Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/exekx)

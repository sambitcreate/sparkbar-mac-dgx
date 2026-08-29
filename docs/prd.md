# SparkBar — macOS Menu Bar Monitor for NVIDIA DGX Spark

**Product Requirements Document**  
**Version:** 0.1  
**Date:** August 11, 2026  
**Working title:** SparkBar

---

## 1. Product Summary

SparkBar is a tiny native macOS menu-bar application that displays live health, utilization, memory, power, temperature, and inference statistics from one or more NVIDIA DGX Spark systems already monitored by **sparkDash**.

The app does **not** directly SSH into the DGX Spark, run `nvidia-smi`, inspect `/proc`, or duplicate sparkDash collectors.

Instead:

```text
DGX Spark(s)
     │
     │ SSH / local metrics / LLM APIs
     ▼
┌────────────────────┐
│     sparkDash      │
│                    │
│ collectors         │
│ SparkMonitor       │
│ REST API           │
│ WebSocket /ws      │
└─────────┬──────────┘
          │
          │ WebSocket
          │
          ▼
┌────────────────────┐
│     SparkBar       │
│      macOS         │
│                    │
│ NSStatusItem       │
│ SwiftUI popover    │
└────────────────────┘
```

sparkDash already manages multiple DGX Spark systems, local and remote collectors, LLM probes, ComfyUI monitoring and cached snapshots. Its WebSocket exposes all configured Sparks through one connection. 

---

# 2. Research Findings

## sparkDash

sparkDash currently exposes:

- GPU utilization
- GPU temperature
- GPU power draw / limit
- estimated system power
- GPU/shared memory usage
- top GPU processes
- GPU throttling state
- CPU utilization / temperature / power
- RAM
- unified memory
- memory bandwidth
- storage usage and I/O
- network RX/TX
- machine uptime
- machine online/offline state
- multiple LLM servers
- model name
- LLM backend
- generation tokens/sec
- prefill tokens/sec
- active slots
- vLLM KV-cache usage
- running/waiting requests
- TTFT / ITL / E2E latency
- preemption count
- prefix-cache hit rate
- MTP acceptance
- ComfyUI jobs and queue
- ComfyUI progress
- ComfyUI models
- Hermes status

The actual `SparkSnapshot` structure already exposes these as structured data.  

sparkDash provides:

```text
GET /api/sparks
GET /api/sparks/:id/metrics
GET /api/settings

WS /ws
```

The `/ws` payload is:

```text
{
  type: "snapshot",
  sparks: [...],
  refreshInterval: ...
}
```



The default polling frequencies are approximately:

| Metric | Default |
|---|---:|
| GPU | 2 sec |
| CPU | 2 sec |
| RAM | 2 sec |
| Network | 2 sec |
| Unified memory | 2 sec |
| LLM | 2 sec |
| ComfyUI | 2 sec |
| Storage | 5 sec |
| Liveness | 5 sec |



The server also avoids transmitting identical snapshots unnecessarily, so an idle Spark doesn't continuously waste bandwidth sending unchanged JSON.  

### Important implication

**SparkBar should have exactly one WebSocket connection to sparkDash, rather than one connection per DGX Spark.**

---

## CodexBar

CodexBar provides a good reference architecture for a polished native menu-bar application.

It is:

- native Swift
- macOS 14+
- an `LSUIElement` application
- hidden from the Dock
- based on AppKit `NSStatusItem`
- capable of dynamically changing menu-bar icons/content
- using richer SwiftUI UI where appropriate
- designed around persistent background refresh
- using Sparkle for direct-download updates

 

Its menu-bar controller explicitly describes its architecture as:

> AppKit-hosted icons, SwiftUI popovers



CodexBar also uses an 18×18 template image for menu-bar rendering and keeps the application out of the Dock. 

Its current package targets macOS 14+ and uses Swift 6.2. 

### Recommendation

SparkBar should follow the same broad architecture but remain dramatically simpler.

Do **not** fork all of CodexBar.

Borrow the architectural pattern:

```text
AppKit
   ↓
NSStatusItem
   ↓
NSPopover
   ↓
NSHostingController
   ↓
SwiftUI dashboard
```

---

# 3. Product Goal

Make DGX Spark status visible without opening a browser.

A user should be able to glance at the macOS menu bar and immediately answer:

**Is my Spark busy, healthy, overheating, memory-constrained, or running inference?**

Clicking the item should answer:

**What exactly is happening on it right now?**

---

# 4. Target User

Primary user:

- owns one or more NVIDIA DGX Spark / GB10 systems
- runs sparkDash somewhere on their LAN, studio network or Tailscale network
- regularly uses the machines for local inference, ComfyUI, vLLM, llama.cpp, SGLang or similar workloads
- works primarily from a Mac
- wants ambient monitoring without keeping the sparkDash webpage open

---

# 5. Product Principles

### Glanceable

Important information must be understandable within roughly one second.

### Native

No Electron, embedded React, WebView or browser wrapper.

### Read-only by default

The first version monitors. It does not administer.

### Minimal resource usage

SparkBar should consume negligible resources compared with the workloads it monitors.

### sparkDash remains the source of truth

SparkBar should not recreate hardware collectors.

### Works with multiple Sparks

sparkDash already models `N` machines. SparkBar should preserve that architecture.

---

# 6. MVP Scope

## Menu Bar

The menu-bar item contains:

```text
⚡ 72%
```

where the number defaults to GPU utilization.

Alternative user-selectable modes:

```text
⚡
⚡ 72%
⚡ 61°
⚡ 94G
⚡ 82 t/s
⚡ 72% · 61°
```

Available metrics:

- icon only
- GPU utilization
- GPU temperature
- unified-memory usage
- memory percentage
- LLM generation TPS
- GPU + temperature

Default:

**GPU utilization**

---

# 7. Multiple-Spark Menu Bar Behavior

The user selects one of three modes.

### Selected Spark

Always display one chosen machine.

Example:

```text
Studio Spark
GPU 72%
```

### Auto

Display the most active online Spark.

Priority:

```text
alerting Spark
↓
highest GPU utilization
↓
highest LLM activity
↓
selected/default Spark
```

### Aggregate

Display maximum utilization among all machines.

Example:

```text
⚡ 82%
```

Clicking still shows all machines.

**Recommended default: Auto.**

---

# 8. Menu-Bar States

### Normal

```text
⚡ 42%
```

### Heavy load

```text
⚡ 96%
```

### Running LLM

Optional tiny activity indicator.

```text
⚡ 86%
```

with animated/pulsing Spark icon.

Animation must stop when the machine becomes idle.

### Warning

Triggered by:

- thermal throttling
- high memory risk
- configured temperature threshold

### Offline

```text
⚡ —
```

with dimmed icon.

### sparkDash disconnected

Use a distinct disconnected representation rather than claiming the DGX Spark itself is offline.

This distinction is important:

```text
Spark offline
≠
sparkDash unreachable
```

---

# 9. Main Popover

Clicking the status item opens an approximately:

**360–400 px wide native popover.**

Conceptual layout:

```text
┌────────────────────────────────────┐
│ ⚡ SparkBar                  ● Live │
│                                    │
│ Studio Spark                 ▾     │
│ Online · uptime 3d 14h              │
│                                    │
│ ┌────────────────────────────────┐ │
│ │ GPU                       82%  │ │
│ │ █████████████████░░░░          │ │
│ │ 64°C         84W / 100W        │ │
│ └────────────────────────────────┘ │
│                                    │
│ Unified Memory                     │
│ ███████████████░░░░░  92 / 128 GB │
│                                    │
│ CPU          RAM          Network  │
│ 31%          72%          ↓ 1.2 GB │
│ 51°C                       ↑ 18 MB │
│                                    │
│ ─────────────────────────────────  │
│                                    │
│ DeepSeek V4                        │
│ vLLM · :8888                       │
│                                    │
│ 81.4 tok/s       KV cache 68%      │
│ 2 running        0 waiting         │
│                                    │
│ ─────────────────────────────────  │
│                                    │
│ GPU Process                         │
│ python             72.3 GB         │
│                                    │
│ Open sparkDash              ⚙      │
└────────────────────────────────────┘
```

---

# 10. Multi-Spark UI

If sparkDash contains multiple machines, the top of the popover gets a horizontally scrollable selector:

```text
[ Overview ] [ Spark 1 ] [ Spark 2 ] [ Spark 3 ]
```

## Overview

Each machine gets a compact row:

```text
Spark 1       ●
GPU 92%     68°C     105 GB
DeepSeek V4 · 81 tok/s

Spark 2       ●
GPU 4%      48°C      32 GB
Idle

Spark 3       ○
Offline
```

Overview header:

```text
3 Sparks
2 online

Max GPU     92%
Memory      137 / 256 GB
Power       ~221 W
```

Aggregate power should only be calculated when the necessary values are present.

---

# 11. Spark Detail View

Each Spark detail page contains the following sections.

## GPU

Primary card.

Display:

- GPU %
- temperature
- power draw
- power limit
- estimated system draw
- SM clock
- clock percentage
- throttling reason

If throttled:

```text
⚠ Thermal throttle
```

or:

```text
⚠ Power limited
```

sparkDash already exposes this state directly. 

---

## Unified Memory

Display:

```text
92.4 / 128 GB
72%
36 GB available
```

and OOM risk:

```text
Low
Medium
High
```

Also optionally show current memory bandwidth.

---

## CPU / RAM

Compact secondary cards.

```text
CPU
34%
52°C

RAM
76%
97 / 128 GB
```

---

# 12. LLM Monitoring

If the Spark has LLM monitoring enabled, show one card per configured port.

Example:

```text
DeepSeek-V4
vLLM · :8888

Generation        82.4 tok/s
Prefill          412.7 tok/s
Requests               2 / 0
KV cache                 71%
```

Expanded details may contain:

- model ID
- backend
- context length
- GPU memory utilization
- active slots
- total slots
- generation TPS
- prefill TPS
- running requests
- waiting requests
- KV-cache utilization
- TTFT p95
- E2E p95
- ITL p95
- prefix-cache hit rate
- MTP acceptance
- preemptions

sparkDash exposes multiple LLM entries through `metrics.llm[]`, so SparkBar must not assume a single inference server. 

---

# 13. ComfyUI

When `comfyMonitoring` is enabled:

```text
ComfyUI

Flux 2 Dev
████████████░░░░  72%

12 / 20 steps
1 running · 2 queued
ETA 3m 14s
```

When idle:

```text
ComfyUI
Idle
```

SparkBar v1 is **read-only**, so it will not expose:

- cancel
- dequeue
- submit prompt

Those remain in the sparkDash interface.

---

# 14. GPU Processes

Show up to the five processes returned by sparkDash.

Example:

```text
GPU Processes

python              72.4 GB
vllm                 9.1 GB
comfyui              4.2 GB
```

No process enumeration should occur on the Mac.

---

# 15. Network

Compact section:

```text
Ethernet

↓ 1.21 GB/s
↑ 22 MB/s

10000 Mbps
192.168.1.30
```

Hidden/disabled interfaces returned by sparkDash should not be included in the default display.

---

# 16. Storage

Storage is lower priority than GPU/LLM information and should therefore appear below the primary metrics.

Example:

```text
NVMe
1.4 / 3.8 TB
37%

Read    2.2 GB/s
Write   420 MB/s
```

---

# 17. Connection Setup

First launch:

```text
Welcome to SparkBar

Connect to sparkDash

Dashboard URL
┌──────────────────────────────────┐
│ http://192.168.1.30:5555         │
└──────────────────────────────────┘

              [ Connect ]
```

SparkBar performs:

```text
GET /api/sparks
```

If successful:

```text
✓ Connected
3 Sparks found
```

Then it establishes:

```text
ws://192.168.1.30:5555/ws
```

HTTPS automatically maps to WSS:

```text
https://spark.example.com
        ↓
wss://spark.example.com/ws
```

---

# 18. Networking Architecture

Implement:

```swift
actor SparkDashClient
```

Responsibilities:

- normalize base URL
- REST connection test
- create `URLSessionWebSocketTask`
- receive WebSocket frames
- JSON decoding
- reconnect
- connection state
- ping health
- cancellation
- expose snapshots through `AsyncStream`

Conceptually:

```text
SparkDashClient
       │
       ▼
SnapshotStore
       │
       ├──── MenuBarController
       │
       └──── SwiftUI Popover
```

There should only be **one source of state**.

---

# 19. WebSocket Behavior

Use the WebSocket as the primary data source.

The existing sparkDash frontend does essentially the same thing and reconnects if the connection closes. 

SparkBar should improve on that with:

```text
1s
2s
4s
8s
15s
30s maximum
```

exponential reconnect backoff with jitter.

Reset backoff immediately after a successful connection.

---

# 20. Important WebSocket Detail

sparkDash intentionally skips broadcasts when the serialized snapshot has not changed. 

Therefore:

**Do not interpret “I haven't received a snapshot recently” as “the Spark is stale.”**

Use:

- WebSocket connection status
- WebSocket ping
- ping failure
- socket close

to determine sparkDash connectivity.

For DGX liveness, trust:

```text
SparkSnapshot.online
```

sparkDash already performs dedicated liveness checks and gives failed checks a roughly 10-second grace window. 

---

# 21. Native macOS Architecture

Recommended:

```text
Swift 6
SwiftUI
AppKit
Observation
URLSession
Network.framework
ServiceManagement
UserNotifications
```

Minimum target:

**macOS 14 Sonoma**

Architecture:

```text
SparkBarApp
│
├── AppDelegate
│
├── StatusItemController
│   ├── NSStatusItem
│   └── NSPopover
│
├── AppModel
│
├── SparkDashClient
│
├── SnapshotStore
│
├── HistoryStore
│
├── AlertEngine
│
└── SettingsStore
```

---

# 22. Why NSStatusItem Instead of MenuBarExtra

Use:

```text
NSStatusItem
```

rather than relying exclusively on:

```text
MenuBarExtra
```

because SparkBar needs greater control over:

- dynamic image generation
- dynamic title
- animations
- icon dimming
- popover behavior
- alternate clicks
- menu-bar sizing
- future multi-status-item support

This follows the architectural direction used by CodexBar. 

SwiftUI should still implement almost the entire visible popover.

---

# 23. Status Item Controller

Conceptually:

```swift
@MainActor
final class StatusItemController
```

owns:

```text
NSStatusBar.system
NSStatusItem
NSStatusBarButton
NSPopover
NSHostingController
```

The status item contains:

- 18×18 template icon
- optional compact textual metric

CodexBar also uses an 18×18 template image approach for its status bar. 

---

# 24. App Lifecycle

SparkBar is an:

```text
LSUIElement
```

application.

Default behavior:

- no Dock icon
- no ordinary main window
- launches directly into menu bar
- Settings opens as a normal macOS settings window

This is the same high-level behavior used by CodexBar. 

---

# 25. Proposed Project Structure

```text
SparkBar/
│
├── App/
│   ├── SparkBarApp.swift
│   ├── AppDelegate.swift
│   └── AppModel.swift
│
├── MenuBar/
│   ├── StatusItemController.swift
│   ├── StatusIconRenderer.swift
│   └── PopoverController.swift
│
├── SparkDash/
│   ├── SparkDashClient.swift
│   ├── SparkDashEndpoint.swift
│   └── Models/
│       ├── SparkSnapshot.swift
│       ├── GPUMetrics.swift
│       ├── LLMMetrics.swift
│       ├── ComfyMetrics.swift
│       └── NetworkMetrics.swift
│
├── Store/
│   ├── SnapshotStore.swift
│   └── HistoryStore.swift
│
├── Views/
│   ├── PopoverRootView.swift
│   ├── OverviewView.swift
│   ├── SparkDetailView.swift
│   └── Components/
│       ├── MetricBar.swift
│       ├── GPUCard.swift
│       ├── MemoryCard.swift
│       ├── LLMCard.swift
│       └── Sparkline.swift
│
├── Alerts/
│   └── AlertEngine.swift
│
└── Settings/
    ├── SettingsView.swift
    └── SettingsStore.swift
```

---

# 26. API Data Model Strategy

Do not blindly copy the TypeScript interface as non-optional Swift structures.

sparkDash is under active development.

Swift models should be forward-compatible:

```swift
struct SparkSnapshot: Decodable, Identifiable {
    let id: String
    let name: String
    let online: Bool

    let uptime: Double?
    let hardware: HardwareInfo?
    let metrics: SparkMetrics?
}
```

New server fields should be silently ignored.

New optional features should not break older servers.

Feature detection should be based primarily on whether a field exists.

---

# 27. Local Metric History

sparkDash streams current state rather than a complete timeseries.

SparkBar should maintain a small in-memory ring buffer.

Suggested:

```text
15–30 minutes
2-second samples
```

for:

- GPU utilization
- temperature
- power
- unified memory
- LLM TPS

This enables tiny native sparklines.

Important: because sparkDash can skip identical WebSocket messages, SparkBar should sample the **latest known state on its own history timer**, rather than adding points only when a WebSocket message arrives.

History persistence is not required for MVP.

---

# 28. Settings

## Connection

```text
sparkDash URL
Connection status
Test Connection
Reconnect

Open sparkDash
```

## Menu Bar

```text
Display:
○ Icon only
● GPU utilization
○ GPU temperature
○ Unified memory
○ LLM tokens/sec
○ GPU + temperature

Source:
● Auto
○ Specific Spark
○ Aggregate
```

## General

```text
Launch at Login
Start hidden
Show notifications
```

## Temperature

```text
● Celsius
○ Fahrenheit
○ Follow sparkDash
```

---

# 29. Alerts

Alerts should be opt-in/configurable.

Potential alerts:

### Spark offline

```text
Studio Spark went offline
```

### Temperature

```text
Studio Spark reached 85°C
```

### Unified memory

```text
Studio Spark is using 119 / 128 GB
```

### OOM

```text
Memory OOM risk is HIGH
```

### GPU throttling

```text
Studio Spark is thermally throttling
```

### LLM down

```text
vLLM :8888 is no longer responding
```

Use hysteresis and cooldowns to prevent notification spam.

Example:

- send alert at ≥85°C
- clear state below 80°C
- do not resend every sample

---

# 30. Read-Only Security Model

This is especially important because sparkDash currently states that its HTTP/WebSocket API has **no authentication** and should only be exposed to a trusted network or placed behind an authenticated reverse proxy. 

SparkBar v1 should therefore call only:

```text
GET /api/sparks
GET /api/settings
GET /api/sparks/:id/metrics

WS /ws
```

It should **not** initially expose:

```text
shutdown
wake
Comfy cancel
add Spark
edit Spark
delete Spark
LLM benchmarking
Hermes updates
```

This provides a very useful security boundary:

**SparkBar monitors. sparkDash administers.**

---

# 31. Remote Access

Recommended remote configurations:

```text
Mac
 ↓
Tailscale
 ↓
sparkDash
```

or:

```text
Mac
 ↓
HTTPS/WSS reverse proxy
 ↓
sparkDash
```

SparkBar should support:

```text
http://
https://
ws://
wss://
```

but Settings should warn when an insecure endpoint appears to be used outside a local/private environment.

Future versions may support:

- Bearer header
- Basic Auth
- custom reverse-proxy authentication

Credentials must live in Keychain rather than UserDefaults.

---

# 32. Privacy

SparkBar should have:

- no account system
- no cloud backend
- no analytics by default
- no SSH credentials
- no filesystem scanning
- no shell execution
- no DGX credentials
- no model prompt collection

Persist only:

- sparkDash URL
- display preferences
- alert preferences
- default Spark
- optional short-term metric history if later enabled

---

# 33. Performance Targets

When the popover is closed:

```text
CPU average       < 0.5%
Memory            target < 50–75 MB
Network           effectively sparkDash WS payload only
Animations        disabled unless needed
```

The application must not redraw SwiftUI continuously just because the Spark is connected.

Only update UI when:

- snapshot changes
- selected Spark changes
- an animation is actually active
- local history sampling requires it

---

# 34. Sleep / Wake

When the Mac wakes:

1. determine current network availability
2. verify WebSocket
3. reconnect immediately if necessary
4. retain last-known snapshot while reconnecting
5. label it as disconnected rather than deleting the data

Example:

```text
Studio Spark

Last known
GPU 82% · 63°C

Reconnecting…
```

---

# 35. Error States

## Incorrect URL

```text
Could not reach sparkDash.

Check that the dashboard URL is correct
and that this Mac can access port 5555.
```

## API reachable, WebSocket unavailable

```text
sparkDash found
Live stream unavailable
```

## No Sparks configured

```text
Connected to sparkDash

No DGX Spark systems are configured yet.

[ Open sparkDash ]
```

## Server disconnected

Keep last-known information visibly marked as stale/disconnected.

Never replace valid last-known metrics with zeros.

---

# 36. Open sparkDash

Footer action:

```text
Open sparkDash ↗
```

opens the configured base URL in the default browser.

If viewing a particular Spark and sparkDash eventually exposes stable deep links, SparkBar may open that specific Spark directly.

---

# 37. Updates and Distribution

Initial distribution should be:

```text
Developer ID signed
Notarized
Direct download
```

Optional:

```text
Homebrew Cask
```

Use Sparkle 2 for auto-updating.

CodexBar follows the same direct-distribution + Sparkle pattern.  

Mac App Store distribution can be evaluated later.

---

# 38. Launch at Login

Use modern macOS ServiceManagement APIs.

Setting:

```text
Launch SparkBar at login   [on]
```

No separate helper application should be necessary.

---

# 39. Visual Direction

The application should feel like a macOS system monitor rather than a miniaturized webpage.

Use:

- native materials
- SF Pro
- SF Symbols where appropriate
- restrained color
- large numbers
- very little text
- small sparklines
- strong hierarchy

Example primary hierarchy:

```text
82%
GPU

64°C        84 W
Temperature Power
```

Avoid recreating sparkDash's React cards pixel-for-pixel.

SparkBar's value is that it turns the information into a **glanceable native surface**.

---

# 40. Menu-Bar Icon

Recommended visual:

a simple stylized Spark / GPU meter.

States:

```text
idle       static
active     subtle pulse
warning    warning overlay
offline    dim
connecting short bounded animation
```

Do not run perpetual 60 FPS animation.

CodexBar similarly puts hard limits around menu-bar loading animations to avoid continuously redrawing the menu bar. 

---

# 41. MVP Acceptance Criteria

SparkBar v1 is ready when:

1. User can enter a sparkDash URL.
2. App validates the connection.
3. App automatically connects to `/ws`.
4. All configured Sparks appear.
5. Online/offline state is correctly represented.
6. GPU utilization appears in the menu bar.
7. User can choose another menu-bar metric.
8. Clicking opens a native popover.
9. GPU, temperature, power, memory and CPU are visible.
10. LLM backend/model/TPS are visible when available.
11. Multiple LLM ports work correctly.
12. Multiple Sparks work correctly.
13. ComfyUI status appears when available.
14. WebSocket reconnects after network interruption.
15. Sleep/wake works correctly.
16. Last-known data does not turn into false zeros.
17. The app has no Dock icon.
18. Launch at Login works.
19. Open sparkDash works.
20. The application performs no DGX SSH or metric collection itself.

---

# 42. Phase 1

**Core monitor**

```text
Native menu-bar app
Connection onboarding
One sparkDash endpoint
WebSocket client
Multiple Sparks
Overview
Spark details
GPU
CPU
RAM
Unified memory
Power
LLM
Network
Storage
ComfyUI state
Launch at login
```

---

# 43. Phase 1.1

**Polish**

```text
Sparklines
GPU processes
Throttle indicator
Auto/busiest Spark menu metric
Custom menu-bar metric
Temperature unit setting
Keyboard shortcut
Sparkle updates
```

---

# 44. Phase 2

**Alerts**

```text
Offline notification
Temperature thresholds
Memory thresholds
OOM warning
Thermal throttling
LLM unavailable
Notification cooldown / hysteresis
```

---

# 45. Phase 3

**Advanced integration**

Potentially expose selected safe sparkDash actions:

```text
Wake Spark
Open ComfyUI
Open LLM endpoint
Run benchmark
```

Power-off should remain deliberately difficult:

```text
Shutdown…
→ confirmation
→ machine name confirmation
```

because sparkDash's control endpoints currently sit behind the same unauthenticated trusted-network model as the rest of its API.

---

# 46. Future: Multiple sparkDash Servers

Later:

```text
Home
 ├── Spark 1
 └── Spark 2

Studio
 ├── Spark 3
 └── Spark 4
```

SparkBar could maintain one WebSocket per sparkDash deployment.

This should **not** complicate MVP.

sparkDash already solves multi-machine monitoring inside a single deployment, so most users will only need one connection.

---

# 47. Future: Menu-Bar Presets

Borrow one concept from CodexBar without adopting its complexity: configurable menu-bar composition.

Examples:

```text
⚡ 82%
```

```text
⚡ 82% · 64°
```

```text
DeepSeek · 81 t/s
```

```text
105G · 84W
```

Eventually this could become a simple token-based layout editor.

For v1, a normal picker is sufficient.

---

# 48. Most Important Engineering Decision

SparkBar should **consume sparkDash**, not fork its monitoring engine.

That gives us:

```text
No SSH code
No nvidia-smi parser
No Linux collectors
No remote credential management
No LLM backend discovery
No ComfyUI probing
No duplicated polling
```

sparkDash remains responsible for:

```text
DGX → metrics
```

SparkBar becomes responsible for:

```text
metrics → excellent macOS experience
```

That separation is what keeps the app genuinely tiny.

---

# 49. Recommended MVP Technical Stack

```text
Language          Swift 6
UI                SwiftUI
Menu bar          AppKit NSStatusItem
Popover           NSPopover + NSHostingController
State             Observation
Networking        URLSession
WebSocket         URLSessionWebSocketTask
Network state     Network.framework
Preferences       UserDefaults
Secrets           Keychain if eventually needed
Notifications     UserNotifications
Login Item        ServiceManagement
Updates           Sparkle 2
Minimum OS        macOS 14
Distribution      Developer ID + notarization
```

---

# 50. Final Product Definition

**SparkBar is the native Mac companion for sparkDash.**

sparkDash stays running near the DGX machines and performs the monitoring.

SparkBar stays running on the Mac and turns that data into:

```text
one icon
one glance
one click
```

instead of another browser tab.
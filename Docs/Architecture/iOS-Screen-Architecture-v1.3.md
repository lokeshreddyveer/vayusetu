# VayuSetu — Complete iOS Screen Architecture
**UI/UX Specification | v1.3 | Native SwiftUI**

This document defines the complete screen architecture for VayuSetu, including navigation, layouts, components, interactions, states, settings, and screen-to-screen flows.

**Platform:** iOS  
**UI framework:** SwiftUI  
**Design:** Premium dark interface, minimal, professional, native iOS  
**Navigation:** Five native bottom tabs  
**Architecture:** Screen → Section → Component → Action → Destination

---

# 1. Global Navigation Architecture

VayuSetu has exactly five primary tabs.

```text
VayuSetu
│
├── 1. HOME
│
├── 2. PROFILES
│
├── 3. DNS
│
├── 4. ADBLOCK
│
└── 5. SETTINGS
```

The bottom navigation remains consistent across primary screens.

### Bottom navigation

| Tab | Icon concept | Purpose |
|---|---|---|
| Home | Minimal shield | Connection overview |
| Profiles | Layered connection nodes | VPN profile management |
| DNS | Connected network nodes | DNS configuration |
| Adblock | Shield with blocking indicator | Filtering and Safari protection |
| Settings | Precision gear | Application configuration |

**Navigation rules**

- Use native `TabView` with five tabs.
- Each tab maintains its own `NavigationStack`.
- Secondary screens use native push navigation.
- Editors and confirmation flows use sheets where appropriate.
- Destructive actions require confirmation.
- Avoid excessive full-screen modals.
- No browser redirects for normal app features.
- Apple permission dialogs and necessary system Settings handoffs are allowed.

---

# 2. Global Design System

## 2.1 Visual identity

VayuSetu should feel like a professionally designed network-security utility.

Design characteristics:

- Deep navy and charcoal surfaces.
- Restrained green accents for confirmed active protection.
- Clear typography and generous spacing.
- Custom, consistent icons.
- Subtle borders and carefully controlled shadows.
- No excessive gradients, glowing effects, or unnecessary animations.
- Native iOS interactions and accessibility.

### Color system

| Token | Color |
|---|---|
| Main background | `#070B12` |
| Primary card | `#111A25` |
| Elevated card | `#192535` |
| Divider | `#273342` |
| Primary text | `#F5F7FB` |
| Secondary text | `#9AA8BA` |
| Active | `#4DDEA9` |
| Inactive / Unknown | `#8997A9` |
| Pending / Limited | `#F2B75E` |
| Error | `#F16E75` |

Colors must never be the only indication of status.

## 2.2 Typography

Use San Francisco with a consistent hierarchy.

```text
Large Title       32 pt
Screen Title      28 pt
Section Heading   18 pt
Card Heading      16 pt
Primary Body      15 pt
Secondary Body    13 pt
Caption           11–12 pt
```

Support Dynamic Type rather than fixing all text to these sizes.

Use tabular numerals for timers and traffic statistics.

## 2.3 Shared components

```text
DesignSystem
│
├── AppBackground
├── AppNavigationBar
├── BottomTabBar (native)
├── SectionHeader
├── PrimaryCard
├── CompactCard
├── StatusIndicator
├── ProtectionStatusTile
├── ConnectionPowerButton
├── MetricDisplay
├── SessionTimer
├── ProfileRow
├── DNSResolverRow
├── FilterListRow
├── RuleRow
├── SettingsRow
├── SegmentedSelector
├── InlineNotice
├── EmptyState
├── LoadingState
├── ErrorState
├── ConfirmationSheet
├── PermissionExplanation
└── CustomIconLibrary
```

Each component must support disabled, loading, active, error, and accessibility states where relevant.

---

# 3. HOME TAB

**Purpose:** Give the user immediate control of their VPN connection and an accurate overview of all protection systems.

## 3.1 Home screen structure

```text
HOME
│
├── Header
│   ├── VayuSetu Logo
│   ├── App Name
│   └── Settings Shortcut
│
├── Main Connection Card
│   ├── Connection Status
│   ├── Large VPN Power Button
│   ├── Active Profile Name
│   ├── VPN Protocol
│   ├── Server / Endpoint
│   └── Connect / Disconnect Action
│
├── Session Information
│   ├── Session Duration
│   ├── Download Speed
│   ├── Upload Speed
│   └── Total Data Transferred
│
├── Protection Overview
│   ├── VPN Status Tile
│   ├── DNS Status Tile
│   ├── Safari Status Tile
│   └── Adblock Status Tile
│
├── Quick Actions
│   ├── Run Privacy Checks
│   ├── Change VPN Profile
│   └── View Connection Details
│
├── Recent Activity
│   ├── Latest Protection Events
│   └── View All Events
│
└── Bottom Navigation
```

## 3.2 Header

Left:

- VayuSetu icon.
- VayuSetu wordmark.

Right:

- Settings shortcut.

Do not overload the header with multiple action buttons.

## 3.3 Main VPN connection card

The central element is a large circular power button.

### Disconnected

```text
        DISCONNECTED

             ◯
             ⏻

        Tap to Connect

      No Active Connection
```

### Connected

```text
          CONNECTED

             ◉
             ⏻

         WireGuard

      My Home VPN Profile
```

### Connecting

Display:

- Amber status.
- Controlled progress animation.
- Connecting label.
- Cancel option if supported.

Do not display a fake percentage.

### Connection errors

Show:

- Error summary.
- Retry.
- Change profile.
- View details.

## 3.4 Session metrics

```text
SESSION

Duration
00:02:35:42

DOWNLOAD             UPLOAD
24.6 Mbps            3.8 Mbps

DATA RECEIVED        DATA SENT
1.42 GB              284 MB
```

The session timer uses:

`DD:HH:MM:SS`

Days are not artificially capped.

Traffic rates must come from actual network counters. When unavailable, show **Unavailable**, not zero or fabricated measurements.

## 3.5 Protection overview

Four compact tiles arranged in a 2×2 grid.

```text
┌──────────────────┬──────────────────┐
│ VPN              │ DNS              │
│ ● Connected      │ ● Active         │
├──────────────────┼──────────────────┤
│ Safari           │ Adblock          │
│ ● Enabled        │ ● Active         │
└──────────────────┴──────────────────┘
```

Each tile contains:

- Custom icon.
- Protection name.
- Current observed status.
- Status color.
- Navigation indicator.

### Tile navigation

| Tile | Destination |
|---|---|
| VPN | Connection Details |
| DNS | DNS Overview |
| Safari | Adblock → Safari |
| Adblock | Adblock Overview |

**Important:** Tapping a tile opens its screen. It does not immediately enable or disable protection.

### Status presentation

| Status | Color |
|---|---|
| Connected / Active | Green |
| Safari Enabled | Green |
| Disconnected / Inactive | Gray |
| Unknown | Gray |
| Enabled, not verified | Amber |
| Starting / Connecting | Amber |
| Limited | Amber |
| Needs attention | Amber |
| Error | Red |

Safari must say **Enabled**, not **Protecting**, when the system only confirms extension enablement.

## 3.6 Quick actions

Three compact actions:

**Run Checks**  
Opens Settings → Checks.

**Switch Profile**  
Opens Profiles with the profile selector.

**Connection Details**  
Opens the active connection information screen.

## 3.7 Recent activity

Show the latest three local protection events.

Example:

```text
RECENT ACTIVITY

10:42 PM  VPN Connected
10:42 PM  DNS Configuration Verified
10:41 PM  Network Changed

View All Activity →
```

Do not display fabricated blocking events.

---

# 4. CONNECTION DETAILS SCREEN

**Access:** Home → VPN tile or Connection Details.

```text
CONNECTION DETAILS
│
├── Connection Overview
│   ├── Status
│   ├── Profile Name
│   ├── Protocol
│   └── Connected Since
│
├── Server Information
│   ├── Endpoint
│   ├── Port
│   ├── Server IP
│   └── Network Interface
│
├── Connection Statistics
│   ├── Session Duration
│   ├── Download Speed
│   ├── Upload Speed
│   ├── Downloaded Data
│   └── Uploaded Data
│
├── Routing Information
│   ├── IPv4
│   ├── IPv6
│   ├── DNS Policy
│   └── Privacy Lock Status
│
├── Connection Events
│
└── Actions
    ├── Disconnect
    ├── Reconnect
    ├── Switch Profile
    └── Run Checks
```

Only display technical fields the active adapter can actually provide.

Unknown or inaccessible information must be clearly labeled.

---

# 5. PROFILES TAB

**Purpose:** Manage user-supplied VPN profiles and connection behavior.

## 5.1 Profiles overview

```text
PROFILES
│
├── Header
│   ├── Title
│   └── Add Profile (+)
│
├── Active Connection
│   ├── Current Profile
│   ├── Protocol
│   └── Status
│
├── Search Profiles
│
├── Sort / Filter
│   ├── Recently Used
│   ├── Name
│   └── Protocol
│
├── Saved Profiles
│   └── Profile Rows
│
├── Connection Rules
│
└── Import Profile
```

Profile rows contain:

- Profile name.
- Protocol icon.
- Server information.
- Active indicator.
- Overflow menu.

### Row actions

```text
Connect
View Details
Edit
Rename
Duplicate (if safe and supported)
Export
Delete
```

Export must exclude credentials by default.

## 5.2 Add Profile screen

```text
ADD VPN PROFILE
│
├── Import Method
│   ├── Import File
│   ├── Scan QR Code
│   └── Manual Configuration
│
├── Protocol Selection
│   ├── WireGuard
│   ├── OpenVPN
│   └── IKEv2 / IPsec
│
└── Continue
```

Available import methods depend on the selected protocol.

## 5.3 WireGuard profile editor

```text
WIREGUARD PROFILE
│
├── General
│   ├── Profile Name
│   └── Description
│
├── Interface
│   ├── Private Key (Secure)
│   ├── Address
│   ├── DNS
│   └── MTU
│
├── Peer
│   ├── Public Key
│   ├── Preshared Key (Secure)
│   ├── Endpoint
│   ├── Allowed IPs
│   └── Persistent Keepalive
│
├── Validation Results
│
└── Save Profile
```

## 5.4 OpenVPN profile editor

```text
OPENVPN PROFILE
│
├── Profile Name
├── Import .ovpn
├── Server Details
├── Authentication
│   ├── Username
│   ├── Password
│   └── Certificate
├── Advanced Options
├── Validation
└── Save
```

Do not expose unsupported directives as if the app can enforce them.

## 5.5 IKEv2 profile editor

```text
IKEv2 PROFILE
│
├── Profile Name
├── Server Address
├── Remote Identifier
├── Local Identifier
├── Authentication Method
├── Credentials / Certificates
├── On Demand Configuration
├── Validation
└── Save
```

## 5.6 Profile details

```text
PROFILE DETAILS
│
├── Profile Summary
├── Protocol
├── Endpoint
├── DNS Configuration
├── Routing Configuration
├── Last Connected
├── Connection History
├── Edit Profile
├── Export Profile
└── Delete Profile
```

## 5.7 Connection rules

```text
CONNECTION RULES
│
├── Auto Reconnect
├── Privacy Lock
├── Connection on Demand
├── Network Change Behavior
├── Reconnection Policy
├── Conflict Warnings
└── Emergency Reset Shortcut
```

Advanced trusted-network automation is deferred until iOS permissions and capabilities are validated.

---

# 6. DNS TAB

**Purpose:** Configure DNS independently from VPN where supported.

## 6.1 DNS overview

```text
DNS
│
├── Current DNS Status
│   ├── Active / Inactive / Unknown
│   ├── Active Resolver
│   ├── Protocol
│   └── Verification Status
│
├── DNS Mode
│   ├── System DNS
│   ├── Encrypted DNS
│   ├── VPN DNS
│   └── Local Filtering (Conditional)
│
├── Active Resolver Card
│
├── Resolver Library
│
├── DNS Security
│   ├── Strict Encrypted DNS
│   ├── Fallback Policy
│   └── Bootstrap Settings
│
├── DNS Diagnostics
│
└── Advanced DNS Settings
```

## 6.2 DNS mode selection

```text
SELECT DNS MODE

○ System DNS
○ Encrypted DNS Only
○ VPN-Managed DNS
○ Local DNS Filtering
```

Local DNS filtering is displayed only when its enforcement mechanism is supported.

Encrypted DNS-only must not silently establish a VPN tunnel.

## 6.3 Resolver library

```text
DNS RESOLVERS
│
├── Search
├── Selected Resolver
├── Available Presets
├── Custom Resolvers
└── Add Resolver
```

Each resolver row shows:

- Name.
- Endpoint.
- Protocol.
- Selected state.
- Verification information, if available.

Do not claim that a resolver is the fastest or most private without evidence.

## 6.4 Add custom resolver

```text
ADD DNS RESOLVER
│
├── Resolver Name
├── Protocol
│   ├── DoH
│   ├── DoT
│   └── Other Supported Transports
│
├── Endpoint URL / Hostname
├── Port
├── Bootstrap Address
├── IPv4 / IPv6 Settings
├── Validate Configuration
└── Save
```

DoQ, DNSCrypt and DoH3 must appear only when actual transport support exists.

## 6.5 DNS security

```text
DNS SECURITY
│
├── Encryption Requirement
│   ├── Strict Encrypted
│   ├── Encrypted Fallback
│   └── Compatibility Mode
│
├── Fallback Resolver
├── Certificate Validation
├── Bootstrap Policy
├── IPv6 Handling
└── DNS Conflict Information
```

Strict encrypted mode must never silently fall back to plaintext.

## 6.6 DNS diagnostics

```text
DNS DIAGNOSTICS
│
├── Current Configuration
├── Resolver Reachability
├── Observed DNS Behavior
├── DNS Encryption Information
├── IPv4 / IPv6 Results
├── Last Checked
└── Run DNS Check
```

All external checks are user-initiated and disclose relevant third-party requests.

---

# 7. ADBLOCK TAB

**Purpose:** Manage DNS filtering where available, Safari blocking, and user-selected filter subscriptions.

## 7.1 Adblock overview

```text
ADBLOCK
│
├── Protection Summary
│   ├── Overall Status
│   ├── DNS Filtering Status
│   └── Safari Blocking Status
│
├── Protection Surfaces
│   ├── DNS Filtering
│   └── Safari Content Blocker
│
├── Filter Lists
│   ├── Enabled Lists
│   ├── Update Health
│   └── Manage Lists
│
├── Custom Rules
│
├── Available Statistics
│
├── Recent Filter Events
│
└── Advanced Settings
```

Overall status must accurately represent the supported and active enforcement surfaces.

## 7.2 Filter lists screen

```text
FILTER LISTS
│
├── Search Lists
├── Active Lists
├── Recommended Lists
│   ├── HaGeZi
│   ├── OISD
│   └── StevenBlack
├── Custom Lists
├── Add List
└── Update All
```

Recommended lists are unchecked by default.

### Filter list row

```text
List Name
Description
Rule Count
Last Updated
Health Status
Enabled Toggle
```

Selecting a list opens its detail screen.

## 7.3 Filter list details

```text
FILTER LIST DETAILS
│
├── List Name
├── Description
├── Source URL
├── List Format
├── Supported Enforcement Surfaces
├── Total Rules
├── Valid Rules
├── Unsupported Rules
├── Last Successful Update
├── Current Health
├── Update Now
├── Disable List
└── Remove List
```

## 7.4 Filter list health

```text
FILTER HEALTH
│
├── Overall Health
├── Last Successful Compilation
├── Last Successful Installation
├── List Update Failures
├── Rule Capacity
├── Unsupported Rules
├── Last Known Good Configuration
└── Retry / Rollback
```

If a Safari ruleset exceeds supported capacity:

```text
List Too Large

This filter list exceeds the available
Safari content-blocker capacity.

The previous working rules remain active.

[View Details] [Choose Another List]
```

Never silently truncate rules.

## 7.5 Custom rules screen

```text
CUSTOM RULES
│
├── Search Rules
├── Allow Rules
├── Block Rules
├── Add Rule
├── Import Rules
├── Export Rules
└── Test Rule Match
```

Each rule row shows:

- Domain.
- Action: Allow or Block.
- Scope: Exact or Domain + subdomains.
- Enforcement surface.
- Enabled state.

## 7.6 Add custom rule

```text
ADD RULE
│
├── Domain
│
├── Action
│   ├── Allow
│   └── Block
│
├── Scope
│   ├── Domain + Subdomains (Default)
│   └── Exact Domain Only
│
├── Enforcement Surface
│   ├── Supported DNS Filtering
│   └── Safari (when rule type is supported)
│
├── Validation
└── Save Rule
```

### Rule precedence

```text
USER RULES
    ↓
SUBSCRIBED FILTER LISTS
```

Within the user tier, more-specific matches win.

For equally specific user rules, Allow wins.

## 7.7 Test rule match

```text
TEST RULE MATCH
│
├── Enter Domain
├── Select Enforcement Surface
├── Test
│
└── Result
    ├── Allow / Block / No Match
    ├── Winning Rule
    ├── Rule Source
    ├── Matching Scope
    └── Explanation
```

This is a configuration test, not proof that an actual network request was intercepted.

## 7.8 Safari protection

```text
SAFARI PROTECTION
│
├── Safari Status
│   ├── Enabled
│   ├── Disabled
│   ├── Enabled, Not Verified
│   └── Error
│
├── Extension Information
├── Installed Ruleset
├── Last Successful Reload
├── Filter List Health
├── Enablement Instructions
├── Reload Rules
└── Troubleshooting
```

Do not display invented Safari blocked-request counts.

## 7.9 Adblock statistics

```text
ADBLOCK STATISTICS
│
├── Enforcement Surface
├── Available Aggregate Counts
├── Filter List Health
├── Last Updated
└── Statistics Availability Explanation
```

If DNS interception is unavailable:

```text
Detailed DNS statistics unavailable.

This protection mode does not expose
individual DNS filtering events.
```

---

# 8. SETTINGS TAB

## 8.1 Settings overview

```text
SETTINGS
│
├── Privacy & Security
│   ├── Privacy Lock
│   ├── Protection Conflicts
│   ├── Privacy Event History
│   └── Data & Logging
│
├── Network & Diagnostics
│   ├── Checks
│   ├── Network Information
│   └── Compatibility
│
├── Connection Preferences
│   ├── Auto Reconnect
│   ├── Connection Behavior
│   └── Notifications
│
├── Appearance
│   ├── Theme
│   ├── App Icon (if supported)
│   └── Accessibility
│
├── Data Management
│   ├── Backup
│   ├── Restore
│   ├── Export Diagnostics
│   └── Clear Local Data
│
├── Advanced
│   ├── Extension Status
│   ├── Debug Information
│   └── Emergency Reset
│
└── About
    ├── App Version
    ├── Privacy Information
    ├── Licenses
    └── Support Information
```

---

# 9. CHECKS SCREEN

**Location:** Settings → Checks  
**Shortcut:** Home → Run Checks

## 9.1 Checks overview

```text
PRIVACY CHECKS
│
├── Network Overview
│   ├── Public IPv4
│   ├── Public IPv6
│   ├── Network Type
│   └── Connection Status
│
├── IP Intelligence
│   ├── Public IP
│   ├── ASN
│   ├── Network Operator
│   └── Approximate Network Location
│
├── DNS Checks
│   ├── Resolver Observation
│   ├── DNS Encryption
│   └── DNS Configuration
│
├── Connection Checks
│   ├── Route Observation
│   ├── IPv6
│   ├── Reachability
│   └── Connectivity
│
├── Speed Test
│
├── Advanced Diagnostics
│
└── Check History
```

## 9.2 Public IP check

```text
PUBLIC IP
│
├── IPv4 Address
├── IPv6 Address
├── ASN
├── Network Provider
├── Approximate Location
├── Source
├── Last Checked
└── Refresh
```

Potential providers:

- ipify or equivalent for public IP.
- RIPEstat for network ownership and ASN.
- Independent trace endpoint for corroboration.

Each external provider requires appropriate disclosure and consent before its first request.

## 9.3 DNS check

```text
DNS CHECK
│
├── Configured Resolver
├── Observed DNS Behavior
├── Encryption Information
├── Potential Configuration Conflict
├── Evidence Limitations
└── Run Check
```

A configured resolver is not automatically proof that all queries use it.

## 9.4 Speed test

```text
SPEED TEST
│
├── Start Test
├── Data Usage Notice
├── Provider Disclosure
├── Download Speed
├── Upload Speed
├── Latency
├── Jitter (if measured)
├── Test Duration
└── Previous Results
```

Use a supported native measurement integration such as M-Lab NDT7.

The user initiates the test.

## 9.5 Advanced diagnostics

```text
ADVANCED DIAGNOSTICS
│
├── IPv4 / IPv6
├── Network Reachability
├── Route Observations
├── DNSSEC (where verifiable)
├── TLS Checks
├── MTU Information
├── Wi-Fi Information (where permitted)
├── Local Network Discovery (permission-gated)
└── Diagnostic Report
```

Only include measurements that can actually be performed with available iOS APIs.

---

# 10. PRIVACY LOCK SCREEN

**Location:** Settings → Privacy & Security → Privacy Lock

```text
PRIVACY LOCK
│
├── Current Status
├── Enable / Disable
├── Protection Explanation
├── Supported Routing Controls
├── On Demand Behavior
├── Known Platform Exceptions
├── Network Compatibility
├── Recovery Instructions
├── Temporarily Relax Protection
└── Emergency Reset
```

The interface must explain that Privacy Lock is not an absolute kill switch.

## Temporary relaxation

```text
TEMPORARILY RELAX PRIVACY LOCK

Strict routing may be preventing
network access.

Temporarily relaxing supported
VayuSetu-managed restrictions may
allow connectivity.

[Cancel] [Temporarily Relax]
```

Restoration must be visible and user-controlled.

---

# 11. PROTECTION CONFLICTS SCREEN

```text
PROTECTION CONFLICTS
│
├── Overall Compatibility
├── VPN Configuration
├── DNS Configuration
├── Extension Availability
├── Observed Conflicts
├── Potential Limitations
└── Recommended Actions
```

Examples:

- Another VPN configuration may interfere.
- DNS policy is not being applied.
- Safari extension is disabled.
- A required permission is missing.
- A configured feature is unsupported.

Only report conflicts supported by observable evidence.

---

# 12. PRIVACY EVENT HISTORY

```text
PRIVACY ACTIVITY
│
├── Event Timeline
├── Filter Events
│   ├── VPN
│   ├── DNS
│   ├── Safari
│   ├── Adblock
│   └── System
│
├── Event Details
├── Retention Settings
├── Export Redacted Events
└── Clear History
```

Example events:

```text
VPN Connected
VPN Disconnected
DNS Configuration Changed
Safari Extension Enabled
Filter List Updated
Filter Compilation Failed
Privacy Lock Temporarily Relaxed
Emergency Reset Completed
```

Do not record browsing history by default.

---

# 13. DATA & LOGGING SCREEN

```text
DATA & LOGGING
│
├── Privacy Overview
├── Local Data Storage
├── Diagnostic History
├── Event History
├── Detailed DNS Logging
│   └── Off by Default
├── Retention Period
├── Export Data
└── Delete Data
```

Explain what each logging option collects before enabling it.

---

# 14. BACKUP & RESTORE

## Backup screen

```text
BACKUP
│
├── Backup Contents
│   ├── Profile Metadata
│   ├── DNS Presets
│   ├── Filter Subscriptions
│   ├── Custom Rules
│   └── App Preferences
│
├── Include Credentials
│   └── Off by Default
│
├── Encryption Settings
├── Create Backup
└── Save Using Files
```

Credentials can be included only with explicit authorization and encryption.

## Restore screen

```text
RESTORE
│
├── Select Backup
├── Verify Backup
├── Enter Decryption Password
├── Preview Contents
├── Conflict Resolution
└── Restore
```

---

# 15. EMERGENCY RESET

**Location:** Settings → Advanced → Emergency Reset

This is a mandatory v1 recovery screen.

```text
EMERGENCY RESET
│
├── Warning
├── Current VayuSetu Network State
├── Reset Actions
│   ├── Disconnect Managed VPN
│   ├── Disable Managed DNS Configuration
│   ├── Relax Supported Privacy Lock Policy
│   └── Cancel Pending Operations
│
├── Preserved Data
│   ├── Saved VPN Profiles
│   ├── DNS Presets
│   └── Filter Lists
│
├── Confirm Reset
└── Reset Result
```

If iOS requires additional manual steps, display them clearly.

Do not claim that the app can reset configurations it does not control.

---

# 16. EXTENSION STATUS SCREEN

```text
EXTENSION STATUS
│
├── VPN Packet Tunnel
│   ├── Availability
│   ├── Current State
│   └── Last Error
│
├── Safari Content Blocker
│   ├── Enabled State
│   ├── Ruleset Readiness
│   └── Last Reload
│
├── DNS Extension
│   ├── Availability
│   ├── Entitlement Support
│   └── Current State
│
└── Diagnostic Details
```

The DNS proxy section appears only if that extension is actually available.

---

# 17. APPEARANCE SCREEN

```text
APPEARANCE
│
├── Theme
│   ├── Dark
│   ├── Light (if implemented)
│   └── System
│
├── Accent Appearance
├── App Icon (if supported)
├── Reduce Motion
├── Haptic Feedback
└── Accessibility Information
```

The initial design should prioritize the dark theme.

---

# 18. NOTIFICATIONS SCREEN

```text
NOTIFICATIONS
│
├── VPN Connection Changes
├── VPN Connection Failures
├── DNS Configuration Failures
├── Filter List Update Failures
├── Privacy Lock Warnings
├── Notification Permissions
└── Notification Preview Settings
```

Notifications must represent real events.

No advertising or promotional notifications.

---

# 19. ONBOARDING ARCHITECTURE

First launch should explain the app without overwhelming the user.

```text
ONBOARDING
│
├── Welcome
│
├── Privacy Overview
│   ├── Local-First
│   ├── No Mandatory Account
│   └── No Default Telemetry
│
├── Protection Overview
│   ├── VPN
│   ├── DNS
│   └── Safari / Adblock
│
├── Add First VPN Profile (Optional)
│
├── Configure DNS (Optional)
│
├── Safari Setup (Optional)
│
├── Permissions Explanation
│
└── Open VayuSetu
```

The user can skip optional setup.

Do not request every permission during onboarding.

Ask for permissions when the corresponding feature is used.

---

# 20. EMPTY, LOADING, ERROR & PERMISSION STATES

Every major screen needs dedicated states.

## Empty state examples

**Profiles**

```text
No VPN Profiles

Import a configuration to connect
using your own VPN provider.

[Add Profile]
```

**Filter Lists**

```text
No Filter Lists Enabled

Choose the lists you want to use.
Nothing is enabled automatically.

[Browse Lists]
```

**Activity**

```text
No Recent Activity

Protection events will appear here
when they occur.
```

## Permission state

```text
Permission Required

VayuSetu needs the applicable iOS
permission to configure this feature.

[Continue]
```

## Error state

```text
Unable to Apply Configuration

Your previous working configuration
has been preserved.

[Retry] [View Details]
```

Avoid generic error messages that provide no recovery path.

---

# 21. COMPLETE SCREEN NAVIGATION TREE

```text
VayuSetu
│
├── ONBOARDING
│   ├── Welcome
│   ├── Privacy Overview
│   ├── Protection Overview
│   ├── First VPN Setup
│   ├── DNS Setup
│   ├── Safari Setup
│   └── Finish
│
├── HOME
│   ├── Connection Details
│   │   ├── Connection Statistics
│   │   ├── Routing Information
│   │   └── Connection Events
│   │
│   ├── VPN Status → Connection Details
│   ├── DNS Status → DNS Overview
│   ├── Safari Status → Safari Protection
│   ├── Adblock Status → Adblock Overview
│   ├── Run Checks → Settings / Checks
│   ├── Switch Profile → Profiles
│   └── Recent Activity → Privacy Activity
│
├── PROFILES
│   ├── Profile List
│   ├── Search / Sort
│   ├── Add Profile
│   │   ├── Import File
│   │   ├── Scan QR
│   │   └── Manual Setup
│   │       ├── WireGuard
│   │       ├── OpenVPN
│   │       └── IKEv2
│   │
│   ├── Profile Details
│   ├── Edit Profile
│   ├── Export Profile
│   └── Connection Rules
│       ├── Auto Reconnect
│       ├── Privacy Lock
│       └── On Demand
│
├── DNS
│   ├── DNS Overview
│   ├── Select DNS Mode
│   ├── Resolver Library
│   │   ├── Resolver Details
│   │   └── Add Custom Resolver
│   │
│   ├── DNS Security
│   │   ├── Encryption Policy
│   │   ├── Fallback Policy
│   │   └── Bootstrap Settings
│   │
│   ├── DNS Diagnostics
│   └── Advanced DNS Settings
│
├── ADBLOCK
│   ├── Adblock Overview
│   ├── Filter Lists
│   │   ├── Recommended Lists
│   │   ├── Custom Lists
│   │   ├── List Details
│   │   └── Filter Health
│   │
│   ├── Custom Rules
│   │   ├── Add Allow Rule
│   │   ├── Add Block Rule
│   │   ├── Edit Rule
│   │   └── Test Rule Match
│   │
│   ├── Safari Protection
│   │   ├── Extension Status
│   │   ├── Ruleset Status
│   │   └── Troubleshooting
│   │
│   ├── Adblock Statistics
│   └── Advanced Filtering Settings
│
└── SETTINGS
    ├── Privacy & Security
    │   ├── Privacy Lock
    │   ├── Protection Conflicts
    │   ├── Privacy Activity
    │   └── Data & Logging
    │
    ├── Network & Diagnostics
    │   ├── Checks
    │   │   ├── Public IP
    │   │   ├── DNS Check
    │   │   ├── Speed Test
    │   │   ├── Advanced Diagnostics
    │   │   └── Check History
    │   │
    │   ├── Network Information
    │   └── Compatibility
    │
    ├── Connection Preferences
    │   ├── Auto Reconnect
    │   └── Notifications
    │
    ├── Appearance
    ├── Data Management
    │   ├── Backup
    │   ├── Restore
    │   ├── Export Diagnostics
    │   └── Clear Local Data
    │
    ├── Advanced
    │   ├── Extension Status
    │   ├── Debug Information
    │   └── Emergency Reset
    │
    └── About
        ├── App Version
        ├── Privacy Information
        ├── Licenses
        └── Support
```

---

# 22. SCREEN IMPLEMENTATION STRUCTURE

Recommended SwiftUI feature organization:

```text
VayuSetuIOS/
│
├── App/
│   ├── VayuSetuApp.swift
│   ├── AppCoordinator.swift
│   └── AppState.swift
│
├── Navigation/
│   ├── MainTabView.swift
│   ├── AppRoutes.swift
│   └── NavigationCoordinator.swift
│
├── Home/
│   ├── HomeView.swift
│   ├── HomeViewModel.swift
│   ├── ConnectionCard.swift
│   ├── SessionMetricsView.swift
│   ├── ProtectionGridView.swift
│   ├── QuickActionsView.swift
│   └── RecentActivityView.swift
│
├── Profiles/
│   ├── ProfilesView.swift
│   ├── ProfilesViewModel.swift
│   ├── ProfileDetailsView.swift
│   ├── AddProfileView.swift
│   ├── WireGuardEditorView.swift
│   ├── OpenVPNEditorView.swift
│   ├── IKEv2EditorView.swift
│   └── ConnectionRulesView.swift
│
├── DNS/
│   ├── DNSView.swift
│   ├── DNSViewModel.swift
│   ├── DNSModeView.swift
│   ├── ResolverLibraryView.swift
│   ├── ResolverEditorView.swift
│   ├── DNSSecurityView.swift
│   └── DNSDiagnosticsView.swift
│
├── Adblock/
│   ├── AdblockView.swift
│   ├── AdblockViewModel.swift
│   ├── FilterListsView.swift
│   ├── FilterListDetailsView.swift
│   ├── FilterHealthView.swift
│   ├── CustomRulesView.swift
│   ├── RuleEditorView.swift
│   ├── RuleMatchTestView.swift
│   ├── SafariProtectionView.swift
│   └── AdblockStatisticsView.swift
│
├── Checks/
│   ├── ChecksView.swift
│   ├── ChecksViewModel.swift
│   ├── PublicIPView.swift
│   ├── DNSCheckView.swift
│   ├── SpeedTestView.swift
│   └── AdvancedDiagnosticsView.swift
│
├── Settings/
│   ├── SettingsView.swift
│   ├── PrivacyLockView.swift
│   ├── ProtectionConflictsView.swift
│   ├── PrivacyActivityView.swift
│   ├── DataLoggingView.swift
│   ├── BackupRestoreView.swift
│   ├── EmergencyResetView.swift
│   ├── ExtensionStatusView.swift
│   ├── AppearanceView.swift
│   ├── NotificationsView.swift
│   └── AboutView.swift
│
└── DesignSystem/
    ├── Components/
    ├── Icons/
    ├── Typography/
    ├── Colors/
    ├── Spacing/
    └── Animations/
```

---

# 23. SCREEN ARCHITECTURE RULES

Every VayuSetu screen must follow these principles:

**1. Native-first:** Use SwiftUI navigation, sheets, lists, controls, and system integrations.

**2. Truthful status:** Show observed protection state, not merely whether a setting is switched on.

**3. Clear ownership:** Each screen controls only its corresponding feature. Home summarizes; it does not duplicate every configuration setting.

**4. Independent protection:** VPN, DNS, and Safari are independently configurable wherever iOS supports them.

**5. No fabricated metrics:** Missing measurements must display Unavailable or Unknown.

**6. Privacy-first:** No automatic telemetry, browsing-history collection, or unnecessary external requests.

**7. Recoverability:** Every configuration failure must have a clear recovery action. Emergency Reset must remain accessible.

**8. Capability-aware:** Unsupported features must not appear as working controls.

**9. Consistent components:** All screens use the same icon family, spacing system, typography, cards, status indicators, and navigation conventions.

**10. Native in-app experience:** Normal configuration, diagnostics, API results, and feature management remain inside VayuSetu. Only unavoidable Apple-controlled permission and Settings flows may leave the app.

---

**Final architecture:** Five native tabs, with Home as the control center, Profiles for VPN, DNS for resolver configuration, Adblock for filtering and Safari, and Settings for privacy, diagnostics, recovery, and application preferences.
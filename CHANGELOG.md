# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.8.12] - 2026-08-10

### Changed
- Clicking the public IP menu item opens [BrowserLeaks IP](https://browserleaks.com/ip) (the same page used for lookup) instead of copying the address.

---

## [0.8.11] - 2026-08-10

### Performance
- Coalesce `networkInfoDidChange` to UI-relevant snapshot changes only (fewer menu rebuilds).
- Coalesce open-menu rebuilds to one per run-loop turn.
- Skip status-bar icon reapplication when presentation is unchanged.
- Skip GeoIP re-fetch on connect when a fresh IP is already cached.

---

## [0.8.10] - 2026-08-10

### Fixed
- Open menu now updates live when GeoIP finishes (no need to close/reopen). Updates are event-driven via `networkInfoDidChange` only while the menu is open — no background polling.
- Stuck “Fetching network info…” caused by joining an already-finished fetch task after re-arming `isLoading`.

---

## [0.8.9] - 2026-08-10

### Fixed
- Network info menu no longer flashes “unavailable” while GeoIP is still loading. Shows “Fetching network info…” until the request finishes, then updates the open menu with the IP.

---

## [0.8.8] - 2026-08-10

### Fixed
- Public IP / geo lookup now uses [BrowserLeaks](https://browserleaks.com/ip) instead of `ifconfig.co` and Cloudflare. Split-tunnel VPN routes often send those “what is my IP” endpoints direct, which showed the ISP address instead of the VPN exit.

---

## [0.8.7] - 2026-07-31

### Refactor / slim
- Merged `StatusItemViewModel` into `StatusBarController` (no fallback poll timer, no connecting animation timer)
- Removed `ImageCache`; SF Symbols created inline
- `VPNConfigurationLoader` is SC-only (dropped private NEConfigurationManager path)
- GeoIP: two providers only (ifconfig.co → Cloudflare)
- Settings window built lazily; dropped dead “update interval” UI; thinner hotkey settings
- Removed post-toggle menu rebuild delay

---

## [0.8.6] - 2026-07-31

### Removed / slimmed
- Dead modules: connection history, usage statistics, sound feedback, per-connection hotkeys
- Continuous status timer (event-driven status via `ne_session` only)
- Snapshot-testing dependency and skip-only test targets
- Unused protocols (`HotkeyManagerProtocol`, `NotificationManagerProtocol`), Comparable extension
- Launch-time notification auth when notifications disabled

### Changed
- Smaller HotkeyManager / NotificationManager / VPNManager / SettingsManager
- Menu still opens immediately; list reload throttled in background

---

## [0.8.5] - 2026-07-31

### Fixed
- Network info no longer stuck on “Fetching…”: multi-provider GeoIP (`ifconfig.co`, Cloudflare, `ipwho.is` fallback), short timeout, wait up to 2s before opening the menu, keep local VPN interfaces while public IP loads, show “unavailable” instead of infinite fetching when all providers fail

---

## [0.8.4] - 2026-07-30

### Fixed
- Removed ghost/stale VPN entries after delete: enumerate only services in the **current network set** (same scope as `scutil --nc list`), force-reload on menu open, prune orphaned `ne_session`s, and clear last-used ID / hotkeys for missing configs
- Cancel in-flight connect/retry tasks on disconnect so a delayed retry cannot reconnect without user intent
- Prefer currently active VPN for left-click/hotkey toggle (no accidental switch to last-used profile)
- Race: ignore stale `processLoadedConnections` results that could reintroduce a deleted VPN

### Changed / Performance
- Prefer SystemConfiguration over `NEConfigurationManager` (skip broken IPC after first failure)
- Timer path: status-only refresh most ticks; full list reload every 90s (was effectively every 15s)
- Build menu only when opened (no continuous rebuild on every status publish)
- Debounce GeoIP fetches; only on connected/disconnected; remove write-only stats flush on quit
- Strip unnecessary entitlements (JIT, disable-library-validation, location)
- Safer session create (reentrancy guard) and privacy-redacted logging for connection IDs

---

## [0.8.3] - 2026-07-30

### Fixed
- Fixed VPN list and status failing on macOS 26/27 when `NEConfigurationManager` returns `IPC failed` (NEConfigurationErrorDomain code 11). The loader now falls back to SystemConfiguration (`SCNetworkServiceCopyAll`), which still enumerates VPN services with the same UUIDs used by `ne_session` / `scutil --nc`.

---

## [0.8.2] - 2026-03-18

### Fixed
- Switched geolocation provider from HTTP to HTTPS to prevent IP address and location data from being transmitted in plain text
- Fixed observer leak in AppDelegate — notification observers are now properly removed on app termination
- Fixed VPN session statistics being lost when the app quits while a connection is active — duration is now recorded before shutdown
- Fixed potential use-after-deallocation in StatusBarController by removing unnecessary async dispatch in deinit
- Fixed double-cleanup crash risk in HotkeyManager when cleanup is called both from app termination and deinit
- Fixed double observer removal in VPNManager by properly nullifying the observer token in deinit
- Fixed VPN configuration loader silently returning empty results on recursive loading — it now reports a proper error
- Added logging for unknown key codes to aid debugging when hotkey registration uses unexpected values

### Changed
- Removed unnecessary App Transport Security exception for ip-api.com since the new provider uses HTTPS
- Removed redundant dirty-tracking flag in connection history that served no practical purpose

---

## [0.8.1] - 2026-02-22

### Fixed
- Network info now displays reliably after VPN connection by switching to ip-api.com as the sole geolocation provider (removed ipapi.co fallback logic that caused intermittent failures)

---

## [0.8.0] - 2026-02-20

### Added
- Per-connection hotkeys: assign individual keyboard shortcuts to specific VPN connections for quick toggling without opening the menu; shortcuts are shown next to connection names in the context menu
- Network info in menu: when VPN is connected, the context menu shows public IP address, country, and city — click the IP line to copy it to clipboard
- Automatic network info refresh after VPN status changes (with short delay); placeholder "Obtaining network info…" is shown while loading

### Removed
- "Disconnect All" menu item and related functionality, since only one connection can be active at a time

### Fixed
- Menu bar icon animation now stops immediately after VPN connects or disconnects (previously delayed up to 15 seconds due to missed status notifications)
- IP address and country info are now hidden when no VPN is connected
- Switching to a new VPN connection now properly disconnects the currently active one before connecting
- Connection hotkeys settings list now displays with proper visual list style, row separators, and the description text is fully visible

---

## [0.7.0] - 2026-01-17

### Added
- Universal binary support for both Apple Silicon and Intel Macs - one download works on all Mac models without needing separate builds
- Automatic security attribute handling during Homebrew installation - no manual steps required, the Cask automatically removes quarantine attributes
- Comprehensive troubleshooting documentation in README for cases when the app doesn't start

### Changed
- Improved binary discovery mechanism for better compatibility across different build environments and build paths
- Enhanced installation documentation with clearer step-by-step troubleshooting instructions
- Updated Homebrew Cask to automatically handle security settings via postflight script

### Fixed
- Fixed app crashes on launch that occurred when the app tried to initialize system components on some systems
- Fixed missing translations in menu items, settings, and error messages - all UI strings now properly display in English, Russian, and Chinese (Simplified)
- Fixed localization support by ensuring translation files are correctly copied to the app bundle
- Fixed connection status synchronization issues that could cause the menu bar icon to show incorrect VPN state
- Fixed memory management issues that could lead to app instability and unresponsiveness over time
- Fixed infinite recursion that could occur when loading VPN configurations, which could cause the app to hang
- Fixed crash when handler blocks were deallocated prematurely by reverting to a more stable approach
- Fixed compilation errors in settings views that prevented the app from building

---

## [0.6.0] - 2026-01-13

### Added
- Connection status reset mechanism that automatically recovers from failed connection attempts without requiring manual intervention
- Fallback timer system for status updates when system APIs are temporarily unavailable, ensuring the app continues to work reliably
- Comprehensive test coverage for edge cases and error scenarios to improve overall stability

### Changed
- Improved connection status synchronization to prevent race conditions that could show incorrect connection state
- Enhanced timeout handling for disconnect operations to prevent the app from getting stuck in disconnecting state
- Better error recovery when connections fail unexpectedly - the app now automatically resets to a known good state
- Updated documentation comments to English following Swift API guidelines for better code maintainability

### Fixed
- Fixed race conditions that could cause incorrect connection status to be displayed in the menu bar
- Fixed memory leaks during disconnect timeout handling that could cause the app to consume increasing amounts of memory
- Fixed infinite recursion when loading VPN configurations that could cause the app to hang or crash
- Fixed duplicate event handler setup that could cause multiple notifications for the same event
- Fixed connection status not resetting properly after connection failures, which could leave the app in an inconsistent state
- Fixed hotkey manager issues that could cause crashes after hotkey registration, especially when switching between different hotkey combinations
- Fixed Homebrew Cask installation by moving Casks folder to repository root for proper tap compatibility
- Fixed unsigned app blocking by adding automatic quarantine attribute removal in Homebrew postflight script

---

## [0.5.3] - 2026-01-02

### Added
- Homebrew Cask support for easy installation and automatic updates via `brew install --cask vpn-bar` - no need to manually download and install
- Automatic Cask formula updates on each release via GitHub Actions - SHA256 checksums are updated automatically
- Homebrew installation instructions in README for users who prefer package managers

### Changed
- README fully translated to English for better international accessibility and understanding
- Simplified installation process with fewer manual steps required
- Updated GitHub repository URLs in documentation to use correct repository name

### Removed
- Redundant installation scripts that are no longer needed (icon creation scripts, redundant test scripts)
- Unnecessary scripts that duplicated functionality already available in Makefile and CI

---

## [0.5.2] - 2025-12-28

### Added
- Sound feedback when VPN connection is established successfully - provides audio confirmation of successful connection
- Icon caching system for faster menu rendering and smoother interface when switching between VPN connections
- Cleanup methods for proper resource management when the app shuts down or connections are terminated

### Changed
- Optimized menu update performance for faster response times when VPN status changes
- Improved memory usage by removing unused code and features that were consuming resources unnecessarily
- Enhanced app stability through better resource management and cleanup of connections
- Consolidated settings manager usage to use dependency injection consistently throughout the app

### Removed
- Removed unused notification types and monitoring components that were no longer needed
- Removed redundant code and duplicate functionality to simplify the codebase and improve maintainability
- Removed duplicate event notifications that could cause confusion

### Fixed
- Fixed inconsistent settings manager usage that could cause configuration issues when settings were changed
- Fixed duplicate event notifications that could appear multiple times for the same event
- Fixed memory management issues in connection cleanup that could lead to resource leaks

---

## [0.5.1] - 2025-12-27

### Changed
- Optimized status update frequency for better performance and reduced system resource usage
- Improved image caching mechanism for faster menu icon rendering when displaying VPN connection status
- Consolidated timer management to reduce resource usage by using a single timer instead of multiple timers
- Streamlined VPN status monitoring architecture to make it more efficient and easier to maintain

### Fixed
- Fixed duplicate code in VPN configuration loading that could cause unnecessary processing
- Fixed redundant menu update delays that could make the interface feel sluggish
- Fixed duplicate notification checks that were being performed multiple times unnecessarily

---

## [0.5.0] - 2025-12-27

### Added
- Automatic VPN configuration discovery - the app now automatically detects new VPN connections every 30 seconds without requiring a restart
- Last used VPN connection memory - the app remembers which VPN you used last and uses it as the default for quick toggling
- Automatic connection selection - toggle button now works intelligently with your preferred VPN automatically

### Changed
- Improved connection selection logic when multiple VPNs are available - the app now makes smarter choices about which VPN to use
- Enhanced toggle behavior to work intelligently with the last used connection, making it more convenient for users with multiple VPNs
- Better handling of VPN configuration changes without requiring app restart - new or removed VPNs are detected automatically
- Streamlined code for saving and retrieving the last used connection to improve reliability

---

## [0.4.0] - 2025-12-06

### Added
- "About" section in settings window with app information, version details, author information, and direct link to GitHub repository for easy access to source code and issues
- Chinese (Simplified) language support - the app now supports three languages: English, Russian, and Chinese (Simplified) for broader international accessibility
- Enhanced hotkey recording interface with visual display of modifier keys (Command, Option, Control, Shift) so you can see exactly what keys are being recorded
- Inline hotkey validation to prevent conflicts with system shortcuts - the app now warns you if a hotkey combination is already used by macOS
- Clear button in hotkey settings for easy reset when you want to remove or change your hotkey configuration
- StatusItemViewModel for better management of menu bar icon state and updates

### Changed
- More compact settings window layout with reduced padding for better space utilization and a cleaner appearance
- Improved context menu positioning - right-click menu now properly aligns with the menu bar for better accessibility and visual consistency
- Complete localization of all user-facing strings including error messages and descriptions - everything you see is now translated
- Better consistency of interface text across all supported languages - translations are now more uniform and professional

### Fixed
- Fixed duplicate entries in Chinese localization that could cause confusion
- Fixed integration test initialization issues that could cause test failures

---

## [0.3.0] - 2025-11-26

### Added
- Launch at Login support for macOS 13+ - automatically start the app when you log in so VPN management is always available
- "Disconnect All" button in the menu for quickly disconnecting all active VPN connections with a single click
- Connection animation on menu bar icon - visual feedback during connect/disconnect operations so you can see when the app is working
- Hotkey validation to prevent conflicts with system keyboard shortcuts - the app now checks if your chosen hotkey is available
- Improved VoiceOver support for better accessibility - the app is now more usable for users with visual impairments
- Informative messages when no VPN configurations are found in system settings - clear guidance on what to do next
- Quick link to network settings from the menu for easy access to system VPN configuration
- AppConstants for centralized configuration management
- Notification extensions for better notification handling

### Changed
- Migrated to modern UserNotifications API for better compatibility with macOS 11+ and improved notification reliability
- Optimized VPN status update frequency to reduce system resource usage while maintaining responsiveness
- Improved code organization with better separation of concerns and dependency injection through protocols
- Removed deprecated API calls that could cause warnings and potential future compatibility issues

### Fixed
- Fixed potential memory leaks in hotkey manager that could cause the app to consume increasing amounts of memory over time
- Fixed app crashes caused by force unwrapping optional values that could be nil in certain situations
- Fixed notification system compatibility issues on older macOS versions by using the modern API
- Fixed deprecated API usage warnings by updating to current macOS APIs
- Fixed animation logic for connecting and disconnecting states to provide smoother visual feedback

---

## [0.2.0] - 2025-11-17

### Added
- Global hotkeys support - configure keyboard shortcuts to toggle VPN from any application, making VPN management accessible from anywhere
- System notifications when VPN connects or disconnects - stay informed about connection status even when the app is in the background
- Enhanced visual status indicators in the menu bar for better visibility - semi-transparent icon when disconnected, colored shield when connected
- Visual distinction between active and inactive VPN states - clear visual feedback about connection status at a glance

---

## [0.1.1] - 2025-11-16

### Added
- English and Russian language support - the app is now available in two languages for broader accessibility
- Localization system for all interface text - all user-facing strings are now translatable
- Internationalization infrastructure for future language additions - the app is ready for additional languages

### Changed
- All user-facing strings moved to localization files for easier translation and maintenance
- Improved experience for non-Russian speakers by providing English interface

---

## [0.1.0] - 2025-11-16

### Added
- Initial release of VPN Bar
- Basic VPN connection management from menu bar - quick access to all your VPN connections
- Quick connect/disconnect functionality with single click - no need to open System Settings
- Support for multiple VPN configurations - manage all your VPNs from one place
- Menu bar status indicator showing connection state - always visible connection status
- Context menu with list of all available VPN connections - right-click to see all options
- Visual indicators for connected/disconnected status in menu - clear status at a glance

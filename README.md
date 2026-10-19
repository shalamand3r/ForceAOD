# ForceAOD 🌙
### Enable Apple’s native Always-On Display on unsupported devices.

Includes the native AOD panel with wallpaper and notification options. Always-On StandBy should work too on iOS 17.0+.

---

## Compatibility & Installation

Targets iOS 16.0+. Tested on iPhone 13 Pro on iOS 17.0. iOS 16, 18 and 26 are untested. YMMV.

Download from [my Sileo repo](https://shalamand3r.github.io), install and respring.

Warning: this tweak will impact battery life, especially on non-ProMotion displays. Recommended only for iPhone 13 Pro for now (can theoretically drop to 10Hz).

## How it Works

ForceAOD overrides the AOD capability checks in memory and uses Apple’s display system with live rendering. It doesn’t edit the MobileGestalt file or change the physical display refresh rate. Devices that already report native AOD support are left alone.

The main AOD switch stays On while the tweak is installed. Low Power Mode temporarily disables AOD (this is native behavior).

## Building

Build with [Theos](https://theos.dev):

```sh
gmake package FINALPACKAGE=1
```

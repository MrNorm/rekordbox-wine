# Wine cannot be built with link-time optimisation: LTO drops the symbols that
# ntdll's hand-written syscall dispatcher references from assembly, and the
# build dies with "undefined reference to init_syscall_frame".
%global _lto_cflags %{nil}
# The payload includes a whole Wine runtime whose PE half is not ELF;
# build-wine-runtime.sh strips the unix half itself. Requires are listed by
# hand below: the dependency generator would demand Wine's own private
# libraries (ntdll.so), and most system libraries are dlopen()ed by soname,
# which it cannot see.
%global __os_install_post %{nil}
%global debug_package %{nil}
AutoReqProv:    no

Name:           rekordbox-wine
Version:        0.3.0
Release:        1%{?dist}
Summary:        rekordbox 7.2.x with a DDJ-400 on Linux, on its own patched Wine

License:        LGPL-2.1-or-later AND MIT
URL:            https://github.com/MrNorm/rekordbox-wine
Source0:        %{name}-%{version}.tar.gz
ExclusiveArch:  x86_64

BuildRequires:  python3 curl flex bison autoconf perl mingw64-gcc mingw32-gcc
BuildRequires:  libX11-devel libXext-devel libXrandr-devel libXcomposite-devel
BuildRequires:  libXfixes-devel libXi-devel libXcursor-devel libXinerama-devel
BuildRequires:  libXrender-devel libXxf86vm-devel libxkbcommon-devel wayland-devel
BuildRequires:  alsa-lib-devel pulseaudio-libs-devel dbus-devel freetype-devel
BuildRequires:  fontconfig-devel gnutls-devel libusb1-devel systemd-devel libpcap-devel
BuildRequires:  libglvnd-devel mesa-libEGL-devel vulkan-headers vulkan-loader-devel
BuildRequires:  gstreamer1-plugins-base-devel

# No wine package: this one carries its own at /usr/lib/rekordbox-wine/wine.
# These are the system libraries that runtime links or dlopen()s for the
# capabilities rekordbox uses; bin/rbw-runtime-check verifies them on launch.
Requires:       gnutls libglvnd-glx libglvnd-egl libX11 libXext libXi libXrandr
Requires:       libXrender libXcursor libXcomposite libXinerama libXfixes libXxf86vm
Requires:       libxkbcommon libwayland-client freetype fontconfig dbus-libs
Requires:       alsa-lib libusb1 systemd-libs alsa-utils python3
Recommends:     rtkit
Suggests:       pipewire-alsa

%description
A pinned Wine (11.18 with the wine-staging patchset) with the fixes rekordbox
needs compiled in, and a launcher that verifies every one of them before
starting rekordbox. This package does NOT contain rekordbox itself, which is
proprietary and must be downloaded from rekordbox.com.

Ten Wine defects are fixed, without which the application paints a single frame
and freezes, has no working audio device, cannot open its File menu, cannot see
a USB stick, and rejects the controller it has just detected.

The Wine lives in /usr/lib/rekordbox-wine/wine. The distribution's Wine is
neither used nor modified, so a Wine upgrade cannot break rekordbox.

%prep
%autosetup

%build
cd %{_builddir}/%{name}-%{version}
# Build inside the rpm build tree, never a developer's ~/.cache, which carries
# diagnostic code on top of the patch series.
export RBW_WINE_BUILD="%{_builddir}/wine-build"
unset CFLAGS CXXFLAGS LDFLAGS
./bin/build-wine-runtime.sh build/runtime

%install
cd %{_builddir}/%{name}-%{version}
# No pacman here, so no alpm hook.
RBW_ALPM_HOOK=0 packaging/install-tree.sh %{buildroot}

%check
cd %{_builddir}/%{name}-%{version}
# Every patched component carries a marker; a stock one loads perfectly and
# behaves as though nothing was fixed. The list lives in one place.
packaging/verify-tree.sh build/runtime

%post
cat <<'MSG'
rekordbox-wine is installed. It runs rekordbox on its own Wine, in
/usr/lib/rekordbox-wine/wine, and never uses or modifies your system Wine.

Two commands, then you are done. Neither needs root.

  1. Install rekordbox itself. It is proprietary and not included, so this
     downloads it from rekordbox.com and installs it:

       rekordbox-wine --install

     Add --latest to skip the version prompt, or pass an installer you already
     have. You sign in with your own AlphaTheta account.

  2. Start it:

       rekordbox-wine

That is the whole setup. The launcher checks its Wine, cleans stale settings
out of the prefix and applies the audio settings every time it starts, so it
repairs itself if something drifts. You can also start it from your
application menu ("rekordbox (Wine)").

USING A DDJ-400? Two one-off system steps, because they need root or a replug:

  - Replug the controller once, so the udev rule this package installed
    applies to it.
  - Reboot, or run "sudo modprobe -r snd_seq_dummy", so the module blacklist
    takes effect. Without this rekordbox binds an ALSA loopback instead of
    your controller.

  "rekordbox-wine --check" tells you if either is still outstanding.

UPDATES: nothing to do.
  - rekordbox updates itself: the launcher always starts the newest version.
  - Your distribution updates Wine: nothing changes. rekordbox does not use it.

VERIFY ANYTHING:
       rekordbox-wine --check                          report, change nothing
       /usr/share/rekordbox-wine/bin/verifyloaded.sh   confirm the RUNNING
                                                       process uses the fixes

WHAT WORKS, measured: the window renders and repaints (stock Wine paints one
frame and freezes); library, waveforms and two decks at 1.000x; the File menu
and EXPORT mode; DDJ-400 exclusive audio at 44100 Hz with jog wheels and LEDs;
PC MASTER OUT with no dropouts; and USB export.

NOT PROVEN: no exported stick has been read by a real CDJ, and the DDJ-400 has
not been through a full performance pass. See GOLD-STATUS.md in
/usr/share/doc/rekordbox-wine for every claim and its evidence.

MSG

%files
%{_bindir}/rekordbox-wine
/usr/lib/rekordbox-wine/
%{_datadir}/%{name}/
%{_datadir}/applications/%{name}.desktop
/usr/lib/udev/rules.d/60-pioneer-ddj.rules
/usr/lib/modprobe.d/%{name}.conf
/usr/lib/modules-load.d/%{name}.conf
%doc %{_datadir}/doc/%{name}/

%changelog
* Sat Oct 17 2026 rekordbox-wine maintainers <nobody@example.invalid> - 0.3.0-1
- Ship a pinned, patched Wine 11.18-staging runtime instead of patching the
  system Wine; distribution Wine upgrades no longer affect rekordbox.
* Thu Aug 20 2026 rekordbox-wine maintainers <nobody@example.invalid> - 0.2.0-1
- Initial packaging: ten Wine fixes, launcher, udev and module configuration.

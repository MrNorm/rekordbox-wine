# Wine cannot be built with link-time optimisation: LTO drops the symbols that
# ntdll's hand-written syscall dispatcher references from assembly, and the
# build dies with "undefined reference to init_syscall_frame".
%global _lto_cflags %{nil}
# The payload is prebuilt Wine libraries (PE and unix) for one Wine version.
# Stripping them, or letting the shlib scanner generate dependencies from them,
# has no useful meaning here.
%global __os_install_post %{nil}
%global debug_package %{nil}
%global __requires_exclude ^lib(wine|pipewire|asound).*$

Name:           rekordbox-wine
Version:        0.2.0
Release:        1%{?dist}
Summary:        Wine fixes and launcher for running rekordbox 7.2.x with a DDJ-400

License:        LGPL-2.1-or-later AND MIT
URL:            https://github.com/REPLACE-ME/rekordbox-wine
Source0:        %{name}-%{version}.tar.gz
ExclusiveArch:  x86_64

BuildRequires:  clang lld python3 curl flex bison
BuildRequires:  libX11-devel libXext-devel libXrandr-devel libXcomposite-devel
BuildRequires:  libXfixes-devel libXi-devel libXcursor-devel
BuildRequires:  alsa-lib-devel dbus-devel freetype-devel gnutls-devel libusb1-devel

Requires:       wine >= 11.0
Requires:       alsa-lib alsa-utils python3
Recommends:     rtkit
Suggests:       pipewire-alsa wine-mono wine-gecko

%description
Patched Wine components and a launcher that verifies every one of them before
starting rekordbox. This package does NOT contain rekordbox itself, which is
proprietary and must be downloaded from rekordbox.com.

Ten Wine defects are fixed, without which the application paints a single frame
and freezes, has no working audio device, cannot open its File menu, cannot see
a USB stick, and rejects the controller it has just detected.

Four of the fixes are unix-side Wine libraries that cannot be overridden from
inside a prefix. They are installed to %{_datadir}/%{name}/winedll and applied
by a separate script, because overwriting files owned by the wine package would
be a file conflict and would be undone by every wine upgrade.

%prep
%autosetup

%build
cd %{_builddir}/%{name}-%{version}
# Build inside the rpm build tree, never a developer's ~/.cache, which carries
# diagnostic code on top of the patch series.
#
# --define "reuse_artifacts 1" skips the Wine compile and packages the existing
# artifacts/ instead. %check still verifies every marker, so this cannot ship a
# stock component -- it only avoids recompiling Wine once per package format.
%if 0%{?reuse_artifacts}
echo "reuse_artifacts: skipping the Wine build, %%check still verifies markers"
%else
export RBW_WINE_BUILD="%{_builddir}/wine-build"
./bin/build-patched-dlls.sh
%endif

%install
cd %{_builddir}/%{name}-%{version}
packaging/install-tree.sh %{buildroot}

%check
cd %{_builddir}/%{name}-%{version}
# Every patched component carries a marker. A missing marker means the build
# silently produced a stock component, which loads perfectly and behaves as
# though nothing was fixed.
set -e
wine_ver=$(wine --version | sed 's/^wine-//;s/ .*//')
for spec in \
  "artifacts/dxgi-patched-native-${wine_ver}.dll:RBW-PATCH" \
  "artifacts/mmdevapi-patched-native-${wine_ver}.dll:RBW-MMDEV" \
  "artifacts/setupapi-patched-native-${wine_ver}.dll:PhysicalDeviceObjectName" \
  "artifacts/winedll/winealsa.so:RBW-EVENT3" \
  "artifacts/winedll/winex11.so:RBW-POPUP" \
  "artifacts/winedll/mountmgr.so:RBW-REMOVABLE" \
  "artifacts/winedll/mountmgr.sys:RBW-VOLNODE" \
  "artifacts/winedll/wineusb.sys:RBW-USBHCD" \
  "artifacts/winedll/wineusb.so:RBW-USBHCD" ; do
  f="${spec%:*}"; m="${spec##*:}"
  test "$(strings -a "$f" | grep -c -- "$m" || true)" -gt 0 \
    || { echo "ERROR: $f has no '$m' marker - stock build?"; exit 1; }
done

%post
cat <<'MSG'

rekordbox-wine is installed. It does NOT modify your system Wine.

The fixes live in a private Wine tree (about 16 MB of symlinks to your system
Wine, plus six patched files), built automatically on first run. Every other
Wine application on this machine keeps using the distro's Wine, unchanged.

Two steps, neither needs root:

  1. Install rekordbox itself. Not included -- it is proprietary. Download it
     from rekordbox.com and sign in with your own AlphaTheta account.

       rekordbox-wine --install ~/Downloads/rekordbox_7.2.18.exe

  2. Replug your controller so the new udev rule applies, and reboot (or
     "sudo modprobe -r snd_seq_dummy") so the module blacklist takes effect.

Then:

       rekordbox-wine              launch
       rekordbox-wine --check      verify every step, change nothing
       /usr/share/rekordbox-wine/bin/verifyloaded.sh
                                   confirm the RUNNING process really is using
                                   the patched libraries

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
%{_datadir}/%{name}/
%{_datadir}/applications/%{name}.desktop
/usr/lib/udev/rules.d/60-pioneer-ddj.rules
/usr/lib/modprobe.d/%{name}.conf
/usr/lib/modules-load.d/%{name}.conf
%doc %{_datadir}/doc/%{name}/

%changelog
* Thu Aug 20 2026 rekordbox-wine maintainers <nobody@example.invalid> - 0.2.0-1
- Initial packaging: ten Wine fixes, launcher, udev and module configuration.

#!/bin/bash
# ASCII Saver Uninstaller
# Removes the screensaver, camera agent, and all associated data.

# Re-run with sudo if not root (needed because pkg installer writes as root)
if [ "$EUID" -ne 0 ]; then
    echo "Requesting administrator privileges to uninstall..."
    exec sudo "$0" "$@"
fi

echo ""
echo "ASCII Saver Uninstaller"
echo "======================"
echo ""

# Get the real user (not root) for home directory paths
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

# Stop camera agent if running
if pgrep -x "ASCIISaverCameraAgent" > /dev/null 2>&1; then
    echo "Stopping camera agent..."
    killall ASCIISaverCameraAgent 2>/dev/null || true
    sleep 1
fi

# Remove screensaver bundle
SAVER="$REAL_HOME/Library/Screen Savers/ASCIISaver.saver"
if [ -d "$SAVER" ]; then
    echo "Removing screensaver..."
    rm -rf "$SAVER"
else
    echo "Screensaver not found (already removed)"
fi

# Remove camera agent
AGENT="/Applications/ASCIISaverCameraAgent.app"
if [ -d "$AGENT" ]; then
    echo "Removing camera agent..."
    rm -rf "$AGENT"
else
    echo "Camera agent not found (already removed)"
fi

# Remove shared frame buffer
if [ -d "/tmp/ASCIISaver" ]; then
    echo "Removing frame buffer..."
    rm -rf "/tmp/ASCIISaver"
fi

# Remove preferences (run as real user)
echo "Removing preferences..."
sudo -u "$REAL_USER" defaults delete com.jorviksoftware.ASCIISaver 2>/dev/null || true

# Remove app group container
GROUP_CONTAINER="$REAL_HOME/Library/Group Containers/group.jorviksoftware.ASCIISaver"
if [ -d "$GROUP_CONTAINER" ]; then
    echo "Removing app group container..."
    rm -rf "$GROUP_CONTAINER"
fi

# Forget the installer receipts
pkgutil --forget com.jorviksoftware.ASCIISaver.saver 2>/dev/null || true
pkgutil --forget com.jorviksoftware.ASCIISaver.agent 2>/dev/null || true

echo ""
echo "ASCII Saver has been completely removed."
echo "You may need to log out and back in to clear the screensaver from System Settings."

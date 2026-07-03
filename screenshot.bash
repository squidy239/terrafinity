timeout 6s zig build run -Dtest_play &
sleep 5s
mkdir -p /tmp/screenshots
cosmic-screenshot --interactive=false --save-dir /tmp/screenshots
mv /tmp/screenshots/$(ls /tmp/screenshots/ | tail -n 1) screenshot.png
rm -rf /tmp/screenshots
echo "screenshot.png saved"
rm -r screenshot.png
timeout 40s zig build run -Dtest_play=35 &> /dev/null &
sleep 30s
mkdir -p /tmp/screenshots
cosmic-screenshot --interactive=false --save-dir /tmp/screenshots > /dev/null
mv /tmp/screenshots/$(ls /tmp/screenshots/ | tail -n 1) screenshot.png
rm -rf /tmp/screenshots
echo "the screenshot was saved to screenshot.png"

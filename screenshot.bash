timeout 6s zig build run -Dtest_play=5 &> /dev/null &
sleep 5s
mkdir -p /tmp/screenshots
cosmic-screenshot --interactive=false --save-dir /tmp/screenshots > /dev/null
mv /tmp/screenshots/$(ls /tmp/screenshots/ | tail -n 1) screenshot.png
rm -rf /tmp/screenshots
echo "the screenshot was saved to screenshot.png"

while true; do
    timeout 30s zig build run -Dtest_play &> output.txt
    sleep 30
done
# Terrafinity

Terrafinity is a work in progress 3d voxel game similar to Minecraft.
Most game logic and world generation is multithreaded.
There is also no world height limit, which lets extremely large terrain exist.

![terrain](terrain.png)

# How To Build

Terrafinity can be built using the zig build system.
To compile and run in release mode use ```zig build run -Doptimize=ReleaseSafe``` with a zig 0.15.2 compiler installed

## Additional Dependencies:

Linux:  ```sudo apt install libx11-dev librocksdb-dev```


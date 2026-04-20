# Terrafinity

Terrafinity is a work in progress 3d voxel game similar to Minecraft.
Most game logic and world generation is multithreaded.
There is also no world height limit, which lets extremely large terrain exist.

![terrain](src/assets/terrain.png)

# How To Build

Terrafinity can be built using the zig build system.
To compile and run in release mode use ```zig build run -Doptimize=ReleaseSafe``` with a zig 0.16 compiler installed.

I only tested it on x64 Linux so their may be issues on other platforms.

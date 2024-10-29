pub const Player = struct {
    pos: @Vector(3, f32),
    pitch: f32,
    yaw: f32,
    roll: f32,
    speed: @Vector(3, f32),
    cameraUp: @Vector(3, f32),
    cameraFront: @Vector(3, f32),
};

# The documentation for the voxeelgame network protocal
 NOT FINISHED OR WORKING, just a plan of what it will be

# standerd packet types:

## standerd no verify packet:
[
2 bytes: type
1 bit: is packet split
if split{2 bytes amount of packets, 2 bytes packet segment number}
data
]

## standerd verify packet:
[
2 bytes: type
1 bit: is packet split
if split{2 bytes amount of packets, 2 bytes packet segment number}
4 bytes: packet id,
data
]

## packet aknolagement
[2 bytes:type, 4 bytes: packet id, bit:intact, if(intact is false) 1 bit was packet split, if packet was split, 2 bytes segment number]
aknolagement must get acnolaged


# serverbound (just data):

## Ping:
verifyed to prevent DDoS amplifacation, first response packet is used as ping
[
ping sent time: i64,
url_length:byte,
url used to ping: string,
] -> ping response

## unverified login:
verifyed
[
version: 2 bytes,
username len:1 byte,
username: variable string,
server adderess len: 1 byte,
url_length:byte,
url used to join: string,
]
// url includes routes
// will fully do login later

## Disconnect:
sent 8 times for redundency, also in case of crash
[
reason:short,
]
## full player update:
not verifyed
[
x:f64,
y:f64,
z:f64,
pitch:f16,
yaw:f16,
velocity x: f64,
velocity y: f64,
velocity z:f64,
onground:bit,
] - 52 bytes

## player look:
not verifyed
[
pitch:f16,
yaw:f16,
]

## player move:
not verifyed
[
offset x:f32,
offset y:f32,
offset z:f32,
]

## check if chunks were generated:
verify
[
chunk_amount: u5,
chunk_positians: [][3]i32,
] -> Respond which chunks were generated



# clientbound (just data):

## Respond which chunks were generated:
verify
[
chunk_amount: u5,
chunk_positians: [][3]i32,
] -> Check which chunks were generated

chunk_positians a list of which chunks were modified, server will later send them, client is free to generate all other chunks on its own.

## Send_Chunk:
verify
[
chunk_pos:[3]i32,
compressian_type:byte,
chunk_data_len: short,
chunk_data: []byte,
]

## player_update_positian:
verify
[
self:bit,
if not self UUID:8 bytes,
x:f64,
y:f64,
z:f64,
pitch:f16,
yaw:f16,
velocity x: f64,
velocity y: f64,
velocity z:f64,
onground:bit,
]

ot verifyed
[
x:f64,
y:f64,
z:f64,
pitch:f16,
yaw:f16,
velocity x: f64,
velocity y: f64,
velocity z:f64,
onground:bit,
] - 52 bytes

## player look:
not verifyed
[
UUID:8 bytes,
pitch:f16,
yaw:f16,
]

## player move:
not verifyed
[
UUID:8 bytes,
offset x:f32,
offset y:f32,
offset z:f32,
]

## Kick:
verify
[
reasonlength:byte,
reason:string,
]

## ping response:
verifyed
[
server_name_len:byte,
server_name:string,
server_descriptian_len:byte,
server_descriptian:string,
players_onlne:u32
ping_summery_len:short
ping_summery:string,
] <- ping

ping summery is usualy list of online players
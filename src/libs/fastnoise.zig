// MIT License
//
// Copyright(c) 2023 Jordan Peck (jordan.me2@gmail.com)
// Copyright(c) 2023 Contributors
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files(the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and / or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions :
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
// .'',;:cldxkO00KKXXNNWWWNNXKOkxdollcc::::::;:::ccllloooolllllllllooollc:,'...        ...........',;cldxkO000Okxdlc::;;;,,;;;::cclllllll
// ..',;:ldxO0KXXNNNNNNNNXXK0kxdolcc::::::;;;,,,,,,;;;;;;;;;;:::cclllllc:;'....       ...........',;:ldxO0KXXXK0Okxdolc::;;;;::cllodddddo
// ...',:loxO0KXNNNNNXXKK0Okxdolc::;::::::::;;;,,'''''.....''',;:clllllc:;,'............''''''''',;:loxO0KXNNNNNXK0Okxdollccccllodxxxxxxd
// ....';:ldkO0KXXXKK00Okxdolcc:;;;;;::cclllcc:;;,''..... ....',;clooddolcc:;;;;,,;;;;;::::;;;;;;:cloxk0KXNWWWWWWNXKK0Okxddoooddxxkkkkkxx
// .....';:ldxkOOOOOkxxdolcc:;;;,,,;;:cllooooolcc:;'...      ..,:codxkkkxddooollloooooooollcc:::::clodkO0KXNWWWWWWNNXK00Okxxxxxxxxkkkkxxx
// . ....';:cloddddo___________,,,,;;:clooddddoolc:,...      ..,:ldx__00OOOkkk___kkkkkkxxdollc::::cclodkO0KXXNNNNNNXXK0OOkxxxxxxxxxxxxddd
// .......',;:cccc:|           |,,,;;:cclooddddoll:;'..     ..';cox|  \KKK000|   |KK00OOkxdocc___;::clldxxkO0KKKKK00Okkxdddddddddddddddoo
// .......'',,,,,''|   ________|',,;;::cclloooooolc:;'......___:ldk|   \KK000|   |XKKK0Okxolc|   |;;::cclodxxkkkkxxdoolllcclllooodddooooo
// ''......''''....|   |  ....'',,,,;;;::cclloooollc:;,''.'|   |oxk|    \OOO0|   |KKK00Oxdoll|___|;;;;;::ccllllllcc::;;,,;;;:cclloooooooo
// ;;,''.......... |   |_____',,;;;____:___cllo________.___|   |___|     \xkk|   |KK_______ool___:::;________;;;_______...'',;;:ccclllloo
// c:;,''......... |         |:::/     '   |lo/        |           |      \dx|   |0/       \d|   |cc/        |'/       \......',,;;:ccllo
// ol:;,'..........|    _____|ll/    __    |o/   ______|____    ___|   |   \o|   |/   ___   \|   |o/   ______|/   ___   \ .......'',;:clo
// dlc;,...........|   |::clooo|    /  |   |x\___   \KXKKK0|   |dol|   |\   \|   |   |   |   |   |d\___   \..|   |  /   /       ....',:cl
// xoc;'...  .....'|   |llodddd|    \__|   |_____\   \KKK0O|   |lc:|   |'\       |   |___|   |   |_____\   \.|   |_/___/...      ...',;:c
// dlc;'... ....',;|   |oddddddo\          |          |Okkx|   |::;|   |..\      |\         /|   |          | \         |...    ....',;:c
// ol:,'.......',:c|___|xxxddollc\_____,___|_________/ddoll|___|,,,|___|...\_____|:\ ______/l|___|_________/...\________|'........',;::cc
// c:;'.......';:codxxkkkkxxolc::;::clodxkOO0OOkkxdollc::;;,,''''',,,,''''''''''',,'''''',;:loxkkOOkxol:;,'''',,;:ccllcc:;,'''''',;::ccll
// ;,'.......',:codxkOO0OOkxdlc:;,,;;:cldxxkkxxdolc:;;,,''.....'',;;:::;;,,,'''''........,;cldkO0KK0Okdoc::;;::cloodddoolc:;;;;;::ccllooo
// .........',;:lodxOO0000Okdoc:,,',,;:clloddoolc:;,''.......'',;:clooollc:;;,,''.......',:ldkOKXNNXX0Oxdolllloddxxxxxxdolccccccllooodddd
// .    .....';:cldxkO0000Okxol:;,''',,;::cccc:;,,'.......'',;:cldxxkkxxdolc:;;,'.......';coxOKXNWWWNXKOkxddddxxkkkkkkxdoollllooddxxxxkkk
//       ....',;:codxkO000OOxdoc:;,''',,,;;;;,''.......',,;:clodkO00000Okxolc::;,,''..',;:ldxOKXNWWWNNK0OkkkkkkkkkkkxxddooooodxxkOOOOO000
//       ....',;;clodxkkOOOkkdolc:;,,,,,,,,'..........,;:clodxkO0KKXKK0Okxdolcc::;;,,,;;:codkO0XXNNNNXKK0OOOOOkkkkxxdoollloodxkO0KKKXXXXX
//
// VERSION: 1.1.1
// https://github.com/Auburn/FastNoiseLite
// This has been modified from the original source.

const std = @import("std");
const builtin = @import("builtin");

const prime_x: i32 = 501125321;
const prime_y: i32 = 1136930381;
const prime_z: i32 = 1720413743;
const prime_x_shl1 = std.math.shl(i32, prime_x, 1);
const prime_y_shl1 = std.math.shl(i32, prime_y, 1);
const prime_z_shl1 = std.math.shl(i32, prime_z, 1);
/// FastNoise2's hash multiplier.
const hash_multiplier: i32 = @bitCast(@as(u32, 0xB7E0A5F5));

/// Describes a noise-generating algorithm.
pub const NoiseType = enum {
    /// Simplex is the successor of and comparable to Perlin noise, but with fewer
    /// directional artifacts in higher dimensions, and a lower computational overhead.
    simplex,
    /// A variation of simplex (i.e. "SuperSimplex") which has a smoother output.
    simplex_smooth,
    /// Worley/Voronoi noise algorithm.
    cellular,
    /// A classic general-purpose gradient noise.
    perlin,
    /// A more complex variation of value noise that employs a cubic function.
    value_cubic,
    /// Consists of the creation of a lattice of points which are assigned random values.
    value,
};

pub const RotationType = enum {
    none,
    improve_xy_planes,
    improve_xz_planes,
};

pub const FractalType = enum {
    none,
    fbm,
    ridged,
    ping_pong,
    progressive,
    independent,
};

pub const CellularDistanceFunc = enum {
    euclidean,
    euclidean_sq,
    manhattan,
    hybrid,
};

pub const CellularReturnType = enum {
    cell_value,
    distance,
    distance2,
    distance2_add,
    distance2_sub,
    distance2_mul,
    distance2_div,
};

pub const DomainWarpType = enum {
    simplex,
    simplex_reduced,
    basic_grid,
};

/// Structure containing the noise-generater state.
///
/// The generator behaves as a state-machine, and all of its functions are "pure" in
/// the regard that they do not modify the internal state of the generator.
/// Configuration of the generator is done via the struct's fields, which are intended
/// to be modified directly as-needed.
// Lookup tables are module-level so every Noise(Float) instantiation
// shares one copy; the values are FastNoise's f32 tables. `f64` uses
// them via `@floatCast` (exact for these values); not duplicated per-Float.
const warp_gradient_pairs: [16][2]f32 = .{
    .{ 0.130526192220052, 0.99144486137381 },
    .{ 0.38268343236509, 0.923879532511287 },
    .{ 0.608761429008721, 0.793353340291235 },
    .{ 0.793353340291235, 0.608761429008721 },
    .{ 0.923879532511287, 0.38268343236509 },
    .{ 0.99144486137381, 0.130526192220051 },
    .{ 0.99144486137381, -0.130526192220051 },
    .{ 0.923879532511287, -0.38268343236509 },
    .{ 0.793353340291235, -0.60876142900872 },
    .{ 0.608761429008721, -0.793353340291235 },
    .{ 0.38268343236509, -0.923879532511287 },
    .{ 0.130526192220052, -0.99144486137381 },
    .{ -0.130526192220052, -0.99144486137381 },
    .{ -0.38268343236509, -0.923879532511287 },
    .{ -0.608761429008721, -0.793353340291235 },
    .{ -0.793353340291235, -0.608761429008721 },
};

const gradients_3d: [256]f32 = .{
    0, 1, 1, 0, 0,  -1, 1, 0, 0,  1,  -1, 0, 0,  -1, -1, 0,
    1, 0, 1, 0, -1, 0,  1, 0, 1,  0,  -1, 0, -1, 0,  -1, 0,
    1, 1, 0, 0, -1, 1,  0, 0, 1,  -1, 0,  0, -1, -1, 0,  0,
    0, 1, 1, 0, 0,  -1, 1, 0, 0,  1,  -1, 0, 0,  -1, -1, 0,
    1, 0, 1, 0, -1, 0,  1, 0, 1,  0,  -1, 0, -1, 0,  -1, 0,
    1, 1, 0, 0, -1, 1,  0, 0, 1,  -1, 0,  0, -1, -1, 0,  0,
    0, 1, 1, 0, 0,  -1, 1, 0, 0,  1,  -1, 0, 0,  -1, -1, 0,
    1, 0, 1, 0, -1, 0,  1, 0, 1,  0,  -1, 0, -1, 0,  -1, 0,
    1, 1, 0, 0, -1, 1,  0, 0, 1,  -1, 0,  0, -1, -1, 0,  0,
    0, 1, 1, 0, 0,  -1, 1, 0, 0,  1,  -1, 0, 0,  -1, -1, 0,
    1, 0, 1, 0, -1, 0,  1, 0, 1,  0,  -1, 0, -1, 0,  -1, 0,
    1, 1, 0, 0, -1, 1,  0, 0, 1,  -1, 0,  0, -1, -1, 0,  0,
    0, 1, 1, 0, 0,  -1, 1, 0, 0,  1,  -1, 0, 0,  -1, -1, 0,
    1, 0, 1, 0, -1, 0,  1, 0, 1,  0,  -1, 0, -1, 0,  -1, 0,
    1, 1, 0, 0, -1, 1,  0, 0, 1,  -1, 0,  0, -1, -1, 0,  0,
    1, 1, 0, 0, 0,  -1, 1, 0, -1, 1,  0,  0, 0,  -1, -1, 0,
};

const rand_3d: [1024]f32 = .{
    -0.7292736885,  -0.6618439697,  0.1735581948,   0, 0.790292081,   -0.5480887466,  -0.2739291014,  0, 0.7217578935,   0.6226212466,  -0.3023380997,   0, 0.565683137,    -0.8208298145, -0.0790000257, 0, 0.760049034,   -0.5555979497, -0.3370999617,  0, 0.3713945616,   0.5011264475,   0.7816254623,   0, -0.1277062463,  -0.4254438999,    -0.8959289049, 0, -0.2881560924, -0.5815838982,  0.7607405838,   0,
    0.5849561111,   -0.662820239,   -0.4674352136,  0, 0.3307171178,  0.0391653737,   0.94291689,     0, 0.8712121778,   -0.4113374369, -0.2679381538,   0, 0.580981015,    0.7021915846,  0.4115677815,  0, 0.503756873,   0.6330056931,  -0.5878203852,  0, 0.4493712205,   0.601390195,    0.6606022552,   0, -0.6878403724,  0.09018890807,    -0.7202371714, 0, -0.5958956522, -0.6469350577,  0.475797649,    0,
    -0.5127052122,  0.1946921978,   -0.8361987284,  0, -0.9911507142, -0.05410276466, -0.1212153153,  0, -0.2149721042,  0.9720882117,  -0.09397607749,  0, -0.7518650936,  -0.5428057603, 0.3742469607,  0, 0.5237068895,  0.8516377189,  -0.02107817834, 0, 0.6333504779,   0.1926167129,   -0.7495104896,  0, -0.06788241606, 0.3998305789,     0.9140719259,  0, -0.5538628599, -0.4729896695,  -0.6852128902,  0,
    -0.7261455366,  -0.5911990757,  0.3509933228,   0, -0.9229274737, -0.1782808786,  0.3412049336,   0, -0.6968815002,  0.6511274338,  0.3006480328,    0, 0.9608044783,   -0.2098363234, -0.1811724921, 0, 0.06817146062, -0.9743405129, 0.2145069156,   0, -0.3577285196,  -0.6697087264,  -0.6507845481,  0, -0.1868621131,  0.7648617052,     -0.6164974636, 0, -0.6541697588, 0.3967914832,   0.6439087246,   0,
    0.6993340405,   -0.6164538506,  0.3618239211,   0, -0.1546665739, 0.6291283928,   0.7617583057,   0, -0.6841612949,  -0.2580482182, -0.6821542638,   0, 0.5383980957,   0.4258654885,  0.7271630328,  0, -0.5026987823, -0.7939832935, -0.3418836993,  0, 0.3202971715,   0.2834415347,   0.9039195862,   0, 0.8683227101,   -0.0003762656404, -0.4959995258, 0, 0.791120031,   -0.08511045745, 0.6057105799,   0,
    -0.04011016052, -0.4397248749,  0.8972364289,   0, 0.9145119872,  0.3579346169,   -0.1885487608,  0, -0.9612039066,  -0.2756484276, 0.01024666929,   0, 0.6510361721,   -0.2877799159, -0.7023778346, 0, -0.2041786351, 0.7365237271,  0.644859585,    0, -0.7718263711,  0.3790626912,   0.5104855816,   0, -0.3060082741,  -0.7692987727,    0.5608371729,  0, 0.454007341,   -0.5024843065,  0.7357899537,   0,
    0.4816795475,   0.6021208291,   -0.6367380315,  0, 0.6961980369,  -0.3222197429,  0.641469197,    0, -0.6532160499,  -0.6781148932, 0.3368515753,    0, 0.5089301236,   -0.6154662304, -0.6018234363, 0, -0.1635919754, -0.9133604627, -0.372840892,   0, 0.52408019,     -0.8437664109,  0.1157505864,   0, 0.5902587356,   0.4983817807,     -0.6349883666, 0, 0.5863227872,  0.494764745,    0.6414307729,   0,
    0.6779335087,   0.2341345225,   0.6968408593,   0, 0.7177054546,  -0.6858979348,  0.120178631,    0, -0.5328819713,  -0.5205125012, 0.6671608058,    0, -0.8654874251,  -0.0700727088, -0.4960053754, 0, -0.2861810166, 0.7952089234,  0.5345495242,   0, -0.04849529634, 0.9810836427,   -0.1874115585,  0, -0.6358521667,  0.6058348682,     0.4781800233,  0, 0.6254794696,  -0.2861619734,  0.7258696564,   0,
    -0.2585259868,  0.5061949264,   -0.8227581726,  0, 0.02136306781, 0.5064016808,   -0.8620330371,  0, 0.200111773,    0.8599263484,  0.4695550591,    0, 0.4743561372,   0.6014985084,  -0.6427953014, 0, 0.6622993731,  -0.5202474575, -0.5391679918,  0, 0.08084972818,  -0.6532720452,  0.7527940996,   0, -0.6893687501,  0.0592860349,     0.7219805347,  0, -0.1121887082, -0.9673185067,  0.2273952515,   0,
    0.7344116094,   0.5979668656,   -0.3210532909,  0, 0.5789393465,  -0.2488849713,  0.7764570201,   0, 0.6988182827,   0.3557169806,  -0.6205791146,   0, -0.8636845529,  -0.2748771249, -0.4224826141, 0, -0.4247027957, -0.4640880967, 0.777335046,    0, 0.5257722489,   -0.8427017621,  0.1158329937,   0, 0.9343830603,   0.316302472,      -0.1639543925, 0, -0.1016836419, -0.8057303073,  -0.5834887393,  0,
    -0.6529238969,  0.50602126,     -0.5635892736,  0, -0.2465286165, -0.9668205684,  -0.06694497494, 0, -0.9776897119,  -0.2099250524, -0.007368825344, 0, 0.7736893337,   0.5734244712,  0.2694238123,  0, -0.6095087895, 0.4995678998,  0.6155736747,   0, 0.5794535482,   0.7434546771,   0.3339292269,   0, -0.8226211154,  0.08142581855,    0.5627293636,  0, -0.510385483,  0.4703667658,   0.7199039967,   0,
    -0.5764971849,  -0.07231656274, -0.8138926898,  0, 0.7250628871,  0.3949971505,   -0.5641463116,  0, -0.1525424005,  0.4860840828,  -0.8604958341,   0, -0.5550976208,  -0.4957820792, 0.667882296,   0, -0.1883614327, 0.9145869398,  0.357841725,    0, 0.7625556724,   -0.5414408243,  -0.3540489801,  0, -0.5870231946,  -0.3226498013,    -0.7424963803, 0, 0.3051124198,  0.2262544068,   -0.9250488391,  0,
    0.6379576059,   0.577242424,    -0.5097070502,  0, -0.5966775796, 0.1454852398,   -0.7891830656,  0, -0.658330573,   0.6555487542,  -0.3699414651,   0, 0.7434892426,   0.2351084581,  0.6260573129,  0, 0.5562114096,  0.8264360377,  -0.0873632843,  0, -0.3028940016,  -0.8251527185,  0.4768419182,   0, 0.1129343818,   -0.985888439,     -0.1235710781, 0, 0.5937652891,  -0.5896813806,  0.5474656618,   0,
    0.6757964092,   -0.5835758614,  -0.4502648413,  0, 0.7242302609,  -0.1152719764,  0.6798550586,   0, -0.9511914166,  0.0753623979,  -0.2992580792,   0, 0.2539470961,   -0.1886339355, 0.9486454084,  0, 0.571433621,   -0.1679450851, -0.8032795685,  0, -0.06778234979, 0.3978269256,   0.9149531629,   0, 0.6074972649,   0.733060024,      -0.3058922593, 0, -0.5435478392, 0.1675822484,   0.8224791405,   0,
    -0.5876678086,  -0.3380045064,  -0.7351186982,  0, -0.7967562402, 0.04097822706,  -0.6029098428,  0, -0.1996350917,  0.8706294745,  0.4496111079,    0, -0.02787660336, -0.9106232682, -0.4122962022, 0, -0.7797625996, -0.6257634692, 0.01975775581,  0, -0.5211232846,  0.7401644346,   -0.4249554471,  0, 0.8575424857,   0.4053272873,     -0.3167501783, 0, 0.1045223322,  0.8390195772,   -0.5339674439,  0,
    0.3501822831,   0.9242524096,   -0.1520850155,  0, 0.1987849858,  0.07647613266,  0.9770547224,   0, 0.7845996363,   0.6066256811,  -0.1280964233,   0, 0.09006737436,  -0.9750989929, -0.2026569073, 0, -0.8274343547, -0.542299559,  0.1458203587,   0, -0.3485797732,  -0.415802277,   0.840000362,    0, -0.2471778936,  -0.7304819962,    -0.6366310879, 0, -0.3700154943, 0.8577948156,   0.3567584454,   0,
    0.5913394901,   -0.548311967,   -0.5913303597,  0, 0.1204873514,  -0.7626472379,  -0.6354935001,  0, 0.616959265,    0.03079647928, 0.7863922953,    0, 0.1258156836,   -0.6640829889, -0.7369967419, 0, -0.6477565124, -0.1740147258, -0.7417077429,  0, 0.6217889313,   -0.7804430448,  -0.06547655076, 0, 0.6589943422,   -0.6096987708,    0.4404473475,  0, -0.2689837504, -0.6732403169,  -0.6887635427,  0,
    -0.3849775103,  0.5676542638,   0.7277093879,   0, 0.5754444408,  0.8110471154,   -0.1051963504,  0, 0.9141593684,   0.3832947817,  0.131900567,     0, -0.107925319,   0.9245493968,  0.3654593525,  0, 0.377977089,   0.3043148782,  0.8743716458,   0, -0.2142885215,  -0.8259286236,  0.5214617324,   0, 0.5802544474,   0.4148098596,     -0.7008834116, 0, -0.1982660881, 0.8567161266,   -0.4761596756,  0,
    -0.03381553704, 0.3773180787,   -0.9254661404,  0, -0.6867922841, -0.6656597827,  0.2919133642,   0, 0.7731742607,   -0.2875793547, -0.5652430251,   0, -0.09655941928, 0.9193708367,  -0.3813575004, 0, 0.2715702457,  -0.9577909544, -0.09426605581, 0, 0.2451015704,   -0.6917998565,  -0.6792188003,  0, 0.977700782,    -0.1753855374,    0.1155036542,  0, -0.5224739938, 0.8521606816,   0.02903615945,  0,
    -0.7734880599,  -0.5261292347,  0.3534179531,   0, -0.7134492443, -0.269547243,   0.6467878011,   0, 0.1644037271,   0.5105846203,  -0.8439637196,   0, 0.6494635788,   0.05585611296, 0.7583384168,  0, -0.4711970882, 0.5017280509,  -0.7254255765,  0, -0.6335764307,  -0.2381686273,  -0.7361091029,  0, -0.9021533097,  -0.270947803,     -0.3357181763, 0, -0.3793711033, 0.872258117,    0.3086152025,   0,
    -0.6855598966,  -0.3250143309,  0.6514394162,   0, 0.2900942212,  -0.7799057743,  -0.5546100667,  0, -0.2098319339,  0.85037073,    0.4825351604,    0, -0.4592603758,  0.6598504336,  -0.5947077538, 0, 0.8715945488,  0.09616365406, -0.4807031248,  0, -0.6776666319,  0.7118504878,   -0.1844907016,  0, 0.7044377633,   0.312427597,      0.637304036,   0, -0.7052318886, -0.2401093292,  -0.6670798253,  0,
    0.081921007,    -0.7207336136,  -0.6883545647,  0, -0.6993680906, -0.5875763221,  -0.4069869034,  0, -0.1281454481,  0.6419895885,  0.7559286424,    0, -0.6337388239,  -0.6785471501, -0.3714146849, 0, 0.5565051903,  -0.2168887573, -0.8020356851,  0, -0.5791554484,  0.7244372011,   -0.3738578718,  0, 0.1175779076,   -0.7096451073,    0.6946792478,  0, -0.6134619607, 0.1323631078,   0.7785527795,   0,
    0.6984635305,   -0.02980516237, -0.715024719,   0, 0.8318082963,  -0.3930171956,  0.3919597455,   0, 0.1469576422,   0.05541651717, -0.9875892167,   0, 0.708868575,    -0.2690503865, 0.6520101478,  0, 0.2726053183,  0.67369766,    -0.68688995,    0, -0.6591295371,  0.3035458599,   -0.6880466294,  0, 0.4815131379,   -0.7528270071,    0.4487723203,  0, 0.9430009463,  0.1675647412,   -0.2875261255,  0,
    0.434802957,    0.7695304522,   -0.4677277752,  0, 0.3931996188,  0.594473625,    0.7014236729,   0, 0.7254336655,   -0.603925654,  0.3301814672,    0, 0.7590235227,   -0.6506083235, 0.02433313207, 0, -0.8552768592, -0.3430042733, 0.3883935666,   0, -0.6139746835,  0.6981725247,   0.3682257648,   0, -0.7465905486,  -0.5752009504,    0.3342849376,  0, 0.5730065677,  0.810555537,    -0.1210916791,  0,
    -0.9225877367,  -0.3475211012,  -0.167514036,   0, -0.7105816789, -0.4719692027,  -0.5218416899,  0, -0.08564609717, 0.3583001386,  0.929669703,     0, -0.8279697606,  -0.2043157126, 0.5222271202,  0, 0.427944023,   0.278165994,   0.8599346446,   0, 0.5399079671,   -0.7857120652,  -0.3019204161,  0, 0.5678404253,   -0.5495413974,    -0.6128307303, 0, -0.9896071041, 0.1365639107,   -0.04503418428, 0,
    -0.6154342638,  -0.6440875597,  0.4543037336,   0, 0.1074204368,  -0.7946340692,  0.5975094525,   0, -0.3595449969,  -0.8885529948, 0.28495784,      0, -0.2180405296,  0.1529888965,  0.9638738118,  0, -0.7277432317, -0.6164050508, -0.3007234646,  0, 0.7249729114,   -0.00669719484, 0.6887448187,   0, -0.5553659455,  -0.5336586252,    0.6377908264,  0, 0.5137558015,  0.7976208196,   -0.3160000073,  0,
    -0.3794024848,  0.9245608561,   -0.03522751494, 0, 0.8229248658,  0.2745365933,   -0.4974176556,  0, -0.5404114394,  0.6091141441,  0.5804613989,    0, 0.8036581901,   -0.2703029469, 0.5301601931,  0, 0.6044318879,  0.6832968393,  0.4095943388,   0, 0.06389988817,  0.9658208605,   -0.2512108074,  0, 0.1087113286,   0.7402471173,     -0.6634877936, 0, -0.713427712,  -0.6926784018,  0.1059128479,   0,
    0.6458897819,   -0.5724548511,  -0.5050958653,  0, -0.6553931414, 0.7381471625,   0.159995615,    0, 0.3910961323,   0.9188871375,  -0.05186755998,  0, -0.4879022471,  -0.5904376907, 0.6429111375,  0, 0.6014790094,  0.7707441366,  -0.2101820095,  0, -0.5677173047,  0.7511360995,   0.3368851762,   0, 0.7858573506,   0.226674665,      0.5753666838,  0, -0.4520345543, -0.604222686,   -0.6561857263,  0,
    0.002272116345, 0.4132844051,   -0.9105991643,  0, -0.5815751419, -0.5162925989,  0.6286591339,   0, -0.03703704785, 0.8273785755,  0.5604221175,    0, -0.5119692504,  0.7953543429,  -0.3244980058, 0, -0.2682417366, -0.9572290247, -0.1084387619,  0, -0.2322482736,  -0.9679131102,  -0.09594243324, 0, 0.3554328906,   -0.8881505545,    0.2913006227,  0, 0.7346520519,  -0.4371373164,  0.5188422971,   0,
    0.9985120116,   0.04659011161,  -0.02833944577, 0, -0.3727687496, -0.9082481361,  0.1900757285,   0, 0.91737377,     -0.3483642108, 0.1925298489,    0, 0.2714911074,   0.4147529736,  -0.8684886582, 0, 0.5131763485,  -0.7116334161, 0.4798207128,   0, -0.8737353606,  0.18886992,     -0.4482350644,  0, 0.8460043821,   -0.3725217914,    0.3814499973,  0, 0.8978727456,  -0.1780209141,  -0.4026575304,  0,
    0.2178065647,   -0.9698322841,  -0.1094789531,  0, -0.1518031304, -0.7788918132,  -0.6085091231,  0, -0.2600384876,  -0.4755398075, -0.8403819825,   0, 0.572313509,    -0.7474340931, -0.3373418503, 0, -0.7174141009, 0.1699017182,  -0.6756111411,  0, -0.684180784,   0.02145707593,  -0.7289967412,  0, -0.2007447902,  0.06555605789,    -0.9774476623, 0, -0.1148803697, -0.8044887315,  0.5827524187,   0,
    -0.7870349638,  0.03447489231,  0.6159443543,   0, -0.2015596421, 0.6859872284,   0.6991389226,   0, -0.08581082512, -0.10920836,   -0.9903080513,   0, 0.5532693395,   0.7325250401,  -0.396610771,  0, -0.1842489331, -0.9777375055, -0.1004076743,  0, 0.0775473789,   -0.9111505856,  0.4047110257,   0, 0.1399838409,   0.7601631212,     -0.6344734459, 0, 0.4484419361,  -0.845289248,   0.2904925424,   0,
};

// 2D perlin gradient tables for the AVX2 vpermps path: the low three hash
// bits pick one of the eight octagonal directions, identical to the XOR-sign
// bit-math path used as the fallback on other targets.
const grad_gx_table: [8]f32 = .{
    1.0 + @sqrt(2.0), -1.0 - @sqrt(2.0), 1.0 + @sqrt(2.0), -1.0 - @sqrt(2.0),
    1.0,              -1.0,              1.0,              -1.0,
};
const grad_gy_table: [8]f32 = .{
    1.0,              1.0,              -1.0,              -1.0,
    1.0 + @sqrt(2.0), 1.0 + @sqrt(2.0), -1.0 - @sqrt(2.0), -1.0 - @sqrt(2.0),
};

// The 16 warp gradient pairs split into two 8-entry tables for the AVX2
// vpermps path; the high bit of the index picks the half.
const warp_gx_lo: [8]f32 = blk: {
    var t: [8]f32 = undefined;
    for (0..8) |i| t[i] = warp_gradient_pairs[i][0];
    break :blk t;
};
const warp_gy_lo: [8]f32 = blk: {
    var t: [8]f32 = undefined;
    for (0..8) |i| t[i] = warp_gradient_pairs[i][1];
    break :blk t;
};
const warp_gx_hi: [8]f32 = blk: {
    var t: [8]f32 = undefined;
    for (0..8) |i| t[i] = warp_gradient_pairs[8 + i][0];
    break :blk t;
};
const warp_gy_hi: [8]f32 = blk: {
    var t: [8]f32 = undefined;
    for (0..8) |i| t[i] = warp_gradient_pairs[8 + i][1];
    break :blk t;
};

/// AVX2 vpermps over eight f32 lanes: `out[i] = table[idx[i] & 7]`.  Call
/// sites gate on x86-64 with AVX2, so this is only instantiated there; the
/// pure-Zig select/bit-math paths are the fallback on other targets.
inline fn vpermpsF32(idx: @Vector(8, i32), table: @Vector(8, f32)) @Vector(8, f32) {
    var out: @Vector(8, f32) = undefined;
    asm volatile ("vpermps %[src], %[idx], %[out]"
        : [out] "=x" (out),
        : [idx] "x" (idx),
          [src] "x" (table),
    );
    return out;
}

pub fn Noise(comptime Float: type) type {
    // Compile-error if a non-float is specified
    switch (@typeInfo(Float)) {
        .float => |f| switch (f.bits) {
            32, 64 => {},
            else => @compileError("only 32 and 64 bit types supported"),
        },
        else => @compileError(@typeName(Float) ++ " is not a floating-point type."),
    }

    // Equivalent to -ffast-math in GCC
    @setFloatMode(.optimized);

    const sqrt3: Float = comptime @sqrt(3.0);
    const f2: Float = comptime 0.5 * (sqrt3 - 1.0);
    const g2: Float = comptime (3.0 - sqrt3) / 6.0;
    const r3: Float = comptime 2.0 / 3.0;
    const k_simplex2_falloff_c: Float = comptime -4.0 * (sqrt3 + 2.0) / (sqrt3 + 3.0);

    return struct {
        const State = @This();
        /// Seed used for all noise types.
        ///
        /// Default: `1337`
        seed: i32 = 1337,
        /// The frequency for all noise types.
        ///
        /// Default: `0.01`
        frequency: Float = 0.01,
        /// The noise algorithm to be used.
        ///
        /// Default: `.simplex`
        noise_type: NoiseType = .simplex,
        /// Sets rotation type for 3D noise.
        ///
        /// Default: `.none`
        rotation_type: RotationType = .none,
        /// The method used for combining octaves for all fractal noise types.
        ///
        /// Default: `.none`
        fractal_type: FractalType = .none,
        /// The octave count for all fractal noise types.
        ///
        /// Default: `3`
        octaves: u32 = 3,
        /// The octave lacunarity for all fractal noise types.
        ///
        /// Default: `2.0`
        lacunarity: Float = 2.0,
        /// The octave gain for all fractal noise types.
        ///
        /// Default: `0.5`
        gain: Float = 0.5,
        /// The octave weighting for all non domain warp fractal types.
        ///
        /// Default: `0.0`
        weighted_strength: Float = 0.0,
        /// The strength of the fractal ping pong effect.
        ///
        /// Default: `2.0`
        ping_pong_strength: Float = 2.0,
        /// The distance function used in cellular noise calculations.
        ///
        /// Default: `euclidean_sq`
        cellular_distance: CellularDistanceFunc = .euclidean_sq,
        /// The cellular return type from cellular noise calculations.
        ///
        /// Default: `.distance`
        cellular_return: CellularReturnType = .distance,
        /// The maximum distance a cellular point can move from it's grid position.
        /// Setting this higher than `1.0` will cause artifacts.
        ///
        /// Default: `1.0`
        cellular_jitter_mod: Float = 1.0,
        /// The warp algorithm when using domain warp.
        ///
        /// Default: `.simplex`
        domain_warp_type: DomainWarpType = .simplex,
        /// The maximum warp distance from original position when using domain warp.
        ///
        /// Default: `1.0`
        domain_warp_amp: Float = 1.0,
        const Dim = enum { d2, d3 };
        /// Lanes processed per SIMD chunk, tuned to the target's vector width.
        const GridLanes = std.simd.suggestVectorLength(Float) orelse 1;

        const CoordSource = union(enum) {
            /// Samples a regular grid: index `(z * height + y) * width + x` is sampled at
            /// `(x0 + x * spacing, y0 + y * spacing, z0 + z * spacing)`.
            grid: struct { width: usize, depth: usize, x0: Float, y0: Float, z0: Float, spacing: Float },
            /// Samples at explicit coordinates.
            points: struct { xs: []const Float, ys: []const Float, zs: []const Float },
        };

        /// Generates 2D noise at given position using the currently configured state.
        /// The return value is normalized to the range of `-1.0` to `1.0`.
        inline fn genNoise2DFractal(comptime noise: NoiseType, state: *const State, seed: i32, xv: @Vector(1, Float), yv: @Vector(1, Float)) @Vector(1, Float) {
            return switch (state.fractal_type) {
                .none, .progressive, .independent => genNoiseSingle2D(1, noise, state, seed, xv, yv),
                .fbm => genFractalFBm2D(1, noise, state, seed, state.calculateFractalBounding(), xv, yv),
                .ridged => genFractalRidged2D(1, noise, state, seed, state.calculateFractalBounding(), xv, yv),
                .ping_pong => genFractalPingPong2D(1, noise, state, seed, state.calculateFractalBounding(), xv, yv),
            };
        }

        pub fn genNoise2D(state: *const State, x: Float, y: Float) Float {
            @setFloatMode(.optimized);
            @setEvalBranchQuota(200_000);
            // Direct single-sample path: bypasses the grid-batching dispatch
            // (union handling, loop setup, store/load through a scratch
            // buffer) that the generic fill path pays for every sample.
            const FloatV = @Vector(1, Float);
            const xv: FloatV = .{x * state.frequency};
            const yv: FloatV = .{y * state.frequency};
            const result: FloatV = switch (state.noise_type) {
                .simplex => genNoise2DFractal(.simplex, state, state.seed, xv, yv),
                .simplex_smooth => genNoise2DFractal(.simplex_smooth, state, state.seed, xv, yv),
                .cellular => genNoise2DFractal(.cellular, state, state.seed, xv, yv),
                .perlin => genNoise2DFractal(.perlin, state, state.seed, xv, yv),
                .value_cubic => genNoise2DFractal(.value_cubic, state, state.seed, xv, yv),
                .value => genNoise2DFractal(.value, state, state.seed, xv, yv),
            };
            return result[0];
        }

        /// Fills `out` with 2D noise samples.
        ///
        /// `out` holds a `width`-column grid of `out.len / width` rows in row-major order;
        /// the sample at index `y * width + x` is generated at
        /// `(x0 + x * spacing, y0 + y * spacing)`.
        pub fn fillGrid2D(state: *const State, out: []Float, width: usize, x0: Float, y0: Float, spacing: Float) void {
            std.debug.assert(width != 0);
            std.debug.assert(out.len % width == 0);
            fillGridDispatch(GridLanes, .d2, state, out, .{ .grid = .{ .width = width, .depth = 1, .x0 = x0, .y0 = y0, .z0 = 0, .spacing = spacing } });
        }

        /// Fills `out` with 2D noise samples at explicit coordinates.
        ///
        /// `out[i]` is the noise at `(xs[i], ys[i])`; the slices must have equal lengths.
        pub fn fillNoise2DGrid(state: *const State, out: []Float, xs: []const Float, ys: []const Float) void {
            std.debug.assert(out.len == xs.len and out.len == ys.len);
            fillGridDispatch(GridLanes, .d2, state, out, .{ .points = .{ .xs = xs, .ys = ys, .zs = &.{} } });
        }

        /// Generates 2D noise at given position using the currently configured state.
        /// The return value is mapped to the given range and numeric type.
        pub fn genNoise2DRange(state: *const State, x: Float, y: Float, comptime T: type, min: T, max: T) T {
            std.debug.assert(min < max);
            return mapNoiseToRange(state.genNoise2D(x, y), T, min, max);
        }

        /// Generates 2D noise at given position using the currently configured state.
        /// The return value is mapped to the range of the specified numeric type.
        pub fn genNoise2DAsType(state: *const State, x: Float, y: Float, comptime T: type) T {
            return switch (@typeInfo(T)) {
                .int => {
                    const min = comptime std.math.minInt(T);
                    const max = comptime std.math.maxInt(T);
                    return genNoise2DRange(state, x, y, T, min, max);
                },
                .float => @floatCast(genNoise2D(state, x, y)),
                else => @compileError(@typeName(T) ++ " is not a numeric type"),
            };
        }
        /// Generates 3D noise at given position using the currently configured state.
        /// The return value is normalized to the range of `-1.0` to `1.0`.
        inline fn genNoise3DFractal(comptime noise: NoiseType, state: *const State, seed: i32, xv: @Vector(1, Float), yv: @Vector(1, Float), zv: @Vector(1, Float)) @Vector(1, Float) {
            return switch (state.fractal_type) {
                .none, .progressive, .independent => genNoiseSingle3D(1, noise, state, seed, xv, yv, zv),
                .fbm => genFractalFBm3D(1, noise, state, seed, state.calculateFractalBounding(), xv, yv, zv),
                .ridged => genFractalRidged3D(1, noise, state, seed, state.calculateFractalBounding(), xv, yv, zv),
                .ping_pong => genFractalPingPong3D(1, noise, state, seed, state.calculateFractalBounding(), xv, yv, zv),
            };
        }

        pub fn genNoise3D(state: *const State, x: Float, y: Float, z: Float) Float {
            @setFloatMode(.optimized);
            @setEvalBranchQuota(200_000);
            // Direct single-sample path; see genNoise2D.
            const FloatV = @Vector(1, Float);
            var xv: FloatV = .{x * state.frequency};
            var yv: FloatV = .{y * state.frequency};
            var zv: FloatV = .{z * state.frequency};
            rotate3DVec(state, 1, &xv, &yv, &zv);
            const result: FloatV = switch (state.noise_type) {
                .simplex => genNoise3DFractal(.simplex, state, state.seed, xv, yv, zv),
                .simplex_smooth => genNoise3DFractal(.simplex_smooth, state, state.seed, xv, yv, zv),
                .cellular => genNoise3DFractal(.cellular, state, state.seed, xv, yv, zv),
                .perlin => genNoise3DFractal(.perlin, state, state.seed, xv, yv, zv),
                .value_cubic => genNoise3DFractal(.value_cubic, state, state.seed, xv, yv, zv),
                .value => genNoise3DFractal(.value, state, state.seed, xv, yv, zv),
            };
            return result[0];
        }

        /// Fills `out` with 3D noise samples.
        ///
        /// `out` holds a `width`-by-`height`-by-`depth` grid in row-major order, where
        /// `height = out.len / (width * depth)`; the sample at index
        /// `(z * height + y) * width + x` is generated at
        /// `(x0 + x * spacing, y0 + y * spacing, z0 + z * spacing)`.
        pub fn fillGrid3D(state: *const State, out: []Float, width: usize, depth: usize, x0: Float, y0: Float, z0: Float, spacing: Float) void {
            std.debug.assert(width != 0);
            std.debug.assert(depth != 0);
            std.debug.assert(out.len % (width * depth) == 0);
            fillGridDispatch(GridLanes, .d3, state, out, .{ .grid = .{ .width = width, .depth = depth, .x0 = x0, .y0 = y0, .z0 = z0, .spacing = spacing } });
        }

        /// Fills `out` with 3D noise samples at explicit coordinates.
        ///
        /// `out[i]` is the noise at `(xs[i], ys[i], zs[i])`; the slices must have equal lengths.
        pub fn fillNoise3DGrid(state: *const State, out: []Float, xs: []const Float, ys: []const Float, zs: []const Float) void {
            std.debug.assert(out.len == xs.len and out.len == ys.len and out.len == zs.len);
            fillGridDispatch(GridLanes, .d3, state, out, .{ .points = .{ .xs = xs, .ys = ys, .zs = zs } });
        }

        /// Generates 3D noise at given position using the currently configured state.
        /// The return value is mapped to the given range and numeric type.
        pub fn genNoise3DRange(state: *const State, x: Float, y: Float, z: Float, comptime T: type, min: T, max: T) T {
            std.debug.assert(min < max);
            return mapNoiseToRange(state.genNoise3D(x, y, z), T, min, max);
        }

        /// Generates 3D noise at given position using the currently configured state.
        /// The return value is mapped to the range of the specified numeric type.
        pub fn genNoise3DAsType(state: *const State, x: Float, y: Float, z: Float, comptime T: type) T {
            return switch (@typeInfo(T)) {
                .int => {
                    const min = comptime std.math.minInt(T);
                    const max = comptime std.math.maxInt(T);
                    return genNoise3DRange(state, x, y, z, T, min, max);
                },
                .float => @floatCast(genNoise3D(state, x, y, z)),
                else => @compileError(@typeName(T) ++ " is not a numeric type"),
            };
        }
        pub inline fn domainWarp2D(state: *const State, x: *Float, y: *Float) void {
            var xs: @Vector(1, Float) = .{x.*};
            var ys: @Vector(1, Float) = .{y.*};
            state.warpVector2D(1, &xs, &ys);
            x.* = xs[0];
            y.* = ys[0];
        }
        pub inline fn domainWarp3D(state: *const State, x: *Float, y: *Float, z: *Float) void {
            switch (state.fractal_type) {
                .progressive => state.domainWarpFractal3D(x, y, z, true),
                .independent => state.domainWarpFractal3D(x, y, z, false),
                else => state.domainWarpSingle3D(x, y, z),
            }
        }

        /// Fills `out_xs`/`out_ys` with the 2D domain warp of the given coordinates.
        ///
        /// `out_xs[i]`/`out_ys[i]` is `xs[i]`/`ys[i]` warped by the configured domain
        /// warp; the slices must have equal lengths.
        pub fn fillWarp2DGrid(state: *const State, out_xs: []Float, out_ys: []Float, xs: []const Float, ys: []const Float) void {
            std.debug.assert(out_xs.len == out_ys.len and out_xs.len == xs.len and out_xs.len == ys.len);
            warpGrid2DImpl(GridLanes, state, out_xs, out_ys, xs, ys);
        }
        // End of public API

        inline fn doSingleDomainWarp2DVec(state: *const State, comptime N: usize, seed: i32, amp: Float, freq: Float, x: @Vector(N, Float), y: @Vector(N, Float), xp: *@Vector(N, Float), yp: *@Vector(N, Float)) void {
            @setFloatMode(.optimized);
            switch (state.domain_warp_type) {
                .simplex => singleDomainWarpSimplexGradientVec(N, seed, amp * 38.283687591552734375, freq, x, y, xp, yp),
                .simplex_reduced => singleDomainWarpSimplexGradientVec(N, seed, amp * 16.0, freq, x, y, xp, yp),
                .basic_grid => singleDomainWarpBasicGrid2DVec(N, seed, amp, freq, x, y, xp, yp),
            }
        }
        inline fn doSingleDomainWarp3D(state: *const State, seed: i32, amp: Float, freq: Float, x: Float, y: Float, z: Float, xp: *Float, yp: *Float, zp: *Float) void {
            @setFloatMode(.optimized);
            switch (state.domain_warp_type) {
                .simplex => singleDomainWarpOpenSimplex2Gradient(seed, amp * 32.69428253173828125, freq, x, y, z, xp, yp, zp, false),
                .simplex_reduced => singleDomainWarpOpenSimplex2Gradient(seed, amp * 7.71604938271605, freq, x, y, z, xp, yp, zp, true),
                .basic_grid => singleDomainWarpBasicGrid3D(seed, amp, freq, x, y, z, xp, yp, zp),
            }
        }
        // Utilities

        fn mapNoiseToRange(noise: Float, comptime T: type, min: T, max: T) T {
            @setFloatMode(.optimized);
            const n = 0.5 * (1.0 + @max(-1.0, @min(1.0, noise)));
            return switch (@typeInfo(T)) {
                // Integer ranges (especially i32/i64) exceed the f32 mantissa,
                // so widen to f64 for the mapping; f64 represents every i32
                // exactly and i64 up to 2^53.
                .int => @intFromFloat(@as(f64, @floatFromInt(min)) + @as(f64, n) * (@as(f64, @floatFromInt(max)) - @as(f64, @floatFromInt(min)))),
                .float => min + @as(T, @floatCast(n)) * (max - min),
                else => @compileError(@typeName(T) ++ " is not a numeric type"),
            };
        }
        inline fn fastRound(f: Float) i32 {
            @setFloatMode(.optimized);
            return @round(f);
        }

        /// Broadcasts a value to vector type `T`.
        inline fn splat(comptime T: type, value: anytype) T {
            return @splat(value);
        }

        /// Converts an integer to vector type `T`.
        inline fn floatFromInt(comptime T: type, value: anytype) T {
            return @floatFromInt(value);
        }
        inline fn lerp(a: anytype, b: @TypeOf(a), t: @TypeOf(a)) @TypeOf(a) {
            @setFloatMode(.optimized);
            // Explicit FMA guarantees single-instruction lerp on every target;
            // under .optimized LLVM already contracts this, so the values are
            // unchanged (bit-exact).
            return @mulAdd(@TypeOf(a), t, b - a, a);
        }

        inline fn interpHermite(t: Float) Float {
            @setFloatMode(.optimized);
            return t * t * (3 - 2 * t);
        }

        inline fn interpHermiteVec(comptime N: usize, t: @Vector(N, Float)) @Vector(N, Float) {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            return t * t * (splat(FloatV, 3) - splat(FloatV, 2) * t);
        }

        inline fn interpQuinticVec(comptime N: usize, t: @Vector(N, Float)) @Vector(N, Float) {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            // Quintic smoothstep 6t^5 - 15t^4 + 10t^3 in Horner form
            // t^3 * ((6t - 15)t + 10): the quadratic chain and the t^3 chain
            // are independent, so the critical-path depth is one level shorter
            // than the t^3*(6t^2-15t+10) association (values within 1 ULP).
            const step1 = @mulAdd(FloatV, splat(FloatV, 6), t, splat(FloatV, -15));
            const poly = @mulAdd(FloatV, step1, t, splat(FloatV, 10));
            const t2 = t * t;
            return poly * (t2 * t);
        }

        inline fn cubicLerp(a: anytype, b: @TypeOf(a), c: @TypeOf(a), d: @TypeOf(a), t: @TypeOf(a)) @TypeOf(a) {
            @setFloatMode(.optimized);
            // Cubic interpolation in a pure 3-stage FMA chain:
            // ((p*t + q)*t + r)*t + b with p = (d-c)-(a-b), q = (a-b)-p,
            // r = c-a.  Five fewer operations than the power form; the value
            // differs from the exact polynomial by <= 1 ULP (reassociation).
            const T = @TypeOf(a);
            const ab = a - b;
            const p = (d - c) - ab;
            const q = ab - p;
            const r = c - a;
            const f1 = @mulAdd(T, p, t, q);
            const f2h = @mulAdd(T, f1, t, r);
            return @mulAdd(T, f2h, t, b);
        }

        inline fn pingPongVec(comptime N: usize, t: @Vector(N, Float)) @Vector(N, Float) {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            const f = t - (@floor(t * splat(FloatV, 0.5)) * splat(FloatV, 2));
            return @select(Float, f < splat(FloatV, 1), f, splat(FloatV, 2) - f);
        }

        fn calculateFractalBounding(state: *const State) Float {
            @setFloatMode(.optimized);
            const gain: Float = @abs(state.gain);
            var amp = gain;
            var amp_fractal: Float = 1.0;
            for (1..state.octaves) |_| {
                amp_fractal += amp;
                amp *= gain;
            }
            return 1.0 / amp_fractal;
        }
        // Grid Batching

        fn storeChunk(comptime N: usize, start: usize, out: []Float, result: @Vector(N, Float)) void {
            @setFloatMode(.optimized);
            if (start + N <= out.len) {
                inline for (0..N) |i| out[start + i] = result[i];
            } else {
                inline for (0..N) |i| {
                    if (start + i < out.len) out[start + i] = result[i];
                }
            }
        }

        fn fillGridDispatch(comptime N: usize, comptime dim: Dim, state: *const State, out: []Float, source: CoordSource) void {
            switch (state.fractal_type) {
                .none => fillGridDispatchNoise(N, dim, state, out, source, .none),
                .fbm => fillGridDispatchNoise(N, dim, state, out, source, .fbm),
                .ridged => fillGridDispatchNoise(N, dim, state, out, source, .ridged),
                .ping_pong => fillGridDispatchNoise(N, dim, state, out, source, .ping_pong),
                .progressive, .independent => fillGridDispatchNoise(N, dim, state, out, source, .none),
            }
        }

        fn fillGridDispatchNoise(comptime N: usize, comptime dim: Dim, state: *const State, out: []Float, source: CoordSource, comptime fractal: FractalType) void {
            switch (state.noise_type) {
                .simplex => if (comptime dim == .d2) fillGrid2DImpl(N, state, out, source, fractal, .simplex) else fillGrid3DImpl(N, state, out, source, fractal, .simplex),
                .simplex_smooth => if (comptime dim == .d2) fillGrid2DImpl(N, state, out, source, fractal, .simplex_smooth) else fillGrid3DImpl(N, state, out, source, fractal, .simplex_smooth),
                .cellular => if (comptime dim == .d2) fillGrid2DImpl(N, state, out, source, fractal, .cellular) else fillGrid3DImpl(N, state, out, source, fractal, .cellular),
                .perlin => if (comptime dim == .d2) fillGrid2DImpl(N, state, out, source, fractal, .perlin) else fillGrid3DImpl(N, state, out, source, fractal, .perlin),
                .value_cubic => if (comptime dim == .d2) fillGrid2DImpl(N, state, out, source, fractal, .value_cubic) else fillGrid3DImpl(N, state, out, source, fractal, .value_cubic),
                .value => if (comptime dim == .d2) fillGrid2DImpl(N, state, out, source, fractal, .value) else fillGrid3DImpl(N, state, out, source, fractal, .value),
            }
        }

        fn fillGrid2DImpl(comptime N: usize, state: *const State, out: []Float, source: CoordSource, comptime fractal: FractalType, comptime noise: NoiseType) void {
            @setFloatMode(.optimized);
            @setEvalBranchQuota(200_000);
            const FloatV = @Vector(N, Float);
            const frequency_v: FloatV = @splat(state.frequency);
            const iota_v: FloatV = comptime blk: {
                var arr: [N]Float = undefined;
                for (0..N) |i| arr[i] = @floatFromInt(i);
                break :blk arr;
            };
            const spacing_freq: Float = switch (source) {
                .grid => |g| g.spacing * state.frequency,
                .points => 0,
            };
            const spacing_freq_v: FloatV = @splat(spacing_freq);
            const x0_freq_v: FloatV = switch (source) {
                .grid => |g| @splat(g.x0 * state.frequency),
                .points => @splat(0),
            };
            const y0_freq: Float = switch (source) {
                .grid => |g| g.y0 * state.frequency,
                .points => 0,
            };

            // Fractal bounding is loop-invariant; compute once instead of per
            // chunk (LLVM cannot hoist it past the stores without alias proof).
            // `fractal` is comptime, so non-fractal fills skip it entirely.
            const bounding: Float = switch (fractal) {
                .fbm, .ridged, .ping_pong => state.calculateFractalBounding(),
                else => 1.0,
            };

            var start: usize = 0;
            // Carried grid counters: row = start / width, col = start % width
            // maintained by addition and wraparound instead of per-chunk
            // integer division (the division is 64-bit and ~25 cycles on Zen2).
            var col: usize = 0;
            var row: usize = 0;
            // Split the loop so full chunks carry no per-chunk bounds checks
            // and store via a single vector store; the tail (at most one
            // chunk) is handled separately below.
            const full_len = out.len - (out.len % N);
            while (start < full_len) : (start += N) {
                var x: FloatV = undefined;
                var y: FloatV = undefined;
                switch (source) {
                    .grid => |g| {
                        if (col + N <= g.width) {
                            const col_f: Float = @floatFromInt(col);
                            const row_f: Float = @floatFromInt(row);
                            x = @mulAdd(FloatV, @as(FloatV, @splat(col_f)) + iota_v, spacing_freq_v, x0_freq_v);
                            y = @splat(@mulAdd(Float, row_f, spacing_freq, y0_freq));
                            col += N;
                            if (col == g.width) {
                                col = 0;
                                row += 1;
                            }
                        } else {
                            var idx: @Vector(N, usize) = undefined;
                            inline for (0..N) |i| idx[i] = start + i;
                            const width_v: @Vector(N, usize) = @splat(g.width);
                            const ix = idx % width_v;
                            x = (@as(FloatV, @splat(g.x0)) + floatFromInt(FloatV, ix) * @as(FloatV, @splat(g.spacing))) * frequency_v;
                            y = (@as(FloatV, @splat(g.y0)) + floatFromInt(FloatV, idx / width_v) * @as(FloatV, @splat(g.spacing))) * frequency_v;
                            // Re-sync the carried counters (rare: once per row).
                            const next = start + N;
                            col = next % g.width;
                            row = next / g.width;
                        }
                    },
                    .points => |p| {
                        // One 32-byte load per coordinate instead of N scalar
                        // loads plus inserts.
                        x = @as(FloatV, @bitCast(p.xs[start..][0..N].*)) * frequency_v;
                        y = @as(FloatV, @bitCast(p.ys[start..][0..N].*)) * frequency_v;
                    },
                }

                const result: FloatV = switch (fractal) {
                    .none, .progressive, .independent => genNoiseSingle2D(N, noise, state, state.seed, x, y),
                    .fbm => genFractalFBm2D(N, noise, state, state.seed, bounding, x, y),
                    .ridged => genFractalRidged2D(N, noise, state, state.seed, bounding, x, y),
                    .ping_pong => genFractalPingPong2D(N, noise, state, state.seed, bounding, x, y),
                };
                // Single 32-byte store; the full_len bound makes it provable.
                out[start..][0..N].* = @as([N]Float, @bitCast(result));
            }
            // Tail chunk (at most one): the guarded paths.
            if (start < out.len) {
                var x: FloatV = undefined;
                var y: FloatV = undefined;
                switch (source) {
                    .grid => |g| {
                        var idx: @Vector(N, usize) = undefined;
                        inline for (0..N) |i| idx[i] = start + i;
                        const width_v: @Vector(N, usize) = @splat(g.width);
                        const ix = idx % width_v;
                        x = (@as(FloatV, @splat(g.x0)) + floatFromInt(FloatV, ix) * @as(FloatV, @splat(g.spacing))) * frequency_v;
                        y = (@as(FloatV, @splat(g.y0)) + floatFromInt(FloatV, idx / width_v) * @as(FloatV, @splat(g.spacing))) * frequency_v;
                    },
                    .points => |p| {
                        const remaining = out.len - start;
                        inline for (0..N) |i| {
                            x[i] = p.xs[start + @min(i, remaining - 1)];
                            y[i] = p.ys[start + @min(i, remaining - 1)];
                        }
                        x *= frequency_v;
                        y *= frequency_v;
                    },
                }
                const result: FloatV = switch (fractal) {
                    .none, .progressive, .independent => genNoiseSingle2D(N, noise, state, state.seed, x, y),
                    .fbm => genFractalFBm2D(N, noise, state, state.seed, bounding, x, y),
                    .ridged => genFractalRidged2D(N, noise, state, state.seed, bounding, x, y),
                    .ping_pong => genFractalPingPong2D(N, noise, state, state.seed, bounding, x, y),
                };
                storeChunk(N, start, out, result);
            }
        }

        /// Applies the configured 3D rotation transform to a chunk of
        /// frequency-scaled coordinates (shared by the grid fill and the
        /// single-sample path).
        inline fn rotate3DVec(state: *const State, comptime N: usize, x: *@Vector(N, Float), y: *@Vector(N, Float), z: *@Vector(N, Float)) void {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            switch (state.rotation_type) {
                .improve_xy_planes => {
                    const xy = x.* + y.*;
                    const s2 = xy * splat(FloatV, -0.211324865405187);
                    z.* *= splat(FloatV, 0.577350269189626);
                    x.* += s2 - z.*;
                    y.* = y.* + s2 - z.*;
                    z.* += xy * splat(FloatV, 0.577350269189626);
                },
                .improve_xz_planes => {
                    const xz = x.* + z.*;
                    const s2 = xz * splat(FloatV, -0.211324865405187);
                    y.* *= splat(FloatV, 0.577350269189626);
                    x.* += s2 - y.*;
                    z.* += s2 - y.*;
                    y.* += xz * splat(FloatV, 0.577350269189626);
                },
                .none => {},
            }
        }

        fn fillGrid3DImpl(comptime N: usize, state: *const State, out: []Float, source: CoordSource, comptime fractal: FractalType, comptime noise: NoiseType) void {
            @setFloatMode(.optimized);
            @setEvalBranchQuota(200_000);
            const FloatV = @Vector(N, Float);
            const frequency_v: FloatV = @splat(state.frequency);
            // Grid rows per column; invariant across chunks, so hoist the
            // division out of the loop (LLVM cannot hoist integer division).
            const height: usize = switch (source) {
                .grid => |g| out.len / (g.width * g.depth),
                .points => 0,
            };
            const iota_v: FloatV = comptime blk: {
                var arr: [N]Float = undefined;
                for (0..N) |i| arr[i] = @floatFromInt(i);
                break :blk arr;
            };
            const spacing_freq: Float = switch (source) {
                .grid => |g| g.spacing * state.frequency,
                .points => 0,
            };
            const spacing_freq_v: FloatV = @splat(spacing_freq);
            const x0_freq_v: FloatV = switch (source) {
                .grid => |g| @splat(g.x0 * state.frequency),
                .points => @splat(0),
            };
            const y0_freq: Float = switch (source) {
                .grid => |g| g.y0 * state.frequency,
                .points => 0,
            };
            const z0_freq: Float = switch (source) {
                .grid => |g| g.z0 * state.frequency,
                .points => 0,
            };

            // Fractal bounding is loop-invariant; compute once instead of per
            // chunk (LLVM cannot hoist it past the stores without alias proof).
            // `fractal` is comptime, so non-fractal fills skip it entirely.
            const bounding: Float = switch (fractal) {
                .fbm, .ridged, .ping_pong => state.calculateFractalBounding(),
                else => 1.0,
            };

            var start: usize = 0;
            // Carried grid counters: ix = start % width, iy = (start/width) %
            // height, iz = start / (width*height), maintained by addition and
            // wraparound instead of per-chunk 64-bit integer division.
            var ix: usize = 0;
            var iy: usize = 0;
            var iz: usize = 0;
            // Split the loop so full chunks carry no per-chunk bounds checks
            // and store via a single vector store; see fillGrid2DImpl.
            const full_len = out.len - (out.len % N);
            while (start < full_len) : (start += N) {
                var x: FloatV = undefined;
                var y: FloatV = undefined;
                var z: FloatV = undefined;
                switch (source) {
                    .grid => |g| {
                        if (ix + N <= g.width) {
                            // The chunk fits inside one x-row, so the y and z
                            // coordinates are constant within the chunk.
                            const ix0_f: Float = @floatFromInt(ix);
                            const iy0_f: Float = @floatFromInt(iy);
                            const iz0_f: Float = @floatFromInt(iz);
                            x = @mulAdd(FloatV, @as(FloatV, @splat(ix0_f)) + iota_v, spacing_freq_v, x0_freq_v);
                            y = @splat(@mulAdd(Float, iy0_f, spacing_freq, y0_freq));
                            z = @splat(@mulAdd(Float, iz0_f, spacing_freq, z0_freq));
                            ix += N;
                            if (ix == g.width) {
                                ix = 0;
                                iy += 1;
                                if (iy == height) {
                                    iy = 0;
                                    iz += 1;
                                }
                            }
                        } else {
                            var idx: @Vector(N, usize) = undefined;
                            inline for (0..N) |i| idx[i] = start + i;
                            const width_v: @Vector(N, usize) = @splat(g.width);
                            const height_v: @Vector(N, usize) = @splat(height);
                            const area_v: @Vector(N, usize) = @splat(g.width * height);
                            const ixv = idx % width_v;
                            const iyv = (idx / width_v) % height_v;
                            const izv = idx / area_v;
                            x = (@as(FloatV, @splat(g.x0)) + floatFromInt(FloatV, ixv) * @as(FloatV, @splat(g.spacing))) * frequency_v;
                            y = (@as(FloatV, @splat(g.y0)) + floatFromInt(FloatV, iyv) * @as(FloatV, @splat(g.spacing))) * frequency_v;
                            z = (@as(FloatV, @splat(g.z0)) + floatFromInt(FloatV, izv) * @as(FloatV, @splat(g.spacing))) * frequency_v;
                            // Re-sync the carried counters (rare).
                            const next = start + N;
                            ix = next % g.width;
                            iy = (next / g.width) % height;
                            iz = next / (g.width * height);
                        }
                    },
                    .points => |p| {
                        // One 32-byte load per coordinate instead of N scalar
                        // loads plus inserts.
                        x = @as(FloatV, @bitCast(p.xs[start..][0..N].*)) * frequency_v;
                        y = @as(FloatV, @bitCast(p.ys[start..][0..N].*)) * frequency_v;
                        z = @as(FloatV, @bitCast(p.zs[start..][0..N].*)) * frequency_v;
                    },
                }

                rotate3DVec(state, N, &x, &y, &z);

                const result: FloatV = switch (fractal) {
                    .none, .progressive, .independent => genNoiseSingle3D(N, noise, state, state.seed, x, y, z),
                    .fbm => genFractalFBm3D(N, noise, state, state.seed, bounding, x, y, z),
                    .ridged => genFractalRidged3D(N, noise, state, state.seed, bounding, x, y, z),
                    .ping_pong => genFractalPingPong3D(N, noise, state, state.seed, bounding, x, y, z),
                };
                out[start..][0..N].* = @as([N]Float, @bitCast(result));
            }
            // Tail chunk (at most one): the guarded paths.
            if (start < out.len) {
                var x: FloatV = undefined;
                var y: FloatV = undefined;
                var z: FloatV = undefined;
                switch (source) {
                    .grid => |g| {
                        var idx: @Vector(N, usize) = undefined;
                        inline for (0..N) |i| idx[i] = start + i;
                        const width_v: @Vector(N, usize) = @splat(g.width);
                        const height_v: @Vector(N, usize) = @splat(height);
                        const area_v: @Vector(N, usize) = @splat(g.width * height);
                        const ixv = idx % width_v;
                        const iyv = (idx / width_v) % height_v;
                        const izv = idx / area_v;
                        x = (@as(FloatV, @splat(g.x0)) + floatFromInt(FloatV, ixv) * @as(FloatV, @splat(g.spacing))) * frequency_v;
                        y = (@as(FloatV, @splat(g.y0)) + floatFromInt(FloatV, iyv) * @as(FloatV, @splat(g.spacing))) * frequency_v;
                        z = (@as(FloatV, @splat(g.z0)) + floatFromInt(FloatV, izv) * @as(FloatV, @splat(g.spacing))) * frequency_v;
                    },
                    .points => |p| {
                        const remaining = out.len - start;
                        inline for (0..N) |i| {
                            x[i] = p.xs[start + @min(i, remaining - 1)];
                            y[i] = p.ys[start + @min(i, remaining - 1)];
                            z[i] = p.zs[start + @min(i, remaining - 1)];
                        }
                        x *= frequency_v;
                        y *= frequency_v;
                        z *= frequency_v;
                    },
                }

                rotate3DVec(state, N, &x, &y, &z);

                const result: FloatV = switch (fractal) {
                    .none, .progressive, .independent => genNoiseSingle3D(N, noise, state, state.seed, x, y, z),
                    .fbm => genFractalFBm3D(N, noise, state, state.seed, bounding, x, y, z),
                    .ridged => genFractalRidged3D(N, noise, state, state.seed, bounding, x, y, z),
                    .ping_pong => genFractalPingPong3D(N, noise, state, state.seed, bounding, x, y, z),
                };
                storeChunk(N, start, out, result);
            }
        }

        // Hashing

        inline fn hash3D(seed: i32, x_primed: i32, y_primed: i32, z_primed: i32) i32 {
            return (seed ^ x_primed ^ y_primed ^ z_primed) *% 0x27D4EB2D;
        }
        inline fn hash2DVec(comptime N: usize, seed: i32, x_primed: @Vector(N, i32), y_primed: @Vector(N, i32)) @Vector(N, i32) {
            @setFloatMode(.optimized);
            const seed_v: @Vector(N, i32) = @splat(seed);
            return (seed_v ^ x_primed ^ y_primed) *% splat(@Vector(N, i32), hash_multiplier);
        }

        inline fn hash3DVec(comptime N: usize, seed: i32, x_primed: @Vector(N, i32), y_primed: @Vector(N, i32), z_primed: @Vector(N, i32)) @Vector(N, i32) {
            @setFloatMode(.optimized);
            const seed_v: @Vector(N, i32) = @splat(seed);
            return (seed_v ^ x_primed ^ y_primed ^ z_primed) *% splat(@Vector(N, i32), hash_multiplier);
        }

        inline fn gradCoord2DFromHashVec(comptime N: usize, hash_in: @Vector(N, i32), xd: @Vector(N, Float), yd: @Vector(N, Float)) @Vector(N, Float) {
            @setFloatMode(.optimized);
            const IntV = @Vector(N, i32);
            const FloatV = @Vector(N, Float);
            var hash = hash_in;
            hash ^= hash >> splat(IntV, 15);
            if (comptime N == 8 and Float == f32 and builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .avx2)) {
                // One vpermps per component selects the table entry from the
                // low three hash bits of each lane.  The XOR-sign path below
                // is the fallback for other targets and widths. Only valid for f32.
                const table_gx: @Vector(8, Float) = @bitCast(grad_gx_table);
                const table_gy: @Vector(8, Float) = @bitCast(grad_gy_table);
                const gx = vpermpsF32(hash, table_gx);
                const gy = vpermpsF32(hash, table_gy);
                return @mulAdd(FloatV, gx, xd, gy * yd);
            }
            var sx: FloatV = undefined;
            var sy: FloatV = undefined;
            if (Float == f32) {
                const hbits: @Vector(N, u32) = @bitCast(hash);
                sx = @as(FloatV, @bitCast(@as(@Vector(N, u32), @bitCast(xd)) ^ (hbits << splat(@Vector(N, u5), 31))));
                sy = @as(FloatV, @bitCast(@as(@Vector(N, u32), @bitCast(yd)) ^ ((hbits >> splat(@Vector(N, u5), 1)) << splat(@Vector(N, u5), 31))));
            } else {
                // f64 fallback via selects; bit trick would need u64 63-bit shift.
                const pos_x = (hash & splat(IntV, 1)) == splat(IntV, 0);
                const pos_y = (hash & splat(IntV, 2)) == splat(IntV, 0);
                sx = @select(Float, pos_x, xd, -xd);
                sy = @select(Float, pos_y, yd, -yd);
            }
            // The swap bit exchanges the components, matching FastNoise2's table.
            const swap = (hash & splat(IntV, 4)) != splat(IntV, 0);
            const u = @select(Float, swap, sy, sx);
            const v = @select(Float, swap, sx, sy);
            return @mulAdd(FloatV, u, splat(FloatV, 1.0 + @sqrt(2.0)), v);
        }

        inline fn gradCoord2DVec(comptime N: usize, seed: i32, x_primed: @Vector(N, i32), y_primed: @Vector(N, i32), xd: @Vector(N, Float), yd: @Vector(N, Float)) @Vector(N, Float) {
            return gradCoord2DFromHashVec(N, hash2DVec(N, seed, x_primed, y_primed), xd, yd);
        }

        inline fn gradCoord3DFromHashVec(comptime N: usize, hash_in: @Vector(N, i32), xd: @Vector(N, Float), yd: @Vector(N, Float), zd: @Vector(N, Float)) @Vector(N, Float) {
            @setFloatMode(.optimized);
            const IntV = @Vector(N, i32);
            const FloatV = @Vector(N, Float);
            var hash = hash_in;
            hash ^= hash >> splat(IntV, 15);
            const h13 = hash & splat(IntV, 13);
            const u = @select(Float, h13 > splat(IntV, 7), yd, xd);
            const v = @select(Float, h13 == splat(IntV, 12), xd, @select(Float, h13 < splat(IntV, 2), yd, zd));
            if (Float == f32) {
                const hbits: @Vector(N, u32) = @bitCast(hash);
                const su = @as(FloatV, @bitCast(@as(@Vector(N, u32), @bitCast(u)) ^ (hbits << splat(@Vector(N, u5), 31))));
                const sv = @as(FloatV, @bitCast(@as(@Vector(N, u32), @bitCast(v)) ^ ((hbits >> splat(@Vector(N, u5), 1)) << splat(@Vector(N, u5), 31))));
                return su + sv;
            } else {
                const pos_u = (hash & splat(IntV, 1)) == splat(IntV, 0);
                const pos_v = (hash & splat(IntV, 2)) == splat(IntV, 0);
                return @select(Float, pos_u, u, -u) + @select(Float, pos_v, v, -v);
            }
        }

        inline fn gradCoord3DVec(comptime N: usize, seed: i32, x_primed: @Vector(N, i32), y_primed: @Vector(N, i32), z_primed: @Vector(N, i32), xd: @Vector(N, Float), yd: @Vector(N, Float), zd: @Vector(N, Float)) @Vector(N, Float) {
            return gradCoord3DFromHashVec(N, hash3DVec(N, seed, x_primed, y_primed, z_primed), xd, yd, zd);
        }

        inline fn gradCoordOut3D(seed: i32, x_primed: i32, y_primed: i32, z_primed: i32, xo: *Float, yo: *Float, zo: *Float) void {
            const hash: usize = @intCast(hash3D(seed, x_primed, y_primed, z_primed) & (255 << 2));
            xo.* = rand_3d[hash];
            yo.* = rand_3d[hash | 1];
            zo.* = rand_3d[hash | 2];
        }
        // The 2D warp gradient table is 16 direction pairs (22.5-degree steps)
        // repeated eight times, so the four low hash bits pick the unique pair.

        fn GradPair(comptime N: usize) type {
            return struct { xg: @Vector(N, Float), yg: @Vector(N, Float) };
        }

        fn UnitPair(comptime N: usize) type {
            return struct { xo: @Vector(N, Float), yo: @Vector(N, Float) };
        }

        inline fn gradient2DTableVec(comptime N: usize, hash: @Vector(N, i32)) GradPair(N) {
            @setFloatMode(.optimized);
            const IntV = @Vector(N, i32);
            const idx = (hash >> splat(IntV, 1)) & splat(IntV, 0xF);
            if (comptime N == 8 and Float == f32 and builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .avx2)) {
                // Two vpermps per component select the pair; the values are
                // identical to the select-tree fallback. Only f32 tables exist.
                const table_gx_lo: @Vector(8, Float) = @bitCast(warp_gx_lo);
                const table_gy_lo: @Vector(8, Float) = @bitCast(warp_gy_lo);
                const table_gx_hi: @Vector(8, Float) = @bitCast(warp_gx_hi);
                const table_gy_hi: @Vector(8, Float) = @bitCast(warp_gy_hi);
                const gx_lo = vpermpsF32(idx, table_gx_lo);
                const gy_lo = vpermpsF32(idx, table_gy_lo);
                const gx_hi = vpermpsF32(idx, table_gx_hi);
                const gy_hi = vpermpsF32(idx, table_gy_hi);
                const take_hi = (idx & splat(IntV, 8)) != splat(IntV, 0);
                return .{
                    .xg = @select(Float, take_hi, gx_hi, gx_lo),
                    .yg = @select(Float, take_hi, gy_hi, gy_lo),
                };
            }
            return gradientPairSelect(N, 0, 16, idx);
        }

        inline fn gradientPairSelect(comptime N: usize, comptime lo: usize, comptime hi: usize, idx: @Vector(N, i32)) GradPair(N) {
            @setFloatMode(.optimized);
            const IntV = @Vector(N, i32);
            const FloatV = @Vector(N, Float);
            if (hi - lo == 1) {
                return .{ .xg = splat(FloatV, warp_gradient_pairs[lo][0]), .yg = splat(FloatV, warp_gradient_pairs[lo][1]) };
            }
            const mid = (lo + hi) / 2;
            const bit = comptime std.math.log2_int(usize, hi - lo - 1);
            const take_hi = (idx & splat(IntV, @as(i32, 1) << bit)) != splat(IntV, 0);
            const lo_pair = gradientPairSelect(N, lo, mid, idx);
            const hi_pair = gradientPairSelect(N, mid, hi, idx);
            return .{
                .xg = @select(Float, take_hi, hi_pair.xg, lo_pair.xg),
                .yg = @select(Float, take_hi, hi_pair.yg, lo_pair.yg),
            };
        }

        // Zig has no vector gather, so the 256-entry rand_2d table is replaced by
        // a unit vector derived from two independent hash values. The result is
        // statistically equivalent but differs from FastNoise's table output.
        inline fn randomUnit2DFromHashes(comptime N: usize, h1: @Vector(N, i32), h2: @Vector(N, i32)) UnitPair(N) {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            const vx = floatFromInt(FloatV, h1) * splat(FloatV, 1.0 / 2147483648.0);
            const vy = floatFromInt(FloatV, h2) * splat(FloatV, 1.0 / 2147483648.0);
            const len = @sqrt(vx * vx + vy * vy);
            // One division instead of two; vx/len vs vx*(1/len) differ by at
            // most an ULP, which is within the numerical-equivalence budget.
            // |h1| >= 1 for non-zero hashes, so len >= 2^-31 >> 1e-30 always.
            const inv_len = splat(FloatV, 1.0) / len;
            return .{
                .xo = vx * inv_len,
                .yo = vy * inv_len,
            };
        }

        inline fn gradCoordDual2DVec(comptime N: usize, seed: i32, x_primed: @Vector(N, i32), y_primed: @Vector(N, i32), xd: @Vector(N, Float), yd: @Vector(N, Float)) UnitPair(N) {
            @setFloatMode(.optimized);
            // The gradient table and the random unit vector share the first
            // hash; computing it once saves a full hash per corner.
            const h1 = hash2DVec(N, seed, x_primed, y_primed);
            const h2 = hash2DVec(N, seed +% 1293373, x_primed, y_primed);
            const grad = gradient2DTableVec(N, h1);
            const value = xd * grad.xg + yd * grad.yg;
            const offset = randomUnit2DFromHashes(N, h1, h2);
            return .{ .xo = value * offset.xo, .yo = value * offset.yo };
        }
        inline fn gradCoordDual3D(seed: i32, x_primed: i32, y_primed: i32, z_primed: i32, xd: Float, yd: Float, zd: Float, xo: *Float, yo: *Float, zo: *Float) void {
            const hash = hash3D(seed, x_primed, y_primed, z_primed);
            const index1: usize = @intCast(hash & (63 << 2));
            const index2: usize = @intCast((hash >> 6) & (255 << 2));

            const xg: Float = gradients_3d[index1];
            const yg: Float = gradients_3d[index1 | 1];
            const zg: Float = gradients_3d[index1 | 2];
            const value = xd * xg + yd * yg + zd * zg;

            const xgo: Float = rand_3d[index2];
            const ygo: Float = rand_3d[index2 | 1];
            const zgo: Float = rand_3d[index2 | 2];

            xo.* = value * xgo;
            yo.* = value * ygo;
            zo.* = value * zgo;
        }
        inline fn genNoiseSingle2D(comptime N: usize, comptime noise: NoiseType, state: *const State, seed: i32, x: @Vector(N, Float), y: @Vector(N, Float)) @Vector(N, Float) {
            @setFloatMode(.optimized);
            return switch (noise) {
                .simplex => singleSimplex2D(N, seed, x, y),
                .simplex_smooth => singleSimplexS2D(N, seed, x, y),
                .cellular => singleCellular2D(N, state, seed, x, y),
                .perlin => singlePerlin2D(N, seed, x, y),
                .value_cubic => singleValueCubic2D(N, seed, x, y),
                .value => singleValue2D(N, seed, x, y),
            };
        }

        inline fn genNoiseSingle3D(comptime N: usize, comptime noise: NoiseType, state: *const State, seed: i32, x: @Vector(N, Float), y: @Vector(N, Float), z: @Vector(N, Float)) @Vector(N, Float) {
            @setFloatMode(.optimized);
            return switch (noise) {
                .simplex => singleSimplex3D(N, seed, x, y, z),
                .simplex_smooth => singleSimplexS3D(N, seed, x, y, z),
                .cellular => singleCellular3D(N, state, seed, x, y, z),
                .perlin => singlePerlin3D(N, seed, x, y, z),
                .value_cubic => singleValueCubic3D(N, seed, x, y, z),
                .value => singleValue3D(N, seed, x, y, z),
            };
        }

        // Single Noise

        // Primes the four cell corners and folds the seed/hash-multiplier into
        // each, returning the four final hashes in [00, 10, 01, 11] order.
        // Shared by perlin and value noise; the hash sequence is unchanged.
        inline fn cellHash2D(comptime N: usize, seed: i32, x0: @Vector(N, i32), y0: @Vector(N, i32)) [4]@Vector(N, i32) {
            @setFloatMode(.optimized);
            const IntV = @Vector(N, i32);
            const x0p: IntV = x0 *% splat(IntV, prime_x);
            const y0p: IntV = y0 *% splat(IntV, prime_y);
            const x1p: IntV = x0p +% splat(IntV, prime_x);
            const y1p: IntV = y0p +% splat(IntV, prime_y);
            const seed_v: IntV = @splat(seed);
            const mult_v: IntV = splat(IntV, hash_multiplier);
            const x0_seed = seed_v ^ x0p;
            const x1_seed = seed_v ^ x1p;
            return .{
                (x0_seed ^ y0p) *% mult_v,
                (x1_seed ^ y0p) *% mult_v,
                (x0_seed ^ y1p) *% mult_v,
                (x1_seed ^ y1p) *% mult_v,
            };
        }

        inline fn cellHash3D(comptime N: usize, seed: i32, x0: @Vector(N, i32), y0: @Vector(N, i32), z0: @Vector(N, i32)) [8]@Vector(N, i32) {
            @setFloatMode(.optimized);
            const IntV = @Vector(N, i32);
            const x0p: IntV = x0 *% splat(IntV, prime_x);
            const y0p: IntV = y0 *% splat(IntV, prime_y);
            const z0p: IntV = z0 *% splat(IntV, prime_z);
            const x1p: IntV = x0p +% splat(IntV, prime_x);
            const y1p: IntV = y0p +% splat(IntV, prime_y);
            const z1p: IntV = z0p +% splat(IntV, prime_z);
            const seed_v: IntV = @splat(seed);
            const mult_v: IntV = splat(IntV, hash_multiplier);
            const x0_seed = seed_v ^ x0p;
            const x1_seed = seed_v ^ x1p;
            const xy00 = x0_seed ^ y0p;
            const xy10 = x1_seed ^ y0p;
            const xy01 = x0_seed ^ y1p;
            const xy11 = x1_seed ^ y1p;
            return .{
                (xy00 ^ z0p) *% mult_v,
                (xy10 ^ z0p) *% mult_v,
                (xy01 ^ z0p) *% mult_v,
                (xy11 ^ z0p) *% mult_v,
                (xy00 ^ z1p) *% mult_v,
                (xy10 ^ z1p) *% mult_v,
                (xy01 ^ z1p) *% mult_v,
                (xy11 ^ z1p) *% mult_v,
            };
        }

        fn singlePerlin2D(comptime N: usize, seed: i32, x: @Vector(N, Float), y: @Vector(N, Float)) @Vector(N, Float) {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            const IntV = @Vector(N, i32);

            const x0_f: FloatV = @floor(x);
            const x0: IntV = @intFromFloat(x0_f);
            const y0_f: FloatV = @floor(y);
            const y0: IntV = @intFromFloat(y0_f);
            const xd0: FloatV = x - x0_f;
            const yd0: FloatV = y - y0_f;
            const xd1: FloatV = xd0 - splat(FloatV, 1);
            const yd1: FloatV = yd0 - splat(FloatV, 1);

            const xs = interpQuinticVec(N, xd0);
            const ys = interpQuinticVec(N, yd0);

            const h = cellHash2D(N, seed, x0, y0);
            const xf0 = lerp(gradCoord2DFromHashVec(N, h[0], xd0, yd0), gradCoord2DFromHashVec(N, h[1], xd1, yd0), xs);
            const xf1 = lerp(gradCoord2DFromHashVec(N, h[2], xd0, yd1), gradCoord2DFromHashVec(N, h[3], xd1, yd1), xs);

            return lerp(xf0, xf1, ys) * splat(FloatV, 1.0 / 1.726796627044677734375);
        }

        fn singlePerlin3D(comptime N: usize, seed: i32, x: @Vector(N, Float), y: @Vector(N, Float), z: @Vector(N, Float)) @Vector(N, Float) {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            const IntV = @Vector(N, i32);

            const x0_f: FloatV = @floor(x);
            const x0: IntV = @intFromFloat(x0_f);
            const y0_f: FloatV = @floor(y);
            const y0: IntV = @intFromFloat(y0_f);
            const z0_f: FloatV = @floor(z);
            const z0: IntV = @intFromFloat(z0_f);
            const xd0: FloatV = x - x0_f;
            const yd0: FloatV = y - y0_f;
            const zd0: FloatV = z - z0_f;
            const xd1: FloatV = xd0 - splat(FloatV, 1);
            const yd1: FloatV = yd0 - splat(FloatV, 1);
            const zd1: FloatV = zd0 - splat(FloatV, 1);

            const xs = interpQuinticVec(N, xd0);
            const ys = interpQuinticVec(N, yd0);
            const zs = interpQuinticVec(N, zd0);

            const h = cellHash3D(N, seed, x0, y0, z0);
            const xf00 = lerp(gradCoord3DFromHashVec(N, h[0], xd0, yd0, zd0), gradCoord3DFromHashVec(N, h[1], xd1, yd0, zd0), xs);
            const xf10 = lerp(gradCoord3DFromHashVec(N, h[2], xd0, yd1, zd0), gradCoord3DFromHashVec(N, h[3], xd1, yd1, zd0), xs);
            const xf01 = lerp(gradCoord3DFromHashVec(N, h[4], xd0, yd0, zd1), gradCoord3DFromHashVec(N, h[5], xd1, yd0, zd1), xs);
            const xf11 = lerp(gradCoord3DFromHashVec(N, h[6], xd0, yd1, zd1), gradCoord3DFromHashVec(N, h[7], xd1, yd1, zd1), xs);

            const yf0 = lerp(xf00, xf10, ys);
            const yf1 = lerp(xf01, xf11, ys);
            return lerp(yf0, yf1, zs) * splat(FloatV, 0.964921414852142333984375);
        }

        inline fn valCoord2DFromHashVec(comptime N: usize, hash_in: @Vector(N, i32)) @Vector(N, Float) {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            var hash = hash_in;
            hash *%= hash *% splat(@Vector(N, i32), hash_multiplier);
            return floatFromInt(FloatV, hash) * splat(FloatV, 1.0 / 2147483648.0);
        }

        inline fn valCoord3DFromHashVec(comptime N: usize, hash_in: @Vector(N, i32)) @Vector(N, Float) {
            return valCoord2DFromHashVec(N, hash_in);
        }

        fn singleValue2D(comptime N: usize, seed: i32, x: @Vector(N, Float), y: @Vector(N, Float)) @Vector(N, Float) {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            const IntV = @Vector(N, i32);

            const x0_f: FloatV = @floor(x);
            const x0: IntV = @intFromFloat(x0_f);
            const y0_f: FloatV = @floor(y);
            const y0: IntV = @intFromFloat(y0_f);
            const xs = interpHermiteVec(N, x - x0_f);
            const ys = interpHermiteVec(N, y - y0_f);

            const h = cellHash2D(N, seed, x0, y0);
            const xf0 = lerp(valCoord2DFromHashVec(N, h[0]), valCoord2DFromHashVec(N, h[1]), xs);
            const xf1 = lerp(valCoord2DFromHashVec(N, h[2]), valCoord2DFromHashVec(N, h[3]), xs);

            return lerp(xf0, xf1, ys);
        }

        fn singleValue3D(comptime N: usize, seed: i32, x: @Vector(N, Float), y: @Vector(N, Float), z: @Vector(N, Float)) @Vector(N, Float) {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            const IntV = @Vector(N, i32);

            const x0_f: FloatV = @floor(x);
            const x0: IntV = @intFromFloat(x0_f);
            const y0_f: FloatV = @floor(y);
            const y0: IntV = @intFromFloat(y0_f);
            const z0_f: FloatV = @floor(z);
            const z0: IntV = @intFromFloat(z0_f);
            const xs = interpHermiteVec(N, x - x0_f);
            const ys = interpHermiteVec(N, y - y0_f);
            const zs = interpHermiteVec(N, z - z0_f);

            const h = cellHash3D(N, seed, x0, y0, z0);
            const xf00 = lerp(valCoord3DFromHashVec(N, h[0]), valCoord3DFromHashVec(N, h[1]), xs);
            const xf10 = lerp(valCoord3DFromHashVec(N, h[2]), valCoord3DFromHashVec(N, h[3]), xs);
            const xf01 = lerp(valCoord3DFromHashVec(N, h[4]), valCoord3DFromHashVec(N, h[5]), xs);
            const xf11 = lerp(valCoord3DFromHashVec(N, h[6]), valCoord3DFromHashVec(N, h[7]), xs);

            const yf0 = lerp(xf00, xf10, ys);
            const yf1 = lerp(xf01, xf11, ys);
            return lerp(yf0, yf1, zs);
        }

        fn singleValueCubic2D(comptime N: usize, seed: i32, x: @Vector(N, Float), y: @Vector(N, Float)) @Vector(N, Float) {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            const IntV = @Vector(N, i32);

            const x1_f: FloatV = @floor(x);
            const x1: IntV = @intFromFloat(x1_f);
            const y1_f: FloatV = @floor(y);
            const y1: IntV = @intFromFloat(y1_f);
            const xs: FloatV = x - x1_f;
            const ys: FloatV = y - y1_f;

            const x1p: IntV = x1 *% splat(IntV, prime_x);
            const y1p: IntV = y1 *% splat(IntV, prime_y);
            const x0p: IntV = x1p -% splat(IntV, prime_x);
            const y0p: IntV = y1p -% splat(IntV, prime_y);
            const x2p: IntV = x1p +% splat(IntV, prime_x);
            const y2p: IntV = y1p +% splat(IntV, prime_y);
            const x3p: IntV = x1p +% splat(IntV, prime_x_shl1);
            const y3p: IntV = y1p +% splat(IntV, prime_y_shl1);

            const seed_v: IntV = @splat(seed);
            const mult_v: IntV = splat(IntV, hash_multiplier);
            const x0_seed = seed_v ^ x0p;
            const x1_seed = seed_v ^ x1p;
            const x2_seed = seed_v ^ x2p;
            const x3_seed = seed_v ^ x3p;

            const row_y0 = cubicLerp(valCoord2DFromHashVec(N, (x0_seed ^ y0p) *% mult_v), valCoord2DFromHashVec(N, (x1_seed ^ y0p) *% mult_v), valCoord2DFromHashVec(N, (x2_seed ^ y0p) *% mult_v), valCoord2DFromHashVec(N, (x3_seed ^ y0p) *% mult_v), xs);
            const row_y1 = cubicLerp(valCoord2DFromHashVec(N, (x0_seed ^ y1p) *% mult_v), valCoord2DFromHashVec(N, (x1_seed ^ y1p) *% mult_v), valCoord2DFromHashVec(N, (x2_seed ^ y1p) *% mult_v), valCoord2DFromHashVec(N, (x3_seed ^ y1p) *% mult_v), xs);
            const row_y2 = cubicLerp(valCoord2DFromHashVec(N, (x0_seed ^ y2p) *% mult_v), valCoord2DFromHashVec(N, (x1_seed ^ y2p) *% mult_v), valCoord2DFromHashVec(N, (x2_seed ^ y2p) *% mult_v), valCoord2DFromHashVec(N, (x3_seed ^ y2p) *% mult_v), xs);
            const row_y3 = cubicLerp(valCoord2DFromHashVec(N, (x0_seed ^ y3p) *% mult_v), valCoord2DFromHashVec(N, (x1_seed ^ y3p) *% mult_v), valCoord2DFromHashVec(N, (x2_seed ^ y3p) *% mult_v), valCoord2DFromHashVec(N, (x3_seed ^ y3p) *% mult_v), xs);

            return cubicLerp(row_y0, row_y1, row_y2, row_y3, ys) * splat(FloatV, 1.0 / (1.5 * 1.5));
        }

        fn singleValueCubic3D(comptime N: usize, seed: i32, x: @Vector(N, Float), y: @Vector(N, Float), z: @Vector(N, Float)) @Vector(N, Float) {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            const IntV = @Vector(N, i32);

            const x1_f: FloatV = @floor(x);
            const x1: IntV = @intFromFloat(x1_f);
            const y1_f: FloatV = @floor(y);
            const y1: IntV = @intFromFloat(y1_f);
            const z1_f: FloatV = @floor(z);
            const z1: IntV = @intFromFloat(z1_f);
            const xs: FloatV = x - x1_f;
            const ys: FloatV = y - y1_f;
            const zs: FloatV = z - z1_f;

            const x1p: IntV = x1 *% splat(IntV, prime_x);
            const y1p: IntV = y1 *% splat(IntV, prime_y);
            const z1p: IntV = z1 *% splat(IntV, prime_z);
            const xps = [4]IntV{ x1p -% splat(IntV, prime_x), x1p, x1p +% splat(IntV, prime_x), x1p +% splat(IntV, prime_x_shl1) };
            const yps = [4]IntV{ y1p -% splat(IntV, prime_y), y1p, y1p +% splat(IntV, prime_y), y1p +% splat(IntV, prime_y_shl1) };
            const zps = [4]IntV{ z1p -% splat(IntV, prime_z), z1p, z1p +% splat(IntV, prime_z), z1p +% splat(IntV, prime_z_shl1) };

            const seed_v: IntV = @splat(seed);
            const mult_v: IntV = splat(IntV, hash_multiplier);
            var seed_xy: [4][4]IntV = undefined;
            inline for (0..4) |ix| inline for (0..4) |iy| {
                seed_xy[ix][iy] = seed_v ^ xps[ix] ^ yps[iy];
            };

            // Stream the interpolation one z-plane at a time instead of
            // materializing the full 4x4x4 grid (64 vector registers would
            // spill at N=8); the evaluation order x -> y -> z is unchanged.
            var z_rows: [4]FloatV = undefined;
            inline for (0..4) |iz| {
                var y_rows: [4]FloatV = undefined;
                inline for (0..4) |iy| {
                    const v0 = valCoord3DFromHashVec(N, (seed_xy[0][iy] ^ zps[iz]) *% mult_v);
                    const v1 = valCoord3DFromHashVec(N, (seed_xy[1][iy] ^ zps[iz]) *% mult_v);
                    const v2 = valCoord3DFromHashVec(N, (seed_xy[2][iy] ^ zps[iz]) *% mult_v);
                    const v3 = valCoord3DFromHashVec(N, (seed_xy[3][iy] ^ zps[iz]) *% mult_v);
                    y_rows[iy] = cubicLerp(v0, v1, v2, v3, xs);
                }
                z_rows[iz] = cubicLerp(y_rows[0], y_rows[1], y_rows[2], y_rows[3], ys);
            }
            return cubicLerp(z_rows[0], z_rows[1], z_rows[2], z_rows[3], zs) * splat(FloatV, 1.0 / (1.5 * 1.5 * 1.5));
        }

        // Simplex skewing and cell floor, shared by the plain and smooth
        // variants. Smooth 3D re-adjusts the base/deltas afterward, so the
        // primed coords are computed by each caller.
        inline fn simplexSkew2D(comptime N: usize, x: @Vector(N, Float), y: @Vector(N, Float)) struct {
            x_skewed_base: @Vector(N, i32),
            y_skewed_base: @Vector(N, i32),
            dx_skewed: @Vector(N, Float),
            dy_skewed: @Vector(N, Float),
            x_primed_base: @Vector(N, i32),
            y_primed_base: @Vector(N, i32),
        } {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            const IntV = @Vector(N, i32);
            const skew_delta = splat(FloatV, f2) * (x + y);
            const x_skewed = x + skew_delta;
            const y_skewed = y + skew_delta;
            const x_skewed_base_f: FloatV = @floor(x_skewed);
            const y_skewed_base_f: FloatV = @floor(y_skewed);
            const x_skewed_base: IntV = @intFromFloat(x_skewed_base_f);
            const y_skewed_base: IntV = @intFromFloat(y_skewed_base_f);
            return .{
                .x_skewed_base = x_skewed_base,
                .y_skewed_base = y_skewed_base,
                .dx_skewed = x_skewed - x_skewed_base_f,
                .dy_skewed = y_skewed - y_skewed_base_f,
                .x_primed_base = x_skewed_base *% splat(IntV, prime_x),
                .y_primed_base = y_skewed_base *% splat(IntV, prime_y),
            };
        }

        inline fn simplexSkew3D(comptime N: usize, x: @Vector(N, Float), y: @Vector(N, Float), z: @Vector(N, Float)) struct {
            x_skewed_base: @Vector(N, i32),
            y_skewed_base: @Vector(N, i32),
            z_skewed_base: @Vector(N, i32),
            dx_skewed: @Vector(N, Float),
            dy_skewed: @Vector(N, Float),
            dz_skewed: @Vector(N, Float),
        } {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            const skew_delta = splat(FloatV, 1.0 / 3.0) * (x + y + z);
            const x_skewed = x + skew_delta;
            const y_skewed = y + skew_delta;
            const z_skewed = z + skew_delta;
            const x_skewed_base_f: FloatV = @floor(x_skewed);
            const y_skewed_base_f: FloatV = @floor(y_skewed);
            const z_skewed_base_f: FloatV = @floor(z_skewed);
            return .{
                .x_skewed_base = @intFromFloat(x_skewed_base_f),
                .y_skewed_base = @intFromFloat(y_skewed_base_f),
                .z_skewed_base = @intFromFloat(z_skewed_base_f),
                .dx_skewed = x_skewed - x_skewed_base_f,
                .dy_skewed = y_skewed - y_skewed_base_f,
                .dz_skewed = z_skewed - z_skewed_base_f,
            };
        }

        fn singleSimplex2D(comptime N: usize, seed: i32, x: @Vector(N, Float), y: @Vector(N, Float)) @Vector(N, Float) {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            const IntV = @Vector(N, i32);
            const BoolV = @Vector(N, bool);
            const k_unskew2: FloatV = splat(FloatV, -g2);
            const k_twice_unskew2_plus_1: FloatV = splat(FloatV, 1 - 2 * g2);
            const k_falloff_radius_sq: FloatV = splat(FloatV, 0.5);

            const s = simplexSkew2D(N, x, y);

            const x_ge_y: BoolV = s.dx_skewed >= s.dy_skewed;
            const unskew_delta = k_unskew2 * (s.dx_skewed + s.dy_skewed);
            const dx0 = s.dx_skewed + unskew_delta;
            const dy0 = s.dy_skewed + unskew_delta;
            const offset_ge: FloatV = splat(FloatV, g2 - 1.0);
            const offset_lt: FloatV = splat(FloatV, g2);
            const dx1 = dx0 + @select(Float, x_ge_y, offset_ge, offset_lt);
            const dy1 = dy0 + @select(Float, x_ge_y, offset_lt, offset_ge);
            const dx2 = dx0 - k_twice_unskew2_plus_1;
            const dy2 = dy0 - k_twice_unskew2_plus_1;

            const falloff0 = @mulAdd(FloatV, -dy0, dy0, @mulAdd(FloatV, -dx0, dx0, k_falloff_radius_sq));
            const falloff1 = @mulAdd(FloatV, -dy1, dy1, @mulAdd(FloatV, -dx1, dx1, k_falloff_radius_sq));
            const falloff2 = falloff0 + @mulAdd(FloatV, unskew_delta, splat(FloatV, k_simplex2_falloff_c), splat(FloatV, -2.0 / 3.0));
            const w0 = @max(falloff0, splat(FloatV, 0));
            const w1 = @max(falloff1, splat(FloatV, 0));
            const w2 = @max(falloff2, splat(FloatV, 0));
            const gr0 = gradCoord2DVec(N, seed, s.x_primed_base, s.y_primed_base, dx0, dy0);
            const gr1 = gradCoord2DVec(N, seed, @select(i32, x_ge_y, s.x_primed_base +% splat(IntV, prime_x), s.x_primed_base), @select(i32, x_ge_y, s.y_primed_base, s.y_primed_base +% splat(IntV, prime_y)), dx1, dy1);
            const gr2 = gradCoord2DVec(N, seed, s.x_primed_base +% splat(IntV, prime_x), s.y_primed_base +% splat(IntV, prime_y), dx2, dy2);

            const value = gr2 * (w2 * w2) * (w2 * w2) + gr1 * (w1 * w1) * (w1 * w1) + gr0 * (w0 * w0) * (w0 * w0);
            return value * splat(FloatV, 1.0 / 0.0261208079755306243896484375);
        }

        fn singleSimplex3D(comptime N: usize, seed: i32, x: @Vector(N, Float), y: @Vector(N, Float), z: @Vector(N, Float)) @Vector(N, Float) {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            const IntV = @Vector(N, i32);
            const BoolV = @Vector(N, bool);
            const k_reflect_unskew3: FloatV = splat(FloatV, -0.5);
            const k_falloff_radius_sq: FloatV = splat(FloatV, 0.6);

            const s = simplexSkew3D(N, x, y, z);

            const x_ge_y: BoolV = s.dx_skewed >= s.dy_skewed;
            const y_ge_z: BoolV = s.dy_skewed >= s.dz_skewed;
            const x_ge_z: BoolV = s.dx_skewed >= s.dz_skewed;

            const unskew_delta = k_reflect_unskew3 * (s.dx_skewed + s.dy_skewed + s.dz_skewed);
            const dx0 = s.dx_skewed + unskew_delta;
            const dy0 = s.dy_skewed + unskew_delta;
            const dz0 = s.dz_skewed + unskew_delta;
            const x_primed_base: IntV = s.x_skewed_base *% splat(IntV, prime_x);
            const y_primed_base: IntV = s.y_skewed_base *% splat(IntV, prime_y);
            const z_primed_base: IntV = s.z_skewed_base *% splat(IntV, prime_z);

            const mask_x1: BoolV = x_ge_y & x_ge_z;
            const mask_y1: BoolV = y_ge_z & ~x_ge_y;
            const mask_z1: BoolV = x_ge_z | y_ge_z;
            const n_mask_x2: BoolV = x_ge_y | x_ge_z;
            const n_mask_y2: BoolV = x_ge_y & ~y_ge_z;
            const n_mask_z2: BoolV = x_ge_z & y_ge_z;

            const half: FloatV = splat(FloatV, 0.5);
            const neg_half: FloatV = splat(FloatV, -0.5);
            const one: FloatV = splat(FloatV, 1.0);
            const zero: FloatV = splat(FloatV, 0.0);
            const dx1 = dx0 + @select(Float, mask_x1, neg_half, half);
            const dy1 = dy0 + @select(Float, mask_y1, neg_half, half);
            const dz1 = dz0 + @select(Float, mask_z1, half, neg_half);
            const dx2 = dx0 + @select(Float, n_mask_x2, zero, one);
            const dy2 = dy0 + @select(Float, n_mask_y2, one, zero);
            const dz2 = dz0 + @select(Float, n_mask_z2, one, zero);
            const dx3 = dx0 + half;
            const dy3 = dy0 + half;
            const dz3 = dz0 + half;

            const falloff0 = @mulAdd(FloatV, -dz0, dz0, @mulAdd(FloatV, -dy0, dy0, @mulAdd(FloatV, -dx0, dx0, k_falloff_radius_sq)));
            const falloff1 = @mulAdd(FloatV, -dz1, dz1, @mulAdd(FloatV, -dy1, dy1, @mulAdd(FloatV, -dx1, dx1, k_falloff_radius_sq)));
            const falloff2 = @mulAdd(FloatV, -dz2, dz2, @mulAdd(FloatV, -dy2, dy2, @mulAdd(FloatV, -dx2, dx2, k_falloff_radius_sq)));
            const falloff3 = falloff0 - (unskew_delta + splat(FloatV, 3.0 / 4.0));
            const w0 = @max(falloff0, splat(FloatV, 0));
            const w1 = @max(falloff1, splat(FloatV, 0));
            const w2 = @max(falloff2, splat(FloatV, 0));
            const w3 = @max(falloff3, splat(FloatV, 0));

            const gr0 = gradCoord3DVec(N, seed, x_primed_base, y_primed_base, z_primed_base, dx0, dy0, dz0);
            const gr1 = gradCoord3DVec(N, seed, @select(i32, mask_x1, x_primed_base +% splat(IntV, prime_x), x_primed_base), @select(i32, mask_y1, y_primed_base +% splat(IntV, prime_y), y_primed_base), @select(i32, mask_z1, z_primed_base, z_primed_base +% splat(IntV, prime_z)), dx1, dy1, dz1);
            const gr2 = gradCoord3DVec(N, seed, @select(i32, n_mask_x2, x_primed_base +% splat(IntV, prime_x), x_primed_base), @select(i32, n_mask_y2, y_primed_base, y_primed_base +% splat(IntV, prime_y)), @select(i32, n_mask_z2, z_primed_base, z_primed_base +% splat(IntV, prime_z)), dx2, dy2, dz2);
            const gr3 = gradCoord3DVec(N, seed, x_primed_base +% splat(IntV, prime_x), y_primed_base +% splat(IntV, prime_y), z_primed_base +% splat(IntV, prime_z), dx3, dy3, dz3);

            const value = gr3 * (w3 * w3) * (w3 * w3) + gr2 * (w2 * w2) * (w2 * w2) + gr1 * (w1 * w1) * (w1 * w1) + gr0 * (w0 * w0) * (w0 * w0);
            return value * splat(FloatV, 1.0 / 0.030586399137973785400390625);
        }

        fn singleSimplexS2D(comptime N: usize, seed: i32, x: @Vector(N, Float), y: @Vector(N, Float)) @Vector(N, Float) {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            const IntV = @Vector(N, i32);
            const BoolV = @Vector(N, bool);
            const k_unskew2: FloatV = splat(FloatV, -g2);
            const k_falloff_radius_sq: FloatV = splat(FloatV, 2.0 / 3.0);
            const k_1_plus_2u: FloatV = splat(FloatV, 1 - 2 * g2);
            // Constant-offset select arms: k_g2_minus_1 = -(1 - g2) = -(k_unskew2 + 1),
            // k_2g2_minus_1 = -(1 - 2 * g2) = -k_1_plus_2u, k_2g2 = -k_2u (exact negations).
            const k_g2_minus_1: FloatV = splat(FloatV, g2 - 1.0);
            const k_2g2_minus_1: FloatV = splat(FloatV, 2 * g2 - 1);
            const k_2g2: FloatV = splat(FloatV, 2 * g2);

            const s = simplexSkew2D(N, x, y);

            const forward_xy: BoolV = s.dx_skewed + s.dy_skewed > splat(FloatV, 1.0);
            const boundary_xy: FloatV = @select(Float, forward_xy, splat(FloatV, -1.0), splat(FloatV, 0));
            const forward_x: BoolV = @mulAdd(FloatV, s.dx_skewed, splat(FloatV, -2.0), s.dy_skewed) < boundary_xy;
            const forward_y: BoolV = @mulAdd(FloatV, s.dy_skewed, splat(FloatV, -2.0), s.dx_skewed) < boundary_xy;

            const unskew_delta = k_unskew2 * (s.dx_skewed + s.dy_skewed);
            const dx_base = s.dx_skewed + unskew_delta;
            const dy_base = s.dy_skewed + unskew_delta;

            // Vertex <0, 0>
            const falloff_base0 = @mulAdd(FloatV, -dy_base, dy_base, @mulAdd(FloatV, -dx_base, dx_base, k_falloff_radius_sq));
            const w0 = falloff_base0 * falloff_base0;
            var value = w0 * w0 * gradCoord2DVec(N, seed, s.x_primed_base, s.y_primed_base, dx_base, dy_base);

            // Vertex <1, 1>
            {
                const grad = gradCoord2DVec(N, seed, s.x_primed_base +% splat(IntV, prime_x), s.y_primed_base +% splat(IntV, prime_y), dx_base - k_1_plus_2u, dy_base - k_1_plus_2u);
                const falloff = @mulAdd(FloatV, unskew_delta, splat(FloatV, k_simplex2_falloff_c), falloff_base0 - k_falloff_radius_sq);
                const w1 = falloff * falloff;
                value += w1 * w1 * grad;
            }

            // dx_base - (forward_xy ? 1 - g2 : g2) == dx_base + (forward_xy ? g2 - 1 : -g2).
            const dx_base1 = dx_base + @select(Float, forward_xy, k_g2_minus_1, k_unskew2);
            const dy_base1 = dy_base + @select(Float, forward_xy, k_g2_minus_1, k_unskew2);

            // Vertex <1, 0> or <-1, 0> or <1, 2>
            {
                const x_primed = @select(i32, forward_xy, @select(i32, forward_x, s.x_primed_base +% splat(IntV, prime_x *% 2), s.x_primed_base), @select(i32, forward_x, s.x_primed_base +% splat(IntV, prime_x *% 2), s.x_primed_base) -% splat(IntV, prime_x));
                const y_primed = @select(i32, forward_xy, s.y_primed_base +% splat(IntV, prime_y), s.y_primed_base);
                const dx = dx_base1 + @select(Float, forward_x, k_2g2_minus_1, splat(FloatV, 1));
                const dy = dy_base1 + @select(Float, forward_x, k_2g2, splat(FloatV, 0));
                const falloff = @max(@mulAdd(FloatV, -dy, dy, @mulAdd(FloatV, -dx, dx, k_falloff_radius_sq)), splat(FloatV, 0));
                const w2 = falloff * falloff;
                value += w2 * w2 * gradCoord2DVec(N, seed, x_primed, y_primed, dx, dy);
            }

            // Vertex <0, 1> or <0, -1> or <2, 1>
            {
                const x_primed = @select(i32, forward_xy, s.x_primed_base +% splat(IntV, prime_x), s.x_primed_base);
                const y_primed = @select(i32, forward_xy, @select(i32, forward_y, s.y_primed_base +% splat(IntV, prime_y *% 2), s.y_primed_base), @select(i32, forward_y, s.y_primed_base +% splat(IntV, prime_y *% 2), s.y_primed_base) -% splat(IntV, prime_y));
                const dx = dx_base1 + @select(Float, forward_y, k_2g2, splat(FloatV, 0));
                const dy = dy_base1 + @select(Float, forward_y, k_2g2_minus_1, splat(FloatV, 1));
                const falloff = @max(@mulAdd(FloatV, -dy, dy, @mulAdd(FloatV, -dx, dx, k_falloff_radius_sq)), splat(FloatV, 0));
                const w3 = falloff * falloff;
                value += w3 * w3 * gradCoord2DVec(N, seed, x_primed, y_primed, dx, dy);
            }

            return value * splat(FloatV, 1.0 / 0.14084912836551666259765625);
        }

        fn singleSimplexS3D(comptime N: usize, seed: i32, x: @Vector(N, Float), y: @Vector(N, Float), z: @Vector(N, Float)) @Vector(N, Float) {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            const IntV = @Vector(N, i32);
            const BoolV = @Vector(N, bool);
            const k_reflect_unskew3: FloatV = splat(FloatV, -0.5);
            const k_twice_unskew3: FloatV = splat(FloatV, -0.25);
            const k_falloff_radius_sq: FloatV = splat(FloatV, 0.75);

            const s = simplexSkew3D(N, x, y, z);
            var x_skewed_base: IntV = s.x_skewed_base;
            var y_skewed_base: IntV = s.y_skewed_base;
            var z_skewed_base: IntV = s.z_skewed_base;
            var dx_skewed = s.dx_skewed;
            var dy_skewed = s.dy_skewed;
            var dz_skewed = s.dz_skewed;

            {
                const twice_unskew_delta = k_twice_unskew3 * (dx_skewed + dy_skewed + dz_skewed);
                const x_normal = dx_skewed + twice_unskew_delta;
                const y_normal = dy_skewed + twice_unskew_delta;
                const z_normal = dz_skewed + twice_unskew_delta;
                const xyz_normal = -twice_unskew_delta;

                var max_score: FloatV = @splat(0.375);
                var move_mask_bits: IntV = @select(i32, xyz_normal > max_score, splat(IntV, -1), splat(IntV, 0));
                max_score = @max(max_score, xyz_normal);
                move_mask_bits = @select(i32, x_normal > max_score, splat(IntV, 1), move_mask_bits);
                max_score = @max(max_score, x_normal);
                move_mask_bits = @select(i32, y_normal > max_score, splat(IntV, 2), move_mask_bits);
                max_score = @max(max_score, y_normal);
                move_mask_bits = @select(i32, z_normal > max_score, splat(IntV, 4), move_mask_bits);
                max_score = @max(max_score, z_normal);
                max_score += splat(FloatV, 0.125) - xyz_normal;
                move_mask_bits = @select(i32, -z_normal > max_score, splat(IntV, 3), move_mask_bits);
                max_score = @max(max_score, -z_normal);
                move_mask_bits = @select(i32, -y_normal > max_score, splat(IntV, 5), move_mask_bits);
                max_score = @max(max_score, -y_normal);
                move_mask_bits = @select(i32, -x_normal > max_score, splat(IntV, 6), move_mask_bits);
                max_score = @max(max_score, -x_normal);

                const move_x: BoolV = (move_mask_bits & splat(IntV, 1)) != splat(IntV, 0);
                const move_y: BoolV = (move_mask_bits & splat(IntV, 2)) != splat(IntV, 0);
                const move_z: BoolV = (move_mask_bits & splat(IntV, 4)) != splat(IntV, 0);
                x_skewed_base = @select(i32, move_x, x_skewed_base +% splat(IntV, 1), x_skewed_base);
                y_skewed_base = @select(i32, move_y, y_skewed_base +% splat(IntV, 1), y_skewed_base);
                z_skewed_base = @select(i32, move_z, z_skewed_base +% splat(IntV, 1), z_skewed_base);
                dx_skewed = @select(Float, move_x, dx_skewed - splat(FloatV, 1), dx_skewed);
                dy_skewed = @select(Float, move_y, dy_skewed - splat(FloatV, 1), dy_skewed);
                dz_skewed = @select(Float, move_z, dz_skewed - splat(FloatV, 1), dz_skewed);
            }

            const x_primed_base: IntV = x_skewed_base *% splat(IntV, prime_x);
            const y_primed_base: IntV = y_skewed_base *% splat(IntV, prime_y);
            const z_primed_base: IntV = z_skewed_base *% splat(IntV, prime_z);

            const skewed_sum = dx_skewed + dy_skewed + dz_skewed;
            const twice_unskew_delta = k_twice_unskew3 * skewed_sum;
            const x_normal = dx_skewed + twice_unskew_delta;
            const y_normal = dy_skewed + twice_unskew_delta;
            const z_normal = dz_skewed + twice_unskew_delta;
            const xyz_normal = -twice_unskew_delta;

            // k_reflect_unskew3 == -0.5, so unskew_delta doubles as the
            // coordinate_sum term (3 * k_reflect_unskew3 + 1 = -0.5).
            const unskew_delta = k_reflect_unskew3 * skewed_sum;
            const dx_base = dx_skewed + unskew_delta;
            const dy_base = dy_skewed + unskew_delta;
            const dz_base = dz_skewed + unskew_delta;

            // Vertex <0, 0, 0>
            var value: FloatV = undefined;
            var falloff_base_stem_a: FloatV = undefined;
            var falloff_base_stem_b: FloatV = undefined;
            {
                const falloff_base = @mulAdd(FloatV, -dz_base, dz_base, @mulAdd(FloatV, -dy_base, dy_base, @mulAdd(FloatV, -dx_base, dx_base, k_falloff_radius_sq))) * splat(FloatV, 0.5);
                falloff_base_stem_a = falloff_base - splat(FloatV, 0.375);
                falloff_base_stem_b = falloff_base - splat(FloatV, 0.5);
                const f0 = falloff_base * falloff_base;
                value = f0 * f0 * gradCoord3DVec(N, seed, x_primed_base, y_primed_base, z_primed_base, dx_base, dy_base, dz_base);
            }

            // Vertex <1, 1, 1> or <-1, -1, -1>
            {
                const sign_mask: BoolV = xyz_normal < splat(FloatV, 0);
                const x_primed = @select(i32, sign_mask, x_primed_base -% splat(IntV, prime_x), x_primed_base +% splat(IntV, prime_x));
                const y_primed = @select(i32, sign_mask, y_primed_base -% splat(IntV, prime_y), y_primed_base +% splat(IntV, prime_y));
                const z_primed = @select(i32, sign_mask, z_primed_base -% splat(IntV, prime_z), z_primed_base +% splat(IntV, prime_z));
                const offset = @select(Float, sign_mask, splat(FloatV, 0.5), splat(FloatV, -0.5));
                const grad = gradCoord3DVec(N, seed, x_primed, y_primed, z_primed, dx_base - offset, dy_base - offset, dz_base - offset);
                // offset * unskew_delta is exact (offset is a power of two), so
                // the FMA form rounds identically to mul-then-add.
                const falloff_base = @max(@mulAdd(FloatV, offset, unskew_delta, falloff_base_stem_a), splat(FloatV, 0));
                const f = falloff_base * falloff_base;
                value += f * f * grad;
            }

            // Vertex <1, 1, 0> or <-1, -1, 0>
            {
                const sign_mask: BoolV = xyz_normal < z_normal;
                const x_primed = @select(i32, sign_mask, x_primed_base -% splat(IntV, prime_x), x_primed_base +% splat(IntV, prime_x));
                const y_primed = @select(i32, sign_mask, y_primed_base -% splat(IntV, prime_y), y_primed_base +% splat(IntV, prime_y));
                const offset0 = @select(Float, sign_mask, splat(FloatV, 1.0), splat(FloatV, -1.0));
                const grad = gradCoord3DVec(N, seed, x_primed, y_primed, z_primed_base, dx_base, dy_base, dz_base - offset0);
                const falloff_base = @min(@select(Float, sign_mask, -dz_base, dz_base) - falloff_base_stem_b, splat(FloatV, 0));
                const f = falloff_base * falloff_base;
                value += f * f * grad;
            }

            // Vertex <1, 0, 1> or <-1, 0, -1>
            {
                const sign_mask: BoolV = xyz_normal < y_normal;
                const x_primed = @select(i32, sign_mask, x_primed_base -% splat(IntV, prime_x), x_primed_base +% splat(IntV, prime_x));
                const z_primed = @select(i32, sign_mask, z_primed_base -% splat(IntV, prime_z), z_primed_base +% splat(IntV, prime_z));
                const offset0 = @select(Float, sign_mask, splat(FloatV, 1.0), splat(FloatV, -1.0));
                const grad = gradCoord3DVec(N, seed, x_primed, y_primed_base, z_primed, dx_base, dy_base - offset0, dz_base);
                const falloff_base = @min(@select(Float, sign_mask, -dy_base, dy_base) - falloff_base_stem_b, splat(FloatV, 0));
                const f = falloff_base * falloff_base;
                value += f * f * grad;
            }

            // Vertex <0, 1, 1> or <0, -1, -1>
            {
                const sign_mask: BoolV = xyz_normal < x_normal;
                const y_primed = @select(i32, sign_mask, y_primed_base -% splat(IntV, prime_y), y_primed_base +% splat(IntV, prime_y));
                const z_primed = @select(i32, sign_mask, z_primed_base -% splat(IntV, prime_z), z_primed_base +% splat(IntV, prime_z));
                const offset0 = @select(Float, sign_mask, splat(FloatV, 1.0), splat(FloatV, -1.0));
                const grad = gradCoord3DVec(N, seed, x_primed_base, y_primed, z_primed, dx_base - offset0, dy_base, dz_base);
                const falloff_base = @min(@select(Float, sign_mask, -dx_base, dx_base) - falloff_base_stem_b, splat(FloatV, 0));
                const f = falloff_base * falloff_base;
                value += f * f * grad;
            }

            // Vertex <1, 0, 0> or <-1, 0, 0>
            {
                const sign_mask: BoolV = x_normal < splat(FloatV, 0);
                const x_primed = @select(i32, sign_mask, x_primed_base -% splat(IntV, prime_x), x_primed_base +% splat(IntV, prime_x));
                const offset0 = @select(Float, sign_mask, splat(FloatV, 0.5), splat(FloatV, -0.5));
                const grad = gradCoord3DVec(N, seed, x_primed, y_primed_base, z_primed_base, dx_base + offset0, dy_base - offset0, dz_base - offset0);
                const falloff_base = @max(@mulAdd(FloatV, offset0, unskew_delta, falloff_base_stem_a) + @select(Float, sign_mask, -dx_base, dx_base), splat(FloatV, 0));
                const f = falloff_base * falloff_base;
                value += f * f * grad;
            }

            // Vertex <0, 1, 0> or <0, -1, 0>
            {
                const sign_mask: BoolV = y_normal < splat(FloatV, 0);
                const y_primed = @select(i32, sign_mask, y_primed_base -% splat(IntV, prime_y), y_primed_base +% splat(IntV, prime_y));
                const offset0 = @select(Float, sign_mask, splat(FloatV, 0.5), splat(FloatV, -0.5));
                const grad = gradCoord3DVec(N, seed, x_primed_base, y_primed, z_primed_base, dx_base - offset0, dy_base + offset0, dz_base - offset0);
                const falloff_base = @max(@mulAdd(FloatV, offset0, unskew_delta, falloff_base_stem_a) + @select(Float, sign_mask, -dy_base, dy_base), splat(FloatV, 0));
                const f = falloff_base * falloff_base;
                value += f * f * grad;
            }

            // Vertex <0, 0, 1> or <0, 0, -1>
            {
                const sign_mask: BoolV = z_normal < splat(FloatV, 0);
                const z_primed = @select(i32, sign_mask, z_primed_base -% splat(IntV, prime_z), z_primed_base +% splat(IntV, prime_z));
                const offset0 = @select(Float, sign_mask, splat(FloatV, 0.5), splat(FloatV, -0.5));
                const grad = gradCoord3DVec(N, seed, x_primed_base, y_primed_base, z_primed, dx_base - offset0, dy_base - offset0, dz_base + offset0);
                const falloff_base = @max(@mulAdd(FloatV, offset0, unskew_delta, falloff_base_stem_a) + @select(Float, sign_mask, -dz_base, dz_base), splat(FloatV, 0));
                const f = falloff_base * falloff_base;
                value += f * f * grad;
            }

            return value * splat(FloatV, 1.0 / 0.0069091119803488254547119140625);
        }

        // Cellular Noise

        inline fn cellularDelta2D(comptime N: usize, seed: i32, xi_primed: @Vector(N, i32), yi_primed: @Vector(N, i32), jitter: Float, vx_base: @Vector(N, Float), vy_base: @Vector(N, Float)) struct { vx: @Vector(N, Float), vy: @Vector(N, Float), hash: @Vector(N, i32) } {
            @setFloatMode(.optimized);
            const IntV = @Vector(N, i32);
            const FloatV = @Vector(N, Float);
            // The random offset is derived from two 11-bit hash fields and
            // normalized to the jitter radius, avoiding a table gather.  The
            // primed coordinates and the lattice-origin subtraction are
            // hoisted by the caller (integer multiply distributes exactly, so
            // the hash is bit-identical).
            const hash = hash2DVec(N, seed, xi_primed, yi_primed);
            const hash_u: @Vector(N, u32) = @bitCast(hash);
            const xd: FloatV = floatFromInt(FloatV, @as(IntV, @bitCast(hash_u & splat(@Vector(N, u32), 0x7ff)))) - splat(FloatV, 1023.5);
            const yd: FloatV = floatFromInt(FloatV, @as(IntV, @bitCast(hash_u >> splat(@Vector(N, u32), 21)))) - splat(FloatV, 1023.5);
            const inv_mag: FloatV = splat(FloatV, jitter) / @sqrt(xd * xd + yd * yd);
            return .{
                .vx = xd * inv_mag + vx_base,
                .vy = yd * inv_mag + vy_base,
                .hash = hash,
            };
        }

        inline fn cellularDelta3D(comptime N: usize, seed: i32, xi_primed: @Vector(N, i32), yi_primed: @Vector(N, i32), zi_primed: @Vector(N, i32), jitter: Float, vx_base: @Vector(N, Float), vy_base: @Vector(N, Float), vz_base: @Vector(N, Float)) struct { vx: @Vector(N, Float), vy: @Vector(N, Float), vz: @Vector(N, Float), hash: @Vector(N, i32) } {
            @setFloatMode(.optimized);
            const IntV = @Vector(N, i32);
            const FloatV = @Vector(N, Float);
            // The random offset is derived from three 10-bit hash fields and
            // normalized to the jitter radius, avoiding a table gather.  The
            // primed coordinates and the lattice-origin subtraction are
            // hoisted by the caller (integer multiply distributes exactly, so
            // the hash is bit-identical).
            const hash = hash3DVec(N, seed, xi_primed, yi_primed, zi_primed);
            const hash_u: @Vector(N, u32) = @bitCast(hash);
            const xd: FloatV = floatFromInt(FloatV, @as(IntV, @bitCast(hash_u & splat(@Vector(N, u32), 0x3ff)))) - splat(FloatV, 511.5);
            const yd: FloatV = floatFromInt(FloatV, @as(IntV, @bitCast((hash_u >> splat(@Vector(N, u32), 11)) & splat(@Vector(N, u32), 0x3ff)))) - splat(FloatV, 511.5);
            const zd: FloatV = floatFromInt(FloatV, @as(IntV, @bitCast(hash_u >> splat(@Vector(N, u32), 22)))) - splat(FloatV, 511.5);
            const inv_mag: FloatV = splat(FloatV, jitter) / @sqrt(xd * xd + yd * yd + zd * zd);
            return .{
                .vx = xd * inv_mag + vx_base,
                .vy = yd * inv_mag + vy_base,
                .vz = zd * inv_mag + vz_base,
                .hash = hash,
            };
        }

        inline fn updateCellular(comptime N: usize, dist0: *@Vector(N, Float), dist1: *@Vector(N, Float), closest_hash: *@Vector(N, i32), hash: @Vector(N, i32), new_dist: @Vector(N, Float), track_hash: bool, track_dist1: bool) void {
            @setFloatMode(.optimized);
            // The return type is invariant for the whole fill, so these branches
            // are perfectly predicted; they skip vector work that is dead for
            // the active return type (closest_hash is only read by .cell_value,
            // dist1 only by the .distance2* family).
            if (track_dist1) dist1.* = @max(@min(dist1.*, new_dist), dist0.*);
            if (track_hash) {
                const mask = new_dist < dist0.*;
                dist0.* = @select(Float, mask, new_dist, dist0.*);
                closest_hash.* = @select(i32, mask, hash, closest_hash.*);
            } else {
                // min selects the same lanes as (new < dist0) ? new : dist0 here.
                dist0.* = @min(dist0.*, new_dist);
            }
        }

        // Folds the configured distance metric over the nine neighbor cells.
        // `mode` is comptime, so each distance function still generates its own
        // unrolled loop with no per-cell branch.
        inline fn cellularLoop2D(comptime N: usize, comptime mode: CellularDistanceFunc, seed: i32, xr_primed: @Vector(N, i32), yr_primed: @Vector(N, i32), xr_minus_x: @Vector(N, Float), yr_minus_y: @Vector(N, Float), jitter: Float, dist0: *@Vector(N, Float), dist1: *@Vector(N, Float), closest_hash: *@Vector(N, i32), comptime track_hash: bool, comptime track_dist1: bool) void {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            const IntV = @Vector(N, i32);
            const offsets = [3]i32{ -1, 0, 1 };
            inline for (offsets) |ox| {
                inline for (offsets) |oy| {
                    const cell = cellularDelta2D(
                        N,
                        seed,
                        xr_primed +% splat(IntV, ox *% prime_x),
                        yr_primed +% splat(IntV, oy *% prime_y),
                        jitter,
                        xr_minus_x + splat(FloatV, @as(Float, @floatFromInt(ox))),
                        yr_minus_y + splat(FloatV, @as(Float, @floatFromInt(oy))),
                    );
                    const new_dist: FloatV = switch (mode) {
                        .euclidean, .euclidean_sq => cell.vx * cell.vx + cell.vy * cell.vy,
                        .manhattan => @abs(cell.vx) + @abs(cell.vy),
                        .hybrid => (@abs(cell.vx) + @abs(cell.vy)) + (cell.vx * cell.vx + cell.vy * cell.vy),
                    };
                    updateCellular(N, dist0, dist1, closest_hash, cell.hash, new_dist, track_hash, track_dist1);
                }
            }
        }

        fn singleCellular2D(comptime N: usize, state: *const State, seed: i32, x: @Vector(N, Float), y: @Vector(N, Float)) @Vector(N, Float) {
            // The update flags depend only on the return type; dispatching
            // them comptime removes two predicted branches per cell from the
            // inner loops (9 cells/chunk in 2D, 27 in 3D).
            return switch (state.cellular_return) {
                .cell_value => singleCellular2DRet(N, state, seed, x, y, true, false),
                .distance => singleCellular2DRet(N, state, seed, x, y, false, false),
                .distance2, .distance2_add, .distance2_sub, .distance2_mul, .distance2_div => singleCellular2DRet(N, state, seed, x, y, false, true),
            };
        }

        fn singleCellular2DRet(comptime N: usize, state: *const State, seed: i32, x: @Vector(N, Float), y: @Vector(N, Float), comptime track_hash: bool, comptime track_dist1: bool) @Vector(N, Float) {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            const IntV = @Vector(N, i32);

            const xr: IntV = @round(x);
            const yr: IntV = @round(y);
            var dist0: FloatV = @splat(std.math.floatMax(Float));
            var dist1: FloatV = @splat(std.math.floatMax(Float));
            var closest_hash: IntV = @splat(0);

            // Per-chunk cell arithmetic shared by all nine neighbors: the
            // primed lattice coordinates and the lattice-origin offset are
            // hoisted out of the cell loop (integer multiply distributes
            // exactly, the float reassociation is within 1 ULP).
            const xr_primed: IntV = xr *% splat(IntV, prime_x);
            const yr_primed: IntV = yr *% splat(IntV, prime_y);
            const xr_minus_x: FloatV = floatFromInt(FloatV, xr) - x;
            const yr_minus_y: FloatV = floatFromInt(FloatV, yr) - y;

            const jitter = 0.43701595 * state.cellular_jitter_mod;
            switch (state.cellular_distance) {
                .euclidean, .euclidean_sq => cellularLoop2D(N, .euclidean, seed, xr_primed, yr_primed, xr_minus_x, yr_minus_y, jitter, &dist0, &dist1, &closest_hash, track_hash, track_dist1),
                .manhattan => cellularLoop2D(N, .manhattan, seed, xr_primed, yr_primed, xr_minus_x, yr_minus_y, jitter, &dist0, &dist1, &closest_hash, track_hash, track_dist1),
                .hybrid => cellularLoop2D(N, .hybrid, seed, xr_primed, yr_primed, xr_minus_x, yr_minus_y, jitter, &dist0, &dist1, &closest_hash, track_hash, track_dist1),
            }

            if (state.cellular_distance == .euclidean and state.cellular_return != .cell_value) {
                dist0 = @sqrt(dist0);
                if (state.cellular_return != .distance) dist1 = @sqrt(dist1);
            }

            const result = switch (state.cellular_return) {
                .cell_value => floatFromInt(FloatV, closest_hash) * splat(FloatV, 1.0 / 2147483648.0),
                .distance => dist0 - splat(FloatV, 1.0),
                .distance2 => dist1 - splat(FloatV, 1.0),
                .distance2_add => @mulAdd(FloatV, dist1 + dist0, splat(FloatV, 0.5), splat(FloatV, -1.0)),
                .distance2_sub => (dist1 - dist0) - splat(FloatV, 1.0),
                .distance2_mul => @mulAdd(FloatV, dist1 * dist0, splat(FloatV, 0.5), splat(FloatV, -1.0)),
                .distance2_div => (dist0 / dist1) - splat(FloatV, 1.0),
            };

            // "hybrid" can result in out of range values
            return @max(splat(FloatV, -1.0), @min(splat(FloatV, 1.0), result));
        }

        fn cellularLoop3D(comptime N: usize, comptime mode: CellularDistanceFunc, seed: i32, xr_primed: @Vector(N, i32), yr_primed: @Vector(N, i32), zr_primed: @Vector(N, i32), xr_minus_x: @Vector(N, Float), yr_minus_y: @Vector(N, Float), zr_minus_z: @Vector(N, Float), jitter: Float, dist0: *@Vector(N, Float), dist1: *@Vector(N, Float), closest_hash: *@Vector(N, i32), comptime track_hash: bool, comptime track_dist1: bool) void {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            const IntV = @Vector(N, i32);
            const offsets = [3]i32{ -1, 0, 1 };
            inline for (offsets) |ox| {
                inline for (offsets) |oy| {
                    inline for (offsets) |oz| {
                        const cell = cellularDelta3D(
                            N,
                            seed,
                            xr_primed +% splat(IntV, ox *% prime_x),
                            yr_primed +% splat(IntV, oy *% prime_y),
                            zr_primed +% splat(IntV, oz *% prime_z),
                            jitter,
                            xr_minus_x + splat(FloatV, @as(Float, @floatFromInt(ox))),
                            yr_minus_y + splat(FloatV, @as(Float, @floatFromInt(oy))),
                            zr_minus_z + splat(FloatV, @as(Float, @floatFromInt(oz))),
                        );
                        const new_dist: FloatV = switch (mode) {
                            .euclidean, .euclidean_sq => cell.vx * cell.vx + cell.vy * cell.vy + cell.vz * cell.vz,
                            .manhattan => @abs(cell.vx) + @abs(cell.vy) + @abs(cell.vz),
                            .hybrid => (@abs(cell.vx) + @abs(cell.vy) + @abs(cell.vz)) + (cell.vx * cell.vx + cell.vy * cell.vy + cell.vz * cell.vz),
                        };
                        updateCellular(N, dist0, dist1, closest_hash, cell.hash, new_dist, track_hash, track_dist1);
                    }
                }
            }
        }

        fn singleCellular3D(comptime N: usize, state: *const State, seed: i32, x: @Vector(N, Float), y: @Vector(N, Float), z: @Vector(N, Float)) @Vector(N, Float) {
            // Comptime update flags; see singleCellular2D.
            return switch (state.cellular_return) {
                .cell_value => singleCellular3DRet(N, state, seed, x, y, z, true, false),
                .distance => singleCellular3DRet(N, state, seed, x, y, z, false, false),
                .distance2, .distance2_add, .distance2_sub, .distance2_mul, .distance2_div => singleCellular3DRet(N, state, seed, x, y, z, false, true),
            };
        }

        fn singleCellular3DRet(comptime N: usize, state: *const State, seed: i32, x: @Vector(N, Float), y: @Vector(N, Float), z: @Vector(N, Float), comptime track_hash: bool, comptime track_dist1: bool) @Vector(N, Float) {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            const IntV = @Vector(N, i32);

            const xr: IntV = @round(x);
            const yr: IntV = @round(y);
            const zr: IntV = @round(z);
            var dist0: FloatV = @splat(std.math.floatMax(Float));
            var dist1: FloatV = @splat(std.math.floatMax(Float));
            var closest_hash: IntV = @splat(0);

            // Per-chunk cell arithmetic shared by all 27 neighbors: the
            // primed lattice coordinates and the lattice-origin offset are
            // hoisted out of the cell loop (integer multiply distributes
            // exactly, the float reassociation is within 1 ULP).
            const xr_primed: IntV = xr *% splat(IntV, prime_x);
            const yr_primed: IntV = yr *% splat(IntV, prime_y);
            const zr_primed: IntV = zr *% splat(IntV, prime_z);
            const xr_minus_x: FloatV = floatFromInt(FloatV, xr) - x;
            const yr_minus_y: FloatV = floatFromInt(FloatV, yr) - y;
            const zr_minus_z: FloatV = floatFromInt(FloatV, zr) - z;

            const jitter = 0.39614353 * state.cellular_jitter_mod;
            switch (state.cellular_distance) {
                .euclidean, .euclidean_sq => cellularLoop3D(N, .euclidean, seed, xr_primed, yr_primed, zr_primed, xr_minus_x, yr_minus_y, zr_minus_z, jitter, &dist0, &dist1, &closest_hash, track_hash, track_dist1),
                .manhattan => cellularLoop3D(N, .manhattan, seed, xr_primed, yr_primed, zr_primed, xr_minus_x, yr_minus_y, zr_minus_z, jitter, &dist0, &dist1, &closest_hash, track_hash, track_dist1),
                .hybrid => cellularLoop3D(N, .hybrid, seed, xr_primed, yr_primed, zr_primed, xr_minus_x, yr_minus_y, zr_minus_z, jitter, &dist0, &dist1, &closest_hash, track_hash, track_dist1),
            }

            if (state.cellular_distance == .euclidean and state.cellular_return != .cell_value) {
                dist0 = @sqrt(dist0);
                if (state.cellular_return != .distance) dist1 = @sqrt(dist1);
            }

            const result = switch (state.cellular_return) {
                .cell_value => floatFromInt(FloatV, closest_hash) * splat(FloatV, 1.0 / 2147483648.0),
                .distance => dist0 - splat(FloatV, 1.0),
                .distance2 => dist1 - splat(FloatV, 1.0),
                .distance2_add => @mulAdd(FloatV, dist1 + dist0, splat(FloatV, 0.5), splat(FloatV, -1.0)),
                .distance2_sub => (dist1 - dist0) - splat(FloatV, 1.0),
                .distance2_mul => @mulAdd(FloatV, dist1 * dist0, splat(FloatV, 0.5), splat(FloatV, -1.0)),
                .distance2_div => (dist0 / dist1) - splat(FloatV, 1.0),
            };

            // "hybrid" can result in out of range values
            return @max(splat(FloatV, -1.0), @min(splat(FloatV, 1.0), result));
        }

        // Fractal

        // Maps one octave's raw noise to its contribution for the unweighted
        // even/odd chain. `fractal` is comptime, so the transform folds away.
        inline fn octaveNoise2D(comptime N: usize, comptime noise: NoiseType, comptime fractal: FractalType, state: *const State, seed: i32, xv: @Vector(N, Float), yv: @Vector(N, Float), strength: @Vector(N, Float)) @Vector(N, Float) {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            const raw = genNoiseSingle2D(N, noise, state, seed, xv, yv);
            return switch (fractal) {
                .fbm => raw,
                .ridged => @abs(raw),
                .ping_pong => pingPongVec(N, (raw + splat(FloatV, 1.0)) * strength),
                else => unreachable,
            };
        }

        inline fn octaveNoise3D(comptime N: usize, comptime noise: NoiseType, comptime fractal: FractalType, state: *const State, seed: i32, xv: @Vector(N, Float), yv: @Vector(N, Float), zv: @Vector(N, Float), strength: @Vector(N, Float)) @Vector(N, Float) {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            const raw = genNoiseSingle3D(N, noise, state, seed, xv, yv, zv);
            return switch (fractal) {
                .fbm => raw,
                .ridged => @abs(raw),
                .ping_pong => pingPongVec(N, (raw + splat(FloatV, 1.0)) * strength),
                else => unreachable,
            };
        }

        // The even/odd octave chain shared by the unweighted fbm/ridged/
        // ping-pong paths. Interleaving even and odd octaves halves the serial
        // sum/amp latency and overlaps the two noise evaluations; `fractal` is
        // comptime so the per-octave transform, tail sum form, and final
        // combine fold to the same codegen as the hand-written copies.
        fn fractalEvenOdd2D(comptime N: usize, comptime noise: NoiseType, comptime fractal: FractalType, state: *const State, seed: i32, bounding: Float, x: @Vector(N, Float), y: @Vector(N, Float)) @Vector(N, Float) {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            const gain: FloatV = @splat(state.gain);
            const lac: FloatV = @splat(state.lacunarity);
            const gain_sq: FloatV = gain * gain;
            const strength: FloatV = @splat(state.ping_pong_strength);
            var sum0: FloatV = @splat(0);
            var sum1: FloatV = @splat(0);
            var xv = x;
            var yv = y;
            var amp0: FloatV = @splat(bounding);
            var amp1: FloatV = amp0 * gain;
            var i: u32 = 0;
            while (i + 1 < state.octaves) : (i += 2) {
                // All three coordinate pairs for the pair are computed up
                // front so the next iteration's floor can start as soon as
                // these muls retire, overlapping the noise evaluations below.
                const xv1 = xv * lac;
                const yv1 = yv * lac;
                const xv2 = xv1 * lac;
                const yv2 = yv1 * lac;
                const n0 = octaveNoise2D(N, noise, fractal, state, seed +% @as(i32, @intCast(i)), xv, yv, strength);
                const n1 = octaveNoise2D(N, noise, fractal, state, seed +% @as(i32, @intCast(i + 1)), xv1, yv1, strength);
                sum0 = @mulAdd(FloatV, n0, amp0, sum0);
                sum1 = @mulAdd(FloatV, n1, amp1, sum1);
                xv = xv2;
                yv = yv2;
                amp0 *= gain_sq;
                amp1 *= gain_sq;
            }
            if (i < state.octaves) {
                const n = octaveNoise2D(N, noise, fractal, state, seed +% @as(i32, @intCast(i)), xv, yv, strength);
                switch (fractal) {
                    .fbm => sum0 += n * amp0,
                    .ridged, .ping_pong => sum0 = @mulAdd(FloatV, n, amp0, sum0),
                    else => unreachable,
                }
            }
            return switch (fractal) {
                .fbm => sum0 + sum1,
                .ridged => @mulAdd(FloatV, sum0 + sum1, splat(FloatV, -2.0), splat(FloatV, 1.0)),
                .ping_pong => @mulAdd(FloatV, sum0 + sum1, splat(FloatV, 2.0), splat(FloatV, -1.0)),
                else => unreachable,
            };
        }

        fn fractalEvenOdd3D(comptime N: usize, comptime noise: NoiseType, comptime fractal: FractalType, state: *const State, seed: i32, bounding: Float, x: @Vector(N, Float), y: @Vector(N, Float), z: @Vector(N, Float)) @Vector(N, Float) {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            const gain: FloatV = @splat(state.gain);
            const lac: FloatV = @splat(state.lacunarity);
            const gain_sq: FloatV = gain * gain;
            const strength: FloatV = @splat(state.ping_pong_strength);
            var sum0: FloatV = @splat(0);
            var sum1: FloatV = @splat(0);
            var xv = x;
            var yv = y;
            var zv = z;
            var amp0: FloatV = @splat(bounding);
            var amp1: FloatV = amp0 * gain;
            var i: u32 = 0;
            while (i + 1 < state.octaves) : (i += 2) {
                // All three coordinate triples computed up front; see the 2D
                // even/odd loop for why.
                const xv1 = xv * lac;
                const yv1 = yv * lac;
                const zv1 = zv * lac;
                const xv2 = xv1 * lac;
                const yv2 = yv1 * lac;
                const zv2 = zv1 * lac;
                const n0 = octaveNoise3D(N, noise, fractal, state, seed +% @as(i32, @intCast(i)), xv, yv, zv, strength);
                const n1 = octaveNoise3D(N, noise, fractal, state, seed +% @as(i32, @intCast(i + 1)), xv1, yv1, zv1, strength);
                sum0 = @mulAdd(FloatV, n0, amp0, sum0);
                sum1 = @mulAdd(FloatV, n1, amp1, sum1);
                xv = xv2;
                yv = yv2;
                zv = zv2;
                amp0 *= gain_sq;
                amp1 *= gain_sq;
            }
            if (i < state.octaves) {
                const n = octaveNoise3D(N, noise, fractal, state, seed +% @as(i32, @intCast(i)), xv, yv, zv, strength);
                switch (fractal) {
                    .fbm => sum0 += n * amp0,
                    .ridged, .ping_pong => sum0 = @mulAdd(FloatV, n, amp0, sum0),
                    else => unreachable,
                }
            }
            return switch (fractal) {
                .fbm => sum0 + sum1,
                .ridged => @mulAdd(FloatV, sum0 + sum1, splat(FloatV, -2.0), splat(FloatV, 1.0)),
                .ping_pong => @mulAdd(FloatV, sum0 + sum1, splat(FloatV, 2.0), splat(FloatV, -1.0)),
                else => unreachable,
            };
        }

        // The weighted_strength != 0 path shared by the fbm/ridged/ping-pong
        // fractal types. `fractal` is comptime so the per-octave transform, the
        // sum combine, and the amplitude weighting fold to the same codegen as
        // the hand-written copies.
        fn fractalWeighted2D(comptime N: usize, comptime noise: NoiseType, comptime fractal: FractalType, state: *const State, seed: i32, bounding: Float, x: @Vector(N, Float), y: @Vector(N, Float)) @Vector(N, Float) {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            const gain: FloatV = @splat(state.gain);
            const lac: FloatV = @splat(state.lacunarity);
            const weighted: FloatV = @splat(state.weighted_strength);
            const strength: FloatV = @splat(state.ping_pong_strength);
            var sum: FloatV = @splat(0);
            var xv = x;
            var yv = y;
            var amp: FloatV = @splat(bounding);
            for (0..state.octaves) |i| {
                const noise_v = octaveNoise2D(N, noise, fractal, state, seed +% @as(i32, @intCast(i)), xv, yv, strength);
                sum += switch (fractal) {
                    .fbm => noise_v * amp,
                    .ridged => (noise_v * splat(FloatV, -2.0) + splat(FloatV, 1.0)) * amp,
                    .ping_pong => (noise_v - splat(FloatV, 0.5)) * splat(FloatV, 2.0) * amp,
                    else => unreachable,
                };
                amp *= switch (fractal) {
                    .fbm => lerp(splat(FloatV, 1.0), @min(noise_v + splat(FloatV, 1.0), splat(FloatV, 2.0)) * splat(FloatV, 0.5), weighted),
                    .ridged => lerp(splat(FloatV, 1.0), splat(FloatV, 1.0) - noise_v, weighted),
                    .ping_pong => lerp(splat(FloatV, 1.0), noise_v, weighted),
                    else => unreachable,
                };
                xv *= lac;
                yv *= lac;
                amp *= gain;
            }
            return sum;
        }

        fn fractalWeighted3D(comptime N: usize, comptime noise: NoiseType, comptime fractal: FractalType, state: *const State, seed: i32, bounding: Float, x: @Vector(N, Float), y: @Vector(N, Float), z: @Vector(N, Float)) @Vector(N, Float) {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            const gain: FloatV = @splat(state.gain);
            const lac: FloatV = @splat(state.lacunarity);
            const weighted: FloatV = @splat(state.weighted_strength);
            const strength: FloatV = @splat(state.ping_pong_strength);
            var sum: FloatV = @splat(0);
            var xv = x;
            var yv = y;
            var zv = z;
            var amp: FloatV = @splat(bounding);
            for (0..state.octaves) |i| {
                const noise_v = octaveNoise3D(N, noise, fractal, state, seed +% @as(i32, @intCast(i)), xv, yv, zv, strength);
                sum += switch (fractal) {
                    .fbm => noise_v * amp,
                    .ridged => (noise_v * splat(FloatV, -2.0) + splat(FloatV, 1.0)) * amp,
                    .ping_pong => (noise_v - splat(FloatV, 0.5)) * splat(FloatV, 2.0) * amp,
                    else => unreachable,
                };
                amp *= switch (fractal) {
                    .fbm => lerp(splat(FloatV, 1.0), (noise_v + splat(FloatV, 1.0)) * splat(FloatV, 0.5), weighted),
                    .ridged => lerp(splat(FloatV, 1.0), splat(FloatV, 1.0) - noise_v, weighted),
                    .ping_pong => lerp(splat(FloatV, 1.0), noise_v, weighted),
                    else => unreachable,
                };
                xv *= lac;
                yv *= lac;
                zv *= lac;
                amp *= gain;
            }
            return sum;
        }

        fn genFractalFBm2D(comptime N: usize, comptime noise: NoiseType, state: *const State, seed: i32, bounding: Float, x: @Vector(N, Float), y: @Vector(N, Float)) @Vector(N, Float) {
            @setFloatMode(.optimized);
            if (state.weighted_strength == 0) {
                return fractalEvenOdd2D(N, noise, .fbm, state, seed, bounding, x, y);
            }
            return fractalWeighted2D(N, noise, .fbm, state, seed, bounding, x, y);
        }

        fn genFractalFBm3D(comptime N: usize, comptime noise: NoiseType, state: *const State, seed: i32, bounding: Float, x: @Vector(N, Float), y: @Vector(N, Float), z: @Vector(N, Float)) @Vector(N, Float) {
            @setFloatMode(.optimized);
            if (state.weighted_strength == 0) {
                return fractalEvenOdd3D(N, noise, .fbm, state, seed, bounding, x, y, z);
            }
            return fractalWeighted3D(N, noise, .fbm, state, seed, bounding, x, y, z);
        }

        fn genFractalRidged2D(comptime N: usize, comptime noise: NoiseType, state: *const State, seed: i32, bounding: Float, x: @Vector(N, Float), y: @Vector(N, Float)) @Vector(N, Float) {
            @setFloatMode(.optimized);
            if (state.weighted_strength == 0) {
                // (1 - 2*n_i)*amp_i is factored across octaves:
                // sum(amp_i) - 2*sum(n_i*amp_i) = 1.0 - 2*(sum0 + sum1).
                return fractalEvenOdd2D(N, noise, .ridged, state, seed, bounding, x, y);
            }
            return fractalWeighted2D(N, noise, .ridged, state, seed, bounding, x, y);
        }

        fn genFractalRidged3D(comptime N: usize, comptime noise: NoiseType, state: *const State, seed: i32, bounding: Float, x: @Vector(N, Float), y: @Vector(N, Float), z: @Vector(N, Float)) @Vector(N, Float) {
            @setFloatMode(.optimized);
            if (state.weighted_strength == 0) {
                return fractalEvenOdd3D(N, noise, .ridged, state, seed, bounding, x, y, z);
            }
            return fractalWeighted3D(N, noise, .ridged, state, seed, bounding, x, y, z);
        }

        fn genFractalPingPong2D(comptime N: usize, comptime noise: NoiseType, state: *const State, seed: i32, bounding: Float, x: @Vector(N, Float), y: @Vector(N, Float)) @Vector(N, Float) {
            @setFloatMode(.optimized);
            if (state.weighted_strength == 0) {
                // (n - 0.5) * 2 * amp = 2*n*amp - amp. Factoring across
                // octaves gives 2*(sum0 + sum1) - sum(amp_i) = 2*(sum0 + sum1) - 1.0.
                return fractalEvenOdd2D(N, noise, .ping_pong, state, seed, bounding, x, y);
            }
            return fractalWeighted2D(N, noise, .ping_pong, state, seed, bounding, x, y);
        }

        fn genFractalPingPong3D(comptime N: usize, comptime noise: NoiseType, state: *const State, seed: i32, bounding: Float, x: @Vector(N, Float), y: @Vector(N, Float), z: @Vector(N, Float)) @Vector(N, Float) {
            @setFloatMode(.optimized);
            if (state.weighted_strength == 0) {
                // Even/odd chains halve the serial sum latency and overlap the
                // two noise evaluations (see Ridged2D). sum(amp_i) = 1.0, so
                // 2*(sum0 + sum1) - 1.0 matches the single-chain result up to
                // reassociation order.
                return fractalEvenOdd3D(N, noise, .ping_pong, state, seed, bounding, x, y, z);
            }
            return fractalWeighted3D(N, noise, .ping_pong, state, seed, bounding, x, y, z);
        }

        // Domain Warp Coordinate Transforms

        inline fn transformDomainWarpCoordinate2DVec(state: *const State, comptime N: usize, x: *@Vector(N, Float), y: *@Vector(N, Float)) void {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            switch (state.domain_warp_type) {
                .simplex, .simplex_reduced => {
                    const t = (x.* + y.*) * splat(FloatV, f2);
                    x.* += t;
                    y.* += t;
                },
                else => {},
            }
        }
        fn transformDomainWarpCoordinate3D(state: *const State, x: *Float, y: *Float, z: *Float) void {
            @setFloatMode(.optimized);
            switch (state.rotation_type) {
                .improve_xy_planes => {
                    const xy: Float = x.* + y.*;
                    const s2: Float = xy * -0.211324865405187;
                    z.* *= 0.577350269189626;
                    x.* += s2 - z.*;
                    y.* = y.* + s2 - z.*;
                    z.* += xy * 0.577350269189626;
                },
                .improve_xz_planes => {
                    const xz: Float = x.* + z.*;
                    const s2: Float = xz * -0.211324865405187;
                    y.* *= 0.577350269189626;
                    x.* += s2 - y.*;
                    z.* += s2 - y.*;
                    y.* += xz * 0.577350269189626;
                },
                else => switch (state.domain_warp_type) {
                    .simplex, .simplex_reduced => {
                        const r: Float = (x.* + y.* + z.*) * r3;
                        x.* = r - x.*;
                        y.* = r - y.*;
                        z.* = r - z.*;
                    },
                    else => {},
                },
            }
        }
        // Domain Warp Single Wrapper

        fn domainWarpSingle2DVec(state: *const State, comptime N: usize, x: *@Vector(N, Float), y: *@Vector(N, Float)) void {
            @setFloatMode(.optimized);
            const amp = state.domain_warp_amp;
            var xs: @Vector(N, Float) = x.*;
            var ys: @Vector(N, Float) = y.*;
            state.transformDomainWarpCoordinate2DVec(N, &xs, &ys);
            state.doSingleDomainWarp2DVec(N, state.seed, amp, state.frequency, xs, ys, x, y);
        }
        fn domainWarpSingle3D(state: *const State, x: *Float, y: *Float, z: *Float) void {
            @setFloatMode(.optimized);
            const amp = state.domain_warp_amp;
            var xs: Float = x.*;
            var ys: Float = y.*;
            var zs: Float = z.*;
            state.transformDomainWarpCoordinate3D(&xs, &ys, &zs);
            state.doSingleDomainWarp3D(state.seed, amp, state.frequency, xs, ys, zs, x, y, z);
        }
        // Domain Warp Fractal
        // progressive and independent differ only in whether the simplex
        // rotation/transform runs inside the octave loop or once up front.

        fn domainWarpFractal2DVec(state: *const State, comptime N: usize, x: *@Vector(N, Float), y: *@Vector(N, Float), comptime progressive: bool) void {
            @setFloatMode(.optimized);
            const gain = state.gain;
            const lacunarity = state.lacunarity;
            var amp = state.domain_warp_amp * state.calculateFractalBounding();
            var freq = state.frequency;
            var octave_seed = state.seed;
            var xs: @Vector(N, Float) = x.*;
            var ys: @Vector(N, Float) = y.*;
            if (!progressive) state.transformDomainWarpCoordinate2DVec(N, &xs, &ys);
            for (0..state.octaves) |_| {
                if (progressive) {
                    xs = x.*;
                    ys = y.*;
                    state.transformDomainWarpCoordinate2DVec(N, &xs, &ys);
                }
                state.doSingleDomainWarp2DVec(N, octave_seed, amp, freq, xs, ys, x, y);
                amp *= gain;
                freq *= lacunarity;
                octave_seed +%= 1;
            }
        }
        fn domainWarpFractal3D(state: *const State, x: *Float, y: *Float, z: *Float, comptime progressive: bool) void {
            @setFloatMode(.optimized);
            const gain = state.gain;
            const lacunarity = state.lacunarity;
            var amp = state.domain_warp_amp * state.calculateFractalBounding();
            var freq = state.frequency;
            var octave_seed = state.seed;
            var xs: Float = x.*;
            var ys: Float = y.*;
            var zs: Float = z.*;
            if (!progressive) state.transformDomainWarpCoordinate3D(&xs, &ys, &zs);
            for (0..state.octaves) |_| {
                if (progressive) {
                    xs = x.*;
                    ys = y.*;
                    zs = z.*;
                    state.transformDomainWarpCoordinate3D(&xs, &ys, &zs);
                }
                state.doSingleDomainWarp3D(octave_seed, amp, freq, xs, ys, zs, x, y, z);
                amp *= gain;
                freq *= lacunarity;
                octave_seed +%= 1;
            }
        }
        // Domain Warp Basic Grid

        fn singleDomainWarpBasicGrid2DVec(comptime N: usize, seed: i32, warp_amp: Float, frequency: Float, x: @Vector(N, Float), y: @Vector(N, Float), xp: *@Vector(N, Float), yp: *@Vector(N, Float)) void {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            const IntV = @Vector(N, i32);
            const xf = x * splat(FloatV, frequency);
            const yf = y * splat(FloatV, frequency);

            const x0_f: FloatV = @floor(xf);
            const x0: IntV = @intFromFloat(x0_f);
            const y0_f: FloatV = @floor(yf);
            const y0: IntV = @intFromFloat(y0_f);
            const xs = interpHermiteVec(N, xf - x0_f);
            const ys = interpHermiteVec(N, yf - y0_f);

            const x0p = x0 *% splat(IntV, prime_x);
            const y0p = y0 *% splat(IntV, prime_y);
            const x1p = x0p +% splat(IntV, prime_x);
            const y1p = y0p +% splat(IntV, prime_y);

            // All four corners share the (seed ^ xp) and ((seed+1293373) ^ xp)
            // prefixes; XOR is associative/commutative, so hoisting them and
            // feeding randomUnit2DFromHashes directly is bit-exact and saves
            // four (seed ^ xp) XORs plus two splats per warp.
            const seed_v: IntV = @splat(seed);
            const seed2_v: IntV = @splat(seed +% 1293373);
            const mult_v: IntV = splat(IntV, hash_multiplier);
            const x0_seed = seed_v ^ x0p;
            const x1_seed = seed_v ^ x1p;
            const x0_seed2 = seed2_v ^ x0p;
            const x1_seed2 = seed2_v ^ x1p;

            const o00 = randomUnit2DFromHashes(N, (x0_seed ^ y0p) *% mult_v, (x0_seed2 ^ y0p) *% mult_v);
            const o10 = randomUnit2DFromHashes(N, (x1_seed ^ y0p) *% mult_v, (x1_seed2 ^ y0p) *% mult_v);
            const lx0x = lerp(o00.xo, o10.xo, xs);
            const ly0x = lerp(o00.yo, o10.yo, xs);

            const o01 = randomUnit2DFromHashes(N, (x0_seed ^ y1p) *% mult_v, (x0_seed2 ^ y1p) *% mult_v);
            const o11 = randomUnit2DFromHashes(N, (x1_seed ^ y1p) *% mult_v, (x1_seed2 ^ y1p) *% mult_v);
            const lx1x = lerp(o01.xo, o11.xo, xs);
            const ly1x = lerp(o01.yo, o11.yo, xs);

            xp.* += lerp(lx0x, lx1x, ys) * splat(FloatV, warp_amp);
            yp.* += lerp(ly0x, ly1x, ys) * splat(FloatV, warp_amp);
        }
        fn singleDomainWarpBasicGrid3D(seed: i32, warp_amp: Float, frequency: Float, x: Float, y: Float, z: Float, xp: *Float, yp: *Float, zp: *Float) void {
            @setFloatMode(.optimized);
            const xf = x * frequency;
            const yf = y * frequency;
            const zf = z * frequency;

            var x0: i32 = @floor(xf);
            var y0: i32 = @floor(yf);
            var z0: i32 = @floor(zf);

            const xs = interpHermite(xf - @as(Float, @floatFromInt(x0)));
            const ys = interpHermite(yf - @as(Float, @floatFromInt(y0)));
            const zs = interpHermite(zf - @as(Float, @floatFromInt(z0)));

            x0 *%= prime_x;
            y0 *%= prime_y;
            z0 *%= prime_z;
            const x1 = x0 +% prime_x;
            const y1 = y0 +% prime_y;
            const z1 = z0 +% prime_z;

            // All 8 corner hashes share the (seed ^ x ^ y) prefix; XOR is
            // associative/commutative, so hoisting the prefixes is bit-exact
            // and turns each hash into one XOR + one multiply.
            const seed_x0 = seed ^ x0;
            const seed_x1 = seed ^ x1;
            const seed_x0_y0 = seed_x0 ^ y0;
            const seed_x1_y0 = seed_x1 ^ y0;
            const seed_x0_y1 = seed_x0 ^ y1;
            const seed_x1_y1 = seed_x1 ^ y1;

            var idx0: usize = @intCast(((seed_x0_y0 ^ z0) *% 0x27D4EB2D) & (255 << 2));
            var idx1: usize = @intCast(((seed_x1_y0 ^ z0) *% 0x27D4EB2D) & (255 << 2));

            var lx0x = @mulAdd(Float, xs, rand_3d[idx1] - rand_3d[idx0], rand_3d[idx0]);
            var ly0x = @mulAdd(Float, xs, rand_3d[idx1 | 1] - rand_3d[idx0 | 1], rand_3d[idx0 | 1]);
            var lz0x = @mulAdd(Float, xs, rand_3d[idx1 | 2] - rand_3d[idx0 | 2], rand_3d[idx0 | 2]);

            idx0 = @intCast(((seed_x0_y1 ^ z0) *% 0x27D4EB2D) & (255 << 2));
            idx1 = @intCast(((seed_x1_y1 ^ z0) *% 0x27D4EB2D) & (255 << 2));

            var lx1x = @mulAdd(Float, xs, rand_3d[idx1] - rand_3d[idx0], rand_3d[idx0]);
            var ly1x = @mulAdd(Float, xs, rand_3d[idx1 | 1] - rand_3d[idx0 | 1], rand_3d[idx0 | 1]);
            var lz1x = @mulAdd(Float, xs, rand_3d[idx1 | 2] - rand_3d[idx0 | 2], rand_3d[idx0 | 2]);

            const lx0y = @mulAdd(Float, ys, lx1x - lx0x, lx0x);
            const ly0y = @mulAdd(Float, ys, ly1x - ly0x, ly0x);
            const lz0y = @mulAdd(Float, ys, lz1x - lz0x, lz0x);

            idx0 = @intCast(((seed_x0_y0 ^ z1) *% 0x27D4EB2D) & (255 << 2));
            idx1 = @intCast(((seed_x1_y0 ^ z1) *% 0x27D4EB2D) & (255 << 2));

            lx0x = @mulAdd(Float, xs, rand_3d[idx1] - rand_3d[idx0], rand_3d[idx0]);
            ly0x = @mulAdd(Float, xs, rand_3d[idx1 | 1] - rand_3d[idx0 | 1], rand_3d[idx0 | 1]);
            lz0x = @mulAdd(Float, xs, rand_3d[idx1 | 2] - rand_3d[idx0 | 2], rand_3d[idx0 | 2]);

            idx0 = @intCast(((seed_x0_y1 ^ z1) *% 0x27D4EB2D) & (255 << 2));
            idx1 = @intCast(((seed_x1_y1 ^ z1) *% 0x27D4EB2D) & (255 << 2));

            lx1x = @mulAdd(Float, xs, rand_3d[idx1] - rand_3d[idx0], rand_3d[idx0]);
            ly1x = @mulAdd(Float, xs, rand_3d[idx1 | 1] - rand_3d[idx0 | 1], rand_3d[idx0 | 1]);
            lz1x = @mulAdd(Float, xs, rand_3d[idx1 | 2] - rand_3d[idx0 | 2], rand_3d[idx0 | 2]);

            const lx0z = @mulAdd(Float, ys, lx1x - lx0x, lx0x);
            const ly0z = @mulAdd(Float, ys, ly1x - ly0x, ly0x);
            const lz0z = @mulAdd(Float, ys, lz1x - lz0x, lz0x);

            xp.* = @mulAdd(Float, warp_amp, @mulAdd(Float, zs, lx0z - lx0y, lx0y), xp.*);
            yp.* = @mulAdd(Float, warp_amp, @mulAdd(Float, zs, ly0z - ly0y, ly0y), yp.*);
            zp.* = @mulAdd(Float, warp_amp, @mulAdd(Float, zs, lz0z - lz0y, lz0y), zp.*);
        }
        // Domain Warp Simplex/OpenSimplex2

        fn singleDomainWarpSimplexGradientVec(comptime N: usize, seed: i32, warp_amp: Float, frequency: Float, x: @Vector(N, Float), y: @Vector(N, Float), xr: *@Vector(N, Float), yr: *@Vector(N, Float)) void {
            @setFloatMode(.optimized);
            const FloatV = @Vector(N, Float);
            const IntV = @Vector(N, i32);
            const zero: FloatV = splat(FloatV, 0);
            const xx = x * splat(FloatV, frequency);
            const yy = y * splat(FloatV, frequency);

            const i_f: FloatV = @floor(xx);
            const i: IntV = @intFromFloat(i_f);
            const j_f: FloatV = @floor(yy);
            const j: IntV = @intFromFloat(j_f);
            const xi = xx - i_f;
            const yi = yy - j_f;

            const t = (xi + yi) * splat(FloatV, g2);
            const x0 = xi - t;
            const y0 = yi - t;

            const ip = i *% splat(IntV, prime_x);
            const jp = j *% splat(IntV, prime_y);

            var vx: FloatV = zero;
            var vy: FloatV = zero;

            const a = @mulAdd(FloatV, -y0, y0, @mulAdd(FloatV, -x0, x0, splat(FloatV, 0.5)));
            const a_ok = a > splat(FloatV, 0);
            const aaaa = (a * a) * (a * a);
            const ga = gradCoordDual2DVec(N, seed, ip, jp, x0, y0);
            vx += @select(Float, a_ok, aaaa * ga.xo, zero);
            vy += @select(Float, a_ok, aaaa * ga.yo, zero);

            const c = @mulAdd(FloatV, t, splat(FloatV, 2.0 * (1.0 - 2.0 * g2) * (1.0 / g2 - 2.0)), splat(FloatV, -2.0 * (1.0 - 2.0 * g2) * (1.0 - 2.0 * g2)) + a);
            const c_ok = c > splat(FloatV, 0);
            const x2 = x0 + splat(FloatV, 2 * g2 - 1.0);
            const y2 = y0 + splat(FloatV, 2 * g2 - 1.0);
            const cccc = (c * c) * (c * c);
            const gc = gradCoordDual2DVec(N, seed, ip +% splat(IntV, prime_x), jp +% splat(IntV, prime_y), x2, y2);
            vx += @select(Float, c_ok, cccc * gc.xo, zero);
            vy += @select(Float, c_ok, cccc * gc.yo, zero);

            const y_gt_x = y0 > x0;
            const x1 = @select(Float, y_gt_x, x0 + splat(FloatV, g2), x0 + splat(FloatV, g2 - 1.0));
            const y1 = @select(Float, y_gt_x, y0 + splat(FloatV, g2 - 1.0), y0 + splat(FloatV, g2));
            const b = @mulAdd(FloatV, -y1, y1, @mulAdd(FloatV, -x1, x1, splat(FloatV, 0.5)));
            const b_ok = b > splat(FloatV, 0);
            const bbbb = (b * b) * (b * b);
            const ib = @select(i32, y_gt_x, ip, ip +% splat(IntV, prime_x));
            const jb = @select(i32, y_gt_x, jp +% splat(IntV, prime_y), jp);
            const gb = gradCoordDual2DVec(N, seed, ib, jb, x1, y1);
            vx += @select(Float, b_ok, bbbb * gb.xo, zero);
            vy += @select(Float, b_ok, bbbb * gb.yo, zero);

            xr.* += vx * splat(FloatV, warp_amp);
            yr.* += vy * splat(FloatV, warp_amp);
        }
        // Inline so the two callers (which pass literal true/false for
        // out_grad) each get a specialized copy: the per-corner out_grad
        // branch folds away instead of being tested four times per warp.
        inline fn singleDomainWarpOpenSimplex2Gradient(seed: i32, warp_amp: Float, frequency: Float, x: Float, y: Float, z: Float, xr: *Float, yr: *Float, zr: *Float, out_grad: bool) void {
            @setFloatMode(.optimized);
            const xx = x * frequency;
            const yy = y * frequency;
            const zz = z * frequency;

            var i = fastRound(xx);
            var j = fastRound(yy);
            var k = fastRound(zz);
            var x0 = xx - @as(Float, @floatFromInt(i));
            var y0 = yy - @as(Float, @floatFromInt(j));
            var z0 = zz - @as(Float, @floatFromInt(k));

            var xNSign = @as(i32, @trunc(-x0 - 1.0)) | 1;
            var yNSign = @as(i32, @trunc(-y0 - 1.0)) | 1;
            var zNSign = @as(i32, @trunc(-z0 - 1.0)) | 1;

            // The ±1 sign is tracked as a float too; negating ±1.0 is exact,
            // so one int->float conversion per axis serves both the corner-2
            // offsets and the loop-bottom x0/y0/z0 updates (the bottom would
            // otherwise re-convert the same, not-yet-negated sign).
            var xNSignf: Float = @floatFromInt(xNSign);
            var yNSignf: Float = @floatFromInt(yNSign);
            var zNSignf: Float = @floatFromInt(zNSign);

            var ax0 = xNSignf * -x0;
            var ay0 = yNSignf * -y0;
            var az0 = zNSignf * -z0;

            i *%= prime_x;
            j *%= prime_y;
            k *%= prime_z;

            var vx: Float = 0;
            var vy: Float = 0;
            var vz: Float = 0;
            var xo: Float = undefined;
            var yo: Float = undefined;
            var zo: Float = undefined;

            var seed_value = seed;
            var a = (0.6 - x0 * x0) - (y0 * y0 + z0 * z0);
            var l: usize = 0;
            while (l < 2) : (l += 1) {
                if (a > 0) {
                    const aaaa = (a * a) * (a * a);
                    if (out_grad) {
                        gradCoordOut3D(seed_value, i, j, k, &xo, &yo, &zo);
                    } else {
                        gradCoordDual3D(seed_value, i, j, k, x0, y0, z0, &xo, &yo, &zo);
                    }
                    vx += aaaa * xo;
                    vy += aaaa * yo;
                    vz += aaaa * zo;
                }

                var b = a + 1.0;
                var ii = i;
                var jj = j;
                var kk = k;
                var x1 = x0;
                var y1 = y0;
                var z1 = z0;
                if (ax0 >= ay0 and ax0 >= az0) {
                    x1 += xNSignf;
                    b = @mulAdd(Float, -(2.0 * xNSignf), x1, b);
                    ii -= xNSign *% prime_x;
                } else if (ay0 > ax0 and ay0 >= az0) {
                    y1 += yNSignf;
                    b = @mulAdd(Float, -(2.0 * yNSignf), y1, b);
                    jj -= yNSign *% prime_y;
                } else {
                    z1 += zNSignf;
                    b = @mulAdd(Float, -(2.0 * zNSignf), z1, b);
                    kk -= zNSign *% prime_z;
                }

                if (b > 0) {
                    const bbbb = (b * b) * (b * b);
                    if (out_grad) {
                        gradCoordOut3D(seed_value, ii, jj, kk, &xo, &yo, &zo);
                    } else {
                        gradCoordDual3D(seed_value, ii, jj, kk, x1, y1, z1, &xo, &yo, &zo);
                    }
                    vx += bbbb * xo;
                    vy += bbbb * yo;
                    vz += bbbb * zo;
                }

                ax0 = 0.5 - ax0;
                ay0 = 0.5 - ay0;
                az0 = 0.5 - az0;

                x0 = xNSignf * ax0;
                y0 = yNSignf * ay0;
                z0 = zNSignf * az0;

                a += (0.75 - ax0) - (ay0 + az0);

                i += (xNSign >> 1) & prime_x;
                j += (yNSign >> 1) & prime_y;
                k += (zNSign >> 1) & prime_z;

                xNSign = -xNSign;
                yNSign = -yNSign;
                zNSign = -zNSign;
                xNSignf = -xNSignf;
                yNSignf = -yNSignf;
                zNSignf = -zNSignf;

                seed_value +%= 1293373;
            }

            xr.* += vx * warp_amp;
            yr.* += vy * warp_amp;
            zr.* += vz * warp_amp;
        }
        // Domain Warp Batching

        inline fn warpVector2D(state: *const State, comptime N: usize, x: *@Vector(N, Float), y: *@Vector(N, Float)) void {
            switch (state.fractal_type) {
                .progressive => state.domainWarpFractal2DVec(N, x, y, true),
                .independent => state.domainWarpFractal2DVec(N, x, y, false),
                else => state.domainWarpSingle2DVec(N, x, y),
            }
        }

        fn warpGrid2DImpl(comptime N: usize, state: *const State, out_xs: []Float, out_ys: []Float, xs: []const Float, ys: []const Float) void {
            @setFloatMode(.optimized);
            @setEvalBranchQuota(200_000);
            const FloatV = @Vector(N, Float);

            var start: usize = 0;
            // Full/tail split; see fillGrid2DImpl.
            const full_len = out_xs.len - (out_xs.len % N);
            while (start < full_len) : (start += N) {
                var x: FloatV = undefined;
                var y: FloatV = undefined;
                // One 32-byte load per coordinate instead of N scalar loads
                // plus inserts; unaligned-safe on AVX2.
                x = @as(FloatV, @bitCast(xs[start..][0..N].*));
                y = @as(FloatV, @bitCast(ys[start..][0..N].*));
                state.warpVector2D(N, &x, &y);
                out_xs[start..][0..N].* = @as([N]Float, @bitCast(x));
                out_ys[start..][0..N].* = @as([N]Float, @bitCast(y));
            }
            if (start < out_xs.len) {
                var x: FloatV = undefined;
                var y: FloatV = undefined;
                const remaining = out_xs.len - start;
                inline for (0..N) |i| {
                    x[i] = xs[start + @min(i, remaining - 1)];
                    y[i] = ys[start + @min(i, remaining - 1)];
                }
                state.warpVector2D(N, &x, &y);
                storeChunk(N, start, out_xs, x);
                storeChunk(N, start, out_ys, y);
            }
        }
    };
}
test "reference all" {
    std.testing.refAllDecls(Noise(f32));
}

test "range of all 2D noise/fractal combinations" {
    @setEvalBranchQuota(500_000);
    const size = 128;
    var noise = Noise(f32){};

    inline for (@typeInfo(FractalType).@"enum".fields) |fractal| {
        noise.fractal_type = comptime std.meta.stringToEnum(FractalType, fractal.name).?;

        @setEvalBranchQuota(size * size * 2);
        inline for (@typeInfo(NoiseType).@"enum".fields) |noise_type| {
            noise.noise_type = comptime std.meta.stringToEnum(NoiseType, noise_type.name).?;
            for (0..size * size) |i| {
                const value = noise.genNoise2D(@floatFromInt(i % size), @floatFromInt(i / size));
                try std.testing.expect(value >= -1.0001 and value <= 1.0001);
            }
        }
    }
}

test "range of all 3D noise/fractal combinations" {
    @setEvalBranchQuota(500_000);
    const size = 32;
    var noise = Noise(f32){};

    inline for (@typeInfo(FractalType).@"enum".fields) |fractal| {
        noise.fractal_type = comptime std.meta.stringToEnum(FractalType, fractal.name).?;

        @setEvalBranchQuota(size * size * size * 2);
        inline for (@typeInfo(NoiseType).@"enum".fields) |noise_type| {
            noise.noise_type = comptime std.meta.stringToEnum(NoiseType, noise_type.name).?;
            for (0..size) |z| for (0..size) |y| for (0..size) |x| {
                const value = noise.genNoise3D(@floatFromInt(x), @floatFromInt(y), @floatFromInt(z));
                try std.testing.expect(value >= -1.0001 and value <= 1.0001);
            };
        }
    }
}

test "range of all 2D cellular return/distance combinations (f64)" {
    @setEvalBranchQuota(200_000);
    const size = 128;
    var noise = Noise(f64){
        .noise_type = .cellular,
    };

    inline for (@typeInfo(CellularDistanceFunc).@"enum".fields) |dist| {
        noise.cellular_distance = comptime std.meta.stringToEnum(CellularDistanceFunc, dist.name).?;
        inline for (@typeInfo(CellularReturnType).@"enum".fields) |ret| {
            noise.cellular_return = std.meta.stringToEnum(CellularReturnType, ret.name).?;
            for (0..size * size) |i| {
                const value = noise.genNoise2D(@floatFromInt(i % size), @floatFromInt(i / size));
                try std.testing.expect(value >= -1.0001 and value <= 1.0001);
            }
        }
    }
}

test "range of all 3D cellular return/distance combinations" {
    @setEvalBranchQuota(200_000);
    const size = 32;
    var noise = Noise(f32){
        .noise_type = .cellular,
    };

    inline for (@typeInfo(CellularDistanceFunc).@"enum".fields) |dist| {
        noise.cellular_distance = comptime std.meta.stringToEnum(CellularDistanceFunc, dist.name).?;
        inline for (@typeInfo(CellularReturnType).@"enum".fields) |ret| {
            noise.cellular_return = std.meta.stringToEnum(CellularReturnType, ret.name).?;
            for (0..size) |z| for (0..size) |y| for (0..size) |x| {
                const value = noise.genNoise3D(@floatFromInt(x), @floatFromInt(y), @floatFromInt(z));
                try std.testing.expect(value >= -1.0 and value <= 1.0);
            };
        }
    }
}

test "domain warp keeps coordinates finite for all warp/fractal types" {
    @setEvalBranchQuota(100_000);
    var noise = Noise(f32){
        .seed = -1234567890,
    };
    inline for (@typeInfo(DomainWarpType).@"enum".fields) |warp_type| {
        noise.domain_warp_type = comptime std.meta.stringToEnum(DomainWarpType, warp_type.name).?;
        inline for (@typeInfo(FractalType).@"enum".fields) |fractal| {
            noise.fractal_type = comptime std.meta.stringToEnum(FractalType, fractal.name).?;
            for (0..64) |i| {
                var x: f32 = @floatFromInt(i % 8);
                var y: f32 = @floatFromInt(i / 8);
                var z: f32 = @floatFromInt(i % 4);
                noise.domainWarp2D(&x, &y);
                noise.domainWarp3D(&x, &y, &z);
                try std.testing.expect(std.math.isFinite(x) and std.math.isFinite(y) and std.math.isFinite(z));
            }
        }
    }
}

test "fillGrid2D matches scalar genNoise2D" {
    @setEvalBranchQuota(500_000);
    const size = 30;
    var noise = Noise(f32){};
    inline for (@typeInfo(FractalType).@"enum".fields) |fractal| {
        noise.fractal_type = comptime std.meta.stringToEnum(FractalType, fractal.name).?;
        inline for (@typeInfo(NoiseType).@"enum".fields) |noise_type| {
            noise.noise_type = comptime std.meta.stringToEnum(NoiseType, noise_type.name).?;
            var grid: [size * size]f32 = undefined;
            noise.fillGrid2D(&grid, size, 3.0, -7.0, 0.25);
            for (0..size) |y| for (0..size) |x| {
                const expected = noise.genNoise2D(3.0 + @as(f32, @floatFromInt(x)) * 0.25, -7.0 + @as(f32, @floatFromInt(y)) * 0.25);
                try std.testing.expectApproxEqAbs(expected, grid[y * size + x], 1e-5);
            };
        }
    }
}

test "fillGrid3D matches scalar genNoise3D" {
    @setEvalBranchQuota(500_000);
    const width = 6;
    const height = 5;
    const depth = 3;
    var noise = Noise(f32){};
    inline for (@typeInfo(FractalType).@"enum".fields) |fractal| {
        noise.fractal_type = comptime std.meta.stringToEnum(FractalType, fractal.name).?;
        inline for (@typeInfo(NoiseType).@"enum".fields) |noise_type| {
            noise.noise_type = comptime std.meta.stringToEnum(NoiseType, noise_type.name).?;
            inline for (@typeInfo(RotationType).@"enum".fields) |rotation| {
                noise.rotation_type = comptime std.meta.stringToEnum(RotationType, rotation.name).?;
                var grid: [width * height * depth]f32 = undefined;
                noise.fillGrid3D(&grid, width, depth, 1.5, -2.0, 4.0, 0.5);
                for (0..depth) |z| for (0..height) |y| for (0..width) |x| {
                    const expected = noise.genNoise3D(
                        1.5 + @as(f32, @floatFromInt(x)) * 0.5,
                        -2.0 + @as(f32, @floatFromInt(y)) * 0.5,
                        4.0 + @as(f32, @floatFromInt(z)) * 0.5,
                    );
                    try std.testing.expectApproxEqAbs(expected, grid[(z * height + y) * width + x], 1e-5);
                };
            }
        }
    }
}

test "range mapping handles full int ranges without overflow" {
    var noise = Noise(f32){};
    for (0..100) |i| {
        const x: f32 = @floatFromInt(i);
        const i8_value = noise.genNoise2DRange(x, 0, i8, -128, 127);
        try std.testing.expect(i8_value >= -128 and i8_value <= 127);
        const u16_value = noise.genNoise3DRange(x, 0, 1, u16, 0, 65535);
        try std.testing.expect(u16_value <= 65535);
    }
}

test "benchmark fillGrid2D on a 32x32 grid" {
    const size = 32;
    const x0 = -16.0;
    const y0 = -16.0;
    const spacing = 1.0 / @as(f32, size);
    var noise = Noise(f32){ .noise_type = .perlin, .fractal_type = .ridged, .octaves = 12 };
    noise.seed = 1337;

    var grid: [size * size]f32 = undefined;
    noise.fillGrid2D(&grid, size, x0, y0, spacing);
    for (0..size) |y| for (0..size) |x| {
        const expected = noise.genNoise2D(x0 + @as(f32, @floatFromInt(x)) * spacing, y0 + @as(f32, @floatFromInt(y)) * spacing);
        try std.testing.expectApproxEqAbs(expected, grid[y * size + x], 1e-5);
    };

    const io = std.testing.io;
    const iterations = 100;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| noise.fillGrid2D(&grid, size, x0, y0, spacing);
    const fill_done = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| for (0..size * size) |i| {
        grid[i] = noise.genNoise2D(x0 + @as(f32, @floatFromInt(i % size)) * spacing, y0 + @as(f32, @floatFromInt(i / size)) * spacing);
    };
    const end = std.Io.Clock.Timestamp.now(io, .awake);

    const samples: f64 = @floatFromInt(iterations * size * size);
    const scalar_ns = @as(f64, @floatFromInt(fill_done.durationTo(end).raw.toNanoseconds())) / samples;
    const fill_ns = @as(f64, @floatFromInt(start.durationTo(fill_done).raw.toNanoseconds())) / samples;
    std.debug.print("32x32 grid: scalar {d:.1} ns/sample, fillGrid2D {d:.1} ns/sample, {d:.2}x faster\n", .{ scalar_ns, fill_ns, scalar_ns / fill_ns });

    // The terrain height path samples at warped (irregular) coordinates, so
    // benchmark the explicit-coordinate variant against per-point sampling.
    var xs: [size * size]f32 = undefined;
    var ys: [size * size]f32 = undefined;
    for (0..size * size) |i| {
        xs[i] = @as(f32, @floatFromInt(i % size)) * 0.53 - @as(f32, @floatFromInt(i / size)) * 0.11;
        ys[i] = @as(f32, @floatFromInt(i % 5)) * 0.37 + @as(f32, @floatFromInt(i / 7)) * 0.29;
    }
    var points_out: [size * size]f32 = undefined;
    noise.fillNoise2DGrid(&points_out, &xs, &ys);
    const points_start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| noise.fillNoise2DGrid(&points_out, &xs, &ys);
    const points_done = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| for (0..size * size) |i| {
        points_out[i] = noise.genNoise2D(xs[i], ys[i]);
    };
    const points_end = std.Io.Clock.Timestamp.now(io, .awake);

    const points_scalar_ns = @as(f64, @floatFromInt(points_done.durationTo(points_end).raw.toNanoseconds())) / samples;
    const points_fill_ns = @as(f64, @floatFromInt(points_start.durationTo(points_done).raw.toNanoseconds())) / samples;
    std.debug.print("32x32 points: scalar {d:.1} ns/sample, fillNoise2DGrid {d:.1} ns/sample, {d:.2}x faster\n", .{ points_scalar_ns, points_fill_ns, points_scalar_ns / points_fill_ns });
}

test "fillNoise2DGrid matches scalar genNoise2D at explicit coordinates" {
    @setEvalBranchQuota(500_000);
    const count = 35;
    var xs: [count]f32 = undefined;
    var ys: [count]f32 = undefined;
    for (0..count) |i| {
        xs[i] = @as(f32, @floatFromInt(i)) * 0.37 + @as(f32, @floatFromInt(i % 3)) * 0.11;
        ys[i] = @as(f32, @floatFromInt(i % 5)) * 0.53 - @as(f32, @floatFromInt(i / 5)) * 0.07;
    }
    var noise = Noise(f32){};
    inline for (@typeInfo(FractalType).@"enum".fields) |fractal| {
        noise.fractal_type = comptime std.meta.stringToEnum(FractalType, fractal.name).?;
        inline for (@typeInfo(NoiseType).@"enum".fields) |noise_type| {
            noise.noise_type = comptime std.meta.stringToEnum(NoiseType, noise_type.name).?;
            var out: [count]f32 = undefined;
            noise.fillNoise2DGrid(&out, &xs, &ys);
            for (0..count) |i| {
                const expected = noise.genNoise2D(xs[i], ys[i]);
                try std.testing.expectApproxEqAbs(expected, out[i], 1e-5);
            }
        }
    }
}

test "fillNoise3DGrid matches scalar genNoise3D at explicit coordinates" {
    @setEvalBranchQuota(500_000);
    const count = 29;
    var xs: [count]f32 = undefined;
    var ys: [count]f32 = undefined;
    var zs: [count]f32 = undefined;
    for (0..count) |i| {
        xs[i] = @as(f32, @floatFromInt(i)) * 0.31;
        ys[i] = @as(f32, @floatFromInt(i % 4)) * 0.47 - 1.0;
        zs[i] = @as(f32, @floatFromInt(i / 3)) * 0.19;
    }
    var noise = Noise(f32){};
    inline for (@typeInfo(FractalType).@"enum".fields) |fractal| {
        noise.fractal_type = comptime std.meta.stringToEnum(FractalType, fractal.name).?;
        inline for (@typeInfo(NoiseType).@"enum".fields) |noise_type| {
            noise.noise_type = comptime std.meta.stringToEnum(NoiseType, noise_type.name).?;
            inline for (@typeInfo(RotationType).@"enum".fields) |rotation| {
                noise.rotation_type = comptime std.meta.stringToEnum(RotationType, rotation.name).?;
                var out: [count]f32 = undefined;
                noise.fillNoise3DGrid(&out, &xs, &ys, &zs);
                for (0..count) |i| {
                    const expected = noise.genNoise3D(xs[i], ys[i], zs[i]);
                    try std.testing.expectApproxEqAbs(expected, out[i], 1e-5);
                }
            }
        }
    }
}

test "simplex noise is continuous across cell boundaries" {
    const noise_types = [_]NoiseType{ .simplex, .simplex_smooth };
    for (noise_types) |noise_type| {
        var noise2 = Noise(f32){ .noise_type = noise_type, .frequency = 1.0, .seed = 1337 };
        var noise3 = Noise(f32){ .noise_type = noise_type, .frequency = 1.0, .seed = 1337 };
        // Walk along diagonals crossing many lattice cell boundaries in steps
        // small enough that a mask error would show up as a visible jump.
        var prev2 = noise2.genNoise2D(0.0, 0.0);
        var prev3 = noise3.genNoise3D(0.0, 0.0, 0.0);
        for (0..800) |i| {
            const t: f32 = @as(f32, @floatFromInt(i)) / 128.0;
            const v2 = noise2.genNoise2D(t * 0.7, t * 0.3);
            const v3 = noise3.genNoise3D(t * 0.7, t * 0.3, t * 0.5);
            try std.testing.expect(@abs(v2 - prev2) < 0.2);
            try std.testing.expect(@abs(v3 - prev3) < 0.2);
            prev2 = v2;
            prev3 = v3;
        }
    }
}

test "fillWarp2DGrid matches scalar domainWarp2D" {
    @setEvalBranchQuota(500_000);
    const count = 40;
    var xs: [count]f32 = undefined;
    var ys: [count]f32 = undefined;
    for (0..count) |i| {
        xs[i] = @as(f32, @floatFromInt(i)) * 0.37 + @as(f32, @floatFromInt(i % 3)) * 0.11;
        ys[i] = @as(f32, @floatFromInt(i % 5)) * 0.53 - @as(f32, @floatFromInt(i / 5)) * 0.07;
    }
    var noise = Noise(f32){};
    inline for (@typeInfo(DomainWarpType).@"enum".fields) |warp| {
        noise.domain_warp_type = comptime std.meta.stringToEnum(DomainWarpType, warp.name).?;
        inline for (@typeInfo(FractalType).@"enum".fields) |fractal| {
            noise.fractal_type = comptime std.meta.stringToEnum(FractalType, fractal.name).?;
            var out_xs: [count]f32 = undefined;
            var out_ys: [count]f32 = undefined;
            noise.fillWarp2DGrid(&out_xs, &out_ys, &xs, &ys);
            for (0..count) |i| {
                var gx = xs[i];
                var gy = ys[i];
                noise.domainWarp2D(&gx, &gy);
                try std.testing.expectApproxEqAbs(gx, out_xs[i], 1e-5);
                try std.testing.expectApproxEqAbs(gy, out_ys[i], 1e-5);
            }
        }
    }
}

test "fillWarp2DGrid keeps coordinates finite for all warp/fractal types" {
    @setEvalBranchQuota(100_000);
    var noise = Noise(f32){ .seed = -1234567890 };
    var xs: [64]f32 = undefined;
    var ys: [64]f32 = undefined;
    for (0..64) |i| {
        xs[i] = @floatFromInt(i % 8);
        ys[i] = @floatFromInt(i / 8);
    }
    inline for (@typeInfo(DomainWarpType).@"enum".fields) |warp| {
        noise.domain_warp_type = comptime std.meta.stringToEnum(DomainWarpType, warp.name).?;
        inline for (@typeInfo(FractalType).@"enum".fields) |fractal| {
            noise.fractal_type = comptime std.meta.stringToEnum(FractalType, fractal.name).?;
            var out_xs: [64]f32 = undefined;
            var out_ys: [64]f32 = undefined;
            noise.fillWarp2DGrid(&out_xs, &out_ys, &xs, &ys);
            for (0..64) |i| {
                try std.testing.expect(std.math.isFinite(out_xs[i]) and std.math.isFinite(out_ys[i]));
            }
        }
    }
}

test "warp gradient select tree matches the pair table" {
    // The table holds 16 direction pairs repeated eight times; the low four
    // hash bits select the pair, and every higher bit combination must hit it.
    for (0..128) |index1| {
        const hash: i32 = @as(i32, @intCast(index1)) << 1;
        const grad = Noise(f32).gradient2DTableVec(1, @as(@Vector(1, i32), @splat(hash)));
        const pair = index1 & 15;
        try std.testing.expectEqual(warp_gradient_pairs[pair][0], grad.xg[0]);
        try std.testing.expectEqual(warp_gradient_pairs[pair][1], grad.yg[0]);
    }
}

test "benchmark fillWarp2DGrid on a 32x32 grid" {
    const size = 32;
    var noise = Noise(f32){ .domain_warp_type = .simplex, .fractal_type = .fbm, .octaves = 3 };
    noise.seed = 1337;

    var xs: [size * size]f32 = undefined;
    var ys: [size * size]f32 = undefined;
    for (0..size * size) |i| {
        xs[i] = @as(f32, @floatFromInt(i % size)) * 0.53 - @as(f32, @floatFromInt(i / size)) * 0.11;
        ys[i] = @as(f32, @floatFromInt(i % 5)) * 0.37 + @as(f32, @floatFromInt(i / 7)) * 0.29;
    }
    var out_xs: [size * size]f32 = undefined;
    var out_ys: [size * size]f32 = undefined;
    noise.fillWarp2DGrid(&out_xs, &out_ys, &xs, &ys);
    for (0..size * size) |i| {
        var gx = xs[i];
        var gy = ys[i];
        noise.domainWarp2D(&gx, &gy);
        try std.testing.expectEqual(gx, out_xs[i]);
        try std.testing.expectEqual(gy, out_ys[i]);
    }

    const io = std.testing.io;
    const iterations = 100;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| noise.fillWarp2DGrid(&out_xs, &out_ys, &xs, &ys);
    const fill_done = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| for (0..size * size) |i| {
        var gx = xs[i];
        var gy = ys[i];
        noise.domainWarp2D(&gx, &gy);
        out_xs[i] = gx;
        out_ys[i] = gy;
    };
    const end = std.Io.Clock.Timestamp.now(io, .awake);

    const samples: f64 = @floatFromInt(iterations * size * size);
    const scalar_ns = @as(f64, @floatFromInt(fill_done.durationTo(end).raw.toNanoseconds())) / samples;
    const fill_ns = @as(f64, @floatFromInt(start.durationTo(fill_done).raw.toNanoseconds())) / samples;
    std.debug.print("32x32 warp: scalar {d:.1} ns/sample, fillWarp2DGrid {d:.1} ns/sample, {d:.2}x faster\n", .{ scalar_ns, fill_ns, scalar_ns / fill_ns });
}

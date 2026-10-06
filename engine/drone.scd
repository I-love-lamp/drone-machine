// Drone Machine — generative drone engine with layered threads of sound + effects
//
// Start with ./start-engine.sh, or by hand: sclang drone.scd
// Controlled over OSC on port 57120 by the touchscreen UI (ui/ui.py), a phone OSC app,
// or any USB MIDI controller. See README.md for the full list of messages.
//
// Five layers, each with its own thread (a Routine) deciding when to change notes:
//   sub      deep sine/triangle on the root and fifth
//   pad      detuned oscillators morphing between sine and saw
//   glass    high FM shimmer that swells in and out
//   bells    sparse inharmonic strikes, great into the delay
//   texture  wind (filtered noise) and tuned crackle

(
s = Server.default;
s.options.numOutputBusChannels = 2;
s.options.numInputBusChannels = 0;
s.options.memSize = 65536;          // 64 MB of real-time memory for the delay line
s.recHeaderFormat = "wav";
s.recSampleFormat = "int24";

thisProcess.openUDPPort(57120);

s.waitForBoot {

    // ---------------------------------------------------------------- sounds

    SynthDef(\sub, { |out, freq = 55, amp = 0.35, tone = 0.3, attack = 10, release = 14, gate = 1|
        var f, sig, env;
        f = freq.lag(6) * LFNoise2.kr(0.05, 0.05).midiratio;
        sig = SinOsc.ar(f) + LFTri.ar(f * 2, 0, tone.lag(1) * 0.25);
        sig = (sig * tone.lag(1).linlin(0, 1, 1, 4)).tanh * LFNoise2.kr(0.07).range(0.7, 1);
        env = EnvGen.kr(Env.asr(attack, 1, release, \sine), gate, doneAction: 2);
        Out.ar(out, (sig * env * amp) ! 2);
    }).add;

    // Three drifting oscillators morphing from sine (dark tone) to saw (bright tone).
    SynthDef(\pad, { |out, freq = 110, amp = 0.18, tone = 0.4, detune = 0.2,
                     attack = 8, release = 10, gate = 1|
        var drift, freqs, saws, sines, sig, cutoff, env;
        drift = LFNoise2.kr({ Rand(0.03, 0.15) } ! 3, detune.lag(1));   // in semitones
        freqs = (freq.lag(5).cpsmidi + drift).midicps;                   // lag = notes glide
        saws = VarSaw.ar(freqs, { Rand(0, 1) } ! 3, LFNoise2.kr(0.1 ! 3).range(0.1, 0.9));
        sines = SinOsc.ar(freqs, { Rand(0, 2pi) } ! 3);
        sig = XFade2.ar(sines, saws, tone.lag(1) * 1.6 - 1).sum * 0.33;
        cutoff = tone.lag(1).linexp(0, 1, 150, 9000) * LFNoise2.kr(Rand(0.02, 0.06)).exprange(0.5, 2);
        sig = RLPF.ar(sig, cutoff.clip(40, 18000), 0.5);
        env = EnvGen.kr(Env.asr(attack, 1, release, \sine), gate, doneAction: 2);
        sig = Pan2.ar(sig, LFNoise2.kr(Rand(0.02, 0.05)) * 0.6);
        Out.ar(out, sig * env * amp);
    }).add;

    // FM shimmer with a wandering modulation index and slow tremolo.
    SynthDef(\glass, { |out, freq = 880, amp = 0.05, tone = 0.4, detune = 0.2,
                       attack = 6, release = 10, gate = 1|
        var f, index, sig, env;
        f = freq.lag(3) * LFNoise2.kr(0.1 ! 2, detune.lag(1) * 0.3).midiratio;
        index = tone.lag(1) * LFNoise2.kr(0.08).range(0.2, 2);
        sig = SinOsc.ar(f + SinOsc.ar(f * 2.001, 0, f * index));
        sig = sig * SinOsc.kr(Rand(0.1, 0.6), Rand(0, 2pi)).range(0.3, 1);
        env = EnvGen.kr(Env.asr(attack, 1, release, \sine), gate, doneAction: 2);
        Out.ar(out, sig * env * amp);
    }).add;

    // One bell strike: inharmonic partials, higher ones dying faster. Tone adds the upper partials.
    SynthDef(\bell, { |out, freq = 440, amp = 0.1, tone = 0.5, decay = 6, pan = 0|
        var ratios = [1, 2.76, 5.40, 8.93];
        var amps = [1, 0.6, 0.4, 0.25] * [1, tone, tone.squared, tone.cubed];
        var envs = [1, 0.5, 0.3, 0.15].collect { |d| EnvGen.ar(Env.perc(0.003, decay * d, 1, -4)) };
        var sig = (SinOsc.ar(freq * ratios) * amps * envs).sum;
        DetectSilence.ar(sig, 0.0001, 0.2, doneAction: 2);
        Out.ar(out, Pan2.ar(sig * amp, pan));
    }).add;

    // Wind and crackle. Density thins the wind and thickens the crackle; rate speeds up the gusts.
    SynthDef(\texture, { |out, amp = 8, density = 0.3, tone = 0.4, rate = 0.4, freq = 220|
        var speed, wind, dust, crackle;
        speed = rate.lag(1).linexp(0, 1, 0.3, 4);
        wind = BPF.ar(PinkNoise.ar(1 ! 2),
            (tone.lag(2).linexp(0, 1, 200, 5000) * LFNoise2.kr([0.05, 0.07] * speed).exprange(0.5, 2)).clip(60, 15000),
            LFNoise2.kr(0.1 * speed).range(0.08, 0.5), 2);
        wind = wind * LFNoise2.kr(0.15 * speed).range(0.3, 1);
        dust = Dust.ar(density.lag(1).linexp(0, 1, 0.5, 40) ! 2);
        crackle = Ringz.ar(dust * 0.2, freq.lag(4) * [3, 4.5], 0.15) + (dust * tone.lag(1) * 0.3);
        Out.ar(out, ((wind * (1 - (density.lag(1) * 0.5))) + crackle) * amp);
    }).add;

    // Per-layer channel strip: level, mute, and how much goes to the delay/reverb ("space").
    SynthDef(\strip, { |in, dry, send, level = 0.7, space = 0.5, mute = 0, id = 0|
        var sig = In.ar(in, 2) * (level.lag(0.2).squared * 2) * (1 - mute).lag(0.5);
        var sp = space.lag(0.2);
        SendReply.kr(Impulse.kr(15), '/meter', Amplitude.kr(sig.sum * 0.5, 0.05, 0.4), id);
        Out.ar(dry, sig * (1 - sp).sqrt);
        Out.ar(send, sig * sp.sqrt);
    }).add;

    // Send bus -> ping-pong delay (with freeze) -> reverb, mixed with the dry bus,
    // then drive -> bitcrush -> filter -> limiter on everything.
    SynthDef(\fx, { |dry, send, out = 0, drive = 0.1, crush = 0, filter = 1, delayMix = 0.3,
                    delayTime = 0.5, feedback = 0.5, freeze = 0, reverbMix = 0.6, room = 0.8, amp = 0.5|
        var wet, loop, delayed, sig, gain, crushed;
        wet = In.ar(send, 2);

        // Freeze stops new sound entering the delay and holds the loop at full feedback.
        loop = LocalIn.ar(2);
        delayed = DelayC.ar((wet * (1 - freeze.lag(0.05))) + (loop * Select.kr(freeze, [feedback, 1])),
            2.5, delayTime.lag(2));                                      // lag = tape-style pitch bends
        LocalOut.ar(LPF.ar(delayed, Select.kr(freeze, [3000, 12000])).reverse.tanh);
        wet = wet + (delayed * delayMix.max(freeze).lag(0.2));
        wet = FreeVerb2.ar(wet[0], wet[1], reverbMix.lag(0.2), room.lag(0.5), 0.5);

        sig = In.ar(dry, 2) + wet;

        gain = drive.lag(0.1).linexp(0, 1, 1, 30);
        sig = (sig * gain).tanh / gain.pow(0.3);

        crushed = Latch.ar(sig, Impulse.ar(crush.lag(0.1).linexp(0, 1, 48000, 1200)));
        crushed = crushed.round(crush.squared * 0.2);
        sig = SelectX.ar(crush.lag(0.1).min(0.05) * 20, [sig, crushed]);

        sig = RLPF.ar(sig, filter.lag(0.1).linexp(0, 1, 80, 18000), 0.7);
        sig = Limiter.ar(LeakDC.ar(sig) * amp.lag(0.1), 0.9);
        Out.ar(out, sig);
    }).add;

    s.sync;

    // ---------------------------------------------------------------- routing

    ~dryBus = Bus.audio(s, 2);
    ~sendBus = Bus.audio(s, 2);
    ~srcGroup = Group.new(s);
    ~stripGroup = Group.after(~srcGroup);
    ~fxGroup = Group.after(~stripGroup);
    ~fx = Synth(\fx, [\dry, ~dryBus, \send, ~sendBus], ~fxGroup);

    ~layerNames = [\sub, \pad, \glass, \bells, \texture];
    ~layers = ();
    ~layerNames.do { |name, i|
        var bus = Bus.audio(s, 2);
        ~layers[name] = (
            index: i, bus: bus, voices: List.new, muted: false,
            group: Group.tail(~srcGroup),
            strip: Synth(\strip, [\in, bus, \dry, ~dryBus, \send, ~sendBus, \id, i], ~stripGroup)
        );
    };
    ~texture = Synth(\texture, [\out, ~layers[\texture][\bus]], ~layers[\texture][\group]);

    // How each layer picks notes. Weights are for [root, fifth, any scale note].
    // Layers with a \def keep a set of sustained voices; bells are one-shots.
    ~conf = (
        sub: (def: \sub, amp: 0.22, minV: 1, maxV: 2, octave: -1, octaves: 1, weights: [0.7, 0.3, 0], lowest: 28),
        pad: (def: \pad, amp: 0.22, minV: 1, maxV: 6, octave: 0, octaves: 3, weights: [0.35, 0.25, 0.4]),
        glass: (def: \glass, amp: 0.25, minV: 0, maxV: 4, octave: 2, octaves: 2, weights: [0.2, 0.2, 0.6]),
        bells: (octave: 1, octaves: 3, weights: [0.25, 0.15, 0.6]),
        texture: ()
    );

    // ---------------------------------------------------------------- state

    // Every parameter is 0..1. Layer parameters are named <layer>_<param>, e.g. pad_tone.
    ~p = (
        volume: 0.7, weather: 0.4, drift: 0.3,
        drive: 0.1, crush: 0, filter: 1, delay: 0.35, time: 0.5, feedback: 0.5, reverb: 0.6, size: 0.85
    );
    ~layerParams = [\level, \density, \rate, \tone, \space];
    ~key = { |name, param| (name ++ "_" ++ param).asSymbol };
    (
        sub: [0.6, 0.5, 0.2, 0.3, 0.15],
        pad: [0.7, 0.5, 0.3, 0.4, 0.5],
        glass: [0.45, 0.4, 0.3, 0.4, 0.8],
        bells: [0.4, 0.3, 0.3, 0.5, 0.85],
        texture: [0.3, 0.3, 0.4, 0.4, 0.5]
    ).keysValuesDo { |name, vals| ~layerParams.do { |param, i| ~p[~key.(name, param)] = vals[i] } };

    // ~mod holds the weather's offsets (-1..1), scaled by the weather amount and added to the setting.
    ~mod = ();
    ~val = { |k| (~p[k] + ((~mod[k] ? 0) * ~p[\weather] * 0.5)).clip(0, 1) };
    ~lv = { |name, param| ~val.(~key.(name, param)) };

    ~scales = [
        [\minor, [0, 2, 3, 5, 7, 8, 10]],
        [\dorian, [0, 2, 3, 5, 7, 9, 10]],
        [\lydian, [0, 2, 4, 6, 7, 9, 11]],
        [\pentatonic, [0, 3, 5, 7, 10]],
        [\fifths, [0, 7]],
        [\phrygian, [0, 1, 3, 5, 7, 8, 10]]
    ];
    ~scaleIndex = 0;
    ~root = 38;                // MIDI note: D2
    ~hold = false;
    ~freezeOn = false;
    ~recording = false;
    ~meters = 0 ! ~layerNames.size;
    ~ui = nil;

    // How each parameter reaches the synths. Rates are read by the layer threads instead.
    ~targets = (
        volume: { |v| ~fx.set(\amp, v.squared) },
        drift: { |v| ~layerNames.do { |n| ~layers[n][\group].set(\detune, v * 0.6) } },
        drive: { |v| ~fx.set(\drive, v) },
        crush: { |v| ~fx.set(\crush, v) },
        filter: { |v| ~fx.set(\filter, v) },
        delay: { |v| ~fx.set(\delayMix, v * 0.8) },
        time: { |v| ~fx.set(\delayTime, v.linexp(0, 1, 0.05, 2.0)) },
        feedback: { |v| ~fx.set(\feedback, v * 0.95) },
        reverb: { |v| ~fx.set(\reverbMix, v) },
        size: { |v| ~fx.set(\room, v.linlin(0, 1, 0.3, 1)) },
        weather: { ~applyAll.value },
        texture_density: { |v| ~texture.set(\density, v) },
        texture_rate: { |v| ~texture.set(\rate, v) }
    );
    ~layerNames.do { |name|
        var layer = ~layers[name];
        ~targets[~key.(name, \level)] = { |v| layer[\strip].set(\level, v) };
        ~targets[~key.(name, \space)] = { |v| layer[\strip].set(\space, v) };
        ~targets[~key.(name, \tone)] = { |v| layer[\group].set(\tone, v) };
        if (~conf[name][\def].notNil) { ~targets[~key.(name, \density)] = { ~fitVoices.(name) } };
    };

    ~apply = { |k| ~targets[k].value(~val.(k)) };
    ~applyAll = { ~p.keysDo { |k| if (k != \weather) { ~apply.(k) } } };

    // ---------------------------------------------------------------- UI feedback

    ~sendUI = { |...args| ~ui !? { |a| a.sendMsg(*args) } };
    ~notify = {
        ~sendUI.('/state/info', ~root, ~noteName.(~root), ~scaleIndex, ~scales[~scaleIndex][0],
            ~hold.binaryValue, ~freezeOn.binaryValue, ~recording.binaryValue);
    };
    ~sendFullState = {
        ~p.keysValuesDo { |k, v| ~sendUI.('/state/p', k, v) };
        ~layerNames.do { |n| ~sendUI.('/state/mute', n, ~layers[n][\muted].binaryValue) };
        ~notify.value;
    };

    ~setParam = { |k, v|
        if (~p[k].notNil) {
            ~p[k] = v.asFloat.clip(0, 1);
            ~apply.(k);
            ~sendUI.('/state/p', k, ~p[k]);
        };
    };

    // ---------------------------------------------------------------- layer threads

    ~pickNote = { |name|
        var conf = ~conf[name];
        var scale = ~scales[~scaleIndex][1];
        var interval = [
            0, if (scale.includes(7)) { 7 } { scale.choose }, scale.choose
        ].wchoose(conf[\weights].normalizeSum);
        var note = ~root + interval + (12 * (conf[\octave] + rrand(0, conf[\octaves] - 1)));
        while { note < (conf[\lowest] ? 0) } { note = note + 12 };   // keep the sub audible
        note
    };

    ~addVoice = { |name|
        var conf = ~conf[name], layer = ~layers[name];
        var note = ~pickNote.(name);
        var synth = Synth(conf[\def], [
            \out, layer[\bus], \freq, note.midicps, \amp, conf[\amp],
            \tone, ~lv.(name, \tone), \detune, ~val.(\drift) * 0.6,
            \attack, rrand(4, 12), \release, rrand(8, 16)
        ], layer[\group]);
        layer[\voices].add((node: synth, pitch: note));
    };

    ~removeVoice = { |name| ~layers[name][\voices].removeAt(0) !? { |v| v[\node].release } };

    ~retune = { |v, name|
        v[\pitch] = ~pickNote.(name);
        v[\node].set(\freq, v[\pitch].midicps);
    };

    ~fitVoices = { |name|
        var conf = ~conf[name], voices = ~layers[name][\voices];
        var want = (~lv.(name, \density) * (conf[\maxV] - conf[\minV])).round.asInteger + conf[\minV];
        while { voices.size < want } { ~addVoice.(name) };
        while { voices.size > want } { ~removeVoice.(name) };
    };

    // Sustained layers: every so often move one voice to a new note. Glass instead swaps its
    // oldest voice for a new one, so notes swell in and out. Rate sets how often (40s .. 2s).
    ~voiceThread = { |name, swell = false|
        Routine {
            loop {
                if (~hold.not) {
                    var voices = ~layers[name][\voices];
                    ~fitVoices.(name);
                    if (voices.notEmpty) {
                        if (swell) { ~removeVoice.(name); ~addVoice.(name) } { ~retune.(voices.choose, name) };
                    };
                };
                (~lv.(name, \rate).linexp(0, 1, 40, 2) * rrand(0.6, 1.4)).wait;
            }
        }
    };

    // Bells: strikes of 1-3 notes, slightly strummed. Rate sets how often (15s .. 0.5s on average).
    ~bellThread = Routine {
        loop {
            var layer = ~layers[\bells];
            var now = Main.elapsedTime;
            var count = 1 + (~lv.(\bells, \density) * 3 * 1.0.rand).floor.asInteger;
            layer[\voices] = layer[\voices].select { |v| v[\until] > now };
            if (layer[\muted].not and: { ~lv.(\bells, \level) > 0.01 }) {
                count.do { |i|
                    var note = ~pickNote.(\bells), decay = rrand(3.0, 9.0);
                    SystemClock.sched(i * rrand(0.04, 0.25), {
                        Synth(\bell, [\out, layer[\bus], \freq, note.midicps, \amp, 0.5,
                            \tone, ~lv.(\bells, \tone), \decay, decay, \pan, rrand(-0.7, 0.7)], layer[\group]);
                        nil
                    });
                    layer[\voices].add((pitch: note, until: now + decay));
                };
            };
            (~lv.(\bells, \rate).linexp(0, 1, 15, 0.5) * exprand(0.4, 2.0)).wait;
        }
    };

    // Weather: a slow random walk on each of these, always drifting back towards the setting.
    ~weatherKeys = [\sub_tone, \pad_tone, \glass_tone, \bells_tone, \texture_tone, \texture_density,
        \pad_space, \glass_space, \filter, \time, \drift];
    ~weatherThread = Routine {
        var dt = 0.25;
        loop {
            if (~p[\weather] > 0) {
                ~weatherKeys.do { |k|
                    var m = ~mod[k] ? 0;
                    ~mod[k] = (m - (m * 0.03 * dt) + (0.gauss(0.1) * dt.sqrt)).clip(-1, 1);
                    ~apply.(k);
                };
            };
            dt.wait;
        }
    };

    // Sends meters, live (weather-affected) values and playing notes to the UI 10 times a second.
    ~uiThread = Routine {
        loop {
            ~ui !? { |a|
                a.sendMsg('/state/meters', *~meters);
                a.sendMsg('/state/eff', *~p.keys.asArray.collect { |k| [k, ~val.(k)] }.flatten);
                ~layerNames.do { |n| a.sendMsg('/state/notes', n, *~layers[n][\voices].collect { |v| v[\pitch] }.asArray) };
            };
            0.1.wait;
        }
    };

    // ---------------------------------------------------------------- performance actions

    // Re-pick every sustained note, staggered so the chord morphs rather than jumps.
    ~mutate = {
        fork {
            [\sub, \pad, \glass].do { |name|
                ~layers[name][\voices].copy.do { |v|
                    if (~layers[name][\voices].includes(v)) { ~retune.(v, name) };
                    rrand(0.3, 1.5).wait;
                }
            }
        }
    };

    ~noteName = { |n| ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"][n % 12] ++ ((n div: 12) - 1) };

    ~setRoot = { |note|
        var shift = note.asInteger.clip(24, 60) - ~root;
        ~root = ~root + shift;
        [\sub, \pad, \glass].do { |name|
            ~layers[name][\voices].do { |v| v[\pitch] = v[\pitch] + shift; v[\node].set(\freq, v[\pitch].midicps) };
        };
        ~texture.set(\freq, (~root + 24).midicps);
        "root: %".format(~noteName.(~root)).postln;
        ~notify.value;
    };

    ~setScale = { |i|
        ~scaleIndex = i.asInteger.wrap(0, ~scales.size - 1);
        "scale: %".format(~scales[~scaleIndex][0]).postln;
        ~mutate.value;
        ~notify.value;
    };

    ~setMute = { |name, on|
        ~layers[name] !? { |layer|
            layer[\muted] = on;
            layer[\strip].set(\mute, on.binaryValue);
            ~sendUI.('/state/mute', name, on.binaryValue);
        };
    };

    ~setFreeze = { |on| ~freezeOn = on; ~fx.set(\freeze, on.binaryValue); ~notify.value };
    ~setHold = { |on| ~hold = on; ~notify.value };

    ~setRecord = { |on|
        if (on and: { ~recording.not }) {
            var dir = "~/drone-recordings".standardizePath;
            File.mkdir(dir);
            s.record(dir +/+ "drone_%.wav".format(Date.getDate.stamp));
            ~recording = true;
        };
        if (on.not and: { ~recording }) { s.stopRecording; ~recording = false };
        ~notify.value;
    };

    // ---------------------------------------------------------------- OSC

    ~p.keysDo { |k| OSCdef(("p_" ++ k).asSymbol, { |msg| ~setParam.(k, msg[1]) }, ("/p/" ++ k).asSymbol) };
    OSCdef(\mute, { |msg| ~setMute.(msg[1].asSymbol, msg[2] > 0) }, '/mute');
    OSCdef(\root, { |msg| ~setRoot.(msg[1]) }, '/root');
    OSCdef(\rootStep, { |msg| ~setRoot.(~root + msg[1]) }, '/root/step');
    OSCdef(\scale, { |msg| ~setScale.(msg[1]) }, '/scale');
    OSCdef(\scaleNext, { ~setScale.(~scaleIndex + 1) }, '/scale/next');
    OSCdef(\mutate, { ~mutate.value }, '/mutate');
    OSCdef(\hold, { |msg| ~setHold.(msg[1] > 0) }, '/hold');
    OSCdef(\freeze, { |msg| ~setFreeze.(msg[1] > 0) }, '/freeze');
    OSCdef(\record, { |msg| ~setRecord.(msg[1] > 0) }, '/record');
    OSCdef(\meter, { |msg| ~meters[msg[2]] = msg[3] }, '/meter');

    // A UI says hello (with the port it listens on) and gets the full state back.
    OSCdef(\hello, { |msg, time, addr|
        var ui = NetAddr(addr.ip, msg[1].asInteger);
        if (ui != ~ui) { "UI connected: %:%".format(addr.ip, msg[1]).postln };
        ~ui = ui;
        ~sendFullState.value;
    }, '/ui/hello');

    // ---------------------------------------------------------------- MIDI (optional)

    // Edit this to match your controller's CC numbers.
    ~ccMap = (
        1: \sub_level, 2: \pad_level, 3: \glass_level, 4: \bells_level, 5: \texture_level,
        6: \filter, 7: \feedback, 8: \reverb, 9: \drive, 10: \weather, 11: \volume
    );
    try {
        MIDIClient.init(verbose: false);
        MIDIIn.connectAll;
        MIDIdef.cc(\cc, { |val, num| ~ccMap[num] !? { |k| ~setParam.(k, val / 127) } });
        // Playing any key moves the drone's root to that note (kept in the C2..B2 octave).
        MIDIdef.noteOn(\root, { |vel, note| ~setRoot.(36 + (note % 12)) });
    } { "MIDI unavailable, continuing with OSC only".postln };

    // ---------------------------------------------------------------- go

    ~setRoot.(~root);
    ~applyAll.value;
    ~voiceThread.(\sub).play;
    ~voiceThread.(\pad).play;
    ~voiceThread.(\glass, true).play;
    ~bellThread.play;
    ~weatherThread.play;
    ~uiThread.play;
    if (thisProcess.openPorts.includes(57120).not) {
        "WARNING: port 57120 was busy (is another sclang running?). Listening on % instead.".format(thisProcess.openPorts).postln;
    };
    "Drone machine running. OSC on port(s) %".format(thisProcess.openPorts).postln;
};
)

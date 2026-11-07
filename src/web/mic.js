// Recording the microphone for voice (voice.* in the config; src/voice.zig),
// shared by the board (talking to the operator) and the terminal page
// (dictating into a session). The page records; cl web runs voice.stt on
// the WAV it gets.

// micOpen() asks for the mic and starts recording; micClose(rec) stops it
// and gives back { chunks, rate, ms }: Float32 chunks of ~0.1 s at `rate` Hz,
// and how long it ran.
async function micOpen() {
  const stream = await navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true } });
  const ac = new AudioContext();
  const src = ac.createMediaStreamSource(stream);
  // ScriptProcessor is deprecated but works everywhere, WebKitGTK included.
  const proc = ac.createScriptProcessor(4096, 1, 1);
  const chunks = [];
  proc.onaudioprocess = (e) => chunks.push(new Float32Array(e.inputBuffer.getChannelData(0)));
  src.connect(proc); proc.connect(ac.destination);
  return { stream, ac, src, proc, chunks, at: Date.now() };
}
function micClose(r) {
  r.proc.disconnect(); r.src.disconnect(); r.stream.getTracks().forEach((t) => t.stop());
  const rate = r.ac.sampleRate;
  r.ac.close();
  return { chunks: r.chunks, rate, ms: Date.now() - r.at };
}
// Is the mic there at all? Browsers only offer it on HTTPS or 127.0.0.1.
const micAllowed = () => !!navigator.mediaDevices?.getUserMedia;
const MIC_NO_HTTPS = "The browser only allows the mic on HTTPS or 127.0.0.1 (README, Voice)";

// The loudest stretch (RMS of each chunk, ~0.1 s), 0..1. Whisper makes words
// up out of silence ("you", "Thank you."): a recording that never got louder
// than MIC_QUIET isn't sent.
const MIC_QUIET = 0.015;
function loudest(chunks) {
  let max = 0;
  for (const c of chunks) { let sum = 0; for (const x of c) sum += x * x; max = Math.max(max, Math.sqrt(sum / c.length)); }
  return max;
}
// Float32 chunks at `from` Hz -> a 16-bit mono WAV at `to` Hz (what whisper wants).
function wavOf(chunks, from, to) {
  const len = chunks.reduce((n, c) => n + c.length, 0);
  const all = new Float32Array(len);
  let o = 0; for (const c of chunks) { all.set(c, o); o += c.length; }
  const step = from / to, n = Math.floor(len / step);
  const buf = new ArrayBuffer(44 + n * 2), v = new DataView(buf);
  const str = (at, s) => { for (let i = 0; i < s.length; i++) v.setUint8(at + i, s.charCodeAt(i)); };
  str(0, "RIFF"); v.setUint32(4, 36 + n * 2, true); str(8, "WAVE"); str(12, "fmt ");
  v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true);
  v.setUint32(24, to, true); v.setUint32(28, to * 2, true); v.setUint16(32, 2, true); v.setUint16(34, 16, true);
  str(36, "data"); v.setUint32(40, n * 2, true);
  for (let i = 0; i < n; i++) {
    // Average the samples this one covers: a cheap low-pass before dropping the rate.
    const a = Math.floor(i * step), b = Math.max(a + 1, Math.floor((i + 1) * step));
    let sum = 0; for (let k = a; k < b; k++) sum += all[k];
    const x = Math.max(-1, Math.min(1, sum / (b - a)));
    v.setInt16(44 + i * 2, x < 0 ? x * 0x8000 : x * 0x7fff, true);
  }
  return new Blob([buf], { type: "audio/wav" });
}

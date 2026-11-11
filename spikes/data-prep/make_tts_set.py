"""Phase 3 golden speech set made with the macOS `say` voices (first-party, offline). Synthetic speech: it measures the
transcribers against exact reference text, but it is cleaner than real recordings, so real creator speech comes later.
Sets: english (US/UK), indian_english, hindi (Devanagari), hinglish (code-mixed), noisy_english (10 dB SNR with ESC-50
sounds), and one long timeline clip with known sentence start times (timestamp error).
Run: python3 -I make_tts_set.py          Output: ~/Library/Developer/SmartAsset/phase3/data/speech"""
import json, math, random, struct, subprocess, wave
from pathlib import Path

ROOT = Path.home() / "Library/Developer/SmartAsset/phase3/data"
OUT = ROOT / "speech"
OUT.mkdir(parents=True, exist_ok=True)
RATE = 16000

EN = [
    "This drone shot flies over a glacier at sunrise and the light is warm on the ice.",
    "Welcome back to the channel, today we are testing three microphones in a noisy kitchen.",
    "Add a slow zoom on the interview, then cut to the wide shot of the studio.",
    "The podcast episode covers how small teams ship software without any managers.",
    "Please remove the background music under the voiceover and keep the street ambience.",
    "At the two minute mark the speaker explains why the battery drains so quickly.",
    "We recorded the sound effects in a parking garage because the echo was perfect.",
    "Export the vertical version for social media and keep the captions inside the safe area.",
]
HI = [
    "आज हम पहाड़ों में सुबह की सैर के लिए जा रहे हैं।",
    "इस वीडियो में हम नया कैमरा और उसके लेंस की जांच करेंगे।",
    "कृपया आवाज़ को थोड़ा धीमा कीजिए और संगीत बंद कर दीजिए।",
    "शहर की गलियों में बारिश के बाद बहुत सुंदर रोशनी थी।",
    "हमारे पॉडकास्ट में आज एक नए लेखक से बातचीत होगी।",
    "यह दृश्य समुद्र के किनारे सूर्यास्त के समय लिया गया था।",
    "इंटरव्यू के बाद हम बाज़ार की आवाज़ें रिकॉर्ड करेंगे।",
    "कल सुबह हम सब स्टूडियो में मिलेंगे और शूटिंग शुरू करेंगे।",
]
HINGLISH = [
    "आज का vlog बहुत मज़ेदार है क्योंकि हमने drone से पूरा शहर shoot किया।",
    "इस clip में interview के बाद थोड़ा background music add कर दो।",
    "हमारा podcast आज रात upload होगा तो subscribe करना मत भूलना।",
    "यह वाला shot बहुत अच्छा आया है, इसे timeline में सबसे ऊपर रखो।",
    "कैमरा की battery low है इसलिए हम next scene कल record करेंगे।",
    "मैंने इस video का voiceover Hindi और English दोनों में बनाया है।",
    "Export करने से पहले colour grading एक बार फिर check कर लेना।",
    "यह sound effect बहुत loud है, volume थोड़ा कम कर दो।",
]

def say(text, voice, name):
    aiff = OUT / f"{name}.aiff"
    wav = OUT / f"{name}.wav"
    subprocess.run(["say", "-v", voice, "-o", str(aiff), text], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{RATE}", "-c", "1", str(aiff), str(wav)], check=True)
    aiff.unlink()
    return wav

def read(path):
    with wave.open(str(path)) as w:
        assert w.getframerate() == RATE and w.getnchannels() == 1 and w.getsampwidth() == 2, path
        return list(struct.unpack(f"<{w.getnframes()}h", w.readframes(w.getnframes())))

def write(path, samples):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(struct.pack(f"<{len(samples)}h", *[max(-32768, min(32767, int(s))) for s in samples]))

def first_speech(samples, floor=400):
    for i, s in enumerate(samples):
        if abs(s) > floor: return i / RATE
    return 0.0

def rms(x):
    return math.sqrt(sum(v * v for v in x) / max(1, len(x)))

items = []
def add(group, name, text, voice, lang, wav):
    s = read(wav)
    items.append({"group": group, "file": wav.name, "text": text, "voice": voice, "language": lang, "seconds": round(len(s) / RATE, 2)})

for i, t in enumerate(EN):
    voice = ["Samantha", "Daniel"][i % 2]
    add("english", f"en{i}", t, voice, "en", say(t, voice, f"en{i}"))
for i, t in enumerate(EN):
    voice = ["Aman", "Rishi", "Tara"][i % 3]
    add("indian_english", f"ien{i}", t, voice, "en", say(t, voice, f"ien{i}"))
for i, t in enumerate(HI):
    add("hindi", f"hi{i}", t, "Lekha", "hi", say(t, "Lekha", f"hi{i}"))
for i, t in enumerate(HINGLISH):
    add("hinglish", f"hg{i}", t, "Lekha", "hi", say(t, "Lekha", f"hg{i}"))

# noisy: English speech mixed with ESC-50 clips (rain, engine, crowd...) at 10 dB signal-to-noise
noise_files = sorted((ROOT / "esc50/clips").glob("*.wav"))
rng = random.Random(3)
for i, t in enumerate(EN):
    speech = read(OUT / f"en{i}.wav")
    src = rng.choice(noise_files)
    tmp = OUT / "_noise16k.wav"
    subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{RATE}", "-c", "1", str(src), str(tmp)], check=True)   # ESC-50 is 44.1 kHz
    noise = read(tmp)
    tmp.unlink()
    noise = [noise[j % len(noise)] for j in range(len(speech))]
    gain = rms(speech) / (rms(noise) or 1) / (10 ** (10 / 20))
    mixed = [a + b * gain for a, b in zip(speech, noise)]
    p = OUT / f"noisy{i}.wav"; write(p, mixed)
    add("noisy_english", f"noisy{i}", t, "Samantha/Daniel + ESC-50 at 10 dB", "en", p)

# timeline: the English sentences one after another with 3 s of near-silence between, true start times known
timeline, marks, t = [], [], 0.0
for i, text in enumerate(EN):
    s = read(OUT / f"en{i}.wav")
    lead = first_speech(s)
    marks.append({"index": i, "text": text, "speech_start": round(t + lead, 3)})
    timeline += s + [0] * int(3 * RATE)
    t += len(s) / RATE + 3
write(OUT / "timeline_en.wav", timeline)
(OUT / "timeline_en.json").write_text(json.dumps({"seconds": round(t, 1), "sentences": marks}, indent=1))
(OUT / "speech.json").write_text(json.dumps(items, indent=1, ensure_ascii=False))
print(len(items), "utterances;", "timeline", round(t, 1), "s")

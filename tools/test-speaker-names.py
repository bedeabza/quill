#!/usr/bin/env python3
"""Exercise three named caption streams through Quill using local macOS voices."""
import argparse
import json
import subprocess
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quill", type=Path, default=Path(__file__).resolve().parents[1] / ".build/debug/quill")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    root = args.output or Path(tempfile.mkdtemp(prefix="quill-named-speaker-test-"))
    root.mkdir(parents=True, exist_ok=True)
    phrases = [
        ("Samantha", "Good morning everyone. Today we need to review the project timeline and agree on the delivery date. The design team has finished the first draft and is ready for feedback."),
        ("Daniel", "Thank you. The engineering work is progressing well. We completed the database migration yesterday and all automated tests are passing. I expect the remaining integration work to finish next week."),
        ("Alex", "From the customer side, the main priority is clear communication. We should prepare a short update explaining the new features and schedule a demonstration for the support team. That will help everyone prepare."),
    ]
    time = 0
    observations = []
    files = []
    for index, (voice, phrase) in enumerate(phrases):
        audio, wav = root / f"{index}.aiff", root / f"{index}.wav"
        subprocess.run(["say", "-v", voice, "-o", str(audio), phrase], check=True)
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(audio), "-ar", "16000", "-ac", "1", str(wav)], check=True)
        duration = float(subprocess.check_output(["ffprobe", "-v", "quiet", "-show_entries", "format=duration", "-of", "csv=p=0", str(wav)]))
        files.append(f"file '{index}.wav'")
        observations.append({"observed_at": 1788912000 + time + duration + 1, "meeting_id": "synthetic-fixture",
                             "names": [f"Fixture {chr(65 + index)}"], "source": "meeting_caption", "text": phrase, "is_local": False})
        time += duration
    (root / "list.txt").write_text("\n".join(files))
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", str(root / "list.txt"),
                    "-c:a", "pcm_s16le", str(root / "system.caf")], check=True)
    (root / "meta.json").write_text(json.dumps({"started": "2026-09-09T00:00:00Z", "duration_seconds": int(time),
                                               "audio_started_at": 1788912000, "files": {"system": "system.caf"}, "start_offset_ms": {"system": 0}}))
    (root / "speaker-observations.jsonl").write_text("\n".join(json.dumps(item) for item in observations) + "\n")
    result = root / "result"
    with (root / "inference.log").open("w") as log:
        subprocess.run([str(args.quill), "transcribe", str(root), "--output", str(result), "--offline"], check=True, stdout=log, stderr=log)
    transcript = json.loads((result / "transcript.json").read_text())
    names = {segment["speaker_name"] for segment in transcript["segments"] if segment.get("speaker_name")}
    assert names == {"Fixture A", "Fixture B", "Fixture C"}, names
    # A name must stay inside its caption's actual speech interval even if
    # diarization puts two voices into one acoustic cluster.
    start = 0
    for observation in observations:
        end = observation["observed_at"] - 1788912000 - 1
        for segment in transcript["segments"]:
            if segment.get("speaker_name") == observation["names"][0]:
                assert start - 0.5 <= segment["start_ms"] / 1000 <= segment["end_ms"] / 1000 <= end + 0.5, segment
        start = end
    print(f"Three names correctly scoped to their speech: {result}")


if __name__ == "__main__":
    main()

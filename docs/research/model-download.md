# Model download (H5, H3): what is fetched, how it is checked, and what was tested

Status 2026-11-09. Built to the owner's rules of 2026-11-09 (PLAN §16).

## The rules, and where each is enforced

| Rule | Where |
| --- | --- |
| Hugging Face only, pinned and verified files only, never arbitrary repositories | `SmartAssetKit/PinnedModels.swift`: one model, one repository, one full commit hash, 11 files with size and SHA-256. URLs are built only from these (`…/resolve/<commit>/<path>`) |
| Download only when the person selects Download Model | `Settings ▸ Models` button → confirmation sheet → `ModelDownload.start()`. Nothing else calls it; no timer, no launch check |
| Show name, publisher, version/commit, size and disk space first | The confirmation sheet: model, publisher, source, version (commit, pinned), download size and file count, disk space needed (and free), license |
| SHA-256 against trusted published hashes | Every file after download (`ModelFiles.check`), and all files again before installing (`ModelFiles.problems`) |
| HTTPS, temporary files, atomic install after verification | Pinned URLs are `https://huggingface.co`; redirects only to HTTPS Hugging Face hosts (`PinnedModels.allowsRedirect`: huggingface.co, *.huggingface.co, hf.co, *.hf.co); files go to `Models/.download-<id>/` beside the final folder; `ModelFiles.install` moves the whole folder into place (`moveItem`, or `replaceItemAt` over an older install) after a receipt naming the commit is written |
| Stored locally in Application Support | `~/Library/Application Support/SmartAsset/Models/mlx`. The app loads models from nowhere else (`SemanticModels.directory`); tests point `SA_MODELS_DIR`/`SA_MODELS_ROOT` elsewhere explicitly |
| No telemetry, analytics, cloud inference, automatic downloads, update checks | Ephemeral URL session (no cookies, cache or stored credentials), no extra headers; `tools/audit-network.sh` checks that networking code exists only in `Models/ModelDownload.swift`, names only https://huggingface.co, and schedules nothing |
| Works with Wi-Fi off once installed | `tools/offline-check.sh` runs the model self-tests with internet connections denied by the OS |

## Where the checksums come from

Pinned in Phase 3 (`phase3/PINS.md`): `Nurymanau/EmbeddingGemma-2-MLX-Swift` at commit `06b4e075e6b3772e3c29df9f2a2ace7bd4950bdd`.
Re-read on 2026-11-09 from Hugging Face's API at that commit:

* The three large files are Git LFS objects; Hugging Face publishes their SHA-256, and the pins equal it: `text-q8/model.safetensors`
  (288,118,885 bytes, eb8a0674…), `text-q8/tokenizer.json` (32,170,510, 4d777ef5…), `vision-q8/vision.safetensors` (193,095,171,
  9b18ee38…).
* The eight small JSON files are plain git blobs; Hugging Face lists only their git blob id (SHA-1). The local Phase 3 copies'
  `git hash-object` ids equal the published ids for all eight, and the pinned SHA-256 values were computed from those copies.

Total 513,421,847 bytes; the app asks for 10 % more free space.

## Tested

* Kit tests: URLs are the pinned commit over HTTPS; redirects to anything but Hugging Face hosts over HTTPS are refused
  (`http://`, look-alike hosts, other schemes); a missing file, a wrong size and a wrong checksum are each reported; install
  moves (never copies), replaces an older install in one step, and an install of another commit or with a damaged file is not
  recognised.
* Self-test "model download" (opt-in, `SA_NETWORK_TESTS=1`, into a folder in /tmp), against the real Hugging Face, 2026-11-09:
  a pin with a wrong checksum was refused with "did not match its published checksum" and nothing was installed; then the 11
  files (513.4 MB) downloaded, verified and installed in **178 s**, search by meaning started with them and answered a
  query, and Remove stopped search by meaning and deleted the files.
* `tools/audit-network.sh`: all checks pass (networking only in the download file, one host, nothing scheduled, no network
  crate in Rust, no internet socket in 176 samples while indexing, describing and searching).
* `tools/offline-check.sh`: with internet connections denied by `sandbox-exec` (checked: a request to huggingface.co is
  refused), semantic search, text in pictures, labels, video moments and More Like This all pass.

## Not done

* Resume within a file: an interrupted download keeps the files already verified and fetches the rest; a half-downloaded
  file starts again.
* Whisper models (Phase 5) and switching between several search models (only one exists).
* H3 "recommendation by memory tier": the Models tab states the measured memory use (about 1.2 GB, on a 16 GB Mac); no 8 GB
  or 24–32 GB Mac was tested, so no tier is claimed.
* The confirmation sheet is not in the snapshot set.

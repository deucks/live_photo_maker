## 0.0.1

* TODO: Describe initial release.

## 0.0.2

* Fix: bug fix.

## 0.0.3

* Fix: bug fix.

## 0.0.4

* Fix: bug fix.

## 0.0.5

* Feature: Add video support.

## 0.0.6

* Upgrade README.md

## 0.0.7

* Documented the wallpaper-motion contract: iOS requires a ~0.92s paired video
  (longer clips get "Motion Not Available") and plays it slowed ~3.3x on the
  lockscreen — so callers must feed real-time (1x) video and let the pipeline
  do the squeeze. Pre-speeding the input makes the wallpaper look too fast.
* Retime step is skipped when the clip already matches the target duration.
* Fix: retiming scaled only the video track, leaving longer audio behind — exports gained a black-frame tail when the source had audio.
* Fix: asset writer no longer runs in real-time mode (could drop frames on slower devices).

## 0.0.8

* Fast path: input that already matches the Live Photo contract (~0.92s,
  1080x1920) skips the duration/retime/resize transcode passes entirely, and
  its compressed frames are copied into the paired video without re-encoding
  (passthrough) — no generation loss, much faster.
* Errors now surface to Dart: `create()` throws `LivePhotoException` with the
  failing stage and native error message instead of returning false (and the
  call no longer hangs forever when generation fails).
* Staged paired video/photo files are deleted after the library save, and
  stale cache files are swept at the start of each generation — the plugin
  cache no longer grows by a few MB per creation.

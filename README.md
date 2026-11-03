# Phone Home Spike (iOS) — Step 1 cadence spike

Thin native beacon that proves the "about hourly" background cadence
against the real Phone Home Firebase project: BGAppRefreshTask
(earliest +1h, re-armed in the handler, Bus iOS pattern) → one
CLLocation fix → battery → one small RTDB write → sleep.

- Household `SPIKE1`, phone `spikeI` ("Spike iPhone").
- Identity: Firebase Anonymous Auth over REST, Follow Me lifecycle
  (sign up once, persist tokens, refresh-first, never blind re-sign-up).
- On-device log (Toronto stamps) is the cadence evidence; Share from
  the app's single screen.
- Built unsigned by GitHub Actions (xcodegen + xcodebuild), like the
  Bus iOS apps; signed at install time by the same tooling Domi uses
  for the other unsigned IPAs.

This is a spike: no watcher page, no Step 2 features.

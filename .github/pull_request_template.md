## Summary
<!-- What does this change, and why? A few sentences or bullets. -->

## Changes
<!-- The notable parts: new files or types, behaviour that changes, anything deliberately left alone. -->

## Test plan
<!-- Tick what you ran. Say plainly what you did NOT or could not run. -->
- [ ] `xcodebuild test -scheme AudioRecorder -destination 'platform=macOS'` passes with no new warnings
- [ ] New or changed logic has tests
- [ ] Tried it in the app (record / stop, and anything this touches)

## Not covered
<!-- Anything not tested or only checked by hand: real Core Audio recording, the UI's look, older macOS versions, … -->

## Checklist
- [ ] User-visible change? Added a line under **Unreleased** in `CHANGELOG.md`
- [ ] README updated if usage or setup changed
- [ ] No personal signing settings in the project file (use `Config/Local.xcconfig`)

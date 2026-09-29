# Contributing to Moonlight

Thanks for helping. Bug reports, fixes and improvements are all welcome.

## Reporting bugs and ideas

Open a GitHub issue. For bugs, include:

- what you did, what you expected, and what happened instead
- your macOS or iOS version and the Moonlight version (Moonlight > About Moonlight)
- the audio format involved, if the problem is with particular files

Please don't attach copyrighted music. A short description of the file (format,
where it was tagged) is usually enough. Security problems go through
[SECURITY.md](SECURITY.md), not public issues.

## Making changes

1. Fork the repository and create a branch for your change.
2. Set up the project as described in "Building Moonlight yourself" in the
   [README](README.md). Don't commit your `Config/*.local.xcconfig` files or a
   `GoogleService-Info.plist`; git ignores them.
3. Keep each pull request focused on one change, and explain *why* in the description.
4. Add or update tests for behaviour you change.
5. Make sure the tests pass:

   ```sh
   xcodebuild test -project Moonlight.xcodeproj -scheme Moonlight -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO
   xcodebuild test -project Moonlight.xcodeproj -scheme MoonlightMobile -destination "platform=iOS Simulator,name=iPhone 17 Pro" CODE_SIGNING_ALLOWED=NO
   ```

CI runs the same builds and tests on every pull request.

## Code guidelines

- Edit `project.yml`, not `Moonlight.xcodeproj`, then run `xcodegen generate`.
  Commit both.
- Match the style of the surrounding code.
- Every Swift file starts with a short plain-English header explaining what the
  file does. Keep it accurate when you change a file's purpose, and add one to new
  files.
- Read [ARCHITECTURE.md](ARCHITECTURE.md) before larger changes for a short technical overview.
- Your music files are precious. Code that writes to audio files must be careful
  and tested against the fixtures in `Tests/Fixtures`.

## License of contributions

Moonlight is licensed under the [Mozilla Public License 2.0](LICENSE). By
submitting a pull request, you agree that your contribution is licensed under the
same license. Only contribute code and assets you have the right to share.

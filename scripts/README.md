# Scripts

- `setup.sh` ensures formal-web exists at the pin, applies the patch, builds
  the three helper executables and the binding crate, and installs the CDP
  client's `ws` dependency in the formal-web clone.
- `build-app.sh` builds the Swift app and assembles `dist/Agent Browser.app`,
  including the helper executables and the MLX resource bundles.
- `run-app.sh` runs the development bundle with the model and extension
  directories filled in.
- `stop-app.sh` stops every known Agent Browser binary so a test run starts
  from one instance.
- `smoke-test.sh` installs `examples/hello` into the data directory, stops any
  old app, and runs one inference task through `launch`, `prompt` and
  `verify`. It does not enable training.

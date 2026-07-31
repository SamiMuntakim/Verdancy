// Jest stand-in for `.png` imports (esbuild's `binary` loader yields a Uint8Array
// at build time; Node can't require a PNG). Handlers only forward these bytes to
// the Gemini client, which is mocked in tests, so a tiny PNG signature suffices.
module.exports = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]);

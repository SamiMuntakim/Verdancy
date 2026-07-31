// Bundled binary assets imported by handlers. esbuild's `binary` loader turns a
// `.png` import into a Uint8Array; this ambient declaration lets tsc type it
// without reading the file. See BuddyFn bundling in lib/verdancy-stack.ts.
declare module '*.png' {
  const data: Uint8Array;
  export default data;
}

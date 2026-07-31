module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'node',
  roots: ['<rootDir>/test'],
  testMatch: ['**/*.test.ts'],
  // `.png` imports (bundled binary in prod) → a stub so handler modules load.
  moduleNameMapper: { '\\.png$': '<rootDir>/test/helpers/pngStub.js' },
};

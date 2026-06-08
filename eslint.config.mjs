import tseslint from 'typescript-eslint';

export default tseslint.config(
  {
    ignores: ['cdk.out/**', 'node_modules/**', 'dist/**', '**/*.js', '**/*.d.ts'],
  },
  ...tseslint.configs.recommended,
);

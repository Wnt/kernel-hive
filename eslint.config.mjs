// Repository Node-script lint. The SPA keeps its richer, app-only config in
// spa/eslint.config.js so scripts here do not enter the SPA or Knip scopes.
export default [
  {
    files: ['scripts/**/*.mjs'],
    languageOptions: {
      ecmaVersion: 2023,
      sourceType: 'module',
      globals: {
        AbortController: 'readonly',
        Buffer: 'readonly',
        console: 'readonly',
        crypto: 'readonly',
        document: 'readonly',
        fetch: 'readonly',
        performance: 'readonly',
        process: 'readonly',
        setTimeout: 'readonly',
        structuredClone: 'readonly',
        TextDecoder: 'readonly',
        TextEncoder: 'readonly',
        URL: 'readonly',
        WebSocket: 'readonly',
        window: 'readonly',
      },
    },
    rules: {
      eqeqeq: ['error', 'always', { null: 'ignore' }],
      'no-unused-vars': [
        'error',
        {
          args: 'after-used',
          argsIgnorePattern: '^_|^e$',
          caughtErrors: 'none',
          varsIgnorePattern: '^_',
        },
      ],
      'no-var': 'error',
      'prefer-const': ['error', { destructuring: 'all' }],
    },
  },
];

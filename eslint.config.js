import eslintConfig from '@falcondev-oss/configs/eslint'

export default eslintConfig({
  tsconfigPath: './tsconfig.json',
})
  .append({
    // The GNOME Shell process is a GJS runtime, not Node. It exposes a few
    // globals and consumes untyped, private Shell internals. Relax the rules
    // that fight those patterns — only for the extension sources.
    name: 'gjs/extension',
    files: ['gnome-extension/src/**/*.ts'],
    languageOptions: {
      globals: {
        global: 'readonly',
        globalThis: 'readonly',
        log: 'readonly',
        logError: 'readonly',
        print: 'readonly',
        printerr: 'readonly',
        _: 'readonly',
        ngettext: 'readonly',
        C_: 'readonly',
      },
    },
    rules: {
      // Reaching into private Shell internals (e.g. quickSettings._system) is
      // untyped by design; the type-aware "unsafe" rules flag every hop.
      'ts/no-unsafe-member-access': 'off',
      'ts/no-unsafe-assignment': 'off',
      'ts/no-unsafe-call': 'off',
      'ts/no-unsafe-return': 'off',
      'ts/no-unsafe-argument': 'off',
      'ts/no-explicit-any': 'off',
      // GJS/GNOME extensions use the `_foo` convention for private members and
      // order methods by lifecycle (enable/disable first), not visibility.
      'no-underscore-dangle': 'off',
      'unicorn/prefer-private-class-fields': 'off',
      'unicorn/consistent-class-member-order': 'off',
    },
  })
  .append({
    // Build tooling runs under Node and legitimately logs progress.
    name: 'node/scripts',
    files: ['scripts/**/*.mjs'],
    rules: {
      'no-console': 'off',
    },
  })
  .append({
    // Docs and static assets are not part of the linted code surface.
    ignores: ['gnome-extension/dist/**', 'assets/**', '**/*.md'],
  })

import { cpSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const dist = join(root, 'dist');

const skip = (src) => {
  const rel = src.slice(root.length + 1);
  const parts = rel.split('/');
  if (
    parts.some(
      (part) =>
        part === '__tests__' || part === '__fixtures__' || part === '__mocks__'
    )
  ) {
    return false;
  }
  if (rel === 'android/build' || rel.startsWith('android/build/')) return false;
  if (rel === 'ios/build' || rel.startsWith('ios/build/')) return false;
  if (rel.startsWith('lib/typescript/test/app')) return false;
  return true;
};

mkdirSync(dist, { recursive: true });

const publishPaths = [
  'src',
  'lib',
  'android',
  'ios',
  'cpp',
  'plugin',
  'app.plugin.js',
  'twilio-voice-react-native.podspec',
  'README.md',
  'LICENSE',
];

for (const rel of publishPaths) {
  const source = join(root, rel);
  if (!existsSync(source)) continue;
  cpSync(source, join(dist, rel), { recursive: true, filter: skip });
}

const pkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
delete pkg.scripts;
if (process.argv.includes('--dev')) {
  delete pkg.peerDependencies;
}

const entryExists = (spec) =>
  ['', '.js', '.ts', '.tsx', '.d.ts'].some((ext) =>
    existsSync(join(dist, `${spec}${ext}`))
  );

for (const field of ['main', 'module', 'types', 'react-native', 'source']) {
  if (!entryExists(pkg[field])) {
    throw new Error(
      `package.json "${field}" points at "${pkg[field]}", which is not in dist/`
    );
  }
}

writeFileSync(join(dist, 'package.json'), `${JSON.stringify(pkg, null, 2)}\n`);

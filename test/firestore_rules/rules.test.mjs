// Security-rules tests for Clippy (spec §5), run against the Firestore
// emulator via `firebase emulators:exec`. Proves per-user isolation, the
// size cap, and item immutability without needing a real Firebase project.
import {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} from '@firebase/rules-unit-testing';
import {
  doc,
  getDoc,
  setDoc,
  updateDoc,
  deleteDoc,
} from 'firebase/firestore';
import { readFileSync } from 'node:fs';

let passed = 0;
let failed = 0;
async function check(name, fn) {
  try {
    await fn();
    console.log(`  ok  - ${name}`);
    passed++;
  } catch (e) {
    console.error(`  FAIL - ${name}: ${e.message}`);
    failed++;
  }
}

const clip = (overrides = {}) => ({
  ciphertext: 'ct',
  iv: 'iv',
  hash: 'h',
  source: 'devA',
  timestamp: new Date(),
  ...overrides,
});

const testEnv = await initializeTestEnvironment({
  projectId: 'demo-clippy',
  firestore: {
    rules: readFileSync('../../firestore.rules', 'utf8'),
    host: '127.0.0.1',
    port: 8085,
  },
});

const alice = testEnv.authenticatedContext('alice').firestore();
const bob = testEnv.authenticatedContext('bob').firestore();
const anon = testEnv.unauthenticatedContext().firestore();

// Seed one item under alice with rules disabled (for read/update/delete tests).
await testEnv.withSecurityRulesDisabled(async (ctx) => {
  await setDoc(doc(ctx.firestore(), 'clips/alice/items/seed'), clip());
});

await check('alice can create a clip under her own path', () =>
  assertSucceeds(setDoc(doc(alice, 'clips/alice/items/c1'), clip())));

await check('alice can read her own clip', () =>
  assertSucceeds(getDoc(doc(alice, 'clips/alice/items/seed'))));

await check('bob CANNOT read alice\'s clip', () =>
  assertFails(getDoc(doc(bob, 'clips/alice/items/seed'))));

await check('bob CANNOT create under alice\'s path', () =>
  assertFails(setDoc(doc(bob, 'clips/alice/items/evil'), clip())));

await check('unauthenticated CANNOT read', () =>
  assertFails(getDoc(doc(anon, 'clips/alice/items/seed'))));

await check('unauthenticated CANNOT create', () =>
  assertFails(setDoc(doc(anon, 'clips/alice/items/x'), clip())));

await check('oversize ciphertext (>=150000) is rejected', () =>
  assertFails(
    setDoc(doc(alice, 'clips/alice/items/big'),
      clip({ ciphertext: 'x'.repeat(150000) }))));

await check('items are immutable (update denied)', () =>
  assertFails(
    updateDoc(doc(alice, 'clips/alice/items/seed'), { ciphertext: 'changed' })));

await check('alice can delete her own item (trim)', () =>
  assertSucceeds(deleteDoc(doc(alice, 'clips/alice/items/seed'))));

await testEnv.cleanup();
console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);

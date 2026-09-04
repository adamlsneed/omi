/**
 * STATIC CHECKER (not behavioral coverage) for the marketplace frontend's API defaults.
 * Run: npm test  (from web/frontend)
 *
 * This fork runs against BasedHardware's hosted backend. The files below carry the
 * frontend's API base URL defaults; none of them may fall back to a local dev server.
 * Moved here from app/test/unit/based_hardware_endpoint_defaults_test.dart so the
 * app suite no longer reaches outside app/.
 */
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const DISALLOWED = ['http://localhost:8000', 'http://127.0.0.1:8787'];

const FILES = [
  '../../.env.template',
  '../constants/envConfig.ts',
  '../actions/apps/get-app-initialization-data.ts',
  '../actions/apps/submit-app.ts',
  '../actions/apps/generate-description.ts',
  '../actions/apps/upload-thumbnail.ts',
  '../app/my-apps/page.tsx',
];

describe('marketplace frontend API defaults (static checker)', () => {
  for (const relativePath of FILES) {
    it(`${relativePath} does not default to a local dev server`, () => {
      const source = readFileSync(new URL(relativePath, import.meta.url), 'utf8');
      for (const needle of DISALLOWED) {
        assert.ok(!source.includes(needle), `${relativePath} must not default to ${needle}`);
      }
    });
  }
});

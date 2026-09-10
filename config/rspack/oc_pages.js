const fs = require('node:fs');
const path = require('node:path');

const { IS_OC, ROOT_PATH } = require('../webpack.constants');
const { aliases } = require('../helpers/aliases');
const { OC_PAGES_SOURCE } = require('./loader_rules');

// `link:` installs none of the linked package's dependencies, and
// resolve.symlinks is off (see the resolve block in rspack.config.mjs), so a
// request from oc-pages walks up from the symlinked path through *this* tree
// and misses them. Resolve from the checkout's own roots as well, which is
// where node would have looked and where the versions the pin agrees with
// already are. A pinned oc-pages is a real directory inside ROOT_PATH, so this
// adds nothing.
const linkedOcPagesModules = () => {
  if (!IS_OC) return [];

  let real;
  try {
    real = fs.realpathSync(path.join(ROOT_PATH, 'node_modules/oc-pages'));
  } catch {
    return [];
  }

  if (real === ROOT_PATH || real.startsWith(ROOT_PATH + path.sep)) return [];

  // Node would walk to the filesystem root; stop at the checkout instead, which
  // is the outermost ancestor still carrying a package.json. Past it lie stray
  // node_modules nobody meant as a resolution root, and resolving something
  // there would turn a clean failure into a silently wrong version.
  const ancestors = [];
  for (let dir = real; path.dirname(dir) !== dir; dir = path.dirname(dir)) {
    ancestors.push(dir);
  }

  let boundary = -1;
  ancestors.forEach((dir, i) => {
    if (fs.existsSync(path.join(dir, 'package.json'))) boundary = i;
  });

  return ancestors
    .slice(0, boundary + 1)
    .map((dir) => path.join(dir, 'node_modules'))
    .filter((dir) => fs.existsSync(dir));
};

// Our own tree wins: a linked checkout must not supply a second copy of
// anything both trees carry.
const ocPagesResolveModules = ['node_modules', ...linkedOcPagesModules()];

const packageOf = (specifier) => {
  const parts = specifier.split('/');
  return specifier.startsWith('@') ? parts.slice(0, 2).join('/') : parts[0];
};

// Packages aliased to a copy inside this repo. They are deliberately GitLab's
// single copy, so they are never candidates for infection and must not be
// reported as unclassified. Derived from the alias map rather than listed again,
// so the two cannot drift.
const packagesPinnedToOurCopy = () =>
  new Set(
    Object.entries(aliases)
      .filter(
        ([, target]) =>
          typeof target === 'string' && target.includes(`${path.sep}node_modules${path.sep}`),
      )
      .map(([key]) => packageOf(key.replace(/\$$/, ''))),
  );

// An oc-pages dependency the scanner could not resolve gets no graph entry, so
// it never takes ?vue3. That is invisible until the package happens to be Vue-3
// only, and then it surfaces as `export 'Fragment' was not found in 'vue'`,
// which names Vue and the bundler rather than the classification gap behind it.
// A stale tmp/infection_scanner.json produces exactly this, and cost hours once
// because the error points everywhere except the graph. Reporting is all this
// does: whether an unresolved package is safe to force-infect depends on
// whether anything outside oc-pages imports it, which needs a person.
const warnUnclassifiedOcPagesDeps = (scannerGraph, classifiedPackages) => {
  if (!IS_OC || !scannerGraph) return;

  const pinned = packagesPinnedToOurCopy();
  const classified = new Set(classifiedPackages);
  const unclassified = new Set();

  for (const [filePath, entry] of scannerGraph) {
    if (!entry.infected || !OC_PAGES_SOURCE.test(filePath)) continue;

    for (const edge of entry.imports || []) {
      if (edge.resolved || edge.source.startsWith('.')) continue;

      const pkg = packageOf(edge.source);
      if (!pinned.has(pkg) && !classified.has(pkg)) unclassified.add(pkg);
    }
  }

  if (!unclassified.size) return;

  console.warn(
    `[vue3-infection] OC: unresolved oc-pages dependencies, so not infected: ${[...unclassified]
      .sort()
      .join(', ')}. Harmless while they work under Vue 2; a Vue-3-only one fails as ` +
      `"export 'Fragment' was not found in 'vue'". Try deleting tmp/infection_scanner.json ` +
      `first -- a stale graph looks exactly like this.`,
  );
};

const ocPagesRules = IS_OC
  ? [
      // oc-pages imports an .svg as its markup unless the import asks for a URL.
      {
        test: /\.svg$/,
        include: OC_PAGES_SOURCE,
        resourceQuery: { not: [/url/] },
        type: 'asset/source',
      },
    ]
  : [];

module.exports = { ocPagesRules, ocPagesResolveModules, warnUnclassifiedOcPagesDeps };

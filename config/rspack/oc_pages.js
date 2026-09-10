const fs = require('node:fs');
const path = require('node:path');

const { IS_OC, ROOT_PATH } = require('../webpack.constants');
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

module.exports = { ocPagesRules, ocPagesResolveModules };

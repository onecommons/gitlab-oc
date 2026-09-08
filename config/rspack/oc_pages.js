const { IS_OC } = require('../webpack.constants');
const { OC_PAGES_SOURCE } = require('./loader_rules');

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

module.exports = { ocPagesRules };

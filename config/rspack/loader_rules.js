const path = require('path');
const browserslist = require('browserslist');

const ROOT_PATH = path.resolve(__dirname, '../..');

const WORKER_LOADER_PATH = path.join(__dirname, 'worker_loader.js');
const WORKER_QUERY_RE = /(^|[?&])worker(&|$)/;

// OC Change: the oc-pages package ships source, and resolve.symlinks is off, so
// its files are seen at the symlinked oc/ path rather than under node_modules.
// Match both: a rule keyed to only one of them stops applying without a word.
const OC_PAGES_DIRS = '(dashboard|project_overview|public_cloud|vue_shared)';
const OC_PAGES_SOURCE = new RegExp(
  `[\\\\/](?:oc-pages|oc[\\\\/]app[\\\\/]assets[\\\\/]javascripts)[\\\\/]${OC_PAGES_DIRS}[\\\\/]`,
);

const shouldExcludeFromCompiling = (modulePath) => {
  if (/\.vue\.js$/.test(modulePath)) {
    return false;
  }

  if (OC_PAGES_SOURCE.test(modulePath)) {
    return false; // OC Change
  }

  if (/graphql-ws/.test(modulePath)) {
    return false;
  }

  if (new RegExp(path.join(ROOT_PATH, 'node_modules/@gitlab/ui/src')).test(modulePath)) {
    return false;
  }

  return (
    new RegExp(path.join(ROOT_PATH, 'node_modules')).test(modulePath) ||
    new RegExp(path.join(ROOT_PATH, 'vendor/assets')).test(modulePath)
  );
};

const BROWSERSLIST_TARGETS = browserslist(browserslist.loadConfig({ path: ROOT_PATH }));

function buildSwcOptions() {
  const isIstanbul = process.env.BABEL_ENV === 'istanbul';

  const options = {
    jsc: {
      parser: {
        syntax: 'ecmascript',
        jsx: false,
        dynamicImport: true,
        privateMethod: true,
        functionBind: false,
        exportDefaultFrom: true,
        exportNamespaceFrom: true,
        decorators: false,
        decoratorsBeforeExport: false,
        topLevelAwait: false,
        importMeta: true,
        importAssertions: false,
      },
      experimental: {},
    },
    env: {
      mode: 'usage',
      coreJs: '3',
      targets: BROWSERSLIST_TARGETS,
    },
    module: {
      type: 'es6',
      strictMode: false,
      lazy: false,
      noInterop: false,
    },
  };

  if (isIstanbul) {
    const pluginWasm = require.resolve('swc-plugin-coverage-instrument');
    options.jsc.experimental.plugins = [[pluginWasm, {}]];
  }

  return options;
}

function buildLoaderRules({ vueLoaderOptions = {} } = {}) {
  const swcOptions = buildSwcOptions();

  return [
    {
      resourceQuery: WORKER_QUERY_RE,
      use: [{ loader: WORKER_LOADER_PATH }],
    },

    {
      test: /\.(js|cjs|mjs)$/,
      exclude: shouldExcludeFromCompiling,
      loader: 'builtin:swc-loader',
      options: swcOptions,
    },

    {
      test: /\.vue$/,
      // eslint-disable-next-line no-underscore-dangle -- internal key plumbed in from the config
      loader: vueLoaderOptions.__loaderModule || 'vue-loader',
      options: vueLoaderOptions,
    },

    {
      test: /\.(graphql|gql)$/,
      // OC Change
      exclude: (modulePath) => /node_modules/.test(modulePath) && !OC_PAGES_SOURCE.test(modulePath),
      loader: 'graphql-tag/loader',
    },

    {
      test: /\.svg$/,
      resourceQuery: /raw/,
      type: 'asset/source',
    },

    {
      test: /\.svg$/,
      resourceQuery: /url/,
      exclude: /@gitlab\/svgs\/.+\.svg$/,
      type: 'asset/resource',
      generator: {
        filename: '[name].[contenthash:8][ext]',
      },
    },

    {
      test: /@gitlab\/svgs\/.+\.svg$/,
      type: 'asset/resource',
      generator: {
        filename: '[name].[contenthash:8][ext]',
      },
    },

    {
      test: /\.(gif|png|mp4)$/,
      type: 'asset',
      parser: {
        dataUrlCondition: {
          maxSize: 2048,
        },
      },
      generator: {
        filename: '[name].[contenthash:8][ext]',
      },
    },

    {
      test: /\.(eot|ttf|woff|woff2)$/,
      include: /node_modules\/(katex\/dist\/fonts|monaco-editor)/,
      type: 'asset/resource',
      generator: {
        filename: '[name].[contenthash:8][ext]',
      },
    },

    {
      test: /\.(worker(\.min)?\.js|pdf)$/,
      exclude: /node_modules/,
      type: 'asset/resource',
      generator: {
        filename: '[name].[contenthash:8][ext]',
      },
    },

    {
      test: /editor\/schema\/.+\.json$/,
      type: 'asset/resource',
      generator: {
        filename: '[name].[contenthash:8][ext]',
      },
    },

    {
      exclude: /\.svg$/,
      resourceQuery: /raw/,
      type: 'asset/source',
    },

    {
      test: /\.css$/,
      type: 'javascript/auto',
      use: [
        'style-loader',
        {
          loader: 'css-loader',
          options: {
            modules: 'global',
            localIdentName: '[name].[contenthash:8].[ext]',
          },
        },
      ],
    },

    {
      test: /\.scss$/,
      type: 'javascript/auto',
      use: [
        'style-loader',
        {
          loader: 'css-loader',
          options: {
            modules: 'global',
            localIdentName: '[name].[contenthash:8].[ext]',
          },
        },
        {
          loader: 'sass-loader',
          options: {
            api: 'modern-compiler',
          },
        },
      ],
    },
  ].filter(Boolean);
}

module.exports = { buildLoaderRules, shouldExcludeFromCompiling, OC_PAGES_SOURCE };

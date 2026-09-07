const IS_EE = require('../../config/helpers/is_ee_env');
const IS_JH = require('../../config/helpers/is_jh_env');
const IS_OC = require('../../config/helpers/is_oc_env'); // OC Change

const allPatterns = [
  {
    ignore: !IS_EE,
    pattern: 'ee/**/*.*',
  },
  {
    ignore: !IS_JH,
    pattern: 'jh/**/*.*',
  },
  // OC Change
  {
    ignore: !IS_OC,
    pattern: 'oc/**/*.*',
  },
];

const ignorePatterns = allPatterns.filter((x) => x.ignore).map((x) => x.pattern);

module.exports = { ignorePatterns };
